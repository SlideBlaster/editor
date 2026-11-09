-- |
-- Module      : SlideBlaster.App.Command
-- Description : Closed product commands and pure availability policy.
--
-- Commands describe user meaning. Browser buttons, menus, keyboard shortcuts,
-- and the native composition must ask the same availability function instead
-- of independently rediscovering policy.
module SlideBlaster.App.Command
  ( AppCommand (..)
  , ProjectCommand (..)
  , HistoryCommand (..)
  , DeckCommand (..)
  , ReorderFrameDirection (..)
  , SourceCommand (..)
  , CanvasCommand (..)
  , PropertyCommand (..)
  , ThemeCommand (..)
  , ViewCommand (..)
  , PresenterCommand (..)
  , ExportCommand (..)
  , SemanticReadiness (..)
  , LeaseReadiness (..)
  , DeckReadiness (..)
  , DiagnosticReadiness (..)
  , ExportReadiness (..)
  , PresenterReadiness (..)
  , CommandContext (..)
  , HistoryBoundary (..)
  , DisabledReason (..)
  , CommandAvailability (..)
  , commandAvailability
  ) where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty ((:|)))
import SlideBlaster.App.Capability
  ( Capability (..)
  , CapabilitySet
  , CapabilityStatus (..)
  , capabilityStatus
  )
import SlideBlaster.App.Selection
  ( ConnectorPreset
  , Panel
  , PanelVisibility
  , Selection
  , Tool
  , Zoom
  )
import SlideBlaster.Canvas
  ( ConnectorId
  , ConnectorPropertyPatch
  , EditIntent
  , ElementId
  , NodeId
  , NodePropertyPatch
  , OverlayStep
  , Placement
  , Theme
  )
import SlideBlaster.Catalog (ShapeId)
import SlideBlaster.Export
  ( ExportTarget (..)
  , LossPolicy
  )
import SlideBlaster.Presentation
  ( Animation
  , AnimationId
  , FrameId
  , SlideRotation
  , SurfaceAddress
  )

data ProjectCommand
  = NewProject
  | OpenProject
  | SaveCurrentSource
  | ImportWorkspace
  | ExportWorkspace
  | RefreshGitStatus
  | CommitProject
  | PushProject
  deriving stock (Eq, Show)

data HistoryCommand = UndoSource | RedoSource
  deriving stock (Eq, Ord, Show)

data ReorderFrameDirection = FrameEarlier | FrameLater
  deriving stock (Eq, Ord, Show)

data DeckCommand
  = SelectFrame !FrameId
  | InsertFrameAfter !(Maybe FrameId)
  | DeleteFrame !FrameId
  | ReorderFrame !FrameId !ReorderFrameDirection
  | AddNotes !FrameId
  | RemoveNotes !FrameId
  deriving stock (Eq, Show)

data SourceCommand
  = ReplaceDraft !ByteString
  | AdmitCurrentDraft
  | GoToDiagnostic
  deriving stock (Eq, Show)

data CanvasCommand
  = SetActiveTool !Tool
  | SelectSurface !SurfaceAddress
  | ApplyCanvasEdit !SurfaceAddress !EditIntent
  | InsertText !SurfaceAddress !Placement
  | InsertShapePreset !SurfaceAddress !ShapeId !Placement
  | InsertConnector !SurfaceAddress !ConnectorPreset
  | DeleteElements !SurfaceAddress !(NonEmpty ElementId)
  deriving stock (Eq, Show)

data PropertyCommand
  = SetNodeProperty !SurfaceAddress !NodeId !NodePropertyPatch
  | SetConnectorProperty
      !SurfaceAddress
      !ConnectorId
      !ConnectorPropertyPatch
  | SetFrameRotation !FrameId !SlideRotation
  | AddAnimation !FrameId !Animation
  | RemoveAnimation !FrameId !AnimationId
  deriving stock (Eq, Show)

data ThemeCommand
  = OpenThemeEditor
  | PreviewTheme !Theme
  | ApplyTheme !Theme
  | SaveTheme
  | ImportTheme
  deriving stock (Eq, Show)

