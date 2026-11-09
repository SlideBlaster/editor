{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Native codec and envelope-shape laws for Product/2.
module Main (main) where

import SlideBlaster.Protocol
  ( PointValue (..)
  , PointerEventValue (..)
  , PointerSampleValue (..)
  , PointerTargetValue (..)
  , ProductV2Error (..)
  , ProductV2Request (..)
  , SurfaceKindValue (..)
  , SurfaceValue (..)
  , decodeProductV2RequestJSON
  , encodeProductV2ErrorJSON
  , encodeProductV2SuccessJSON
  , productProtocolV2
  , productV2Success
  )

import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)

import Control.Monad (unless)
import System.Exit (exitFailure)

main :: IO ()
main = do
  run "codec rejects malformed, unknown, and extra-key requests" closedRequestShape
  run "codec decodes raw pointer vocabulary without semantic imports" rawPointerCodec
  run "codec rejects the removed viewport command" removedViewportCommand
  run "codec decodes keyboard node activation and New Slide as closed commands" keyboardActivationCodec
  run "success and error envelopes have frozen top-level shape" envelopeShape

run :: String -> IO () -> IO ()
run name check = check >> putStrLn ("PASS: " <> name)

closedRequestShape :: IO ()
closedRequestShape = do
  assertEqual "malformed" (Left ProductV2MalformedJSON) (decodeProductV2RequestJSON "{")
  assertEqual
    "unknown command"
    (Left ProductV2UnknownCommand)
    (decode (request "begin_drag" []))
  assertInvalidField (decode (request "workspace_snapshot" ["extra" .= True]))

rawPointerCodec :: IO ()
rawPointerCodec = do
  decoded <- requireRight (decode (request "pointer_event" ["event" .= downEvent]))
  case decoded of
    ProductV2PointerEvent (PointerDownValue (NodeTargetValue (SurfaceValue "trial" AudienceSurfaceValue) "alpha") sample) -> do
      assertEqual "css point" (PointValue 10 10) (pointerCssPointValue sample)
      assertEqual "slide point" (PointValue (3 / 2) 0) (pointerSlidePointValue sample)
    _ -> failTest "unexpected raw pointer request"

keyboardActivationCodec :: IO ()
keyboardActivationCodec = do
  decoded <- requireRight (decode (request "activate_node" ["surface" .= surface, "nodeId" .= ("alpha" :: Text)]))
  assertEqual "activation" (ProductV2ActivateNode (SurfaceValue "trial" AudienceSurfaceValue) "alpha") decoded
  assertInvalidField (decode (request "activate_node" ["surface" .= surface, "nodeId" .= ("alpha" :: Text), "revision" .= (0 :: Int)]))
  assertEqual "slide selection" (Right (SelectSlideProduct "finish")) (decode (request "select_slide" ["frame" .= ("finish" :: Text)]))
  assertInvalidField (decode (request "select_slide" ["frame" .= ("finish" :: Text), "index" .= (2 :: Int)]))
  assertEqual "new slide" (Right (NewSlideProduct 7)) (decode (request "new_slide" ["revision" .= (7 :: Int)]))

-- | Which part of the canvas is visible is browser presentation state, so the
-- viewport command was removed from the boundary and must not decode.
removedViewportCommand :: IO ()
removedViewportCommand = do
  assertEqual
    "viewport event"
    (Left ProductV2UnknownCommand)
    (decode (request "viewport_event" ["event" .= object ["type" .= ("wheel" :: Text)]]))
  assertEqual
    "zoom view command"
    (Left (ProductV2InvalidField "request.viewCommand is invalid"))
    (decode (request "view_command" ["viewCommand" .= ("zoom_in" :: Text)]))

envelopeShape :: IO ()
envelopeShape = do
  success <- decodeValue (encodeProductV2SuccessJSON (productV2Success "node_activated" [object ["kind" .= ("focus_node" :: Text), "nodeId" .= ("alpha" :: Text)]] (object [])))
  assertKeys ["protocol", "ok", "kind", "actions", "workspace"] success
  failure <- decodeValue (encodeProductV2ErrorJSON ProductV2NodeNotAdmitted)
  assertKeys ["protocol", "ok", "kind", "error"] failure
  errorValue <- field "error" failure
  assertKeys ["code", "message"] errorValue

request :: Text -> [Pair] -> Value
request command fields = object (["protocol" .= productProtocolV2, "command" .= command] <> fields)

downEvent :: Value
downEvent =
  object
    [ "type" .= ("down" :: Text)
    , "pointerId" .= (7 :: Int)
    , "pointerType" .= ("mouse" :: Text)
    , "button" .= (0 :: Int)
    , "primary" .= True
    , "cssPoint" .= point "10" "10"
    , "slidePoint" .= point "3/2" "0"
    , "modifiers" .= object ["alt" .= False, "shift" .= False, "control" .= False, "meta" .= False]
    , "target" .= object ["kind" .= ("node" :: Text), "surface" .= surface, "nodeId" .= ("alpha" :: Text)]
    ]

surface :: Value
surface = object ["frame" .= ("trial" :: Text), "kind" .= ("audience" :: Text)]

point :: Text -> Text -> Value
point x y = object ["x" .= x, "y" .= y]

decode :: Value -> Either ProductV2Error ProductV2Request
decode = decodeProductV2RequestJSON . LazyByteString.toStrict . encode

assertInvalidField :: Either ProductV2Error value -> IO ()
assertInvalidField result =
  case result of
    Left ProductV2InvalidField {} -> pure ()
    _ -> failTest "expected invalid_field"

requireRight :: Either ProductV2Error value -> IO value
requireRight result =
  case result of
    Left failure -> failTest ("unexpected decode failure: " <> show failure)
    Right value -> pure value

decodeValue :: ByteString -> IO Value
decodeValue bytes =
  case eitherDecodeStrict' bytes of
    Left problem -> failTest ("invalid response JSON: " <> problem)
    Right value -> pure value

field :: Text -> Value -> IO Value
field name (Object value) =
  maybe (failTest ("missing field: " <> show name)) pure (KeyMap.lookup (Key.fromText name) value)
field _ _ = failTest "expected object"

assertKeys :: [Text] -> Value -> IO ()
assertKeys expected (Object value) = do
  let actual = fmap Key.toText (KeyMap.keys value)
  unless (length actual == length expected && all (`elem` expected) actual)
    (failTest ("unexpected keys: " <> show actual))
assertKeys _ _ = failTest "expected object"

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  unless (expected == actual) (failTest (label <> ": expected " <> show expected <> ", got " <> show actual))

failTest :: String -> IO value
failTest message = putStrLn ("FAIL: " <> message) >> exitFailure
