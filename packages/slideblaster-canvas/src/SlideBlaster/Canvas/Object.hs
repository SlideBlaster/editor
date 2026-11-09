-- |
-- Module      : SlideBlaster.Canvas.Object
-- Description : Ordered picture objects, source barriers, and z-order laws.
--
-- A 'Picture' preserves statement order. Nodes/assets/stencils may swap only
-- with an adjacent reorderable object; connectors, groups, named coordinates,
-- and opaque/source barriers stop a reorder. Construction validates stable
-- element identity and group membership.
module SlideBlaster.Canvas.Object
  ( Node (..)
  , NodeAccessibility (..)
  , ResolvedNode (..)
  , Connector (..)
  , Group (..)
  , CanvasObject (..)
  , elementId
  , elementOverlay
  , LayerBarrier (..)
  , LayerEntry (..)
  , isReorderBarrier
  , Picture
  , PictureError (..)
  , emptyPicture
  , mkPicture
  , pictureEntries
  , pictureElements
  , findElement
  , ReorderDirection (..)
  , ReorderError (..)
  , reorderElement
  ) where

import SlideBlaster.Canvas.Connector (ConnectorPath)
import SlideBlaster.Canvas.Content (Content)
import SlideBlaster.Canvas.Geometry (Box, Point)
import SlideBlaster.Canvas.Identifier
  ( AnimationRef
  , BarrierId
  , ConnectorId
  , ElementId (..)
  , GroupId
  , NodeId
  , SourceRef
  )
import SlideBlaster.Canvas.Overlay (OverlayHook (AlwaysVisible))
import SlideBlaster.Canvas.Placement (Placement)
import SlideBlaster.Canvas.Property
  ( ConnectorPropertyPatch (connectorPatchOverlay)
  , NodeProperties
  , NodePropertyPatch (nodePatchOverlay)
  )
import SlideBlaster.Canvas.Outline (OutlineRef)

import Data.List.NonEmpty (NonEmpty)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

-- | Ordinary semantic node; exact source options remain in CST provenance.
data Node = Node
  { nodeIdentifier :: !NodeId
  , nodePlacement :: !Placement
  , nodeOutline :: !OutlineRef
  , nodeContent :: !Content
  , nodePropertyOverrides :: !NodePropertyPatch
  , nodeAnimationRefs :: ![AnimationRef]
  , nodeAccessibility :: !NodeAccessibility
  }
  deriving stock (Eq, Show)

data NodeAccessibility
  = DecorativeNode
  | AccessibleNode !Text !(Maybe Text)
  deriving stock (Eq, Ord, Show)

-- | Layout-ready node value consumed by render/export planning.
data ResolvedNode = ResolvedNode
  { resolvedNode :: !Node
  , resolvedNodeBox :: !Box
  , resolvedNodeProperties :: !NodeProperties
  }
  deriving stock (Eq, Show)

data Connector = Connector
  { connectorIdentifier :: !ConnectorId
  , connectorPath :: !ConnectorPath
  , connectorLabel :: !(Maybe Content)
  , connectorPropertyOverrides :: !ConnectorPropertyPatch
  , connectorAnimationRefs :: ![AnimationRef]
  , connectorAccessibility :: !NodeAccessibility
  }
  deriving stock (Eq, Show)

-- | Explicit membership; containment/layout semantics are not implied.
data Group = Group
  { groupIdentifier :: !GroupId
  , groupMembers :: !(NonEmpty ElementId)
  , groupPlacement :: !(Maybe Placement)
  , groupOverlay :: !OverlayHook
  }
  deriving stock (Eq, Show)

data CanvasObject
  = CanvasNode !Node
  | CanvasConnector !Connector
  | CanvasGroup !Group
  deriving stock (Eq, Show)

elementId :: CanvasObject -> ElementId
elementId object =
  case object of
    CanvasNode value -> NodeElement (nodeIdentifier value)
    CanvasConnector value -> ConnectorElement (connectorIdentifier value)
    CanvasGroup value -> GroupElement (groupIdentifier value)

elementOverlay :: CanvasObject -> OverlayHook
elementOverlay object =
  case object of
    CanvasNode value ->
      maybe AlwaysVisible id (nodePatchOverlay (nodePropertyOverrides value))
    CanvasConnector value ->
      maybe
        AlwaysVisible
        id
        (connectorPatchOverlay (connectorPropertyOverrides value))
    CanvasGroup value -> groupOverlay value

-- | Source-order statement that no generic z-order operation may cross.
data LayerBarrier
  = NamedCoordinateBarrier !BarrierId !Point
  | OpaqueStatementBarrier !BarrierId !SourceRef
  | ExplicitLayerBarrier !BarrierId !Text
  deriving stock (Eq, Show)

data LayerEntry
  = ObjectEntry !CanvasObject
  | BarrierEntry !LayerBarrier
  deriving stock (Eq, Show)

