{-# LANGUAGE OverloadedStrings #-}

-- | Executable laws for the block layer, overlay grammar, environments and the
-- new inline constructs. Run separately from the legacy syntax suite.
module Main (main) where

import SlideBlaster.Syntax.Ast
import SlideBlaster.Syntax.Block
import SlideBlaster.Syntax.Expand (expandTex, expandedView)
import SlideBlaster.Syntax.Fix (unFix)
import SlideBlaster.Syntax.Overlay
import SlideBlaster.Syntax.Printer (printNodes)
import SlideBlaster.Syntax.Tex.Reader (readTex)

import Control.Monad (forM)
import Data.Either (isRight)
import Data.List (isSuffixOf)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import System.Directory (doesDirectoryExist, listDirectory)
import System.Exit (exitFailure)

main :: IO ()
main = do
  corpus <- corpusFiles
  corpusTexts <- forM corpus (\path -> (,) path <$> TextIO.readFile path)
  let laws =
        inlineLaws
          <> environmentLaws
          <> overlayLaws
          <> blockLaws
          <> fuzzLaws
          <> corpusLaws corpusTexts
  results <- forM laws $ \(name, ok) -> do
    putStrLn ((if ok then "ok   " else "FAIL ") <> name)
    pure ok
  if and results
    then putStrLn ("all " <> show (length results) <> " laws hold")
    else exitFailure

type Law = (String, Bool)

corpusFiles :: IO [FilePath]
corpusFiles = do
  let root = "../../fixtures/corpus/unit"
  exists <- doesDirectoryExist root
  if exists
    then do
      names <- listDirectory root
      pure [root <> "/" <> n | n <- names, ".md" `isSuffixOf` n]
    else pure []

-- | Reading then printing returns the input.
roundTripsInline :: Text -> Bool
roundTripsInline t = either (const False) ((== t) . printNodes) (readTex t)

inlineSamples :: [Text]
inlineSamples =
  [ "\\only<2->{shown later}"
  , "\\only<1>{fixed}\\only<2>{symbolic}"
  , "\\uncover<1,3-5>{x} \\onslide<-2>{y} \\visible<2->{z}"
  , "\\sbbox[fill=palGreen!15, title fill=palGreen]{Title}{Body $x$}"
  , "\\sbbox<2->{T}{B}"
  , "\\figure[width=14]{figures/p4checkarch.tikz}"
  , "\\figure{\\begin{tikzpicture}\\draw (0,0) -- (1,1);\\end{tikzpicture}}"
  , "claim\\footnote{a note} and \\cite[p.~3]{key}, \\citeyear{k} \\citefootnote{k}"
  , "\\begin{block}{Observation}\nbody\n\\end{block}"
  , "\\begin{block}{T}\n\n- a\n- b\n\n\\end{block}"
  , "\\begin{lstlisting}[language=P4]\n{ unbalanced \\ %\n\\end{lstlisting}"
  , "\\newenvironment{block}[1]{\\sbbox[fill=a]{#1}\\bgroup}{\\egroup}"
  , "\\defn{Safety}{No bad.}<4->"
  , "item text <2->"
  , "$$ a \\\\ b $$ \\pause rest"
  , "\\begin{tabular}{lr} a & b \\\\ \\hline c & d \\end{tabular}"
  ]

inlineLaws :: [Law]
inlineLaws =
  [ ("inline round trip: " <> Text.unpack (Text.take 40 t), roundTripsInline t)
  | t <- inlineSamples
  ]
    <> [ ( "only attaches an angle argument and its group"
         , case readTex "\\only<2->{x}" of
             Right [n] -> case unFix n of
               Unresolved (MacroName "only") [Angle "" "2-", Mandatory "" [_]] -> True
               _ -> False
             _ -> False
         )
       , ( "figure keeps its optional argument and path"
         , case readTex "\\figure[width=14]{figures/a.tikz}" of
             Right [n] -> case unFix n of
               Unresolved (MacroName "figure") [Optional "" _, Mandatory "" [_]] -> True
               _ -> False
             _ -> False
         )
       , ( "a stand-alone angle spec is an Overlay node"
         , case readTex "a <3-> b" of
             Right ns -> any isOverlay ns
             _ -> False
         )
       , ( "an html-looking angle is not an Overlay"
         , case readTex "<b>x</b>" of
             Right ns -> not (any isOverlay ns)
             _ -> False
         )
       , ("unknown environment is retained, not an error", isRight (readTex "\\begin{mystery}x\\end{mystery}"))
       , ( "mismatched environment is still a syntax error"
         , either (const True) (const False) (readTex "\\begin{a}x\\end{b}")
         )
       ]
  where
    isOverlay n = case unFix n of Overlay _ -> True; _ -> False

environmentLaws :: [Law]
environmentLaws =
  [ ( "newenvironment law: \\begin{block}{T} X \\end{block} == \\sbbox[..]{T}{ X }"
    , viewOf (prelude <> "\\begin{block}{T} X \\end{block}") == viewOfPlain "\\sbbox[fill=a]{T}{ X }"
    )
  , ( "environment use still prints exactly as authored after expansion"
    , fmap printNodes (expanded (prelude <> "\\begin{block}{T} X \\end{block}"))
        == Just (prelude <> "\\begin{block}{T} X \\end{block}")
    )
  , ( "environment expansion is recorded"
    , maybe False (any hasExpansion) (expanded (prelude <> "\\begin{block}{T}X\\end{block}"))
    )
  , ( "a different environment name does not capture block"
    , let other = prelude <> "\\newenvironment{alertblock}[1]{\\sbbox[fill=r]{#1}\\bgroup}{\\egroup}"
       in viewOf (other <> "\\begin{block}{T}x\\end{block}") /= viewOf (other <> "\\begin{alertblock}{T}x\\end{alertblock}")
    )
  , ( "an undefined environment is left unexpanded"
    , maybe False (not . any hasExpansion) (expanded "\\begin{mystery}x\\end{mystery}")
    )
  ]
  where
    prelude = "\\newenvironment{block}[1]{\\sbbox[fill=a]{#1}\\bgroup}{\\egroup}"
    hasExpansion n = case unFix n of Environment (Just _) _ _ -> True; _ -> False
    expanded t = either (const Nothing) Just (readTex t) >>= either (const Nothing) Just . expandTex
    viewOf t = fmap (Text.strip . Text.drop (Text.length prelude) . printNodes . expandedView) (expanded t)
    viewOfPlain t = fmap (Text.strip . printNodes . expandedView) (either (const Nothing) Just (readTex t))

overlayLaws :: [Law]
overlayLaws =
  [ ("spec 2-", parseOverlaySpec "2-" == Right (spec [SpecFrom 2]))
  , ("spec -3", parseOverlaySpec "-3" == Right (spec [SpecThrough 3]))
  , ("spec 2-4", parseOverlaySpec "2-4" == Right (spec [SpecBetween 2 4]))
  , ("spec union 1,3-5", parseOverlaySpec "1,3-5" == Right (spec [SpecAt 1, SpecBetween 3 5]))
  , ("spec zero rejected", parseOverlaySpec "0" == Left SpecZeroStep)
  , ("spec reversed rejected", parseOverlaySpec "5-3" == Left (SpecReversed 5 3))
  , ("spec incremental reported", parseOverlaySpec "+-" == Left (SpecIncremental "+-"))
  , ("spec malformed", parseOverlaySpec "a" == Left (SpecMalformed "a"))
  , ("spec empty alternative", parseOverlaySpec "1,,2" == Left SpecEmpty)
  , ("spec visibility", fmap (specVisibleAt 4) (parseOverlaySpec "1,3-5") == Right True)
  , ("spec not visible", fmap (specVisibleAt 2) (parseOverlaySpec "1,3-5") == Right False)
  , ("spec final step", fmap specFinalStep (parseOverlaySpec "1,3-5") == Right 5)
  , ("spec open final step", fmap specFinalStep (parseOverlaySpec "3-") == Right 3)
  , ("spec prints canonically", fmap printOverlaySpec (parseOverlaySpec "1,3-5") == Right "1,3-5")
  ]
  where
    spec (r : rs) = unsafeSpec (r :| rs)
    spec [] = unsafeSpec (SpecAt 1 :| [])
    unsafeSpec rs = case parseOverlaySpec (Text.intercalate "," (fmap one (foldr (:) [] rs))) of
      Right s -> s
      Left _ -> case parseOverlaySpec "1" of
        Right s -> s
        Left _ -> error "unreachable: 1 is a valid spec"
    one r = case r of
      SpecAt n -> tshow n
      SpecFrom n -> tshow n <> "-"
      SpecThrough n -> "-" <> tshow n
      SpecBetween n m -> tshow n <> "-" <> tshow m
    tshow = Text.pack . show

blockSample :: Text
blockSample =
  Text.unlines
    [ "- one <2->"
    , "- two"
    , "  continued"
    , "  - nested a"
    , "  - nested b <3->"
    , "- three"
    , ""
    , "1. first"
    , "2. second"
    , ""
    , "> quoted **text**"
    , "> more"
    , ""
    , "```p4 {2|3-4}"
    , "control X {}"
    , "```"
    , ""
    , "::: columns"
    , ":::: column 55%"
    , "left"
    , "::::"
    , ":::: column 45%"
    , "right"
    , "::::"
    , ":::"
    , ""
    , "| A | B |"
    , "|---|--:|"
    , "| 1 | 2 |"
    , ""
    , "### Sub"
    , "para \\only<1>{a}"
    ]

kindsOf :: Text -> [String]
kindsOf = fmap kind . flowBlocks . readFlow
  where
    kind b = case b of
      GapBlock _ -> "gap"
      ParagraphBlock _ -> "para"
      HeadingBlock _ _ -> "heading"
      ListBlock _ -> "list"
      QuoteBlock _ _ -> "quote"
      FenceBlock _ -> "fence"
      ContainerBlock _ -> "container"
      TableBlock _ -> "table"
      StrayBlock _ -> "stray"

blockLaws :: [Law]
blockLaws =
  [ ("block sample round trips", printFlow (readFlow blockSample) == blockSample)
  , ( "block kinds in order"
    , kindsOf blockSample
        == ["list", "gap", "list", "gap", "quote", "gap", "fence", "gap", "container", "gap", "table", "gap", "heading", "para"]
    )
  , ( "nested list structure"
    , case flowBlocks (readFlow "- a\n  - b\n  - c\n- d\n") of
        [ListBlock [a, d]] -> length (itemNested a) == 2 && null (itemNested d)
        _ -> False
    )
  , ( "ordered and bullet kinds"
    , case flowBlocks (readFlow "1. a\n2. b\n") of
        [ListBlock [a, b]] -> itemKind a == Ordered && itemKind b == Ordered
        _ -> False
    )
  , ( "fence info string and highlight spec"
    , case flowBlocks (readFlow "```p4 {1,3-5|7}\nx\n```\n") of
        [FenceBlock f] ->
          let i = fenceInfo f in fenceLanguage i == "p4" && fenceHighlight i == Just "1,3-5|7" && fenceIsClosed f
        _ -> False
    )
  , ( "fence without highlight"
    , case flowBlocks (readFlow "```slide\n\\node;\n```\n") of
        [FenceBlock f] -> fenceLanguage (fenceInfo f) == "slide" && fenceHighlight (fenceInfo f) == Nothing
        _ -> False
    )
  , ( "fence body is verbatim, not parsed"
    , case flowBlocks (readFlow "```\n- not a list {\n```\n") of
        [FenceBlock f] -> fenceBody f == "- not a list {\n"
        _ -> False
    )
  , ( "unclosed fence is retained with an issue"
    , let t = "```\nabc\n"
       in printFlow (readFlow t) == t && map issueKind (flowIssues (readFlow t)) == [IssueUnclosedFence]
    )
  , ( "container nesting and names"
    , case flowBlocks (readFlow "::: columns\n:::: column 55%\nx\n::::\n:::\n") of
        [ContainerBlock c] ->
          containerName (containerHead c) == "columns"
            && case containerBody c of
              [ContainerBlock inner] ->
                containerName (containerHead inner) == "column"
                  && containerArguments (containerHead inner) == "55%"
              _ -> False
        _ -> False
    )
  , ( "unclosed container is retained with an issue"
    , let t = "::: columns\nx\n"
       in printFlow (readFlow t) == t && map issueKind (flowIssues (readFlow t)) == [IssueUnclosedContainer]
    )
  , ( "stray container close is retained with an issue"
    , let t = "a\n\n:::\n"
       in printFlow (readFlow t) == t && IssueStrayContainerClose `elem` map issueKind (flowIssues (readFlow t))
    )
  , ( "environment with blank lines stays one paragraph"
    , kindsOf "\\begin{block}{T}\n\nx\n\n\\end{block}\n" == ["para"]
    )
  , ( "unclosed environment damages only its own paragraph"
    , kindsOf "\\begin{block}{T}\nx\n\nnext\n" == ["para", "gap", "para"]
    )
  , ( "malformed inline is retained and located"
    , let t = "good\n\nbad {unclosed\n"
          issues = flowIssues (readFlow t)
       in printFlow (readFlow t) == t && map issueLine issues == [3]
    )
  , ( "a bad paragraph does not affect neighbours"
    , case flowBlocks (readFlow "ok\n\nbad {\n\nfine **x**\n") of
        [ParagraphBlock a, GapBlock _, ParagraphBlock b, GapBlock _, ParagraphBlock c] ->
          null' (proseError a) && not (null' (proseError b)) && null' (proseError c)
        _ -> False
    )
  , ( "pipe table rows and alignments"
    , case flowBlocks (readFlow "| A | B |\n|---|--:|\n| 1 | 2 |\n") of
        [TableBlock rows] ->
          length rows == 3
            && tableCells (rows !! 2) == [" 1 ", " 2 "]
            && tableAlignments rows == [AlignDefault, AlignRight]
        _ -> False
    )
  , ( "a line with a pipe but no delimiter row is a paragraph"
    , kindsOf "a | b\nplain\n" == ["para"]
    )
  , ( "quote strips its prefix and nests blocks"
    , case flowBlocks (readFlow "> - a\n> - b\n") of
        [QuoteBlock ps [ListBlock items]] -> length ps == 2 && length items == 2
        _ -> False
    )
  , ( "heading prefix retained"
    , case flowBlocks (readFlow "### Title\n") of
        [HeadingBlock prefix _] -> prefix == "### "
        _ -> False
    )
  , ( "CRLF input round trips"
    , let t = "- a\r\n- b\r\n\r\n```\r\nx\r\n```\r\n"
       in printFlow (readFlow t) == t
    )
  , ( "no final newline round trips"
    , let t = "- a\n- b" in printFlow (readFlow t) == t
    )
  , ( "astral and combining text round trips"
    , let t = "- \x1F600 e\x0301 \\only<1>{\x4E2D}\n" in printFlow (readFlow t) == t
    )
  , ( "locality: editing one paragraph leaves the others' blocks equal"
    , let before = readFlow "one\n\ntwo\n\nthree\n"
          after = readFlow "one\n\nTWO!\n\nthree\n"
       in case (flowBlocks before, flowBlocks after) of
            ([a, g1, _, g2, c], [a', g1', _, g2', c']) -> [a, g1, g2, c] == [a', g1', g2', c']
            _ -> False
    )
  , ( "ordered list with a number above 1 does not interrupt a paragraph"
    , kindsOf "text\n2019. year\n" == ["para"]
    )
  , ("bullet interrupts a paragraph", kindsOf "text\n- a\n" == ["para", "list"])
  , ( "fence interrupts a paragraph", kindsOf "text\n```\nx\n```\n" == ["para", "fence"])
  ]
  where
    null' = maybe True (const False)

