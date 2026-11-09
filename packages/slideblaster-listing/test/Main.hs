{-# LANGUAGE OverloadedStrings #-}

-- | Laws for the listing model and highlight grammar.
module Main (main) where

import SlideBlaster.Listing

import Control.Monad (forM)
import Data.Text (Text)
import System.Exit (exitFailure)

main :: IO ()
main = do
  results <- forM laws $ \(name, ok) -> do
    putStrLn ((if ok then "ok   " else "FAIL ") <> name)
    pure ok
  if and results then putStrLn ("all " <> show (length results) <> " laws hold") else exitFailure

spec :: Text -> Maybe HighlightSpec
spec = either (const Nothing) Just . parseHighlightSpec

laws :: [(String, Bool)]
laws =
  [ ("spec '1,3-5|7' has two steps", fmap highlightStepCount (spec "1,3-5|7") == Just 2)
  , ("step one is 1,3-5", fmap (highlightedAt 1) (spec "1,3-5|7") == Just [LineRange 1 1, LineRange 3 5])
  , ("step two is 7", fmap (highlightedAt 2) (spec "1,3-5|7") == Just [LineRange 7 7])
  , ("line 4 highlighted at step 1", fmap (isHighlightedAt 1 4) (spec "1,3-5|7") == Just True)
  , ("line 4 not highlighted at step 2", fmap (isHighlightedAt 2 4) (spec "1,3-5|7") == Just False)
  , ("beyond the last step highlights nothing", fmap (highlightedAt 3) (spec "1|2") == Just [])
  , ("step zero highlights nothing", fmap (highlightedAt 0) (spec "1|2") == Just [])
  , ("empty spec has one step and no highlight", fmap highlightStepCount (spec "") == Just 1 && fmap (highlightedAt 1) (spec "") == Just [])
  , ("zero line rejected", parseHighlightSpec "0" == Left HighlightZeroLine)
  , ("reversed range rejected", parseHighlightSpec "5-3" == Left (HighlightReversed 5 3))
  , ("malformed item rejected", parseHighlightSpec "a" == Left (HighlightMalformed "a"))
  , ("empty item rejected", parseHighlightSpec "1,,2" == Left HighlightEmptyItem)
  , ("canonical print", fmap printHighlightSpec (spec "1, 3-5 | 7") == Just "1,3-5|7")
  , ("print then parse is stable", fmap (spec . printHighlightSpec) (spec "2|3-4") == Just (spec "2|3-4"))
  , ("listing lines drop the final newline", fmap listingLines (either (const Nothing) Just (mkListing "p4" "a\nb\n" Nothing False)) == Just ["a", "b"])
  , ("empty code has no lines", fmap listingLines (either (const Nothing) Just (mkListing "" "" Nothing False)) == Just [])
  , ("mkListing rejects a bad spec", either (const True) (const False) (mkListing "p4" "x" (Just "x") False))
  ]
