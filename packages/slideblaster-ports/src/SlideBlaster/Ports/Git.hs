{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Ports.Git
-- Description : Structured Git requests bound to one workspace root.
--
-- Shared code can request Git operations but can never construct a shell
-- command. Native adapters translate each constructor to an executable plus an
-- argument array; browser adapters encode the same closed vocabulary.
module SlideBlaster.Ports.Git
  ( GitBranchName
  , GitNameError (..)
  , mkGitBranchName
  , gitBranchNameText
  , GitRemoteName
  , mkGitRemoteName
  , gitRemoteNameText
  , GitCommitMessage
  , GitCommitMessageError (..)
  , mkGitCommitMessage
  , gitCommitMessageText
  , GitHistoryLimit
  , mkGitHistoryLimit
  , gitHistoryLimitValue
  , GitOperation (..)
  , GitRequest (..)
  , gitRequestOperation
  , GitStatusSnapshot
  , gitStatusSnapshot
  , gitStatusSnapshotText
  , GitCommitRecord (..)
  , GitResponse (..)
  , GitError (..)
  , validateGitResponse
  , GitPort
  , gitPort
  , gitWorkspaceId
  , gitOperationProvision
  , runGitRequest
  ) where

import SlideBlaster.Ports.Capability
  ( CapabilityProvision (..)
  , RuntimeFailure
  )
import SlideBlaster.Ports.Workspace (WorkspaceId, WorkspacePath)

import Data.Char (isAsciiLower, isAsciiUpper)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

newtype GitBranchName = GitBranchName Text
  deriving stock (Eq, Ord, Show)

newtype GitRemoteName = GitRemoteName Text
  deriving stock (Eq, Ord, Show)

data GitNameError
  = GitNameEmpty
  | GitNameUnsafe
  deriving stock (Eq, Ord, Show)

-- | Validate a conservative branch-name subset accepted identically by hosts.
mkGitBranchName :: Text -> Either GitNameError GitBranchName
mkGitBranchName value =
  GitBranchName <$> validateGitName True value

gitBranchNameText :: GitBranchName -> Text
gitBranchNameText (GitBranchName value) = value

-- | Validate a conservative local remote-name subset.
mkGitRemoteName :: Text -> Either GitNameError GitRemoteName
mkGitRemoteName value =
  GitRemoteName <$> validateGitName False value

gitRemoteNameText :: GitRemoteName -> Text
gitRemoteNameText (GitRemoteName value) = value

newtype GitCommitMessage = GitCommitMessage Text
  deriving stock (Eq, Ord, Show)

data GitCommitMessageError
  = GitCommitMessageEmpty
  | GitCommitMessageContainsNull
  deriving stock (Eq, Ord, Show)

mkGitCommitMessage
  :: Text
  -> Either GitCommitMessageError GitCommitMessage
mkGitCommitMessage value
  | Text.null (Text.strip value) = Left GitCommitMessageEmpty
  | Text.any (== '\NUL') value = Left GitCommitMessageContainsNull
  | otherwise = Right (GitCommitMessage value)

gitCommitMessageText :: GitCommitMessage -> Text
gitCommitMessageText (GitCommitMessage value) = value

newtype GitHistoryLimit = GitHistoryLimit Natural
  deriving stock (Eq, Ord, Show)

mkGitHistoryLimit :: Natural -> Maybe GitHistoryLimit
mkGitHistoryLimit 0 = Nothing
mkGitHistoryLimit value = Just (GitHistoryLimit value)

gitHistoryLimitValue :: GitHistoryLimit -> Natural
gitHistoryLimitValue (GitHistoryLimit value) = value

data GitOperation
  = GitVersionOperation
  | GitStatusOperation
  | GitInitializeOperation
  | GitStageOperation
  | GitCommitOperation
  | GitLogOperation
  | GitCreateBranchOperation
  | GitCheckoutOperation
  | GitPullOperation
  | GitPushOperation
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data GitRequest
  = GitVersionRequest
  | GitStatusRequest
  | GitInitializeRequest !GitBranchName
  | GitStageRequest !(NonEmpty WorkspacePath)
  | GitCommitRequest !GitCommitMessage
  | GitLogRequest !GitHistoryLimit
  | GitCreateBranchRequest !GitBranchName
  | GitCheckoutRequest !GitBranchName
  | GitPullRequest !GitRemoteName !GitBranchName
  | GitPushRequest !GitRemoteName !GitBranchName
  deriving stock (Eq, Show)

gitRequestOperation :: GitRequest -> GitOperation
gitRequestOperation request =
  case request of
    GitVersionRequest -> GitVersionOperation
    GitStatusRequest -> GitStatusOperation
    GitInitializeRequest _ -> GitInitializeOperation
    GitStageRequest _ -> GitStageOperation
    GitCommitRequest _ -> GitCommitOperation
    GitLogRequest _ -> GitLogOperation
    GitCreateBranchRequest _ -> GitCreateBranchOperation
    GitCheckoutRequest _ -> GitCheckoutOperation
    GitPullRequest _ _ -> GitPullOperation
    GitPushRequest _ _ -> GitPushOperation

-- | Opaque porcelain-v1 output until the dedicated status parser is promoted.
--
-- Keeping it opaque prevents callers from treating arbitrary process text as
-- another command. The current native vertical slice only displays status.
newtype GitStatusSnapshot = GitStatusSnapshot Text
  deriving stock (Eq, Ord, Show)

gitStatusSnapshot :: Text -> GitStatusSnapshot
gitStatusSnapshot = GitStatusSnapshot

gitStatusSnapshotText :: GitStatusSnapshot -> Text
gitStatusSnapshotText (GitStatusSnapshot value) = value

-- | Structured history item returned by future full Git interpreters.
data GitCommitRecord = GitCommitRecord
  { gitCommitIdentifier :: !Text
  , gitCommitAuthor :: !Text
  , gitCommitSubject :: !Text
  }
  deriving stock (Eq, Ord, Show)

data GitResponse
  = GitVersionResponse !Text
  | GitStatusResponse !GitStatusSnapshot
  | GitCompletedResponse !GitOperation
  | GitLogResponse ![GitCommitRecord]
  deriving stock (Eq, Show)

data GitError
  = GitRuntimeFailure !RuntimeFailure
  | GitOperationUnsupported !GitOperation
  | GitUnexpectedResponse !GitOperation
  deriving stock (Eq, Show)

-- | Reject a response constructor that does not match its structured request.
validateGitResponse
  :: GitRequest
  -> GitResponse
  -> Either GitError GitResponse
validateGitResponse request response
  | responseMatches (gitRequestOperation request) response = Right response
  | otherwise = Left (GitUnexpectedResponse (gitRequestOperation request))

data GitPort m = GitPort
  { gitWorkspaceId :: !WorkspaceId
  , gitOperationProvision
      :: GitOperation
      -> CapabilityProvision ()
  , runGitRequest :: GitRequest -> m (Either GitError GitResponse)
  }

-- | Construct a port that rejects mismatched successful responses at the
-- shared boundary, regardless of the target interpreter.
gitPort
  :: Applicative m
  => WorkspaceId
  -> (GitOperation -> CapabilityProvision ())
  -> (GitRequest -> m (Either GitError GitResponse))
  -> GitPort m
gitPort workspace operationProvision execute =
  GitPort
    { gitWorkspaceId = workspace
    , gitOperationProvision = operationProvision
    , runGitRequest = \request ->
        case operationProvision (gitRequestOperation request) of
          CapabilityUnavailable _ ->
            pure
              (Left (GitOperationUnsupported (gitRequestOperation request)))
          CapabilityProvided () ->
            fmap
              (>>= validateGitResponse request)
              (execute request)
    }

validateGitName :: Bool -> Text -> Either GitNameError Text
validateGitName allowSlash value
  | Text.length value > 160 = Left GitNameUnsafe
  | not (Text.all (isNameCharacter allowSlash) value) = Left GitNameUnsafe
  | Text.isSuffixOf "/" value = Left GitNameUnsafe
  | Text.isInfixOf ".." value = Left GitNameUnsafe
  | Text.isInfixOf "//" value = Left GitNameUnsafe
  | Text.isInfixOf "@{" value = Left GitNameUnsafe
  | any unsafeSegment (Text.splitOn "/" value) = Left GitNameUnsafe
  | otherwise =
      case Text.uncons value of
        Nothing -> Left GitNameEmpty
        Just (first, _)
          | isNameInitial first -> Right value
          | otherwise -> Left GitNameUnsafe

isNameInitial :: Char -> Bool
isNameInitial character =
  isAsciiLower character
    || isAsciiUpper character
    || (character >= '0' && character <= '9')
    || character == '_'

isNameCharacter :: Bool -> Char -> Bool
isNameCharacter allowSlash character =
  isNameInitial character
    || character == '-'
    || character == '.'
    || (allowSlash && character == '/')

unsafeSegment :: Text -> Bool
unsafeSegment segment =
  Text.null segment
    || Text.isPrefixOf "." segment
    || Text.isSuffixOf "." segment
    || Text.isSuffixOf ".lock" segment

responseMatches :: GitOperation -> GitResponse -> Bool
responseMatches operation response =
  case (operation, response) of
    (GitVersionOperation, GitVersionResponse _) -> True
    (GitStatusOperation, GitStatusResponse _) -> True
    (GitLogOperation, GitLogResponse _) -> True
    (GitInitializeOperation, GitCompletedResponse GitInitializeOperation) -> True
    (GitStageOperation, GitCompletedResponse GitStageOperation) -> True
    (GitCommitOperation, GitCompletedResponse GitCommitOperation) -> True
    (GitCreateBranchOperation, GitCompletedResponse GitCreateBranchOperation) -> True
    (GitCheckoutOperation, GitCompletedResponse GitCheckoutOperation) -> True
    (GitPullOperation, GitCompletedResponse GitPullOperation) -> True
    (GitPushOperation, GitCompletedResponse GitPushOperation) -> True
    _ -> False
