-- |
-- Module      : SlideBlaster.Presentation.Model
-- Description : Frames, notes sidecars, and audience-capped presentation beats.
--
-- A presentation is semantic data over canvas pictures. Deck aspect ratio and
-- per-frame display rotation are retained without choosing source syntax or
-- renderer coordinate semantics. Each frame owns one validated 'Scene', so its
-- picture, derived overlays, and animation targets cannot disagree. The
-- audience scene alone determines each frame's beat count. Notes are a full
-- scene projected at the same step, but can never add a beat.
module SlideBlaster.Presentation.Model
  ( AspectRatio
  , AspectRatioError (..)
  , Beat
  , Frame
  , FrameId
  , FrameIdError (..)
  , FrameMetadata
  , Notes
  , Presentation
  , PresentationError (..)
  , PresentationMetadata
  , SlideRotation
  , aspectRatioHeight
  , aspectRatioWidth
  , beatAnimations
  , beatAspectRatio
  , beatAudiencePicture
  , beatAudienceScene
  , beatFrameCount
  , beatFrameId
  , beatFrameNumber
  , beatFrameRotation
  , beatFrameTitle
  , beatNotesAnimations
  , beatNotesPicture
  , beatNotesScene
  , beatReducedMotionPolicy
  , beatStep
  , beatStepCount
  , beatTheme
  , defaultAspectRatio
  , flattenBeats
  , frameAnimations
  , frameAudienceOverlay
  , frameAudiencePicture
  , frameAudienceScene
  , frameId
  , frameIdText
  , frameMetadata
  , frameNotes
  , frameRotation
  , frameStepCount
  , frameTitle
  , mkAspectRatio
  , mkFrame
  , mkFrameId
  , mkFrameMetadata
  , mkNotes
  , mkPresentation
  , mkPresentationMetadata
  , noSlideRotation
  , notesAnimations
  , notesOverlay
  , notesPicture
  , notesScene
  , presentationAspectRatio
  , presentationFrames
  , presentationMetadata
  , presentationReducedMotionPolicy
  , presentationTheme
  , presentationTitle
  , slideRotationDegrees
  , slideRotationFromDegrees
  ) where

import SlideBlaster.Canvas
  ( OverlayStep
  , Picture
  , Theme
  , firstOverlayStep
  , mkOverlayStep
  )
import SlideBlaster.Presentation.Animation
  ( Animation
  , AnimationTimeline
  , ReducedMotionPolicy
  , animationsForStep
  )
import SlideBlaster.Presentation.Overlay
  ( OverlayProgram
  , StepCount
  , overlayProgramStepCount
  , stepCountNumber
  )
import SlideBlaster.Presentation.Scene
  ( Scene
  , sceneAnalysis
  , sceneAnimationTimeline
  , sceneOverlayProgram
  , scenePicture
  )

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

-- | Stable frame identity preserved across reorder and title changes.
newtype FrameId = FrameId Text
  deriving stock (Eq, Ord, Show)

-- | Failure to construct a frame identity.
data FrameIdError = FrameIdEmpty
  deriving stock (Eq, Show)

-- | Construct a non-blank frame identity while preserving its spelling.
mkFrameId :: Text -> Either FrameIdError FrameId
mkFrameId value
  | Text.null (Text.strip value) = Left FrameIdEmpty
  | otherwise = Right (FrameId value)

-- | Return stable frame identity text.
frameIdText :: FrameId -> Text
frameIdText (FrameId value) = value

-- | Positive, normalized width-to-height deck aspect ratio.
data AspectRatio = AspectRatio !Natural !Natural
  deriving stock (Eq, Ord, Show)

-- | Invalid aspect-ratio dimension.
data AspectRatioError
  = AspectRatioWidthIsZero
  | AspectRatioHeightIsZero
  deriving stock (Eq, Show)

-- | Construct a positive aspect ratio and reduce it by its greatest common
-- divisor.
mkAspectRatio
  :: Natural
  -> Natural
  -> Either AspectRatioError AspectRatio
mkAspectRatio 0 _ = Left AspectRatioWidthIsZero
mkAspectRatio _ 0 = Left AspectRatioHeightIsZero
mkAspectRatio width height =
  let common = gcd width height
   in Right (AspectRatio (width `div` common) (height `div` common))

