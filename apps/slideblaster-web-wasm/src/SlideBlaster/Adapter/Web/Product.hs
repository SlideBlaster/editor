-- |
-- Module      : SlideBlaster.Adapter.Web.Product
-- Description : Stateful Wasm composition for the shared product protocol.
--
-- The protocol codec and every state transition remain shared Haskell in
-- @slideblaster-protocol@ and @slideblaster-app@. This adapter contributes only
-- the mutable cell required by a long-lived browser reactor. A rejected request
-- returns the protocol response paired with the unchanged 'LiveAuthoring'
-- value, so failure cannot partially mutate the browser session.
module SlideBlaster.Adapter.Web.Product
  ( ProductRuntime
  , newProductRuntime
  , dispatchProductRequestJSON
  ) where

import SlideBlaster.App
  ( LiveAuthoring
  , LiveAuthoringError
  , newLiveAuthoring
  )
import SlideBlaster.Protocol (dispatchLiveRequestJSON)

import Data.ByteString (ByteString)

import Control.Concurrent.MVar
  ( MVar
  , modifyMVar
  , newMVar
  )

-- | One isolated interactive session owned by the Wasm reactor.
newtype ProductRuntime = ProductRuntime (MVar LiveAuthoring)

-- | Construct the pure initial authoring state before placing it in a cell.
newProductRuntime
  :: IO (Either LiveAuthoringError ProductRuntime)
newProductRuntime =
  case newLiveAuthoring of
    Left failure -> pure (Left failure)
    Right initial ->
      Right . ProductRuntime <$> newMVar initial

-- | Run one shared request atomically and return its closed JSON response.
dispatchProductRequestJSON
  :: ProductRuntime
  -> ByteString
  -> IO ByteString
dispatchProductRequestJSON (ProductRuntime stateCell) requestBytes =
  modifyMVar stateCell $ \current -> do
    let (next, responseBytes) =
          dispatchLiveRequestJSON current requestBytes
    pure (next, responseBytes)
