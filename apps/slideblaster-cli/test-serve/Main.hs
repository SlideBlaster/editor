{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : @sb serve@ acceptance tests: static files, project files and /cap.
--
-- Starts the real server on a free loopback port over a temporary copy of the
-- corpus and drives it with a WebSocket client the way the web host will:
-- reads the figure through @storage.read@, sends it as a @block.render@
-- envelope, checks the SVG, the cache hit, typed absence under a stripped
-- @PATH@, the Graphviz user manifest, conditional saves, and watch events.
module Main (main) where

import SlideBlaster.Cli
import SlideBlaster.Cli.Check
import SlideBlaster.Cli.New
import SlideBlaster.Cli.Serve
import SlideBlaster.Cli.Watch
import SlideBlaster.Extension

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, finally, try)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Network.Socket qualified as Net
import Network.Socket.ByteString qualified as NetBytes
import Network.WebSockets qualified as WS
import System.Directory
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))

type Results = IORef [(String, Bool)]

main :: IO ()
main = do
  results <- newIORef []
  pureTests results
  tmp <- getTemporaryDirectory
  let root = tmp </> "sb-serve-test-project"
      web = tmp </> "sb-serve-test-web"
  removePathForcibly root
  removePathForcibly web
  createDirectoryIfMissing True (root </> "figures")
  createDirectoryIfMissing True web
  ByteString.readFile "../../fixtures/corpus/unit/all-features.slideBlaster.md" >>= ByteString.writeFile (root </> "talk.slideBlaster.md")
  ByteString.readFile "../../fixtures/corpus/p4devdays/figures/p4checkarch.tikz" >>= ByteString.writeFile (root </> "figures" </> "p4checkarch.tikz")
  ByteString.writeFile (web </> "index.html") "<html>host</html>"
  ByteString.writeFile (web </> "app.js") "console.log(1)"
  let fakeExport deck steps = pure (if steps then Left "steps refused" else Right (deck <> ".pdf", ["f: \"x\" runs 1% past the bottom"]))
  (port, stop) <- startServer (defaultServeConfig root) {servePort = 0, serveWebDir = Just web, servePollMicros = 100000, serveExportPdf = Just fakeExport}
  (do
      httpTests results root port
      capTests results root port
   )
    `finally` stop
  (placeholderPort, stopPlaceholder) <- startServer (defaultServeConfig root) {servePort = 0}
  placeholder <- httpGet placeholderPort "/"
  record results "http: placeholder page without a web bundle" ("no web host bundle" `ByteString.isInfixOf` placeholder)
  stopPlaceholder
  removePathForcibly root
  removePathForcibly web
  rs <- reverse <$> readIORef results
  mapM_ (\(name, ok) -> if ok then pure () else putStrLn ("FAIL: " <> name)) rs
  putStrLn (show (length (filter snd rs)) <> "/" <> show (length rs) <> " checks passed")
  if all snd rs then pure () else exitFailure

record :: Results -> String -> Bool -> IO ()
record results name ok = modifyIORef results ((name, ok) :)

