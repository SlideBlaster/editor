{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Render.Measurement
-- Description : Correlated measurement of already-lowered render content.
--
-- Haskell describes exactly what must be measured. Requests contain
-- dialect-free 'RenderContent' and an embedded resource manifest, never
-- semantic canvas content, theme lookups, or source syntax. A target adapter
-- supplies sizes, after which this module proves exact ticket and key coverage.
module SlideBlaster.Render.Measurement
  ( MeasurementTicket
  , measurementTicketFromWord64
  , measurementTicketToWord64
  , MeasurementPart
  , mkMeasurementPart
  , measurementPartText
  , MeasurementKey (..)
  , MeasurementMode (..)
  , MeasurementRequest (..)
  , MeasurementBatch
  , MeasurementBatchError (..)
  , mkMeasurementBatch
  , measurementBatchRequests
  , measurementBatchResources
  , measurementBatchTicket
  , MeasurementResult (..)
  , MeasurementSet
  , MeasurementCompletionError (..)
  , completeMeasurements
  , lookupMeasurement
  ) where

import SlideBlaster.Canvas (CanvasUnit, Size, canvasUnitValue)
import SlideBlaster.Presentation (ElementAddress)
import SlideBlaster.Render.Content
  ( RenderContent
  , renderContentResourceReferences
  )
import SlideBlaster.Render.Resource
  ( ResourceManifest
  , ResourceReferenceError
  , validateResourceReferences
  )

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)

-- | Correlation fence for one measurement/layout attempt.
newtype MeasurementTicket = MeasurementTicket Word64
  deriving stock (Eq, Ord, Show)

measurementTicketFromWord64 :: Word64 -> MeasurementTicket
measurementTicketFromWord64 = MeasurementTicket

measurementTicketToWord64 :: MeasurementTicket -> Word64
measurementTicketToWord64 (MeasurementTicket value) = value

-- | Stable semantic sub-part within an element, such as @body@ or @label@.
newtype MeasurementPart = MeasurementPart Text
  deriving stock (Eq, Ord, Show)

mkMeasurementPart :: Text -> Maybe MeasurementPart
mkMeasurementPart value
  | Text.null (Text.strip value) = Nothing
  | otherwise = Just (MeasurementPart value)

measurementPartText :: MeasurementPart -> Text
measurementPartText (MeasurementPart value) = value

-- | Stable address of one measurable rendered fragment.
data MeasurementKey = MeasurementKey
  { measurementElement :: !ElementAddress
  , measurementPart :: !MeasurementPart
  }
  deriving stock (Eq, Ord, Show)

-- | Intrinsic size or wrapping under a target-neutral slide-unit constraint.
data MeasurementMode
  = MeasureIntrinsic
  | MeasureWithin !CanvasUnit
  deriving stock (Eq, Ord, Show)

-- | A dialect-free render fragment to measure.
data MeasurementRequest = MeasurementRequest
  { measurementKey :: !MeasurementKey
  , measurementContent :: !RenderContent
  , measurementMode :: !MeasurementMode
  }
  deriving stock (Eq, Show)

data MeasurementBatch = MeasurementBatch
  !MeasurementTicket
  !ResourceManifest
  ![MeasurementRequest]
  deriving stock (Eq, Show)

data MeasurementBatchError
  = DuplicateMeasurementRequest !MeasurementKey
  | MeasurementWidthMustBePositive !MeasurementKey !CanvasUnit
  | MeasurementResourceInvalid !ResourceReferenceError
  deriving stock (Eq, Show)

-- | Construct a batch, rejecting duplicate keys or content whose embedded
-- font/image references are absent or have the wrong kind.
mkMeasurementBatch
  :: MeasurementTicket
  -> ResourceManifest
  -> [MeasurementRequest]
  -> Either MeasurementBatchError MeasurementBatch
mkMeasurementBatch ticket resources requests = do
  _ <- uniqueRequestKeys Set.empty requests
  validateMeasurementWidths requests
  mapMeasurementResourceError
    ( validateResourceReferences
        resources
        (foldMap (renderContentResourceReferences . measurementContent) requests)
    )
  Right (MeasurementBatch ticket resources requests)

