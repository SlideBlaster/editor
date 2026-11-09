-- |
-- Module      : SlideBlaster.Ports.Capability
-- Description : Explicit capability provision and target-boundary failures.
--
-- A composition distinguishes a port that exists from one that is unavailable
-- before offering a command. Runtime failures remain typed in case an
-- advertised capability later loses permission, transport, or infrastructure.
module SlideBlaster.Ports.Capability
  ( CapabilityName (..)
  , CapabilityAbsenceReason (..)
  , CapabilityAbsence (..)
  , CapabilityProvision (..)
  , capabilityIsProvided
  , RuntimeFailure (..)
  ) where

import Data.Text (Text)

-- | Closed product capabilities supplied by native and browser compositions.
data CapabilityName
  = WorkspaceStorageCapability
  | GitCapability
  | MeasurementCapability
  | PresenterWindowCapability
  | PresenterChannelCapability
  | DownloadCapability
  | PrintCapability
  | ArchiveCapability
  | CompilerCapability
  | ClockCapability
  | LoggingCapability
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Why a composition cannot provide an entire port.
data CapabilityAbsenceReason
  = NotImplementedForTarget !Text
  | HostOperationMissing !Text
  | ExternalDependencyMissing !Text
  | PermissionUnavailable !Text
  deriving stock (Eq, Ord, Show)

-- | Capability name and stable reason used by command availability.
data CapabilityAbsence = CapabilityAbsence
  { absentCapability :: !CapabilityName
  , capabilityAbsenceReason :: !CapabilityAbsenceReason
  }
  deriving stock (Eq, Ord, Show)

-- | Either a real interpreter record or an explicit whole-port absence.
data CapabilityProvision capability
  = CapabilityProvided capability
  | CapabilityUnavailable !CapabilityAbsence
  deriving stock (Eq, Ord, Show)

-- | Test whether a composition actually supplied an interpreter.
capabilityIsProvided :: CapabilityProvision capability -> Bool
capabilityIsProvided provision =
  case provision of
    CapabilityProvided _ -> True
    CapabilityUnavailable _ -> False

-- | Failure after a capability was advertised.
--
-- Messages must not contain source bytes, credentials, or compiler input.
data RuntimeFailure
  = RuntimeUnavailable !Text
  | RuntimeProtocolFailure !Text
  | RuntimeInfrastructureFailure !Text
  | RuntimeRejected !Text !Text
  deriving stock (Eq, Ord, Show)
