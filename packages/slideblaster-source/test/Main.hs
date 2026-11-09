-- |
-- Module      : Main
-- Description : Executable contract tests for byte-exact source replacement.
--
-- These dependency-free tests exercise the source laws that every native and
-- Wasm composition must share.
module Main (main) where

import Control.Monad (unless)
import Data.ByteString.Char8 qualified as ByteString
import System.Exit (exitFailure)
import SlideBlaster.Source

main :: IO ()
main = do
  successfulReplacement
  staleReplacement
  expectedMismatch
  noOpReplacement
  insertionAndDeletion
  arbitraryBytesRemainLocal
  outOfBoundsReplacement
  exhaustedRevision
  portableOffsetLimit

successfulReplacement :: IO ()
successfulReplacement = do
  let snapshot = snapshotFromBytes (ByteString.pack "left (1,2) right")
      target = requireSpan 5 10
      replacement =
        mkExactReplacement
          (snapshotRevision snapshot)
          target
          (ByteString.pack "(1,2)")
          (ByteString.pack "(3,4)")
  case applyExactReplacement replacement snapshot of
    Left problem -> failTest ("successful replacement rejected: " <> show problem)
    Right updated -> do
      assertEqual
        "only the target bytes change"
        (ByteString.pack "left (3,4) right")
        (snapshotBytes updated)
      assertEqual
        "a changed source advances once"
        (revisionFromWord64 1)
        (snapshotRevision updated)

staleReplacement :: IO ()
staleReplacement = do
  let snapshot = snapshotFromBytes (ByteString.pack "abc")
      replacement =
        mkExactReplacement
          (revisionFromWord64 1)
          (requireSpan 0 1)
          (ByteString.pack "a")
          (ByteString.pack "z")
  case applyExactReplacement replacement snapshot of
    Left ReplacementStale {} -> pure ()
    other -> failTest ("stale edit was not fenced: " <> show other)

expectedMismatch :: IO ()
expectedMismatch = do
  let snapshot = snapshotFromBytes (ByteString.pack "abc")
      replacement =
        mkExactReplacement
          (snapshotRevision snapshot)
          (requireSpan 1 2)
          (ByteString.pack "x")
          (ByteString.pack "z")
  case applyExactReplacement replacement snapshot of
    Left ReplacementExpectedMismatch {} -> pure ()
    other -> failTest ("expected-byte mismatch was not rejected: " <> show other)

noOpReplacement :: IO ()
noOpReplacement = do
  let snapshot = snapshotFromBytes (ByteString.pack "abc")
      replacement =
        mkExactReplacement
          (snapshotRevision snapshot)
          (requireSpan 1 2)
          (ByteString.pack "b")
          (ByteString.pack "b")
  case applyExactReplacement replacement snapshot of
    Left problem -> failTest ("no-op replacement rejected: " <> show problem)
    Right updated ->
      assertEqual
        "byte-identical replacement keeps its revision"
        (snapshotRevision snapshot)
        (snapshotRevision updated)

insertionAndDeletion :: IO ()
insertionAndDeletion = do
  let beforeInsert = snapshotFromBytes (ByteString.pack "ac")
      insert =
        mkExactReplacement
          (snapshotRevision beforeInsert)
          (requireSpan 1 1)
          ByteString.empty
          (ByteString.pack "b")
  afterInsert <-
    case applyExactReplacement insert beforeInsert of
      Left problem -> failTest ("insertion rejected: " <> show problem)
      Right value -> pure value
  assertEqual
    "empty span inserts without changing neighbours"
    (ByteString.pack "abc")
    (snapshotBytes afterInsert)

  let delete =
        mkExactReplacement
          (snapshotRevision afterInsert)
          (requireSpan 1 2)
          (ByteString.pack "b")
          ByteString.empty
  case applyExactReplacement delete afterInsert of
    Left problem -> failTest ("deletion rejected: " <> show problem)
    Right afterDelete ->
      assertEqual
        "empty value deletes only the span"
        (ByteString.pack "ac")
        (snapshotBytes afterDelete)

arbitraryBytesRemainLocal :: IO ()
arbitraryBytesRemainLocal = do
  let snapshot = snapshotFromBytes (ByteString.pack "\NUL\255old\128\LF")
      replacement =
        mkExactReplacement
          (snapshotRevision snapshot)
          (requireSpan 2 5)
          (ByteString.pack "old")
          (ByteString.pack "new")
  case applyExactReplacement replacement snapshot of
    Left problem -> failTest ("arbitrary-byte replacement rejected: " <> show problem)
    Right updated ->
      assertEqual
        "non-UTF8 prefix and suffix remain byte-identical"
        (ByteString.pack "\NUL\255new\128\LF")
        (snapshotBytes updated)

outOfBoundsReplacement :: IO ()
outOfBoundsReplacement = do
  let snapshot = snapshotFromBytes (ByteString.pack "abc")
      replacement =
        mkExactReplacement
          (snapshotRevision snapshot)
          (requireSpan 0 4)
          (ByteString.pack "abc?")
          ByteString.empty
  case applyExactReplacement replacement snapshot of
    Left ReplacementOutOfBounds {} -> pure ()
    other -> failTest ("out-of-bounds edit was not rejected: " <> show other)

exhaustedRevision :: IO ()
exhaustedRevision = do
  let snapshot =
        snapshotAtRevision
          (revisionFromWord64 maxBound)
          (ByteString.pack "a")
      replacement =
        mkExactReplacement
          (snapshotRevision snapshot)
          (requireSpan 0 1)
          (ByteString.pack "a")
          (ByteString.pack "b")
  case applyExactReplacement replacement snapshot of
    Left ReplacementRevisionExhausted {} -> pure ()
    other -> failTest ("revision exhaustion was not rejected: " <> show other)

portableOffsetLimit :: IO ()
portableOffsetLimit =
  case sourceSpanFromInts 0 2_147_483_648 of
    Nothing -> pure ()
    Just value -> failTest ("non-portable byte offset was accepted: " <> show value)

requireSpan :: Int -> Int -> SourceSpan
requireSpan start end =
  case sourceSpanFromInts start end of
    Nothing -> error "test bug: invalid source span"
    Just spanValue -> spanValue

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $
    failTest (label <> ": expected " <> show expected <> ", got " <> show actual)

failTest :: String -> IO value
failTest message = do
  putStrLn ("FAIL: " <> message)
  exitFailure
