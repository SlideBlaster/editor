-- |
-- Module      : SlideBlaster.Canvas.Placement
-- Description : Authored placement meaning and derived resolved boxes.
--
-- Absolute and relative placement are co-equal authored modes. A resolved box
-- records the authored cause beside disposable geometry; source-derived
-- placement remains explicitly read-only rather than being guessed writable.
module SlideBlaster.Canvas.Placement
  ( RelativeSide (..)
  , RelativePlacement (..)
  , defaultPortsForSide
  , Placement (..)
  , ResolvedElementBox (..)
  , LayoutError (..)
  ) where

import SlideBlaster.Canvas.Geometry
  ( BorderPort (..)
  , Box
  , CanvasUnit
  , Point
  )
import SlideBlaster.Canvas.Identifier (ElementId, NodeId, SourceRef)

import Data.List.NonEmpty (NonEmpty)

-- | The eight relative-placement directions supported by authored source.
data RelativeSide
  = Above
  | AboveRight
  | RightOf
  | BelowRight
  | Below
  | BelowLeft
  | LeftOf
  | AboveLeft
  deriving stock (Eq, Ord, Show)

-- | Authored binding from one node anchor to another.
data RelativePlacement = RelativePlacement
  { relativeTarget :: !NodeId
  , relativeSide :: !RelativeSide
  , relativePrimaryGap :: !CanvasUnit
  , relativeSecondaryGap :: !CanvasUnit
  , relativeTargetPort :: !BorderPort
  , relativeOwnPort :: !BorderPort
  }
  deriving stock (Eq, Ord, Show)

-- | Conventional own/target port pair for a relative side.
defaultPortsForSide :: RelativeSide -> (BorderPort, BorderPort)
defaultPortsForSide side =
  case side of
    Above -> (South, North)
    AboveRight -> (SouthWest, NorthEast)
    RightOf -> (West, East)
    BelowRight -> (NorthWest, SouthEast)
    Below -> (North, South)
    BelowLeft -> (NorthEast, SouthWest)
    LeftOf -> (East, West)
    AboveLeft -> (SouthEast, NorthWest)

-- | Authored placement mode. Derived placement is renderable but not editable.
data Placement
  = AbsolutePlacement !Point !BorderPort
  | RelativeNodePlacement !RelativePlacement
  | SourceDerivedPlacement !SourceRef
  | GeneratedPlacement !Point !BorderPort
  deriving stock (Eq, Ord, Show)

-- | One disposable layout result retaining the placement that produced it.
data ResolvedElementBox = ResolvedElementBox
  { resolvedElementId :: !ElementId
  , resolvedAuthoredPlacement :: !Placement
  , resolvedBox :: !Box
  }
  deriving stock (Eq, Ord, Show)

-- | Failures a future target-neutral layout resolver must report explicitly.
data LayoutError
  = PlacementCycle !(NonEmpty NodeId)
  | MissingPlacementTarget !NodeId !NodeId
  | MissingMeasurement !ElementId
  | LayoutUnsupportedPlacement !SourceRef
  deriving stock (Eq, Show)
