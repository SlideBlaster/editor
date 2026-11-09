-- |
-- Module      : SlideBlaster.Canvas.Geometry
-- Description : Exact target-neutral slide units and geometry.
--
-- Geometry is expressed in exact rational slide units with a y-up coordinate
-- system. Sizes and relative fractions are validated at construction; resolved
-- boxes are derived values and never persistence authority.
module SlideBlaster.Canvas.Geometry
  ( CanvasUnit
  , canvasUnit
  , canvasUnitFromInteger
  , canvasUnitValue
  , addUnits
  , subtractUnits
  , scaleUnit
  , absoluteUnit
  , Point
  , point
  , pointX
  , pointY
  , translatePoint
  , Vector
  , vector
  , vectorX
  , vectorY
  , Size
  , GeometryError (..)
  , mkSize
  , sizeWidth
  , sizeHeight
  , Box
  , box
  , boxCenter
  , boxSize
  , boxLeft
  , boxRight
  , boxBottom
  , boxTop
  , boxesOverlapX
  , boxesOverlapY
  , BorderPort (..)
  , pointAtPort
  , Axis (..)
  , Fraction
  , mkFraction
  , fractionValue
  , zeroFraction
  , RelativePoint
  , mkRelativePoint
  , relativePointX
  , relativePointY
  , resolveRelativePoint
  , RelativeRect
  , mkRelativeRect
  , relativeRectLeft
  , relativeRectBottom
  , relativeRectWidth
  , relativeRectHeight
  ) where

-- | An exact distance or coordinate in target-independent slide units.
newtype CanvasUnit = CanvasUnit Rational
  deriving stock (Eq, Ord, Show)

canvasUnit :: Rational -> CanvasUnit
canvasUnit = CanvasUnit

canvasUnitFromInteger :: Integer -> CanvasUnit
canvasUnitFromInteger = CanvasUnit . fromInteger

canvasUnitValue :: CanvasUnit -> Rational
canvasUnitValue (CanvasUnit value) = value

addUnits :: CanvasUnit -> CanvasUnit -> CanvasUnit
addUnits (CanvasUnit left) (CanvasUnit right) = CanvasUnit (left + right)

subtractUnits :: CanvasUnit -> CanvasUnit -> CanvasUnit
subtractUnits (CanvasUnit left) (CanvasUnit right) = CanvasUnit (left - right)

scaleUnit :: Rational -> CanvasUnit -> CanvasUnit
scaleUnit factor (CanvasUnit value) = CanvasUnit (factor * value)

absoluteUnit :: CanvasUnit -> CanvasUnit
absoluteUnit (CanvasUnit value) = CanvasUnit (abs value)

-- | A point in the slide's y-up coordinate system.
data Point = Point !CanvasUnit !CanvasUnit
  deriving stock (Eq, Ord, Show)

point :: CanvasUnit -> CanvasUnit -> Point
point = Point

pointX :: Point -> CanvasUnit
pointX (Point x _) = x

pointY :: Point -> CanvasUnit
pointY (Point _ y) = y

translatePoint :: Vector -> Point -> Point
translatePoint (Vector dx dy) (Point x y) =
  Point (addUnits x dx) (addUnits y dy)

-- | A directed displacement in slide units.
data Vector = Vector !CanvasUnit !CanvasUnit
  deriving stock (Eq, Ord, Show)

vector :: CanvasUnit -> CanvasUnit -> Vector
vector = Vector

vectorX :: Vector -> CanvasUnit
vectorX (Vector x _) = x

vectorY :: Vector -> CanvasUnit
vectorY (Vector _ y) = y

-- | Failure to construct validated geometry.
data GeometryError
  = NonPositiveWidth !CanvasUnit
  | NonPositiveHeight !CanvasUnit
  | InvalidRelativeRectangle
  deriving stock (Eq, Show)

-- | A strictly positive full width and height.
data Size = Size !CanvasUnit !CanvasUnit
  deriving stock (Eq, Ord, Show)

mkSize :: CanvasUnit -> CanvasUnit -> Either GeometryError Size
mkSize width height
  | width <= canvasUnitFromInteger 0 = Left (NonPositiveWidth width)
  | height <= canvasUnitFromInteger 0 = Left (NonPositiveHeight height)
  | otherwise = Right (Size width height)

sizeWidth :: Size -> CanvasUnit
sizeWidth (Size width _) = width

sizeHeight :: Size -> CanvasUnit
sizeHeight (Size _ height) = height

-- | A resolved axis-aligned box represented by centre and full size.
data Box = Box !Point !Size
  deriving stock (Eq, Ord, Show)

box :: Point -> Size -> Box
box = Box

boxCenter :: Box -> Point
boxCenter (Box center _) = center

