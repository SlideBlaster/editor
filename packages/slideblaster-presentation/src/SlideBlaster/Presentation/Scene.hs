-- |
-- Module      : SlideBlaster.Presentation.Scene
-- Description : Validated picture, overlay, and animation authority.
--
-- A 'Scene' is the only presentation-owned pairing of a canvas 'Picture' with
-- overlay and timed-animation analysis. Its overlay hooks are derived by
-- walking the picture and the canvas-owned recursive content overlay event
-- stream, including point pauses. Animation track and click targets are
-- validated against the same element set. Callers therefore cannot attach an
-- unrelated overlay program or a foreign animation target to a picture.
module SlideBlaster.Presentation.Scene
  ( Scene
  , SceneAnalysis
  , SceneError (..)
  , emptyScene
  , mkScene
  , sceneAnalysis
  , sceneAnimationTimeline
  , sceneElementIds
  , sceneOverlayProgram
  , scenePicture
  ) where

import SlideBlaster.Canvas
  ( CanvasObject (..)
  , Connector (connectorLabel)
  , Content
  , ContentOverlayEvent (..)
  , ElementId
  , Node (nodeContent)
  , OverlayDirective (..)
  , Picture
  , contentOverlayEvents
  , elementId
  , elementOverlay
  , emptyPicture
  , pictureElements
  )
import SlideBlaster.Presentation.Animation
  ( Animation
  , AnimationId
  , AnimationTarget
  , AnimationTimeline
  , AnimationTrigger (..)
  , animationId
  , animationTargetElement
  , animationTimelineAnimations
  , animationTracks
  , animationTrigger
  , emptyAnimationTimeline
  , trackTarget
  )
import SlideBlaster.Presentation.Overlay
  ( OverlayProgram
  , emptyOverlayProgram
  , overlayHookProgram
  , overlayPause
  , overlayPauseAt
  , overlaySequence
  )

import Data.List.NonEmpty qualified as NonEmpty

-- | Derived facts that must stay coherent with one exact picture.
data SceneAnalysis
  = SceneAnalysis !OverlayProgram ![ElementId]
  deriving stock (Eq, Show)

-- | One coherent picture scene with validated animation ownership.
data Scene
  = Scene
      !Picture
      !AnimationTimeline
      !SceneAnalysis
  deriving stock (Eq, Show)

-- | Failure to construct a coherent scene.
data SceneError
  = SceneAnimationTrackTargetMissing !AnimationId !ElementId
  | SceneAnimationClickTargetMissing !AnimationId !ElementId
  deriving stock (Eq, Show)

-- | The empty one-step scene.
emptyScene :: Scene
emptyScene =
  Scene
    emptyPicture
    emptyAnimationTimeline
    (SceneAnalysis emptyOverlayProgram [])

-- | Derive overlay analysis and validate every scene-local reference.
mkScene
  :: Picture
  -> AnimationTimeline
  -> Either SceneError Scene
mkScene picture timeline = do
  let objects = pictureElements picture
      identities = elementId <$> objects
  validateAnimationTargets identities timeline
  let analysis =
        SceneAnalysis
          (overlaySequence (objectOverlayProgram <$> objects))
          identities
  Right (Scene picture timeline analysis)

-- | Return the authoritative canvas picture.
scenePicture :: Scene -> Picture
scenePicture (Scene picture _ _) = picture

-- | Return the validated timed-animation timeline.
sceneAnimationTimeline :: Scene -> AnimationTimeline
sceneAnimationTimeline (Scene _ timeline _) = timeline

-- | Return derived scene facts.
sceneAnalysis :: Scene -> SceneAnalysis
sceneAnalysis (Scene _ _ analysis) = analysis

-- | Return the picture/content-derived overlay program.
sceneOverlayProgram :: SceneAnalysis -> OverlayProgram
sceneOverlayProgram (SceneAnalysis program _) = program

-- | Return scene element identities in picture reading order.
sceneElementIds :: SceneAnalysis -> [ElementId]
sceneElementIds (SceneAnalysis _ identities) = identities

validateAnimationTargets
  :: [ElementId]
  -> AnimationTimeline
  -> Either SceneError ()
validateAnimationTargets identities = go . animationTimelineAnimations
  where
    go [] = Right ()
    go (animation : remaining) = do
      validateTrackTargets identities animation
      validateClickTarget identities animation
      go remaining

validateTrackTargets
  :: [ElementId]
  -> Animation
  -> Either SceneError ()
validateTrackTargets identities animation =
  go (NonEmpty.toList (animationTracks animation))
  where
    go [] = Right ()
    go (track : remaining) = do
      validateTarget
        (SceneAnimationTrackTargetMissing (animationId animation))
        identities
        (trackTarget track)
      go remaining

validateClickTarget
  :: [ElementId]
  -> Animation
  -> Either SceneError ()
validateClickTarget identities animation =
  case animationTrigger animation of
    OnTargetClick _ target ->
      validateTarget
        (SceneAnimationClickTargetMissing (animationId animation))
        identities
        target
    _ -> Right ()

validateTarget
  :: (ElementId -> SceneError)
  -> [ElementId]
  -> AnimationTarget
  -> Either SceneError ()
validateTarget missing identities target =
  case animationTargetElement target of
    Nothing -> Right ()
    Just identity
      | identity `elem` identities -> Right ()
      | otherwise -> Left (missing identity)

objectOverlayProgram :: CanvasObject -> OverlayProgram
objectOverlayProgram object =
  overlaySequence
    [overlayHookProgram (elementOverlay object), objectContentProgram object]

objectContentProgram :: CanvasObject -> OverlayProgram
objectContentProgram object =
  case object of
    CanvasNode node -> contentOverlayProgram (nodeContent node)
    CanvasConnector connector ->
      maybe emptyOverlayProgram contentOverlayProgram (connectorLabel connector)
    CanvasGroup _ -> emptyOverlayProgram

contentOverlayProgram :: Content -> OverlayProgram
contentOverlayProgram contentValue =
  overlaySequence (overlayEventProgram <$> contentOverlayEvents contentValue)

overlayEventProgram :: ContentOverlayEvent -> OverlayProgram
overlayEventProgram event =
  case event of
    ContentOverlayHook hook -> overlayHookProgram hook
    ContentOverlayPause directive ->
      case directive of
        PauseNext -> overlayPause
        PauseAt step -> overlayPauseAt step
