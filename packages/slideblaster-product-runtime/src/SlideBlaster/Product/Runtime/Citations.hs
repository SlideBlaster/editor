{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.Citations
-- Description : Resolve @\\cite@, @\\citefootnote@ and @\\bibliography@ with slideblaster-cite.
--
-- A pure pass over the flow content of a deck. Labels are numbered by first
-- citation across the whole deck; every 'CitationContent' becomes resolved
-- text, each frame collects the references its @\\citefootnote@ marks name (a
-- footer), and @\\bibliography@ is filled with the reference list. Keys with no
-- entry are returned so the analyzer can report them.
module SlideBlaster.Product.Runtime.Citations
  ( Resolved (..)
  , resolveCitations
  ) where

import SlideBlaster.Canvas
  ( Content
  , ContentItem (..)
  , ContentNode (..)
  , ContainerKind (..)
  , Dialect (..)
  , Provenance (..)
  , DerivedState (..)
  , TableCell (..)
  , TableModel (..)
  , TableRow (..)
  , content
  , contentNodes
  , identifierText
  )
import SlideBlaster.Cite

import Data.Foldable (toList)
import Data.List (nub)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text

data Resolved = Resolved
  { resolvedFrames :: ![(Content, Content)]
  -- ^ per frame, in input order: body with resolved citations, footer references
  , resolvedUnknown :: ![(Int, Text)]
  -- ^ frame index and key, for keys with no bibliography entry
  }

resolveCitations :: CitationStyle -> Bibliography -> [Content] -> Resolved
resolveCitations style bibliography frames =
  Resolved
    { resolvedFrames = [(content (fmap go (contentNodes body)), footer body) | body <- frames]
    , resolvedUnknown = nub [(i, k) | (i, body) <- zip [0 ..] frames, k <- keysOf (contentNodes body), lookup k labels == Just Nothing]
    }
  where
    perFrame = fmap (keysOf . contentNodes) frames
    allKeys = concat perFrame
    labels = citationLabels style bibliography allKeys
    uniqueKeys = nub allKeys
    labelOf k = fromMaybe "?" (fromMaybe Nothing (lookup k labels))
    shortLabel k = case style of
      NumericStyle -> Text.dropAround (\c -> c == '[' || c == ']') (labelOf k)
      AuthorYearStyle -> labelOf k
    cited ks = case style of
      NumericStyle -> "[" <> Text.intercalate ", " (fmap shortLabel ks) <> "]"
      AuthorYearStyle -> "(" <> Text.intercalate "; " (fmap shortLabel ks) <> ")"
    reference k = labelOf k <> " " <> maybe k formatEntry (lookupEntry k bibliography)
    refNode k = TransparentContainer prov (GenericContainer "p") [TextRun prov (reference k)]
    prov = CanvasProvenance LaTeX
    bibliographyKeys
      | null uniqueKeys = fmap entryKey (bibliographyEntries bibliography)
      | otherwise = [k | k <- uniqueKeys, Just _ <- [lookupEntry k bibliography]]
    footer body =
      content [refNode k | k <- nub (footnoteKeys (contentNodes body))]
    go node = case node of
      CitationContent p ks _ ->
        CitationContent p ks (DerivedReady (content [TextRun p (cited (fmap identifierText (toList ks)))]))
      TransparentContainer p (GenericContainer "bibliography") _ ->
        TransparentContainer p (GenericContainer "bibliography") (fmap refNode bibliographyKeys)
      TransparentContainer p kind cs -> TransparentContainer p kind (fmap go cs)
      StyledRun p marks cs -> StyledRun p marks (fmap go cs)
      ListContent p kind items -> ListContent p kind (fmap (\i -> i {contentItemBody = fmap go (contentItemBody i)}) items)
      OverlayContent hook cs -> OverlayContent hook (fmap go cs)
      TableContent p (DerivedReady (TableModel rows aligns)) ->
        TableContent p (DerivedReady (TableModel (fmap (\(TableRow cells) -> TableRow (fmap (\c -> c {tableCellContent = fmap go (tableCellContent c)}) cells)) rows) aligns))
      other -> other

-- Citation keys in reading order.
keysOf :: [ContentNode] -> [Text]
keysOf = concatMap node
  where
    node n = case n of
      CitationContent _ ks _ -> fmap identifierText (toList ks)
      _ -> concatMap node (childrenOf n)

-- Keys named by @\\citefootnote@ marks.
footnoteKeys :: [ContentNode] -> [Text]
footnoteKeys = concatMap node
  where
    node n = case n of
      TransparentContainer _ (GenericContainer "footnote") cs -> keysOf cs
      _ -> concatMap node (childrenOf n)

childrenOf :: ContentNode -> [ContentNode]
childrenOf n = case n of
  StyledRun _ _ cs -> cs
  TransparentContainer _ _ cs -> cs
  ListContent _ _ items -> concatMap contentItemBody (toList items)
  OverlayContent _ cs -> cs
  TableContent _ (DerivedReady (TableModel rows _)) ->
    concat [tableCellContent c | TableRow cells <- toList rows, c <- toList cells]
  _ -> []

-- | A one-line reference: authors, title, venue, year.
formatEntry :: BibEntry -> Text
formatEntry e =
  Text.intercalate ". " parts <> "."
  where
    clean = Text.filter (\c -> c /= '{' && c /= '}')
    field name = clean <$> entryField name e
    authors = case authorSurnames e of
      [] -> Nothing
      names -> Just (Text.intercalate ", " names)
    venue = case mapMaybeField ["journal", "booktitle", "publisher", "howpublished"] of
      v : _ -> Just v
      [] -> Nothing
    mapMaybeField names = [v | n <- names, Just v <- [field n]]
    parts = [p | Just p <- [authors, field "title", venue, field "year"], not (Text.null p)]
