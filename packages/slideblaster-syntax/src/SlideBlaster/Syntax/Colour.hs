{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Colour
-- Description : xcolor semantics, modelled rather than parsed from the package.
--
-- A 'ColourExpr' is authored syntax: it records that the author wrote
-- @red!50!black@ and nothing more. This module supplies the /meaning/ of that
-- expression, which is what makes the tree abstract rather than concrete: the
-- data needed to interpret and run the construct lives with it.
--
-- The semantics implemented are xcolor's, not an approximation of them:
--
-- * @c!p@ is @c!p!white@, so @red!50@ is red tinted halfway to white;
-- * @c!p!d@ is the convex combination @p\/100@ of @c@ with @d@;
-- * @-c@ complements each channel;
-- * arithmetic is exact 'Rational' throughout and only the final conversion to
--   8-bit channels rounds, so @red!33!blue@ does not drift.
--
-- Two colour types are deliberate. 'ExactColour' is the domain value, closed
-- under mixing and exact; 'Rgb' is the quantised result a renderer wants.
-- Mixing quantised bytes would accumulate error, so quantisation happens once,
-- last.
--
-- The palette is xcolor's 19 always-available base colours, checked against the
-- xcolor manual. Extending the model is adding a table entry, never changing the
-- resolver: that is the point of modelling the package instead of reading its
-- sources. A future @\\definecolor@ supplies additional 'ExactColour' bindings
-- through the same lookup.
--
-- Resolution is total but fallible, and failure is typed: an unknown colour name
-- is a fact about the document, not a crash, and callers decide whether it
-- degrades a run or reports a diagnostic.
module SlideBlaster.Syntax.Colour
  ( ExactColour
  , exactColour
  , exactRed
  , exactGreen
  , exactBlue
  , Rgb (..)
  , quantiseColour
  , rgbToHex
  , ColourError (..)
  , resolveColour
  , resolveColourExact
  , basePalette
  , lookupBaseColour
  ) where

import SlideBlaster.Syntax.Number (clampUnit, hexText, rationalText)
import SlideBlaster.Syntax.Style
  ( ColourExpr (..)
  , ColourModel (..)
  , Literal (..)
  )

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word8)

-- | An exact colour, each channel in the closed unit interval.
--
-- Construct with 'exactColour', which clamps, so an out-of-range channel is
-- unrepresentable.
data ExactColour = ExactColour !Rational !Rational !Rational
  deriving stock (Eq, Ord, Show)

-- | Build an exact colour, clamping each channel to the unit interval.
exactColour :: Rational -> Rational -> Rational -> ExactColour
exactColour r g b = ExactColour (clampUnit r) (clampUnit g) (clampUnit b)

exactRed :: ExactColour -> Rational
exactRed (ExactColour value _ _) = value

exactGreen :: ExactColour -> Rational
exactGreen (ExactColour _ value _) = value

exactBlue :: ExactColour -> Rational
exactBlue (ExactColour _ _ value) = value

-- | A resolved 8-bit sRGB colour, ready for any renderer.
data Rgb = Rgb
  { rgbRed :: !Word8
  , rgbGreen :: !Word8
  , rgbBlue :: !Word8
  }
  deriving stock (Eq, Ord, Show)

-- | Quantise to 8 bits per channel, rounding half up on the exact value.
quantiseColour :: ExactColour -> Rgb
quantiseColour (ExactColour r g b) = Rgb (channel r) (channel g) (channel b)
  where
    channel value = fromIntegral (floor (value * 255 + 1 / 2) :: Integer)

-- | Format as a CSS hex triplet, including the leading @#@.
rgbToHex :: Rgb -> Text
rgbToHex colour =
  "#"
    <> component (rgbRed colour)
    <> component (rgbGreen colour)
    <> component (rgbBlue colour)
  where
    component value =
      Text.pack
        [ hexDigit (fromIntegral value `div` 16)
        , hexDigit (fromIntegral value `mod` 16)
        ]
    hexDigit value
      | value < 10 = toEnum (fromEnum '0' + value)
      | otherwise = toEnum (fromEnum 'a' + value - 10)

-- | Why a colour expression has no meaning.
data ColourError
  = -- | The name is not in the palette and was never defined.
    UnknownColourName !Text
  | -- | The literal payload does not match its declared model.
    MalformedColourLiteral !ColourModel !Text
  deriving stock (Eq, Show)