data ViewCommand
  = SetPanelVisibility !Panel !PanelVisibility
  | SetZoom !Zoom
  | FitActiveSurface
  | PanActiveSurface
  | PreviewOverlayStep !OverlayStep
  deriving stock (Eq, Show)

data PresenterCommand
  = StartPresentation
  | StopPresentation
  | PresenterNext
  | PresenterBack
  | PresenterHome
  | PresenterEnd
  deriving stock (Eq, Ord, Show)

data ExportCommand
  = AnalyzeExport !ExportTarget !LossPolicy
  | ConfirmExportWarnings !ExportTarget
  | GenerateExport !ExportTarget
  | CancelExport !ExportTarget
  | DownloadExport !ExportTarget
  deriving stock (Eq, Show)

data AppCommand
  = Project !ProjectCommand
  | History !HistoryCommand
  | Deck !DeckCommand
  | Source !SourceCommand
  | Canvas !CanvasCommand
  | Property !PropertyCommand
  | Theme !ThemeCommand
  | View !ViewCommand
  | Present !PresenterCommand
  | Export !ExportCommand
  deriving stock (Eq, Show)

data SemanticReadiness = SyntaxOnlyDocument | SemanticDocumentReady
  deriving stock (Eq, Ord, Show)

data LeaseReadiness = NoCanvasLease | InertCanvasLease | WritableCanvasLease
  deriving stock (Eq, Ord, Show)

data DeckReadiness = EmptyDeck | NonEmptyDeck
  deriving stock (Eq, Ord, Show)

data DiagnosticReadiness
  = DiagnosticsPending
  | DiagnosticsClean
  | DiagnosticWarnings
  | HardDiagnostics
  deriving stock (Eq, Ord, Show)

data ExportReadiness
  = ExportNotAnalyzed
  | ExportClean
  | ExportWarningsAwaitingConfirmation
  | ExportWarningsConfirmed
  | ExportArtifactReady
  deriving stock (Eq, Ord, Show)

data HistoryBoundary = HistoryAvailable | AtHistoryBoundary
  deriving stock (Eq, Ord, Show)

data PresenterReadiness = PresenterStopped | PresenterRunning
  deriving stock (Eq, Ord, Show)

data CommandContext = CommandContext
  { commandCapabilities :: !CapabilitySet
  , commandSemanticReadiness :: !SemanticReadiness
  , commandLeaseReadiness :: !(SurfaceAddress -> LeaseReadiness)
  , commandDeckReadiness :: !DeckReadiness
  , commandDiagnosticReadiness :: !DiagnosticReadiness
  , commandSelection :: !Selection
  , commandUndoBoundary :: !HistoryBoundary
  , commandRedoBoundary :: !HistoryBoundary
  , commandPresenterReadiness :: !PresenterReadiness
  , commandExportReadiness :: !(ExportTarget -> ExportReadiness)
  }

data DisabledReason
  = MissingCapability !Capability !CapabilityStatus
  | SemanticMeaningUnavailable
  | WritableCanvasUnavailable
  | PresentationIsEmpty
  | DiagnosticsNotCurrent
  | HardDiagnosticsBlockCommand
  | UndoBoundaryReached
  | RedoBoundaryReached
  | PresenterAlreadyRunning
  | PresenterIsNotRunning
  | NoDiagnosticAvailable
  | ExportAnalysisRequired !ExportTarget
  | ExportWarningConfirmationRequired !ExportTarget
  | ExportArtifactUnavailable !ExportTarget
  deriving stock (Eq, Show)

data CommandAvailability
  = CommandEnabled
  | CommandDisabled !(NonEmpty DisabledReason)
  deriving stock (Eq, Show)

commandAvailability :: CommandContext -> AppCommand -> CommandAvailability
commandAvailability context command =
  availabilityFromReasons (requirements context command)

availabilityFromReasons :: [DisabledReason] -> CommandAvailability
availabilityFromReasons reasons =
  case reasons of
    [] -> CommandEnabled
    first : remaining -> CommandDisabled (first :| remaining)

