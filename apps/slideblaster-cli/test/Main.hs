{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Native CLI argument, persistence, and process-output tests.
--
-- Process-child fixtures capture the real stdout, stderr, and exit status
-- without redirecting process-global handles inside a running test.
module Main (main) where

import SlideBlaster.Adapter.Native
  ( NativeFileSystem (..)
  , NativeFsError (..)
  , NativeSaveError (..)
  , nativeFileSystem
  )
import SlideBlaster.Cli
import SlideBlaster.Cli.Build (BuildTarget (..), defaultBuildOutput, themeStylesheet)
import SlideBlaster.Cli.Pdf (chromeArguments, findChrome, overflowWarnings)
import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import System.Environment (setEnv)

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import System.Process (readProcessWithExitCode)

import Control.Exception (bracket)
import Control.Monad (unless)
import System.Directory
  ( createDirectory
  , getTemporaryDirectory
  , removeFile
  , removePathForcibly
  )
import System.Environment (getArgs, getExecutablePath)
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
  , exitFailure
  , exitWith
  )
import System.FilePath ((</>))
import System.IO (hClose, openBinaryTempFile)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    "--child" : "cli" : cliArguments ->
      runNativeCliChild cliArguments
    ["--child", "install-failed"] ->
      runFailureChild
        ( NativeSaveIoError
            (NativeFsError "ignored" "forced install failure")
        )
    ["--child", "real-write", path] ->
      runRealWriteChild path
    ["--child", "tikz-install-failed"] ->
      runTikzFailureChild
        ( NativeSaveIoError
            (NativeFsError "ignored.tikz" "forced TikZ install failure")
        )
    ["--child", "tikz-noop"] ->
      runTikzNoOpChild
    _ -> runParentTests

runParentTests :: IO ()
runParentTests = do
  assertEqual "version command" (Right CliVersion) (parseArguments ["version"])
  assertEqual
    "inspect command"
    (Right (CliInspect "deck.slideBlaster.md"))
    (parseArguments ["inspect", "deck.slideBlaster.md"])
  assertEqual
    "write replacement"
    ( Right
        ( CliReplace
            ReplaceOptions
              { replacePath = "figure.tikz"
              , replaceStart = 9
              , replaceEnd = 14
              , replaceExpected = "(1,2)"
              , replaceValue = "(3,4)"
              , replacePersistence = PersistChanges
              }
        )
    )
    ( parseArguments
        ["replace", "figure.tikz", "9", "14", "(1,2)", "(3,4)", "--write"]
    )
  assertLeft
    "negative offset"
    (parseArguments ["replace", "x", "-1", "0", "", "x"])
  assertLeft
    "reversed span"
    (parseArguments ["replace", "x", "2", "1", "", "x"])
  buildArgumentParsing
  pdfPieces
  tikzArgumentParsing
  tikzUsageFailures
  noOpWriteDoesNotPersist
  saveFailureReportsExitOne
  realWriteFixturePersists
  tikzReadyAnalysis
  tikzSyntaxOnlyAnalysis
  tikzDryRunPreservesExactSource
  tikzWriteInstallsExactSuccessor
  tikzNoOpWriteSkipsPersistence
  tikzSemanticsUnavailableIsTyped
  tikzMissingTargetIsTyped
  tikzMissingFileReportsExitOne
  tikzSaveFailureReportsExitOne

runNativeCliChild :: [String] -> IO ()
runNativeCliChild arguments = do
  status <- runCli nativeFileSystem (Text.pack <$> arguments)
  exitWith status

runFailureChild :: NativeSaveError -> IO ()
runFailureChild saveError = do
  let fileSystem =
        NativeFileSystem
          { nativeReadFile = \_ -> pure (Right "abc")
          , nativeCompareAndReplace = \_ _ _ -> pure (Left saveError)
          }
  status <-
    runCli
      fileSystem
      ["replace", "ignored", "1", "2", "b", "x", "--write"]
  exitWith status

runRealWriteChild :: FilePath -> IO ()
runRealWriteChild path = do
  status <-
    runCli
      nativeFileSystem
      [ "replace"
      , Text.pack path
      , "1"
      , "2"
      , "b"
      , "x"
      , "--write"
      ]
  exitWith status

