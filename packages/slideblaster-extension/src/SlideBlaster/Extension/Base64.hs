-- |
-- Module      : SlideBlaster.Extension.Base64
-- Description : Pure RFC 4648 base64 (padded) for envelope bytes.
--
-- Envelope fields that carry arbitrary bytes use standard-alphabet padded
-- base64. Decoding is strict: wrong length, bad characters or misplaced padding
-- yield 'Nothing'.
module SlideBlaster.Extension.Base64
  ( encodeBase64
  , decodeBase64
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Word (Word8)

-- | Encode bytes as padded base64 text (ASCII bytes).
encodeBase64 :: ByteString -> ByteString
encodeBase64 = ByteString.pack . go . ByteString.unpack
  where
    go (a : b : c : rest) = quad a b c <> go rest
    go [a, b] = take 3 (quad a b 0) <> [61]
    go [a] = take 2 (quad a 0 0) <> [61, 61]
    go [] = []
    quad a b c =
      let n = (fromIntegral a `shiftL` 16) .|. (fromIntegral b `shiftL` 8) .|. fromIntegral c :: Int
       in [ symbol (n `shiftR` 18), symbol (n `shiftR` 12)
          , symbol (n `shiftR` 6), symbol n ]
    symbol n = alphabet (n .&. 63)

alphabet :: Int -> Word8
alphabet n
  | n < 26 = fromIntegral (65 + n)
  | n < 52 = fromIntegral (71 + n)
  | n < 62 = fromIntegral (n - 4)
  | n == 62 = 43
  | otherwise = 47

unalphabet :: Word8 -> Maybe Int
unalphabet w
  | w >= 65 && w <= 90 = Just (fromIntegral w - 65)
  | w >= 97 && w <= 122 = Just (fromIntegral w - 71)
  | w >= 48 && w <= 57 = Just (fromIntegral w + 4)
  | w == 43 = Just 62
  | w == 47 = Just 63
  | otherwise = Nothing

-- | Decode padded base64 text; 'Nothing' on any irregularity.
decodeBase64 :: ByteString -> Maybe ByteString
decodeBase64 input
  | ByteString.length input `mod` 4 /= 0 = Nothing
  | otherwise = ByteString.pack <$> go (ByteString.unpack input)
  where
    go [] = Just []
    go [a, b, 61, 61] = do
      x <- unalphabet a
      y <- unalphabet b
      let n = (x `shiftL` 18) .|. (y `shiftL` 12)
      if y .&. 15 /= 0 then Nothing else Just [byte n 16]
    go [a, b, c, 61] = do
      x <- unalphabet a
      y <- unalphabet b
      z <- unalphabet c
      let n = (x `shiftL` 18) .|. (y `shiftL` 12) .|. (z `shiftL` 6)
      if z .&. 3 /= 0 then Nothing else Just [byte n 16, byte n 8]
    go (a : b : c : d : rest) = do
      x <- unalphabet a
      y <- unalphabet b
      z <- unalphabet c
      w <- unalphabet d
      let n = (x `shiftL` 18) .|. (y `shiftL` 12) .|. (z `shiftL` 6) .|. w
      (\more -> [byte n 16, byte n 8, byte n 0] <> more) <$> go rest
    go _ = Nothing
    byte n s = fromIntegral ((n `shiftR` s) .&. 255)
