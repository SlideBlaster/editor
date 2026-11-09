-- |
-- Module      : SlideBlaster.Presentation.Presenter
-- Description : Total beat navigation and synchronized presenter projections.
--
-- Presenter state is a zipper over the audience-capped beat list. Navigation
-- clamps at either end and never constructs a new overlay or animation step.
-- Audience and console views are projected together from one cursor, so notes,
-- next-beat preview, counters, and the host-supplied timer origin cannot drift.
module SlideBlaster.Presentation.Presenter
  ( AudienceView
  , PresenterConsoleView
  , PresenterState
  , PresenterViews
  , TimerOrigin
  , audienceBeat
  , backBeat
  , consoleCurrentBeat
  , consoleNextBeat
  , consoleNotesPicture
  , consoleSlideCount
  , consoleSlideNumber
  , consoleStepCount
  , consoleStepNumber
  , consoleTimerOrigin
  , endBeat
  , homeBeat
  , nextBeat
  , presenterCurrentBeat
  , projectPresenterViews
  , startPresenter
  , timerOriginFromMilliseconds
  , timerOriginMilliseconds
  , viewsAudience
  , viewsConsole
  ) where

import SlideBlaster.Canvas
  ( Picture
  , overlayStepNumber
  )
import SlideBlaster.Presentation.Model
  ( Beat
  , Presentation
  , beatFrameCount
  , beatFrameNumber
  , beatNotesPicture
  , beatStep
  , beatStepCount
  , flattenBeats
  )
import SlideBlaster.Presentation.Overlay
  ( stepCountNumber
  )

import Data.List.NonEmpty (NonEmpty ((:|)))
import Numeric.Natural (Natural)

-- | Host-supplied monotonic timer origin in milliseconds.
newtype TimerOrigin = TimerOrigin Natural
  deriving stock (Eq, Ord, Show)

-- | Construct a stable host timer origin.
timerOriginFromMilliseconds :: Natural -> TimerOrigin
timerOriginFromMilliseconds = TimerOrigin

-- | Return the host timer origin in milliseconds.
timerOriginMilliseconds :: TimerOrigin -> Natural
timerOriginMilliseconds (TimerOrigin value) = value

-- | A non-empty zipper over the presentation's flattened beat list.
data PresenterState
  = PresenterState
      [Beat]
      !Beat
      [Beat]
      !TimerOrigin

-- | Start at the first audience beat. This is total because a semantic
-- 'Presentation' is non-empty and every frame has at least one overlay beat.
startPresenter
  :: TimerOrigin
  -> Presentation
  -> PresenterState
startPresenter origin presentation =
  case flattenBeats presentation of
    first :| remaining ->
      PresenterState [] first remaining origin

-- | Return the beat selected by the single shared cursor.
presenterCurrentBeat :: PresenterState -> Beat
presenterCurrentBeat (PresenterState _ current _ _) = current

-- | Advance one beat, clamping at the final beat.
nextBeat :: PresenterState -> PresenterState
nextBeat state@(PresenterState before current after origin) =
  case after of
    [] -> state
    following : rest ->
      PresenterState (current : before) following rest origin

-- | Move back one beat, clamping at the first beat.
backBeat :: PresenterState -> PresenterState
backBeat state@(PresenterState before current after origin) =
  case before of
    [] -> state
    preceding : rest ->
      PresenterState rest preceding (current : after) origin

-- | Jump to the first beat.
homeBeat :: PresenterState -> PresenterState
homeBeat state@(PresenterState before current after origin) =
  case reverse before of
    [] -> state
    first : remaining ->
      PresenterState [] first (remaining <> (current : after)) origin

-- | Jump to the final beat.
endBeat :: PresenterState -> PresenterState
endBeat state@(PresenterState _ _ after _) =
  case after of
    [] -> state
    _ -> endBeat (nextBeat state)

-- | Audience projection for the selected beat.
newtype AudienceView = AudienceView Beat

-- | Presenter-only projection synchronized to one audience beat.
data PresenterConsoleView
  = PresenterConsoleView
      !Beat
      !(Maybe Beat)
      !TimerOrigin

-- | Audience and console projections created atomically from one state.
data PresenterViews
  = PresenterViews
      !AudienceView
      !PresenterConsoleView

-- | Project both surfaces from the same presenter cursor.
projectPresenterViews :: PresenterState -> PresenterViews
projectPresenterViews
  (PresenterState _ current after origin) =
    let following =
          case after of
            [] -> Nothing
            next : _ -> Just next
     in PresenterViews
          (AudienceView current)
          (PresenterConsoleView current following origin)

-- | Return the beat rendered by the audience surface.
audienceBeat :: AudienceView -> Beat
audienceBeat (AudienceView beat) = beat

-- | Return the current beat mirrored by the presenter console.
consoleCurrentBeat :: PresenterConsoleView -> Beat
consoleCurrentBeat (PresenterConsoleView current _ _) = current

-- | Return the full notes picture at the same current overlay step.
consoleNotesPicture :: PresenterConsoleView -> Maybe Picture
consoleNotesPicture = beatNotesPicture . consoleCurrentBeat

-- | Return the next audience beat preview, if any.
consoleNextBeat :: PresenterConsoleView -> Maybe Beat
consoleNextBeat (PresenterConsoleView _ following _) = following

-- | Return the current one-based slide number.
consoleSlideNumber :: PresenterConsoleView -> Natural
consoleSlideNumber = beatFrameNumber . consoleCurrentBeat

-- | Return the number of slides.
consoleSlideCount :: PresenterConsoleView -> Natural
consoleSlideCount = beatFrameCount . consoleCurrentBeat

-- | Return the current one-based step number.
consoleStepNumber :: PresenterConsoleView -> Natural
consoleStepNumber =
  overlayStepNumber . beatStep . consoleCurrentBeat

-- | Return the current slide's audience-owned step count.
consoleStepCount :: PresenterConsoleView -> Natural
consoleStepCount =
  stepCountNumber . beatStepCount . consoleCurrentBeat

-- | Return the unchanged host-supplied timer origin.
consoleTimerOrigin :: PresenterConsoleView -> TimerOrigin
consoleTimerOrigin (PresenterConsoleView _ _ origin) = origin

-- | Return the audience half of a synchronized projection.
viewsAudience :: PresenterViews -> AudienceView
viewsAudience (PresenterViews audience _) = audience

-- | Return the presenter-console half of a synchronized projection.
viewsConsole :: PresenterViews -> PresenterConsoleView
viewsConsole (PresenterViews _ console) = console
