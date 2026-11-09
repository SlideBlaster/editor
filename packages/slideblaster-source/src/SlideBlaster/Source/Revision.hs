-- |
-- Module      : SlideBlaster.Source.Revision
-- Description : Monotonic revision identifiers for authored source snapshots.
--
-- Revisions are process-local synchronization fences. They prevent an edit
-- projected from one snapshot from being applied to a different snapshot; they
-- are not persistent file identities or content hashes.
module SlideBlaster.Source.Revision
  ( Revision
  , initialRevision
  , nextRevision
  , revisionFromWord64
  , revisionToWord64
  ) where

import Data.Word (Word64)

-- | An opaque, monotonically increasing snapshot revision.
newtype Revision = Revision Word64
  deriving (Eq, Ord)

instance Show Revision where
  showsPrec precedence (Revision value) = showsPrec precedence value

-- | The revision assigned when bytes first enter an engine session.
initialRevision :: Revision
initialRevision = Revision 0

-- | Construct a revision at a protocol or persistence boundary.
revisionFromWord64 :: Word64 -> Revision
revisionFromWord64 = Revision

-- | Reveal the stable unsigned representation used by protocols.
revisionToWord64 :: Revision -> Word64
revisionToWord64 (Revision value) = value

-- | Advance a revision, failing instead of wrapping at the numeric limit.
nextRevision :: Revision -> Maybe Revision
nextRevision (Revision value)
  | value == maxBound = Nothing
  | otherwise = Just (Revision (value + 1))
