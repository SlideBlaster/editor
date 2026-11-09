{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Export.Internal.Html
-- Description : Deterministic standalone and print-document writers.
module SlideBlaster.Export.Internal.Html
  ( HtmlPlanInput (..)
  , planStandaloneHtml
  , planRenderedPdf
  ) where

import SlideBlaster.Export.Diagnostic
  ( DiagnosticCode
      ( DuplicateRenderedBeat
      , ExternalHtmlDependency
      , MissingRenderedBeat
      , UnexpectedRenderedBeat
      , UnsafeRenderedMarkup
      )
  , DiagnosticSeverity (ExportFatal)
  , ExportDiagnostic
  , ExportLocation (DocumentLocation, SlideLocation)
  , exportDiagnostic
  , hasFatalDiagnostics
  )
import SlideBlaster.Export.Internal.Report
  ( artifactsReport
  , capabilityReport
  , deterministicArtifact
  , printPlan
  , rejectedReport
  )
import SlideBlaster.Export.Rendered
  ( BeatKey
  , RenderedBeat
  , RenderedBeatSet
  , beatKeyFrameId
  , beatKeyStepNumber
  , renderedBeatKey
  , renderedBeatMarkup
  , renderedBeats
  )
import SlideBlaster.Export.Types
  ( ArtifactMediaType (HtmlDocument)
  , CapabilityPlan (PrintRenderedBeats)
  , ExportReport
  , ExportTarget (RenderedPdf, StandaloneHtml)
  )

import Data.ByteString (ByteString)
import Data.List (group, sort)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Numeric.Natural (Natural)

-- | Fully supplied, effect-free input to the renderer-native writers.
data HtmlPlanInput = HtmlPlanInput
  { htmlPlanTitle :: Text
  , htmlPlanExpectedBeats :: [BeatKey]
  , htmlPlanRenderedBeats :: RenderedBeatSet
  , htmlPlanStyles :: [Text]
  , htmlPlanScripts :: [Text]
  , htmlPlanSemanticDiagnostics :: [ExportDiagnostic]
  , htmlPlanPrintOutputName :: Text
  , htmlPlanPageWidthMillimetres :: Natural
  , htmlPlanPageHeightMillimetres :: Natural
  }
  deriving stock (Eq, Show)

-- | Emit one self-contained offline presenter document.
planStandaloneHtml :: HtmlPlanInput -> ExportReport
planStandaloneHtml input
  | hasFatalDiagnostics diagnostics =
      rejectedReport StandaloneHtml diagnostics
  | otherwise =
      artifactsReport
        StandaloneHtml
        diagnostics
        ( NonEmpty.singleton
            ( deterministicArtifact
                "index.html"
                HtmlDocument
                (renderDocument InteractiveDocument input orderedBeats)
            )
        )
  where
    (validationDiagnostics, orderedBeats) = validateInput input
    diagnostics =
      htmlPlanSemanticDiagnostics input <> validationDiagnostics

-- | Produce a print document and require browser/native print execution.
--
-- This function deliberately never returns bytes labelled as a PDF.
planRenderedPdf :: HtmlPlanInput -> ExportReport
planRenderedPdf input
  | hasFatalDiagnostics diagnostics =
      rejectedReport RenderedPdf diagnostics
  | otherwise =
      capabilityReport
        RenderedPdf
        diagnostics
        ( PrintRenderedBeats
            ( printPlan
                (renderDocument PrintDocument input orderedBeats)
                (htmlPlanPrintOutputName input)
                (length orderedBeats)
                (htmlPlanPageWidthMillimetres input)
                (htmlPlanPageHeightMillimetres input)
            )
        )
  where
    (validationDiagnostics, orderedBeats) = validateInput input
    diagnostics =
      htmlPlanSemanticDiagnostics input <> validationDiagnostics

data DocumentMode
  = InteractiveDocument
  | PrintDocument
  deriving stock (Eq, Show)

validateInput :: HtmlPlanInput -> ([ExportDiagnostic], [RenderedBeat])
validateInput input =
  ( duplicateDiagnostics
      <> missingDiagnostics
      <> unexpectedDiagnostics
      <> concatMap validateRenderedBeat supplied
      <> validateStyleBundles (htmlPlanStyles input)
      <> validateScriptBundles (htmlPlanScripts input)
  , mapMaybe (`lookupBeat` supplied) expected
  )
  where
    expected = htmlPlanExpectedBeats input
    supplied = renderedBeats (htmlPlanRenderedBeats input)
    expectedSet = Set.fromList expected
    suppliedAddresses = renderedBeatKey <$> supplied
    suppliedSet = Set.fromList suppliedAddresses
    duplicateAddresses =
      (firstOfEach . filter ((> 1) . length) . group . sort) suppliedAddresses
    duplicateDiagnostics =
      diagnosticForAddress
        ExportFatal
        DuplicateRenderedBeat
        "The renderer supplied this beat more than once."
        <$> duplicateAddresses
    missingDiagnostics =
      diagnosticForAddress
        ExportFatal
        MissingRenderedBeat
        "The renderer did not supply this presentation beat."
        <$> filter (`Set.notMember` suppliedSet) expected
    unexpectedDiagnostics =
      diagnosticForAddress
        ExportFatal
        UnexpectedRenderedBeat
        "The renderer supplied a beat outside this presentation revision."
        <$> filter (`Set.notMember` expectedSet) suppliedAddresses

firstOfEach :: [[value]] -> [value]
firstOfEach = foldr appendFirst []
  where
    appendFirst values rest =
      case values of
        [] -> rest
        value : _ -> value : rest

lookupBeat :: BeatKey -> [RenderedBeat] -> Maybe RenderedBeat
lookupBeat address = findMatching
  where
    findMatching candidates =
      case candidates of
        [] -> Nothing
        candidate : rest
          | renderedBeatKey candidate == address -> Just candidate
          | otherwise -> findMatching rest

validateRenderedBeat :: RenderedBeat -> [ExportDiagnostic]
validateRenderedBeat beat =
  scriptDiagnostics <> dependencyDiagnostics
  where
    markup = renderedBeatMarkup beat
    lowerMarkup = Text.toCaseFold markup
    scriptDiagnostics
      | "<script" `Text.isInfixOf` lowerMarkup =
          [ diagnosticForAddress
              ExportFatal
              UnsafeRenderedMarkup
              "Rendered beat markup contains an executable script element."
              (renderedBeatKey beat)
          ]
      | otherwise = []
    dependencyDiagnostics
      | markupHasExternalDependency lowerMarkup =
          [ diagnosticForAddress
              ExportFatal
              ExternalHtmlDependency
              "Rendered beat markup contains a resource that is not embedded."
              (renderedBeatKey beat)
          ]
      | otherwise = []

validateStyleBundles :: [Text] -> [ExportDiagnostic]
validateStyleBundles styles
  | any styleIsUnsafe styles =
      [ exportDiagnostic
          ExportFatal
          ExternalHtmlDependency
          DocumentLocation
          "A bundled stylesheet imports or references a resource that is not embedded."
      ]
  | otherwise = []
  where
    styleIsUnsafe style =
      let folded = Text.toCaseFold style
       in "</style" `Text.isInfixOf` folded
            || "@import" `Text.isInfixOf` folded
            || hasNonDataCssUrl folded

validateScriptBundles :: [Text] -> [ExportDiagnostic]
validateScriptBundles scripts
  | any scriptIsUnsafe scripts =
      [ exportDiagnostic
          ExportFatal
          ExternalHtmlDependency
          DocumentLocation
          "A bundled runtime script escapes its inline element or requests an external module."
      ]
  | otherwise = []
  where
    scriptIsUnsafe script =
      let folded = Text.toCaseFold script
       in "</script" `Text.isInfixOf` folded
            || "import(" `Text.isInfixOf` folded
            || "import " `Text.isInfixOf` folded
            || "fetch(" `Text.isInfixOf` folded
            || "xmlhttprequest" `Text.isInfixOf` folded
            || "websocket(" `Text.isInfixOf` folded
            || "eventsource(" `Text.isInfixOf` folded
            || "sendbeacon(" `Text.isInfixOf` folded

markupHasExternalDependency :: Text -> Bool
markupHasExternalDependency markup =
  any (any referenceIsExternal . attributeValues markup) resourceAttributes
    || any (tagHasExternalHref markup) hrefResourceTags
    || "<iframe" `Text.isInfixOf` markup
    || "<object" `Text.isInfixOf` markup
    || "<embed" `Text.isInfixOf` markup
    || "@import" `Text.isInfixOf` markup
    || hasNonDataCssUrl markup
  where
    resourceAttributes = ["src", "srcset", "poster"]
    hrefResourceTags = ["link", "use", "image"]

tagHasExternalHref :: Text -> Text -> Bool
tagHasExternalHref source tagName =
  go source
  where
    opening = "<" <> tagName
    go remaining =
      case Text.breakOn opening remaining of
        (_, suffix)
          | Text.null suffix -> False
        (_, suffix) ->
          let afterName = Text.drop (Text.length opening) suffix
              (tagBody, afterTag) = Text.breakOn ">" afterName
              references =
                attributeValues tagBody "href"
                  <> attributeValues tagBody "xlink:href"
           in if tagNameBoundary afterName
                then any referenceIsExternal references
                  || go (Text.drop 1 afterTag)
                else go afterName

tagNameBoundary :: Text -> Bool
tagNameBoundary afterName =
  case Text.uncons afterName of
    Nothing -> True
    Just (character, _) ->
      character == ' '
        || character == '\t'
        || character == '\n'
        || character == '\r'
        || character == '>'
        || character == '/'

referenceIsExternal :: Text -> Bool
referenceIsExternal reference =
  let stripped = Text.strip reference
      folded = Text.toCaseFold stripped
   in not (Text.null stripped)
        && not ("data:" `Text.isPrefixOf` folded)
        && not ("#" `Text.isPrefixOf` folded)

attributeValues :: Text -> Text -> [Text]
attributeValues source attribute = go source
  where
    go remaining =
      case Text.breakOn attribute remaining of
        (_, suffix)
          | Text.null suffix -> []
        (before, suffix) ->
          let afterName = Text.drop (Text.length attribute) suffix
              retry = go afterName
           in if not (attributeBoundary before)
                then retry
                else
                  case Text.uncons (Text.stripStart afterName) of
                    Just ('=', afterEquals) ->
                      let (value, rest) = takeAttributeValue afterEquals
                       in value : go rest
                    _ -> retry

attributeBoundary :: Text -> Bool
attributeBoundary before =
  case Text.unsnoc before of
    Nothing -> True
    Just (_, character) ->
      character == '<'
        || character == ' '
        || character == '\t'
        || character == '\n'
        || character == '\r'

takeAttributeValue :: Text -> (Text, Text)
takeAttributeValue source =
  case Text.uncons (Text.stripStart source) of
    Nothing -> ("", "")
    Just ('"', rest) -> Text.breakOn "\"" rest
    Just ('\'', rest) -> Text.breakOn "'" rest
    Just (_, _) ->
      Text.break
        (\character -> character == ' ' || character == '\t' || character == '>')
        (Text.stripStart source)

hasNonDataCssUrl :: Text -> Bool
hasNonDataCssUrl source =
  case Text.breakOn "url(" source of
    (_, suffix)
      | Text.null suffix -> False
    (_, suffix) ->
      let afterOpen = Text.drop 4 suffix
          (reference, rest) = Text.breakOn ")" afterOpen
          cleaned = Text.dropAround isCssQuote (Text.strip reference)
       in referenceIsExternal cleaned
            || hasNonDataCssUrl (Text.drop 1 rest)
  where
    isCssQuote character = character == '"' || character == '\''

diagnosticForAddress ::
  DiagnosticSeverity ->
  DiagnosticCode ->
  Text ->
  BeatKey ->
  ExportDiagnostic
diagnosticForAddress severity code message address =
  exportDiagnostic
    severity
    code
    (SlideLocation (renderBeatAddress address))
    message

renderBeatAddress :: BeatKey -> Text
renderBeatAddress address =
  "frame "
    <> beatKeyFrameId address
    <> ", step "
    <> Text.pack (show (beatKeyStepNumber address))

renderDocument ::
  DocumentMode ->
  HtmlPlanInput ->
  [RenderedBeat] ->
  ByteString
renderDocument mode input beats =
  Text.Encoding.encodeUtf8
    ( Text.concat
        [ "<!doctype html>\n"
        , "<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        , "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
        , "<title>"
        , escapeHtml (htmlPlanTitle input)
        , "</title>\n<style>\n"
        , baseStyle mode input
        , "\n"
        , Text.intercalate "\n" (htmlPlanStyles input)
        , "\n</style>\n</head>\n<body>\n"
        , "<main id=\"sb-deck\" data-sb-mode=\""
        , modeName mode
        , "\">\n"
        , Text.concat (zipWith renderBeat [0 :: Int ..] beats)
        , "</main>\n"
        , renderScripts mode (htmlPlanScripts input)
        , "</body>\n</html>\n"
        ]
    )

modeName :: DocumentMode -> Text
modeName mode =
  case mode of
    InteractiveDocument -> "interactive"
    PrintDocument -> "print"

baseStyle :: DocumentMode -> HtmlPlanInput -> Text
baseStyle mode input =
  Text.concat
    [ ":root{color-scheme:light dark}*{box-sizing:border-box}"
    , "html,body{margin:0;min-height:100%;background:#111}"
    , "#sb-deck{margin:0 auto}.sb-beat{position:relative;overflow:hidden;"
    , "width:100vw;height:100vh;background:white;color:black}"
    , ".sb-beat[hidden]{display:none}"
    , "@media print{"
    , "@page{size:"
    , Text.pack (show (htmlPlanPageWidthMillimetres input))
    , "mm "
    , Text.pack (show (htmlPlanPageHeightMillimetres input))
    , "mm;margin:0}"
    , "html,body,#sb-deck{background:white;width:auto;height:auto}"
    , ".sb-beat,.sb-beat[hidden]{display:block;width:"
    , Text.pack (show (htmlPlanPageWidthMillimetres input))
    , "mm;height:"
    , Text.pack (show (htmlPlanPageHeightMillimetres input))
    , "mm;break-after:page;page-break-after:always}"
    , ".sb-beat:last-child{break-after:auto;page-break-after:auto}}"
    , case mode of
        InteractiveDocument -> ""
        PrintDocument -> ".sb-beat,.sb-beat[hidden]{display:block}"
    ]

renderBeat :: Int -> RenderedBeat -> Text
renderBeat index beat =
  Text.concat
    [ "<section class=\"sb-beat"
    , if index == 0 then " sb-active" else ""
    , "\" data-sb-index=\""
    , Text.pack (show index)
    , "\" data-sb-frame=\""
    , escapeHtml (beatKeyFrameId address)
    , "\" data-sb-step=\""
    , Text.pack (show (beatKeyStepNumber address))
    , "\""
    , if index == 0
        then " aria-hidden=\"false\""
        else " aria-hidden=\"true\" hidden"
    , ">\n"
    , renderedBeatMarkup beat
    , "\n</section>\n"
    ]
  where
    address = renderedBeatKey beat

renderScripts :: DocumentMode -> [Text] -> Text
renderScripts mode scripts =
  Text.concat
    [ case mode of
        InteractiveDocument ->
          "<script>\n" <> presenterRuntime <> "\n</script>\n"
        PrintDocument -> ""
    , Text.concat
        ( (\script -> "<script>\n" <> script <> "\n</script>\n")
            <$> scripts
        )
    ]

presenterRuntime :: Text
presenterRuntime =
  Text.intercalate
    "\n"
    [ "(()=>{'use strict';"
    , "const beats=[...document.querySelectorAll('.sb-beat')];"
    , "let current=0;"
    , "const show=(next)=>{"
    , "if(next<0||next>=beats.length)return;"
    , "beats.forEach((beat,index)=>{"
    , "const active=index===next;"
    , "beat.hidden=!active;"
    , "beat.setAttribute('aria-hidden',active?'false':'true');"
    , "beat.classList.toggle('sb-active',active);"
    , "});current=next;};"
    , "addEventListener('keydown',(event)=>{"
    , "if(['ArrowRight','ArrowDown','PageDown',' '].includes(event.key)){"
    , "event.preventDefault();show(current+1);}"
    , "if(['ArrowLeft','ArrowUp','PageUp'].includes(event.key)){"
    , "event.preventDefault();show(current-1);}"
    , "if(event.key==='Home'){event.preventDefault();show(0);}"
    , "if(event.key==='End'){event.preventDefault();show(beats.length-1);}"
    , "});show(0);})();"
    ]

escapeHtml :: Text -> Text
escapeHtml =
  Text.concatMap escapeCharacter
  where
    escapeCharacter character =
      case character of
        '&' -> "&amp;"
        '<' -> "&lt;"
        '>' -> "&gt;"
        '"' -> "&quot;"
        '\'' -> "&#39;"
        _ -> Text.singleton character
