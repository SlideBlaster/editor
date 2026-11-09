-- |
-- Module      : SlideBlaster.Document.Provenance
-- Description : Field-grained source provenance and editability.
--
-- Provenance says how a semantic field relates to exact source, independently
-- of the field's value or input dialect. Only a direct slot with a named
-- inverse projection rule is eligible to propose an ordinary canvas patch.
module SlideBlaster.Document.Provenance
  ( NonEditableReason (..)
  , Origin (..)
  , ProjectionRule
  , ProvenanceMap
  , emptyProvenanceMap
  , insertOrigin
  , lookupOrigin
  , mkProjectionRule
  , projectionRuleText
  , provenanceFromList
  , provenanceToList
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import SlideBlaster.Source (SourceSpan)

-- | A named inverse rule reviewed by a format-specific projector.
newtype ProjectionRule = ProjectionRule Text
  deriving (Eq, Ord, Show)

-- | Explain why a semantic field is currently canvas-read-only.
data NonEditableReason
  = ExpandedSyntax
  | DerivedValue
  | AmbiguousOwnership
  | UnsupportedSyntax
  | OpaqueSource
  | MissingInverseRule
  deriving (Eq, Ord, Show)

-- | The relationship between one semantic field and exact authored source.
data Origin
  = DirectSlot !SourceSpan !ProjectionRule
  | DerivedBy !ProjectionRule !(NonEmpty SourceSpan)
  | ExpandedFrom !(NonEmpty SourceSpan)
  | GeneratedAt !SourceSpan
  | ReadOnly !NonEditableReason !(Maybe SourceSpan)
  deriving (Eq, Ord, Show)

-- | A typed index from format-chosen semantic field keys to origins.
newtype ProvenanceMap key = ProvenanceMap (Map key Origin)
  deriving (Eq, Show)

-- | Construct a projection-rule name, rejecting empty values.
mkProjectionRule :: Text -> Maybe ProjectionRule
mkProjectionRule value
  | Text.null (Text.strip value) = Nothing
  | otherwise = Just (ProjectionRule value)

-- | Return the stable projection-rule name.
projectionRuleText :: ProjectionRule -> Text
projectionRuleText (ProjectionRule value) = value

-- | Construct an empty provenance index.
emptyProvenanceMap :: ProvenanceMap key
emptyProvenanceMap = ProvenanceMap Map.empty

-- | Insert or replace the origin for one semantic key.
insertOrigin
  :: Ord key
  => key
  -> Origin
  -> ProvenanceMap key
  -> ProvenanceMap key
insertOrigin key origin (ProvenanceMap values) =
  ProvenanceMap (Map.insert key origin values)

-- | Look up the source origin of one semantic field.
lookupOrigin :: Ord key => key -> ProvenanceMap key -> Maybe Origin
lookupOrigin key (ProvenanceMap values) = Map.lookup key values

-- | Build an index; later duplicate keys take precedence.
provenanceFromList :: Ord key => [(key, Origin)] -> ProvenanceMap key
provenanceFromList = ProvenanceMap . Map.fromList

-- | Return origins in semantic-key order.
provenanceToList :: ProvenanceMap key -> [(key, Origin)]
provenanceToList (ProvenanceMap values) = Map.toAscList values
