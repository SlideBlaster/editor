{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Protocol.Version
-- Description : Stable version identifiers for the first shared slice.
--
-- The protocol version changes when request or response meaning becomes
-- incompatible. The implementation version tracks this scaffold's package
-- release and may change without a protocol break.
module SlideBlaster.Protocol.Version
  ( implementationVersion
  , protocolVersion
  ) where

import Data.Text (Text)

-- | Current command/response compatibility version.
protocolVersion :: Text
protocolVersion = "1"

-- | Current shared implementation release.
implementationVersion :: Text
implementationVersion = "0.1.0.0"
