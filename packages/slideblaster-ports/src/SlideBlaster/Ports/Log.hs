{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Ports.Log
-- Description : Small structured logging capability without source payloads.
--
-- Context is a closed scalar vocabulary. Callers must never put authored
-- source, credentials, compiler input, or opaque host values into a log field.
module SlideBlaster.Ports.Log
  ( LogLevel (..)
  , LogValue (..)
  , LogField
  , mkLogField
  , logFieldName
  , logFieldValue
  , LogEntry (..)
  , LogPortError (..)
  , LogPort (..)
  ) where

import SlideBlaster.Ports.Capability (RuntimeFailure)

import Data.Char (isAsciiLower, isAsciiUpper)
import Data.Text (Text)
import Data.Text qualified as Text

data LogLevel
  = DebugLog
  | InfoLog
  | WarningLog
  | ErrorLog
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data LogValue
  = LogText !Text
  | LogInteger !Integer
  | LogBoolean !Bool
  deriving stock (Eq, Ord, Show)

data LogField = LogField !Text !LogValue
  deriving stock (Eq, Ord, Show)

-- | Construct a stable ASCII field name.
mkLogField :: Text -> LogValue -> Maybe LogField
mkLogField name value =
  case Text.uncons name of
    Nothing -> Nothing
    Just (first, remaining)
      | isInitial first && Text.all isContinuation remaining ->
          Just (LogField name value)
      | otherwise -> Nothing

logFieldName :: LogField -> Text
logFieldName (LogField name _) = name

logFieldValue :: LogField -> LogValue
logFieldValue (LogField _ value) = value

data LogEntry = LogEntry
  { logEntryLevel :: !LogLevel
  , logEntryMessage :: !Text
  , logEntryFields :: ![LogField]
  }
  deriving stock (Eq, Show)

data LogPortError
  = LogRuntimeFailure !RuntimeFailure
  deriving stock (Eq, Show)

data LogPort m = LogPort
  { writeLogEntry :: LogEntry -> m (Either LogPortError ())
  }

isInitial :: Char -> Bool
isInitial character =
  isAsciiLower character
    || isAsciiUpper character
    || character == '_'

isContinuation :: Char -> Bool
isContinuation character =
  isInitial character
    || (character >= '0' && character <= '9')
    || character == '-'
