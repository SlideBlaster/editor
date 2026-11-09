-- |
-- Module      : SlideBlaster.Ports.Export
-- Description : Host execution records for already-planned export artifacts.
--
-- Export compatibility and loss policy are resolved before these ports run.
-- The records consume authoritative slideblaster-export values and cannot
-- classify, repair, or silently discard presentation features.
module SlideBlaster.Ports.Export
  ( DownloadRequest (..)
  , DownloadPort (..)
  , ArchiveBytes
  , mkArchiveBytes
  , archiveBytesValue
  , PrintCompletion (..)
  , PrintPort (..)
  , ArchivePort (..)
  , ExportPortError (..)
  ) where

import SlideBlaster.Export
  ( ArchivePlan
  , DeterministicArtifact
  , PrintPlan
  )
import SlideBlaster.Ports.Capability (RuntimeFailure)

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString

-- | A pure artifact, or exact bytes produced from an authoritative archive
-- plan, ready for host delivery.
data DownloadRequest
  = DownloadArtifact !DeterministicArtifact
  | DownloadArchive !ArchivePlan !ArchiveBytes
  deriving stock (Eq, Show)

data ExportPortError
  = ExportRuntimeFailure !RuntimeFailure
  | ExportOperationUnsupported
  | ArchiveResultEmpty
  deriving stock (Eq, Show)

-- | Non-empty bytes returned by a successful deterministic archive codec.
newtype ArchiveBytes = ArchiveBytes ByteString
  deriving stock (Eq, Show)

-- | Admit only a non-empty successful codec result.
mkArchiveBytes :: ByteString -> Either ExportPortError ArchiveBytes
mkArchiveBytes bytes
  | ByteString.null bytes = Left ArchiveResultEmpty
  | otherwise = Right (ArchiveBytes bytes)

-- | Recover exact archive bytes for a delivery adapter.
archiveBytesValue :: ArchiveBytes -> ByteString
archiveBytesValue (ArchiveBytes bytes) = bytes

data DownloadPort m = DownloadPort
  { deliverDownload
      :: DownloadRequest
      -> m (Either ExportPortError ())
  }

-- | Browser print cannot honestly assert that the user saved a PDF.
data PrintCompletion
  = PrintDialogCompleted
  | PrintDialogDismissed
  deriving stock (Eq, Ord, Show)

data PrintPort m = PrintPort
  { executePrintPlan
      :: PrintPlan
      -> m (Either ExportPortError PrintCompletion)
  }

data ArchivePort m = ArchivePort
  { compressArchivePlan
      :: ArchivePlan
      -> m (Either ExportPortError ArchiveBytes)
  }
