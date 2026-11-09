-- |
-- Module      : SlideBlaster.Presentation.Animation
-- Description : Target-neutral timed animation tracks and scheduling.
--
-- Timed animation is frame data, never a source of presenter beats. A timeline
-- assigns each animation to an existing frame-entry or overlay-step trigger;
-- dependency triggers may only refer backwards, making scheduling total and
-- cycle-free. Property tracks are typed by their value domain. Hosts can play
-- them, sample a deterministic static endpoint for export, or apply the
-- presentation's reduced-motion policy.
module SlideBlaster.Presentation.Animation
  ( Animation
  , AnimationError (..)
  , AnimationDisposition (..)
  , AnimationEffect (..)
  , AnimationId
  , AnimationIdError (..)
  , AnimationImportance (..)
  , AnimationSchedule
  , AnimationStart (..)
  , AnimationTarget (..)
  , AnimationTimeline
  , AnimationTiming
  , AnimationTrigger (..)
  , Easing (..)
  , FillMode (..)
  , Keyframe
  , Milliseconds
  , MotionPreference (..)
  , MotionPath
  , MotionPathSegment (..)
  , PlaybackDirection (..)
  , PositiveCount
  , PropertyKind (..)
  , PropertyTrack
  , PropertyTrackView (..)
  , ReducedMotionPolicy (..)
  , Repeat (..)
  , Rgba (..)
  , SampledProperty (..)
  , Scalar2 (..)
  , StaticSample (..)
  , StepPosition (..)
  , TimelineError (..)
  , TimingError (..)
  , TrackError (..)
  , UnitInterval
  , animationDisposition
  , animationEffect
  , animationId
  , animationIdText
  , animationImportance
  , animationIsSlideTransition
  , animationSchedule
  , animationScheduledStep
  , animationTargetElement
  , animationTimelineAnimations
  , animationTiming
  , animationTracks
  , animationTrigger
  , animationsForStep
  , emptyAnimationTimeline
  , fillColorTrack
  , keyframeOffset
  , keyframeValue
  , milliseconds
  , millisecondsCount
  , mkAnimation
  , mkAnimationId
  , mkAnimationTimeline
  , mkAnimationTiming
  , mkAnimationTimingWithDirection
  , mkKeyframe
  , mkMotionPath
  , mkPositiveCount
  , mkUnitInterval
  , motionPathTrack
  , opacityTrack
  , positiveCountNumber
  , propertyTrackView
  , rotationTrack
  , sampleAnimation
  , samplePropertyTrack
  , scaleTrack
  , motionPathSegments
  , motionPathStart
  , strokeColorTrack
  , scheduleStart
  , scheduleStep
  , timingDelay
  , timingDirection
  , timingDuration
  , timingEasing
  , timingFill
  , timingRepeat
  , trackKeyframeCount
  , trackProperty
  , trackTarget
  , translationTrack
  , unitIntervalValue
  ) where

import SlideBlaster.Canvas
  ( ElementId
  , OverlayStep
  , firstOverlayStep
  )

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word8)
import Numeric.Natural (Natural)

-- | Stable animation identity within one frame timeline.
newtype AnimationId = AnimationId Text
  deriving stock (Eq, Ord, Show)

-- | Failure to construct a stable animation identity.
data AnimationIdError = AnimationIdEmpty
  deriving stock (Eq, Show)

-- | Construct a non-blank animation identity while preserving its spelling.
mkAnimationId :: Text -> Either AnimationIdError AnimationId
mkAnimationId value
  | Text.null (Text.strip value) = Left AnimationIdEmpty
  | otherwise = Right (AnimationId value)

-- | Return the stable animation identity text.
animationIdText :: AnimationId -> Text
animationIdText (AnimationId value) = value

-- | A target for one or more typed property tracks.
data AnimationTarget
  = SlideSurface
  | PictureElement !ElementId
  deriving stock (Eq, Ord, Show)