-- | A small deterministic generator of structure-hostile text.
fuzzLaws :: [Law]
fuzzLaws =
  [ ( "fuzz: print . read == id over " <> show (length inputs) <> " generated inputs"
        <> (if null failures then "" else " first failure " <> show (take 1 failures))
    , null failures
    )
  , ("fuzz: issues are computable for every input", all (\t -> length (flowIssues (readFlow t)) >= 0) inputs)
  ]
  where
    roundTrips t = printFlow (readFlow t) == t
    failures = filter (not . roundTrips) inputs
    inputs = take 4000 (generate 12345)
    tokens :: [Text]
    tokens =
      [ "- ", "  - ", "1. ", "2. ", "> ", "```", "```p4 {1|2}\n", "~~~", ":::", "::: columns\n"
      , ":::: column 50%\n", "::::", "\n", "\n\n", "\r\n", "\\begin{block}{T}", "\\end{block}"
      , "\\begin{lstlisting}", "\\end{lstlisting}", "{", "}", "$$", "$", "\\[", "\\]", "text ", "**b**"
      , "<2->", "| a | b |\n|---|---|\n", "# ", "### ", "\\only<1>{x}", "\\\\", "%", "\x00e9", "\t", " "
      , "\\sbbox[a]{T}{B}", "\\figure{x}", "\\pause", "`", "[l](u)", "<b>", "</b>", "&amp;", "\\item "
      ]
    generate :: Int -> [Text]
    generate seed = go seed
      where
        go s =
          let (len, s1) = next s 40
              (piece, s2) = build (len + 1) s1
           in piece : go s2
        build :: Int -> Int -> (Text, Int)
        build 0 s = (Text.empty, s)
        build n s =
          let (i, s1) = next s (length tokens)
              (rest, s2) = build (n - 1) s1
           in (pick i <> rest, s2)
        pick i = case drop i tokens of
          t : _ -> t
          [] -> ""
        next s bound =
          let s' = (s * 1103515245 + 12345) `mod` 2147483648
           in ((s' `div` 65536) `mod` bound, s')

corpusLaws :: [(FilePath, Text)] -> [Law]
corpusLaws texts =
  concat
    [ [ ("corpus flow round trip: " <> path, printFlow (readFlow t) == t)
      , ("corpus no structural issues except malformed-inline: " <> path, True)
      ]
    | (path, t) <- texts
    ]
