{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Native laws for the raw-event source-authoritative Product/2 protocol.
module Main (main) where

import SlideBlaster.Product.Runtime
  ( ProductV2State
  , dispatchProductV2RequestJSON
  , newProductV2State
  )
import SlideBlaster.Protocol (productProtocolV2)
import Paths_slideblaster_product_runtime qualified as Paths

import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (ord)
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word8)

import Control.Monad (unless)
import System.Exit (exitFailure)

main :: IO ()
main = do
  run "raw pointer/view schema is exact and phase commands are obsolete" closedSchema
  run "keyboard activation selects and focuses without source mutation" keyboardActivation
  run "first unselected press-drag commits one verified operation" firstPressDrag
  run "subthreshold release selects without source history" subthresholdSelection
  run "threshold-crossing semantic no-op creates no history" semanticNoOp
  run "cancel and lost capture clear preview without commit" cancellation
  run "stale pointer samples cannot cross source authority" staleAuthority
  run "common snapping and guides remain Haskell-owned" snapping
  run "Alt selects free mode and bypasses snapping" altFree
  run "real headline direct anchor survives natural and Alt/free drag" realHeadlineDrag
  run "real demo natural snap failures fall back without cancelling drag" realDemoNaturalDrag
  run "rejected replacement preview clears stored operation" rejectedPreview
  run "undo restores exact original bytes" exactUndo
  run "one-slide navigator projection disables traversal" oneSlideNavigator
  run "three-slide navigation and New Slide remain Haskell-owned" deckNavigationAndNewSlide

run :: String -> IO () -> IO ()
run name check = check >> putStrLn ("PASS: " <> name)

closedSchema :: IO ()
closedSchema = do
  assertDispatchError "unknown_command" newProductV2State (request "begin_drag" [])
  assertDispatchError "unknown_command" newProductV2State (request "preview_drag" [])
  assertDispatchError "unknown_command" newProductV2State (request "commit_drag" [])
  assertDispatchError "unknown_command" newProductV2State (request "select_node" [])
  let extra = pointerRequest (downEvent False "1" "0") ["extra" .= True]
  assertDispatchError "invalid_field" newProductV2State extra
  (ready, _) <- readyFixture
  (_, response) <- dispatchValue ready (pointerRequest (downEvent False "1" "0") [])
  assertObjectKeys ["protocol", "ok", "kind", "actions", "workspace"] response
  workspace <- field "workspace" response
  assertObjectKeys
    [ "source", "readiness", "canUndo", "canRedo", "selection"
    , "authority", "renderOffer", "displayedRender", "pointer", "preview"
    , "navigator"
    ]
    workspace
  pointer <- field "pointer" workspace
  assertObjectKeys ["phase", "pointerId"] pointer
  assertText "pressed" "phase" pointer
  actions <- field "actions" response >>= arrayValues "actions"
  capture <- requireMatching (hasTextField "kind" "capture_pointer") actions
  assertNumber 7 "pointerId" capture

firstPressDrag :: IO ()
firstPressDrag = do
  (ready, _) <- readyFixture
  (pressed, pressResponse) <- dispatchValue ready (pointerRequest (downEvent False "3/2" "0") [])
  assertText "alpha" "selection" =<< field "workspace" pressResponse
  (_, response) <- dispatchValue pressed (pointerRequest (upEvent False "4" "5" 13 10) [])
  assertText "pointer_committed" "kind" response
  workspace <- field "workspace" response
  assertNumber 1 "revision" =<< field "source" workspace
  assertBool True "canUndo" workspace
  assertEqual "first-action committed bytes" movedFourFiveFixture =<< sourceBytes workspace
  pointer <- field "pointer" workspace
  assertText "idle" "phase" pointer
  actions <- field "actions" response >>= arrayValues "release actions"
  _ <- requireMatching (hasTextField "kind" "release_pointer") actions
  _ <- requireMatching (hasTextField "kind" "clear_preview") actions
  pure ()

