-- |
-- Module      : SlideBlaster.Protocol.Types
-- Description : Cross-target command and response algebra for the shared engine.
--
-- Requests carry immutable values rather than platform handles. Hosts are
-- responsible for loading or storing bytes; the shared engine only inspects or
-- transforms snapshots.
module SlideBlaster.Protocol.Types
  ( EngineRequest (..)
  , EngineResponse (..)
  , ProtocolDecodeFailure (..)
  , ProtocolError (..)
  ) where

import SlideBlaster.Engine
  ( AppliedExactReplacement
  , AppliedTikzMove
  , AppliedTikzStyle
  , ExactLocalEditError
  , SnapshotInspection
  , TikzAnalysis
  , TikzMoveIntent
  , TikzStyleIntent
  )
import SlideBlaster.Source (ExactReplacement, SourceBufferSnapshot)
import SlideBlaster.TikZ (MoveError, StyleError)

import Data.Text (Text)

-- | A request understood by the shared engine boundary.
data EngineRequest
  = InspectSource !SourceBufferSnapshot
  | ReplaceSource !SourceBufferSnapshot !ExactReplacement
  | AnalyzeTikz !SourceBufferSnapshot
  | MoveTikzNode !SourceBufferSnapshot !TikzMoveIntent
  | StyleTikzNode !SourceBufferSnapshot !TikzStyleIntent
  deriving (Eq, Show)

-- | A successfully completed engine request.
data EngineResponse
  = SourceInspected !SourceBufferSnapshot !SnapshotInspection
  | SourceReplaced !AppliedExactReplacement !SnapshotInspection
  | TikzAnalyzed !TikzAnalysis
  | TikzNodeMoved !AppliedTikzMove
  | TikzNodeStyled !AppliedTikzStyle
  deriving (Eq, Show)

-- | Typed failures produced while decoding a request.
data ProtocolDecodeFailure
  = ProtocolMalformedJSON !Text
  | ProtocolUnsupportedVersion !Text
  | ProtocolUnknownCommand !Text
  | ProtocolInvalidField !Text
  deriving (Eq, Show)

-- | A rejected request. Rejection never changes the supplied snapshot.
data ProtocolError
  = ProtocolExactReplacementError ExactLocalEditError
  | ProtocolTikzMoveError MoveError
  | ProtocolTikzStyleError StyleError
  | ProtocolDecodeError ProtocolDecodeFailure
  deriving (Eq, Show)
