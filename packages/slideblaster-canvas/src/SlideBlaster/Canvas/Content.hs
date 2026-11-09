-- |
-- Module      : SlideBlaster.Canvas.Content
-- Description : Recursive mixed-dialect canvas content with provenance.
--
-- Markdown, LaTeX, and HTML constructs may nest freely. Opaque math retains its
-- literal payload, while unsupported content retains only a typed source handle:
-- exact authored bytes and editability remain owned by the source/CST layer.
module SlideBlaster.Canvas.Content
  ( Dialect (..)
  , Provenance (..)
  , provenanceDialect
  , provenanceOrigin
  , InlineMark (..)
  , ContainerKind (..)
  , ListKind (..)
  , MathKind (..)
  , DerivedFailure (..)
  , DerivedState (..)
  , TableCell (..)
  , TableRow (..)
  , TableModel (..)
  , OverlayDirective (..)
  , ContentOverlayEvent (..)
  , UnsupportedKind (..)
  , SourceBackedContent (..)
  , ContentItem (..)
  , ContentNode (..)
  , Content
  , content
  , emptyContent
  , contentNodes
  , contentOverlayEvents
  ) where

import SlideBlaster.Canvas.Identifier
  ( AssetId
  , CitationKey
  , SourceRef
  )
import SlideBlaster.Canvas.Overlay (OverlayHook, OverlayStep)
import SlideBlaster.Document (Origin)
import SlideBlaster.Listing (Listing)

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Numeric.Natural (Natural)

-- | Surface language that authored one semantic content construct.
data Dialect = Markdown | LaTeX | HTML
  deriving stock (Eq, Ord, Show)

-- | Source ownership is distinct from dialect.
data Provenance
  = AuthoredProvenance !Dialect !Origin
  | CanvasProvenance !Dialect
  deriving stock (Eq, Ord, Show)

provenanceDialect :: Provenance -> Dialect
provenanceDialect provenance =
  case provenance of
    AuthoredProvenance dialect _ -> dialect
    CanvasProvenance dialect -> dialect

provenanceOrigin :: Provenance -> Maybe Origin
provenanceOrigin provenance =
  case provenance of
    AuthoredProvenance _ origin -> Just origin
    CanvasProvenance _ -> Nothing

-- | Semantic inline formatting; provenance lives on the containing run.
data InlineMark
  = Strong
  | Emphasis
  | Underline
  | Strike
  | Highlight
  | InlineCode
  | LinkTarget !Text
  | InlineColour !Text
  deriving stock (Eq, Ord, Show)

-- | Transparent supported container whose children re-enter mixed parsing.
--
-- Flow desugaring ("SlideBlaster.Canvas.Flow") uses these generic names, which
-- are part of its contract: @paragraph@, @quote@, @footnote@, @box-title@,
-- @box-body@, @bibliography@, and @cite:<command>@ for non-default citation
-- commands such as @cite:year@.
data ContainerKind
  = GenericContainer !Text
  | ColumnsContainer
  | MatrixContainer
  | TableContainer
  | -- | @\\sbbox[options]{title}{body}@: the raw option text (possibly empty);
    -- children are a @box-title@ and a @box-body@ container.
    BoxContainer !Text
  | -- | @\\figure[options]{target}@: the raw option text; one figure child.
    FigureContainer !Text
  | -- | One @:::: column <width>@ of a @columns@ container: the raw width text.
    ColumnContainer !Text
  | -- | A heading of the given level.
    HeadingContainer !Int
  deriving stock (Eq, Ord, Show)

data ListKind = UnorderedList | OrderedList
  deriving stock (Eq, Ord, Show)

data MathKind = InlineMath | DisplayMath
  deriving stock (Eq, Ord, Show)

-- | Capability-owned derived values never replace their authored request.
data DerivedState value
  = DerivedUnresolved
  | DerivedLoading
  | DerivedReady !value
  | DerivedFailed !DerivedFailure
  deriving stock (Eq, Ord, Show)

data DerivedFailure
  = DerivedCapabilityUnavailable !Text
  | DerivedInputMissing !Text
  | DerivedInputInvalid !Text
  | DerivedExecutionFailed !Text
  deriving stock (Eq, Ord, Show)

data TableCell = TableCell
  { tableCellColumnSpan :: !Natural
  , tableCellRowSpan :: !Natural
  , tableCellContent :: ![ContentNode]
  }
  deriving stock (Eq, Ord, Show)

newtype TableRow = TableRow (NonEmpty TableCell)
  deriving stock (Eq, Ord, Show)

-- | Rows (the first is the header) and one alignment letter per column
-- (@"l"@, @"c"@, @"r"@, or empty for the default).
data TableModel = TableModel !(NonEmpty TableRow) ![Text]
  deriving stock (Eq, Ord, Show)

