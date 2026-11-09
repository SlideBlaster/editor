{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.App.Live
-- Description : Pure interactive authoring state for the browser parity loop.
--
-- This module joins the real catalog, canvas, theme, snapping, and direct
-- render-outline contracts into one revision-fenced state transition seam.
-- It is intentionally pure and target-neutral: the Wasm host keeps one value,
-- while a native composition can run the same commands. This state is not a
-- substitute for source authority; persistence remains disabled until an
-- accepted format adapter can verify the corresponding source patch.
module SlideBlaster.App.Live
  ( LiveRevision
  , liveRevisionToWord64
  , LiveAuthoring
  , LiveNode
  , LiveAuthoringError (..)
  , newLiveAuthoring
  , liveAuthoringRevision
  , liveAuthoringTheme
  , liveAuthoringNodes
  , liveAuthoringSelection
  , liveAuthoringGuides
  , liveAuthoringCanUndo
  , liveAuthoringCanRedo
  , liveAuthoringHasThemePreview
  , loadLiveDrawIOCatalog
  , liveCatalogFamilies
  , searchLiveCatalog
  , liveResolvePresetOutlines
  , insertLiveShape
  , selectLiveNode
  , moveLiveNode
  , setLivePaletteColour
  , setLiveThemeName
  , setLiveNodeDistance
  , previewLivePaletteColour
  , previewLiveThemeName
  , previewLiveNodeDistance
  , cancelLiveThemePreview
  , undoLiveAuthoring
  , redoLiveAuthoring
  , liveNodeSemantic
  , liveNodeBox
  , liveNodeResolvedProperties
  , liveResolveNodeOutlines
  ) where

import SlideBlaster.Canvas
  ( AlignmentTarget (ThemeRegionAlignment)
  , Axis (..)
  , AxisReference (..)
  , BindingConfigError
  , BorderPort (Centre)
  , Box
  , CanvasUnit
  , Colour
  , DragMode
  , DragRequest (..)
  , GeometryError
  , MasterRegion (..)
  , Node (..)
  , NodeAccessibility (DecorativeNode)
  , NodeId
  , NodeProperties
  , NodeSeed (..)
  , OutlineRef (..)
  , PeerBox (..)
  , Placement (AbsolutePlacement)
  , Point
  , PointReference (..)
  , PropertyResolutionError
  , SnapConfigError
  , SnapGuide
  , Size
  , StencilId
  , Theme (..)
  , ThemeStyle (..)
  , defaultTheme
  , dragGuides
  , dragResolvedCenter
  , dragResolvedPlacement
  , box
  , boxSize
  , canvasUnit
  , canvasUnitFromInteger
  , canvasUnitValue
  , addUnits
  , emptyNodePropertyPatch
  , mkBindingConfig
  , mkSize
  , mkSnapConfigWithPointReferences
  , masterRegions
  , nodeId
  , palette
  , paletteEntries
  , point
  , relativeRectBottom
  , relativeRectHeight
  , relativeRectLeft
  , relativeRectWidth
  , resolveDrag
  , resolveMasterAnchors
  , resolveNodeProperties
  , scaleUnit
  , fractionValue
  , sizeHeight
  , sizeWidth
  )
import SlideBlaster.Catalog
  ( CatalogFamily
  , CuratedCatalogError
  , DrawIOCatalogError
  , ShapeCatalog
  , ShapeCatalogError
  , ShapeId
  , ShapePreset
  , StencilDefinition
  , StencilGeometryData (..)
  , StencilLibrary
  , StencilLibraryError
  , catalogFamilies
  , catalogPresetById
  , curatedShapeCatalog
  , decodeDrawIOCatalog
  , drawIOShapeCatalog
  , drawIOStencilLibrary
  , mergeShapeCatalogs
  , mkStencilLibrary
  , searchCatalog
  , shapePresetFamily
  , shapePresetDropSize
  , shapePresetNodeSeed
  , shapePresetOutline
  , stencilDefinitionById
  , stencilDefinitionGeometry
  )
import SlideBlaster.Render
  ( OutlineLoweringError
  , RenderOutline
  , lowerOutlineRef
  )

import Data.ByteString (ByteString)
import Data.Char (isControl)
import Data.List.NonEmpty (NonEmpty)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)

