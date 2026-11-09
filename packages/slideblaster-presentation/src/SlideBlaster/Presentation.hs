-- |
-- Module      : SlideBlaster.Presentation
-- Description : Public facade for pure presentation and presenter semantics.
--
-- This facade combines semantic deck data, normalized overlay aggregation,
-- target-neutral timed animations, and total presenter navigation. Canvas
-- pictures and element identities remain owned by "SlideBlaster.Canvas";
-- concrete source syntax, renderer plans, clocks, windows, and persistence stay
-- outside this package.
module SlideBlaster.Presentation
  ( module SlideBlaster.Presentation.Address
  , module SlideBlaster.Presentation.Animation
  , module SlideBlaster.Presentation.Model
  , module SlideBlaster.Presentation.Overlay
  , module SlideBlaster.Presentation.Presenter
  , module SlideBlaster.Presentation.Scene
  ) where

import SlideBlaster.Presentation.Address
import SlideBlaster.Presentation.Animation
import SlideBlaster.Presentation.Model
import SlideBlaster.Presentation.Overlay
import SlideBlaster.Presentation.Presenter
import SlideBlaster.Presentation.Scene