-- | Return an element target, or 'Nothing' for the whole slide surface.
animationTargetElement :: AnimationTarget -> Maybe ElementId
animationTargetElement target =
  case target of
    SlideSurface -> Nothing
    PictureElement element -> Just element

-- | Non-negative duration or delay in milliseconds.
newtype Milliseconds = Milliseconds Natural
  deriving stock (Eq, Ord, Show)

-- | Construct a millisecond quantity.
milliseconds :: Natural -> Milliseconds
milliseconds = Milliseconds

-- | Return a millisecond quantity as a natural number.
millisecondsCount :: Milliseconds -> Natural
millisecondsCount (Milliseconds value) = value

-- | A rational number in the closed interval @[0,1]@.
newtype UnitInterval = UnitInterval Rational
  deriving stock (Eq, Ord, Show)

-- | Validate a unit-interval value.
mkUnitInterval :: Rational -> Maybe UnitInterval
mkUnitInterval value
  | value < 0 = Nothing
  | value > 1 = Nothing
  | otherwise = Just (UnitInterval value)

-- | Return the rational unit-interval value.
unitIntervalValue :: UnitInterval -> Rational
unitIntervalValue (UnitInterval value) = value

-- | A strictly positive repeat or step count.
newtype PositiveCount = PositiveCount Natural
  deriving stock (Eq, Ord, Show)

-- | Validate a strictly positive count.
mkPositiveCount :: Natural -> Maybe PositiveCount
mkPositiveCount 0 = Nothing
mkPositiveCount value = Just (PositiveCount value)

-- | Return the natural count.
positiveCountNumber :: PositiveCount -> Natural
positiveCountNumber (PositiveCount value) = value

-- | The position at which a stepped easing function changes value.
data StepPosition = StepAtStart | StepAtEnd
  deriving stock (Eq, Ord, Show)

-- | A target-independent easing curve.
--
-- The x control points of 'CubicBezier' are unit intervals, which preserves
-- monotonic time. Its y control points may overshoot.
data Easing
  = Linear
  | Ease
  | EaseIn
  | EaseOut
  | EaseInOut
  | CubicBezier !UnitInterval !Rational !UnitInterval !Rational
  | Stepped !PositiveCount !StepPosition
  deriving stock (Eq, Show)

-- | Repetition of one animation after its initial playback.
data Repeat
  = PlayOnce
  | RepeatTimes !PositiveCount
  | RepeatForever
  deriving stock (Eq, Show)

-- | State retained outside the active interval.
data FillMode
  = NoFill
  | FillForwards
  | FillBackwards
  | FillBoth
  deriving stock (Eq, Ord, Show)

-- | Direction in which keyframes are traversed on each playback iteration.
--
-- Alternating directions are interpreted across repeats. This is retained as
-- authored animation meaning; a host must not silently assume forward play.
data PlaybackDirection
  = PlayForward
  | PlayReverse
  | PlayAlternate
  | PlayAlternateReverse
  deriving stock (Eq, Ord, Show)

-- | Validated timing shared by every property track in an animation.
data AnimationTiming = AnimationTiming
  { timingDelayValue :: !Milliseconds
  , timingDurationValue :: !Milliseconds
  , timingEasingValue :: !Easing
  , timingRepeatValue :: !Repeat
  , timingDirectionValue :: !PlaybackDirection
  , timingFillValue :: !FillMode
  }
  deriving stock (Eq, Show)

-- | Timing validation failure.
data TimingError = AnimationDurationMustBePositive
  deriving stock (Eq, Show)

-- | Construct animation timing. Delay may be zero; duration may not.
mkAnimationTiming
  :: Milliseconds
  -> Milliseconds
  -> Easing
  -> Repeat
  -> FillMode
  -> Either TimingError AnimationTiming
mkAnimationTiming delay duration easing repeatMode fillMode
  = mkAnimationTimingWithDirection
      delay
      duration
      easing
      repeatMode
      PlayForward
      fillMode

