-- |
-- Module      : SlideBlaster.Ports
-- Description : Public target-neutral runtime capability vocabulary.
--
-- Ports are small records consumed explicitly by the component that needs
-- them. They do not form a global effect environment and they contain no
-- platform implementation. Browser and native adapters interpret these exact
-- contracts without gaining presentation, layout, export-policy, or source
-- authority.
module SlideBlaster.Ports
  ( module SlideBlaster.Ports.Capability
  , module SlideBlaster.Ports.Clock
  , module SlideBlaster.Ports.Compile
  , module SlideBlaster.Ports.Export
  , module SlideBlaster.Ports.Git
  , module SlideBlaster.Ports.Log
  , module SlideBlaster.Ports.Measurement
  , module SlideBlaster.Ports.Presenter
  , module SlideBlaster.Ports.Workspace
  ) where

import SlideBlaster.Ports.Capability
import SlideBlaster.Ports.Clock
import SlideBlaster.Ports.Compile
import SlideBlaster.Ports.Export
import SlideBlaster.Ports.Git
import SlideBlaster.Ports.Log
import SlideBlaster.Ports.Measurement
import SlideBlaster.Ports.Presenter
import SlideBlaster.Ports.Workspace
