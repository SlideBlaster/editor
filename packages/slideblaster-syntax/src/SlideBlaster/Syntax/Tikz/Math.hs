{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Tikz.Math
-- Description : The mathematical expressions of TikZ (pgfmath).
--
-- An expression is a number, with or without a unit, built with the
-- operators and functions the pgfmath engine has. As there, a result
-- remembers whether a unit was written anywhere in it: TikZ reads @(1,2)@ in
-- the picture's coordinate system and @(1cm,2pt)@ as lengths, by exactly that
-- flag. A value with a unit is in TeX points.
--
-- Macros are expanded as TeX expands them, as text, before the expression is
-- read; the caller supplies their definitions.
module SlideBlaster.Syntax.Tikz.Math
  ( MathValue (..)
  , evalMath
  , expandMacros
  , pointsPer
  , pointsPerCm
  ) where

import Data.Char (isAlpha, isDigit, isSpace)
import Data.Fixed (mod')
import Data.Text (Text)
import Data.Text qualified as Text

-- | A result: the number (in points when a unit was written) and whether one was.
data MathValue = MathValue
  { mathNumber :: !Double
  , mathUnits :: !Bool
  }
  deriving stock (Eq, Show)

pointsPerCm :: Double
pointsPerCm = 28.45274

-- | TeX points in one of a unit; em and ex are those of a ten point font.
pointsPer :: Text -> Maybe Double
pointsPer unit =
  case unit of
    "pt" -> Just 1
    "cm" -> Just pointsPerCm
    "mm" -> Just (pointsPerCm / 10)
    "in" -> Just 72.27
    "bp" -> Just (72.27 / 72)
    "pc" -> Just 12
    "sp" -> Just (1 / 65536)
    "dd" -> Just (1238 / 1157)
    "cc" -> Just (12 * 1238 / 1157)
    "em" -> Just 10
    "ex" -> Just 4.30554
    _ -> Nothing

-- | Replace every macro by its definition, again and again, as TeX would
-- (at most a fixed number of rounds, so a macro that names itself ends). A
-- macro right after a number multiplies it (@0.5\\w@), as a TeX length does.
-- A macro nobody defined is left standing.
expandMacros :: (Text -> Maybe Text) -> Text -> Text
expandMacros definition = go (24 :: Int)
  where
    go rounds text
      | rounds == 0 || not (Text.any (== '\\') text) = text
      | otherwise = let next = pass text in if next == text then text else go (rounds - 1) next
    pass text =
      case Text.breakOn "\\" text of
        (before, rest)
          | Text.null rest -> before
          | otherwise ->
              let name = Text.takeWhile (\c -> isAlpha c || c == '@') (Text.drop 1 rest)
                  after = Text.drop (1 + Text.length name) rest
                  -- a macro whose name ends in a letter swallows the spaces after it
                  after' = if Text.null name then after else Text.dropWhile (== ' ') after
               in case if Text.null name then Nothing else definition name of
                    Nothing -> before <> Text.take (1 + max 1 (Text.length name)) rest <> pass (Text.drop (1 + max 1 (Text.length name)) rest)
                    Just body
                      | Just (_, c) <- Text.unsnoc (Text.stripEnd before), isDigit c || c == '.' -> before <> "*(" <> body <> ")" <> pass after'
                      | otherwise -> before <> body <> pass after'

-- | Evaluate an expression. Macros are expanded first with the given definitions.
evalMath :: (Text -> Maybe Text) -> Text -> Either Text MathValue
evalMath definition source =
  let text = Text.unpack (expandMacros definition source)
   in case ternary (skip text) of
        Right (value, rest) | all isSpace rest -> Right value
        Right (_, rest) -> Left ("cannot read " <> Text.pack (take 12 rest) <> " in the expression " <> Text.strip source)
        Left problem -> Left (problem <> " in the expression " <> Text.strip source)

type Reader a = String -> Either Text (a, String)

skip :: String -> String
skip = dropWhile isSpace

plain :: Double -> MathValue
plain number = MathValue number False

truth :: Bool -> MathValue
truth yes = plain (if yes then 1 else 0)

-- Two values under an operator: a unit on either side stays.
lift2 :: (Double -> Double -> Double) -> MathValue -> MathValue -> MathValue
lift2 f (MathValue a ua) (MathValue b ub) = MathValue (f a b) (ua || ub)

ternary :: Reader MathValue
ternary input = do
  (condition, rest) <- disjunction input
  case skip rest of
    '?' : more -> do
      (yes, afterYes) <- ternary (skip more)
      case skip afterYes of
        ':' : afterColon -> do
          (no, final) <- ternary (skip afterColon)
          Right (if mathNumber condition /= 0 then yes else no, final)
        _ -> Left "a ? needs its :"
    _ -> Right (condition, rest)

-- Left-associative operators of one level.
chain :: Reader MathValue -> [(String, MathValue -> MathValue -> MathValue)] -> Reader MathValue
chain operand operators input = operand input >>= uncurry more
  where
    more left rest =
      let trimmed = skip rest
       in case [(apply, drop (length symbol) trimmed) | (symbol, apply) <- operators, symbol `prefixes` trimmed] of
            (apply, after) : _ -> do
              (right, final) <- operand (skip after)
              more (apply left right) final
            [] -> Right (left, rest)
    prefixes symbol text = take (length symbol) text == symbol

disjunction :: Reader MathValue
disjunction = chain conjunction [("||", \a b -> truth (mathNumber a /= 0 || mathNumber b /= 0))]

conjunction :: Reader MathValue
conjunction = chain comparison [("&&", \a b -> truth (mathNumber a /= 0 && mathNumber b /= 0))]

comparison :: Reader MathValue
comparison =
  chain
    sums
    [ ("==", compared (==))
    , ("!=", compared (/=))
    , ("<=", compared (<=))
    , (">=", compared (>=))
    , ("<", compared (<))
    , (">", compared (>))
    ]
  where
    compared test a b = truth (test (mathNumber a) (mathNumber b))

sums :: Reader MathValue
sums = chain products [("+", lift2 (+)), ("-", lift2 (-))]

products :: Reader MathValue
products = chain powers [("*", lift2 (*)), ("/", divide)]
  where
    -- a length divided by a length is a plain number
    divide (MathValue a ua) (MathValue b ub) = MathValue (if b == 0 then 0 else a / b) (ua && not ub)

powers :: Reader MathValue
powers input = do
  (base, rest) <- unary input
  case skip rest of
    '^' : more -> do
      (exponent', final) <- powers (skip more)
      Right (MathValue (mathNumber base ** mathNumber exponent') (mathUnits base), final)
    _ -> Right (base, rest)

-- As in pgfmath, a sign in front binds tighter than a power: -2^2 is 4.
unary :: Reader MathValue
unary input =
  case input of
    '-' : rest -> do
      (value, final) <- unary (skip rest)
      Right (value {mathNumber = negate (mathNumber value)}, final)
    '+' : rest -> unary (skip rest)
    '!' : rest -> do
      (value, final) <- unary (skip rest)
      Right (truth (mathNumber value == 0), final)
    _ -> postfix input

postfix :: Reader MathValue
postfix input = primary input >>= uncurry after
  where
    after value rest =
      case rest of
        '!' : more | take 1 more /= "=" -> after (plain (factorial (mathNumber value))) more
        -- r: the number is in radians
        'r' : more | not (startsName more) -> after (plain (mathNumber value * 180 / pi)) more
        -- also with a space before it: sin(\\x r)
        ' ' : _ | 'r' : more <- skip rest, not (startsName more) -> after (plain (mathNumber value * 180 / pi)) more
        _ -> Right (value, rest)
    startsName text = case text of
      c : _ -> isAlpha c
      [] -> False
    factorial n = product [1 .. fromIntegral (max 0 (round n :: Integer))]

primary :: Reader MathValue
primary input =
  case input of
    '(' : rest -> do
      (value, afterValue) <- ternary (skip rest)
      case skip afterValue of
        ')' : final -> Right (value, final)
        _ -> Left "a ( is never closed"
    '{' : rest -> do
      -- braces group; a list in braces is an array to index
      (values, afterValues) <- arguments '}' rest
      case (values, afterValues) of
        (_, '[' : more) -> do
          (index, afterIndex) <- ternary (skip more)
          case skip afterIndex of
            ']' : final -> case drop (round (mathNumber index)) values of
              found : _ -> Right (found, final)
              [] -> Left "an array is indexed past its end"
            _ -> Left "a [ is never closed"
        ([single], _) -> Right (single, afterValues)
        _ -> Left "a list in braces needs an index"
    '"' : rest -> Right (plain 0, drop 1 (dropWhile (/= '"') rest))
    c : _
      | isDigit c || c == '.' -> number input
      | isAlpha c ->
          let (name, rest) = span (\x -> isAlpha x || isDigit x || x == '_') input
           in case skip rest of
                '(' : more -> do
                  (values, final) <- arguments ')' more
                  (\value -> (value, final)) <$> function name values
                _ -> (\value -> (value, rest)) <$> function name []
    _ -> Left ("cannot read " <> Text.pack (take 12 input))

-- Comma separated expressions up to a closing character.
arguments :: Char -> Reader [MathValue]
arguments close input =
  case skip input of
    c : rest | c == close -> Right ([], rest)
    trimmed -> do
      (value, afterValue) <- ternary trimmed
      case skip afterValue of
        ',' : more -> do
          (values, final) <- arguments close more
          Right (value : values, final)
        c : final | c == close -> Right ([value], final)
        _ -> Left ("a list is never closed by " <> Text.singleton close)

number :: Reader MathValue
number input =
  let (whole, afterWhole) = span isDigit input
      (fraction, afterFraction) = case afterWhole of
        '.' : more -> let (digits, rest) = span isDigit more in ("." <> (if null digits then "0" else digits), rest)
        _ -> ("", afterWhole)
      (power, afterPower) = case afterFraction of
        e : more
          | e `elem` ("eE" :: String)
          , (sign, digits) <- span (`elem` ("+-" :: String)) more
          , length sign <= 1
          , (found@(_ : _), rest) <- span isDigit digits ->
              ("e" <> filter (== '-') sign <> found, rest)
        _ -> ("", afterFraction)
      value = read ((if null whole then "0" else whole) <> (if null fraction then "" else fraction) <> power) :: Double
      (letters, afterLetters) = span isAlpha (skip afterPower)
   in if null whole && null fraction
        then Left ("cannot read " <> Text.pack (take 12 input))
        else case pointsPer (Text.pack (take 2 letters)) of
          Just factor | length letters >= 2 -> Right (MathValue (value * factor) True, drop 2 letters <> afterLetters)
          _ -> Right (plain value, afterPower)

function :: String -> [MathValue] -> Either Text MathValue
function name values =
  case (name, fmap mathNumber values) of
    ("pi", []) -> Right (plain pi)
    ("e", []) -> Right (plain (exp 1))
    ("true", []) -> Right (plain 1)
    ("false", []) -> Right (plain 0)
    -- one fixed value: a picture must not change each time it is read
    ("rnd", []) -> Right (plain 0.5)
    ("rand", []) -> Right (plain 0)
    ("random", []) -> Right (plain 0.5)
    ("random", [a]) -> Right (plain (fromIntegral (ceiling (a / 2) :: Integer)))
    ("random", [a, b]) -> Right (plain (fromIntegral (round ((a + b) / 2) :: Integer)))
    ("sin", [a]) -> Right (plain (sin (radians a)))
    ("cos", [a]) -> Right (plain (cos (radians a)))
    ("tan", [a]) -> Right (plain (tan (radians a)))
    ("sec", [a]) -> Right (plain (1 / cos (radians a)))
    ("cosec", [a]) -> Right (plain (1 / sin (radians a)))
    ("cot", [a]) -> Right (plain (1 / tan (radians a)))
    ("asin", [a]) -> Right (plain (degrees (asin a)))
    ("acos", [a]) -> Right (plain (degrees (acos a)))
    ("atan", [a]) -> Right (plain (degrees (atan a)))
    ("atan2", [y, x]) -> Right (plain (degrees (atan2 y x)))
    ("sinh", [a]) -> Right (plain (sinh a))
    ("cosh", [a]) -> Right (plain (cosh a))
    ("tanh", [a]) -> Right (plain (tanh a))
    ("deg", [a]) -> Right (plain (degrees a))
    ("rad", [a]) -> Right (plain (radians a))
    ("exp", [a]) -> Right (plain (exp a))
    ("ln", [a]) -> Right (plain (log a))
    ("log10", [a]) -> Right (plain (logBase 10 a))
    ("log2", [a]) -> Right (plain (logBase 2 a))
    ("sqrt", [_]) -> same sqrt
    ("abs", [_]) -> same abs
    ("neg", [_]) -> same negate
    ("round", [_]) -> same (fromIntegral . (round' :: Double -> Integer))
    ("floor", [_]) -> same (fromIntegral . (floor :: Double -> Integer))
    ("ceil", [_]) -> same (fromIntegral . (ceiling :: Double -> Integer))
    ("int", [_]) -> same (fromIntegral . (truncate :: Double -> Integer))
    ("frac", [a]) -> Right (plain (a - fromIntegral (truncate a :: Integer)))
    ("real", [_]) -> same id
    ("scalar", [a]) -> Right (plain a)
    ("sign", [a]) -> Right (plain (signum a))
    ("pow", [a, b]) -> Right (plain (a ** b))
    ("veclen", [x, y]) -> Right (MathValue (sqrt (x * x + y * y)) units)
    ("add", [a, b]) -> Right (MathValue (a + b) units)
    ("subtract", [a, b]) -> Right (MathValue (a - b) units)
    ("multiply", [a, b]) -> Right (MathValue (a * b) units)
    ("divide", [a, b]) -> Right (MathValue (if b == 0 then 0 else a / b) units)
    ("div", [a, b]) -> Right (plain (if b == 0 then 0 else fromIntegral (truncate (a / b) :: Integer)))
    ("mod", [a, b]) -> Right (MathValue (if b == 0 then 0 else a - b * fromIntegral (truncate (a / b) :: Integer)) units)
    ("Mod", [a, b]) -> Right (MathValue (if b == 0 then 0 else a `mod'` b) units)
    ("min", _ : _) -> Right (MathValue (minimum (fmap mathNumber values)) units)
    ("max", _ : _) -> Right (MathValue (maximum (fmap mathNumber values)) units)
    ("equal", [a, b]) -> Right (truth (a == b))
    ("notequal", [a, b]) -> Right (truth (a /= b))
    ("greater", [a, b]) -> Right (truth (a > b))
    ("less", [a, b]) -> Right (truth (a < b))
    ("notgreater", [a, b]) -> Right (truth (a <= b))
    ("notless", [a, b]) -> Right (truth (a >= b))
    ("and", [a, b]) -> Right (truth (a /= 0 && b /= 0))
    ("or", [a, b]) -> Right (truth (a /= 0 || b /= 0))
    ("not", [a]) -> Right (truth (a == 0))
    ("ifthenelse", [c, a, b]) -> Right (MathValue (if c /= 0 then a else b) units)
    ("iseven", [a]) -> Right (truth (even (round a :: Integer)))
    ("isodd", [a]) -> Right (truth (odd (round a :: Integer)))
    ("factorial", [a]) -> Right (plain (product [1 .. fromIntegral (max 0 (round a :: Integer))]))
    _ -> Left ("the function " <> Text.pack name <> " with " <> Text.pack (show (length values)) <> " arguments is not known")
  where
    units = any mathUnits values
    radians a = a * pi / 180
    degrees a = a * 180 / pi
    -- halves round away from zero, as TeX rounds
    round' a = if a < 0 then negate (floor (negate a + 0.5)) else floor (a + 0.5)
    same f = case values of
      [MathValue a u] -> Right (MathValue (f a) u)
      _ -> Left "one argument expected"