-- | Connectors and groups are barriers unless a format adapter proves more.
isReorderBarrier :: LayerEntry -> Bool
isReorderBarrier entry =
  case entry of
    BarrierEntry _ -> True
    ObjectEntry object ->
      case object of
        CanvasConnector _ -> True
        CanvasGroup _ -> True
        CanvasNode _ -> False

newtype Picture = Picture [LayerEntry]
  deriving stock (Eq, Show)

data PictureError
  = DuplicateElementId !ElementId
  | DanglingGroupMember !GroupId !ElementId
  | GroupContainsItself !GroupId
  | DuplicateGroupMember !GroupId !ElementId
  deriving stock (Eq, Show)

emptyPicture :: Picture
emptyPicture = Picture []

mkPicture :: [LayerEntry] -> Either PictureError Picture
mkPicture entries = do
  identities <- collectUnique Set.empty entries
  validateGroups identities entries
  Right (Picture entries)

pictureEntries :: Picture -> [LayerEntry]
pictureEntries (Picture entries) = entries

pictureElements :: Picture -> [CanvasObject]
pictureElements (Picture entries) = collectElements entries

findElement :: ElementId -> Picture -> Maybe CanvasObject
findElement wanted (Picture entries) = findInEntries entries
  where
    findInEntries [] = Nothing
    findInEntries (entry : remaining) =
      case entry of
        BarrierEntry _ -> findInEntries remaining
        ObjectEntry object
          | elementId object == wanted -> Just object
          | otherwise -> findInEntries remaining

data ReorderDirection = TowardFront | TowardBack
  deriving stock (Eq, Ord, Show)

data ReorderError
  = ReorderElementMissing !ElementId
  | ReorderElementIsBarrier !ElementId
  | ReorderAtBoundary !ElementId
  | ReorderBlocked !ElementId
  deriving stock (Eq, Show)

reorderElement ::
  ReorderDirection ->
  ElementId ->
  Picture ->
  Either ReorderError Picture
reorderElement direction wanted (Picture entries) =
  Picture <$> case direction of
    TowardFront -> moveForward wanted entries
    TowardBack -> reverseMove wanted entries

collectUnique ::
  Set ElementId ->
  [LayerEntry] ->
  Either PictureError (Set ElementId)
collectUnique seen [] = Right seen
collectUnique seen (entry : remaining) =
  case entry of
    BarrierEntry _ -> collectUnique seen remaining
    ObjectEntry object ->
      let identity = elementId object
       in if Set.member identity seen
            then Left (DuplicateElementId identity)
            else collectUnique (Set.insert identity seen) remaining

validateGroups ::
  Set ElementId ->
  [LayerEntry] ->
  Either PictureError ()
validateGroups _ [] = Right ()
validateGroups identities (entry : remaining) =
  case entry of
    ObjectEntry (CanvasGroup value) -> do
      validateMembers
        identities
        (groupIdentifier value)
        (groupMembers value)
      validateGroups identities remaining
    _ -> validateGroups identities remaining

validateMembers ::
  Set ElementId ->
  GroupId ->
  NonEmpty ElementId ->
  Either PictureError ()
validateMembers identities identity members =
  validateGroupMembers Set.empty (toList members)
  where
    validateGroupMembers _ [] = Right ()
    validateGroupMembers seen (member : remaining) = do
      validateMember member
      if Set.member member seen
        then Left (DuplicateGroupMember identity member)
        else
          validateGroupMembers
            (Set.insert member seen)
            remaining
    validateMember member
      | member == GroupElement identity = Left (GroupContainsItself identity)
      | Set.member member identities = Right ()
      | otherwise = Left (DanglingGroupMember identity member)

toList :: NonEmpty value -> [value]
toList = foldr (:) []

collectElements :: [LayerEntry] -> [CanvasObject]
collectElements [] = []
collectElements (entry : remaining) =
  case entry of
    BarrierEntry _ -> collectElements remaining
    ObjectEntry object -> object : collectElements remaining

moveForward ::
  ElementId ->
  [LayerEntry] ->
  Either ReorderError [LayerEntry]
moveForward wanted entries =
  case entries of
    [] -> Left (ReorderElementMissing wanted)
    [ObjectEntry object]
      | elementId object == wanted ->
          if isReorderBarrier (ObjectEntry object)
            then Left (ReorderElementIsBarrier wanted)
            else Left (ReorderAtBoundary wanted)
    [_] -> Left (ReorderElementMissing wanted)
    ObjectEntry object : next : remaining
      | elementId object == wanted ->
          if isReorderBarrier (ObjectEntry object)
            then Left (ReorderElementIsBarrier wanted)
            else
              if isReorderBarrier next
                then Left (ReorderBlocked wanted)
                else Right (next : ObjectEntry object : remaining)
    entry : remaining -> (entry :) <$> moveForward wanted remaining

reverseMove ::
  ElementId ->
  [LayerEntry] ->
  Either ReorderError [LayerEntry]
reverseMove wanted entries =
  reverse <$> moveForward wanted (reverse entries)
