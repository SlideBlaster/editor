{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Extension.Envelope
-- Description : The block.render request and result envelope and its JSON form.
--
-- @{ticket, slot, kind, fingerprint, input, deadline}@ in,
-- @{ticket, fingerprint, artifact | diagnostics | absence}@ out, exactly as
-- specified in @docs/specs/cap-websocket.md@. The same codec serves the Wasm
-- core, the @/cap@ server and the stdio transport. A requester accepts a result
-- only when 'resultTicket' and 'resultFingerprint' match what it sent.
module SlideBlaster.Extension.Envelope
  ( RenderEnvelope (..)
  , EnvelopeError (..)
  , Severity (..)
  , Diagnostic (..)
  , Provenance (..)
  , Artifact (..)
  , Outcome (..)
  , RenderResult (..)
  , decodeRenderEnvelope
  , encodeRenderEnvelope
  , encodeRenderResult
  , decodeRenderResult
  , absenceDiagnostic
  , acceptsResult
  ) where

import SlideBlaster.Extension.Absence
import SlideBlaster.Extension.Base64 (decodeBase64, encodeBase64)
import SlideBlaster.Extension.Request
import SlideBlaster.Extension.Slot (Slot (..), parseSlot, slotName)

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Maybe (catMaybes)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Vector qualified as Vector

-- | A parsed @block.render@ request.
data RenderEnvelope = RenderEnvelope
  { envelopeTicket :: !Ticket
  , envelopeFingerprint :: !(Maybe Fingerprint)
  -- ^ Optional claim; a provider host recomputes and compares.
  , envelopeDeadlineMs :: !(Maybe Int)
  , envelopeRequest :: !BlockRequest
  }
  deriving (Eq, Show)

-- | A malformed envelope: the field and a reason.
data EnvelopeError = EnvelopeError
  { envelopeErrorField :: !Text
  , envelopeErrorReason :: !Text
  }
  deriving (Eq, Show)

-- | Diagnostic severity.
data Severity = SeverityError | SeverityWarning | SeverityInfo
  deriving (Eq, Show)

-- | A located message for the diagnostics list.
data Diagnostic = Diagnostic
  { diagnosticSeverity :: !Severity
  , diagnosticCode :: !Text
  , diagnosticMessage :: !Text
  , diagnosticTexLine :: !(Maybe Int)
  , diagnosticSourceLine :: !(Maybe Int)
  , diagnosticFile :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | Who produced an artifact and how.
data Provenance = Provenance
  { provenanceProvider :: !Text
  , provenanceVersion :: !Text
  , provenanceCached :: !Bool
  , provenanceElapsedMs :: !Int
  }
  deriving (Eq, Show)

-- | A produced artifact; bytes are exactly the cached file.
data Artifact = Artifact
  { artifactMime :: !Text
  , artifactBytes :: !ByteString
  , artifactProvenance :: !Provenance
  }
  deriving (Eq, Show)

-- | What happened to a request.
data Outcome
  = Rendered !Artifact
  | Failed
  -- ^ The provider ran and reported diagnostics (not cached).
  | Absent !Absence
  -- ^ No artifact could be produced; see 'Absence'.
  deriving (Eq, Show)

-- | A @block.render@ result.
data RenderResult = RenderResult
  { resultTicket :: !Ticket
  , resultFingerprint :: !Fingerprint
  , resultOutcome :: !Outcome
  , resultDiagnostics :: ![Diagnostic]
  }
  deriving (Eq, Show)

-- | The warning diagnostic that accompanies an absence.
absenceDiagnostic :: Absence -> Diagnostic
absenceDiagnostic absence =
  Diagnostic SeverityWarning "provider.absent" (absenceMessage absence) Nothing Nothing Nothing

-- | The requester-side echo check: ticket and fingerprint must both match.
acceptsResult :: Ticket -> Fingerprint -> RenderResult -> Bool
acceptsResult ticket fingerprint result =
  resultTicket result == ticket && resultFingerprint result == fingerprint

-- ---------------------------------------------------------------------------
-- Decoding

type Decode a = Either EnvelopeError a

bad :: Text -> Text -> Decode a
bad field reason = Left (EnvelopeError field reason)

-- | Decode the object of a @block.render@ message (the @id@ and @op@ members of
-- the surrounding transport message are ignored).
decodeRenderEnvelope :: Aeson.Object -> Decode RenderEnvelope
decodeRenderEnvelope msg = do
  ticket <- field "ticket" msg >>= text "ticket"
  case KeyMap.lookup "slot" msg of
    Nothing -> Right ()
    Just raw -> do
      slotText <- text "slot" raw
      case parseSlot slotText of
        Just BlockRender -> Right ()
        _ -> bad "slot" "must be block.render"
  kind <- field "kind" msg >>= text "kind"
  fingerprint <- case KeyMap.lookup "fingerprint" msg of
    Nothing -> Right Nothing
    Just Null -> Right Nothing
    Just raw -> do
      claimed <- text "fingerprint" raw
      maybe (bad "fingerprint" "must be 64 lower-case hex characters") (Right . Just) (mkFingerprint claimed)
  deadline <- optionalInt "deadline" msg
  inputObject <- field "input" msg >>= object' "input"
  request <- decodeBlockRequest kind inputObject
  Right
    RenderEnvelope
      { envelopeTicket = Ticket ticket
      , envelopeFingerprint = fingerprint
      , envelopeDeadlineMs = deadline
      , envelopeRequest = request
      }

decodeBlockRequest :: Text -> Aeson.Object -> Decode BlockRequest
decodeBlockRequest kind obj = do
  body <- field' "input.body" "body" obj >>= text "input.body"
  preamble <- maybe (Right "") (text "input.preamble") (KeyMap.lookup "preamble" obj)
  palette <- case KeyMap.lookup "palette" obj of
    Nothing -> Right []
    Just raw -> array "input.palette" raw >>= traverse decodeColour
  width <- optionalInt "input.width" obj
  inputs <- case KeyMap.lookup "inputs" obj of
    Nothing -> Right []
    Just raw -> array "input.inputs" raw >>= traverse decodeInput
  lineMap <- case KeyMap.lookup "lineMap" obj of
    Nothing -> Right Nothing
    Just Null -> Right Nothing
    Just raw -> Just <$> decodeLineMap raw
  Right
    BlockRequest
      { requestKind = kind
      , requestBody = body
      , requestPreamble = preamble
      , requestPalette = palette
      , requestWidth = width
      , requestInputs = inputs
      , requestLineMap = lineMap
      }
  where
    decodeColour raw = do
      o <- object' "input.palette[]" raw
      name <- field' "input.palette[].name" "name" o >>= text "input.palette[].name"
      hex <- field' "input.palette[].hex" "hex" o >>= text "input.palette[].hex"
      Right (PaletteColour name hex)
    decodeInput raw = do
      o <- object' "input.inputs[]" raw
      path <- field' "input.inputs[].path" "path" o >>= text "input.inputs[].path"
      b64 <- field' "input.inputs[].contentBase64" "contentBase64" o >>= text "input.inputs[].contentBase64"
      case decodeBase64 (Encoding.encodeUtf8 b64) of
        Nothing -> bad "input.inputs[].contentBase64" "invalid base64"
        Just bytes -> Right (ResolvedInput path bytes)
    decodeLineMap raw = do
      o <- object' "input.lineMap" raw
      file <- field' "input.lineMap.file" "file" o >>= text "input.lineMap.file"
      first <- maybe (Right 1) Right =<< optionalInt "input.lineMap.firstLine" o
      Right (LineMap file first)

field :: Text -> Aeson.Object -> Decode Value
field name = field' name name

field' :: Text -> Text -> Aeson.Object -> Decode Value
field' path name obj = maybe (bad path "is required") Right (KeyMap.lookup (Key.fromText name) obj)

text :: Text -> Value -> Decode Text
text _ (String t) = Right t
text path _ = bad path "must be a string"

object' :: Text -> Value -> Decode Aeson.Object
object' _ (Object o) = Right o
object' path _ = bad path "must be an object"

array :: Text -> Value -> Decode [Value]
array _ (Array a) = Right (Vector.toList a)
array path _ = bad path "must be an array"

optionalInt :: Text -> Aeson.Object -> Decode (Maybe Int)
optionalInt path obj = case KeyMap.lookup (Key.fromText (lastSegment path)) obj of
  Nothing -> Right Nothing
  Just Null -> Right Nothing
  Just (Number n) -> case floatingOrInteger n :: Either Double Int of
    Right whole | whole >= 0 -> Right (Just whole)
    _ -> bad path "must be a non-negative integer"
  Just _ -> bad path "must be a non-negative integer"
  where
    lastSegment = snd . Text.breakOnEnd "."

-- ---------------------------------------------------------------------------
-- Encoding

-- | Encode a request message body (members only; the caller adds @id@ and @op@).
encodeRenderEnvelope :: RenderEnvelope -> [Pair]
encodeRenderEnvelope env =
  [ "ticket" .= ticketText (envelopeTicket env)
  , "slot" .= slotName BlockRender
  , "kind" .= requestKind req
  ]
    <> ["fingerprint" .= fingerprintText f | Just f <- [envelopeFingerprint env]]
    <> ["deadline" .= d | Just d <- [envelopeDeadlineMs env]]
    <> ["input" .= inputJson]
  where
    req = envelopeRequest env
    inputJson =
      object . catMaybes $
        [ Just ("body" .= requestBody req)
        , nonEmpty "preamble" (requestPreamble req)
        , if null (requestPalette req)
            then Nothing
            else Just ("palette" .= [object ["name" .= colourName c, "hex" .= colourHex c] | c <- requestPalette req])
        , ("width" .=) <$> requestWidth req
        , if null (requestInputs req)
            then Nothing
            else
              Just
                ( "inputs"
                    .= [ object ["path" .= inputPath i, "contentBase64" .= b64 (inputBytes i)]
                       | i <- requestInputs req
                       ]
                )
        , (\(LineMap file first) -> "lineMap" .= object ["file" .= file, "firstLine" .= first]) <$> requestLineMap req
        ]
    nonEmpty name t = if Text.null t then Nothing else Just (name .= t)

b64 :: ByteString -> Text
b64 = Encoding.decodeLatin1 . encodeBase64

-- | Encode a result as response members (the caller adds @id@ and @ok@).
encodeRenderResult :: RenderResult -> [Pair]
encodeRenderResult result =
  [ "ticket" .= ticketText (resultTicket result)
  , "fingerprint" .= fingerprintText (resultFingerprint result)
  ]
    <> outcomePairs (resultOutcome result)
    <> ["diagnostics" .= (diagnosticJson <$> resultDiagnostics result)]
  where
    outcomePairs outcome = case outcome of
      Rendered artifact -> ["artifact" .= artifactJson artifact]
      Failed -> []
      Absent absence -> ["absence" .= absenceJson absence]

absenceJson :: Absence -> Value
absenceJson absence =
  object $
    ["reason" .= absenceCode absence]
      <> case absence of
        ToolMissing provider tool -> ["provider" .= provider, "tool" .= tool]
        NoProvider kind -> ["kind" .= kind]
        TimedOut provider ms -> ["provider" .= provider, "limit" .= ms]
        LimitExceeded provider bytes -> ["provider" .= provider, "limit" .= bytes]

artifactJson :: Artifact -> Value
artifactJson artifact =
  object
    [ "mime" .= artifactMime artifact
    , "encoding" .= (if isText then "utf8" else "base64" :: Text)
    , "data" .= (if isText then utf8 else b64 bytes)
    , "size" .= ByteString.length bytes
    , "provenance"
        .= object
          [ "provider" .= provenanceProvider p
          , "version" .= provenanceVersion p
          , "cached" .= provenanceCached p
          , "elapsedMs" .= provenanceElapsedMs p
          ]
    ]
  where
    bytes = artifactBytes artifact
    p = artifactProvenance artifact
    decoded = Encoding.decodeUtf8' bytes
    isText = isTextMime (artifactMime artifact) && either (const False) (const True) decoded
    utf8 = either (const "") id decoded

isTextMime :: Text -> Bool
isTextMime mime = "text/" `Text.isPrefixOf` mime || mime == "image/svg+xml" || mime == "application/json"

diagnosticJson :: Diagnostic -> Value
diagnosticJson d =
  object . catMaybes $
    [ Just ("severity" .= severityName (diagnosticSeverity d))
    , Just ("code" .= diagnosticCode d)
    , Just ("message" .= diagnosticMessage d)
    , ("texLine" .=) <$> diagnosticTexLine d
    , ("sourceLine" .=) <$> diagnosticSourceLine d
    , ("file" .=) <$> diagnosticFile d
    ]

severityName :: Severity -> Text
severityName s = case s of
  SeverityError -> "error"
  SeverityWarning -> "warning"
  SeverityInfo -> "info"

-- | Decode result members (for the Wasm core, tests and the stdio transport).
decodeRenderResult :: Aeson.Object -> Decode RenderResult
decodeRenderResult obj = do
  ticket <- field "ticket" obj >>= text "ticket"
  fpText <- field "fingerprint" obj >>= text "fingerprint"
  fp <- maybe (bad "fingerprint" "must be 64 lower-case hex characters") Right (mkFingerprint fpText)
  diagnostics <- case KeyMap.lookup "diagnostics" obj of
    Nothing -> Right []
    Just raw -> array "diagnostics" raw >>= traverse decodeDiagnostic
  outcome <- case (KeyMap.lookup "artifact" obj, KeyMap.lookup "absence" obj) of
    (Just a, _) -> Rendered <$> decodeArtifact a
    (Nothing, Just a) -> Absent <$> decodeAbsence a
    (Nothing, Nothing) -> Right Failed
  Right (RenderResult (Ticket ticket) fp outcome diagnostics)

decodeArtifact :: Value -> Decode Artifact
decodeArtifact raw = do
  o <- object' "artifact" raw
  mime <- field' "artifact.mime" "mime" o >>= text "artifact.mime"
  encoding <- field' "artifact.encoding" "encoding" o >>= text "artifact.encoding"
  dat <- field' "artifact.data" "data" o >>= text "artifact.data"
  bytes <- case encoding of
    "utf8" -> Right (Encoding.encodeUtf8 dat)
    "base64" -> maybe (bad "artifact.data" "invalid base64") Right (decodeBase64 (Encoding.encodeUtf8 dat))
    _ -> bad "artifact.encoding" "must be utf8 or base64"
  prov <- field' "artifact.provenance" "provenance" o >>= object' "artifact.provenance"
  provider <- field' "provenance.provider" "provider" prov >>= text "provenance.provider"
  version <- field' "provenance.version" "version" prov >>= text "provenance.version"
  let cached = KeyMap.lookup "cached" prov == Just (Bool True)
  elapsed <- maybe 0 id <$> optionalInt "elapsedMs" prov
  Right (Artifact mime bytes (Provenance provider version cached elapsed))

decodeAbsence :: Value -> Decode Absence
decodeAbsence raw = do
  o <- object' "absence" raw
  reason <- field' "absence.reason" "reason" o >>= text "absence.reason"
  let optText name = maybe (Right "") (text name) (KeyMap.lookup (Key.fromText name) o)
  provider <- optText "provider"
  tool <- optText "tool"
  kind <- optText "kind"
  limit <- maybe 0 id <$> optionalInt "limit" o
  case reason of
    "tool_missing" -> Right (ToolMissing provider tool)
    "no_provider" -> Right (NoProvider kind)
    "timeout" -> Right (TimedOut provider limit)
    "limit_exceeded" -> Right (LimitExceeded provider limit)
    _ -> bad "absence.reason" "unknown reason"

decodeDiagnostic :: Value -> Decode Diagnostic
decodeDiagnostic raw = do
  o <- object' "diagnostic" raw
  sev <- field' "diagnostic.severity" "severity" o >>= text "diagnostic.severity"
  severity <- case sev of
    "error" -> Right SeverityError
    "warning" -> Right SeverityWarning
    "info" -> Right SeverityInfo
    _ -> bad "diagnostic.severity" "unknown severity"
  code <- field' "diagnostic.code" "code" o >>= text "diagnostic.code"
  message <- field' "diagnostic.message" "message" o >>= text "diagnostic.message"
  texLine <- optionalInt "texLine" o
  sourceLine <- optionalInt "sourceLine" o
  file <- maybe (Right Nothing) (fmap Just . text "diagnostic.file") (KeyMap.lookup "file" o)
  Right (Diagnostic severity code message texLine sourceLine file)
