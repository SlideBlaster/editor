{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Cli.Render
-- Description : @sb render DIR@: compile one figure, without a server.
--
-- Reads one @block.render@ request (the JSON the session core writes into its
-- effect) on standard input and writes the provider outcome on standard output,
-- in the shape of a session/1 @provider_result@ body: exactly one of @artifact@
-- or @diagnostics@. The project directory is where the figure cache lives, so
-- the result is shared with @sb serve@ and @sb build@. An editor whose core
-- runs in its own page uses this as its figure compiler.
module SlideBlaster.Cli.Render
  ( runRender
  , outcomeValue
  ) where

import SlideBlaster.Adapter.Native (defaultBrokerConfig, newBroker)
import SlideBlaster.Cli.Cap (newCapEnv)
import SlideBlaster.Cli.Session (sessionCapabilities)
import SlideBlaster.Product.Runtime.Driver (Capabilities (..))
import SlideBlaster.Protocol.Session
  ( ProviderArtifact (..)
  , ProviderDiagnostic (..)
  , ProviderOutcome (..)
  , encodeBase16
  , encodeValue
  )

import Data.Aeson (Value, eitherDecodeStrict', object, (.=))
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import System.Directory (doesDirectoryExist)
import System.Exit (ExitCode (..))
import System.IO (stdin, stdout)

runRender :: FilePath -> IO ExitCode
runRender root = do
  present <- doesDirectoryExist root
  request <- eitherDecodeStrict' <$> ByteString.hGetContents stdin
  outcome <- case (present, request) of
    (False, _) -> pure (failure "bad_request" "the project directory does not exist")
    (_, Left _) -> pure (failure "bad_request" "standard input is not a JSON block.render request")
    (True, Right value) -> do
      broker <- newBroker (defaultBrokerConfig root)
      env <- newCapEnv root broker "0.2.0"
      capRenderBlock (sessionCapabilities env) value
  ByteString.hPut stdout (encodeValue (outcomeValue outcome))
  pure ExitSuccess
  where
    failure :: Text -> Text -> ProviderOutcome
    failure code message = ProviderDiagnosticsOutcome [ProviderDiagnostic "error" code message Nothing False]

-- | A provider outcome as a @provider_result@ body.
outcomeValue :: ProviderOutcome -> Value
outcomeValue outcome = case outcome of
  ProviderArtifactOutcome artifact ->
    object
      [ "artifact"
          .= object
            [ "mime" .= artifactMime artifact
            , "bytesBase16" .= encodeBase16 (artifactBytes artifact)
            , "width" .= artifactWidth artifact
            , "height" .= artifactHeight artifact
            , "provenance" .= artifactProvenance artifact
            ]
      ]
  ProviderDiagnosticsOutcome diagnostics ->
    object
      [ "diagnostics"
          .= [ object
                 [ "severity" .= providerSeverity d
                 , "code" .= providerCode d
                 , "message" .= providerMessage d
                 , "line" .= providerLine d
                 , "absent" .= providerAbsent d
                 ]
             | d <- diagnostics
             ]
      ]
