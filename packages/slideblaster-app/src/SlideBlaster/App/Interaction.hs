-- |
-- Module      : SlideBlaster.App.Interaction
-- Description : Browser-neutral pointer gesture policy.
--
-- This total reducer owns pointer eligibility, identity and phase, the
-- CSS-pixel movement threshold, first-action selection and drag, snapping/free
-- preview lifecycle, release/commit/cancel behaviour, and the current one-slide
-- navigator projection. A host supplies closed pointer facts and interprets
-- closed actions. Format composition supplies authority capture, preview
-- verification, and commit callbacks; browser APIs and frame-rate coalescing
-- remain host mechanics. Because every retained move and release is reduced
-- from its raw coordinates, coalescing cannot change the laws.
--
-- Which part of the canvas is visible is browser presentation state. Zoom and
-- pan are therefore owned by the host viewport and are deliberately absent
-- here.
module SlideBlaster.App.Interaction
  ( PointerId (..)
  , PointerType (..)
  , PointerButton (..)
  , PrimaryEligibility (..)
  , PointerModifiers (..)
  , CssPoint (..)
  , PointerSample (..)
  , PointerTarget (..)
  , PointerEvent (..)
  , GesturePhase (..)
  , InteractionState
  , InteractionPolicy (..)
  , InteractionFailure (..)
  , CommitDisposition (..)
  , HostAction (..)
  , InteractionTransition (..)
  , initialInteractionState
  , resetDocumentInteraction
  , interactionSelection
  , interactionGesturePhase
  , interactionActivePointer
  , interactionPreview
  , NavigatorProjection (..)
  , navigatorProjection
  , InteractionCommandAvailability (..)
  , CommandDisabledReason (..)
  , reducePointerEvent
  ) where

import SlideBlaster.Canvas qualified as Canvas

import Data.Word (Word64)

-- | Host pointer identity. It is compared for every continuation event.
newtype PointerId = PointerId Word64
  deriving stock (Eq, Ord, Show)

-- | Closed host-observed pointer kind.
data PointerType = MousePointer | PenPointer | TouchPointer
  deriving stock (Eq, Show)

-- | Closed host-observed button fact.
data PointerButton
  = PrimaryButton
  | MiddleButton
  | SecondaryButton
  | OtherButton !Word64
  deriving stock (Eq, Show)

-- | Eligibility derived only from raw host facts.
data PrimaryEligibility
  = EligiblePrimaryPointer
  | NotPrimaryPointer
  | NotPrimaryButton
  deriving stock (Eq, Show)

-- | Keyboard modifiers observed with one raw sample.
data PointerModifiers = PointerModifiers
  { modifierAlt :: !Bool
  , modifierShift :: !Bool
  , modifierControl :: !Bool
  , modifierMeta :: !Bool
  }
  deriving stock (Eq, Show)

-- | Screen-space CSS-pixel coordinate used only for threshold policy.
data CssPoint = CssPoint
  { cssPointX :: !Rational
  , cssPointY :: !Rational
  }
  deriving stock (Eq, Show)

-- | One closed raw pointer sample. Slide coordinates are host-observed geometry;
-- Haskell never reads DOM state.
data PointerSample = PointerSample
  { pointerSampleId :: !PointerId
  , pointerSampleType :: !PointerType
  , pointerSampleButton :: !PointerButton
  , pointerSampleIsPrimary :: !Bool
  , pointerSampleCssPoint :: !CssPoint
  , pointerSampleSlidePoint :: !Canvas.Point
  , pointerSampleModifiers :: !PointerModifiers
  }
  deriving stock (Eq, Show)

-- | Hit target reported by the host's painted closed projection.
data PointerTarget
  = PointerCanvas
  | PointerNode !Canvas.NodeId
  deriving stock (Eq, Show)

