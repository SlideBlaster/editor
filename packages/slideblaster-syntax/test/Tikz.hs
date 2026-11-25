{-# LANGUAGE OverloadedStrings #-}

-- Laws of the TikZ reader, and a run over a corpus of real pictures when
-- SB_TIKZ_CORPUS names folders of .tex and .tikz files (separated by colons).
module Main (main) where

import SlideBlaster.Syntax.Tikz.Ast
import SlideBlaster.Syntax.Tikz.Edit
import SlideBlaster.Syntax.Tikz.Eval
import SlideBlaster.Syntax.Tikz.Math
import SlideBlaster.Syntax.Tikz.Parse

import Control.Monad (forM, unless, when)
import Data.Char (isSpace)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.ByteString qualified as ByteString
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hSetEncoding, stdout, utf8)

slice :: Text -> Span -> Text
slice source (Span a b) = Text.take (b - a) (Text.drop a source)

itemsOf :: Text -> [Item]
itemsOf source = let Picture _ found = parsePicture 0 source in found

opsOf :: Text -> [PathOp]
opsOf source = case itemsOf source of
  [ItemPath command] -> pathOps command
  other -> error ("not one path: " <> show other)

-- Every statement in a picture, however deep.
allItems :: Picture -> [Item]
allItems (Picture _ found) = concatMap deep found
  where
    deep item = item : case item of
      ItemScope _ _ inner -> allItems inner
      ItemForeach _ _ inner -> allItems inner
      ItemLayer _ _ inner -> allItems inner
      ItemOverlay _ _ _ inner -> allItems inner
      _ -> []

-- The statements of a picture cover its text: in order, without overlap, and
-- only blank space between them.
covers :: Text -> Picture -> Maybe Text
covers source (Picture (Span start end) found) = go start found
  where
    go at list =
      case list of
        [] -> gap at end
        item : more ->
          let Span a b = itemSpan item
           in if a < at || b < a || b > end
                then Just ("span out of order at " <> Text.pack (show (a, b)))
                else case gap at a of
                  Just problem -> Just problem
                  Nothing -> case inner item of
                    Just problem -> Just problem
                    Nothing -> go b more
    gap a b = let between = slice source (Span a b) in if Text.all isSpace between then Nothing else Just ("text between statements: " <> Text.take 40 (Text.strip between))
    inner item = case item of
      ItemScope _ _ picture -> covers source picture
      ItemForeach _ _ picture -> covers source picture
      ItemLayer _ _ picture -> covers source picture
      ItemOverlay _ _ _ picture -> covers source picture
      _ -> Nothing

