-- |
-- Module      : SlideBlaster.Canvas.Connector
-- Description : Validated editable connector paths and anchor resolution.
--
-- Paths validate open/closed cardinality. Relative @+@ and @++@ anchors resolve
-- left-to-right, node anchors re-resolve from current boxes, orthogonal elbows
-- are derived, and cubic controls remain authored absolute points.
module SlideBlaster.Canvas.Connector
  ( RelativeAdvance (..)
  , Anchor (..)
  , CornerOrder (..)
  , ConnectorSegment (..)
  , PathClosure (..)
  , ConnectorPath
  , ConnectorPathError (..)
  , mkConnectorPath
  , connectorAnchors
  , connectorSegments
  , connectorClosure
  , AnchorResolutionError (..)
  , ResolvedSegment (..)
  , ResolvedConnectorPath (..)
  , resolveConnectorPath
  ) where

import SlideBlaster.Canvas.Geometry
  ( BorderPort
  , Box
  , Point
  , Vector
  , point
  , pointAtPort
  , pointX
  , pointY
  , translatePoint
  )
import SlideBlaster.Canvas.Identifier (NodeId, SourceRef)

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map

-- | Whether a relative coordinate advances the running anchor.
data RelativeAdvance = KeepCurrent | AdvanceCurrent
  deriving stock (Eq, Ord, Show)

-- | Editable anchor subset plus a source-backed read-only fallback.
data Anchor
  = NodeAnchor !NodeId !BorderPort
  | AbsoluteAnchor !Point
  | RelativeAnchor !RelativeAdvance !Vector
  | SourceBackedAnchor !SourceRef
  deriving stock (Eq, Ord, Show)

data CornerOrder = HorizontalThenVertical | VerticalThenHorizontal
  deriving stock (Eq, Ord, Show)

-- | Segment from one anchor to the next.
data ConnectorSegment
  = StraightSegment
  | OrthogonalSegment !CornerOrder
  | CubicSegment !Point !Point
  deriving stock (Eq, Ord, Show)

data PathClosure = OpenPath | ClosedPath
  deriving stock (Eq, Ord, Show)

data ConnectorPath = ConnectorPath
  !(NonEmpty Anchor)
  ![ConnectorSegment]
  !PathClosure
  deriving stock (Eq, Ord, Show)

data ConnectorPathError
  = OpenPathSegmentCountMismatch !Int !Int
  | ClosedPathSegmentCountMismatch !Int !Int
  deriving stock (Eq, Show)

mkConnectorPath ::
  NonEmpty Anchor ->
  [ConnectorSegment] ->
  PathClosure ->
  Either ConnectorPathError ConnectorPath
mkConnectorPath anchors segments closure =
  let anchorCount = nonEmptyLength anchors
      segmentCount = length segments
   in case closure of
        OpenPath
          | segmentCount == anchorCount - 1 ->
            Right (ConnectorPath anchors segments closure)
          | otherwise ->
              Left (OpenPathSegmentCountMismatch anchorCount segmentCount)
        ClosedPath
          | segmentCount == anchorCount ->
            Right (ConnectorPath anchors segments closure)
          | otherwise ->
              Left (ClosedPathSegmentCountMismatch anchorCount segmentCount)

connectorAnchors :: ConnectorPath -> NonEmpty Anchor
connectorAnchors (ConnectorPath anchors _ _) = anchors

connectorSegments :: ConnectorPath -> [ConnectorSegment]
connectorSegments (ConnectorPath _ segments _) = segments

connectorClosure :: ConnectorPath -> PathClosure
connectorClosure (ConnectorPath _ _ closure) = closure

data AnchorResolutionError
  = MissingAnchorNode !NodeId
  | RelativeAnchorWithoutCurrent
  | UnsupportedSourceAnchor !SourceRef
  | ConnectorResolutionInvariant
  deriving stock (Eq, Show)

-- | Geometry-ready segment retaining cubic and orthogonal meaning.
data ResolvedSegment
  = ResolvedStraight !Point !Point
  | ResolvedOrthogonal !Point !Point !Point
  | ResolvedCubic !Point !Point !Point !Point
  deriving stock (Eq, Ord, Show)

data ResolvedConnectorPath = ResolvedConnectorPath
  { resolvedAnchors :: !(NonEmpty Point)
  , resolvedSegments :: ![ResolvedSegment]
  , resolvedClosure :: !PathClosure
  }
  deriving stock (Eq, Ord, Show)

resolveConnectorPath ::
  Map NodeId Box ->
  ConnectorPath ->
  Either AnchorResolutionError ResolvedConnectorPath
