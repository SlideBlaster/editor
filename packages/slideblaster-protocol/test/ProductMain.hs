{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Native laws for the interactive product JSON protocol.
--
-- These tests exercise the same pure dispatcher used by the Wasm reactor.
-- They pin atomic stale/error behaviour, direct outline projection, and the
-- closed theme-editor bridge without reproducing semantic policy in a host.
module Main (main) where

import SlideBlaster.App
  ( LiveAuthoring
  , newLiveAuthoring
  )
import SlideBlaster.Protocol
  ( LiveProductRequest
  , decodeLiveRequestJSON
  , dispatchLiveRequestJSON
  , productProtocol
  , themeEditorProtocol
  )

import Data.Aeson
  ( Value (..)
  , eitherDecodeStrict'
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (toList)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding

import Control.Monad (unless)
import System.Exit (exitFailure)

main :: IO ()
main = do
  run "catalog initialization and search use shared Haskell data" catalogSearchLaw
  run "insert and snapped move return direct workspace geometry" insertMoveLaw
  run "stale requests cannot mutate live state" staleRequestLaw
  run "imported arcs remain explicit direct path segments" arcProjectionLaw
  run "theme-editor apply intents mutate only supported controls" themeIntentLaw
  run "unsupported theme phases are typed and atomic" themeFailureLaw
  run "direct theme, selection, undo, and redo commands compose" directCommandLaw
  run "product requests and responses are closed JSON" jsonClosureLaw

run :: String -> IO () -> IO ()
run name check = do
  check
  putStrLn ("PASS: " <> name)

catalogSearchLaw :: IO ()
catalogSearchLaw = do
  initial <- requireInitial
  (withCatalog, initialized) <-
    dispatchValue initial (initializeCatalogRequest catalogFixtureText)
  assertTextField "catalog init kind" "catalog_initialized" "kind" initialized
  assertBoolField "catalog init succeeds" True "ok" initialized
  workspace <- field "workspace" initialized
  families <- field "catalogFamilies" workspace >>= arrayValues "catalog families"
  assertTrue
    "imported family is advertised"
    (any (hasTextField "name" "Tests") families)

  (afterSearch, response) <-
    dispatchValue
      withCatalog
      ( request
          "search_catalog"
          [ "query" .= ("Arc Fixture" :: Text)
          , "family" .= ("Tests" :: Text)
          , "limit" .= (10 :: Int)
          ]
      )
  assertEqual "search is read-only" withCatalog afterSearch
  results <- field "results" response >>= arrayValues "search results"
  assertEqual "one fixture result" 1 (length results)
  result <- onlyValue "search result" results
  assertTextField "shape id" "tests.arc" "id" result
  assertTextField "shape family" "Tests" "family" result
  assertTextField "shape priority" "p2" "priority" result

insertMoveLaw :: IO ()
insertMoveLaw = do
  initial <- requireInitial
  (inserted, insertedResponse) <-
    dispatchValue
      initial
      ( request
          "insert_shape"
          [ "revision" .= (0 :: Int)
          , "shapeId" .= ("rectangle" :: Text)
          , "point" .= pointRequest "1" "1"
          ]
      )
  insertedWorkspace <- field "workspace" insertedResponse
  assertNumberField "insert revision" 1 "revision" insertedWorkspace
  insertedNodes <- field "nodes" insertedWorkspace >>= arrayValues "inserted nodes"
  insertedNode <- onlyValue "inserted node" insertedNodes
  assertTextField "generated semantic id" "shape-1" "id" insertedNode
  insertedOutlines <-
    field "outlines" insertedNode >>= arrayValues "inserted outlines"
  insertedOutline <- onlyValue "inserted outline" insertedOutlines
  assertTextField "rectangle lowers directly" "rectangle" "kind" insertedOutline

  (_, movedResponse) <-
    dispatchValue
      inserted
      ( request
          "move_node"
          [ "revision" .= (1 :: Int)
          , "nodeId" .= ("shape-1" :: Text)
          , "point" .= pointRequest "8.1" "4.6"
          , "mode" .= ("snap" :: Text)
          ]
      )
  movedWorkspace <- field "workspace" movedResponse
  assertNumberField "move revision" 2 "revision" movedWorkspace
  movedNodes <- field "nodes" movedWorkspace >>= arrayValues "moved nodes"
  movedNode <- onlyValue "moved node" movedNodes
  centre <- field "box" movedNode >>= field "center"
  assertNumberField "snapped centre x" 8 "x" centre
  assertNumberField "snapped centre y" 4.5 "y" centre
  guides <- field "snapGuides" movedWorkspace >>= arrayValues "snap guides"
  assertTrue "snap guides are semantic output" (not (null guides))

staleRequestLaw :: IO ()
staleRequestLaw = do
  initial <- requireInitial
  (inserted, _) <-
    dispatchValue
      initial
      ( request
          "insert_shape"
          [ "revision" .= (0 :: Int)
          , "shapeId" .= ("rectangle" :: Text)
          , "point" .= pointRequest "1" "1"
          ]
      )
  (afterStale, staleResponse) <-
    dispatchValue
      inserted
      ( request
          "move_node"
          [ "revision" .= (0 :: Int)
          , "nodeId" .= ("shape-1" :: Text)
          , "point" .= pointRequest "5" "5"
          , "mode" .= ("free" :: Text)
          ]
      )
  assertEqual "stale request preserves exact state" inserted afterStale
  assertBoolField "stale response is rejected" False "ok" staleResponse
  failure <- field "error" staleResponse
  assertTextField "stale error code" "stale_revision" "code" failure

arcProjectionLaw :: IO ()
arcProjectionLaw = do
  initial <- requireInitial
  (withCatalog, _) <-
    dispatchValue initial (initializeCatalogRequest catalogFixtureText)
  (_, response) <-
    dispatchValue
      withCatalog
      ( request
          "search_catalog"
          [ "query" .= ("Arc Fixture" :: Text)
          , "family" .= Null
          , "limit" .= (10 :: Int)
          ]
      )
  result <-
    field "results" response
      >>= arrayValues "arc results"
      >>= onlyValue "arc result"
  outline <-
    field "outlines" result
      >>= arrayValues "arc outlines"
      >>= onlyValue "arc outline"
  assertTextField "arc outline is a path" "path" "kind" outline
  subpath <-
    field "subpaths" outline
      >>= arrayValues "arc subpaths"
      >>= onlyValue "arc subpath"
  segment <-
    field "segments" subpath
      >>= arrayValues "arc segments"
      >>= onlyValue "arc segment"
  assertKeys
    "arc segment closure"
    ["end", "kind", "largeArc", "radii", "rotation", "sweep"]
    segment
  assertTextField "arc segment kind" "arc" "kind" segment
  assertBoolField "large-arc flag survives" True "largeArc" segment
  assertTextField
    "y-down import sweep is normalized explicitly"
    "counter_clockwise"
    "sweep"
    segment

themeIntentLaw :: IO ()
themeIntentLaw = do
  initial <- requireInitial
  (named, _) <-
    dispatchValue
      initial
      ( themeControlRequest
          0
          "theme_name"
          ( object
              [ "kind" .= ("theme_metadata" :: Text)
              , "property" .= ("name" :: Text)
              ]
          )
          (String "Protocol Theme")
      )
  (recoloured, _) <-
    dispatchValue
      named
      ( themeControlRequest
          1
          "palette_accent_colour"
          ( object
              [ "kind" .= ("palette_colour" :: Text)
              , "name" .= ("accent" :: Text)
              ]
          )
          (String "#10203080")
      )
  (_, distanceResponse) <-
    dispatchValue
      recoloured
      ( themeControlRequest
          2
          "node_distance"
          (object ["kind" .= ("node_distance" :: Text)])
          (String "3/4")
      )
  workspace <- field "workspace" distanceResponse
  theme <- field "theme" workspace
  assertTextField "theme name changed" "Protocol Theme" "name" theme
  assertNumberField "node distance changed" 0.75 "nodeDistance" theme
  palette <- field "palette" theme >>= arrayValues "theme palette"
  accent <- requireMatching "accent palette entry" (hasTextField "name" "accent") palette
  assertTextField "alpha colour changed" "#10203080" "colour" accent

  editor <- field "themeEditor" workspace
  assertTextField
    "theme editor protocol"
    themeEditorProtocol
    "protocol"
    editor
  assertNumberField "theme projection revision" 3 "projectionRevision" editor
  save <- field "save" editor
  assertBoolField "theme save remains disabled" False "enabled" save

themeFailureLaw :: IO ()
themeFailureLaw = do
  initial <- requireInitial
  let preview =
        object
          [ "protocol" .= productProtocol
          , "command" .= ("theme_intent" :: Text)
          , "intent"
              .= object
                [ "protocol" .= themeEditorProtocol
                , "projectionRevision" .= (0 :: Int)
                , "themeId" .= ("default" :: Text)
                , "phase" .= ("preview" :: Text)
                , "edit"
                    .= object
                      [ "kind" .= ("set_control" :: Text)
                      , "controlId" .= ("theme_name" :: Text)
                      , "target"
                          .= object
                            [ "kind" .= ("theme_metadata" :: Text)
                            , "property" .= ("name" :: Text)
                            ]
                      , "state"
                          .= object
                            [ "kind" .= ("set" :: Text)
                            , "value" .= ("Preview" :: Text)
                            ]
                      ]
                ]
          ]
  (afterPreview, response) <- dispatchValue initial preview
  assertEqual "preview preserves exact state" initial afterPreview
  failure <- field "error" response
  assertTextField
    "preview rejection code"
    "theme_preview_not_supported"
    "code"
    failure

directCommandLaw :: IO ()
directCommandLaw = do
  initial <- requireInitial
  (named, namedResponse) <-
    dispatchValue
      initial
      ( request
          "set_theme_name"
          [ "revision" .= (0 :: Int)
          , "name" .= ("Direct Theme" :: Text)
          ]
      )
  assertTextField "direct name command" "theme_name_set" "kind" namedResponse
  (recoloured, _) <-
    dispatchValue
      named
      ( request
          "set_palette_colour"
          [ "revision" .= (1 :: Int)
          , "key" .= ("accent" :: Text)
          , "colour" .= ("#AABBCC" :: Text)
          ]
      )
  (distanced, _) <-
    dispatchValue
      recoloured
      ( request
          "set_node_distance"
          [ "revision" .= (2 :: Int)
          , "distance" .= ("5/4" :: Text)
          ]
      )
  (deselected, selectionResponse) <-
    dispatchValue distanced (request "select_node" [])
  assertEqual "selection is transient" distanced deselected
  assertTextField
    "missing optional node id clears selection"
    "selection_changed"
    "kind"
    selectionResponse
  (undone, undoResponse) <-
    dispatchValue
      deselected
      (request "undo" ["revision" .= (3 :: Int)])
  undoWorkspace <- field "workspace" undoResponse
  assertBoolField "undo enables redo" True "canRedo" undoWorkspace
  (redone, redoResponse) <-
    dispatchValue
      undone
      (request "redo" ["revision" .= (4 :: Int)])
  assertTrue "redo produces a new state" (redone /= undone)
  redoWorkspace <- field "workspace" redoResponse
  redoTheme <- field "theme" redoWorkspace
  assertNumberField "redo restores node distance" 1.25 "nodeDistance" redoTheme

jsonClosureLaw :: IO ()
jsonClosureLaw = do
  initial <- requireInitial
  (_, snapshotResponse) <-
    dispatchValue initial (request "workspace_snapshot" [])
  assertKeys
    "workspace response envelope"
    ["kind", "ok", "protocol", "workspace"]
    snapshotResponse
  workspace <- field "workspace" snapshotResponse
  assertKeys
    "workspace projection"
    [ "canRedo"
    , "canUndo"
    , "catalogFamilies"
    , "nodes"
    , "persistenceReason"
    , "persistent"
    , "revision"
    , "selectedNodeId"
    , "snapGuides"
    , "theme"
    , "themeEditor"
    ]
    workspace
  editor <- field "themeEditor" workspace
  assertKeys
    "theme editor root"
    ["projectionRevision", "protocol", "save", "sections", "theme"]
    editor

  let withExtra =
        request
          "workspace_snapshot"
          ["extra" .= True]
  (afterFailure, failureResponse) <- dispatchValue initial withExtra
  assertEqual "closed decoder failure is atomic" initial afterFailure
  assertKeys
    "error response envelope"
    ["error", "kind", "ok", "protocol"]
    failureResponse
  failure <- field "error" failureResponse
  assertKeys "error payload" ["code", "message"] failure
  assertTextField "extra field error" "invalid_field" "code" failure

  decodedCatalog <-
    decodeRequest
      (initializeCatalogRequest catalogFixtureText)
  assertTrue
    "catalog payload is redacted from request rendering"
    (not ("Arc Fixture" `Text.isInfixOf` Text.pack (show decodedCatalog)))

  decodedThemeName <-
    decodeRequest
      ( themeControlRequest
          0
          "theme_name"
          (object ["kind" .= ("theme_metadata" :: Text), "property" .= ("name" :: Text)])
          (String "secret-theme-name")
      )
  assertTrue
    "theme value is redacted from request rendering"
    (not ("secret-theme-name" `Text.isInfixOf` Text.pack (show decodedThemeName)))

request :: Text -> [Pair] -> Value
request command fields =
  object
    ( [ "protocol" .= productProtocol
      , "command" .= command
      ]
        <> fields
    )

initializeCatalogRequest :: Text -> Value
initializeCatalogRequest catalogJSON =
  request
    "initialize_catalog"
    ["catalogJson" .= catalogJSON]

pointRequest :: Text -> Text -> Value
pointRequest x y =
  object ["x" .= x, "y" .= y]

themeControlRequest :: Int -> Text -> Value -> Value -> Value
themeControlRequest revision controlIdentity target value =
  request
    "theme_intent"
    [ "intent"
        .= object
          [ "protocol" .= themeEditorProtocol
          , "projectionRevision" .= revision
          , "themeId" .= ("default" :: Text)
          , "phase" .= ("apply" :: Text)
          , "edit"
              .= object
                [ "kind" .= ("set_control" :: Text)
                , "controlId" .= controlIdentity
                , "target" .= target
                , "state"
                    .= object
                      [ "kind" .= ("set" :: Text)
                      , "value" .= value
                      ]
                ]
          ]
    ]

catalogFixtureText :: Text
catalogFixtureText =
  TextEncoding.decodeUtf8
    ( LazyByteString.toStrict
        ( encode
            ( object
                [ "schemaVersion" .= (1 :: Int)
                , "provenance"
                    .= object
                      [ "migrationSource" .= ("protocol fixture" :: Text)
                      , "definitionsCommit" .= Text.replicate 40 "0"
                      , "geometryCommit" .= Text.replicate 40 "0"
                      , "definitionsSha256" .= Text.replicate 64 "0"
                      , "geometrySha256" .= Text.replicate 64 "0"
                      , "drawioRepository"
                          .= ("https://example.invalid/drawio" :: Text)
                      , "drawioUpstreamCommit"
                          .= (Nothing :: Maybe Text)
                      , "upstreamCommitStatus" .= ("fixture" :: Text)
                      ]
                , "attribution"
                    .= object
                      [ "title" .= ("Fixture catalog" :: Text)
                      , "author" .= ("Protocol tests" :: Text)
                      , "license" .= ("CC0" :: Text)
                      , "source" .= ("https://example.invalid/catalog" :: Text)
                      ]
                , "shapes"
                    .= [ object
                           [ "id" .= ("tests.arc" :: Text)
                           , "label" .= ("Arc Fixture" :: Text)
                           , "category" .= ("Tests / Fixture" :: Text)
                           , "keywords" .= (["arc", "fixture"] :: [Text])
                           , "size"
                               .= object
                                 [ "width" .= (2 :: Int)
                                 , "height" .= (1 :: Int)
                                 ]
                           , "aspect" .= ("variable" :: Text)
                           , "path"
                               .= ( "M 0 0.5 A 0.5 0.5 0 1 1 1 0.5"
                                     :: Text
                                  )
                           ]
                       ]
                ]
            )
        )
    )

dispatchValue
  :: LiveAuthoring
  -> Value
  -> IO (LiveAuthoring, Value)
dispatchValue authoring requestValue = do
  let requestBytes = LazyByteString.toStrict (encode requestValue)
      (next, responseBytes) =
        dispatchLiveRequestJSON authoring requestBytes
  response <-
    case eitherDecodeStrict' responseBytes of
      Left problem -> failTest ("response is not JSON: " <> problem)
      Right value -> pure value
  pure (next, response)

decodeRequest :: Value -> IO LiveProductRequest
decodeRequest value =
  case decodeLiveRequestJSON requestBytes of
    Left failure -> failTest ("request did not decode: " <> show failure)
    Right decoded -> pure decoded
 where
  requestBytes =
    LazyByteString.toStrict (encode value)

requireInitial :: IO LiveAuthoring
requireInitial =
  case newLiveAuthoring of
    Left failure -> failTest ("initial state failed: " <> show failure)
    Right authoring -> pure authoring

field :: Text -> Value -> IO Value
field key value =
  case value of
    Object objectValue ->
      case KeyMap.lookup (Key.fromText key) objectValue of
        Nothing -> failTest ("missing field: " <> show key)
        Just found -> pure found
    _ -> failTest ("expected object while reading field: " <> show key)

arrayValues :: String -> Value -> IO [Value]
arrayValues _ (Array values) = pure (toList values)
arrayValues label _ = failTest (label <> " is not an array")

onlyValue :: String -> [value] -> IO value
onlyValue _ [value] = pure value
onlyValue label values =
  failTest
    (label <> " expected one value, got " <> show (length values))

requireMatching
  :: String
  -> (Value -> Bool)
  -> [Value]
  -> IO Value
requireMatching _ _ [] = failTest "matching value is missing"
requireMatching label predicate (value : remaining)
  | predicate value = pure value
  | otherwise = requireMatching label predicate remaining

hasTextField :: Text -> Text -> Value -> Bool
hasTextField key expected value =
  case value of
    Object objectValue ->
      KeyMap.lookup (Key.fromText key) objectValue
        == Just (String expected)
    _ -> False

assertTextField :: String -> Text -> Text -> Value -> IO ()
assertTextField label expected key value = do
  actual <- field key value
  assertEqual label (String expected) actual

assertBoolField :: String -> Bool -> Text -> Value -> IO ()
assertBoolField label expected key value = do
  actual <- field key value
  assertEqual label (Bool expected) actual

assertNumberField :: String -> Double -> Text -> Value -> IO ()
assertNumberField label expected key value = do
  actual <- field key value
  case actual of
    Number number ->
      assertEqual label expected (realToFrac number)
    _ -> failTest (label <> ": field is not a number")

assertKeys :: String -> [Text] -> Value -> IO ()
assertKeys label expected value =
  case value of
    Object objectValue ->
      assertEqual
        label
        (sort expected)
        (sort (fmap Key.toText (KeyMap.keys objectValue)))
    _ -> failTest (label <> ": expected an object")

assertTrue :: String -> Bool -> IO ()
assertTrue label condition =
  unless condition (failTest label)

assertEqual
  :: (Eq value, Show value)
  => String
  -> value
  -> value
  -> IO ()
assertEqual label expected actual =
  unless
    (expected == actual)
    ( failTest
        ( label
            <> ": expected "
            <> show expected
            <> ", got "
            <> show actual
        )
    )

failTest :: String -> IO value
failTest message = do
  putStrLn ("FAIL: " <> message)
  exitFailure
