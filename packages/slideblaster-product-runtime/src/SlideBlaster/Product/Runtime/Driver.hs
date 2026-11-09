{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.Driver
-- Description : Effect-interpreting server driver for session/1 (native serving).
--
-- Wraps the pure 'Session' in one 'MVar' and interprets the effects a native
-- server can handle itself: project listing, compare-and-replace saves, block
-- rendering through a provider callback, and file-watch notifications. Only the
-- effects the UI must act on (measure, present, ...) are returned. Results that
-- arrive later are pushed through the supplied callback as @view_updated@.
-- 'Capabilities' is a plain record so this module depends on no extension or
-- server package; @sb serve@ adapts its broker and storage to it.
module SlideBlaster.Product.Runtime.Driver
  ( Capabilities (..)
  , SessionDriver
  , newSessionDriver
  , handleSessionFrame
  , driverFileChanged
  ) where

import SlideBlaster.Product.Runtime.Analysis (Analyzer)
import SlideBlaster.Product.Runtime.Session
import SlideBlaster.Protocol.Session

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, void)
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word64)

-- | What the host process supplies. All paths are project-relative.
data Capabilities = Capabilities
  { capListProject :: IO [(Text, ByteString)]
  -- ^ every project file (excluding @.slideblaster/@ and @.git/@)
  , capWriteFile :: Text -> Maybe ByteString -> ByteString -> IO (Either Text ())
  -- ^ path, expected current bytes (Nothing = must not exist), new bytes
  , capRenderBlock :: Value -> IO ProviderOutcome
  -- ^ a @/cap@ @block.render@ request body; never throws for provider faults
  }

data DriverState = DriverState
  { driverSession :: !Session
  , driverOnDisk :: !(Maybe ByteString)
  , driverEntry :: !Text
  }

data SessionDriver = SessionDriver
  { driverCapabilities :: Capabilities
  , driverState :: MVar DriverState
  , driverPush :: ByteString -> IO ()
  }

newSessionDriver :: Capabilities -> Analyzer -> (ByteString -> IO ()) -> IO SessionDriver
newSessionDriver capabilities analyzer push = do
  state <- newMVar (DriverState (newSession analyzer) Nothing "")
  pure (SessionDriver capabilities state push)

