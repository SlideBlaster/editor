{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Cli.Serve
-- Description : @sb serve@: static host, @/cap@ WebSocket, optional extra mounts.
--
-- One loopback HTTP server (warp) that
--
--   * serves the packaged web host's static files;
--   * serves read-only raw project files under @/project/<path>@;
--   * answers @GET /cap-info@;
--   * upgrades @/cap@ to the capability and extension envelope
--     (@docs/specs/cap-websocket.md@); and
--   * upgrades any extra mount (for example @/session@, supplied by the
--     integrator) through 'serveMounts'.
--
-- Lifecycle for use as a desktop sidecar: bind port 0 for a free port, print
-- @SB_READY port=NNNN@ on standard output once listening, and stop cleanly on
-- SIGTERM, SIGINT or (with 'serveExitOnStdinEof') end of standard input.
module SlideBlaster.Cli.Serve
  ( ServeConfig (..)
  , WebSocketMount (..)
  , defaultServeConfig
  , runServe
  , startServer
  , serveApplication
  , readyLine
  , contentTypeFor
  , originAllowed
  ) where

import SlideBlaster.Adapter.Native
import SlideBlaster.Cli.Cap
import SlideBlaster.Cli.Watch

import Control.Concurrent (forkIO, killThread, newEmptyMVar, newMVar, takeMVar, threadDelay, tryPutMVar, withMVar)
import Control.Exception (SomeException, finally, handle, try)
import Control.Monad (forever, void, when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as Lazy
import Data.Char (toLower)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.List (isSuffixOf)
import Network.HTTP.Types (Header, hContentType, status200, status400, status403, status404, status405, status500)
import Network.Socket
  ( SockAddr (SockAddrInet)
  , Socket
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
  , bind
  , close
  , defaultProtocol
  , listen
  , setSocketOption
  , socket
  , socketPort
  , tupleToHostAddress
  , Family (AF_INET)
  , withSocketsDo
  )
import Network.Wai (Application, Response, pathInfo, queryString, requestHeaders, requestMethod, responseFile, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.WebSockets qualified as WS
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist)
import System.FilePath (splitDirectories, takeExtension, takeFileName, (</>))
import System.IO (hFlush, hPutStrLn, stderr, stdin, stdout)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)

-- | An extra WebSocket endpoint mounted beside @/cap@.
data WebSocketMount = WebSocketMount
  { mountPath :: !Text
  -- ^ Request path such as @"/session"@.
  , mountHandler :: CapEnv -> WS.PendingConnection -> IO ()
  -- ^ Receives the server environment (project root, broker) and the pending
  -- upgrade (accept or reject it).
  }

-- | Server settings.
data ServeConfig = ServeConfig
  { serveRoot :: !FilePath
  , servePort :: !Int
  -- ^ 0 selects a free port.
  , serveWebDir :: !(Maybe FilePath)
  -- ^ Static host directory; 'Nothing' serves a built-in placeholder page.
  , serveMounts :: ![WebSocketMount]
  , serveExitOnStdinEof :: !Bool
  , serveVersion :: !Text
  , servePollMicros :: !Int
  , serveExportPdf :: !(Maybe (FilePath -> Bool -> IO (Either Text (FilePath, [Text]))))
  -- ^ Behind @POST /export/pdf@: build the PDF of a deck (absolute path, one page per step?) and
  -- return where it was written. 'Nothing' answers 404.
  }

-- | Defaults: free port off, no web directory, no mounts, 400 ms polling.
defaultServeConfig :: FilePath -> ServeConfig
defaultServeConfig root =
  ServeConfig
    { serveRoot = root
    , servePort = 4173
    , serveWebDir = Nothing
    , serveMounts = []
    , serveExitOnStdinEof = False
    , serveVersion = "0.2.0"
    , servePollMicros = 400000
    , serveExportPdf = Nothing
    }

-- | The machine-readable ready line a supervisor waits for.
readyLine :: Int -> String
readyLine port = "SB_READY port=" <> show port

-- | Start the server on a loopback socket and return the bound port with an
-- action that stops it. No signal handlers are installed here.
startServer :: ServeConfig -> IO (Int, IO ())
startServer config = do
  root <- canonicalizePath (serveRoot config)
  rootExists <- doesDirectoryExist root
  if not rootExists
    then ioError (userError ("not a directory: " <> serveRoot config))
    else do
      broker <- newBroker (defaultBrokerConfig root)
      env <- newCapEnv root broker (serveVersion config)
      listener <- bindLoopback (servePort config)
      port <- fromIntegral <$> socketPort listener
      app <- serveApplication config env
      let settings = Warp.setHost "127.0.0.1" (Warp.setPort port Warp.defaultSettings)
      server <- forkIO (Warp.runSettingsSocket settings listener app `finally` close listener)
      let stopServer = do
            killThread server
            void (try (close listener) :: IO (Either SomeException ()))
      pure (port, stopServer)

-- | Run until SIGTERM, SIGINT or (when enabled) end of standard input, printing
-- 'readyLine' once listening.
runServe :: ServeConfig -> IO ()
runServe config = do
  (port, stopServer) <- startServer config
  stop <- newEmptyMVar
  let signalStop = void (tryPutMVar stop ())
  _ <- installHandler sigTERM (Catch signalStop) Nothing
  _ <- installHandler sigINT (Catch signalStop) Nothing
  when (serveExitOnStdinEof config) $ void (forkIO (drainStdin >> signalStop))
  hPutStrLn stderr ("sb serve: project " <> serveRoot config)
  hPutStrLn stderr ("sb serve: http://127.0.0.1:" <> show port <> "/")
  putStrLn (readyLine port)
  hFlush stdout
  takeMVar stop
  stopServer

-- Listen on 127.0.0.1 only; port 0 lets the system choose.
bindLoopback :: Int -> IO Socket
bindLoopback port = withSocketsDo $ do
  sock <- socket AF_INET Stream defaultProtocol
  setSocketOption sock ReuseAddr 1
  bind sock (SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1)))
  listen sock 128
  pure sock

