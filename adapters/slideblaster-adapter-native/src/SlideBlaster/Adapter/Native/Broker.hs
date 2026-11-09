{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Native.Broker
-- Description : Native block.render broker: registry, tools, cache, providers.
--
-- Given a 'RenderEnvelope' the broker finds the provider for the block kind,
-- computes (or verifies) the fingerprint, answers from the project cache
-- (@.slideblaster/cache/<provider>/<fingerprint>@) when it can, and otherwise
-- runs the provider under its limits. A missing tool, provider, timeout or
-- oversized output is typed absence and is never cached; a provider failure is
-- diagnostics and is never cached; only successful artifacts are cached.
-- Manifests are reloaded on demand so a dropped @extension.json@ is picked up
-- without a restart. Counters record requests, cache hits and process runs.
module SlideBlaster.Adapter.Native.Broker
  ( Broker
  , BrokerConfig (..)
  , BrokerError (..)
  , BrokerStats (..)
  , ProviderInfo (..)
  , newBroker
  , renderBlock
  , listProviders
  , brokerStats
  , brokerProblems
  , defaultBrokerConfig
  ) where

import SlideBlaster.Adapter.Native.Extensions
import SlideBlaster.Adapter.Native.Process (findTool)
import SlideBlaster.Adapter.Native.Provider
import SlideBlaster.Adapter.Native.Sanitize (sanitizeSvg)
import SlideBlaster.Adapter.Native.Stdio (runStdio)
import SlideBlaster.Adapter.Native.Tex
import SlideBlaster.Extension

import Control.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.IORef
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.Encoding.Error qualified as Encoding
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getFileSize
  , getTemporaryDirectory
  , renameFile
  )
import System.Environment (lookupEnv)
import System.FilePath (splitSearchPath, takeDirectory, (</>))
import System.IO.Error (tryIOError)

-- | How to build a broker.
data BrokerConfig = BrokerConfig
  { configProjectRoot :: !FilePath
  , configSearchPath :: !(Maybe [FilePath])
  -- ^ Tool directories; 'Nothing' reads @PATH@ at each lookup.
  , configTempRoot :: !(Maybe FilePath)
  -- ^ Scratch root for TeX runs; defaults to the system temp directory.
  , configUserExtensions :: !Bool
  -- ^ Whether to read user-level manifests.
  , configMaxConcurrentRuns :: !Int
  }

-- | Project root with defaults (PATH lookup, system temp, user manifests, two runs).
defaultBrokerConfig :: FilePath -> BrokerConfig
defaultBrokerConfig root =
  BrokerConfig
    { configProjectRoot = root
    , configSearchPath = Nothing
    , configTempRoot = Nothing
    , configUserExtensions = True
    , configMaxConcurrentRuns = 2
    }

-- | A broker instance.
data Broker = Broker
  { brokerConfig :: !BrokerConfig
  , brokerCounters :: !(IORef BrokerStats)
  , brokerRuns :: !QSem
  , brokerLastProblems :: !(IORef [ManifestProblem])
  }

-- | Counters since the broker started.
data BrokerStats = BrokerStats
  { statsRequests :: !Int
  , statsCacheHits :: !Int
  , statsRuns :: !Int
  }
  deriving (Eq, Show)

-- | Request rejected before any provider ran.
data BrokerError
  = FingerprintMismatch !Fingerprint !Fingerprint
  -- ^ Claimed, then computed.
  deriving (Eq, Show)

-- | A provider as listed to hosts.
data ProviderInfo = ProviderInfo
  { infoManifest :: !Manifest
  , infoAvailable :: !Bool
  , infoMissingTools :: ![Text]
  }

-- | Create a broker.
newBroker :: BrokerConfig -> IO Broker
newBroker config = do
  counters <- newIORef (BrokerStats 0 0 0)
  sem <- newQSem (max 1 (configMaxConcurrentRuns config))
  problems <- newIORef []
  pure Broker {brokerConfig = config, brokerCounters = counters, brokerRuns = sem, brokerLastProblems = problems}

-- | Current counters.
brokerStats :: Broker -> IO BrokerStats
brokerStats = readIORef . brokerCounters