keyboardActivation :: IO ()
keyboardActivation = do
  (ready, readyResponse) <- readyFixture
  original <- workspaceBytes readyResponse
  (activated, response) <-
    dispatchValue ready (request "activate_node" ["surface" .= trialSurface, "nodeId" .= ("alpha" :: Text)])
  assertText "node_activated" "kind" response
  workspace <- field "workspace" response
  assertText "alpha" "selection" workspace
  assertNumber 0 "revision" =<< field "source" workspace
  assertBool False "canUndo" workspace
  assertEqual "keyboard activation exact source" original =<< sourceBytes workspace
  actions <- field "actions" response >>= arrayValues "keyboard actions"
  focus <- requireMatching (hasTextField "kind" "focus_node") actions
  assertText "alpha" "nodeId" focus
  (_, staleResponse) <-
    dispatchValue activated (pointerRequest (terminalEvent "lost_capture") [])
  staleWorkspace <- field "workspace" staleResponse
  assertText "alpha" "selection" staleWorkspace
  assertEqual "stale pointer preserves keyboard source" original =<< sourceBytes staleWorkspace

subthresholdSelection :: IO ()
subthresholdSelection = do
  (ready, _) <- readyFixture
  (pressed, _) <- dispatchValue ready (pointerRequest (downEvent False "3/2" "0") [])
  (_, response) <- dispatchValue pressed (pointerRequest (upEvent False "3/2" "0" 11 10) [])
  workspace <- field "workspace" response
  assertText "alpha" "selection" workspace
  assertNumber 0 "revision" =<< field "source" workspace
  assertBool False "canUndo" workspace
  assertEqual "subthreshold exact source" noncanonicalFixture =<< sourceBytes workspace
  assertNull "subthreshold preview" =<< field "preview" workspace

cancellation :: IO ()
cancellation = do
  (ready, _) <- readyFixture
  (pressed, _) <- dispatchValue ready (pointerRequest (downEvent False "3/2" "0") [])
  (previewed, _) <- dispatchValue pressed (pointerRequest (moveEvent False "6" "7" 13 10) [])
  (cancelled, cancelledResponse) <-

    dispatchValue previewed (pointerRequest (terminalEvent "cancel") [])
  cancelledWorkspace <- field "workspace" cancelledResponse
  assertNull "cancel clears preview" =<< field "preview" cancelledWorkspace
  assertNumber 0 "revision" =<< field "source" cancelledWorkspace
  (pressedAgain, _) <- dispatchValue cancelled (pointerRequest (downEvent False "3/2" "0") [])
  (_, lostResponse) <-
    dispatchValue pressedAgain (pointerRequest (terminalEvent "lost_capture") [])
  lostWorkspace <- field "workspace" lostResponse
  assertText "idle" "phase" =<< field "pointer" lostWorkspace
  assertBool False "canUndo" lostWorkspace
  assertEqual "lost capture source" noncanonicalFixture =<< sourceBytes lostWorkspace

semanticNoOp :: IO ()
semanticNoOp = do
  (ready, _) <- readyFixture
  (pressed, _) <- dispatchValue ready (pointerRequest (downEvent False "3/2" "0") [])
  (_, response) <-
    dispatchValue pressed (pointerRequest (upEvent False "3/2" "0" 13 10) [])
  workspace <- field "workspace" response
  assertNumber 0 "revision" =<< field "source" workspace
  assertBool False "canUndo" workspace
  assertEqual "semantic no-op exact source" noncanonicalFixture =<< sourceBytes workspace
  assertText "idle" "phase" =<< field "pointer" workspace

staleAuthority :: IO ()
staleAuthority = do
  (ready, _) <- readyFixture
  (pressed, _) <- dispatchValue ready (pointerRequest (downEvent False "3/2" "0") [])
  (replaced, replaceResponse) <-
    dispatchValue
      pressed
      (request "replace_source" ["revision" .= (0 :: Int), "sourceBase16" .= base16Encode malformedFixture])
  replacedRevision <- workspaceRevision replaceResponse
  assertEqual "replacement revision" 1 replacedRevision
  (_, delayed) <- dispatchValue replaced (pointerRequest (upEvent False "6" "7" 13 10) [])
  delayedWorkspace <- field "workspace" delayed
  assertNumber 1 "revision" =<< field "source" delayedWorkspace
  assertBool True "canUndo" delayedWorkspace
  assertEqual "stale pointer preserved replacement" malformedFixture =<< sourceBytes delayedWorkspace