measurementBatchTicket :: MeasurementBatch -> MeasurementTicket
measurementBatchTicket (MeasurementBatch ticket _ _) = ticket

measurementBatchResources :: MeasurementBatch -> ResourceManifest
measurementBatchResources (MeasurementBatch _ resources _) = resources

measurementBatchRequests :: MeasurementBatch -> [MeasurementRequest]
measurementBatchRequests (MeasurementBatch _ _ requests) = requests

-- | One host result, retaining the ticket that fenced its request.
data MeasurementResult = MeasurementResult
  { measurementResultTicket :: !MeasurementTicket
  , measurementResultKey :: !MeasurementKey
  , measurementResultSize :: !Size
  }
  deriving stock (Eq, Show)

newtype MeasurementSet = MeasurementSet (Map MeasurementKey Size)
  deriving stock (Eq, Show)

data MeasurementCompletionError
  = StaleMeasurementResult !MeasurementTicket !MeasurementTicket
  | DuplicateMeasurementResult !MeasurementKey
  | MissingMeasurementResults !(Set MeasurementKey)
  | UnexpectedMeasurementResults !(Set MeasurementKey)
  deriving stock (Eq, Show)

-- | Validate ticket, uniqueness, and exact request/result coverage.
completeMeasurements
  :: MeasurementBatch
  -> [MeasurementResult]
  -> Either MeasurementCompletionError MeasurementSet
completeMeasurements batch results = do
  resultMap <- collectResults expectedTicket Map.empty results
  let requested = Set.fromList (fmap measurementKey (measurementBatchRequests batch))
      returned = Map.keysSet resultMap
      missing = Set.difference requested returned
      unexpected = Set.difference returned requested
  if not (Set.null missing)
    then Left (MissingMeasurementResults missing)
    else
      if not (Set.null unexpected)
        then Left (UnexpectedMeasurementResults unexpected)
        else Right (MeasurementSet resultMap)
  where
    expectedTicket = measurementBatchTicket batch

lookupMeasurement :: MeasurementKey -> MeasurementSet -> Maybe Size
lookupMeasurement key (MeasurementSet values) = Map.lookup key values

mapMeasurementResourceError
  :: Either ResourceReferenceError ()
  -> Either MeasurementBatchError ()
mapMeasurementResourceError result =
  case result of
    Left failure -> Left (MeasurementResourceInvalid failure)
    Right () -> Right ()

uniqueRequestKeys
  :: Set MeasurementKey
  -> [MeasurementRequest]
  -> Either MeasurementBatchError (Set MeasurementKey)
uniqueRequestKeys seen [] = Right seen
uniqueRequestKeys seen (request : remaining)
  | Set.member key seen = Left (DuplicateMeasurementRequest key)
  | otherwise = uniqueRequestKeys (Set.insert key seen) remaining
  where
    key = measurementKey request

validateMeasurementWidths
  :: [MeasurementRequest]
  -> Either MeasurementBatchError ()
validateMeasurementWidths [] = Right ()
validateMeasurementWidths (request : remaining) =
  case measurementMode request of
    MeasureWithin width
      | canvasUnitValue width <= 0 ->
          Left
            (MeasurementWidthMustBePositive (measurementKey request) width)
    MeasureWithin _ -> validateMeasurementWidths remaining
    MeasureIntrinsic -> validateMeasurementWidths remaining

collectResults
  :: MeasurementTicket
  -> Map MeasurementKey Size
  -> [MeasurementResult]
  -> Either MeasurementCompletionError (Map MeasurementKey Size)
collectResults _ values [] = Right values
collectResults expected values (result : remaining)
  | measurementResultTicket result /= expected =
      Left
        ( StaleMeasurementResult
            expected
            (measurementResultTicket result)
        )
  | Map.member key values =
      Left (DuplicateMeasurementResult key)
  | otherwise =
      collectResults
        expected
        (Map.insert key (measurementResultSize result) values)
        remaining
  where
    key = measurementResultKey result
