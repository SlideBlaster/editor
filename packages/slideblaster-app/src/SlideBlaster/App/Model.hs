-- |
-- Module      : SlideBlaster.App.Model
-- Description : Coherent source draft, analysis, canvas, and product view state.
--
-- The current history snapshot is authoritative source. An accepted document
-- and painted canvas may lag behind it, but only exact-current values regain
-- semantic or edit authority.
module SlideBlaster.App.Model
  ( DocumentSession
  , SessionError (..)
  , SessionChange (..)
  , startDocumentSession
  , sessionId
  , sessionHistory
  , sessionDraft
  , sessionAcceptedDocument
  , sessionCanvasAuthority
  , sessionPendingPaintRequests
  , sessionSemanticPresentation
  , replaceSessionDraft
  , undoSession
  , redoSession
  , acceptSessionDocument
  , beginSessionPaintRequests
  , consumeSessionPaintRequest
  , setSessionCanvasAuthority
  , ExportJobState (..)
  , ExportJobs
  , emptyExportJobs
  , exportJobState
  , setExportJobState
  , AppModel
  , newAppModel
  , appDocumentSession
  , appSelection
  , appTool
  , appCanvasView
  , appCapabilities
  , appPresenter
  , appExportJobs
  , setAppDocumentSession
  , setAppSelection
  , setAppTool
  , setAppCanvasView
  , setAppCapabilities
  , setAppPresenter
  , setAppExportJobs
  , appCommandContext
  ) where

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word64)
import SlideBlaster.App.Capability (CapabilitySet)
import SlideBlaster.App.Command
  ( CommandContext (..)
  , DeckReadiness (..)
  , DiagnosticReadiness (..)
  , ExportReadiness (..)
  , HistoryBoundary (..)
  , LeaseReadiness (..)
  , PresenterReadiness (..)
  , SemanticReadiness (..)
  )
import SlideBlaster.App.History
  ( HistoryChange (..)
  , HistoryError
  , SourceHistory
  , canRedo
  , canUndo
  , historyCurrent
  , recordHistoryBytes
  , redoHistory
  , startHistory
  , undoHistory
  )
import SlideBlaster.App.Lease
  ( CanvasAuthority
  , InertReason (..)
  , PaintRequest
  , SessionId
  , inertCanvasAuthority
  , noCanvasAuthority
  , paintRequest
  , paintRequestSurface
  , revokeCanvasAuthority
  , writableCanvasAuthority
  )
import SlideBlaster.App.Selection
  ( CanvasView
  , Selection (NoSelection)
  , Tool (SelectTool)
  , defaultCanvasView
  )
import SlideBlaster.Document
  ( Diagnostic
  , DiagnosticSeverity (..)
  , DocumentSnapshot
  , documentDiagnostics
  , documentSemantic
  , documentSource
  , diagnosticSeverity
  )
import SlideBlaster.Export
  ( ExportReport
  , ExportTarget
  )
import SlideBlaster.Presentation
  ( Frame
  , Presentation
  , PresenterState
  , SurfaceAddress
  , SurfaceKind (AudienceSurface, NotesSurface)
  , frameId
  , frameNotes
  , presentationFrames
  , surfaceAddress
  )
import SlideBlaster.Render
  ( renderTicketFromWord64
  )
import SlideBlaster.Source
  ( Revision
  , SourceBufferSnapshot
  , snapshotBytes
  , snapshotRevision
  )

data DocumentSession syntax key = DocumentSession
  !SessionId
  !SourceHistory
  !(Maybe (DocumentSnapshot syntax key Presentation))
  !(Map SurfaceAddress CanvasAuthority)
  !(Map SurfaceAddress PaintRequest)
  !Word64

data SessionError
  = SessionHistoryError !HistoryError
  | StaleDocumentAnalysis !Revision !Revision
  | AnalysisBytesDoNotMatchDraft !Revision
  | RenderTicketExhausted
  | PaintCompletionNotPending !SurfaceAddress
  | PaintCompletionDoesNotMatch !PaintRequest !PaintRequest
  deriving stock (Eq, Show)

