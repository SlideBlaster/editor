-- |
-- Module      : SlideBlaster.Extension
-- Description : Public surface of the extension broker's pure core.
--
-- Shared by native GHC and GHC Wasm; contains no process, filesystem or
-- socket code. Providers (native @sb.tex@, stdio-json children, host-side
-- TypeScript) implement the effect; this package owns the request and result
-- types, manifests, fingerprints, cache layout, typed absence and the TikZ
-- request builder. See @docs/architecture/alpha.md@ section 4 and
-- @docs/specs/cap-websocket.md@.
module SlideBlaster.Extension
  ( module SlideBlaster.Extension.Absence
  , module SlideBlaster.Extension.Base64
  , module SlideBlaster.Extension.Envelope
  , module SlideBlaster.Extension.Manifest
  , module SlideBlaster.Extension.Registry
  , module SlideBlaster.Extension.Request
  , module SlideBlaster.Extension.Sha256
  , module SlideBlaster.Extension.Slot
  , module SlideBlaster.Extension.Tikz
  ) where

import SlideBlaster.Extension.Absence
import SlideBlaster.Extension.Base64
import SlideBlaster.Extension.Envelope
import SlideBlaster.Extension.Manifest
import SlideBlaster.Extension.Registry
import SlideBlaster.Extension.Request
import SlideBlaster.Extension.Sha256
import SlideBlaster.Extension.Slot
import SlideBlaster.Extension.Tikz
