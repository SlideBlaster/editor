{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Export.Internal.LatexProject
-- Description : Bounded deterministic Beamer project planning.
--
-- The writer consumes only public Presentation and Canvas projections. Its
-- implemented subset emits real Beamer/TikZ source; every construct outside
-- that subset is either a documented warning-backed approximation or a fatal
-- diagnostic.
module SlideBlaster.Export.Internal.LatexProject
  ( planLatexProject
  ) where

import SlideBlaster.Canvas
  ( Anchor (..)
  , Anchor9 (..)
  , BorderPort (..)
  , CanvasObject (..)
  , CanvasUnit
  , Colour (..)
  , Connector
  , ConnectorPath
  , ConnectorSegment (..)
  , CornerOrder (..)
  , Furniture (..)
  , Group
  , LayerBarrier (..)
  , LayerEntry (..)
  , Node
  , NodePropertyPatch
  , OutlineRef (..)
  , OverlayHook (..)
  , OverlayStep
  , PageNumberFormat (..)
  , PageNumberFurniture
  , Palette
  , PathClosure (..)
  , Placement (..)
  , Point
  , PrimitiveOutline (..)
  , RelativeAdvance (..)
  , StepRange
  , Theme
  , ThemeStyle
  , Vector
  , bandFurnitureId
  , canvasUnitValue
  , connectorAnchors
  , connectorClosure
  , connectorIdentifier
  , connectorLabel
  , connectorPath
  , connectorPropertyOverrides
  , connectorSegments
  , elementOverlay
  , emptyConnectorPropertyPatch
  , emptyNodePropertyPatch
  , groupIdentifier
  , identifierText
  , logoFurnitureId
  , masterAnchors
  , masterRegions
  , nodeContent
  , nodeIdentifier
  , nodeOutline
  , nodePlacement
  , nodePropertyOverrides
  , outlineRadiusValue
  , overlayStepNumber
  , pageNumberAnchor
  , pageNumberFormat
  , paletteEntries
  , pictureEntries
  , pointX
  , pointY
  , stepRangeEnd
  , stepRangeStart
  , themeBaseConnectorPatch
  , themeBaseNodePatch
  , themeConnectorRoles
  , themeFurniture
  , themeMasterLayout
  , themeNodeRoles
  , themePalette
  , themeStyle
  , themeTypeScale
  , typeScaleEntries
  , vectorX
  , vectorY
  )
import SlideBlaster.Export.Diagnostic
  ( DiagnosticCode
      ( LatexFontMaySubstitute
      , LatexMasterLayoutOmitted
      , LatexTextMayReflow
      , LatexUnsupportedFurniture
      , LatexUnsupportedGeometry
      , LatexUnsupportedObject
      , LatexUnsupportedPlacement
      , LatexUnsupportedTheme
      )
  , DiagnosticSeverity (ExportFatal, ExportWarning)
  , ExportDiagnostic
  , ExportLocation
      ( DocumentLocation
      , NodeLocation
      )
  , exportDiagnostic
  , hasFatalDiagnostics
  )
import SlideBlaster.Export.Internal.Latex
  ( escapeLatexText
  , projectContent
  , projectionDiagnostics
  , projectionText
  , contentRouteIds
  , routeTarget
  )
import SlideBlaster.Export.Internal.Model
  ( latexAnimationDiagnostics
  )
import SlideBlaster.Export.Internal.Report
  ( artifactsReport
  , deterministicArtifact
  , rejectedReport
  )
import SlideBlaster.Export.Types
  ( ArtifactMediaType (LatexSource, LatexStyle)
  , ExportReport
  , ExportTarget (LatexProject)
  , LossPolicy (PermitDocumentedApproximation, RejectLoss)
  )
import SlideBlaster.Presentation
  ( Frame
  , Presentation
  , aspectRatioHeight
  , aspectRatioWidth
  , frameAudiencePicture
  , frameId
  , frameIdText
  , frameNotes
  , frameRotation
  , frameTitle
  , notesPicture
  , presentationAspectRatio
  , presentationFrames
  , presentationTheme
  , slideRotationDegrees
  )

import SlideBlaster.Presentation.Route (Routes)
import SlideBlaster.Presentation.Route qualified as Route
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Ratio (denominator, numerator)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding

-- | Generate a deterministic bounded Beamer project or reject it with all
-- independent compatibility diagnostics.
planLatexProject :: LossPolicy -> Maybe Routes -> Presentation -> ExportReport
planLatexProject lossPolicy routes presentation
  | hasFatalDiagnostics diagnostics =
      rejectedReport LatexProject diagnostics
  | otherwise =
      artifactsReport
        LatexProject
        diagnostics
        ( deterministicArtifact
            "deck.tex"
            LatexSource
            (Text.Encoding.encodeUtf8 deckSource)
            :| [ deterministicArtifact
                   "theme.sty"
                   LatexStyle
                   (Text.Encoding.encodeUtf8 (partText themePart))
               ]
        )
  where
    theme = presentationTheme presentation
    frames = presentationFrames presentation
    framePart =
      foldParts
        (projectFrame lossPolicy theme routes (NonEmpty.toList frames))
        (printOrder routes (NonEmpty.toList frames))
    themePart = projectTheme lossPolicy theme
    diagnostics =
      intrinsicDiagnostics
        <> masterLayoutDiagnostics theme
        <> latexAnimationDiagnostics lossPolicy frames
        <> partDiagnostics themePart
        <> partDiagnostics framePart
    deckSource =
      renderDeckEnvelope presentation (partText framePart)

data ProjectPart = ProjectPart
  { partText :: Text
  , partDiagnostics :: [ExportDiagnostic]
  }

intrinsicDiagnostics :: [ExportDiagnostic]
intrinsicDiagnostics =
  [ exportDiagnostic
      ExportWarning
      LatexTextMayReflow
      DocumentLocation
      "TeX lays out text independently, so tight canvas boxes may reflow."
  , exportDiagnostic
      ExportWarning
      LatexFontMaySubstitute
      DocumentLocation
      "The compiling TeX installation may substitute unavailable theme fonts."
  ]

masterLayoutDiagnostics :: Theme -> [ExportDiagnostic]
masterLayoutDiagnostics theme
  | null (masterRegions layout) && null (masterAnchors layout) = []
  | otherwise =
      [ exportDiagnostic
          ExportWarning
          LatexMasterLayoutOmitted
          DocumentLocation
          "Editor-only master layout regions and anchors are intentionally omitted from export."
      ]
  where
    layout = themeMasterLayout theme

renderDeckEnvelope :: Presentation -> Text -> Text
renderDeckEnvelope presentation frameSource =
  Text.concat
    [ "\\documentclass[aspectratio="
    , aspectOption presentation
    , "]{beamer}\n"
    , "\\usepackage{theme}\n"
    , "\\begin{document}\n"
    , frameSource
    , "\\end{document}\n"
    ]

aspectOption :: Presentation -> Text
aspectOption presentation =
  let ratio = presentationAspectRatio presentation
   in Text.pack (show (aspectRatioWidth ratio))
        <> Text.pack (show (aspectRatioHeight ratio))

-- | Frames as printed: with routes, each section once in default-route order.
printOrder :: Maybe Routes -> [Frame] -> [Frame]
printOrder Nothing frames = frames
printOrder (Just routes) frames =
  [f | key <- order, f <- take 1 [f | f <- frames, frameIdText (frameId f) == key]]
    <> [f | f <- frames, frameIdText (frameId f) `notElem` order]
  where
    order = Route.exportOrder routes

-- | Hypertargets a frame carries: itself, and every route choice that leads here.
frameTargets :: Maybe Routes -> [Frame] -> Frame -> Text
frameTargets Nothing _ _ = ""
frameTargets (Just routes) frames frame =
  Text.concat
    ( "\\hypertarget{sbframe-" <> key <> "}{}"
        : [ "\\hypertarget{" <> routeTarget choice route <> "}{}"
          | (choice, route) <- choices
          , Route.frameAfterChoice routes route choice == Just key
          ]
    )
  where
    key = frameIdText (frameId frame)
    choices =
      [ (frameIdText (frameId f), route)
      | f <- frames
      , route <- nubText (concat [contentRouteIds (nodeContent n) | ObjectEntry (CanvasNode n) <- pictureEntries (frameAudiencePicture f)])
      ]
    nubText = foldr (\x acc -> x : filter (/= x) acc) []

-- | At the end of a section: where each route goes next.
continueLine :: Maybe Routes -> Frame -> Text
continueLine Nothing _ = ""
continueLine (Just routes) frame =
  case [s | s <- Route.routesSections routes, take 1 (reverse (Route.sectionFrames s)) == [frameIdText (frameId frame)]] of
    section : _ | links@(_ : _) <- [link route next | (route, next) <- Route.continuations routes section] ->
      "\\par\\vfill\\hfill{\\footnotesize Continue: " <> Text.intercalate " \\quad " links <> "}\n"
    _ -> ""
  where
    link route next =
      "\\hyperlink{sbframe-" <> Text.concat (take 1 (Route.sectionFrames next)) <> "}{" <> escapeLatexText route <> ": " <> escapeLatexText (Route.sectionTitle next) <> "}"

projectFrame :: LossPolicy -> Theme -> Maybe Routes -> [Frame] -> Frame -> ProjectPart
projectFrame lossPolicy theme routes allFrames frame =
  ProjectPart
    { partText =
        Text.concat
          [ "\\begin{frame}[fragile]{"
          , escapeLatexText (frameTitle frame)
          , "}\n"
          , targetsHere
          , rotationPrefix
          , "\\begin{tikzpicture}[x=1cm,y=1cm]\n"
          , partText picturePart
          , "\\end{tikzpicture}"
          , rotationSuffix
          , continueSource
          , notesSource
          , "\n\\end{frame}\n"
          ]
    , partDiagnostics =
        partDiagnostics picturePart <> partDiagnostics notesPart
    }
  where
    slideReference = frameIdText (frameId frame)
    targetsHere = let t = frameTargets routes allFrames frame in if Text.null t then "" else t <> "\n"
    continueSource = continueLine routes frame
    picturePart =
      foldParts
        (projectLayerEntry lossPolicy (themeStyle theme) slideReference)
        (pictureEntries (frameAudiencePicture frame))
    notesPart =
      case frameNotes frame of
        Nothing -> ProjectPart "" []
        Just notes ->
          foldParts
            ( projectLayerEntry
                lossPolicy
                (themeStyle theme)
                (slideReference <> ":notes")
            )
            (pictureEntries (notesPicture notes))
    notesSource =
      case frameNotes frame of
        Nothing -> ""
        Just _ ->
          Text.concat
            [ "\n\\note{%\n"
            , "\\begin{tikzpicture}[x=1cm,y=1cm]\n"
            , partText notesPart
            , "\\end{tikzpicture}%\n"
            , "}"
            ]
    degrees = slideRotationDegrees (frameRotation frame)
    (rotationPrefix, rotationSuffix)
      | degrees == 0 = ("", "")
      | otherwise =
          ( "\\rotatebox{" <> renderRational degrees <> "}{%\n"
          , "}"
          )

projectLayerEntry ::
  LossPolicy ->
  ThemeStyle ->
  Text ->
  LayerEntry ->
  ProjectPart
projectLayerEntry lossPolicy style slideReference entry =
  case entry of
    ObjectEntry object ->
      projectObject lossPolicy style slideReference object
    BarrierEntry barrier ->
      projectBarrier lossPolicy slideReference barrier

projectObject ::
  LossPolicy ->
  ThemeStyle ->
  Text ->
  CanvasObject ->
  ProjectPart
projectObject lossPolicy style slideReference object =
  case object of
    CanvasNode node ->
      projectNodeObject lossPolicy style slideReference node
    CanvasConnector connector ->
      projectConnectorObject lossPolicy style slideReference connector
    CanvasGroup group ->
      groupComment group

projectNodeObject ::
  LossPolicy ->
  ThemeStyle ->
  Text ->
  Node ->
  ProjectPart
projectNodeObject lossPolicy style slideReference node =
  ProjectPart
    { partText =
        wrapObjectOverlay
          (elementOverlay (CanvasNode node))
          ( Text.concat
              [ "\\node["
              , Text.intercalate "," (placementOptions <> outlineOptions)
              , "] ("
              , identity
              , ")"
              , placementSource
              , " {"
              , projectionText contentPart
              , "};\n"
              ]
          )
    , partDiagnostics =
        placementDiagnostics
          <> outlineDiagnostics
          <> styleDiagnostics
          <> projectionDiagnostics contentPart
    }
  where
    identity = identifierText (nodeIdentifier node)
    location = NodeLocation slideReference identity
    (placementSource, placementOptions, placementDiagnostics) =
      projectPlacement slideReference identity (nodePlacement node)
    (outlineOptions, outlineDiagnostics) =
      projectOutline lossPolicy location (nodeOutline node)
    styleDiagnostics =
      patchDiagnostics
        lossPolicy
        location
        style
        (nodePropertyOverrides node)
    contentPart =
      projectContent
        lossPolicy
        slideReference
        identity
        (nodeContent node)

projectPlacement ::
  Text ->
  Text ->
  Placement ->
  (Text, [Text], [ExportDiagnostic])
projectPlacement slideReference identity placement =
  case placement of
    AbsolutePlacement position anchor ->
      ( " at " <> renderPoint position
      , ["anchor=" <> renderBorderPort anchor]
      , []
      )
    GeneratedPlacement position anchor ->
      ( " at " <> renderPoint position
      , ["anchor=" <> renderBorderPort anchor]
      , []
      )
    RelativeNodePlacement _ ->
      ( ""
      , []
      , [ exportDiagnostic
            ExportFatal
            LatexUnsupportedPlacement
            (NodeLocation slideReference identity)
            "Relative placement is retained semantically but its exact anchor binding is outside the bounded writer."
        ]
      )
    SourceDerivedPlacement reference ->
      ( ""
      , []
      , [ exportDiagnostic
            ExportFatal
            LatexUnsupportedPlacement
            (NodeLocation slideReference identity)
            ( "Source-derived placement "
                <> identifierText reference
                <> " cannot be regenerated without the source serializer."
            )
        ]
      )

projectOutline ::
  LossPolicy ->
  ExportLocation ->
  OutlineRef ->
  ([Text], [ExportDiagnostic])
projectOutline lossPolicy location outline =
  case outline of
    PrimitiveGeometry primitive ->
      case primitive of
        RectangleOutline -> (["rectangle"], [])
        RoundedRectangleOutline radius ->
          ( [ "rectangle"
            , "rounded corners="
                <> renderUnit (outlineRadiusValue radius)
                <> "cm"
            ]
          , []
          )
        EllipseOutline -> (["ellipse"], [])
        ArcOutline {} ->
          approximateRectangle "Arc outline is approximated by a rectangle."
    PolygonGeometry {} ->
      approximateRectangle "Polygon outline is approximated by a rectangle."
    PathGeometry {} ->
      approximateRectangle "Path outline is approximated by a rectangle."
    CompoundGeometry {} ->
      approximateRectangle "Compound outline is approximated by a rectangle."
    StencilGeometry {} ->
      ( []
      , [ exportDiagnostic
            ExportFatal
            LatexUnsupportedGeometry
            location
            "Stencil geometry has no bounded LaTeX projection."
        ]
      )
    CustomGeometry {} ->
      ( []
      , [ exportDiagnostic
            ExportFatal
            LatexUnsupportedGeometry
            location
            "Custom geometry has no bounded LaTeX projection."
        ]
      )
    UnsupportedGeometry reference ->
      ( []
      , [ exportDiagnostic
            ExportFatal
            LatexUnsupportedGeometry
            location
            ( "Source-backed geometry "
                <> identifierText reference
                <> " cannot be regenerated."
            )
        ]
      )
  where
    approximateRectangle message =
      ( ["rectangle"]
      , [ policyDiagnostic
            lossPolicy
            LatexUnsupportedGeometry
            location
            message
        ]
      )

patchDiagnostics ::
  LossPolicy ->
  ExportLocation ->
  ThemeStyle ->
  NodePropertyPatch ->
  [ExportDiagnostic]
patchDiagnostics lossPolicy location style patch
  | patch == emptyNodePropertyPatch
      && themeBaseNodePatch style == emptyNodePropertyPatch
      && all (== emptyNodePropertyPatch) (Map.elems (themeNodeRoles style)) =
      []
  | otherwise =
      [ policyDiagnostic
          lossPolicy
          LatexUnsupportedTheme
          location
          "Node theme/property styling is outside the bounded writer; geometry and content remain."
      ]

projectConnectorObject ::
  LossPolicy ->
  ThemeStyle ->
  Text ->
  Connector ->
  ProjectPart
projectConnectorObject lossPolicy style slideReference connector =
  ProjectPart
    { partText =
        wrapObjectOverlay
          (elementOverlay (CanvasConnector connector))
          ( "\\draw "
              <> partText pathPart
              <> labelSource
              <> ";\n"
          )
    , partDiagnostics =
        partDiagnostics pathPart
          <> connectorStyleDiagnostics
          <> labelDiagnostics
    }
  where
    identity = identifierText (connectorIdentifier connector)
    location = NodeLocation slideReference ("connector:" <> identity)
    pathPart =
      projectConnectorPath
        slideReference
        identity
        (connectorPath connector)
    connectorStyleDiagnostics
      | connectorPropertyOverrides connector == emptyConnectorPropertyPatch
          && themeBaseConnectorPatch style == emptyConnectorPropertyPatch
          && all
            (== emptyConnectorPropertyPatch)
            (Map.elems (themeConnectorRoles style)) =
          []
      | otherwise =
          [ policyDiagnostic
              lossPolicy
              LatexUnsupportedTheme
              location
              "Connector theme/property styling is outside the bounded writer; its path remains."
          ]
    (labelSource, labelDiagnostics) =
      case connectorLabel connector of
        Nothing -> ("", [])
        Just label ->
          let projected =
                projectContent
                  lossPolicy
                  slideReference
                  ("connector:" <> identity)
                  label
           in ( " node[midway]{"
                  <> projectionText projected
                  <> "}"
              , projectionDiagnostics projected
              )

projectConnectorPath ::
  Text ->
  Text ->
  ConnectorPath ->
  ProjectPart
projectConnectorPath slideReference identity path =
  case connectorAnchors path of
    first :| rest ->
      let targets =
            case connectorClosure path of
              OpenPath -> rest
              ClosedPath -> rest <> [first]
          segments = connectorSegments path
          firstPart = projectAnchor slideReference identity first
          segmentParts = zipWith (projectSegment slideReference identity) segments targets
          cardinalityDiagnostic
            | length targets == length segments = []
            | otherwise =
                [ exportDiagnostic
                    ExportFatal
                    LatexUnsupportedObject
                    (NodeLocation slideReference ("connector:" <> identity))
                    "Validated connector path cardinality was inconsistent."
                ]
       in ProjectPart
            { partText =
                partText firstPart
                  <> Text.concat (partText <$> segmentParts)
            , partDiagnostics =
                partDiagnostics firstPart
                  <> concatMap partDiagnostics segmentParts
                  <> cardinalityDiagnostic
            }

projectSegment ::
  Text ->
  Text ->
  ConnectorSegment ->
  Anchor ->
  ProjectPart
projectSegment slideReference identity segment target =
  let targetPart = projectAnchor slideReference identity target
      operator =
        case segment of
          StraightSegment -> " -- "
          OrthogonalSegment order ->
            case order of
              HorizontalThenVertical -> " -| "
              VerticalThenHorizontal -> " |- "
          CubicSegment firstControl secondControl ->
            " .. controls "
              <> renderPoint firstControl
              <> " and "
              <> renderPoint secondControl
              <> " .. "
   in targetPart {partText = operator <> partText targetPart}

projectAnchor :: Text -> Text -> Anchor -> ProjectPart
projectAnchor slideReference identity anchor =
  case anchor of
    NodeAnchor node port ->
      plainPart
        ( "("
            <> identifierText node
            <> "."
            <> renderBorderPort port
            <> ")"
        )
    AbsoluteAnchor position -> plainPart (renderPoint position)
    RelativeAnchor advance displacement ->
      plainPart
        ( case advance of
            KeepCurrent -> "+"
            AdvanceCurrent -> "++"
        )
        `appendPart` plainPart (renderVector displacement)
    SourceBackedAnchor reference ->
      fatalPart
        LatexUnsupportedPlacement
        (NodeLocation slideReference ("connector:" <> identity))
        ( "Source-backed connector anchor "
            <> identifierText reference
            <> " cannot be regenerated."
        )

projectBarrier :: LossPolicy -> Text -> LayerBarrier -> ProjectPart
projectBarrier lossPolicy slideReference barrier =
  case barrier of
    NamedCoordinateBarrier identity position ->
      plainPart
        ( "\\coordinate ("
            <> identifierText identity
            <> ") at "
            <> renderPoint position
            <> ";\n"
        )
    OpaqueStatementBarrier identity reference ->
      fatalPart
        LatexUnsupportedObject
        (NodeLocation slideReference ("barrier:" <> identifierText identity))
        ( "Opaque source statement "
            <> identifierText reference
            <> " cannot be regenerated."
        )
    ExplicitLayerBarrier identity layerName ->
      ProjectPart
        { partText =
            "% layer barrier "
              <> identifierText identity
              <> ": "
              <> escapeLatexText layerName
              <> "\n"
        , partDiagnostics =
            [ policyDiagnostic
                lossPolicy
                LatexUnsupportedObject
                (NodeLocation slideReference ("barrier:" <> identifierText identity))
                "Explicit layer grouping is retained only as an ordered source comment."
            ]
        }

groupComment :: Group -> ProjectPart
groupComment group =
  plainPart
    ( "% semantic group "
        <> identifierText (groupIdentifier group)
        <> "\n"
    )

projectTheme :: LossPolicy -> Theme -> ProjectPart
projectTheme lossPolicy theme =
  ProjectPart
    { partText =
        Text.concat
          [ "\\NeedsTeXFormat{LaTeX2e}\n"
          , "\\ProvidesPackage{theme}[SlideBlaster generated theme]\n"
          , "\\RequirePackage{tikz}\n"
          , "\\usetikzlibrary{positioning,calc,arrows.meta}\n"
          , "\\RequirePackage{xcolor}\n"
          , "\\RequirePackage{graphicx}\n"
          , "\\RequirePackage{hyperref}\n"
          , "\\RequirePackage[normalem]{ulem}\n"
          , "\\RequirePackage{amsmath}\n"
          , "\\RequirePackage{amssymb}\n"
          , "\\RequirePackage{booktabs}\n"
          , "\\RequirePackage{multirow}\n"
          , "\\RequirePackage{array}\n"
          , "\\RequirePackage{threeparttable}\n"
          , paletteSource (themePalette (themeStyle theme))
          , partText furniturePart
          ]
    , partDiagnostics =
        globalStyleDiagnostics lossPolicy (themeStyle theme)
          <> partDiagnostics furniturePart
    }
  where
    furniturePart =
      foldParts
        (projectFurniture lossPolicy)
        (themeFurniture theme)

paletteSource :: Palette -> Text
paletteSource paletteValue =
  Text.concat
    ( zipWith
        renderEntry
        [1 :: Int ..]
        (paletteEntries paletteValue)
    )
  where
    renderEntry index (_, colour) =
      let (red, green, blue) =
            case colour of
              RGB r g b -> (r, g, b)
              RGBA r g b _ -> (r, g, b)
       in Text.concat
            [ "\\definecolor{sbColor"
            , Text.pack (show index)
            , "}{RGB}{"
            , Text.pack (show red)
            , ","
            , Text.pack (show green)
            , ","
            , Text.pack (show blue)
            , "}\n"
            ]

globalStyleDiagnostics :: LossPolicy -> ThemeStyle -> [ExportDiagnostic]
globalStyleDiagnostics lossPolicy style =
  concat
    [ if null (typeScaleEntries (themeTypeScale style))
        then []
        else
          [ policyDiagnostic
              lossPolicy
              LatexUnsupportedTheme
              DocumentLocation
              "Named theme type-scale entries are emitted only through per-node content in the bounded writer."
          ]
    , if any hasTranslucentAlpha (paletteEntries (themePalette style))
        then
          [ policyDiagnostic
              lossPolicy
              LatexUnsupportedTheme
              DocumentLocation
              "Translucent theme palette colours are emitted as opaque RGB colours."
          ]
        else []
    ]
  where
    hasTranslucentAlpha (_, colour) =
      case colour of
        RGB {} -> False
        RGBA _ _ _ alpha -> alpha < 255

projectFurniture :: LossPolicy -> Furniture -> ProjectPart
projectFurniture lossPolicy furniture =
  case furniture of
    PageNumber value -> projectPageNumber lossPolicy value
    Logo value ->
      policyOmission
        lossPolicy
        ( "Logo furniture "
            <> identifierText (logoFurnitureId value)
            <> " requires project asset copying."
        )
    Band value ->
      policyOmission
        lossPolicy
        ("Band furniture " <> identifierText (bandFurnitureId value) <> " is outside the bounded writer.")

projectPageNumber :: LossPolicy -> PageNumberFurniture -> ProjectPart
projectPageNumber lossPolicy value =
  ProjectPart
    { partText =
        Text.concat
          [ "\\setbeamertemplate{"
          , verticalTemplate
          , "}{\\leavevmode\\hbox to \\paperwidth{"
          , horizontalBefore
          , numberSource
          , horizontalAfter
          , "}\\vskip2pt}\n"
          ]
    , partDiagnostics = anchorDiagnostics <> formatDiagnostics
    }
  where
    (verticalTemplate, anchorDiagnostics) =
      case pageNumberAnchor value of
        TopLeft -> ("headline", [])
        TopCentre -> ("headline", [])
        TopRight -> ("headline", [])
        BottomLeft -> ("footline", [])
        BottomCentre -> ("footline", [])
        BottomRight -> ("footline", [])
        _ ->
          ( "footline"
          , [ policyDiagnostic
                lossPolicy
                LatexUnsupportedFurniture
                DocumentLocation
                "Middle-anchored page number furniture is approximated in the footer."
            ]
          )
    (horizontalBefore, horizontalAfter) =
      case pageNumberAnchor value of
        TopLeft -> ("", "\\hfil")
        MiddleLeft -> ("", "\\hfil")
        BottomLeft -> ("", "\\hfil")
        TopCentre -> ("\\hfil", "\\hfil")
        MiddleCentre -> ("\\hfil", "\\hfil")
        BottomCentre -> ("\\hfil", "\\hfil")
        TopRight -> ("\\hfil", "")
        MiddleRight -> ("\\hfil", "")
        BottomRight -> ("\\hfil", "")
    (numberSource, formatDiagnostics) =
      case pageNumberFormat value of
        PageNumberOnly -> ("\\insertframenumber", [])
        PageNumberOfTotal ->
          ("\\insertframenumber/\\inserttotalframenumber", [])
        NamedPageNumberFormat name ->
          ( "\\insertframenumber"
          , [ policyDiagnostic
                lossPolicy
                LatexUnsupportedFurniture
                DocumentLocation
                ("Named page-number format " <> name <> " is approximated by the page number.")
            ]
          )

policyOmission :: LossPolicy -> Text -> ProjectPart
policyOmission lossPolicy message =
  ProjectPart
    { partText = "% omitted furniture: " <> escapeLatexText message <> "\n"
    , partDiagnostics =
        [ policyDiagnostic
            lossPolicy
            LatexUnsupportedFurniture
            DocumentLocation
            message
        ]
    }

policyDiagnostic ::
  LossPolicy ->
  DiagnosticCode ->
  ExportLocation ->
  Text ->
  ExportDiagnostic
policyDiagnostic lossPolicy code location message =
  exportDiagnostic
    severity
    code
    location
    message
  where
    severity =
      case lossPolicy of
        RejectLoss -> ExportFatal
        PermitDocumentedApproximation -> ExportWarning

fatalPart :: DiagnosticCode -> ExportLocation -> Text -> ProjectPart
fatalPart code location message =
  ProjectPart
    { partText = ""
    , partDiagnostics =
        [exportDiagnostic ExportFatal code location message]
    }

plainPart :: Text -> ProjectPart
plainPart source =
  ProjectPart
    { partText = source
    , partDiagnostics = []
    }

appendPart :: ProjectPart -> ProjectPart -> ProjectPart
appendPart left right =
  ProjectPart
    { partText = partText left <> partText right
    , partDiagnostics =
        partDiagnostics left <> partDiagnostics right
    }

foldParts :: (value -> ProjectPart) -> [value] -> ProjectPart
foldParts project =
  foldr (appendPart . project) (plainPart "")

wrapObjectOverlay :: OverlayHook -> Text -> Text
wrapObjectOverlay hook source =
  case hook of
    AlwaysVisible -> source
    VisibleDuring ranges ->
      "\\only<"
        <> renderRanges (NonEmpty.toList ranges)
        <> ">{"
        <> source
        <> "}\n"

renderRanges :: [StepRange] -> Text
renderRanges = Text.intercalate "," . fmap renderRange

renderRange :: StepRange -> Text
renderRange range =
  case
      ( stepRangeStart range
      , stepRangeEnd range
      )
    of
      (Nothing, Nothing) -> "1-"
      (Just start, Nothing) -> renderStep start <> "-"
      (Nothing, Just end) -> "-" <> renderStep end
      (Just start, Just end)
        | start == end -> renderStep start
        | otherwise -> renderStep start <> "-" <> renderStep end

renderStep :: OverlayStep -> Text
renderStep =
  Text.pack . show . overlayStepNumber

renderPoint :: Point -> Text
renderPoint value =
  "("
    <> renderUnit (pointX value)
    <> ","
    <> renderUnit (pointY value)
    <> ")"

renderVector :: Vector -> Text
renderVector value =
  "("
    <> renderUnit (vectorX value)
    <> ","
    <> renderUnit (vectorY value)
    <> ")"

renderUnit :: CanvasUnit -> Text
renderUnit = renderRational . canvasUnitValue

renderRational :: Rational -> Text
renderRational value
  | denominator value == 1 =
      Text.pack (show (numerator value))
  | otherwise =
      "{"
        <> Text.pack (show (numerator value))
        <> "/"
        <> Text.pack (show (denominator value))
        <> "}"

renderBorderPort :: BorderPort -> Text
renderBorderPort port =
  case port of
    North -> "north"
    NorthEast -> "north east"
    East -> "east"
    SouthEast -> "south east"
    South -> "south"
    SouthWest -> "south west"
    West -> "west"
    NorthWest -> "north west"
    Centre -> "center"