laws :: [(String, Bool)]
laws =
  [ ( "a line between two nodes"
    , case opsOf "\\draw[->, thick] (a) -- (b.north);" of
        [OpOptions _ (Options _ [Option _ "->" Nothing Nothing, Option _ "thick" Nothing Nothing]), OpMove _ (Coordinate _ Absolute Nothing (CoordNode "a" Nothing) "a"), OpLine _ JoinLine [] (TargetAt (Coordinate _ Absolute Nothing (CoordNode "b" (Just "north")) _))] -> True
        _ -> False
    )
  , ( "labels stand between a join and its target; a node after the target is its own operation"
    , case opsOf "\\draw (0,0) -| node[above] {x} coordinate (m) (2,1) node {end};" of
        [OpMove _ _, OpLine _ JoinHV [OpNode first, OpNode second] (TargetAt _), OpNode third] ->
          fmap (\(Braced _ t) -> t) (nodeText first) == Just "x" && nodeKind second == KindCoordinate && nodeName second == Just "m" && fmap (\(Braced _ t) -> t) (nodeText third) == Just "end"
        _ -> False
    )
  , ( "the parts of a node come in any order"
    , case itemsOf "\\node (a) [draw] at (1,2) [fill=red!20] {A $x_1$};" of
        [ItemPath PathCommand {pathCommand = "node", pathOps = [OpNode node]}] ->
          nodeName node == Just "a"
            && fmap coordBody (nodeAt node) == Just (CoordXY "1" "2")
            && fmap optionKey (nodeOptions node) == ["draw", "fill"]
            && [t | Option _ "fill" _ (Just (Value _ t)) <- nodeOptions node] == ["red!20"]
        _ -> False
    )
  , ( "every form of coordinate"
    , fmap (fmap coordBody . parseCoordinate 0)
        [ "(1cm,2pt)", "+(30:1)", "++(0,0,1)", "(a.south west)", "($(a)!0.5!(b)$)", "(a |- b.north)", "(1,2 -| c)"
        , "(canvas cs:x=1cm,y=2)", "(intersection of a--b and c--d)", "([xshift=2pt]a.east)", "(north:1 and 2)", "({1+2},{sin(30)})", "(a.30)", "\\p"
        ]
        == fmap Right
          [ CoordXY "1cm" "2pt", CoordPolar "30" "1" Nothing, CoordXYZ "0" "0" "1", CoordNode "a" (Just "south west"), CoordCalc "(a)!0.5!(b)"
          , CoordVH (CoordNode "a" Nothing) (CoordNode "b" (Just "north")), CoordHV (CoordXY "1" "2") (CoordNode "c" Nothing)
          , CoordSystem "canvas" (parseOptions 11 "x=1cm,y=2"), CoordIntersection "intersection of a--b and c--d", CoordNode "a" (Just "east"), CoordPolar "north" "1" (Just "2")
          , CoordXY "{1+2}" "{sin(30)}", CoordNode "a" (Just "30"), CoordMacro "p"
          ]
    )
  , ( "relative coordinates and options inside one are kept"
    , fmap (\c -> (coordRelative c, fmap (\(Options _ o) -> fmap optionKey o) (coordOptions c))) (parseCoordinate 0 "++([xshift=2pt, yshift=1pt] a)") == Right (RelativeMove, Just ["xshift", "yshift"])
    )
  , ( "options split at commas outside braces; a value loses one pair of braces; handlers are told apart"
    , case parseOptions 0 "draw, fill = {red!20},  minimum  width=2cm, box/.style={draw, rounded corners}, every node/.append style={font=\\small}, ->, label={[red]above:x, y}" of
        Options _ found ->
          fmap (\o -> (optionKey o, optionHandler o, fmap (\(Value _ t) -> t) (optionValue o))) found
            == [ ("draw", Nothing, Nothing), ("fill", Nothing, Just "red!20"), ("minimum width", Nothing, Just "2cm"), ("box", Just "style", Just "draw, rounded corners")
               , ("every node", Just "append style", Just "font=\\small"), ("->", Nothing, Nothing), ("label", Nothing, Just "[red]above:x, y")
               ]
    )
  , ( "curves, arcs, circles, rectangles, grids and cycles"
    , case opsOf "\\filldraw (0,0) .. controls (1,1) and (2,1) .. (3,0) arc (0:90:1cm) arc[start angle=0, end angle=90, radius=1] circle (2pt) circle[radius=1] ellipse (1 and 2) rectangle +(1,1) grid[step=.5] (3,3) -- cycle;" of
        [OpMove _ _, OpCurve _ _ (Just _) [] (TargetAt _), OpArc _ (ArcOld "0" "90" "1cm"), OpArc _ (ArcKeys (Options _ [_, _, _])), OpCircle _ (RoundOld "2pt"), OpCircle _ (RoundKeys (Just _)), OpEllipse _ (RoundOld "1 and 2"), OpRectangle _ [] (TargetAt Coordinate {coordRelative = RelativeStay}), OpGrid _ (Just _) (TargetAt _), OpLine _ JoinLine [] (TargetCycle _)] -> True
        _ -> False
    )
  , ( "to and edge take options, labels and a target"
    , case opsOf "\\path (a) to[bend left=30] node[auto] {x} (b) edge[->] node {y} (c) edge[loop above] ();" of
        [OpMove _ _, OpTo _ [Options _ [Option _ "bend left" Nothing (Just (Value _ "30"))]] [OpNode _] (TargetAt _), OpEdge _ [_] [OpNode _] (TargetAt _), OpEdge _ [_] [] (TargetAt Coordinate {coordBody = CoordNode "" Nothing})] -> True
        _ -> False
    )
  , ( "foreach in a path and as a statement, with several variables and options"
    , ( case opsOf "\\draw (0,0) \\foreach \\x in {1,2,3} { -- (\\x,0) } foreach \\a/\\b [count=\\i] in \\list { -- (\\a,\\b) };" of
          [OpMove _ _, OpForeach _ Foreach {foreachVariables = "\\x", foreachList = Braced _ "1,2,3"} [OpLine {}], OpForeach _ Foreach {foreachVariables = "\\a/\\b", foreachOptions = Just _, foreachList = Braced _ "\\list"} [OpLine {}]] -> True
          _ -> False
      , case itemsOf "\\foreach \\x in {0,...,3}\n  \\foreach \\y in {0,1} {\n    \\node at (\\x,\\y) {};\n  }" of
          [ItemForeach _ _ (Picture _ [ItemForeach _ _ (Picture _ [ItemPath _])])] -> True
          _ -> False
      )
        == (True, True)
    )
  , ( "scopes, layers, sets and styles hold statements and options"
    , case itemsOf "\\begin{scope}[shift={(1,2)}, rotate=30]\n  \\draw (0,0) -- (1,1);\n  \\begin{scope}\\fill (0,0) circle (1pt);\\end{scope}\n\\end{scope}\n\\begin{pgfonlayer}{background}\\node {x};\\end{pgfonlayer}\n\\tikzset{box/.style={draw}}\n\\tikzstyle{old}=[draw,thick]\n\\scoped[red] \\draw (0,0) -- (1,0);" of
        [ItemScope _ (Just (Options _ [Option _ "shift" Nothing (Just (Value _ "(1,2)")), _])) (Picture _ [ItemPath _, ItemScope _ Nothing (Picture _ [ItemPath _])]), ItemLayer _ "background" (Picture _ [ItemPath _]), ItemSet _ (Options _ [Option _ "box" (Just "style") _]), ItemStyle _ "old" False (Options _ [_, _]), ItemScope _ (Just _) (Picture _ [ItemPath _])] -> True
        _ -> False
    )
  , ( "what is not a picture statement is kept as a command with its arguments"
    , case itemsOf "% a comment\n\\def\\r#1{2#1}\n\\pgfmathsetmacro{\\a}{3*\\r}\n\\usetikzlibrary{calc, positioning}\n\\cat[shift={(1,-1)}]{figures/a.tikz};\n\\newcommand{\\box}[2][red]{\\node[#1] {#2};}" of
        [ItemComment _, ItemCommand _ "def" [Braced _ "\\r", Braced _ "#1", Braced _ "2#1"], ItemCommand _ "pgfmathsetmacro" [Braced _ "\\a", Braced _ "3*\\r"], ItemCommand _ "usetikzlibrary" [_], ItemCommand (Span a b) "cat" [Braced _ "shift={(1,-1)}", Braced _ "figures/a.tikz"], ItemCommand _ "newcommand" [_, Braced _ "2", Braced _ "red", _]] -> b - a == 37
        _ -> False
    )
  , ( "a statement that cannot be read says why and does not hide the next one"
    , case itemsOf "\\draw (0,0) -- wibble (1,1);\n\\node {ok};\n\\draw (0,0) -- (1,1)\n" of
        [ItemUnread (Span 0 28) reason, ItemPath _, ItemUnread _ ending] -> "wibble" `Text.isInfixOf` reason && "semicolon" `Text.isInfixOf` ending
        _ -> False
    )
  , ( "trees, plots, parabolas, let and decorations"
    , case opsOf "\\node {root} child {node {a} edge from parent[dashed] node[left] {l}} child[missing] child foreach \\x in {1,2} {node {\\x}};" of
        [OpNode _, OpChild _ [] [] (Just [OpNode _, OpEdgeFromParent _ (Just _) [OpNode _]]), OpChild _ [_] [] Nothing, OpChild _ [] [_] (Just [OpNode _])] ->
          case opsOf "\\draw plot[smooth] coordinates {(0,0) (1,1)} -- plot (\\x,{sin(\\x r)}) parabola[bend at end] bend (1,1) (2,0) let \\p1 = (a), \\n1 = {veclen(\\x1,\\y1)} in (\\n1,0) decorate[decoration=brace] { (0,0) -- (1,0) } sin (1,1) cos (2,0);" of
            [OpPlot _ False (Just _) (PlotCoordinates [_, _]), OpPlot _ True Nothing (PlotExpression _), OpParabola _ (Just _) (Just _) (TargetAt _), OpLet _ "\\p1 = (a), \\n1 = {veclen(\\x1,\\y1)}", OpMove _ _, OpDecorate _ (Just _) [_, _], OpSin _ _, OpCos _ _] -> True
            _ -> False
        _ -> False
    )
  , ( "pictures are found in a document, as environments and inline"
    , case parseDocument "Text \\begin{tikzpicture}[scale=2]\n\\draw (0,0) -- (1,1);\n\\end{tikzpicture} and \\tikz[baseline] \\node {x}; or \\tikz{\\fill (0,0) circle (1pt);}." of
        Document [ChunkText _, ChunkPicture _ (Just (Options _ [Option _ "scale" _ _])) (Picture _ [ItemPath _]), ChunkText _, ChunkInline _ (Just _) (Picture _ [ItemPath _]), ChunkText _, ChunkInline _ Nothing (Picture _ [ItemPath _]), ChunkText _] -> True
        _ -> False
    )
  , ( "expressions: operators, functions, units, macros, and whether a unit was written"
    , let macros name = lookup name [("r", "2"), ("w", "3cm"), ("n", "\\r+1")]
          value text = either (const Nothing) (\(MathValue number units) -> Just (fromIntegral (round (number * 1000) :: Integer) / 1000 :: Double, units)) (evalMath macros text)
       in fmap value ["1+2*3", "(1+2)*3", "2^3^2", "-2^2", "sin(30)", "cos(pi r)", "1cm", "1cm+2pt", "2*\\r", "0.5\\w", "\\n*2", "veclen(3,4)", "1cm/2pt", "max(1,5,3)", "3>2 ? 10 : 20", "mod(7,3)", "{4,5,6}[1]", "atan2(1,1)", "2 * (3 + 1)mm", "1e2", ".5", "3!", "nope(1)", "1+"]
            == [ Just (7, False), Just (9, False), Just (512, False), Just (4, False), Just (0.5, False), Just (-1, False), Just (28.453, True), Just (30.453, True), Just (4, False)
               , Just (42.679, True), Just (4, False), Just (5, False), Just (14.226, False), Just (5, False), Just (10, False), Just (1, False), Just (5, False), Just (45, False)
               , Nothing, Just (100, False), Just (0.5, False), Just (6, False), Nothing, Nothing
               ]
    )
  , ( "spans are the source: a node's text, name and options can be cut out"
    , let source = "\\node[draw, fill=blue!10] (parser) at (2,3) {Parser};"
       in case itemsOf source of
            [ItemPath PathCommand {pathSpan = whole, pathOps = [OpNode node]}] ->
              slice source whole == source
                && fmap (\(Braced s _) -> slice source s) (nodeText node) == Just "{Parser}"
                && [slice source s | PartName s _ <- nodeParts node] == ["(parser)"]
                && [slice source s | PartOptions (Options s _) <- nodeParts node] == ["draw, fill=blue!10"]
                && [slice source s | PartAt s _ <- nodeParts node] == ["at (2,3)"]
            _ -> False
    )
  ]

