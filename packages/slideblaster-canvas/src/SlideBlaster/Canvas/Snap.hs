-- |
-- Module      : SlideBlaster.Canvas.Snap
-- Description : Pure binding and absolute drag snapping policy.
--
-- The resolver tries a relative binding first, then a two-dimensional theme
-- anchor. Otherwise each axis resolves independently with strict precedence
-- alignment, equal spacing, then grid.
-- 'FreeDrag' (the Alt gesture) bypasses every candidate and preserves the exact
-- proposed centre.
module SlideBlaster.Canvas.Snap
  ( SnapConfig
  , SnapConfigError (..)
  , mkSnapConfig
  , mkSnapConfigWithPointReferences
  , snapThreshold
  , snapGrid
  , snapSlideSize
  , snapExtraReferences
  , snapPointReferences
  , BindingConfig
  , BindingConfigError (..)
  , mkBindingConfig
  , bindingAlignmentTolerance
  , bindingMaximumGap
  , PeerBox (..)
  , AlignmentTarget (..)
  , AxisReference (..)
  , PointReference (..)
  , BindingCandidate (..)
  , PointSnapCandidate (..)
  , AlignmentCandidate (..)
  , SpacingCandidate (..)
  , GridCandidate (..)
  , AxisCandidate (..)
  , GuideKind (..)
  , SnapGuide (..)
  , DragMode (..)
  , DragRequest (..)
  , DragResolution (..)
  , bindingCandidates
  , absoluteCandidates
  , resolveDrag
  ) where

import SlideBlaster.Canvas.Geometry
  ( Axis (..)
  , Box
  , CanvasUnit
  , Point
  , Size
  , absoluteUnit
  , addUnits
  , boxBottom
  , boxCenter
  , boxLeft
  , boxRight
  , boxSize
  , boxTop
  , boxesOverlapX
  , boxesOverlapY
  , canvasUnit
  , canvasUnitFromInteger
  , canvasUnitValue
  , point
  , pointX
  , pointY
  , scaleUnit
  , sizeHeight
  , sizeWidth
  , subtractUnits
  )
import SlideBlaster.Canvas.Identifier (AnchorId, NodeId, RegionId)
import SlideBlaster.Canvas.Placement
  ( Placement (AbsolutePlacement, RelativeNodePlacement)
  , RelativePlacement (..)
  , RelativeSide (..)
  , defaultPortsForSide
  )
import SlideBlaster.Canvas.Geometry (BorderPort (Centre))
import Data.Set (Set)
import Data.Set qualified as Set

-- | Valid absolute-snap configuration in slide units.
data SnapConfig = SnapConfig
  !CanvasUnit
  !(Maybe CanvasUnit)
  !Size
  ![AxisReference]
  ![PointReference]
  deriving stock (Eq, Show)

data SnapConfigError
  = NegativeSnapThreshold !CanvasUnit
  | NonPositiveGrid !CanvasUnit
  | ThresholdCapturesGrid
  deriving stock (Eq, Show)

mkSnapConfig ::
  CanvasUnit ->
  Maybe CanvasUnit ->
  Size ->
  [AxisReference] ->
  Either SnapConfigError SnapConfig
mkSnapConfig threshold grid slideSize references
  = mkSnapConfigWithPointReferences
      threshold
      grid
      slideSize
      references
      []

mkSnapConfigWithPointReferences ::
  CanvasUnit ->
  Maybe CanvasUnit ->
  Size ->
  [AxisReference] ->
  [PointReference] ->
  Either SnapConfigError SnapConfig
mkSnapConfigWithPointReferences threshold grid slideSize references pointReferences
  | threshold < zero = Left (NegativeSnapThreshold threshold)
  | Just step <- grid
  , step <= zero =
      Left (NonPositiveGrid step)
  | Just step <- grid
  , scaleUnit 2 threshold >= step =
      Left ThresholdCapturesGrid
  | otherwise =
      Right
        (SnapConfig threshold grid slideSize references pointReferences)
  where
    zero = canvasUnitFromInteger 0

snapThreshold :: SnapConfig -> CanvasUnit
snapThreshold (SnapConfig threshold _ _ _ _) = threshold

