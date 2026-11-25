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
  , PictureNode (..)
  , PictureLine (..)
  , PictureJoin (..)
  , PictureLabel (..)
  , PictureEndpoint (..)
  , pictureItems
  , shiftPictureItem
  , PictureFrom (..)
  , includedItem
  , pictureNodeDistance
  , parseDraw
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
import SlideBlaster.Canvas.Placement (Placement (AbsolutePlacement, GeneratedPlacement, RelativeNodePlacement), RelativePlacement (RelativePlacement), RelativeSide (Above, AboveLeft, AboveRight, Below, BelowLeft, BelowRight, LeftOf, RightOf), defaultPortsForSide)
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
import SlideBlaster.Syntax.Picture (DrawJoin (..), DrawLabel (..), DrawPath (..), DrawPoint (..), DrawStep (..), Statement (AttachedStatement, NodeStatement, OpaqueStatement), optionPairs, readDraw, readPicture, statementText)
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

import Data.Char (isAlphaNum, isDigit, isSpace)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Unsafe (lengthWord8)
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
      | name `elem` ["tabular", "tabular*", "array"] = lowerTabular ctx (printNodes body)
      | name == "columns" = lowerColumns ctx (printNodes body)
      | name == "column" = do
          let (width, rest) = leadingGroup (printNodes body)
          inner <- lowerBlocks ctx (Block.flowBlocks (Block.readFlow (Text.dropWhile (== '\n') rest)))
          pure [TransparentContainer (provenance ctx LaTeX) (ColumnContainer (columnWidth width)) inner]
      | otherwise = do
          report ctx LevelInfo "environment.unknown" ("unknown environment " <> name <> "; its content is shown")
          inner <- lowerSeq ctx body
          pure [TransparentContainer (provenance ctx LaTeX) (GenericContainer name) inner]

-- @\\begin{tabular}{lr} a & b \\\\ c & d \\end{tabular}@: rows end with @\\\\@, cells
-- are split at @&@, the column letters give the alignment, and rules
-- (@\\toprule@, @\\midrule@, @\\bottomrule@, @\\hline@) are dropped. The first row
-- is the head.
lowerTabular :: Ctx -> Text -> L [ContentNode]
lowerTabular ctx raw = do
  let (spec, rest) = leadingGroup raw
      aligns = [Text.singleton c | c <- Text.unpack spec, c `elem` ("lcr" :: String)]
      rows = filter (not . Text.null . Text.strip) (fmap withoutRules (splitTop "\\\\" rest))
  rowModels <- traverse lowerRow rows
  case NonEmpty.nonEmpty (mapMaybe id rowModels) of
    Just neRows -> pure [TableContent (provenance ctx LaTeX) (DerivedReady (TableModel neRows aligns))]
    Nothing -> (: []) <$> unsupported ctx LaTeX UnsupportedSyntax
  where
    withoutRules row = foldl (\t rule -> Text.replace rule "" t) row ["\\toprule", "\\midrule", "\\bottomrule", "\\hline"]
    lowerRow row = do
      cells <- traverse (\cell -> TableCell 1 1 . trimNodes <$> lowerProse ctx (Block.readProse (Text.strip cell))) (splitTop "&" row)
      pure (TableRow <$> NonEmpty.nonEmpty cells)

-- @\\begin{columns} \\column{0.6} .. \\column{0.4} .. \\end{columns}@ as in Beamer;
-- @\\begin{column}{w}@ environments inside are read by the environment rule.
lowerColumns :: Ctx -> Text -> L [ContentNode]
lowerColumns ctx raw =
  case drop 1 (Text.splitOn "\\column{" (snd (leadingOptional raw))) of
    [] -> do
      inner <- lowerBlocks ctx (Block.flowBlocks (Block.readFlow (Text.dropWhile (== '\n') raw)))
      pure [TransparentContainer (provenance ctx LaTeX) ColumnsContainer inner]
    pieces -> do
      columns <- traverse one pieces
      pure [TransparentContainer (provenance ctx LaTeX) ColumnsContainer columns]
  where
    one piece = do
      let (width, rest) = Text.breakOn "}" piece
      inner <- lowerBlocks ctx (Block.flowBlocks (Block.readFlow (Text.dropWhile (== '\n') (Text.drop 1 rest))))
      pure (TransparentContainer (provenance ctx LaTeX) (ColumnContainer (columnWidth width)) inner)

