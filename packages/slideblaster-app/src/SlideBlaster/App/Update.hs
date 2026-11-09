-- |
-- Module      : SlideBlaster.App.Update
-- Description : Pure source, analysis, paint, and presenter state transitions.
--
-- Effects are requests interpreted by a browser or native composition. Every
-- asynchronous completion re-enters this reducer with the fences carried by
-- its semantic value.
module SlideBlaster.App.Update
  ( PresenterMovement (..)
  , AppEvent (..)
  , AppEffect (..)
  , Update
  , updateModel
  , updateEffects
  , UpdateError (..)
  , update
  ) where

import Data.ByteString (ByteString)
import SlideBlaster.App.Lease
  ( LeaseError
  , PaintRequest
  , acknowledgePaint
  , paintRequestSurface
  )
import SlideBlaster.App.Model
  ( AppModel
  , SessionChange (..)
  , SessionError
  , acceptSessionDocument
  , appDocumentSession
  , appPresenter
  , beginSessionPaintRequests
  , consumeSessionPaintRequest
  , redoSession
  , replaceSessionDraft
  , sessionDraft
  , sessionSemanticPresentation
  , setAppDocumentSession
  , setAppPresenter
  , setSessionCanvasAuthority
  , undoSession
  )
import SlideBlaster.Document
  ( DocumentSnapshot
  , documentSemantic
  )
import SlideBlaster.Presentation
  ( Presentation
  , PresenterState
  , PresenterViews
  , TimerOrigin
  , backBeat
  , endBeat
  , homeBeat
  , nextBeat
  , projectPresenterViews
  , startPresenter
  )
import SlideBlaster.Render (RenderPlan)
import SlideBlaster.Source (SourceBufferSnapshot)

data PresenterMovement
  = MovePresenterNext
  | MovePresenterBack
  | MovePresenterHome
  | MovePresenterEnd
  deriving stock (Eq, Ord, Show)

data AppEvent syntax key
  = DraftBytesChanged !ByteString
  | UndoDraft
  | RedoDraft
  | AnalysisCompleted !(DocumentSnapshot syntax key Presentation)
  | PaintCompleted !PaintRequest !RenderPlan
  | StartPresenter !TimerOrigin
  | StopPresenter
  | MovePresenter !PresenterMovement

data AppEffect
  = AnalyzeSource !SourceBufferSnapshot
  | MeasureAndRender
      !PaintRequest
      !SourceBufferSnapshot
      !Presentation
  | PublishPresenter !PresenterViews

data Update syntax key = Update
  !(AppModel syntax key)
  ![AppEffect]

updateModel :: Update syntax key -> AppModel syntax key
updateModel (Update model _) = model

updateEffects :: Update syntax key -> [AppEffect]
updateEffects (Update _ effects) = effects

data UpdateError
  = UpdateSessionError !SessionError
  | UpdateLeaseError !LeaseError
  | PresenterNotStarted
  | NoCurrentSemanticPresentation
  deriving stock (Eq, Show)

update
  :: AppEvent syntax key
  -> AppModel syntax key
  -> Either UpdateError (Update syntax key)
update event model =
  case event of
    DraftBytesChanged bytes ->
      updateFromSessionChange model
        <$> mapSessionError
          (replaceSessionDraft bytes (appDocumentSession model))
    UndoDraft ->
      updateFromSessionChange model
        <$> mapSessionError (undoSession (appDocumentSession model))
    RedoDraft ->
      updateFromSessionChange model
        <$> mapSessionError (redoSession (appDocumentSession model))
    AnalysisCompleted document -> do
      acceptedSession <-
        mapSessionError
          (acceptSessionDocument document (appDocumentSession model))
      case documentSemantic document of
        Nothing ->
          Right
            ( Update
                (setAppDocumentSession acceptedSession model)
                []
            )
        Just presentation -> do
          (session, requests) <-
            mapSessionError
              (beginSessionPaintRequests presentation acceptedSession)
          let effects =
                [ MeasureAndRender
                    request
                    (sessionDraft session)
                    presentation
                | request <- requests
                ]
          Right
            (Update (setAppDocumentSession session model) effects)
    PaintCompleted request plan -> do
      let currentSession = appDocumentSession model
      session <-
        mapSessionError
          (consumeSessionPaintRequest request currentSession)
      authority <-
        mapLeaseError
          (acknowledgePaint request plan)
      let nextSession =
            setSessionCanvasAuthority
              (paintRequestSurface request)
              authority
              session
      Right (Update (setAppDocumentSession nextSession model) [])
    StartPresenter origin -> do
      presentation <-
        case sessionSemanticPresentation (appDocumentSession model) of
          Nothing -> Left NoCurrentSemanticPresentation
          Just value -> Right value
      let presenter = startPresenter origin presentation
      let nextModel = setAppPresenter (Just presenter) model
      Right
        ( Update
            nextModel
            [PublishPresenter (projectPresenterViews presenter)]
        )
    StopPresenter ->
      Right (Update (setAppPresenter Nothing model) [])
    MovePresenter movement -> do
      presenter <-
        case appPresenter model of
          Nothing -> Left PresenterNotStarted
          Just value -> Right value
      let nextPresenter = movePresenter movement presenter
          nextModel = setAppPresenter (Just nextPresenter) model
      Right
        ( Update
            nextModel
            [PublishPresenter (projectPresenterViews nextPresenter)]
        )

updateFromSessionChange
  :: AppModel syntax key
  -> SessionChange syntax key
  -> Update syntax key
updateFromSessionChange model change =
  case change of
    SessionUnchanged _ -> Update model []
    SessionChanged source session ->
      Update
        (setAppDocumentSession session model)
        [AnalyzeSource source]

movePresenter :: PresenterMovement -> PresenterState -> PresenterState
movePresenter movement =
  case movement of
    MovePresenterNext -> nextBeat
    MovePresenterBack -> backBeat
    MovePresenterHome -> homeBeat
    MovePresenterEnd -> endBeat

mapSessionError
  :: Either SessionError value
  -> Either UpdateError value
mapSessionError result =
  case result of
    Left failure -> Left (UpdateSessionError failure)
    Right value -> Right value

mapLeaseError
  :: Either LeaseError value
  -> Either UpdateError value
mapLeaseError result =
  case result of
    Left failure -> Left (UpdateLeaseError failure)
    Right value -> Right value
