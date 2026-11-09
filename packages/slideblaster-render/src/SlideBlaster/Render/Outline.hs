-- |
-- Module      : SlideBlaster.Render.Outline
-- Description : Lower generic canvas outlines into direct render geometry.
--
-- Catalog and source adapters supply a stencil resolver; this module never
-- imports catalog metadata. Every successful result contains only slide-space
-- geometry, including resolved elliptical arc segments. Missing, cyclic, or
-- intentionally opaque geometry fails with a typed cause before a host paints.
module SlideBlaster.Render.Outline
  ( StencilResolver
  , OutlineLoweringError (..)
  , lowerOutlineRef
  ) where

import SlideBlaster.Canvas
  ( ArcRadii
  , ArcSize (..)
  , ArcSweep (..)
  , Box
  , CanvasUnit
  , CustomGeometryId
  , OutlinePoint
  , OutlineRef (..)
  , PathCommand (..)
  , PathOutline
  , Point
  , PolygonOutline
  , PrimitiveOutline (..)
  , SourceRef
  , StencilId
  , arcRadiusX
  , arcRadiusY
  , boxSize
  , outlinePointToCanvas
  , outlineRadiusValue
  , pathOutlineCommands
  , polygonOutlinePoints
  , scaleUnit
  , sizeHeight
  , sizeWidth
  )
import SlideBlaster.Render.Geometry
  ( RenderArcSize (..)
  , RenderArcSweep (..)
  , RenderFillRule (RenderNonZeroFill)
  , RenderGeometryError
  , RenderOutline
  , RenderPath
  , RenderPathClosure (..)
  , RenderPathSegment (..)
  , mkRenderArcRadii
  , mkRenderCornerRadii
  , mkRenderPath
  , mkRenderPolygon
  , mkRenderRectangle
  , renderEllipse
  , renderPathOutline
  , zeroRenderCornerRadii
  )

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set

-- | Resolve a catalog- or format-owned stencil identity to generic geometry.
type StencilResolver = StencilId -> Maybe OutlineRef

data OutlineLoweringError
  = MissingStencilGeometry !StencilId
  | CyclicStencilGeometry !StencilId
  | CustomGeometryNeedsAdapter !CustomGeometryId
  | UnsupportedSourceGeometry !SourceRef
  | PrimitiveArcNeedsEndpoints
  | InvalidResolvedOutline !RenderGeometryError
  | InvalidResolvedPath
  deriving stock (Eq, Show)

-- | Resolve one source outline into one or more direct slide-space outlines.
lowerOutlineRef
  :: StencilResolver
  -> Box
  -> OutlineRef
  -> Either OutlineLoweringError (NonEmpty RenderOutline)
lowerOutlineRef resolveStencil target =
  lower Set.empty
  where
    lower seen outline =
      case outline of
        PrimitiveGeometry primitive ->
          (:| []) <$> lowerPrimitive target primitive
        PolygonGeometry polygon ->
          mapGeometryError
            ( (:| [])
                <$> mkRenderPolygon
                  (fmap (outlinePointToCanvas target) (polygonPoints polygon))
            )
        PathGeometry path ->
          (:| [])
            . renderPathOutline RenderNonZeroFill
            <$> lowerPath target path
        CompoundGeometry children ->
          concatNonEmpty <$> traverse (lower seen) children
        StencilGeometry identity
          | Set.member identity seen ->
              Left (CyclicStencilGeometry identity)
          | otherwise ->
              case resolveStencil identity of
                Nothing -> Left (MissingStencilGeometry identity)
                Just resolved ->
                  lower (Set.insert identity seen) resolved
        CustomGeometry identity ->
          Left (CustomGeometryNeedsAdapter identity)
        UnsupportedGeometry source ->
          Left (UnsupportedSourceGeometry source)

lowerPrimitive
  :: Box
  -> PrimitiveOutline
  -> Either OutlineLoweringError RenderOutline
lowerPrimitive target primitive =
  case primitive of
    RectangleOutline ->
      Right (mkRenderRectangle target zeroRenderCornerRadii)
    RoundedRectangleOutline radius -> do
      corners <-
        mapGeometryError
          ( mkRenderCornerRadii
              (outlineRadiusValue radius)
              (outlineRadiusValue radius)
              (outlineRadiusValue radius)
              (outlineRadiusValue radius)
          )
      Right (mkRenderRectangle target corners)
    EllipseOutline -> Right (renderEllipse target)
    ArcOutline {} -> Left PrimitiveArcNeedsEndpoints

lowerPath
  :: Box
  -> PathOutline
  -> Either OutlineLoweringError (NonEmpty RenderPath)
