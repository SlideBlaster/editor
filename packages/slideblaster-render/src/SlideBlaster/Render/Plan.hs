{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Render.Plan
-- Description : Closed, revision-fenced render instructions.
--
-- A valid plan is a disposable, self-contained paint instruction for exactly
-- one semantic surface. Every style is direct, every outline and path is
-- resolved geometry, every external byte is embedded in the manifest, every
-- interaction selects its owning element, and every animation target occurs in
-- the plan. Hosts translate this vocabulary; they do not resolve semantics.
module SlideBlaster.Render.Plan
  ( RenderTicket
  , renderTicketFromWord64
  , renderTicketToWord64
  , RenderPart
  , mkRenderPart
  , renderPartText
  , RenderIdentity (..)
  , RenderVisibility (..)
  , Accessibility (..)
  , Interaction (..)
  , RenderMediaControls (..)
  , RenderMediaStart (..)
  , RenderMediaLoop (..)
  , RenderMediaAudio (..)
  , RenderMediaPlayback (..)
  , RenderMedia (..)
  , RenderArrowTip (..)
  , RenderArrowTips (..)
  , noRenderArrowTips
  , RenderAnimation
  , renderAnimationStart
  , renderAnimationValue
  , RenderPrimitiveKind (..)
  , RenderPrimitive (..)
  , renderPrimitiveKind
  , RenderItem (..)
  , RenderLayerKind (..)
  , RenderLayer (..)
  , RenderPlan
  , RenderPlanError (..)
  , mkRenderPlan
  , renderPlanAnimations
  , renderPlanLayers
  , renderPlanResources
  , renderPlanRevision
  , renderPlanSize
  , renderPlanStep
  , renderPlanSurface
  , renderPlanTicket
  , visibilityForOverlay
  ) where

import SlideBlaster.Canvas
  ( Box
  , ElementId (..)
  , FurnitureId
  , OverlayHook
  , OverlayStep
  , Size
  , overlayVisibleAt
  )
import SlideBlaster.Presentation
  ( Animation
  , AnimationId
  , AnimationStart (..)
  , AnimationTarget (..)
  , AnimationTimeline
  , ElementAddress
  , SurfaceAddress
  , animationSchedule
  , animationId
  , animationTimelineAnimations
  , animationTracks
  , animationsForStep
  , elementAddressElement
  , elementAddressSurface
  , scheduleStart
  , trackTarget
  )
import SlideBlaster.Render.Content
  ( RenderContent
  , RenderImageFit
  , renderContentResourceReferences
  )
import SlideBlaster.Render.Geometry
  ( RenderClip
  , RenderHitRegion
  , RenderHitRegionView (NoRenderHitRegionView)
  , RenderOutline
  , RenderPath
  , RenderTransform
  , renderHitRegionView
  )
import SlideBlaster.Render.Resource
  ( ResourceId
  , ResourceManifest
  , ResourceReference (..)
  , ResourceReferenceError
  , ResourceReferenceKind
      ( BinaryReference
      , ImageReference
      )
  , validateResourceReferences
  )
import SlideBlaster.Render.Style
  ( RenderShapeStyle
  , RenderStroke
  )
import SlideBlaster.Source (Revision)

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)

-- | Correlation fence for one layout/paint attempt.
newtype RenderTicket = RenderTicket Word64
  deriving stock (Eq, Ord, Show)

renderTicketFromWord64 :: Word64 -> RenderTicket
renderTicketFromWord64 = RenderTicket

renderTicketToWord64 :: RenderTicket -> Word64
renderTicketToWord64 (RenderTicket value) = value

-- | Stable non-empty sub-part used when an element or furniture item emits
-- several primitives.
newtype RenderPart = RenderPart Text
  deriving stock (Eq, Ord, Show)

mkRenderPart :: Text -> Maybe RenderPart
mkRenderPart value
  | Text.null (Text.strip value) = Nothing
  | otherwise = Just (RenderPart value)

renderPartText :: RenderPart -> Text
renderPartText (RenderPart value) = value

