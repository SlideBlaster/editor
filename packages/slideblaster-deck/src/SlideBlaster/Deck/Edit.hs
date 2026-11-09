{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Deck.Edit
-- Description : Narrow, verified structural writers for @*.slideBlaster.md@.
--
-- The alpha writes only structure: new slide, duplicate slide, delete slide,
-- reorder slide and set slide id. Each operation is exactly one
-- 'Source.ExactReplacement' against the revision the caller saw, followed by a
-- full reparse that must be semantically ready and show the expected slide
-- order. Nothing is printed from the syntax; bytes outside the replaced region
-- are untouched, and a slide's own body bytes are copied, never regenerated.
--
-- The generated title slide cannot be edited, moved or deleted: it is derived
-- from the frontmatter.
module SlideBlaster.Deck.Edit
  ( MarkdownEditError (..)
  , newSlideAfter
  , duplicateSlide
  , deleteSlide
  , moveSlideAfter
  , setSlideId
  ) where

import SlideBlaster.Deck.Container
  ( Container (..)
  , SlideEntry (..)
  , Span (..)
  , validSlideId
  )
import SlideBlaster.Deck.Markdown
  ( DeckConfig
  , MarkdownDeck (..)
  , MarkdownDeckDocument
  , MarkdownDeckSyntax (..)
  , DeckSlide (..)
  , analyzeMarkdownDeckWith
  , titleSlideId
  )
import SlideBlaster.Document qualified as Document
import SlideBlaster.Source qualified as Source

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

-- | Why an edit was refused.
data MarkdownEditError
  = EditNotReady
  | EditStale !Source.Revision !Source.Revision
  | EditSlideMissing !Text
  | EditInvalidId !Text
  | EditIdInUse !Text
  | EditTitleSlide
  | EditSourceRejected !Source.ExactReplacementError
  | EditVerificationRejected
  deriving stock (Eq, Show)

-- A planned change: replace the span, with the slide ids the result must show.
data Plan = Plan !Int !Int !ByteString ![Text]

-- | Insert an empty slide titled @Untitled@ after the named slide, or before the
-- first slide when 'Nothing' (or the title slide) is named. Returns the new
-- document and the new slide's id.
newSlideAfter
  :: DeckConfig
  -> Source.Revision
  -> Maybe Text
  -> MarkdownDeckDocument
  -> Either MarkdownEditError (MarkdownDeckDocument, Text)
newSlideAfter config expected after document = do
  (container, deck, source) <- ready expected document
  let identity = freshId (usedIds deck) "slide"
  position <- insertionPoint container deck after
  let before = ByteString.take position (Source.snapshotBytes source)
      eol = endOfLine source
      text = separator eol before <> "## Untitled {#" <> Encoding.encodeUtf8 identity <> "}" <> eol <> eol
      order = insertAfterId after (deckIds deck) identity
  result <- commit config expected document (Plan position position text order)
  Right (result, identity)

-- | Copy a slide, with a fresh id, directly after it. Returns the new id.
duplicateSlide
  :: DeckConfig
  -> Source.Revision
  -> Text
  -> MarkdownDeckDocument
  -> Either MarkdownEditError (MarkdownDeckDocument, Text)
duplicateSlide config expected identity document = do
  (container, deck, source) <- ready expected document
  entry <- slideEntry container deck identity
  let fresh = freshId (usedIds deck) (identity <> "-copy")
      Span start end = slideSpan entry
      original = slice start end (Source.snapshotBytes source)
      eol = endOfLine source
      copy = retarget entry start fresh original
      text = separator eol original <> copy
      order = insertAfterId (Just identity) (deckIds deck) fresh
  result <- commit config expected document (Plan end end text order)
  Right (result, fresh)

-- | Remove a slide, including its notes and pictures.
deleteSlide
  :: DeckConfig
  -> Source.Revision
  -> Text
  -> MarkdownDeckDocument
  -> Either MarkdownEditError MarkdownDeckDocument
deleteSlide config expected identity document = do
  (container, deck, _) <- ready expected document
  entry <- slideEntry container deck identity
  let Span start end = slideSpan entry
  commit config expected document (Plan start end ByteString.empty (filter (/= identity) (deckIds deck)))

-- | Move a slide to directly after another, or to the front when 'Nothing' is
-- given. One replacement covers the two affected positions.
moveSlideAfter
  :: DeckConfig
  -> Source.Revision
  -> Text
  -> Maybe Text
  -> MarkdownDeckDocument
  -> Either MarkdownEditError MarkdownDeckDocument
moveSlideAfter config expected identity target document = do
  (container, deck, source) <- ready expected document
  moved <- slideEntry container deck identity
  anchor <- traverse (slideEntry container deck) (nonTitle target)
  let entries = containerSlides container
      bytes = Source.snapshotBytes source
      eol = endOfLine source
      segment e = case slideSpan e of Span a b -> slice a b bytes
      others = filter (\e -> not (sameEntry e moved)) entries
      arranged =
        case anchor of
          Nothing -> moved : others
          Just a -> concatMap (\e -> if sameEntry e a then [e, moved] else [e]) others
      Span firstStart _ = slideSpan (headOr moved entries)
      Span _ lastEnd = slideSpan (lastOr moved entries)
      pieces = fmap segment arranged
      -- Bytes between consecutive slides (section headings) stay where they
      -- are; only the slides trade places around them.
      gaps = [slice a b bytes | (Span _ a, Span b _) <- zip (fmap slideSpan entries) (drop 1 (fmap slideSpan entries))]
      joined = ByteString.concat (zipWith terminate pieces (fmap Just gaps <> [Nothing]))
      terminate piece gap = case gap of
        Nothing -> piece
        Just g
          | ByteString.isSuffixOf "\n" piece -> piece <> g
          | otherwise -> piece <> eol <> g
      idOf = zip (fmap slideSpan entries) [deckSlideId s | s <- deckSlides deck, not (deckSlideIsTitle s)]
      newIds = [i | e <- arranged, Just i <- [lookup (slideSpan e) idOf]]
      titleIds = [i | i <- deckIds deck, i == titleSlideId]
  commit config expected document (Plan firstStart lastEnd joined (titleIds <> newIds))
  where
    nonTitle (Just t) | t /= titleSlideId = Just t
    nonTitle _ = Nothing

-- | Set a slide's id: replaces the written id, or appends @{#id}@ to a heading
-- that has none.
setSlideId
  :: DeckConfig
  -> Source.Revision
  -> Text
  -> Text
  -> MarkdownDeckDocument
  -> Either MarkdownEditError MarkdownDeckDocument
setSlideId config expected identity new document = do
  (container, deck, source) <- ready expected document
  if not (validSlideId new)
    then Left (EditInvalidId new)
    else Right ()
  entry <- slideEntry container deck identity
  if new /= identity && Set.member new (usedIds deck)
    then Left (EditIdInUse new)
    else Right ()
  let order = fmap (\i -> if i == identity then new else i) (deckIds deck)
      bytes = Source.snapshotBytes source
  case slideIdSpan entry of
    Just (Span a b) ->
      commit config expected document (Plan a b (Encoding.encodeUtf8 new) order)
    Nothing ->
      let Span hs he = slideHeadingSpan entry
          written = slice hs he bytes
          trimmedEnd = hs + ByteString.length (ByteString.dropWhileEnd (== 32) written)
       in commit config expected document (Plan trimmedEnd trimmedEnd (Encoding.encodeUtf8 (" {#" <> new <> "}")) order)

------------------------------------------------------------------------------
-- Shared helpers

ready
  :: Source.Revision
  -> MarkdownDeckDocument
  -> Either MarkdownEditError (Container, MarkdownDeck, Source.SourceBufferSnapshot)
ready expected document = do
  let source = Document.documentSource document
      actual = Source.snapshotRevision source
  if expected /= actual then Left (EditStale expected actual) else Right ()
  deck <- maybe (Left EditNotReady) Right (Document.documentSemantic document)
  container <- maybe (Left EditNotReady) Right (syntaxContainer (Document.documentSyntax document))
  Right (container, deck, source)

commit
  :: DeckConfig
  -> Source.Revision
  -> MarkdownDeckDocument
  -> Plan
  -> Either MarkdownEditError MarkdownDeckDocument
commit config expected document (Plan start end new order) = do
  let source = Document.documentSource document
      expectedBytes = slice start end (Source.snapshotBytes source)
  target <- maybe (Left EditVerificationRejected) Right (Source.sourceSpanFromInts start end)
  let replacement = Source.mkExactReplacement expected target expectedBytes new
  successorSource <- either (Left . EditSourceRejected) Right (Source.applyExactReplacement replacement source)
  let successor = analyzeMarkdownDeckWith config successorSource
  case Document.documentSemantic successor of
    Just deck | deckIds deck == order -> Right successor
    _ -> Left EditVerificationRejected

deckIds :: MarkdownDeck -> [Text]
deckIds = fmap deckSlideId . deckSlides

usedIds :: MarkdownDeck -> Set.Set Text
usedIds = Set.fromList . deckIds

freshId :: Set.Set Text -> Text -> Text
freshId used base = pick (1 :: Int)
  where
    pick n =
      let candidate = if n == 1 then numbered base else base <> "-" <> Text.pack (show n)
       in if Set.member candidate used then pick (n + 1) else candidate
    numbered b
      | b == "slide" = "slide-" <> Text.pack (show (Set.size used + 1))
      | otherwise = b

slideEntry :: Container -> MarkdownDeck -> Text -> Either MarkdownEditError SlideEntry
slideEntry container deck identity
  | identity == titleSlideId = Left EditTitleSlide
  | otherwise =
      case lookup identity (zip bodyIds (containerSlides container)) of
        Just entry -> Right entry
        Nothing -> Left (EditSlideMissing identity)
  where
    -- Slides after the generated title slide line up with container entries.
    bodyIds = [deckSlideId s | s <- deckSlides deck, not (deckSlideIsTitle s)]

sameEntry :: SlideEntry -> SlideEntry -> Bool
sameEntry a b = slideSpan a == slideSpan b

headOr :: a -> [a] -> a
headOr d [] = d
headOr _ (x : _) = x

lastOr :: a -> [a] -> a
lastOr d xs = foldl (\_ x -> x) d xs

-- Where a new slide goes: after the named slide, else before the first slide.
insertionPoint :: Container -> MarkdownDeck -> Maybe Text -> Either MarkdownEditError Int
insertionPoint container deck after =
  case after of
    Just identity | identity /= titleSlideId -> do
      entry <- slideEntry container deck identity
      let Span _ end = slideSpan entry
      Right end
    _ ->
      case containerSlides container of
        e : _ -> let Span s _ = slideSpan e in Right s
        [] -> Right (containerLength container)

insertAfterId :: Maybe Text -> [Text] -> Text -> [Text]
insertAfterId after ids new =
  case after of
    Just a | a /= titleSlideId ->
      concatMap (\i -> if i == a then [i, new] else [i]) ids
    _ ->
      let (titles, rest) = span (== titleSlideId) ids
       in titles <> [new] <> rest

-- Blank-line padding so a block inserted after @before@ starts its own paragraph.
separator :: ByteString -> ByteString -> ByteString
separator eol before
  | ByteString.null before = ByteString.empty
  | ByteString.isSuffixOf "\n\n" before || ByteString.isSuffixOf "\n\r\n" before = ByteString.empty
  | ByteString.isSuffixOf "\n" before = eol
  | otherwise = eol <> eol

endOfLine :: Source.SourceBufferSnapshot -> ByteString
endOfLine source
  | ByteString.isInfixOf "\r\n" (Source.snapshotBytes source) = "\r\n"
  | otherwise = "\n"

slice :: Int -> Int -> ByteString -> ByteString
slice a b = ByteString.take (b - a) . ByteString.drop a

-- Give a copied slide a different id: swap the written id, or append one.
retarget :: SlideEntry -> Int -> Text -> ByteString -> ByteString
retarget entry slideStart new original =
  case slideIdSpan entry of
    Just (Span a b) ->
      let ra = a - slideStart
          rb = b - slideStart
       in ByteString.take ra original <> Encoding.encodeUtf8 new <> ByteString.drop rb original
    Nothing ->
      let Span hs he = slideHeadingSpan entry
          written = slice (hs - slideStart) (he - slideStart) original
          cut = hs - slideStart + ByteString.length (ByteString.dropWhileEnd (== 32) written)
       in ByteString.take cut original <> Encoding.encodeUtf8 (" {#" <> new <> "}") <> ByteString.drop cut original