lowerPath target path =
  case NonEmpty.toList (pathOutlineCommands path) of
    MovePath start : remaining ->
      finishPaths
        =<< collectSubpath
          (outlinePointToCanvas target start)
          []
          remaining
    _ -> Left InvalidResolvedPath
  where
    collectSubpath start reversedSegments remaining =
      case remaining of
        [] -> do
          pathValue <- makePath start reversedSegments RenderOpenPath
          Right ([pathValue], Nothing)
        MovePath next : later -> do
          pathValue <- makePath start reversedSegments RenderOpenPath
          Right
            ( [pathValue]
            , Just (outlinePointToCanvas target next, later)
            )
        ClosePath : later -> do
          pathValue <- makePath start reversedSegments RenderClosedPath
          case later of
            [] -> Right ([pathValue], Nothing)
            MovePath next : afterMove ->
              Right
                ( [pathValue]
                , Just (outlinePointToCanvas target next, afterMove)
                )
            _ -> Left InvalidResolvedPath
        command : later -> do
          segment <- lowerSegment target command
          collectSubpath start (segment : reversedSegments) later

    finishPaths (paths, continuation) =
      case continuation of
        Nothing ->
          maybe (Left InvalidResolvedPath) Right (NonEmpty.nonEmpty paths)
        Just (nextStart, remaining) -> do
          (laterPaths, following) <-
            collectSubpath nextStart [] remaining
          combined <- finishPaths (laterPaths, following)
          Right (appendList paths combined)

makePath
  :: Point
  -> [RenderPathSegment]
  -> RenderPathClosure
  -> Either OutlineLoweringError RenderPath
makePath start reversedSegments closure =
  case NonEmpty.nonEmpty (reverse reversedSegments) of
    Nothing -> Left InvalidResolvedPath
    Just segments -> Right (mkRenderPath start segments closure)

lowerSegment
  :: Box
  -> PathCommand
  -> Either OutlineLoweringError RenderPathSegment
lowerSegment target command =
  case command of
    LinePath endpoint ->
      Right (RenderLineTo (outlinePointToCanvas target endpoint))
    QuadraticPath control endpoint ->
      Right
        ( RenderQuadraticTo
            (outlinePointToCanvas target control)
            (outlinePointToCanvas target endpoint)
        )
    CubicPath firstControl secondControl endpoint ->
      Right
        ( RenderCubicTo
            (outlinePointToCanvas target firstControl)
            (outlinePointToCanvas target secondControl)
            (outlinePointToCanvas target endpoint)
        )
    ArcPath radii rotation arcSize arcSweep endpoint -> do
      resolvedRadii <-
        mapGeometryError
          ( mkRenderArcRadii
              (resolvedRadiusX target radii)
              (resolvedRadiusY target radii)
          )
      Right
        ( RenderArcTo
            resolvedRadii
            rotation
            (lowerArcSize arcSize)
            (lowerArcSweep arcSweep)
            (outlinePointToCanvas target endpoint)
        )
    MovePath {} -> Left InvalidResolvedPath
    ClosePath -> Left InvalidResolvedPath

resolvedRadiusX :: Box -> ArcRadii -> CanvasUnit
resolvedRadiusX target radii =
  scaleUnit
    (arcRadiusX radii / 2)
    (sizeWidth (boxSize target))

resolvedRadiusY :: Box -> ArcRadii -> CanvasUnit
resolvedRadiusY target radii =
  scaleUnit
    (arcRadiusY radii / 2)
    (sizeHeight (boxSize target))

lowerArcSize :: ArcSize -> RenderArcSize
lowerArcSize arcSize =
  case arcSize of
    SmallArc -> RenderSmallArc
    LargeArc -> RenderLargeArc

lowerArcSweep :: ArcSweep -> RenderArcSweep
lowerArcSweep arcSweep =
  case arcSweep of
    CounterClockwiseArc -> RenderCounterClockwiseArc
    ClockwiseArc -> RenderClockwiseArc

polygonPoints
  :: PolygonOutline
  -> NonEmpty OutlinePoint
polygonPoints = polygonOutlinePoints

concatNonEmpty :: NonEmpty (NonEmpty value) -> NonEmpty value
concatNonEmpty (first :| remaining) =
  foldl (<>) first remaining

appendList :: [value] -> NonEmpty value -> NonEmpty value
appendList prefix suffix =
  case prefix of
    [] -> suffix
    first : remaining ->
      first :| (remaining <> NonEmpty.toList suffix)

mapGeometryError
  :: Either RenderGeometryError value
  -> Either OutlineLoweringError value
mapGeometryError result =
  case result of
    Left failure -> Left (InvalidResolvedOutline failure)
    Right value -> Right value
