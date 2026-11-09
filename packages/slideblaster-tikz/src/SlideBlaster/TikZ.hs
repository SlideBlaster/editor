-- |
-- Module      : SlideBlaster.TikZ
-- Description : Public facade for the bounded lossless TikZ vertical slice.
--
-- This facade combines exact document opening, typed diagnostics, the minimal
-- semantic and render models, and the verified 'MoveNode' operation. Its
-- supported grammar is specified in @docs/specs/slice1-tikz-subset.md@.
module SlideBlaster.TikZ
  ( module SlideBlaster.TikZ.Diagnostic
  , module SlideBlaster.TikZ.Document
  , module SlideBlaster.TikZ.Edit
  , module SlideBlaster.TikZ.Model
  , module SlideBlaster.TikZ.RenderPlan
  ) where

import SlideBlaster.TikZ.Diagnostic
import SlideBlaster.TikZ.Document
import SlideBlaster.TikZ.Edit
import SlideBlaster.TikZ.Model
import SlideBlaster.TikZ.RenderPlan