snapping :: IO ()
snapping = do
  (ready, _) <- readyFixture
  (pressed, _) <- dispatchValue ready (pointerRequest (downEvent False "3/2" "0") [])
  (previewed, response) <-
    dispatchValue pressed (pointerRequest (moveEvent False "81/10" "71/10" 13 10) [])
  workspace <- field "workspace" response
  preview <- requiredNonNull "snapped preview" =<< field "preview" workspace
  centre <- field "centre" preview
  assertText "8" "x" centre
  assertText "7" "y" centre
  assertBool False "freeDrag" preview
  guides <- field "guides" preview >>= arrayValues "guides"
  guide <- onlyValue "alignment guide" guides
  assertText "alignment" "kind" guide
  (_, committed) <- dispatchValue previewed (pointerRequest (upEvent False "81/10" "71/10" 13 10) [])
  assertEqual "snapped source" movedEightSevenFixture =<< workspaceBytes committed

altFree :: IO ()
altFree = do
  (ready, _) <- readyFixture
  (pressed, _) <- dispatchValue ready (pointerRequest (downEvent False "3/2" "0") [])
  (_, response) <-
    dispatchValue pressed (pointerRequest (moveEvent True "81/10" "71/10" 13 10) [])
  preview <- requiredNonNull "free preview" =<< (field "workspace" response >>= field "preview")
  assertBool True "freeDrag" preview
  centre <- field "centre" preview
  assertText "81/10" "x" centre
  assertText "71/10" "y" centre
  guides <- field "guides" preview >>= arrayValues "free guides"
  assertEqual "free guide count" 0 (length guides)

realDemoNaturalDrag :: IO ()
realDemoNaturalDrag = do
  fixturePath <- Paths.getDataFileName "test/fixtures/demo.slide"
  fixture <- ByteString.readFile fixturePath
  leftFallback <- runNaturalDrag fixture "source" "11" "7"
    [("21/2", "13/2"), ("49/5", "29/5"), ("47/5", "26/5"), ("9", "5")]
    ("44/5", "5")
  assertEqual "left relative placement uses fallback" True leftFallback
  sourceFallback <- runNaturalDrag fixture "source" "11" "7"
    [("8", "7"), ("53/10", "7"), ("56/5", "34/5"), ("23/2", "13/2"), ("11", "6")]
    ("12", "6")
  assertEqual "source/model spacing uses fallback" True sourceFallback

runNaturalDrag
  :: ByteString
  -> Text
  -> Text
  -> Text
  -> [(Text, Text)]
  -> (Text, Text)
  -> IO Bool
runNaturalDrag fixture node startX startY intermediates (endX, endY) = do
  (opened, openedResponse) <-
    dispatchValue newProductV2State (request "open_source" ["sourceBase16" .= base16Encode fixture])
  paint <- responsePaint openedResponse
  (ready, _) <- dispatchValue opened (request "acknowledge_paint" ["paint" .= paint])
  let openingSurface = object ["frame" .= ("opening" :: Text), "kind" .= ("audience" :: Text)]
      down = object (sampleFields "down" False startX startY 100 100 <> ["target" .= object ["kind" .= ("node" :: Text), "surface" .= openingSurface, "nodeId" .= node]])
  (pressed, _) <- dispatchValue ready (pointerRequest down [])
  (previewed, usedFallback) <- foldNaturalMoves pressed False intermediates
  (_, committed) <- dispatchValue previewed (pointerRequest (upEvent False endX endY 160 140) [])
  assertText "pointer_committed" "kind" committed
  committedWorkspace <- field "workspace" committed
  assertNumber 1 "revision" =<< field "source" committedWorkspace
  assertBool True "canUndo" committedWorkspace
  assertText "idle" "phase" =<< field "pointer" committedWorkspace
  pure usedFallback

