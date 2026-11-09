{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Laws of the session/1 state machine over a stand-in analyzer.
module Main (main) where

import SlideBlaster.Product.Runtime.Session
import SlideBlaster.Protocol.Session
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
  run "codec is exact-key and rejects Product/2" codecLaw
  run "a deck in a subfolder is laid out with the theme next to it" deckThemeLaw

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
files1 = [("talk.slideBlaster.md", deck1), ("figures/a.tikz", "\\draw (0,0) -- (1,1);")]

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
      expect "body is the file" (String "\\draw (0,0) -- (1,1);") (path ["request", "input", "body"] e)
      expect "inputs carry base64" (String "XGRyYXcgKDAsMCkgLS0gKDEsMSk7") (path ["request", "input", "inputs"] e `seq` field "contentBase64" (head' (arr (path ["request", "input", "inputs"] e))))
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
  (s2, _, effects2) <- send s (req "project_file" ["path" .= ("figures/a.tikz" :: Text), "bytesBase16" .= encodeBase16 "\\draw (0,0) -- (2,2);"])
  e2 <- figureEffect effects2
  expect "new fingerprint" False (field "fingerprint" e == field "fingerprint" e2)
  (_, _, effects3) <- send s2 (req "project_file" ["path" .= ("figures/a.tikz" :: Text), "bytesBase16" .= encodeBase16 "\\draw (0,0) -- (2,2);"])
  expect "same bytes, same fingerprint: no new request" [] (effectsOfKind "block.render" effects3)

codecLaw :: IO ()
codecLaw = do
  expect "extra field" True (isLeft' (decodeSessionRequest (req "workspace_snapshot" ["x" .= (1 :: Int)])))
  expect "product/2 string" (Left SessionUnsupportedProtocol) (decodeSessionRequest (Char8.pack "{\"protocol\":\"slideblaster.product/2\",\"command\":\"workspace_snapshot\"}"))
  expect "uppercase base16" True (isLeft' (decodeSessionRequest (req "open_source" ["sourceBase16" .= ("AB" :: Text)])))
  expect "before open" (Left SessionNotOpen) (either Left (const (Right ())) (decodeSessionRequest (req "workspace_snapshot" []) >>= runSession (newSession analyzer)))
  where
    isLeft' (Left _) = True
    isLeft' (Right _) = False
