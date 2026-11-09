{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import SlideBlaster.Canvas qualified as Canvas
import SlideBlaster.Deck
import SlideBlaster.Document qualified as Document
import SlideBlaster.Presentation qualified as Presentation
import SlideBlaster.Source qualified as Source

import Data.ByteString qualified as ByteString
import Data.List.NonEmpty qualified as NonEmpty
import System.Exit (exitFailure)

main :: IO ()
main = do
  fixture <- ByteString.readFile "test/fixtures/demo.slide"
  let document = analyzeDeck (Source.snapshotFromBytes fixture)
  check "fixture bytes remain exact" (Source.snapshotBytes (Document.documentSource document) == fixture)
  presentation <- require "fixture is ready" (Document.documentSemantic document)
  let frames = NonEmpty.toList (Presentation.presentationFrames presentation)
  check "fixture has three slides" (length frames == 3)
  check "stable frame ids" (fmap (Presentation.frameIdText . Presentation.frameId) frames == ["opening", "questions", "finish"])
  let syntax = Document.documentSyntax document
  check "all slides retain notes" (all (maybe False (const True) . slideNote) (deckSlides syntax))
  openingId <- requireEither "opening id" (Presentation.mkFrameId "opening")
  sourceId <- require "source node id" (Canvas.nodeId "source")
  headlineId <- require "headline node id" (Canvas.nodeId "headline")
  let destination = Canvas.point (Canvas.canvasUnit 12) (Canvas.canvasUnit 6)
      move node =
        Canvas.MoveElement
          (Canvas.NodeElement node)
          (Canvas.AbsolutePlacement destination Canvas.Centre)
      expectedMoved = replaceOnce fixture "(source) at (11,7)" "(source) at (12,6)"
  moved <- requireEither "direct centre move succeeds" (applyDeckCanvasEdit openingId (move sourceId) document)
  check
    "parent lift changes only exact coordinate spelling"
    (Source.snapshotBytes (Document.documentSource moved) == expectedMoved)
  let headlineDestination = Canvas.point (Canvas.canvasUnit 3) (Canvas.canvasUnit 7)
      headlineMove =
        Canvas.MoveElement
          (Canvas.NodeElement headlineId)
          (Canvas.AbsolutePlacement headlineDestination Canvas.NorthWest)
      expectedHeadline = replaceOnce fixture "(headline) at (1,8)" "(headline) at (3,7)"
  check
    "real headline retains writable north-west anchor provenance"
    ( writableNodePlacement openingId headlineId document
        == Just (Canvas.AbsolutePlacement (Canvas.point (Canvas.canvasUnit 1) (Canvas.canvasUnit 8)) Canvas.NorthWest)
    )
  movedHeadline <- requireEither "real headline direct-anchor move succeeds" (applyDeckCanvasEdit openingId headlineMove document)
  check
    "real headline changes only its two coordinate lexemes"
    (Source.snapshotBytes (Document.documentSource movedHeadline) == expectedHeadline)
  check
    "real headline advances exactly one parent revision"
    ( Source.snapshotRevision (Document.documentSource movedHeadline)
        == Source.revisionFromWord64 1
    )
  check
    "real headline reparses to the intended retained anchor destination"
    ( writableNodePlacement openingId headlineId movedHeadline
        == Just (Canvas.AbsolutePlacement headlineDestination Canvas.NorthWest)
    )
  relativeFrame <- requireEither "relative frame id" (Presentation.mkFrameId "a")
  relativeId <- require "relative node id" (Canvas.nodeId "relative")
  let relativeSource option =
        "deck ()\nslide a \"A\" () \"\"\"\\node[anchor=north west, "
          <> option
          <> "] (relative) at (1,1) {R};\"\"\"\n"
      relativeIsReadOnly option =
        let source = relativeSource option
            analyzed = analyzeDeck (Source.snapshotFromBytes source)
         in Source.snapshotBytes (Document.documentSource analyzed) == source
              && writableNodePlacement relativeFrame relativeId analyzed == Nothing
  check "compact relative option remains exact and read-only" (relativeIsReadOnly "above=other")
  check "spaced relative option remains exact and read-only" (relativeIsReadOnly "above = other")
  check "tab and mixed-whitespace relative option remains exact and read-only" (relativeIsReadOnly "above\t =\r\n other")
  let payloadSource =
        "deck ()\nslide a \"A\" () \"\"\"\\node[anchor=north west, label={above = other, below=other}] (relative) at (1,1) {left = right of words};\"\"\"\n"
      payloadDocument = analyzeDeck (Source.snapshotFromBytes payloadSource)
  check
    "relative words in nested option payload and node content do not change writability"
    ( Source.snapshotBytes (Document.documentSource payloadDocument) == payloadSource
        && writableNodePlacement relativeFrame relativeId payloadDocument
          == Just (Canvas.AbsolutePlacement (Canvas.point (Canvas.canvasUnit 1) (Canvas.canvasUnit 1)) Canvas.NorthWest)
    )
  let unknownAnchor =
        "deck ()\nslide a \"A\" () \"\"\"\\node[anchor=somewhere] (relative) at (1,1) {R};\"\"\"\n"
      duplicateAnchor = relativeSource "anchor=south"
  check
    "unknown anchor still fails closed"
    (Document.documentSemantic (analyzeDeck (Source.snapshotFromBytes unknownAnchor)) == Nothing)
  check
    "duplicate anchor still fails closed"
    (Document.documentSemantic (analyzeDeck (Source.snapshotFromBytes duplicateAnchor)) == Nothing)
  let sameNodeAcrossSlides =
        "deck ()\nslide a \"A\" () \"\"\"\\node (same) at (1,1) {A};\"\"\"\nslide b \"B\" () \"\"\"\\node (same) at (2,2) {B};\"\"\"\n"
      duplicateNodeWithinSlide =
        "deck ()\nslide a \"A\" () \"\"\"\\node (same) at (1,1) {A};\\node (same) at (2,2) {B};\"\"\"\n"
  check
    "same node id across slides is admitted"
    (Document.documentSemantic (analyzeDeck (Source.snapshotFromBytes sameNodeAcrossSlides)) /= Nothing)
  check
    "duplicate node id within one slide rejects atomically"
    (Document.documentSemantic (analyzeDeck (Source.snapshotFromBytes duplicateNodeWithinSlide)) == Nothing)
  let revision = Source.snapshotRevision (Document.documentSource document)
  opening <- require "opening frame" (case frames of value : _ -> Just value; [] -> Nothing)
  inserted <- requireEither "insert succeeds" (insertSlideAfter revision (Presentation.frameId opening) document)
  let insertedBytes = Source.snapshotBytes (Document.documentSource inserted)
      exactInsertion = "\n\nslide slide-4 \"Untitled\" (\n) \"\"\"\n\n\"\"\"\n"
  check
    "insertion is one exact deterministic parent replacement"
    (replaceOnce insertedBytes exactInsertion ByteString.empty == fixture)
  insertedPresentation <- require "inserted deck ready" (Document.documentSemantic inserted)
  check "insert adds exactly one frame" (NonEmpty.length (Presentation.presentationFrames insertedPresentation) == 4)
  let duplicate = "deck ()\nslide same \"A\" () \"\"\"\"\"\"\nslide same \"B\" () \"\"\"\"\"\"\n"
      malformed = "deck ()\nslide a \"A\" () \"\"\"unterminated"
  check "duplicate ids reject atomically" (Document.documentSemantic (analyzeDeck (Source.snapshotFromBytes duplicate)) == Nothing)
  check "malformed structure rejects atomically" (Document.documentSemantic (analyzeDeck (Source.snapshotFromBytes malformed)) == Nothing)

check :: String -> Bool -> IO ()
check label condition = if condition then putStrLn ("PASS " <> label) else putStrLn ("FAIL " <> label) >> exitFailure

require :: String -> Maybe value -> IO value
require label value = case value of
  Just result -> pure result
  Nothing -> putStrLn ("FAIL " <> label) >> exitFailure

requireEither :: String -> Either failure value -> IO value
requireEither label value = case value of
  Right result -> pure result
  Left _ -> putStrLn ("FAIL " <> label) >> exitFailure

replaceOnce :: ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString
replaceOnce source needle replacement =
  let (prefix, remainder) = ByteString.breakSubstring needle source
      suffix = ByteString.drop (ByteString.length needle) remainder
   in if ByteString.null remainder || needle `ByteString.isInfixOf` suffix
        then source
        else prefix <> replacement <> suffix
