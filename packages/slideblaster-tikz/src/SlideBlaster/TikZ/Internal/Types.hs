{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.TikZ.Internal.Types
-- Description : Concrete, semantic, render, and edit state for the bounded reader.
--
-- Public modules expose validated constructors and abstract document values.
-- Internal syntax and provenance constructors remain package-private so a
-- caller cannot manufacture writable semantics without the authoritative
-- reader.
module SlideBlaster.TikZ.Internal.Types
  ( AnalysisState (..)
  , ConcreteSyntax (..)
  , Connector (..)
  , CoordinateProvenance (..)
  , Diagnostic (..)
  , DiagnosticCategory (..)
  , DiagnosticCode (..)
  , DirectSourceError (..)
  , DocumentSnapshot (..)
  , MoveError (..)
  , MoveNode (..)
  , Node (..)
  , NodeId (..)
  , OpaqueKind (..)
  , OpaqueRegion (..)
  , Picture (..)
  , Point (..)
  , ContentProvenance (..)
  , StyleNode (..)
  , StyleError (..)
  , contentSlotSpan
  , ReadyDocument (..)
  , RenderConnector (..)
  , RenderError (..)
  , RenderNode (..)
  , RenderPlan (..)
  , SemanticState (..)
  , VerificationFailure (..)
  , concreteOpaqueRegions
  , diagnosticCategory
  , diagnosticCode
  , diagnosticMessage
  , diagnosticSpan
  , documentAnalysis
  , documentConcreteSyntax
  , documentDiagnostics
  , documentOpaqueRegions
  , documentPicture
  , documentSemanticState
  , documentSourceSnapshot
  , mkNodeId
  , nodeIdText
  , opaqueKind
  , opaqueSpan
  ) where

import Data.Char (isAsciiLower, isAsciiUpper)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import SlideBlaster.Source
  ( ExactReplacementError
  , Revision
  , SnapshotError
  , SourceBufferSnapshot
  , SourceSpan
  , snapshotRevision
  )
import SlideBlaster.Syntax.Command (Command)
import SlideBlaster.Syntax.Surface (Dialect)
import SlideBlaster.TikZ.Internal.Decimal (Coordinate)
import SlideBlaster.TikZ.NodeContent (NodeContent)

-- | A validated source and render identity.
newtype NodeId = NodeId Text
  deriving (Eq, Ord, Show)

-- | Construct an identity accepted at the source-to-render boundary.
mkNodeId :: Text -> Maybe NodeId
mkNodeId value =
  case Text.uncons value of
    Nothing -> Nothing
    Just (firstCharacter, rest)
      | isIdentifierStart firstCharacter
          && Text.all isIdentifierContinue rest ->
          Just (NodeId value)
      | otherwise -> Nothing

-- | Reveal the validated textual identity.
nodeIdText :: NodeId -> Text
nodeIdText (NodeId value) = value

isIdentifierStart :: Char -> Bool
isIdentifierStart character =
  isAsciiUpper character || isAsciiLower character || character == '_'

isIdentifierContinue :: Char -> Bool
isIdentifierContinue character =
  isIdentifierStart character
    || (character >= '0' && character <= '9')
    || character == '-'

-- | A semantic point in slide coordinates.
data Point = Point !Coordinate !Coordinate
  deriving (Eq, Ord, Show)

-- | One semantic content node.
data Node = Node !NodeId !Point !Text
  deriving (Eq, Show)

-- | One straight connector from the named node to an absolute point.
data Connector = Connector !NodeId !Point
  deriving (Eq, Show)

-- | The complete semantic picture admitted by the literal Slice 1 reader.
data Picture = Picture !Node !Connector
  deriving (Eq, Show)

-- | Stable diagnostic classification.
data DiagnosticCategory
  = DiagnosticMalformed
  | DiagnosticUnsupported
  | DiagnosticAmbiguous
  deriving (Eq, Ord, Show)

-- | Stable diagnostic code within a classification.
data DiagnosticCode
  = ExpectedNodeStatement
  | ExpectedConnectorStatement
  | ExpectedSyntaxToken
  | InvalidNodeIdentifier
  | InvalidConnectorIdentifier
  | InvalidCoordinateToken
  | InvalidUtf8Content
  | NestedNodeContentUnsupported
  | NodeOptionsUnsupported
  | ConnectorOptionsUnsupported
  | ConnectorOperationUnsupported
  | ConnectorTargetUnsupported
  | ExtraConstructUnsupported
  | MultipleConstructsAmbiguous
  | SourceSpanDomainExceeded
  deriving (Eq, Ord, Show)

-- | A source-backed reader diagnostic.
data Diagnostic = Diagnostic
  !DiagnosticCategory
  !DiagnosticCode
  !(Maybe SourceSpan)
  !Text
  deriving (Eq, Show)

-- | Return the broad failure boundary.
diagnosticCategory :: Diagnostic -> DiagnosticCategory
diagnosticCategory (Diagnostic category _ _ _) = category

-- | Return the stable diagnostic identifier.
diagnosticCode :: Diagnostic -> DiagnosticCode
diagnosticCode (Diagnostic _ code _ _) = code

-- | Return a source span when the common native/Wasm offset domain permits it.
diagnosticSpan :: Diagnostic -> Maybe SourceSpan
diagnosticSpan (Diagnostic _ _ spanValue _) = spanValue

-- | Return the human-readable diagnostic.
diagnosticMessage :: Diagnostic -> Text
diagnosticMessage (Diagnostic _ _ _ message) = message

-- | Why bytes have no writable semantic interpretation.
data OpaqueKind
  = OpaqueMalformed
  | OpaqueUnsupported
  | OpaqueAmbiguous
  deriving (Eq, Ord, Show)

-- | A complete source-backed region retained outside the semantic subset.
--
-- A missing span means the source length exceeds the shared portable offset
-- domain; the region still means the complete authoritative source bytes.
data OpaqueRegion = OpaqueRegion !OpaqueKind !(Maybe SourceSpan)
  deriving (Eq, Show)

-- | Return why this region is opaque.
opaqueKind :: OpaqueRegion -> OpaqueKind
opaqueKind (OpaqueRegion kind _) = kind

-- | Return the exact half-open byte range when representable.
opaqueSpan :: OpaqueRegion -> Maybe SourceSpan
opaqueSpan (OpaqueRegion _ spanValue) = spanValue

-- | Span-backed concrete syntax for the supported document or recovered input.
data ConcreteSyntax
  = SupportedConcrete
      !SourceSpan
      !SourceSpan
      !SourceSpan
      !SourceSpan
      !SourceSpan
  | RecoveredConcrete !(NonEmpty OpaqueRegion)
  deriving (Eq, Show)

-- | Return the regions which remain intentionally uninterpreted.
concreteOpaqueRegions :: ConcreteSyntax -> [OpaqueRegion]
concreteOpaqueRegions = \case
  SupportedConcrete {} -> []
  RecoveredConcrete regions -> NonEmpty.toList regions

-- | Provenance controlling the inverse coordinate projection.
data CoordinateProvenance
  = DirectCoordinateSlots !SourceSpan !SourceSpan
  | ReadOnlyCoordinates !Text
  deriving (Eq, Show)

-- | Where a node's content bytes sit in the source.
--
-- Content is delimited by the parser but interpreted by @slideblaster-syntax@, so
-- an edit to it comes back as replacement text for exactly this span. Keeping the
-- span here rather than deriving it later is what lets a content edit be an exact
-- replacement like any other.
newtype ContentProvenance = DirectContentSlot SourceSpan
  deriving (Eq, Show)

contentSlotSpan :: ContentProvenance -> SourceSpan
contentSlotSpan (DirectContentSlot value) = value

-- | A successful semantic analysis paired with its field-level provenance.
data ReadyDocument
  = ReadyDocument !Picture !CoordinateProvenance !ContentProvenance
  deriving (Eq, Show)

-- | Semantic analysis for the exact source revision.
data AnalysisState
  = AnalysisReady !ReadyDocument
  | AnalysisUnavailable !(NonEmpty Diagnostic)
  deriving (Eq, Show)

-- | One coherent exact-source, syntax, analysis, provenance, and diagnostic value.
data DocumentSnapshot = DocumentSnapshot
  !SourceBufferSnapshot
  !ConcreteSyntax
  !AnalysisState
  deriving (Eq)

instance Show DocumentSnapshot where
  show document =
    "DocumentSnapshot {revision = "
      <> show (snapshotRevision (documentSourceSnapshot document))
      <> ", semanticState = "
      <> case documentAnalysis document of
        AnalysisReady {} -> "ready}"
        AnalysisUnavailable diagnostics ->
          "syntax-only, diagnosticCount = "
            <> show (NonEmpty.length diagnostics)
            <> "}"

-- | Public view of semantic availability.
data SemanticState
  = SemanticallyReady !Picture
  | SyntaxOnly !(NonEmpty Diagnostic)
  deriving (Eq, Show)

-- | Return the authoritative exact source value.
documentSourceSnapshot :: DocumentSnapshot -> SourceBufferSnapshot
documentSourceSnapshot (DocumentSnapshot source _ _) = source

-- | Return the span-backed concrete state.
documentConcreteSyntax :: DocumentSnapshot -> ConcreteSyntax
documentConcreteSyntax (DocumentSnapshot _ syntax _) = syntax

-- | Return the internal semantic/provenance state.
documentAnalysis :: DocumentSnapshot -> AnalysisState
documentAnalysis (DocumentSnapshot _ _ analysis) = analysis

-- | Return all reader diagnostics for this revision.
documentDiagnostics :: DocumentSnapshot -> [Diagnostic]
documentDiagnostics document =
  case documentAnalysis document of
    AnalysisReady {} -> []
    AnalysisUnavailable diagnostics -> NonEmpty.toList diagnostics

-- | Return the public semantic availability.
documentSemanticState :: DocumentSnapshot -> SemanticState
documentSemanticState document =
  case documentAnalysis document of
    AnalysisReady (ReadyDocument picture _ _) -> SemanticallyReady picture
    AnalysisUnavailable diagnostics -> SyntaxOnly diagnostics

-- | Return the current picture only when elaboration succeeded.
documentPicture :: DocumentSnapshot -> Maybe Picture
documentPicture document =
  case documentAnalysis document of
    AnalysisReady (ReadyDocument picture _ _) -> Just picture
    AnalysisUnavailable {} -> Nothing

-- | Return all exact-source regions without writable semantics.
documentOpaqueRegions :: DocumentSnapshot -> [OpaqueRegion]
documentOpaqueRegions =
  concreteOpaqueRegions . documentConcreteSyntax

-- | Failure to admit a direct authored-source replacement.
data DirectSourceError
  = DirectSourceStale !Revision !Revision
  | DirectSourceAdvanceFailed !SnapshotError
  deriving (Eq, Show)

-- | A revision-fenced semantic node-move request.
data MoveNode = MoveNode !Revision !NodeId !Point
  deriving (Eq, Show)

-- | One request to change a style property of a node's content.
--
-- The command is the syntax package's own, so this boundary adds a revision fence
-- and a target and nothing else. What an edit may do is decided where the tree is
-- understood, not here.
-- | A style change asked of one node's content.
--
-- The 'Dialect' is the theme's default notation, not a claim about the file.
-- Authored content is one mixed language with no outermost notation, so it is used
-- only where neither an enclosing construct nor the content being wrapped settles
-- which notation a new construct should be written in.
data StyleNode = StyleNode !Revision !NodeId !Dialect !Command
  deriving (Eq, Show)

-- | Failure of the atomic content style transaction.
data StyleError
  = StyleStale !Revision !Revision
  | StyleSemanticsUnavailable
  | StyleTargetMissing !NodeId
  | -- | The content is outside the readable subset, so it has no structure to
    -- address. Carries the reader's explanation.
    StyleContentUnreadable !Text
  | -- | The command itself was refused, with the reason from the syntax package.
    StyleRefused !Text
  | StyleSourceCheckFailed !ExactReplacementError
  | -- | The patched source did not reparse to the intended meaning, so nothing was
    -- committed.
    StyleVerificationFailed
  deriving (Eq, Show)

-- | A stable semantic verification failure.
data VerificationFailure
  = VerificationParseOrElaborationFailed
  | VerificationSemanticMismatch
  deriving (Eq, Show)

-- | Failure of the atomic provenance-guided move transaction.
data MoveError
  = MoveStale !Revision !Revision
  | MoveSemanticsUnavailable
  | MoveTargetMissing !NodeId
  | MoveTargetAmbiguous !NodeId
  | MoveProjectionUnsupported !NodeId
  | MoveSourceCheckFailed !ExactReplacementError
  | MoveVerificationFailed !VerificationFailure
  deriving (Eq, Show)

-- | One positioned node instruction.
--
-- Carries both the exact authored content and its interpretation. The text is
-- kept because it is the authority; the interpretation is kept because the
-- renderer cannot derive it and must not try.
data RenderNode = RenderNode !NodeId !Point !Text !NodeContent
  deriving (Eq, Show)

-- | One straight renderer-neutral connector instruction.
data RenderConnector = RenderConnector !Point !Point
  deriving (Eq, Show)

-- | The complete minimal drawing plan.
data RenderPlan = RenderPlan !RenderNode !RenderConnector
  deriving (Eq, Show)

-- | Why no plan can be derived for this exact source revision.
data RenderError
  = RenderSemanticsUnavailable !(NonEmpty Diagnostic)
  deriving (Eq, Show)
