-- |
-- Module      : SlideBlaster.App.History
-- Description : Branching exact-byte source history with fresh revisions.
--
-- Source history stores authored bytes. Undo and redo restore those bytes by
-- advancing the current snapshot, so old revision identifiers and provenance
-- never regain authority. A byte-identical record is a no-op and a new edit
-- after undo clears the redo branch.
module SlideBlaster.App.History
  ( SourceHistory
  , HistoryError (..)
  , HistoryChange (..)
  , startHistory
  , historyCurrent
  , canUndo
  , canRedo
  , recordHistoryBytes
  , undoHistory
  , redoHistory
  ) where

import Data.ByteString (ByteString)
import SlideBlaster.Source
  ( Revision
  , SnapshotError (SnapshotRevisionExhausted)
  , SourceBufferSnapshot
  , advanceSnapshot
  , snapshotBytes
  , snapshotRevision
  )

data SourceHistory = SourceHistory
  ![ByteString]
  !SourceBufferSnapshot
  ![ByteString]
  deriving stock (Eq, Show)

data HistoryError
  = HistoryRevisionExhausted !Revision
  deriving stock (Eq, Show)

data HistoryChange
  = HistoryNoOp !SourceHistory
  | HistoryAdvanced !SourceBufferSnapshot !SourceHistory
  deriving stock (Eq, Show)

startHistory :: SourceBufferSnapshot -> SourceHistory
startHistory current = SourceHistory [] current []

historyCurrent :: SourceHistory -> SourceBufferSnapshot
historyCurrent (SourceHistory _ current _) = current

canUndo :: SourceHistory -> Bool
canUndo (SourceHistory before _ _) =
  case before of
    [] -> False
    _ -> True

canRedo :: SourceHistory -> Bool
canRedo (SourceHistory _ _ after) =
  case after of
    [] -> False
    _ -> True

recordHistoryBytes
  :: ByteString
  -> SourceHistory
  -> Either HistoryError HistoryChange
recordHistoryBytes bytes history@(SourceHistory before current _)
  | bytes == snapshotBytes current = Right (HistoryNoOp history)
  | otherwise = do
      successor <- advanceOrHistoryError bytes current
      let next =
            SourceHistory
              (snapshotBytes current : before)
              successor
              []
      Right (HistoryAdvanced successor next)

undoHistory :: SourceHistory -> Either HistoryError HistoryChange
undoHistory history@(SourceHistory before current after) =
  case before of
    [] -> Right (HistoryNoOp history)
    priorBytes : earlier -> do
      successor <- advanceOrHistoryError priorBytes current
      let next =
            SourceHistory
              earlier
              successor
              (snapshotBytes current : after)
      Right (HistoryAdvanced successor next)

redoHistory :: SourceHistory -> Either HistoryError HistoryChange
redoHistory history@(SourceHistory before current after) =
  case after of
    [] -> Right (HistoryNoOp history)
    laterBytes : remaining -> do
      successor <- advanceOrHistoryError laterBytes current
      let next =
            SourceHistory
              (snapshotBytes current : before)
              successor
              remaining
      Right (HistoryAdvanced successor next)

advanceOrHistoryError
  :: ByteString
  -> SourceBufferSnapshot
  -> Either HistoryError SourceBufferSnapshot
advanceOrHistoryError bytes snapshot =
  case advanceSnapshot bytes snapshot of
    Left (SnapshotRevisionExhausted revision) ->
      Left (HistoryRevisionExhausted revision)
    Right successor ->
      if snapshotRevision successor == snapshotRevision snapshot
        then Right snapshot
        else Right successor
