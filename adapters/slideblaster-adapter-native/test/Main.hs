{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Portable native filesystem adapter contract tests.
--
-- The production adapter uses ordinary Haskell filesystem libraries. These
-- tests prove exact bytes, the best-effort expected-byte check, temporary-file
-- cleanup after a successful rename, portable permission copying, and
-- byte-identical storage elision.
module Main (main) where

import SlideBlaster.Adapter.Native
  ( NativeFileSystem (..)
  , NativeFsError (..)
  , NativeSaveError (..)
  , loadSnapshot
  , nativeFileSystem
  , saveSnapshotIfUnchanged
  )
import SlideBlaster.Adapter.Native.Port
  ( nativeClockProvision
  , nativeGitProvision
  , nativeLogProvision
  , nativeStorageProvision
  )
import SlideBlaster.Ports
  ( CapabilityProvision (..)
  , ExpectedContent (..)
  , GitError (..)
  , GitOperation (..)
  , GitRequest (..)
  , GitResponse (..)
  , LogEntry (..)
  , LogLevel (..)
  , StorageError (..)
  , StorageWriteOutcome (..)
  , capabilityIsProvided
  , conditionalWrite
  , gitOperationProvision
  , gitStatusSnapshotText
  , gitWorkspaceId
  , mkGitBranchName
  , mkWorkspaceId
  , mkWorkspacePath
  , readTimerOrigin
  , runGitRequest
  , storageArbitraryBytesSupport
  , storageCreateSupport
  , storageListFiles
  , storageReadFile
  , storageReplaceSupport
  , storageWorkspaceId
  , storageWriteFile
  , timerOriginMilliseconds
  , writeLogEntry
  )
import SlideBlaster.Source
  ( snapshotBytes
  , snapshotFromBytes
  )

import Data.ByteString qualified as ByteString
import Data.IORef
  ( modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List (isInfixOf)
import Data.Text qualified as Text

import Control.Exception (bracket)
import Control.Monad (unless)
import System.Directory
  ( createDirectory
  , createFileLink
  , getDirectoryContents
  , getPermissions
  , getTemporaryDirectory
  , removeFile
  , removePathForcibly
  )
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO
  ( hClose
  , openBinaryTempFile
  )
import System.Process (callProcess)

main :: IO ()
main =
  withTemporaryDirectory $ \root -> do
    exactLoadPreservesBytes root
    successfulReplacementPreservesPermissions root
    staleBytesAreRejected root
    byteIdenticalSaveIsNoOp
    changedSaveInvokesCapability
    missingFileIsTyped root
    nativePortWorkspaceContracts root
    nativePortGitClockAndLogContracts root

exactLoadPreservesBytes :: FilePath -> IO ()
exactLoadPreservesBytes root = do
  let path = root </> "exact.slide"
      expected = ByteString.pack [0, 10, 255, 92, 110]
  ByteString.writeFile path expected
  result <- loadSnapshot nativeFileSystem path
  case result of
    Left problem -> failTest ("exact load failed: " <> show problem)
    Right snapshot ->
      assertEqual "exact load bytes" expected (snapshotBytes snapshot)

successfulReplacementPreservesPermissions :: FilePath -> IO ()
successfulReplacementPreservesPermissions root = do
  let path = root </> "success.slide"
  ByteString.writeFile path "before"
  permissionsBefore <- getPermissions path
  result <-
    saveSnapshotIfUnchanged
      nativeFileSystem
      path
      "before"
      (snapshotFromBytes "after")
  assertEqual "successful replacement" (Right ()) result
  assertEqual
    "successful replacement bytes"
    "after"
    =<< ByteString.readFile path
  permissionsAfter <- getPermissions path
  assertEqual
    "portable permissions are copied"
    permissionsBefore
    permissionsAfter
  directoryEntries <- getDirectoryContents root
  assertEqual
    "successful replacement leaves no temporary sibling"
    []
    (filter (".slideblaster.tmp" `isInfixOf`) directoryEntries)

staleBytesAreRejected :: FilePath -> IO ()
staleBytesAreRejected root = do
  let path = root </> "conflict.slide"
  ByteString.writeFile path "newer external bytes"
  result <-
    saveSnapshotIfUnchanged
      nativeFileSystem
      path
      "older bytes"
      (snapshotFromBytes "proposed")
  assertEqual
    "stale bytes report conflict"
    (Left (NativeSaveConflict path))
    result
  assertEqual
    "stale target remains unchanged"
    "newer external bytes"
    =<< ByteString.readFile path

byteIdenticalSaveIsNoOp :: IO ()
byteIdenticalSaveIsNoOp = do
  compareCount <- newIORef (0 :: Int)
  let fileSystem =
        NativeFileSystem
          { nativeReadFile = \_ -> pure (Right "before")
          , nativeCompareAndReplace =
              \_ _ _ -> do
                modifyIORef' compareCount (+ 1)
                pure (Right ())
          }
  result <-
    saveSnapshotIfUnchanged
      fileSystem
      "ignored"
      "before"
      (snapshotFromBytes "before")
  assertEqual "byte-identical save succeeds" (Right ()) result
  assertEqual "byte-identical save skips capability" 0
    =<< readIORef compareCount

changedSaveInvokesCapability :: IO ()
changedSaveInvokesCapability = do
  compareCount <- newIORef (0 :: Int)
  let fileSystem =
        NativeFileSystem
          { nativeReadFile = \_ -> pure (Right "before")
          , nativeCompareAndReplace =
              \_ expected successor -> do
                assertEqual "capability expected bytes" "before" expected
                assertEqual "capability successor bytes" "after" successor
                modifyIORef' compareCount (+ 1)
                pure (Right ())
          }
  result <-
    saveSnapshotIfUnchanged
      fileSystem
      "ignored"
      "before"
      (snapshotFromBytes "after")
  assertEqual "changed save succeeds" (Right ()) result
  assertEqual "changed save calls capability once" 1
    =<< readIORef compareCount

missingFileIsTyped :: FilePath -> IO ()
missingFileIsTyped root = do
  let path = root </> "missing.slide"
  result <- loadSnapshot nativeFileSystem path
  case result of
    Left problem ->
      assertEqual "missing-file diagnostic path" path (nativeFsErrorPath problem)
    Right _ -> failTest "missing file unexpectedly loaded"

nativePortWorkspaceContracts :: FilePath -> IO ()
nativePortWorkspaceContracts parent = do
  let root = parent </> "ports-workspace"
  createDirectory root
  workspace <-
    requireMaybe "native port workspace id" (mkWorkspaceId "native-test")
  storage <-
    requireProvision
      "native storage provision"
      (nativeStorageProvision workspace root)
  assertEqual
    "native storage retains workspace identity"
    workspace
    (storageWorkspaceId storage)
  assertEqual
    "native storage preserves arbitrary bytes"
    True
    (capabilityIsProvided (storageArbitraryBytesSupport storage))
  assertEqual
    "portable native conditional create is unavailable"
    False
    (capabilityIsProvided (storageCreateSupport storage))
  assertEqual
    "portable native expected-byte replacement is available"
    True
    (capabilityIsProvided (storageReplaceSupport storage))

  aPath <- requireRight "native port a path" (mkWorkspacePath "a.txt")
  bPath <- requireRight "native port b path" (mkWorkspacePath "nested/b.txt")
  nestedSortPath <-
    requireRight "native port nested sort path" (mkWorkspacePath "a/x.txt")
  createDirectory (root </> "a")
  createDirectory (root </> "nested")
  ByteString.writeFile (root </> "a.txt") "alpha"
  ByteString.writeFile (root </> "a" </> "x.txt") "nested alpha"
  ByteString.writeFile (root </> "nested" </> "b.txt") "bravo"
  createDirectory (root </> ".git")
  ByteString.writeFile (root </> ".git" </> "private") "not-user-storage"
  createDirectory (root </> "nested" </> ".git")
  ByteString.writeFile
    (root </> "nested" </> ".git" </> "private")
    "not-user-storage-either"

  listed <- storageListFiles storage
  assertEqual
    "native workspace traversal is globally sorted and excludes every .git"
    (Right [aPath, nestedSortPath, bPath])
    listed
  assertEqual
    "native workspace exact read"
    (Right (Just "alpha"))
    =<< storageReadFile storage aPath

  changed <-
    storageWriteFile storage
      (conditionalWrite aPath (ExpectExact "alpha") "changed")
  assertEqual
    "native expected-byte replacement succeeds"
    (Right StorageWritten)
    changed
  assertEqual
    "native expected-byte replacement writes exact bytes"
    "changed"
    =<< ByteString.readFile (root </> "a.txt")

  stale <-
    storageWriteFile storage
      (conditionalWrite aPath (ExpectExact "alpha") "stale")
  assertEqual
    "native stale replacement conflicts"
    (Left (StorageConflict aPath))
    stale
  assertEqual
    "native stale replacement leaves bytes unchanged"
    "changed"
    =<< ByteString.readFile (root </> "a.txt")

  ByteString.writeFile (root </> "a.txt") "external"
  staleNoOp <-
    storageWriteFile storage
      (conditionalWrite aPath (ExpectExact "changed") "changed")
  assertEqual
    "native byte-identical request still checks expected disk bytes"
    (Left (StorageConflict aPath))
    staleNoOp
  matchedNoOp <-
    storageWriteFile storage
      (conditionalWrite aPath (ExpectExact "external") "external")
  assertEqual
    "native matched byte-identical request is unchanged"
    (Right StorageUnchanged)
    matchedNoOp

  newPath <- requireRight "native port new path" (mkWorkspacePath "new.txt")
  unsupportedCreate <-
    storageWriteFile storage
      (conditionalWrite newPath ExpectAbsent "new")
  assertEqual
    "native conditional create fails without mutation"
    (Left (StorageConditionalWriteUnsupported newPath))
    unsupportedCreate
  newExists <- storageReadFile storage newPath
  assertEqual "unsupported create did not create a file" (Right Nothing) newExists

  linkPath <- requireRight "native port link path" (mkWorkspacePath "escape.txt")
  createFileLink (parent </> "exact.slide") (root </> "escape.txt")
  linkedListing <- storageListFiles storage
  assertEqual
    "native traversal rejects symbolic links"
    (Left (StorageUnsafeFilesystemEntry linkPath))
    linkedListing
  assertEqual
    "native exact read rejects symbolic links"
    (Left (StorageUnsafeFilesystemEntry linkPath))
    =<< storageReadFile storage linkPath
  assertEqual
    "native replacement rejects symbolic links without following them"
    (Left (StorageUnsafeFilesystemEntry linkPath))
    =<< storageWriteFile storage
      (conditionalWrite linkPath (ExpectExact "untrusted") "replacement")

nativePortGitClockAndLogContracts :: FilePath -> IO ()
nativePortGitClockAndLogContracts parent = do
  let root = parent </> "git-workspace"
  createDirectory root
  callProcess "git" ["init", "--quiet", root]
  ByteString.writeFile (root </> "deck.slide") "slide"
  workspace <-
    requireMaybe "native Git workspace id" (mkWorkspaceId "native-git-test")
  git <-
    requireProvision
      "native Git provision"
      (nativeGitProvision workspace root)
  assertEqual
    "native Git retains workspace identity"
    workspace
    (gitWorkspaceId git)
  assertEqual
    "native Git status is advertised"
    True
    (capabilityIsProvided (gitOperationProvision git GitStatusOperation))
  assertEqual
    "native Git commit is honestly unavailable"
    False
    (capabilityIsProvided (gitOperationProvision git GitCommitOperation))
  version <- runGitRequest git GitVersionRequest
  case version of
    Right (GitVersionResponse value)
      | "git version " `Text.isPrefixOf` value -> pure ()
      | otherwise -> failTest "native Git version response has unexpected text"
    other -> failTest ("native Git version failed: " <> show other)
  status <- runGitRequest git GitStatusRequest
  case status of
    Right (GitStatusResponse snapshot)
      | "deck.slide" `Text.isInfixOf` gitStatusSnapshotText snapshot -> pure ()
      | otherwise -> failTest "native Git status omitted the untracked deck"
    other -> failTest ("native Git status failed: " <> show other)
  branch <-
    requireRight
      "native Git initialization branch"
      (mkGitBranchName "main")
  assertEqual
    "unsupported native Git operation does not synthesize success"
    (Left (GitOperationUnsupported GitInitializeOperation))
    =<< runGitRequest
      git
      (GitInitializeRequest branch)

  clock <-
    requireProvision "native clock provision" nativeClockProvision
  first <- readTimerOrigin clock
  second <- readTimerOrigin clock
  case (first, second) of
    (Right firstOrigin, Right secondOrigin) ->
      assertEqual
        "native monotonic clock does not move backwards"
        True
        ( timerOriginMilliseconds secondOrigin
            >= timerOriginMilliseconds firstOrigin
        )
    other -> failTest ("native clock failed: " <> show other)

  logger <-
    requireProvision "native log provision" nativeLogProvision
  assertEqual
    "native structured logger executes"
    (Right ())
    =<< writeLogEntry
      logger
      LogEntry
        { logEntryLevel = InfoLog
        , logEntryMessage = "native port test"
        , logEntryFields = []
        }

withTemporaryDirectory :: (FilePath -> IO value) -> IO value
withTemporaryDirectory action = do
  temporaryDirectory <- getTemporaryDirectory
  bracket
    (do
      (path, handle) <-
        openBinaryTempFile temporaryDirectory "slideblaster-native-tests"
      hClose handle
      removeFile path
      createDirectory path
      pure path
    )
    removePathForcibly
    action

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $
    failTest (label <> ": expected " <> show expected <> ", got " <> show actual)

failTest :: String -> IO value
failTest message = do
  putStrLn ("FAIL: " <> message)
  exitFailure

requireMaybe :: String -> Maybe value -> IO value
requireMaybe label result =
  case result of
    Nothing -> failTest (label <> ": construction failed")
    Just value -> pure value

requireRight :: Show problem => String -> Either problem value -> IO value
requireRight label result =
  case result of
    Left problem -> failTest (label <> ": " <> show problem)
    Right value -> pure value

requireProvision
  :: String
  -> CapabilityProvision capability
  -> IO capability
requireProvision label provision =
  case provision of
    CapabilityProvided capability -> pure capability
    CapabilityUnavailable absence ->
      failTest (label <> ": " <> show absence)
