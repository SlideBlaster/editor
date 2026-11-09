{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Executable laws for the complete shape catalog slice.
module Main (main) where

import Paths_slideblaster_catalog (getDataFileName)
import SlideBlaster.Canvas
  ( ArcSize (LargeArc)
  , ArcSweep (CounterClockwiseArc)
  , NodeSeed (..)
  , OutlineGeometryError (..)
  , OutlineRef (StencilGeometry)
  , PathCommand (..)
  , Sizing (MinimumSize)
  , nodePatchSizing
  , mkArcRadii
  , outlinePoint
  , pathOutlineCommands
  )
import SlideBlaster.Catalog

import Control.Monad (forM_, unless)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import System.Exit (exitFailure)

main :: IO ()
main = do
  snapshot <- loadSnapshot
  run "complete 2,257-row draw.io snapshot decodes" (fullSnapshotLaw snapshot)
  run "the 15 native presets remain a separate parametric catalog" curatedLaw
  run "native and draw.io catalogs merge to 2,272 unique presets" (mergeLaw snapshot)
  run "lookup and search preserve stable catalog identity and order" (searchLaw snapshot)
  run "category and family grouping match the lazy palette contract" (groupingLaw snapshot)
  run "duplicate preset identities are rejected" duplicateCatalogLaw
  run "duplicate snapshot identities are rejected" duplicateSnapshotLaw
  run "qualified dotted identities decode and malformed segments fail" dottedIdentityLaw
  run "the complete generated path grammar normalizes exactly" pathGrammarLaw
  run "malformed path programs fail with typed causes" pathFailureLaw
  run "snapshot provenance is structurally validated" provenanceValidationLaw
  run "invalid sizes, families, and aspect policies fail closed" rowValidationLaw
  run "the packaged CC BY attribution remains present" attributionNoticeLaw

run :: String -> IO () -> IO ()
run name check = do
  check
  putStrLn ("PASS: " <> name)

loadSnapshot :: IO ByteString
loadSnapshot = do
  path <- getDataFileName "data/drawio/catalog-v1.json"
  ByteString.readFile path

decodeSnapshot :: ByteString -> IO DrawIOCatalog
decodeSnapshot bytes =
  requireRight "draw.io snapshot" (decodeDrawIOCatalog bytes)

fullSnapshotLaw :: ByteString -> IO ()
fullSnapshotLaw bytes = do
  decoded <- decodeSnapshot bytes
  let presets =
        NonEmpty.toList
          (catalogPresets (drawIOShapeCatalog decoded))
      stencils =
        stencilDefinitions (drawIOStencilLibrary decoded)
      provenance = drawIOCatalogProvenance decoded
  assertEqual "draw.io preset count" 2257 (length presets)
  assertEqual "stencil definition count" 2257 (length stencils)
  assertTrue
    "every imported preset is P2"
    (all ((== P2Catalog) . shapePresetPriority) presets)
  assertTrue
    "every imported preset carries draw.io attribution"
    (all isDrawIOOrigin presets)
  assertTrue
    "every imported preset resolves through a stencil"
    (all hasStencilOutline presets)
  assertEqual
    "definition source revision"
    "e67c13abbdaf00065b7337419dc8b9b99301d98e"
    (snapshotDefinitionsCommit provenance)
  assertEqual
    "geometry source revision"
    "3d9545017bbf682a73b9b364fe69b0c670c39fb3"
    (snapshotGeometryCommit provenance)
  assertEqual
    "definition source hash"
    "f3f3d0caf172c582c941449aa2a8635b37aa5bcf055a03dba69817915a47066b"
    (snapshotDefinitionsSha256 provenance)
  assertEqual
    "geometry source hash"
    "300c9b1f7fa864dda8b79395bacbdce5652fb5b38ec35e57e928249fbd189228"
    (snapshotGeometrySha256 provenance)
  assertEqual
    "unknown upstream commit stays explicit"
    Nothing
    (snapshotDrawIOUpstreamCommit provenance)
  where
    isDrawIOOrigin preset =
      case shapePresetOrigin preset of
        ImportedDrawIOOrigin _ -> True
        _ -> False
    hasStencilOutline preset =
      case shapePresetOutline preset of
        StencilGeometry _ -> True
        _ -> False

curatedLaw :: IO ()
curatedLaw = do
  catalog <- requireRight "curated catalog" curatedShapeCatalog
  let firstPreset :| _ = catalogPresets catalog
      presets = NonEmpty.toList (catalogPresets catalog)
      identities = fmap (shapeIdText . shapePresetIdentifier) presets
      seed = shapePresetNodeSeed firstPreset
  assertEqual "curated preset count" 15 (length presets)
  assertEqual
    "curated identity order"
    [ "rectangle"
    , "rounded-rectangle"
    , "square"
    , "ellipse"
    , "circle"
    , "diamond"
    , "triangle"
    , "trapezoid"
    , "parallelogram"
    , "hexagon"
    , "cylinder"
    , "flow-process"
    , "flow-decision"
    , "flow-terminator"
    , "flow-data"
    ]
    identities
  assertTrue
    "every native preset is P0"
    (all ((== P0Catalog) . shapePresetPriority) presets)
  assertTrue
    "every native preset has native origin"
    (all ((== CuratedCatalogOrigin) . shapePresetOrigin) presets)
  assertEqual
    "catalog insertion erases to generic outline"
    (shapePresetOutline firstPreset)
    (nodeSeedOutline seed)
  assertEqual
    "catalog insertion carries minimum sizing"
    (Just (MinimumSize (shapePresetDropSize firstPreset)))
    (nodePatchSizing (nodeSeedProperties seed))

mergeLaw :: ByteString -> IO ()
mergeLaw bytes = do
  drawIO <- decodeSnapshot bytes
  curated <- requireRight "curated catalog" curatedShapeCatalog
  combined <-
    requireRight
      "combined catalog"
      (mergeShapeCatalogs curated (drawIOShapeCatalog drawIO))
  assertEqual
    "combined preset count"
    2272
    (length (catalogPresets combined))
  forM_
    ["rectangle", "flow-decision", "abstract.amplifier", "waveforms.up-ramp"]
    (\rawId -> do
       identity <- requireJust "combined lookup id" (shapeId rawId)
       assertTrue
         ("combined lookup " <> show rawId)
         (case catalogPresetById identity combined of
            Just _ -> True
            Nothing -> False)
    )

searchLaw :: ByteString -> IO ()
searchLaw bytes = do
  decoded <- decodeSnapshot bytes
  let catalog = drawIOShapeCatalog decoded
      results = searchCatalog "BOOST" catalog
  amplifier <- requireJust "amplifier id" (shapeId "abstract.amplifier")
  ampSymbol <- requireJust "IEC amp id" (shapeId "iec417.amp")
  assertEqual
    "keyword search preserves snapshot order"
    [amplifier, ampSymbol]
    (fmap shapePresetIdentifier results)
  assertEqual
    "empty search returns all rows"
    2257
    (length (searchCatalog "   " catalog))
  assertEqual
    "category text alone is not an implicit keyword"
    []
    (searchCatalog "Electrical / Abstract" catalog)

groupingLaw :: ByteString -> IO ()
groupingLaw bytes = do
  drawIO <- decodeSnapshot bytes
  curated <- requireRight "curated catalog" curatedShapeCatalog
  combined <-
    requireRight
      "combined catalog"
      (mergeShapeCatalogs curated (drawIOShapeCatalog drawIO))
  general <- requireJust "General family" (catalogFamily "General")
  flowchart <- requireJust "Flowchart family" (catalogFamily "Flowchart")
  let sections = catalogSections combined
      families = catalogFamilies [general, flowchart] combined
  case sections of
    [] -> failTest "category sections are empty"
    firstSection : _ ->
      assertEqual "first category" "General" (fst firstSection)
  assertEqual
    "pinned family prefix"
    [general, flowchart]
    (take 2 (fmap fst families))
  assertEqual
    "every preset appears in one family"
    2272
    (sum (fmap (NonEmpty.length . snd) families))
  assertEqual "combined family count" 18 (length families)

duplicateCatalogLaw :: IO ()
duplicateCatalogLaw = do
  catalog <- requireRight "curated catalog" curatedShapeCatalog
  let firstPreset :| _ = catalogPresets catalog
  case mkShapeCatalog (firstPreset :| [firstPreset]) of
    Left (DuplicateCatalogShape duplicate) ->
      assertEqual
        "duplicate identity"
        (shapePresetIdentifier firstPreset)
        duplicate
    other -> failTest ("duplicate catalog result: " <> show other)

duplicateSnapshotLaw :: IO ()
duplicateSnapshotLaw =
  case decodeDrawIOCatalog (snapshotBytes [validRow "duplicate.id", validRow "duplicate.id"]) of
    Left (InvalidDrawIOShapeCatalog (DuplicateCatalogShape duplicate)) ->
      assertEqual
        "duplicate snapshot identity"
        "duplicate.id"
        (shapeIdText duplicate)
    other -> failTest ("duplicate snapshot result: " <> show other)

dottedIdentityLaw :: IO ()
dottedIdentityLaw = do
  decoded <-
    decodeSnapshot (snapshotBytes [validRow "advertising.3-1-rec"])
  identity <- requireJust "qualified shape id" (shapeId "advertising.3-1-rec")
  assertTrue
    "qualified dotted id is indexed"
    (case catalogPresetById identity (drawIOShapeCatalog decoded) of
       Just _ -> True
       Nothing -> False)
  forM_ [".leading", "trailing.", "empty..segment", "invalid.$segment"] $ \invalid ->
    case decodeDrawIOCatalog (snapshotBytes [validRow invalid]) of
      Left (InvalidDrawIOShapeId actual) ->
        assertEqual "invalid qualified id" invalid actual
      other -> failTest ("invalid dotted id result: " <> show other)

pathGrammarLaw :: IO ()
pathGrammarLaw = do
  arcRadii <- requireRight "reflected arc radii" (mkArcRadii (1 / 5) (2 / 5))
  path <-
    requireRight
      "complete path grammar"
      ( decodeStencilPath
          "M 0 0 L 1 1 Q 0.25 0.5 0.75 1 \
          \C 0 0.25 0.5 0.75 1 1 A 0.1 0.2 30 1 1 0.5 0.6 Z"
      )
  assertEqual
    "normalized commands"
    ( MovePath (outlinePoint (-1) 1)
        :| [ LinePath (outlinePoint 1 (-1))
           , QuadraticPath
               (outlinePoint (-1 / 2) 0)
               (outlinePoint (1 / 2) (-1))
           , CubicPath
               (outlinePoint (-1) (1 / 2))
               (outlinePoint 0 (-1 / 2))
               (outlinePoint 1 (-1))
           , ArcPath
               arcRadii
               (-30)
               LargeArc
               CounterClockwiseArc
               (outlinePoint 0 (-1 / 5))
           , ClosePath
           ]
    )
    (pathOutlineCommands path)
  degenerateArc <-
    requireRight
      "zero-radius SVG arc"
      (decodeStencilPath "M 0 0 A 0 0.2 0 0 1 1 1")
  assertEqual
    "zero-radius SVG arc becomes a line"
    (MovePath (outlinePoint (-1) 1) :| [LinePath (outlinePoint 1 (-1))])
    (pathOutlineCommands degenerateArc)
  redundantClose <-
    requireRight
      "redundant close"
      (decodeStencilPath "M 0 0 L 1 1 Z Z")
  assertEqual
    "redundant close is normalized"
    ( MovePath (outlinePoint (-1) 1)
        :| [LinePath (outlinePoint 1 (-1)), ClosePath]
    )
    (pathOutlineCommands redundantClose)

pathFailureLaw :: IO ()
pathFailureLaw = do
  assertLeft "empty path" EmptyStencilPath (decodeStencilPath "")
  assertLeft
    "unknown command"
    (UnknownStencilPathCommand "X")
    (decodeStencilPath "M 0 0 X 1 1")
  assertLeft
    "missing operand"
    (MissingStencilPathOperands "M" 2)
    (decodeStencilPath "M 0")
  assertLeft
    "invalid number"
    (InvalidStencilPathNumber "nope")
    (decodeStencilPath "M nope 0")
  assertLeft
    "invalid arc flag"
    (InvalidStencilArcFlag "2")
    (decodeStencilPath "M 0 0 A 1 1 0 2 0 1 1")
  assertLeft
    "negative arc radius"
    (InvalidStencilArcRadius (-1) 1)
    (decodeStencilPath "M 0 0 A -1 1 0 0 0 1 1")
  assertLeft
    "path must begin with move"
    (InvalidStencilPathStructure PathMustStartWithMove)
    (decodeStencilPath "L 1 1")
  assertLeft
    "empty close is rejected"
    (InvalidStencilPathStructure PathCloseWithoutDrawnSegment)
    (decodeStencilPath "M 0 0 Z")
  assertLeft
    "draw after close needs a new move"
    (InvalidStencilPathStructure PathCommandAfterCloseNeedsMove)
    (decodeStencilPath "M 0 0 L 1 1 Z L 0 0")

provenanceValidationLaw :: IO ()
provenanceValidationLaw =
  case
      decodeDrawIOCatalog
        (snapshotBytesWithDefinitionsHash "not-a-sha256" [validRow "valid.id"])
    of
    Left (InvalidDrawIOProvenance field) ->
      assertEqual "invalid provenance field" "definitionsSha256" field
    other -> failTest ("invalid provenance result: " <> show other)

rowValidationLaw :: IO ()
rowValidationLaw = do
  case decodeDrawIOCatalog (snapshotBytes [rowWith "valid.id" 0 1 "variable" "M 0 0 L 1 1"]) of
    Left (InvalidDrawIOShapeSize rawId) ->
      assertEqual "invalid size id" "valid.id" rawId
    other -> failTest ("invalid size result: " <> show other)
  case decodeDrawIOCatalog (snapshotBytes [rowInCategory "valid.id" " / Broken"]) of
    Left (InvalidDrawIOCategory rawId category) -> do
      assertEqual "invalid category id" "valid.id" rawId
      assertEqual "invalid category" " / Broken" category
    other -> failTest ("invalid category result: " <> show other)
  case decodeDrawIOCatalog (snapshotBytes [rowWith "valid.id" 1 1 "sometimes" "M 0 0 L 1 1"]) of
    Left (InvalidDrawIOAspect rawId aspect) -> do
      assertEqual "invalid aspect id" "valid.id" rawId
      assertEqual "invalid aspect" "sometimes" aspect
    other -> failTest ("invalid aspect result: " <> show other)

attributionNoticeLaw :: IO ()
attributionNoticeLaw = do
  snapshot <- decodeSnapshot =<< loadSnapshot
  assertEqual
    "catalog license"
    "CC BY 4.0"
    (attributionLicense (drawIOCatalogAttribution snapshot))
  noticePath <- getDataFileName "THIRD_PARTY_NOTICES.md"
  notice <- Text.Encoding.decodeUtf8 <$> ByteString.readFile noticePath
  assertTrue
    "notice names CC BY 4.0"
    ("CC BY 4.0" `Text.isInfixOf` notice)
  assertTrue
    "notice names JGraph"
    ("JGraph Ltd" `Text.isInfixOf` notice)

snapshotBytes :: [Value] -> ByteString
snapshotBytes =
  snapshotBytesWithDefinitionsHash (Text.replicate 64 "0")

snapshotBytesWithDefinitionsHash :: Text -> [Value] -> ByteString
snapshotBytesWithDefinitionsHash definitionsHash rows =
  LazyByteString.toStrict
    ( encode
        ( object
            [ "schemaVersion" .= (1 :: Int)
            , "provenance"
                .= object
                  [ "migrationSource" .= ("test fixture" :: Text)
                  , "definitionsCommit" .= Text.replicate 40 "0"
                  , "geometryCommit" .= Text.replicate 40 "0"
                  , "definitionsSha256" .= definitionsHash
                  , "geometrySha256" .= Text.replicate 64 "0"
                  , "drawioRepository" .= ("https://example.invalid" :: Text)
                  , "drawioUpstreamCommit" .= (Nothing :: Maybe Text)
                  , "upstreamCommitStatus" .= ("fixture" :: Text)
                  ]
            , "attribution"
                .= object
                  [ "title" .= ("Fixture" :: Text)
                  , "author" .= ("Fixture author" :: Text)
                  , "license" .= ("CC0" :: Text)
                  , "source" .= ("https://example.invalid" :: Text)
                  ]
            , "shapes" .= rows
            ]
        )
    )

validRow :: Text -> Value
validRow rawId =
  rowWith rawId 2 1 "variable" "M 0 0 L 1 1"

rowInCategory :: Text -> Text -> Value
rowInCategory rawId category =
  object
    [ "id" .= rawId
    , "label" .= ("Fixture" :: Text)
    , "category" .= category
    , "keywords" .= (["fixture"] :: [Text])
    , "size" .= object ["width" .= (2 :: Int), "height" .= (1 :: Int)]
    , "aspect" .= ("variable" :: Text)
    , "path" .= ("M 0 0 L 1 1" :: Text)
    ]

rowWith :: Text -> Int -> Int -> Text -> Text -> Value
rowWith rawId width height aspect path =
  object
    [ "id" .= rawId
    , "label" .= ("Fixture" :: Text)
    , "category" .= ("Tests / Fixture" :: Text)
    , "keywords" .= (["fixture"] :: [Text])
    , "size" .= object ["width" .= width, "height" .= height]
    , "aspect" .= aspect
    , "path" .= path
    ]

requireRight :: Show failure => String -> Either failure value -> IO value
requireRight label result =
  case result of
    Left failure -> failTest (label <> ": " <> show failure)
    Right value -> pure value

requireJust :: String -> Maybe value -> IO value
requireJust label result =
  case result of
    Nothing -> failTest (label <> ": missing value")
    Just value -> pure value

assertLeft
  :: (Eq failure, Show failure, Show value)
  => String
  -> failure
  -> Either failure value
  -> IO ()
assertLeft label expected actual =
  case actual of
    Left failure -> assertEqual label expected failure
    Right value -> failTest (label <> ": unexpected success " <> show value)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  unless
    (expected == actual)
    ( failTest
        ( label
            <> ": expected "
            <> show expected
            <> ", received "
            <> show actual
        )
    )

assertTrue :: String -> Bool -> IO ()
assertTrue label condition =
  unless condition (failTest label)

failTest :: String -> IO value
failTest message = do
  putStrLn ("FAIL: " <> message)
  exitFailure
