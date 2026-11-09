-- |
-- Module      : SlideBlaster.App.CanvasEdit
-- Description : Lease-fenced format-neutral canvas edit transactions.
--
-- A request captures one common canvas operation, the exact current accepted
-- document, and its writable paint lease. A format adapter is responsible for
-- semantic verification and may then ask this module to commit its successor.
-- The commit boundary checks only format-neutral mechanical facts: changed
-- bytes, one revision step, the exact current base bytes and revision, and the
-- current lease. It does not claim that an arbitrary document is proof of
-- format-specific semantic verification. A successful commit records the
-- supplied bytes once in source history; rejection, no-op, and stale completion
-- have no state effects.
module SlideBlaster.App.CanvasEdit
  ( CanvasEditRequest
  , CanvasEditError (..)
  , beginCanvasEdit
  , canvasEditRequestDocument
  , canvasEditRequestOperation
  , canvasEditRequestPaint
  , commitCanvasSuccessor
  ) where

import SlideBlaster.App.Lease
  ( PaintRequest
  , authorityAllowsEdit
  , paintRequestRevision
  , paintRequestSurface
  )
import SlideBlaster.App.Model
  ( AppModel
  , SessionChange (..)
  , SessionError
  , appDocumentSession
  , replaceSessionDraft
  , sessionAcceptedDocument
  , sessionCanvasAuthority
  , sessionDraft
  , setAppDocumentSession
  )
import SlideBlaster.Canvas (EditIntent)
import SlideBlaster.Document (DocumentSnapshot, documentSource)
import SlideBlaster.Presentation (Presentation)
import SlideBlaster.Source
  ( Revision
  , SourceBufferSnapshot
  , revisionToWord64
  , snapshotBytes
  , snapshotRevision
  )

-- | One operation captured against current exact source and paint authority.
data CanvasEditRequest syntax key = CanvasEditRequest
  !PaintRequest
  !SourceBufferSnapshot
  !(DocumentSnapshot syntax key Presentation)
  !EditIntent

-- | Failures before a format-owned successor reaches history.
data CanvasEditError
  = CanvasEditLeaseRequired
  | CanvasEditAcceptedDocumentRequired
  | CanvasEditAcceptedDocumentStale !Revision !Revision
  | CanvasEditSuccessorBaseMismatch !Revision !Revision
  | CanvasEditSuccessorNoOp
  | CanvasEditSuccessorRevisionInvalid !Revision !Revision
  | CanvasEditCompletionStale !Revision !Revision
  | CanvasEditSessionError !SessionError
  deriving stock (Eq, Show)

-- | Capture an edit only from a current accepted document and writable lease.
beginCanvasEdit
  :: PaintRequest
  -> EditIntent
  -> AppModel syntax key
  -> Either CanvasEditError (CanvasEditRequest syntax key)
beginCanvasEdit paint operation model
  | not (authorityAllowsEdit paint authority) = Left CanvasEditLeaseRequired
  | paintRequestRevision paint /= snapshotRevision draft =
      Left
        ( CanvasEditAcceptedDocumentStale
            (snapshotRevision draft)
            (paintRequestRevision paint)
        )
  | otherwise =
      case sessionAcceptedDocument session of
        Nothing -> Left CanvasEditAcceptedDocumentRequired
        Just document
          | not (sameSource draft (documentSource document)) ->
              Left
                ( CanvasEditAcceptedDocumentStale
                    (snapshotRevision draft)
                    (snapshotRevision (documentSource document))
                )
          | otherwise ->
              Right (CanvasEditRequest paint draft document operation)
  where
    session = appDocumentSession model
    draft = sessionDraft session
    authority = sessionCanvasAuthority (paintRequestSurface paint) session

canvasEditRequestDocument
  :: CanvasEditRequest syntax key
  -> DocumentSnapshot syntax key Presentation
canvasEditRequestDocument (CanvasEditRequest _ _ document _) = document

canvasEditRequestOperation :: CanvasEditRequest syntax key -> EditIntent
canvasEditRequestOperation (CanvasEditRequest _ _ _ operation) = operation

canvasEditRequestPaint :: CanvasEditRequest syntax key -> PaintRequest
canvasEditRequestPaint (CanvasEditRequest paint _ _ _) = paint

-- | Mechanically commit a successor already verified by its format adapter.
--
-- This function is deliberately not a semantic-verification sealer. App is
-- format-neutral and cannot establish that the successor has the requested
-- meaning. The caller owns that proof and must pass the exact adapter result
-- for this request. App rechecks changed bytes, revision +1, exact base bytes
-- and revision, the captured lease, and the single history transition.
commitCanvasSuccessor
  :: CanvasEditRequest syntax key
  -> DocumentSnapshot syntax key Presentation
  -> AppModel syntax key
  -> Either CanvasEditError (AppModel syntax key)
commitCanvasSuccessor request successor model
  | snapshotBytes after == snapshotBytes before = Left CanvasEditSuccessorNoOp
  | revisionToWord64 (snapshotRevision after)
      /= revisionToWord64 (snapshotRevision before) + 1 =
      Left
        ( CanvasEditSuccessorRevisionInvalid
            (snapshotRevision before)
            (snapshotRevision after)
        )
  | not (sameSource current before) =
      Left
        ( CanvasEditCompletionStale
            (snapshotRevision before)
            (snapshotRevision current)
        )
  | not (authorityAllowsEdit paint authority) = Left CanvasEditLeaseRequired
  | otherwise = do
      change <-
        mapSessionError
          (replaceSessionDraft (snapshotBytes after) session)
      case change of
        SessionUnchanged _ -> Left CanvasEditSuccessorNoOp
        SessionChanged recorded nextSession
          | sameSource recorded after ->
              Right (setAppDocumentSession nextSession model)
          | otherwise ->
              Left
                ( CanvasEditSuccessorBaseMismatch
                    (snapshotRevision after)
                    (snapshotRevision recorded)
                )
  where
    before = requestSource request
    after = documentSource successor
    paint = canvasEditRequestPaint request
    session = appDocumentSession model
    current = sessionDraft session
    authority = sessionCanvasAuthority (paintRequestSurface paint) session

requestSource :: CanvasEditRequest syntax key -> SourceBufferSnapshot
requestSource (CanvasEditRequest _ source _ _) = source

sameSource :: SourceBufferSnapshot -> SourceBufferSnapshot -> Bool
sameSource left right =
  snapshotRevision left == snapshotRevision right
    && snapshotBytes left == snapshotBytes right

mapSessionError
  :: Either SessionError value
  -> Either CanvasEditError value
mapSessionError result =
  case result of
    Left failure -> Left (CanvasEditSessionError failure)
    Right value -> Right value