-- | Handle one text frame from the UI and return the response frame.
handleSessionFrame :: SessionDriver -> ByteString -> IO ByteString
handleSessionFrame driver frame =
  case decodeSessionRequest frame of
    Left failure -> pure (encodeValue (sessionErrorValue failure))
    Right request
      | internalOnly request -> pure (encodeValue (sessionErrorValue SessionUnknownCommand))
      | otherwise -> do
          filled <- fillProject driver request
          result <- modifyMVar (driverState driver) (\state -> pure (apply state filled))
          case result of
            Left failure -> pure (encodeValue (sessionErrorValue failure))
            Right (kind, effects, session, requests) -> do
              forM_ requests (spawnRender driver)
              (kind', session') <- performStorage driver kind effects session
              let uiEffects = filter uiVisible effects
              -- A fast provider (cache hit) may already have advanced the state and
              -- pushed; answer with the newest view so the reply never regresses it.
              latest <- driverSession <$> readMVar (driverState driver)
              let session'' = if sessionRevision latest == sessionRevision session' then latest else session'
              pure (encodeValue (sessionSuccess kind' uiEffects (viewValue session'')))
  where
    apply state request =
      case runSession (driverSession state) request of
        Left failure -> (state, Left failure)
        Right (session', kind, effects) ->
          let entry = case request of
                OpenProject e _ -> e
                OpenSource _ -> "deck.slideBlaster.md"
                _ -> driverEntry state
              onDisk = case request of
                OpenProject _ files -> lookup entry files
                _ -> driverOnDisk state
           in (state {driverSession = session', driverEntry = entry, driverOnDisk = onDisk}, Right (kind, effects, session', blockRequests effects))

internalOnly :: SessionRequest -> Bool
internalOnly request =
  case request of
    ProviderResult {} -> True
    StorageResult {} -> True
    ProjectFile {} -> True
    _ -> False

uiVisible :: Value -> Bool
uiVisible effect = effectKind effect `notElem` [Just "block.render", Just "storage"]

effectKind :: Value -> Maybe Text
effectKind (Object o) = case KeyMap.lookup "kind" o of
  Just (String kind) -> Just kind
  _ -> Nothing
effectKind _ = Nothing

blockRequests :: [Value] -> [(Word64, Text, Value)]
blockRequests effects =
  [ (ticket, fingerprint, request)
  | Object o <- effects
  , KeyMap.lookup "kind" o == Just (String "block.render")
  , Just (Number t) <- [KeyMap.lookup "ticket" o]
  , Just (String fingerprint) <- [KeyMap.lookup "fingerprint" o]
  , Just request <- [KeyMap.lookup "request" o]
  , let ticket = round t
  ]

-- Open requests with no files: list the project through the capability.
fillProject :: SessionDriver -> SessionRequest -> IO SessionRequest
fillProject driver request =
  case request of
    OpenProject entry [] -> OpenProject entry <$> capListProject (driverCapabilities driver)
    _ -> pure request

spawnRender :: SessionDriver -> (Word64, Text, Value) -> IO ()
spawnRender driver (ticket, fingerprint, request) =
  void . forkIO $ do
    outcome <- try (capRenderBlock (driverCapabilities driver) request)
    let result = case outcome of
          Right value -> value
          Left problem -> ProviderDiagnosticsOutcome [ProviderDiagnostic "error" "provider_error" (shortException problem) Nothing False]
    pushWith driver (ProviderResult ticket fingerprint result) "view_updated"

shortException :: SomeException -> Text
shortException _ = "the provider failed unexpectedly"

-- Run an internal request and push the resulting view to the UI.
pushWith :: SessionDriver -> SessionRequest -> Text -> IO ()
pushWith driver request kind = do
  outcome <- modifyMVar (driverState driver) $ \state ->
    case runSession (driverSession state) request of
      Left _ -> pure (state, Nothing)
      Right (session', _, effects) ->
        pure (state {driverSession = session'}, Just (session', effects))
  case outcome of
    Nothing -> pure ()
    Just (session', effects) -> do
      forM_ (blockRequests effects) (spawnRender driver)
      driverPush driver (encodeValue (sessionSuccess kind (filter uiVisible effects) (viewValue session')))

-- Perform storage effects synchronously; on success feed storage_result back.
performStorage :: SessionDriver -> Text -> [Value] -> Session -> IO (Text, Session)
performStorage driver kind effects session =
  case [(path, bytes, revision) | Object o <- effects, KeyMap.lookup "kind" o == Just (String "storage"), Just (String path) <- [KeyMap.lookup "path" o], Just (String hex) <- [KeyMap.lookup "bytesBase16" o], Just bytes <- [decodeBase16 hex], Just (Number r) <- [KeyMap.lookup "revision" o], let revision = round r] of
    [] -> pure (kind, session)
    ((path, bytes, revision) : _) -> do
      state <- readMVar (driverState driver)
      written <- capWriteFile (driverCapabilities driver) path (driverOnDisk state) bytes
      case written of
        Left _ -> pure ("save_failed", session)
        Right () -> do
          modifyMVar_ (driverState driver) (\s -> pure s {driverOnDisk = Just bytes})
          modifyMVar (driverState driver) $ \s ->
            case runSession (driverSession s) (StorageResult path revision True) of
              Left _ -> pure (s, ("save_failed", driverSession s))
              Right (session', _, _) -> pure (s {driverSession = session'}, ("saved", session'))

-- | Feed a file-watch notification (bytes, or Nothing when deleted) to the core.
-- The deck itself is reloaded only when it has no unsaved edits.
driverFileChanged :: SessionDriver -> Text -> Maybe ByteString -> IO ()
driverFileChanged driver path bytes = do
  state <- readMVar (driverState driver)
  if path == driverEntry state
    then case (bytes, sessionDeckBytes (driverSession state), sessionRevision (driverSession state)) of
      (Just new, Just current, Just revision)
        | Just new == driverOnDisk state -> pure ()
        | new /= current && sessionSaved (driverSession state) == Just revision -> do
            modifyMVar_ (driverState driver) (\s -> pure s {driverOnDisk = Just new})
            pushWith driver (ReplaceSource revision new) "view_updated"
      _ -> pure ()
    else pushWith driver (ProjectFile path bytes) "view_updated"
