-- |
-- Module      : SlideBlaster.Protocol.Run
-- Description : Pure interpreter for the shared engine request algebra.
--
-- Running a request has no host effects. Exact replacement and bounded TikZ
-- movement return only accepted successor snapshots; a failure returns no
-- successor.
module SlideBlaster.Protocol.Run
  ( runEngineRequest
  ) where

import SlideBlaster.Engine
  ( appliedReplacementSnapshot
  , analyzeTikzSnapshot
  , applyExactLocalReplacement
  , applyTikzMove
  , applyTikzStyle
  , inspectSnapshot
  )
import SlideBlaster.Protocol.Types
  ( EngineRequest (..)
  , EngineResponse (..)
  , ProtocolError (..)
  )

-- | Interpret one request against the shared pure engine.
runEngineRequest :: EngineRequest -> Either ProtocolError EngineResponse
runEngineRequest request =
  case request of
    InspectSource snapshot ->
      Right (SourceInspected snapshot (inspectSnapshot snapshot))
    ReplaceSource snapshot replacement ->
      case applyExactLocalReplacement replacement snapshot of
        Left problem -> Left (ProtocolExactReplacementError problem)
        Right applied ->
          Right
            (SourceReplaced applied (inspectSnapshot (appliedReplacementSnapshot applied)))
    AnalyzeTikz snapshot ->
      Right (TikzAnalyzed (analyzeTikzSnapshot snapshot))
    MoveTikzNode snapshot intent ->
      case applyTikzMove intent snapshot of
        Left problem -> Left (ProtocolTikzMoveError problem)
        Right applied -> Right (TikzNodeMoved applied)
    StyleTikzNode snapshot intent ->
      case applyTikzStyle intent snapshot of
        Left problem -> Left (ProtocolTikzStyleError problem)
        Right applied -> Right (TikzNodeStyled applied)
