{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Protocol.Codec
-- Description : Exact JSON encoding for the shared engine protocol.
--
-- Protocol v1 represents source and replacement bytes as lowercase base16.
-- This keeps JSON portable while preserving malformed or non-UTF-8 authored
-- bytes exactly. Decoding validates the protocol, command, byte encoding,
-- offsets, and revisions before constructing domain values.
module SlideBlaster.Protocol.Codec
  ( decodeEngineRequestJSON
  , encodeEngineRequestJSON
  , encodeEngineResponseJSON
  , encodeProtocolErrorJSON
  , engineProtocol
  ) where

import SlideBlaster.Engine
  ( AppliedTikzMove
  , ExactLocalEditError (..)
  , ExactReplacementReceipt (..)
  , SnapshotInspection (..)
  , TikzAnalysis (..)
  , TikzIntentError (..)
  , TikzMoveIntent
  , TikzStyleIntent
  , TikzStyleOutcome (..)
  , AppliedTikzStyle
  , appliedTikzStyleAnalysis
  , appliedTikzStyleBeforeRevision
  , appliedTikzStyleIntent
  , appliedTikzStyleOutcome
  , mkTikzStyleIntent
  , tikzStyleIntentCommand
  , tikzStyleIntentDialect
  , tikzStyleIntentNodeId
  , tikzStyleIntentRevision
  , TikzMoveOutcome (..)
  , Utf8Status (..)
  , appliedReplacementReceipt
  , appliedReplacementSnapshot
  , appliedTikzMoveAnalysis
  , appliedTikzMoveBeforeRevision
  , appliedTikzMoveIntent
  , appliedTikzMoveOutcome
  , mkTikzMoveIntent
  , tikzAnalysisSnapshot
  , tikzMoveIntentDestination
  , tikzMoveIntentNodeId
  , tikzMoveIntentRevision
  )
import SlideBlaster.Protocol.Style
  ( dialectName
  , parseDialect
  , encodeCommand
  , encodeStyleError
  , parseCommand
  )
import SlideBlaster.Syntax.Command (Command)
import SlideBlaster.Protocol.Types
  ( EngineRequest (..)
  , EngineResponse (..)
  , ProtocolDecodeFailure (..)
  , ProtocolError (..)
  )
import SlideBlaster.Source
  ( ExactReplacement
  , ExactReplacementError (..)
  , SourceSpan
  , SourceBufferSnapshot
  , exactReplacementExpected
  , exactReplacementRevision
  , exactReplacementSpan
  , exactReplacementValue
  , mkExactReplacement
  , revisionFromWord64
  , revisionToWord64
  , snapshotAtRevision
  , snapshotBytes
  , snapshotRevision
  , sourceSpanEnd
  , sourceSpanFromInts
  , sourceSpanStart
  , unByteOffset
  )
import SlideBlaster.Syntax.Colour (rgbToHex)
import SlideBlaster.Syntax.Inline
  ( InlineIssue (UnexpandedMacro, UnresolvableColour)
  , InlineRun (..)
  , ResolvedStyle (..)
  , RunKind (BreakRun, MathRun, OpaqueRun, PlainRun, VerbatimRun)
  )
import SlideBlaster.Syntax.Path (pathToList)
import SlideBlaster.Syntax.Style
  ( Family (Monospace, SansSerif, Serif)
  , Slant (Italic, Upright)
  , Variant (NormalVariant, SmallCaps)
  , Weight (Bold, NormalWeight)
  )
import SlideBlaster.Syntax.Surface (Dialect (Html, Markdown, Tex))
import SlideBlaster.TikZ.NodeContent
  ( ContentStatus (ContentOpaque, ContentUnderstood)
  , NodeContent (..)
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
  , renderNodeContent
  , renderNodeId
  , renderNodePosition
  , renderNodeStructuredContent
  , renderPlanConnector
  , renderPlanNode
  )

import Data.Aeson
  ( Object
  , Value (Null)
  , eitherDecodeStrict'
  , encode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.Aeson.Types (Pair, Parser, parseEither)
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as ByteStringBuilder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text.Encoding qualified as TextEncoding
import Data.Char (chr, ord)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64, Word8)
import Control.Monad (unless)

-- | Fully qualified identifier for the engine JSON protocol.
engineProtocol :: Text
engineProtocol = "slideblaster.engine/1"

-- | Decode and validate one exact engine request.
decodeEngineRequestJSON :: ByteString -> Either ProtocolError EngineRequest
decodeEngineRequestJSON bytes = do
  value <-
    first
      (ProtocolDecodeError . ProtocolMalformedJSON . Text.pack)
      (decodeJSONValue bytes)
  wireProtocol <- parseFieldValue parseProtocol value
  if wireProtocol /= engineProtocol
    then Left (ProtocolDecodeError (ProtocolUnsupportedVersion wireProtocol))
    else do
      command <- parseFieldValue parseCommandField value
      decodeCommand command value

-- | Encode a request for cross-target fixtures or a browser caller.
encodeEngineRequestJSON :: EngineRequest -> ByteString
encodeEngineRequestJSON request =
  strictEncode $
    case request of
      InspectSource snapshot ->
        object
          [ "protocol" .= engineProtocol
          , "command" .= ("inspect" :: Text)
          , "snapshot" .= encodeSnapshot snapshot
          ]
      ReplaceSource snapshot replacement ->
        object
          [ "protocol" .= engineProtocol
          , "command" .= ("replace" :: Text)
          , "snapshot" .= encodeSnapshot snapshot
          , "edit"
              .= object
                [ "revision"
                    .= revisionToWord64 (exactReplacementRevision replacement)
                , "start"
                    .= unByteOffset
                      (sourceSpanStart (exactReplacementSpan replacement))
                , "end"
                    .= unByteOffset
                      (sourceSpanEnd (exactReplacementSpan replacement))
                , "expected" .= encodeBase16 (exactReplacementExpected replacement)
                , "value" .= encodeBase16 (exactReplacementValue replacement)
                ]
          ]
      AnalyzeTikz snapshot ->
        object
          [ "protocol" .= engineProtocol
          , "command" .= ("analyze_tikz" :: Text)
          , "snapshot" .= encodeSnapshot snapshot
          ]
      MoveTikzNode snapshot intent ->
        object
          [ "protocol" .= engineProtocol
          , "command" .= ("move_tikz_node" :: Text)
          , "snapshot" .= encodeSnapshot snapshot
          , "intent" .= encodeMoveIntent intent
          ]
      StyleTikzNode snapshot intent ->
        object
          [ "protocol" .= engineProtocol
          , "command" .= ("style_tikz_node" :: Text)
          , "snapshot" .= encodeSnapshot snapshot
          , "intent" .= encodeStyleIntent intent
          ]

-- | Encode a successful response, including the authoritative successor.
encodeEngineResponseJSON :: EngineResponse -> ByteString
encodeEngineResponseJSON response =
  strictEncode $
    case response of
      SourceInspected snapshot inspection ->
        successObject "inspection" snapshot inspection []
      SourceReplaced applied inspection ->
        successObject
          "replacement"
          (appliedReplacementSnapshot applied)
          inspection
          ["edit" .= encodeReceipt (appliedReplacementReceipt applied)]
      TikzAnalyzed analysis ->
        tikzSuccessObject "tikz_analysis" analysis []
      TikzNodeMoved applied ->
        tikzSuccessObject
          "tikz_move"
          (appliedTikzMoveAnalysis applied)
          ["move" .= encodeAppliedTikzMove applied]
      TikzNodeStyled applied ->
        tikzSuccessObject
          "tikz_style"
          (appliedTikzStyleAnalysis applied)
          ["style" .= encodeAppliedTikzStyle applied]

-- | Encode a typed protocol rejection without disclosing source bytes.
encodeProtocolErrorJSON :: ProtocolError -> ByteString
encodeProtocolErrorJSON problem =
  strictEncode $
    object
      [ "protocol" .= engineProtocol
      , "ok" .= False
      , "error" .= encodeProtocolError problem
      ]

decodeCommand :: Text -> Value -> Either ProtocolError EngineRequest
decodeCommand command value =
  case command of
    "inspect" -> do
      wireSnapshot <- parseFieldValue parseSnapshotField value
      InspectSource <$> decodeSnapshot wireSnapshot
    "replace" -> do
      (wireSnapshot, wireEdit) <- parseFieldValue parseReplaceFields value
      snapshot <- decodeSnapshot wireSnapshot
      replacement <- decodeReplacement wireEdit
      pure (ReplaceSource snapshot replacement)
    "analyze_tikz" -> do
      wireSnapshot <- parseFieldValue parseSnapshotField value
      AnalyzeTikz <$> decodeSnapshot wireSnapshot
    "move_tikz_node" -> do
      (wireSnapshot, wireIntent) <- parseFieldValue parseMoveFields value
      snapshot <- decodeSnapshot wireSnapshot
      intent <- decodeMoveIntent wireIntent
      pure (MoveTikzNode snapshot intent)
    "style_tikz_node" -> do
      (wireSnapshot, revision, targetId, themeDialect, styleCommand) <-
        parseFieldValue parseStyleFields value
      snapshot <- decodeSnapshot wireSnapshot
      case
        mkTikzStyleIntent
          (revisionFromWord64 revision)
          targetId
          themeDialect
          styleCommand of
        Left problem ->
          Left
            ( ProtocolDecodeError
                (ProtocolInvalidField (renderTikzIntentError problem))
            )
        Right intent -> pure (StyleTikzNode snapshot intent)
    _ -> Left (ProtocolDecodeError (ProtocolUnknownCommand command))

data WireSnapshot = WireSnapshot !Word64 !Text !Text

data WireReplacement = WireReplacement !Word64 !Word64 !Word64 !Text !Text

data WireMoveIntent = WireMoveIntent !Word64 !Text !Text !Text

-- Wasm32 and native builds deliberately share the smaller offset domain so the
-- same JSON request cannot decode differently by target word size.
maxProtocolByteOffset :: Word64
maxProtocolByteOffset = 2_147_483_647

parseProtocol :: Value -> Parser Text
parseProtocol =
  withObject "SlideBlaster engine request" $ \value ->
    value .: "protocol"

parseCommandField :: Value -> Parser Text
parseCommandField =
  withObject "SlideBlaster engine request" $ \value ->
    value .: "command"

parseSnapshotField :: Value -> Parser WireSnapshot
parseSnapshotField =
  withObject "SlideBlaster snapshot request" $ \value -> do
    requireExactKeys ["protocol", "command", "snapshot"] value
    value .: "snapshot" >>= parseSnapshot

parseReplaceFields :: Value -> Parser (WireSnapshot, WireReplacement)
parseReplaceFields =
  withObject "SlideBlaster replacement request" $ \value -> do
    requireExactKeys ["protocol", "command", "snapshot", "edit"] value
    (,)
      <$> (value .: "snapshot" >>= parseSnapshot)
      <*> (value .: "edit" >>= parseReplacement)

parseMoveFields :: Value -> Parser (WireSnapshot, WireMoveIntent)
parseMoveFields =
  withObject "SlideBlaster TikZ move request" $ \value -> do
    requireExactKeys ["protocol", "command", "snapshot", "intent"] value
    (,)
      <$> (value .: "snapshot" >>= parseSnapshot)
      <*> (value .: "intent" >>= parseMoveIntent)

parseSnapshot :: Value -> Parser WireSnapshot
parseSnapshot =
  withObject "SlideBlaster source snapshot" $ \value -> do
    requireExactKeys ["revision", "source", "encoding"] value
    WireSnapshot
      <$> value .: "revision"
      <*> value .: "source"
      <*> value .: "encoding"

parseReplacement :: Value -> Parser WireReplacement
parseReplacement =
  withObject "SlideBlaster exact replacement" $ \value -> do
    requireExactKeys ["revision", "start", "end", "expected", "value"] value
    WireReplacement
      <$> value .: "revision"
      <*> value .: "start"
      <*> value .: "end"
      <*> value .: "expected"
      <*> value .: "value"

parseMoveIntent :: Value -> Parser WireMoveIntent
parseMoveIntent =
  withObject "SlideBlaster TikZ move intent" $ \value -> do
    requireExactKeys ["revision", "nodeId", "destination"] value
    revision <- value .: "revision"
    nodeIdentity <- value .: "nodeId"
    (xCoordinate, yCoordinate) <-
      value .: "destination" >>= parseWirePoint
    pure
      ( WireMoveIntent
          revision
          nodeIdentity
          xCoordinate
          yCoordinate
      )

parseWirePoint :: Value -> Parser (Text, Text)
parseWirePoint =
  withObject "SlideBlaster decimal point" $ \value -> do
    requireExactKeys ["x", "y"] value
    (,)
      <$> value .: "x"
      <*> value .: "y"

requireExactKeys :: [Key] -> Object -> Parser ()
requireExactKeys expected value =
  unless
    ( KeyMap.size value == length expected
        && all (`KeyMap.member` value) expected
    )
    (fail "request contains missing or unknown fields")

decodeSnapshot :: WireSnapshot -> Either ProtocolError SourceBufferSnapshot
decodeSnapshot (WireSnapshot revision sourceText encoding)
  | encoding /= "base16" =
      Left
        ( ProtocolDecodeError
            (ProtocolInvalidField "snapshot.encoding must be base16")
        )
  | otherwise = do
      sourceBytes <- decodeBase16Field "snapshot.source" sourceText
      pure (snapshotAtRevision (revisionFromWord64 revision) sourceBytes)

decodeReplacement :: WireReplacement -> Either ProtocolError ExactReplacement
decodeReplacement (WireReplacement revision wireStart wireEnd expectedText valueText) = do
  start <- decodeByteOffset "edit.start" wireStart
  end <- decodeByteOffset "edit.end" wireEnd
  spanValue <-
    case sourceSpanFromInts start end of
      Nothing ->
        Left
          (ProtocolDecodeError (ProtocolInvalidField "edit span is negative or reversed"))
      Just validSpan -> Right validSpan
  expected <- decodeBase16Field "edit.expected" expectedText
  replacement <- decodeBase16Field "edit.value" valueText
  pure
    ( mkExactReplacement
        (revisionFromWord64 revision)
        spanValue
        expected
        replacement
    )

decodeMoveIntent :: WireMoveIntent -> Either ProtocolError TikzMoveIntent
decodeMoveIntent (WireMoveIntent revision nodeIdentity xCoordinate yCoordinate) =
  case
      mkTikzMoveIntent
        (revisionFromWord64 revision)
        nodeIdentity
        xCoordinate
        yCoordinate
    of
      Left problem ->
        Left
          ( ProtocolDecodeError
              (ProtocolInvalidField (renderTikzIntentError problem))
          )
      Right intent -> Right intent

renderTikzIntentError :: TikzIntentError -> Text
renderTikzIntentError problem =
  case problem of
    TikzIntentInvalidNodeId _ ->
      "intent.nodeId is outside the validated identifier grammar"
    TikzIntentInvalidX _ ->
      "intent.destination.x is outside the bounded decimal grammar"
    TikzIntentInvalidY _ ->
      "intent.destination.y is outside the bounded decimal grammar"

decodeByteOffset :: Text -> Word64 -> Either ProtocolError Int
decodeByteOffset field value
  | value > maxProtocolByteOffset =
      Left
        ( ProtocolDecodeError
            ( ProtocolInvalidField
                (field <> " exceeds the cross-target byte-offset limit")
            )
        )
  | otherwise = Right (fromIntegral value)

parseFieldValue :: (Value -> Parser result) -> Value -> Either ProtocolError result
parseFieldValue parser value =
  first
    (ProtocolDecodeError . ProtocolInvalidField . Text.pack)
    (parseEither parser value)

decodeBase16Field :: Text -> Text -> Either ProtocolError ByteString
decodeBase16Field field value =
  first
    (ProtocolDecodeError . ProtocolInvalidField . ((field <> ": ") <>))
    (decodeBase16 value)

encodeSnapshot :: SourceBufferSnapshot -> Value
encodeSnapshot snapshot =
  object
    [ "revision" .= revisionToWord64 (snapshotRevision snapshot)
    , "source" .= encodeBase16 (snapshotBytes snapshot)
    , "encoding" .= ("base16" :: Text)
    ]

encodeMoveIntent :: TikzMoveIntent -> Value
encodeMoveIntent intent =
  object
    [ "revision" .= revisionToWord64 (tikzMoveIntentRevision intent)
    , "nodeId" .= nodeIdText (tikzMoveIntentNodeId intent)
    , "destination" .= encodePoint (tikzMoveIntentDestination intent)
    ]

tikzSuccessObject :: Text -> TikzAnalysis -> [Pair] -> Value
tikzSuccessObject responseKind analysis extraFields =
  object
    ( [ "protocol" .= engineProtocol
      , "ok" .= True
      , "response" .= responseKind
      , "snapshot" .= encodeSnapshot (tikzAnalysisSnapshot analysis)
      ]
        <> extraFields
        <> ["analysis" .= encodeTikzAnalysis analysis]
    )

encodeTikzAnalysis :: TikzAnalysis -> Value
encodeTikzAnalysis analysis =
  case analysis of
    TikzAnalysisReady _ plan ->
      object
        [ "state" .= ("ready" :: Text)
        , "renderPlan"
            .= encodeRenderPlan (tikzAnalysisSnapshot analysis) plan
        ]
    TikzAnalysisSyntaxOnly _ diagnostics ->
      object
        [ "state" .= ("syntax_only" :: Text)
        , "diagnostics"
            .= fmap encodeDiagnostic (NonEmpty.toList diagnostics)
        ]

encodeRenderPlan :: SourceBufferSnapshot -> RenderPlan -> Value
encodeRenderPlan snapshot plan =
  object
    [ "sourceRevision" .= revisionToWord64 (snapshotRevision snapshot)
    , "coordinateSpace" .= ("slide_16x9_y_up" :: Text)
    , "node"
        .= object
          [ "kind" .= ("content_node" :: Text)
          , "id" .= nodeIdText (renderNodeId node)
          , "center" .= encodePoint (renderNodePosition node)
          , -- The exact authored bytes stay in the protocol. They are the
            -- authority; the runs below are a derived convenience for drawing.
            "content" .= renderNodeContent node
          , "contentStatus" .= encodeContentStatus (nodeContentStatus structured)
          , "runs" .= fmap encodeInlineRun (nodeContentRuns structured)
          , "issues" .= fmap encodeInlineIssue (nodeContentIssues structured)
          ]
    , "connector"
        .= object
          [ "kind" .= ("straight_connector" :: Text)
          , "start" .= encodePoint (renderConnectorStart connector)
          , "end" .= encodePoint (renderConnectorEnd connector)
          ]
    ]
  where
    node = renderPlanNode plan
    structured = renderNodeStructuredContent node
    connector = renderPlanConnector plan

-- | Whether the content was interpreted. An opaque status carries its reason so
-- the host can explain the fallback instead of silently showing raw source.
encodeContentStatus :: ContentStatus -> Value
encodeContentStatus status =
  case status of
    ContentUnderstood -> object ["kind" .= ("understood" :: Text)]
    ContentOpaque reason ->
      object ["kind" .= ("opaque" :: Text), "reason" .= reason]

-- | One resolved run.
--
-- The path travels with the run because it is what turns an interaction on screen
-- back into an edit on the authored tree. Without it the host could draw the
-- content but could never change it.
encodeInlineRun :: InlineRun -> Value
encodeInlineRun run =
  object
    [ "kind" .= encodeRunKind (runKind run)
    , "text" .= runText run
    , "path" .= pathToList (runPath run)
    , "dialect" .= maybe Null (\value -> object ["name" .= encodeDialect value]) (runDialect run)
    , "link" .= maybe Null (\value -> object ["target" .= value]) (runLink run)
    , "style" .= encodeResolvedStyle (runStyle run)
    ]

encodeRunKind :: RunKind -> Text
encodeRunKind kind =
  case kind of
    PlainRun -> "plain"
    MathRun _ -> "math"
    VerbatimRun -> "verbatim"
    BreakRun -> "break"
    OpaqueRun -> "opaque"

encodeDialect :: Dialect -> Text
encodeDialect dialect =
  case dialect of
    Tex -> "tex"
    Html -> "html"
    Markdown -> "markdown"

-- | Styling in effect, with colours already resolved to sRGB.
--
-- Resolution happens in Haskell, not in the host: xcolor's mixing rules are
-- source semantics, and a browser must not be asked to reimplement them.
encodeResolvedStyle :: ResolvedStyle -> Value
encodeResolvedStyle style =
  object
    [ "weight" .= case styleWeight style of
        NormalWeight -> "normal" :: Text
        Bold -> "bold"
    , "slant" .= case styleSlant style of
        Upright -> "upright" :: Text
        Italic -> "italic"
    , "family" .= case styleFamily style of
        Serif -> "serif" :: Text
        SansSerif -> "sans" :: Text
        Monospace -> "mono"
    , "variant" .= case styleVariant style of
        NormalVariant -> "normal" :: Text
        SmallCaps -> "smallcaps"
    , "underline" .= styleUnderline style
    , "strike" .= styleStrike style
    , "highlight" .= styleHighlight style
    , -- Absent rather than black: the theme decides an unstated colour.
      "foreground" .= maybe Null (\value -> object ["srgb" .= rgbToHex value]) (styleForeground style)
    , "background" .= maybe Null (\value -> object ["srgb" .= rgbToHex value]) (styleBackground style)
    ]

encodeInlineIssue :: InlineIssue -> Value
encodeInlineIssue issue =
  case issue of
    UnresolvableColour path failure ->
      object
        [ "kind" .= ("unresolvable_colour" :: Text)
        , "path" .= pathToList path
        , "detail" .= Text.pack (show failure)
        ]
    UnexpandedMacro path name ->
      object
        [ "kind" .= ("unexpanded_macro" :: Text)
        , "path" .= pathToList path
        , "detail" .= Text.pack (show name)
        ]

encodePoint :: Point -> Value
encodePoint value =
  object
    [ "x" .= coordinateToText (pointX value)
    , "y" .= coordinateToText (pointY value)
    ]

encodeDiagnostic :: Diagnostic -> Value
encodeDiagnostic diagnostic =
  object
    [ "category" .= encodeDiagnosticCategory (diagnosticCategory diagnostic)
    , "code" .= encodeDiagnosticCode (diagnosticCode diagnostic)
    , "span"
        .= maybe Null encodeDiagnosticSpan (diagnosticSpan diagnostic)
    , "message" .= diagnosticMessage diagnostic
    ]

encodeDiagnosticSpan :: SourceSpan -> Value
encodeDiagnosticSpan spanValue =
  object
    [ "start" .= unByteOffset (sourceSpanStart spanValue)
    , "end" .= unByteOffset (sourceSpanEnd spanValue)
    ]

encodeDiagnosticCategory :: DiagnosticCategory -> Text
encodeDiagnosticCategory category =
  case category of
    DiagnosticMalformed -> "malformed"
    DiagnosticUnsupported -> "unsupported"
    DiagnosticAmbiguous -> "ambiguous"

encodeDiagnosticCode :: DiagnosticCode -> Text
encodeDiagnosticCode code =
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

encodeAppliedTikzMove :: AppliedTikzMove -> Value
encodeAppliedTikzMove applied =
  object
    [ "outcome" .= encodeTikzMoveOutcome (appliedTikzMoveOutcome applied)
    , "beforeRevision"
        .= revisionToWord64 (appliedTikzMoveBeforeRevision applied)
    , "afterRevision"
        .= revisionToWord64
          (snapshotRevision (tikzAnalysisSnapshot successorAnalysis))
    , "nodeId" .= nodeIdText (tikzMoveIntentNodeId intent)
    , "destination" .= encodePoint (tikzMoveIntentDestination intent)
    ]
  where
    intent = appliedTikzMoveIntent applied
    successorAnalysis = appliedTikzMoveAnalysis applied

encodeStyleIntent :: TikzStyleIntent -> Value
encodeStyleIntent intent =
  object
    [ "revision" .= revisionToWord64 (tikzStyleIntentRevision intent)
    , "nodeId" .= nodeIdText (tikzStyleIntentNodeId intent)
    , "themeDialect" .= dialectName (tikzStyleIntentDialect intent)
    , "command" .= encodeCommand (tikzStyleIntentCommand intent)
    ]

encodeAppliedTikzStyle :: AppliedTikzStyle -> Value
encodeAppliedTikzStyle applied =
  object
    [ "outcome" .= encodeTikzStyleOutcome (appliedTikzStyleOutcome applied)
    , "beforeRevision"
        .= revisionToWord64 (appliedTikzStyleBeforeRevision applied)
    , "afterRevision"
        .= revisionToWord64
          (snapshotRevision (tikzAnalysisSnapshot successorAnalysis))
    , "nodeId" .= nodeIdText (tikzStyleIntentNodeId intent)
    ]
  where
    intent = appliedTikzStyleIntent applied
    successorAnalysis = appliedTikzStyleAnalysis applied

encodeTikzStyleOutcome :: TikzStyleOutcome -> Text
encodeTikzStyleOutcome outcome =
  case outcome of
    TikzStyleVerifiedChange -> "verified_change"
    TikzStyleUnchanged -> "unchanged"

parseStyleFields :: Value -> Parser (WireSnapshot, Word64, Text, Dialect, Command)
parseStyleFields =
  withObject "SlideBlaster style request" $ \value -> do
    requireExactKeys ["protocol", "command", "snapshot", "intent"] value
    wireSnapshot <- value .: "snapshot" >>= parseSnapshot
    intent <- value .: "intent"
    (revision, nodeIdentity, themeDialect, styleCommand) <-
      withObject
        "style intent"
        ( \fields -> do
            -- The notation is required rather than defaulted. A default here would
            -- be a second opinion about a theme setting, and a silent one.
            requireExactKeys
              ["revision", "nodeId", "themeDialect", "command"]
              fields
            revisionField <- fields .: "revision"
            identityField <- fields .: "nodeId"
            dialectField <- fields .: "themeDialect" >>= parseDialect
            commandField <- fields .: "command" >>= parseCommand
            pure (revisionField, identityField, dialectField, commandField)
        )
        intent
    pure (wireSnapshot, revision, nodeIdentity, themeDialect, styleCommand)

encodeTikzMoveOutcome :: TikzMoveOutcome -> Text
encodeTikzMoveOutcome outcome =
  case outcome of
    TikzMoveVerifiedChange -> "verified_change"
    TikzMoveUnchanged -> "unchanged"

successObject
  :: Text
  -> SourceBufferSnapshot
  -> SnapshotInspection
  -> [Pair]
  -> Value
successObject responseKind snapshot inspection extraFields =
  object
    ( [ "protocol" .= engineProtocol
      , "ok" .= True
      , "response" .= responseKind
      , "snapshot" .= encodeSnapshot snapshot
      , "inspection" .= encodeInspection inspection
      ]
        <> extraFields
    )

encodeInspection :: SnapshotInspection -> Value
encodeInspection inspection =
  object
    [ "revision" .= revisionToWord64 (inspectionRevision inspection)
    , "bytes" .= inspectionByteLength inspection
    , "lines" .= inspectionLineCount inspection
    , "utf8" .= (inspectionUtf8Status inspection == ValidUtf8)
    , "fingerprint" .= inspectionFingerprint inspection
    ]

encodeReceipt :: ExactReplacementReceipt -> Value
encodeReceipt receipt =
  object
    [ "beforeRevision" .= revisionToWord64 (receiptBeforeRevision receipt)
    , "afterRevision" .= revisionToWord64 (receiptAfterRevision receipt)
    , "start"
        .= unByteOffset (sourceSpanStart (receiptTargetSpan receipt))
    , "end"
        .= unByteOffset (sourceSpanEnd (receiptTargetSpan receipt))
    , "removedBytes" .= receiptRemovedByteLength receipt
    , "insertedBytes" .= receiptInsertedByteLength receipt
    , "changed" .= receiptChanged receipt
    ]

encodeProtocolError :: ProtocolError -> Value
encodeProtocolError protocolError =
  case protocolError of
    ProtocolDecodeError decodeFailure -> encodeDecodeFailure decodeFailure
    ProtocolExactReplacementError localError ->
      case localError of
        LocalEditPostconditionFailed message ->
          errorObject "local_postcondition_failed" message []
        LocalSourceEditRejected sourceError -> encodeSourceError sourceError
    ProtocolTikzMoveError moveError -> encodeTikzMoveError moveError
    ProtocolTikzStyleError styleError -> encodeStyleError styleError

encodeTikzMoveError :: MoveError -> Value
encodeTikzMoveError moveError =
  case moveError of
    MoveStale requested actual ->
      errorObject
        "stale_revision"
        "The move targets a stale source revision"
        [ "requestedRevision" .= revisionToWord64 requested
        , "actualRevision" .= revisionToWord64 actual
        ]
    MoveSemanticsUnavailable ->
      errorObject
        "tikz_semantics_unavailable"
        "The exact source has no writable TikZ semantics"
        []
    MoveTargetMissing target ->
      errorObject
        "tikz_target_missing"
        "The requested TikZ node does not exist"
        ["nodeId" .= nodeIdText target]
    MoveTargetAmbiguous target ->
      errorObject
        "tikz_target_ambiguous"
        "The requested TikZ node is ambiguous"
        ["nodeId" .= nodeIdText target]
    MoveProjectionUnsupported target ->
      errorObject
        "tikz_projection_unsupported"
        "The requested TikZ node cannot be projected to exact source"
        ["nodeId" .= nodeIdText target]
    MoveSourceCheckFailed sourceError -> encodeSourceError sourceError
    MoveVerificationFailed failure ->
      errorObject
        "tikz_verification_failed"
        "The candidate TikZ edit failed semantic verification"
        ["reason" .= encodeVerificationFailure failure]

encodeVerificationFailure :: VerificationFailure -> Text
encodeVerificationFailure failure =
  case failure of
    VerificationParseOrElaborationFailed ->
      "parse_or_elaboration_failed"
    VerificationSemanticMismatch -> "semantic_mismatch"

encodeDecodeFailure :: ProtocolDecodeFailure -> Value
encodeDecodeFailure failure =
  case failure of
    ProtocolMalformedJSON message ->
      errorObject "malformed_json" message []
    ProtocolUnsupportedVersion version ->
      errorObject
        "unsupported_protocol"
        "The engine protocol version is not supported"
        ["actual" .= version]
    ProtocolUnknownCommand command ->
      errorObject
        "unknown_command"
        "The engine command is not supported"
        ["command" .= command]
    ProtocolInvalidField message ->
      errorObject "invalid_field" message []

encodeSourceError :: ExactReplacementError -> Value
encodeSourceError sourceError =
  case sourceError of
    ReplacementStale requested actual ->
      errorObject
        "stale_revision"
        "The replacement targets a stale source revision"
        [ "requestedRevision" .= revisionToWord64 requested
        , "actualRevision" .= revisionToWord64 actual
        ]
    ReplacementOutOfBounds target sourceLength ->
      errorObject
        "span_out_of_bounds"
        "The replacement span is outside the source"
        [ "start" .= unByteOffset (sourceSpanStart target)
        , "end" .= unByteOffset (sourceSpanEnd target)
        , "sourceBytes" .= sourceLength
        ]
    ReplacementExpectedMismatch expectedLength actualLength ->
      errorObject
        "expected_bytes_mismatch"
        "The source span does not contain the expected bytes"
        [ "expectedBytes" .= expectedLength
        , "actualBytes" .= actualLength
        ]
    ReplacementRevisionExhausted revision ->
      errorObject
        "revision_exhausted"
        "The source revision cannot advance"
        ["revision" .= revisionToWord64 revision]
    ReplacementLocalityPostconditionFailed ->
      errorObject
        "source_locality_postcondition_failed"
        "The replacement did not preserve unrelated source bytes"
        []

errorObject :: Text -> Text -> [Pair] -> Value
errorObject code message details =
  object
    [ "code" .= code
    , "message" .= message
    , "details" .= object details
    ]

strictEncode :: Value -> ByteString
strictEncode = LazyByteString.toStrict . encode

decodeJSONValue :: ByteString -> Either String Value
decodeJSONValue = eitherDecodeStrict'

encodeBase16 :: ByteString -> Text
encodeBase16 = TextEncoding.decodeLatin1 . LazyByteString.toStrict . ByteStringBuilder.toLazyByteString . ByteStringBuilder.byteStringHex

decodeBase16 :: Text -> Either Text ByteString
decodeBase16 value =
  -- over the bytes, not through a list of characters
  let digits = TextEncoding.encodeUtf8 value
      count = ByteString.length digits
      nibble w
        | w >= 48 && w <= 57 = Just (w - 48)
        | w >= 97 && w <= 102 = Just (w - 87)
        | w >= 65 && w <= 70 = Just (w - 55)
        | otherwise = Nothing
      step index
        | index + 1 >= count = Nothing
        | otherwise = case (nibble (ByteString.index digits index), nibble (ByteString.index digits (index + 1))) of
            (Just high, Just low) -> Just (high * 16 + low, index + 2)
            _ -> Nothing
      (bytes, _) = ByteString.unfoldrN (count `div` 2) step 0
   in if odd count
        then Left "base16 value has an odd number of digits"
        else if ByteString.length bytes == count `div` 2 then Right bytes else Left "base16 value contains a non-hexadecimal digit"

hexDigit :: Int -> Char
hexDigit value
  | value < 10 = chr (ord '0' + value)
  | otherwise = chr (ord 'a' + value - 10)

hexNibble :: Char -> Maybe Int
hexNibble character
  | character >= '0' && character <= '9' =
      Just (ord character - ord '0')
  | character >= 'a' && character <= 'f' =
      Just (ord character - ord 'a' + 10)
  | character >= 'A' && character <= 'F' =
      Just (ord character - ord 'A' + 10)
  | otherwise = Nothing