-- | Stable identity for one paint part. Furniture identity is explicitly
-- multipart so a logo, label, and backing shape do not alias one another.
data RenderIdentity
  = ElementRender !ElementAddress !RenderPart
  | FurnitureRender !SurfaceAddress !FurnitureId !RenderPart
  | BackgroundRender !SurfaceAddress !RenderPart
  deriving stock (Eq, Ord, Show)

data RenderVisibility
  = RenderVisible
  | RenderHiddenReserved
  deriving stock (Eq, Ord, Show)

data Accessibility
  = Decorative
  | Labelled !Text
  deriving stock (Eq, Ord, Show)

data Interaction
  = Inert
  | SelectElement !ElementAddress
  deriving stock (Eq, Ord, Show)

data RenderMediaControls
  = ShowMediaControls
  | HideMediaControls
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderMediaStart
  = StartMediaManually
  | StartMediaAutomatically
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderMediaLoop
  = PlayMediaOnce
  | LoopMedia
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderMediaAudio
  = MediaAudible
  | MediaMuted
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderMediaPlayback = RenderMediaPlayback
  { renderMediaControls :: !RenderMediaControls
  , renderMediaStart :: !RenderMediaStart
  , renderMediaLoop :: !RenderMediaLoop
  , renderMediaAudio :: !RenderMediaAudio
  }
  deriving stock (Eq, Ord, Show)

data RenderMedia
  = RenderVideo !RenderMediaPlayback
  | RenderAudio !RenderMediaPlayback
  | RenderEmbeddedDocument
  deriving stock (Eq, Ord, Show)

-- | Direct geometry for one connector endpoint. Filled tips are first-class
-- connector paint, so a host never has to synthesize SVG marker definitions.
data RenderArrowTip
  = NoRenderArrowTip
  | StrokedRenderArrowTip !RenderPath !RenderStroke
  | FilledRenderArrowTip !RenderOutline !RenderShapeStyle
  deriving stock (Eq, Show)

data RenderArrowTips = RenderArrowTips
  { renderStartArrowTip :: !RenderArrowTip
  , renderEndArrowTip :: !RenderArrowTip
  }
  deriving stock (Eq, Show)

noRenderArrowTips :: RenderArrowTips
noRenderArrowTips =
  RenderArrowTips
    { renderStartArrowTip = NoRenderArrowTip
    , renderEndArrowTip = NoRenderArrowTip
    }

-- | One animation whose dependency trigger has already been resolved to a
-- concrete start relation within this plan's overlay beat.
data RenderAnimation = RenderAnimation
  !Animation
  !AnimationStart
  deriving stock (Eq, Show)

renderAnimationValue :: RenderAnimation -> Animation
renderAnimationValue (RenderAnimation animation _) = animation

renderAnimationStart :: RenderAnimation -> AnimationStart
renderAnimationStart (RenderAnimation _ start) = start

data RenderPrimitiveKind
  = ShapePrimitiveKind
  | ContentPrimitiveKind
  | ConnectorPrimitiveKind
  | ImagePrimitiveKind
  | MediaPrimitiveKind
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Closed target-neutral drawing vocabulary. There is intentionally no
-- semantic canvas content/property, source-outline, asset-id, or stencil-id
-- constructor here.
data RenderPrimitive
  = ShapePrimitive !RenderOutline !RenderShapeStyle
  | ContentPrimitive !RenderContent !Box
  | ConnectorPrimitive !RenderPath !RenderStroke !RenderArrowTips
  | ImagePrimitive !ResourceId !Box !RenderImageFit
  | MediaPrimitive !ResourceId !Box !RenderMedia
  deriving stock (Eq, Show)

renderPrimitiveKind :: RenderPrimitive -> RenderPrimitiveKind
renderPrimitiveKind primitive =
  case primitive of
    ShapePrimitive {} -> ShapePrimitiveKind
    ContentPrimitive {} -> ContentPrimitiveKind
    ConnectorPrimitive {} -> ConnectorPrimitiveKind
    ImagePrimitive {} -> ImagePrimitiveKind
    MediaPrimitive {} -> MediaPrimitiveKind

