-- |
-- Module      : SlideBlaster.Source.Span
-- Description : Validated half-open byte spans into authored source.
--
-- Offsets count bytes, not Unicode code points. A 'SourceSpan' is half-open:
-- its start is included and its end is excluded.
module SlideBlaster.Source.Span
  ( ByteOffset
  , SourceSpan
  , mkByteOffset
  , mkSourceSpan
  , sourceSpanEnd
  , sourceSpanFromInts
  , sourceSpanLength
  , sourceSpanStart
  , unByteOffset
  ) where

-- | A non-negative byte offset in the common native/Wasm32 domain.
newtype ByteOffset = ByteOffset Int
  deriving (Eq, Ord, Show)

-- | A validated half-open byte span.
data SourceSpan = SourceSpan !ByteOffset !ByteOffset
  deriving (Eq, Ord, Show)

-- | Validate and construct a byte offset.
mkByteOffset :: Int -> Maybe ByteOffset
mkByteOffset value
  | value < 0 || value > maximumPortableByteOffset = Nothing
  | otherwise = Just (ByteOffset value)

maximumPortableByteOffset :: Int
maximumPortableByteOffset = 2_147_483_647

-- | Obtain the machine-sized byte count represented by an offset.
unByteOffset :: ByteOffset -> Int
unByteOffset (ByteOffset value) = value

-- | Construct a span when its start does not follow its end.
mkSourceSpan :: ByteOffset -> ByteOffset -> Maybe SourceSpan
mkSourceSpan start end
  | start <= end = Just (SourceSpan start end)
  | otherwise = Nothing

-- | Validate two integer offsets and construct a span.
sourceSpanFromInts :: Int -> Int -> Maybe SourceSpan
sourceSpanFromInts start end = do
  validStart <- mkByteOffset start
  validEnd <- mkByteOffset end
  mkSourceSpan validStart validEnd

-- | Return the included start offset.
sourceSpanStart :: SourceSpan -> ByteOffset
sourceSpanStart (SourceSpan start _) = start

-- | Return the excluded end offset.
sourceSpanEnd :: SourceSpan -> ByteOffset
sourceSpanEnd (SourceSpan _ end) = end

-- | Return the number of bytes covered by a span.
sourceSpanLength :: SourceSpan -> Int
sourceSpanLength spanValue =
  unByteOffset (sourceSpanEnd spanValue) - unByteOffset (sourceSpanStart spanValue)