-- | Construct animation timing with an explicit playback direction. Delay may
-- be zero; duration may not.
mkAnimationTimingWithDirection
  :: Milliseconds
  -> Milliseconds
  -> Easing
  -> Repeat
  -> PlaybackDirection
  -> FillMode
  -> Either TimingError AnimationTiming
mkAnimationTimingWithDirection
  delay
  duration
  easing
  repeatMode
  direction
  fillMode
  | millisecondsCount duration == 0 = Left AnimationDurationMustBePositive
  | otherwise =
      Right
        AnimationTiming
          { timingDelayValue = delay
          , timingDurationValue = duration
          , timingEasingValue = easing
          , timingRepeatValue = repeatMode
          , timingDirectionValue = direction
          , timingFillValue = fillMode
          }

-- | Return the non-negative delay before active playback.
timingDelay :: AnimationTiming -> Milliseconds
timingDelay = timingDelayValue

-- | Return the positive active duration.
timingDuration :: AnimationTiming -> Milliseconds
timingDuration = timingDurationValue

-- | Return the target-independent easing curve.
timingEasing :: AnimationTiming -> Easing
timingEasing = timingEasingValue

-- | Return the playback repeat behavior.
timingRepeat :: AnimationTiming -> Repeat
timingRepeat = timingRepeatValue

-- | Return the authored playback direction.
timingDirection :: AnimationTiming -> PlaybackDirection
timingDirection = timingDirectionValue

-- | Return the state retained outside the active interval.
timingFill :: AnimationTiming -> FillMode
timingFill = timingFillValue

-- | A value at a normalized point in an animation's active duration.
data Keyframe value = Keyframe !UnitInterval !value
  deriving stock (Eq, Show)

-- | Construct one typed keyframe.
mkKeyframe :: UnitInterval -> value -> Keyframe value
mkKeyframe = Keyframe

-- | Return a keyframe's normalized offset.
keyframeOffset :: Keyframe value -> UnitInterval
keyframeOffset (Keyframe offset _) = offset

-- | Return a keyframe's typed value.
keyframeValue :: Keyframe value -> value
keyframeValue (Keyframe _ value) = value

-- | A two-dimensional scalar in slide coordinates.
data Scalar2 = Scalar2 !Rational !Rational
  deriving stock (Eq, Ord, Show)

-- | An RGBA color with eight-bit channels.
data Rgba = Rgba !Word8 !Word8 !Word8 !Word8
  deriving stock (Eq, Ord, Show)

-- | Closed property vocabulary understood by the shared model.
data PropertyKind
  = OpacityProperty
  | TranslationProperty
  | MotionPathProperty
  | RotationProperty
  | ScaleProperty
  | FillColorProperty
  | StrokeColorProperty
  deriving stock (Eq, Ord, Show)

-- | One target/property track with a statically matching value domain.
data PropertyTrack
  = OpacityPropertyTrack !AnimationTarget !(NonEmpty (Keyframe UnitInterval))
  | TranslationPropertyTrack !AnimationTarget !(NonEmpty (Keyframe Scalar2))
  | MotionPathPropertyTrack !AnimationTarget !MotionPath
  | RotationPropertyTrack !AnimationTarget !(NonEmpty (Keyframe Rational))
  | ScalePropertyTrack !AnimationTarget !(NonEmpty (Keyframe Scalar2))
  | FillColorPropertyTrack !AnimationTarget !(NonEmpty (Keyframe Rgba))
  | StrokeColorPropertyTrack !AnimationTarget !(NonEmpty (Keyframe Rgba))
  deriving stock (Eq, Show)

