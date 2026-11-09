-- |
-- Module      : SlideBlaster.Extension.Sha256
-- Description : Pure SHA-256 for fingerprints (no C code, builds for Wasm).
--
-- A small, allocation-light implementation of FIPS 180-4 SHA-256 over strict
-- 'ByteString's. It exists so that fingerprints computed in the Wasm core and by
-- the native server are byte-identical without a C-FFI dependency. Throughput
-- is adequate for block requests (kilobytes); it is not a general hash library.
module SlideBlaster.Extension.Sha256
  ( sha256
  , sha256Hex
  ) where

import Data.Bits (complement, rotateR, shiftL, shiftR, xor, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List (foldl')
import Data.Word (Word32, Word64, Word8)

-- | The 32-byte SHA-256 digest of the input.
sha256 :: ByteString -> ByteString
sha256 input =
  ByteString.pack (concatMap wordBytes (hashWords (blocks (pad input))))

-- | The digest as 64 lower-case hexadecimal characters.
sha256Hex :: ByteString -> ByteString
sha256Hex = ByteString.pack . concatMap hexPair . ByteString.unpack . sha256
  where
    hexPair byte = [hexDigit (byte `shiftR` 4), hexDigit (byte .&. 15)]
    hexDigit n
      | n < 10 = 48 + n
      | otherwise = 87 + n

wordBytes :: Word32 -> [Word8]
wordBytes w =
  [ fromIntegral (w `shiftR` 24)
  , fromIntegral (w `shiftR` 16)
  , fromIntegral (w `shiftR` 8)
  , fromIntegral w
  ]

pad :: ByteString -> ByteString
pad input = ByteString.concat [input, ByteString.singleton 0x80, zeros, lengthBytes]
  where
    len = ByteString.length input
    zeros = ByteString.replicate ((55 - len) `mod` 64) 0
    bitLength = fromIntegral len * 8 :: Word64
    lengthBytes =
      ByteString.pack
        [fromIntegral (bitLength `shiftR` s) | s <- [56, 48 .. 0]]

blocks :: ByteString -> [ByteString]
blocks bytes
  | ByteString.null bytes = []
  | otherwise =
      let (block, rest) = ByteString.splitAt 64 bytes
       in block : blocks rest

type State = (Word32, Word32, Word32, Word32, Word32, Word32, Word32, Word32)

hashWords :: [ByteString] -> [Word32]
hashWords = stateList . foldl' compress initial
  where
    initial =
      ( 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
      , 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 )
    stateList (a, b, c, d, e, f, g, h) = [a, b, c, d, e, f, g, h]

compress :: State -> ByteString -> State
compress state@(a0, b0, c0, d0, e0, f0, g0, h0) block =
  ( a0 + a', b0 + b', c0 + c', d0 + d'
  , e0 + e', f0 + f', g0 + g', h0 + h' )
  where
    (a', b', c', d', e', f', g', h') =
      foldl' step state (zip roundConstants (schedule block))

step :: State -> (Word32, Word32) -> State
step (a, b, c, d, e, f, g, h) (k, w) =
  (t1 + t2, a, b, c, d + t1, e, f, g)
  where
    s1 = rotateR e 6 `xor` rotateR e 11 `xor` rotateR e 25
    ch = (e .&. f) `xor` (complement e .&. g)
    t1 = h + s1 + ch + k + w
    s0 = rotateR a 2 `xor` rotateR a 13 `xor` rotateR a 22
    maj = (a .&. b) `xor` (a .&. c) `xor` (b .&. c)
    t2 = s0 + maj

-- | The 64-entry message schedule of one 64-byte block.
schedule :: ByteString -> [Word32]
schedule block = take 64 (scheduleList (readWords (ByteString.unpack block)))

scheduleList :: [Word32] -> [Word32]
scheduleList initialWords = ws
  where
    ws = initialWords <> zipWith4' next (drop 14 ws) (drop 9 ws) (drop 1 ws) ws
    next w14 w9 w1 w0 = sigma1 w14 + w9 + sigma0 w1 + w0
    sigma0 x = rotateR x 7 `xor` rotateR x 18 `xor` shiftR x 3
    sigma1 x = rotateR x 17 `xor` rotateR x 19 `xor` shiftR x 10

zipWith4' :: (a -> b -> c -> d -> e) -> [a] -> [b] -> [c] -> [d] -> [e]
zipWith4' f (a : as) (b : bs) (c : cs) (d : ds) = f a b c d : zipWith4' f as bs cs ds
zipWith4' _ _ _ _ _ = []

readWords :: [Word8] -> [Word32]
readWords (a : b : c : d : rest) =
  ( (fromIntegral a `shiftL` 24)
      .|. (fromIntegral b `shiftL` 16)
      .|. (fromIntegral c `shiftL` 8)
      .|. fromIntegral d
  )
    : readWords rest
readWords _ = []

roundConstants :: [Word32]
roundConstants =
  [ 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
  , 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
  , 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
  , 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
  , 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
  , 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
  , 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
  , 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ]
