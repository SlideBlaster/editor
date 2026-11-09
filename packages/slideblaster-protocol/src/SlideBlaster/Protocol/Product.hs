{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Protocol.Product
-- Description : Closed JSON protocol for the interactive product state.
--
-- This module is the target-neutral composition boundary for live browser
-- authoring. It decodes versioned requests, invokes only the shared Haskell
-- catalog/canvas/app semantics, and projects direct render geometry back to a
-- disposable host view. The live state deliberately has no persistence
-- authority: every workspace projection says why save remains unavailable.
--
-- 'dispatchLiveRequestJSON' is atomic. A malformed, stale, unsupported, or
-- unprojectable request returns the original 'LiveAuthoring' value unchanged.
module SlideBlaster.Protocol.Product
  ( productProtocol
  , themeEditorProtocol
  , LiveProductRequest (..)
  , ThemeControlIntent (..)
  , ProductProtocolError (..)
  , LiveProductSuccess
  , decodeLiveRequestJSON
  , runLiveRequest
  , encodeLiveSuccessJSON
  , encodeLiveErrorJSON
  , dispatchLiveRequestJSON
  ) where

import SlideBlaster.App
  ( LiveAuthoring
  , LiveAuthoringError (..)
  , LiveNode
  , liveAuthoringCanRedo
  , liveAuthoringCanUndo
  , liveAuthoringGuides
  , liveAuthoringNodes
  , liveAuthoringRevision
  , liveAuthoringSelection
  , liveAuthoringTheme
  , liveCatalogFamilies
  , liveNodeBox
  , liveNodeResolvedProperties
  , liveNodeSemantic
  , liveResolveNodeOutlines
  , liveResolvePresetOutlines
  , liveRevisionToWord64
  , loadLiveDrawIOCatalog
  , moveLiveNode
  , redoLiveAuthoring
  , searchLiveCatalog
  , selectLiveNode
  , setLiveNodeDistance
  , setLivePaletteColour
  , setLiveThemeName
  , insertLiveShape
  , undoLiveAuthoring
  )
import SlideBlaster.Canvas
  ( Box
  , CanvasUnit
  , Colour (..)
  , ColourRef (..)
  , CornerTreatment (..)
  , DashPattern (..)
  , DragMode (..)
  , Flip (..)
  , Gradient (..)
  , GradientStop (..)
  , GuideKind (..)
  , Node (nodeIdentifier)
  , NodeId
  , NodeProperties (..)
  , Paint (..)
  , Point
  , Scale
  , Shadow (..)
  , Size
  , SnapGuide (..)
  , Stroke (..)
  , Theme (..)
  , ThemeStyle (..)
  , Vector
  , boxBottom
  , boxCenter
  , boxLeft
  , boxRight
  , boxSize
  , boxTop
  , canvasUnit
  , canvasUnitValue
  , identifierText
  , nodeId
  , opacityValue
  , paletteEntries
  , point
  , pointX
  , pointY
  , rotationDegrees
  , scaleX
  , scaleY
  , sizeHeight
  , sizeWidth
  , vectorX
  , vectorY
  )
import SlideBlaster.Catalog
  ( CatalogFamily
  , CatalogOrigin (..)
  , CatalogPriority (..)
  , ShapeAttribution (..)
  , ShapeId
  , ShapePreset (..)
  , catalogFamily
  , catalogFamilyText
  , shapeId
  , shapeIdText
  )
import SlideBlaster.Render
  ( RenderArcRadii
  , RenderArcSize (..)
  , RenderArcSweep (..)
  , RenderCornerRadii
  , RenderCornerRadiiView (..)
  , RenderFillRule (..)
  , RenderOutline
  , RenderOutlineView (..)
  , RenderPath
  , RenderPathClosure (..)
  , RenderPathSegment (..)
  , renderArcRadiusX
  , renderArcRadiusY
  , renderCornerRadiiView
  , renderOutlineView
  , renderPathClosure
  , renderPathSegments
  , renderPathStart
  )

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
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (ord)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Ratio (denominator, numerator, (%))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64, Word8)

-- | Version identifier for the interactive product boundary.
productProtocol :: Text
productProtocol = "slideblaster.product/1"

-- | Version identifier consumed by the browser theme-editor module.
themeEditorProtocol :: Text
themeEditorProtocol = "slideblaster.theme-editor/1"

-- | One decoded command. Revisions remain wire integers because
-- 'LiveRevision' is opaque; the runner compares them to the current state and
-- passes the actual opaque revision into the semantic operation only on match.
data LiveProductRequest
  = InitializeCatalog !Text
  | WorkspaceSnapshot
  | SearchCatalog !Text !(Maybe CatalogFamily) !Int
  | InsertShape !Word64 !ShapeId !Point
  | SelectNode !(Maybe NodeId)
  | MoveNode !Word64 !NodeId !Point !DragMode
  | SetPaletteColour !Word64 !Text !Colour
  | SetThemeName !Word64 !Text
  | SetNodeDistance !Word64 !CanvasUnit
  | UndoLive !Word64
  | RedoLive !Word64
  | ApplyThemeControl !Word64 !Text !ThemeControlIntent
  deriving stock (Eq)

-- Catalog JSON, search text, positions, colours, and theme values are redacted
-- from accidental adapter logs.
instance Show LiveProductRequest where
  show request =
    case request of
      InitializeCatalog catalogJSON ->
        "InitializeCatalog {characterLength = "
          <> show (Text.length catalogJSON)
          <> "}"
      WorkspaceSnapshot -> "WorkspaceSnapshot"
      SearchCatalog _ family resultLimit ->
        "SearchCatalog <redacted-query> "
          <> show family
          <> " "
          <> show resultLimit
      InsertShape revision identity _ ->
        "InsertShape "
          <> show revision
          <> " "
          <> show identity
          <> " <redacted-point>"
      SelectNode selection -> "SelectNode " <> show selection
      MoveNode revision identity _ mode ->
        "MoveNode "
          <> show revision
          <> " "
          <> show identity
          <> " <redacted-point> "
          <> show mode
      SetPaletteColour revision key _ ->
        "SetPaletteColour "
          <> show revision
          <> " "
          <> show key
          <> " <redacted-colour>"
      SetThemeName revision _ ->
        "SetThemeName "
          <> show revision
          <> " <redacted-name>"
      SetNodeDistance revision _ ->
        "SetNodeDistance "
          <> show revision
          <> " <redacted-distance>"
      UndoLive revision -> "UndoLive " <> show revision
      RedoLive revision -> "RedoLive " <> show revision
      ApplyThemeControl revision themeIdentity intent ->
        "ApplyThemeControl "
          <> show revision
          <> " "
          <> show themeIdentity
          <> " "
          <> show intent

-- | Supported semantic subset of the exact theme-editor intent envelope.
data ThemeControlIntent
  = SetThemeNameControl !Text
  | SetPaletteColourControl !Text !Colour
  | SetNodeDistanceControl !CanvasUnit
  deriving stock (Eq)

instance Show ThemeControlIntent where
  show intent =
    case intent of
      SetThemeNameControl {} -> "SetThemeNameControl <redacted-name>"
      SetPaletteColourControl key _ ->
        "SetPaletteColourControl "
          <> show key
          <> " <redacted-colour>"
      SetNodeDistanceControl {} ->
        "SetNodeDistanceControl <redacted-distance>"

-- | Stable failure categories. No constructor carries authored source bytes.
data ProductProtocolError
  = ProductMalformedJSON !Text
  | ProductUnsupportedProtocol !Text
  | ProductUnknownCommand !Text
  | ProductInvalidField !Text
  | ProductStaleRevision !Word64 !Word64
  | ProductThemeIdentityMismatch !Text !Text
  | ProductThemePreviewUnsupported
  | ProductThemeSaveUnavailable
  | ProductThemeUnsetUnsupported
  | ProductThemeActionUnsupported
  | ProductThemeTargetUnsupported !Text
  | ProductPaletteControlMissing !Text
  | ProductProjectionPaletteMissing !Text
  | ProductProjectionInvalid !Text
  | ProductLiveFailure !LiveAuthoringError
  deriving stock (Eq, Show)

