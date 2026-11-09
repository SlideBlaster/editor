{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Listing
-- Description : Code-listing model and stepped line-highlight specifications.
--
-- A listing is verbatim text with a language and an optional highlight
-- specification. The specification is the text inside the braces of a fence info
-- string, @{1,3-5|7}@: line numbers and inclusive ranges separated by commas,
-- with @|@ separating steps. Step one highlights lines @1,3-5@, step two line @7@.
-- A listing with an empty specification has no highlight and one step.
--
-- Skeleton for the alpha: the model and the grammar are complete; syntax
-- colouring is the host's job (a content-host call), and binding steps to
-- presentation beats arrives with milestone M.
module SlideBlaster.Listing
  ( Listing (..)
  , mkListing
  , listingLines
  , HighlightSpec
  , LineRange (..)
  , HighlightError (..)
  , parseHighlightSpec
  , noHighlight
  , highlightStepCount
  , highlightedAt
  , isHighlightedAt
  , printHighlightSpec
  ) where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as Text

-- | An inclusive range of one-based line numbers.
data LineRange = LineRange !Int !Int
  deriving stock (Eq, Ord, Show)

-- | Per-step highlighted line ranges. Always at least one step.
newtype HighlightSpec = HighlightSpec [[LineRange]]
  deriving stock (Eq, Ord, Show)

-- | Why a specification was rejected.
data HighlightError
  = HighlightEmptyItem
  | HighlightMalformed !Text
  | HighlightZeroLine
  | HighlightReversed !Int !Int
  deriving stock (Eq, Show)

-- | A listing: the language tag as authored (may be empty), the exact code, the
-- highlight specification and whether line numbers are shown.
data Listing = Listing
  { listingLanguage :: !Text
  , listingCode :: !Text
  , listingHighlight :: !HighlightSpec
  , listingLineNumbers :: !Bool
  }
  deriving stock (Eq, Ord, Show)

-- | Build a listing from a language, code and the raw text inside the braces.
mkListing :: Text -> Text -> Maybe Text -> Bool -> Either HighlightError Listing
mkListing language code rawSpec numbers = do
  spec <- maybe (Right noHighlight) parseHighlightSpec rawSpec
  pure (Listing language code spec numbers)

-- | The code split into lines, without line endings.
listingLines :: Listing -> [Text]
listingLines listing =
  case Text.splitOn "\n" (Text.dropWhileEnd (== '\n') (listingCode listing)) of
    [""] | Text.null (listingCode listing) -> []
    ls -> fmap (Text.dropWhileEnd (== '\r')) ls

-- | One step, nothing highlighted.
noHighlight :: HighlightSpec
noHighlight = HighlightSpec [[]]

-- | Parse the text inside the braces.
parseHighlightSpec :: Text -> Either HighlightError HighlightSpec
parseHighlightSpec raw
  | Text.all (\c -> c == ' ') raw = Right noHighlight
  | otherwise = HighlightSpec <$> traverse step (Text.splitOn "|" raw)
  where
    step part
      | Text.all (== ' ') part = Right []
      | otherwise = traverse range (Text.splitOn "," part)
    range item =
      case Text.breakOn "-" (Text.strip item) of
        (single, rest)
          | Text.null rest -> (\n -> LineRange n n) <$> number single
        (low, rest) -> do
          a <- number low
          b <- number (Text.drop 1 rest)
          if a <= b then Right (LineRange a b) else Left (HighlightReversed a b)
    number text
      | Text.null text = Left HighlightEmptyItem
      | Text.all isDigit text && Text.length text <= 9 =
          case Text.foldl' (\acc c -> acc * 10 + fromEnum c - fromEnum '0') 0 text of
            0 -> Left HighlightZeroLine
            n -> Right n
      | otherwise = Left (HighlightMalformed text)

-- | The number of steps; at least one.
highlightStepCount :: HighlightSpec -> Int
highlightStepCount (HighlightSpec steps) = max 1 (length steps)

-- | Ranges highlighted at a one-based step; empty outside the specification.
highlightedAt :: Int -> HighlightSpec -> [LineRange]
highlightedAt step (HighlightSpec steps) =
  case drop (step - 1) steps of
    ranges : _ | step >= 1 -> ranges
    _ -> []

-- | Whether a one-based line is highlighted at a one-based step.
isHighlightedAt :: Int -> Int -> HighlightSpec -> Bool
isHighlightedAt step line spec =
  any (\(LineRange a b) -> line >= a && line <= b) (highlightedAt step spec)

-- | Canonical text of a specification.
printHighlightSpec :: HighlightSpec -> Text
printHighlightSpec (HighlightSpec steps) =
  Text.intercalate "|" (fmap (Text.intercalate "," . fmap one) steps)
  where
    one (LineRange a b)
      | a == b = Text.pack (show a)
      | otherwise = Text.pack (show a) <> "-" <> Text.pack (show b)
