{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Export.Internal.Workspace
-- Description : Deterministic workspace archive capability planning.
module SlideBlaster.Export.Internal.Workspace
  ( planWorkspaceArchive
  ) where

import SlideBlaster.Export.Diagnostic
  ( DiagnosticCode
      ( DuplicateWorkspacePath
      , ExcludedGitMetadata
      , UnsafeWorkspacePath
      )
  , DiagnosticSeverity (ExportFatal, ExportWarning)
  , ExportDiagnostic
  , ExportLocation (WorkspacePathLocation)
  , exportDiagnostic
  , hasFatalDiagnostics
  )
import SlideBlaster.Export.Internal.Report
  ( archivePlan
  , capabilityReport
  , rejectedReport
  )
import SlideBlaster.Export.Types
  ( CapabilityPlan (CompressWorkspace)
  , ExportReport
  , ExportTarget (WorkspaceArchive)
  , WorkspaceEntry
  , workspaceEntryPath
  )

import Data.List (group, sort, sortOn)
import Data.Text (Text)
import Data.Text qualified as Text

-- | Validate exact storage entries and request deterministic ZIP compression.
planWorkspaceArchive :: Text -> [WorkspaceEntry] -> ExportReport
planWorkspaceArchive outputName suppliedEntries
  | hasFatalDiagnostics diagnostics =
      rejectedReport WorkspaceArchive diagnostics
  | otherwise =
      capabilityReport
        WorkspaceArchive
        diagnostics
        (CompressWorkspace (archivePlan outputName includedEntries))
  where
    unsafeEntries =
      sortOn workspaceEntryPath
        (filter (not . pathIsSafe . workspaceEntryPath) suppliedEntries)
    safeEntries = filter (pathIsSafe . workspaceEntryPath) suppliedEntries
    gitEntries =
      sortOn workspaceEntryPath
        (filter (isGitPath . workspaceEntryPath) safeEntries)
    includedEntries = filter (not . isGitPath . workspaceEntryPath) safeEntries
    duplicatePaths =
      firstOfEach
        ( filter ((> 1) . length)
            (group (sort (workspaceEntryPath <$> includedEntries)))
        )
    diagnostics =
      (unsafePathDiagnostic . workspaceEntryPath <$> unsafeEntries)
        <> (duplicatePathDiagnostic <$> duplicatePaths)
        <> (gitPathDiagnostic . workspaceEntryPath <$> gitEntries)

pathIsSafe :: Text -> Bool
pathIsSafe path =
  not (Text.null path)
    && not ("/" `Text.isPrefixOf` path)
    && not (hasWindowsDrivePrefix path)
    && not ("\\" `Text.isInfixOf` path)
    && not ("\NUL" `Text.isInfixOf` path)
    && all segmentIsSafe (Text.splitOn "/" path)

segmentIsSafe :: Text -> Bool
segmentIsSafe segment =
  not (Text.null segment)
    && segment /= "."
    && segment /= ".."

hasWindowsDrivePrefix :: Text -> Bool
hasWindowsDrivePrefix path =
  case Text.unpack (Text.take 2 path) of
    [letter, ':'] -> isAsciiLetter letter
    _ -> False

isAsciiLetter :: Char -> Bool
isAsciiLetter character =
  (character >= 'a' && character <= 'z')
    || (character >= 'A' && character <= 'Z')

isGitPath :: Text -> Bool
isGitPath = elem ".git" . Text.splitOn "/"

firstOfEach :: [[value]] -> [value]
firstOfEach = foldr appendFirst []
  where
    appendFirst values rest =
      case values of
        [] -> rest
        value : _ -> value : rest

unsafePathDiagnostic :: Text -> ExportDiagnostic
unsafePathDiagnostic path =
  exportDiagnostic
    ExportFatal
    UnsafeWorkspacePath
    (WorkspacePathLocation path)
    "Workspace path is not a normalized, relative POSIX file path."

duplicatePathDiagnostic :: Text -> ExportDiagnostic
duplicatePathDiagnostic path =
  exportDiagnostic
    ExportFatal
    DuplicateWorkspacePath
    (WorkspacePathLocation path)
    "Workspace contains more than one entry at this exact path."

gitPathDiagnostic :: Text -> ExportDiagnostic
gitPathDiagnostic path =
  exportDiagnostic
    ExportWarning
    ExcludedGitMetadata
    (WorkspacePathLocation path)
    "Git internals are intentionally excluded from workspace archives."
