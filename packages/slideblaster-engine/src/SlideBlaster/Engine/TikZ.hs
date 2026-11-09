{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Engine.TikZ
-- Description : Pure engine composition for the bounded TikZ vertical slice.
--
-- The engine opens one exact snapshot with the authoritative bounded reader,
-- derives either a render plan or syntax-only diagnostics, and applies only a
-- typed, semantically verified node move. Protocol and host layers translate
-- values around this API; they do not reproduce its document semantics.
module SlideBlaster.Engine.TikZ
  ( AppliedTikzMove
  , TikzAnalysis (..)
  , TikzIntentError (..)
  , TikzMoveIntent
  , TikzMoveOutcome (..)
  , analyzeTikzSnapshot
  , appliedTikzMoveAnalysis
  , appliedTikzMoveBeforeRevision
  , appliedTikzMoveIntent
  , appliedTikzMoveOutcome
  , applyTikzMove
  , AppliedTikzStyle
  , TikzStyleIntent
  , TikzStyleOutcome (..)
  , appliedTikzStyleAnalysis
  , appliedTikzStyleBeforeRevision
  , appliedTikzStyleIntent
  , appliedTikzStyleOutcome
  , applyTikzStyle
  , mkTikzStyleIntent
  , tikzStyleIntentCommand
  , tikzStyleIntentDialect
  , tikzStyleIntentNodeId
  , tikzStyleIntentRevision
  , mkTikzMoveIntent
  , tikzAnalysisSnapshot
  , tikzMoveIntentDestination
  , tikzMoveIntentNodeId
  , tikzMoveIntentRevision
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import SlideBlaster.Source
  ( Revision
  , SourceBufferSnapshot
  , snapshotRevision
  )
import SlideBlaster.Syntax.Command (Command)
import SlideBlaster.Syntax.Surface (Dialect)
import SlideBlaster.TikZ
  ( CoordinateError
  , Diagnostic
  , DocumentSnapshot
  , MoveError
  , NodeId
  , Point
  , RenderError (..)
  , RenderPlan
  , applyMoveNode
  , coordinateFromDecimalText
  , documentSourceSnapshot
  , mkNodeId
  , moveNode
  , openTikz
  , point
  , renderDocument
  , StyleError
  , applyStyleNode
  , styleNode
  )

-- | Total analysis of one exact source snapshot.
data TikzAnalysis
  = TikzAnalysisReady !DocumentSnapshot !RenderPlan
  | TikzAnalysisSyntaxOnly !DocumentSnapshot !(NonEmpty Diagnostic)
  deriving (Eq, Show)

-- | A validated semantic node-move intent admitted at an engine boundary.
data TikzMoveIntent = TikzMoveIntent !Revision !NodeId !Point
  deriving (Eq, Show)

-- | Why a wire or CLI value cannot become a typed move intent.
data TikzIntentError
  = TikzIntentInvalidNodeId !Text
  | TikzIntentInvalidX !CoordinateError
  | TikzIntentInvalidY !CoordinateError
  deriving (Eq, Show)

-- | Whether a verified move changed exact source.
data TikzMoveOutcome
  = TikzMoveVerifiedChange
  | TikzMoveUnchanged
  deriving (Eq, Show)

-- | A successful move and the authoritative analysis of its successor.
data AppliedTikzMove = AppliedTikzMove
  !Revision
  !TikzMoveIntent
  !TikzMoveOutcome
  !TikzAnalysis
  deriving (Eq, Show)

-- | Analyze exact source without changing bytes or revision.
analyzeTikzSnapshot :: SourceBufferSnapshot -> TikzAnalysis
analyzeTikzSnapshot = analyzeDocument . openTikz

-- | Validate textual boundary values without floating-point conversion.
mkTikzMoveIntent
  :: Revision
  -> Text
  -> Text
  -> Text
  -> Either TikzIntentError TikzMoveIntent
mkTikzMoveIntent revision nodeIdText xText yText = do
  nodeIdentity <-
    case mkNodeId nodeIdText of
      Nothing -> Left (TikzIntentInvalidNodeId nodeIdText)
      Just value -> Right value
  xCoordinate <-
    case coordinateFromDecimalText xText of
      Left problem -> Left (TikzIntentInvalidX problem)
      Right value -> Right value
  yCoordinate <-
    case coordinateFromDecimalText yText of
      Left problem -> Left (TikzIntentInvalidY problem)
      Right value -> Right value
  Right
    ( TikzMoveIntent
        revision
        nodeIdentity
        (point xCoordinate yCoordinate)
    )

-- | Open, apply, reparse, and semantically verify one typed move.
applyTikzMove
  :: TikzMoveIntent
  -> SourceBufferSnapshot
  -> Either MoveError AppliedTikzMove
applyTikzMove intent source = do
  successor <-
    applyMoveNode
      (moveNode requestedRevision target destination)
      (openTikz source)
  let successorAnalysis = analyzeDocument successor
      successorRevision =
        snapshotRevision (documentSourceSnapshot successor)
      outcome
        | successorRevision == beforeRevision = TikzMoveUnchanged
        | otherwise = TikzMoveVerifiedChange
  Right
    ( AppliedTikzMove
        beforeRevision
        intent
        outcome
        successorAnalysis
    )
  where
    TikzMoveIntent requestedRevision target destination = intent
    beforeRevision = snapshotRevision source

-- | A validated content style intent admitted at an engine boundary.
-- | A style change, its target, and the theme's default notation.
--
-- The dialect is a theme setting. Authored content is one mixed language with no
-- outermost notation, so nothing about the file could supply it, and the interface
-- must not invent it per gesture.
data TikzStyleIntent = TikzStyleIntent !Revision !NodeId !Dialect !Command
  deriving (Eq, Show)

-- | Whether a verified style change altered exact source.
data TikzStyleOutcome
  = TikzStyleVerifiedChange
  | TikzStyleUnchanged
  deriving (Eq, Show)

-- | A successful style change and the authoritative analysis of its successor.
data AppliedTikzStyle = AppliedTikzStyle
  !Revision
  !TikzStyleIntent
  !TikzStyleOutcome
  !TikzAnalysis
  deriving (Eq, Show)

-- | Validate a wire node identity, leaving the command to the syntax package.
--
-- The command needs no validation here because it is already a typed value: a
-- target it cannot resolve and a style it cannot spell are refused where the tree
-- is understood, with reasons this boundary could not produce.
mkTikzStyleIntent
  :: Revision
  -> Text
  -> Dialect
  -> Command
  -> Either TikzIntentError TikzStyleIntent
mkTikzStyleIntent revision nodeIdText themeDialect command =
  case mkNodeId nodeIdText of
    Nothing -> Left (TikzIntentInvalidNodeId nodeIdText)
    Just nodeIdentity ->
      Right (TikzStyleIntent revision nodeIdentity themeDialect command)

-- | Open, apply, reparse, and semantically verify one typed style change.
applyTikzStyle
  :: TikzStyleIntent
  -> SourceBufferSnapshot
  -> Either StyleError AppliedTikzStyle
applyTikzStyle intent source = do
  successor <-
    applyStyleNode
      (styleNode requestedRevision target themeDialect command)
      (openTikz source)
  let successorAnalysis = analyzeDocument successor
      successorRevision =
        snapshotRevision (documentSourceSnapshot successor)
      outcome
        | successorRevision == beforeRevision = TikzStyleUnchanged
        | otherwise = TikzStyleVerifiedChange
  Right (AppliedTikzStyle beforeRevision intent outcome successorAnalysis)
  where
    TikzStyleIntent requestedRevision target themeDialect command = intent
    beforeRevision = snapshotRevision source

appliedTikzStyleBeforeRevision :: AppliedTikzStyle -> Revision
appliedTikzStyleBeforeRevision (AppliedTikzStyle value _ _ _) = value

appliedTikzStyleIntent :: AppliedTikzStyle -> TikzStyleIntent
appliedTikzStyleIntent (AppliedTikzStyle _ value _ _) = value

appliedTikzStyleOutcome :: AppliedTikzStyle -> TikzStyleOutcome
appliedTikzStyleOutcome (AppliedTikzStyle _ _ value _) = value

appliedTikzStyleAnalysis :: AppliedTikzStyle -> TikzAnalysis
appliedTikzStyleAnalysis (AppliedTikzStyle _ _ _ value) = value

tikzStyleIntentRevision :: TikzStyleIntent -> Revision
tikzStyleIntentRevision (TikzStyleIntent value _ _ _) = value

tikzStyleIntentNodeId :: TikzStyleIntent -> NodeId
tikzStyleIntentNodeId (TikzStyleIntent _ value _ _) = value

tikzStyleIntentCommand :: TikzStyleIntent -> Command
tikzStyleIntentCommand (TikzStyleIntent _ _ _ value) = value

-- | The theme's default notation carried with this intent.
tikzStyleIntentDialect :: TikzStyleIntent -> Dialect
tikzStyleIntentDialect (TikzStyleIntent _ _ value _) = value

-- | Return the exact snapshot represented by an analysis.
tikzAnalysisSnapshot :: TikzAnalysis -> SourceBufferSnapshot
tikzAnalysisSnapshot analysis =
  case analysis of
    TikzAnalysisReady document _ -> documentSourceSnapshot document
    TikzAnalysisSyntaxOnly document _ -> documentSourceSnapshot document

-- | Return the source revision painted by the caller.
tikzMoveIntentRevision :: TikzMoveIntent -> Revision
tikzMoveIntentRevision (TikzMoveIntent value _ _) = value

-- | Return the validated semantic target.
tikzMoveIntentNodeId :: TikzMoveIntent -> NodeId
tikzMoveIntentNodeId (TikzMoveIntent _ value _) = value

-- | Return the validated semantic destination.
tikzMoveIntentDestination :: TikzMoveIntent -> Point
tikzMoveIntentDestination (TikzMoveIntent _ _ value) = value

-- | Return the authoritative revision before the move.
appliedTikzMoveBeforeRevision :: AppliedTikzMove -> Revision
appliedTikzMoveBeforeRevision (AppliedTikzMove value _ _ _) = value

-- | Return the accepted intent.
appliedTikzMoveIntent :: AppliedTikzMove -> TikzMoveIntent
appliedTikzMoveIntent (AppliedTikzMove _ value _ _) = value

-- | Return whether the verified transaction changed source.
appliedTikzMoveOutcome :: AppliedTikzMove -> TikzMoveOutcome
appliedTikzMoveOutcome (AppliedTikzMove _ _ value _) = value

-- | Return the authoritative successor analysis.
appliedTikzMoveAnalysis :: AppliedTikzMove -> TikzAnalysis
appliedTikzMoveAnalysis (AppliedTikzMove _ _ _ value) = value

analyzeDocument :: DocumentSnapshot -> TikzAnalysis
analyzeDocument document =
  case renderDocument document of
    Right plan -> TikzAnalysisReady document plan
    Left (RenderSemanticsUnavailable diagnostics) ->
      TikzAnalysisSyntaxOnly document diagnostics
