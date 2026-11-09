-- |
-- Module      : SlideBlaster.Render.Style
-- Description : Direct, target-neutral render styles.
--
-- Render styles contain only concrete values. Palette keys, theme font
-- sentinels, authored role defaults, and source option precedence must all be
-- resolved before constructing these values.
module SlideBlaster.Render.Style
  ( RenderColour (..)
  , RenderOpacity
  , mkRenderOpacity
  , renderOpacityValue
  , opaqueRenderOpacity
  , RenderGradientOffset
  , mkRenderGradientOffset
  , renderGradientOffsetValue
  , RenderGradientStop (..)
  , RenderPaint
  , RenderPaintView (..)
  , noRenderPaint
  , solidRenderPaint
  , mkLinearRenderGradient
  , mkRadialRenderGradient
  , renderPaintView
  , RenderDashPattern
  , RenderDashPatternView (..)
  , renderSolidDash
  , mkRenderCustomDash
  , renderDashPatternView
  , RenderLineCap (..)
  , RenderLineJoin (..)
  , RenderStroke
  , RenderStrokeView (..)
  , noRenderStroke
  , mkRenderStroke
  , renderStrokeView
  , RenderShadow
  , mkRenderShadow
  , renderShadowBlur
  , renderShadowColour
  , renderShadowOffset
  , renderShadowSpread
  , RenderShapeStyle (..)
  , RenderFontWeight (..)
  , RenderFontPosture (..)
  , RenderTextDecoration (..)
  , RenderHorizontalAlignment (..)
  , RenderVerticalAlignment (..)
  , RenderTypography
  , RenderStyleError (..)
  , mkRenderTypography
  , renderTypographyColour
  , renderTypographyDecoration
  , renderTypographyFamily
  , renderTypographyHorizontal
  , renderTypographyLineSpacing
  , renderTypographyPosture
  , renderTypographySize
  , renderTypographyVertical
  , renderTypographyWeight
  , renderTypographyResourceReferences
  ) where

import SlideBlaster.Canvas
  ( CanvasUnit
  , Point
  , Vector
  , canvasUnitValue
  )
import SlideBlaster.Render.Resource
  ( ResourceId
  , ResourceReference (..)
  , ResourceReferenceKind (FontReference)
  )

import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Word (Word16, Word8)

-- | Direct RGBA colour. There is no palette indirection in a render value.
data RenderColour = RenderColour !Word8 !Word8 !Word8 !Word8
  deriving stock (Eq, Ord, Show)

newtype RenderOpacity = RenderOpacity Rational
  deriving stock (Eq, Ord, Show)

mkRenderOpacity :: Rational -> Maybe RenderOpacity
mkRenderOpacity value
  | value >= 0 && value <= 1 = Just (RenderOpacity value)
  | otherwise = Nothing

renderOpacityValue :: RenderOpacity -> Rational
renderOpacityValue (RenderOpacity value) = value

opaqueRenderOpacity :: RenderOpacity
opaqueRenderOpacity = RenderOpacity 1

-- | One normalized offset along a gradient vector or radius.
newtype RenderGradientOffset = RenderGradientOffset Rational
  deriving stock (Eq, Ord, Show)

mkRenderGradientOffset :: Rational -> Maybe RenderGradientOffset
mkRenderGradientOffset value
  | value >= 0 && value <= 1 = Just (RenderGradientOffset value)
  | otherwise = Nothing

renderGradientOffsetValue :: RenderGradientOffset -> Rational
renderGradientOffsetValue (RenderGradientOffset value) = value

-- | One direct gradient colour at a normalized offset. The containing paint
-- smart constructor validates stop ordering.
data RenderGradientStop
  = RenderGradientStop !RenderGradientOffset !RenderColour
  deriving stock (Eq, Ord, Show)

data RenderPaint
  = NoRenderPaint
  | SolidRenderPaint !RenderColour
  | LinearRenderGradient
      !Point
      !Point
      !(NonEmpty RenderGradientStop)
  | RadialRenderGradient
      !Point
      !CanvasUnit
      !(NonEmpty RenderGradientStop)
  deriving stock (Eq, Ord, Show)

-- | Public inspection form for an already-validated paint.
data RenderPaintView
  = NoRenderPaintView
  | SolidRenderPaintView !RenderColour
  | LinearRenderGradientView
      !Point
      !Point
      !(NonEmpty RenderGradientStop)
  | RadialRenderGradientView
      !Point
      !CanvasUnit
      !(NonEmpty RenderGradientStop)
  deriving stock (Eq, Ord, Show)

noRenderPaint :: RenderPaint
noRenderPaint = NoRenderPaint

solidRenderPaint :: RenderColour -> RenderPaint
solidRenderPaint = SolidRenderPaint

mkLinearRenderGradient
  :: Point
  -> Point
  -> NonEmpty RenderGradientStop
  -> Either RenderStyleError RenderPaint