data RenderItem = RenderItem
  { renderItemIdentity :: !RenderIdentity
  , renderItemVisibility :: !RenderVisibility
  , renderItemPrimitive :: !RenderPrimitive
  , renderItemTransform :: !RenderTransform
  , renderItemClip :: !RenderClip
  , renderItemHitRegion :: !RenderHitRegion
  , renderItemInteraction :: !Interaction
  , renderItemAccessibility :: !Accessibility
  }
  deriving stock (Eq, Show)

-- | Fixed back-to-front order. Layers may be omitted but may not be repeated
-- or reordered.
data RenderLayerKind
  = BackgroundLayer
  | RearFurnitureLayer
  | ConnectorLayer
  | ObjectLayer
  | ContentLayer
  | FrontFurnitureLayer
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderLayer = RenderLayer
  { renderLayerKind :: !RenderLayerKind
  , renderLayerItems :: ![RenderItem]
  }
  deriving stock (Eq, Show)

data RenderPlan = RenderPlan
  !Revision
  !RenderTicket
  !SurfaceAddress
  !OverlayStep
  !Size
  !ResourceManifest
  !(NonEmpty RenderLayer)
  ![RenderAnimation]
  deriving stock (Eq, Show)

data RenderPlanError
  = RenderIdentityOutsideSurface !RenderIdentity !SurfaceAddress
  | RenderInteractionOutsideSurface !ElementAddress !SurfaceAddress
  | RenderInteractionIdentityMismatch !ElementAddress !ElementAddress
  | NonElementRenderItemInteractive !RenderIdentity !ElementAddress
  | InteractiveRenderItemHasNoHitRegion !RenderIdentity
  | RenderIdentityInWrongLayer !RenderIdentity !RenderLayerKind
  | RenderPrimitiveInWrongLayer
      !RenderIdentity
      !RenderPrimitiveKind
      !RenderLayerKind
  | RenderElementPrimitiveMismatch !ElementId !RenderPrimitiveKind
  | RenderLayerOrderInvalid !RenderLayerKind !RenderLayerKind
  | DuplicateRenderIdentity !RenderIdentity
  | RenderResourceInvalid !ResourceReferenceError
  | RenderAnimationTargetMissing !AnimationId !ElementId
  | RenderAnimationClickTargetMissing !AnimationId !ElementId
  | RenderAnimationScheduleMissing !AnimationId
  deriving stock (Eq, Show)

-- | Validate and construct one disposable, self-contained plan.
mkRenderPlan
  :: Revision
  -> RenderTicket
  -> SurfaceAddress
  -> OverlayStep
  -> Size
  -> ResourceManifest
  -> NonEmpty RenderLayer
  -> AnimationTimeline
  -> Either RenderPlanError RenderPlan
mkRenderPlan revision ticket surface step size resources layers timeline = do
  validateLayerOrder layers
  _ <- validateLayers surface Set.empty layers
  mapResourceError
    ( validateResourceReferences
        resources
        (foldMap layerResourceReferences layers)
    )
  validateAnimations
    (renderedElementIds layers)
    timeline
    (animationTimelineAnimations timeline)
  animations <- renderAnimationsForStep step timeline
  Right
    ( RenderPlan
        revision
        ticket
        surface
        step
        size
        resources
        layers
        animations
    )

renderPlanRevision :: RenderPlan -> Revision
renderPlanRevision (RenderPlan revision _ _ _ _ _ _ _) = revision

renderPlanTicket :: RenderPlan -> RenderTicket
renderPlanTicket (RenderPlan _ ticket _ _ _ _ _ _) = ticket

renderPlanSurface :: RenderPlan -> SurfaceAddress
renderPlanSurface (RenderPlan _ _ surface _ _ _ _ _) = surface