-- An edit of a figure's text, with places told by evaluating it.
edited :: FigureOp -> Text -> Either Text Text
edited = editFigure (placeIn (evaluatePicture Map.empty))

-- Where in a text a piece starts.
startOf :: Text -> Text -> Int
startOf piece text = Text.length (fst (Text.breakOn piece text))

editLaws :: [(String, Bool)]
editLaws =
  [ ("a placed node moves by its coordinate", edited (MoveItem 0 1 0.5) "\\node[draw] (a) at (1,2) {A};" == Right "\\node[draw] (a) at (2,2.5) {A};")
  , ("in a scaled picture the numbers written are the scaled ones", let t = "\\begin{tikzpicture}[scale=2]\n\\node (a) at (1,1) {A};\n\\end{tikzpicture}" in edited (MoveItem (startOf "\\node" t) 1 0) t == Right "\\begin{tikzpicture}[scale=2]\n\\node (a) at (1.5,1) {A};\n\\end{tikzpicture}")
  , ("a node beside another moves by a shift", let t = "\\node (a) at (0,0) {A};\n\\node[right=of a] (b) {B};" in edited (MoveItem (startOf "\\node[right" t) 0.5 0) t == Right "\\node (a) at (0,0) {A};\n\\node[right=of a, xshift=0.5cm, yshift=0cm] (b) {B};")
  , ("a shift that is there is added to", let t = "\\node (a) at (0,0) {A};\n\\node[right=of a, xshift=0.5cm, yshift=0cm] (b) {B};" in edited (MoveItem (startOf "\\node[right" t) 0.5 1) t == Right "\\node (a) at (0,0) {A};\n\\node[right=of a, xshift=1cm, yshift=1cm] (b) {B};")
  , ("a node nobody placed gets a place", edited (MoveItem 0 1 1) "\\node[draw] {A};" == Right "\\node[draw] at (1,1) {A};")
  , ("a line between points moves all its points", edited (MoveItem 0 1 0) "\\draw[->] (0,0) -- (1,1) -- (2,0);" == Right "\\draw[->] (1,0) -- (2,1) -- (3,0);")
  , ("a line between nodes does not move", either (const True) (const False) (edited (MoveItem (startOf "\\draw" "\\node (a) at (0,0) {A};\\node (b) at (2,0) {B};\\draw (a) -- (b);") 1 0) "\\node (a) at (0,0) {A};\\node (b) at (2,0) {B};\\draw (a) -- (b);"))
  , ("a node's text is replaced between its braces", edited (SetText 0 "new $x$") "\\node[draw] (a) at (1,2) {old};" == Right "\\node[draw] (a) at (1,2) {new $x$};")
  , ("a label on a line is retyped", let t = "\\draw (0,0) -- node[above] {old} (1,0);" in edited (SetText (startOf "node[above]" t) "new") t == Right "\\draw (0,0) -- node[above] {new} (1,0);")
  , ("an option is set where it is", edited (SetOption 0 "fill" (Just "red!20")) "\\node[draw, fill=blue] (a) {A};" == Right "\\node[draw, fill=red!20] (a) {A};")
  , ("an option is added at the end", edited (SetOption 0 "fill" (Just "red!20")) "\\node[draw] (a) {A};" == Right "\\node[draw, fill=red!20] (a) {A};")
  , ("an option list is made when there is none", edited (SetOption 0 "thick" (Just "")) "\\draw (0,0) -- (1,0);" == Right "\\draw[thick] (0,0) -- (1,0);")
  , ("an option is taken away with its comma", edited (SetOption 0 "fill" Nothing) "\\node[draw, fill=blue, thick] (a) {A};" == Right "\\node[draw, thick] (a) {A};")
  , ("the last option taken away takes the brackets", edited (SetOption 0 "draw" Nothing) "\\node[draw] (a) {A};" == Right "\\node (a) {A};")
  , ("a node in a matrix cell is retyped", let t = "\\matrix[column sep=5mm] {\n  \\node (a) {one}; &\n  \\node (b) {two}; \\\\\n};" in edited (SetText (startOf "\\node (b)" t) "2") t == Right "\\matrix[column sep=5mm] {\n  \\node (a) {one}; &\n  \\node (b) {2}; \\\\\n};")
  , ("a new node is written at the end, where it was asked to stand", edited (AddNode 2 1 "draw" "new") "\\node (a) at (0,0) {A};" == Right "\\node (a) at (0,0) {A};\n\\node[draw] (n1) at (2,1) {new};\n")
  , ("in a picture environment it goes before the end, at the picture's scale", let t = "\\begin{tikzpicture}[scale=2]\n  \\node (n1) at (0,0) {A};\n\\end{tikzpicture}" in edited (AddNode 2 1 "draw" "new") t == Right "\\begin{tikzpicture}[scale=2]\n  \\node (n1) at (0,0) {A};\n\\node[draw] (n2) at (1,0.5) {new};\n\\end{tikzpicture}")
  , ("a line joins two nodes by their names", let t = "\\node (a) at (0,0) {A};\n\\node (b) at (2,0) {B};" in edited (AddLine 0 (startOf "\\node (b)" t) "->") t == Right "\\node (a) at (0,0) {A};\n\\node (b) at (2,0) {B};\n\\draw[->] (a) -- (b);\n")
  , ("a node without a name is given one", let t = "\\node (a) at (0,0) {A};\n\\node[draw] at (2,0) {B};" in edited (AddLine 0 (startOf "\\node[draw]" t) "->") t == Right "\\node (a) at (0,0) {A};\n\\node[draw] (n1) at (2,0) {B};\n\\draw[->] (a) -- (n1);\n")
  , ("a node is made at least so big", edited (Resize 0 3 1.5) "\\node[draw] (a) at (0,0) {A};" == Right "\\node[draw, minimum width=3cm, minimum height=1.5cm] (a) at (0,0) {A};")
  , ("a circle keeps one size", edited (Resize 0 3 1.5) "\\node[draw, circle, minimum size=1cm] (a) at (0,0) {A};" == Right "\\node[draw, circle, minimum size=3cm] (a) at (0,0) {A};")
  , ("a line is bent, keeping its label", let t = "\\node (a) at (0,0) {A};\\node (b) at (2,1) {B};\n\\draw[->] (a) -- node[above] {x} (b);" in edited (SetRoute (startOf "\\draw" t) "bend left") t == Right "\\node (a) at (0,0) {A};\\node (b) at (2,1) {B};\n\\draw[->] (a) to[bend left] node[above] {x} (b);")
  , ("and made straight or right-angled again", let t = "\\node (a) at (0,0) {A};\\node (b) at (2,1) {B};\n\\draw[->] (a) to[bend left] (b);" in (edited (SetRoute (startOf "\\draw" t) "straight") t, edited (SetRoute (startOf "\\draw" t) "hv") t) == (Right "\\node (a) at (0,0) {A};\\node (b) at (2,1) {B};\n\\draw[->] (a) -- (b);", Right "\\node (a) at (0,0) {A};\\node (b) at (2,1) {B};\n\\draw[->] (a) -| (b);"))
  , ("several edits at once each find their place", let t = "\\node (a) at (0,0) {A};\n\\node (b) at (2,0) {B};" in edited (Batch [MoveItem 0 1 1, MoveItem (startOf "\\node (b)" t) 1 1]) t == Right "\\node (a) at (1,1) {A};\n\\node (b) at (3,1) {B};")
  , ("a statement is deleted with its line", let t = "\\node (a) {A};\n  \\draw (0,0) -- (1,0);\n\\node (b) {B};" in edited (DeleteItem (startOf "\\draw" t)) t == Right "\\node (a) {A};\n\\node (b) {B};")
  , ("a label is deleted from its line", let t = "\\draw (0,0) -- node[above] {old} (1,0);" in edited (DeleteItem (startOf "node[above]" t)) t == Right "\\draw (0,0) -- (1,0);")
  ]

