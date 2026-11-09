{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Printer
-- Description : Exact reprinting of the mixed tree, as one fold.
--
-- One printer for three dialects, because there is one tree. Each node prints from
-- its surface, so a construct comes back in the dialect that authored it, and a
-- construct whose style was edited comes back re-spelled in that same dialect.
--
-- The contract is exactness: for any tree obtained by reading input, printing
-- reproduces that input character for character.
--
-- The printer never reads a macro expansion. That is what makes expansion
-- one-directional structurally rather than by convention: a macro use prints from
-- its authored name and arguments, so no edit inside an expansion can leak into the
-- document.
module SlideBlaster.Syntax.Printer
  ( printNode
  , printNodes
  , printLayer
  , printColourExpr
  ) where

import SlideBlaster.Syntax.Ast
  ( ArgumentF (Angle, Mandatory, Optional)
  , BreakKind (HardBreak, SoftBreak, ThematicBreak)
  , DefinitionF (..)
  , DefinitionForm (NewCommandForm, NewEnvironmentForm, ProvideCommandForm, RenewCommandForm, RenewEnvironmentForm)
  , ItemF (ItemF)
  , MacroName (MacroName)
  , MathForm (..)
  , Node
  , NodeF (..)
  , ParametersF (..)
  )
import SlideBlaster.Syntax.Fix (cata)
import SlideBlaster.Syntax.Colour (resolveColour, rgbToHex)
import SlideBlaster.Syntax.Style
  ( ColourExpr (..)
  , ColourModel (GrayModel, HtmlModel, NamedModel, RgbModel)
  , Family (Monospace, SansSerif, Serif)
  , Literal (literalText)
  , Slant (Italic, Upright)
  , StyleKey (ForegroundKey)
  , StyleMap
  , StyleValue (..)
  , Variant (NormalVariant, SmallCaps)
  , Weight (Bold, NormalWeight)
  , lookupStyle
  )
import SlideBlaster.Syntax.Surface
  ( Attribute (..)
  , AttributeValue (PlainValue, StyleValue)
  , Declaration (..)
  , ElementName
  , HtmlSpelling (..)
  , MdSpelling (..)
  , QuoteStyle (DoubleQuoted, SingleQuoted, Unquoted)
  , Surface (HtmlSurface, MarkdownSurface, TexSurface, Transparent)
  , TagForm (NormalTag, SelfClosingTag, VoidTag)
  , TexSpelling (..)
  , declarationKey
  , elementNameText
  )

import Data.Text (Text)
import Data.Text qualified as Text

-- | Reprint a tree exactly as authored.
printNode :: Node -> Text
printNode = cata printLayer

-- | Reprint a run of trees.
printNodes :: [Node] -> Text
printNodes = foldMap printNode

-- | Print one layer whose children are already printed.
printLayer :: NodeF Text -> Text
printLayer layer =
  case layer of
    Text surface value -> printText surface value
    Whitespace value -> value
    Comment surface value -> printComment surface value
    Run surface children -> wrap surface (mconcat children)
    Styled facts surface children ->
      printStyled facts surface (mconcat children)
    Heading level surface children ->
      printHeading level surface (mconcat children)
    Quote surface children -> wrap surface (mconcat children)
    Items _ surface preamble items ->
      printItems surface (mconcat preamble) items
    Verbatim surface value -> printVerbatim surface value
    Linked surface children -> printLinked surface (mconcat children)
    Break kind surface -> printBreak kind surface
    Foreign _ value -> value
    Math form payload -> printMath form payload
    Define definition -> printDefinition definition
    MacroUse _ name arguments -> control name <> foldMap printArgument arguments
    Unresolved name arguments -> control name <> foldMap printArgument arguments
    Parameter value -> Text.cons '#' value
    Alignment -> "&"
    Overlay spec -> "<" <> spec <> ">"
    Environment _ name body -> environment name (mconcat body)

-- | A styled construct prints from its surface, except where the spelling embeds a
-- style fact as an argument. That is what makes an edit dialect-preserving with no
-- inverse rule: changing the colour changes the fact, and the argument is
-- regenerated here.
printStyled :: StyleMap -> Surface -> Text -> Text
printStyled facts surface body =
  case surface of
    TexSurface (TexColourCommand name) ->
      "\\" <> name <> "{" <> colour <> "}{" <> body <> "}"
    TexSurface (TexColourDeclaration name) ->
      "\\" <> name <> "{" <> colour <> "}" <> body
    HtmlSurface (HtmlElement name attributes trailing form) ->
      printElement name (fmap (restated facts) attributes) trailing form body
    HtmlSurface (HtmlRawText name attributes trailing) ->
      printElement name (fmap (restated facts) attributes) trailing NormalTag body
    _ -> wrap surface body
  where
    colour =
      case lookupStyle ForegroundKey facts of
        Just (SetForeground expression) -> printColourExpr expression
        _ -> Text.empty

-- | Rewrite a @style@ attribute so its declarations agree with the style facts.
--
-- Only declarations whose value actually differs are rewritten. Everything
-- else, including every property this model does not know, is emitted from its
-- authored text, so editing a colour cannot discard a font size sitting beside it.
restated :: StyleMap -> Attribute -> Attribute
restated facts attribute
  | Text.toLower (attributeName attribute) == "style"
  , Just (StyleValue declarations) <- attributeValue attribute =
      attribute
        { attributeValue = Just (StyleValue (fmap (restateDeclaration facts) declarations))
        }
  | otherwise = attribute

restateDeclaration :: StyleMap -> Declaration -> Declaration
restateDeclaration facts declaration =
  case declarationKey declaration >>= (`lookupStyle` facts) of
    Nothing -> declaration
    Just value ->
      case cssValue value of
        Nothing -> declaration
        Just replacement
          | replacement == declarationValue declaration -> declaration
          | otherwise ->
              declaration
                { declarationValue = replacement
                , declarationText = rewritten replacement
                }
  where
    -- The authored text is reproduced around the value, so the separator and
    -- spacing the author chose survive a change to what is between them.
    rewritten replacement =
      let text = declarationText declaration
          (before, rest) = Text.breakOn ":" text
          suffix = if Text.isSuffixOf ";" text then ";" else Text.empty
          spacing =
            Text.takeWhile (== ' ') (Text.drop 1 rest)
       in before <> ":" <> spacing <> replacement <> important <> suffix
    important
      | declarationImportant declaration = " !important"
      | otherwise = Text.empty

-- | How a style fact is written as a CSS value.
cssValue :: StyleValue -> Maybe Text
cssValue value =
  case value of
    SetForeground expression -> Just (cssColour expression)
    SetBackground expression -> Just (cssColour expression)
    SetWeight Bold -> Just "bold"
    SetWeight NormalWeight -> Just "normal"
    SetSlant Italic -> Just "italic"
    SetSlant Upright -> Just "normal"
    SetFamily Monospace -> Just "monospace"
    SetFamily Serif -> Just "serif"
    SetFamily SansSerif -> Just "sans-serif"
    SetVariant SmallCaps -> Just "small-caps"
    SetVariant NormalVariant -> Just "normal"
    SetUnderline True -> Just "underline"
    SetUnderline False -> Just "none"
    SetStrike True -> Just "line-through"
    SetStrike False -> Just "none"
    -- No CSS property corresponds, so the declaration is left as authored.
    SetHighlight _ -> Nothing

-- | A colour expression as CSS. Named colours and hex literals are written
-- directly; anything computed is resolved, because CSS has no mixing syntax.
cssColour :: ColourExpr -> Text
cssColour expression =
  case expression of
    ColourName name -> name
    ColourLiteral HtmlModel digits -> "#" <> digits
    _ ->
      case resolveColour expression of
        Right rgb -> rgbToHex rgb
        Left _ -> printColourExpr expression

-- | Wrap a body in whatever delimiters its surface calls for. Used by every
-- container, because in all three dialects a container is exactly a delimiter pair
-- around its content.
wrap :: Surface -> Text -> Text
wrap surface body =
  case surface of
    TexSurface spelling -> wrapTex spelling body
    MarkdownSurface spelling -> wrapMarkdown spelling body
    HtmlSurface spelling -> wrapHtml spelling body
    Transparent _ -> body

wrapTex :: TexSpelling -> Text -> Text
wrapTex spelling body =
  case spelling of
    TexBraceGroup -> "{" <> body <> "}"
    TexBeginEndGroup -> "\\bgroup" <> body <> "\\egroup"
    TexCommand name -> "\\" <> name <> "{" <> body <> "}"
    -- A declaration is not wrapped: its scope is the enclosing group, which
    -- prints its own braces.
    TexDeclaration name -> "\\" <> name <> body
    TexEnvironment name -> environment name body
    TexControlSymbol symbol -> "\\" <> symbol <> body
    TexItem -> "\\item" <> body
    TexChars -> body
    TexEscaped -> body
    TexComment -> body
    -- A colour spelling carries no colour of its own: the colour is a style
    -- fact, and printStyled supplies it. These cases are reachable only if a
    -- colour spelling is attached to something that is not a styled construct,
    -- which no reader produces. An empty colour argument keeps the output
    -- well-formed rather than silently dropping the command.
    TexColourCommand name -> "\\" <> name <> "{}{" <> body <> "}"
    TexColourDeclaration name -> "\\" <> name <> "{}" <> body

wrapMarkdown :: MdSpelling -> Text -> Text
wrapMarkdown spelling body =
  case spelling of
    MdDelimited delimiter -> delimiter <> body <> delimiter
    MdQuote prefix -> prefix <> body
    MdParagraph -> body
    MdItem indent marker after -> indent <> marker <> after <> body
    _ -> body

wrapHtml :: HtmlSpelling -> Text -> Text
wrapHtml spelling body =
  case spelling of
    HtmlElement name attributes trailing form ->
      printElement name attributes trailing form body
    HtmlRawText name attributes trailing ->
      printElement name attributes trailing NormalTag body
    HtmlChars -> body
    HtmlEntity _ -> body
    HtmlComment -> body

printElement :: ElementName -> [Attribute] -> Text -> TagForm -> Text -> Text
printElement name attributes trailing form body =
  case form of
    VoidTag -> open <> ">"
    SelfClosingTag -> open <> "/>"
    NormalTag -> open <> ">" <> body <> "</" <> written <> ">"
  where
    written = elementNameText name
    open = "<" <> written <> foldMap printAttribute attributes <> trailing

printAttribute :: Attribute -> Text
printAttribute attribute =
  attributeBefore attribute
    <> attributeName attribute
    <> maybe Text.empty assigned (attributeValue attribute)
  where
    assigned value = "=" <> quoted (attributeQuote attribute) (valueText value)
    valueText value =
      case value of
        PlainValue text -> text
        StyleValue declarations -> foldMap declarationText declarations
    quoted style text =
      case style of
        DoubleQuoted -> "\"" <> text <> "\""
        SingleQuoted -> "'" <> text <> "'"
        Unquoted -> text

printText :: Surface -> Text -> Text
printText surface value =
  case surface of
    TexSurface TexEscaped -> Text.cons '\\' value
    HtmlSurface (HtmlEntity name) -> "&" <> name <> ";"
    _ -> value

printComment :: Surface -> Text -> Text
printComment surface value =
  case surface of
    TexSurface _ -> "%" <> value
    HtmlSurface _ -> "<!--" <> value <> "-->"
    MarkdownSurface _ -> value
    Transparent _ -> value

-- | A Markdown ATX heading's hash count is its level, so it is regenerated rather
-- than stored twice.
printHeading :: Int -> Surface -> Text -> Text
printHeading level surface body =
  case surface of
    MarkdownSurface (MdAtxHeading afterHashes closing) ->
      Text.replicate level "#" <> afterHashes <> body <> closing
    MarkdownSurface (MdSetextHeading underline) -> body <> underline
    _ -> wrap surface body

printVerbatim :: Surface -> Text -> Text
printVerbatim surface value =
  case surface of
    MarkdownSurface (MdCodeSpan count) -> fence <> value <> fence
      where
        fence = Text.replicate count "`"
    MarkdownSurface (MdFenced character count info) ->
      fence <> info <> value <> fence
      where
        fence = Text.replicate count (Text.singleton character)
    MarkdownSurface MdIndentedCode -> value
    HtmlSurface (HtmlRawText name attributes trailing) ->
      printElement name attributes trailing NormalTag value
    _ -> value

printLinked :: Surface -> Text -> Text
printLinked surface body =
  case surface of
    MarkdownSurface (MdInlineLink target) ->
      "[" <> body <> "](" <> target <> ")"
    MarkdownSurface (MdReferenceLink label) ->
      "[" <> body <> "][" <> label <> "]"
    MarkdownSurface (MdAutoLink target) -> "<" <> target <> ">"
    _ -> wrap surface body

printBreak :: BreakKind -> Surface -> Text
printBreak kind surface =
  case surface of
    MarkdownSurface (MdSoftBreak value) -> value
    MarkdownSurface (MdHardBreak value) -> value
    MarkdownSurface (MdThematicBreak value) -> value
    MarkdownSurface (MdBlankLines value) -> value
    TexSurface (TexControlSymbol symbol) -> "\\" <> symbol
    HtmlSurface spelling -> wrapHtml spelling Text.empty
    _ ->
      case kind of
        SoftBreak -> "\n"
        HardBreak -> "\\\\"
        ThematicBreak -> Text.empty

printItems :: Surface -> Text -> [ItemF Text] -> Text
printItems surface preamble items =
  case surface of
    TexSurface (TexEnvironment name) ->
      environment name (preamble <> foldMap printItem items)
    _ -> wrap surface (preamble <> foldMap printItem items)

printItem :: ItemF Text -> Text
printItem (ItemF surface label body) =
  case surface of
    TexSurface TexItem ->
      "\\item" <> maybe Text.empty bracketed label <> mconcat body
    _ -> wrap surface (mconcat body)
  where
    bracketed children = "[" <> mconcat children <> "]"

environment :: Text -> Text -> Text
environment name body =
  "\\begin{" <> name <> "}" <> body <> "\\end{" <> name <> "}"

control :: MacroName -> Text
control (MacroName name) = Text.cons '\\' name

printArgument :: ArgumentF Text -> Text
printArgument argument =
  case argument of
    Mandatory before children -> before <> "{" <> mconcat children <> "}"
    Optional before children -> before <> "[" <> mconcat children <> "]"
    Angle before spec -> before <> "<" <> spec <> ">"

printMath :: MathForm -> Text -> Text
printMath form payload =
  case form of
    InlineDollar -> "$" <> payload <> "$"
    InlineParen -> "\\(" <> payload <> "\\)"
    DisplayDoubleDollar -> "$$" <> payload <> "$$"
    DisplayBracket -> "\\[" <> payload <> "\\]"

-- | Print an xcolor expression in its authored spelling.
printColourExpr :: ColourExpr -> Text
printColourExpr colour =
  case colour of
    ColourName name -> name
    ColourLiteral model payload ->
      "[" <> colourModelName model <> "]{" <> payload <> "}"
    ColourTint base percentage ->
      printColourExpr base <> "!" <> literalText percentage
    ColourMix base percentage other ->
      printColourExpr base
        <> "!"
        <> literalText percentage
        <> "!"
        <> printColourExpr other
    ColourComplement base -> "-" <> printColourExpr base

colourModelName :: ColourModel -> Text
colourModelName model =
  case model of
    NamedModel -> "named"
    RgbModel -> "rgb"
    GrayModel -> "gray"
    HtmlModel -> "HTML"

printDefinition :: DefinitionF Text -> Text
printDefinition definition =
  "\\"
    <> definitionFormName (definitionForm definition)
    <> name
    <> parameters
    <> "{"
    <> mconcat (definitionBody definition)
    <> "}"
    <> maybe Text.empty (\close -> "{" <> mconcat close <> "}") (definitionClose definition)
  where
    bare = control (definitionName definition)
    MacroName plain = definitionName definition
    name
      | isEnvironmentForm (definitionForm definition) = "{" <> plain <> "}"
      | definitionNameBraced definition = "{" <> bare <> "}"
      | otherwise = bare
    isEnvironmentForm form = form == NewEnvironmentForm || form == RenewEnvironmentForm
    parameters = printParameters (definitionParameters definition)

printParameters :: ParametersF Text -> Text
printParameters parameters
  | count <= 0 = Text.empty
  | otherwise = "[" <> Text.pack (show count) <> "]" <> optional
  where
    count = parameterCount parameters
    optional =
      maybe
        Text.empty
        (\children -> "[" <> mconcat children <> "]")
        (parameterOptionalDefault parameters)

definitionFormName :: DefinitionForm -> Text
definitionFormName form =
  case form of
    NewCommandForm -> "newcommand"
    RenewCommandForm -> "renewcommand"
    ProvideCommandForm -> "providecommand"
    NewEnvironmentForm -> "newenvironment"
    RenewEnvironmentForm -> "renewenvironment"