-- | Raw event vocabulary. Cancellation and lost capture carry identity so a
-- delayed event cannot cancel a newer pointer.
data PointerEvent
  = PointerPressed !PointerTarget !PointerSample
  | PointerMoved !PointerSample
  | PointerReleased !PointerSample
  | PointerCancelled !PointerId
  | PointerCaptureLost !PointerId
  deriving stock (Eq, Show)

-- | Public gesture phase; payloads and authority fences remain opaque.
data GesturePhase = GestureIdle | GesturePressed | GestureDragging
  deriving stock (Eq, Show)

-- | Format-neutral callbacks. The captured fence must include every authority
-- fact needed to reject stale preview or commit. The preview payload is the
-- exact verified operation later consumed by commit.
data InteractionPolicy fence preview commit = InteractionPolicy
  { captureInteractionFence
      :: Canvas.NodeId -> Either InteractionFailure fence
  , resolveInteractionPreview
      :: fence
      -> Canvas.NodeId
      -> Canvas.Point
      -> Canvas.DragMode
      -> Either InteractionFailure (Canvas.DragResolution, preview)
  , commitInteractionPreview
      :: preview -> Either InteractionFailure (CommitDisposition commit)
  }

-- | Stable semantic failures; format-specific details stay redacted.
data InteractionFailure
  = InteractionAuthorityUnavailable
  | InteractionAuthorityStale
  | InteractionPreviewRejected
  | InteractionCommitRejected
  deriving stock (Eq, Show)

-- | Commit distinguishes a verified source transition from a verified no-op.
data CommitDisposition commit
  = InteractionCommitted !commit
  | InteractionNoOp

-- | Closed effect requests interpreted by a browser or native host.
data HostAction
  = RequestPointerCapture !PointerId
  | RequestPointerRelease !PointerId
  | RequestRepaint
  | ShowPreview !Canvas.NodeId !Canvas.DragResolution !Canvas.DragMode
  | ClearPreview
  deriving stock (Eq, Show)

-- | Reducer output. A commit value is composition-owned state, never a host
-- effect. Host actions contain no DOM operation.
data InteractionTransition fence preview commit = InteractionTransition
  { transitionState :: !(InteractionState fence preview)
  , transitionActions :: ![HostAction]
  , transitionCommit :: !(Maybe commit)
  }

-- | Closed command availability projection.
data InteractionCommandAvailability
  = InteractionCommandEnabled
  | InteractionCommandDisabled !CommandDisabledReason
  deriving stock (Eq, Show)

-- | Why a view command cannot run.
data CommandDisabledReason
  = OnlySlideAvailable
  deriving stock (Eq, Show)

-- | Current one-slide navigator projection. Indexing is zero-based.
data NavigatorProjection = NavigatorProjection
  { navigatorActiveIndex :: !Word64
  , navigatorSlideCount :: !Word64
  , navigatorPreviousAvailability :: !InteractionCommandAvailability
  , navigatorNextAvailability :: !InteractionCommandAvailability
  }
  deriving stock (Eq, Show)

data ActiveGesture fence preview
  = PressedGesture
      !PointerId
      !Canvas.NodeId
      !CssPoint
      !fence
  | DraggingGesture
      !PointerId
      !Canvas.NodeId
      !CssPoint
      !fence
      !(Maybe (Canvas.DragResolution, preview))

data InteractionState fence preview = InteractionState
  { stateSelection :: !(Maybe Canvas.NodeId)
  , stateGesture :: !(Maybe (ActiveGesture fence preview))
  }

-- | Initial idle state.
initialInteractionState :: InteractionState fence preview
initialInteractionState = InteractionState Nothing Nothing

-- | Invalidate document-relative selection, gesture, fence, and preview.
resetDocumentInteraction
  :: InteractionState fence preview
  -> InteractionState otherFence otherPreview
resetDocumentInteraction _ = InteractionState Nothing Nothing

interactionSelection :: InteractionState fence preview -> Maybe Canvas.NodeId
interactionSelection = stateSelection

