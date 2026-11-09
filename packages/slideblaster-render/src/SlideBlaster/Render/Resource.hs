{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Render.Resource
-- Description : Embedded resources and validated render-time references.
--
-- A resource manifest contains the exact bytes needed by a render plan.
-- References name both an identity and the kind of resource expected at that
-- use site. Validation therefore rejects missing resources and using, for
-- example, image bytes as a font before a host receives the plan.
module SlideBlaster.Render.Resource
  ( ResourceId
  , mkResourceId
  , resourceIdText
  , ImageFormat (..)
  , FontFormat (..)
  , MediaType
  , mkMediaType
  , mediaTypeText
  , ResourceKind (..)
  , RenderResource
  , RenderResourceError (..)
  , mkRenderResource
  , renderResourceBytes
  , renderResourceId
  , renderResourceKind
  , ResourceManifest
  , ResourceManifestError (..)
  , emptyResourceManifest
  , mkResourceManifest
  , lookupRenderResource
  , resourceManifestResources
  , ResourceReferenceKind (..)
  , ResourceReference (..)
  , ResourceReferenceError (..)
  , validateResourceReferences
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

-- | Stable manifest-local identity with the same conservative token grammar
-- used by browser identities.
newtype ResourceId = ResourceId Text
  deriving stock (Eq, Ord, Show)

-- | Construct a non-empty ASCII token beginning with a letter or underscore.
mkResourceId :: Text -> Maybe ResourceId
mkResourceId value =
  case Text.uncons value of
    Nothing -> Nothing
    Just (firstCharacter, rest)
      | isInitial firstCharacter && Text.all isContinuation rest ->
          Just (ResourceId value)
      | otherwise -> Nothing

resourceIdText :: ResourceId -> Text
resourceIdText (ResourceId value) = value

data ImageFormat
  = PngImage
  | JpegImage
  | GifImage
  | WebPImage
  | AvifImage
  | SvgImage
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data FontFormat
  = WoffFont
  | Woff2Font
  | OpenTypeFont
  | TrueTypeFont
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Validated MIME type for embedded non-image/non-font media.
newtype MediaType = MediaType Text
  deriving stock (Eq, Ord, Show)

-- | Validate a conservative @type/subtype@ MIME spelling. Parameters belong
-- in the lowering diagnostic rather than in a resource kind.
mkMediaType :: Text -> Maybe MediaType
mkMediaType value =
  case Text.splitOn "/" value of
    [major, minor]
      | validMimeToken major && validMimeToken minor ->
          Just (MediaType value)
    _ -> Nothing

mediaTypeText :: MediaType -> Text
mediaTypeText (MediaType value) = value

data ResourceKind
  = ImageResource !ImageFormat
  | FontResource !FontFormat
  | BinaryResource !MediaType
  deriving stock (Eq, Ord, Show)

-- | One non-empty embedded byte payload.
data RenderResource = RenderResource
  !ResourceId
  !ResourceKind
  !ByteString
  deriving stock (Eq)

-- Deliberately omit resource bytes from diagnostics and logs.
instance Show RenderResource where
  showsPrec precedence resource =
    showParen (precedence > 10)
      ( showString "RenderResource "
          . shows (renderResourceId resource)
          . showChar ' '
          . shows (renderResourceKind resource)
          . showString " <"
          . shows (ByteString.length (renderResourceBytes resource))
          . showString " bytes>"
      )

data RenderResourceError
  = EmptyRenderResource !ResourceId
  deriving stock (Eq, Show)

mkRenderResource
  :: ResourceId
  -> ResourceKind
  -> ByteString
  -> Either RenderResourceError RenderResource
mkRenderResource identity kind bytes
  | ByteString.null bytes = Left (EmptyRenderResource identity)
  | otherwise = Right (RenderResource identity kind bytes)

renderResourceId :: RenderResource -> ResourceId
renderResourceId (RenderResource identity _ _) = identity

renderResourceKind :: RenderResource -> ResourceKind
renderResourceKind (RenderResource _ kind _) = kind

renderResourceBytes :: RenderResource -> ByteString
renderResourceBytes (RenderResource _ _ bytes) = bytes

-- | A duplicate-free map of exact embedded resource bytes.
newtype ResourceManifest = ResourceManifest (Map ResourceId RenderResource)
  deriving stock (Eq, Show)

data ResourceManifestError
  = DuplicateRenderResource !ResourceId
  deriving stock (Eq, Show)

emptyResourceManifest :: ResourceManifest
emptyResourceManifest = ResourceManifest Map.empty

mkResourceManifest
  :: [RenderResource]
  -> Either ResourceManifestError ResourceManifest
mkResourceManifest resources =
  ResourceManifest <$> collectResources Map.empty resources

lookupRenderResource
  :: ResourceId
  -> ResourceManifest
  -> Maybe RenderResource
lookupRenderResource identity (ResourceManifest resources) =
  Map.lookup identity resources

-- | Return resources in stable identifier order.
resourceManifestResources :: ResourceManifest -> [RenderResource]
resourceManifestResources (ResourceManifest resources) =
  Map.elems resources

-- | Resource kind required by one render use site.
data ResourceReferenceKind
  = ImageReference
  | FontReference
  | BinaryReference
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data ResourceReference = ResourceReference
  { referencedResourceId :: !ResourceId
  , referencedResourceKind :: !ResourceReferenceKind
  }
  deriving stock (Eq, Ord, Show)

data ResourceReferenceError
  = ReferencedResourceMissing !ResourceReference
  | ReferencedResourceKindMismatch !ResourceReference !ResourceKind
  deriving stock (Eq, Show)

-- | Prove that every reference exists with the expected broad resource kind.
validateResourceReferences
  :: ResourceManifest
  -> Set ResourceReference
  -> Either ResourceReferenceError ()
validateResourceReferences manifest =
  validateReferenceList manifest . Set.toAscList

collectResources
  :: Map ResourceId RenderResource
  -> [RenderResource]
  -> Either ResourceManifestError (Map ResourceId RenderResource)
collectResources resources [] = Right resources
collectResources resources (resource : remaining)
  | Map.member identity resources =
      Left (DuplicateRenderResource identity)
  | otherwise =
      collectResources (Map.insert identity resource resources) remaining
  where
    identity = renderResourceId resource

validateReferenceList
  :: ResourceManifest
  -> [ResourceReference]
  -> Either ResourceReferenceError ()
validateReferenceList _ [] = Right ()
validateReferenceList manifest (reference : remaining) =
  case lookupRenderResource (referencedResourceId reference) manifest of
    Nothing -> Left (ReferencedResourceMissing reference)
    Just resource
      | referenceMatches
          (referencedResourceKind reference)
          (renderResourceKind resource) ->
          validateReferenceList manifest remaining
      | otherwise ->
          Left
            ( ReferencedResourceKindMismatch
                reference
                (renderResourceKind resource)
            )

referenceMatches :: ResourceReferenceKind -> ResourceKind -> Bool
referenceMatches expected actual =
  case (expected, actual) of
    (ImageReference, ImageResource _) -> True
    (FontReference, FontResource _) -> True
    (BinaryReference, BinaryResource _) -> True
    _ -> False

isInitial :: Char -> Bool
isInitial character =
  isAsciiLower character
    || isAsciiUpper character
    || character == '_'

isContinuation :: Char -> Bool
isContinuation character =
  isInitial character
    || (character >= '0' && character <= '9')
    || character == '-'

isAsciiLower :: Char -> Bool
isAsciiLower character = character >= 'a' && character <= 'z'

isAsciiUpper :: Char -> Bool
isAsciiUpper character = character >= 'A' && character <= 'Z'

validMimeToken :: Text -> Bool
validMimeToken token =
  not (Text.null token) && Text.all isMimeCharacter token

isMimeCharacter :: Char -> Bool
isMimeCharacter character =
  isAsciiLower character
    || isAsciiUpper character
    || (character >= '0' && character <= '9')
    || character `elem` ['!', '#', '$', '&', '^', '_', '.', '+', '-']