newtype LiveRevision = LiveRevision Word64
  deriving stock (Eq, Ord, Show)

liveRevisionToWord64 :: LiveRevision -> Word64
liveRevisionToWord64 (LiveRevision value) = value

data LiveDocument = LiveDocument
  !Theme
  ![LiveNode]
  !Word64
  deriving stock (Eq, Show)

data LiveAuthoring = LiveAuthoring
  !LiveRevision
  !ShapeCatalog
  !StencilLibrary
  !LiveDocument
  !(Maybe NodeId)
  ![SnapGuide]
  ![LiveDocument]
  ![LiveDocument]
  !(Maybe LiveDocument)
  deriving stock (Eq, Show)

data LiveNode = LiveNode
  !Node
  !Box
  deriving stock (Eq, Show)

data LiveAuthoringError
  = LiveCuratedCatalogInvalid !CuratedCatalogError
  | LiveDrawIOCatalogInvalid !DrawIOCatalogError
  | LiveCatalogMergeInvalid !ShapeCatalogError
  | LiveStencilLibraryInvalid !StencilLibraryError
  | LiveStaleRevision !LiveRevision !LiveRevision
  | LiveRevisionExhausted
  | LiveShapeMissing !ShapeId
  | LiveNodeIdentityExhausted
  | LiveNodeMissing !NodeId
  | LiveNodePropertiesInvalid !PropertyResolutionError
  | LiveSlideGeometryInvalid !GeometryError
  | LiveSnapConfigurationInvalid !SnapConfigError
  | LiveBindingConfigurationInvalid !BindingConfigError
  | LiveOutlineInvalid !OutlineLoweringError
  | LivePaletteKeyInvalid !Text
  | LiveThemeNameInvalid
  | LiveNodeDistanceNegative !CanvasUnit
  | LiveUndoBoundary
  | LiveRedoBoundary
  deriving stock (Eq, Show)

newLiveAuthoring :: Either LiveAuthoringError LiveAuthoring
newLiveAuthoring = do
  catalog <-
    mapLeft LiveCuratedCatalogInvalid curatedShapeCatalog
  library <-
    mapLeft LiveStencilLibraryInvalid (mkStencilLibrary [])
  Right
    ( LiveAuthoring
        (LiveRevision 0)
        catalog
        library
        (LiveDocument defaultTheme [] 1)
        Nothing
        []
        []
        []
        Nothing
    )

liveAuthoringRevision :: LiveAuthoring -> LiveRevision
liveAuthoringRevision (LiveAuthoring revision _ _ _ _ _ _ _ _) = revision

liveAuthoringTheme :: LiveAuthoring -> Theme
liveAuthoringTheme authoring =
  liveDocumentTheme (liveCurrentDocument authoring)

liveAuthoringNodes :: LiveAuthoring -> [LiveNode]
liveAuthoringNodes authoring =
  liveDocumentNodes (liveCurrentDocument authoring)

liveAuthoringSelection :: LiveAuthoring -> Maybe NodeId
liveAuthoringSelection (LiveAuthoring _ _ _ _ selection _ _ _ _) = selection

liveAuthoringGuides :: LiveAuthoring -> [SnapGuide]
liveAuthoringGuides (LiveAuthoring _ _ _ _ _ guides _ _ _) = guides

liveAuthoringCanUndo :: LiveAuthoring -> Bool
liveAuthoringCanUndo (LiveAuthoring _ _ _ _ _ _ past _ _) =
  not (null past)

liveAuthoringCanRedo :: LiveAuthoring -> Bool
liveAuthoringCanRedo (LiveAuthoring _ _ _ _ _ _ _ future _) =
  not (null future)

-- | Whether the current theme projection contains uncommitted preview edits.
liveAuthoringHasThemePreview :: LiveAuthoring -> Bool
liveAuthoringHasThemePreview authoring =
  case liveThemePreviewOrigin authoring of
    Nothing -> False
    Just _ -> True

