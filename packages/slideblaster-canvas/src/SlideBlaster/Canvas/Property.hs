{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Canvas.Property
-- Description : Typed visual properties and explicit override layers.
--
-- Node and connector authoring keeps partial overrides separate from resolved
-- total properties. A higher patch wins field-by-field; semantic roles remain
-- ordinary typed data rather than being smuggled into an untyped option map.
module SlideBlaster.Canvas.Property
  ( Colour (..)
  , ColourRef (..)
  , GradientStop (..)
  , Gradient (..)
  , Paint (..)
  , Stroke (..)
  , DashPattern (..)
  , mkCustomDash
  , Opacity
  , mkOpacity
  , opacityValue
  , opaqueOpacity
  , Rotation
  , rotation
  , rotationDegrees
  , noRotation
  , Scale
  , mkScale
  , scaleX
  , scaleY
  , unitScale
  , Flip (..)
  , Transform (..)
  , identityTransform
  , Shadow (..)
  , CornerTreatment (..)
  , FontSize
  , mkFontSize
  , fontSizeUnit
  , FontFamily (..)
  , FontWeight (..)
  , FontPosture (..)
  , TextDecoration (..)
  , HorizontalAlignment (..)
  , VerticalAlignment (..)
  , Typography (..)
  , defaultTypography
  , Sizing (..)
  , ArrowTip (..)
  , LineJoin (..)
  , NodePropertyPatch (..)
  , emptyNodePropertyPatch
  , mergeNodePropertyPatch
  , NodeProperties (..)
  , defaultNodeProperties
  , applyNodePropertyPatch
  , ConnectorPropertyPatch (..)
  , emptyConnectorPropertyPatch
  , mergeConnectorPropertyPatch
  , ConnectorProperties (..)
  , defaultConnectorProperties
  , applyConnectorPropertyPatch
  ) where

import SlideBlaster.Canvas.Geometry
  ( CanvasUnit
  , Point
  , Size
  , Vector
  , canvasUnit
  , canvasUnitValue
  )
import SlideBlaster.Canvas.Identifier (RoleId)
import SlideBlaster.Canvas.Overlay (OverlayHook (AlwaysVisible))

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Word (Word16, Word8)

-- | Structured direct colour.
data Colour
  = RGB !Word8 !Word8 !Word8
  | RGBA !Word8 !Word8 !Word8 !Word8
  deriving stock (Eq, Ord, Show)

-- | Either a direct colour or a named key resolved through a theme palette.
data ColourRef
  = DirectColour !Colour
  | PaletteColour !Text
  deriving stock (Eq, Ord, Show)

data GradientStop = GradientStop
  { gradientStopOffset :: !Opacity
  , gradientStopColour :: !ColourRef
  }
  deriving stock (Eq, Ord, Show)

data Gradient
  = LinearGradient !Rotation !(NonEmpty GradientStop)
  | RadialGradient !Point !CanvasUnit !(NonEmpty GradientStop)
  deriving stock (Eq, Ord, Show)

data Paint
  = NoPaint
  | SolidPaint !ColourRef
  | GradientPaint !Gradient
  deriving stock (Eq, Ord, Show)

-- | Outline state and width. Dash and opacity stay independent properties.
data Stroke
  = NoStroke
  | SolidStroke !ColourRef !CanvasUnit
  deriving stock (Eq, Ord, Show)

data DashPattern
  = SolidDash
  | Dashed
  | Dotted
  | CustomDash !(NonEmpty CanvasUnit)
  deriving stock (Eq, Ord, Show)

mkCustomDash :: NonEmpty CanvasUnit -> Maybe DashPattern
mkCustomDash intervals
  | all ((> 0) . canvasUnitValue) intervals = Just (CustomDash intervals)
  | otherwise = Nothing

-- | Closed unit interval opacity.
newtype Opacity = Opacity Rational
  deriving stock (Eq, Ord, Show)

mkOpacity :: Rational -> Maybe Opacity
mkOpacity value
  | value >= 0 && value <= 1 = Just (Opacity value)
  | otherwise = Nothing

opacityValue :: Opacity -> Rational
opacityValue (Opacity value) = value

opaqueOpacity :: Opacity
opaqueOpacity = Opacity 1

-- | Clockwise visual rotation in degrees.
newtype Rotation = Rotation Rational
  deriving stock (Eq, Ord, Show)

rotation :: Rational -> Rotation
rotation = Rotation

rotationDegrees :: Rotation -> Rational
rotationDegrees (Rotation value) = value

noRotation :: Rotation
noRotation = Rotation 0

-- | Strictly positive dimensionless visual scale.
data Scale = Scale !Rational !Rational
  deriving stock (Eq, Ord, Show)

mkScale :: Rational -> Rational -> Maybe Scale
mkScale x y
  | x > 0 && y > 0 = Just (Scale x y)
  | otherwise = Nothing

scaleX :: Scale -> Rational
scaleX (Scale x _) = x

scaleY :: Scale -> Rational
scaleY (Scale _ y) = y

unitScale :: Scale
unitScale = Scale 1 1

data Flip
  = NoFlip
  | FlipHorizontal
  | FlipVertical
  | FlipBoth
  deriving stock (Eq, Ord, Show)

data Transform = Transform
  { transformRotation :: !Rotation
  , transformScale :: !Scale
  , transformFlip :: !Flip
  }
  deriving stock (Eq, Ord, Show)

identityTransform :: Transform
identityTransform = Transform noRotation unitScale NoFlip

data Shadow
  = NoShadow
  | DropShadow !Vector !CanvasUnit !ColourRef !Opacity
  deriving stock (Eq, Ord, Show)

data CornerTreatment
  = SharpCorners
  | RoundedCorners !CanvasUnit
  | ChamferedCorners !CanvasUnit
  deriving stock (Eq, Ord, Show)

-- | Strictly positive authored font size in slide units.
newtype FontSize = FontSize CanvasUnit
  deriving stock (Eq, Ord, Show)

mkFontSize :: CanvasUnit -> Maybe FontSize
mkFontSize value
  | canvasUnitValue value > 0 = Just (FontSize value)
  | otherwise = Nothing

fontSizeUnit :: FontSize -> CanvasUnit
fontSizeUnit (FontSize value) = value

data FontFamily
  = ThemeFont
  | NamedFont !Text
  deriving stock (Eq, Ord, Show)

data FontWeight
  = WeightNormal
  | WeightBold
  | WeightNumber !Word16
  deriving stock (Eq, Ord, Show)

data FontPosture = Upright | Italic
  deriving stock (Eq, Ord, Show)

data TextDecoration
  = NoDecoration
  | UnderlineText
  | StrikeText
  deriving stock (Eq, Ord, Show)

data HorizontalAlignment = AlignLeft | AlignCentre | AlignRight
  deriving stock (Eq, Ord, Show)

data VerticalAlignment = AlignTop | AlignMiddle | AlignBottom
  deriving stock (Eq, Ord, Show)

data Typography = Typography
  { typographyFamily :: !FontFamily
  , typographySize :: !FontSize
  , typographyWeight :: !FontWeight
  , typographyPosture :: !FontPosture
  , typographyDecoration :: !TextDecoration
  , typographyColour :: !ColourRef
  , typographyHorizontal :: !HorizontalAlignment
  , typographyVertical :: !VerticalAlignment
  , typographyWrapWidth :: !(Maybe CanvasUnit)
  , typographyLineSpacing :: !Rational
  }
  deriving stock (Eq, Ord, Show)

defaultTypography :: Typography
defaultTypography =
  Typography
    { typographyFamily = ThemeFont
    , typographySize = FontSize (canvasUnit (3 / 10))
    , typographyWeight = WeightNormal
    , typographyPosture = Upright
    , typographyDecoration = NoDecoration
    , typographyColour = PaletteColour "ink"
    , typographyHorizontal = AlignCentre
    , typographyVertical = AlignMiddle
    , typographyWrapWidth = Nothing
    , typographyLineSpacing = 1
    }

-- | Authored sizing policy, distinct from a measured resolved box.
data Sizing
  = ContentSized
  | MinimumSize !Size
  | FixedSize !Size
  | FixedWidth !CanvasUnit
  | FixedHeight !CanvasUnit
  | AspectLocked !Size
  deriving stock (Eq, Ord, Show)

-- | Extensible connector tip name; render targets classify support separately.
data ArrowTip
  = NoArrowTip
  | NamedArrowTip !Text
  deriving stock (Eq, Ord, Show)

data LineJoin = MiterJoin | RoundJoin | BevelJoin
  deriving stock (Eq, Ord, Show)

-- | Explicit node values. 'Nothing' means this layer does not override a field.
data NodePropertyPatch = NodePropertyPatch
  { nodePatchPaint :: !(Maybe Paint)
  , nodePatchStroke :: !(Maybe Stroke)
  , nodePatchDash :: !(Maybe DashPattern)
  , nodePatchOpacity :: !(Maybe Opacity)
  , nodePatchRotation :: !(Maybe Rotation)
  , nodePatchScale :: !(Maybe Scale)
  , nodePatchFlip :: !(Maybe Flip)
  , nodePatchShadow :: !(Maybe Shadow)
  , nodePatchCornerTreatment :: !(Maybe CornerTreatment)
  , nodePatchSizing :: !(Maybe Sizing)
  , nodePatchTypography :: !(Maybe Typography)
  , nodePatchRole :: !(Maybe RoleId)
  , nodePatchOverlay :: !(Maybe OverlayHook)
  }
  deriving stock (Eq, Ord, Show)

emptyNodePropertyPatch :: NodePropertyPatch
emptyNodePropertyPatch =
  NodePropertyPatch
    { nodePatchPaint = Nothing
    , nodePatchStroke = Nothing
    , nodePatchDash = Nothing
    , nodePatchOpacity = Nothing
    , nodePatchRotation = Nothing
    , nodePatchScale = Nothing
    , nodePatchFlip = Nothing
    , nodePatchShadow = Nothing
    , nodePatchCornerTreatment = Nothing
    , nodePatchSizing = Nothing
    , nodePatchTypography = Nothing
    , nodePatchRole = Nothing
    , nodePatchOverlay = Nothing
    }

-- | Merge a lower-precedence patch with a higher-precedence patch.
mergeNodePropertyPatch ::
  NodePropertyPatch ->
  NodePropertyPatch ->
  NodePropertyPatch
mergeNodePropertyPatch lower higher =
  NodePropertyPatch
    { nodePatchPaint = prefer (nodePatchPaint higher) (nodePatchPaint lower)
    , nodePatchStroke = prefer (nodePatchStroke higher) (nodePatchStroke lower)
    , nodePatchDash = prefer (nodePatchDash higher) (nodePatchDash lower)
    , nodePatchOpacity = prefer (nodePatchOpacity higher) (nodePatchOpacity lower)
    , nodePatchRotation = prefer (nodePatchRotation higher) (nodePatchRotation lower)
    , nodePatchScale = prefer (nodePatchScale higher) (nodePatchScale lower)
    , nodePatchFlip = prefer (nodePatchFlip higher) (nodePatchFlip lower)
    , nodePatchShadow = prefer (nodePatchShadow higher) (nodePatchShadow lower)
    , nodePatchCornerTreatment =
        prefer
          (nodePatchCornerTreatment higher)
          (nodePatchCornerTreatment lower)
    , nodePatchSizing = prefer (nodePatchSizing higher) (nodePatchSizing lower)
    , nodePatchTypography =
        prefer (nodePatchTypography higher) (nodePatchTypography lower)
    , nodePatchRole = prefer (nodePatchRole higher) (nodePatchRole lower)
    , nodePatchOverlay = prefer (nodePatchOverlay higher) (nodePatchOverlay lower)
    }

-- | Fully resolved node values consumed by layout and target planners.
data NodeProperties = NodeProperties
  { nodePaint :: !Paint
  , nodeStroke :: !Stroke
  , nodeDash :: !DashPattern
  , nodeOpacity :: !Opacity
  , nodeRotation :: !Rotation
  , nodeScale :: !Scale
  , nodeFlip :: !Flip
  , nodeShadow :: !Shadow
  , nodeCornerTreatment :: !CornerTreatment
  , nodeSizing :: !Sizing
  , nodeTypography :: !Typography
  , nodeRole :: !RoleId
  , nodeOverlay :: !OverlayHook
  }
  deriving stock (Eq, Ord, Show)

defaultNodeProperties :: RoleId -> NodeProperties
defaultNodeProperties role =
  NodeProperties
    { nodePaint = NoPaint
    , nodeStroke = NoStroke
    , nodeDash = SolidDash
    , nodeOpacity = opaqueOpacity
    , nodeRotation = noRotation
    , nodeScale = unitScale
    , nodeFlip = NoFlip
    , nodeShadow = NoShadow
    , nodeCornerTreatment = SharpCorners
    , nodeSizing = ContentSized
    , nodeTypography = defaultTypography
    , nodeRole = role
    , nodeOverlay = AlwaysVisible
    }

applyNodePropertyPatch :: NodeProperties -> NodePropertyPatch -> NodeProperties
applyNodePropertyPatch base patch =
  NodeProperties
    { nodePaint = maybe (nodePaint base) id (nodePatchPaint patch)
    , nodeStroke = maybe (nodeStroke base) id (nodePatchStroke patch)
    , nodeDash = maybe (nodeDash base) id (nodePatchDash patch)
    , nodeOpacity = maybe (nodeOpacity base) id (nodePatchOpacity patch)
    , nodeRotation = maybe (nodeRotation base) id (nodePatchRotation patch)
    , nodeScale = maybe (nodeScale base) id (nodePatchScale patch)
    , nodeFlip = maybe (nodeFlip base) id (nodePatchFlip patch)
    , nodeShadow = maybe (nodeShadow base) id (nodePatchShadow patch)
    , nodeCornerTreatment =
        maybe
          (nodeCornerTreatment base)
          id
          (nodePatchCornerTreatment patch)
    , nodeSizing = maybe (nodeSizing base) id (nodePatchSizing patch)
    , nodeTypography =
        maybe (nodeTypography base) id (nodePatchTypography patch)
    , nodeRole = maybe (nodeRole base) id (nodePatchRole patch)
    , nodeOverlay = maybe (nodeOverlay base) id (nodePatchOverlay patch)
    }

-- | Explicit connector values, including label typography and role.
data ConnectorPropertyPatch = ConnectorPropertyPatch
  { connectorPatchPaint :: !(Maybe Paint)
  , connectorPatchStroke :: !(Maybe Stroke)
  , connectorPatchDash :: !(Maybe DashPattern)
  , connectorPatchOpacity :: !(Maybe Opacity)
  , connectorPatchRotation :: !(Maybe Rotation)
  , connectorPatchSizing :: !(Maybe Sizing)
  , connectorPatchTypography :: !(Maybe Typography)
  , connectorPatchRole :: !(Maybe RoleId)
  , connectorPatchOverlay :: !(Maybe OverlayHook)
  , connectorPatchStartTip :: !(Maybe ArrowTip)
  , connectorPatchEndTip :: !(Maybe ArrowTip)
  , connectorPatchLineJoin :: !(Maybe LineJoin)
  }
  deriving stock (Eq, Ord, Show)

emptyConnectorPropertyPatch :: ConnectorPropertyPatch
emptyConnectorPropertyPatch =
  ConnectorPropertyPatch
    { connectorPatchPaint = Nothing
    , connectorPatchStroke = Nothing
    , connectorPatchDash = Nothing
    , connectorPatchOpacity = Nothing
    , connectorPatchRotation = Nothing
    , connectorPatchSizing = Nothing
    , connectorPatchTypography = Nothing
    , connectorPatchRole = Nothing
    , connectorPatchOverlay = Nothing
    , connectorPatchStartTip = Nothing
    , connectorPatchEndTip = Nothing
    , connectorPatchLineJoin = Nothing
    }

mergeConnectorPropertyPatch ::
  ConnectorPropertyPatch ->
  ConnectorPropertyPatch ->
  ConnectorPropertyPatch
mergeConnectorPropertyPatch lower higher =
  ConnectorPropertyPatch
    { connectorPatchPaint =
        prefer (connectorPatchPaint higher) (connectorPatchPaint lower)
    , connectorPatchStroke =
        prefer (connectorPatchStroke higher) (connectorPatchStroke lower)
    , connectorPatchDash =
        prefer (connectorPatchDash higher) (connectorPatchDash lower)
    , connectorPatchOpacity =
        prefer (connectorPatchOpacity higher) (connectorPatchOpacity lower)
    , connectorPatchRotation =
        prefer (connectorPatchRotation higher) (connectorPatchRotation lower)
    , connectorPatchSizing =
        prefer (connectorPatchSizing higher) (connectorPatchSizing lower)
    , connectorPatchTypography =
        prefer (connectorPatchTypography higher) (connectorPatchTypography lower)
    , connectorPatchRole =
        prefer (connectorPatchRole higher) (connectorPatchRole lower)
    , connectorPatchOverlay =
        prefer (connectorPatchOverlay higher) (connectorPatchOverlay lower)
    , connectorPatchStartTip =
        prefer (connectorPatchStartTip higher) (connectorPatchStartTip lower)
    , connectorPatchEndTip =
        prefer (connectorPatchEndTip higher) (connectorPatchEndTip lower)
    , connectorPatchLineJoin =
        prefer (connectorPatchLineJoin higher) (connectorPatchLineJoin lower)
    }

data ConnectorProperties = ConnectorProperties
  { connectorPaint :: !Paint
  , connectorStroke :: !Stroke
  , connectorDash :: !DashPattern
  , connectorOpacity :: !Opacity
  , connectorRotation :: !Rotation
  , connectorSizing :: !Sizing
  , connectorTypography :: !Typography
  , connectorRole :: !RoleId
  , connectorOverlay :: !OverlayHook
  , connectorStartTip :: !ArrowTip
  , connectorEndTip :: !ArrowTip
  , connectorLineJoin :: !LineJoin
  }
  deriving stock (Eq, Ord, Show)

defaultConnectorProperties :: RoleId -> ConnectorProperties
defaultConnectorProperties role =
  ConnectorProperties
    { connectorPaint = NoPaint
    , connectorStroke =
        SolidStroke (PaletteColour "ink") (canvasUnit (1 / 100))
    , connectorDash = SolidDash
    , connectorOpacity = opaqueOpacity
    , connectorRotation = noRotation
    , connectorSizing = ContentSized
    , connectorTypography = defaultTypography
    , connectorRole = role
    , connectorOverlay = AlwaysVisible
    , connectorStartTip = NoArrowTip
    , connectorEndTip = NamedArrowTip "stealth"
    , connectorLineJoin = MiterJoin
    }

applyConnectorPropertyPatch ::
  ConnectorProperties ->
  ConnectorPropertyPatch ->
  ConnectorProperties
applyConnectorPropertyPatch base patch =
  ConnectorProperties
    { connectorPaint =
        maybe (connectorPaint base) id (connectorPatchPaint patch)
    , connectorStroke =
        maybe (connectorStroke base) id (connectorPatchStroke patch)
    , connectorDash =
        maybe (connectorDash base) id (connectorPatchDash patch)
    , connectorOpacity =
        maybe (connectorOpacity base) id (connectorPatchOpacity patch)
    , connectorRotation =
        maybe (connectorRotation base) id (connectorPatchRotation patch)
    , connectorSizing =
        maybe (connectorSizing base) id (connectorPatchSizing patch)
    , connectorTypography =
        maybe (connectorTypography base) id (connectorPatchTypography patch)
    , connectorRole =
        maybe (connectorRole base) id (connectorPatchRole patch)
    , connectorOverlay =
        maybe (connectorOverlay base) id (connectorPatchOverlay patch)
    , connectorStartTip =
        maybe (connectorStartTip base) id (connectorPatchStartTip patch)
    , connectorEndTip =
        maybe (connectorEndTip base) id (connectorPatchEndTip patch)
    , connectorLineJoin =
        maybe (connectorLineJoin base) id (connectorPatchLineJoin patch)
    }

prefer :: Maybe value -> Maybe value -> Maybe value
prefer higher lower =
  case higher of
    Just value -> Just value
    Nothing -> lower
