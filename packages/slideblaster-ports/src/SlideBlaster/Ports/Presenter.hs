{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Ports.Presenter
-- Description : Presenter window handles and navigation-channel transport.
--
-- These ports open/focus/close host windows and transport closed navigation
-- messages. They never own a second deck, a cursor, beats, notes projection, or
-- render semantics; those remain in slideblaster-presentation and
-- slideblaster-render.
module SlideBlaster.Ports.Presenter
  ( PresenterSessionId
  , mkPresenterSessionId
  , presenterSessionIdText
  , PresenterWindowKind (..)
  , PresenterWindowHandle
  , mkPresenterWindowHandle
  , presenterWindowHandleText
  , PresenterNavigation (..)
  , PresenterMessageSequence
  , presenterMessageSequenceFromWord64
  , presenterMessageSequenceToWord64
  , PresenterChannelMessage (..)
  , PresenterPortError (..)
  , PresenterWindowPort (..)
  , PresenterChannelPort (..)
  ) where

import SlideBlaster.Ports.Capability (RuntimeFailure)

import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)

newtype PresenterSessionId = PresenterSessionId Text
  deriving stock (Eq, Ord, Show)

mkPresenterSessionId :: Text -> Maybe PresenterSessionId
mkPresenterSessionId value
  | Text.null (Text.strip value) = Nothing
  | Text.length value > 128 = Nothing
  | Text.any isControl value = Nothing
  | otherwise = Just (PresenterSessionId value)

presenterSessionIdText :: PresenterSessionId -> Text
presenterSessionIdText (PresenterSessionId value) = value

data PresenterWindowKind
  = AudienceWindow
  | PresenterConsoleWindow
  deriving stock (Eq, Ord, Show, Enum, Bounded)

newtype PresenterWindowHandle = PresenterWindowHandle Text
  deriving stock (Eq, Ord, Show)

mkPresenterWindowHandle :: Text -> Maybe PresenterWindowHandle
mkPresenterWindowHandle value
  | Text.null (Text.strip value) = Nothing
  | Text.length value > 256 = Nothing
  | Text.any isControl value = Nothing
  | otherwise = Just (PresenterWindowHandle value)

presenterWindowHandleText :: PresenterWindowHandle -> Text
presenterWindowHandleText (PresenterWindowHandle value) = value

data PresenterNavigation
  = PresenterNext
  | PresenterBack
  | PresenterHome
  | PresenterEnd
  deriving stock (Eq, Ord, Show, Enum, Bounded)

newtype PresenterMessageSequence = PresenterMessageSequence Word64
  deriving stock (Eq, Ord, Show)

presenterMessageSequenceFromWord64
  :: Word64
  -> PresenterMessageSequence
presenterMessageSequenceFromWord64 = PresenterMessageSequence

presenterMessageSequenceToWord64
  :: PresenterMessageSequence
  -> Word64
presenterMessageSequenceToWord64
  (PresenterMessageSequence value) = value

-- | One host-transport message. Haskell applies the command to PresenterState.
data PresenterChannelMessage = PresenterChannelMessage
  { presenterMessageSession :: !PresenterSessionId
  , presenterMessageSequence :: !PresenterMessageSequence
  , presenterMessageNavigation :: !PresenterNavigation
  }
  deriving stock (Eq, Show)

data PresenterPortError
  = PresenterRuntimeFailure !RuntimeFailure
  | PresenterWindowUnknown !PresenterWindowHandle
  | PresenterSessionMismatch !PresenterSessionId
  deriving stock (Eq, Show)

data PresenterWindowPort m = PresenterWindowPort
  { openPresenterWindow
      :: PresenterSessionId
      -> PresenterWindowKind
      -> m (Either PresenterPortError PresenterWindowHandle)
  , focusPresenterWindow
      :: PresenterWindowHandle
      -> m (Either PresenterPortError ())
  , closePresenterWindow
      :: PresenterWindowHandle
      -> m (Either PresenterPortError ())
  }

data PresenterChannelPort m = PresenterChannelPort
  { sendPresenterNavigation
      :: PresenterChannelMessage
      -> m (Either PresenterPortError ())
  , receivePresenterNavigation
      :: PresenterSessionId
      -> m (Either PresenterPortError (Maybe PresenterChannelMessage))
  }
