{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Cli
-- Description : Native CLI parsing and host composition for shared source operations.
--
-- The CLI loads exact bytes through the native adapter and delegates all source
-- operations to the shared protocol. Exact replacement and verified bounded
-- TikZ movement are dry runs unless @--write@ is present; persistence delegates
-- one exact-byte compare/install operation to the native adapter.
module SlideBlaster.Cli
  ( CliCommand (..)
  , CliHooks (..)
  , PersistenceMode (..)
  , ReplaceOptions (..)
  , ServeOptions (..)
  , TikzMoveOptions (..)
  , defaultHooks
  , parseArguments
  , runCli
  , runCliWith
  , usage
  ) where

import SlideBlaster.Cli.Build (BuildOptions (..), BuildTarget (..), buildPdfFile, defaultBuildOutput, runBuild)
import SlideBlaster.Cli.Check (DeckChecker, analysisChecks, basicChecker, hasErrors, renderDiagnostic)
import SlideBlaster.Cli.New (NewError (..), scaffoldProject, sampleDeckName)
import SlideBlaster.Cli.Session (sessionMount)
import SlideBlaster.Product.Runtime.Analysis (Analyzer (..))
import Data.Map.Strict qualified as Map
import SlideBlaster.Cli.Serve
  ( ServeConfig (..)
  , WebSocketMount
  , defaultServeConfig
  , runServe
  )

import Control.Exception (SomeException, try)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Text.IO qualified as Text.IO
import System.Exit (ExitCode (..))
import System.IO (stderr)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Environment (getExecutablePath)
import System.FilePath (takeDirectory, takeFileName, (</>))
import SlideBlaster.Cli.Watch (scanProject)
import Data.ByteString qualified as ByteString
import Data.List (isSuffixOf)
import System.IO.Error (tryIOError)
import Text.Read (readMaybe)
import SlideBlaster.Adapter.Native
  ( NativeFileSystem (..)
  , NativeFsError (..)
  , NativeSaveError (..)
  , loadSnapshot
  , saveSnapshotIfUnchanged
  )
import SlideBlaster.Engine
  ( AppliedExactReplacement
  , AppliedTikzMove
  , ExactReplacementReceipt (receiptChanged)
  , TikzAnalysis (..)
  , TikzIntentError (..)
  , TikzMoveOutcome (..)
  , appliedReplacementReceipt
  , appliedReplacementSnapshot
  , appliedTikzMoveAnalysis
  , appliedTikzMoveOutcome
  , mkTikzMoveIntent
  , tikzAnalysisSnapshot
  )
import SlideBlaster.Protocol
  ( EngineRequest (..)
  , EngineResponse (..)
  , ProtocolError
  , implementationVersion
  , protocolVersion
  , renderEngineResponse
  , renderProtocolError
  , runEngineRequest
  )
import SlideBlaster.Source
  ( SourceBufferSnapshot
  , mkExactReplacement
  , revisionFromWord64
  , snapshotBytes
  , snapshotRevision
  , sourceSpanFromInts
  )

-- | Commands accepted by the native executable.
data CliCommand
  = CliVersion
  | CliHelp
  | CliInspect !FilePath
  | CliReplace !ReplaceOptions
  | CliTikzAnalyze !FilePath
  | CliTikzMove !TikzMoveOptions
  | CliServe !ServeOptions
  | CliNew !FilePath
  | CliCheck !FilePath
  | CliBuild !BuildTarget !FilePath !FilePath !(Maybe FilePath)
  -- ^ target, deck, output file, optional web directory
  deriving (Eq, Show)

-- | Parsed @sb serve@ arguments.
data ServeOptions = ServeOptions
  { serveOptDirectory :: !FilePath
  , serveOptPort :: !Int
  -- ^ 0 selects a free port.
  , serveOptWebDir :: !(Maybe FilePath)
  , serveOptExitOnStdinEof :: !Bool
  }
  deriving (Eq, Show)

-- | Seams the integrating executable can fill without editing this module.
data CliHooks = CliHooks
  { hookMounts :: [WebSocketMount]
  -- ^ Extra WebSocket endpoints for @sb serve@, for example @/session@.
  , hookAnalyzer :: Maybe Analyzer
  -- ^ The deck reader behind @/session@. Without one the endpoint refuses
  -- connections; the integrating executable supplies it.
  , hookChecker :: DeckChecker
  -- ^ The deck checker behind @sb check@.
  }

-- | Built-in behaviour: no extra mounts and the parser-free checker.
defaultHooks :: CliHooks
defaultHooks = CliHooks {hookMounts = [], hookAnalyzer = Nothing, hookChecker = basicChecker}

-- | Parsed arguments for an exact byte-local source replacement.
data ReplaceOptions = ReplaceOptions
  { replacePath :: !FilePath
  , replaceStart :: !Int
  , replaceEnd :: !Int
  , replaceExpected :: !Text
  , replaceValue :: !Text
  , replacePersistence :: !PersistenceMode
  }
  deriving (Eq, Show)

-- | Parsed values for one verified bounded TikZ node move.
data TikzMoveOptions = TikzMoveOptions
  { tikzMovePath :: !FilePath
  , tikzMoveNodeId :: !Text
  , tikzMoveX :: !Text
  , tikzMoveY :: !Text
  , tikzMovePersistence :: !PersistenceMode
  }
  deriving (Eq, Show)

-- | Whether an accepted edit is previewed or conditionally persisted.
data PersistenceMode
  = PreviewOnly
  | PersistChanges
  deriving (Eq, Show)

-- | Parse a complete CLI argument vector without performing effects.
parseArguments :: [Text] -> Either Text CliCommand
parseArguments arguments =
  case arguments of
    ["version"] -> Right CliVersion
    ["--version"] -> Right CliVersion
    ["help"] -> Right CliHelp
    ["--help"] -> Right CliHelp
    ["-h"] -> Right CliHelp
    ["inspect", path] -> Right (CliInspect (Text.unpack path))
    ["replace", path, start, end, expected, value] ->
      parseReplace path start end expected value PreviewOnly
    ["replace", path, start, end, expected, value, "--write"] ->
      parseReplace path start end expected value PersistChanges
    ["tikz", "analyze", path] ->
      Right (CliTikzAnalyze (Text.unpack path))
    ["tikz", "move-node", path, nodeIdentity, xCoordinate, yCoordinate] ->
      parseTikzMove
        path
        nodeIdentity
        xCoordinate
        yCoordinate
        PreviewOnly
    [ "tikz"
      , "move-node"
      , path
      , nodeIdentity
      , xCoordinate
      , yCoordinate
      , "--write"
      ] ->
        parseTikzMove
          path
          nodeIdentity
          xCoordinate
          yCoordinate
          PersistChanges
    ("serve" : rest) -> parseServe rest
    ["new", dir] -> Right (CliNew (Text.unpack dir))
    ["check", path] -> Right (CliCheck (Text.unpack path))
    ("build" : rest) -> parseBuild rest
    [] -> Right CliHelp
    _ -> Left "invalid command or arguments"

parseBuild :: [Text] -> Either Text CliCommand
parseBuild = go Nothing Nothing Nothing Nothing False
  where
    go deck out web target steps arguments = case arguments of
      [] -> case (target, deck) of
        (Nothing, _) -> Left "build needs a target: --html or --pdf"
        (Just _, Nothing) -> Left "build needs a deck file"
        (Just TargetHtml, _) | steps -> Left "--steps only applies to --pdf"
        (Just t, Just d) ->
          let t' = case t of TargetPdf _ -> TargetPdf steps; other -> other
           in Right (CliBuild t' d (maybe (defaultBuildOutput t' d) id out) web)
      "--html" : rest -> pick TargetHtml rest
      "--pdf" : rest -> pick (TargetPdf False) rest
      "--steps" : rest -> go deck out web target True rest
      ["-o"] -> Left "-o needs a file name"
      "-o" : value : rest -> go deck (Just (Text.unpack value)) web target steps rest
      "--web" : value : rest -> go deck out (Just (Text.unpack value)) target steps rest
      flag : _ | "-" `Text.isPrefixOf` flag -> Left ("unknown build option " <> flag)
      value : rest -> case deck of
        Nothing -> go (Just (Text.unpack value)) out web target steps rest
        Just _ -> Left "build takes exactly one deck"
      where
        pick chosen rest = case target of
          Just other | other /= chosen -> Left "build takes one target: --html or --pdf"
          _ -> go deck out web (Just chosen) steps rest

