-- |
-- Module      : SlideBlaster.Presentation.Overlay
-- Description : Overlay build aggregation without source parsing or layout.
--
-- Canvas owns normalized visibility hooks and their source provenance. This
-- module only combines those hooks with reading-order pauses to derive a
-- positive audience step count. Sequences thread a local pause floor; parallel
-- branches share their starting floor and cannot change one another. Overlays
-- always retain union geometry and are deliberately distinct from timed
-- animations.
module SlideBlaster.Presentation.Overlay
  ( OverlayProgram
  , PauseTarget (..)
  , StepCount
  , emptyOverlayProgram
  , oneStep
  , overlayHookProgram
  , overlayParallel
  , overlayPause
  , overlayPauseAt
  , overlayProgramHooks
  , overlayProgramStepCount
  , overlaySequence
  , stepCountFinalStep
  , stepCountFromNatural
  , stepCountNumber
  ) where

import SlideBlaster.Canvas
  ( OverlayHook
  , OverlayStep
  , firstOverlayStep
  , mkOverlayStep
  , overlayFinalStep
  , overlayStepNumber
  )

import Numeric.Natural (Natural)

-- | A positive number of discrete overlay beats.
newtype StepCount = StepCount Natural
  deriving stock (Eq, Ord, Show)

-- | How a point pause changes the local reading-order floor.
data PauseTarget
  = -- | Advance one step beyond the current local floor.
    NextOverlayStep
  | -- | Set the local floor to an explicit, already-normalized step.
    OverlayStepTarget !OverlayStep
  deriving stock (Eq, Ord, Show)

-- | A normalized overlay aggregation tree.
--
-- Constructors stay private so callers state whether nested material is
-- sequential or parallel instead of depending on representation details.
data OverlayProgram
  = EmptyOverlayProgram
  | HookOverlayProgram !OverlayHook
  | PauseOverlayProgram !PauseTarget
  | SequenceOverlayProgram [OverlayProgram]
  | ParallelOverlayProgram [OverlayProgram]
  deriving stock (Eq, Show)

-- | The smallest valid step count.
oneStep :: StepCount
oneStep = StepCount 1

-- | Validate a positive step count.
stepCountFromNatural :: Natural -> Maybe StepCount
stepCountFromNatural 0 = Nothing
stepCountFromNatural value = Just (StepCount value)

-- | Return the positive numeric count.
stepCountNumber :: StepCount -> Natural
stepCountNumber (StepCount value) = value

-- | Return the final overlay step represented by a count.
stepCountFinalStep :: StepCount -> OverlayStep
stepCountFinalStep (StepCount value) =
  case mkOverlayStep value of
    Just step -> step
    Nothing -> firstOverlayStep

-- | A program with no overlay references or pauses.
emptyOverlayProgram :: OverlayProgram
emptyOverlayProgram = EmptyOverlayProgram

-- | Include one normalized canvas visibility hook in the build calculation.
overlayHookProgram :: OverlayHook -> OverlayProgram
overlayHookProgram = HookOverlayProgram

-- | Advance one step after the preceding material in this sequence.
overlayPause :: OverlayProgram
overlayPause = PauseOverlayProgram NextOverlayStep

-- | Set the following material's local floor to an explicit step.
overlayPauseAt :: OverlayStep -> OverlayProgram
overlayPauseAt = PauseOverlayProgram . OverlayStepTarget

-- | Compose material whose reading-order pause floors flow left-to-right.
overlaySequence :: [OverlayProgram] -> OverlayProgram
overlaySequence = SequenceOverlayProgram

-- | Compose independent scopes that begin at the same overlay floor.
overlayParallel :: [OverlayProgram] -> OverlayProgram
overlayParallel = ParallelOverlayProgram

-- | Return normalized visibility hooks in source reading order.
overlayProgramHooks :: OverlayProgram -> [OverlayHook]
overlayProgramHooks program =
  case program of
    EmptyOverlayProgram -> []
    HookOverlayProgram hook -> [hook]
    PauseOverlayProgram _ -> []
    SequenceOverlayProgram children -> children >>= overlayProgramHooks
    ParallelOverlayProgram children -> children >>= overlayProgramHooks

-- | Derive the audience-owned positive step count.
overlayProgramStepCount :: OverlayProgram -> StepCount
overlayProgramStepCount program =
  let Measurement maximumStep _ = measureFrom 1 program
   in StepCount maximumStep

-- | Maximum referenced step and resulting local floor.
data Measurement = Measurement !Natural !Natural

measureFrom :: Natural -> OverlayProgram -> Measurement
measureFrom floorStep program =
  case program of
    EmptyOverlayProgram -> Measurement floorStep floorStep
    HookOverlayProgram hook ->
      Measurement
        (max floorStep (overlayStepNumber (overlayFinalStep hook)))
        floorStep
    PauseOverlayProgram target ->
      let targetStep =
            case target of
              NextOverlayStep -> floorStep + 1
              OverlayStepTarget step -> overlayStepNumber step
       in Measurement (max floorStep targetStep) targetStep
    SequenceOverlayProgram children -> measureSequence floorStep children
    ParallelOverlayProgram children ->
      Measurement
        ( foldr
            (\child currentMaximum ->
              let Measurement childMaximum _ = measureFrom floorStep child
               in max childMaximum currentMaximum
            )
            floorStep
            children
        )
        floorStep

measureSequence :: Natural -> [OverlayProgram] -> Measurement
measureSequence initialFloor =
  go initialFloor initialFloor
  where
    go :: Natural -> Natural -> [OverlayProgram] -> Measurement
    go maximumStep floorStep remaining =
      case remaining of
        [] -> Measurement maximumStep floorStep
        child : rest ->
          let Measurement childMaximum childFloor = measureFrom floorStep child
           in go (max maximumStep childMaximum) childFloor rest
