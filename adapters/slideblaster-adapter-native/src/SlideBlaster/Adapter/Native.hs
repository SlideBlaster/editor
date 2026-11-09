-- |
-- Module      : SlideBlaster.Adapter.Native
-- Description : Public native capability interpreters.
--
-- Native-only effects terminate here. Shared source, engine, and protocol
-- packages depend on neither this adapter nor host filesystem and process APIs.
module SlideBlaster.Adapter.Native
  ( NativeFileSystem (..)
  , NativeFsError (..)
  , NativeGit (..)
  , NativeGitError (..)
  , NativeSaveError (..)
  , createFileIfAbsent
  , loadSnapshot
  , nativeFileSystem
  , nativeGit
  , saveSnapshotIfUnchanged
  , module SlideBlaster.Adapter.Native.Broker
  , module SlideBlaster.Adapter.Native.Extensions
  , module SlideBlaster.Adapter.Native.Sanitize
  ) where

import SlideBlaster.Adapter.Native.Broker
import SlideBlaster.Adapter.Native.Extensions
import SlideBlaster.Adapter.Native.FileSystem
import SlideBlaster.Adapter.Native.Sanitize
import SlideBlaster.Adapter.Native.Git