-- | The default widescreen ratio.
defaultAspectRatio :: AspectRatio
defaultAspectRatio = AspectRatio 16 9

-- | Return normalized aspect width.
aspectRatioWidth :: AspectRatio -> Natural
aspectRatioWidth (AspectRatio width _) = width

-- | Return normalized aspect height.
aspectRatioHeight :: AspectRatio -> Natural
aspectRatioHeight (AspectRatio _ height) = height

-- | Normalized display rotation in rational degrees @[0,360)@.
--
-- This type records semantic metadata only. It does not decide which angles a
-- UI offers, whether rotation changes logical coordinates, or how source and
-- export formats spell the value.
newtype SlideRotation = SlideRotation Rational
  deriving stock (Eq, Ord, Show)

-- | An unrotated frame.
noSlideRotation :: SlideRotation
noSlideRotation = SlideRotation 0

-- | Normalize rational display degrees into @[0,360)@.
slideRotationFromDegrees :: Rational -> SlideRotation
slideRotationFromDegrees degrees =
  let completeTurns = floor (degrees / 360)
   in SlideRotation (degrees - fromInteger completeTurns * 360)

-- | Return normalized rational display degrees.
slideRotationDegrees :: SlideRotation -> Rational
slideRotationDegrees (SlideRotation degrees) = degrees

-- | Navigation metadata attached to one frame.
data FrameMetadata = FrameMetadata !Text !SlideRotation
  deriving stock (Eq, Show)

-- | Construct navigation metadata.
mkFrameMetadata :: Text -> SlideRotation -> FrameMetadata
mkFrameMetadata = FrameMetadata

-- | Return the navigation title; visible titles remain canvas content.
frameTitle :: Frame -> Text
frameTitle (Frame _ (FrameMetadata title _) _ _) = title

-- | Return per-frame display rotation metadata.
frameRotation :: Frame -> SlideRotation
frameRotation (Frame _ (FrameMetadata _ rotation) _ _) = rotation

-- | A full presenter-only picture scene.
newtype Notes = Notes Scene
  deriving stock (Eq, Show)

-- | Construct a full notes sidecar scene.
mkNotes :: Scene -> Notes
mkNotes = Notes

-- | Return the coherent notes scene.
notesScene :: Notes -> Scene
notesScene (Notes scene) = scene

-- | Return the notes canvas picture.
notesPicture :: Notes -> Picture
notesPicture = scenePicture . notesScene

-- | Return notes overlays. They are projected at the audience step but never
-- consulted when deriving frame beats.
notesOverlay :: Notes -> OverlayProgram
notesOverlay = sceneOverlayProgram . sceneAnalysis . notesScene

-- | Return the notes timed-animation timeline.
notesAnimations :: Notes -> AnimationTimeline
notesAnimations = sceneAnimationTimeline . notesScene

-- | One ordered audience frame with an optional full notes sidecar.
data Frame
  = Frame
      !FrameId
      !FrameMetadata
      !Scene
      !(Maybe Notes)
  deriving stock (Eq, Show)

-- | Construct one semantic frame.
mkFrame
  :: FrameId
  -> FrameMetadata
  -> Scene
  -> Maybe Notes
  -> Frame
mkFrame = Frame

-- | Return stable frame identity.
frameId :: Frame -> FrameId
frameId (Frame identity _ _ _) = identity

-- | Return frame navigation metadata.
frameMetadata :: Frame -> FrameMetadata
frameMetadata (Frame _ metadata _ _) = metadata

-- | Return the coherent audience scene.
frameAudienceScene :: Frame -> Scene
frameAudienceScene (Frame _ _ scene _) = scene

-- | Return the audience canvas picture.
frameAudiencePicture :: Frame -> Picture
frameAudiencePicture = scenePicture . frameAudienceScene

-- | Return the normalized audience overlay aggregation.
frameAudienceOverlay :: Frame -> OverlayProgram
frameAudienceOverlay =
  sceneOverlayProgram . sceneAnalysis . frameAudienceScene

