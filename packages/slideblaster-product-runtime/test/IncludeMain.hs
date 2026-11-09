{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Sub-presentations (@\\include@) spliced by the production analyzer.
module Main (main) where

import SlideBlaster.Canvas (identifierText)
import SlideBlaster.Deck.Include
import SlideBlaster.Presentation.Route qualified as Route
import SlideBlaster.Product.Runtime.Analysis
import SlideBlaster.Product.Runtime.MarkdownAnalyzer (markdownAnalyzer)
import SlideBlaster.Product.Runtime.Session
import SlideBlaster.Protocol.Session

import Control.Monad (unless)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import System.Exit (exitFailure)

bytes :: Text -> ByteString
bytes = Encoding.encodeUtf8

parent :: ByteString
parent =
  bytes
    "---\nslideblaster: 1\ntitle: Parent\nroutes:\n  main: [one, two]\n---\n\n\
    \## Opening {#opening}\n\nhello\n\n\
    \# One {#one}\n\n\\include[titleslide,dividers]{kid}\n\n## After {#after}\n\nx\n\n\
    \# Two {#two}\n\n\\include{../other/talk.slideBlaster.md}\n\n## Last {#last}\n\nx\n"

kid :: ByteString
kid =
  bytes
    "---\nslideblaster: 1\ntitle: Kid\n---\n\n\
    \## Same {#opening}\n\n\\figure{figures/a.tikz}\n\n\
    \# Inner {#inner}\n\n## Deep {#deep}\n\nx\n\n\\include{grand}\n"

grand :: ByteString
grand = bytes "---\nslideblaster: 1\ntitle: Grand\n---\n\n## G {#g}\n\nx\n"

other :: ByteString
other = bytes "---\nslideblaster: 1\ntitle: Other\n---\n\n## O {#o}\n\nx\n"

files :: Map Text ByteString
files =
  Map.fromList
    [ ("kid/talk.slideBlaster.md", kid)
    , ("kid/figures/a.tikz", "\\draw (0,0) -- (1,1);")
    , ("kid/grand/talk.slideBlaster.md", grand)
    , ("_up/other/talk.slideBlaster.md", other)
    ]

failWith :: String -> IO a
failWith m = putStrLn ("FAIL: " <> m) >> exitFailure

expect :: (Eq a, Show a) => String -> a -> a -> IO ()
expect label e a = unless (e == a) (failWith (label <> "\n  expected: " <> show e <> "\n  actual:   " <> show a))

field :: Text -> Value -> Value
field k (Object o) = fromMaybe Null (KeyMap.lookup (Key.fromText k) o)
field _ _ = Null

arr :: Value -> [Value]
arr (Array a) = toList a
arr _ = []

str :: Value -> Text
str (String t) = t
str _ = ""

codes :: Analysis -> [Text]
codes a = [diagnosticCode d | d <- analysisDiagnostics a, diagnosticSeverity d `elem` ["error", "warning"]]

main :: IO ()
main = do
  -- path keys
  expect "normalize" "_up/x" (normalizeKey "a/../../x")
  expect "normalize deeper" "_up/_up/x" (normalizeKey "../../x")
  expect "up then back" "_up" (normalizeKey "_up/x/..")
  expect "relative" "../x/y" (keyToRelative "_up/x/y")
  expect "child key" "my-talk" (childKeyOf "_up/My_Talk")
  expect "child key of file" "talk" (childKeyOf "a/talk.slideBlaster.md")
  expect "include line" (Just (IncludeLine ["a", "b"] "../x")) (parseIncludeLine "\\include[a, b]{../x}  \n")
  expect "not an include" Nothing (parseIncludeLine "\\includegraphics{x}")

  let analysis = analyzeDeck markdownAnalyzer files "talk.slideBlaster.md" parent
      keys = fmap frameKey (analysisFrames analysis)
  expect "diagnostics" [] (codes analysis)
  expect
    "frames: child spliced in order, title and dividers kept by option"
    [ "title-slide", "opening", "section-one"
    , "kid/title-slide", "kid/opening", "kid/section-inner", "kid/deep", "kid/grand/g"
    , "after", "section-two", "talk/o", "last"
    ]
    keys
  expect "parent section holds the child slides" ["section-one", "kid/title-slide", "kid/opening", "kid/section-inner", "kid/deep", "kid/grand/g", "after"] (Route.sectionFrames (analysisSections analysis !! 0))
  expect "subsections nested under the parent section" [("kid/inner", Just "one", "kid")] [(subId s, subParent s, subDeck s) | s <- analysisSubsections analysis, subDeck s == "kid"]
  expect "no collision: handles are distinct" True (let hs = [identifierText (figureRef r) | r <- analysisFigures analysis] in length hs == length (Map.keys (Map.fromList [(h, ()) | h <- hs])))
  expect "figure path resolves under the child's folder" [("kid/opening", Just "kid/figures/a.tikz")] [(figureFrame r, figureInputPath r) | r <- analysisFigures analysis]
  expect "origin" (Just (FrameOrigin "kid" "kid/talk.slideBlaster.md")) (frameOrigin (analysisFrames analysis !! 4))
  expect "grandchild origin keeps the innermost deck" (Just (FrameOrigin "grand" "kid/grand/talk.slideBlaster.md")) (frameOrigin (analysisFrames analysis !! 7))
  expect "outside the folder" (Just (FrameOrigin "talk" "../other/talk.slideBlaster.md")) (frameOrigin (analysisFrames analysis !! 10))
  expect "parent frames are not read-only" Nothing (frameOrigin (analysisFrames analysis !! 1))

  -- missing, cycle, ambiguity
  let missing = analyzeDeck markdownAnalyzer Map.empty "talk.slideBlaster.md" parent
  expect "missing include" ["include.missing", "include.missing"] (codes missing)
  let cyc = analyzeDeck markdownAnalyzer (Map.fromList [("kid/talk.slideBlaster.md", bytes "---\nslideblaster: 1\ntitle: K\n---\n\n## K {#k}\n\nx\n\n\\include{..}\n")]) "talk.slideBlaster.md" (bytes "---\nslideblaster: 1\ntitle: P\n---\n\n## P {#p}\n\nx\n\n\\include{kid}\n")
  expect "cycle" ["include.cycle"] (codes cyc)

  -- the session view and edits
  s0 <- case runSession (newSession markdownAnalyzer) (OpenProject "talk.slideBlaster.md" ((("talk.slideBlaster.md", parent)) : Map.toList files)) of
    Right (s, _, _) -> pure s
    Left p -> failWith (show p)
  let v = viewValue s0
  expect "view sections are the parent's" ["one", "two"] (fmap (str . field "id") (arr (field "sections" v)))
  expect "view subsections" ["kid/inner"] (fmap (str . field "id") (arr (field "subsections" v)))
  let items = arr (field "items" (field "navigator" v))
  expect "origin badge" "kid" (str (field "deck" (field "origin" (items !! 4))))
  expect "page count counts child slides" (12 :: Int) (length items)
  case runSession s0 (SelectSlide "kid/deep") of
    Left p -> failWith (show p)
    Right (s1, _, _) -> do
      expect "new_slide disabled on included slide" (Bool False) (field "enabled" (field "new_slide" (field "commands" (viewValue s1))))
      case runSession s1 (SessionCommand NewSlide Nothing) of
        Left (SessionEditRejected m) -> expect "reason" "include.read_only" (Text.take 17 m)
        other' -> failWith ("expected rejection, got " <> either show (const "success") other')
  putStrLn "include tests passed"
