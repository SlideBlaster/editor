{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Surface
-- Description : How a construct was written, in whichever dialect wrote it.
--
-- The tree in "SlideBlaster.Syntax.Ast" says what a construct /means/. This module
-- says how it was /spelled/. Splitting them is what lets one node type serve three
-- dialects: @\\textbf{x}@ and @**x**@ are the same node with different surfaces.
--
-- Two consequences follow, and they are the point of the whole design.
--
-- Reprinting is exact, because the surface retains every incidental detail:
-- attribute quoting, element-name case, which of @*@ or @_@ delimited an emphasis,
-- how many backticks fenced a block.
--
-- Editing keeps the author's dialect without an inverse rule. Changing a
-- construct's style changes a style fact and leaves its surface alone, so the
-- printer re-spells it the way the author wrote it. There is nothing to invert,
-- because nothing was ever normalized away.
--
-- == What belongs here
--
-- A detail belongs in the surface when it is one-to-one with its meaning, and in
-- the tree when it is many-to-one. Bold is many-to-one — three dialects spell it
-- three ways — so it is a style fact. A link's URL is one-to-one: the text @\/a\/b@
-- /is/ the target, in every dialect, so it stays here and 'linkTarget' reads it.
module SlideBlaster.Syntax.Surface
  ( -- * Dialects
    Dialect (..)
  , Surface (..)
  , dialectOf
  , spelledDialect
  , hostedDialects

    -- * TeX
  , TexSpelling (..)

    -- * Markdown
  , MdSpelling (..)

    -- * HTML
  , HtmlSpelling (..)
  , ElementName
  , elementName
  , elementNameText
  , elementNameLower
  , isVoidElement
  , isRawTextElement
  , TagForm (..)
  , Attribute (..)
  , AttributeValue (..)
  , QuoteStyle (..)
  , Declaration (..)

    -- * Derived reads
  , linkTarget
  , surfaceCarriesStyleValue
  , declarationKey
  ) where

import SlideBlaster.Syntax.Style (StyleKey (..))

import Data.Text (Text)
import Data.Text qualified as Text

-- | The surface language that authored a construct.
data Dialect
  = Tex
  | Html
  | Markdown
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | How one construct was written.
data Surface
  = TexSurface !TexSpelling
  | HtmlSurface !HtmlSpelling
  | MarkdownSurface !MdSpelling
  | -- | A construct with no spelling of its own: it prints its children and
    -- nothing else, while still recording which dialect it belongs to.
    --
    -- Two operations need this. Substituting a macro argument for a @#1@
    -- parameter must be a node-to-node rewrite, and removing a style must unwrap
    -- one construct into however many children it had. Both are the same idea, so
    -- both use this rather than one spelling per dialect.
    Transparent !Dialect
  deriving stock (Eq, Ord, Show)

-- | Which dialect authored a construct. Total, so dialect has a single source of
-- truth and cannot disagree with the spelling it came from.
dialectOf :: Surface -> Dialect
dialectOf surface =
  case surface of
    TexSurface _ -> Tex
    HtmlSurface _ -> Html
    MarkdownSurface _ -> Markdown
    Transparent dialect -> dialect

-- | Which notation this spelling actually commits the author to, if any.
--
-- Distinct from 'dialectOf', which always answers, because two kinds of construct
-- commit to nothing and a new construct placed at one of them must not be written
-- as though they had.
--
-- A 'Transparent' container has no spelling at all. The document container that
-- holds a whole fragment is one of these, and authored input has no outermost
-- notation for it to stand for: the input is one mixed language, not a LaTeX file
-- that happens to contain other markup.
--
-- Ordinary characters commit to nothing either. @plain@ is the same bytes in all
-- three notations, and which reader consumed it is an accident of how this package
-- is structured rather than a statement by the author. 'dialectOf' still reports a
-- dialect for them, which is what the printer's escaping and the host's run
-- labelling want; this is the different question of what an edit may assume.
spelledDialect :: Surface -> Maybe Dialect
spelledDialect surface =
  case surface of
    TexSurface TexChars -> Nothing
    TexSurface _ -> Just Tex
    HtmlSurface HtmlChars -> Nothing
    HtmlSurface _ -> Just Html
    MarkdownSurface MdChars -> Nothing
    MarkdownSurface _ -> Just Markdown
    Transparent _ -> Nothing

-- | The dialects a construct nested inside this one may be written in, innermost
-- first.
--
-- When an edit has to create a construct it is written in the language that
-- already surrounds it: adding bold inside a LaTeX construct produces @\\textbf@,
-- and inside a Markdown one @**@. That is always the first entry, and it is not a
-- preference that could be reordered.
--
-- The later entries matter only when the surrounding language cannot spell the
-- property at all. Authored input is one mixed language in which all three
-- notations are directly writable, so falling back to another of them yields text
-- the author could have typed and that this package reads back. Nothing compiles
-- the input as a LaTeX document, so @\<s\>@ among LaTeX-spelled content breaks
-- no build; refusing the style instead would deny an author something the language
-- plainly permits.
--
-- HTML is last everywhere because CSS expresses everything this model carries, and
-- for the same reason it needs no guest of its own. Markdown, which has markup for
-- only a few properties, is nobody's fallback.
--
-- A property none of the admissible dialects can spell is still refused.
hostedDialects :: Dialect -> [Dialect]
hostedDialects dialect =
  case dialect of
    Tex -> [Tex, Html]
    Markdown -> [Markdown, Html]
    Html -> [Html]

-- | How a TeX construct was written.
data TexSpelling
  = -- | Ordinary characters.
    TexChars
  | -- | A backslash-escaped literal character such as @\\{@ or @\\%@. The node's
    -- text is the character itself, so the escape is spelling, not content.
    TexEscaped
  | -- | @%@ comment.
    TexComment
  | -- | @{ ... }@, which scopes declarations.
    TexBraceGroup
  | -- | @\\bgroup ... \\egroup@.
    TexBeginEndGroup
  | -- | @\\textbf{x}@: a command taking its content as an argument.
    TexCommand !Text
  | -- | @{\\bfseries x}@: a declaration whose scope is the rest of its group.
    TexDeclaration !Text
  | -- | @\\begin{itemize} ... \\end{itemize}@.
    TexEnvironment !Text
  | -- | @\\item@.
    TexItem
  | -- | @\\textcolor{red}{x}@: a command whose first argument is the colour it
    -- sets. The colour itself is a style fact, so an edit changes the fact and the
    -- printer regenerates this argument.
    TexColourCommand !Text
  | -- | @{\\color{red} x}@: a colour declaration scoped to its group.
    TexColourDeclaration !Text
  | -- | A control symbol such as @\\\\@.
    TexControlSymbol !Text
  deriving stock (Eq, Ord, Show)

-- | How a Markdown construct was written.
data MdSpelling
  = MdChars
  | -- | The exact delimiter that opened and closed a span: @**@, @__@, @*@, @_@,
    -- @==@, @~~@.
    MdDelimited !Text
  | -- | @## Title ##@: whitespace after the hashes, then any closing hashes.
    MdAtxHeading !Text !Text
  | -- | @Title@ followed by an underline, retained exactly.
    MdSetextHeading !Text
  | MdParagraph
  | -- | The @\>@ prefix of each quoted line.
    MdQuote !Text
  | -- | An item's indentation, marker and following whitespace.
    MdItem !Text !Text !Text
  | -- | Bullet list.
    MdBullet
  | -- | Ordered list.
    MdOrdered
  | -- | Fence character, fence length, and info string.
    MdFenced !Char !Int !Text
  | MdIndentedCode
  | -- | Backtick count of a code span.
    MdCodeSpan !Int
  | -- | @[text](target)@, retaining the target text.
    MdInlineLink !Text
  | -- | @[text][label]@, retaining the label.
    MdReferenceLink !Text
  | -- | @\<https:\/\/example.com\>@.
    MdAutoLink !Text
  | -- | Exact characters of a thematic break.
    MdThematicBreak !Text
  | -- | A line ending inside a paragraph.
    MdSoftBreak !Text
  | -- | Trailing spaces or a backslash before a line ending.
    MdHardBreak !Text
  | -- | One or more blank lines between blocks.
    MdBlankLines !Text
  deriving stock (Eq, Ord, Show)

-- | An element name, retaining the author's case while exposing a normalized form
-- for comparison. HTML names are case-insensitive but must reprint exactly.
data ElementName = ElementName
  { elementNameText :: !Text
  , elementNameLower :: !Text
  }
  deriving stock (Eq, Ord, Show)

-- | Construct an element name from its authored spelling.
elementName :: Text -> ElementName
elementName written =
  ElementName
    { elementNameText = written
    , elementNameLower = Text.toLower written
    }

-- | Elements that never have children or a closing tag.
isVoidElement :: ElementName -> Bool
isVoidElement name =
  elementNameLower name
    `elem` [ "area"
           , "base"
           , "br"
           , "col"
           , "embed"
           , "hr"
           , "img"
           , "input"
           , "link"
           , "meta"
           , "source"
           , "track"
           , "wbr"
           ]

-- | Elements whose content is not parsed as markup.
isRawTextElement :: ElementName -> Bool
isRawTextElement name =
  elementNameLower name `elem` ["script", "style", "textarea", "title"]

-- | How a tag was written, so it reprints identically.
data TagForm
  = -- | @\<p\>...\</p\>@
    NormalTag
  | -- | @\<br/\>@, an explicit self-closing solidus.
    SelfClosingTag
  | -- | @\<br\>@, a void element with no solidus.
    VoidTag
  deriving stock (Eq, Ord, Show)

-- | How an attribute value was quoted.
data QuoteStyle
  = DoubleQuoted
  | SingleQuoted
  | Unquoted
  deriving stock (Eq, Ord, Show)

-- | One CSS declaration inside a @style@ attribute.
--
-- 'declarationText' is the exact source of this declaration including its
-- surrounding whitespace and trailing semicolon, so untouched declarations reprint
-- byte for byte while an edited one is regenerated.
data Declaration = Declaration
  { declarationProperty :: !Text
  , declarationValue :: !Text
  , declarationImportant :: !Bool
  , declarationText :: !Text
  }
  deriving stock (Eq, Ord, Show)

-- | An attribute value. @style@ is structured; everything else is opaque text.
data AttributeValue
  = PlainValue !Text
  | StyleValue ![Declaration]
  deriving stock (Eq, Ord, Show)

-- | One attribute. A boolean attribute has no value. 'attributeBefore' is the
-- whitespace preceding it, so attribute spacing reprints exactly.
data Attribute = Attribute
  { attributeName :: !Text
  , attributeValue :: !(Maybe AttributeValue)
  , attributeQuote :: !QuoteStyle
  , attributeBefore :: !Text
  }
  deriving stock (Eq, Ord, Show)

-- | How an HTML construct was written.
data HtmlSpelling
  = -- | An element: name, attributes, whitespace before the open tag's @\>@, and
    -- how the tag was closed.
    HtmlElement !ElementName ![Attribute] !Text !TagForm
  | HtmlChars
  | -- | A character reference, retaining the authored name so @&amp;@ does not
    -- reprint as @&@.
    HtmlEntity !Text
  | -- | @\<!-- ... --\>@.
    HtmlComment
  | -- | A raw-text element whose content is not markup.
    HtmlRawText !ElementName ![Attribute] !Text
  deriving stock (Eq, Ord, Show)

-- | The target of a link, read from its spelling.
--
-- One-to-one details stay in the surface, so this is a derived read rather than a
-- stored field. That removes any possibility of a stored target disagreeing with
-- the text that will be printed.
linkTarget :: Surface -> Maybe Text
linkTarget surface =
  case surface of
    MarkdownSurface (MdInlineLink target) -> Just target
    MarkdownSurface (MdReferenceLink label) -> Just label
    MarkdownSurface (MdAutoLink target) -> Just target
    HtmlSurface (HtmlElement _ attributes _ _) -> attributeText "href" attributes
    TexSurface _ -> Nothing
    _ -> Nothing
  where
    attributeText wanted attributes =
      case [value | Attribute name (Just value) _ _ <- attributes, name == wanted] of
        PlainValue value : _ -> Just value
        _ -> Nothing

-- | Whether this spelling prints one property's value from the style fact, rather
-- than encoding that property in the spelling itself.
--
-- The distinction decides what an edit has to do. @\\textcolor@ prints whatever
-- colour the fact holds, so changing the colour changes only the fact and the
-- author keeps their command. @\\textbf@ /is/ the assertion of boldness, so
-- changing the weight fact without changing the spelling would leave the two
-- disagreeing; such an edit must re-spell.
--
-- The property matters, not just the spelling: @\<strong style="color:red"\>@
-- prints its colour from the fact but asserts its weight in the tag name, so the
-- same surface answers differently for the two keys. Being derived rather than
-- stored, this cannot fall out of step with what the printer does.
surfaceCarriesStyleValue :: StyleKey -> Surface -> Bool
surfaceCarriesStyleValue key surface =
  case surface of
    TexSurface (TexColourCommand _) -> key == ForegroundKey
    TexSurface (TexColourDeclaration _) -> key == ForegroundKey
    HtmlSurface (HtmlElement _ attributes _ _) -> declaredIn attributes
    HtmlSurface (HtmlRawText _ attributes _) -> declaredIn attributes
    _ -> False
  where
    declaredIn attributes =
      or
        [ declarationKey declaration == Just key
        | Attribute name (Just (StyleValue declarations)) _ _ <- attributes
        , Text.toLower name == "style"
        , declaration <- declarations
        ]

-- | The property a CSS declaration sets, when this model has one.
--
-- Shared by the reader, the printer and the edit path so that what is recognised,
-- what is regenerated, and what an edit may change in place can never diverge.
declarationKey :: Declaration -> Maybe StyleKey
declarationKey declaration =
  case declarationProperty declaration of
    "color" -> Just ForegroundKey
    "background-color" -> Just BackgroundKey
    "font-weight" -> Just WeightKey
    "font-style" -> Just SlantKey
    "font-family" -> Just FamilyKey
    "font-variant" -> Just VariantKey
    "text-decoration" ->
      case declarationValue declaration of
        "line-through" -> Just StrikeKey
        _ -> Just UnderlineKey
    _ -> Nothing
