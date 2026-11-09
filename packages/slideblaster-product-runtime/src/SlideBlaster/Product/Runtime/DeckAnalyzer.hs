{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.DeckAnalyzer
-- Description : Milestone-W analyzer for @*.slideBlaster.md@ decks.
--
-- A deliberately small, line-oriented reader of the container grammar of
-- docs/architecture/alpha.md section 3.1 and the flow subset the walking
-- skeleton needs: frontmatter, @## Title {#id}@ slides, paragraphs, lists with
-- trailing overlay specs, @\\pause@, math, fenced code, @\\figure@, @tikz@
-- fences, @:::@ columns, @\\begin{block}@/@\\defn@ boxes and @notes@ fences.
-- It builds canvas content directly and never rewrites bytes: slide spans are
-- exact byte ranges, and the single structural edit (new slide) is one
-- insertion between spans. It is the seam's default implementation
-- ("default, revisitable"); the core-language lane's reader can replace it
-- behind the same 'Analyzer' record.
module SlideBlaster.Product.Runtime.DeckAnalyzer
  ( deckAnalyzer
  ) where

import SlideBlaster.Canvas
  ( ContainerKind (..)
  , ContentItem (..)
  , ContentNode (..)
  , DerivedState (..)
  , InlineMark (..)
  , ListKind (..)
  , MathKind (..)
  , OverlayDirective (..)
  , OverlayHook (..)
  , Provenance (..)
  , Dialect (..)
  , StepRange
  , citationKey
  , content
  , mkOverlayStep
  , singleStep
  , sourceRef
  , stepsBetween
  , stepsFrom
  , stepsThrough
  )
import SlideBlaster.Product.Runtime.Analysis
import SlideBlaster.Product.Runtime.SlidePlan (FrameInput (..), TitleFields (..))

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (digitToInt, isAlphaNum, isDigit, isSpace, toLower)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.Encoding.Error (lenientDecode)

-- | The W analyzer.
deckAnalyzer :: Analyzer
deckAnalyzer = Analyzer {analyzeDeck = analyse, insertSlideAfter = insertAfter}

prov :: Provenance
prov = CanvasProvenance Markdown

-- Exact byte accounting -----------------------------------------------------

data Line = Line
  { lineStart :: !Int
  , lineText :: !Text
  }

lineWidth :: Line -> Int
lineWidth l = ByteString.length (Encoding.encodeUtf8 (lineText l)) + 1

-- Split on '\n' keeping exact offsets. A final line without a newline is
-- over-counted by one byte; spans are clamped to the input length by callers.
linesOf :: ByteString -> [Line]
linesOf bytes = go 0 (Text.splitOn "\n" (Encoding.decodeUtf8With lenientDecode bytes))
  where
    go _ [] = []
    go offset [lastLine]
      | Text.null lastLine = []
      | otherwise = [Line offset lastLine]
    go offset (t : rest) = let l = Line offset t in l : go (offset + lineWidth l) rest

-- Frontmatter ---------------------------------------------------------------

data Front = Front
  { frontFields :: Map Text Text
  , frontEnd :: Int
  , frontBody :: [Line]
  , frontSpan :: (Int, Int)
  }

splitFront :: ByteString -> [Line] -> Front
splitFront bytes ls =
  case ls of
    (first : rest)
      | Text.stripEnd (lineText first) == "---"
      , (inside, closer : after) <- break (\l -> Text.stripEnd (lineText l) == "---") rest ->
          let end = lineStart closer + lineWidth closer
           in Front (fields inside) end after (0, min end (ByteString.length bytes))
    _ -> Front Map.empty 0 ls (0, 0)
  where
    fields = collect Map.empty
    collect acc [] = acc
    collect acc (l : more) =
      case Text.breakOn ":" (lineText l) of
        (key, rest')
          | not (Text.null rest') && not (Text.null key) && not (isSpace (Text.head key)) ->
              let value = Text.strip (Text.drop 1 rest')
               in if value == "|"
                    then
                      let (block, others) = span (\x -> Text.null (Text.strip (lineText x)) || isSpace (Text.head (lineText x))) more
                       in collect (Map.insert key (Text.intercalate "\n" (fmap (Text.stripStart . lineText) block)) acc) others
                    else collect (Map.insert key (unquote value) acc) more
        _ -> collect acc more
    unquote v
      | Text.length v >= 2 && Text.head v == '"' && Text.last v == '"' = Text.init (Text.tail v)
      | otherwise = v

-- Slides --------------------------------------------------------------------

data Section = Section
  { sectionTitle :: Text
  , sectionId :: Text
  , sectionSpan :: (Int, Int)
  , sectionBody :: [Text]
  }

sectionsOf :: Int -> [Line] -> [Section]
sectionsOf total ls = finish (go False ls [])
  where
    -- accumulate (header, body lines) groups, tracking fence state
    go _ [] acc = reverse acc
    go inFence (l : rest) acc =
      let t = lineText l
          fenceToggle = "```" `Text.isPrefixOf` Text.stripStart t
          opensSection = not inFence && "## " `Text.isPrefixOf` t
          inFence' = if fenceToggle then not inFence else inFence
       in if opensSection
            then go inFence' rest ((l, []) : acc)
            else case acc of
              ((h, body) : older) -> go inFence' rest ((h, body <> [l]) : older)
              [] -> go inFence' rest acc
    finish groups =
      [ Section title ident (lineStart header, spanEnd) (fmap lineText body)
      | (header, body) <- groups
      , let (title, ident) = splitTitle (Text.drop 3 (lineText header))
      , let spanEnd = case reverse body of
              (lastLine : _) -> min total (lineStart lastLine + lineWidth lastLine)
              [] -> min total (lineStart header + lineWidth header)
      ]
    splitTitle t =
      case Text.breakOn "{#" t of
        (title, rest)
          | not (Text.null rest) -> (Text.strip title, Text.takeWhile (/= '}') (Text.drop 2 rest))
        (title, _) -> (Text.strip title, slug title)

slug :: Text -> Text
slug t =
  let s = Text.intercalate "-" (Text.words (Text.map (\c -> if isAlphaNum c then toLower c else ' ') t))
   in if Text.null s then "slide" else s

analyse :: Map Text ByteString -> Text -> ByteString -> Analysis
analyse _files _entry bytes =
  Analysis
    { analysisTitle = Map.findWithDefault "" "title" fm
    , analysisTheme = Map.findWithDefault "default" "theme" fm
    , analysisFrames = titleFrame <> slideFrames
    , analysisDiagnostics = concatMap (fst . snd) built'
    , analysisFigures = concatMap (snd . snd) built'
    , analysisImages = []
    , analysisReady = True
    , analysisSections = []
    , analysisSubsections = []
    , analysisRoutes = []
    }
  where
    allLines = linesOf bytes
    front = splitFront bytes allLines
    fm = frontFields front
    sections = sectionsOf (ByteString.length bytes) (frontBody front)
    built' = [(frame, (diags, figs)) | s <- sections, let (frame, diags, figs) = buildSection s]
    slideFrames = fmap fst built'
    titleFrame
      | Map.member "title" fm =
          [ AnalyzedFrame
              { frameKey = "title"
              , frameTitleText = Map.findWithDefault "" "title" fm
              , frameSpan = frontSpan front
              , frameScene =
                  FrameInput
                    "title"
                    (content [])
                    (content [])
                    ( Just
                        TitleFields
                          { titleFieldTitle = Map.findWithDefault "" "title" fm
                          , titleFieldSubtitle = Map.findWithDefault "" "subtitle" fm
                          , titleFieldAuthors = Map.findWithDefault "" "authors" fm
                          , titleFieldInstitute = Map.findWithDefault "" "institute" fm
                          , titleFieldDate = Map.findWithDefault "" "date" fm
                          , titleFieldDivider = False
                          }
                    )
                    []
                    []
                    (content [])
              , frameNotes = content []
              , frameOrigin = Nothing
              }
          ]
      | otherwise = []
    preamble = Encoding.encodeUtf8 (Map.findWithDefault "" "preamble" fm)
    buildSection s =
      let (nodes, notes, figs, diags) = parseBlocks preamble (sectionId s) (sectionBody s)
       in ( AnalyzedFrame
              { frameKey = sectionId s
              , frameTitleText = sectionTitle s
              , frameSpan = sectionSpan s
              , frameScene = FrameInput (sectionId s) (content (inline (sectionTitle s))) (content nodes) Nothing [] [] (content [])
              , frameNotes = content notes
              , frameOrigin = Nothing
              }
          , [d {diagnosticFrame = Just (sectionId s), diagnosticSpan = Just (sectionSpan s)} | d <- diags]
          , figs
          )

-- Blocks --------------------------------------------------------------------

type Parsed = ([ContentNode], [ContentNode], [FigureRequest], [DiagnosticItem])

parseBlocks :: ByteString -> Text -> [Text] -> Parsed
parseBlocks preamble frame body = go (0 :: Int) body [] [] [] []
  where
    go _ [] nodes notes figs diags = (reverse nodes, reverse notes, reverse figs, reverse diags)
    go n (l : rest) nodes notes figs diags
      | Text.null (Text.strip l) = go n rest nodes notes figs diags
      | Just info <- fenceInfo l =
          let (inside, after) = takeFence rest
              kind = Text.takeWhile (not . isSpace) info
           in case kind of
                "notes" -> go n after nodes (reverse (paragraphs inside) <> notes) figs diags
                "tikz" -> figureFrom n after (figureNode n "" (Just (Text.intercalate "\n" inside))) nodes notes figs diags
                "slide" -> go n after nodes notes figs (info' "picture_tier_opaque" "```slide blocks are retained but not rendered yet" : diags)
                _ -> go n after (codeNode kind inside : nodes) notes figs diags
      | Text.strip l == "\\pause" = go n rest (OverlayPauseContent prov PauseNext : nodes) notes figs diags
      | Just path <- figurePath l = figureFrom n rest (figureNode n path Nothing) nodes notes figs diags
      | Text.strip l == "$$" || Text.strip l == "\\[" =
          let closer = if Text.strip l == "$$" then "$$" else "\\]"
              (inside, after) = break ((== closer) . Text.strip) rest
           in go n (drop 1 after) (OpaqueMath prov DisplayMath (Text.unwords inside) : nodes) notes figs diags
      | "$$" `Text.isPrefixOf` Text.strip l && "$$" `Text.isSuffixOf` Text.strip l && Text.length (Text.strip l) > 4 =
          go n rest (OpaqueMath prov DisplayMath (Text.strip (Text.dropEnd 2 (Text.drop 2 (Text.strip l)))) : nodes) notes figs diags
      | isListLine l =
          let (items, after) = span (\x -> isListLine x || (not (Text.null (Text.strip x)) && isSpace (Text.head x) && not (isFenceLine x))) (l : rest)
           in go n after (listNode (filter isListLine items) : nodes) notes figs diags
      | ":::" `Text.isPrefixOf` Text.strip l && "columns" `Text.isInfixOf` l =
          let (inside, after) = takeColons rest
              columns = parseColumns preamble frame inside
           in go n after (TransparentContainer prov ColumnsContainer columns : nodes) notes figs diags
      | Just title <- beginBlock l =
          let (inside, after) = break (isEnd . Text.strip) rest
              (innerNodes, _, _, _) = parseBlocks preamble frame inside
           in go n (drop 1 after) (TransparentContainer prov (GenericContainer ("box:" <> title)) innerNodes : nodes) notes figs diags
      | Just (title, text, hook) <- defnLine l =
          let box = TransparentContainer prov (GenericContainer ("box:" <> title)) [paragraphNode text]
           in go n rest ((if hook == AlwaysVisible then box else OverlayContent hook [box]) : nodes) notes figs diags
      | "|" `Text.isPrefixOf` Text.strip l =
          let (rows, after) = span (("|" `Text.isPrefixOf`) . Text.strip) (l : rest)
           in go n after (tableNode rows : nodes) notes figs diags
      | otherwise =
          let (para, after) = break (\x -> Text.null (Text.strip x) || isFenceLine x || Text.strip x == "\\pause" || isListLine x || isBlockStart x) rest
           in go n after (paragraphNode (Text.unwords (fmap Text.strip (l : para))) : nodes) notes figs diags
      where
        figureFrom k after made nodes' notes' figs' diags' =
          case made of
            Just (node, request) -> go (k + 1) after (node : nodes') notes' (request : figs') diags'
            Nothing -> go (k + 1) after nodes' notes' figs' diags'
    figureNode n path inlineBody =
      fmap
        ( \ref ->
            ( CompiledFigureContent prov ref DerivedLoading
            , FigureRequest
                { figureFrame = frame
                , figureRef = ref
                , figureKind = "tikz"
                , figureBody = maybe ByteString.empty Encoding.encodeUtf8 inlineBody
                , figureInputPath = if Text.null path then Nothing else Just path
                , figurePreamble = preamble
                , figurePalette = []
                , figureWidth = 960
                , figureInputs = [path | not (Text.null path)]
                , figureFirstLine = 1
                , figureUnits = Nothing
                }
            )
        )
        (sourceRef ("fig-" <> frame <> "-" <> Text.pack (show n)))
    info' code message = DiagnosticItem "info" code message Nothing Nothing

isFenceLine :: Text -> Bool
isFenceLine = ("```" `Text.isPrefixOf`) . Text.stripStart

fenceInfo :: Text -> Maybe Text
fenceInfo l = Text.strip <$> Text.stripPrefix "```" (Text.stripStart l)

takeFence :: [Text] -> ([Text], [Text])
takeFence rest =
  let (inside, after) = break isFenceLine rest in (inside, drop 1 after)

takeColons :: [Text] -> ([Text], [Text])
takeColons rest = go (0 :: Int) rest []
  where
    go _ [] acc = (reverse acc, [])
    go depth (l : more) acc
      | Text.strip l == ":::" && depth == 0 = (reverse acc, more)
      | ":::: column" `Text.isPrefixOf` Text.strip l = go (depth + 1) more (l : acc)
      | Text.strip l == "::::" = go (max 0 (depth - 1)) more (l : acc)
      | otherwise = go depth more (l : acc)

parseColumns :: ByteString -> Text -> [Text] -> [ContentNode]
parseColumns preamble frame ls = go ls
  where
    go [] = []
    go (l : rest)
      | ":::: column" `Text.isPrefixOf` Text.strip l =
          let width = Text.strip (Text.drop (Text.length ":::: column") (Text.strip l))
              (inside, after) = break ((== "::::") . Text.strip) rest
              (nodes, _, _, _) = parseBlocks preamble frame inside
           in TransparentContainer prov (GenericContainer ("column:" <> width)) nodes : go (drop 1 after)
      | otherwise = go rest

figurePath :: Text -> Maybe Text
figurePath l =
  let t = Text.strip l
   in case Text.stripPrefix "\\figure" t of
        Just rest ->
          let afterOpts = if "[" `Text.isPrefixOf` rest then Text.drop 1 (Text.dropWhile (/= ']') rest) else rest
           in case Text.stripPrefix "{" afterOpts of
                Just body -> Just (Text.strip (Text.takeWhile (/= '}') body))
                Nothing -> Nothing
        Nothing -> Nothing

beginBlock :: Text -> Maybe Text
beginBlock l =
  case Text.stripPrefix "\\begin{" (Text.strip l) of
    Just rest ->
      let (name, afterName) = Text.breakOn "}" rest
       in if name `elem` ["block", "alertblock", "exampleblock"]
            then Just (argument (Text.drop 1 afterName))
            else Nothing
    Nothing -> Nothing
  where
    argument t = maybe "" (Text.takeWhile (/= '}')) (Text.stripPrefix "{" t)

isEnd :: Text -> Bool
isEnd t = "\\end{" `Text.isPrefixOf` t

isBlockStart :: Text -> Bool
isBlockStart l =
  let t = Text.strip l
   in "\\begin{" `Text.isPrefixOf` t || ":::" `Text.isPrefixOf` t || "\\figure" `Text.isPrefixOf` t || "|" `Text.isPrefixOf` t

defnLine :: Text -> Maybe (Text, Text, OverlayHook)
defnLine l =
  case Text.stripPrefix "\\defn{" (Text.strip l) of
    Just rest ->
      let (title, afterTitle) = Text.breakOn "}{" rest
          (bodyPart, tailPart) = Text.breakOnEnd "}" (Text.drop 2 afterTitle)
          hook = case Text.stripSuffix ">" (Text.strip tailPart) >>= Text.stripPrefix "<" of
            Just spec -> fromMaybe AlwaysVisible (parseSpec spec)
            Nothing -> AlwaysVisible
       in if Text.null afterTitle || Text.null bodyPart then Nothing else Just ("Definition: " <> title, Text.dropEnd 1 bodyPart, hook)
    Nothing -> Nothing

isListLine :: Text -> Bool
isListLine l =
  let t = Text.stripStart l
   in "- " `Text.isPrefixOf` t || "* " `Text.isPrefixOf` t || orderedMarker t

orderedMarker :: Text -> Bool
orderedMarker t =
  let digits = Text.takeWhile isDigit t
   in not (Text.null digits) && (". " `Text.isPrefixOf` Text.drop (Text.length digits) t)

listNode :: [Text] -> ContentNode
listNode items =
  ListContent prov kind (fromMaybe (ContentItem prov [] AlwaysVisible :| []) (nonEmptyOf (fmap item items)))
  where
    kind = case items of
      (first : _) | orderedMarker (Text.stripStart first) -> OrderedList
      _ -> UnorderedList
    item l =
      let body = stripMarker (Text.stripStart l)
          (text, hook) = splitSpec body
       in ContentItem prov (inline text) hook
    stripMarker t
      | "- " `Text.isPrefixOf` t || "* " `Text.isPrefixOf` t = Text.strip (Text.drop 2 t)
      | otherwise = Text.strip (Text.drop 2 (Text.dropWhile isDigit t))

nonEmptyOf :: [a] -> Maybe (NonEmpty a)
nonEmptyOf (x : xs) = Just (x :| xs)
nonEmptyOf [] = Nothing

-- Trailing @<spec>@ on an item or definition line.
splitSpec :: Text -> (Text, OverlayHook)
splitSpec t =
  case Text.breakOnEnd " <" (Text.strip t) of
    (before, spec)
      | not (Text.null before)
      , ">" `Text.isSuffixOf` spec
      , Just hook <- parseSpec (Text.dropEnd 1 spec) ->
          (Text.strip (Text.dropEnd 2 before), hook)
    _ -> (Text.strip t, AlwaysVisible)

-- | Beamer overlay spec: @n@, @n-@, @-n@, @n-m@ and comma unions.
parseSpec :: Text -> Maybe OverlayHook
parseSpec spec = do
  ranges <- traverse range (Text.splitOn "," spec)
  case ranges of
    (r : rs) -> Just (VisibleDuring (r :| rs))
    [] -> Nothing
  where
    number s = if not (Text.null s) && Text.all isDigit s then mkOverlayStep (Text.foldl' (\acc c -> acc * 10 + fromIntegral (digitToInt c)) 0 s) else Nothing
    range :: Text -> Maybe StepRange
    range part =
      case Text.splitOn "-" (Text.strip part) of
        [n] -> singleStep <$> number n
        ["", m] -> stepsThrough <$> number m
        [n, ""] -> stepsFrom <$> number n
        [n, m] -> do
          a <- number n
          b <- number m
          stepsBetween a b
        _ -> Nothing

codeNode :: Text -> [Text] -> ContentNode
codeNode kind inside =
  TransparentContainer prov (GenericContainer ("codeblock:" <> kind)) [TextRun prov l | l <- inside]

tableNode :: [Text] -> ContentNode
tableNode rows =
  TransparentContainer prov (GenericContainer "codeblock:") [TextRun prov (Text.strip r) | r <- rows]

paragraphs :: [Text] -> [ContentNode]
paragraphs ls =
  [paragraphNode (Text.unwords (fmap Text.strip grp)) | grp <- groups ls, not (null grp)]
  where
    groups [] = []
    groups xs = let (g, rest) = break (Text.null . Text.strip) xs in g : groups (drop 1 rest)

paragraphNode :: Text -> ContentNode
paragraphNode text = TransparentContainer prov (GenericContainer "p") (inline text)

-- Inline --------------------------------------------------------------------

inline :: Text -> [ContentNode]
inline text
  | Text.null text = []
  | otherwise =
      case nextMarker text of
        Nothing -> [TextRun prov text]
        Just (before, marker, rest) ->
          let lead = [TextRun prov before | not (Text.null before)]
           in case marker of
                "$" ->
                  let (math, after) = Text.breakOn "$" rest
                   in if Text.null after
                        then lead <> [TextRun prov ("$" <> rest)]
                        else lead <> [OpaqueMath prov InlineMath math] <> inline (Text.drop 1 after)
                "**" -> wrapped lead Strong "**" rest
                "`" -> wrapped lead InlineCode "`" rest
                "*" -> wrapped lead Emphasis "*" rest
                "\\citefootnote{" -> cite lead rest
                "\\cite{" -> cite lead rest
                "\\only<" -> only lead rest
                _ -> lead <> [TextRun prov marker] <> inline rest
  where
    wrapped lead mark closer rest =
      let (inner, after) = Text.breakOn closer rest
       in if Text.null after
            then lead <> [TextRun prov (closer <> rest)]
            else lead <> [StyledRun prov (mark :| []) (if mark == InlineCode then [TextRun prov inner] else inline inner)] <> inline (Text.drop (Text.length closer) after)
    cite lead rest =
      let (keys, after) = Text.breakOn "}" rest
          parsed = mapMaybe (citationKey . Text.strip) (Text.splitOn "," keys)
       in case parsed of
            (k : ks) | not (Text.null after) -> lead <> [CitationContent prov (k :| ks) DerivedUnresolved] <> inline (Text.drop 1 after)
            _ -> lead <> [TextRun prov rest]
    only lead rest =
      let (spec, afterSpec) = Text.breakOn ">" rest
          body = Text.drop 1 (Text.dropWhile (/= '{') afterSpec)
          (inner, after) = Text.breakOn "}" body
       in case parseSpec spec of
            Just hook | not (Text.null afterSpec) && not (Text.null after) -> lead <> [OverlayContent hook (inline inner)] <> inline (Text.drop 1 after)
            _ -> lead <> [TextRun prov ("\\only<" <> rest)]

markers :: [Text]
markers = ["\\citefootnote{", "\\cite{", "\\only<", "**", "$", "`", "*"]

nextMarker :: Text -> Maybe (Text, Text, Text)
nextMarker text = go 0
  where
    go i
      | i >= Text.length text = Nothing
      | otherwise =
          let tailText = Text.drop i text
           in case [m | m <- markers, m `Text.isPrefixOf` tailText] of
                (m : _) -> Just (Text.take i text, m, Text.drop (Text.length m) tailText)
                [] -> go (i + 1)

-- Structural edit -----------------------------------------------------------

insertAfter :: ByteString -> Maybe Text -> Maybe (ByteString, Text)
insertAfter bytes after =
  let front = splitFront bytes (linesOf bytes)
      sections = sectionsOf (ByteString.length bytes) (frontBody front)
      existing = fmap sectionId sections
      ident = freshId existing (length existing + 1)
      position = case [snd (sectionSpan s) | s <- sections, Just (sectionId s) == after] of
        (end : _) -> end
        [] -> case reverse sections of
          (lastSection : _) -> snd (sectionSpan lastSection)
          [] -> max (frontEnd front) 0
      before = ByteString.take position bytes
      separator = if ByteString.null before || ByteString.isSuffixOf "\n\n" before then "" else if ByteString.isSuffixOf "\n" before then "\n" else "\n\n"
      new = Encoding.encodeUtf8 ("## New slide {#" <> ident <> "}\n\n")
   in Just (ByteString.concat [before, separator, new, ByteString.drop position bytes], ident)
  where
    freshId existing n =
      let candidate = "slide-" <> Text.pack (show n)
       in if candidate `elem` existing then freshId existing (n + 1) else candidate
