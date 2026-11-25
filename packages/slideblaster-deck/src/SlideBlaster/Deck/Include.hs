{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Deck.Include
-- Description : The @\\include[opts]{path}@ line and project-relative path keys.
--
-- A sub-presentation is spliced into a parent deck by a block-level line
-- @\\include[titleslide,dividers]{../other-talk}@ (also @skip={ids}@ and
-- @only={ids}@ to leave slides out or take only some). This module reads that line
-- and defines the path keys the analyzer and the file loaders share: a key is a
-- project-relative path with @.@ and @..@ resolved, where a @..@ that leaves the
-- project root is spelled @_up@ (so @..\/talk@ is @_up\/talk@ and every key is a
-- plain relative path a file map can hold).
module SlideBlaster.Deck.Include
  ( IncludeLine (..)
  , parseIncludeLine
  , optionName
  , optionList
  , normalizeKey
  , joinKey
  , keyDirectory
  , keyToRelative
  , childKeyOf
  , deckSuffix
  ) where

import Data.Char (isAsciiLower, isDigit, toLower)
import Data.Text (Text)
import Data.Text qualified as Text

-- | A parsed include line.
data IncludeLine = IncludeLine
  { includeOptions :: ![Text]
  , includePath :: !Text
  }
  deriving stock (Eq, Show)

-- | @\\include{path}@ or @\\include[opts]{path}@ alone on a line (column 0).
parseIncludeLine :: Text -> Maybe IncludeLine
parseIncludeLine raw = do
  afterName <- Text.stripPrefix "\\include" line
  (options, afterOptions) <- case Text.uncons afterName of
    Just ('[', r) -> let (o, rest) = Text.breakOn "]" r in if Text.null rest then Nothing else Just (o, Text.drop 1 rest)
    _ -> Just ("", afterName)
  afterBrace <- Text.stripPrefix "{" afterOptions
  let (path, rest) = Text.breakOn "}" afterBrace
  if Text.null rest || not (Text.null (Text.strip (Text.drop 1 rest))) || Text.null (Text.strip path)
    then Nothing
    else Just (IncludeLine [w | o <- splitOutsideBraces options, let w = Text.strip o, not (Text.null w)] (Text.strip path))
  where
    line = Text.dropWhileEnd (\c -> c == '\n' || c == '\r') raw

-- | Split at the commas that are not inside braces, so @skip={a,b}@ stays whole.
splitOutsideBraces :: Text -> [Text]
splitOutsideBraces = map (Text.pack . reverse) . go (0 :: Int) "" . Text.unpack
  where
    go _ current [] = [current]
    go depth current (c : rest)
      | c == ',' && depth == 0 = current : go depth "" rest
      | c == '{' = go (depth + 1) (c : current) rest
      | c == '}' = go (max 0 (depth - 1)) (c : current) rest
      | otherwise = go depth (c : current) rest

-- | The name of an option: @skip@ for @skip={a,b}@, the option itself when it has no value.
optionName :: Text -> Text
optionName = Text.strip . fst . Text.breakOn "="

-- | The list an option gives: @skip={a,b}@ and @skip=a@ are both read. Nothing
-- when the option is not written.
optionList :: Text -> [Text] -> Maybe [Text]
optionList name options = case [value | o <- options, let (n, value) = Text.breakOn "=" o, Text.strip n == name, not (Text.null value)] of
  [] -> Nothing
  values -> Just [w | value <- values, part <- Text.splitOn "," (unbrace (Text.strip (Text.drop 1 value))), let w = Text.strip part, not (Text.null w)]
  where
    unbrace t = fromMaybeText t (Text.stripPrefix "{" t >>= Text.stripSuffix "}")
    fromMaybeText fallback = maybe fallback id

-- | Resolve @.@ and @..@; a @..@ beyond the root becomes @_up@.
normalizeKey :: Text -> Text
normalizeKey = Text.intercalate "/" . reverse . foldl step [] . Text.splitOn "/"
  where
    step acc segment
      | Text.null segment || segment == "." = acc
      | segment == ".." = case acc of
          top : rest | top /= "_up" -> rest
          _ -> "_up" : acc
      | otherwise = segment : acc

-- | A path written in a deck whose folder has the given key. An empty folder
-- leaves the path as written.
joinKey :: Text -> Text -> Text
joinKey dir path
  | Text.null dir = path
  | otherwise = normalizeKey (dir <> "/" <> path)

-- | The folder part of a file key (empty at the root).
keyDirectory :: Text -> Text
keyDirectory key = case Text.splitOn "/" key of
  [_] -> ""
  segments -> Text.intercalate "/" (init segments)

-- | The key as a path relative to the root folder (@_up@ back to @..@).
keyToRelative :: Text -> Text
keyToRelative = Text.intercalate "/" . map (\s -> if s == "_up" then ".." else s) . Text.splitOn "/"

-- | @.slideBlaster.md@
deckSuffix :: Text
deckSuffix = ".slideBlaster.md"

-- | The namespace of an included deck: its folder name, or the file stem when a
-- file was named; lower-cased to @[a-z0-9-]@.
childKeyOf :: Text -> Text
childKeyOf includedKey =
  let segments = [s | s <- Text.splitOn "/" includedKey, not (Text.null s), s /= "_up"]
      base = case reverse segments of
        s : _ | Just stem <- Text.stripSuffix deckSuffix s -> stem
        s : _ -> s
        [] -> ""
      cleaned = Text.intercalate "-" (Text.words (Text.map (\c -> if isAsciiLower c || isDigit c then c else ' ') (Text.map toLower base)))
   in if Text.null cleaned then "deck" else cleaned