realHeadlineDrag :: IO ()
realHeadlineDrag = do
  fixturePath <- Paths.getDataFileName "test/fixtures/demo.slide"
  fixture <- ByteString.readFile fixturePath
  let openingSurface = object ["frame" .= ("opening" :: Text), "kind" .= ("audience" :: Text)]
      headlineDown =
        object
          ( sampleFields "down" False "2" "15/2" 100 100
              <> [ "target"
                    .= object
                      [ "kind" .= ("node" :: Text)
                      , "surface" .= openingSurface
                      , "nodeId" .= ("headline" :: Text)
                      ]
                 ]
          )
      expectedNatural = replaceOnce fixture "(headline) at (1,8)" "(headline) at (3,7)"
      expectedAlt = replaceOnce fixture "(headline) at (1,8)" "(headline) at (3.5,7.5)"
  (opened, openedResponse) <-
    dispatchValue newProductV2State (request "open_source" ["sourceBase16" .= base16Encode fixture])
  paint <- responsePaint openedResponse
  (ready, _) <- dispatchValue opened (request "acknowledge_paint" ["paint" .= paint])
  (pressed, pressedResponse) <- dispatchValue ready (pointerRequest headlineDown [])
  assertText "headline" "selection" =<< field "workspace" pressedResponse
  (previewed, _) <-
    foldNaturalMoves pressed False [("5/2", "29/4"), ("3", "7"), ("7/2", "27/4"), ("4", "13/2")]
  (committedState, committed) <-
    dispatchValue previewed (pointerRequest (upEvent False "4" "13/2" 160 140) [])
  assertText "pointer_committed" "kind" committed
  committedWorkspace <- field "workspace" committed
  assertNumber 1 "revision" =<< field "source" committedWorkspace
  assertBool True "canUndo" committedWorkspace
  assertEqual "headline natural drag changes only at coordinates" expectedNatural =<< sourceBytes committedWorkspace
  (undoneState, undone) <- dispatchValue committedState (request "undo" ["revision" .= (1 :: Int)])
  assertEqual "headline natural drag exact undo" fixture =<< workspaceBytes undone
  undoRevision <- workspaceRevision undone
  undoPaint <- responsePaint undone
  (undoReady, _) <- dispatchValue undoneState (request "acknowledge_paint" ["paint" .= undoPaint])
  (altPressed, _) <- dispatchValue undoReady (pointerRequest headlineDown [])
  (altPreviewed, altResponse) <-
    dispatchValue altPressed (pointerRequest (moveEvent True "9/2" "7" 180 150) [])
  altPreview <- requiredNonNull "headline Alt preview" =<< (field "workspace" altResponse >>= field "preview")
  assertBool True "freeDrag" altPreview
  altGuides <- field "guides" altPreview >>= arrayValues "headline Alt guides"
  assertEqual "headline Alt preview has no guides" 0 (length altGuides)
  (altCommittedState, altCommitted) <-
    dispatchValue altPreviewed (pointerRequest (upEvent True "9/2" "7" 180 150) [])
  altWorkspace <- field "workspace" altCommitted
  assertNumber (undoRevision + 1) "revision" =<< field "source" altWorkspace
  assertEqual "headline Alt drag retains north-west anchor semantics" expectedAlt =<< sourceBytes altWorkspace
  (_, altUndone) <-
    dispatchValue altCommittedState (request "undo" ["revision" .= (undoRevision + 1)])
  assertEqual "headline Alt exact undo" fixture =<< workspaceBytes altUndone

foldNaturalMoves :: ProductV2State -> Bool -> [(Text, Text)] -> IO (ProductV2State, Bool)
foldNaturalMoves state usedFallback values =
  case values of
    [] -> pure (state, usedFallback)
    (x, y) : remaining -> do
      (next, response) <- dispatchValue state (pointerRequest (moveEvent False x y 140 120) [])
      assertText "pointer_updated" "kind" response
      workspace <- field "workspace" response
      assertText "dragging" "phase" =<< field "pointer" workspace
      preview <- requiredNonNull "natural preview" =<< field "preview" workspace
      fallback <- boolField "freeDrag" preview
      guides <- field "guides" preview >>= arrayValues "natural guides"
      if fallback then assertEqual "fallback guide count" 0 (length guides) else pure ()
      foldNaturalMoves next (usedFallback || fallback) remaining

