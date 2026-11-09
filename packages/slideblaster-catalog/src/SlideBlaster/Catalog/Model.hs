-- |
-- Module      : SlideBlaster.Catalog.Model
-- Description : Validated shape catalog and attributed stencil registry.
--
-- Catalog rows are creation presets, never a second canvas object hierarchy.
-- Dropping any row creates an ordinary node carrying its generic canvas
-- outline, properties, size, and content. Large generated libraries therefore
-- add data and attributed resources without widening the canvas model.
module SlideBlaster.Catalog.Model
  ( ShapeId
  , shapeId
  , shapeIdText
  , CatalogFamily
  , catalogFamily
  , catalogFamilyText
  , CatalogPriority (..)
  , CatalogOrigin (..)
  , ShapeAttribution (..)
  , ShapePreset (..)
  , shapePresetNodeSeed
  , ShapeCatalog
  , ShapeCatalogError (..)
  , mkShapeCatalog
  , mergeShapeCatalogs
  , catalogPresets
  , catalogPresetById
  , StencilAspectPolicy (..)
  , StencilGeometryData (..)
  , StencilDefinition (..)
  , StencilLibrary
  , StencilLibraryError (..)
  , mkStencilLibrary
  , stencilDefinitions
  , stencilDefinitionById
  ) where

import SlideBlaster.Canvas
  ( AssetId
  , Content
  , NodeSeed (..)
  , NodePropertyPatch (nodePatchSizing)
  , OutlineRef
  , PathOutline
  , Size
  , Sizing (MinimumSize)
  , StencilId
  , stencilId
  )

import Data.Char (isControl)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

-- | Stable palette identity. It is deliberately catalog-owned and is not
-- retained by an inserted semantic node.
newtype ShapeId = ShapeId Text
  deriving stock (Eq, Ord, Show)

shapeId :: Text -> Maybe ShapeId
shapeId value =
  case stencilId value of
    Nothing -> Nothing
    Just _ -> Just (ShapeId value)

shapeIdText :: ShapeId -> Text
shapeIdText (ShapeId value) = value

-- | Stable first-level panel grouping, such as @General@ or @Electrical@.
--
-- Construction rejects empty or slash-delimited values because a family is
-- one level; the more specific display category remains on 'ShapePreset'.
newtype CatalogFamily = CatalogFamily Text
  deriving stock (Eq, Ord, Show)

catalogFamily :: Text -> Maybe CatalogFamily
catalogFamily value
  | Text.null stripped = Nothing
  | Text.any (== '/') stripped = Nothing
  | Text.any isControl stripped = Nothing
  | otherwise = Just (CatalogFamily stripped)
  where
    stripped = Text.strip value

catalogFamilyText :: CatalogFamily -> Text
catalogFamilyText (CatalogFamily value) = value

-- | Product reach tier. P0 and P1 are curated native presets; P2 is the
-- searchable long tail and does not imply a different canvas object type.
data CatalogPriority
  = P0Catalog
  | P1Catalog
  | P2Catalog
  deriving stock (Eq, Ord, Show)

data ShapeAttribution = ShapeAttribution
  { attributionTitle :: !Text
  , attributionAuthor :: !Text
  , attributionLicense :: !Text
  , attributionSource :: !Text
  }
  deriving stock (Eq, Ord, Show)

data CatalogOrigin
  = CuratedCatalogOrigin
  | ImportedDrawIOOrigin !ShapeAttribution
  | UserCatalogOrigin !Text !(Maybe ShapeAttribution)
  | ExtensionCatalogOrigin !Text !(Maybe ShapeAttribution)
  deriving stock (Eq, Ord, Show)

-- | One palette creation preset. The preset is consumed at insertion time;
-- authored and palette-created nodes are semantically indistinguishable.
data ShapePreset = ShapePreset
  { shapePresetIdentifier :: !ShapeId
  , shapePresetLabel :: !Text
  , shapePresetCategory :: !Text
  , shapePresetKeywords :: ![Text]
  , shapePresetFamily :: !CatalogFamily
  , shapePresetPriority :: !CatalogPriority
  , shapePresetOrigin :: !CatalogOrigin
  , shapePresetOutline :: !OutlineRef
  , shapePresetProperties :: !NodePropertyPatch
  , shapePresetDropSize :: !Size
  , shapePresetContent :: !Content
  }
  deriving stock (Eq, Show)

