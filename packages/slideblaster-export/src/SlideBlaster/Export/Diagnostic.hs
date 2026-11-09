{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Export.Diagnostic
-- Description : Stable, scoped export diagnostics.
--
-- Export never silently drops a construct. Every known loss or approximation
-- is represented by one of these diagnostics at document, slide, node,
-- animation, asset, or workspace scope.
module SlideBlaster.Export.Diagnostic
  ( DiagnosticSeverity (..)
  , DiagnosticCode (..)
  , ExportLocation (..)
  , ExportDiagnostic
  , exportDiagnostic
  , diagnosticSeverity
  , diagnosticCode
  , diagnosticLocation
  , diagnosticMessage
  , hasFatalDiagnostics
  ) where

import Data.Text (Text)

-- | Whether export may continue.
data DiagnosticSeverity
  = ExportWarning
  | ExportFatal
  deriving stock (Eq, Ord, Show)

-- | Stable machine-readable causes reported by the bounded export planners.
data DiagnosticCode
  = MissingRenderedBeat
  | UnexpectedRenderedBeat
  | DuplicateRenderedBeat
  | UnsafeRenderedMarkup
  | ExternalHtmlDependency
  | UnsupportedAnimation
  | SampledAnimation
  | LatexTextMayReflow
  | LatexFontMaySubstitute
  | LatexUnsupportedContent
  | LatexUnsupportedObject
  | LatexUnsupportedTheme
  | LatexUnsupportedAnimation
  | LatexMasterLayoutOmitted
  | LatexShapePresetApproximation
  | LatexUnsupportedPlacement
  | LatexUnsupportedGeometry
  | LatexUnsupportedFurniture
  | UnsafeWorkspacePath
  | DuplicateWorkspacePath
  | ExcludedGitMetadata
  | InternalExportInvariant
  deriving stock (Eq, Ord, Show)

-- | Semantic location affected by a diagnostic.
--
-- Identifiers are stable textual projections of the public presentation and
-- canvas identities. They are not DOM identifiers.
data ExportLocation
  = DocumentLocation
  | SlideLocation Text
  | NodeLocation Text Text
  | AnimationLocation Text (Maybe Text) Text
  | AssetLocation Text
  | WorkspacePathLocation Text
  deriving stock (Eq, Ord, Show)

-- | One warning or fatal export fact.
data ExportDiagnostic = ExportDiagnostic
  { diagnosticSeverity :: !DiagnosticSeverity
  , diagnosticCode :: !DiagnosticCode
  , diagnosticLocation :: !ExportLocation
  , diagnosticMessage :: !Text
  }
  deriving stock (Eq, Show)

-- | Construct a diagnostic.
exportDiagnostic ::
  DiagnosticSeverity ->
  DiagnosticCode ->
  ExportLocation ->
  Text ->
  ExportDiagnostic
exportDiagnostic = ExportDiagnostic

-- | Whether any diagnostic forbids an artifact or capability plan.
hasFatalDiagnostics :: [ExportDiagnostic] -> Bool
hasFatalDiagnostics = any ((== ExportFatal) . diagnosticSeverity)
