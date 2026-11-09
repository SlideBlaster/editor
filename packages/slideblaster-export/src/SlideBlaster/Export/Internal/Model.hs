{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Export.Internal.Model
-- Description : Total projections from public presentation semantics.
--
-- This module owns only target-planning views. It never introduces a second
-- presentation or picture identity: renderer keys, animation scopes, and page
-- geometry are total projections from public values.
module SlideBlaster.Export.Internal.Model
  ( expectedBeatKeys
  , renderedMotionDiagnostics
  , latexAnimationDiagnostics
  , presentationPageSize
  , elementReference
  ) where

import SlideBlaster.Canvas
  ( ElementId (..)
  , identifierText
  )
import SlideBlaster.Export.Diagnostic
  ( DiagnosticCode
      ( LatexUnsupportedAnimation
      , SampledAnimation
      , UnsupportedAnimation
      )
  , DiagnosticSeverity (ExportFatal, ExportWarning)
  , ExportDiagnostic
  , ExportLocation (AnimationLocation)
  , exportDiagnostic
  )
import SlideBlaster.Export.Rendered
  ( BeatKey
  , RenderedBeat
  , RenderedBeatSet
  , RenderedMotion (..)
  , beatKeyFor
  , renderedBeatKey
  , renderedBeatMotion
  , renderedBeats
  )
import SlideBlaster.Export.Types
  ( ExportTarget (RenderedPdf, StandaloneHtml)
  , LossPolicy (PermitDocumentedApproximation, RejectLoss)
  )
import SlideBlaster.Presentation
  ( Animation
  , AnimationImportance (DecorativeMotion, EssentialMotion)
  , Beat
  , Frame
  , Presentation
  , StaticSample (FinalSample, InitialSample)
  , animationId
  , animationIdText
  , animationImportance
  , animationTargetElement
  , animationTimelineAnimations
  , animationTracks
  , aspectRatioHeight
  , aspectRatioWidth
  , beatAnimations
  , beatFrameId
  , flattenBeats
  , frameAnimations
  , frameId
  , frameIdText
  , frameNotes
  , notesAnimations
  , presentationAspectRatio
  , trackTarget
  )

import Data.List.NonEmpty qualified as NonEmpty
import Data.List.NonEmpty (NonEmpty)
import Data.Set qualified as Set
import Data.Text (Text)
import Numeric.Natural (Natural)

-- | Expected renderer keys in authoritative presenter order.
expectedBeatKeys :: Presentation -> [BeatKey]
expectedBeatKeys =
  NonEmpty.toList . fmap beatKeyFor . flattenBeats

-- | Compare renderer motion claims with animations scheduled on each public
-- beat. Missing/duplicate beat diagnostics remain the HTML planner's concern.
renderedMotionDiagnostics ::
  ExportTarget ->
  LossPolicy ->
  Presentation ->
  RenderedBeatSet ->
  [ExportDiagnostic]
renderedMotionDiagnostics target lossPolicy presentation supplied =
  concatMap
    diagnosticsForBeat
    (NonEmpty.toList (flattenBeats presentation))
  where
    diagnosticsForBeat beat =
      case lookupRenderedBeat (beatKeyFor beat) supplied of
        Nothing -> []
        Just rendered ->
          concatMap
            (diagnosticForMotion target lossPolicy beat (renderedBeatMotion rendered))
            (beatAnimations beat)

-- | Report every timed animation that a source-only LaTeX project cannot
-- execute. Decorative motion may become the authored base state only under an
-- explicit approximation policy; essential motion always rejects export.
latexAnimationDiagnostics ::
  LossPolicy ->
  NonEmpty Frame ->
  [ExportDiagnostic]
latexAnimationDiagnostics lossPolicy =
  foldMap frameDiagnostics
  where
    frameDiagnostics frame =
      let slideReference = frameIdText (frameId frame)
          audienceDiagnostics =
            diagnosticForLatex lossPolicy slideReference
              <$> animationTimelineAnimations (frameAnimations frame)
          notesDiagnostics =
            case frameNotes frame of
              Nothing -> []
              Just notes ->
                diagnosticForLatex lossPolicy (slideReference <> ":notes")
                  <$> animationTimelineAnimations (notesAnimations notes)
       in audienceDiagnostics <> notesDiagnostics

-- | Stable physical page size. One normalized aspect unit is twenty
-- millimetres, giving the default 16:9 deck a 320 mm by 180 mm page.
presentationPageSize :: Presentation -> (Natural, Natural)
presentationPageSize presentation =
  let ratio = presentationAspectRatio presentation
   in ( 20 * aspectRatioWidth ratio
      , 20 * aspectRatioHeight ratio
      )

lookupRenderedBeat :: BeatKey -> RenderedBeatSet -> Maybe RenderedBeat
lookupRenderedBeat wanted =
  go . renderedBeats
  where
    go candidates =
      case candidates of
        [] -> Nothing
        candidate : rest
          | renderedBeatKey candidate == wanted -> Just candidate
          | otherwise -> go rest

diagnosticForMotion ::
  ExportTarget ->
  LossPolicy ->
  Beat ->
  RenderedMotion ->
  Animation ->
  [ExportDiagnostic]
diagnosticForMotion target lossPolicy beat motion animation =
  case target of
    StandaloneHtml ->
      case motion of
        InteractiveMotion -> []
        StaticMotion endpoint ->
          [ animationDiagnostic
              (lossSeverity lossPolicy animation)
              SampledAnimation
              beat
              animation
              ( "Standalone HTML contains the "
                  <> sampleName endpoint
                  <> " static state instead of this timed animation."
              )
          ]
    RenderedPdf ->
      case motion of
        InteractiveMotion ->
          [ animationDiagnostic
              ExportFatal
              UnsupportedAnimation
              beat
              animation
              "Rendered PDF requires a renderer-produced static animation sample."
          ]
        StaticMotion endpoint ->
          [ animationDiagnostic
              (lossSeverity lossPolicy animation)
              SampledAnimation
              beat
              animation
              ( "Static PDF samples this timed animation at its "
                  <> sampleName endpoint
                  <> " endpoint."
              )
          ]
    _ -> []

diagnosticForLatex ::
  LossPolicy ->
  Text ->
  Animation ->
  ExportDiagnostic
diagnosticForLatex lossPolicy slideReference animation =
  exportDiagnostic
    (lossSeverity lossPolicy animation)
    LatexUnsupportedAnimation
    (animationLocation slideReference animation)
    "LaTeX source preserves the authored base state but cannot execute this timed animation."

lossSeverity :: LossPolicy -> Animation -> DiagnosticSeverity
lossSeverity lossPolicy animation =
  case animationImportance animation of
    EssentialMotion -> ExportFatal
    DecorativeMotion ->
      case lossPolicy of
        RejectLoss -> ExportFatal
        PermitDocumentedApproximation -> ExportWarning

animationDiagnostic ::
  DiagnosticSeverity ->
  DiagnosticCode ->
  Beat ->
  Animation ->
  Text ->
  ExportDiagnostic
animationDiagnostic severity code beat animation message =
  exportDiagnostic
    severity
    code
    (animationLocation (frameIdText (beatFrameId beat)) animation)
    message

animationLocation :: Text -> Animation -> ExportLocation
animationLocation slideReference animation =
  AnimationLocation
    slideReference
    (singleAnimationTarget animation)
    (animationIdText (animationId animation))

singleAnimationTarget :: Animation -> Maybe Text
singleAnimationTarget animation =
  case Set.toList targetSet of
    [target] -> elementReference <$> animationTargetElement target
    _ -> Nothing
  where
    targetSet =
      Set.fromList
        (trackTarget <$> NonEmpty.toList (animationTracks animation))

sampleName :: StaticSample -> Text
sampleName endpoint =
  case endpoint of
    InitialSample -> "initial"
    FinalSample -> "final"

-- | Stable typed element identity projection for diagnostics and generated
-- target annotations.
elementReference :: ElementId -> Text
elementReference element =
  case element of
    NodeElement identity -> "node:" <> identifierText identity
    ConnectorElement identity -> "connector:" <> identifierText identity
    GroupElement identity -> "group:" <> identifierText identity