interactionGesturePhase :: InteractionState fence preview -> GesturePhase
interactionGesturePhase state =
  case stateGesture state of
    Nothing -> GestureIdle
    Just PressedGesture {} -> GesturePressed
    Just DraggingGesture {} -> GestureDragging

interactionActivePointer :: InteractionState fence preview -> Maybe PointerId
interactionActivePointer state = gesturePointerId <$> stateGesture state

interactionPreview
  :: InteractionState fence preview
  -> Maybe (Canvas.DragResolution, preview)
interactionPreview state =
  case stateGesture state of
    Just (DraggingGesture _ _ _ _ preview) -> preview
    _ -> Nothing

navigatorProjection :: InteractionState fence preview -> NavigatorProjection
navigatorProjection _ =
  NavigatorProjection
    { navigatorActiveIndex = 0
    , navigatorSlideCount = 1
    , navigatorPreviousAvailability = InteractionCommandDisabled OnlySlideAvailable
    , navigatorNextAvailability = InteractionCommandDisabled OnlySlideAvailable
    }


-- | Reduce one raw pointer event. A press selects and arms the same gesture;
-- crossing the two-CSS-pixel threshold previews immediately. Release computes
-- from its own retained sample, so dropping intermediate move samples is safe.
reducePointerEvent
  :: InteractionPolicy fence preview commit
  -> PointerEvent
  -> InteractionState fence preview
  -> Either InteractionFailure (InteractionTransition fence preview commit)
reducePointerEvent policy event state =
  case event of
    PointerPressed target sample -> pressPointer policy target sample state
    PointerMoved sample -> continuePointer policy False sample state
    PointerReleased sample -> continuePointer policy True sample state
    PointerCancelled identity -> Right (cancelPointer identity state)
    PointerCaptureLost identity -> Right (cancelPointer identity state)


pressPointer
  :: InteractionPolicy fence preview commit
  -> PointerTarget
  -> PointerSample
  -> InteractionState fence preview
  -> Either InteractionFailure (InteractionTransition fence preview commit)
pressPointer policy target sample state =
  case (primaryEligibility sample, target) of
    (EligiblePrimaryPointer, PointerNode node) -> do
      fence <- captureInteractionFence policy node
      let identity = pointerSampleId sample
          next =
            state
              { stateSelection = Just node
              , stateGesture =
                  Just
                    ( PressedGesture
                        identity
                        node
                        (pointerSampleCssPoint sample)
                        fence
                    )
              }
      Right
        InteractionTransition
          { transitionState = next
          , transitionActions = [RequestPointerCapture identity, RequestRepaint]
          , transitionCommit = Nothing
          }
    _ -> Right (unchangedTransition state)

continuePointer
  :: InteractionPolicy fence preview commit
  -> Bool
  -> PointerSample
  -> InteractionState fence preview
  -> Either InteractionFailure (InteractionTransition fence preview commit)
continuePointer policy isRelease sample state =
  case stateGesture state of
    Nothing -> Right (unchangedTransition state)
    Just gesture
      | gesturePointerId gesture /= pointerSampleId sample ->
          Right (unchangedTransition state)
      | otherwise ->
          let crossed = thresholdCrossed (gestureOrigin gesture) (pointerSampleCssPoint sample)
           in case (gesture, crossed, isRelease) of
                (PressedGesture {}, False, False) -> Right (unchangedTransition state)
                (PressedGesture {}, False, True) ->
                  Right (finishWithoutCommit (pointerSampleId sample) state)
                _ -> previewAndMaybeFinish policy isRelease sample gesture state

previewAndMaybeFinish
  :: InteractionPolicy fence preview commit
  -> Bool
  -> PointerSample
  -> ActiveGesture fence preview
  -> InteractionState fence preview
  -> Either InteractionFailure (InteractionTransition fence preview commit)
