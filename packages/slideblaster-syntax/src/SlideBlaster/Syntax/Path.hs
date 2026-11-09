-- |
-- Module      : SlideBlaster.Syntax.Path
-- Description : Addressing a construct by position in the tree.
--
-- A canvas edit has to name the thing it edits. Naming it by byte span requires
-- an inverse rule from bytes back to structure, which is where source-preserving
-- editors accumulate their unimplementable cases. A 'Path' names a construct
-- structurally instead, so resolving it is a total descent with no parsing and
-- no ambiguity, and it stays valid under any edit that does not change the shape
-- above it.
--
-- The index space is the tree's own 'Foldable' order over child nodes.
-- Navigation uses 'traverse' rather than a per-constructor case analysis, so by
-- the @Traversable@/@Foldable@ coherence law 'childAt' and 'setChildAt' agree
-- with 'childrenOf' by construction, for every present and future constructor.
-- Adding a node type cannot desynchronise them.
--
-- A path is only meaningful against the tree it was derived from. Every
-- operation returns 'Maybe' and none of them raises.
module SlideBlaster.Syntax.Path
  ( Path
  , rootPath
  , pathFromList
  , pathToList
  , extendPath
  , childAt
  , setChildAt
  , resolvePath
  , modifyAt
  , replaceAt
  , pathsOf
  ) where

import SlideBlaster.Syntax.Ast (Node)
import SlideBlaster.Syntax.Fix (Fix (Fix), unFix)

import Data.Foldable (toList)

-- | A position in a tree, as child indices from the root.
newtype Path = Path [Int]
  deriving stock (Eq, Ord, Show)

-- | The tree itself.
rootPath :: Path
rootPath = Path []

pathFromList :: [Int] -> Path
pathFromList = Path

pathToList :: Path -> [Int]
pathToList (Path indices) = indices

-- | Descend one level further.
extendPath :: Path -> Int -> Path
extendPath (Path indices) index = Path (indices <> [index])

-- | The immediate child at an index in 'Foldable' order.
childAt :: Int -> Node -> Maybe Node
childAt index tree
  | index < 0 = Nothing
  | otherwise = case drop index (toList (unFix tree)) of
      found : _ -> Just found
      [] -> Nothing

-- | Replace the immediate child at an index, keeping every other field.
--
-- Uses 'traverse' so the index space cannot drift from 'childAt'.
setChildAt :: Int -> Node -> Node -> Maybe Node
setChildAt index replacement tree
  | index < 0 = Nothing
  | index >= length (toList layer) = Nothing
  | otherwise = Just (Fix (runCounter (traverse step layer) 0))
  where
    layer = unFix tree
    step child =
      Counter
        ( \position ->
            (position + 1, if position == index then replacement else child)
        )

-- | Follow a path to the construct it names.
resolvePath :: Path -> Node -> Maybe Node
resolvePath (Path indices) tree =
  case indices of
    [] -> Just tree
    index : rest -> do
      child <- childAt index tree
      resolvePath (Path rest) child

-- | Transform the construct a path names, rebuilding its ancestors.
--
-- 'Nothing' when the path does not resolve, so a stale path cannot silently
-- edit the wrong construct.
modifyAt :: Path -> (Node -> Node) -> Node -> Maybe Node
modifyAt (Path indices) transform tree =
  case indices of
    [] -> Just (transform tree)
    index : rest -> do
      child <- childAt index tree
      updated <- modifyAt (Path rest) transform child
      setChildAt index updated tree

-- | Replace the construct a path names.
replaceAt :: Path -> Node -> Node -> Maybe Node
replaceAt path replacement = modifyAt path (const replacement)

-- | Every construct paired with its path, in document order, root first.
pathsOf :: Node -> [(Path, Node)]
pathsOf = go rootPath
  where
    go path tree =
      (path, tree)
        : concat
          ( zipWith
              (\index child -> go (extendPath path index) child)
              [0 ..]
              (toList (unFix tree))
          )

-- | A minimal counting applicative, so child indices come from 'traverse'
-- itself rather than from a hand-written case for every constructor.
newtype Counter a = Counter (Int -> (Int, a))

runCounter :: Counter a -> Int -> a
runCounter (Counter step) start = snd (step start)

instance Functor Counter where
  fmap transform (Counter step) =
    Counter
      ( \position ->
          let (next, value) = step position
           in (next, transform value)
      )

instance Applicative Counter where
  pure value = Counter (\position -> (position, value))
  Counter first <*> Counter second =
    Counter
      ( \position ->
          let (afterFirst, transform) = first position
              (afterSecond, value) = second afterFirst
           in (afterSecond, transform value)
      )
