{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Extension.Request
-- Description : Block request, fingerprint, ticket and cache-key types.
--
-- The broker turns a figure into a 'BlockRequest'. Its 'Fingerprint' is the
-- SHA-256 of a length-prefixed canonical encoding of everything that can change
-- the artifact: provider identity, kind, body, deck preamble, palette, requested
-- width and the resolved @\\input@ closure (sorted by path). The same pure
-- function runs in the Wasm core and in the native server, so both sides agree
-- on cache keys and on the echo check that guards a provider result.
module SlideBlaster.Extension.Request
  ( Ticket (..)
  , Fingerprint
  , fingerprintText
  , mkFingerprint
  , ProviderIdentity (..)
  , PaletteColour (..)
  , ResolvedInput (..)
  , LineMap (..)
  , BlockRequest (..)
  , emptyBlockRequest
  , requestFingerprint
  , cacheSegments
  ) where

import SlideBlaster.Extension.Sha256 (sha256Hex)

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Char8
import Data.Char (isHexDigit)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

-- | Opaque correlation token minted by the requester and echoed in the result.
newtype Ticket = Ticket {ticketText :: Text}
  deriving (Eq, Ord, Show)

-- | A validated 64-character lower-case hexadecimal SHA-256.
newtype Fingerprint = Fingerprint Text
  deriving (Eq, Ord, Show)

-- | The 64 hex characters.
fingerprintText :: Fingerprint -> Text
fingerprintText (Fingerprint text) = text

-- | Validate wire text as a fingerprint (upper case is rejected, not folded).
mkFingerprint :: Text -> Maybe Fingerprint
mkFingerprint text
  | Text.length text == 64 && Text.all (\c -> isHexDigit c && c `notElem` ['A' .. 'F']) text =
      Just (Fingerprint text)
  | otherwise = Nothing

-- | Which provider build a fingerprint is for.
data ProviderIdentity = ProviderIdentity
  { providerId :: !Text
  , providerVersion :: !Text
  }
  deriving (Eq, Show)

-- | A named theme colour, emitted as @\\definecolor{name}{HTML}{HEX}@.
data PaletteColour = PaletteColour
  { colourName :: !Text
  , colourHex :: !Text
  }
  deriving (Eq, Show)

-- | A workspace file the block refers to, stored under the name the block uses.
data ResolvedInput = ResolvedInput
  { inputPath :: !Text
  , inputBytes :: !ByteString
  }
  deriving (Eq, Show)

-- | Where the block body starts, to name error locations.
data LineMap = LineMap
  { lineMapFile :: !Text
  , lineMapFirstLine :: !Int
  }
  deriving (Eq, Show)

-- | What a @block.render@ provider is asked to render.
data BlockRequest = BlockRequest
  { requestKind :: !Text
  , requestBody :: !Text
  , requestPreamble :: !Text
  , requestPalette :: ![PaletteColour]
  , requestWidth :: !(Maybe Int)
  , requestInputs :: ![ResolvedInput]
  , requestLineMap :: !(Maybe LineMap)
  }
  deriving (Eq, Show)

-- | A request with only kind and body.
emptyBlockRequest :: Text -> Text -> BlockRequest
emptyBlockRequest kind body =
  BlockRequest
    { requestKind = kind
    , requestBody = body
    , requestPreamble = ""
    , requestPalette = []
    , requestWidth = Nothing
    , requestInputs = []
    , requestLineMap = Nothing
    }

-- | The cache key. The line map is deliberately excluded: it only relabels
-- diagnostics and must not invalidate a good artifact.
requestFingerprint :: ProviderIdentity -> BlockRequest -> Fingerprint
requestFingerprint provider request =
  Fingerprint . Encoding.decodeLatin1 . sha256Hex . Char8.concat $ fields
  where
    fields =
      map
        field
        ( [ "sb-fingerprint/1"
          , utf8 (providerId provider)
          , utf8 (providerVersion provider)
          , utf8 (requestKind request)
          , utf8 (requestBody request)
          , utf8 (requestPreamble request)
          , Char8.pack (show (length (requestPalette request)))
          ]
            <> concat
              [[utf8 (colourName c), utf8 (colourHex c)] | c <- requestPalette request]
            <> [maybe "-" (Char8.pack . show) (requestWidth request)]
            <> concat
              [ [utf8 (inputPath i), inputBytes i]
              | i <- sortOn inputPath (requestInputs request)
              ]
        )
    utf8 = Encoding.encodeUtf8
    field bytes = Char8.pack (show (Char8.length bytes)) <> ":" <> bytes <> ";"

-- | Project-relative cache location as path segments:
-- @.slideblaster/cache/<provider>/<fingerprint>@.
cacheSegments :: ProviderIdentity -> Fingerprint -> [Text]
cacheSegments provider fingerprint =
  [".slideblaster", "cache", providerId provider, fingerprintText fingerprint]
