{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Export.Internal.Latex
-- Description : Pure LaTeX compatibility projection and project writer.
module SlideBlaster.Export.Internal.Latex
  ( LatexProjection
  , projectionText
  , routeTarget
  , projectionDiagnostics
  , projectContent
  , escapeLatexText
  , contentRouteIds
  ) where

import SlideBlaster.Canvas
  ( Content
  , ContentItem (..)
  , ContentNode (..)
  , ContainerKind (..)
  , DerivedState (..)
  , Dialect (..)
  , InlineMark (..)
  , ListKind (..)
  , OverlayDirective (..)
  , OverlayHook (..)
  , OverlayStep
  , StepRange
  , contentNodes
  , identifierText
  , overlayStepNumber
  , provenanceDialect
  , sourceBackedReference
  , stepRangeEnd
  , stepRangeStart
  )
import SlideBlaster.Export.Diagnostic
  ( DiagnosticCode (LatexUnsupportedContent)
  , DiagnosticSeverity (ExportFatal, ExportWarning)
  , ExportDiagnostic
  , ExportLocation (NodeLocation)
  , exportDiagnostic
  )
import SlideBlaster.Export.Types
  ( LossPolicy (PermitDocumentedApproximation, RejectLoss)
  )

import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text

-- | Projected source plus every fidelity fact discovered while producing it.
data LatexProjection = LatexProjection
  { projectionText :: Text
  , projectionDiagnostics :: [ExportDiagnostic]
  }
  deriving stock (Eq, Show)

-- | Project recursively structured mixed-dialect content to LaTeX.
--
-- Authored LaTeX text and opaque math remain literal. Supported semantic
-- Markdown/HTML constructs are written canonically. Every unsupported
-- construct contributes a scoped fatal diagnostic unless it has the one
-- explicitly documented visual approximation admitted by the loss policy.
projectContent ::
  LossPolicy ->
  Text ->
  Text ->
  Content ->
  LatexProjection
projectContent lossPolicy slideReference nodeReference =
  projectNodes lossPolicy slideReference nodeReference . contentNodes

projectNodes ::
  LossPolicy ->
  Text ->
  Text ->
  [ContentNode] ->
  LatexProjection
projectNodes lossPolicy slideReference nodeReference =
  foldMapProjection
    (projectNode lossPolicy slideReference nodeReference)

projectNode ::
  LossPolicy ->
  Text ->
  Text ->
  ContentNode ->
  LatexProjection
projectNode lossPolicy slideReference nodeReference node =
  case node of
    TextRun provenance value ->
      textProjection
        ( if provenanceDialect provenance == LaTeX
            then value
            else escapeLatexText value
        )
    StyledRun _ marks children ->
      applyMarks
        lossPolicy
        slideReference
        nodeReference
        (NonEmpty.toList marks)
        (projectNodes lossPolicy slideReference nodeReference children)
    TransparentContainer _ kind children ->
      projectContainer
        lossPolicy
        slideReference
        nodeReference
        kind
        children
    ListContent _ kind items ->
      projectList
        lossPolicy
        slideReference
        nodeReference
        kind
        (NonEmpty.toList items)
    OpaqueMath _ _ value ->
      textProjection value
    ImageContent {} ->
      unsupportedProjection
        slideReference
        nodeReference
        "Image content requires an asset-copy capability that is not implemented in this slice."
    IncludeContent _ _ state ->
      case state of
        DerivedReady nested ->
          projectContent lossPolicy slideReference nodeReference nested
        DerivedUnresolved ->
          unresolvedProjection "Included content has not been resolved."
        DerivedLoading ->
          unresolvedProjection "Included content is still loading."
        DerivedFailed _ ->
          unresolvedProjection "Included content failed to resolve."
    TableContent _ _ ->
      unsupportedProjection
        slideReference
        nodeReference
        "Semantic tables require a row/column-span-aware LaTeX writer."
    CitationContent _ keys _ ->
      textProjection
        ( "\\cite{"
            <> Text.intercalate
              ","
              (identifierText <$> NonEmpty.toList keys)
            <> "}"
        )
    CompiledFigureContent {} ->
      unsupportedProjection
        slideReference
        nodeReference
        "Compiled figures require an asset-copy and includegraphics export capability."
    CodeContent {} ->
      unsupportedProjection
        slideReference
        nodeReference
        "Code listings are not yet projected to LaTeX (lane I wires listing export)."
    LineBreak {} -> textProjection "\\\\{}"
    OverlayContent hook children ->
      wrapOverlay
        hook
        (projectNodes lossPolicy slideReference nodeReference children)
    OverlayPauseContent _ directive ->
      textProjection
        ( case directive of
            PauseNext -> "\\pause{}"
            PauseAt step -> "\\pause[" <> renderStep step <> "]"
        )
    UnsupportedContent sourceBacked ->
      unsupportedProjection
        slideReference
        nodeReference
        ( "Source-backed content "
            <> identifierText (sourceBackedReference sourceBacked)
            <> " has no total LaTeX projection."
        )
  where
    unresolvedProjection =
      unsupportedProjection slideReference nodeReference

projectContainer ::
  LossPolicy ->
  Text ->
  Text ->
  ContainerKind ->
  [ContentNode] ->
  LatexProjection
projectContainer lossPolicy slideReference nodeReference kind children =
  case kind of
    -- a route choice: a link to the first slide after this one on that route
    GenericContainer name
      | Just route <- Text.stripPrefix "route:" name ->
          surroundProjection
            ("\\hyperlink{" <> routeTarget slideReference route <> "}{")
            "}"
            (projectNodes lossPolicy slideReference nodeReference children)
    GenericContainer _ ->
      projectNodes lossPolicy slideReference nodeReference children
    ColumnsContainer ->
      unsupportedProjection
        slideReference
        nodeReference
        "Column structure has no bounded LaTeX projection in this slice."
    MatrixContainer ->
      unsupportedProjection
        slideReference
        nodeReference
        "Matrix structure has no bounded LaTeX projection in this slice."
    TableContainer ->
      unsupportedProjection
        slideReference
        nodeReference
        "A semantic table without its literal tabular source cannot be projected."
    BoxContainer _ ->
      unsupportedProjection
        slideReference
        nodeReference
        "Boxes (sbbox) are not yet projected to LaTeX (lane I wires box export)."
    FigureContainer _ ->
      projectNodes lossPolicy slideReference nodeReference children
    ColumnContainer _ ->
      projectNodes lossPolicy slideReference nodeReference children
    HeadingContainer _ ->
      projectNodes lossPolicy slideReference nodeReference children

projectList ::
  LossPolicy ->
  Text ->
  Text ->
  ListKind ->
  [ContentItem] ->
  LatexProjection
projectList lossPolicy slideReference nodeReference kind items =
  surroundProjection
    ("\\begin{" <> environment <> "}")
    ("\\end{" <> environment <> "}")
    (foldMapProjection projectItem items)
  where
    environment =
      case kind of
        UnorderedList -> "itemize"
        OrderedList -> "enumerate"
    projectItem item =
      appendProjection
        (textProjection ("\\item" <> renderItemOverlay (contentItemOverlay item) <> " "))
        (projectNodes lossPolicy slideReference nodeReference (contentItemBody item))

applyMarks ::
  LossPolicy ->
  Text ->
  Text ->
  [InlineMark] ->
  LatexProjection ->
  LatexProjection
applyMarks lossPolicy slideReference nodeReference marks initial =
  foldr applyMark initial marks
  where
    applyMark mark projected =
      case mark of
        Strong -> commandProjection "\\textbf" projected
        Emphasis -> commandProjection "\\emph" projected
        Underline -> commandProjection "\\underline" projected
        Strike -> commandProjection "\\sout" projected
        InlineCode -> commandProjection "\\texttt" projected
        LinkTarget target ->
          surroundProjection
            ("\\href{" <> escapeLatexArgument target <> "}{")
            "}"
            projected
        Highlight ->
          approximateVisualMark
            lossPolicy
            slideReference
            nodeReference
            "Highlight styling is omitted from the generated LaTeX source."
            projected
        InlineColour _ ->
          approximateVisualMark
            lossPolicy
            slideReference
            nodeReference
            "Inline colour styling is omitted from the generated LaTeX source."
            projected

approximateVisualMark ::
  LossPolicy ->
  Text ->
  Text ->
  Text ->
  LatexProjection ->
  LatexProjection
approximateVisualMark lossPolicy slideReference nodeReference message projected =
  projected
    { projectionDiagnostics =
        projectionDiagnostics projected
          <> [ exportDiagnostic
                 severity
                 LatexUnsupportedContent
                 (NodeLocation slideReference nodeReference)
                 message
             ]
    }
  where
    severity =
      case lossPolicy of
        RejectLoss -> ExportFatal
        PermitDocumentedApproximation -> ExportWarning

wrapOverlay :: OverlayHook -> LatexProjection -> LatexProjection
wrapOverlay hook projected =
  case hook of
    AlwaysVisible -> projected
    VisibleDuring ranges ->
      surroundProjection
        ("\\only<" <> renderRanges (NonEmpty.toList ranges) <> ">{")
        "}"
        projected

renderItemOverlay :: OverlayHook -> Text
renderItemOverlay hook =
  case hook of
    AlwaysVisible -> ""
    VisibleDuring ranges ->
      "<" <> renderRanges (NonEmpty.toList ranges) <> ">"

renderRanges :: [StepRange] -> Text
renderRanges = Text.intercalate "," . fmap renderRange

renderRange :: StepRange -> Text
renderRange range =
  case (stepRangeStart range, stepRangeEnd range) of
    (Nothing, Nothing) -> "1-"
    (Just start, Nothing) -> renderStep start <> "-"
    (Nothing, Just end) -> "-" <> renderStep end
    (Just start, Just end)
      | start == end -> renderStep start
      | otherwise -> renderStep start <> "-" <> renderStep end

renderStep :: OverlayStep -> Text
renderStep = Text.pack . show . overlayStepNumber

unsupportedProjection :: Text -> Text -> Text -> LatexProjection
unsupportedProjection slideReference nodeReference message =
  LatexProjection
    { projectionText = ""
    , projectionDiagnostics =
        [ exportDiagnostic
            ExportFatal
            LatexUnsupportedContent
            (NodeLocation slideReference nodeReference)
            message
        ]
    }

textProjection :: Text -> LatexProjection
textProjection value =
  LatexProjection
    { projectionText = value
    , projectionDiagnostics = []
    }

appendProjection :: LatexProjection -> LatexProjection -> LatexProjection
appendProjection left right =
  LatexProjection
    { projectionText = projectionText left <> projectionText right
    , projectionDiagnostics =
        projectionDiagnostics left <> projectionDiagnostics right
    }

foldMapProjection ::
  (value -> LatexProjection) ->
  [value] ->
  LatexProjection
foldMapProjection project =
  foldr (appendProjection . project) (textProjection "")

surroundProjection ::
  Text ->
  Text ->
  LatexProjection ->
  LatexProjection
surroundProjection before after projected =
  projected
    { projectionText = before <> projectionText projected <> after
    }

commandProjection :: Text -> LatexProjection -> LatexProjection
commandProjection command =
  surroundProjection (command <> "{") "}"

-- | Escape literal prose for a LaTeX text argument.
escapeLatexText :: Text -> Text
escapeLatexText =
  Text.concatMap escapeCharacter
  where
    escapeCharacter character =
      case character of
        '\\' -> "\\textbackslash{}"
        '{' -> "\\{"
        '}' -> "\\}"
        '$' -> "\\$"
        '&' -> "\\&"
        '#' -> "\\#"
        '%' -> "\\%"
        '_' -> "\\_"
        '^' -> "\\textasciicircum{}"
        '~' -> "\\textasciitilde{}"
        _ -> Text.singleton character

escapeLatexArgument :: Text -> Text
escapeLatexArgument =
  Text.concatMap escapeCharacter
  where
    escapeCharacter character =
      case character of
        '\\' -> "\\string\\"
        '{' -> "\\{"
        '}' -> "\\}"
        '%' -> "\\%"
        '#' -> "\\#"
        _ -> Text.singleton character

-- | Hypertarget name of the slide a route leads to from a choice slide.
routeTarget :: Text -> Text -> Text
routeTarget slideReference route = "sbroute-" <> slideReference <> "-" <> route

-- | Route ids of the @\\route@ choices in content, in reading order.
contentRouteIds :: Content -> [Text]
contentRouteIds = concatMap node . contentNodes
  where
    node n = case n of
      TransparentContainer _ (GenericContainer name) children
        | Just route <- Text.stripPrefix "route:" name -> [route]
        | otherwise -> concatMap node children
      TransparentContainer _ _ children -> concatMap node children
      StyledRun _ _ children -> concatMap node children
      OverlayContent _ children -> concatMap node children
      ListContent _ _ items -> concatMap (concatMap node . contentItemBody) (NonEmpty.toList items)
      _ -> []