parseServe :: [Text] -> Either Text CliCommand
parseServe = go Nothing (ServeOptions "" 4173 Nothing False)
  where
    go dir options arguments = case arguments of
      [] -> case dir of
        Nothing -> Left "serve requires a project directory"
        Just d -> Right (CliServe options {serveOptDirectory = d})
      "--port" : value : rest -> case readMaybe (Text.unpack value) of
        Just port | port >= 0 && port <= 65535 -> go dir options {serveOptPort = port} rest
        _ -> Left "--port must be an integer from 0 to 65535"
      "--web" : value : rest -> go dir options {serveOptWebDir = Just (Text.unpack value)} rest
      "--exit-on-stdin-eof" : rest -> go dir options {serveOptExitOnStdinEof = True} rest
      flag : _ | "--" `Text.isPrefixOf` flag -> Left ("unknown serve option " <> flag)
      value : rest -> case dir of
        Nothing -> go (Just (Text.unpack value)) options rest
        Just _ -> Left "serve takes exactly one project directory"

-- | Run one native CLI invocation and return its process exit status.
runCli :: NativeFileSystem IO -> [Text] -> IO ExitCode
runCli = runCliWith defaultHooks

-- | 'runCli' with caller-supplied 'CliHooks'.
runCliWith :: CliHooks -> NativeFileSystem IO -> [Text] -> IO ExitCode
runCliWith hooks fileSystem arguments =
  case parseArguments arguments of
    Left problem -> do
      Text.IO.hPutStrLn stderr ("slideblaster: " <> problem)
      Text.IO.hPutStr stderr usage
      pure (ExitFailure 2)
    Right command -> runCommand hooks fileSystem command

