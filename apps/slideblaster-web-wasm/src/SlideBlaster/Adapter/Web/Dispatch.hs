{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Web.Dispatch
-- Description : Composition seam from the browser export to the shared protocol.
--
-- The browser passes the JSON encoding owned by @slideblaster-protocol@. This
-- module performs no independent decoding and therefore cannot drift into a
-- web-only engine protocol.
module SlideBlaster.Adapter.Web.Dispatch
  ( dispatchEngineRequestJSON
  , initializeWebAdapter
  ) where

import SlideBlaster.Adapter.Web.HostCall (HostClient, HostError)
import SlideBlaster.Adapter.Web.Log (LogLevel (Info), writeLog)
import SlideBlaster.Protocol
  ( decodeEngineRequestJSON
  , encodeEngineResponseJSON
  , encodeProtocolErrorJSON
  , runEngineRequest
  )

import Data.Aeson (object)
import Data.ByteString (ByteString)

-- | Decode, run, and encode one request using only the shared protocol.
dispatchEngineRequestJSON :: ByteString -> ByteString
dispatchEngineRequestJSON requestBytes =
  case decodeEngineRequestJSON requestBytes of
    Left protocolError -> encodeProtocolErrorJSON protocolError
    Right request ->
      case runEngineRequest request of
        Left protocolError -> encodeProtocolErrorJSON protocolError
        Right response -> encodeEngineResponseJSON response

-- | Verify the browser host boundary during reactor startup.
initializeWebAdapter :: HostClient -> IO (Either HostError ())
initializeWebAdapter client =
  writeLog client Info "SlideBlaster Wasm reactor initialized" (object [])
