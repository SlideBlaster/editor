{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Html.Reader
-- Description : Reading inline HTML into the unified tree.
--
-- HTML and LaTeX have to nest inside one another in either order, so neither
-- reader can own the recursion. This module takes the content parser as an
-- argument and calls it for an element's children, which lets the caller supply a
-- parser that dispatches back to every dialect. The knot is tied once, in
-- "SlideBlaster.Syntax.Tex.Reader", and no reader knows what the others are.
--
-- == What an element becomes
--
-- Tags that mean a style become 'Styled' with the fact they assert, so
-- @\<strong\>@ and @\\textbf@ produce the same tree with different surfaces and an
-- edit can change either. A @style@ attribute becomes 'Declaration's, each keeping
-- its exact text, so properties this model does not know are still reprinted and
-- still there after an edit. An unrecognised tag becomes a 'Run', which keeps its
-- children addressable; 'SlideBlaster.Syntax.Ast.Foreign' would flatten them into
-- opaque text and lose that.
--
-- == Why an unclosed tag is not an error
--
-- A @\<@ that does not begin a well-formed element is ordinary text. So is a tag
-- with no matching close. HTML is defined to be tolerant here, and a mixed content
-- field is exactly where a stray @\<@ appears, so refusing the whole document over
-- one would be wrong. Such input is preserved byte for byte and read-only, which
-- is the same treatment every other unsupported construct gets.
module SlideBlaster.Syntax.Html.Reader
  ( htmlInline
  , htmlEntityNode
  , parseDeclarations
  , declarationFact
  , styleTags
  ) where

import SlideBlaster.Syntax.Ast
  ( BreakKind (HardBreak)
  , Node
  , NodeF (Break, Linked, Run, Styled, Text)
  )
import SlideBlaster.Syntax.Fix (Fix (Fix))
import SlideBlaster.Syntax.Style
  ( ColourExpr (ColourLiteral, ColourName)
  , ColourModel (HtmlModel)
  , Family (Monospace, SansSerif, Serif)
  , Slant (Italic, Upright)
  , StyleValue (..)
  , Variant (NormalVariant, SmallCaps)
  , Weight (Bold, NormalWeight)
  , styleMapFromList
  )
import SlideBlaster.Syntax.Surface
  ( Attribute (..)
  , AttributeValue (PlainValue, StyleValue)
  , Declaration (..)
  , ElementName
  , HtmlSpelling (HtmlElement, HtmlEntity)
  , QuoteStyle (DoubleQuoted, SingleQuoted, Unquoted)
  , Surface (HtmlSurface)
  , TagForm (NormalTag, SelfClosingTag, VoidTag)
  , elementName
  , elementNameLower
  , isVoidElement
  )

import Control.Applicative (empty)
import Data.Char (isAlphaNum, isAscii, isLetter)
import Data.Text (Text)
import Data.Text qualified as Text
import Text.Megaparsec
  ( MonadParsec
  , choice
  , chunk
  , many
  , optional
  , takeWhile1P
  , takeWhileP
  , try
  )
import Text.Megaparsec.Char (char)

html :: NodeF Node -> Node
html = Fix

-- | Read one inline HTML element, given a parser for mixed content.
--
-- Fails without consuming input when the text does not begin a well-formed
-- element, so a caller can fall through to treating @\<@ as ordinary text.
htmlInline :: (MonadParsec e Text m) => m [Node] -> m Node
htmlInline content = try (openTag >>= body)
  where
    openTag = do
      _ <- char '<'
      name <- tagName
      attributes <- many attribute
      trailing <- takeWhileP Nothing isHtmlSpace
      pure (name, attributes, trailing)
    body (name, attributes, trailing) = do
      selfClosing <- optional (try (chunk "/>"))
      case selfClosing of
        Just _ -> pure (element name attributes trailing SelfClosingTag [])
        Nothing -> do
          _ <- char '>'
          if isVoidElement name
            then pure (element name attributes trailing VoidTag [])
            else do
              children <- content
              closeTag name
              pure (element name attributes trailing NormalTag children)
    closeTag name = try $ do
      _ <- chunk "</"
      closing <- tagName
      _ <- takeWhileP Nothing isHtmlSpace
      _ <- char '>'
      -- A close tag for a different element means this was not an element after
      -- all, so the whole attempt backtracks and the text is preserved as written.
      if elementNameLower closing == elementNameLower name
        then pure ()
        else empty

-- | Build the node an element denotes.
--
-- Anything not recognised keeps its structure as a 'Run' rather than becoming
-- opaque text, so its children stay addressable and editable even though the
-- element itself carries no meaning here.
element :: ElementName -> [Attribute] -> Text -> TagForm -> [Node] -> Node
element name attributes trailing form children
  | Just fact <- lookup lowered styleTags =
      html (Styled (styleMapFromList (fact : attributeFacts)) surface children)
  | not (null attributeFacts) =
      html (Styled (styleMapFromList attributeFacts) surface children)
  | lowered == "a" = html (Linked surface children)
  | lowered == "br" = html (Break HardBreak surface)
  | otherwise = html (Run surface children)
  where
    lowered = elementNameLower name
    surface = HtmlSurface (HtmlElement name attributes trailing form)
    attributeFacts =
      [ fact
      | Attribute attrName (Just (StyleValue declarations)) _ _ <- attributes
      , Text.toLower attrName == "style"
      , Just fact <- fmap declarationFact declarations
      ]

-- | Tags whose whole meaning is one style fact.
--
-- Presentational and semantic tags are deliberately treated alike: @\<b\>@ and
-- @\<strong\>@ differ in why they are bold, not in whether they are, and the
-- distinction is preserved because each keeps its own spelling.
styleTags :: [(Text, StyleValue)]
styleTags =
  [ ("strong", SetWeight Bold)
  , ("b", SetWeight Bold)
  , ("em", SetSlant Italic)
  , ("i", SetSlant Italic)
  , ("u", SetUnderline True)
  , ("ins", SetUnderline True)
  , ("s", SetStrike True)
  , ("del", SetStrike True)
  , ("strike", SetStrike True)
  , ("code", SetFamily Monospace)
  , ("kbd", SetFamily Monospace)
  , ("samp", SetFamily Monospace)
  , ("tt", SetFamily Monospace)
  , ("mark", SetHighlight True)
  ]

tagName :: (MonadParsec e Text m) => m ElementName
tagName = elementName <$> takeWhile1P Nothing isNameChar
  where
    isNameChar c = isAscii c && (isAlphaNum c || c == '-' || c == '_')

attribute :: (MonadParsec e Text m) => m Attribute
attribute = try $ do
  before <- takeWhile1P Nothing isHtmlSpace
  name <- takeWhile1P Nothing isAttributeChar
  assigned <- optional (char '=' *> attributeRhs name)
  case assigned of
    Nothing -> pure (Attribute name Nothing Unquoted before)
    Just (value, quoting) -> pure (Attribute name (Just value) quoting before)
  where
    isAttributeChar c =
      isAscii c && (isAlphaNum c || c == '-' || c == '_' || c == ':')

attributeRhs
  :: (MonadParsec e Text m) => Text -> m (AttributeValue, QuoteStyle)
attributeRhs name =
  choice
    [ try (quoted '"' DoubleQuoted)
    , try (quoted '\'' SingleQuoted)
    , unquoted
    ]
  where
    quoted delimiter style = do
      _ <- char delimiter
      raw <- takeWhileP Nothing (/= delimiter)
      _ <- char delimiter
      pure (valueOf name raw, style)
    unquoted = do
      raw <- takeWhileP Nothing (\c -> not (isHtmlSpace c) && c /= '>' && c /= '/')
      pure (valueOf name raw, Unquoted)

-- | A @style@ attribute carries declarations; everything else is a plain value.
valueOf :: Text -> Text -> AttributeValue
valueOf name raw
  | Text.toLower name == "style" = StyleValue (parseDeclarations raw)
  | otherwise = PlainValue raw

-- | Split a @style@ attribute into declarations, keeping each one's exact text.
--
-- Total by construction. A piece with no @:@ has no property and no value, and is
-- carried only as text, so nothing is discarded and nothing is invented. The
-- concatenation of every 'declarationText' is the original attribute value.
parseDeclarations :: Text -> [Declaration]
parseDeclarations raw
  | Text.null raw = []
  | otherwise = fmap declaration (pieces raw)
  where
    pieces value =
      case Text.breakOn ";" value of
        (piece, rest)
          | Text.null rest -> [piece | not (Text.null piece)]
          | otherwise ->
              (piece <> ";") : pieces (Text.drop 1 rest)
    declaration text =
      case Text.breakOn ":" text of
        (before, rest)
          | Text.null rest ->
              Declaration Text.empty Text.empty False text
          | otherwise ->
              let raw' = Text.drop 1 rest
                  stripped = Text.dropWhileEnd (== ';') raw'
                  (value, important) = splitImportant (Text.strip stripped)
               in Declaration (Text.toLower (Text.strip before)) value important text
    splitImportant value =
      case Text.stripSuffix "!important" (Text.stripEnd value) of
        Just remaining -> (Text.stripEnd remaining, True)
        Nothing -> (value, False)

-- | The style fact a CSS declaration asserts, when this model has one.
--
-- Declarations with no fact are still printed, so an unsupported property survives
-- an edit to a supported one.
declarationFact :: Declaration -> Maybe StyleValue
declarationFact declaration =
  case declarationProperty declaration of
    "color" -> SetForeground <$> cssColour value
    "background-color" -> SetBackground <$> cssColour value
    "font-weight" -> case value of
      "bold" -> Just (SetWeight Bold)
      "bolder" -> Just (SetWeight Bold)
      "700" -> Just (SetWeight Bold)
      "800" -> Just (SetWeight Bold)
      "900" -> Just (SetWeight Bold)
      "normal" -> Just (SetWeight NormalWeight)
      "400" -> Just (SetWeight NormalWeight)
      _ -> Nothing
    "font-style" -> case value of
      "italic" -> Just (SetSlant Italic)
      "oblique" -> Just (SetSlant Italic)
      "normal" -> Just (SetSlant Upright)
      _ -> Nothing
    "font-variant" -> case value of
      "small-caps" -> Just (SetVariant SmallCaps)
      "normal" -> Just (SetVariant NormalVariant)
      _ -> Nothing
    "font-family" -> case value of
      "monospace" -> Just (SetFamily Monospace)
      "serif" -> Just (SetFamily Serif)
      "sans-serif" -> Just (SetFamily SansSerif)
      _ -> Nothing
    "text-decoration" -> case value of
      "underline" -> Just (SetUnderline True)
      "line-through" -> Just (SetStrike True)
      "none" -> Just (SetUnderline False)
      _ -> Nothing
    _ -> Nothing
  where
    value = Text.toLower (declarationValue declaration)

-- | A CSS colour this model can represent.
cssColour :: Text -> Maybe ColourExpr
cssColour value =
  case Text.stripPrefix "#" value of
    Just digits
      | Text.length digits == 6
      , Text.all isHexDigit digits ->
          Just (ColourLiteral HtmlModel digits)
    _
      | not (Text.null value)
      , Text.all isLetter value ->
          Just (ColourName value)
    _ -> Nothing
  where
    isHexDigit c =
      (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

-- | Read a character reference, keeping its authored name.
htmlEntityNode :: (MonadParsec e Text m) => m Node
htmlEntityNode = try $ do
  _ <- char '&'
  name <- takeWhile1P Nothing (\c -> isAscii c && isAlphaNum c)
  _ <- char ';'
  case lookup (Text.toLower name) namedEntities of
    -- An unknown reference is left as ordinary input rather than guessed at.
    Nothing -> empty
    Just value -> pure (html (Text (HtmlSurface (HtmlEntity name)) value))

-- | The references this model decodes. Anything else stays ordinary input, so it
-- is preserved rather than guessed at.
namedEntities :: [(Text, Text)]
namedEntities =
  [ ("amp", "&")
  , ("lt", "<")
  , ("gt", ">")
  , ("quot", "\"")
  , ("apos", "'")
  , ("nbsp", "\xa0")
  ]

isHtmlSpace :: Char -> Bool
isHtmlSpace c = c == ' ' || c == '\t' || c == '\n' || c == '\r'
