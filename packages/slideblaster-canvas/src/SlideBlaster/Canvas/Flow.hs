{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Canvas.Flow
-- Description : Flow-body desugaring: syntax blocks to canvas content and region nodes.
--
-- The flow tier of a slide is Markdown blocks over mixed-dialect inline content
-- ("SlideBlaster.Syntax.Block"). This module gives it canvas meaning:
--
-- * 'lowerFlow' turns a 'Flow' into 'Canvas.Content.Content' (paragraphs, lists,
--   boxes, columns, figures, code, tables, citations, overlay content), reporting
--   every unsupported or unknown construct as a 'FlowDiagnostic' and keeping it
--   as 'UnsupportedContent' (decision D8: retained, labelled, never blocking).
-- * 'regionNodes' places that content as theme-region nodes (@flow-title@,
--   @flow-body@, ...) with generated placement, so a theme change moves content
--   without touching authored coordinates (decision D3).
-- * 'pictureEntries' lowers the @```slide@ picture tier to absolutely placed
--   nodes layered above the flow nodes.
--
-- == Macros
--
-- Content is expanded before lowering with a prelude of definitions in scope
-- ('FlowContext'), so @\\begin{block}{T}..\\end{block}@ lowers exactly as
-- @\\sbbox[..]{T}{..}@ (decision D4). Expansion is a derived view; the authored
-- text is untouched.
--
-- == Overlays
--
-- @\\only\<s>{..}@, @\\uncover@, @\\onslide@, @\\visible@ and trailing @\<s>@ on a
-- list item or macro use become 'OverlayContent' / 'contentItemOverlay' hooks;
-- @\\pause@ becomes 'OverlayPauseContent'. The presentation layer derives beats
-- from these alone. Incremental specs (@+@, @.@) and @\\invisible@ are reported
-- and treated as always visible.
--
-- == Resources
--
-- Figures and images cannot carry file paths in a content node (identifiers are
-- restricted), so each gets a deterministic handle (@\<prefix>-figure-1@) and a
-- 'FlowResource' recording the target and options, in reading order.
module SlideBlaster.Canvas.Flow
  ( -- * Lowering
    FlowContext (..)
  , LoweredFlow (..)
  , lowerFlow
  , lowerInlineText
  , defaultPrelude
  , parsePrelude

    -- * Diagnostics and resources
  , FlowDiagnostic (..)
  , DiagnosticLevel (..)
  , FlowResource (..)
  , ResourceKind (..)

    -- * Overlay hooks
  , specHook

    -- * Region nodes and picture tier
  , Region (..)
  , slideSizeFor
  , regionNodes
  , contentPlainText
  , pictureEntries
  , PictureItem (..)
  , PictureEndpoint (..)
  , pictureItems
  ) where

import SlideBlaster.Canvas.Content
import SlideBlaster.Canvas.Geometry
  ( BorderPort (..)
  , Size
  , canvasUnit
  , fractionValue
  , mkSize
  , point
  , relativeRectBottom
  , relativeRectHeight
  , relativeRectLeft
  , relativeRectWidth
  , sizeHeight
  , sizeWidth
  , canvasUnitValue
  )
import SlideBlaster.Canvas.Identifier
  ( NodeId
  , RoleId
  , assetId
  , barrierId
  , citationKey
  , nodeId
  , roleId
  , sourceRef
  )
import SlideBlaster.Canvas.Object
  ( CanvasObject (CanvasNode)
  , LayerBarrier (OpaqueStatementBarrier)
  , LayerEntry (BarrierEntry, ObjectEntry)
  , NodeAccessibility (DecorativeNode)
  )
import SlideBlaster.Canvas.Object qualified as Object
import SlideBlaster.Canvas.Outline (OutlineRef (PrimitiveGeometry), PrimitiveOutline (RectangleOutline))
import SlideBlaster.Canvas.Overlay
  ( OverlayHook (AlwaysVisible, VisibleDuring)
  , StepRange
  , mkOverlayStep
  , singleStep
  , stepsBetween
  , stepsFrom
  , stepsThrough
  )
import SlideBlaster.Canvas.Placement (Placement (AbsolutePlacement, GeneratedPlacement))
import SlideBlaster.Canvas.Property
  ( NodePropertyPatch (nodePatchOverlay, nodePatchRole, nodePatchSizing)
  , Sizing (FixedSize)
  , emptyNodePropertyPatch
  )
import SlideBlaster.Canvas.Theme
  ( MasterRegion (masterRegionName, masterRegionRect)
  , Theme (themeMasterLayout, themeStyle)
  , ThemeStyle (themeNodeRoles)
  , masterRegions
  )
import SlideBlaster.Document (Origin)
import SlideBlaster.Listing (mkListing)
import SlideBlaster.Syntax.Ast
  ( ArgumentF (Angle, Mandatory, Optional)
  , BreakKind (HardBreak, SoftBreak, ThematicBreak)
  , ItemF (ItemF)
  , ListKind (Described, Ordered, Unordered)
  , MacroName (MacroName)
  , MathForm (DisplayBracket, DisplayDoubleDollar, InlineDollar, InlineParen)
  , NodeF (..)
  , nodeDialect
  )
import SlideBlaster.Syntax.Ast qualified as Ast
import SlideBlaster.Syntax.Block qualified as Block
import SlideBlaster.Syntax.Expand (expandTexWith, expandedView)
import SlideBlaster.Syntax.Fix (unFix)
import SlideBlaster.Syntax.Overlay
  ( OverlaySpec
  , SpecError (..)
  , SpecRange (..)
  , parseOverlaySpec
  , specRanges
  )
import SlideBlaster.Syntax.Picture (Statement (NodeStatement, OpaqueStatement), optionPairs, readPicture)
import SlideBlaster.Syntax.Printer (printColourExpr, printNodes)
import SlideBlaster.Syntax.Style
  ( Family (Monospace)
  , Slant (Italic)
  , StyleValue (..)
  , Weight (Bold)
  , styleMapToList
  )
import SlideBlaster.Syntax.Surface qualified as Surface
import SlideBlaster.Syntax.Surface (MdSpelling (MdInlineLink), Surface (MarkdownSurface), linkTarget)
import SlideBlaster.Syntax.Tex.Reader (readTex)

import Data.Char (isAlphaNum, isSpace)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Numeric.Natural (Natural)

type SynNode = Ast.Node

------------------------------------------------------------------------------
-- Public types

-- | What lowering needs besides the flow itself.
data FlowContext = FlowContext
  { contextOrigin :: !Origin
  -- ^ Provenance attached to every lowered construct: the flow's source span.
  , contextPrelude :: ![SynNode]
  -- ^ Definitions in scope: the theme prelude, then the deck @preamble@.
  , contextHandlePrefix :: !Text
  -- ^ Prefix of resource handles, normally the slide id.
  }

-- | Result of lowering one flow.
data LoweredFlow = LoweredFlow
  { loweredContent :: !Content
  , loweredDiagnostics :: ![FlowDiagnostic]
  , loweredResources :: ![FlowResource]
  }
  deriving stock (Eq, Show)

-- | Severity of a flow diagnostic. None of these block saving (decision D8).
data DiagnosticLevel = LevelInfo | LevelWarning
  deriving stock (Eq, Ord, Show)

-- | A located lowering problem. The line is one-based within the flow text.
data FlowDiagnostic = FlowDiagnostic
  { flowDiagnosticLevel :: !DiagnosticLevel
  , flowDiagnosticCode :: !Text
  , flowDiagnosticMessage :: !Text
  , flowDiagnosticLine :: !Int
  , flowDiagnosticColumn :: !Int
  }
  deriving stock (Eq, Show)

-- | What a resource handle refers to.
data ResourceKind = TikzFile | TikzInline | ImageFile
  deriving stock (Eq, Show)

-- | A figure or image referenced by a content handle, in reading order.
data FlowResource = FlowResource
  { resourceHandle :: !Text
  , resourceKind :: !ResourceKind
  , resourceTarget :: !Text
  -- ^ The path (files) or the inline TikZ source.
  , resourceOptions :: !Text
  -- ^ Raw @[..]@ option text, possibly empty.
  , resourceLine :: !Int
  }
  deriving stock (Eq, Show)

------------------------------------------------------------------------------
-- Prelude

-- | The built-in theme prelude: ordinary user-writable definitions (decision D4).
defaultPrelude :: Text
defaultPrelude =
  Text.unlines
    [ "\\newenvironment{block}[1]{\\sbbox[fill=theme.block.bg, title fill=theme.block.title]{#1}\\bgroup}{\\egroup}"
    , "\\newenvironment{alertblock}[1]{\\sbbox[fill=theme.alert.bg, title fill=theme.alert.title]{#1}\\bgroup}{\\egroup}"
    , "\\newcommand{\\defn}[2]{\\sbbox[fill=palBlue!10, title fill=palBlue]{Definition: #1}{#2}}"
    , "\\newcommand{\\lemma}[1]{\\sbbox[fill=palGreen!10, title fill=palGreen]{Lemma}{#1}}"
    ]

-- | Read a prelude text; a text that does not read yields no definitions and a
-- diagnostic.
parsePrelude :: Text -> ([SynNode], [FlowDiagnostic])
parsePrelude text =
  case readTex text of
    Right nodes -> (nodes, [])
    Left failure ->
      ( []
      , [FlowDiagnostic LevelWarning "prelude.malformed" ("preamble does not read as TeX: " <> Text.pack (show failure)) 1 1]
      )

------------------------------------------------------------------------------
-- Lowering monad

data State' = State'
  { sDiagnostics :: ![FlowDiagnostic]
  , sResources :: ![FlowResource]
  , sFigures :: !Int
  , sImages :: !Int
  , sUnsupported :: !Int
  }

newtype L a = L (State' -> (a, State'))

instance Functor L where
  fmap f (L g) = L (\s -> let (a, s') = g s in (f a, s'))

instance Applicative L where
  pure a = L (\s -> (a, s))
  L f <*> L g = L (\s -> let (h, s1) = f s; (a, s2) = g s1 in (h a, s2))

instance Monad L where
  L g >>= f = L (\s -> let (a, s1) = g s; L h = f a in h s1)

runL :: L a -> (a, State')
runL (L g) = g (State' [] [] 0 0 0)

report :: Ctx -> DiagnosticLevel -> Text -> Text -> L ()
report ctx level code message =
  L (\s -> ((), s {sDiagnostics = FlowDiagnostic level code message (ctxLine ctx) 1 : sDiagnostics s}))

nextCounter :: (State' -> Int) -> (State' -> Int -> State') -> L Int
nextCounter get set = L (\s -> let n = get s + 1 in (n, set s n))

recordResource :: FlowResource -> L ()
recordResource r = L (\s -> ((), s {sResources = r : sResources s}))

data Ctx = Ctx
  { ctxFlow :: !FlowContext
  , ctxLine :: !Int
  }

provenance :: Ctx -> Dialect -> Provenance
provenance ctx dialect = AuthoredProvenance dialect (contextOrigin (ctxFlow ctx))

-- | The canvas dialect of a syntax node; nodes that commit to no notation are
-- LaTeX, the format's default.
dialectOfNode :: SynNode -> Dialect
dialectOfNode n =
  case nodeDialect (unFix n) of
    Just Surface.Tex -> LaTeX
    Just Surface.Html -> HTML
    Just Surface.Markdown -> Markdown
    Nothing -> LaTeX

------------------------------------------------------------------------------
-- Entry points

-- | Lower a flow body (a slide body or a note).
lowerFlow :: FlowContext -> Block.Flow -> LoweredFlow
lowerFlow context flow =
  let (nodes, final) = runL (lowerBlocks (Ctx context 1) (Block.flowBlocks flow))
      structural = fmap issueDiagnostic (Block.flowIssues flow)
   in LoweredFlow
        { loweredContent = content (trimNodes nodes)
        , loweredDiagnostics = structural <> reverse (sDiagnostics final)
        , loweredResources = reverse (sResources final)
        }

-- | Lower one line of inline content (a title, an author list).
lowerInlineText :: FlowContext -> Text -> LoweredFlow
lowerInlineText context text =
  let prose = Block.readProse text
      (nodes, final) = runL (lowerProse (Ctx context 1) prose)
   in LoweredFlow
        { loweredContent = content (trimNodes nodes)
        , loweredDiagnostics =
            maybe [] (\e -> [issueDiagnostic (Block.FlowIssue Block.IssueMalformedInline 1 1 (Text.pack (show e)))]) (Block.proseError prose)
              <> reverse (sDiagnostics final)
        , loweredResources = reverse (sResources final)
        }

issueDiagnostic :: Block.FlowIssue -> FlowDiagnostic
issueDiagnostic issue =
  FlowDiagnostic
    { flowDiagnosticLevel =
        case Block.issueKind issue of
          Block.IssueStrayContainerClose -> LevelInfo
          _ -> LevelWarning
    , flowDiagnosticCode =
        case Block.issueKind issue of
          Block.IssueMalformedInline -> "syntax.malformed-inline"
          Block.IssueUnclosedFence -> "syntax.unclosed-fence"
          Block.IssueUnclosedContainer -> "syntax.unclosed-container"
          Block.IssueStrayContainerClose -> "syntax.stray-container-close"
    , flowDiagnosticMessage = Block.issueMessage issue
    , flowDiagnosticLine = Block.issueLine issue
    , flowDiagnosticColumn = Block.issueColumn issue
    }

------------------------------------------------------------------------------
-- Blocks

lowerBlocks :: Ctx -> [Block.Block] -> L [ContentNode]
lowerBlocks _ [] = pure []
lowerBlocks ctx (block : rest) = do
  here <- lowerBlock ctx block
  let advanced = ctx {ctxLine = ctxLine ctx + Text.count "\n" (Block.printBlock block)}
  later <- lowerBlocks advanced rest
  pure (here <> later)

lowerBlock :: Ctx -> Block.Block -> L [ContentNode]
lowerBlock ctx block =
  case block of
    Block.GapBlock _ -> pure []
    Block.ParagraphBlock prose -> do
      inner <- lowerProse ctx prose
      pure [paragraph ctx inner | not (null (trimNodes inner))]
    Block.HeadingBlock prefix prose -> do
      inner <- lowerProse ctx prose
      let level = Text.length (Text.takeWhile (== '#') (Text.stripStart prefix))
      pure [TransparentContainer (provenance ctx Markdown) (HeadingContainer level) (trimNodes inner)]
    Block.ListBlock items -> lowerList ctx items
    Block.QuoteBlock _ inner -> do
      kids <- lowerBlocks ctx inner
      pure [TransparentContainer (provenance ctx Markdown) (GenericContainer "quote") kids]
    Block.FenceBlock fence -> lowerFence ctx fence
    Block.ContainerBlock container -> lowerContainer ctx container
    Block.TableBlock rows -> lowerTable ctx rows
    Block.StrayBlock _ -> pure []

paragraph :: Ctx -> [ContentNode] -> ContentNode
paragraph ctx inner =
  TransparentContainer (provenance ctx LaTeX) (GenericContainer "paragraph") (trimNodes inner)

-- | Lower inline prose; a prose that failed to read is retained as unsupported.
lowerProse :: Ctx -> Block.Prose -> L [ContentNode]
lowerProse ctx prose =
  case Block.proseError prose of
    Just _ -> do
      node' <- unsupported ctx LaTeX UnsupportedSyntax
      pure [node']
    Nothing -> lowerNodes ctx (Block.proseNodes prose)

lowerList :: Ctx -> [Block.ListItem] -> L [ContentNode]
lowerList _ [] = pure []
lowerList ctx items@(first : _) = do
  contentItems <- traverse (lowerItem ctx) items
  case NonEmpty.nonEmpty contentItems of
    Nothing -> pure []
    Just neItems ->
      pure
        [ ListContent
            (provenance ctx Markdown)
            (if Block.itemKind first == Ordered then OrderedList else UnorderedList)
            neItems
        ]

lowerItem :: Ctx -> Block.ListItem -> L ContentItem
lowerItem ctx item = do
  let nodes = Block.proseNodes (Block.itemProse item)
  (hook, rest) <- itemOverlay ctx nodes
  body <-
    case Block.proseError (Block.itemProse item) of
      Just _ -> (: []) <$> unsupported ctx LaTeX UnsupportedSyntax
      Nothing -> lowerNodes ctx rest
  nested <- lowerList ctx (Block.itemNested item)
  pure
    ContentItem
      { contentItemProvenance = provenance ctx Markdown
      , contentItemBody = trimNodes body <> nested
      , contentItemOverlay = hook
      }

-- | Split an item's overlay specification, leading (@\\item\<2->@) or trailing
-- (Markdown @- text \<2->@), from its content.
itemOverlay :: Ctx -> [SynNode] -> L (OverlayHook, [SynNode])
itemOverlay ctx nodes =
  case dropWhile isBlankNode nodes of
    first : after
      | Overlay spec <- unFix first -> do
          hook <- hookFor ctx spec
          pure (hook, after)
    _ ->
      case reverse (dropWhile isBlankNode (reverse nodes)) of
        [] -> pure (AlwaysVisible, nodes)
        trimmed ->
          case reverse trimmed of
            lastNode : beforeRev
              | Overlay spec <- unFix lastNode -> do
                  hook <- hookFor ctx spec
                  pure (hook, reverse beforeRev)
            _ -> pure (AlwaysVisible, nodes)

isBlankNode :: SynNode -> Bool
isBlankNode n =
  case unFix n of
    Whitespace _ -> True
    _ -> False

hookFor :: Ctx -> Text -> L OverlayHook
hookFor ctx spec =
  case parseOverlaySpec spec of
    Right parsed ->
      case specHook parsed of
        Just hook -> pure hook
        Nothing -> report ctx LevelWarning "overlay.invalid-step" ("overlay specification <" <> spec <> "> has an invalid step") >> pure AlwaysVisible
    Left (SpecIncremental _) ->
      report ctx LevelInfo "overlay.incremental" ("incremental overlay specification <" <> spec <> "> is not evaluated; shown always") >> pure AlwaysVisible
    Left failure ->
      report ctx LevelWarning "overlay.malformed" ("malformed overlay specification <" <> spec <> ">: " <> Text.pack (show failure)) >> pure AlwaysVisible

-- | A validated specification as a canvas visibility hook.
specHook :: OverlaySpec -> Maybe OverlayHook
specHook spec = VisibleDuring <$> traverse range (specRanges spec)
  where
    step = mkOverlayStep
    range :: SpecRange -> Maybe StepRange
    range r =
      case r of
        SpecAt n -> singleStep <$> step n
        SpecFrom n -> stepsFrom <$> step n
        SpecThrough n -> stepsThrough <$> step n
        SpecBetween n m -> do
          low <- step n
          high <- step m
          stepsBetween low high

lowerFence :: Ctx -> Block.Fence -> L [ContentNode]
lowerFence ctx fence =
  let info = Block.fenceInfo fence
      language = Block.fenceLanguage info
   in case language of
        "slide" -> pure []
        "notes" -> pure []
        "tikz" -> do
          handle <- figureHandle ctx
          recordResource (FlowResource handle TikzInline (Block.fenceBody fence) "" (ctxLine ctx))
          pure (figureNode ctx "" handle)
        _ ->
          case mkListing language (Block.fenceBody fence) (Block.fenceHighlight info) False of
            Right listing -> pure [CodeContent (provenance ctx Markdown) listing]
            Left failure -> do
              report ctx LevelWarning "listing.highlight" ("invalid highlight specification: " <> Text.pack (show failure))
              case mkListing language (Block.fenceBody fence) Nothing False of
                Right listing -> pure [CodeContent (provenance ctx Markdown) listing]
                Left _ -> (: []) <$> unsupported ctx Markdown UnsupportedSyntax

figureHandle :: Ctx -> L Text
figureHandle ctx = do
  n <- nextCounter sFigures (\s v -> s {sFigures = v})
  pure (contextHandlePrefix (ctxFlow ctx) <> "-figure-" <> Text.pack (show n))

imageHandle :: Ctx -> L Text
imageHandle ctx = do
  n <- nextCounter sImages (\s v -> s {sImages = v})
  pure (contextHandlePrefix (ctxFlow ctx) <> "-image-" <> Text.pack (show n))

figureNode :: Ctx -> Text -> Text -> [ContentNode]
figureNode ctx options handle =
  case sourceRef handle of
    Just ref ->
      [ TransparentContainer
          (provenance ctx LaTeX)
          (FigureContainer options)
          [CompiledFigureContent (provenance ctx LaTeX) ref DerivedUnresolved]
      ]
    Nothing -> []

lowerContainer :: Ctx -> Block.Container -> L [ContentNode]
lowerContainer ctx container = do
  let ContainerHeadView name arguments = headView container
  kids <- lowerBlocks ctx {ctxLine = ctxLine ctx + 1} (Block.containerBody container)
  case name of
    "columns" -> pure [TransparentContainer (provenance ctx Markdown) ColumnsContainer kids]
    "column" -> pure [TransparentContainer (provenance ctx Markdown) (ColumnContainer arguments) kids]
    _ -> do
      report ctx LevelInfo "container.unknown" ("unknown container ::: " <> name <> "; its content is shown")
      pure [TransparentContainer (provenance ctx Markdown) (GenericContainer name) kids]

data ContainerHeadView = ContainerHeadView !Text !Text

headView :: Block.Container -> ContainerHeadView
headView container =
  let h = Block.containerHead container
   in ContainerHeadView (Block.containerName h) (Block.containerArguments h)

lowerTable :: Ctx -> [Text] -> L [ContentNode]
lowerTable ctx rows = do
  let dataRows = [row | (index, row) <- zip [0 :: Int ..] rows, index /= 1]
  rowModels <- traverse lowerRow dataRows
  case NonEmpty.nonEmpty (mapMaybe id rowModels) of
    Just neRows -> pure [TableContent (provenance ctx Markdown) (DerivedReady (TableModel neRows aligns))]
    Nothing -> (: []) <$> unsupported ctx Markdown UnsupportedSyntax
  where
    aligns = fmap alignLetter (Block.tableAlignments rows)
    alignLetter a = case a of
      Block.AlignLeft -> "l"
      Block.AlignCentre -> "c"
      Block.AlignRight -> "r"
      Block.AlignDefault -> ""
    lowerRow line = do
      cells <- traverse lowerCell (Block.tableCells line)
      pure (TableRow <$> NonEmpty.nonEmpty cells)
    lowerCell raw = do
      inner <- lowerProse ctx (Block.readProse (Text.strip raw))
      pure (TableCell 1 1 (trimNodes inner))

------------------------------------------------------------------------------
-- Inline content

-- | Expand with the prelude, then lower.
lowerNodes :: Ctx -> [SynNode] -> L [ContentNode]
lowerNodes ctx nodes =
  case expandTexWith (contextPrelude (ctxFlow ctx)) nodes of
    Right expanded -> lowerSeq ctx (expandedView expanded)
    Left failure -> do
      report ctx LevelWarning "macro.expansion" ("macro expansion failed: " <> Text.pack (show failure))
      lowerSeq ctx nodes

-- | Lower a sibling run, binding stand-alone overlay specs to the preceding
-- construct and merging adjacent text.
lowerSeq :: Ctx -> [SynNode] -> L [ContentNode]
lowerSeq ctx = go []
  where
    go acc [] = pure (coalesce (reverse acc))
    go acc (current : rest) =
      case unFix current of
        Overlay spec -> do
          hook <- hookFor ctx spec
          case splitLastContent acc of
            Just (previous, before) -> go (OverlayContent hook [previous] : before) rest
            Nothing -> do
              report ctx LevelWarning "overlay.dangling" ("overlay <" <> spec <> "> follows nothing")
              go acc rest
        Text _ _
          | Just (alt, target, after) <- imageAfter current rest -> do
              image <- lowerImage ctx alt target
              go (reverse image <> acc) after
        _ -> do
          produced <- lowerOne ctx current
          go (reverse produced <> acc) rest
    -- Text ending in '!' followed by a Markdown inline link is an image.
    imageAfter current rest =
      case (unFix current, rest) of
        (Text _ t, linked : after)
          | "!" `Text.isSuffixOf` t
          , Linked surface kids <- unFix linked
          , MarkdownSurface (MdInlineLink target) <- surface
          , Just _ <- linkTarget surface ->
              Just (printNodes kids, target, after)
        _ -> Nothing

-- | The last non-blank content node and the accumulator without it. Blank text
-- between that node and the end stays after it, so order is preserved.
splitLastContent :: [ContentNode] -> Maybe (ContentNode, [ContentNode])
splitLastContent acc =
  case acc of
    [] -> Nothing
    blank@(TextRun _ t) : more
      | Text.all isSpace t ->
          case splitLastContent more of
            Just (previous, before) -> Just (previous, blank : before)
            Nothing -> Nothing
    previous : more -> Just (previous, more)

lowerImage :: Ctx -> Text -> Text -> L [ContentNode]
lowerImage ctx alt target = do
  let path = Text.strip (Text.takeWhile (not . isSpace) (Text.strip target))
  handle <- imageHandle ctx
  if isTikzPath path
    then do
      recordResource (FlowResource handle TikzFile path "" (ctxLine ctx))
      pure (figureNode ctx "" handle)
    else do
      recordResource (FlowResource handle ImageFile path "" (ctxLine ctx))
      case assetId handle of
        Just asset -> pure [ImageContent (provenance ctx Markdown) asset alt]
        Nothing -> (: []) <$> unsupported ctx Markdown UnsupportedSyntax

isTikzPath :: Text -> Bool
isTikzPath path = any (`Text.isSuffixOf` Text.toLower path) [".tikz", ".tex"]

lowerOne :: Ctx -> SynNode -> L [ContentNode]
lowerOne ctx current =
  case unFix current of
    Text _ value -> pure [TextRun (prov current) value]
    Whitespace value -> pure [TextRun (provenance ctx LaTeX) value]
    Comment _ _ -> pure []
    Run _ kids -> lowerSeq ctx kids
    Styled facts _ kids -> do
      inner <- lowerSeq ctx kids
      pure $
        case NonEmpty.nonEmpty (concatMap mark (styleMapToList facts)) of
          Just marks -> [StyledRun (prov current) marks inner]
          Nothing -> inner
    Items kind _ _ items -> do
      contentItems <- traverse itemFromAst items
      pure
        [ ListContent (provenance ctx LaTeX) (listKind kind) neItems
        | Just neItems <- [NonEmpty.nonEmpty contentItems]
        ]
    Heading level _ kids -> do
      inner <- lowerSeq ctx kids
      pure [TransparentContainer (prov current) (HeadingContainer level) inner]
    Quote _ kids -> do
      inner <- lowerSeq ctx kids
      pure [TransparentContainer (prov current) (GenericContainer "quote") inner]
    Verbatim surface value ->
      pure $
        case surface of
          MarkdownSurface _ -> [StyledRun (prov current) (InlineCode :| []) [TextRun (prov current) value]]
          _ -> [TextRun (prov current) value]
    Linked surface kids -> do
      inner <- lowerSeq ctx kids
      pure $
        case linkTarget surface of
          Just target -> [StyledRun (prov current) (LinkTarget target :| []) inner]
          Nothing -> inner
    Break kind _ ->
      pure $
        case kind of
          HardBreak -> [LineBreak (prov current)]
          SoftBreak -> [TextRun (prov current) " "]
          ThematicBreak -> [LineBreak (prov current)]
    Foreign _ _ -> (: []) <$> unsupported ctx (dialectOfNode current) UnsupportedSyntax
    Math form payload ->
      pure [OpaqueMath (provenance ctx LaTeX) (mathKind form) payload]
    Define _ -> pure []
    MacroUse (Just expansion) _ _ -> lowerSeq ctx expansion
    MacroUse Nothing (MacroName name) _ -> unknownCommand name
    Environment (Just expansion) _ _ -> lowerSeq ctx expansion
    Environment Nothing name body -> lowerEnvironment name body
    Unresolved (MacroName name) args -> lowerCommand ctx current name args
    Parameter _ -> pure []
    Alignment -> pure [TextRun (provenance ctx LaTeX) "&"]
    Overlay _ -> pure []
  where
    prov n = provenance ctx (dialectOfNode n)
    mark value =
      case value of
        SetWeight Bold -> [Strong]
        SetSlant Italic -> [Emphasis]
        SetUnderline True -> [Underline]
        SetStrike True -> [Strike]
        SetHighlight True -> [Highlight]
        SetFamily Monospace -> [InlineCode]
        SetForeground colour -> [InlineColour (printColourExpr colour)]
        _ -> []
    listKind kind =
      case kind of
        Ordered -> OrderedList
        Unordered -> UnorderedList
        Described -> UnorderedList
    itemFromAst (ItemF _ _ body) = do
      (hook, rest) <- itemOverlay ctx body
      inner <- lowerSeq ctx rest
      pure ContentItem {contentItemProvenance = provenance ctx LaTeX, contentItemBody = trimNodes inner, contentItemOverlay = hook}
    unknownCommand name = do
      report ctx LevelInfo "command.unknown" ("unknown command \\" <> name <> "; kept as an opaque region")
      (: []) <$> unsupported ctx LaTeX UnsupportedSyntax
    lowerEnvironment name body
      | name `elem` ["lstlisting", "verbatim", "Verbatim", "minted"] =
          let raw = printNodes body
              (header, code) = splitListingHeader raw
           in case mkListing (listingLanguage' header) code Nothing False of
                Right listing -> pure [CodeContent (provenance ctx LaTeX) listing]
                Left _ -> (: []) <$> unsupported ctx LaTeX UnsupportedSyntax
      | otherwise = do
          report ctx LevelInfo "environment.unknown" ("unknown environment " <> name <> "; its content is shown")
          inner <- lowerSeq ctx body
          pure [TransparentContainer (provenance ctx LaTeX) (GenericContainer name) inner]

-- | The @[language=P4]@ header of a listing environment and the code after it.
splitListingHeader :: Text -> (Text, Text)
splitListingHeader raw =
  case Text.uncons raw of
    Just ('[', rest) ->
      let (header, after) = Text.break (== ']') rest
       in (header, Text.dropWhile (== '\n') (Text.drop 1 after))
    _ -> (Text.empty, Text.dropWhile (== '\n') raw)

listingLanguage' :: Text -> Text
listingLanguage' header =
  case [Text.strip v | (k, Just v) <- optionPairs header, k == "language"] of
    v : _ -> Text.toLower v
    [] -> Text.empty

mathKind :: MathForm -> MathKind
mathKind form =
  case form of
    InlineDollar -> InlineMath
    InlineParen -> InlineMath
    DisplayDoubleDollar -> DisplayMath
    DisplayBracket -> DisplayMath

-- | Split attached arguments into overlay spec, options and mandatory bodies.
data Args = Args
  { argAngle :: !(Maybe Text)
  , argOptional :: ![[SynNode]]
  , argMandatory :: ![[SynNode]]
  }

splitArgs :: [ArgumentF SynNode] -> Args
splitArgs args =
  Args
    { argAngle = case [s | Angle _ s <- args] of s : _ -> Just s; [] -> Nothing
    , argOptional = [k | Optional _ k <- args]
    , argMandatory = [k | Mandatory _ k <- args]
    }

lowerCommand :: Ctx -> SynNode -> Text -> [ArgumentF SynNode] -> L [ContentNode]
lowerCommand ctx current name args =
  case name of
    "pause" -> pure [OverlayPauseContent p PauseNext]
    -- Vertical space, as in Beamer: the plan carries the length in em.
    "smallskip" -> pure [vspace "0.3"]
    "medskip" -> pure [vspace "0.6"]
    "bigskip" -> pure [vspace "1.2"]
    "vspace" -> pure [vspace (Text.pack (show (lengthEm (Text.strip (printNodes (concat (take 1 (argMandatory a))))))))]
    "bibliography" -> pure [TransparentContainer p (GenericContainer "bibliography") []]
    "sbbox" -> do
      title <- maybe (pure []) (lowerSeq ctx) (listToMaybe' (argMandatory a))
      body <- maybe (pure []) (lowerSeq ctx) (listToMaybe' (drop 1 (argMandatory a)))
      let options = Text.strip (printNodes (concat (argOptional a)))
          boxed =
            TransparentContainer
              p
              (BoxContainer options)
              [ TransparentContainer p (GenericContainer "box-title") (trimNodes title)
              , TransparentContainer p (GenericContainer "box-body") (trimNodes body)
              ]
      withSpec boxed
    "figure" -> lowerFigure
    "includegraphics" -> lowerFigure
    "footnote" -> do
      inner <- maybe (pure []) (lowerSeq ctx) (listToMaybe' (argMandatory a))
      pure [TransparentContainer p (GenericContainer "footnote") (trimNodes inner)]
    -- @\\route{id}{label}@: a route choice; the plan lowers it to a button.
    "route" -> do
      label <- maybe (pure []) (lowerSeq ctx) (listToMaybe' (drop 1 (argMandatory a)))
      let target = Text.strip (printNodes (concat (take 1 (argMandatory a))))
      pure [TransparentContainer p (GenericContainer ("route:" <> target)) (trimNodes label)]
    "cite" -> citation Nothing
    "citep" -> citation (Just "citep")
    "citet" -> citation (Just "citet")
    "citeauthor" -> citation (Just "citeauthor")
    "citeyear" -> citation (Just "citeyear")
    "nocite" -> pure []
    "citefootnote" -> do
      cited <- citation Nothing
      pure [TransparentContainer p (GenericContainer "footnote") cited]
    _
      | name `elem` ["only", "uncover", "onslide", "visible"] -> overlayCommand
      | name == "invisible" -> do
          report ctx LevelInfo "overlay.unsupported" "\\invisible is not supported; content is shown"
          inner <- maybe (pure []) (lowerSeq ctx) (listToMaybe' (argMandatory a))
          pure inner
      | otherwise -> do
          report ctx LevelInfo "command.unknown" ("unknown command \\" <> name <> "; kept as an opaque region")
          (: []) <$> unsupported ctx LaTeX UnsupportedSyntax
  where
    vspace em = TransparentContainer p (GenericContainer ("vspace:" <> em)) []
    -- A TeX length in em (11pt body): em, ex, pt, mm, cm, in; unknown units read as em.
    lengthEm :: Text -> Double
    lengthEm t =
      let (num, unit) = Text.span (\c -> c `elem` ("0123456789.-" :: String)) (Text.filter (/= '*') t)
          n = case reads (Text.unpack (if Text.isPrefixOf "." num then "0" <> num else num)) of [(v, "")] -> v; _ -> 0
       in n * case Text.strip unit of
            "ex" -> 0.5
            "pt" -> 1 / 11
            "mm" -> 2.845 / 11
            "cm" -> 28.45 / 11
            "in" -> 72.27 / 11
            _ -> 1
    a = splitArgs args
    p = provenance ctx LaTeX
    withSpec produced =
      case argAngle a of
        Nothing -> pure [produced]
        Just spec -> do
          hook <- hookFor ctx spec
          pure [OverlayContent hook [produced]]
    overlayCommand = do
      inner <- maybe (pure []) (lowerSeq ctx) (listToMaybe' (argMandatory a))
      case argAngle a of
        Nothing -> pure inner
        Just spec -> do
          hook <- hookFor ctx spec
          pure [OverlayContent hook (if name == "only" then onlyMark inner else inner)]
    -- As in Beamer, \only (and a figure with an overlay spec) takes no space where it
    -- is hidden; \uncover and the others keep their space. The runtime drops content
    -- under this mark at the steps it is hidden instead of reserving it.
    onlyMark inner = [TransparentContainer p (GenericContainer "only") inner]
    citation variant =
      let keys = mapMaybe citationKey (filter (not . Text.null) (fmap Text.strip (Text.splitOn "," (printNodes (concat (take 1 (argMandatory a)))))))
          wrap node' =
            case variant of
              Nothing -> [node']
              Just v -> [TransparentContainer p (GenericContainer ("cite:" <> Text.drop 4 v)) [node']]
       in case NonEmpty.nonEmpty keys of
            Just neKeys -> pure (wrap (CitationContent p neKeys DerivedUnresolved))
            Nothing -> do
              report ctx LevelWarning "cite.empty" ("\\" <> name <> " has no valid citation key")
              (: []) <$> unsupported ctx LaTeX UnsupportedSyntax
    lowerFigure = do
      let target = Text.strip (printNodes (concat (take 1 (argMandatory a))))
          options = Text.strip (printNodes (concat (argOptional a)))
          lowered
            | isTikzPath target && not (Text.any (== '\\') target) = do
                handle <- figureHandle ctx
                recordResource (FlowResource handle TikzFile target options (ctxLine ctx))
                pure (figureNode ctx options handle)
            | isImagePath target = do
                handle <- imageHandle ctx
                recordResource (FlowResource handle ImageFile target options (ctxLine ctx))
                case assetId handle of
                  Just asset ->
                    pure
                      [ TransparentContainer p (FigureContainer options) [ImageContent p asset ""]
                      ]
                  Nothing -> (: []) <$> unsupported ctx LaTeX UnsupportedSyntax
            | any (`Text.isInfixOf` target) ["\\begin{tikzpicture}", "\\draw", "\\node", "\\path"] = do
                handle <- figureHandle ctx
                recordResource (FlowResource handle TikzInline target options (ctxLine ctx))
                pure (figureNode ctx options handle)
            | otherwise = do
                report ctx LevelWarning "figure.unknown-target" ("\\" <> name <> " target is neither a .tikz/.tex file, an image, nor TikZ source")
                (: []) <$> unsupported ctx LaTeX UnsupportedSyntax
      produced <- lowered
      case (argAngle a, produced) of
        (Just spec, [single]) -> do
          hook <- hookFor ctx spec
          pure [OverlayContent hook (onlyMark [single])]
        _ -> pure produced
    _unused = current

listToMaybe' :: [x] -> Maybe x
listToMaybe' xs = case xs of x : _ -> Just x; [] -> Nothing

isImagePath :: Text -> Bool
isImagePath path =
  not (Text.any (== '\\') path)
    && any (`Text.isSuffixOf` Text.toLower path) [".svg", ".png", ".jpg", ".jpeg", ".pdf", ".gif", ".webp"]

unsupported :: Ctx -> Dialect -> UnsupportedKind -> L ContentNode
unsupported ctx dialect kind = do
  n <- nextCounter sUnsupported (\s v -> s {sUnsupported = v})
  let handle = contextHandlePrefix (ctxFlow ctx) <> "-opaque-" <> Text.pack (show n)
  case sourceRef handle of
    Just ref -> pure (UnsupportedContent (SourceBackedContent ref dialect kind))
    Nothing -> pure (TextRun (provenance ctx dialect) Text.empty)

------------------------------------------------------------------------------
-- Content helpers

-- | Merge adjacent text runs with equal provenance.
coalesce :: [ContentNode] -> [ContentNode]
coalesce nodes =
  case nodes of
    TextRun p1 a : TextRun p2 b : rest | p1 == p2 -> coalesce (TextRun p1 (a <> b) : rest)
    other : rest -> other : coalesce rest
    [] -> []

-- | Drop leading and trailing whitespace-only text.
trimNodes :: [ContentNode] -> [ContentNode]
trimNodes = trimEnd . trimStart
  where
    trimStart nodes =
      case nodes of
        TextRun p t : rest ->
          let stripped = Text.stripStart t
           in if Text.null stripped then trimStart rest else TextRun p stripped : rest
        _ -> nodes
    trimEnd = reverse . trimStart' . reverse
    trimStart' nodes =
      case nodes of
        TextRun p t : rest ->
          let stripped = Text.stripEnd t
           in if Text.null stripped then trimStart' rest else TextRun p stripped : rest
        _ -> nodes

------------------------------------------------------------------------------
-- Region nodes

-- | A named flow region: where a title, body or footer lives on the slide.
data Region
  = TitleRegion
  | BodyRegion
  | SubtitleRegion
  | AuthorsRegion
  | InstituteRegion
  | DateRegion
  | NotesRegion
  deriving stock (Eq, Ord, Show)

regionName :: Region -> Text
regionName region =
  case region of
    TitleRegion -> "title"
    BodyRegion -> "body"
    SubtitleRegion -> "subtitle"
    AuthorsRegion -> "authors"
    InstituteRegion -> "institute"
    DateRegion -> "date"
    NotesRegion -> "notes"

-- | Fallback geometry in fractions @(left, bottom, width, height)@ when the
-- theme declares no region of that name; y grows upward.
defaultRect :: Bool -> Region -> (Rational, Rational, Rational, Rational)
defaultRect titleSlide region =
  case (titleSlide, region) of
    (True, TitleRegion) -> (0.08, 0.55, 0.84, 0.20)
    (True, SubtitleRegion) -> (0.08, 0.45, 0.84, 0.09)
    (True, AuthorsRegion) -> (0.08, 0.28, 0.84, 0.08)
    (True, InstituteRegion) -> (0.08, 0.20, 0.84, 0.07)
    (True, DateRegion) -> (0.08, 0.12, 0.84, 0.07)
    (True, BodyRegion) -> (0.08, 0.10, 0.84, 0.60)
    (_, NotesRegion) -> (0.04, 0.04, 0.92, 0.92)
    (False, TitleRegion) -> (0.04, 0.84, 0.92, 0.12)
    (False, BodyRegion) -> (0.04, 0.08, 0.92, 0.72)
    (False, _) -> (0.04, 0.02, 0.92, 0.06)

-- | Slide size in canvas units for an aspect ratio: height 9, width from the ratio
-- (16:9 gives 16x9, 4:3 gives 12x9).
slideSizeFor :: Natural -> Natural -> Maybe Size
slideSizeFor w h
  | h == 0 = Nothing
  | otherwise =
      either (const Nothing) Just
        (mkSize (canvasUnit (9 * fromIntegral w / fromIntegral h)) (canvasUnit 9))

-- | Place each region's content as one node. Empty content produces no node.
-- Placement is generated from the theme region (or the fallback geometry), so
-- the nodes carry no authored coordinates; sizing is the region's size.
regionNodes :: Theme -> Size -> Bool -> [(Region, Content)] -> [LayerEntry]
regionNodes theme size titleSlide parts =
  [ ObjectEntry (CanvasNode (mkNode region body))
  | (region, body) <- parts
  , not (null (contentNodes body))
  ]
  where
    width = canvasUnitValue (sizeWidth size)
    height = canvasUnitValue (sizeHeight size)
    themed =
      Map.fromList
        [ ( masterRegionName r
          , ( fractionValue (relativeRectLeft (masterRegionRect r))
            , fractionValue (relativeRectBottom (masterRegionRect r))
            , fractionValue (relativeRectWidth (masterRegionRect r))
            , fractionValue (relativeRectHeight (masterRegionRect r))
            )
          )
        | r <- masterRegions (themeMasterLayout theme)
        ]
    rectFor region = maybe (defaultRect titleSlide region) id (Map.lookup (regionName region) themed)
    mkNode region body =
      let (l, b, w, h) = rectFor region
          topLeft = point (canvasUnit (l * width)) (canvasUnit ((b + h) * height))
          regionSize = either (const size) id (mkSize (canvasUnit (w * width)) (canvasUnit (h * height)))
          identifier = regionNodeId region
          role = themedRole region
       in Object.Node
            { Object.nodeIdentifier = identifier
            , Object.nodePlacement = GeneratedPlacement topLeft NorthWest
            , Object.nodeOutline = PrimitiveGeometry RectangleOutline
            , Object.nodeContent = body
            , Object.nodePropertyOverrides =
                emptyNodePropertyPatch
                  { nodePatchSizing = Just (FixedSize regionSize)
                  , nodePatchRole = role
                  }
            , Object.nodeAnimationRefs = []
            , Object.nodeAccessibility = DecorativeNode
            }
    themedRole region =
      case roleId (regionName region) of
        Just role | Map.member role (themeNodeRoles (themeStyle theme)) -> Just role
        _ -> Nothing :: Maybe RoleId
    regionNodeId region =
      case nodeId ("flow-" <> regionName region) of
        Just identifier -> identifier
        Nothing -> fallbackNodeId

-- A literal that always validates; used only to avoid a partial function.
fallbackNodeId :: NodeId
fallbackNodeId =
  case nodeId "flow-region" of
    Just identifier -> identifier
    Nothing -> fallbackNodeId

------------------------------------------------------------------------------
-- Picture tier

-- | Lower a @```slide@ block body. Supported @\\node@ statements become absolutely
-- placed nodes (anchor @center@ unless @anchor=..@ says otherwise, overlay from
-- @overlay={spec}@); anything else becomes an opaque-statement barrier with an
-- informational diagnostic. Statement text is never modified.
pictureEntries :: FlowContext -> Int -> Text -> ([LayerEntry], [FlowDiagnostic], [FlowResource])
pictureEntries context firstLine body =
  let (entries, final) = runL (go (Ctx context firstLine) (1 :: Int) (readPicture body))
   in (concat entries, reverse (sDiagnostics final), reverse (sResources final))
  where
    go _ _ [] = pure []
    go ctx n (statement : rest) = do
      here <- one ctx n statement
      let advanced = ctx {ctxLine = ctxLine ctx + Text.count "\n" (statementTextOf statement)}
      later <- go advanced (n + 1) rest
      pure (here : later)
    statementTextOf statement =
      case statement of
        NodeStatement {} -> nodeRaw statement
        OpaqueStatement raw -> raw
    nodeRaw statement =
      case statement of
        NodeStatement _ _ _ _ _ raw -> raw
        OpaqueStatement raw -> raw
    one ctx n statement =
      case statement of
        NodeStatement options name x y nodeBody _ -> do
          let pairs = optionPairs options
              identifier = pickId n name
              port = maybe Centre id (lookupAnchor pairs)
          inner <- lowerProse ctx (Block.readProse nodeBody)
          let isBox = any (\(k, _) -> k == "sbbox") pairs
              boxed =
                if isBox
                  then
                    [ TransparentContainer
                        (provenance ctx LaTeX)
                        (BoxContainer options)
                        [ TransparentContainer (provenance ctx LaTeX) (GenericContainer "box-title") []
                        , TransparentContainer (provenance ctx LaTeX) (GenericContainer "box-body") (trimNodes inner)
                        ]
                    ]
                  else trimNodes inner
          hook <-
            case [v | (k, Just v) <- pairs, k == "overlay"] of
              spec : _ -> Just <$> hookFor ctx spec
              [] -> pure Nothing
          pure
            [ ObjectEntry
                ( CanvasNode
                    Object.Node
                      { Object.nodeIdentifier = identifier
                      , Object.nodePlacement = AbsolutePlacement (point (canvasUnit x) (canvasUnit y)) port
                      , Object.nodeOutline = PrimitiveGeometry RectangleOutline
                      , Object.nodeContent = content boxed
                      , Object.nodePropertyOverrides = emptyNodePropertyPatch {nodePatchOverlay = hook}
                      , Object.nodeAnimationRefs = []
                      , Object.nodeAccessibility = DecorativeNode
                      }
                )
            ]
        OpaqueStatement raw
          | Text.all isSpace raw || isCommentOnly raw -> pure []
          | Just _ <- parseDraw raw -> pure []
          | otherwise -> do
              report ctx LevelInfo "picture.unsupported-statement" ("picture statement outside the supported subset is kept opaque: " <> Text.take 40 (Text.strip raw))
              case (barrierId ("statement-" <> Text.pack (show n)), sourceRef (contextHandlePrefix context <> "-statement-" <> Text.pack (show n))) of
                (Just barrier, Just ref) -> pure [BarrierEntry (OpaqueStatementBarrier barrier ref)]
                _ -> pure []
    isCommentOnly raw = all (\l -> let t = Text.strip l in Text.null t || "%" `Text.isPrefixOf` t) (Text.lines raw)
    pickId n name =
      case name >>= validId of
        Just identifier -> identifier
        Nothing -> case nodeId ("picture-" <> Text.pack (show n)) of
          Just identifier -> identifier
          Nothing -> fallbackNodeId
    validId t = if Text.all (\c -> isAlphaNum c || c == '-' || c == '_') t then nodeId t else Nothing
    lookupAnchor pairs =
      case [v | (k, Just v) <- pairs, k == "anchor"] of
        v : _ -> anchorPort (Text.strip v)
        [] -> Nothing
    anchorPort v =
      case v of
        "north" -> Just North
        "north east" -> Just NorthEast
        "east" -> Just East
        "south east" -> Just SouthEast
        "south" -> Just South
        "south west" -> Just SouthWest
        "west" -> Just West
        "north west" -> Just NorthWest
        "center" -> Just Centre
        _ -> Nothing

-- | The characters of a content tree in reading order, with block boundaries as
-- single spaces. Used for frame titles and navigation labels; never for
-- rendering.
contentPlainText :: Content -> Text
contentPlainText = Text.unwords . Text.words . Text.concat . fmap plain . contentNodes
  where
    plain node' =
      case node' of
        TextRun _ t -> t
        StyledRun _ _ kids -> Text.concat (fmap plain kids)
        TransparentContainer _ _ kids -> " " <> Text.concat (fmap plain kids) <> " "
        ListContent _ _ items -> Text.concat [" " <> Text.concat (fmap plain (contentItemBody i)) | i <- NonEmpty.toList items]
        OpaqueMath _ _ payload -> payload
        OverlayContent _ kids -> Text.concat (fmap plain kids)
        LineBreak _ -> " "
        _ -> ""

-- | A picture-tier item the host can place on top of the flow body: a node at
-- slide coordinates (units, origin bottom-left) or a straight polyline.
data PictureItem
  = PictureNodeItem
      { pictureNodeId :: !Text
      , pictureNodeX :: !Double
      , pictureNodeY :: !Double
      , pictureNodeAnchor :: !Text
      , pictureNodeOptions :: !Text
      , pictureNodeContent :: ![ContentNode]
      , pictureNodeHook :: !(Maybe OverlayHook)
      }
  | PictureLineItem
      { pictureLineOptions :: !Text
      , pictureLinePoints :: ![PictureEndpoint]
      }
  deriving stock (Eq, Show)

-- | An end of a drawn line: a node id or slide coordinates.
data PictureEndpoint
  = EndpointNode !Text
  | EndpointPoint !Double !Double
  deriving stock (Eq, Show)

-- | The nodes and straight @\\draw@ lines of a picture block, in source order.
-- Statements outside this subset are skipped here (they stay opaque in
-- 'pictureEntries', which reports them).
pictureItems :: FlowContext -> Int -> Text -> [PictureItem]
pictureItems context firstLine body = concat (fst (runL (go (Ctx context firstLine) (1 :: Int) (readPicture body))))
  where
    go _ _ [] = pure []
    go ctx n (statement : rest) = do
      here <- one ctx n statement
      let raw = case statement of
            NodeStatement _ _ _ _ _ r -> r
            OpaqueStatement r -> r
      later <- go (ctx {ctxLine = ctxLine ctx + Text.count "\n" raw}) (n + 1) rest
      pure (here : later)
    one ctx n statement =
      case statement of
        NodeStatement options name x y nodeBody _ -> do
          let pairs = optionPairs options
              identifier = maybe ("picture-" <> Text.pack (show n)) id (name >>= validName)
              isBox = any (\(k, _) -> k == "sbbox") pairs
              anchor = case [v | (k, Just v) <- pairs, k == "anchor"] of
                v : _ -> Text.strip v
                [] -> "center"
          inner <- lowerProse ctx (Block.readProse nodeBody)
          let nodes
                | isBox = [TransparentContainer (provenance ctx LaTeX) (BoxContainer options) [TransparentContainer (provenance ctx LaTeX) (GenericContainer "box-title") [], TransparentContainer (provenance ctx LaTeX) (GenericContainer "box-body") (trimNodes inner)]]
                | otherwise = trimNodes inner
          hook <-
            case [v | (k, Just v) <- pairs, k == "overlay"] of
              spec : _ -> Just <$> hookFor ctx spec
              [] -> pure Nothing
          pure [PictureNodeItem identifier (fromRational x) (fromRational y) anchor options nodes hook]
        OpaqueStatement raw ->
          pure [PictureLineItem opts points | Just (opts, points) <- [parseDraw raw]]
    validName t = if not (Text.null t) && Text.all (\c -> isAlphaNum c || c == '-' || c == '_') t then Just t else Nothing

-- @\\draw[options] (a) -- (b) -- (x,y);@ with node ids and plain coordinates.
parseDraw :: Text -> Maybe (Text, [PictureEndpoint])
parseDraw raw = do
  afterDraw <- Text.stripPrefix "\\draw" (Text.strip raw)
  let (options, afterOptions) = case Text.uncons (Text.stripStart afterDraw) of
        Just ('[', rest) -> let (inside, after) = Text.break (== ']') rest in (inside, Text.drop 1 after)
        _ -> ("", afterDraw)
      path = Text.strip (maybe (Text.strip afterOptions) id (Text.stripSuffix ";" (Text.strip afterOptions)))
  points <- traverse endpoint (Text.splitOn "--" path)
  if length points >= 2 then Just (options, points) else Nothing
  where
    endpoint part = do
      inner <- Text.stripPrefix "(" (Text.strip part) >>= Text.stripSuffix ")"
      case Text.splitOn "," inner of
        [a, b] -> EndpointPoint <$> number a <*> number b
        [single]
          | Text.all (\c -> isAlphaNum c || c `elem` ("-_." :: String)) (Text.strip single), not (Text.null (Text.strip single)) ->
              Just (EndpointNode (Text.takeWhile (/= '.') (Text.strip single)))
        _ -> Nothing
    number t = case TextRead.signed TextRead.double (Text.strip t) of
      Right (v, rest) | Text.null rest -> Just v
      _ -> Nothing