mkLinearRenderGradient start end stops = do
  validateGradientStops stops
  if start == end
    then Left RenderLinearGradientNeedsDistinctPoints
    else Right (LinearRenderGradient start end stops)

mkRadialRenderGradient
  :: Point
  -> CanvasUnit
  -> NonEmpty RenderGradientStop
  -> Either RenderStyleError RenderPaint
mkRadialRenderGradient centre radius stops
  | canvasUnitValue radius <= 0 =
      Left (RenderGradientRadiusMustBePositive radius)
  | otherwise = do
      validateGradientStops stops
      Right (RadialRenderGradient centre radius stops)

renderPaintView :: RenderPaint -> RenderPaintView
renderPaintView paint =
  case paint of
    NoRenderPaint -> NoRenderPaintView
    SolidRenderPaint colour -> SolidRenderPaintView colour
    LinearRenderGradient start end stops ->
      LinearRenderGradientView start end stops
    RadialRenderGradient centre radius stops ->
      RadialRenderGradientView centre radius stops

data RenderDashPattern
  = RenderSolidDash
  | RenderCustomDash !(NonEmpty CanvasUnit)
  deriving stock (Eq, Ord, Show)

data RenderDashPatternView
  = RenderSolidDashView
  | RenderCustomDashView !(NonEmpty CanvasUnit)
  deriving stock (Eq, Ord, Show)

renderSolidDash :: RenderDashPattern
renderSolidDash = RenderSolidDash

mkRenderCustomDash
  :: NonEmpty CanvasUnit
  -> Either RenderStyleError RenderDashPattern
mkRenderCustomDash values
  | any ((<= 0) . canvasUnitValue) values =
      Left (RenderDashLengthsMustBePositive values)
  | otherwise = Right (RenderCustomDash values)

renderDashPatternView :: RenderDashPattern -> RenderDashPatternView
renderDashPatternView dash =
  case dash of
    RenderSolidDash -> RenderSolidDashView
    RenderCustomDash values -> RenderCustomDashView values

data RenderLineCap
  = RenderButtCap
  | RenderRoundCap
  | RenderSquareCap
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderLineJoin
  = RenderMiterJoin
  | RenderRoundJoin
  | RenderBevelJoin
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderStroke
  = NoRenderStroke
  | RenderStroke
      !RenderColour
      !CanvasUnit
      !RenderDashPattern
      !RenderLineCap
      !RenderLineJoin
  deriving stock (Eq, Ord, Show)

data RenderStrokeView
  = NoRenderStrokeView
  | RenderStrokeView
      !RenderColour
      !CanvasUnit
      !RenderDashPattern
      !RenderLineCap
      !RenderLineJoin
  deriving stock (Eq, Ord, Show)

noRenderStroke :: RenderStroke
noRenderStroke = NoRenderStroke

mkRenderStroke
  :: RenderColour
  -> CanvasUnit
  -> RenderDashPattern
  -> RenderLineCap
  -> RenderLineJoin
  -> Either RenderStyleError RenderStroke
mkRenderStroke colour width dash cap join
  | canvasUnitValue width <= 0 =
      Left (RenderStrokeWidthMustBePositive width)
  | otherwise = Right (RenderStroke colour width dash cap join)

renderStrokeView :: RenderStroke -> RenderStrokeView
renderStrokeView stroke =
  case stroke of
    NoRenderStroke -> NoRenderStrokeView
    RenderStroke colour width dash cap join ->
      RenderStrokeView colour width dash cap join

data RenderShadow = RenderShadow
  { renderShadowOffset :: !Vector
  , renderShadowBlur :: !CanvasUnit
  , renderShadowSpread :: !CanvasUnit
  , renderShadowColour :: !RenderColour
  }
  deriving stock (Eq, Ord, Show)

mkRenderShadow
  :: Vector
  -> CanvasUnit
  -> CanvasUnit
  -> RenderColour
  -> Either RenderStyleError RenderShadow
mkRenderShadow offset blur spread colour
  | canvasUnitValue blur < 0 =
      Left (RenderShadowBlurMustBeNonNegative blur)
  | canvasUnitValue spread < 0 =
      Left (RenderShadowSpreadMustBeNonNegative spread)
  | otherwise = Right (RenderShadow offset blur spread colour)

data RenderShapeStyle = RenderShapeStyle
  { renderShapePaint :: !RenderPaint
  , renderShapeStroke :: !RenderStroke
  , renderShapeOpacity :: !RenderOpacity
  , renderShapeShadows :: ![RenderShadow]
  }
  deriving stock (Eq, Ord, Show)

data RenderFontWeight
  = RenderWeightNormal
  | RenderWeightBold
  | RenderWeightNumber !Word16
  deriving stock (Eq, Ord, Show)

