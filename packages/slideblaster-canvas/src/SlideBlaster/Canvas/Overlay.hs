-- |
-- Module      : SlideBlaster.Canvas.Overlay
-- Description : Fixed-geometry overlay visibility hooks.
--
-- Overlay steps begin at one. Hooks answer visibility only; layout is always
-- measured over the maximal state, so changing a step never causes reflow.
module SlideBlaster.Canvas.Overlay
  ( OverlayStep
  , mkOverlayStep
  , firstOverlayStep
  , overlayStepNumber
  , StepRange
  , singleStep
  , stepsFrom
  , stepsThrough
  , stepsBetween
  , stepRangeStart
  , stepRangeEnd
  , OverlayHook (..)
  , overlayVisibleAt
  , overlayFinalStep
  ) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Numeric.Natural (Natural)

-- | A one-based audience build step.
newtype OverlayStep = OverlayStep Natural
  deriving stock (Eq, Ord, Show)

mkOverlayStep :: Natural -> Maybe OverlayStep
mkOverlayStep value
  | value == 0 = Nothing
  | otherwise = Just (OverlayStep value)

firstOverlayStep :: OverlayStep
firstOverlayStep = OverlayStep 1

overlayStepNumber :: OverlayStep -> Natural
overlayStepNumber (OverlayStep value) = value

-- | Inclusive step interval; a missing bound means open in that direction.
data StepRange = StepRange !(Maybe OverlayStep) !(Maybe OverlayStep)
  deriving stock (Eq, Ord, Show)

singleStep :: OverlayStep -> StepRange
singleStep step = StepRange (Just step) (Just step)

stepsFrom :: OverlayStep -> StepRange
stepsFrom step = StepRange (Just step) Nothing

stepsThrough :: OverlayStep -> StepRange
stepsThrough step = StepRange Nothing (Just step)

stepsBetween :: OverlayStep -> OverlayStep -> Maybe StepRange
stepsBetween start end
  | start <= end = Just (StepRange (Just start) (Just end))
  | otherwise = Nothing

stepRangeStart :: StepRange -> Maybe OverlayStep
stepRangeStart (StepRange start _) = start

stepRangeEnd :: StepRange -> Maybe OverlayStep
stepRangeEnd (StepRange _ end) = end

-- | Visibility rule attached to a node, connector, or nested content construct.
data OverlayHook
  = AlwaysVisible
  | VisibleDuring !(NonEmpty StepRange)
  deriving stock (Eq, Ord, Show)

overlayVisibleAt :: OverlayStep -> OverlayHook -> Bool
overlayVisibleAt _ AlwaysVisible = True
overlayVisibleAt step (VisibleDuring ranges) =
  any (rangeContains step) ranges

overlayFinalStep :: OverlayHook -> OverlayStep
overlayFinalStep AlwaysVisible = firstOverlayStep
overlayFinalStep (VisibleDuring (firstRange :| remainingRanges)) =
  foldl
    maximumStep
    (rangeFinalStep firstRange)
    (fmap rangeFinalStep remainingRanges)

rangeContains :: OverlayStep -> StepRange -> Bool
rangeContains step (StepRange start end) =
  maybe True (<= step) start && maybe True (step <=) end

rangeFinalStep :: StepRange -> OverlayStep
rangeFinalStep (StepRange _ (Just end)) = end
rangeFinalStep (StepRange (Just start) Nothing) = start
rangeFinalStep (StepRange Nothing Nothing) = firstOverlayStep

maximumStep :: OverlayStep -> OverlayStep -> OverlayStep
maximumStep left right
  | left >= right = left
  | otherwise = right