-- | Manifest problems seen by the latest load.
brokerProblems :: Broker -> IO [ManifestProblem]
brokerProblems = readIORef . brokerLastProblems

loadRegistry :: Broker -> IO Registry
loadRegistry broker = do
  loaded <-
    if configUserExtensions (brokerConfig broker)
      then loadAllManifests (configProjectRoot (brokerConfig broker))
      else do
        workspace <- loadManifestDirectory (configProjectRoot (brokerConfig broker) </> ".slideblaster" </> "extensions")
        pure workspace {loadedManifests = loadedManifests workspace <> [builtinTexManifest]}
  writeIORef (brokerLastProblems broker) (loadedProblems loaded)
  pure (mkRegistry (loadedManifests loaded))

searchDirs :: Broker -> IO [FilePath]
searchDirs broker = case configSearchPath (brokerConfig broker) of
  Just dirs -> pure dirs
  Nothing -> maybe [] splitSearchPath <$> lookupEnv "PATH"

-- | All providers with tool availability, in priority order.
listProviders :: Broker -> IO [ProviderInfo]
listProviders broker = do
  registry <- loadRegistry broker
  dirs <- searchDirs broker
  mapM (describe dirs) (registryManifests registry)
  where
    describe dirs manifest = do
      missing <- missingTools dirs manifest
      pure (ProviderInfo manifest (null missing) missing)

missingTools :: [FilePath] -> Manifest -> IO [Text]
missingTools dirs manifest = do
  found <- mapM (\tool -> (,) tool <$> findTool dirs (Text.unpack tool)) (requiredTools manifest)
  pure [tool | (tool, Nothing) <- found]

-- Tools to check: the manifest's needs, plus argv[0] for stdio transports.
requiredTools :: Manifest -> [Text]
requiredTools manifest = case manifestTransport manifest of
  StdioJson spec -> let t = NonEmpty.head (stdioArgv spec) in manifestTools manifest <> [t | t `notElem` manifestTools manifest]
  _ -> manifestTools manifest

bump :: Broker -> (BrokerStats -> BrokerStats) -> IO ()
bump broker = modifyIORef' (brokerCounters broker)

-- | Serve one @block.render@ envelope.
renderBlock :: Broker -> RenderEnvelope -> IO (Either BrokerError RenderResult)
renderBlock broker envelope = do
  bump broker (\s -> s {statsRequests = statsRequests s + 1})
  registry <- loadRegistry broker
  case lookupProvider BlockRender kind registry of
    Nothing -> pure (Right (absentResult (requestFingerprint noProvider request) (NoProvider kind)))
    Just manifest -> do
      let identity = providerIdentity manifest
          computed = requestFingerprint identity request
      case envelopeFingerprint envelope of
        Just claimed | claimed /= computed -> pure (Left (FingerprintMismatch claimed computed))
        _ -> Right <$> serve manifest identity computed
  where
    request = envelopeRequest envelope
    kind = requestKind request
    ticket = envelopeTicket envelope
    noProvider = ProviderIdentity "none" "0"
    absentResult fp absence =
      RenderResult ticket fp (Absent absence) [absenceDiagnostic absence]
    failedResult fp diags = RenderResult ticket fp Failed diags

    serve manifest identity fp = do
      let config = brokerConfig broker
          limits = manifestLimits manifest
          cachePath = foldl (</>) (configProjectRoot config) (Text.unpack <$> cacheSegments identity fp)
          mime = maybe "application/octet-stream" id (outputMime manifest)
          provenance cached elapsed =
            Provenance (manifestId manifest) (manifestVersion manifest) cached elapsed
      cached <- readCache cachePath (limitMaxBytes limits)
      case cached of
        Just bytes -> do
          bump broker (\s -> s {statsCacheHits = statsCacheHits s + 1})
          pure (RenderResult ticket fp (Rendered (Artifact mime bytes (provenance True 0))) [])
        Nothing -> do
          dirs <- searchDirs broker
          missing <- missingTools dirs manifest
          case missing of
            tool : _ -> pure (absentResult fp (ToolMissing (manifestId manifest) tool))
            [] -> do
              start <- getMonotonicTimeNSec
              outcome <- withRunSlot broker $ do
                bump broker (\s -> s {statsRuns = statsRuns s + 1})
                runProvider broker manifest dirs envelope
              end <- getMonotonicTimeNSec
              let elapsed = fromIntegral ((end - start) `div` 1000000)
              case outcome of
                ProviderAbsent absence -> pure (absentResult fp absence)
                ProviderFailed diags -> pure (failedResult fp diags)
                ProviderArtifact raw -> do
                  let bytes = finalise mime raw
                  if ByteString.length bytes > limitMaxBytes limits
                    then pure (absentResult fp (LimitExceeded (manifestId manifest) (limitMaxBytes limits)))
                    else do
                      writeCache cachePath bytes
                      pure (RenderResult ticket fp (Rendered (Artifact mime bytes (provenance False elapsed))) [])

