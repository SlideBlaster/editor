{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Cli.Watch
-- Description : Polling file-change detection for the project tree.
--
-- The server reports external edits to the host by comparing two snapshots of
-- the tree (path to modification time and size). Polling needs no native
-- notification library and behaves the same on every platform (default,
-- revisitable). @.slideblaster/@, @.git/@ and @node_modules/@ are not scanned.
module SlideBlaster.Cli.Watch
  ( Change (..)
  , TreeSnapshot
  , scanTree
  , ProjectScan
  , scanProject
  , scanSnapshot
  , diffSnapshots
  , changeName
  ) where

import Control.Monad (foldM)
import Data.ByteString qualified as ByteString
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime)
import SlideBlaster.Deck.Container (includeLinesOf)
import SlideBlaster.Deck.Include (IncludeLine (..), deckSuffix, keyDirectory, keyToRelative, normalizeKey)
import System.Directory
  ( doesDirectoryExist
  , getFileSize
  , getModificationTime
  , listDirectory
  , pathIsSymbolicLink
  )
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (tryIOError)

-- | Relative path to (modification time, size in bytes).
type TreeSnapshot = Map FilePath (UTCTime, Integer)

-- | What happened to a path between two snapshots.
data Change = Created | Modified | Deleted
  deriving (Eq, Show)

-- | Wire name of a change.
changeName :: Change -> String
changeName change = case change of
  Created -> "created"
  Modified -> "modified"
  Deleted -> "deleted"

skipped :: FilePath -> Bool
skipped name = name `elem` [".slideblaster", ".git", "node_modules"]

-- | Snapshot every regular file under the root (symbolic links are not followed
-- into directories).
scanTree :: FilePath -> IO TreeSnapshot
scanTree root = Map.fromList <$> go ""
  where
    go relative = do
      let dir = if null relative then root else root </> relative
      listing <- tryIOError (listDirectory dir)
      case listing of
        Left _ -> pure []
        Right names -> concat <$> mapM (entry relative) [n | n <- names, not (skipped n)]
    entry relative name = do
      let rel = if null relative then name else relative <> "/" <> name
          full = root </> rel
      link <- tryIOError (pathIsSymbolicLink full)
      isDir <- doesDirectoryExist full
      if isDir && link /= Right True
        then go rel
        else do
          info <- tryIOError ((,) <$> getModificationTime full <*> getFileSize full)
          pure [(rel, i) | Right i <- [info]]

-- | Changes from an old snapshot to a new one, sorted by path.
diffSnapshots :: TreeSnapshot -> TreeSnapshot -> [(FilePath, Change)]
diffSnapshots old new =
  Map.toAscList $
    Map.unions
      [ Map.map (const Created) (Map.difference new old)
      , Map.map (const Deleted) (Map.difference old new)
      , Map.mapMaybe id (Map.intersectionWith (\a b -> if a == b then Nothing else Just Modified) old new)
      ]

-- | Project key to (real path, stamp). Keys of files outside the root, which
-- belong to included decks, spell each leading @..@ as @_up@.
type ProjectScan = Map FilePath (FilePath, (UTCTime, Integer))

-- | The stamps of a scan, for 'diffSnapshots'.
scanSnapshot :: ProjectScan -> TreeSnapshot
scanSnapshot = Map.map snd

-- | The project tree plus the files of every deck it includes (@\\include{..}@),
-- transitively. An included folder contributes its whole tree; an included
-- file its folder (just the file when that folder is an ancestor of the root).
scanProject :: FilePath -> IO ProjectScan
scanProject root = do
  tree <- scanTree root
  let own = Map.mapWithKey (\key stamp -> (root </> key, stamp)) tree
      decks = [key | key <- Map.keys tree, Text.unpack deckSuffix `isSuffixOfString` key]
  (found, _) <- foldM visit (own, []) decks
  pure found
  where
    isSuffixOfString suffix string = reverse suffix == take (length suffix) (reverse string)
    visit (acc, seen) deckKey
      | deckKey `elem` seen = pure (acc, seen)
      | otherwise = do
          let seen' = deckKey : seen
          case Map.lookup deckKey acc of
            Nothing -> pure (acc, seen')
            Just (real, _) -> do
              bytes <- either (const ByteString.empty) id <$> tryIOError (ByteString.readFile real)
              foldM (include deckKey) (acc, seen') [includePath l | l <- includeLinesOf bytes]
    include deckKey (acc, seen) path = do
      let target = Text.unpack (normalizeKey (Text.pack (keyDirectory' deckKey) <> "/" <> path))
          real = root </> Text.unpack (keyToRelative (Text.pack target))
      isDir <- doesDirectoryExist real
      let folderKey = target
          fileDir = takeDirectory target
          fileDirKey = if fileDir == "." then "" else fileDir
          ancestorOnly = all (== "_up") (splitSlash fileDirKey)
      added <-
        if isDir
          then tree folderKey real
          else
            if Text.unpack deckSuffix `isSuffixOfString` target
              then if ancestorOnly then single target real else tree fileDirKey (takeDirectory real)
              else pure Map.empty
      let acc' = Map.union acc added
          decks = [k | k <- Map.keys added, Text.unpack deckSuffix `isSuffixOfString` k, takeDirectory' k == folderKey || k == target]
      foldM visit (acc', seen) decks
    keyDirectory' = Text.unpack . keyDirectory . Text.pack
    takeDirectory' k = let d = takeDirectory k in if d == "." then "" else d
    splitSlash = filter (not . null) . map Text.unpack . Text.splitOn "/" . Text.pack
    tree key realDir = do
      files <- scanTree realDir
      pure (Map.fromList [(if null key then rel else key <> "/" <> rel, (realDir </> rel, stamp)) | (rel, stamp) <- Map.toList files])
    single key real = do
      info <- tryIOError ((,) <$> getModificationTime real <*> getFileSize real)
      pure (either (const Map.empty) (\i -> Map.singleton key (real, i)) info)