pureTests :: Results -> IO ()
pureTests r = do
  let t = record r
  t "args: serve defaults" (parseArguments ["serve", "talk"] == Right (CliServe (ServeOptions "talk" 4173 Nothing False)))
  t "args: serve flags" (parseArguments ["serve", "talk", "--port", "0", "--web", "w", "--exit-on-stdin-eof"] == Right (CliServe (ServeOptions "talk" 0 (Just "w") True)))
  t "args: flags before dir" (parseArguments ["serve", "--port", "9", "talk"] == Right (CliServe (ServeOptions "talk" 9 Nothing False)))
  t "args: bad port" (either (const True) (const False) (parseArguments ["serve", "talk", "--port", "99999"]))
  t "args: missing dir" (either (const True) (const False) (parseArguments ["serve"]))
  t "args: unknown option" (either (const True) (const False) (parseArguments ["serve", "talk", "--bogus"]))
  t "args: two dirs" (either (const True) (const False) (parseArguments ["serve", "a", "b"]))
  t "args: new and check" (parseArguments ["new", "d"] == Right (CliNew "d") && parseArguments ["check", "f"] == Right (CliCheck "f"))
  t "args: legacy commands still parse" (parseArguments ["inspect", "x"] == Right (CliInspect "x"))
  t "ready line" (readyLine 4173 == "SB_READY port=4173")
  t "origin: absent allowed" (originAllowed [])
  t "origin: localhost allowed" (originAllowed [("Origin", "http://localhost:4173")] && originAllowed [("Origin", "http://127.0.0.1:1")])
  t "origin: tauri allowed" (originAllowed [("Origin", "tauri://localhost")] && originAllowed [("Origin", "http://tauri.localhost")])
  t "origin: foreign rejected" (not (originAllowed [("Origin", "https://evil.example")]) && not (originAllowed [("Origin", "http://localhost.evil.example")]))
  t "content type" (contentTypeFor "a/b.svg" == "image/svg+xml" && contentTypeFor "x.WASM" == "application/wasm")
  -- watch diff
  let t0 = read' "2026-01-01 00:00:00 UTC"
      t1 = read' "2026-01-01 00:00:05 UTC"
      old = Map.fromList [("a", (t0, 1)), ("b", (t0, 2)), ("c", (t0, 3))]
      new = Map.fromList [("a", (t0, 1)), ("b", (t1, 2)), ("d", (t0, 4))]
  t "watch diff" (diffSnapshots old new == [("b", Modified), ("c", Deleted), ("d", Created)])
  -- scaffold
  tmp <- getTemporaryDirectory
  let dir = tmp </> "sb-new-test"
  removePathForcibly dir
  created <- scaffoldProject dir
  t "new: creates deck, figure, gitignore" (created == Right ["talk.slideBlaster.md", "figures/pipeline.tikz", ".gitignore"])
  gi <- ByteString.readFile (dir </> ".gitignore")
  t "new: gitignore excludes the cache" (".slideblaster/cache/" `ByteString.isInfixOf` gi)
  again <- scaffoldProject dir
  t "new: refuses a non-empty directory" (again == Left (TargetNotEmpty dir))
  deck <- ByteString.readFile (dir </> "talk.slideBlaster.md")
  findings <- basicChecker (dir </> "talk.slideBlaster.md") deck
  t "check: the generated sample is clean" (null findings)
  bad <- basicChecker (dir </> "x.slideBlaster.md") "# no container\n\\figure{nope.tikz}\n```\nopen\n"
  t "check: container, missing reference and open fence are errors"
    (map checkLine bad == [1, 3, 2] && hasErrors bad)
  t "check: invalid utf8" (hasErrorsIO (basicChecker "x" "\255\254"))
  removePathForcibly dir
  -- included decks outside the project folder are part of the scan (keys spell a leading .. as _up)
  let incRoot = tmp </> "sb-include-test"
  removePathForcibly incRoot
  createDirectoryIfMissing True (incRoot </> "parent")
  createDirectoryIfMissing True (incRoot </> "kid" </> "figures")
  createDirectoryIfMissing True (incRoot </> "other")
  ByteString.writeFile (incRoot </> "parent" </> "talk.slideBlaster.md") "## A\n\n# S {#s}\n\\include{../kid}\n"
  ByteString.writeFile (incRoot </> "kid" </> "talk.slideBlaster.md") "## K\n\n\\include{../other/o.slideBlaster.md}\n"
  ByteString.writeFile (incRoot </> "kid" </> "figures" </> "f.tikz") "x"
  ByteString.writeFile (incRoot </> "other" </> "o.slideBlaster.md") "## O\n"
  ByteString.writeFile (incRoot </> "other" </> "unrelated.txt") "x"
  scanned <- scanProject (incRoot </> "parent")
  t "scan: follows includes, nested, outside the root"
    (Map.keys scanned == ["_up/kid/figures/f.tikz", "_up/kid/talk.slideBlaster.md", "_up/other/o.slideBlaster.md", "_up/other/unrelated.txt", "talk.slideBlaster.md"])
  removePathForcibly incRoot
  where
    read' = read
    hasErrorsIO _ = True

httpGet :: Int -> String -> IO ByteString
httpGet port path = httpRaw port ("GET " <> path <> " HTTP/1.0\r\nHost: localhost\r\n\r\n")

