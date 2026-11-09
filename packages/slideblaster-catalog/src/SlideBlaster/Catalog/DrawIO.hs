{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Catalog.DrawIO
-- Description : Decoder for the versioned, attributed draw.io catalog snapshot.
--
-- The checked-in JSON is generated data. This module validates every identity,
-- size, and path command before the catalog becomes semantic input. The browser
-- may package the JSON as an asset and the native composition may read it with
-- ordinary filesystem APIs; neither target owns catalog meaning.
module SlideBlaster.Catalog.DrawIO
  ( CatalogSnapshotProvenance (..)
  , DrawIOCatalog
  , drawIOCatalogProvenance
  , drawIOCatalogAttribution
  , drawIOShapeCatalog
  , drawIOStencilLibrary
  , DrawIOCatalogError (..)
  , StencilPathError (..)
  , decodeDrawIOCatalog
  , decodeStencilPath
  ) where

import SlideBlaster.Canvas
  ( ArcSize (..)
  , ArcSweep (..)
  , ColourRef (PaletteColour)
  , OutlineGeometryError
  , OutlinePoint
  , OutlineRef (StencilGeometry)
  , PathCommand (..)
  , PathOutline
  , Stroke (SolidStroke)
  , canvasUnit
  , emptyContent
  , emptyNodePropertyPatch
  , mkPathOutline
  , mkArcRadii
  , mkSize
  , nodePatchStroke
  , outlinePoint
  , stencilId
  )
import SlideBlaster.Catalog.Model
  ( CatalogOrigin (ImportedDrawIOOrigin)
  , CatalogPriority (P2Catalog)
  , ShapePreset (..)
  , ShapeAttribution (..)
  , ShapeCatalog
  , ShapeCatalogError
  , StencilAspectPolicy (..)
  , StencilDefinition (..)
  , StencilGeometryData (StencilPath)
  , StencilLibrary
  , StencilLibraryError
  , catalogFamily
  , mkShapeCatalog
  , mkStencilLibrary
  , shapeId
  )

import Data.Aeson
  ( FromJSON (parseJSON)
  , eitherDecodeStrict'
  , withObject
  , (.:)
  )
import Data.ByteString (ByteString)
import Data.Char (isControl)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead

data CatalogSnapshotProvenance = CatalogSnapshotProvenance
  { snapshotMigrationSource :: !Text
  , snapshotDefinitionsCommit :: !Text
  , snapshotGeometryCommit :: !Text
  , snapshotDefinitionsSha256 :: !Text
  , snapshotGeometrySha256 :: !Text
  , snapshotDrawIORepository :: !Text
  , snapshotDrawIOUpstreamCommit :: !(Maybe Text)
  , snapshotUpstreamCommitStatus :: !Text
  }
  deriving stock (Eq, Show)

data DrawIOCatalog = DrawIOCatalog
  { drawIOCatalogProvenance :: !CatalogSnapshotProvenance
  , drawIOCatalogAttribution :: !ShapeAttribution
  , drawIOShapeCatalog :: !ShapeCatalog
  , drawIOStencilLibrary :: !StencilLibrary
  }
  deriving stock (Eq, Show)

data DrawIOCatalogError
  = DrawIOCatalogJsonInvalid !Text
  | UnsupportedCatalogSchemaVersion !Int
  | InvalidDrawIOProvenance !Text
  | InvalidDrawIOAttribution !Text
  | EmptyDrawIOCatalog
  | InvalidDrawIOShapeId !Text
  | InvalidDrawIOStencilId !Text
  | InvalidDrawIOShapeLabel !Text
  | InvalidDrawIOCategory !Text !Text
  | InvalidDrawIOShapeSize !Text
  | InvalidDrawIOFamily !Text !Text
  | InvalidDrawIOAspect !Text !Text
  | InvalidDrawIOPath !Text !StencilPathError
  | InvalidDrawIOShapeCatalog !ShapeCatalogError
  | InvalidDrawIOStencilLibrary !StencilLibraryError
  deriving stock (Eq, Show)

data StencilPathError
  = EmptyStencilPath
  | UnknownStencilPathCommand !Text
  | MissingStencilPathOperands !Text !Int
  | InvalidStencilPathNumber !Text
  | InvalidStencilArcFlag !Text
  | InvalidStencilArcRadius !Rational !Rational
  | InvalidStencilPathStructure !OutlineGeometryError
  deriving stock (Eq, Show)

data SnapshotWire = SnapshotWire
  !Int
  !CatalogSnapshotProvenance
  !AttributionWire
  ![ShapeWire]

data AttributionWire = AttributionWire !Text !Text !Text !Text

data ShapeWire = ShapeWire
  !Text
  !Text
  !Text
  ![Text]
  !Scientific
  !Scientific
  !Text
  !Text

instance FromJSON SnapshotWire where
  parseJSON =
    withObject "draw.io catalog snapshot" $ \value ->
      SnapshotWire
        <$> value .: "schemaVersion"
        <*> value .: "provenance"
        <*> value .: "attribution"
        <*> value .: "shapes"

instance FromJSON CatalogSnapshotProvenance where
  parseJSON =
    withObject "catalog provenance" $ \value ->
      CatalogSnapshotProvenance
        <$> value .: "migrationSource"
        <*> value .: "definitionsCommit"
        <*> value .: "geometryCommit"
        <*> value .: "definitionsSha256"
        <*> value .: "geometrySha256"
        <*> value .: "drawioRepository"
        <*> value .: "drawioUpstreamCommit"
        <*> value .: "upstreamCommitStatus"

instance FromJSON AttributionWire where
  parseJSON =
    withObject "shape attribution" $ \value ->
      AttributionWire
        <$> value .: "title"
        <*> value .: "author"
        <*> value .: "license"
        <*> value .: "source"

instance FromJSON ShapeWire where
  parseJSON =
    withObject "draw.io shape" $ \value -> do
      sizeValue <- value .: "size"
      ShapeWire
        <$> value .: "id"
        <*> value .: "label"
        <*> value .: "category"
        <*> value .: "keywords"
        <*> sizeValue .: "width"
        <*> sizeValue .: "height"
        <*> value .: "aspect"
        <*> value .: "path"

decodeDrawIOCatalog :: ByteString -> Either DrawIOCatalogError DrawIOCatalog
decodeDrawIOCatalog bytes = do
  SnapshotWire version provenance attributionWire rows <-
    mapLeft
      (DrawIOCatalogJsonInvalid . Text.pack)
      (eitherDecodeStrict' bytes)
  if version == 1
    then pure ()
    else Left (UnsupportedCatalogSchemaVersion version)
  let attribution = attributionFromWire attributionWire
  validateProvenance provenance
  validateAttribution attribution
  converted <- traverse (convertRow attribution) rows
  pairs <-
    case NonEmpty.nonEmpty converted of
      Nothing -> Left EmptyDrawIOCatalog
      Just values -> Right values
  catalog <-
    mapLeft
      InvalidDrawIOShapeCatalog
      (mkShapeCatalog (fmap fst pairs))
  library <-
    mapLeft
      InvalidDrawIOStencilLibrary
      (mkStencilLibrary (fmap snd (NonEmpty.toList pairs)))
  Right
    DrawIOCatalog
      { drawIOCatalogProvenance = provenance
      , drawIOCatalogAttribution = attribution
      , drawIOShapeCatalog = catalog
      , drawIOStencilLibrary = library
      }

convertRow
  :: ShapeAttribution
  -> ShapeWire
  -> Either DrawIOCatalogError (ShapePreset, StencilDefinition)
convertRow
  attribution
  (ShapeWire rawId label category keywords width height aspect rawPath) = do
    if validDisplayText label
      then Right ()
      else Left (InvalidDrawIOShapeLabel rawId)
    if validCategory category
      then Right ()
      else Left (InvalidDrawIOCategory rawId category)
    shapeIdentity <-
      maybe
        (Left (InvalidDrawIOShapeId rawId))
        Right
        (shapeId rawId)
    stencilIdentity <-
      maybe
        (Left (InvalidDrawIOStencilId rawId))
        Right
        (stencilId rawId)
    dropSize <-
      mapLeft
        (const (InvalidDrawIOShapeSize rawId))
        (mkSize (canvasUnit (toRational width)) (canvasUnit (toRational height)))
    family <-
      maybe
        (Left (InvalidDrawIOFamily rawId category))
        Right
        (catalogFamily (categoryFamily category))
    aspectPolicy <-
      case Text.toCaseFold aspect of
        "fixed" -> Right PreserveStencilAspect
        "variable" -> Right StretchStencil
        _ -> Left (InvalidDrawIOAspect rawId aspect)
    path <-
      mapLeft
        (InvalidDrawIOPath rawId)
        (decodeStencilPath rawPath)
    let preset =
          ShapePreset
            { shapePresetIdentifier = shapeIdentity
            , shapePresetLabel = label
            , shapePresetCategory = category
            , shapePresetKeywords = keywords
            , shapePresetFamily = family
            , shapePresetPriority = P2Catalog
            , shapePresetOrigin = ImportedDrawIOOrigin attribution
            , shapePresetOutline = StencilGeometry stencilIdentity
            , shapePresetProperties =
                emptyNodePropertyPatch
                  { nodePatchStroke =
                      Just
                        ( SolidStroke
                            (PaletteColour "ink")
                            (canvasUnit (1 / 100))
                        )
                  }
            , shapePresetDropSize = dropSize
            , shapePresetContent = emptyContent
            }
        stencil =
          StencilDefinition
            { stencilDefinitionId = stencilIdentity
            , stencilDefinitionLabel = label
            , stencilDefinitionCategory = category
            , stencilDefinitionKeywords = keywords
            , stencilDefinitionAspect = aspectPolicy
            , stencilDefinitionGeometry = StencilPath path
            , stencilDefinitionAttribution = attribution
            }
    Right
      ( preset
      , stencil
      )

-- | Decode the generated SVG command subset and normalize its @[0,1]@ y-down
-- coordinates into the canvas outline plane @[-1,1]@ y-up.
decodeStencilPath :: Text -> Either StencilPathError PathOutline
decodeStencilPath source = do
  parsed <- parseCommands (Text.words source)
  let commands = removeRepeatedClose parsed
  nonEmpty <-
    maybe (Left EmptyStencilPath) Right (NonEmpty.nonEmpty commands)
  mapLeft InvalidStencilPathStructure (mkPathOutline nonEmpty)

-- SVG permits redundant close-path commands. The canvas path contract stores
-- one semantic close per subpath, so normalize only this no-op spelling.
removeRepeatedClose :: [PathCommand] -> [PathCommand]
removeRepeatedClose commands =
  case commands of
    ClosePath : ClosePath : rest ->
      removeRepeatedClose (ClosePath : rest)
    command : rest ->
      command : removeRepeatedClose rest
    [] -> []

parseCommands :: [Text] -> Either StencilPathError [PathCommand]
parseCommands [] = Right []
parseCommands (command : remaining) =
  case command of
    "M" -> withPoint command MovePath remaining
    "L" -> withPoint command LinePath remaining
    "Q" -> do
      (control, afterControl) <- takePoint command 1 remaining
      (endpoint, rest) <- takePoint command 3 afterControl
      prepend (QuadraticPath control endpoint) rest
    "C" -> do
      (firstControl, afterFirst) <- takePoint command 1 remaining
      (secondControl, afterSecond) <- takePoint command 3 afterFirst
      (endpoint, rest) <- takePoint command 5 afterSecond
      prepend (CubicPath firstControl secondControl endpoint) rest
    "A" -> parseArc remaining
    "Z" -> prepend ClosePath remaining
    unknown -> Left (UnknownStencilPathCommand unknown)
  where
    withPoint label constructor tokens = do
      (value, rest) <- takePoint label 1 tokens
      prepend (constructor value) rest
    prepend value rest = (value :) <$> parseCommands rest

parseArc :: [Text] -> Either StencilPathError [PathCommand]
parseArc tokens = do
  (radiusX, afterRadiusX) <- takeNumber "A" 1 tokens
  (radiusY, afterRadiusY) <- takeNumber "A" 2 afterRadiusX
  (rotation, afterRotation) <- takeNumber "A" 3 afterRadiusY
  (largeToken, afterLarge) <- takeOperand "A" 4 afterRotation
  (sweepToken, afterSweep) <- takeOperand "A" 5 afterLarge
  large <- parseArcSize largeToken
  sweep <- parseArcSweep sweepToken
  (endpoint, rest) <- takePoint "A" 6 afterSweep
  command <-
    if radiusX < 0 || radiusY < 0
      then Left (InvalidStencilArcRadius radiusX radiusY)
      else
        if radiusX == 0 || radiusY == 0
          then Right (LinePath endpoint)
          else do
            radii <-
              mapLeft
                (const (InvalidStencilArcRadius radiusX radiusY))
                (mkArcRadii (2 * radiusX) (2 * radiusY))
            Right
              ( ArcPath
                  radii
                  (negate rotation)
                  large
                  sweep
                  endpoint
              )
  (command :) <$> parseCommands rest

takePoint
  :: Text
  -> Int
  -> [Text]
  -> Either StencilPathError (OutlinePoint, [Text])
takePoint label firstIndex tokens = do
  (x, afterX) <- takeNumber label firstIndex tokens
  (y, rest) <- takeNumber label (firstIndex + 1) afterX
  Right (normalizedPoint x y, rest)

takeNumber
  :: Text
  -> Int
  -> [Text]
  -> Either StencilPathError (Rational, [Text])
takeNumber label operandIndex tokens = do
  (token, rest) <- takeOperand label operandIndex tokens
  number <- parseNumber token
  Right (number, rest)

takeOperand
  :: Text
  -> Int
  -> [Text]
  -> Either StencilPathError (Text, [Text])
takeOperand label operandIndex tokens =
  case tokens of
    [] -> Left (MissingStencilPathOperands label operandIndex)
    token : rest -> Right (token, rest)

parseNumber :: Text -> Either StencilPathError Rational
parseNumber token =
  case TextRead.rational token of
    Right (number, remainder)
      | Text.null remainder -> Right number
    _ -> Left (InvalidStencilPathNumber token)

parseArcSize :: Text -> Either StencilPathError ArcSize
parseArcSize token =
  case token of
    "0" -> Right SmallArc
    "1" -> Right LargeArc
    _ -> Left (InvalidStencilArcFlag token)

-- SVG paths are y-down. Reflection into y-up reverses the sweep orientation.
parseArcSweep :: Text -> Either StencilPathError ArcSweep
parseArcSweep token =
  case token of
    "0" -> Right ClockwiseArc
    "1" -> Right CounterClockwiseArc
    _ -> Left (InvalidStencilArcFlag token)

normalizedPoint :: Rational -> Rational -> OutlinePoint
normalizedPoint x y = outlinePoint (2 * x - 1) (1 - 2 * y)

attributionFromWire :: AttributionWire -> ShapeAttribution
attributionFromWire (AttributionWire title author license source) =
  ShapeAttribution
    { attributionTitle = title
    , attributionAuthor = author
    , attributionLicense = license
    , attributionSource = source
    }

categoryFamily :: Text -> Text
categoryFamily =
  Text.strip . fst . Text.breakOn " / "

validateProvenance
  :: CatalogSnapshotProvenance
  -> Either DrawIOCatalogError ()
validateProvenance provenance
  | not (validDisplayText (snapshotMigrationSource provenance)) =
      Left (InvalidDrawIOProvenance "migrationSource")
  | not (validCommit (snapshotDefinitionsCommit provenance)) =
      Left (InvalidDrawIOProvenance "definitionsCommit")
  | not (validCommit (snapshotGeometryCommit provenance)) =
      Left (InvalidDrawIOProvenance "geometryCommit")
  | not (validSha256 (snapshotDefinitionsSha256 provenance)) =
      Left (InvalidDrawIOProvenance "definitionsSha256")
  | not (validSha256 (snapshotGeometrySha256 provenance)) =
      Left (InvalidDrawIOProvenance "geometrySha256")
  | not (validDisplayText (snapshotDrawIORepository provenance)) =
      Left (InvalidDrawIOProvenance "drawioRepository")
  | not (maybe True validCommit (snapshotDrawIOUpstreamCommit provenance)) =
      Left (InvalidDrawIOProvenance "drawioUpstreamCommit")
  | not (validDisplayText (snapshotUpstreamCommitStatus provenance)) =
      Left (InvalidDrawIOProvenance "upstreamCommitStatus")
  | otherwise = Right ()

validateAttribution :: ShapeAttribution -> Either DrawIOCatalogError ()
validateAttribution attribution
  | not (validDisplayText (attributionTitle attribution)) =
      Left (InvalidDrawIOAttribution "title")
  | not (validDisplayText (attributionAuthor attribution)) =
      Left (InvalidDrawIOAttribution "author")
  | not (validDisplayText (attributionLicense attribution)) =
      Left (InvalidDrawIOAttribution "license")
  | not (validDisplayText (attributionSource attribution)) =
      Left (InvalidDrawIOAttribution "source")
  | otherwise = Right ()

validCategory :: Text -> Bool
validCategory category =
  validDisplayText category
    && all validDisplayText (Text.splitOn " / " category)
    && not (Text.isInfixOf "/" (Text.replace " / " "" category))

validDisplayText :: Text -> Bool
validDisplayText value =
  not (Text.null (Text.strip value))
    && not (Text.any isControl value)

validCommit :: Text -> Bool
validCommit value =
  Text.length value == 40 && Text.all isLowerHex value

validSha256 :: Text -> Bool
validSha256 value =
  Text.length value == 64 && Text.all isLowerHex value

isLowerHex :: Char -> Bool
isLowerHex character =
  (character >= '0' && character <= '9')
    || (character >= 'a' && character <= 'f')

mapLeft :: (failure -> mapped) -> Either failure value -> Either mapped value
mapLeft transform value =
  case value of
    Left failure -> Left (transform failure)
    Right success -> Right success
