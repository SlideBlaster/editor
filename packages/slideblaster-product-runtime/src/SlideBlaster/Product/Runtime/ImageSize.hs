{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.ImageSize
-- Description : Intrinsic size of project images, read from the bytes.
--
-- Only the aspect ratio matters to layout, so SVG sizes come from the root
-- @viewBox@ (else @width@/@height@ with units stripped) and bitmap sizes from
-- the PNG, GIF, JPEG and WebP headers. Unreadable input yields 'Nothing'.
module SlideBlaster.Product.Runtime.ImageSize
  ( svgDimensions
  , imageDimensions
  , imageMime
  , isImagePath
  ) where

import Data.Bits (shiftL, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (isDigit, isSpace)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.Read qualified as TextRead

-- | Image file extensions the host can paint.
isImagePath :: Text -> Bool
isImagePath path = imageMime path /= Nothing

-- | Media type from the file extension.
imageMime :: Text -> Maybe Text
imageMime path
  | ext ".svg" = Just "image/svg+xml"
  | ext ".png" = Just "image/png"
  | ext ".jpg" || ext ".jpeg" = Just "image/jpeg"
  | ext ".gif" = Just "image/gif"
  | ext ".webp" = Just "image/webp"
  | otherwise = Nothing
  where
    ext suffix = suffix `Text.isSuffixOf` Text.toLower path

-- | Intrinsic size of an image by media type.
imageDimensions :: Text -> ByteString -> Maybe (Double, Double)
imageDimensions mime bytes =
  case mime of
    "image/svg+xml" -> svgDimensions (Encoding.decodeUtf8With (\_ _ -> Just '?') bytes)
    "image/png" -> pngSize
    "image/gif" -> gifSize
    "image/jpeg" -> jpegSize bytes
    "image/webp" -> webpSize
    _ -> Nothing
  where
    byte i = fromIntegral (ByteString.index bytes i) :: Int
    be32 i = (byte i `shiftL` 24) .|. (byte (i + 1) `shiftL` 16) .|. (byte (i + 2) `shiftL` 8) .|. byte (i + 3)
    le16 i = byte i .|. (byte (i + 1) `shiftL` 8)
    le24 i = le16 i .|. (byte (i + 2) `shiftL` 16)
    positive (w, h) = if w > 0 && h > 0 then Just (fromIntegral w, fromIntegral h) else Nothing
    pngSize
      | ByteString.length bytes >= 24 && ByteString.take 4 (ByteString.drop 1 bytes) == "PNG" = positive (be32 16, be32 20)
      | otherwise = Nothing
    gifSize
      | ByteString.length bytes >= 10 = positive (le16 6, le16 8)
      | otherwise = Nothing
    webpSize
      | ByteString.length bytes < 30 || ByteString.take 4 bytes /= "RIFF" = Nothing
      | otherwise = case ByteString.take 4 (ByteString.drop 12 bytes) of
          "VP8 " -> positive (le16 26 .&. 16383, le16 28 .&. 16383)
          "VP8L" ->
            let b = le24 21 .|. (byte 24 `shiftL` 24)
             in positive ((b .&. 16383) + 1, ((b `div` 16384) .&. 16383) + 1)
          "VP8X" -> positive (le24 24 + 1, le24 27 + 1)
          _ -> Nothing

-- Walk JPEG segments to the first start-of-frame marker.
jpegSize :: ByteString -> Maybe (Double, Double)
jpegSize bytes
  | ByteString.take 2 bytes /= ByteString.pack [0xff, 0xd8] = Nothing
  | otherwise = go 2
  where
    len = ByteString.length bytes
    at i = fromIntegral (ByteString.index bytes i) :: Int
    go i
      | i + 9 >= len = Nothing
      | at i /= 0xff = go (i + 1)
      | otherwise =
          let marker = at (i + 1)
              size = at (i + 2) * 256 + at (i + 3)
           in if marker == 0xff
                then go (i + 1)
                else
                  if marker `elem` ([0xc0 .. 0xc3] <> [0xc5 .. 0xc7] <> [0xc9 .. 0xcb] <> [0xcd .. 0xcf])
                    then
                      let h = at (i + 5) * 256 + at (i + 6)
                          w = at (i + 7) * 256 + at (i + 8)
                       in if w > 0 && h > 0 then Just (fromIntegral w, fromIntegral h) else Nothing
                    else go (i + 2 + max 2 size)

-- | Intrinsic size of an SVG: its @viewBox@, else @width@/@height@ (units
-- stripped).
svgDimensions :: Text -> Maybe (Double, Double)
svgDimensions svg =
  case viewBox of
    Just size -> Just size
    Nothing -> (,) <$> attribute "width" <*> attribute "height"
  where
    root = Text.takeWhile (/= '>') (snd (Text.breakOn "<svg" svg))
    attribute name = case Text.breakOn (name <> "=") root of
      (_, rest) | Text.null rest -> Nothing
      (before, rest)
        | maybe True (isSpace . snd) (Text.unsnoc before) -> number (Text.drop 1 (Text.drop (Text.length name + 1) rest))
        | otherwise -> Nothing
    viewBox = case Text.breakOn "viewBox=" root of
      (_, rest) | Text.null rest -> Nothing
      (_, rest) ->
        let quoted = Text.drop 1 (Text.drop 8 rest)
            parts = Text.words (Text.map (\c -> if c == ',' then ' ' else c) (Text.takeWhile (\c -> c /= '\'' && c /= '"') quoted))
         in case mapMaybe (fmap fst . either (const Nothing) Just . TextRead.double) parts of
              [_, _, w, h] | w > 0 && h > 0 -> Just (w, h)
              _ -> Nothing
    number t = case TextRead.double (Text.takeWhile (\c -> isDigit c || c == '.') t) of
      Right (v, _) | v > 0 -> Just v
      _ -> Nothing
