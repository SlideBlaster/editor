{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Markdown.Reader
-- Description : Reading inline Markdown out of mixed content.
--
-- Markdown needs no gate. Authored content is one mixed language, so @**bold**@
-- sits directly beside @\\textbf{bold}@ and @\\<strong\>bold\\</strong\>@ with
-- nothing declaring a region or switching a mode. There is no @markdown@
-- environment here and no root notation to escape from.
--
-- == Only inline constructs
--
-- A block reader would own paragraphs, lists, headings and fences, and would have
-- to run before inline parsing over lines this module never sees. What is read here
-- is what appears inside a line of text, which is what a slide's text content is.
-- 'SlideBlaster.Syntax.Surface.MdSpelling' already describes the block spellings,
-- so adding them later needs no change to the tree.
--
-- == Open recursion
--
-- The content parser arrives as an argument, taking the delimiter that must close
-- the construct. This module therefore knows nothing about LaTeX or HTML while
-- still allowing both inside emphasis, and the recursion is tied in exactly one
-- place, in "SlideBlaster.Syntax.Tex.Reader".
--
-- == Emphasis that is not emphasis
--
-- CommonMark decides whether a delimiter opens a span from what surrounds it, so
-- that @a * b@ is three words and @snake_case_name@ is one. This module gets the
-- same outcome from where it is tried rather than by looking backwards: it runs
-- only at a position where the previous construct ended, so a delimiter inside a
-- word is consumed as part of that word and never reaches here. What it does check
-- is that an opener is not followed by whitespace and that a closer exists at all.
-- A delimiter that opens nothing is not an error; it backtracks and is preserved as
-- the character it is.
module SlideBlaster.Syntax.Markdown.Reader
  ( markdownInline
  , emphasisDelimiters
  ) where

import SlideBlaster.Syntax.Ast
  ( ItemF (ItemF)
  , ListKind (Ordered, Unordered)
  , Node
  , NodeF (Items, Linked, Styled, Verbatim)
  , node
  )
import SlideBlaster.Syntax.Style
  ( Slant (Italic)
  , StyleValue (SetHighlight, SetSlant, SetStrike, SetWeight)
  , Weight (Bold)
  , styleMapFromList
  )
import SlideBlaster.Syntax.Surface
  ( MdSpelling
      ( MdBullet
      , MdCodeSpan
      , MdDelimited
      , MdInlineLink
      , MdItem
      , MdOrdered
      )
  , Surface (MarkdownSurface)
  )

import Control.Applicative (empty, many, (<|>))
import Data.Char (isDigit, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Text.Megaparsec
  ( MonadParsec
  , choice
  , chunk
  , notFollowedBy
  , satisfy
  , takeWhile1P
  , takeWhileP
  , try
  )
import Text.Megaparsec.Char (char)

-- | One inline Markdown construct.
--
-- The first argument builds a content parser that stops at the given closing
-- delimiter. The second parses the content of one list item, stopping at the end of
-- its line. The third says whether this position begins a line, which is the only
-- place a list item may start.
markdownInline
  :: (MonadParsec e Text m) => (Text -> m [Node]) -> m [Node] -> Bool -> m Node
markdownInline content itemContent atLineStart =
  choice
    [ codeSpan
    , if atLineStart then markdownList itemContent else empty
    , inlineLink content
    , emphasis content
    ]

-- | A bullet or ordered list, one item per line.
--
-- The list ends at the first line that does not begin with a marker, and the line
-- ending before that line is left unconsumed, so a list inside a node body is
-- framed by the whitespace around it rather than swallowing it.
--
-- Each item retains the exact indentation, marker and following spaces it was
-- written with, so @-@, @*@ and @+@ come back as themselves and an ordered list
-- keeps its own numbering.
markdownList :: (MonadParsec e Text m) => m [Node] -> m Node
markdownList itemContent = try $ do
  (first, kind) <- itemAt Text.empty
  rest <- many (try (continuation kind))
  pure
    ( node
        ( Items
            (listKind kind)
            (MarkdownSurface (listSurface kind))
            []
            (first : rest)
        )
    )
  where
    -- A later item carries the line ending and indentation that precede it, which
    -- is how the whole list reprints exactly.
    continuation kind = do
      ending <- lineEnding
      (item, itemKind) <- itemAt ending
      if itemKind == kind then pure item else empty
    itemAt leading = do
      indent <- takeWhileP Nothing (\c -> c == ' ' || c == '\t')
      (marker, kind) <- listMarker
      spacing <- takeWhile1P Nothing (\c -> c == ' ' || c == '\t')
      children <- itemContent
      pure
        ( ItemF
            (MarkdownSurface (MdItem (leading <> indent) marker spacing))
            Nothing
            children
        , kind
        )

-- | Whether a list is bulleted or numbered.
data ListMarkerKind = BulletMarker | OrderedMarker
  deriving stock (Eq)

listKind :: ListMarkerKind -> ListKind
listKind kind =
  case kind of
    BulletMarker -> Unordered
    OrderedMarker -> Ordered

listSurface :: ListMarkerKind -> MdSpelling
listSurface kind =
  case kind of
    BulletMarker -> MdBullet
    OrderedMarker -> MdOrdered

-- | A single item marker, retained as written.
listMarker :: (MonadParsec e Text m) => m (Text, ListMarkerKind)
listMarker = bullet <|> ordered
  where
    bullet = do
      character <- satisfy (\c -> c == '-' || c == '*' || c == '+')
      pure (Text.singleton character, BulletMarker)
    ordered = try $ do
      digits <- takeWhile1P Nothing isDigit
      terminator <- satisfy (\c -> c == '.' || c == ')')
      pure (digits <> Text.singleton terminator, OrderedMarker)

-- | One line ending, in either spelling.
lineEnding :: (MonadParsec e Text m) => m Text
lineEnding = chunk "\r\n" <|> chunk "\n" <|> chunk "\r"

-- | @**text**@ and its relatives, longest delimiter first.
--
-- Order matters: @**@ must be attempted before @*@, or a strong span would be read
-- as an emphasis span containing one.
emphasis :: (MonadParsec e Text m) => (Text -> m [Node]) -> m Node
emphasis content =
  choice [try (delimited content marker fact) | (marker, fact) <- emphasisDelimiters]

-- | The delimiter runs this reader understands, and what each asserts.
--
-- Longest first, because @**@ and @__@ must win over @*@ and @_@.
emphasisDelimiters :: [(Text, StyleValue)]
emphasisDelimiters =
  [ ("**", SetWeight Bold)
  , ("__", SetWeight Bold)
  , ("~~", SetStrike True)
  , ("==", SetHighlight True)
  , ("*", SetSlant Italic)
  , ("_", SetSlant Italic)
  ]

delimited
  :: (MonadParsec e Text m) => (Text -> m [Node]) -> Text -> StyleValue -> m Node
delimited content marker fact = do
  _ <- chunk marker
  -- An opener immediately followed by whitespace opens nothing, which is what
  -- keeps @a * b@ from becoming emphasis.
  notFollowedBy spaceCharacter
  children <- content marker
  _ <- chunk marker
  -- A span with no content is not a span: @****@ is four characters. Rejecting it
  -- here rather than producing an empty construct keeps the printer's output equal
  -- to the input.
  if null children
    then empty
    else
      pure
        ( node
            ( Styled
                (styleMapFromList [fact])
                (MarkdownSurface (MdDelimited marker))
                children
            )
        )

-- | @`code`@, whose content is literal text rather than markup.
--
-- The backtick count is retained, because a span may be opened with more than one
-- so that its content can contain a backtick.
codeSpan :: (MonadParsec e Text m) => m Node
codeSpan = try $ do
  opening <- takeWhile1P Nothing (== '`')
  let fence = Text.length opening
  body <- takeWhile1P Nothing (/= '`')
  _ <- chunk opening
  pure (node (Verbatim (MarkdownSurface (MdCodeSpan fence)) body))

-- | @[text](target)@.
--
-- The target is retained exactly as written, including any title, because this
-- reader does not interpret it and reprinting must be byte-for-byte.
inlineLink :: (MonadParsec e Text m) => (Text -> m [Node]) -> m Node
inlineLink content = try $ do
  _ <- char '['
  children <- content "]"
  _ <- char ']'
  _ <- char '('
  target <- takeWhile1P Nothing (\c -> c /= ')' && c /= '\n')
  _ <- char ')'
  if null children
    then empty
    else
      pure
        ( node
            (Linked (MarkdownSurface (MdInlineLink target)) children)
        )

-- | A single whitespace character.
spaceCharacter :: (MonadParsec e Text m) => m Char
spaceCharacter = satisfy isSpace