-- | Erase catalog identity and metadata at the insertion boundary.
shapePresetNodeSeed :: ShapePreset -> NodeSeed
shapePresetNodeSeed preset =
  NodeSeed
    { nodeSeedOutline = shapePresetOutline preset
    , nodeSeedContent = shapePresetContent preset
    , nodeSeedProperties =
        (shapePresetProperties preset)
          { nodePatchSizing =
              Just (MinimumSize (shapePresetDropSize preset))
          }
    }

data ShapeCatalog = ShapeCatalog
  !(NonEmpty ShapePreset)
  !(Map ShapeId ShapePreset)
  deriving stock (Eq, Show)

data ShapeCatalogError = DuplicateCatalogShape !ShapeId
  deriving stock (Eq, Show)

mkShapeCatalog
  :: NonEmpty ShapePreset
  -> Either ShapeCatalogError ShapeCatalog
mkShapeCatalog entries = do
  index <- foldl insertUnique (Right Map.empty) entries
  Right (ShapeCatalog entries index)
  where
    insertUnique
      :: Either ShapeCatalogError (Map ShapeId ShapePreset)
      -> ShapePreset
      -> Either ShapeCatalogError (Map ShapeId ShapePreset)
    insertUnique accumulated entry = do
      seen <- accumulated
      let identity = shapePresetIdentifier entry
      if Map.member identity seen
        then Left (DuplicateCatalogShape identity)
        else Right (Map.insert identity entry seen)

mergeShapeCatalogs
  :: ShapeCatalog
  -> ShapeCatalog
  -> Either ShapeCatalogError ShapeCatalog
mergeShapeCatalogs left right =
  mkShapeCatalog (catalogPresets left <> catalogPresets right)

catalogPresets :: ShapeCatalog -> NonEmpty ShapePreset
catalogPresets (ShapeCatalog entries _) = entries

catalogPresetById :: ShapeId -> ShapeCatalog -> Maybe ShapePreset
catalogPresetById wanted (ShapeCatalog _ index) =
  Map.lookup wanted index

data StencilAspectPolicy
  = StretchStencil
  | PreserveStencilAspect
  deriving stock (Eq, Ord, Show)

data StencilGeometryData
  = StencilPath !PathOutline
  | StencilCompound !(NonEmpty OutlineRef)
  | StencilSvgAsset !AssetId
  | StencilRasterAsset !AssetId
  deriving stock (Eq, Ord, Show)

data StencilDefinition = StencilDefinition
  { stencilDefinitionId :: !StencilId
  , stencilDefinitionLabel :: !Text
  , stencilDefinitionCategory :: !Text
  , stencilDefinitionKeywords :: ![Text]
  , stencilDefinitionAspect :: !StencilAspectPolicy
  , stencilDefinitionGeometry :: !StencilGeometryData
  , stencilDefinitionAttribution :: !ShapeAttribution
  }
  deriving stock (Eq, Ord, Show)

newtype StencilLibrary = StencilLibrary (Map StencilId StencilDefinition)
  deriving stock (Eq, Show)

data StencilLibraryError = DuplicateStencilDefinition !StencilId
  deriving stock (Eq, Show)

mkStencilLibrary
  :: [StencilDefinition]
  -> Either StencilLibraryError StencilLibrary
mkStencilLibrary =
  fmap StencilLibrary . foldl insertUnique (Right Map.empty)
  where
    insertUnique
      :: Either StencilLibraryError (Map StencilId StencilDefinition)
      -> StencilDefinition
      -> Either StencilLibraryError (Map StencilId StencilDefinition)
    insertUnique accumulated definition = do
      definitions <- accumulated
      let identity = stencilDefinitionId definition
      if Map.member identity definitions
        then Left (DuplicateStencilDefinition identity)
        else Right (Map.insert identity definition definitions)

stencilDefinitions :: StencilLibrary -> [StencilDefinition]
stencilDefinitions (StencilLibrary definitions) = Map.elems definitions

stencilDefinitionById
  :: StencilId
  -> StencilLibrary
  -> Maybe StencilDefinition
stencilDefinitionById identity (StencilLibrary definitions) =
  Map.lookup identity definitions