exactUndo :: IO ()
exactUndo = do
  (ready, _) <- readyFixture
  (pressed, _) <- dispatchValue ready (pointerRequest (downEvent False "3/2" "0") [])
  (moved, moveResponse) <- dispatchValue pressed (pointerRequest (upEvent False "4" "5" 13 10) [])
  revision <- workspaceRevision moveResponse
  (_, undone) <- dispatchValue moved (request "undo" ["revision" .= revision])
  assertEqual "undo exact original" noncanonicalFixture =<< workspaceBytes undone
  workspace <- field "workspace" undone
  assertNumber 2 "revision" =<< field "source" workspace
  assertBool True "canRedo" workspace

rejectedPreview :: IO ()
rejectedPreview = do
  (ready, _) <- readyFixture
  (pressed, _) <- dispatchValue ready (pointerRequest (downEvent False "3/2" "0") [])
  (previewed, _) <- dispatchValue pressed (pointerRequest (moveEvent False "4" "5" 13 10) [])
  (rejected, response) <-
    dispatchValue previewed (pointerRequest (moveEvent False "2/7" "7" 14 10) [])
  assertText "pointer_preview_rejected" "kind" response
  workspace <- field "workspace" response
  assertNull "rejected replacement preview" =<< field "preview" workspace
  assertText "idle" "phase" =<< field "pointer" workspace
  assertNumber 0 "revision" =<< field "source" workspace
  (_, delayedRelease) <-
    dispatchValue rejected (pointerRequest (upEvent False "4" "5" 15 10) [])
  delayedWorkspace <- field "workspace" delayedRelease
  assertNumber 0 "revision" =<< field "source" delayedWorkspace
  assertBool False "canUndo" delayedWorkspace
  assertEqual "rejected preview exact source" noncanonicalFixture =<< sourceBytes delayedWorkspace

oneSlideNavigator :: IO ()
oneSlideNavigator = do
  (ready, response) <- readyFixture
  navigator <- field "workspace" response >>= field "navigator"
  assertNumber 0 "activeIndex" navigator
  assertNumber 1 "slideCount" navigator
  previous <- field "previous" navigator
  next <- field "next" navigator
  assertBool False "enabled" previous
  assertBool False "enabled" next
  assertText "only_slide_available" "disabledReason" previous
  (_, commandResponse) <-
    dispatchValue ready (request "view_command" ["viewCommand" .= ("next_slide" :: Text)])
  assertEqual "disabled navigator source" noncanonicalFixture =<< workspaceBytes commandResponse