-- | Total public projection of a validated typed property track.
--
-- View constructors do not construct 'PropertyTrack'; adapters can inspect all
-- authored keyframes without bypassing track validation.
data PropertyTrackView
  = OpacityTrackView !AnimationTarget !(NonEmpty (Keyframe UnitInterval))
  | TranslationTrackView !AnimationTarget !(NonEmpty (Keyframe Scalar2))
  | MotionPathTrackView !AnimationTarget !MotionPath
  | RotationTrackView !AnimationTarget !(NonEmpty (Keyframe Rational))
  | ScaleTrackView !AnimationTarget !(NonEmpty (Keyframe Scalar2))
  | FillColorTrackView !AnimationTarget !(NonEmpty (Keyframe Rgba))
  | StrokeColorTrackView !AnimationTarget !(NonEmpty (Keyframe Rgba))
  deriving stock (Eq, Show)

-- | Property-track validation failure.
data TrackError
  = TrackNeedsAtLeastTwoKeyframes
  | TrackOffsetsMustIncrease
  deriving stock (Eq, Show)

-- | Construct a validated opacity track.
opacityTrack
  :: AnimationTarget
  -> NonEmpty (Keyframe UnitInterval)
  -> Either TrackError PropertyTrack
opacityTrack target frames =
  OpacityPropertyTrack target <$> validateKeyframes frames

-- | Construct a validated translation track.
translationTrack
  :: AnimationTarget
  -> NonEmpty (Keyframe Scalar2)
  -> Either TrackError PropertyTrack
translationTrack target frames =
  TranslationPropertyTrack target <$> validateKeyframes frames

-- | One segment after a motion path's explicit starting point.
data MotionPathSegment
  = LinePathTo !Scalar2
  | CubicPathTo !Scalar2 !Scalar2 !Scalar2
  deriving stock (Eq, Ord, Show)

-- | A non-empty geometric motion path in slide coordinates.
data MotionPath
  = MotionPath !Scalar2 !(NonEmpty MotionPathSegment)
  deriving stock (Eq, Show)

-- | Construct a motion path with an explicit start and one or more segments.
mkMotionPath :: Scalar2 -> NonEmpty MotionPathSegment -> MotionPath
mkMotionPath = MotionPath

-- | Return the explicit initial point of a motion path.
motionPathStart :: MotionPath -> Scalar2
motionPathStart (MotionPath start _) = start

-- | Return line/cubic segments in traversal order.
motionPathSegments :: MotionPath -> NonEmpty MotionPathSegment
motionPathSegments (MotionPath _ segments) = segments

-- | Construct a typed motion-path track.
motionPathTrack :: AnimationTarget -> MotionPath -> PropertyTrack
motionPathTrack = MotionPathPropertyTrack

-- | Construct a validated rotation track in rational degrees.
rotationTrack
  :: AnimationTarget
  -> NonEmpty (Keyframe Rational)
  -> Either TrackError PropertyTrack
rotationTrack target frames =
  RotationPropertyTrack target <$> validateKeyframes frames

-- | Construct a validated two-axis scale track.
scaleTrack
  :: AnimationTarget
  -> NonEmpty (Keyframe Scalar2)
  -> Either TrackError PropertyTrack
scaleTrack target frames =
  ScalePropertyTrack target <$> validateKeyframes frames

-- | Construct a validated fill-color track.
fillColorTrack
  :: AnimationTarget
  -> NonEmpty (Keyframe Rgba)
  -> Either TrackError PropertyTrack
fillColorTrack target frames =
  FillColorPropertyTrack target <$> validateKeyframes frames

-- | Construct a validated stroke-color track.
strokeColorTrack
  :: AnimationTarget
  -> NonEmpty (Keyframe Rgba)
  -> Either TrackError PropertyTrack
strokeColorTrack target frames =
  StrokeColorPropertyTrack target <$> validateKeyframes frames

-- | Return the target shared by every keyframe of a track.
trackTarget :: PropertyTrack -> AnimationTarget
trackTarget track =
  case track of
    OpacityPropertyTrack target _ -> target
    TranslationPropertyTrack target _ -> target
    MotionPathPropertyTrack target _ -> target
    RotationPropertyTrack target _ -> target
    ScalePropertyTrack target _ -> target
    FillColorPropertyTrack target _ -> target
    StrokeColorPropertyTrack target _ -> target

