{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import Data.Word (Word64)
import SlideBlaster.App
import SlideBlaster.Canvas
import SlideBlaster.Catalog
import SlideBlaster.Document
import SlideBlaster.Export
import SlideBlaster.Presentation
import SlideBlaster.Render
import SlideBlaster.Source

main :: IO ()
main =
  case sequence checks of
    Left message -> ioError (userError message)
    Right _ -> putStrLn "slideblaster-app tests passed"
  where
    checks =
      [ historyCheck
      , commandPolicyCheck
      , diagnosticFreshnessCheck
      , leaseCheck
      , updateFencingCheck
      , canvasEditCheck
      , interactionCheck
      , notesSurfaceFanoutCheck
      , liveAuthoringCheck
      ]

liveAuthoringCheck :: Either String ()
liveAuthoringCheck = do
  initial <- requireRight "live authoring initialization" newLiveAuthoring
  rectangle <- requireMaybe "rectangle shape id" (shapeId "rectangle")
  inserted <-
    requireRight
      "live rectangle insertion"
      ( insertLiveShape
          (liveAuthoringRevision initial)
          rectangle
          (point (canvasUnit 8) (canvasUnit (9 / 2)))
          initial
      )
  assert
    (length (liveAuthoringNodes inserted) == 1)
    "live insertion did not add one ordinary node"
  assert
    (liveAuthoringCanUndo inserted)
    "live insertion did not enter source-style history"
  insertedNode <-
    case liveAuthoringNodes inserted of
      [value] -> Right value
      _ -> Left "live insertion produced an unexpected node list"
  moved <-
    requireRight
      "live snapped move"
      ( moveLiveNode
          (liveAuthoringRevision inserted)
          (nodeIdentifier (liveNodeSemantic insertedNode))
          (point (canvasUnit (161 / 20)) (canvasUnit (221 / 50)))
          SnappingDrag
          inserted
      )
  movedNode <-
    case liveAuthoringNodes moved of
      [value] -> Right value
      _ -> Left "live move produced an unexpected node list"
  assert
    ( boxCenter (liveNodeBox movedNode)
        == point (canvasUnit 8) (canvasUnit (9 / 2))
    )
    "live move did not resolve through the Haskell grid snap"
  case
      moveLiveNode
        (liveAuthoringRevision initial)
        (nodeIdentifier (liveNodeSemantic movedNode))
        (point (canvasUnit 3) (canvasUnit 3))
        SnappingDrag
        moved
    of
      Left (LiveStaleRevision _ _) -> Right ()
      Left other -> Left ("unexpected stale live-move failure: " <> show other)
      Right _ -> Left "stale live gesture changed the authoring state"
  undone <-
    requireRight
      "undo live move"
      (undoLiveAuthoring (liveAuthoringRevision moved) moved)
  assert
    (length (liveAuthoringNodes undone) == 1)
    "undo live move removed the inserted node"
  redone <-
    requireRight
      "redo live move"
      (redoLiveAuthoring (liveAuthoringRevision undone) undone)
  assert
    (liveAuthoringCanUndo redone)
    "redo live move lost the history chain"

historyCheck :: Either String ()
historyCheck = do
  let initial = snapshotFromBytes "a"
      history0 = startHistory initial
  (snapshot1, history1) <-
    requireAdvanced "record first edit" =<<
      requireRight "record first edit" (recordHistoryBytes "b" history0)
  assert
    (revisionToWord64 (snapshotRevision snapshot1) == 1)
    "first history edit did not advance once"
  (snapshot2, history2) <-
    requireAdvanced "undo first edit" =<<
      requireRight "undo first edit" (undoHistory history1)
  assert
    (snapshotBytes snapshot2 == "a")
    "undo did not restore exact prior bytes"
  assert
    (revisionToWord64 (snapshotRevision snapshot2) == 2)
    "undo revived an old revision instead of issuing a fresh one"
  (snapshot3, history3) <-
    requireAdvanced "redo first edit" =<<
      requireRight "redo first edit" (redoHistory history2)
  assert
    (snapshotBytes snapshot3 == "b")
    "redo did not restore exact later bytes"
  (_, history4) <-
    requireAdvanced "second undo" =<<
      requireRight "second undo" (undoHistory history3)
  (_, branched) <-
    requireAdvanced "branching edit" =<<
      requireRight "branching edit" (recordHistoryBytes "c" history4)
  assert (not (canRedo branched)) "branching edit retained stale redo history"
  noOp <-
    requireRight
      "history no-op"
      (recordHistoryBytes "c" branched)
  case noOp of
    HistoryNoOp preserved ->
      assert
        ( snapshotRevision (historyCurrent preserved)
            == snapshotRevision (historyCurrent branched)
        )
        "history no-op advanced the revision"
    HistoryAdvanced {} -> Left "byte-identical history edit was not a no-op"

commandPolicyCheck :: Either String ()
commandPolicyCheck = do
  let capabilities =
        capabilitySet
          [ (StorageCapability, CapabilityAvailable)
          , (DownloadCapability, CapabilityAvailable)
          ]
      context =
        CommandContext
          { commandCapabilities = capabilities
          , commandSemanticReadiness = SyntaxOnlyDocument
          , commandLeaseReadiness = const InertCanvasLease
          , commandDeckReadiness = EmptyDeck
          , commandDiagnosticReadiness = HardDiagnostics
          , commandSelection = NoSelection
          , commandUndoBoundary = AtHistoryBoundary
          , commandRedoBoundary = AtHistoryBoundary
          , commandPresenterReadiness = PresenterStopped
          , commandExportReadiness =
              const ExportWarningsAwaitingConfirmation
          }
  assert
    ( commandAvailability context (Project SaveCurrentSource)
        == CommandEnabled
    )
    "syntax-only source could not be saved"
  case commandAvailability context (Present StartPresentation) of
    CommandDisabled reasons ->
      assert
        (SemanticMeaningUnavailable `elem` reasons)
        "presenter did not report semantic unavailability"
    CommandEnabled -> Left "empty syntax-only document could present"
  case commandAvailability context (Export (GenerateExport StandaloneHtml)) of
    CommandDisabled reasons ->
      assert
        ( ExportWarningConfirmationRequired StandaloneHtml
            `elem` reasons
        )
        "lossy export did not require confirmation"
    CommandEnabled -> Left "unconfirmed lossy export was enabled"

leaseCheck :: Either String ()
leaseCheck = do
  surface <- sampleSurface
  size <- requireRight "lease slide size" (mkSize (canvasUnit 16) (canvasUnit 9))
  plan <-
    requireRight
      "lease render plan"
      ( mkRenderPlan
          initialRevision
          ticket
          surface
          firstOverlayStep
          size
          emptyResourceManifest
          (RenderLayer ObjectLayer [] :| [])
          emptyAnimationTimeline
      )
  let request = paintRequest session initialRevision ticket surface
  authority <-
    requireRight
      "paint acknowledgement"
      (acknowledgePaint request plan)
  assert
    (authorityAllowsEdit request authority)
    "matching painted lease did not grant edit authority"
  let inert = revokeCanvasAuthority NewerDraftExists authority
  assert
    (not (authorityAllowsEdit request inert))
    "revoked painted lease remained writable"
  case
      acknowledgePaint
        (paintRequest session (revisionFromWord64 1) ticket surface)
        plan
    of
      Left (PaintForWrongRevision _ _) -> Right ()
      Left other -> Left ("unexpected stale-paint failure: " <> show other)
      Right _ -> Left "stale render plan regained edit authority"
  where
    session = sessionIdFromWord64 9
    ticket = renderTicketFromWord64 4

updateFencingCheck :: Either String ()
updateFencingCheck = do
  presentation <- samplePresentation
  let initial = snapshotFromBytes "a"
      session = startDocumentSession (sessionIdFromWord64 1) initial
      model = newAppModel session emptyCapabilitySet
  changed <-
    requireRight
      "draft update"
      (update (DraftBytesChanged "b") model)
  case updateEffects changed of
    [AnalyzeSource source] ->
      assert
        (snapshotBytes source == "b")
        "draft update requested analysis of the wrong bytes"
    _ -> Left "draft update did not request exactly one analysis"
  let staleDocument =
        readyDocument
          initial
          ()
          presentation
          (emptyProvenanceMap :: ProvenanceMap Text)
          []
  case update (AnalysisCompleted staleDocument) (updateModel changed) of
    Left (UpdateSessionError (StaleDocumentAnalysis _ _)) -> Right ()
    Left other -> Left ("unexpected stale-analysis failure: " <> show other)
    Right _ -> Left "stale document analysis replaced newer draft state"
  let current = sessionDraft (appDocumentSession (updateModel changed))
      currentDocument =
        readyDocument
          current
          ()
          presentation
          (emptyProvenanceMap :: ProvenanceMap Text)
          []
  accepted <-
    requireRight
      "current analysis"
      (update (AnalysisCompleted currentDocument) (updateModel changed))
  case updateEffects accepted of
    [MeasureAndRender request source _] -> do
      assert
        (snapshotRevision source == snapshotRevision current)
        "current analysis emitted a render request for another revision"
      assert
        (paintRequestRevision request == snapshotRevision current)
        "paint request did not fence the current revision"
      size <-
        requireRight
          "paint completion size"
          (mkSize (canvasUnit 16) (canvasUnit 9))
      plan <-
        requireRight
          "requested paint plan"
          ( mkRenderPlan
              (paintRequestRevision request)
              (paintRequestTicket request)
              (paintRequestSurface request)
              firstOverlayStep
              size
              emptyResourceManifest
              (RenderLayer ObjectLayer [] :| [])
              emptyAnimationTimeline
          )
      let wrongRequest =
            paintRequest
              (paintRequestSession request)
              (paintRequestRevision request)
              (renderTicketFromWord64 999)
              (paintRequestSurface request)
      case update (PaintCompleted wrongRequest plan) (updateModel accepted) of
        Left
          ( UpdateSessionError
              (PaintCompletionDoesNotMatch expected actual)
            ) ->
            assert
              (expected == request && actual == wrongRequest)
              "unsolicited completion reported the wrong pending fence"
        Left other ->
          Left ("unexpected unsolicited-paint failure: " <> show other)
        Right _ ->
          Left "an unsolicited paint completion acquired authority"
      painted <-
        requireRight
          "requested paint completion"
          (update (PaintCompleted request plan) (updateModel accepted))
      let paintedSession = appDocumentSession (updateModel painted)
      assert
        ( authorityAllowsEdit
            request
            (sessionCanvasAuthority
              (paintRequestSurface request)
              paintedSession
            )
        )
        "requested paint did not acquire its surface authority"
    _ -> Left "ready analysis did not request measurement and rendering"

canvasEditCheck :: Either String ()
canvasEditCheck = do
  presentation <- samplePresentation
  nodeIdentity <- requireMaybe "canvas edit node id" (nodeId "canvas-node")
  let source = snapshotFromBytes "before"
      document =
        readyDocument
          source
          ()
          presentation
          (emptyProvenanceMap :: ProvenanceMap Text)
          []
      initialModel =
        newAppModel
          (startDocumentSession (sessionIdFromWord64 41) source)
          emptyCapabilitySet
      operation =
        MoveElement
          (NodeElement nodeIdentity)
          ( AbsolutePlacement
              (point (canvasUnit 4) (canvasUnit 5))
              Centre
          )
  accepted <-
    requireRight
      "canvas edit analysis"
      (update (AnalysisCompleted document) initialModel)
  request <-
    case updateEffects accepted of
      [MeasureAndRender issued sourceForPaint _] -> do
        assert
          (sourceForPaint == source)
          "canvas edit paint request did not retain exact source"
        Right issued
      effects ->
        Left
          ( "canvas edit analysis emitted unexpected effects: "
              <> show (length effects)
          )
  size <- requireRight "canvas edit plan size" (mkSize (canvasUnit 16) (canvasUnit 9))
  plan <-
    requireRight
      "canvas edit render plan"
      ( mkRenderPlan
          (paintRequestRevision request)
          (paintRequestTicket request)
          (paintRequestSurface request)
          firstOverlayStep
          size
          emptyResourceManifest

          (RenderLayer ObjectLayer [] :| [])
          emptyAnimationTimeline
      )
  painted <-
    requireRight
      "canvas edit paint acknowledgement"
      (update (PaintCompleted request plan) (updateModel accepted))
  let paintedModel = updateModel painted
      paintedSession = appDocumentSession paintedModel
  assert
    ( authorityAllowsEdit
        request
        (sessionCanvasAuthority (paintRequestSurface request) paintedSession)
    )
    "acknowledged pending paint did not grant canvas authority"
  editRequest <-
    requireRight
      "begin common canvas edit"
      (beginCanvasEdit request operation paintedModel)
  assert
    (canvasEditRequestPaint editRequest == request)
    "common edit did not capture the issued paint request"
  assert
    (canvasEditRequestOperation editRequest == operation)
    "common edit did not capture the exact operation"
  case commitCanvasSuccessor editRequest document paintedModel of
    Left CanvasEditSuccessorNoOp -> Right ()
    Left other -> Left ("unexpected canvas no-op failure: " <> show other)
    Right _ -> Left "byte-identical canvas successor committed"
  let unadvancedSource = snapshotFromBytes "after"
      unadvancedDocument =
        readyDocument
          unadvancedSource
          ()
          presentation
          (emptyProvenanceMap :: ProvenanceMap Text)
          []
  case commitCanvasSuccessor editRequest unadvancedDocument paintedModel of
    Left (CanvasEditSuccessorRevisionInvalid expected actual) -> do
      assert
        (expected == snapshotRevision source)
        "mechanical rejection reported the wrong base revision"
      assert
        (actual == snapshotRevision unadvancedSource)
        "mechanical rejection reported the wrong successor revision"
    Left other ->
      Left ("unexpected unadvanced-successor failure: " <> show other)
    Right _ -> Left "unadvanced canvas successor committed"
  successorSource <-
    requireRight
      "canvas successor source advance"
      (advanceSnapshot "after" source)
  let successorDocument =
        readyDocument
          successorSource
          ()
          presentation
          (emptyProvenanceMap :: ProvenanceMap Text)
          []
  committed <-
    requireRight
      "mechanically commit format-owned canvas successor"
      (commitCanvasSuccessor editRequest successorDocument paintedModel)
  let committedSession = appDocumentSession committed
  assert
    (snapshotBytes (sessionDraft committedSession) == "after")
    "canvas commit did not record successor bytes"
  assert
    (canUndo (sessionHistory committedSession))
    "canvas commit did not create exactly undoable source history"
  case commitCanvasSuccessor editRequest successorDocument committed of
    Left (CanvasEditCompletionStale expected actual) -> do
      assert
        (expected == snapshotRevision source)
        "replayed completion reported the wrong request revision"
      assert
        (actual == snapshotRevision successorSource)
        "replayed completion reported the wrong current revision"
    Left other -> Left ("unexpected replayed canvas completion failure: " <> show other)
    Right _ -> Left "mechanical canvas successor committed more than once"
  undone <- requireRight "undo canvas source transaction" (update UndoDraft committed)
  let undoneSource = sessionDraft (appDocumentSession (updateModel undone))
  assert
    (snapshotBytes undoneSource == "before")
    "canvas undo did not restore byte-exact original source"
  assert
    (revisionToWord64 (snapshotRevision undoneSource) == 2)
    "canvas undo revived an old revision instead of issuing a fresh one"

interactionCheck :: Either String ()
interactionCheck = do
  identity <- requireMaybe "interaction node id" (nodeId "interaction-node")
  slideSize <- requireRight "interaction slide size" (mkSize (canvasUnit 16) (canvasUnit 9))
  nodeSize <- requireRight "interaction node size" (mkSize (canvasUnit 2) (canvasUnit 1))
  snapConfig <-
    requireRight
      "interaction snap config"
      (mkSnapConfig (canvasUnit (1 / 5)) (Just (canvasUnit (1 / 2))) slideSize [])
  bindingConfig <-
    requireRight
      "interaction binding config"
      (mkBindingConfig (canvasUnit (1 / 5)) (canvasUnit (1 / 2)))
  let policy =
        InteractionPolicy
          { captureInteractionFence = const (Right ())
          , resolveInteractionPreview =
              \() node destination mode ->
                Right
                  ( resolveDrag
                      DragRequest
                        { dragNodeIdentity = node
                        , dragExcludedBindingTargets = mempty
                        , dragMode = mode
                        , dragProposedBox = box destination nodeSize
                        , dragPeers = []
                        , dragSnapConfig = snapConfig
                        , dragBindingConfig = bindingConfig
                        }
                  , ()
                  )
          , commitInteractionPreview = const (Right (InteractionCommitted (7 :: Int)))
          }
      press = pointerSample 11 PrimaryButton True (CssPoint 10 10) (point (canvasUnit (3 / 2)) (canvasUnit 0)) noModifiers
  pressed <-
    requireRight
      "first press selects and arms drag"
      (reducePointerEvent policy (PointerPressed (PointerNode identity) press) initialInteractionState)
  assert
    (interactionSelection (transitionState pressed) == Just identity)
    "first press did not select its node"
  assert
    (interactionGesturePhase (transitionState pressed) == GesturePressed)
    "first press did not arm the same drag"
  assert
    (transitionActions pressed == [RequestPointerCapture (PointerId 11), RequestRepaint])
    "first press did not request closed capture and repaint actions"
  subthreshold <-
    requireRight
      "subthreshold move"
      ( reducePointerEvent
          policy
          (PointerMoved (pointerSample 11 PrimaryButton True (CssPoint 11 10) (point (canvasUnit 2) (canvasUnit 2)) noModifiers))
          (transitionState pressed)
      )
  assert
    (interactionGesturePhase (transitionState subthreshold) == GesturePressed)
    "subthreshold move started a drag"
  assert
    (null (transitionActions subthreshold) && transitionCommit subthreshold == Nothing)
    "subthreshold move produced preview or commit work"
  released <-
    requireRight
      "release sample crosses threshold and commits"
      ( reducePointerEvent
          policy
          (PointerReleased (pointerSample 11 PrimaryButton True (CssPoint 13 10) (point (canvasUnit (41 / 10)) (canvasUnit (51 / 10))) noModifiers))
          (transitionState subthreshold)
      )
  assert (transitionCommit released == Just 7) "release did not commit its retained raw sample"
  assert
    (interactionGesturePhase (transitionState released) == GestureIdle)
    "release did not end the gesture"
  pressedAgain <-
    requireRight
      "second press"
      (reducePointerEvent policy (PointerPressed (PointerNode identity) press) (transitionState released))
  let cancelled = reducePointerEvent policy (PointerCaptureLost (PointerId 11)) (transitionState pressedAgain)
  cancelledTransition <- requireRight "lost pointer capture" cancelled
  assert
    (interactionGesturePhase (transitionState cancelledTransition) == GestureIdle)
    "lost capture retained the gesture"
  assert
    (ClearPreview `elem` transitionActions cancelledTransition)
    "lost capture did not clear preview"
  altPressed <-
    requireRight
      "Alt press"
      (reducePointerEvent policy (PointerPressed (PointerNode identity) press) (transitionState cancelledTransition))
  altPreview <-
    requireRight
      "Alt free preview"
      ( reducePointerEvent
          policy
          (PointerMoved (pointerSample 11 PrimaryButton True (CssPoint 13 10) (point (canvasUnit (41 / 10)) (canvasUnit (51 / 10))) noModifiers {modifierAlt = True}))
          (transitionState altPressed)
      )
  case transitionActions altPreview of
    [ShowPreview selected resolution FreeDrag] -> do
      assert (selected == identity) "Alt preview changed node identity"
      assert
        (dragResolvedCenter resolution == point (canvasUnit (41 / 10)) (canvasUnit (51 / 10)))
        "Alt preview did not bypass snapping"
      assert (null (dragGuides resolution)) "Alt preview emitted snap guides"
    _ -> Left "Alt move did not emit one free preview"
  let navigator = navigatorProjection initialInteractionState
  assert
    ( navigatorSlideCount navigator == 1
        && navigatorActiveIndex navigator == 0
        && navigatorPreviousAvailability navigator == InteractionCommandDisabled OnlySlideAvailable
        && navigatorNextAvailability navigator == InteractionCommandDisabled OnlySlideAvailable
    )
    "one-slide navigator projection or command enablement is incorrect"

pointerSample
  :: Word64
  -> PointerButton
  -> Bool
  -> CssPoint
  -> Point
  -> PointerModifiers
  -> PointerSample
pointerSample identity button isPrimary cssPoint slidePoint modifiers =
  PointerSample
    { pointerSampleId = PointerId identity
    , pointerSampleType = MousePointer
    , pointerSampleButton = button
    , pointerSampleIsPrimary = isPrimary
    , pointerSampleCssPoint = cssPoint
    , pointerSampleSlidePoint = slidePoint
    , pointerSampleModifiers = modifiers
    }

noModifiers :: PointerModifiers
noModifiers = PointerModifiers False False False False

diagnosticFreshnessCheck :: Either String ()
diagnosticFreshnessCheck = do
  presentation <- samplePresentation
  let initial = snapshotFromBytes "accepted"
      baseSession = startDocumentSession (sessionIdFromWord64 20) initial
      capabilities =
        capabilitySet [(GitCapability, CapabilityAvailable)]
      pendingContext =
        appCommandContext (newAppModel baseSession capabilities)
  assertDiagnosticsNotCurrent
    "a session without accepted diagnostics allowed Git commit"
    pendingContext
  accepted <-
    requireRight
      "accept clean diagnostics"
      ( acceptSessionDocument
          ( readyDocument
              initial
              ()
              presentation
              (emptyProvenanceMap :: ProvenanceMap Text)
              []
          )
          baseSession
      )
  assert
    ( commandAvailability
        (appCommandContext (newAppModel accepted capabilities))
        (Project CommitProject)
        == CommandEnabled
    )
    "current clean diagnostics did not enable Git commit"
  changed <-
    requireRight
      "advance draft after diagnostics"
      (replaceSessionDraft "newer" accepted)
  staleSession <-
    case changed of
      SessionUnchanged _ -> Left "new draft unexpectedly produced no history entry"
      SessionChanged _ value -> Right value
  assertDiagnosticsNotCurrent
    "stale accepted diagnostics allowed Git commit"
    (appCommandContext (newAppModel staleSession capabilities))

notesSurfaceFanoutCheck :: Either String ()
notesSurfaceFanoutCheck = do
  presentation <- samplePresentationWithNotes
  let source = snapshotFromBytes "notes"
      session = startDocumentSession (sessionIdFromWord64 30) source
      document =
        readyDocument
          source
          ()
          presentation
          (emptyProvenanceMap :: ProvenanceMap Text)
          []
  accepted <-
    requireRight
      "accept presentation with notes"
      (update (AnalysisCompleted document) (newAppModel session emptyCapabilitySet))
  case updateEffects accepted of
    [ MeasureAndRender audienceRequest _ _
      , MeasureAndRender notesRequest _ _
      ] -> do
        assert
          (paintRequestSurface audienceRequest /= paintRequestSurface notesRequest)
          "audience and notes paint requests shared a surface"
        assert
          (paintRequestTicket audienceRequest /= paintRequestTicket notesRequest)
          "audience and notes paint requests shared a render ticket"
    effects ->
      Left
        ( "presentation with notes emitted the wrong paint fanout: "
            <> show (length effects)
        )

samplePresentation :: Either String Presentation
samplePresentation = do
  identity <- requireRight "sample frame id" (mkFrameId "frame-1")
  requireRight
    "sample presentation"
    ( mkPresentation
        ( mkPresentationMetadata
            "Sample"
            defaultAspectRatio
            defaultTheme
            CompleteImmediately
        )
        ( mkFrame
            identity
            (mkFrameMetadata "Sample" noSlideRotation)
            emptyScene
            Nothing
            :| []
        )
    )

samplePresentationWithNotes :: Either String Presentation
samplePresentationWithNotes = do
  identity <- requireRight "notes frame id" (mkFrameId "frame-with-notes")
  requireRight
    "sample presentation with notes"
    ( mkPresentation
        ( mkPresentationMetadata
            "Notes"
            defaultAspectRatio
            defaultTheme
            CompleteImmediately
        )
        ( mkFrame
            identity
            (mkFrameMetadata "Notes" noSlideRotation)
            emptyScene
            (Just (mkNotes emptyScene))
            :| []
        )
    )

sampleSurface :: Either String SurfaceAddress
sampleSurface = do
  frame <- requireRight "surface frame id" (mkFrameId "frame-1")
  Right (surfaceAddress frame AudienceSurface)

assertDiagnosticsNotCurrent
  :: String
  -> CommandContext
  -> Either String ()
assertDiagnosticsNotCurrent message context =
  case commandAvailability context (Project CommitProject) of
    CommandDisabled reasons ->
      assert
        (DiagnosticsNotCurrent `elem` reasons)
        message
    CommandEnabled -> Left message

requireAdvanced
  :: String
  -> HistoryChange
  -> Either String (SourceBufferSnapshot, SourceHistory)
requireAdvanced label change =
  case change of
    HistoryNoOp _ -> Left (label <> " unexpectedly produced a no-op")
    HistoryAdvanced snapshot history -> Right (snapshot, history)

assert :: Bool -> String -> Either String ()
assert condition message
  | condition = Right ()
  | otherwise = Left message

requireRight :: Show failure => String -> Either failure value -> Either String value
requireRight label result =
  case result of
    Left failure -> Left (label <> ": " <> show failure)
    Right value -> Right value

requireMaybe :: String -> Maybe value -> Either String value
requireMaybe label result =
  case result of
    Nothing -> Left (label <> ": missing value")
    Just value -> Right value
