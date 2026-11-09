-- |
-- Module      : SlideBlaster.Protocol
-- Description : Public versioned command boundary around the shared engine.
--
-- The command algebra is shared Haskell data for native and Wasm
-- compositions. Its JSON codec preserves arbitrary authored bytes exactly and
-- exposes only typed renderer-neutral results.
module SlideBlaster.Protocol
  ( EngineRequest (..)
  , EngineResponse (..)
  , HostFailure (..)
  , HostProtocolDecodeError (..)
  , HostRequest
  , HostRequestError (..)
  , HostRequestId
  , HostResponse (..)
  , ProtocolDecodeFailure (..)
  , ProtocolError (..)
  , LiveProductRequest (..)
  , ThemeControlIntent (..)
  , ProductProtocolError (..)
  , LiveProductSuccess
  , decodeHostResponseJSON
  , decodeEngineRequestJSON
  , decodeLiveRequestJSON
  , dispatchLiveRequestJSON
  , encodeLiveErrorJSON
  , encodeLiveSuccessJSON
  , encodeHostRequestJSON
  , encodeEngineRequestJSON
  , encodeEngineResponseJSON
  , encodeProtocolErrorJSON
  , engineProtocol
  , hostProtocolVersion
  , hostRequestIdFromWord64
  , hostRequestIdToWord64
  , implementationVersion
  , maxHostRequestId
  , mkHostRequest
  , protocolVersion
  , productProtocol
  , renderEngineResponse
  , renderProtocolError
  , runLiveRequest
  , runEngineRequest
  , themeEditorProtocol
  , productProtocolV2
  , ProductV2Request (..)
  , PaintFenceValue (..)
  , SurfaceValue (..)
  , SurfaceKindValue (..)
  , PointerEventValue (..)
  , PointerSampleValue (..)
  , PointerTargetValue (..)
  , PointerTypeValue (..)
  , PointerButtonValue (..)
  , PointerModifiersValue (..)
  , PointValue (..)
  , ViewCommandValue (..)
  , ProductV2Error (..)
  , ProductV2Success
  , productV2Success
  , decodeProductV2RequestJSON
  , encodeProductV2SuccessJSON
  , encodeProductV2ErrorJSON
  ) where

import SlideBlaster.Protocol.Codec
import SlideBlaster.Protocol.Host
import SlideBlaster.Protocol.Product
import SlideBlaster.Protocol.ProductV2
import SlideBlaster.Protocol.Render
import SlideBlaster.Protocol.Run
import SlideBlaster.Protocol.Types
import SlideBlaster.Protocol.Version