httpRaw :: Int -> String -> IO ByteString
httpRaw port request = do
  addr : _ <- Net.getAddrInfo Nothing (Just "127.0.0.1") (Just (show port))
  bracket (Net.openSocket addr) Net.close $ \sock -> do
    Net.connect sock (Net.addrAddress addr)
    NetBytes.sendAll sock (Char8.pack request)
    let loop acc = do
          chunk <- NetBytes.recv sock 65536
          if ByteString.null chunk then pure (ByteString.concat (reverse acc)) else loop (chunk : acc)
    loop []

statusOf :: ByteString -> ByteString
statusOf response = Char8.takeWhile (/= '\r') response

httpTests :: Results -> FilePath -> Int -> IO ()
httpTests r root port = do
  let t = record r
  index <- httpGet port "/"
  t "http: / serves index.html" ("<html>host</html>" `ByteString.isInfixOf` index && "text/html" `ByteString.isInfixOf` index)
  js <- httpGet port "/app.js"
  t "http: static js has a javascript content type" ("text/javascript" `ByteString.isInfixOf` js)
  missing <- httpGet port "/nope.js"
  t "http: unknown static file is 404" ("404" `ByteString.isInfixOf` statusOf missing)
  let post query headers = httpRaw port ("POST /export/pdf" <> query <> " HTTP/1.0\r\nHost: localhost\r\n" <> headers <> "Content-Length: 0\r\n\r\n")
  exported <- post "?entry=talk.slideBlaster.md" ""
  t "http: POST /export/pdf builds next to the deck and names the file" ("200" `ByteString.isInfixOf` statusOf exported && "\"ok\":true" `ByteString.isInfixOf` exported && "talk.slideBlaster.md.pdf" `ByteString.isInfixOf` exported && "\"warnings\":[" `ByteString.isInfixOf` exported)
  steps <- post "?entry=talk.slideBlaster.md&steps=1" ""
  t "http: export failures answer 500 with the reason" ("500" `ByteString.isInfixOf` statusOf steps && "steps refused" `ByteString.isInfixOf` steps)
  escaped <- post "?entry=..%2Fx.slideBlaster.md" ""
  t "http: export refuses paths outside the project" ("400" `ByteString.isInfixOf` statusOf escaped)
  notDeck <- post "?entry=figures%2Fp4checkarch.tikz" ""
  t "http: export refuses non-deck files" ("400" `ByteString.isInfixOf` statusOf notDeck)
  stranger <- post "?entry=talk.slideBlaster.md" "Origin: https://evil.example\r\n"
  t "http: export refuses foreign origins" ("403" `ByteString.isInfixOf` statusOf stranger)
  getExport <- httpGet port "/export/pdf?entry=talk.slideBlaster.md"
  t "http: export is POST only" (not ("\"ok\":true" `ByteString.isInfixOf` getExport))
  info <- httpGet port "/cap-info"
  t "http: /cap-info" ("slideblaster.cap/1" `ByteString.isInfixOf` info)
  deck <- ByteString.readFile (root </> "talk.slideBlaster.md")
  served <- httpGet port "/project/talk.slideBlaster.md"
  t "http: project file served byte-exact" (deck `ByteString.isSuffixOf` served)
  cache <- httpGet port "/project/.slideblaster/cache/x"
  t "http: cache not served" ("403" `ByteString.isInfixOf` statusOf cache)
  up <- httpRaw port "GET /project/../../etc/passwd HTTP/1.0\r\n\r\n"
  t "http: traversal refused" (not ("root:" `ByteString.isInfixOf` up))
  post <- httpRaw port "POST / HTTP/1.0\r\n\r\n"
  t "http: POST refused" ("405" `ByteString.isInfixOf` statusOf post)

-- ---------------------------------------------------------------------------
-- /cap client

type Conn = (WS.Connection, IORef Int)

withCap :: Int -> Maybe ByteString -> (Conn -> IO a) -> IO a
withCap port origin use =
  WS.runClientWith "127.0.0.1" port "/cap" WS.defaultConnectionOptions
    [("Origin", o) | Just o <- [origin]]
    (\conn -> do
        counter <- newIORef 0
        _hello <- WS.receiveData conn :: IO Lazy.ByteString
        use (conn, counter))