deckNavigationAndNewSlide :: IO ()
deckNavigationAndNewSlide = do
  (opened, openedResponse) <-
    dispatchValue newProductV2State (request "open_source" ["sourceBase16" .= base16Encode threeSlideFixture])
  initialNavigator <- field "workspace" openedResponse >>= field "navigator"
  assertNumber 3 "slideCount" initialNavigator
  assertText "one" "activeFrame" initialNavigator
  initialItems <- field "items" initialNavigator >>= arrayValues "projected slides"
  assertEqual "all-slide projection count" 3 (length initialItems)
  firstItem <- onlyAt "first projected slide" 0 initialItems
  assertObjectKeys ["frame", "title", "audience", "notes"] firstItem
  firstAudience <- field "audience" firstItem
  assertText "one" "frame" =<< field "surface" firstAudience
  assertNull "fixture has no notes projection" =<< field "notes" firstItem
  (selectedThird, selectedThirdResponse) <-
    dispatchValue opened (request "select_slide" ["frame" .= ("three" :: Text)])
  assertText "slide_selected" "kind" selectedThirdResponse
  selectedNavigator <- field "workspace" selectedThirdResponse >>= field "navigator"
  assertText "three" "activeFrame" selectedNavigator
  assertNumber 0 "revision" =<< (field "workspace" selectedThirdResponse >>= field "source")
  (_, missingSelection) <-
    dispatchValue selectedThird (request "select_slide" ["frame" .= ("missing" :: Text)])
  assertBool False "ok" missingSelection
  assertText "active_slide_missing" "code" =<< field "error" missingSelection
  (second, secondResponse) <- dispatchValue opened (request "view_command" ["viewCommand" .= ("next_slide" :: Text)])
  assertNumber 0 "revision" =<< (field "workspace" secondResponse >>= field "source")
  secondNavigator <- field "workspace" secondResponse >>= field "navigator"
  assertText "two" "activeFrame" secondNavigator
  (created, createdResponse) <- dispatchValue second (request "new_slide" ["revision" .= (0 :: Int)])
  assertText "slide_created" "kind" createdResponse
  assertNumber 1 "revision" =<< (field "workspace" createdResponse >>= field "source")
  createdBytes <- workspaceBytes createdResponse
  createdNavigator <- field "workspace" createdResponse >>= field "navigator"
  assertNumber 4 "slideCount" createdNavigator
  assertText "slide-4" "activeFrame" createdNavigator
  (afterStale, staleResponse) <-
    dispatchValue created (request "new_slide" ["revision" .= (0 :: Int)])
  assertBool False "ok" staleResponse
  assertText "stale_revision" "code" =<< field "error" staleResponse
  (unchanged, unchangedResponse) <-
    dispatchValue afterStale (request "workspace_snapshot" [])
  assertEqual "stale New Slide preserves generated parent" createdBytes =<< workspaceBytes unchangedResponse
  assertNumber 1 "revision" =<< (field "workspace" unchangedResponse >>= field "source")
  unchangedNavigator <- field "workspace" unchangedResponse >>= field "navigator"
  assertNumber 4 "slideCount" unchangedNavigator
  assertText "slide-4" "activeFrame" unchangedNavigator
  (undone, undoResponse) <- dispatchValue unchanged (request "undo" ["revision" .= (1 :: Int)])
  assertEqual "New Slide undo restores exact parent" threeSlideFixture =<< workspaceBytes undoResponse
  undoNavigator <- field "workspace" undoResponse >>= field "navigator"
  assertNumber 3 "slideCount" undoNavigator
  assertText "two" "activeFrame" undoNavigator
  (_, redoResponse) <- dispatchValue undone (request "redo" ["revision" .= (2 :: Int)])
  assertEqual "New Slide redo restores exact generated parent" createdBytes =<< workspaceBytes redoResponse
  assertNumber 3 "revision" =<< (field "workspace" redoResponse >>= field "source")
  redoNavigator <- field "workspace" redoResponse >>= field "navigator"
  assertNumber 4 "slideCount" redoNavigator
  assertText "slide-4" "activeFrame" redoNavigator

threeSlideFixture :: ByteString
threeSlideFixture =
  "deck \"Three\" ()\nslide one \"One\" () \"\"\"\\node (shared) at (1,1) {one};\"\"\"\nslide two \"Two\" () \"\"\"\\node (shared) at (2,2) {two};\"\"\"\nslide three \"Three\" () \"\"\"\"\"\"\n"
readyFixture :: IO (ProductV2State, Value)
readyFixture = do
  (opened, response) <-
    dispatchValue newProductV2State (request "open_source" ["sourceBase16" .= base16Encode noncanonicalFixture])
  paint <- responsePaint response
  dispatchValue opened (request "acknowledge_paint" ["paint" .= paint])

responsePaint :: Value -> IO Value
responsePaint response = do
  workspace <- field "workspace" response
  offer <- requiredNonNull "render offer" =<< field "renderOffer" workspace
  field "fence" offer

pointerRequest :: Value -> [Pair] -> Value
pointerRequest event extra = request "pointer_event" (["event" .= event] <> extra)

downEvent :: Bool -> Text -> Text -> Value
downEvent alt x y =
  object (sampleFields "down" alt x y 10 10 <> ["target" .= object ["kind" .= ("node" :: Text), "surface" .= trialSurface, "nodeId" .= ("alpha" :: Text)]])

trialSurface :: Value
trialSurface = object ["frame" .= ("trial" :: Text), "kind" .= ("audience" :: Text)]

moveEvent :: Bool -> Text -> Text -> Int -> Int -> Value
moveEvent alt x y cssX cssY = object (sampleFields "move" alt x y cssX cssY)

upEvent :: Bool -> Text -> Text -> Int -> Int -> Value
upEvent alt x y cssX cssY = object (sampleFields "up" alt x y cssX cssY)