main :: IO ()
main = do
  hSetEncoding stdout utf8
  debug <- lookupEnv "SB_TIKZ_DEBUG"
  when (debug /= Nothing) $ mapM_ (\t -> putStrLn (Text.unpack t <> "  =>  " <> show (evalMath (\name -> lookup name [("r", "2"), ("w", "3cm"), ("n", "\\r+1")]) t))) ["1+2*3", "(1+2)*3", "2^3^2", "-2^2", "sin(30)", "cos(pi r)", "1cm", "1cm+2pt", "2*\\r", "0.5\\w", "\\n*2", "veclen(3,4)", "1cm/2pt", "max(1,5,3)", "3>2 ? 10 : 20", "mod(7,3)", "{4,5,6}[1]", "atan2(1,1)", "2 * (3 + 1)mm", "1e2", ".5", "3!", "nope(1)", "1+"]
  when (debug /= Nothing) $ mapM_ (\(op, t) -> putStrLn (show (edited op t)))
    [ (AddNode 2 1 "draw" "new", "\\node (a) at (0,0) {A};")
    , (AddNode 2 1 "draw" "new", "\\begin{tikzpicture}[scale=2]\n  \\node (n1) at (0,0) {A};\n\\end{tikzpicture}")
    , (AddLine 0 24 "->", "\\node (a) at (0,0) {A};\n\\node[draw] at (2,0) {B};")
    , (SetRoute 46 "bend left", "\\node (a) at (0,0) {A};\\node (b) at (2,1) {B};\n\\draw[->] (a) -- node[above] {x} (b);")
    , (SetText 34 "2", "\\matrix[column sep=5mm] {\n  \\node (a) {one}; &\n  \\node (b) {two}; \\\\\n};")
    , (MoveItem 22 0.5 0, "\\node (a) at (0,0) {A};\n\\node[right=of a] (b) {B};")
    , (MoveItem 0 1 1, "\\node[draw] {A};")
    , (SetOption 0 "draw" Nothing, "\\node[draw] (a) {A};")
    ]
  when (debug /= Nothing) $ print [(pathCommand c, pathSpan c, [(nodeSpan n, nodeText n) | OpNode n <- pathOps c]) | ItemPath c <- itemsOf "\\matrix[column sep=5mm] {\n  \\node (a) {one}; &\n  \\node (b) {two}; \\\\\n};"]
  results <- forM (laws <> editLaws) $ \(name, ok) -> do
    putStrLn ((if ok then "ok   " else "FAIL ") <> name)
    pure ok
  corpusOk <- lookupEnv "SB_TIKZ_CORPUS" >>= maybe (pure True) (fmap and . mapM corpus . filter (not . null) . splitColons)
  if and results && corpusOk then putStrLn ("all " <> show (length results) <> " laws hold") else exitFailure
  where
    splitColons text = case break (== ':') text of
      (first, _ : rest) -> first : splitColons rest
      (first, []) -> [first]