loadLiveDrawIOCatalog
  :: ByteString
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
loadLiveDrawIOCatalog bytes authoring = do
  imported <-
    mapLeft LiveDrawIOCatalogInvalid (decodeDrawIOCatalog bytes)
  combined <-
    mapLeft
      LiveCatalogMergeInvalid
      ( mergeShapeCatalogs
          (liveShapeCatalog authoring)
          (drawIOShapeCatalog imported)
      )
  Right
    (replaceCatalog combined (drawIOStencilLibrary imported) authoring)

liveCatalogFamilies :: LiveAuthoring -> [(CatalogFamily, Int)]
liveCatalogFamilies authoring =
  [ (family, length presets)
  | (family, presets) <-
      catalogFamilies [] (liveShapeCatalog authoring)
  ]

searchLiveCatalog
  :: Text
  -> Maybe CatalogFamily
  -> Int
  -> LiveAuthoring
  -> [ShapePreset]
searchLiveCatalog query wantedFamily resultLimit authoring =
  take boundedMaximum
    (filter matchesFamily (searchCatalog query (liveShapeCatalog authoring)))
  where
    boundedMaximum = max 0 (min 300 resultLimit)
    matchesFamily preset =
      case wantedFamily of
        Nothing -> True
        Just family -> family == shapePresetFamily preset

liveResolvePresetOutlines
  :: LiveAuthoring
  -> ShapePreset
  -> Either LiveAuthoringError (NonEmpty RenderOutline)
liveResolvePresetOutlines authoring preset =
  mapLeft LiveOutlineInvalid
    ( lowerOutlineRef
        (resolveStencil (liveStencilLibrary authoring))
        ( box
            (point (canvasUnitFromInteger 0) (canvasUnitFromInteger 0))
            (shapePresetDropSize preset)
        )
        (shapePresetOutline preset)
    )

insertLiveShape
  :: LiveRevision
  -> ShapeId
  -> Point
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
insertLiveShape expected identity centre authoring = do
  ensureCurrent expected authoring
  preset <-
    maybe
      (Left (LiveShapeMissing identity))
      Right
      (catalogPresetById identity (liveShapeCatalog authoring))
  _ <- liveResolvePresetOutlines authoring preset
  let document = liveCurrentDocument authoring
      nextIdentity = liveDocumentNextNodeId document
  if nextIdentity == maxBound
    then Left LiveNodeIdentityExhausted
    else do
      semanticIdentity <-
        maybe
          (Left LiveNodeIdentityExhausted)
          Right
          (nodeId ("shape-" <> Text.pack (show nextIdentity)))
      let seed = shapePresetNodeSeed preset
          semantic =
            Node
              { nodeIdentifier = semanticIdentity
              , nodePlacement = AbsolutePlacement centre Centre
              , nodeOutline = nodeSeedOutline seed
              , nodeContent = nodeSeedContent seed
              , nodePropertyOverrides = nodeSeedProperties seed
              , nodeAnimationRefs = []
              , nodeAccessibility = DecorativeNode
              }
          liveNode =
            LiveNode semantic (box centre (shapePresetDropSize preset))
          successor =
            LiveDocument
              (liveDocumentTheme document)
              (liveDocumentNodes document <> [liveNode])
              (nextIdentity + 1)
      commitDocument successor (Just semanticIdentity) [] authoring

selectLiveNode
  :: Maybe NodeId
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
selectLiveNode selection authoring =
  case selection of
    Nothing -> Right (setTransientSelection Nothing [] authoring)
    Just identity ->
      case findLiveNode identity (liveAuthoringNodes authoring) of
        Nothing -> Left (LiveNodeMissing identity)
        Just _ ->
          Right (setTransientSelection (Just identity) [] authoring)

