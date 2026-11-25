{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.Drawing
-- Description : A TikZ figure as things the page draws and the canvas edits.
--
-- A figure the evaluator carries out completely needs no TeX: its paths and
-- nodes become a @drawing@ content value, each part with the span of the text
-- it comes from. A figure with anything the evaluator leaves out is not drawn
-- here at all ('drawnFigure' gives 'Nothing'), so TeX draws it exactly.
module SlideBlaster.Product.Runtime.Drawing
  ( drawnFigure
  , figurePicture
  , figureMeasureItems
  , figureSizes
  , figurePlace
  , figureDrawable
  , inlineContent
  ) where

import SlideBlaster.Product.Runtime.Theme (unitScale)
import SlideBlaster.Syntax.Tikz.Ast hiding (Value)
import SlideBlaster.Syntax.Tikz.Edit (placeIn)
import SlideBlaster.Syntax.Tikz.Eval
import SlideBlaster.Syntax.Tikz.Math (pointsPerCm)
import SlideBlaster.Syntax.Tikz.Parse

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (isAlpha, isSpace)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text

-- | The one picture of a figure's text, with what the text around it and the
-- deck's preamble set up: where the picture's body starts and ends, its
-- options, and its statements after the set-up ones.
figurePicture :: Text -> [(Text, Text)] -> Text -> Maybe (Maybe Options, Picture)
figurePicture preamble palette body =
  let colours = [ItemCommand (Span 0 0) "definecolor" [plain name, plain "HTML", plain (Text.dropWhile (== '#') hex)] | (name, hex) <- palette]
      plain = Braced (Span 0 0)
      setupOf text offset = let Picture _ found = parsePicture offset text in filter keeps found
      keeps item = case item of
        ItemSet {} -> True
        ItemStyle {} -> True
        ItemCommand _ command _ -> command `elem` ["def", "newcommand", "renewcommand", "colorlet", "definecolor", "pgfmathsetmacro", "pgfmathtruncatemacro"]
        _ -> False
      before = colours <> setupOf preamble 0
   in if "\\begin{tikzpicture}" `Text.isInfixOf` body || "\\tikz" `Text.isInfixOf` body
        then
          let Document chunks = parseDocument body
              around = concat [setupOf (Text.take (b - a) (Text.drop a body)) a | ChunkText (Span a b) <- chunks]
           in case [(options, picture) | ChunkPicture _ options picture <- chunks] <> [(options, picture) | ChunkInline _ options picture <- chunks] of
                [(options, Picture at found)] -> Just (options, Picture at (before <> around <> found))
                _ -> Nothing
        else let Picture at found = parsePicture 0 body in Just (Nothing, Picture at (before <> found))

-- | Where the statement or node starting at a place of a figure's text stands
-- (centimetres, y up): what a checked move asks.
figurePlace :: Sizes -> Text -> [(Text, Text)] -> Text -> Int -> Maybe (Double, Double)
figurePlace sizes preamble palette body start =
  case figurePicture preamble palette body of
    Nothing -> Nothing
    Just (_, Picture _ withSetup) ->
      -- the statements the set-up adds stand before the picture's own
      placeIn (\options (Picture at own) -> evaluatePicture sizes options (Picture at (take (length withSetup - length own) withSetup <> own))) body start

-- | Whether the core draws a figure itself: the evaluator carries all of it
-- out. (Then TeX is not asked for it.)
figureDrawable :: Text -> [(Text, Text)] -> Text -> Bool
figureDrawable preamble palette body =
  case figurePicture preamble palette body of
    Nothing -> False
    Just (options, picture) ->
      let result = evaluatePicture Map.empty options picture
       in null (evaluatedProblems result) && not (null (evaluatedDrawn result))

-- | A figure as a @drawing@ value: the deck's preamble and palette, the width
-- asked for (slide units), the measured text sizes, and the figure's text.
-- 'Nothing' when the evaluator left anything out, or drew nothing.
drawnFigure :: Text -> Maybe Text -> Sizes -> Text -> [(Text, Text)] -> Maybe Double -> Text -> Maybe Value
drawnFigure ref file sizes preamble palette units body = do
  (options, picture) <- figurePicture preamble palette body
  let result = evaluatePicture sizes options picture
      drawn = evaluatedDrawn result
  if not (null (evaluatedProblems result)) || null drawn then Nothing else Just (drawing ref file units result)

-- | The measured sizes of figure texts, out of all the node sizes the page
-- reported (plan pixels, under @node:tz:@ and the text's key), in centimetres.
figureSizes :: Map.Map Text (Double, Double) -> Sizes
figureSizes measured = Map.fromList [(key, (w / unitScale, h / unitScale)) | (full, (w, h)) <- Map.toList measured, Just key <- [Text.stripPrefix measurePrefix full]]

measurePrefix :: Text
measurePrefix = "node:tz:"

-- | What the page is asked to measure for a figure: every node text nobody
-- measured yet, set as the figure sets it (the given style is the slide's body type).
figureMeasureItems :: Value -> Map.Map Text (Double, Double) -> Text -> [(Text, Text)] -> Text -> [(Text, Value)]
figureMeasureItems bodyStyle measured preamble palette body =
  case figurePicture preamble palette body of
    Nothing -> []
    Just (options, picture) ->
      let result = evaluatePicture (figureSizes measured) options picture
       in if not (null (evaluatedProblems result))
            then []
            else
              [ ( full
                , object
                    [ "key" .= full
                    , "content" .= inlineContent text
                    , "width" .= num (maybe 4000 (* unitScale) (textWidth style))
                    , "fit" .= (textWidth style == Nothing)
                    , "style" .= styled style
                    ]
                )
              | (key, text, style) <- evaluatedTexts result
              , let full = measurePrefix <> key
              , not (Map.member full measured)
              ]
  where
    styled style = case bodyStyle of
      Object o ->
        Object
          ( KeyMap.insert "size" (num (textSize style / pointsPerCm * unitScale))
              . KeyMap.insert "weight" (Number (if textBold style then 700 else 400))
              . KeyMap.insert "italic" (Bool (textItalic style))
              . KeyMap.insert "lineHeight" (Number 1.2)
              $ o
          )
      other -> other

drawing :: Text -> Maybe Text -> Maybe Double -> Evaluated -> Value
drawing ref file units result =
  let drawn = evaluatedDrawn result
      points = concat [segmentPoints s | DrawnPath {drawnSegments = segments} <- drawn, s <- segments] <> concat [corners box | DrawnNode {drawnBox = box} <- drawn]
      pad = 0.05
      (x1, x2, y1, y2) = (minimum (fmap fst points) - pad, maximum (fmap fst points) + pad, minimum (fmap snd points) - pad, maximum (fmap snd points) + pad)
      natural = x2 - x1
      k = unitScale * maybe 1 (\wanted -> if natural > 0 then wanted / natural else 1) units
      px x = (x - x1) * k
      py y = (y2 - y) * k
      spot (x, y) = number (px x) <> " " <> number (py y)
      pathData segments = Text.unwords (fmap piece segments)
      piece segment = case segment of
        MoveTo p -> "M " <> spot p
        LineTo p -> "L " <> spot p
        CurveTo a b c -> "C " <> spot a <> " " <> spot b <> " " <> spot c
        ClosePath -> "Z"
      strokeOf = maybe Null (\(Stroke colour width dash) -> object ["color" .= colour, "width" .= num (width / pointsPerCm * k), "dash" .= fmap (\d -> num (d / pointsPerCm * k)) dash])
      spanOf (Span a b) = [a, b]
      -- a tip nobody gave a length goes with the line: 3pt and four and a half line widths, as TikZ's own
      tipOf stroke = maybe Null (\(Tip kind size open) ->
        let width = maybe 0.4 strokeWidth stroke
            usual = (3 + 4.5 * width) / pointsPerCm
            name = case kind of
              TipTo -> "to" :: Text
              TipLatex -> "latex"
              TipStealth -> "stealth"
              TipTriangle -> "triangle"
              TipBar -> "bar"
              TipCircle -> "circle"
              TipDiamond -> "diamond"
              TipSquare -> "square"
         in object ["kind" .= name, "length" .= num (fromMaybe usual size * k), "open" .= open])
      startOf (Span a _) = a
      item (index, one) = case one of
        DrawnPath at segments stroke fill (startTip, endTip) opacity _ ->
          [ object
              [ "k" .= ("path" :: Text), "id" .= ("tz-" <> Text.pack (show index)), "span" .= spanOf at, "at" .= startOf at
              , "d" .= pathData segments, "stroke" .= strokeOf stroke, "fill" .= maybe Null String fill
              , "tips" .= object ["start" .= tipOf stroke startTip, "end" .= tipOf stroke endTip]
              , "opacity" .= num opacity
              ]
          ]
        DrawnNode at node name (NodeBox (cx, cy) w h shape turn) stroke fill corner shadow text style opacity _ ->
          let (left, top, width, height) = (px (cx - w / 2), py (cy + h / 2), w * k, h * k)
              r = min (corner * k) (min width height / 2)
              outline = case shape of
                ShapeRectangle
                  | r > 0 ->
                      Text.unwords
                        [ "M", pair (left + r) top, "L", pair (left + width - r) top, arc r, pair (left + width) (top + r)
                        , "L", pair (left + width) (top + height - r), arc r, pair (left + width - r) (top + height)
                        , "L", pair (left + r) (top + height), arc r, pair left (top + height - r)
                        , "L", pair left (top + r), arc r, pair (left + r) top, "Z"
                        ]
                  | otherwise -> Text.unwords ["M", pair left top, "L", pair (left + width) top, "L", pair (left + width) (top + height), "L", pair left (top + height), "Z"]
                ShapeDiamond -> Text.unwords ["M", pair left (top + height / 2), "L", pair (left + width / 2) top, "L", pair (left + width) (top + height / 2), "L", pair (left + width / 2) (top + height), "Z"]
                ShapeCoordinate -> ""
                _ ->
                  let (rx, ry) = (width / 2, height / 2)
                      half = "A " <> number rx <> " " <> number ry <> " 0 1 1 "
                   in Text.unwords ["M", pair left (top + ry), half <> pair (left + width) (top + ry), half <> pair left (top + ry), "Z"]
              arc radius = "A " <> number radius <> " " <> number radius <> " 0 0 1"
              pair x y = number x <> " " <> number y
              Span textStart textEnd = maybe (Span 0 0) (\(Braced s _) -> s) (nodeText node)
              ident = "tz-" <> Text.pack (show index)
              centre = object ["x" .= num (px cx), "y" .= num (py cy)]
              background =
                [ object
                    [ "k" .= ("path" :: Text), "id" .= (ident <> "-bg"), "of" .= ident, "span" .= spanOf at, "at" .= startOf (nodeSpan node)
                    , "d" .= outline, "stroke" .= strokeOf stroke, "fill" .= maybe Null String fill
                    , "tips" .= object ["start" .= Null, "end" .= Null], "opacity" .= num opacity
                    , "shadow" .= maybe Null (\(Shadow sx sy blur dark) -> object ["dx" .= num (sx * k), "dy" .= num (negate sy * k), "blur" .= num (blur * k), "opacity" .= num dark]) shadow
                    , "rotate" .= num turn, "about" .= centre
                    ]
                | stroke /= Nothing || fill /= Nothing
                , not (Text.null outline)
                ]
           in background
                <> [ object
                       [ "k" .= ("node" :: Text), "id" .= ident, "span" .= spanOf at, "at" .= startOf (nodeSpan node), "node" .= spanOf (nodeSpan node), "text" .= [textStart, textEnd]
                       , "name" .= maybe Null String name
                       , "box" .= object ["x" .= num left, "y" .= num top, "width" .= num width, "height" .= num height]
                       , "rotate" .= num turn, "opacity" .= num opacity
                       , "color" .= textColour style, "size" .= num (textSize style / pointsPerCm * k)
                       , "bold" .= textBold style, "italic" .= textItalic style, "mono" .= textMono style, "align" .= textAlign style
                       , "source" .= text
                       , "key" .= (measurePrefix <> textKey style text)
                       , "wrap" .= (textWidth style /= Nothing)
                       , "content" .= inlineContent text
                       ]
                   ]
   in object
        [ "t" .= ("drawing" :: Text)
        , "ref" .= ref
        , "file" .= maybe Null String file
        , "width" .= num ((x2 - x1) * k)
        , "height" .= num ((y2 - y1) * k)
        , "scale" .= num k
        , "origin" .= object ["x" .= num x1, "y" .= num y2]
        , "items" .= concatMap item (zip [1 :: Int ..] drawn)
        ]
  where
    segmentPoints segment = case segment of
      MoveTo q -> [q]
      LineTo q -> [q]
      CurveTo a b c -> [a, b, c]
      ClosePath -> []
    corners (NodeBox (x, y) w h _ turn) =
      let a = turn * pi / 180
       in [(x + sx * w / 2 * cos a - sy * h / 2 * sin a, y + sx * w / 2 * sin a + sy * h / 2 * cos a) | sx <- [-1, 1], sy <- [-1, 1]]

num :: Double -> Value
num value = Number (fromRational (toRational (fromIntegral (round (value * 100) :: Integer) / 100 :: Double)))

number :: Double -> Text
number value = Text.pack (show (fromIntegral (round (value * 100) :: Integer) / 100 :: Double))

-- How a piece of text is set as it is read.
data Face = Face {faceBold :: !Bool, faceItalic :: !Bool, faceMono :: !Bool, faceColour :: !(Maybe Text)}

-- | A node's text as content: maths between dollars, @\\\\@ as a line break,
-- the font commands of LaTeX as bold, italic and monospace text.
inlineContent :: Text -> [Value]
inlineContent source = merge (go (Face False False False Nothing) (Text.unpack source))
  where
    textValue face written =
      object
        ( ["t" .= ("text" :: Text), "text" .= Text.pack written]
            <> ["bold" .= True | faceBold face]
            <> ["italic" .= True | faceItalic face]
            <> ["mono" .= True | faceMono face]
            <> ["color" .= c | Just c <- [faceColour face]]
        )
    -- neighbouring plain pieces stay separate values; the page sets them one after the other
    merge = id
    go :: Face -> String -> [Value]
    go face chars =
      case chars of
        [] -> []
        '%' : rest -> go face (drop 1 (dropWhile (/= '\n') rest))
        '$' : rest ->
          let (math, after) = break (== '$') rest
           in object ["t" .= ("math" :: Text), "display" .= False, "tex" .= Text.pack math] : go face (drop 1 after)
        '\\' : '\\' : rest -> object ["t" .= ("br" :: Text)] : go face (skipBracket (dropWhile isSpace rest))
        '\\' : c : rest
          | c `elem` ("&%$#_{} " :: String) -> textValue face [c] : go face rest
          | c == ',' || c == ';' || c == ':' || c == '!' -> textValue face " " : go face rest
          | isAlpha c ->
              let (name, afterName) = span isAlpha (c : rest)
                  after = dropWhile (== ' ') afterName
               in command face name after
          | otherwise -> go face rest
        '~' : rest -> textValue face "\160" : go face rest
        '{' : rest ->
          let (inner, after) = group rest
           in go face inner <> go face after
        '}' : rest -> go face rest
        _ ->
          let (plain, after) = break (`elem` ("\\${}~%" :: String)) chars
              spaced = fmap (\ch -> if ch == '\n' then ' ' else ch) plain
           in textValue face spaced : go face after
    command face name after
      | name `elem` ["textbf", "mathbf"] = wrapped face {faceBold = True}
      | name `elem` ["textit", "emph", "textsl"] = wrapped face {faceItalic = True}
      | name == "texttt" = wrapped face {faceMono = True}
      | name `elem` ["textrm", "textsf", "textnormal", "mbox", "text", "textsc", "underline", "uline"] = wrapped face
      | name == "bfseries" || name == "bf" = go face {faceBold = True} after
      | name `elem` ["itshape", "it", "em", "slshape"] = go face {faceItalic = True} after
      | name == "ttfamily" || name == "tt" = go face {faceMono = True} after
      | name `elem` ["sffamily", "rmfamily", "normalfont", "tiny", "scriptsize", "footnotesize", "small", "normalsize", "large", "Large", "LARGE", "huge", "Huge", "centering", "raggedright", "raggedleft", "strut", "noindent", "selectfont", "par", "relax", "protect"] = go face after
      | name == "textcolor" =
          let (colour, rest1) = argument after
              (inner, rest2) = argument rest1
           in go face {faceColour = named colour} inner <> go face rest2
      | name == "color" = let (colour, rest1) = argument after in go face {faceColour = named colour} rest1
      | name `elem` ["vspace", "hspace", "vskip", "hskip", "label", "fontsize"] = go face (snd (argument (snd (argument' name after))))
      | name == "ldots" || name == "dots" = textValue face "\8230" : go face after
      | name == "to" = textValue face "\8594" : go face after
      | name == "checkmark" = textValue face "\10003" : go face after
      | otherwise =
          -- a command nobody here knows: its arguments are kept as text
          go face after
      where
        wrapped inside = let (inner, rest) = argument after in go inside inner <> go face rest
        argument' _ text = ("" :: String, text)
    named colour = resolveColour Map.empty (Text.pack colour)
    argument text =
      case text of
        '{' : rest -> group rest
        c : rest -> ([c], rest)
        [] -> ([], [])
    -- up to the brace that closes the one just read
    group = walk (0 :: Int) ""
      where
        walk _ seen [] = (reverse seen, [])
        walk depth seen (c : rest)
          | c == '\\', next : more <- rest = walk depth (next : c : seen) more
          | c == '{' = walk (depth + 1) (c : seen) rest
          | c == '}' && depth == 0 = (reverse seen, rest)
          | c == '}' = walk (depth - 1) (c : seen) rest
          | otherwise = walk depth (c : seen) rest
    skipBracket text = case text of
      '[' : rest -> drop 1 (dropWhile (/= ']') rest)
      _ -> text