-- | Return the closed property kind of a track.
trackProperty :: PropertyTrack -> PropertyKind
trackProperty track =
  case track of
    OpacityPropertyTrack {} -> OpacityProperty
    TranslationPropertyTrack {} -> TranslationProperty
    MotionPathPropertyTrack {} -> MotionPathProperty
    RotationPropertyTrack {} -> RotationProperty
    ScalePropertyTrack {} -> ScaleProperty
    FillColorPropertyTrack {} -> FillColorProperty
    StrokeColorPropertyTrack {} -> StrokeColorProperty

-- | Inspect every value of a validated typed track.
propertyTrackView :: PropertyTrack -> PropertyTrackView
propertyTrackView track =
  case track of
    OpacityPropertyTrack target frames ->
      OpacityTrackView target frames
    TranslationPropertyTrack target frames ->
      TranslationTrackView target frames
    MotionPathPropertyTrack target path ->
      MotionPathTrackView target path
    RotationPropertyTrack target frames ->
      RotationTrackView target frames
    ScalePropertyTrack target frames ->
      ScaleTrackView target frames
    FillColorPropertyTrack target frames ->
      FillColorTrackView target frames
    StrokeColorPropertyTrack target frames ->
      StrokeColorTrackView target frames

-- | Return the number of keyframes in a track.
trackKeyframeCount :: PropertyTrack -> Int
trackKeyframeCount track =
  case track of
    OpacityPropertyTrack _ frames -> NonEmpty.length frames
    TranslationPropertyTrack _ frames -> NonEmpty.length frames
    MotionPathPropertyTrack _ (MotionPath _ segments) ->
      1 + NonEmpty.length segments
    RotationPropertyTrack _ frames -> NonEmpty.length frames
    ScalePropertyTrack _ frames -> NonEmpty.length frames
    FillColorPropertyTrack _ frames -> NonEmpty.length frames
    StrokeColorPropertyTrack _ frames -> NonEmpty.length frames

validateKeyframes
  :: NonEmpty (Keyframe value)
  -> Either TrackError (NonEmpty (Keyframe value))
validateKeyframes (_ :| []) = Left TrackNeedsAtLeastTwoKeyframes
validateKeyframes frames
  | offsetsStrictlyIncrease frames = Right frames
  | otherwise = Left TrackOffsetsMustIncrease

offsetsStrictlyIncrease :: NonEmpty (Keyframe value) -> Bool
offsetsStrictlyIncrease (firstFrame :| remaining) =
  go (keyframeOffset firstFrame) remaining
  where
    go :: UnitInterval -> [Keyframe value] -> Bool
    go _ [] = True
    go previous (current : rest) =
      previous < keyframeOffset current
        && go (keyframeOffset current) rest

-- | Coarse semantic purpose used for compatibility and accessibility policy.
data AnimationEffect
  = EntranceEffect
  | EmphasisEffect
  | ExitEffect
  | MotionEffect
  | TransitionEffect
  deriving stock (Eq, Ord, Show)

-- | Whether omitting motion loses necessary meaning.
data AnimationImportance = DecorativeMotion | EssentialMotion
  deriving stock (Eq, Ord, Show)

-- | A total trigger vocabulary that cannot add presenter clicks.
data AnimationTrigger
  = OnFrameEnter
  | OnOverlayStep !OverlayStep
  | OnTargetClick !OverlayStep !AnimationTarget
  | AtTimelineOffset !OverlayStep !Milliseconds
  | WithPrevious
  | AfterPrevious
  | WithAnimation !AnimationId
  | AfterAnimation !AnimationId
  deriving stock (Eq, Show)

-- | One classified animation with one or more typed tracks.
data Animation = Animation
  { animationIdValue :: !AnimationId
  , animationEffectValue :: !AnimationEffect
  , animationImportanceValue :: !AnimationImportance
  , animationTriggerValue :: !AnimationTrigger
  , animationTimingValue :: !AnimationTiming
  , animationTracksValue :: !(NonEmpty PropertyTrack)
  }
  deriving stock (Eq, Show)

