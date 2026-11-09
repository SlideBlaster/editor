-- |
-- Module      : SlideBlaster.Render.Layout
-- Description : Deterministic authored-placement dependency resolution.
--
-- Render owns derived layout values and failures. Inputs retain only stable
-- node identity, authored placement, and measured size; they do not carry a
-- semantic canvas node or unresolved theme/property state.
module SlideBlaster.Render.Layout
  ( NodeLayoutInput (..)
  , ResolvedNode (..)
  , LayoutError (..)
  , NodeLayoutError
  , resolveNodeLayout
  , resolvedNodeBoxes
  ) where

import SlideBlaster.Canvas
  ( BorderPort
  , Box
  , NodeId
  , Placement (..)
  , Point
  , RelativePlacement (..)
  , RelativeSide (..)
  , Size
  , SourceRef
  , addUnits
  , box
  , canvasUnitFromInteger
  , point
  , pointAtPort
  , pointX
  , pointY
  , subtractUnits
  )

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map

-- | Minimal already-measured input for one layout participant.
data NodeLayoutInput = NodeLayoutInput
  { layoutInputIdentifier :: !NodeId
  , layoutInputPlacement :: !Placement
  , layoutInputSize :: !Size
  }
  deriving stock (Eq, Show)

-- | Disposable render-owned layout result.
data ResolvedNode = ResolvedNode
  { resolvedNodeIdentifier :: !NodeId
  , resolvedNodePlacement :: !Placement
  , resolvedNodeBox :: !Box
  }
  deriving stock (Eq, Show)

data LayoutError
  = DuplicateLayoutNode !NodeId
  | PlacementCycle !(NonEmpty NodeId)
  | MissingPlacementTarget !NodeId !NodeId
  | LayoutUnsupportedPlacement !NodeId !SourceRef
  | LayoutResultMissing !NodeId
  deriving stock (Eq, Show)

-- | Compatibility name for code that used the initial render-owned wrapper.
type NodeLayoutError = LayoutError

data VisitMark = Visiting | Finished !ResolvedNode

-- | Resolve all inputs in input order or reject the entire layout.
resolveNodeLayout
  :: [NodeLayoutInput]
  -> Either LayoutError [ResolvedNode]
resolveNodeLayout inputs = do
  index <- buildIndex Map.empty inputs
  marks <- resolveAll index Map.empty inputs
  collectInInputOrder marks inputs

-- | Build a node-box index for connector anchor resolution.
resolvedNodeBoxes :: [ResolvedNode] -> Map NodeId Box
resolvedNodeBoxes =
  foldr
    ( \resolved ->
        Map.insert
          (resolvedNodeIdentifier resolved)
          (resolvedNodeBox resolved)
    )
    Map.empty

buildIndex
  :: Map NodeId NodeLayoutInput
  -> [NodeLayoutInput]
  -> Either LayoutError (Map NodeId NodeLayoutInput)
buildIndex values [] = Right values
buildIndex values (input : remaining)
  | Map.member identity values =
      Left (DuplicateLayoutNode identity)
  | otherwise =
      buildIndex (Map.insert identity input values) remaining
  where
    identity = layoutInputIdentifier input

resolveAll
  :: Map NodeId NodeLayoutInput
  -> Map NodeId VisitMark
  -> [NodeLayoutInput]
  -> Either LayoutError (Map NodeId VisitMark)
resolveAll _ marks [] = Right marks
resolveAll index marks (input : remaining) = do
  let identity = layoutInputIdentifier input
  (nextMarks, _) <- resolveOne index marks (identity :| []) identity
  resolveAll index nextMarks remaining

resolveOne
  :: Map NodeId NodeLayoutInput
  -> Map NodeId VisitMark
  -> NonEmpty NodeId
  -> NodeId
  -> Either LayoutError (Map NodeId VisitMark, ResolvedNode)
