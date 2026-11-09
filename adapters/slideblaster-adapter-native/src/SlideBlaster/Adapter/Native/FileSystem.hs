{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Native.FileSystem
-- Description : Portable exact-byte loading and best-effort conditional persistence.
--
-- The native adapter uses ordinary Haskell filesystem libraries. A save
-- re-reads and compares the target, writes a temporary sibling, copies the
-- target's portable permissions, and renames the sibling over the target.
-- The comparison is intentionally described as best effort: the standard
-- library does not provide an atomic external-writer compare-and-exchange.
module SlideBlaster.Adapter.Native.FileSystem
  ( NativeFileSystem (..)
  , NativeFsError (..)
  , NativeSaveError (..)
  , createFileIfAbsent
  , loadSnapshot
  , nativeFileSystem
  , saveSnapshotIfUnchanged
  ) where

import SlideBlaster.Source
  ( SourceBufferSnapshot
  , snapshotBytes
  , snapshotFromBytes
  )

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text

import Control.Exception (bracketOnError)
import System.Directory
  ( copyPermissions
  , createDirectoryIfMissing
  , removeFile
  , renameFile
  )
import System.FilePath
  ( takeDirectory
  , takeFileName
  )
import System.IO
  ( Handle
  , hClose
  , hFlush
  , openBinaryTempFile
  )
import System.IO.Error (isAlreadyExistsError, tryIOError)
import System.Posix.Files (createLink)

-- | Host filesystem operations required by the native composition.
--
-- Keeping conditional replacement as one capability prevents callers from
-- accidentally separating the expected-byte check from the adapter write.
data NativeFileSystem m = NativeFileSystem
  { nativeReadFile :: FilePath -> m (Either NativeFsError ByteString)
  , nativeCompareAndReplace
      :: FilePath
      -> ByteString
      -> ByteString
      -> m (Either NativeSaveError ())
  }

-- | An I/O failure annotated with the affected path.
data NativeFsError = NativeFsError
  { nativeFsErrorPath :: !FilePath
  , nativeFsErrorMessage :: !Text
  }
  deriving (Eq, Show)

-- | A portable native save rejection.
data NativeSaveError
  = NativeSaveIoError !NativeFsError
  | NativeSaveConflict !FilePath
  deriving (Eq, Show)

-- | Interpret native storage with @bytestring@, @directory@, and @base@.
nativeFileSystem :: NativeFileSystem IO
nativeFileSystem =
  NativeFileSystem
    { nativeReadFile = readFileBytes
    , nativeCompareAndReplace = compareAndReplaceFile
    }

-- | Load a file as a new revision-zero engine snapshot.
loadSnapshot
  :: Functor m
  => NativeFileSystem m
  -> FilePath
  -> m (Either NativeFsError SourceBufferSnapshot)
loadSnapshot fileSystem path =
  fmap (fmap snapshotFromBytes) (nativeReadFile fileSystem path)

-- | Save a successor through the adapter's conditional replacement
-- capability.
--
-- A byte-identical successor is a storage no-op and does not invoke the
-- capability.
saveSnapshotIfUnchanged
  :: Applicative m
  => NativeFileSystem m
  -> FilePath
  -> ByteString
  -> SourceBufferSnapshot
  -> m (Either NativeSaveError ())
saveSnapshotIfUnchanged fileSystem path expectedCurrent successor
  | successorBytes == expectedCurrent = pure (Right ())
  | otherwise =
      nativeCompareAndReplace
        fileSystem
        path
        expectedCurrent
        successorBytes
  where
    successorBytes = snapshotBytes successor

-- | Create a file only if the path does not exist yet.
--
-- The bytes are written to a temporary sibling and then hard-linked into place,
-- which fails atomically when another writer created the target first
-- ('NativeSaveConflict'). Missing parent directories are created.
createFileIfAbsent :: FilePath -> ByteString -> IO (Either NativeSaveError ())
createFileIfAbsent path bytes = do
  prepared <- tryIOError (createDirectoryIfMissing True (takeDirectory path))
  case prepared of
    Left problem -> pure (Left (NativeSaveIoError (toNativeFsError path problem)))
    Right () -> do
      result <-
        tryIOError $
          bracketOnError
            (openBinaryTempFile (takeDirectory path) (takeFileName path <> ".slideblaster.tmp"))
            cleanupTemporarySibling
            ( \(temporaryPath, handle) -> do
                ByteString.hPut handle bytes
                hFlush handle
                hClose handle
                linked <- tryIOError (createLink temporaryPath path)
                _ <- tryIOError (removeFile temporaryPath)
                pure linked
            )
      pure $ case result of
        Left problem -> Left (NativeSaveIoError (toNativeFsError path problem))
        Right (Left problem)
          | isAlreadyExistsError problem -> Left (NativeSaveConflict path)
          | otherwise -> Left (NativeSaveIoError (toNativeFsError path problem))
        Right (Right ()) -> Right ()

readFileBytes :: FilePath -> IO (Either NativeFsError ByteString)
readFileBytes path = do
  result <- tryIOError (ByteString.readFile path)
  pure (mapLeft (toNativeFsError path) result)

compareAndReplaceFile
  :: FilePath
  -> ByteString
  -> ByteString
  -> IO (Either NativeSaveError ())
compareAndReplaceFile path expectedCurrent successor = do
  currentResult <- tryIOError (ByteString.readFile path)
  case currentResult of
    Left problem ->
      pure (Left (NativeSaveIoError (toNativeFsError path problem)))
    Right current
      | current /= expectedCurrent ->
          pure (Left (NativeSaveConflict path))
      | otherwise -> do
          installResult <-
            tryIOError (installWithTemporarySibling path successor)
          pure
            ( mapLeft
                (NativeSaveIoError . toNativeFsError path)
                installResult
            )

installWithTemporarySibling :: FilePath -> ByteString -> IO ()
installWithTemporarySibling path successor =
  bracketOnError
    (openBinaryTempFile directory template)
    cleanupTemporarySibling
    install
  where
    directory = takeDirectory path
    template = takeFileName path <> ".slideblaster.tmp"

    install :: (FilePath, Handle) -> IO ()
    install (temporaryPath, handle) = do
      ByteString.hPut handle successor
      hFlush handle
      hClose handle
      copyPermissions path temporaryPath
      renameFile temporaryPath path

cleanupTemporarySibling :: (FilePath, Handle) -> IO ()
cleanupTemporarySibling (temporaryPath, handle) = do
  _ <- tryIOError (hClose handle)
  _ <- tryIOError (removeFile temporaryPath)
  pure ()

toNativeFsError :: FilePath -> IOError -> NativeFsError
toNativeFsError path problem =
  NativeFsError
    { nativeFsErrorPath = path
    , nativeFsErrorMessage = Text.pack (show problem)
    }

mapLeft :: (left -> mapped) -> Either left right -> Either mapped right
mapLeft transform value =
  case value of
    Left problem -> Left (transform problem)
    Right result -> Right result