-- | Human-readable usage text for the executable.
usage :: Text
usage =
  Text.unlines
    [ "Usage:"
    , "  sb new DIR"
    , "  sb serve DIR [--port N] [--web DIR] [--exit-on-stdin-eof]"
    , "  sb check DECK"
    , "  sb build --html DECK [-o OUT.html] [--web DIR]"
    , "  sb build --pdf DECK [-o OUT.pdf] [--steps] [--web DIR]"
    , "  sb version"
    , "  slideblaster inspect FILE"
    , "  slideblaster replace FILE START END EXPECTED REPLACEMENT [--write]"
    , "  slideblaster tikz analyze FILE"
    , "  slideblaster tikz move-node FILE NODE_ID X Y [--write]"
    , ""
    , "serve starts the local host: static web UI, /cap WebSocket, project files at"
    , "/project/. --port 0 picks a free port; the line SB_READY port=N is printed on"
    , "standard output once listening. It stops on SIGTERM/SIGINT or, with"
    , "--exit-on-stdin-eof, when standard input closes."
    , "build --html writes one offline page: every slide and step with the figures compiled."
    , "build --pdf prints that page with headless Chrome (SB_CHROME, google-chrome, chromium on PATH):"
    , "one page per slide showing its final step; --steps prints one page per overlay step."
    , "START and END are zero-based, half-open byte offsets."
    , "EXPECTED and REPLACEMENT are command-line text encoded as UTF-8."
    , "replace is an exact, checked dry run unless --write is supplied."
    , "tikz move-node is semantically verified and is also a dry run by default."
    ]

parseReplace
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> PersistenceMode
  -> Either Text CliCommand
