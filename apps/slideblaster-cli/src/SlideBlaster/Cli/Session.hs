{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Cli.Session
-- Description : The @/session@ WebSocket: session/1 served natively.
--
-- Adapts the native broker and project storage to the integrator's
-- 'Capabilities' record and runs one 'SessionDriver' per connection. Each text
-- frame from the UI is answered by 'handleSessionFrame'; frames the core pushes
-- on its own (a figure finished, a watched file changed) are sent unsolicited.
-- The mount needs an 'Analyzer' (the deck reader); without one the endpoint
-- refuses the upgrade with an explanatory reason.
module SlideBlaster.Cli.Session
  ( sessionMount
  , sessionCapabilities
  , withBundledThemes
  , svgDimensions
  ) where

import SlideBlaster.Adapter.Native
import SlideBlaster.Cli.Cap
import SlideBlaster.Cli.Serve (WebSocketMount (..))
import SlideBlaster.Cli.Watch
import SlideBlaster.Extension qualified as Ext
import SlideBlaster.Product.Runtime.Analysis (Analyzer)
import SlideBlaster.Product.Runtime.Driver
import SlideBlaster.Product.Runtime.Session (nodeSizesPath)
import SlideBlaster.Protocol.Session qualified as Session

import Control.Concurrent (forkIO, killThread, newMVar, threadDelay, withMVar)
import Control.Exception (finally, handle)
import Control.Monad (forever)
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (isDigit, isSpace)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.Read qualified as TextRead
import Network.WebSockets qualified as WS
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Error (tryIOError)

-- | The @/session@ endpoint backed by the given deck analyzer.
sessionMount :: Maybe Analyzer -> [FilePath] -> Int -> WebSocketMount
sessionMount maybeAnalyzer bundledThemes pollMicros =
  WebSocketMount
    { mountPath = "/session"
    , mountHandler = \env pending -> case maybeAnalyzer of
        Nothing -> WS.rejectRequest pending "no deck analyzer is linked into this sb build"
        Just analyzer -> do
          connection <- WS.acceptRequest pending
          lock <- newMVar ()
          let push bytes = ignoreClosed (withMVar lock (\_ -> WS.sendTextData connection bytes))
          driver <- newSessionDriver (withBundledThemes bundledThemes (sessionCapabilities env)) analyzer push
          watcher <- forkIO (watchProject env pollMicros driver)
          kept <- newIORef Nothing
          ( handle (\closed -> const (pure ()) (closed :: WS.ConnectionException)) . forever $ do
              frame <- WS.receiveData connection :: IO ByteString
              response <- handleSessionFrame driver frame
              push response
              keepNodeSizes env kept driver
            )
            `finally` killThread watcher
    }

-- Write the measured node sizes next to the other caches when they changed, so
-- a later @sb build@ (which has no page to measure with) lays pictures out alike.
keepNodeSizes :: CapEnv -> IORef (Maybe ByteString) -> SessionDriver -> IO ()
keepNodeSizes env kept driver = do
  current <- driverNodeSizesFile driver
  previous <- readIORef kept
  case current of
    Just bytes | current /= previous -> do
      let target = capRoot env </> Text.unpack nodeSizesPath
      written <- tryIOError (createDirectoryIfMissing True (takeDirectory target) >> ByteString.writeFile target bytes)
      either (const (pure ())) (const (writeIORef kept current)) written
    _ -> pure ()

-- A tab that went away is not an error: late pushes to it are dropped quietly.
ignoreClosed :: IO () -> IO ()
ignoreClosed = handle (\closed -> const (pure ()) (closed :: WS.ConnectionException))

-- | Offer what ships with the editor as project files, unless the project
-- provides its own: each directory's files appear under the directory's own
-- name (@.../themes/fns/theme.css@ as @themes/fns/theme.css@,
-- @.../shapes/flowchart.tikz@ as @shapes/flowchart.tikz@).
withBundledThemes :: [FilePath] -> Capabilities -> Capabilities
withBundledThemes [] capabilities = capabilities
withBundledThemes dirs capabilities =
  capabilities
    { capListProject = do
        project <- capListProject capabilities
        bundled <- concat <$> mapM bundledFiles dirs
        let have = Map.fromList [(path, ()) | (path, _) <- project]
        pure (project <> [(path, bytes) | (path, bytes) <- bundled, not (Map.member path have)])
    }

bundledFiles :: FilePath -> IO [(Text, ByteString)]
bundledFiles root = do
  present <- doesDirectoryExist root
  if present then go "" else pure []
  where
    go relative = do
      names <- either (const []) id <$> tryIOError (listDirectory (root </> relative))
      concat <$> mapM (entry relative) names
    entry relative name = do
      let next = if null relative then name else relative </> name
      isDirectory <- doesDirectoryExist (root </> next)
      if isDirectory
        then go next
        else do
          bytes <- tryIOError (ByteString.readFile (root </> next))
          pure (either (const []) (\b -> [(Text.pack (takeFileName root </> next), b)]) bytes)

-- | Storage and rendering for the driver, over the project directory.
sessionCapabilities :: CapEnv -> Capabilities
sessionCapabilities env =
  Capabilities
    { capListProject = listProject env
    , capWriteFile = \path expected bytes -> do
        case validateProjectPath path of
          Left _ -> pure (Left "path is not allowed")
          Right [] -> pure (Left "path is empty")
          Right segments -> do
            result <- saveProjectFile env segments expected bytes
            pure $ case result of
              Right () -> Right ()
              Left SaveConflict -> Left "conflict"
              Left (SaveBadPath _) -> Left "path is not allowed"
              Left (SaveIo why) -> Left why
    , capRenderBlock = renderForSession env
    }

-- Every project file the core may read (not caches, git, or huge files).
listProject :: CapEnv -> IO [(Text, ByteString)]
listProject env = do
  tree <- scanProject (capRoot env)
  -- caches are not project files, except the measured node sizes the core lays pictures out from
  sizes <- tryIOError (ByteString.readFile (capRoot env </> Text.unpack nodeSizesPath))
  files <- fmap (mapMaybe id) . mapM load $ [(path, real) | (path, (real, (_, size))) <- Map.toAscList tree, size <= 16777216]
  pure (files <> either (const []) (\bytes -> [(nodeSizesPath, bytes)]) sizes)
  where
    load (path, real) = do
      bytes <- tryIOError (ByteString.readFile real)
      pure (either (const Nothing) (\b -> Just (Text.pack path, b)) bytes)

renderForSession :: CapEnv -> Value -> IO Session.ProviderOutcome
renderForSession env request = case request of
  Object o ->
    -- The core's fingerprint is not the broker's (the broker adds provider
    -- identity), so the claim is dropped and the broker's own is used.
    let withTicket = KeyMap.insert "ticket" (String "t-session") (KeyMap.delete "fingerprint" o)
     in case Ext.decodeRenderEnvelope withTicket of
          Left err -> pure (failure "bad_request" (Ext.envelopeErrorField err <> ": " <> Ext.envelopeErrorReason err) False)
          Right envelope -> do
            result <- renderBlock (capBroker env) envelope
            pure $ case result of
              Left _ -> failure "fingerprint_mismatch" "fingerprint mismatch" False
              Right rendered -> outcomeOf rendered
  _ -> pure (failure "bad_request" "block.render request must be an object" False)
  where
    failure code message absent =
      Session.ProviderDiagnosticsOutcome [Session.ProviderDiagnostic "error" code message Nothing absent]
    outcomeOf rendered = case Ext.resultOutcome rendered of
      Ext.Rendered artifact ->
        let bytes = Ext.artifactBytes artifact
            (w, h) = svgDimensions (Encoding.decodeUtf8With (\_ _ -> Just '?') bytes)
            prov = Ext.artifactProvenance artifact
         in Session.ProviderArtifactOutcome
              Session.ProviderArtifact
                { Session.artifactMime = Ext.artifactMime artifact
                , Session.artifactBytes = bytes
                , Session.artifactWidth = w
                , Session.artifactHeight = h
                , Session.artifactProvenance = Ext.provenanceProvider prov <> " " <> Ext.provenanceVersion prov
                }
      Ext.Failed -> Session.ProviderDiagnosticsOutcome (diagnostic False <$> Ext.resultDiagnostics rendered)
      Ext.Absent _ -> Session.ProviderDiagnosticsOutcome (diagnostic True <$> Ext.resultDiagnostics rendered)
    diagnostic absent d =
      Session.ProviderDiagnostic
        { Session.providerSeverity = case Ext.diagnosticSeverity d of
            Ext.SeverityError -> "error"
            Ext.SeverityWarning -> "warning"
            Ext.SeverityInfo -> "info"
        , Session.providerCode = Ext.diagnosticCode d
        , Session.providerMessage = Ext.diagnosticMessage d
        , Session.providerLine = fromIntegral <$> Ext.diagnosticSourceLine d
        , Session.providerAbsent = absent
        }

-- | Intrinsic size of an SVG: its @viewBox@, else @width@/@height@ (units
-- stripped). Falls back to 100 by 100 when neither is readable.
svgDimensions :: Text -> (Double, Double)
svgDimensions svg =
  case viewBox of
    Just (w, h) -> (w, h)
    Nothing -> case (attribute "width", attribute "height") of
      (Just w, Just h) -> (w, h)
      _ -> (100, 100)
  where
    root = Text.takeWhile (/= '>') (snd (Text.breakOn "<svg" svg))
    attribute name = case Text.breakOn (name <> "=") root of
      (_, rest) | Text.null rest -> Nothing
      (before, rest)
        | maybe True (\(c, _) -> isSpace c) (lastChar before) ->
            number (Text.drop 1 (Text.drop (Text.length name + 1) rest))
        | otherwise -> Nothing
    lastChar t = case Text.unsnoc t of
      Just (_, c) -> Just (c, ())
      Nothing -> Nothing
    viewBox = case Text.breakOn "viewBox=" root of
      (_, rest) | Text.null rest -> Nothing
      (_, rest) ->
        let quoted = Text.drop 1 (Text.drop 8 rest)
            parts = Text.words (Text.map (\c -> if c == ',' then ' ' else c) (Text.takeWhile (\c -> c /= '\'' && c /= '"') quoted))
         in case mapMaybe (fmap fst . either (const Nothing) Just . TextRead.double) parts of
              [_, _, w, h] | w > 0 && h > 0 -> Just (w, h)
              _ -> Nothing
    number t = case TextRead.double (Text.takeWhile (\c -> isDigit c || c == '.') t) of
      Right (v, _) | v > 0 -> Just v
      _ -> Nothing

-- Feed external edits to the core as they happen.
watchProject :: CapEnv -> Int -> SessionDriver -> IO ()
watchProject env pollMicros driver = do
  initial <- scanProject (capRoot env)
  go initial
  where
    go previous = do
      threadDelay pollMicros
      current <- scanProject (capRoot env)
      let changes = diffSnapshots (scanSnapshot previous) (scanSnapshot current)
      mapM_ (notify current) changes
      go current
    notify current (path, change) = do
      bytes <- case (change, Map.lookup path current) of
        (Deleted, _) -> pure Nothing
        (_, Just (real, _)) -> either (const Nothing) Just <$> tryIOError (ByteString.readFile real)
        (_, Nothing) -> pure Nothing
      driverFileChanged driver (Text.pack path) bytes
