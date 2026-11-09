{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Web.Port
-- Description : Browser host-call interpreters for shared runtime ports.
--
-- This bridge constructs requests only through the existing typed host-call
-- wrappers. The current host supports storage list/read and structured
-- logging. Its legacy plain-text measurer cannot satisfy the render-owned
-- structured-content/resource contract. Conditional exact-byte writes and all
-- other ports are advertised as unavailable rather than approximated.
module SlideBlaster.Adapter.Web.Port
  ( webStorageProvision
  , webGitProvision
  , webMeasurementProvision
  , webPresenterWindowProvision
  , webPresenterChannelProvision
  , webDownloadProvision
  , webPrintProvision
  , webArchiveProvision
  , webCompilerProvision
  , webClockProvision
  , webLogProvision
  ) where

import SlideBlaster.Adapter.Web.HostCall
  ( HostClient
  , HostError (..)
  )
import SlideBlaster.Adapter.Web.Log qualified as WebLog
import SlideBlaster.Adapter.Web.Storage qualified as WebStorage
import SlideBlaster.Ports

import Data.Aeson
  ( Value
  , object
  , toJSON
  , (.=)
  )
import Data.Aeson.Key qualified as AesonKey
import Data.ByteString (ByteString)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding

-- | Supply the host's real list/read subset.
--
-- The legacy @storage.write@ operation is intentionally not called: it is an
-- unconditional UTF-16-string write and therefore cannot satisfy the exact
-- expected-content contract.
webStorageProvision
  :: HostClient
  -> WorkspaceId
  -> CapabilityProvision (StoragePort IO)
webStorageProvision client workspace =
  CapabilityProvided
    StoragePort
      { storageWorkspaceId = workspace
      , storageArbitraryBytesSupport =
          operationUnavailable
            WorkspaceStorageCapability
            "storage.readBytes is absent from host protocol v1"
      , storageCreateSupport =
          operationUnavailable
            WorkspaceStorageCapability
            "storage.writeConditional is absent from host protocol v1"
      , storageReplaceSupport =
          operationUnavailable
            WorkspaceStorageCapability
            "storage.writeConditional is absent from host protocol v1"
      , storageListFiles = webListFiles client
      , storageReadFile = webReadFile client
      , storageWriteFile = \request ->
          pure
            ( Left
                ( StorageConditionalWriteUnsupported
                    (conditionalWritePath request)
                )
            )
      }

webGitProvision :: CapabilityProvision (GitPort IO)
webGitProvision =
  hostUnavailable
    GitCapability
    "git"

-- | Fail closed because host protocol v1's plain-text measurer cannot consume
-- structured RenderContent or install its exact embedded font resources.
webMeasurementProvision
  :: CapabilityProvision (MeasurementPort IO)
webMeasurementProvision =
  hostUnavailable
    MeasurementCapability
    "measure.render-content"

webPresenterWindowProvision
  :: CapabilityProvision (PresenterWindowPort IO)
webPresenterWindowProvision =
  hostUnavailable
    PresenterWindowCapability
    "presenter.window"

webPresenterChannelProvision
  :: CapabilityProvision (PresenterChannelPort IO)
webPresenterChannelProvision =
  hostUnavailable
    PresenterChannelCapability
    "presenter.channel"

webDownloadProvision
  :: CapabilityProvision (DownloadPort IO)
webDownloadProvision =
  hostUnavailable
    DownloadCapability
    "download.deliver"

webPrintProvision :: CapabilityProvision (PrintPort IO)
webPrintProvision =
  hostUnavailable
    PrintCapability
    "print.execute"

webArchiveProvision :: CapabilityProvision (ArchivePort IO)
webArchiveProvision =
  hostUnavailable
    ArchiveCapability
    "archive.compress"

webCompilerProvision :: CapabilityProvision (CompilerPort IO)
webCompilerProvision =
  hostUnavailable
    CompilerCapability
    "compile.run"

webClockProvision :: CapabilityProvision (ClockPort IO)
webClockProvision =
  hostUnavailable
    ClockCapability
    "clock.monotonic"

-- | Supply the real versioned structured-log host call.
webLogProvision
  :: HostClient
  -> CapabilityProvision (LogPort IO)
webLogProvision client =
  CapabilityProvided
    LogPort
      { writeLogEntry = \entry -> do
          result <-
            WebLog.writeLog
              client
              (webLogLevel (logEntryLevel entry))
              (logEntryMessage entry)
              (logContext (logEntryFields entry))
          pure $
            case result of
              Left problem ->
                Left (LogRuntimeFailure (hostRuntimeFailure problem))
              Right () -> Right ()
      }

webListFiles
  :: HostClient
  -> IO (Either StorageError [WorkspacePath])
webListFiles client = do
  result <- WebStorage.listPaths client
  pure $
    case result of
      Left problem ->
        Left (StorageRuntimeFailure (hostRuntimeFailure problem))
      Right paths ->
        fmap (sortOn workspacePathText)
          (traverse validateHostPath paths)

webReadFile
  :: HostClient
  -> WorkspacePath
  -> IO (Either StorageError (Maybe ByteString))
webReadFile client path = do
  result <-
    WebStorage.readText client (workspacePathText path)
  pure $
    case result of
      Left problem ->
        Left (StorageRuntimeFailure (hostRuntimeFailure problem))
      Right contents ->
        Right (TextEncoding.encodeUtf8 <$> contents)

validateHostPath :: Text -> Either StorageError WorkspacePath
validateHostPath value =
  case mkWorkspacePath value of
    Left problem -> Left (StorageHostReturnedInvalidPath problem)
    Right path -> Right path

webLogLevel :: LogLevel -> WebLog.LogLevel
webLogLevel level =
  case level of
    DebugLog -> WebLog.Debug
    InfoLog -> WebLog.Info
    WarningLog -> WebLog.Warning
    ErrorLog -> WebLog.Error

logContext :: [LogField] -> Value
logContext fields =
  object
    ( fmap
        ( \field ->
            AesonKey.fromText (logFieldName field)
              .= logValueJSON (logFieldValue field)
        )
        fields
    )

logValueJSON :: LogValue -> Value
logValueJSON value =
  case value of
    LogText text -> toJSON text
    LogInteger integer -> toJSON integer
    LogBoolean boolean -> toJSON boolean

hostRuntimeFailure :: HostError -> RuntimeFailure
hostRuntimeFailure problem =
  case problem of
    HostUnavailable message -> RuntimeUnavailable message
    HostProtocolError message -> RuntimeProtocolFailure message
    HostRejected code message -> RuntimeRejected code message

hostUnavailable
  :: CapabilityName
  -> Text
  -> CapabilityProvision capability
hostUnavailable capability operation =
  CapabilityUnavailable
    CapabilityAbsence
      { absentCapability = capability
      , capabilityAbsenceReason =
          HostOperationMissing operation
      }

operationUnavailable
  :: CapabilityName
  -> Text
  -> CapabilityProvision ()
operationUnavailable capability detail =
  CapabilityUnavailable
    CapabilityAbsence
      { absentCapability = capability
      , capabilityAbsenceReason =
          HostOperationMissing detail
      }
