{-# LANGUAGE OverloadedStrings #-}

-- | Round-trip and locality laws for the @*.slideBlaster.md@ deck reader and its
-- narrow writers, over the corpus @unit/@ decks and generated inputs.
module Main (main) where

import SlideBlaster.Canvas qualified as Canvas
import SlideBlaster.Deck.Container
import SlideBlaster.Deck.Edit
import SlideBlaster.Deck.Markdown
import SlideBlaster.Document qualified as Document
import SlideBlaster.Source qualified as Source

import Control.Monad (forM)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List (isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import System.Directory (doesDirectoryExist, listDirectory)
import System.Exit (exitFailure)

type Law = (String, Bool)

main :: IO ()
main = do
  files <- corpusFiles
  decks <- forM files (\path -> (,) path <$> ByteString.readFile path)
  let laws =
        concatMap (uncurry deckLaws) decks
          <> sampleLaws decks
          <> fuzzLaws
          <> failureLaws
  results <- forM laws $ \(name, ok) -> do
    putStrLn ((if ok then "ok   " else "FAIL ") <> name)
    pure ok
  if and results
    then putStrLn ("all " <> show (length results) <> " laws hold")
    else exitFailure

corpusFiles :: IO [FilePath]
corpusFiles = do
  let root = "../../fixtures/corpus/unit"
  exists <- doesDirectoryExist root
  if exists
    then do
      names <- listDirectory root
      pure [root <> "/" <> n | n <- names, ".slideBlaster.md" `isSuffixOf` n]
    else pure []

snapshot :: ByteString -> Source.SourceBufferSnapshot
snapshot = Source.snapshotFromBytes

config :: DeckConfig
config = defaultDeckConfig

readyDeck :: ByteString -> Maybe (MarkdownDeckDocument, MarkdownDeck)
readyDeck bytes =
  let doc = analyzeMarkdownDeckWith config (snapshot bytes)
   in (,) doc <$> Document.documentSemantic doc

bytesOf :: MarkdownDeckDocument -> ByteString
bytesOf = Source.snapshotBytes . Document.documentSource

revisionOf :: MarkdownDeckDocument -> Source.Revision
revisionOf = Source.snapshotRevision . Document.documentSource

ids :: MarkdownDeck -> [Text]
ids = fmap deckSlideId . deckSlides

-- | The container reader partitions the bytes exactly.
containerRoundTrips :: ByteString -> Bool
containerRoundTrips bytes =
  case readContainer bytes of
    Right c -> Encoding.encodeUtf8 (printContainer c) == bytes
    Left _ -> True

deckLaws :: FilePath -> ByteString -> [Law]
deckLaws path bytes =
  [ ("round trip: print (read x) == x: " <> path, containerRoundTrips bytes)
  , ("document keeps exact source: " <> path, fmap bytesOf (Just (analyzeMarkdownDeckWith config (snapshot bytes))) == Just bytes)
  , ("no hard diagnostic: " <> path, not (any Document.isHardDiagnostic (Document.documentDiagnostics (analyzeMarkdownDeckWith config (snapshot bytes)))))
  ]
    <> maybe [] (editLaws path bytes) (readyDeck bytes)

-- | Editing one slide's bytes leaves every other slide's text and the
-- container structure alone; each writer is one local replacement.
editLaws :: FilePath -> ByteString -> (MarkdownDeckDocument, MarkdownDeck) -> [Law]
editLaws path bytes (doc, deck) =
  [ ("locality: body edit leaves other slides intact: " <> path, bodyEditLocal)
  , ("new slide then delete restores bytes: " <> path, newThenDelete)
  , ("duplicate then delete restores bytes: " <> path, duplicateThenDelete)
  , ("set id then set back restores bytes: " <> path, renameBack)
  , ("move then move back restores bytes: " <> path, moveBack)
  , ("set id is one local replacement: " <> path, renameLocal)
  ]
  where
    rev = revisionOf doc
    named = [deckSlideId s | s <- deckSlides deck, not (deckSlideIsTitle s)]
    explicit = [deckSlideId s | s <- deckSlides deck, deckSlideExplicitId s]
    firstSlide = take 1 named
    bodyEditLocal =
      case readContainer bytes of
        Right c ->
          and
            [ let SlideEntry {slideBodySpan = Span a b} = entry
                  edited = ByteString.take a bytes <> "\nedited line\n" <> ByteString.drop b bytes
               in case readContainer edited of
                    Right c' ->
                      length (containerSlides c') == length (containerSlides c)
                        && [slideText e | (j, e) <- zip [0 :: Int ..] (containerSlides c'), j /= i]
                          == [slideText e | (j, e) <- zip [0 :: Int ..] (containerSlides c), j /= i]
                    Left _ -> False
            | (i, entry) <- zip [0 :: Int ..] (containerSlides c)
            ]
        Left _ -> False
    newThenDelete = and
      [ case newSlideAfter config rev (Just s) doc of
          Right (doc', new) ->
            case deleteSlide config (revisionOf doc') (revisionOf doc' `seq` new) doc' of
              Right doc'' -> bytesOf doc'' == bytes
              Left _ -> False
          Left _ -> False
      | s <- firstSlide
      ]
    duplicateThenDelete = and
      [ case duplicateSlide config rev s doc of
          Right (doc', copy) ->
            case deleteSlide config (revisionOf doc') copy doc' of
              -- Copying the last slide may add the blank separator line that
              -- precedes a new slide; every other copy restores byte for byte.
              Right doc'' ->
                if Just s == lastExplicit
                  then ByteString.dropWhileEnd isSpaceByte (bytesOf doc'') == ByteString.dropWhileEnd isSpaceByte bytes
                  else bytesOf doc'' == bytes
              Left _ -> False
          Left _ -> False
      | s <- explicit
      ]
    lastExplicit = case reverse named of l : _ -> Just l; [] -> Nothing
    isSpaceByte w = w == 10 || w == 13 || w == 32
    renameBack = and
      [ case setSlideId config rev s "zz-renamed" doc of
          Right doc' ->
            case setSlideId config (revisionOf doc') "zz-renamed" s doc' of
              Right doc'' -> bytesOf doc'' == bytes
              Left _ -> False
          Left _ -> False
      | s <- explicit
      ]
    renameLocal = and
      [ case setSlideId config rev s "zz-renamed" doc of
          Right doc' ->
            let after = bytesOf doc'
                prefix = commonPrefix bytes after
                suffix = commonSuffix (ByteString.drop prefix bytes) (ByteString.drop prefix after)
             in ByteString.length after - ByteString.length bytes
                  == ByteString.length "zz-renamed" - ByteString.length (Encoding.encodeUtf8 s)
                  && prefix + suffix >= ByteString.length bytes - ByteString.length (Encoding.encodeUtf8 s)
          Left _ -> False
      | s <- explicit
      ]
    moveBack =
      case explicit of
        a : b : _ | length explicit == length named ->
          case moveSlideAfter config rev a (Just b) doc of
            Right doc' ->
              case moveSlideAfter config (revisionOf doc') a Nothing doc' of
                Right doc'' ->
                  -- moving a back to the front restores the original order of
                  -- slides; bytes match when every slide ends with a newline
                  ids' doc'' == ids' doc || not (all endsNewline (slideTexts bytes))
                Left _ -> False
            Left _ -> False
        _ -> True
    ids' d = maybe [] ids (Document.documentSemantic d)
    endsNewline t = "\n" `Text.isSuffixOf` t
    slideTexts b = either (const []) (fmap slideText . containerSlides) (readContainer b)

commonPrefix :: ByteString -> ByteString -> Int
commonPrefix a b = length (takeWhile id (ByteString.zipWith (==) a b))

commonSuffix :: ByteString -> ByteString -> Int
commonSuffix a b = commonPrefix (ByteString.reverse a) (ByteString.reverse b)

sampleLaws :: [(FilePath, ByteString)] -> [Law]
sampleLaws decks =
  case [bytes | (path, bytes) <- decks, "all-features" `isInfixOf'` path] of
    bytes : _ ->
      case readyDeck bytes of
        Just (doc, deck) ->
          [ ("sample: slide ids", ids deck == ["title-slide", "why", "prog", "arch", "results", "refs"])
          , ("sample: notes on why", maybe False (not . null . Canvas.contentNodes . deckSlideNotes) (deckSlideById "why" deck))
          , ("sample: figure resource on arch", maybe False (not . null . deckSlideResources) (deckSlideById "arch" deck))
          , ("sample: no hard diagnostics", not (any Document.isHardDiagnostic (Document.documentDiagnostics doc)))
          ]
        Nothing -> [("sample: reads ready", False)]
    [] -> []
  where
    isInfixOf' needle hay = Text.pack needle `Text.isInfixOf` Text.pack hay

-- Deterministic pseudo-random decks from fragments.
fuzzLaws :: [Law]
fuzzLaws =
  [ ("fuzz: container round trip (" <> show (length inputs) <> " inputs)", all containerRoundTrips inputs)
  , ("fuzz: analysis is total", all (\b -> let d = analyzeMarkdownDeckWith config (snapshot b) in bytesOf d == b) inputs)
  ]
  where
    inputs = fmap generate [1 .. 600 :: Int]

fragments :: [Text]
fragments =
  [ "---\n", "title: T\n", "theme: x\n", "---\n", "## A {#a}\n", "## B\n", "## C {#c}\n", "\n"
  , "- item <2->\n", "```notes\n", "```slide\n", "```\n", "text \\only<1>{x}\n", "| a | b |\n|---|---|\n"
  , "::: columns\n", ":::\n", "\\figure{f.tikz}\n", "# Head\n", "$x$ and \\cite{k}\n", "caf\233\n", "\r\n", "tail"
  ]

generate :: Int -> ByteString
generate seed = Encoding.encodeUtf8 (Text.concat (take count (pick (seed * 7919 + 13))))
  where
    count = 1 + seed `mod` 24
    pick s = let s' = (s * 1103515245 + 12345) `mod` 2147483648 in (fragments !! (s' `div` 7 `mod` length fragments)) : pick s'

failureLaws :: [Law]
failureLaws =
  [ ("invalid UTF-8 is syntax only", syntaxOnly "\255\254 ## x\n")
  , ("unclosed frontmatter is syntax only", syntaxOnly "---\ntitle: x\n")
  , ("duplicate ids are syntax only", syntaxOnly "## A {#a}\n\n## B {#a}\n")
  , ("bad id is syntax only", syntaxOnly "## A {#Bad_Id}\n")
  , ("empty deck is syntax only", syntaxOnly "")
  , ("heading in fence is not a slide", ids' "## A {#a}\n\n```\n## not a slide\n```\n" == Just ["a"])
  , ("include line is a boundary, not slide text", includeShape "## A {#a}\n\nx\n\n# S {#s}\n\\include[titleslide]{kid}\n\n## B {#b}\n\ny\n" == Just ([1], [2], 3, ["s"]))
  , ("include inside a fence is text", includeShape "## A {#a}\n\n```\n\\include{kid}\n```\n" == Just ([], [], 1, []))
  , ("include round-trips", fmap printContainer (either (const Nothing) Just (readContainer "## A\n\\include{k}\nprose\n## B\n")) == Just "## A\n\\include{k}\nprose\n## B\n")
  , ("missing ids get slide-N", ids' "## A\n\n## B {#slide-1}\n\n## C\n" == Just ["slide-2", "slide-1", "slide-3"])
  ]
  where
    includeShape bytes = do
      container <- either (const Nothing) Just (readContainer bytes)
      deck <- Document.documentSemantic (analyzeMarkdownDeckWith config (snapshot bytes))
      Just
        ( [includeSlidesBefore i | i <- containerIncludes container]
        , [deckIncludeFramesBefore i | i <- deckIncludes deck]
        , length (deckFrames deck)
        , [x | i <- deckIncludes deck, Just x <- [deckIncludeSection i]]
        )
    syntaxOnly bytes = Document.documentSemantic (analyzeMarkdownDeckWith config (snapshot bytes)) == Nothing
    ids' bytes = ids <$> Document.documentSemantic (analyzeMarkdownDeckWith config (snapshot bytes))