runTikzFailureChild :: NativeSaveError -> IO ()
runTikzFailureChild saveError = do
  let fileSystem =
        NativeFileSystem
          { nativeReadFile = \_ -> pure (Right nonCanonicalSource)
          , nativeCompareAndReplace = \_ _ _ -> pure (Left saveError)
          }
  status <-
    runCli
      fileSystem
      ["tikz", "move-node", "ignored.tikz", "alpha", "4", "5", "--write"]
  exitWith status

runTikzNoOpChild :: IO ()
runTikzNoOpChild = do
  let fileSystem =
        NativeFileSystem
          { nativeReadFile = \_ -> pure (Right nonCanonicalSource)
          , nativeCompareAndReplace =
              \_ _ _ ->
                pure
                  ( Left
                      ( NativeSaveIoError
                          ( NativeFsError
                              "ignored.tikz"
                              "no-op unexpectedly reached persistence"
                          )
                      )
                  )
          }
  status <-
    runCli
      fileSystem
      [ "tikz"
      , "move-node"
      , "ignored.tikz"
      , "alpha"
      , "1.5"
      , "0"
      , "--write"
      ]
  exitWith status

tikzArgumentParsing :: IO ()
tikzArgumentParsing = do
  assertEqual
    "TikZ analyze command"
    (Right (CliTikzAnalyze "figure.tikz"))
    (parseArguments ["tikz", "analyze", "figure.tikz"])
  assertEqual
    "TikZ move dry run"
    ( Right
        ( CliTikzMove
            TikzMoveOptions
              { tikzMovePath = "figure.tikz"
              , tikzMoveNodeId = "alpha"
              , tikzMoveX = "4"
              , tikzMoveY = "5"
              , tikzMovePersistence = PreviewOnly
              }
        )
    )
    ( parseArguments
        ["tikz", "move-node", "figure.tikz", "alpha", "4", "5"]
    )
  assertEqual
    "TikZ move write"
    ( Right
        ( CliTikzMove
            TikzMoveOptions
              { tikzMovePath = "figure.tikz"
              , tikzMoveNodeId = "node_1"
              , tikzMoveX = "-3.25"
              , tikzMoveY = "+4.5"
              , tikzMovePersistence = PersistChanges
              }
        )
    )
    ( parseArguments
        [ "tikz"
        , "move-node"
        , "figure.tikz"
        , "node_1"
        , "-3.25"
        , "+4.5"
        , "--write"
        ]
    )
  assertLeft
    "TikZ analyze rejects extra arguments"
    (parseArguments ["tikz", "analyze", "figure.tikz", "--write"])
  assertLeft
    "TikZ move rejects an unknown persistence flag"
    ( parseArguments
        [ "tikz"
        , "move-node"
        , "figure.tikz"
        , "alpha"
        , "4"
        , "5"
        , "--force"
        ]
    )
  assertContains
    "usage advertises TikZ analyze"
    "slideblaster tikz analyze FILE"
    (Text.unpack usage)
  assertContains
    "usage advertises TikZ move"
    "slideblaster tikz move-node FILE NODE_ID X Y [--write]"
    (Text.unpack usage)

tikzUsageFailures :: IO ()
tikzUsageFailures = do
  assertChildUsageFailure
    "invalid TikZ node identifier"
    ["tikz", "move-node", "ignored", "bad id", "4", "5"]
    "NODE_ID is outside the validated TikZ identifier grammar"
  assertChildUsageFailure
    "TikZ exponent coordinate"
    ["tikz", "move-node", "ignored", "alpha", "1e2", "5"]
    "X is outside the bounded TikZ decimal grammar"
  assertChildUsageFailure
    "TikZ over-precise coordinate"
    [ "tikz"
    , "move-node"
    , "ignored"
    , "alpha"
    , "4"
    , "1.0000000000"
    ]
    "Y is outside the bounded TikZ decimal grammar"

assertChildUsageFailure :: String -> [String] -> String -> IO ()
assertChildUsageFailure label arguments expectedDiagnostic = do
  (status, standardOutput, standardError) <-
    runChild (["--child", "cli"] <> arguments)
  assertEqual (label <> " exit status") (ExitFailure 2) status
  assertEqual (label <> " stdout") "" standardOutput
  assertContains (label <> " diagnostic") expectedDiagnostic standardError
  assertContains (label <> " usage") "Usage:" standardError