snapGrid :: SnapConfig -> Maybe CanvasUnit
snapGrid (SnapConfig _ grid _ _ _) = grid

snapSlideSize :: SnapConfig -> Size
snapSlideSize (SnapConfig _ _ slideSize _ _) = slideSize

snapExtraReferences :: SnapConfig -> [AxisReference]
snapExtraReferences (SnapConfig _ _ _ references _) = references

snapPointReferences :: SnapConfig -> [PointReference]
snapPointReferences (SnapConfig _ _ _ _ references) = references

-- | Valid relative-binding offer configuration.
data BindingConfig = BindingConfig !CanvasUnit !CanvasUnit
  deriving stock (Eq, Show)

data BindingConfigError
  = NegativeBindingAlignmentTolerance !CanvasUnit
  | NegativeBindingMaximumGap !CanvasUnit
  deriving stock (Eq, Show)

mkBindingConfig ::
  CanvasUnit ->
  CanvasUnit ->
  Either BindingConfigError BindingConfig
mkBindingConfig alignmentTolerance maximumGap
  | alignmentTolerance < zero =
      Left (NegativeBindingAlignmentTolerance alignmentTolerance)
  | maximumGap < zero = Left (NegativeBindingMaximumGap maximumGap)
  | otherwise = Right (BindingConfig alignmentTolerance maximumGap)
  where
    zero = canvasUnitFromInteger 0

bindingAlignmentTolerance :: BindingConfig -> CanvasUnit
bindingAlignmentTolerance (BindingConfig value _) = value

bindingMaximumGap :: BindingConfig -> CanvasUnit
bindingMaximumGap (BindingConfig _ value) = value

data PeerBox = PeerBox
  { peerNodeId :: !NodeId
  , peerResolvedBox :: !Box
  }
  deriving stock (Eq, Show)

data AlignmentTarget
  = SlideAlignment
  | ThemeRegionAlignment !RegionId
  | PeerAlignment !NodeId
  deriving stock (Eq, Ord, Show)

-- | Additional theme/master alignment coordinate.
data AxisReference = AxisReference
  { axisReferenceAxis :: !Axis
  , axisReferenceCoordinate :: !CanvasUnit
  , axisReferenceTarget :: !AlignmentTarget
  }
  deriving stock (Eq, Show)

-- | Resolved editor-only theme anchor in slide coordinates.
data PointReference = PointReference
  { pointReferenceAnchor :: !AnchorId
  , pointReferencePosition :: !Point
  }
  deriving stock (Eq, Show)

data BindingCandidate = BindingCandidate
  { candidateBindingTarget :: !NodeId
  , candidateRelativePlacement :: !RelativePlacement
  , candidateBindingCenter :: !Point
  , candidateBindingScore :: !CanvasUnit
  , candidateBindingTargetBox :: !Box
  }
  deriving stock (Eq, Show)

-- | One Euclidean centre-to-anchor offer. Squared distance remains exact and
-- is sufficient for ordering without introducing floating point or square
-- roots into shared semantics.
data PointSnapCandidate = PointSnapCandidate
  { pointSnapAnchor :: !AnchorId
  , pointSnapResolvedCenter :: !Point
  , pointSnapSquaredDistance :: !Rational
  }
  deriving stock (Eq, Show)

data AlignmentCandidate = AlignmentCandidate
  { alignmentAxis :: !Axis
  , alignmentResolvedCoordinate :: !CanvasUnit
  , alignmentGuideCoordinate :: !CanvasUnit
  , alignmentDistance :: !CanvasUnit
  , alignmentTarget :: !AlignmentTarget
  }
  deriving stock (Eq, Show)

data SpacingCandidate = SpacingCandidate
  { spacingAxis :: !Axis
  , spacingResolvedCoordinate :: !CanvasUnit
  , spacingLowEdge :: !CanvasUnit
  , spacingHighEdge :: !CanvasUnit
  , spacingDistance :: !CanvasUnit
  , spacingLowPeer :: !NodeId
  , spacingHighPeer :: !NodeId
  }
  deriving stock (Eq, Show)

data GridCandidate = GridCandidate
  { gridAxis :: !Axis
  , gridResolvedCoordinate :: !CanvasUnit
  , gridDistance :: !CanvasUnit
  }
  deriving stock (Eq, Show)

