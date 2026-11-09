{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Extension.Registry
-- Description : Provider lookup over validated manifests, plus built-ins.
--
-- A registry maps @(slot, kind)@ to one provider. Manifests are supplied in
-- priority order (workspace, then user, then built-in); the first manifest that
-- provides a pair wins, so a user can shadow a built-in without a release.
module SlideBlaster.Extension.Registry
  ( Registry
  , mkRegistry
  , registryManifests
  , lookupProvider
  , providerIdentity
  , manifestTools
  , builtinTexManifest
  ) where

import SlideBlaster.Extension.Manifest
import SlideBlaster.Extension.Request (ProviderIdentity (..))
import SlideBlaster.Extension.Slot (Slot (..))

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)

-- | Manifests in priority order.
newtype Registry = Registry [Manifest]
  deriving (Eq, Show)

-- | Build a registry; the first manifest providing a pair wins.
mkRegistry :: [Manifest] -> Registry
mkRegistry = Registry

-- | The manifests, in priority order.
registryManifests :: Registry -> [Manifest]
registryManifests (Registry manifests) = manifests

-- | The provider for a slot and kind, if any.
lookupProvider :: Slot -> Text -> Registry -> Maybe Manifest
lookupProvider slot kind (Registry manifests) =
  case filter serves manifests of
    found : _ -> Just found
    [] -> Nothing
  where
    serves manifest =
      any
        (\p -> provideSlot p == slot && kind `elem` provideKinds p)
        (NonEmpty.toList (manifestProvides manifest))

-- | The identity that salts fingerprints.
providerIdentity :: Manifest -> ProviderIdentity
providerIdentity manifest = ProviderIdentity (manifestId manifest) (manifestVersion manifest)

-- | Tools the provider needs on @PATH@.
manifestTools :: Manifest -> [Text]
manifestTools manifest = needTool <$> manifestNeeds manifest

-- | The compiled-in @sb.tex@ manifest: TikZ and TeX to SVG (design 4.2).
builtinTexManifest :: Manifest
builtinTexManifest =
  Manifest
    { manifestId = "sb.tex"
    , manifestVersion = "0.2.0"
    , manifestProvides = Provide BlockRender ["tikz", "tex"] (Just "image/svg+xml") :| []
    , manifestTransport = BuiltinNative
    , manifestNeeds = [Need "latex", Need "dvisvgm"]
    , manifestPermissions = ["exec:tex", "fs:project:read"]
    , manifestLimits = Limits {limitTimeoutMs = 60000, limitMaxBytes = 8388608}
    }