-- | Animation construction failure.
data AnimationError
  = SlideTransitionMustTargetSlideSurface
  deriving stock (Eq, Show)

-- | Construct one animation. A slide transition is definitionally a
-- whole-surface effect; track and timing validation otherwise happens at their
-- own constructors, and dependency validation happens in
-- 'mkAnimationTimeline'.
mkAnimation
  :: AnimationId
  -> AnimationEffect
  -> AnimationImportance
  -> AnimationTrigger
  -> AnimationTiming
  -> NonEmpty PropertyTrack
  -> Either AnimationError Animation
mkAnimation identity effect importance trigger timing tracks =
  if effect == TransitionEffect
    && any ((/= SlideSurface) . trackTarget) tracks
    then Left SlideTransitionMustTargetSlideSurface
    else
      Right
        Animation
          { animationIdValue = identity
          , animationEffectValue = effect
          , animationImportanceValue = importance
          , animationTriggerValue = trigger
          , animationTimingValue = timing
          , animationTracksValue = tracks
          }

-- | Return an animation's stable identity.
animationId :: Animation -> AnimationId
animationId = animationIdValue

-- | Return an animation's semantic effect classification.
animationEffect :: Animation -> AnimationEffect
animationEffect = animationEffectValue

-- | Return whether an animation is necessary to preserve meaning.
animationImportance :: Animation -> AnimationImportance
animationImportance = animationImportanceValue

-- | Whether an animation is a validated whole-slide transition.
animationIsSlideTransition :: Animation -> Bool
animationIsSlideTransition animation =
  animationEffect animation == TransitionEffect

-- | Return the trigger that schedules an animation within an existing beat.
animationTrigger :: Animation -> AnimationTrigger
animationTrigger = animationTriggerValue

-- | Return validated timing.
animationTiming :: Animation -> AnimationTiming
animationTiming = animationTimingValue

-- | Return typed property tracks.
animationTracks :: Animation -> NonEmpty PropertyTrack
animationTracks = animationTracksValue

-- | A validated, source-ordered, cycle-free animation timeline.
newtype AnimationTimeline = AnimationTimeline [Animation]
  deriving stock (Eq, Show)

-- | Timeline construction failure.
data TimelineError
  = DuplicateAnimationId !AnimationId
  | TriggerNeedsPrevious !AnimationId
  | TriggerReferenceNotPrior !AnimationId !AnimationId
  deriving stock (Eq, Show)

-- | A timeline without timed animations.
emptyAnimationTimeline :: AnimationTimeline
emptyAnimationTimeline = AnimationTimeline []

-- | Validate stable identities and backward-only trigger dependencies.
mkAnimationTimeline
  :: [Animation]
  -> Either TimelineError AnimationTimeline
mkAnimationTimeline animations = do
  _ <- scheduleAnimations animations
  pure (AnimationTimeline animations)

-- | Return animations in authored timeline order.
animationTimelineAnimations :: AnimationTimeline -> [Animation]
animationTimelineAnimations (AnimationTimeline animations) = animations

-- | How a validated animation starts within its owning beat.
--
-- Relative triggers are resolved to a concrete prior animation identity. A
-- playback host therefore receives the authored with/after distinction and
-- never has to infer it from list position.
data AnimationStart
  = StartAtBeatEntry
  | StartOnTargetClick !AnimationTarget
  | StartAtTimelineOffset !Milliseconds
  | StartWithAnimation !AnimationId
  | StartAfterAnimation !AnimationId
  deriving stock (Eq, Show)

-- | Validated beat ownership and start relation for one animation.
data AnimationSchedule
  = AnimationSchedule !OverlayStep !AnimationStart
  deriving stock (Eq, Show)