-- Read every picture of every file in a folder: the statements must cover
-- the text; what could not be read is counted and the commonest reasons shown.
corpus :: FilePath -> IO Bool
corpus folder = do
  exists <- doesDirectoryExist folder
  if not exists
    then putStrLn ("corpus " <> folder <> ": not there, skipped") >> pure True
    else do
      names <- filter (\n -> any (`Text.isSuffixOf` Text.pack n) [".tex", ".tikz"]) <$> listDirectory folder
      found <- forM names $ \name -> do
        source <- decodeUtf8With lenientDecode <$> ByteString.readFile (folder <> "/" <> name)
        let Document chunks = parseDocument source
            pictures = [picture | ChunkPicture _ _ picture <- chunks] <> [picture | ChunkInline _ _ picture <- chunks]
            broken = [(name, problem) | picture <- pictures, Just problem <- [covers source picture]]
            everything = concatMap allItems pictures
            unread = [(name, reason, slice source s) | ItemUnread s reason <- everything]
        pure (length pictures, length everything, length [() | ItemPath _ <- everything], unread, broken)
      let pictures = sum [p | (p, _, _, _, _) <- found]
          statements = sum [s | (_, s, _, _, _) <- found]
          paths = sum [s | (_, _, s, _, _) <- found]
          unread = concat [u | (_, _, _, u, _) <- found]
          broken = concat [b | (_, _, _, _, b) <- found]
          reasons = sortOn (Down . snd) (Map.toList (Map.fromListWith (+) [(generalise reason, 1 :: Int) | (_, reason, _) <- unread]))
      putStrLn ("corpus " <> folder <> ": " <> show (length names) <> " files, " <> show pictures <> " pictures, " <> show statements <> " statements, " <> show paths <> " paths read, " <> show (length unread) <> " unread")
      mapM_ (\(reason, count) -> putStrLn ("  " <> show count <> "  " <> Text.unpack reason)) (take 25 reasons)
      stats <- lookupEnv "SB_TIKZ_STATS"
      when (stats /= Nothing) $ do
        sources <- forM names $ \name -> decodeUtf8With lenientDecode <$> ByteString.readFile (folder <> "/" <> name)
        let everything = concat [allItems picture | source <- sources, let Document chunks = parseDocument source, picture <- [p | ChunkPicture _ _ p <- chunks] <> [p | ChunkInline _ _ p <- chunks]]
            tally label values = putStrLn ("  " <> label <> ": " <> unwords [Text.unpack k <> "=" <> show n | (k, n) <- take 70 (sortOn (Down . snd) (Map.toList (Map.fromListWith (+) [(v, 1 :: Int) | v <- values])))])
            ops = concatMap deepOps [op | ItemPath command <- everything, op <- pathOps command]
            options = concat [found' | ItemPath command <- everything, op <- concatMap deepOps (pathOps command), found' <- opOptions op] <> concat [o | ItemScope _ (Just (Options _ o)) _ <- everything] <> concat [o | ItemSet _ (Options _ o) <- everything]
            styled = concat [nested o | o <- options]
            nested o = case (optionHandler o, optionValue o) of
              (Just _, Just (Value (Span a _) text)) -> let Options _ inner = parseOptions a text in inner <> concatMap nested inner
              _ -> []
        tally "commands" ([pathCommand c | ItemPath c <- everything] <> ["\\" <> n | ItemCommand _ n _ <- everything] <> ["scope" | ItemScope {} <- everything] <> ["foreach" | ItemForeach {} <- everything] <> ["layer" | ItemLayer {} <- everything] <> ["overlay" | ItemOverlay {} <- everything])
        tally "operations" (fmap (Text.pack . takeWhile (/= ' ') . show) ops)
        tally "coordinates" [Text.pack (takeWhile (/= ' ') (show (coordBody c))) <> (case coordRelative c of Absolute -> ""; RelativeStay -> "+"; RelativeMove -> "++") | op <- ops, c <- opCoordinates op]
        tally "options" (fmap (\o -> optionKey o <> maybe "" ("/." <>) (optionHandler o)) (options <> styled))
      lookupEnv "SB_TIKZ_DRAW" >>= maybe (pure ()) (\out -> draw out folder names)
      verbose <- lookupEnv "SB_TIKZ_SHOW"
      when (verbose /= Nothing) $ mapM_ (\(name, reason, text) -> putStrLn ("    " <> name <> ": " <> Text.unpack reason <> "\n      " <> Text.unpack (Text.take 160 (Text.unwords (Text.words text))))) (take 60 unread)
      unless (null broken) $ mapM_ (\(name, problem) -> putStrLn ("  BROKEN " <> name <> ": " <> Text.unpack problem)) (take 20 broken)
      pure (null broken)
  where
    -- reasons without their positions, so equal ones count together
    generalise = Text.unwords . fmap (\w -> if Text.all (`elem` ("0123456789" :: String)) w then "N" else w) . Text.words

