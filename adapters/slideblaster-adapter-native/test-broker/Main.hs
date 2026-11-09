{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Broker, sb.tex, stdio-json and SVG sanitiser acceptance tests.
--
-- Runs the real @latex@, @dvisvgm@ and @dot@ tools against the corpus. Covers
-- the milestone-W exit criteria owned by lane B: a TikZ figure compiles to SVG,
-- the second identical request is a cache hit, a stripped @PATH@ gives typed
-- absence, and a user-written Graphviz manifest renders a @dot@ block.
module Main (main) where

import SlideBlaster.Adapter.Native
import SlideBlaster.Extension

import Control.Exception (bracket)
import Data.ByteString qualified as ByteString
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import System.Directory
import System.Exit (exitFailure)
import System.FilePath ((</>))

type Results = IORef [(String, Bool)]

main :: IO ()
main = do
  results <- newIORef []
  sanitizerTests results
  withProject $ \root -> do
    texTests results root
    graphvizTests results root
    limitTests results root
    absenceTests results root
  rs <- reverse <$> readIORef results
  mapM_ (\(name, ok) -> if ok then pure () else putStrLn ("FAIL: " <> name)) rs
  putStrLn (show (length (filter snd rs)) <> "/" <> show (length rs) <> " checks passed")
  if all snd rs then pure () else exitFailure

isRendered :: Either e RenderResult -> Bool
isRendered (Right res) = case resultOutcome res of
  Rendered _ -> True
  _ -> False
isRendered (Left _) = False

isCached :: Either e RenderResult -> Bool
isCached (Right res) = case resultOutcome res of
  Rendered a -> provenanceCached (artifactProvenance a)
  _ -> False
isCached (Left _) = False

timedOut :: Either e RenderResult -> Bool
timedOut r = case absenceOf r of
  Just (TimedOut _ _) -> True
  _ -> False

absenceOf :: Either e RenderResult -> Maybe Absence
absenceOf (Right res) = case resultOutcome res of
  Absent a -> Just a
  _ -> Nothing
absenceOf (Left _) = Nothing

record :: Results -> String -> Bool -> IO ()
record results name ok = modifyIORef results ((name, ok) :)

withProject :: (FilePath -> IO a) -> IO a
withProject use = do
  tmp <- getTemporaryDirectory
  let root = tmp </> "sb-broker-test-project"
  bracket
    (removePathForcibly root >> createDirectoryIfMissing True root >> pure root)
    removePathForcibly
    use

sanitizerTests :: Results -> IO ()
sanitizerTests r = do
  let t name input expected = record r ("sanitize: " <> name) (sanitizeSvg input == expected)
      has name input needle present = record r ("sanitize: " <> name) (Text.isInfixOf needle (sanitizeSvg input) == present)
  t "clean svg is untouched" "<svg xmlns='http://www.w3.org/2000/svg'><path d='M0 0'/></svg>" "<svg xmlns='http://www.w3.org/2000/svg'><path d='M0 0'/></svg>"
  has "script element removed" "<svg><script>alert(1)</script><g/></svg>" "script" False
  has "script content removed" "<svg><script>alert(1)</script><g/></svg>" "alert" False
  has "sibling kept after script" "<svg><script>x</script><g/></svg>" "<g/>" True
  has "foreignObject removed" "<svg><foreignObject><div onclick='x'>hi</div></foreignObject></svg>" "div" False
  has "onload attribute removed" "<svg onload=\"alert(1)\" width='3'/>" "onload" False
  has "other attributes kept" "<svg onload=\"alert(1)\" width='3'/>" "width='3'" True
  has "external href removed" "<image href=\"http://evil/x.png\" width='1'/>" "evil" False
  has "xlink external href removed" "<image xlink:href='https://evil/x.png'/>" "evil" False
  has "fragment href kept" "<use xlink:href=\"#g1\"/>" "#g1" True
  has "data image href kept" "<image href=\"data:image/png;base64,AAAA\"/>" "data:image/png" True
  has "javascript href removed" "<a href=\"javascript:alert(1)\"><g/></a>" "javascript" False
  has "doctype removed" "<?xml version='1.0'?><!DOCTYPE svg [<!ENTITY x 'y'>]><svg/>" "ENTITY" False
  has "xml declaration kept" "<?xml version='1.0'?><svg/>" "<?xml version" True
  has "stylesheet pi removed" "<?xml-stylesheet href='x.css'?><svg/>" "stylesheet" False
  has "external style import removed" "<svg><style>@import url(http://evil/x.css);</style><g/></svg>" "evil" False
  has "style url(#id) kept" "<svg><style>.a{fill:url(#grad)}</style></svg>" "url(#grad)" True
  has "style attr external url removed" "<g style=\"fill:url(http://evil/a)\"/>" "evil" False
  has "animate removed" "<svg><animate attributeName='href' to='javascript:x'/></svg>" "animate" False
  has "uppercase SCRIPT removed" "<svg><SCRIPT>bad()</SCRIPT></svg>" "bad" False
  has "quoted > in attribute does not end tag" "<g title=\"a>b\" onclick=\"x\"/>" "onclick" False

fixtureTikz :: IO Text
fixtureTikz = Encoding.decodeUtf8 <$> ByteString.readFile "../../fixtures/corpus/p4devdays/figures/p4checkarch.tikz"

palette :: [PaletteColour]
palette =
  [ PaletteColour "palCitron" "FFCA3A", PaletteColour "palOlivine" "8AC926"
  , PaletteColour "palCerulean" "1982C4", PaletteColour "palGray" "6A6F77"
  , PaletteColour "palCoral" "FF595E" ]

envelope :: Text -> BlockRequest -> RenderEnvelope
envelope ticket req = RenderEnvelope (Ticket ticket) Nothing Nothing req

newTestBroker :: FilePath -> Maybe [FilePath] -> IO Broker
newTestBroker root dirs =
  newBroker (defaultBrokerConfig root) {configUserExtensions = False, configSearchPath = dirs}

texTests :: Results -> FilePath -> IO ()
texTests r root = do
  body <- fixtureTikz
  broker <- newTestBroker root Nothing
  let req = (emptyBlockRequest "tikz" body)
        { requestPreamble = "\\usepackage{pifont}", requestPalette = palette
        , requestLineMap = Just (LineMap "figures/p4checkarch.tikz" 1), requestWidth = Just 960 }
  first <- renderBlock broker (envelope "t1" req)
  case first of
    Right res -> do
      record r "tex: p4checkarch renders" (case resultOutcome res of Rendered _ -> True; _ -> False)
      record r "tex: result echoes ticket" (resultTicket res == Ticket "t1")
      case resultOutcome res of
        Rendered a -> do
          let svg = Encoding.decodeUtf8 (artifactBytes a)
          record r "tex: artifact is svg" ("<svg" `Text.isInfixOf` svg)
          record r "tex: mime" (artifactMime a == "image/svg+xml")
          record r "tex: no-fonts means no text elements" (not ("<text" `Text.isInfixOf` svg))
          record r "tex: first call not cached" (not (provenanceCached (artifactProvenance a)))
          let path = root </> ".slideblaster" </> "cache" </> "sb.tex" </> Text.unpack (fingerprintText (resultFingerprint res))
          onDisk <- doesFileExist path
          record r "tex: cache file at documented layout" onDisk
        _ -> pure ()
    Left _ -> record r "tex: p4checkarch renders" False
  second <- renderBlock broker (envelope "t2" req)
  stats <- brokerStats broker
  record r "tex: second call is a cache hit"
    (isCached second)
  record r "tex: counters (2 requests, 1 hit, 1 run)" (stats == BrokerStats 2 1 1)
  -- A TeX error maps to the figure's source line.
  let bad = (emptyBlockRequest "tikz" "\\draw (0,0) -- (1,1);\n\\draw (1,1) -- (2,2);\n\\nosuchmacro;\n\\draw (3,3) -- (4,4);")
        { requestLineMap = Just (LineMap "figures/bad.tikz" 10) }
  failed <- renderBlock broker (envelope "t3" bad)
  case failed of
    Right res -> do
      record r "tex error: outcome is Failed" (resultOutcome res == Failed)
      case resultDiagnostics res of
        [d] -> do
          record r "tex error: message" (diagnosticMessage d == "Undefined control sequence")
          record r "tex error: source line mapped through markers and lineMap" (diagnosticSourceLine d == Just 12)
          record r "tex error: file" (diagnosticFile d == Just "figures/bad.tikz")
        _ -> record r "tex error: exactly one diagnostic" False
    Left _ -> record r "tex error: outcome is Failed" False
  stats2 <- brokerStats broker
  _ <- renderBlock broker (envelope "t4" bad)
  stats3 <- brokerStats broker
  record r "tex error: failures are not cached" (statsRuns stats3 == statsRuns stats2 + 1)
  -- \input closure written beside the document.
  let withInput = (emptyBlockRequest "tikz" "\\input{figures/part}")
        { requestInputs = [ResolvedInput "figures/part.tex" "\\draw (0,0) circle (1);"] }
  closure <- renderBlock broker (envelope "t5" withInput)
  record r "tex: \\input closure resolves in the temp directory"
    (isRendered closure)
  -- Nothing leaks into the project besides the cache.
  entries <- listDirectory root
  record r "tex: project contains only .slideblaster" (entries == [".slideblaster"])
  -- fingerprint verification
  let wrong = (envelope "t6" req) {envelopeFingerprint = mkFingerprint (Text.replicate 64 "0")}
  mismatch <- renderBlock broker wrong
  record r "tex: wrong claimed fingerprint is rejected" (case mismatch of Left (FingerprintMismatch _ _) -> True; _ -> False)
  -- unknown kind
  nokind <- renderBlock broker (envelope "t7" (emptyBlockRequest "plotly" "x"))
  record r "no provider for unknown kind is typed absence"
    (absenceOf nokind == Just (NoProvider "plotly"))

graphvizTests :: Results -> FilePath -> IO ()
graphvizTests r root = do
  let dir = root </> ".slideblaster" </> "extensions" </> "user.graphviz"
  createDirectoryIfMissing True dir
  ByteString.writeFile (dir </> "extension.json") graphviz
  broker <- newTestBroker root Nothing
  providers <- listProviders broker
  record r "graphviz: listed with workspace priority"
    (map (manifestId . infoManifest) providers == ["user.graphviz", "sb.tex"])
  record r "graphviz: available when dot is installed" (and [infoAvailable p | p <- providers, manifestId (infoManifest p) == "user.graphviz"])
  let req = emptyBlockRequest "dot" "digraph G { a -> b; b -> c; }"
  one <- renderBlock broker (envelope "g1" req)
  case one of
    Right res -> case resultOutcome res of
      Rendered a -> do
        record r "graphviz: dot block renders to svg" ("<svg" `Text.isInfixOf` Encoding.decodeUtf8 (artifactBytes a))
        record r "graphviz: provenance names the user provider" (provenanceProvider (artifactProvenance a) == "user.graphviz")
      _ -> record r "graphviz: dot block renders to svg" False
    Left _ -> record r "graphviz: dot block renders to svg" False
  two <- renderBlock broker (envelope "g2" req)
  record r "graphviz: second call cached"
    (isCached two)
  bad <- renderBlock broker (envelope "g3" (emptyBlockRequest "dot" "digraph {"))
  record r "graphviz: syntax error is a diagnostic"
    (case bad of Right res -> resultOutcome res == Failed && not (null (resultDiagnostics res)); Left _ -> False)
  -- A manifest with an unknown field is reported and does not hide the others.
  let badDir = root </> ".slideblaster" </> "extensions" </> "broken"
  createDirectoryIfMissing True badDir
  ByteString.writeFile (badDir </> "extension.json") "{\"id\":\"x\",\"version\":\"1\",\"bogus\":1}"
  _ <- listProviders broker
  problems <- brokerProblems broker
  record r "manifest problems are reported, not fatal" (length problems == 1)
  removePathForcibly badDir
  where
    graphviz =
      "{ \"id\": \"user.graphviz\", \"version\": \"1.0.0\",\
      \  \"provides\": [{ \"slot\": \"block.render\", \"kinds\": [\"dot\"], \"output\": \"image/svg+xml\" }],\
      \  \"transport\": { \"kind\": \"stdio-json\", \"argv\": [\"dot\", \"-Tsvg\"], \"stdin\": \"body\", \"stdout\": \"artifact\" },\
      \  \"permissions\": [\"exec:dot\"], \"limits\": { \"timeoutMs\": 10000, \"maxBytes\": 4194304 } }" :: ByteString.ByteString

limitTests :: Results -> FilePath -> IO ()
limitTests r root = do
  install "slow" "slow" ["sleep", "5"] 300 4096
  install "flood" "flood" ["yes"] 5000 2048
  broker <- newTestBroker root Nothing
  slow <- renderBlock broker (envelope "s1" (emptyBlockRequest "slow" ""))
  record r "limits: timeout is typed absence"
    (absenceOf slow == Just (TimedOut "limits.slow" 300))
  flood <- renderBlock broker (envelope "s2" (emptyBlockRequest "flood" ""))
  record r "limits: oversized output is typed absence"
    (absenceOf flood == Just (LimitExceeded "limits.flood" 2048))
  deadline <- renderBlock broker ((envelope "s3" (emptyBlockRequest "slow" "")) {envelopeDeadlineMs = Just 50})
  record r "limits: request deadline shortens the budget"
    (timedOut deadline)
  where
    install dirName kind argv timeoutMs maxBytes = do
      let dir = root </> ".slideblaster" </> "extensions" </> dirName
      createDirectoryIfMissing True dir
      ByteString.writeFile (dir </> "extension.json") . Encoding.encodeUtf8 . Text.pack $
        "{\"id\":\"limits." <> dirName <> "\",\"version\":\"1\",\"provides\":[{\"slot\":\"block.render\",\"kinds\":[\"" <> kind
          <> "\"],\"output\":\"text/plain\"}],\"transport\":{\"kind\":\"stdio-json\",\"argv\":[" <> commaQuoted argv
          <> "]},\"limits\":{\"timeoutMs\":" <> show (timeoutMs :: Int) <> ",\"maxBytes\":" <> show (maxBytes :: Int) <> "}}"
    commaQuoted :: [String] -> String
    commaQuoted xs = concatMap id (zipWith (\i x -> (if i > (0 :: Int) then "," else "") <> show x) [0 ..] xs)

absenceTests :: Results -> FilePath -> IO ()
absenceTests r root = do
  -- A PATH containing latex but not dvisvgm.
  tmp <- getTemporaryDirectory
  let bin = tmp </> "sb-broker-test-bin"
  removePathForcibly bin
  createDirectoryIfMissing True bin
  latex <- findExecutable "latex"
  case latex of
    Nothing -> record r "absence: latex available for the test" False
    Just path -> do
      createFileLink path (bin </> "latex")
      broker <- newTestBroker root (Just [bin])
      let req = emptyBlockRequest "tikz" "\\draw (0,0) -- (1,1); % absence"
      res <- renderBlock broker (envelope "a1" req)
      case res of
        Right x -> do
          record r "absence: missing dvisvgm is typed absence" (resultOutcome x == Absent (ToolMissing "sb.tex" "dvisvgm"))
          record r "absence: carries a warning diagnostic" (map diagnosticCode (resultDiagnostics x) == ["provider.absent"])
        Left _ -> record r "absence: missing dvisvgm is typed absence" False
      providers <- listProviders broker
      record r "absence: provider listed unavailable with missing tool"
        (and [not (infoAvailable p) && infoMissingTools p == ["dvisvgm"] | p <- providers, manifestId (infoManifest p) == "sb.tex"])
      stats <- brokerStats broker
      record r "absence: no process run" (statsRuns stats == 0)
      -- Absence is not cached: with PATH restored the same request renders.
      restored <- newTestBroker root Nothing
      again <- renderBlock restored (envelope "a2" req)
      record r "absence: not cached, renders once tools are back"
        (isRendered again)
  removePathForcibly bin
