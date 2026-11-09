{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : SlideBlaster.Syntax.Fix
-- Description : Fixpoint of a syntax functor and the folds over it.
--
-- Every dialect's tree is expressed as a functor whose recursive position is a
-- parameter, then closed with 'Fix'. Traversals are then folds rather than
-- hand-written recursion: printing, macro expansion, semantic queries, and edits
-- are all algebras.
--
-- This is deliberately a local twenty-line definition rather than a dependency.
-- The shape is standard and the project keeps its dependency surface small
-- because every shared package must also compile for WebAssembly.
module SlideBlaster.Syntax.Fix
  ( Fix (..)
  , project
  , embed
  , cata
  , para
  , ana
  , cataM
  ) where

-- | The least fixpoint of a syntax functor.
newtype Fix f = Fix {unFix :: f (Fix f)}

deriving stock instance Eq (f (Fix f)) => Eq (Fix f)

deriving stock instance Ord (f (Fix f)) => Ord (Fix f)

deriving stock instance Show (f (Fix f)) => Show (Fix f)

-- | Expose one layer of structure.
project :: Fix f -> f (Fix f)
project = unFix

-- | Close one layer of structure.
embed :: f (Fix f) -> Fix f
embed = Fix

-- | Fold a tree bottom-up. The algebra sees children already folded.
cata :: Functor f => (f a -> a) -> Fix f -> a
cata algebra = go
  where
    go = algebra . fmap go . unFix

-- | Fold bottom-up while retaining each child's original subtree.
--
-- Used where an algebra must inspect the authored form of a child as well as its
-- folded result, such as reporting which construct a diagnostic came from.
para :: Functor f => (f (Fix f, a) -> a) -> Fix f -> a
para algebra = go
  where
    go tree = algebra (fmap (\child -> (child, go child)) (unFix tree))

-- | Unfold a tree top-down from a seed.
ana :: Functor f => (a -> f a) -> a -> Fix f
ana coalgebra = go
  where
    go = Fix . fmap go . coalgebra

-- | Fold bottom-up in a monad, for algebras that can fail or need state.
--
-- Macro expansion uses this: it threads the definition environment and reports
-- unsupported definition forms.
cataM
  :: (Traversable f, Monad m)
  => (f a -> m a)
  -> Fix f
  -> m a
cataM algebra = go
  where
    go tree = traverse go (unFix tree) >>= algebra