drainStdin :: IO ()
drainStdin = do
  chunk <- try (ByteString.hGetSome stdin 4096) :: IO (Either SomeException ByteString)
  case chunk of
    Right bytes | not (ByteString.null bytes) -> drainStdin
    _ -> pure ()

-- | The WAI application: websockets first, then HTTP.
serveApplication :: ServeConfig -> CapEnv -> IO Application
serveApplication config env = do
  let wsApp pending = routeSocket config env pending
  pure (websocketsOr WS.defaultConnectionOptions wsApp (httpApp config env))

routeSocket :: ServeConfig -> CapEnv -> WS.PendingConnection -> IO ()
routeSocket config env pending
  | not (originAllowed (WS.requestHeaders request)) = WS.rejectRequest pending "origin not allowed"
  | path == "/cap" = capSocket config env pending
  | otherwise = case [m | m <- serveMounts config, mountPath m == path] of
      m : _ -> mountHandler m env pending
      [] -> WS.rejectRequest pending "unknown endpoint"
  where
    request = WS.pendingRequest pending
    path = Text.takeWhile (/= '?') (Encoding.decodeUtf8With (\_ _ -> Just '?') (WS.requestPath request))

-- | Accept a missing @Origin@, or one whose host is loopback (or the desktop
-- shell's webview origin). This blocks cross-site WebSocket hijacking by web
-- pages from other origins.
originAllowed :: [Header] -> Bool
originAllowed headers = case lookup "Origin" headers of
  Nothing -> True
  Just origin ->
    let afterScheme = snd (Char8.breakSubstring "://" origin)
        scheme = fst (Char8.breakSubstring "://" origin)
        host = Char8.takeWhile (\c -> c /= ':' && c /= '/') (Char8.drop 3 afterScheme)
        bracketed = Char8.takeWhile (/= ']') (Char8.drop 3 afterScheme) <> "]"
     in scheme == "tauri"
          || host `elem` ["127.0.0.1", "localhost", "tauri.localhost"]
          || bracketed == "[::1]"

capSocket :: ServeConfig -> CapEnv -> WS.PendingConnection -> IO ()
capSocket config env pending = do
  connection <- WS.acceptRequest pending
  sendLock <- newMVar ()
  let send :: Value -> IO ()
      send value = handle (\closed -> const (pure ()) (closed :: WS.ConnectionException)) . withMVar sendLock $ \_ -> WS.sendTextData connection (Aeson.encode value)
  hello <- helloEvent env
  send hello
  watcher <- newIORef Nothing
  let loop = forever $ do
        message <- WS.receiveData connection :: IO Lazy.ByteString
        case Aeson.decode message of
          Just (Object obj) -> void . forkIO . handle (reportCrash send obj) $ dispatch obj
          _ -> send (errorResponse Null "bad_request" "message must be a JSON object")
      dispatch obj = do
        result <- handleCapRequest env obj
        case result of
          Just response -> send response
          Nothing -> watchOp obj
      watchOp obj = do
        let requestId = maybe Null id (lookupId obj)
        case lookupOp obj of
          Just "watch.subscribe" -> do
            current <- readIORef watcher
            case current of
              Just _ -> pure ()
              Nothing -> do
                tid <- forkIO (watchLoop config env send)
                writeIORef watcher (Just tid)
            send (object ["id" .= requestId, "ok" .= True])
          _ -> do
            current <- readIORef watcher
            mapM_ killThread current
            writeIORef watcher Nothing
            send (object ["id" .= requestId, "ok" .= True])
  handle (\closed -> const (pure ()) (closed :: WS.ConnectionException)) (loop `finally` (readIORef watcher >>= mapM_ killThread))
  where
    lookupId = KeyMap.lookup "id"
    lookupOp obj = case KeyMap.lookup "op" obj of
      Just (String s) -> Just s
      _ -> Nothing

reportCrash :: (Value -> IO ()) -> Aeson.Object -> SomeException -> IO ()
reportCrash send obj problem =
  send (errorResponse (maybe Null id (KeyMap.lookup "id" obj)) "io_error" (Text.pack (show problem)))

watchLoop :: ServeConfig -> CapEnv -> (Value -> IO ()) -> IO ()
watchLoop config env send = do
  initial <- scanSnapshot <$> scanProject (capRoot env)
  go initial
  where
    go previous = do
      threadDelay (servePollMicros config)
      current <- scanSnapshot <$> scanProject (capRoot env)
      let changes = diffSnapshots previous current
      when (not (null changes)) $
        send . object $
          [ "event" .= ("watch" :: Text)
          , "changes" .= [object ["path" .= Text.pack p, "change" .= changeName c] | (p, c) <- changes]
          ]
      go current

httpApp :: ServeConfig -> CapEnv -> Application
httpApp config env request respond
  | requestMethod request == "POST" && pathInfo request == ["export", "pdf"] = exportPdf config env request respond
  | requestMethod request /= "GET" && requestMethod request /= "HEAD" =
      respond (responseLBS status405 [] "method not allowed")
  | otherwise = case pathInfo request of
      ["cap-info"] ->
        respond . responseLBS status200 [(hContentType, "application/json")] . Aeson.encode $
          object ["protocol" .= capProtocol, "root" .= Text.pack (lastSegment (capRealRoot env))]
      ("project" : rest) -> projectFile env (Text.intercalate "/" rest) respond
      segments -> staticFile config segments respond
  where
    lastSegment path = case reverse (splitDirectories path) of
      n : _ -> n
      [] -> path

-- | @POST /export/pdf?entry=<deck path in the project>[&steps=1]@: write @<deck>.pdf@ next to the
-- deck and answer @{"ok":true,"path":...,"name":...,"warnings":[...]}@ (out-of-bounds items) or @{"ok":false,"error":...}@. Same-origin
-- only (the WebSocket origin rule), so another web page cannot make the server write files.
exportPdf :: ServeConfig -> CapEnv -> Application
exportPdf config env request respond = case serveExportPdf config of
  Nothing -> respond (responseLBS status404 [] "not found")
  Just build
    | not (originAllowed (requestHeaders request)) -> respond (responseLBS status403 [] "origin not allowed")
    | otherwise -> case [Encoding.decodeUtf8With lenientDecode v | (k, Just v) <- queryString request, k == "entry"] of
        entry : _
          | Right segments@(_ : _) <- validateProjectPath entry
          , ".slideBlaster.md" `isSuffixOf` last segments -> do
              let deck = foldl (</>) (capRoot env) segments
                  steps = ("steps", Just "1") `elem` queryString request
              exists <- doesFileExist deck
              if not exists
                then answer status404 (Left "no such deck")
                else build deck steps >>= either (answer status500 . Left) (answer status200 . Right)
        _ -> answer status400 (Left "entry must name a .slideBlaster.md file inside the project")
  where
    answer status result =
      respond . responseLBS status [(hContentType, "application/json")] . Aeson.encode $ case result of
        Right (path, warnings) -> object ["ok" .= True, "path" .= Text.pack path, "name" .= Text.pack (takeFileName path), "warnings" .= (warnings :: [Text])]
        Left message -> object ["ok" .= False, "error" .= (message :: Text)]

projectFile :: CapEnv -> Text -> (Response -> IO b) -> IO b
projectFile env relative respond = case validateProjectPath relative of
  Left _ -> respond (responseLBS status403 [] "forbidden")
  Right [] -> respond (responseLBS status404 [] "not found")
  Right segments -> do
    let full = foldl (</>) (capRoot env) segments
    real <- try (canonicalizePath full) :: IO (Either SomeException FilePath)
    isFile <- doesFileExist full
    let rootParts = splitDirectories (capRealRoot env)
    case real of
      Right r
        | isFile && take (length rootParts) (splitDirectories r) == rootParts ->
            respond (responseFile status200 [(hContentType, contentTypeFor full)] full Nothing)
      _ -> respond (responseLBS status404 [] "not found")

staticFile :: ServeConfig -> [Text] -> (Response -> IO b) -> IO b
staticFile config segments respond = case serveWebDir config of
  Nothing
    | null segments -> respond (responseLBS status200 [(hContentType, "text/html; charset=utf-8")] placeholderPage)
    | otherwise -> respond (responseLBS status404 [] "not found")
  Just dir ->
    if any unsafe segments
      then respond (responseLBS status400 [] "bad path")
      else do
        let relative = if null segments then ["index.html"] else Text.unpack <$> segments
            full = foldl (</>) dir relative
        isFile <- doesFileExist full
        if isFile
          then respond (responseFile status200 [(hContentType, contentTypeFor full)] full Nothing)
          else respond (responseLBS status404 [] "not found")
  where
    unsafe s = Text.null s || s == "." || s == ".." || Text.any (\c -> c == '\\' || c == '\0') s

placeholderPage :: Lazy.ByteString
placeholderPage =
  "<!doctype html><meta charset=utf-8><title>SlideBlaster</title>\
  \<h1>sb serve</h1><p>The project is being served, but no web host bundle was found.\
  \ Build <code>hosts/web</code> or pass <code>--web &lt;dir&gt;</code>.\
  \ The capability socket is at <code>/cap</code> (see docs/specs/cap-websocket.md).</p>"

-- | Content type from the file extension.
contentTypeFor :: FilePath -> ByteString
contentTypeFor path = case map toLower (takeExtension path) of
  ".html" -> "text/html; charset=utf-8"
  ".htm" -> "text/html; charset=utf-8"
  ".js" -> "text/javascript; charset=utf-8"
  ".mjs" -> "text/javascript; charset=utf-8"
  ".css" -> "text/css; charset=utf-8"
  ".json" -> "application/json"
  ".map" -> "application/json"
  ".wasm" -> "application/wasm"
  ".svg" -> "image/svg+xml"
  ".png" -> "image/png"
  ".jpg" -> "image/jpeg"
  ".jpeg" -> "image/jpeg"
  ".gif" -> "image/gif"
  ".webp" -> "image/webp"
  ".woff" -> "font/woff"
  ".woff2" -> "font/woff2"
  ".ttf" -> "font/ttf"
  ".otf" -> "font/otf"
  ".pdf" -> "application/pdf"
  ".md" -> "text/markdown; charset=utf-8"
  ".tikz" -> "text/plain; charset=utf-8"
  ".tex" -> "text/plain; charset=utf-8"
  ".bib" -> "text/plain; charset=utf-8"
  ".txt" -> "text/plain; charset=utf-8"
  _ -> "application/octet-stream"
