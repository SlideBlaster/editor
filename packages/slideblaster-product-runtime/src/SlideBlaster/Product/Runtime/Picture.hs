{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.Picture
-- Description : The picture tier (@```slide@ blocks) as plan items.
--
-- Nodes and straight @\\draw@ lines in slide units (16 by 9, origin
-- bottom-left) become flow, rect and line items in plan pixels (y down). Node
-- size is estimated from its text (the core has no DOM); lines to a node id stop
-- at the node's border. Colours come from the deck preamble's @\\definecolor@
-- lines and a few basic names; @fill=name!pct@ mixes with white as xcolor does.
module SlideBlaster.Product.Runtime.Picture
  ( pictureValues
  , preambleColours
  ) where

import SlideBlaster.Canvas
  ( ContainerKind (..)
  , ContentNode (..)
  , OverlayStep
  , content
  , overlayVisibleAt
  )
import SlideBlaster.Canvas.Flow (PictureEndpoint (..), PictureItem (..), contentPlainText)
import SlideBlaster.Product.Runtime.Lower (FigureInfo, lowerContent)
import SlideBlaster.Product.Runtime.Theme (unitScale)
import SlideBlaster.Canvas (SourceRef)

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (isAlpha, isHexDigit, digitToInt)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Numeric (showHex)

-- | @\\definecolor{name}{HTML}{RRGGBB}@ (and @{rgb}{r,g,b}@) in a preamble.
preambleColours :: Text -> [(Text, Text)]
preambleColours preamble = mapMaybe definition (drop 1 (Text.splitOn "\\definecolor" preamble))
  where
    definition rest = do
      (name, afterName) <- braced rest
      (model, afterModel) <- braced afterName
      (spec, _) <- braced afterModel
      case Text.toLower (Text.strip model) of
        "html" | Text.length (Text.strip spec) == 6, Text.all isHexDigit (Text.strip spec) -> Just (Text.strip name, "#" <> Text.toLower (Text.strip spec))
        "rgb" -> case traverse number (Text.splitOn "," spec) of
          Just [r, g, b] -> Just (Text.strip name, hex (round (r * 255), round (g * 255), round (b * 255)))
          _ -> Nothing
        _ -> Nothing
    braced t = do
      inner <- Text.stripPrefix "{" (Text.stripStart t)
      let (body, after) = Text.break (== '}') inner
      if Text.null after then Nothing else Just (body, Text.drop 1 after)
    number t = case TextRead.double (Text.strip t) of
      Right (v, _) -> Just v
      _ -> Nothing

type Rgb = (Int, Int, Int)

hex :: Rgb -> Text
hex (r, g, b) = "#" <> Text.pack (concatMap two [r, g, b])
  where two v = let h = showHex (max 0 (min 255 v)) "" in if length h < 2 then '0' : h else h

parseHex :: Text -> Maybe Rgb
parseHex t = case Text.unpack (Text.drop 1 t) of
  [a, b, c, d, e, f] | all isHexDigit [a, b, c, d, e, f] -> Just (h a b, h c d, h e f)
  _ -> Nothing
  where h x y = digitToInt x * 16 + digitToInt y

basicColours :: [(Text, Text)]
basicColours =
  [ ("black", "#000000"), ("white", "#ffffff"), ("red", "#ff0000"), ("green", "#00ff00"), ("blue", "#0000ff")
  , ("cyan", "#00ffff"), ("magenta", "#ff00ff"), ("yellow", "#ffff00"), ("gray", "#808080"), ("grey", "#808080")
  , ("orange", "#ff8000"), ("purple", "#bf0040"), ("brown", "#bf8040"), ("teal", "#008080"), ("violet", "#800080")
  , ("lightgray", "#bfbfbf"), ("darkgray", "#404040"), ("lime", "#bfff00"), ("olive", "#808000"), ("pink", "#ffbfbf")
  ]

-- | A colour expression: @name@, @#hex@ or @name!pct[!other]@.
resolveColour :: [(Text, Text)] -> Text -> Maybe Text
resolveColour palette expression =
  case Text.splitOn "!" (Text.strip expression) of
    [single] -> hex <$> base single
    [name, pct] -> mix name pct "white"
    [name, pct, other] -> mix name pct other
    _ -> Nothing
  where
    base name
      | "#" `Text.isPrefixOf` name = parseHex name
      | otherwise = firstJust [lookup name palette >>= parseHex, lookup name basicColours >>= parseHex]
    firstJust xs = case [x | Just x <- xs] of x : _ -> Just x; [] -> Nothing
    mix name pct other = do
      c1 <- base name
      c2 <- base other
      p <- case TextRead.double pct of
        Right (v, rest) | Text.null rest -> Just (max 0 (min 100 v) / 100)
        _ -> Nothing
      let m x y = round (p * fromIntegral x + (1 - p) * fromIntegral y :: Double)
          (r1, g1, b1) = c1
          (r2, g2, b2) = c2
      Just (hex (m r1 r2, m g1 g2, m b1 b2))

-- Node geometry in slide units.
data Geometry = Geometry Double Double Double Double

estimate :: PictureItem -> Geometry
estimate item =
  let text = visibleChars (contentPlainText (content (pictureNodeContent item)))
      chars = fromIntegral (max 4 (Text.length text)) :: Double
      width = max 1.2 (min 9 (0.21 * chars + 0.6))
      lines' = fromIntegral (max 1 (ceiling (0.21 * chars / 8.4) :: Int)) :: Double
      height = 0.5 * lines' + 0.3
      (dx, dy) = case pictureNodeAnchor item of
        "north" -> (0, -height / 2)
        "south" -> (0, height / 2)
        "east" -> (-width / 2, 0)
        "west" -> (width / 2, 0)
        "north east" -> (-width / 2, -height / 2)
        "north west" -> (width / 2, -height / 2)
        "south east" -> (-width / 2, height / 2)
        "south west" -> (width / 2, height / 2)
        _ -> (0, 0)
      centreX = max (width / 2 + 0.1) (min (16 - width / 2 - 0.1) (pictureNodeX item + dx))
   in Geometry centreX (pictureNodeY item + dy) width height

-- Drop TeX control words and braces so math counts by what it prints.
visibleChars :: Text -> Text
visibleChars text = Text.filter (\c -> c `notElem` ("{}$" :: String)) (strip text)
  where
    strip t = case Text.breakOn "\\" t of
      (before, rest)
        | Text.null rest -> before
        | otherwise -> before <> strip (Text.dropWhile isAlpha (Text.drop 1 rest))

-- Point where the segment from the centre of a box towards a target leaves it.
clip :: Geometry -> (Double, Double) -> (Double, Double)
clip (Geometry cx cy w h) (tx, ty)
  | dx == 0 && dy == 0 = (cx, cy)
  | otherwise = (cx + dx * t, cy + dy * t)
  where
    dx = tx - cx
    dy = ty - cy
    sx = if dx == 0 then 1 / 0 else (w / 2) / abs dx
    sy = if dy == 0 then 1 / 0 else (h / 2) / abs dy
    t = min 1 (min sx sy)

num :: Double -> Value
num value = Number (fromRational (toRational (fromIntegral (round (value * 1000) :: Integer) / 1000 :: Double)))

-- | Plan items for a picture block at one audience step. The first argument is
-- the deck's colours; then the flow style, ink colour, step and figure lookup.
pictureValues :: [(Text, Text)] -> Value -> Text -> OverlayStep -> (SourceRef -> FigureInfo) -> Double -> [PictureItem] -> [Value]
pictureValues palette flowStyle ink step figures slideHeight items = concatMap nodeValue visibleNodes <> concatMap lineValue (zip [1 :: Int ..] [l | l@PictureLineItem {} <- items])
  where
    nodes = [(pictureNodeId n, (n, estimate n)) | n@PictureNodeItem {} <- items]
    visibleNodes = [(n, g) | (_, (n, g)) <- nodes, maybe True (overlayVisibleAt step) (pictureNodeHook n)]
    visibleIds = [pictureNodeId n | (n, _) <- visibleNodes]
    toPlan (x, y) = (x * unitScale, (slideHeight - y) * unitScale)
    optionsOf n = pairsOf (pictureNodeOptions n)
    nodeValue (n, Geometry cx cy w h) =
      let (left, top) = toPlan (cx - w / 2, cy + h / 2)
          box = object ["x" .= num left, "y" .= num top, "width" .= num (w * unitScale), "height" .= num (h * unitScale)]
          isBox = any ((== "sbbox") . fst) (optionsOf n)
          fillColour = lookup "fill" (optionsOf n) >>= id >>= resolveColour palette
          drawColour = case (lookup "draw" (optionsOf n) >>= id >>= resolveColour palette, any ((== "draw") . fst) (optionsOf n)) of
            (Just c, _) -> Just c
            (Nothing, True) -> Just ink
            _ -> Nothing
          nodesNow = fmap (fillBox palette) (pictureNodeContent n)
          lowered = lowerContent step figures nodesNow
          background
            | isBox = []
            | fillColour == Nothing && drawColour == Nothing = []
            | otherwise =
                [ object
                    [ "kind" .= ("rect" :: Text), "id" .= ("pic-bg-" <> pictureNodeId n), "box" .= box
                    , "fill" .= maybe Null String fillColour
                    , "stroke" .= maybe Null (\c -> object ["color" .= c, "width" .= num 2]) drawColour
                    , "radius" .= num 6, "opacity" .= num 1, "hit" .= Null
                    ]
                ]
       in background
            <> [ object
                   [ "kind" .= ("flow" :: Text), "id" .= ("pic-" <> pictureNodeId n), "box" .= box
                   , "style" .= centred flowStyle, "content" .= lowered ]
               ]
    centred style = case style of
      Object o -> Object (KeyMap.insert "align" (String "center") o)
      other -> other
    lineValue (index, line) =
      let points = [resolvePoint p | p <- pictureLinePoints line]
          options = pairsOf (pictureLineOptions line)
          keys = [k | (k, _) <- options]
          colour = fromMaybe ink (listToMaybe' (mapMaybe (resolveColour palette) (keys <> [v | (k, Just v) <- options, k `elem` ["draw", "color"]])))
          width
            | "very thick" `elem` keys = 4
            | "thick" `elem` keys = 3
            | "thin" `elem` keys = 1
            | otherwise = 2 :: Double
          dash
            | "dashed" `elem` keys = toJSON [8, 6 :: Int]
            | "dotted" `elem` keys = toJSON [2, 6 :: Int]
            | otherwise = Null
          startArrow = any (`elem` keys) ["<-", "<->", "<-latex", "<-stealth"]
          endArrow = any (`elem` keys) ["->", "<->", "-latex", "-stealth", "->>", "-to"]
          segments = zip (pictureLinePoints line) (drop 1 (pictureLinePoints line))
          total = length segments
       in if any (== Nothing) points || visibleBad (pictureLinePoints line) then [] else
            [ object
                [ "kind" .= ("line" :: Text), "id" .= ("pic-line-" <> Text.pack (show index) <> "-" <> Text.pack (show k))
                , "from" .= pt a', "to" .= pt b'
                , "stroke" .= object ["color" .= colour, "width" .= num width, "dash" .= dash]
                , "arrow" .= (arrow k total startArrow endArrow :: Text)
                , "hit" .= Null
                ]
            | (k, (a, b)) <- zip [1 :: Int ..] segments
            , Just (a', b') <- [clipped a b]
            ]
    visibleBad ends = or [name `notElem` visibleIds | EndpointNode name <- ends]
    arrow k total s e
      | total == 1 && s && e = "both"
      | k == total && e = "end"
      | otherwise = "none"
    pt (x, y) = let (px, py) = toPlan (x, y) in object ["x" .= num px, "y" .= num py]
    resolvePoint p = centreOf p
    centreOf e = case e of
      EndpointPoint x y -> Just (x, y)
      EndpointNode name -> (\(_, Geometry x y _ _) -> (x, y)) <$> lookup name nodes
    edge e towards = case e of
      EndpointPoint x y -> Just (x, y)
      EndpointNode name -> (\(_, g) -> clip g towards) <$> lookup name nodes
    clipped a b = do
      ca <- centreOf a
      cb <- centreOf b
      Just (fromMaybe ca (edge a cb), fromMaybe cb (edge b ca))
    listToMaybe' xs = case xs of x : _ -> Just x; [] -> Nothing

-- Option list as (key, value) pairs; reuses the comma splitting of node options.
pairsOf :: Text -> [(Text, Maybe Text)]
pairsOf options = [pair item | item <- splitTop options, not (Text.null (Text.strip item))]
  where
    pair item = case Text.breakOn "=" item of
      (key, rest)
        | Text.null rest -> (Text.strip key, Nothing)
        | otherwise -> (Text.strip key, Just (Text.strip (Text.drop 1 rest)))
    splitTop = go (0 :: Int) Text.empty
    go depth acc remaining = case Text.uncons remaining of
      Nothing -> [acc]
      Just (c, rest)
        | c == '{' -> go (depth + 1) (Text.snoc acc c) rest
        | c == '}' -> go (max 0 (depth - 1)) (Text.snoc acc c) rest
        | c == ',' && depth == 0 -> acc : go depth Text.empty rest
        | otherwise -> go depth (Text.snoc acc c) rest

-- Rewrite a box's @fill=<colour expression>@ into a literal @fill=#hex@.
fillBox :: [(Text, Text)] -> ContentNode -> ContentNode
fillBox palette node = case node of
  TransparentContainer p (BoxContainer options) kids -> TransparentContainer p (BoxContainer (rewrite options)) kids
  other -> other
  where
    rewrite options =
      Text.intercalate "," [ case pair of
                               (k, Just v) | k == "fill", Just c <- resolveColour palette v -> "fill=" <> c
                               (k, Just v) -> k <> "=" <> v
                               (k, Nothing) -> k
                           | pair <- pairsOf options ]
