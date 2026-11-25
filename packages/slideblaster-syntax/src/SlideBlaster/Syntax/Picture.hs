{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Picture
-- Description : Statement reader for the @```slide@ picture tier.
--
-- The picture block is the TikZ superset of the format: nodes placed absolutely,
-- @\\node[options] (id) at (x,y) {content};@, or attached to another node,
-- @\\node[options, below=of other] (id) {content};@. This module splits the
-- block body into statements and recognises these node forms, reading the
-- text with the TikZ reader ("SlideBlaster.Syntax.Tikz.Parse"). Everything
-- else (anything this tier does not edit) is an 'OpaqueStatement'
-- retaining its exact bytes, so the block is always printable by concatenating
-- statement text and unsupported content is reported rather than dropped.
--
-- Total and exact: @'printPicture' ('readPicture' t) == t@ for every 'Text'.
module SlideBlaster.Syntax.Picture
  ( Statement (..)
  , readPicture
  , printPicture
  , statementText
  , optionPairs
  , NodeSpans (..)
  , nodeSpans
  , skipLead
  , catParts
  , catOf
  , catShift
  , attachSides
  , attachmentOf
  , optionItems
  , DrawPath (..)
  , DrawPoint (..)
  , DrawJoin (..)
  , DrawStep (..)
  , DrawLabel (..)
  , readDraw
  , printDraw
  , decimalText
  ) where

import Data.Char (isAlphaNum, isDigit, isSpace)
import Data.Ratio ((%))
import Data.Text (Text)
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import SlideBlaster.Syntax.Tikz.Ast qualified as Tikz
import SlideBlaster.Syntax.Tikz.Parse qualified as Tikz

-- | One statement of the block.
data Statement
  = -- | A supported absolutely placed node. Texts are raw; the @raw@ field is the
    -- whole statement including leading whitespace and the closing semicolon.
    NodeStatement
      { statementOptions :: !Text
      , statementName :: !(Maybe Text)
      , statementX :: !Rational
      , statementY :: !Rational
      , statementContent :: !Text
      , statementRaw :: !Text
      }
  | -- | A node attached to another: no @at@, and one option @side=of target@
    -- or @side=distance of target@ with a side from 'attachSides'. The options
    -- text still holds that option.
    AttachedStatement
      { attachedOptions :: !Text
      , attachedName :: !(Maybe Text)
      , attachedSide :: !Text
      , attachedTarget :: !Text
      , attachedDistance :: !(Maybe Rational)
      -- ^ the written gap in slide units (@1.5@ or @1.5cm@); none means the default
      , attachedContent :: !Text
      , attachedRaw :: !Text
      }
  | -- | Anything else, retained exactly.
    OpaqueStatement !Text
  deriving stock (Eq, Show)

-- | The exact text of a statement.
statementText :: Statement -> Text
statementText statement =
  case statement of
    NodeStatement {statementRaw = raw} -> raw
    AttachedStatement {attachedRaw = raw} -> raw
    OpaqueStatement raw -> raw

-- | Split a block body into statements. Total.
readPicture :: Text -> [Statement]
readPicture body = fmap classify (splitStatements body)

-- | Concatenate statement texts; the exact inverse of 'readPicture'.
printPicture :: [Statement] -> Text
printPicture = foldMap statementText

-- | Split into statements as TikZ reads them ('Tikz.parsePicture'): each piece
-- runs from the end of the statement before it to the end of its own, so the
-- blank space and comment lines in front of a statement belong to it. A scope
-- or a loop is one piece, whatever stands inside it. What follows the last
-- statement (trailing blank space, comments) is kept as a piece of its own.
splitStatements :: Text -> [Text]
splitStatements body =
  let Tikz.Picture _ items = Tikz.parsePicture 0 body
      ends = dedupe [withSemicolon end | item <- items, not (isComment item), let Tikz.Span _ end = Tikz.itemSpan item]
      isComment item = case item of
        Tikz.ItemComment _ -> True
        _ -> False
      -- a statement's semicolon belongs to it, also when the reader left it outside
      withSemicolon end =
        let rest = Text.drop end body
            gap = Text.takeWhile (\c -> c == ' ' || c == '\t') rest
         in if Text.take 1 (Text.drop (Text.length gap) rest) == ";" then end + Text.length gap + 1 else end
      dedupe = go (0 :: Int)
        where
          go _ [] = []
          go last' (e : more) = if e > last' then e : go e more else go last' more
      pieces from found = case found of
        [] -> [Text.drop from body | from < Text.length body]
        end : more -> Text.take (end - from) (Text.drop from body) : pieces end more
   in filter (not . Text.null) (pieces 0 ends)

classify :: Text -> Statement
classify raw =
  case parseNode raw of
    Just statement -> statement
    Nothing -> OpaqueStatement raw

-- | Drop the blank space and whole-line comments in front of a statement.
skipLead :: Text -> Text
skipLead text =
  let rest = Text.stripStart text
   in if "%" `Text.isPrefixOf` rest then skipLead (Text.dropWhile (/= '\n') rest) else rest

-- | The parts of an include statement @\\cat[options]{path};@: what precedes
-- the command (blank space, comment lines), its options without the brackets,
-- the path, and what follows the closing brace.
catParts :: Text -> Maybe (Text, Text, Text, Text)
catParts raw = do
  let body = skipLead raw
      lead = Text.take (Text.length raw - Text.length body) raw
  afterName <- Text.stripPrefix "\\cat" body
  (options, afterOptions) <-
    case Text.stripPrefix "[" afterName of
      Just inner ->
        let (written, rest) = Text.breakOn "]" inner
         in (,) written <$> Text.stripPrefix "]" rest
      Nothing -> Just ("", afterName)
  inner <- Text.stripPrefix "{" afterOptions
  let (path, rest) = Text.breakOn "}" inner
  after <- Text.stripPrefix "}" rest
  if Text.null (Text.strip path) || not (Text.all (\c -> c == ';' || isSpace c) after)
    then Nothing
    else Just (lead, options, Text.strip path, after)

-- | Options and path of an include statement.
catOf :: Text -> Maybe (Text, Text)
catOf raw = (\(_, options, path, _) -> (options, path)) <$> catParts raw

-- | The @shift={(x,y)}@ of an include's options, in slide units; none is no shift.
catShift :: Text -> (Rational, Rational)
catShift options =
  case [v | (k, Just v) <- optionPairs options, k == "shift"] of
    value : _
      | [x, y] <- Text.splitOn "," (Text.filter (\c -> c `notElem` ("{}() " :: String)) value)
      , Just x' <- decimal x
      , Just y' <- decimal y -> (x', y')
    _ -> (0, 0)

parseNode :: Text -> Maybe Statement
parseNode raw = fst <$> readNode raw

-- | Where the editable parts of a node statement sit in its raw text, as
-- character offsets.
data NodeSpans = NodeSpans
  { spansOptionsInsert :: !Int
  -- ^ where a @[options]@ group goes when the node has none (right after @\\node@)
  , spansOptions :: !(Maybe (Int, Int))
  -- ^ the options text inside its brackets
  , spansNameInsert :: !Int
  -- ^ where a @(name)@ goes when the node has none
  , spansAt :: !(Maybe (Int, Int))
  -- ^ @at (x,y)@ with the blank space before it, on an absolutely placed node
  , spansPoint :: !(Maybe (Int, Int))
  -- ^ the @(x,y)@ point including its parentheses
  , spansContentOpen :: !Int
  -- ^ the opening brace of the content
  , spansContent :: !(Int, Int)
  -- ^ the content inside its braces
  }
  deriving stock (Eq, Show)

-- | The spans of a statement 'readPicture' reads as a node; 'Nothing' otherwise.
nodeSpans :: Text -> Maybe NodeSpans
nodeSpans raw = snd <$> readNode raw

-- | The sides a node can be attached on.
attachSides :: [Text]
attachSides = ["above", "below", "left", "right", "above left", "above right", "below left", "below right"]

-- | Read one option item as an attachment: side, target and written distance.
attachmentOf :: Text -> Maybe (Text, Text, Maybe Rational)
attachmentOf item = do
  let (key, rest) = Text.breakOn "=" item
      side = Text.unwords (Text.words key)
      value = Text.strip (Text.drop 1 rest)
  if side `elem` attachSides && not (Text.null rest) then Just () else Nothing
  let (first, afterFirst) = Text.break isSpace value
      (distance, remainder) =
        case decimal (maybe first id (Text.stripSuffix "cm" first)) of
          Just d | first /= "of" -> (Just d, Text.stripStart afterFirst)
          _ -> (Nothing, value)
  target <- Text.strip <$> Text.stripPrefix "of " remainder
  if not (Text.null target) && Text.all (\c -> c /= ' ' && c /= '(' && c /= ')') target
    then Just (side, target, distance)
    else Nothing

-- | An option list split at its top-level commas, each item exactly as written.
optionItems :: Text -> [Text]
optionItems options = if Text.null (Text.strip options) then [] else go (0 :: Int) Text.empty options
  where
    go depth acc remaining =
      case Text.uncons remaining of
        Nothing -> [acc]
        Just (c, rest)
          | c == '{' -> go (depth + 1) (Text.snoc acc c) rest
          | c == '}' -> go (max 0 (depth - 1)) (Text.snoc acc c) rest
          | c == ',' && depth == 0 -> acc : go depth Text.empty rest
          | otherwise -> go depth (Text.snoc acc c) rest

-- The one attaching option of an option list, if there is exactly one.
attachment :: Text -> Maybe (Text, Text, Maybe Rational)
attachment options =
  case [found | Just found <- fmap attachmentOf (optionItems options)] of
    [found] -> Just found
    _ -> Nothing

-- One reader for both node forms, with the offsets of what it read. The
-- statement is read as TikZ reads it ('Tikz.parsePicture'), so the parts of
-- the node may come in any order: @\\node (a) [draw] at (1,2) {x};@ is the
-- same node as @\\node[draw] (a) at (1,2) {x};@. A node this tier edits has at
-- most one option list, a place written as two plain numbers (or one
-- attaching option and no place), and its text.
readNode :: Text -> Maybe (Statement, NodeSpans)
readNode raw = do
  Tikz.ItemPath command <- oneStatement raw
  if Tikz.pathCommand command == "node" then Just () else Nothing
  let Tikz.Span commandStart commandEnd = Tikz.pathSpan command
  -- nothing but the semicolon may follow the node
  if Text.all (\c -> c == ';' || isSpace c) (Text.drop commandEnd raw) then Just () else Nothing
  (leading, node) <- case Tikz.pathOps command of
    [Tikz.OpNode node] -> Just (Nothing, node)
    [Tikz.OpOptions _ options, Tikz.OpNode node] -> Just (Just options, node)
    _ -> Nothing
  if Tikz.nodeKind node == Tikz.KindNode && null (Tikz.nodeForeach node) then Just () else Nothing
  let afterCommand = commandStart + Text.length ("\\node" :: Text)
      optionLists = maybe [] pure leading <> [options | Tikz.PartOptions options <- Tikz.nodeParts node]
      names = [name | Tikz.PartName _ name <- Tikz.nodeParts node]
      places = [coordinate | Tikz.PartAt _ coordinate <- Tikz.nodeParts node]
  if length optionLists > 1 || length names > 1 || length places > 1 || or [True | Tikz.PartAnimation _ <- Tikz.nodeParts node] then Nothing else Just ()
  Tikz.Braced contentSpan content <- Tikz.nodeText node
  let inside (Tikz.Span a b) open = if Text.take 1 (Text.drop a raw) == Text.singleton open then (a + 1, b - 1) else (a, b)
      outside (Tikz.Span a b) open = if Text.take 1 (Text.drop a raw) == Text.singleton open then (a, b) else (a - 1, b + 1)
      optionsSpan = fmap (\(Tikz.Options at _) -> inside at '[') (listToMaybe' optionLists)
      options = maybe "" (\(a, b) -> Text.take (b - a) (Text.drop a raw)) optionsSpan
      name = fmap Text.strip (listToMaybe' names)
      -- a name goes after the option list when that comes first, else right after the command
      nameInsert = case optionsSpan of
        Just (a, b) | Text.null (Text.strip (Text.take (a - 1 - afterCommand) (Text.drop afterCommand raw))) -> b + 1
        _ -> afterCommand
      (contentOpen, _) = outside contentSpan '{'
      (contentStart, contentEnd) = inside contentSpan '{'
      spans atSpan pointSpan =
        NodeSpans
          { spansOptionsInsert = afterCommand
          , spansOptions = optionsSpan
          , spansNameInsert = nameInsert
          , spansAt = atSpan
          , spansPoint = pointSpan
          , spansContentOpen = contentOpen
          , spansContent = (contentStart, contentEnd)
          }
  case listToMaybe' places of
    Just coordinate -> do
      (xText, yText) <- case (Tikz.coordRelative coordinate, Tikz.coordOptions coordinate, Tikz.coordBody coordinate) of
        (Tikz.Absolute, Nothing, Tikz.CoordXY x y) -> Just (Text.strip x, Text.strip y)
        _ -> Nothing
      x <- decimal xText
      y <- decimal yText
      let (pointStart, pointEnd) = outside' (Tikz.coordSpan coordinate)
          outside' (Tikz.Span a b) = if Text.take 1 (Text.drop a raw) == "(" then (a, b) else (a - 1, b + 1)
          -- @at@ with the blank space before it
          beforePoint = Text.stripEnd (Text.take pointStart raw)
          atStart = if "at" `Text.isSuffixOf` beforePoint then Text.length (Text.stripEnd (Text.dropEnd 2 beforePoint)) else pointStart
      Just (NodeStatement options name x y content raw, spans (Just (atStart, pointEnd)) (Just (pointStart, pointEnd)))
    Nothing -> do
      (side, target, distance) <- attachment options
      Just (AttachedStatement options name side target distance content raw, spans Nothing Nothing)
  where
    listToMaybe' found = case found of
      first : _ -> Just first
      [] -> Nothing

-- The one statement of a piece of text (comments aside), as TikZ reads it.
oneStatement :: Text -> Maybe Tikz.Item
oneStatement raw =
  let Tikz.Picture _ items = Tikz.parsePicture 0 raw
   in case [item | item <- items, not (isComment item)] of
        [single] -> Just single
        _ -> Nothing
  where
    isComment item = case item of
      Tikz.ItemComment _ -> True
      _ -> False

-- | A plain decimal such as @12.5@ or @-3@.
decimal :: Text -> Maybe Rational
decimal text =
  case Text.uncons text of
    Just ('-', rest) -> negate <$> unsigned rest
    _ -> unsigned text
  where
    unsigned t =
      let (whole, fraction) = Text.break (== '.') t
          digits = Text.drop 1 fraction
       in if not (Text.null whole)
            && Text.all isDigit whole
            && Text.all isDigit digits
            && (Text.null fraction || not (Text.null digits))
            then
              Just
                ( fromInteger (readInteger whole)
                    + fromInteger (readInteger digits) / fromInteger (10 ^ Text.length digits)
                )
            else Nothing
    readInteger = Text.foldl' (\acc c -> acc * 10 + toInteger (fromEnum c - fromEnum '0')) 0

-- | Split an option list at top-level commas into key and optional value; the
-- value of @key={a,b}@ keeps its inner braces stripped.
optionPairs :: Text -> [(Text, Maybe Text)]
optionPairs options = [pair item | item <- splitTop options, not (Text.null (Text.strip item))]
  where
    pair item =
      case Text.breakOn "=" item of
        (key, rest)
          | Text.null rest -> (Text.strip key, Nothing)
          | otherwise -> (Text.strip key, Just (unbrace (Text.strip (Text.drop 1 rest))))
    unbrace v = maybe v id (Text.stripPrefix "{" v >>= Text.stripSuffix "}")
    splitTop = go (0 :: Int) Text.empty
    go depth acc remaining =
      case Text.uncons remaining of
        Nothing -> [acc]
        Just (c, rest)
          | c == '{' -> go (depth + 1) (Text.snoc acc c) rest
          | c == '}' -> go (max 0 (depth - 1)) (Text.snoc acc c) rest
          | c == ',' && depth == 0 -> acc : go depth Text.empty rest
          | isSpace c && Text.null acc -> go depth acc rest
          | otherwise -> go depth (Text.snoc acc c) rest

-- Lines ---------------------------------------------------------------------

-- | A @\\draw@ statement as a path: a first point, then steps that each join
-- on to a next point and may carry labels.
--
-- @\\draw[->] (a) -- node[auto] {yes} (b) -| (c.north) to[bend left] (3,4);@
data DrawPath = DrawPath
  { drawLead :: !Text
  -- ^ blank space and comment lines in front of the command
  , drawOptions :: !Text
  , drawStart :: !DrawPoint
  , drawSteps :: ![DrawStep]
  , drawTail :: !Text
  -- ^ what follows the semicolon
  }
  deriving stock (Eq, Show)

-- | An end or corner of a path: a node (with an anchor such as @north@ or an
-- angle, when one is written) or a point in slide units.
data DrawPoint
  = DrawNode !Text !(Maybe Text)
  | DrawAt !Rational !Rational
  deriving stock (Eq, Show)

-- | How a step reaches its point: straight (@--@), along x then y (@-|@),
-- along y then x (@|-@), or @to@ with its options (@bend left=30@, @out=90, in=180@).
data DrawJoin = JoinStraight | JoinHV | JoinVH | JoinTo !Text
  deriving stock (Eq, Show)

-- | @node[options] {content}@ on a path.
data DrawLabel = DrawLabel
  { drawLabelOptions :: !Text
  , drawLabelContent :: !Text
  }
  deriving stock (Eq, Show)

data DrawStep = DrawStep
  { stepJoin :: !DrawJoin
  , stepLabels :: ![DrawLabel]
  -- ^ written between the join and the point: they sit along the step
  , stepPoint :: !DrawPoint
  , stepAfter :: ![DrawLabel]
  -- ^ written after the point: they sit at it
  }
  deriving stock (Eq, Show)

-- | Read a @\\draw@ statement of this form; anything else is 'Nothing' and
-- stays opaque. The statement is read as TikZ reads it ('Tikz.parsePicture').
readDraw :: Text -> Maybe DrawPath
readDraw raw = do
  Tikz.ItemPath command <- oneStatement raw
  if Tikz.pathCommand command == "draw" && Tikz.pathOverlay command == Nothing then Just () else Nothing
  let Tikz.Span commandStart commandEnd = Tikz.pathSpan command
      lead = Text.take commandStart raw
      after = Text.drop commandEnd raw
      rest = fromMaybe after (Text.stripPrefix ";" (Text.stripStart after))
      written (Tikz.Options (Tikz.Span a b) _) = if Text.take 1 (Text.drop a raw) == "[" then Text.take (b - a - 2) (Text.drop (a + 1) raw) else Text.take (b - a) (Text.drop a raw)
      (options, ops) = case Tikz.pathOps command of
        Tikz.OpOptions _ found : more -> (written found, more)
        more -> ("", more)
      pointOf coordinate =
        case (Tikz.coordRelative coordinate, Tikz.coordOptions coordinate, Tikz.coordBody coordinate) of
          (Tikz.Absolute, Nothing, Tikz.CoordXY x y) -> DrawAt <$> signed (Text.strip x) <*> signed (Text.strip y)
          (Tikz.Absolute, Nothing, Tikz.CoordNode name anchor) ->
            let wordy = Text.all (\c -> isAlphaNum c || c == '-' || c == '_')
                named = Text.strip name
                anchorText = fmap Text.strip anchor
             in if not (Text.null named) && wordy named && maybe True (\a -> not (Text.null a) && Text.all (\c -> isAlphaNum c || c == ' ' || c == '-' || c == '.') a) anchorText
                  then Just (DrawNode named anchorText)
                  else Nothing
          _ -> Nothing
      labelOf op = case op of
        Tikz.OpNode node
          | Tikz.nodeKind node == Tikz.KindNode
          , null (Tikz.nodeForeach node)
          , Just (Tikz.Braced _ content) <- Tikz.nodeText node ->
              case Tikz.nodeParts node of
                [] -> Just (DrawLabel "" content)
                [Tikz.PartOptions found] -> Just (DrawLabel (written found) content)
                _ -> Nothing
        _ -> Nothing
      target to = case to of
        Tikz.TargetAt coordinate -> pointOf coordinate
        Tikz.TargetCycle _ -> Nothing
      -- the labels written after a point, and what is left
      trailing found = case found of
        op : more | Just label <- labelOf op -> let (labels, left) = trailing more in (label : labels, left)
        _ -> ([], found)
      steps found = case found of
        [] -> Just []
        Tikz.OpLine _ join before to : more -> stepWith (case join of Tikz.JoinLine -> JoinStraight; Tikz.JoinHV -> JoinHV; Tikz.JoinVH -> JoinVH) before to more
        Tikz.OpTo _ [] before to : more -> stepWith (JoinTo "") before to more
        Tikz.OpTo _ [found'] before to : more -> stepWith (JoinTo (written found')) before to more
        _ -> Nothing
      stepWith join before to more = do
        labels <- traverse labelOf before
        point' <- target to
        let (afterLabels, left) = trailing more
        (DrawStep join labels point' afterLabels :) <$> steps left
  case ops of
    Tikz.OpMove _ first : more -> do
      start <- pointOf first
      found <- steps more
      if null found then Nothing else Just (DrawPath lead options start found rest)
    _ -> Nothing
  where
    signed t = do
      let (sign, digits) = case Text.uncons t of
            Just ('-', more) -> (-1, more)
            Just ('+', more) -> (1, more)
            _ -> (1 :: Integer, t)
          (whole, fraction) = Text.breakOn "." digits
          places = Text.drop 1 fraction
      if Text.null (whole <> places) || not (Text.all isDigit (whole <> places)) || (not (Text.null fraction) && Text.null places && Text.null whole) then Nothing else Just ()
      Just ((sign * read (Text.unpack ("0" <> whole <> places))) % (10 ^ Text.length places))

-- | Write a path with single spaces between its parts. What the path does
-- not hold (the spacing as written) is not kept: print only a changed path.
printDraw :: DrawPath -> Text
printDraw path =
  drawLead path <> "\\draw" <> grouped (drawOptions path) <> " " <> pointOf (drawStart path) <> Text.concat (fmap stepOf (drawSteps path)) <> ";" <> drawTail path
  where
    grouped options = if Text.null (Text.strip options) then "" else "[" <> options <> "]"
    pointOf at = case at of
      DrawNode name anchor -> "(" <> name <> maybe "" ("." <>) anchor <> ")"
      DrawAt x y -> "(" <> decimalText x <> "," <> decimalText y <> ")"
    labelOf (DrawLabel options content) = " node" <> grouped options <> " {" <> content <> "}"
    joinOf join = case join of
      JoinStraight -> "--"
      JoinHV -> "-|"
      JoinVH -> "|-"
      JoinTo options -> "to" <> grouped options
    stepOf (DrawStep join before to after) = " " <> joinOf join <> Text.concat (fmap labelOf before) <> " " <> pointOf to <> Text.concat (fmap labelOf after)

-- | A number as written in a picture: at most two decimals, none when whole.
decimalText :: Rational -> Text
decimalText value =
  let hundredths = round (value * 100) :: Integer
      (whole, part) = abs hundredths `quotRem` 100
      sign = if hundredths < 0 then "-" else ""
      digits
        | part == 0 = ""
        | part `rem` 10 == 0 = "." <> Text.pack (show (part `quot` 10))
        | otherwise = "." <> Text.pack (if part < 10 then "0" <> show part else show part)
   in sign <> Text.pack (show whole) <> digits