resolveConnectorPath nodeBoxes path = do
  anchors <- resolveAnchors nodeBoxes (connectorAnchors path)
  pairs <-
    case connectorClosure path of
      OpenPath -> Right (openPairs anchors)
      ClosedPath -> Right (closedPairs anchors)
  segments <-
    resolveSegments pairs (connectorSegments path)
  Right
    ResolvedConnectorPath
      { resolvedAnchors = anchors
      , resolvedSegments = segments
      , resolvedClosure = connectorClosure path
      }

resolveAnchors ::
  Map NodeId Box ->
  NonEmpty Anchor ->
  Either AnchorResolutionError (NonEmpty Point)
resolveAnchors nodeBoxes (firstAnchor :| remainingAnchors) = do
  (firstPoint, initialCurrent) <- resolveAnchor nodeBoxes Nothing firstAnchor
  remainingPoints <-
    resolveRemaining nodeBoxes initialCurrent remainingAnchors
  Right (firstPoint :| remainingPoints)

resolveRemaining ::
  Map NodeId Box ->
  Maybe Point ->
  [Anchor] ->
  Either AnchorResolutionError [Point]
resolveRemaining _ _ [] = Right []
resolveRemaining nodeBoxes current (nextAnchor : rest) = do
  (nextPoint, nextCurrent) <- resolveAnchor nodeBoxes current nextAnchor
  later <- resolveRemaining nodeBoxes nextCurrent rest
  Right (nextPoint : later)

resolveAnchor ::
  Map NodeId Box ->
  Maybe Point ->
  Anchor ->
  Either AnchorResolutionError (Point, Maybe Point)
resolveAnchor nodeBoxes _ (NodeAnchor identity port) =
  case Map.lookup identity nodeBoxes of
    Nothing -> Left (MissingAnchorNode identity)
    Just nodeBox ->
      let resolved = pointAtPort port nodeBox
       in Right (resolved, Just resolved)
resolveAnchor _ _ (AbsoluteAnchor resolved) =
  Right (resolved, Just resolved)
resolveAnchor _ Nothing (RelativeAnchor _ _) =
  Left RelativeAnchorWithoutCurrent
resolveAnchor _ (Just current) (RelativeAnchor advance displacement) =
  let resolved = translatePoint displacement current
      nextCurrent =
        case advance of
          KeepCurrent -> Just current
          AdvanceCurrent -> Just resolved
   in Right (resolved, nextCurrent)
resolveAnchor _ _ (SourceBackedAnchor reference) =
  Left (UnsupportedSourceAnchor reference)

openPairs :: NonEmpty Point -> [(Point, Point)]
openPairs (firstPoint :| remainingPoints) =
  adjacentPairs firstPoint remainingPoints

closedPairs :: NonEmpty Point -> [(Point, Point)]
closedPairs (firstPoint :| remainingPoints) =
  let (pairs, finalPoint) =
        adjacentPairsWithFinal firstPoint remainingPoints
   in pairs <> [(finalPoint, firstPoint)]

adjacentPairs :: Point -> [Point] -> [(Point, Point)]
adjacentPairs _ [] = []
adjacentPairs previous (current : rest) =
  (previous, current) : adjacentPairs current rest

adjacentPairsWithFinal :: Point -> [Point] -> ([(Point, Point)], Point)
adjacentPairsWithFinal firstPoint [] = ([], firstPoint)
adjacentPairsWithFinal firstPoint (nextPoint : rest) =
  let (laterPairs, finalPoint) =
        adjacentPairsWithFinal nextPoint rest
   in ((firstPoint, nextPoint) : laterPairs, finalPoint)

resolveSegments ::
  [(Point, Point)] ->
  [ConnectorSegment] ->
  Either AnchorResolutionError [ResolvedSegment]
resolveSegments [] [] = Right []
resolveSegments ((start, end) : remainingPairs) (segment : remainingSegments) = do
  later <- resolveSegments remainingPairs remainingSegments
  Right (resolveSegment start end segment : later)
resolveSegments _ _ = Left ConnectorResolutionInvariant

resolveSegment :: Point -> Point -> ConnectorSegment -> ResolvedSegment
resolveSegment start end segment =
  case segment of
    StraightSegment -> ResolvedStraight start end
    OrthogonalSegment order ->
      ResolvedOrthogonal start (orthogonalElbow order start end) end
    CubicSegment firstControl secondControl ->
      ResolvedCubic start firstControl secondControl end

orthogonalElbow :: CornerOrder -> Point -> Point -> Point
orthogonalElbow order start end =
  case order of
    HorizontalThenVertical -> point (pointX end) (pointY start)
    VerticalThenHorizontal -> point (pointX start) (pointY end)

nonEmptyLength :: NonEmpty value -> Int
nonEmptyLength (_ :| values) = 1 + length values