-- | Return the audience timed-animation timeline.
frameAnimations :: Frame -> AnimationTimeline
frameAnimations = sceneAnimationTimeline . frameAudienceScene

-- | Return the optional full notes sidecar.
frameNotes :: Frame -> Maybe Notes
frameNotes (Frame _ _ _ notes) = notes

-- | Derive the positive audience-owned frame step count.
frameStepCount :: Frame -> StepCount
frameStepCount = overlayProgramStepCount . frameAudienceOverlay

-- | Deck-level semantic metadata.
data PresentationMetadata
  = PresentationMetadata
      !Text
      !AspectRatio
      !Theme
      !ReducedMotionPolicy
  deriving stock (Eq, Show)

-- | Construct deck-level semantic metadata.
mkPresentationMetadata
  :: Text
  -> AspectRatio
  -> Theme
  -> ReducedMotionPolicy
  -> PresentationMetadata
mkPresentationMetadata = PresentationMetadata

-- | Return the presentation title.
presentationTitle :: Presentation -> Text
presentationTitle
  (Presentation (PresentationMetadata title _ _ _) _) = title

-- | Return the deck-wide aspect ratio.
presentationAspectRatio :: Presentation -> AspectRatio
presentationAspectRatio
  (Presentation (PresentationMetadata _ ratio _ _) _) = ratio

-- | Return the selected structured canvas theme and furniture.
presentationTheme :: Presentation -> Theme
presentationTheme
  (Presentation (PresentationMetadata _ _ theme _) _) = theme

-- | Return the deck's reduced-motion policy.
presentationReducedMotionPolicy :: Presentation -> ReducedMotionPolicy
presentationReducedMotionPolicy
  (Presentation (PresentationMetadata _ _ _ policy) _) = policy

-- | An ordered, non-empty semantic deck with unique stable frame identities.
data Presentation
  = Presentation !PresentationMetadata !(NonEmpty Frame)
  deriving stock (Eq, Show)

-- | Failure to construct one coherent semantic presentation.
data PresentationError
  = DuplicatePresentationFrameId !FrameId
  deriving stock (Eq, Show)

-- | Construct a non-empty presentation and reject ambiguous stable addresses.
--
-- Empty authoring workspaces belong to application state before elaboration;
-- they are not semantic presentations.
mkPresentation
  :: PresentationMetadata
  -> NonEmpty Frame
  -> Either PresentationError Presentation
mkPresentation metadata frames =
  case firstDuplicateFrameId [] (NonEmpty.toList frames) of
    Nothing -> Right (Presentation metadata frames)
    Just duplicate -> Left (DuplicatePresentationFrameId duplicate)

-- | Return deck metadata.
presentationMetadata :: Presentation -> PresentationMetadata
presentationMetadata (Presentation metadata _) = metadata

-- | Return frames in presentation order.
presentationFrames :: Presentation -> NonEmpty Frame
presentationFrames (Presentation _ frames) = frames

-- | One audience-owned @(frame, step)@ item in reading order.
--
-- The constructor is private: all beats come from 'flattenBeats', which proves
-- that their step is within the owning frame's audience-derived count.
data Beat
  = Beat
      !Frame
      !Natural
      !Natural
      !OverlayStep
      !AspectRatio
      !Theme
      !ReducedMotionPolicy

-- | Expand every frame into a non-empty audience-owned overlay beat stream.
flattenBeats :: Presentation -> NonEmpty Beat
flattenBeats presentation =
  let frames = presentationFrames presentation
      totalFrames = naturalLength frames
      ratio = presentationAspectRatio presentation
      theme = presentationTheme presentation
      policy = presentationReducedMotionPolicy presentation
      firstFrame :| remainingFrames = frames
      firstFrameBeats =
        frameBeats totalFrames ratio theme policy 1 firstFrame
   in foldl
        ( \beats (frameNumber, frame) ->
            beats
              <> frameBeats
                totalFrames
                ratio
                theme
                policy
                frameNumber
                frame
        )
        firstFrameBeats
        (zip [2 ..] remainingFrames)

frameBeats
  :: Natural
  -> AspectRatio
  -> Theme
  -> ReducedMotionPolicy
  -> Natural
  -> Frame
  -> NonEmpty Beat