parseReplace path startText endText expected value persistence = do
  start <- parseNonNegative "START" startText
  end <- parseNonNegative "END" endText
  case sourceSpanFromInts start end of
    Nothing -> Left "START must not follow END"
    Just _ ->
      Right
        ( CliReplace
            ReplaceOptions
              { replacePath = Text.unpack path
              , replaceStart = start
              , replaceEnd = end
              , replaceExpected = expected
              , replaceValue = value
              , replacePersistence = persistence
              }
        )

parseNonNegative :: Text -> Text -> Either Text Int
parseNonNegative label input =
  case readMaybe (Text.unpack input) of
    Just value
      | value >= 0 -> Right value
    _ -> Left (label <> " must be a non-negative decimal integer")

parseTikzMove
  :: Text
  -> Text
  -> Text
  -> Text
  -> PersistenceMode
  -> Either Text CliCommand
parseTikzMove path nodeIdentity xCoordinate yCoordinate persistence = do
  case
      mkTikzMoveIntent
        (revisionFromWord64 0)
        nodeIdentity
        xCoordinate
        yCoordinate
    of
      Left problem -> Left (renderTikzIntentError problem)
      Right _ ->
        Right
          ( CliTikzMove
              TikzMoveOptions
                { tikzMovePath = Text.unpack path
                , tikzMoveNodeId = nodeIdentity
                , tikzMoveX = xCoordinate
                , tikzMoveY = yCoordinate
                , tikzMovePersistence = persistence
                }
          )

renderTikzIntentError :: TikzIntentError -> Text
renderTikzIntentError problem =
  case problem of
    TikzIntentInvalidNodeId _ ->
      "NODE_ID is outside the validated TikZ identifier grammar"
    TikzIntentInvalidX _ ->
      "X is outside the bounded TikZ decimal grammar"
    TikzIntentInvalidY _ ->
      "Y is outside the bounded TikZ decimal grammar"

runCommand :: CliHooks -> NativeFileSystem IO -> CliCommand -> IO ExitCode
runCommand hooks fileSystem command =
  case command of
    CliVersion -> do
      Text.IO.putStrLn ("slideblaster " <> implementationVersion)
      Text.IO.putStrLn ("protocol " <> protocolVersion)
      pure ExitSuccess
    CliHelp -> do
      Text.IO.putStr usage
      pure ExitSuccess
    CliInspect path -> do
      loaded <- loadSnapshot fileSystem path
      case loaded of
        Left problem -> emitNativeFsError problem
        Right snapshot ->
          emitProtocolResult (runEngineRequest (InspectSource snapshot))
    CliReplace options -> runReplacement fileSystem options
    CliTikzAnalyze path -> runTikzAnalysis fileSystem path
    CliTikzMove options -> runTikzMove fileSystem options
    CliServe options -> runServeCommand hooks options
    CliNew dir -> runNew dir
    CliCheck path -> runCheck hooks fileSystem path
    CliBuild target deck out web -> do
      webDir <- maybe findWebDirectory (pure . Just) web
      exe <- takeDirectory <$> getExecutablePath
      runBuild
        (hookAnalyzer hooks)
        BuildOptions
          { buildDeck = deck
          , buildOutput = out
          , buildTarget = target
          , buildThemeDirs = themeDirectories webDir exe
          , buildViewerDirs = viewerDirectories webDir exe
          }

viewerDirectories :: Maybe FilePath -> FilePath -> [FilePath]
viewerDirectories webDir exe =
  maybe [] (\d -> [d </> "dist" </> "offline", d </> "offline"]) webDir <> [exe </> "web" </> "offline", exe </> ".." </> "share" </> "slideblaster" </> "web" </> "offline"]

