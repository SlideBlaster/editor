{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Cite
-- Description : BibTeX reader and citation labels.
--
-- Skeleton for the alpha. The reader is total: it returns the entries it could
-- read and a warning for each region it could not, never an exception. Labels
-- implement the two styles in the format (@numeric@, @author-year@); the
-- bibliography slide and @\\citefootnote@ footer text build on 'citationLabels'
-- in milestone M, and reference formatting is checked against vectors exported
-- from the oracle editors.
module SlideBlaster.Cite
  ( BibEntry (..)
  , Bibliography
  , BibWarning (..)
  , readBibliography
  , bibliographyEntries
  , lookupEntry
  , entryField
  , CitationStyle (..)
  , parseCitationStyle
  , citationLabels
  , authorSurnames
  ) where

import Data.Char (isAlphaNum, isSpace)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

-- | One bibliography entry; the type is lower-cased, field names are lower-cased,
-- field values are the text inside their delimiters with outer whitespace
-- trimmed.
data BibEntry = BibEntry
  { entryType :: !Text
  , entryKey :: !Text
  , entryFields :: ![(Text, Text)]
  }
  deriving stock (Eq, Show)

-- | Entries by key, remembering file order.
data Bibliography = Bibliography !(Map Text BibEntry) ![Text]
  deriving stock (Eq, Show)

-- | A region the reader skipped.
data BibWarning
  = BibUnterminatedEntry !Text
  | BibMalformedEntry !Text
  | BibDuplicateKey !Text
  deriving stock (Eq, Show)

-- | Read BibTeX text. @\@comment@, @\@preamble@ and @\@string@ are skipped. The
-- first entry for a key wins and later ones are reported.
readBibliography :: Text -> (Bibliography, [BibWarning])
readBibliography input = finish (entries input)
  where
    finish found =
      foldl add (Bibliography Map.empty [], []) found
    add (Bibliography byKey order, warnings) (Right entry)
      | Map.member (entryKey entry) byKey =
          (Bibliography byKey order, warnings <> [BibDuplicateKey (entryKey entry)])
      | otherwise =
          (Bibliography (Map.insert (entryKey entry) entry byKey) (order <> [entryKey entry]), warnings)
    add (bibliography, warnings) (Left warning) = (bibliography, warnings <> [warning])

-- | Entries in file order.
bibliographyEntries :: Bibliography -> [BibEntry]
bibliographyEntries (Bibliography byKey order) = [entry | key <- order, Just entry <- [Map.lookup key byKey]]

-- | Find an entry by key.
lookupEntry :: Text -> Bibliography -> Maybe BibEntry
lookupEntry key (Bibliography byKey _) = Map.lookup key byKey

-- | A field by lower-case name.
entryField :: Text -> BibEntry -> Maybe Text
entryField name entry = lookup name (entryFields entry)

entries :: Text -> [Either BibWarning BibEntry]
entries text =
  case Text.break (== '@') text of
    (_, rest)
      | Text.null rest -> []
      | otherwise ->
          let afterAt = Text.drop 1 rest
              kind = Text.toLower (Text.takeWhile isAlphaNum afterAt)
              afterKind = Text.stripStart (Text.drop (Text.length kind) afterAt)
           in case Text.uncons afterKind of
                Just (open, body)
                  | open == '{' || open == '(' ->
                      case balancedBody (closerFor open) open body of
                        Nothing -> [Left (BibUnterminatedEntry kind)]
                        Just (inside, after)
                          | kind `elem` ["comment", "preamble", "string"] -> entries after
                          | otherwise -> entry kind inside : entries after
                _ -> Left (BibMalformedEntry kind) : entries afterAt

closerFor :: Char -> Char
closerFor '(' = ')'
closerFor _ = '}'

-- | Text up to the matching closer (brace-balanced), and what follows it.
balancedBody :: Char -> Char -> Text -> Maybe (Text, Text)
balancedBody closer opener = go (1 :: Int) Text.empty
  where
    go depth acc remaining =
      case Text.uncons remaining of
        Nothing -> Nothing
        Just (c, rest)
          | c == closer && depth == 1 -> Just (acc, rest)
          | c == closer -> go (depth - 1) (Text.snoc acc c) rest
          | c == opener -> go (depth + 1) (Text.snoc acc c) rest
          | otherwise -> go depth (Text.snoc acc c) rest

entry :: Text -> Text -> Either BibWarning BibEntry
entry kind inside =
  case Text.break (== ',') inside of
    (key, rest)
      | Text.null (Text.strip key) -> Left (BibMalformedEntry kind)
      | otherwise ->
          Right (BibEntry kind (Text.strip key) (fields (Text.drop 1 rest)))

fields :: Text -> [(Text, Text)]
fields text =
  let trimmed = Text.dropWhile (\c -> isSpace c || c == ',') text
      name = Text.toLower (Text.takeWhile (\c -> isAlphaNum c || c == '-' || c == '_') trimmed)
      afterName = Text.stripStart (Text.drop (Text.length name) trimmed)
   in if Text.null name
        then []
        else case Text.uncons afterName of
          Just ('=', afterEquals) ->
            let (value, remaining) = fieldValue (Text.stripStart afterEquals)
             in (name, Text.strip value) : fields remaining
          _ -> fields (Text.drop 1 afterName)

fieldValue :: Text -> (Text, Text)
fieldValue text =
  case Text.uncons text of
    Just ('{', rest) -> maybe (rest, Text.empty) id (balancedBody '}' '{' rest)
    Just ('"', rest) -> quoted rest
    _ -> Text.break (\c -> c == ',' || c == '\n') text
  where
    quoted rest =
      let (inside, after) = Text.break (== '"') rest
       in (inside, Text.drop 1 after)

-- | The two citation label styles.
data CitationStyle = NumericStyle | AuthorYearStyle
  deriving stock (Eq, Show)

-- | @numeric@ or @author-year@.
parseCitationStyle :: Text -> Maybe CitationStyle
parseCitationStyle t =
  case t of
    "numeric" -> Just NumericStyle
    "author-year" -> Just AuthorYearStyle
    _ -> Nothing

-- | Surnames of an entry's authors, from @Surname, Given and ...@ or
-- @Given Surname and ...@ spellings.
authorSurnames :: BibEntry -> [Text]
authorSurnames entry' =
  case entryField "author" entry' of
    Nothing -> []
    Just authors -> fmap surname (Text.splitOn " and " authors)
  where
    surname a =
      let stripped = Text.strip (Text.filter (\c -> c /= '{' && c /= '}') a)
       in case Text.splitOn "," stripped of
            family : _ : _ -> Text.strip family
            _ -> case reverse (Text.words stripped) of
              last' : _ -> last'
              [] -> stripped

-- | Labels for keys cited in first-citation order. A key with no entry gets
-- 'Nothing', which callers report as an unknown-key diagnostic at the citation.
citationLabels :: CitationStyle -> Bibliography -> [Text] -> [(Text, Maybe Text)]
citationLabels style bibliography keys = fmap label (zip [1 :: Int ..] (dedupe keys))
  where
    label (index, key) =
      case lookupEntry key bibliography of
        Nothing -> (key, Nothing)
        Just e ->
          ( key
          , Just $ case style of
              NumericStyle -> "[" <> Text.pack (show index) <> "]"
              AuthorYearStyle ->
                let names = authorSurnames e
                    year = maybe "n.d." id (entryField "year" e)
                    who = case names of
                      [] -> key
                      [one] -> one
                      [a, b] -> a <> " and " <> b
                      a : _ -> a <> " et al."
                 in who <> ", " <> year
          )
    dedupe = foldl (\acc k -> if k `elem` acc then acc else acc <> [k]) []
