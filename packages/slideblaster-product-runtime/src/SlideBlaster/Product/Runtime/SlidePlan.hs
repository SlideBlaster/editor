{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.SlidePlan
-- Description : Assemble one closed session/1 plan for a frame, surface and step.
--
-- Furniture first, then the title, then the body flow, in theme regions
-- (session-v1-protocol.md sections 5 and 6). Pure and total: a missing theme
-- asset yields a labelled placeholder item, never a failure.
module SlideBlaster.Product.Runtime.SlidePlan
  ( PlanContext (..)
  , FrameInput (..)
  , TitleFields (..)
  , frameStepCount
  , frameBodyContent
  , buildPlan
  , base16Text
  , fnvHex
  ) where

import SlideBlaster.Canvas
  ( Content
  , SourceRef
  , contentNodes
  , mkOverlayStep
  , firstOverlayStep
  )
import SlideBlaster.Canvas.Flow (PictureItem)
import SlideBlaster.Product.Runtime.Picture (pictureValues)
import SlideBlaster.Product.Runtime.Lower (FigureInfo, contentStepCount, lowerContent)
import SlideBlaster.Product.Runtime.Theme

import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Bits (shiftR, xor, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64, Word8)

-- | Frontmatter fields of the generated title slide.
data TitleFields = TitleFields
  { titleFieldTitle :: !Text
  , titleFieldSubtitle :: !Text
  , titleFieldAuthors :: !Text
  , titleFieldInstitute :: !Text
  , titleFieldDate :: !Text
  , titleFieldDivider :: !Bool
  -- ^ a section divider: laid out by the theme's @sectionSlide@ block
  }
  deriving stock (Eq, Show)

-- | Semantic scene of one frame after flow desugaring.
data FrameInput = FrameInput
  { frameInputId :: !Text
  , frameInputTitle :: !Content
  , frameInputBody :: !Content
  , frameInputTitleSlide :: !(Maybe TitleFields)
  , frameInputPicture :: ![PictureItem]
  -- ^ nodes and lines of the picture tier
  , frameInputColours :: ![(Text, Text)]
  -- ^ deck colours (preamble @\\definecolor@) for the picture tier
  , frameInputFooter :: !Content
  -- ^ footer references (@\\citefootnote@), placed at the bottom of the body region
  }

data PlanContext = PlanContext
  { planSession :: !Word64
  , planRevision :: !Word64
  , planTicket :: !Word64
  , planPage :: !Int
  , planPages :: !Int
  , planDeckTitle :: !Text
  , planSection :: !Text
  -- ^ title of the current section; empty outside sections
  , planProgress :: !(Maybe Double)
  -- ^ position in the active route, 0 to 1
  , planSectionProgress :: !(Maybe Double)
  -- ^ position in the current section of the active route; none outside sections
  , planStep :: !Int
  , planSurface :: !Text
  , planFigures :: SourceRef -> FigureInfo
  , planAsset :: Text -> Maybe (Text, ByteString)
  , planArtifacts :: Map.Map Text (Text, ByteString)
  }

frameStepCount :: FrameInput -> Int
frameStepCount input = max (contentStepCount (frameInputTitle input)) (contentStepCount (frameInputBody input))

num :: Double -> Value
num value = Number (fromRational (toRational (fromIntegral (round (value * 1000) :: Integer) / 1000 :: Double)))

boxValue :: (Double, Double, Double, Double) -> Value
boxValue (x, y, w, h) = object ["x" .= num x, "y" .= num y, "width" .= num w, "height" .= num h]

fontPx :: Theme -> Text -> Double
fontPx theme key = unitScale * Map.findWithDefault 0.4 key (themeSizes theme)

styleValue :: Theme -> Text -> Text -> Text -> Bool -> Value
styleValue theme sizeKey colourToken align bold =
  object
    [ "font" .= themeBodyFont theme
    , "size" .= num (fontPx theme sizeKey)
    , "weight" .= (if bold then 700 else 400 :: Int)
    , "italic" .= False
    , "color" .= paletteColour theme colourToken
    , "align" .= align
    , "lineHeight" .= num 1.25
    ]

-- | Lowered body content of a frame at the context's step.
frameBodyContent :: PlanContext -> FrameInput -> [Value]
frameBodyContent context input =
  lowerContent step (planFigures context) (contentNodes (frameInputBody input))
  where
    step = fromMaybe firstOverlayStep (mkOverlayStep (fromIntegral (max 1 (planStep context))))

buildPlan :: Theme -> PlanContext -> FrameInput -> Value
buildPlan theme context input =
  object
    [ "protocol" .= ("slideblaster.session/1" :: Text)
    , "frame" .= frameInputId input
    , "surface" .= planSurface context
    , "step" .= planStep context
    , "steps" .= frameStepCount input
    , "session" .= planSession context
    , "revision" .= planRevision context
    , "ticket" .= planTicket context
    , "coordinateSpace" .= ("slide_y_down" :: Text)
    , "size" .= object ["width" .= num width, "height" .= num height]
    , "background" .= object ["fill" .= paletteColour theme "background"]
    , "artifacts" .= object [Key.fromText fingerprint .= object ["mime" .= mime, "bytesBase16" .= base16Text bytes] | (fingerprint, (mime, bytes)) <- Map.toList (planArtifacts context)]
    , "items" .= (furniture <> body)
    ]
  where
    (width, height) = themePlanSize theme
    isFirst = planPage context == 1
    step = fromMaybe firstOverlayStep (mkOverlayStep (fromIntegral (max 1 (planStep context))))
    bodyContent = lowered (contentNodes (frameInputBody input))
    lowered nodes = lowerContent step (planFigures context) nodes
    furniture = concat (zipWith (furnitureItem theme context isFirst) [0 :: Int ..] (themeFurniture theme))
    body = case frameInputTitleSlide input of
      Just fields -> titleSlideItems theme fields
      Nothing ->
        [ textItem theme "title" (regionOrDefault "title") (styleValue theme "title" "ink" "left" True) (lowered (contentNodes (frameInputTitle input)))
        , object
            [ "kind" .= ("flow" :: Text)
            , "id" .= ("body" :: Text)
            , "box" .= boxValue (regionBox theme (regionOrDefault "body"))
            , "style" .= styleValue theme "body" "ink" "left" False
            , "content" .= bodyContent
            , "contentHash" .= fnvHex (LazyByteString.toStrict (encode bodyContent))
            ]
        ]
          <> footerItems
          <> pictureItemsOut
    pictureItemsOut
      | null (frameInputPicture input) = []
      | otherwise = pictureValues (frameInputColours input) (styleValue theme "body" "ink" "left" False) (paletteColour theme "ink") step (planFigures context) (height / unitScale) (frameInputPicture input)
    footerNodes = contentNodes (frameInputFooter input)
    footerItems
      | null footerNodes = []
      | otherwise =
          let (bx, by, bw, bh) = regionBox theme (regionOrDefault "body")
              lineHeight = fontPx theme "small" * 1.5
              fh = fromIntegral (length footerNodes) * lineHeight
              footerContent = lowered footerNodes
           in [ object
                  [ "kind" .= ("flow" :: Text)
                  , "id" .= ("footer-refs" :: Text)
                  , "box" .= boxValue (bx, by + bh - fh, bw, fh)
                  , "style" .= styleValue theme "small" "muted" "left" False
                  , "content" .= footerContent
                  , "contentHash" .= fnvHex (LazyByteString.toStrict (encode footerContent))
                  ]
              ]
    regionOrDefault key = Map.findWithDefault (Region 0 0 0 0 "left") key (themeRegions theme)

textItem :: Theme -> Text -> Region -> Value -> [Value] -> Value
textItem theme identifier region' style children =
  object
    [ "kind" .= ("text" :: Text)
    , "id" .= identifier
    , "box" .= boxValue (regionBox theme region')
    , "style" .= style
    , "content" .= children
    , "visibility" .= ("visible" :: Text)
    ]

plainText :: Text -> [Value]
plainText text =
  [ object
      [ "t" .= ("text" :: Text), "text" .= text, "bold" .= False, "italic" .= False
      , "mono" .= False, "color" .= Null ]
  ]

titleSlideItems :: Theme -> TitleFields -> [Value]
titleSlideItems theme fields
  | titleFieldDivider fields =
      ( [ field "title" "title" "ink" True (titleFieldTitle fields)
        , field "subtitle" "subtitle" "muted" False (titleFieldSubtitle fields)
        ]
          >>= filterEmpty
      )
  | otherwise =
  [ field "title" "title" "ink" True (titleFieldTitle fields)
  , field "subtitle" "subtitle" "muted" False (titleFieldSubtitle fields)
  , field "authors" "body" "ink" False (titleFieldAuthors fields)
  , field "institute" "small" "muted" False (titleFieldInstitute fields)
  , field "date" "small" "muted" False (titleFieldDate fields)
  ]
  >>= filterEmpty
  where
    field key sizeKey colour bold value =
      case Map.lookup key (if titleFieldDivider fields then themeSectionSlide theme else themeTitleSlide theme) of
        Nothing -> Null
        Just r | Text.null value -> const Null r
               | otherwise -> textItem theme key r (styleValue theme sizeKey colour (regionAlign r) bold) (plainText value)
    filterEmpty Null = []
    filterEmpty v = [v]

furnitureItem :: Theme -> PlanContext -> Bool -> Int -> Furniture -> [Value]
furnitureItem theme context isFirst index item
  | not applies = []
  | otherwise =
      case furnitureKind item of
        "rule" ->
          [ object
              [ "kind" .= ("rect" :: Text), "id" .= identifier, "box" .= box
              , "fill" .= paletteColour theme (fromMaybe "rule" (furnitureFill item))
              , "stroke" .= Null, "radius" .= num 0, "opacity" .= num 1, "hit" .= Null ]
          ]
        "page-number" ->
          [textual (Text.pack (show (planPage context)))]
        "footer-text" ->
          [textual (expand (fromMaybe "" (furnitureText item)))]
        "progress" ->
          case if furniturePer item == Just "section" then planSectionProgress context else planProgress context of
            Nothing -> []
            Just fraction ->
              let (bx, by, bw, bh) = regionBox theme (furnitureRegion item)
                  bar suffix width colour =
                    object
                      [ "kind" .= ("rect" :: Text), "id" .= (identifier <> suffix)
                      , "box" .= boxValue (bx, by, width, bh)
                      , "fill" .= paletteColour theme colour
                      , "stroke" .= Null, "radius" .= num 0, "opacity" .= num 1, "hit" .= Null ]
               in [bar "-track" bw "rule", bar "-fill" (bw * max 0 (min 1 fraction)) (fromMaybe "accent" (furnitureFill item))]
        "logo" ->
          case furnitureAsset item >>= planAsset context of
            Just (mime, bytes) ->
              [ object
                  [ "kind" .= ("image" :: Text), "id" .= identifier, "box" .= box
                  , "resource" .= object ["mime" .= mime, "bytesBase16" .= base16Text bytes]
                  , "alt" .= ("logo" :: Text), "fit" .= ("contain" :: Text) ]
              ]
            Nothing -> []
        _ -> []
  where
    applies = case furnitureSlides item of
      AllSlides -> True
      FirstSlide -> isFirst
      NotFirstSlide -> not isFirst
    identifier = "furniture-" <> Text.pack (show index)
    -- footer-text templates: {{title}}, {{section}}, {{page}}, {{pages}}
    expand =
      Text.replace "{{title}}" (planDeckTitle context)
        . Text.replace "{{section}}" (planSection context)
        . Text.replace "{{page}}" (Text.pack (show (planPage context)))
        . Text.replace "{{pages}}" (Text.pack (show (planPages context)))
    box = boxValue (regionBox theme (furnitureRegion item))
    textual value =
      textItem theme identifier (furnitureRegion item) (styleValue theme "small" "muted" (regionAlign (furnitureRegion item)) False) (plainText value)

-- | Lower-case base16 text of exact bytes.
base16Text :: ByteString -> Text
base16Text = Text.pack . concatMap byteHex . ByteString.unpack
  where
    byteHex byte = [digit (byte `shiftR` 4), digit (byte .&. 15)]
    digit nibble
      | nibble < 10 = toEnum (fromEnum '0' + fromIntegral nibble)
      | otherwise = toEnum (fromEnum 'a' + fromIntegral nibble - 10)

-- | 64-bit FNV-1a of exact bytes as 16 hex digits (cache key for host
-- measurement; not a security fence).
fnvHex :: ByteString -> Text
fnvHex bytes = base16Text (ByteString.pack (fmap fromIntegral (word64Bytes (ByteString.foldl' step 14695981039346656037 bytes))))
  where
    step :: Word64 -> Word8 -> Word64
    step hash byte = (hash `xor` fromIntegral byte) * 1099511628211
    word64Bytes :: Word64 -> [Word64]
    word64Bytes value = [(value `shiftR` shiftAmount) .&. 255 | shiftAmount <- [56, 48 .. 0]]