moveLiveNode
  :: LiveRevision
  -> NodeId
  -> Point
  -> DragMode
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
moveLiveNode expected identity proposedCentre mode authoring = do
  ensureCurrent expected authoring
  dragged <-
    maybe
      (Left (LiveNodeMissing identity))
      Right
      (findLiveNode identity (liveAuthoringNodes authoring))
  slideSize <- liveSlideSize
  snapConfig <-
    mapLeft
      LiveSnapConfigurationInvalid
      ( mkSnapConfigWithPointReferences
          (canvasUnit (3 / 20))
          (Just (canvasUnit (1 / 2)))
          slideSize
          (themeAxisReferences slideSize (liveAuthoringTheme authoring))
          (themePointReferences slideSize (liveAuthoringTheme authoring))
      )
  bindingConfig <-
    case mkBindingConfig (canvasUnit (1 / 5)) (canvasUnit (3 / 2)) of
      Left failure -> Left (LiveBindingConfigurationInvalid failure)
      Right value -> Right value
  let proposed = box proposedCentre (boxSize (liveNodeBox dragged))
      peers =
        [ PeerBox
            (nodeIdentifier (liveNodeSemantic peer))
            (liveNodeBox peer)
        | peer <- liveAuthoringNodes authoring
        , nodeIdentifier (liveNodeSemantic peer) /= identity
        ]
      resolution =
        resolveDrag
          DragRequest
            { dragNodeIdentity = identity
            , dragExcludedBindingTargets = Set.empty
            , dragMode = mode
            , dragProposedBox = proposed
            , dragPeers = peers
            , dragSnapConfig = snapConfig
            , dragBindingConfig = bindingConfig
            }
      moved =
        LiveNode
          ( (liveNodeSemantic dragged)
              { nodePlacement =
                  dragResolvedPlacement resolution
              }
          )
          ( box
              (dragResolvedCenter resolution)
              (boxSize (liveNodeBox dragged))
          )
  updatedNodes <-
    replaceLiveNode identity moved (liveAuthoringNodes authoring)
  let nextDocument =
        LiveDocument
          (liveAuthoringTheme authoring)
          updatedNodes
          (liveDocumentNextNodeId (liveCurrentDocument authoring))
  commitDocument
    nextDocument
    (Just identity)
    (dragGuides resolution)
    authoring

setLivePaletteColour
  :: LiveRevision
  -> Text
  -> Colour
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
setLivePaletteColour expected rawKey colour authoring = do
  ensureCurrent expected authoring
  let key = Text.strip rawKey
  if Text.null key || Text.any isControl key
    then Left (LivePaletteKeyInvalid rawKey)
    else
      let theme = liveAuthoringTheme authoring
          style = themeStyle theme
          entries =
            (key, colour)
              : filter ((/= key) . fst) (paletteEntries (themePalette style))
          nextTheme =
            theme
              { themeStyle =
                  style {themePalette = palette entries}
              }
       in commitTheme nextTheme authoring

setLiveThemeName
  :: LiveRevision
  -> Text
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
setLiveThemeName expected rawName authoring = do
  ensureCurrent expected authoring
  let name = Text.strip rawName
  if Text.null name || Text.any isControl name
    then Left LiveThemeNameInvalid
    else
      commitTheme
        ((liveAuthoringTheme authoring) {themeName = name})
        authoring

setLiveNodeDistance
  :: LiveRevision
  -> CanvasUnit
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
setLiveNodeDistance expected distance authoring = do
  ensureCurrent expected authoring
  if canvasUnitValue distance < 0
    then Left (LiveNodeDistanceNegative distance)
    else
      let theme = liveAuthoringTheme authoring
          style = themeStyle theme
          nextTheme =
            theme
              { themeStyle =
                  style {themeNodeDistance = distance}
              }
       in commitTheme nextTheme authoring

-- | Preview a palette edit without advancing revision or source history.
previewLivePaletteColour
  :: LiveRevision
  -> Text
  -> Colour
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
previewLivePaletteColour expected rawKey colour authoring = do
  ensureCurrent expected authoring
  let key = Text.strip rawKey
  if Text.null key || Text.any isControl key
    then Left (LivePaletteKeyInvalid rawKey)
    else
      let theme = liveAuthoringTheme authoring
          style = themeStyle theme
          entries =
            (key, colour)
              : filter ((/= key) . fst) (paletteEntries (themePalette style))
          nextTheme =
            theme
              { themeStyle =
                  style {themePalette = palette entries}
              }
       in Right (previewTheme nextTheme authoring)

