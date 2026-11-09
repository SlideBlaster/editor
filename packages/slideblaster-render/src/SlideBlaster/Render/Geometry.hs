-- |
-- Module      : SlideBlaster.Render.Geometry
-- Description : Resolved path, transform, clipping, and hit-test geometry.
--
-- Geometry in this module is already in slide coordinates. It contains no
-- stencil identity, source-backed outline, or target-specific path string.
module SlideBlaster.Render.Geometry
  ( RenderArcRadii
  , mkRenderArcRadii
  , renderArcRadiusX
  , renderArcRadiusY
  , RenderArcSize (..)
  , RenderArcSweep (..)
  , RenderPath
  , RenderPathSegment (..)
  , RenderPathClosure (..)
  , mkRenderPath
  , renderPathClosure
  , renderPathSegments
  , renderPathStart
  , RenderFillRule (..)
  , RenderGeometryError (..)
  , RenderCornerRadii
  , RenderCornerRadiiView (..)
  , mkRenderCornerRadii
  , renderCornerRadiiView
  , zeroRenderCornerRadii
  , RenderOutline
  , RenderOutlineView (..)
  , mkRenderRectangle
  , renderEllipse
  , mkRenderPolygon
  , renderPathOutline
  , renderOutlineView
  , RenderTransform
  , affineRenderTransform
  , identityRenderTransform
  , renderTransformA
  , renderTransformB
  , renderTransformC
  , renderTransformD
  , renderTransformX
  , renderTransformY
  , RenderClip (..)
  , RenderHitRegion
  , RenderHitRegionView (..)
  , noRenderHitRegion
  , renderBoxHitRegion
  , renderOutlineHitRegion
  , mkRenderPathHitRegion
  , renderHitRegionView
  ) where

import SlideBlaster.Canvas
  ( Box
  , CanvasUnit
  , Point
  , canvasUnitFromInteger
  , canvasUnitValue
  , pointX
  , pointY
  )

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set

-- | One segment after a path's explicit starting point.
data RenderPathSegment
  = RenderLineTo !Point
  | RenderQuadraticTo !Point !Point
  | RenderCubicTo !Point !Point !Point
  | RenderArcTo
      !RenderArcRadii
      !Rational
      !RenderArcSize
      !RenderArcSweep
      !Point
  deriving stock (Eq, Ord, Show)

-- | Strictly positive arc radii after resolution into slide units.
data RenderArcRadii = RenderArcRadii !CanvasUnit !CanvasUnit
  deriving stock (Eq, Ord, Show)

mkRenderArcRadii
  :: CanvasUnit
  -> CanvasUnit
  -> Either RenderGeometryError RenderArcRadii
mkRenderArcRadii radiusX radiusY
  | canvasUnitValue radiusX <= 0
      || canvasUnitValue radiusY <= 0 =
      Left (RenderArcRadiiMustBePositive radiusX radiusY)
  | otherwise = Right (RenderArcRadii radiusX radiusY)

renderArcRadiusX :: RenderArcRadii -> CanvasUnit
renderArcRadiusX (RenderArcRadii radiusX _) = radiusX

renderArcRadiusY :: RenderArcRadii -> CanvasUnit
renderArcRadiusY (RenderArcRadii _ radiusY) = radiusY

data RenderArcSize = RenderSmallArc | RenderLargeArc
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderArcSweep
  = RenderCounterClockwiseArc
  | RenderClockwiseArc
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderPathClosure
  = RenderOpenPath
  | RenderClosedPath
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | A resolved non-empty path in slide coordinates.
data RenderPath = RenderPath
  !Point
  !(NonEmpty RenderPathSegment)
  !RenderPathClosure
  deriving stock (Eq, Ord, Show)

mkRenderPath
  :: Point
  -> NonEmpty RenderPathSegment
  -> RenderPathClosure
  -> RenderPath
mkRenderPath = RenderPath

renderPathStart :: RenderPath -> Point
renderPathStart (RenderPath start _ _) = start

