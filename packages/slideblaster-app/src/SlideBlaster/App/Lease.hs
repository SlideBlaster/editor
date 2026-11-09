-- |
-- Module      : SlideBlaster.App.Lease
-- Description : Painted-canvas authority fenced by session, revision, and ticket.
--
-- A render plan becomes editable only after a matching paint acknowledgement.
-- Any newer draft makes the last-good canvas inert. Stale asynchronous paints
-- cannot regain edit authority.
module SlideBlaster.App.Lease
  ( SessionId
  , sessionIdFromWord64
  , sessionIdToWord64
  , LeaseFence
  , leaseFenceSession
  , leaseFenceRevision
  , leaseFenceTicket
  , leaseFenceSurface
  , PaintRequest
  , paintRequest
  , paintRequestSession
  , paintRequestRevision
  , paintRequestTicket
  , paintRequestSurface
  , PaintedCanvasLease
  , paintedLeaseFence
  , paintedLeasePlan
  , InertReason (..)
  , CanvasAuthority
  , noCanvasAuthority
  , writableCanvasAuthority
  , inertCanvasAuthority
  , revokeCanvasAuthority
  , LeaseError (..)
  , acknowledgePaint
  , authorityAllowsEdit
  ) where

import Data.Word (Word64)
import SlideBlaster.Presentation (SurfaceAddress)
import SlideBlaster.Render
  ( RenderPlan
  , RenderTicket
  , renderPlanRevision
  , renderPlanSurface
  , renderPlanTicket
  )
import SlideBlaster.Source (Revision)

newtype SessionId = SessionId Word64
  deriving stock (Eq, Ord, Show)

sessionIdFromWord64 :: Word64 -> SessionId
sessionIdFromWord64 = SessionId

sessionIdToWord64 :: SessionId -> Word64
sessionIdToWord64 (SessionId value) = value

data LeaseFence = LeaseFence
  !SessionId
  !Revision
  !RenderTicket
  !SurfaceAddress
  deriving stock (Eq, Show)

leaseFenceSession :: LeaseFence -> SessionId
leaseFenceSession (LeaseFence session _ _ _) = session

leaseFenceRevision :: LeaseFence -> Revision
leaseFenceRevision (LeaseFence _ revision _ _) = revision

leaseFenceTicket :: LeaseFence -> RenderTicket
leaseFenceTicket (LeaseFence _ _ ticket _) = ticket

leaseFenceSurface :: LeaseFence -> SurfaceAddress
leaseFenceSurface (LeaseFence _ _ _ surface) = surface

-- | An issued paint request. Only a request currently held by the application
-- may be acknowledged; a self-consistent but unsolicited plan has no
-- authority.
newtype PaintRequest = PaintRequest LeaseFence
  deriving stock (Eq, Show)

paintRequest
  :: SessionId
  -> Revision
  -> RenderTicket
  -> SurfaceAddress
  -> PaintRequest
paintRequest session revision ticket surface =
  PaintRequest (LeaseFence session revision ticket surface)

paintRequestSession :: PaintRequest -> SessionId
paintRequestSession (PaintRequest fence) = leaseFenceSession fence

paintRequestRevision :: PaintRequest -> Revision
paintRequestRevision (PaintRequest fence) = leaseFenceRevision fence

paintRequestTicket :: PaintRequest -> RenderTicket
paintRequestTicket (PaintRequest fence) = leaseFenceTicket fence

paintRequestSurface :: PaintRequest -> SurfaceAddress
paintRequestSurface (PaintRequest fence) = leaseFenceSurface fence

data PaintedCanvasLease = PaintedCanvasLease !LeaseFence !RenderPlan

paintedLeaseFence :: PaintedCanvasLease -> LeaseFence
paintedLeaseFence (PaintedCanvasLease fence _) = fence

paintedLeasePlan :: PaintedCanvasLease -> RenderPlan
paintedLeasePlan (PaintedCanvasLease _ plan) = plan

data InertReason
  = NewerDraftExists
  | AcceptedSyntaxOnly
  | MeasurementPending
  | PaintPending
  | SurfaceNoLongerExists
  deriving stock (Eq, Ord, Show)

data CanvasAuthority
  = NoCanvasAuthority
  | WritableCanvasAuthority !PaintedCanvasLease
  | InertCanvasAuthority !PaintedCanvasLease !InertReason

noCanvasAuthority :: CanvasAuthority
noCanvasAuthority = NoCanvasAuthority

writableCanvasAuthority :: CanvasAuthority -> Maybe PaintedCanvasLease
writableCanvasAuthority authority =
  case authority of
    WritableCanvasAuthority lease -> Just lease
    NoCanvasAuthority -> Nothing
    InertCanvasAuthority _ _ -> Nothing

inertCanvasAuthority
  :: CanvasAuthority
  -> Maybe (PaintedCanvasLease, InertReason)
inertCanvasAuthority authority =
  case authority of
    InertCanvasAuthority lease reason -> Just (lease, reason)
    NoCanvasAuthority -> Nothing
    WritableCanvasAuthority _ -> Nothing

revokeCanvasAuthority :: InertReason -> CanvasAuthority -> CanvasAuthority
revokeCanvasAuthority reason authority =
  case authority of
    NoCanvasAuthority -> NoCanvasAuthority
    WritableCanvasAuthority lease -> InertCanvasAuthority lease reason
    InertCanvasAuthority lease _ -> InertCanvasAuthority lease reason

data LeaseError
  = PaintForWrongRevision !Revision !Revision
  | PaintForWrongTicket !RenderTicket !RenderTicket
  | PaintForWrongSurface !SurfaceAddress !SurfaceAddress
  deriving stock (Eq, Show)

-- | Promote an acknowledged plan only when every current fence agrees.
acknowledgePaint
  :: PaintRequest
  -> RenderPlan
  -> Either LeaseError CanvasAuthority
acknowledgePaint request plan
  | renderPlanRevision plan /= revision =
      Left (PaintForWrongRevision revision (renderPlanRevision plan))
  | renderPlanTicket plan /= ticket =
      Left (PaintForWrongTicket ticket (renderPlanTicket plan))
  | renderPlanSurface plan /= surface =
      Left (PaintForWrongSurface surface (renderPlanSurface plan))
  | otherwise =
      Right
        ( WritableCanvasAuthority
            ( PaintedCanvasLease
                (LeaseFence session revision ticket surface)
                plan
            )
        )
  where
    session = paintRequestSession request
    revision = paintRequestRevision request
    ticket = paintRequestTicket request
    surface = paintRequestSurface request

authorityAllowsEdit
  :: PaintRequest
  -> CanvasAuthority
  -> Bool
authorityAllowsEdit request authority =
  case writableCanvasAuthority authority of
    Nothing -> False
    Just lease ->
      let fence = paintedLeaseFence lease
       in leaseFenceSession fence == paintRequestSession request
            && leaseFenceRevision fence == paintRequestRevision request
            && leaseFenceTicket fence == paintRequestTicket request
            && leaseFenceSurface fence == paintRequestSurface request
