{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Sections, route choices and route-aware presenting over the production analyzer.
module Main (main) where

import SlideBlaster.Product.Runtime.Analysis
import SlideBlaster.Product.Runtime.MarkdownAnalyzer (markdownAnalyzer)
import SlideBlaster.Product.Runtime.Session
import SlideBlaster.Protocol.Session

import Control.Monad (unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as Encoding
import System.Exit (exitFailure)

deck :: ByteString
deck =
  Encoding.encodeUtf8
    "---\nslideblaster: 1\ntitle: T\nroutes:\n  ai: [a, b]\n  fm: [b, a]\n---\n\n\
    \## Pick {#pick}\n\n\\route{ai}{AI first}\n\n\\route{fm}{FM first}\n\n\
    \# Part A {#a}\n\nIntro text\n\n## A1 {#a1}\n\nx\n\n## A2 {#a2}\n\nx\n\n\
    \# Part B {#b .nodivider}\n\n## B1 {#b1}\n\nx\n"

failWith :: String -> IO a
failWith m = putStrLn ("FAIL: " <> m) >> exitFailure

expect :: (Eq a, Show a) => String -> a -> a -> IO ()
expect label e a = unless (e == a) (failWith (label <> "\n  expected: " <> show e <> "\n  actual:   " <> show a))

field :: Text -> Value -> Value
field k (Object o) = fromMaybe Null (KeyMap.lookup (Key.fromText k) o)
field _ _ = Null

arr :: Value -> [Value]
arr (Array a) = toList a
arr _ = []

str :: Value -> Text
str (String t) = t
str _ = ""

req :: Text -> [(Key.Key, Value)] -> ByteString
req command fields = encodeValue (object (["protocol" .= sessionProtocol, "command" .= command] <> fmap (uncurry (.=)) fields))

send :: Session -> ByteString -> IO Session
send s bytes = case decodeSessionRequest bytes of
  Left p -> failWith ("decode: " <> show p)
  Right r -> case runSession s r of
    Left p -> failWith ("run: " <> show p)
    Right (s', _, _) -> pure s'

main :: IO ()
main = do
  let analysis = analyzeDeck markdownAnalyzer mempty "talk.slideBlaster.md" deck
  expect "frames: divider for A, none for B" ["title-slide", "pick", "section-a", "a1", "a2", "b1"] (fmap frameKey (analysisFrames analysis))
  expect "diagnostics clean" [] [diagnosticCode d | d <- analysisDiagnostics analysis, diagnosticSeverity d /= "info"]
  expect "routes" [("ai", ["a", "b"]), ("fm", ["b", "a"])] (analysisRoutes analysis)
  s0 <- send (newSession markdownAnalyzer) (req "open_project" ["entry" .= ("talk.slideBlaster.md" :: Text), "files" .= [object ["path" .= ("talk.slideBlaster.md" :: Text), "bytesBase16" .= encodeBase16 deck]]])
  let v = viewValue s0
  expect "view sections" ["a", "b"] (fmap (str . field "id") (arr (field "sections" v)))
  expect "view section frames" [["section-a", "a1", "a2"], ["b1"]] [fmap str (arr (field "frames" sec)) | sec <- arr (field "sections" v)]
  s1 <- send s0 (req "present_open" ["startFrame" .= ("pick" :: Text)])
  let p st = field "presenter" (viewValue st)
      slide st = (field "number" (field "slide" (p st)), field "count" (field "slide" (p st)))
  expect "choices on the pick slide" ["ai", "fm"] (fmap (str . field "route") (arr (field "choices" (p s1))))
  expect "default route page count" (Number 2, Number 6) (slide s1)
  s2 <- send s1 (req "present_route" ["route" .= ("fm" :: Text)])
  expect "choosing fm goes to b1" "b1" (str (field "frame" (p s2)))
  expect "fm page" (Number 3, Number 6) (slide s2)
  s3 <- send s2 (req "present_step" ["direction" .= ("next" :: Text)])
  expect "next follows fm: a-divider" "section-a" (str (field "frame" (p s3)))
  s4 <- send s1 (req "present_route" ["route" .= ("ai" :: Text)])
  expect "choosing ai goes to the divider" "section-a" (str (field "frame" (p s4)))
  -- the printable deck value: print order, route buttons as links, "Continue:" targets
  case deckExportValue s0 of
    Nothing -> failWith "deckExportValue: no deck"
    Just ex -> do
      let slideOf frame = head' [sl | sl <- arr (field "slides" ex), str (field "frame" sl) == frame]
          head' (x : _) = x
          head' [] = Null
          continues frame = [(str (field "route" c), str (field "title" c), str (field "frame" c)) | c <- arr (field "continue" (slideOf frame))]
      expect "print order: lead, then each section once in default-route order" ["title-slide", "pick", "section-a", "a1", "a2", "b1"] (fmap str (arr (field "order" ex)))
      expect "route buttons carry the first slide after the choice on that route" (object ["ai" .= ("section-a" :: Text), "fm" .= ("b1" :: Text)]) (field "choices" (slideOf "pick"))
      expect "slides without a choice carry none" Null (field "choices" (slideOf "a1"))
      expect "section a continues to b on ai only" [("ai", "Part B", "b1")] (continues "a2")
      expect "section b continues to a on fm only" [("fm", "Part A", "section-a")] (continues "b1")
      expect "inner slides have no continue line" [] (continues "a1")
      expect "theme name is exported" (String "default") (field "theme" ex)
  putStrLn "PASS: sections and routes"
