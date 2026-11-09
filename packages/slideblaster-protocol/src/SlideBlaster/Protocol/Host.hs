{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Protocol.Host
-- Description : Versioned browser-capability host envelope.
--
-- This module owns the wire shape shared by Haskell Wasm and the packaged
-- JavaScript host. It validates protocol version, JavaScript-safe request
-- identifiers, closed response objects, and the exclusive success/error
-- branches before an adapter can observe a payload.
module SlideBlaster.Protocol.Host
  ( HostFailure (..)
  , HostProtocolDecodeError (..)
  , HostRequest
  , HostRequestError (..)
  , HostRequestId
  , HostResponse (..)
  , decodeHostResponseJSON
  , encodeHostRequestJSON
  , hostProtocolVersion
  , hostRequestIdFromWord64
  , hostRequestIdToWord64
  , maxHostRequestId
  , mkHostRequest
  ) where

import Control.Monad (unless)
import Data.Aeson
  ( FromJSON (parseJSON)
  , Object
  , Value
  , eitherDecodeStrict'
  , encode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)

-- | Numeric protocol version understood by both sides of the host boundary.
hostProtocolVersion :: Word64
hostProtocolVersion = 1

-- | Largest integer represented exactly by JavaScript's number type.
maxHostRequestId :: Word64
maxHostRequestId = 9_007_199_254_740_991

-- | Correlation identifier safe to encode as a JavaScript number.
newtype HostRequestId = HostRequestId Word64
  deriving stock (Eq, Ord, Show)

-- | Validate a request identifier at a protocol boundary.
hostRequestIdFromWord64 :: Word64 -> Maybe HostRequestId
hostRequestIdFromWord64 value
  | value <= maxHostRequestId = Just (HostRequestId value)
  | otherwise = Nothing

-- | Reveal the stable numeric wire representation.
hostRequestIdToWord64 :: HostRequestId -> Word64
hostRequestIdToWord64 (HostRequestId value) = value

-- | A validated capability request.
data HostRequest = HostRequest !HostRequestId !Text !Text !Value
  deriving stock (Eq)

instance Show HostRequest where
  show (HostRequest requestId capability operation _) =
    "HostRequest "
      <> show requestId
      <> " "
      <> show capability
      <> " "
      <> show operation
      <> " <redacted-payload>"

-- | A local construction failure before any host call occurs.
data HostRequestError
  = HostCapabilityEmpty
  | HostOperationEmpty
  deriving stock (Eq, Show)

-- | Construct a request with non-empty capability and operation names.
mkHostRequest
  :: HostRequestId
  -> Text
  -> Text
  -> Value
  -> Either HostRequestError HostRequest
mkHostRequest requestId capability operation payload
  | Text.null capability = Left HostCapabilityEmpty
  | Text.null operation = Left HostOperationEmpty
  | otherwise = Right (HostRequest requestId capability operation payload)

-- | Structured rejection returned by the JavaScript host.
data HostFailure = HostFailure
  { hostFailureCode :: !Text
  , hostFailureMessage :: !Text
  }
  deriving stock (Eq, Show)

-- | A decoded host result. Success and rejection are mutually exclusive.
data HostResponse
  = HostResponseSucceeded !HostRequestId !Value
  | HostResponseRejected !HostRequestId !HostFailure
  deriving stock (Eq)

instance Show HostResponse where
  show response =
    case response of
      HostResponseSucceeded requestId _ ->
        "HostResponseSucceeded "
          <> show requestId
          <> " <redacted-payload>"
      HostResponseRejected requestId failure ->
        "HostResponseRejected "
          <> show requestId
          <> " "
          <> show failure

-- | Explain why a host response was rejected before reaching an adapter.
data HostProtocolDecodeError
  = HostResponseMalformed !Text
  | HostResponseUnsupportedVersion !Word64
  | HostResponseInvalidRequestId !Word64
  deriving stock (Eq, Show)

-- | Encode the one closed request envelope understood by the browser host.
encodeHostRequestJSON :: HostRequest -> ByteString
encodeHostRequestJSON (HostRequest requestId capability operation payload) =
  LazyByteString.toStrict
    ( encode
        ( object
            [ "version" .= hostProtocolVersion
            , "id" .= hostRequestIdToWord64 requestId
            , "capability" .= capability
            , "operation" .= operation
            , "payload" .= payload
            ]
        )
    )

-- | Decode and validate one closed response envelope.
decodeHostResponseJSON
  :: ByteString
  -> Either HostProtocolDecodeError HostResponse
decodeHostResponseJSON bytes = do
  value <-
    first
      (HostResponseMalformed . Text.pack)
      (eitherDecodeStrict' bytes)
  version <-
    first
      (HostResponseMalformed . Text.pack)
      (parseEither parseHostVersion value)
  if version /= hostProtocolVersion
    then Left (HostResponseUnsupportedVersion version)
    else do
      wire <-
        first
          (HostResponseMalformed . Text.pack)
          (parseEither parseJSON value)
      requestId <-
        maybe
          (Left (HostResponseInvalidRequestId (wireRequestId wire)))
          Right
          (hostRequestIdFromWord64 (wireRequestId wire))
      pure $
        case wireResult wire of
          Right payload -> HostResponseSucceeded requestId payload
          Left failure -> HostResponseRejected requestId failure

parseHostVersion :: Value -> Parser Word64
parseHostVersion =
  withObject "SlideBlaster host response" $ \value ->
    value .: "version"

data WireHostResponse = WireHostResponse
  { wireVersion :: !Word64
  , wireRequestId :: !Word64
  , wireResult :: !(Either HostFailure Value)
  }

instance FromJSON WireHostResponse where
  parseJSON =
    withObject "SlideBlaster host response" $ \value -> do
      version <- value .: "version"
      requestId <- value .: "id"
      succeeded <- value .: "ok"
      result <-
        if succeeded
          then do
            requireExactKeys ["version", "id", "ok", "payload"] value
            Right <$> value .: "payload"
          else do
            requireExactKeys ["version", "id", "ok", "error"] value
            errorValue <- value .: "error"
            Left <$> parseHostFailure errorValue
      pure
        WireHostResponse
          { wireVersion = version
          , wireRequestId = requestId
          , wireResult = result
          }

parseHostFailure :: Value -> Parser HostFailure
parseHostFailure =
  withObject "SlideBlaster host error" $ \value -> do
    requireExactKeys ["code", "message"] value
    HostFailure
      <$> value .: "code"
      <*> value .: "message"

requireExactKeys :: [Key] -> Object -> Parser ()
requireExactKeys expected value =
  unless
    ( KeyMap.size value == length expected
        && all (`KeyMap.member` value) expected
    )
    (fail "host response contains missing or unknown fields")
