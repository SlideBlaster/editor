{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Catalog.Curated
-- Description : Native parametric presets for the small always-visible palette.
--
-- These fifteen presets are SlideBlaster-owned catalog data over the generic
-- canvas geometry language. They are deliberately separate from the imported,
-- attributed draw.io stencil snapshot: no upstream stencil is required to
-- create or render one of these common shapes.
module SlideBlaster.Catalog.Curated
  ( CuratedCatalogError (..)
  , curatedShapeCatalog
  ) where

import SlideBlaster.Canvas
  ( ArcSize (SmallArc)
  , ArcSweep (ClockwiseArc)
  , ColourRef (PaletteColour)
  , GeometryError
  , NodePropertyPatch
  , OutlineGeometryError
  , OutlineRef (..)
  , PathCommand (..)
  , PrimitiveOutline (..)
  , Stroke (SolidStroke)
  , canvasUnit
  , emptyContent
  , emptyNodePropertyPatch
  , mkPathOutline
  , mkArcRadii
  , mkOutlineRadius
  , mkPolygonOutline
  , mkSize
  , nodePatchStroke
  , outlinePoint
  )
import SlideBlaster.Catalog.Model
  ( CatalogOrigin (CuratedCatalogOrigin)
  , CatalogPriority (P0Catalog)
  , ShapeCatalog
  , ShapeCatalogError
  , ShapePreset (..)
  , catalogFamily
  , mkShapeCatalog
  , shapeId
  )

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)

data CuratedCatalogError
  = InvalidCuratedShapeId !Text
  | InvalidCuratedFamily !Text
  | InvalidCuratedSize !Text !GeometryError
  | InvalidCuratedOutline !Text !OutlineGeometryError
  | InvalidCuratedCatalog !ShapeCatalogError
  deriving stock (Eq, Show)

data PresetSeed = PresetSeed
  !Text
  !Text
  !Text
  !Text
  ![Text]
  !Rational
  !Rational
  !(Either OutlineGeometryError OutlineRef)

-- | The complete SlideBlaster 1 native P0 set: eleven general shapes and four
-- flowchart aliases. Construction remains typed so future data edits cannot
-- introduce an invalid identifier, size, outline, or duplicate.
curatedShapeCatalog :: Either CuratedCatalogError ShapeCatalog
curatedShapeCatalog = do
  presets <- traverse seedToPreset curatedSeeds
  mapLeft InvalidCuratedCatalog (mkShapeCatalog presets)

seedToPreset :: PresetSeed -> Either CuratedCatalogError ShapePreset
seedToPreset
  (PresetSeed rawId label familyText category keywords width height outlineResult) = do
    identity <-
      maybe
        (Left (InvalidCuratedShapeId rawId))
        Right
        (shapeId rawId)
    family <-
      maybe
        (Left (InvalidCuratedFamily familyText))
        Right
        (catalogFamily familyText)
    dropSize <-
      mapLeft
        (InvalidCuratedSize rawId)
        (mkSize (canvasUnit width) (canvasUnit height))
    outline <-
      mapLeft
        (InvalidCuratedOutline rawId)
        outlineResult
    Right
      ShapePreset
        { shapePresetIdentifier = identity
        , shapePresetLabel = label
        , shapePresetCategory = category
        , shapePresetKeywords = keywords
        , shapePresetFamily = family
        , shapePresetPriority = P0Catalog
        , shapePresetOrigin = CuratedCatalogOrigin
        , shapePresetOutline = outline
        , shapePresetProperties = drawnProperties
        , shapePresetDropSize = dropSize
        , shapePresetContent = emptyContent
        }

drawnProperties :: NodePropertyPatch
drawnProperties =
  emptyNodePropertyPatch
    { nodePatchStroke =
        Just
          ( SolidStroke
              (PaletteColour "ink")
              (canvasUnit (1 / 100))
          )
    }

