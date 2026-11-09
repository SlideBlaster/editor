{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Native.Git
-- Description : Narrow native Git capability implemented without a shell.
--
-- The adapter invokes the local @git@ executable with an argument vector via
-- the Haskell @process@ library. Shared code sees only this capability record;
-- browser builds can supply a JavaScript-backed interpreter with the same
-- operation meanings.
module SlideBlaster.Adapter.Native.Git
  ( NativeGit (..)
  , NativeGitError (..)
  , nativeGit
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import System.Exit (ExitCode (..))
import System.IO.Error (tryIOError)
import System.Process
  ( CreateProcess (cwd)
  , proc
  , readCreateProcessWithExitCode
  )

-- | Git operations needed by the early local tool.
data NativeGit m = NativeGit
  { nativeGitVersion :: m (Either NativeGitError Text)
  , nativeGitStatus :: FilePath -> m (Either NativeGitError Text)
  }

-- | A process launch failure or a non-zero Git command result.
data NativeGitError
  = NativeGitLaunchError !Text
  | NativeGitCommandError !Int !Text
  deriving (Eq, Show)

-- | Native interpreter backed by the local @git@ executable.
nativeGit :: NativeGit IO
nativeGit =
  NativeGit
    { nativeGitVersion = runGit Nothing ["--version"]
    , nativeGitStatus =
        \repository ->
          runGit
            (Just repository)
            ["status", "--porcelain=v1", "--untracked-files=all"]
    }

runGit :: Maybe FilePath -> [String] -> IO (Either NativeGitError Text)
runGit workingDirectory arguments = do
  let command = (proc "git" arguments) {cwd = workingDirectory}
  result <- tryIOError (readCreateProcessWithExitCode command "")
  pure $
    case result of
      Left problem ->
        Left (NativeGitLaunchError (Text.pack (show problem)))
      Right (ExitSuccess, standardOutput, _) ->
        Right (Text.stripEnd (Text.pack standardOutput))
      Right (ExitFailure code, _, standardError) ->
        Left
          (NativeGitCommandError code (Text.stripEnd (Text.pack standardError)))
