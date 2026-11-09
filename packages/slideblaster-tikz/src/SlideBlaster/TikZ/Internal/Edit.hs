{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

-- |
-- Module      : SlideBlaster.TikZ.Internal.Edit
-- Description : Private candidate-to-verified semantic move transaction.
--
-- A candidate can be built only from direct coordinate provenance. It crosses
-- the verified constructor only after exact source checks, authoritative
-- reparse/elaboration, and equality with the intended semantic picture.
module SlideBlaster.TikZ.Internal.Edit
  ( applyMoveNodeInternal
  , applyMoveNodeWithCoordinateRenderer
  , replaceAuthoredSourceInternal
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List.NonEmpty qualified as NonEmpty
import SlideBlaster.Source
  ( ByteOffset
  , ExactReplacement
  , Revision
  , SourceBufferSnapshot
  , SourceSpan
  , advanceSnapshot
  , applyExactReplacement
  , mkExactReplacement
  , mkSourceSpan
  , snapshotBytes
  , snapshotRevision
  , sourceSpanEnd
  , sourceSpanStart
  , unByteOffset
  )
import SlideBlaster.TikZ.Internal.Decimal
  ( Coordinate
  , renderCoordinateBytes
  )
import SlideBlaster.TikZ.Internal.Parser (parseSnapshot)
import SlideBlaster.TikZ.Internal.Types
  ( AnalysisState (..)
  , CoordinateProvenance (..)
  , Diagnostic
  , DiagnosticCategory (..)
  , DirectSourceError (..)
  , DocumentSnapshot
  , MoveError (..)
  , MoveNode (..)
  , Node (..)
  , NodeId
  , Picture (..)
  , Point (..)
  , ReadyDocument (..)
  , VerificationFailure (..)
  , diagnosticCategory
  , documentAnalysis
  , documentSourceSnapshot
  )

data PatchPhase
  = Candidate
  | Verified

data SemanticTransaction =
  SemanticTransaction !Picture !Picture

data SemanticPatch (phase :: PatchPhase) where
  CandidatePatch
    :: !SourceBufferSnapshot
    -> !ExactReplacement
    -> !SemanticTransaction
    -> SemanticPatch 'Candidate
  VerifiedPatch
    :: !DocumentSnapshot
    -> SemanticPatch 'Verified

-- | Apply a move using the production canonical coordinate renderer.
applyMoveNodeInternal
  :: MoveNode
  -> DocumentSnapshot
  -> Either MoveError DocumentSnapshot
applyMoveNodeInternal =
  applyMoveNodeWithCoordinateRenderer renderCoordinateBytes

-- | Apply a move with an injected private projection renderer.
--
-- This function remains in a hidden module. The production path supplies the
-- canonical renderer; focused tests inject an incorrect renderer to prove that
-- semantic verification rejects a candidate atomically.
applyMoveNodeWithCoordinateRenderer
  :: (Coordinate -> ByteString)
  -> MoveNode
  -> DocumentSnapshot
  -> Either MoveError DocumentSnapshot
applyMoveNodeWithCoordinateRenderer renderCoordinate intent document
  | requestedRevision /= actualRevision =
      Left (MoveStale requestedRevision actualRevision)
  | otherwise =
      case documentAnalysis document of
        AnalysisUnavailable diagnostics ->
          Left (unavailableMoveError targetId diagnostics)
        AnalysisReady (ReadyDocument beforePicture provenance _) ->
          applyReadyMove
            renderCoordinate
            intent
            document
            beforePicture
            provenance
  where
    MoveNode requestedRevision targetId _ = intent
    actualRevision =
      snapshotRevision (documentSourceSnapshot document)

applyReadyMove
  :: (Coordinate -> ByteString)
  -> MoveNode
  -> DocumentSnapshot
  -> Picture
  -> CoordinateProvenance
  -> Either MoveError DocumentSnapshot
applyReadyMove renderCoordinate intent document beforePicture provenance =
  case beforePicture of
    Picture (Node actualId beforePoint content) connector
      | targetId /= actualId ->
          Left (MoveTargetMissing targetId)
      | destination == beforePoint ->
          Right document
      | otherwise -> do
          let afterPicture =
                Picture
                  (Node actualId destination content)
                  connector
              transaction =
                SemanticTransaction beforePicture afterPicture
          candidate <-
            planCandidate
              renderCoordinate
              requestedRevision
              targetId
              beforePoint
              destination
              transaction
              provenance
              (documentSourceSnapshot document)
          verified <- verifyCandidate candidate
          case verified of
            VerifiedPatch successor -> Right successor
  where
    MoveNode requestedRevision targetId destination = intent

planCandidate
  :: (Coordinate -> ByteString)
  -> Revision
  -> NodeId
  -> Point
  -> Point
  -> SemanticTransaction
  -> CoordinateProvenance
  -> SourceBufferSnapshot
  -> Either MoveError (SemanticPatch 'Candidate)
planCandidate
  renderCoordinate
  revision
  targetId
  (Point beforeX beforeY)
  (Point afterX afterY)
  transaction
  provenance
  source =
    case provenance of
      ReadOnlyCoordinates {} ->
        Left (MoveProjectionUnsupported targetId)
      DirectCoordinateSlots xSpan ySpan -> do
        (targetSpan, replacementBytes) <-
          coordinateReplacement
            renderCoordinate
            beforeX
            beforeY
            afterX
            afterY
            xSpan
            ySpan
            source
        let expectedBytes = bytesAtSpan source targetSpan
            exactReplacement =
              mkExactReplacement
                revision
                targetSpan
                expectedBytes
                replacementBytes
        Right (CandidatePatch source exactReplacement transaction)

coordinateReplacement
  :: (Coordinate -> ByteString)
  -> Coordinate
  -> Coordinate
  -> Coordinate
  -> Coordinate
  -> SourceSpan
  -> SourceSpan
  -> SourceBufferSnapshot
  -> Either MoveError (SourceSpan, ByteString)
coordinateReplacement
  renderCoordinate
  beforeX
  beforeY
  afterX
  afterY
  xSpan
  ySpan
  source
    | xChanged && yChanged =
        case
            mkSourceSpan
              (sourceSpanStart xSpan)
              (sourceSpanEnd ySpan)
          of
          Nothing -> Left MoveSemanticsUnavailable
          Just combinedSpan ->
            Right
              ( combinedSpan
              , renderCoordinate afterX
                  <> bytesBetween
                    source
                    (sourceSpanEnd xSpan)
                    (sourceSpanStart ySpan)
                  <> renderCoordinate afterY
              )
    | xChanged = Right (xSpan, renderCoordinate afterX)
    | yChanged = Right (ySpan, renderCoordinate afterY)
    | otherwise = Left MoveSemanticsUnavailable
  where
    xChanged = beforeX /= afterX
    yChanged = beforeY /= afterY

verifyCandidate
  :: SemanticPatch 'Candidate
  -> Either MoveError (SemanticPatch 'Verified)
verifyCandidate
  ( CandidatePatch
      source
      exactReplacement
      (SemanticTransaction _ intendedPicture)
    ) = do
  successorSource <-
    case applyExactReplacement exactReplacement source of
      Left problem -> Left (MoveSourceCheckFailed problem)
      Right updated -> Right updated
  let successorDocument = parseSnapshot successorSource
  case documentAnalysis successorDocument of
    AnalysisUnavailable {} ->
      Left
        (MoveVerificationFailed VerificationParseOrElaborationFailed)
    AnalysisReady (ReadyDocument actualPicture _ _)
      | actualPicture == intendedPicture ->
          Right (VerifiedPatch successorDocument)
      | otherwise ->
          Left (MoveVerificationFailed VerificationSemanticMismatch)

-- | Admit direct authored bytes at the expected revision, retaining invalid input.
replaceAuthoredSourceInternal
  :: Revision
  -> ByteString
  -> DocumentSnapshot
  -> Either DirectSourceError DocumentSnapshot
replaceAuthoredSourceInternal expectedRevision newBytes document
  | expectedRevision /= actualRevision =
      Left (DirectSourceStale expectedRevision actualRevision)
  | newBytes == snapshotBytes source =
      Right document
  | otherwise =
      case advanceSnapshot newBytes source of
        Left problem -> Left (DirectSourceAdvanceFailed problem)
        Right successor -> Right (parseSnapshot successor)
  where
    source = documentSourceSnapshot document
    actualRevision = snapshotRevision source

unavailableMoveError
  :: NodeId
  -> NonEmpty.NonEmpty Diagnostic
  -> MoveError
unavailableMoveError targetId diagnostics
  | any
      ((== DiagnosticAmbiguous) . diagnosticCategory)
      (NonEmpty.toList diagnostics) =
      MoveTargetAmbiguous targetId
  | any
      ((== DiagnosticUnsupported) . diagnosticCategory)
      (NonEmpty.toList diagnostics) =
      MoveProjectionUnsupported targetId
  | otherwise = MoveSemanticsUnavailable

bytesAtSpan :: SourceBufferSnapshot -> SourceSpan -> ByteString
bytesAtSpan source spanValue =
  ByteString.take
    (end - start)
    (ByteString.drop start (snapshotBytes source))
  where
    start = unByteOffset (sourceSpanStart spanValue)
    end = unByteOffset (sourceSpanEnd spanValue)

bytesBetween
  :: SourceBufferSnapshot
  -> ByteOffset
  -> ByteOffset
  -> ByteString
bytesBetween source startOffset endOffset =
  ByteString.take
    (end - start)
    (ByteString.drop start (snapshotBytes source))
  where
    start = unByteOffset startOffset
    end = unByteOffset endOffset
