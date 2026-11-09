-- |
-- Module      : SlideBlaster.TikZ.Document
-- Description : Coherent exact-source and derived bounded-TikZ document snapshots.
--
-- Opening is total: unsupported or malformed bytes remain authoritative in a
-- syntax-only snapshot. Direct authored replacement is revision-fenced but may
-- intentionally produce such a syntax-only successor.
module SlideBlaster.TikZ.Document
  ( DirectSourceError (..)
  , DocumentSnapshot
  , OpaqueKind (..)
  , OpaqueRegion
  , SemanticState (..)
  , documentDiagnostics
  , documentOpaqueRegions
  , documentPicture
  , documentSemanticState
  , documentSourceSnapshot
  , exactDocumentBytes
  , opaqueKind
  , opaqueRegionBytes
  , opaqueSpan
  , openTikz
  , openTikzBytes
  , replaceAuthoredSource
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import SlideBlaster.Source
  ( Revision
  , SourceBufferSnapshot
  , snapshotBytes
  , snapshotFromBytes
  , sourceSpanEnd
  , sourceSpanStart
  , unByteOffset
  )
import SlideBlaster.TikZ.Internal.Edit (replaceAuthoredSourceInternal)
import SlideBlaster.TikZ.Internal.Parser (parseSnapshot)
import SlideBlaster.TikZ.Internal.Types
  ( DirectSourceError (..)
  , DocumentSnapshot
  , OpaqueKind (..)
  , OpaqueRegion
  , SemanticState (..)
  , documentDiagnostics
  , documentOpaqueRegions
  , documentPicture
  , documentSemanticState
  , documentSourceSnapshot
  , opaqueKind
  , opaqueSpan
  )

-- | Open one already revisioned exact source snapshot.
openTikz :: SourceBufferSnapshot -> DocumentSnapshot
openTikz = parseSnapshot

-- | Open authored bytes at the initial in-process revision.
openTikzBytes :: ByteString -> DocumentSnapshot
openTikzBytes = parseSnapshot . snapshotFromBytes

-- | Return the exact authored bytes without invoking a printer.
exactDocumentBytes :: DocumentSnapshot -> ByteString
exactDocumentBytes =
  snapshotBytes . documentSourceSnapshot

-- | Return the exact bytes denoted by an opaque source region.
opaqueRegionBytes :: DocumentSnapshot -> OpaqueRegion -> ByteString
opaqueRegionBytes document region =
  case opaqueSpan region of
    Nothing -> exactDocumentBytes document
    Just spanValue ->
      ByteString.take
        (end - start)
        (ByteString.drop start (exactDocumentBytes document))
      where
        start = unByteOffset (sourceSpanStart spanValue)
        end = unByteOffset (sourceSpanEnd spanValue)

-- | Admit direct authored bytes at the expected revision.
--
-- Invalid replacement text remains the authoritative successor with typed
-- diagnostics and no writable semantic picture.
replaceAuthoredSource
  :: Revision
  -> ByteString
  -> DocumentSnapshot
  -> Either DirectSourceError DocumentSnapshot
replaceAuthoredSource = replaceAuthoredSourceInternal
