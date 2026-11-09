{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Export.Types
-- Description : Target, artifact, capability, and report values.
--
-- 'ExportReport' has no public constructor. Export planners preserve the
-- invariant that fatal diagnostics accompany only rejection, while artifacts
-- and capability plans never coexist with a fatal diagnostic.
module SlideBlaster.Export.Types
  ( ExportTarget (..)
  , LossPolicy (..)
  , ArtifactMediaType (..)
  , DeterministicArtifact (DeterministicArtifact)
  , artifactPath
  , artifactMediaType
  , artifactBytes
  , WorkspaceEntry
  , workspaceEntry
  , workspaceEntryPath
  , workspaceEntryBytes
  , PrintPlan (PrintPlan)
  , printDocumentBytes
  , printOutputName
  , printPageCount
  , printPageWidthMillimetres
  , printPageHeightMillimetres
  , ArchivePlan (ArchivePlan)
  , archiveOutputName
  , archiveEntries
  , CapabilityPlan (..)
  , ExportOutcome (..)
  , ExportReport (ExportReport)
  , reportTarget
  , reportDiagnostics
  , reportOutcome
  ) where

import SlideBlaster.Export.Diagnostic (ExportDiagnostic)

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Numeric.Natural (Natural)

-- | User-visible export target.
data ExportTarget
  = StandaloneHtml
  | RenderedPdf
  | LatexProject
  | WorkspaceArchive
  deriving stock (Eq, Ord, Show)

-- | Whether enumerated target approximations are admitted.
data LossPolicy
  = RejectLoss
  | PermitDocumentedApproximation
  deriving stock (Eq, Ord, Show)

-- | Media type of a deterministic pure artifact.
data ArtifactMediaType
  = HtmlDocument
  | LatexSource
  | LatexStyle
  | BibliographySource
  | BinaryAsset Text
  deriving stock (Eq, Ord, Show)

-- | A path-addressed artifact whose bytes depend only on the request.
data DeterministicArtifact = DeterministicArtifact
  { artifactPath :: !Text
  , artifactMediaType :: !ArtifactMediaType
  , artifactBytes :: !ByteString
  }
  deriving stock (Eq, Show)

-- | Exact workspace bytes at one relative POSIX path.
data WorkspaceEntry = WorkspaceEntry
  { workspaceEntryPath :: !Text
  , workspaceEntryBytes :: !ByteString
  }
  deriving stock (Eq, Show)

-- | Construct an entry. Safety and duplicate checks belong to the archive
-- planner so invalid input receives an 'ExportReport' diagnostic.
workspaceEntry :: Text -> ByteString -> WorkspaceEntry
workspaceEntry = WorkspaceEntry

-- | A deterministic print document awaiting a browser or native webview.
data PrintPlan = PrintPlan
  { printDocumentBytes :: !ByteString
  , printOutputName :: !Text
  , printPageCount :: !Int
  , printPageWidthMillimetres :: !Natural
  , printPageHeightMillimetres :: !Natural
  }
  deriving stock (Eq, Show)

-- | Ordered exact entries awaiting deterministic ZIP compression.
data ArchivePlan = ArchivePlan
  { archiveOutputName :: !Text
  , archiveEntries :: [WorkspaceEntry]
  }
  deriving stock (Eq, Show)

-- | Host effect required to complete a target.
data CapabilityPlan
  = PrintRenderedBeats PrintPlan
  | CompressWorkspace ArchivePlan
  deriving stock (Eq, Show)

-- | Pure disposition of an export request.
data ExportOutcome
  = ArtifactsReady (NonEmpty DeterministicArtifact)
  | CapabilityRequired CapabilityPlan
  | ExportRejected
  deriving stock (Eq, Show)

-- | Invariant-preserving result from one export planner.
data ExportReport = ExportReport
  { reportTarget :: !ExportTarget
  , reportDiagnostics :: [ExportDiagnostic]
  , reportOutcome :: !ExportOutcome
  }
  deriving stock (Eq, Show)
