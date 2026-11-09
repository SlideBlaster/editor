-- |
-- Module      : SlideBlaster.Catalog.Search
-- Description : Stable target-neutral catalog search and grouping.
module SlideBlaster.Catalog.Search
  ( searchCatalog
  , catalogSections
  , catalogFamilies
  ) where

import SlideBlaster.Catalog.Model
  ( CatalogFamily
  , ShapeCatalog
  , ShapePreset (..)
  , catalogFamilyText
  , catalogPresets
  )

import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text

-- | Case-folded label/category/keyword search in stable catalog order.
searchCatalog :: Text -> ShapeCatalog -> [ShapePreset]
searchCatalog query catalog
  | Text.null needle = NonEmpty.toList (catalogPresets catalog)
  | otherwise =
      filter matches (NonEmpty.toList (catalogPresets catalog))
  where
    needle = Text.toCaseFold (Text.strip query)
    matches preset =
      any
        (Text.isInfixOf needle . Text.toCaseFold)
        (shapePresetLabel preset : shapePresetKeywords preset)

-- | First-seen category sections for the panel/navigation layout.
catalogSections :: ShapeCatalog -> [(Text, NonEmpty ShapePreset)]
catalogSections catalog =
  foldl appendPreset [] (NonEmpty.toList (catalogPresets catalog))
  where
    appendPreset [] preset =
      [(shapePresetCategory preset, preset NonEmpty.:| [])]
    appendPreset ((name, entries) : remaining) preset
      | name == shapePresetCategory preset =
          (name, entries <> (preset NonEmpty.:| [])) : remaining
      | otherwise =
          (name, entries) : appendPreset remaining preset

-- | Family groups for the lazy palette. Named pinned families come first in
-- caller order; remaining families are sorted by their stable display text.
-- Presets retain catalog order within every family.
catalogFamilies
  :: [CatalogFamily]
  -> ShapeCatalog
  -> [(CatalogFamily, NonEmpty ShapePreset)]
catalogFamilies pinned catalog =
  pinnedGroups <> sortOn (catalogFamilyText . fst) remainingGroups
  where
    groups =
      foldl appendPreset [] (NonEmpty.toList (catalogPresets catalog))
    pinnedGroups =
      concatMap (matchingFamily groups) pinned
    remainingGroups =
      filter (\(family, _) -> family `notElem` pinned) groups

    matchingFamily [] _ = []
    matchingFamily (group@(family, _) : rest) wanted
      | family == wanted = [group]
      | otherwise = matchingFamily rest wanted

    appendPreset [] preset =
      [(shapePresetFamily preset, preset NonEmpty.:| [])]
    appendPreset ((family, entries) : remaining) preset
      | family == shapePresetFamily preset =
          (family, entries <> (preset NonEmpty.:| [])) : remaining
      | otherwise =
          (family, entries) : appendPreset remaining preset
