{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Picture
-- Description : Statement reader for the @```slide@ picture tier.
--
-- The picture block is the TikZ superset of the format: absolutely placed
-- @\\node[options] (id) at (x,y) {content};@ statements. This module splits the
-- block body into statements and recognises the supported node form. Everything
-- else (@\\draw@, relative placement, anything unparsed) is an 'OpaqueStatement'
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
  ) where

import Data.Char (isDigit, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text

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
  | -- | Anything else, retained exactly.
    OpaqueStatement !Text
  deriving stock (Eq, Show)

-- | The exact text of a statement.
statementText :: Statement -> Text
statementText statement =
  case statement of
    NodeStatement {statementRaw = raw} -> raw
    OpaqueStatement raw -> raw

-- | Split a block body into statements. Total.
readPicture :: Text -> [Statement]
readPicture body = fmap classify (splitStatements body)

-- | Concatenate statement texts; the exact inverse of 'readPicture'.
printPicture :: [Statement] -> Text
printPicture = foldMap statementText

-- | Split after each top-level semicolon (outside braces, brackets and
-- comments). A final fragment without a semicolon is kept as its own piece, so
-- trailing whitespace and comments are retained.
splitStatements :: Text -> [Text]
splitStatements = go Text.empty (0 :: Int) (0 :: Int)
  where
    go acc _ _ remaining
      | Text.null remaining = [acc | not (Text.null acc)]
    go acc braces brackets remaining =
      case Text.uncons remaining of
        Nothing -> [acc | not (Text.null acc)]
        Just (c, rest)
          | c == '%' ->
              let (comment, afterComment) = Text.break (== '\n') remaining
               in go (acc <> comment) braces brackets afterComment
          | c == '\\' ->
              case Text.uncons rest of
                Just (escaped, rest') -> go (acc <> Text.pack [c, escaped]) braces brackets rest'
                Nothing -> go (Text.snoc acc c) braces brackets rest
          | c == '{' -> go (Text.snoc acc c) (braces + 1) brackets rest
          | c == '}' -> go (Text.snoc acc c) (max 0 (braces - 1)) brackets rest
          | c == '[' -> go (Text.snoc acc c) braces (brackets + 1) rest
          | c == ']' -> go (Text.snoc acc c) braces (max 0 (brackets - 1)) rest
          | c == ';' && braces == 0 && brackets == 0 -> (acc <> ";") : go Text.empty 0 0 rest
          | otherwise -> go (Text.snoc acc c) braces brackets rest

classify :: Text -> Statement
classify raw =
  case parseNode raw of
    Just statement -> statement
    Nothing -> OpaqueStatement raw

parseNode :: Text -> Maybe Statement
parseNode raw = do
  afterCommand <- Text.stripPrefix "\\node" (Text.stripStart raw)
  let (options, afterOptions) = optionalBracket (Text.stripStart afterCommand)
  let (name, afterName) = optionalParen (Text.stripStart afterOptions)
  afterAt <- Text.stripPrefix "at" (Text.stripStart afterName)
  (xText, yText, afterPoint) <- point (Text.stripStart afterAt)
  x <- decimal xText
  y <- decimal yText
  (content, afterContent) <- braced (Text.stripStart afterPoint)
  if Text.strip afterContent == ";"
    then Just (NodeStatement options name x y content raw)
    else Nothing

optionalBracket :: Text -> (Text, Text)
optionalBracket text =
  case Text.uncons text of
    Just ('[', rest) ->
      case balanced '[' ']' rest of
        Just (inside, after) -> (inside, after)
        Nothing -> (Text.empty, text)
    _ -> (Text.empty, text)

optionalParen :: Text -> (Maybe Text, Text)
optionalParen text =
  case Text.uncons text of
    Just ('(', rest) ->
      let (inside, after) = Text.break (== ')') rest
       in if Text.null after then (Nothing, text) else (Just (Text.strip inside), Text.drop 1 after)
    _ -> (Nothing, text)

point :: Text -> Maybe (Text, Text, Text)
point text = do
  rest <- Text.stripPrefix "(" text
  let (inside, after) = Text.break (== ')') rest
  if Text.null after
    then Nothing
    else case Text.splitOn "," inside of
      [x, y] -> Just (Text.strip x, Text.strip y, Text.drop 1 after)
      _ -> Nothing

braced :: Text -> Maybe (Text, Text)
braced text = Text.stripPrefix "{" text >>= balanced '{' '}'

-- | The text up to the matching closer (the opener already consumed), and the
-- text after it.
balanced :: Char -> Char -> Text -> Maybe (Text, Text)
balanced open close = go (1 :: Int) Text.empty
  where
    go depth acc remaining =
      case Text.uncons remaining of
        Nothing -> Nothing
        Just ('\\', rest) ->
          case Text.uncons rest of
            Just (c, rest') -> go depth (acc <> Text.pack ['\\', c]) rest'
            Nothing -> Nothing
        Just (c, rest)
          | c == close && depth == 1 -> Just (acc, rest)
          | c == close -> go (depth - 1) (Text.snoc acc c) rest
          | c == open -> go (depth + 1) (Text.snoc acc c) rest
          | otherwise -> go depth (Text.snoc acc c) rest

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
