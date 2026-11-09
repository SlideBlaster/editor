-- |
-- Module      : SlideBlaster.Product.Runtime.Sha256
-- Description : Portable pure SHA-256 for block fingerprints.
--
-- FIPS 180-4, no dependencies beyond base, so the same core builds natively and
-- for Wasm. Used for the session/1 provider fingerprint fence, not for secrets.
module SlideBlaster.Product.Runtime.Sha256
  ( sha256
  , sha256Hex
  ) where

import Data.Bits (complement, rotateR, shiftL, shiftR, xor, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Word (Word32, Word64, Word8)

-- | Raw 32-byte digest.
sha256 :: ByteString -> ByteString
sha256 message =
  ByteString.pack (concatMap wordBytes (finalState message))
  where
    wordBytes :: Word32 -> [Word8]
    wordBytes w = [fromIntegral (w `shiftR` s) | s <- [24, 16, 8, 0]]

-- | Lower-case hex digest.
sha256Hex :: ByteString -> String
sha256Hex = concatMap hex . ByteString.unpack . sha256
  where
    hex byte = [digit (byte `shiftR` 4), digit (byte .&. 15)]
    digit nibble
      | nibble < 10 = toEnum (fromEnum '0' + fromIntegral nibble)
      | otherwise = toEnum (fromEnum 'a' + fromIntegral nibble - 10)

finalState :: ByteString -> [Word32]
finalState message = foldl' compress initial (blocks padded)
  where
    padded = pad message
    initial =
      [ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
      , 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 ]

pad :: ByteString -> ByteString
pad message =
  ByteString.concat
    [ message
    , ByteString.singleton 0x80
    , ByteString.replicate zeros 0
    , ByteString.pack [fromIntegral (bitLength `shiftR` s) | s <- [56, 48 .. 0]]
    ]
  where
    len = ByteString.length message
    zeros = (55 - len) `mod` 64
    bitLength = fromIntegral len * 8 :: Word64

blocks :: ByteString -> [ByteString]
blocks bytes
  | ByteString.null bytes = []
  | otherwise = let (block, rest) = ByteString.splitAt 64 bytes in block : blocks rest

toWords :: ByteString -> [Word32]
toWords bytes
  | ByteString.length bytes < 4 = []
  | otherwise =
      let (four, rest) = ByteString.splitAt 4 bytes
          word = foldl' (\acc b -> (acc `shiftL` 8) .|. fromIntegral b) 0 (ByteString.unpack four)
       in word : toWords rest

schedule :: [Word32] -> [Word32]
schedule initialWords = initialWords <> go initialWords (48 :: Int)
  where
    go _ 0 = []
    go window remaining =
      case window of
        [w16, w15, _, _, _, _, _, _, _, w7, _, _, _, _, w2, _] ->
          let s0 = (w15 `rotateR` 7) `xor` (w15 `rotateR` 18) `xor` (w15 `shiftR` 3)
              s1 = (w2 `rotateR` 17) `xor` (w2 `rotateR` 19) `xor` (w2 `shiftR` 10)
              next = w16 + s0 + w7 + s1
           in next : go (drop 1 window <> [next]) (remaining - 1)
        _ -> []

compress :: [Word32] -> ByteString -> [Word32]
compress state block = zipWith (+) state (finish (foldl' round' state (zip constants (schedule (toWords block)))))
  where
    finish = id
    round' [a, b, c, d, e, f, g, h] (k, w) =
      let s1 = (e `rotateR` 6) `xor` (e `rotateR` 11) `xor` (e `rotateR` 25)
          ch = (e .&. f) `xor` (complement e .&. g)
          t1 = h + s1 + ch + k + w
          s0 = (a `rotateR` 2) `xor` (a `rotateR` 13) `xor` (a `rotateR` 22)
          maj = (a .&. b) `xor` (a .&. c) `xor` (b .&. c)
          t2 = s0 + maj
       in [t1 + t2, a, b, c, d + t1, e, f, g]
    round' other _ = other

constants :: [Word32]
constants =
  [ 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
  , 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
  , 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
  , 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
  , 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
  , 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
  , 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
  , 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2 ]
