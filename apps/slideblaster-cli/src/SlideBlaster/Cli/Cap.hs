{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Cli.Cap
-- Description : Request handling for the @/cap@ capability and extension socket.
--
-- Implements the operations of @docs/specs/cap-websocket.md@: project storage
-- (list, read, conditional save), provider listing and @block.render@ through
-- the native broker. Handlers are pure request-to-response functions over a
-- 'CapEnv'; the socket loop and file watching live in "SlideBlaster.Cli.Serve".
-- All paths are validated project-relative and re-checked against the real
-- (symlink-resolved) project root.
module SlideBlaster.Cli.Cap
  ( CapEnv (..)
  , newCapEnv
  , capProtocol
  , helloEvent
  , handleCapRequest
  , validateProjectPath
  , PathProblem (..)
  , errorResponse
  , SaveFailure (..)
  , saveProjectFile
  ) where

import SlideBlaster.Adapter.Native
import SlideBlaster.Extension

import Control.Monad (foldM)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import System.Directory
  ( canonicalizePath
  , doesDirectoryExist
  , doesFileExist
  , getFileSize
  , listDirectory
  , pathIsSymbolicLink
  )
import System.FilePath (splitDirectories, takeDirectory, (</>))
import System.IO.Error (tryIOError)

-- | The protocol identifier sent in @hello@.
capProtocol :: Text
capProtocol = "slideblaster.cap/1"

-- | Everything a handler needs.
data CapEnv = CapEnv
  { capRoot :: !FilePath
  , capRealRoot :: !FilePath
  -- ^ Symlink-resolved root, for containment checks.
  , capBroker :: !Broker
  , capVersion :: !Text
  }

-- | Resolve the real root and bundle the environment.
newCapEnv :: FilePath -> Broker -> Text -> IO CapEnv
newCapEnv root broker version = do
  real <- canonicalizePath root
  pure CapEnv {capRoot = root, capRealRoot = real, capBroker = broker, capVersion = version}

-- | Why a path was refused.
data PathProblem = BadPath | ForbiddenPath
  deriving (Eq, Show)

-- | Validate wire path text into path segments.
validateProjectPath :: Text -> Either PathProblem [FilePath]
validateProjectPath path
  | Text.null path = Right []
  | any badSegment segments = Left BadPath
  | Text.any (\c -> c == '\\' || c == '\0') path = Left BadPath
  | "/" `Text.isPrefixOf` path = Left BadPath
  | isCache = Left ForbiddenPath
  | otherwise = Right (Text.unpack <$> segments)
  where
    segments = Text.splitOn "/" path
    badSegment s = Text.null s || s == "." || s == ".."
    isCache = case segments of
      ".slideblaster" : "cache" : _ -> True
      _ -> False

-- Resolve segments under the root and confirm the real location stays inside.
resolveInside :: CapEnv -> [FilePath] -> IO (Either PathProblem FilePath)
resolveInside env segments = do
  let target = foldl (</>) (capRoot env) segments
  real <- nearestRealPath target
  let rootParts = splitDirectories (capRealRoot env)
      realParts = splitDirectories real
  pure $
    if take (length rootParts) realParts == rootParts
      then Right target
      else Left BadPath
  where
    nearestRealPath path = do
      exists <- doesFileExist path
      isDir <- doesDirectoryExist path
      if exists || isDir || path == takeDirectory path
        then canonicalizePath path
        else do
          parent <- nearestRealPath (takeDirectory path)
          pure (parent </> lastPart path)
    lastPart path = case reverse (splitDirectories path) of
      p : _ -> p
      [] -> ""

-- | Failure response.
errorResponse :: Value -> Text -> Text -> Value
errorResponse requestId code message =
  object
    [ "id" .= requestId
    , "ok" .= False
    , "error" .= object ["code" .= code, "message" .= message]
    ]

okResponse :: Value -> [Pair] -> Value
okResponse requestId pairs = object (["id" .= requestId, "ok" .= True] <> pairs)

-- | The @hello@ event sent when a connection opens.
helloEvent :: CapEnv -> IO Value
helloEvent env = do
  providers <- providerJson env
  pure . object $
    [ "event" .= ("hello" :: Text)
    , "protocol" .= capProtocol
    , "version" .= capVersion env
    , "root" .= Text.pack (rootName (capRealRoot env))
    , "providers" .= providers
    ]
  where
    rootName path = case reverse (splitDirectories path) of
      n : _ -> n
      [] -> path

providerJson :: CapEnv -> IO [Value]
providerJson env = do
  infos <- listProviders (capBroker env)
  pure
    [ object $
        [ "id" .= manifestId m
        , "version" .= manifestVersion m
        , "slot" .= slotName (provideSlot p)
        , "kinds" .= provideKinds p
        , "available" .= infoAvailable info
        , "missingTools" .= infoMissingTools info
        ]
          <> ["output" .= o | Just o <- [provideOutput p]]
    | info <- infos
    , let m = infoManifest info
    , p <- NonEmpty.toList (manifestProvides m)
    ]

-- | Handle one request object. 'Nothing' means the operation is connection
-- level (@watch.*@) and the caller must handle it.
handleCapRequest :: CapEnv -> Aeson.Object -> IO (Maybe Value)
handleCapRequest env obj = case opName of
  Just "ping" -> respond (pure (okResponse requestId []))
  Just "storage.list" -> respond (storageList env requestId obj)
  Just "storage.read" -> respond (storageRead env requestId obj)
  Just "storage.save" -> respond (storageSave env requestId obj)
  Just "providers.list" -> respond $ do
    providers <- providerJson env
    problems <- brokerProblems (capBroker env)
    pure
      ( okResponse requestId
          [ "providers" .= providers
          , "problems" .= [object ["path" .= Text.pack (problemPath p), "message" .= problemReason p] | p <- problems]
          ]
      )
  Just "block.render" -> respond (blockRender env requestId obj)
  Just "broker.stats" -> respond $ do
    s <- brokerStats (capBroker env)
    pure (okResponse requestId ["requests" .= statsRequests s, "cacheHits" .= statsCacheHits s, "runs" .= statsRuns s])
  Just "watch.subscribe" -> pure Nothing
  Just "watch.unsubscribe" -> pure Nothing
  Just other -> respond (pure (errorResponse requestId "unknown_op" ("unknown operation " <> other)))
  Nothing -> respond (pure (errorResponse requestId "bad_request" "missing op"))
  where
    requestId = maybe Null id (KeyMap.lookup "id" obj)
    opName = case KeyMap.lookup "op" obj of
      Just (String s) -> Just s
      _ -> Nothing
    respond action = Just <$> action

textField :: Text -> Aeson.Object -> Maybe Text
textField name obj = case KeyMap.lookup (Key.fromText name) obj of
  Just (String s) -> Just s
  _ -> Nothing

pathProblemResponse :: Value -> PathProblem -> Value
pathProblemResponse requestId problem = case problem of
  BadPath -> errorResponse requestId "bad_path" "path must be project-relative without '..' or empty segments"
  ForbiddenPath -> errorResponse requestId "forbidden" "path is not accessible through storage"

readLimit :: Integer
readLimit = 33554432

storageRead :: CapEnv -> Value -> Aeson.Object -> IO Value
storageRead env requestId obj =
  case validateProjectPath (maybe "" id (textField "path" obj)) of
    Left problem -> pure (pathProblemResponse requestId problem)
    Right [] -> pure (errorResponse requestId "bad_path" "a file path is required")
    Right segments -> do
      resolved <- resolveInside env segments
      case resolved of
        Left problem -> pure (pathProblemResponse requestId problem)
        Right full -> do
          isFile <- doesFileExist full
          if not isFile
            then pure (errorResponse requestId "not_found" "no such file")
            else do
              size <- tryIOError (getFileSize full)
              case size of
                Left problem -> pure (errorResponse requestId "io_error" (Text.pack (show problem)))
                Right n
                  | n > readLimit -> pure (errorResponse requestId "too_large" "file exceeds the 32 MiB read limit")
                  | otherwise -> do
                      content <- tryIOError (ByteString.readFile full)
                      pure $ case content of
                        Left problem -> errorResponse requestId "io_error" (Text.pack (show problem))
                        Right bytes ->
                          okResponse requestId
                            [ "path" .= Text.intercalate "/" (Text.pack <$> segments)
                            , "size" .= ByteString.length bytes
                            , "sha256" .= decodeAscii (sha256Hex bytes)
                            , "contentBase64" .= decodeAscii (encodeBase64 bytes)
                            ]

decodeAscii :: ByteString -> Text
decodeAscii = Encoding.decodeLatin1

storageSave :: CapEnv -> Value -> Aeson.Object -> IO Value
storageSave env requestId obj =
  case validateProjectPath (maybe "" id (textField "path" obj)) of
    Left problem -> pure (pathProblemResponse requestId problem)
    Right [] -> pure (errorResponse requestId "bad_path" "a file path is required")
    Right segments -> case decodeField "contentBase64" of
      Nothing -> pure (errorResponse requestId "bad_request" "contentBase64 is required and must be base64")
      Just content -> case expected of
        Left why -> pure (errorResponse requestId "bad_request" why)
        Right expectation -> do
          result <- saveProjectFile env segments expectation content
          pure $ case result of
            Right () ->
              okResponse requestId
                [ "path" .= Text.intercalate "/" (Text.pack <$> segments)
                , "sha256" .= decodeAscii (sha256Hex content)
                , "size" .= ByteString.length content
                ]
            Left (SaveBadPath problem) -> pathProblemResponse requestId problem
            Left SaveConflict -> errorResponse requestId "conflict" "current bytes differ from the expected bytes"
            Left (SaveIo why) -> errorResponse requestId "io_error" why
  where
    decodeField name = case textField name obj of
      Just t -> decodeBase64 (Encoding.encodeUtf8 t)
      Nothing -> Nothing
    expected :: Either Text (Maybe ByteString)
    expected = case KeyMap.lookup "expectedBase64" obj of
      Nothing -> Right Nothing
      Just Null -> Right Nothing
      Just (String t) -> maybe (Left "expectedBase64 is not valid base64") (Right . Just) (decodeBase64 (Encoding.encodeUtf8 t))
      Just _ -> Left "expectedBase64 must be a string or null"

-- | Why a project save failed.
data SaveFailure
  = SaveBadPath !PathProblem
  | SaveConflict
  | SaveIo !Text
  deriving (Eq, Show)

-- | Conditional save: @Nothing@ means the file must not exist yet; @Just
-- before@ means it must currently hold exactly those bytes.
saveProjectFile :: CapEnv -> [FilePath] -> Maybe ByteString -> ByteString -> IO (Either SaveFailure ())
saveProjectFile env segments expectation content = do
  resolved <- resolveInside env segments
  case resolved of
    Left problem -> pure (Left (SaveBadPath problem))
    Right full -> do
      result <- case expectation of
        Nothing -> createFileIfAbsent full content
        Just before
          | before == content -> do
              exists <- doesFileExist full
              pure (if exists then Right () else Left (NativeSaveConflict full))
          | otherwise -> nativeCompareAndReplace nativeFileSystem full before content
      pure $ case result of
        Right () -> Right ()
        Left (NativeSaveConflict _) -> Left SaveConflict
        Left (NativeSaveIoError e) -> Left (SaveIo (nativeFsErrorMessage e))

storageList :: CapEnv -> Value -> Aeson.Object -> IO Value
storageList env requestId obj =
  case validateProjectPath (maybe "" id (textField "path" obj)) of
    Left problem -> pure (pathProblemResponse requestId problem)
    Right segments -> do
      resolved <- resolveInside env segments
      case resolved of
        Left problem -> pure (pathProblemResponse requestId problem)
        Right full -> do
          isDir <- doesDirectoryExist full
          if not isDir
            then pure (errorResponse requestId "not_found" "no such directory")
            else do
              entries <- walk full segments recursive (4000 :: Int)
              pure (okResponse requestId ["entries" .= (entryJson <$> sortOn fst entries)])
  where
    recursive = KeyMap.lookup "recursive" obj == Just (Bool True)
    entryJson (path, (kind, size)) =
      object $
        ["path" .= Text.intercalate "/" (Text.pack <$> path), "kind" .= (kind :: Text)]
          <> ["size" .= s | Just s <- [size :: Maybe Integer]]
    walk dir prefix deep budget = do
      listing <- tryIOError (listDirectory dir)
      case listing of
        Left _ -> pure []
        Right names -> do
          fmap fst . foldM (step dir prefix deep) ([], budget) $ sortOn id (filter visible names)
    visible n = n /= ".git"
    step dir prefix deep (acc, budget) name
      | budget <= 0 = pure (acc, budget)
      | (prefix <> [name]) `startsWith` [".slideblaster", "cache"] = pure (acc, budget)
      | otherwise = do
          let full = dir </> name
              path = prefix <> [name]
          link <- tryIOError (pathIsSymbolicLink full)
          real <- tryIOError (canonicalizePath full)
          let inside = either (const False) (\r -> take (length rootParts) (splitDirectories r) == rootParts) real
          isDir <- doesDirectoryExist full
          isFile <- doesFileExist full
          if not inside
            then pure (acc, budget)
            else
              if isDir
                then do
                  nested <- if deep && link /= Right True then walk full path deep (budget - 1) else pure []
                  pure (acc <> [(path, ("dir", Nothing))] <> nested, budget - 1 - length nested)
                else
                  if isFile
                    then do
                      size <- tryIOError (getFileSize full)
                      pure (acc <> [(path, ("file", either (const Nothing) Just size))], budget - 1)
                    else pure (acc, budget)
    rootParts = splitDirectories (capRealRoot env)
    startsWith xs prefix = take (length prefix) xs == prefix

blockRender :: CapEnv -> Value -> Aeson.Object -> IO Value
blockRender env requestId obj = case decodeRenderEnvelope obj of
  Left err -> pure (errorResponse requestId "bad_request" (envelopeErrorField err <> ": " <> envelopeErrorReason err))
  Right envelope -> do
    result <- renderBlock (capBroker env) envelope
    pure $ case result of
      Left (FingerprintMismatch claimed computed) ->
        object
          [ "id" .= requestId
          , "ok" .= False
          , "error"
              .= object
                [ "code" .= ("fingerprint_mismatch" :: Text)
                , "message" .= ("claimed fingerprint does not match the request" :: Text)
                , "claimed" .= fingerprintText claimed
                , "computed" .= fingerprintText computed
                ]
          ]
      Right rendered -> okResponse requestId (encodeRenderResult rendered)

