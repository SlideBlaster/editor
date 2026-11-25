{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : TestAnalyzer
-- Description : A tiny stand-in deck analyzer for session tests.
module TestAnalyzer (analyzer, deckText, deck1) where

import SlideBlaster.Canvas hiding (Theme (..), Furniture (..))
import SlideBlaster.Product.Runtime.Analysis
import SlideBlaster.Product.Runtime.SlidePlan

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

deck1 :: ByteString
deck1 = deckText ["## One {#one}", "alpha", "\\pause", "beta", "## Two {#two}", "\\figure{figures/a.tikz}", "gamma"]

-- Stand-in analyzer ---------------------------------------------------------

deckText :: [Text] -> ByteString
deckText = Encoding.encodeUtf8 . Text.unlines

prov :: Provenance
prov = CanvasProvenance Markdown

analyzer :: Analyzer
analyzer = Analyzer {analyzeDeck = analyse, insertSlideAfter = insertAfter, editPicture = \_ _ _ _ _ -> Left "not offered by the test analyzer"}

sections :: ByteString -> [(Text, Text, (Int, Int), [Text])]
sections bytes = go 0 (Text.lines (Encoding.decodeUtf8 bytes)) []
  where
    go _ [] acc = finish (reverse acc)
    go offset (line : rest) acc
      | "## " `Text.isPrefixOf` line =
          let (title, ident) = splitTitle (Text.drop 3 line)
           in go (offset + width line) rest ((title, ident, (offset, offset + width line), []) : acc)
      | otherwise = case acc of
          ((t, i, (s, _), body) : older) -> go (offset + width line) rest ((t, i, (s, offset + width line), body <> [line]) : older)
          [] -> go (offset + width line) rest acc
    width line = ByteString.length (Encoding.encodeUtf8 line) + 1
    finish = id
    splitTitle t = case Text.breakOn " {#" t of
      (title, rest) | not (Text.null rest) -> (title, Text.dropEnd 1 (Text.drop 3 rest))
      (title, _) -> (title, Text.toLower (Text.replace " " "-" title))

analyse :: a -> Text -> ByteString -> Analysis
analyse _ _ bytes =
  Analysis
    { analysisTitle = "Deck"
    , analysisTheme = "default"
    , analysisFrames = frames
    , analysisDiagnostics = []
    , analysisFigures = concat figures
    , analysisImages = []
    , analysisReady = True
    , analysisSections = []
    , analysisSubsections = []
    , analysisRoutes = []
    }
  where
    secs = sections bytes
    built = [(frame, figs) | (index, (title, ident, sp, body)) <- zip [0 :: Int ..] secs, let (frame, figs) = buildFrame index title ident sp body]
    frames = fmap fst built
    figures = fmap snd built

buildFrame :: Int -> Text -> Text -> (Int, Int) -> [Text] -> (AnalyzedFrame, [FigureRequest])
buildFrame index title ident sp body =
  ( AnalyzedFrame
      { frameKey = ident
      , frameTitleText = title
      , frameSpan = sp
      , frameScene = FrameInput ident (content [TextRun prov title]) (content nodes) Nothing [] [] [] (content [])
      , frameNotes = content [TextRun prov ("notes of " <> title)]
      , frameOrigin = Nothing
      }
  , requests
  )
  where
    pieces = zip [0 :: Int ..] (filter (not . Text.null . Text.strip) body)
    nodes = mapMaybe (uncurry nodeFor) pieces
    nodeFor n line
      | line == "\\pause" = Just (OverlayPauseContent prov PauseNext)
      | "\\figure{" `Text.isPrefixOf` line = fmap (\ref -> CompiledFigureContent prov ref DerivedLoading) (sourceRef (refName n))
      | otherwise = Just (TextRun prov line)
    refName n = "fig-" <> Text.pack (show index) <> "-" <> Text.pack (show n)
    requests =
      [ FigureRequest ident ref "tikz" ByteString.empty (Just figPath) ByteString.empty [] 960 [figPath] 1 Nothing
      | (n, line) <- pieces
      , "\\figure{" `Text.isPrefixOf` line
      , Just ref <- [sourceRef (refName n)]
      , let figPath = Text.dropEnd 1 (Text.drop 8 line)
      ]

insertAfter :: ByteString -> Maybe Text -> Maybe (ByteString, Text)
insertAfter bytes after =
  case [sp | (_, ident, sp, _) <- sections bytes, Just ident == after] of
    ((_, end) : _) ->
      let ident = "slide-" <> Text.pack (show (length (sections bytes) + 1))
       in Just (ByteString.concat [ByteString.take end bytes, Encoding.encodeUtf8 ("## New slide {#" <> ident <> "}\n"), ByteString.drop end bytes], ident)
    [] -> Nothing