data AxisCandidate
  = AlignmentSnap !AlignmentCandidate
  | SpacingSnap !SpacingCandidate
  | GridSnap !GridCandidate
  deriving stock (Eq, Show)

data GuideKind
  = PointGuide
  | AlignmentGuide
  | SpacingGuide
  | BindingGuide
  deriving stock (Eq, Ord, Show)

data SnapGuide = SnapGuide
  { guideStart :: !Point
  , guideEnd :: !Point
  , guideKind :: !GuideKind
  }
  deriving stock (Eq, Show)

data DragMode = SnappingDrag | FreeDrag
  deriving stock (Eq, Ord, Show)

data DragRequest = DragRequest
  { dragNodeIdentity :: !NodeId
  , dragExcludedBindingTargets :: !(Set NodeId)
  , dragMode :: !DragMode
  , dragProposedBox :: !Box
  , dragPeers :: ![PeerBox]
  , dragSnapConfig :: !SnapConfig
  , dragBindingConfig :: !BindingConfig
  }
  deriving stock (Eq, Show)

data DragResolution = DragResolution
  { dragResolvedCenter :: !Point
  , dragResolvedPlacement :: !Placement
  , dragGuides :: ![SnapGuide]
  , dragSelectedBinding :: !(Maybe BindingCandidate)
  , dragSelectedPoint :: !(Maybe PointSnapCandidate)
  , dragHorizontalSnap :: !(Maybe AxisCandidate)
  , dragVerticalSnap :: !(Maybe AxisCandidate)
  }
  deriving stock (Eq, Show)

bindingCandidates ::
  BindingConfig ->
  Box ->
  [PeerBox] ->
  [BindingCandidate]
bindingCandidates config dragged =
  concatMap candidatesForPeer
  where
    candidatesForPeer peer =
      concatMap
        (candidateForSide config dragged peer)
        [Below, Above, RightOf, LeftOf]

absoluteCandidates ::
  SnapConfig ->
  Box ->
  [PeerBox] ->
  (Maybe AxisCandidate, Maybe AxisCandidate)
absoluteCandidates config dragged peers =
  ( chooseAxisCandidate config HorizontalAxis dragged peers
  , chooseAxisCandidate config VerticalAxis dragged peers
  )

resolveDrag :: DragRequest -> DragResolution
resolveDrag request =
  case dragMode request of
    FreeDrag -> exactResolution request
    SnappingDrag ->
      case bestBinding (bindingCandidatesFor request) of
        Just binding -> bindingResolution binding
        Nothing ->
          case bestPointSnap
            (dragSnapConfig request)
            (boxCenter (dragProposedBox request)) of
            Just candidate -> pointResolution (dragSnapConfig request) candidate
            Nothing -> absoluteResolution request

bindingCandidatesFor :: DragRequest -> [BindingCandidate]
bindingCandidatesFor request =
  filter eligible
    ( bindingCandidates
        (dragBindingConfig request)
        (dragProposedBox request)
        (dragPeers request)
    )
  where
    eligible candidate =
      candidateBindingTarget candidate /= dragNodeIdentity request
        && not
          ( Set.member
              (candidateBindingTarget candidate)
              (dragExcludedBindingTargets request)
          )

exactResolution :: DragRequest -> DragResolution
exactResolution request =
  let center = boxCenter (dragProposedBox request)
   in DragResolution
        { dragResolvedCenter = center
        , dragResolvedPlacement = AbsolutePlacement center Centre
        , dragGuides = []
        , dragSelectedBinding = Nothing
        , dragSelectedPoint = Nothing
        , dragHorizontalSnap = Nothing
        , dragVerticalSnap = Nothing
        }

bindingResolution :: BindingCandidate -> DragResolution
bindingResolution candidate =
  DragResolution
    { dragResolvedCenter = candidateBindingCenter candidate
    , dragResolvedPlacement =
        RelativeNodePlacement (candidateRelativePlacement candidate)
    , dragGuides =
        [ SnapGuide
            (candidateBindingCenter candidate)
            (boxCenter (candidateBindingTargetBox candidate))
            BindingGuide
        ]
    , dragSelectedBinding = Just candidate
    , dragSelectedPoint = Nothing
    , dragHorizontalSnap = Nothing
    , dragVerticalSnap = Nothing
    }

