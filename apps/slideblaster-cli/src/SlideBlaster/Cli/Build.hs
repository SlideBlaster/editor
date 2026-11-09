{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Cli.Build
-- Description : @sb build --html@ and @--pdf@: a deck and its project to one offline page or a PDF.
--
-- Opens the deck's directory as a project, serves every figure through the same
-- broker @sb serve@ uses, projects every slide and step to session/1 plans
-- ('renderProject') and writes the self-contained page ('exportDeckHtml') with
-- the host's offline viewer and the deck theme's stylesheet inlined. @--pdf@
-- writes the same page in print mode to a scratch directory and has Chrome print it
-- ("SlideBlaster.Cli.Pdf").
module SlideBlaster.Cli.Build
  ( BuildOptions (..)
  , BuildTarget (..)
  , runBuild
  , buildPdfFile
  , defaultBuildOutput
  , themeStylesheet
  ) where

import SlideBlaster.Adapter.Native (defaultBrokerConfig, newBroker)
import SlideBlaster.Cli.Cap (newCapEnv)
import SlideBlaster.Cli.Session (sessionCapabilities, withBundledThemes)
import SlideBlaster.Cli.Pdf (findChrome, printToPdf)
import SlideBlaster.Export.Offline (OfflineAssets (..), OfflinePrint (..), exportDeckHtml, inlineCssUrls)
import SlideBlaster.Extension (encodeBase64)
import SlideBlaster.Product.Runtime.Analysis (Analyzer)
import SlideBlaster.Product.Runtime.Batch (renderProject)
import SlideBlaster.Product.Runtime.Driver (Capabilities (..))

import Control.Exception (SomeException, finally, try)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.Text.IO qualified as Text.IO
import System.Directory (canonicalizePath, doesFileExist, getTemporaryDirectory, removePathForcibly)
import System.Exit (ExitCode (..))
import System.FilePath (makeRelative, normalise, takeDirectory, takeExtension, takeFileName, (</>))
import System.Posix.Temp (mkdtemp)
import System.IO (stderr)

-- | What @sb build@ writes.
data BuildTarget
  = TargetHtml
  | TargetPdf !Bool
  -- ^ PDF; with 'True', one page per overlay step instead of one per slide (its final step)
  deriving (Eq, Show)

data BuildOptions = BuildOptions
  { buildDeck :: !FilePath
  , buildOutput :: !FilePath
  , buildTarget :: !BuildTarget
  , buildThemeDirs :: ![FilePath]
  , buildViewerDirs :: ![FilePath]
  -- ^ directories that may hold @viewer.js@ and @viewer.css@
  }

-- | Output next to the deck: @talk.slideBlaster.md@ becomes @talk.html@ or @talk.pdf@.
defaultBuildOutput :: BuildTarget -> FilePath -> FilePath
defaultBuildOutput target deck =
  case Text.stripSuffix ".slideBlaster.md" (Text.pack deck) of
    Just stem -> Text.unpack stem <> extension
    Nothing -> deck <> extension
  where
    extension = case target of
      TargetHtml -> ".html"
      TargetPdf _ -> ".pdf"

runBuild :: Maybe Analyzer -> BuildOptions -> IO ExitCode
runBuild analyzer options = do
  result <- case buildTarget options of
    TargetHtml -> fmap (const []) <$> buildHtmlFile analyzer options
    TargetPdf _ -> buildPdfFile analyzer options
  case result of
    Left message -> failWith message
    Right warnings -> do
      mapM_ (\w -> Text.IO.hPutStrLn stderr ("warning: out of bounds: " <> w)) warnings
      Text.IO.putStrLn ("wrote " <> Text.pack (buildOutput options))
      pure ExitSuccess

buildHtmlFile :: Maybe Analyzer -> BuildOptions -> IO (Either Text ())
buildHtmlFile analyzer options = do
  page <- renderPage analyzer options Nothing
  traverse (ByteString.writeFile (buildOutput options)) page

-- | Write the deck as a PDF to 'buildOutput': the print-mode page, printed by Chrome. On success,
-- one warning per slide item whose content runs out of its box or off the slide.
buildPdfFile :: Maybe Analyzer -> BuildOptions -> IO (Either Text [Text])
buildPdfFile analyzer options = do
  chrome <- findChrome
  case (chrome, buildTarget options) of
    (Left message, _) -> pure (Left message)
    (Right binary, target) -> do
      page <- renderPage analyzer options (Just (OfflinePrint (target == TargetPdf True)))
      case page of
        Left message -> pure (Left message)
        Right bytes -> do
          temporary <- getTemporaryDirectory
          scratch <- mkdtemp (temporary </> "sb-pdf-")
          let htmlFile = scratch </> "deck.html"
          (ByteString.writeFile htmlFile bytes >> printToPdf binary scratch htmlFile (buildOutput options))
            `finally` (try (removePathForcibly scratch) :: IO (Either SomeException ()))

-- | The offline page for a deck: figures compiled, theme stylesheet inlined, print mode optional.
renderPage :: Maybe Analyzer -> BuildOptions -> Maybe OfflinePrint -> IO (Either Text ByteString)
renderPage Nothing _ _ = pure (Left "no deck analyzer is linked into this sb build")
renderPage (Just analyzer) options printMode = do
  deckPath <- canonicalizePath (buildDeck options)
  present <- doesFileExist deckPath
  if not present
    then pure (Left ("no such deck: " <> Text.pack (buildDeck options)))
    else do
      viewer <- findViewer (buildViewerDirs options)
      case viewer of
        Nothing -> pure (Left "the offline viewer bundle was not found (run `npm run build` in hosts/web, or pass --web DIR)")
        Just (script, style) -> do
          let root = takeDirectory deckPath
              entry = Text.pack (makeRelative root deckPath)
          broker <- newBroker (defaultBrokerConfig root)
          env <- newCapEnv root broker "0.2.0"
          let capabilities = withBundledThemes (buildThemeDirs options) (sessionCapabilities env)
          files <- capListProject capabilities
          if entry `notElem` map fst files
            then pure (Left ("the deck is not readable: " <> Text.pack (takeFileName deckPath)))
            else do
              result <- renderProject analyzer entry files (capRenderBlock capabilities)
              pure $ case result of
                Left problem -> Left ("could not render the deck: " <> Text.pack (show problem))
                Right deck ->
                  Right (exportDeckHtml (OfflineAssets script style (themeStylesheet (Map.fromList files) deck) printMode) deck)

-- | The stylesheet of the deck's theme (@themes/<name>/<css>@ in the project, deck-local or bundled)
-- with every relative @url()@ (fonts, images) inlined as a data URI. Empty when the theme has none.
themeStylesheet :: Map.Map Text ByteString -> Value -> Text
themeStylesheet files deck =
  case themeName of
    Nothing -> ""
    Just name ->
      let dir = "themes/" <> name <> "/"
          cssName = case Map.lookup (dir <> "theme.json") files >>= Aeson.decodeStrict of
            Just (Object o) | Just (String c) <- KeyMap.lookup "css" o -> c
            _ -> "theme.css"
       in maybe "" (inlineCssUrls (dataUri files dir) . decode) (Map.lookup (dir <> cssName) files)
  where
    themeName = case deck of
      Object o | Just (String n) <- KeyMap.lookup "theme" o, Text.all (\c -> c == '-' || c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9']) n -> Just n
      _ -> Nothing
    decode = Encoding.decodeUtf8With lenientDecode

dataUri :: Map.Map Text ByteString -> Text -> Text -> Maybe Text
dataUri files dir path
  | ".." `elem` Text.splitOn "/" path || Text.isPrefixOf "/" path || Text.isInfixOf ":" path = Nothing
  | otherwise = do
      bytes <- Map.lookup (Text.pack (normalise (Text.unpack (dir <> path)))) files
      mime <- lookup (takeExtension (Text.unpack path)) mimes
      Just ("data:" <> mime <> ";base64," <> Encoding.decodeUtf8 (encodeBase64 bytes))
  where
    mimes =
      [ (".woff2", "font/woff2"), (".woff", "font/woff"), (".ttf", "font/ttf"), (".otf", "font/otf")
      , (".png", "image/png"), (".jpg", "image/jpeg"), (".jpeg", "image/jpeg"), (".svg", "image/svg+xml"), (".webp", "image/webp")
      ]

failWith :: Text -> IO ExitCode
failWith message = Text.IO.hPutStrLn stderr ("slideblaster: " <> message) >> pure (ExitFailure 1)

findViewer :: [FilePath] -> IO (Maybe (Text, Text))
findViewer [] = pure Nothing
findViewer (dir : rest) = do
  hasScript <- doesFileExist (dir </> "viewer.js")
  hasStyle <- doesFileExist (dir </> "viewer.css")
  if hasScript && hasStyle
    then do
      script <- ByteString.readFile (dir </> "viewer.js")
      style <- ByteString.readFile (dir </> "viewer.css")
      pure (Just (decode script, decode style))
    else findViewer rest
  where
    decode = Encoding.decodeUtf8With lenientDecode