-- | Return the existing overlay beat that owns this schedule.
scheduleStep :: AnimationSchedule -> OverlayStep
scheduleStep (AnimationSchedule step _) = step

-- | Return the explicit intra-beat start relation.
scheduleStart :: AnimationSchedule -> AnimationStart
scheduleStart (AnimationSchedule _ start) = start

-- | Return the validated schedule for an animation identity.
animationSchedule
  :: AnimationTimeline
  -> AnimationId
  -> Maybe AnimationSchedule
animationSchedule (AnimationTimeline animations) identity = do
  scheduled <- either (const Nothing) Just (scheduleAnimations animations)
  lookup
    identity
    [ (animationId animation, schedule)
    | (animation, schedule) <- scheduled
    ]

-- | Return the existing overlay beat on which an animation is scheduled.
animationScheduledStep
  :: AnimationTimeline
  -> AnimationId
  -> Maybe OverlayStep
animationScheduledStep timeline identity =
  scheduleStep <$> animationSchedule timeline identity

-- | Select animations scheduled for one existing overlay beat.
animationsForStep :: OverlayStep -> AnimationTimeline -> [Animation]
animationsForStep targetStep (AnimationTimeline animations) =
  case scheduleAnimations animations of
    Left _ -> []
    Right scheduled ->
      [ animation
      | (animation, schedule) <- scheduled
      , scheduleStep schedule == targetStep
      ]

scheduleAnimations
  :: [Animation]
  -> Either TimelineError [(Animation, AnimationSchedule)]
scheduleAnimations = go [] Nothing
  where
    go
      :: [(AnimationId, AnimationSchedule)]
      -> Maybe AnimationSchedule
      -> [Animation]
      -> Either TimelineError [(Animation, AnimationSchedule)]
    go _ _ [] = Right []
    go prior previousSchedule (animation : rest)
      | any ((== animationId animation) . fst) prior =
          Left (DuplicateAnimationId (animationId animation))
      | otherwise = do
          schedule <- resolveTrigger prior previousSchedule animation
          remaining <-
            go
              ((animationId animation, schedule) : prior)
              (Just schedule)
              rest
          pure ((animation, schedule) : remaining)

resolveTrigger
  :: [(AnimationId, AnimationSchedule)]
  -> Maybe AnimationSchedule
  -> Animation
  -> Either TimelineError AnimationSchedule
resolveTrigger prior previousSchedule animation =
  case animationTrigger animation of
    OnFrameEnter ->
      Right (AnimationSchedule firstOverlayStep StartAtBeatEntry)
    OnOverlayStep step ->
      Right (AnimationSchedule step StartAtBeatEntry)
    OnTargetClick step target ->
      Right (AnimationSchedule step (StartOnTargetClick target))
    AtTimelineOffset step offset ->
      Right (AnimationSchedule step (StartAtTimelineOffset offset))
    WithPrevious ->
      requirePrevious StartWithAnimation
    AfterPrevious ->
      requirePrevious StartAfterAnimation
    WithAnimation dependency ->
      requireDependency dependency StartWithAnimation
    AfterAnimation dependency ->
      requireDependency dependency StartAfterAnimation
  where
    requirePrevious relation =
      case previousSchedule of
        Nothing -> Left (TriggerNeedsPrevious (animationId animation))
        Just schedule ->
          case prior of
            [] -> Left (TriggerNeedsPrevious (animationId animation))
            (previousIdentity, _) : _ ->
              Right
                ( AnimationSchedule
                    (scheduleStep schedule)
                    (relation previousIdentity)
                )
    requireDependency dependency relation =
      case lookup dependency prior of
        Nothing ->
          Left
            ( TriggerReferenceNotPrior
                (animationId animation)
                dependency
            )
        Just schedule ->
          Right
            ( AnimationSchedule
                (scheduleStep schedule)
                (relation dependency)
            )

-- | Which deterministic endpoint a non-animated target should use.
data StaticSample = InitialSample | FinalSample
  deriving stock (Eq, Ord, Show)

