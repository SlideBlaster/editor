{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Deck.Markdown
-- Description : Read a @*.slideBlaster.md@ deck into a source-locked document.
--
-- This is the alpha deck reader (design section 3). The exact bytes stay
-- authoritative: the syntax is the span container of
-- "SlideBlaster.Deck.Container", and the semantic value (a presentation plus a
-- per-slide view) is derived and never printed back.
--
-- == Structure
--
-- * Frontmatter between @---@ lines supplies the title slide and deck settings.
-- * Each @## Title {#id}@ line starts a slide; the body is a flow
--   ("SlideBlaster.Syntax.Block"), lowered to a title region and a body region.
-- * Top-level @```slide@ fences are the picture tier: positioned nodes in the
--   same scene. Top-level @```notes@ fences are the speaker notes scene.
-- * A slide without an id receives an implicit @slide-N@ that is not written to
--   the file until a writer asks for it.
--
-- == Failure policy
--
-- Container-level failures (invalid UTF-8, unclosed frontmatter, malformed or
-- duplicate ids, no slides, unusable aspect) produce a syntax-only document with
-- a hard diagnostic. Everything inside a slide body is non-hard: unknown
-- constructs are retained and reported (decision D8).
module SlideBlaster.Deck.Markdown
  ( -- * Documents
    MarkdownDeckDocument
  , MarkdownDeckSyntax (..)
  , MarkdownKey (..)
  , MarkdownDeck (..)
  , DeckSlide (..)
  , DeckSection (..)
  , DeckInclude (..)
  , DeckConfig (..)
  , defaultDeckConfig
  , analyzeMarkdownDeck
  , analyzeMarkdownDeckWith
    -- * Accessors for lowering
  , deckSlideList
  , deckSlideById
  , titleSlideId
  ) where

import SlideBlaster.Canvas qualified as Canvas
import SlideBlaster.Canvas.Flow qualified as Flow
import SlideBlaster.Deck.Container
  ( Container (..)
  , ContainerError (..)
  , IncludeEntry (..)
  , SectionEntry (..)
  , SlideEntry (..)
  , Span (..)
  , lineStarts
  , readContainer
  )
import SlideBlaster.Deck.Frontmatter
  ( Aspect (..)
  , Frontmatter
  , frontmatterAspect
  , frontmatterLookup
  , frontmatterRoutes
  , unknownKeys
  )
import SlideBlaster.Deck.Include (IncludeLine (..))
import SlideBlaster.Document qualified as Document
import SlideBlaster.Presentation qualified as Presentation
import SlideBlaster.Presentation.Flow qualified as PFlow
import SlideBlaster.Source qualified as Source
import SlideBlaster.Syntax.Ast qualified as Ast
import SlideBlaster.Syntax.Block qualified as Block

import Data.Char (isAsciiLower, isDigit)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Unsafe (lengthWord8)
import Numeric.Natural (Natural)

-- | The recoverable parent syntax; 'Nothing' when no container was admitted.
newtype MarkdownDeckSyntax = MarkdownDeckSyntax
  { syntaxContainer :: Maybe Container
  }
  deriving stock (Eq, Show)

-- | Provenance keys, one per editable or derived slide fact.
data MarkdownKey
  = SlideIdKey !Text
  | SlideTitleKey !Text
  | SlideBodyKey !Text
  | SlideNotesKey !Text
  deriving stock (Eq, Ord, Show)

-- | One slide's meaning.
data DeckSlide = DeckSlide
  { deckSlideId :: !Text
  , deckSlideExplicitId :: !Bool
  -- ^ Whether the id is written in the file.
  , deckSlideIsTitle :: !Bool
  -- ^ The generated title slide.
  , deckSlideTitle :: !Text
  , deckSlideTitleContent :: !Canvas.Content
  -- ^ The title read as inline TeX/Markdown (emphasis, math, commands).
  , deckSlideSpan :: !(Maybe Source.SourceSpan)
  -- ^ Heading through end of body; for the title slide, the frontmatter.
  , deckSlideHeadingSpan :: !(Maybe Source.SourceSpan)
  , deckSlideIdSpan :: !(Maybe Source.SourceSpan)
  , deckSlideBody :: !Canvas.Content
  , deckSlideNotes :: !Canvas.Content
  , deckSlideResources :: ![Flow.FlowResource]
  -- ^ Figures and images, by deterministic handle.
  , deckSlideIsDivider :: !Bool
  -- ^ A generated section divider (chapter page).
  , deckSlideDiagnostics :: ![Document.Diagnostic]
  , deckSlidePicture :: ![Flow.PictureItem]
  -- ^ Nodes and straight lines of the @```slide@ picture tier.
  }
  deriving stock (Eq, Show)

-- | A section (@# Title {#id}@) and the slides it holds, in file order. Slides
-- before the first section, and the generated title slide, belong to none.
data DeckSection = DeckSection
  { deckSectionId :: !Text
  , deckSectionExplicitId :: !Bool
  , deckSectionTitle :: !Text
  , deckSectionSpan :: !(Maybe Source.SourceSpan)
  , deckSectionHeadingSpan :: !(Maybe Source.SourceSpan)
  , deckSectionSlides :: ![Text]
  , deckSectionDivider :: !(Maybe Text)
  -- ^ Frame id of the generated divider slide, which comes first in the section.
  }
  deriving stock (Eq, Show)

-- | An @\\include[opts]{path}@ line and where it sits among the frames.
data DeckInclude = DeckInclude
  { deckIncludeLine :: !IncludeLine
  , deckIncludeSpan :: !(Maybe Source.SourceSpan)
  -- ^ the directive line without its line ending
  , deckIncludeFramesBefore :: !Int
  -- ^ how many entries of 'deckFrames' precede it
  , deckIncludeSection :: !(Maybe Text)
  -- ^ id of the section it falls in, if any
  }
  deriving stock (Eq, Show)

-- | The semantic value of a deck.
data MarkdownDeck = MarkdownDeck
  { deckPresentation :: !Presentation.Presentation
  , deckSlides :: ![DeckSlide]
  -- ^ The title slide and authored slides; what the writers address.
  , deckFrames :: ![DeckSlide]
  -- ^ 'deckSlides' with section dividers interleaved: every page of the deck.
  , deckFrontmatter :: !(Maybe Frontmatter)
  , deckThemeName :: !(Maybe Text)
  , deckSections :: ![DeckSection]
  , deckIncludes :: ![DeckInclude]
  -- ^ The @\\include@ lines, in file order.
  , deckRoutes :: ![(Text, [Text])]
  -- ^ Frontmatter @routes:@ as written: route name to section ids; the first is the default.
  }
  deriving stock (Eq, Show)

-- | A deck document.
type MarkdownDeckDocument = Document.DocumentSnapshot MarkdownDeckSyntax MarkdownKey MarkdownDeck

-- | How the host resolves the @theme:@ name. The theme itself is a defined
-- value owned by the host (design D4); this package never invents one.
data DeckConfig = DeckConfig
  { configResolveTheme :: Text -> Maybe Canvas.Theme
  , configHandlePrefix :: Text
  -- ^ prepended to slide ids in content handles, so an included deck's figure
  -- and image handles cannot collide with the parent's; empty for a top-level deck
  }

-- | Resolves nothing; every deck uses the default theme.
defaultDeckConfig :: DeckConfig
defaultDeckConfig = DeckConfig (const Nothing) ""

-- | All slides in order, title slide first when present.
deckSlideList :: MarkdownDeck -> [DeckSlide]
deckSlideList = deckSlides

-- | Look up a slide by id.
deckSlideById :: Text -> MarkdownDeck -> Maybe DeckSlide
deckSlideById identity deck =
  case filter ((== identity) . deckSlideId) (deckSlides deck) of
    slide : _ -> Just slide
    [] -> Nothing

-- | Id of the generated title slide.
titleSlideId :: Text
titleSlideId = "title-slide"

-- | Analyze with the default configuration.
analyzeMarkdownDeck :: Source.SourceBufferSnapshot -> MarkdownDeckDocument
analyzeMarkdownDeck = analyzeMarkdownDeckWith defaultDeckConfig

-- | Analyze one exact snapshot. Total.
analyzeMarkdownDeckWith :: DeckConfig -> Source.SourceBufferSnapshot -> MarkdownDeckDocument
analyzeMarkdownDeckWith config source =
  case readContainer (Source.snapshotBytes source) of
    Left failure ->
      failed source (MarkdownDeckSyntax Nothing) (containerFailure failure)
    Right container ->
      case build config source container of
        Left problem -> failed source (MarkdownDeckSyntax (Just container)) problem
        Right (deck, provenance, diagnostics) ->
          Document.readyDocument source (MarkdownDeckSyntax (Just container)) deck provenance diagnostics

failed :: Source.SourceBufferSnapshot -> MarkdownDeckSyntax -> Document.Diagnostic -> MarkdownDeckDocument
failed source syntax problem = Document.syntaxOnlyDocument source syntax (problem :| [])

------------------------------------------------------------------------------
-- Diagnostics

fallbackCode :: Document.DiagnosticCode
fallbackCode =
  case Document.mkDiagnosticCode "deck.internal" of
    Just code -> code
    Nothing -> fallbackCode

diag
  :: Document.DiagnosticSeverity
  -> Document.DiagnosticCategory
  -> Text
  -> Text
  -> Maybe Source.SourceSpan
  -> Document.Diagnostic
diag severity category code message =
  Document.mkDiagnostic severity category (fromMaybe fallbackCode (Document.mkDiagnosticCode code)) message

spanOf :: Int -> Int -> Maybe Source.SourceSpan
spanOf = Source.sourceSpanFromInts

containerFailure :: ContainerError -> Document.Diagnostic
containerFailure failure =
  case failure of
    InvalidUtf8 ->
      diag Document.DiagnosticError Document.SyntaxMalformed "deck.utf8" "the deck is not valid UTF-8; it stays read-only" Nothing
    UnclosedFrontmatter _ ->
      diag Document.DiagnosticError Document.SyntaxMalformed "deck.frontmatter.unclosed" "the frontmatter is not closed by a line containing only ---" Nothing
    InvalidSlideId line raw ->
      diag Document.DiagnosticError Document.SyntaxMalformed "deck.slide.id" ("line " <> Text.pack (show line) <> ": " <> raw <> " is not a valid slide id (use a-z, 0-9 and -)") Nothing
    DuplicateSlideId line raw ->
      diag Document.DiagnosticError Document.SyntaxMalformed "deck.slide.duplicate" ("line " <> Text.pack (show line) <> ": slide id " <> raw <> " is used twice") Nothing
    InvalidSectionId line raw ->
      diag Document.DiagnosticError Document.SyntaxMalformed "deck.section.id" ("line " <> Text.pack (show line) <> ": " <> raw <> " is not a valid section id (use a-z, 0-9 and -)") Nothing
    DuplicateSectionId line raw ->
      diag Document.DiagnosticError Document.SyntaxMalformed "route.duplicate-section" ("line " <> Text.pack (show line) <> ": section id " <> raw <> " is used twice") Nothing

levelSeverity :: Flow.DiagnosticLevel -> Document.DiagnosticSeverity
levelSeverity Flow.LevelInfo = Document.DiagnosticInformation
levelSeverity Flow.LevelWarning = Document.DiagnosticWarning

-- | Map a flow diagnostic to a byte span: the line (one-based, relative to the
-- flow) in a text that begins at the given byte offset.
flowDiagnostic :: Int -> Text -> Flow.FlowDiagnostic -> Document.Diagnostic
flowDiagnostic base text d =
  let ls = lineStarts text
      line = Flow.flowDiagnosticLine d
      location =
        case drop (max 0 (line - 1)) ls of
          (offset, l) : _ ->
            spanOf (base + offset) (base + offset + lengthWord8 (Text.dropWhileEnd (\c -> c == '\n' || c == '\r') l))
          [] -> spanOf base (base + lengthWord8 text)
   in diag
        (levelSeverity (Flow.flowDiagnosticLevel d))
        (categoryOf (Flow.flowDiagnosticCode d))
        (Flow.flowDiagnosticCode d)
        (Flow.flowDiagnosticMessage d)
        location

categoryOf :: Text -> Document.DiagnosticCategory
categoryOf code
  | "unsupported" `Text.isInfixOf` code || "unknown" `Text.isInfixOf` code = Document.SyntaxUnsupported
  | "cite" `Text.isInfixOf` code || "ref" `Text.isInfixOf` code = Document.ReferenceMissing
  | otherwise = Document.SyntaxMalformed

------------------------------------------------------------------------------
-- Building

rule :: Text -> Maybe Document.ProjectionRule
rule = Document.mkProjectionRule

originOver :: Text -> Maybe Source.SourceSpan -> Document.Origin
originOver name location =
  case (rule name, location) of
    (Just r, Just s) -> Document.DerivedBy r (s :| [])
    (_, s) -> Document.ReadOnly Document.OpaqueSource s

direct :: Text -> Maybe Source.SourceSpan -> Document.Origin
direct name location =
  case (rule name, location) of
    (Just r, Just s) -> Document.DirectSlot s r
    (_, s) -> Document.ReadOnly Document.MissingInverseRule s

data Built = Built
  { builtSlide :: !DeckSlide
  , builtFrame :: !Presentation.Frame
  , builtProvenance :: ![(MarkdownKey, Document.Origin)]
  }

build
  :: DeckConfig
  -> Source.SourceBufferSnapshot
  -> Container
  -> Either Document.Diagnostic (MarkdownDeck, Document.ProvenanceMap MarkdownKey, [Document.Diagnostic])
build config _source container = do
  let frontmatter = containerFrontmatter container
      frontSpan = case containerFrontmatterSpan container of Span a b -> spanOf a b
      entries = containerSlides container
      explicit = Set.fromList (mapMaybe slideIdText entries)
      (themeValue, themeNote) = resolveTheme config frontmatter
      aspectResult = maybe (Right (Aspect 16 9)) frontmatterAspect frontmatter
      aspectNote =
        case aspectResult of
          Left raw -> [diag Document.DiagnosticWarning Document.SyntaxMalformed "deck.aspect" ("aspect " <> raw <> " is not W:H; using 16:9") frontSpan]
          Right _ -> []
      Aspect aw ah = either (const (Aspect 16 9)) id aspectResult
      width = fromIntegral aw :: Natural
      height = fromIntegral ah :: Natural
      unknownNotes =
        [ diag Document.DiagnosticInformation Document.SyntaxUnsupported "deck.frontmatter.unknown" ("unknown frontmatter key " <> k <> " is kept") frontSpan
        | Just fm <- [frontmatter]
        , k <- unknownKeys fm
        ]
  size <-
    maybe
      (Left (diag Document.DiagnosticError Document.SyntaxMalformed "deck.aspect" "the aspect ratio gives no usable slide size" frontSpan))
      Right
      (Flow.slideSizeFor width height)
  let (preludeNodes, preludeIssues) =
        Flow.parsePrelude
          (Flow.defaultPrelude <> "\n" <> fromMaybe "" (frontmatter >>= frontmatterLookup "preamble"))
      preludeNotes =
        [ diag (levelSeverity (Flow.flowDiagnosticLevel d)) Document.SyntaxMalformed (Flow.flowDiagnosticCode d) ("preamble: " <> Flow.flowDiagnosticMessage d) frontSpan
        | d <- preludeIssues
        ]
      titleText = headline container frontmatter
      hasTitleSlide = maybe False (const True) frontmatter && maybe False (not . Text.null) titleText
      reserved = if hasTitleSlide then Set.insert titleSlideId explicit else explicit
      assigned = assignIds reserved entries
      env = Env themeValue size preludeNodes (configHandlePrefix config)
  titleParts <-
    if hasTitleSlide
      then (: []) <$> buildTitle env frontSpan frontmatter (fromMaybe "" titleText)
      else Right []
  slideBuilts <- traverse (buildSlideEntry env) assigned
  let withDividers = case frontmatter >>= frontmatterLookup "sectionSlides" of
        Just v -> Text.toLower (Text.strip v) /= "false"
        Nothing -> True
      sectionList0 = sectionsOf assigned (containerSections container)
      taken = Set.union reserved (Set.fromList [i | (i, _, _) <- assigned])
      dividerIds = mintDividers taken [(deckSectionId sec, sectionNoDivider e) | (sec, e) <- zip sectionList0 (containerSections container), withDividers]
      sectionList = [sec {deckSectionDivider = lookup (deckSectionId sec) dividerIds} | sec <- sectionList0]
  dividerBuilts <-
    traverse
      (\(sec, e) -> traverse (buildDivider env sec e) (lookup (deckSectionId sec) dividerIds))
      (zip sectionList (containerSections container))
  let dividerAt = [(sectionSlidesBefore e, built) | (e, Just built) <- zip (containerSections container) dividerBuilts]
      slideCount = length slideBuilts
      interleaved =
        concat [[b | (n, b) <- dividerAt, n == i] <> [sb] | (i, sb) <- zip [0 ..] slideBuilts]
          <> [b | (n, b) <- dividerAt, n >= slideCount]
      allBuilt = titleParts <> interleaved
      sectionEntries = containerSections container
      deckIncludesList =
        [ DeckInclude
            { deckIncludeLine = includeLine inc
            , deckIncludeSpan = let Span a b = includeLineSpan inc in spanOf a b
            , deckIncludeFramesBefore =
                length titleParts
                  + min slideCount (includeSlidesBefore inc)
                  + length
                    [ ()
                    | (e, _) <- dividerEntries
                    , let Span a0 _ = sectionSpan e
                    , sectionSlidesBefore e < includeSlidesBefore inc || (sectionSlidesBefore e == includeSlidesBefore inc && a0 < incStart)
                    ]
            , deckIncludeSection =
                case [deckSectionId sec | (sec, e) <- zip sectionList sectionEntries, let Span a _ = sectionSpan e, a < incStart] of
                  [] -> Nothing
                  ids -> Just (last ids)
            }
        | inc <- containerIncludes container
        , let Span incStart _ = includeSpan inc
        ]
      dividerEntries = [(e, built) | (e, Just built) <- zip sectionEntries dividerBuilts]
  frames <- case NonEmpty.nonEmpty (fmap builtFrame allBuilt) of
    Nothing -> Left (diag Document.DiagnosticError Document.SyntaxMalformed "deck.empty" "the deck has no slides; add a ## heading" Nothing)
    Just ne -> Right ne
  presentation <-
    either
      (Left . flowFailure frontSpan)
      Right
      (PFlow.deckPresentation (fromMaybe "" (frontmatter >>= frontmatterLookup "title")) (width, height) themeValue frames)
  let frameSlides = fmap builtSlide allBuilt
      slides = [x | x <- frameSlides, not (deckSlideIsDivider x)]
      provenance = Document.provenanceFromList (concatMap builtProvenance allBuilt)
      diagnostics = unknownNotes <> aspectNote <> themeNote <> preludeNotes <> concatMap deckSlideDiagnostics slides
  Right
    ( MarkdownDeck presentation slides frameSlides frontmatter (frontmatter >>= frontmatterLookup "theme") sectionList deckIncludesList (maybe [] frontmatterRoutes frontmatter)
    , provenance
    , diagnostics
    )

-- | Sections with their slide ids: a section holds the slides from its
-- position up to the next section.
sectionsOf :: [(Text, Bool, SlideEntry)] -> [SectionEntry] -> [DeckSection]
sectionsOf assigned entries = go Set.empty entries
  where
    slideIds = [identity | (identity, _, _) <- assigned]
    explicit = Set.fromList (mapMaybe sectionIdText entries)
    go _ [] = []
    go used (entry : rest) =
      let (identity, isExplicit) = case sectionIdText entry of
            Just i -> (i, True)
            Nothing -> (fresh (Set.union used explicit) (slug (sectionTitleText entry)) (1 :: Int), False)
          upto = case rest of
            next : _ -> sectionSlidesBefore next
            [] -> length slideIds
          Span hs he = sectionHeadingSpan entry
          Span ss se = sectionSpan entry
       in DeckSection
            { deckSectionId = identity
            , deckSectionExplicitId = isExplicit
            , deckSectionTitle = sectionTitleText entry
            , deckSectionSpan = spanOf ss se
            , deckSectionHeadingSpan = spanOf hs he
            , deckSectionSlides = take (upto - sectionSlidesBefore entry) (drop (sectionSlidesBefore entry) slideIds)
            , deckSectionDivider = Nothing
            }
            : go (Set.insert identity used) rest
    fresh used base n =
      let candidate = if n == 1 then base else base <> "-" <> Text.pack (show n)
       in if Set.member candidate used then fresh used base (n + 1) else candidate
    slug t =
      let s = Text.intercalate "-" (Text.words (Text.map (\c -> if isAsciiLower c || isDigit c then c else ' ') (Text.toLower t)))
       in if Text.null s then "section" else s

-- | Divider ids @section-<id>@, unique among every id in the deck.
mintDividers :: Set.Set Text -> [(Text, Bool)] -> [(Text, Text)]
mintDividers used0 = go used0
  where
    go _ [] = []
    go used ((sid, off) : rest)
      | off = go used rest
      | otherwise =
          let pick n =
                let c = if n == (1 :: Int) then "section-" <> sid else "section-" <> sid <> "-" <> Text.pack (show n)
                 in if Set.member c used then pick (n + 1) else c
              ident = pick 1
           in (sid, ident) : go (Set.insert ident used) rest

-- | The chapter page of a section: its title, and any text under the heading as a subtitle.
buildDivider :: Env -> DeckSection -> SectionEntry -> Text -> Either Document.Diagnostic Built
buildDivider env sec entry identity = do
  let headingSpan = deckSectionHeadingSpan sec
      origin = originOver "flow.title" headingSpan
      ctx = Flow.FlowContext origin (envPrelude env) (envHandlePrefix env <> identity)
      subtitle = Text.unwords [Text.strip l | l <- Text.lines (sectionBodyText entry), not (Text.null (Text.strip l)), not ("```" `Text.isPrefixOf` Text.strip l)]
      parts =
        (Flow.TitleRegion, Flow.loweredContent (Flow.lowerInlineText ctx (deckSectionTitle sec)))
          : [(Flow.SubtitleRegion, Flow.loweredContent (Flow.lowerInlineText ctx subtitle)) | not (Text.null subtitle)]
      entries = Flow.regionNodes (envTheme env) (envSize env) True parts
  frame <- frameFor headingSpan identity (deckSectionTitle sec) entries []
  Right
    Built
      { builtSlide =
          DeckSlide
            { deckSlideId = identity
            , deckSlideExplicitId = False
            , deckSlideIsTitle = False
            , deckSlideTitle = deckSectionTitle sec
            , deckSlideTitleContent = let t = deckSectionTitle sec in Canvas.content [Canvas.TextRun (Canvas.CanvasProvenance Canvas.Markdown) t | not (Text.null t)]
            , deckSlideSpan = deckSectionSpan sec
            , deckSlideHeadingSpan = headingSpan
            , deckSlideIdSpan = Nothing
            , deckSlideBody = Canvas.content [Canvas.TextRun (Canvas.CanvasProvenance Canvas.Markdown) subtitle | not (Text.null subtitle)]
            , deckSlideNotes = Canvas.emptyContent
            , deckSlideResources = []
            , deckSlideIsDivider = True
            , deckSlideDiagnostics = []
            , deckSlidePicture = []
            }
      , builtFrame = frame
      , builtProvenance = [(SlideIdKey identity, generated headingSpan)]
      }

data Env = Env
  { envTheme :: !Canvas.Theme
  , envSize :: !Canvas.Size
  , envPrelude :: ![Ast.Node]
  , envHandlePrefix :: !Text
  }

flowFailure :: Show a => Maybe Source.SourceSpan -> a -> Document.Diagnostic
flowFailure location failure =
  diag Document.DiagnosticError Document.InternalInvariant "deck.presentation" ("the deck cannot form a presentation: " <> Text.pack (show failure)) location

-- | The deck headline: a @# Title@ line before the first slide wins over the
-- frontmatter title.
headline :: Container -> Maybe Frontmatter -> Maybe Text
headline container frontmatter =
  case [Text.strip (Text.drop 2 l) | l <- Text.lines (containerPreambleText container), "# " `Text.isPrefixOf` l] of
    t : _ | not (Text.null t) -> Just t
    _ -> frontmatter >>= frontmatterLookup "title"

resolveTheme :: DeckConfig -> Maybe Frontmatter -> (Canvas.Theme, [Document.Diagnostic])
resolveTheme config frontmatter =
  case frontmatter >>= frontmatterLookup "theme" of
    Nothing -> (Canvas.defaultTheme, [])
    Just name ->
      case configResolveTheme config name of
        Just theme -> (theme, [])
        Nothing ->
          ( Canvas.defaultTheme
          , [diag Document.DiagnosticInformation Document.CapabilityUnavailable "deck.theme.unresolved" ("theme " <> name <> " is not available here; the default theme is used") Nothing]
          )

-- | Give every slide an id: its own, or the first unused @slide-N@.
assignIds :: Set.Set Text -> [SlideEntry] -> [(Text, Bool, SlideEntry)]
assignIds reserved = go reserved (1 :: Int)
  where
    go _ _ [] = []
    go used n (entry : rest) =
      case slideIdText entry of
        Just identity -> (identity, True, entry) : go used n rest
        Nothing ->
          let (candidate, n') = fresh used n
           in (candidate, False, entry) : go (Set.insert candidate used) n' rest
    fresh used n =
      let candidate = "slide-" <> Text.pack (show n)
       in if Set.member candidate used then fresh used (n + 1) else (candidate, n + 1)

frameFor
  :: Maybe Source.SourceSpan
  -> Text
  -> Text
  -> [Canvas.LayerEntry]
  -> [Canvas.LayerEntry]
  -> Either Document.Diagnostic Presentation.Frame
frameFor location identity title audience notes = do
  frameId <- either (const (Left (diag Document.DiagnosticError Document.SyntaxMalformed "deck.slide.id" ("slide id " <> identity <> " is unusable") location))) Right (Presentation.mkFrameId identity)
  either (Left . flowFailure location) Right (PFlow.slideFrame frameId title audience notes)

generated :: Maybe Source.SourceSpan -> Document.Origin
generated (Just s) = Document.GeneratedAt s
generated Nothing = Document.ReadOnly Document.DerivedValue Nothing

buildTitle
  :: Env
  -> Maybe Source.SourceSpan
  -> Maybe Frontmatter
  -> Text
  -> Either Document.Diagnostic Built
buildTitle env frontSpan frontmatter titleText = do
  let origin = originOver "flow.title" frontSpan
      ctx = Flow.FlowContext origin (envPrelude env) (envHandlePrefix env <> titleSlideId)
      field key = frontmatter >>= frontmatterLookup key
      part region value = (region,) . Flow.loweredContent . Flow.lowerInlineText ctx <$> value
      parts =
        [ Just (Flow.TitleRegion, Flow.loweredContent (Flow.lowerInlineText ctx titleText))
        , part Flow.SubtitleRegion (field "subtitle")
        , part Flow.AuthorsRegion (field "authors")
        , part Flow.InstituteRegion (field "institute")
        , part Flow.DateRegion (field "date")
        ]
      entries = Flow.regionNodes (envTheme env) (envSize env) True (catMaybes' parts)
  frame <- frameFor frontSpan titleSlideId titleText entries []
  Right
    Built
      { builtSlide =
          DeckSlide
            { deckSlideId = titleSlideId
            , deckSlideExplicitId = False
            , deckSlideIsTitle = True
            , deckSlideTitle = titleText
            , deckSlideTitleContent = let t = titleText in Canvas.content [Canvas.TextRun (Canvas.CanvasProvenance Canvas.Markdown) t | not (Text.null t)]
            , deckSlideSpan = frontSpan
            , deckSlideHeadingSpan = Nothing
            , deckSlideIdSpan = Nothing
            , deckSlideBody = Canvas.emptyContent
            , deckSlideNotes = Canvas.emptyContent
            , deckSlideResources = []
            , deckSlideIsDivider = False
            , deckSlideDiagnostics = []
            , deckSlidePicture = []
            }
      , builtFrame = frame
      , builtProvenance =
          [ (SlideIdKey titleSlideId, generated frontSpan)
          , (SlideTitleKey titleSlideId, originOver "frontmatter.title" frontSpan)
          ]
      }
  where
    catMaybes' = mapMaybe id

-- | A block with its line (one-based) and byte offset within the body.
data Located = Located !Int !Int !Block.Block

locate :: [Block.Block] -> [Located]
locate = go 1 0
  where
    go _ _ [] = []
    go line offset (b : rest) =
      let printed = Block.printBlock b
       in Located line offset b : go (line + length (Block.splitLinesKeep printed)) (offset + lengthWord8 printed) rest

fencesOf :: Text -> [Located] -> [(Int, Int, Text)]
fencesOf language blocks =
  [ (line + 1, offset + lengthWord8 (Block.fenceOpen f), Block.fenceBody f)
  | Located line offset (Block.FenceBlock f) <- blocks
  , Block.fenceLanguage (Block.fenceInfo f) == language
  ]

buildSlideEntry :: Env -> (Text, Bool, SlideEntry) -> Either Document.Diagnostic Built
buildSlideEntry env (identity, explicitId, entry) = do
  let Span bodyStart bodyEnd = slideBodySpan entry
      Span headStart headEnd = slideHeadingSpan entry
      wholeSpan = case slideSpan entry of Span a b -> spanOf a b
      headingSpan = spanOf headStart headEnd
      bodySpan = spanOf bodyStart bodyEnd
      bodyText = slideBodyText entry
      flow = Block.readFlow bodyText
      located = locate (Block.flowBlocks flow)
      origin = originOver "flow.body" bodySpan
      ctx = Flow.FlowContext origin (envPrelude env) (envHandlePrefix env <> identity)
      titleLowered = Flow.lowerInlineText ctx (slideTitleText entry)
      bodyLowered = Flow.lowerFlow ctx flow
      pictureFences = fencesOf "slide" located
      noteFences = fencesOf "notes" located
      pictureText = Text.concat [t | (_, _, t) <- pictureFences]
      noteText = Text.concat [t | (_, _, t) <- noteFences]
      (pictureEntries, pictureNotes, pictureResources) =
        case pictureFences of
          (line, _, _) : _ -> Flow.pictureEntries ctx line pictureText
          [] -> ([], [], [])
      pictureItemsOf = case pictureFences of
        (line, _, _) : _ -> Flow.pictureItems ctx line pictureText
        [] -> []
      notesLowered = Flow.lowerFlow ctx (Block.readFlow noteText)
      pictureBase = case pictureFences of (_, o, _) : _ -> bodyStart + o; [] -> bodyStart
      notesBase = case noteFences of (_, o, _) : _ -> bodyStart + o; [] -> bodyStart
      audience =
        Flow.regionNodes
          (envTheme env)
          (envSize env)
          False
          [(Flow.TitleRegion, Flow.loweredContent titleLowered), (Flow.BodyRegion, Flow.loweredContent bodyLowered)]
          <> pictureEntries
      noteEntries =
        Flow.regionNodes (envTheme env) (envSize env) False [(Flow.NotesRegion, Flow.loweredContent notesLowered)]
      diagnostics =
        fmap (flowDiagnostic bodyStart bodyText) (Flow.loweredDiagnostics bodyLowered)
          <> fmap (flowDiagnostic pictureBase pictureText) pictureNotes
          <> fmap (flowDiagnostic notesBase noteText) (Flow.loweredDiagnostics notesLowered)
          <> fmap (relocate headingSpan) (Flow.loweredDiagnostics titleLowered)
  frame <- frameFor wholeSpan identity (slideTitleText entry) audience noteEntries
  let notesPresent = not (null noteFences)
  Right
    Built
      { builtSlide =
          DeckSlide
            { deckSlideId = identity
            , deckSlideExplicitId = explicitId
            , deckSlideIsTitle = False
            , deckSlideTitle = slideTitleText entry
            , deckSlideTitleContent = Flow.loweredContent titleLowered
            , deckSlideSpan = wholeSpan
            , deckSlideHeadingSpan = headingSpan
            , deckSlideIdSpan = slideIdSpan entry >>= \(Span a b) -> spanOf a b
            , deckSlideBody = Flow.loweredContent bodyLowered
            , deckSlideNotes = Flow.loweredContent notesLowered
            , deckSlideResources = Flow.loweredResources bodyLowered <> pictureResources <> Flow.loweredResources notesLowered
            , deckSlideIsDivider = False
            , deckSlideDiagnostics = diagnostics
            , deckSlidePicture = pictureItemsOf
            }
      , builtFrame = frame
      , builtProvenance =
          [ ( SlideIdKey identity
            , if explicitId
                then direct "slide.id" (slideIdSpan entry >>= \(Span a b) -> spanOf a b)
                else generated headingSpan
            )
          , (SlideTitleKey identity, originOver "slide.title" headingSpan)
          , (SlideBodyKey identity, origin)
          ]
            <> [(SlideNotesKey identity, originOver "flow.notes" bodySpan) | notesPresent]
      }
  where
    relocate location d =
      diag
        (levelSeverity (Flow.flowDiagnosticLevel d))
        (categoryOf (Flow.flowDiagnosticCode d))
        (Flow.flowDiagnosticCode d)
        (Flow.flowDiagnosticMessage d)
        location