pointResolution :: SnapConfig -> PointSnapCandidate -> DragResolution
pointResolution config candidate =
  let center = pointSnapResolvedCenter candidate
      slideSize = snapSlideSize config
   in DragResolution
        { dragResolvedCenter = center
        , dragResolvedPlacement = AbsolutePlacement center Centre
        , dragGuides =
            [ SnapGuide
                (point (pointX center) (canvasUnitFromInteger 0))
                (point (pointX center) (sizeHeight slideSize))
                PointGuide
            , SnapGuide
                (point (canvasUnitFromInteger 0) (pointY center))
                (point (sizeWidth slideSize) (pointY center))
                PointGuide
            ]
        , dragSelectedBinding = Nothing
        , dragSelectedPoint = Just candidate
        , dragHorizontalSnap = Nothing
        , dragVerticalSnap = Nothing
        }

absoluteResolution :: DragRequest -> DragResolution
absoluteResolution request =
  let config = dragSnapConfig request
      proposed = dragProposedBox request
      (horizontal, vertical) =
        absoluteCandidates config proposed (dragPeers request)
      center =
        point
          (candidateCoordinate (pointX (boxCenter proposed)) horizontal)
          (candidateCoordinate (pointY (boxCenter proposed)) vertical)
      guides =
        candidateGuides config proposed horizontal
          <> candidateGuides config proposed vertical
   in DragResolution
        { dragResolvedCenter = center
        , dragResolvedPlacement = AbsolutePlacement center Centre
        , dragGuides = guides
        , dragSelectedBinding = Nothing
        , dragSelectedPoint = Nothing
        , dragHorizontalSnap = horizontal
        , dragVerticalSnap = vertical
        }

bestPointSnap :: SnapConfig -> Point -> Maybe PointSnapCandidate
bestPointSnap config proposed =
  foldl choose Nothing candidates
  where
    thresholdValue = canvasUnitValue (snapThreshold config)
    maximumSquared = thresholdValue * thresholdValue
    candidates =
      [ PointSnapCandidate
          { pointSnapAnchor = pointReferenceAnchor reference
          , pointSnapResolvedCenter = candidatePoint
          , pointSnapSquaredDistance = distance
          }
      | reference <- snapPointReferences config
      , let candidatePoint = pointReferencePosition reference
      , let distance = squaredDistance proposed candidatePoint
      , distance <= maximumSquared
      ]
    choose Nothing candidate = Just candidate
    choose (Just current) candidate
      | pointSnapSquaredDistance candidate
          < pointSnapSquaredDistance current =
          Just candidate
      | otherwise = Just current

squaredDistance :: Point -> Point -> Rational
squaredDistance left right =
  let dx =
        canvasUnitValue
          (subtractUnits (pointX left) (pointX right))
      dy =
        canvasUnitValue
          (subtractUnits (pointY left) (pointY right))
   in dx * dx + dy * dy

candidateForSide ::
  BindingConfig ->
  Box ->
  PeerBox ->
  RelativeSide ->
  [BindingCandidate]
candidateForSide config dragged peer side =
  let peerBox = peerResolvedBox peer
      alignment =
        case side of
          Above -> absoluteUnit (subtractUnits draggedX peerX)
          Below -> absoluteUnit (subtractUnits draggedX peerX)
          RightOf -> absoluteUnit (subtractUnits draggedY peerY)
          LeftOf -> absoluteUnit (subtractUnits draggedY peerY)
          _ -> canvasUnitFromInteger 0
      rawGap =
        case side of
          Below -> subtractUnits (boxBottom peerBox) (boxTop dragged)
          Above -> subtractUnits (boxBottom dragged) (boxTop peerBox)
          RightOf -> subtractUnits (boxLeft dragged) (boxRight peerBox)
          LeftOf -> subtractUnits (boxLeft peerBox) (boxRight dragged)
          _ -> canvasUnitFromInteger (-1)
      within =
        alignment <= bindingAlignmentTolerance config
          && rawGap >= canvasUnitFromInteger 0
          && rawGap <= bindingMaximumGap config
   in if within
        then
          let gap = roundToTenth rawGap
              (ownPort, targetPort) = defaultPortsForSide side
              placement =
                RelativePlacement
                  { relativeTarget = peerNodeId peer
                  , relativeSide = side
                  , relativePrimaryGap = gap
                  , relativeSecondaryGap = canvasUnitFromInteger 0
                  , relativeTargetPort = targetPort
                  , relativeOwnPort = ownPort
                  }
           in [ BindingCandidate
                  { candidateBindingTarget = peerNodeId peer
                  , candidateRelativePlacement = placement
                  , candidateBindingCenter =
                      boundCenter side gap dragged peerBox
                  , candidateBindingScore = addUnits rawGap alignment
                  , candidateBindingTargetBox = peerBox
                  }
              ]
        else []
  where
    draggedX = pointX (boxCenter dragged)
    draggedY = pointY (boxCenter dragged)
    peerX = pointX (boxCenter (peerResolvedBox peer))
    peerY = pointY (boxCenter (peerResolvedBox peer))