data SessionChange syntax key
  = SessionUnchanged !(DocumentSession syntax key)
  | SessionChanged
      !SourceBufferSnapshot
      !(DocumentSession syntax key)

startDocumentSession
  :: SessionId
  -> SourceBufferSnapshot
  -> DocumentSession syntax key
startDocumentSession identity source =
  DocumentSession
    identity
    (startHistory source)
    Nothing
    Map.empty
    Map.empty
    0

sessionId :: DocumentSession syntax key -> SessionId
sessionId (DocumentSession identity _ _ _ _ _) = identity

sessionHistory :: DocumentSession syntax key -> SourceHistory
sessionHistory (DocumentSession _ history _ _ _ _) = history

sessionDraft :: DocumentSession syntax key -> SourceBufferSnapshot
sessionDraft = historyCurrent . sessionHistory

sessionAcceptedDocument
  :: DocumentSession syntax key
  -> Maybe (DocumentSnapshot syntax key Presentation)
sessionAcceptedDocument (DocumentSession _ _ accepted _ _ _) = accepted

sessionCanvasAuthority
  :: SurfaceAddress
  -> DocumentSession syntax key
  -> CanvasAuthority
sessionCanvasAuthority surface (DocumentSession _ _ _ authorities _ _) =
  Map.findWithDefault noCanvasAuthority surface authorities

sessionPendingPaintRequests
  :: DocumentSession syntax key
  -> [PaintRequest]
sessionPendingPaintRequests (DocumentSession _ _ _ _ requests _) =
  Map.elems requests

sessionSemanticPresentation
  :: DocumentSession syntax key
  -> Maybe Presentation
sessionSemanticPresentation session = do
  document <- sessionAcceptedDocument session
  if sourcesAgree (sessionDraft session) (documentSource document)
    then documentSemantic document
    else Nothing

replaceSessionDraft
  :: ByteString
  -> DocumentSession syntax key
  -> Either SessionError (SessionChange syntax key)
replaceSessionDraft bytes session =
  applyHistoryChange session
    <$> mapHistoryError
      (recordHistoryBytes bytes (sessionHistory session))

undoSession
  :: DocumentSession syntax key
  -> Either SessionError (SessionChange syntax key)
undoSession session =
  applyHistoryChange session
    <$> mapHistoryError (undoHistory (sessionHistory session))

redoSession
  :: DocumentSession syntax key
  -> Either SessionError (SessionChange syntax key)
redoSession session =
  applyHistoryChange session
    <$> mapHistoryError (redoHistory (sessionHistory session))

acceptSessionDocument
  :: DocumentSnapshot syntax key Presentation
  -> DocumentSession syntax key
  -> Either SessionError (DocumentSession syntax key)
acceptSessionDocument document session
  | snapshotRevision analyzed /= snapshotRevision draft =
      Left
        ( StaleDocumentAnalysis
            (snapshotRevision draft)
            (snapshotRevision analyzed)
        )
  | snapshotBytes analyzed /= snapshotBytes draft =
      Left (AnalysisBytesDoNotMatchDraft (snapshotRevision draft))
  | otherwise =
      Right
        ( DocumentSession
            (sessionId session)
            (sessionHistory session)
            (Just document)
            (revokeAuthorities acceptedReason (sessionAuthorities session))
            Map.empty
            (sessionNextRenderTicket session)
        )
  where
    draft = sessionDraft session
    analyzed = documentSource document
    acceptedReason =
      case documentSemantic document of
        Nothing -> AcceptedSyntaxOnly
        Just _ -> MeasurementPending

beginSessionPaintRequests
  :: Presentation
  -> DocumentSession syntax key
  -> Either SessionError (DocumentSession syntax key, [PaintRequest])