renderPlanStep :: RenderPlan -> OverlayStep
renderPlanStep (RenderPlan _ _ _ step _ _ _ _) = step

renderPlanSize :: RenderPlan -> Size
renderPlanSize (RenderPlan _ _ _ _ size _ _ _) = size

renderPlanResources :: RenderPlan -> ResourceManifest
renderPlanResources (RenderPlan _ _ _ _ _ resources _ _) = resources

renderPlanLayers :: RenderPlan -> NonEmpty RenderLayer
renderPlanLayers (RenderPlan _ _ _ _ _ _ layers _) = layers

renderPlanAnimations :: RenderPlan -> [RenderAnimation]
renderPlanAnimations (RenderPlan _ _ _ _ _ _ _ animations) = animations

visibilityForOverlay :: OverlayStep -> OverlayHook -> RenderVisibility
visibilityForOverlay step hook
  | overlayVisibleAt step hook = RenderVisible
  | otherwise = RenderHiddenReserved

validateLayers
  :: SurfaceAddress
  -> Set RenderIdentity
  -> NonEmpty RenderLayer
  -> Either RenderPlanError (Set RenderIdentity)
validateLayers surface seen layers =
  validateLayerList surface seen (NonEmpty.toList layers)

validateLayerList
  :: SurfaceAddress
  -> Set RenderIdentity
  -> [RenderLayer]
  -> Either RenderPlanError (Set RenderIdentity)
validateLayerList _ seen [] = Right seen
validateLayerList surface seen (layer : remaining) = do
  nextSeen <-
    validateItems
      surface
      (renderLayerKind layer)
      seen
      (renderLayerItems layer)
  validateLayerList surface nextSeen remaining

validateItems
  :: SurfaceAddress
  -> RenderLayerKind
  -> Set RenderIdentity
  -> [RenderItem]
  -> Either RenderPlanError (Set RenderIdentity)
validateItems _ _ seen [] = Right seen
validateItems surface layerKind seen (item : remaining) = do
  validateIdentitySurface surface identity
  validateIdentityLayer layerKind identity
  validatePrimitiveLayer layerKind item
  validateElementPrimitive identity (renderItemPrimitive item)
  validateInteraction
    surface
    identity
    (renderItemHitRegion item)
    (renderItemInteraction item)
  if Set.member identity seen
    then Left (DuplicateRenderIdentity identity)
    else
      validateItems
        surface
        layerKind
        (Set.insert identity seen)
        remaining
  where
    identity = renderItemIdentity item

validateIdentitySurface
  :: SurfaceAddress
  -> RenderIdentity
  -> Either RenderPlanError ()
validateIdentitySurface expected identity
  | renderIdentitySurface identity == expected = Right ()
  | otherwise = Left (RenderIdentityOutsideSurface identity expected)

validateInteraction
  :: SurfaceAddress
  -> RenderIdentity
  -> RenderHitRegion
  -> Interaction
  -> Either RenderPlanError ()
validateInteraction _ _ _ Inert = Right ()
validateInteraction _ identity hitRegion (SelectElement _)
  | NoRenderHitRegionView <- renderHitRegionView hitRegion =
      Left (InteractiveRenderItemHasNoHitRegion identity)
validateInteraction expected identity _ (SelectElement address)
  | elementAddressSurface address /= expected =
      Left (RenderInteractionOutsideSurface address expected)
  | ElementRender owner _ <- identity
  , owner == address =
      Right ()
  | ElementRender owner _ <- identity =
      Left (RenderInteractionIdentityMismatch owner address)
  | otherwise =
      Left (NonElementRenderItemInteractive identity address)

renderIdentitySurface :: RenderIdentity -> SurfaceAddress
renderIdentitySurface identity =
  case identity of
    ElementRender address _ -> elementAddressSurface address
    FurnitureRender surface _ _ -> surface
    BackgroundRender surface _ -> surface

validateIdentityLayer
  :: RenderLayerKind
  -> RenderIdentity
  -> Either RenderPlanError ()
