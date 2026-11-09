{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.TikZ.Internal.Decimal
-- Description : Exact bounded decimal coordinates for the Slice 1 TikZ subset.
--
-- Coordinates are normalized fixed-point values. The concrete reader accepts
-- deliberately bounded decimal tokens, while the renderer emits one canonical
-- finite decimal spelling. No floating-point conversion occurs.
module SlideBlaster.TikZ.Internal.Decimal
  ( Coordinate
  , CoordinateError (..)
  , coordinateFromDecimalText
  , coordinateFromInteger
  , coordinateFromScaled
  , coordinateFromRational
  , coordinateToRational
  , coordinateToText
  , parseCoordinateBytes
  , renderCoordinateBytes
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Ratio (denominator, numerator)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Word (Word8)

-- | A normalized decimal coefficient and base-10 fractional scale.
data Coordinate = Coordinate !Integer !Word8
  deriving (Eq)

instance Show Coordinate where
  show value = "Coordinate " <> show (coordinateToText value)

instance Ord Coordinate where
  compare
    (Coordinate leftCoefficient leftScale)
    (Coordinate rightCoefficient rightScale) =
      compare
        (leftCoefficient * (10 ^ rightScale))
        (rightCoefficient * (10 ^ leftScale))

-- | Explain why a value cannot enter the bounded decimal domain.
data CoordinateError
  = CoordinateEmpty
  | CoordinateMissingIntegerDigits
  | CoordinateMissingFractionDigits
  | CoordinateInvalidCharacter
  | CoordinateTooManyDigits !Int
  | CoordinateTooPrecise !Int
  | CoordinateNotFiniteDecimal
  deriving (Eq, Show)

-- | Construct an integral coordinate.
coordinateFromInteger :: Integer -> Coordinate
coordinateFromInteger coefficient = Coordinate coefficient 0

-- | Construct and normalize a scaled integer when its precision is supported.
coordinateFromScaled :: Integer -> Word8 -> Either CoordinateError Coordinate
coordinateFromScaled coefficient scale
  | scale > maximumFractionDigits =
      Left (CoordinateTooPrecise (fromIntegral scale))
  | decimalDigitCount coefficient > maximumDigits =
      Left (CoordinateTooManyDigits (decimalDigitCount coefficient))
  | otherwise = Right (normalizeCoordinate coefficient scale)

-- | Convert an exact rational only when it has a bounded finite decimal form.
coordinateFromRational :: Rational -> Either CoordinateError Coordinate
coordinateFromRational value =
  findScale 0 1
  where
    valueNumerator = numerator value
    valueDenominator = denominator value

    findScale scale multiplier
      | multiplier `rem` valueDenominator == 0 =
          coordinateFromScaled
            (valueNumerator * (multiplier `quot` valueDenominator))
            scale
      | scale == maximumFractionDigits = Left CoordinateNotFiniteDecimal
      | otherwise = findScale (scale + 1) (multiplier * 10)

-- | Parse a public textual decimal using the same grammar as authored source.
coordinateFromDecimalText :: Text -> Either CoordinateError Coordinate
coordinateFromDecimalText = parseCoordinateBytes . Text.Encoding.encodeUtf8

-- | Parse one exact ASCII decimal token.
parseCoordinateBytes :: ByteString -> Either CoordinateError Coordinate
parseCoordinateBytes input
  | ByteString.null input = Left CoordinateEmpty
  | otherwise = do
      let (sign, unsigned) = splitSign input
          (integerDigits, decimalAndFraction) =
            ByteString.break (== decimalPoint) unsigned
      if ByteString.null integerDigits
        then Left CoordinateMissingIntegerDigits
        else pure ()
      ensureDigits integerDigits
      fractionDigits <-
        if ByteString.null decimalAndFraction
          then Right ByteString.empty
          else do
            let fraction = ByteString.drop 1 decimalAndFraction
            if ByteString.null fraction
              then Left CoordinateMissingFractionDigits
              else pure ()
            if ByteString.elem decimalPoint fraction
              then Left CoordinateInvalidCharacter
              else pure ()
            ensureDigits fraction
            Right fraction
      let digitCount =
            ByteString.length integerDigits + ByteString.length fractionDigits
          fractionCount = ByteString.length fractionDigits
      if digitCount > maximumDigits
        then Left (CoordinateTooManyDigits digitCount)
        else pure ()
      if fractionCount > fromIntegral maximumFractionDigits
        then Left (CoordinateTooPrecise fractionCount)
        else pure ()
      let unsignedCoefficient =
            decimalDigitsValue (integerDigits <> fractionDigits)
          coefficient = sign * unsignedCoefficient
      Right
        ( normalizeCoordinate
            coefficient
            (fromIntegral fractionCount)
        )

-- | Return the exact rational meaning without floating-point conversion.
coordinateToRational :: Coordinate -> Rational
coordinateToRational (Coordinate coefficient scale) =
  fromInteger coefficient / fromInteger (10 ^ scale)

-- | Emit the canonical decimal spelling used only for a rewritten slot.
renderCoordinateBytes :: Coordinate -> ByteString
renderCoordinateBytes = Text.Encoding.encodeUtf8 . coordinateToText

-- | Return the canonical human-readable decimal spelling.
coordinateToText :: Coordinate -> Text
coordinateToText (Coordinate coefficient scale)
  | scale == 0 = Text.pack (show coefficient)
  | otherwise =
      signText
        <> Text.pack wholeDigits
        <> "."
        <> Text.pack fractionalDigits
  where
    signText :: Text
    signText
      | coefficient < 0 = "-"
      | otherwise = ""
    magnitudeDigits = show (abs coefficient)
    scaleLength = fromIntegral scale
    paddedDigits =
      replicate (max 0 (scaleLength + 1 - length magnitudeDigits)) '0'
        <> magnitudeDigits
    splitPosition = length paddedDigits - scaleLength
    (wholeDigits, fractionalDigits) = splitAt splitPosition paddedDigits

maximumDigits :: Int
maximumDigits = 18

maximumFractionDigits :: Word8
maximumFractionDigits = 9

decimalPoint :: Word8
decimalPoint = 46

decimalDigitCount :: Integer -> Int
decimalDigitCount value = length (show (abs value))
splitSign :: ByteString -> (Integer, ByteString)
splitSign bytes =
  case ByteString.uncons bytes of
    Just (43, rest) -> (1, rest)
    Just (45, rest) -> (-1, rest)
    _ -> (1, bytes)

ensureDigits :: ByteString -> Either CoordinateError ()
ensureDigits bytes
  | ByteString.all isAsciiDigit bytes = Right ()
  | otherwise = Left CoordinateInvalidCharacter

isAsciiDigit :: Word8 -> Bool
isAsciiDigit byte = byte >= 48 && byte <= 57

decimalDigitsValue :: ByteString -> Integer
decimalDigitsValue =
  ByteString.foldl'
    (\value byte -> value * 10 + fromIntegral (byte - 48))
    0

normalizeCoordinate :: Integer -> Word8 -> Coordinate
normalizeCoordinate coefficient scale
  | coefficient == 0 = Coordinate 0 0
  | scale > 0 && coefficient `rem` 10 == 0 =
      normalizeCoordinate (coefficient `quot` 10) (scale - 1)
  | otherwise = Coordinate coefficient scale