previewAndMaybeFinish policy isRelease sample gesture state = do
  let node = gestureNode gesture
      fence = gestureFence gesture
      mode = sampleDragMode sample
  (resolution, preview) <-
    resolveInteractionPreview policy fence node (pointerSampleSlidePoint sample) mode
  if isRelease
    then do
      disposition <- commitInteractionPreview policy preview
      let committed =
            case disposition of
              InteractionCommitted value -> Just value
              InteractionNoOp -> Nothing
      Right
        InteractionTransition
          { transitionState = state {stateGesture = Nothing}
          , transitionActions =
              [ RequestPointerRelease (pointerSampleId sample)
              , ClearPreview
              , RequestRepaint
              ]
          , transitionCommit = committed
          }
    else
      let nextGesture =
            DraggingGesture
              (pointerSampleId sample)
              node
              (gestureOrigin gesture)
              fence
              (Just (resolution, preview))
       in Right
            InteractionTransition
              { transitionState = state {stateGesture = Just nextGesture}
              , transitionActions = [ShowPreview node resolution mode]
              , transitionCommit = Nothing
              }

cancelPointer
  :: PointerId
  -> InteractionState fence preview
  -> InteractionTransition fence preview commit
cancelPointer identity state =
  case stateGesture state of
    Just gesture
      | gesturePointerId gesture == identity ->
          InteractionTransition
            { transitionState = state {stateGesture = Nothing}
            , transitionActions = [RequestPointerRelease identity, ClearPreview, RequestRepaint]
            , transitionCommit = Nothing
            }
    _ -> unchangedTransition state

finishWithoutCommit
  :: PointerId
  -> InteractionState fence preview
  -> InteractionTransition fence preview commit
finishWithoutCommit identity state =
  InteractionTransition
    { transitionState = state {stateGesture = Nothing}
    , transitionActions = [RequestPointerRelease identity, ClearPreview, RequestRepaint]
    , transitionCommit = Nothing
    }

unchangedTransition
  :: InteractionState fence preview
  -> InteractionTransition fence preview commit
unchangedTransition state = InteractionTransition state [] Nothing

primaryEligibility :: PointerSample -> PrimaryEligibility
primaryEligibility sample
  | not (pointerSampleIsPrimary sample) = NotPrimaryPointer
  | pointerSampleButton sample /= PrimaryButton = NotPrimaryButton
  | otherwise = EligiblePrimaryPointer

sampleDragMode :: PointerSample -> Canvas.DragMode
sampleDragMode sample
  | modifierAlt (pointerSampleModifiers sample) = Canvas.FreeDrag
  | otherwise = Canvas.SnappingDrag

thresholdCrossed :: CssPoint -> CssPoint -> Bool
thresholdCrossed origin current =
  let deltaX = cssPointX current - cssPointX origin
      deltaY = cssPointY current - cssPointY origin
   in deltaX * deltaX + deltaY * deltaY >= movementThreshold * movementThreshold

movementThreshold :: Rational
movementThreshold = 2

gesturePointerId :: ActiveGesture fence preview -> PointerId
gesturePointerId gesture =
  case gesture of
    PressedGesture identity _ _ _ -> identity
    DraggingGesture identity _ _ _ _ -> identity

gestureNode :: ActiveGesture fence preview -> Canvas.NodeId
gestureNode gesture =
  case gesture of
    PressedGesture _ node _ _ -> node
    DraggingGesture _ node _ _ _ -> node

gestureOrigin :: ActiveGesture fence preview -> CssPoint
gestureOrigin gesture =
  case gesture of
    PressedGesture _ _ origin _ -> origin
    DraggingGesture _ _ origin _ _ -> origin

gestureFence :: ActiveGesture fence preview -> fence
gestureFence gesture =
  case gesture of
    PressedGesture _ _ _ fence -> fence
    DraggingGesture _ _ _ fence _ -> fence
