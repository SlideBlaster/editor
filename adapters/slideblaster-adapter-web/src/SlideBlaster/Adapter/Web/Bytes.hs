{-# LANGUAGE JavaScriptFFI #-}

-- |
-- Module      : SlideBlaster.Adapter.Web.Bytes
-- Description : Byte strings across the JSFFI boundary, as @Uint8Array@.
--
-- A session frame carries whole decks and figures. Passing it as a JavaScript
-- string would go through a Haskell 'String', one heap cell per character; here
-- the bytes are copied once, straight between the Wasm memory and a
-- @Uint8Array@.
module SlideBlaster.Adapter.Web.Bytes
  ( JSVal
  , bytesFromJS
  , bytesToJS
  , nullValue
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Internal qualified as Internal
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.Word (Word8)
import Foreign.Ptr (Ptr, castPtr)
import GHC.Wasm.Prim (JSVal)

foreign import javascript unsafe "$1.byteLength"
  jsByteLength :: JSVal -> IO Int

foreign import javascript unsafe "new Uint8Array(__exports.memory.buffer, $2, $1.byteLength).set($1)"
  jsCopyIn :: JSVal -> Ptr Word8 -> IO ()

foreign import javascript unsafe "new Uint8Array(__exports.memory.buffer, $1, $2).slice()"
  jsCopyOut :: Ptr Word8 -> Int -> IO JSVal

foreign import javascript unsafe "null"
  jsNull :: IO JSVal

-- | The bytes of a @Uint8Array@.
bytesFromJS :: JSVal -> IO ByteString
bytesFromJS value = do
  size <- jsByteLength value
  Internal.create size (jsCopyIn value)

-- | A fresh @Uint8Array@ holding the bytes.
bytesToJS :: ByteString -> IO JSVal
bytesToJS bytes = unsafeUseAsCStringLen bytes (\(pointer, size) -> jsCopyOut (castPtr pointer) size)

-- | JavaScript @null@.
nullValue :: IO JSVal
nullValue = jsNull
