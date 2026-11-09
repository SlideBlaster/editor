{-# LANGUAGE JavaScriptFFI #-}

-- |
-- Module      : Main
-- Description : Static JavaScript exports for the GHC Wasm reactor.
--
-- Browser effects are imported only by @slideblaster-adapter-web@. This
-- composition root exposes startup and shared-protocol dispatch functions.
module Main
  ( main
  ) where

import SlideBlaster.Adapter.Web.Dispatch
  ( dispatchEngineRequestJSON
  , initializeWebAdapter
  )
import SlideBlaster.Adapter.Web.HostCall (newHostClient, renderHostError)
import SlideBlaster.Adapter.Web.Product
  ( ProductRuntime
  , dispatchProductRequestJSON
  , newProductRuntime
  )
import SlideBlaster.Adapter.Web.ProductV2
  ( ProductV2Runtime
  , dispatchProductV2RequestJSON
  , newProductV2Runtime
  )
import SlideBlaster.Adapter.Web.String
  ( JSString (..)
  , fromWebString
  , toWebString
  )

import Control.Exception (throwIO)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import System.IO.Unsafe (unsafePerformIO)

foreign export javascript "sb_start"
  sbStart :: IO ()

foreign export javascript "sb_dispatch"
  sbDispatch :: JSString -> IO JSString

foreign export javascript "sb_product_dispatch"
  sbProductDispatch :: JSString -> IO JSString

foreign export javascript "sb_product_v2_dispatch"
  sbProductV2Dispatch :: JSString -> IO JSString

main :: IO ()
main = sbStart

sbStart :: IO ()
sbStart = do
  client <- newHostClient
  initialized <- initializeWebAdapter client
  case initialized of
    Left hostError ->
      throwIO (userError (Text.unpack (renderHostError hostError)))
    Right () ->
      pure ()

sbDispatch :: JSString -> IO JSString
sbDispatch =
  pure
    . toWebString
    . TextEncoding.decodeUtf8
    . dispatchEngineRequestJSON
    . TextEncoding.encodeUtf8
    . fromWebString

sbProductV2Dispatch :: JSString -> IO JSString
sbProductV2Dispatch request = do
  response <-
    dispatchProductV2RequestJSON
      productV2Runtime
      (TextEncoding.encodeUtf8 (fromWebString request))
  pure (toWebString (TextEncoding.decodeUtf8 response))

-- Product/2 deliberately has its own AppModel-backed runtime. It does not
-- share or translate the legacy LiveAuthoring cell used by product/1.
{-# NOINLINE productV2Runtime #-}
productV2Runtime :: ProductV2Runtime
productV2Runtime = unsafePerformIO newProductV2Runtime

sbProductDispatch :: JSString -> IO JSString
sbProductDispatch request = do
  response <-
    dispatchProductRequestJSON
      productRuntime
      (TextEncoding.encodeUtf8 (fromWebString request))
  pure (toWebString (TextEncoding.decodeUtf8 response))

-- The static foreign export cannot receive an application environment.
-- Keeping this single cell at the Wasm composition root avoids a mutable global
-- in shared domain code while giving every request the same revisioned session.
{-# NOINLINE productRuntime #-}
productRuntime :: ProductRuntime
productRuntime =
  unsafePerformIO $ do
    initialized <- newProductRuntime
    case initialized of
      Left failure ->
        throwIO
          ( userError
              ("Could not initialize product runtime: " <> show failure)
          )
      Right runtime -> pure runtime
