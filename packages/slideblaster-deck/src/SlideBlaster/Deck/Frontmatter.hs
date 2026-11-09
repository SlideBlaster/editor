{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Deck.Frontmatter
-- Description : The YAML subset of a @*.slideBlaster.md@ frontmatter block.
--
-- Frontmatter is read, never written: edits are exact byte replacements located
-- by the container, so nothing here prints. Only the subset the format uses is
-- understood: @key: value@ scalars (plain, @"double"@, @'single'@), block scalars
-- (@|@ keeps line breaks, @>@ folds them) and @- item@ lists, which are joined
-- with commas. Anything else on a line is ignored for meaning but, being part of
-- the container's bytes, retained exactly.
--
-- Unknown keys are kept and reported ('unknownKeys') as information diagnostics.
module SlideBlaster.Deck.Frontmatter
  ( Frontmatter
  , parseFrontmatter
  , emptyFrontmatter
  , frontmatterEntries
  , frontmatterLookup
  , knownKeys
  , unknownKeys
  , Aspect (..)
  , frontmatterAspect
  , frontmatterFormatVersion
  , frontmatterRoutes
  ) where

import Data.Char (isAlphaNum, isDigit, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text

-- | Entries in file order, values already unquoted and block scalars folded.
newtype Frontmatter = Frontmatter [(Text, Text)]
  deriving stock (Eq, Show)

emptyFrontmatter :: Frontmatter
emptyFrontmatter = Frontmatter []

-- | All entries in file order.
frontmatterEntries :: Frontmatter -> [(Text, Text)]
frontmatterEntries (Frontmatter entries) = entries

-- | The first value for a key.
frontmatterLookup :: Text -> Frontmatter -> Maybe Text
frontmatterLookup key (Frontmatter entries) = lookup key entries

-- | Keys the format defines.
knownKeys :: [Text]
knownKeys =
  [ "slideblaster"
  , "title"
  , "subtitle"
  , "authors"
  , "institute"
  , "date"
  , "theme"
  , "aspect"
  , "bibliography"
  , "citation-style"
  , "preamble"
  , "listing-defaults"
  , "routes"
  , "sectionSlides"
  ]

-- | Keys present that the format does not define, in file order.
unknownKeys :: Frontmatter -> [Text]
unknownKeys (Frontmatter entries) = [k | (k, _) <- entries, k `notElem` knownKeys]

-- | Slide aspect ratio.
data Aspect = Aspect !Int !Int
  deriving stock (Eq, Show)

-- | The aspect ratio; @16:9@ when absent. 'Left' carries the unreadable text.
frontmatterAspect :: Frontmatter -> Either Text Aspect
frontmatterAspect fm =
  case frontmatterLookup "aspect" fm of
    Nothing -> Right (Aspect 16 9)
    Just raw ->
      case Text.splitOn ":" (Text.strip raw) of
        [w, h]
          | Just a <- number w
          , Just b <- number h
          , a > 0
          , b > 0 ->
              Right (Aspect a b)
        _ -> Left raw
  where
    number t
      | not (Text.null t) && Text.all isDigit t && Text.length t <= 4 =
          Just (Text.foldl' (\acc c -> acc * 10 + fromEnum c - fromEnum '0') 0 t)
      | otherwise = Nothing

-- | The declared format version, if it is a number.
frontmatterFormatVersion :: Frontmatter -> Maybe Int
frontmatterFormatVersion fm =
  case frontmatterLookup "slideblaster" fm of
    Just v | not (Text.null v) && Text.all isDigit v -> Just (Text.foldl' (\a c -> a * 10 + fromEnum c - fromEnum '0') 0 v)
    _ -> Nothing

-- | The @routes:@ map: route name to its section ids, in file order. The
-- value is stored as one @name: id, id@ line per route.
frontmatterRoutes :: Frontmatter -> [(Text, [Text])]
frontmatterRoutes fm =
  case frontmatterLookup "routes" fm of
    Nothing -> []
    Just value -> [route l | l <- Text.lines value, not (Text.null (Text.strip l))]
  where
    route l =
      let (name, rest) = Text.breakOn ":" l
       in (Text.strip name, [i | i <- fmap Text.strip (Text.splitOn "," (Text.drop 1 rest)), not (Text.null i)])

-- Canonical @name: a, b@ lines of an indented routes block. Accepts the flow
-- form @name: [a, b]@ and the block form @name:@ followed by @- a@ items.
routesValue :: [Text] -> Text
routesValue block = Text.intercalate "\n" [name <> ": " <> Text.intercalate ", " (reverse ids) | (name, ids) <- reverse (foldl step [] block)]
  where
    -- accumulator: routes newest first, each with its ids newest first
    step acc l
      | Text.null t = acc
      | Just item <- Text.stripPrefix "-" t =
          case acc of
            (name, ids) : more -> (name, scalar item : ids) : more
            [] -> acc
      | otherwise =
          case Text.breakOn ":" t of
            (name, after) | not (Text.null after) -> (Text.strip name, reverse (inline (Text.strip (Text.drop 1 after)))) : acc
            _ -> acc
      where
        t = Text.strip l
    inline v =
      let bare = fst (Text.breakOn " #" v)
          inner = case Text.stripPrefix "[" (Text.strip bare) of
            Just r -> Text.dropWhileEnd (== ']') (Text.strip r)
            Nothing -> bare
       in [i | i <- fmap scalar (Text.splitOn "," inner), not (Text.null i)]

-- | Read the lines between the @---@ fences.
parseFrontmatter :: [Text] -> Frontmatter
parseFrontmatter ls = Frontmatter (go ls)
  where
    go [] = []
    go (line : rest) =
      case keyOf line of
        Nothing -> go rest
        Just (key, raw)
          | blockMarker raw ->
              let (block, after) = span continuation rest
               in (key, blockValue raw block) : go after
          | key == "routes" && Text.null raw ->
              let (block, after) = span continuation rest
               in (key, routesValue block) : go after
          | Text.null raw ->
              let (items, after) = span listItem rest
               in if null items
                    then (key, Text.empty) : go after
                    else (key, Text.intercalate ", " (fmap (scalar . Text.drop 1 . Text.stripStart) items)) : go after
          | otherwise -> (key, scalar raw) : go rest
    continuation l = Text.null (Text.strip l) || (not (Text.null l) && maybe False (isSpace . fst) (Text.uncons l))
    listItem l = "-" `Text.isPrefixOf` Text.stripStart l && not (Text.null (Text.strip l))

keyOf :: Text -> Maybe (Text, Text)
keyOf line =
  case Text.uncons line of
    Just (c, _)
      | isAlphaNum c ->
          let (key, rest) = Text.break (== ':') line
           in if Text.null rest || not (Text.all validKeyChar key)
                then Nothing
                else Just (key, Text.strip (Text.drop 1 rest))
    _ -> Nothing
  where
    validKeyChar c = isAlphaNum c || c == '-' || c == '_'

blockMarker :: Text -> Bool
blockMarker raw =
  case Text.uncons raw of
    Just (c, rest) -> (c == '|' || c == '>') && Text.all (\x -> x == '-' || x == '+' || isDigit x) rest
    Nothing -> False

blockValue :: Text -> [Text] -> Text
blockValue marker block =
  let content = reverse (dropWhile (Text.null . Text.strip) (reverse block))
      indent = minimum' (fmap indentOf (filter (not . Text.null . Text.strip) content))
      stripped = fmap (Text.drop indent) content
   in if Text.take 1 marker == ">"
        then Text.unwords (filter (not . Text.null) stripped)
        else Text.intercalate "\n" stripped
  where
    indentOf l = Text.length (Text.takeWhile (== ' ') l)
    minimum' xs = if null xs then 0 else foldr1 min xs

-- | A plain, double-quoted or single-quoted scalar.
scalar :: Text -> Text
scalar raw =
  case Text.uncons stripped of
    Just ('"', rest) -> unescape (fst (breakQuote rest))
    Just ('\'', rest) -> Text.replace "''" "'" (fst (Text.breakOn "'" rest))
    _ -> Text.strip (fst (Text.breakOn " #" stripped))
  where
    stripped = Text.strip raw
    breakQuote t = go Text.empty t
      where
        go acc remaining =
          case Text.uncons remaining of
            Nothing -> (acc, Text.empty)
            Just ('\\', more) -> case Text.uncons more of
              Just (c, more') -> go (acc <> Text.pack ['\\', c]) more'
              Nothing -> (acc, Text.empty)
            Just ('"', more) -> (acc, more)
            Just (c, more) -> go (Text.snoc acc c) more
    unescape = Text.replace "\\\"" "\"" . Text.replace "\\\\" "\\" . Text.replace "\\n" "\n"