resolveOne index marks path identity =
  case Map.lookup identity marks of
    Just (Finished value) -> Right (marks, value)
    Just Visiting ->
      Left (PlacementCycle path)
    Nothing ->
      case Map.lookup identity index of
        Nothing ->
          let owner = firstPathNode path
           in Left (MissingPlacementTarget owner identity)
        Just input -> do
          let marked = Map.insert identity Visiting marks
          (resolvedMarks, resolvedBoxValue) <-
            resolvePlacement index marked path input
          let resolved =
                ResolvedNode
                  { resolvedNodeIdentifier = layoutInputIdentifier input
                  , resolvedNodePlacement = layoutInputPlacement input
                  , resolvedNodeBox = resolvedBoxValue
                  }
              finished = Map.insert identity (Finished resolved) resolvedMarks
          Right (finished, resolved)

resolvePlacement
  :: Map NodeId NodeLayoutInput
  -> Map NodeId VisitMark
  -> NonEmpty NodeId
  -> NodeLayoutInput
  -> Either LayoutError (Map NodeId VisitMark, Box)
resolvePlacement index marks path input =
  case layoutInputPlacement input of
    AbsolutePlacement anchor ownPort ->
      Right (marks, boxFromAnchor anchor ownPort size)
    GeneratedPlacement anchor ownPort ->
      Right (marks, boxFromAnchor anchor ownPort size)
    SourceDerivedPlacement reference ->
      Left
        ( LayoutUnsupportedPlacement
            (layoutInputIdentifier input)
            reference
        )
    RelativeNodePlacement relative -> do
      let target = relativeTarget relative
          owner = layoutInputIdentifier input
      case Map.lookup target index of
        Nothing ->
          Left (MissingPlacementTarget owner target)
        Just _ -> do
          (nextMarks, targetNode) <-
            resolveOne index marks (appendPath path target) target
          let targetAnchor =
                pointAtPort
                  (relativeTargetPort relative)
                  (resolvedNodeBox targetNode)
              desiredOwnAnchor =
                offsetForRelative relative targetAnchor
          Right
            ( nextMarks
            , boxFromAnchor desiredOwnAnchor (relativeOwnPort relative) size
            )
  where
    size = layoutInputSize input

-- | Secondary gap offsets the perpendicular axis. For diagonal positions the
-- primary axis remains vertical, matching Above/Below creation semantics.
offsetForRelative :: RelativePlacement -> Point -> Point
offsetForRelative relative target =
  point
    (addUnits (pointX target) xOffset)
    (addUnits (pointY target) yOffset)
  where
    primary = relativePrimaryGap relative
    secondary = relativeSecondaryGap relative
    negative value = subtractUnits zero value
    zero = canvasUnitFromInteger 0
    (xOffset, yOffset) =
      case relativeSide relative of
        Above -> (secondary, primary)
        AboveRight -> (secondary, primary)
        RightOf -> (primary, secondary)
        BelowRight -> (secondary, negative primary)
        Below -> (secondary, negative primary)
        BelowLeft -> (negative secondary, negative primary)
        LeftOf -> (negative primary, secondary)
        AboveLeft -> (negative secondary, primary)

boxFromAnchor :: Point -> BorderPort -> Size -> Box
boxFromAnchor anchor ownPort size =
  let origin = point zero zero
      ownAtOrigin = pointAtPort ownPort (box origin size)
      centre =
        point
          (subtractUnits (pointX anchor) (pointX ownAtOrigin))
          (subtractUnits (pointY anchor) (pointY ownAtOrigin))
   in box centre size
  where
    zero = canvasUnitFromInteger 0

appendPath :: NonEmpty NodeId -> NodeId -> NonEmpty NodeId
appendPath (first :| remaining) identity = first :| (remaining <> [identity])

firstPathNode :: NonEmpty NodeId -> NodeId
firstPathNode (first :| _) = first

collectInInputOrder
  :: Map NodeId VisitMark
  -> [NodeLayoutInput]
  -> Either LayoutError [ResolvedNode]
collectInInputOrder _ [] = Right []
collectInInputOrder marks (input : remaining) =
  case Map.lookup identity marks of
    Just (Finished resolved) ->
      (resolved :) <$> collectInInputOrder marks remaining
    _ -> Left (LayoutResultMissing identity)
  where
    identity = layoutInputIdentifier input