requirements :: CommandContext -> AppCommand -> [DisabledReason]
requirements context command =
  deduplicateReasons $
    case command of
      Project project -> projectRequirements context project
      History history -> historyRequirements context history
      Deck _ -> requireSemantic context
      Source source -> sourceRequirements context source
      Canvas canvas -> canvasRequirements context canvas
      Property property -> propertyRequirements context property
      Theme theme -> themeRequirements context theme
      View _ -> []
      Present presenter -> presenterRequirements context presenter
      Export export -> exportRequirements context export

projectRequirements :: CommandContext -> ProjectCommand -> [DisabledReason]
projectRequirements context command =
  case command of
    NewProject -> []
    OpenProject -> requireCapability context StorageCapability
    SaveCurrentSource -> requireCapability context StorageCapability
    ImportWorkspace ->
      requireCapabilities context [StorageCapability, ArchiveCapability]
    ExportWorkspace ->
      requireCapabilities context [StorageCapability, ArchiveCapability]
    RefreshGitStatus -> requireCapability context GitCapability
    CommitProject ->
      requireCapability context GitCapability <> rejectHardDiagnostics context
    PushProject ->
      requireCapability context GitCapability <> rejectHardDiagnostics context

historyRequirements :: CommandContext -> HistoryCommand -> [DisabledReason]
historyRequirements context command =
  case command of
    UndoSource ->
      case commandUndoBoundary context of
        HistoryAvailable -> []
        AtHistoryBoundary -> [UndoBoundaryReached]
    RedoSource ->
      case commandRedoBoundary context of
        HistoryAvailable -> []
        AtHistoryBoundary -> [RedoBoundaryReached]

sourceRequirements :: CommandContext -> SourceCommand -> [DisabledReason]
sourceRequirements context command =
  case command of
    ReplaceDraft _ -> []
    AdmitCurrentDraft -> []
    GoToDiagnostic ->
      case commandDiagnosticReadiness context of
        DiagnosticsClean -> [NoDiagnosticAvailable]
        DiagnosticsPending -> [NoDiagnosticAvailable]
        DiagnosticWarnings -> []
        HardDiagnostics -> []

canvasRequirements :: CommandContext -> CanvasCommand -> [DisabledReason]
canvasRequirements context command =
  case command of
    SetActiveTool _ -> requireSemantic context
    SelectSurface _ -> requireSemantic context
    ApplyCanvasEdit surface _ -> semanticAndLeaseAt context surface
    InsertText surface _ -> semanticAndLeaseAt context surface
    InsertShapePreset surface _ _ -> semanticAndLeaseAt context surface
    InsertConnector surface _ -> semanticAndLeaseAt context surface
    DeleteElements surface _ -> semanticAndLeaseAt context surface

propertyRequirements
  :: CommandContext
  -> PropertyCommand
  -> [DisabledReason]
propertyRequirements context command =
  case command of
    SetNodeProperty surface _ _ -> semanticAndLeaseAt context surface
    SetConnectorProperty surface _ _ -> semanticAndLeaseAt context surface
    SetFrameRotation {} -> requireSemantic context
    AddAnimation {} -> requireSemantic context
    RemoveAnimation {} -> requireSemantic context

themeRequirements :: CommandContext -> ThemeCommand -> [DisabledReason]
themeRequirements context command =
  case command of
    OpenThemeEditor -> requireSemantic context
    PreviewTheme _ -> requireSemantic context
    ApplyTheme _ -> requireSemantic context
    SaveTheme ->
      requireSemantic context <> requireCapability context StorageCapability
    ImportTheme ->
      requireCapability context StorageCapability

presenterRequirements
  :: CommandContext
  -> PresenterCommand
  -> [DisabledReason]
presenterRequirements context command =
  case command of
    StartPresentation ->
      requireSemantic context
        <> requireDeck context
        <> requireCapabilities
          context
          [ PresenterWindowCapability
          , PresenterChannelCapability
          , ClockCapability
          ]
        <> case commandPresenterReadiness context of
          PresenterRunning -> [PresenterAlreadyRunning]
          PresenterStopped -> []
    StopPresentation -> requirePresenterRunning context
    PresenterNext -> requirePresenterRunning context
    PresenterBack -> requirePresenterRunning context
    PresenterHome -> requirePresenterRunning context
    PresenterEnd -> requirePresenterRunning context