terminalEvent :: Text -> Value
terminalEvent kind = object ["type" .= kind, "pointerId" .= (7 :: Int)]

sampleFields :: Text -> Bool -> Text -> Text -> Int -> Int -> [Pair]
sampleFields kind alt x y cssX cssY =
  [ "type" .= kind
  , "pointerId" .= (7 :: Int)
  , "pointerType" .= ("mouse" :: Text)
  , "button" .= (0 :: Int)
  , "primary" .= True
  , "cssPoint" .= point (Text.pack (show cssX)) (Text.pack (show cssY))
  , "slidePoint" .= point x y
  , "modifiers"
      .= object
        [ "alt" .= alt
        , "shift" .= False
        , "control" .= False
        , "meta" .= False
        ]
  ]

point :: Text -> Text -> Value
point x y = object ["x" .= x, "y" .= y]

request :: Text -> [Pair] -> Value
request command fields = object (["protocol" .= productProtocolV2, "command" .= command] <> fields)

dispatchValue :: ProductV2State -> Value -> IO (ProductV2State, Value)
dispatchValue state value = do
  let (next, bytes) = dispatchProductV2RequestJSON state (LazyByteString.toStrict (encode value))
  decoded <- decodeValue bytes
  pure (next, decoded)

assertDispatchError :: Text -> ProductV2State -> Value -> IO ()
assertDispatchError code state value = do
  (_, response) <- dispatchValue state value
  assertBool False "ok" response
  failure <- field "error" response
  assertText code "code" failure

workspaceBytes :: Value -> IO ByteString
workspaceBytes response = field "workspace" response >>= sourceBytes

sourceBytes :: Value -> IO ByteString
sourceBytes workspace = do
  source <- field "source" workspace
  encoded <- textField "base16" source
  maybe (failTest "response source base16 is invalid") pure (base16Decode encoded)

workspaceRevision :: Value -> IO Int
workspaceRevision response = field "workspace" response >>= field "source" >>= numberField "revision"

field :: Text -> Value -> IO Value
field name (Object objectValue) =
  maybe (failTest ("missing field: " <> Text.unpack name)) pure (KeyMap.lookup (Key.fromText name) objectValue)
field name _ = failTest ("expected object for field: " <> Text.unpack name)

textField :: Text -> Value -> IO Text
textField name value = do
  present <- field name value
  case present of
    String text -> pure text
    _ -> failTest ("field is not text: " <> Text.unpack name)

numberField :: Text -> Value -> IO Int
numberField name value = do
  present <- field name value
  case Aeson.fromJSON present of
    Aeson.Success number -> pure number
    Aeson.Error _ -> failTest ("field is not an integer: " <> Text.unpack name)

boolField :: Text -> Value -> IO Bool
boolField name value = do
  present <- field name value
  case present of
    Bool actual -> pure actual
    _ -> failTest ("field is not boolean: " <> Text.unpack name)

arrayValues :: String -> Value -> IO [Value]
arrayValues _ (Array values) = pure (toList values)
arrayValues label _ = failTest (label <> " is not an array")

requiredNonNull :: String -> Value -> IO Value
requiredNonNull label Null = failTest (label <> " is null")
requiredNonNull _ value = pure value

onlyAt :: String -> Int -> [Value] -> IO Value
onlyAt label wanted values =
  case drop wanted values of
    value : _ -> pure value
    [] -> failTest (label <> " index missing")

onlyValue :: String -> [Value] -> IO Value
onlyValue _ [value] = pure value
onlyValue label values = failTest (label <> " count: " <> show (length values))

requireMatching :: (Value -> Bool) -> [Value] -> IO Value
requireMatching predicate values =
  case filter predicate values of
    [value] -> pure value
    matches -> failTest ("matching value count: " <> show (length matches))

hasTextField :: Text -> Text -> Value -> Bool
hasTextField key expected (Object objectValue) =
  KeyMap.lookup (Key.fromText key) objectValue == Just (String expected)
hasTextField _ _ _ = False

