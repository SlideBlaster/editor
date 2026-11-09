{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Laws for session/1 content lowering (canvas content to plan content).
module Main (main) where

import SlideBlaster.Canvas hiding (Theme (..), Furniture (..))
import SlideBlaster.Product.Runtime.SlidePlan
import SlideBlaster.Product.Runtime.Theme
import SlideBlaster.Product.Runtime.Lower
  ( FigureInfo (..)
  , contentStepCount
  , lowerContent
  )

import Control.Monad (unless)
import Data.Aeson (Value, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Key qualified as Key
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as Encoding
import Numeric.Natural (Natural)
import System.Exit (exitFailure)

main :: IO ()
main = do
  run "text, marks and line breaks lower to the closed tree" marks
  run "lists keep order and nesting" lists
  run "math lowers opaque TeX with display flag" mathLaw
  run "pauses hide later content as reserved geometry" pauses
  run "overlay hooks reserve hidden content" hooks
  run "\\only drops hidden content instead of reserving it" onlyHooks
  run "step count covers pauses and hooks" stepCounts
  run "figures lower to figure or placeholder by state" figures
  run "images embed their bytes or show an error placeholder" images
  run "unsupported content is labelled, never dropped" unsupported
  run "plan places title and body in y-down theme regions" planRegions
  run "plan furniture follows first/not-first rules" planFurniture
  run "theme.json overrides the built-in theme" themeParse
  run "progress furniture and the {{section}} template follow the context" progressBar

run :: String -> IO () -> IO ()
run name check = check >> putStrLn ("PASS: " <> name)

expect :: String -> Value -> Value -> IO ()
expect label expected actual =
  unless (expected == actual) $ do
    putStrLn ("FAIL: " <> label)
    putStrLn ("  expected: " <> show (Aeson.encode expected))
    putStrLn ("  actual:   " <> show (Aeson.encode actual))
    exitFailure

prov :: Provenance
prov = CanvasProvenance Markdown

txt :: Text -> ContentNode
txt = TextRun prov

step :: Natural -> OverlayStep
step n = fromMaybe firstOverlayStep (mkOverlayStep n)


lowerAt :: Natural -> [ContentNode] -> [Value]
lowerAt n = lowerContent (step n) (const FigureUnknown)

textValue :: Text -> Value
textValue t = object ["t" .= ("text" :: Text), "text" .= t, "bold" .= False, "italic" .= False, "mono" .= False, "color" .= Aeson.Null]

marks :: IO ()
marks = do
  expect "plain" (Aeson.toJSON [textValue "hi"]) (Aeson.toJSON (lowerAt 1 [txt "hi"]))
  expect
    "strong"
    (Aeson.toJSON [object ["t" .= ("strong" :: Text), "children" .= [textValue "x"]]])
    (Aeson.toJSON (lowerAt 1 [StyledRun prov (Strong :| []) [txt "x"]]))
  expect
    "line break"
    (Aeson.toJSON [object ["t" .= ("br" :: Text)]])
    (Aeson.toJSON (lowerAt 1 [LineBreak prov]))

lists :: IO ()
lists = do
  let item body = ContentItem prov body AlwaysVisible
      lowered =
        lowerAt 1 [ListContent prov UnorderedList (item [txt "a"] :| [item [txt "b"]])]
  expect
    "ul"
    ( Aeson.toJSON
        [ object
            [ "t" .= ("ul" :: Text)
            , "children"
                .= [ object ["t" .= ("li" :: Text), "children" .= [textValue "a"]]
                   , object ["t" .= ("li" :: Text), "children" .= [textValue "b"]]
                   ]
            ]
        ]
    )
    (Aeson.toJSON lowered)

mathLaw :: IO ()
mathLaw =
  expect
    "display math"
    ( Aeson.toJSON
        [ object
            [ "t" .= ("math" :: Text)
            , "display" .= True
            , "tex" .= ("x^2" :: Text)
            , "label" .= ("x^2" :: Text)
            ]
        ]
    )
    (Aeson.toJSON (lowerAt 1 [OpaqueMath prov DisplayMath "x^2"]))

pauses :: IO ()
pauses = do
  let nodes = [txt "a", OverlayPauseContent prov PauseNext, txt "b"]
      reserved v = object ["t" .= ("reserved" :: Text), "children" .= [v]]
  expect "step 1 hides b" (Aeson.toJSON [textValue "a", reserved (textValue "b")]) (Aeson.toJSON (lowerAt 1 nodes))
  expect "step 2 shows b" (Aeson.toJSON [textValue "a", textValue "b"]) (Aeson.toJSON (lowerAt 2 nodes))

hooks :: IO ()
hooks = do
  let hook = VisibleDuring (singleStep (step 2) :| [])
      nodes = [OverlayContent hook [txt "x"]]
  expect
    "hidden at 1"
    (Aeson.toJSON [object ["t" .= ("reserved" :: Text), "children" .= [textValue "x"]]])
    (Aeson.toJSON (lowerAt 1 nodes))
  expect "visible at 2" (Aeson.toJSON [textValue "x"]) (Aeson.toJSON (lowerAt 2 nodes))

onlyHooks :: IO ()
onlyHooks = do
  let hook = VisibleDuring (singleStep (step 2) :| [])
      nodes = [OverlayContent hook [TransparentContainer prov (GenericContainer "only") [txt "x"]], txt "y"]
  expect "hidden at 1 takes no space" (Aeson.toJSON [textValue "y"]) (Aeson.toJSON (lowerAt 1 nodes))
  expect "visible at 2, unwrapped" (Aeson.toJSON [textValue "x", textValue "y"]) (Aeson.toJSON (lowerAt 2 nodes))

stepCounts :: IO ()
stepCounts = do
  let hook = VisibleDuring (stepsFrom (step 3) :| [])
  expect "none" (Aeson.toJSON (1 :: Int)) (Aeson.toJSON (contentStepCount (content [txt "a"])))
  expect "two pauses" (Aeson.toJSON (3 :: Int)) (Aeson.toJSON (contentStepCount (content [OverlayPauseContent prov PauseNext, OverlayPauseContent prov PauseNext])))
  expect "hook" (Aeson.toJSON (3 :: Int)) (Aeson.toJSON (contentStepCount (content [OverlayContent hook [txt "x"]])))

figures :: IO ()
figures = do
  ref <- needRef "fig-1"
  let node = CompiledFigureContent prov ref DerivedLoading
      go info = lowerContent firstOverlayStep (const info) [node]
  expect "unknown is pending" (Aeson.toJSON [placeholderV "pending" "" "Figure"]) (Aeson.toJSON (go FigureUnknown))
  expect "absent" (Aeson.toJSON [placeholderV "absent" "abc" "no tex"]) (Aeson.toJSON (go (FigureAbsent "abc" "no tex")))
  expect "ready" (Aeson.toJSON [figureV "abc" 10 5]) (Aeson.toJSON (go (FigureReady "abc" 10 5)))
  expect "pending" (Aeson.toJSON [placeholderV "pending" "abc" "Compiling figure"]) (Aeson.toJSON (go (FigurePending "abc")))
  expect "failed" (Aeson.toJSON [placeholderV "error" "abc" "boom"]) (Aeson.toJSON (go (FigureFailed "abc" "boom")))
  where
    figureV fp w h = object ["t" .= ("figure" :: Text), "fingerprint" .= (fp :: Text), "width" .= (w :: Double), "height" .= (h :: Double)]
    placeholderV st fp msg = object ["t" .= ("placeholder" :: Text), "state" .= (st :: Text), "fingerprint" .= (fp :: Text), "label" .= (msg :: Text)]

images :: IO ()
images = do
  asset <- maybe (putStrLn "FAIL: bad asset" >> exitFailure) pure (assetId "img-1")
  let go info = lowerContent firstOverlayStep (const info) [ImageContent prov asset "Churn"]
  expect
    "image embeds"
    (Aeson.toJSON [object ["t" .= ("image" :: Text), "src" .= ("img-1" :: Text), "alt" .= ("Churn" :: Text), "mime" .= ("image/svg+xml" :: Text), "bytesBase16" .= ("3c73" :: Text), "width" .= (800 :: Double), "height" .= (320 :: Double)]])
    (Aeson.toJSON (go (FigureImage "image/svg+xml" "3c73" 800 320)))
  expect
    "missing file is an error placeholder"
    (Aeson.toJSON [object ["t" .= ("placeholder" :: Text), "state" .= ("error" :: Text), "fingerprint" .= ("" :: Text), "label" .= ("image file is missing: x.png" :: Text)]])
    (Aeson.toJSON (go (FigureFailed "" "image file is missing: x.png")))

unsupported :: IO ()
unsupported = do
  ref <- needRef "u1"
  let node = UnsupportedContent (SourceBackedContent ref Markdown UnsupportedSyntax)
  expect
    "labelled"
    (Aeson.toJSON [object ["t" .= ("unsupported" :: Text), "label" .= ("unsupported content" :: Text)]])
    (Aeson.toJSON (lowerAt 1 [node]))

needRef :: Text -> IO SourceRef
needRef name = maybe (putStrLn "FAIL: bad ref" >> exitFailure) pure (sourceRef name)

ctx :: Int -> Int -> PlanContext
ctx page step' =
  PlanContext
    { planSession = 1, planRevision = 2, planTicket = 3, planPage = page, planPages = 3
    , planDeckTitle = "Deck", planSection = "", planProgress = Nothing, planSectionProgress = Nothing, planStep = step', planSurface = "audience"
    , planFigures = const FigureUnknown, planAsset = const Nothing, planArtifacts = Map.empty }

frame :: FrameInput
frame = FrameInput "s1" (content [txt "Title"]) (content [txt "Body", OverlayPauseContent prov PauseNext, txt "More"]) Nothing [] [] (content [])

field :: Text -> Value -> Value
field k (Aeson.Object o) = fromMaybe Aeson.Null (KeyMap.lookup (Key.fromText k) o)
field _ _ = Aeson.Null

items :: Value -> [Value]
items v = case field "items" v of
  Aeson.Array a -> foldr (:) [] a
  _ -> []

planRegions :: IO ()
planRegions = do
  let plan = buildPlan builtinTheme (ctx 2 1) frame
      kinds = fmap (field "kind") (items plan)
  expect "kinds" (Aeson.toJSON (["rect", "text", "text", "text", "flow"] :: [Text])) (Aeson.toJSON kinds)
  expect "steps" (Aeson.toJSON (2 :: Int)) (field "steps" plan)
  expect "size" (object ["width" .= (1280 :: Int), "height" .= (720 :: Int)]) (field "size" plan)
  -- title region y=7.35,h=1.15 in a 9-unit slide: top = (9-7.35-1.15)*80 = 40
  case filter ((== Aeson.String "title") . field "id") (items plan) of
    [titleItem] -> expect "title box" (object ["x" .= (72 :: Int), "y" .= (40 :: Int), "width" .= (1136 :: Int), "height" .= (92 :: Int)]) (field "box" titleItem)
    _ -> putStrLn "FAIL: no title item" >> exitFailure
  case filter ((== Aeson.String "body") . field "id") (items plan) of
    [bodyItem] -> expect "body hides step 2" (Aeson.toJSON (2 :: Int)) (Aeson.toJSON (length (case field "content" bodyItem of Aeson.Array a -> foldr (:) [] a; _ -> [])))
    _ -> putStrLn "FAIL: no body item" >> exitFailure

planFurniture :: IO ()
planFurniture = do
  let firstKinds = fmap (field "kind") (items (buildPlan builtinTheme (ctx 1 1) frame))
  expect "first slide has only the rule plus title and body" (Aeson.toJSON (["rect", "text", "flow"] :: [Text])) (Aeson.toJSON firstKinds)

themeParse :: IO ()
themeParse =
  case parseTheme (Encoding.encodeUtf8 "{\"name\":\"x\",\"aspect\":[4,3],\"palette\":{\"accent\":\"#111111\",\"block\":{\"bg\":\"#222222\"}},\"regions\":{\"body\":{\"x\":1,\"y\":1,\"w\":2,\"h\":3}}}") of
    Left problem -> putStrLn ("FAIL: " <> show problem) >> exitFailure
    Right theme -> do
      expect "name" (Aeson.toJSON ("x" :: Text)) (Aeson.toJSON (themeName theme))
      expect "size" (Aeson.toJSON (960 :: Double, 720 :: Double)) (Aeson.toJSON (themePlanSize theme))
      expect "nested palette" (Aeson.toJSON ("#222222" :: Text)) (Aeson.toJSON (paletteColour theme "block.bg"))
      expect "regions merge" (Aeson.toJSON (80 :: Double, 400 :: Double, 160 :: Double, 240 :: Double)) (Aeson.toJSON (regionBox theme (regionFor theme "body")))
  where
    regionFor theme key = fromMaybe (Region 0 0 0 0 "") (lookupRegion key theme)
    lookupRegion key theme = Map.lookup key (themeRegions theme)

progressBar :: IO ()
progressBar =
  case parseTheme (Encoding.encodeUtf8 "{\"furniture\":[{\"kind\":\"progress\",\"x\":0,\"y\":0,\"w\":10,\"h\":0.1},{\"kind\":\"footer-text\",\"x\":0,\"y\":1,\"w\":5,\"h\":0.5,\"text\":\"{{section}}!\"}]}") of
    Left problem -> putStrLn ("FAIL: " <> show problem) >> exitFailure
    Right theme -> do
      let context = (ctx 2 1) {planProgress = Just 0.25, planSection = "Part A"}
          plan = buildPlan theme context frame
          boxWidth item = field "width" (field "box" item)
      expect "track then fill" (Aeson.toJSON ([800, 200] :: [Int])) (Aeson.toJSON [n | item <- items plan, Aeson.String k <- [field "id" item], k `elem` ["furniture-0-track", "furniture-0-fill"], Aeson.Number x <- [boxWidth item], let n = round x :: Int])
      expect "section template" (Aeson.toJSON (["Part A!"] :: [Text])) (Aeson.toJSON (concat [[t | Aeson.String t <- [field "text" c]] | item <- items plan, field "id" item == Aeson.String "furniture-1", Aeson.Array cs <- [field "content" item], c <- foldr (:) [] cs]))
      expect "no progress without a position" (Aeson.toJSON (0 :: Int)) (Aeson.toJSON (length [() | item <- items (buildPlan theme (ctx 2 1) frame), Aeson.String k <- [field "id" item], k == "furniture-0-fill"]))
