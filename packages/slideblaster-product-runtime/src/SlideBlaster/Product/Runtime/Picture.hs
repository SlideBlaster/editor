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
  , pictureInfo
  , pictureCentres
  , pictureBoxes
  , optionKeys
  , naturalSize
  , pictureMeasureItems
  , NodeSizes
  , PictureEnv (..)
  , expandNodeStyles
  , libraryFileOf
  , libraryNames
  , libraryStyles
  , nodeSizeKey
  , preambleColours
  ) where

import SlideBlaster.Canvas
  ( ContainerKind (..)
  , ContentNode (..)
  , OverlayStep
  , content
  , overlayVisibleAt
  )
import SlideBlaster.Canvas.Flow (PictureEndpoint (..), PictureFrom (..), PictureItem (..), PictureJoin (..), PictureLabel (..), PictureLine (..), PictureNode (..), contentPlainText, pictureNodeDistance)
import SlideBlaster.Product.Runtime.Lower (FigureInfo, lowerContent)
import SlideBlaster.Product.Runtime.Theme (unitScale)
import SlideBlaster.Canvas (SourceRef)

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as Encoding
import SlideBlaster.Product.Runtime.Sha256 (sha256Hex)
import Data.Char (isAlpha, isAlphaNum, isAscii, isHexDigit, digitToInt)
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

-- | Measured content sizes (plan pixels) by 'nodeSizeKey'. The page measures a
-- node's content with the real fonts; until its answer arrives the size is
-- estimated from the text.
type NodeSizes = Map.Map Text (Double, Double)

-- | What a node's content size depends on: its options and its content as
-- written. (The theme's type is the cache's concern: it is emptied when that changes.)
nodeSizeKey :: PictureNode -> Text
nodeSizeKey item =
  let options = pairsOf (pictureNodeOptions item)
      -- how a node looks does not change how big its content is; an sbbox paints its options itself
      relevant
        | any ((== "sbbox") . fst) options = options
        | otherwise = [o | o@(k, _) <- options, k `elem` ["role", "font", "text width", "align"]]
      written = Text.intercalate "," [k <> maybe "" ("=" <>) v | (k, v) <- relevant]
   in "node:" <> Text.pack (take 20 (sha256Hex (Encoding.encodeUtf8 (written <> "\0" <> pictureNodeSource item))))

-- Space between a node's content and its border, in slide units.
padX, padY :: Double
padX = 0.2
padY = 0.13

-- A length option such as @minimum width=3@ or @text width=4cm@, in slide units.
lengthOption :: Text -> PictureNode -> Maybe Double
lengthOption key item =
  case reverse [v | (k, Just v) <- pairsOf (pictureNodeOptions item), k == key] of
    v : _ -> case TextRead.double (Text.strip v) of
      Right (n, unit) | Text.strip unit `elem` ["", "cm"] -> Just n
      _ -> Nothing
    [] -> Nothing

hasOption :: Text -> PictureNode -> Bool
hasOption key item = any ((== key) . fst) (pairsOf (pictureNodeOptions item))

-- | The size of a node's box, in slide units: its content (measured, else
-- estimated) plus padding, no smaller than @minimum width@, @minimum height@
-- or @minimum size@; a @circle@ is as wide as the diagonal of that box.
boxSize :: NodeSizes -> PictureNode -> (Double, Double)
boxSize = sizeWith True

-- | The box a node would have without its @minimum ..@ options.
naturalSize :: NodeSizes -> PictureNode -> (Double, Double)
naturalSize = sizeWith False

sizeWith :: Bool -> NodeSizes -> PictureNode -> (Double, Double)
sizeWith minimums sizes item =
  let isBox = hasOption "sbbox" item
      (w0, h0) = case Map.lookup (nodeSizeKey item) sizes of
        Just (w, h) -> (w / unitScale + (if isBox then 0 else 2 * padX), h / unitScale + (if isBox then 0 else 2 * padY))
        Nothing -> estimatedSize item
      least key = if minimums then max (fromMaybe 0 (lengthOption key item)) (fromMaybe 0 (lengthOption "minimum size" item)) else 0
      (w1, h1) = (max w0 (least "minimum width"), max h0 (least "minimum height"))
   in if hasOption "circle" item
        then let d = max (sqrt (w0 * w0 + h0 * h0)) (max (least "minimum width") (least "minimum height")) in (d, d)
        else (w1, h1)