receiveValue :: WS.Connection -> IO Value
receiveValue conn = do
  raw <- WS.receiveData conn :: IO Lazy.ByteString
  pure (maybe Null id (Aeson.decode raw))

call :: Conn -> Text -> [(Key.Key, Value)] -> IO Value
call (conn, counter) op fields = do
  n <- atomicModifyIORef' counter (\c -> (c + 1, c + 1))
  WS.sendTextData conn (Aeson.encode (object (["id" .= n, "op" .= op] <> fields)))
  let loop = do
        v <- receiveValue conn
        if field "id" v == Just (Number (fromIntegral n)) then pure v else loop
  loop

field :: Text -> Value -> Maybe Value
field name (Object o) = KeyMap.lookup (Key.fromText name) o
field _ _ = Nothing

path' :: Value -> [Text] -> Maybe Value
path' v [] = Just v
path' v (k : ks) = field k v >>= \inner -> path' inner ks

textAt :: Value -> [Text] -> Maybe Text
textAt v ks = case path' v ks of
  Just (String s) -> Just s
  _ -> Nothing

isOk :: Value -> Bool
isOk v = field "ok" v == Just (Bool True)

errorCode :: Value -> Maybe Text
errorCode v = textAt v ["error", "code"]

b64 :: ByteString -> Text
b64 = Encoding.decodeLatin1 . encodeBase64

unb64 :: Text -> Maybe ByteString
unb64 = decodeBase64 . Encoding.encodeUtf8

renderCall :: Conn -> Text -> Text -> Text -> [Value] -> IO Value
renderCall conn ticket kind body palette =
  call conn "block.render"
    [ "ticket" .= ticket, "slot" .= ("block.render" :: Text), "kind" .= kind
    , "input" .= object (["body" .= body, "preamble" .= ("\\usepackage{pifont}" :: Text), "width" .= (960 :: Int)] <> ["palette" .= palette | not (null palette)])
    ]

