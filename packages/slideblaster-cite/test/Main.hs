{-# LANGUAGE OverloadedStrings #-}

-- | Laws for the BibTeX reader and citation labels.
module Main (main) where

import SlideBlaster.Cite

import Control.Monad (forM)
import Data.Text (Text)
import System.Exit (exitFailure)

main :: IO ()
main = do
  results <- forM laws $ \(name, ok) -> do
    putStrLn ((if ok then "ok   " else "FAIL ") <> name)
    pure ok
  if and results then putStrLn ("all " <> show (length results) <> " laws hold") else exitFailure

sample :: Text
sample =
  "@comment{ignored}\n\
  \@article{dijkstra1970,\n  author = {Dijkstra, Edsger W.},\n  title = {Notes on {Structured} Programming},\n  year = 1970\n}\n\
  \@inproceedings{p4ltl, author = \"Alice Smith and Bob Jones\", year = {2023}, title = \"T\"}\n\
  \@misc{three, author={A One and B Two and C Three}, year={2020}}\n"

bibliography :: Bibliography
bibliography = fst (readBibliography sample)

laws :: [(String, Bool)]
laws =
  [ ("reads three entries in order", fmap entryKey (bibliographyEntries bibliography) == ["dijkstra1970", "p4ltl", "three"])
  , ("comment entries are skipped", lookupEntry "ignored" bibliography == Nothing)
  , ("braced value keeps inner braces", (lookupEntry "dijkstra1970" bibliography >>= entryField "title") == Just "Notes on {Structured} Programming")
  , ("bare number value", (lookupEntry "dijkstra1970" bibliography >>= entryField "year") == Just "1970")
  , ("quoted value", (lookupEntry "p4ltl" bibliography >>= entryField "year") == Just "2023")
  , ("surnames from both spellings", fmap authorSurnames (lookupEntry "p4ltl" bibliography) == Just ["Smith", "Jones"])
  , ("duplicate key reported", snd (readBibliography "@misc{a,year=1}\n@misc{a,year=2}") == [BibDuplicateKey "a"])
  , ("unterminated entry reported, not thrown", snd (readBibliography "@misc{a, year=1") == [BibUnterminatedEntry "misc"])
  , ("empty input", bibliographyEntries (fst (readBibliography "")) == [])
  , ("numeric labels by first citation", citationLabels NumericStyle bibliography ["p4ltl", "dijkstra1970", "p4ltl"] == [("p4ltl", Just "[1]"), ("dijkstra1970", Just "[2]")])
  , ("author-year labels", citationLabels AuthorYearStyle bibliography ["dijkstra1970", "p4ltl", "three"] == [("dijkstra1970", Just "Dijkstra, 1970"), ("p4ltl", Just "Smith and Jones, 2023"), ("three", Just "One et al., 2020")])
  , ("unknown key has no label", citationLabels NumericStyle bibliography ["nope"] == [("nope", Nothing)])
  , ("style names", fmap parseCitationStyle ["numeric", "author-year", "x"] == [Just NumericStyle, Just AuthorYearStyle, Nothing])
  ]
