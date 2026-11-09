{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.App.Selection
-- Description : Semantic tools, selections, and canvas view state.
--
-- Selection uses semantic addresses and is never source provenance. Handles and
-- content ranges are explicit sub-selections rather than ad-hoc DOM state.
module SlideBlaster.App.Selection
  ( Tool (..)
  , ConnectorPreset (..)
  , HandleId
  , mkHandleId
  , handleIdText
  , ContentRange
  , mkContentRange
  , contentRangeStart
  , contentRangeEnd
  , Selection (..)
  , Panel (..)
  , PanelVisibility (..)
  , Zoom
  , mkZoom
  , zoomValue
  , defaultZoom
  , CanvasView (..)
  , defaultCanvasView
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import SlideBlaster.Canvas
  ( ConnectorId
  )
import SlideBlaster.Catalog (ShapeId)
import SlideBlaster.Presentation
  ( ElementAddress
  , FrameId
  , SurfaceAddress
  )

data ConnectorPreset
  = StraightConnector
  | OrthogonalConnector
  | CurvedConnector
  deriving stock (Eq, Ord, Show)

data Tool
  = SelectTool
  | TextTool
  | ShapeTool !ShapeId
  | ConnectorTool !ConnectorPreset
  | PanTool
  deriving stock (Eq, Ord, Show)

newtype HandleId = HandleId Text
  deriving stock (Eq, Ord, Show)

mkHandleId :: Text -> Maybe HandleId
mkHandleId value
  | Text.null (Text.strip value) = Nothing
  | otherwise = Just (HandleId value)

handleIdText :: HandleId -> Text
handleIdText (HandleId value) = value

data ContentRange = ContentRange !Natural !Natural
  deriving stock (Eq, Ord, Show)

mkContentRange :: Natural -> Natural -> Maybe ContentRange
mkContentRange start end
  | start <= end = Just (ContentRange start end)
  | otherwise = Nothing

contentRangeStart :: ContentRange -> Natural
contentRangeStart (ContentRange start _) = start

contentRangeEnd :: ContentRange -> Natural
contentRangeEnd (ContentRange _ end) = end

data Selection
  = NoSelection
  | ObjectSelection !(NonEmpty ElementAddress)
  | ConnectorHandleSelection !SurfaceAddress !ConnectorId !HandleId
  | ContentSelection !ElementAddress !ContentRange
  | FrameSelection !FrameId
  deriving stock (Eq, Show)

data Panel
  = FilesPanel
  | SourcePanel
  | NavigatorPanel
  | ShapesPanel
  | PropertiesPanel
  | ThemePanel
  | ExportPanel
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data PanelVisibility = PanelShown | PanelHidden
  deriving stock (Eq, Ord, Show)

newtype Zoom = Zoom Rational
  deriving stock (Eq, Ord, Show)

mkZoom :: Rational -> Maybe Zoom
mkZoom value
  | value > 0 = Just (Zoom value)
  | otherwise = Nothing

zoomValue :: Zoom -> Rational
zoomValue (Zoom value) = value

defaultZoom :: Zoom
defaultZoom = Zoom 1

data CanvasView = CanvasView
  { canvasZoom :: !Zoom
  , canvasVisiblePanels :: !(Set Panel)
  , canvasActiveSurface :: !(Maybe SurfaceAddress)
  }
  deriving stock (Eq, Show)

defaultCanvasView :: CanvasView
defaultCanvasView =
  CanvasView
    { canvasZoom = defaultZoom
    , canvasVisiblePanels =
        Set.fromList
          [ FilesPanel
          , SourcePanel
          , NavigatorPanel
          , ShapesPanel
          , PropertiesPanel
          ]
    , canvasActiveSurface = Nothing
    }
