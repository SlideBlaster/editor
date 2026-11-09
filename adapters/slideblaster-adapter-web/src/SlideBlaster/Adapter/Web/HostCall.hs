{-# LANGUAGE JavaScriptFFI #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : SlideBlaster.Adapter.Web.HostCall
-- Description : The single asynchronous JSFFI import used by the web target.
--
-- The shared protocol package owns request and response envelopes. This adapter
-- owns only client correlation state, the foreign call, and translation of
-- JavaScript exceptions into typed host errors.
module SlideBlaster.Adapter.Web.HostCall
  ( HostClient
  , HostError (..)
  , hostCall
  , newHostClient
  , parseHostResult
  , renderHostError
  ) where

import SlideBlaster.Protocol
  ( HostFailure (..)
  , HostRequestId
  , HostResponse (..)
  , decodeHostResponseJSON
  , encodeHostRequestJSON
  , hostRequestIdFromWord64
  , maxHostRequestId
  , mkHostRequest
  )

import Control.Exception (SomeException, displayException, evaluate, try)
import Data.Aeson (Value)
import Data.Aeson.Types (Parser, parseEither)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64)
import GHC.Wasm.Prim (JSString (..), fromJSString, toJSString)

-- | Failures at the transport, envelope, or capability boundary.
data HostError
  = HostUnavailable !Text
  | HostProtocolError !Text
  | HostRejected !Text !Text
  deriving stock (Eq, Show)

-- | Per-reactor request-id state. Its constructor is hidden.
newtype HostClient = HostClient (IORef Word64)

-- | Allocate a host client at the Wasm composition root.
newHostClient :: IO HostClient
newHostClient = HostClient <$> newIORef 0

nextRequestId :: HostClient -> IO (Either HostError Word64)
nextRequestId (HostClient counter) =
  atomicModifyIORef' counter $ \current ->
    if current >= maxHostRequestId
      then
        ( current
        , Left (HostProtocolError "Browser host request identifiers are exhausted")
        )
      else
        let next = current + 1
         in (next, Right next)

-- This is deliberately the adapter's only JavaScript import. All browser
-- capabilities cross the same auditable, versioned JSON boundary.
foreign import javascript safe
  "return await globalThis.slideblasterHost.call($1);"
  jsHostCall :: JSString -> IO JSString

-- | Invoke one browser capability through the shared host envelope.
hostCall
  :: HostClient
  -> Text
  -> Text
  -> Value
  -> IO (Either HostError Value)
hostCall client capability operation payload = do
  nextId <- nextRequestId client
  case nextId of
    Left problem -> pure (Left problem)
    Right requestIdValue ->
      case hostRequestIdFromWord64 requestIdValue of
        Nothing ->
          pure (Left (HostProtocolError "Browser host request id is not JavaScript-safe"))
        Just requestId ->
          case mkHostRequest requestId capability operation payload of
            Left problem ->
              pure (Left (HostProtocolError (Text.pack (show problem))))
            Right request -> do
              decoded <-
                try @SomeException $ do
                  raw <-
                    jsHostCall
                      ( toJSString
                          ( Text.unpack
                              (TextEncoding.decodeUtf8 (encodeHostRequestJSON request))
                          )
                      )
                  evaluate
                    ( decodeHostResponseJSON
                        (TextEncoding.encodeUtf8 (Text.pack (fromJSString raw)))
                    )
              pure $
                case decoded of
                  Left exception ->
                    Left (HostUnavailable (Text.pack (displayException exception)))
                  Right (Left problem) ->
                    Left (HostProtocolError (Text.pack (show problem)))
                  Right (Right response) ->
                    correlate requestId response

correlate :: HostRequestId -> HostResponse -> Either HostError Value
correlate expected response =
  case response of
    HostResponseSucceeded actual payload
      | actual == expected -> Right payload
      | otherwise -> Left mismatchedId
    HostResponseRejected actual failure
      | actual == expected ->
          Left
            ( HostRejected
                (hostFailureCode failure)
                (hostFailureMessage failure)
            )
      | otherwise -> Left mismatchedId
  where
    mismatchedId = HostProtocolError "Host response request id did not match"

-- | Parse a capability-specific result after envelope validation.
parseHostResult :: (Value -> Parser result) -> Value -> Either HostError result
parseHostResult parser value =
  case parseEither parser value of
    Left message -> Left (HostProtocolError (Text.pack message))
    Right result -> Right result

-- | Render a host error without exposing request payloads.
renderHostError :: HostError -> Text
renderHostError = \case
  HostUnavailable message -> "Browser host unavailable: " <> message
  HostProtocolError message -> "Browser host protocol error: " <> message
  HostRejected code message -> code <> ": " <> message
