{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Native.Port
-- Description : Portable native interpreters for shared runtime ports.
--
-- The implemented subset delegates exact reads/replacements and Git calls to
-- the existing standard-library native adapters. Paths are first validated by
-- slideblaster-ports and resolved beneath one injected workspace root. Missing
-- native features are advertised as unavailable; no placeholder action claims
-- to have printed, archived, compiled, downloaded, or opened presenter windows.
module SlideBlaster.Adapter.Native.Port
  ( nativeStorageProvision
  , nativeGitProvision
  , nativeClockProvision
  , nativeLogProvision
  , nativeMeasurementProvision
  , nativePresenterWindowProvision
  , nativePresenterChannelProvision
  , nativeDownloadProvision
  , nativePrintProvision
  , nativeArchiveProvision
  , nativeCompilerProvision
  ) where

import SlideBlaster.Adapter.Native.FileSystem
  ( NativeFileSystem (..)
  , NativeFsError (..)
  , NativeSaveError (..)
  , nativeFileSystem
  )
import SlideBlaster.Adapter.Native.Git
  ( NativeGit (..)
  , NativeGitError (..)
  , nativeGit
  )
import SlideBlaster.Ports

import Data.ByteString (ByteString)
import Data.List
  ( sort
  , sortOn
  )
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO

import GHC.Clock (getMonotonicTimeNSec)
import Numeric.Natural (Natural)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , doesPathExist
  , listDirectory
  , pathIsSymbolicLink
  )
import System.FilePath ((</>))
import System.IO (stderr)
import System.IO.Error (tryIOError)

-- | Supply exact-byte reads, sorted traversal, and expected-byte replacement.
--
-- Conditional creation is not claimed because the existing portable adapter
-- has no exclusive create primitive. Existing-file replacement keeps its
-- documented best-effort external-writer race.
nativeStorageProvision
  :: WorkspaceId
  -> FilePath
  -> CapabilityProvision (StoragePort IO)
nativeStorageProvision workspace root =
  CapabilityProvided
    StoragePort
      { storageWorkspaceId = workspace
      , storageArbitraryBytesSupport = CapabilityProvided ()
      , storageCreateSupport =
          operationUnavailable
            WorkspaceStorageCapability
            "Portable conditional creation is not implemented"
      , storageReplaceSupport = CapabilityProvided ()
      , storageListFiles = nativeListFiles root
      , storageReadFile = nativeReadWorkspaceFile root
      , storageWriteFile = nativeWriteWorkspaceFile root
      }

-- | Supply the existing argument-array Git version and status operations.
nativeGitProvision
  :: WorkspaceId
  -> FilePath
  -> CapabilityProvision (GitPort IO)
nativeGitProvision workspace root =
  CapabilityProvided
    ( gitPort
        workspace
        nativeGitOperationProvision
        (runNativeGit root)
    )

-- | Supply a monotonic timer origin from @base@.
nativeClockProvision :: CapabilityProvision (ClockPort IO)
nativeClockProvision =
  CapabilityProvided
    ClockPort
      { readTimerOrigin = do
          nanoseconds <- getMonotonicTimeNSec
          let milliseconds =
                fromIntegral (nanoseconds `div` 1_000_000) :: Natural
          pure
            ( Right
                (timerOriginFromMilliseconds milliseconds)
            )
      }

-- | Supply structured stderr logging using @text@ and @base@.
nativeLogProvision :: CapabilityProvision (LogPort IO)
nativeLogProvision =
  CapabilityProvided
    LogPort
      { writeLogEntry = \entry -> do
          result <-
            tryIOError
              (TextIO.hPutStrLn stderr (renderNativeLogEntry entry))
          pure $
            case result of
              Left problem ->
                Left
                  ( LogRuntimeFailure
                      ( RuntimeInfrastructureFailure
                          (Text.pack (show problem))
                      )
                  )
              Right () -> Right ()
      }

nativeMeasurementProvision
  :: CapabilityProvision (MeasurementPort IO)
nativeMeasurementProvision =
  unavailable
    MeasurementCapability
    "No native layout measurer has been selected"

nativePresenterWindowProvision
  :: CapabilityProvision (PresenterWindowPort IO)
nativePresenterWindowProvision =
  unavailable
    PresenterWindowCapability
    "The local CLI has no presenter window host"

nativePresenterChannelProvision
  :: CapabilityProvision (PresenterChannelPort IO)
nativePresenterChannelProvision =
  unavailable
    PresenterChannelCapability
    "The local CLI has no presenter channel host"

nativeDownloadProvision
  :: CapabilityProvision (DownloadPort IO)
nativeDownloadProvision =
  unavailable
    DownloadCapability
    "Artifact destination selection is not composed in the local CLI"

