{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Executable contract tests for the shared pure engine slice.
--
-- These checks remain free of platform adapters so they can run unchanged for
-- native and Wasm builds.
module Main (main) where

import Control.Monad (unless)
import Data.ByteString.Char8 qualified as ByteString
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import System.Exit (exitFailure)
import SlideBlaster.Canvas qualified as Canvas
import SlideBlaster.Document qualified as Document
import SlideBlaster.Engine
import SlideBlaster.Render qualified as Render
import SlideBlaster.Source
import SlideBlaster.TikZ
import SlideBlaster.TikZ.Adapter qualified as Adapter

main :: IO ()
main = do
  inspectionIsDeterministic
  replacementProducesReceipt
  tikzAnalysisIsReady
  tikzSyntaxOnlyPreservesExactSource
  tikzMoveProducesVerifiedExactSuccessor
  tikzNoOpPreservesExactSourceAndRevision
  tikzMoveRejectsInvalidIntent
  tikzMoveRejectsStaleRevision
  commonRenderPlanConnectorFollows

inspectionIsDeterministic :: IO ()
inspectionIsDeterministic = do
  let inspection = inspectSnapshot (snapshotFromBytes (ByteString.pack "a\nb\n"))
  assertEqual "inspection byte count" 4 (inspectionByteLength inspection)
  assertEqual "inspection logical line count" 2 (inspectionLineCount inspection)
  assertEqual "inspection UTF-8 status" ValidUtf8 (inspectionUtf8Status inspection)
  unless ("fnv1a64:" `Text.isPrefixOf` inspectionFingerprint inspection) $
    failTest "inspection fingerprint lacks its algorithm prefix"

replacementProducesReceipt :: IO ()
replacementProducesReceipt = do
  let snapshot = snapshotFromBytes (ByteString.pack "\\node at (1,2);")
      spanValue = requireSpan 9 14
      replacement =
        mkExactReplacement
          (snapshotRevision snapshot)
          spanValue
          (ByteString.pack "(1,2)")
          (ByteString.pack "(3,4)")
  case applyExactLocalReplacement replacement snapshot of
    Left problem -> failTest ("exact replacement rejected: " <> show problem)
    Right applied -> do
      let receipt = appliedReplacementReceipt applied
      assertEqual "receipt marks changed edit" True (receiptChanged receipt)
      assertEqual "receipt removed byte count" 5 (receiptRemovedByteLength receipt)
      assertEqual "receipt inserted byte count" 5 (receiptInsertedByteLength receipt)
      assertEqual
        "applied snapshot contains replacement"
        (ByteString.pack "\\node at (3,4);")
        (snapshotBytes (appliedReplacementSnapshot applied))

tikzAnalysisIsReady :: IO ()
tikzAnalysisIsReady =
  case analyzeTikzSnapshot (snapshotFromBytes canonicalTikzSource) of
    TikzAnalysisSyntaxOnly _ diagnostics ->
      failTest ("ready TikZ source produced diagnostics: " <> show diagnostics)
    ready@(TikzAnalysisReady _ plan) -> do
      assertEqual
        "ready analysis preserves source"
        canonicalTikzSource
        (snapshotBytes (tikzAnalysisSnapshot ready))
      assertEqual
        "ready node identity"
        "alpha"
        (nodeIdText (renderNodeId (renderPlanNode plan)))
      assertEqual
        "ready node x"
        "1"
        (coordinateToText (pointX (renderNodePosition (renderPlanNode plan))))
      assertEqual
        "ready connector end y"
        "8"
        (coordinateToText (pointY (renderConnectorEnd (renderPlanConnector plan))))

tikzSyntaxOnlyPreservesExactSource :: IO ()
tikzSyntaxOnlyPreservesExactSource = do
  let malformed = TextEncoding.encodeUtf8 "\\node"
      analysis = analyzeTikzSnapshot (snapshotFromBytes malformed)
  case analysis of
    TikzAnalysisReady {} ->
      failTest "malformed TikZ source unexpectedly produced a render plan"
    TikzAnalysisSyntaxOnly _ diagnostics -> do
      assertEqual
        "syntax-only analysis preserves exact source"
        malformed
        (snapshotBytes (tikzAnalysisSnapshot analysis))
      assertEqual
        "syntax-only analysis has a malformed diagnostic"
        DiagnosticMalformed
        (diagnosticCategory (NonEmpty.head diagnostics))

tikzMoveProducesVerifiedExactSuccessor :: IO ()
tikzMoveProducesVerifiedExactSuccessor = do
  let snapshot = snapshotFromBytes noncanonicalTikzSource
      intent = requireMoveIntent snapshot "alpha" "4" "5"
  case applyTikzMove intent snapshot of
    Left problem -> failTest ("valid TikZ move rejected: " <> show problem)
    Right applied -> do
      assertEqual
        "verified move classification"
        TikzMoveVerifiedChange
        (appliedTikzMoveOutcome applied)
      assertEqual
        "verified move advances once"
        1
        ( revisionToWord64
            ( snapshotRevision
                (tikzAnalysisSnapshot (appliedTikzMoveAnalysis applied))
            )
        )
      assertEqual
        "verified move exact successor"
        movedTikzSource
        (snapshotBytes (tikzAnalysisSnapshot (appliedTikzMoveAnalysis applied)))
      case appliedTikzMoveAnalysis applied of
        TikzAnalysisSyntaxOnly _ diagnostics ->
          failTest ("verified successor became syntax-only: " <> show diagnostics)
        TikzAnalysisReady _ plan -> do
          assertEqual
            "moved node x"
            "4"
            (coordinateToText (pointX (renderNodePosition (renderPlanNode plan))))
          assertEqual
            "connector follows moved node"
            (renderNodePosition (renderPlanNode plan))
            (renderConnectorStart (renderPlanConnector plan))

tikzNoOpPreservesExactSourceAndRevision :: IO ()
tikzNoOpPreservesExactSourceAndRevision = do
  let snapshot = snapshotFromBytes noncanonicalTikzSource
      intent = requireMoveIntent snapshot "alpha" "1.5" "0"
  case applyTikzMove intent snapshot of
    Left problem -> failTest ("semantic no-op rejected: " <> show problem)
    Right applied -> do
      assertEqual
        "no-op classification"
        TikzMoveUnchanged
        (appliedTikzMoveOutcome applied)
      assertEqual
        "no-op exact source"
        noncanonicalTikzSource
        (snapshotBytes (tikzAnalysisSnapshot (appliedTikzMoveAnalysis applied)))
      assertEqual
        "no-op revision"
        0
        ( revisionToWord64
            ( snapshotRevision
                (tikzAnalysisSnapshot (appliedTikzMoveAnalysis applied))
            )
        )

tikzMoveRejectsInvalidIntent :: IO ()
tikzMoveRejectsInvalidIntent = do
  let revision = snapshotRevision (snapshotFromBytes canonicalTikzSource)
  case mkTikzMoveIntent revision "not valid" "1" "2" of
    Left (TikzIntentInvalidNodeId _) -> pure ()
    other -> failTest ("invalid node identity admitted: " <> show other)
  case mkTikzMoveIntent revision "alpha" "1e3" "2" of
    Left (TikzIntentInvalidX _) -> pure ()
    other -> failTest ("invalid decimal admitted: " <> show other)

tikzMoveRejectsStaleRevision :: IO ()
tikzMoveRejectsStaleRevision = do
  let source = snapshotAtRevision (revisionFromWord64 2) canonicalTikzSource
      intent =
        case mkTikzMoveIntent (revisionFromWord64 1) "alpha" "4" "5" of
          Left problem -> error ("test bug: invalid move intent: " <> show problem)
          Right valid -> valid
  case applyTikzMove intent source of
    Left (MoveStale requested actual) -> do
      assertEqual "stale requested revision" 1 (revisionToWord64 requested)
      assertEqual "stale actual revision" 2 (revisionToWord64 actual)
    other -> failTest ("stale move was not rejected atomically: " <> show other)

commonRenderPlanConnectorFollows :: IO ()
commonRenderPlanConnectorFollows = do
  let source = snapshotFromBytes canonicalTikzSource
  document <-
    requireRight
      "common engine admission"
      (Adapter.analyzeCommonTikz source)
  slideSize <-
    requireRight
      "common engine slide size"
      (Canvas.mkSize (Canvas.canvasUnit 16) (Canvas.canvasUnit 9))
  nodeSize <-
    requireRight
      "common engine node size"
      (Canvas.mkSize (Canvas.canvasUnit 2) (Canvas.canvasUnit 1))
  initialPlan <-
    requireRight
      "initial common render plan"
      (renderCommonTikzPlan (Render.renderTicketFromWord64 70) slideSize nodeSize document)
  assertEqual
    "initial common connector starts at admitted node"
    (Canvas.point (Canvas.canvasUnit 1) (Canvas.canvasUnit 2))
    (commonConnectorStart initialPlan)
  nodeIdentity <-
    case Canvas.nodeId "alpha" of
      Nothing -> failTest "test bug: invalid common node id"
      Just value -> pure value
  let destination = Canvas.point (Canvas.canvasUnit 6) (Canvas.canvasUnit 7)
      operation =
        Canvas.MoveElement
          (Canvas.NodeElement nodeIdentity)
          (Canvas.AbsolutePlacement destination Canvas.Centre)
  successor <-
    case Adapter.applyCommonTikzEdit operation document of
      Left problem -> failTest ("common engine move failed: " <> show problem)
      Right (Adapter.TikzCanvasUnchanged _) ->
        failTest "common engine move unexpectedly produced no change"
      Right (Adapter.TikzCanvasVerified value) -> pure value
  successorPlan <-
    requireRight
      "successor common render plan"
      (renderCommonTikzPlan (Render.renderTicketFromWord64 71) slideSize nodeSize successor)
  assertEqual
    "successor common connector starts at moved node"
    destination
    (commonConnectorStart successorPlan)
  assertEqual
    "successor plan carries authoritative revision"
    (snapshotRevision (Document.documentSource successor))
    (Render.renderPlanRevision successorPlan)

commonConnectorStart :: Render.RenderPlan -> Canvas.Point
commonConnectorStart plan =
  case
      [ Render.renderPathStart path
      | layer <- NonEmpty.toList (Render.renderPlanLayers plan)
      , item <- Render.renderLayerItems layer
      , Render.ConnectorPrimitive path _ _ <- [Render.renderItemPrimitive item]
      ]
    of
      [start] -> start
      other -> error ("test bug: expected one common connector, got " <> show other)

requireRight :: Show problem => String -> Either problem value -> IO value
requireRight label result =
  case result of
    Left problem -> failTest (label <> ": " <> show problem)
    Right value -> pure value

requireMoveIntent
  :: SourceBufferSnapshot
  -> Text.Text
  -> Text.Text
  -> Text.Text
  -> TikzMoveIntent
requireMoveIntent snapshot target xCoordinate yCoordinate =
  case
      mkTikzMoveIntent
        (snapshotRevision snapshot)
        target
        xCoordinate
        yCoordinate
    of
      Left problem -> error ("test bug: invalid move intent: " <> show problem)
      Right intent -> intent

canonicalTikzSource :: ByteString.ByteString
canonicalTikzSource =
  TextEncoding.encodeUtf8
    "\\node (alpha) at (1,2) {hello};\n\\draw (alpha) -- (9,8);\n"

noncanonicalTikzSource :: ByteString.ByteString
noncanonicalTikzSource =
  TextEncoding.encodeUtf8
    "% lead\n\\node % command\n (alpha)\t at ( +001.5000 % x\n ,\t -000.00 ) {π 😀}; % between\n\\draw\t(alpha) -- (9.0 , 8);\n"

movedTikzSource :: ByteString.ByteString
movedTikzSource =
  TextEncoding.encodeUtf8
    "% lead\n\\node % command\n (alpha)\t at ( 4 % x\n ,\t 5 ) {π 😀}; % between\n\\draw\t(alpha) -- (9.0 , 8);\n"

requireSpan :: Int -> Int -> SourceSpan
requireSpan start end =
  case sourceSpanFromInts start end of
    Nothing -> error "test bug: invalid source span"
    Just spanValue -> spanValue

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $
    failTest (label <> ": expected " <> show expected <> ", got " <> show actual)

failTest :: String -> IO value
failTest message = do
  putStrLn ("FAIL: " <> message)
  exitFailure