tikzReadyAnalysis :: IO ()
tikzReadyAnalysis =
  withTemporaryDirectory $ \root -> do
    let path = root </> "ready.tikz"
    ByteString.writeFile path nonCanonicalSource
    (status, standardOutput, standardError) <-
      runChild ["--child", "cli", "tikz", "analyze", path]
    assertEqual "ready analysis exit status" ExitSuccess status
    assertEqual "ready analysis stderr" "" standardError
    assertContains
      "ready analysis discriminator"
      "response=tikz_analysis"
      standardOutput
    assertContains
      "ready analysis state"
      "document.state=ready"
      standardOutput
    assertContains
      "ready analysis revision"
      "source.revision=0"
      standardOutput
    assertContains
      "ready analysis coordinate space"
      "plan.coordinate-space=slide_16x9_y_up"
      standardOutput
    assertContains
      "ready analysis node"
      "plan.node.id=alpha"
      standardOutput
    assertContains
      "ready analysis canonical x"
      "plan.node.center.x=1.5"
      standardOutput
    assertContains
      "ready analysis canonical y"
      "plan.node.center.y=0"
      standardOutput
    assertContains
      "ready analysis connector end"
      "plan.connector.end.x=9"
      standardOutput
    assertNotContains
      "ready analysis does not echo source"
      "% lead"
      standardOutput
    assertEqual
      "ready analysis preserves exact file"
      nonCanonicalSource
      =<< ByteString.readFile path

tikzSyntaxOnlyAnalysis :: IO ()
tikzSyntaxOnlyAnalysis =
  withTemporaryDirectory $ \root -> do
    let path = root </> "malformed.tikz"
    ByteString.writeFile path malformedTikzSource
    (status, standardOutput, standardError) <-
      runChild ["--child", "cli", "tikz", "analyze", path]
    assertEqual "syntax-only analysis exit status" (ExitFailure 1) status
    assertEqual "syntax-only analysis stderr" "" standardError
    assertContains
      "syntax-only analysis discriminator"
      "response=tikz_analysis"
      standardOutput
    assertContains
      "syntax-only analysis state"
      "document.state=syntax_only"
      standardOutput
    assertContains
      "syntax-only diagnostic count"
      "diagnostics.count=1"
      standardOutput
    assertContains
      "syntax-only diagnostic category"
      "diagnostic.0.category=malformed"
      standardOutput
    assertContains
      "syntax-only diagnostic code"
      "diagnostic.0.code=expected_syntax_token"
      standardOutput
    assertContains
      "syntax-only diagnostic start"
      "diagnostic.0.start=5"
      standardOutput
    assertContains
      "syntax-only diagnostic end"
      "diagnostic.0.end=5"
      standardOutput
    assertContains
      "syntax-only static diagnostic"
      "diagnostic.0.message=Expected '(' before the node identifier"
      standardOutput
    assertNotContains
      "syntax-only analysis does not echo source"
      "\\node"
      standardOutput
    assertEqual
      "syntax-only analysis preserves exact file"
      malformedTikzSource
      =<< ByteString.readFile path

tikzDryRunPreservesExactSource :: IO ()
tikzDryRunPreservesExactSource =
  withTemporaryDirectory $ \root -> do
    let path = root </> "dry-run.tikz"
    ByteString.writeFile path nonCanonicalSource
    (status, standardOutput, standardError) <-
      runChild
        [ "--child"
        , "cli"
        , "tikz"
        , "move-node"
        , path
        , "alpha"
        , "4"
        , "5"
        ]
    assertEqual "TikZ dry-run exit status" ExitSuccess status
    assertEqual "TikZ dry-run stderr" "" standardError
    assertContains
      "TikZ dry-run response"
      "response=tikz_move"
      standardOutput
    assertContains
      "TikZ dry-run verified outcome"
      "move.outcome=verified_change"
      standardOutput
    assertContains
      "TikZ dry-run before revision"
      "move.before-revision=0"
      standardOutput
    assertContains
      "TikZ dry-run after revision"
      "move.after-revision=1"
      standardOutput
    assertContains
      "TikZ dry-run target"
      "move.node-id=alpha"
      standardOutput
    assertContains
      "TikZ dry-run destination x"
      "move.destination.x=4"
      standardOutput
    assertContains
      "TikZ dry-run destination y"
      "move.destination.y=5"
      standardOutput
    assertContains
      "TikZ dry-run plan revision"
      "plan.source-revision=1"
      standardOutput
    assertContains
      "TikZ dry-run connector follows node x"
      "plan.connector.start.x=4"
      standardOutput
    assertContains
      "TikZ dry-run connector follows node y"
      "plan.connector.start.y=5"
      standardOutput
    assertContains
      "TikZ dry-run does not persist"
      "host.persisted=false"
      standardOutput
    assertNotContains
      "TikZ dry-run does not echo Unicode source"
      "π"
      standardOutput
    assertEqual
      "TikZ dry-run preserves exact source"
      nonCanonicalSource
      =<< ByteString.readFile path

