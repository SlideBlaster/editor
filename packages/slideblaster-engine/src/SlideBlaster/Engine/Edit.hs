{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Engine.Edit
-- Description : Checked application of one byte-local replacement.
--
-- The transaction establishes source revision, expected-byte, locality, and
-- successor-revision laws. It intentionally does not claim TikZ semantic
-- equivalence; a format-aware verifier will wrap this primitive in a later
-- vertical slice.
module SlideBlaster.Engine.Edit
  ( AppliedExactReplacement
  , ExactLocalEditError (..)
  , ExactReplacementReceipt (..)
  , appliedReplacementReceipt
  , appliedReplacementSnapshot
  , applyExactLocalReplacement
  ) where

import Data.ByteString qualified as ByteString
import Data.Text (Text)
import SlideBlaster.Source
  ( ExactReplacement
  , ExactReplacementError
  , Revision
  , SourceBufferSnapshot
  , SourceSpan
  , applyExactReplacement
  , exactReplacementSpan
  , exactReplacementValue
  , nextRevision
  , snapshotBytes
  , snapshotRevision
  , sourceSpanLength
  )

-- | Failure of the source primitive or the engine-level successor law.
data ExactLocalEditError
  = LocalSourceEditRejected !ExactReplacementError
  | LocalEditPostconditionFailed !Text
  deriving (Eq, Show)

-- | Audit metadata for an accepted local edit.
data ExactReplacementReceipt = ExactReplacementReceipt
  { receiptBeforeRevision :: !Revision
  , receiptAfterRevision :: !Revision
  , receiptTargetSpan :: !SourceSpan
  , receiptRemovedByteLength :: !Int
  , receiptInsertedByteLength :: !Int
  , receiptChanged :: !Bool
  }
  deriving (Eq, Show)

-- | A mechanically checked exact replacement and its audit receipt.
--
-- This does not imply format parsing or semantic equivalence. The constructor
-- is hidden so callers cannot fabricate successful application.
data AppliedExactReplacement
  = AppliedExactReplacement !SourceBufferSnapshot !ExactReplacementReceipt
  deriving (Eq, Show)

-- | Apply an exact replacement and verify the resulting revision transition.
applyExactLocalReplacement
  :: ExactReplacement
  -> SourceBufferSnapshot
  -> Either ExactLocalEditError AppliedExactReplacement
applyExactLocalReplacement replacement before = do
  after <- mapLeft LocalSourceEditRejected (applyExactReplacement replacement before)
  verifyRevisionTransition before after
  let receipt =
        ExactReplacementReceipt
          { receiptBeforeRevision = snapshotRevision before
          , receiptAfterRevision = snapshotRevision after
          , receiptTargetSpan = exactReplacementSpan replacement
          , receiptRemovedByteLength = sourceSpanLength (exactReplacementSpan replacement)
          , receiptInsertedByteLength =
              ByteString.length (exactReplacementValue replacement)
          , receiptChanged = snapshotBytes before /= snapshotBytes after
          }
  pure (AppliedExactReplacement after receipt)

-- | Return the accepted successor snapshot.
appliedReplacementSnapshot :: AppliedExactReplacement -> SourceBufferSnapshot
appliedReplacementSnapshot (AppliedExactReplacement snapshot _) = snapshot

-- | Return the audit receipt produced during acceptance.
appliedReplacementReceipt :: AppliedExactReplacement -> ExactReplacementReceipt
appliedReplacementReceipt (AppliedExactReplacement _ receipt) = receipt

verifyRevisionTransition
  :: SourceBufferSnapshot
  -> SourceBufferSnapshot
  -> Either ExactLocalEditError ()
verifyRevisionTransition before after
  | bytesChanged =
      case nextRevision (snapshotRevision before) of
        Just expectedRevision
          | expectedRevision == snapshotRevision after -> Right ()
        _ ->
          Left
            (LocalEditPostconditionFailed "changed bytes did not advance exactly one revision")
  | snapshotRevision before == snapshotRevision after = Right ()
  | otherwise =
      Left
        (LocalEditPostconditionFailed "byte-identical edit unexpectedly advanced its revision")
  where
    bytesChanged = snapshotBytes before /= snapshotBytes after

mapLeft :: (leftA -> leftB) -> Either leftA right -> Either leftB right
mapLeft transform value =
  case value of
    Left problem -> Left (transform problem)
    Right result -> Right result