boxSize :: Box -> Size
boxSize (Box _ sizeValue) = sizeValue

boxLeft :: Box -> CanvasUnit
boxLeft value =
  subtractUnits
    (pointX (boxCenter value))
    (scaleUnit (1 / 2) (sizeWidth (boxSize value)))

boxRight :: Box -> CanvasUnit
boxRight value =
  addUnits
    (pointX (boxCenter value))
    (scaleUnit (1 / 2) (sizeWidth (boxSize value)))

boxBottom :: Box -> CanvasUnit
boxBottom value =
  subtractUnits
    (pointY (boxCenter value))
    (scaleUnit (1 / 2) (sizeHeight (boxSize value)))

boxTop :: Box -> CanvasUnit
boxTop value =
  addUnits
    (pointY (boxCenter value))
    (scaleUnit (1 / 2) (sizeHeight (boxSize value)))

boxesOverlapX :: Box -> Box -> Bool
boxesOverlapX left right =
  boxLeft left < boxRight right && boxRight left > boxLeft right

boxesOverlapY :: Box -> Box -> Bool
boxesOverlapY left right =
  boxBottom left < boxTop right && boxTop left > boxBottom right

-- | Named border and centre anchors shared by placement and connectors.
data BorderPort
  = North
  | NorthEast
  | East
  | SouthEast
  | South
  | SouthWest
  | West
  | NorthWest
  | Centre
  deriving stock (Eq, Ord, Show, Enum, Bounded)

pointAtPort :: BorderPort -> Box -> Point
pointAtPort port value =
  case port of
    North -> point centerX top
    NorthEast -> point right top
    East -> point right centerY
    SouthEast -> point right bottom
    South -> point centerX bottom
    SouthWest -> point left bottom
    West -> point left centerY
    NorthWest -> point left top
    Centre -> boxCenter value
  where
    centerX = pointX (boxCenter value)
    centerY = pointY (boxCenter value)
    left = boxLeft value
    right = boxRight value
    bottom = boxBottom value
    top = boxTop value

-- | One independent slide coordinate axis.
data Axis = HorizontalAxis | VerticalAxis
  deriving stock (Eq, Ord, Show)

-- | A closed unit interval value used by aspect-independent theme geometry.
newtype Fraction = Fraction Rational
  deriving stock (Eq, Ord, Show)

mkFraction :: Rational -> Maybe Fraction
mkFraction value
  | value >= 0 && value <= 1 = Just (Fraction value)
  | otherwise = Nothing

fractionValue :: Fraction -> Rational
fractionValue (Fraction value) = value

zeroFraction :: Fraction
zeroFraction = Fraction 0

-- | Aspect-independent point measured from the slide's top-left corner.
--
-- Relative theme data follows the editor convention: x grows right and y grows
-- down. 'resolveRelativePoint' performs the one explicit conversion into the
-- canvas' slide-space y-up coordinate system.
data RelativePoint = RelativePoint !Fraction !Fraction
  deriving stock (Eq, Ord, Show)

mkRelativePoint :: Fraction -> Fraction -> RelativePoint
mkRelativePoint = RelativePoint

relativePointX :: RelativePoint -> Fraction
relativePointX (RelativePoint x _) = x

relativePointY :: RelativePoint -> Fraction
relativePointY (RelativePoint _ y) = y

resolveRelativePoint :: Size -> RelativePoint -> Point
resolveRelativePoint slideSize (RelativePoint x y) =
  point
    (scaleUnit (fractionValue x) (sizeWidth slideSize))
    ( scaleUnit
        (1 - fractionValue y)
        (sizeHeight slideSize)
    )

-- | A rectangle relative to the current slide box.
data RelativeRect = RelativeRect !Fraction !Fraction !Fraction !Fraction
  deriving stock (Eq, Ord, Show)

mkRelativeRect ::
  Fraction ->
  Fraction ->
  Fraction ->
  Fraction ->
  Either GeometryError RelativeRect
mkRelativeRect left bottom width height
  | fractionValue width <= 0
      || fractionValue height <= 0
      || fractionValue left + fractionValue width > 1
      || fractionValue bottom + fractionValue height > 1 =
      Left InvalidRelativeRectangle
  | otherwise = Right (RelativeRect left bottom width height)

relativeRectLeft :: RelativeRect -> Fraction
relativeRectLeft (RelativeRect left _ _ _) = left

relativeRectBottom :: RelativeRect -> Fraction
relativeRectBottom (RelativeRect _ bottom _ _) = bottom

relativeRectWidth :: RelativeRect -> Fraction
relativeRectWidth (RelativeRect _ _ width _) = width

relativeRectHeight :: RelativeRect -> Fraction
relativeRectHeight (RelativeRect _ _ _ height) = height
