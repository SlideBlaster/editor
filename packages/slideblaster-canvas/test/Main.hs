{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Executable laws for canvas authoring semantics.
module Main (main) where

import SlideBlaster.Canvas
import SlideBlaster.Document
  ( NonEditableReason (OpaqueSource)
  , Origin (ReadOnly)
  )

import Control.Monad (unless)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import System.Exit (exitFailure)

main :: IO ()
main = do
  run "shape properties resolve by documented precedence" propertyPrecedence
  run "frame overrides select their theme role" intermediateRolePrecedence
  run "unknown explicit theme roles are typed" unknownRoleIsTyped
  run "outlines remain data-extensible" outlineContractIsExtensible
  run "relative binding wins before absolute snapping" bindingWins
  run "theme anchors capture both axes before line snapping" pointSnapWins
  run "Alt/free drag bypasses every candidate" freeDragBypasses
  run "alignment wins before spacing and grid" alignmentWins
  run "spacing wins before grid" spacingWins
  run "spacing never overlaps a wide dragged node" spacingRejectsOverlap
  run "grid is the final in-range fallback" gridFallback
  run "axes resolve independently" axesResolveIndependently
  run "out-of-range axes preserve exact drop" exactOutsideThreshold
  run "binding candidates reject overlap and detachment" bindingRange
  run "connector cardinality and relative fold are exact" connectorLaws
  run "orthogonal elbow order is derived" orthogonalElbowLaw
  run "layer barriers stop z-order moves" barrierLaw
  run "picture identity is unique" pictureIdentityLaw
  run "overlay visibility is fixed-step and finite" overlayLaw
  run "mixed content retains dialect and source handles" contentLaw
  run "outline-local coordinates map through the target box" outlineMappingLaw
  run "outline constructors reject degenerate geometry" outlineValidationLaw
  run "qualified resource identifiers preserve imported stable ids" qualifiedIdentifierLaw

run :: String -> IO () -> IO ()
run name check = do
  check
  putStrLn ("PASS: " <> name)

propertyPrecedence :: IO ()
propertyPrecedence = do
  titleRole <- requireJust "title role" (roleId "title")
  halfOpacity <- requireJust "opacity" (mkOpacity (1 / 2))
  quarterOpacity <- requireJust "opacity" (mkOpacity (1 / 4))
  let rolePatch =
        emptyNodePropertyPatch
          { nodePatchRotation = Just (rotation 15)
          , nodePatchPaint = Just (SolidPaint (DirectColour (RGB 0 255 0)))
          }
      style =
        (themeStyle defaultTheme)
          { themeBaseNodePatch =
              emptyNodePropertyPatch
                { nodePatchOpacity = Just quarterOpacity
                }
          , themeNodeRoles =
              Map.fromList
                [ (defaultRoleId, emptyNodePropertyPatch)
                , (titleRole, rolePatch)
                ]
          }
      preset =
        emptyNodePropertyPatch
          { nodePatchRole = Just titleRole
          , nodePatchPaint = Just (SolidPaint (DirectColour (RGB 0 0 255)))
          , nodePatchOpacity = Just halfOpacity
          }
      frameOverride =
        emptyNodePropertyPatch
          { nodePatchPaint = Just (SolidPaint (DirectColour (RGB 255 255 0)))
          }
      explicit =
        emptyNodePropertyPatch
          { nodePatchPaint = Just (SolidPaint (DirectColour (RGB 0 0 0)))
          }
  resolved <-
    requireRight
      "property resolution"
      (resolveNodePropertiesWithOverrides style preset [frameOverride] explicit)
  assertEqual
    "explicit paint wins"
    (SolidPaint (DirectColour (RGB 0 0 0)))
    (nodePaint resolved)
  assertEqual "shape opacity wins over theme base" halfOpacity (nodeOpacity resolved)
  assertEqual "role rotation survives" (rotation 15) (nodeRotation resolved)
  assertEqual "preset-selected role survives" titleRole (nodeRole resolved)

intermediateRolePrecedence :: IO ()
intermediateRolePrecedence = do
  titleRole <- requireJust "intermediate title role" (roleId "title")
  let titlePaint = SolidPaint (DirectColour (RGB 12 34 56))
      style =
        (themeStyle defaultTheme)
          { themeNodeRoles =
              Map.fromList
                [ (defaultRoleId, emptyNodePropertyPatch)
                ,
                  ( titleRole
                  , emptyNodePropertyPatch
                      { nodePatchPaint = Just titlePaint
                      }
                  )
                ]
          }
      frameOverride =
        emptyNodePropertyPatch
          { nodePatchRole = Just titleRole
          }
  resolved <-
    requireRight
      "intermediate role resolution"
      ( resolveNodePropertiesWithOverrides
          style
          emptyNodePropertyPatch
          [frameOverride]
          emptyNodePropertyPatch
      )
  assertEqual "intermediate role survives" titleRole (nodeRole resolved)
  assertEqual "intermediate role defaults apply" titlePaint (nodePaint resolved)

unknownRoleIsTyped :: IO ()
unknownRoleIsTyped = do
  unknown <- requireJust "unknown role" (roleId "not-in-theme")
  let explicit = emptyNodePropertyPatch {nodePatchRole = Just unknown}
  case
      resolveNodeProperties
        (themeStyle defaultTheme)
        emptyNodePropertyPatch
        explicit
    of
    Left (UnknownThemeRole role) ->
      assertEqual "reported missing role" unknown role
    other -> failTest ("unknown role result: " <> show other)

outlineContractIsExtensible :: IO ()
outlineContractIsExtensible = do
  custom <- requireJust "custom geometry id" (customGeometryId "plugin-outline")
  let extensible = CustomGeometry custom
  assertEqual "custom outline remains typed data" extensible extensible

outlineValidationLaw :: IO ()
outlineValidationLaw = do
  assertEqual
    "negative rounded radius"
    (Left (OutlineRadiusMustBeNonNegative (canvasUnit (-1))))
    (mkOutlineRadius (canvasUnit (-1)))
  assertEqual
    "zero arc radius"
    (Left (ArcRadiiMustBePositive 0 1))
    (mkArcRadii 0 1)
  assertEqual
    "collinear polygon"
    (Left PolygonHasZeroArea)
    ( mkPolygonOutline
        ( outlinePoint 0 0
            :| [outlinePoint 1 1, outlinePoint 2 2]
        )
    )

qualifiedIdentifierLaw :: IO ()
qualifiedIdentifierLaw = do
  imported <-
    requireJust
      "digit-leading qualified segment"
      (stencilId "advertising.3-1-rec")
  assertEqual
    "qualified identifier spelling"
    "advertising.3-1-rec"
    (identifierText imported)
  assertEqual "leading dot rejected" Nothing (stencilId ".advertising")
  assertEqual "trailing dot rejected" Nothing (stencilId "advertising.")
  assertEqual "empty segment rejected" Nothing (stencilId "advertising..banner")
  assertEqual "digit-leading root rejected" Nothing (stencilId "3.advertising")
  assertEqual "non-token character rejected" Nothing (stencilId "advertising.a/b")

bindingWins :: IO ()
bindingWins = do
  request <- bindingRequest SnappingDrag
  let result = resolveDrag request
  case dragSelectedBinding result of
    Nothing -> failTest "binding did not engage"
    Just candidate -> do
      target <- requireJust "peer id" (nodeId "peer")
      assertEqual "binding target" target (candidateBindingTarget candidate)
      case dragResolvedPlacement result of
        RelativeNodePlacement placement ->
          assertEqual "binding side" RightOf (relativeSide placement)
        other -> failTest ("binding returned absolute placement: " <> show other)
  assertEqual "binding suppresses axis snaps" Nothing (dragHorizontalSnap result)

freeDragBypasses :: IO ()
freeDragBypasses = do
  request <- bindingRequest FreeDrag
  let result = resolveDrag request
      proposed = boxCenter (dragProposedBox request)
  assertEqual "free center stays exact" proposed (dragResolvedCenter result)
  assertEqual "free drag has no guides" [] (dragGuides result)
  assertEqual "free drag has no binding" Nothing (dragSelectedBinding result)
  assertEqual "free drag has no point snap" Nothing (dragSelectedPoint result)
  assertEqual "free drag has no x snap" Nothing (dragHorizontalSnap result)
  assertEqual "free drag has no y snap" Nothing (dragVerticalSnap result)

alignmentWins :: IO ()
alignmentWins = do
  region <- requireJust "region" (regionId "title-region")
  dragged <- unitBoxAt (canvasUnit (51 / 10)) (canvasUnit 5)
  peers <- spacingPeers
  config <-
    defaultSnapConfig
      [AxisReference HorizontalAxis (canvasUnit (128 / 25)) (ThemeRegionAlignment region)]
  let (horizontal, _) = absoluteCandidates config dragged peers
  case horizontal of
    Just (AlignmentSnap candidate) ->
      assertEqual
        "closest alignment is selected"
        (canvasUnit (128 / 25))
        (alignmentResolvedCoordinate candidate)
    other -> failTest ("alignment precedence result: " <> show other)

spacingWins :: IO ()
spacingWins = do
  dragged <- unitBoxAt (canvasUnit (51 / 10)) (canvasUnit 5)
  peers <- spacingPeers
  config <- defaultSnapConfig []
  let (horizontal, _) = absoluteCandidates config dragged peers
  case horizontal of
    Just (SpacingSnap candidate) ->
      assertEqual
        "equal gap center"
        (canvasUnit 5)
        (spacingResolvedCoordinate candidate)
    other -> failTest ("spacing precedence result: " <> show other)

spacingRejectsOverlap :: IO ()
spacingRejectsOverlap = do
  leftIdentity <- requireJust "left overlap peer" (nodeId "left-overlap")
  rightIdentity <- requireJust "right overlap peer" (nodeId "right-overlap")
  peerSize <- requireRight "peer size" (mkSize (canvasUnit 1) (canvasUnit 1))
  draggedSize <- requireRight "wide dragged size" (mkSize (canvasUnit 4) (canvasUnit 1))
  let dragged = box (point (canvasUnit 5) (canvasUnit 5)) draggedSize
      peers =
        [ PeerBox
            leftIdentity
            (box (point (canvasUnit (7 / 2)) (canvasUnit 5)) peerSize)
        , PeerBox
            rightIdentity
            (box (point (canvasUnit (13 / 2)) (canvasUnit 5)) peerSize)
        ]
  config <- defaultSnapConfig []
  let (horizontal, _) = absoluteCandidates config dragged peers
  case horizontal of
    Just (SpacingSnap _) ->
      failTest "equal-spacing offered an overlapping placement"
    _ -> pure ()

pointSnapWins :: IO ()
pointSnapWins = do
  identity <- requireJust "drag identity" (nodeId "point-drag")
  anchorIdentity <- requireJust "theme anchor" (anchorId "hero-anchor")
  slide <- requireRight "point snap slide" (mkSize (canvasUnit 10) (canvasUnit 10))
  proposed <- unitBoxAt (canvasUnit (13 / 5)) (canvasUnit (15 / 2))
  config <-
    requireRight
      "point snap config"
      ( mkSnapConfigWithPointReferences
          (canvasUnit (1 / 5))
          Nothing
          slide
          []
          [ PointReference
              anchorIdentity
              (point (canvasUnit (5 / 2)) (canvasUnit (15 / 2)))
          ]
      )
  bindingConfig <-
    requireRight
      "point binding config"
      (mkBindingConfig (canvasUnit (1 / 10)) (canvasUnit (1 / 10)))
  let result =
        resolveDrag
          DragRequest
            { dragNodeIdentity = identity
            , dragExcludedBindingTargets = Set.empty
            , dragMode = SnappingDrag
            , dragProposedBox = proposed
            , dragPeers = []
            , dragSnapConfig = config
            , dragBindingConfig = bindingConfig
            }
  case dragSelectedPoint result of
    Just candidate -> do
      assertEqual "point snap identity" anchorIdentity (pointSnapAnchor candidate)
      assertEqual
        "point snap centre"
        (point (canvasUnit (5 / 2)) (canvasUnit (15 / 2)))
        (dragResolvedCenter result)
      assertEqual "point snap crosshair" 2 (length (dragGuides result))
    Nothing -> failTest "theme anchor did not engage"

gridFallback :: IO ()
gridFallback = do
  dragged <- unitBoxAt (canvasUnit (71 / 10)) (canvasUnit (111 / 10))
  slide <- requireRight "large slide" (mkSize (canvasUnit 100) (canvasUnit 100))
  config <-
    requireRight
      "snap config"
      (mkSnapConfig (canvasUnit (1 / 5)) (Just (canvasUnit (1 / 2))) slide [])
  let (horizontal, vertical) = absoluteCandidates config dragged []
  assertGrid "x grid" (canvasUnit 7) horizontal
  assertGrid "y grid" (canvasUnit 11) vertical

axesResolveIndependently :: IO ()
axesResolveIndependently = do
  region <- requireJust "region" (regionId "x-guide")
  dragged <- unitBoxAt (canvasUnit (71 / 10)) (canvasUnit (111 / 10))
  slide <- requireRight "large slide" (mkSize (canvasUnit 100) (canvasUnit 100))
  config <-
    requireRight
      "snap config"
      ( mkSnapConfig
          (canvasUnit (1 / 5))
          (Just (canvasUnit (1 / 2)))
          slide
          [AxisReference HorizontalAxis (canvasUnit (36 / 5)) (ThemeRegionAlignment region)]
      )
  let (horizontal, vertical) = absoluteCandidates config dragged []
  case horizontal of
    Just (AlignmentSnap _) -> pure ()
    other -> failTest ("x did not align: " <> show other)
  assertGrid "y remains an independent grid snap" (canvasUnit 11) vertical

exactOutsideThreshold :: IO ()
exactOutsideThreshold = do
  draggedIdentity <- requireJust "exact dragged id" (nodeId "exact-dragged")
  dragged <- unitBoxAt (canvasUnit (713 / 100)) (canvasUnit (1113 / 100))
  slide <- requireRight "large slide" (mkSize (canvasUnit 100) (canvasUnit 100))
  config <-
    requireRight
      "snap config"
      (mkSnapConfig (canvasUnit (1 / 100)) (Just (canvasUnit (1 / 2))) slide [])
  bindingConfig <-
    requireRight
      "binding config"
      (mkBindingConfig (canvasUnit (1 / 100)) (canvasUnit (1 / 100)))
  let result =
        resolveDrag
          DragRequest
            { dragNodeIdentity = draggedIdentity
            , dragExcludedBindingTargets = Set.empty
            , dragMode = SnappingDrag
            , dragProposedBox = dragged
            , dragPeers = []
            , dragSnapConfig = config
            , dragBindingConfig = bindingConfig
            }
  assertEqual
    "exact proposal remains"
    (boxCenter dragged)
    (dragResolvedCenter result)

bindingRange :: IO ()
bindingRange = do
  peerIdentity <- requireJust "peer" (nodeId "binding-peer")
  peer <- unitBoxAt (canvasUnit 5) (canvasUnit 5)
  overlapping <- unitBoxAt (canvasUnit (11 / 2)) (canvasUnit 5)
  distant <- unitBoxAt (canvasUnit 8) (canvasUnit 5)
  config <-
    requireRight
      "binding config"
      (mkBindingConfig (canvasUnit (1 / 5)) (canvasUnit (1 / 2)))
  assertEqual
    "overlap offers no binding"
    []
    (bindingCandidates config overlapping [PeerBox peerIdentity peer])
  assertEqual
    "past max gap detaches"
    []
    (bindingCandidates config distant [PeerBox peerIdentity peer])

connectorLaws :: IO ()
connectorLaws = do
  let anchors =
        AbsoluteAnchor origin
          :| [ RelativeAnchor KeepCurrent (vector (canvasUnit 1) (canvasUnit 0))
             , RelativeAnchor KeepCurrent (vector (canvasUnit 0) (canvasUnit 1))
             ]
      segments = [StraightSegment, StraightSegment]
  case mkConnectorPath anchors [StraightSegment] OpenPath of
    Left (OpenPathSegmentCountMismatch 3 1) -> pure ()
    other -> failTest ("open path cardinality: " <> show other)
  path <- requireRight "connector path" (mkConnectorPath anchors segments OpenPath)
  resolved <- requireRight "connector resolution" (resolveConnectorPath Map.empty path)
  assertEqual
    "relative + does not advance current"
    ( origin
        :| [ point (canvasUnit 1) (canvasUnit 0)
           , point (canvasUnit 0) (canvasUnit 1)
           ]
    )
    (resolvedAnchors resolved)

orthogonalElbowLaw :: IO ()
orthogonalElbowLaw = do
  let end = point (canvasUnit 3) (canvasUnit 2)
      anchors = AbsoluteAnchor origin :| [AbsoluteAnchor end]
  path <-
    requireRight
      "orthogonal connector"
      (mkConnectorPath anchors [OrthogonalSegment HorizontalThenVertical] OpenPath)
  resolved <- requireRight "orthogonal resolution" (resolveConnectorPath Map.empty path)
  assertEqual
    "horizontal then vertical elbow"
    [ResolvedOrthogonal origin (point (canvasUnit 3) (canvasUnit 0)) end]
    (resolvedSegments resolved)

barrierLaw :: IO ()
barrierLaw = do
  first <- testNode "front-a"
  second <- testNode "front-b"
  barrierIdentity <- requireJust "barrier id" (barrierId "opaque")
  source <- requireJust "source ref" (sourceRef "opaque-source")
  pictureValue <-
    requireRight
      "picture"
      ( mkPicture
          [ ObjectEntry (CanvasNode first)
          , BarrierEntry (OpaqueStatementBarrier barrierIdentity source)
          , ObjectEntry (CanvasNode second)
          ]
      )
  case reorderElement TowardFront (NodeElement (nodeIdentifier first)) pictureValue of
    Left (ReorderBlocked _) -> pure ()
    other -> failTest ("barrier reorder result: " <> show other)

pictureIdentityLaw :: IO ()
pictureIdentityLaw = do
  node <- testNode "duplicate"
  case
      mkPicture
        [ ObjectEntry (CanvasNode node)
        , ObjectEntry (CanvasNode node)
        ] of
    Left (DuplicateElementId identity) ->
      assertEqual "duplicate identity" (NodeElement (nodeIdentifier node)) identity
    other -> failTest ("duplicate picture result: " <> show other)

overlayLaw :: IO ()
overlayLaw = do
  second <- requireJust "step 2" (mkOverlayStep 2)
  fourth <- requireJust "step 4" (mkOverlayStep 4)
  fifth <- requireJust "step 5" (mkOverlayStep 5)
  range <- requireJust "step range" (stepsBetween second fourth)
  let hook = VisibleDuring (range :| [singleStep fifth])
  assertTrue "step 2 visible" (overlayVisibleAt second hook)
  assertTrue "step 5 visible" (overlayVisibleAt fifth hook)
  assertEqual "finite last step" fifth (overlayFinalStep hook)
  assertEqual "numeric accessor" 5 (overlayStepNumber fifth)

contentLaw :: IO ()
contentLaw = do
  opaqueSource <- requireJust "opaque ref" (sourceRef "unsupported-run")
  let provenance = AuthoredProvenance LaTeX originValue
      value =
        content
          [ TransparentContainer
              (CanvasProvenance HTML)
              (GenericContainer "div")
              [ StyledRun
                  provenance
                  (Strong :| [])
                  [TextRun (CanvasProvenance Markdown) "mixed"]
              , OpaqueMath provenance InlineMath "e^{i\\pi}+1=0"
              ]
          , UnsupportedContent
              SourceBackedContent
                { sourceBackedReference = opaqueSource
                , sourceBackedDialect = LaTeX
                , sourceBackedKind = UnsupportedSyntax
                }
          ]
  assertEqual "authored dialect" LaTeX (provenanceDialect provenance)
  assertEqual "authored origin" (Just originValue) (provenanceOrigin provenance)
  assertEqual "content tree remains intact" 2 (length (contentNodes value))
  where
    originValue = ReadOnly OpaqueSource Nothing

outlineMappingLaw :: IO ()
outlineMappingLaw = do
  targetSize <- requireRight "outline target" (mkSize (canvasUnit 4) (canvasUnit 2))
  let target = box (point (canvasUnit 10) (canvasUnit 5)) targetSize
  assertEqual
    "outline top-right maps affinely"
    (point (canvasUnit 12) (canvasUnit 6))
    (outlinePointToCanvas target (outlinePoint 1 1))

bindingRequest :: DragMode -> IO DragRequest
bindingRequest mode = do
  peerIdentity <- requireJust "peer id" (nodeId "peer")
  draggedIdentity <- requireJust "dragged id" (nodeId "dragged")
  dragged <- unitBoxAt (canvasUnit (33 / 5)) (canvasUnit 5)
  peerSize <- requireRight "peer size" (mkSize (canvasUnit 2) (canvasUnit 2))
  slide <- requireRight "slide size" (mkSize (canvasUnit 16) (canvasUnit 9))
  region <- requireJust "guide id" (regionId "binding-guide")
  snapConfig <-
    requireRight
      "snap config"
      ( mkSnapConfig
          (canvasUnit (1 / 5))
          (Just (canvasUnit (1 / 2)))
          slide
          [ AxisReference
              HorizontalAxis
              (canvasUnit (33 / 5))
              (ThemeRegionAlignment region)
          ]
      )
  bindingConfig <-
    requireRight
      "binding config"
      (mkBindingConfig (canvasUnit (1 / 5)) (canvasUnit (1 / 2)))
  pure
    DragRequest
      { dragNodeIdentity = draggedIdentity
      , dragExcludedBindingTargets = Set.empty
      , dragMode = mode
      , dragProposedBox = dragged
      , dragPeers =
          [PeerBox peerIdentity (box (point (canvasUnit 5) (canvasUnit 5)) peerSize)]
      , dragSnapConfig = snapConfig
      , dragBindingConfig = bindingConfig
      }

defaultSnapConfig :: [AxisReference] -> IO SnapConfig
defaultSnapConfig references = do
  slide <- requireRight "slide size" (mkSize (canvasUnit 16) (canvasUnit 9))
  requireRight
    "snap config"
    ( mkSnapConfig
        (canvasUnit (1 / 5))
        (Just (canvasUnit (1 / 2)))
        slide
        references
    )

spacingPeers :: IO [PeerBox]
spacingPeers = do
  leftIdentity <- requireJust "left peer" (nodeId "left")
  rightIdentity <- requireJust "right peer" (nodeId "right")
  left <- unitBoxAt (canvasUnit 3) (canvasUnit 5)
  right <- unitBoxAt (canvasUnit 7) (canvasUnit 5)
  pure [PeerBox leftIdentity left, PeerBox rightIdentity right]

testNode :: Text -> IO Node
testNode label = do
  identity <- requireJust "node id" (nodeId label)
  pure
    Node
      { nodeIdentifier = identity
      , nodePlacement = AbsolutePlacement origin Centre
      , nodeOutline = PrimitiveGeometry RectangleOutline
      , nodeContent = emptyContent
      , nodePropertyOverrides = emptyNodePropertyPatch
      , nodeAnimationRefs = []
      , nodeAccessibility = DecorativeNode
      }

unitBoxAt :: CanvasUnit -> CanvasUnit -> IO Box
unitBoxAt x y = do
  sizeValue <- requireRight "unit size" (mkSize (canvasUnit 1) (canvasUnit 1))
  pure (box (point x y) sizeValue)

origin :: Point
origin = point (canvasUnit 0) (canvasUnit 0)

assertGrid :: String -> CanvasUnit -> Maybe AxisCandidate -> IO ()
assertGrid label expected candidate =
  case candidate of
    Just (GridSnap value) ->
      assertEqual label expected (gridResolvedCoordinate value)
    other -> failTest (label <> ": " <> show other)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $
    failTest
      ( label
          <> ": expected "
          <> show expected
          <> ", got "
          <> show actual
      )

assertTrue :: String -> Bool -> IO ()
assertTrue label condition =
  unless condition (failTest (label <> ": condition was false"))

requireJust :: String -> Maybe value -> IO value
requireJust label result =
  case result of
    Just value -> pure value
    Nothing -> failTest (label <> ": unexpectedly invalid")

requireRight :: Show problem => String -> Either problem value -> IO value
requireRight label result =
  case result of
    Right value -> pure value
    Left problem -> failTest (label <> ": " <> show problem)

failTest :: String -> IO value
failTest message = do
  putStrLn ("FAIL: " <> message)
  exitFailure