nativePrintProvision :: CapabilityProvision (PrintPort IO)
nativePrintProvision =
  unavailable
    PrintCapability
    "The local CLI has no selected PDF or print interpreter"

nativeArchiveProvision :: CapabilityProvision (ArchivePort IO)
nativeArchiveProvision =
  unavailable
    ArchiveCapability
    "No deterministic ZIP codec is composed yet"

nativeCompilerProvision :: CapabilityProvision (CompilerPort IO)
nativeCompilerProvision =
  unavailable
    CompilerCapability
    "No local TeX compiler adapter is composed yet"

nativeListFiles
  :: FilePath
  -> IO (Either StorageError [WorkspacePath])
nativeListFiles root = do
  result <- catchStorageFailure (walkDirectory root [] root)
  pure (sortOn workspacePathText <$> result)

walkDirectory
  :: FilePath
  -> [Text]
  -> FilePath
  -> IO (Either StorageError [WorkspacePath])
walkDirectory root relative directory = do
  names <- sort <$> listDirectory directory
  walkEntries root relative directory names

walkEntries
  :: FilePath
  -> [Text]
  -> FilePath
  -> [FilePath]
  -> IO (Either StorageError [WorkspacePath])
walkEntries _ _ _ [] = pure (Right [])
walkEntries root relative directory (name : remaining)
  | name == ".git" =
      walkEntries root relative directory remaining
  | otherwise =
      case mkWorkspacePath (Text.intercalate "/" pathSegments) of
        Left problem ->
          pure (Left (StorageHostReturnedInvalidPath problem))
        Right workspacePath -> do
          let nativePath = directory </> name
          symbolic <- pathIsSymbolicLink nativePath
          if symbolic
            then pure (Left (StorageUnsafeFilesystemEntry workspacePath))
            else do
              isDirectory <- doesDirectoryExist nativePath
              isFile <- doesFileExist nativePath
              current <-
                if isDirectory
                  then walkDirectory root pathSegments nativePath
                  else
                    if isFile
                      then pure (Right [workspacePath])
                      else
                        pure
                          (Left (StorageUnsafeFilesystemEntry workspacePath))
              case current of
                Left problem -> pure (Left problem)
                Right currentPaths -> do
                  rest <-
                    walkEntries root relative directory remaining
                  pure ((currentPaths <>) <$> rest)
  where
    pathSegments = relative <> [Text.pack name]

nativeReadWorkspaceFile
  :: FilePath
  -> WorkspacePath
  -> IO (Either StorageError (Maybe ByteString))
nativeReadWorkspaceFile root workspacePath =
  catchStorageFailure $ do
    safe <- hasNoSymbolicLinkComponents root workspacePath
    if not safe
      then pure (Left (StorageUnsafeFilesystemEntry workspacePath))
      else do
        let nativePath = resolveWorkspacePath root workspacePath
        exists <- doesPathExist nativePath
        if not exists
          then pure (Right Nothing)
          else do
            isFile <- doesFileExist nativePath
            if not isFile
              then pure (Left (StorageUnsafeFilesystemEntry workspacePath))
              else do
                loaded <- nativeReadFile nativeFileSystem nativePath
                pure $
                  case loaded of
                    Left problem ->
                      Left
                        ( StorageRuntimeFailure
                            (nativeFsFailure problem)
                        )
                    Right bytes -> Right (Just bytes)

nativeWriteWorkspaceFile
  :: FilePath
  -> ConditionalWrite
  -> IO (Either StorageError StorageWriteOutcome)
nativeWriteWorkspaceFile root request =
  catchStorageFailure $ do
    let workspacePath = conditionalWritePath request
        nativePath = resolveWorkspacePath root workspacePath
    safe <- hasNoSymbolicLinkComponents root workspacePath
    if not safe
      then pure (Left (StorageUnsafeFilesystemEntry workspacePath))
      else
        case conditionalWriteExpected request of
          ExpectAbsent ->
            pure
              ( Left
                  (StorageConditionalWriteUnsupported workspacePath)
              )
          ExpectExact expected
            | expected == conditionalWriteValue request -> do
                exists <- doesPathExist nativePath
                if not exists
                  then pure (Left (StorageConflict workspacePath))
                  else do
                    isFile <- doesFileExist nativePath
                    if not isFile
                      then
                        pure
                          (Left (StorageUnsafeFilesystemEntry workspacePath))
                      else do
                        loaded <- nativeReadFile nativeFileSystem nativePath
                        pure $
                          case loaded of
                            Left problem ->
                              Left
                                ( StorageRuntimeFailure
                                    (nativeFsFailure problem)
                                )
                            Right current
                              | current == expected ->
                                  Right StorageUnchanged
                              | otherwise ->
                                  Left (StorageConflict workspacePath)
            | otherwise -> do
                exists <- doesPathExist nativePath
                if not exists
                  then pure (Left (StorageConflict workspacePath))
                  else do
                    isFile <- doesFileExist nativePath
                    if not isFile
                      then
                        pure
                          (Left (StorageUnsafeFilesystemEntry workspacePath))
                      else do
                        saved <-
                          nativeCompareAndReplace
                            nativeFileSystem
                            nativePath
                            expected
                            (conditionalWriteValue request)
                        pure $
                          case saved of
                            Left (NativeSaveConflict _) ->
                              Left (StorageConflict workspacePath)
                            Left (NativeSaveIoError problem) ->
                              Left
                                ( StorageRuntimeFailure
                                    (nativeFsFailure problem)
                                )
                            Right () -> Right StorageWritten

