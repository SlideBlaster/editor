-- |
-- Module      : SlideBlaster.Engine.Inspect
-- Description : Deterministic metadata inspection of authored source.
--
-- Inspection is pure and cross-target: equal bytes and revisions must produce
-- equal results under native GHC and GHC Wasm. The FNV-1a fingerprint is a
-- diagnostic checksum, not a security primitive or persistent identity.
module SlideBlaster.Engine.Inspect
  ( SnapshotInspection (..)
  , Utf8Status (..)
  , inspectSnapshot
  ) where

import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Word (Word64, Word8)
import Numeric (showHex)
import SlideBlaster.Source
  ( Revision
  , SourceBufferSnapshot
  , snapshotBytes
  , snapshotRevision
  )

-- | Whether the complete authored byte sequence is valid UTF-8.
data Utf8Status
  = ValidUtf8
  | InvalidUtf8
  deriving (Eq, Show)

-- | Stable, derived facts about one source snapshot.
data SnapshotInspection = SnapshotInspection
  { inspectionRevision :: !Revision
  , inspectionByteLength :: !Int
  , inspectionLineCount :: !Int
  , inspectionUtf8Status :: !Utf8Status
  , inspectionFingerprint :: !Text
  }
  deriving (Eq, Show)

-- | Inspect a snapshot without interpreting its presentation format.
inspectSnapshot :: SourceBufferSnapshot -> SnapshotInspection
inspectSnapshot snapshot =
  SnapshotInspection
    { inspectionRevision = snapshotRevision snapshot
    , inspectionByteLength = ByteString.length bytes
    , inspectionLineCount = countLines bytes
    , inspectionUtf8Status = utf8Status bytes
    , inspectionFingerprint = fnv1a64 bytes
    }
  where
    bytes = snapshotBytes snapshot

countLines :: ByteString -> Int
countLines bytes =
  case ByteString.unsnoc bytes of
    Nothing -> 0
    Just (_, finalByte)
      | finalByte == lineFeed -> lineFeeds
      | otherwise -> lineFeeds + 1
  where
    lineFeed = 10
    lineFeeds = ByteString.count lineFeed bytes

utf8Status :: ByteString -> Utf8Status
utf8Status bytes =
  case Text.Encoding.decodeUtf8' bytes of
    Left _ -> InvalidUtf8
    Right _ -> ValidUtf8

fnv1a64 :: ByteString -> Text
fnv1a64 bytes = Text.pack ("fnv1a64:" <> padding <> hexadecimal)
  where
    digest = ByteString.foldl' hashByte fnvOffsetBasis bytes
    hexadecimal = showHex digest ""
    padding = replicate (16 - length hexadecimal) '0'

hashByte :: Word64 -> Word8 -> Word64
hashByte hashValue byte = (hashValue `xor` fromIntegral byte) * fnvPrime

fnvOffsetBasis :: Word64
fnvOffsetBasis = 14695981039346656037

fnvPrime :: Word64
fnvPrime = 1099511628211
