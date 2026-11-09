-- |
-- Module      : SlideBlaster.App.Capability
-- Description : Target capability availability used by command policy.
--
-- Browser and native compositions advertise the same closed vocabulary. A
-- missing target service disables the affected command with a reason; it does
-- not select an alternate semantic implementation.
module SlideBlaster.App.Capability
  ( Capability (..)
  , CapabilityReason (..)
  , CapabilityStatus (..)
  , CapabilitySet
  , emptyCapabilitySet
  , capabilitySet
  , capabilityStatus
  , hasCapability
  , setCapabilityStatus
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

data Capability
  = StorageCapability
  | GitCapability
  | MeasurementCapability
  | PresenterWindowCapability
  | PresenterChannelCapability
  | DownloadCapability
  | PrintCapability
  | ArchiveCapability
  | CompileCapability
  | ClipboardCapability
  | ClockCapability
  | LoggingCapability
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data CapabilityReason
  = NotImplementedForTarget
  | PermissionDenied
  | TemporarilyUnavailable !Text
  | HostRejectedCapability !Text
  deriving stock (Eq, Ord, Show)

data CapabilityStatus
  = CapabilityAvailable
  | CapabilityUnavailable !CapabilityReason
  deriving stock (Eq, Ord, Show)

newtype CapabilitySet = CapabilitySet (Map Capability CapabilityStatus)
  deriving stock (Eq, Show)

emptyCapabilitySet :: CapabilitySet
emptyCapabilitySet = CapabilitySet Map.empty

capabilitySet :: [(Capability, CapabilityStatus)] -> CapabilitySet
capabilitySet = CapabilitySet . Map.fromList

-- | Unadvertised capabilities are unavailable, never optimistically assumed.
capabilityStatus :: Capability -> CapabilitySet -> CapabilityStatus
capabilityStatus capability (CapabilitySet values) =
  Map.findWithDefault
    (CapabilityUnavailable NotImplementedForTarget)
    capability
    values

hasCapability :: Capability -> CapabilitySet -> Bool
hasCapability capability values =
  case capabilityStatus capability values of
    CapabilityAvailable -> True
    CapabilityUnavailable _ -> False

setCapabilityStatus
  :: Capability
  -> CapabilityStatus
  -> CapabilitySet
  -> CapabilitySet
setCapabilityStatus capability status (CapabilitySet values) =
  CapabilitySet (Map.insert capability status values)
