{-# LANGUAGE DeriveTraversable #-}

-- |
-- Module      : SlideBlaster.Syntax.Ast
-- Description : One semantic tree for TeX, HTML and Markdown mixed freely.
--
-- Slide content mixes three dialects and nests them: @\\textbf{**x**}@ is TeX
-- containing Markdown, @\<div\>\\begin{itemize}@ is HTML containing TeX. This is
-- one tree rather than three, because the dialects overlap in meaning and differ
-- only in spelling. Bold is 'Styled' with a weight fact whether it was written
-- @\\textbf{x}@, @**x**@ or @\<strong\>x\</strong\>@; the difference is carried by
-- 'SlideBlaster.Syntax.Surface.Surface'.
--
-- == Why not one tree per dialect
--
-- A coproduct of three dialect trees makes @bold@ three different constructors, so
-- every semantic pass has three cases for one concept, and every edit has to map
-- back from meaning to the right dialect constructor. That inverse mapping is the
-- unimplemented @ProjectionRule@ in the document package. Carrying the dialect as
-- data instead of as a constructor removes the need for it: an edit changes a
-- style fact, the surface is untouched, and the printer re-spells the construct the
-- way the author wrote it.
--
-- == Exactness
--
-- Printing any tree obtained from reading input reproduces that input character
-- for character. This is what removes any need for source spans or byte offsets:
-- the tree is both the meaning and the source, and an edit is a tree
-- transformation.
--
-- == Structure
--
-- The recursive position is a parameter, so 'NodeF' is a 'Functor', 'Foldable' and
-- 'Traversable', and passes are folds from "SlideBlaster.Syntax.Fix".
--
-- Constructs that exist in only one dialect and have exactly one spelling carry no
-- surface, because their constructor already determines how they print: 'Math',
-- 'Define', 'MacroUse', 'Parameter' and 'Alignment' are TeX and nothing else.
module SlideBlaster.Syntax.Ast
  ( -- * Tree
    NodeF (..)
  , Node
  , ItemF (..)
  , ArgumentF (..)

    -- * Semantic vocabulary
  , ListKind (..)
  , BreakKind (..)
  , MathForm (..)

    -- * Macros
  , MacroName (..)
  , DefinitionF (..)
  , DefinitionForm (..)
  , ParametersF (..)

    -- * Convenience
  , node
  , childrenOf
  , nodeDialect
  , nodeSpelledDialect
  , setPrimaryChildren
  ) where

import SlideBlaster.Syntax.Fix (Fix (Fix), unFix)
import SlideBlaster.Syntax.Style (StyleMap)
import SlideBlaster.Syntax.Surface (Dialect (Tex), Surface, dialectOf, spelledDialect)

import Data.Text (Text)

-- | A complete tree.
type Node = Fix NodeF

-- | Build one node.
node :: NodeF Node -> Node
node = Fix

-- | Every child of a node, in document order, including macro expansions.
childrenOf :: Node -> [Node]
childrenOf = foldr (:) [] . unFix

-- | The dialect a construct is written in, when it determines one.
--
-- 'Nothing' means the construct is spelled identically in every dialect and so
-- says nothing about which language surrounds it: whitespace is the only such
-- case. Constructs that exist in one dialect only report it even though they
-- carry no surface, because their constructor already fixes their language.
-- | Which dialect a construct commits its author to, if any.
--
-- The question an edit asks. 'nodeDialect' reports the notation a construct is
-- printed under; this reports only what the author actually chose, so a container
-- with no spelling and plain characters that would be identical in any notation
-- both answer 'Nothing'. Constructs that exist only in LaTeX answer 'Just' 'Tex'
-- even without a surface, because there is no other way to write them.
nodeSpelledDialect :: NodeF r -> Maybe Dialect
nodeSpelledDialect layer =
  case layer of
    Text surface _ -> spelledDialect surface
    Comment surface _ -> spelledDialect surface
    Run surface _ -> spelledDialect surface
    Styled _ surface _ -> spelledDialect surface
    Items _ surface _ _ -> spelledDialect surface
    Heading _ surface _ -> spelledDialect surface
    Quote surface _ -> spelledDialect surface
    Verbatim surface _ -> spelledDialect surface
    Linked surface _ -> spelledDialect surface
    Break _ surface -> spelledDialect surface
    Foreign surface _ -> spelledDialect surface
    Math _ _ -> Just Tex
    Define _ -> Just Tex
    MacroUse{} -> Just Tex
    Unresolved _ _ -> Just Tex
    Parameter _ -> Just Tex
    Alignment -> Just Tex
    Overlay _ -> Just Tex
    Environment{} -> Just Tex
    Whitespace _ -> Nothing

nodeDialect :: NodeF r -> Maybe Dialect
nodeDialect layer =
  case layer of
    Text surface _ -> Just (dialectOf surface)
    Comment surface _ -> Just (dialectOf surface)
    Run surface _ -> Just (dialectOf surface)
    Styled _ surface _ -> Just (dialectOf surface)
    Items _ surface _ _ -> Just (dialectOf surface)
    Heading _ surface _ -> Just (dialectOf surface)
    Quote surface _ -> Just (dialectOf surface)
    Verbatim surface _ -> Just (dialectOf surface)
    Linked surface _ -> Just (dialectOf surface)
    Break _ surface -> Just (dialectOf surface)
    Foreign surface _ -> Just (dialectOf surface)
    Math _ _ -> Just Tex
    Define _ -> Just Tex
    MacroUse{} -> Just Tex
    Unresolved _ _ -> Just Tex
    Parameter _ -> Just Tex
    Alignment -> Just Tex
    Overlay _ -> Just Tex
    Environment{} -> Just Tex
    Whitespace _ -> Nothing

-- | Replace a construct's children with a different number of them.
--
-- 'SlideBlaster.Syntax.Path' can navigate and substitute without knowing any
-- constructor, but it cannot change how many children a node has, because
-- 'traverse' preserves shape. Merging two adjacent constructs into one does
-- change the count, so that operation has to be written here, where the
-- constructors live.
--
-- 'Nothing' means the construct has no single child list to rewrite. Those
-- refusals are deliberate rather than unfinished: a list has both a preamble and
-- its items, a macro use has both an expansion and its arguments, and a
-- definition body is a template whose shape is its meaning. Restructuring any of
-- them from a flat list would have to guess which field the children belong to.
--
-- The identity @'setPrimaryChildren' ('Data.Foldable.toList' ('unFix' n)) n ==
-- 'Just' n@ holds for every constructor that answers, which is what keeps this
-- function honest about the child order 'SlideBlaster.Syntax.Path' uses.
setPrimaryChildren :: [Node] -> Node -> Maybe Node
setPrimaryChildren children tree =
  case unFix tree of
    Run surface _ -> Just (Fix (Run surface children))
    Styled facts surface _ -> Just (Fix (Styled facts surface children))
    Heading level surface _ -> Just (Fix (Heading level surface children))
    Quote surface _ -> Just (Fix (Quote surface children))
    Linked surface _ -> Just (Fix (Linked surface children))
    -- No child list at all.
    Text _ _ -> Nothing
    Whitespace _ -> Nothing
    Comment _ _ -> Nothing
    Verbatim _ _ -> Nothing
    Break _ _ -> Nothing
    Foreign _ _ -> Nothing
    Math _ _ -> Nothing
    Parameter _ -> Nothing
    Alignment -> Nothing
    -- More than one child list, so a flat list cannot say where they go.
    Items{} -> Nothing
    Define _ -> Nothing
    MacroUse{} -> Nothing
    Unresolved _ _ -> Nothing
    Overlay _ -> Nothing
    -- Argument groups lead the body, so a flat list cannot say where they go.
    Environment{} -> Nothing

-- | A control sequence name without its leading backslash.
newtype MacroName = MacroName Text
  deriving stock (Eq, Ord, Show)

-- | Which LaTeX2e definition command was used.
data DefinitionForm
  = NewCommandForm
  | RenewCommandForm
  | ProvideCommandForm
  | -- | @\\newenvironment{name}[n]{begin}{end}@.
    NewEnvironmentForm
  | RenewEnvironmentForm
  deriving stock (Eq, Ord, Show)

-- | A definition's parameter list: how many mandatory parameters, and the default
-- for a leading optional parameter when one was declared.
data ParametersF r = ParametersF
  { parameterCount :: !Int
  , parameterOptionalDefault :: !(Maybe [r])
  }
  deriving stock (Eq, Ord, Show, Functor, Foldable, Traversable)

-- | A user macro definition.
--
-- 'definitionNameBraced' records whether the author wrote @\\newcommand{\\R}@ or
-- @\\newcommand\\R@, both of which are legal and must reprint as written.
data DefinitionF r = DefinitionF
  { definitionForm :: !DefinitionForm
  , definitionName :: !MacroName
  , definitionNameBraced :: !Bool
  , definitionParameters :: !(ParametersF r)
  , definitionBody :: ![r]
  , -- | The closing half of an environment definition ('NewEnvironmentForm',
    -- 'RenewEnvironmentForm'); 'Nothing' for command definitions.
    definitionClose :: !(Maybe [r])
  }
  deriving stock (Eq, Ord, Show, Functor, Foldable, Traversable)

-- | One argument supplied to a macro use.
--
-- The leading 'Text' is the whitespace between the macro name, or the previous
-- argument, and this argument's opening delimiter. TeX skips that space when
-- reading, so it belongs to no other node, and without it @\\R {x}@ would reprint
-- as @\\R{x}@.
data ArgumentF r
  = -- | A braced mandatory argument.
    Mandatory !Text ![r]
  | -- | A bracketed optional argument.
    Optional !Text ![r]
  | -- | A Beamer overlay specification in angle brackets, such as @\<2->@. The
    -- first field is the whitespace before it and the second the specification
    -- without its brackets.
    Angle !Text !Text
  deriving stock (Eq, Ord, Show, Functor, Foldable, Traversable)

-- | One list item.
--
-- The label is an explicit @\\item[label]@ or HTML value; Markdown items have
-- none. The marker itself is spelling and lives in 'itemSurface'.
data ItemF r = ItemF
  { itemSurface :: !Surface
  , itemLabel :: !(Maybe [r])
  , itemBody :: ![r]
  }
  deriving stock (Eq, Ord, Show, Functor, Foldable, Traversable)

data ListKind
  = Unordered
  | Ordered
  | Described
  deriving stock (Eq, Ord, Show)

-- | A break, in whichever dialect wrote it.
data BreakKind
  = -- | A line ending inside a paragraph, which does not force a new line.
    SoftBreak
  | -- | An explicit line break: @\\\\@, @\<br\>@, or Markdown trailing spaces.
    HardBreak
  | -- | A horizontal rule: @\<hr\>@ or Markdown @---@.
    ThematicBreak
  deriving stock (Eq, Ord, Show)

data MathForm
  = InlineDollar
  | InlineParen
  | DisplayDoubleDollar
  | DisplayBracket
  deriving stock (Eq, Ord, Show)

-- | One layer of the tree, with @r@ standing for its children.
data NodeF r
  = -- | Text content. The surface says how it was written, so a TeX @\\%@, an
    -- HTML @&amp;@ and a plain character are all text whose value is the character
    -- it denotes.
    Text !Surface !Text
  | -- | An exact whitespace run, including line endings. Whitespace is spelled the
    -- same way in every dialect, so it carries no surface.
    Whitespace !Text
  | -- | A comment body, excluding its delimiters.
    Comment !Surface !Text
  | -- | A transparent container: a TeX group, a substituted argument, a Markdown
    -- paragraph, an HTML element with no other meaning.
    Run !Surface ![r]
  | -- | Styled content. The facts are what the construct sets; the surface is how
    -- it was written.
    Styled !StyleMap !Surface ![r]
  | -- | A list. The second field is content between the environment's start and
    -- its first item, normally whitespace or comments, retained so the environment
    -- reprints exactly. Markdown and HTML lists have none.
    Items !ListKind !Surface ![r] ![ItemF r]
  | -- | A heading of the given level.
    Heading !Int !Surface ![r]
  | -- | Quoted content.
    Quote !Surface ![r]
  | -- | Verbatim content, never interpreted: a Markdown code span or fence, an
    -- HTML raw-text element.
    Verbatim !Surface !Text
  | -- | A link. Its target is one-to-one with its spelling, so
    -- 'SlideBlaster.Syntax.Surface.linkTarget' reads it from the surface rather
    -- than duplicating it here.
    Linked !Surface ![r]
  | -- | A break.
    Break !BreakKind !Surface
  | -- | Syntactically well-formed input whose meaning is outside the supported
    -- subset. Preserved and printable, but read-only for the semantic layer.
    -- Widening support means recognising more constructs, never preserving less.
    Foreign !Surface !Text
  | -- | Math, whose payload stays uninterpreted. TeX only.
    Math !MathForm !Text
  | -- | A definition, which binds for the remainder of its scope. TeX only.
    Define !(DefinitionF r)
  | -- | A use of a macro. The first field is its expansion once expansion has run,
    -- and is never read by the printer, which is what makes expansion
    -- one-directional. TeX only.
    MacroUse !(Maybe [r]) !MacroName ![ArgumentF r]
  | -- | A control sequence whose meaning is unknown. Its name is semantic, because
    -- a later definition can bind it. TeX only.
    Unresolved !MacroName ![ArgumentF r]
  | -- | Macro parameter marker, meaningful inside a definition body. TeX only.
    Parameter !Text
  | -- | Alignment tab @&@, meaningful inside tabular and matrix environments. TeX
    -- only.
    Alignment
  | -- | A stand-alone overlay specification @\<spec>@ (spec text without the
    -- angle brackets), such as the trailing @\<2->@ on a Markdown item or after a
    -- macro use. Command-attached specifications are 'Angle' arguments instead.
    Overlay !Text
  | -- | A LaTeX environment other than the list environments. The first field is
    -- the expansion when the environment is user-defined with @\\newenvironment@
    -- (never read by the printer); the body includes the environment's argument
    -- groups as its leading siblings, exactly as written.
    Environment !(Maybe [r]) !Text ![r]
  deriving stock (Eq, Ord, Show, Functor, Foldable, Traversable)
