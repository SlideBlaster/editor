-- |
-- Module      : SlideBlaster.Source
-- Description : Public entry point for byte-exact authored source.
--
-- A 'SourceBufferSnapshot' is the authoritative authored byte sequence paired with an
-- in-memory revision. Exact replacements are revision-fenced and preserve every
-- byte outside their target span.
module SlideBlaster.Source
  ( ByteOffset
  , ExactReplacement
  , ExactReplacementError (..)
  , Revision
  , SnapshotError (..)
  , SourceBufferSnapshot
  , SourceSpan
  , advanceSnapshot
  , applyExactReplacement
  , exactReplacementExpected
  , exactReplacementRevision
  , exactReplacementSpan
  , exactReplacementValue
  , initialRevision
  , mkByteOffset
  , mkExactReplacement
  , mkSourceSpan
  , nextRevision
  , revisionFromWord64
  , revisionToWord64
  , snapshotAtRevision
  , snapshotBytes
  , snapshotFromBytes
  , snapshotRevision
  , sourceSpanEnd
  , sourceSpanFromInts
  , sourceSpanLength
  , sourceSpanStart
  , unByteOffset
  ) where

import SlideBlaster.Source.Edit
import SlideBlaster.Source.Revision
import SlideBlaster.Source.Snapshot
import SlideBlaster.Source.Span
