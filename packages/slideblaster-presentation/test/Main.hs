{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Executable laws for scene, presentation, and presenter semantics.
module Main (main) where

import SlideBlaster.Canvas
  ( BorderPort (Centre)
  , CanvasObject (CanvasNode)
  , Content
  , ContentNode (..)
  , Dialect (Markdown)
  , ElementId (NodeElement)
  , LayerEntry (ObjectEntry)
  , Node (..)
  , NodeAccessibility (AccessibleNode)
  , NodeId
  , OverlayDirective (..)
  , OverlayHook (VisibleDuring)
  , OverlayStep
  , OutlineRef (PrimitiveGeometry)
  , Picture
  , Placement (AbsolutePlacement)
  , PrimitiveOutline (RectangleOutline)
  , Provenance (CanvasProvenance)
  , content
  , defaultTheme
  , emptyNodePropertyPatch
  , emptyPicture
  , mkOverlayStep
  , mkPicture
  , nodeId
  , overlayStepNumber
  , point
  , singleStep
  , canvasUnit
  )
import SlideBlaster.Presentation
import SlideBlaster.Presentation.Route qualified as Route

import Control.Monad (unless)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Numeric.Natural (Natural)
import System.Exit (exitFailure)

main :: IO ()
main = do
  scenesDeriveOverlayAuthority
  scenesRejectForeignAnimationTargets
  presentationsAreNonEmptyAndUnambiguous
  notesCannotAddBeats
  navigationIsTotalAndOrdered
  viewsStaySynchronized
  animationTracksAndSchedulingAreTyped
  timedAnimationsCannotAddBeats
  stableAddressesDistinguishSurfaces
  metadataIsNormalized
  routesFollowTheChosenOrder

scenesDeriveOverlayAuthority :: IO ()
scenesDeriveOverlayAuthority = do
  let scene = requireScene sampleAudiencePicture emptyAnimationTimeline
      analysis = sceneAnalysis scene
      emptyAnalysis = sceneAnalysis emptyScene
  assertEqual
    "picture and content hooks derive the scene count"
    2
    (stepCountNumber (overlayProgramStepCount (sceneOverlayProgram analysis)))
  assertEqual
    "all picture/content hooks remain inspectable"
    2
    (length (overlayProgramHooks (sceneOverlayProgram analysis)))
  assertEqual
    "an empty picture cannot receive a fake overlay program"
    (1, 0)
    ( stepCountNumber
        (overlayProgramStepCount (sceneOverlayProgram emptyAnalysis))
    , length (overlayProgramHooks (sceneOverlayProgram emptyAnalysis))
    )

scenesRejectForeignAnimationTargets :: IO ()
scenesRejectForeignAnimationTargets = do
  let foreignElement = NodeElement (requireNodeId "foreign")
      elementTrack = sampleOpacityTrack (PictureElement foreignElement)
      targeted =
        requireAnimation
          "foreign-track"
          OnFrameEnter
          DecorativeMotion
          elementTrack
      targetedTimeline =
        requireRight
          "foreign target timeline"
          (mkAnimationTimeline [targeted])
  assertEqual
    "foreign property target is rejected by its scene"
    ( Left
        ( SceneAnimationTrackTargetMissing
            (animationId targeted)
            foreignElement
        )
    )
    (mkScene emptyPicture targetedTimeline)

  let clicked =
        requireAnimation
          "foreign-click"
          (OnTargetClick (requireStep 1) (PictureElement foreignElement))
          DecorativeMotion
          (sampleOpacityTrack SlideSurface)
      clickTimeline =
        requireRight "foreign click timeline" (mkAnimationTimeline [clicked])
  assertEqual
    "foreign click target is rejected by its scene"
    ( Left
        ( SceneAnimationClickTargetMissing
            (animationId clicked)
            foreignElement
        )
    )
    (mkScene emptyPicture clickTimeline)

  let localTarget = PictureElement sampleElementId
      local =
        requireAnimation
          "local"
          (OnTargetClick (requireStep 1) localTarget)
          DecorativeMotion
          (sampleOpacityTrack localTarget)
      localTimeline =
        requireRight "local target timeline" (mkAnimationTimeline [local])
  case mkScene sampleAudiencePicture localTimeline of
    Left problem ->
      failTest ("local animation target was rejected: " <> show problem)
    Right _ -> pure ()

presentationsAreNonEmptyAndUnambiguous :: IO ()
presentationsAreNonEmptyAndUnambiguous = do
  let frames = presentationFrames samplePresentation
      beats = flattenBeats samplePresentation
  assertEqual "semantic presentation has frames" 2 (NonEmpty.length frames)
  assertEqual "semantic presentation has beats" 3 (NonEmpty.length beats)
  assertEqual
    "duplicate stable frame identity is rejected"
    (Left (DuplicatePresentationFrameId (frameId introFrame)))
    (mkPresentation samplePresentationMetadata (introFrame :| [introFrame]))

notesCannotAddBeats :: IO ()
notesCannotAddBeats = do
  let beats = NonEmpty.toList (flattenBeats samplePresentation)
  assertEqual "audience-capped total beat count" 3 (length beats)
  assertEqual
    "flattened frame/step reading order"
    [("intro", 1), ("intro", 2), ("end", 1)]
    (beatKey <$> beats)
  assertEqual
    "notes exist on both audience beats"
    [True, True, False]
    (hasNotes <$> beats)
  assertEqual
    "notes step five cannot appear"
    False
    (any ((== 5) . overlayStepNumber . beatStep) beats)
  where
    hasNotes :: Beat -> Bool
    hasNotes = maybe False (const True) . beatNotesPicture

navigationIsTotalAndOrdered :: IO ()
navigationIsTotalAndOrdered = do
  let state0 =
        startPresenter
          (timerOriginFromMilliseconds 4242)
          samplePresentation
      state1 = nextBeat state0
      state2 = nextBeat state1
      state3 = nextBeat state2
  assertEqual "starts at first beat" ("intro", 1) (stateKey state0)
  assertEqual "next stays within slide first" ("intro", 2) (stateKey state1)
  assertEqual "next rolls to following slide" ("end", 1) (stateKey state2)
  assertEqual "next clamps at end" ("end", 1) (stateKey state3)
  assertEqual "back reverses one beat" ("intro", 2) (stateKey (backBeat state2))
  assertEqual "home selects first beat" ("intro", 1) (stateKey (homeBeat state2))
  assertEqual "end selects final beat" ("end", 1) (stateKey (endBeat state0))
  assertEqual
    "back clamps at home"
    ("intro", 1)
    (stateKey (backBeat state0))

viewsStaySynchronized :: IO ()
viewsStaySynchronized = do
  let state =
        startPresenter
          (timerOriginFromMilliseconds 4242)
          samplePresentation
      views = projectPresenterViews state
      audience = viewsAudience views
      console = viewsConsole views
  assertEqual
    "audience and console share current beat"
    (beatKey (audienceBeat audience))
    (beatKey (consoleCurrentBeat console))
  assertEqual "console has current notes" True (hasPicture (consoleNotesPicture console))
  assertEqual
    "console previews next beat"
    (Just ("intro", 2))
    (beatKey <$> consoleNextBeat console)
  assertEqual "console slide number" 1 (consoleSlideNumber console)
  assertEqual "console slide count" 2 (consoleSlideCount console)
  assertEqual "console step number" 1 (consoleStepNumber console)
  assertEqual "console step count" 2 (consoleStepCount console)
  assertEqual
    "timer origin remains host supplied"
    4242
    (timerOriginMilliseconds (consoleTimerOrigin console))
  where
    hasPicture :: Maybe picture -> Bool
    hasPicture = maybe False (const True)

animationTracksAndSchedulingAreTyped :: IO ()
animationTracksAndSchedulingAreTyped = do
  let zero = requireUnitInterval 0
      half = requireUnitInterval (1 / 2)
      one = requireUnitInterval 1
      validFrames =
        mkKeyframe zero zero
          :| [mkKeyframe half half, mkKeyframe one one]
      reversedFrames =
        mkKeyframe one one
          :| [mkKeyframe zero zero]
      singleFrame = mkKeyframe zero zero :| []
      track =
        requireRight
          "valid opacity track"
          (opacityTrack SlideSurface validFrames)
  assertEqual "typed property kind" OpacityProperty (trackProperty track)
  assertEqual "typed keyframe count" 3 (trackKeyframeCount track)
  case propertyTrackView track of
    OpacityTrackView SlideSurface projectedFrames ->
      assertEqual
        "track view exposes validated frames"
        3
        (length projectedFrames)
    other -> failTest ("unexpected opacity track view: " <> show other)
  assertEqual
    "static final sample"
    (SampledOpacity SlideSurface one)
    (samplePropertyTrack FinalSample track)
  assertEqual
    "reversed offsets rejected"
    (Left TrackOffsetsMustIncrease)
    (opacityTrack SlideSurface reversedFrames)
  assertEqual
    "single keyframe rejected"
    (Left TrackNeedsAtLeastTwoKeyframes)
    (opacityTrack SlideSurface singleFrame)

  let path =
        mkMotionPath
          (Scalar2 0 0)
          ( LinePathTo (Scalar2 2 1)
              :| [ CubicPathTo
                    (Scalar2 3 1)
                    (Scalar2 4 2)
                    (Scalar2 5 3)
                 ]
          )
      pathTrack = motionPathTrack SlideSurface path
  assertEqual
    "motion path final position"
    (SampledMotionPathPosition SlideSurface (Scalar2 5 3))
    (samplePropertyTrack FinalSample pathTrack)

  let timeline = scheduleTaxonomyTimeline
      step2 = requireStep 2
      scheduled = animationIdText . animationId <$> animationsForStep step2 timeline
  assertEqual
    "click offset with and after triggers share their explicit beat"
    ["click", "with", "after", "offset"]
    scheduled
  assertEqual
    "with previous resolves to an exact dependency"
    (Just (StartWithAnimation (requireAnimationId "click")))
    ( scheduleStart
        <$> animationSchedule timeline (requireAnimationId "with")
    )
  assertEqual
    "after identity preserves after rather than with"
    (Just (StartAfterAnimation (requireAnimationId "click")))
    ( scheduleStart
        <$> animationSchedule timeline (requireAnimationId "after")
    )
  assertEqual
    "click target remains explicit"
    (Just (StartOnTargetClick SlideSurface))
    ( scheduleStart
        <$> animationSchedule timeline (requireAnimationId "click")
    )
  assertEqual
    "timeline offset remains explicit"
    (Just (StartAtTimelineOffset (milliseconds 125)))
    ( scheduleStart
        <$> animationSchedule timeline (requireAnimationId "offset")
    )

  let fade = requireAnimation "duplicate" OnFrameEnter DecorativeMotion track
  assertEqual
    "duplicate animation identity rejected"
    (Left (DuplicateAnimationId (animationId fade)))
    (mkAnimationTimeline [fade, fade])
  let forward =
        requireAnimation
          "forward"
          (AfterAnimation (requireAnimationId "missing"))
          DecorativeMotion
          track
  assertEqual
    "forward dependency rejected"
    ( Left
        ( TriggerReferenceNotPrior
            (animationId forward)
            (requireAnimationId "missing")
        )
    )
    (mkAnimationTimeline [forward])

  assertEqual
    "explicit reverse-alternate playback is retained"
    PlayAlternateReverse
    (timingDirection sampleDirectedTiming)
  assertEqual
    "compatibility timing defaults to forward"
    PlayForward
    (timingDirection sampleTiming)
  assertEqual
    "decorative motion can be omitted"
    OmitAnimation
    ( animationDisposition
        ReducedMotion
        OmitDecorativeMotion
        fade
    )
  let essential =
        requireAnimation "essential" OnFrameEnter EssentialMotion track
  assertEqual
    "essential meaning resolves to final state"
    ApplyFinalAnimationState
    ( animationDisposition
        ReducedMotion
        OmitDecorativeMotion
        essential
    )

  let elementTarget = PictureElement sampleElementId
      elementTrack =
        requireRight
          "valid element opacity"
          (opacityTrack elementTarget validFrames)
  assertEqual
    "slide transitions reject element targets"
    (Left SlideTransitionMustTargetSlideSurface)
    ( mkAnimation
        (requireAnimationId "bad-transition")
        TransitionEffect
        EssentialMotion
        OnFrameEnter
        sampleTiming
        (elementTrack :| [])
    )
  let transition =
        requireRight
          "valid slide transition"
          ( mkAnimation
              (requireAnimationId "transition")
              TransitionEffect
              EssentialMotion
              OnFrameEnter
              sampleTiming
              (track :| [])
          )
  assertEqual "transition classification" True (animationIsSlideTransition transition)

timedAnimationsCannotAddBeats :: IO ()
timedAnimationsCannotAddBeats = do
  let beats = NonEmpty.toList (flattenBeats samplePresentation)
  assertEqual "animations do not change beat total" 3 (length beats)
  assertEqual
    "audience animation runs only on existing step two"
    [[], ["fade", "echo"], []]
    (fmap (fmap (animationIdText . animationId) . beatAnimations) beats)
  assertEqual
    "notes animation beyond audience cap never runs"
    [[], [], []]
    (fmap (fmap (animationIdText . animationId) . beatNotesAnimations) beats)

stableAddressesDistinguishSurfaces :: IO ()
stableAddressesDistinguishSurfaces = do
  let frame = requireFrameId "intro"
      audience = surfaceAddress frame AudienceSurface
      notes = surfaceAddress frame NotesSurface
      audienceElement = elementAddress audience sampleElementId
      notesElement = elementAddress notes sampleElementId
  assertEqual "surface frame identity" frame (surfaceAddressFrame audience)
  assertEqual "audience kind" AudienceSurface (surfaceAddressKind audience)
  assertEqual "notes kind" NotesSurface (surfaceAddressKind notes)
  assertNotEqual "surface kind is part of address" audience notes
  assertNotEqual "element address includes surface" audienceElement notesElement
  assertEqual
    "element identity survives addressing"
    sampleElementId
    (elementAddressElement audienceElement)

metadataIsNormalized :: IO ()
metadataIsNormalized = do
  let ratio = requireRight "positive aspect" (mkAspectRatio 32 18)
      rotation = slideRotationFromDegrees (-90)
  assertEqual "aspect width is reduced" 16 (aspectRatioWidth ratio)
  assertEqual "aspect height is reduced" 9 (aspectRatioHeight ratio)
  assertEqual "rotation is normalized" 270 (slideRotationDegrees rotation)
  assertEqual
    "zero width rejected"
    (Left AspectRatioWidthIsZero)
    (mkAspectRatio 0 9)
  assertEqual
    "zero height rejected"
    (Left AspectRatioHeightIsZero)
    (mkAspectRatio 16 0)

samplePresentation :: Presentation
samplePresentation =
  requireRight
    "sample presentation"
    ( mkPresentation
        samplePresentationMetadata
        (introFrame :| [endFrame])
    )

samplePresentationMetadata :: PresentationMetadata
samplePresentationMetadata =
  mkPresentationMetadata
    "Demo"
    defaultAspectRatio
    defaultTheme
    OmitDecorativeMotion

introFrame :: Frame
introFrame =
  let audience =
        requireScene sampleAudiencePicture sampleAudienceTimeline
      notes =
        mkNotes
          (requireScene sampleNotesPicture sampleNotesTimeline)
   in mkFrame
        (requireFrameId "intro")
        (mkFrameMetadata "Intro" noSlideRotation)
        audience
        (Just notes)

endFrame :: Frame
endFrame =
  mkFrame
    (requireFrameId "end")
    (mkFrameMetadata "End" noSlideRotation)
    emptyScene
    Nothing

sampleAudiencePicture :: Picture
sampleAudiencePicture =
  pictureWithContent
    "sample-node"
    ( content
        [ OverlayContent
            (VisibleDuring (singleStep (requireStep 2) :| []))
            [TextRun (CanvasProvenance Markdown) "revealed"]
        , OverlayPauseContent
            (CanvasProvenance Markdown)
            PauseNext
        ]
    )

sampleNotesPicture :: Picture
sampleNotesPicture =
  pictureWithContent
    "notes-node"
    ( content
        [ TextRun (CanvasProvenance Markdown) "speaker notes"
        , OverlayPauseContent
            (CanvasProvenance Markdown)
            (PauseAt (requireStep 5))
        ]
    )

pictureWithContent :: Text -> Content -> Picture
pictureWithContent identity body =
  requireRight
    "sample picture"
    ( mkPicture
        [ ObjectEntry
            ( CanvasNode
                Node
                  { nodeIdentifier = requireNodeId identity
                  , nodePlacement =
                      AbsolutePlacement
                        (point (canvasUnit 0) (canvasUnit 0))
                        Centre
                  , nodeOutline = PrimitiveGeometry RectangleOutline
                  , nodeContent = body
                  , nodePropertyOverrides = emptyNodePropertyPatch
                  , nodeAnimationRefs = []
                  , nodeAccessibility =
                      AccessibleNode "sample content" Nothing
                  }
            )
        ]
    )

sampleAudienceTimeline :: AnimationTimeline
sampleAudienceTimeline =
  let track = sampleOpacityTrack SlideSurface
      fade =
        requireAnimation
          "fade"
          (OnOverlayStep (requireStep 2))
          DecorativeMotion
          track
      echo =
        requireAnimation
          "echo"
          AfterPrevious
          DecorativeMotion
          track
   in requireRight "audience timeline" (mkAnimationTimeline [fade, echo])

sampleNotesTimeline :: AnimationTimeline
sampleNotesTimeline =
  let track = sampleOpacityTrack SlideSurface
      late =
        requireAnimation
          "late-note"
          (OnOverlayStep (requireStep 5))
          DecorativeMotion
          track
   in requireRight "notes timeline" (mkAnimationTimeline [late])

scheduleTaxonomyTimeline :: AnimationTimeline
scheduleTaxonomyTimeline =
  let track = sampleOpacityTrack SlideSurface
      click =
        requireAnimation
          "click"
          (OnTargetClick (requireStep 2) SlideSurface)
          DecorativeMotion
          track
      with =
        requireAnimation
          "with"
          WithPrevious
          DecorativeMotion
          track
      after =
        requireAnimation
          "after"
          (AfterAnimation (animationId click))
          DecorativeMotion
          track
      offset =
        requireAnimation
          "offset"
          (AtTimelineOffset (requireStep 2) (milliseconds 125))
          DecorativeMotion
          track
   in requireRight
        "schedule taxonomy timeline"
        (mkAnimationTimeline [click, with, after, offset])

sampleOpacityTrack :: AnimationTarget -> PropertyTrack
sampleOpacityTrack target =
  let zero = requireUnitInterval 0
      one = requireUnitInterval 1
   in requireRight
        "sample opacity track"
        ( opacityTrack
            target
            (mkKeyframe zero zero :| [mkKeyframe one one])
        )

sampleTiming :: AnimationTiming
sampleTiming =
  requireRight
    "sample timing"
    ( mkAnimationTiming
        (milliseconds 0)
        (milliseconds 250)
        EaseOut
        PlayOnce
        FillBoth
    )

sampleDirectedTiming :: AnimationTiming
sampleDirectedTiming =
  requireRight
    "sample directed timing"
    ( mkAnimationTimingWithDirection
        (milliseconds 0)
        (milliseconds 250)
        EaseOut
        PlayOnce
        PlayAlternateReverse
        FillBoth
    )

requireAnimation
  :: Text
  -> AnimationTrigger
  -> AnimationImportance
  -> PropertyTrack
  -> Animation
requireAnimation identity trigger importance track =
  requireRight
    "sample animation"
    ( mkAnimation
        (requireAnimationId identity)
        EmphasisEffect
        importance
        trigger
        sampleTiming
        (track :| [])
    )

sampleElementId :: ElementId
sampleElementId = NodeElement (requireNodeId "sample-node")

stateKey :: PresenterState -> (Text, Natural)
stateKey = beatKey . presenterCurrentBeat

beatKey :: Beat -> (Text, Natural)
beatKey beat =
  ( frameIdText (beatFrameId beat)
  , overlayStepNumber (beatStep beat)
  )

requireScene :: Picture -> AnimationTimeline -> Scene
requireScene picture timeline =
  requireRight "valid scene" (mkScene picture timeline)

requireStep :: Natural -> OverlayStep
requireStep value =
  requireJust "positive overlay step" (mkOverlayStep value)

requireFrameId :: Text -> FrameId
requireFrameId value =
  requireRight "non-blank frame identity" (mkFrameId value)

requireNodeId :: Text -> NodeId
requireNodeId value =
  requireJust "non-blank node identity" (nodeId value)

requireAnimationId :: Text -> AnimationId
requireAnimationId value =
  requireRight "non-blank animation identity" (mkAnimationId value)

requireUnitInterval :: Rational -> UnitInterval
requireUnitInterval value =
  requireJust "unit interval" (mkUnitInterval value)

requireRight :: Show problem => String -> Either problem value -> value
requireRight label result =
  case result of
    Left problem -> error (label <> ": " <> show problem)
    Right value -> value

requireJust :: String -> Maybe value -> value
requireJust label result =
  case result of
    Nothing -> error label
    Just value -> value

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $
    failTest (label <> ": expected " <> show expected <> ", got " <> show actual)

assertNotEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertNotEqual label left right =
  unless (left /= right) $
    failTest (label <> ": expected distinct values, both were " <> show left)

failTest :: String -> IO value
failTest message = do
  putStrLn ("FAIL: " <> message)
  exitFailure

routeDeck :: Route.Routes
routeDeck =
  Route.mkRoutes
    ["title", "intro", "pick", "a1", "a2", "b1", "c1"]
    [Route.Section "a" "Part A" ["a1", "a2"], Route.Section "b" "Part B" ["b1"], Route.Section "c" "Part C" ["c1"]]
    [("ab", ["a", "b"]), ("ba", ["b", "a"])]

routesFollowTheChosenOrder :: IO ()
routesFollowTheChosenOrder = do
  assertEqual "lead is frames before any section" ["title", "intro", "pick"] (Route.routesLead routeDeck)
  assertEqual "first route is the default" (Just "ab") (Route.defaultRoute routeDeck)
  assertEqual "default order" ["title", "intro", "pick", "a1", "a2", "b1"] (Route.routeFrames routeDeck Nothing)
  assertEqual "chosen order" ["title", "intro", "pick", "b1", "a1", "a2"] (Route.routeFrames routeDeck (Just "ba"))
  assertEqual "unknown route falls back to default" (Route.routeFrames routeDeck Nothing) (Route.routeFrames routeDeck (Just "nope"))
  assertEqual "no routes: file order" ["title", "intro", "pick", "a1", "a2", "b1", "c1"] (Route.routeFrames (Route.mkRoutes ["title", "intro", "pick", "a1", "a2", "b1", "c1"] (Route.routesSections routeDeck) []) Nothing)
  assertEqual "after the choice follows the chosen route" (Just "b1") (Route.frameAfterChoice routeDeck "ba" "pick")
  assertEqual "after the last frame there is none" Nothing (Route.frameAfterChoice routeDeck "ab" "b1")
  let at route frame = fmap (\p -> (Route.positionPage p, Route.positionPages p, Route.positionSectionPage p, Route.positionSectionPages p)) (Route.position routeDeck route frame)
  assertEqual "page follows the route" (Just (4, 6, 1, 1)) (at (Just "ba") "b1")
  assertEqual "section page" (Just (6, 6, 2, 2)) (at (Just "ba") "a2")
  assertEqual "frame outside the route" Nothing (at Nothing "c1")
  assertEqual
    "validation"
    [Route.DuplicateRoute "x", Route.UnknownSection "x" "zz", Route.DuplicateEntry "x" "a", Route.MissingSection "x" "b", Route.MissingSection "x" "c"]
    (Route.validateRoutes ["a", "b", "c"] [("x", ["a", "zz", "a"]), ("x", ["a", "b", "c"])])
  assertEqual "print order: default order, omitted section last" ["title", "intro", "pick", "a1", "a2", "b1", "c1"] (Route.exportOrder routeDeck)
  assertEqual "continue lines" [("ab", "b")] [(n, Route.sectionId s) | (n, s) <- Route.continuations routeDeck (Route.Section "a" "Part A" ["a1", "a2"])]
  assertEqual "routes that end at a section are omitted" [("ba", "a")] [(n, Route.sectionId s) | (n, s) <- Route.continuations routeDeck (Route.Section "b" "Part B" ["b1"])]
