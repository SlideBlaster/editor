-- |
-- Module      : SlideBlaster.Ports.Measurement
-- Description : Runtime execution of authoritative render measurement batches.
--
-- The port consumes render-owned dialect-free content, embedded resources, and
-- correlation values without defining a second host-shaped request model.
-- An adapter that cannot honor structured content and exact font resources
-- must remain unavailable instead of flattening text or accepting font
-- fallback.
module SlideBlaster.Ports.Measurement
  ( MeasurementPort (..)
  , MeasurementPortError (..)
  , measurementResultForRequest
  ) where

import SlideBlaster.Canvas (Size)
import SlideBlaster.Ports.Capability (RuntimeFailure)
import SlideBlaster.Render
  ( MeasurementBatch
  , MeasurementRequest (..)
  , MeasurementResult (..)
  , MeasurementTicket
  )

import Data.Text (Text)

-- | Execute one already-correlated authoritative measurement batch.
data MeasurementPort m = MeasurementPort
  { runMeasurementBatch
      :: MeasurementBatch
      -> m (Either MeasurementPortError [MeasurementResult])
  }

data MeasurementPortError
  = MeasurementRuntimeFailure !RuntimeFailure
  | MeasurementRequestUnsupported !Text
  deriving stock (Eq, Show)

-- | Construct a result using only the original request key and batch ticket.
--
-- Adapters use this after converting a positive host result to the
-- canvas-owned 'Size'. Exact batch coverage and staleness are still checked by
-- @completeMeasurements@ in slideblaster-render.
measurementResultForRequest
  :: MeasurementTicket
  -> MeasurementRequest
  -> Size
  -> MeasurementResult
measurementResultForRequest ticket request size =
  MeasurementResult
    { measurementResultTicket = ticket
    , measurementResultKey = measurementKey request
    , measurementResultSize = size
    }
