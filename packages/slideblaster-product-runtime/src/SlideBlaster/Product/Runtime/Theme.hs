{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.Theme
-- Description : Data themes (themes/<name>/theme.json) as the lowering sees them.
--
-- Themes are data, not code (design 3.4). Coordinates in @theme.json@ are slide
-- units (16x9, origin bottom-left, y up); 'regionBox' converts to the plan's
-- top-left y-down pixel space at 80 pixels per unit.
module SlideBlaster.Product.Runtime.Theme
  ( Theme (..)
  , Region (..)
  , Furniture (..)
  , Slides (..)
  , builtinTheme
  , parseTheme
  , unitScale
  , regionBox
  , themePlanSize
  , paletteColour
  ) where

import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific (toRealFloat)
import Data.Text (Text)

-- | A rectangle in theme units (y up, @y@ is the bottom edge).
data Region = Region
  { regionX :: !Double
  , regionY :: !Double
  , regionW :: !Double
  , regionH :: !Double
  , regionAlign :: !Text
  }
  deriving stock (Eq, Show)

data Slides = AllSlides | FirstSlide | NotFirstSlide
  deriving stock (Eq, Show)

-- | One deck-wide chrome item.
data Furniture = Furniture
  { furnitureKind :: !Text
  , furnitureSlides :: !Slides
  , furnitureRegion :: !Region
  , furnitureAsset :: !(Maybe Text)
  , furnitureText :: !(Maybe Text)
  , furnitureFill :: !(Maybe Text)
  , furniturePer :: !(Maybe Text)
  -- ^ @progress@ only: @\"section\"@ measures position within the current section
  }
  deriving stock (Eq, Show)

data Theme = Theme
  { themeName :: !Text
  , themeAspect :: !(Double, Double)
  , themePalette :: !(Map Text Text)
  , themeBodyFont :: !Text
  , themeMonoFont :: !Text
  , themeSizes :: !(Map Text Double)
  , themeRegions :: !(Map Text Region)
  , themeTitleSlide :: !(Map Text Region)
  , themeSectionSlide :: !(Map Text Region)
  , themeFurniture :: ![Furniture]
  }
  deriving stock (Eq, Show)

unitScale :: Double
unitScale = 80

themePlanSize :: Theme -> (Double, Double)
themePlanSize theme =
  (unitScale * unitHeight * fst (themeAspect theme) / snd (themeAspect theme), unitScale * unitHeight)

-- | Slide height in theme units; width follows the aspect ratio.
unitHeight :: Double
unitHeight = 9

-- | Convert to plan pixels: (x, y-down top, width, height).
regionBox :: Theme -> Region -> (Double, Double, Double, Double)
regionBox _ r =
  ( regionX r * unitScale
  , (unitHeight - regionY r - regionH r) * unitScale
  , regionW r * unitScale
  , regionH r * unitScale
  )

-- | Resolve a palette token (@accent@, @block.bg@) or pass through a literal colour.
paletteColour :: Theme -> Text -> Text
paletteColour theme token = Map.findWithDefault token token (themePalette theme)

mkRegion :: Double -> Double -> Double -> Double -> Region
mkRegion x y w h = Region x y w h "left"

-- | Built-in fallback when no theme file is present; mirrors @themes/default@.
builtinTheme :: Theme
builtinTheme =
  Theme
    { themeName = "default"
    , themeAspect = (16, 9)
    , themePalette =
        Map.fromList
          [ ("background", "#ffffff"), ("ink", "#1a1a2e"), ("muted", "#555555")
          , ("accent", "#4a90d9"), ("link", "#4a90d9"), ("codeBackground", "#f1f5f9")
          , ("rule", "#dddddd"), ("block.bg", "#e8f0fb"), ("block.title", "#4a90d9")
          , ("alert.bg", "#fdecea"), ("alert.title", "#c0392b")
          ]
    , themeBodyFont = "'Segoe UI', system-ui, -apple-system, sans-serif"
    , themeMonoFont = "'JetBrains Mono', 'Fira Code', ui-monospace, monospace"
    , themeSizes = Map.fromList [("title", 0.72), ("subtitle", 0.45), ("body", 0.4), ("small", 0.3), ("code", 0.3)]
    , themeRegions =
        Map.fromList
          [ ("title", mkRegion 0.9 7.35 14.2 1.15)
          , ("body", mkRegion 0.9 1.1 14.2 5.95)
          , ("footer", mkRegion 0.9 0.25 14.2 0.55)
          ]
    , themeTitleSlide =
        Map.fromList
          [ ("title", centred 1.6 4.7 12.8 1.5), ("subtitle", centred 1.6 3.7 12.8 0.8)
          , ("authors", centred 1.6 2.4 12.8 0.6), ("institute", centred 1.6 1.7 12.8 0.5)
          , ("date", centred 1.6 1.1 12.8 0.5)
          ]
    , themeSectionSlide =
        Map.fromList [("title", centred 1.6 4.2 12.8 1.5), ("subtitle", centred 1.6 3.2 12.8 0.8)]
    , themeFurniture =
        [ Furniture "rule" AllSlides (mkRegion 0 0 16 0.045) Nothing Nothing (Just "accent") Nothing
        , Furniture "page-number" NotFirstSlide (Region 14.4 0.25 1 0.5 "right") Nothing Nothing Nothing Nothing
        , Furniture "footer-text" NotFirstSlide (mkRegion 0.9 0.25 10 0.5) Nothing (Just "{{title}}") Nothing Nothing
        ]
    }
  where
    centred x y w h = Region x y w h "center"

-- | Parse @theme.json@. Missing optional fields fall back to the built-in theme.
parseTheme :: ByteString -> Either Text Theme
parseTheme bytes =
  case eitherDecodeStrict' bytes of
    Left problem -> Left (fromString' problem)
    Right (Object root) -> Right (fromObject root)
    Right _ -> Left "theme.json must be an object"
  where
    fromString' = Key.toText . Key.fromString

fromObject :: KeyMap.KeyMap Value -> Theme
fromObject root =
  Theme
    { themeName = textAt "name" (themeName builtinTheme)
    , themeAspect = aspect
    , themePalette = if Map.null palette then themePalette builtinTheme else palette
    , themeBodyFont = textIn fonts "body" (themeBodyFont builtinTheme)
    , themeMonoFont = textIn fonts "mono" (themeMonoFont builtinTheme)
    , themeSizes = Map.union (numberMap (objAt fonts "sizes")) (themeSizes builtinTheme)
    , themeRegions = Map.union (regionMap (objAt root "regions")) (themeRegions builtinTheme)
    , themeTitleSlide = Map.union (regionMap (objAt root "titleSlide")) (themeTitleSlide builtinTheme)
    , themeSectionSlide = Map.union (regionMap (objAt root "sectionSlide")) (themeSectionSlide builtinTheme)
    , themeFurniture = maybe (themeFurniture builtinTheme) (foldr (\v acc -> maybe acc (: acc) (furnitureOf v)) []) (arrayAt "furniture")
    }
  where
    fonts = objAt root "fonts"
    palette = flattenPalette (objAt root "palette")
    textAt key fallback = textIn root key fallback
    arrayAt key =
      case KeyMap.lookup (Key.fromText key) root of
        Just (Array items) -> Just (foldr (:) [] items)
        _ -> Nothing
    aspect =
      case KeyMap.lookup "aspect" root of
        Just (Array items) | [Number w, Number h] <- foldr (:) [] items -> (toRealFloat w, toRealFloat h)
        _ -> themeAspect builtinTheme

objAt :: KeyMap.KeyMap Value -> Text -> KeyMap.KeyMap Value
objAt obj key =
  case KeyMap.lookup (Key.fromText key) obj of
    Just (Object inner) -> inner
    _ -> KeyMap.empty

textIn :: KeyMap.KeyMap Value -> Text -> Text -> Text
textIn obj key fallback =
  case KeyMap.lookup (Key.fromText key) obj of
    Just (String value) -> value
    _ -> fallback

numIn :: KeyMap.KeyMap Value -> Text -> Double -> Double
numIn obj key fallback =
  case KeyMap.lookup (Key.fromText key) obj of
    Just (Number value) -> toRealFloat value
    _ -> fallback

numberMap :: KeyMap.KeyMap Value -> Map Text Double
numberMap obj = Map.fromList [(Key.toText k, toRealFloat n) | (k, Number n) <- KeyMap.toList obj]

flattenPalette :: KeyMap.KeyMap Value -> Map Text Text
flattenPalette obj = Map.fromList (concatMap entry (KeyMap.toList obj))
  where
    entry (key, String colour) = [(Key.toText key, colour)]
    entry (key, Object inner) =
      [(Key.toText key <> "." <> Key.toText k, c) | (k, String c) <- KeyMap.toList inner]
    entry _ = []

regionOf :: KeyMap.KeyMap Value -> Region
regionOf obj =
  Region (numIn obj "x" 0) (numIn obj "y" 0) (numIn obj "w" 0) (numIn obj "h" 0) (textIn obj "align" "left")

regionMap :: KeyMap.KeyMap Value -> Map Text Region
regionMap obj = Map.fromList [(Key.toText k, regionOf inner) | (k, Object inner) <- KeyMap.toList obj]

furnitureOf :: Value -> Maybe Furniture
furnitureOf (Object obj) =
  Just
    Furniture
      { furnitureKind = textIn obj "kind" ""
      , furnitureSlides = case textIn obj "slides" "all" of
          "first" -> FirstSlide
          "not-first" -> NotFirstSlide
          _ -> AllSlides
      , furnitureRegion = regionOf obj
      , furnitureAsset = optText "asset"
      , furnitureText = optText "text"
      , furnitureFill = optText "fill"
      , furniturePer = optText "per"
      }
  where
    optText key = case KeyMap.lookup (Key.fromText key) obj of
      Just (String value) -> Just value
      _ -> Nothing
furnitureOf _ = Nothing
