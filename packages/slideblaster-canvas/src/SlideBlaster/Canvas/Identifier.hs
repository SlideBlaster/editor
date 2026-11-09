{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

-- |
-- Module      : SlideBlaster.Canvas.Identifier
-- Description : Validated, nominal identifiers for canvas semantic entities.
--
-- Every identifier kind is distinct even though all identifiers retain the same
-- source-friendly token spelling. Constructors are private: identifiers are
-- non-empty ASCII tokens beginning with a letter or underscore.
module SlideBlaster.Canvas.Identifier
  ( Identifier
  , IdentifierKind
      ( NodeIdentity
      , ConnectorIdentity
      , GroupIdentity
      , AssetIdentity
      , StencilIdentity
      , CustomGeometryIdentity
      , RoleIdentity
      , RegionIdentity
      , AnchorIdentity
      , ThemeIdentity
      , FamilyIdentity
      , BarrierIdentity
      , SourceIdentity
      , FurnitureIdentity
      , AnimationIdentity
      , CitationIdentity
      )
  , NodeId
  , ConnectorId
  , GroupId
  , AssetId
  , StencilId
  , CustomGeometryId
  , RoleId
  , RegionId
  , AnchorId
  , ThemeId
  , FamilyId
  , BarrierId
  , SourceRef
  , FurnitureId
  , AnimationRef
  , CitationKey
  , ElementId (..)
  , nodeId
  , connectorId
  , groupId
  , assetId
  , stencilId
  , customGeometryId
  , roleId
  , regionId
  , anchorId
  , themeId
  , familyId
  , barrierId
  , sourceRef
  , furnitureId
  , animationRef
  , citationKey
  , defaultRoleId
  , defaultThemeId
  , identifierText
  ) where

import Data.Text (Text)
import Data.Text qualified as Text

-- | The semantic domain carried by an 'Identifier'.
data IdentifierKind
  = NodeIdentity
  | ConnectorIdentity
  | GroupIdentity
  | AssetIdentity
  | StencilIdentity
  | CustomGeometryIdentity
  | RoleIdentity
  | RegionIdentity
  | AnchorIdentity
  | ThemeIdentity
  | FamilyIdentity
  | BarrierIdentity
  | SourceIdentity
  | FurnitureIdentity
  | AnimationIdentity
  | CitationIdentity

-- | A validated source-friendly identifier with a nominal domain parameter.
newtype Identifier (kind :: IdentifierKind) = Identifier Text
  deriving stock (Eq, Ord, Show)

type role Identifier nominal

type NodeId = Identifier 'NodeIdentity

type ConnectorId = Identifier 'ConnectorIdentity

type GroupId = Identifier 'GroupIdentity

type AssetId = Identifier 'AssetIdentity

type StencilId = Identifier 'StencilIdentity

type CustomGeometryId = Identifier 'CustomGeometryIdentity

type RoleId = Identifier 'RoleIdentity

type RegionId = Identifier 'RegionIdentity

type AnchorId = Identifier 'AnchorIdentity

type ThemeId = Identifier 'ThemeIdentity

type FamilyId = Identifier 'FamilyIdentity

type BarrierId = Identifier 'BarrierIdentity

-- | Stable handle into source-owned provenance. Exact bytes remain elsewhere.
type SourceRef = Identifier 'SourceIdentity

type FurnitureId = Identifier 'FurnitureIdentity

-- | Stable reference to a presentation-owned animation.
type AnimationRef = Identifier 'AnimationIdentity

-- | Stable bibliography key used by mixed content.
type CitationKey = Identifier 'CitationIdentity

-- | Stable identity of an editable or animatable canvas element.
data ElementId
  = NodeElement !NodeId
  | ConnectorElement !ConnectorId
  | GroupElement !GroupId
  deriving stock (Eq, Ord, Show)

nodeId :: Text -> Maybe NodeId
nodeId = mkIdentifier

connectorId :: Text -> Maybe ConnectorId
connectorId = mkIdentifier

groupId :: Text -> Maybe GroupId
groupId = mkIdentifier

assetId :: Text -> Maybe AssetId
assetId = mkIdentifier

stencilId :: Text -> Maybe StencilId
stencilId = mkQualifiedIdentifier

customGeometryId :: Text -> Maybe CustomGeometryId
customGeometryId = mkIdentifier

roleId :: Text -> Maybe RoleId
roleId = mkIdentifier

regionId :: Text -> Maybe RegionId
regionId = mkIdentifier

anchorId :: Text -> Maybe AnchorId
anchorId = mkIdentifier

themeId :: Text -> Maybe ThemeId
themeId = mkIdentifier

familyId :: Text -> Maybe FamilyId
familyId = mkIdentifier

barrierId :: Text -> Maybe BarrierId
barrierId = mkIdentifier

sourceRef :: Text -> Maybe SourceRef
sourceRef = mkIdentifier

furnitureId :: Text -> Maybe FurnitureId
furnitureId = mkIdentifier

animationRef :: Text -> Maybe AnimationRef
animationRef = mkIdentifier

citationKey :: Text -> Maybe CitationKey
citationKey = mkIdentifier

-- | Stable fallback role used by the target-neutral default theme.
defaultRoleId :: RoleId
defaultRoleId = Identifier "body"

-- | Stable identity of the target-neutral default theme.
defaultThemeId :: ThemeId
defaultThemeId = Identifier "default"

-- | Recover the validated spelling for source, protocols, or diagnostics.
identifierText :: Identifier kind -> Text
identifierText (Identifier value) = value

mkIdentifier :: Text -> Maybe (Identifier kind)
mkIdentifier value =
  case Text.uncons value of
    Nothing -> Nothing
    Just (firstCharacter, rest)
      | isInitial firstCharacter && Text.all isContinuation rest ->
          Just (Identifier value)
      | otherwise -> Nothing

-- | Imported resource identifiers may be namespace-qualified with dots. The
-- first segment retains the source-friendly identifier rule. Later non-empty
-- segments may begin with a digit because imported registries such as draw.io
-- use stable names like @advertising.3-1-rec@. Leading, trailing, or doubled
-- dots and non-ASCII token characters remain invalid.
mkQualifiedIdentifier :: Text -> Maybe (Identifier kind)
mkQualifiedIdentifier value
  | any Text.null segments = Nothing
  | otherwise =
      case segments of
        [] -> Nothing
        firstSegment : remaining
          | validFirstSegment firstSegment
              && all (Text.all isContinuation) remaining ->
              Just (Identifier value)
          | otherwise -> Nothing
  where
    segments = Text.splitOn "." value
    validFirstSegment segment =
      case Text.uncons segment of
        Nothing -> False
        Just (firstCharacter, rest) ->
          isInitial firstCharacter && Text.all isContinuation rest

isInitial :: Char -> Bool
isInitial character =
  isAsciiLower character
    || isAsciiUpper character
    || character == '_'

isContinuation :: Char -> Bool
isContinuation character =
  isInitial character
    || (character >= '0' && character <= '9')
    || character == '-'

isAsciiLower :: Char -> Bool
isAsciiLower character = character >= 'a' && character <= 'z'

isAsciiUpper :: Char -> Bool
isAsciiUpper character = character >= 'A' && character <= 'Z'
