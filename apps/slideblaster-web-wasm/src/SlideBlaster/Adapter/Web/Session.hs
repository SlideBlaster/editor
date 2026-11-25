-- |
-- Module      : SlideBlaster.Adapter.Web.Session
-- Description : The session/1 core as one in-page cell (milestone W-web).
--
-- The same pure 'runSession' that @sb serve@ drives natively, held in one
-- 'MVar'. Nothing here touches files, providers or the network: every effect
-- the session asks for (@storage@, @block.render@, @measure@, ...) is returned
-- to the page, which performs it and answers with the matching request
-- (@storage_result@, @provider_result@, @measurement_result@, @project_file@).
module SlideBlaster.Adapter.Web.Session
  ( SessionRuntime
  , newSessionRuntime
  , dispatchSessionFrame
  , sessionRuntimeNodeSizes
  ) where

import SlideBlaster.Product.Runtime.Analysis (Analyzer)
import SlideBlaster.Product.Runtime.Session
  ( Session
  , newSession
  , runSession
  , sessionNodeSizesFile
  , viewValue
  )
import SlideBlaster.Protocol.Session
  ( decodeSessionRequest
  , encodeValue
  , sessionErrorValue
  , sessionSuccess
  )

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Control.Exception (evaluate)
import Data.ByteString (ByteString)

-- | One long-lived session.
newtype SessionRuntime = SessionRuntime (MVar Session)

newSessionRuntime :: Analyzer -> IO SessionRuntime
newSessionRuntime analyzer = SessionRuntime <$> newMVar (newSession analyzer)

-- | Answer one request frame. The response is forced before the cell is
-- released, so a failure cannot leave a half-evaluated successor behind.
dispatchSessionFrame :: SessionRuntime -> ByteString -> IO ByteString
dispatchSessionFrame (SessionRuntime cell) frame =
  case decodeSessionRequest frame of
    Left failure -> pure (encodeValue (sessionErrorValue failure))
    Right request ->
      modifyMVar cell $ \session ->
        case runSession session request of
          Left failure -> pure (session, encodeValue (sessionErrorValue failure))
          Right (next, kind, effects) -> do
            response <- evaluate (encodeValue (sessionSuccess kind effects (viewValue next)))
            pure (next, response)

-- | The measured node sizes the page should keep in the project's cache, if any.
sessionRuntimeNodeSizes :: SessionRuntime -> IO (Maybe ByteString)
sessionRuntimeNodeSizes (SessionRuntime cell) = sessionNodeSizesFile <$> readMVar cell
