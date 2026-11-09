-- |
-- Module      : SlideBlaster.Ports.Clock
-- Description : Monotonic presenter timer origin capability.
--
-- Wall-clock time is not semantic presentation state. The port supplies only
-- the authoritative presentation package's monotonic timer-origin value.
module SlideBlaster.Ports.Clock
  ( TimerOrigin
  , timerOriginFromMilliseconds
  , timerOriginMilliseconds
  , ClockPort (..)
  , ClockPortError (..)
  ) where

import SlideBlaster.Ports.Capability (RuntimeFailure)
import SlideBlaster.Presentation
  ( TimerOrigin
  , timerOriginFromMilliseconds
  , timerOriginMilliseconds
  )

data ClockPortError
  = ClockRuntimeFailure !RuntimeFailure
  deriving stock (Eq, Show)

data ClockPort m = ClockPort
  { readTimerOrigin :: m (Either ClockPortError TimerOrigin)
  }
