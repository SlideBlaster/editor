{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Runtime-port contract tests.
--
-- These tests exercise the target-neutral laws using native GHC: portable
-- path rejection, exact expected-byte writes, source revision fencing,
-- structured Git requests, measurement correlation, and explicit absence.
module Main (main) where

import SlideBlaster.Canvas
  ( ElementId (..)
  , canvasUnit
  , canvasUnitValue
  , mkSize
  , nodeId
  , sizeHeight
  , sizeWidth
  )
import SlideBlaster.Ports
import SlideBlaster.Presentation
  ( SurfaceKind (..)
  , elementAddress
  , mkFrameId
  , surfaceAddress
  )
import SlideBlaster.Render
  ( MeasurementKey (..)
  , MeasurementMode (..)
  , MeasurementRequest (..)
  , RenderContent (..)
  , RenderContentRole (..)
  , emptyResourceManifest
  , measurementPartText
  , measurementResultKey
  , measurementResultSize
  , measurementResultTicket
  , measurementTicketFromWord64
  , mkMeasurementBatch
  , mkMeasurementPart
  )
import SlideBlaster.Source
  ( advanceSnapshot
  , initialRevision
  , snapshotAtRevision
  , snapshotBytes
  , snapshotFromBytes
  )

import Data.ByteString qualified as ByteString
import Data.IORef
  ( modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text

import Control.Monad (unless)
import System.Exit (exitFailure)

main :: IO ()
main = do
  workspacePathsArePortable
  sourceWritesPreserveExactCondition
  staleSourceSuccessorDoesNotReachStorage
  gitRequestsStayStructured
  gitPortRejectsMismatchedHostResponse
  measurementUsesAuthoritativeTicketAndKey
  measurementFailureIsExplicit
  archiveBytesCannotClaimEmptySuccess
  compilerPortRejectsMismatchedResult
  unavailableCapabilityIsExplicit

workspacePathsArePortable :: IO ()
workspacePathsArePortable = do
  accepted <- requireRight "valid workspace path" (mkWorkspacePath "themes/é/theme.json")
  assertEqual
    "valid path renders without normalization drift"
    "themes/é/theme.json"
    (workspacePathText accepted)
  assertEqual
    "valid path segments"
    ("themes" :| ["é", "theme.json"])
    (workspacePathSegments accepted)
  traverse_
    ( \(label, source, expected) ->
        assertEqual label (Left expected) (mkWorkspacePath source)
    )
    [ ("empty path", "", WorkspacePathEmpty)
    , ("absolute path", "/deck.md", WorkspacePathAbsolute)
    ,
      ( "backslash path"
      , "themes\\escape"
      , WorkspacePathContainsBackslash
      )
    ,
      ( "empty segment"
      , "themes//theme.json"
      , WorkspacePathContainsEmptySegment
      )
    ,
      ( "current segment"
      , "themes/./theme.json"
      , WorkspacePathContainsCurrentSegment
      )
    ,
      ( "parent segment"
      , "themes/../theme.json"
      , WorkspacePathContainsParentSegment
      )
    ,
      ( "Windows drive"
      , "C:/escape"
      , WorkspacePathContainsWindowsDrive
      )
    ,
      ( "Windows drive-relative path"
      , "C:escape"
      , WorkspacePathContainsWindowsDrive
      )
    ,
      ( "NUL path"
      , "themes/\NUL/theme.json"
      , WorkspacePathContainsNull
      )
    ,
      ( "control path"
      , "themes/\n/theme.json"
      , WorkspacePathContainsControl
      )
    ,
      ( "overlong path"
      , Text.replicate 241 "a"
      , WorkspacePathTooLong
      )
    ]

sourceWritesPreserveExactCondition :: IO ()
sourceWritesPreserveExactCondition = do
  workspace <- requireMaybe "workspace id" (mkWorkspaceId "test-workspace")
  path <- requireRight "source path" (mkWorkspacePath "deck.slide")
  captured <- newIORef ([] :: [ConditionalWrite])
  let storage =
        StoragePort
          { storageWorkspaceId = workspace
          , storageArbitraryBytesSupport = CapabilityProvided ()
          , storageCreateSupport = CapabilityProvided ()
          , storageReplaceSupport = CapabilityProvided ()
          , storageListFiles = pure (Right [])
          , storageReadFile = \_ -> pure (Right Nothing)
          , storageWriteFile = \request -> do
              modifyIORef' captured (request :)
              pure (Right StorageWritten)
          }
      before = snapshotFromBytes "before"
  after <-
    requireRight
      "changed source successor"
      (advanceSnapshot "after" before)
  result <- saveSourceSnapshot storage path before after
  assertEqual "source save succeeds" (Right StorageWritten) result
  requests <- readIORef captured
  case requests of
    [request] -> do
      assertEqual "source save path" path (conditionalWritePath request)
      assertEqual
        "source save exact expected bytes"
        (ExpectExact (snapshotBytes before))
        (conditionalWriteExpected request)
      assertEqual
        "source save exact successor bytes"
        (snapshotBytes after)
        (conditionalWriteValue request)
    _ -> failTest "source save did not issue exactly one conditional write"

staleSourceSuccessorDoesNotReachStorage :: IO ()
staleSourceSuccessorDoesNotReachStorage = do
  workspace <- requireMaybe "workspace id" (mkWorkspaceId "test-workspace")
  path <- requireRight "source path" (mkWorkspacePath "deck.slide")
  writes <- newIORef (0 :: Int)
  let storage =
        StoragePort
          { storageWorkspaceId = workspace
          , storageArbitraryBytesSupport = CapabilityProvided ()
          , storageCreateSupport = CapabilityProvided ()
          , storageReplaceSupport = CapabilityProvided ()
          , storageListFiles = pure (Right [])
          , storageReadFile = \_ -> pure (Right Nothing)
          , storageWriteFile = \_ -> do
              modifyIORef' writes (+ 1)
              pure (Right StorageWritten)
          }
      before = snapshotFromBytes "before"
      invalidSuccessor = snapshotAtRevision initialRevision "changed"
  result <-
    saveSourceSnapshot storage path before invalidSuccessor
  assertEqual
    "non-newer changed snapshot is rejected"
    (Left (StorageInvalidSourceSuccessor initialRevision initialRevision))
    result
  assertEqual "invalid successor causes no write" 0
    =<< readIORef writes

gitRequestsStayStructured :: IO ()
gitRequestsStayStructured = do
  branch <- requireRight "branch" (mkGitBranchName "feature/runtime-ports")
  remote <- requireRight "remote" (mkGitRemoteName "origin")
  message <-
    requireRight
      "commit message"
      (mkGitCommitMessage "runtime ports; $(never-a-shell)")
  path <- requireRight "git path" (mkWorkspacePath "deck.slide")
  let stageRequest = GitStageRequest (path :| [])
  assertEqual
    "stage operation remains structured"
    GitStageOperation
    (gitRequestOperation stageRequest)
  assertEqual
    "commit operation remains structured"
    GitCommitOperation
    (gitRequestOperation (GitCommitRequest message))
  assertEqual
    "push operation remains structured"
    GitPushOperation
    (gitRequestOperation (GitPushRequest remote branch))
  assertEqual
    "response kind is checked"
    (Left (GitUnexpectedResponse GitStatusOperation))
    (validateGitResponse GitStatusRequest (GitVersionResponse "git version"))
  assertEqual
    "query requests cannot accept mutation completion"
    (Left (GitUnexpectedResponse GitVersionOperation))
    ( validateGitResponse
        GitVersionRequest
        (GitCompletedResponse GitVersionOperation)
    )
  assertEqual
    "unsafe ref is rejected before an adapter"
    (Left GitNameUnsafe)
    (mkGitBranchName "main;touch-pwned")

gitPortRejectsMismatchedHostResponse :: IO ()
gitPortRejectsMismatchedHostResponse = do
  workspace <-
    requireMaybe "Git response workspace" (mkWorkspaceId "git-response-test")
  dispatches <- newIORef (0 :: Int)
  let port =
        gitPort
          workspace
          (\_ -> CapabilityProvided ())
          (\_ -> pure (Right (GitVersionResponse "wrong response")))
      unavailablePort =
        gitPort
          workspace
          ( \_ ->
              CapabilityUnavailable
                CapabilityAbsence
                  { absentCapability = GitCapability
                  , capabilityAbsenceReason =
                      NotImplementedForTarget "test"
                  }
          )
          ( \_ -> do
              modifyIORef' dispatches (+ 1)
              pure (Right (GitStatusResponse (gitStatusSnapshot "")))
          )
  assertEqual
    "Git port fences every successful response"
    (Left (GitUnexpectedResponse GitStatusOperation))
    =<< runGitRequest port GitStatusRequest
  assertEqual
    "unsupported Git operation fails before target dispatch"
    (Left (GitOperationUnsupported GitStatusOperation))
    =<< runGitRequest unavailablePort GitStatusRequest
  assertEqual "unsupported Git operation dispatch count" 0
    =<< readIORef dispatches

measurementUsesAuthoritativeTicketAndKey :: IO ()
measurementUsesAuthoritativeTicketAndKey = do
  request <- plainMeasurementRequest
  measuredSize <-
    requireRight
      "measured size"
      (mkSize (canvasUnit (5 / 4)) (canvasUnit (2 / 5)))
  let ticket = measurementTicketFromWord64 42
      result =
        measurementResultForRequest
          ticket
          request
          measuredSize
  assertEqual "measurement ticket preserved" ticket (measurementResultTicket result)
  assertEqual "measurement key preserved" (measurementKey request) (measurementResultKey result)
  assertEqual
    "pixel width translated to slide units"
    (5 / 4)
    (canvasUnitValue (sizeWidth (measurementResultSize result)))
  assertEqual
    "pixel height translated to slide units"
    (2 / 5)
    (canvasUnitValue (sizeHeight (measurementResultSize result)))

measurementFailureIsExplicit :: IO ()
measurementFailureIsExplicit = do
  request <- plainMeasurementRequest
  let ticket = measurementTicketFromWord64 7
      expected =
        MeasurementRequestUnsupported "structured render content"
      port =
        MeasurementPort
          { runMeasurementBatch = \_ -> pure (Left expected)
          }
  batch <-
    requireRight
      "measurement failure batch"
      (mkMeasurementBatch ticket emptyResourceManifest [request])
  actual <- runMeasurementBatch port batch
  assertEqual
    "an insufficient host remains a typed failure"
    (Left expected)
    actual

archiveBytesCannotClaimEmptySuccess :: IO ()
archiveBytesCannotClaimEmptySuccess = do
  assertEqual
    "empty archive output is rejected"
    (Left ArchiveResultEmpty)
    (mkArchiveBytes ByteString.empty)
  archive <-
    requireRight
      "non-empty archive output"
      (mkArchiveBytes "PK deterministic archive bytes")
  assertEqual
    "archive bytes remain exact"
    "PK deterministic archive bytes"
    (archiveBytesValue archive)

compilerPortRejectsMismatchedResult :: IO ()
compilerPortRejectsMismatchedResult = do
  dispatches <- newIORef (0 :: Int)
  let request =
        CompileRequest
          { compileKind = LatexFragmentToHtml
          , compilePrimarySource = snapshotFromBytes "x + y"
          , compileAuxiliaryEntries = []
          }
      port =
        compilerPort
          (\_ -> CapabilityProvided ())
          (\_ -> pure (Right (CompiledSvg "<svg/>")))
      unavailablePort =
        compilerPort
          ( \_ ->
              CapabilityUnavailable
                CapabilityAbsence
                  { absentCapability = CompilerCapability
                  , capabilityAbsenceReason =
                      NotImplementedForTarget "test"
                  }
          )
          ( \_ -> do
              modifyIORef' dispatches (+ 1)
              pure (Right (CompiledHtml "unreachable"))
          )
  assertEqual
    "compiler port fences result media kind"
    (Left (CompileUnexpectedResult LatexFragmentToHtml))
    =<< runCompiler port request
  assertEqual
    "unsupported compiler kind fails before target dispatch"
    (Left (CompileKindUnsupported LatexFragmentToHtml))
    =<< runCompiler unavailablePort request
  assertEqual "unsupported compiler dispatch count" 0
    =<< readIORef dispatches

unavailableCapabilityIsExplicit :: IO ()
unavailableCapabilityIsExplicit = do
  let absence =
        CapabilityAbsence
          { absentCapability = PrintCapability
          , capabilityAbsenceReason =
              HostOperationMissing "print.execute"
          }
      provision =
        CapabilityUnavailable absence
          :: CapabilityProvision (PrintPort IO)
  assertEqual "unavailable port is observable" False (capabilityIsProvided provision)

plainMeasurementRequest :: IO MeasurementRequest
plainMeasurementRequest = do
  frame <- requireRight "frame id" (mkFrameId "frame-1")
  node <- requireMaybe "node id" (nodeId "node-1")
  part <- requireMaybe "measurement part" (mkMeasurementPart "body")
  let key =
        MeasurementKey
          { measurementElement =
              elementAddress
                (surfaceAddress frame AudienceSurface)
                (NodeElement node)
          , measurementPart = part
          }
  assertEqual "measurement part spelling" "body" (measurementPartText part)
  pure
    MeasurementRequest
      { measurementKey = key
      , measurementContent =
          RenderContainer InlineFlow []
      , measurementMode = MeasureWithin (canvasUnit 5)
      }

requireRight :: Show problem => String -> Either problem value -> IO value
requireRight label result =
  case result of
    Left problem -> failTest (label <> ": " <> show problem)
    Right value -> pure value

requireMaybe :: String -> Maybe value -> IO value
requireMaybe label result =
  case result of
    Nothing -> failTest (label <> ": construction failed")
    Just value -> pure value

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $
    failTest
      (label <> ": expected " <> show expected <> ", got " <> show actual)

failTest :: String -> IO value
failTest message = do
  putStrLn ("FAIL: " <> message)
  exitFailure

traverse_ :: Applicative effect => (value -> effect ignored) -> [value] -> effect ()
traverse_ action =
  foldr
    (\value rest -> action value *> rest)
    (pure ())
