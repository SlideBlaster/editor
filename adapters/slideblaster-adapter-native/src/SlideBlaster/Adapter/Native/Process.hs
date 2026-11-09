{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Native.Process
-- Description : Bounded child-process execution without a shell.
--
-- Runs an executable with an argument vector (never a shell string), a byte
-- budget on standard output, and a wall-clock timeout that interrupts the whole
-- process group. Used by the @sb.tex@ pipeline and the @stdio-json@ transport.
module SlideBlaster.Adapter.Native.Process
  ( RunSpec (..)
  , RunOutcome (..)
  , runLimited
  , findTool
  ) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (findExecutablesInDirectories)
import System.Exit (ExitCode)
import System.IO (Handle, hClose)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (..)
  , createProcess
  , interruptProcessGroupOf
  , proc
  , terminateProcess
  , waitForProcess
  )
import System.Timeout (timeout)

-- | What to run.
data RunSpec = RunSpec
  { runExecutable :: !FilePath
  , runArguments :: ![String]
  , runWorkingDirectory :: !(Maybe FilePath)
  , runStdin :: !ByteString
  , runTimeoutMs :: !Int
  , runMaxStdout :: !Int
  }

-- | How a run ended.
data RunOutcome
  = RunExited !ExitCode !ByteString !ByteString
  -- ^ Exit status, standard output, and the first 16 KiB of standard error.
  | RunTimedOut
  | RunTooLarge
  | RunSpawnFailed !Text

-- | Find an executable in the given directories (the search path).
findTool :: [FilePath] -> String -> IO (Maybe FilePath)
findTool dirs name = do
  found <- findExecutablesInDirectories dirs name
  pure $ case found of
    path : _ -> Just path
    [] -> Nothing

-- | Run a process under the spec's limits.
runLimited :: RunSpec -> IO RunOutcome
runLimited spec = do
  started <-
    try
      ( createProcess
          (proc (runExecutable spec) (runArguments spec))
            { cwd = runWorkingDirectory spec
            , std_in = CreatePipe
            , std_out = CreatePipe
            , std_err = CreatePipe
            , create_group = True
            }
      )
  case started of
    Left problem -> pure (RunSpawnFailed (Text.pack (show (problem :: SomeException))))
    Right (Just hin, Just hout, Just herr, ph) -> supervise hin hout herr ph
    Right _ -> pure (RunSpawnFailed "process pipes unavailable")
  where
    supervise hin hout herr ph = do
      _ <- forkIO (feed hin)
      outVar <- newEmptyMVar
      errVar <- newEmptyMVar
      readerOut <- forkIO (readBounded (runMaxStdout spec) (killGroup ph) hout >>= putMVar outVar)
      readerErr <- forkIO (readTruncated 16384 herr >>= putMVar errVar)
      finished <-
        timeout (runTimeoutMs spec * 1000) $ do
          out <- takeMVar outVar
          err <- takeMVar errVar
          code <- waitForProcess ph
          pure (code, out, err)
      case finished of
        Nothing -> do
          killGroup ph
          _ <- waitForProcess ph
          killThread readerOut
          killThread readerErr
          closeQuietly hout
          closeQuietly herr
          pure RunTimedOut
        Just (code, out, err) -> do
          closeQuietly hout
          closeQuietly herr
          pure $ case out of
            Nothing -> RunTooLarge
            Just bytes -> RunExited code bytes err
    feed hin = do
      _ <- try (ByteString.hPut hin (runStdin spec)) :: IO (Either SomeException ())
      closeQuietly hin

closeQuietly :: Handle -> IO ()
closeQuietly handle = do
  _ <- try (hClose handle) :: IO (Either SomeException ())
  pure ()

-- Read the whole stream, or 'Nothing' (after calling the hook) once it exceeds
-- the limit.
readBounded :: Int -> IO () -> Handle -> IO (Maybe ByteString)
readBounded limit onExceed handle = go [] 0
  where
    go chunks total = do
      chunk <- try (ByteString.hGetSome handle 32768) :: IO (Either SomeException ByteString)
      case chunk of
        Left _ -> pure (Just (ByteString.concat (reverse chunks)))
        Right bytes
          | ByteString.null bytes -> pure (Just (ByteString.concat (reverse chunks)))
          | total + ByteString.length bytes > limit -> onExceed >> pure Nothing
          | otherwise -> go (bytes : chunks) (total + ByteString.length bytes)

-- Keep the first @limit@ bytes and discard the rest, draining to EOF.
readTruncated :: Int -> Handle -> IO ByteString
readTruncated limit handle = go [] 0
  where
    go chunks total = do
      chunk <- try (ByteString.hGetSome handle 32768) :: IO (Either SomeException ByteString)
      case chunk of
        Left _ -> pure (ByteString.concat (reverse chunks))
        Right bytes
          | ByteString.null bytes -> pure (ByteString.concat (reverse chunks))
          | otherwise ->
              go (ByteString.take (limit - total) bytes : chunks) (min limit (total + ByteString.length bytes))

killGroup :: ProcessHandle -> IO ()
killGroup ph = do
  _ <- try (interruptProcessGroupOf ph) :: IO (Either SomeException ())
  _ <- try (terminateProcess ph) :: IO (Either SomeException ())
  pure ()
