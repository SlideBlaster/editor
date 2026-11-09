-- |
-- Module      : SlideBlaster.Adapter.Web.ProductV2
-- Description : Stateful Wasm cell for source-authoritative product/2.
--
-- The mutable cell contains the shared product runtime only. Protocol JSON
-- decoding/encoding stays in @slideblaster-protocol@; source/history policy,
-- lease checks, semantic projection, and transitions stay in the portable
-- @slideblaster-product-runtime@ package.
module SlideBlaster.Adapter.Web.ProductV2
  ( ProductV2Runtime
  , newProductV2Runtime
  , dispatchProductV2RequestJSON
  ) where

import SlideBlaster.Product.Runtime
  ( ProductV2State
  , newProductV2State
  )
import SlideBlaster.Product.Runtime qualified as ProductRuntime

import Data.ByteString (ByteString)

import Control.Concurrent.MVar
  ( MVar
  , modifyMVar
  , newMVar
  )
import Control.Exception (evaluate)

-- | One long-lived source-authoritative browser runtime.
newtype ProductV2Runtime = ProductV2Runtime (MVar ProductV2State)

-- | Create the runtime without platform effects.
newProductV2Runtime :: IO ProductV2Runtime
newProductV2Runtime = ProductV2Runtime <$> newMVar newProductV2State

-- | Dispatch one request atomically through the shared pure state machine.
dispatchProductV2RequestJSON
  :: ProductV2Runtime
  -> ByteString
  -> IO ByteString
dispatchProductV2RequestJSON (ProductV2Runtime stateCell) requestBytes =
  modifyMVar stateCell $ \current -> do
    let (next, response) =
          ProductRuntime.dispatchProductV2RequestJSON current requestBytes
    forcedNext <- evaluate next
    forcedResponse <- evaluate response
    pure (forcedNext, forcedResponse)
