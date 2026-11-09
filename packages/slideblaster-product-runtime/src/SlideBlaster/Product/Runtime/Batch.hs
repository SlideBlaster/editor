{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.Batch
-- Description : Headless session run for export: open, render every block, project plans.
--
-- Drives the pure 'Session' to quiescence without a UI: every @block.render@
-- effect is served by the supplied provider and its result fed back through the
-- same fenced @provider_result@ path the server uses, so exported figures obey
-- the ticket and fingerprint laws too.
module SlideBlaster.Product.Runtime.Batch
  ( renderProject
  ) where

import SlideBlaster.Product.Runtime.Analysis (Analyzer)
import SlideBlaster.Product.Runtime.Session
import SlideBlaster.Protocol.Session

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Text (Text)

-- | Open a project and project every slide. The provider receives the @/cap@
-- shaped @block.render@ request of each figure.
renderProject
  :: Analyzer
  -> Text
  -> [(Text, ByteString)]
  -> (Value -> IO ProviderOutcome)
  -> IO (Either SessionError Value)
renderProject analyzer entry files provider =
  case runSession (newSession analyzer) (OpenProject entry files) of
    Left failure -> pure (Left failure)
    Right (session, _, effects) -> do
      final <- serve session effects
      pure (maybe (Left SessionDeckNotReady) Right (final >>= deckExportValue))
  where
    serve session effects =
      case [(t, fp, r) | Object o <- effects, KeyMap.lookup "kind" o == Just (String "block.render"), Just (Number t) <- [KeyMap.lookup "ticket" o], Just (String fp) <- [KeyMap.lookup "fingerprint" o], Just r <- [KeyMap.lookup "request" o]] of
        [] -> pure (Just session)
        requests -> feed session requests
    feed session [] = pure (Just session)
    feed session ((ticket, fingerprint, request) : rest) = do
      outcome <- provider request
      case runSession session (ProviderResult (round ticket) fingerprint outcome) of
        Left _ -> pure Nothing
        Right (session', _, _) -> feed session' rest