beginSessionPaintRequests presentation session = do
  (nextTicket, requests) <-
    allocatePaintRequests
      (sessionId session)
      (snapshotRevision (sessionDraft session))
      (sessionNextRenderTicket session)
      (presentationSurfaces presentation)
  let indexed =
        Map.fromList
          [(paintRequestSurface request, request) | request <- requests]
  Right
    ( DocumentSession
        (sessionId session)
        (sessionHistory session)
        (sessionAcceptedDocument session)
        (sessionAuthorities session)
        indexed
        nextTicket
    , requests
    )

consumeSessionPaintRequest
  :: PaintRequest
  -> DocumentSession syntax key
  -> Either SessionError (DocumentSession syntax key)
consumeSessionPaintRequest completion session =
  case Map.lookup surface (sessionPendingRequests session) of
    Nothing -> Left (PaintCompletionNotPending surface)
    Just expected
      | expected /= completion ->
          Left (PaintCompletionDoesNotMatch expected completion)
      | otherwise ->
          Right
            ( DocumentSession
                (sessionId session)
                (sessionHistory session)
                (sessionAcceptedDocument session)
                (sessionAuthorities session)
                (Map.delete surface (sessionPendingRequests session))
                (sessionNextRenderTicket session)
            )
  where
    surface = paintRequestSurface completion

setSessionCanvasAuthority
  :: SurfaceAddress
  -> CanvasAuthority
  -> DocumentSession syntax key
  -> DocumentSession syntax key
setSessionCanvasAuthority surface authority session =
  DocumentSession
    (sessionId session)
    (sessionHistory session)
    (sessionAcceptedDocument session)
    (Map.insert surface authority (sessionAuthorities session))
    (sessionPendingRequests session)
    (sessionNextRenderTicket session)

applyHistoryChange
  :: DocumentSession syntax key
  -> HistoryChange
  -> SessionChange syntax key
applyHistoryChange session change =
  case change of
    HistoryNoOp _ -> SessionUnchanged session
    HistoryAdvanced source history ->
      SessionChanged
        source
        ( DocumentSession
            (sessionId session)
            history
            (sessionAcceptedDocument session)
            ( revokeAuthorities
                NewerDraftExists
                (sessionAuthorities session)
            )
            Map.empty
            (sessionNextRenderTicket session)
        )

mapHistoryError
  :: Either HistoryError value
  -> Either SessionError value
mapHistoryError result =
  case result of
    Left failure -> Left (SessionHistoryError failure)
    Right value -> Right value

sourcesAgree :: SourceBufferSnapshot -> SourceBufferSnapshot -> Bool
sourcesAgree left right =
  snapshotRevision left == snapshotRevision right
    && snapshotBytes left == snapshotBytes right

sessionAuthorities
  :: DocumentSession syntax key
  -> Map SurfaceAddress CanvasAuthority
sessionAuthorities (DocumentSession _ _ _ authorities _ _) = authorities

sessionPendingRequests
  :: DocumentSession syntax key
  -> Map SurfaceAddress PaintRequest
sessionPendingRequests (DocumentSession _ _ _ _ requests _) = requests

sessionNextRenderTicket :: DocumentSession syntax key -> Word64
sessionNextRenderTicket (DocumentSession _ _ _ _ _ nextTicket) = nextTicket

revokeAuthorities
  :: InertReason
  -> Map SurfaceAddress CanvasAuthority
  -> Map SurfaceAddress CanvasAuthority
revokeAuthorities reason = fmap (revokeCanvasAuthority reason)

presentationSurfaces :: Presentation -> [SurfaceAddress]
presentationSurfaces presentation =
  foldMap frameSurfaces (presentationFrames presentation)
  where
    frameSurfaces :: Frame -> [SurfaceAddress]
    frameSurfaces frame =
      surfaceAddress (frameId frame) AudienceSurface
        : case frameNotes frame of
          Nothing -> []
          Just _ -> [surfaceAddress (frameId frame) NotesSurface]

allocatePaintRequests
  :: SessionId
  -> Revision
  -> Word64
  -> [SurfaceAddress]
  -> Either SessionError (Word64, [PaintRequest])
