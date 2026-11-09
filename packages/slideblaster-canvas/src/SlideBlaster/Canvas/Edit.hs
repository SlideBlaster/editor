-- |
-- Module      : SlideBlaster.Canvas.Edit
-- Description : Typed canvas authoring intents before source projection.
--
-- These values describe semantic intent only. Revision fencing, provenance
-- projection, reparsing, semantic verification, and history commit belong to
-- the source/edit transaction packages.
module SlideBlaster.Canvas.Edit
  ( NodeSeed (..)
  , EditIntent (..)
  , dragResolutionIntent
  ) where

import SlideBlaster.Canvas.Connector (ConnectorPath)
import SlideBlaster.Canvas.Content (Content)
import SlideBlaster.Canvas.Geometry (Point)
import SlideBlaster.Canvas.Identifier
  ( AnimationRef
  , ConnectorId
  , ElementId
  , NodeId
  )
import SlideBlaster.Canvas.Object
  ( NodeAccessibility
  , ReorderDirection
  )
import SlideBlaster.Canvas.Placement (Placement, RelativePlacement)
import SlideBlaster.Canvas.Property
  ( ConnectorPropertyPatch
  , NodePropertyPatch
  , Sizing
  )
import SlideBlaster.Canvas.Outline (OutlineRef)
import SlideBlaster.Canvas.Snap
  ( DragResolution
  , dragResolvedPlacement
  )

import Data.List.NonEmpty (NonEmpty)

-- | Catalog-free input for creating one ordinary node. A palette, paste
-- adapter, or authored-source command must resolve its own identity and
-- provenance before entering the semantic edit layer.
data NodeSeed = NodeSeed
  { nodeSeedOutline :: !OutlineRef
  , nodeSeedContent :: !Content
  , nodeSeedProperties :: !NodePropertyPatch
  }
  deriving stock (Eq, Show)

-- | Closed semantic operations issued by canvas and property surfaces.
data EditIntent
  = MoveElement !ElementId !Placement
  | ResizeElement !ElementId !Sizing
  | BindNode !NodeId !RelativePlacement
  | DetachNode !NodeId !Point
  | SetNodeProperties !NodeId !NodePropertyPatch
  | SetConnectorProperties !ConnectorId !ConnectorPropertyPatch
  | SetNodeAccessibility !NodeId !NodeAccessibility
  | SetConnectorAccessibility !ConnectorId !NodeAccessibility
  | SetNodeAnimations !NodeId ![AnimationRef]
  | SetConnectorAnimations !ConnectorId ![AnimationRef]
  | ReplaceNodeContent !NodeId !Content
  | ReplaceNodeOutline !NodeId !OutlineRef
  | ReplaceConnectorPath !ConnectorId !ConnectorPath
  | ReorderCanvasElement !ElementId !ReorderDirection
  | DeleteCanvasElements !(NonEmpty ElementId)
  | InsertNode !NodeSeed !Placement
  deriving stock (Eq, Show)

dragResolutionIntent :: ElementId -> DragResolution -> EditIntent
dragResolutionIntent identity resolution =
  MoveElement identity (dragResolvedPlacement resolution)
