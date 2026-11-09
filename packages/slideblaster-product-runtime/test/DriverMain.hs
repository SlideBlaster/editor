{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : The native session driver interprets storage, providers and watch events.
module Main (main) where

import SlideBlaster.Product.Runtime.Driver
import SlideBlaster.Protocol.Session
import TestAnalyzer

import Control.Concurrent.MVar (MVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar)
import Control.Monad (unless)
import Data.Aeson (Value (..), eitherDecodeStrict', object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import System.Exit (exitFailure)
import System.Timeout (timeout)

main :: IO ()
main = do
  run "open with entry only lists the project through the capability" openLaw
  run "block.render is served by the driver and pushed as view_updated" renderLaw
  run "save writes with expected bytes; conflict reports save_failed" saveLaw
  run "internal-only commands are rejected from the UI" internalLaw
  run "watch events reload a clean deck and re-request figures" watchLaw

run :: String -> IO () -> IO ()
run name check = check >> putStrLn ("PASS: " <> name)

failWith :: String -> IO a
failWith message = putStrLn ("FAIL: " <> message) >> exitFailure

expect :: (Eq a, Show a) => String -> a -> a -> IO ()
expect label expected actual =
  unless (expected == actual) $ failWith (label <> "\n  expected: " <> show expected <> "\n  actual:   " <> show actual)

data Fake = Fake
  { fakeWrites :: MVar [(Text, Maybe ByteString, ByteString)]
  , fakeConflict :: MVar Bool
  , fakeRenders :: MVar Int
  }

mkDriver :: IO (SessionDriver, Fake, MVar ByteString)
mkDriver = do
  writes <- newMVar []
  conflict <- newMVar False
  renders <- newMVar 0
  pushed <- newEmptyMVar
  let capabilities =
        Capabilities
          { capListProject = pure [("talk.slideBlaster.md", deck1), ("figures/a.tikz", "\\draw (0,0);")]
          , capWriteFile = \path expected new -> do
              bad <- readMVar conflict
              modifyMVar_ writes (pure . ((path, expected, new) :))
              pure (if bad then Left "conflict" else Right ())
          , capRenderBlock = \_ -> do
              modifyMVar_ renders (pure . (+ 1))
              pure (ProviderArtifactOutcome (ProviderArtifact "image/svg+xml" "<svg/>" 10 5 "fake"))
          }
  driver <- newSessionDriver capabilities analyzer (putMVar pushed)
  pure (driver, Fake writes conflict renders, pushed)

req :: Text -> [(Key.Key, Value)] -> ByteString
req command fields = encodeValue (object (["protocol" .= sessionProtocol, "command" .= command] <> fmap (uncurry (.=)) fields))

decode :: ByteString -> IO Value
decode bytes = either (\e -> failWith ("json: " <> e)) pure (eitherDecodeStrict' bytes)

field :: Text -> Value -> Value
field k (Object o) = fromMaybe Null (KeyMap.lookup (Key.fromText k) o)
field _ _ = Null

kindsOf :: Value -> [Value]
kindsOf v = case field "effects" v of
  Array a -> fmap (field "kind") (toList a)
  _ -> []

openRequest :: ByteString
openRequest = req "open_project" ["entry" .= ("talk.slideBlaster.md" :: Text)]

openLaw :: IO ()
openLaw = do
  (driver, _, _) <- mkDriver
  response <- handleSessionFrame driver openRequest >>= decode
  expect "ok" (Bool True) (field "ok" response)
  expect "ui sees measure only" [String "measure"] (kindsOf response)
  expect "frames" 2 (case field "navigator" (field "view" response) of
    o -> case field "items" o of Array a -> length a; _ -> 0)

renderLaw :: IO ()
renderLaw = do
  (driver, fake, pushed) <- mkDriver
  _ <- handleSessionFrame driver openRequest
  frame <- timeout 5000000 (takeMVar pushed)
  case frame of
    Nothing -> failWith "no push within 5s"
    Just bytes -> do
      push <- decode bytes
      expect "push kind" (String "view_updated") (field "kind" push)
      expect "render called once" 1 =<< readMVar (fakeRenders fake)

saveLaw :: IO ()
saveLaw = do
  (driver, fake, _) <- mkDriver
  _ <- handleSessionFrame driver openRequest
  response <- handleSessionFrame driver (req "command" ["name" .= ("save" :: Text)]) >>= decode
  expect "saved" (String "saved") (field "kind" response)
  writes <- readMVar (fakeWrites fake)
  expect "write was compare-and-replace" [("talk.slideBlaster.md", Just deck1, deck1)] writes
  modifyMVar_ (fakeConflict fake) (pure . const True)
  conflicted <- handleSessionFrame driver (req "command" ["name" .= ("save" :: Text)]) >>= decode
  expect "conflict" (String "save_failed") (field "kind" conflicted)

internalLaw :: IO ()
internalLaw = do
  (driver, _, _) <- mkDriver
  _ <- handleSessionFrame driver openRequest
  response <- handleSessionFrame driver (req "project_file" ["path" .= ("x" :: Text), "bytesBase16" .= ("" :: Text)]) >>= decode
  expect "rejected" (String "unknown_command") (field "code" (field "error" response))

watchLaw :: IO ()
watchLaw = do
  (driver, fake, pushed) <- mkDriver
  _ <- handleSessionFrame driver openRequest
  _ <- takeMVar pushed
  driverFileChanged driver "figures/a.tikz" (Just "\\draw (1,1);")
  frame <- timeout 5000000 (takeMVar pushed)
  case frame of
    Nothing -> failWith "no push"
    Just bytes -> do
      push <- decode bytes
      expect "watch push" (String "view_updated") (field "kind" push)
  _ <- timeout 2000000 (takeMVar pushed)
  n <- readMVar (fakeRenders fake)
  expect "figure re-rendered after file change" True (n >= 2)
  let new = ByteString.concat [deck1, "extra\n"]
  driverFileChanged driver "talk.slideBlaster.md" (Just new)
  _ <- timeout 2000000 (takeMVar pushed)
  snapshot <- handleSessionFrame driver (req "workspace_snapshot" []) >>= decode
  expect "deck reloaded to disk bytes" (String (encodeBase16 new)) (field "sourceBase16" (field "source" (field "view" snapshot)))