data RenderFontPosture
  = RenderUpright
  | RenderItalic
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderTextDecoration
  = RenderNoDecoration
  | RenderUnderline
  | RenderStrike
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderHorizontalAlignment
  = RenderAlignLeft
  | RenderAlignCentre
  | RenderAlignRight
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderVerticalAlignment
  = RenderAlignTop
  | RenderAlignMiddle
  | RenderAlignBottom
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Fully resolved typography. A font is always an embedded manifest resource,
-- never a theme sentinel or platform-dependent family lookup.
data RenderTypography = RenderTypography
  !ResourceId
  !CanvasUnit
  !RenderFontWeight
  !RenderFontPosture
  !RenderTextDecoration
  !RenderColour
  !RenderHorizontalAlignment
  !RenderVerticalAlignment
  !Rational
  deriving stock (Eq, Ord, Show)

data RenderStyleError
  = RenderFontSizeMustBePositive !CanvasUnit
  | RenderLineSpacingMustBePositive !Rational
  | RenderFontWeightOutOfRange !Word16
  | RenderGradientStopsOutOfOrder
      !RenderGradientOffset
      !RenderGradientOffset
  | RenderLinearGradientNeedsDistinctPoints
  | RenderGradientRadiusMustBePositive !CanvasUnit
  | RenderDashLengthsMustBePositive !(NonEmpty CanvasUnit)
  | RenderStrokeWidthMustBePositive !CanvasUnit
  | RenderShadowBlurMustBeNonNegative !CanvasUnit
  | RenderShadowSpreadMustBeNonNegative !CanvasUnit
  deriving stock (Eq, Show)

mkRenderTypography
  :: ResourceId
  -> CanvasUnit
  -> RenderFontWeight
  -> RenderFontPosture
  -> RenderTextDecoration
  -> RenderColour
  -> RenderHorizontalAlignment
  -> RenderVerticalAlignment
  -> Rational
  -> Either RenderStyleError RenderTypography
mkRenderTypography
  family
  size
  weight
  posture
  decoration
  colour
  horizontal
  vertical
  lineSpacing
    | canvasUnitValue size <= 0 =
        Left (RenderFontSizeMustBePositive size)
    | lineSpacing <= 0 =
        Left (RenderLineSpacingMustBePositive lineSpacing)
    | RenderWeightNumber number <- weight
    , number < 1 || number > 1000 =
        Left (RenderFontWeightOutOfRange number)
    | otherwise =
        Right
          ( RenderTypography
              family
              size
              weight
              posture
              decoration
              colour
              horizontal
              vertical
              lineSpacing
          )

renderTypographyFamily :: RenderTypography -> ResourceId
renderTypographyFamily (RenderTypography family _ _ _ _ _ _ _ _) = family

renderTypographySize :: RenderTypography -> CanvasUnit
renderTypographySize (RenderTypography _ size _ _ _ _ _ _ _) = size

renderTypographyWeight :: RenderTypography -> RenderFontWeight
renderTypographyWeight (RenderTypography _ _ weight _ _ _ _ _ _) = weight

renderTypographyPosture :: RenderTypography -> RenderFontPosture
renderTypographyPosture (RenderTypography _ _ _ posture _ _ _ _ _) = posture

renderTypographyDecoration :: RenderTypography -> RenderTextDecoration
renderTypographyDecoration
  (RenderTypography _ _ _ _ decoration _ _ _ _) = decoration

renderTypographyColour :: RenderTypography -> RenderColour
renderTypographyColour (RenderTypography _ _ _ _ _ colour _ _ _) = colour

renderTypographyHorizontal
  :: RenderTypography
  -> RenderHorizontalAlignment
renderTypographyHorizontal
  (RenderTypography _ _ _ _ _ _ horizontal _ _) = horizontal

renderTypographyVertical :: RenderTypography -> RenderVerticalAlignment
renderTypographyVertical
  (RenderTypography _ _ _ _ _ _ _ vertical _) = vertical

renderTypographyLineSpacing :: RenderTypography -> Rational
renderTypographyLineSpacing
  (RenderTypography _ _ _ _ _ _ _ _ lineSpacing) = lineSpacing

renderTypographyResourceReferences
  :: RenderTypography
  -> Set ResourceReference
renderTypographyResourceReferences typography =
  Set.singleton
    (ResourceReference (renderTypographyFamily typography) FontReference)

validateGradientStops
  :: NonEmpty RenderGradientStop
  -> Either RenderStyleError ()
validateGradientStops stops = go (renderGradientOffsets stops)
  where
    go [] = Right ()
    go [_] = Right ()
    go (first : second : remaining)
      | first <= second = go (second : remaining)
      | otherwise = Left (RenderGradientStopsOutOfOrder first second)

renderGradientOffsets :: NonEmpty RenderGradientStop -> [RenderGradientOffset]
renderGradientOffsets =
  NonEmpty.toList . fmap (\(RenderGradientStop offset _) -> offset)