renderPathSegments :: RenderPath -> NonEmpty RenderPathSegment
renderPathSegments (RenderPath _ segments _) = segments

renderPathClosure :: RenderPath -> RenderPathClosure
renderPathClosure (RenderPath _ _ closure) = closure

data RenderFillRule
  = RenderNonZeroFill
  | RenderEvenOddFill
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderCornerRadii = RenderCornerRadii
  !CanvasUnit
  !CanvasUnit
  !CanvasUnit
  !CanvasUnit
  deriving stock (Eq, Ord, Show)

data RenderCornerRadiiView = RenderCornerRadiiView
  !CanvasUnit
  !CanvasUnit
  !CanvasUnit
  !CanvasUnit
  deriving stock (Eq, Ord, Show)

data RenderGeometryError
  = RenderArcRadiiMustBePositive !CanvasUnit !CanvasUnit
  | RenderCornerRadiusMustBeNonNegative !CanvasUnit
  | RenderPolygonNeedsThreeDistinctPoints
  | RenderPolygonHasZeroArea
  | RenderHitWidthMustBePositive !CanvasUnit
  deriving stock (Eq, Show)

mkRenderCornerRadii
  :: CanvasUnit
  -> CanvasUnit
  -> CanvasUnit
  -> CanvasUnit
  -> Either RenderGeometryError RenderCornerRadii
mkRenderCornerRadii topLeft topRight bottomRight bottomLeft =
  case
      filter
        ((< 0) . canvasUnitValue)
        [topLeft, topRight, bottomRight, bottomLeft]
    of
      invalid : _ -> Left (RenderCornerRadiusMustBeNonNegative invalid)
      [] -> Right (RenderCornerRadii topLeft topRight bottomRight bottomLeft)

zeroRenderCornerRadii :: RenderCornerRadii
zeroRenderCornerRadii = RenderCornerRadii zero zero zero zero
  where
    zero = canvasUnitFromInteger 0

renderCornerRadiiView :: RenderCornerRadii -> RenderCornerRadiiView
renderCornerRadiiView
  (RenderCornerRadii topLeft topRight bottomRight bottomLeft) =
    RenderCornerRadiiView topLeft topRight bottomRight bottomLeft

-- | Direct resolved outline geometry. Stencils and authored custom outlines
-- must be lowered to one of these constructors.
data RenderOutline
  = RenderRectangle !Box !RenderCornerRadii
  | RenderEllipse !Box
  | RenderPolygon !(NonEmpty Point)
  | RenderPathOutline !RenderFillRule !(NonEmpty RenderPath)
  deriving stock (Eq, Ord, Show)

data RenderOutlineView
  = RenderRectangleView !Box !RenderCornerRadii
  | RenderEllipseView !Box
  | RenderPolygonView !(NonEmpty Point)
  | RenderPathOutlineView !RenderFillRule !(NonEmpty RenderPath)
  deriving stock (Eq, Ord, Show)

mkRenderRectangle :: Box -> RenderCornerRadii -> RenderOutline
mkRenderRectangle = RenderRectangle

renderEllipse :: Box -> RenderOutline
renderEllipse = RenderEllipse

mkRenderPolygon
  :: NonEmpty Point
  -> Either RenderGeometryError RenderOutline
mkRenderPolygon points
  | Set.size (Set.fromList (NonEmpty.toList points)) < 3 =
      Left RenderPolygonNeedsThreeDistinctPoints
  | polygonTwiceArea points == 0 =
      Left RenderPolygonHasZeroArea
  | otherwise = Right (RenderPolygon points)

renderPathOutline
  :: RenderFillRule
  -> NonEmpty RenderPath
  -> RenderOutline
renderPathOutline = RenderPathOutline

renderOutlineView :: RenderOutline -> RenderOutlineView
renderOutlineView outline =
  case outline of
    RenderRectangle box radii -> RenderRectangleView box radii
    RenderEllipse box -> RenderEllipseView box
    RenderPolygon points -> RenderPolygonView points
    RenderPathOutline rule paths -> RenderPathOutlineView rule paths

