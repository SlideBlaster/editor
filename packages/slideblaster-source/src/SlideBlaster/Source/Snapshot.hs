-- |
-- Module      : SlideBlaster.Source.Snapshot
-- Description : Immutable authoritative source bytes paired with a revision.
--
-- Snapshot construction is explicit at host boundaries. Advancing with
-- byte-identical content is a no-op; changed content advances the revision
-- exactly once.
module SlideBlaster.Source.Snapshot
  ( SnapshotError (..)
  , SourceBufferSnapshot
  , advanceSnapshot
  , snapshotAtRevision
  , snapshotBytes
  , snapshotFromBytes
  , snapshotRevision
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import SlideBlaster.Source.Revision (Revision, initialRevision, nextRevision)

-- | An immutable source value held by the engine.
data SourceBufferSnapshot = SourceBufferSnapshot !Revision !ByteString
  deriving (Eq)

-- Source bytes are intentionally redacted from accidental logs.
instance Show SourceBufferSnapshot where
  show snapshot =
    "SourceBufferSnapshot {revision = "
      <> show (snapshotRevision snapshot)
      <> ", byteLength = "
      <> show (ByteString.length (snapshotBytes snapshot))
      <> "}"

-- | Failure to create a successor snapshot.
data SnapshotError
  = SnapshotRevisionExhausted !Revision
  deriving (Eq, Show)

-- | Admit source bytes into a new engine session.
snapshotFromBytes :: ByteString -> SourceBufferSnapshot
snapshotFromBytes = SourceBufferSnapshot initialRevision

-- | Reconstruct a snapshot at a trusted protocol boundary.
--
-- Callers must not use this function to bypass a live session's revision
-- fence. It exists for decoding an explicitly versioned request.
snapshotAtRevision :: Revision -> ByteString -> SourceBufferSnapshot
snapshotAtRevision = SourceBufferSnapshot

-- | Return the exact authored bytes.
snapshotBytes :: SourceBufferSnapshot -> ByteString
snapshotBytes (SourceBufferSnapshot _ bytes) = bytes

-- | Return the synchronization revision.
snapshotRevision :: SourceBufferSnapshot -> Revision
snapshotRevision (SourceBufferSnapshot revision _) = revision

-- | Produce the next snapshot, or preserve the input on a byte-identical no-op.
advanceSnapshot
  :: ByteString
  -> SourceBufferSnapshot
  -> Either SnapshotError SourceBufferSnapshot
advanceSnapshot newBytes snapshot
  | newBytes == snapshotBytes snapshot = Right snapshot
  | otherwise =
      case nextRevision (snapshotRevision snapshot) of
        Nothing -> Left (SnapshotRevisionExhausted (snapshotRevision snapshot))
        Just revision -> Right (SourceBufferSnapshot revision newBytes)
