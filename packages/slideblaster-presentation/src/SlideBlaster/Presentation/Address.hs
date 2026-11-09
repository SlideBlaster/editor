-- |
-- Module      : SlideBlaster.Presentation.Address
-- Description : Stable addresses across presentation picture surfaces.
--
-- A canvas element identity is only unique within its owning picture. These
-- addresses add stable frame identity and the audience/notes surface
-- distinction without introducing indexes, source spans, or renderer handles.
-- Their components are already validated by their owning packages.
module SlideBlaster.Presentation.Address
  ( ElementAddress
  , SurfaceAddress
  , SurfaceKind (..)
  , elementAddress
  , elementAddressElement
  , elementAddressSurface
  , surfaceAddress
  , surfaceAddressFrame
  , surfaceAddressKind
  ) where

import SlideBlaster.Canvas (ElementId)
import SlideBlaster.Presentation.Model (FrameId)

-- | Which full picture side of a frame owns an element.
data SurfaceKind = AudienceSurface | NotesSurface
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Stable address of one full picture surface.
data SurfaceAddress = SurfaceAddress !FrameId !SurfaceKind
  deriving stock (Eq, Ord, Show)

-- | Construct a surface address from already-validated identities.
surfaceAddress :: FrameId -> SurfaceKind -> SurfaceAddress
surfaceAddress = SurfaceAddress

-- | Return the stable owning frame.
surfaceAddressFrame :: SurfaceAddress -> FrameId
surfaceAddressFrame (SurfaceAddress frame _) = frame

-- | Return whether the address selects the audience or notes picture.
surfaceAddressKind :: SurfaceAddress -> SurfaceKind
surfaceAddressKind (SurfaceAddress _ kind) = kind

-- | Stable address of one canvas element in one frame surface.
data ElementAddress = ElementAddress !SurfaceAddress !ElementId
  deriving stock (Eq, Ord, Show)

-- | Construct an element address from already-validated identities.
elementAddress :: SurfaceAddress -> ElementId -> ElementAddress
elementAddress = ElementAddress

-- | Return the owning picture surface.
elementAddressSurface :: ElementAddress -> SurfaceAddress
elementAddressSurface (ElementAddress surface _) = surface

-- | Return the canvas-owned element identity.
elementAddressElement :: ElementAddress -> ElementId
elementAddressElement (ElementAddress _ element) = element