validateIdentityLayer layer identity
  | identityBelongsInLayer layer identity = Right ()
  | otherwise = Left (RenderIdentityInWrongLayer identity layer)

identityBelongsInLayer :: RenderLayerKind -> RenderIdentity -> Bool
identityBelongsInLayer layer identity =
  case (layer, identity) of
    (BackgroundLayer, BackgroundRender {}) -> True
    (RearFurnitureLayer, FurnitureRender {}) -> True
    (FrontFurnitureLayer, FurnitureRender {}) -> True
    (ConnectorLayer, ElementRender {}) -> True
    (ObjectLayer, ElementRender {}) -> True
    (ContentLayer, ElementRender {}) -> True
    _ -> False

validatePrimitiveLayer
  :: RenderLayerKind
  -> RenderItem
  -> Either RenderPlanError ()
validatePrimitiveLayer layer item
  | primitiveBelongsInLayer layer (renderItemPrimitive item) = Right ()
  | otherwise =
      Left
        ( RenderPrimitiveInWrongLayer
            (renderItemIdentity item)
            (renderPrimitiveKind (renderItemPrimitive item))
            layer
        )

validateElementPrimitive
  :: RenderIdentity
  -> RenderPrimitive
  -> Either RenderPlanError ()
validateElementPrimitive identity primitive =
  case identity of
    ElementRender address _
      | elementAcceptsPrimitive
          (elementAddressElement address)
          (renderPrimitiveKind primitive) ->
          Right ()
      | otherwise ->
          Left
            ( RenderElementPrimitiveMismatch
                (elementAddressElement address)
                (renderPrimitiveKind primitive)
            )
    FurnitureRender {} -> Right ()
    BackgroundRender {} -> Right ()

elementAcceptsPrimitive :: ElementId -> RenderPrimitiveKind -> Bool
elementAcceptsPrimitive element primitive =
  case (element, primitive) of
    (NodeElement {}, ShapePrimitiveKind) -> True
    (NodeElement {}, ContentPrimitiveKind) -> True
    (NodeElement {}, ImagePrimitiveKind) -> True
    (NodeElement {}, MediaPrimitiveKind) -> True
    (ConnectorElement {}, ConnectorPrimitiveKind) -> True
    -- Groups are semantic containers. Their children emit paint identities;
    -- accepting an unrelated leaf primitive for a group would make group
    -- animation and hit ownership ambiguous.
    (GroupElement {}, _) -> False
    _ -> False

primitiveBelongsInLayer :: RenderLayerKind -> RenderPrimitive -> Bool
primitiveBelongsInLayer layer primitive =
  case (layer, renderPrimitiveKind primitive) of
    (BackgroundLayer, ShapePrimitiveKind) -> True
    (BackgroundLayer, ImagePrimitiveKind) -> True
    (RearFurnitureLayer, ShapePrimitiveKind) -> True
    (RearFurnitureLayer, ContentPrimitiveKind) -> True
    (RearFurnitureLayer, ImagePrimitiveKind) -> True
    (ConnectorLayer, ConnectorPrimitiveKind) -> True
    (ObjectLayer, ShapePrimitiveKind) -> True
    (ObjectLayer, ImagePrimitiveKind) -> True
    (ContentLayer, ContentPrimitiveKind) -> True
    (ContentLayer, MediaPrimitiveKind) -> True
    (FrontFurnitureLayer, ShapePrimitiveKind) -> True
    (FrontFurnitureLayer, ContentPrimitiveKind) -> True
    (FrontFurnitureLayer, ImagePrimitiveKind) -> True
    _ -> False

validateLayerOrder :: NonEmpty RenderLayer -> Either RenderPlanError ()
validateLayerOrder (first :| remaining) =
  go (renderLayerKind first) remaining
  where
    go _ [] = Right ()
    go previous (current : rest)
      | renderLayerKind current > previous =
          go (renderLayerKind current) rest
      | otherwise =
          Left
            (RenderLayerOrderInvalid previous (renderLayerKind current))

