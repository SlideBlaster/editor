{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Web.Storage
-- Description : Text storage capability interpreted by the browser host.
--
-- Paths are abstract workspace-relative names. The browser host decides the
-- persistence mechanism and validates the path before touching storage.
module SlideBlaster.Adapter.Web.Storage
  ( listPaths
  , readText
  , writeText
  ) where

import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import SlideBlaster.Adapter.Web.HostCall
  ( HostError
  , HostClient
  , hostCall
  , parseHostResult
  )

listPaths :: HostClient -> IO (Either HostError [Text])
listPaths client = do
  result <- hostCall client "storage" "list" (object [])
  pure $ result >>= parseHostResult parseListResult
  where
    parseListResult :: Value -> Parser [Text]
    parseListResult =
      withObject "storage.list payload" $ \value ->
        value .: "paths"

readText :: HostClient -> Text -> IO (Either HostError (Maybe Text))
readText client path = do
  result <-
    hostCall client
      "storage"
      "read"
      (object ["path" .= path])
  pure $ result >>= parseHostResult parseReadResult
  where
    parseReadResult :: Value -> Parser (Maybe Text)
    parseReadResult =
      withObject "storage.read payload" $ \value ->
        value .:? "text"

writeText :: HostClient -> Text -> Text -> IO (Either HostError ())
writeText client path contents = do
  result <-
    hostCall client
      "storage"
      "write"
      ( object
          [ "path" .= path
          , "text" .= contents
          ]
      )
  pure (() <$ result)