runServeCommand :: CliHooks -> ServeOptions -> IO ExitCode
runServeCommand hooks options = do
  webDir <- maybe findWebDirectory (pure . Just) (serveOptWebDir options)
  exe <- takeDirectory <$> getExecutablePath
  let themeDirs = themeDirectories webDir exe
      exportPdf deck steps = do
        let output = defaultBuildOutput (TargetPdf steps) deck
        built <-
          buildPdfFile
            (hookAnalyzer hooks)
            BuildOptions
              { buildDeck = deck
              , buildOutput = output
              , buildTarget = TargetPdf steps
              , buildThemeDirs = themeDirs
              , buildViewerDirs = viewerDirectories webDir exe
              }
        pure ((,) output <$> built)
  let config =
        (defaultServeConfig (serveOptDirectory options))
          { servePort = serveOptPort options
          , serveWebDir = webDir
          , serveMounts = hookMounts hooks <> [sessionMount (hookAnalyzer hooks) themeDirs (servePollMicros (defaultServeConfig ""))]
          , serveExitOnStdinEof = serveOptExitOnStdinEof options
          , serveExportPdf = Just exportPdf
          }
  result <- try (runServe config) :: IO (Either SomeException ())
  case result of
    Right () -> pure ExitSuccess
    Left problem -> do
      Text.IO.hPutStrLn stderr ("slideblaster: serve failed: " <> Text.pack (show problem))
      pure (ExitFailure 1)

themeDirectories :: Maybe FilePath -> FilePath -> [FilePath]
themeDirectories webDir exe =
  maybe [] (\d -> [d </> "themes", d </> ".." </> ".." </> "themes", d </> ".." </> ".." </> ".." </> "themes"]) webDir
    <> ["themes", exe </> "themes", exe </> ".." </> "share" </> "slideblaster" </> "themes"]

-- The packaged web host: hosts/web/dist in the working tree, else beside the
-- executable (web/ or ../share/slideblaster/web).
findWebDirectory :: IO (Maybe FilePath)
findWebDirectory = do
  exe <- takeDirectory <$> getExecutablePath
  firstExisting ["hosts/web", "hosts/web/dist", exe </> "web", exe </> ".." </> "share" </> "slideblaster" </> "web"]
  where
    firstExisting [] = pure Nothing
    firstExisting (d : ds) = do
      ok <- doesFileExist (d </> "index.html")
      if ok then pure (Just d) else firstExisting ds

runNew :: FilePath -> IO ExitCode
runNew dir = do
  result <- scaffoldProject dir
  case result of
    Right files -> do
      mapM_ (\f -> Text.IO.putStrLn ("created " <> Text.pack (dir </> f))) files
      Text.IO.putStrLn ("next: sb serve " <> Text.pack dir)
      pure ExitSuccess
    Left problem -> do
      Text.IO.hPutStrLn stderr ("slideblaster: " <> describeNewError problem)
      pure (ExitFailure 1)

describeNewError :: NewError -> Text
describeNewError problem = case problem of
  TargetNotEmpty d -> Text.pack d <> " exists and is not empty"
  TargetIsFile d -> Text.pack d <> " is a file"
  NewIoError d why -> Text.pack d <> ": " <> why

runCheck :: CliHooks -> NativeFileSystem IO -> FilePath -> IO ExitCode
runCheck hooks fileSystem path = do
  isDir <- doesDirectoryExist path
  let deckPath = path
  if isDir
    then do
      Text.IO.hPutStrLn stderr ("slideblaster: " <> Text.pack path <> " is a directory; name a deck such as " <> Text.pack (path </> sampleDeckName))
      pure (ExitFailure 2)
    else do
      loaded <- nativeReadFile fileSystem deckPath
      case loaded of
        Left problem -> emitNativeFsError problem
        Right bytes -> do
          basic <- hookChecker hooks deckPath bytes
          -- the deck's folder as a project (included decks and their files), the deck itself as the entry
          let root = takeDirectory deckPath
              entry = Text.pack (takeFileName deckPath)
          scanned <- scanProject root
          projectFiles <- fmap Map.fromList . fmap concat . mapM (\(key, (real, _)) -> either (const []) (\b -> [(Text.pack key, b)]) <$> tryIOError (ByteString.readFile real)) $ [kv | kv@(key, _) <- Map.toList scanned, any (`isSuffixOf` key) [".slideBlaster.md", ".bib"]]
          let diagnostics = basic <> maybe [] (\a -> analysisChecks bytes (analyzeDeck a (Map.delete entry projectFiles) entry bytes)) (hookAnalyzer hooks)
          mapM_ (Text.IO.putStrLn . renderDiagnostic deckPath) diagnostics
          if hasErrors diagnostics
            then pure (ExitFailure 1)
            else do
              Text.IO.putStrLn (Text.pack deckPath <> ": ok")
              pure ExitSuccess

