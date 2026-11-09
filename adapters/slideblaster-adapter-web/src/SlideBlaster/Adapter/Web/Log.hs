{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Web.Log
-- Description : Structured browser logging capability.
--
-- Logging is best-effort at call sites, while transport failures remain typed
-- so callers can choose whether a missing logger matters.
module SlideBlaster.Adapter.Web.Log
  ( LogLevel (..)
  , writeLog
  ) where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import SlideBlaster.Adapter.Web.HostCall (HostClient, HostError, hostCall)

data LogLevel
  = Debug
  | Info
  | Warning
  | Error
  deriving stock (Eq, Ord, Show)

writeLog :: HostClient -> LogLevel -> Text -> Value -> IO (Either HostError ())
writeLog client level message context = do
  result <-
    hostCall client
      "log"
      "write"
      ( object
          [ "level" .= renderLevel level
          , "message" .= message
          , "context" .= context
          ]
      )
  pure (() <$ result)

renderLevel :: LogLevel -> Text
renderLevel = \case
  Debug -> "debug"
  Info -> "info"
  Warning -> "warn"
  Error -> "error"
