-- |
-- Module      : SlideBlaster.TikZ.Edit
-- Description : Public typed semantic move operation.
--
-- Callers describe intent only. Candidate bytes and verified patch
-- constructors are private; a successful result has already passed exact
-- source checks, reparse/elaboration, and semantic equality.
module SlideBlaster.TikZ.Edit
  ( MoveError (..)
  , MoveNode
  , StyleError (..)
  , StyleNode
  , Dialect
  , VerificationFailure (..)
  , applyMoveNode
  , applyStyleNode
  , styleNode
  , styleNodeCommand
  , styleNodeRevision
  , styleNodeTarget
  , moveNode
  , moveNodeDestination
  , moveNodeRevision
  , moveNodeTarget
  ) where

import SlideBlaster.Source (Revision)
import SlideBlaster.Syntax.Command (Command)
import SlideBlaster.Syntax.Surface (Dialect)
import SlideBlaster.TikZ.Internal.Edit (applyMoveNodeInternal)
import SlideBlaster.TikZ.Internal.Style (applyStyleNodeInternal)
import SlideBlaster.TikZ.Internal.Types
  ( DocumentSnapshot
  , MoveError (..)
  , MoveNode (..)
  , NodeId
  , Point
  , StyleError (..)
  , StyleNode (..)
  , VerificationFailure (..)
  )

-- | Construct a node move tied to the source revision used for its canvas.
moveNode :: Revision -> NodeId -> Point -> MoveNode
moveNode = MoveNode

-- | Return the revision fence captured by this intent.
moveNodeRevision :: MoveNode -> Revision
moveNodeRevision (MoveNode value _ _) = value

-- | Return the semantic target identity.
moveNodeTarget :: MoveNode -> NodeId
moveNodeTarget (MoveNode _ value _) = value

-- | Return the intended semantic destination.
moveNodeDestination :: MoveNode -> Point
moveNodeDestination (MoveNode _ _ value) = value

-- | Apply one atomic provenance-guided and semantically verified node move.
applyMoveNode
  :: MoveNode
  -> DocumentSnapshot
  -> Either MoveError DocumentSnapshot
applyMoveNode = applyMoveNodeInternal

-- | Construct a content style change tied to the revision its canvas was drawn
-- from.
styleNode :: Revision -> NodeId -> Dialect -> Command -> StyleNode
styleNode = StyleNode

styleNodeRevision :: StyleNode -> Revision
styleNodeRevision (StyleNode value _ _ _) = value

styleNodeTarget :: StyleNode -> NodeId
styleNodeTarget (StyleNode _ value _ _) = value

styleNodeCommand :: StyleNode -> Command
styleNodeCommand (StyleNode _ _ _ value) = value

-- | Apply one atomic provenance-guided and semantically verified content style
-- change.
applyStyleNode
  :: StyleNode
  -> DocumentSnapshot
  -> Either StyleError DocumentSnapshot
applyStyleNode = applyStyleNodeInternal
