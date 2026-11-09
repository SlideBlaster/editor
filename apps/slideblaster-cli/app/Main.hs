-- |
-- Module      : Main
-- Description : Native SlideBlaster executable composition root.
--
-- The composition root selects native capability interpreters. Shared engine
-- and protocol modules remain unaware of files, processes, or command lines.
module Main (main) where

import SlideBlaster.Adapter.Native (nativeFileSystem)
import SlideBlaster.Cli (CliHooks (..), defaultHooks, runCliWith)
import SlideBlaster.Product.Runtime.MarkdownAnalyzer (markdownAnalyzer)

import Data.Text qualified as Text

import System.Environment (getArgs)
import System.Exit (exitWith)

main :: IO ()
main = do
  arguments <- getArgs
  status <- runCliWith defaultHooks {hookAnalyzer = Just markdownAnalyzer} nativeFileSystem (Text.pack <$> arguments)
  exitWith status
