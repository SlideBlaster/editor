{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Cli.Pdf
-- Description : Print an offline deck page to PDF with headless Chrome or Chromium.
--
-- @sb build --pdf@ renders the deck's offline HTML (the same painter as the
-- editor) in its print layout and lets Chrome write the PDF, so the page looks
-- as it does on screen and every link stays a real PDF link. This module only
-- finds the browser and runs it; the page decides its own pages (@\@page@ is
-- the slide size, one page per slide).
module SlideBlaster.Cli.Pdf
  ( chromeNames
  , chromeArguments
  , findChrome
  , printToPdf
  , overflowWarnings
  ) where

import Control.Exception (SomeException, try)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (doesFileExist, findExecutable, getFileSize, removeFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

-- | Binary names tried on @PATH@, in order, after @$SB_CHROME@.
chromeNames :: [FilePath]
chromeNames = ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"]

-- | The browser to use: @$SB_CHROME@ if set (it must exist, no fallback), else the first of
-- 'chromeNames' on @PATH@.
findChrome :: IO (Either Text FilePath)
findChrome = do
  override <- lookupEnv "SB_CHROME"
  case override of
    Just path | not (null path) -> do
      found <- doesFileExist path
      resolved <- if found then pure (Just path) else findExecutable path
      pure (maybe (Left ("SB_CHROME is set to " <> Text.pack path <> ", which is not an executable file")) Right resolved)
    _ -> firstOnPath chromeNames
  where
    firstOnPath [] =
      pure (Left ("no Chrome or Chromium found: install one (tried " <> Text.intercalate ", " (fmap Text.pack chromeNames) <> " on PATH) or set SB_CHROME to its path"))
    firstOnPath (name : rest) = findExecutable name >>= maybe (firstOnPath rest) (pure . Right)

-- | Command line for one print: a scratch profile directory, the PDF to write and the page URL.
-- The page signals nothing the command line can observe, so the virtual-time budget is what
-- lets math, fonts and code highlighting settle before printing.
chromeArguments :: FilePath -> FilePath -> FilePath -> [String]
chromeArguments profile output page =
  [ "--headless=new"
  , "--disable-gpu"
  , "--no-first-run"
  , "--no-default-browser-check"
  , "--disable-extensions"
  , "--hide-scrollbars"
  , "--no-pdf-header-footer"
  , "--run-all-compositor-stages-before-draw"
  , "--enable-logging=stderr"
  , "--v=0"
  , "--virtual-time-budget=" <> show virtualTimeBudgetMillis
  , "--user-data-dir=" <> profile
  , "--print-to-pdf=" <> output
  , "file://" <> page
  ]

virtualTimeBudgetMillis :: Int
virtualTimeBudgetMillis = 15000

-- | Print @page@ (an HTML file) to @output@. @scratch@ is an empty directory for the browser profile.
-- On success, the page's out-of-bounds warnings (see 'overflowWarnings').
printToPdf :: FilePath -> FilePath -> FilePath -> FilePath -> IO (Either Text [Text])
printToPdf chrome scratch page output = do
  _ <- try (removeFile output) :: IO (Either SomeException ())
  result <- timeout (180 * 1000000) (try (readProcessWithExitCode chrome (chromeArguments (scratch </> "profile") output page) ""))
  case result of
    Nothing -> pure (Left "Chrome did not finish printing within 180 seconds")
    Just (Left problem) -> pure (Left ("could not run " <> Text.pack chrome <> ": " <> Text.pack (show (problem :: SomeException))))
    Just (Right (code, _out, err)) -> do
      present <- doesFileExist output
      size <- if present then getFileSize output else pure 0
      pure $
        if code == ExitSuccess && size > 0
          then Right (overflowWarnings (Text.pack err))
          else Left ("Chrome failed to write the PDF (" <> Text.pack (show code) <> "): " <> Text.strip (Text.pack (lastLines (filter (not . isConsole) (lines err)))))
  where
    lastLines = unlines . reverse . take 6 . reverse
    isConsole = ("CONSOLE" `Text.isInfixOf`) . Text.pack

-- | The @sb-overflow: …@ lines the print page logs (one per item that runs out of its box), taken
-- from Chrome's stderr log, where a console message reads @[…:INFO:CONSOLE:1] "message", source: …@.
overflowWarnings :: Text -> [Text]
overflowWarnings = concatMap pick . Text.lines
  where
    marker = "\"sb-overflow: "
    pick line = case Text.breakOn marker line of
      (_, rest) | not (Text.null rest) -> [message (Text.drop (Text.length marker) rest)]
      _ -> []
    -- the message ends at the last `", source:`
    message text = case Text.breakOnEnd "\", source:" text of
      ("", _) -> text
      (before, _) -> Text.dropEnd (Text.length "\", source:") before