-- | Resolve an authored colour expression to 8-bit sRGB.
resolveColour :: ColourExpr -> Either ColourError Rgb
resolveColour expression = quantiseColour <$> resolveColourExact expression

-- | Resolve without quantising, for callers that mix further.
resolveColourExact :: ColourExpr -> Either ColourError ExactColour
resolveColourExact expression =
  case expression of
    ColourName name -> namedColour name
    ColourLiteral model payload -> literalColour model payload
    -- xcolor defines @c!p@ as @c!p!white@; a tint is not a separate operation.
    ColourTint base percentage -> do
      resolved <- resolveColourExact base
      pure (mixExact (fraction percentage) resolved white)
    ColourMix base percentage other -> do
      resolvedBase <- resolveColourExact base
      resolvedOther <- resolveColourExact other
      pure (mixExact (fraction percentage) resolvedBase resolvedOther)
    ColourComplement base -> complementExact <$> resolveColourExact base

-- | A percentage literal carries the authored number on a 0..100 scale, so the
-- weight is that number over one hundred, clamped as xcolor clamps it.
fraction :: Literal Rational -> Rational
fraction percentage = clampUnit (literalValue percentage / 100)

white :: ExactColour
white = ExactColour 1 1 1

mixExact :: Rational -> ExactColour -> ExactColour -> ExactColour
mixExact weight (ExactColour r1 g1 b1) (ExactColour r2 g2 b2) =
  exactColour (blend r1 r2) (blend g1 g2) (blend b1 b2)
  where
    blend first second = weight * first + (1 - weight) * second

complementExact :: ExactColour -> ExactColour
complementExact (ExactColour r g b) = exactColour (1 - r) (1 - g) (1 - b)

namedColour :: Text -> Either ColourError ExactColour
namedColour name =
  case lookupBaseColour name of
    Just found -> Right found
    Nothing -> Left (UnknownColourName name)

-- | Resolve a base palette entry by name.
lookupBaseColour :: Text -> Maybe ExactColour
lookupBaseColour name = Map.lookup name basePalette

literalColour :: ColourModel -> Text -> Either ColourError ExactColour
literalColour model payload =
  case model of
    NamedModel -> namedColour payload
    GrayModel ->
      case rationalText (Text.strip payload) of
        Just level -> Right (exactColour level level level)
        Nothing -> malformed
    RgbModel ->
      case traverse (rationalText . Text.strip) (Text.split (== ',') payload) of
        Just [r, g, b] -> Right (exactColour r g b)
        _ -> malformed
    HtmlModel ->
      case hexText 6 (Text.strip payload) of
        Just value ->
          Right
            ( exactColour
                (byteFraction (value `div` 65536))
                (byteFraction ((value `div` 256) `mod` 256))
                (byteFraction (value `mod` 256))
            )
        Nothing -> malformed
  where
    malformed = Left (MalformedColourLiteral model payload)
    byteFraction value = fromIntegral value / 255

-- | xcolor's 19 always-available colours.
--
-- Grays are defined in the gray model and the rest in rgb, matching the manual;
-- cyan, magenta and yellow are the cmyk primaries, which convert exactly.
basePalette :: Map Text ExactColour
basePalette =
  Map.fromList
    [ ("red", ExactColour 1 0 0)
    , ("green", ExactColour 0 1 0)
    , ("blue", ExactColour 0 0 1)
    , ("cyan", ExactColour 0 1 1)
    , ("magenta", ExactColour 1 0 1)
    , ("yellow", ExactColour 1 1 0)
    , ("black", gray 0)
    , ("darkgray", gray (1 / 4))
    , ("gray", gray (1 / 2))
    , ("lightgray", gray (3 / 4))
    , ("white", gray 1)
    , ("brown", ExactColour (3 / 4) (1 / 2) (1 / 4))
    , ("lime", ExactColour (3 / 4) 1 0)
    , ("olive", ExactColour (1 / 2) (1 / 2) 0)
    , ("orange", ExactColour 1 (1 / 2) 0)
    , ("pink", ExactColour 1 (3 / 4) (3 / 4))
    , ("purple", ExactColour (3 / 4) 0 (1 / 4))
    , ("teal", ExactColour 0 (1 / 2) (1 / 2))
    , ("violet", ExactColour (1 / 2) 0 (1 / 2))
    ]
  where
    gray level = ExactColour level level level