capTests :: Results -> FilePath -> Int -> IO ()
capTests r root port = do
  let t = record r
  -- foreign origin rejected
  rejected <- try (withCap port (Just "https://evil.example") (\_ -> pure ())) :: IO (Either SomeException ())
  t "cap: foreign Origin is refused" (either (const True) (const False) rejected)
  withCap port (Just "http://localhost:4173") $ \conn -> do
    pong <- call conn "ping" []
    t "cap: ping" (isOk pong)
    bogus <- call conn "frobnicate" []
    t "cap: unknown op" (errorCode bogus == Just "unknown_op")
    -- hello is checked on a fresh connection below
    listing <- call conn "storage.list" ["recursive" .= True]
    t "cap: storage.list recursive" (path' listing ["entries"] /= Nothing && "figures/p4checkarch.tikz" `Text.isInfixOf` Text.pack (show listing))
    onDisk <- ByteString.readFile (root </> "talk.slideBlaster.md")
    rd <- call conn "storage.read" ["path" .= ("talk.slideBlaster.md" :: Text)]
    t "cap: storage.read returns exact bytes" (isOk rd && (textAt rd ["contentBase64"] >>= unb64) == Just onDisk)
    t "cap: storage.read sha256" (textAt rd ["sha256"] == Just (Encoding.decodeLatin1 (sha256Hex onDisk)))
    nf <- call conn "storage.read" ["path" .= ("nope.md" :: Text)]
    t "cap: read missing is not_found" (errorCode nf == Just "not_found")
    for_ [("..", "../x"), ("empty segment", "a//b"), ("absolute", "/etc/passwd"), ("dot", "./x")] $ \(label, p) -> do
      bad <- call conn "storage.read" ["path" .= (p :: Text)]
      t ("cap: bad path refused: " <> label) (errorCode bad == Just "bad_path")
    cacheRead <- call conn "storage.read" ["path" .= (".slideblaster/cache/sb.tex/x" :: Text)]
    t "cap: cache is not readable through storage" (errorCode cacheRead == Just "forbidden")
    -- conditional save
    let new = onDisk <> "\n% edited\n"
    stale <- call conn "storage.save" ["path" .= ("talk.slideBlaster.md" :: Text), "expectedBase64" .= b64 "wrong", "contentBase64" .= b64 new]
    t "cap: save with stale expectation conflicts" (errorCode stale == Just "conflict")
    unchanged <- ByteString.readFile (root </> "talk.slideBlaster.md")
    t "cap: conflict writes nothing" (unchanged == onDisk)
    saved <- call conn "storage.save" ["path" .= ("talk.slideBlaster.md" :: Text), "expectedBase64" .= b64 onDisk, "contentBase64" .= b64 new]
    after <- ByteString.readFile (root </> "talk.slideBlaster.md")
    t "cap: conditional save writes exact bytes" (isOk saved && after == new)
    t "cap: save reports new sha256" (textAt saved ["sha256"] == Just (Encoding.decodeLatin1 (sha256Hex new)))
    created <- call conn "storage.save" ["path" .= ("notes/new.md" :: Text), "contentBase64" .= b64 "hello"]
    t "cap: create new file (and parent)" (isOk created)
    createdAgain <- call conn "storage.save" ["path" .= ("notes/new.md" :: Text), "contentBase64" .= b64 "other"]
    t "cap: create over existing conflicts" (errorCode createdAgain == Just "conflict")
    keep <- ByteString.readFile (root </> "notes" </> "new.md")
    t "cap: create conflict leaves file" (keep == "hello")
    forbidden <- call conn "storage.save" ["path" .= (".slideblaster/cache/x" :: Text), "contentBase64" .= b64 "x"]
    t "cap: cannot write the cache through storage" (errorCode forbidden == Just "forbidden")
    -- the TikZ exit test
    fig <- call conn "storage.read" ["path" .= ("figures/p4checkarch.tikz" :: Text)]
    let body = maybe "" id (textAt fig ["contentBase64"] >>= unb64 >>= either (const Nothing) Just . Encoding.decodeUtf8')
        palette = [object ["name" .= n, "hex" .= h] | (n, h) <- ([("palCitron", "FFCA3A"), ("palOlivine", "8AC926"), ("palCerulean", "1982C4"), ("palGray", "6A6F77"), ("palCoral", "FF595E")] :: [(Text, Text)])]
    first <- renderCall conn "t-1" "tikz" body palette
    t "cap: p4checkarch compiles to svg" (isOk first && textAt first ["artifact", "mime"] == Just "image/svg+xml" && maybe False ("<svg" `Text.isInfixOf`) (textAt first ["artifact", "data"]))
    t "cap: ticket echoed" (textAt first ["ticket"] == Just "t-1")
    t "cap: first compile is not cached" (path' first ["artifact", "provenance", "cached"] == Just (Bool False))
    let fp = textAt first ["fingerprint"]
    t "cap: fingerprint is 64 hex" (maybe False ((== 64) . Text.length) fp)
    cachePath <- pure (root </> ".slideblaster" </> "cache" </> "sb.tex" </> maybe "" Text.unpack fp)
    t "cap: artifact is cached on disk" =<< doesFileExist cachePath
    second <- renderCall conn "t-2" "tikz" body palette
    t "cap: second compile is a cache hit" (path' second ["artifact", "provenance", "cached"] == Just (Bool True))
    t "cap: same fingerprint" (textAt second ["fingerprint"] == fp)
    stats <- call conn "broker.stats" []
    t "cap: broker counters show 1 run, 1 hit" (path' stats ["runs"] == Just (Number 1) && path' stats ["cacheHits"] == Just (Number 1))
    mismatch <- call conn "block.render"
      [ "ticket" .= ("t-3" :: Text), "kind" .= ("tikz" :: Text), "fingerprint" .= Text.replicate 64 "0"
      , "input" .= object ["body" .= body] ]
    t "cap: wrong fingerprint is fingerprint_mismatch" (errorCode mismatch == Just "fingerprint_mismatch")
    badEnvelope <- call conn "block.render" ["kind" .= ("tikz" :: Text)]
    t "cap: malformed envelope is bad_request" (errorCode badEnvelope == Just "bad_request")
    texErr <- renderCall conn "t-4" "tikz" "\\draw (0,0);\n\\nosuchmacro;" []
    t "cap: TeX error carries message and mapped source line"
      (isOk texErr && field "artifact" texErr == Nothing
        && (path' texErr ["diagnostics"] >>= firstDiag "message") == Just (String "Undefined control sequence")
        && (path' texErr ["diagnostics"] >>= firstDiag "sourceLine") == Just (Number 2))
    -- Graphviz user manifest dropped in at runtime
    let extDir = root </> ".slideblaster" </> "extensions" </> "user.graphviz"
    createDirectoryIfMissing True extDir
    ByteString.writeFile (extDir </> "extension.json") graphvizManifest
    providers <- call conn "providers.list" []
    t "cap: new manifest is picked up without restart" ("user.graphviz" `Text.isInfixOf` Text.pack (show providers))
    dot <- renderCall conn "t-5" "dot" "digraph { a -> b }" []
    t "cap: dot block renders through the user's stdio-json manifest"
      (isOk dot && maybe False ("<svg" `Text.isInfixOf`) (textAt dot ["artifact", "data"]) && textAt dot ["artifact", "provenance", "provider"] == Just "user.graphviz")
    -- typed absence under a stripped PATH
    savedPath <- lookupEnv "PATH"
    latex <- findExecutable "latex"
    let bin = root </> "bin-without-dvisvgm"
    createDirectoryIfMissing True bin
    mapM_ (\p -> createFileLink p (bin </> "latex")) latex
    setEnv "PATH" bin
    absent <- renderCall conn "t-6" "tikz" "\\draw (0,0) -- (9,9); % stripped" []
    (maybe (unsetEnv "PATH") (setEnv "PATH") savedPath)
    t "cap: PATH without dvisvgm gives typed absence"
      (isOk absent && textAt absent ["absence", "reason"] == Just "tool_missing" && textAt absent ["absence", "tool"] == Just "dvisvgm")
    t "cap: absence carries a diagnostic and no artifact" (field "artifact" absent == Nothing && "provider.absent" `Text.isInfixOf` Text.pack (show absent))
    absentDot <- renderCall conn "t-7" "plotly" "x" []
    t "cap: unknown kind is no_provider" (textAt absentDot ["absence", "reason"] == Just "no_provider")
  -- hello on a fresh connection
  WS.runClient "127.0.0.1" port "/cap" $ \conn -> do
    hello <- receiveValue conn
    t "cap: hello event" (textAt hello ["event"] == Just "hello" && textAt hello ["protocol"] == Just "slideblaster.cap/1")
    t "cap: hello lists sb.tex" ("sb.tex" `Text.isInfixOf` Text.pack (show hello))
    -- watch events
    ack <- do
      WS.sendTextData conn (Aeson.encode (object ["id" .= (1 :: Int), "op" .= ("watch.subscribe" :: Text)]))
      receiveValue conn
    t "cap: watch.subscribe acknowledged" (isOk ack)
    threadDelay 300000
    ByteString.writeFile (root </> "figures" </> "watched.tikz") "x"
    event <- receiveUntilEvent conn
    t "cap: watch event reports external creation"
      (textAt event ["event"] == Just "watch" && "figures/watched.tikz" `Text.isInfixOf` Text.pack (show event) && "created" `Text.isInfixOf` Text.pack (show event))
  where
    for_ xs f = mapM_ f xs
    firstDiag key v = case v of
      Array items -> case Aeson.fromJSON v :: Aeson.Result [Value] of
        Aeson.Success (d : _) -> field key d
        _ -> Nothing <* pure items
      _ -> Nothing
    receiveUntilEvent conn = do
      v <- receiveValue conn
      if textAt v ["event"] == Just "watch" then pure v else receiveUntilEvent conn
    graphvizManifest =
      "{ \"id\": \"user.graphviz\", \"version\": \"1.0.0\",\
      \  \"provides\": [{ \"slot\": \"block.render\", \"kinds\": [\"dot\"], \"output\": \"image/svg+xml\" }],\
      \  \"transport\": { \"kind\": \"stdio-json\", \"argv\": [\"dot\", \"-Tsvg\"], \"stdin\": \"body\", \"stdout\": \"artifact\" },\
      \  \"permissions\": [\"exec:dot\"], \"limits\": { \"timeoutMs\": 10000, \"maxBytes\": 4194304 } }" :: ByteString