-- | One statically sampled property value.
data SampledProperty
  = SampledOpacity !AnimationTarget !UnitInterval
  | SampledTranslation !AnimationTarget !Scalar2
  | SampledMotionPathPosition !AnimationTarget !Scalar2
  | SampledRotation !AnimationTarget !Rational
  | SampledScale !AnimationTarget !Scalar2
  | SampledFillColor !AnimationTarget !Rgba
  | SampledStrokeColor !AnimationTarget !Rgba
  deriving stock (Eq, Show)

-- | Sample every track of an animation at a deterministic endpoint.
sampleAnimation :: StaticSample -> Animation -> [SampledProperty]
sampleAnimation endpoint animation =
  samplePropertyTrack endpoint <$> NonEmpty.toList (animationTracks animation)

-- | Sample one typed property track at its initial or final endpoint.
samplePropertyTrack :: StaticSample -> PropertyTrack -> SampledProperty
samplePropertyTrack endpoint track =
  case track of
    OpacityPropertyTrack target frames ->
      SampledOpacity target (keyframeValue (sampleFrame endpoint frames))
    TranslationPropertyTrack target frames ->
      SampledTranslation target (keyframeValue (sampleFrame endpoint frames))
    MotionPathPropertyTrack target path ->
      SampledMotionPathPosition target (sampleMotionPath endpoint path)
    RotationPropertyTrack target frames ->
      SampledRotation target (keyframeValue (sampleFrame endpoint frames))
    ScalePropertyTrack target frames ->
      SampledScale target (keyframeValue (sampleFrame endpoint frames))
    FillColorPropertyTrack target frames ->
      SampledFillColor target (keyframeValue (sampleFrame endpoint frames))
    StrokeColorPropertyTrack target frames ->
      SampledStrokeColor target (keyframeValue (sampleFrame endpoint frames))

sampleFrame :: StaticSample -> NonEmpty (Keyframe value) -> Keyframe value
sampleFrame endpoint (firstFrame :| remaining) =
  case endpoint of
    InitialSample -> firstFrame
    FinalSample -> foldl (\_ current -> current) firstFrame remaining

sampleMotionPath :: StaticSample -> MotionPath -> Scalar2
sampleMotionPath endpoint (MotionPath start segments) =
  case endpoint of
    InitialSample -> start
    FinalSample ->
      foldl
        (\_ segment -> motionPathSegmentEnd segment)
        start
        (NonEmpty.toList segments)

motionPathSegmentEnd :: MotionPathSegment -> Scalar2
motionPathSegmentEnd segment =
  case segment of
    LinePathTo endpoint -> endpoint
    CubicPathTo _ _ endpoint -> endpoint

-- | Runtime preference obtained from the host.
data MotionPreference = FullMotion | ReducedMotion
  deriving stock (Eq, Ord, Show)

-- | Presentation policy applied when the host requests reduced motion.
data ReducedMotionPolicy
  = PreserveAuthoredMotion
  | CompleteImmediately
  | OmitDecorativeMotion
  deriving stock (Eq, Ord, Show)

-- | Host action after applying motion preference and policy.
data AnimationDisposition
  = PlayAnimation
  | ApplyFinalAnimationState
  | OmitAnimation
  deriving stock (Eq, Ord, Show)

-- | Resolve a pure, explicit reduced-motion disposition.
animationDisposition
  :: MotionPreference
  -> ReducedMotionPolicy
  -> Animation
  -> AnimationDisposition
animationDisposition preference policy animation =
  case preference of
    FullMotion -> PlayAnimation
    ReducedMotion ->
      case policy of
        PreserveAuthoredMotion -> PlayAnimation
        CompleteImmediately -> ApplyFinalAnimationState
        OmitDecorativeMotion ->
          case animationImportance animation of
            EssentialMotion -> ApplyFinalAnimationState
            DecorativeMotion -> OmitAnimation
