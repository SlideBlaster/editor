{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Engine.CommonTikz
-- Description : Closed render composition for admitted source-backed pictures.
--
-- This portable composition renders every admitted node and straight connector
-- on one requested audience surface. Empty pictures are valid. Authored mixed
-- content remains source-authoritative and intentionally unpainted until exact
-- structured measurement is available.
module SlideBlaster.Engine.CommonTikz
  ( CommonTikzRenderError (..)
  , renderCommonTikzPlan
  , renderPresentationSurfacePlan
  ) where

import SlideBlaster.Canvas qualified as Canvas
import SlideBlaster.Document qualified as Document
import SlideBlaster.Presentation qualified as Presentation
import SlideBlaster.Render qualified as Render
import SlideBlaster.Source qualified as Source
import SlideBlaster.TikZ.Adapter (CommonTikzDocument)

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map

-- | Typed failures at the bounded common render seam.
data CommonTikzRenderError
  = CommonTikzRenderSyntaxOnly
  | CommonTikzRenderSurfaceMissing
  | CommonTikzRenderPlacementUnsupported !Canvas.Placement
  | CommonTikzRenderConnectorUnsupported
  | CommonTikzRenderConnectorResolution !Canvas.AnchorResolutionError
  | CommonTikzRenderStyle !Render.RenderStyleError
  | CommonTikzRenderPlan !Render.RenderPlanError
  | CommonTikzRenderInvariant
  deriving stock (Eq, Show)

-- | Compatibility wrapper for the original one-document TikZ slice.
renderCommonTikzPlan
  :: Render.RenderTicket
  -> Canvas.Size
  -> Canvas.Size
  -> CommonTikzDocument
  -> Either CommonTikzRenderError Render.RenderPlan
renderCommonTikzPlan ticket slideSize nodeSize document = do
  presentation <- maybe (Left CommonTikzRenderSyntaxOnly) Right (Document.documentSemantic document)
  let firstFrame :| _ = Presentation.presentationFrames presentation
      surface = Presentation.surfaceAddress (Presentation.frameId firstFrame) Presentation.AudienceSurface
  renderPresentationSurfacePlan ticket slideSize nodeSize (const True) surface (Document.documentSource document) presentation

-- | Render all admitted objects on one exact requested surface. The supplied
-- predicate controls interaction projection only; inert nodes remain painted.
renderPresentationSurfacePlan
  :: Render.RenderTicket
  -> Canvas.Size
  -> Canvas.Size
  -> (Canvas.NodeId -> Bool)
  -> Presentation.SurfaceAddress
  -> Source.SourceBufferSnapshot
  -> Presentation.Presentation
  -> Either CommonTikzRenderError Render.RenderPlan
renderPresentationSurfacePlan ticket slideSize nodeSize isWritable surface source presentation = do
  picture <- surfacePicture surface presentation
  stroke <-
    mapLeft CommonTikzRenderStyle
      ( Render.mkRenderStroke
          black
          (Canvas.canvasUnit (1 / 50))
          Render.renderSolidDash
          Render.RenderButtCap
          Render.RenderMiterJoin
      )
  shapePart <- maybe (Left CommonTikzRenderInvariant) Right (Render.mkRenderPart "shape")
  pathPart <- maybe (Left CommonTikzRenderInvariant) Right (Render.mkRenderPart "path")
  nodePairs <- traverse (nodeBox nodeSize) [node | Canvas.CanvasNode node <- Canvas.pictureElements picture]
  let boxes = Map.fromList [(Canvas.nodeIdentifier node, box) | (node, box) <- nodePairs]
      nodeItems = fmap (nodeItem isWritable surface stroke shapePart) nodePairs
  connectorItems <-
    traverse
      (connectorItem surface stroke pathPart boxes)
      [connector | Canvas.CanvasConnector connector <- Canvas.pictureElements picture]
  let layers =
        Render.RenderLayer Render.ConnectorLayer connectorItems
          :| [Render.RenderLayer Render.ObjectLayer nodeItems]
  mapLeft CommonTikzRenderPlan
    ( Render.mkRenderPlan
        (Source.snapshotRevision source)
        ticket
        surface
        Canvas.firstOverlayStep
        slideSize
        Render.emptyResourceManifest
        layers
        Presentation.emptyAnimationTimeline
    )

surfacePicture
  :: Presentation.SurfaceAddress
  -> Presentation.Presentation
  -> Either CommonTikzRenderError Canvas.Picture
surfacePicture surface presentation =
  case findFrame (Presentation.surfaceAddressFrame surface) (NonEmpty.toList (Presentation.presentationFrames presentation)) of
    Nothing -> Left CommonTikzRenderSurfaceMissing
    Just frame -> case Presentation.surfaceAddressKind surface of
      Presentation.AudienceSurface -> Right (Presentation.frameAudiencePicture frame)
      Presentation.NotesSurface ->
        case Presentation.frameNotes frame of
          Nothing -> Left CommonTikzRenderSurfaceMissing
          Just notes -> Right (Presentation.notesPicture notes)

findFrame :: Presentation.FrameId -> [Presentation.Frame] -> Maybe Presentation.Frame
findFrame _ [] = Nothing
findFrame wanted (frame : remaining)
  | Presentation.frameId frame == wanted = Just frame
  | otherwise = findFrame wanted remaining

nodeBox :: Canvas.Size -> Canvas.Node -> Either CommonTikzRenderError (Canvas.Node, Canvas.Box)
nodeBox size node =
  case Canvas.nodePlacement node of
    Canvas.AbsolutePlacement anchor port -> Right (node, Canvas.box (centreForPort size anchor port) size)
    unsupported -> Left (CommonTikzRenderPlacementUnsupported unsupported)

centreForPort :: Canvas.Size -> Canvas.Point -> Canvas.BorderPort -> Canvas.Point
centreForPort size anchor port =
  let halfWidth = Canvas.scaleUnit (1 / 2) (Canvas.sizeWidth size)
      halfHeight = Canvas.scaleUnit (1 / 2) (Canvas.sizeHeight size)
      x = Canvas.pointX anchor
      y = Canvas.pointY anchor
      shifted horizontal vertical = Canvas.point (Canvas.addUnits x horizontal) (Canvas.addUnits y vertical)
      negative = Canvas.scaleUnit (-1)
   in case port of
        Canvas.Centre -> anchor
        Canvas.North -> shifted (Canvas.canvasUnit 0) (negative halfHeight)
        Canvas.NorthEast -> shifted (negative halfWidth) (negative halfHeight)
        Canvas.East -> shifted (negative halfWidth) (Canvas.canvasUnit 0)
        Canvas.SouthEast -> shifted (negative halfWidth) halfHeight
        Canvas.South -> shifted (Canvas.canvasUnit 0) halfHeight
        Canvas.SouthWest -> shifted halfWidth halfHeight
        Canvas.West -> shifted halfWidth (Canvas.canvasUnit 0)
        Canvas.NorthWest -> shifted halfWidth (negative halfHeight)

nodeItem
  :: (Canvas.NodeId -> Bool)
  -> Presentation.SurfaceAddress
  -> Render.RenderStroke
  -> Render.RenderPart
  -> (Canvas.Node, Canvas.Box)
  -> Render.RenderItem
nodeItem isWritable surface stroke shapePart (node, box) =
  let address = Presentation.elementAddress surface (Canvas.NodeElement (Canvas.nodeIdentifier node))
      outline = Render.mkRenderRectangle box Render.zeroRenderCornerRadii
      style =
        Render.RenderShapeStyle
          { Render.renderShapePaint = Render.noRenderPaint
          , Render.renderShapeStroke = stroke
          , Render.renderShapeOpacity = Render.opaqueRenderOpacity
          , Render.renderShapeShadows = []
          }
   in Render.RenderItem
        { Render.renderItemIdentity = Render.ElementRender address shapePart
        , Render.renderItemVisibility = Render.RenderVisible
        , Render.renderItemPrimitive = Render.ShapePrimitive outline style
        , Render.renderItemTransform = Render.identityRenderTransform
        , Render.renderItemClip = Render.NoRenderClip
        , Render.renderItemHitRegion = Render.renderOutlineHitRegion outline
        , Render.renderItemInteraction =
            if isWritable (Canvas.nodeIdentifier node)
              then Render.SelectElement address
              else Render.Inert
        , Render.renderItemAccessibility = Render.Decorative
        }

connectorItem
  :: Presentation.SurfaceAddress
  -> Render.RenderStroke
  -> Render.RenderPart
  -> Map.Map Canvas.NodeId Canvas.Box
  -> Canvas.Connector
  -> Either CommonTikzRenderError Render.RenderItem
connectorItem surface stroke pathPart boxes connector = do
  resolved <- mapLeft CommonTikzRenderConnectorResolution (Canvas.resolveConnectorPath boxes (Canvas.connectorPath connector))
  path <- resolvedStraightPath resolved
  let address = Presentation.elementAddress surface (Canvas.ConnectorElement (Canvas.connectorIdentifier connector))
  pure
    Render.RenderItem
      { Render.renderItemIdentity = Render.ElementRender address pathPart
      , Render.renderItemVisibility = Render.RenderVisible
      , Render.renderItemPrimitive = Render.ConnectorPrimitive path stroke Render.noRenderArrowTips
      , Render.renderItemTransform = Render.identityRenderTransform
      , Render.renderItemClip = Render.NoRenderClip
      , Render.renderItemHitRegion = Render.noRenderHitRegion
      , Render.renderItemInteraction = Render.Inert
      , Render.renderItemAccessibility = Render.Decorative
      }

resolvedStraightPath :: Canvas.ResolvedConnectorPath -> Either CommonTikzRenderError Render.RenderPath
resolvedStraightPath resolved =
  case Canvas.resolvedSegments resolved of
    Canvas.ResolvedStraight start endpoint : remaining ->
      case traverse segmentEndpoint remaining of
        Left failure -> Left failure
        Right endpoints ->
          Right
            ( Render.mkRenderPath
                start
                (Render.RenderLineTo endpoint :| fmap Render.RenderLineTo endpoints)
                Render.RenderOpenPath
            )
    _ -> Left CommonTikzRenderConnectorUnsupported
  where
    segmentEndpoint segment = case segment of
      Canvas.ResolvedStraight _ endpoint -> Right endpoint
      _ -> Left CommonTikzRenderConnectorUnsupported

black :: Render.RenderColour
black = Render.RenderColour 0 0 0 255

mapLeft :: (left -> other) -> Either left value -> Either other value
mapLeft convert result = case result of
  Left failure -> Left (convert failure)
  Right value -> Right value
