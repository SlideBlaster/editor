{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Export.Internal.Report
-- Description : Smart constructors preserving export report invariants.
module SlideBlaster.Export.Internal.Report
  ( artifactsReport
  , capabilityReport
  , rejectedReport
  , deterministicArtifact
  , printPlan
  , archivePlan
  ) where

import SlideBlaster.Export.Diagnostic
  ( DiagnosticCode (InternalExportInvariant)
  , DiagnosticSeverity (ExportFatal)
  , ExportDiagnostic
  , ExportLocation (DocumentLocation)
  , exportDiagnostic
  , hasFatalDiagnostics
  )
import SlideBlaster.Export.Types
  ( ArchivePlan (..)
  , ArtifactMediaType
  , CapabilityPlan
  , DeterministicArtifact (..)
  , ExportOutcome (..)
  , ExportReport (..)
  , ExportTarget
  , PrintPlan (..)
  , WorkspaceEntry
  , workspaceEntryPath
  )

import Data.ByteString (ByteString)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Numeric.Natural (Natural)

-- | Report deterministic artifacts, rejecting defensively if fatal
-- diagnostics were supplied.
artifactsReport ::
  ExportTarget ->
  [ExportDiagnostic] ->
  NonEmpty DeterministicArtifact ->
  ExportReport
artifactsReport target diagnostics artifacts
  | hasFatalDiagnostics diagnostics = rejectedReport target diagnostics
  | otherwise =
      ExportReport
        { reportTarget = target
        , reportDiagnostics = diagnostics
        , reportOutcome =
            ArtifactsReady
              (NonEmpty.sortWith artifactPath artifacts)
        }

-- | Report a required host capability, rejecting defensively if fatal
-- diagnostics were supplied.
capabilityReport ::
  ExportTarget ->
  [ExportDiagnostic] ->
  CapabilityPlan ->
  ExportReport
capabilityReport target diagnostics capability
  | hasFatalDiagnostics diagnostics = rejectedReport target diagnostics
  | otherwise =
      ExportReport
        { reportTarget = target
        , reportDiagnostics = diagnostics
        , reportOutcome = CapabilityRequired capability
        }

-- | Report failure. Planners ensure the supplied list contains a fatal fact.
rejectedReport :: ExportTarget -> [ExportDiagnostic] -> ExportReport
rejectedReport target diagnostics =
  ExportReport
    { reportTarget = target
    , reportDiagnostics = fatalDiagnostics
    , reportOutcome = ExportRejected
    }
  where
    fatalDiagnostics
      | hasFatalDiagnostics diagnostics = diagnostics
      | otherwise =
          diagnostics
            <> [ exportDiagnostic
                   ExportFatal
                   InternalExportInvariant
                   DocumentLocation
                   "Export was rejected without a fatal cause."
               ]

-- | Construct one generated artifact.
deterministicArtifact ::
  Text ->
  ArtifactMediaType ->
  ByteString ->
  DeterministicArtifact
deterministicArtifact = DeterministicArtifact

-- | Construct a browser/native print capability payload.
printPlan :: ByteString -> Text -> Int -> Natural -> Natural -> PrintPlan
printPlan = PrintPlan

-- | Construct an archive capability payload with sorted entries.
archivePlan :: Text -> [WorkspaceEntry] -> ArchivePlan
archivePlan outputName entries =
  ArchivePlan
    { archiveOutputName = outputName
    , archiveEntries = sortOn workspaceEntryPath entries
    }
