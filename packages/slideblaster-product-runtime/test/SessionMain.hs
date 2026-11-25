{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Laws of the session/1 state machine over a stand-in analyzer.
module Main (main) where

import SlideBlaster.Product.Runtime.Session
import SlideBlaster.Protocol.Session
import SlideBlaster.Product.Runtime.MarkdownAnalyzer (markdownAnalyzer)
import TestAnalyzer

import Control.Monad (unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import System.Exit (exitFailure)

main :: IO ()
main = do
  run "open_project projects frames, figure request and measure batch" openLaw
  run "wrong fingerprint or ticket is ignored, right one substitutes the figure" providerLaw
  run "provider failure becomes a diagnostic and a placeholder" failureLaw
  run "missing figure source is a diagnostic without a provider request" missingLaw
  run "apply_source_replace is exact, fenced and local; undo restores bytes" editLaw
  run "new_slide inserts after active and is undoable" newSlideLaw
  run "save emits exact bytes and storage_result advances saved" saveLaw
  run "stale measurement ticket rejects; overflow becomes a diagnostic" measureLaw
  run "presenter walks steps then slides" presenterLaw
  run "project_file change re-requests the figure" projectFileLaw
  run "a library shape is asked for, then drawn as its outline" shapeLaw
  run "several elements are moved, copied, reordered, removed and turned" arrangeLaw
  run "lines go at right angles or bent, carry labels and take points" routeLaw
  run "a TikZ figure is drawn by the core and edited through its text" figureLaw
  run "images are named in plans and fetched once when the page asks for that" imageRefLaw
  run "codec is exact-key and rejects Product/2" codecLaw
  run "a deck in a subfolder is laid out with the theme next to it" deckThemeLaw
  run "a deck in a subfolder finds its images next to it, as sb build does" deckImageLaw

run :: String -> IO () -> IO ()
run name check = check >> putStrLn ("PASS: " <> name)

failWith :: String -> IO a
failWith message = putStrLn ("FAIL: " <> message) >> exitFailure

expect :: (Eq a, Show a) => String -> a -> a -> IO ()
expect label expected actual =
  unless (expected == actual) $
    failWith (label <> "\n  expected: " <> show expected <> "\n  actual:   " <> show actual)

-- Driving helpers -----------------------------------------------------------

req :: Text -> [(Key.Key, Value)] -> ByteString
req command fields = encodeValue (object (["protocol" .= sessionProtocol, "command" .= command] <> fmap (uncurry (.=)) fields))

send :: Session -> ByteString -> IO (Session, Text, [Value])
send session bytes =
  case decodeSessionRequest bytes of
    Left problem -> failWith ("decode: " <> show problem)
    Right request -> case runSession session request of
      Left problem -> failWith ("run: " <> show problem)
      Right result -> pure result

sendErr :: Session -> ByteString -> IO SessionError
sendErr session bytes =
  case decodeSessionRequest bytes >>= runSession session of
    Left problem -> pure problem
    Right _ -> failWith "expected an error"

field :: Text -> Value -> Value
field k (Object o) = fromMaybe Null (KeyMap.lookup (Key.fromText k) o)
field _ _ = Null

path :: [Text] -> Value -> Value
path = flip (foldl (flip field))

arr :: Value -> [Value]
arr (Array a) = toList a
arr _ = []

str :: Value -> Text
str (String t) = t
str _ = ""

num :: Value -> Int
num (Number n) = round n
num _ = -1

effectsOfKind :: Text -> [Value] -> [Value]
effectsOfKind kind = filter ((== String kind) . field "kind")

files1 :: [(Text, ByteString)]
files1 = [("talk.slideBlaster.md", deck1), ("figures/a.tikz", "\\draw plot coordinates {(0,0) (1,1)};")]

open1 :: IO (Session, [Value])
open1 = do
  (s, _, effects) <- send (newSession analyzer) (req "open_project" ["entry" .= ("talk.slideBlaster.md" :: Text), "files" .= [object ["path" .= p, "bytesBase16" .= encodeBase16 b] | (p, b) <- files1]])
  pure (s, effects)

view :: Session -> Value
view = viewValue

-- Laws ----------------------------------------------------------------------

openLaw :: IO ()
openLaw = do
  (s, effects) <- open1
  expect "frames" ["one", "two"] (fmap (str . field "frame") (arr (path ["navigator", "items"] (view s))))
  expect "steps" [2, 1] (fmap (num . field "steps") (arr (path ["navigator", "items"] (view s))))
  case effectsOfKind "block.render" effects of
    [e] -> do
      expect "fingerprint is 64 hex" 64 (Text.length (str (field "fingerprint" e)))
      expect "relays /cap shape" (String "tikz") (path ["request", "kind"] e)
      expect "body is the file" (String "\\draw plot coordinates {(0,0) (1,1)};") (path ["request", "input", "body"] e)
      expect "inputs carry base64" (String "XGRyYXcgcGxvdCBjb29yZGluYXRlcyB7KDAsMCkgKDEsMSl9Ow==") (path ["request", "input", "inputs"] e `seq` field "contentBase64" (head' (arr (path ["request", "input", "inputs"] e))))
    other -> failWith ("expected one block.render, got " <> show (length other))
  expect "one measure batch" 1 (length (effectsOfKind "measure" effects))
  expect "active is first" (String "one") (path ["navigator", "activeFrame"] (view s))
  expect "figure is a pending placeholder" (String "pending") (firstPlaceholderState (view s) "two")
  where
    head' (x : _) = x
    head' [] = Null

firstPlaceholderState :: Value -> Text -> Value
firstPlaceholderState v frame =
  case [item | item <- arr (path ["navigator", "items"] v), str (field "frame" item) == frame] of
    (item : _) -> collect (path ["audience", "items"] item)
    [] -> Null
  where
    collect items = case concatMap (placeholders . field "content") (arr items) of
      (p : _) -> field "state" p
      [] -> Null
    placeholders (Array a) = concatMap placeholders (toList a)
    placeholders o@(Object _)
      | field "t" o == String "placeholder" = [o]
      | otherwise = placeholders (field "children" o)
    placeholders _ = []

figureEffect :: [Value] -> IO Value
figureEffect effects = case effectsOfKind "block.render" effects of
  (e : _) -> pure e
  [] -> failWith "no block.render"

providerLaw :: IO ()
providerLaw = do
  (s, effects) <- open1
  e <- figureEffect effects
  let ticket = num (field "ticket" e)
      fp = str (field "fingerprint" e)
      artifact = object ["mime" .= ("image/svg+xml" :: Text), "bytesBase16" .= encodeBase16 "<svg/>", "width" .= (100 :: Int), "height" .= (50 :: Int), "provenance" .= ("t" :: Text)]
      result t f = req "provider_result" ["ticket" .= t, "fingerprint" .= (f :: Text), "artifact" .= artifact]
  (_, kind1, _) <- send s (result (ticket + 99) fp)
  expect "unknown ticket ignored" "provider_result_ignored" kind1
  (_, kind2, _) <- send s (result ticket "00")
  expect "wrong fingerprint ignored" "provider_result_ignored" kind2
  (s3, kind3, _) <- send s (result ticket fp)
  expect "accepted" "provider_result_accepted" kind3
  expect "figure replaces placeholder" Null (firstPlaceholderState (view s3) "two")
  let twoPlan = head' [path ["audience"] item | item <- arr (path ["navigator", "items"] (view s3)), str (field "frame" item) == "two"]
  expect "artifact travels in the plan" (String "image/svg+xml") (path ["artifacts", fp, "mime"] twoPlan)
  (_, kind4, _) <- send s3 (result ticket fp)
  expect "replay ignored" "provider_result_ignored" kind4
  where
    head' (x : _) = x
    head' [] = Null

failureLaw :: IO ()
failureLaw = do
  (s, effects) <- open1
  e <- figureEffect effects
  (s', _, _) <- send s (req "provider_result" ["ticket" .= num (field "ticket" e), "fingerprint" .= str (field "fingerprint" e), "diagnostics" .= [object ["severity" .= ("error" :: Text), "code" .= ("provider_error" :: Text), "message" .= ("! Undefined control sequence." :: Text), "line" .= Aeson.Null, "absent" .= False]]])
  expect "error placeholder" (String "error") (firstPlaceholderState (view s') "two")
  expect "diagnostic projected" [String "provider_error"] (fmap (field "code") (filter ((== String "two") . field "frame") (arr (field "diagnostics" (view s')))))

missingLaw :: IO ()
missingLaw = do
  (s, _, effects) <- send (newSession analyzer) (req "open_project" ["entry" .= ("t.md" :: Text), "files" .= [object ["path" .= ("t.md" :: Text), "bytesBase16" .= encodeBase16 deck1]]])
  expect "no provider request" [] (effectsOfKind "block.render" effects)
  expect "missing asset diagnostic" [String "missing_asset"] (fmap (field "code") (filter ((== String "two") . field "frame") (arr (field "diagnostics" (view s)))))

editLaw :: IO ()
editLaw = do
  (s, _) <- open1
  let rev = 1 :: Int
      start = ByteString.length "## One {#one}\n"
      replace r s0 e0 expected rep = req "apply_source_replace" ["revision" .= r, "start" .= s0, "end" .= e0, "expectedBase16" .= encodeBase16 expected, "replacementBase16" .= encodeBase16 rep]
  stale <- sendErr s (replace (rev + 5) start (start + 5) "alpha" "ALPHA")
  expect "stale rejected" (SessionStale 6 1) stale
  _ <- sendErr s (replace rev start (start + 5) "wrong" "ALPHA")
  (s2, _, _) <- send s (replace rev start (start + 5) "alpha" "ALPHA")
  let expected = ByteString.concat [ByteString.take start deck1, "ALPHA", ByteString.drop (start + 5) deck1]
  expect "exact bytes" (Just expected) (sessionDeckBytes s2)
  expect "revision bumps" (Just 2) (sessionRevision s2)
  (s3, _, _) <- send s2 (req "command" ["name" .= ("undo" :: Text), "revision" .= (2 :: Int)])
  expect "undo restores exact bytes" (Just deck1) (sessionDeckBytes s3)
  expect "undo is a new revision" (Just 3) (sessionRevision s3)
  (s4, _, _) <- send s3 (req "command" ["name" .= ("redo" :: Text), "revision" .= (3 :: Int)])
  expect "redo reapplies" (Just expected) (sessionDeckBytes s4)

newSlideLaw :: IO ()
newSlideLaw = do
  (s, _) <- open1
  (s2, kind, _) <- send s (req "command" ["name" .= ("new_slide" :: Text), "revision" .= (1 :: Int)])
  expect "kind" "slide_created" kind
  expect "frames" ["one", "slide-3", "two"] (fmap (str . field "frame") (arr (path ["navigator", "items"] (view s2))))
  expect "new slide is active" (String "slide-3") (path ["navigator", "activeFrame"] (view s2))
  (s3, _, _) <- send s2 (req "command" ["name" .= ("undo" :: Text), "revision" .= (2 :: Int)])
  expect "undo removes it" (Just deck1) (sessionDeckBytes s3)

saveLaw :: IO ()
saveLaw = do
  (s, _) <- open1
  (_, _, effects) <- send s (req "command" ["name" .= ("save" :: Text)])
  case effectsOfKind "storage" effects of
    [e] -> expect "exact bytes" (String (encodeBase16 deck1)) (field "bytesBase16" e)
    _ -> failWith "expected one storage effect"
  (s2, _, _) <- send s (req "apply_source_replace" ["revision" .= (1 :: Int), "start" .= (0 :: Int), "end" .= (0 :: Int), "expectedBase16" .= ("" :: Text), "replacementBase16" .= encodeBase16 "x"])
  expect "dirty after edit" (Number 1) (field "saved" (view s2))
  (s3, _, _) <- send s2 (req "storage_result" ["path" .= ("talk.slideBlaster.md" :: Text), "revision" .= (2 :: Int), "ok" .= True])
  expect "saved advances" (Number 2) (field "saved" (view s3))

measureLaw :: IO ()
measureLaw = do
  (s, effects) <- open1
  m <- case effectsOfKind "measure" effects of
    (e : _) -> pure e
    [] -> failWith "no measure"
  let ticket = num (field "ticket" m)
      results t h = req "measurement_result" ["ticket" .= (t :: Int), "results" .= [object ["key" .= k, "width" .= (1000 :: Int), "height" .= (h :: Int)] | k <- ["one", "two" :: Text]]]
  e1 <- sendErr s (results (ticket + 1) 10)
  expect "stale ticket" SessionStaleTicket e1
  (s2, _, _) <- send s (results ticket 9999)
  expect "overflow diagnostics" [String "one", String "two"] (fmap (field "frame") (filter ((== String "overflow") . field "code") (arr (field "diagnostics" (view s2)))))
  e2 <- sendErr s2 (results ticket 10)
  expect "ticket is single use" SessionStaleTicket e2

deckThemeLaw :: IO ()
deckThemeLaw = do
  let theme colour = Char8.pack ("{\"palette\":{\"background\":\"" <> colour <> "\"}}")
      files :: [(Text, ByteString)]
      files =
        [ ("sub/talk.slideBlaster.md", deck1)
        , ("sub/themes/default/theme.json", theme "#123456")
        , ("themes/default/theme.json", theme "#654321")
        ]
  (s, _, _) <- send (newSession analyzer) (req "open_project" ["entry" .= ("sub/talk.slideBlaster.md" :: Text), "files" .= [object ["path" .= p, "bytesBase16" .= encodeBase16 b] | (p, b) <- files]])
  let shown = Aeson.encode (view s)
      has colour = Char8.pack colour `ByteString.isInfixOf` ByteString.toStrict shown
  expect "the deck's own theme" (True, False) (has "#123456", has "#654321")

deckImageLaw :: IO ()
deckImageLaw = do
  let svg = Char8.pack "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"/>"
      deck = Char8.pack "---\nslideblaster: 1\ntitle: T\n---\n\n## One {#one}\n\n\\figure{figures/a.svg}\n\n## Two {#two}\n\n\\figure{../shared/b.svg}\n"
      files :: [(Text, ByteString)]
      files = [("sub/talk.slideBlaster.md", deck), ("sub/figures/a.svg", svg), ("shared/b.svg", svg)]
  (s, _, _) <- send (newSession analyzer) (req "open_project" ["entry" .= ("sub/talk.slideBlaster.md" :: Text), "files" .= [object ["path" .= p, "bytesBase16" .= encodeBase16 b] | (p, b) <- files]])
  expect "no missing image" [] (fmap (field "message") (filter ((== String "missing_asset") . field "code") (arr (field "diagnostics" (view s)))))

presenterLaw :: IO ()
presenterLaw = do
  (s, _) <- open1
  (s1, _, e1) <- send s (req "present_open" [])
  expect "present effect" 1 (length (effectsOfKind "present" e1))
  let stepNext st = send st (req "present_step" ["direction" .= ("next" :: Text)])
      pos st = (str (path ["presenter", "frame"] (view st)), num (path ["presenter", "step"] (view st)))
  expect "start" ("one", 1) (pos s1)
  (s2, _, _) <- stepNext s1
  expect "step within slide" ("one", 2) (pos s2)
  (s3, _, _) <- stepNext s2
  expect "next slide" ("two", 1) (pos s3)
  (s4, _, _) <- stepNext s3
  expect "end clamps" ("two", 1) (pos s4)
  (s5, _, _) <- send s4 (req "present_step" ["direction" .= ("previous" :: Text)])
  expect "back to last step" ("one", 2) (pos s5)
  (s6, _, _) <- send s5 (req "present_close" [])
  expect "closed" Null (field "presenter" (view s6))

projectFileLaw :: IO ()
projectFileLaw = do
  (s, effects) <- open1
  e <- figureEffect effects
  (s2, _, effects2) <- send s (req "project_file" ["path" .= ("figures/a.tikz" :: Text), "bytesBase16" .= encodeBase16 "\\draw plot coordinates {(0,0) (2,2)};"])
  e2 <- figureEffect effects2
  expect "new fingerprint" False (field "fingerprint" e == field "fingerprint" e2)
  (_, _, effects3) <- send s2 (req "project_file" ["path" .= ("figures/a.tikz" :: Text), "bytesBase16" .= encodeBase16 "\\draw plot coordinates {(0,0) (2,2)};"])
  expect "same bytes, same fingerprint: no new request" [] (effectsOfKind "block.render" effects3)

-- A node names a library style: the view says which library file is missing;
-- once the host supplies it the node is drawn as the style's outline.
shapeLaw :: IO ()
shapeLaw = do
  let deck = "---\nslideblaster: 1\n---\n\n## One {#one}\n\n```slide\n\\node[flow.decision, fill=yellow] (a) at (4,4) {A};\n```\n" :: ByteString
      library = "\\tikzset{flow.decision/.style={outline={M 0.5 0 L 1 0.5 L 0.5 1 L 0 0.5 Z}, minimum width=2.4, minimum height=2}}\n" :: ByteString
      kinds session = [(field "kind" item, field "d" item) | item <- planItems session, field "id" item == String "pic-bg-a"]
      planItems session = case path ["navigator", "items"] (viewValue session) of
        Array frames -> concat [case path ["audience", "items"] f of Array items -> toList items; _ -> [] | f <- toList frames, field "frame" f == String "one"]
        _ -> []
  (s, _, _) <- send (newSession markdownAnalyzer) (req "open_project" ["entry" .= ("deck.slideBlaster.md" :: Text), "files" .= [object ["path" .= ("deck.slideBlaster.md" :: Text), "bytesBase16" .= encodeBase16 deck]]])
  expect "the missing library file is named" (Aeson.toJSON ["shapes/flow.tikz" :: Text]) (field "needs" (viewValue s))
  expect "without its definition the node is a plain filled box" [(String "rect", Null)] (kinds s)
  (s2, _, _) <- send s (req "project_file" ["path" .= ("shapes/flow.tikz" :: Text), "bytesBase16" .= encodeBase16 library])
  expect "nothing is missing any more" (Aeson.toJSON ([] :: [Text])) (field "needs" (viewValue s2))
  expect "the node is drawn as the outline" [(String "path", String "M 0.5 0 L 1 0.5 L 0.5 1 L 0 0.5 Z")] (kinds s2)
  expect "library files are not offered as picture files" (Aeson.toJSON ([] :: [Text])) (field "pictureFiles" (viewValue s2))

arrangeLaw :: IO ()
arrangeLaw = do
  let deck = "---\nslideblaster: 1\n---\n\n## One {#one}\n\n```slide\n\\node[draw] (a) at (2,3) {A};\n\\node[draw, rotate=30] (b) at (5,3) {B};\n\\node[outline={M 0 0 L 1 0.5 L 0 1 Z}, xscale=-1, rotate=90] (c) at (8,3) {};\n\\draw[->] (a) -- (b);\n```\n" :: ByteString
      edit session op = send session (req "picture_edit" ["revision" .= field "revision" (viewValue session), "frame" .= ("one" :: Text), "op" .= object op])
      refuse session op = sendErr session (req "picture_edit" ["revision" .= field "revision" (viewValue session), "frame" .= ("one" :: Text), "op" .= object op])
      body session = Text.strip (Text.takeWhile (/= '`') (snd (Text.breakOnEnd "```slide\n" (Text.decodeUtf8 (fromMaybe "" (decodeBase16 (str (path ["source", "sourceBase16"] (viewValue session)))))))))
      made effects = [str (field "node" e) | e <- effectsOfKind "node_created" effects]
      items session = case path ["navigator", "items"] (viewValue session) of
        Array frames -> concat [arr (path ["audience", "items"] f) | f <- toList frames, field "frame" f == String "one"]
        _ -> []
      item session name = case [i | i <- items session, field "id" i == String name] of i : _ -> i; [] -> Null
      move node x y = object ["kind" .= ("move_node" :: Text), "node" .= (node :: Text), "x" .= (x :: Double), "y" .= (y :: Double)]
  (s, _, _) <- send (newSession markdownAnalyzer) (req "open_project" ["entry" .= ("deck.slideBlaster.md" :: Text), "files" .= [object ["path" .= ("deck.slideBlaster.md" :: Text), "bytesBase16" .= encodeBase16 deck]]])
  expect "a turned box and its text carry the turn" (Aeson.toJSON (30 :: Int), Aeson.toJSON (30 :: Int)) (field "rotate" (item s "pic-bg-b"), field "rotate" (item s "pic-b"))
  expect "an outline carries its turn and its flip" (Aeson.toJSON (90 :: Int), object ["x" .= True, "y" .= False]) (field "rotate" (item s "pic-bg-c"), field "flip" (item s "pic-bg-c"))
  expect "an unturned box carries neither" (Null, Null) (field "rotate" (item s "pic-bg-a"), field "flip" (item s "pic-bg-a"))
  -- several moves are one edit and one revision
  (s1, _, _) <- edit s ["kind" .= ("batch" :: Text), "ops" .= [move "a" 160 240, move "b" 400 240]]
  expect "one revision for the batch" (num (field "revision" (viewValue s)) + 1) (num (field "revision" (viewValue s1)))
  expect "both nodes moved" True (all (`Text.isInfixOf` body s1) ["(a) at (2,", "(b) at (5,"] && body s1 /= body s)
  problem <- refuse s1 ["kind" .= ("batch" :: Text), "ops" .= [move "a" 160 240, move "nosuch" 0 0]]
  expect "a batch with a step that cannot be done changes nothing" True (case problem of SessionEditRejected _ -> True; _ -> False)
  expect "nested batches are refused by the codec" True (either (const True) (const False) (decodeSessionRequest (req "picture_edit" ["revision" .= (1 :: Int), "frame" .= ("one" :: Text), "op" .= object ["kind" .= ("batch" :: Text), "ops" .= [object ["kind" .= ("batch" :: Text), "ops" .= [move "a" 0 0]]]]])))
  -- a copy of two joined nodes brings the line between them along, under new names
  (s2, _, effects2) <- edit s1 ["kind" .= ("paste" :: Text), "text" .= ("\\node[draw] (a) at (2,3) {A};\n\\node[draw, rotate=30] (b) at (5,3) {B};\n\\draw[->] (a) -- (b);" :: Text), "x" .= (80 :: Double), "y" .= (80 :: Double)]
  expect "the paste names the two nodes it made" 2 (length (made effects2))
  expect "the copies are written after what was there" True (all (\n -> ("(" <> n <> ")") `Text.isInfixOf` body s2) (made effects2) && ("\\draw[->] (" <> Text.intercalate ") -- (" (made effects2) <> ");") `Text.isInfixOf` body s2)
  -- order: a node sent to the back is written first
  (s3, _, _) <- edit s2 ["kind" .= ("reorder" :: Text), "node" .= ("c" :: Text), "to" .= ("back" :: Text)]
  expect "the node sent back is the first statement" True ("\\node[outline=" `Text.isPrefixOf` body s3)
  expect "an unknown place is refused by the codec" True (either (const True) (const False) (decodeSessionRequest (req "picture_edit" ["revision" .= (1 :: Int), "frame" .= ("one" :: Text), "op" .= object ["kind" .= ("reorder" :: Text), "node" .= ("c" :: Text), "to" .= ("sideways" :: Text)]])))
  -- several removed at once; the line between two removed nodes goes with them
  (s4, _, _) <- edit s3 ["kind" .= ("delete_many" :: Text), "items" .= (["a", "b"] :: [Text])]
  expect "both nodes and their line are gone, the copies stay" (False, False, True) ("(a) at" `Text.isInfixOf` body s4, "(a) -- (b)" `Text.isInfixOf` body s4, all (\n -> ("(" <> n <> ")") `Text.isInfixOf` body s4) (made effects2))

routeLaw :: IO ()
routeLaw = do
  let deck = "---\nslideblaster: 1\n---\n\n## One {#one}\n\n```slide\n\\node[draw] (a) at (2,6) {A};\n\\node[draw] (b) at (8,3) {B};\n\\draw[->] (a) -| node[auto] {down} (b);\n```\n" :: ByteString
      edit session op = send session (req "picture_edit" ["revision" .= field "revision" (viewValue session), "frame" .= ("one" :: Text), "op" .= object op])
      written session = Text.decodeUtf8 (fromMaybe "" (decodeBase16 (str (path ["source", "sourceBase16"] (viewValue session)))))
      block session = Text.takeWhile (/= '`') (snd (Text.breakOnEnd "```slide\n" (written session)))
      lastLine session = Text.strip (last (Text.lines (block session)))
      frame session = case path ["navigator", "items"] (viewValue session) of
        Array frames -> case [f | f <- toList frames, field "frame" f == String "one"] of f : _ -> path ["audience"] f; [] -> Null
        _ -> Null
      item session name = case [i | i <- arr (field "items" (frame session)), field "id" i == String name] of i : _ -> i; [] -> Null
      line session = case arr (path ["picture", "lines"] (frame session)) of l : _ -> l; [] -> Null
  (s, _, _) <- send (newSession markdownAnalyzer) (req "open_project" ["entry" .= ("deck.slideBlaster.md" :: Text), "files" .= [object ["path" .= ("deck.slideBlaster.md" :: Text), "bytesBase16" .= encodeBase16 deck]]])
  expect "a right-angled step is one trail through its corner" (String "trail", True, String "end") (field "kind" (item s "pic-line-1-1"), "M " `Text.isPrefixOf` str (field "d" (item s "pic-line-1-1")) && length (Text.splitOn " L " (str (field "d" (item s "pic-line-1-1")))) == 3, field "arrow" (item s "pic-line-1-1"))
  expect "its label is painted as text of its own" (String "flow") (field "kind" (item s "pic-label-3-1"))
  expect "the canvas is told how the line goes and what it carries" (Aeson.toJSON ["hv" :: Text], [String "down"]) (field "joins" (line s), fmap (field "source") (arr (field "labels" (line s))))
  (s1, _, _) <- edit s ["kind" .= ("route" :: Text), "line" .= ("line-3" :: Text), "to" .= ("bend left" :: Text), "bend" .= (40 :: Int)]
  expect "bent: the source says so" "\\draw[->] (a) to[bend left=40] node[auto] {down} (b);" (lastLine s1)
  expect "bent: a trail with a curve" True (" C " `Text.isInfixOf` str (field "d" (item s1 "pic-line-1-1")))
  (s2, _, _) <- edit s1 ["kind" .= ("route" :: Text), "line" .= ("line-3" :: Text), "to" .= ("straight" :: Text), "bend" .= Null]
  expect "straight again: a plain line item" (String "line") (field "kind" (item s2 "pic-line-1-1"))
  (s3, _, _) <- edit s2 ["kind" .= ("label" :: Text), "line" .= ("line-3" :: Text), "index" .= (1 :: Int), "text" .= ("" :: Text)]
  expect "an emptied label is gone" ("\\draw[->] (a) -- (b);", Null) (lastLine s3, item s3 "pic-label-3-1")
  (s4, _, _) <- edit s3 ["kind" .= ("add_point" :: Text), "line" .= ("line-3" :: Text), "step" .= (1 :: Int), "x" .= (640 :: Int), "y" .= (160 :: Int)]
  expect "a point is written in slide units" "\\draw[->] (a) -- (8,7) -- (b);" (lastLine s4)
  expect "the canvas gets the point back in plan pixels" (Aeson.toJSON [Null, object ["x" .= (640 :: Int), "y" .= (160 :: Int)], Null]) (field "points" (line s4))
  expect "a route nobody knows is refused by the codec" True (either (const True) (const False) (decodeSessionRequest (req "picture_edit" ["revision" .= (1 :: Int), "frame" .= ("one" :: Text), "op" .= object ["kind" .= ("route" :: Text), "line" .= ("line-3" :: Text), "to" .= ("zigzag" :: Text), "bend" .= Null]])))

figureLaw :: IO ()
figureLaw = do
  let deck = "---\nslideblaster: 1\n---\n\n## One {#one}\n\n```tikz\n\\node[draw, fill=blue!10] (a) at (0,0) {one};\n\\node[draw, circle] (b) at (3,1) {two};\n\\draw[->] (a) to[bend left] (b);\n```\n\n## Two {#two}\n\n\\figure{figures/f.tikz}\n\n## Three {#three}\n\n```tikz\n\\node[shape=nobody knows] (a) at (0,0) {one};\n```\n" :: ByteString
      file = "\\begin{tikzpicture}[scale=2]\n  \\node[draw] (x) at (1,1) {X};\n\\end{tikzpicture}\n" :: ByteString
      written session = Text.decodeUtf8 (fromMaybe "" (decodeBase16 (str (path ["source", "sourceBase16"] (viewValue session)))))
      drawings value = case value of
        Object o | KeyMap.lookup "t" o == Just (String "drawing") -> [value]
        Object o -> concatMap drawings (KeyMap.elems o)
        Array items -> concatMap drawings (toList items)
        _ -> []
      frame name session = case path ["navigator", "items"] (viewValue session) of
        Array frames -> case [f | f <- toList frames, field "frame" f == String name] of f : _ -> path ["audience"] f; [] -> Null
        _ -> Null
      drawingOf name session = case drawings (frame name session) of d : _ -> d; [] -> Null
      nodesOf d = [i | i <- arr (field "items" d), field "k" i == String "node"]
      edit session figure op = send session (req "figure_edit" ["revision" .= field "revision" (viewValue session), "figure" .= figure, "op" .= object op])
  (s, _, effects) <- send (newSession markdownAnalyzer) (req "open_project" ["entry" .= ("deck.slideBlaster.md" :: Text), "files" .= [object ["path" .= ("deck.slideBlaster.md" :: Text), "bytesBase16" .= encodeBase16 deck], object ["path" .= ("figures/f.tikz" :: Text), "bytesBase16" .= encodeBase16 file]]])
  let one = drawingOf "one" s
      two = drawingOf "two" s
  expect "a figure the evaluator carries out is a drawing: two nodes, their outlines and the line" (2, 5) (length (nodesOf one), length (arr (field "items" one)))
  expect "a figure with something it does not carry out is left to TeX" (Null, 1) (drawingOf "three" s, length (effectsOfKind "block.render" effects))
  expect "the texts of its nodes are sent to be measured" True (any (\e -> any (\i -> "node:tz:" `Text.isPrefixOf` str (field "key" i)) (arr (field "items" e))) (effectsOfKind "measure" effects))
  let at d source = case [field "at" n | n <- nodesOf d, field "source" n == String source] of v : _ -> v; [] -> Null
  (s1, _, _) <- edit s (field "ref" one) ["kind" .= ("move" :: Text), "at" .= at one "one", "dx" .= (1 :: Int), "dy" .= (0.5 :: Double)]
  expect "a move rewrites the node's coordinate in the deck" True ("\\node[draw, fill=blue!10] (a) at (1,0.5) {one};" `Text.isInfixOf` written s1)
  (s2, _, _) <- edit s1 (field "ref" (drawingOf "one" s1)) ["kind" .= ("option" :: Text), "at" .= at (drawingOf "one" s1) "two", "key" .= ("fill" :: Text), "value" .= ("red!15" :: Text)]
  expect "an option is written into the node" True ("\\node[draw, circle, fill=red!15] (b) at (3,1) {two};" `Text.isInfixOf` written s2)
  (s3, _, fileEffects) <- edit s2 (field "ref" two) ["kind" .= ("move" :: Text), "at" .= at two "X", "dx" .= (1 :: Int), "dy" .= (0 :: Int)]
  expect "a figure in its own file: the file is written, with the scaled coordinate" [String (encodeBase16 "\\begin{tikzpicture}[scale=2]\n  \\node[draw] (x) at (1.5,1) {X};\n\\end{tikzpicture}\n")] (fmap (field "bytesBase16") (effectsOfKind "file.write" fileEffects))
  expect "and the deck's own text stays as it was" (written s2) (written s3)
  (s3u, _, undoEffects) <- send s3 (req "command" ["name" .= ("undo" :: Text), "revision" .= field "revision" (viewValue s3)])
  expect "undo puts the figure file back, and it is written" ([String (encodeBase16 file)], 1) (fmap (field "bytesBase16") (effectsOfKind "file.write" undoEffects), length (nodesOf (drawingOf "two" s3u)))
  (_, _, redoEffects) <- send s3u (req "command" ["name" .= ("redo" :: Text), "revision" .= field "revision" (viewValue s3u)])
  expect "redo writes the edit again" 1 (length (effectsOfKind "file.write" redoEffects))
  expect "an edit of something that is not there is refused" True (either (const True) (const False) (decodeSessionRequest (req "figure_edit" ["revision" .= field "revision" (viewValue s3), "figure" .= field "ref" two, "op" .= object ["kind" .= ("delete" :: Text), "at" .= (9999 :: Int)]]) >>= runSession s3))

imageRefLaw :: IO ()
imageRefLaw = do
  let deck = "---\nslideblaster: 1\n---\n\n## One {#one}\n\n![a picture](pic.svg)\n" :: ByteString
      svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"><rect width=\"40\" height=\"20\"/></svg>" :: ByteString
      opening = req "open_project" ["entry" .= ("deck.slideBlaster.md" :: Text), "files" .= [object ["path" .= ("deck.slideBlaster.md" :: Text), "bytesBase16" .= encodeBase16 deck], object ["path" .= ("pic.svg" :: Text), "bytesBase16" .= encodeBase16 svg]]]
      holders key value = case value of
        Object o -> [v | Just v <- [KeyMap.lookup key o]] <> concatMap (holders key) (KeyMap.elems o)
        Array items -> concatMap (holders key) (toList items)
        _ -> []
  (plain, _, _) <- send (newSession markdownAnalyzer) opening
  expect "unasked, a plan carries the image itself" (True, []) (String (encodeBase16 svg) `elem` holders "bytesBase16" (viewValue plain), holders "bytesRef" (viewValue plain))
  (asked, _, _) <- send (newSession markdownAnalyzer) (req "image_refs" ["on" .= True])
  (named, _, _) <- send asked opening
  let refs = holders "bytesRef" (viewValue named)
  expect "asked, it names the image and carries no bytes of it" (True, False) (not (null refs), String (encodeBase16 svg) `elem` holders "bytesBase16" (viewValue named))
  (_, _, got) <- send named (req "resources" ["refs" .= take 1 refs])
  expect "the bytes come when asked for by that name" [String (encodeBase16 svg)] (fmap (field "bytesBase16") (effectsOfKind "resource" got))
  (changed, _, _) <- send named (req "project_file" ["path" .= ("pic.svg" :: Text), "bytesBase16" .= encodeBase16 (svg <> " ")])
  expect "a changed file gets a new name" True (take 1 (holders "bytesRef" (viewValue changed)) /= take 1 refs)

codecLaw :: IO ()
codecLaw = do
  expect "extra field" True (isLeft' (decodeSessionRequest (req "workspace_snapshot" ["x" .= (1 :: Int)])))
  expect "product/2 string" (Left SessionUnsupportedProtocol) (decodeSessionRequest (Char8.pack "{\"protocol\":\"slideblaster.product/2\",\"command\":\"workspace_snapshot\"}"))
  expect "uppercase base16" True (isLeft' (decodeSessionRequest (req "open_source" ["sourceBase16" .= ("AB" :: Text)])))
  expect "before open" (Left SessionNotOpen) (either Left (const (Right ())) (decodeSessionRequest (req "workspace_snapshot" []) >>= runSession (newSession analyzer)))
  where
    isLeft' (Left _) = True
    isLeft' (Right _) = False