-- | Inline overlay pause meaning. 'PauseNext' advances the local step;
-- 'PauseAt' selects an already-normalized explicit step.
data OverlayDirective
  = PauseNext
  | PauseAt !OverlayStep
  deriving stock (Eq, Ord, Show)

-- | Source-order overlay facts derivable from a content tree.
data ContentOverlayEvent
  = ContentOverlayHook !OverlayHook
  | ContentOverlayPause !OverlayDirective
  deriving stock (Eq, Ord, Show)

-- | Stable unsupported category suitable for diagnostics and export policy.
data UnsupportedKind
  = UnsupportedUnsafe
  | UnsupportedSyntax
  | UnsupportedDialectConstruct
  | UnsupportedExternalCapability
  deriving stock (Eq, Ord, Show)

-- | Read-only semantic placeholder backed by exact source held elsewhere.
data SourceBackedContent = SourceBackedContent
  { sourceBackedReference :: !SourceRef
  , sourceBackedDialect :: !Dialect
  , sourceBackedKind :: !UnsupportedKind
  }
  deriving stock (Eq, Ord, Show)

-- | One nested list item.
data ContentItem = ContentItem
  { contentItemProvenance :: !Provenance
  , contentItemBody :: ![ContentNode]
  , contentItemOverlay :: !OverlayHook
  }
  deriving stock (Eq, Ord, Show)

-- | One recursively nested content construct.
data ContentNode
  = TextRun !Provenance !Text
  | StyledRun !Provenance !(NonEmpty InlineMark) ![ContentNode]
  | TransparentContainer !Provenance !ContainerKind ![ContentNode]
  | ListContent !Provenance !ListKind !(NonEmpty ContentItem)
  | OpaqueMath !Provenance !MathKind !Text
  | ImageContent !Provenance !AssetId !Text
  | IncludeContent !Provenance !AssetId !(DerivedState Content)
  | TableContent !Provenance !(DerivedState TableModel)
  | CitationContent
      !Provenance
      !(NonEmpty CitationKey)
      !(DerivedState Content)
  | CompiledFigureContent
      !Provenance
      !SourceRef
      !(DerivedState AssetId)
  | -- | A verbatim code listing with its language and highlight spec.
    CodeContent !Provenance !Listing
  | LineBreak !Provenance
  | OverlayContent !OverlayHook ![ContentNode]
  | OverlayPauseContent !Provenance !OverlayDirective
  | UnsupportedContent !SourceBackedContent
  deriving stock (Eq, Ord, Show)

-- | A node's single content payload. The empty list is an intentional empty box.
newtype Content = Content [ContentNode]
  deriving stock (Eq, Ord, Show)

content :: [ContentNode] -> Content
content = Content

emptyContent :: Content
emptyContent = Content []

contentNodes :: Content -> [ContentNode]
contentNodes (Content nodes) = nodes

-- | Collect all overlay hooks and pauses in semantic reading order.
contentOverlayEvents :: Content -> [ContentOverlayEvent]
contentOverlayEvents (Content nodes) = nodes >>= nodeOverlayEvents

nodeOverlayEvents :: ContentNode -> [ContentOverlayEvent]
nodeOverlayEvents node =
  case node of
    TextRun {} -> []
    StyledRun _ _ children -> children >>= nodeOverlayEvents
    TransparentContainer _ _ children -> children >>= nodeOverlayEvents
    ListContent _ _ items ->
      foldMap itemEvents items
    OpaqueMath {} -> []
    ImageContent {} -> []
    IncludeContent _ _ state -> derivedContentEvents state
    TableContent _ state -> tableStateEvents state
    CitationContent _ _ state -> derivedContentEvents state
    CompiledFigureContent {} -> []
    CodeContent {} -> []
    LineBreak {} -> []
    OverlayContent hook children ->
      ContentOverlayHook hook : (children >>= nodeOverlayEvents)
    OverlayPauseContent _ directive -> [ContentOverlayPause directive]
    UnsupportedContent {} -> []
  where
    itemEvents item =
      ContentOverlayHook (contentItemOverlay item)
        : (contentItemBody item >>= nodeOverlayEvents)
    derivedContentEvents state =
      case state of
        DerivedReady nested -> contentOverlayEvents nested
        DerivedUnresolved -> []
        DerivedLoading -> []
        DerivedFailed _ -> []
    tableStateEvents state =
      case state of
        DerivedReady (TableModel rows _) ->
          foldMap rowEvents rows
        DerivedUnresolved -> []
        DerivedLoading -> []
        DerivedFailed _ -> []
    rowEvents (TableRow cells) =
      foldMap (foldMap nodeOverlayEvents . tableCellContent) cells
