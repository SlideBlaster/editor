-- |
-- Module      : SlideBlaster.Canvas.Outline
-- Description : Target-neutral outline geometry for ordinary canvas nodes.
--
-- This module deliberately knows nothing about palette rows, catalog
-- categories, search metadata, attribution, or draw.io. Those are
-- creation-time concerns owned by @slideblaster-catalog@. After insertion, a
-- catalog preset and an equivalent authored node have the same semantic shape:
-- an 'OutlineRef' plus ordinary node properties.
module SlideBlaster.Canvas.Outline
  ( OutlineRadius
  , mkOutlineRadius
  , outlineRadiusValue
  , ArcRadii
  , mkArcRadii
  , arcRadiusX
  , arcRadiusY
  , PrimitiveOutline (..)
  , ArcSize (..)
  , ArcSweep (..)
  , OutlinePoint
  , outlinePoint
  , outlinePointX
  , outlinePointY
  , outlinePointToCanvas
  , PathCommand (..)
  , PolygonOutline
  , mkPolygonOutline
  , polygonOutlinePoints
  , PathOutline
  , mkPathOutline
  , pathOutlineCommands
  , OutlineGeometryError (..)
  , OutlineRef (..)
  ) where

import SlideBlaster.Canvas.Geometry
  ( Box
  , CanvasUnit
  , Point
  , addUnits
  , boxCenter
  , boxSize
  , canvasUnitValue
  , point
  , pointX
  , pointY
  , scaleUnit
  , sizeHeight
  , sizeWidth
  )
import SlideBlaster.Canvas.Identifier
  ( CustomGeometryId
  , SourceRef
  , StencilId
  )

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set

-- | Small generic primitive vocabulary; catalog entries are not cases here.
newtype OutlineRadius = OutlineRadius CanvasUnit
  deriving stock (Eq, Ord, Show)

-- | Construct a non-negative corner radius in slide units.
mkOutlineRadius
  :: CanvasUnit
  -> Either OutlineGeometryError OutlineRadius
mkOutlineRadius radius
  | canvasUnitValue radius < 0 =
      Left (OutlineRadiusMustBeNonNegative radius)
  | otherwise = Right (OutlineRadius radius)

outlineRadiusValue :: OutlineRadius -> CanvasUnit
outlineRadiusValue (OutlineRadius radius) = radius

-- | Strictly positive radii in the outline-local coordinate plane.
data ArcRadii = ArcRadii !Rational !Rational
  deriving stock (Eq, Ord, Show)

mkArcRadii
  :: Rational
  -> Rational
  -> Either OutlineGeometryError ArcRadii
mkArcRadii radiusX radiusY
  | radiusX <= 0 || radiusY <= 0 =
      Left (ArcRadiiMustBePositive radiusX radiusY)
  | otherwise = Right (ArcRadii radiusX radiusY)

arcRadiusX :: ArcRadii -> Rational
arcRadiusX (ArcRadii radiusX _) = radiusX

arcRadiusY :: ArcRadii -> Rational
arcRadiusY (ArcRadii _ radiusY) = radiusY

data PrimitiveOutline
  = RectangleOutline
  | RoundedRectangleOutline !OutlineRadius
  | EllipseOutline
  | ArcOutline !ArcRadii
  deriving stock (Eq, Ord, Show)

-- | Coordinate in an outline-local, y-up plane. The canonical target box is
-- @[-1,1] × [-1,1]@; values outside it deliberately allow callouts and effects
-- to protrude. 'outlinePointToCanvas' is the sole affine mapping contract.
data OutlinePoint = OutlinePoint !Rational !Rational
  deriving stock (Eq, Ord, Show)

outlinePoint :: Rational -> Rational -> OutlinePoint
outlinePoint = OutlinePoint

outlinePointX :: OutlinePoint -> Rational
outlinePointX (OutlinePoint x _) = x

outlinePointY :: OutlinePoint -> Rational
outlinePointY (OutlinePoint _ y) = y

outlinePointToCanvas :: Box -> OutlinePoint -> Point
outlinePointToCanvas target (OutlinePoint x y) =
  point
    ( addUnits
        (pointX (boxCenter target))
        (scaleUnit (x / 2) (sizeWidth (boxSize target)))
    )
    ( addUnits
        (pointY (boxCenter target))
        (scaleUnit (y / 2) (sizeHeight (boxSize target)))
    )

