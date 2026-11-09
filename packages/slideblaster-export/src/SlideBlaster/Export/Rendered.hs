{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Export.Rendered
-- Description : Renderer-owned beat fragments accepted by HTML and PDF export.
--
-- A rendered beat is an opaque renderer result keyed to the public
-- presentation beat address. It is not a second presentation model and is
-- never interpreted as source authority.
module SlideBlaster.Export.Rendered
  ( BeatKey
  , beatKeyFor
  , beatKeyFrameId
  , beatKeyStepNumber
  , RenderedMotion (..)
  , RenderedBeat
  , interactiveRenderedBeat
  , staticRenderedBeat
  , renderedBeatKey
  , renderedBeatMotion
  , renderedBeatMarkup
  , RenderedBeatSet
  , renderedBeatSet
  , renderedBeats
  ) where

import SlideBlaster.Canvas (overlayStepNumber)
import SlideBlaster.Presentation
  ( Beat
  , StaticSample
  , beatFrameId
  , beatStep
  , frameIdText
  )

import Data.List (sortOn)
import Data.Text (Text)
import Numeric.Natural (Natural)

-- | Deterministic renderer transport identity derived from an authoritative
-- public presentation beat.
--
-- The constructor is private. Export does not admit independently invented
-- frame/step semantics.
data BeatKey = BeatKey
  { beatKeyFrameId :: !Text
  , beatKeyStepNumber :: !Natural
  }
  deriving stock (Eq, Ord, Show)

-- | Total transport-key projection from one public presentation beat.
beatKeyFor :: Beat -> BeatKey
beatKeyFor beat =
  BeatKey
    { beatKeyFrameId = frameIdText (beatFrameId beat)
    , beatKeyStepNumber = overlayStepNumber (beatStep beat)
    }

-- | Whether the renderer preserved motion or applied a static endpoint.
data RenderedMotion
  = InteractiveMotion
  | StaticMotion StaticSample
  deriving stock (Eq, Show)

-- | Final renderer markup for one presentation beat.
data RenderedBeat = RenderedBeat
  { renderedBeatKey :: !BeatKey
  , renderedBeatMotion :: !RenderedMotion
  , renderedBeatMarkup :: Text
  }
  deriving stock (Eq, Show)

-- | Claim renderer output that preserves the beat's interactive timelines.
interactiveRenderedBeat :: Beat -> Text -> RenderedBeat
interactiveRenderedBeat beat =
  RenderedBeat (beatKeyFor beat) InteractiveMotion

-- | Claim renderer output after applying one deterministic static endpoint to
-- every timed animation on the beat.
staticRenderedBeat :: StaticSample -> Beat -> Text -> RenderedBeat
staticRenderedBeat endpoint beat =
  RenderedBeat (beatKeyFor beat) (StaticMotion endpoint)

-- | Renderer results in deterministic address order.
--
-- Duplicate and unexpected addresses remain present so the export planner can
-- reject them with scoped diagnostics rather than losing information here.
newtype RenderedBeatSet = RenderedBeatSet
  { renderedBeats :: [RenderedBeat]
  }
  deriving stock (Eq, Show)

-- | Form a set-like renderer result while retaining duplicate entries.
renderedBeatSet :: [RenderedBeat] -> RenderedBeatSet
renderedBeatSet =
  RenderedBeatSet
    . sortOn renderedBeatKey
