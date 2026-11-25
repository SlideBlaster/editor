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
  , PictureEditOp (..)
  , FigureEditOp (..)
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
import Data.ByteString.Builder qualified as ByteStringBuilder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text.Encoding qualified as TextEncoding
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

-- | One canvas edit of a slide's picture block. Points are plan pixels (the
-- session coordinate space); nodes are named by id, lines as @line-N@.
data PictureEditOp
  = -- | TikZ options for the new node, its centre, and its content.
    PictureAddNode !Text !Double !Double !Text
  | PictureMoveNode !Text !Double !Double
  | -- | Node, side, the node it attaches to, and the gap in plan pixels (none: the default gap).
    PictureAttach !Text !Text !Text !(Maybe Double)
  | PictureSetText !Text !Text
  | -- | Item (node id or @line-N@), options to set (bare when the value is absent) and keys to remove.
    PictureStyle !Text ![(Text, Maybe Text)] ![Text]
  | -- | Node and the width and height its box should have, in plan pixels.
    PictureResize !Text !Double !Double
  | PictureConnect !Text !Text
  | PictureDelete !Text
  | -- | Bring a picture file onto the slide, shifted by plan pixels.
    PictureAddInclude !Text !Double !Double
  | -- | Give an included picture (@cat-N@) a shift, in plan pixels.
    PictureMoveInclude !Text !Double !Double
  | -- | Remove several items (ids as they are before the edit).
    PictureDeleteMany ![Text]
  | -- | Node and where it goes in the painting order: @front@, @back@, @forward@, @backward@.
    PictureReorder !Text !Text
  | -- | Picture statements to copy onto the slide, shifted right and down by plan pixels.
    PicturePaste !Text !Double !Double
  | -- | Several edits as one step.
    PictureBatch ![PictureEditOp]
  | -- | Line, how it goes (@straight@, @hv@, @vh@, @bend left@, @bend right@), bend in degrees.
    PictureRoute !Text !Text !(Maybe Double)
  | -- | Line, label number (0 adds one), text (empty removes).
    PictureLabelText !Text !Int !Text
  | -- | Line, label number, options to set and to remove.
    PictureLabelStyle !Text !Int ![(Text, Maybe Text)] ![Text]
  | -- | Line, step (from 1) and the plan point to put into it.
    PictureAddPoint !Text !Int !Double !Double
  | -- | Line, point (from 0) and where it goes, in plan pixels.
    PictureMovePoint !Text !Int !Double !Double
  | PictureRemovePoint !Text !Int
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
  | PictureEdit !Word64 !Text !PictureEditOp
  | FigureEdit !Word64 !Text !FigureEditOp
  -- ^ revision, the figure's reference, the change
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
  | ImageRefs !Bool
  -- ^ whether images are named in plans (and fetched with 'Resources') rather than carried in every plan
  | Resources ![Text]
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
    "picture_edit" -> do
      exact ["revision", "frame", "op"]
      op <- field "op" request >>= pictureOp
      PictureEdit <$> word "revision" request <*> text "frame" request <*> pure op
    "figure_edit" -> do
      exact ["revision", "figure", "op"]
      op <- field "op" request >>= figureOp
      FigureEdit <$> word "revision" request <*> text "figure" request <*> pure op
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
    "image_refs" -> do
      exact ["on"]
      field "on" request >>= \value -> case value of
        Bool on -> Right (ImageRefs on)
        _ -> Left (SessionInvalidField "on")
    "resources" -> do
      exact ["refs"]
      refs <- field "refs" request >>= \value -> case value of
        Array items | length items <= 2000 -> traverse (\item -> case item of String ref -> Right ref; _ -> Left (SessionInvalidField "refs")) (toList items)
        _ -> Left (SessionInvalidField "refs")
      Right (Resources refs)
    "pointer_event" -> Left (SessionNotImplemented "pointer_event")
    "activate_node" -> Left (SessionNotImplemented "activate_node")
    _ -> Left SessionUnknownCommand
  where
    providerKey = if KeyMap.member "artifact" request then "artifact" else "diagnostics"

