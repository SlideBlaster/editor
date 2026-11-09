{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Export
-- Description : Public multi-target export request and report contract.
--
-- Pure targets return deterministic artifacts. Rendered PDF and workspace ZIP
-- return explicit host capability plans. No function in this package prints,
-- compiles TeX, reads storage, compresses ZIP bytes, or claims those effects
-- have occurred.
module SlideBlaster.Export
  ( ExportRequest (..)
  , StandaloneHtmlOptions
  , standaloneHtmlOptions
  , RenderedPdfOptions
  , ExportOptionError (..)
  , renderedPdfOptions
  , LatexOptions
  , latexOptions
  , latexOptionsWithRoutes
  , WorkspaceArchiveOptions
  , workspaceArchiveOptions
  , planExport
  , ExportTarget (..)
  , LossPolicy (..)
  , ArtifactMediaType (..)
  , DeterministicArtifact
  , artifactPath
  , artifactMediaType
  , artifactBytes
  , WorkspaceEntry
  , workspaceEntry
  , workspaceEntryPath
  , workspaceEntryBytes
  , PrintPlan
  , printDocumentBytes
  , printOutputName
  , printPageCount
  , printPageWidthMillimetres
  , printPageHeightMillimetres
  , ArchivePlan
  , archiveOutputName
  , archiveEntries
  , CapabilityPlan (..)
  , ExportOutcome (..)
  , ExportReport
  , reportTarget
  , reportDiagnostics
  , reportOutcome
  ) where

import SlideBlaster.Export.Internal.Html
  ( HtmlPlanInput (..)
  , planRenderedPdf
  , planStandaloneHtml
  )
import SlideBlaster.Export.Internal.LatexProject
  ( planLatexProject
  )
import SlideBlaster.Export.Internal.Model
  ( expectedBeatKeys
  , presentationPageSize
  , renderedMotionDiagnostics
  )
import SlideBlaster.Export.Internal.Workspace
  ( planWorkspaceArchive
  )
import SlideBlaster.Export.Rendered
  ( RenderedBeatSet
  )
import SlideBlaster.Export.Types
  ( ArchivePlan
  , ArtifactMediaType (..)
  , CapabilityPlan (..)
  , DeterministicArtifact
  , ExportOutcome (..)
  , ExportReport
  , ExportTarget (..)
  , LossPolicy (..)
  , PrintPlan
  , WorkspaceEntry
  , archiveEntries
  , archiveOutputName
  , artifactBytes
  , artifactMediaType
  , artifactPath
  , printDocumentBytes
  , printOutputName
  , printPageCount
  , printPageHeightMillimetres
  , printPageWidthMillimetres
  , reportDiagnostics
  , reportOutcome
  , reportTarget
  , workspaceEntry
  , workspaceEntryBytes
  , workspaceEntryPath
  )
import SlideBlaster.Presentation.Route (Routes)
import SlideBlaster.Presentation
  ( Presentation
  , presentationTitle
  )

import Data.Text (Text)
import Data.Text qualified as Text

-- | Resources already bundled by the renderer plus the explicit loss policy.
data StandaloneHtmlOptions = StandaloneHtmlOptions
  [Text]
  [Text]
  !LossPolicy

-- | Construct standalone presenter options. Style and script order is
-- preserved; both lists must contain inline, self-contained source.
standaloneHtmlOptions ::
  [Text] ->
  [Text] ->
  LossPolicy ->
  StandaloneHtmlOptions
standaloneHtmlOptions = StandaloneHtmlOptions

-- | Renderer resources, suggested output name, and static-loss policy.
data RenderedPdfOptions = RenderedPdfOptions
  [Text]
  [Text]
  !Text
  !LossPolicy

-- | Invalid export option.
data ExportOptionError
  = ExportOutputNameEmpty
  | ExportOutputNameContainsPath
  deriving stock (Eq, Show)

-- | Construct rendered-PDF options. The output name is a host suggestion, not
-- a claim that browser print will return bytes at that name.
renderedPdfOptions ::
  [Text] ->
  [Text] ->
  Text ->
  LossPolicy ->
  Either ExportOptionError RenderedPdfOptions
renderedPdfOptions styles scripts outputName lossPolicy = do
  validatedName <- validateOutputName outputName
  Right
    (RenderedPdfOptions styles scripts validatedName lossPolicy)

-- | Pure LaTeX compatibility policy.
data LatexOptions = LatexOptions !LossPolicy !(Maybe Routes)

-- | Construct source-project options.
latexOptions :: LossPolicy -> LatexOptions
latexOptions policy = LatexOptions policy Nothing

-- | Source-project options for a deck with sections and routes: each section is
-- printed once in default-route order, route choices become hyperlinks, and each
-- section ends with a line linking to where each route continues.
latexOptionsWithRoutes :: LossPolicy -> Routes -> LatexOptions
latexOptionsWithRoutes policy routes = LatexOptions policy (Just routes)

-- | Suggested deterministic ZIP output name.
newtype WorkspaceArchiveOptions = WorkspaceArchiveOptions Text

-- | Construct archive options.
workspaceArchiveOptions ::
  Text ->
  Either ExportOptionError WorkspaceArchiveOptions
workspaceArchiveOptions outputName =
  WorkspaceArchiveOptions <$> validateOutputName outputName

validateOutputName :: Text -> Either ExportOptionError Text
validateOutputName outputName
  | Text.null (Text.strip outputName) = Left ExportOutputNameEmpty
  | outputName == "."
      || outputName == ".."
      || "/" `Text.isInfixOf` outputName
      || "\\" `Text.isInfixOf` outputName
      || "\NUL" `Text.isInfixOf` outputName =
      Left ExportOutputNameContainsPath
  | otherwise = Right outputName

-- | One closed request contract with target-specific valid inputs.
data ExportRequest
  = StandaloneHtmlRequest
      !Presentation
      !RenderedBeatSet
      !StandaloneHtmlOptions
  | RenderedPdfRequest
      !Presentation
      !RenderedBeatSet
      !RenderedPdfOptions
  | LatexProjectRequest
      !Presentation
      !LatexOptions
  | WorkspaceArchiveRequest
      [WorkspaceEntry]
      !WorkspaceArchiveOptions

-- | Plan one export without performing host effects.
planExport :: ExportRequest -> ExportReport
planExport request =
  case request of
    StandaloneHtmlRequest presentation rendered options ->
      planStandaloneHtml
        (htmlInputForStandalone presentation rendered options)
    RenderedPdfRequest presentation rendered options ->
      planRenderedPdf
        (htmlInputForPdf presentation rendered options)
    LatexProjectRequest presentation (LatexOptions lossPolicy routes) ->
      planLatexProject lossPolicy routes presentation
    WorkspaceArchiveRequest entries (WorkspaceArchiveOptions outputName) ->
      planWorkspaceArchive outputName entries

htmlInputForStandalone ::
  Presentation ->
  RenderedBeatSet ->
  StandaloneHtmlOptions ->
  HtmlPlanInput
htmlInputForStandalone
  presentation
  rendered
  (StandaloneHtmlOptions styles scripts lossPolicy) =
    HtmlPlanInput
      { htmlPlanTitle = presentationTitle presentation
      , htmlPlanExpectedBeats = expectedBeatKeys presentation
      , htmlPlanRenderedBeats = rendered
      , htmlPlanStyles = styles
      , htmlPlanScripts = scripts
      , htmlPlanSemanticDiagnostics =
          renderedMotionDiagnostics
            StandaloneHtml
            lossPolicy
            presentation
            rendered
      , htmlPlanPrintOutputName = "presentation.pdf"
      , htmlPlanPageWidthMillimetres = pageWidth
      , htmlPlanPageHeightMillimetres = pageHeight
      }
    where
      (pageWidth, pageHeight) = presentationPageSize presentation

htmlInputForPdf ::
  Presentation ->
  RenderedBeatSet ->
  RenderedPdfOptions ->
  HtmlPlanInput
htmlInputForPdf
  presentation
  rendered
  (RenderedPdfOptions styles scripts outputName lossPolicy) =
    HtmlPlanInput
      { htmlPlanTitle = presentationTitle presentation
      , htmlPlanExpectedBeats = expectedBeatKeys presentation
      , htmlPlanRenderedBeats = rendered
      , htmlPlanStyles = styles
      , htmlPlanScripts = scripts
      , htmlPlanSemanticDiagnostics =
          renderedMotionDiagnostics
            RenderedPdf
            lossPolicy
            presentation
            rendered
      , htmlPlanPrintOutputName = outputName
      , htmlPlanPageWidthMillimetres = pageWidth
      , htmlPlanPageHeightMillimetres = pageHeight
      }
    where
      (pageWidth, pageHeight) = presentationPageSize presentation
