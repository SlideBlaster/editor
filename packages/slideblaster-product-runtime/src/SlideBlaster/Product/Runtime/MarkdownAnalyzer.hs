{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.MarkdownAnalyzer
-- Description : The production 'Analyzer': the deck package's Markdown reader.
--
-- Adapts "SlideBlaster.Deck.Markdown" (container reader and flow desugaring)
-- and "SlideBlaster.Deck.Edit" (verified structural writers) to the session
-- seam. Slide spans are exact byte ranges from the reader; figure resources
-- are joined to block-render requests by their deterministic handles.
module SlideBlaster.Product.Runtime.MarkdownAnalyzer
  ( markdownAnalyzer
  ) where

import SlideBlaster.Canvas
  ( ContainerKind (GenericContainer)
  , ContentNode (..)
  , Dialect (Markdown)
  , Provenance (CanvasProvenance)
  , content
  , contentNodes
  , defaultTheme
  , sourceRef
  )
import SlideBlaster.Cite (CitationStyle (..), parseCitationStyle, readBibliography)
import SlideBlaster.Canvas.Flow (FlowResource (..), ResourceKind (..))
import SlideBlaster.Canvas.Flow qualified as Flow
import SlideBlaster.Deck.Edit (newSlideAfter)
import SlideBlaster.Deck.PictureEdit (PictureOp, pictureEditMessage)
import SlideBlaster.Deck.PictureEdit qualified as PictureEdit
import SlideBlaster.Deck.Frontmatter (frontmatterLookup)
import SlideBlaster.Deck.Include (IncludeLine (..), childKeyOf, deckSuffix, joinKey, keyDirectory, keyToRelative, normalizeKey, optionList, optionName)
import SlideBlaster.Deck.Markdown
  ( DeckSlide (..)
  , WrittenText (..)
  , MarkdownDeck (..)
  , DeckSection (..)
  , DeckInclude (..)
  , DeckConfig (..)
  , MarkdownDeckDocument
  , analyzeMarkdownDeck
  , analyzeMarkdownDeckWith
  , defaultDeckConfig
  )
import SlideBlaster.Document qualified as Document
import SlideBlaster.Presentation.Route qualified as Route
import SlideBlaster.Product.Runtime.Analysis
import SlideBlaster.Product.Runtime.Lower (contentRoutes)
import SlideBlaster.Product.Runtime.MathMacros (expandMathIn, parseMathMacros)
import SlideBlaster.Product.Runtime.Picture (expandNodeStyles, libraryStyles, optionKeys, preambleColours)
import SlideBlaster.Product.Runtime.Citations (Resolved (..), resolveCitations)
import SlideBlaster.Product.Runtime.SlidePlan (FrameInput (..), TitleFields (..))
import SlideBlaster.Source qualified as Source

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List (nub, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe, maybeToList)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.Read qualified as TextRead

-- | Analyzer backed by the alpha Markdown deck reader.
markdownAnalyzer :: Analyzer
markdownAnalyzer = Analyzer {analyzeDeck = analyse, insertSlideAfter = insertAfter, editPicture = editPictureOf}

analyse :: Map Text ByteString -> Text -> ByteString -> Analysis
analyse files entry bytes
  | pictureEntry entry =
      -- A picture file opened on its own: one slide whose picture is the file,
      -- with every span counted in the file's own bytes.
      let (wrapped, lead, _) = pictureWrap entry bytes
          whole = analyseWith (Ctx "" [entry] "" []) files wrapped
          size = ByteString.length bytes
          back n = max 0 (min size (n - lead))
          own frame =
            frame
              { frameSpan = (0, size)
              , frameScene =
                  (frameScene frame)
                    { frameInputPicture = fmap (Flow.shiftPictureItem (negate lead)) (frameInputPicture (frameScene frame))
                    , frameInputWritten = []
                    }
              }
       in whole
            { analysisFrames = [own frame | frame <- analysisFrames whole, frameKey frame == pictureFrame]
            , analysisDiagnostics = [item {diagnosticSpan = fmap (\(a, b) -> (back a, back b)) (diagnosticSpan item)} | item <- analysisDiagnostics whole]
            }
  | otherwise = analyseWith (Ctx "" [entry] "" []) files bytes

-- | The text of a project file named in a deck that sits in the given folder.
projectText :: Text -> Map Text ByteString -> Text -> Maybe Text
projectText dir files path = Encoding.decodeUtf8With (\_ _ -> Just '?') <$> Map.lookup (joinKey dir (Text.strip path)) files

-- | Whether an entry is a picture file (@.tikz@) rather than a deck.
pictureEntry :: Text -> Bool
pictureEntry = Text.isSuffixOf ".tikz"

-- | The id of the one slide a picture file is shown on.
pictureFrame :: Text
pictureFrame = "picture"

-- | A picture file read as a deck: the file is the picture block of one slide
-- titled with the file's name. Returns the deck, the length of what was put
-- before the file, and what was put after it.
pictureWrap :: Text -> ByteString -> (ByteString, Int, ByteString)
pictureWrap entry bytes =
  let name = Text.map (\c -> if c `elem` ("_#{}\\$%&^~*`<>[]" :: String) then ' ' else c) (last ("" : Text.splitOn "/" entry))
      prefix = Encoding.encodeUtf8 ("---\nslideblaster: 1\n---\n\n## " <> name <> " {#" <> pictureFrame <> "}\n\n```slide\n")
      suffix = (if ByteString.null bytes || "\n" `ByteString.isSuffixOf` bytes then "" else "\n") <> "```\n"
   in (prefix <> bytes <> suffix, ByteString.length prefix, suffix)

-- | Where a deck sits among the decks that include it.
data Ctx = Ctx
  { ctxDir :: !Text
  -- ^ the deck's folder key; its figure, image and bibliography paths resolve there
  , ctxStack :: ![Text]
  -- ^ deck keys from the top-level deck down to this one (cycle detection)
  , ctxHandlePrefix :: !Text
  , ctxBibs :: ![Text]
  -- ^ bibliographies of the including decks, nearest first
  }

analyseWith :: Ctx -> Map Text ByteString -> ByteString -> Analysis
analyseWith ctx files bytes =
  withIncludes ctx files (deckIncludes' document) ownBib (analyseOwn ctx files bytes document)
  where
    snapshot = Source.snapshotFromBytes bytes
    document = analyzeMarkdownDeckWith (DeckConfig (const (Just defaultTheme)) (ctxHandlePrefix ctx) (projectText (ctxDir ctx) files)) snapshot
    deckIncludes' d = maybe [] deckIncludes (Document.documentSemantic d)
    ownBib = case Document.documentSemantic document >>= deckFrontmatter of
      Just front -> bibTextOf ctx files (fromMaybe "" (frontmatterLookup "bibliography" front))
      Nothing -> Nothing

bibTextOf :: Ctx -> Map Text ByteString -> Text -> Maybe Text
bibTextOf ctx files path = Encoding.decodeUtf8With (\_ _ -> Just '?') <$> Map.lookup (joinKey (ctxDir ctx) (Text.strip path)) files

analyseOwn :: Ctx -> Map Text ByteString -> ByteString -> MarkdownDeckDocument -> Analysis
analyseOwn ctx files bytes document =
  case Document.documentSemantic document of
    Nothing ->
      Analysis
        { analysisTitle = ""
        , analysisTheme = "default"
        , analysisFrames = []
        , analysisDiagnostics = documentItems
        , analysisFigures = []
        , analysisImages = []
        , analysisReady = False
        , analysisSections = []
        , analysisSubsections = []
        , analysisRoutes = []
        }
    Just deck ->
      let slides = deckFrames deck
          front = deckFrontmatter deck
          lookupFront key = fromMaybe "" (front >>= frontmatterLookup key)
          preamble = Encoding.encodeUtf8 (lookupFront "preamble")
          cited = citeFrames (maybeToList (bibTextOf ctx files (lookupFront "bibliography")) <> ctxBibs ctx) bytes lookupFront slides (fmap (frameOf (libraryStyles (projectText "" files)) lookupFront) slides)
          sections = [Route.Section (deckSectionId s) (deckSectionTitle s) (maybe [] pure (deckSectionDivider s) <> deckSectionSlides s) | s <- deckSections deck]
          routes = deckRoutes deck
          choices = [(frameKey f, route) | f <- fst cited, (route, _) <- contentRoutes (contentNodes (frameInputBody (frameScene f)))]
          routeItems = routeDiagnostics frontSpan (routeLineSpan bytes) sections routes choices
          frontSpan = Just (0, frontmatterEnd bytes)
       in Analysis
            { analysisTitle = lookupFront "title"
            , analysisTheme = fromMaybe "default" (deckThemeName deck)
            , analysisFrames = fst cited
            , analysisDiagnostics = nub (documentItems <> concatMap slideItems slides <> snd cited <> routeItems)
            , analysisFigures = concatMap (figuresOf (ctxDir ctx) preamble) slides
            , analysisImages = concatMap (imagesOf (ctxDir ctx)) slides
            , analysisReady = True
            , analysisSections = sections
            , analysisSubsections = []
            , analysisRoutes = routes
            }
  where
    documentItems = fmap (diagnosticItem Nothing) (Document.documentDiagnostics document)
    slideItems slide = fmap (diagnosticItem (Just (deckSlideId slide))) (deckSlideDiagnostics slide)

-- Byte offset just past the frontmatter's closing @---@ line (0 when there is none).
frontmatterEnd :: ByteString -> Int
frontmatterEnd bytes
  | "---\n" `ByteString.isPrefixOf` bytes =
      let (before, after) = ByteString.breakSubstring "\n---" (ByteString.drop 3 bytes)
       in if ByteString.null after then 0 else min (ByteString.length bytes) (3 + ByteString.length before + 4 + maybe 0 (+ 1) (ByteString.elemIndex 10 (ByteString.drop (3 + ByteString.length before + 4) bytes)))
  | otherwise = 0

-- The span of the frontmatter line that defines a route (@  name:@).
routeLineSpan :: ByteString -> Text -> Maybe (Int, Int)
routeLineSpan bytes name =
  case [(start, end) | (start, end, line) <- numbered, Text.stripStart line `startsWithName` name] of
    span' : _ -> Just span'
    [] -> Nothing
  where
    limit = frontmatterEnd bytes
    region = ByteString.take limit bytes
    numbered = go 0 (ByteString.split 10 region)
    go _ [] = []
    go offset (l : rest) = (offset, offset + ByteString.length l, Encoding.decodeUtf8With (\_ _ -> Just '?') l) : go (offset + ByteString.length l + 1) rest
    startsWithName line n = (n <> ":") `Text.isPrefixOf` line

-- Resolve citations against the deck's bibliography file (frontmatter
-- @bibliography:@, @citation-style:@), fill footers and the reference list.
citeFrames :: [Text] -> ByteString -> (Text -> Text) -> [DeckSlide] -> [AnalyzedFrame] -> ([AnalyzedFrame], [DiagnosticItem])
citeFrames bibTexts deckBytes lookupFront slides frames =
  (zipWith apply frames resolvedFrames, unknown <> missing)
  where
    -- citations inside picture nodes are resolved with the body's, in reading
    -- order: each node's content rides along in a marked container and is
    -- taken back out afterwards
    marker = "picture-node:"
    bodies =
      [ content
          ( contentNodes (frameInputBody scene)
              <> [ TransparentContainer (CanvasProvenance Markdown) (GenericContainer (marker <> Text.pack (show i))) (Flow.pictureNodeContent n)
                 | (i, Flow.PictureNodeItem n) <- zip [0 :: Int ..] (frameInputPicture scene)
                 ]
          )
      | scene <- fmap frameScene frames
      ]
    style = fromMaybe NumericStyle (parseCitationStyle (lookupFront "citation-style"))
    path = Text.strip (lookupFront "bibliography")
    -- the deck's own bibliography first, then those of the decks that include it
    bibliography = fst (readBibliography (Text.intercalate "\n" bibTexts))
    Resolved resolvedFrames unknownKeys = resolveCitations style bibliography bodies
    apply frame (body, footer) =
      let scene = frameScene frame
          carried = [(name, kids) | TransparentContainer _ (GenericContainer name) kids <- contentNodes body, marker `Text.isPrefixOf` name]
          own = [n | n <- contentNodes body, not (isCarried n)]
          isCarried n = case n of
            TransparentContainer _ (GenericContainer name) _ -> marker `Text.isPrefixOf` name
            _ -> False
          picture =
            [ case item of
                Flow.PictureNodeItem node -> maybe item (\kids -> Flow.PictureNodeItem node {Flow.pictureNodeContent = kids}) (lookup (marker <> Text.pack (show i)) carried)
                other -> other
            | (i, item) <- zip [0 :: Int ..] (frameInputPicture scene)
            ]
       in frame {frameScene = scene {frameInputBody = content own, frameInputFooter = footer, frameInputPicture = picture}}
    missing =
      [ DiagnosticItem "warning" "cite.no-bibliography" ("bibliography file not found: " <> (if Text.null path then "(no bibliography: in the frontmatter)" else path)) Nothing Nothing
      | null bibTexts
      , not (null unknownKeys)
      ]
    unknown =
      [ DiagnosticItem "warning" "cite.unknown-key" ("unknown citation key: " <> key) (keySpan slide key) (Just (deckSlideId slide))
      | (index, key) <- unknownKeys
      , slide <- take 1 (drop index slides)
      ]
    keySpan slide key = do
      sp <- deckSlideSpan slide
      let (start, end) = spanPair sp
          region = ByteString.take (end - start) (ByteString.drop start deckBytes)
          needle = Encoding.encodeUtf8 key
          (before, after) = ByteString.breakSubstring needle region
      if ByteString.null after
        then Just (start, end)
        else Just (start + ByteString.length before, start + ByteString.length before + ByteString.length needle)

-- The first argument gives the definitions of the library styles an option list uses.
frameOf :: (Text -> Text) -> (Text -> Text) -> DeckSlide -> AnalyzedFrame
frameOf library lookupFront slide =
  let macros = parseMathMacros (lookupFront "preamble")
      mapContent c = content (fmap (expandMathIn macros) (contentNodes c))
      expandPicture item = case item of
        Flow.PictureNodeItem node ->
          Flow.PictureNodeItem
            node
            { Flow.pictureNodeContent = fmap (expandMathIn macros) (Flow.pictureNodeContent node)
            , -- named styles (title, body, note, the deck's own \tikzset) stand for their options
              Flow.pictureNodeOptions = expandNodeStyles (lookupFront "preamble" <> "\n" <> library (Flow.pictureNodeOptions node)) (Flow.pictureNodeOptions node)
            }
        other -> other
   in AnalyzedFrame
    { frameKey = deckSlideId slide
    , frameTitleText = deckSlideTitle slide
    , frameSpan = maybe (0, 0) spanPair (deckSlideSpan slide)
    , frameScene =
        FrameInput
          { frameInputId = deckSlideId slide
          , frameInputTitle = mapContent (deckSlideTitleContent slide)
          , frameInputBody = mapContent (deckSlideBody slide)
          , frameInputTitleSlide =
              if deckSlideIsDivider slide
                then Just (TitleFields (deckSlideTitle slide) (dividerSubtitle slide) "" "" "" True)
              else if deckSlideIsTitle slide
                then
                  Just
                    TitleFields
                      { titleFieldDivider = False
                      , titleFieldTitle = lookupFront "title"
                      , titleFieldSubtitle = lookupFront "subtitle"
                      , titleFieldAuthors = lookupFront "authors"
                      , titleFieldInstitute = lookupFront "institute"
                      , titleFieldDate = lookupFront "date"
                      }
                else Nothing
          , frameInputPicture = fmap expandPicture (deckSlidePicture slide)
          , frameInputColours = preambleColours (lookupFront "preamble")
          , frameInputWritten = [(writtenPart w, writtenStart w, writtenEnd w, writtenSource w, writtenBefore w, writtenAfter w) | w <- deckSlideWritten slide]
          , frameInputFooter = content []
          }
    , frameNotes = mapContent (deckSlideNotes slide)
    , frameOrigin = Nothing
    }

-- A divider's subtitle is the text under its section heading, kept as its body.
dividerSubtitle :: DeckSlide -> Text
dividerSubtitle slide = Text.concat [t | TextRun _ t <- contentNodes (deckSlideBody slide)]

spanPair :: Source.SourceSpan -> (Int, Int)
spanPair sp = (Source.unByteOffset (Source.sourceSpanStart sp), Source.unByteOffset (Source.sourceSpanEnd sp))

diagnosticItem :: Maybe Text -> Document.Diagnostic -> DiagnosticItem
diagnosticItem frame d =
  DiagnosticItem
    { diagnosticSeverity = case Document.diagnosticSeverity d of
        Document.DiagnosticError -> "error"
        Document.DiagnosticWarning -> "warning"
        Document.DiagnosticInformation -> "info"
    , diagnosticCode = Document.diagnosticCodeText (Document.diagnosticCode d)
    , diagnosticMessage = Document.diagnosticMessage d
    , diagnosticSpan = spanPair <$> Document.diagnosticSpan d
    , diagnosticFrame = frame
    }

figuresOf :: Text -> ByteString -> DeckSlide -> [FigureRequest]
figuresOf dir preamble slide = mapMaybe figure (deckSlideResources slide)
  where
    figure resource =
      case (resourceKind resource, sourceRef (resourceHandle resource)) of
        (TikzFile, Just ref) -> Just (request ref (Just (joinKey dir (resourceTarget resource))) ByteString.empty resource)
        (TikzInline, Just ref) -> Just (request ref Nothing (Encoding.encodeUtf8 (resourceTarget resource)) resource)
        _ -> Nothing
    request ref path body resource =
      FigureRequest
        { figureFrame = deckSlideId slide
        , figureRef = ref
        , figureKind = "tikz"
        , figureBody = body
        , figureInputPath = path
        , figurePreamble = preamble
        , figurePalette = []
        , figureWidth = 960
        , figureInputs = maybe [] pure path
        , figureFirstLine = resourceLine resource
        , figureUnits = widthOption (resourceOptions resource)
        }

imagesOf :: Text -> DeckSlide -> [ImageRequest]
imagesOf dir slide = mapMaybe image (deckSlideResources slide)
  where
    image resource =
      case (resourceKind resource, sourceRef (resourceHandle resource)) of
        (ImageFile, Just ref) ->
          Just
            ImageRequest
              { imageFrame = deckSlideId slide
              , imageRef = ref
              , imagePath = joinKey dir (resourceTarget resource)
              , imageUnits = widthOption (resourceOptions resource)
              , imageLine = resourceLine resource
              }
        _ -> Nothing

-- The @width=W@ entry of a raw @[..]@ option list, as slide units. A value
-- with a unit or macro suffix is not a plain number and is ignored.
widthOption :: Text -> Maybe Double
widthOption options =
  case [Text.strip (Text.drop 6 entry) | entry <- fmap Text.strip (Text.splitOn "," options), "width=" `Text.isPrefixOf` entry] of
    (value : _) -> case TextRead.double value of
      Right (w, rest) | w > 0, Text.null rest -> Just w
      _ -> Nothing
    [] -> Nothing

insertAfter :: ByteString -> Maybe Text -> Maybe (ByteString, Text)
insertAfter bytes after =
  case newSlideAfter defaultDeckConfig (Source.snapshotRevision snapshot) after (analyzeMarkdownDeck snapshot) of
    Right (document, identity) -> Just (Source.snapshotBytes (Document.documentSource document), identity)
    Left _ -> Nothing
  where
    snapshot = Source.snapshotFromBytes bytes

editPictureOf :: Map Text ByteString -> Text -> ByteString -> Text -> PictureOp -> Either Text (ByteString, [Text])
editPictureOf files entry bytes frame requested
  | pictureEntry entry = do
      -- edit the file as the picture block it is shown as, then take the file back out
      let (wrapped, lead, suffix) = pictureWrap entry bytes
      (edited, made) <- editDeckPicture files wrapped frame requested
      let inner = ByteString.drop lead edited
      if ByteString.take lead edited == ByteString.take lead wrapped && suffix `ByteString.isSuffixOf` inner
        then Right (ByteString.take (ByteString.length inner - ByteString.length suffix) inner, made)
        else Left "the edit reached outside the picture file"
  | otherwise = editDeckPicture files bytes frame requested

editDeckPicture :: Map Text ByteString -> ByteString -> Text -> PictureOp -> Either Text (ByteString, [Text])
editDeckPicture files bytes frame requested =
  case PictureEdit.editPicture config frame op document of
    Right (successor, made) -> Right (Source.snapshotBytes (Document.documentSource successor), made)
    Left failure -> Left (pictureEditMessage failure)
  where
    config = defaultDeckConfig {configReadFile = projectText "" files}
    document = analyzeMarkdownDeckWith config (Source.snapshotFromBytes bytes)
    deck = Document.documentSemantic document
    preamble = fromMaybe "" (deck >>= deckFrontmatter >>= frontmatterLookup "preamble")
    written item = listToMaybe' [Flow.pictureNodeOptions n | Just d <- [deck], s <- deckFrames d, deckSlideId s == frame, Flow.PictureNodeItem n <- deckSlidePicture s, Flow.pictureNodeId n == item]
    listToMaybe' xs = case xs of x : _ -> Just x; [] -> Nothing
    -- Taking a fill or border off a node whose named style supplies it means
    -- saying so: the option is written as @none@ rather than merely removed.
    op = case requested of
      PictureEdit.SetOptions item changes | Just options <- written item ->
        PictureEdit.SetOptions item (fmap (override options changes) changes)
      other -> other
    override options changes change = case change of
      PictureEdit.RemoveOption key
        | key `elem` ["fill", "draw"]
        , let next = PictureEdit.applyOptions changes options
        , key `elem` optionKeys (expandNodeStyles (preamble <> "\n" <> libraryStyles (projectText "" files) next) next) -> PictureEdit.SetOption key (Just "none")
      other -> other

------------------------------------------------------------------------------
-- Sub-presentations

-- | An included deck, renamed and ready to splice in.
data Spliced = Spliced
  { spliceKey :: !Text
  , spliceFrames :: ![AnalyzedFrame]
  , spliceSubsections :: ![Subsection]
  , spliceFigures :: ![FigureRequest]
  , spliceImages :: ![ImageRequest]
  }

-- | Splice the decks named by the @\\include@ lines into an analysis.
withIncludes :: Ctx -> Map Text ByteString -> [DeckInclude] -> Maybe Text -> Analysis -> Analysis
withIncludes _ _ [] _ analysis = analysis
withIncludes ctx files includes ownBib base
  | not (analysisReady base) = base
  | otherwise =
      base
        { analysisFrames = spliceAt [(deckIncludeFramesBefore inc, spliceFrames s) | (inc, _, Just s) <- resolved] (analysisFrames base)
        , analysisSections = fmap withChildren (analysisSections base)
        , analysisSubsections = concat [spliceSubsections s | (_, _, Just s) <- resolved]
        , analysisDiagnostics = nub (analysisDiagnostics base <> concat [ds | (_, ds, _) <- resolved])
        , analysisFigures = analysisFigures base <> concat [spliceFigures s | (_, _, Just s) <- resolved]
        , analysisImages = analysisImages base <> concat [spliceImages s | (_, _, Just s) <- resolved]
        }
  where
    resolved = go [] includes
    go _ [] = []
    go used (inc : rest) =
      let (diags, spliced) = includeOne ctx files ownBib used inc
       in (inc, diags, spliced) : go (maybe used (\s -> (spliceKey s, fmap frameKey (spliceFrames s)) : used) spliced) rest
    baseIndex = Map.fromList (zip (fmap frameKey (analysisFrames base)) [0 :: Int ..])
    -- a section's frames in order, the spliced slides in front of the first frame at or after the include
    withChildren sec =
      let own = [((Map.findWithDefault 0 k baseIndex, 1 :: Int), [k]) | k <- Route.sectionFrames sec]
          added =
            [ ((deckIncludeFramesBefore inc, 0), fmap frameKey (spliceFrames s))
            | (inc, _, Just s) <- resolved
            , deckIncludeSection inc == Just (Route.sectionId sec)
            ]
       in sec {Route.sectionFrames = concatMap snd (sortOn fst (own <> added))}

-- | Insert groups of frames before the frame at each index.
spliceAt :: [(Int, [a])] -> [a] -> [a]
spliceAt groups = go 0
  where
    go index items =
      concat [g | (n, g) <- groups, n == index]
        <> case items of
          [] -> []
          x : rest -> x : go (index + 1) rest

-- | Locate, analyse and rename one included deck: its diagnostics (at the
-- include line) and, when it could be included, its slides.
--
-- @used@ holds the decks already included, each with the slides taken from it.
-- A deck may be included again as long as no slide is taken twice (one include
-- with @skip={references}@, a later one with @only={references}@).
includeOne :: Ctx -> Map Text ByteString -> Maybe Text -> [(Text, [Text])] -> DeckInclude -> ([DiagnosticItem], Maybe Spliced)
includeOne ctx files ownBib used inc =
  case located of
    Left (code, message) -> ([problem "error" code message], Nothing)
    Right (deckKey, childName)
      | deckKey `elem` ctxStack ctx ->
          ([problem "error" "include.cycle" ("include cycle: " <> Text.intercalate " -> " (reverse (ctxStack ctx) <> [deckKey]))], Nothing)
      | otherwise ->
          case Map.lookup deckKey files of
            Nothing -> ([problem "error" "include.missing" ("included deck is not readable: " <> includePath line)], Nothing)
            Just childBytes ->
              let childCtx =
                    Ctx
                      { ctxDir = keyDirectory deckKey
                      , ctxStack = deckKey : ctxStack ctx
                      , ctxHandlePrefix = ctxHandlePrefix ctx <> "i_" <> childName <> "_"
                      , ctxBibs = maybeToList ownBib <> ctxBibs ctx
                      }
                  child = analyseWith childCtx files childBytes
               in if not (analysisReady child)
                    then
                      ( [ problem "error" "include.failed" ("included deck " <> childName <> " cannot be read" <> firstError child)
                        ]
                      , Nothing
                      )
                    else
                      let (spliced, notes) = rename childName deckKey child
                          earlier = concat [keys | (name, keys) <- used, name == childName]
                          twice = [k | k <- fmap frameKey (spliceFrames spliced), k `elem` earlier]
                       in case twice of
                            k : _ ->
                              ( [ problem "error" "include.duplicate" ("slide " <> k <> " is included twice (leave it out of one include with skip={..} or only={..}, or rename a folder)")
                                ]
                              , Nothing
                              )
                            [] -> (optionNotes <> idNotes child <> notes, Just spliced)
  where
    line = deckIncludeLine inc
    spanHere = spanPair <$> deckIncludeSpan inc
    problem severity code message = DiagnosticItem severity code message spanHere Nothing
    firstError child = case [diagnosticMessage d | d <- analysisDiagnostics child, diagnosticSeverity d == "error"] of
      m : _ -> ": " <> m
      [] -> ""
    options = includeOptions line
    optionNotes =
      [ problem "warning" "include.option" ("unknown include option " <> o <> " (known: titleslide, dividers, skip={ids}, only={ids})")
      | o <- options
      , o `notElem` ["titleslide", "dividers"]
      , not (optionName o `elem` ["skip", "only"] && "=" `Text.isInfixOf` o)
      ]
    skipped = fromMaybe [] (optionList "skip" options)
    only = optionList "only" options
    idNotes child =
      [ problem "warning" "include.option" ("no slide with id " <> k <> " in the included deck")
      | k <- nub (skipped <> fromMaybe [] only)
      , k `notElem` fmap frameKey (analysisFrames child)
      ]
    -- how many times this deck was included before: later ones get their own group names
    repeatOf childName = length [() | (name, _) <- used, name == childName]
    keepTitle = "titleslide" `elem` options
    keepDividers = "dividers" `elem` options
    located = locateDeck ctx files (includePath line)
    rename childName deckKey child =
      let ns k = childName <> "/" <> k
          isTitle f = case frameInputTitleSlide (frameScene f) of Just t -> not (titleFieldDivider t); Nothing -> False
          isDivider f = case frameInputTitleSlide (frameScene f) of Just t -> titleFieldDivider t; Nothing -> False
          left f = frameKey f `elem` skipped || maybe False (frameKey f `notElem`) only
          dropped = [frameKey f | f <- analysisFrames child, (isTitle f && not keepTitle) || (isDivider f && not keepDividers) || left f]
          -- group names: the deck's name, numbered when the deck is included again
          group k = case repeatOf childName of
            0 -> ns k
            n -> childName <> "." <> Text.pack (show (n + 1)) <> "/" <> k
          kept = [f | f <- analysisFrames child, frameKey f `notElem` dropped]
          origin = FrameOrigin childName (keyToRelative deckKey)
          rewrite f =
            f
              { frameKey = ns (frameKey f)
              , frameSpan = fromMaybe (0, 0) spanHere
              , frameScene = (frameScene f) {frameInputId = ns (frameKey f)}
              , frameOrigin = Just (fromMaybe origin (frameOrigin f))
              }
          keptKeys ks = [ns k | k <- ks, k `notElem` dropped]
          own = [Subsection (group (Route.sectionId s)) (Route.sectionTitle s) (deckIncludeSection inc) (keptKeys (Route.sectionFrames s)) childName | s <- analysisSections child]
          nested = [sub {subId = group (subId sub), subParent = maybe (deckIncludeSection inc) (Just . group) (subParent sub), subFrames = keptKeys (subFrames sub)} | sub <- analysisSubsections child]
          -- a group with no slide left (all skipped) is not shown
          every = own <> nested
          alive known =
            let next = [subId sub | sub <- every, not (null (subFrames sub)) || or [subParent c == Just (subId sub) | c <- every, subId c `elem` known]]
             in if next == known then known else alive next
          groups = [sub | sub <- every, subId sub `elem` alive []]
          figures = [r {figureFrame = ns (figureFrame r)} | r <- analysisFigures child, figureFrame r `notElem` dropped]
          images = [r {imageFrame = ns (imageFrame r)} | r <- analysisImages child, imageFrame r `notElem` dropped]
          notes =
            [ d {diagnosticMessage = "[" <> childName <> "] " <> diagnosticMessage d, diagnosticSpan = spanHere, diagnosticFrame = ns <$> diagnosticFrame d}
            | d <- analysisDiagnostics child
            , not ("route." `Text.isPrefixOf` diagnosticCode d)
            ]
       in (Spliced childName (fmap rewrite kept) groups figures images, notes)

-- | The deck file an include names: a @.slideBlaster.md@ file, or the single
-- one in a folder; with the name its slides are filed under.
locateDeck :: Ctx -> Map Text ByteString -> Text -> Either (Text, Text) (Text, Text)
locateDeck ctx files path
  | "/" `Text.isPrefixOf` path = Left ("include.missing", "absolute include paths are not supported: " <> path)
  | deckSuffix `Text.isSuffixOf` key && key `elem` known = Right (key, childKeyOf key)
  | otherwise =
      case nub candidates of
        [one] -> Right (one, childKeyOf key)
        [] -> Left ("include.missing", "no deck found at " <> path <> " (a folder with a " <> deckSuffix <> " file, or such a file)")
        many -> Left ("include.ambiguous", "more than one deck in " <> path <> ": " <> Text.intercalate ", " many)
  where
    key = normalizeKey (ctxDir ctx <> "/" <> path)
    known = Map.keys files <> ctxStack ctx
    folder = if Text.null key then "" else key <> "/"
    candidates =
      [ k
      | k <- known
      , Just rest <- [Text.stripPrefix folder k]
      , not (Text.null rest)
      , not ("/" `Text.isInfixOf` rest)
      , deckSuffix `Text.isSuffixOf` rest
      ]
