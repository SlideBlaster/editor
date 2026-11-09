{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Web.Measure
-- Description : Browser-backed text measurement capability.
--
-- Measurements are derived layout evidence only; they never become authored
-- source or semantic authority.
module SlideBlaster.Adapter.Web.Measure
  ( TextMeasureRequest (..)
  , TextMetrics (..)
  , measureText
  ) where

import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import SlideBlaster.Adapter.Web.HostCall
  ( HostError
  , HostClient
  , hostCall
  , parseHostResult
  )

data TextMeasureRequest = TextMeasureRequest
  { measureContent :: Text
  , measureFont :: Text
  , measureMaxWidth :: Maybe Double
  }
  deriving stock (Eq, Show)

data TextMetrics = TextMetrics
  { measuredWidth :: Double
  , measuredHeight :: Double
  , measuredLines :: Int
  }
  deriving stock (Eq, Show)

measureText :: HostClient -> TextMeasureRequest -> IO (Either HostError TextMetrics)
measureText client request = do
  result <-
    hostCall client
      "measure"
      "text"
      ( object
          [ "text" .= measureContent request
          , "font" .= measureFont request
          , "maxWidth" .= measureMaxWidth request
          ]
      )
  pure $ result >>= parseHostResult parseMetrics
  where
    parseMetrics :: Value -> Parser TextMetrics
    parseMetrics =
      withObject "measure.text result" $ \value ->
        TextMetrics
          <$> value .: "width"
          <*> value .: "height"
          <*> value .: "lines"