runReplacement :: NativeFileSystem IO -> ReplaceOptions -> IO ExitCode
runReplacement fileSystem options = do
  loaded <- loadSnapshot fileSystem (replacePath options)
  case loaded of
    Left problem -> emitNativeFsError problem
    Right before ->
      case makeReplacement options before of
        Left problem -> do
          Text.IO.hPutStrLn stderr ("slideblaster: " <> problem)
          pure (ExitFailure 2)
        Right request ->
          case runEngineRequest request of
            Left problem -> do
              Text.IO.hPutStr stderr (renderProtocolError problem)
              pure (ExitFailure 1)
            Right response@(SourceReplaced applied _) ->
              persistOrPreview fileSystem options before applied response
            Right response -> do
              Text.IO.hPutStr stderr (renderEngineResponse response)
              pure (ExitFailure 1)

runTikzAnalysis :: NativeFileSystem IO -> FilePath -> IO ExitCode
runTikzAnalysis fileSystem path = do
  loaded <- loadSnapshot fileSystem path
  case loaded of
    Left problem -> emitNativeFsError problem
    Right snapshot ->
      case runEngineRequest (AnalyzeTikz snapshot) of
        Left problem -> do
          Text.IO.hPutStr stderr (renderProtocolError problem)
          pure (ExitFailure 1)
        Right response@(TikzAnalyzed analysis) -> do
          Text.IO.putStr (renderEngineResponse response)
          case analysis of
            TikzAnalysisReady {} -> pure ExitSuccess
            TikzAnalysisSyntaxOnly {} -> pure (ExitFailure 1)
        Right response -> do
          Text.IO.hPutStr stderr (renderEngineResponse response)
          pure (ExitFailure 1)

runTikzMove :: NativeFileSystem IO -> TikzMoveOptions -> IO ExitCode
runTikzMove fileSystem options = do
  loaded <- loadSnapshot fileSystem (tikzMovePath options)
  case loaded of
    Left problem -> emitNativeFsError problem
    Right before ->
      case makeTikzMove options before of
        Left problem -> do
          Text.IO.hPutStrLn stderr ("slideblaster: " <> problem)
          pure (ExitFailure 2)
        Right request ->
          case runEngineRequest request of
            Left problem -> do
              Text.IO.hPutStr stderr (renderProtocolError problem)
              pure (ExitFailure 1)
            Right response@(TikzNodeMoved applied) ->
              persistTikzMove fileSystem options before applied response
            Right response -> do
              Text.IO.hPutStr stderr (renderEngineResponse response)
              pure (ExitFailure 1)

makeReplacement
  :: ReplaceOptions
  -> SourceBufferSnapshot
  -> Either Text EngineRequest
makeReplacement options snapshot =
  case sourceSpanFromInts (replaceStart options) (replaceEnd options) of
    Nothing -> Left "invalid replacement span"
    Just target ->
      Right
        ( ReplaceSource
            snapshot
            ( mkExactReplacement
                (snapshotRevision snapshot)
                target
                (Text.Encoding.encodeUtf8 (replaceExpected options))
                (Text.Encoding.encodeUtf8 (replaceValue options))
            )
        )

makeTikzMove
  :: TikzMoveOptions
  -> SourceBufferSnapshot
  -> Either Text EngineRequest
