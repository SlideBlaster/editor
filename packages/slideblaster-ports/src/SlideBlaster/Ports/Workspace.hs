{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Ports.Workspace
-- Description : Exact-byte workspace storage with lexical path safety.
--
-- Every path is a validated normalized POSIX-relative name. Writes always
-- state the expected old content; adapters may not weaken them into an
-- unconditional overwrite. Source persistence consumes authoritative
-- 'SourceBufferSnapshot' values while using exact bytes, not process-local
-- revisions, as the external conflict condition.
module SlideBlaster.Ports.Workspace
  ( WorkspaceId
  , mkWorkspaceId
  , workspaceIdText
  , WorkspacePath
  , WorkspacePathError (..)
  , mkWorkspacePath
  , workspacePathText
  , workspacePathSegments
  , ExpectedContent (..)
  , ConditionalWrite
  , conditionalWrite
  , conditionalWriteExpected
  , conditionalWritePath
  , conditionalWriteValue
  , StorageWriteOutcome (..)
  , StorageError (..)
  , StoragePort (..)
  , saveSourceSnapshot
  ) where

import SlideBlaster.Ports.Capability
  ( CapabilityProvision
  , RuntimeFailure
  )
import SlideBlaster.Source
  ( Revision
  , SourceBufferSnapshot
  , snapshotBytes
  , snapshotRevision
  )

import Data.ByteString (ByteString)
import Data.Char (isAlpha, isControl)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text

-- | Composition-scoped identity proving which root a Storage/Git pair shares.
newtype WorkspaceId = WorkspaceId Text
  deriving stock (Eq, Ord, Show)

-- | Construct a non-blank, protocol-safe workspace identity.
mkWorkspaceId :: Text -> Maybe WorkspaceId
mkWorkspaceId value
  | Text.null (Text.strip value) = Nothing
  | Text.length value > 128 = Nothing
  | Text.any isControl value = Nothing
  | otherwise = Just (WorkspaceId value)

workspaceIdText :: WorkspaceId -> Text
workspaceIdText (WorkspaceId value) = value

-- | A non-empty normalized path whose segments cannot traverse above a root.
newtype WorkspacePath = WorkspacePath (NonEmpty Text)
  deriving stock (Eq, Ord, Show)

data WorkspacePathError
  = WorkspacePathEmpty
  | WorkspacePathTooLong
  | WorkspacePathAbsolute
  | WorkspacePathContainsBackslash
  | WorkspacePathContainsNull
  | WorkspacePathContainsControl
  | WorkspacePathContainsEmptySegment
  | WorkspacePathContainsCurrentSegment
  | WorkspacePathContainsParentSegment
  | WorkspacePathContainsWindowsDrive
  deriving stock (Eq, Ord, Show)

-- | Validate the same portable relative-path language in every composition.
mkWorkspacePath :: Text -> Either WorkspacePathError WorkspacePath
mkWorkspacePath value
  | Text.null value = Left WorkspacePathEmpty
  | Text.length value > 240 = Left WorkspacePathTooLong
  | Text.isPrefixOf "/" value = Left WorkspacePathAbsolute
  | Text.any (== '\\') value = Left WorkspacePathContainsBackslash
  | Text.any (== '\NUL') value = Left WorkspacePathContainsNull
  | Text.any isControl value = Left WorkspacePathContainsControl
  | otherwise =
      case Text.splitOn "/" value of
        [] -> Left WorkspacePathEmpty
        first : remaining -> do
          validateSegments (first : remaining)
          if isWindowsDriveSegment first
            then Left WorkspacePathContainsWindowsDrive
            else Right (WorkspacePath (first :| remaining))

workspacePathText :: WorkspacePath -> Text
workspacePathText (WorkspacePath segments) =
  Text.intercalate "/" (toList segments)

workspacePathSegments :: WorkspacePath -> NonEmpty Text
workspacePathSegments (WorkspacePath segments) = segments

data ExpectedContent
  = ExpectAbsent
  | ExpectExact !ByteString
  deriving stock (Eq, Show)

-- | One conditional exact-byte write request.
data ConditionalWrite = ConditionalWrite
  !WorkspacePath
  !ExpectedContent
  !ByteString
  deriving stock (Eq, Show)

conditionalWrite
  :: WorkspacePath
  -> ExpectedContent
  -> ByteString
  -> ConditionalWrite
conditionalWrite = ConditionalWrite

conditionalWritePath :: ConditionalWrite -> WorkspacePath
conditionalWritePath (ConditionalWrite path _ _) = path

conditionalWriteExpected :: ConditionalWrite -> ExpectedContent
conditionalWriteExpected (ConditionalWrite _ expected _) = expected

conditionalWriteValue :: ConditionalWrite -> ByteString
conditionalWriteValue (ConditionalWrite _ _ value) = value

data StorageWriteOutcome
  = StorageWritten
  | StorageUnchanged
  deriving stock (Eq, Ord, Show)

data StorageError
  = StorageRuntimeFailure !RuntimeFailure
  | StorageConflict !WorkspacePath
  | StorageConditionalWriteUnsupported !WorkspacePath
  | StorageEncodingUnsupported !WorkspacePath
  | StorageUnsafeFilesystemEntry !WorkspacePath
  | StorageHostReturnedInvalidPath !WorkspacePathError
  | StorageInvalidSourceSuccessor !Revision !Revision
  deriving stock (Eq, Show)

-- | Exact workspace operations rooted at one abstract workspace identity.
--
-- Listing returns files only, sorted by 'workspacePathText'. An absent read is
-- normal. Consumers requiring binary assets must first check
-- 'storageArbitraryBytesSupport'. The write action must preserve
-- 'ExpectedContent' or return a typed unsupported error without mutating
-- storage.
data StoragePort m = StoragePort
  { storageWorkspaceId :: !WorkspaceId
  , storageArbitraryBytesSupport :: !(CapabilityProvision ())
  , storageCreateSupport :: !(CapabilityProvision ())
  , storageReplaceSupport :: !(CapabilityProvision ())
  , storageListFiles :: m (Either StorageError [WorkspacePath])
  , storageReadFile
      :: WorkspacePath
      -> m (Either StorageError (Maybe ByteString))
  , storageWriteFile
      :: ConditionalWrite
      -> m (Either StorageError StorageWriteOutcome)
  }

-- | Persist a successor snapshot through exact expected-content fencing.
--
-- A changed successor must have a strictly newer in-memory revision. A
-- byte-identical successor stays a storage no-op and may retain its revision.
saveSourceSnapshot
  :: Applicative m
  => StoragePort m
  -> WorkspacePath
  -> SourceBufferSnapshot
  -> SourceBufferSnapshot
  -> m (Either StorageError StorageWriteOutcome)
saveSourceSnapshot port path expected successor
  | successorBytes /= expectedBytes
      && successorRevision <= expectedRevision =
      pure
        ( Left
            ( StorageInvalidSourceSuccessor
                expectedRevision
                successorRevision
            )
        )
  | otherwise =
      storageWriteFile port
        (conditionalWrite path (ExpectExact expectedBytes) successorBytes)
  where
    expectedBytes = snapshotBytes expected
    successorBytes = snapshotBytes successor
    expectedRevision = snapshotRevision expected
    successorRevision = snapshotRevision successor

validateSegments :: [Text] -> Either WorkspacePathError ()
validateSegments segments
  | any Text.null segments = Left WorkspacePathContainsEmptySegment
  | any (== ".") segments = Left WorkspacePathContainsCurrentSegment
  | any (== "..") segments = Left WorkspacePathContainsParentSegment
  | otherwise = Right ()

isWindowsDriveSegment :: Text -> Bool
isWindowsDriveSegment segment =
  case Text.unpack segment of
    letter : ':' : _ -> isAlpha letter
    _ -> False

toList :: NonEmpty value -> [value]
toList (first :| remaining) = first : remaining
