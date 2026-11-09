{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Cli.Check
-- Description : @sb check@: deck lint with a seam for the full deck reader.
--
-- Seam: 'DeckChecker' is the single point where the container reader of the
-- core language lane plugs in. Until it lands, 'basicChecker' performs the
-- checks that need no deck parser: valid UTF-8, a @slideblaster: 1@ container
-- declaration, balanced code fences, and that every @\\figure{...}@,
-- @\\input{...}@ and fenced @tikz@ reference resolves to a project file. It
-- reports in @file:line: severity: message@ form and fails (exit 1) on any
-- error.
module SlideBlaster.Cli.Check
  ( CheckSeverity (..)
  , CheckDiagnostic (..)
  , DeckChecker
  , basicChecker
  , renderDiagnostic
  , analysisChecks
  , hasErrors
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import SlideBlaster.Product.Runtime.Analysis (Analysis (..), DiagnosticItem (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, (</>))

-- | Diagnostic severity.
data CheckSeverity = CheckError | CheckWarning
  deriving (Eq, Show)

-- | One located finding (1-based line; 0 means whole file).
data CheckDiagnostic = CheckDiagnostic
  { checkSeverity :: !CheckSeverity
  , checkLine :: !Int
  , checkMessage :: !Text
  }
  deriving (Eq, Show)

-- | Check one deck: its path (for resolving references) and exact bytes.
type DeckChecker = FilePath -> ByteString -> IO [CheckDiagnostic]

-- | @file:line: severity: message@.
renderDiagnostic :: FilePath -> CheckDiagnostic -> Text
renderDiagnostic file d =
  Text.pack file <> ":" <> Text.pack (show (checkLine d)) <> ": "
    <> (case checkSeverity d of CheckError -> "error"; CheckWarning -> "warning")
    <> ": " <> checkMessage d

-- | Whether any finding is an error.
hasErrors :: [CheckDiagnostic] -> Bool
hasErrors = any ((== CheckError) . checkSeverity)

-- | The parser-free checks described in the module header.
basicChecker :: DeckChecker
basicChecker path bytes = case Encoding.decodeUtf8' bytes of
  Left _ -> pure [CheckDiagnostic CheckError 0 "file is not valid UTF-8"]
  Right text -> do
    let numbered = zip [1 :: Int ..] (Text.lines text)
        container =
          [ CheckDiagnostic CheckError 1 "missing 'slideblaster: 1' container declaration"
          | not (any (\(_, l) -> Text.strip l == "slideblaster: 1") (take 40 numbered))
          ]
        fences = [n | (n, l) <- numbered, "```" `Text.isPrefixOf` Text.stripStart l]
        unbalanced =
          [ CheckDiagnostic CheckError (lastFence fences) "unterminated code fence"
          | odd (length fences)
          ]
        refs = [(n, ref) | (n, l) <- numbered, ref <- references l]
    missing <- mapM (check n') refs
    pure (container <> unbalanced <> concat missing)
  where
    n' = takeDirectory path
    lastFence fs = case reverse fs of
      n : _ -> n
      [] -> 0
    check dir (n, ref) = do
      let candidates = [dir </> Text.unpack ref, dir </> Text.unpack ref <> ".tex"]
      found <- or <$> mapM doesFileExist candidates
      pure [CheckDiagnostic CheckError n ("referenced file not found: " <> ref) | not found]

-- File references on one line: @\figure{x}@ and @\input{x}@.
references :: Text -> [Text]
references line = concatMap (arguments line) ["\\figure", "\\input"]
  where
    arguments l name = case Text.breakOn name l of
      (_, rest)
        | Text.null rest -> []
        | otherwise ->
            let after = Text.drop (Text.length name) rest
                afterOpts = case Text.uncons after of
                  Just ('[', r) -> Text.drop 1 (Text.dropWhile (/= ']') r)
                  _ -> after
             in case Text.uncons afterOpts of
                  Just ('{', body) ->
                    let arg = Text.strip (Text.takeWhile (/= '}') body)
                     in [arg | not (Text.null arg), not ("http" `Text.isPrefixOf` arg)] <> arguments (Text.drop 1 (Text.dropWhile (/= '}') body)) name
                  _ -> arguments after name

-- | Findings of the deck analysis that @sb check@ reports: sections and routes
-- (@route.*@, @deck.section.*@). Located by the line of the diagnostic's span.
analysisChecks :: ByteString -> Analysis -> [CheckDiagnostic]
analysisChecks bytes analysis = nubChecks $
  [ CheckDiagnostic severity (maybe 0 (lineOf . fst) (diagnosticSpan d)) (diagnosticCode d <> ": " <> diagnosticMessage d)
  | d <- analysisDiagnostics analysis
  , any (`Text.isPrefixOf` diagnosticCode d) ["route.", "deck.section.", "include."]
  , Just severity <- [case diagnosticSeverity d of "error" -> Just CheckError; "warning" -> Just CheckWarning; _ -> Nothing]
  ]
  where
    nubChecks = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
    lineOf offset = 1 + ByteString.count 10 (ByteString.take offset bytes)
