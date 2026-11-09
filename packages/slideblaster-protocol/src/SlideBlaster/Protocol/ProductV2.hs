{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Protocol.ProductV2
-- Description : Closed composition-neutral Product/2 wire vocabulary and JSON codec.
--
-- This module owns only the stable Product/2 request, response-envelope, and
-- error vocabulary. It deliberately knows nothing about application state,
-- source history, TikZ, presentation meaning, rendering, or gesture
-- transitions. A product runtime interprets these closed values.
module SlideBlaster.Protocol.ProductV2
  ( productProtocolV2
  , ProductV2Request (..)
  , PaintFenceValue (..)
  , SurfaceValue (..)
  , SurfaceKindValue (..)
  , PointerEventValue (..)
  , PointerSampleValue (..)
  , PointerTargetValue (..)
  , PointerTypeValue (..)
  , PointerButtonValue (..)
  , PointerModifiersValue (..)
  , PointValue (..)
  , ViewCommandValue (..)
  , ProductV2Error (..)
  , ProductV2Success
  , productV2Success
  , decodeProductV2RequestJSON
  , encodeProductV2SuccessJSON
  , encodeProductV2ErrorJSON
  ) where

import Data.Aeson
  ( Object
  , Result (..)
  , Value (..)
  , eitherDecodeStrict'
  , encode
  , fromJSON
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (ord)
import Data.Ratio ((%))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64, Word8)

-- | Version identifier for the source-authoritative product boundary.
productProtocolV2 :: Text
productProtocolV2 = "slideblaster.product/2"

-- | Closed surface spelling used only for wire correlation.
data SurfaceKindValue = AudienceSurfaceValue | NotesSurfaceValue
  deriving stock (Eq, Show)

-- | Closed painted surface address carried by node-targeted requests.
data SurfaceValue = SurfaceValue
  { surfaceFrameValue :: !Text
  , surfaceKindValue :: !SurfaceKindValue
  }
  deriving stock (Eq, Show)

-- | Exact correlation supplied when acknowledging a paint.
data PaintFenceValue = PaintFenceValue
  { fenceSession :: !Word64
  , fenceRevision :: !Word64
  , fenceTicket :: !Word64
  , fenceFrame :: !Text
  , fenceSurface :: !SurfaceKindValue
  }
  deriving stock (Eq, Show)

-- | Exact protocol point. Coordinates are finite exact-number strings on JSON.
data PointValue = PointValue !Rational !Rational
  deriving stock (Eq, Show)

-- | Closed pointer kind.
data PointerTypeValue = MousePointerValue | PenPointerValue | TouchPointerValue
  deriving stock (Eq, Show)

-- | Closed pointer button fact.
data PointerButtonValue
  = PrimaryButtonValue
  | MiddleButtonValue
  | SecondaryButtonValue
  | OtherButtonValue !Word64
  deriving stock (Eq, Show)

-- | Closed modifier facts carried by each pointer sample.
data PointerModifiersValue = PointerModifiersValue
  { modifierAltValue :: !Bool
  , modifierShiftValue :: !Bool
  , modifierControlValue :: !Bool
  , modifierMetaValue :: !Bool
  }
  deriving stock (Eq, Show)

-- | One semantically complete raw pointer sample.
data PointerSampleValue = PointerSampleValue
  { pointerIdValue :: !Word64
  , pointerTypeValue :: !PointerTypeValue
  , pointerButtonValue :: !PointerButtonValue
  , pointerPrimaryValue :: !Bool
  , pointerCssPointValue :: !PointValue
  , pointerSlidePointValue :: !PointValue
  , pointerModifiersValue :: !PointerModifiersValue
  }
  deriving stock (Eq, Show)

-- | Closed painted hit target.
data PointerTargetValue = CanvasTargetValue | NodeTargetValue !SurfaceValue !Text
  deriving stock (Eq, Show)

-- | Raw pointer-event vocabulary. Policy commands are intentionally absent.
data PointerEventValue
  = PointerDownValue !PointerTargetValue !PointerSampleValue
  | PointerMoveValue !PointerSampleValue
  | PointerUpValue !PointerSampleValue
  | PointerCancelValue !Word64
  | PointerLostCaptureValue !Word64
  deriving stock (Eq, Show)

-- | Closed view command vocabulary. The visible canvas region is browser
-- presentation state, so zoom and pan are not protocol commands.
data ViewCommandValue
  = PreviousSlideValue
  | NextSlideValue
  deriving stock (Eq, Show)

-- | Closed browser command set. Keyboard activation selects and requests focus;
-- it does not encode a source mutation or keyboard movement operation.
data ProductV2Request
  = OpenSource !ByteString
  | ProductV2WorkspaceSnapshot
  | AcknowledgePaint !PaintFenceValue
  | ProductV2PointerEvent !PointerEventValue
  | ProductV2ViewCommand !ViewCommandValue
  | ProductV2ActivateNode !SurfaceValue !Text
  | SelectSlideProduct !Text
  | NewSlideProduct !Word64
  | UndoProduct !Word64
  | RedoProduct !Word64
  | ReplaceProductSource !Word64 !ByteString
  deriving stock (Eq, Show)

-- | Stable, source-redacted protocol failures.
data ProductV2Error
  = ProductV2MalformedJSON
  | ProductV2UnsupportedProtocol
  | ProductV2UnknownCommand
  | ProductV2InvalidField !Text
  | ProductV2WorkspaceNotOpen
  | ProductV2StaleRevision !Word64 !Word64
  | ProductV2PaintNotOffered
  | ProductV2PaintFenceMismatch
  | ProductV2NodeNotAdmitted
  | ProductV2NodeNotSelected
  | ProductV2SessionIdExhausted
  | ProductV2GestureIdExhausted
  | ProductV2GestureNotActive
  | ProductV2GestureIdMismatch
  | ProductV2GestureNotPreviewed
  | ProductV2GestureStaleRevision
  | ProductV2GestureStalePaint
  | ProductV2HistoryUnavailable
  | ProductV2AnalysisRejected
  | ProductV2RenderRejected
  | ProductV2PaintRejected
  | ProductV2CanvasEditRejected
  | ProductV2CanvasProjectionRejected
  | ProductV2CanvasVerificationRejected
  | ProductV2DeckNotReady
  | ProductV2ActiveSlideMissing
  | ProductV2DeckProjectionRejected
  | ProductV2SurfaceNotActive
  deriving stock (Eq, Show)

-- | Opaque successful response envelope.
newtype ProductV2Success = ProductV2Success Value

-- | Build the stable successful response envelope. Runtime-specific projection
-- remains a closed JSON value validated by protocol shape tests.
productV2Success :: Text -> [Value] -> Value -> ProductV2Success
productV2Success kind actions workspace =
  ProductV2Success
    ( object
        [ "protocol" .= productProtocolV2
        , "ok" .= True
        , "kind" .= kind
        , "actions" .= actions
        , "workspace" .= workspace
        ]
    )

-- | Decode one exact-key Product/2 request.
decodeProductV2RequestJSON :: ByteString -> Either ProductV2Error ProductV2Request
decodeProductV2RequestJSON bytes = do
  value <- mapLeft (const ProductV2MalformedJSON) (eitherDecodeStrict' bytes)
  decodeRequest value

-- | Encode one successful response.
encodeProductV2SuccessJSON :: ProductV2Success -> ByteString
encodeProductV2SuccessJSON (ProductV2Success value) = LazyByteString.toStrict (encode value)

-- | Encode one typed error without authored bytes or exception text.
encodeProductV2ErrorJSON :: ProductV2Error -> ByteString
encodeProductV2ErrorJSON failure =
  LazyByteString.toStrict
    ( encode
        ( object
            [ "protocol" .= productProtocolV2
            , "ok" .= False
            , "kind" .= ("error" :: Text)
            , "error" .= object ["code" .= errorCode failure, "message" .= errorMessage failure]
            ]
        )
    )

decodeRequest :: Value -> Either ProductV2Error ProductV2Request
decodeRequest value = do
  request <- expectObject "request" value
  protocol <- requiredText "request.protocol" "protocol" request
  if protocol == productProtocolV2 then Right () else Left ProductV2UnsupportedProtocol
  command <- requiredText "request.command" "command" request
  case command of
    "open_source" -> requireFields "request" ["protocol", "command", "sourceBase16"] request >> OpenSource <$> requiredBase16 "request.sourceBase16" "sourceBase16" request
    "workspace_snapshot" -> requireFields "request" ["protocol", "command"] request >> Right ProductV2WorkspaceSnapshot
    "acknowledge_paint" -> requireFields "request" ["protocol", "command", "paint"] request >> AcknowledgePaint <$> requiredPaintFence request
    "pointer_event" -> requireFields "request" ["protocol", "command", "event"] request >> ProductV2PointerEvent <$> requiredPointerEvent request
    "view_command" -> requireFields "request" ["protocol", "command", "viewCommand"] request >> ProductV2ViewCommand <$> requiredViewCommand request
    "activate_node" -> do
      requireFields "request" ["protocol", "command", "surface", "nodeId"] request
      ProductV2ActivateNode <$> requiredSurface "request.surface" "surface" request <*> requiredText "request.nodeId" "nodeId" request
    "select_slide" -> requireFields "request" ["protocol", "command", "frame"] request >> SelectSlideProduct <$> requiredText "request.frame" "frame" request
    "new_slide" -> requireFields "request" ["protocol", "command", "revision"] request >> NewSlideProduct <$> safeWord "request.revision" "revision" request
    "undo" -> requireFields "request" ["protocol", "command", "revision"] request >> UndoProduct <$> safeWord "request.revision" "revision" request
    "redo" -> requireFields "request" ["protocol", "command", "revision"] request >> RedoProduct <$> safeWord "request.revision" "revision" request
    "replace_source" -> do
      requireFields "request" ["protocol", "command", "revision", "sourceBase16"] request
      ReplaceProductSource <$> safeWord "request.revision" "revision" request <*> requiredBase16 "request.sourceBase16" "sourceBase16" request
    _ -> Left ProductV2UnknownCommand


requiredSurface :: Text -> Text -> Object -> Either ProductV2Error SurfaceValue
requiredSurface location key parent = do
  surface <- requiredValue location key parent >>= expectObject location
  requireFields location ["frame", "kind"] surface
  kind <- requiredText (location <> ".kind") "kind" surface
  surfaceKind <- case kind of
    "audience" -> Right AudienceSurfaceValue
    "notes" -> Right NotesSurfaceValue
    _ -> Left (ProductV2InvalidField (location <> ".kind is invalid"))
  SurfaceValue <$> requiredText (location <> ".frame") "frame" surface <*> pure surfaceKind
requiredPaintFence :: Object -> Either ProductV2Error PaintFenceValue
requiredPaintFence request = do
  paint <- requiredValue "request.paint" "paint" request >>= expectObject "request.paint"
  requireFields "request.paint" ["session", "revision", "ticket", "surface"] paint
  surface <- requiredValue "request.paint.surface" "surface" paint >>= expectObject "request.paint.surface"
  requireFields "request.paint.surface" ["frame", "kind"] surface
  kind <- requiredText "request.paint.surface.kind" "kind" surface
  surfaceKind <- case kind of
    "audience" -> Right AudienceSurfaceValue
    "notes" -> Right NotesSurfaceValue
    _ -> Left (ProductV2InvalidField "request.paint.surface.kind is invalid")
  PaintFenceValue
    <$> safeWord "request.paint.session" "session" paint
    <*> safeWord "request.paint.revision" "revision" paint
    <*> safeWord "request.paint.ticket" "ticket" paint
    <*> requiredText "request.paint.surface.frame" "frame" surface
    <*> pure surfaceKind

requiredPointerEvent :: Object -> Either ProductV2Error PointerEventValue
requiredPointerEvent request = do
  event <- requiredValue "request.event" "event" request >>= expectObject "request.event"
  kind <- requiredText "request.event.type" "type" event
  case kind of
    "down" -> requireFields "request.event" pointerSampleFieldsWithTarget event >> PointerDownValue <$> requiredPointerTarget event <*> requiredPointerSample event
    "move" -> requireFields "request.event" pointerSampleFields event >> PointerMoveValue <$> requiredPointerSample event
    "up" -> requireFields "request.event" pointerSampleFields event >> PointerUpValue <$> requiredPointerSample event
    "cancel" -> requireFields "request.event" ["type", "pointerId"] event >> PointerCancelValue <$> safeWord "request.event.pointerId" "pointerId" event
    "lost_capture" -> requireFields "request.event" ["type", "pointerId"] event >> PointerLostCaptureValue <$> safeWord "request.event.pointerId" "pointerId" event
    _ -> Left (ProductV2InvalidField "request.event.type is invalid")

pointerSampleFields :: [Text]
pointerSampleFields = ["type", "pointerId", "pointerType", "button", "primary", "cssPoint", "slidePoint", "modifiers"]

pointerSampleFieldsWithTarget :: [Text]
pointerSampleFieldsWithTarget = pointerSampleFields <> ["target"]

requiredPointerSample :: Object -> Either ProductV2Error PointerSampleValue
requiredPointerSample event =
  PointerSampleValue
    <$> safeWord "request.event.pointerId" "pointerId" event
    <*> requiredPointerType event
    <*> requiredPointerButton event
    <*> requiredBool "request.event.primary" "primary" event
    <*> requiredPoint "request.event.cssPoint" "cssPoint" event
    <*> requiredPoint "request.event.slidePoint" "slidePoint" event
    <*> requiredModifiers event

requiredPointerType :: Object -> Either ProductV2Error PointerTypeValue
requiredPointerType event = do
  value <- requiredText "request.event.pointerType" "pointerType" event
  case value of
    "mouse" -> Right MousePointerValue
    "pen" -> Right PenPointerValue
    "touch" -> Right TouchPointerValue
    _ -> Left (ProductV2InvalidField "request.event.pointerType is invalid")

requiredPointerButton :: Object -> Either ProductV2Error PointerButtonValue
requiredPointerButton event = do
  value <- safeWord "request.event.button" "button" event
  Right $ case value of
    0 -> PrimaryButtonValue
    1 -> MiddleButtonValue
    2 -> SecondaryButtonValue
    _ -> OtherButtonValue value

requiredModifiers :: Object -> Either ProductV2Error PointerModifiersValue
requiredModifiers event = do
  modifiers <- requiredValue "request.event.modifiers" "modifiers" event >>= expectObject "request.event.modifiers"
  requireFields "request.event.modifiers" ["alt", "shift", "control", "meta"] modifiers
  PointerModifiersValue
    <$> requiredBool "request.event.modifiers.alt" "alt" modifiers
    <*> requiredBool "request.event.modifiers.shift" "shift" modifiers
    <*> requiredBool "request.event.modifiers.control" "control" modifiers
    <*> requiredBool "request.event.modifiers.meta" "meta" modifiers

requiredPointerTarget :: Object -> Either ProductV2Error PointerTargetValue
requiredPointerTarget event = do
  target <- requiredValue "request.event.target" "target" event >>= expectObject "request.event.target"
  kind <- requiredText "request.event.target.kind" "kind" target
  case kind of
    "canvas" -> requireFields "request.event.target" ["kind"] target >> Right CanvasTargetValue
    "node" -> do
      requireFields "request.event.target" ["kind", "surface", "nodeId"] target
      NodeTargetValue <$> requiredSurface "request.event.target.surface" "surface" target <*> requiredText "request.event.target.nodeId" "nodeId" target
    _ -> Left (ProductV2InvalidField "request.event.target.kind is invalid")

requiredViewCommand :: Object -> Either ProductV2Error ViewCommandValue
requiredViewCommand request = do
  value <- requiredText "request.viewCommand" "viewCommand" request
  case value of
    "previous_slide" -> Right PreviousSlideValue
    "next_slide" -> Right NextSlideValue
    _ -> Left (ProductV2InvalidField "request.viewCommand is invalid")

requiredPoint :: Text -> Text -> Object -> Either ProductV2Error PointValue
requiredPoint location key request = do
  point <- requiredValue location key request >>= expectObject location
  requireFields location ["x", "y"] point
  PointValue <$> requiredRational (location <> ".x") "x" point <*> requiredRational (location <> ".y") "y" point

requiredRational :: Text -> Text -> Object -> Either ProductV2Error Rational
requiredRational location key value = do
  text <- requiredText location key value
  maybe (Left (ProductV2InvalidField (location <> " must be an exact number string"))) Right (parseExactRational text)

requiredBase16 :: Text -> Text -> Object -> Either ProductV2Error ByteString
requiredBase16 location key value = do
  text <- requiredText location key value
  maybe (Left (ProductV2InvalidField (location <> " must be even-length base16"))) Right (base16Decode text)

requiredBool :: Text -> Text -> Object -> Either ProductV2Error Bool
requiredBool location key value = do
  present <- requiredValue location key value
  case present of
    Bool result -> Right result
    _ -> Left (ProductV2InvalidField (location <> " must be a boolean"))

expectObject :: Text -> Value -> Either ProductV2Error Object
expectObject _ (Object value) = Right value
expectObject location _ = Left (ProductV2InvalidField (location <> " must be an object"))

requiredValue :: Text -> Text -> Object -> Either ProductV2Error Value
requiredValue location key value = maybe (Left (ProductV2InvalidField (location <> " is required"))) Right (KeyMap.lookup (Key.fromText key) value)

requiredText :: Text -> Text -> Object -> Either ProductV2Error Text
requiredText location key value = do
  present <- requiredValue location key value
  case present of
    String text -> Right text
    _ -> Left (ProductV2InvalidField (location <> " must be a string"))

safeWord :: Text -> Text -> Object -> Either ProductV2Error Word64
safeWord location key value = do
  present <- requiredValue location key value
  parsed <- case present of
    Number _ -> case fromJSON present :: Result Word64 of
      Error _ -> Left (ProductV2InvalidField (location <> " must be an integer"))
      Success result -> Right result
    _ -> Left (ProductV2InvalidField (location <> " must be a number"))
  if parsed <= 9007199254740991 then Right parsed else Left (ProductV2InvalidField (location <> " exceeds safe integer range"))

requireFields :: Text -> [Text] -> Object -> Either ProductV2Error ()
requireFields location required value =
  case filter (not . (`KeyMap.member` value) . Key.fromText) required of
    missing : _ -> Left (ProductV2InvalidField (location <> "." <> missing <> " is required"))
    [] -> case filter (`notElem` required) (fmap Key.toText (KeyMap.keys value)) of
      unexpected : _ -> Left (ProductV2InvalidField (location <> "." <> unexpected <> " is not allowed"))
      [] -> Right ()

parseExactRational :: Text -> Maybe Rational
parseExactRational raw
  | Text.length raw > 128 = Nothing
  | otherwise = do
      let (sign, unsigned) = maybe (1, raw) ((-1,) ) (Text.stripPrefix "-" raw)
      magnitude <- parseUnsignedRational unsigned
      Just (sign * magnitude)

parseUnsignedRational :: Text -> Maybe Rational
parseUnsignedRational value =
  case Text.splitOn "/" value of
    [top, bottom] -> do
      topValue <- parseCanonicalInteger top
      bottomValue <- parseCanonicalInteger bottom
      if bottomValue > 0 then Just (topValue % bottomValue) else Nothing
    [decimal] -> case Text.splitOn "." decimal of
      [integer] -> fromInteger <$> parseCanonicalInteger integer
      [integer, fraction] -> do
        whole <- parseCanonicalInteger integer
        fractional <- parseDigits fraction
        if Text.null fraction then Nothing else let scale = 10 ^ Text.length fraction in Just ((whole * scale + fractional) % scale)
      _ -> Nothing
    _ -> Nothing

parseCanonicalInteger :: Text -> Maybe Integer
parseCanonicalInteger value
  | Text.null value = Nothing
  | Text.length value > 1 && Text.isPrefixOf "0" value = Nothing
  | otherwise = parseDigits value

parseDigits :: Text -> Maybe Integer
parseDigits value
  | Text.null value = Nothing
  | Text.all (\character -> character >= '0' && character <= '9') value =
      Just (Text.foldl' (\total character -> total * 10 + toInteger (ord character - ord '0')) 0 value)
  | otherwise = Nothing

base16Decode :: Text -> Maybe ByteString
base16Decode value = ByteString.pack <$> pairs (Text.unpack value)
  where
    pairs characters = case characters of
      [] -> Just []
      high : low : rest -> do
        highValue <- hexValue high
        lowValue <- hexValue low
        remaining <- pairs rest
        Just (highValue * 16 + lowValue : remaining)
      [_] -> Nothing

hexValue :: Char -> Maybe Word8
hexValue character
  | character >= '0' && character <= '9' = Just (fromIntegral (ord character - ord '0'))
  | character >= 'a' && character <= 'f' = Just (fromIntegral (10 + ord character - ord 'a'))
  | character >= 'A' && character <= 'F' = Just (fromIntegral (10 + ord character - ord 'A'))
  | otherwise = Nothing

errorCode :: ProductV2Error -> Text
errorCode failure = case failure of
  ProductV2MalformedJSON -> "malformed_json"
  ProductV2UnsupportedProtocol -> "unsupported_protocol"
  ProductV2UnknownCommand -> "unknown_command"
  ProductV2InvalidField _ -> "invalid_field"
  ProductV2WorkspaceNotOpen -> "workspace_not_open"
  ProductV2StaleRevision {} -> "stale_revision"
  ProductV2PaintNotOffered -> "paint_not_offered"
  ProductV2PaintFenceMismatch -> "paint_fence_mismatch"
  ProductV2NodeNotAdmitted -> "node_not_admitted"
  ProductV2NodeNotSelected -> "node_not_selected"
  ProductV2SessionIdExhausted -> "session_id_exhausted"
  ProductV2GestureIdExhausted -> "gesture_id_exhausted"
  ProductV2GestureNotActive -> "gesture_not_active"
  ProductV2GestureIdMismatch -> "gesture_id_mismatch"
  ProductV2GestureNotPreviewed -> "gesture_not_previewed"
  ProductV2GestureStaleRevision -> "gesture_stale_revision"
  ProductV2GestureStalePaint -> "gesture_stale_paint"
  ProductV2HistoryUnavailable -> "history_unavailable"
  ProductV2AnalysisRejected -> "analysis_rejected"
  ProductV2RenderRejected -> "render_rejected"
  ProductV2PaintRejected -> "paint_rejected"
  ProductV2CanvasEditRejected -> "canvas_edit_rejected"
  ProductV2CanvasProjectionRejected -> "canvas_projection_rejected"
  ProductV2CanvasVerificationRejected -> "canvas_verification_rejected"
  ProductV2DeckNotReady -> "deck_not_ready"
  ProductV2ActiveSlideMissing -> "active_slide_missing"
  ProductV2DeckProjectionRejected -> "deck_projection_rejected"
  ProductV2SurfaceNotActive -> "surface_not_active"

errorMessage :: ProductV2Error -> Text
errorMessage failure = case failure of
  ProductV2InvalidField detail -> detail
  ProductV2StaleRevision requested actual -> "requested revision " <> Text.pack (show requested) <> " is stale; current revision is " <> Text.pack (show actual)
  ProductV2MalformedJSON -> "request is not valid JSON"
  ProductV2UnsupportedProtocol -> "request protocol is not supported"
  ProductV2UnknownCommand -> "request command is not supported"
  ProductV2WorkspaceNotOpen -> "no source workspace is open"
  ProductV2PaintNotOffered -> "no matching common paint is available"
  ProductV2PaintFenceMismatch -> "paint correlation does not match current state"
  ProductV2NodeNotAdmitted -> "node is not admitted by the current source"
  ProductV2NodeNotSelected -> "node is not the current selection"
  ProductV2SessionIdExhausted -> "no browser-safe session identifier remains"
  ProductV2GestureIdExhausted -> "no browser-safe gesture identifier remains"
  ProductV2GestureNotActive -> "no drag gesture is active"
  ProductV2GestureIdMismatch -> "gesture does not match the active drag"
  ProductV2GestureNotPreviewed -> "drag has no verified preview to commit"
  ProductV2GestureStaleRevision -> "gesture source revision is no longer current"
  ProductV2GestureStalePaint -> "gesture paint authority is no longer current"
  ProductV2HistoryUnavailable -> "requested history transition is unavailable"
  ProductV2AnalysisRejected -> "source analysis was rejected"
  ProductV2RenderRejected -> "common render projection was rejected"
  ProductV2PaintRejected -> "paint acknowledgement was rejected"
  ProductV2CanvasEditRejected -> "canvas edit authority was rejected"
  ProductV2CanvasProjectionRejected -> "canvas edit projection was rejected"
  ProductV2CanvasVerificationRejected -> "canvas edit verification was rejected"
  ProductV2DeckNotReady -> "the provisional deck is not ready"
  ProductV2ActiveSlideMissing -> "the active slide is not present"
  ProductV2DeckProjectionRejected -> "the provisional deck projection was rejected"
  ProductV2SurfaceNotActive -> "the painted surface is not the active audience surface"

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft convert value = case value of
  Left failure -> Left (convert failure)
  Right result -> Right result
