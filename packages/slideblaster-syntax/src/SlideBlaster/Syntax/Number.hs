-- |
-- Module      : SlideBlaster.Syntax.Number
-- Description : Total numeric conversions for reading and resolving syntax.
--
-- @read@ is partial and is forbidden by the repository style, so every numeric
-- conversion in this package goes through a function here that returns 'Maybe'
-- and never raises. Each accepts exactly the unsigned lexical forms that the
-- dialects admit and rejects everything else, including the empty string.
--
-- Values are exact: percentages and colour components are 'Rational', not
-- floating point, so @12.5@ and @1/8@ survive arithmetic without drift and a
-- resolved colour is reproducible.
module SlideBlaster.Syntax.Number
  ( decimalText
  , rationalText
  , hexText
  , clampUnit
  ) where

import Data.Char (digitToInt, isDigit, isHexDigit)
import Data.Text (Text)
import Data.Text qualified as Text

-- | An unsigned run of decimal digits, such as @2@ in @[2]@.
decimalText :: Text -> Maybe Int
decimalText value
  | Text.null value = Nothing
  | Text.all isDigit value = Just (Text.foldl' step 0 value)
  | otherwise = Nothing
  where
    step accumulated character = accumulated * 10 + digitToInt character

-- | An unsigned decimal literal, such as @50@, @12.5@, or @.5@.
--
-- At most one point, and at least one digit overall.
rationalText :: Text -> Maybe Rational
rationalText value =
  case Text.split (== '.') value of
    [whole] -> integerPart whole
    [whole, fraction] -> do
      wholeValue <- if Text.null whole then Just 0 else integerPart whole
      fractionValue <- fractionPart fraction
      pure (wholeValue + fractionValue)
    _ -> Nothing
  where
    integerPart part
      | Text.null part = Nothing
      | Text.all isDigit part = Just (Text.foldl' step 0 part)
      | otherwise = Nothing

    fractionPart part
      | Text.null part = Just 0
      | Text.all isDigit part =
          Just (Text.foldl' step 0 part / (10 ^ Text.length part))
      | otherwise = Nothing

    step accumulated character =
      accumulated * 10 + fromIntegral (digitToInt character)

-- | A run of hexadecimal digits of exactly the requested length.
hexText :: Int -> Text -> Maybe Int
hexText width value
  | Text.length value /= width = Nothing
  | Text.all isHexDigit value = Just (Text.foldl' step 0 value)
  | otherwise = Nothing
  where
    step accumulated character = accumulated * 16 + digitToInt character

-- | Restrict a value to the closed unit interval, as colour arithmetic requires.
clampUnit :: Rational -> Rational
clampUnit value = max 0 (min 1 value)