-- | A change to a TikZ figure the core draws itself. @at@ is where the
-- statement or node starts in the figure's text, as the drawing reports it.
data FigureEditOp
  = -- | right and up, in centimetres
    FigureMove !Int !Double !Double
  | FigureText !Int !Text
  | -- | set an option (an empty value writes the bare key), or with no value take it away
    FigureOption !Int !Text !(Maybe Text)
  | FigureDelete !Int
  | -- | a new node at a place of the picture (centimetres, y up): its options and text
    FigureAddNode !Double !Double !Text !Text
  | -- | a new line between two nodes, with these options
    FigureAddLine !Int !Int !Text
  | -- | at least this wide and high, in centimetres
    FigureResize !Int !Double !Double
  | -- | @straight@, @hv@, @vh@, @bend left@ or @bend right@
    FigureRoute !Int !Text
  | FigureBatch ![FigureEditOp]
  deriving stock (Eq, Show)

figureOp :: Value -> Either SessionError FigureEditOp
figureOp (Object op) = do
  kind <- text "kind" op
  let exact keys = requireKeys ("kind" : keys) op
      at = count "at" op
  case kind of
    "move" -> exact ["at", "dx", "dy"] >> FigureMove <$> at <*> double "dx" op <*> double "dy" op
    "text" -> exact ["at", "text"] >> FigureText <$> at <*> text "text" op
    "option" -> do
      exact ["at", "key", "value"]
      value <- case KeyMap.lookup "value" op of
        Just Null -> Right Nothing
        _ -> Just <$> text "value" op
      FigureOption <$> at <*> text "key" op <*> pure value
    "delete" -> exact ["at"] >> FigureDelete <$> at
    "add_node" -> exact ["x", "y", "options", "text"] >> FigureAddNode <$> double "x" op <*> double "y" op <*> text "options" op <*> text "text" op
    "add_line" -> exact ["from", "to", "options"] >> FigureAddLine <$> count "from" op <*> count "to" op <*> text "options" op
    "resize" -> exact ["at", "width", "height"] >> FigureResize <$> at <*> double "width" op <*> double "height" op
    "route" -> do
      exact ["at", "to"]
      to <- text "to" op
      if to `elem` ["straight", "hv", "vh", "bend left", "bend right"] then FigureRoute <$> at <*> pure to else Left (SessionInvalidField "to")
    "batch" -> do
      exact ["ops"]
      ops <- field "ops" op >>= \value -> case value of
        Array items | length items <= 500 -> traverse figureOp (toList items)
        _ -> Left (SessionInvalidField "ops")
      Right (FigureBatch ops)
    _ -> Left (SessionInvalidField "kind")
figureOp _ = Left (SessionInvalidField "op")

pictureOp :: Value -> Either SessionError PictureEditOp
pictureOp (Object op) = do
  kind <- text "kind" op
  let exact keys = requireKeys ("kind" : keys) op
  case kind of
    "add_node" -> exact ["options", "x", "y", "text"] >> PictureAddNode <$> text "options" op <*> double "x" op <*> double "y" op <*> text "text" op
    "move_node" -> exact ["node", "x", "y"] >> PictureMoveNode <$> text "node" op <*> double "x" op <*> double "y" op
    "attach" -> do
      exact ["node", "side", "to", "distance"]
      gap <- case KeyMap.lookup "distance" op of
        Just Null -> Right Nothing
        _ -> Just <$> double "distance" op
      PictureAttach <$> text "node" op <*> text "side" op <*> text "to" op <*> pure gap
    "style" -> do
      exact ["item", "set", "remove"]
      set <- array "set" op >>= traverse optionEntry
      remove <- array "remove" op >>= traverse (\v -> case v of String key -> Right key; _ -> Left (SessionInvalidField "remove entry"))
      PictureStyle <$> text "item" op <*> pure set <*> pure remove
    "resize" -> exact ["node", "width", "height"] >> PictureResize <$> text "node" op <*> double "width" op <*> double "height" op
    "set_text" -> exact ["node", "text"] >> PictureSetText <$> text "node" op <*> text "text" op
    "connect" -> exact ["from", "to"] >> PictureConnect <$> text "from" op <*> text "to" op
    "delete" -> exact ["item"] >> PictureDelete <$> text "item" op
    "add_include" -> exact ["path", "x", "y"] >> PictureAddInclude <$> text "path" op <*> double "x" op <*> double "y" op
    "move_include" -> exact ["item", "x", "y"] >> PictureMoveInclude <$> text "item" op <*> double "x" op <*> double "y" op
    "delete_many" -> do
      exact ["items"]
      PictureDeleteMany <$> (array "items" op >>= traverse (\v -> case v of String item -> Right item; _ -> Left (SessionInvalidField "items entry")))
    "reorder" -> do
      exact ["node", "to"]
      to <- text "to" op
      if to `elem` ["front", "back", "forward", "backward"] then PictureReorder <$> text "node" op <*> pure to else Left (SessionInvalidField "to")
    "paste" -> exact ["text", "x", "y"] >> PicturePaste <$> text "text" op <*> double "x" op <*> double "y" op
    "route" -> do
      exact ["line", "to", "bend"]
      bend <- case KeyMap.lookup "bend" op of
        Just Null -> Right Nothing
        _ -> Just <$> double "bend" op
      to <- text "to" op
      if to `elem` ["straight", "hv", "vh", "bend left", "bend right"] && maybe True (\d -> d >= 0 && d <= 180) bend then PictureRoute <$> text "line" op <*> pure to <*> pure bend else Left (SessionInvalidField "to")
    "label" -> exact ["line", "index", "text"] >> PictureLabelText <$> text "line" op <*> (count "index" op) <*> text "text" op
    "label_style" -> do
      exact ["line", "index", "set", "remove"]
      set <- array "set" op >>= traverse optionEntry
      remove <- array "remove" op >>= traverse (\v -> case v of String key -> Right key; _ -> Left (SessionInvalidField "remove entry"))
      PictureLabelStyle <$> text "line" op <*> (count "index" op) <*> pure set <*> pure remove
    "add_point" -> exact ["line", "step", "x", "y"] >> PictureAddPoint <$> text "line" op <*> (count "step" op) <*> double "x" op <*> double "y" op
    "move_point" -> exact ["line", "point", "x", "y"] >> PictureMovePoint <$> text "line" op <*> (count "point" op) <*> double "x" op <*> double "y" op
    "remove_point" -> exact ["line", "point"] >> PictureRemovePoint <$> text "line" op <*> (count "point" op)
    "batch" -> do
      exact ["ops"]
      ops <- array "ops" op >>= traverse pictureOp
      -- one level only, and a bounded number of edits
      if null ops || length ops > 400 || or [True | PictureBatch _ <- ops] then Left (SessionInvalidField "ops") else Right (PictureBatch ops)
    _ -> Left (SessionInvalidField "op.kind")
