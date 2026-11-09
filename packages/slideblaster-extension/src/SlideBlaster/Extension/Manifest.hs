{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Extension.Manifest
-- Description : Extension manifest type and strict JSON validation.
--
-- An @extension.json@ declares one provider: the slots and kinds it serves, how
-- it is reached ('Transport'), the tools it needs, the permissions it asks for
-- and its limits. Parsing is strict: an unknown field at any level, a wrong
-- type, an empty required list or a malformed identifier is a 'ManifestError'
-- that names the offending JSON path. The core never guesses at a manifest.
--
-- Built-in providers are compiled-in values of the same 'Manifest' type, so a
-- user manifest and a built-in are indistinguishable to the broker.
module SlideBlaster.Extension.Manifest
  ( Manifest (..)
  , Provide (..)
  , Transport (..)
  , StdioSpec (..)
  , Need (..)
  , Limits (..)
  , ManifestError (..)
  , defaultLimits
  , parseManifest
  , manifestToJson
  , renderManifestError
  ) where

import SlideBlaster.Extension.Slot (Slot (..), parseSlot, slotName)

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as Lazy
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector

-- | A validated extension manifest.
data Manifest = Manifest
  { manifestId :: !Text
  , manifestVersion :: !Text
  , manifestProvides :: !(NonEmpty Provide)
  , manifestTransport :: !Transport
  , manifestNeeds :: ![Need]
  , manifestPermissions :: ![Text]
  , manifestLimits :: !Limits
  }
  deriving (Eq, Show)

-- | One slot a provider serves.
data Provide = Provide
  { provideSlot :: !Slot
  , provideKinds :: ![Text]
  -- ^ Block kinds (only meaningful for 'BlockRender' and 'BlockEdit').
  , provideOutput :: !(Maybe Text)
  -- ^ Output media type, required for 'BlockRender'.
  }
  deriving (Eq, Show)

-- | How a provider is reached.
data Transport
  = BuiltinNative
  -- ^ Haskell code inside @sb serve@.
  | BuiltinHost
  -- ^ TypeScript inside the web host.
  | StdioJson !StdioSpec
  -- ^ A child process; no shell.
  deriving (Eq, Show)

-- | A child-process transport: an argument vector (never a shell string), the
-- block body on standard input and the artifact on standard output.
newtype StdioSpec = StdioSpec
  { stdioArgv :: NonEmpty Text
  }
  deriving (Eq, Show)

-- | An external tool that must be on @PATH@.
newtype Need = Need {needTool :: Text}
  deriving (Eq, Show)

-- | Resource limits enforced by the broker.
data Limits = Limits
  { limitTimeoutMs :: !Int
  , limitMaxBytes :: !Int
  }
  deriving (Eq, Show)

-- | Limits when a manifest omits them: 60 s and 8 MiB (default, revisitable).
defaultLimits :: Limits
defaultLimits = Limits {limitTimeoutMs = 60000, limitMaxBytes = 8388608}

-- | Why a manifest was rejected: the JSON path and a reason.
data ManifestError = ManifestError
  { manifestErrorPath :: !Text
  , manifestErrorReason :: !Text
  }
  deriving (Eq, Show)

-- | One-line rendering such as @provides[0].kinds: must not be empty@.
renderManifestError :: ManifestError -> Text
renderManifestError (ManifestError path reason) =
  (if Text.null path then "manifest" else path) <> ": " <> reason

type Parse a = Either ManifestError a

failAt :: Text -> Text -> Parse a
failAt path reason = Left (ManifestError path reason)

-- | Parse and validate manifest bytes.
parseManifest :: ByteString -> Either ManifestError Manifest
parseManifest bytes = case Aeson.eitherDecodeStrict bytes of
  Left problem -> failAt "" ("invalid JSON: " <> Text.pack problem)
  Right value -> manifestFromValue value

manifestFromValue :: Value -> Parse Manifest
manifestFromValue value = do
  obj <- expectObject "" value
  closedKeys ""
    ["id", "version", "provides", "transport", "needs", "permissions", "limits"]
    obj
  ident <- required "" "id" obj >>= expectText "id" >>= validateIdentifier "id"
  version <- required "" "version" obj >>= expectText "version" >>= nonBlank "version"
  provides <- required "" "provides" obj >>= expectArray "provides" >>= parseProvides
  transport <- required "" "transport" obj >>= parseTransport
  needs <- optionalList "needs" parseNeed obj
  permissions <- optionalList "permissions" parsePermission obj
  limits <- maybe (Right defaultLimits) (parseLimits "limits") (KeyMap.lookup "limits" obj)
  pure
    Manifest
      { manifestId = ident
      , manifestVersion = version
      , manifestProvides = provides
      , manifestTransport = transport
      , manifestNeeds = needs
      , manifestPermissions = permissions
      , manifestLimits = limits
      }

parseProvides :: [Value] -> Parse (NonEmpty Provide)
parseProvides items = do
  parsed <- traverse parseIndexed (zip [0 :: Int ..] items)
  case NonEmpty.nonEmpty parsed of
    Nothing -> failAt "provides" "must declare at least one slot"
    Just provides -> Right provides
  where
    parseIndexed (index, item) = parseProvide ("provides[" <> Text.pack (show index) <> "]") item

parseProvide :: Text -> Value -> Parse Provide
parseProvide path value = do
  obj <- expectObject path value
  closedKeys path ["slot", "kinds", "output"] obj
  slotText <- required path "slot" obj >>= expectText (path <> ".slot")
  slot <- case parseSlot slotText of
    Nothing -> failAt (path <> ".slot") ("unknown slot " <> quote slotText)
    Just known -> Right known
  kinds <- case KeyMap.lookup "kinds" obj of
    Nothing -> Right []
    Just raw -> do
      items <- expectArray (path <> ".kinds") raw
      traverse (\item -> expectText (path <> ".kinds[]") item >>= validateKind (path <> ".kinds[]")) items
  output <- case KeyMap.lookup "output" obj of
    Nothing -> Right Nothing
    Just raw -> Just <$> (expectText (path <> ".output") raw >>= nonBlank (path <> ".output"))
  let needsKinds = slot == BlockRender || slot == BlockEdit
  if needsKinds && null kinds
    then failAt (path <> ".kinds") ("slot " <> slotName slot <> " requires at least one kind")
    else
      if slot == BlockRender && output == Nothing
        then failAt (path <> ".output") "slot block.render requires an output media type"
        else Right Provide {provideSlot = slot, provideKinds = kinds, provideOutput = output}

parseTransport :: Value -> Parse Transport
parseTransport value = do
  obj <- expectObject "transport" value
  kind <- required "transport" "kind" obj >>= expectText "transport.kind"
  case kind of
    "builtin-native" -> closedKeys "transport" ["kind"] obj >> Right BuiltinNative
    "builtin-host" -> closedKeys "transport" ["kind"] obj >> Right BuiltinHost
    "stdio-json" -> do
      closedKeys "transport" ["kind", "argv", "stdin", "stdout"] obj
      argvItems <- required "transport" "argv" obj >>= expectArray "transport.argv"
      argv <- traverse (expectText "transport.argv[]" >=> nonBlank "transport.argv[]") argvItems
      argvNonEmpty <- case NonEmpty.nonEmpty argv of
        Nothing -> failAt "transport.argv" "must not be empty"
        Just ok -> Right ok
      expectLiteral "transport.stdin" "body" (KeyMap.lookup "stdin" obj)
      expectLiteral "transport.stdout" "artifact" (KeyMap.lookup "stdout" obj)
      Right (StdioJson (StdioSpec argvNonEmpty))
    other -> failAt "transport.kind" ("unknown transport " <> quote other)
  where
    (>=>) f g x = f x >>= g

-- A stdio field that must be absent or exactly the one supported value.
expectLiteral :: Text -> Text -> Maybe Value -> Parse ()
expectLiteral _ _ Nothing = Right ()
expectLiteral path wanted (Just raw) = do
  text <- expectText path raw
  if text == wanted then Right () else failAt path ("only " <> quote wanted <> " is supported")

parseNeed :: Text -> Value -> Parse Need
parseNeed path value = do
  obj <- expectObject path value
  closedKeys path ["tool"] obj
  tool <- required path "tool" obj >>= expectText (path <> ".tool") >>= validateTool (path <> ".tool")
  Right (Need tool)

parsePermission :: Text -> Value -> Parse Text
parsePermission path value = expectText path value >>= nonBlank path

parseLimits :: Text -> Value -> Parse Limits
parseLimits path value = do
  obj <- expectObject path value
  closedKeys path ["timeoutMs", "maxBytes"] obj
  timeoutMs <- positiveInt path "timeoutMs" (limitTimeoutMs defaultLimits) obj
  maxBytes <- positiveInt path "maxBytes" (limitMaxBytes defaultLimits) obj
  Right Limits {limitTimeoutMs = timeoutMs, limitMaxBytes = maxBytes}

positiveInt :: Text -> Text -> Int -> Aeson.Object -> Parse Int
positiveInt parent name fallback obj = case KeyMap.lookup (Key.fromText name) obj of
  Nothing -> Right fallback
  Just (Number n) -> case floatingOrInteger n :: Either Double Int of
    Right whole | whole > 0 -> Right whole
    _ -> failAt path "must be a positive integer"
  Just _ -> failAt path "must be a positive integer"
  where
    path = parent <> "." <> name

optionalList :: Text -> (Text -> Value -> Parse a) -> Aeson.Object -> Parse [a]
optionalList name parseItem obj = case KeyMap.lookup (Key.fromText name) obj of
  Nothing -> Right []
  Just raw -> do
    items <- expectArray name raw
    traverse (\(index, item) -> parseItem (name <> "[" <> Text.pack (show index) <> "]") item) (zip [0 :: Int ..] items)

required :: Text -> Text -> Aeson.Object -> Parse Value
required parent name obj = case KeyMap.lookup (Key.fromText name) obj of
  Nothing -> failAt (qualify parent name) "is required"
  Just value -> Right value

qualify :: Text -> Text -> Text
qualify parent name = if Text.null parent then name else parent <> "." <> name

closedKeys :: Text -> [Text] -> Aeson.Object -> Parse ()
closedKeys parent allowed obj =
  case [key | key <- Key.toText <$> KeyMap.keys obj, key `notElem` allowed] of
    [] -> Right ()
    unknown : _ -> failAt (qualify parent unknown) "unknown field"

expectObject :: Text -> Value -> Parse Aeson.Object
expectObject _ (Object obj) = Right obj
expectObject path _ = failAt path "must be an object"

expectArray :: Text -> Value -> Parse [Value]
expectArray _ (Array items) = Right (Vector.toList items)
expectArray path _ = failAt path "must be an array"

expectText :: Text -> Value -> Parse Text
expectText _ (String text) = Right text
expectText path _ = failAt path "must be a string"

nonBlank :: Text -> Text -> Parse Text
nonBlank path text
  | Text.null (Text.strip text) = failAt path "must not be empty"
  | otherwise = Right text

validateIdentifier :: Text -> Text -> Parse Text
validateIdentifier path text
  | not (Text.null text) && Text.all isIdentChar text && startsAlnum = Right text
  | otherwise = failAt path "must be letters, digits, '.', '-' or '_' and start with a letter or digit"
  where
    startsAlnum = maybe False (isAsciiLower' . fst) (Text.uncons text)
    isAsciiLower' c = isAsciiLower c || isAsciiUpper c || isDigit c

validateKind :: Text -> Text -> Parse Text
validateKind path text
  | not (Text.null text) && Text.all (\c -> isAsciiLower c || isDigit c || c == '-' || c == '_' || c == '.') text = Right text
  | otherwise = failAt path "must be lower-case letters, digits, '.', '-' or '_'"

-- A tool is a bare executable name, never a path.
validateTool :: Text -> Text -> Parse Text
validateTool path text
  | not (Text.null text) && Text.all (\c -> isIdentChar c || c == '+') text = Right text
  | otherwise = failAt path "must be a bare executable name"

isIdentChar :: Char -> Bool
isIdentChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c == '.' || c == '-' || c == '_'

quote :: Text -> Text
quote text = "'" <> text <> "'"

-- | The canonical JSON form of a manifest (round-trips through 'parseManifest').
manifestToJson :: Manifest -> ByteString
manifestToJson manifest =
  Lazy.toStrict . Aeson.encode $
    object
      [ "id" .= manifestId manifest
      , "version" .= manifestVersion manifest
      , "provides" .= (provideJson <$> NonEmpty.toList (manifestProvides manifest))
      , "transport" .= transportJson (manifestTransport manifest)
      , "needs" .= [object ["tool" .= tool] | Need tool <- manifestNeeds manifest]
      , "permissions" .= manifestPermissions manifest
      , "limits"
          .= object
            [ "timeoutMs" .= limitTimeoutMs (manifestLimits manifest)
            , "maxBytes" .= limitMaxBytes (manifestLimits manifest)
            ]
      ]
  where
    provideJson (Provide slot kinds output) =
      object $
        ["slot" .= slotName slot]
          <> ["kinds" .= kinds | not (null kinds)]
          <> ["output" .= o | Just o <- [output]]
    transportJson transport = case transport of
      BuiltinNative -> object ["kind" .= ("builtin-native" :: Text)]
      BuiltinHost -> object ["kind" .= ("builtin-host" :: Text)]
      StdioJson (StdioSpec argv) ->
        object
          [ "kind" .= ("stdio-json" :: Text)
          , "argv" .= NonEmpty.toList argv
          , "stdin" .= ("body" :: Text)
          , "stdout" .= ("artifact" :: Text)
          ]
