{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Tikz.Eval
-- Description : What a TikZ picture draws.
--
-- The evaluator walks the syntax tree as TikZ runs it: options change the
-- graphic state within their scope, coordinates are computed in the current
-- transformation, a path is built operation by operation and then stroked and
-- filled, nodes are sized from their text, placed, and remembered by name so
-- later coordinates can refer to them.
--
-- The result is a list of drawn things in centimetres, x to the right and y
-- up, each with the span of the statement it comes from, so that what is seen
-- can be traced back to the text and edited there.
--
-- What it cannot draw it says: every construct or option it does not carry
-- out is reported with its span. A caller that needs the exact picture (and
-- has TeX) can then use TeX for that picture instead.
module SlideBlaster.Syntax.Tikz.Eval
  ( Drawn (..)
  , Segment (..)
  , Stroke (..)
  , Tip (..)
  , TipKind (..)
  , Shadow (..)
  , NodeShape (..)
  , NodeBox (..)
  , TextStyle (..)
  , Problem (..)
  , Sizes
  , Evaluated (..)
  , evaluatePicture
  , textKey
  , matrixCells
  , resolveColour
  , Point
  ) where

import SlideBlaster.Syntax.Tikz.Ast
import SlideBlaster.Syntax.Tikz.Math
import SlideBlaster.Syntax.Tikz.Parse

import Data.Char (isAlpha, isDigit, isSpace)
import Data.List (foldl', sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Numeric (showHex)

-- | A point in centimetres: x to the right, y up.
type Point = (Double, Double)

data Segment
  = MoveTo !Point
  | LineTo !Point
  | CurveTo !Point !Point !Point
  | ClosePath
  deriving stock (Eq, Show)

-- | The head of an arrow: its kind, its length in centimetres when one is
-- written (otherwise it goes with the line's width), and whether it is hollow.
data Tip = Tip
  { tipKind :: !TipKind
  , tipLength :: !(Maybe Double)
  , tipOpen :: !Bool
  }
  deriving stock (Eq, Show)

data TipKind
  = -- | two thin strokes, as TeX's arrow: the tip TikZ uses unless told otherwise
    TipTo
  | -- | a long filled triangle with curved sides
    TipLatex
  | -- | a filled tip with a notch at the back
    TipStealth
  | TipTriangle
  | TipBar
  | TipCircle
  | TipDiamond
  | TipSquare
  deriving stock (Eq, Show)

-- | A node's shadow: how far right and up it lies (centimetres), how soft its
-- edge is (centimetres), how dark it is (0 to 1).
data Shadow = Shadow
  { shadowX :: !Double
  , shadowY :: !Double
  , shadowBlur :: !Double
  , shadowOpacity :: !Double
  }
  deriving stock (Eq, Show)

-- | How a line is stroked: colour (hex), width in points, dash lengths in points.
data Stroke = Stroke
  { strokeColour :: !Text
  , strokeWidth :: !Double
  , strokeDash :: ![Double]
  }
  deriving stock (Eq, Show)

data NodeShape
  = ShapeRectangle
  | ShapeCircle
  | ShapeEllipse
  | ShapeDiamond
  | -- | a point: no size, nothing drawn
    ShapeCoordinate
  deriving stock (Eq, Show)

-- | Where a node is: its centre, width and height (centimetres), its shape and
-- its turn in degrees, counter-clockwise.
data NodeBox = NodeBox
  { boxCentre :: !Point
  , boxWidth :: !Double
  , boxHeight :: !Double
  , boxShape :: !NodeShape
  , boxRotate :: !Double
  }
  deriving stock (Eq, Show)

-- | How a node's text is set: colour, size in points, weight and slant, the
-- width it is broken at (centimetres), how its lines are aligned.
data TextStyle = TextStyle
  { textColour :: !Text
  , textSize :: !Double
  , textBold :: !Bool
  , textItalic :: !Bool
  , textMono :: !Bool
  , textWidth :: !(Maybe Double)
  , textAlign :: !Text
  }
  deriving stock (Eq, Show)

data Drawn
  = -- | A path: its statement, its segments, how it is stroked and filled,
    -- whether it has an arrow tip at its start and at its end, its opacity,
    -- and its layer (below zero is behind the main one).
    DrawnPath
      { drawnSpan :: !Span
      , drawnSegments :: ![Segment]
      , drawnStroke :: !(Maybe Stroke)
      , drawnFill :: !(Maybe Text)
      , drawnArrows :: !(Maybe Tip, Maybe Tip)
      , drawnOpacity :: !Double
      , drawnLayer :: !Int
      }
  | -- | A node: the statement and the node within it, its name, where it is,
    -- its border and fill, its text as written and how it is set.
    DrawnNode
      { drawnSpan :: !Span
      , drawnNode :: !Node
      , drawnName :: !(Maybe Text)
      , drawnBox :: !NodeBox
      , drawnStroke :: !(Maybe Stroke)
      , drawnFill :: !(Maybe Text)
      , drawnRounded :: !Double
      , drawnShadow :: !(Maybe Shadow)
      , drawnText :: !Text
      , drawnTextStyle :: !TextStyle
      , drawnOpacity :: !Double
      , drawnLayer :: !Int
      }
  deriving stock (Eq, Show)

-- | Something the evaluator did not carry out: where, and what.
data Problem = Problem !Span !Text
  deriving stock (Eq, Show)

-- | The size of a node's text (width and height in centimetres) by 'textKey'.
-- A text nobody measured gets an estimate from its length.
type Sizes = Map Text (Double, Double)

data Evaluated = Evaluated
  { evaluatedDrawn :: ![Drawn]
  , evaluatedProblems :: ![Problem]
  , evaluatedTexts :: ![(Text, Text, TextStyle)]
  -- ^ every node text that was sized: its key, the text, how it is set
  , evaluatedNodes :: !(Map Text NodeBox)
  }
  deriving stock (Eq, Show)

-- | What the size of a text depends on.
textKey :: TextStyle -> Text -> Text
textKey style text =
  Text.intercalate "|" [Text.pack (show (textSize style)), flag (textBold style), flag (textItalic style), flag (textMono style), maybe "" (Text.pack . show) (textWidth style), text]
  where
    flag yes = if yes then "1" else "0"

-- Colours -------------------------------------------------------------------

type Rgb = (Double, Double, Double)

baseColours :: [(Text, Rgb)]
baseColours =
  [ ("black", (0, 0, 0)), ("white", (1, 1, 1)), ("red", (1, 0, 0)), ("green", (0, 1, 0)), ("blue", (0, 0, 1))
  , ("cyan", (0, 1, 1)), ("magenta", (1, 0, 1)), ("yellow", (1, 1, 0)), ("gray", (0.5, 0.5, 0.5)), ("grey", (0.5, 0.5, 0.5))
  , ("darkgray", (0.25, 0.25, 0.25)), ("lightgray", (0.75, 0.75, 0.75)), ("orange", (1, 0.5, 0)), ("purple", (0.75, 0, 0.25))
  , ("brown", (0.75, 0.5, 0.25)), ("lime", (0.75, 1, 0)), ("olive", (0.5, 0.5, 0)), ("pink", (1, 0.75, 0.75)), ("teal", (0, 0.5, 0.5)), ("violet", (0.5, 0, 0.5))
  ]

-- | A colour expression of xcolor as a hex colour: a name, or
-- @name!percent!name!percent..@ (the last mix is with white when no name follows).
resolveColour :: Map Text Text -> Text -> Maybe Text
resolveColour defined expression = toHex <$> mixed (Text.splitOn "!" (Text.strip expression))
  where
    named name =
      let key = Text.strip name
       in case Map.lookup key defined of
            Just hex -> fromHex hex
            Nothing
              | "#" `Text.isPrefixOf` key -> fromHex key
              | otherwise -> lookup key baseColours
    mixed parts =
      case parts of
        [] -> Nothing
        first : rest -> named first >>= \colour -> go colour rest
    go colour rest =
      case rest of
        [] -> Just colour
        [percent] -> blend colour percent (1, 1, 1) >>= \c -> go c []
        percent : other : more -> named other >>= blend colour percent >>= \c -> go c more
    blend (r1, g1, b1) percent (r2, g2, b2) =
      case TextRead.double (Text.strip percent) of
        Right (value, left) | Text.null (Text.strip left) ->
          let p = max 0 (min 100 value) / 100
           in Just (p * r1 + (1 - p) * r2, p * g1 + (1 - p) * g2, p * b1 + (1 - p) * b2)
        _ -> Nothing

toHex :: Rgb -> Text
toHex (r, g, b) = Text.pack ("#" <> concatMap two [r, g, b])
  where
    two value = let n = max 0 (min 255 (round (value * 255) :: Int)) in (if n < 16 then "0" else "") <> showHex n ""

fromHex :: Text -> Maybe Rgb
fromHex hex =
  case Text.unpack (Text.dropWhile (== '#') hex) of
    [a, b, c, d, e, f] -> (,,) <$> pair a b <*> pair c d <*> pair e f
    _ -> Nothing
  where
    pair x y = (\hi lo -> fromIntegral (hi * 16 + lo) / 255) <$> digit x <*> digit y
    digit c
      | isDigit c = Just (fromEnum c - fromEnum '0')
      | c `elem` ("abcdef" :: String) = Just (fromEnum c - fromEnum 'a' + 10)
      | c `elem` ("ABCDEF" :: String) = Just (fromEnum c - fromEnum 'A' + 10)
      | otherwise = Nothing :: Maybe Int

-- State ---------------------------------------------------------------------

-- An affine map: x' = a x + c y + e, y' = b x + d y + f.
data Affine = Affine !Double !Double !Double !Double !Double !Double

identity :: Affine
identity = Affine 1 0 0 1 0 0

apply :: Affine -> Point -> Point
apply (Affine a b c d e f) (x, y) = (a * x + c * y + e, b * x + d * y + f)

-- First the second map, then the first.
compose :: Affine -> Affine -> Affine
compose (Affine a b c d e f) (Affine a' b' c' d' e' f') =
  Affine (a * a' + c * b') (b * a' + d * b') (a * c' + c * d') (b * c' + d * d') (a * e' + c * f' + e) (b * e' + d * f' + f)

-- What a scope can change and its end takes back.
data Env = Env
  { envTransform :: !Affine
  , envDraw :: !(Maybe Text)
  -- ^ the colour a path is stroked with, when it is
  , envFill :: !(Maybe Text)
  , envColour :: !Text
  -- ^ the colour lines, fills and text take when none is named
  , envText :: !(Maybe Text)
  , envLineWidth :: !Double
  , envDash :: ![Double]
  , envArrows :: !(Maybe Tip, Maybe Tip)
  , envTip :: !Tip
  -- ^ what @>@ stands for (@>=Latex@ sets it)
  , envRounded :: !Double
  , envOpacity :: !Double
  , envLayer :: !Int
  , envStyles :: !(Map Text Text)
  -- ^ named styles: the option list each stands for (with @#1@ for its argument)
  , envMacros :: !(Map Text Text)
  , envColours :: !(Map Text Text)
  , envFontSize :: !Double
  , envBold :: !Bool
  , envItalic :: !Bool
  , envMono :: !Bool
  , envNodeDistance :: !Double
  , envNode :: !NodeSetup
  , envTo :: !ToSetup
  , envRadius :: !(Double, Double)
  , envArc :: !(Maybe Double, Maybe Double, Maybe Double)
  , envShorten :: !(Double, Double)
  -- ^ how much shorter a line is at its start and at its end
  , envMatrix :: !Bool
  , envShape :: !Bool
  -- ^ whether nodes grow and shrink with the transformation
  , envShadow :: !(Maybe Shadow)
  , envSeps :: !(Double, Double)
  -- ^ the space between the columns and between the rows of a matrix
  , envOnNode :: !Bool
  -- ^ whether the options being read are a node's (then a colour or a shape name means the node's)
  }

-- What only nodes have.
data NodeSetup = NodeSetup
  { setupShape :: !NodeShape
  , setupInner :: !(Double, Double)
  , setupMinimum :: !(Double, Double)
  , setupTextWidth :: !(Maybe Double)
  , setupAlign :: !Text
  , setupAnchor :: !(Maybe Text)
  , setupPlace :: !(Maybe (Text, Maybe Double, Maybe Text))
  -- ^ @above@, @below left@ ..: the side, a distance, and the node it is @of@
  , setupRotate :: !Double
  , setupPos :: !(Maybe Double)
  , setupAuto :: !(Maybe Bool)
  -- ^ beside the line: to its left ('False') or, swapped, to its right
  , setupSloped :: !Bool
  , setupLabels :: ![Text]
  , setupFit :: !(Maybe Text)
  , setupShift :: !(Double, Double)
  , setupDrawn :: !Bool
  -- ^ whether @draw@ was asked of this node itself
  , setupFilled :: !Bool
  }

data ToSetup = ToSetup
  { toBend :: !(Maybe Double)
  , toOut :: !(Maybe Double)
  , toIn :: !(Maybe Double)
  , toLooseness :: !Double
  , toLoop :: !Bool
  , toBendAngle :: !Double
  }

-- What stays when a scope ends.
data World = World
  { worldNodes :: !(Map Text NodeBox)
  , worldDrawn :: ![Drawn]
  , worldProblems :: ![Problem]
  , worldTexts :: ![(Text, Text, TextStyle)]
  }

-- A path as it is built.
data Building = Building
  { buildSegments :: ![Segment]
  -- ^ newest first
  , buildAt :: !Point
  , buildRel :: !Point
  -- ^ what a relative coordinate counts from: @+(..)@ leaves it where it was
  , buildStart :: !Point
  -- ^ where the current subpath began
  , buildFrom :: !(Maybe Text)
  -- ^ the node the path stands on, when its last coordinate was a node: the
  -- next line starts at that node's border
  , buildNodes :: ![Drawn]
  -- ^ the nodes of this path, drawn after it
  , buildLast :: !(Maybe Timer)
  , buildMid :: !Bool
  -- ^ whether the node being placed stands between a line's start and its end
  -- (written before the end): it then goes halfway unless it says otherwise
  }

-- The last part of a path, for placing a node along it.
data Timer
  = TimerLine !Point !Point
  | TimerCorner !Point !Point !Point
  | TimerCurve !Point !Point !Point !Point

defaultEnv :: Env
defaultEnv =
  Env
    { envTransform = identity
    , envDraw = Nothing
    , envFill = Nothing
    , envColour = "#000000"
    , envText = Nothing
    , envLineWidth = 0.4
    , envDash = []
    , envArrows = (Nothing, Nothing)
    , envTip = Tip TipTo Nothing False
    , envRounded = 0
    , envOpacity = 1
    , envLayer = 0
    , envStyles = Map.fromList builtinStyles
    , envMacros = Map.empty
    , envColours = Map.empty
    , envFontSize = 10
    , envBold = False
    , envItalic = False
    , envMono = False
    , envNodeDistance = 1
    , envNode = defaultNode
    , envTo = ToSetup Nothing Nothing Nothing 1 False 30
    , envRadius = (0, 0)
    , envArc = (Nothing, Nothing, Nothing)
    , envShorten = (0, 0)
    , envMatrix = False
    , envShape = False
    , envShadow = Nothing
    , envSeps = (0, 0)
    , envOnNode = False
    }

defaultNode :: NodeSetup
defaultNode = NodeSetup ShapeRectangle (innerSep, innerSep) (0, 0) Nothing "center" Nothing Nothing 0 Nothing Nothing False [] Nothing (0, 0) False False
  where
    innerSep = 0.3333 * 10 / pointsPerCm

builtinStyles :: [(Text, Text)]
builtinStyles =
  [ ("help lines", "color=gray, line width=0.2pt")
  , ("ultra thin", "line width=0.1pt"), ("very thin", "line width=0.2pt"), ("thin", "line width=0.4pt"), ("semithick", "line width=0.6pt")
  , ("thick", "line width=0.8pt"), ("very thick", "line width=1.2pt"), ("ultra thick", "line width=1.6pt")
  , ("solid", "dash pattern="), ("dashed", "dash pattern=on 3pt off 3pt"), ("dotted", "dash pattern=on 0.4pt off 2pt")
  , ("densely dashed", "dash pattern=on 3pt off 2pt"), ("loosely dashed", "dash pattern=on 3pt off 6pt")
  , ("densely dotted", "dash pattern=on 0.4pt off 1pt"), ("loosely dotted", "dash pattern=on 0.4pt off 4pt")
  , ("dash dot", "dash pattern=on 3pt off 2pt on 0.4pt off 2pt")
  ]

-- Evaluation ----------------------------------------------------------------

-- | Evaluate a picture: its options (those of @\\begin{tikzpicture}[..]@),
-- the sizes of the texts measured so far, the statements.
evaluatePicture :: Sizes -> Maybe Options -> Picture -> Evaluated
evaluatePicture sizes options picture =
  let start = World Map.empty [] [] []
      (env, world) = optionsIn sizes (Span 0 0) (maybe [] (\(Options _ found) -> found) options) (defaultEnv, start)
      final = statements sizes env world picture
   in Evaluated
        { evaluatedDrawn = sortOn layerOf (reverse (worldDrawn final))
        , evaluatedProblems = reverse (worldProblems final)
        , evaluatedTexts = reverse (worldTexts final)
        , evaluatedNodes = worldNodes final
        }
  where
    layerOf drawn = case drawn of
      DrawnPath {drawnLayer = layer} -> layer
      DrawnNode {drawnLayer = layer} -> layer

problem :: Span -> Text -> World -> World
problem at message world = world {worldProblems = Problem at message : worldProblems world}

-- The statements of a body; what they define holds until the body ends.
statements :: Sizes -> Env -> World -> Picture -> World
statements sizes env world (Picture _ found) = snd (run (env, world) found)
  where
    run state items =
      case items of
        [] -> state
        -- \ifdefined\name .. \fi: skipped when the name was never defined
        ItemCommand _ "ifdefined" _ : ItemCommand _ name _ : rest
          | Map.member name (envMacros (fst state)) -> run state rest
          | otherwise -> run state (drop 1 (dropWhile (not . isFi) rest))
        item : rest -> run (statement sizes item state) rest
    isFi item = case item of
      ItemCommand _ "fi" _ -> True
      _ -> False

statement :: Sizes -> Item -> (Env, World) -> (Env, World)
statement sizes item (env, world) =
  case item of
    ItemComment _ -> (env, world)
    ItemUnread at reason -> (env, problem at reason world)
    ItemPath command -> (env, path sizes env world command)
    ItemScope at options inner ->
      let (scoped, world') = optionsIn sizes at (maybe [] (\(Options _ found) -> found) options) (env, world)
       in (env, statements sizes scoped world' inner)
    ItemLayer _ layer inner ->
      (env, statements sizes env {envLayer = if layer == "background" then -1 else if layer == "foreground" then 1 else envLayer env} world inner)
    ItemOverlay _ _ _ inner -> (env, statements sizes env world inner)
    ItemSet at (Options _ found) -> optionsIn sizes at found (env, world)
    ItemStyle _ name appends (Options (Span a b) _) ->
      -- the options are kept as text: they are read when the style is used
      (env {envStyles = Map.insertWith (\new old -> if appends then old <> ", " <> new else new) name (Text.replicate 0 "" <> styleText a b) (envStyles env)}, world)
    ItemForeach at loop inner ->
      case foreachValues env loop of
        Left reason -> (env, problem at reason world)
        Right rounds -> (env, foldl' (\w bindings -> statements sizes (bind bindings env) w inner) world rounds)
    ItemCommand at name arguments -> command at name arguments
  where
    styleText _ _ = case item of
      ItemStyle _ _ _ (Options _ found) -> Text.intercalate ", " (fmap optionText found)
      _ -> ""
    texts = fmap (\(Braced _ t) -> t) arguments'
    arguments' = case item of
      ItemCommand _ _ found -> found
      _ -> []
    define name body = (env {envMacros = Map.insert (Text.dropWhile (== '\\') (Text.strip name)) body (envMacros env)}, world)
    command at name _ =
      case (name, texts) of
        ("def", [macro, parameters, body]) | Text.null (Text.strip parameters) -> define macro body
        ("def", _) -> (env, world)
        ("edef", [macro, parameters, body]) | Text.null (Text.strip parameters) -> define macro (expandIn env body)
        ("newcommand", [macro, body]) -> define macro body
        ("renewcommand", [macro, body]) -> define macro body
        ("newcommand", _) -> (env, world)
        ("pgfmathsetmacro", [macro, expression]) -> evaluated at macro expression (Text.pack . showNumber . mathNumber)
        ("pgfmathtruncatemacro", [macro, expression]) -> evaluated at macro expression (Text.pack . show . (truncate :: Double -> Integer) . mathNumber)
        ("pgfmathsetlengthmacro", [macro, expression]) -> evaluated at macro expression (\v -> Text.pack (showNumber (if mathUnits v then mathNumber v else mathNumber v)) <> "pt")
        ("colorlet", [new, old]) -> case resolveColour (envColours env) old of
          Just hex -> (env {envColours = Map.insert (Text.strip new) hex (envColours env)}, world)
          Nothing -> (env, problem at ("the colour " <> old <> " is not known") world)
        ("definecolor", [new, model, values]) -> case definedColour (Text.strip model) values of
          Just hex -> (env {envColours = Map.insert (Text.strip new) hex (envColours env)}, world)
          Nothing -> (env, problem at ("cannot read the colour " <> values) world)
        _
          | name `elem` ignored -> (env, world)
          | Just body <- Map.lookup name (envMacros env) ->
              -- a macro of the picture's own used as a statement: its text is read as statements
              let expanded = substitute texts body
                  inner = parsePicture 0 expanded
                  world' = statements sizes env world {worldProblems = worldProblems world} (respan at inner)
               in (env, world')
          | otherwise -> (env, problem at ("\\" <> name <> " is not carried out") world)
    evaluated at macro expression render =
      case mathIn env expression of
        Right value -> define macro (render value)
        Left reason -> (env, problem at reason world)
    ignored = ["usetikzlibrary", "usepgflibrary", "pgfdeclarelayer", "pgfsetlayers", "pgfresetboundingbox", "pgfmathsetseed", "small", "footnotesize", "centering", "ifdefined", "fi", "else", "relax", "noindent"]
    substitute arguments body = foldl' (\text (n, argument) -> Text.replace ("#" <> Text.pack (show n)) argument text) body (zip [1 :: Int ..] arguments)

-- Statements read from a macro's text all belong to the place the macro is used.
respan :: Span -> Picture -> Picture
respan at (Picture _ found) = Picture at (fmap item found)
  where
    item one = case one of
      ItemPath command -> ItemPath command {pathSpan = at}
      ItemScope _ options inner -> ItemScope at options (respan at inner)
      ItemForeach _ loop inner -> ItemForeach at loop (respan at inner)
      ItemLayer _ layer inner -> ItemLayer at layer (respan at inner)
      ItemOverlay _ name spec inner -> ItemOverlay at name spec (respan at inner)
      ItemSet _ options -> ItemSet at options
      ItemStyle _ name appends options -> ItemStyle at name appends options
      ItemCommand _ name arguments -> ItemCommand at name arguments
      ItemComment _ -> ItemComment at
      ItemUnread _ reason -> ItemUnread at reason

definedColour :: Text -> Text -> Maybe Text
definedColour model values =
  let numbers = mapMaybe (\t -> case TextRead.double (Text.strip t) of Right (v, _) -> Just v; Left _ -> Nothing) (Text.splitOn "," values)
   in case (model, numbers) of
        ("rgb", [r, g, b]) -> Just (toHex (r, g, b))
        ("RGB", [r, g, b]) -> Just (toHex (r / 255, g / 255, b / 255))
        ("gray", [g]) -> Just (toHex (g, g, g))
        ("HTML", _) -> toHex <$> fromHex (Text.strip values)
        _ -> Nothing

showNumber :: Double -> String
showNumber value =
  let rounded = fromIntegral (round (value * 100000) :: Integer) / 100000 :: Double
   in if rounded == fromIntegral (round rounded :: Integer) then show (round rounded :: Integer) else show rounded

macro' :: Env -> Text -> Maybe Text
macro' env name = Map.lookup name (envMacros env)

-- Expand the macros of a text, and the values a @let@ set: @\\x1@, @\\y{a}@, @\\p2@, @\\n1@.
expandIn :: Env -> Text -> Text
expandIn env = expandMacros (macro' env) . registers env

mathIn :: Env -> Text -> Either Text MathValue
mathIn env = evalMath (macro' env) . registers env

registers :: Env -> Text -> Text
registers env text =
  case Text.breakOn "\\" text of
    (before, rest)
      | Text.null rest -> before
      | Just (letter, more) <- Text.uncons (Text.drop 1 rest)
      , letter `elem` ("pxyn" :: String)
      , Just (index, after) <- indexOf more
      , Just value <- Map.lookup (Text.cons letter index) (envMacros env) ->
          before <> value <> registers env after
      | otherwise -> before <> "\\" <> registers env (Text.drop 1 rest)
  where
    indexOf more =
      case Text.uncons more of
        Just (c, _) | isDigit c -> Just (Text.span isDigit more)
        Just ('{', inner) | (name, close) <- Text.breakOn "}" inner, not (Text.null close) -> Just (name, Text.drop 1 close)
        _ -> Nothing

optionText :: Option -> Text
optionText option = optionKey option <> maybe "" ("/." <>) (optionHandler option) <> maybe "" (\(Value _ text) -> "={" <> text <> "}") (optionValue option)

bind :: [(Text, Text)] -> Env -> Env
bind bindings env = env {envMacros = foldl' (\macros (name, value) -> Map.insert name value macros) (envMacros env) bindings}

-- The rounds of a loop: for each, the values its variables take.
foreachValues :: Env -> Foreach -> Either Text [[(Text, Text)]]
foreachValues env loop =
  let Braced _ written = foreachList loop
      listText = expandIn env written
      variables = fmap (Text.dropWhile (== '\\') . Text.strip) (Text.splitOn "/" (foreachVariables loop))
      entries = expandDots (fmap Text.strip (splitTop ',' listText))
      counter = case foreachOptions loop of
        Just (Options _ found) -> [(Text.dropWhile (== '\\') (Text.strip (Text.takeWhile (/= ' ') value)), start value) | Option _ "count" _ (Just (Value _ value)) <- found]
        Nothing -> []
      start value = case Text.words value of
        [_, "from", n] -> fromMaybe 1 (readInt n)
        _ -> 1 :: Int
      readInt t = case TextRead.signed TextRead.decimal t of
        Right (n, rest) | Text.null rest -> Just n
        _ -> Nothing
   in if any Text.null variables
        then Left "a foreach needs a variable"
        else
          Right
            [ zip variables (parts <> repeat (lastOr "" parts)) <> [(name, Text.pack (show (from + index))) | (name, from) <- counter]
            | (index, entry) <- zip [0 ..] entries
            , let parts = fmap unbrace (splitTop '/' entry)
            ]
  where
    lastOr fallback list = case reverse list of
      final : _ -> final
      [] -> fallback
    unbrace t = fromMaybe t (Text.stripPrefix "{" (Text.strip t) >>= Text.stripSuffix "}")
    -- 1,2,...,6 and a,...,e
    expandDots list =
      case list of
        a : b : "..." : end : rest | Just x <- number a, Just y <- number b, Just z <- number end, y /= x -> fmap render (range x (y - x) z) <> expandDots rest
        a : "..." : end : rest | Just x <- number a, Just z <- number end -> fmap render (range x (if z >= x then 1 else -1) z) <> expandDots rest
        a : "..." : end : rest | [x] <- Text.unpack a, [z] <- Text.unpack end, isAlpha x, isAlpha z -> fmap Text.singleton [x .. z] <> expandDots rest
        a : rest -> a : expandDots rest
        [] -> []
    number t = case mathIn env t of
      Right value | not (Text.any isAlpha (expandIn env t)) -> Just (mathNumber value)
      _ -> Nothing
    range x step z = takeWhile (\v -> if step > 0 then v <= z + 1e-9 else v >= z - 1e-9) (take 2000 (iterate (+ step) x))
    render = Text.pack . showNumber

-- Split at a character outside braces.
splitTop :: Char -> Text -> [Text]
splitTop at text = go (0 :: Int) "" (Text.unpack text)
  where
    go _ seen [] = [Text.pack (reverse seen)]
    go depth seen (c : rest)
      | c == '{' = go (depth + 1) (c : seen) rest
      | c == '}' = go (depth - 1) (c : seen) rest
      | c == at && depth == 0 = Text.pack (reverse seen) : go depth "" rest
      | otherwise = go depth (c : seen) rest

-- Options -------------------------------------------------------------------

-- Carry out a list of options in order.
optionsIn :: Sizes -> Span -> [Option] -> (Env, World) -> (Env, World)
optionsIn sizes at found state = foldl' (\s option -> optionIn sizes at option s) state found

number' :: Env -> Text -> Maybe MathValue
number' env text = either (const Nothing) Just (mathIn env text)

-- A length in centimetres: a number without a unit counts in the given unit (points).
lengthIn :: Double -> Env -> Text -> Maybe Double
lengthIn unit env text = (\value -> if mathUnits value then mathNumber value / pointsPerCm else mathNumber value * unit / pointsPerCm) <$> number' env text

optionIn :: Sizes -> Span -> Option -> (Env, World) -> (Env, World)
optionIn sizes at option (env, world) =
  let key = optionKey option
      value = fmap (\(Value _ text) -> text) (optionValue option)
      node = envNode env
      set f = (f env, world)
      setNode f = (env {envNode = f node}, world)
      unknown = (env, problem (if optionSpan option == Span 0 0 then at else optionSpan option) ("the option " <> key <> maybe "" ("=" <>) value <> " is not carried out") world)
      colourOf text = resolveColour (envColours env) (expandIn env text)
      points text = (* pointsPerCm) <$> lengthIn 1 env text
      centimetres text = lengthIn 1 env text
      angle text = mathNumber <$> number' env text
      styled body argument = optionsIn sizes at (let Options _ found = parseOptions 0 (Text.replace "#1" (fromMaybe "" argument) body) in fmap (\o -> o {optionSpan = Span 0 0}) found) (env, world)
      place side = case value of
        Nothing -> setNode (\n -> n {setupPlace = Just (side, Nothing, Nothing)})
        Just text ->
          let written = Text.strip (expandIn env text)
              (before, ofNode) = Text.breakOn "of " written
              target = if Text.null ofNode then Nothing else Just (Text.strip (Text.drop 3 ofNode))
              distance = if Text.null (Text.strip before) then Nothing else lengthIn 1 env (Text.strip before)
           in setNode (\n -> n {setupPlace = Just (side, distance, target)})
   in case (optionHandler option, key, value) of
        (Just handler, _, Just body)
          | handler == "style" -> set (\e -> e {envStyles = Map.insert key body (envStyles e)})
          | handler == "append style" -> set (\e -> e {envStyles = Map.insertWith (\new old -> old <> ", " <> new) key body (envStyles e)})
          | handler == "prefix style" -> set (\e -> e {envStyles = Map.insertWith (\new old -> new <> ", " <> old) key body (envStyles e)})
          | handler `elem` ["default", "code", "pic", "tip"] -> (env, world)
        (Just "list", _, _) -> (env, world)
        (Just _, _, _) -> unknown
        (Nothing, "draw", Nothing) -> (env {envDraw = Just (fromMaybe (envColour env) (envDraw env)), envNode = node {setupDrawn = True}}, world)
        (Nothing, "draw", Just "none") -> (env {envDraw = Nothing, envNode = node {setupDrawn = False}}, world)
        (Nothing, "draw", Just text) -> maybe unknown (\c -> (env {envDraw = Just c, envNode = node {setupDrawn = True}}, world)) (colourOf text)
        (Nothing, "fill", Nothing) -> (env {envFill = Just (fromMaybe (envColour env) (envFill env)), envNode = node {setupFilled = True}}, world)
        (Nothing, "fill", Just "none") -> (env {envFill = Nothing, envNode = node {setupFilled = False}}, world)
        (Nothing, "fill", Just text) -> maybe unknown (\c -> (env {envFill = Just c, envNode = node {setupFilled = True}}, world)) (colourOf text)
        (Nothing, "color", Just text) -> maybe unknown (\c -> set (recolour c)) (colourOf text)
        (Nothing, "text", Just text) -> maybe unknown (\c -> set (\e -> e {envText = Just c})) (colourOf text)
        (Nothing, "line width", Just text) -> maybe unknown (\w -> set (\e -> e {envLineWidth = w})) (points text)
        (Nothing, "dash pattern", Just text) -> set (\e -> e {envDash = dashes e text})
        (Nothing, "opacity", Just text) -> maybe unknown (\o -> set (\e -> e {envOpacity = o})) (angle text)
        (Nothing, "draw opacity", Just _) -> (env, world)
        (Nothing, "fill opacity", Just text) -> maybe unknown (\o -> set (\e -> e {envOpacity = o})) (angle text)
        (Nothing, "text opacity", Just _) -> (env, world)
        (Nothing, "rounded corners", Nothing) -> set (\e -> e {envRounded = 4 / pointsPerCm})
        (Nothing, "rounded corners", Just text) -> maybe unknown (\r -> set (\e -> e {envRounded = r})) (centimetres text)
        (Nothing, "sharp corners", Nothing) -> set (\e -> e {envRounded = 0})
        (Nothing, "radius", Just text) -> maybe unknown (\r -> set (\e -> e {envRadius = (r, r)})) (radius text)
        (Nothing, "x radius", Just text) -> maybe unknown (\r -> set (\e -> e {envRadius = (r, snd (envRadius e))})) (radius text)
        (Nothing, "y radius", Just text) -> maybe unknown (\r -> set (\e -> e {envRadius = (fst (envRadius e), r)})) (radius text)
        (Nothing, "start angle", Just text) -> maybe unknown (\a -> set (\e -> let (_, b, c) = envArc e in e {envArc = (Just a, b, c)})) (angle text)
        (Nothing, "end angle", Just text) -> maybe unknown (\a -> set (\e -> let (s, _, c) = envArc e in e {envArc = (s, Just a, c)})) (angle text)
        (Nothing, "delta angle", Just text) -> maybe unknown (\a -> set (\e -> let (s, b, _) = envArc e in e {envArc = (s, b, Just a)})) (angle text)
        -- transformations: each is applied inside what is there already
        (Nothing, "shift", Just text) -> case parseCoordinate 0 (Text.strip text) of
          Right c | Just (x, y) <- vectorOf env world c -> set (transformed (Affine 1 0 0 1 x y))
          _ -> unknown
        (Nothing, "xshift", Just text) -> maybe unknown (\d -> onNodeOr (\n -> n {setupShift = (fst (setupShift n) + d, snd (setupShift n))}) (transformed (Affine 1 0 0 1 d 0))) (centimetres text)
        (Nothing, "yshift", Just text) -> maybe unknown (\d -> onNodeOr (\n -> n {setupShift = (fst (setupShift n), snd (setupShift n) + d)}) (transformed (Affine 1 0 0 1 0 d))) (centimetres text)
        (Nothing, "scale", Just text) -> maybe unknown (\k -> set (transformed (Affine k 0 0 k 0 0))) (angle text)
        (Nothing, "xscale", Just text) -> maybe unknown (\k -> set (transformed (Affine k 0 0 1 0 0))) (angle text)
        (Nothing, "yscale", Just text) -> maybe unknown (\k -> set (transformed (Affine 1 0 0 k 0 0))) (angle text)
        (Nothing, "rotate", Just text) -> maybe unknown (\a -> onNodeOr (\n -> n {setupRotate = setupRotate n + a}) (transformed (rotation a))) (angle text)
        (Nothing, "x", Just text) -> maybe unknown (\d -> set (transformed (Affine d 0 0 1 0 0))) (centimetres text)
        (Nothing, "y", Just text) -> maybe unknown (\d -> set (transformed (Affine 1 0 0 d 0 0))) (centimetres text)
        -- node set-up
        (Nothing, "inner sep", Just text) -> maybe unknown (\d -> setNode (\n -> n {setupInner = (d, d)})) (centimetres text)
        (Nothing, "inner xsep", Just text) -> maybe unknown (\d -> setNode (\n -> n {setupInner = (d, snd (setupInner n))})) (centimetres text)
        (Nothing, "inner ysep", Just text) -> maybe unknown (\d -> setNode (\n -> n {setupInner = (fst (setupInner n), d)})) (centimetres text)
        (Nothing, "outer sep", Just _) -> (env, world)
        (Nothing, "minimum width", Just text) -> maybe unknown (\d -> setNode (\n -> n {setupMinimum = (d, snd (setupMinimum n))})) (centimetres text)
        (Nothing, "minimum height", Just text) -> maybe unknown (\d -> setNode (\n -> n {setupMinimum = (fst (setupMinimum n), d)})) (centimetres text)
        (Nothing, "minimum size", Just text) -> maybe unknown (\d -> setNode (\n -> n {setupMinimum = (d, d)})) (centimetres text)
        (Nothing, "text width", Just text) -> maybe unknown (\d -> setNode (\n -> n {setupTextWidth = Just d, setupAlign = if setupAlign n == "center" && setupTextWidth n == Nothing then "left" else setupAlign n})) (centimetres text)
        (Nothing, "align", Just text) -> setNode (\n -> n {setupAlign = Text.strip text})
        (Nothing, "anchor", Just text) -> setNode (\n -> n {setupAnchor = Just (Text.unwords (Text.words text))})
        (Nothing, "shape", Just text) -> maybe unknown (\s -> setNode (\n -> n {setupShape = s})) (shapeNamed (Text.strip text))
        (Nothing, "node distance", Just text) -> maybe unknown (\d -> set (\e -> e {envNodeDistance = d})) (centimetres (Text.takeWhile (/= ' ') (Text.strip text)))
        (Nothing, "font", Just text) -> set (font text)
        (Nothing, "node font", Just text) -> set (font text)
        (Nothing, "pos", Just text) -> maybe unknown (\p -> setNode (\n -> n {setupPos = Just p})) (angle text)
        (Nothing, "auto", _) -> setNode (\n -> n {setupAuto = Just (value == Just "right")})
        (Nothing, "swap", Nothing) -> setNode (\n -> n {setupAuto = Just (maybe True not (setupAuto n))})
        (Nothing, "sloped", Nothing) -> setNode (\n -> n {setupSloped = True})
        (Nothing, "label", Just text) -> setNode (\n -> n {setupLabels = setupLabels n <> [text]})
        (Nothing, "fit", Just text) -> setNode (\n -> n {setupFit = Just text})
        (Nothing, "name", Just _) -> (env, world)
        (Nothing, "bend left", _) -> set (\e -> e {envTo = (envTo e) {toBend = Just (fromMaybe (toBendAngle (envTo e)) (value >>= angle))}})
        (Nothing, "bend right", _) -> set (\e -> e {envTo = (envTo e) {toBend = Just (negate (fromMaybe (toBendAngle (envTo e)) (value >>= angle)))}})
        (Nothing, "out", Just text) -> maybe unknown (\a -> set (\e -> e {envTo = (envTo e) {toOut = Just a}})) (angle text)
        (Nothing, "in", Just text) -> maybe unknown (\a -> set (\e -> e {envTo = (envTo e) {toIn = Just a}})) (angle text)
        (Nothing, "looseness", Just text) -> maybe unknown (\a -> set (\e -> e {envTo = (envTo e) {toLooseness = a}})) (angle text)
        (Nothing, "shorten >", Just text) -> maybe unknown (\d -> set (\e -> e {envShorten = (fst (envShorten e), d)})) (centimetres text)
        (Nothing, "shorten <", Just text) -> maybe unknown (\d -> set (\e -> e {envShorten = (d, snd (envShorten e))})) (centimetres text)
        (Nothing, "matrix", Nothing) -> set (\e -> e {envMatrix = True})
        (Nothing, "column sep", Just text) -> maybe unknown (\d -> set (\e -> e {envSeps = (d, snd (envSeps e))})) (centimetres text)
        (Nothing, "row sep", Just text) -> maybe unknown (\d -> set (\e -> e {envSeps = (fst (envSeps e), d)})) (centimetres text)
        (Nothing, "transform shape", Nothing) -> set (\e -> e {envShape = True})
        -- TikZ's own defaults: half an ex right and down; a blur shadow is soft and 40% dark, a drop shadow sharp and half as dark as its colour
        (Nothing, "blur shadow", _) -> set (\e -> e {envShadow = Just (shadowWith e value (Shadow 0.076 (-0.076) 0.105 0.4))})
        (Nothing, "drop shadow", _) -> set (\e -> e {envShadow = Just (shadowWith e value (Shadow 0.076 (-0.076) 0 0.25))})
        (Nothing, "circular drop shadow", _) -> set (\e -> e {envShadow = Just (shadowWith e value (Shadow 0.076 (-0.076) 0 0.25))})
        (Nothing, ">", Just text) -> set (\e -> e {envTip = fromMaybe (envTip e) (tipNamed e text)})
        (Nothing, "loop", Nothing) -> set (\e -> e {envTo = (envTo e) {toLoop = True, toLooseness = 8, toOut = Just (fromMaybe 105 (toOut (envTo e))), toIn = Just (fromMaybe 75 (toIn (envTo e)))}})
        (Nothing, "loop above", Nothing) -> set (\e -> e {envTo = (envTo e) {toLoop = True, toLooseness = 8, toOut = Just 105, toIn = Just 75}})
        (Nothing, "loop below", Nothing) -> set (\e -> e {envTo = (envTo e) {toLoop = True, toLooseness = 8, toOut = Just 285, toIn = Just 255}})
        (Nothing, "loop left", Nothing) -> set (\e -> e {envTo = (envTo e) {toLoop = True, toLooseness = 8, toOut = Just 195, toIn = Just 165}})
        (Nothing, "loop right", Nothing) -> set (\e -> e {envTo = (envTo e) {toLoop = True, toLooseness = 8, toOut = Just 15, toIn = Just (-15)}})
        (Nothing, "bend angle", Just text) -> maybe unknown (\a -> set (\e -> e {envTo = (envTo e) {toBendAngle = a}})) (angle text)
        (Nothing, "on background layer", Nothing) -> set (\e -> e {envLayer = -1})
        (Nothing, _, _)
          | key `elem` ["above", "below", "left", "right", "above left", "above right", "below left", "below right"] -> place key
          | Just position <- lookup key positions -> setNode (\n -> n {setupPos = Just position})
          | Just body <- Map.lookup key (envStyles env) -> styled body value
          | Just shape <- shapeNamed key, value == Nothing -> setNode (\n -> n {setupShape = shape})
          | value == Nothing, Just colour <- colourOf key -> set (recolour colour)
          | value == Nothing, Just arrows <- arrowSpec env key -> set (\e -> e {envArrows = arrows})
          | key `elem` quiet -> (env, world)
          | otherwise -> unknown
  where
    recolour colour e
      | envOnNode e = e {envColour = colour, envText = Just colour, envDraw = fmap (const colour) (envDraw e)}
      | otherwise = e {envColour = colour, envDraw = fmap (const colour) (envDraw e), envFill = fmap (const colour) (envFill e)}
    transformed local e = e {envTransform = compose (envTransform e) local}
    rotation degrees = let a = degrees * pi / 180 in Affine (cos a) (sin a) (negate (sin a)) (cos a) 0 0
    -- on a node these turn or move the node itself, not the coordinate system
    onNodeOr forNode forPath
      | envOnNode env = (env {envNode = forNode (envNode env)}, world)
      | otherwise = (forPath env, world)
    -- a radius without a unit counts in the picture's own units
    radius text = (\v -> if mathUnits v then mathNumber v / pointsPerCm else mathNumber v) <$> number' env text
    dashes e text =
      let pieces = Text.words (expandIn e text)
       in mapMaybe (\piece -> (* pointsPerCm) <$> lengthIn 1 e piece) (filter (`notElem` ["on", "off"]) pieces)
    font text e =
      let has names = any (`Text.isInfixOf` text) names
          size = lookupSize text
       in e
            { envFontSize = fromMaybe (envFontSize e) size
            , envBold = envBold e || has ["\\bfseries", "\\bf", "\\textbf"]
            , envItalic = envItalic e || has ["\\itshape", "\\it", "\\em", "\\slshape"]
            , envMono = envMono e || has ["\\ttfamily", "\\tt"]
            }
    lookupSize text = case [size | (name, size) <- fontSizes, name `Text.isInfixOf` text] of
      size : _ -> Just size
      [] -> Nothing
    fontSizes = [("\\tiny", 5), ("\\scriptsize", 7), ("\\footnotesize", 8), ("\\small", 9), ("\\normalsize", 10), ("\\large", 12), ("\\Large", 14.4), ("\\LARGE", 17.28), ("\\huge", 20.74), ("\\Huge", 24.88)]
    positions = [("midway", 0.5), ("near start", 0.25), ("near end", 0.75), ("very near start", 0.125), ("very near end", 0.875), ("at start", 0), ("at end", 1)]
    quiet = ["baseline", "remember picture", "overlay", "every node", "line cap", "line join", "cap", "use as bounding box", "clip", "behind path", "in front of path", "smooth", "anchor", "absolute", "semitransparent", "transparent", "midway", "above", "nodes", "execute at begin node", "inner color", "outer color", "shade", "pattern", "double", "path fading", "local bounding box", "tension", "samples", "domain", "variable", "mark", "name path", "name intersections", "decoration", "decorate", "postaction", "preaction", "trim left", "trim right", "text depth", "text height", "node contents"]

shapeNamed :: Text -> Maybe NodeShape
shapeNamed name =
  case name of
    "rectangle" -> Just ShapeRectangle
    "circle" -> Just ShapeCircle
    "ellipse" -> Just ShapeEllipse
    "diamond" -> Just ShapeDiamond
    "coordinate" -> Just ShapeCoordinate
    _ -> Nothing

-- @->@, @<-@, @<->@, @-latex@, @stealth-stealth@, @-{Stealth[length=2mm]}@, @|-|@ ..:
-- what stands before the hyphen is the tip at the start, what stands after it the tip at the end.
arrowSpec :: Env -> Text -> Maybe (Maybe Tip, Maybe Tip)
arrowSpec env key
  | Text.all (\c -> isAlpha c || isDigit c || c `elem` ("<>-|[]{}=.,* '" :: String)) key
  , (start, rest) <- breakTop (Text.unpack key)
  , '-' : end <- rest =
      Just (tipNamed env (Text.pack start), tipNamed env (Text.pack end))
  | otherwise = Nothing
  where
    -- up to the first hyphen outside braces and brackets
    breakTop = go (0 :: Int) ""
      where
        go _ seen [] = (reverse seen, [])
        go depth seen rest@(c : more)
          | c `elem` ("{[" :: String) = go (depth + 1) (c : seen) more
          | c `elem` ("}]" :: String) = go (depth - 1) (c : seen) more
          | c == '-' && depth == 0 = (reverse seen, rest)
          | otherwise = go depth (c : seen) more

-- One arrow tip as written: a name (or @>@ for the tip in use), maybe options in brackets.
tipNamed :: Env -> Text -> Maybe Tip
tipNamed env written =
  let trimmed = Text.strip (fromMaybe written (Text.stripPrefix "{" (Text.strip written) >>= Text.stripSuffix "}"))
      (name, bracket) = Text.breakOn "[" trimmed
      options = let Options _ found = parseOptions 0 (Text.dropEnd 1 (Text.drop 1 bracket)) in found
      lengthOf = case [text | Option _ "length" _ (Just (Value _ text)) <- options] of
        text : _ -> lengthIn 1 env (Text.unwords (take 1 (Text.words text)))
        [] -> Nothing
      open = or [True | Option _ "open" _ _ <- options]
      kind = case Text.toLower (Text.strip name) of
        "" -> Nothing
        n
          | Text.all (`elem` ("<>" :: String)) n -> Just (tipKind (envTip env))
          | n `elem` ["latex", "latex'", "latex reversed"] -> Just TipLatex
          | "stealth" `Text.isPrefixOf` n -> Just TipStealth
          | n `elem` ["to", "to reversed", "implies", "hooks", "straight barb", "classical tikz rightarrow", "computer modern rightarrow", "angle 90", "angle 60", "angle 45"] -> Just TipTo
          | "triangle" `Text.isPrefixOf` n -> Just TipTriangle
          | "open triangle" `Text.isPrefixOf` n -> Just TipTriangle
          | n `elem` ["|", "bar", "bracket", "tee barb"] -> Just TipBar
          | n `elem` ["o", "*", "circle", "ellipse"] -> Just TipCircle
          | n `elem` ["diamond", "open diamond", "kite", "turned square"] -> Just TipDiamond
          | n `elem` ["square", "open square", "rectangle"] -> Just TipSquare
          | otherwise -> Just TipLatex
      hollow = open || Text.strip name == "o" || "open " `Text.isPrefixOf` Text.toLower (Text.strip name)
      inherited = if Text.all (`elem` ("<>" :: String)) (Text.strip name) then tipLength (envTip env) else Nothing
   in (\k -> Tip k (maybe inherited Just lengthOf) (hollow || (Text.all (`elem` ("<>" :: String)) (Text.strip name) && tipOpen (envTip env)))) <$> kind

-- A shadow with what its own options say: @shadow xshift@, @shadow yshift@, @shadow opacity@ (in percent for a blur shadow), @shadow blur radius@.
shadowWith :: Env -> Maybe Text -> Shadow -> Shadow
shadowWith env value base =
  let Options _ found = parseOptions 0 (fromMaybe "" value)
      set shadow option = case (optionKey option, optionValue option) of
        ("shadow xshift", Just (Value _ text)) -> maybe shadow (\d -> shadow {shadowX = d}) (lengthIn 1 env text)
        ("shadow yshift", Just (Value _ text)) -> maybe shadow (\d -> shadow {shadowY = d}) (lengthIn 1 env text)
        ("shadow blur radius", Just (Value _ text)) -> maybe shadow (\d -> shadow {shadowBlur = d}) (lengthIn 1 env text)
        ("shadow opacity", Just (Value _ text)) -> maybe shadow (\v -> shadow {shadowOpacity = mathNumber v / 100}) (number' env text)
        ("opacity", Just (Value _ text)) -> maybe shadow (\v -> shadow {shadowOpacity = mathNumber v}) (number' env text)
        _ -> shadow
   in foldl' set base found

-- Coordinates ---------------------------------------------------------------

-- A coordinate as a vector: lengths as they are, plain numbers in the picture's units.
vectorOf :: Env -> World -> Coordinate -> Maybe Point
vectorOf env world c = fst <$> located env world (0, 0) c {coordRelative = Absolute}

-- Where a coordinate is, given the current point; and the node it names, if it names one whole.
located :: Env -> World -> Point -> Coordinate -> Maybe (Point, Maybe Text)
located env world current c = do
  let scoped = case coordOptions c of
        Just (Options _ found) -> fst (optionsIn Map.empty (coordSpan c) found (env {envOnNode = False}, world))
        Nothing -> env
  (found, name) <- body scoped (coordBody c)
  let moved = (fst (apply (envTransform scoped) (0, 0)) - fst (apply (envTransform env) (0, 0)), snd (apply (envTransform scoped) (0, 0)) - snd (apply (envTransform env) (0, 0)))
      point = case coordBody c of
        CoordNode _ _ | coordOptions c /= Nothing -> (fst found + fst moved, snd found + snd moved)
        _ -> found
      (x, y) = point
      (cx, cy) = current
  pure $ case coordRelative c of
    Absolute -> (point, name)
    _ -> ((cx + x - ox scoped, cy + y - oy scoped), Nothing)
  where
    -- a relative coordinate is a displacement: the origin's own place is taken off again
    ox e = fst (apply (envTransform e) (0, 0))
    oy e = snd (apply (envTransform e) (0, 0))
    expand e = expandIn e
    component e text = number' e (unbraced (expand e text))
    unbraced t = fromMaybe t (Text.stripPrefix "{" (Text.strip t) >>= Text.stripSuffix "}")
    body e form =
      case form of
        CoordXY xText yText -> do
          x <- component e xText
          y <- component e yText
          -- a part with a unit is a length on the canvas, one without counts in the picture's units
          let Affine a b cc d tx ty = envTransform e
              ux = if mathUnits x then (mathNumber x / pointsPerCm, 0) else (a * mathNumber x, b * mathNumber x)
              uy = if mathUnits y then (0, mathNumber y / pointsPerCm) else (cc * mathNumber y, d * mathNumber y)
          Just ((fst ux + fst uy + tx, snd ux + snd uy + ty), Nothing)
        CoordXYZ xText yText zText -> do
          x <- component e xText
          y <- component e yText
          z <- component e zText
          -- the z axis points down and to the left, as in TikZ
          let k = mathNumber z * (-0.385)
          Just (apply (envTransform e) (mathNumber x + k, mathNumber y + k), Nothing)
        CoordPolar angleText radiusText yRadius -> do
          let direction = lookup (Text.strip angleText) [("right", 0), ("east", 0), ("up", 90), ("north", 90), ("left", 180), ("west", 180), ("down", 270), ("south", 270), ("north east", 45), ("north west", 135), ("south west", 225), ("south east", 315)]
          a <- maybe (mathNumber <$> component e angleText) Just direction
          r <- component e radiusText
          ry <- maybe (Just r) (component e) yRadius
          let rad = a * pi / 180
              inUnits v = if mathUnits v then mathNumber v / pointsPerCm else mathNumber v
              local = (inUnits r * cos rad, inUnits ry * sin rad)
              Affine ta tb tc td tx ty = envTransform e
          Just (if mathUnits r then (fst local + tx, snd local + ty) else (ta * fst local + tc * snd local + tx, tb * fst local + td * snd local + ty), Nothing)
        CoordNode nameText anchor ->
          let name = Text.strip (expand e nameText)
           in case Map.lookup name (worldNodes world) of
                Just box -> case anchor of
                  Nothing -> Just (boxCentre box, if boxShape box == ShapeCoordinate then Nothing else Just name)
                  Just written -> (\p -> (p, Nothing)) <$> anchorOf box (Text.unwords (Text.words (expand e written)))
                Nothing ->
                  -- a macro that holds a whole coordinate: \p1, or a name defined as "1,2"
                  case parseCoordinate 0 ("(" <> name <> ")") of
                    Right inner | coordBody inner /= CoordNode name Nothing, not (Text.null name) -> body e (coordBody inner)
                    _ -> Nothing
        CoordMacro name -> do
          text <- macro' e name
          inner <- either (const Nothing) Just (parseCoordinate 0 (Text.strip text))
          located e world current inner
        CoordVH first second -> do
          ((x, _), _) <- body e first
          ((_, y), _) <- body e second
          Just ((x, y), Nothing)
        CoordHV first second -> do
          ((_, y), _) <- body e first
          ((x, _), _) <- body e second
          Just ((x, y), Nothing)
        CoordCalc text -> (\p -> (p, Nothing)) <$> calc e world (expand e text)
        CoordSystem _ _ -> Nothing
        CoordIntersection _ -> Nothing

-- A named anchor of a node, or the point on its border at an angle.
anchorOf :: NodeBox -> Text -> Maybe Point
anchorOf box anchor =
  case anchor of
    "center" -> Just (boxCentre box)
    "mid" -> Just (boxCentre box)
    "base" -> Just (boxCentre box)
    "text" -> Just (boxCentre box)
    "north" -> side 0 1
    "south" -> side 0 (-1)
    "east" -> side 1 0
    "west" -> side (-1) 0
    "north east" -> corner 1 1
    "north west" -> corner (-1) 1
    "south east" -> corner 1 (-1)
    "south west" -> corner (-1) (-1)
    "mid east" -> side 1 0
    "mid west" -> side (-1) 0
    "base east" -> side 1 0
    "base west" -> side (-1) 0
    _ -> case TextRead.signed TextRead.double anchor of
      Right (degrees, rest) | Text.null (Text.strip rest) ->
        let a = (degrees + boxRotate box) * pi / 180
            (cx, cy) = boxCentre box
         in Just (borderToward box (cx + 1000 * cos a, cy + 1000 * sin a))
      _ -> Nothing
  where
    turn (x, y) =
      let a = boxRotate box * pi / 180
          (cx, cy) = boxCentre box
       in (cx + x * cos a - y * sin a, cy + x * sin a + y * cos a)
    w = boxWidth box / 2
    h = boxHeight box / 2
    side sx sy = Just (turn (sx * w, sy * h))
    corner sx sy = case boxShape box of
      ShapeRectangle -> Just (turn (sx * w, sy * h))
      ShapeCoordinate -> Just (boxCentre box)
      -- on a round shape the corners lie on the border
      _ -> Just (turn (sx * w * sqrt 0.5, sy * h * sqrt 0.5))

-- Where the line from a node's centre towards a point leaves the node.
borderToward :: NodeBox -> Point -> Point
borderToward box (tx, ty) =
  let (cx, cy) = boxCentre box
      a = negate (boxRotate box) * pi / 180
      -- into the node's own frame
      (dx, dy) = ((tx - cx) * cos a - (ty - cy) * sin a, (tx - cx) * sin a + (ty - cy) * cos a)
      w = boxWidth box / 2
      h = boxHeight box / 2
      t = case boxShape box of
        ShapeCoordinate -> 0
        ShapeRectangle -> min (if dx == 0 then 1 / 0 else w / abs dx) (if dy == 0 then 1 / 0 else h / abs dy)
        ShapeDiamond -> let s = abs dx / max 1e-9 w + abs dy / max 1e-9 h in if s == 0 then 0 else 1 / s
        _ -> let s = sqrt ((dx / max 1e-9 w) ^ (2 :: Int) + (dy / max 1e-9 h) ^ (2 :: Int)) in if s == 0 then 0 else 1 / s
      (bx, by) = if dx == 0 && dy == 0 then (0, 0) else (dx * min 1 t, dy * min 1 t)
      back = negate a
   in (cx + bx * cos back - by * sin back, cy + bx * sin back + by * cos back)

-- The calc library: sums and differences of coordinates, each maybe times a
-- factor, each maybe a point between two others: @(a)!0.5!(b)@, @(a)!1cm!(b)@.
calc :: Env -> World -> Text -> Maybe Point
calc env world source = terms (Text.strip source) (0, 0) 1
  where
    terms text total sign
      | Text.null text = Just total
      | otherwise = do
          (factor, afterFactor) <- leadingFactor text
          (point, rest) <- modified afterFactor
          let total' = (fst total + sign * factor * fst point, snd total + sign * factor * snd point)
              trimmed = Text.stripStart rest
          case Text.uncons trimmed of
            Nothing -> Just total'
            Just ('+', more) -> terms (Text.stripStart more) total' 1
            Just ('-', more) -> terms (Text.stripStart more) total' (-1)
            _ -> Nothing
    -- 2*(a) or {sqrt(2)}*(a)
    leadingFactor text
      | "(" `Text.isPrefixOf` text = Just (1, text)
      | otherwise =
          let (before, after) = Text.breakOn "*" text
           in if Text.null after then Nothing else (\v -> (mathNumber v, Text.stripStart (Text.drop 1 after))) <$> number' env (unbraced before)
    unbraced t = fromMaybe t (Text.stripPrefix "{" (Text.strip t) >>= Text.stripSuffix "}")
    -- one coordinate and the !..! that may follow it
    modified text = do
      (first, rest) <- one text
      between first rest
    between first rest =
      case Text.stripPrefix "!" (Text.stripStart rest) of
        Nothing -> Just (first, rest)
        Just afterBang -> do
          let (middle, afterMiddle) = breakBang afterBang
          afterSecondBang <- Text.stripPrefix "!" afterMiddle
          -- an angle may stand before the second coordinate: !0.5!30:(b)
          let (turn, target) = case Text.breakOn ":" (Text.takeWhile (/= '(') afterSecondBang) of
                (degrees, colon) | not (Text.null colon) -> (mathNumber <$> number' env degrees, Text.dropWhile (/= '(') afterSecondBang)
                _ -> (Nothing, afterSecondBang)
          (secondRaw, final) <- one (Text.stripStart target)
          let second = case turn of
                Nothing -> secondRaw
                Just degrees ->
                  let a = degrees * pi / 180
                      (dx, dy) = (fst secondRaw - fst first, snd secondRaw - snd first)
                   in (fst first + dx * cos a - dy * sin a, snd first + dx * sin a + dy * cos a)
              (dx, dy) = (fst second - fst first, snd second - snd first)
              len = sqrt (dx * dx + dy * dy)
          point <-
            if "(" `Text.isPrefixOf` Text.strip middle
              then do
                -- the projection of a third point on the line
                (third, _) <- one (Text.strip middle)
                let k = if len == 0 then 0 else ((fst third - fst first) * dx + (snd third - snd first) * dy) / (len * len)
                Just (fst first + k * dx, snd first + k * dy)
              else do
                value <- number' env (unbraced middle)
                let k = if mathUnits value then (if len == 0 then 0 else mathNumber value / pointsPerCm / len) else mathNumber value
                Just (fst first + k * dx, snd first + k * dy)
          between point final
    breakBang text = go (0 :: Int) "" (Text.unpack text)
      where
        go _ seen [] = (Text.pack (reverse seen), "")
        go depth seen rest@(c : more)
          | c `elem` ("({" :: String) = go (depth + 1) (c : seen) more
          | c `elem` (")}" :: String) = go (depth - 1) (c : seen) more
          | c == '!' && depth == 0 = (Text.pack (reverse seen), Text.pack rest)
          | otherwise = go depth (c : seen) more
    -- a coordinate in parentheses (which may hold another calculation)
    one text = do
      inner <- Text.stripPrefix "(" text
      let (inside, rest) = closing inner
      afterClose <- Text.stripPrefix ")" rest
      coordinate <- either (const Nothing) Just (parseCoordinate 0 ("(" <> inside <> ")"))
      (point, _) <- located env world (0, 0) coordinate
      Just (point, afterClose)
    closing text = go (0 :: Int) "" (Text.unpack text)
      where
        go _ seen [] = (Text.pack (reverse seen), "")
        go depth seen rest@(c : more)
          | c == '(' || c == '{' = go (depth + 1) (c : seen) more
          | (c == ')' || c == '}') && depth > 0 = go (depth - 1) (c : seen) more
          | c == ')' = (Text.pack (reverse seen), Text.pack rest)
          | otherwise = go depth (c : seen) more

-- Paths ---------------------------------------------------------------------

path :: Sizes -> Env -> World -> PathCommand -> World
path sizes env world command =
  let usage = case pathCommand command of
        "draw" -> env {envDraw = Just (envColour env)}
        "fill" -> env {envFill = Just (envColour env)}
        "filldraw" -> env {envDraw = Just (envColour env), envFill = Just (envColour env)}
        "shadedraw" -> env {envDraw = Just (envColour env)}
        "matrix" -> env {envMatrix = True}
        _ -> env
      withEvery = case Map.lookup "every path" (envStyles env) of
        Just body -> fst (optionsIn sizes (pathSpan command) (let Options _ found = parseOptions 0 body in found) (usage, world))
        Nothing -> usage
      start = Building [] origin origin origin Nothing [] Nothing False
      origin = apply (envTransform env) (0, 0)
      (final, building, world') = operations sizes (pathSpan command) (pathOps command) (withEvery, start, world)
      segments = reverse (buildSegments building)
      visible = any (\s -> case s of LineTo _ -> True; CurveTo {} -> True; ClosePath -> True; MoveTo _ -> False) segments
      stroke = (\colour -> Stroke colour (envLineWidth final) (envDash final)) <$> envDraw final
      drawn =
        [ DrawnPath (pathSpan command) (rounded (envRounded final) (shortened (envShorten final) segments)) stroke (envFill final) (envArrows final) (envOpacity final) (envLayer final)
        | visible
        , stroke /= Nothing || envFill final /= Nothing
        , pathCommand command `notElem` ["clip", "useasboundingbox"]
        ]
   in world' {worldDrawn = reverse (buildNodes building) <> drawn <> worldDrawn world'}

type PathState = (Env, Building, World)

operations :: Sizes -> Span -> [PathOp] -> PathState -> PathState
operations sizes whole ops state = foldl' step state ops
  where
    step s@(_, before, _) op =
      let (env, after, world) = operation sizes whole op s
       in (env, after {buildRel = if stays op then buildRel before else buildAt after}, world)
    stays op = case op of
      OpMove _ c -> held c
      OpLine _ _ _ (TargetAt c) -> held c
      OpCurve _ _ _ _ (TargetAt c) -> held c
      OpRectangle _ _ (TargetAt c) -> held c
      OpTo _ _ _ (TargetAt c) -> held c
      OpEdge {} -> True
      OpNode _ -> True
      _ -> False
    held c = coordRelative c == RelativeStay

push :: Segment -> Building -> Building
push segment building = building {buildSegments = segment : buildSegments building}

-- Start a line from the current point: when the path stands on a node, from its border towards where the line goes.
leave :: World -> Point -> Building -> (Point, Building)
leave world toward building =
  case buildFrom building >>= \name -> Map.lookup name (worldNodes world) of
    Just box ->
      let from = borderToward box toward
          -- the move that put the path on the node is replaced by one to its border
          segments = case buildSegments building of
            MoveTo _ : rest -> MoveTo from : rest
            other -> MoveTo from : other
       in (from, building {buildSegments = segments, buildAt = from, buildFrom = Nothing})
    Nothing -> (buildAt building, building {buildFrom = Nothing})

-- End a line at a target: at the border of a node, coming from the given point.
arrive :: World -> Point -> (Point, Maybe Text) -> Point
arrive world from (point, name) =
  case name >>= \found -> Map.lookup found (worldNodes world) of
    Just box -> borderToward box from
    Nothing -> point

operation :: Sizes -> Span -> PathOp -> PathState -> PathState
operation sizes whole op (env, building, world) =
  let fails message = (env, building, problem (opSpan op) message world)
      find = located env world (buildRel building)
      targetOf to = case to of
        TargetAt c -> find c
        TargetCycle _ -> Just (buildStart building, Nothing)
      closes to = case to of
        TargetCycle _ -> True
        TargetAt _ -> False
      labelled timer found state = offMid (foldl' (\s label -> operation sizes whole label (onTimer timer s)) state found)
      onTimer timer (e, b, w) = (e, b {buildLast = Just timer, buildMid = True}, w)
      offMid (e, b, w) = (e, b {buildMid = False}, w)
      settle target b = case target of
        (point, Just name) -> b {buildAt = point, buildFrom = Just name}
        (point, Nothing) -> b {buildAt = point, buildFrom = Nothing}
   in case op of
        OpMove _ c -> case find c of
          Nothing -> fails ("cannot place the coordinate (" <> coordText c <> ")")
          Just (point, name) -> (env, (push (MoveTo point) building) {buildAt = point, buildStart = point, buildFrom = name, buildLast = Nothing}, world)
        OpLine _ join found to -> case targetOf to of
          Nothing -> fails "cannot place the end of this line"
          Just target@(centre, _) ->
            let corner = case join of
                  JoinLine -> Nothing
                  JoinHV -> Just (fst centre, snd (buildAt building))
                  JoinVH -> Just (fst (buildAt building), snd centre)
                (from, left) = leave world (fromMaybe centre corner) building
                end = arrive world (fromMaybe from corner) target
                drawn = foldl' (flip push) left (maybe [] (pure . LineTo) corner <> [if closes to then ClosePath else LineTo end])
                timer = maybe (TimerLine from end) (\c -> TimerCorner from c end) corner
                moved = (settle target drawn) {buildAt = if closes to then buildStart building else fst target, buildLast = Just timer}
             in labelled timer found (env, moved, world)
        OpCurve _ first second found to -> case (find first, maybe (find first) find second, targetOf to) of
          (Just (c1, _), Just (c2, _), Just target) ->
            let (from, left) = leave world c1 building
                end = arrive world c2 target
                timer = TimerCurve from c1 c2 end
                moved = (settle target (push (CurveTo c1 c2 end) left)) {buildLast = Just timer}
             in labelled timer found (env, moved, world)
          _ -> fails "cannot place the points of this curve"
        OpRectangle _ found to -> case targetOf to of
          Nothing -> fails "cannot place the corner of this rectangle"
          Just ((x2, y2), _) ->
            let (x1, y1) = buildAt building
                box = foldl' (flip push) building {buildFrom = Nothing} [MoveTo (x1, y1), LineTo (x2, y1), LineTo (x2, y2), LineTo (x1, y2), ClosePath]
                timer = TimerLine (x1, y1) (x2, y2)
             in labelled timer found (env, box {buildAt = (x2, y2), buildLast = Just timer}, world)
        OpCircle _ shape -> roundOp shape False
        OpEllipse _ shape -> roundOp shape True
        OpArc _ arc ->
          let read' text = number' env text
              parsed = case arc of
                ArcOld startText endText radiusText ->
                  let (rx, ry) = case Text.splitOn " and " radiusText of
                        [x, y] -> (x, y)
                        _ -> (radiusText, radiusText)
                   in (,,,) <$> (mathNumber <$> read' startText) <*> (mathNumber <$> read' endText) <*> (units <$> read' rx) <*> (units <$> read' ry)
                ArcKeys (Options _ found) ->
                  let (scoped, _) = optionsIn sizes whole found (env, world)
                      (rx, ry) = envRadius scoped
                   in case envArc scoped of
                        (Just s, Just e, _) -> Just (s, e, rx, ry)
                        (Just s, _, Just d) -> Just (s, s + d, rx, ry)
                        (_, Just e, Just d) -> Just (e - d, e, rx, ry)
                        _ -> Nothing
              units v = if mathUnits v then mathNumber v / pointsPerCm else mathNumber v
           in case parsed of
                Nothing -> fails "cannot read this arc"
                Just (startAngle, endAngle, rx, ry) ->
                  let (x0, y0) = buildAt building
                      rad a = a * pi / 180
                      centre = (x0 - rx * cos (rad startAngle), y0 - ry * sin (rad startAngle))
                      pieces = arcCurves centre rx ry startAngle endAngle
                      end = (fst centre + rx * cos (rad endAngle), snd centre + ry * sin (rad endAngle))
                   in (env, (foldl' (flip push) building {buildFrom = Nothing} pieces) {buildAt = end}, world)
        OpGrid _ options to -> case targetOf to of
          Nothing -> fails "cannot place the corner of this grid"
          Just ((x2, y2), _) ->
            let step = case options of
                  Just (Options _ found) -> case [text | Option _ "step" _ (Just (Value _ text)) <- found] of
                    text : _ -> fromMaybe 1 (lengthIn pointsPerCm env text)
                    [] -> 1
                  Nothing -> 1
                (x1, y1) = buildAt building
                (lowX, highX, lowY, highY) = (min x1 x2, max x1 x2, min y1 y2, max y1 y2)
                Affine a _ _ d _ _ = envTransform env
                (stepX, stepY) = (max 1e-3 (abs (step * a)), max 1e-3 (abs (step * d)))
                ticks low high size = takeWhile (<= high + 1e-6) (take 400 (iterate (+ size) (fromIntegral (ceiling (low / size - 1e-6) :: Integer) * size)))
                lines' = concat [[MoveTo (x, lowY), LineTo (x, highY)] | x <- ticks lowX highX stepX] <> concat [[MoveTo (lowX, y), LineTo (highX, y)] | y <- ticks lowY highY stepY]
             in (env, (foldl' (flip push) building {buildFrom = Nothing} lines') {buildAt = (x2, y2)}, world)
        OpTo _ options found to -> toOp options found to False
        OpEdge _ options found to -> toOp options found to True
        OpOptions _ (Options _ found) -> let (env', world') = optionsIn sizes whole found (env, world) in (env', building, world')
        OpScope _ inner ->
          let (_, building', world') = operations sizes whole inner (env, building, world) in (env, building', world')
        OpForeach at loop inner -> case foreachValues env loop of
          Left reason -> (env, building, problem at reason world)
          Right rounds ->
            let (building', world') = foldl' (\(b, w) bindings -> let (_, b', w') = operations sizes whole inner (bind bindings env, b, w) in (b', w')) (building, world) rounds
             in (env, building', world')
        OpLet at assignments -> case letBindings env world (buildRel building) assignments of
          Just bindings -> (bind bindings env, building, world)
          Nothing -> (env, building, problem at "cannot read this let" world)
        OpNode node -> let (drawn, world') = placeNode sizes whole env world building node in (env, building {buildNodes = drawn <> buildNodes building}, world')
        OpMacro at name -> case macro' env name of
          Just body -> case parsePicture 0 ("\\path " <> body <> ";") of
            Picture _ [ItemPath inner] -> operations sizes whole (pathOps inner) (env, building, world)
            _ -> (env, building, problem at ("\\" <> name <> " does not hold a path") world)
          Nothing -> (env, building, problem at ("\\" <> name <> " is not defined") world)
        OpExtra _ -> (env, building, world)
        OpAnimation _ -> (env, building, world)
        OpNodeAlso _ _ _ -> fails "node also is not carried out"
        OpParabola {} -> fails "parabola is not drawn"
        OpSin {} -> fails "sin is not drawn"
        OpCos {} -> fails "cos is not drawn"
        OpPlot {} -> fails "plot is not drawn"
        OpEdgeFromParent {} -> fails "trees are not drawn"
        OpChild {} -> fails "trees are not drawn"
        OpDecorate {} -> fails "decorations are not drawn"
        OpSvg {} -> fails "svg paths are not drawn"
        OpGraph {} -> fails "graphs are not drawn"
        OpLSystem {} -> fails "L-systems are not drawn"
  where
    roundOp shape ellipse =
      let read' text = (\v -> if mathUnits v then mathNumber v / pointsPerCm else scaleOf * mathNumber v) <$> number' env text
          Affine a _ _ _ _ _ = envTransform env
          scaleOf = abs a
          radii = case shape of
            RoundOld text -> case Text.splitOn " and " text of
              [x, y] -> (,) <$> read' x <*> read' y
              _ -> (\r -> (r, r)) <$> read' text
            RoundKeys options ->
              let (scoped, _) = optionsIn sizes whole (maybe [] (\(Options _ found) -> found) options) (env, world)
                  (rx, ry) = envRadius scoped
               in Just (rx * scaleOf, ry * scaleOf)
          _ = ellipse :: Bool
       in case radii of
            Nothing -> (env, building, problem (opSpan op) "cannot read this radius" world)
            Just (rx, ry) ->
              let centre@(cx, cy) = buildAt building
                  pieces = MoveTo (cx + rx, cy) : arcCurves centre rx ry 0 360 <> [ClosePath]
               in (env, (foldl' (flip push) building {buildFrom = Nothing} pieces) {buildAt = centre}, world)
    toOp options found to separate =
      let (scoped0, world0) = optionsIn sizes whole (concat [o | Options _ o <- options]) (env {envTo = ToSetup Nothing Nothing Nothing 1 False 30}, world)
          -- an edge is a path of its own: drawn, with the options every edge has
          scoped = if separate then (case Map.lookup "every edge" (envStyles scoped0) of
                      Just body -> fst (optionsIn sizes whole (let Options _ o = parseOptions 0 body in o) (scoped0 {envDraw = Just (fromMaybe (envColour scoped0) (envDraw scoped0))}, world0))
                      Nothing -> scoped0 {envDraw = Just (fromMaybe (envColour scoped0) (envDraw scoped0))}) else scoped0
          target = case to of
            TargetAt c -> case located env world0 (buildRel building) c of
              Nothing | toLoop (envTo scoped) -> Just (buildAt building, buildFrom building)
              found' -> found'
            TargetCycle _ -> Just (buildStart building, Nothing)
       in case target of
            Nothing -> (env, building, problem (opSpan op) "cannot place the end of this line" world0)
            Just found'@(centre, _) ->
              let setup = envTo scoped
                  straight = atan2 (snd centre - snd (buildAt building)) (fst centre - fst (buildAt building)) * 180 / pi
                  angles = case (toOut setup, toIn setup, toBend setup) of
                    (Just out, Just into, _) -> Just (out, into)
                    (_, _, Just bend) -> Just (straight + bend, straight + 180 - bend)
                    (Just out, Nothing, _) -> Just (out, straight + 180)
                    (Nothing, Just into, _) -> Just (straight, into)
                    _ -> Nothing
                  toward (x, y) degrees far = (x + far * cos (degrees * pi / 180), y + far * sin (degrees * pi / 180))
                  -- a separate edge leaves the main path where it is
                  origin = if separate then building {buildSegments = [], buildNodes = []} else building
                  (from, left, timer, piece) = case angles of
                    Nothing ->
                      let (start, b) = leave world0 centre origin
                          end = arrive world0 start found'
                       in (start, b, TimerLine start end, LineTo end)
                    Just (out, into) ->
                      let (start, b) = leave world0 (toward (buildAt origin) out 1000) origin
                          end = arrive world0 (toward centre into 1000) found'
                          distance = max (if toLoop setup then 0.5 else 0) (0.3915 * toLooseness setup * sqrt ((fst end - fst start) ^ (2 :: Int) + (snd end - snd start) ^ (2 :: Int)))
                          (c1, c2) = (toward start out distance, toward end into distance)
                       in (start, b, TimerCurve start c1 c2 end, CurveTo c1 c2 end)
                  moved = (push piece left) {buildLast = Just timer, buildMid = True}
                  (_, afterLabels0, world1) = foldl' (\s label -> operation sizes whole label s) (scoped, moved, world0) found
                  afterLabels = afterLabels0 {buildMid = False}
               in if separate
                    then
                      let stroke = (\colour -> Stroke colour (envLineWidth scoped) (envDash scoped)) <$> envDraw scoped
                          segments = case reverse (buildSegments afterLabels) of
                            list@(MoveTo _ : _) -> list
                            list -> MoveTo from : list
                          edge = DrawnPath whole segments stroke Nothing (envArrows scoped) (envOpacity scoped) (envLayer scoped)
                       in (env, building {buildNodes = buildNodes afterLabels <> [edge] <> buildNodes building}, world1)
                    else (env, afterLabels {buildAt = centre, buildFrom = snd found'}, world1)

-- Take a length off the start and off the end of a path of one piece.
shortened :: (Double, Double) -> [Segment] -> [Segment]
shortened (atStart, atEnd) segments
  | atStart == 0 && atEnd == 0 = segments
  | length [() | MoveTo _ <- segments] /= 1 || ClosePath `elem` segments = segments
  | otherwise = reverse (trimEnd (reverse (trimStart segments)))
  where
    pull (x1, y1) (x2, y2) distance =
      let len = sqrt ((x2 - x1) ^ (2 :: Int) + (y2 - y1) ^ (2 :: Int))
       in if len <= distance || len == 0 then (x1, y1) else (x1 + (x2 - x1) * distance / len, y1 + (y2 - y1) * distance / len)
    trimStart list = case list of
      MoveTo a : LineTo b : rest -> MoveTo (pull a b atStart) : LineTo b : rest
      MoveTo a : CurveTo c1 c2 b : rest -> MoveTo (pull a c1 atStart) : CurveTo c1 c2 b : rest
      other -> other
    -- newest first
    trimEnd list = case list of
      LineTo b : rest@(before : _) -> LineTo (pull b (endOf before) atEnd) : rest
      CurveTo c1 c2 b : rest -> CurveTo c1 c2 (pull b c2 atEnd) : rest
      other -> other
    endOf segment = case segment of
      MoveTo q -> q
      LineTo q -> q
      CurveTo _ _ q -> q
      ClosePath -> (0, 0)

-- An arc of an ellipse as cubic curves, each a quarter turn at most.
arcCurves :: Point -> Double -> Double -> Double -> Double -> [Segment]
arcCurves (cx, cy) rx ry startAngle endAngle =
  let total = endAngle - startAngle
      count = max 1 (ceiling (abs total / 90) :: Int)
      step = total / fromIntegral count
      piece index =
        let a0 = (startAngle + step * fromIntegral index) * pi / 180
            a1 = (startAngle + step * fromIntegral (index + 1)) * pi / 180
            k = 4 / 3 * tan ((a1 - a0) / 4)
            p0 = (cx + rx * cos a0, cy + ry * sin a0)
            p3 = (cx + rx * cos a1, cy + ry * sin a1)
            c1 = (fst p0 - k * rx * sin a0, snd p0 + k * ry * cos a0)
            c2 = (fst p3 + k * rx * sin a1, snd p3 - k * ry * cos a1)
         in CurveTo c1 c2 p3
   in fmap piece [0 .. count - 1]

-- Round the corners between straight pieces by a radius.
rounded :: Double -> [Segment] -> [Segment]
rounded radius segments
  | radius <= 0 = segments
  | otherwise = concatMap subpath (split segments)
  where
    split list = case list of
      [] -> []
      first : rest -> let (same, more) = break isMove rest in (first : same) : split more
    isMove s = case s of
      MoveTo _ -> True
      _ -> False
    subpath list =
      case list of
        MoveTo start : rest
          | all isLine rest, length rest >= 2 ->
              let closed = any (== ClosePath) rest
                  points = start : [p | LineTo p <- rest]
               in if closed then ring points else open points
        _ -> list
    isLine s = case s of
      LineTo _ -> True
      ClosePath -> True
      _ -> False
    toward (x1, y1) (x2, y2) distance =
      let len = sqrt ((x2 - x1) ^ (2 :: Int) + (y2 - y1) ^ (2 :: Int))
          k = if len == 0 then 0 else min 0.5 (distance / len)
       in (x1 + (x2 - x1) * k, y1 + (y2 - y1) * k)
    corner before at after = [LineTo (toward at before radius), CurveTo (mix (toward at before radius) at) (mix (toward at after radius) at) (toward at after radius)]
    mix (x1, y1) (x2, y2) = (x1 + (x2 - x1) * 0.55, y1 + (y2 - y1) * 0.55)
    open points =
      case points of
        first : _ -> MoveTo first : concat [corner a b c | (a, b, c) <- zip3 points (drop 1 points) (drop 2 points)] <> [LineTo (lastOf first points)]
        [] -> []
    ring points =
      case points of
        first : second : _ ->
          let cyclic = points <> [first, second]
              start = toward first second radius
           in MoveTo start : concat [corner a b c | (a, b, c) <- zip3 cyclic (drop 1 cyclic) (drop 2 cyclic)] <> [ClosePath]
        _ -> fmap LineTo points
    lastOf fallback list = case reverse list of
      final : _ -> final
      [] -> fallback

-- @\\p1 = (a), \\n1 = {expr}@: points give \\p, \\x and \\y, numbers give \\n.
letBindings :: Env -> World -> Point -> Text -> Maybe [(Text, Text)]
letBindings env world current assignments = go env [] (fmap Text.strip (splitTop ',' assignments))
  where
    go _ found [] = Just found
    go scope found (one : rest) = do
      let (name, value) = Text.breakOn "=" one
          register = Text.filter (not . isSpace) (Text.dropWhile (== '\\') (Text.strip name))
          written = Text.strip (Text.drop 1 value)
      new <- case Text.uncons register of
        Just ('p', index) -> do
          coordinate <- either (const Nothing) Just (parseCoordinate 0 written)
          ((x, y), _) <- located scope world current coordinate
          let pointsOf v = Text.pack (showNumber (v * pointsPerCm)) <> "pt"
              suffix = unbraced index
          Just [("p" <> suffix, pointsOf x <> "," <> pointsOf y), ("x" <> suffix, pointsOf x), ("y" <> suffix, pointsOf y)]
        Just ('n', index) -> do
          result <- number' scope (unbraced written)
          Just [("n" <> unbraced index, Text.pack (showNumber (mathNumber result)) <> (if mathUnits result then "pt" else ""))]
        _ -> Nothing
      go (bind new scope) (found <> new) rest
    unbraced t = fromMaybe t (Text.stripPrefix "{" (Text.strip t) >>= Text.stripSuffix "}")

-- Nodes ---------------------------------------------------------------------

-- The cells of a matrix, row by row: where each starts in the source, and its text.
matrixCells :: Int -> Text -> [[(Int, Text)]]
matrixCells base text = filter (any (not . Text.null . Text.strip . snd)) (rows (go 0 (0 :: Int) 0 "" (Text.unpack text)))
  where
    rows found = case break (\(_, _, endsRow) -> endsRow) found of
      (cells, final : rest) -> fmap cell (cells <> [final]) : rows rest
      ([], []) -> []
      (cells, []) -> [fmap cell cells]
    cell (start, written, _) = (base + start, written)
    go index depth start seen chars =
      case chars of
        [] -> [(start, Text.pack (reverse seen), True)]
        '\\' : '\\' : rest | depth == 0 -> (start, Text.pack (reverse seen), True) : go (index + 2) 0 (index + 2) "" rest
        '\\' : c : rest -> go (index + 2) depth start (c : '\\' : seen) rest
        '&' : rest | depth == 0 -> (start, Text.pack (reverse seen), False) : go (index + 1) 0 (index + 1) "" rest
        c : rest -> go (index + 1) (if c == '{' then depth + 1 else if c == '}' then depth - 1 else depth) start (c : seen) rest

-- The box around what was drawn: left, right, bottom, top.
extentOf :: [Drawn] -> (Double, Double, Double, Double)
extentOf drawn =
  let points = concat [segmentPoints s | DrawnPath {drawnSegments = segments} <- drawn, s <- segments] <> concat [[(x - w / 2, y - h / 2), (x + w / 2, y + h / 2)] | DrawnNode {drawnBox = NodeBox (x, y) w h _ _} <- drawn]
      segmentPoints segment = case segment of
        MoveTo q -> [q]
        LineTo q -> [q]
        CurveTo a b c -> [a, b, c]
        ClosePath -> []
   in case points of
        [] -> (0, 0, 0, 0)
        _ -> (minimum (fmap fst points), maximum (fmap fst points), minimum (fmap snd points), maximum (fmap snd points))

-- A point along the last part of a path, and the direction of travel there.
alongTimer :: Timer -> Double -> (Point, Point)
alongTimer timer t =
  case timer of
    TimerLine a b -> (mix a b t, minus b a)
    TimerCorner a c b
      | t < 0.5 -> (mix a c (2 * t), minus c a)
      | otherwise -> (mix c b (2 * t - 1), minus b c)
    TimerCurve a c1 c2 b ->
      let u = 1 - t
          at pa pc1 pc2 pb = u * u * u * pa + 3 * u * u * t * pc1 + 3 * u * t * t * pc2 + t * t * t * pb
          slope pa pc1 pc2 pb = 3 * u * u * (pc1 - pa) + 6 * u * t * (pc2 - pc1) + 3 * t * t * (pb - pc2)
       in ((at (fst a) (fst c1) (fst c2) (fst b), at (snd a) (snd c1) (snd c2) (snd b)), (slope (fst a) (fst c1) (fst c2) (fst b), slope (snd a) (snd c1) (snd c2) (snd b)))
  where
    mix (x1, y1) (x2, y2) k = (x1 + (x2 - x1) * k, y1 + (y2 - y1) * k)
    minus (x1, y1) (x2, y2) = (x1 - x2, y1 - y2)

estimate :: TextStyle -> Text -> (Double, Double)
estimate style text =
  let size = textSize style / pointsPerCm
      rows = fmap (Text.filter (\c -> not (c `elem` ("{}$\\" :: String)))) (Text.splitOn "\\\\" text)
      widest = maximum (0 : fmap (fromIntegral . Text.length . Text.strip) rows) * size * 0.47
      (width, lineCount) = case textWidth style of
        Just limit | limit > 0 -> (limit, max (length rows) (ceiling (widest / limit) :: Int))
        _ -> (widest, length rows)
   in if Text.null (Text.strip text) then (0, 0) else (width, fromIntegral (max 1 lineCount) * size * 1.2)

placeNode :: Sizes -> Span -> Env -> World -> Building -> Node -> ([Drawn], World)
placeNode sizes whole env world building node =
  case nodeForeach node of
    loop : more -> case foreachValues env loop of
      Left reason -> ([], problem (nodeSpan node) reason world)
      Right rounds -> foldl' (\(drawn, w) bindings -> let (new, w') = placeNode sizes whole (bind bindings env) w building node {nodeForeach = more} in (new <> drawn, w')) ([], world) rounds
    [] ->
      let base = env {envNode = defaultNode, envOnNode = True, envDraw = Nothing, envFill = Nothing, envArrows = (Nothing, Nothing), envRounded = 0}
          every = case Map.lookup "every node" (envStyles env) of
            Just body | nodeKind node == KindNode -> let Options _ found = parseOptions 0 body in found
            _ -> []
          (scoped, world1) = optionsIn sizes (nodeSpan node) (every <> nodeOptions node) (base, world)
          setup0 = envNode scoped
          setup = setup0 {setupMinimum = (fst (setupMinimum setup0) * grow, snd (setupMinimum setup0) * grow), setupTextWidth = fmap (* grow) (setupTextWidth setup0)}
          shape = if nodeKind node == KindCoordinate then ShapeCoordinate else setupShape setup
          written = maybe "" (\(Braced _ text) -> expandIn scoped text) (nodeText node)
          style = TextStyle (fromMaybe (envColour scoped) (envText scoped)) (envFontSize scoped * grow) (envBold scoped) (envItalic scoped) (envMono scoped) (setupTextWidth setup) (setupAlign setup)
          key = textKey style written
          cells = if envMatrix scoped then matrixCells (maybe 0 (\(Braced (Span a _) _) -> a + 1) (nodeText node)) (maybe "" (\(Braced _ text) -> text) (nodeText node)) else []
          cellEnv = env {envMatrix = False}
          -- each cell on its own, at the origin, to see how big it is
          extents = fmap (fmap (\(offset, text) -> extentOf (worldDrawn (statements sizes cellEnv {envTransform = identity} world {worldDrawn = []} (parsePicture offset text))))) cells
          columns = maximum (0 : fmap length extents)
          column j = [e | row <- extents, e : _ <- [drop j row]]
          lefts = [maximum (0 : [negate x1 | (x1, _, _, _) <- column j]) | j <- [0 .. columns - 1]]
          rights = [maximum (0 : [x2 | (_, x2, _, _) <- column j]) | j <- [0 .. columns - 1]]
          ups = [maximum (0 : [y2 | (_, _, _, y2) <- row]) | row <- extents]
          downs = [maximum (0 : [negate y1 | (_, _, y1, _) <- row]) | row <- extents]
          (columnSep, rowSep) = envSeps scoped
          columnAt j = sum (take j lefts) + sum (take j rights) + fromIntegral j * columnSep + sum (take 1 (drop j lefts))
          rowAt i = sum (take i ups) + sum (take i downs) + fromIntegral i * rowSep + sum (take 1 (drop i ups))
          matrixSize = (sum lefts + sum rights + fromIntegral (max 0 (columns - 1)) * columnSep, sum ups + sum downs + fromIntegral (max 0 (length extents - 1)) * rowSep)
          (textW, textH)
            | envMatrix scoped = matrixSize
            | otherwise = fromMaybe (estimate style written) (Map.lookup key sizes)
          grow = if envShape scoped then (let Affine a b _ _ _ _ = envTransform env in sqrt (a * a + b * b)) else 1
          (innerX, innerY) = (fst (setupInner setup0) * grow, snd (setupInner setup0) * grow)
          contentW = fromMaybe textW (setupTextWidth setup) + 2 * innerX
          contentH = textH + 2 * innerY
          (minW, minH) = setupMinimum setup
          (width, height) = case shape of
            ShapeCoordinate -> (0, 0)
            ShapeCircle -> let d = max (sqrt (contentW * contentW + contentH * contentH)) (max minW minH) in (d, d)
            ShapeEllipse -> (max (contentW * sqrt 2) minW, max (contentH * sqrt 2) minH)
            ShapeDiamond -> let s = contentW + contentH in (max s minW, max s minH)
            ShapeRectangle -> (max contentW minW, max contentH minH)
          name = fmap (expandIn scoped) (nodeName node)
          -- a node that fits others is as big as what it fits, wherever the path is
          fitted = setupFit setup >>= fitBox scoped world1 (innerX, innerY)
          explicit = nodeAt node >>= \c -> fst <$> located env world1 (buildRel building) c
          onPath = case (explicit, buildLast building, setupPos setup, nodeKind node) of
            (Nothing, Just timer, position, _) | position /= Nothing || buildMid building -> Just (alongTimer timer (fromMaybe 0.5 position))
            _ -> Nothing
          reference = fromMaybe (maybe (buildAt building) fst onPath) explicit
          gap = 0.06
          sideVector side = case side of
            "above" -> (0, 1)
            "below" -> (0, -1)
            "left" -> (-1, 0)
            "right" -> (1, 0)
            "above left" -> (-1, 1)
            "above right" -> (1, 1)
            "below left" -> (-1, -1)
            _ -> (1, -1)
          centre0 = case setupPlace setup of
            -- beside another node (the positioning library): border to border, the distance apart
            Just (side, distance, Just target)
              | Just other <- Map.lookup (Text.strip target) (worldNodes world1) ->
                  let (sx, sy) = sideVector side
                      d = fromMaybe (envNodeDistance scoped) distance
                      (ox, oy) = boxCentre other
                   in (ox + sx * (boxWidth other / 2 + d + width / 2), oy + sy * (boxHeight other / 2 + d + height / 2))
            Just (side, distance, _) ->
              let (sx, sy) = sideVector side
                  d = fromMaybe 0 distance
               in (fst reference + sx * (width / 2 + d + gap * abs sx), snd reference + sy * (height / 2 + d + gap * abs sy))
            Nothing -> case (setupAuto setup, onPath) of
              (Just right, Just (_, (tx, ty))) ->
                let len = sqrt (tx * tx + ty * ty)
                    (nx, ny) = if len == 0 then (0, 1) else (negate ty / len, tx / len)
                    (sx, sy) = if right then (negate nx, negate ny) else (nx, ny)
                    reach = abs sx * width / 2 + abs sy * height / 2 + gap
                 in (fst reference + sx * reach, snd reference + sy * reach)
              _ -> case setupAnchor setup of
                Just anchor | Just (ax, ay) <- anchorOf (NodeBox (0, 0) width height shape 0) anchor -> (fst reference - ax, snd reference - ay)
                _ -> reference
          (shiftX, shiftY) = setupShift setup
          slope = case (setupSloped setup, onPath) of
            (True, Just (_, (tx, ty))) -> let a = atan2 ty tx * 180 / pi in if a > 90 then a - 180 else if a < -90 then a + 180 else a
            _ -> 0
          box = case fitted of
            Just found -> found
            Nothing -> NodeBox (fst centre0 + shiftX, snd centre0 + shiftY) width height shape (setupRotate setup + slope)
          stroke = if setupDrawn setup then (\colour -> Stroke colour (envLineWidth scoped) (envDash scoped)) <$> envDraw scoped else Nothing
          fill = if setupFilled setup then envFill scoped else Nothing
          drawn = DrawnNode whole node name box stroke fill (envRounded scoped * grow) (envShadow scoped) written style (envOpacity scoped) (envLayer scoped)
          world2 = world1 {worldNodes = maybe id (\found -> Map.insert found box) name (worldNodes world1), worldTexts = [(key, written, style) | not (Text.null (Text.strip written))] <> worldTexts world1}
          labels = concat [labelOf scoped box text | text <- setupLabels setup]
          visible = shape /= ShapeCoordinate
          -- a matrix: its box first, then every cell drawn where its column and row put it
          (left, top) = (fst (boxCentre box) - fst matrixSize / 2, snd (boxCentre box) + snd matrixSize / 2)
          filled = foldl' (\w (i, row) -> foldl' (\w' (j, (offset, text)) -> statements sizes cellEnv {envTransform = Affine 1 0 0 1 (left + columnAt j) (top - rowAt i)} w' (parsePicture offset text)) w (zip [0 ..] row)) world2 {worldDrawn = drawn {drawnText = ""} : worldDrawn world2} (zip [0 :: Int ..] cells)
       in if envMatrix scoped then ([], filled) else (labels <> [drawn | visible], world2 {worldTexts = [(textKey s t, t, s) | DrawnNode {drawnText = t, drawnTextStyle = s} <- labels] <> worldTexts world2})
  where
    -- label=above:text, label={[options]30:text}
    labelOf scoped box text =
      let trimmed = Text.strip text
          (options, afterOptions) = case Text.stripPrefix "[" trimmed of
            Just inner -> let (inside, rest) = Text.breakOn "]" inner in (inside, Text.drop 1 rest)
            Nothing -> ("", trimmed)
          (direction, content) = case Text.breakOn ":" afterOptions of
            (before, after) | not (Text.null after), not (Text.any (== '$') before) -> (Text.strip before, Text.drop 1 after)
            _ -> ("above", afterOptions)
          angle = fromMaybe 90 (lookup direction [("above", 90), ("below", 270), ("left", 180), ("right", 0), ("above left", 135), ("above right", 45), ("below left", 225), ("below right", 315), ("north", 90), ("south", 270), ("east", 0), ("west", 180)] `orElse` (either (const Nothing) (Just . mathNumber) (mathIn scoped direction)))
          (labelEnv, _) = optionsIn sizes whole (let Options _ found = parseOptions 0 options in found) (scoped {envNode = defaultNode, envDraw = Nothing, envFill = Nothing, envOnNode = True}, world)
          style = TextStyle (fromMaybe (envColour labelEnv) (envText labelEnv)) (envFontSize labelEnv) (envBold labelEnv) (envItalic labelEnv) (envMono labelEnv) Nothing "center"
          written = expandIn scoped content
          (textW, textH) = fromMaybe (estimate style written) (Map.lookup (textKey style written) sizes)
          (innerX, innerY) = setupInner (envNode labelEnv)
          (w, h) = (textW + 2 * innerX, textH + 2 * innerY)
          (cx, cy) = boxCentre box
          rad = angle * pi / 180
          (bx, by) = borderToward box (cx + 1000 * cos rad, cy + 1000 * sin rad)
          reach = abs (cos rad) * w / 2 + abs (sin rad) * h / 2
          centre = (bx + cos rad * reach, by + sin rad * reach)
       in [DrawnNode whole node Nothing (NodeBox centre w h ShapeRectangle 0) Nothing Nothing 0 Nothing written style (envOpacity labelEnv) (envLayer labelEnv)]
    orElse a b = maybe b Just a
    -- fit=(a)(b)(c): the box around those nodes and points, with the inner sep around it
    fitBox scoped world' (innerX, innerY) text =
      let names = filter (not . Text.null) (fmap (Text.strip . Text.takeWhile (/= ')')) (drop 1 (Text.splitOn "(" (expandIn scoped text))))
          boxes = concatMap (\found -> case Map.lookup found (worldNodes world') of
            Just b -> let (cx, cy) = boxCentre b in [(cx - boxWidth b / 2, cy - boxHeight b / 2), (cx + boxWidth b / 2, cy + boxHeight b / 2)]
            Nothing -> case parseCoordinate 0 ("(" <> found <> ")") >>= maybe (Left "") Right . located scoped world' (0, 0) of
              Right (p, _) -> [p]
              Left _ -> []) names
       in case boxes of
            [] -> Nothing
            _ ->
              let xs = fmap fst boxes
                  ys = fmap snd boxes
                  (x1, x2, y1, y2) = (minimum xs - innerX, maximum xs + innerX, minimum ys - innerY, maximum ys + innerY)
               in Just (NodeBox ((x1 + x2) / 2, (y1 + y2) / 2) (x2 - x1) (y2 - y1) ShapeRectangle 0)
