{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Native.Extensions
-- Description : Locating and loading extension manifests from disk.
--
-- Manifests live in @<project>/.slideblaster/extensions/<id>/extension.json@
-- (workspace) and @$XDG_CONFIG_HOME/slideblaster/extensions/<id>/extension.json@
-- (user, default @~/.config@). Priority is workspace, then user, then the
-- compiled-in built-ins. An invalid manifest is reported and skipped; it never
-- prevents the deck from opening.
module SlideBlaster.Adapter.Native.Extensions
  ( ManifestProblem (..)
  , LoadedManifests (..)
  , loadManifestDirectory
  , loadAllManifests
  , userExtensionsDirectory
  ) where

import SlideBlaster.Extension

import Data.ByteString qualified as ByteString
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (doesDirectoryExist, doesFileExist, getHomeDirectory, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Error (tryIOError)

-- | A manifest that could not be loaded.
data ManifestProblem = ManifestProblem
  { problemPath :: !FilePath
  , problemReason :: !Text
  }
  deriving (Eq, Show)

-- | Manifests in priority order plus the problems met on the way.
data LoadedManifests = LoadedManifests
  { loadedManifests :: ![Manifest]
  , loadedProblems :: ![ManifestProblem]
  }

-- | The per-user extension directory.
userExtensionsDirectory :: IO FilePath
userExtensionsDirectory = do
  xdg <- lookupEnv "XDG_CONFIG_HOME"
  case xdg of
    Just dir | not (null dir) -> pure (dir </> "slideblaster" </> "extensions")
    _ -> do
      home <- getHomeDirectory
      pure (home </> ".config" </> "slideblaster" </> "extensions")

-- | Load every @<dir>/<id>/extension.json@ (sorted by directory name).
loadManifestDirectory :: FilePath -> IO LoadedManifests
loadManifestDirectory dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure (LoadedManifests [] [])
    else do
      listing <- tryIOError (listDirectory dir)
      case listing of
        Left problem -> pure (LoadedManifests [] [ManifestProblem dir (Text.pack (show problem))])
        Right entries -> do
          results <- mapM loadOne (sort entries)
          pure (LoadedManifests [m | Just (Right m) <- results] [p | Just (Left p) <- results])
  where
    loadOne entry = do
      let path = dir </> entry </> "extension.json"
      present <- doesFileExist path
      if not present
        then pure Nothing
        else do
          bytes <- tryIOError (ByteString.readFile path)
          pure . Just $ case bytes of
            Left problem -> Left (ManifestProblem path (Text.pack (show problem)))
            Right content -> case parseManifest content of
              Left err -> Left (ManifestProblem path (renderManifestError err))
              Right manifest -> Right manifest

-- | Workspace, user, then built-in manifests.
loadAllManifests :: FilePath -> IO LoadedManifests
loadAllManifests projectRoot = do
  userDir <- userExtensionsDirectory
  workspace <- loadManifestDirectory (projectRoot </> ".slideblaster" </> "extensions")
  user <- loadManifestDirectory userDir
  pure
    LoadedManifests
      { loadedManifests = loadedManifests workspace <> loadedManifests user <> [builtinTexManifest]
      , loadedProblems = loadedProblems workspace <> loadedProblems user
      }

