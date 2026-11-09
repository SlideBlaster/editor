{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Protocol.Render
-- Description : Stable human-readable rendering of protocol outcomes.
--
-- Rendering uses newline-delimited key/value fields so the CLI remains easy to
-- inspect without committing the Wasm host to this text as its future wire
-- encoding. Output values never include authored source bytes.
module SlideBlaster.Protocol.Render
  ( renderEngineResponse
  , renderProtocolError
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.List.NonEmpty qualified as NonEmpty
import SlideBlaster.Engine
  ( AppliedTikzMove
  , AppliedTikzStyle
  , TikzStyleOutcome (..)
  , appliedTikzStyleAnalysis
  , appliedTikzStyleBeforeRevision
  , appliedTikzStyleIntent
  , appliedTikzStyleOutcome
  , tikzStyleIntentNodeId
  , ExactLocalEditError (..)
  , ExactReplacementReceipt (..)
  , SnapshotInspection (..)
  , TikzAnalysis (..)
  , TikzMoveOutcome (..)
  , Utf8Status (..)
  , appliedReplacementReceipt
  , appliedTikzMoveAnalysis
  , appliedTikzMoveBeforeRevision
  , appliedTikzMoveIntent
  , appliedTikzMoveOutcome
  , tikzAnalysisSnapshot
  , tikzMoveIntentDestination
  , tikzMoveIntentNodeId
  )
import SlideBlaster.TikZ (StyleError (..))
import SlideBlaster.Protocol.Types
  ( EngineResponse (..)
  , ProtocolDecodeFailure (..)
  , ProtocolError (..)
  )
import SlideBlaster.Protocol.Version (protocolVersion)
import SlideBlaster.Source
  ( ExactReplacementError (..)
  , revisionToWord64
  , snapshotRevision
  , sourceSpanEnd
  , sourceSpanStart
  , unByteOffset
  )
import SlideBlaster.TikZ
  ( Diagnostic
  , DiagnosticCategory (..)
  , DiagnosticCode (..)
  , MoveError (..)
  , Point
  , RenderPlan
  , VerificationFailure (..)
  , coordinateToText
  , diagnosticCategory
  , diagnosticCode
  , diagnosticMessage
  , diagnosticSpan
  , nodeIdText
  , pointX
  , pointY
  , renderConnectorEnd
  , renderConnectorStart
  , renderNodeId
  , renderNodePosition
  , renderPlanConnector
  , renderPlanNode
  )

-- | Render a successful response as stable diagnostic text.
renderEngineResponse :: EngineResponse -> Text
renderEngineResponse response =
  Text.unlines $
    protocolHeader
      <> case response of
        SourceInspected _ inspection ->
          "response=inspection" : inspectionFields inspection
        SourceReplaced applied inspection ->
          "response=replacement"
            : receiptFields (appliedReplacementReceipt applied)
            <> inspectionFields inspection
        TikzAnalyzed analysis ->
          "response=tikz_analysis" : analysisFields analysis
        TikzNodeMoved applied ->
          "response=tikz_move"
            : moveFields applied
            <> analysisFields (appliedTikzMoveAnalysis applied)
        TikzNodeStyled applied ->
          "response=tikz_style"
            : styleFields applied
            <> analysisFields (appliedTikzStyleAnalysis applied)

-- | Render a rejection without disclosing source content.
renderProtocolError :: ProtocolError -> Text
renderProtocolError protocolError =
  Text.unlines $
    protocolHeader
      <> ( "response=error"
            : case protocolError of
              ProtocolExactReplacementError localError -> localErrorFields localError
              ProtocolTikzMoveError moveError -> tikzMoveErrorFields moveError
              ProtocolTikzStyleError styleError -> tikzStyleErrorFields styleError
              ProtocolDecodeError decodeFailure -> decodeFailureFields decodeFailure
         )

protocolHeader :: [Text]
protocolHeader = ["slideblaster.protocol=" <> protocolVersion]

inspectionFields :: SnapshotInspection -> [Text]
inspectionFields inspection =
  [ "source.revision=" <> decimal (revisionToWord64 (inspectionRevision inspection))
  , "source.bytes=" <> decimal (inspectionByteLength inspection)
  , "source.lines=" <> decimal (inspectionLineCount inspection)
  , "source.utf8=" <> renderUtf8Status (inspectionUtf8Status inspection)
  , "source.fingerprint=" <> inspectionFingerprint inspection
  ]

receiptFields :: ExactReplacementReceipt -> [Text]
receiptFields receipt =
  [ "edit.before-revision=" <> decimal (revisionToWord64 (receiptBeforeRevision receipt))
  , "edit.after-revision=" <> decimal (revisionToWord64 (receiptAfterRevision receipt))
  , "edit.start=" <> decimal (unByteOffset (sourceSpanStart (receiptTargetSpan receipt)))
  , "edit.end=" <> decimal (unByteOffset (sourceSpanEnd (receiptTargetSpan receipt)))
  , "edit.removed-bytes=" <> decimal (receiptRemovedByteLength receipt)
  , "edit.inserted-bytes=" <> decimal (receiptInsertedByteLength receipt)
  , "edit.changed=" <> renderBool (receiptChanged receipt)
  ]

analysisFields :: TikzAnalysis -> [Text]
analysisFields analysis =
  sourceRevisionField analysis
    : case analysis of
      TikzAnalysisReady _ plan ->
        "document.state=ready" : renderPlanFields analysis plan
      TikzAnalysisSyntaxOnly _ diagnostics ->
        "document.state=syntax_only"
          : "diagnostics.count=" <> decimal (NonEmpty.length diagnostics)
          : concat
            ( zipWith
                diagnosticFields
                [0 :: Int ..]
                (NonEmpty.toList diagnostics)
            )

sourceRevisionField :: TikzAnalysis -> Text
sourceRevisionField analysis =
  "source.revision="
    <> decimal
      (revisionToWord64 (snapshotRevision (tikzAnalysisSnapshot analysis)))

renderPlanFields :: TikzAnalysis -> RenderPlan -> [Text]
renderPlanFields analysis plan =
  [ "plan.source-revision="
      <> decimal
        (revisionToWord64 (snapshotRevision (tikzAnalysisSnapshot analysis)))
  , "plan.coordinate-space=slide_16x9_y_up"
  , "plan.node.kind=content_node"
  , "plan.node.id=" <> nodeIdText (renderNodeId node)
  ]
    <> pointFields "plan.node.center" (renderNodePosition node)
    <> ["plan.connector.kind=straight_connector"]
    <> pointFields
      "plan.connector.start"
      (renderConnectorStart connector)
    <> pointFields
      "plan.connector.end"
      (renderConnectorEnd connector)
  where
    node = renderPlanNode plan
    connector = renderPlanConnector plan

moveFields :: AppliedTikzMove -> [Text]
moveFields applied =
  [ "move.outcome=" <> renderMoveOutcome (appliedTikzMoveOutcome applied)
  , "move.before-revision="
      <> decimal (revisionToWord64 (appliedTikzMoveBeforeRevision applied))
  , "move.after-revision="
      <> decimal
        ( revisionToWord64
            ( snapshotRevision
                (tikzAnalysisSnapshot (appliedTikzMoveAnalysis applied))
            )
        )
  , "move.node-id="
      <> nodeIdText (tikzMoveIntentNodeId (appliedTikzMoveIntent applied))
  ]
    <> pointFields
      "move.destination"
      (tikzMoveIntentDestination (appliedTikzMoveIntent applied))

renderMoveOutcome :: TikzMoveOutcome -> Text
renderMoveOutcome outcome =
  case outcome of
    TikzMoveVerifiedChange -> "verified_change"
    TikzMoveUnchanged -> "unchanged"

pointFields :: Text -> Point -> [Text]
pointFields prefix value =
  [ prefix <> ".x=" <> coordinateToText (pointX value)
  , prefix <> ".y=" <> coordinateToText (pointY value)
  ]

diagnosticFields :: Int -> Diagnostic -> [Text]
diagnosticFields index diagnostic =
  [ prefix <> ".category="
      <> renderDiagnosticCategory (diagnosticCategory diagnostic)
  , prefix <> ".code=" <> renderDiagnosticCode (diagnosticCode diagnostic)
  ]
    <> case diagnosticSpan diagnostic of
      Nothing -> [prefix <> ".span=unavailable"]
      Just spanValue ->
        [ prefix <> ".start="
            <> decimal (unByteOffset (sourceSpanStart spanValue))
        , prefix <> ".end="
            <> decimal (unByteOffset (sourceSpanEnd spanValue))
        ]
    <> [prefix <> ".message=" <> oneLine (diagnosticMessage diagnostic)]
  where
    prefix = "diagnostic." <> decimal index

renderDiagnosticCategory :: DiagnosticCategory -> Text
renderDiagnosticCategory category =
  case category of
    DiagnosticMalformed -> "malformed"
    DiagnosticUnsupported -> "unsupported"
    DiagnosticAmbiguous -> "ambiguous"

renderDiagnosticCode :: DiagnosticCode -> Text
renderDiagnosticCode code =
  case code of
    ExpectedNodeStatement -> "expected_node_statement"
    ExpectedConnectorStatement -> "expected_connector_statement"
    ExpectedSyntaxToken -> "expected_syntax_token"
    InvalidNodeIdentifier -> "invalid_node_identifier"
    InvalidConnectorIdentifier -> "invalid_connector_identifier"
    InvalidCoordinateToken -> "invalid_coordinate_token"
    InvalidUtf8Content -> "invalid_utf8_content"
    NestedNodeContentUnsupported -> "nested_node_content_unsupported"
    NodeOptionsUnsupported -> "node_options_unsupported"
    ConnectorOptionsUnsupported -> "connector_options_unsupported"
    ConnectorOperationUnsupported -> "connector_operation_unsupported"
    ConnectorTargetUnsupported -> "connector_target_unsupported"
    ExtraConstructUnsupported -> "extra_construct_unsupported"
    MultipleConstructsAmbiguous -> "multiple_constructs_ambiguous"
    SourceSpanDomainExceeded -> "source_span_domain_exceeded"

localErrorFields :: ExactLocalEditError -> [Text]
localErrorFields localError =
  case localError of
    LocalEditPostconditionFailed message ->
      [ "error.code=local_postcondition_failed"
      , "error.message=" <> oneLine message
      ]
    LocalSourceEditRejected sourceError -> sourceErrorFields sourceError

sourceErrorFields :: ExactReplacementError -> [Text]
sourceErrorFields sourceError =
  case sourceError of
    ReplacementStale requested actual ->
      [ "error.code=stale_revision"
      , "error.requested-revision=" <> decimal (revisionToWord64 requested)
      , "error.actual-revision=" <> decimal (revisionToWord64 actual)
      ]
    ReplacementOutOfBounds target sourceLength ->
      [ "error.code=span_out_of_bounds"
      , "error.start=" <> decimal (unByteOffset (sourceSpanStart target))
      , "error.end=" <> decimal (unByteOffset (sourceSpanEnd target))
      , "error.source-bytes=" <> decimal sourceLength
      ]
    ReplacementExpectedMismatch expectedLength actualLength ->
      [ "error.code=expected_bytes_mismatch"
      , "error.expected-bytes=" <> decimal expectedLength
      , "error.actual-bytes=" <> decimal actualLength
      ]
    ReplacementRevisionExhausted revision ->
      [ "error.code=revision_exhausted"
      , "error.revision=" <> decimal (revisionToWord64 revision)
      ]
    ReplacementLocalityPostconditionFailed ->
      ["error.code=source_locality_postcondition_failed"]

-- | A style change, described without disclosing the content it changed.
styleFields :: AppliedTikzStyle -> [Text]
styleFields applied =
  [ "style.outcome=" <> renderStyleOutcome (appliedTikzStyleOutcome applied)
  , "style.before-revision="
      <> decimal (revisionToWord64 (appliedTikzStyleBeforeRevision applied))
  , "style.after-revision="
      <> decimal
        ( revisionToWord64
            ( snapshotRevision
                (tikzAnalysisSnapshot (appliedTikzStyleAnalysis applied))
            )
        )
  , "style.node-id=" <> nodeIdText (tikzStyleIntentNodeId (appliedTikzStyleIntent applied))
  ]

renderStyleOutcome :: TikzStyleOutcome -> Text
renderStyleOutcome outcome =
  case outcome of
    TikzStyleVerifiedChange -> "verified_change"
    TikzStyleUnchanged -> "unchanged"

-- | A style refusal. Reasons that mention a construct give its structural path
-- only, never the text it contains.
tikzStyleErrorFields :: StyleError -> [Text]
tikzStyleErrorFields styleError =
  case styleError of
    StyleStale requested actual ->
      [ "error.code=stale_revision"
      , "error.requested-revision=" <> decimal (revisionToWord64 requested)
      , "error.actual-revision=" <> decimal (revisionToWord64 actual)
      ]
    StyleSemanticsUnavailable -> ["error.code=tikz_semantics_unavailable"]
    StyleTargetMissing target ->
      [ "error.code=tikz_target_missing"
      , "error.node-id=" <> nodeIdText target
      ]
    StyleContentUnreadable reason ->
      [ "error.code=style_content_unreadable"
      , "error.detail=" <> reason
      ]
    StyleRefused reason ->
      ["error.code=style_refused", "error.detail=" <> reason]
    StyleSourceCheckFailed _ -> ["error.code=style_source_check_failed"]
    StyleVerificationFailed -> ["error.code=style_verification_failed"]

tikzMoveErrorFields :: MoveError -> [Text]
tikzMoveErrorFields moveError =
  case moveError of
    MoveStale requested actual ->
      [ "error.code=stale_revision"
      , "error.requested-revision=" <> decimal (revisionToWord64 requested)
      , "error.actual-revision=" <> decimal (revisionToWord64 actual)
      ]
    MoveSemanticsUnavailable ->
      ["error.code=tikz_semantics_unavailable"]
    MoveTargetMissing target ->
      [ "error.code=tikz_target_missing"
      , "error.node-id=" <> nodeIdText target
      ]
    MoveTargetAmbiguous target ->
      [ "error.code=tikz_target_ambiguous"
      , "error.node-id=" <> nodeIdText target
      ]
    MoveProjectionUnsupported target ->
      [ "error.code=tikz_projection_unsupported"
      , "error.node-id=" <> nodeIdText target
      ]
    MoveSourceCheckFailed sourceError -> sourceErrorFields sourceError
    MoveVerificationFailed failure ->
      [ "error.code=tikz_verification_failed"
      , "error.reason=" <> renderVerificationFailure failure
      ]

renderVerificationFailure :: VerificationFailure -> Text
renderVerificationFailure failure =
  case failure of
    VerificationParseOrElaborationFailed ->
      "parse_or_elaboration_failed"
    VerificationSemanticMismatch -> "semantic_mismatch"

decodeFailureFields :: ProtocolDecodeFailure -> [Text]
decodeFailureFields failure =
  case failure of
    ProtocolMalformedJSON message ->
      ["error.code=malformed_json", "error.message=" <> oneLine message]
    ProtocolUnsupportedVersion version ->
      ["error.code=unsupported_protocol", "error.protocol=" <> oneLine version]
    ProtocolUnknownCommand command ->
      ["error.code=unknown_command", "error.command=" <> oneLine command]
    ProtocolInvalidField message ->
      ["error.code=invalid_field", "error.message=" <> oneLine message]

renderUtf8Status :: Utf8Status -> Text
renderUtf8Status status =
  case status of
    ValidUtf8 -> "true"
    InvalidUtf8 -> "false"

renderBool :: Bool -> Text
renderBool value
  | value = "true"
  | otherwise = "false"

decimal :: Show value => value -> Text
decimal = Text.pack . show

oneLine :: Text -> Text
oneLine = Text.map replaceNewline
  where
    replaceNewline character
      | character == '\n' || character == '\r' = ' '
      | otherwise = character