tikzWriteInstallsExactSuccessor :: IO ()
tikzWriteInstallsExactSuccessor =
  withTemporaryDirectory $ \root -> do
    let path = root </> "write.tikz"
    ByteString.writeFile path nonCanonicalSource
    (status, standardOutput, standardError) <-
      runChild
        [ "--child"
        , "cli"
        , "tikz"
        , "move-node"
        , path
        , "alpha"
        , "4"
        , "5"
        , "--write"
        ]
    assertEqual "TikZ write exit status" ExitSuccess status
    assertEqual "TikZ write stderr" "" standardError
    assertContains
      "TikZ write verified outcome"
      "move.outcome=verified_change"
      standardOutput
    assertContains
      "TikZ write reports persistence"
      "host.persisted=true"
      standardOutput
    assertEqual
      "TikZ write exact noncanonical Unicode successor"
      movedNonCanonicalSource
      =<< ByteString.readFile path

tikzNoOpWriteSkipsPersistence :: IO ()
tikzNoOpWriteSkipsPersistence = do
  (status, standardOutput, standardError) <-
    runChild ["--child", "tikz-noop"]
  assertEqual "TikZ no-op write exit status" ExitSuccess status
  assertEqual "TikZ no-op write stderr" "" standardError
  assertContains
    "TikZ no-op outcome"
    "move.outcome=unchanged"
    standardOutput
  assertContains
    "TikZ no-op keeps revision"
    "move.after-revision=0"
    standardOutput
  assertContains
    "TikZ no-op skips persistence"
    "host.persisted=false"
    standardOutput

tikzSemanticsUnavailableIsTyped :: IO ()
tikzSemanticsUnavailableIsTyped =
  withTemporaryDirectory $ \root -> do
    let path = root </> "syntax-only-move.tikz"
    ByteString.writeFile path malformedTikzSource
    (status, standardOutput, standardError) <-
      runChild
        [ "--child"
        , "cli"
        , "tikz"
        , "move-node"
        , path
        , "alpha"
        , "4"
        , "5"
        ]
    assertEqual
      "syntax-only move exit status"
      (ExitFailure 1)
      status
    assertEqual "syntax-only move stdout" "" standardOutput
    assertContains
      "syntax-only move typed error"
      "error.code=tikz_semantics_unavailable"
      standardError
    assertNotContains
      "syntax-only move error does not echo source"
      "\\node"
      standardError
    assertEqual
      "syntax-only move preserves exact source"
      malformedTikzSource
      =<< ByteString.readFile path

tikzMissingTargetIsTyped :: IO ()
tikzMissingTargetIsTyped =
  withTemporaryDirectory $ \root -> do
    let path = root </> "missing-target.tikz"
    ByteString.writeFile path nonCanonicalSource
    (status, standardOutput, standardError) <-
      runChild
        [ "--child"
        , "cli"
        , "tikz"
        , "move-node"
        , path
        , "beta"
        , "4"
        , "5"
        ]
    assertEqual "missing TikZ target exit status" (ExitFailure 1) status
    assertEqual "missing TikZ target stdout" "" standardOutput
    assertContains
      "missing TikZ target typed error"
      "error.code=tikz_target_missing"
      standardError
    assertContains
      "missing TikZ target identity"
      "error.node-id=beta"
      standardError
    assertEqual
      "missing TikZ target preserves exact source"
      nonCanonicalSource
      =<< ByteString.readFile path

