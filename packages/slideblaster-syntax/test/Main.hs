{-# LANGUAGE OverloadedStrings #-}

-- | Executable laws for the syntax package.
--
-- Three families, and the distinction between them is the contract:
--
-- * printing a hand-built tree reproduces an exact authored spelling, including
--   trees that mix dialects, which is what proves one tree serves all three;
-- * reading then printing real input reproduces it character for character;
-- * malformed input is rejected rather than represented.
--
-- A fourth family covers macro expansion, and every case there additionally
-- asserts that printing is unchanged by expansion.
module Main (main) where

import SlideBlaster.Syntax.Command
  ( Command (Command)
  , CommandError
      ( CommandInsideExpansion
      , CommandNotClearable
      , CommandRange
      , CommandTargetNotFound
      , CommandUnspellable
      )
  , Effect (ClearStyle, SetStyle, ToggleStyle)
  , Target (At, Between)
  , applyCommand
  )
import SlideBlaster.Syntax.Range
  ( Point (Point)
  , RangeError (RangeEmpty, RangeNotSplittable)
  , extentOf
  , pathEntersExpansion
  , prepareSelection
  , runExtents
  )
import SlideBlaster.Syntax.Ast
  ( ArgumentF (Mandatory)
  , DefinitionF (..)
  , DefinitionForm (NewCommandForm)
  , ItemF (ItemF)
  , ListKind (Unordered)
  , MacroName (MacroName)
  , Node
  , NodeF (..)
  , ParametersF (..)
  , node
  , setPrimaryChildren
  )
import SlideBlaster.Syntax.Colour
  ( ColourError (UnknownColourName)
  , resolveColour
  , rgbToHex
  )
import SlideBlaster.Syntax.Edit
  ( EditError (PathNotFound)
  , clearStyleAt
  , setStyleAt
  , stylesInPlace
  )
import SlideBlaster.Syntax.Expand (expandTex)
import SlideBlaster.Syntax.Fix (unFix)
import SlideBlaster.Syntax.Inline
  ( Inline (..)
  , InlineIssue (UnexpandedMacro, UnresolvableColour)
  , InlineRun (..)
  , RunKind (OpaqueRun, PlainRun)
  , ResolvedStyle (..)
  , coalesceRuns
  , flattenInline
  , inlineText
  , styleHolds
  )
import SlideBlaster.Syntax.Path
  ( Path
  , childAt
  , pathFromList
  , pathsOf
  , resolvePath
  , rootPath
  , setChildAt
  )
import SlideBlaster.Syntax.Printer (printNode, printNodes)
import SlideBlaster.Syntax.Style
  ( ColourExpr (ColourComplement, ColourMix, ColourName, ColourTint)
  , Literal (..)
  , Slant (Italic, Upright)
  , StyleKey (ForegroundKey, HighlightKey, SlantKey, WeightKey)
  , StyleValue
      ( SetForeground
      , SetHighlight
      , SetSlant
      , SetStrike
      , SetUnderline
      , SetWeight
      )
  , Weight (Bold)
  , styleMapFromList
  )
import SlideBlaster.Syntax.Surface
  ( Attribute (..)
  , AttributeValue (PlainValue, StyleValue)
  , Declaration (..)
  , HtmlSpelling (HtmlElement)
  , MdSpelling (MdBullet, MdChars, MdDelimited, MdItem)
  , QuoteStyle (DoubleQuoted)
  , Dialect (Html, Markdown, Tex)
  , Surface (HtmlSurface, MarkdownSurface, TexSurface, Transparent)
  , TagForm (NormalTag)
  , TexSpelling (..)
  , dialectOf
  , elementName
  , hostedDialects
  )
import SlideBlaster.Syntax.Tex.Reader (readTex)

import Data.Foldable (toList)
import Data.Maybe (listToMaybe)
import Data.List (unsnoc)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Exit (exitFailure)

main :: IO ()
main = do
  printResults <- traverse runCase cases
  roundTripResults <- traverse runRoundTrip roundTripCorpus
  rejectResults <- traverse runReject malformedCorpus
  expandResults <- traverse runExpansion expansionCorpus
  failResults <- traverse runExpansionFailure expansionFailures
  dialectResults <- traverse checkDialect dialectCases
  colourResults <- traverse runColour colourCases
  colourFailResults <- traverse runColourFailure colourFailures
  pathResults <- traverse checkPath pathCases
  inlineResults <- traverse runInline inlineCases
  editResults <- traverse runEdit editCases
  editFailResults <- traverse runEditFailure editFailures
  commandResults <- traverse runCommand commandCases
  commandFailResults <- traverse runCommandFailure commandFailures
  mixedResults <- traverse runMixedCommand mixedCommandCases
  mixedReadResults <- traverse runMixedRead mixedReadCases
  mixedTripResults <- traverse runRoundTrip mixedRoundTrip
  structuralResults <- traverse checkStructural structuralCases
  let results =
        printResults
          <> roundTripResults
          <> rejectResults
          <> expandResults
          <> failResults
          <> dialectResults
          <> colourResults
          <> colourFailResults
          <> pathResults
          <> inlineResults
          <> editResults
          <> editFailResults
          <> commandResults
          <> commandFailResults
          <> mixedResults
          <> mixedReadResults
          <> mixedTripResults
          <> structuralResults
  if and results
    then putStrLn ("all " <> show (length results) <> " laws hold")
    else exitFailure

-- Printing hand-built trees --------------------------------------------------

runCase :: (String, Node, Text) -> IO Bool
runCase (name, tree, expected) = do
  let actual = printNode tree
  if actual == expected
    then do
      putStrLn ("ok   print " <> name)
      pure True
    else do
      putStrLn ("FAIL print " <> name)
      putStrLn ("  expected: " <> show expected)
      putStrLn ("  actual:   " <> show actual)
      pure False

texChars :: Text -> Node
texChars = node . Text (TexSurface TexChars)

cases :: [(String, Node, Text)]
cases =
  [ ( "tex style command"
    , styledTex (SetWeight Bold) (TexCommand "textbf") [texChars "x"]
    , "\\textbf{x}"
    )
  , ( "tex style declaration scopes over its group"
    , node
        ( Run
            (TexSurface TexBraceGroup)
            [ styledTex
                (SetWeight Bold)
                (TexDeclaration "bfseries")
                [node (Whitespace " "), texChars "a b"]
            ]
        )
    , "{\\bfseries a b}"
    )
  , ( "emph keeps its own spelling though it means italic"
    , styledTex (SetSlant Italic) (TexCommand "emph") [texChars "x"]
    , "\\emph{x}"
    )
  , ( "colour percentage keeps the authored spelling, not the value"
    , styledTex
        (SetForeground (ColourTint (ColourName "red") (Literal (1 / 2) "50")))
        (TexColourCommand "textcolor")
        [texChars "x"]
    , "\\textcolor{red!50}{x}"
    )
  , -- The point of one tree: TeX containing Markdown containing HTML, printed by
    -- one fold, each construct in the dialect that authored it.
    ( "tex containing markdown containing html"
    , styledTex
        (SetWeight Bold)
        (TexCommand "textbf")
        [ node
            ( Styled
                (styleMapFromList [SetSlant Italic])
                (MarkdownSurface (MdDelimited "*"))
                [ node
                    ( Styled
                        (styleMapFromList [SetWeight Bold])
                        ( HtmlSurface
                            ( HtmlElement
                                (elementName "strong")
                                []
                                ""
                                NormalTag
                            )
                        )
                        [node (Text (HtmlSurface (HtmlElement (elementName "x") [] "" NormalTag)) "")]
                    )
                ]
            )
        ]
    , "\\textbf{*<strong></strong>*}"
    )
  , ( "html attributes keep quoting and spacing"
    , node
        ( Run
            ( HtmlSurface
                ( HtmlElement
                    (elementName "DIV")
                    [ Attribute "class" (Just (PlainValue "a b")) DoubleQuoted " "
                    , Attribute "hidden" Nothing DoubleQuoted " "
                    ]
                    ""
                    NormalTag
                )
            )
            [texChars "inner"]
        )
    , "<DIV class=\"a b\" hidden>inner</DIV>"
    )
  , ( "untouched style declarations reprint byte for byte"
    , node
        ( Run
            ( HtmlSurface
                ( HtmlElement
                    (elementName "span")
                    [ Attribute
                        "style"
                        ( Just
                            ( StyleValue
                                [ Declaration "color" "red" False "color: red;"
                                , Declaration "margin" "0" False " margin:0"
                                ]
                            )
                        )
                        DoubleQuoted
                        " "
                    ]
                    ""
                    NormalTag
                )
            )
            []
        )
    , "<span style=\"color: red; margin:0\"></span>"
    )
  , ( "markdown list keeps each marker and indent"
    , node
        ( Items
            Unordered
            (MarkdownSurface MdBullet)
            []
            [ ItemF (MarkdownSurface (MdItem "" "-" " ")) Nothing [texChars "a"]
            , ItemF (MarkdownSurface (MdItem "  " "*" " ")) Nothing [texChars "b"]
            ]
        )
    , "- a  * b"
    )
  , ( "itemize preamble whitespace survives"
    , node
        ( Items
            Unordered
            (TexSurface (TexEnvironment "itemize"))
            [node (Whitespace "\n  ")]
            [ItemF (TexSurface TexItem) Nothing [texChars " a"]]
        )
    , "\\begin{itemize}\n  \\item a\\end{itemize}"
    )
  , ( "definition body is a template, printed not expanded"
    , node
        ( Define
            DefinitionF
              { definitionForm = NewCommandForm
              , definitionName = MacroName "R"
              , definitionNameBraced = True
              , definitionParameters =
                  ParametersF {parameterCount = 0, parameterOptionalDefault = Nothing}
              , definitionBody =
                  [node (Unresolved (MacroName "mathbb") [Mandatory "" [texChars "R"]])]
              , definitionClose = Nothing
              }
        )
    , "\\newcommand{\\R}{\\mathbb{R}}"
    )
  ]

styledTex :: StyleValue -> TexSpelling -> [Node] -> Node
styledTex fact spelling children =
  node (Styled (styleMapFromList [fact]) (TexSurface spelling) children)

-- Dialect is data, not a constructor ----------------------------------------

-- | The same meaning in three dialects must be the same constructor, differing
-- only in its surface. This is what removes the need for an inverse mapping.
checkDialect :: (String, Node, Text) -> IO Bool
checkDialect (name, tree, expected) =
  case unFix tree of
    Styled _ surface _
      | printNode tree == expected -> do
          putStrLn
            ("ok   dialect " <> name <> " (" <> show (dialectOf surface) <> ")")
          pure True
    _ -> do
      putStrLn ("FAIL dialect " <> name)
      putStrLn ("  printed " <> show (printNode tree) <> " wanted " <> show expected)
      pure False

dialectCases :: [(String, Node, Text)]
dialectCases =
  [ ( "bold in tex"
    , styledTex (SetWeight Bold) (TexCommand "textbf") [texChars "x"]
    , "\\textbf{x}"
    )
  , ( "bold in markdown"
    , node
        ( Styled
            (styleMapFromList [SetWeight Bold])
            (MarkdownSurface (MdDelimited "**"))
            [texChars "x"]
        )
    , "**x**"
    )
  , ( "bold in html"
    , node
        ( Styled
            (styleMapFromList [SetWeight Bold])
            (HtmlSurface (HtmlElement (elementName "strong") [] "" NormalTag))
            [texChars "x"]
        )
    , "<strong>x</strong>"
    )
  ]

-- Expansion ------------------------------------------------------------------

runExpansion :: (String, Text, [(Text, Text)]) -> IO Bool
runExpansion (name, input, expected) =
  case readTex input of
    Left err -> reject ("syntax error: " <> show err)
    Right parsed ->
      case expandTex parsed of
        Left err -> reject ("expansion failed: " <> show err)
        Right nodes ->
          let printed = printNodes nodes
              found = concatMap macroExpansions nodes
           in if printed /= input
                then
                  reject
                    ( "printing changed the source: "
                        <> show input
                        <> " became "
                        <> show printed
                    )
                else
                  if all (`elem` found) expected
                    then do
                      putStrLn ("ok   expand " <> name)
                      pure True
                    else
                      reject ("expected " <> show expected <> " among " <> show found)
  where
    reject message = do
      putStrLn ("FAIL expand " <> name)
      putStrLn ("  " <> message)
      pure False

runExpansionFailure :: (String, Text) -> IO Bool
runExpansionFailure (name, input) =
  case readTex input of
    Left err -> do
      putStrLn ("FAIL expand-reject " <> name <> ": " <> show err)
      pure False
    Right parsed ->
      case expandTex parsed of
        Left _ -> do
          putStrLn ("ok   expand-reject " <> name)
          pure True
        Right _ -> do
          putStrLn ("FAIL expand-reject " <> name <> ": accepted")
          pure False

-- | Collect the printed expansion of every resolved macro use.
macroExpansions :: Node -> [(Text, Text)]
macroExpansions tree =
  here <> concatMap macroExpansions (toList (unFix tree))
  where
    here =
      case unFix tree of
        MacroUse (Just expansion) (MacroName name) _ ->
          [(name, printNodes expansion)]
        _ -> []

expansionCorpus :: [(String, Text, [(Text, Text)])]
expansionCorpus =
  [ ( "zero-argument macro resolves"
    , "\\newcommand{\\R}{\\mathbb{R}}x \\R y"
    , [("R", "\\mathbb{R}")]
    )
  , ( "two-argument macro substitutes both parameters"
    , "\\newcommand{\\pair}[2]{#1-#2}\\pair{a}{b}"
    , [("pair", "a-b")]
    )
  , ( "repeated parameter is substituted at each occurrence"
    , "\\newcommand{\\twice}[1]{#1#1}\\twice{ab}"
    , [("twice", "abab")]
    )
  , ( "whitespace before an argument is preserved and skipped"
    , "\\newcommand{\\id}[1]{#1}\\id {z}"
    , [("id", "z")]
    )
  , ( "argument containing markup is substituted whole"
    , "\\newcommand{\\box}[1]{[#1]}\\box{\\textbf{q}}"
    , [("box", "[\\textbf{q}]")]
    )
  , ( "nested macro use expands transitively"
    , "\\newcommand{\\a}{A}\\newcommand{\\b}{\\a\\a}\\b"
    , [("b", "\\a\\a")]
    )
  , ( "zero-arity macro does not consume a following group"
    , "\\newcommand{\\R}{X}\\R {y}"
    , [("R", "X")]
    )
  , ("undefined macro stays unresolved", "\\undefinedmacro{x}", [])
  ]

expansionFailures :: [(String, Text)]
expansionFailures =
  [ ("self-referential definition", "\\newcommand{\\a}{\\a}\\a")
  , ( "mutually recursive definitions"
    , "\\newcommand{\\a}{\\b}\\newcommand{\\b}{\\a}\\a"
    )
  , ("missing argument", "\\newcommand{\\pair}[2]{#1#2}\\pair{a}")
  ]

-- Reading ---------------------------------------------------------------------

runRoundTrip :: (String, Text) -> IO Bool
runRoundTrip (name, input) =
  case readTex input of
    Left err -> do
      putStrLn ("FAIL round-trip " <> name)
      putStrLn ("  unexpected syntax error: " <> show err)
      pure False
    Right nodes -> do
      let actual = printNodes nodes
      if actual == input
        then do
          putStrLn ("ok   round-trip " <> name)
          pure True
        else do
          putStrLn ("FAIL round-trip " <> name)
          putStrLn ("  input:  " <> show input)
          putStrLn ("  output: " <> show actual)
          pure False

roundTripCorpus :: [(String, Text)]
roundTripCorpus =
  [ ("plain text", "Hello world")
  , ("style command", "\\textbf{bold}")
  , ("style declaration in a group", "{\\bfseries a b}")
  , ("colour tint", "\\textcolor{red!50}{x}")
  , ("colour mix", "\\textcolor{red!50!black}{x}")
  , ("colour with decimal percentage", "\\textcolor{red!12.5}{x}")
  , ("colour declaration", "{\\color{blue}text}")
  , ("nested styles", "\\textbf{a \\textit{b} c}")
  , ("unknown macro is preserved", "\\mathbb{R}")
  , ("inline math", "Euler $e^{i\\pi}+1=0$ done")
  , ("display math", "$$\\int f$$")
  , ("comment then text", "% note\ntext")
  , ("alignment tab", "a & b")
  , ("parameter in definition body", "\\newcommand{\\pair}[2]{#1#2}")
  , ("escaped hash", "\\newcommand{\\h}{##}")
  , ("consecutive parameters", "\\newcommand{\\t}[1]{#1#1}")
  , ("definition with braced name", "\\newcommand{\\R}{\\mathbb{R}}")
  , ("definition with bare name", "\\newcommand\\R{\\mathbb{R}}")
  , ("definition with optional default", "\\newcommand{\\g}[2][d]{#1#2}")
  , ( "itemize with whitespace"
    , "\\begin{itemize}\n  \\item a\n  \\item b\n\\end{itemize}"
    )
  , ("enumerate", "\\begin{enumerate}\\item x\\end{enumerate}")
  , ( "description with item label"
    , "\\begin{description}\\item[k] v\\end{description}"
    )
  , ("unicode text", "h\233llo \8594 w\246rld")
  , ("carriage returns preserved", "a\r\nb")
  , ("tab preserved", "a\tb")
  , ("no trailing newline", "a")
  , ("trailing newline", "a\n")
  , ("escaped brace", "\\{ok\\}")
  , ("escaped percent and dollar", "100\\% of \\$5")
  , ("double backslash", "line\\\\break")
  , ("empty input", "")
  ]

runReject :: (String, Text) -> IO Bool
runReject (name, input) =
  case readTex input of
    Left _ -> do
      putStrLn ("ok   reject " <> name)
      pure True
    Right _ -> do
      putStrLn ("FAIL reject " <> name <> ": accepted malformed input")
      pure False

malformedCorpus :: [(String, Text)]
malformedCorpus =
  [ ("unclosed group", "{oops")
  , ("unmatched close brace", "oops}")
  , ("unclosed inline math", "$x")
  , ("mismatched environment", "\\begin{itemize}\\item a\\end{enumerate}")
  , ("unclosed environment", "\\begin{itemize}\\item a")
  ]

-- Colour: xcolor semantics --------------------------------------------------

-- | Three of these expected values are taken from the xcolor manual's own table
-- of predefined colours, so the palette is checked against the primary source
-- rather than against my arithmetic.
runColour :: (String, ColourExpr, Text) -> IO Bool
runColour (name, expression, expected) =
  case resolveColour expression of
    Left err -> do
      putStrLn ("FAIL colour " <> name <> ": " <> show err)
      pure False
    Right colour
      | rgbToHex colour == expected -> do
          putStrLn ("ok   colour " <> name)
          pure True
      | otherwise -> do
          putStrLn ("FAIL colour " <> name)
          putStrLn ("  expected " <> show expected <> " got " <> show (rgbToHex colour))
          pure False

percent :: Rational -> Text -> Literal Rational
percent = Literal

colourCases :: [(String, ColourExpr, Text)]
colourCases =
  [ ("red", ColourName "red", "#ff0000")
  , ("black", ColourName "black", "#000000")
  , ("white", ColourName "white", "#ffffff")
  , ("gray is the half level", ColourName "gray", "#808080")
  , -- xcolor manual: orange is FF8000.
    ("orange matches the manual", ColourName "orange", "#ff8000")
  , -- xcolor manual: violet is 800080.
    ("violet matches the manual", ColourName "violet", "#800080")
  , -- xcolor manual: purple is BF0040.
    ("purple matches the manual", ColourName "purple", "#bf0040")
  , ("brown", ColourName "brown", "#bf8040")
  , -- A tint is a mix with white, which is what xcolor defines it to be.
    ("tint mixes with white", ColourTint (ColourName "red") (percent 50 "50"), "#ff8080")
  , ( "explicit mix with black darkens"
    , ColourMix (ColourName "red") (percent 50 "50") (ColourName "black")
    , "#800000"
    )
  , -- Exactness: 12.5% of 255 is not representable in binary floating point.
    ( "fractional percentage stays exact"
    , ColourTint (ColourName "red") (percent (25 / 2) "12.5")
    , "#ffdfdf"
    )
  , ("complement inverts each channel", ColourComplement (ColourName "red"), "#00ffff")
  , ( "nested mix composes"
    , ColourTint
        (ColourMix (ColourName "red") (percent 50 "50") (ColourName "blue"))
        (percent 100 "100")
    , "#800080"
    )
  , -- A percentage outside 0..100 clamps rather than escaping the gamut.
    ("percentage clamps", ColourTint (ColourName "red") (percent 150 "150"), "#ff0000")
  ]

runColourFailure :: (String, ColourExpr, ColourError) -> IO Bool
runColourFailure (name, expression, expected) =
  case resolveColour expression of
    Left err
      | err == expected -> do
          putStrLn ("ok   colour-reject " <> name)
          pure True
    outcome -> do
      putStrLn ("FAIL colour-reject " <> name <> ": " <> show outcome)
      pure False

colourFailures :: [(String, ColourExpr, ColourError)]
colourFailures =
  [ ("undefined name", ColourName "chartreuse", UnknownColourName "chartreuse")
  , -- Failure propagates out of arithmetic instead of defaulting to a colour.
    ( "undefined name inside a mix"
    , ColourTint (ColourName "nosuch") (percent 50 "50")
    , UnknownColourName "nosuch"
    )
  ]

-- Paths: structural addressing ----------------------------------------------

checkPath :: (String, IO Bool) -> IO Bool
checkPath (name, check) = do
  outcome <- check
  putStrLn ((if outcome then "ok   path " else "FAIL path ") <> name)
  pure outcome

-- | Wrap a read document so it is one addressable tree. A transparent container
-- prints only its children, so this changes no bytes.
document :: [Node] -> Node
document = node . Run (Transparent Tex)

readDocument :: Text -> Maybe Node
readDocument input =
  case readTex input of
    Left _ -> Nothing
    Right nodes -> Just (document nodes)

findPath :: (Node -> Bool) -> Node -> Maybe Path
findPath predicate tree =
  fmap fst (listToMaybe (filter (predicate . snd) (pathsOf tree)))

isTextNode :: Node -> Bool
isTextNode tree = case unFix tree of
  Text _ _ -> True
  _ -> False

isStyledNode :: Node -> Bool
isStyledNode tree = case unFix tree of
  Styled{} -> True
  _ -> False

pathCases :: [(String, IO Bool)]
pathCases =
  [ ( "every path resolves to the node it was derived from"
    , pure
        ( case readDocument "a \\textbf{b} \\textit{c}" of
            Nothing -> False
            Just tree ->
              all
                (\(path, expected) -> resolvePath path tree == Just expected)
                (pathsOf tree)
        )
    )
  , ( "child indices agree with the traversal used to replace them"
    , pure
        ( case readDocument "a \\textbf{b} c" of
            Nothing -> False
            Just tree ->
              let marker = node (Text (TexSurface TexChars) "Z")
                  count = length (toList (unFix tree))
               in count > 0
                    && all
                      ( \index ->
                          case setChildAt index marker tree of
                            Nothing -> False
                            Just updated -> childAt index updated == Just marker
                      )
                      [0 .. count - 1]
        )
    )
  , ( "replacing a child leaves the siblings alone"
    , pure
        ( case readDocument "abc" of
            Nothing -> False
            Just tree ->
              case childAt 0 tree of
                Nothing -> False
                Just original -> setChildAt 0 original tree == Just tree
        )
    )
  , ( "an out-of-range index does not resolve"
    , pure
        ( case readDocument "a" of
            Nothing -> False
            Just tree ->
              childAt (length (toList (unFix tree))) tree == Nothing
                && childAt (-1) tree == Nothing
        )
    )
  ]

-- Lowering: resolved runs ----------------------------------------------------

runInline :: (String, Text, Inline -> Bool) -> IO Bool
runInline (name, input, expected) =
  case readDocument input of
    Nothing -> do
      putStrLn ("FAIL inline " <> name <> ": did not read")
      pure False
    Just tree ->
      let lowered = flattenInline tree
       in if expected lowered
            then do
              putStrLn ("ok   inline " <> name)
              pure True
            else do
              putStrLn ("FAIL inline " <> name)
              putStrLn ("  runs: " <> show (inlineRuns lowered))
              putStrLn ("  issues: " <> show (inlineIssues lowered))
              pure False

visible :: Inline -> [(Text, Bool, Bool)]
visible lowered =
  [ (runText run, styleWeight (runStyle run) == Bold, styleSlant (runStyle run) == Italic)
  | run <- inlineRuns lowered
  , runKind run == PlainRun
  ]

inlineCases :: [(String, Text, Inline -> Bool)]
inlineCases =
  [ ( "plain text is one run with default styling"
    , "hello"
    , \lowered -> visible lowered == [("hello", False, False)]
    )
  , ( "a style command applies to its content only"
    , "a \\textbf{b} c"
    , \lowered ->
        visible lowered
          == [("a", False, False), (" ", False, False), ("b", True, False), (" ", False, False), ("c", False, False)]
    )
  , ( "nested styles accumulate"
    , "\\textbf{a \\textit{b}}"
    , \lowered ->
        visible lowered
          == [("a", True, False), (" ", True, False), ("b", True, True)]
    )
  , ( "a declaration styles the rest of its group and no further"
    , "{\\bfseries a}b"
    , \lowered ->
        visible lowered == [(" ", True, False), ("a", True, False), ("b", False, False)]
    )
  , ( "an escaped character lowers to the character, not its spelling"
    , "\\%x"
    , \lowered -> inlineText lowered == "%x"
    )
  , ( "colour resolves to sRGB"
    , "\\textcolor{red}{x}"
    , \lowered ->
        [ fmap rgbToHex (styleForeground (runStyle run))
        | run <- inlineRuns lowered
        , runKind run == PlainRun
        ]
          == [Just "#ff0000"]
    )
  , ( "an unknown colour is reported and does not stop the lowering"
    , "\\textcolor{chartreuse}{x}"
    , \lowered ->
        inlineText lowered == "x"
          && any isColourIssue (inlineIssues lowered)
    )
  , -- The reader cannot know an unknown macro's arity, so the following group
    -- stays a sibling rather than becoming an argument. The lowering therefore
    -- shows the unknown control sequence as its own source and still renders the
    -- group's content, which is the honest reading: the name is not understood,
    -- the group's text is.
    ( "an unresolved macro shows its own source and is reported"
    , "\\mathbb{R}"
    , \lowered ->
        any
          (\run -> runKind run == OpaqueRun && runText run == "\\mathbb")
          (inlineRuns lowered)
          && inlineText lowered == "\\mathbbR"
          && any isMacroIssue (inlineIssues lowered)
    )
  , ( "a comment renders nothing but is still in the tree"
    , "a% note\n"
    , \lowered ->
        not (Text.isInfixOf "note" (inlineText lowered))
          && Text.isPrefixOf "a" (inlineText lowered)
    )
  , ( "every run carries the dialect that authored it"
    , "\\textbf{x}"
    , \lowered ->
        all
          (\run -> runDialect run == Just Tex)
          [run | run <- inlineRuns lowered, runKind run == PlainRun]
    )
  ]

isColourIssue :: InlineIssue -> Bool
isColourIssue issue = case issue of
  UnresolvableColour _ _ -> True
  _ -> False

isMacroIssue :: InlineIssue -> Bool
isMacroIssue issue = case issue of
  UnexpandedMacro _ _ -> True
  _ -> False

-- Editing: change meaning, keep dialect --------------------------------------

runEdit :: (String, Text, Node -> Either EditError Node, Text) -> IO Bool
runEdit (name, input, edit, expected) =
  case readDocument input of
    Nothing -> do
      putStrLn ("FAIL edit " <> name <> ": did not read")
      pure False
    Just tree ->
      case edit tree of
        Left err -> do
          putStrLn ("FAIL edit " <> name <> ": " <> show err)
          pure False
        Right edited ->
          let printed = printNode edited
           in if printed == expected
                then do
                  putStrLn ("ok   edit " <> name)
                  pure True
                else do
                  putStrLn ("FAIL edit " <> name)
                  putStrLn ("  expected " <> show expected)
                  putStrLn ("  actual   " <> show printed)
                  pure False

atFirst :: (Node -> Bool) -> (Path -> Node -> Either EditError Node) -> Node -> Either EditError Node
atFirst predicate action tree =
  case findPath predicate tree of
    Nothing -> Left (PathNotFound rootPath)
    Just path -> action path tree

editCases :: [(String, Text, Node -> Either EditError Node, Text)]
editCases =
  [ ( "bold a plain run in a LaTeX document"
    , "hello"
    , atFirst isTextNode (\path -> setStyleAt Tex path (SetWeight Bold))
    , "\\textbf{hello}"
    )
  , ( "only the addressed run changes"
    , "a \\textit{b} c"
    , atFirst isTextNode (\path -> setStyleAt Tex path (SetWeight Bold))
    , "\\textbf{a} \\textit{b} c"
    )
  , ( "recolouring keeps the author's command and rewrites only the colour"
    , "\\textcolor{red}{x}"
    , atFirst isStyledNode (\path -> setStyleAt Tex path (SetForeground (ColourName "blue")))
    , "\\textcolor{blue}{x}"
    )
  , ( "a tinted colour is replaced wholesale, not patched"
    , "\\textcolor{red!50}{x}"
    , atFirst isStyledNode (\path -> setStyleAt Tex path (SetForeground (ColourName "teal")))
    , "\\textcolor{teal}{x}"
    )
  , ( "changing a style the spelling asserts re-spells the command"
    , "\\emph{x}"
    , atFirst isStyledNode (\path -> setStyleAt Tex path (SetSlant Upright))
    , "\\textup{x}"
    )
  , ( "setting the value already in effect rewrites nothing"
    , "\\textbf{x}"
    , atFirst isStyledNode (\path -> setStyleAt Tex path (SetWeight Bold))
    , "\\textbf{x}"
    )
  , ( "removing a style unwraps the construct"
    , "a\\textbf{b}c"
    , atFirst isStyledNode (\path -> clearStyleAt path WeightKey)
    , "abc"
    )
  , ( "removing a style the construct does not carry changes nothing"
    , "\\textbf{x}"
    , atFirst isStyledNode (\path -> clearStyleAt path SlantKey)
    , "\\textbf{x}"
    )
  , ( "an edit inside a group leaves the group's braces alone"
    , "{\\bfseries a}"
    , atFirst isTextNode (\path -> setStyleAt Tex path (SetSlant Italic))
    , "{\\bfseries \\textit{a}}"
    )
  ]

editFailures :: [(String, Text, Node -> Either EditError Node)]
editFailures =
  [ -- Plain LaTeX cannot highlight without a package, so the edit is refused
    -- rather than emitting a command the document has not loaded.
    ( "LaTeX cannot spell strikethrough"
    , "x"
    , atFirst isTextNode (\path -> setStyleAt Tex path (SetStrike True))
    )
  , -- Markdown has no markup for small capitals or colour.
    ( "Markdown cannot spell colour"
    , "x"
    , atFirst isTextNode (\path -> setStyleAt Markdown path (SetForeground (ColourName "red")))
    )
  ]

runEditFailure :: (String, Text, Node -> Either EditError Node) -> IO Bool
runEditFailure (name, input, edit) =
  case readDocument input of
    Nothing -> do
      putStrLn ("FAIL edit-reject " <> name <> ": did not read")
      pure False
    Just tree ->
      case edit tree of
        Left _ -> do
          putStrLn ("ok   edit-reject " <> name)
          pure True
        Right edited -> do
          putStrLn
            ( "FAIL edit-reject "
                <> name
                <> ": accepted, produced "
                <> show (printNode edited)
            )
          pure False

-- Commands over ranges --------------------------------------------------------

-- | A point named the way the host names one: by rendered run and offset into it.
pointInRun :: Int -> Int -> Node -> Maybe Point
pointInRun index offset tree =
  case drop index (inlineRuns (flattenInline tree)) of
    run : _ -> Just (Point (runPath run) offset)
    [] -> Nothing

-- | Select from one rendered position to another and apply an effect.
selectAndApply
  :: (Int, Int)
  -> (Int, Int)
  -> Effect
  -> Node
  -> Either CommandError Node
selectAndApply (fromRun, fromOffset) (toRun, toOffset) effect tree =
  case (pointInRun fromRun fromOffset tree, pointInRun toRun toOffset tree) of
    (Just start, Just end) ->
      applyCommand Tex (Command (Between start end) effect) tree
    _ -> Left (CommandTargetNotFound rootPath)

-- | How many items the one list in this input has, or 'Nothing' if there is no
-- list.
--
-- Reprinting a list proves nothing about whether it was read as a list, since text
-- that merely looks like one reprints identically. This counts the structure.
itemCountOf :: Text -> Maybe Int
itemCountOf input =
  case readDocument input of
    Nothing -> Nothing
    Just tree ->
      case [items | (_, found) <- pathsOf tree, Just items <- [listItems found]] of
        [count] -> Just count
        _ -> Nothing
  where
    listItems found =
      case unFix found of
        Items _ _ _ items -> Just (length items)
        _ -> Nothing

-- | Report each list-structure expectation that fails, with what was produced.
reportListStructure :: IO Bool
reportListStructure = do
  let expectations =
        [ ("\n- first\n- second $a^2+b^2=c^2$\n", Just 2)
        , ("\n- a\n- b\n- c\n", Just 3)
        , ("\n1. a\n2. b\n", Just 2)
        , ("\n  - indented\n", Just 1)
        , ("\n- a\nnot an item\n", Just 1)
        , ("a - b", Nothing)
        , ("text a - b more", Nothing)
        , ("2*3*4", Nothing)
        ]
      failures =
        [ show input <> " gave " <> show (itemCountOf input) <> ", wanted " <> show wanted
        | (input, wanted) <- expectations
        , itemCountOf input /= wanted
        ]
  mapM_ (putStrLn . ("  " <>)) failures
  pure (null failures)

-- | Whether the run carrying a word resolves to the expected style.
--
-- Reading a construct and printing it again proves nothing about whether the
-- construct was understood, because unrecognised markup reprints just as faithfully.
-- This asks what a renderer would draw, which is the claim the corpus makes.
styleOfWord :: Text -> Text -> (ResolvedStyle -> Bool) -> Bool
styleOfWord input word expected =
  case readDocument input of
    Nothing -> False
    Just tree ->
      case [run | run <- inlineRuns (flattenInline tree), runText run == word] of
        [found] -> expected (runStyle found)
        _ -> False

-- | Whether some run carries exactly this text.
hasRun :: Text -> Text -> Bool
hasRun input wanted =
  case readDocument input of
    Nothing -> False
    Just tree -> any ((== wanted) . runText) (inlineRuns (flattenInline tree))

isBold :: ResolvedStyle -> Bool
isBold = (== Bold) . styleWeight

isItalic :: ResolvedStyle -> Bool
isItalic = (== Italic) . styleSlant

-- | The dialect table from the node-content format specification.
--
-- Each row is one meaning and how each notation writes it. The table is the
-- contract, so it is checked directly rather than being restated in prose: a
-- spelling that drifts from the specification fails here.
--
-- Underline has no Markdown column and strikethrough has no LaTeX one, which is why
-- those are absent rather than expected to fail; the ladder covers them, and
-- "a property no admissible notation can write is refused" covers the rest.
dialectTable :: [(Dialect, StyleValue, Text)]
dialectTable =
  [ (Markdown, SetWeight Bold, "**x**")
  , (Tex, SetWeight Bold, "\\textbf{x}")
  , (Html, SetWeight Bold, "<b>x</b>")
  , (Markdown, SetSlant Italic, "*x*")
  , (Tex, SetSlant Italic, "\\textit{x}")
  , (Html, SetSlant Italic, "<i>x</i>")
  , (Tex, SetUnderline True, "\\underline{x}")
  , (Html, SetUnderline True, "<u>x</u>")
  , (Markdown, SetHighlight True, "==x==")
  , (Tex, SetHighlight True, "\\hl{x}")
  , (Html, SetHighlight True, "<mark>x</mark>")
  ]

-- | The single character the dialect table is applied to.
plainText :: Node
plainText = node (Text (TexSurface TexChars) "x")

-- | Adding a style with a toggle and toggling it again returns the authored bytes.
--
-- This holds only when nothing in the selection had the property to begin with.
-- Then the first press creates exactly one construct and the second removes that
-- construct, so the bytes come back.
--
-- Toggling is deliberately not an involution in general. Turning a property off
-- removes every assertion of it inside the selection, which is what the author
-- asked for and which discards information: un-italicising @\<em>ab\</em>@ leaves
-- @ab@, and nothing then records that HTML wrote the italic. Exact restoration of
-- an arbitrary edit is history's job, and history restores a source revision
-- rather than replaying an inverse, precisely because an inverse does not exist.
addedStyleIsRemovable :: StyleValue -> Text -> Either String Bool
addedStyleIsRemovable value input =
  case readDocument input of
    Nothing -> Left (show input <> " did not parse")
    Just tree
      -- Applicable only when nothing in the selection has the property. Partly
      -- styled input is a different case: the first press adds the property to
      -- the rest, and the second removes the author's own construct along with
      -- what was added, which is what turning it off means.
      | anyHolds value tree -> Right False
      | otherwise ->
          case selectWhole (ToggleStyle value) tree of
            -- A dialect that cannot spell the property refuses, and the document
            -- is untouched. That is a different law, tested elsewhere.
            Left (CommandUnspellable _ _) -> Right False
            Left failure -> Left (context <> " first press refused: " <> show failure)
            Right once
              | not (selectionHolds value once) ->
                  Left (context <> " did not take effect: " <> show (printNode once))
              | otherwise ->
                  case selectWhole (ToggleStyle value) once of
                    Left failure ->
                      Left (context <> " second press refused: " <> show failure)
                    Right twice
                      | printNode twice == input -> Right True
                      | otherwise ->
                          Left
                            ( context
                                <> " became "
                                <> show (printNode twice)
                                <> " via "
                                <> show (printNode once)
                            )
  where
    context = show input <> " with " <> show value

-- | Turning a property off leaves nothing in the selection asserting it.
--
-- This is the postcondition that makes a toggle honest. Removing the fact from
-- the construct a selection resolves to is not enough, because a descendant may
-- assert it and win: @\textmd{\textbf{ab}}@ is still bold both in LaTeX and on
-- screen.
toggleOffIsComplete :: StyleValue -> Text -> Either String Bool
toggleOffIsComplete value input =
  case readDocument input of
    Nothing -> Left (show input <> " did not parse")
    Just tree
      | not (selectionHolds value tree) -> Right False
      | otherwise ->
          case selectWhole (ToggleStyle value) tree of
            Left failure -> Left (context <> " refused: " <> show failure)
            Right cleared
              | selectionHolds value cleared ->
                  Left
                    ( context
                        <> " still asserts it: "
                        <> show (printNode cleared)
                    )
              | otherwise -> Right True
  where
    context = show input <> " with " <> show value

-- | Whether every rendered character already has a style value.
selectionHolds :: StyleValue -> Node -> Bool
selectionHolds value tree =
  case inlineRuns (flattenInline tree) of
    [] -> False
    runs -> all (styleHolds value . runStyle) runs

-- | Whether any rendered character already has a style value.
anyHolds :: StyleValue -> Node -> Bool
anyHolds value tree = any (styleHolds value . runStyle) (inlineRuns (flattenInline tree))

-- | Inputs and properties the toggle laws are checked over.
toggleSubjects :: [(StyleValue, Text)]
toggleSubjects =
  [ (value, input)
  | input <-
      [ "ab"
      , "\\textbf{ab}"
      , "<em>ab</em>"
      , "<strong>ab</strong>"
      , "a \\textbf{b} c"
      , "\\textbf{a\\textbf{b}}"
      , "\\textbf{\\textit{ab}}"
      , "\\textit{a} b"
      , "<u>ab</u>"
      ]
  , value <-
      [ SetWeight Bold
      , SetSlant Italic
      , SetUnderline True
      , SetStrike True
      ]
  ]

-- | Run a toggle law over every subject, reporting failures and refusing to pass
-- vacuously.
reportToggleLaw :: String -> (StyleValue -> Text -> Either String Bool) -> IO Bool
reportToggleLaw label law = do
  let outcomes = [law value input | (value, input) <- toggleSubjects]
      failures = [reason | Left reason <- outcomes]
      applicable = length [() | Right True <- outcomes]
  mapM_ (putStrLn . ("  " <>)) failures
  if applicable == 0
    then do
      putStrLn ("  " <> label <> " applied to nothing, so it proves nothing")
      pure False
    else pure (null failures)

reportAddedStyleIsRemovable :: IO Bool
reportAddedStyleIsRemovable =
  reportToggleLaw "removability" addedStyleIsRemovable

reportToggleOffIsComplete :: IO Bool
reportToggleOffIsComplete =
  reportToggleLaw "completeness of turning off" toggleOffIsComplete

-- | Select every rendered character and apply an effect.
--
-- Used by the toggle laws, where the question is what a toolbar button does to a
-- whole selection rather than to one construct.
selectWhole :: Effect -> Node -> Either CommandError Node
selectWhole effect tree =
  case unsnoc (inlineRuns (flattenInline tree)) of
    Nothing -> Left (CommandRange RangeEmpty)
    Just (_, finalRun) ->
      case pointInRun 0 0 tree of
        Nothing -> Left (CommandRange RangeEmpty)
        Just start ->
          applyCommand
            Tex
            ( Command
                (Between start (Point (runPath finalRun) (Text.length (runText finalRun))))
                effect
            )
            tree

commandCases :: [(String, Text, Node -> Either CommandError Node, Text)]
commandCases =
  [ ( "styling part of a run divides it and wraps only that part"
    , "Bold"
    , selectAndApply (0, 0) (0, 2) (SetStyle (SetWeight Bold))
    , "\\textbf{Bo}ld"
    )
  , ( "styling everything wraps once"
    , "Bold"
    , selectAndApply (0, 0) (0, 4) (SetStyle (SetWeight Bold))
    , "\\textbf{Bold}"
    )
  , ( "a range covering a whole construct wraps the construct, not its children"
    , "\\textit{a b}c"
    , selectAndApply (0, 0) (2, 1) (SetStyle (SetWeight Bold))
    , "\\textbf{\\textit{a b}}c"
    )
  , ( "constructs this edit created are merged"
    , "\\textit{a}bc"
    , selectAndApply (0, 0) (1, 1) (SetStyle (SetWeight Bold))
    , "\\textbf{\\textit{a}b}c"
    )
  , ( "a range crossing two constructs styles each covered part"
    , "\\textbf{Bo}ld"
    , selectAndApply (0, 1) (1, 1) (SetStyle (SetSlant Italic))
    , "\\textbf{B\\textit{o}}\\textit{l}d"
    )
  , ( "recolouring keeps the author's own command and rewrites its argument"
    , "\\textcolor{red}{x}y"
    , selectAndApply (0, 0) (0, 1) (SetStyle (SetForeground (ColourName "blue")))
    , "\\textcolor{blue}{x}y"
    )
  , ( "toggling a property nothing in the selection has sets it"
    , "ab"
    , selectWhole (ToggleStyle (SetWeight Bold))
    , "\\textbf{ab}"
    )
  , ( "toggling a property everything in the selection has removes it"
    , "\\textbf{ab}"
    , selectWhole (ToggleStyle (SetWeight Bold))
    , "ab"
    )
  , ( "toggling a partly styled selection styles all of it"
    , "\\textbf{a}b"
    , selectWhole (ToggleStyle (SetWeight Bold))
    , "\\textbf{\\textbf{a}b}"
    )
  , ( "a toggle around HTML content is written in HTML, there being no root dialect"
    , "<em>ab</em>"
    , selectWhole (ToggleStyle (SetUnderline True))
    , "<u><em>ab</em></u>"
    )
  , ( "a toggle inside an HTML element is written in HTML"
    , "<em>ab</em>"
    , selectAndApply (0, 0) (0, 1) (ToggleStyle (SetUnderline True))
    , "<em><u>a</u>b</em>"
    )
  , ( "toggling off removes the property from nested constructs too"
    , "\\textbf{a\\textbf{b}}"
    , selectWhole (ToggleStyle (SetWeight Bold))
    , "ab"
    )
  , ( "toggling off leaves other properties of the same construct alone"
    , "\\textbf{\\textit{ab}}"
    , selectWhole (ToggleStyle (SetWeight Bold))
    , "\\textit{ab}"
    )
  , ( "toggling off an inherited property states the opposing value"
    , "\\textbf{ab}"
    , selectAndApply (0, 0) (0, 1) (ToggleStyle (SetWeight Bold))
    , "\\textbf{\\textmd{a}b}"
    )
  , ( "clearing a fact the construct carries removes the command with it"
    , "\\textbf{x}"
    , \tree -> case findPath isStyledNode tree of
        Nothing -> Left (CommandTargetNotFound rootPath)
        Just path -> applyCommand Tex (Command (At path) (ClearStyle WeightKey)) tree
    , "x"
    )
  , ( "clearing an inherited fact states the opposing value instead"
    , "\\textbf{ab}"
    , selectAndApply (0, 0) (0, 1) (ClearStyle WeightKey)
    , "\\textbf{\\textmd{a}b}"
    )
  , ( "bare text commits to no notation, so the theme default decides"
    , "x"
    , \tree -> case findPath isTextNode tree of
        Nothing -> Left (CommandTargetNotFound rootPath)
        Just path ->
          -- Nothing encloses it and "x" is the same bytes in every notation, so
          -- there is nothing to inherit and the theme setting is consulted.
          applyCommand Markdown (Command (At path) (SetStyle (SetWeight Bold))) tree
    , "**x**"
    )
  , ( "the same text under a different theme default is written differently"
    , "x"
    , \tree -> case findPath isTextNode tree of
        Nothing -> Left (CommandTargetNotFound rootPath)
        Just path ->
          applyCommand Tex (Command (At path) (SetStyle (SetWeight Bold))) tree
    , "\\textbf{x}"
    )
  , ( "an enclosing LaTeX construct overrides the theme default"
    , "\\textit{x}"
    , \tree -> case findPath isTextNode tree of
        Nothing -> Left (CommandTargetNotFound rootPath)
        Just path ->
          applyCommand Markdown (Command (At path) (SetStyle (SetWeight Bold))) tree
    , "\\textit{\\textbf{x}}"
    )
  , ( "an enclosing HTML element overrides the theme default"
    , "<em>x</em>"
    , \tree -> case findPath isTextNode tree of
        Nothing -> Left (CommandTargetNotFound rootPath)
        Just path ->
          applyCommand Markdown (Command (At path) (SetStyle (SetWeight Bold))) tree
    , "<em><b>x</b></em>"
    )
  , ( "uniform content settles the notation when nothing encloses it"
    , "<em>a</em> <em>b</em>"
    , selectWhole (SetStyle (SetWeight Bold))
    , "<b><em>a</em> <em>b</em></b>"
    )
  , ( "a property LaTeX cannot spell falls back to a notation that can"
    , "\\textbf{ab}"
    , selectAndApply (0, 0) (0, 2) (SetStyle (SetStrike True))
      -- Selecting the whole construct covers the construct, so the strike wraps
      -- it; LaTeX has no strikethrough, so HTML supplies the spelling.
    , "<s>\\textbf{ab}</s>"
    )
  , ( "an edit on an HTML construct is written as HTML"
    , "<strong>x</strong>y"
    , selectAndApply (0, 0) (0, 1) (SetStyle (SetSlant Italic))
    , "<i><strong>x</strong></i>y"
    )
  , ( "an edit on a LaTeX construct is written as LaTeX"
    , "\\textbf{x}y"
    , selectAndApply (0, 0) (0, 1) (SetStyle (SetSlant Italic))
    , "\\textit{\\textbf{x}}y"
    )
  , ( "part of an HTML element's text is wrapped in HTML"
    , "<em>ab</em>"
    , selectAndApply (0, 0) (0, 1) (SetStyle (SetWeight Bold))
    , "<em><b>a</b>b</em>"
    )
  , -- One selection, two dialects, and the two new constructs are adjacent
    -- siblings that must not be merged because they are spelled differently.
    ( "both dialects are edited in one document, each in its own spelling"
    , "\\textbf{a}<em>b</em>c"
    , selectAndApply (0, 0) (1, 1) (SetStyle (SetUnderline True))
    , "\\underline{\\textbf{a}}<u><em>b</em></u>c"
    )
  , ( "an HTML element keeps the style properties this model does not know"
    , "<span style=\"color: #ff0000; font-size: 2em\">x</span>y"
    , selectAndApply (0, 0) (0, 1) (SetStyle (SetWeight Bold))
    , "<b><span style=\"color: #ff0000; font-size: 2em\">x</span></b>y"
    )
  , ( "recolouring an HTML span rewrites the declaration and keeps its neighbour"
    , "<span style=\"color: #ff0000; font-size: 2em\">x</span>y"
    , selectAndApply (0, 0) (0, 1) (SetStyle (SetForeground (ColourName "blue")))
    , "<span style=\"color: blue; font-size: 2em\">x</span>y"
    )
  , ( "colouring HTML content writes a CSS declaration"
    , "<em>x</em>y"
    , selectAndApply (0, 0) (0, 1) (SetStyle (SetForeground (ColourName "green")))
    , "<span style=\"color: green;\"><em>x</em></span>y"
    )
  , ( "a computed colour is resolved to sRGB, because CSS cannot mix"
    , "<em>x</em>y"
    , selectAndApply
        (0, 0)
        (0, 1)
        (SetStyle (SetForeground (ColourTint (ColourName "blue") (Literal 40 "40"))))
    , "<span style=\"color: #9999ff;\"><em>x</em></span>y"
    )
  ]

runCommand :: (String, Text, Node -> Either CommandError Node, Text) -> IO Bool
runCommand (name, input, command, expected) =
  case readDocument input of
    Nothing -> do
      putStrLn ("FAIL command " <> name <> ": did not read")
      pure False
    Just tree ->
      case command tree of
        Left failure -> do
          putStrLn ("FAIL command " <> name <> ": refused with " <> show failure)
          pure False
        Right edited ->
          let actual = printNode edited
           in if actual == expected
                then do
                  putStrLn ("ok   command " <> name)
                  pure True
                else do
                  putStrLn ("FAIL command " <> name)
                  putStrLn ("  expected: " <> show expected)
                  putStrLn ("  actual:   " <> show actual)
                  pure False

commandFailures :: [(String, Text, Node -> Either CommandError Node, CommandError)]
commandFailures =
  [ ( "a property no admissible notation can write is refused"
    , "x"
    , -- Nothing has markup meaning "not highlighted": LaTeX has none, and HTML has
      -- no way to cancel a <mark> from outside it either. Asserting a highlight is
      -- possible, so this is the ladder being exhausted rather than a dialect being
      -- excluded on principle.
      selectAndApply (0, 0) (0, 1) (SetStyle (SetHighlight False))
    , CommandUnspellable Tex HighlightKey
    )
  , ( "an inherited colour cannot be cleared, because nothing says what it becomes"
    , "\\textcolor{red}{ab}"
    , selectAndApply (0, 0) (0, 1) (ClearStyle ForegroundKey)
    , CommandNotClearable ForegroundKey
    )
  , ( "an empty selection is refused"
    , "abc"
    , selectAndApply (0, 1) (0, 1) (SetStyle (SetWeight Bold))
    , CommandRange RangeEmpty
    )
  , ( "a boundary inside a construct that is not plain text cannot be divided"
    , "$x+y$"
    , selectAndApply (0, 1) (0, 2) (SetStyle (SetWeight Bold))
    , CommandRange (RangeNotSplittable (pathFromList [0]))
    )
  ]

runCommandFailure
  :: (String, Text, Node -> Either CommandError Node, CommandError) -> IO Bool
runCommandFailure (name, input, command, expected) =
  case readDocument input of
    Nothing -> do
      putStrLn ("FAIL command-reject " <> name <> ": did not read")
      pure False
    Just tree ->
      case command tree of
        Left failure
          | failure == expected -> do
              putStrLn ("ok   command-reject " <> name)
              pure True
          | otherwise -> do
              putStrLn ("FAIL command-reject " <> name)
              putStrLn ("  expected: " <> show expected)
              putStrLn ("  actual:   " <> show failure)
              pure False
        Right edited -> do
          putStrLn
            ( "FAIL command-reject "
                <> name
                <> ": accepted, produced "
                <> show (printNode edited)
            )
          pure False

-- Commands on mixed-dialect trees ---------------------------------------------

-- | Markdown containing one word, so an edit inside it has a Markdown context.
--
-- Built by hand rather than read, because no Markdown reader exists yet. That
-- limits where mixed input can come from, not what the model can represent or
-- edit.
markdownWord :: Node
markdownWord =
  node
    ( Styled
        (styleMapFromList [SetWeight Bold])
        (MarkdownSurface (MdDelimited "**"))
        [node (Text (MarkdownSurface MdChars) "x")]
    )

mixedCommandCases :: [(String, Node, Node -> Either CommandError Node, Text)]
mixedCommandCases =
  [ ( "an edit inside Markdown is written in Markdown"
    , markdownWord
    , \tree -> applyCommand Tex (Command (At rootPath) (SetStyle (SetSlant Italic))) tree
    , "***x***"
    )
  , ( "Markdown falls to the HTML it hosts for a style it cannot write"
    , markdownWord
    , \tree -> applyCommand Tex (Command (At rootPath) (SetStyle (SetUnderline True))) tree
    , "<u>**x**</u>"
    )
  , ( "the ambient dialect is ignored when the tree settles the question"
    , markdownWord
    , \tree ->
        applyCommand Markdown (Command (At rootPath) (SetStyle (SetWeight Bold))) tree
    , "**x**"
    )
  ]

-- Mixed LaTeX and HTML read from real input -----------------------------------

-- | Both dialects nest inside one another, in either order, from text.
mixedRoundTrip :: [(String, Text)]
mixedRoundTrip =
  [ ("html bold", "<strong>bold</strong>")
  , ("html and tex side by side", "<em>a</em> and \\textbf{b}")
  , ("html inside tex", "\\textbf{outer <em>inner</em> after}")
  , ("tex inside html", "<strong>outer \\textit{inner} after</strong>")
  , ("hex colour in a style attribute", "<span style=\"color: #ff0000\">red</span>")
  , ("unsupported css property preserved", "<span style=\"color:#00f;font-size:2em\">kept</span>")
  , ("both colour spellings together", "\\textcolor{red}{tex} <span style='color: blue'>html</span>")
  , ("three nested html styles", "<u><s><code>three</code></s></u>")
  , ("a bare angle bracket is text", "a < b")
  , ("angles around digits", "5<6 and 7>8")
  , ("an unclosed tag is text", "<em>unclosed")
  , ("a stray close tag is text", "</em>")
  , ("a void element", "<br/>x")
  , ("a link", "<a href=\"#t\">link</a>")
  , ("an unknown element keeps its children", "<unknown attr>kept</unknown>")
  , ("character references", "&amp; &lt; &unknown;")
  , ("highlight", "<mark>hl</mark>")
  , ("a tex declaration inside html", "<span>{\\bfseries g}</span>")
  , ("a tex group inside html", "<em>{a}</em>")
  , ("a style attribute inside a tex command", "\\textbf{<span style=\"color: green\">deep</span>}")
    -- Markdown, written directly in content with nothing declaring a region.
  , ("markdown strong", "**bold**")
  , ("markdown strong with underscores", "__bold__")
  , ("markdown emphasis", "*italic*")
  , ("markdown emphasis with an underscore", "_italic_")
  , ("markdown strikethrough", "~~gone~~")
  , ("markdown highlight", "==lit==")
  , ("markdown code span", "`literal`")
  , ("markdown code span with a longer fence", "``has ` inside``")
  , ("markdown link", "[text](https://example.com)")
    -- Delimiters that must not become emphasis.
  , ("an underscore inside a word is part of the word", "snake_case_name")
  , ("a lone asterisk between spaces is a character", "a * b")
    -- CommonMark allows an asterisk to emphasise inside a word while forbidding an
    -- underscore, so this is emphasis and only its bytes are asserted here.
  , ("an asterisk inside a word does emphasise, and still reprints", "2*3*4")
  , ("an unclosed delimiter is text", "**unclosed")
  , ("an empty delimiter run is text", "****")
  , ("a delimiter followed by a space opens nothing", "** not emphasis")
    -- All three notations at once, and each nested in the others.
  , ("all three notations in one line", "**md** \\textbf{tex} <em>html</em>")
  , ("markdown inside a latex command", "\\textbf{a **b** c}")
  , ("latex inside markdown", "**a \\textit{b} c**")
  , ("markdown inside an html element", "<em>a **b** c</em>")
  , ("html inside markdown", "**a <em>b</em> c**")
  , ("markdown nested in markdown", "**a *b* c**")
    -- The normative corpus from the node-content format specification. Its own
    -- statement is that canonical input round-trips byte for byte.
  , ("corpus 1: markdown in text", "Hello **world**")
  , ("corpus 2: three notations in one line", "Mix \\textbf{bold}, **md**, and <i>it</i>")
  , ("corpus 3: inline math is opaque", "Euler $e^{i\\pi}+1=0$ done")
  , ( "corpus 5: html wrapping a latex list whose item carries markdown"
    , "<div>\\begin{itemize}\\item bold **text**\\item plain\\end{itemize}</div>"
    )
  , ("corpus 6: an out-of-subset construct is still preserved", "\\usetikzlibrary{calc} hi")
  , ( "corpus 4: a list framed by the newlines around it"
    , "\n- first\n- second $a^2+b^2=c^2$\n"
    )
    -- Lists, whose markers and numbering are retained as written.
  , ("a bullet list keeps its marker", "\n- a\n- b\n")
  , ("a starred bullet list keeps its marker", "\n* a\n* b\n")
  , ("an ordered list keeps its own numbering", "\n1. a\n2. b\n")
  , ("a list with markdown inside an item", "\n- **bold** item\n- plain\n")
  , ("a list with latex inside an item", "\n- \\textbf{bold} item\n")
  , ("a list item indent is retained", "\n  - indented\n")
  , ("a dash mid-sentence is not a list", "a - b")
  , ("a dash mid-line after text is not a list", "text a - b more")
  , ("a list ends where the markers stop", "\n- a\nnot an item\n")
  ]

-- | Reading mixed input and printing it must reproduce it exactly, or the source
-- would not be preserved across an edit elsewhere in the document.
mixedReadCases :: [(String, Text, [(Dialect, Text)])]
mixedReadCases =
  [ ( "an HTML tag becomes the same style fact a LaTeX command would"
    , "<strong>x</strong>"
    , [(Html, "x")]
    )
  , ( "each construct keeps its own dialect when they are nested"
    , "\\textbf{a<em>b</em>}"
    , [(Tex, "a"), (Html, "b")]
    )
  , ( "a style attribute becomes a fact without discarding the rest"
    , "<span style=\"color: #ff0000; font-size: 2em\">x</span>"
    , [(Html, "x")]
    )
  , ( "Markdown delimiters become the same fact the other notations carry"
    , "**x**"
    , [(Markdown, "x")]
    )
  , ( "each notation keeps its own when all three nest"
    , "\\textbf{a**b**<em>c</em>}"
    , [(Tex, "a"), (Markdown, "b"), (Html, "c")]
    )
  ]

runMixedRead :: (String, Text, [(Dialect, Text)]) -> IO Bool
runMixedRead (name, input, expected) =
  case readDocument input of
    Nothing -> do
      putStrLn ("FAIL mixed-read " <> name <> ": did not read")
      pure False
    Just tree ->
      let actual =
            [ (dialect, runText run)
            | run <- inlineRuns (flattenInline tree)
            , Just dialect <- [runDialect run]
            , not (Text.null (Text.strip (runText run)))
            ]
       in if actual == expected
            then do
              putStrLn ("ok   mixed-read " <> name)
              pure True
            else do
              putStrLn ("FAIL mixed-read " <> name)
              putStrLn ("  expected: " <> show expected)
              putStrLn ("  actual:   " <> show actual)
              pure False

runMixedCommand :: (String, Node, Node -> Either CommandError Node, Text) -> IO Bool
runMixedCommand (name, tree, command, expected) =
  case command tree of
    Left failure -> do
      putStrLn ("FAIL mixed " <> name <> ": refused with " <> show failure)
      pure False
    Right edited ->
      let actual = printNode edited
       in if actual == expected
            then do
              putStrLn ("ok   mixed " <> name)
              pure True
            else do
              putStrLn ("FAIL mixed " <> name)
              putStrLn ("  expected: " <> show expected)
              putStrLn ("  actual:   " <> show actual)
              pure False

-- Structural laws about the machinery itself ----------------------------------

structuralCases :: [(String, IO Bool)]
structuralCases =
  [ ( "a list is read as a list, and a dash in a sentence is not"
    , reportListStructure
    )
  , ( "the corpus means what the specification says it means"
    , pure
        ( and
            [ styleOfWord "Mix \\textbf{bold}, **md**, and <i>it</i>" "bold" isBold
            , styleOfWord "Mix \\textbf{bold}, **md**, and <i>it</i>" "md" isBold
            , styleOfWord "Mix \\textbf{bold}, **md**, and <i>it</i>" "it" isItalic
            , -- Corpus 5: three notations nested, the innermost being Markdown
              -- inside a LaTeX item inside an HTML container.
              styleOfWord
                "<div>\\begin{itemize}\\item bold **text**\\item plain\\end{itemize}</div>"
                "text"
                isBold
            , -- Corpus 3: math is opaque, so its body is one unparsed run.
              hasRun "Euler $e^{i\\pi}+1=0$ done" "e^{i\\pi}+1=0"
            ]
        )
    )
  , ( "the format's dialect table is what a new construct is spelled with"
    , pure
        ( and
            [ fmap printNode (setStyleAt dialect rootPath value (document [plainText]))
                == Right expected
            | (dialect, value, expected) <- dialectTable
            ]
        )
    )
  , ( "a style a toggle added can be removed exactly"
    , reportAddedStyleIsRemovable
    )
  , ( "toggling a property off leaves nothing in the selection asserting it"
    , reportToggleOffIsComplete
    )
  , ( "preparing a selection changes no bytes"
    , pure
        ( all
            preparePreservesBytes
            [ "Bold"
            , "\\textbf{Bo}ld"
            , "\\textit{a}bc"
            , "a \\textbf{b} c"
            , "x\\%y"
            ]
        )
    )
  , ( "setting the children a node already has returns that node"
    , pure
        ( all
            primaryChildrenIdentity
            [ "\\textbf{a}"
            , "\\textit{a b}"
            , "a b c"
            , "\\underline{x}"
            ]
        )
    )
  , ( "styles-in-place agrees with what setting a style does"
    , pure
        ( all
            inPlaceAgrees
            [ "\\textbf{x}"
            , "\\textit{x}"
            , "x"
            , "\\textcolor{red}{x}"
            ]
        )
    )
  , ( "a hosting ladder always offers the enclosing dialect first"
    , pure
        ( and
            [ case hostedDialects dialect of
                first : _ -> first == dialect
                [] -> False
            | dialect <- [minBound .. maxBound]
            ]
        )
    )
  , ( "an edit's meaning survives being written out and read back"
    , pure
        ( all
            editSurvivesRoundTrip
            [ ("Bold", (0, 0), (0, 2), SetStyle (SetWeight Bold))
            , ("\\textit{a}bc", (0, 0), (1, 1), SetStyle (SetWeight Bold))
            , ("a \\textbf{b} c", (0, 0), (2, 1), SetStyle (SetSlant Italic))
            ]
        )
    )
  , ( "no edit can reach inside a macro expansion"
    , pure noEditInsideExpansion
    )
  ]

-- | Expansion is a reading of the document, not part of it, so there is no source
-- inside one to change. Every path that enters an expansion must be refused, and
-- there must be such paths or the law would be vacuous.
noEditInsideExpansion :: Bool
noEditInsideExpansion =
  case expandedDocument "\\newcommand{\\hi}{hello}\\hi" of
    Nothing -> False
    Just expanded ->
      let inside =
            [ path
            | (path, _) <- pathsOf expanded
            , pathEntersExpansion path expanded
            ]
       in not (null inside)
            && all
              ( \path ->
                  case applyCommand
                    Tex
                    (Command (At path) (SetStyle (SetWeight Bold)))
                    expanded of
                    Left (CommandInsideExpansion refused) -> refused == path
                    _ -> False
              )
              inside

-- | Read and expand, so the tree contains an expansion to test against.
expandedDocument :: Text -> Maybe Node
expandedDocument input =
  case readTex input of
    Left _ -> Nothing
    Right nodes ->
      case expandTex nodes of
        Left _ -> Nothing
        Right expanded -> Just (document expanded)

-- | Splitting text nodes must be invisible, or a refused edit could still have
-- altered the document.
preparePreservesBytes :: Text -> Bool
preparePreservesBytes input =
  case readDocument input of
    Nothing -> False
    Just tree ->
      let before = printNode tree
          extents = runExtents tree
          total = maybe 0 snd (extentOf extents rootPath)
       in and
            [ case prepareSelection start end tree of
                Left _ -> True -- refusing is allowed; changing bytes is not
                Right prepared -> printNode prepared == before
            | start <- [0 .. total]
            , end <- [start .. total]
            ]

-- | The child order 'setPrimaryChildren' writes must be the one every traversal
-- reads.
primaryChildrenIdentity :: Text -> Bool
primaryChildrenIdentity input =
  case readDocument input of
    Nothing -> False
    Just tree ->
      all
        ( \(_, subtree) ->
            case setPrimaryChildren (toList (unFix subtree)) subtree of
              Nothing -> True -- declined, which is a different claim
              Just rebuilt -> rebuilt == subtree
        )
        (pathsOf tree)

-- | The predicate a caller uses to tell created constructs from rewritten ones
-- must match what the edit actually did.
inPlaceAgrees :: Text -> Bool
inPlaceAgrees input =
  case readDocument input of
    Nothing -> False
    Just tree ->
      all
        ( \(path, subtree) ->
            case setStyleAt Tex path (SetWeight Bold) tree of
              Left _ -> True
              Right edited ->
                case resolvePath path edited of
                  Nothing -> False
                  Just after ->
                    let wrapped = case unFix after of
                          Styled _ _ [only] -> only == subtree
                          _ -> False
                     in stylesInPlace WeightKey subtree /= wrapped
        )
        (pathsOf tree)

-- | Source is authoritative, so what an edit means is whatever reading its output
-- back produces. Trees differ by text divisions the printer cannot show; the runs
-- a renderer would draw must not.
editSurvivesRoundTrip :: (Text, (Int, Int), (Int, Int), Effect) -> Bool
editSurvivesRoundTrip (input, from, to, effect) =
  case readDocument input of
    Nothing -> False
    Just tree ->
      case selectAndApply from to effect tree of
        Left _ -> False
        Right edited ->
          case readDocument (printNode edited) of
            Nothing -> False
            Just reread ->
              fmap
                withoutPaths
                (inlineRuns (coalesceRuns (flattenInline edited)))
                == fmap
                  withoutPaths
                  (inlineRuns (coalesceRuns (flattenInline reread)))
  where
    -- Paths legitimately differ: the edited tree still carries its divisions,
    -- while a fresh read has none. Everything a renderer acts on must agree.
    withoutPaths run =
      (runKind run, runText run, runStyle run, runDialect run, runLink run)

checkStructural :: (String, IO Bool) -> IO Bool
checkStructural (name, check) = do
  held <- check
  if held
    then do
      putStrLn ("ok   structure " <> name)
      pure True
    else do
      putStrLn ("FAIL structure " <> name)
      pure False
