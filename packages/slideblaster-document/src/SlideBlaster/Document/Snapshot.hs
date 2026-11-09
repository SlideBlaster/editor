-- |
-- Module      : SlideBlaster.Document.Snapshot
-- Description : Coherent source, syntax, diagnostics, semantics, and provenance.
--
-- Constructors make semantic readiness explicit. Syntax-only snapshots retain
-- exact source and recoverable syntax with at least one diagnostic; ready
-- snapshots carry semantic meaning and its field-grained provenance.
module SlideBlaster.Document.Snapshot
  ( DocumentSnapshot
  , SemanticState (..)
  , documentDiagnostics
  , documentProvenance
  , documentSemantic
  , documentSemanticState
  , documentSource
  , documentSyntax
  , readyDocument
  , syntaxOnlyDocument
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import SlideBlaster.Document.Diagnostic (Diagnostic)
import SlideBlaster.Document.Provenance (ProvenanceMap)
import SlideBlaster.Source (SourceBufferSnapshot)

-- | The semantic state derived from one exact source revision.
data SemanticState key semantic
  = SemanticallyReady !semantic !(ProvenanceMap key)
  | SyntaxOnly !(NonEmpty Diagnostic)
  deriving (Eq, Show)

-- | One coherent source-locked document analysis.
data DocumentSnapshot syntax key semantic
  = ReadyDocument
      !SourceBufferSnapshot
      !syntax
      !semantic
      !(ProvenanceMap key)
      ![Diagnostic]
  | SyntaxOnlyDocument
      !SourceBufferSnapshot
      !syntax
      !(NonEmpty Diagnostic)
  deriving (Eq, Show)

-- | Construct a semantically ready snapshot.
readyDocument
  :: SourceBufferSnapshot
  -> syntax
  -> semantic
  -> ProvenanceMap key
  -> [Diagnostic]
  -> DocumentSnapshot syntax key semantic
readyDocument = ReadyDocument

-- | Construct a syntax-only snapshot with non-empty recovery diagnostics.
syntaxOnlyDocument
  :: SourceBufferSnapshot
  -> syntax
  -> NonEmpty Diagnostic
  -> DocumentSnapshot syntax key semantic
syntaxOnlyDocument = SyntaxOnlyDocument

-- | Return the exact authoritative source buffer.
documentSource :: DocumentSnapshot syntax key semantic -> SourceBufferSnapshot
documentSource document =
  case document of
    ReadyDocument source _ _ _ _ -> source
    SyntaxOnlyDocument source _ _ -> source

-- | Return the recoverable format-specific concrete syntax.
documentSyntax :: DocumentSnapshot syntax key semantic -> syntax
documentSyntax document =
  case document of
    ReadyDocument _ syntax _ _ _ -> syntax
    SyntaxOnlyDocument _ syntax _ -> syntax

-- | Return semantic readiness without exposing snapshot constructors.
documentSemanticState
  :: DocumentSnapshot syntax key semantic
  -> SemanticState key semantic
documentSemanticState document =
  case document of
    ReadyDocument _ _ semantic provenance _ ->
      SemanticallyReady semantic provenance
    SyntaxOnlyDocument _ _ diagnostics ->
      SyntaxOnly diagnostics

-- | Return current semantic meaning when elaboration succeeded.
documentSemantic
  :: DocumentSnapshot syntax key semantic
  -> Maybe semantic
documentSemantic document =
  case document of
    ReadyDocument _ _ semantic _ _ -> Just semantic
    SyntaxOnlyDocument {} -> Nothing

-- | Return field-grained provenance only for current semantic meaning.
documentProvenance
  :: DocumentSnapshot syntax key semantic
  -> Maybe (ProvenanceMap key)
documentProvenance document =
  case document of
    ReadyDocument _ _ _ provenance _ -> Just provenance
    SyntaxOnlyDocument {} -> Nothing

-- | Return all diagnostics attached to the exact revision.
documentDiagnostics
  :: DocumentSnapshot syntax key semantic
  -> [Diagnostic]
documentDiagnostics document =
  case document of
    ReadyDocument _ _ _ _ diagnostics -> diagnostics
    SyntaxOnlyDocument _ _ diagnostics -> NonEmpty.toList diagnostics