allocatePaintRequests identity revision initial surfaces =
  go initial surfaces
  where
    go nextTicket remaining =
      case remaining of
        [] -> Right (nextTicket, [])
        surface : rest
          | nextTicket == maxBound -> Left RenderTicketExhausted
          | otherwise -> do
              (followingTicket, later) <- go (nextTicket + 1) rest
              let request =
                    paintRequest
                      identity
                      revision
                      (renderTicketFromWord64 nextTicket)
                      surface
              Right (followingTicket, request : later)

data ExportJobState
  = ExportAnalyzing
  | ExportWaitingForConfirmation
  | ExportConfirmed
  | ExportRunning
  | ExportComplete !ExportReport
  deriving stock (Eq, Show)

newtype ExportJobs = ExportJobs (Map ExportTarget ExportJobState)
  deriving stock (Eq, Show)

emptyExportJobs :: ExportJobs
emptyExportJobs = ExportJobs Map.empty

exportJobState :: ExportTarget -> ExportJobs -> Maybe ExportJobState
exportJobState target (ExportJobs jobs) = Map.lookup target jobs

setExportJobState
  :: ExportTarget
  -> ExportJobState
  -> ExportJobs
  -> ExportJobs
setExportJobState target state (ExportJobs jobs) =
  ExportJobs (Map.insert target state jobs)

data AppModel syntax key = AppModel
  !(DocumentSession syntax key)
  !Selection
  !Tool
  !CanvasView
  !CapabilitySet
  !(Maybe PresenterState)
  !ExportJobs

newAppModel
  :: DocumentSession syntax key
  -> CapabilitySet
  -> AppModel syntax key
newAppModel session capabilities =
  AppModel
    session
    NoSelection
    SelectTool
    defaultCanvasView
    capabilities
    Nothing
    emptyExportJobs

appDocumentSession
  :: AppModel syntax key
  -> DocumentSession syntax key
appDocumentSession (AppModel session _ _ _ _ _ _) = session

appSelection :: AppModel syntax key -> Selection
appSelection (AppModel _ selection _ _ _ _ _) = selection

appTool :: AppModel syntax key -> Tool
appTool (AppModel _ _ tool _ _ _ _) = tool

appCanvasView :: AppModel syntax key -> CanvasView
appCanvasView (AppModel _ _ _ view _ _ _) = view

appCapabilities :: AppModel syntax key -> CapabilitySet
appCapabilities (AppModel _ _ _ _ capabilities _ _) = capabilities

appPresenter :: AppModel syntax key -> Maybe PresenterState
appPresenter (AppModel _ _ _ _ _ presenter _) = presenter

appExportJobs :: AppModel syntax key -> ExportJobs
appExportJobs (AppModel _ _ _ _ _ _ jobs) = jobs

setAppDocumentSession
  :: DocumentSession syntax key
  -> AppModel syntax key
  -> AppModel syntax key
setAppDocumentSession session model =
  AppModel
    session
    (appSelection model)
    (appTool model)
    (appCanvasView model)
    (appCapabilities model)
    (appPresenter model)
    (appExportJobs model)

setAppSelection :: Selection -> AppModel syntax key -> AppModel syntax key
setAppSelection selection model =
  AppModel
    (appDocumentSession model)
    selection
    (appTool model)
    (appCanvasView model)
    (appCapabilities model)
    (appPresenter model)
    (appExportJobs model)

setAppTool :: Tool -> AppModel syntax key -> AppModel syntax key
setAppTool tool model =
  AppModel
    (appDocumentSession model)
    (appSelection model)
    tool
    (appCanvasView model)
    (appCapabilities model)
    (appPresenter model)
    (appExportJobs model)

setAppCanvasView
  :: CanvasView
  -> AppModel syntax key
  -> AppModel syntax key
setAppCanvasView view model =
  AppModel
    (appDocumentSession model)
    (appSelection model)
    (appTool model)
    view
    (appCapabilities model)
    (appPresenter model)
    (appExportJobs model)

setAppCapabilities
  :: CapabilitySet
  -> AppModel syntax key
  -> AppModel syntax key
