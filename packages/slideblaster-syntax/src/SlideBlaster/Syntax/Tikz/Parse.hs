{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Tikz.Parse
-- Description : Reads TikZ source into its syntax tree.
--
-- The reader does what TikZ's scanner does, without running TeX: it splits a
-- picture into statements, a path statement at its semicolon, and reads the
-- path's operations in the order the dispatcher of @tikz.code.tex@ tests for
-- them. Delimiters are matched as TeX matches them: an option list ends at
-- the first @]@ outside braces, a coordinate at the first @)@ outside braces
-- (or at @$)@ when it starts with @$@), an option list splits at commas
-- outside braces.
--
-- It never fails as a whole. A path statement it cannot read becomes
-- 'ItemUnread' with the reason; everything else it does not know is kept as
-- 'ItemCommand'. Nothing is expanded: a macro in a path is 'OpMacro', a
-- macro in a coordinate is part of that coordinate's text.
module SlideBlaster.Syntax.Tikz.Parse
  ( parsePicture
  , parseDocument
  , parseOptions
  , parseCoordinate
  , pathCommandNames
  ) where

import SlideBlaster.Syntax.Tikz.Ast

import Data.Char (isAlpha, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text

-- Tokens --------------------------------------------------------------------

data Kind = KCs | KOpen | KClose | KComment | KSpace | KWord | KChar | KEnd
  deriving stock (Eq, Show)

-- A token: its kind, where it starts, its text.
data Tok = Tok !Kind !Int !Text
  deriving stock (Eq, Show)

tokEnd :: Tok -> Int
tokEnd (Tok _ start text) = start + Text.length text

-- Tokens of a text that starts at the given offset, closed by an end mark.
tokens :: Int -> Text -> [Tok]
tokens offset text =
  case Text.uncons text of
    Nothing -> [Tok KEnd offset ""]
    Just (c, rest)
      | c == '\\' ->
          let name = Text.takeWhile (\x -> isAlpha x || x == '@') rest
              taken = if Text.null name then Text.take 1 rest else name
           in emit KCs (Text.cons c taken)
      | c == '{' -> emit KOpen "{"
      | c == '}' -> emit KClose "}"
      | c == '%' -> emit KComment (Text.takeWhile (/= '\n') text)
      | isSpace c -> emit KSpace (Text.takeWhile isSpace text)
      | isAlpha c -> emit KWord (Text.takeWhile isAlpha text)
      | otherwise -> emit KChar (Text.singleton c)
  where
    emit kind piece = Tok kind offset piece : tokens (offset + Text.length piece) (Text.drop (Text.length piece) text)

textOf :: [Tok] -> Text
textOf = Text.concat . fmap (\(Tok _ _ t) -> t)

isBlank :: Tok -> Bool
isBlank (Tok kind _ _) = kind == KSpace || kind == KComment

trimToks :: [Tok] -> [Tok]
trimToks = reverse . dropWhile isBlank . reverse . dropWhile isBlank

spanOf :: Int -> [Tok] -> Span
spanOf fallback toks =
  case toks of
    [] -> Span fallback fallback
    first@(Tok _ start _) : _ -> Span start (tokEnd (lastOr first toks))

lastOr :: a -> [a] -> a
lastOr fallback list = case reverse list of
  final : _ -> final
  [] -> fallback

-- Tokens up to (not including) the first one at brace depth 0 that the test
-- accepts, and the rest starting with it. Nothing when there is none, or a
-- group closes that was not opened here.
breakOuter :: ([Tok] -> Bool) -> [Tok] -> Maybe ([Tok], [Tok])
breakOuter stop = go (0 :: Int) []
  where
    go depth seen toks =
      case toks of
        [] -> Nothing
        Tok KEnd _ _ : _ -> Nothing
        _ | depth == 0, stop toks -> Just (reverse seen, toks)
        t@(Tok KOpen _ _) : rest -> go (depth + 1) (t : seen) rest
        t@(Tok KClose _ _) : rest
          | depth == 0 -> Nothing
          | otherwise -> go (depth - 1) (t : seen) rest
        t : rest -> go depth (t : seen) rest

isChar :: Char -> [Tok] -> Bool
isChar c toks = case toks of
  Tok KChar _ t : _ -> t == Text.singleton c
  _ -> False

isWord :: Text -> [Tok] -> Bool
isWord w toks = case toks of
  Tok KWord _ t : _ -> t == w
  _ -> False

-- Split at every token at brace depth 0 that the test accepts.
splitOuter :: (Tok -> Bool) -> [Tok] -> [[Tok]]
splitOuter at = go (0 :: Int) []
  where
    go depth seen toks =
      case toks of
        [] -> [reverse seen]
        t@(Tok kind _ _) : rest
          | kind == KEnd -> [reverse seen]
          | depth == 0, at t -> reverse seen : go depth [] rest
          | kind == KOpen -> go (depth + 1) (t : seen) rest
          | kind == KClose -> go (max 0 (depth - 1)) (t : seen) rest
          | otherwise -> go depth (t : seen) rest

-- Parser --------------------------------------------------------------------

-- What is left to read, and where the last token read ended.
data S = S !Int ![Tok]

newtype P a = P (S -> Either Text (a, S))

runP :: P a -> S -> Either Text (a, S)
runP (P f) = f

instance Functor P where
  fmap f (P p) = P (\s -> case p s of Left e -> Left e; Right (a, s') -> Right (f a, s'))

instance Applicative P where
  pure a = P (\s -> Right (a, s))
  P pf <*> P pa = P (\s -> case pf s of
    Left e -> Left e
    Right (f, s') -> case pa s' of
      Left e -> Left e
      Right (a, s'') -> Right (f a, s''))

instance Monad P where
  P p >>= f = P (\s -> case p s of
    Left e -> Left e
    Right (a, s') -> runP (f a) s')

failP :: Text -> P a
failP message = P (\_ -> Left message)

look :: P [Tok]
look = P (\s@(S _ toks) -> Right (toks, s))

-- Where the next token starts.
here :: P Int
here = P (\s@(S end toks) -> Right (case toks of Tok _ start _ : _ -> start; [] -> end, s))

-- Where the last token read ended.
sofar :: P Int
sofar = P (\s@(S end _) -> Right (end, s))

next :: P Tok
next = P (\(S end toks) -> case toks of
  t@(Tok kind _ _) : rest | kind /= KEnd -> Right (t, S (tokEnd t) rest)
  _ -> Left ("the statement ends at " <> Text.pack (show end) <> " before it is complete"))

-- Take these tokens, which are the next ones.
takeToks :: [Tok] -> P ()
takeToks taken = P (\(S end toks) -> Right ((), S (case reverse taken of t : _ -> tokEnd t; [] -> end) (drop (length taken) toks)))

ws :: P ()
ws = P (\(S end toks) -> let (blank, rest) = span isBlank toks in Right ((), S (case reverse blank of t : _ -> tokEnd t; [] -> end) rest))

atEnd :: P Bool
atEnd = (\toks -> case toks of Tok KEnd _ _ : _ -> True; [] -> True; _ -> False) <$> look

char :: Char -> P ()
char c = do
  toks <- look
  if isChar c toks then () <$ next else failP ("expected " <> Text.singleton c)

word :: Text -> P ()
word w = do
  toks <- look
  if isWord w toks then () <$ next else failP ("expected " <> w)

-- Read with a parser from a start position and return the span read.
spanned :: P a -> P (Span, a)
spanned p = do
  start <- here
  a <- p
  end <- sofar
  pure (Span start (max start end), a)

-- Run a parser on a list of tokens as if they were all there is.
within :: [Tok] -> Int -> P a -> Either Text a
within toks end p =
  let start = case toks of Tok _ s _ : _ -> s; [] -> end
   in case runP (p <* ws) (S start (toks <> [Tok KEnd end ""])) of
        Left e -> Left e
        Right (a, S _ rest) -> case rest of
          Tok KEnd _ _ : _ -> Right a
          [] -> Right a
          Tok _ at t : _ -> Left ("cannot read " <> Text.take 20 t <> " at " <> Text.pack (show at))

-- A braced group: its span with the braces, its tokens without.
group :: P (Span, [Tok])
group = do
  toks <- look
  case toks of
    Tok KOpen start _ : rest ->
      case breakOuter (\ts -> case ts of Tok KClose _ _ : _ -> True; _ -> False) rest of
        Nothing -> closingOf start rest
        Just (inner, _) -> do
          takeToks (take (length inner + 2) toks)
          end <- sofar
          pure (Span start end, inner)
    _ -> failP "expected {"
  where
    -- breakOuter refuses a close at depth 0, which is exactly the one wanted here
    closingOf start rest =
      case scan (0 :: Int) [] rest of
        Nothing -> failP ("the { at " <> Text.pack (show start) <> " is never closed")
        Just inner -> do
          toks <- look
          takeToks (take (length inner + 2) toks)
          end <- sofar
          pure (Span start end, inner)
    scan depth seen toks =
      case toks of
        [] -> Nothing
        Tok KEnd _ _ : _ -> Nothing
        t@(Tok KOpen _ _) : more -> scan (depth + 1) (t : seen) more
        t@(Tok KClose _ _) : more
          | depth == 0 -> Just (reverse seen)
          | otherwise -> scan (depth - 1) (t : seen) more
        t : more -> scan depth (t : seen) more

braced :: P Braced
braced = (\(s, inner) -> Braced s (textOf inner)) <$> group

-- What stands between an opening character (the next token) and the first
-- closing one outside braces: the span with both, the tokens between.
delimited :: Char -> Char -> P (Span, [Tok])
delimited open close = do
  start <- here
  char open
  toks <- look
  case breakOuter (isChar close) toks of
    Nothing -> failP ("the " <> Text.singleton open <> " at " <> Text.pack (show start) <> " is never closed")
    Just (inner, _) -> do
      takeToks inner
      char close
      end <- sofar
      pure (Span start end, inner)

-- Options -------------------------------------------------------------------

-- | Read an option list from what stands between its brackets; the offset is
-- where that text starts in the source.
parseOptions :: Int -> Text -> Options
parseOptions offset text = optionsOf (Span offset (offset + Text.length text)) (init (tokens offset text))

optionsOf :: Span -> [Tok] -> Options
optionsOf whole toks = Options whole (concatMap entry (splitOuter (\(Tok kind _ t) -> kind == KChar && t == ",") toks))
  where
    entry piece =
      case trimToks piece of
        [] -> []
        trimmed@(Tok _ start _ : _) ->
          let (keyToks, afterKey) = case breakOuter (isChar '=') (trimmed <> [Tok KEnd 0 ""]) of
                Just (before, _ : after) -> (before, Just (takeWhile (\(Tok kind _ _) -> kind /= KEnd) after))
                _ -> (trimmed, Nothing)
              written = Text.unwords (Text.words (textOf (filter (\(Tok kind _ _) -> kind /= KComment) keyToks)))
              (key, handler) = case Text.breakOnEnd "/." written of
                (before, after) | not (Text.null before) -> (Text.dropEnd 2 before, Just after)
                _ -> (written, Nothing)
              value = fmap valueOf afterKey
           in [Option (Span start (tokEnd (lastOr (Tok KEnd start "") trimmed))) key handler value]
    valueOf after =
      case trimToks after of
        [] -> Value (Span (snd' whole) (snd' whole)) ""
        trimmed@(first@(Tok kind start _) : rest) ->
          let end = tokEnd (lastOr first trimmed)
              -- one pair of outer braces is taken off, as pgfkeys does
              inner
                | kind == KOpen, wholeGroup rest = textOf (init rest)
                | otherwise = textOf trimmed
           in Value (Span start end) inner
    snd' (Span _ b) = b
    -- whether these tokens, after an opening brace, end with the brace that closes it
    wholeGroup rest = go (0 :: Int) rest
      where
        go depth toks' =
          case toks' of
            [Tok KClose _ _] -> depth == 0
            Tok KOpen _ _ : more -> go (depth + 1) more
            Tok KClose _ _ : more -> depth > 0 && go (depth - 1) more
            _ : more -> go depth more
            [] -> False

bracketOptions :: P Options
bracketOptions = do
  (Span start end, inner) <- delimited '[' ']'
  pure (optionsOf (Span (start + 1) (end - 1)) inner)

maybeOptions :: P (Maybe Options)
maybeOptions = do
  ws
  toks <- look
  if isChar '[' toks then Just <$> bracketOptions else pure Nothing

-- Coordinates ---------------------------------------------------------------

-- | Read one coordinate, with its signs and parentheses, from a text that
-- starts at the given offset.
parseCoordinate :: Int -> Text -> Either Text Coordinate
parseCoordinate offset text = within (init (tokens offset text)) (offset + Text.length text) coordinate

coordinate :: P Coordinate
coordinate = do
  ws
  start <- here
  toks <- look
  relative <- case toks of
    Tok KChar _ "+" : Tok KChar _ "+" : _ -> RelativeMove <$ (next >> next)
    Tok KChar _ "+" : _ -> RelativeStay <$ next
    _ -> pure Absolute
  ws
  after <- look
  case after of
    Tok KCs _ name : _ -> do
      _ <- next
      end <- sofar
      pure (Coordinate (Span start end) relative Nothing (CoordMacro (Text.drop 1 name)) name)
    Tok KChar _ "(" : inside -> do
      let afterSpace = dropWhile isBlank inside
      if isChar '$' afterSpace then calc start relative else plain start relative
    Tok _ _ found : _ -> failP ("a coordinate is expected at " <> Text.pack (show start) <> ", not " <> Text.take 20 found)
    [] -> failP ("a coordinate is expected at " <> Text.pack (show start))
  where
    calc start relative = do
      char '('
      ws
      char '$'
      toks <- look
      -- up to the dollar that is followed by the closing parenthesis
      case breakOuter (\ts -> case ts of Tok KChar _ "$" : more -> isChar ')' (dropWhile isBlank more); _ -> False) toks of
        Nothing -> failP ("the ($ at " <> Text.pack (show start) <> " is never closed by $)")
        Just (inner, _) -> do
          takeToks inner
          char '$'
          ws
          char ')'
          end <- sofar
          pure (Coordinate (Span start end) relative Nothing (CoordCalc (textOf inner)) ("$" <> textOf inner <> "$"))
    plain start relative = do
      char '('
      options <- maybeOptions
      toks <- look
      case breakOuter (isChar ')') toks of
        Nothing -> failP ("the ( at " <> Text.pack (show start) <> " is never closed")
        Just (inner, _) -> do
          takeToks inner
          char ')'
          end <- sofar
          body <- either failP pure (coordBodyOf inner)
          pure (Coordinate (Span start end) relative options body (textOf inner))

-- The tests of TikZ's scanner, in its order: a coordinate system, an
-- intersection, a perpendicular, polar, comma separated, else a node.
coordBodyOf :: [Tok] -> Either Text CoordBody
coordBodyOf toks
  | Just (before, _ : _ : after) <- breakOuter (\ts -> case ts of Tok KWord _ "cs" : Tok KChar _ ":" : _ -> True; _ -> False) closed =
      Right (CoordSystem (clean before) (optionsOf (spanOf 0 (stripEnd after)) (stripEnd after)))
  | isWord "intersection" trimmed = Right (CoordIntersection (clean toks))
  | Just (before, _ : _ : after) <- breakOuter (\ts -> case ts of Tok KChar _ "-" : Tok KChar _ "|" : _ -> True; _ -> False) closed =
      CoordHV <$> simple before <*> simple (stripEnd after)
  | Just (before, _ : _ : after) <- breakOuter (\ts -> case ts of Tok KChar _ "|" : Tok KChar _ "-" : _ -> True; _ -> False) closed =
      CoordVH <$> simple before <*> simple (stripEnd after)
  | otherwise = simple toks
  where
    trimmed = trimToks toks
    closed = toks <> [Tok KEnd 0 ""]
    stripEnd = takeWhile (\(Tok kind _ _) -> kind /= KEnd)
    clean = Text.strip . textOf
    simple part
      | Just (before, _ : after) <- breakOuter (isChar ':') (part <> [Tok KEnd 0 ""]) =
          let radius = stripEnd after
           in case breakOuter (isWord "and") (radius <> [Tok KEnd 0 ""]) of
                Just (x, _ : y) -> Right (CoordPolar (clean before) (clean x) (Just (clean (stripEnd y))))
                _ -> Right (CoordPolar (clean before) (clean radius) Nothing)
      | otherwise =
          case splitOuter (\(Tok kind _ t) -> kind == KChar && t == ",") part of
            [x, y] -> Right (CoordXY (clean x) (clean y))
            [x, y, z] -> Right (CoordXYZ (clean x) (clean y) (clean z))
            -- an empty name is the node an edge starts from: (a) edge[loop] ()
            [single]
              | name <- clean single ->
                  let (node, anchor) = Text.breakOn "." name
                   in if Text.null anchor || Text.null node then Right (CoordNode name Nothing) else Right (CoordNode node (Just (Text.strip (Text.drop 1 anchor))))
            _ -> Left ("cannot read the coordinate (" <> clean part <> ")")

-- Paths ---------------------------------------------------------------------

target :: P Target
target = do
  ws
  toks <- look
  case toks of
    Tok KWord start "cycle" : _ -> next >> pure (TargetCycle (Span start (start + 5)))
    _ -> TargetAt <$> coordinate

-- The nodes, coordinates and pics written between an operation and its target.
labels :: P [PathOp]
labels = do
  ws
  toks <- look
  case toks of
    Tok KWord _ w : _ | w `elem` ["node", "coordinate", "pic"] -> do
      one <- nodeOp
      (one :) <$> labels
    _ -> pure []

foreachHead :: P Foreach
foreachHead = do
  ws
  start <- here
  toks <- look
  _ <- case toks of
    Tok KCs _ "\\foreach" : _ -> next
    Tok KWord _ "foreach" : _ -> next
    _ -> failP "expected foreach"
  rest <- look
  case breakOuter (\ts -> isWord "in" ts || isChar '[' ts) rest of
    Nothing -> failP ("the foreach at " <> Text.pack (show start) <> " has no in")
    Just (variables, _) -> do
      takeToks variables
      options <- maybeOptions
      ws
      word "in"
      ws
      listToks <- look
      list <- case listToks of
        Tok KOpen _ _ : _ -> braced
        Tok KCs at name : _ -> next >> pure (Braced (Span at (at + Text.length name)) name)
        _ -> failP ("the foreach at " <> Text.pack (show start) <> " needs a list in braces")
      end <- sofar
      pure (Foreach (Span start end) (Text.strip (textOf variables)) options list)

-- node, coordinate or pic, from its keyword on.
nodeOp :: P PathOp
nodeOp = do
  ws
  start <- here
  Tok _ _ keyword <- next
  kind <- case keyword of
    "node" -> pure KindNode
    "coordinate" -> pure KindCoordinate
    "pic" -> pure KindPic
    _ -> failP "expected node"
  ws
  toks <- look
  if kind == KindNode && isWord "also" toks
    then do
      _ <- next
      options <- maybeOptions
      ws
      (_, name) <- delimited '(' ')'
      end <- sofar
      pure (OpNodeAlso (Span start end) options (Text.strip (textOf name)))
    else do
      loops <- foreachHeads
      (parts, text) <- nodeParts' kind False
      end <- sofar
      let node = Node (Span start end) kind loops parts text
          supplied = any (\o -> optionKey o `elem` ["node contents", "pic type"]) (nodeOptions node)
      if kind /= KindCoordinate && text == Nothing && not supplied
        then failP ("the " <> keyword <> " at " <> Text.pack (show start) <> " has no text in braces")
        else pure (OpNode node)

foreachHeads :: P [Foreach]
foreachHeads = do
  ws
  toks <- look
  if isWord "foreach" toks
    then (:) <$> foreachHead <*> foreachHeads
    else pure []

-- A coordinate is @coordinate[options](name) at (point)@: once it has its
-- name, a parenthesis is the next point of the path, not another name.
nodeParts' :: NodeKind -> Bool -> P ([NodePart], Maybe Braced)
nodeParts' kind named = do
  ws
  toks <- look
  case toks of
    Tok KWord _ "at" : _ -> do
      (s, at) <- spanned (next >> coordinate)
      more (PartAt s at)
    Tok KChar _ "(" : _ | not (kind == KindCoordinate && named) -> do
      (s, name) <- delimited '(' ')'
      (\(parts, text) -> (PartName s (Text.strip (textOf name)) : parts, text)) <$> nodeParts' kind True
    Tok KChar _ "[" : _ -> do
      options <- bracketOptions
      more (PartOptions options)
    Tok KChar _ ":" : _ -> do
      (s, _) <- spanned animation
      more (PartAnimation s)
    Tok KOpen _ _ : _ | kind /= KindCoordinate -> do
      text <- braced
      pure ([], Just text)
    _ -> pure ([], Nothing)
  where
    more part = (\(parts, text) -> (part : parts, text)) <$> nodeParts' kind named

-- @:attribute = {..}@
animation :: P ()
animation = do
  char ':'
  toks <- look
  case breakOuter (isChar '=') toks of
    Nothing -> failP "an animation attribute needs ="
    Just (name, _) -> takeToks name >> char '=' >> ws >> () <$ group

-- Path operations up to the end of what there is to read (or a closing brace).
pathOps' :: P [PathOp]
pathOps' = do
  ws
  toks <- look
  case toks of
    [] -> pure []
    Tok KEnd _ _ : _ -> pure []
    Tok KClose _ _ : _ -> pure []
    Tok KCs _ "\\par" : _ -> next >> pathOps'
    _ -> (:) <$> pathOp <*> pathOps'

groupOps :: P [PathOp]
groupOps = do
  (Span _ end, inner) <- group
  either failP pure (within inner (end - 1) pathOps')

pathOp :: P PathOp
pathOp = do
  ws
  start <- here
  toks <- look
  let done make = (\end -> make (Span start end)) <$> sofar
      keyword = next
  case toks of
    Tok KChar _ "(" : _ -> coordinate >>= \c -> done (\s -> OpMove s c)
    Tok KChar _ "+" : _ -> coordinate >>= \c -> done (\s -> OpMove s c)
    Tok KChar _ "-" : Tok KChar _ "-" : _ -> do
      _ <- next >> next
      ws
      after <- look
      if isWord "plot" after
        then keyword >> plot start True
        else do
          found <- labels
          to <- target
          done (\s -> OpLine s JoinLine found to)
    Tok KChar _ "-" : Tok KChar _ "|" : _ -> do
      _ <- next >> next
      found <- labels
      to <- target
      done (\s -> OpLine s JoinHV found to)
    Tok KChar _ "|" : Tok KChar _ "-" : _ -> do
      _ <- next >> next
      found <- labels
      to <- target
      done (\s -> OpLine s JoinVH found to)
    Tok KChar _ "." : Tok KChar _ "." : _ -> do
      _ <- next >> next
      early <- labels
      ws
      word "controls"
      first <- coordinate
      ws
      afterFirst <- look
      second <- if isWord "and" afterFirst then Just <$> (next >> coordinate) else pure Nothing
      ws
      char '.'
      char '.'
      found <- labels
      to <- target
      done (\s -> OpCurve s first second (early <> found) to)
    Tok KChar _ "[" : _ -> bracketOptions >>= \o -> done (\s -> OpOptions s o)
    Tok KChar _ ":" : _ -> animation >> done OpAnimation
    Tok KOpen _ _ : _ -> groupOps >>= \ops -> done (\s -> OpScope s ops)
    Tok KCs _ "\\foreach" : _ -> foreachOp start
    Tok KCs _ "\\pgfextra" : _ -> do
      _ <- next
      ws
      after <- look
      case after of
        Tok KOpen _ _ : _ -> group >> done OpExtra
        _ -> case breakOuter (\ts -> case ts of Tok KCs _ "\\endpgfextra" : _ -> True; _ -> False) after of
          Nothing -> failP "\\pgfextra without \\endpgfextra"
          Just (code, _) -> takeToks code >> next >> done OpExtra
    Tok KCs _ name : _ -> next >> done (\s -> OpMacro s (Text.drop 1 name))
    Tok KWord _ w : _ ->
      case w of
        "node" -> nodeOp
        "coordinate" -> nodeOp
        "pic" -> nodeOp
        "rectangle" -> do
          _ <- keyword
          found <- labels
          to <- target
          done (\s -> OpRectangle s found to)
        "circle" -> keyword >> roundArgs >>= \r -> done (\s -> OpCircle s r)
        "ellipse" -> keyword >> roundArgs >>= \r -> done (\s -> OpEllipse s r)
        "arc" -> do
          _ <- keyword
          ws
          after <- look
          arc <- case after of
            Tok KChar _ "(" : _ -> do
              (_, inner) <- delimited '(' ')'
              case splitOuter (\(Tok kind _ t) -> kind == KChar && t == ":") inner of
                [a, b, r] -> pure (ArcOld (Text.strip (textOf a)) (Text.strip (textOf b)) (Text.strip (textOf r)))
                _ -> failP "an arc is written (start:end:radius)"
            Tok KChar _ "[" : _ -> ArcKeys <$> bracketOptions
            _ -> (\at -> ArcKeys (Options (Span at at) [])) <$> sofar
          done (\s -> OpArc s arc)
        "grid" -> do
          _ <- keyword
          options <- maybeOptions
          to <- target
          done (\s -> OpGrid s options to)
        "parabola" -> do
          _ <- keyword
          options <- maybeOptions
          ws
          after <- look
          bend <- if isWord "bend" after then Just <$> (next >> coordinate) else pure Nothing
          to <- target
          done (\s -> OpParabola s options bend to)
        "sin" -> keyword >> target >>= \to -> done (\s -> OpSin s to)
        "cos" -> keyword >> target >>= \to -> done (\s -> OpCos s to)
        "plot" -> keyword >> plot start False
        "to" -> do
          _ <- keyword
          (options, found, to) <- toArgs
          done (\s -> OpTo s options found to)
        "edge" -> do
          _ <- keyword
          ws
          after <- look
          if isWord "from" after
            then do
              _ <- next
              ws
              word "parent"
              options <- maybeOptions
              found <- labels
              done (\s -> OpEdgeFromParent s options found)
            else do
              (options, found, to) <- toArgs
              done (\s -> OpEdge s options found to)
        "foreach" -> foreachOp start
        "let" -> do
          _ <- keyword
          after <- look
          case breakOuter (isWord "in") after of
            Nothing -> failP "let without in"
            Just (assignments, _) -> takeToks assignments >> next >> done (\s -> OpLet s (Text.strip (textOf assignments)))
        "child" -> do
          _ <- keyword
          first <- maybeOptions
          loops <- foreachHeads
          second <- maybeOptions
          ws
          after <- look
          body <- case after of
            Tok KOpen _ _ : _ -> Just <$> groupOps
            _ -> pure Nothing
          done (\s -> OpChild s (maybe [] pure first <> maybe [] pure second) loops body)
        "decorate" -> do
          _ <- keyword
          options <- maybeOptions
          ws
          ops <- groupOps
          done (\s -> OpDecorate s options ops)
        "svg" -> do
          _ <- keyword
          options <- maybeOptions
          ws
          body <- braced
          done (\s -> OpSvg s options body)
        "graph" -> do
          _ <- keyword
          options <- maybeOptions
          ws
          body <- braced
          done (\s -> OpGraph s options body)
        "lindenmayer" -> do
          _ <- keyword
          ws
          word "system"
          options <- maybeOptions
          done (\s -> OpLSystem s options)
        "l" | Tok KChar _ "-" : Tok KWord _ "system" : _ <- drop 1 toks -> do
          _ <- next >> next >> next
          options <- maybeOptions
          done (\s -> OpLSystem s options)
        _ -> failP ("cannot read " <> w <> " at " <> Text.pack (show start) <> " as part of a path")
    Tok _ _ t : _ -> failP ("cannot read " <> t <> " at " <> Text.pack (show start) <> " as part of a path")
    [] -> failP "the path ends before it is complete"
  where
    roundArgs = do
      ws
      after <- look
      case after of
        Tok KChar _ "(" : _ -> (\(_, inner) -> RoundOld (Text.strip (textOf inner))) <$> delimited '(' ')'
        Tok KChar _ "[" : _ -> RoundKeys . Just <$> bracketOptions
        _ -> pure (RoundKeys Nothing)
    toArgs = do
      options <- toOptions
      found <- labels
      to <- target
      pure (options, found, to)
    toOptions = do
      ws
      after <- look
      case after of
        Tok KChar _ "[" : _ -> (:) <$> bracketOptions <*> toOptions
        Tok KChar _ ":" : _ -> animation >> toOptions
        _ -> pure []
    foreachOp start = do
      loop <- foreachHead
      ws
      ops <- groupOps
      end <- sofar
      pure (OpForeach (Span start end) loop ops)
    plot start lineTo = do
      options <- maybeOptions
      ws
      after <- look
      found <- case after of
        Tok KWord _ "coordinates" : _ -> do
          _ <- next
          ws
          (Span _ end, inner) <- group
          PlotCoordinates <$> either failP pure (within inner (end - 1) coordinates)
        Tok KWord _ "file" : _ -> next >> ws >> PlotFile <$> braced
        Tok KWord _ "function" : _ -> next >> ws >> PlotFunction <$> braced
        Tok KChar _ "(" : _ -> PlotExpression <$> coordinate
        _ -> failP "plot needs coordinates, a file, a function or an expression"
      end <- sofar
      pure (OpPlot (Span start end) lineTo options found)
    coordinates = do
      ws
      done' <- atEnd
      if done' then pure [] else (:) <$> coordinate <*> coordinates

-- Statements ----------------------------------------------------------------

-- | The commands that start a path statement.
pathCommandNames :: [Text]
pathCommandNames = ["path", "draw", "fill", "filldraw", "pattern", "shade", "shadedraw", "clip", "useasboundingbox", "node", "coordinate", "matrix", "pic", "graph"]

-- Commands that are not paths but, like them, run up to a semicolon.
semicolonCommands :: [Text]
semicolonCommands = ["datavisualization", "calendar", "spy", "chainin"]

-- Beamer's commands that show their argument on some slides only.
overlayCommands :: [Text]
overlayCommands = ["only", "uncover", "visible", "invisible", "onslide"]

-- | Read the body of a picture: the text between @\\begin{tikzpicture}@ and
-- its end, or a picture block or file of statements. The offset is where
-- the text starts in the source the spans count in.
parsePicture :: Int -> Text -> Picture
parsePicture offset text =
  let toks = tokens offset text
      end = offset + Text.length text
   in Picture (Span offset end) (items end toks)

-- Statements up to the end mark. Every token is accounted for by an item
-- or is blank space between items.
items :: Int -> [Tok] -> [Item]
items end toks =
  case dropWhile (\(Tok kind _ _) -> kind == KSpace) toks of
    [] -> []
    Tok KEnd _ _ : _ -> []
    Tok KComment start t : rest -> ItemComment (Span start (start + Text.length t)) : items end rest
    found@(Tok KCs start name : rest) ->
      let (item, after) = statement end start (Text.drop 1 name) found rest in item : items end after
    found@(Tok KOpen start _ : _) ->
      case runP group (S start found) of
        Right ((whole@(Span _ close), inner), S _ after) ->
          -- { [options] statements } is a scope (the scopes library)
          let (options, body) = case runP maybeOptions (S start inner) of
                Right (Just found', S _ remaining) -> (Just found', remaining)
                _ -> (Nothing, inner)
           in ItemScope whole options (Picture (spanOf (close - 1) body) (items (close - 1) (body <> [Tok KEnd (close - 1) ""]))) : items end after
        Left message -> [ItemUnread (Span start end) message]
    Tok _ start _ : _ ->
      -- text that is no statement: up to the next command or group
      let (stray, after) = break (\(Tok kind _ _) -> kind `elem` [KCs, KOpen, KEnd, KComment]) (dropWhile (\(Tok kind _ _) -> kind == KSpace) toks)
          Span _ strayEnd = spanOf start (trimToks stray)
       in ItemUnread (Span start strayEnd) "this is not a statement" : items end after

-- One statement that starts with a command: the item and what follows it.
statement :: Int -> Int -> Text -> [Tok] -> [Tok] -> (Item, [Tok])
statement end start name found rest
  | name `elem` pathCommandNames =
      case breakOuter (isChar ';') rest of
        Nothing -> (ItemUnread (Span start (lineEnd rest)) ("no semicolon ends this \\" <> name), afterLine rest)
        Just (body, semicolon : after) ->
          let close = tokEnd semicolon
              whole = Span start close
           in (either (ItemUnread whole) ItemPath (within body (close - 1) (pathStatement whole name)), after)
        Just (_, []) -> (ItemUnread (Span start end) "no semicolon ends this path", [])
  | name `elem` semicolonCommands =
      -- commands of libraries with a syntax of their own, which a semicolon ends: kept whole
      case breakOuter (isChar ';') rest of
        Just (body, semicolon : after) -> (ItemCommand (Span start (tokEnd semicolon)) name [Braced (spanOf start body) (textOf body)], after)
        _ -> (ItemUnread (Span start (lineEnd rest)) ("no semicolon ends this \\" <> name), afterLine rest)
  | name `elem` overlayCommands
  , Right (item, S _ after) <- runP overlay (S start found) = (item, after)
  | name == "begin" = environment
  | name == "scoped" = run $ do
      _ <- next
      options <- scopeOptions
      ws
      after <- look
      case after of
        Tok KOpen _ _ : _ -> do
          (Span _ close, inner) <- group
          finish (\s -> ItemScope s options (Picture (spanOf close inner) (items (close - 1) (inner <> [Tok KEnd (close - 1) ""]))))
        Tok KCs at inner : more ->
          let (item, remaining) = statement end at (Text.drop 1 inner) after more
              Span _ itemEnd = itemSpan item
           in P (\_ -> Right (ItemScope (Span start itemEnd) options (Picture (itemSpan item) [item]), S itemEnd remaining))
        _ -> failP "\\scoped needs a statement or a group"
  | name == "foreach" = run $ do
      loop <- foreachHead
      ws
      after <- look
      case after of
        Tok KOpen _ _ : _ -> do
          (Span _ close, inner) <- group
          finish (\s -> ItemForeach s loop (Picture (spanOf close inner) (items (close - 1) (inner <> [Tok KEnd (close - 1) ""]))))
        Tok KCs at inner : more ->
          let (item, remaining) = statement end at (Text.drop 1 inner) after more
              Span _ itemEnd = itemSpan item
           in P (\_ -> Right (ItemForeach (Span start itemEnd) loop (Picture (itemSpan item) [item]), S itemEnd remaining))
        _ -> failP "\\foreach needs a body"
  | name == "tikzset" = run $ do
      _ <- next
      ws
      (Span open close, inner) <- group
      finish (\s -> ItemSet s (optionsOf (Span (open + 1) (close - 1)) inner))
  | name == "tikzstyle" = run $ do
      _ <- next
      ws
      Braced _ styleName <- braced
      ws
      after <- look
      appends <- if isChar '+' after then True <$ next else pure False
      char '='
      ws
      options <- bracketOptions
      finish (\s -> ItemStyle s (Text.strip styleName) appends options)
  | name `elem` ["def", "edef", "gdef", "xdef"] = run $ do
      _ <- next
      ws
      Tok _ at macro <- next
      after <- look
      -- the parameter text runs up to the body
      case break (\(Tok kind _ _) -> kind == KOpen || kind == KEnd) after of
        (parameters, Tok KOpen _ _ : _) -> do
          takeToks parameters
          body <- braced
          finish (\s -> ItemCommand s name [Braced (Span at (at + Text.length macro)) macro, Braced (spanOf at parameters) (textOf parameters), body])
        _ -> failP ("\\" <> name <> " without a body")
  | otherwise = run $ do
      _ <- next
      arguments <- commandArguments
      -- a semicolon straight after belongs to the command (\cat{file};)
      after <- look
      case dropWhile isBlank after of
        Tok KChar _ ";" : _ | not (null arguments) -> ws >> char ';'
        _ -> pure ()
      finish (\s -> ItemCommand s name arguments)
  where
    overlay = do
      _ <- next
      ws
      (specSpan, spec) <- delimited '<' '>'
      ws
      (Span _ close, inner) <- group
      finish (\s -> ItemOverlay s name (Braced specSpan (textOf spec)) (Picture (spanOf (close - 1) inner) (items (close - 1) (inner <> [Tok KEnd (close - 1) ""]))))
    -- animations may stand before the options of a scope: :rotate = {..}
    scopeOptions = do
      ws
      toks <- look
      if isChar ':' toks then animation >> scopeOptions else maybeOptions
    run parser =
      case runP parser (S start found) of
        Right (item, S _ after) -> (item, after)
        Left message -> (ItemUnread (Span start (lineEnd rest)) message, afterLine rest)
    finish make = (\close -> make (Span start close)) <$> sofar
    -- when a statement cannot be read, the rest of its line goes with it
    lineEnd toks = case break newline toks of
      (line, _) -> let Span _ e = spanOf start (found' line) in e
    found' line = take 1 found <> line
    afterLine = dropWhile (not . newline)
    newline (Tok kind _ t) = kind == KEnd || (kind == KSpace && Text.any (== '\n') t)
    environment = run $ do
      _ <- next
      ws
      Braced _ environmentName <- braced
      case Text.strip environmentName of
        "scope" -> do
          options <- scopeOptions
          (bodySpan, inner) <- upToEnd "scope"
          finish (\s -> ItemScope s options (Picture bodySpan inner))
        "pgfonlayer" -> do
          ws
          Braced _ layer <- braced
          (bodySpan, inner) <- upToEnd "pgfonlayer"
          finish (\s -> ItemLayer s (Text.strip layer) (Picture bodySpan inner))
        other -> do
          -- an environment of some package: kept whole, as written
          bodyStart <- sofar
          toks <- look
          case endOf other toks of
            Nothing -> failP ("\\begin{" <> other <> "} is never ended")
            Just (body, closing) -> do
              takeToks (body <> closing)
              finish (\s -> ItemCommand s ("begin{" <> other <> "}") [Braced (spanOf bodyStart body) (textOf body)])
    upToEnd environmentName = do
      bodyStart <- sofar
      toks <- look
      case endOf environmentName toks of
        Nothing -> failP ("\\begin{" <> environmentName <> "} is never ended")
        Just (body, closing) -> do
          takeToks (body <> closing)
          let Span _ bodyEnd = spanOf bodyStart body
              bodySpan = Span bodyStart (max bodyStart bodyEnd)
          pure (bodySpan, items bodyEnd (body <> [Tok KEnd bodyEnd ""]))
    -- the tokens up to the matching \end{name}, and the tokens of that \end{name}
    endOf environmentName = go (0 :: Int) []
      where
        go depth seen toks =
          case toks of
            [] -> Nothing
            Tok KEnd _ _ : _ -> Nothing
            t@(Tok KCs _ command) : more
              | command `elem` ["\\begin", "\\end"]
              , (blank, Tok KOpen _ _ : afterOpen) <- span isBlank more
              , (inside, close@(Tok KClose _ _) : _) <- break (\(Tok kind _ _) -> kind == KClose || kind == KEnd) afterOpen
              , Text.strip (textOf inside) == environmentName ->
                  let whole = [t] <> blank <> take 1 (drop (length blank) more) <> inside <> [close]
                   in if command == "\\begin"
                        then go (depth + 1) (reverse whole <> seen) (drop (length whole - 1) more)
                        else
                          if depth == 0
                            then Just (reverse seen, whole)
                            else go (depth - 1) (reverse whole <> seen) (drop (length whole - 1) more)
            t : more -> go depth (t : seen) more

-- The arguments that follow a command without a blank line between: groups,
-- bracketed options, a star, a single control sequence after \let-like commands.
commandArguments :: P [Braced]
commandArguments = do
  toks <- look
  let (blank, after) = span isBlank toks
      paragraph = any (\(Tok kind _ t) -> kind == KSpace && Text.count "\n" t > 1) blank
  if paragraph
    then pure []
    else case after of
      Tok KOpen _ _ : _ -> ws >> ((:) <$> braced <*> commandArguments)
      Tok KChar _ "[" : _ | null blank -> do
        (s, inner) <- delimited '[' ']'
        (Braced s (textOf inner) :) <$> commandArguments
      Tok KChar at "*" : _ | null blank -> next >> ((Braced (Span at (at + 1)) "*" :) <$> commandArguments)
      Tok KChar at "=" : _ | null blank -> next >> ((Braced (Span at (at + 1)) "=" :) <$> commandArguments)
      _ -> pure []

-- A path statement, from its command to before its semicolon.
pathStatement :: Span -> Text -> P PathCommand
pathStatement whole name = do
  toks <- look
  overlay <- case toks of
    Tok KChar _ "<" : _ -> do
      (s, inner) <- delimited '<' '>'
      pure (Just (Braced s (textOf inner)))
    _ -> pure Nothing
  -- \node, \coordinate, \pic and \matrix are a path that starts with that operation
  first <- case name of
    "node" -> pure <$> fromKeyword "node"
    "matrix" -> pure <$> fromKeyword "node"
    "coordinate" -> pure <$> fromKeyword "coordinate"
    "pic" -> pure <$> fromKeyword "pic"
    "graph" -> pure <$> fromKeyword "graph"
    _ -> pure []
  rest <- pathOps'
  pure (PathCommand whole name overlay (first <> rest))
  where
    -- read as if the keyword stood here
    fromKeyword keyword = P (\(S end toks) ->
      let at = case toks of Tok _ start _ : _ -> start; [] -> end
          parser = if keyword == "graph" then pathOp else nodeOp
       in runP parser (S end (Tok KWord at keyword : toks)))

-- Documents -----------------------------------------------------------------

-- | Find the pictures of a TeX source: @tikzpicture@ environments and
-- @\\tikz@ commands. Everything else is kept as text between them.
parseDocument :: Text -> Document
parseDocument text = Document (merge (chunks (tokens 0 text)))
  where
    end = Text.length text
    merge list =
      case list of
        ChunkText (Span a _) : ChunkText (Span _ b) : more -> merge (ChunkText (Span a b) : more)
        one : more -> one : merge more
        [] -> []
    chunks toks =
      case toks of
        [] -> []
        Tok KEnd _ _ : _ -> []
        Tok KCs start "\\begin" : more
          | (blank, Tok KOpen _ _ : afterOpen) <- span isBlank more
          , (inside, Tok KClose _ _ : afterName) <- break (\(Tok kind _ _) -> kind == KClose || kind == KEnd) afterOpen
          , Text.strip (textOf inside) == "tikzpicture"
          , null blank
          , Right ((options, body, bodySpan@(Span _ bodyEnd), close), S _ after) <- runP pictureBody (S start afterName) ->
              ChunkPicture (Span start close) options (Picture bodySpan (items bodyEnd (body <> [Tok KEnd bodyEnd ""]))) : chunks after
        Tok KCs start "\\tikz" : more
          | Right ((options, body, bodySpan@(Span _ bodyEnd), close), S _ after) <- runP inline (S start more) ->
              ChunkInline (Span start close) options (Picture bodySpan (items bodyEnd (body <> [Tok KEnd bodyEnd ""]))) : chunks after
        t@(Tok _ start _) : more -> ChunkText (Span start (tokEnd t)) : chunks more
    pictureBody = do
      options <- maybeOptions
      bodyStart <- sofar
      toks <- look
      case pictureEnd (0 :: Int) [] toks of
        Nothing -> failP "the picture is never ended"
        Just (body, closing) -> do
          takeToks (body <> closing)
          close <- sofar
          let Span _ bodyEnd = spanOf bodyStart body
          pure (options, body, Span bodyStart (max bodyStart bodyEnd), close)
    pictureEnd depth seen toks =
      case toks of
        [] -> Nothing
        Tok KEnd _ _ : _ -> Nothing
        t@(Tok KCs _ command) : more
          | command `elem` ["\\begin", "\\end"]
          , (blank, open@(Tok KOpen _ _) : afterOpen) <- span isBlank more
          , (inside, close@(Tok KClose _ _) : afterName) <- break (\(Tok kind _ _) -> kind == KClose || kind == KEnd) afterOpen
          , Text.strip (textOf inside) == "tikzpicture" ->
              let whole = [t] <> blank <> [open] <> inside <> [close]
               in if command == "\\begin"
                    then pictureEnd (depth + 1) (reverse whole <> seen) afterName
                    else if depth == 0 then Just (reverse seen, whole) else pictureEnd (depth - 1) (reverse whole <> seen) afterName
        t : more -> pictureEnd depth (t : seen) more
    inline = do
      options <- maybeOptions
      ws
      toks <- look
      case toks of
        Tok KOpen _ _ : _ -> do
          (Span open close, inner) <- group
          pure (options, inner, Span (open + 1) (close - 1), close)
        _ ->
          -- without braces the picture is everything up to the next semicolon
          case breakOuter (isChar ';') toks of
            Just (body, semicolon : _) -> do
              bodyStart <- here
              takeToks (body <> [semicolon])
              close <- sofar
              pure (options, body <> [semicolon], Span bodyStart close, close)
            _ -> failP "\\tikz needs a group or a statement"
    _unused = end