-- | Preview a theme-name edit without advancing revision or source history.
previewLiveThemeName
  :: LiveRevision
  -> Text
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
previewLiveThemeName expected rawName authoring = do
  ensureCurrent expected authoring
  let name = Text.strip rawName
  if Text.null name || Text.any isControl name
    then Left LiveThemeNameInvalid
    else
      Right
        ( previewTheme
            ((liveAuthoringTheme authoring) {themeName = name})
            authoring
        )

-- | Preview node-distance changes without creating one history item per input.
previewLiveNodeDistance
  :: LiveRevision
  -> CanvasUnit
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
previewLiveNodeDistance expected distance authoring = do
  ensureCurrent expected authoring
  if canvasUnitValue distance < 0
    then Left (LiveNodeDistanceNegative distance)
    else
      let theme = liveAuthoringTheme authoring
          style = themeStyle theme
          nextTheme =
            theme
              { themeStyle =
                  style {themeNodeDistance = distance}
              }
       in Right (previewTheme nextTheme authoring)

-- | Discard the active theme preview without changing revision or history.
cancelLiveThemePreview :: LiveAuthoring -> LiveAuthoring
cancelLiveThemePreview authoring =
  case liveThemePreviewOrigin authoring of
    Nothing -> authoring
    Just origin ->
      LiveAuthoring
        (liveAuthoringRevision authoring)
        (liveShapeCatalog authoring)
        (liveStencilLibrary authoring)
        origin
        (selectionIfPresent (liveAuthoringSelection authoring) origin)
        []
        (livePastDocuments authoring)
        (liveFutureDocuments authoring)
        Nothing

undoLiveAuthoring
  :: LiveRevision
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
undoLiveAuthoring expected authoring = do
  ensureCurrent expected authoring
  case livePastDocuments authoring of
    [] -> Left LiveUndoBoundary
    previous : remaining -> do
      revision <- advanceRevision (liveAuthoringRevision authoring)
      Right
        ( LiveAuthoring
            revision
            (liveShapeCatalog authoring)
            (liveStencilLibrary authoring)
            previous
            (selectionIfPresent (liveAuthoringSelection authoring) previous)
            []
            remaining
            (liveCurrentDocument authoring : liveFutureDocuments authoring)
            Nothing
        )

redoLiveAuthoring
  :: LiveRevision
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
redoLiveAuthoring expected authoring = do
  ensureCurrent expected authoring
  case liveFutureDocuments authoring of
    [] -> Left LiveRedoBoundary
    following : remaining -> do
      revision <- advanceRevision (liveAuthoringRevision authoring)
      Right
        ( LiveAuthoring
            revision
            (liveShapeCatalog authoring)
            (liveStencilLibrary authoring)
            following
            (selectionIfPresent (liveAuthoringSelection authoring) following)
            []
            (liveCurrentDocument authoring : livePastDocuments authoring)
            remaining
            Nothing
        )

liveNodeSemantic :: LiveNode -> Node
liveNodeSemantic (LiveNode semantic _) = semantic

liveNodeBox :: LiveNode -> Box
liveNodeBox (LiveNode _ resolvedBox) = resolvedBox

liveNodeResolvedProperties
  :: LiveAuthoring
  -> LiveNode
  -> Either LiveAuthoringError NodeProperties
liveNodeResolvedProperties authoring liveNode =
  mapLeft LiveNodePropertiesInvalid
    ( resolveNodeProperties
        (themeStyle (liveAuthoringTheme authoring))
        emptyNodePropertyPatch
        (nodePropertyOverrides (liveNodeSemantic liveNode))
    )

liveResolveNodeOutlines
  :: LiveAuthoring
  -> LiveNode
  -> Either LiveAuthoringError (NonEmpty RenderOutline)
liveResolveNodeOutlines authoring liveNode =
  mapLeft LiveOutlineInvalid
    ( lowerOutlineRef
        (resolveStencil (liveStencilLibrary authoring))
        (liveNodeBox liveNode)
        (nodeOutline (liveNodeSemantic liveNode))
    )

resolveStencil :: StencilLibrary -> StencilId -> Maybe OutlineRef
resolveStencil library identity = do
  definition <- stencilDefinitionById identity library
  stencilGeometryOutline definition

