-- |
-- Module      : SlideBlaster.Adapter.Native.Provider
-- Description : Shared result shape of native block.render providers.
--
-- A provider run either yields artifact bytes, fails with diagnostics (a
-- user-fixable error such as a TeX error), or is absent (tool missing, timeout,
-- output over the limit). The broker adds caching, provenance and fingerprint
-- echo around this.
module SlideBlaster.Adapter.Native.Provider
  ( ProviderOutcome (..)
  ) where

import SlideBlaster.Extension (Absence, Diagnostic)

import Data.ByteString (ByteString)

-- | What one provider run produced.
data ProviderOutcome
  = ProviderArtifact !ByteString
  | ProviderFailed ![Diagnostic]
  | ProviderAbsent !Absence
  deriving (Eq, Show)
