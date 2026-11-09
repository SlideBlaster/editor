{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Block
-- Description : Lossless Markdown block structure over mixed-dialect prose.
--
-- "SlideBlaster.Syntax.Tex.Reader" reads /inline/ content: TeX, Markdown spans and
-- HTML mixed freely. This module adds the line-oriented block layer a slide body
-- needs above it: paragraphs, nested lists, quotes, fenced code with an info
-- string, @:::@ containers, pipe tables and headings. Block structure is found by
-- line shape; the text of each leaf is handed to the inline reader.
--
-- == Laws
--
-- * @'printFlow' ('readFlow' t) == t@ for /every/ 'Text', not only well-formed
--   input. 'readFlow' is total: input it cannot interpret becomes a leaf that
--   retains the exact bytes ('Prose' with a recorded error, an unclosed fence, a
--   stray container close), and 'flowIssues' reports it. This is the D8 rule:
--   unknown or malformed syntax is retained, never rewritten, never an exception.
-- * A leaf's inline error is local: one bad paragraph does not affect its
--   neighbours.
--
-- == TeX-aware paragraphs
--
-- A paragraph is not ended by a blank line while a TeX group, environment or
-- display math is open, so @\\begin{block}...\\end{block}@ with blank lines inside
-- stays one construct. If the construct never closes, the paragraph falls back to
-- ending at its first blank line so the damage stays local.
module SlideBlaster.Syntax.Block
  ( -- * Tree
    Flow (..)
  , Block (..)
  , Prose (..)
  , ListItem (..)
  , Fence (..)
  , Container (..)

    -- * Reading and printing
  , readFlow
  , printFlow
  , printBlock
  , readProse
  , printProse

    -- * Derived views
  , FenceInfo (..)
  , fenceInfo
  , fenceOpenLine
  , fenceIsClosed
  , ContainerHead (..)
  , containerHead
  , containerIsClosed
  , tableRows
  , tableCells
  , tableAlignments
  , TableAlignment (..)

    -- * Diagnostics
  , FlowIssue (..)
  , IssueKind (..)
  , flowIssues

    -- * Lines
  , splitLinesKeep
  ) where

import SlideBlaster.Syntax.Ast (ListKind (Ordered, Unordered), Node, NodeF (Foreign), node)
import SlideBlaster.Syntax.Printer (printNodes)
import SlideBlaster.Syntax.Surface (Dialect (Tex), Surface (Transparent))
import SlideBlaster.Syntax.Tex.Reader (TexSyntaxError (..), readTex)

import Data.Char (isAlpha, isDigit, isSpace)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text

-- | A parsed flow body: the blocks of one slide or one note, in order.
newtype Flow = Flow {flowBlocks :: [Block]}
  deriving stock (Eq, Show)

-- | Inline content read by the TeX/Markdown/HTML reader, with the reader's error
-- when it could not interpret the text. On error 'proseNodes' is a single
-- 'Foreign' node holding the exact text, so printing is still exact.
data Prose = Prose
  { proseNodes :: ![Node]
  , proseError :: !(Maybe TexSyntaxError)
  }
  deriving stock (Eq, Show)

-- | One list item. The lead is the indentation, marker and following spaces; the
-- prose is the rest of the first line plus its continuation lines (including
-- line endings); nested items are those indented deeper than this item.
data ListItem = ListItem
  { itemLead :: !Text
  , itemKind :: !ListKind
  , itemProse :: !Prose
  , itemNested :: ![ListItem]
  }
  deriving stock (Eq, Show)

-- | A fenced block. Open and close are whole lines including their line endings;
-- the close is empty when the fence was never closed.
data Fence = FenceData
  { fenceOpen :: !Text
  , fenceBody :: !Text
  , fenceClose :: !Text
  }
  deriving stock (Eq, Show)

-- | A @:::@ container with nested blocks; the close line is empty when unclosed.
data Container = ContainerData
  { containerOpen :: !Text
  , containerBody :: ![Block]
  , containerClose :: !Text
  }
  deriving stock (Eq, Show)

-- | One block.
data Block
  = -- | Blank lines between blocks, exactly.
    GapBlock !Text
  | -- | A paragraph, including its trailing line ending.
    ParagraphBlock !Prose
  | -- | An ATX heading: the prefix (indent, hashes, spaces) and the rest of the line.
    HeadingBlock !Text !Prose
  | -- | A list with its (possibly nested) items.
    ListBlock ![ListItem]
  | -- | A quote: the exact prefix of each line and the blocks of the stripped text.
    QuoteBlock ![Text] ![Block]
  | FenceBlock !Fence
  | ContainerBlock !Container
  | -- | A pipe table, one raw line each; the second is the delimiter row.
    TableBlock ![Text]
  | -- | A container close with nothing to close.
    StrayBlock !Text
  deriving stock (Eq, Show)

-- | Read any text. Total.
readFlow :: Text -> Flow
readFlow input = Flow (fst (parseBlocks False (splitLinesKeep input)))

-- | Print a flow; the exact inverse of 'readFlow'.
printFlow :: Flow -> Text
printFlow = foldMap printBlock . flowBlocks

-- | Print one block.
printBlock :: Block -> Text
printBlock block =
  case block of
    GapBlock text -> text
    ParagraphBlock prose -> printProse prose
    HeadingBlock prefix prose -> prefix <> printProse prose
    ListBlock items -> foldMap printItem items
    QuoteBlock prefixes inner ->
      reprefix prefixes (splitLinesKeep (foldMap printBlock inner))
    FenceBlock fence -> fenceOpen fence <> fenceBody fence <> fenceClose fence
    ContainerBlock container ->
      containerOpen container
        <> foldMap printBlock (containerBody container)
        <> containerClose container
    TableBlock rows -> Text.concat rows
    StrayBlock text -> text

-- | Put each exact prefix back in front of its line. A final prefix with no text
-- after it (a trailing @>@ with nothing quoted) has no line, so the shorter side
-- is padded rather than truncated.
reprefix :: [Text] -> [Text] -> Text
reprefix prefixes quoted =
  case (prefixes, quoted) of
    ([], remaining) -> Text.concat remaining
    (prefix : more, []) -> prefix <> reprefix more []
    (prefix : more, line : remaining) -> prefix <> line <> reprefix more remaining

printItem :: ListItem -> Text
printItem item =
  itemLead item <> printProse (itemProse item) <> foldMap printItem (itemNested item)

-- | Print inline content.
printProse :: Prose -> Text
printProse = printNodes . proseNodes

-- | Read inline text. The reader's own exactness is checked rather than assumed,
-- so a reader defect degrades to a retained, reported leaf and never to a
-- rewrite.
readProse :: Text -> Prose
readProse text =
  case readTex text of
    Right nodes
      | printNodes nodes == text -> Prose nodes Nothing
      | otherwise ->
          retained (Just (TexSyntaxError Nothing 1 1 "inline reader did not reproduce its input"))
    Left failure -> retained (Just failure)
  where
    retained failure = Prose [node (Foreign (Transparent Tex) text)] failure

------------------------------------------------------------------------------
-- Line classification

data LineKind
  = BlankLine
  | FenceLine !Char !Int
  | ContainerOpenLine
  | ContainerCloseLine
  | HeadingLine
  | QuoteLine
  | ItemLine !Int !ListKind !Int
  | OtherLine

-- | Strip the line ending.
lineBody :: Text -> Text
lineBody = Text.dropWhileEnd (\c -> c == '\n' || c == '\r')

indentOf :: Text -> Int
indentOf = Text.length . Text.takeWhile (\c -> c == ' ' || c == '\t')

classify :: Text -> LineKind
classify line
  | Text.all isSpace body = BlankLine
  | indent <= 3, Just kind <- structural = kind
  | Just (width, kind, number) <- itemMarker rest = ItemLine (indent + width) kind number
  | otherwise = OtherLine
  where
    body = lineBody line
    indent = indentOf body
    rest = Text.dropWhile (\c -> c == ' ' || c == '\t') body
    structural
      | Just (c, n) <- fenceRun rest = Just (FenceLine c n)
      | ":::" `Text.isPrefixOf` rest =
          if Text.all isSpace (Text.dropWhile (== ':') rest)
            then Just ContainerCloseLine
            else Just ContainerOpenLine
      | isHeading rest = Just HeadingLine
      | ">" `Text.isPrefixOf` rest = Just QuoteLine
      | otherwise = Nothing

-- | A run of three or more backticks or tildes opening a fence. A backtick fence
-- may not have a backtick in its info string.
fenceRun :: Text -> Maybe (Char, Int)
fenceRun rest =
  case Text.uncons rest of
    Just (c, _)
      | c == '`' || c == '~' ->
          let run = Text.takeWhile (== c) rest
              info = Text.drop (Text.length run) rest
           in if Text.length run >= 3 && not (c == '`' && Text.any (== '`') info)
                then Just (c, Text.length run)
                else Nothing
    _ -> Nothing

isHeading :: Text -> Bool
isHeading rest =
  let hashes = Text.takeWhile (== '#') rest
      after = Text.drop (Text.length hashes) rest
   in Text.length hashes >= 1
        && Text.length hashes <= 6
        && maybe True (isSpace . fst) (Text.uncons after)

-- | A list marker at the start of already-indented text: the width of marker plus
-- following spaces, the kind, and the number for an ordered marker.
itemMarker :: Text -> Maybe (Int, ListKind, Int)
itemMarker rest =
  case Text.uncons rest of
    Just (c, after)
      | c `elem` ("-*+" :: String) && spaceOrEnd after ->
          Just (1 + spaces after, Unordered, 0)
    Just (c, _)
      | isDigit c ->
          let digits = Text.takeWhile isDigit rest
              after = Text.drop (Text.length digits) rest
           in case Text.uncons after of
                Just (t, afterMarker)
                  | (t == '.' || t == ')')
                      && Text.length digits <= 9
                      && spaceOrEnd afterMarker ->
                      Just (Text.length digits + 1 + spaces afterMarker, Ordered, readNumber digits)
                _ -> Nothing
    _ -> Nothing
  where
    spaceOrEnd after =
      case Text.uncons after of
        Nothing -> True
        Just (c, _) -> c == ' ' || c == '\t' || c == '\n' || c == '\r'
    spaces after = Text.length (Text.takeWhile (\c -> c == ' ' || c == '\t') after)
    readNumber = Text.foldl' (\acc c -> acc * 10 + fromEnum c - fromEnum '0') 0

-- | Whether a line may interrupt a paragraph.
interrupts :: Text -> Bool
interrupts line =
  case classify line of
    BlankLine -> True
    FenceLine _ _ -> True
    ContainerOpenLine -> True
    ContainerCloseLine -> True
    HeadingLine -> True
    QuoteLine -> True
    ItemLine _ Unordered _ -> True
    ItemLine _ Ordered 1 -> True
    ItemLine _ _ _ -> False
    OtherLine -> False

------------------------------------------------------------------------------
-- Block parser

-- | Parse lines into blocks. When inside a container, stop at its closing line and
-- return it with the remaining lines.
parseBlocks :: Bool -> [Text] -> ([Block], Maybe (Text, [Text]))
parseBlocks inContainer = go []
  where
    done acc = reverse acc
    go acc [] = (done acc, Nothing)
    go acc lines'@(line : rest) =
      case classify line of
        BlankLine ->
          let (blanks, after) = span (\l -> isBlank l) lines'
           in go (GapBlock (Text.concat blanks) : acc) after
        ContainerCloseLine
          | inContainer -> (done acc, Just (line, rest))
          | otherwise -> go (StrayBlock line : acc) rest
        ContainerOpenLine ->
          let (inner, closing) = parseBlocks True rest
           in case closing of
                Just (closeLine, after) ->
                  go (ContainerBlock (ContainerData line inner closeLine) : acc) after
                Nothing -> (done (ContainerBlock (ContainerData line inner Text.empty) : acc), Nothing)
        FenceLine mark count ->
          let (bodyLines, closeLine, after) = takeFence mark count rest
           in go (FenceBlock (FenceData line (Text.concat bodyLines) closeLine) : acc) after
        HeadingLine ->
          let body = lineBody line
              hashesEnd = indentOf body + Text.length (Text.takeWhile (== '#') (Text.dropWhile (\c -> c == ' ' || c == '\t') body))
              afterHashes = Text.length (Text.takeWhile (\c -> c == ' ' || c == '\t') (Text.drop hashesEnd body))
              prefixLength = hashesEnd + afterHashes
           in go (HeadingBlock (Text.take prefixLength line) (readProse (Text.drop prefixLength line)) : acc) rest
        QuoteLine ->
          let (quoted, after) = span isQuote lines'
              stripped = fmap stripQuote quoted
              (inner, _) = parseBlocks False (splitLinesKeep (Text.concat (fmap snd stripped)))
           in go (QuoteBlock (fmap fst stripped) inner : acc) after
        ItemLine _ kind _ ->
          let (items, after) = parseItems (leadingIndent line) kind lines'
           in go (ListBlock items : acc) after
        OtherLine
          | Just (tableLines, after) <- takeTable lines' -> go (TableBlock tableLines : acc) after
          | otherwise ->
              let (paragraphLines, after) = takeParagraph lines'
               in go (ParagraphBlock (readProse (Text.concat paragraphLines)) : acc) after
    isBlank l = case classify l of BlankLine -> True; _ -> False
    isQuote l = case classify l of QuoteLine -> True; _ -> False

leadingIndent :: Text -> Int
leadingIndent = indentOf . lineBody

-- | Split a quote line into its exact prefix and the quoted text.
stripQuote :: Text -> (Text, Text)
stripQuote line =
  let indent = Text.takeWhile (\c -> c == ' ' || c == '\t') line
      afterIndent = Text.drop (Text.length indent) line
      afterMarker = Text.drop 1 afterIndent
      space = Text.take 1 (Text.takeWhile (\c -> c == ' ' || c == '\t') afterMarker)
      prefix = indent <> ">" <> space
   in (prefix, Text.drop (Text.length prefix) line)

-- | Lines of a fence body, its closing line (or empty) and the remainder.
takeFence :: Char -> Int -> [Text] -> ([Text], Text, [Text])
takeFence mark count = loop []
  where
    loop acc [] = (reverse acc, Text.empty, [])
    loop acc (line : rest)
      | closes line = (reverse acc, line, rest)
      | otherwise = loop (line : acc) rest
    closes line =
      let body = lineBody line
          stripped = Text.dropWhile (== ' ') body
          run = Text.takeWhile (== mark) stripped
       in indentOf body <= 3
            && Text.length run >= count
            && Text.all isSpace (Text.drop (Text.length run) stripped)

-- | A pipe table starting here: a header line with a pipe, then a delimiter row.
takeTable :: [Text] -> Maybe ([Text], [Text])
takeTable lines' =
  case lines' of
    header : delimiter : rest
      | Text.any (== '|') (lineBody header)
      , isDelimiterRow (lineBody delimiter) ->
          let (rows, after) = span isTableRow rest
           in Just (header : delimiter : rows, after)
    _ -> Nothing
  where
    isTableRow l =
      case classify l of
        BlankLine -> False
        _ -> Text.any (== '|') (lineBody l)

isDelimiterRow :: Text -> Bool
isDelimiterRow row =
  not (null cells) && all isDelimiterCell cells && Text.any (== '-') row
  where
    cells = rowCells row
    isDelimiterCell cell =
      let core = Text.strip cell
          inner = Text.dropWhile (== ':') core
          dashes = Text.dropWhileEnd (== ':') inner
       in not (Text.null dashes)
            && Text.all (== '-') dashes
            && Text.length core - Text.length dashes <= 2

-- | Split a table row into raw cell texts, dropping the optional outer pipes.
rowCells :: Text -> [Text]
rowCells row =
  let trimmed = Text.strip row
      noLeading = maybe trimmed id (Text.stripPrefix "|" trimmed)
      noTrailing =
        if "|" `Text.isSuffixOf` noLeading && not ("\\|" `Text.isSuffixOf` noLeading)
          then Text.dropEnd 1 noLeading
          else noLeading
   in splitUnescaped noTrailing

splitUnescaped :: Text -> [Text]
splitUnescaped text = finish (Text.foldl' step ([], Text.empty, False) text)
  where
    step (done, current, escaped) c
      | escaped = (done, Text.snoc current c, False)
      | c == '\\' = (done, Text.snoc current c, True)
      | c == '|' = (current : done, Text.empty, False)
      | otherwise = (done, Text.snoc current c, False)
    finish (done, current, _) = reverse (current : done)

-- | The raw lines of a table.
tableRows :: [Text] -> [Text]
tableRows = fmap lineBody

-- | The raw cell texts of one row line.
tableCells :: Text -> [Text]
tableCells = rowCells . lineBody

-- | Column alignment from a delimiter row.
data TableAlignment = AlignDefault | AlignLeft | AlignCentre | AlignRight
  deriving stock (Eq, Show)

-- | The alignment of each column from the delimiter row (second line).
tableAlignments :: [Text] -> [TableAlignment]
tableAlignments rows =
  case rows of
    _ : delimiter : _ -> fmap alignment (rowCells (lineBody delimiter))
    _ -> []
  where
    alignment cell =
      let core = Text.strip cell
       in case (":" `Text.isPrefixOf` core, ":" `Text.isSuffixOf` core) of
            (True, True) -> AlignCentre
            (True, False) -> AlignLeft
            (False, True) -> AlignRight
            (False, False) -> AlignDefault

-- | A paragraph: lines up to a blank line or an interrupting block, extended
-- across blank lines while a TeX construct is open.
takeParagraph :: [Text] -> ([Text], [Text])
takeParagraph lines' =
  case attempt False lines' of
    Just result -> result
    Nothing -> maybe (lines', []) id (attempt True lines')
  where
    attempt strict = loop strict initialState []
    loop strict state acc remaining =
      case remaining of
        [] ->
          if isOpen state && not strict
            then Nothing
            else Just (reverse acc, [])
        line : rest ->
          let state' = scanLine state (lineBody line)
              acc' = line : acc
           in if isOpen state' && not strict
                then loop strict state' acc' rest
                else case rest of
                  next : _ | interrupts next -> Just (reverse acc', rest)
                  [] -> Just (reverse acc', [])
                  _ -> loop strict state' acc' rest

-- | Bracket-balance state of the TeX in a paragraph.
data TexState = TexState
  { tsBrace :: !Int
  , tsEnvironment :: !Int
  , tsDisplay :: !Bool
  , tsRaw :: !(Maybe Text)
  }

initialState :: TexState
initialState = TexState 0 0 False Nothing

isOpen :: TexState -> Bool
isOpen state =
  tsBrace state > 0 || tsEnvironment state > 0 || tsDisplay state || isJust (tsRaw state)

-- | Advance the state over one line. Comments end the scan; escaped characters
-- are skipped; the contents of verbatim-like environments are not interpreted.
scanLine :: TexState -> Text -> TexState
scanLine state0 line0 = go state0 line0
  where
    go state text =
      case tsRaw state of
        Just name ->
          let terminator = "\\end{" <> name <> "}"
              (_, found) = Text.breakOn terminator text
           in if Text.null found
                then state
                else
                  go
                    state {tsRaw = Nothing, tsEnvironment = max 0 (tsEnvironment state - 1)}
                    (Text.drop (Text.length terminator) found)
        Nothing ->
          case Text.uncons text of
            Nothing -> state
            Just (c, rest)
              | c == '%' -> state
              | c == '\\' -> escape state rest
              | c == '$' ->
                  case Text.uncons rest of
                    Just ('$', rest') -> go state {tsDisplay = not (tsDisplay state)} rest'
                    _ -> go state rest
              | c == '{' -> go state {tsBrace = tsBrace state + 1} rest
              | c == '}' -> go state {tsBrace = max 0 (tsBrace state - 1)} rest
              | otherwise -> go state rest
    escape state rest
      | Just after <- Text.stripPrefix "begin{" rest =
          let (name, remaining) = Text.break (== '}') after
           in go
                state
                  { tsEnvironment = tsEnvironment state + 1
                  , tsRaw = if name `elem` ["lstlisting", "verbatim", "Verbatim", "minted"] then Just name else Nothing
                  }
                (Text.drop 1 remaining)
      | Just after <- Text.stripPrefix "end{" rest =
          go state {tsEnvironment = max 0 (tsEnvironment state - 1)} after
      | Just after <- Text.stripPrefix "[" rest = go state {tsDisplay = True} after
      | Just after <- Text.stripPrefix "]" rest = go state {tsDisplay = False} after
      | otherwise = go state (Text.drop 1 rest)

------------------------------------------------------------------------------
-- Lists

-- | Parse a run of items whose first item is at the given indentation. Returns
-- the sibling items and the remaining lines.
parseItems :: Int -> ListKind -> [Text] -> ([ListItem], [Text])
parseItems baseIndent baseKind = siblings
  where
    siblings lines' =
      case lines' of
        line : rest
          | ItemLine _ kind _ <- classify line
          , kind == baseKind
          , leadingIndent line == baseIndent ->
              let (item, after) = oneItem line rest
                  (more, final) = siblings after
               in (item : more, final)
        _ -> ([], lines')
    oneItem line rest =
      let (lead, kind, firstText) = splitItem line
          (continuation, afterText) = collectContinuation rest
          (nested, afterNested) =
            case afterText of
              next : _
                | ItemLine _ nestedKind _ <- classify next
                , leadingIndent next > baseIndent ->
                    parseItems (leadingIndent next) nestedKind afterText
              _ -> ([], afterText)
       in ( ListItem lead kind (readProse (Text.concat (firstText : continuation))) nested
          , afterNested
          )
    collectContinuation lines' =
      case lines' of
        [] -> ([], [])
        line : rest ->
          case classify line of
            BlankLine ->
              let (blanks, after) = span isBlank lines'
               in case after of
                    next : _
                      | continues next -> let (more, final) = collectContinuation after in (blanks <> more, final)
                    _ -> ([], lines')
            ItemLine _ _ _ -> ([], lines')
            _
              | leadingIndent line > baseIndent ->
                  let (more, final) = collectContinuation rest in (line : more, final)
              | otherwise -> ([], lines')
    continues next =
      case classify next of
        ItemLine _ kind _ ->
          leadingIndent next > baseIndent || (leadingIndent next == baseIndent && kind == baseKind)
        BlankLine -> False
        _ -> leadingIndent next > baseIndent
    isBlank l = case classify l of BlankLine -> True; _ -> False

-- | The lead (indentation, marker, spacing), kind and remaining text of an item line.
splitItem :: Text -> (Text, ListKind, Text)
splitItem line =
  case itemMarker rest of
    Just (width, kind, _) ->
      let lead = indent <> Text.take width rest
       in (lead, kind, Text.drop (Text.length lead) line)
    Nothing -> (Text.empty, Unordered, line)
  where
    indent = Text.takeWhile (\c -> c == ' ' || c == '\t') line
    rest = Text.drop (Text.length indent) line

------------------------------------------------------------------------------
-- Lines

-- | Split after every line feed, keeping the line endings, so concatenation is the
-- identity.
splitLinesKeep :: Text -> [Text]
splitLinesKeep text
  | Text.null text = []
  | otherwise =
      let (before, after) = Text.break (== '\n') text
       in case Text.uncons after of
            Nothing -> [before]
            Just (_, remaining) -> Text.snoc before '\n' : splitLinesKeep remaining

------------------------------------------------------------------------------
-- Views

-- | The parts of a fence info string such as @p4 {2|3-4}@.
data FenceInfo = FenceInfo
  { fenceLanguage :: !Text
  -- ^ First word; empty when the fence has no info string.
  , fenceHighlight :: !(Maybe Text)
  -- ^ The text inside braces, such as @1,3-5|7@.
  , fenceOptions :: !Text
  -- ^ Everything after the language that is not the brace group, stripped.
  }
  deriving stock (Eq, Show)

-- | The open line of a fence, without its line ending.
fenceOpenLine :: Fence -> Text
fenceOpenLine = lineBody . fenceOpen

-- | Whether the fence has its closing line.
fenceIsClosed :: Fence -> Bool
fenceIsClosed = not . Text.null . fenceClose

-- | Parse the info string of a fence.
fenceInfo :: Fence -> FenceInfo
fenceInfo fence =
  FenceInfo
    { fenceLanguage = language
    , fenceHighlight = highlight
    , fenceOptions = Text.strip (before <> afterBrace)
    }
  where
    open = Text.strip (Text.dropWhile (\c -> c == '`' || c == '~') (Text.stripStart (fenceOpenLine fence)))
    language = Text.takeWhile (\c -> not (isSpace c) && c /= '{') open
    remainder = Text.drop (Text.length language) open
    (before, fromBrace) = Text.breakOn "{" remainder
    (inside, closing) = Text.breakOn "}" (Text.drop 1 fromBrace)
    highlight
      | Text.null fromBrace || Text.null closing = Nothing
      | otherwise = Just inside
    afterBrace
      | Text.null fromBrace || Text.null closing = fromBrace
      | otherwise = Text.drop 1 closing

-- | The name and arguments on a container's open line.
data ContainerHead = ContainerHead
  { containerColons :: !Int
  , containerName :: !Text
  , containerArguments :: !Text
  }
  deriving stock (Eq, Show)

-- | Parse @::: columns@ or @:::: column 55%@.
containerHead :: Container -> ContainerHead
containerHead container =
  ContainerHead
    { containerColons = Text.length colons
    , containerName = name
    , containerArguments = Text.strip arguments
    }
  where
    stripped = Text.strip (lineBody (containerOpen container))
    colons = Text.takeWhile (== ':') stripped
    afterColons = Text.strip (Text.drop (Text.length colons) stripped)
    cleaned = Text.dropWhile (== '{') (Text.dropWhile (== '.') afterColons)
    name = Text.takeWhile (\c -> isAlpha c || isDigit c || c == '-' || c == '_') cleaned
    arguments = Text.drop (Text.length name) cleaned

-- | Whether the container has its closing line.
containerIsClosed :: Container -> Bool
containerIsClosed = not . Text.null . containerClose

------------------------------------------------------------------------------
-- Diagnostics

-- | Stable class of a structural or inline problem.
data IssueKind
  = IssueMalformedInline
  | IssueUnclosedFence
  | IssueUnclosedContainer
  | IssueStrayContainerClose
  deriving stock (Eq, Show)

-- | A problem located by one-based line and column within the flow text.
data FlowIssue = FlowIssue
  { issueKind :: !IssueKind
  , issueLine :: !Int
  , issueColumn :: !Int
  , issueMessage :: !Text
  }
  deriving stock (Eq, Show)

-- | Every problem in a flow, in source order. Retained input is reported, never
-- dropped.
flowIssues :: Flow -> [FlowIssue]
flowIssues (Flow blocks) = snd (walk 1 blocks)

walk :: Int -> [Block] -> (Int, [FlowIssue])
walk line [] = (line, [])
walk line (block : rest) =
  let (afterBlock, here) = issuesOf line block
      (end, later) = walk afterBlock rest
   in (end, here <> later)

linesIn :: Text -> Int
linesIn = Text.count "\n"

issuesOf :: Int -> Block -> (Int, [FlowIssue])
issuesOf line block =
  case block of
    GapBlock text -> (line + linesIn text, [])
    ParagraphBlock prose -> proseIssues line prose
    HeadingBlock prefix prose -> proseIssuesAfter line prefix prose
    ListBlock items -> itemsIssues line items
    QuoteBlock _ inner ->
      -- The quote's lines are the same lines; columns shift by the prefix, which
      -- is reported at the start of the line instead.
      let (end, here) = walk line inner
       in (max end (line + linesIn (printBlock block)), here)
    FenceBlock fence ->
      let total = linesIn (fenceOpen fence <> fenceBody fence <> fenceClose fence)
          unclosed =
            [ FlowIssue IssueUnclosedFence line 1 "code fence is never closed"
            | not (fenceIsClosed fence)
            ]
       in (line + total, unclosed)
    ContainerBlock container ->
      let (afterOpen, _) = (line + linesIn (containerOpen container), ())
          (afterBody, inner) = walk afterOpen (containerBody container)
          unclosed =
            [ FlowIssue IssueUnclosedContainer line 1 "::: container is never closed"
            | not (containerIsClosed container)
            ]
       in (afterBody + linesIn (containerClose container), unclosed <> inner)
    TableBlock rows -> (line + linesIn (Text.concat rows), [])
    StrayBlock text ->
      (line + linesIn text, [FlowIssue IssueStrayContainerClose line 1 "::: closes nothing"])

proseIssues :: Int -> Prose -> (Int, [FlowIssue])
proseIssues line prose =
  ( line + linesIn (printProse prose)
  , maybe [] (\failure -> [located line 0 failure]) (proseError prose)
  )

proseIssuesAfter :: Int -> Text -> Prose -> (Int, [FlowIssue])
proseIssuesAfter line prefix prose =
  ( line + linesIn (prefix <> printProse prose)
  , maybe [] (\failure -> [located line (Text.length prefix) failure]) (proseError prose)
  )

itemsIssues :: Int -> [ListItem] -> (Int, [FlowIssue])
itemsIssues line [] = (line, [])
itemsIssues line (item : rest) =
  let leadColumns = Text.length (itemLead item)
      here = maybe [] (\failure -> [located line leadColumns failure]) (proseError (itemProse item))
      afterText = line + linesIn (printProse (itemProse item))
      (afterNested, nested) = itemsIssues afterText (itemNested item)
      (end, later) = itemsIssues afterNested rest
   in (end, here <> nested <> later)

located :: Int -> Int -> TexSyntaxError -> FlowIssue
located line columnShift failure =
  FlowIssue
    { issueKind = IssueMalformedInline
    , issueLine = line + texErrorLine failure - 1
    , issueColumn =
        if texErrorLine failure <= 1 then texErrorColumn failure + columnShift else texErrorColumn failure
    , issueMessage = texErrorMessage failure
    }