-- | Opaque successful wire value. Callers cannot bypass the closed encoder.
newtype LiveProductSuccess = LiveProductSuccess Value

-- | Decode one closed product request.
decodeLiveRequestJSON
  :: ByteString
  -> Either ProductProtocolError LiveProductRequest
decodeLiveRequestJSON bytes = do
  value <-
    mapLeft
      (ProductMalformedJSON . Text.pack)
      (eitherDecodeStrict' bytes)
  decodeRequestValue value

-- | Run one decoded request and construct its complete response projection.
--
-- Projection failure is part of the transaction: callers receive no successor.
runLiveRequest
  :: LiveAuthoring
  -> LiveProductRequest
  -> Either
      ProductProtocolError
      (LiveAuthoring, LiveProductSuccess)
runLiveRequest authoring request =
  case request of
    InitializeCatalog catalogJSON -> do
      next <-
        mapLive
          ( loadLiveDrawIOCatalog
              (TextEncoding.encodeUtf8 catalogJSON)
              authoring
          )
      successWithWorkspace "catalog_initialized" next
    WorkspaceSnapshot ->
      successWithWorkspace "workspace_snapshot" authoring
    SearchCatalog query wantedFamily resultLimit -> do
      let presets =
            searchLiveCatalog
              query
              wantedFamily
              resultLimit
              authoring
      results <- traverse (shapePresetValue authoring) presets
      Right
        ( authoring
        , LiveProductSuccess
            ( successValue
                "catalog_search"
                ["results" .= results]
            )
        )
    InsertShape requestedRevision identity position -> do
      ensureRevision requestedRevision authoring
      next <-
        mapLive
          ( insertLiveShape
              (liveAuthoringRevision authoring)
              identity
              position
              authoring
          )
      successWithWorkspace "shape_inserted" next
    SelectNode selection -> do
      next <- mapLive (selectLiveNode selection authoring)
      successWithWorkspace "selection_changed" next
    MoveNode requestedRevision identity position mode -> do
      ensureRevision requestedRevision authoring
      next <-
        mapLive
          ( moveLiveNode
              (liveAuthoringRevision authoring)
              identity
              position
              mode
              authoring
          )
      successWithWorkspace "node_moved" next
    SetPaletteColour requestedRevision key colour -> do
      ensureRevision requestedRevision authoring
      next <-
        mapLive
          ( setLivePaletteColour
              (liveAuthoringRevision authoring)
              key
              colour
              authoring
          )
      successWithWorkspace "palette_colour_set" next
    SetThemeName requestedRevision name -> do
      ensureRevision requestedRevision authoring
      next <-
        mapLive
          ( setLiveThemeName
              (liveAuthoringRevision authoring)
              name
              authoring
          )
      successWithWorkspace "theme_name_set" next
    SetNodeDistance requestedRevision distance -> do
      ensureRevision requestedRevision authoring
      next <-
        mapLive
          ( setLiveNodeDistance
              (liveAuthoringRevision authoring)
              distance
              authoring
          )
      successWithWorkspace "node_distance_set" next
    UndoLive requestedRevision -> do
      ensureRevision requestedRevision authoring
      next <-
        mapLive
          (undoLiveAuthoring (liveAuthoringRevision authoring) authoring)
      successWithWorkspace "undo" next
    RedoLive requestedRevision -> do
      ensureRevision requestedRevision authoring
      next <-
        mapLive
          (redoLiveAuthoring (liveAuthoringRevision authoring) authoring)
      successWithWorkspace "redo" next
    ApplyThemeControl requestedRevision requestedTheme intent -> do
      ensureRevision requestedRevision authoring
      ensureThemeIdentity requestedTheme authoring
      next <- applyThemeControl intent authoring
      successWithWorkspace "theme_changed" next

-- | Encode one already-closed success envelope.
encodeLiveSuccessJSON :: LiveProductSuccess -> ByteString
encodeLiveSuccessJSON (LiveProductSuccess value) =
  LazyByteString.toStrict (encode value)

-- | Encode one stable, source-redacted error envelope.
encodeLiveErrorJSON :: ProductProtocolError -> ByteString
encodeLiveErrorJSON failure =
  LazyByteString.toStrict
    ( encode
        ( object
            [ "protocol" .= productProtocol
            , "ok" .= False
            , "kind" .= ("error" :: Text)
            , "error"
                .= object
                  [ "code" .= productErrorCode failure
                  , "message" .= productErrorMessage failure
                  ]
            ]
        )
    )

-- | Decode, execute, and encode one request without partial state mutation.
dispatchLiveRequestJSON
  :: LiveAuthoring
  -> ByteString
  -> (LiveAuthoring, ByteString)
dispatchLiveRequestJSON authoring requestBytes =
  case decodeLiveRequestJSON requestBytes of
    Left failure ->
      (authoring, encodeLiveErrorJSON failure)
    Right request ->
      case runLiveRequest authoring request of
        Left failure ->
          (authoring, encodeLiveErrorJSON failure)
        Right (next, success) ->
          (next, encodeLiveSuccessJSON success)

decodeRequestValue
  :: Value
  -> Either ProductProtocolError LiveProductRequest
decodeRequestValue value = do
  envelope <- expectObject "request" value
  protocol <- requiredText "request.protocol" "protocol" envelope
  if protocol == productProtocol
    then Right ()
    else Left (ProductUnsupportedProtocol protocol)
  command <- requiredText "request.command" "command" envelope
  case command of
    "initialize_catalog" -> do
      requireFields
        "request"
        ["protocol", "command", "catalogJson"]
        []
        envelope
      InitializeCatalog
        <$> requiredText "request.catalogJson" "catalogJson" envelope
    "workspace_snapshot" -> do
      requireFields "request" ["protocol", "command"] [] envelope
      Right WorkspaceSnapshot
    "search_catalog" -> do
      requireFields
        "request"
        ["protocol", "command", "query", "limit"]
        ["family"]
        envelope
      query <- requiredText "request.query" "query" envelope
      resultLimit <-
        requiredBoundedInt "request.limit" "limit" envelope
      if resultLimit < 1 || resultLimit > 300
        then
          Left
            (ProductInvalidField "request.limit must be between 1 and 300")
        else do
          family <- optionalCatalogFamily envelope
          Right (SearchCatalog query family resultLimit)
    "insert_shape" -> do
      requireFields
        "request"
        ["protocol", "command", "revision", "shapeId", "point"]
        []
        envelope
      InsertShape
        <$> requiredRevision envelope
        <*> requiredShapeId envelope
        <*> requiredPoint "request.point" "point" envelope
    "select_node" -> do
      requireFields
        "request"
        ["protocol", "command"]
        ["nodeId"]
        envelope
      SelectNode <$> optionalNullableNodeId envelope
    "move_node" -> do
      requireFields
        "request"
        ["protocol", "command", "revision", "nodeId", "point", "mode"]
        []
        envelope
      MoveNode
        <$> requiredRevision envelope
        <*> requiredNodeId envelope
        <*> requiredPoint "request.point" "point" envelope
        <*> requiredDragMode envelope
    "set_palette_colour" -> do
      requireFields
        "request"
        ["protocol", "command", "revision", "key", "colour"]
        []
        envelope
      SetPaletteColour
        <$> requiredRevision envelope
        <*> requiredWireIdentifier "request.key" "key" envelope
        <*> requiredColour "request.colour" "colour" envelope
    "set_theme_name" -> do
      requireFields
        "request"
        ["protocol", "command", "revision", "name"]
        []
        envelope
      SetThemeName
        <$> requiredRevision envelope
        <*> requiredText "request.name" "name" envelope
    "set_node_distance" -> do
      requireFields
        "request"
        ["protocol", "command", "revision", "distance"]
        []
        envelope
      SetNodeDistance
        <$> requiredRevision envelope
        <*> requiredCanvasUnit "request.distance" "distance" envelope
    "undo" -> do
      requireFields
        "request"
        ["protocol", "command", "revision"]
        []
        envelope
      UndoLive <$> requiredRevision envelope
    "redo" -> do
      requireFields
        "request"
        ["protocol", "command", "revision"]
        []
        envelope
      RedoLive <$> requiredRevision envelope
    "theme_intent" -> do
      requireFields
        "request"
        ["protocol", "command", "intent"]
        []
        envelope
      intentValue <- requiredValue "request.intent" "intent" envelope
      decodeThemeIntent intentValue
    _ -> Left (ProductUnknownCommand command)

decodeThemeIntent
  :: Value
  -> Either ProductProtocolError LiveProductRequest
decodeThemeIntent value = do
  intent <- expectObject "request.intent" value
  requireFields
    "request.intent"
    ["protocol", "projectionRevision", "themeId", "phase", "edit"]
    []
    intent
  protocol <-
    requiredText "request.intent.protocol" "protocol" intent
  if protocol == themeEditorProtocol
    then Right ()
    else Left (ProductUnsupportedProtocol protocol)
  revision <-
    requiredSafeRevision
      "request.intent.projectionRevision"
      "projectionRevision"
      intent
  themeIdentity <-
    requiredWireIdentifier
      "request.intent.themeId"
      "themeId"
      intent
  phase <- requiredText "request.intent.phase" "phase" intent
  case phase of
    "preview" -> Left ProductThemePreviewUnsupported
    "save" -> Left ProductThemeSaveUnavailable
    "apply" -> do
      edit <- requiredValue "request.intent.edit" "edit" intent
      control <- decodeThemeEdit edit
      Right (ApplyThemeControl revision themeIdentity control)
    _ ->
      Left
        (ProductInvalidField "request.intent.phase is not a known phase")

decodeThemeEdit
  :: Value
  -> Either ProductProtocolError ThemeControlIntent
decodeThemeEdit value = do
  edit <- expectObject "request.intent.edit" value
  kind <- requiredText "request.intent.edit.kind" "kind" edit
  case kind of
    "save_theme" -> Left ProductThemeSaveUnavailable
    "invoke_action" -> Left ProductThemeActionUnsupported
    "set_control" -> do
      requireFields
        "request.intent.edit"
        ["kind", "controlId", "target", "state"]
        []
        edit
      controlIdentity <-
        requiredWireIdentifier
          "request.intent.edit.controlId"
          "controlId"
          edit
      target <-
        requiredValue "request.intent.edit.target" "target" edit
      state <-
        requiredValue "request.intent.edit.state" "state" edit
      decodeThemeControl controlIdentity target state
    _ ->
      Left
        (ProductInvalidField "request.intent.edit.kind is not known")

decodeThemeControl
  :: Text
  -> Value
  -> Value
  -> Either ProductProtocolError ThemeControlIntent
decodeThemeControl controlIdentity targetValue stateValue = do
  state <- expectObject "request.intent.edit.state" stateValue
  stateKind <-
    requiredText "request.intent.edit.state.kind" "kind" state
  case stateKind of
    "unset" -> Left ProductThemeUnsetUnsupported
    "set" -> do
      requireFields
        "request.intent.edit.state"
        ["kind", "value"]
        []
        state
      target <- expectObject "request.intent.edit.target" targetValue
      targetKind <-
        requiredText "request.intent.edit.target.kind" "kind" target
      decoded <-
        case targetKind of
          "theme_metadata" ->
            decodeThemeMetadataControl target state
          "palette_colour" ->
            decodePaletteControl target state
          "node_distance" ->
            decodeNodeDistanceControl target state
          _ -> Left (ProductThemeTargetUnsupported targetKind)
      ensureControlIdentity controlIdentity decoded
      Right decoded
    _ ->
      Left
        (ProductInvalidField "request.intent.edit.state.kind is not known")

decodeThemeMetadataControl
  :: Object
  -> Object
  -> Either ProductProtocolError ThemeControlIntent
decodeThemeMetadataControl target state = do
  requireFields
    "request.intent.edit.target"
    ["kind", "property"]
    []
    target
  property <-
    requiredText "request.intent.edit.target.property" "property" target
  case property of
    "name" ->
      SetThemeNameControl
        <$> requiredText "request.intent.edit.state.value" "value" state
    _ -> Left (ProductThemeTargetUnsupported ("theme_metadata/" <> property))

decodePaletteControl
  :: Object
  -> Object
  -> Either ProductProtocolError ThemeControlIntent
decodePaletteControl target state = do
  requireFields
    "request.intent.edit.target"
    ["kind", "name"]
    []
    target
  key <-
    requiredWireIdentifier
      "request.intent.edit.target.name"
      "name"
      target
  colour <-
    requiredColour "request.intent.edit.state.value" "value" state
  Right (SetPaletteColourControl key colour)

decodeNodeDistanceControl
  :: Object
  -> Object
  -> Either ProductProtocolError ThemeControlIntent
decodeNodeDistanceControl target state = do
  requireFields
    "request.intent.edit.target"
    ["kind"]
    []
    target
  SetNodeDistanceControl
    <$> requiredCanvasUnit "request.intent.edit.state.value" "value" state

ensureControlIdentity
  :: Text
  -> ThemeControlIntent
  -> Either ProductProtocolError ()
ensureControlIdentity actual intent
  | actual == expected = Right ()
  | otherwise =
      Left
        ( ProductInvalidField
            "request.intent.edit.controlId does not match its target"
        )
  where
    expected =
      case intent of
        SetThemeNameControl {} -> "theme_name"
        SetPaletteColourControl key _ ->
          "palette_" <> key <> "_colour"
        SetNodeDistanceControl {} -> "node_distance"

applyThemeControl
  :: ThemeControlIntent
  -> LiveAuthoring
  -> Either ProductProtocolError LiveAuthoring
applyThemeControl intent authoring =
  case intent of
    SetThemeNameControl name ->
      mapLive
        ( setLiveThemeName
            (liveAuthoringRevision authoring)
            name
            authoring
        )
    SetPaletteColourControl key colour -> do
      if paletteControlExists key authoring
        then
          mapLive
            ( setLivePaletteColour
                (liveAuthoringRevision authoring)
                key
                colour
                authoring
            )
        else Left (ProductPaletteControlMissing key)
    SetNodeDistanceControl distance ->
      mapLive
        ( setLiveNodeDistance
            (liveAuthoringRevision authoring)
            distance
            authoring
        )

paletteControlExists :: Text -> LiveAuthoring -> Bool
paletteControlExists key authoring =
  any
    ((== key) . fst)
    ( paletteEntries
        (themePalette (themeStyle (liveAuthoringTheme authoring)))
    )

successWithWorkspace
  :: Text
  -> LiveAuthoring
  -> Either
      ProductProtocolError
      (LiveAuthoring, LiveProductSuccess)
successWithWorkspace kind authoring = do
  workspace <- workspaceValue authoring
  Right
    ( authoring
    , LiveProductSuccess
        (successValue kind ["workspace" .= workspace])
    )

successValue :: Text -> [Pair] -> Value
successValue kind fields =
  object
    ( [ "protocol" .= productProtocol
      , "ok" .= True
      , "kind" .= kind
      ]
        <> fields
    )

workspaceValue
  :: LiveAuthoring
  -> Either ProductProtocolError Value
workspaceValue authoring = do
  revision <- projectedRevision authoring
  nodes <- traverse (liveNodeValue authoring) (liveAuthoringNodes authoring)
  themeProjection <- themeValue (liveAuthoringTheme authoring)
  editorProjection <- themeEditorValue authoring
  Right
    ( object
        [ "revision" .= revision
        , "persistent" .= False
        , "persistenceReason"
            .= ("source_adapter_not_yet_verified" :: Text)
        , "canUndo" .= liveAuthoringCanUndo authoring
        , "canRedo" .= liveAuthoringCanRedo authoring
        , "selectedNodeId"
            .= fmap identifierText (liveAuthoringSelection authoring)
        , "theme" .= themeProjection
        , "themeEditor" .= editorProjection
        , "snapGuides" .= fmap snapGuideValue (liveAuthoringGuides authoring)
        , "nodes" .= nodes
        , "catalogFamilies"
            .= fmap catalogFamilyValue (liveCatalogFamilies authoring)
        ]
    )

catalogFamilyValue :: (CatalogFamily, Int) -> Value
catalogFamilyValue (family, count) =
  object
    [ "name" .= catalogFamilyText family
    , "count" .= count
    ]

themeValue :: Theme -> Either ProductProtocolError Value
themeValue theme = do
  colours <-
    traverse
      paletteEntryValue
      (paletteEntries (themePalette (themeStyle theme)))
  Right
    ( object
        [ "id" .= identifierText (themeIdentifier theme)
        , "name" .= themeName theme
        , "description" .= themeDescription theme
        , "palette" .= colours
        , "nodeDistance"
            .= approximateNumber
              (canvasUnitValue (themeNodeDistance (themeStyle theme)))
        ]
    )

paletteEntryValue
  :: (Text, Colour)
  -> Either ProductProtocolError Value
paletteEntryValue (key, colour)
  | isWireIdentifier key =
      Right
        ( object
            [ "name" .= key
            , "colour" .= colourText colour
            ]
        )
  | otherwise =
      Left
        ( ProductProjectionInvalid
            ("theme palette key is not a wire identifier: " <> key)
        )

themeEditorValue
  :: LiveAuthoring
  -> Either ProductProtocolError Value
themeEditorValue authoring = do
  revision <- projectedRevision authoring
  let theme = liveAuthoringTheme authoring
      style = themeStyle theme
  paletteGroups <-
    traverse
      paletteEditorGroup
      (paletteEntries (themePalette style))
  let empty = emptyEditorSection
      themeNameControl =
        editorControl
          "theme_name"
          "Theme name"
          (Just "The reusable display name for this structured theme.")
          "text"
          (String (themeName theme))
          ( object
              [ "kind" .= ("theme_metadata" :: Text)
              , "property" .= ("name" :: Text)
              ]
          )
      nodeDistanceControl =
        editorControl
          "node_distance"
          "Node distance"
          (Just "Default relative-placement distance in slide units.")
          "rational"
          (String (renderRational (canvasUnitValue (themeNodeDistance style))))
          (object ["kind" .= ("node_distance" :: Text)])
      paletteSection =
        object
          [ "controls" .= [themeNameControl]
          , "groups" .= paletteGroups
          , "actions" .= ([] :: [Value])
          ]
      distanceSection =
        object
          [ "controls" .= [nodeDistanceControl]
          , "groups" .= ([] :: [Value])
          , "actions" .= ([] :: [Value])
          ]
  Right
    ( object
        [ "protocol" .= themeEditorProtocol
        , "projectionRevision" .= revision
        , "theme"
            .= object
              [ "id" .= identifierText (themeIdentifier theme)
              , "name" .= themeName theme
              , "description" .= themeDescription theme
              ]
        , "sections"
            .= object
              [ "palette" .= paletteSection
              , "typographyRoles" .= empty
              , "background" .= empty
              , "baseShapeStyle" .= empty
              , "nodeDistance" .= distanceSection
              , "masterRegions" .= empty
              , "masterAnchors" .= empty
              , "furniture" .= empty
              ]
        , "save"
            .= object
              [ "enabled" .= False
              , "disabledReason"
                  .= ( "Theme save requires a verified source adapter; \
                       \source_adapter_not_yet_verified."
                         :: Text
                     )
              ]
        ]
    )

emptyEditorSection :: Value
emptyEditorSection =
  object
    [ "controls" .= ([] :: [Value])
    , "groups" .= ([] :: [Value])
    , "actions" .= ([] :: [Value])
    ]

paletteEditorGroup
  :: (Text, Colour)
  -> Either ProductProtocolError Value
paletteEditorGroup (key, colour)
  | isWireIdentifier key =
      Right
        ( object
            [ "id" .= ("palette_" <> key)
            , "label" .= key
            , "summary" .= (Nothing :: Maybe Text)
            , "controls"
                .= [ editorControl
                       ("palette_" <> key <> "_colour")
                       "Colour"
                       Nothing
                       "colour"
                       (String (colourText colour))
                       ( object
                           [ "kind" .= ("palette_colour" :: Text)
                           , "name" .= key
                           ]
                       )
                   ]
            , "actions" .= ([] :: [Value])
            ]
        )
  | otherwise =
      Left
        ( ProductProjectionInvalid
            ("theme palette key is not a wire identifier: " <> key)
        )

editorControl
  :: Text
  -> Text
  -> Maybe Text
  -> Text
  -> Value
  -> Value
  -> Value
editorControl identity label help kind value target =
  object
    [ "id" .= identity
    , "label" .= label
    , "help" .= help
    , "kind" .= kind
    , "value" .= value
    , "optional" .= False
    , "active" .= True
    , "editable" .= True
    , "disabledReason" .= (Nothing :: Maybe Text)
    , "options" .= Null
    , "target" .= target
    ]

liveNodeValue
  :: LiveAuthoring
  -> LiveNode
  -> Either ProductProtocolError Value
liveNodeValue authoring liveNode = do
  outlines <-
    mapLive
      (liveResolveNodeOutlines authoring liveNode)
  properties <-
    mapLive
      (liveNodeResolvedProperties authoring liveNode)
  style <-
    nodeStyleValue (liveAuthoringTheme authoring) properties
  let identity =
        identifierText
          (nodeIdentifier (liveNodeSemantic liveNode))
  Right
    ( object
        [ "id" .= identity
        , "label" .= identity
        , "box" .= boxValue (liveNodeBox liveNode)
        , "outlines" .= fmap outlineValue (NonEmpty.toList outlines)
        , "style" .= style
        ]
    )

shapePresetValue
  :: LiveAuthoring
  -> ShapePreset
  -> Either ProductProtocolError Value
shapePresetValue authoring preset = do
  outlines <-
    mapLive (liveResolvePresetOutlines authoring preset)
  Right
    ( object
        [ "id" .= shapeIdText (shapePresetIdentifier preset)
        , "label" .= shapePresetLabel preset
        , "category" .= shapePresetCategory preset
        , "family" .= catalogFamilyText (shapePresetFamily preset)
        , "priority" .= catalogPriorityText (shapePresetPriority preset)
        , "origin" .= catalogOriginValue (shapePresetOrigin preset)
        , "attribution"
            .= catalogAttributionValue (shapePresetOrigin preset)
        , "dropSize" .= sizeValue (shapePresetDropSize preset)
        , "outlines" .= fmap outlineValue (NonEmpty.toList outlines)
        ]
    )

catalogPriorityText :: CatalogPriority -> Text
catalogPriorityText priority =
  case priority of
    P0Catalog -> "p0"
    P1Catalog -> "p1"
    P2Catalog -> "p2"

catalogOriginValue :: CatalogOrigin -> Value
catalogOriginValue origin =
  case origin of
    CuratedCatalogOrigin ->
      object
        [ "kind" .= ("curated" :: Text)
        , "name" .= (Nothing :: Maybe Text)
        ]
    ImportedDrawIOOrigin {} ->
      object
        [ "kind" .= ("drawio" :: Text)
        , "name" .= (Nothing :: Maybe Text)
        ]
    UserCatalogOrigin name _ ->
      object
        [ "kind" .= ("user" :: Text)
        , "name" .= Just name
        ]
    ExtensionCatalogOrigin name _ ->
      object
        [ "kind" .= ("extension" :: Text)
        , "name" .= Just name
        ]

catalogAttributionValue :: CatalogOrigin -> Value
catalogAttributionValue origin =
  case origin of
    CuratedCatalogOrigin -> Null
    ImportedDrawIOOrigin attribution -> attributionValue attribution
    UserCatalogOrigin _ attribution ->
      maybe Null attributionValue attribution
    ExtensionCatalogOrigin _ attribution ->
      maybe Null attributionValue attribution

attributionValue :: ShapeAttribution -> Value
attributionValue attribution =
  object
    [ "title" .= attributionTitle attribution
    , "author" .= attributionAuthor attribution
    , "license" .= attributionLicense attribution
    , "source" .= attributionSource attribution
    ]

outlineValue :: RenderOutline -> Value
outlineValue outline =
  case renderOutlineView outline of
    RenderRectangleView resolvedBox radii ->
      object
        [ "kind" .= ("rectangle" :: Text)
        , "box" .= boxValue resolvedBox
        , "radii" .= cornerRadiiValue radii
        ]
    RenderEllipseView resolvedBox ->
      object
        [ "kind" .= ("ellipse" :: Text)
        , "box" .= boxValue resolvedBox
        ]
    RenderPolygonView points ->
      object
        [ "kind" .= ("polygon" :: Text)
        , "points" .= fmap pointValue (NonEmpty.toList points)
        ]
    RenderPathOutlineView fillRule paths ->
      object
        [ "kind" .= ("path" :: Text)
        , "fillRule" .= fillRuleText fillRule
        , "subpaths" .= fmap renderPathValue (NonEmpty.toList paths)
        ]

cornerRadiiValue :: RenderCornerRadii -> Value
cornerRadiiValue radii =
  case renderCornerRadiiView radii of
    RenderCornerRadiiView topLeft topRight bottomRight bottomLeft ->
      object
        [ "topLeft" .= canvasNumber topLeft
        , "topRight" .= canvasNumber topRight
        , "bottomRight" .= canvasNumber bottomRight
        , "bottomLeft" .= canvasNumber bottomLeft
        ]

fillRuleText :: RenderFillRule -> Text
fillRuleText fillRule =
  case fillRule of
    RenderNonZeroFill -> "nonzero"
    RenderEvenOddFill -> "evenodd"

renderPathValue :: RenderPath -> Value
renderPathValue path =
  object
    [ "start" .= pointValue (renderPathStart path)
    , "closed"
        .= case renderPathClosure path of
          RenderOpenPath -> False
          RenderClosedPath -> True
    , "segments"
        .= fmap
          renderPathSegmentValue
          (NonEmpty.toList (renderPathSegments path))
    ]

renderPathSegmentValue :: RenderPathSegment -> Value
renderPathSegmentValue segment =
  case segment of
    RenderLineTo endpoint ->
      object
        [ "kind" .= ("line" :: Text)
        , "end" .= pointValue endpoint
        ]
    RenderQuadraticTo control endpoint ->
      object
        [ "kind" .= ("quadratic" :: Text)
        , "control" .= pointValue control
        , "end" .= pointValue endpoint
        ]
    RenderCubicTo firstControl secondControl endpoint ->
      object
        [ "kind" .= ("cubic" :: Text)
        , "control1" .= pointValue firstControl
        , "control2" .= pointValue secondControl
        , "end" .= pointValue endpoint
        ]
    RenderArcTo radii rotation arcSize arcSweep endpoint ->
      object
        [ "kind" .= ("arc" :: Text)
        , "radii" .= arcRadiiValue radii
        , "rotation" .= approximateNumber rotation
        , "largeArc"
            .= case arcSize of
              RenderSmallArc -> False
              RenderLargeArc -> True
        , "sweep" .= arcSweepText arcSweep
        , "end" .= pointValue endpoint
        ]

arcRadiiValue :: RenderArcRadii -> Value
arcRadiiValue radii =
  object
    [ "x" .= canvasNumber (renderArcRadiusX radii)
    , "y" .= canvasNumber (renderArcRadiusY radii)
    ]

arcSweepText :: RenderArcSweep -> Text
arcSweepText arcSweep =
  case arcSweep of
    RenderCounterClockwiseArc -> "counter_clockwise"
    RenderClockwiseArc -> "clockwise"

nodeStyleValue
  :: Theme
  -> NodeProperties
  -> Either ProductProtocolError Value
nodeStyleValue theme properties = do
  paint <- paintValue theme (nodePaint properties)
  stroke <-
    strokeValue
      theme
      (nodeDash properties)
      (nodeStroke properties)
  shadow <- shadowValue theme (nodeShadow properties)
  Right
    ( object
        [ "paint" .= paint
        , "stroke" .= stroke
        , "opacity"
            .= approximateNumber (opacityValue (nodeOpacity properties))
        , "transform"
            .= object
              [ "rotation"
                  .= approximateNumber
                    (rotationDegrees (nodeRotation properties))
              , "scale"
                  .= scaleValue (nodeScale properties)
              , "flip" .= flipText (nodeFlip properties)
              ]
        , "shadow" .= shadow
        , "cornerTreatment"
            .= cornerTreatmentValue (nodeCornerTreatment properties)
        ]
    )

paintValue
  :: Theme
  -> Paint
  -> Either ProductProtocolError Value
paintValue theme paintValue' =
  case paintValue' of
    NoPaint ->
      Right (object ["kind" .= ("none" :: Text)])
    SolidPaint colourReference -> do
      colour <- resolveColour theme colourReference
      Right
        ( object
            [ "kind" .= ("solid" :: Text)
            , "colour" .= colourText colour
            ]
        )
    GradientPaint gradient ->
      gradientValue theme gradient

gradientValue
  :: Theme
  -> Gradient
  -> Either ProductProtocolError Value
gradientValue theme gradient =
  case gradient of
    LinearGradient rotation stops -> do
      directStops <-
        traverse (gradientStopValue theme) (NonEmpty.toList stops)
      Right
        ( object
            [ "kind" .= ("linear_gradient" :: Text)
            , "rotation"
                .= approximateNumber (rotationDegrees rotation)
            , "stops" .= directStops
            ]
        )
    RadialGradient centre radius stops -> do
      directStops <-
        traverse (gradientStopValue theme) (NonEmpty.toList stops)
      Right
        ( object
            [ "kind" .= ("radial_gradient" :: Text)
            , "centre" .= pointValue centre
            , "radius" .= canvasNumber radius
            , "stops" .= directStops
            ]
        )

gradientStopValue
  :: Theme
  -> GradientStop
  -> Either ProductProtocolError Value
gradientStopValue theme stop = do
  colour <- resolveColour theme (gradientStopColour stop)
  Right
    ( object
        [ "offset"
            .= approximateNumber
              (opacityValue (gradientStopOffset stop))
        , "colour" .= colourText colour
        ]
    )

strokeValue
  :: Theme
  -> DashPattern
  -> Stroke
  -> Either ProductProtocolError Value
strokeValue theme dash stroke =
  case stroke of
    NoStroke ->
      Right (object ["kind" .= ("none" :: Text)])
    SolidStroke colourReference width -> do
      colour <- resolveColour theme colourReference
      Right
        ( object
            [ "kind" .= ("solid" :: Text)
            , "colour" .= colourText colour
            , "width" .= canvasNumber width
            , "dash" .= dashValue dash
            ]
        )

dashValue :: DashPattern -> Value
dashValue dash =
  case dash of
    SolidDash ->
      object
        [ "kind" .= ("solid" :: Text)
        , "values" .= ([] :: [Double])
        ]
    Dashed ->
      object
        [ "kind" .= ("dashed" :: Text)
        , "values" .= ([] :: [Double])
        ]
    Dotted ->
      object
        [ "kind" .= ("dotted" :: Text)
        , "values" .= ([] :: [Double])
        ]
    CustomDash intervals ->
      object
        [ "kind" .= ("custom" :: Text)
        , "values"
            .= fmap canvasNumber (NonEmpty.toList intervals)
        ]

shadowValue
  :: Theme
  -> Shadow
  -> Either ProductProtocolError Value
shadowValue theme shadow =
  case shadow of
    NoShadow ->
      Right (object ["kind" .= ("none" :: Text)])
    DropShadow offset blur colourReference opacity -> do
      colour <- resolveColour theme colourReference
      Right
        ( object
            [ "kind" .= ("drop" :: Text)
            , "offset" .= vectorValue offset
            , "blur" .= canvasNumber blur
            , "colour" .= colourText colour
            , "opacity"
                .= approximateNumber (opacityValue opacity)
            ]
        )

cornerTreatmentValue :: CornerTreatment -> Value
cornerTreatmentValue treatment =
  case treatment of
    SharpCorners ->
      object
        [ "kind" .= ("sharp" :: Text)
        , "amount" .= (0 :: Double)
        ]
    RoundedCorners amount ->
      object
        [ "kind" .= ("rounded" :: Text)
        , "amount" .= canvasNumber amount
        ]
    ChamferedCorners amount ->
      object
        [ "kind" .= ("chamfered" :: Text)
        , "amount" .= canvasNumber amount
        ]

scaleValue :: Scale -> Value
scaleValue scale =
  object
    [ "x" .= approximateNumber (scaleX scale)
    , "y" .= approximateNumber (scaleY scale)
    ]

flipText :: Flip -> Text
flipText flipValue =
  case flipValue of
    NoFlip -> "none"
    FlipHorizontal -> "horizontal"
    FlipVertical -> "vertical"
    FlipBoth -> "both"

resolveColour
  :: Theme
  -> ColourRef
  -> Either ProductProtocolError Colour
resolveColour theme reference =
  case reference of
    DirectColour colour -> Right colour
    PaletteColour key ->
      case
          lookup
            key
            (paletteEntries (themePalette (themeStyle theme)))
        of
          Nothing -> Left (ProductProjectionPaletteMissing key)
          Just colour -> Right colour

snapGuideValue :: SnapGuide -> Value
snapGuideValue guide =
  object
    [ "kind" .= guideKindText (guideKind guide)
    , "start" .= pointValue (guideStart guide)
    , "end" .= pointValue (guideEnd guide)
    ]

guideKindText :: GuideKind -> Text
guideKindText kind =
  case kind of
    PointGuide -> "point"
    AlignmentGuide -> "alignment"
    SpacingGuide -> "spacing"
    BindingGuide -> "binding"

boxValue :: Box -> Value
boxValue resolvedBox =
  object
    [ "center" .= pointValue (boxCenter resolvedBox)
    , "size" .= sizeValue (boxSize resolvedBox)
    , "left" .= canvasNumber (boxLeft resolvedBox)
    , "right" .= canvasNumber (boxRight resolvedBox)
    , "bottom" .= canvasNumber (boxBottom resolvedBox)
    , "top" .= canvasNumber (boxTop resolvedBox)
    ]

sizeValue :: Size -> Value
sizeValue resolvedSize =
  object
    [ "width" .= canvasNumber (sizeWidth resolvedSize)
    , "height" .= canvasNumber (sizeHeight resolvedSize)
    ]

pointValue :: Point -> Value
pointValue position =
  object
    [ "x" .= canvasNumber (pointX position)
    , "y" .= canvasNumber (pointY position)
    ]

vectorValue :: Vector -> Value
vectorValue offset =
  object
    [ "x" .= canvasNumber (vectorX offset)
    , "y" .= canvasNumber (vectorY offset)
    ]

canvasNumber :: CanvasUnit -> Double
canvasNumber = approximateNumber . canvasUnitValue

approximateNumber :: Rational -> Double
approximateNumber = fromRational

ensureRevision
  :: Word64
  -> LiveAuthoring
  -> Either ProductProtocolError ()
ensureRevision requested authoring
  | requested == actual = Right ()
  | otherwise = Left (ProductStaleRevision requested actual)
  where
    actual =
      liveRevisionToWord64 (liveAuthoringRevision authoring)

ensureThemeIdentity
  :: Text
  -> LiveAuthoring
  -> Either ProductProtocolError ()
ensureThemeIdentity requested authoring
  | requested == actual = Right ()
  | otherwise =
      Left (ProductThemeIdentityMismatch requested actual)
  where
    actual =
      identifierText
        (themeIdentifier (liveAuthoringTheme authoring))

optionalCatalogFamily
  :: Object
  -> Either ProductProtocolError (Maybe CatalogFamily)
optionalCatalogFamily envelope =
  case KeyMap.lookup "family" envelope of
    Nothing -> Right Nothing
    Just Null -> Right Nothing
    Just (String rawFamily) ->
      case catalogFamily rawFamily of
        Nothing ->
          Left (ProductInvalidField "request.family is invalid")
        Just family -> Right (Just family)
    Just _ ->
      Left
        (ProductInvalidField "request.family must be a string or null")

requiredRevision
  :: Object
  -> Either ProductProtocolError Word64
requiredRevision =
  requiredSafeRevision "request.revision" "revision"

requiredSafeRevision
  :: Text
  -> Text
  -> Object
  -> Either ProductProtocolError Word64
requiredSafeRevision location key value = do
  revision <- requiredWord64 location key value
  if revision <= maximumJavaScriptInteger
    then Right revision
    else
      Left
        ( ProductInvalidField
            (location <> " exceeds the browser safe-integer range")
        )

maximumJavaScriptInteger :: Word64
maximumJavaScriptInteger = 9007199254740991

requiredShapeId
  :: Object
  -> Either ProductProtocolError ShapeId
requiredShapeId envelope = do
  rawIdentity <-
    requiredText "request.shapeId" "shapeId" envelope
  case shapeId rawIdentity of
    Nothing -> Left (ProductInvalidField "request.shapeId is invalid")
    Just identity -> Right identity

requiredNodeId
  :: Object
  -> Either ProductProtocolError NodeId
requiredNodeId envelope = do
  rawIdentity <-
    requiredText "request.nodeId" "nodeId" envelope
  case nodeId rawIdentity of
    Nothing -> Left (ProductInvalidField "request.nodeId is invalid")
    Just identity -> Right identity

optionalNullableNodeId
  :: Object
  -> Either ProductProtocolError (Maybe NodeId)
optionalNullableNodeId envelope =
  case KeyMap.lookup "nodeId" envelope of
    Nothing -> Right Nothing
    Just Null -> Right Nothing
    Just (String rawIdentity) ->
      case nodeId rawIdentity of
        Nothing -> Left (ProductInvalidField "request.nodeId is invalid")
        Just identity -> Right (Just identity)
    Just _ ->
      Left
        (ProductInvalidField "request.nodeId must be a string or null")

projectedRevision
  :: LiveAuthoring
  -> Either ProductProtocolError Word64
projectedRevision authoring
  | revision <= maximumJavaScriptInteger = Right revision
  | otherwise =
      Left
        ( ProductProjectionInvalid
            "live revision exceeds the browser safe-integer range"
        )
  where
    revision =
      liveRevisionToWord64 (liveAuthoringRevision authoring)

requiredPoint
  :: Text
  -> Text
  -> Object
  -> Either ProductProtocolError Point
requiredPoint location key envelope = do
  value <- requiredValue location key envelope
  coordinates <- expectObject location value
  requireFields location ["x", "y"] [] coordinates
  x <- requiredCanvasUnit (location <> ".x") "x" coordinates
  y <- requiredCanvasUnit (location <> ".y") "y" coordinates
  Right (point x y)

requiredDragMode
  :: Object
  -> Either ProductProtocolError DragMode
requiredDragMode envelope = do
  mode <- requiredText "request.mode" "mode" envelope
  case mode of
    "snap" -> Right SnappingDrag
    "free" -> Right FreeDrag
    _ ->
      Left
        (ProductInvalidField "request.mode must be snap or free")

requiredColour
  :: Text
  -> Text
  -> Object
  -> Either ProductProtocolError Colour
requiredColour location key envelope = do
  rawColour <- requiredText location key envelope
  case parseColour rawColour of
    Nothing ->
      Left
        ( ProductInvalidField
            (location <> " must be #RRGGBB or #RRGGBBAA")
        )
    Just colour -> Right colour

requiredCanvasUnit
  :: Text
  -> Text
  -> Object
  -> Either ProductProtocolError CanvasUnit
requiredCanvasUnit location key envelope = do
  rawValue <- requiredText location key envelope
  case parseExactRational rawValue of
    Nothing ->
      Left
        ( ProductInvalidField
            (location <> " must be an integer, decimal, or exact fraction")
        )
    Just value -> Right (canvasUnit value)

requiredWireIdentifier
  :: Text
  -> Text
  -> Object
  -> Either ProductProtocolError Text
requiredWireIdentifier location key envelope = do
  value <- requiredText location key envelope
  if isWireIdentifier value
    then Right value
    else
      Left
        (ProductInvalidField (location <> " is not a valid identifier"))

isWireIdentifier :: Text -> Bool
isWireIdentifier value =
  case Text.uncons value of
    Nothing -> False
    Just (firstCharacter, remaining) ->
      isIdentifierInitial firstCharacter
        && Text.all isIdentifierContinuation remaining

isIdentifierInitial :: Char -> Bool
isIdentifierInitial character =
  (character >= 'a' && character <= 'z')
    || (character >= 'A' && character <= 'Z')
    || character == '_'

isIdentifierContinuation :: Char -> Bool
isIdentifierContinuation character =
  isIdentifierInitial character
    || (character >= '0' && character <= '9')
    || character == '-'

parseColour :: Text -> Maybe Colour
parseColour value =
  case Text.unpack value of
    ['#', r1, r2, g1, g2, b1, b2] ->
      RGB
        <$> hexPair r1 r2
        <*> hexPair g1 g2
        <*> hexPair b1 b2
    ['#', r1, r2, g1, g2, b1, b2, a1, a2] ->
      RGBA
        <$> hexPair r1 r2
        <*> hexPair g1 g2
        <*> hexPair b1 b2
        <*> hexPair a1 a2
    _ -> Nothing

hexPair :: Char -> Char -> Maybe Word8
hexPair high low = do
  highValue <- hexValue high
  lowValue <- hexValue low
  Just (highValue * 16 + lowValue)

hexValue :: Char -> Maybe Word8
hexValue character
  | character >= '0' && character <= '9' =
      Just (fromIntegral (ord character - ord '0'))
  | character >= 'a' && character <= 'f' =
      Just (fromIntegral (10 + ord character - ord 'a'))
  | character >= 'A' && character <= 'F' =
      Just (fromIntegral (10 + ord character - ord 'A'))
  | otherwise = Nothing

colourText :: Colour -> Text
colourText colour =
  case colour of
    RGB red green blue ->
      "#" <> byteHex red <> byteHex green <> byteHex blue
    RGBA red green blue alpha ->
      "#"
        <> byteHex red
        <> byteHex green
        <> byteHex blue
        <> byteHex alpha

byteHex :: Word8 -> Text
byteHex value =
  Text.pack
    [ hexDigit (value `div` 16)
    , hexDigit (value `mod` 16)
    ]

hexDigit :: Word8 -> Char
hexDigit value =
  case value of
    0 -> '0'
    1 -> '1'
    2 -> '2'
    3 -> '3'
    4 -> '4'
    5 -> '5'
    6 -> '6'
    7 -> '7'
    8 -> '8'
    9 -> '9'
    10 -> 'A'
    11 -> 'B'
    12 -> 'C'
    13 -> 'D'
    14 -> 'E'
    _ -> 'F'

parseExactRational :: Text -> Maybe Rational
parseExactRational rawValue
  | Text.length rawValue > 128 = Nothing
  | otherwise = do
      let (sign, unsigned) =
            case Text.stripPrefix "-" rawValue of
              Nothing -> (1, rawValue)
              Just remaining -> (-1, remaining)
      if Text.null unsigned
        then Nothing
        else do
          magnitude <- parseUnsignedRational unsigned
          Just (sign * magnitude)

parseUnsignedRational :: Text -> Maybe Rational
parseUnsignedRational value =
  case Text.splitOn "/" value of
    [numeratorText, denominatorText] -> do
      numeratorValue <- parseCanonicalInteger numeratorText
      denominatorValue <- parsePositiveDenominator denominatorText
      Just (numeratorValue % denominatorValue)
    [decimalText] -> parseDecimal decimalText
    _ -> Nothing

parseDecimal :: Text -> Maybe Rational
parseDecimal value =
  case Text.splitOn "." value of
    [integerText] ->
      fromInteger <$> parseCanonicalInteger integerText
    [integerText, fractionalText] -> do
      integerValue <- parseCanonicalInteger integerText
      fractionalValue <- parseDigits fractionalText
      if Text.null fractionalText
        then Nothing
        else
          let denominatorValue =
                10 ^ Text.length fractionalText
           in Just
                ( ( integerValue * denominatorValue
                      + fractionalValue
                  )
                    % denominatorValue
                )
    _ -> Nothing

parseCanonicalInteger :: Text -> Maybe Integer
parseCanonicalInteger value
  | Text.null value = Nothing
  | Text.length value > 1
      && Text.isPrefixOf "0" value =
      Nothing
  | otherwise = parseDigits value

parsePositiveDenominator :: Text -> Maybe Integer
parsePositiveDenominator value = do
  parsed <- parseCanonicalInteger value
  if parsed > 0 then Just parsed else Nothing

parseDigits :: Text -> Maybe Integer
parseDigits value
  | Text.null value = Nothing
  | Text.all isAsciiDigit value =
      Just (Text.foldl' appendDigit 0 value)
  | otherwise = Nothing
  where
    appendDigit accumulated character =
      accumulated * 10
        + toInteger (ord character - ord '0')

isAsciiDigit :: Char -> Bool
isAsciiDigit character =
  character >= '0' && character <= '9'

renderRational :: Rational -> Text
renderRational value
  | denominator value == 1 =
      Text.pack (show (numerator value))
  | otherwise =
      Text.pack (show (numerator value))
        <> "/"
        <> Text.pack (show (denominator value))

expectObject
  :: Text
  -> Value
  -> Either ProductProtocolError Object
expectObject _ (Object value) = Right value
expectObject location _ =
  Left (ProductInvalidField (location <> " must be an object"))

requiredValue
  :: Text
  -> Text
  -> Object
  -> Either ProductProtocolError Value
requiredValue location key value =
  case KeyMap.lookup (Key.fromText key) value of
    Nothing -> Left (ProductInvalidField (location <> " is required"))
    Just present -> Right present

requiredText
  :: Text
  -> Text
  -> Object
  -> Either ProductProtocolError Text
requiredText location key value = do
  present <- requiredValue location key value
  case present of
    String text -> Right text
    _ -> Left (ProductInvalidField (location <> " must be a string"))

requiredWord64
  :: Text
  -> Text
  -> Object
  -> Either ProductProtocolError Word64
requiredWord64 location key value = do
  present <- requiredValue location key value
  case present of
    Number _ ->
      case fromJSON present :: Result Word64 of
        Error _ ->
          Left
            ( ProductInvalidField
                (location <> " must be a non-negative integer")
            )
        Success parsed -> Right parsed
    _ ->
      Left
        (ProductInvalidField (location <> " must be a number"))

requiredBoundedInt
  :: Text
  -> Text
  -> Object
  -> Either ProductProtocolError Int
requiredBoundedInt location key value = do
  present <- requiredValue location key value
  case present of
    Number _ ->
      case fromJSON present :: Result Int of
        Error _ ->
          Left
            (ProductInvalidField (location <> " must be an integer"))
        Success parsed -> Right parsed
    _ ->
      Left
        (ProductInvalidField (location <> " must be a number"))

requireFields
  :: Text
  -> [Text]
  -> [Text]
  -> Object
  -> Either ProductProtocolError ()
requireFields location required optional value =
  case missing of
    firstMissing : _ ->
      Left
        ( ProductInvalidField
            (location <> "." <> firstMissing <> " is required")
        )
    [] ->
      case unexpected of
        firstUnexpected : _ ->
          Left
            ( ProductInvalidField
                ( location
                    <> "."
                    <> firstUnexpected
                    <> " is not allowed"
                )
            )
        [] -> Right ()
  where
    actual = fmap Key.toText (KeyMap.keys value)
    allowed = required <> optional
    missing = filter (`notElem` actual) required
    unexpected = filter (`notElem` allowed) actual

productErrorCode :: ProductProtocolError -> Text
productErrorCode failure =
  case failure of
    ProductMalformedJSON {} -> "malformed_json"
    ProductUnsupportedProtocol {} -> "unsupported_protocol"
    ProductUnknownCommand {} -> "unknown_command"
    ProductInvalidField {} -> "invalid_field"
    ProductStaleRevision {} -> "stale_revision"
    ProductThemeIdentityMismatch {} -> "theme_identity_mismatch"
    ProductThemePreviewUnsupported -> "theme_preview_not_supported"
    ProductThemeSaveUnavailable -> "theme_save_unavailable"
    ProductThemeUnsetUnsupported -> "theme_unset_not_supported"
    ProductThemeActionUnsupported -> "theme_action_not_supported"
    ProductThemeTargetUnsupported {} -> "theme_target_not_supported"
    ProductPaletteControlMissing {} -> "palette_control_missing"
    ProductProjectionPaletteMissing {} -> "palette_reference_missing"
    ProductProjectionInvalid {} -> "projection_invalid"
    ProductLiveFailure liveFailure ->
      liveErrorCode liveFailure

productErrorMessage :: ProductProtocolError -> Text
productErrorMessage failure =
  case failure of
    ProductMalformedJSON message ->
      "Malformed JSON: " <> oneLine message
    ProductUnsupportedProtocol protocol ->
      "Unsupported protocol: " <> oneLine protocol
    ProductUnknownCommand command ->
      "Unknown command: " <> oneLine command
    ProductInvalidField message -> oneLine message
    ProductStaleRevision requested actual ->
      "Stale revision "
        <> decimal requested
        <> "; current revision is "
        <> decimal actual
    ProductThemeIdentityMismatch requested actual ->
      "Theme "
        <> oneLine requested
        <> " does not match current theme "
        <> oneLine actual
    ProductThemePreviewUnsupported ->
      "Theme previews are not committed by this live protocol."
    ProductThemeSaveUnavailable ->
      "Theme save requires a verified source adapter."
    ProductThemeUnsetUnsupported ->
      "Unsetting this theme control is not supported."
    ProductThemeActionUnsupported ->
      "Theme collection actions are not supported by this slice."
    ProductThemeTargetUnsupported target ->
      "Unsupported theme target: " <> oneLine target
    ProductPaletteControlMissing key ->
      "The projected palette control no longer exists: " <> oneLine key
    ProductProjectionPaletteMissing key ->
      "A resolved style references a missing palette colour: " <> oneLine key
    ProductProjectionInvalid message ->
      "The current semantic state cannot be projected: " <> oneLine message
    ProductLiveFailure liveFailure ->
      liveErrorMessage liveFailure

liveErrorCode :: LiveAuthoringError -> Text
liveErrorCode failure =
  case failure of
    LiveCuratedCatalogInvalid {} -> "curated_catalog_invalid"
    LiveDrawIOCatalogInvalid {} -> "catalog_invalid"
    LiveCatalogMergeInvalid {} -> "catalog_merge_invalid"
    LiveStencilLibraryInvalid {} -> "stencil_library_invalid"
    LiveStaleRevision {} -> "stale_revision"
    LiveRevisionExhausted -> "revision_exhausted"
    LiveShapeMissing {} -> "shape_missing"
    LiveNodeIdentityExhausted -> "node_identity_exhausted"
    LiveNodeMissing {} -> "node_missing"
    LiveNodePropertiesInvalid {} -> "node_properties_invalid"
    LiveSlideGeometryInvalid {} -> "slide_geometry_invalid"
    LiveSnapConfigurationInvalid {} -> "snap_configuration_invalid"
    LiveBindingConfigurationInvalid {} -> "binding_configuration_invalid"
    LiveOutlineInvalid {} -> "outline_invalid"
    LivePaletteKeyInvalid {} -> "palette_key_invalid"
    LiveThemeNameInvalid -> "theme_name_invalid"
    LiveNodeDistanceNegative {} -> "node_distance_negative"
    LiveUndoBoundary -> "undo_boundary"
    LiveRedoBoundary -> "redo_boundary"

liveErrorMessage :: LiveAuthoringError -> Text
liveErrorMessage failure =
  case failure of
    LiveCuratedCatalogInvalid {} -> "The curated shape catalog is invalid."
    LiveDrawIOCatalogInvalid {} -> "The imported shape catalog is invalid."
    LiveCatalogMergeInvalid {} -> "The shape catalogs cannot be merged."
    LiveStencilLibraryInvalid {} -> "The stencil library is invalid."
    LiveStaleRevision expected actual ->
      "Stale revision "
        <> decimal (liveRevisionToWord64 expected)
        <> "; current revision is "
        <> decimal (liveRevisionToWord64 actual)
    LiveRevisionExhausted -> "The live revision counter is exhausted."
    LiveShapeMissing identity ->
      "Shape is not present in the catalog: " <> shapeIdText identity
    LiveNodeIdentityExhausted -> "The node identity counter is exhausted."
    LiveNodeMissing identity ->
      "Node is not present: " <> identifierText identity
    LiveNodePropertiesInvalid {} ->
      "The node properties cannot be resolved."
    LiveSlideGeometryInvalid {} -> "The slide geometry is invalid."
    LiveSnapConfigurationInvalid {} ->
      "The snapping configuration is invalid."
    LiveBindingConfigurationInvalid {} ->
      "The relative-binding configuration is invalid."
    LiveOutlineInvalid {} -> "The outline cannot be lowered to direct geometry."
    LivePaletteKeyInvalid key -> "Palette key is invalid: " <> oneLine key
    LiveThemeNameInvalid -> "Theme name must be non-empty printable text."
    LiveNodeDistanceNegative {} -> "Node distance cannot be negative."
    LiveUndoBoundary -> "There is no live edit to undo."
    LiveRedoBoundary -> "There is no live edit to redo."

decimal :: Show value => value -> Text
decimal = Text.pack . show

oneLine :: Text -> Text
oneLine = Text.map replaceNewline
  where
    replaceNewline character
      | character == '\n' || character == '\r' = ' '
      | otherwise = character

mapLive
  :: Either LiveAuthoringError value
  -> Either ProductProtocolError value
mapLive = mapLeft ProductLiveFailure

mapLeft
  :: (failure -> mapped)
  -> Either failure value
  -> Either mapped value
mapLeft transform result =
  case result of
    Left failure -> Left (transform failure)
    Right value -> Right value
