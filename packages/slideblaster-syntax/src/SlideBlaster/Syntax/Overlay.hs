{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Overlay
-- Description : The Beamer overlay specification grammar.
--
-- An overlay specification is the text inside the angle brackets of @\\only\<2->@,
-- @\\item\<1,3-5>@ or a trailing @\<2->@ on a Markdown list item. The grammar
-- accepted here is the closed, absolute form: a comma-separated union of
-- @n@, @n-@, @-n@ and @n-m@ with positive integers. Beamer's incremental forms
-- (@+@, @.@, @+(1)-@) depend on a running counter and are reported as
-- 'SpecIncremental' rather than guessed at; the reader keeps their bytes.
--
-- This module only classifies text. Binding a specification to visibility is the
-- canvas layer's job ("SlideBlaster.Canvas.Flow"); keeping the grammar here lets
-- the syntax layer validate and the oracle vectors exercise it without a canvas.
module SlideBlaster.Syntax.Overlay
  ( OverlaySpec
  , SpecRange (..)
  , SpecError (..)
  , parseOverlaySpec
  , specRanges
  , printOverlaySpec
  , specFinalStep
  , specVisibleAt
  ) where

import Data.Char (isDigit)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

-- | One interval of one-based steps.
data SpecRange
  = -- | @n@
    SpecAt !Natural
  | -- | @n-@
    SpecFrom !Natural
  | -- | @-n@
    SpecThrough !Natural
  | -- | @n-m@ with @n <= m@
    SpecBetween !Natural !Natural
  deriving stock (Eq, Ord, Show)

-- | A non-empty union of ranges.
newtype OverlaySpec = OverlaySpec (NonEmpty SpecRange)
  deriving stock (Eq, Ord, Show)

-- | Why a specification was not accepted.
data SpecError
  = -- | Empty text or an empty comma alternative.
    SpecEmpty
  | -- | Not a number or range.
    SpecMalformed !Text
  | -- | Step zero; steps are one-based.
    SpecZeroStep
  | -- | @m-n@ with @m > n@.
    SpecReversed !Natural !Natural
  | -- | A counter-relative form (@+@, @.@, parentheses) this reader does not
    -- evaluate.
    SpecIncremental !Text
  deriving stock (Eq, Show)

-- | The ranges of a specification in written order.
specRanges :: OverlaySpec -> NonEmpty SpecRange
specRanges (OverlaySpec ranges) = ranges

-- | Parse the text between the angle brackets.
parseOverlaySpec :: Text -> Either SpecError OverlaySpec
parseOverlaySpec raw
  | Text.null raw = Left SpecEmpty
  | Text.any (\c -> c == '+' || c == '.' || c == '(' || c == ')') raw =
      Left (SpecIncremental raw)
  | otherwise = do
      parts <- traverse range (Text.splitOn "," raw)
      case parts of
        [] -> Left SpecEmpty
        first : rest -> Right (OverlaySpec (first :| rest))
  where
    range part =
      case Text.breakOn "-" part of
        (single, rest)
          | Text.null rest -> SpecAt <$> step single
        (before, rest) ->
          let after = Text.drop 1 rest
           in case (Text.null before, Text.null after) of
                (True, True) -> Left (SpecMalformed part)
                (False, True) -> SpecFrom <$> step before
                (True, False) -> SpecThrough <$> step after
                (False, False) -> do
                  low <- step before
                  high <- step after
                  if low <= high then Right (SpecBetween low high) else Left (SpecReversed low high)
    step text
      | Text.null text = Left SpecEmpty
      | Text.all isDigit text =
          case Text.foldl' (\acc c -> acc * 10 + fromIntegral (fromEnum c - fromEnum '0')) (0 :: Natural) text of
            0 -> Left SpecZeroStep
            value -> Right value
      | otherwise = Left (SpecMalformed text)

-- | Print a specification in its canonical spelling.
printOverlaySpec :: OverlaySpec -> Text
printOverlaySpec (OverlaySpec ranges) =
  Text.intercalate "," (fmap one (NonEmpty.toList ranges))
  where
    one r =
      case r of
        SpecAt n -> number n
        SpecFrom n -> number n <> "-"
        SpecThrough n -> "-" <> number n
        SpecBetween n m -> number n <> "-" <> number m
    number = Text.pack . show

-- | The last step a specification mentions; the step count a construct needs.
specFinalStep :: OverlaySpec -> Natural
specFinalStep (OverlaySpec ranges) = maximum (fmap final ranges)
  where
    final r =
      case r of
        SpecAt n -> n
        SpecFrom n -> n
        SpecThrough n -> n
        SpecBetween _ m -> m

-- | Whether the construct is shown at a step.
specVisibleAt :: Natural -> OverlaySpec -> Bool
specVisibleAt step (OverlaySpec ranges) = any contains ranges
  where
    contains r =
      case r of
        SpecAt n -> step == n
        SpecFrom n -> step >= n
        SpecThrough n -> step <= n
        SpecBetween n m -> step >= n && step <= m
