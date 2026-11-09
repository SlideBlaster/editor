{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.TikZ.Internal.Style
-- Description : Private candidate-to-verified content style transaction.
--
-- The same shape as the node-move transaction: an edit reaches the source only
-- through recorded provenance, and it is accepted only after the patched source has
-- been reparsed and found to mean what was asked for. A refusal at any point leaves
-- the document untouched.
--
-- What differs from a move is what "means" is. A move compares pictures, because a
-- coordinate either is or is not the requested one. A style edit changes text whose
-- tree has more than one faithful shape: dividing a text construct to style half of
-- it leaves a tree that prints identically but is not equal as a tree. The
-- comparison is therefore on the runs a renderer would draw, coalesced, which is
-- the observable result and nothing more.
module SlideBlaster.TikZ.Internal.Style
  ( applyStyleNodeInternal
  , describeStyleRefusal
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import SlideBlaster.Source
  ( SourceBufferSnapshot
  , SourceSpan
  , applyExactReplacement
  , mkExactReplacement
  , snapshotBytes
  , snapshotRevision
  , sourceSpanEnd
  , sourceSpanStart
  , unByteOffset
  )
import SlideBlaster.Syntax.Ast qualified as Syntax
import SlideBlaster.Syntax.Command (CommandError (..), applyCommand)
import SlideBlaster.Syntax.Inline
  ( InlineRun (runKind, runStyle, runText)
  , coalesceRuns
  , flattenInline
  , inlineRuns
  )
import SlideBlaster.Syntax.Path (Path, pathToList)
import SlideBlaster.Syntax.Printer (printNode)
import SlideBlaster.Syntax.Range (RangeError (..))
import SlideBlaster.TikZ.Internal.Parser (parseSnapshot)
import SlideBlaster.TikZ.Internal.Types
  ( AnalysisState (..)
  , ContentProvenance
  , DocumentSnapshot
  , Node (..)
  , Picture (..)
  , ReadyDocument (..)
  , StyleError (..)
  , StyleNode (..)
  , contentSlotSpan
  , documentAnalysis
  , documentSourceSnapshot
  )
import SlideBlaster.TikZ.NodeContent
  ( ContentStatus (ContentOpaque, ContentUnderstood)
  , nodeContentStatus
  , nodeContentTree
  , readNodeContent
  )

-- | Apply one atomic provenance-guided and semantically verified style change to a
-- node's content.
applyStyleNodeInternal
  :: StyleNode
  -> DocumentSnapshot
  -> Either StyleError DocumentSnapshot
applyStyleNodeInternal intent document
  | requestedRevision /= actualRevision =
      Left (StyleStale requestedRevision actualRevision)
  | otherwise =
      case documentAnalysis document of
        AnalysisUnavailable _ -> Left StyleSemanticsUnavailable
        AnalysisReady (ReadyDocument picture _ contentProvenance) ->
          applyReady intent document picture contentProvenance
  where
    StyleNode requestedRevision _ _ _ = intent
    actualRevision = snapshotRevision (documentSourceSnapshot document)

applyReady
  :: StyleNode
  -> DocumentSnapshot
  -> Picture
  -> ContentProvenance
  -> Either StyleError DocumentSnapshot
applyReady (StyleNode _ targetId themeDialect command) document picture contentProvenance =
  case picture of
    Picture (Node actualId _ content) _
      | targetId /= actualId -> Left (StyleTargetMissing targetId)
      | otherwise ->
          case nodeContentTree content of
            -- Content outside the readable subset has no addressable structure, so
            -- an edit to it could only be guesswork.
            Nothing ->
              Left (StyleContentUnreadable (unreadableReason content))
            Just tree ->
              case applyCommand themeDialect command tree of
                Left refusal -> Left (StyleRefused (describeStyleRefusal refusal))
                Right edited -> commit document contentProvenance content edited

-- | Write the new content bytes, reparse, and require the result to say what was
-- intended before accepting it.
commit
  :: DocumentSnapshot
  -> ContentProvenance
  -> Text
  -> Syntax.Node
  -> Either StyleError DocumentSnapshot
commit document contentProvenance before edited
  -- A command that changes nothing changes no bytes, so there is no transaction
  -- to verify and the revision does not advance.
  | replacement == before = Right document
  | otherwise = do
      successorSource <-
        case applyExactReplacement exactReplacement source of
          Left problem -> Left (StyleSourceCheckFailed problem)
          Right updated -> Right updated
      let successor = parseSnapshot successorSource
      case documentAnalysis successor of
        AnalysisUnavailable _ -> Left StyleVerificationFailed
        AnalysisReady (ReadyDocument (Picture (Node _ _ actual) _) _ _) ->
          case nodeContentTree actual of
            -- The edit produced content the reader cannot read back. Refusing
            -- leaves the document as it was, which is the only safe outcome.
            Nothing -> Left StyleVerificationFailed
            Just reread
              | sameMeaning (lower reread) intended -> Right successor
              | otherwise -> Left StyleVerificationFailed
  where
    replacement = printNode edited
    intended = lower edited
    lower = inlineRuns . coalesceRuns . flattenInline
    source = documentSourceSnapshot document
    targetSpan = contentSlotSpan contentProvenance
    exactReplacement =
      mkExactReplacement
        (snapshotRevision source)
        targetSpan
        (bytesAtSpan source targetSpan)
        (Text.Encoding.encodeUtf8 replacement)

-- | Two lowerings mean the same thing when a renderer could not tell them apart.
--
-- Paths are excluded deliberately: the edited tree still carries the divisions the
-- edit made in order to style part of a construct, while a fresh read of the
-- printed source has none. Everything a renderer acts on must agree.
sameMeaning :: [InlineRun] -> [InlineRun] -> Bool
sameMeaning actual intended = fmap observable actual == fmap observable intended
  where
    observable run = (runKind run, runText run, runStyle run)

-- | Why the content could not be read, for a diagnostic.
unreadableReason :: Text -> Text
unreadableReason content =
  case nodeContentStatus (readNodeContent content) of
    ContentOpaque reason -> reason
    -- Unreachable: 'nodeContentTree' and 'readNodeContent' read the same bytes the
    -- same way, so one cannot fail while the other succeeds.
    ContentUnderstood -> "the content could not be read"

bytesAtSpan :: SourceBufferSnapshot -> SourceSpan -> ByteString
bytesAtSpan source spanValue =
  ByteString.take
    (end - start)
    (ByteString.drop start (snapshotBytes source))
  where
    start = unByteOffset (sourceSpanStart spanValue)
    end = unByteOffset (sourceSpanEnd spanValue)

-- | A refusal explained for a diagnostic.
--
-- Structural, never quoting authored content, so a diagnostic can cross the
-- protocol without disclosing the document.
describeStyleRefusal :: CommandError -> Text
describeStyleRefusal failure =
  case failure of
    CommandTargetNotFound path ->
      "no construct at path " <> renderPath path
    CommandInsideExpansion path ->
      "path "
        <> renderPath path
        <> " lies inside a macro expansion, which is read-only"
    CommandRange reason -> describeRange reason
    CommandUnspellable dialect key ->
      Text.pack (show dialect) <> " cannot express " <> Text.pack (show key)
    CommandNotClearable key ->
      Text.pack (show key) <> " has no value meaning it no longer applies"

describeRange :: RangeError -> Text
describeRange reason =
  case reason of
    RangePathNotRendered path -> "nothing rendered at path " <> renderPath path
    RangeOffsetOutOfRange path offset ->
      "offset "
        <> Text.pack (show offset)
        <> " lies outside the construct at path "
        <> renderPath path
    RangeNotSplittable path ->
      "the construct at path " <> renderPath path <> " cannot be divided"
    RangeEmpty -> "the selection is empty"

renderPath :: Path -> Text
renderPath = Text.pack . show . pathToList