-- SVG output is always sanitised, whichever provider produced it.
finalise :: Text -> ByteString -> ByteString
finalise mime raw
  | mime == "image/svg+xml" = Encoding.encodeUtf8 (sanitizeSvg (Encoding.decodeUtf8With Encoding.lenientDecode raw))
  | otherwise = raw

outputMime :: Manifest -> Maybe Text
outputMime manifest =
  case [o | p <- NonEmpty.toList (manifestProvides manifest), provideSlot p == BlockRender, Just o <- [provideOutput p]] of
    o : _ -> Just o
    [] -> Nothing

withRunSlot :: Broker -> IO a -> IO a
withRunSlot broker = bracket_ (waitQSem (brokerRuns broker)) (signalQSem (brokerRuns broker))

runProvider :: Broker -> Manifest -> [FilePath] -> RenderEnvelope -> IO ProviderOutcome
runProvider broker manifest dirs envelope = do
  let request = envelopeRequest envelope
      limits = manifestLimits manifest
      budget = maybe (limitTimeoutMs limits) (min (limitTimeoutMs limits)) (envelopeDeadlineMs envelope)
  case manifestTransport manifest of
    BuiltinNative
      | manifestId manifest == "sb.tex" -> do
          latex <- findTool dirs "latex"
          dvisvgm <- findTool dirs "dvisvgm"
          tmp <- maybe getTemporaryDirectory pure (configTempRoot (brokerConfig broker))
          case (latex, dvisvgm) of
            (Just l, Just d) ->
              runTex
                TexConfig
                  { texLatex = l
                  , texDvisvgm = d
                  , texTempRoot = tmp
                  , texTimeoutMs = budget
                  , texMaxBytes = limitMaxBytes limits
                  }
                request
            (Nothing, _) -> pure (ProviderAbsent (ToolMissing (manifestId manifest) "latex"))
            (_, Nothing) -> pure (ProviderAbsent (ToolMissing (manifestId manifest) "dvisvgm"))
      | otherwise -> pure (ProviderAbsent (NoProvider (requestKind request)))
    BuiltinHost -> pure (ProviderAbsent (NoProvider (requestKind request)))
    StdioJson spec -> do
      let exe = NonEmpty.head (stdioArgv spec)
      found <- findTool dirs (Text.unpack exe)
      case found of
        Nothing -> pure (ProviderAbsent (ToolMissing (manifestId manifest) exe))
        Just path -> runStdio (manifestId manifest) path spec limits (Just budget) request

readCache :: FilePath -> Int -> IO (Maybe ByteString)
readCache path maxBytes = do
  present <- doesFileExist path
  if not present
    then pure Nothing
    else do
      size <- tryIOError (getFileSize path)
      case size of
        Right n | fromIntegral n <= maxBytes -> either (const Nothing) Just <$> tryIOError (ByteString.readFile path)
        _ -> pure Nothing

-- Write through a temporary sibling so a crash never leaves a torn artifact.
writeCache :: FilePath -> ByteString -> IO ()
writeCache path bytes = do
  _ <- tryIOError $ do
    createDirectoryIfMissing True (takeDirectory path)
    now <- getMonotonicTimeNSec
    let temp = path <> "." <> show now <> ".tmp"
    ByteString.writeFile temp bytes
    renameFile temp path
  pure ()