setAppCapabilities capabilities model =
  AppModel
    (appDocumentSession model)
    (appSelection model)
    (appTool model)
    (appCanvasView model)
    capabilities
    (appPresenter model)
    (appExportJobs model)

setAppPresenter
  :: Maybe PresenterState
  -> AppModel syntax key
  -> AppModel syntax key
setAppPresenter presenter model =
  AppModel
    (appDocumentSession model)
    (appSelection model)
    (appTool model)
    (appCanvasView model)
    (appCapabilities model)
    presenter
    (appExportJobs model)

setAppExportJobs
  :: ExportJobs
  -> AppModel syntax key
  -> AppModel syntax key
setAppExportJobs jobs model =
  AppModel
    (appDocumentSession model)
    (appSelection model)
    (appTool model)
    (appCanvasView model)
    (appCapabilities model)
    (appPresenter model)
    jobs

appCommandContext :: AppModel syntax key -> CommandContext
appCommandContext model =
  CommandContext
    { commandCapabilities = appCapabilities model
    , commandSemanticReadiness =
        case sessionSemanticPresentation session of
          Nothing -> SyntaxOnlyDocument
          Just _ -> SemanticDocumentReady
    , commandLeaseReadiness = leaseReadinessFor session
    , commandDeckReadiness =
        case sessionSemanticPresentation session of
          Just _ -> NonEmptyDeck
          _ -> EmptyDeck
    , commandDiagnosticReadiness =
        diagnosticReadinessFor session
    , commandSelection = appSelection model
    , commandUndoBoundary =
        historyBoundaryFor (canUndo (sessionHistory session))
    , commandRedoBoundary =
        historyBoundaryFor (canRedo (sessionHistory session))
    , commandPresenterReadiness =
        case appPresenter model of
          Nothing -> PresenterStopped
          Just _ -> PresenterRunning
    , commandExportReadiness =
        flip exportReadinessFor (appExportJobs model)
    }
  where
    session = appDocumentSession model

leaseReadinessFor
  :: DocumentSession syntax key
  -> SurfaceAddress
  -> LeaseReadiness
leaseReadinessFor session surface =
  case writableCanvasAuthority (sessionCanvasAuthority surface session) of
    Just _ -> WritableCanvasLease
    Nothing ->
      case inertCanvasAuthority (sessionCanvasAuthority surface session) of
        Just _ -> InertCanvasLease
        Nothing -> NoCanvasLease

diagnosticReadinessFor
  :: DocumentSession syntax key
  -> DiagnosticReadiness
diagnosticReadinessFor session =
  case sessionAcceptedDocument session of
    Nothing -> DiagnosticsPending
    Just accepted
      | not (sourcesAgree (sessionDraft session) (documentSource accepted)) ->
          DiagnosticsPending
      | otherwise ->
          classifyDiagnostics (documentDiagnostics accepted)

classifyDiagnostics :: [Diagnostic] -> DiagnosticReadiness
classifyDiagnostics diagnostics
  | any ((== DiagnosticError) . diagnosticSeverity) diagnostics =
      HardDiagnostics
  | any ((== DiagnosticWarning) . diagnosticSeverity) diagnostics =
      DiagnosticWarnings
  | otherwise = DiagnosticsClean

historyBoundaryFor :: Bool -> HistoryBoundary
historyBoundaryFor available
  | available = HistoryAvailable
  | otherwise = AtHistoryBoundary

exportReadinessFor :: ExportTarget -> ExportJobs -> ExportReadiness
exportReadinessFor target jobs =
  case exportJobState target jobs of
    Nothing -> ExportNotAnalyzed
    Just ExportAnalyzing -> ExportNotAnalyzed
    Just ExportWaitingForConfirmation ->
      ExportWarningsAwaitingConfirmation
    Just ExportConfirmed -> ExportWarningsConfirmed
    Just ExportRunning -> ExportWarningsConfirmed
    Just (ExportComplete _) -> ExportArtifactReady
