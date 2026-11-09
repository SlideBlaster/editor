{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Extension.Absence
-- Description : Typed absence of a provider, tool or resource.
--
-- A missing tool or provider is a result, never a crash and never a reason to
-- refuse to open, save or export a deck. The host paints a labelled
-- placeholder and shows the diagnostic. An absence is never cached.
module SlideBlaster.Extension.Absence
  ( Absence (..)
  , absenceCode
  , absenceMessage
  , absencePlaceholderLabel
  ) where

import Data.Text (Text)
import Data.Text qualified as Text

-- | Why no artifact could be produced.
data Absence
  = ToolMissing !Text !Text
  -- ^ Provider id and the tool not on @PATH@.
  | NoProvider !Text
  -- ^ No manifest provides this block kind.
  | TimedOut !Text !Int
  -- ^ Provider id and the budget in milliseconds.
  | LimitExceeded !Text !Int
  -- ^ Provider id and the byte limit.
  deriving (Eq, Show)

-- | Stable wire code of the reason.
absenceCode :: Absence -> Text
absenceCode absence = case absence of
  ToolMissing {} -> "tool_missing"
  NoProvider {} -> "no_provider"
  TimedOut {} -> "timeout"
  LimitExceeded {} -> "limit_exceeded"

-- | Human-readable diagnostic text.
absenceMessage :: Absence -> Text
absenceMessage absence = case absence of
  ToolMissing provider tool ->
    tool <> " is not installed; provider " <> provider <> " cannot render"
  NoProvider kind -> "no provider renders blocks of kind '" <> kind <> "'"
  TimedOut provider ms -> "provider " <> provider <> " exceeded " <> Text.pack (show ms) <> " ms"
  LimitExceeded provider bytes ->
    "provider " <> provider <> " produced more than " <> Text.pack (show bytes) <> " bytes"

-- | Short text for the placeholder the host paints in the figure's box.
absencePlaceholderLabel :: Text -> Absence -> Text
absencePlaceholderLabel kind absence = case absence of
  ToolMissing _ tool -> kind <> " figure (" <> tool <> " not installed)"
  NoProvider _ -> kind <> " figure (no renderer)"
  TimedOut {} -> kind <> " figure (render timed out)"
  LimitExceeded {} -> kind <> " figure (output too large)"
