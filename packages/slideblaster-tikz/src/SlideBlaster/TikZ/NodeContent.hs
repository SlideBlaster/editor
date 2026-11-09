{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.TikZ.NodeContent
-- Description : Interpreting a node's content as mixed-dialect markup.
--
-- The picture reader delimits a node's content and hands over its exact bytes
-- without interpreting them. This module supplies the interpretation, by reading
-- those bytes with "SlideBlaster.Syntax" and lowering the result to the resolved
-- runs a renderer can draw.
--
-- == Why unreadable content does not fail the document
--
-- The syntax reader refuses malformed input rather than inventing a tree for it,
-- which is the right behaviour for a reader. A slide, though, should not become
-- unopenable because one node's content is outside the supported subset. So a
-- reader failure is recorded here as 'ContentOpaque' and the content is carried as
-- a single opaque run holding the author's exact bytes: nothing is lost, nothing
-- is guessed, and the status says plainly which happened.
--
-- Widening support therefore only ever moves content from 'ContentOpaque' to
-- 'ContentUnderstood'. It never changes what is preserved.
--
-- == Why the tree is not carried
--
-- A render plan is renderer-facing. Editing needs the tree, but it can call
-- 'readNodeContent' on the same bytes and get the same tree, because reading is
-- deterministic. Carrying it in the plan would put an edit target inside a derived
-- value, which is exactly the confusion the run paths exist to avoid.
module SlideBlaster.TikZ.NodeContent
  ( NodeContent (..)
  , ContentStatus (..)
  , readNodeContent
  , nodeContentTree
  ) where

import SlideBlaster.Syntax.Ast (Node, NodeF (Run), node)
import SlideBlaster.Syntax.Expand (ExpansionError (..), expandTex)
import SlideBlaster.Syntax.Inline
  ( Inline (..)
  , InlineIssue
  , InlineRun
  , flattenInline
  , opaqueInline
  )
import SlideBlaster.Syntax.Surface (Dialect (Tex), Surface (Transparent))
import SlideBlaster.Syntax.Tex.Reader (TexSyntaxError (..), readTex)

import Data.Text (Text)
import Data.Text qualified as Text

-- | Whether the content was interpreted, and if not, why not.
data ContentStatus
  = ContentUnderstood
  | -- | Carries a positioned explanation, suitable for a diagnostic.
    ContentOpaque !Text
  deriving (Eq, Show)

-- | A node's content: the author's bytes, and what they mean.
data NodeContent = NodeContent
  { -- | The exact authored bytes. Always present, whatever the status.
    nodeContentSource :: !Text
  , nodeContentRuns :: ![InlineRun]
  , nodeContentStatus :: !ContentStatus
  , -- | Things understood only partially, such as an unknown colour name.
    nodeContentIssues :: ![InlineIssue]
  }
  deriving (Eq, Show)

-- | Read and lower a node's content. Total: every input yields a value.
readNodeContent :: Text -> NodeContent
readNodeContent source =
  case readTex source of
    Left failure -> opaque (describeSyntaxError failure)
    Right parsed ->
      case expandTex parsed of
        Left failure -> opaque (describeExpansionError failure)
        Right expanded ->
          let lowered = flattenInline (wrap expanded)
           in NodeContent
                { nodeContentSource = source
                , nodeContentRuns = inlineRuns lowered
                , nodeContentStatus = ContentUnderstood
                , nodeContentIssues = inlineIssues lowered
                }
  where
    opaque reason =
      NodeContent
        { nodeContentSource = source
        , nodeContentRuns = inlineRuns (opaqueInline source)
        , nodeContentStatus = ContentOpaque reason
        , nodeContentIssues = []
        }

-- | The tree an edit operates on, or 'Nothing' when the content is opaque.
--
-- The same wrapping as 'readNodeContent' uses, so the paths carried by runs
-- resolve against this tree.
nodeContentTree :: Text -> Maybe Node
nodeContentTree source =
  case readTex source of
    Left _ -> Nothing
    Right parsed ->
      case expandTex parsed of
        Left _ -> Nothing
        Right expanded -> Just (wrap expanded)

-- | Content is a sequence, and a path needs a single root. A transparent
-- container supplies one without contributing any bytes of its own.
wrap :: [Node] -> Node
wrap = node . Run (Transparent Tex)

describeSyntaxError :: TexSyntaxError -> Text
describeSyntaxError failure =
  "line "
    <> Text.pack (show (texErrorLine failure))
    <> ", column "
    <> Text.pack (show (texErrorColumn failure))
    <> ": "
    <> texErrorMessage failure

describeExpansionError :: ExpansionError -> Text
describeExpansionError failure =
  case failure of
    ExpansionTooDeep name ->
      "macro expansion did not terminate: " <> Text.pack (show name)
    MissingArgument name index ->
      "macro "
        <> Text.pack (show name)
        <> " is missing argument "
        <> Text.pack (show index)