makeTikzMove options snapshot =
  case
      mkTikzMoveIntent
        (snapshotRevision snapshot)
        (tikzMoveNodeId options)
        (tikzMoveX options)
        (tikzMoveY options)
    of
      Left problem -> Left (renderTikzIntentError problem)
      Right intent -> Right (MoveTikzNode snapshot intent)

persistOrPreview
  :: NativeFileSystem IO
  -> ReplaceOptions
  -> SourceBufferSnapshot
  -> AppliedExactReplacement
  -> EngineResponse
  -> IO ExitCode
persistOrPreview fileSystem options before applied response =
  persistAcceptedEdit
    fileSystem
    (replacePersistence options)
    (replacePath options)
    before
    (appliedReplacementSnapshot applied)
    (receiptChanged (appliedReplacementReceipt applied))
    response

persistTikzMove
  :: NativeFileSystem IO
  -> TikzMoveOptions
  -> SourceBufferSnapshot
  -> AppliedTikzMove
  -> EngineResponse
  -> IO ExitCode
persistTikzMove fileSystem options before applied response =
  persistAcceptedEdit
    fileSystem
    (tikzMovePersistence options)
    (tikzMovePath options)
    before
    (tikzAnalysisSnapshot (appliedTikzMoveAnalysis applied))
    (appliedTikzMoveOutcome applied == TikzMoveVerifiedChange)
    response

persistAcceptedEdit
  :: NativeFileSystem IO
  -> PersistenceMode
  -> FilePath
  -> SourceBufferSnapshot
  -> SourceBufferSnapshot
  -> Bool
  -> EngineResponse
  -> IO ExitCode
persistAcceptedEdit
  fileSystem
  persistence
  path
  before
  after
  changed
  response =
  case persistence of
    PreviewOnly -> do
      Text.IO.putStr (renderEngineResponse response)
      Text.IO.putStrLn "host.persisted=false"
      pure ExitSuccess
    PersistChanges
      | not changed -> do
          Text.IO.putStr (renderEngineResponse response)
          Text.IO.putStrLn "host.persisted=false"
          pure ExitSuccess
      | otherwise -> do
          saved <-
            saveSnapshotIfUnchanged
              fileSystem
              path
              (snapshotBytes before)
              after
          case saved of
            Left problem -> emitNativeSaveError problem
            Right () -> do
              Text.IO.putStr (renderEngineResponse response)
              Text.IO.putStrLn "host.persisted=true"
              pure ExitSuccess

emitProtocolResult
  :: Either ProtocolError EngineResponse
  -> IO ExitCode
emitProtocolResult result =
  case result of
    Left problem -> do
      Text.IO.hPutStr stderr (renderProtocolError problem)
      pure (ExitFailure 1)
    Right response -> do
      Text.IO.putStr (renderEngineResponse response)
      pure ExitSuccess

emitNativeFsError :: NativeFsError -> IO ExitCode
emitNativeFsError problem = do
  Text.IO.hPutStrLn
    stderr
    ( "slideblaster: "
        <> Text.pack (nativeFsErrorPath problem)
        <> ": "
        <> oneLine (nativeFsErrorMessage problem)
    )
  pure (ExitFailure 1)

emitNativeSaveError :: NativeSaveError -> IO ExitCode
emitNativeSaveError problem = do
  case problem of
    NativeSaveIoError fileSystemProblem -> do
      Text.IO.hPutStrLn
        stderr
        ( "slideblaster: "
            <> pathText (nativeFsErrorPath fileSystemProblem)
            <> ": "
            <> oneLine (nativeFsErrorMessage fileSystemProblem)
        )
    NativeSaveConflict path ->
      Text.IO.hPutStrLn
        stderr
        ( "slideblaster: "
            <> pathText path
            <> ": file changed after it was loaded; refusing to overwrite"
        )
  pure (ExitFailure 1)

pathText :: FilePath -> Text
pathText = Text.pack

oneLine :: Text -> Text
oneLine = Text.map replaceNewline
  where
    replaceNewline character
      | character == '\n' || character == '\r' = ' '
      | otherwise = character
