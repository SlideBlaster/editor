{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Extension.Tikz
-- Description : TikZ block request builder, @\\input@ closure and TeX log mapping.
--
-- Pure. Turns a 'BlockRequest' into the standalone LaTeX document that
-- @sb.tex@ compiles (a port of @buildStandaloneDocument@ and
-- @inferPreamble@ from the editor's @tikzDocument.ts@), resolves the
-- @\\input@ closure through a caller-supplied workspace read function, and maps
-- a TeX failure back to the figure's source line.
--
-- Document layout, in order: @\\documentclass[tikz,border=1pt]{standalone}@;
-- inferred packages the deck preamble does not itself load; the deck preamble
-- verbatim (so it takes precedence); inferred TikZ libraries; the palette as
-- @\\definecolor@; then the body, preceded by one @%%sb-line N@ comment per
-- source line so a TeX line number maps back to a source line without a side
-- table. (A comment line is invisible to TeX except inside a verbatim
-- environment, which TikZ pictures do not use.)
module SlideBlaster.Extension.Tikz
  ( buildTikzDocument
  , inferLibraries
  , inferPackages
  , scanInputs
  , resolveInputClosure
  , TexError (..)
  , parseTexLog
  , mapTexLine
  , markerPrefix
  , isSafeRelativePath
  ) where

import SlideBlaster.Extension.Request

import Data.ByteString (ByteString)
import Data.Char (isAlpha, isAlphaNum, isAscii, isHexDigit)
import Data.List (nub)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

-- | The marker comment prefix; the line number follows.
markerPrefix :: Text
markerPrefix = "%%sb-line "

defaultLibraries :: [Text]
defaultLibraries =
  [ "arrows.meta", "calc", "positioning", "fit", "backgrounds", "intersections", "through"
  , "shapes.geometric", "shapes.misc", "shapes.symbols", "shapes.arrows", "shapes.multipart"
  , "decorations.pathmorphing", "decorations.pathreplacing", "decorations.markings"
  , "decorations.text", "patterns", "matrix", "chains", "scopes", "quotes", "angles"
  , "petri", "automata"
  ]

defaultPackages :: [Text]
defaultPackages = ["amsmath", "amssymb"]

-- | Libraries to load: the default set, those the body names, and marker
-- libraries. Order is stable and without duplicates.
inferLibraries :: Text -> [Text]
inferLibraries source =
  nub (defaultLibraries <> named <> [lib | (test, libs, _) <- markers, test source, lib <- libs])
  where
    named =
      [ lib
      | arg <- commandArguments "\\usetikzlibrary" source
      , lib <- Text.strip <$> Text.splitOn "," arg
      , not (Text.null lib)
      ]

-- | Packages to load as @(name, full usepackage line)@: defaults, those the body
-- names (options kept) and marker packages.
inferPackages :: Text -> [(Text, Text)]
inferPackages source =
  nubOn fst $
    [(p, "\\usepackage{" <> p <> "}") | p <- defaultPackages]
      <> namedPackages source
      <> [(p, "\\usepackage{" <> p <> "}") | (test, _, pkgs) <- markers, test source, p <- pkgs]

nubOn :: Eq b => (a -> b) -> [a] -> [a]
nubOn f = go []
  where
    go _ [] = []
    go seen (x : xs)
      | f x `elem` seen = go seen xs
      | otherwise = x : go (f x : seen) xs

-- Packages named by @\\usepackage[opts]{a,b}@ in the body, with their options.
namedPackages :: Text -> [(Text, Text)]
namedPackages source =
  [ (name, "\\usepackage" <> options <> "{" <> name <> "}")
  | (options, arg) <- usepackageCalls source
  , name <- Text.strip <$> Text.splitOn "," arg
  , not (Text.null name)
  ]

markers :: [(Text -> Bool, [Text], [Text])]
markers =
  [ (hasCommand "\\ding", [], ["pifont"])
  , (anyCI ["linuxbiolinum", "linux biolinum", "libertine", "biolinum"], [], ["libertine"])
  , (anyCI ["inconsolata", "zi4"], [], ["inconsolata"])
  , (anyOf ["\\begin{axis}", "\\addplot", "\\begin{semilogxaxis}"], [], ["pgfplots"])
  , (anyOf ["\\chemfig"], [], ["chemfig"])
  , (anyOf ["\\begin{tikzcd}"], [], ["tikz-cd"])
  , (anyOf ["\\begin{circuitikz}"], [], ["circuitikz"])
  , (anyOf ["tdplot_", "\\tdplotsetmaincoords"], ["3d"], [])
  ]
  where
    anyOf needles hay = any (`Text.isInfixOf` hay) needles
    anyCI needles hay = any (`Text.isInfixOf` Text.toLower hay) needles

-- @\\name@ not followed by a letter.
hasCommand :: Text -> Text -> Bool
hasCommand name hay = go hay
  where
    go t = case Text.breakOn name t of
      (_, rest)
        | Text.null rest -> False
        | otherwise ->
            let after = Text.drop (Text.length name) rest
             in case Text.uncons after of
                  Just (c, _) | isAlpha c && isAscii c -> go after
                  _ -> True

-- Brace arguments of every occurrence of a command, skipping @[opts]@.
commandArguments :: Text -> Text -> [Text]
commandArguments name source = snd <$> calls source name

usepackageCalls :: Text -> [(Text, Text)]
usepackageCalls source = calls source "\\usepackage"

-- (options text including brackets or empty, brace argument)
calls :: Text -> Text -> [(Text, Text)]
calls source name = go source
  where
    go t = case Text.breakOn name t of
      (_, rest)
        | Text.null rest -> []
        | otherwise ->
            let after = Text.drop (Text.length name) rest
                (options, afterOpts) = optionalBracket after
             in case Text.uncons afterOpts of
                  Just ('{', body) ->
                    let (arg, remainder) = Text.break (== '}') body
                     in (options, arg) : go (Text.drop 1 remainder)
                  _ -> go after
    optionalBracket t = case Text.uncons t of
      Just ('[', r) ->
        let (inside, remainder) = Text.break (== ']') r
         in ("[" <> inside <> "]", Text.drop 1 remainder)
      _ -> ("", t)

-- | Build the full standalone document for a TikZ (or TeX) block.
buildTikzDocument :: BlockRequest -> Text
buildTikzDocument request =
  Text.unlines $
    ["\\documentclass[tikz,border=1pt]{standalone}"]
      <> [line | (name, line) <- inferPackages original, name `notElem` declared, name /= "tikz"]
      <> preambleLines
      <> ["\\usetikzlibrary{" <> Text.intercalate "," (inferLibraries original) <> "}"]
      <> (if "pgfplots" `elem` (fst <$> inferPackages original) && "pgfplots" `notElem` declared
            then ["\\pgfplotsset{compat=1.16}"]
            else [])
      <> paletteLines
      <> ["\\begin{document}"]
      <> markedBody
      <> ["\\end{document}"]
  where
    original = requestBody request
    body = stripUsepackage original
    preambleLines = [requestPreamble request | not (Text.null (Text.strip (requestPreamble request)))]
    declared =
      [ name
      | (_, arg) <- usepackageCalls (requestPreamble request)
      , name <- Text.strip <$> Text.splitOn "," arg
      ]
    paletteLines =
      [ "\\definecolor{" <> colourName c <> "}{HTML}{" <> Text.toUpper (colourHex c) <> "}"
      | c <- requestPalette request
      , validColourName (colourName c)
      , validHex (colourHex c)
      ]
    wrapped = if requestKind request == "tex" then body else ensureTikzpicture body
    -- Marker numbering follows the original body; the optional wrapper adds
    -- two lines at the very start and end, handled by an offset of one line.
    markedBody =
      let sourceLines = Text.splitOn "\n" wrapped
          offset = if wrapped == body then 0 else 1 :: Int
       in concat
            [ [markerPrefix <> Text.pack (show (max 1 (n - offset))), l]
            | (n, l) <- zip [1 :: Int ..] sourceLines
            ]

validColourName :: Text -> Bool
validColourName n = not (Text.null n) && Text.all (\c -> isAscii c && isAlphaNum c) n

validHex :: Text -> Bool
validHex h = Text.length h == 6 && Text.all isHexDigit h

ensureTikzpicture :: Text -> Text
ensureTikzpicture source
  | "\\begin{tikzpicture}" `Text.isInfixOf` source = source
  | otherwise = "\\begin{tikzpicture}\n" <> source <> "\n\\end{tikzpicture}"

-- Blank out @\\usepackage[..]{..}@ calls in the body (they are hoisted); line
-- structure is preserved.
stripUsepackage :: Text -> Text
stripUsepackage = Text.intercalate "\n" . map stripLine . Text.splitOn "\n"
  where
    stripLine l
      | "\\usepackage" `Text.isInfixOf` l = removeCalls l
      | otherwise = l
    removeCalls l = case Text.breakOn "\\usepackage" l of
      (before, rest)
        | Text.null rest -> l
        | otherwise ->
            let after = Text.drop (Text.length "\\usepackage") rest
                afterOpts = case Text.uncons after of
                  Just ('[', r) -> Text.drop 1 (Text.dropWhile (/= ']') r)
                  _ -> after
             in case Text.uncons afterOpts of
                  Just ('{', body) -> before <> removeCalls (Text.drop 1 (Text.dropWhile (/= '}') body))
                  _ -> l

-- | Names referenced by @\\input{x}@, @\\include{x}@ or @\\input x@, in order,
-- without duplicates. Comment text (after an unescaped @%@) is ignored.
scanInputs :: Text -> [Text]
scanInputs source = nub (concatMap lineRefs (Text.splitOn "\n" source))
  where
    lineRefs l = refs "\\input" (code l) <> refs "\\include" (code l)
    code l = fst (breakComment l)
    refs name t = case Text.breakOn name t of
      (_, rest)
        | Text.null rest -> []
        | otherwise ->
            let after = Text.drop (Text.length name) rest
             in case Text.uncons after of
                  Just ('{', r) -> Text.strip (Text.takeWhile (/= '}') r) : refs name r
                  Just (c, _)
                    | isAlpha c && isAscii c -> refs name after
                    | otherwise ->
                        let bare = Text.takeWhile (\x -> not (x `elem` (" \t{}\\%" :: String))) (Text.stripStart after)
                         in [bare | not (Text.null bare)] <> refs name after
                  Nothing -> []

breakComment :: Text -> (Text, Text)
breakComment l = go 0
  where
    go i
      | i >= Text.length l = (l, "")
      | Text.index l i == '%' && (i == 0 || Text.index l (i - 1) /= '\\') = Text.splitAt i l
      | otherwise = go (i + 1)

-- | Resolve the @\\input@ closure of a body. The read function takes a
-- project-relative path and returns its bytes. Each reference is tried as
-- written, with @.tex@ appended, then relative to the base directory of the
-- block's own file; the file is stored under the name the body used (with the
-- extension TeX would add), so the compile finds it relative to the temporary
-- root. Unsafe references (absolute, @..@) and unreadable files are returned
-- as unresolved. Depth and file count are bounded (8 and 64).
resolveInputClosure
  :: Monad m
  => (Text -> m (Maybe ByteString))
  -> Text
  -- ^ Directory of the block's own file ("" for the project root).
  -> Text
  -- ^ Block body.
  -> m ([ResolvedInput], [Text])
resolveInputClosure readFile' baseDir body0 = loop [body0] [] []
  where
    -- Worklist of bodies still to scan; 'done' and 'unresolved' are reversed.
    loop [] done unresolved = pure (reverse done, reverse unresolved)
    loop (body : queue) done unresolved = do
      let seen r = any (`elem` (inputPath <$> done)) [r, r <> ".tex"] || r `elem` unresolved
          fresh = [r | r <- scanInputs body, not (seen r)]
      (done', unresolved', found) <- resolveAll fresh done unresolved []
      loop (queue <> reverse found) done' unresolved'
    resolveAll [] done unresolved found = pure (done, unresolved, found)
    resolveAll (r : rs) done unresolved found
      | length done >= 64 || not (isSafeRelativePath r) =
          resolveAll rs done (r : unresolved) found
      | otherwise = do
          hit <- firstHit (candidates r)
          case hit of
            Nothing -> resolveAll rs done (r : unresolved) found
            Just (name, bytes) ->
              resolveAll rs (ResolvedInput name bytes : done) unresolved
                (Encoding.decodeUtf8Lenient bytes : found)
    candidates r = [(name, path) | name <- withExt r, path <- [name, joinDir name]]
    withExt r = if hasExtension r then [r] else [r <> ".tex", r]
    hasExtension r = "." `Text.isInfixOf` snd (Text.breakOnEnd "/" r)
    joinDir r = if Text.null baseDir then r else baseDir <> "/" <> r
    firstHit [] = pure Nothing
    firstHit ((name, path) : rest) = do
      r <- readFile' path
      case r of
        Just bytes -> pure (Just (name, bytes))
        Nothing -> firstHit rest

-- | A reference that stays inside the temporary root: relative, no @..@,
-- no backslash, no control characters.
isSafeRelativePath :: Text -> Bool
isSafeRelativePath path =
  not (Text.null path)
    && not ("/" `Text.isPrefixOf` path)
    && not ("~" `Text.isPrefixOf` path)
    && ".." `notElem` Text.splitOn "/" path
    && Text.all (\c -> c /= '\\' && c /= '\0') path
    && not (any (\c -> c `elem` ("\n\r" :: String)) (Text.unpack path))

-- | The first error of a TeX log.
data TexError = TexError
  { texErrorMessage :: !Text
  -- ^ The text after @! @ on the first error line.
  , texErrorLine :: !(Maybe Int)
  -- ^ The @l.N@ line of the generated document, when reported.
  }
  deriving (Eq, Show)

-- | Find the first @! ...@ line and the following @l.N@ context line.
parseTexLog :: Text -> Maybe TexError
parseTexLog logText = case dropWhile (not . isBang) (Text.lines logText) of
  [] -> Nothing
  bang : rest ->
    Just
      TexError
        { texErrorMessage = Text.strip (stripEnd (Text.drop 2 bang))
        , texErrorLine = firstJust' (lineNumber <$> take 12 rest)
        }
  where
    isBang l = "! " `Text.isPrefixOf` l
    stripEnd = Text.dropWhileEnd (== '.') . Text.strip
    lineNumber l = case Text.stripPrefix "l." l of
      Just r ->
        let digits = Text.takeWhile (\c -> c >= '0' && c <= '9') r
         in if Text.null digits then Nothing else Just (digitsToInt digits)
      Nothing -> Nothing
    firstJust' = foldr (\x acc -> maybe acc Just x) Nothing

digitsToInt :: Text -> Int
digitsToInt = Text.foldl' (\acc c -> acc * 10 + (fromEnum c - fromEnum '0')) 0

-- | Map a line of the generated document to a body line using the
-- @%%sb-line N@ markers: the nearest marker at or before the line.
mapTexLine :: Text -> Int -> Maybe Int
mapTexLine document texLine =
  case mapMaybe markerAt (reverse (take texLine (Text.lines document))) of
    n : _ -> Just n
    [] -> Nothing
  where
    markerAt l = case Text.stripPrefix markerPrefix l of
      Just r | not (Text.null r), Text.all (\c -> c >= '0' && c <= '9') r -> Just (digitsToInt r)
      _ -> Nothing