stencilGeometryOutline :: StencilDefinition -> Maybe OutlineRef
stencilGeometryOutline definition =
  case stencilDefinitionGeometry definition of
    StencilPath path -> Just (PathGeometry path)
    StencilCompound outlines -> Just (CompoundGeometry outlines)
    StencilSvgAsset {} -> Nothing
    StencilRasterAsset {} -> Nothing

themeAxisReferences :: Size -> Theme -> [AxisReference]
themeAxisReferences slideSize theme =
  concatMap regionReferences (masterRegions layout)
  where
    layout = themeMasterLayout theme
    slideWidth = sizeWidth slideSize
    slideHeight = sizeHeight slideSize
    regionReferences region =
      let rectangle = masterRegionRect region
          left =
            scaleUnit
              (fractionValue (relativeRectLeft rectangle))
              slideWidth
          bottom =
            scaleUnit
              (fractionValue (relativeRectBottom rectangle))
              slideHeight
          width =
            scaleUnit
              (fractionValue (relativeRectWidth rectangle))
              slideWidth
          height =
            scaleUnit
              (fractionValue (relativeRectHeight rectangle))
              slideHeight
          target = ThemeRegionAlignment (masterRegionId region)
       in [ AxisReference HorizontalAxis left target
          , AxisReference HorizontalAxis (addUnits left (scaleUnit (1 / 2) width)) target
          , AxisReference HorizontalAxis (addUnits left width) target
          , AxisReference VerticalAxis bottom target
          , AxisReference VerticalAxis (addUnits bottom (scaleUnit (1 / 2) height)) target
          , AxisReference VerticalAxis (addUnits bottom height) target
          ]

themePointReferences :: Size -> Theme -> [PointReference]
themePointReferences slideSize theme =
  [ PointReference identity position
  | (identity, position) <-
      resolveMasterAnchors slideSize (themeMasterLayout theme)
  ]

liveSlideSize :: Either LiveAuthoringError Size
liveSlideSize =
  mapLeft
    LiveSlideGeometryInvalid
    (mkSize (canvasUnit 16) (canvasUnit 9))

commitTheme
  :: Theme
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
commitTheme theme authoring =
  commitDocument
    ( LiveDocument
        theme
        (liveAuthoringNodes authoring)
        (liveDocumentNextNodeId (liveCurrentDocument authoring))
    )
    (liveAuthoringSelection authoring)
    []
    authoring

previewTheme :: Theme -> LiveAuthoring -> LiveAuthoring
previewTheme theme authoring =
  LiveAuthoring
    (liveAuthoringRevision authoring)
    (liveShapeCatalog authoring)
    (liveStencilLibrary authoring)
    ( LiveDocument
        theme
        (liveAuthoringNodes authoring)
        (liveDocumentNextNodeId (liveCurrentDocument authoring))
    )
    (liveAuthoringSelection authoring)
    []
    (livePastDocuments authoring)
    (liveFutureDocuments authoring)
    ( case liveThemePreviewOrigin authoring of
        Nothing -> Just (liveCurrentDocument authoring)
        Just origin -> Just origin
    )

commitDocument
  :: LiveDocument
  -> Maybe NodeId
  -> [SnapGuide]
  -> LiveAuthoring
  -> Either LiveAuthoringError LiveAuthoring
commitDocument next selection guides authoring = do
  revision <- advanceRevision (liveAuthoringRevision authoring)
  let historyBase =
        case liveThemePreviewOrigin authoring of
          Nothing -> liveCurrentDocument authoring
          Just origin -> origin
  Right
    ( LiveAuthoring
        revision
        (liveShapeCatalog authoring)
        (liveStencilLibrary authoring)
        next
        selection
        guides
        (historyBase : livePastDocuments authoring)
        []
        Nothing
    )

advanceRevision
  :: LiveRevision
  -> Either LiveAuthoringError LiveRevision
advanceRevision (LiveRevision revision)
  | revision == maxBound = Left LiveRevisionExhausted
  | otherwise = Right (LiveRevision (revision + 1))

