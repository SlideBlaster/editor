-- |
-- Module      : SlideBlaster.Syntax.Style
-- Description : Style facts shared by every input dialect.
--
-- Bold has three spellings — @\\textbf{x}@, @**x**@, @\<strong\>x\</strong\>@ — and
-- one meaning. This module holds the meaning. How it was written lives in
-- "SlideBlaster.Syntax.Surface".
--
-- Styles are a keyed map rather than a fixed record. That matters for two
-- reasons. An HTML @style@ attribute can set several properties at once, so a
-- single authored construct carries several facts. And an edit must be able to
-- change one property without asserting anything about the others, which a record
-- of @Maybe@ fields cannot express: there is no way to distinguish "leave the
-- weight alone" from "set the weight to nothing".
module SlideBlaster.Syntax.Style
  ( -- * Facts
    StyleKey (..)
  , StyleValue (..)
  , styleKey

    -- * Maps
  , StyleMap
  , emptyStyleMap
  , styleMapFromList
  , styleMapToList
  , lookupStyle
  , insertStyle
  , removeStyle

    -- * Values
  , Weight (..)
  , Slant (..)
  , Family (..)
  , Variant (..)

    -- * Colour
  , ColourExpr (..)
  , ColourModel (..)
  , Literal (..)
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

-- | A value together with the exact text the author wrote for it.
--
-- Many values have several spellings that mean the same thing: @50@ and @50.0@ as
-- a colour percentage, @1cm@ and @10mm@ as a length. Semantics reads
-- 'literalValue'; printing reproduces 'literalText'. Without this, exact
-- reprinting and semantic interpretation would pull in opposite directions.
data Literal a = Literal
  { literalValue :: !a
  , literalText :: !Text
  }
  deriving stock (Eq, Ord, Show)

data Weight
  = NormalWeight
  | Bold
  deriving stock (Eq, Ord, Show)

data Slant
  = Upright
  | Italic
  deriving stock (Eq, Ord, Show)

data Family
  = Serif
  | SansSerif
  | Monospace
  deriving stock (Eq, Ord, Show)

data Variant
  = NormalVariant
  | SmallCaps
  deriving stock (Eq, Ord, Show)

-- | The colour model a literal was written in.
data ColourModel
  = NamedModel
  | RgbModel
  | GrayModel
  | HtmlModel
  deriving stock (Eq, Ord, Show)

-- | An xcolor colour expression.
--
-- Percentages keep their authored spelling, so @red!50@ does not reprint as
-- @red!25\/2@ after being read as a 'Rational'.
data ColourExpr
  = -- | A plain name such as @red@.
    ColourName !Text
  | -- | A literal in an explicit model, such as @[rgb]{1,0,0}@.
    ColourLiteral !ColourModel !Text
  | -- | @a!p@: percentage @p@ of @a@ mixed with white.
    ColourTint !ColourExpr !(Literal Rational)
  | -- | @a!p!b@: percentage @p@ of @a@ mixed with @b@.
    ColourMix !ColourExpr !(Literal Rational) !ColourExpr
  | -- | @-a@: the complement of @a@.
    ColourComplement !ColourExpr
  deriving stock (Eq, Ord, Show)

-- | Which property a style fact sets.
--
-- Underline, strikethrough and highlight are separate keys rather than one
-- decoration key because they can be applied together.
data StyleKey
  = WeightKey
  | SlantKey
  | FamilyKey
  | VariantKey
  | UnderlineKey
  | StrikeKey
  | HighlightKey
  | ForegroundKey
  | BackgroundKey
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | One style fact.
data StyleValue
  = SetWeight !Weight
  | SetSlant !Slant
  | SetFamily !Family
  | SetVariant !Variant
  | SetUnderline !Bool
  | SetStrike !Bool
  | SetHighlight !Bool
  | SetForeground !ColourExpr
  | SetBackground !ColourExpr
  deriving stock (Eq, Ord, Show)

-- | The property a fact sets. Total, so a fact and its key cannot disagree.
styleKey :: StyleValue -> StyleKey
styleKey value =
  case value of
    SetWeight _ -> WeightKey
    SetSlant _ -> SlantKey
    SetFamily _ -> FamilyKey
    SetVariant _ -> VariantKey
    SetUnderline _ -> UnderlineKey
    SetStrike _ -> StrikeKey
    SetHighlight _ -> HighlightKey
    SetForeground _ -> ForegroundKey
    SetBackground _ -> BackgroundKey

-- | The style facts carried by one authored construct.
--
-- A TeX style command contributes exactly one fact; an HTML @style@ attribute may
-- contribute several. The map's size therefore follows the source, which is what
-- keeps nesting order faithful: @\\textbf{\\textit{x}}@ stays two nested nodes
-- rather than collapsing into one node with two facts.
newtype StyleMap = StyleMap (Map StyleKey StyleValue)
  deriving stock (Eq, Ord, Show)

emptyStyleMap :: StyleMap
emptyStyleMap = StyleMap Map.empty

-- | Later facts win, so a construct that sets the same property twice keeps the
-- effective one.
styleMapFromList :: [StyleValue] -> StyleMap
styleMapFromList values =
  StyleMap (Map.fromList [(styleKey value, value) | value <- values])

-- | Facts in a stable order, for printing and comparison.
styleMapToList :: StyleMap -> [StyleValue]
styleMapToList (StyleMap facts) = Map.elems facts

lookupStyle :: StyleKey -> StyleMap -> Maybe StyleValue
lookupStyle key (StyleMap facts) = Map.lookup key facts

insertStyle :: StyleValue -> StyleMap -> StyleMap
insertStyle value (StyleMap facts) =
  StyleMap (Map.insert (styleKey value) value facts)

removeStyle :: StyleKey -> StyleMap -> StyleMap
removeStyle key (StyleMap facts) = StyleMap (Map.delete key facts)