frameBeats totalFrames ratio theme policy frameNumber frame =
  fmap
    (\step -> Beat frame frameNumber totalFrames step ratio theme policy)
    ( frameOverlaySteps
        (stepCountNumber (frameStepCount frame))
    )

frameOverlaySteps :: Natural -> NonEmpty OverlayStep
frameOverlaySteps finalStep =
  firstOverlayStep
    :| mapMaybe mkOverlayStep [2 .. finalStep]

naturalLength :: NonEmpty value -> Natural
naturalLength (_ :| remaining) =
  1 + foldr (const (+ 1)) 0 remaining

firstDuplicateFrameId :: [FrameId] -> [Frame] -> Maybe FrameId
firstDuplicateFrameId _ [] = Nothing
firstDuplicateFrameId seen (frame : remaining)
  | frameId frame `elem` seen = Just (frameId frame)
  | otherwise =
      firstDuplicateFrameId (frameId frame : seen) remaining

-- | Return stable owning-frame identity.
beatFrameId :: Beat -> FrameId
beatFrameId (Beat frame _ _ _ _ _ _) = frameId frame

-- | Return the one-based frame number.
beatFrameNumber :: Beat -> Natural
beatFrameNumber (Beat _ number _ _ _ _ _) = number

-- | Return the total number of frames.
beatFrameCount :: Beat -> Natural
beatFrameCount (Beat _ _ total _ _ _ _) = total

-- | Return the owning frame's navigation title.
beatFrameTitle :: Beat -> Text
beatFrameTitle (Beat frame _ _ _ _ _ _) = frameTitle frame

-- | Return the owning frame's display rotation.
beatFrameRotation :: Beat -> SlideRotation
beatFrameRotation (Beat frame _ _ _ _ _ _) = frameRotation frame

-- | Return deck-wide aspect metadata.
beatAspectRatio :: Beat -> AspectRatio
beatAspectRatio (Beat _ _ _ _ ratio _ _) = ratio

-- | Return the selected structured theme and furniture.
beatTheme :: Beat -> Theme
beatTheme (Beat _ _ _ _ _ theme _) = theme

-- | Return the current one-based overlay step.
beatStep :: Beat -> OverlayStep
beatStep (Beat _ _ _ step _ _ _) = step

-- | Return the owning frame's audience-derived step count.
beatStepCount :: Beat -> StepCount
beatStepCount (Beat frame _ _ _ _ _ _) = frameStepCount frame

-- | Return the audience picture.
beatAudiencePicture :: Beat -> Picture
beatAudiencePicture (Beat frame _ _ _ _ _ _) = frameAudiencePicture frame

-- | Return the audience scene from which picture, overlays, and animations
-- were coherently derived.
beatAudienceScene :: Beat -> Scene
beatAudienceScene (Beat frame _ _ _ _ _ _) = frameAudienceScene frame

-- | Return the optional notes picture at the same current step.
beatNotesPicture :: Beat -> Maybe Picture
beatNotesPicture (Beat frame _ _ _ _ _ _) =
  notesPicture <$> frameNotes frame

-- | Return the optional coherent notes scene at the current audience step.
beatNotesScene :: Beat -> Maybe Scene
beatNotesScene (Beat frame _ _ _ _ _ _) =
  notesScene <$> frameNotes frame

-- | Return audience animations scheduled on this existing beat.
beatAnimations :: Beat -> [Animation]
beatAnimations (Beat frame _ _ step _ _ _) =
  animationsForStep step (frameAnimations frame)

-- | Return notes animations scheduled on this existing beat. These never add
-- beats even when the notes timeline refers to later steps.
beatNotesAnimations :: Beat -> [Animation]
beatNotesAnimations (Beat frame _ _ step _ _ _) =
  case frameNotes frame of
    Nothing -> []
    Just notes -> animationsForStep step (notesAnimations notes)

-- | Return the deck's reduced-motion policy.
beatReducedMotionPolicy :: Beat -> ReducedMotionPolicy
beatReducedMotionPolicy (Beat _ _ _ _ _ _ policy) = policy
