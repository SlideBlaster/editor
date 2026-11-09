{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import SlideBlaster.Canvas qualified as Canvas
import SlideBlaster.Presentation qualified as Presentation
import SlideBlaster.Render
import SlideBlaster.Source (initialRevision)

import Data.ByteString qualified as ByteString
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text

main :: IO ()
main =
  case sequence checks of
    Left message -> ioError (userError message)
    Right _ -> putStrLn "slideblaster-render tests passed (21 laws)"
  where
    checks =
      [ relativeLayoutCheck
      , cycleCheck
      , measurementCoverageCheck
      , measurementResourceCheck
      , validPlanFenceCheck
      , duplicateIdentityCheck
      , surfaceOwnershipCheck
      , reversedLayerCheck
      , primitiveLayerCheck
      , interactionOwnerCheck
      , missingResourceCheck
      , resourceKindCheck
      , animationMembershipCheck
      , furnitureMultipartCheck
      , measurementWidthCheck
      , styleGeometryValidationCheck
      , richContentCheck
      , elementPrimitiveCorrelationCheck
      , clickTargetCoherenceCheck
      , filledArrowTipCheck
      , outlineArcLoweringCheck
      ]

outlineArcLoweringCheck :: Either String ()
outlineArcLoweringCheck = do
  radii <-
    requireRight
      "outline arc radii"
      (Canvas.mkArcRadii 1 1)
  path <-
    requireRight
      "outline arc path"
      ( Canvas.mkPathOutline
          ( Canvas.MovePath (Canvas.outlinePoint (-1) 0)
              :| [ Canvas.ArcPath
                      radii
                      0
                      Canvas.LargeArc
                      Canvas.ClockwiseArc
                      (Canvas.outlinePoint 1 0)
                 ]
          )
      )
  size <-
    requireRight
      "outline target size"
      (Canvas.mkSize (canvasUnit 4) (canvasUnit 2))
  outlines <-
    requireRight
      "outline lowering"
      ( lowerOutlineRef
          (const Nothing)
          ( Canvas.box
              (Canvas.point (canvasUnit 8) (canvasUnit (9 / 2)))
              size
          )
          (Canvas.PathGeometry path)
      )
  case outlines of
    outline :| [] ->
      case renderOutlineView outline of
        RenderPathOutlineView
          RenderNonZeroFill
          (renderPath :| []) ->
            case renderPathSegments renderPath of
              RenderArcTo
                renderRadii
                0
                RenderLargeArc
                RenderClockwiseArc
                endpoint
                  :| []
                    | renderPathStart renderPath
                        == Canvas.point
                          (canvasUnit 6)
                          (canvasUnit (9 / 2))
                        && renderArcRadiusX renderRadii == canvasUnit 2
                        && renderArcRadiusY renderRadii == canvasUnit 1
                        && endpoint
                          == Canvas.point
                            (canvasUnit 10)
                            (canvasUnit (9 / 2)) ->
                        Right ()
              _ -> Left "resolved path did not retain its elliptical arc"
        _ -> Left "path outline lowered to the wrong render primitive"
    _ -> Left "one path outline did not lower to exactly one outline"

relativeLayoutCheck :: Either String ()
relativeLayoutCheck = do
  firstId <- requireMaybe "first node id" (Canvas.nodeId "first")
  secondId <- requireMaybe "second node id" (Canvas.nodeId "second")
  size <-
    requireRight
      "node size"
      (Canvas.mkSize (canvasUnit 2) (canvasUnit 1))
  let first =
        NodeLayoutInput
          { layoutInputIdentifier = firstId
          , layoutInputPlacement =
              Canvas.AbsolutePlacement
                (Canvas.point zero zero)
                Canvas.Centre
          , layoutInputSize = size
          }
      second =
        NodeLayoutInput
          { layoutInputIdentifier = secondId
          , layoutInputPlacement =
              Canvas.RelativeNodePlacement
                Canvas.RelativePlacement
                  { Canvas.relativeTarget = firstId
                  , Canvas.relativeSide = Canvas.RightOf
                  , Canvas.relativePrimaryGap = canvasUnit 1
                  , Canvas.relativeSecondaryGap = zero
                  , Canvas.relativeTargetPort = Canvas.East
                  , Canvas.relativeOwnPort = Canvas.West
                  }
          , layoutInputSize = size
          }
  resolved <-
    requireRight
      "relative layout"
      (resolveNodeLayout [first, second])
  case resolved of
    [_firstResolved, secondResolved]
      | Canvas.pointX
          (Canvas.boxCenter (resolvedNodeBox secondResolved))
          == canvasUnit 3 ->
          Right ()
      | otherwise -> Left "relative layout resolved the wrong centre"
    _ -> Left "relative layout did not preserve input cardinality"
  where
    zero = Canvas.canvasUnitFromInteger 0

cycleCheck :: Either String ()
cycleCheck = do
  firstId <- requireMaybe "cycle node a" (Canvas.nodeId "a")
  secondId <- requireMaybe "cycle node b" (Canvas.nodeId "b")
  size <-
    requireRight
      "cycle size"
      (Canvas.mkSize (canvasUnit 1) (canvasUnit 1))
  let relativeTo target =
        Canvas.RelativeNodePlacement
          Canvas.RelativePlacement
            { Canvas.relativeTarget = target
            , Canvas.relativeSide = Canvas.RightOf
            , Canvas.relativePrimaryGap = canvasUnit 1
            , Canvas.relativeSecondaryGap =
                Canvas.canvasUnitFromInteger 0
            , Canvas.relativeTargetPort = Canvas.East
            , Canvas.relativeOwnPort = Canvas.West
            }
      inputs =
        [ NodeLayoutInput firstId (relativeTo secondId) size
        , NodeLayoutInput secondId (relativeTo firstId) size
        ]
  case resolveNodeLayout inputs of
    Left (PlacementCycle path)
      | NonEmpty.toList path == [firstId, secondId, firstId] -> Right ()
      | otherwise -> Left "cycle diagnostic did not retain dependency path"
    Left other -> Left ("unexpected cycle failure: " <> show other)
    Right _ -> Left "relative placement cycle was accepted"

measurementCoverageCheck :: Either String ()
measurementCoverageCheck = do
  address <- sampleElementAddress Presentation.AudienceSurface "node-1"
  part <- requireMaybe "measurement part" (mkMeasurementPart "body")
  size <-
    requireRight
      "measurement size"
      (Canvas.mkSize (canvasUnit 2) (canvasUnit 1))
  (manifest, typography) <- sampleFont
  let ticket = measurementTicketFromWord64 7
      key = MeasurementKey address part
      request =
        MeasurementRequest
          { measurementKey = key
          , measurementContent =
              RenderText "measured text" typography NoRenderHighlight
          , measurementMode = MeasureIntrinsic
          }
  batch <-
    requireRight
      "measurement batch"
      (mkMeasurementBatch ticket manifest [request])
  case completeMeasurements batch [] of
    Left (MissingMeasurementResults missing)
      | not (null missing) -> Right ()
    Left other ->
      Left ("unexpected missing-measurement failure: " <> show other)
    Right _ -> Left "incomplete measurement batch was accepted"
  measurements <-
    requireRight
      "complete measurement batch"
      ( completeMeasurements
          batch
          [MeasurementResult ticket key size]
      )
  if lookupMeasurement key measurements == Just size
    then Right ()
    else Left "completed measurement was not indexed"

measurementResourceCheck :: Either String ()
measurementResourceCheck = do
  address <- sampleElementAddress Presentation.AudienceSurface "node-1"
  part <- requireMaybe "resource measurement part" (mkMeasurementPart "body")
  (_, typography) <- sampleFont
  let request =
        MeasurementRequest
          { measurementKey = MeasurementKey address part
          , measurementContent =
              RenderText "font fenced" typography NoRenderHighlight
          , measurementMode = MeasureIntrinsic
          }
  case
      mkMeasurementBatch
        (measurementTicketFromWord64 8)
        emptyResourceManifest
        [request]
    of
      Left (MeasurementResourceInvalid (ReferencedResourceMissing _)) ->
        Right ()
      Left other ->
        Left ("unexpected measurement resource failure: " <> show other)
      Right _ -> Left "measurement accepted an absent font resource"

validPlanFenceCheck :: Either String ()
validPlanFenceCheck = do
  address <- sampleElementAddress Presentation.AudienceSurface "node-1"
  part <- requireMaybe "render part" (mkRenderPart "shape")
  (slideSize, objectBox) <- sampleSizes
  let surface = Presentation.elementAddressSurface address
      item = shapeItem address part objectBox
      layers = RenderLayer ObjectLayer [item] :| []
      ticket = renderTicketFromWord64 11
  plan <-
    requireRight
      "valid plan"
      ( mkRenderPlan
          initialRevision
          ticket
          surface
          Canvas.firstOverlayStep
          slideSize
          emptyResourceManifest
          layers
          Presentation.emptyAnimationTimeline
      )
  if renderPlanRevision plan == initialRevision
      && renderPlanTicket plan == ticket
      && renderPlanSurface plan == surface
      && renderPlanStep plan == Canvas.firstOverlayStep
      && renderPlanSize plan == slideSize
      && renderPlanResources plan == emptyResourceManifest
    then Right ()
    else Left "render plan lost a revision/ticket/surface/step/size fence"

duplicateIdentityCheck :: Either String ()
duplicateIdentityCheck = do
  address <- sampleElementAddress Presentation.AudienceSurface "node-1"
  part <- requireMaybe "duplicate part" (mkRenderPart "shape")
  (slideSize, objectBox) <- sampleSizes
  let item = shapeItem address part objectBox
  expectPlanFailure
    "duplicate render identity was accepted"
    isDuplicate
    slideSize
    (Presentation.elementAddressSurface address)
    emptyResourceManifest
    (RenderLayer ObjectLayer [item, item] :| [])
    Presentation.emptyAnimationTimeline
  where
    isDuplicate failure =
      case failure of
        DuplicateRenderIdentity _ -> True
        _ -> False

surfaceOwnershipCheck :: Either String ()
surfaceOwnershipCheck = do
  audienceAddress <-
    sampleElementAddress Presentation.AudienceSurface "node-1"
  notesAddress <- sampleElementAddress Presentation.NotesSurface "node-1"
  part <- requireMaybe "surface part" (mkRenderPart "shape")
  (slideSize, objectBox) <- sampleSizes
  let foreignItem = shapeItem notesAddress part objectBox
  expectPlanFailure
    "cross-surface render item was accepted"
    isOutside
    slideSize
    (Presentation.elementAddressSurface audienceAddress)
    emptyResourceManifest
    (RenderLayer ObjectLayer [foreignItem] :| [])
    Presentation.emptyAnimationTimeline
  where
    isOutside failure =
      case failure of
        RenderIdentityOutsideSurface _ _ -> True
        _ -> False

reversedLayerCheck :: Either String ()
reversedLayerCheck = do
  address <- sampleElementAddress Presentation.AudienceSurface "node-1"
  part <- requireMaybe "order part" (mkRenderPart "shape")
  (slideSize, objectBox) <- sampleSizes
  let layers =
        RenderLayer ObjectLayer [shapeItem address part objectBox]
          :| [RenderLayer BackgroundLayer []]
  expectPlanFailure
    "reversed render layers were accepted"
    isOrderFailure
    slideSize
    (Presentation.elementAddressSurface address)
    emptyResourceManifest
    layers
    Presentation.emptyAnimationTimeline
  where
    isOrderFailure failure =
      case failure of
        RenderLayerOrderInvalid ObjectLayer BackgroundLayer -> True
        _ -> False

primitiveLayerCheck :: Either String ()
primitiveLayerCheck = do
  address <- sampleElementAddress Presentation.AudienceSurface "node-1"
  part <- requireMaybe "primitive part" (mkRenderPart "content")
  (slideSize, objectBox) <- sampleSizes
  let badItem =
        (shapeItem address part objectBox)
          { renderItemPrimitive =
              ContentPrimitive
                (RenderContainer ParagraphFlow [])
                objectBox
          }
  expectPlanFailure
    "content primitive in the object layer was accepted"
    isWrongPrimitive
    slideSize
    (Presentation.elementAddressSurface address)
    emptyResourceManifest
    (RenderLayer ObjectLayer [badItem] :| [])
    Presentation.emptyAnimationTimeline
  where
    isWrongPrimitive failure =
      case failure of
        RenderPrimitiveInWrongLayer
          _
          ContentPrimitiveKind
          ObjectLayer -> True
        _ -> False

interactionOwnerCheck :: Either String ()
interactionOwnerCheck = do
  owner <- sampleElementAddress Presentation.AudienceSurface "node-a"
  selected <- sampleElementAddress Presentation.AudienceSurface "node-b"
  part <- requireMaybe "interaction part" (mkRenderPart "shape")
  (slideSize, objectBox) <- sampleSizes
  let badItem =
        (shapeItem owner part objectBox)
          { renderItemInteraction = SelectElement selected
          }
  expectPlanFailure
    "element A was allowed to select element B"
    isMismatch
    slideSize
    (Presentation.elementAddressSurface owner)
    emptyResourceManifest
    (RenderLayer ObjectLayer [badItem] :| [])
    Presentation.emptyAnimationTimeline
  where
    isMismatch failure =
      case failure of
        RenderInteractionIdentityMismatch _ _ -> True
        _ -> False

missingResourceCheck :: Either String ()
missingResourceCheck = do
  address <- sampleElementAddress Presentation.AudienceSurface "image-node"
  part <- requireMaybe "image part" (mkRenderPart "image")
  image <- requireMaybe "image resource id" (mkResourceId "hero-image")
  binary <- requireMaybe "binary resource id" (mkResourceId "demo-video")
  (_, typography) <- sampleFont
  (slideSize, objectBox) <- sampleSizes
  let imageItem =
        (shapeItem address part objectBox)
          { renderItemPrimitive =
              ImagePrimitive image objectBox RenderContainImage
          }
  expectPlanFailure
    "image primitive with no embedded resource was accepted"
    isMissing
    slideSize
    (Presentation.elementAddressSurface address)
    emptyResourceManifest
    (RenderLayer ObjectLayer [imageItem] :| [])
    Presentation.emptyAnimationTimeline
  let contentItem =
        (shapeItem address part objectBox)
          { renderItemPrimitive =
              ContentPrimitive
                (RenderText "missing font" typography NoRenderHighlight)
                objectBox
          }
  expectPlanFailure
    "content with no embedded font was accepted"
    isMissing
    slideSize
    (Presentation.elementAddressSurface address)
    emptyResourceManifest
    (RenderLayer ContentLayer [contentItem] :| [])
    Presentation.emptyAnimationTimeline
  let mediaItem =
        (shapeItem address part objectBox)
          { renderItemPrimitive =
              MediaPrimitive
                binary
                objectBox
                ( RenderVideo
                    RenderMediaPlayback
                      { renderMediaControls = ShowMediaControls
                      , renderMediaStart = StartMediaManually
                      , renderMediaLoop = PlayMediaOnce
                      , renderMediaAudio = MediaAudible
                      }
                )
          }
  expectPlanFailure
    "media with no embedded binary was accepted"
    isMissing
    slideSize
    (Presentation.elementAddressSurface address)
    emptyResourceManifest
    (RenderLayer ContentLayer [mediaItem] :| [])
    Presentation.emptyAnimationTimeline
  where
    isMissing failure =
      case failure of
        RenderResourceInvalid (ReferencedResourceMissing _) -> True
        _ -> False

resourceKindCheck :: Either String ()
resourceKindCheck = do
  address <- sampleElementAddress Presentation.AudienceSurface "image-node"
  part <- requireMaybe "kind part" (mkRenderPart "image")
  resourceId <- requireMaybe "kind resource id" (mkResourceId "hero-image")
  font <-
    requireRight
      "wrong-kind resource"
      ( mkRenderResource
          resourceId
          (FontResource Woff2Font)
          (ByteString.pack [1, 2, 3])
      )
  manifest <- requireRight "wrong-kind manifest" (mkResourceManifest [font])
  (slideSize, objectBox) <- sampleSizes
  let item =
        (shapeItem address part objectBox)
          { renderItemPrimitive =
              ImagePrimitive resourceId objectBox RenderContainImage
          }
  expectPlanFailure
    "font resource was accepted at an image reference"
    isMismatch
    slideSize
    (Presentation.elementAddressSurface address)
    manifest
    (RenderLayer ObjectLayer [item] :| [])
    Presentation.emptyAnimationTimeline
  where
    isMismatch failure =
      case failure of
        RenderResourceInvalid (ReferencedResourceKindMismatch _ _) -> True
        _ -> False

animationMembershipCheck :: Either String ()
animationMembershipCheck = do
  renderedAddress <-
    sampleElementAddress Presentation.AudienceSurface "rendered"
  missingId <- requireMaybe "missing animation node" (Canvas.nodeId "missing")
  part <- requireMaybe "animation part" (mkRenderPart "shape")
  missingAnimation <- sampleAnimation (Canvas.NodeElement missingId)
  (slideSize, objectBox) <- sampleSizes
  let surface = Presentation.elementAddressSurface renderedAddress
      layers =
        RenderLayer
          ObjectLayer
          [shapeItem renderedAddress part objectBox]
          :| []
  expectPlanFailure
    "animation target absent from the render plan was accepted"
    isMissingTarget
    slideSize
    surface
    emptyResourceManifest
    layers
    =<< requireRight
      "missing-target timeline"
      (Presentation.mkAnimationTimeline [missingAnimation])
  presentAnimation <-
    sampleAnimation (Presentation.elementAddressElement renderedAddress)
  presentTimeline <-
    requireRight
      "present-target timeline"
      (Presentation.mkAnimationTimeline [presentAnimation])
  _ <-
    requireRight
      "present animation target"
      ( mkRenderPlan
          initialRevision
          (renderTicketFromWord64 20)
          surface
          Canvas.firstOverlayStep
          slideSize
          emptyResourceManifest
          layers
          presentTimeline
      )
  Right ()
  where
    isMissingTarget failure =
      case failure of
        RenderAnimationTargetMissing _ _ -> True
        _ -> False

furnitureMultipartCheck :: Either String ()
furnitureMultipartCheck = do
  address <- sampleElementAddress Presentation.AudienceSurface "node-1"
  furniture <-
    requireMaybe "furniture id" (Canvas.furnitureId "page-number")
  backingPart <- requireMaybe "furniture backing part" (mkRenderPart "backing")
  labelPart <- requireMaybe "furniture label part" (mkRenderPart "label")
  (slideSize, objectBox) <- sampleSizes
  let surface = Presentation.elementAddressSurface address
      backing =
        inertShapeItem
          (FurnitureRender surface furniture backingPart)
          objectBox
      label =
        inertShapeItem
          (FurnitureRender surface furniture labelPart)
          objectBox
  _ <-
    requireRight
      "multipart furniture plan"
      ( mkRenderPlan
          initialRevision
          (renderTicketFromWord64 21)
          surface
          Canvas.firstOverlayStep
          slideSize
          emptyResourceManifest
          (RenderLayer FrontFurnitureLayer [backing, label] :| [])
          Presentation.emptyAnimationTimeline
      )
  Right ()

measurementWidthCheck :: Either String ()
measurementWidthCheck = do
  address <- sampleElementAddress Presentation.AudienceSurface "measure-width"
  part <- requireMaybe "width measurement part" (mkMeasurementPart "body")
  (manifest, typography) <- sampleFont
  let key = MeasurementKey address part
      request =
        MeasurementRequest
          { measurementKey = key
          , measurementContent =
              RenderText "cannot wrap at zero" typography NoRenderHighlight
          , measurementMode = MeasureWithin zero
          }
  case
      mkMeasurementBatch
        (measurementTicketFromWord64 30)
        manifest
        [request]
    of
      Left (MeasurementWidthMustBePositive rejectedKey rejectedWidth)
        | rejectedKey == key
        , rejectedWidth == zero ->
            Right ()
      Left other ->
        Left ("unexpected width validation failure: " <> show other)
      Right _ -> Left "zero-width measurement constraint was accepted"
  where
    zero = Canvas.canvasUnitFromInteger 0

styleGeometryValidationCheck :: Either String ()
styleGeometryValidationCheck = do
  firstOffset <-
    requireMaybe "first gradient offset" (mkRenderGradientOffset (3 / 4))
  secondOffset <-
    requireMaybe "second gradient offset" (mkRenderGradientOffset (1 / 4))
  startOffset <-
    requireMaybe "gradient start offset" (mkRenderGradientOffset 0)
  endOffset <-
    requireMaybe "gradient end offset" (mkRenderGradientOffset 1)
  let firstStop =
        RenderGradientStop firstOffset (RenderColour 0 0 0 255)
      secondStop =
        RenderGradientStop secondOffset (RenderColour 255 255 255 255)
      orderedStart =
        RenderGradientStop startOffset (RenderColour 0 0 0 255)
      orderedEnd =
        RenderGradientStop endOffset (RenderColour 255 255 255 255)
      origin = Canvas.point zero zero
      path =
        mkRenderPath
          origin
          (RenderLineTo (Canvas.point (canvasUnit 1) zero) :| [])
          RenderOpenPath
      collinear =
        origin
          :| [ Canvas.point (canvasUnit 1) (canvasUnit 1)
             , Canvas.point (canvasUnit 2) (canvasUnit 2)
             ]
  case mkLinearRenderGradient origin origin (firstStop :| [secondStop]) of
    Left RenderGradientStopsOutOfOrder {} -> Right ()
    Left other -> Left ("unexpected gradient validation failure: " <> show other)
    Right _ -> Left "unordered gradient stops were accepted"
  case
      mkLinearRenderGradient
        origin
        origin
        (orderedStart :| [orderedEnd])
    of
      Left RenderLinearGradientNeedsDistinctPoints -> Right ()
      Left other ->
        Left ("unexpected linear-gradient validation failure: " <> show other)
      Right _ -> Left "coincident linear-gradient endpoints were accepted"
  case
      mkRadialRenderGradient
        origin
        zero
        (orderedStart :| [orderedEnd])
    of
      Left RenderGradientRadiusMustBePositive {} -> Right ()
      Left other ->
        Left ("unexpected radial-gradient validation failure: " <> show other)
      Right _ -> Left "zero-radius radial gradient was accepted"
  case mkRenderCustomDash (canvasUnit 1 :| [zero]) of
    Left RenderDashLengthsMustBePositive {} -> Right ()
    Left other -> Left ("unexpected dash validation failure: " <> show other)
    Right _ -> Left "zero-length custom dash was accepted"
  case
      mkRenderStroke
        (RenderColour 0 0 0 255)
        zero
        renderSolidDash
        RenderButtCap
        RenderMiterJoin
    of
      Left RenderStrokeWidthMustBePositive {} -> Right ()
      Left other -> Left ("unexpected stroke validation failure: " <> show other)
      Right _ -> Left "zero-width stroke was accepted"
  case
      mkRenderShadow
        (Canvas.vector zero zero)
        negative
        zero
        (RenderColour 0 0 0 128)
    of
      Left RenderShadowBlurMustBeNonNegative {} -> Right ()
      Left other -> Left ("unexpected shadow validation failure: " <> show other)
      Right _ -> Left "negative shadow blur was accepted"
  case
      mkRenderShadow
        (Canvas.vector zero zero)
        zero
        negative
        (RenderColour 0 0 0 128)
    of
      Left RenderShadowSpreadMustBeNonNegative {} -> Right ()
      Left other ->
        Left ("unexpected shadow-spread validation failure: " <> show other)
      Right _ -> Left "negative shadow spread was accepted"
  case mkRenderCornerRadii negative zero zero zero of
    Left RenderCornerRadiusMustBeNonNegative {} -> Right ()
    Left other -> Left ("unexpected radius validation failure: " <> show other)
    Right _ -> Left "negative corner radius was accepted"
  case mkRenderPolygon collinear of
    Left RenderPolygonHasZeroArea -> Right ()
    Left other -> Left ("unexpected polygon validation failure: " <> show other)
    Right _ -> Left "degenerate polygon was accepted"
  case mkRenderPathHitRegion path zero of
    Left RenderHitWidthMustBePositive {} -> Right ()
    Left other -> Left ("unexpected hit-width validation failure: " <> show other)
    Right _ -> Left "zero-width path hit region was accepted"
  where
    zero = Canvas.canvasUnitFromInteger 0
    negative = Canvas.canvasUnit (-1)

richContentCheck :: Either String ()
richContentCheck = do
  (manifest, typography) <- sampleFont
  link <- requireRight "typed web link" (mkRenderWebLink RenderHttps "example.com")
  rowSpan <- requireMaybe "positive row span" (mkRenderTableSpan 2)
  columnSpan <- requireMaybe "positive column span" (mkRenderTableSpan 1)
  let highlighted =
        RenderText
          "highlight"
          typography
          (HighlightWith (RenderColour 255 240 120 255))
      linked =
        RenderLink
          link
          [RenderText "link" typography NoRenderHighlight]
      math =
        RenderMath
          RenderMathPresentation
            { renderMathDisplay = RenderInlineMath
            , renderMathAccessibilityLabel = "x squared"
            , renderMathRoot =
                RenderMathScripts
                  ( RenderMathToken
                      RenderMathIdentifier
                      "x"
                      typography
                  )
                  Nothing
                  ( Just
                      ( RenderMathToken
                          RenderMathNumber
                          "2"
                          typography
                      )
                  )
            }
      table =
        RenderTableContent
          RenderTable
            { renderTableHeadRows = []
            , renderTableBodyRows =
                [ RenderTableRow
                    [ RenderTableCell
                        { renderTableCellKind = RenderDataCell
                        , renderTableCellRowSpan = rowSpan
                        , renderTableCellColumnSpan = columnSpan
                        , renderTableCellContent =
                            [RenderText "cell" typography NoRenderHighlight]
                        }
                    ]
                ]
            }
      content =
        RenderContainer
          ParagraphFlow
          [ highlighted
          , linked
          , math
          , table
          , RenderInlineOverlay InlineHiddenReserved highlighted
          ]
      plain = renderContentPlainText content
  if Text.isInfixOf "x squared" plain
      && Text.isInfixOf "cell" plain
      && not (null (renderContentResourceReferences content))
      && renderLinkTargetHref link == "https://example.com"
      && renderTableSpanValue rowSpan == 2
      && manifest /= emptyResourceManifest
    then Right ()
    else Left "rich render content lost typed presentation information"

elementPrimitiveCorrelationCheck :: Either String ()
elementPrimitiveCorrelationCheck = do
  address <- sampleElementAddress Presentation.AudienceSurface "ordinary-node"
  part <- requireMaybe "correlation part" (mkRenderPart "connector")
  (slideSize, objectBox) <- sampleSizes
  let start = Canvas.point zero zero
      path =
        mkRenderPath
          start
          (RenderLineTo (Canvas.point (canvasUnit 1) zero) :| [])
          RenderOpenPath
      item =
        (shapeItem address part objectBox)
          { renderItemPrimitive =
              ConnectorPrimitive path noRenderStroke noRenderArrowTips
          }
  expectPlanFailure
    "node identity was allowed to own connector geometry"
    isMismatch
    slideSize
    (Presentation.elementAddressSurface address)
    emptyResourceManifest
    (RenderLayer ConnectorLayer [item] :| [])
    Presentation.emptyAnimationTimeline
  where
    zero = Canvas.canvasUnitFromInteger 0
    isMismatch failure =
      case failure of
        RenderElementPrimitiveMismatch
          (Canvas.NodeElement _)
          ConnectorPrimitiveKind -> True
        _ -> False

clickTargetCoherenceCheck :: Either String ()
clickTargetCoherenceCheck = do
  renderedAddress <-
    sampleElementAddress Presentation.AudienceSurface "click-rendered"
  missingId <- requireMaybe "missing click node" (Canvas.nodeId "click-missing")
  part <- requireMaybe "click part" (mkRenderPart "shape")
  animation <-
    sampleTriggeredAnimation
      "click-animation"
      ( Presentation.PictureElement
          (Presentation.elementAddressElement renderedAddress)
      )
      ( Presentation.OnTargetClick
          Canvas.firstOverlayStep
          (Presentation.PictureElement (Canvas.NodeElement missingId))
      )
  timeline <-
    requireRight
      "click animation timeline"
      (Presentation.mkAnimationTimeline [animation])
  (slideSize, objectBox) <- sampleSizes
  expectPlanFailure
    "animation click target absent from the plan was accepted"
    isMissing
    slideSize
    (Presentation.elementAddressSurface renderedAddress)
    emptyResourceManifest
    (RenderLayer ObjectLayer [shapeItem renderedAddress part objectBox] :| [])
    timeline
  where
    isMissing failure =
      case failure of
        RenderAnimationClickTargetMissing _ (Canvas.NodeElement _) -> True
        _ -> False

filledArrowTipCheck :: Either String ()
filledArrowTipCheck = do
  address <-
    sampleConnectorAddress Presentation.AudienceSurface "arrow-connector"
  part <- requireMaybe "arrow part" (mkRenderPart "path")
  (slideSize, _) <- sampleSizes
  stroke <-
    requireRight
      "arrow stroke"
      ( mkRenderStroke
          (RenderColour 20 20 20 255)
          (canvasUnit (1 / 20))
          renderSolidDash
          RenderRoundCap
          RenderRoundJoin
      )
  let start = Canvas.point zero zero
      end = Canvas.point (canvasUnit 2) zero
      path = mkRenderPath start (RenderLineTo end :| []) RenderOpenPath
  tipOutline <-
    requireRight
      "filled arrow outline"
      ( mkRenderPolygon
          ( end
              :| [ Canvas.point (canvasUnit (3 / 2)) (canvasUnit (1 / 4))
                 , Canvas.point (canvasUnit (3 / 2)) (canvasUnit (-1 / 4))
                 ]
          )
      )
  hitRegion <-
    requireRight
      "arrow hit region"
      (mkRenderPathHitRegion path (canvasUnit (1 / 5)))
  let item =
        RenderItem
          { renderItemIdentity = ElementRender address part
          , renderItemVisibility = RenderVisible
          , renderItemPrimitive =
              ConnectorPrimitive
                path
                stroke
                RenderArrowTips
                  { renderStartArrowTip = NoRenderArrowTip
                  , renderEndArrowTip =
                      FilledRenderArrowTip tipOutline sampleShapeStyle
                  }
          , renderItemTransform = identityRenderTransform
          , renderItemClip = NoRenderClip
          , renderItemHitRegion = hitRegion
          , renderItemInteraction = SelectElement address
          , renderItemAccessibility = Labelled "arrow connector"
          }
  _ <-
    requireRight
      "filled arrow render plan"
      ( mkRenderPlan
          initialRevision
          (renderTicketFromWord64 32)
          (Presentation.elementAddressSurface address)
          Canvas.firstOverlayStep
          slideSize
          emptyResourceManifest
          (RenderLayer ConnectorLayer [item] :| [])
          Presentation.emptyAnimationTimeline
      )
  Right ()
  where
    zero = Canvas.canvasUnitFromInteger 0

expectPlanFailure
  :: String
  -> (RenderPlanError -> Bool)
  -> Canvas.Size
  -> Presentation.SurfaceAddress
  -> ResourceManifest
  -> NonEmpty RenderLayer
  -> Presentation.AnimationTimeline
  -> Either String ()
expectPlanFailure message predicate slideSize surface resources layers animations =
  case
      mkRenderPlan
        initialRevision
        (renderTicketFromWord64 99)
        surface
        Canvas.firstOverlayStep
        slideSize
        resources
        layers
        animations
    of
      Left failure
        | predicate failure -> Right ()
        | otherwise -> Left ("unexpected plan failure: " <> show failure)
      Right _ -> Left message

shapeItem
  :: Presentation.ElementAddress
  -> RenderPart
  -> Canvas.Box
  -> RenderItem
shapeItem address part objectBox =
  RenderItem
    { renderItemIdentity = ElementRender address part
    , renderItemVisibility = RenderVisible
    , renderItemPrimitive =
        ShapePrimitive
          (rectangleOutline objectBox)
          sampleShapeStyle
    , renderItemTransform = identityRenderTransform
    , renderItemClip = NoRenderClip
    , renderItemHitRegion = renderBoxHitRegion objectBox
    , renderItemInteraction = SelectElement address
    , renderItemAccessibility = Labelled "sample shape"
    }

inertShapeItem :: RenderIdentity -> Canvas.Box -> RenderItem
inertShapeItem identity objectBox =
  RenderItem
    { renderItemIdentity = identity
    , renderItemVisibility = RenderVisible
    , renderItemPrimitive =
        ShapePrimitive
          (rectangleOutline objectBox)
          sampleShapeStyle
    , renderItemTransform = identityRenderTransform
    , renderItemClip = NoRenderClip
    , renderItemHitRegion = noRenderHitRegion
    , renderItemInteraction = Inert
    , renderItemAccessibility = Decorative
    }

rectangleOutline :: Canvas.Box -> RenderOutline
rectangleOutline objectBox =
  mkRenderRectangle objectBox zeroRenderCornerRadii

sampleShapeStyle :: RenderShapeStyle
sampleShapeStyle =
  RenderShapeStyle
    { renderShapePaint =
        solidRenderPaint (RenderColour 245 245 245 255)
    , renderShapeStroke = noRenderStroke
    , renderShapeOpacity = opaqueRenderOpacity
    , renderShapeShadows = []
    }

sampleFont :: Either String (ResourceManifest, RenderTypography)
sampleFont = do
  resourceId <- requireMaybe "font resource id" (mkResourceId "body-font")
  resource <-
    requireRight
      "font resource"
      ( mkRenderResource
          resourceId
          (FontResource Woff2Font)
          (ByteString.pack [119, 79, 70, 50])
      )
  manifest <-
    requireRight "font resource manifest" (mkResourceManifest [resource])
  typography <-
    requireRight
      "direct typography"
      ( mkRenderTypography
          resourceId
          (canvasUnit (3 / 10))
          RenderWeightNormal
          RenderUpright
          RenderNoDecoration
          (RenderColour 0 0 0 255)
          RenderAlignLeft
          RenderAlignTop
          1
      )
  Right (manifest, typography)

sampleAnimation
  :: Canvas.ElementId
  -> Either String Presentation.Animation
sampleAnimation target =
  sampleTriggeredAnimation
    "missing-target-animation"
    (Presentation.PictureElement target)
    Presentation.OnFrameEnter

sampleTriggeredAnimation
  :: Text
  -> Presentation.AnimationTarget
  -> Presentation.AnimationTrigger
  -> Either String Presentation.Animation
sampleTriggeredAnimation identityText target trigger = do
  identity <-
    requireRight
      "animation id"
      (Presentation.mkAnimationId identityText)
  start <-
    requireMaybe
      "animation start"
      (Presentation.mkUnitInterval 0)
  finish <-
    requireMaybe
      "animation finish"
      (Presentation.mkUnitInterval 1)
  track <-
    requireRight
      "animation opacity track"
      ( Presentation.opacityTrack
          target
          ( Presentation.mkKeyframe start start
              :| [Presentation.mkKeyframe finish finish]
          )
      )
  timing <-
    requireRight
      "animation timing"
      ( Presentation.mkAnimationTiming
          (Presentation.milliseconds 0)
          (Presentation.milliseconds 250)
          Presentation.Linear
          Presentation.PlayOnce
          Presentation.FillBoth
      )
  requireRight
    "animation"
    ( Presentation.mkAnimation
        identity
        Presentation.EmphasisEffect
        Presentation.DecorativeMotion
        trigger
        timing
        (track :| [])
    )

sampleSizes :: Either String (Canvas.Size, Canvas.Box)
sampleSizes = do
  slideSize <-
    requireRight
      "slide size"
      (Canvas.mkSize (canvasUnit 16) (canvasUnit 9))
  objectSize <-
    requireRight
      "object size"
      (Canvas.mkSize (canvasUnit 2) (canvasUnit 1))
  Right
    ( slideSize
    , Canvas.box
        (Canvas.point zero zero)
        objectSize
    )
  where
    zero = Canvas.canvasUnitFromInteger 0

sampleElementAddress
  :: Presentation.SurfaceKind
  -> Text
  -> Either String Presentation.ElementAddress
sampleElementAddress kind identityText = do
  frame <- requireRight "frame id" (Presentation.mkFrameId "frame-1")
  identity <-
    requireMaybe
      "address node id"
      (Canvas.nodeId identityText)
  Right
    ( Presentation.elementAddress
        (Presentation.surfaceAddress frame kind)
        (Canvas.NodeElement identity)
    )

sampleConnectorAddress
  :: Presentation.SurfaceKind
  -> Text
  -> Either String Presentation.ElementAddress
sampleConnectorAddress kind identityText = do
  frame <- requireRight "frame id" (Presentation.mkFrameId "frame-1")
  identity <-
    requireMaybe
      "address connector id"
      (Canvas.connectorId identityText)
  Right
    ( Presentation.elementAddress
        (Presentation.surfaceAddress frame kind)
        (Canvas.ConnectorElement identity)
    )

canvasUnit :: Rational -> Canvas.CanvasUnit
canvasUnit = Canvas.canvasUnit

requireMaybe :: String -> Maybe value -> Either String value
requireMaybe label value =
  case value of
    Nothing -> Left ("could not construct " <> label)
    Just resolved -> Right resolved

requireRight
  :: Show failure
  => String
  -> Either failure value
  -> Either String value
requireRight label value =
  case value of
    Left failure -> Left (label <> ": " <> show failure)
    Right resolved -> Right resolved