boundCenter :: RelativeSide -> CanvasUnit -> Box -> Box -> Point
boundCenter side gap dragged peer =
  let draggedHalfWidth = scaleUnit (1 / 2) (sizeWidth (boxSize dragged))
      draggedHalfHeight = scaleUnit (1 / 2) (sizeHeight (boxSize dragged))
      peerHalfWidth = scaleUnit (1 / 2) (sizeWidth (boxSize peer))
      peerHalfHeight = scaleUnit (1 / 2) (sizeHeight (boxSize peer))
      horizontalOffset = addUnits peerHalfWidth (addUnits gap draggedHalfWidth)
      verticalOffset = addUnits peerHalfHeight (addUnits gap draggedHalfHeight)
      peerCenter = boxCenter peer
   in case side of
        Below ->
          point
            (pointX peerCenter)
            (subtractUnits (pointY peerCenter) verticalOffset)
        Above ->
          point
            (pointX peerCenter)
            (addUnits (pointY peerCenter) verticalOffset)
        RightOf ->
          point
            (addUnits (pointX peerCenter) horizontalOffset)
            (pointY peerCenter)
        LeftOf ->
          point
            (subtractUnits (pointX peerCenter) horizontalOffset)
            (pointY peerCenter)
        _ -> boxCenter dragged

bestBinding :: [BindingCandidate] -> Maybe BindingCandidate
bestBinding = foldl choose Nothing
  where
    choose Nothing candidate = Just candidate
    choose (Just current) candidate
      | candidateBindingScore candidate < candidateBindingScore current =
          Just candidate
      | otherwise = Just current

chooseAxisCandidate ::
  SnapConfig ->
  Axis ->
  Box ->
  [PeerBox] ->
  Maybe AxisCandidate
chooseAxisCandidate config axis dragged peers =
  case bestAlignment config axis dragged peers of
    Just candidate -> Just (AlignmentSnap candidate)
    Nothing ->
      case spacingCandidate config axis dragged peers of
        Just candidate -> Just (SpacingSnap candidate)
        Nothing -> GridSnap <$> gridCandidate config axis dragged

bestAlignment ::
  SnapConfig ->
  Axis ->
  Box ->
  [PeerBox] ->
  Maybe AlignmentCandidate
bestAlignment config axis dragged peers =
  foldl choose Nothing candidates
  where
    candidates =
      [ AlignmentCandidate
          { alignmentAxis = axis
          , alignmentResolvedCoordinate =
              addUnits draggedCenter (subtractUnits target draggedPoint)
          , alignmentGuideCoordinate = target
          , alignmentDistance =
              absoluteUnit (subtractUnits target draggedPoint)
          , alignmentTarget = targetKind
          }
      | (target, targetKind) <- alignmentReferences config axis peers
      , draggedPoint <- projectedPoints axis dragged
      , absoluteUnit (subtractUnits target draggedPoint)
          <= snapThreshold config
      ]
    draggedCenter = axisCenter axis dragged
    choose Nothing candidate = Just candidate
    choose (Just current) candidate
      | alignmentDistance candidate < alignmentDistance current =
          Just candidate
      | otherwise = Just current