curatedSeeds :: NonEmpty PresetSeed
curatedSeeds =
  PresetSeed
    "rectangle"
    "Rectangle"
    "General"
    "General"
    ["box", "rect"]
    (16 / 5)
    2
    (Right (PrimitiveGeometry RectangleOutline))
    :| [ PresetSeed
           "rounded-rectangle"
           "Rounded Rectangle"
           "General"
           "General"
           ["box", "rounded", "rect"]
           (16 / 5)
           2
           (roundedRectangleOutline (2 / 5))
       , PresetSeed
           "square"
           "Square"
           "General"
           "General"
           ["box", "rect"]
           (11 / 5)
           (11 / 5)
           (Right (PrimitiveGeometry RectangleOutline))
       , PresetSeed
           "ellipse"
           "Ellipse"
           "General"
           "General"
           ["oval", "round"]
           (16 / 5)
           2
           (Right (PrimitiveGeometry EllipseOutline))
       , PresetSeed
           "circle"
           "Circle"
           "General"
           "General"
           ["round", "dot", "oval"]
           (11 / 5)
           (11 / 5)
           (Right (PrimitiveGeometry EllipseOutline))
       , PresetSeed
           "diamond"
           "Diamond"
           "General"
           "General"
           ["rhombus", "decision"]
           (14 / 5)
           (11 / 5)
           diamondOutline
       , PresetSeed
           "triangle"
           "Triangle"
           "General"
           "General"
           ["delta", "arrow"]
           (13 / 5)
           (12 / 5)
           triangleOutline
       , PresetSeed
           "trapezoid"
           "Trapezoid"
           "General"
           "General"
           ["trapezium"]
           3
           2
           trapezoidOutline
       , PresetSeed
           "parallelogram"
           "Parallelogram"
           "General"
           "General"
           ["data", "skew", "rhomboid"]
           (16 / 5)
           2
           parallelogramOutline
       , PresetSeed
           "hexagon"
           "Hexagon"
           "General"
           "General"
           ["polygon", "preparation", "six"]
           (14 / 5)
           (12 / 5)
           hexagonOutline
       , PresetSeed
           "cylinder"
           "Cylinder"
           "General"
           "General"
           ["database", "db", "disk", "storage"]
           (12 / 5)
           (14 / 5)
           cylinderOutline
       , PresetSeed
           "flow-process"
           "Process"
           "Flowchart"
           "Flowchart"
           ["action", "step", "rectangle"]
           (16 / 5)
           (9 / 5)
           (Right (PrimitiveGeometry RectangleOutline))
       , PresetSeed
           "flow-decision"
           "Decision"
           "Flowchart"
           "Flowchart"
           ["branch", "if", "diamond"]
           3
           (11 / 5)
           diamondOutline
       , PresetSeed
           "flow-terminator"
           "Terminator"
           "Flowchart"
           "Flowchart"
           ["start", "end", "stadium", "pill"]
           3
           (8 / 5)
           (roundedRectangleOutline (4 / 5))
       , PresetSeed
           "flow-data"
           "Data"
           "Flowchart"
           "Flowchart"
           ["io", "input", "output", "parallelogram"]
           (16 / 5)
           (9 / 5)
           parallelogramOutline
       ]

diamondOutline :: Either OutlineGeometryError OutlineRef
diamondOutline =
  PolygonGeometry
    <$> mkPolygonOutline
      ( outlinePoint 0 1
          :| [ outlinePoint 1 0
             , outlinePoint 0 (-1)
             , outlinePoint (-1) 0
             ]
      )

triangleOutline :: Either OutlineGeometryError OutlineRef
triangleOutline =
  PolygonGeometry
    <$> mkPolygonOutline
      ( outlinePoint 0 1
          :| [ outlinePoint 1 (-1)
             , outlinePoint (-1) (-1)
             ]
      )

trapezoidOutline :: Either OutlineGeometryError OutlineRef
trapezoidOutline =
  PolygonGeometry
    <$> mkPolygonOutline
      ( outlinePoint (-2 / 3) 1
          :| [ outlinePoint (2 / 3) 1
             , outlinePoint 1 (-1)
             , outlinePoint (-1) (-1)
             ]
      )

parallelogramOutline :: Either OutlineGeometryError OutlineRef
parallelogramOutline =
  PolygonGeometry
    <$> mkPolygonOutline
      ( outlinePoint (-2 / 3) 1
          :| [ outlinePoint 1 1
             , outlinePoint (2 / 3) (-1)
             , outlinePoint (-1) (-1)
             ]
      )

hexagonOutline :: Either OutlineGeometryError OutlineRef
hexagonOutline =
  PolygonGeometry
    <$> mkPolygonOutline
      ( outlinePoint (-1 / 2) 1
          :| [ outlinePoint (1 / 2) 1
             , outlinePoint 1 0
             , outlinePoint (1 / 2) (-1)
             , outlinePoint (-1 / 2) (-1)
             , outlinePoint (-1) 0
             ]
      )

cylinderOutline :: Either OutlineGeometryError OutlineRef
cylinderOutline = do
  radii <- mkArcRadii 1 (1 / 4)
  PathGeometry
    <$> mkPathOutline
      ( MovePath (outlinePoint (-1) (3 / 4))
          :| [ ArcPath
                 radii
                 0
                 SmallArc
                 ClockwiseArc
                 (outlinePoint 1 (3 / 4))
             , LinePath (outlinePoint 1 (-3 / 4))
             , ArcPath
                 radii
                 0
                 SmallArc
                 ClockwiseArc
                 (outlinePoint (-1) (-3 / 4))
             , ClosePath
             , MovePath (outlinePoint (-1) (3 / 4))
             , ArcPath
                 radii
                 0
                 SmallArc
                 ClockwiseArc
                 (outlinePoint 1 (3 / 4))
             ]
      )

roundedRectangleOutline
  :: Rational
  -> Either OutlineGeometryError OutlineRef
roundedRectangleOutline radius =
  PrimitiveGeometry . RoundedRectangleOutline
    <$> mkOutlineRadius (canvasUnit radius)

mapLeft :: (failure -> mapped) -> Either failure value -> Either mapped value
mapLeft transform value =
  case value of
    Left failure -> Left (transform failure)
    Right success -> Right success