-- | Target-neutral path geometry for custom and imported outlines.
data PathCommand
  = MovePath !OutlinePoint
  | LinePath !OutlinePoint
  | QuadraticPath !OutlinePoint !OutlinePoint
  | CubicPath !OutlinePoint !OutlinePoint !OutlinePoint
  | ArcPath
      !ArcRadii
      !Rational
      !ArcSize
      !ArcSweep
      !OutlinePoint
  | ClosePath
  deriving stock (Eq, Ord, Show)

data ArcSize = SmallArc | LargeArc
  deriving stock (Eq, Ord, Show)

data ArcSweep = CounterClockwiseArc | ClockwiseArc
  deriving stock (Eq, Ord, Show)

newtype PolygonOutline = PolygonOutline (NonEmpty OutlinePoint)
  deriving stock (Eq, Ord, Show)

newtype PathOutline = PathOutline (NonEmpty PathCommand)
  deriving stock (Eq, Ord, Show)

data OutlineGeometryError
  = PolygonNeedsThreeDistinctPoints
  | PolygonHasZeroArea
  | OutlineRadiusMustBeNonNegative !CanvasUnit
  | ArcRadiiMustBePositive !Rational !Rational
  | PathMustStartWithMove
  | PathSubpathNeedsDrawnSegment
  | PathCommandAfterCloseNeedsMove
  | PathCloseWithoutDrawnSegment
  deriving stock (Eq, Show)

mkPolygonOutline
  :: NonEmpty OutlinePoint
  -> Either OutlineGeometryError PolygonOutline
mkPolygonOutline points
  | Set.size (Set.fromList (NonEmpty.toList points)) < 3 =
      Left PolygonNeedsThreeDistinctPoints
  | polygonTwiceArea points == 0 =
      Left PolygonHasZeroArea
  | otherwise = Right (PolygonOutline points)

polygonOutlinePoints :: PolygonOutline -> NonEmpty OutlinePoint
polygonOutlinePoints (PolygonOutline points) = points

mkPathOutline
  :: NonEmpty PathCommand
  -> Either OutlineGeometryError PathOutline
mkPathOutline commands@(first :| remaining) =
  case first of
    MovePath _ -> validatePath False remaining
    _ -> Left PathMustStartWithMove
  where
    validatePath drawn []
      | drawn = Right (PathOutline commands)
      | otherwise = Left PathSubpathNeedsDrawnSegment
    validatePath drawn (command : rest) =
      case command of
        MovePath _
          | drawn -> validatePath False rest
          | otherwise -> Left PathSubpathNeedsDrawnSegment
        LinePath _ -> validatePath True rest
        QuadraticPath {} -> validatePath True rest
        CubicPath {} -> validatePath True rest
        ArcPath {} -> validatePath True rest
        ClosePath
          | not drawn -> Left PathCloseWithoutDrawnSegment
          | otherwise ->
              case rest of
                [] -> Right (PathOutline commands)
                MovePath _ : later -> validatePath False later
                _ -> Left PathCommandAfterCloseNeedsMove

pathOutlineCommands :: PathOutline -> NonEmpty PathCommand
pathOutlineCommands (PathOutline commands) = commands

polygonTwiceArea :: NonEmpty OutlinePoint -> Rational
polygonTwiceArea (first :| remaining) =
  go first first remaining
  where
    go initial previous rest =
      case rest of
        [] -> cross previous initial
        current : later ->
          cross previous current + go initial current later

    cross left right =
      outlinePointX left * outlinePointY right
        - outlinePointY left * outlinePointX right

-- | Extensible outline geometry used by both palette preview and canvas.
data OutlineRef
  = PrimitiveGeometry !PrimitiveOutline
  | PolygonGeometry !PolygonOutline
  | PathGeometry !PathOutline
  | CompoundGeometry !(NonEmpty OutlineRef)
  | StencilGeometry !StencilId
  | CustomGeometry !CustomGeometryId
  | UnsupportedGeometry !SourceRef
  deriving stock (Eq, Ord, Show)