layerResourceReferences :: RenderLayer -> Set ResourceReference
layerResourceReferences =
  foldMap itemResourceReferences . renderLayerItems

itemResourceReferences :: RenderItem -> Set ResourceReference
itemResourceReferences = primitiveResourceReferences . renderItemPrimitive

primitiveResourceReferences :: RenderPrimitive -> Set ResourceReference
primitiveResourceReferences primitive =
  case primitive of
    ShapePrimitive {} -> Set.empty
    ContentPrimitive content _ ->
      renderContentResourceReferences content
    ConnectorPrimitive {} -> Set.empty
    ImagePrimitive resource _ _ ->
      Set.singleton (ResourceReference resource ImageReference)
    MediaPrimitive resource _ _ ->
      Set.singleton (ResourceReference resource BinaryReference)

mapResourceError
  :: Either ResourceReferenceError ()
  -> Either RenderPlanError ()
mapResourceError result =
  case result of
    Left failure -> Left (RenderResourceInvalid failure)
    Right () -> Right ()

renderedElementIds :: NonEmpty RenderLayer -> Set ElementId
renderedElementIds =
  foldMap layerElementIds

layerElementIds :: RenderLayer -> Set ElementId
layerElementIds =
  foldMap itemElementIds . renderLayerItems

itemElementIds :: RenderItem -> Set ElementId
itemElementIds item =
  case renderItemIdentity item of
    ElementRender address _ ->
      Set.singleton (elementAddressElement address)
    FurnitureRender {} -> Set.empty
    BackgroundRender {} -> Set.empty

validateAnimations
  :: Set ElementId
  -> AnimationTimeline
  -> [Animation]
  -> Either RenderPlanError ()
validateAnimations _ _ [] = Right ()
validateAnimations rendered timeline (animation : remaining) = do
  validateAnimationTargets rendered animation
  case animationSchedule timeline (animationId animation) of
    Nothing ->
      Left (RenderAnimationScheduleMissing (animationId animation))
    Just schedule ->
      validateAnimationStart
        rendered
        (animationId animation)
        (scheduleStart schedule)
  validateAnimations rendered timeline remaining

validateAnimationTargets
  :: Set ElementId
  -> Animation
  -> Either RenderPlanError ()
validateAnimationTargets rendered animation =
  validateTargetList
    (animationId animation)
    rendered
    (fmap trackTarget (NonEmpty.toList (animationTracks animation)))

validateTargetList
  :: AnimationId
  -> Set ElementId
  -> [AnimationTarget]
  -> Either RenderPlanError ()
validateTargetList _ _ [] = Right ()
validateTargetList identity rendered (target : remaining) =
  case target of
    SlideSurface ->
      validateTargetList identity rendered remaining
    PictureElement element
      | Set.member element rendered ->
          validateTargetList identity rendered remaining
      | otherwise ->
          Left (RenderAnimationTargetMissing identity element)

renderAnimationsForStep
  :: OverlayStep
  -> AnimationTimeline
  -> Either RenderPlanError [RenderAnimation]
renderAnimationsForStep step timeline =
  traverse toRenderAnimation (animationsForStep step timeline)
  where
    toRenderAnimation animation =
      case animationSchedule timeline (animationId animation) of
        Nothing ->
          Left (RenderAnimationScheduleMissing (animationId animation))
        Just schedule ->
          Right (RenderAnimation animation (scheduleStart schedule))

validateAnimationStart
  :: Set ElementId
  -> AnimationId
  -> AnimationStart
  -> Either RenderPlanError ()
validateAnimationStart rendered identity start =
  case start of
    StartOnTargetClick SlideSurface -> Right ()
    StartOnTargetClick (PictureElement element)
      | Set.member element rendered -> Right ()
      | otherwise ->
          Left (RenderAnimationClickTargetMissing identity element)
    StartAtBeatEntry -> Right ()
    StartAtTimelineOffset {} -> Right ()
    StartWithAnimation {} -> Right ()
    StartAfterAnimation {} -> Right ()
