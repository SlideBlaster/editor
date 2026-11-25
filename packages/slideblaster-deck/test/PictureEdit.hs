{-# LANGUAGE OverloadedStrings #-}

-- | Canvas edits of the picture block: each one changes only the bytes it
-- must, reads back as intended, and rejects text that would change meaning.
module Main (main) where

import SlideBlaster.Deck.Markdown
import SlideBlaster.Deck.PictureEdit
import SlideBlaster.Document qualified as Document
import SlideBlaster.Source qualified as Source

import Control.Monad (forM)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import System.Exit (exitFailure)

document :: Text -> MarkdownDeckDocument
document = analyzeMarkdownDeck . Source.snapshotFromBytes . Encoding.encodeUtf8

textOf :: MarkdownDeckDocument -> Text
textOf = Encoding.decodeUtf8 . Source.snapshotBytes . Document.documentSource

header :: Text
header = "---\nslideblaster: 1\ntitle: T\n---\n\n"

plain :: Text
plain = header <> "## One {#one}\n\nHello\n\n## Two {#two}\n\nBye\n"

drawn :: Text
drawn =
  header
    <> "## One {#one}\n\nHello\n\n```slide\n% the idea\n\\node[draw]   (a)  at (2,3) {A  b};\n\\node at (5, 3) {Other};\n\\draw[->] (a) -- (6,6);\n```\n\n## Two {#two}\n\nBye\n"

twoBlocks :: Text
twoBlocks = header <> "## One {#one}\n\n```slide\n\\node (a) at (1,1) {A};\n\\node at (2,2) {unnamed};\n```\n\nBetween the blocks.\n\n```slide\n\\node (b) at (3,3) {B};\n```\n"

run :: Text -> Text -> PictureOp -> Either PictureEditError (Text, Maybe Text)
run deck slide op = (\(d, made) -> (textOf d, case made of first : _ -> Just first; [] -> Nothing)) <$> editPicture defaultDeckConfig slide op (document deck)

-- The successor text and every node the edit made.
runAll :: Text -> PictureOp -> Either PictureEditError (Text, [Text])
runAll deck op = (\(d, made) -> (textOf d, made)) <$> editPicture defaultDeckConfig "one" op (document deck)

-- Three nodes and two lines, for edits of several things at once.
several :: Text
several = header <> "## One {#one}\n\n```slide\n\\node[draw] (a) at (1,1) {A};\n\\node[fill=red] at (4,1) {unnamed};\n\\node[draw, right=of a] (c) {C};\n\\draw[->] (a) -- (c);\n\\draw (a) -- (2,5);\n```\n"

block :: Text -> Text
block body = header <> "## One {#one}\n\n```slide\n" <> body <> "```\n"

chain :: Text -> [PictureOp] -> Either PictureEditError Text
chain deck ops = foldl (\acc op -> acc >>= \d -> fst <$> run d "one" op) (Right deck) ops

-- The fourth statement of a slide (a line between a and c) after an edit.
lineAfter :: Text -> PictureOp -> Either PictureEditError Text
lineAfter line op =
  let before = block ("\\node (a) at (1,1) {A};\n% kept\n\\node (b) at (2,2) {B};\n\\node (c) at (5,1) {C};\n" <> line <> "\n\\node (z) at (9,9) {Z};\n")
      (start, end) = ("\\node (c) at (5,1) {C};\n", "\n\\node (z) at (9,9) {Z};\n")
   in (\(after, _) -> Text.takeWhile (/= '\n') (snd (Text.breakOnEnd start (fst (Text.breakOn end after))))) <$> runAll before op

main :: IO ()
main = do
  let laws =
        [ ( "add to a slide without a block makes the block"
          , run plain "one" (AddNode "draw" 4 5 "Idea")
              == Right (header <> "## One {#one}\n\nHello\n\n```slide\n\\node[draw] (n1) at (4,5) {Idea};\n```\n\n## Two {#two}\n\nBye\n", Just "n1")
          )
        , ( "add appends one line and keeps every other byte"
          , fmap fst (run drawn "one" (AddNode "" 1.5 2.25 "New"))
              == Right (Text.replace "\\draw[->] (a) -- (6,6);\n" "\\draw[->] (a) -- (6,6);\n\\node (n1) at (1.5,2.25) {New};\n" drawn)
          )
        , ( "move rewrites only the point"
          , fmap fst (run drawn "one" (MoveNode "a" 7 1.5)) == Right (Text.replace "(a)  at (2,3)" "(a)  at (7,1.5)" drawn)
          )
        , ( "move of an unnamed node addresses it by statement number"
          , fmap fst (run drawn "one" (MoveNode "picture-2" 5.5 4)) == Right (Text.replace "at (5, 3)" "at (5.5,4)" drawn)
          )
        , ( "retype rewrites only the content"
          , fmap fst (run drawn "one" (SetNodeText "a" "$x^2$ and **bold**")) == Right (Text.replace "{A  b}" "{$x^2$ and **bold**}" drawn)
          )
        , ( "connect names the unnamed node and adds one arrow"
          , fmap fst (run drawn "one" (ConnectNodes "a" "picture-2"))
              == Right (Text.replace "\\draw[->] (a) -- (6,6);\n" "\\draw[->] (a) -- (6,6);\n\\draw[->] (a) -- (n1);\n" (Text.replace "\\node at (5, 3)" "\\node (n1) at (5, 3)" drawn))
          )
        , ( "delete of a node takes its lines with it"
          , fmap fst (run drawn "one" (DeleteItem "a" [])) == Right (Text.replace "\n% the idea\n\\node[draw]   (a)  at (2,3) {A  b};" "" (Text.replace "\n\\draw[->] (a) -- (6,6);" "" drawn))
          )
        , ( "delete of a line leaves the nodes"
          , fmap fst (run drawn "one" (DeleteItem "line-3" [])) == Right (Text.replace "\n\\draw[->] (a) -- (6,6);" "" drawn)
          )
        , ("text that closes its braces early is rejected", run drawn "one" (SetNodeText "a" "x}; \\node at (1,1) {y") == Left PictureVerificationRejected)
        , ("text that closes the block is rejected", run drawn "one" (SetNodeText "a" "x\n```\n") == Left PictureVerificationRejected)
        , ("unbalanced text is rejected", run drawn "one" (SetNodeText "a" "{") == Left PictureVerificationRejected)
        , ("a missing node is reported", run drawn "one" (MoveNode "zz" 1 1) == Left (PictureItemMissing "node zz"))
        , ("the title slide is not editable", run drawn "title-slide" (AddNode "" 1 1 "x") == Left (PictureSlideMissing "title-slide"))
        , ( "a whole drawing built from nothing stays three short lines"
          , chain plain [AddNode "draw" 4 5 "Parser", AddNode "draw" 9 5 "Checker", ConnectNodes "n1" "n2"]
              == Right (header <> "## One {#one}\n\nHello\n\n```slide\n\\node[draw] (n1) at (4,5) {Parser};\n\\node[draw] (n2) at (9,5) {Checker};\n\\draw[->] (n1) -- (n2);\n```\n\n## Two {#two}\n\nBye\n")
          )
        , ( "deleting everything again leaves an empty block"
          , chain plain [AddNode "draw" 4 5 "Parser", DeleteItem "n1" []] == Right (header <> "## One {#one}\n\nHello\n\n```slide\n```\n\n## Two {#two}\n\nBye\n")
          )
        , ( "attach drops the point and adds one option"
          , fmap fst (run drawn "one" (AttachNode "a" "right" "picture-2" Nothing))
              == Right (Text.replace "\\node at (5, 3)" "\\node (n1) at (5, 3)" (Text.replace "\\node[draw]   (a)  at (2,3) {A  b}" "\\node[draw, right=of n1]   (a) {A  b}" drawn))
          )
        , ( "attach a node without options gives it the one option"
          , fmap fst (run drawn "one" (AttachNode "picture-2" "below" "a" Nothing)) == Right (Text.replace "\\node at (5, 3) {Other}" "\\node[below=of a] {Other}" drawn)
          )
        , ( "attach again only changes the option"
          , chain drawn [AttachNode "picture-2" "below" "a" Nothing, AttachNode "picture-2" "above" "a" Nothing] == Right (Text.replace "\\node at (5, 3) {Other}" "\\node[above=of a] {Other}" drawn)
          )
        , ( "moving an attached node detaches it and writes its point"
          , chain drawn [AttachNode "picture-2" "below" "a" Nothing, MoveNode "picture-2" 9 1] == Right (Text.replace "\\node at (5, 3) {Other}" "\\node at (9,1) {Other}" drawn)
          )
        , ( "detaching keeps the other options"
          , chain drawn [AttachNode "a" "right" "picture-2" Nothing, MoveNode "a" 1 1]
              == Right (Text.replace "\\node at (5, 3)" "\\node (n1) at (5, 3)" (Text.replace "\\node[draw]   (a)  at (2,3) {A  b}" "\\node[draw]   (a) at (1,1) {A  b}" drawn))
          )
        , ("a circle of attachments is refused", (chain drawn [AttachNode "picture-2" "below" "a" Nothing] >>= \d -> fst <$> run d "one" (AttachNode "a" "above" "picture-2" Nothing)) == Left (PictureNotEditable "these nodes would be attached to each other in a circle"))
        , ("a node does not attach to itself", run drawn "one" (AttachNode "a" "above" "a" Nothing) == Left (PictureNotEditable "these nodes would be attached to each other in a circle"))
        , ( "deleting a node keeps the node attached to it, at its given point"
          , (chain drawn [AttachNode "picture-2" "below" "a" Nothing] >>= \d -> fst <$> run d "one" (DeleteItem "a" [("picture-2", 2, 1.5)]))
              == Right (Text.replace "\n% the idea\n\\node[draw]   (a)  at (2,3) {A  b};" "" (Text.replace "\n\\draw[->] (a) -- (6,6);" "" (Text.replace "\\node at (5, 3) {Other}" "\\node at (2,1.5) {Other}" drawn)))
          )
        , ("deleting a node with an unplaced follower is refused", (chain drawn [AttachNode "picture-2" "below" "a" Nothing] >>= \d -> fst <$> run d "one" (DeleteItem "a" [])) == Left (PictureNotEditable "a node attached to this one has no place to stay"))
        , ( "an attached node can be retyped and connected"
          , chain drawn [AttachNode "picture-2" "below" "a" Nothing, SetNodeText "picture-2" "New", ConnectNodes "a" "picture-2"]
              == Right (Text.replace "\\draw[->] (a) -- (6,6);\n" "\\draw[->] (a) -- (6,6);\n\\draw[->] (a) -- (n1);\n" (Text.replace "\\node at (5, 3) {Other}" "\\node[below=of a] (n1) {New}" drawn))
          )
        , ( "attach at a distance writes the distance"
          , fmap fst (run drawn "one" (AttachNode "picture-2" "above right" "a" (Just 1.5))) == Right (Text.replace "\\node at (5, 3) {Other}" "\\node[above right=1.5 of a] {Other}" drawn)
          )
        , ( "a node attaches to the slide's own title"
          , fmap fst (run drawn "one" (AttachNode "picture-2" "below" "title" (Just 0.8))) == Right (Text.replace "\\node at (5, 3) {Other}" "\\node[below=0.8 of title] {Other}" drawn)
          )
        , ( "restyle replaces an option where it stands and adds new ones at the end"
          , fmap fst (run drawn "one" (SetOptions "a" [SetOption "draw" (Just "red"), SetOption "fill" (Just "yellow!30"), SetOption "thick" Nothing]))
              == Right (Text.replace "\\node[draw]   (a)" "\\node[draw=red, fill=yellow!30, thick]   (a)" drawn)
          )
        , ( "restyle of a node without options gives it brackets, and removing the last option takes them away"
          , chain drawn [SetOptions "picture-2" [SetOption "draw" Nothing]] == Right (Text.replace "\\node at (5, 3)" "\\node[draw] at (5, 3)" drawn)
              && chain drawn [SetOptions "picture-2" [SetOption "draw" Nothing], SetOptions "picture-2" [RemoveOption "draw"]] == Right drawn
          )
        , ( "restyle of a line changes its arrow and keeps the rest"
          , fmap fst (run drawn "one" (SetOptions "line-3" [RemoveOption "->", SetOption "<->" Nothing, SetOption "dashed" Nothing]))
              == Right (Text.replace "\\draw[->] (a) -- (6,6);" "\\draw[<->, dashed] (a) -- (6,6);" drawn)
          )
        , ( "restyle keeps an attached node attached"
          , chain drawn [AttachNode "picture-2" "below" "a" Nothing, SetOptions "picture-2" [SetOption "fill" (Just "blue!10")]]
              == Right (Text.replace "\\node at (5, 3) {Other}" "\\node[below=of a, fill=blue!10] {Other}" drawn)
          )
        , ("an option cannot break out of its list", run drawn "one" (SetOptions "a" [SetOption "fill" (Just "red] {x}; \\node")]) == Left (PictureNotEditable "an option cannot hold brackets, a semicolon or a line break"))
        , ( "a slide with two blocks: statements number across them, new ones go into the last"
          , chain twoBlocks [MoveNode "b" 9 9, AddNode "" 1 1 "new", ConnectNodes "a" "b", DeleteItem "picture-2" []]
              == Right (header <> "## One {#one}\n\n```slide\n\\node (a) at (1,1) {A};\n```\n\nBetween the blocks.\n\n```slide\n\\node (b) at (9,9) {B};\n\\node (n1) at (1,1) {new};\n\\draw[->] (a) -- (b);\n```\n")
          )
        , ( "a picture file is brought in with one line, moved by its shift, and removed whole"
          , ( fmap fst (run drawn "one" (AddInclude "arch.tikz" 0 0))
            , chain drawn [AddInclude "arch.tikz" 0 0, MoveInclude "cat-4" 2 (-1.5)]
            , chain drawn [AddInclude "arch.tikz" 2 1, MoveInclude "cat-4" 0 0]
            , chain drawn [AddInclude "arch.tikz" 2 1, DeleteItem "cat-4" []]
            )
              == ( Right (Text.replace "(6,6);\n" "(6,6);\n\\cat{arch.tikz};\n" drawn)
                 , Right (Text.replace "(6,6);\n" "(6,6);\n\\cat[shift={(2,-1.5)}]{arch.tikz};\n" drawn)
                 , Right (Text.replace "(6,6);\n" "(6,6);\n\\cat{arch.tikz};\n" drawn)
                 , Right drawn
                 )
          )
        , ( "nodes of an included picture take arrows and attachments by name"
          , let included = Text.replace "(6,6);\n" "(6,6);\n\\cat{arch.tikz};\n" drawn
                config = defaultDeckConfig {configReadFile = \path -> if path == "arch.tikz" then Just "\\node (core) at (1,1) {Core};\n" else Nothing}
                with op deck = (\(d, _) -> textOf d) <$> editPicture config "one" op (document deck)
             in ( with (ConnectNodes "a" "core") included
                , with (AttachNode "a" "below" "core" Nothing) included
                , fmap fst (run included "one" (ConnectNodes "a" "core"))
                )
                  == ( Right (Text.replace "\\cat{arch.tikz};\n" "\\cat{arch.tikz};\n\\draw[->] (a) -- (core);\n" included)
                     , Right (Text.replace "\\node[draw]   (a)  at (2,3) {A  b};" "\\node[draw, below=of core]   (a) {A  b};" included)
                     , Left (PictureItemMissing "node core")
                     )
          )
        , ( "delete of several things at once: nodes, their lines, and a pinned follower"
          , ( fmap fst (runAll several (DeleteItems ["a", "picture-2"] [("c", 3, 1)]))
            , fmap fst (runAll several (DeleteItems ["line-4", "c"] []))
            , runAll several (DeleteItems ["a", "nosuch"] [("c", 3, 1)])
            , runAll several (DeleteItems ["a"] [])
            )
              == ( Right (block "\\node[draw] (c) at (3,1) {C};\n")
                 , Right (block "\\node[draw] (a) at (1,1) {A};\n\\node[fill=red] at (4,1) {unnamed};\n\\draw (a) -- (2,5);\n")
                 , Left (PictureItemMissing "node nosuch")
                 , Left (PictureNotEditable "a node attached to this one has no place to stay")
                 )
          )
        , ( "layering moves a node among the nodes and says what it is called there"
          , ( runAll several (Reorder "a" ToFront)
            , runAll several (Reorder "c" ToBack)
            , runAll several (Reorder "a" Forward)
            , fmap fst (runAll several (Reorder "picture-2" Backward))
            , runAll several (Reorder "a" ToBack)
            , runAll several (Reorder "c" Forward)
            )
              == ( Right (block "\\node[fill=red] at (4,1) {unnamed};\n\\node[draw, right=of a] (c) {C};\n\\node[draw] (a) at (1,1) {A};\n\\draw[->] (a) -- (c);\n\\draw (a) -- (2,5);\n", ["a"])
                 , Right (block "\\node[draw, right=of a] (c) {C};\n\\node[draw] (a) at (1,1) {A};\n\\node[fill=red] at (4,1) {unnamed};\n\\draw[->] (a) -- (c);\n\\draw (a) -- (2,5);\n", ["c"])
                 , Right (block "\\node[fill=red] at (4,1) {unnamed};\n\\node[draw] (a) at (1,1) {A};\n\\node[draw, right=of a] (c) {C};\n\\draw[->] (a) -- (c);\n\\draw (a) -- (2,5);\n", ["a"])
                 , Right (block "\\node[fill=red] at (4,1) {unnamed};\n\\node[draw] (a) at (1,1) {A};\n\\node[draw, right=of a] (c) {C};\n\\draw[->] (a) -- (c);\n\\draw (a) -- (2,5);\n")
                 , Left (PictureNotEditable "it is already at the back")
                 , Left (PictureNotEditable "it is already in front")
                 )
          )
        , ( "paste copies nodes under new names, shifted, with the lines between them"
          , ( runAll several (PasteStatements "\\node[draw] (a) at (1,1) {A};\n\\node[fill=red] at (4,1) {unnamed};\n\\node[draw, right=of a] (c) {C};\n\\draw[->] (a) -- (c);\n\\draw (a) -- (2,5);\n\\draw (a) -- (zz);" 0.5 (-0.5))
            , runAll plain (PasteStatements "\\node[draw] (q) at (1,1) {A};" 0 0)
            , fmap fst (runAll several (PasteStatements "\\node[draw, right=of a] (c) {C};" 1 1))
            , runAll plain (PasteStatements "\\node[draw, right=of a] (c) {C};" 1 1)
            , runAll several (PasteStatements "% nothing\n\\cat{x.tikz};" 1 1)
            , runAll several (PasteStatements "\\node (x) at (1,1) {a}; \\node at (2,2) {b" 0 0)
            )
              == ( Right (Text.replace "(2,5);\n" "(2,5);\n\\node[draw] (n1) at (1.5,0.5) {A};\n\\node[fill=red] (n2) at (4.5,0.5) {unnamed};\n\\node[draw, right=of n1] (n3) {C};\n\\draw[->] (n1) -- (n3);\n\\draw (n1) -- (2.5,4.5);\n" several, ["n1", "n2", "n3"])
                 , Right (header <> "## One {#one}\n\nHello\n\n```slide\n\\node[draw] (n1) at (1,1) {A};\n```\n\n## Two {#two}\n\nBye\n", ["n1"])
                 , Right (Text.replace "(2,5);\n" "(2,5);\n\\node[draw, right=of a] (n1) {C};\n" several)
                 , Left (PictureNotEditable "a copied node is attached to a, which is not on this slide")
                 , Left (PictureNotEditable "there is nothing to paste here")
                 , Right (Text.replace "(2,5);\n" "(2,5);\n\\node (n1) at (1,1) {a};\n" several, ["n1"])
                 )
          )
        , ( "several edits as one: each reads what the one before wrote"
          , ( runAll several (Batch [MoveNode "a" 2 2, MoveNode "picture-2" 5 2, SetOptions "c" [SetOption "rotate" (Just "30")]])
            , runAll several (Batch [AddNode "" 1 1 "x", ConnectNodes "n1" "a"])
            , runAll several (Batch [MoveNode "a" 2 2, MoveNode "nosuch" 1 1])
            , runAll several (Batch [SetNodeText "a" "x}; \\node at (1,1) {y", MoveNode "a" 1 1])
            , runAll plain (Batch [AddNode "" 1 1 "x", AddNode "draw" 2 2 "y"])
            )
              == ( Right (block "\\node[draw] (a) at (2,2) {A};\n\\node[fill=red] at (5,2) {unnamed};\n\\node[draw, right=of a, rotate=30] (c) {C};\n\\draw[->] (a) -- (c);\n\\draw (a) -- (2,5);\n", [])
                 , Right (Text.replace "(2,5);\n" "(2,5);\n\\node (n1) at (1,1) {x};\n\\draw[->] (n1) -- (a);\n" several, ["n1"])
                 , Left (PictureItemMissing "node nosuch")
                 , Left PictureVerificationRejected
                 , Right (header <> "## One {#one}\n\nHello\n\n```slide\n\\node (n1) at (1,1) {x};\n\\node[draw] (n2) at (2,2) {y};\n```\n\n## Two {#two}\n\nBye\n", ["n1", "n2"])
                 )
          )
        , ( "a line is made straight, right-angled or bent, and nothing else of it changes"
          , ( lineAfter "\\draw[->, thick] (a) -- node[above] {yes} (c);" (SetRoute "line-4" "hv" Nothing)
            , lineAfter "\\draw[->] (a) -| (c);" (SetRoute "line-4" "bend left" Nothing)
            , lineAfter "\\draw[->] (a) to[bend left=45] (c);" (SetRoute "line-4" "bend right" Nothing)
            , lineAfter "\\draw[->] (a) to[bend right=45] (c);" (SetRoute "line-4" "bend right" (Just 20))
            , lineAfter "\\draw[->] (a.east) to[bend right, looseness=2] node {x} (c.north);" (SetRoute "line-4" "straight" Nothing)
            , lineAfter "\\draw[->] (a) -- (c);" (SetRoute "line-4" "wavy" Nothing)
            )
              == ( Right "\\draw[->, thick] (a) -| node[above] {yes} (c);"
                 , Right "\\draw[->] (a) to[bend left] (c);"
                 , Right "\\draw[->] (a) to[bend right=45] (c);"
                 , Right "\\draw[->] (a) to[bend right=20] (c);"
                 , Right "\\draw[->] (a.east) -- node {x} (c.north);"
                 , Left (PictureNotEditable "a line goes straight, at a right angle, or bends left or right")
                 )
          )
        , ( "a label is added on the middle step, retyped, moved to the other side and removed"
          , ( lineAfter "\\draw[->] (a) -- (c);" (SetLineLabel "line-4" 0 "yes")
            , lineAfter "\\draw[->] (a) -- (3,3) -- (4,4) -- (c);" (SetLineLabel "line-4" 0 "mid")
            , lineAfter "\\draw[->] (a) -- node[auto] {yes} (c) node[right] {end};" (SetLineLabel "line-4" 2 "$x^2$ {ok}")
            , lineAfter "\\draw[->] (a) -- node[auto] {yes} (c);" (SetLabelOptions "line-4" 1 [SetOption "swap" Nothing, SetOption "pos" (Just "0.25")])
            , lineAfter "\\draw[->] (a) -- node[auto] {yes} (c);" (SetLineLabel "line-4" 1 " ")
            , lineAfter "\\draw[->] (a) -- node[auto] {yes} (c);" (SetLineLabel "line-4" 1 "no} (c); \\node at (1,1) {x")
            , lineAfter "\\draw[->] (a) -- (c);" (SetLineLabel "line-4" 3 "x")
            )
              == ( Right "\\draw[->] (a) -- node[auto] {yes} (c);"
                 , Right "\\draw[->] (a) -- (3,3) -- node[auto] {mid} (4,4) -- (c);"
                 , Right "\\draw[->] (a) -- node[auto] {yes} (c) node[right] {$x^2$ {ok}};"
                 , Right "\\draw[->] (a) -- node[auto, swap, pos=0.25] {yes} (c);"
                 , Right "\\draw[->] (a) -- (c);"
                 , Left PictureSourceRejected
                 , Left (PictureItemMissing "label")
                 )
          )
        , ( "a point is put into a line, moved and taken out again; an end on a node is not a point"
          , ( lineAfter "\\draw[->] (a) -- node[auto] {l} (c);" (AddLinePoint "line-4" 1 3.456 2)
            , lineAfter "\\draw[->] (a) -- (3,2) -- (c);" (MoveLinePoint "line-4" 1 4 4.5)
            , lineAfter "\\draw[->] (a) -- node {p} (3,2) -- node {q} (c);" (RemoveLinePoint "line-4" 1)
            , lineAfter "\\draw[->] (a) -- (c);" (MoveLinePoint "line-4" 0 1 1)
            , lineAfter "\\draw[->] (a) -- (c);" (RemoveLinePoint "line-4" 1)
            )
              == ( Right "\\draw[->] (a) -- node[auto] {l} (3.46,2) -- (c);"
                 , Right "\\draw[->] (a) -- (4,4.5) -- (c);"
                 , Right "\\draw[->] (a) -- node {p} node {q} (c);"
                 , Left (PictureNotEditable "this end follows its node")
                 , Left (PictureNotEditable "only a point between the ends can be taken out")
                 )
          )
        , ( "a copy keeps how its lines go, their labels and anchors"
          , fmap fst (runAll several (PasteStatements "\\node (a) at (1,1) {A};\n\\node (b) at (3,1) {B};\n\\draw[->] (a.east) to[bend left] node[auto] {go} (b) -| (5,5);" 1 0))
              == Right (Text.replace "(2,5);\n" "(2,5);\n\\node (n1) at (2,1) {A};\n\\node (n2) at (4,1) {B};\n\\draw[->] (n1.east) to[bend left] node[auto] {go} (n2) -| (6,5);\n" several)
          )
        , ( "an empty slide at the end of the file gets a block"
          , fmap fst (run (header <> "## One {#one}\n") "one" (AddNode "" 2 2 "x")) == Right (header <> "## One {#one}\n\n```slide\n\\node (n1) at (2,2) {x};\n```\n")
          )
        ]
  results <- forM laws $ \(name, ok) -> do
    putStrLn ((if ok then "ok   " else "FAIL ") <> name)
    pure ok
  if and results then putStrLn ("all " <> show (length results) <> " laws hold") else exitFailure
