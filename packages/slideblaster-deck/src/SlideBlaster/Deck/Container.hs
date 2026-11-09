{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Deck.Container
-- Description : Lossless span container for @*.slideBlaster.md@ decks.
--
-- A deck is @frontmatter? preamble-text? slide*@. This module finds the spans and
-- nothing else: it never rewrites bytes, and every position is a byte offset into
-- the exact UTF-8 source. The slide body is later read by
-- "SlideBlaster.Syntax.Block".
--
-- == Laws
--
-- * @'printContainer' c@ equals the source: the frontmatter, preamble and slide
--   texts partition the bytes exactly.
-- * A slide's span runs from the first byte of its @## @ heading line to the first
--   byte of the next heading line (or the end), so editing one slide's bytes
--   cannot affect another slide's span.
-- * Headings inside fenced code (@```@ / @~~~@) are not slide boundaries.
--
-- == Read-only inputs
--
-- Input that cannot be admitted without guessing is a 'ContainerError', which the
-- document layer turns into a syntax-only (read-only) document with a hard
-- diagnostic: invalid UTF-8, an unclosed frontmatter fence, a malformed or
-- duplicated @{#id}@. Nothing is rewritten.
module SlideBlaster.Deck.Container
  ( Container (..)
  , SlideEntry (..)
  , SectionEntry (..)
  , IncludeEntry (..)
  , ContainerError (..)
  , readContainer
  , printContainer
  , Span (..)
  , spanLength
  , spanOfSlide
  , validSlideId
  , lineStarts
  , includeLinesOf
  ) where

import SlideBlaster.Deck.Frontmatter (Frontmatter, emptyFrontmatter, parseFrontmatter)
import SlideBlaster.Deck.Include (IncludeLine (..), parseIncludeLine)

import Data.ByteString (ByteString)
import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.Encoding.Error qualified as EncodingError
import Data.Text.Unsafe (lengthWord8)
import Data.List (nub, sortOn)

-- | A half-open byte range.
data Span = Span !Int !Int
  deriving stock (Eq, Ord, Show)

spanLength :: Span -> Int
spanLength (Span a b) = b - a

-- | One slide's exact structure.
data SlideEntry = SlideEntry
  { slideText :: !Text
  -- ^ The whole slide: heading line through the end of its body.
  , slideSpan :: !Span
  , slideHeadingSpan :: !Span
  -- ^ The heading line without its line ending.
  , slideTitleText :: !Text
  -- ^ Heading text after @## @, before any @{#id}@, trimmed.
  , slideIdText :: !(Maybe Text)
  , slideIdSpan :: !(Maybe Span)
  -- ^ The id characters between @{#@ and @}@.
  , slideBodyText :: !Text
  -- ^ Everything after the heading line.
  , slideBodySpan :: !Span
  , slideStartLine :: !Int
  -- ^ One-based line of the heading.
  }
  deriving stock (Eq, Show)

-- | A section: a column-0 @# Title {#id}@ line outside fences. It owns no bytes
-- of any slide; its span runs from the heading to the next heading and holds
-- only the heading and any prose before the next slide.
data SectionEntry = SectionEntry
  { sectionText :: !Text
  , sectionSpan :: !Span
  , sectionHeadingSpan :: !Span
  , sectionTitleText :: !Text
  , sectionIdText :: !(Maybe Text)
  , sectionIdSpan :: !(Maybe Span)
  , sectionStartLine :: !Int
  , sectionNoDivider :: !Bool
  -- ^ @{#id .nodivider}@: no divider slide for this section
  , sectionBodyText :: !Text
  -- ^ Text after the heading line; the divider's subtitle comes from it.
  , sectionSlidesBefore :: !Int
  -- ^ How many slides precede the section; the slides from this index on
  -- belong to it until the next section.
  }
  deriving stock (Eq, Show)

-- | A block-level @\\include[opts]{path}@ line between slides. It owns the line
-- and any prose after it up to the next heading or include; it is no slide.
data IncludeEntry = IncludeEntry
  { includeText :: !Text
  , includeSpan :: !Span
  , includeLineSpan :: !Span
  -- ^ the directive line without its line ending
  , includeLine :: !IncludeLine
  , includeStartLine :: !Int
  , includeSlidesBefore :: !Int
  -- ^ how many slides precede the include
  }
  deriving stock (Eq, Show)

-- | The whole deck.
data Container = Container
  { containerFrontmatterText :: !Text
  -- ^ From the opening fence through the line after the closing fence; empty
  -- when there is none.
  , containerFrontmatterSpan :: !Span
  , containerFrontmatter :: !(Maybe Frontmatter)
  , containerPreambleText :: !Text
  -- ^ Text between the frontmatter and the first slide.
  , containerPreambleSpan :: !Span
  , containerSlides :: ![SlideEntry]
  , containerSections :: ![SectionEntry]
  , containerIncludes :: ![IncludeEntry]
  , containerLength :: !Int
  }
  deriving stock (Eq, Show)

-- | Why a deck could not be admitted.
data ContainerError
  = InvalidUtf8
  | UnclosedFrontmatter !Int
  | InvalidSlideId !Int !Text
  | DuplicateSlideId !Int !Text
  | InvalidSectionId !Int !Text
  | DuplicateSectionId !Int !Text
  deriving stock (Eq, Show)

-- | The slide and section texts and the rest, in order; equals the decoded source.
printContainer :: Container -> Text
printContainer c =
  containerFrontmatterText c <> containerPreambleText c <> foldMap snd (sortOn fst pieces)
  where
    pieces =
      [(a, slideText e) | e <- containerSlides c, let Span a _ = slideSpan e]
        <> [(a, sectionText e) | e <- containerSections c, let Span a _ = sectionSpan e]
        <> [(a, includeText e) | e <- containerIncludes c, let Span a _ = includeSpan e]

-- | The span of a slide.
spanOfSlide :: SlideEntry -> Span
spanOfSlide = slideSpan

-- | @[a-z0-9][a-z0-9-]*@
validSlideId :: Text -> Bool
validSlideId t =
  case Text.uncons t of
    Just (c, rest) -> alnum c && Text.all (\x -> alnum x || x == '-') rest
    Nothing -> False
  where
    alnum c = isAsciiLower c || isDigit c

-- | Decode and split. Total.
readContainer :: ByteString -> Either ContainerError Container
readContainer bytes =
  case Encoding.decodeUtf8' bytes of
    Left (_ :: EncodingError.UnicodeException) -> Left InvalidUtf8
    Right text -> readText text

-- | Byte offset of each line start, with the line text including its ending.
lineStarts :: Text -> [(Int, Text)]
lineStarts = go 0 . splitKeep
  where
    go _ [] = []
    go offset (l : rest) = (offset, l) : go (offset + lengthWord8 l) rest

splitKeep :: Text -> [Text]
splitKeep text
  | Text.null text = []
  | otherwise =
      let (before, after) = Text.break (== '\n') text
       in case Text.uncons after of
            Nothing -> [before]
            Just (_, remaining) -> Text.snoc before '\n' : splitKeep remaining

readText :: Text -> Either ContainerError Container
readText text = do
  let allLines = lineStarts text
      total = lengthWord8 text
  (frontLines, rest, frontmatter) <- splitFrontmatter allLines
  let frontText = Text.concat (fmap snd frontLines)
      frontEnd = lengthWord8 frontText
      restStart = case rest of
        (o, _) : _ -> o
        [] -> total
      (preamble, groups) = splitGroups rest
      preambleText = Text.concat (fmap snd preamble)
      lineNumbers = lineNumberOf allLines
      slideGroups = [g | SlideGroup g <- groups]
      slidesBefore = scanl (\n g -> case g of SlideGroup _ -> n + 1; _ -> n) (0 :: Int) groups
  slides <- traverse (buildSlide lineNumbers total) slideGroups
  sections <- sequenceA [buildSection lineNumbers before g | (before, SectionGroup g) <- zip slidesBefore groups]
  let includes = [buildInclude lineNumbers before g | (before, IncludeGroup g) <- zip slidesBefore groups]
      ids = [(slideStartLine s, i) | s <- slides, Just i <- [slideIdText s]]
      sectionIds = [(sectionStartLine s, i) | s <- sections, Just i <- [sectionIdText s]]
  case (firstDuplicate (fmap snd ids), firstDuplicate (fmap snd sectionIds)) of
    (Just dup, _) -> Left (DuplicateSlideId (maybe 1 id (lookup' dup ids)) dup)
    (_, Just dup) -> Left (DuplicateSectionId (maybe 1 id (lookup' dup sectionIds)) dup)
    _ ->
      Right
        Container
          { containerFrontmatterText = frontText
          , containerFrontmatterSpan = Span 0 frontEnd
          , containerFrontmatter = frontmatter
          , containerPreambleText = preambleText
          , containerPreambleSpan = Span restStart (restStart + lengthWord8 preambleText)
          , containerSlides = slides
          , containerSections = sections
          , containerIncludes = includes
          , containerLength = total
          }
  where
    lookup' k pairs = case [l | (l, v) <- pairs, v == k] of
      _ : l : _ -> Just l
      l : _ -> Just l
      [] -> Nothing
    firstDuplicate xs = case [x | x <- nub xs, length (filter (== x) xs) > 1] of
      x : _ -> Just x
      [] -> Nothing

-- | Map a byte offset to its one-based line number.
lineNumberOf :: [(Int, Text)] -> Int -> Int
lineNumberOf ls offset = 1 + length (takeWhile (\(o, _) -> o < offset) ls)

splitFrontmatter
  :: [(Int, Text)]
  -> Either ContainerError ([(Int, Text)], [(Int, Text)], Maybe Frontmatter)
splitFrontmatter ls =
  case ls of
    (_, first) : rest
      | isFence first ->
          let (inside, after) = break (isFence . snd) rest
           in case after of
                [] -> Left (UnclosedFrontmatter 1)
                closing : remaining ->
                  Right
                    ( head' ls <> inside <> [closing]
                    , remaining
                    , Just (parseFrontmatter (fmap (stripEol . snd) inside))
                    )
    _ -> Right ([], ls, Nothing)
  where
    head' xs = take 1 xs
    isFence l = let t = Text.stripEnd (stripEol l) in t == "---" || (t == "..." && False)

stripEol :: Text -> Text
stripEol = Text.dropWhileEnd (\c -> c == '\n' || c == '\r')

-- | One run of lines opened by a heading: a slide (@## @) or a section (@# @).
data Group = SlideGroup [(Int, Text)] | SectionGroup [(Int, Text)] | IncludeGroup [(Int, Text)]

data Boundary = SlideBoundary | SectionBoundary | IncludeBoundary

-- | Split lines into the text before the first heading and the groups after
-- it, ignoring headings inside fenced code. A @# @ line opens a section when
-- it carries an @{#id}@ or follows a heading; before that it stays preamble
-- text, where it is the deck title.
splitGroups :: [(Int, Text)] -> ([(Int, Text)], [Group])
splitGroups ls = (reverse preambleRev, reverse (close current doneRev))
  where
    (preambleRev, current, doneRev) = foldl step ([], Nothing, []) (classify ls)
    step (pre, open, done) (Just b, item) = (pre, Just (b, [item]), close open done)
    step (pre, Just (b, acc), done) (Nothing, item) = (pre, Just (b, item : acc), done)
    step (pre, Nothing, done) (Nothing, item) = (item : pre, Nothing, done)
    close Nothing done = done
    close (Just (b, acc)) done = group b (reverse acc) : done
    group SlideBoundary = SlideGroup
    group SectionBoundary = SectionGroup
    group IncludeBoundary = IncludeGroup

classify :: [(Int, Text)] -> [(Maybe Boundary, (Int, Text))]
classify = go Nothing False
  where
    go _ _ [] = []
    go fence seen (item@(_, l) : rest) =
      case fence of
        Just f -> (Nothing, item) : go (if closesFence f l then Nothing else Just f) seen rest
        Nothing
          | isHeading l -> (Just SlideBoundary, item) : go Nothing True rest
          | isIncludeLine l -> (Just IncludeBoundary, item) : go Nothing True rest
          | isSectionHeading l && (seen || hasIdSuffix l) -> (Just SectionBoundary, item) : go Nothing True rest
          | otherwise -> (Nothing, item) : go (opens l) seen rest

-- | A column-0 @\\include[..]{..}@ line.
isIncludeLine :: Text -> Bool
isIncludeLine l = "\\include" `Text.isPrefixOf` l && maybe False (const True) (parseIncludeLine l)

-- | The include lines of deck text outside fences, for tools that only need the
-- paths. Empty when the deck is not admitted.
includeLinesOf :: ByteString -> [IncludeLine]
includeLinesOf bytes = either (const []) (fmap includeLine . containerIncludes) (readContainer bytes)

-- | A slide heading line: @## @ at column 0.
isHeading :: Text -> Bool
isHeading l = "## " `Text.isPrefixOf` l || stripEol l == "##"

-- | A section heading line: @# @ at column 0 (not @## @).
isSectionHeading :: Text -> Bool
isSectionHeading l = "# " `Text.isPrefixOf` l || stripEol l == "#"

hasIdSuffix :: Text -> Bool
hasIdSuffix l =
  let t = Text.stripEnd (stripEol l)
   in "}" `Text.isSuffixOf` t && "{#" `Text.isInfixOf` t

opens :: Text -> Maybe (Char, Int)
opens l =
  let body = stripEol l
      stripped = Text.dropWhile (== ' ') body
      indent = Text.length body - Text.length stripped
   in case Text.uncons stripped of
        Just (c, _)
          | (c == '`' || c == '~') && indent <= 3 ->
              let run = Text.takeWhile (== c) stripped
                  info = Text.drop (Text.length run) stripped
               in if Text.length run >= 3 && not (c == '`' && Text.any (== '`') info)
                    then Just (c, Text.length run)
                    else Nothing
        _ -> Nothing

closesFence :: (Char, Int) -> Text -> Bool
closesFence (c, n) l =
  let body = stripEol l
      stripped = Text.dropWhile (== ' ') body
      run = Text.takeWhile (== c) stripped
   in Text.length body - Text.length stripped <= 3
        && Text.length run >= n
        && Text.all (\x -> x == ' ' || x == '\t') (Text.drop (Text.length run) stripped)

buildSlide :: (Int -> Int) -> Int -> [(Int, Text)] -> Either ContainerError SlideEntry
buildSlide lineNumber _ slideLines =
  case slideLines of
    [] -> Left InvalidUtf8
    (start, heading) : bodyLines -> do
      let headingBody = stripEol heading
          afterHashes = Text.drop 3 headingBody
          (titlePart, identifier) = splitId afterHashes
          headingLength = lengthWord8 headingBody
          bodyText = Text.concat (fmap snd bodyLines)
          wholeText = heading <> bodyText
          line = lineNumber start
      idParts <-
        case identifier of
          Nothing -> Right Nothing
          Just (raw, offsetInHeading) ->
            if validSlideId raw
              then Right (Just (raw, Span (start + offsetInHeading) (start + offsetInHeading + lengthWord8 raw)))
              else Left (InvalidSlideId line raw)
      Right
        SlideEntry
          { slideText = wholeText
          , slideSpan = Span start (start + lengthWord8 wholeText)
          , slideHeadingSpan = Span start (start + headingLength)
          , slideTitleText = Text.strip titlePart
          , slideIdText = fmap fst idParts
          , slideIdSpan = fmap snd idParts
          , slideBodyText = bodyText
          , slideBodySpan = Span (start + lengthWord8 heading) (start + lengthWord8 wholeText)
          , slideStartLine = line
          }

buildInclude :: (Int -> Int) -> Int -> [(Int, Text)] -> IncludeEntry
buildInclude lineNumber before groupLines =
  case groupLines of
    (start, directive) : _ ->
      let whole = Text.concat (fmap snd groupLines)
       in IncludeEntry
            { includeText = whole
            , includeSpan = Span start (start + lengthWord8 whole)
            , includeLineSpan = Span start (start + lengthWord8 (stripEol directive))
            , includeLine = maybe (IncludeLine [] "") id (parseIncludeLine directive)
            , includeStartLine = lineNumber start
            , includeSlidesBefore = before
            }
    [] -> IncludeEntry "" (Span 0 0) (Span 0 0) (IncludeLine [] "") 1 before

buildSection :: (Int -> Int) -> Int -> [(Int, Text)] -> Either ContainerError SectionEntry
buildSection lineNumber before sectionLines =
  case sectionLines of
    [] -> Left InvalidUtf8
    (start, heading) : bodyLines -> do
      let headingBody = stripEol heading
          (titlePart, identifier0) = splitIdAt 2 (Text.drop 2 headingBody)
          -- the id is the first word inside {#..}; later words are classes
          identifier = fmap (\(raw, o) -> (headWord raw, o)) identifier0
          headWord raw = case Text.words raw of w : _ -> w; [] -> raw
          classes = case identifier0 of Just (raw, _) -> drop 1 (Text.words raw); Nothing -> []
          wholeText = Text.concat (fmap snd sectionLines)
          line = lineNumber start
      idParts <-
        case identifier of
          Nothing -> Right Nothing
          Just (raw, offsetInHeading)
            | validSlideId raw -> Right (Just (raw, Span (start + offsetInHeading) (start + offsetInHeading + lengthWord8 raw)))
            | otherwise -> Left (InvalidSectionId line raw)
      Right
        SectionEntry
          { sectionText = wholeText
          , sectionSpan = Span start (start + lengthWord8 wholeText)
          , sectionHeadingSpan = Span start (start + lengthWord8 headingBody)
          , sectionTitleText = Text.strip titlePart
          , sectionIdText = fmap fst idParts
          , sectionIdSpan = fmap snd idParts
          , sectionStartLine = line
          , sectionNoDivider = ".nodivider" `elem` classes
          , sectionBodyText = Text.concat (fmap snd bodyLines)
          , sectionSlidesBefore = before
          }

-- | Split @title {#id}@; the offset is the id's byte offset within the heading.
splitId :: Text -> (Text, Maybe (Text, Int))
splitId = splitIdAt 3

-- | 'splitId' for a heading whose marker (@## @, @# @) is the given width.
splitIdAt :: Int -> Text -> (Text, Maybe (Text, Int))
splitIdAt markerWidth afterHashes =
  let trimmed = Text.stripEnd afterHashes
   in case Text.breakOnEnd "{#" trimmed of
        (before, after)
          | not (Text.null before)
          , "}" `Text.isSuffixOf` after
          , Text.length after >= 1 ->
              let raw = Text.dropEnd 1 after
                  titleText = Text.dropEnd 2 before
                  offset = markerWidth + lengthWord8 before
               in (titleText, Just (raw, offset))
        _ -> (afterHashes, Nothing)

_unusedEmpty :: Frontmatter
_unusedEmpty = emptyFrontmatter