exportRequirements :: CommandContext -> ExportCommand -> [DisabledReason]
exportRequirements context command =
  case command of
    AnalyzeExport target _ ->
      requireSemanticForTarget context target <> targetCapabilities context target
    ConfirmExportWarnings target ->
      case commandExportReadiness context target of
        ExportWarningsAwaitingConfirmation -> []
        _ -> [ExportWarningConfirmationRequired target]
    GenerateExport target ->
      requireSemanticForTarget context target
        <> targetCapabilities context target
        <> requireExportConfirmation context target
    CancelExport _ -> []
    DownloadExport target ->
      requireCapability context DownloadCapability
        <> case commandExportReadiness context target of
          ExportArtifactReady -> []
          _ -> [ExportArtifactUnavailable target]

requireSemanticForTarget
  :: CommandContext
  -> ExportTarget
  -> [DisabledReason]
requireSemanticForTarget context target =
  case target of
    WorkspaceArchive -> []
    StandaloneHtml -> requireSemantic context
    RenderedPdf -> requireSemantic context
    LatexProject -> requireSemantic context

targetCapabilities
  :: CommandContext
  -> ExportTarget
  -> [DisabledReason]
targetCapabilities context target =
  case target of
    StandaloneHtml -> []
    RenderedPdf -> requireCapability context PrintCapability
    LatexProject -> []
    WorkspaceArchive ->
      requireCapabilities context [StorageCapability, ArchiveCapability]

requireExportConfirmation
  :: CommandContext
  -> ExportTarget
  -> [DisabledReason]
requireExportConfirmation context target =
  case commandExportReadiness context target of
    ExportClean -> []
    ExportWarningsConfirmed -> []
    ExportArtifactReady -> []
    ExportWarningsAwaitingConfirmation ->
      [ExportWarningConfirmationRequired target]
    ExportNotAnalyzed -> [ExportAnalysisRequired target]

semanticAndLeaseAt
  :: CommandContext
  -> SurfaceAddress
  -> [DisabledReason]
semanticAndLeaseAt context surface =
  requireSemantic context <> requireWritableLease context surface

requireSemantic :: CommandContext -> [DisabledReason]
requireSemantic context =
  case commandSemanticReadiness context of
    SemanticDocumentReady -> []
    SyntaxOnlyDocument -> [SemanticMeaningUnavailable]

requireWritableLease
  :: CommandContext
  -> SurfaceAddress
  -> [DisabledReason]
requireWritableLease context surface =
  case commandLeaseReadiness context surface of
    WritableCanvasLease -> []
    NoCanvasLease -> [WritableCanvasUnavailable]
    InertCanvasLease -> [WritableCanvasUnavailable]

requireDeck :: CommandContext -> [DisabledReason]
requireDeck context =
  case commandDeckReadiness context of
    NonEmptyDeck -> []
    EmptyDeck -> [PresentationIsEmpty]

rejectHardDiagnostics :: CommandContext -> [DisabledReason]
rejectHardDiagnostics context =
  case commandDiagnosticReadiness context of
    DiagnosticsPending -> [DiagnosticsNotCurrent]
    HardDiagnostics -> [HardDiagnosticsBlockCommand]
    DiagnosticsClean -> []
    DiagnosticWarnings -> []

requirePresenterRunning :: CommandContext -> [DisabledReason]
requirePresenterRunning context
  | commandPresenterReadiness context == PresenterRunning = []
  | otherwise = [PresenterIsNotRunning]

requireCapability :: CommandContext -> Capability -> [DisabledReason]
requireCapability context capability =
  case capabilityStatus capability (commandCapabilities context) of
    CapabilityAvailable -> []
    status@(CapabilityUnavailable _) ->
      [MissingCapability capability status]

requireCapabilities
  :: CommandContext
  -> [Capability]
  -> [DisabledReason]
requireCapabilities context =
  foldMap (requireCapability context)

deduplicateReasons :: [DisabledReason] -> [DisabledReason]
deduplicateReasons = foldr insertReason []
  where
    insertReason reason accumulated
      | reason `elem` accumulated = accumulated
      | otherwise = reason : accumulated