pictureOp _ = Left (SessionInvalidField "op must be an object")

optionEntry :: Value -> Either SessionError (Text, Maybe Text)
optionEntry (Object entry) = do
  requireKeys ["key", "value"] entry
  key <- text "key" entry
  case KeyMap.lookup "value" entry of
    Just Null -> Right (key, Nothing)
    _ -> (,) key . Just <$> text "value" entry
optionEntry _ = Left (SessionInvalidField "set entry")

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
-- A small whole number: which label, step or point of a line.
count :: Text -> Object -> Either SessionError Int
count key obj = word key obj >>= \value -> if value <= 10000 then Right (fromIntegral value) else Left (SessionInvalidField key)

word :: Text -> Object -> Either SessionError Word64
word key obj = field key obj >>= \value -> case value of
  Number n | Right integer <- (floatingOrInteger n :: Either Double Integer), integer >= 0, integer <= 9007199254740991 -> Right (fromIntegral integer)
  _ -> Left (SessionInvalidField (key <> " must be a safe non-negative integer"))

base16 :: Text -> Object -> Either SessionError ByteString
base16 key obj = text key obj >>= maybe (Left (SessionInvalidField (key <> " must be lowercase base16"))) Right . decodeBase16

-- | Lowercase base16 of exact bytes.
encodeBase16 :: ByteString -> Text
encodeBase16 = TextEncoding.decodeLatin1 . LazyByteString.toStrict . ByteStringBuilder.toLazyByteString . ByteStringBuilder.byteStringHex

-- | Strict lowercase base16 (even length, no uppercase).
decodeBase16 :: Text -> Maybe ByteString
decodeBase16 value =
  -- over the bytes, not through a list of characters: a project is megabytes of this
  let digits = TextEncoding.encodeUtf8 value
      count = ByteString.length digits
      nibble w
        | w >= 48 && w <= 57 = Just (w - 48)
        | w >= 97 && w <= 102 = Just (w - 87)
        | otherwise = Nothing
      step index
        | index + 1 >= count = Nothing
        | otherwise = case (nibble (ByteString.index digits index), nibble (ByteString.index digits (index + 1))) of
            (Just high, Just low) -> Just (high * 16 + low, index + 2)
            _ -> Nothing
      (bytes, _) = ByteString.unfoldrN (count `div` 2) step 0
   in if even count && ByteString.length bytes == count `div` 2 then Just bytes else Nothing