ensureCurrent
  :: LiveRevision
  -> LiveAuthoring
  -> Either LiveAuthoringError ()
ensureCurrent expected authoring
  | expected == actual = Right ()
  | otherwise = Left (LiveStaleRevision expected actual)
  where
    actual = liveAuthoringRevision authoring

findLiveNode :: NodeId -> [LiveNode] -> Maybe LiveNode
findLiveNode _ [] = Nothing
findLiveNode wanted (liveNode : remaining)
  | nodeIdentifier (liveNodeSemantic liveNode) == wanted = Just liveNode
  | otherwise = findLiveNode wanted remaining

replaceLiveNode
  :: NodeId
  -> LiveNode
  -> [LiveNode]
  -> Either LiveAuthoringError [LiveNode]
replaceLiveNode wanted replacement nodes =
  case nodes of
    [] -> Left (LiveNodeMissing wanted)
    liveNode : remaining
      | nodeIdentifier (liveNodeSemantic liveNode) == wanted ->
          Right (replacement : remaining)
      | otherwise ->
          (liveNode :) <$> replaceLiveNode wanted replacement remaining

selectionIfPresent :: Maybe NodeId -> LiveDocument -> Maybe NodeId
selectionIfPresent selection document =
  case selection of
    Nothing -> Nothing
    Just identity ->
      case findLiveNode identity (liveDocumentNodes document) of
        Nothing -> Nothing
        Just _ -> Just identity

replaceCatalog
  :: ShapeCatalog
  -> StencilLibrary
  -> LiveAuthoring
  -> LiveAuthoring
replaceCatalog catalog library authoring =
  LiveAuthoring
    (liveAuthoringRevision authoring)
    catalog
    library
    (liveCurrentDocument authoring)
    (liveAuthoringSelection authoring)
    (liveAuthoringGuides authoring)
    (livePastDocuments authoring)
    (liveFutureDocuments authoring)
    (liveThemePreviewOrigin authoring)

setTransientSelection
  :: Maybe NodeId
  -> [SnapGuide]
  -> LiveAuthoring
  -> LiveAuthoring
setTransientSelection selection guides authoring =
  LiveAuthoring
    (liveAuthoringRevision authoring)
    (liveShapeCatalog authoring)
    (liveStencilLibrary authoring)
    (liveCurrentDocument authoring)
    selection
    guides
    (livePastDocuments authoring)
    (liveFutureDocuments authoring)
    (liveThemePreviewOrigin authoring)

liveShapeCatalog :: LiveAuthoring -> ShapeCatalog
liveShapeCatalog (LiveAuthoring _ catalog _ _ _ _ _ _ _) = catalog

liveStencilLibrary :: LiveAuthoring -> StencilLibrary
liveStencilLibrary (LiveAuthoring _ _ library _ _ _ _ _ _) = library

liveCurrentDocument :: LiveAuthoring -> LiveDocument
liveCurrentDocument (LiveAuthoring _ _ _ document _ _ _ _ _) = document

livePastDocuments :: LiveAuthoring -> [LiveDocument]
livePastDocuments (LiveAuthoring _ _ _ _ _ _ past _ _) = past

liveFutureDocuments :: LiveAuthoring -> [LiveDocument]
liveFutureDocuments (LiveAuthoring _ _ _ _ _ _ _ future _) = future

liveThemePreviewOrigin :: LiveAuthoring -> Maybe LiveDocument
liveThemePreviewOrigin (LiveAuthoring _ _ _ _ _ _ _ _ origin) = origin

liveDocumentTheme :: LiveDocument -> Theme
liveDocumentTheme (LiveDocument theme _ _) = theme

liveDocumentNodes :: LiveDocument -> [LiveNode]
liveDocumentNodes (LiveDocument _ nodes _) = nodes

liveDocumentNextNodeId :: LiveDocument -> Word64
liveDocumentNextNodeId (LiveDocument _ _ nextIdentity) = nextIdentity

mapLeft
  :: (failure -> mapped)
  -> Either failure value
  -> Either mapped value
mapLeft transform result =
  case result of
    Left failure -> Left (transform failure)
    Right value -> Right value