alignmentReferences ::
  SnapConfig ->
  Axis ->
  [PeerBox] ->
  [(CanvasUnit, AlignmentTarget)]
alignmentReferences config axis peers =
  slideReferences
    <> themeReferences
    <> concatMap peerReferences peers
  where
    extent =
      case axis of
        HorizontalAxis -> sizeWidth (snapSlideSize config)
        VerticalAxis -> sizeHeight (snapSlideSize config)
    slideReferences =
      [ (canvasUnitFromInteger 0, SlideAlignment)
      , (scaleUnit (1 / 3) extent, SlideAlignment)
      , (scaleUnit (1 / 2) extent, SlideAlignment)
      , (scaleUnit (2 / 3) extent, SlideAlignment)
      , (extent, SlideAlignment)
      ]
    themeReferences =
      [ (axisReferenceCoordinate reference, axisReferenceTarget reference)
      | reference <- snapExtraReferences config
      , axisReferenceAxis reference == axis
      ]
    peerReferences peer =
      [ (coordinate, PeerAlignment (peerNodeId peer))
      | coordinate <- projectedPoints axis (peerResolvedBox peer)
      ]

projectedPoints :: Axis -> Box -> [CanvasUnit]
projectedPoints axis value =
  case axis of
    HorizontalAxis -> [boxLeft value, pointX (boxCenter value), boxRight value]
    VerticalAxis -> [boxBottom value, pointY (boxCenter value), boxTop value]

spacingCandidate ::
  SnapConfig ->
  Axis ->
  Box ->
  [PeerBox] ->
  Maybe SpacingCandidate
spacingCandidate config axis dragged peers = do
  low <- nearestLow axis dragged peers
  high <- nearestHigh axis dragged peers
  let lowEdge = highEdge axis (peerResolvedBox low)
      highEdgeValue = lowEdgeOf axis (peerResolvedBox high)
      available = subtractUnits highEdgeValue lowEdge
      draggedExtent =
        case axis of
          HorizontalAxis -> sizeWidth (boxSize dragged)
          VerticalAxis -> sizeHeight (boxSize dragged)
      centered = scaleUnit (1 / 2) (addUnits lowEdge highEdgeValue)
      distance = absoluteUnit (subtractUnits centered (axisCenter axis dragged))
  if available >= draggedExtent
    && distance <= snapThreshold config
    then
      Just
        SpacingCandidate
          { spacingAxis = axis
          , spacingResolvedCoordinate = centered
          , spacingLowEdge = lowEdge
          , spacingHighEdge = highEdgeValue
          , spacingDistance = distance
          , spacingLowPeer = peerNodeId low
          , spacingHighPeer = peerNodeId high
          }
    else Nothing

nearestLow :: Axis -> Box -> [PeerBox] -> Maybe PeerBox
nearestLow axis dragged =
  foldl choose Nothing . filter qualifies
  where
    qualifies peer =
      overlapsPerpendicular axis dragged (peerResolvedBox peer)
        && highEdge axis (peerResolvedBox peer) <= lowEdgeOf axis dragged
    choose Nothing peer = Just peer
    choose (Just current) peer
      | highEdge axis (peerResolvedBox peer)
          > highEdge axis (peerResolvedBox current) =
          Just peer
      | otherwise = Just current

nearestHigh :: Axis -> Box -> [PeerBox] -> Maybe PeerBox
nearestHigh axis dragged =
  foldl choose Nothing . filter qualifies
  where
    qualifies peer =
      overlapsPerpendicular axis dragged (peerResolvedBox peer)
        && lowEdgeOf axis (peerResolvedBox peer) >= highEdge axis dragged
    choose Nothing peer = Just peer
    choose (Just current) peer
      | lowEdgeOf axis (peerResolvedBox peer)
          < lowEdgeOf axis (peerResolvedBox current) =
          Just peer
      | otherwise = Just current

gridCandidate :: SnapConfig -> Axis -> Box -> Maybe GridCandidate
gridCandidate config axis dragged = do
  step <- snapGrid config
  let current = axisCenter axis dragged
      snapped = nearestMultiple step current
      distance = absoluteUnit (subtractUnits snapped current)
  if distance <= snapThreshold config
    then
      Just
        GridCandidate
          { gridAxis = axis
          , gridResolvedCoordinate = snapped
          , gridDistance = distance
          }
    else Nothing

