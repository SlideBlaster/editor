{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Canvas.Theme
-- Description : Structured style, master-region, and furniture theme layers.
--
-- Theme styles are typed data. Master regions are soft creation/snap guides and
-- never own or reflow content. Furniture is target-neutral chrome that remains
-- distinct from authored picture objects.
module SlideBlaster.Canvas.Theme
  ( Palette
  , palette
  , paletteEntries
  , TypeScale
  , typeScale
  , typeScaleEntries
  , ThemeStyle (..)
  , ListMarkerStyle (..)
  , nodeRolePatch
  , connectorRolePatch
  , PropertyResolutionError (..)
  , resolveNodeProperties
  , resolveNodePropertiesWithOverrides
  , MasterRegion (..)
  , AnchorAttachment (..)
  , MasterAnchor (..)
  , MasterLayout
  , MasterLayoutError (..)
  , mkMasterLayout
  , emptyMasterLayout
  , masterRegions
  , masterAnchors
  , resolveMasterAnchors
  , Anchor9 (..)
  , SafeArea (..)
  , PageNumberFormat (..)
  , PageNumberFurniture (..)
  , LogoFurniture (..)
  , BandPosition (..)
  , BandSlots (..)
  , BandFurniture (..)
  , Furniture (..)
  , Theme (..)
  , defaultTheme
  ) where

import SlideBlaster.Canvas.Content (Content)
import SlideBlaster.Syntax.Surface (Dialect (Html))
import SlideBlaster.Canvas.Geometry
  ( CanvasUnit
  , Fraction
  , Point
  , RelativePoint
  , RelativeRect
  , Size
  , addUnits
  , canvasUnit
  , fractionValue
  , point
  , relativeRectBottom
  , relativeRectHeight
  , relativeRectLeft
  , relativeRectWidth
  , resolveRelativePoint
  , scaleUnit
  , sizeHeight
  , sizeWidth
  , zeroFraction
  )
import SlideBlaster.Canvas.Identifier
  ( AnchorId
  , AssetId
  , FurnitureId
  , RegionId
  , RoleId
  , ThemeId
  , defaultRoleId
  , defaultThemeId
  )
import SlideBlaster.Canvas.Property
  ( Colour (RGB)
  , ConnectorPropertyPatch
  , FontSize
  , NodeProperties (nodeRole)
  , NodePropertyPatch (nodePatchRole)
  , applyNodePropertyPatch
  , defaultNodeProperties
  , emptyConnectorPropertyPatch
  , emptyNodePropertyPatch
  , mergeNodePropertyPatch
  )

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Maybe (fromMaybe)

-- | Named theme colours.
newtype Palette = Palette (Map Text Colour)
  deriving stock (Eq, Show)

palette :: [(Text, Colour)] -> Palette
palette = Palette . Map.fromList

paletteEntries :: Palette -> [(Text, Colour)]
paletteEntries (Palette entries) = Map.toAscList entries

-- | Named typography sizes.
newtype TypeScale = TypeScale (Map Text FontSize)
  deriving stock (Eq, Show)

typeScale :: [(Text, FontSize)] -> TypeScale
typeScale = TypeScale . Map.fromList

typeScaleEntries :: TypeScale -> [(Text, FontSize)]
typeScaleEntries (TypeScale entries) = Map.toAscList entries

-- | Theme style defaults. Explicit object patches are applied later.
data ThemeStyle = ThemeStyle
  { themePalette :: !Palette
  , themeTypeScale :: !TypeScale
  , themeDefaultRole :: !RoleId
  , themeBaseNodePatch :: !NodePropertyPatch
  , themeNodeRoles :: !(Map RoleId NodePropertyPatch)
  , themeBaseConnectorPatch :: !ConnectorPropertyPatch
  , themeConnectorRoles :: !(Map RoleId ConnectorPropertyPatch)
  , themeListMarkers :: !ListMarkerStyle
  , themeNodeDistance :: !CanvasUnit
  , -- | Which notation to write a new construct in when nothing else settles it.
    --
    -- Authored text is one mixed language with no outermost notation, so a
    -- construct created inside an existing one takes that one's language and a
    -- construct wrapping content of a single language takes that. Neither applies
    -- to an empty text box: nobody can know what a box with no content is written
    -- in, so the theme says.
    --
    -- It is deliberately a theme setting rather than a document property. A file
    -- has no dialect to report, and asking the interface would let it answer
    -- differently from one gesture to the next.
    themeDefaultDialect :: !Dialect
  }
  deriving stock (Eq, Show)

-- | Theme-owned list marker spelling. Ordered markers use a format-neutral
-- pattern such as @"%n."@; adapters decide how to escape it.
data ListMarkerStyle = ListMarkerStyle
  { unorderedListMarker :: !Text
  , orderedListMarkerPattern :: !Text
  }
  deriving stock (Eq, Ord, Show)

nodeRolePatch :: RoleId -> ThemeStyle -> Maybe NodePropertyPatch
nodeRolePatch role style = Map.lookup role (themeNodeRoles style)

connectorRolePatch :: RoleId -> ThemeStyle -> Maybe ConnectorPropertyPatch
connectorRolePatch role style = Map.lookup role (themeConnectorRoles style)

data PropertyResolutionError
  = UnknownThemeRole !RoleId
  deriving stock (Eq, Show)

-- | Resolve fallback < theme base < selected role < creation preset < explicit.
--
-- The preset is an ordinary patch supplied by a catalog or source adapter;
-- this function has no dependency on either kind of producer.
resolveNodeProperties
  :: ThemeStyle
  -> NodePropertyPatch
  -> NodePropertyPatch
  -> Either PropertyResolutionError NodeProperties
resolveNodeProperties style preset explicit =
  resolveNodePropertiesWithOverrides style preset [] explicit

-- | Resolve node properties with additional low-to-high presentation/frame
-- patches between the creation preset and final authored object values.
resolveNodePropertiesWithOverrides
  :: ThemeStyle
  -> NodePropertyPatch
  -> [NodePropertyPatch]
  -> NodePropertyPatch
  -> Either PropertyResolutionError NodeProperties
resolveNodePropertiesWithOverrides style preset intermediate explicit = do
  rolePatch <- selectedRolePatch style selectedRole
  let combined =
        foldl
          mergeNodePropertyPatch
          ( mergeNodePropertyPatch
              (mergeNodePropertyPatch (themeBaseNodePatch style) rolePatch)
              preset
          )
          intermediate
      resolvedBeforeExplicit =
        applyNodePropertyPatch
          (defaultNodeProperties (themeDefaultRole style))
          combined
      resolved =
        applyNodePropertyPatch resolvedBeforeExplicit explicit
  Right resolved {nodeRole = selectedRole}
  where
    selectedRole =
      fromMaybe
        (themeDefaultRole style)
        ( nodePatchRole explicit
            `orElse` latestIntermediateRole intermediate
            `orElse` nodePatchRole preset
        )

selectedRolePatch
  :: ThemeStyle
  -> RoleId
  -> Either PropertyResolutionError NodePropertyPatch
selectedRolePatch style role =
  case nodeRolePatch role style of
    Just patch -> Right patch
    Nothing
      | role == themeDefaultRole style -> Right emptyNodePropertyPatch
      | otherwise -> Left (UnknownThemeRole role)

orElse :: Maybe value -> Maybe value -> Maybe value
orElse left right =
  case left of
    Just value -> Just value
    Nothing -> right

latestIntermediateRole :: [NodePropertyPatch] -> Maybe RoleId
latestIntermediateRole =
  foldl
    (\selected patch -> nodePatchRole patch `orElse` selected)
    Nothing

-- | A relative soft guide and creation-only defaults.
data MasterRegion = MasterRegion
  { masterRegionId :: !RegionId
  , masterRegionName :: !Text
  , masterRegionRect :: !RelativeRect
  , masterRegionDefaultRole :: !(Maybe RoleId)
  , masterRegionDefaultAnchor :: !(Maybe Anchor9)
  }
  deriving stock (Eq, Show)

-- | Optional attachment to a region slot. 'FreeAnchor' uses the stored free
-- point; an invalid/missing region also falls back to it deterministically.
data AnchorAttachment
  = FreeAnchor
  | AttachedToRegion !RegionId !Anchor9
  deriving stock (Eq, Ord, Show)

data MasterAnchor = MasterAnchor
  { masterAnchorId :: !AnchorId
  , masterAnchorName :: !Text
  , masterAnchorFreePoint :: !RelativePoint
  , masterAnchorAttachment :: !AnchorAttachment
  }
  deriving stock (Eq, Show)

data MasterLayout = MasterLayout ![MasterRegion] ![MasterAnchor]
  deriving stock (Eq, Show)

data MasterLayoutError
  = DuplicateMasterRegion !RegionId
  | DuplicateMasterAnchor !AnchorId
  deriving stock (Eq, Show)

mkMasterLayout
  :: [MasterRegion]
  -> [MasterAnchor]
  -> Either MasterLayoutError MasterLayout
mkMasterLayout regions anchors = do
  validateUnique
    masterRegionId
    DuplicateMasterRegion
    Set.empty
    regions
  validateUnique
    masterAnchorId
    DuplicateMasterAnchor
    Set.empty
    anchors
  Right (MasterLayout regions anchors)

emptyMasterLayout :: MasterLayout
emptyMasterLayout = MasterLayout [] []

masterRegions :: MasterLayout -> [MasterRegion]
masterRegions (MasterLayout regions _) = regions

masterAnchors :: MasterLayout -> [MasterAnchor]
masterAnchors (MasterLayout _ anchors) = anchors

-- | Resolve every editor-only anchor into the canvas' y-up slide space.
resolveMasterAnchors :: Size -> MasterLayout -> [(AnchorId, Point)]
resolveMasterAnchors slideSize layout =
  [ (masterAnchorId anchor, resolveAnchor anchor)
  | anchor <- masterAnchors layout
  ]
  where
    regionIndex =
      Map.fromList
        [ (masterRegionId region, masterRegionRect region)
        | region <- masterRegions layout
        ]
    resolveAnchor anchor =
      case masterAnchorAttachment anchor of
        FreeAnchor ->
          resolveRelativePoint slideSize (masterAnchorFreePoint anchor)
        AttachedToRegion regionIdentity slot ->
          case Map.lookup regionIdentity regionIndex of
            Nothing ->
              resolveRelativePoint slideSize (masterAnchorFreePoint anchor)
            Just rectangle -> pointAtRelativeRect slot rectangle
    pointAtRelativeRect slot rectangle =
      point
        (slotX slot rectangle)
        (slotY slot rectangle)
    slotX slot rectangle =
      let left =
            scaleUnit
              (fractionValue (relativeRectLeft rectangle))
              (sizeWidth slideSize)
          width =
            scaleUnit
              (fractionValue (relativeRectWidth rectangle))
              (sizeWidth slideSize)
       in case slot of
            TopLeft -> left
            MiddleLeft -> left
            BottomLeft -> left
            TopCentre -> addUnits left (scaleUnit (1 / 2) width)
            MiddleCentre -> addUnits left (scaleUnit (1 / 2) width)
            BottomCentre -> addUnits left (scaleUnit (1 / 2) width)
            TopRight -> addUnits left width
            MiddleRight -> addUnits left width
            BottomRight -> addUnits left width
    slotY slot rectangle =
      let bottom =
            scaleUnit
              (fractionValue (relativeRectBottom rectangle))
              (sizeHeight slideSize)
          height =
            scaleUnit
              (fractionValue (relativeRectHeight rectangle))
              (sizeHeight slideSize)
       in case slot of
            BottomLeft -> bottom
            BottomCentre -> bottom
            BottomRight -> bottom
            MiddleLeft -> addUnits bottom (scaleUnit (1 / 2) height)
            MiddleCentre -> addUnits bottom (scaleUnit (1 / 2) height)
            MiddleRight -> addUnits bottom (scaleUnit (1 / 2) height)
            TopLeft -> addUnits bottom height
            TopCentre -> addUnits bottom height
            TopRight -> addUnits bottom height

validateUnique
  :: Ord identity
  => (value -> identity)
  -> (identity -> failure)
  -> Set identity
  -> [value]
  -> Either failure ()
validateUnique identify duplicate = go
  where
    go _ [] = Right ()
    go seen (value : remaining)
      | Set.member identity seen = Left (duplicate identity)
      | otherwise = go (Set.insert identity seen) remaining
      where
        identity = identify value

-- | Furniture placement slot against the safe area.
data Anchor9
  = TopLeft
  | TopCentre
  | TopRight
  | MiddleLeft
  | MiddleCentre
  | MiddleRight
  | BottomLeft
  | BottomCentre
  | BottomRight
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Relative insets from the current slide box.
data SafeArea = SafeArea
  { safeAreaLeft :: !Fraction
  , safeAreaTop :: !Fraction
  , safeAreaRight :: !Fraction
  , safeAreaBottom :: !Fraction
  }
  deriving stock (Eq, Show)

data PageNumberFormat
  = PageNumberOnly
  | PageNumberOfTotal
  | NamedPageNumberFormat !Text
  deriving stock (Eq, Ord, Show)

data PageNumberFurniture = PageNumberFurniture
  { pageNumberFurnitureId :: !FurnitureId
  , pageNumberFormat :: !PageNumberFormat
  , pageNumberAnchor :: !Anchor9
  , pageNumberRole :: !RoleId
  }
  deriving stock (Eq, Show)

data LogoFurniture = LogoFurniture
  { logoFurnitureId :: !FurnitureId
  , logoAsset :: !AssetId
  , logoAnchor :: !Anchor9
  , logoSize :: !Size
  }
  deriving stock (Eq, Show)

data BandPosition = HeaderBand | FooterBand
  deriving stock (Eq, Ord, Show)

data BandSlots = BandSlots
  { bandLeft :: !(Maybe Content)
  , bandCentre :: !(Maybe Content)
  , bandRight :: !(Maybe Content)
  }
  deriving stock (Eq, Show)

data BandFurniture = BandFurniture
  { bandFurnitureId :: !FurnitureId
  , bandPosition :: !BandPosition
  , bandExtent :: !Fraction
  , bandSlots :: !BandSlots
  , bandRole :: !RoleId
  }
  deriving stock (Eq, Show)

-- | Structured deck-wide chrome.
data Furniture
  = PageNumber !PageNumberFurniture
  | Logo !LogoFurniture
  | Band !BandFurniture
  deriving stock (Eq, Show)

data Theme = Theme
  { themeIdentifier :: !ThemeId
  , themeName :: !Text
  , themeDescription :: !Text
  , themeStyle :: !ThemeStyle
  , themeMasterLayout :: !MasterLayout
  , themeSafeArea :: !SafeArea
  , themeFurniture :: ![Furniture]
  }
  deriving stock (Eq, Show)

-- | Minimal deterministic theme for tests and unthemed documents.
defaultTheme :: Theme
defaultTheme =
  Theme
    { themeIdentifier = defaultThemeId
    , themeName = "Default"
    , themeDescription = "Target-neutral fallback theme"
    , themeStyle =
        ThemeStyle
          { themePalette =
              palette
                [ ("background", RGB 255 255 255)
                , ("ink", RGB 24 24 27)
                , ("accent", RGB 79 70 229)
                ]
          , themeTypeScale = typeScale []
          , themeDefaultRole = defaultRoleId
          , themeBaseNodePatch = emptyNodePropertyPatch
          , themeNodeRoles =
              Map.singleton defaultRoleId emptyNodePropertyPatch
          , themeBaseConnectorPatch = emptyConnectorPropertyPatch
          , themeConnectorRoles =
              Map.singleton defaultRoleId emptyConnectorPropertyPatch
          , themeListMarkers =
              ListMarkerStyle
                { unorderedListMarker = "•"
                , orderedListMarkerPattern = "%n."
                }
          , themeNodeDistance = canvasUnit (1 / 2)
          , -- HTML, because it is the most expressive of the three: it alone covers
            -- underline, colour and arbitrary inline styling, so a construct created
            -- where nothing settles the notation can always be written. The format
            -- specifies this default and that it is configurable.
            themeDefaultDialect = Html
          }
    , themeMasterLayout = emptyMasterLayout
    , themeSafeArea =
        SafeArea
          { safeAreaLeft = zeroFraction
          , safeAreaTop = zeroFraction
          , safeAreaRight = zeroFraction
          , safeAreaBottom = zeroFraction
          }
    , themeFurniture = []
    }
