-- |
-- Module      : SlideBlaster.Canvas
-- Description : Public facade for target-neutral canvas authoring semantics.
--
-- The facade exposes authored pictures, mixed content, themes, generic outline
-- geometry, connector paths, pure property resolution, pure drag snapping, and
-- typed edit intents. Palette presets, catalog search, imported stencil data,
-- and attribution live in @slideblaster-catalog@. This facade deliberately
-- exposes no browser DOM or target render plan.
module SlideBlaster.Canvas
  ( module SlideBlaster.Canvas.Connector
  , module SlideBlaster.Canvas.Content
  , module SlideBlaster.Canvas.Edit
  , module SlideBlaster.Canvas.Geometry
  , module SlideBlaster.Canvas.Identifier
  , module SlideBlaster.Canvas.Object
  , module SlideBlaster.Canvas.Outline
  , module SlideBlaster.Canvas.Overlay
  , module SlideBlaster.Canvas.Placement
  , module SlideBlaster.Canvas.Property
  , module SlideBlaster.Canvas.Snap
  , module SlideBlaster.Canvas.Theme
  ) where

import SlideBlaster.Canvas.Connector
import SlideBlaster.Canvas.Content
import SlideBlaster.Canvas.Edit
import SlideBlaster.Canvas.Geometry
import SlideBlaster.Canvas.Identifier
import SlideBlaster.Canvas.Object
import SlideBlaster.Canvas.Outline
import SlideBlaster.Canvas.Overlay
import SlideBlaster.Canvas.Placement
import SlideBlaster.Canvas.Property
import SlideBlaster.Canvas.Snap
import SlideBlaster.Canvas.Theme
