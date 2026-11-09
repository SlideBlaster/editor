{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Protocol.Session
-- Description : Closed session/1 wire vocabulary and JSON codec.
--
-- Successor of the Product/2 codec (docs/specs/session-v1-protocol.md). This
-- module owns request decoding, the response envelope and typed errors only; it
-- knows nothing of deck meaning. Requests are exact-key objects; authored bytes
-- cross as bounded lowercase base16.
module SlideBlaster.Protocol.Session
  ( sessionProtocol
  , SessionRequest (..)
  , FenceValue (..)
  , CommandName (..)
  , PaintOutcome (..)
  , Direction (..)
  , ProviderOutcome (..)
  , ProviderDiagnostic (..)
  , ProviderArtifact (..)
  , SessionError (..)
  , decodeSessionRequest
  , sessionSuccess
  , sessionErrorValue
  , encodeValue
  , encodeBase16
  , decodeBase16
  ) where

import Data.Aeson (Object, Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (ord)
import Data.Foldable (toList)
import Data.Scientific (floatingOrInteger, toRealFloat)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)

sessionProtocol :: Text
sessionProtocol = "slideblaster.session/1"

-- | Exact correlation for one painted plan.
data FenceValue = FenceValue
  { fenceSession :: !Word64
  , fenceRevision :: !Word64
  , fenceTicket :: !Word64
  , fenceFrame :: !Text
  , fenceSurface :: !Text
  }
  deriving stock (Eq, Show)

data CommandName
  = PreviousSlide
  | NextSlide
  | NewSlide
  | Undo
  | Redo
  | Save
  deriving stock (Eq, Show)

data PaintOutcome = Painted | PaintFailed !Text
  deriving stock (Eq, Show)

data Direction = StepNext | StepPrevious
  deriving stock (Eq, Show)

data ProviderArtifact = ProviderArtifact
  { artifactMime :: !Text
  , artifactBytes :: !ByteString
  , artifactWidth :: !Double
  , artifactHeight :: !Double
  , artifactProvenance :: !Text
  }
  deriving stock (Eq, Show)

data ProviderDiagnostic = ProviderDiagnostic
  { providerSeverity :: !Text
  , providerCode :: !Text
  , providerMessage :: !Text
  , providerLine :: !(Maybe Word64)
  , providerAbsent :: !Bool
  }
  deriving stock (Eq, Show)

data ProviderOutcome
  = ProviderArtifactOutcome !ProviderArtifact
  | ProviderDiagnosticsOutcome ![ProviderDiagnostic]
  deriving stock (Eq, Show)

data SessionRequest
  = OpenProject !Text ![(Text, ByteString)]
  | OpenSource !ByteString
  | ProjectFile !Text !(Maybe ByteString)
  | ApplySourceReplace !Word64 !Word64 !Word64 !ByteString !ByteString
  | ReplaceSource !Word64 !ByteString
  | SessionCommand !CommandName !(Maybe Word64)
  | SelectSlide !Text
  | AcknowledgePaint !FenceValue
  | PaintCompletion !FenceValue !PaintOutcome
  | MeasurementResult !Word64 ![(Text, Double, Double)]
  | ProviderResult !Word64 !Text !ProviderOutcome
  | StorageResult !Text !Word64 !Bool
  | PresentOpen !(Maybe Text)
  | PresentStep !Direction
  | PresentGoto !Text !(Maybe Int)
  | PresentRoute !Text
  | PresentClose
  | WorkspaceSnapshot
  deriving stock (Eq, Show)

-- | Stable, source-redacted failures.
data SessionError
  = SessionMalformedJSON
  | SessionUnsupportedProtocol
  | SessionUnknownCommand
  | SessionInvalidField !Text
  | SessionNotOpen
  | SessionStale !Word64 !Word64
  | SessionNotImplemented !Text
  | SessionStaleTicket
  | SessionMeasurementMismatch
  | SessionPaintFenceMismatch
  | SessionHistoryUnavailable
  | SessionDeckNotReady
  | SessionUnknownFrame
  | SessionEditRejected !Text
  | SessionProjectInvalid !Text
  | SessionDisabled !Text
  deriving stock (Eq, Show)

encodeValue :: Value -> ByteString
encodeValue = LazyByteString.toStrict . encode

sessionSuccess :: Text -> [Value] -> Value -> Value
sessionSuccess kind effects view =
  object
    [ "protocol" .= sessionProtocol
    , "ok" .= True
    , "kind" .= kind
    , "effects" .= effects
    , "view" .= view
    ]

sessionErrorValue :: SessionError -> Value
sessionErrorValue failure =
  object
    [ "protocol" .= sessionProtocol
    , "ok" .= False
    , "kind" .= ("error" :: Text)
    , "error" .= object ["code" .= code, "message" .= message]
    ]
  where
    (code, message) = describe failure

describe :: SessionError -> (Text, Text)
describe failure =
  case failure of
    SessionMalformedJSON -> ("malformed_json", "request is not valid JSON")
    SessionUnsupportedProtocol -> ("unsupported_protocol", "unsupported protocol string")
    SessionUnknownCommand -> ("unknown_command", "unknown command")
    SessionInvalidField detail -> ("invalid_field", detail)
    SessionNotOpen -> ("session_not_open", "no project is open")
    SessionStale requested actual ->
      ("stale_revision", "requested revision " <> shown requested <> " but current is " <> shown actual)
    SessionNotImplemented what -> ("not_implemented", what <> " is not available in this build")
    SessionStaleTicket -> ("stale_ticket", "ticket does not match the outstanding request")
    SessionMeasurementMismatch -> ("measurement_mismatch", "results do not match the requested keys")
    SessionPaintFenceMismatch -> ("paint_fence_mismatch", "fence does not match an offered plan")
    SessionHistoryUnavailable -> ("history_unavailable", "nothing to undo or redo")
    SessionDeckNotReady -> ("deck_not_ready", "the deck has errors that block this operation")
    SessionUnknownFrame -> ("unknown_frame", "no such slide")
    SessionEditRejected detail -> ("edit_rejected", detail)
    SessionProjectInvalid detail -> ("project_invalid", detail)
    SessionDisabled reason -> ("command_disabled", reason)
  where
    shown = Text.pack . show

-- | Decode one exact-key session/1 request.
decodeSessionRequest :: ByteString -> Either SessionError SessionRequest
decodeSessionRequest bytes =
  case eitherDecodeStrict' bytes of
    Left _ -> Left SessionMalformedJSON
    Right (Object request) -> decodeObject request
    Right _ -> Left (SessionInvalidField "request must be an object")

decodeObject :: Object -> Either SessionError SessionRequest
decodeObject request = do
  protocol <- text "protocol" request
  if protocol == sessionProtocol then Right () else Left SessionUnsupportedProtocol
  command <- text "command" request
  let exact keys = requireKeys (["protocol", "command"] <> keys) request
  case command of
    "open_project" -> do
      entry <- text "entry" request
      if KeyMap.member "files" request
        then do
          exact ["entry", "files"]
          files <- array "files" request >>= traverse fileEntry
          Right (OpenProject entry files)
        else exact ["entry"] >> Right (OpenProject entry [])
    "open_source" -> exact ["sourceBase16"] >> OpenSource <$> base16 "sourceBase16" request
    "project_file" -> do
      exact ["path", "bytesBase16"]
      path <- text "path" request
      case KeyMap.lookup "bytesBase16" request of
        Just Null -> Right (ProjectFile path Nothing)
        _ -> ProjectFile path . Just <$> base16 "bytesBase16" request
    "apply_source_replace" -> do
      exact ["revision", "start", "end", "expectedBase16", "replacementBase16"]
      ApplySourceReplace
        <$> word "revision" request
        <*> word "start" request
        <*> word "end" request
        <*> base16 "expectedBase16" request
        <*> base16 "replacementBase16" request
    "replace_source" -> exact ["revision", "sourceBase16"] >> ReplaceSource <$> word "revision" request <*> base16 "sourceBase16" request
    "command" -> do
      name <- text "name" request
      case name of
        "previous_slide" -> exact ["name"] >> Right (SessionCommand PreviousSlide Nothing)
        "next_slide" -> exact ["name"] >> Right (SessionCommand NextSlide Nothing)
        "save" -> exact ["name"] >> Right (SessionCommand Save Nothing)
        "new_slide" -> exact ["name", "revision"] >> SessionCommand NewSlide . Just <$> word "revision" request
        "undo" -> exact ["name", "revision"] >> SessionCommand Undo . Just <$> word "revision" request
        "redo" -> exact ["name", "revision"] >> SessionCommand Redo . Just <$> word "revision" request
        _ -> Left SessionUnknownCommand
    "select_slide" -> exact ["frame"] >> SelectSlide <$> text "frame" request
    "acknowledge_paint" -> exact ["fence"] >> AcknowledgePaint <$> fence request
    "paint_completion" -> do
      exact ["fence", "outcome"]
      outcome <- case KeyMap.lookup "outcome" request of
        Just (String "painted") -> Right Painted
        Just (Object failed) -> PaintFailed <$> text "failed" failed
        _ -> Left (SessionInvalidField "outcome")
      PaintCompletion <$> fence request <*> pure outcome
    "measurement_result" -> do
      exact ["ticket", "results"]
      results <- array "results" request >>= traverse measurement
      MeasurementResult <$> word "ticket" request <*> pure results
    "provider_result" -> do
      requireKeys ["protocol", "command", "ticket", "fingerprint", providerKey] request
      ProviderResult <$> word "ticket" request <*> text "fingerprint" request <*> providerOutcome request
    "storage_result" -> do
      exact ["path", "revision", "ok"]
      StorageResult <$> text "path" request <*> word "revision" request <*> bool "ok" request
    "present_open" -> do
      case KeyMap.lookup "startFrame" request of
        Nothing -> exact [] >> Right (PresentOpen Nothing)
        Just _ -> exact ["startFrame"] >> PresentOpen . Just <$> text "startFrame" request
    "present_step" -> do
      exact ["direction"]
      direction <- text "direction" request
      case direction of
        "next" -> Right (PresentStep StepNext)
        "previous" -> Right (PresentStep StepPrevious)
        _ -> Left (SessionInvalidField "direction")
    "present_goto" ->
      case KeyMap.lookup "step" request of
        Nothing -> exact ["frame"] >> PresentGoto <$> text "frame" request <*> pure Nothing
        Just _ -> exact ["frame", "step"] >> PresentGoto <$> text "frame" request <*> (Just . fromIntegral <$> word "step" request)
    "present_route" -> exact ["route"] >> PresentRoute <$> text "route" request
    "present_close" -> exact [] >> Right PresentClose
    "workspace_snapshot" -> exact [] >> Right WorkspaceSnapshot
    "pointer_event" -> Left (SessionNotImplemented "pointer_event")
    "activate_node" -> Left (SessionNotImplemented "activate_node")
    _ -> Left SessionUnknownCommand
  where
    providerKey = if KeyMap.member "artifact" request then "artifact" else "diagnostics"

fileEntry :: Value -> Either SessionError (Text, ByteString)
fileEntry (Object entry) = do
  requireKeys ["path", "bytesBase16"] entry
  (,) <$> text "path" entry <*> base16 "bytesBase16" entry
fileEntry _ = Left (SessionInvalidField "files entry")

measurement :: Value -> Either SessionError (Text, Double, Double)
measurement (Object entry) = do
  requireKeys ["key", "width", "height"] entry
  (,,) <$> text "key" entry <*> double "width" entry <*> double "height" entry
measurement _ = Left (SessionInvalidField "results entry")

fence :: Object -> Either SessionError FenceValue
fence parent =
  case KeyMap.lookup "fence" parent of
    Just (Object inner) -> do
      requireKeys ["session", "revision", "ticket", "frame", "surface"] inner
      FenceValue
        <$> word "session" inner
        <*> word "revision" inner
        <*> word "ticket" inner
        <*> text "frame" inner
        <*> text "surface" inner
    _ -> Left (SessionInvalidField "fence")

providerOutcome :: Object -> Either SessionError ProviderOutcome
providerOutcome request =
  case (KeyMap.lookup "artifact" request, KeyMap.lookup "diagnostics" request) of
    (Just (Object artifact), Nothing) -> do
      requireKeys ["mime", "bytesBase16", "width", "height", "provenance"] artifact
      ProviderArtifactOutcome
        <$> ( ProviderArtifact
                <$> text "mime" artifact
                <*> base16 "bytesBase16" artifact
                <*> double "width" artifact
                <*> double "height" artifact
                <*> text "provenance" artifact
            )
    (Nothing, Just (Array items)) -> ProviderDiagnosticsOutcome <$> traverse diagnostic (toList items)
    _ -> Left (SessionInvalidField "provider_result needs exactly one of artifact or diagnostics")
  where
    diagnostic (Object entry) = do
      requireKeys ["severity", "code", "message", "line", "absent"] entry
      ProviderDiagnostic
        <$> text "severity" entry
        <*> text "code" entry
        <*> text "message" entry
        <*> ( case KeyMap.lookup "line" entry of
                Just Null -> Right Nothing
                _ -> Just <$> word "line" entry
            )
        <*> bool "absent" entry
    diagnostic _ = Left (SessionInvalidField "diagnostics entry")

requireKeys :: [Text] -> Object -> Either SessionError ()
requireKeys keys obj
  | KeyMap.keys obj == sortedKeys = Right ()
  | otherwise = Left (SessionInvalidField "unexpected or missing fields")
  where
    sortedKeys = KeyMap.keys (KeyMap.fromList [(Key.fromText key, Null) | key <- keys])

field :: Text -> Object -> Either SessionError Value
field key obj = maybe (Left (SessionInvalidField (key <> " is required"))) Right (KeyMap.lookup (Key.fromText key) obj)

text :: Text -> Object -> Either SessionError Text
text key obj = field key obj >>= \value -> case value of
  String content -> Right content
  _ -> Left (SessionInvalidField (key <> " must be a string"))

bool :: Text -> Object -> Either SessionError Bool
bool key obj = field key obj >>= \value -> case value of
  Bool content -> Right content
  _ -> Left (SessionInvalidField (key <> " must be a boolean"))

array :: Text -> Object -> Either SessionError [Value]
array key obj = field key obj >>= \value -> case value of
  Array items -> Right (toList items)
  _ -> Left (SessionInvalidField (key <> " must be an array"))

double :: Text -> Object -> Either SessionError Double
double key obj = field key obj >>= \value -> case value of
  Number n -> Right (toRealFloat n)
  _ -> Left (SessionInvalidField (key <> " must be a number"))

-- | Non-negative integer below 2^53 (exactly representable in JavaScript).
word :: Text -> Object -> Either SessionError Word64
word key obj = field key obj >>= \value -> case value of
  Number n | Right integer <- (floatingOrInteger n :: Either Double Integer), integer >= 0, integer <= 9007199254740991 -> Right (fromIntegral integer)
  _ -> Left (SessionInvalidField (key <> " must be a safe non-negative integer"))

base16 :: Text -> Object -> Either SessionError ByteString
base16 key obj = text key obj >>= maybe (Left (SessionInvalidField (key <> " must be lowercase base16"))) Right . decodeBase16

-- | Lowercase base16 of exact bytes.
encodeBase16 :: ByteString -> Text
encodeBase16 = Text.pack . concatMap hex . ByteString.unpack
  where
    hex byte = [digit (byte `div` 16), digit (byte `mod` 16)]
    digit nibble
      | nibble < 10 = toEnum (fromEnum '0' + fromIntegral nibble)
      | otherwise = toEnum (fromEnum 'a' + fromIntegral nibble - 10)

-- | Strict lowercase base16 (even length, no uppercase).
decodeBase16 :: Text -> Maybe ByteString
decodeBase16 value = ByteString.pack <$> pairs (Text.unpack value)
  where
    pairs [] = Just []
    pairs (high : low : rest) = (\h l remaining -> fromIntegral (h * 16 + l :: Int) : remaining) <$> nibble high <*> nibble low <*> pairs rest
    pairs _ = Nothing
    nibble c
      | c >= '0' && c <= '9' = Just (ord c - ord '0')
      | c >= 'a' && c <= 'f' = Just (ord c - ord 'a' + 10)
      | otherwise = Nothing
