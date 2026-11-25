{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Tikz.Edit
-- Description : Changing a TikZ picture through its text.
--
-- Every edit names a statement or a node by where it starts in the text (the
-- start of its span, as the evaluator reports it) and rewrites only the piece
-- of text that says the thing being changed: a coordinate, an option, the
-- text between a node's braces, a statement. Everything else stays as written.
--
-- A move is checked: the caller says where things end up for a given text,
-- and a rewritten coordinate is kept only when the thing then stands where it
-- was asked to. (A picture may scale or turn its coordinates, so the numbers
-- to write are found by trying.) A node whose place is not a pair of numbers
-- (it stands beside another node, or on a line) is moved by @xshift@ and
-- @yshift@ instead.
module SlideBlaster.Syntax.Tikz.Edit
  ( FigureOp (..)
  , editFigure
  , bodyPicture
  , placeIn
  ) where

import SlideBlaster.Syntax.Tikz.Ast
import SlideBlaster.Syntax.Tikz.Eval
import SlideBlaster.Syntax.Tikz.Math
import SlideBlaster.Syntax.Tikz.Parse

import Data.Char (isSpace)
import Data.List (sortOn)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead

data FigureOp
  = -- | Move the statement or node starting here: right and up, in centimetres.
    MoveItem !Int !Double !Double
  | -- | The new text between the braces of the node starting here.
    SetText !Int !Text
  | -- | Set an option of the statement or node starting here, or with no value given take it away.
    -- A value of @""@ writes the bare key.
    SetOption !Int !Text !(Maybe Text)
  | -- | Take the statement or node starting here out of the picture.
    DeleteItem !Int
  | -- | A new node standing at a place (centimetres, y up, as the evaluator counts): its options and its text.
    AddNode !Double !Double !Text !Text
  | -- | A new line from the node starting at the first place to the node starting at the second, with these options.
    -- A node without a name is given one.
    AddLine !Int !Int !Text
  | -- | Make the node starting here at least this wide and high (centimetres).
    Resize !Int !Double !Double
  | -- | How the first part of the line starting here goes: @straight@, @hv@ (across, then up or down),
    -- @vh@, @bend left@, @bend right@.
    SetRoute !Int !Text
  | -- | Several edits as one. They are carried out from the end of the text backwards, so each still finds its place.
    Batch ![FigureOp]
  deriving stock (Eq, Show)

-- | The picture of a figure's text: the one @tikzpicture@ in it, or the text
-- itself when it holds bare statements.
bodyPicture :: Text -> Maybe (Maybe Options, Picture)
bodyPicture body
  | "\\begin{tikzpicture}" `Text.isInfixOf` body || "\\tikz" `Text.isInfixOf` body =
      let Document chunks = parseDocument body
       in case [(options, picture) | ChunkPicture _ options picture <- chunks] <> [(options, picture) | ChunkInline _ options picture <- chunks] of
            [found] -> Just found
            _ -> Nothing
  | otherwise = Just (Nothing, parsePicture 0 body)

-- | Where the statement or node starting at a place stands, in a text, given
-- how its picture is evaluated: a node's centre, a path's first point.
placeIn :: (Maybe Options -> Picture -> Evaluated) -> Text -> Int -> Maybe (Double, Double)
placeIn evaluate body start = do
  (options, picture) <- bodyPicture body
  let drawn = evaluatedDrawn (evaluate options picture)
  listToMaybe
    ( [boxCentre (drawnBox d) | d@DrawnNode {} <- drawn, spanStart (nodeSpan (drawnNode d)) == start]
        <> [boxCentre (drawnBox d) | d@DrawnNode {} <- drawn, spanStart (drawnSpan d) == start]
        <> [point | d@DrawnPath {} <- drawn, spanStart (drawnSpan d) == start, MoveTo point : _ <- [drawnSegments d]]
    )

-- What an edit points at.
data Aim
  = AimStatement !PathCommand
  | -- | a node, and the statement it is in
    AimNode !PathCommand !Node

commands :: Picture -> [PathCommand]
commands (Picture _ found) = concatMap item found
  where
    item one = case one of
      -- the cells of a matrix hold statements of their own
      ItemPath command
        | pathCommand command == "matrix" ->
            command : concat [commands (parsePicture offset text) | OpNode node <- pathOps command, Just (Braced (Span a _) written) <- [nodeText node], row <- matrixCells (a + 1) written, (offset, text) <- row]
      ItemPath command -> [command]
      ItemScope _ _ inner -> commands inner
      ItemForeach _ _ inner -> commands inner
      ItemLayer _ _ inner -> commands inner
      ItemOverlay _ _ _ inner -> commands inner
      _ -> []

deepOps :: [PathOp] -> [PathOp]
deepOps = concatMap (\op -> op : deepOps (inside op))
  where
    inside op = case op of
      OpLine _ _ found _ -> found
      OpCurve _ _ _ found _ -> found
      OpRectangle _ found _ -> found
      OpTo _ _ found _ -> found
      OpEdge _ _ found _ -> found
      OpEdgeFromParent _ _ found -> found
      OpScope _ found -> found
      OpForeach _ _ found -> found
      OpChild _ _ _ (Just found) -> found
      OpDecorate _ _ found -> found
      _ -> []

nodesOf :: PathCommand -> [Node]
nodesOf command = [node | OpNode node <- deepOps (pathOps command)]

aim :: Picture -> Int -> Maybe Aim
aim picture start =
  listToMaybe
    ( [AimNode command node | command <- commands picture, node <- nodesOf command, spanStart (nodeSpan node) == start, not (wholeStatement command node)]
        <> [AimNode command node | command <- commands picture, spanStart (pathSpan command) == start, [OpNode node] <- [filter (not . isOptions) (pathOps command)]]
        <> [AimStatement command | command <- commands picture, spanStart (pathSpan command) == start]
        <> [AimNode command node | command <- commands picture, node <- nodesOf command, spanStart (nodeSpan node) == start]
    )
  where
    -- @\\node ..;@ is a statement that is one node: the node is the statement
    wholeStatement command node = spanStart (pathSpan command) == spanStart (nodeSpan node)
    isOptions op = case op of
      OpOptions {} -> True
      _ -> False

spanStart :: Span -> Int
spanStart (Span a _) = a

splice :: Span -> Text -> Text -> Text
splice (Span a b) new text = Text.take a text <> new <> Text.drop b text

-- Several replacements at once: done from the end, so the earlier spans still hold.
spliceAll :: [(Span, Text)] -> Text -> Text
spliceAll changes text = foldl (\t (at, new) -> splice at new t) text (sortOn (Down . spanStart . fst) changes)

slice :: Span -> Text -> Text
slice (Span a b) = Text.take (b - a) . Text.drop a

-- | Carry out an edit on a figure's text. The function says, for a text and
-- the start of a statement or node in it, where that thing stands
-- (centimetres, y up); it is asked only by moves.
editFigure :: (Text -> Int -> Maybe (Double, Double)) -> FigureOp -> Text -> Either Text Text
editFigure place op body =
  case op of
    Batch ops -> foldl (\text one -> text >>= editFigure place one) (Right body) (sortOn (Down . placeOf) ops)
    AddNode x y options text -> do
      let name = freshName body
          start = insertPlace body
          indent = Text.takeWhileEnd (\c -> c == ' ' || c == '\t') (Text.take start body)
          lead = if Text.null indent && start > 0 && Text.takeEnd 1 (Text.take start body) /= "\n" then "\n" else ""
          statement = "\\node" <> (if Text.null (Text.strip options) then "" else "[" <> options <> "]") <> " (" <> name <> ") at (0,0) {" <> text <> "};"
          -- the new statement takes the line; what stood there (the end of the picture) moves down
          added = Text.take start body <> lead <> statement <> "\n" <> indent <> Text.drop start body
          at = start + Text.length lead
      case place added at of
        Nothing -> Right added
        Just (px, py)
          | abs (x - px) < 0.005 && abs (y - py) < 0.005 -> Right added
          | otherwise -> editOne place (MoveItem at (x - px) (y - py)) added
    AddLine from to options -> do
      (_, picture) <- maybe (Left "this figure does not hold one picture") Right (bodyPicture body)
      let nodeAtStart start = case aim picture start of
            Just (AimNode _ node) -> Right node
            _ -> Left "a line goes between two nodes"
      first <- nodeAtStart from
      second <- nodeAtStart to
      let fresh = freshNames body
          named node candidate = maybe (candidate, [(namePlace node, "(" <> candidate <> ") ")]) (\name -> (name, [])) (nodeName node)
          (firstName, firstInsert) = named first (Text.concat (take 1 fresh))
          (secondName, secondInsert) = if from == to then (firstName, []) else named second (Text.concat (take 1 (drop (length firstInsert) fresh)))
          namePlace node = case ([at | PartAt at _ <- nodeParts node], nodeText node) of
            (Span a _ : _, _) -> Span (keywordStart a) (keywordStart a)
            ([], Just (Braced at _)) -> let a = outerStart at body in Span a a
            ([], Nothing) -> let Span _ b = nodeSpan node in Span b b
          -- an @at@ part's span may start at its coordinate: the word before it is where the name goes
          keywordStart a = let before = Text.stripEnd (Text.take a body) in if "at" `Text.isSuffixOf` before then Text.length before - 2 else a
          start = insertPlace body
          indent = Text.takeWhileEnd (\c -> c == ' ' || c == '\t') (Text.take start body)
          lead = if Text.null indent && start > 0 && Text.takeEnd 1 (Text.take start body) /= "\n" then "\n" else ""
          statement = "\\draw" <> (if Text.null (Text.strip options) then "" else "[" <> options <> "]") <> " (" <> firstName <> ") " <> (if from == to then "to[loop above] ()" else "-- (" <> secondName <> ")") <> ";"
      Right (spliceAll ((Span start start, lead <> statement <> "\n" <> indent) : firstInsert <> secondInsert) body)
    _ -> editOne place op body
  where
    placeOf one = case one of
      MoveItem at _ _ -> at
      SetText at _ -> at
      SetOption at _ _ -> at
      DeleteItem at -> at
      Resize at _ _ -> at
      SetRoute at _ -> at
      _ -> maxBound

-- Where a new statement goes: the start of the line that ends the picture, or the end of the text.
insertPlace :: Text -> Int
insertPlace body =
  case Text.breakOnEnd "\\end{tikzpicture}" body of
    (before, _) | not (Text.null before) ->
      let upTo = Text.length before - Text.length ("\\end{tikzpicture}" :: Text)
          indent = Text.takeWhileEnd (\c -> c == ' ' || c == '\t') (Text.take upTo body)
       in upTo - Text.length indent
    _ -> Text.length (Text.stripEnd body) + (if Text.null (Text.stripEnd body) then 0 else 0)

-- Names nobody uses yet: n1, n2, ..
freshNames :: Text -> [Text]
freshNames body = [name | k <- [1 :: Int ..], let name = "n" <> Text.pack (show k), not (("(" <> name <> ")") `Text.isInfixOf` body), not (("(" <> name <> ".") `Text.isInfixOf` body)]

freshName :: Text -> Text
freshName = Text.concat . take 1 . freshNames

editOne :: (Text -> Int -> Maybe (Double, Double)) -> FigureOp -> Text -> Either Text Text
editOne place op body = do
  (_, picture) <- maybe (Left "this figure does not hold one picture") Right (bodyPicture body)
  let find start = maybe (Left "that part of the figure is not there any more") Right (aim picture start)
  case op of
    SetText start new -> do
      found <- find start
      node <- case found of
        AimNode _ node -> Right node
        AimStatement command -> maybe (Left "this statement has no text") Right (listToMaybe (nodesOf command))
      case nodeText node of
        Just (Braced at _) -> Right (splice (inner at body) new body)
        Nothing -> Left "this node has no text"
    DeleteItem start -> do
      found <- find start
      Right $ case found of
        AimNode command node | spanStart (pathSpan command) /= spanStart (nodeSpan node), length (filter (not . isOptionsOp) (pathOps command)) > 1 -> removeWithSpace (nodeSpan node) body
        AimNode command _ -> removeLine (pathSpan command) body
        AimStatement command -> removeLine (pathSpan command) body
    SetOption start key value -> do
      found <- find start
      Right (setOptions (optionsPlace body found) [(key, value)] body)
    Resize start width height -> do
      found <- find start
      node <- case found of
        AimNode _ node -> Right node
        AimStatement _ -> Left "only a node has a size"
      let round' = or [key == "circle" | Option _ key _ _ <- nodeOptions node]
          changes
            | round' = [("minimum size", Just (decimal (max width height) <> "cm")), ("minimum width", Nothing), ("minimum height", Nothing)]
            | otherwise = [("minimum width", Just (decimal width <> "cm")), ("minimum height", Just (decimal height <> "cm"))]
      Right (setOptions (optionsPlace body found) changes body)
    SetRoute start route -> do
      found <- find start
      command <- case found of
        AimStatement command -> Right command
        AimNode _ _ -> Left "only a line has a route"
      join <- maybe (Left "no such route") Right (lookup route [("straight", "--"), ("hv", "-|"), ("vh", "|-"), ("bend left", "to[bend left]"), ("bend right", "to[bend right]")])
      let endText to = case to of
            TargetAt c -> slice (coordSpan c) body
            TargetCycle _ -> "cycle"
          written at labels to = splice at (Text.unwords (join : fmap (\label -> slice (opSpan label) body) labels <> [endText to])) body
      case [op' | op' <- pathOps command, isJoin op'] of
        OpLine at _ labels to : _ -> Right (written at labels to)
        OpTo at _ labels to : _ -> Right (written at labels to)
        _ -> Left "this line has no part to route"
    AddNode {} -> Left "not one edit"
    AddLine {} -> Left "not one edit"
    Batch _ -> Left "not one edit"
    MoveItem start dx dy -> do
      found <- find start
      before <- maybe (Left "cannot tell where this stands") Right (place body start)
      let wanted = (fst before + dx, snd before + dy)
          lands candidate = case place candidate start of
            Just (x, y) -> abs (x - fst wanted) < 0.02 && abs (y - snd wanted) < 0.02
            Nothing -> False
          -- the numbers to write for a move, found by trying: first as they are, then
          -- corrected by how far the first try really went
          tried rewrite =
            let first = rewrite (dx, dy)
             in case first of
                  Nothing -> Nothing
                  Just candidate
                    | lands candidate -> Just candidate
                    | otherwise -> do
                        (x, y) <- place candidate start
                        let (mx, my) = (x - fst before, y - snd before)
                            scaled d m = if abs d < 1e-9 then Just 0 else if abs m < 1e-6 then Nothing else Just (d * d / m)
                        sx <- scaled dx mx
                        sy <- scaled dy my
                        second <- rewrite (sx, sy)
                        if lands second then Just second else Nothing
          shifted = case found of
            AimNode _ _ -> Just (setOptions (optionsPlace body found) [("xshift", Just (shiftBy "xshift" dx)), ("yshift", Just (shiftBy "yshift" dy))] body)
            AimStatement _ -> Nothing
          current key = case optionsPlace body found of
            (Just (Options _ options), _) -> listToMaybe [value | Option _ k Nothing (Just (Value _ text)) <- options, k == key, Right value <- [evalMath (const Nothing) text]]
            _ -> Nothing
          shiftBy key d =
            let old = maybe 0 (\v -> mathNumber v / pointsPerCm) (current key)
             in decimal (old + d) <> "cm"
          byCoordinates = case found of
            AimNode command node
              | Just coordinate <- nodeAt node -> tried (\d -> movedCoordinates d [coordinate] body)
              | [OpNode _] <- [op | op <- pathOps command, not (isOptionsOp op)], Just (Braced at _) <- nodeText node, not (positioned node) ->
                  -- a node nobody placed stands at the origin: it is given a place
                  tried (\(x, y) -> Just (splice (Span (outerStart at body) (outerStart at body)) ("at (" <> decimal x <> "," <> decimal y <> ") ") body))
              | otherwise -> Nothing
            AimStatement command ->
              let own = concatMap coordinatesOf (deepOps (pathOps command)) <> mapMaybe nodeAt (nodesOf command)
               in if null (filter plain own) then Nothing else tried (\d -> movedCoordinates d own body)
      case (byCoordinates, shifted) of
        (Just done, _) -> Right done
        (Nothing, Just done) | lands done -> Right done
        (Nothing, _) -> case found of
          AimStatement _ -> Left "this line follows the things it joins: move those"
          AimNode _ _ -> Left "this node cannot be moved by hand"
  where
    positioned node = or [key `elem` ["above", "below", "left", "right", "above left", "above right", "below left", "below right", "fit"] | Option _ key _ _ <- nodeOptions node]

isJoin :: PathOp -> Bool
isJoin op = case op of
  OpLine {} -> True
  OpTo {} -> True
  _ -> False

isOptionsOp :: PathOp -> Bool
isOptionsOp op = case op of
  OpOptions {} -> True
  _ -> False

-- A coordinate written as two plain numbers, counted from the origin.
plain :: Coordinate -> Bool
plain coordinate =
  case (coordRelative coordinate, coordBody coordinate) of
    (Absolute, CoordXY x y) -> isNumber x && isNumber y
    _ -> False
  where
    isNumber text = case TextRead.signed TextRead.double (Text.strip text) of
      Right (_, rest) -> Text.null (Text.strip rest) || Text.strip rest == "cm"
      Left _ -> False

-- Every plain coordinate moved by a distance; nothing when none of them is plain.
movedCoordinates :: (Double, Double) -> [Coordinate] -> Text -> Maybe Text
movedCoordinates (dx, dy) coordinates body =
  case filter plain coordinates of
    [] -> Nothing
    found -> Just (spliceAll (mapMaybe change found) body)
  where
    change coordinate = case coordBody coordinate of
      CoordXY x y -> do
        (xValue, xUnit) <- numberOf x
        (yValue, yUnit) <- numberOf y
        let written = slice (coordSpan coordinate) body
            open = Text.takeWhile (/= '(') written
        Just (coordSpan coordinate, open <> "(" <> decimal (xValue + dx) <> xUnit <> "," <> decimal (yValue + dy) <> yUnit <> ")")
      _ -> Nothing
    numberOf text = case TextRead.signed TextRead.double (Text.strip text) of
      Right (value, rest) -> Just (value, Text.strip rest)
      Left _ -> Nothing

coordinatesOf :: PathOp -> [Coordinate]
coordinatesOf op =
  let at to = case to of
        TargetAt c -> [c]
        TargetCycle _ -> []
   in case op of
        OpMove _ c -> [c]
        OpLine _ _ _ to -> at to
        OpCurve _ a b _ to -> [a] <> maybe [] pure b <> at to
        OpRectangle _ _ to -> at to
        OpGrid _ _ to -> at to
        OpTo _ _ _ to -> at to
        OpEdge _ _ _ to -> at to
        _ -> []

decimal :: Double -> Text
decimal value =
  let rounded = fromIntegral (round (value * 100) :: Integer) / 100 :: Double
      shown = Text.pack (show (abs rounded))
      trimmed = if ".0" `Text.isSuffixOf` shown then Text.dropEnd 2 shown else shown
   in if rounded == 0 then "0" else (if rounded < 0 then "-" else "") <> trimmed

-- The text between the braces of a braced span, whether or not the span includes them.
inner :: Span -> Text -> Span
inner (Span a b) body
  | Text.take 1 (Text.drop a body) == "{" = Span (a + 1) (b - 1)
  | otherwise = Span a b

-- Where the opening brace of a braced span is.
outerStart :: Span -> Text -> Int
outerStart (Span a _) body
  | Text.take 1 (Text.drop a body) == "{" = a
  | otherwise = a - 1

-- The option list an edit of options goes to, and, when there is none yet, where one is put.
optionsPlace :: Text -> Aim -> (Maybe Options, Int)
optionsPlace body found =
  case found of
    AimNode command node ->
      case [options | PartOptions options <- nodeParts node] of
        options : _ -> (Just options, 0)
        [] -> case [options | OpOptions _ options <- take 1 (pathOps command), spanStart (pathSpan command) == spanStart (nodeSpan node)] of
          options : _ -> (Just options, 0)
          [] -> (Nothing, afterWord (spanStart (nodeSpan node)))
    AimStatement command ->
      case [options | OpOptions _ options <- take 1 (pathOps command)] of
        options : _ -> (Just options, 0)
        [] -> case [options | [OpNode node] <- [take 1 (pathOps command)], PartOptions options <- take 1 (nodeParts node)] of
          options : _ | pathCommand command `elem` ["node", "coordinate"] -> (Just options, 0)
          _ -> (Nothing, afterWord (spanStart (pathSpan command)))
  where
    -- just after the command or keyword that starts there: \draw, \node, node
    afterWord start =
      let rest = Text.drop start body
          slash = Text.length (Text.takeWhile (== '\\') rest)
       in start + slash + Text.length (Text.takeWhile (\c -> c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') (Text.drop slash rest))

-- Set and remove options: in the list that is there, or in a new one.
setOptions :: (Maybe Options, Int) -> [(Text, Maybe Text)] -> Text -> Text
setOptions (found, fresh) changes body =
  case found of
    Nothing ->
      let written = [render key value | (key, Just value) <- changes]
       in if null written then body else splice (Span fresh fresh) ("[" <> Text.intercalate ", " written <> "]") body
    Just (Options whole options) ->
      let bracketed = Text.take 1 (slice whole body) == "["
          Span start end = whole
          contents = if bracketed then Span (start + 1) (end - 1) else whole
          existing key = [option | option <- options, optionKey option == key, optionHandler option == Nothing]
          replaced = [(optionSpan option, render key value) | (key, Just value) <- changes, option <- take 1 (reverse (existing key))]
          removed = [(widen (optionSpan option), "") | (key, Nothing) <- changes, option <- existing key]
          added = [render key value | (key, Just value) <- changes, null (existing key)]
          Span _ contentsEnd = contents
          kept = Text.strip (slice contents (spliceAll removed body))
          tailText
            | null added = ""
            | Text.null (Text.strip (Text.filter (/= ',') kept)) = Text.intercalate ", " added
            | "," `Text.isSuffixOf` kept = " " <> Text.intercalate ", " added
            | otherwise = ", " <> Text.intercalate ", " added
          -- the new options go where the list ends, after what is written there (less its trailing space)
          insertAt = contentsEnd - Text.length (Text.takeWhileEnd isSpace (slice contents body))
          edited = spliceAll (replaced <> removed <> [(Span insertAt insertAt, tailText) | not (Text.null tailText)]) body
          -- a list left empty goes away, brackets and all
          emptied = (bracketed || outside /= whole) && null added && null replaced && all (\option -> optionHandler option == Nothing && (optionKey option, Nothing) `elem` changes) options
          -- the brackets around a list whose span is only what stands between them
          outside = if not bracketed && Text.take 1 (Text.drop end body) == "]" && Text.takeEnd 1 (Text.take start body) == "[" then Span (start - 1) (end + 1) else whole
       in if emptied then splice outside "" body else edited
  where
    render key value = if Text.null value then key else key <> "=" <> value
    -- an option and the comma that goes with it
    widen (Span a b) =
      let after = Text.drop b body
          spaces = Text.length (Text.takeWhile isSpace after)
          before = Text.take a body
          back = Text.length (Text.takeWhileEnd isSpace before)
       in if Text.take 1 (Text.drop spaces after) == ","
            then Span a (b + spaces + 1 + Text.length (Text.takeWhile (== ' ') (Text.drop (spaces + 1) after)))
            else if Text.takeEnd 1 (Text.dropEnd back before) == "," then Span (a - back - 1) b else Span a b

-- Take a statement out, and its line with it when nothing else is on the line.
removeLine :: Span -> Text -> Text
removeLine (Span a b) body =
  let before = Text.take a body
      after = Text.drop b body
      indent = Text.takeWhileEnd (\c -> c == ' ' || c == '\t') before
      startsLine = Text.length indent == Text.length before || Text.takeEnd 1 (Text.dropEnd (Text.length indent) before) == "\n"
      rest = Text.dropWhile (\c -> c == ' ' || c == '\t') after
   in if startsLine && (Text.null rest || Text.take 1 rest == "\n")
        then Text.dropEnd (Text.length indent) before <> Text.drop 1 rest
        else before <> after

-- Take a piece out of a line, and one of the spaces around it.
removeWithSpace :: Span -> Text -> Text
removeWithSpace (Span a b) body =
  let before = Text.take a body
      after = Text.drop b body
   in if Text.takeEnd 1 before == " " && Text.take 1 after == " " then before <> Text.drop 1 after else before <> after
