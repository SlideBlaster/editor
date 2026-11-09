{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.TikZ.Adapter
-- Description : Bounded TikZ adapter into the common product model.
--
-- The lossless TikZ reader and its semantic types remain private to this
-- package. This adapter admits the deliberate one-node/one-connector subset as
-- a generic source-locked document and delegates an absolute-centre
-- 'MoveElement' to the existing verified inverse. Unsupported operation and
-- placement forms remain typed and atomic.
module SlideBlaster.TikZ.Adapter
  ( TikzSyntax
  , TikzFieldKey (..)
  , CommonTikzDocument
  , TikzAdapterError (..)
  , TikzCanvasEditError (..)
  , TikzCanvasEditResult (..)
  , analyzeCommonTikz
  , applyCommonTikzEdit
  ) where

import SlideBlaster.Canvas qualified as Canvas
import SlideBlaster.Document qualified as Document
import SlideBlaster.Presentation qualified as Presentation
import SlideBlaster.Source
  ( SourceBufferSnapshot
  , snapshotBytes
  , snapshotRevision
  )
import SlideBlaster.TikZ.Internal.Decimal qualified as TikzDecimal
import SlideBlaster.TikZ.Internal.Edit (applyMoveNodeInternal)
import SlideBlaster.TikZ.Internal.Parser (parseSnapshot)
import SlideBlaster.TikZ qualified as Bounded
import SlideBlaster.TikZ.Internal.Types qualified as Tikz

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as Text

-- | Opaque recoverable TikZ syntax retained by the generic document.
newtype TikzSyntax = TikzSyntax Tikz.DocumentSnapshot
  deriving stock (Eq, Show)

-- | Common-model fields for which this bounded adapter records provenance.
data TikzFieldKey
  = TikzNodeCentreX !Canvas.NodeId
  | TikzNodeCentreY !Canvas.NodeId
  | TikzConnectorStart !Canvas.ConnectorId
  | TikzConnectorEndpoint !Canvas.ConnectorId
  deriving stock (Eq, Ord, Show)

type CommonTikzDocument =
  Document.DocumentSnapshot TikzSyntax TikzFieldKey Presentation.Presentation

data TikzAdapterError
  = TikzAdapterNodeIdentityInvalid
  | TikzAdapterConnectorIdentityInvalid
  | TikzAdapterFrameIdentityInvalid
  | TikzAdapterConnectorPathInvalid !Canvas.ConnectorPathError
  | TikzAdapterPictureInvalid !Canvas.PictureError
  | TikzAdapterSceneInvalid !Presentation.SceneError
  | TikzAdapterPresentationInvalid !Presentation.PresentationError
  | TikzAdapterProjectionRuleInvalid
  | TikzAdapterInvariant
  deriving stock (Eq, Show)

data TikzCanvasEditError
  = TikzCanvasIntentUnsupported !Canvas.EditIntent
  | TikzCanvasPlacementUnsupported !Canvas.Placement
  | TikzCanvasTargetMissing !Canvas.ElementId
  | TikzCanvasCoordinateUnsupported !TikzDecimal.CoordinateError
  | TikzCanvasProjectionFailed !Bounded.MoveError
  | TikzCanvasAdmissionFailed !TikzAdapterError
  | TikzCanvasSemanticMismatch
  deriving stock (Eq, Show)

data TikzCanvasEditResult
  = TikzCanvasUnchanged !CommonTikzDocument
  | TikzCanvasVerified !CommonTikzDocument
  deriving stock (Eq, Show)

-- | Analyze exact source into the generic document and common presentation.
analyzeCommonTikz
  :: SourceBufferSnapshot
  -> Either TikzAdapterError CommonTikzDocument
analyzeCommonTikz source = admitDocument (parseSnapshot source)

-- | Apply one common operation through the bounded verified TikZ inverse.
applyCommonTikzEdit
  :: Canvas.EditIntent
  -> CommonTikzDocument
  -> Either TikzCanvasEditError TikzCanvasEditResult
applyCommonTikzEdit operation document =
  case operation of
    Canvas.MoveElement element placement ->
      case (element, placement) of
        ( Canvas.NodeElement requestedNode
          , Canvas.AbsolutePlacement destination Canvas.Centre
          ) -> moveNode requestedNode destination
        (Canvas.NodeElement _, unsupported) ->
          Left (TikzCanvasPlacementUnsupported unsupported)
        _ -> Left (TikzCanvasTargetMissing element)
    _ -> Left (TikzCanvasIntentUnsupported operation)
  where
    TikzSyntax privateDocument = Document.documentSyntax document

    moveNode requestedNode destination = do
      privatePicture <-
        case Bounded.documentPicture privateDocument of
          Nothing -> Left (TikzCanvasProjectionFailed Bounded.MoveSemanticsUnavailable)
          Just value -> Right value
      let privateNode = Bounded.pictureNode privatePicture
          privateIdentity = Bounded.nodeId privateNode
      if Canvas.identifierText requestedNode /= Bounded.nodeIdText privateIdentity
        then Left (TikzCanvasTargetMissing (Canvas.NodeElement requestedNode))
        else do
          x <- mapCoordinate (Canvas.canvasUnitValue (Canvas.pointX destination))
          y <- mapCoordinate (Canvas.canvasUnitValue (Canvas.pointY destination))
          successor <-
            mapProjection
              ( applyMoveNodeInternal
                  ( Bounded.moveNode
                      (snapshotRevision (Bounded.documentSourceSnapshot privateDocument))
                      privateIdentity
                      (Bounded.point x y)
                  )
                  privateDocument
              )
          if snapshotBytes (Bounded.documentSourceSnapshot successor)
              == snapshotBytes (Bounded.documentSourceSnapshot privateDocument)
            then Right (TikzCanvasUnchanged document)
            else do
              commonSuccessor <- mapAdmission (admitDocument successor)
              if successorHasDestination requestedNode destination commonSuccessor
                then Right (TikzCanvasVerified commonSuccessor)
                else Left TikzCanvasSemanticMismatch

admitDocument :: Tikz.DocumentSnapshot -> Either TikzAdapterError CommonTikzDocument
admitDocument privateDocument =
  case Tikz.documentAnalysis privateDocument of
    Tikz.AnalysisUnavailable diagnostics ->
      Right
        ( Document.syntaxOnlyDocument
            source
            (TikzSyntax privateDocument)
            (fmap commonDiagnostic diagnostics)
        )
    Tikz.AnalysisReady (Tikz.ReadyDocument picture provenance _) -> do
      presentation <- pictureToPresentation picture
      origins <- provenanceFor privateDocument picture provenance
      Right
        ( Document.readyDocument
            source
            (TikzSyntax privateDocument)
            presentation
            origins
            []
        )
  where
    source = Bounded.documentSourceSnapshot privateDocument

pictureToPresentation
  :: Bounded.Picture
  -> Either TikzAdapterError Presentation.Presentation
pictureToPresentation picture = do
  commonNodeId <- maybeToError TikzAdapterNodeIdentityInvalid (Canvas.nodeId nodeName)
  commonConnectorId <-
    maybeToError
      TikzAdapterConnectorIdentityInvalid
      (Canvas.connectorId (nodeName <> "-connector"))
  connectorPath <-
    mapLeft TikzAdapterConnectorPathInvalid
      ( Canvas.mkConnectorPath
          ( Canvas.NodeAnchor commonNodeId Canvas.Centre
              :| [Canvas.AbsoluteAnchor connectorEndpoint]
          )
          [Canvas.StraightSegment]
          Canvas.OpenPath
      )
  canvasPicture <-
    mapLeft TikzAdapterPictureInvalid
      ( Canvas.mkPicture
          [ Canvas.ObjectEntry
              ( Canvas.CanvasNode
                  Canvas.Node
                    { Canvas.nodeIdentifier = commonNodeId
                    , Canvas.nodePlacement =
                        Canvas.AbsolutePlacement nodePoint Canvas.Centre
                    , Canvas.nodeOutline =
                        Canvas.PrimitiveGeometry Canvas.RectangleOutline
                    , Canvas.nodeContent =
                        Canvas.content
                          [ Canvas.TextRun
                              (Canvas.CanvasProvenance Canvas.LaTeX)
                              (Bounded.nodeContent privateNode)
                          ]
                    , Canvas.nodePropertyOverrides = Canvas.emptyNodePropertyPatch
                    , Canvas.nodeAnimationRefs = []
                    , Canvas.nodeAccessibility = Canvas.DecorativeNode
                    }
              )
          , Canvas.ObjectEntry
              ( Canvas.CanvasConnector
                  Canvas.Connector
                    { Canvas.connectorIdentifier = commonConnectorId
                    , Canvas.connectorPath = connectorPath
                    , Canvas.connectorLabel = Nothing
                    , Canvas.connectorPropertyOverrides =
                        Canvas.emptyConnectorPropertyPatch
                    , Canvas.connectorAnimationRefs = []
                    , Canvas.connectorAccessibility = Canvas.DecorativeNode
                    }
              )
          ]
      )
  scene <-
    mapLeft TikzAdapterSceneInvalid
      (Presentation.mkScene canvasPicture Presentation.emptyAnimationTimeline)
  frameIdentity <-
    mapLeft (const TikzAdapterFrameIdentityInvalid)
      (Presentation.mkFrameId "tikz-frame")
  mapLeft TikzAdapterPresentationInvalid
    ( Presentation.mkPresentation
        ( Presentation.mkPresentationMetadata
            "Bounded TikZ"
            Presentation.defaultAspectRatio
            Canvas.defaultTheme
            Presentation.CompleteImmediately
        )
        ( Presentation.mkFrame
            frameIdentity
            (Presentation.mkFrameMetadata "Bounded TikZ" Presentation.noSlideRotation)
            scene
            Nothing
            :| []
        )
    )
  where
    privateNode = Bounded.pictureNode picture
    privateConnector = Bounded.pictureConnector picture
    nodeName = Bounded.nodeIdText (Bounded.nodeId privateNode)
    nodePoint = commonPoint (Bounded.nodePosition privateNode)
    connectorEndpoint = commonPoint (Bounded.connectorEnd privateConnector)

provenanceFor
  :: Tikz.DocumentSnapshot
  -> Bounded.Picture
  -> Tikz.CoordinateProvenance
  -> Either TikzAdapterError (Document.ProvenanceMap TikzFieldKey)
provenanceFor privateDocument picture coordinateProvenance = do
  commonNodeId <-
    maybeToError TikzAdapterNodeIdentityInvalid
      (Canvas.nodeId (Bounded.nodeIdText (Bounded.nodeId (Bounded.pictureNode picture))))
  commonConnectorId <-
    maybeToError TikzAdapterConnectorIdentityInvalid
      (Canvas.connectorId (Canvas.identifierText commonNodeId <> "-connector"))
  rule <-
    maybeToError
      TikzAdapterProjectionRuleInvalid
      (Document.mkProjectionRule "tikz.direct-node-centre")
  case (Tikz.documentConcreteSyntax privateDocument, coordinateProvenance) of
    ( Tikz.SupportedConcrete _ _ connectorSpan xSpan ySpan
      , Tikz.DirectCoordinateSlots directX directY
      )
        | xSpan == directX && ySpan == directY ->
            Right
              ( Document.provenanceFromList
                  [ (TikzNodeCentreX commonNodeId, Document.DirectSlot xSpan rule)
                  , (TikzNodeCentreY commonNodeId, Document.DirectSlot ySpan rule)
                  , ( TikzConnectorStart commonConnectorId
                    , Document.DerivedBy rule (xSpan :| [ySpan])
                    )
                  , ( TikzConnectorEndpoint commonConnectorId
                    , Document.ReadOnly Document.MissingInverseRule (Just connectorSpan)
                    )
                  ]
              )
    _ -> Left TikzAdapterInvariant

commonPoint :: Bounded.Point -> Canvas.Point
commonPoint value =
  Canvas.point
    (Canvas.canvasUnit (TikzDecimal.coordinateToRational (Bounded.pointX value)))
    (Canvas.canvasUnit (TikzDecimal.coordinateToRational (Bounded.pointY value)))

commonDiagnostic :: Bounded.Diagnostic -> Document.Diagnostic
commonDiagnostic diagnostic =
  Document.mkDiagnostic
    Document.DiagnosticError
    (case Bounded.diagnosticCategory diagnostic of
      Bounded.DiagnosticMalformed -> Document.SyntaxMalformed
      Bounded.DiagnosticUnsupported -> Document.SyntaxUnsupported
      Bounded.DiagnosticAmbiguous -> Document.MeaningAmbiguous
    )
    commonCode
    (Bounded.diagnosticMessage diagnostic)
    (Bounded.diagnosticSpan diagnostic)
  where
    commonCode =
      case Document.mkDiagnosticCode
        ("tikz." <> Text.pack (show (Bounded.diagnosticCode diagnostic)))
      of
        Just value -> value
        Nothing -> invariantDiagnosticCode
    invariantDiagnosticCode =
      case Document.mkDiagnosticCode "tikz.invariant" of
        Just value -> value
        Nothing -> commonCode

successorHasDestination
  :: Canvas.NodeId
  -> Canvas.Point
  -> CommonTikzDocument
  -> Bool
successorHasDestination requested destination document =
  case Document.documentSemantic document of
    Nothing -> False
    Just presentation ->
      let frame :| _ = Presentation.presentationFrames presentation
       in case Canvas.findElement
            (Canvas.NodeElement requested)
            (Presentation.frameAudiencePicture frame)
          of
            Just (Canvas.CanvasNode node) ->
              Canvas.nodePlacement node
                == Canvas.AbsolutePlacement destination Canvas.Centre
            _ -> False

mapCoordinate
  :: Rational
  -> Either TikzCanvasEditError TikzDecimal.Coordinate
mapCoordinate = mapLeft TikzCanvasCoordinateUnsupported . TikzDecimal.coordinateFromRational

mapProjection
  :: Either Bounded.MoveError value
  -> Either TikzCanvasEditError value
mapProjection = mapLeft TikzCanvasProjectionFailed

mapAdmission
  :: Either TikzAdapterError value
  -> Either TikzCanvasEditError value
mapAdmission = mapLeft TikzCanvasAdmissionFailed

mapLeft :: (left -> other) -> Either left value -> Either other value
mapLeft convert result =
  case result of
    Left failure -> Left (convert failure)
    Right value -> Right value

maybeToError :: failure -> Maybe value -> Either failure value
maybeToError failure result =
  case result of
    Nothing -> Left failure
    Just value -> Right value