-- A Beamer column width (@0.6@, @0.6\\textwidth@, @.5\\linewidth@) as a percentage.
columnWidth :: Text -> Text
columnWidth width =
  let number = Text.takeWhile (\c -> isDigit c || c == '.') (Text.strip width)
   in case TextRead.double (if "." `Text.isPrefixOf` number then "0" <> number else number) of
        Right (v, _) | v > 0 && v <= 1 -> Text.pack (show (round (v * 100) :: Int)) <> "%"
        _ -> Text.strip width

-- A leading @{..}@ group of an environment body, and the text after it.
leadingGroup :: Text -> (Text, Text)
leadingGroup raw =
  case Text.uncons (Text.stripStart (snd (leadingOptional raw))) of
    Just ('{', rest) -> let (inside, after) = Text.break (== '}') rest in (inside, Text.drop 1 after)
    _ -> (Text.empty, raw)

-- A leading @[..]@ group and the text after it.
leadingOptional :: Text -> (Text, Text)
leadingOptional raw =
  case Text.uncons (Text.stripStart raw) of
    Just ('[', rest) -> let (inside, after) = Text.break (== ']') rest in (inside, Text.drop 1 after)
    _ -> (Text.empty, raw)

-- Split at a separator outside braces and inline math.
splitTop :: Text -> Text -> [Text]
splitTop separator = go (0 :: Int) False Text.empty
  where
    go depth math acc remaining
      | Text.null remaining = [acc]
      | depth == 0 && not math && separator `Text.isPrefixOf` remaining = acc : go depth math Text.empty (Text.drop (Text.length separator) remaining)
      | otherwise =
          case Text.uncons remaining of
            Nothing -> [acc]
            Just ('\\', rest) | Just (c, rest') <- Text.uncons rest, c /= '\\' -> go depth math (acc <> Text.pack ['\\', c]) rest'
            Just (c, rest)
              | c == '{' -> go (depth + 1) math (Text.snoc acc c) rest
              | c == '}' -> go (max 0 (depth - 1)) math (Text.snoc acc c) rest
              | c == '$' -> go depth (not math) (Text.snoc acc c) rest
              | otherwise -> go depth math (Text.snoc acc c) rest

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
    -- @\\pause[3]@: what follows is shown from that step on, as in Beamer
    "pause"
      | Right (number, rest) <- TextRead.decimal (Text.strip (printNodes (concat (argOptional a))))
      , Text.null rest
      , Just at <- mkOverlayStep (number :: Natural) ->
          pure [OverlayPauseContent p (PauseAt at)]
    "pause" -> pure [OverlayPauseContent p PauseNext]
    "appear" -> pure [OverlayPauseContent p PauseNext]
    "printbibliography" -> pure [TransparentContainer p (GenericContainer "bibliography") []]
    -- @\\matrix{1 & 2 \\\\ 3 & 4}@: a matrix, typeset as math
    "matrix" -> pure [OpaqueMath p InlineMath ("\\begin{pmatrix}" <> printNodes (concat (take 1 (argMandatory a))) <> "\\end{pmatrix}")]
    -- @\\alert<2>{..}@: emphasised on those steps (always, without a spec), shown plain otherwise
    "alert" -> do
      inner <- maybe (pure []) (lowerSeq ctx) (listToMaybe' (argMandatory a))
      case argAngle a of
        Nothing -> pure [StyledRun p (InlineColour "#c62828" :| []) inner]
        Just spec -> do
          hook <- hookFor ctx spec
          pure [OverlayContent hook [TransparentContainer p (GenericContainer "alert") inner]]
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
          -- hidden (its space kept) on the named steps, shown on the others
          inner <- maybe (pure []) (lowerSeq ctx) (listToMaybe' (argMandatory a))
          case argAngle a of
            Nothing -> pure [OverlayContent AlwaysVisible [TransparentContainer p (GenericContainer "invisible") inner]]
            Just spec -> do
              hook <- hookFor ctx spec
              pure [OverlayContent hook [TransparentContainer p (GenericContainer "invisible") inner]]
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

-- | Lower a @```slide@ block body. A slide may hold several blocks: statements
-- are numbered across them, so each block is given the number of its first. Supported @\\node@ statements become absolutely
-- placed nodes (anchor @center@ unless @anchor=..@ says otherwise, overlay from
-- @overlay={spec}@); anything else becomes an opaque-statement barrier with an
-- informational diagnostic. Statement text is never modified.
pictureEntries :: FlowContext -> Int -> Int -> Text -> ([LayerEntry], [FlowDiagnostic], [FlowResource])
pictureEntries context firstLine firstStatement body =
  let (entries, final) = runL (go (Ctx context firstLine) firstStatement (readPicture body))
   in (concat entries, reverse (sDiagnostics final), reverse (sResources final))
  where
    go _ _ [] = pure []
    go ctx n (statement : rest) = do
      here <- one ctx n statement
      let advanced = ctx {ctxLine = ctxLine ctx + Text.count "\n" (statementTextOf statement)}
      later <- go advanced (n + 1) rest
      pure (here : later)
    statementTextOf = statementText
    one ctx n statement =
      case nodeForm statement of
        Just (NodeForm options name place nodeBody) -> do
          let pairs = optionPairs options
              identifier = pickId n name
              port = maybe Centre id (lookupAnchor pairs)
              placement =
                case place of
                  Left (x, y) -> AbsolutePlacement (point (canvasUnit x) (canvasUnit y)) port
                  Right (side, target, gap) ->
                    case (nodeId target, lookup side [("above", Above), ("below", Below), ("left", LeftOf), ("right", RightOf), ("above left", AboveLeft), ("above right", AboveRight), ("below left", BelowLeft), ("below right", BelowRight)]) of
                      (Just targetId, Just relativeSide) ->
                        let (own, theirs) = defaultPortsForSide relativeSide
                            distance = canvasUnit (maybe pictureNodeDistance id gap)
                            diagonal = relativeSide `elem` [AboveLeft, AboveRight, BelowLeft, BelowRight]
                         in RelativeNodePlacement (RelativePlacement targetId relativeSide distance (if diagonal then distance else canvasUnit 0) theirs own)
                      _ -> AbsolutePlacement (point (canvasUnit 8) (canvasUnit 4.5)) port
          inner <- lowerNodeBody ctx nodeBody
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
                      , Object.nodePlacement = placement
                      , Object.nodeOutline = PrimitiveGeometry RectangleOutline
                      , Object.nodeContent = content boxed
                      , Object.nodePropertyOverrides = emptyNodePropertyPatch {nodePatchOverlay = hook}
                      , Object.nodeAnimationRefs = []
                      , Object.nodeAccessibility = DecorativeNode
                      }
                )
            ]
        Nothing
          | Text.all isSpace raw || isCommentOnly raw -> pure []
          | Just _ <- parseDraw raw -> pure []
          | otherwise -> do
              report ctx LevelInfo "picture.unsupported-statement" ("picture statement outside the supported subset is kept opaque: " <> Text.take 40 (Text.strip raw))
              case (barrierId ("statement-" <> Text.pack (show n)), sourceRef (contextHandlePrefix context <> "-statement-" <> Text.pack (show n))) of
                (Just barrier, Just ref) -> pure [BarrierEntry (OpaqueStatementBarrier barrier ref)]
                _ -> pure []
          where
            raw = statementText statement
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
  = PictureNodeItem !PictureNode
  | PictureLineItem !PictureLine
  deriving stock (Eq, Show)

-- | A placed node of a picture.
data PictureNode = PictureNode
      { pictureNodeId :: !Text
      , pictureNodeX :: !Double
      , pictureNodeY :: !Double
      , pictureNodeAnchor :: !Text
      , pictureNodeOptions :: !Text
      , pictureNodeContent :: ![ContentNode]
      , pictureNodeHook :: !(Maybe OverlayHook)
      , pictureNodeStatement :: !Int
      -- ^ one-based number of the statement in the block
      , pictureNodeNamed :: !Bool
      -- ^ whether the source gives the node a name (else the id is @picture-N@)
      , pictureNodeSource :: !Text
      -- ^ the content exactly as written between the braces
      , pictureNodeSpan :: !(Int, Int)
      -- ^ UTF-8 byte span of the statement (leading blank space excluded)
      , pictureNodeAttached :: !(Maybe (Text, Text))
      -- ^ side and target id of a node attached to another (@below=of a@); its
      -- point is then derived by the layout and the X and Y fields are unused
      , pictureNodeGap :: !(Maybe Double)
      -- ^ the written distance of an attached node (@below=1.5 of a@), slide units
      , pictureNodeFrom :: !(Maybe PictureFrom)
      -- ^ set on a node that comes from an included picture file
      }
  deriving stock (Eq, Show)

-- | A line between nodes or points of a picture.
data PictureLine = PictureLine
      { pictureLineOptions :: !Text
      , pictureLinePoints :: ![PictureEndpoint]
      , pictureLineStatement :: !Int
      , pictureLineSpan :: !(Int, Int)
      , pictureLineFrom :: !(Maybe PictureFrom)
      , pictureLineAnchors :: ![Maybe Text]
      -- ^ for each point, the anchor written on a node end (@a.north@, @a.30@)
      , pictureLineJoins :: ![PictureJoin]
      -- ^ how each step reaches its point; one fewer than the points
      , pictureLineLabels :: ![PictureLabel]
      }
  deriving stock (Eq, Show)

-- | How a line goes from one point to the next.
data PictureJoin
  = PictureStraight
  | -- | along x, then along y (@-|@)
    PictureHV
  | -- | along y, then along x (@|-@)
    PictureVH
  | -- | a curve leaving at this many degrees to the left of straight (negative: right)
    PictureBend !Double
  | -- | a curve leaving and arriving at these angles (@out@, @in@)
    PictureOutIn !Double !Double
  deriving stock (Eq, Show)

-- | A label on a line: its step (from 1), whether it sits at the step's point
-- rather than along it, and what it shows, as a node (its point is derived).
data PictureLabel = PictureLabel
  { pictureLabelStep :: !Int
  , pictureLabelAtEnd :: !Bool
  , pictureLabelNode :: !PictureNode
  }
  deriving stock (Eq, Show)

-- | Where an included picture item comes from: the file, the @\\cat@ statement
-- that brings it in (its number among the slide's statements and its byte span
-- in the deck) and the shift that statement gives it, in slide units. The
-- item's own span counts in the file.
data PictureFrom = PictureFrom
  { fromFile :: !Text
  , fromStatement :: !Int
  , fromSpan :: !(Int, Int)
  , fromShift :: !(Double, Double)
  }
  deriving stock (Eq, Show)

-- | Mark an item as included and move it by the include's shift.
includedItem :: PictureFrom -> PictureItem -> PictureItem
includedItem from item =
  let (dx, dy) = fromShift from
   in case item of
        PictureNodeItem node -> PictureNodeItem node {pictureNodeX = pictureNodeX node + dx, pictureNodeY = pictureNodeY node + dy, pictureNodeFrom = Just from}
        PictureLineItem line ->
          PictureLineItem
            line
            { pictureLinePoints = [case point of EndpointPoint x y -> EndpointPoint (x + dx) (y + dy); other -> other | point <- pictureLinePoints line]
            , pictureLineFrom = Just from
            }

-- | Move an item's byte span by an offset (block-relative to file-relative).
shiftPictureItem :: Int -> PictureItem -> PictureItem
shiftPictureItem base item =
  case item of
    PictureNodeItem node -> PictureNodeItem node {pictureNodeSpan = shifted (pictureNodeSpan node)}
    PictureLineItem line -> PictureLineItem line {pictureLineSpan = shifted (pictureLineSpan line)}
  where
    shifted (a, b) = (a + base, b + base)

-- | An end of a drawn line: a node id or slide coordinates.
data PictureEndpoint
  = EndpointNode !Text
  | EndpointPoint !Double !Double
  deriving stock (Eq, Show)

-- | The nodes and straight @\\draw@ lines of a picture block, in source order.
-- Statements outside this subset are skipped here (they stay opaque in
-- 'pictureEntries', which reports them).
pictureItems :: FlowContext -> Int -> Int -> Text -> [PictureItem]
pictureItems context firstLine firstStatement body = concat (fst (runL (go (Ctx context firstLine) firstStatement (0 :: Int) (readPicture body))))
  where
    go _ _ _ [] = pure []
    go ctx n offset (statement : rest) = do
      let raw = statementText statement
          bytesOf = lengthWord8
          end = offset + bytesOf raw
          start = end - bytesOf (Text.stripStart raw)
      here <- one ctx n (start, end) statement
      later <- go (ctx {ctxLine = ctxLine ctx + Text.count "\n" raw}) (n + 1) end rest
      pure (here : later)
    one ctx n range statement =
      case nodeForm statement of
        Just (NodeForm options name place nodeBody) -> do
          let pairs = optionPairs options
              identifier = maybe ("picture-" <> Text.pack (show n)) id (name >>= validName)
              isBox = any (\(k, _) -> k == "sbbox") pairs
              anchor = case [v | (k, Just v) <- pairs, k == "anchor"] of
                v : _ -> Text.strip v
                [] -> "center"
          inner <- lowerNodeBody ctx nodeBody
          let nodes
                | isBox = [TransparentContainer (provenance ctx LaTeX) (BoxContainer options) [TransparentContainer (provenance ctx LaTeX) (GenericContainer "box-title") [], TransparentContainer (provenance ctx LaTeX) (GenericContainer "box-body") (trimNodes inner)]]
                | otherwise = trimNodes inner
          hook <-
            case [v | (k, Just v) <- pairs, k == "overlay"] of
              spec : _ -> Just <$> hookFor ctx spec
              [] -> pure Nothing
          let (x, y) = either id (const (0, 0)) place
          pure [PictureNodeItem (PictureNode identifier (fromRational x) (fromRational y) anchor options nodes hook n (maybe False (const True) (name >>= validName)) nodeBody range (either (const Nothing) (\(side, target, _) -> Just (side, target)) place) (either (const Nothing) (\(_, _, gap) -> fromRational <$> gap) place) Nothing)]
        Nothing ->
          case readDraw (statementText statement) of
            Nothing -> pure []
            Just path -> do
              let written = zip [1 :: Int ..] [(k, atEnd, label) | (k, step) <- zip [1 :: Int ..] (drawSteps path), (atEnd, label) <- fmap ((,) False) (stepLabels step) <> fmap ((,) True) (stepAfter step)]
              labels <- traverse (\(j, (k, atEnd, DrawLabel labelOptions body)) -> do
                  content <- lowerNodeBody ctx body
                  pure (PictureLabel k atEnd (PictureNode ("label-" <> Text.pack (show n) <> "-" <> Text.pack (show j)) 0 0 "" labelOptions (trimNodes content) Nothing n False body range Nothing Nothing Nothing))) written
              pure [PictureLineItem (PictureLine (drawOptions path) (drawEnds path) n range Nothing (drawAnchors path) (drawJoins path) labels)]
    validName t = if not (Text.null t) && Text.all (\c -> isAlphaNum c || c == '-' || c == '_') t then Just t else Nothing

-- A node's content: one line is inline text; several lines are a flow of
-- blocks (lists, tables, containers), as in a slide body.
lowerNodeBody :: Ctx -> Text -> L [ContentNode]
lowerNodeBody ctx body
  | Text.any (== '\n') (Text.strip body) =
      let text = Text.dropWhile (== '\n') (Text.dropWhileEnd isSpace body)
       in lowerBlocks ctx (Block.flowBlocks (Block.readFlow text))
  | otherwise = lowerProse ctx (Block.readProse body)

-- | The gap, in slide units, between a node and one attached to it.
pictureNodeDistance :: Rational
pictureNodeDistance = 3 / 4

-- Both node forms as one: options, name, an absolute point or a side and
-- target, and the content.
data NodeForm = NodeForm !Text !(Maybe Text) !(Either (Rational, Rational) (Text, Text, Maybe Rational)) !Text

nodeForm :: Statement -> Maybe NodeForm
nodeForm statement =
  case statement of
    NodeStatement options name x y body _ -> Just (NodeForm options name (Left (x, y)) body)
    AttachedStatement options name side target gap body _ -> Just (NodeForm options name (Right (side, target, gap)) body)
    OpaqueStatement _ -> Nothing

drawPoints :: DrawPath -> [DrawPoint]
drawPoints path = drawStart path : fmap stepPoint (drawSteps path)

drawEnds :: DrawPath -> [PictureEndpoint]
drawEnds path = [case at of DrawNode name _ -> EndpointNode name; DrawAt x y -> EndpointPoint (fromRational x) (fromRational y) | at <- drawPoints path]

drawAnchors :: DrawPath -> [Maybe Text]
drawAnchors path = [case at of DrawNode _ anchor -> anchor; DrawAt _ _ -> Nothing | at <- drawPoints path]

-- A @to@ bends as its own options say, else as the line's; without either it is straight.
drawJoins :: DrawPath -> [PictureJoin]
drawJoins path = fmap (joinOf . stepJoin) (drawSteps path)
  where
    joinOf join = case join of
      JoinStraight -> PictureStraight
      JoinHV -> PictureHV
      JoinVH -> PictureVH
      JoinTo options -> fromMaybe PictureStraight (curve (optionPairs options) `orElse` curve (optionPairs (drawOptions path)))
    orElse a b = maybe b Just a
    curve pairs =
      let value key = case reverse [v | (k, v) <- pairs, k == key] of
            v : _ -> Just v
            [] -> Nothing
          degrees fallback v = fromMaybe fallback (v >>= numberOf)
          numberOf t = case TextRead.signed TextRead.double (Text.strip t) of
            Right (v, rest) | Text.null (Text.strip rest) -> Just v
            _ -> Nothing
       in case (value "out" >>= (>>= numberOf), value "in" >>= (>>= numberOf), value "bend left", value "bend right") of
            (Just out, Just into, _, _) -> Just (PictureOutIn out into)
            (_, _, Just v, _) -> Just (PictureBend (degrees 30 v))
            (_, _, _, Just v) -> Just (PictureBend (negate (degrees 30 v)))
            _ -> Nothing

-- | The options and ends of a @\\draw@ line (see 'readDraw' for its full form).
parseDraw :: Text -> Maybe (Text, [PictureEndpoint])
parseDraw raw = (\path -> (drawOptions path, drawEnds path)) <$> readDraw raw
