{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Executable tests for the shared request/response protocol.
--
-- The tests pin diagnostic keys and exact-byte JSON round trips shared by the
-- native and Wasm compositions. Slice 1 fixtures derive from the written wire
-- contract rather than reconstructing TikZ semantics in the test harness.
module Main (main) where

import SlideBlaster.Protocol
import SlideBlaster.Source
import SlideBlaster.Engine
  ( TikzAnalysis (TikzAnalysisReady, TikzAnalysisSyntaxOnly)
  , analyzeTikzSnapshot
  )
import SlideBlaster.Syntax.Inline (InlineRun (runPath))
import SlideBlaster.Syntax.Path (pathToList)
import SlideBlaster.TikZ
  ( MoveError (..)
  , VerificationFailure (..)
  , documentPicture
  , mkNodeId
  , nodeContent
  , pictureNode
  )
import SlideBlaster.TikZ.NodeContent (nodeContentRuns, readNodeContent)
import Text.Printf (printf)

import Data.Aeson
  ( Value (..)
  , eitherDecodeStrict'
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Word (Word64)

import Control.Monad (forM_, unless)
import System.Exit (exitFailure)

main :: IO ()
main = do
  run "inspect request renders stable fields" inspectRequest
  run "replacement request renders stable fields" replacementRequest
  run "inspect JSON preserves arbitrary bytes" jsonRequestRoundTrip
  run "replacement JSON preserves arbitrary bytes" replacementJsonRoundTrip
  run "engine decoder rejects malformed envelopes" engineDecodeRejections
  run "host envelope remains closed and redacted" hostEnvelopeContract
  run "analyze_tikz request round-trips exact bytes" analyzeTikzRequestRoundTrip
  run "move_tikz_node request round-trips typed intent" moveTikzRequestRoundTrip
  run "Slice 1 requests reject unknown nested fields" tikzNestedClosure
  run "Slice 1 requests reject invalid node identities" tikzNodeIdRejections
  run "Slice 1 requests reject invalid decimal values" tikzDecimalRejections
  run "ready analysis has the exact closed JSON shape" readyAnalysisResponse
  run "authored markup reaches the protocol as resolved runs" styledContentResponse
  run "a style command crosses the wire and takes effect" styledEditRoundTrip
  run "a toggle crosses the wire and removes what is already there" toggledEditRoundTrip
  run "the theme notation crosses the wire and decides the spelling" themeDialectRoundTrip
  run "syntax-only analysis has the exact closed JSON shape" syntaxOnlyResponse
  run "verified move returns the exact local successor" verifiedMoveResponse
  run "semantic no-op preserves exact spelling and revision" unchangedMoveResponse
  run "stale move returns no successor snapshot" staleMoveResponse
  run "syntax-only move is typed and source-redacted" unavailableMoveResponse
  run "TikZ move errors have stable source-redacted codes" tikzErrorMapping

run :: String -> IO () -> IO ()
run name check = do
  check
  putStrLn ("PASS: " <> name)

inspectRequest :: IO ()
inspectRequest = do
  let request = InspectSource (snapshotFromBytes (ByteString.Char8.pack "abc\n"))
  case runEngineRequest request of
    Left problem -> failTest ("inspection rejected: " <> show problem)
    Right response -> do
      let rendered = renderEngineResponse response
      assertContains "protocol version" "slideblaster.protocol=1" rendered
      assertContains "inspection response kind" "response=inspection" rendered
      assertContains "inspection byte count" "source.bytes=4" rendered

replacementRequest :: IO ()
replacementRequest = do
  let snapshot = snapshotFromBytes (ByteString.Char8.pack "abc")
      target = requireSpan 1 2
      replacement =
        mkExactReplacement
          (snapshotRevision snapshot)
          target
          (ByteString.Char8.pack "b")
          (ByteString.Char8.pack "z")
  case runEngineRequest (ReplaceSource snapshot replacement) of
    Left problem -> failTest ("replacement rejected: " <> show problem)
    Right response -> do
      let rendered = renderEngineResponse response
      assertContains "replacement response kind" "response=replacement" rendered
      assertContains "replacement advances revision" "edit.after-revision=1" rendered
      assertContains "replacement changes bytes" "edit.changed=true" rendered

jsonRequestRoundTrip :: IO ()
jsonRequestRoundTrip = do
  let snapshot =
        snapshotFromBytes
          (ByteString.Char8.pack "source with a non-UTF8 suffix: \255")
      request = InspectSource snapshot
  assertEqual
    "JSON request preserves exact bytes"
    (Right request)
    (decodeEngineRequestJSON (encodeEngineRequestJSON request))
  case runEngineRequest request of
    Left problem -> failTest ("JSON response fixture rejected: " <> show problem)
    Right response ->
      case eitherDecodeStrict' (encodeEngineResponseJSON response) :: Either String Value of
        Left problem -> failTest ("response is not JSON: " <> problem)
        Right _ -> pure ()

replacementJsonRoundTrip :: IO ()
replacementJsonRoundTrip = do
  let snapshot = snapshotFromBytes (ByteString.Char8.pack "a\255c")
      replacement =
        mkExactReplacement
          (snapshotRevision snapshot)
          (requireSpan 1 2)
          (ByteString.Char8.pack "\255")
          (ByteString.Char8.pack "\NULz")
      request = ReplaceSource snapshot replacement
  assertEqual
    "replacement JSON preserves arbitrary bytes"
    (Right request)
    (decodeEngineRequestJSON (encodeEngineRequestJSON request))

engineDecodeRejections :: IO ()
engineDecodeRejections = do
  assertProtocolDecodeFailure
    "snapshot encoding is mandatory"
    ( ByteString.Char8.pack
        "{\"protocol\":\"slideblaster.engine/1\",\"command\":\"inspect\",\
        \\"snapshot\":{\"revision\":0,\"source\":\"61\",\"encoding\":\"utf8\"}}"
    )
  assertProtocolDecodeFailure
    "unknown request fields are rejected"
    ( ByteString.Char8.pack
        "{\"protocol\":\"slideblaster.engine/1\",\"command\":\"inspect\",\
        \\"snapshot\":{\"revision\":0,\"source\":\"61\",\"encoding\":\"base16\"},\
        \\"extra\":true}"
    )
  assertProtocolDecodeFailure
    "offsets have one native/Wasm domain"
    ( ByteString.Char8.pack
        "{\"protocol\":\"slideblaster.engine/1\",\"command\":\"replace\",\
        \\"snapshot\":{\"revision\":0,\"source\":\"61\",\"encoding\":\"base16\"},\
        \\"edit\":{\"revision\":0,\"start\":2147483648,\"end\":2147483648,\
        \\"expected\":\"\",\"value\":\"\"}}"
    )
  case
      decodeEngineRequestJSON
        (ByteString.Char8.pack "{\"protocol\":\"slideblaster.engine/2\"}")
    of
      Left (ProtocolDecodeError (ProtocolUnsupportedVersion "slideblaster.engine/2")) ->
        pure ()
      other -> failTest ("future engine version was misclassified: " <> show other)

hostEnvelopeContract :: IO ()
hostEnvelopeContract = do
  requestId <-
    case hostRequestIdFromWord64 7 of
      Nothing -> failTest "test bug: host request id 7 was rejected"
      Just value -> pure value
  request <-
    case mkHostRequest requestId "storage" "read" (readJson "{\"path\":\"deck.sb\"}") of
      Left problem -> failTest ("host request construction failed: " <> show problem)
      Right value -> pure value
  case eitherDecodeStrict' (encodeHostRequestJSON request) :: Either String Value of
    Left problem -> failTest ("host request is not JSON: " <> problem)
    Right _ -> pure ()
  assertNotContains
    "host request Show redacts payload"
    "deck.sb"
    (Text.pack (show request))

  assertEqual
    "host success envelope is decoded"
    (Right (HostResponseSucceeded requestId (readJson "{\"stored\":true}")))
    ( decodeHostResponseJSON
        (ByteString.Char8.pack "{\"version\":1,\"id\":7,\"ok\":true,\"payload\":{\"stored\":true}}")
    )
  case
      decodeHostResponseJSON
        ( ByteString.Char8.pack
            "{\"version\":1,\"id\":7,\"ok\":true,\"payload\":null,\
            \\"error\":{\"code\":\"bad\",\"message\":\"ambiguous\"}}"
        )
    of
      Left HostResponseMalformed {} -> pure ()
      other -> failTest ("host payload/error exclusivity was not enforced: " <> show other)
  case
      decodeHostResponseJSON
        (ByteString.Char8.pack "{\"version\":2,\"id\":7,\"ok\":true,\"payload\":null}")
    of
      Left (HostResponseUnsupportedVersion 2) -> pure ()
      other -> failTest ("unknown host version was not rejected: " <> show other)
  case decodeHostResponseJSON (ByteString.Char8.pack "{\"version\":2}") of
    Left (HostResponseUnsupportedVersion 2) -> pure ()
    other -> failTest ("minimal future host version was misclassified: " <> show other)
  let succeeded =
        HostResponseSucceeded requestId (readJson "{\"source\":\"sentinel-source\"}")
  assertNotContains
    "host response Show redacts payload"
    "sentinel-source"
    (Text.pack (show succeeded))

analyzeTikzRequestRoundTrip :: IO ()
analyzeTikzRequestRoundTrip = do
  let snapshot =
        snapshotAtRevision
          (revisionFromWord64 42)
          (ByteString.pack [0, 255, 10, 92, 110])
      request = AnalyzeTikz snapshot
  assertEqual
    "analyze request preserves exact revision and bytes"
    (Right request)
    (decodeEngineRequestJSON (encodeEngineRequestJSON request))
  assertEncodedJsonEqual
    "analyze encoder emits only the closed request fields"
    ( object
        [ "protocol" .= engineProtocol
        , "command" .= ("analyze_tikz" :: Text)
        , "snapshot" .= snapshotValue 42 "00ff0a5c6e"
        ]
    )
    (encodeEngineRequestJSON request)

moveTikzRequestRoundTrip :: IO ()
moveTikzRequestRoundTrip = do
  request <-
    requireDecoded
      "valid move request was rejected"
      ( moveRequestValue
          7
          canonicalSourceHex
          7
          "alpha"
          (pointValue "+001.5000" "-000.00")
      )
  let encoded = encodeEngineRequestJSON request
  assertEqual
    "encoded move decodes to the same typed intent"
    (Right request)
    (decodeEngineRequestJSON encoded)
  assertEncodedJsonEqual
    "typed move encoder uses canonical decimal strings"
    ( moveRequestValue
        7
        canonicalSourceHex
        7
        "alpha"
        (pointValue "1.5" "0")
    )
    encoded

tikzNestedClosure :: IO ()
tikzNestedClosure = do
  let snapshotWithExtra =
        object
          [ "revision" .= (0 :: Word64)
          , "source" .= canonicalSourceHex
          , "encoding" .= ("base16" :: Text)
          , "extra" .= True
          ]
      snapshotMissingEncoding =
        object
          [ "revision" .= (0 :: Word64)
          , "source" .= canonicalSourceHex
          ]
      intentWithExtra =
        object
          [ "revision" .= (0 :: Word64)
          , "nodeId" .= ("alpha" :: Text)
          , "destination" .= pointValue "4" "5"
          , "extra" .= True
          ]
      intentMissingNodeId =
        object
          [ "revision" .= (0 :: Word64)
          , "destination" .= pointValue "4" "5"
          ]
      destinationWithExtra =
        object
          [ "x" .= ("4" :: Text)
          , "y" .= ("5" :: Text)
          , "extra" .= True
          ]
      destinationMissingY = object ["x" .= ("4" :: Text)]
      cases =
        [ ( "analyze top-level extra"
          , object
              [ "protocol" .= engineProtocol
              , "command" .= ("analyze_tikz" :: Text)
              , "snapshot" .= snapshotValue 0 canonicalSourceHex
              , "extra" .= True
              ]
          )
        , ( "analyze missing snapshot"
          , object
              [ "protocol" .= engineProtocol
              , "command" .= ("analyze_tikz" :: Text)
              ]
          )
        , ( "analyze snapshot extra"
          , object
              [ "protocol" .= engineProtocol
              , "command" .= ("analyze_tikz" :: Text)
              , "snapshot" .= snapshotWithExtra
              ]
          )
        , ( "analyze snapshot missing encoding"
          , object
              [ "protocol" .= engineProtocol
              , "command" .= ("analyze_tikz" :: Text)
              , "snapshot" .= snapshotMissingEncoding
              ]
          )
        , ( "move missing intent"
          , object
              [ "protocol" .= engineProtocol
              , "command" .= ("move_tikz_node" :: Text)
              , "snapshot" .= snapshotValue 0 canonicalSourceHex
              ]
          )
        , ( "move intent extra"
          , object
              [ "protocol" .= engineProtocol
              , "command" .= ("move_tikz_node" :: Text)
              , "snapshot" .= snapshotValue 0 canonicalSourceHex
              , "intent" .= intentWithExtra
              ]
          )
        , ( "move intent missing node ID"
          , object
              [ "protocol" .= engineProtocol
              , "command" .= ("move_tikz_node" :: Text)
              , "snapshot" .= snapshotValue 0 canonicalSourceHex
              , "intent" .= intentMissingNodeId
              ]
          )
        , ( "move destination extra"
          , moveRequestValue
              0
              canonicalSourceHex
              0
              "alpha"
              destinationWithExtra
          )
        , ( "move destination missing y"
          , moveRequestValue
              0
              canonicalSourceHex
              0
              "alpha"
              destinationMissingY
          )
        ]
  forM_ cases $ \(label, value) -> assertInvalidField label value

tikzNodeIdRejections :: IO ()
tikzNodeIdRejections =
  forM_
    ["", "1alpha", "alpha beta", "alpha/beta", "π"]
    $ \nodeIdentity ->
      assertInvalidField
        ("invalid node identity " <> show nodeIdentity)
        ( moveRequestValue
            0
            canonicalSourceHex
            0
            nodeIdentity
            (pointValue "4" "5")
        )

tikzDecimalRejections :: IO ()
tikzDecimalRejections = do
  let invalidXValues =
        [ ("JSON number", Number 4)
        , ("exponent", String "1e3")
        , ("unit", String "4pt")
        , ("fractional limit", String "0.1234567890")
        , ("digit limit", String "1234567890123456789")
        , ("non-decimal", String "NaN")
        ]
  forM_ invalidXValues $ \(label, xValue) ->
    assertInvalidField
      ("invalid x decimal: " <> label)
      ( moveRequestValue
          0
          canonicalSourceHex
          0
          "alpha"
          (object ["x" .= xValue, "y" .= ("5" :: Text)])
      )
  assertInvalidField
    "invalid y decimal"
    ( moveRequestValue
        0
        canonicalSourceHex
        0
        "alpha"
        (object ["x" .= ("4" :: Text), "y" .= ("_" :: Text)])
    )

readyAnalysisResponse :: IO ()
readyAnalysisResponse = do
  response <-
    requireRight
      "ready analysis was rejected"
      ( runEngineRequest
          ( AnalyzeTikz
              ( snapshotAtRevision
                  (revisionFromWord64 3)
                  canonicalFixture
              )
          )
      )
  assertEncodedJsonEqual
    "ready analysis response"
    ( object
        [ "protocol" .= engineProtocol
        , "ok" .= True
        , "response" .= ("tikz_analysis" :: Text)
        , "snapshot" .= snapshotValue 3 canonicalSourceHex
        , "analysis" .= readyAnalysisValue 3 "1" "2" "hello" [runValue "plain" "hello" [0] (Just "tex")]
        ]
    )
    (encodeEngineResponseJSON response)

-- | The point of the slice, asserted on the wire.
--
-- Authored LaTeX markup inside a node's content arrives as runs whose styling is
-- already resolved, with the colour converted to sRGB in Haskell, and with the
-- exact authored bytes still present alongside.
styledContentResponse :: IO ()
styledContentResponse = do
  response <-
    requireRight
      "styled analysis was rejected"
      ( runEngineRequest
          ( AnalyzeTikz
              (snapshotAtRevision (revisionFromWord64 1) styledFixture)
          )
      )
  let rendered = Text.Encoding.decodeUtf8 (encodeEngineResponseJSON response)
  assertContains "bold run text" "bold" rendered
  assertContains "bold weight is resolved" "\"weight\":\"bold\"" rendered
  assertContains "colour is resolved to sRGB" "#ff0000" rendered
  assertContains "content is understood" "understood" rendered
  assertContains
    "exact authored bytes are still carried"
    "\\\\textbf{bold} \\\\textcolor{red}{red}"
    rendered

-- | The style command must cross the wire, take effect, and come back as a plan.
--
-- Written as JSON and decoded again rather than constructed directly, so the
-- request the browser sends is the request that is tested.
styledEditRoundTrip :: IO ()
styledEditRoundTrip = do
  let source =
        ByteString.Char8.pack
          "\\node (a) at (1,2) {\\textbf{a}<em>b</em>c};\n\\draw (a) -- (9,8);\n"
      snapshot = snapshotAtRevision (revisionFromWord64 1) source
  runs <- styledRunPaths snapshot
  (firstPath, secondPath) <-
    case runs of
      one : two : _ -> pure (one, two)
      _ -> failTest ("expected at least two runs, got " <> show (length runs))
  let requestJSON =
        Text.Encoding.encodeUtf8
          ( Text.concat
              [ "{\"protocol\":\"slideblaster.engine/1\""
              , ",\"command\":\"style_tikz_node\""
              , ",\"snapshot\":"
              , snapshotJSON snapshot
              , ",\"intent\":{\"revision\":1,\"nodeId\":\"a\""
              , ",\"themeDialect\":\"latex\",\"command\":"
              , "{\"target\":{\"kind\":\"between\""
              , ",\"start\":{\"path\":"
              , pathJSON firstPath
              , ",\"offset\":0}"
              , ",\"end\":{\"path\":"
              , pathJSON secondPath
              , ",\"offset\":1}}"
              , ",\"effect\":{\"kind\":\"set\",\"style\":"
              , "{\"property\":\"underline\",\"value\":true}}}}}"
              ]
          )
  request <-
    requireRight "style request did not decode" (decodeEngineRequestJSON requestJSON)
  response <- requireRight "style request was refused" (runEngineRequest request)
  let rendered = Text.Encoding.decodeUtf8 (encodeEngineResponseJSON response)
  assertContains "the edit was verified" "verified_change" rendered
  assertContains
    "the LaTeX construct is re-spelled in LaTeX"
    "\\\\underline{\\\\textbf{a}}"
    rendered
  assertContains
    "the HTML construct is re-spelled in HTML"
    "<u><em>b</em></u>"
    rendered
  assertContains "the revision advanced" "\"afterRevision\":2" rendered

-- | A toggle sent over the wire against content that already has the property
-- removes it, rather than asserting it a second time.
--
-- The interface sends the same effect either way; which of set or clear it means
-- is decided in Haskell from the tree, so this is the wire form of that decision.
toggledEditRoundTrip :: IO ()
toggledEditRoundTrip = do
  let source =
        ByteString.Char8.pack
          "\\node (a) at (1,2) {\\textbf{ab}};\n\\draw (a) -- (9,8);\n"
      snapshot = snapshotAtRevision (revisionFromWord64 1) source
  runs <- styledRunPaths snapshot
  onlyPath <-
    case runs of
      one : _ -> pure one
      [] -> failTest "expected at least one run"
  let requestJSON =
        Text.Encoding.encodeUtf8
          ( Text.concat
              [ "{\"protocol\":\"slideblaster.engine/1\""
              , ",\"command\":\"style_tikz_node\""
              , ",\"snapshot\":"
              , snapshotJSON snapshot
              , ",\"intent\":{\"revision\":1,\"nodeId\":\"a\""
              , ",\"themeDialect\":\"latex\",\"command\":"
              , "{\"target\":{\"kind\":\"between\""
              , ",\"start\":{\"path\":"
              , pathJSON onlyPath
              , ",\"offset\":0}"
              , ",\"end\":{\"path\":"
              , pathJSON onlyPath
              , ",\"offset\":2}}"
              , ",\"effect\":{\"kind\":\"toggle\",\"style\":"
              , "{\"property\":\"weight\",\"value\":\"bold\"}}}}}"
              ]
          )
  request <-
    requireRight "toggle request did not decode" (decodeEngineRequestJSON requestJSON)
  response <- requireRight "toggle request was refused" (runEngineRequest request)
  let rendered = Text.Encoding.decodeUtf8 (encodeEngineResponseJSON response)
  assertContains "the toggle was verified" "verified_change" rendered
  assertContains
    "the bold command is gone from the node's source"
    "\"content\":\"ab\""
    rendered
  assertNotContains
    "no opposing command was added"
    "textmd"
    rendered
  assertContains "the revision advanced" "\"afterRevision\":2" rendered

-- | The theme's notation crosses the wire and decides how a new construct is
-- written where nothing else settles it.
--
-- The same bytes, the same selection and the same effect produce LaTeX under one
-- setting and HTML under another, which is what makes it a setting rather than a
-- guess. It is a required field: a default in the codec would be a second, silent
-- opinion about a theme.
themeDialectRoundTrip :: IO ()
themeDialectRoundTrip = do
  let source =
        ByteString.Char8.pack
          "\\node (a) at (1,2) {plain};\n\\draw (a) -- (9,8);\n"
      snapshot = snapshotAtRevision (revisionFromWord64 1) source
  runs <- styledRunPaths snapshot
  onlyPath <-
    case runs of
      one : _ -> pure one
      [] -> failTest "expected at least one run"
  let requestFor notation =
        Text.Encoding.encodeUtf8
          ( Text.concat
              [ "{\"protocol\":\"slideblaster.engine/1\""
              , ",\"command\":\"style_tikz_node\""
              , ",\"snapshot\":"
              , snapshotJSON snapshot
              , ",\"intent\":{\"revision\":1,\"nodeId\":\"a\""
              , ",\"themeDialect\":\""
              , notation
              , "\",\"command\":"
              , "{\"target\":{\"kind\":\"between\""
              , ",\"start\":{\"path\":"
              , pathJSON onlyPath
              , ",\"offset\":0}"
              , ",\"end\":{\"path\":"
              , pathJSON onlyPath
              , ",\"offset\":5}}"
              , ",\"effect\":{\"kind\":\"set\",\"style\":"
              , "{\"property\":\"weight\",\"value\":\"bold\"}}}}}"
              ]
          )
      renderedUnder notation = do
        request <-
          requireRight
            ("style request did not decode under " <> Text.unpack notation)
            (decodeEngineRequestJSON (requestFor notation))
        response <-
          requireRight
            ("style request was refused under " <> Text.unpack notation)
            (runEngineRequest request)
        pure (Text.Encoding.decodeUtf8 (encodeEngineResponseJSON response))
  underLatex <- renderedUnder "latex"
  underHtml <- renderedUnder "html"
  underMarkdown <- renderedUnder "markdown"
  assertContains "a LaTeX theme writes LaTeX" "\\\\textbf{plain}" underLatex
  assertContains "an HTML theme writes HTML" "<b>plain</b>" underHtml
  assertContains "a Markdown theme writes Markdown" "**plain**" underMarkdown
  assertProtocolDecodeFailure
    "an unknown notation is refused rather than defaulted"
    (requestFor "klingon")

-- | The run paths the host would read off the rendered plan.
styledRunPaths :: SourceBufferSnapshot -> IO [[Int]]
styledRunPaths snapshot =
  case analyzeTikzSnapshot snapshot of
    TikzAnalysisSyntaxOnly _ diagnostics ->
      failTest ("expected a ready analysis, got " <> show diagnostics)
    TikzAnalysisReady document _ ->
      case documentPicture document of
        Nothing -> failTest "expected a picture"
        Just picture ->
          pure
            ( fmap
                (pathToList . runPath)
                ( nodeContentRuns
                    (readNodeContent (nodeContent (pictureNode picture)))
                )
            )

-- | A snapshot as the browser sends one: exact bytes in base16.
snapshotJSON :: SourceBufferSnapshot -> Text
snapshotJSON snapshot =
  Text.concat
    [ "{\"revision\":"
    , Text.pack (show (revisionToWord64 (snapshotRevision snapshot)))
    , ",\"source\":\""
    , base16 (snapshotBytes snapshot)
    , "\",\"encoding\":\"base16\"}"
    ]
  where
    base16 =
      Text.concat
        . fmap (Text.pack . printf "%02x")
        . ByteString.unpack

pathJSON :: [Int] -> Text
pathJSON indices =
  "[" <> Text.intercalate "," (fmap (Text.pack . show) indices) <> "]"

syntaxOnlyResponse :: IO ()
syntaxOnlyResponse = do
  response <-
    requireRight
      "syntax-only analysis was rejected as a wire failure"
      ( runEngineRequest
          ( AnalyzeTikz
              ( snapshotAtRevision
                  (revisionFromWord64 1)
                  malformedFixture
              )
          )
      )
  assertEncodedJsonEqual
    "syntax-only analysis response"
    ( object
        [ "protocol" .= engineProtocol
        , "ok" .= True
        , "response" .= ("tikz_analysis" :: Text)
        , "snapshot" .= snapshotValue 1 malformedSourceHex
        , "analysis"
            .= object
              [ "state" .= ("syntax_only" :: Text)
              , "diagnostics"
                  .= [ object
                        [ "category" .= ("malformed" :: Text)
                        , "code" .= ("expected_syntax_token" :: Text)
                        , "span"
                            .= object
                              [ "start" .= (5 :: Int)
                              , "end" .= (5 :: Int)
                              ]
                        , "message"
                            .= ("Expected '(' before the node identifier" :: Text)
                        ]
                     ]
              ]
        ]
    )
    (encodeEngineResponseJSON response)

verifiedMoveResponse :: IO ()
verifiedMoveResponse = do
  request <-
    requireDecoded
      "verified move request was rejected"
      ( moveRequestValue
          0
          sharedSourceHex
          0
          "alpha"
          (pointValue "4" "5")
      )
  response <-
    requireRight "verified move failed" (runEngineRequest request)
  assertEncodedJsonEqual
    "verified move response"
    ( object
        [ "protocol" .= engineProtocol
        , "ok" .= True
        , "response" .= ("tikz_move" :: Text)
        , "snapshot" .= snapshotValue 1 sharedMovedSourceHex
        , "move"
            .= moveValue "verified_change" 0 1 "alpha" "4" "5"
        , "analysis" .= readyAnalysisValue 1 "4" "5" "π 😀" unicodeRuns
        ]
    )
    (encodeEngineResponseJSON response)

unchangedMoveResponse :: IO ()
unchangedMoveResponse = do
  request <-
    requireDecoded
      "no-op move request was rejected"
      ( moveRequestValue
          0
          sharedSourceHex
          0
          "alpha"
          (pointValue "1.5" "0")
      )
  response <-
    requireRight "no-op move failed" (runEngineRequest request)
  assertEncodedJsonEqual
    "unchanged move response"
    ( object
        [ "protocol" .= engineProtocol
        , "ok" .= True
        , "response" .= ("tikz_move" :: Text)
        , "snapshot" .= snapshotValue 0 sharedSourceHex
        , "move"
            .= moveValue "unchanged" 0 0 "alpha" "1.5" "0"
        , "analysis" .= readyAnalysisValue 0 "1.5" "0" "π 😀" unicodeRuns
        ]
    )
    (encodeEngineResponseJSON response)

staleMoveResponse :: IO ()
staleMoveResponse = do
  request <-
    requireDecoded
      "stale move fixture did not decode"
      ( moveRequestValue
          9
          canonicalSourceHex
          8
          "alpha"
          (pointValue "4" "5")
      )
  problem <-
    requireLeft "stale move unexpectedly succeeded" (runEngineRequest request)
  let encoded = encodeProtocolErrorJSON problem
  assertEncodedJsonEqual
    "stale move response"
    ( errorResponseValue
        "stale_revision"
        "The move targets a stale source revision"
        ( object
            [ "requestedRevision" .= (8 :: Word64)
            , "actualRevision" .= (9 :: Word64)
            ]
        )
    )
    encoded
  assertRejectedResponseHasNoSnapshot "stale move" encoded
  assertNotContainsEncoded
    "stale move error redacts exact source"
    canonicalSourceHex
    encoded

unavailableMoveResponse :: IO ()
unavailableMoveResponse = do
  request <-
    requireDecoded
      "syntax-only move fixture did not decode"
      ( moveRequestValue
          5
          malformedSourceHex
          5
          "alpha"
          (pointValue "4" "5")
      )
  problem <-
    requireLeft
      "syntax-only source unexpectedly accepted a move"
      (runEngineRequest request)
  let encoded = encodeProtocolErrorJSON problem
  assertEncodedJsonEqual
    "semantics-unavailable response"
    ( errorResponseValue
        "tikz_semantics_unavailable"
        "The exact source has no writable TikZ semantics"
        (object [])
    )
    encoded
  assertRejectedResponseHasNoSnapshot "semantics unavailable" encoded
  assertNotContainsEncoded
    "semantics-unavailable error redacts exact source"
    malformedSourceHex
    encoded

tikzErrorMapping :: IO ()
tikzErrorMapping = do
  nodeIdentity <-
    case mkNodeId "private_target" of
      Nothing -> failTest "test bug: valid target identity was rejected"
      Just value -> pure value
  let mappedCases =
        [ ( "target missing"
          , MoveTargetMissing nodeIdentity
          , "tikz_target_missing"
          )
        , ( "target ambiguous"
          , MoveTargetAmbiguous nodeIdentity
          , "tikz_target_ambiguous"
          )
        , ( "projection unsupported"
          , MoveProjectionUnsupported nodeIdentity
          , "tikz_projection_unsupported"
          )
        , ( "source expected mismatch"
          , MoveSourceCheckFailed (ReplacementExpectedMismatch 3 4)
          , "expected_bytes_mismatch"
          )
        , ( "parse verification"
          , MoveVerificationFailed VerificationParseOrElaborationFailed
          , "tikz_verification_failed"
          )
        , ( "semantic verification"
          , MoveVerificationFailed VerificationSemanticMismatch
          , "tikz_verification_failed"
          )
        ]
  forM_ mappedCases $ \(label, moveError, expectedCode) -> do
    let encoded =
          encodeProtocolErrorJSON (ProtocolTikzMoveError moveError)
    actual <- decodeJson ("invalid " <> label <> " error JSON") encoded
    code <- requireTextAt [Key.fromString "error", Key.fromString "code"] actual
    assertEqual (label <> " stable code") expectedCode code
    assertRejectedResponseHasNoSnapshot label encoded
    assertNotContainsEncoded
      (label <> " does not disclose authored source")
      canonicalSourceHex
      encoded
  assertVerificationReason
    VerificationParseOrElaborationFailed
    "parse_or_elaboration_failed"
  assertVerificationReason
    VerificationSemanticMismatch
    "semantic_mismatch"

assertVerificationReason :: VerificationFailure -> Text -> IO ()
assertVerificationReason failure expectedReason = do
  let encoded =
        encodeProtocolErrorJSON
          (ProtocolTikzMoveError (MoveVerificationFailed failure))
  actual <- decodeJson "verification error JSON" encoded
  reason <-
    requireTextAt
      [ Key.fromString "error"
      , Key.fromString "details"
      , Key.fromString "reason"
      ]
      actual
  assertEqual "verification reason" expectedReason reason

snapshotValue :: Word64 -> Text -> Value
snapshotValue revision source =
  object
    [ "revision" .= revision
    , "source" .= source
    , "encoding" .= ("base16" :: Text)
    ]

moveRequestValue
  :: Word64
  -> Text
  -> Word64
  -> Text
  -> Value
  -> Value
moveRequestValue snapshotRevisionValue source intentRevision nodeIdentity destination =
  object
    [ "protocol" .= engineProtocol
    , "command" .= ("move_tikz_node" :: Text)
    , "snapshot" .= snapshotValue snapshotRevisionValue source
    , "intent"
        .= object
          [ "revision" .= intentRevision
          , "nodeId" .= nodeIdentity
          , "destination" .= destination
          ]
    ]

-- | @"π 😀"@ reads as two character runs separated by whitespace.
unicodeRuns :: [Value]
unicodeRuns =
  [ runValue "plain" "π" [0] (Just "tex")
  , runValue "plain" " " [1] Nothing
  , runValue "plain" "😀" [2] (Just "tex")
  ]

pointValue :: Text -> Text -> Value
pointValue xCoordinate yCoordinate =
  object
    [ "x" .= xCoordinate
    , "y" .= yCoordinate
    ]

-- | Unstyled body text, as the lowering reports it when no construct applies.
unstyledValue :: Value
unstyledValue =
  object
    [ "weight" .= ("normal" :: Text)
    , "slant" .= ("upright" :: Text)
    , "family" .= ("serif" :: Text)
    , "variant" .= ("normal" :: Text)
    , "underline" .= False
    , "strike" .= False
    , "highlight" .= False
    , "foreground" .= Null
    , "background" .= Null
    ]

-- | One expected run. Whitespace carries no dialect because it is spelled
-- identically in every dialect, so there is nothing to attribute.
runValue :: Text -> Text -> [Int] -> Maybe Text -> Value
runValue kind text path dialect =
  object
    [ "kind" .= kind
    , "text" .= text
    , "path" .= path
    , "dialect" .= maybe Null (\name -> object ["name" .= name]) dialect
    , "link" .= Null
    , "style" .= unstyledValue
    ]

readyAnalysisValue :: Word64 -> Text -> Text -> Text -> [Value] -> Value
readyAnalysisValue revision xCoordinate yCoordinate content runs =
  object
    [ "state" .= ("ready" :: Text)
    , "renderPlan"
        .= object
          [ "sourceRevision" .= revision
          , "coordinateSpace" .= ("slide_16x9_y_up" :: Text)
          , "node"
              .= object
                [ "kind" .= ("content_node" :: Text)
                , "id" .= ("alpha" :: Text)
                , "center" .= pointValue xCoordinate yCoordinate
                , "content" .= content
                , "contentStatus" .= object ["kind" .= ("understood" :: Text)]
                , "runs" .= runs
                , "issues" .= ([] :: [Value])
                ]
          , "connector"
              .= object
                [ "kind" .= ("straight_connector" :: Text)
                , "start" .= pointValue xCoordinate yCoordinate
                , "end" .= pointValue "9" "8"
                ]
          ]
    ]

moveValue :: Text -> Word64 -> Word64 -> Text -> Text -> Text -> Value
moveValue outcome beforeRevision afterRevision nodeIdentity xCoordinate yCoordinate =
  object
    [ "outcome" .= outcome
    , "beforeRevision" .= beforeRevision
    , "afterRevision" .= afterRevision
    , "nodeId" .= nodeIdentity
    , "destination" .= pointValue xCoordinate yCoordinate
    ]

errorResponseValue :: Text -> Text -> Value -> Value
errorResponseValue code message details =
  object
    [ "protocol" .= engineProtocol
    , "ok" .= False
    , "error"
        .= object
          [ "code" .= code
          , "message" .= message
          , "details" .= details
          ]
    ]

requireDecoded :: String -> Value -> IO EngineRequest
requireDecoded label value =
  requireRight label (decodeEngineRequestJSON (strictJson value))

assertInvalidField :: String -> Value -> IO ()
assertInvalidField label value =
  case decodeEngineRequestJSON (strictJson value) of
    Left problem@(ProtocolDecodeError (ProtocolInvalidField _)) -> do
      let encoded = encodeProtocolErrorJSON problem
      assertRejectedResponseHasNoSnapshot label encoded
    other -> failTest (label <> ": expected invalid_field, got " <> show other)

assertProtocolDecodeFailure :: String -> ByteString -> IO ()
assertProtocolDecodeFailure label encoded =
  case decodeEngineRequestJSON encoded of
    Left (ProtocolDecodeError _) -> pure ()
    other -> failTest (label <> ": " <> show other)

assertEncodedJsonEqual :: String -> Value -> ByteString -> IO ()
assertEncodedJsonEqual label expected encoded = do
  actual <- decodeJson (label <> " is invalid JSON") encoded
  assertEqual label expected actual

assertRejectedResponseHasNoSnapshot :: String -> ByteString -> IO ()
assertRejectedResponseHasNoSnapshot label encoded = do
  value <- decodeJson (label <> " error response is invalid JSON") encoded
  assertObjectKeys
    (label <> " error envelope")
    ["error", "ok", "protocol"]
    value
  errorValue <- requireField (Key.fromString "error") value
  assertObjectKeys
    (label <> " error object")
    ["code", "details", "message"]
    errorValue

assertObjectKeys :: String -> [Text] -> Value -> IO ()
assertObjectKeys label expected value =
  case value of
    Object fields ->
      assertEqual
        label
        (sort expected)
        (sort (Key.toText <$> KeyMap.keys fields))
    _ -> failTest (label <> ": expected an object")

requireTextAt :: [Key.Key] -> Value -> IO Text
requireTextAt path value =
  case path of
    [] ->
      case value of
        String textValue -> pure textValue
        _ -> failTest "expected a JSON string at the requested path"
    key : rest -> do
      nested <- requireField key value
      requireTextAt rest nested

requireField :: Key.Key -> Value -> IO Value
requireField key value =
  case value of
    Object fields ->
      case KeyMap.lookup key fields of
        Nothing -> failTest ("missing JSON field: " <> show (Key.toText key))
        Just nested -> pure nested
    _ -> failTest ("expected JSON object before field: " <> show (Key.toText key))

decodeJson :: String -> ByteString -> IO Value
decodeJson label encoded =
  case eitherDecodeStrict' encoded of
    Left problem -> failTest (label <> ": " <> problem)
    Right value -> pure value

readJson :: ByteString -> Value
readJson encoded =
  case eitherDecodeStrict' encoded of
    Left problem -> error ("test bug: invalid JSON fixture: " <> problem)
    Right value -> value

strictJson :: Value -> ByteString
strictJson = LazyByteString.toStrict . encode

requireSpan :: Int -> Int -> SourceSpan
requireSpan start end =
  case sourceSpanFromInts start end of
    Nothing -> error "test bug: invalid source span"
    Just spanValue -> spanValue

requireRight :: Show problem => String -> Either problem value -> IO value
requireRight label result =
  case result of
    Left problem -> failTest (label <> ": " <> show problem)
    Right value -> pure value

requireLeft :: Show value => String -> Either problem value -> IO problem
requireLeft label result =
  case result of
    Left problem -> pure problem
    Right value -> failTest (label <> ": " <> show value)

assertContains :: String -> Text -> Text -> IO ()
assertContains label needle haystack =
  unless (needle `Text.isInfixOf` haystack) $
    failTest (label <> ": expected output to contain " <> show needle)

assertNotContains :: String -> Text -> Text -> IO ()
assertNotContains label needle haystack =
  unless (not (needle `Text.isInfixOf` haystack)) $
    failTest (label <> ": output disclosed " <> show needle)

assertNotContainsEncoded :: String -> Text -> ByteString -> IO ()
assertNotContainsEncoded label needle =
  assertNotContains label needle . Text.Encoding.decodeUtf8

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $
    failTest (label <> ": expected " <> show expected <> ", got " <> show actual)

failTest :: String -> IO value
failTest message = do
  putStrLn ("FAIL: " <> message)
  exitFailure

canonicalFixture :: ByteString
canonicalFixture =
  ByteString.Char8.pack
    "\\node (alpha) at (1,2) {hello};\n\\draw (alpha) -- (9,8);\n"

canonicalSourceHex :: Text
canonicalSourceHex =
  "5c6e6f64652028616c706861292061742028312c3229207b68656c6c6f7d3b0a5c647261772028616c70686129202d2d2028392c38293b0a"

styledFixture :: ByteString
styledFixture =
  ByteString.Char8.pack
    "\\node (alpha) at (1,2) {\\textbf{bold} \\textcolor{red}{red}};\n\\draw (alpha) -- (9,8);\n"

malformedFixture :: ByteString
malformedFixture = ByteString.Char8.pack "\\node"

malformedSourceHex :: Text
malformedSourceHex = "5c6e6f6465"

sharedSourceHex :: Text
sharedSourceHex =
  "25206c6561640a5c6e6f6465202520636f6d6d616e640a2028616c70686129092061742028202b3030312e35303030202520780a202c09202d3030302e30302029207bcf8020f09f98807d3b2025206265747765656e0a5c647261770928616c70686129202d2d2028392e30202c2038293b0a"

sharedMovedSourceHex :: Text
sharedMovedSourceHex =
  "25206c6561640a5c6e6f6465202520636f6d6d616e640a2028616c706861290920617420282034202520780a202c0920352029207bcf8020f09f98807d3b2025206265747765656e0a5c647261770928616c70686129202d2d2028392e30202c2038293b0a"
