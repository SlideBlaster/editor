{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Native.Sanitize
-- Description : SVG sanitiser: no script, no external references.
--
-- A provider's SVG is painted into the host page, so it must not execute code
-- or fetch anything. The sanitiser is a tolerant tag scanner (not an XML
-- parser): it drops @script@, @foreignObject@, @iframe@, @object@, @embed@,
-- @animate@-family and @style@-with-external-reference elements with their
-- content, drops DOCTYPE/ENTITY declarations and processing instructions other
-- than the XML declaration, removes @on*@ attributes and @javascript:@ values,
-- and keeps @href@/@src@ only when it is a fragment (@#id@) or an image
-- @data:@ URI. Everything else is passed through byte-for-byte.
module SlideBlaster.Adapter.Native.Sanitize
  ( sanitizeSvg
  ) where

import Data.Char (isSpace, toLower)
import Data.Text (Text)
import Data.Text qualified as Text

-- | Sanitise an SVG document.
sanitizeSvg :: Text -> Text
sanitizeSvg = Text.concat . go
  where
    go t = case Text.uncons t of
      Nothing -> []
      Just ('<', rest)
        | "!--" `Text.isPrefixOf` rest ->
            let (comment, after) = Text.breakOn "-->" rest
             in ("<" <> comment <> Text.take 3 after) : go (Text.drop 3 after)
        | "![CDATA[" `Text.isPrefixOf` rest ->
            let (cdata, after) = Text.breakOn "]]>" rest
             in ("<" <> cdata <> Text.take 3 after) : go (Text.drop 3 after)
        | "!" `Text.isPrefixOf` rest -> go (skipDeclaration rest)
        | "?" `Text.isPrefixOf` rest ->
            let (pi', after) = Text.breakOn "?>" rest
             in if "?xml " `Text.isPrefixOf` rest
                  then ("<" <> pi' <> Text.take 2 after) : go (Text.drop 2 after)
                  else go (Text.drop 2 after)
        | otherwise ->
            let (tag, after) = breakTag rest
             in handleTag tag after
      Just _ ->
        let (textRun, after) = Text.break (== '<') t
         in textRun : go after

    handleTag tag after
      | closing = ["<" <> tag <> ">" | not (isBlocked name)] <> go after
      | isBlocked name =
          if selfClosing tag then go after else go (skipElement name after)
      | name == "style" && externalStyle after = go (skipElement name after)
      | otherwise = ("<" <> cleanTag tag <> ">") : go after
      where
        closing = "/" `Text.isPrefixOf` tag
        name = Text.map toLower (tagName (Text.dropWhile (== '/') tag))

    externalStyle after =
      let (content, _) = Text.breakOn "</" after
          lower = Text.map toLower content
       in "@import" `Text.isInfixOf` lower
            || any (not . fragmentUrl) (urlArguments lower)

    urlArguments t = case Text.breakOn "url(" t of
      (_, rest) | Text.null rest -> []
      (_, rest) ->
        let inner = Text.drop 4 rest
         in Text.strip (Text.takeWhile (/= ')') inner) : urlArguments (Text.drop 1 (Text.dropWhile (/= ')') inner))
    fragmentUrl u = "#" `Text.isPrefixOf` Text.dropWhile (`elem` ("'\"" :: String)) u

isBlocked :: Text -> Bool
isBlocked name =
  name
    `elem` [ "script", "foreignobject", "iframe", "object", "embed", "applet"
           , "animate", "animatemotion", "animatetransform", "set", "audio", "video"
           ]

tagName :: Text -> Text
tagName = Text.takeWhile (\c -> not (isSpace c) && c /= '/' && c /= '>')

selfClosing :: Text -> Bool
selfClosing tag = "/" `Text.isSuffixOf` Text.stripEnd tag

-- Split at the closing @>@ of a tag, honouring quoted attribute values.
breakTag :: Text -> (Text, Text)
breakTag = scan 0 Nothing
  where
    scan :: Int -> Maybe Char -> Text -> (Text, Text)
    scan n quote t = case Text.uncons (Text.drop n t) of
      Nothing -> (t, "")
      Just (c, _) -> case quote of
        Just q | c == q -> scan (n + 1) Nothing t
        Just _ -> scan (n + 1) quote t
        Nothing
          | c == '>' -> (Text.take n t, Text.drop (n + 1) t)
          | c == '"' || c == '\'' -> scan (n + 1) (Just c) t
          | otherwise -> scan (n + 1) Nothing t

-- Skip a @<!DOCTYPE ...>@ or @<!ENTITY ...>@ declaration, including an
-- internal subset in brackets.
skipDeclaration :: Text -> Text
skipDeclaration t = go (0 :: Int) t
  where
    go depth s = case Text.uncons s of
      Nothing -> ""
      Just ('[', r) -> go (depth + 1) r
      Just (']', r) -> go (max 0 (depth - 1)) r
      Just ('>', r) | depth == 0 -> r
      Just (_, r) -> go depth r

-- Drop everything up to and including the matching close tag (case-insensitive).
skipElement :: Text -> Text -> Text
skipElement name t = go t
  where
    close = "</" <> name
    go s = case Text.uncons s of
      Nothing -> ""
      Just ('<', r)
        | Text.map toLower (Text.take (Text.length close - 1) r) == Text.drop 1 close ->
            Text.drop 1 (Text.dropWhile (/= '>') r)
      Just (_, r) -> go r

-- Rebuild a start tag with unsafe attributes removed.
cleanTag :: Text -> Text
cleanTag tag =
  let name = tagName tag
      rest = Text.drop (Text.length name) tag
      trailingSlash = if selfClosing tag then "/" else ""
      body = if trailingSlash == "/" then Text.dropWhileEnd (== '/') (Text.stripEnd rest) else rest
   in name <> Text.concat (keepAttributes (attributes body)) <> trailingSlash

-- (leading whitespace, name, value text including '=' and quotes if present)
attributes :: Text -> [(Text, Text, Text)]
attributes t
  | Text.null (Text.strip t) = []
  | otherwise =
      let (ws, afterWs) = Text.span isSpace t
          (name, afterName) = Text.break (\c -> isSpace c || c == '=') afterWs
          (preEq, afterPre) = Text.span isSpace afterName
       in if Text.null name
            then []
            else case Text.uncons afterPre of
              Just ('=', afterEq) ->
                let (postEq, valueStart) = Text.span isSpace afterEq
                    (valueText, remainder) = takeValue valueStart
                 in (ws, name, preEq <> "=" <> postEq <> valueText) : attributes remainder
              _ -> (ws, name, preEq) : attributes afterPre
  where
    takeValue v = case Text.uncons v of
      Just (q, r) | q == '"' || q == '\'' ->
        let (inside, after) = Text.break (== q) r
         in (Text.singleton q <> inside <> Text.take 1 after, Text.drop 1 after)
      _ -> Text.break isSpace v

keepAttributes :: [(Text, Text, Text)] -> [Text]
keepAttributes attrs = [ws <> name <> value | (ws, name, value) <- attrs, safe name value]
  where
    safe name value =
      let lname = Text.map toLower name
          bare = Text.map toLower (stripQuotes (Text.drop 1 (Text.dropWhile (/= '=') value)))
          stripped = Text.strip bare
       in not ("on" `Text.isPrefixOf` lname)
            && not ("javascript:" `Text.isInfixOf` Text.filter (not . isSpace) bare)
            && not ("vbscript:" `Text.isInfixOf` bare)
            && (lname `notElem` ["href", "xlink:href", "src"] || safeReference stripped)
            && (lname /= "style" || not (externalUrl stripped))
    stripQuotes v = Text.dropAround (`elem` ("\"'" :: String)) (Text.strip v)
    safeReference v = "#" `Text.isPrefixOf` v || "data:image/" `Text.isPrefixOf` v
    externalUrl v = "@import" `Text.isInfixOf` v || ("url(" `Text.isInfixOf` v && not ("url(#" `Text.isInfixOf` v))
