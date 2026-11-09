-- |
-- Module      : SlideBlaster.Source.Edit
-- Description : Revision-fenced, byte-local exact source replacement.
--
-- Applying an 'ExactReplacement' verifies its source revision, bounds, and
-- expected bytes before constructing a successor. It then checks the locality
-- postcondition: prefix and suffix bytes are unchanged and the requested value
-- occupies exactly the target position.
module SlideBlaster.Source.Edit
  ( ExactReplacement
  , ExactReplacementError (..)
  , applyExactReplacement
  , exactReplacementExpected
  , exactReplacementRevision
  , exactReplacementSpan
  , exactReplacementValue
  , mkExactReplacement
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import SlideBlaster.Source.Revision (Revision)
import SlideBlaster.Source.Snapshot
  ( SnapshotError (..)
  , SourceBufferSnapshot
  , advanceSnapshot
  , snapshotBytes
  , snapshotRevision
  )
import SlideBlaster.Source.Span
  ( SourceSpan
  , sourceSpanEnd
  , sourceSpanStart
  , unByteOffset
  )

-- | A candidate replacement tied to the snapshot that produced it.
data ExactReplacement = ExactReplacement
  { exactReplacementRevision :: !Revision
  , exactReplacementSpan :: !SourceSpan
  , exactReplacementExpected :: !ByteString
  , exactReplacementValue :: !ByteString
  }
  deriving (Eq)

-- Expected and replacement bytes are intentionally redacted from logs.
instance Show ExactReplacement where
  show replacement =
    "ExactReplacement {revision = "
      <> show (exactReplacementRevision replacement)
      <> ", span = "
      <> show (exactReplacementSpan replacement)
      <> ", expectedByteLength = "
      <> show (ByteString.length (exactReplacementExpected replacement))
      <> ", replacementByteLength = "
      <> show (ByteString.length (exactReplacementValue replacement))
      <> "}"

-- | Explain why an exact replacement was rejected without changing source.
data ExactReplacementError
  = ReplacementStale !Revision !Revision
  | ReplacementOutOfBounds !SourceSpan !Int
  | ReplacementExpectedMismatch !Int !Int
  | ReplacementRevisionExhausted !Revision
  | ReplacementLocalityPostconditionFailed
  deriving (Eq)

-- Mismatched authored bytes are never included in diagnostic rendering.
instance Show ExactReplacementError where
  show = \case
    ReplacementStale requested actual ->
      "ReplacementStale {requestedRevision = "
        <> show requested
        <> ", actualRevision = "
        <> show actual
        <> "}"
    ReplacementOutOfBounds target sourceLength ->
      "ReplacementOutOfBounds {span = "
        <> show target
        <> ", sourceByteLength = "
        <> show sourceLength
        <> "}"
    ReplacementExpectedMismatch expectedLength actualLength ->
      "ReplacementExpectedMismatch {expectedByteLength = "
        <> show expectedLength
        <> ", actualByteLength = "
        <> show actualLength
        <> "}"
    ReplacementRevisionExhausted revision ->
      "ReplacementRevisionExhausted {revision = " <> show revision <> "}"
    ReplacementLocalityPostconditionFailed ->
      "ReplacementLocalityPostconditionFailed"

-- | Construct an exact replacement. Application performs all source checks.
mkExactReplacement :: Revision -> SourceSpan -> ByteString -> ByteString -> ExactReplacement
mkExactReplacement = ExactReplacement

-- | Apply and mechanically verify one exact local replacement.
applyExactReplacement
  :: ExactReplacement
  -> SourceBufferSnapshot
  -> Either ExactReplacementError SourceBufferSnapshot
applyExactReplacement replacement snapshot
  | requestedRevision /= actualRevision =
      Left (ReplacementStale requestedRevision actualRevision)
  | end > ByteString.length original =
      Left (ReplacementOutOfBounds target (ByteString.length original))
  | expected /= actual =
      Left
        ( ReplacementExpectedMismatch
            (ByteString.length expected)
            (ByteString.length actual)
        )
  | not (localityHolds original updated target value) =
      Left ReplacementLocalityPostconditionFailed
  | otherwise =
      case advanceSnapshot updated snapshot of
        Left (SnapshotRevisionExhausted revision) ->
          Left (ReplacementRevisionExhausted revision)
        Right successor -> Right successor
  where
    requestedRevision = exactReplacementRevision replacement
    actualRevision = snapshotRevision snapshot
    target = exactReplacementSpan replacement
    expected = exactReplacementExpected replacement
    value = exactReplacementValue replacement
    original = snapshotBytes snapshot
    start = unByteOffset (sourceSpanStart target)
    end = unByteOffset (sourceSpanEnd target)
    actual = ByteString.take (end - start) (ByteString.drop start original)
    updated =
      ByteString.take start original
        <> value
        <> ByteString.drop end original

localityHolds :: ByteString -> ByteString -> SourceSpan -> ByteString -> Bool
localityHolds original updated target value =
  ByteString.take start updated == ByteString.take start original
    && ByteString.take (ByteString.length value) (ByteString.drop start updated) == value
    && ByteString.drop (start + ByteString.length value) updated == ByteString.drop end original
    && ByteString.length updated
      == ByteString.length original - (end - start) + ByteString.length value
  where
    start = unByteOffset (sourceSpanStart target)
    end = unByteOffset (sourceSpanEnd target)
