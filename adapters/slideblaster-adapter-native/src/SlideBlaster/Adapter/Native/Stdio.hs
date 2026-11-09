{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Native.Stdio
-- Description : The generic @stdio-json@ transport (child process, no shell).
--
-- Spawns @argv@ directly, writes the block body to standard input and takes
-- standard output as the artifact. A non-zero exit becomes a diagnostic holding
-- the first line of standard error. Limits come from the manifest.
module SlideBlaster.Adapter.Native.Stdio
  ( runStdio
  ) where

import SlideBlaster.Adapter.Native.Process
import SlideBlaster.Adapter.Native.Provider
import SlideBlaster.Extension

import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.Encoding.Error qualified as Encoding
import System.Exit (ExitCode (..))

-- | Run a stdio-json provider for one request. The executable has already been
-- resolved on the search path by the caller.
runStdio :: Text -> FilePath -> StdioSpec -> Limits -> Maybe Int -> BlockRequest -> IO ProviderOutcome
runStdio providerName executable spec limits deadline request = do
  outcome <-
    runLimited
      RunSpec
        { runExecutable = executable
        , runArguments = Text.unpack <$> NonEmpty.tail (stdioArgv spec)
        , runWorkingDirectory = Nothing
        , runStdin = Encoding.encodeUtf8 (requestBody request)
        , runTimeoutMs = maybe (limitTimeoutMs limits) (min (limitTimeoutMs limits)) deadline
        , runMaxStdout = limitMaxBytes limits
        }
  pure $ case outcome of
    RunSpawnFailed why -> ProviderFailed [failure "spawn.failed" why]
    RunTimedOut -> ProviderAbsent (TimedOut providerName (limitTimeoutMs limits))
    RunTooLarge -> ProviderAbsent (LimitExceeded providerName (limitMaxBytes limits))
    RunExited ExitSuccess out _ -> ProviderArtifact out
    RunExited (ExitFailure code) _ err ->
      ProviderFailed
        [ failure
            "provider.error"
            ( case filter (not . Text.null) (Text.strip <$> Text.lines (Encoding.decodeUtf8With Encoding.lenientDecode err)) of
                l : _ -> l
                [] -> providerName <> " exited with status " <> Text.pack (show code)
            )
        ]
  where
    failure code message = Diagnostic SeverityError code message Nothing Nothing Nothing
