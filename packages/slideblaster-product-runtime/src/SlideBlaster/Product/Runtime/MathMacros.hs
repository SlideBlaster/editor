{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.MathMacros
-- Description : Expand the deck preamble's @\\newcommand@ macros inside math.
--
-- Math payloads are opaque TeX to the content tree, so a user macro such as
-- @\\newcommand{\\Reach}{\\mathsf{Reach}}@ would reach KaTeX undefined. The core
-- expands them here (the host never sees user macros).
module SlideBlaster.Product.Runtime.MathMacros
  ( MathMacro
  , parseMathMacros
  , expandMathIn
  ) where

import SlideBlaster.Canvas
  ( ContentItem (..)
  , ContentNode (..)
  , DerivedState (..)
  , TableCell (..)
  , TableModel (..)
  , TableRow (..)
  )

import Data.Char (isAlpha, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text

-- | Name (without backslash), argument count, body.
type MathMacro = (Text, Int, Text)

-- | @\\newcommand@, @\\renewcommand@ and @\\providecommand@ with a braced body.
parseMathMacros :: Text -> [MathMacro]
parseMathMacros preamble = concatMap fromChunk (drop 1 (Text.splitOn "command" preamble))
  where
    fromChunk chunk = case definition chunk of
      Just m -> [m]
      Nothing -> []
    definition chunk = do
      afterName <- Text.stripPrefix "{\\" chunk
      let (name, rest) = Text.span isAlpha afterName
      rest1 <- Text.stripPrefix "}" rest
      let (count, rest2) = case Text.uncons rest1 of
            Just ('[', r) -> let (digits, r') = Text.span isDigit r in (if Text.null digits then 0 else read (Text.unpack digits), Text.drop 1 r')
            _ -> (0, rest1)
      (body, _) <- braced rest2
      if Text.null name then Nothing else Just (name, count, body)

-- First balanced {..} group at the start of the text (after spaces).
braced :: Text -> Maybe (Text, Text)
braced text = case Text.uncons (Text.stripStart text) of
  Just ('{', rest) -> go (1 :: Int) Text.empty rest
  _ -> Nothing
  where
    go depth acc remaining = case Text.uncons remaining of
      Nothing -> Nothing
      Just ('\\', r) -> case Text.uncons r of
        Just (c, r') -> go depth (acc <> Text.pack ['\\', c]) r'
        Nothing -> Nothing
      Just ('{', r) -> go (depth + 1) (Text.snoc acc '{') r
      Just ('}', r)
        | depth == 1 -> Just (acc, r)
        | otherwise -> go (depth - 1) (Text.snoc acc '}') r
      Just (c, r) -> go depth (Text.snoc acc c) r

expandText :: [MathMacro] -> Text -> Text
expandText macros = go (8 :: Int)
  where
    go 0 text = text
    go n text = let next = pass text in if next == text then text else go (n - 1) next
    pass text = case Text.breakOn "\\" text of
      (before, rest)
        | Text.null rest -> before
        | otherwise ->
            let afterSlash = Text.drop 1 rest
                (name, afterName) = Text.span isAlpha afterSlash
             in case [m | m@(n', _, _) <- macros, n' == name, not (Text.null name)] of
                  (_, count, body) : _ -> case arguments count afterName of
                    Just (args, remaining) -> before <> substitute args body <> pass remaining
                    Nothing -> before <> "\\" <> name <> pass afterName
                  [] ->
                    if Text.null name
                      then before <> Text.take 2 rest <> pass (Text.drop 2 rest)
                      else before <> "\\" <> name <> pass afterName
    arguments :: Int -> Text -> Maybe ([Text], Text)
    arguments 0 text = Just ([], text)
    arguments count text = do
      (arg, rest) <- braced text
      (more, remaining) <- arguments (count - 1) rest
      Just (arg : more, remaining)
    substitute args body = foldl (\acc (i, a) -> Text.replace ("#" <> Text.pack (show i)) a acc) body (zip [1 :: Int ..] args)

-- | Rewrite every math payload in a node.
expandMathIn :: [MathMacro] -> ContentNode -> ContentNode
expandMathIn [] node = node
expandMathIn macros node = go node
  where
    go n = case n of
      OpaqueMath p kind tex -> OpaqueMath p kind (expandText macros tex)
      StyledRun p marks cs -> StyledRun p marks (fmap go cs)
      TransparentContainer p kind cs -> TransparentContainer p kind (fmap go cs)
      ListContent p kind items -> ListContent p kind (fmap (\i -> i {contentItemBody = fmap go (contentItemBody i)}) items)
      OverlayContent hook cs -> OverlayContent hook (fmap go cs)
      TableContent p (DerivedReady (TableModel rows aligns)) ->
        TableContent p (DerivedReady (TableModel (fmap (\(TableRow cells) -> TableRow (fmap (\c -> c {tableCellContent = fmap go (tableCellContent c)}) cells)) rows) aligns))
      other -> other