assertObjectKeys :: [Text] -> Value -> IO ()
assertObjectKeys expected (Object objectValue) = do
  let actual = fmap Key.toText (KeyMap.keys objectValue)
  unless
    (length actual == length expected && all (`elem` expected) actual)
    (failTest ("unexpected object keys: " <> show actual))
assertObjectKeys _ _ = failTest "expected object while checking exact keys"

assertText :: Text -> Text -> Value -> IO ()
assertText expected name value = textField name value >>= assertEqual (Text.unpack name) expected

assertNumber :: Int -> Text -> Value -> IO ()
assertNumber expected name value = numberField name value >>= assertEqual (Text.unpack name) expected

assertBool :: Bool -> Text -> Value -> IO ()
assertBool expected name value = do
  present <- field name value
  case present of
    Bool actual -> assertEqual (Text.unpack name) expected actual
    _ -> failTest ("field is not boolean: " <> Text.unpack name)

assertNull :: String -> Value -> IO ()
assertNull _ Null = pure ()
assertNull label _ = failTest (label <> " is not null")

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  unless (expected == actual) (failTest (label <> ": expected " <> show expected <> ", got " <> show actual))

decodeValue :: ByteString -> IO Value
decodeValue bytes =
  case eitherDecodeStrict' bytes of
    Left problem -> failTest ("invalid response JSON: " <> problem)
    Right value -> pure value

failTest :: String -> IO value
failTest message = putStrLn ("FAIL: " <> message) >> exitFailure

base16Encode :: ByteString -> Text
base16Encode = Text.pack . foldMap encodeByte . ByteString.unpack
  where
    encodeByte byte = [hexDigit (byte `div` 16), hexDigit (byte `mod` 16)]

base16Decode :: Text -> Maybe ByteString
base16Decode value = ByteString.pack <$> pairs (Text.unpack value)
  where
    pairs [] = Just []
    pairs (high : low : rest) = do
      highValue <- hexValue high
      lowValue <- hexValue low
      remaining <- pairs rest
      Just (highValue * 16 + lowValue : remaining)
    pairs [_] = Nothing

hexValue :: Char -> Maybe Word8
hexValue character
  | character >= '0' && character <= '9' = Just (fromIntegral (ord character - ord '0'))
  | character >= 'a' && character <= 'f' = Just (fromIntegral (10 + ord character - ord 'a'))
  | otherwise = Nothing

hexDigit :: Word8 -> Char
hexDigit value = "0123456789abcdef" !! fromIntegral value

noncanonicalFixture :: ByteString
noncanonicalFixture =
  trialDeck
    ( TextEncoding.encodeUtf8
        "% lead\r\n\\node % command\r\n (alpha)\t at ( +001.5000 % x\r\n ,\t -000.00 ) {héllo}; % between\r\n\\draw\t(alpha) -- (9.0 , 8);\r\n"
    )

movedFourFiveFixture :: ByteString
movedFourFiveFixture =
  trialDeck
    ( TextEncoding.encodeUtf8
        "% lead\r\n\\node % command\r\n (alpha)\t at ( 4 % x\r\n ,\t 5 ) {héllo}; % between\r\n\\draw\t(alpha) -- (9.0 , 8);\r\n"
    )

movedEightSevenFixture :: ByteString
movedEightSevenFixture =
  trialDeck
    ( TextEncoding.encodeUtf8
        "% lead\r\n\\node % command\r\n (alpha)\t at ( 8 % x\r\n ,\t 7 ) {héllo}; % between\r\n\\draw\t(alpha) -- (9.0 , 8);\r\n"
    )

trialDeck :: ByteString -> ByteString
trialDeck body = "deck ()\r\nslide trial \"Trial\" () \"\"\"" <> body <> "\"\"\"\r\n"

malformedFixture :: ByteString
malformedFixture = "\\node (alpha) at (1,2) {hello}\n\\draw (alpha) -- (9,8);\n"

replaceOnce :: ByteString -> ByteString -> ByteString -> ByteString
replaceOnce source needle replacement =
  let (prefix, remainder) = ByteString.breakSubstring needle source
      suffix = ByteString.drop (ByteString.length needle) remainder
   in if ByteString.null remainder || needle `ByteString.isInfixOf` suffix
        then source
        else prefix <> replacement <> suffix