-- | An explicit affine transform in the matrix form
-- @[a c x; b d y; 0 0 1]@.
data RenderTransform = RenderTransform
  !Rational
  !Rational
  !Rational
  !Rational
  !CanvasUnit
  !CanvasUnit
  deriving stock (Eq, Ord, Show)

affineRenderTransform
  :: Rational
  -> Rational
  -> Rational
  -> Rational
  -> CanvasUnit
  -> CanvasUnit
  -> RenderTransform
affineRenderTransform = RenderTransform

identityRenderTransform :: RenderTransform
identityRenderTransform =
  RenderTransform 1 0 0 1 zero zero
  where
    zero = canvasUnitFromInteger 0

renderTransformA :: RenderTransform -> Rational
renderTransformA (RenderTransform a _ _ _ _ _) = a

renderTransformB :: RenderTransform -> Rational
renderTransformB (RenderTransform _ b _ _ _ _) = b

renderTransformC :: RenderTransform -> Rational
renderTransformC (RenderTransform _ _ c _ _ _) = c

renderTransformD :: RenderTransform -> Rational
renderTransformD (RenderTransform _ _ _ d _ _) = d

renderTransformX :: RenderTransform -> CanvasUnit
renderTransformX (RenderTransform _ _ _ _ x _) = x

renderTransformY :: RenderTransform -> CanvasUnit
renderTransformY (RenderTransform _ _ _ _ _ y) = y

data RenderClip
  = NoRenderClip
  | ClipToRenderOutline !RenderOutline
  deriving stock (Eq, Ord, Show)

-- | Host hit testing consumes this explicit region rather than inferring a
-- clickable area from DOM structure.
data RenderHitRegion
  = NoRenderHitRegion
  | RenderBoxHitRegion !Box
  | RenderOutlineHitRegion !RenderOutline
  | RenderPathHitRegion !RenderPath !CanvasUnit
  deriving stock (Eq, Ord, Show)

data RenderHitRegionView
  = NoRenderHitRegionView
  | RenderBoxHitRegionView !Box
  | RenderOutlineHitRegionView !RenderOutline
  | RenderPathHitRegionView !RenderPath !CanvasUnit
  deriving stock (Eq, Ord, Show)

noRenderHitRegion :: RenderHitRegion
noRenderHitRegion = NoRenderHitRegion

renderBoxHitRegion :: Box -> RenderHitRegion
renderBoxHitRegion = RenderBoxHitRegion

renderOutlineHitRegion :: RenderOutline -> RenderHitRegion
renderOutlineHitRegion = RenderOutlineHitRegion

mkRenderPathHitRegion
  :: RenderPath
  -> CanvasUnit
  -> Either RenderGeometryError RenderHitRegion
mkRenderPathHitRegion path width
  | canvasUnitValue width <= 0 =
      Left (RenderHitWidthMustBePositive width)
  | otherwise = Right (RenderPathHitRegion path width)

renderHitRegionView :: RenderHitRegion -> RenderHitRegionView
renderHitRegionView region =
  case region of
    NoRenderHitRegion -> NoRenderHitRegionView
    RenderBoxHitRegion box -> RenderBoxHitRegionView box
    RenderOutlineHitRegion outline -> RenderOutlineHitRegionView outline
    RenderPathHitRegion path width -> RenderPathHitRegionView path width

polygonTwiceArea :: NonEmpty Point -> Rational
polygonTwiceArea (first :| remaining) =
  go first first remaining
  where
    go :: Point -> Point -> [Point] -> Rational
    go initial previous [] = cross previous initial
    go initial previous (current : rest) =
      cross previous current + go initial current rest

    cross :: Point -> Point -> Rational
    cross left right =
      canvasUnitValue (pointX left) * canvasUnitValue (pointY right)
        - canvasUnitValue (pointY left) * canvasUnitValue (pointX right)
