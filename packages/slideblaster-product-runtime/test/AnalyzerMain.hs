{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : The W deck analyzer over the normative sample deck.
module Main (main) where

import SlideBlaster.Product.Runtime.Analysis
import SlideBlaster.Product.Runtime.DeckAnalyzer (deckAnalyzer)
import SlideBlaster.Product.Runtime.MarkdownAnalyzer (markdownAnalyzer)
import SlideBlaster.Canvas.Flow (PictureFrom (..), PictureItem (..), PictureNode (..))
import SlideBlaster.Deck.PictureEdit (PictureOp (..))
import SlideBlaster.Product.Runtime.Picture (libraryFileOf, libraryNames)
import SlideBlaster.Product.Runtime.SlidePlan (FrameInput (..), frameStepCount)

import Control.Monad (unless)
import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import System.Directory (doesFileExist)
import System.Exit (exitFailure)

main :: IO ()
main = do
  deck <- readFirst ["fixtures/corpus/unit/all-features.slideBlaster.md", "../../fixtures/corpus/unit/all-features.slideBlaster.md"]
  let analysis = analyzeDeck deckAnalyzer Map.empty "all-features.slideBlaster.md" deck
      frames = analysisFrames analysis
  expect "frame ids" ["title", "why", "prog", "arch", "results", "refs"] (fmap frameKey frames)
  expect "theme" "fns" (analysisTheme analysis)
  expect "title" "P4Check" (analysisTitle analysis)
  expect "overlay steps of why" [1, 4, 2, 1, 1, 1] (fmap (frameStepCount . frameScene) frames)
  expect "figure request" [("arch", Just "figures/p4checkarch.tikz")] [(figureFrame r, figureInputPath r) | r <- analysisFigures analysis]
  let spans = fmap frameSpan frames
  expect "spans are ordered and disjoint" True (and (zipWith (\(_, e) (s, _) -> e <= s) spans (drop 1 spans)))
  expect "slide spans start at their header" True (and [ByteString.take 3 (ByteString.drop s deck) == "## " | (s, _) <- drop 1 spans])
  expect "last span reaches the end" (ByteString.length deck) (snd (last spans))
  case insertSlideAfter deckAnalyzer deck (Just "prog") of
    Nothing -> failWith "no insertion"
    Just (new, ident) -> do
      let (_, progEnd) = spans !! 2
      expect "pure insertion: prefix kept" (ByteString.take progEnd deck) (ByteString.take progEnd new)
      expect "pure insertion: suffix kept" (ByteString.drop progEnd deck) (ByteString.drop (ByteString.length new - (ByteString.length deck - progEnd)) new)
      let again = analyzeDeck deckAnalyzer Map.empty "x" new
      expect "new frame follows prog" ["title", "why", "prog", ident, "arch", "results", "refs"] (fmap frameKey (analysisFrames again))
  let production = analyzeDeck markdownAnalyzer Map.empty "all-features.slideBlaster.md" deck
  expect "production frame ids" ["title-slide", "why", "prog", "arch", "results", "refs"] (fmap frameKey (analysisFrames production))
  expect "production steps" [1, 4, 2, 1, 1, 1] (fmap (frameStepCount . frameScene) (analysisFrames production))
  expect "production figure" [("arch", Just "figures/p4checkarch.tikz")] [(figureFrame r, figureInputPath r) | r <- analysisFigures production]
  expect "production theme" "fns" (analysisTheme production)
  case insertSlideAfter markdownAnalyzer deck (Just "prog") of
    Nothing -> failWith "production insert refused"
    Just (new, ident) -> do
      let ids = fmap frameKey (analysisFrames (analyzeDeck markdownAnalyzer Map.empty "x" new))
      expect "production insert position" ["title-slide", "why", "prog", ident, "arch", "results", "refs"] ids
  putStrLn "PASS: deck analyzer"
  -- a picture file is a document of its own: one slide, spans in the file, edits byte-exact
  let picture = "% reusable\n\\node[draw] (a) at (2,3) {A};\n\\node (b) at (5,3) {B};" :: ByteString.ByteString
      opened = analyzeDeck markdownAnalyzer Map.empty "figures/arch.tikz" picture
      nodeSpans = [pictureNodeSpan n | f <- analysisFrames opened, PictureNodeItem n <- frameInputPicture (frameScene f)]
  expect "picture file: one slide" ["picture"] (fmap frameKey (analysisFrames opened))
  expect "picture file: ready" True (analysisReady opened)
  expect "picture file: statement spans count in the file (a comment line above belongs to its statement)" ["% reusable\n\\node[draw] (a) at (2,3) {A};", "\\node (b) at (5,3) {B};"] [ByteString.take (e - b) (ByteString.drop b picture) | (b, e) <- nodeSpans]
  expect "picture file: a move rewrites only the point"
    (Right ("% reusable\n\\node[draw] (a) at (7,1.5) {A};\n\\node (b) at (5,3) {B};", []))
    (editPicture markdownAnalyzer Map.empty "figures/arch.tikz" picture "picture" (MoveNode "a" 7 1.5))
  -- and a deck brings it in with \cat, shifted
  let host = "---\nslideblaster: 1\n---\n\n## One {#one}\n\n```slide\n\\cat[shift={(1,-1)}]{figures/arch.tikz};\n```\n" :: ByteString.ByteString
      shown = analyzeDeck markdownAnalyzer (Map.fromList [("figures/arch.tikz", picture)]) "deck.slideBlaster.md" host
  expect "cat: the file's nodes are on the slide, shifted"
    [("a", 3, 2, Just "figures/arch.tikz"), ("b", 6, 2, Just "figures/arch.tikz")]
    [(pictureNodeId n, pictureNodeX n, pictureNodeY n, fromFile <$> pictureNodeFrom n) | f <- analysisFrames shown, PictureNodeItem n <- frameInputPicture (frameScene f)]
  putStrLn "PASS: picture files"
  -- library shapes: a dotted style name is defined in shapes/<family>.tikz, or by the deck itself
  let shapeFile = "% a library\n\\tikzset{flow.decision/.style={outline={M 0.5 0 L 1 0.5 L 0.5 1 L 0 0.5 Z}, minimum width=2.4}}\n\\tikzset{flow.other/.style={outline={M 0 0 L 1 1}}}\n" :: ByteString.ByteString
      shapeDeck = "---\nslideblaster: 1\npreamble: |\n  \\tikzset{mine.kite/.style={outline={M 0 0 L 1 0 Z}, fill=red}}\n---\n\n## One {#one}\n\n```slide\n\\node[flow.decision, fill=blue] (a) at (2,3) {A};\n\\node[mine.kite] (b) at (5,3) {B};\n\\node[nosuch.thing, draw] (c) at (8,3) {C};\n```\n" :: ByteString.ByteString
      optionsWith files = [(pictureNodeId n, pictureNodeOptions n) | f <- analysisFrames (analyzeDeck markdownAnalyzer files "deck.slideBlaster.md" shapeDeck), PictureNodeItem n <- frameInputPicture (frameScene f)]
  expect "shapes: a library style stands for its definition; the node's own options come after it"
    [ ("a", "outline={M 0.5 0 L 1 0.5 L 0.5 1 L 0 0.5 Z}, minimum width=2.4, fill=blue")
    , ("b", "outline={M 0 0 L 1 0 Z}, fill=red")
    , ("c", "nosuch.thing, draw")
    ]
    (optionsWith (Map.fromList [("shapes/flow.tikz", shapeFile)]))
  expect "shapes: without the library file the name stays as written" (Just "flow.decision, fill=blue") (lookup "a" (optionsWith Map.empty))
  expect "shapes: library names and their files"
    (["flow.decision", "a.b-c.d"], [Just "shapes/flow.tikz", Nothing, Nothing, Nothing])
    (libraryNames "draw, flow.decision, fill=a.b, a.b-c.d, plain", fmap libraryFileOf ["flow.decision", "plain", "a..b", "a b.c"])
  putStrLn "PASS: library shapes"
  where
    readFirst [] = putStrLn "FAIL: sample deck not found" >> exitFailure
    readFirst (path : more) = do
      present <- doesFileExist path
      if present then ByteString.readFile path else readFirst more
    failWith m = putStrLn ("FAIL: " <> m) >> exitFailure
    expect :: (Eq a, Show a) => String -> a -> a -> IO ()
    expect label e a = unless (e == a) (putStrLn ("FAIL: " <> label <> "\n  expected: " <> show e <> "\n  actual:   " <> show a) >> exitFailure)