-- A guess from the amount of text, used until the page has measured.
estimatedSize :: PictureNode -> (Double, Double)
estimatedSize item =
  let text = visibleChars (contentPlainText (content (pictureNodeContent item)))
      chars = fromIntegral (max 1 (Text.length text)) :: Double
      wrap = fromMaybe 9 (lengthOption "text width" item)
      width = maybe (max 0.6 (min wrap (0.21 * chars + 2 * padX))) (+ 2 * padX) (lengthOption "text width" item)
      lines' = fromIntegral (max 1 (ceiling (0.21 * chars / wrap) :: Int)) :: Double
   in (width, 0.5 * lines' + 2 * padY)

-- The box of a node whose authored point is the given one.
boxAt :: NodeSizes -> Double -> Double -> PictureNode -> Geometry
boxAt sizes atX atY item =
  let (width, height) = boxSize sizes item
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
   in Geometry (atX + dx) (atY + dy) width height

-- | What laying a picture out needs besides its statements: measured content
-- sizes, and the slide's own regions a node may attach or draw a line to
-- (@title@, @body@), each as centre, width and height in slide units.
data PictureEnv = PictureEnv
  { envSizes :: !NodeSizes
  , envRegions :: ![(Text, (Double, Double, Double, Double))]
  }

-- | Every node with its geometry. A node attached to another sits beside it,
-- centred on that side, 'pictureNodeDistance' away; an attachment that names no
-- node, or loops back on itself, leaves the node in the middle of the slide.
layout :: PictureEnv -> [PictureItem] -> [(Text, (PictureNode, Geometry))]
layout env items = [(pictureNodeId n, (n, geometryOf [] n)) | n <- nodeItems]
  where
    sizes = envSizes env
    nodeItems = [n | PictureNodeItem n <- items]
    floating = boxAt sizes 8 4.5
    geometryOf seen n =
      case pictureNodeAttached n of
        Nothing -> boxAt sizes (pictureNodeX n) (pictureNodeY n) n
        Just (side, target)
          | pictureNodeId n `elem` seen -> floating n
          | otherwise ->
              let found = case [t | t <- nodeItems, pictureNodeId t == target] of
                    t : _ -> Just (geometryOf (pictureNodeId n : seen) t)
                    [] -> (\(rx, ry, rw, rh) -> Geometry rx ry rw rh) <$> lookup target (envRegions env)
                  d = fromMaybe (fromRational pictureNodeDistance) (pictureNodeGap n)
                  Geometry _ _ w h = floating n
               in case found of
                    Nothing -> floating n
                    Just (Geometry tx ty tw th) ->
                      let (sx, sy) = sideVector side
                          -- beside the target on that side; on a diagonal, past its corner both ways
                          x = tx + sx * (tw / 2 + d + w / 2)
                          y = ty + sy * (th / 2 + d + h / 2)
                       in Geometry x y w h

-- Which way a side points: x right, y up.
sideVector :: Text -> (Double, Double)
sideVector side =
  case side of
    "above" -> (0, 1)
    "below" -> (0, -1)
    "left" -> (-1, 0)
    "right" -> (1, 0)
    "above left" -> (-1, 1)
    "above right" -> (1, 1)
    "below left" -> (-1, -1)
    "below right" -> (1, -1)
    _ -> (0, 0)

-- | The style a node's content is set in: the theme role named by @role=@
-- (body unless said), resized and weighted by @font=@ (@\\small@, @\\large@,
-- @\\bfseries@, ...), aligned by @align=@ and coloured by @text=@.
nodeStyle :: (Text -> Value) -> [(Text, Text)] -> PictureNode -> Value
nodeStyle styleOf palette item =
  case styleOf role of
    Object o ->
      Object
        ( maybe id (KeyMap.insert "color" . String) colour
            . KeyMap.insert "align" (String align)
            . (if bold then KeyMap.insert "weight" (Number 700) else id)
            . (if italic then KeyMap.insert "italic" (Bool True) else id)
            . (\m -> case KeyMap.lookup "size" m of
                  Just (Number size) -> KeyMap.insert "size" (num (realToFrac size * scale)) m
                  _ -> m)
            $ o
        )
    other -> other
  where
    options = pairsOf (pictureNodeOptions item)
    value key = lookup key options >>= id
    role = maybe "body" Text.strip (value "role")
    font = fromMaybe "" (value "font")
    has command = ("\\" <> command) `Text.isInfixOf` font
    scale
      | has "tiny" = 0.6
      | has "footnotesize" = 0.7
      | has "small" = 0.8
      | has "large" = 1.2
      | has "Large" = 1.44
      | has "LARGE" = 1.73
      | has "huge" || has "Huge" = 2.07
      | otherwise = 1 :: Double
    bold = has "bfseries" || has "bf"
    italic = has "itshape" || has "it"
    colour = value "text" >>= resolveColour palette
    align = case value "align" of
      Just v | Text.strip v `elem` ["left", "right", "center"] -> Text.strip v
      _ -> "center"

-- | Named styles a deck may use on nodes. A bare option that names a style
-- stands for that style's options; the deck's own @\\tikzset{name/.style={..}}@
-- in the preamble come first, so they also redefine the built-in ones.
expandNodeStyles :: Text -> Text -> Text
expandNodeStyles preamble = Text.intercalate ", " . go (8 :: Int)
  where
    styles = preambleStyles preamble <> builtinStyles
    go depth options =
      concat
        [ case (Text.any (== '=') item, lookup (Text.strip item) styles) of
            (False, Just definition) | depth > 0 -> go (depth - 1) definition
            _ -> [Text.strip item]
        | item <- splitItems options
        , not (Text.null (Text.strip item))
        ]

builtinStyles :: [(Text, Text)]
builtinStyles =
  [ ("title", "role=title, font=\\bfseries")
  , ("body", "role=body, align=left")
  , ("note", "role=small, draw, fill=yellow!30, rounded corners")
  ]

-- @\\tikzset{name/.style={options}, other/.style={..}}@ definitions in a preamble.
preambleStyles :: Text -> [(Text, Text)]
preambleStyles preamble = mapMaybe definition (zip pieces (drop 1 pieces))
  where
    pieces = Text.splitOn "/.style" preamble
    definition (before, after) = do
      inner <- Text.stripPrefix "{" (Text.stripStart (Text.drop 1 (Text.stripStart after)))
      let name = Text.strip (Text.takeWhileEnd (\c -> c /= '{' && c /= ',' && c /= '\n') before)
      if Text.null name || not ("=" `Text.isPrefixOf` Text.stripStart after) then Nothing else Just (name, closing (0 :: Int) Text.empty inner)
    closing depth acc remaining = case Text.uncons remaining of
      Nothing -> acc
      Just (c, rest)
        | c == '}' && depth == 0 -> acc
        | c == '}' -> closing (depth - 1) (Text.snoc acc c) rest
        | c == '{' -> closing (depth + 1) (Text.snoc acc c) rest
        | otherwise -> closing depth (Text.snoc acc c) rest

-- | The library file a style name belongs to. A dotted name such as
-- @flowchart.decision@ is a library style: its definition, an ordinary
-- @\\tikzset{flowchart.decision/.style={..}}@ line, lives in the project file
-- @shapes/flowchart.tikz@ (the deck's own, else the one shipped with the editor).
libraryFileOf :: Text -> Maybe Text
libraryFileOf name =
  case Text.splitOn "." (Text.strip name) of
    family : rest@(_ : _)
      | all segment (family : rest) -> Just ("shapes/" <> family <> ".tikz")
    _ -> Nothing
  where
    segment s = not (Text.null s) && Text.all (\c -> isAlphaNum c && isAscii c || c == '-' || c == '_') s

-- | The library style names an option list uses (its bare dotted words).
libraryNames :: Text -> [Text]
libraryNames options = [name | item <- splitItems options, let name = Text.strip item, not (Text.any (== '=') name), Just _ <- [libraryFileOf name]]

-- | The definitions, as preamble text, of the library styles an option list
-- uses, read from the given library files (path to text). Only the lines that
-- define those names are taken, so a large library costs nothing it is not used for.
libraryStyles :: (Text -> Maybe Text) -> Text -> Text
libraryStyles readLibrary options =
  Text.unlines
    [ Text.takeWhile (/= '\n') found
    | name <- libraryNames options
    , Just path <- [libraryFileOf name]
    , Just text <- [readLibrary path]
    , let found = snd (Text.breakOn ("\\tikzset{" <> name <> "/.style=") text)
    , not (Text.null found)
    ]

-- | The centre of every node, in slide units, as laid out.
pictureCentres :: PictureEnv -> [PictureItem] -> [(Text, (Double, Double))]
pictureCentres env items = [(name, (x, y)) | (name, (_, Geometry x y _ _)) <- layout env items]

-- | The box of every node (width and height in slide units), as laid out.
pictureBoxes :: PictureEnv -> [PictureItem] -> [(Text, (Double, Double))]
pictureBoxes env items = [(name, (w, h)) | (name, (_, Geometry _ _ w h)) <- layout env items]

-- | What the page should measure: the content of each node whose size is not
-- known yet, laid out as it is painted (shrunk to fit, or at its @text width@).
pictureMeasureItems :: NodeSizes -> [(Text, Text)] -> (Text -> Value) -> OverlayStep -> (SourceRef -> FigureInfo) -> [PictureItem] -> [(Text, Value)]
pictureMeasureItems sizes palette styleOf step figures items =
  [ ( nodeSizeKey n
    , object
        [ "key" .= nodeSizeKey n
        , "content" .= lowerContent step figures (fmap (fillBox palette) (pictureNodeContent n))
        , "width" .= num (maybe 720 (* unitScale) (lengthOption "text width" n))
        , "fit" .= (lengthOption "text width" n == Nothing)
        , "style" .= nodeStyle styleOf palette n
        ]
    )
  | n <- [n | PictureNodeItem n <- items] <> [pictureLabelNode label | PictureLineItem line <- items, label <- pictureLineLabels line]
  , not (Map.member (nodeSizeKey n) sizes)
  ]

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

-- | One step of a line as it is drawn, in slide units: straight, an elbow
-- through a corner, or a curve with its two control points.
data Route
  = RouteLine !(Double, Double) !(Double, Double)
  | RouteElbow !(Double, Double) !(Double, Double) !(Double, Double)
  | RouteCurve !(Double, Double) !(Double, Double) !(Double, Double) !(Double, Double)

-- A node's turn in degrees (@rotate@), counter-clockwise.
turnOf :: PictureNode -> Double
turnOf n = case reverse [v | (k, Just v) <- pairsOf (pictureNodeOptions n), k == "rotate"] of
  v : _ | Right (value, rest) <- TextRead.signed TextRead.double (Text.strip v), Text.null (Text.strip rest) -> value
  _ -> 0

-- Where the segment from a turned box's centre towards a target leaves it.
clipTurned :: Double -> Geometry -> (Double, Double) -> (Double, Double)
clipTurned degrees g@(Geometry cx cy _ _) (tx, ty)
  | degrees == 0 = clip g (tx, ty)
  | otherwise =
      let a = degrees * pi / 180
          spin by (x, y) = (cx + (x - cx) * cos by - (y - cy) * sin by, cy + (x - cx) * sin by + (y - cy) * cos by)
       in spin a (clip g (spin (negate a) (tx, ty)))

-- | The steps of a line as drawn, given where the nodes and regions are.
-- A node end without an anchor starts on the border, towards where the step
-- goes first; with an anchor (@a.north@, @a.30@) it starts exactly there.
-- 'Nothing' when an end names nothing on the slide.
lineRoutes :: (Text -> Maybe (Geometry, Double)) -> PictureLine -> Maybe [Route]
lineRoutes placed line = traverse route (zip3 ends (drop 1 ends) (pictureLineJoins line <> repeat PictureStraight))
  where
    ends = zip (pictureLinePoints line) (pictureLineAnchors line <> repeat Nothing)
    -- an end as: its reference point, and how to leave it towards a target
    end (point, anchor) =
      case point of
        EndpointPoint x y -> Just ((x, y), const (x, y))
        EndpointNode name -> do
          (g@(Geometry cx cy w h), turn) <- placed name
          let spin (x, y) = let a = turn * pi / 180 in (cx + x * cos a - y * sin a, cy + x * sin a + y * cos a)
              corner sx sy = spin (sx * w / 2, sy * h / 2)
              fixed = case fmap (Text.unwords . Text.words) anchor of
                Nothing -> Nothing
                Just "center" -> Just (cx, cy)
                Just "north" -> Just (corner 0 1)
                Just "south" -> Just (corner 0 (-1))
                Just "east" -> Just (corner 1 0)
                Just "west" -> Just (corner (-1) 0)
                Just "north east" -> Just (corner 1 1)
                Just "north west" -> Just (corner (-1) 1)
                Just "south east" -> Just (corner 1 (-1))
                Just "south west" -> Just (corner (-1) (-1))
                Just other -> case TextRead.signed TextRead.double other of
                  Right (degrees, rest) | Text.null rest -> Just (clipTurned turn g (towards (cx, cy) (degrees + turn) (w + h + 1)))
                  _ -> Nothing
          Just (maybe ((cx, cy), clipTurned turn g) (\at -> (at, const at)) fixed)
    towards (x, y) degrees far = let a = degrees * pi / 180 in (x + far * cos a, y + far * sin a)
    route (a, b, join) = do
      (ca@(ax, ay), leaveA) <- end a
      (cb@(bx, by), leaveB) <- end b
      let curve out into =
            let a' = leaveA (towards ca out 1000)
                b' = leaveB (towards cb into 1000)
                -- TikZ's own looseness: the control points sit this far out
                d = 0.3915 * sqrt ((fst b' - fst a') ^ (2 :: Int) + (snd b' - snd a') ^ (2 :: Int))
             in RouteCurve a' (towards a' out d) (towards b' into d) b'
          straightAngle = atan2 (by - ay) (bx - ax) * 180 / pi
      Just $ case join of
        PictureStraight -> RouteLine (leaveA cb) (leaveB ca)
        PictureHV -> let c = (bx, ay) in RouteElbow (leaveA c) c (leaveB c)
        PictureVH -> let c = (ax, by) in RouteElbow (leaveA c) c (leaveB c)
        PictureBend degrees -> curve (straightAngle + degrees) (straightAngle + 180 - degrees)
        PictureOutIn out into -> curve out into

-- A point along a route (0 at its start, 1 at its end; an elbow's corner is at one half, as in TikZ) and the direction of travel there.
routeAt :: Route -> Double -> ((Double, Double), (Double, Double))
routeAt found t =
  case found of
    RouteLine a b -> (mix a b t, minus b a)
    RouteElbow a c b
      | t < 0.5 -> (mix a c (2 * t), minus c a)
      | otherwise -> (mix c b (2 * t - 1), minus b c)
    RouteCurve a c1 c2 b ->
      let u = 1 - t
          at (pa, pc1, pc2, pb) = u * u * u * pa + 3 * u * u * t * pc1 + 3 * u * t * t * pc2 + t * t * t * pb
          slope (pa, pc1, pc2, pb) = 3 * u * u * (pc1 - pa) + 6 * u * t * (pc2 - pc1) + 3 * t * t * (pb - pc2)
       in ((at (fst a, fst c1, fst c2, fst b), at (snd a, snd c1, snd c2, snd b)), (slope (fst a, fst c1, fst c2, fst b), slope (snd a, snd c1, snd c2, snd b)))
  where
    mix (x1, y1) (x2, y2) k = (x1 + (x2 - x1) * k, y1 + (y2 - y1) * k)
    minus (x1, y1) (x2, y2) = (x1 - x2, y1 - y2)

-- | Where each label of a line sits: along its step (@midway@ unless
-- @near start@, @near end@, @at start@, @at end@ or @pos=@ says otherwise),
-- then beside the line as its options ask: @above@, @below@, @left@, @right@,
-- @auto@ (to the left of the direction of travel; @swap@ for the right), or on it.
labelGeometries :: NodeSizes -> [Route] -> PictureLine -> [(PictureNode, Geometry)]
labelGeometries sizes routes line =
  [ (node, Geometry (px + ox) (py + oy) w h)
  | PictureLabel step atEnd node <- pictureLineLabels line
  , found : _ <- [drop (step - 1) routes]
  , let options = pairsOf (pictureNodeOptions node)
        keys = fmap fst options
        has key = key `elem` keys
        numberOf key = case reverse [v | (k, Just v) <- options, k == key] of
          v : _ | Right (value, rest) <- TextRead.signed TextRead.double (Text.strip v), Text.null (Text.strip rest) -> Just value
          _ -> Nothing
        t
          | Just value <- numberOf "pos" = max 0 (min 1 value)
          | has "at start" = 0
          | has "very near start" = 0.125
          | has "near start" = 0.25
          | has "midway" = 0.5
          | has "near end" = 0.75
          | has "very near end" = 0.875
          | has "at end" || atEnd = 1
          | otherwise = 0.5
        ((px, py), (tx, ty)) = routeAt found t
        (w, h) = boxSize sizes node
        gap = 0.06
        beside (sx, sy) = (sx * (w / 2 + gap), sy * (h / 2 + gap))
        len = sqrt (tx * tx + ty * ty)
        normal = if len == 0 then (0, 1) else (negate ty / len, tx / len)
        side (nx, ny) = let reach = abs nx * w / 2 + abs ny * h / 2 + gap in (nx * reach, ny * reach)
        swapped = has "swap" || [v | (k, Just v) <- options, k == "auto"] == ["right"]
        (ox, oy)
          | has "above left" = beside (-1, 1)
          | has "above right" = beside (1, 1)
          | has "below left" = beside (-1, -1)
          | has "below right" = beside (1, -1)
          | has "above" = beside (0, 1)
          | has "below" = beside (0, -1)
          | has "left" = beside (-1, 0)
          | has "right" = beside (1, 0)
          | has "auto" = side (if swapped then (negate (fst normal), negate (snd normal)) else normal)
          | otherwise = (0, 0)
  ]

num :: Double -> Value
num value = Number (fromRational (toRational (fromIntegral (round (value * 1000) :: Integer) / 1000 :: Double)))

-- | Plan items for a picture block at one audience step. The first argument is
-- the deck's colours; then the flow style, ink colour, step and figure lookup.
pictureValues :: PictureEnv -> [(Text, Text)] -> (Text -> Value) -> Text -> OverlayStep -> (SourceRef -> FigureInfo) -> Double -> [PictureItem] -> [Value]
pictureValues env palette styleOf ink step figures slideHeight items = concatMap nodeValue visibleNodes <> concatMap lineValue (zip [1 :: Int ..] [l | PictureLineItem l <- items])
  where
    nodes = layout env items
    regions = [(name, Geometry cx cy w h) | (name, (cx, cy, w, h)) <- envRegions env]
    visibleNodes = [(n, g) | (_, (n, g)) <- nodes, maybe True (overlayVisibleAt step) (pictureNodeHook n)]
    visibleIds = [pictureNodeId n | (n, _) <- visibleNodes]
    toPlan (x, y) = (x * unitScale, (slideHeight - y) * unitScale)
    optionsOf n = pairsOf (pictureNodeOptions n)
    nodeValue (n, Geometry cx cy w h) =
      let (left, top) = toPlan (cx - w / 2, cy + h / 2)
          box = object ["x" .= num left, "y" .= num top, "width" .= num (w * unitScale), "height" .= num (h * unitScale)]
          isBox = any ((== "sbbox") . fst) (optionsOf n)
          -- as in TikZ, a later option wins; @none@ takes a fill or a border away
          lastOf key = case reverse [v | (k, v) <- optionsOf n, k == key] of
            v : _ -> Just v
            [] -> Nothing
          fillColour = lastOf "fill" >>= id >>= resolveColour palette
          -- @outline={M .. Z}@: the node is drawn as that path, stretched over its box
          -- (x right and y down, both from 0 to 1), instead of as a rectangle
          outline = case lastOf "outline" of
            Just (Just v) | not (Text.null (unbraced v)) -> Just (unbraced v)
            _ -> Nothing
          unbraced v = let t = Text.strip v in Text.strip (fromMaybe t (Text.stripPrefix "{" t >>= Text.stripSuffix "}"))
          drawColour = case lastOf "draw" of
            Just (Just v) | Text.strip v == "none" -> Nothing
            Just (Just v) -> Just (fromMaybe ink (resolveColour palette v))
            Just Nothing -> Just ink
            -- an outline nobody coloured is still drawn: an invisible shape helps nobody
            Nothing | Just _ <- outline, fillColour == Nothing -> Just ink
            Nothing -> Nothing
          -- TikZ's own options: @rotate=30@ turns the node about its centre (counter-clockwise),
          -- a negative @xscale@ or @yscale@ mirrors its outline
          numberOf key = case lastOf key of
            Just (Just v) | Right (value, rest) <- TextRead.signed TextRead.double (Text.strip v), Text.null (Text.strip rest) -> Just value
            _ -> Nothing
          rotation = fromMaybe 0 (numberOf "rotate")
          (flipX, flipY) = (maybe False (< 0) (numberOf "xscale"), maybe False (< 0) (numberOf "yscale"))
          turned = ["rotate" .= num rotation | rotation /= 0]
          mirrored = ["flip" .= object ["x" .= flipX, "y" .= flipY] | flipX || flipY]
          nodesNow = fmap (fillBox palette) (pictureNodeContent n)
          lowered = lowerContent step figures nodesNow
          keys = fmap fst (optionsOf n)
          strokeWidth
            | "ultra thick" `elem` keys = 6
            | "very thick" `elem` keys = 4
            | "thick" `elem` keys = 3
            | "thin" `elem` keys = 1
            | otherwise = 2 :: Double
          strokeDash
            | "dashed" `elem` keys = toJSON [8, 6 :: Int]
            | "dotted" `elem` keys = toJSON [2, 6 :: Int]
            | otherwise = Null
          -- TikZ draws sharp corners unless asked; a circle is a square box rounded all the way
          radius
            | "circle" `elem` keys = w * unitScale / 2
            | "rounded corners" `elem` keys = 10
            | otherwise = 0
          background
            | isBox = []
            | fillColour == Nothing && drawColour == Nothing = []
            | Just d <- outline =
                [ object
                    ( [ "kind" .= ("path" :: Text), "id" .= ("pic-bg-" <> pictureNodeId n), "box" .= box, "d" .= d
                    , "fill" .= maybe Null String fillColour
                    , "stroke" .= maybe Null (\c -> object ["color" .= c, "width" .= num strokeWidth, "dash" .= strokeDash]) drawColour
                    , "opacity" .= num 1, "hit" .= Null
                    ]
                    <> turned <> mirrored
                )
                ]
            | otherwise =
                [ object
                    ( [ "kind" .= ("rect" :: Text), "id" .= ("pic-bg-" <> pictureNodeId n), "box" .= box
                    , "fill" .= maybe Null String fillColour
                    , "stroke" .= maybe Null (\c -> object ["color" .= c, "width" .= num strokeWidth, "dash" .= strokeDash]) drawColour
                    , "radius" .= num radius, "opacity" .= num 1, "hit" .= Null
                    ]
                    <> turned
                )
                ]
       in background
            <> [ object
                   ( [ "kind" .= ("flow" :: Text), "id" .= ("pic-" <> pictureNodeId n), "box" .= box
                     , "style" .= nodeStyle styleOf palette n, "content" .= lowered ]
                       <> turned
                   )
               ]
    placedNamed name = case [(g, turnOf n) | (key, (n, g)) <- nodes, key == name] of
      found : _ -> Just found
      [] -> (\g -> (g, 0)) <$> lookup name regions
    lineValue (index, line) =
      let options = pairsOf (pictureLineOptions line)
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
          -- the head a line names: -latex, stealth-stealth, -{Stealth[..]}, <-Latex ..
          tipped key = Text.any (== '-') key && any (`Text.isInfixOf` Text.toLower key) ["latex", "stealth", "triangle", "to", ">", "<"] && not (any (`Text.isPrefixOf` key) ["bend", "shorten", "rounded", "text", "inner", "minimum", "line"])
          tipKeys = filter tipped keys
          (startSide, endSide) = case tipKeys of
            key : _ -> let (before, after) = Text.breakOn "-" key in (before, Text.drop 1 after)
            [] -> ("", "")
          startArrow = not (Text.null (Text.strip startSide))
          endArrow = not (Text.null (Text.strip endSide))
          tipKind
            | any (("latex" `Text.isInfixOf`) . Text.toLower) tipKeys = Just ("latex" :: Text)
            | any (("stealth" `Text.isInfixOf`) . Text.toLower) tipKeys = Just "stealth"
            | otherwise = Nothing
          routes = if visibleBad (pictureLinePoints line) then Nothing else lineRoutes placedNamed line
          total = maybe 0 length routes
          common k =
            [ "id" .= ("pic-line-" <> Text.pack (show index) <> "-" <> Text.pack (show k))
            , "stroke" .= object ["color" .= colour, "width" .= num width, "dash" .= dash]
            , "arrow" .= (arrow k total startArrow endArrow :: Text)
            , "hit" .= Null
            ]
              <> ["tip" .= kind | Just kind <- [tipKind]]
          spot p = let (x, y) = toPlan p in showNumber x <> " " <> showNumber y
          showNumber v = Text.pack (show (fromIntegral (round (v * 100) :: Integer) / 100 :: Double))
          piece (k, found) = case found of
            RouteLine a b -> object (["kind" .= ("line" :: Text), "from" .= pt a, "to" .= pt b] <> common k)
            RouteElbow a c b -> object (["kind" .= ("trail" :: Text), "d" .= ("M " <> spot a <> " L " <> spot c <> " L " <> spot b)] <> common k)
            RouteCurve a c1 c2 b -> object (["kind" .= ("trail" :: Text), "d" .= ("M " <> spot a <> " C " <> spot c1 <> " " <> spot c2 <> " " <> spot b)] <> common k)
       in case routes of
            Nothing -> []
            Just found -> fmap piece (zip [1 :: Int ..] found) <> concatMap nodeValue (labelGeometries (envSizes env) found line)
    visibleBad ends = or [name `notElem` visibleIds && name `notElem` fmap fst regions | EndpointNode name <- ends]
    arrow k total s e
      | total == 1 && s && e = "both"
      | k == total && e = "end"
      | k == 1 && s = "start"
      | otherwise = "none"
    pt (x, y) = let (px, py) = toPlan (x, y) in object ["x" .= num px, "y" .= num py]
    listToMaybe' xs = case xs of x : _ -> Just x; [] -> Nothing

-- | What the canvas needs to edit a picture block: each visible node with its
-- box and authored point (plan pixels), its content as written and its source span, and each line
-- with the nodes it joins, and the gap kept between attached nodes. The order
-- of lines matches the @pic-line-N-k@ items.
pictureInfo :: PictureEnv -> OverlayStep -> Double -> [PictureItem] -> Value
pictureInfo env step slideHeight items =
  object
    [ "distance" .= num (fromRational pictureNodeDistance * unitScale)
    , "regions"
        .= [ object ["id" .= name, "box" .= object ["x" .= num ((cx - w / 2) * unitScale), "y" .= num ((slideHeight - cy - h / 2) * unitScale), "width" .= num (w * unitScale), "height" .= num (h * unitScale)]]
           | (name, (cx, cy, w, h)) <- envRegions env
           , name `notElem` [pictureNodeId n | PictureNodeItem n <- items]
           ]
    , "nodes"
        .= [ object
               [ "id" .= pictureNodeId n
               , "named" .= pictureNodeNamed n
               , "box" .= object ["x" .= num ((cx - w / 2) * unitScale), "y" .= num ((slideHeight - cy - h / 2) * unitScale), "width" .= num (w * unitScale), "height" .= num (h * unitScale)]
               , "at" .= (case pictureNodeAttached n of
                    Nothing -> object ["x" .= num (pictureNodeX n * unitScale), "y" .= num ((slideHeight - pictureNodeY n) * unitScale)]
                    Just _ -> object ["x" .= num (cx * unitScale), "y" .= num ((slideHeight - cy) * unitScale)])
               , "attached" .= fmap (\(side, target) -> object ["side" .= side, "to" .= target, "distance" .= fmap (num . (* unitScale)) (pictureNodeGap n)]) (pictureNodeAttached n)
               , "source" .= pictureNodeSource n
               , "options" .= optionValues (pictureNodeOptions n)
               , "span" .= spanValue (pictureNodeSpan n)
               , "from" .= fmap fromValue (pictureNodeFrom n)
               ]
           | (_, (n, Geometry cx cy w h)) <- layout env items
           , maybe True (overlayVisibleAt step) (pictureNodeHook n)
           ]
    , "lines"
        .= [ object
               [ "id" .= ("line-" <> Text.pack (show (pictureLineStatement l)))
               , "item" .= ("pic-line-" <> Text.pack (show index))
               , "options" .= optionValues (pictureLineOptions l)
               , "ends" .= [case e of EndpointNode name -> String name; EndpointPoint _ _ -> Null | e <- pictureLinePoints l]
               , "points" .= [case e of EndpointPoint x y -> object ["x" .= num (x * unitScale), "y" .= num ((slideHeight - y) * unitScale)]; EndpointNode _ -> Null | e <- pictureLinePoints l]
               , "joins" .= [case j of PictureStraight -> "straight" :: Text; PictureHV -> "hv"; PictureVH -> "vh"; PictureBend d | d >= 0 -> "bend left"; PictureBend _ -> "bend right"; PictureOutIn _ _ -> "curve" | j <- pictureLineJoins l]
               , "bend" .= (case [abs d | PictureBend d <- pictureLineJoins l] of d : _ -> num d; [] -> Null)
               , "labels"
                   .= [ object
                          [ "index" .= j
                          , "box" .= object ["x" .= num ((cx - w / 2) * unitScale), "y" .= num ((slideHeight - cy - h / 2) * unitScale), "width" .= num (w * unitScale), "height" .= num (h * unitScale)]
                          , "source" .= pictureNodeSource n
                          , "options" .= optionValues (pictureNodeOptions n)
                          ]
                      | (j, (n, Geometry cx cy w h)) <- zip [1 :: Int ..] (maybe [] (\found -> labelGeometries (envSizes env) found l) (lineRoutes placedNamed l))
                      ]
               , "span" .= spanValue (pictureLineSpan l)
               , "from" .= fmap fromValue (pictureLineFrom l)
               ]
           | (index, l) <- zip [1 :: Int ..] [l | PictureLineItem l <- items]
           ]
    ]
  where
    laid = layout env items
    placedNamed name = case [(g, turnOf n) | (key, (n, g)) <- laid, key == name] of
      found : _ -> Just found
      [] -> (\(cx, cy, w, h) -> (Geometry cx cy w h, 0)) <$> lookup name (envRegions env)
    spanValue (a, b) = object ["start" .= a, "end" .= b]
    -- where an included item comes from; the shift as plan pixels (right, down)
    fromValue from =
      object
        [ "file" .= fromFile from
        , "cat" .= ("cat-" <> Text.pack (show (fromStatement from)))
        , "span" .= spanValue (fromSpan from)
        , "shift" .= object ["x" .= num (fst (fromShift from) * unitScale), "y" .= num (negate (snd (fromShift from)) * unitScale)]
        ]
    -- options as they apply (named styles already stand for their options), for showing what is on
    optionValues options = [object ["key" .= k, "value" .= v] | (k, v) <- pairsOf options]

-- Option list as (key, value) pairs; reuses the comma splitting of node options.
pairsOf :: Text -> [(Text, Maybe Text)]
pairsOf options = [pair item | item <- splitItems options, not (Text.null (Text.strip item))]
  where
    pair item = case Text.breakOn "=" item of
      (key, rest)
        | Text.null rest -> (Text.strip key, Nothing)
        | otherwise -> (Text.strip key, Just (Text.strip (Text.drop 1 rest)))

-- | The keys of an option list.
optionKeys :: Text -> [Text]
optionKeys = fmap fst . pairsOf

-- An option list split at its top-level commas.
splitItems :: Text -> [Text]
splitItems = go (0 :: Int) Text.empty
  where
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
