{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.ProductV2
-- Description : Shared source-authoritative Product/2 composition.
--
-- This portable pure runtime owns the long-lived App/TikZ/common-render
-- composition, source/history/lease authority, interaction transitions, and
-- workspace projection. The protocol package owns only closed wire vocabulary
-- and JSON encoding. No browser, JSFFI, filesystem, or native effect enters
-- this module.
module SlideBlaster.Product.Runtime.ProductV2
  ( ProductV2State
  , newProductV2State
  , newProductV2StateWithNextSessionId
  , runProductV2Request
  , dispatchProductV2RequestJSON
  ) where

import SlideBlaster.App qualified as App
import SlideBlaster.Canvas qualified as Canvas
import SlideBlaster.Deck qualified as Deck
import SlideBlaster.Document qualified as Document
import SlideBlaster.Engine.CommonTikz (renderPresentationSurfacePlan)
import SlideBlaster.Presentation qualified as Presentation
import SlideBlaster.Protocol.ProductV2
  ( PaintFenceValue (..)
  , ProductV2Error (..)
  , ProductV2Request (..)
  , ProductV2Success
  )
import SlideBlaster.Protocol.ProductV2 qualified as Protocol
import SlideBlaster.Render qualified as Render
import SlideBlaster.Source qualified as Source

import Data.Aeson (Value (..), object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List (find)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Ratio (denominator, numerator)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64, Word8)

-- The plan paired with a request is correlation state, not a semantic model.
data CorrelatedPaint = CorrelatedPaint !App.PaintRequest !Render.RenderPlan

type CommonCanvasEditRequest =
  App.CanvasEditRequest Deck.DeckSyntax Deck.DeckFieldKey

data GesturePreview = GesturePreview
  !Canvas.NodeId
  !Canvas.EditIntent
  !Canvas.DragMode
  !CommonCanvasEditRequest
  !Deck.DeckDocument

-- | One source-authoritative runtime. The App model is the only source,
-- history, accepted-document, and lease authority. The generic interaction
-- state owns pointer phase/identity, selection, preview, and navigator
-- policy; its opaque fence and preview values retain the exact Product/2
-- transaction.
data ProductV2State = ProductV2State
  { productAppModel :: !(App.AppModel Deck.DeckSyntax Deck.DeckFieldKey)
  , productIsOpen :: !Bool
  , productPaints :: !(Map Presentation.SurfaceAddress CorrelatedPaint)
  , productAcknowledgedPaints :: !(Map Presentation.SurfaceAddress CorrelatedPaint)
  , productOfferedPaint :: !(Maybe CorrelatedPaint)
  , productDisplayedPaint :: !(Maybe CorrelatedPaint)
  , productNavigation :: !(Maybe App.DeckNavigation)
  , productInteraction :: !(App.InteractionState CorrelatedPaint GesturePreview)
  , productKeyboardSelection :: !(Maybe Canvas.NodeId)
  , productUndoPreferredFrame :: !(Maybe Presentation.FrameId)
  , productRedoPreferredFrame :: !(Maybe Presentation.FrameId)
  , productNextSession :: !Word64
  }

-- | Construct an unopened runtime rooted in an ordinary App document session.
newProductV2State :: ProductV2State
newProductV2State = newProductV2StateWithNextSessionId 1

-- | Construct an unopened runtime with a restored next session identifier.
-- Values above 'maxCorrelationId' are retained so the next open reports the
-- typed exhaustion failure instead of wrapping or misclassifying analysis.
newProductV2StateWithNextSessionId :: Word64 -> ProductV2State
newProductV2StateWithNextSessionId nextSession =
  ProductV2State
    { productAppModel =
        App.newAppModel
          ( App.startDocumentSession
              (App.sessionIdFromWord64 1)
              (Source.snapshotFromBytes ByteString.empty)
          )
          App.emptyCapabilitySet
    , productIsOpen = False
    , productPaints = Map.empty
    , productAcknowledgedPaints = Map.empty
    , productOfferedPaint = Nothing
    , productDisplayedPaint = Nothing
    , productNavigation = Nothing
    , productInteraction = App.initialInteractionState
    , productKeyboardSelection = Nothing
    , productUndoPreferredFrame = Nothing
    , productRedoPreferredFrame = Nothing
    , productNextSession = nextSession
    }

maxCorrelationId :: Word64
maxCorrelationId = 9007199254740991

-- | Run one request. Failure returns no successor, preserving atomicity.
runProductV2Request
  :: ProductV2State
  -> ProductV2Request
  -> Either ProductV2Error (ProductV2State, ProductV2Success)
runProductV2Request state request =
  case request of
    OpenSource bytes -> do
      next <- openSource bytes state
      success "source_opened" next
    ProductV2WorkspaceSnapshot -> do
      ensureOpen state
      success "workspace_snapshot" state
    AcknowledgePaint fence -> do
      ensureOpen state
      offered <- maybe (Left ProductV2PaintNotOffered) Right (productOfferedPaint state)
      ensureFence fence offered
      next <- acknowledgeOffered offered state
      success "paint_acknowledged" next
    ProductV2PointerEvent event -> do
      ensureOpen state
      converted <- pointerEventFromValue state event
      runPointerEvent converted state
    ProductV2ViewCommand command -> do
      ensureOpen state
      runViewCommand command state
    ProductV2ActivateNode surface nodeText -> do
      ensureOpen state
      activateNode surface nodeText state
    SelectSlideProduct frameText -> do
      ensureOpen state
      selectSlide frameText state
    NewSlideProduct revision -> do
      ensureOpen state
      ensureRevision revision state
      newSlide state
    UndoProduct revision -> do
      ensureOpen state
      ensureRevision revision state
      historyTransition "undo" App.UndoDraft state
    RedoProduct revision -> do
      ensureOpen state
      ensureRevision revision state
      historyTransition "redo" App.RedoDraft state
    ReplaceProductSource revision bytes -> do
      ensureOpen state
      ensureRevision revision state
      replaceSource bytes state

-- | Decode, execute, and encode one request while preserving state on failure.
dispatchProductV2RequestJSON
  :: ProductV2State
  -> ByteString
  -> (ProductV2State, ByteString)
dispatchProductV2RequestJSON state bytes =
  case Protocol.decodeProductV2RequestJSON bytes of
    Left failure -> (state, Protocol.encodeProductV2ErrorJSON failure)
    Right request ->
      case runProductV2Request state request of
        Left failure -> (state, Protocol.encodeProductV2ErrorJSON failure)
        Right (next, response) -> (next, Protocol.encodeProductV2SuccessJSON response)

openSource :: ByteString -> ProductV2State -> Either ProductV2Error ProductV2State
openSource bytes state
  | productNextSession state > maxCorrelationId = Left ProductV2SessionIdExhausted
  | otherwise = do
      let source = Source.snapshotFromBytes bytes
          sessionNumber = productNextSession state
          model =
            App.newAppModel
              (App.startDocumentSession (App.sessionIdFromWord64 sessionNumber) source)
              App.emptyCapabilitySet
          reset =
            state
              { productAppModel = model
              , productIsOpen = True
              , productPaints = Map.empty
              , productAcknowledgedPaints = Map.empty
              , productOfferedPaint = Nothing
              , productDisplayedPaint = Nothing
              , productNavigation = Nothing
              , productInteraction = App.initialInteractionState
              , productKeyboardSelection = Nothing
              , productUndoPreferredFrame = Nothing
              , productRedoPreferredFrame = Nothing
              , productNextSession = sessionNumber + 1
              }
      analyzeAndOffer source reset

replaceSource
  :: ByteString
  -> ProductV2State
  -> Either ProductV2Error (ProductV2State, ProductV2Success)
replaceSource bytes state = do
  updated <- mapUpdate (App.update (App.DraftBytesChanged bytes) (productAppModel state))
  case App.updateEffects updated of
    [] ->
      success
        "source_unchanged"
        state
          { productInteraction = App.resetDocumentInteraction (productInteraction state)
          , productKeyboardSelection = Nothing
          }
    [App.AnalyzeSource source] -> do
      next <-
        analyzeAndOffer
          source
          state
            { productAppModel = App.updateModel updated
            , productKeyboardSelection = Nothing
            , productOfferedPaint = Nothing
            , productInteraction = App.resetDocumentInteraction (productInteraction state)
            }
      success "source_replaced" next
    _ -> Left ProductV2AnalysisRejected

-- | Convert one closed raw pointer fact. Node targets are admitted only for the
-- active painted surface and an accepted-document node.
pointerEventFromValue
  :: ProductV2State
  -> Protocol.PointerEventValue
  -> Either ProductV2Error App.PointerEvent
pointerEventFromValue state event =
  case event of
    Protocol.PointerDownValue target sample -> do
      converted <- pointerTargetFromValue state target
      Right (App.PointerPressed converted (pointerSampleFromValue sample))
    Protocol.PointerMoveValue sample -> Right (App.PointerMoved (pointerSampleFromValue sample))
    Protocol.PointerUpValue sample -> Right (App.PointerReleased (pointerSampleFromValue sample))
    Protocol.PointerCancelValue identity -> Right (App.PointerCancelled (App.PointerId identity))
    Protocol.PointerLostCaptureValue identity -> Right (App.PointerCaptureLost (App.PointerId identity))

pointerTargetFromValue
  :: ProductV2State
  -> Protocol.PointerTargetValue
  -> Either ProductV2Error App.PointerTarget
pointerTargetFromValue state target =
  case target of
    Protocol.CanvasTargetValue -> Right App.PointerCanvas
    Protocol.NodeTargetValue surface nodeText -> do
      ensureActiveSurface surface state
      identity <- nodeIdentity nodeText
      if admittedNode identity (productAppModel state)
        then Right (App.PointerNode identity)
        else Left ProductV2NodeNotAdmitted

nodeIdentity :: Text -> Either ProductV2Error Canvas.NodeId
nodeIdentity value = maybe (Left ProductV2NodeNotAdmitted) Right (Canvas.nodeId value)

pointerSampleFromValue :: Protocol.PointerSampleValue -> App.PointerSample
pointerSampleFromValue sample =
  App.PointerSample
    { App.pointerSampleId = App.PointerId (Protocol.pointerIdValue sample)
    , App.pointerSampleType = pointerTypeFromValue (Protocol.pointerTypeValue sample)
    , App.pointerSampleButton = pointerButtonFromValue (Protocol.pointerButtonValue sample)
    , App.pointerSampleIsPrimary = Protocol.pointerPrimaryValue sample
    , App.pointerSampleCssPoint = cssPointFromValue (Protocol.pointerCssPointValue sample)
    , App.pointerSampleSlidePoint = canvasPointFromValue (Protocol.pointerSlidePointValue sample)
    , App.pointerSampleModifiers = pointerModifiersFromValue (Protocol.pointerModifiersValue sample)
    }

pointerTypeFromValue :: Protocol.PointerTypeValue -> App.PointerType
pointerTypeFromValue value =
  case value of
    Protocol.MousePointerValue -> App.MousePointer
    Protocol.PenPointerValue -> App.PenPointer
    Protocol.TouchPointerValue -> App.TouchPointer

pointerButtonFromValue :: Protocol.PointerButtonValue -> App.PointerButton
pointerButtonFromValue value =
  case value of
    Protocol.PrimaryButtonValue -> App.PrimaryButton
    Protocol.MiddleButtonValue -> App.MiddleButton
    Protocol.SecondaryButtonValue -> App.SecondaryButton
    Protocol.OtherButtonValue code -> App.OtherButton code

pointerModifiersFromValue :: Protocol.PointerModifiersValue -> App.PointerModifiers
pointerModifiersFromValue value =
  App.PointerModifiers
    { App.modifierAlt = Protocol.modifierAltValue value
    , App.modifierShift = Protocol.modifierShiftValue value
    , App.modifierControl = Protocol.modifierControlValue value
    , App.modifierMeta = Protocol.modifierMetaValue value
    }

cssPointFromValue :: Protocol.PointValue -> App.CssPoint
cssPointFromValue (Protocol.PointValue x y) = App.CssPoint x y

canvasPointFromValue :: Protocol.PointValue -> Canvas.Point
canvasPointFromValue (Protocol.PointValue x y) =
  Canvas.point (Canvas.canvasUnit x) (Canvas.canvasUnit y)

-- | Reduce one raw pointer event and, when the reducer commits, adopt the
-- format-verified successor and re-offer paints for the new revision.
runPointerEvent
  :: App.PointerEvent
  -> ProductV2State
  -> Either ProductV2Error (ProductV2State, ProductV2Success)
runPointerEvent event state =
  case App.reducePointerEvent (pointerPolicy state) event (productInteraction state) of
    Left failure -> pointerFailure failure event state
    Right transition ->
      let interaction = App.transitionState transition
          actions = App.transitionActions transition
       in case App.transitionCommit transition of
            Nothing ->
              successWithActions "pointer_updated" actions state {productInteraction = interaction}
            Just model -> do
              analyzed <-
                analyzeAndOffer
                  (App.sessionDraft (App.appDocumentSession model))
                  state
                    { productAppModel = model
                    , productInteraction = interaction
                    , productKeyboardSelection = Nothing
                    , productUndoPreferredFrame = Nothing
                    , productRedoPreferredFrame = Nothing
                    }
              successWithActions "pointer_committed" actions analyzed

-- | A rejected preview ends its own gesture through the reducer's cancellation
-- law, so source, history, and selection are untouched. Authority and commit
-- failures are typed protocol errors with no successor state.
pointerFailure
  :: App.InteractionFailure
  -> App.PointerEvent
  -> ProductV2State
  -> Either ProductV2Error (ProductV2State, ProductV2Success)
pointerFailure failure event state =
  case failure of
    App.InteractionAuthorityUnavailable -> Left ProductV2GestureStalePaint
    App.InteractionAuthorityStale -> Left ProductV2GestureStaleRevision
    App.InteractionCommitRejected -> Left ProductV2CanvasEditRejected
    App.InteractionPreviewRejected ->
      case App.reducePointerEvent
        (pointerPolicy state)
        (App.PointerCancelled (pointerEventIdentity event))
        (productInteraction state) of
        Left _ -> Left ProductV2CanvasProjectionRejected
        Right transition ->
          successWithActions
            "pointer_preview_rejected"
            (App.transitionActions transition)
            state {productInteraction = App.transitionState transition}

pointerEventIdentity :: App.PointerEvent -> App.PointerId
pointerEventIdentity event =
  case event of
    App.PointerPressed _ sample -> App.pointerSampleId sample
    App.PointerMoved sample -> App.pointerSampleId sample
    App.PointerReleased sample -> App.pointerSampleId sample
    App.PointerCancelled identity -> identity
    App.PointerCaptureLost identity -> identity

-- | Format composition for the generic reducer: the displayed writable paint is
-- the authority fence, common snapping resolves the destination, the deck
-- adapter verifies the projection, and App owns the mechanical commit.
pointerPolicy
  :: ProductV2State
  -> App.InteractionPolicy
      CorrelatedPaint
      GesturePreview
      (App.AppModel Deck.DeckSyntax Deck.DeckFieldKey)
pointerPolicy state =
  App.InteractionPolicy
    { App.captureInteractionFence = const (capturePaintFence state)
    , App.resolveInteractionPreview = resolveGesturePreview state
    , App.commitInteractionPreview = commitGesturePreview state
    }

capturePaintFence :: ProductV2State -> Either App.InteractionFailure CorrelatedPaint
capturePaintFence state =
  case productDisplayedPaint state of
    Nothing -> Left App.InteractionAuthorityUnavailable
    Just correlated@(CorrelatedPaint request _)
      | App.paintRequestRevision request /= Source.snapshotRevision draft ->
          Left App.InteractionAuthorityStale
      | not (App.authorityAllowsEdit request (authorityFor request)) ->
          Left App.InteractionAuthorityUnavailable
      | otherwise -> Right correlated
  where
    session = App.appDocumentSession (productAppModel state)
    draft = App.sessionDraft session
    authorityFor request =
      App.sessionCanvasAuthority (App.paintRequestSurface request) session

-- | Resolve one destination. A snapped placement the parent format cannot
-- project falls back to the exact proposed placement instead of cancelling the
-- drag, so a natural gesture keeps moving and stays guide-free when it does.
resolveGesturePreview
  :: ProductV2State
  -> CorrelatedPaint
  -> Canvas.NodeId
  -> Canvas.Point
  -> Canvas.DragMode
  -> Either App.InteractionFailure (Canvas.DragResolution, GesturePreview)
resolveGesturePreview state fence node destination mode =
  case attemptGesturePreview state fence node destination mode of
    Right value -> Right value
    Left failure
      | mode == Canvas.SnappingDrag ->
          attemptGesturePreview state fence node destination Canvas.FreeDrag
      | otherwise -> Left failure

attemptGesturePreview
  :: ProductV2State
  -> CorrelatedPaint
  -> Canvas.NodeId
  -> Canvas.Point
  -> Canvas.DragMode
  -> Either App.InteractionFailure (Canvas.DragResolution, GesturePreview)
attemptGesturePreview state (CorrelatedPaint paint plan) node destination mode = do
  dragged <-
    maybe (Left App.InteractionPreviewRejected) Right (Map.lookup node (plannedNodeBoxes plan))
  resolution <- resolveNodeDrag plan node dragged destination mode
  let frame = Presentation.surfaceAddressFrame (App.paintRequestSurface paint)
  document <-
    maybe
      (Left App.InteractionAuthorityUnavailable)
      Right
      (App.sessionAcceptedDocument (App.appDocumentSession (productAppModel state)))
  authored <-
    maybe
      (Left App.InteractionPreviewRejected)
      Right
      (Deck.writableNodePlacement frame node document)
  let intent =
        Canvas.MoveElement
          (Canvas.NodeElement node)
          (portPlacement authored dragged resolution)
  editRequest <-
    mapLeft
      (const App.InteractionAuthorityStale)
      (App.beginCanvasEdit paint intent (productAppModel state))
  successor <-
    mapLeft
      (const App.InteractionPreviewRejected)
      (Deck.applyDeckCanvasEdit frame intent (App.canvasEditRequestDocument editRequest))
  Right (resolution, GesturePreview node intent mode editRequest successor)

-- | Snapping resolves a box centre, but authored source addresses the node
-- through its own port, so the resolved box is projected back onto that port. A
-- relative resolution is offered unchanged and the parent format decides.
portPlacement :: Canvas.Placement -> Canvas.Box -> Canvas.DragResolution -> Canvas.Placement
portPlacement authored dragged resolution =
  case (authored, Canvas.dragResolvedPlacement resolution) of
    (Canvas.AbsolutePlacement _ port, Canvas.AbsolutePlacement {}) ->
      let resolved = Canvas.box (Canvas.dragResolvedCenter resolution) (Canvas.boxSize dragged)
       in Canvas.AbsolutePlacement (Canvas.pointAtPort port resolved) port
    (_, resolved) -> resolved

-- | Snapping references are the measured peer geometry of the painted surface,
-- so the reducer never reads a document or a DOM.
resolveNodeDrag
  :: Render.RenderPlan
  -> Canvas.NodeId
  -> Canvas.Box
  -> Canvas.Point
  -> Canvas.DragMode
  -> Either App.InteractionFailure Canvas.DragResolution
resolveNodeDrag plan node dragged destination mode = do
  snapConfig <-
    mapLeft
      (const App.InteractionPreviewRejected)
      ( Canvas.mkSnapConfig
          (Canvas.canvasUnit (3 / 20))
          (Just (Canvas.canvasUnit (1 / 2)))
          (Render.renderPlanSize plan)
          []
      )
  bindingConfig <-
    mapLeft
      (const App.InteractionPreviewRejected)
      (Canvas.mkBindingConfig (Canvas.canvasUnit (1 / 5)) (Canvas.canvasUnit (3 / 2)))
  Right
    ( Canvas.resolveDrag
        Canvas.DragRequest
          { Canvas.dragNodeIdentity = node
          , Canvas.dragExcludedBindingTargets = mempty
          , Canvas.dragMode = mode
          , Canvas.dragProposedBox = Canvas.box destination (Canvas.boxSize dragged)
          , Canvas.dragPeers =
              [ Canvas.PeerBox identity value
              | (identity, value) <- Map.toList (plannedNodeBoxes plan)
              , identity /= node
              ]
          , Canvas.dragSnapConfig = snapConfig
          , Canvas.dragBindingConfig = bindingConfig
          }
    )

plannedNodeBoxes :: Render.RenderPlan -> Map Canvas.NodeId Canvas.Box
plannedNodeBoxes plan =
  Map.fromList
    ( mapMaybe
        plannedNodeBox
        (concatMap Render.renderLayerItems (NonEmpty.toList (Render.renderPlanLayers plan)))
    )

plannedNodeBox :: Render.RenderItem -> Maybe (Canvas.NodeId, Canvas.Box)
plannedNodeBox item =
  case (Render.renderItemIdentity item, Render.renderItemPrimitive item) of
    (Render.ElementRender address _, Render.ShapePrimitive outline _) ->
      case (Presentation.elementAddressElement address, Render.renderOutlineView outline) of
        (Canvas.NodeElement identity, Render.RenderRectangleView value _) -> Just (identity, value)
        _ -> Nothing
    _ -> Nothing

commitGesturePreview
  :: ProductV2State
  -> GesturePreview
  -> Either
      App.InteractionFailure
      (App.CommitDisposition (App.AppModel Deck.DeckSyntax Deck.DeckFieldKey))
commitGesturePreview state (GesturePreview _ _ _ editRequest successor) =
  case App.commitCanvasSuccessor editRequest successor (productAppModel state) of
    Right model -> Right (App.InteractionCommitted model)
    Left App.CanvasEditSuccessorNoOp -> Right App.InteractionNoOp
    Left _ -> Left App.InteractionCommitRejected

-- | Keyboard activation selects and focuses one admitted node on the active
-- painted surface. It is never a source mutation.
activateNode
  :: Protocol.SurfaceValue
  -> Text
  -> ProductV2State
  -> Either ProductV2Error (ProductV2State, ProductV2Success)
activateNode surface nodeText state = do
  ensureActiveSurface surface state
  frame <- activeFrameEither state
  identity <- nodeIdentity nodeText
  if admittedNode identity (productAppModel state)
    then Right ()
    else Left ProductV2NodeNotAdmitted
  let next = state {productKeyboardSelection = Just identity}
  successWithActionValues
    "node_activated"
    [ object
        [ "kind" .= ("focus_node" :: Text)
        , "surface" .= surfaceValue (Presentation.surfaceAddress frame Presentation.AudienceSurface)
        , "nodeId" .= Canvas.identifierText identity
        ]
    ]
    next

-- | Select one existing slide. Selection is view state and never edits source.
selectSlide
  :: Text
  -> ProductV2State
  -> Either ProductV2Error (ProductV2State, ProductV2Success)
selectSlide frameText state = do
  navigation <- maybe (Left ProductV2DeckNotReady) Right (productNavigation state)
  frame <-
    case Presentation.mkFrameId frameText of
      Right value -> Right value
      Left _ -> Left ProductV2ActiveSlideMissing
  _ <-
    maybe (Left ProductV2ActiveSlideMissing) Right
      ( find
          ((== frame) . App.navigationEntryFrame)
          (NonEmpty.toList (App.navigationEntries navigation))
      )
  let next =
        selectFrame
          frame
          state
            { productInteraction = App.resetDocumentInteraction (productInteraction state)
            , productKeyboardSelection = Nothing
            }
  successWithActions "slide_selected" [App.RequestRepaint] next

-- | Apply one exact history transition and reselect the slide the transition
-- belongs to, so undo and redo return the reader to the affected slide.
historyTransition
  :: Text
  -> App.AppEvent Deck.DeckSyntax Deck.DeckFieldKey
  -> ProductV2State
  -> Either ProductV2Error (ProductV2State, ProductV2Success)
historyTransition kind event state = do
  updated <- mapUpdate (App.update event (productAppModel state))
  source <-
    case App.updateEffects updated of
      [App.AnalyzeSource value] -> Right value
      _ -> Left ProductV2HistoryUnavailable
  analyzed <-
    analyzeAndOffer
      source
      state
        { productAppModel = App.updateModel updated
        , productInteraction = App.resetDocumentInteraction (productInteraction state)
        , productKeyboardSelection = Nothing
        }
  let preferred =
        if kind == "undo"
          then productUndoPreferredFrame state
          else productRedoPreferredFrame state
      selected = maybe analyzed (`selectFrame` analyzed) preferred
  successWithActions kind [App.RequestRepaint] selected

runViewCommand
  :: Protocol.ViewCommandValue
  -> ProductV2State
  -> Either ProductV2Error (ProductV2State, ProductV2Success)
runViewCommand command state =
  case command of
    Protocol.PreviousSlideValue -> navigateWith App.navigationPrevious state
    Protocol.NextSlideValue -> navigateWith App.navigationNext state

navigateWith
  :: (App.DeckNavigation -> App.DeckNavigation)
  -> ProductV2State
  -> Either ProductV2Error (ProductV2State, ProductV2Success)
navigateWith movement state = do
  navigation <- maybe (Left ProductV2DeckNotReady) Right (productNavigation state)
  let nextNavigation = movement navigation
      next =
        selectActivePaint
          state
            { productNavigation = Just nextNavigation
            , productInteraction = App.resetDocumentInteraction (productInteraction state)
            , productKeyboardSelection = Nothing
            }
  successWithActions "view_updated" [App.RequestRepaint] next

newSlide :: ProductV2State -> Either ProductV2Error (ProductV2State, ProductV2Success)
newSlide state = do
  active <- activeFrameEither state
  document <-
    maybe (Left ProductV2DeckNotReady) Right
      (App.sessionAcceptedDocument (App.appDocumentSession (productAppModel state)))
  successor <- mapLeft deckFailure (Deck.insertSlideAfter (Source.snapshotRevision (Document.documentSource document)) active document)
  updated <- mapUpdate (App.update (App.DraftBytesChanged (Source.snapshotBytes (Document.documentSource successor))) (productAppModel state))
  source <- case App.updateEffects updated of
    [App.AnalyzeSource value] -> Right value
    _ -> Left ProductV2DeckProjectionRejected
  analyzed <-
    analyzeAndOffer
      source
      state
        { productAppModel = App.updateModel updated
        , productUndoPreferredFrame = Just active
        , productRedoPreferredFrame = Nothing
        , productInteraction = App.resetDocumentInteraction (productInteraction state)
        , productKeyboardSelection = Nothing
        }
  navigation <- maybe (Left ProductV2DeckNotReady) Right (productNavigation analyzed)
  let oldIndex = maybe 0 App.navigationActiveIndex (productNavigation state)
      entries = NonEmpty.toList (App.navigationEntries navigation)
  created <- case drop (oldIndex + 1) entries of
    entry : _ -> Right (App.navigationEntryFrame entry)
    [] -> Left ProductV2ActiveSlideMissing
  let selected = selectFrame created analyzed {productRedoPreferredFrame = Just created}
  successWithActions "slide_created" [App.RequestRepaint] selected

selectFrame :: Presentation.FrameId -> ProductV2State -> ProductV2State
selectFrame frame state =
  case productNavigation state of
    Nothing -> state
    Just navigation ->
      selectActivePaint state {productNavigation = Just (App.navigationSelect frame navigation)}

selectActivePaint :: ProductV2State -> ProductV2State
selectActivePaint state =
  case productNavigation state of
    Nothing -> state {productOfferedPaint = Nothing, productDisplayedPaint = Nothing}
    Just navigation ->
      let surface = Presentation.surfaceAddress (App.navigationActiveFrame navigation) Presentation.AudienceSurface
       in case Map.lookup surface (productAcknowledgedPaints state) of
            Just displayed -> state {productOfferedPaint = Nothing, productDisplayedPaint = Just displayed}
            Nothing -> state {productOfferedPaint = Map.lookup surface (productPaints state), productDisplayedPaint = Nothing}

activeFrameEither :: ProductV2State -> Either ProductV2Error Presentation.FrameId
activeFrameEither state = maybe (Left ProductV2ActiveSlideMissing) (Right . App.navigationActiveFrame) (productNavigation state)

ensureActiveSurface :: Protocol.SurfaceValue -> ProductV2State -> Either ProductV2Error ()
ensureActiveSurface supplied state = do
  frame <- activeFrameEither state
  let expected = Protocol.SurfaceValue (Presentation.frameIdText frame) Protocol.AudienceSurfaceValue
  if supplied == expected then Right () else Left ProductV2SurfaceNotActive

deckFailure :: Deck.DeckEditError -> ProductV2Error
deckFailure failure = case failure of
  Deck.DeckNotReady -> ProductV2DeckNotReady
  Deck.DeckActiveSlideMissing _ -> ProductV2ActiveSlideMissing
  Deck.DeckStaleRevision {} -> ProductV2DeckProjectionRejected
  Deck.DeckTargetMissing {} -> ProductV2DeckProjectionRejected
  Deck.DeckPlacementUnsupported {} -> ProductV2DeckProjectionRejected
  Deck.DeckProjectionRejected -> ProductV2DeckProjectionRejected
  Deck.DeckSourceRejected {} -> ProductV2DeckProjectionRejected
  Deck.DeckVerificationRejected -> ProductV2DeckProjectionRejected

analyzeAndOffer
  :: Source.SourceBufferSnapshot
  -> ProductV2State
  -> Either ProductV2Error ProductV2State
analyzeAndOffer source state = do
  let document = Deck.analyzeDeck source
  analyzed <- mapUpdate (App.update (App.AnalysisCompleted document) (productAppModel state))
  case Document.documentSemantic document of
    Nothing ->
      Right
        state
          { productAppModel = App.updateModel analyzed
          , productPaints = Map.empty
          , productAcknowledgedPaints = Map.empty
          , productOfferedPaint = Nothing
          , productDisplayedPaint = Nothing
          }
    Just presentation -> do
      let preferred = App.navigationActiveFrame <$> productNavigation state
          navigation = App.reconcileNavigation preferred presentation
      paints <- traverse (renderEffect source document presentation) (App.updateEffects analyzed)
      let indexed = Map.fromList [(App.paintRequestSurface request, correlated) | correlated@(CorrelatedPaint request _) <- paints]
          base =
            state
              { productAppModel = App.updateModel analyzed
              , productPaints = indexed
              , productAcknowledgedPaints = Map.empty
              , productNavigation = Just navigation
              , productOfferedPaint = Nothing
              , productDisplayedPaint = Nothing
              }
      Right (selectActivePaint base)
  where
    renderEffect exact document presentation effect =
      case effect of
        App.MeasureAndRender request effectSource _
          | effectSource == exact -> do
              slideSize <- mapLeft (const ProductV2RenderRejected) (Canvas.mkSize (Canvas.canvasUnit 16) (Canvas.canvasUnit 9))
              nodeSize <- mapLeft (const ProductV2RenderRejected) (Canvas.mkSize (Canvas.canvasUnit 2) (Canvas.canvasUnit 1))
              plan <-
                mapLeft (const ProductV2RenderRejected)
                  ( renderPresentationSurfacePlan
                      (App.paintRequestTicket request)
                      slideSize
                      nodeSize
                      (\identity ->
                        case Deck.writableNodePlacement
                          (Presentation.surfaceAddressFrame (App.paintRequestSurface request))
                          identity
                          document of
                          Just _ -> True
                          Nothing -> False
                      )
                      (App.paintRequestSurface request)
                      exact
                      presentation
                  )
              Right (CorrelatedPaint request plan)
        _ -> Left ProductV2RenderRejected

acknowledgeOffered
  :: CorrelatedPaint
  -> ProductV2State
  -> Either ProductV2Error ProductV2State
acknowledgeOffered correlated@(CorrelatedPaint request plan) state = do
  updated <-
    mapLeft (const ProductV2PaintRejected)
      (App.update (App.PaintCompleted request plan) (productAppModel state))
  if null (App.updateEffects updated)
    then
      let surface = App.paintRequestSurface request
       in Right
            state
              { productAppModel = App.updateModel updated
              , productAcknowledgedPaints = Map.insert surface correlated (productAcknowledgedPaints state)
              , productOfferedPaint = Nothing
              , productDisplayedPaint = Just correlated
              }
    else Left ProductV2PaintRejected

success
  :: Text
  -> ProductV2State
  -> Either ProductV2Error (ProductV2State, ProductV2Success)
success kind = successWithActions kind []

successWithActions
  :: Text
  -> [App.HostAction]
  -> ProductV2State
  -> Either ProductV2Error (ProductV2State, ProductV2Success)
successWithActions kind actions = successWithActionValues kind (fmap hostActionValue actions)

successWithActionValues
  :: Text
  -> [Value]
  -> ProductV2State
  -> Either ProductV2Error (ProductV2State, ProductV2Success)
successWithActionValues kind actions state = do
  workspace <- workspaceValue state
  Right (state, Protocol.productV2Success kind actions workspace)

workspaceValue :: ProductV2State -> Either ProductV2Error Value
workspaceValue state = do
  ensureOpen state
  let session = App.appDocumentSession (productAppModel state)
      source = App.sessionDraft session
      history = App.sessionHistory session
      interaction = productInteraction state
  offered <- traverse correlatedValue (productOfferedPaint state)
  displayed <- traverse correlatedValue (productDisplayedPaint state)
  preview <- traverse previewValue (App.interactionPreview interaction)
  navigator <- navigatorValue state
  pure
    ( object
        [ "source"
            .= object
              [ "revision" .= revisionNumber (Source.snapshotRevision source)
              , "base16" .= base16Encode (Source.snapshotBytes source)
              ]
        , "readiness" .= readinessText session
        , "canUndo" .= App.canUndo history
        , "canRedo" .= App.canRedo history
        , "selection" .= fmap Canvas.identifierText (firstJust (productKeyboardSelection state) (App.interactionSelection interaction))
        , "authority" .= authorityText state
        , "renderOffer" .= offered
        , "displayedRender" .= displayed
        , "pointer"
            .= object
              [ "phase" .= gesturePhaseText (App.interactionGesturePhase interaction)
              , "pointerId" .= fmap pointerIdNumber (App.interactionActivePointer interaction)
              ]
        , "preview" .= preview
        , "navigator" .= navigator
        ]
    )

previewValue :: (Canvas.DragResolution, GesturePreview) -> Either ProductV2Error Value
previewValue (resolution, GesturePreview node _ mode editRequest result) = do
  let outcome =
        if Source.snapshotBytes (Document.documentSource result)
            == Source.snapshotBytes (Document.documentSource (App.canvasEditRequestDocument editRequest))
          then "no_op" :: Text
          else "verified"
  Right
    ( object
        [ "nodeId" .= Canvas.identifierText node
        , "centre" .= pointValue (Canvas.dragResolvedCenter resolution)
        , "freeDrag" .= (mode == Canvas.FreeDrag)
        , "guides" .= fmap snapGuideValue (Canvas.dragGuides resolution)
        , "outcome" .= outcome
        ]
    )

hostActionValue :: App.HostAction -> Value
hostActionValue action =
  case action of
    App.RequestPointerCapture identity ->
      object ["kind" .= ("capture_pointer" :: Text), "pointerId" .= pointerIdNumber identity]
    App.RequestPointerRelease identity ->
      object ["kind" .= ("release_pointer" :: Text), "pointerId" .= pointerIdNumber identity]
    App.RequestRepaint -> object ["kind" .= ("repaint" :: Text)]
    App.ShowPreview node resolution mode ->
      object
        [ "kind" .= ("show_preview" :: Text)
        , "nodeId" .= Canvas.identifierText node
        , "centre" .= pointValue (Canvas.dragResolvedCenter resolution)
        , "freeDrag" .= (mode == Canvas.FreeDrag)
        , "guides" .= fmap snapGuideValue (Canvas.dragGuides resolution)
        ]
    App.ClearPreview -> object ["kind" .= ("clear_preview" :: Text)]

navigatorValue :: ProductV2State -> Either ProductV2Error Value
navigatorValue state =
  case productNavigation state of
    Nothing ->
      Right
        ( object
            [ "activeIndex" .= (0 :: Int)
            , "activeFrame" .= Null
            , "slideCount" .= (0 :: Int)
            , "items" .= ([] :: [Value])
            , "previous" .= availabilityValue (App.InteractionCommandDisabled App.OnlySlideAvailable)
            , "next" .= availabilityValue (App.InteractionCommandDisabled App.OnlySlideAvailable)
            , "newSlide" .= object ["enabled" .= False, "disabledReason" .= ("source_not_ready" :: Text)]
            ]
        )
    Just navigation -> do
      let entries = NonEmpty.toList (App.navigationEntries navigation)
          count = length entries
          index = App.navigationActiveIndex navigation
          previousReason = if count == 1 then ("only_slide_available" :: Text) else "first_slide"
          nextReason = if count == 1 then ("only_slide_available" :: Text) else "last_slide"
      items <- traverse navigationItemValue entries
      Right
        ( object
            [ "activeIndex" .= index
            , "activeFrame" .= Presentation.frameIdText (App.navigationActiveFrame navigation)
            , "slideCount" .= count
            , "items" .= items
            , "previous" .= boundaryAvailability (App.navigationCanPrevious navigation) previousReason
            , "next" .= boundaryAvailability (App.navigationCanNext navigation) nextReason
            , "newSlide" .= object ["enabled" .= True, "disabledReason" .= Null]
            ]
        )
  where
    navigationItemValue entry = do
      let frame = App.navigationEntryFrame entry
          audienceAddress = Presentation.surfaceAddress frame Presentation.AudienceSurface
          notesAddress = Presentation.surfaceAddress frame Presentation.NotesSurface
      audience <-
        traverse
          (\(CorrelatedPaint _ plan) -> renderPlanValue plan)
          (Map.lookup audienceAddress (productPaints state))
      notes <-
        traverse
          (\(CorrelatedPaint _ plan) -> renderPlanValue plan)
          (Map.lookup notesAddress (productPaints state))
      Right
        ( object
            [ "frame" .= Presentation.frameIdText frame
            , "title" .= App.navigationEntryTitle entry
            , "audience" .= audience
            , "notes" .= notes
            ]
        )
    boundaryAvailability enabled reason =
      if enabled
        then object ["enabled" .= True, "disabledReason" .= Null]
        else object ["enabled" .= False, "disabledReason" .= reason]

availabilityValue :: App.InteractionCommandAvailability -> Value
availabilityValue availability =
  case availability of
    App.InteractionCommandEnabled ->
      object ["enabled" .= True, "disabledReason" .= Null]
    App.InteractionCommandDisabled reason ->
      object ["enabled" .= False, "disabledReason" .= disabledReasonText reason]

disabledReasonText :: App.CommandDisabledReason -> Text
disabledReasonText reason =
  case reason of
    App.OnlySlideAvailable -> "only_slide_available"

gesturePhaseText :: App.GesturePhase -> Text
gesturePhaseText phase =
  case phase of
    App.GestureIdle -> "idle"
    App.GesturePressed -> "pressed"
    App.GestureDragging -> "dragging"

pointerIdNumber :: App.PointerId -> Word64
pointerIdNumber (App.PointerId value) = value

snapGuideValue :: Canvas.SnapGuide -> Value
snapGuideValue guide =
  object
    [ "kind" .= guideKindText (Canvas.guideKind guide)
    , "start" .= pointValue (Canvas.guideStart guide)
    , "end" .= pointValue (Canvas.guideEnd guide)
    ]

guideKindText :: Canvas.GuideKind -> Text
guideKindText kind =
  case kind of
    Canvas.PointGuide -> "point"
    Canvas.AlignmentGuide -> "alignment"
    Canvas.SpacingGuide -> "spacing"
    Canvas.BindingGuide -> "binding"

readinessText :: App.DocumentSession Deck.DeckSyntax Deck.DeckFieldKey -> Text
readinessText session =
  case App.sessionAcceptedDocument session of
    Nothing -> "pending"
    Just document ->
      case Document.documentSemantic document of
        Nothing -> "syntax_only"
        Just _ -> "ready"

authorityText :: ProductV2State -> Text
authorityText state =
  case productDisplayedPaint state of
    Nothing ->
      case productOfferedPaint state of
        Nothing -> "none"
        Just _ -> "paint_pending"
    Just (CorrelatedPaint request _) ->
      let session = App.appDocumentSession (productAppModel state)
          authority =
            App.sessionCanvasAuthority (App.paintRequestSurface request) session
       in if App.authorityAllowsEdit request authority then "writable" else "inert"

correlatedValue :: CorrelatedPaint -> Either ProductV2Error Value
correlatedValue (CorrelatedPaint request plan) = do
  encodedPlan <- renderPlanValue plan
  Right
    ( object
        [ "fence" .= fenceValue request
        , "plan" .= encodedPlan
        ]
    )

fenceValue :: App.PaintRequest -> Value
fenceValue request =
  object
    [ "session" .= App.sessionIdToWord64 (App.paintRequestSession request)
    , "revision" .= revisionNumber (App.paintRequestRevision request)
    , "ticket" .= Render.renderTicketToWord64 (App.paintRequestTicket request)
    , "surface" .= surfaceValue (App.paintRequestSurface request)
    ]

renderPlanValue :: Render.RenderPlan -> Either ProductV2Error Value
renderPlanValue plan = do
  layers <- traverse layerValue (NonEmpty.toList (Render.renderPlanLayers plan))
  Right
    ( object
        [ "protocol" .= Protocol.productProtocolV2
        , "revision" .= revisionNumber (Render.renderPlanRevision plan)
        , "ticket" .= Render.renderTicketToWord64 (Render.renderPlanTicket plan)
        , "surface" .= surfaceValue (Render.renderPlanSurface plan)
        , "coordinateSpace" .= ("slide_16x9_y_up" :: Text)
        , "size" .= sizeValue (Render.renderPlanSize plan)
        , "layers" .= layers
        ]
    )

layerValue :: Render.RenderLayer -> Either ProductV2Error Value
layerValue layer = do
  items <- traverse itemValue (Render.renderLayerItems layer)
  Right
    ( object
        [ "kind" .= layerKindText (Render.renderLayerKind layer)
        , "items" .= items
        ]
    )

itemValue :: Render.RenderItem -> Either ProductV2Error Value
itemValue item =
  case Render.renderItemPrimitive item of
    Render.ShapePrimitive outline _ -> do
      identity <- identityValue (Render.renderItemIdentity item)
      box <- outlineBoxValue outline
      hitTarget <- hitTargetValue (Render.renderItemHitRegion item)
      Right
        ( object
            [ "kind" .= ("rectangle" :: Text)
            , "identity" .= identity
            , "box" .= box
            , "hitTarget" .= hitTarget
            , "interaction" .= interactionValue (Render.renderItemInteraction item)
            ]
        )
    Render.ConnectorPrimitive path _ _ -> do
      identity <- identityValue (Render.renderItemIdentity item)
      endpoint <- pathEndpointValue path
      Right
        ( object
            [ "kind" .= ("line" :: Text)
            , "identity" .= identity
            , "start" .= pointValue (Render.renderPathStart path)
            , "end" .= endpoint
            , "interaction" .= interactionValue (Render.renderItemInteraction item)
            ]
        )
    _ -> Left ProductV2RenderRejected

outlineBoxValue :: Render.RenderOutline -> Either ProductV2Error Value
outlineBoxValue outline =
  case Render.renderOutlineView outline of
    Render.RenderRectangleView box _ -> Right (boxValue box)
    _ -> Left ProductV2RenderRejected

hitTargetValue :: Render.RenderHitRegion -> Either ProductV2Error Value
hitTargetValue region =
  case Render.renderHitRegionView region of
    Render.RenderOutlineHitRegionView outline -> outlineBoxValue outline
    Render.RenderBoxHitRegionView box -> Right (boxValue box)
    _ -> Left ProductV2RenderRejected

pathEndpointValue :: Render.RenderPath -> Either ProductV2Error Value
pathEndpointValue path =
  case NonEmpty.toList (Render.renderPathSegments path) of
    [Render.RenderLineTo endpoint] -> Right (pointValue endpoint)
    _ -> Left ProductV2RenderRejected

identityValue :: Render.RenderIdentity -> Either ProductV2Error Value
identityValue identity =
  case identity of
    Render.ElementRender address part ->
      Right
        ( object
            [ "surface" .= surfaceValue (Presentation.elementAddressSurface address)
            , "element" .= elementValue (Presentation.elementAddressElement address)
            , "part" .= Render.renderPartText part
            ]
        )
    _ -> Left ProductV2RenderRejected

interactionValue :: Render.Interaction -> Value
interactionValue interaction =
  case interaction of
    Render.Inert -> object ["kind" .= ("inert" :: Text)]
    Render.SelectElement address ->
      object
        [ "kind" .= ("select_element" :: Text)
        , "surface" .= surfaceValue (Presentation.elementAddressSurface address)
        , "element" .= elementValue (Presentation.elementAddressElement address)
        ]

elementValue :: Canvas.ElementId -> Value
elementValue element =
  case element of
    Canvas.NodeElement identity ->
      object
        [ "kind" .= ("node" :: Text)
        , "id" .= Canvas.identifierText identity
        ]
    Canvas.ConnectorElement identity ->
      object
        [ "kind" .= ("connector" :: Text)
        , "id" .= Canvas.identifierText identity
        ]
    Canvas.GroupElement identity ->
      object
        [ "kind" .= ("group" :: Text)
        , "id" .= Canvas.identifierText identity
        ]

surfaceValue :: Presentation.SurfaceAddress -> Value
surfaceValue surface =
  object
    [ "frame" .= Presentation.frameIdText (Presentation.surfaceAddressFrame surface)
    , "kind" .= surfaceKindText (Presentation.surfaceAddressKind surface)
    ]

surfaceKindText :: Presentation.SurfaceKind -> Text
surfaceKindText kind =
  case kind of
    Presentation.AudienceSurface -> "audience"
    Presentation.NotesSurface -> "notes"

layerKindText :: Render.RenderLayerKind -> Text
layerKindText kind =
  case kind of
    Render.BackgroundLayer -> "background"
    Render.RearFurnitureLayer -> "rear_furniture"
    Render.ConnectorLayer -> "connector"
    Render.ObjectLayer -> "object"
    Render.ContentLayer -> "content"
    Render.FrontFurnitureLayer -> "front_furniture"

boxValue :: Canvas.Box -> Value
boxValue box =
  object
    [ "center" .= pointValue (Canvas.boxCenter box)
    , "size" .= sizeValue (Canvas.boxSize box)
    ]

sizeValue :: Canvas.Size -> Value
sizeValue size =
  object
    [ "width" .= rationalText (Canvas.canvasUnitValue (Canvas.sizeWidth size))
    , "height" .= rationalText (Canvas.canvasUnitValue (Canvas.sizeHeight size))
    ]

pointValue :: Canvas.Point -> Value
pointValue point =
  object
    [ "x" .= rationalText (Canvas.canvasUnitValue (Canvas.pointX point))
    , "y" .= rationalText (Canvas.canvasUnitValue (Canvas.pointY point))
    ]

ensureOpen :: ProductV2State -> Either ProductV2Error ()
ensureOpen state
  | productIsOpen state = Right ()
  | otherwise = Left ProductV2WorkspaceNotOpen

ensureRevision :: Word64 -> ProductV2State -> Either ProductV2Error ()
ensureRevision requested state
  | requested == actual = Right ()
  | otherwise = Left (ProductV2StaleRevision requested actual)
  where
    actual =
      revisionNumber
        ( Source.snapshotRevision
            (App.sessionDraft (App.appDocumentSession (productAppModel state)))
        )

ensureFence :: PaintFenceValue -> CorrelatedPaint -> Either ProductV2Error ()
ensureFence supplied (CorrelatedPaint request _) =
  if supplied == paintFence request
    then Right ()
    else Left ProductV2PaintFenceMismatch

paintFence :: App.PaintRequest -> PaintFenceValue
paintFence request =
  let surface = App.paintRequestSurface request
   in PaintFenceValue
        { fenceSession = App.sessionIdToWord64 (App.paintRequestSession request)
        , fenceRevision = revisionNumber (App.paintRequestRevision request)
        , fenceTicket = Render.renderTicketToWord64 (App.paintRequestTicket request)
        , fenceFrame = Presentation.frameIdText (Presentation.surfaceAddressFrame surface)
        , fenceSurface = surfaceKindToValue (Presentation.surfaceAddressKind surface)
        }

surfaceKindToValue :: Presentation.SurfaceKind -> Protocol.SurfaceKindValue
surfaceKindToValue kind =
  case kind of
    Presentation.AudienceSurface -> Protocol.AudienceSurfaceValue
    Presentation.NotesSurface -> Protocol.NotesSurfaceValue

admittedNode
  :: Canvas.NodeId
  -> App.AppModel Deck.DeckSyntax Deck.DeckFieldKey
  -> Bool
admittedNode identity model =
  case App.sessionAcceptedDocument (App.appDocumentSession model) of
    Nothing -> False
    Just document ->
      case Document.documentSemantic document of
        Nothing -> False
        Just presentation ->
          any
            (\frame ->
              case Canvas.findElement (Canvas.NodeElement identity) (Presentation.frameAudiencePicture frame) of
                Just (Canvas.CanvasNode _) -> True
                _ -> False
            )
            (NonEmpty.toList (Presentation.presentationFrames presentation))

rationalText :: Rational -> Text
rationalText value
  | denominator value == 1 = Text.pack (show (numerator value))
  | otherwise =
      Text.pack (show (numerator value))
        <> "/"
        <> Text.pack (show (denominator value))

base16Encode :: ByteString -> Text
base16Encode = Text.pack . foldMap encodeByte . ByteString.unpack
  where
    encodeByte byte = [hexDigit (byte `div` 16), hexDigit (byte `mod` 16)]

hexDigit :: Word8 -> Char
hexDigit value =
  case value of
    0 -> '0'
    1 -> '1'
    2 -> '2'
    3 -> '3'
    4 -> '4'
    5 -> '5'
    6 -> '6'
    7 -> '7'
    8 -> '8'
    9 -> '9'
    10 -> 'a'
    11 -> 'b'
    12 -> 'c'
    13 -> 'd'
    14 -> 'e'
    _ -> 'f'

mapUpdate
  :: Either App.UpdateError value
  -> Either ProductV2Error value
mapUpdate = mapLeft (const ProductV2AnalysisRejected)

revisionNumber :: Source.Revision -> Word64
revisionNumber = Source.revisionToWord64

mapLeft :: (left -> other) -> Either left value -> Either other value
mapLeft convert result =
  case result of
    Left failure -> Left (convert failure)
    Right value -> Right value

firstJust :: Maybe value -> Maybe value -> Maybe value
firstJust first second =
  case first of
    Just value -> Just value
    Nothing -> second
