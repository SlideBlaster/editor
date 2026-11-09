{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : The W deck analyzer over the normative sample deck.
module Main (main) where

import SlideBlaster.Product.Runtime.Analysis
import SlideBlaster.Product.Runtime.DeckAnalyzer (deckAnalyzer)
import SlideBlaster.Product.Runtime.MarkdownAnalyzer (markdownAnalyzer)
import SlideBlaster.Product.Runtime.SlidePlan (frameStepCount)

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
  where
    readFirst [] = putStrLn "FAIL: sample deck not found" >> exitFailure
    readFirst (path : more) = do
      present <- doesFileExist path
      if present then ByteString.readFile path else readFirst more
    failWith m = putStrLn ("FAIL: " <> m) >> exitFailure
    expect :: (Eq a, Show a) => String -> a -> a -> IO ()
    expect label e a = unless (e == a) (putStrLn ("FAIL: " <> label <> "\n  expected: " <> show e <> "\n  actual:   " <> show a) >> exitFailure)