candidateCoordinate :: CanvasUnit -> Maybe AxisCandidate -> CanvasUnit
candidateCoordinate original candidate =
  case candidate of
    Nothing -> original
    Just (AlignmentSnap value) -> alignmentResolvedCoordinate value
    Just (SpacingSnap value) -> spacingResolvedCoordinate value
    Just (GridSnap value) -> gridResolvedCoordinate value

candidateGuides ::
  SnapConfig ->
  Box ->
  Maybe AxisCandidate ->
  [SnapGuide]
candidateGuides _ _ Nothing = []
candidateGuides config _ (Just (AlignmentSnap candidate)) =
  let coordinate = alignmentGuideCoordinate candidate
      slideSize = snapSlideSize config
   in case alignmentAxis candidate of
        HorizontalAxis ->
          [ SnapGuide
              (point coordinate (canvasUnitFromInteger 0))
              (point coordinate (sizeHeight slideSize))
              AlignmentGuide
          ]
        VerticalAxis ->
          [ SnapGuide
              (point (canvasUnitFromInteger 0) coordinate)
              (point (sizeWidth slideSize) coordinate)
              AlignmentGuide
          ]
candidateGuides _ dragged (Just (SpacingSnap candidate)) =
  let centered = spacingResolvedCoordinate candidate
      half = axisHalf (spacingAxis candidate) dragged
      nearEdge = subtractUnits centered half
      farEdge = addUnits centered half
      perpendicular = perpendicularCenter (spacingAxis candidate) dragged
   in case spacingAxis candidate of
        HorizontalAxis ->
          [ SnapGuide
              (point (spacingLowEdge candidate) perpendicular)
              (point nearEdge perpendicular)
              SpacingGuide
          , SnapGuide
              (point farEdge perpendicular)
              (point (spacingHighEdge candidate) perpendicular)
              SpacingGuide
          ]
        VerticalAxis ->
          [ SnapGuide
              (point perpendicular (spacingLowEdge candidate))
              (point perpendicular nearEdge)
              SpacingGuide
          , SnapGuide
              (point perpendicular farEdge)
              (point perpendicular (spacingHighEdge candidate))
              SpacingGuide
          ]
candidateGuides _ _ (Just (GridSnap _)) = []

axisCenter :: Axis -> Box -> CanvasUnit
axisCenter axis value =
  case axis of
    HorizontalAxis -> pointX (boxCenter value)
    VerticalAxis -> pointY (boxCenter value)

axisHalf :: Axis -> Box -> CanvasUnit
axisHalf axis value =
  scaleUnit
    (1 / 2)
    ( case axis of
        HorizontalAxis -> sizeWidth (boxSize value)
        VerticalAxis -> sizeHeight (boxSize value)
    )

perpendicularCenter :: Axis -> Box -> CanvasUnit
perpendicularCenter axis value =
  case axis of
    HorizontalAxis -> pointY (boxCenter value)
    VerticalAxis -> pointX (boxCenter value)

lowEdgeOf :: Axis -> Box -> CanvasUnit
lowEdgeOf axis value =
  case axis of
    HorizontalAxis -> boxLeft value
    VerticalAxis -> boxBottom value

highEdge :: Axis -> Box -> CanvasUnit
highEdge axis value =
  case axis of
    HorizontalAxis -> boxRight value
    VerticalAxis -> boxTop value

overlapsPerpendicular :: Axis -> Box -> Box -> Bool
overlapsPerpendicular axis left right =
  case axis of
    HorizontalAxis -> boxesOverlapY left right
    VerticalAxis -> boxesOverlapX left right

nearestMultiple :: CanvasUnit -> CanvasUnit -> CanvasUnit
nearestMultiple step value =
  let quotient = canvasUnitValue value / canvasUnitValue step
      rounded = floor (quotient + (1 / 2))
   in scaleUnit (fromInteger rounded) step

roundToTenth :: CanvasUnit -> CanvasUnit
roundToTenth value =
  let scaled = canvasUnitValue value * 10
      rounded = floor (scaled + (1 / 2))
   in canvasUnit (fromInteger rounded / 10)
