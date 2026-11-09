{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Export.Offline
-- Description : One-file offline HTML deck: session/1 plans plus the host viewer bundle.
--
-- The deck is the whole-deck plan value of @deckExportValue@. The page embeds
-- it as inert JSON and the host's viewer bundle (script and stylesheet) inline,
-- so it opens from disk with no network. This writer adds no external
-- reference of its own; the supplied assets must be self-contained too.
module SlideBlaster.Export.Offline
  ( OfflineAssets (..)
  , OfflinePrint (..)
  , offlineAssets
  , exportDeckHtml
  , inlineCssUrls
  ) where

import Data.Aeson (Value, encode, (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

-- | Host viewer bundle (from @hosts/web@) to inline.
data OfflineAssets = OfflineAssets
  { offlineViewerScript :: !Text
  , offlineViewerStyle :: !Text
  , offlineThemeStyle :: !Text
  -- ^ the deck theme's stylesheet (fonts already inlined, see 'inlineCssUrls'); may be empty
  , offlinePrint :: !(Maybe OfflinePrint)
  -- ^ when set, the page opens in print mode: every slide as one page, no viewer chrome
  }

-- | Print mode of the offline page (used by @sb build --pdf@; Ctrl+P on a normal page prints the handout too).
newtype OfflinePrint = OfflinePrint
  { printSteps :: Bool
  -- ^ one page per overlay step instead of one page per slide showing its final step
  }

-- | Assets with no theme stylesheet and no print mode.
offlineAssets :: Text -> Text -> OfflineAssets
offlineAssets script style = OfflineAssets script style "" Nothing

-- | Deterministic standalone page for a deck value.
exportDeckHtml :: OfflineAssets -> Value -> ByteString
exportDeckHtml assets deck =
  Encoding.encodeUtf8 . Text.concat $
    [ "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
    , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
    , "<title>", escapeHtml title, "</title>\n"
    , "<style>\n", neutraliseClose "style" (offlineViewerStyle assets <> themeStyle), "\n</style>\n"
    , "</head>\n<body>\n<div id=\"sb-viewer\"></div>\n"
    , "<script id=\"sb-deck\" type=\"application/json\">", payload, "</script>\n"
    , printConfig
    , "<script>\n", neutraliseClose "script" (offlineViewerScript assets), "\n</script>\n"
    , "</body>\n</html>\n"
    ]
  where
    title = maybe "SlideBlaster deck" id (parseMaybe (Aeson.withObject "deck" (.:? "title")) deck >>= id)
    themeStyle = if Text.null (offlineThemeStyle assets) then "" else "\n" <> offlineThemeStyle assets
    printConfig = case offlinePrint assets of
      Nothing -> ""
      Just options -> "<script id=\"sb-print\" type=\"application/json\">{\"steps\":" <> (if printSteps options then "true" else "false") <> "}</script>\n"
    payload = escapeJson (Encoding.decodeUtf8 (LazyByteString.toStrict (encode deck)))

escapeHtml :: Text -> Text
escapeHtml = Text.concatMap step
  where
    step '<' = "&lt;"
    step '>' = "&gt;"
    step '&' = "&amp;"
    step '"' = "&quot;"
    step c = Text.singleton c

-- Keep the JSON inert inside a script element: no closing tags, comments, or
-- line terminators that end a JavaScript string.
escapeJson :: Text -> Text
escapeJson = Text.concatMap step
  where
    step '<' = "\\u003c"
    step '>' = "\\u003e"
    step '&' = "\\u0026"
    step '\x2028' = "\\u2028"
    step '\x2029' = "\\u2029"
    step c = Text.singleton c

-- Break any accidental closing tag in inlined assets.
neutraliseClose :: Text -> Text -> Text
neutraliseClose tag = go
  where
    marker = "</" <> tag
    go text =
      let (before, after) = Text.breakOn marker text
       in if Text.null after
            then before
            else before <> "<\\/" <> tag <> go (Text.drop (Text.length marker) after)

-- | Replace every relative @url(...)@ of a stylesheet by a @data:@ URI, so the
-- page needs no file next to it. The resolver gets the path as written and
-- returns the complete @data:@ URI; a reference it cannot resolve, and any
-- absolute or @data:@ URL, is left as written.
inlineCssUrls :: (Text -> Maybe Text) -> Text -> Text
inlineCssUrls resolve = go
  where
    go text =
      let (before, after) = Text.breakOn "url(" text
       in if Text.null after
            then before
            else
              let rest = Text.drop 4 after
                  (inner, tail') = Text.breakOn ")" rest
                  raw = Text.strip inner
                  path = Text.dropAround (\c -> c == '"' || c == '\'') raw
                  replaced = case resolve path of
                    Just uri
                      | not ("data:" `Text.isPrefixOf` path) && not (Text.null path) -> "url(" <> uri <> ")"
                    _ -> "url(" <> inner <> ")"
               in if Text.null tail'
                    then before <> after
                    else before <> replaced <> go (Text.drop 1 tail')