-- Draw every picture of a folder as the evaluator sees it (one SVG each, and
-- the picture's own text beside it), and count what it did not carry out.
draw :: FilePath -> FilePath -> [FilePath] -> IO ()
draw out folder names = do
  createDirectoryIfMissing True out
  shared <- lookupEnv "SB_TIKZ_SETUP" >>= maybe (pure "") (fmap (decodeUtf8With lenientDecode) . ByteString.readFile)
  problems <- forM names $ \name -> do
    own <- decodeUtf8With lenientDecode <$> ByteString.readFile (folder <> "/" <> name)
    let Picture _ sharedItems = parsePicture 0 shared
        source = own
        Document chunks = parseDocument source
        -- what the text around the pictures sets up: styles, colours, macros
        setup = filter keeps sharedItems <> concat [filter keeps found | ChunkText (Span a b) <- chunks, let Picture _ found = parsePicture a (Text.take (b - a) (Text.drop a source))]
        keeps item = case item of
          ItemSet {} -> True
          ItemStyle {} -> True
          ItemCommand _ command _ -> command `elem` ["def", "newcommand", "colorlet", "definecolor", "pgfmathsetmacro"]
          _ -> False
        pictures = [(at, options, picture) | ChunkPicture at options picture <- chunks] <> [(at, options, picture) | ChunkInline at options picture <- chunks]
    forM (zip [1 :: Int ..] pictures) $ \(index, (at, options, Picture body found)) -> do
      let result = evaluatePicture Map.empty options (Picture body (setup <> found))
          base = out <> "/" <> takeWhile (/= '.') name <> "-" <> show index
      writeFile (base <> ".svg") (svgOf (evaluatedDrawn result))
      ByteString.writeFile (base <> ".tikz") (encodeUtf8 (slice source at))
      pure [(name, message, slice source s) | Problem s message <- evaluatedProblems result]
  let found = concat (concat problems)
      clean = length (filter null (concat problems))
      reasons = sortOn (Down . snd) (Map.toList (Map.fromListWith (+) [(message, 1 :: Int) | (_, message, _) <- found]))
  putStrLn ("  drawn: " <> show (length (concat problems)) <> " pictures, " <> show clean <> " with nothing left out, " <> show (length found) <> " things not carried out")
  mapM_ (\(reason, count) -> putStrLn ("    " <> show count <> "  " <> Text.unpack reason)) (take 40 reasons)
  writeFile (out <> "/problems.txt") (unlines [name <> "\t" <> Text.unpack message <> "\t" <> Text.unpack (Text.take 200 (Text.unwords (Text.words text))) | (name, message, text) <- found])

svgOf :: [Drawn] -> String
svgOf drawn =
  let k = 37.795 :: Double
      points = concat [segmentPoints s | DrawnPath {drawnSegments = segments} <- drawn, s <- segments] <> concat [[(x - w / 2, y - h / 2), (x + w / 2, y + h / 2)] | DrawnNode {drawnBox = NodeBox (x, y) w h _ _} <- drawn]
      (x1, x2, y1, y2) = case points of
        [] -> (0, 1, 0, 1)
        _ -> (minimum (fmap fst points) - 0.2, maximum (fmap fst points) + 0.2, minimum (fmap snd points) - 0.2, maximum (fmap snd points) + 0.2)
      px x = show ((x - x1) * k)
      py y = show ((y2 - y) * k)
      pt (x, y) = px x <> " " <> py y
      d segment = case segment of
        MoveTo p -> "M " <> pt p
        LineTo p -> "L " <> pt p
        CurveTo a b c -> "C " <> pt a <> ", " <> pt b <> ", " <> pt c
        ClosePath -> "Z"
      paint stroke fill = " fill=\"" <> maybe "none" Text.unpack fill <> "\"" <> maybe " stroke=\"none\"" (\(Stroke colour width dash) -> " stroke=\"" <> Text.unpack colour <> "\" stroke-width=\"" <> show (width * k / 28.45274) <> "\"" <> (if null dash then "" else " stroke-dasharray=\"" <> unwords (fmap (show . (* (k / 28.45274))) dash) <> "\"")) stroke
      escape = concatMap (\c -> case c of '<' -> "&lt;"; '&' -> "&amp;"; '>' -> "&gt;"; _ -> [c])
      one item = case item of
        DrawnPath _ segments stroke fill (startFound, endFound) opacity _ | (startTip, endTip) <- (startFound /= Nothing, endFound /= Nothing) ->
          "<path d=\"" <> unwords (fmap d segments) <> "\"" <> paint stroke fill <> " opacity=\"" <> show opacity <> "\"" <> (if startTip then " marker-start=\"url(#tip)\"" else "") <> (if endTip then " marker-end=\"url(#tip)\"" else "") <> "/>"
        DrawnNode _ _ _ (NodeBox (x, y) w h shape turn) stroke fill corner _ text style opacity _ ->
          let outline = case shape of
                ShapeRectangle -> "<rect x=\"" <> px (x - w / 2) <> "\" y=\"" <> py (y + h / 2) <> "\" width=\"" <> show (w * k) <> "\" height=\"" <> show (h * k) <> "\" rx=\"" <> show (corner * k) <> "\"" <> paint stroke fill <> "/>"
                ShapeDiamond -> "<path d=\"M " <> pt (x - w / 2, y) <> " L " <> pt (x, y + h / 2) <> " L " <> pt (x + w / 2, y) <> " L " <> pt (x, y - h / 2) <> " Z\"" <> paint stroke fill <> "/>"
                ShapeCoordinate -> ""
                _ -> "<ellipse cx=\"" <> px x <> "\" cy=\"" <> py y <> "\" rx=\"" <> show (w / 2 * k) <> "\" ry=\"" <> show (h / 2 * k) <> "\"" <> paint stroke fill <> "/>"
              rows = Text.splitOn "\\\\" text
              size = textSize style * k / 28.45274
              line index row = "<text x=\"" <> px x <> "\" y=\"" <> show ((y2 - y) * k + size * 0.35 + (fromIntegral index - fromIntegral (length rows - 1) / 2) * size * 1.2) <> "\" font-size=\"" <> show size <> "\" text-anchor=\"middle\" fill=\"" <> Text.unpack (textColour style) <> "\"" <> (if textBold style then " font-weight=\"bold\"" else "") <> ">" <> escape (Text.unpack (Text.strip row)) <> "</text>"
           in "<g opacity=\"" <> show opacity <> "\" transform=\"rotate(" <> show (negate turn) <> " " <> px x <> " " <> py y <> ")\">" <> outline <> concat (zipWith line [0 :: Int ..] rows) <> "</g>"
   in "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" <> show ((x2 - x1) * k) <> "\" height=\"" <> show ((y2 - y1) * k) <> "\" font-family=\"serif\"><defs><marker id=\"tip\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M 0 1 L 10 5 L 0 9 z\" fill=\"context-stroke\"/></marker></defs><rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n" <> unlines (fmap one drawn) <> "</svg>\n"
  where
    segmentPoints segment = case segment of
      MoveTo p -> [p]
      LineTo p -> [p]
      CurveTo a b c -> [a, b, c]
      ClosePath -> []

-- An operation and those inside it.
deepOps :: PathOp -> [PathOp]
deepOps op = op : concatMap deepOps (case op of
  OpLine _ _ found _ -> found
  OpCurve _ _ _ found _ -> found
  OpRectangle _ found _ -> found
  OpTo _ _ found _ -> found
  OpEdge _ _ found _ -> found
  OpEdgeFromParent _ _ found -> found
  OpScope _ found -> found
  OpForeach _ _ found -> found
  OpChild _ _ _ (Just found) -> found
  OpDecorate _ _ found -> found
  _ -> [])

opCoordinates :: PathOp -> [Coordinate]
opCoordinates op =
  let at to = case to of TargetAt c -> [c]; TargetCycle _ -> []
   in case op of
        OpMove _ c -> [c]
        OpLine _ _ _ to -> at to
        OpCurve _ a b _ to -> [a] <> maybe [] pure b <> at to
        OpRectangle _ _ to -> at to
        OpGrid _ _ to -> at to
        OpParabola _ _ b to -> maybe [] pure b <> at to
        OpSin _ to -> at to
        OpCos _ to -> at to
        OpTo _ _ _ to -> at to
        OpEdge _ _ _ to -> at to
        OpNode node -> maybe [] pure (nodeAt node)
        OpPlot _ _ _ (PlotCoordinates found) -> found
        _ -> []

opOptions :: PathOp -> [[Option]]
opOptions op =
  let from (Options _ found) = found
   in case op of
        OpOptions _ o -> [from o]
        OpNode node -> [nodeOptions node]
        OpTo _ os _ _ -> fmap from os
        OpEdge _ os _ _ -> fmap from os
        OpCircle _ (RoundKeys (Just o)) -> [from o]
        OpArc _ (ArcKeys o) -> [from o]
        OpGrid _ (Just o) _ -> [from o]
        OpChild _ os _ _ -> fmap from os
        OpDecorate _ (Just o) _ -> [from o]
        _ -> []