tikzMissingFileReportsExitOne :: IO ()
tikzMissingFileReportsExitOne =
  withTemporaryDirectory $ \root -> do
    let path = root </> "missing.tikz"
    (status, standardOutput, standardError) <-
      runChild ["--child", "cli", "tikz", "analyze", path]
    assertEqual "missing TikZ file exit status" (ExitFailure 1) status
    assertEqual "missing TikZ file stdout" "" standardOutput
    assertContains "missing TikZ file path" path standardError
    assertContains
      "missing TikZ file prefix"
      "slideblaster:"
      standardError

tikzSaveFailureReportsExitOne :: IO ()
tikzSaveFailureReportsExitOne = do
  (status, standardOutput, standardError) <-
    runChild ["--child", "tikz-install-failed"]
  assertEqual "TikZ save failure exit status" (ExitFailure 1) status
  assertEqual "TikZ save failure emits no response" "" standardOutput
  assertContains
    "TikZ save failure diagnostic"
    "forced TikZ install failure"
    standardError
  assertContains
    "TikZ save failure path"
    "ignored.tikz"
    standardError
  assertNotContains
    "TikZ save failure does not echo source"
    "% lead"
    standardError

noOpWriteDoesNotPersist :: IO ()
noOpWriteDoesNotPersist = do
  compareCount <- newIORef (0 :: Int)
  let fileSystem =
        NativeFileSystem
          { nativeReadFile = \_ -> pure (Right (ByteString.pack "abc"))
          , nativeCompareAndReplace =
              \_ _ _ -> do
                modifyIORef' compareCount (+ 1)
                pure (Right ())
          }
  result <-
    runCli
      fileSystem
      ["replace", "ignored", "1", "2", "b", "b", "--write"]
  assertEqual "no-op write exits successfully" ExitSuccess result
  comparisons <- readIORef compareCount
  assertEqual "no-op write does not touch storage" 0 comparisons

saveFailureReportsExitOne :: IO ()
saveFailureReportsExitOne = do
  (status, standardOutput, standardError) <-
    runChild ["--child", "install-failed"]
  assertEqual "save failure exit status" (ExitFailure 1) status
  assertEqual "save failure emits no success response" "" standardOutput
  assertContains
    "save failure diagnostic"
    "forced install failure"
    standardError
  assertContains
    "save failure path"
    "ignored"
    standardError

realWriteFixturePersists :: IO ()
realWriteFixturePersists =
  withTemporaryDirectory $ \root -> do
    let path = root </> "real-write.slide"
    ByteString.writeFile path "abc"
    (status, standardOutput, standardError) <-
      runChild ["--child", "real-write", path]
    assertEqual "real write exit status" ExitSuccess status
    assertContains
      "real write reports persisted successor"
      "host.persisted=true"
      standardOutput
    assertContains
      "real write reports successor revision"
      "edit.after-revision=1"
      standardOutput
    assertEqual "real write stderr" "" standardError
    assertEqual
      "real write exact bytes"
      "axc"
      =<< ByteString.readFile path

nonCanonicalSource :: ByteString
nonCanonicalSource =
  Text.Encoding.encodeUtf8
    "% lead\n\\node % command\n (alpha)\t at ( +001.5000 % x\n ,\t -000.00 ) {π 😀}; % between\n\\draw\t(alpha) -- (9.0 , 8);\n"

movedNonCanonicalSource :: ByteString
movedNonCanonicalSource =
  Text.Encoding.encodeUtf8
    "% lead\n\\node % command\n (alpha)\t at ( 4 % x\n ,\t 5 ) {π 😀}; % between\n\\draw\t(alpha) -- (9.0 , 8);\n"

malformedTikzSource :: ByteString
malformedTikzSource = "\\node"

runChild :: [String] -> IO (ExitCode, String, String)
runChild arguments = do
  executable <- getExecutablePath
  readProcessWithExitCode executable arguments ""

withTemporaryDirectory :: (FilePath -> IO value) -> IO value
withTemporaryDirectory action = do
  temporaryDirectory <- getTemporaryDirectory
  bracket
    (do
      (path, handle) <-
        openBinaryTempFile temporaryDirectory "slideblaster-cli-tests"
      hClose handle
      removeFile path
      createDirectory path
      pure path
    )
    removePathForcibly
    action

assertLeft :: Show right => String -> Either left right -> IO ()
assertLeft label value =
  case value of
    Left _ -> pure ()
    Right result -> failTest (label <> ": unexpectedly parsed " <> show result)