hasNoSymbolicLinkComponents
  :: FilePath
  -> WorkspacePath
  -> IO Bool
hasNoSymbolicLinkComponents root workspacePath =
  go root (toList (workspacePathSegments workspacePath))
  where
    go _ [] = pure True
    go parent (segment : remaining) = do
      let current = parent </> Text.unpack segment
      exists <- doesPathExist current
      if not exists
        then pure True
        else do
          symbolic <- pathIsSymbolicLink current
          if symbolic
            then pure False
            else go current remaining

resolveWorkspacePath :: FilePath -> WorkspacePath -> FilePath
resolveWorkspacePath root workspacePath =
  foldl
    (</>)
    root
    (fmap Text.unpack (toList (workspacePathSegments workspacePath)))

catchStorageFailure
  :: IO (Either StorageError value)
  -> IO (Either StorageError value)
catchStorageFailure action = do
  result <- tryIOError action
  pure $
    case result of
      Left problem ->
        Left
          ( StorageRuntimeFailure
              (RuntimeInfrastructureFailure (Text.pack (show problem)))
          )
      Right value -> value

nativeFsFailure :: NativeFsError -> RuntimeFailure
nativeFsFailure problem =
  RuntimeInfrastructureFailure
    (nativeFsErrorMessage problem)

nativeGitOperationProvision
  :: GitOperation
  -> CapabilityProvision ()
nativeGitOperationProvision operation =
  case operation of
    GitVersionOperation -> CapabilityProvided ()
    GitStatusOperation -> CapabilityProvided ()
    _ ->
      operationUnavailable
        GitCapability
        "The initial native Git bridge supports version and status only"

runNativeGit
  :: FilePath
  -> GitRequest
  -> IO (Either GitError GitResponse)
runNativeGit root request =
  case request of
    GitVersionRequest ->
      fmap
        (fmap GitVersionResponse . mapNativeGitError)
        (nativeGitVersion nativeGit)
    GitStatusRequest ->
      fmap
        ( fmap (GitStatusResponse . gitStatusSnapshot)
            . mapNativeGitError
        )
        (nativeGitStatus nativeGit root)
    _ ->
      pure
        ( Left
            (GitOperationUnsupported (gitRequestOperation request))
        )

mapNativeGitError
  :: Either NativeGitError value
  -> Either GitError value
mapNativeGitError value =
  case value of
    Left (NativeGitLaunchError message) ->
      Left
        ( GitRuntimeFailure
            (RuntimeInfrastructureFailure message)
        )
    Left (NativeGitCommandError code message) ->
      Left
        ( GitRuntimeFailure
            ( RuntimeRejected
                (Text.pack ("git-exit-" <> show code))
                message
            )
        )
    Right result -> Right result

renderNativeLogEntry :: LogEntry -> Text
renderNativeLogEntry entry =
  Text.unwords
    ( [ "[" <> renderNativeLogLevel (logEntryLevel entry) <> "]"
      , logEntryMessage entry
      ]
        <> fmap renderNativeLogField (logEntryFields entry)
    )

renderNativeLogLevel :: LogLevel -> Text
renderNativeLogLevel level =
  case level of
    DebugLog -> "debug"
    InfoLog -> "info"
    WarningLog -> "warn"
    ErrorLog -> "error"

renderNativeLogField :: LogField -> Text
renderNativeLogField field =
  logFieldName field <> "=" <> renderNativeLogValue (logFieldValue field)

renderNativeLogValue :: LogValue -> Text
renderNativeLogValue value =
  case value of
    LogText text -> Text.pack (show text)
    LogInteger integer -> Text.pack (show integer)
    LogBoolean boolean ->
      if boolean then "true" else "false"

unavailable
  :: CapabilityName
  -> Text
  -> CapabilityProvision capability
unavailable capability detail =
  CapabilityUnavailable
    CapabilityAbsence
      { absentCapability = capability
      , capabilityAbsenceReason =
          NotImplementedForTarget detail
      }

operationUnavailable
  :: CapabilityName
  -> Text
  -> CapabilityProvision ()
operationUnavailable = unavailable

toList :: NonEmpty value -> [value]
toList (first :| remaining) = first : remaining
