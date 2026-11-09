-- |
-- Module      : SlideBlaster.Engine
-- Description : Public pure engine API shared by native GHC and GHC Wasm.
--
-- The engine admits and inspects exact source snapshots, applies checked
-- byte-local replacements, and composes the bounded TikZ reader/render/edit
-- proof. Filesystem and browser effects remain outside this package.
module SlideBlaster.Engine
  ( module SlideBlaster.Engine.CommonTikz
  , AppliedExactReplacement
  , AppliedTikzMove
  , ExactLocalEditError (..)
  , ExactReplacementReceipt (..)
  , SnapshotInspection (..)
  , TikzAnalysis (..)
  , TikzIntentError (..)
  , TikzMoveIntent
  , TikzMoveOutcome (..)
  , Utf8Status (..)
  , appliedReplacementReceipt
  , appliedReplacementSnapshot
  , appliedTikzMoveAnalysis
  , appliedTikzMoveBeforeRevision
  , appliedTikzMoveIntent
  , appliedTikzMoveOutcome
  , applyExactLocalReplacement
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
  , analyzeTikzSnapshot
  , inspectSnapshot
  , mkTikzMoveIntent
  , tikzAnalysisSnapshot
  , tikzMoveIntentDestination
  , tikzMoveIntentNodeId
  , tikzMoveIntentRevision
  ) where

import SlideBlaster.Engine.CommonTikz
import SlideBlaster.Engine.Edit
import SlideBlaster.Engine.Inspect
import SlideBlaster.Engine.TikZ