assertContains :: String -> String -> String -> IO ()
assertContains label expectedPart actual =
  unless (expectedPart `isInfixOf` actual) $
    failTest
      ( label
          <> ": expected "
          <> show expectedPart
          <> " within "
          <> show actual
      )

assertNotContains :: String -> String -> String -> IO ()
assertNotContains label unexpectedPart actual =
  unless (not (unexpectedPart `isInfixOf` actual)) $
    failTest
      ( label
          <> ": did not expect "
          <> show unexpectedPart
          <> " within "
          <> show actual
      )

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $
    failTest (label <> ": expected " <> show expected <> ", got " <> show actual)

failTest :: String -> IO value
failTest message = do
  putStrLn ("FAIL: " <> message)
  exitFailure

buildArgumentParsing :: IO ()
buildArgumentParsing = do
  assertEqual "build --html default output" (Right (CliBuild TargetHtml "d/talk.slideBlaster.md" "d/talk.html" Nothing)) (parseArguments ["build", "--html", "d/talk.slideBlaster.md"])
  assertEqual "build --pdf default output" (Right (CliBuild (TargetPdf False) "talk.slideBlaster.md" "talk.pdf" Nothing)) (parseArguments ["build", "--pdf", "talk.slideBlaster.md"])
  assertEqual "build --pdf -o --steps --web" (Right (CliBuild (TargetPdf True) "t.slideBlaster.md" "/tmp/x.pdf" (Just "w"))) (parseArguments ["build", "t.slideBlaster.md", "--steps", "--pdf", "-o", "/tmp/x.pdf", "--web", "w"])
  assertLeft "build needs a target" (parseArguments ["build", "t.slideBlaster.md"])
  assertLeft "build takes one target" (parseArguments ["build", "--html", "--pdf", "t.slideBlaster.md"])
  assertLeft "--steps is for pdf" (parseArguments ["build", "--html", "--steps", "t.slideBlaster.md"])
  assertLeft "build needs a deck" (parseArguments ["build", "--pdf"])
  assertEqual "shots passes its arguments on" (Right (CliShots ["d/t.slideBlaster.md", "--compare"])) (parseArguments ["shots", "d/t.slideBlaster.md", "--compare"])
  assertLeft "shots needs a deck" (parseArguments ["shots"])

pdfPieces :: IO ()
pdfPieces = do
  assertEqual "default pdf name" "a/b.pdf" (defaultBuildOutput (TargetPdf False) "a/b.slideBlaster.md")
  let args = chromeArguments "/p" "/o.pdf" "/h.html"
  assertEqual "chrome prints headless without header/footer" True (all (`elem` args) ["--headless=new", "--no-pdf-header-footer", "--print-to-pdf=/o.pdf", "--user-data-dir=/p", "file:///h.html"])
  assertEqual "chrome logs the page console to stderr" True (all (`elem` args) ["--enable-logging=stderr", "--v=0"])
  assertEqual "overflow warnings come from the console log"
    ["f step 2/3: \"a \"b\"\" runs 3% past the bottom"]
    (overflowWarnings "noise\n[1:1:1109/1.2:INFO:CONSOLE:1] \"sb-overflow: f step 2/3: \"a \"b\"\" runs 3% past the bottom\", source: file:///d.html (1)\n[x:INFO:CONSOLE:1] \"other\", source: y")
  setEnv "SB_CHROME" "/nonexistent/chrome"
  missing <- findChrome
  assertEqual "SB_CHROME that does not exist is an error" True (either (Text.isInfixOf "SB_CHROME") (const False) missing)
  let files = Map.fromList
        [ ("themes/t/theme.json", "{\"css\":\"s.css\"}")
        , ("themes/t/s.css", "@font-face{src:url('f/a.woff2')} .x{background:url(../../secret.png)}")
        , ("themes/t/f/a.woff2", "abc")
        ]
      css = themeStylesheet files (object ["theme" .= ("t" :: Text.Text)])
  assertEqual "theme css found by theme.json and fonts inlined, parent paths refused" "@font-face{src:url(data:font/woff2;base64,YWJj)} .x{background:url(../../secret.png)}" css
  assertEqual "no theme, no css" "" (themeStylesheet files (object []))
