{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Edit
-- Description : Changing style without losing the author's dialect.
--
-- This is the module the representation exists for. A canvas edit arrives as
-- "make the thing at this path bold", and it must come out of the printer as
-- source the author would recognise: @**bold**@ in a Markdown document,
-- @\\textbf{bold}@ in a LaTeX one, and with every unrelated byte untouched.
--
-- No inverse rule is involved. An edit changes a style /fact/ and, where
-- necessary, the /spelling/ that carries it; the printer then re-emits the
-- construct from those two. Nothing has to be recovered from printed text,
-- because nothing was normalized away when it was read.
--
-- == Why an edit sometimes rewrites the spelling
--
-- A spelling either prints its value from the fact or encodes the fact itself.
-- @\\textcolor{red}{x}@ prints whatever colour the fact holds, so recolouring it
-- touches only the fact and the author keeps their command. @\\textbf{x}@ /is/ the
-- claim that the text is bold, so changing the weight fact alone would leave
-- spelling and fact contradicting each other; that edit must also re-spell.
-- 'SlideBlaster.Syntax.Surface.surfaceCarriesStyleValue' draws the line, and
-- because it is derived from the spelling it cannot drift from what the printer
-- does.
--
-- == Why failure is explicit
--
-- Not every style can be written in every dialect. Markdown has no spelling for
-- small capitals, and plain LaTeX has none for strikethrough. Such an edit
-- returns 'UnspellableStyle' rather than producing source that does not say what
-- the fact says. Refusing is the only behaviour consistent with the printer
-- staying exact.
module SlideBlaster.Syntax.Edit
  ( EditError (..)
  , setStyleAt
  , clearStyleAt
  , spellStyle
  , stylesInPlace
  ) where

import SlideBlaster.Syntax.Ast (Node, NodeF (Run, Styled), node)
import SlideBlaster.Syntax.Fix (unFix)
import SlideBlaster.Syntax.Path (Path, replaceAt, resolvePath)
import SlideBlaster.Syntax.Style
  ( Family (Monospace, SansSerif, Serif)
  , Slant (Italic, Upright)
  , StyleKey
  , StyleValue (..)
  , Variant (NormalVariant, SmallCaps)
  , Weight (Bold, NormalWeight)
  , insertStyle
  , lookupStyle
  , removeStyle
  , styleKey
  , styleMapFromList
  , styleMapToList
  )
import SlideBlaster.Syntax.Surface
  ( Attribute (..)
  , AttributeValue (StyleValue)
  , Declaration (..)
  , Dialect (Html, Markdown, Tex)
  , ElementName
  , QuoteStyle (DoubleQuoted)
  , HtmlSpelling (HtmlElement)
  , MdSpelling (MdCodeSpan, MdDelimited)
  , Surface (HtmlSurface, MarkdownSurface, TexSurface, Transparent)
  , TagForm (NormalTag)
  , TexSpelling (TexColourCommand, TexCommand)
  , dialectOf
  , elementName
  , surfaceCarriesStyleValue
  )

import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text

-- | Why an edit was refused.
--
-- Both cases are refusals, not partial results: the tree is returned unchanged,
-- so a rejected edit cannot leave a document half-modified.
data EditError
  = -- | The path does not resolve, which means it was derived from a different
    -- tree. Editing blind would hit the wrong construct.
    PathNotFound !Path
  | -- | The dialect has no way to write this style.
    UnspellableStyle !Dialect !StyleKey
  deriving stock (Eq, Show)

-- | Make the construct at a path carry a style fact.
--
-- If it already carries that exact value, the tree is returned unchanged and the
-- source is therefore byte-identical: a no-op edit rewrites nothing.
--
-- The dialect argument is used only when a new construct has to be created. An
-- existing construct keeps its own dialect, so editing inside a LaTeX document
-- never emits Markdown.
setStyleAt :: Dialect -> Path -> StyleValue -> Node -> Either EditError Node
setStyleAt dialect path value tree = do
  target <- locate path tree
  replacement <- restyle dialect value target
  put path replacement tree

-- | Remove a style fact from the construct at a path.
--
-- When that empties the construct's style, the construct itself is unwrapped into
-- a transparent container, because a spelling such as @\\textbf@ cannot remain
-- once the boldness it asserts is gone. The container keeps the original
-- dialect, so later edits still know where they are.
clearStyleAt :: Path -> StyleKey -> Node -> Either EditError Node
clearStyleAt path key tree = do
  target <- locate path tree
  case unFix target of
    Styled facts surface children
      | Just _ <- lookupStyle key facts ->
          let remaining = removeStyle key facts
              replacement
                | null (styleMapToList remaining) =
                    node (Run (Transparent (dialectOf surface)) children)
                | otherwise = node (Styled remaining surface children)
           in put path replacement tree
    -- No such fact here, so there is nothing to remove and nothing to rewrite.
    _ -> Right tree

locate :: Path -> Node -> Either EditError Node
locate path tree =
  maybe (Left (PathNotFound path)) Right (resolvePath path tree)

put :: Path -> Node -> Node -> Either EditError Node
put path replacement tree =
  maybe (Left (PathNotFound path)) Right (replaceAt path replacement tree)

-- | Whether setting this property would rewrite the construct at hand, rather
-- than wrap it in a new one.
--
-- A caller needs this to tell which constructs an edit created. Coalescing two
-- adjacent constructs is only permissible for constructs the edit itself
-- produced; merging ones the author wrote would rewrite bytes nobody selected.
--
-- This is the same condition 'restyle' branches on, and the law
-- @styles-in-place agrees with what setting a style does@ holds them together.
stylesInPlace :: StyleKey -> Node -> Bool
stylesInPlace key target =
  case unFix target of
    Styled facts _ _ -> isJust (lookupStyle key facts)
    _ -> False

restyle :: Dialect -> StyleValue -> Node -> Either EditError Node
restyle dialect value target =
  case unFix target of
    Styled facts surface children
      | Just existing <- lookupStyle key facts ->
          if existing == value
            then Right target
            else
              if surfaceCarriesStyleValue key surface
                then -- The spelling prints the fact, so the author's command survives.
                  Right (node (Styled (insertStyle value facts) surface children))
                else do
                  -- The spelling asserts the old value, so it must be replaced
                  -- too, in the dialect the construct was already written in.
                  respelled <- spelled (dialectOf surface)
                  Right (node (Styled (insertStyle value facts) respelled children))
    -- Either not a styled construct, or styled along a different axis. Wrapping
    -- is correct in both cases: one construct carries one fact, which is what
    -- keeps nesting order faithful.
    _ -> do
      surface <- spelled dialect
      Right (node (Styled (styleMapFromList [value]) surface [target]))
  where
    key = styleKey value
    spelled inDialect =
      maybe
        (Left (UnspellableStyle inDialect key))
        Right
        (spellStyle inDialect value)

-- | How a dialect writes one style fact, when it can.
--
-- Only wrapping forms are produced. A LaTeX declaration such as @\\bfseries@ is
-- deliberately not used here: its scope runs to the end of the enclosing group,
-- so emitting one would restyle the author's following text as well.
--
-- 'Nothing' means the dialect cannot express the style in its own right. The
-- gaps are real properties of the dialects: Markdown has no small capitals or
-- underline, and plain LaTeX has no strikethrough or highlight without a
-- package. Extending the model is adding a case here once the printer can emit
-- the corresponding spelling.
spellStyle :: Dialect -> StyleValue -> Maybe Surface
spellStyle dialect value =
  case dialect of
    Tex -> texSpelling value
    Markdown -> markdownSpelling value
    Html -> htmlSpelling value

texSpelling :: StyleValue -> Maybe Surface
texSpelling value =
  case value of
    SetWeight Bold -> command "textbf"
    SetWeight NormalWeight -> command "textmd"
    SetSlant Italic -> command "textit"
    SetSlant Upright -> command "textup"
    SetFamily Serif -> command "textrm"
    SetFamily SansSerif -> command "textsf"
    SetFamily Monospace -> command "texttt"
    SetVariant SmallCaps -> command "textsc"
    SetVariant NormalVariant -> command "textup"
    SetUnderline True -> command "underline"
    -- The format's dialect table gives LaTeX a highlight column, so this is a
    -- spelling rather than a refusal.
    SetHighlight True -> command "hl"
    SetForeground _ -> Just (TexSurface (TexColourCommand "textcolor"))
    -- Nothing in the LaTeX subset cancels these, and its dialect table has no
    -- strikethrough column at all, so a notation that can express them supplies the
    -- spelling instead.
    SetUnderline False -> Nothing
    SetHighlight False -> Nothing
    SetStrike _ -> Nothing
    -- Needs \colorbox, which the printer does not yet spell.
    SetBackground _ -> Nothing
  where
    command name = Just (TexSurface (TexCommand name))

markdownSpelling :: StyleValue -> Maybe Surface
markdownSpelling value =
  case value of
    SetWeight Bold -> delimited "**"
    SetSlant Italic -> delimited "*"
    SetHighlight True -> delimited "=="
    SetStrike True -> delimited "~~"
    SetFamily Monospace -> Just (MarkdownSurface (MdCodeSpan 1))
    -- Markdown has no markup for removing emphasis, nor for these properties at
    -- all. Inline HTML is the author's route, and that is a different dialect.
    SetWeight NormalWeight -> Nothing
    SetSlant Upright -> Nothing
    SetFamily Serif -> Nothing
    SetFamily SansSerif -> Nothing
    SetVariant _ -> Nothing
    SetUnderline _ -> Nothing
    SetStrike False -> Nothing
    SetHighlight False -> Nothing
    SetForeground _ -> Nothing
    SetBackground _ -> Nothing
  where
    delimited marker = Just (MarkdownSurface (MdDelimited marker))

htmlSpelling :: StyleValue -> Maybe Surface
htmlSpelling value =
  case value of
    -- The format's dialect table spells these <b> and <i>. Both these and
    -- <strong>/<em> are read, and an authored one reprints as written; this is only
    -- what a construct created here is called.
    SetWeight Bold -> element "b"
    SetSlant Italic -> element "i"
    SetUnderline True -> element "u"
    SetStrike True -> element "s"
    SetFamily Monospace -> element "code"
    -- <mark> is exactly this fact, and the reader already reads it back as such.
    SetHighlight True -> element "mark"
    -- Everything else is a CSS declaration on a span. The value is left empty
    -- here and supplied by the printer from the style fact, which is the same
    -- arrangement @\\textcolor@ uses: one place decides how a value is written, so
    -- an edit changes the fact and never has to rewrite text.
    SetForeground _ -> declared "color"
    SetBackground _ -> declared "background-color"
    SetWeight NormalWeight -> declared "font-weight"
    SetSlant Upright -> declared "font-style"
    SetFamily Serif -> declared "font-family"
    SetFamily SansSerif -> declared "font-family"
    SetVariant _ -> declared "font-variant"
    SetUnderline False -> declared "text-decoration"
    SetStrike False -> declared "text-decoration"
    -- There is no markup for removing a highlight, so turning one off is done by
    -- removing the element that asserts it rather than by writing something.
    SetHighlight False -> Nothing
  where
    element name = Just (HtmlSurface (HtmlElement (named name) [] "" NormalTag))
    declared property =
      Just
        ( HtmlSurface
            ( HtmlElement
                (named "span")
                [ Attribute
                    { attributeName = "style"
                    , attributeValue =
                        Just
                          ( StyleValue
                              [ Declaration
                                  { declarationProperty = property
                                  , declarationValue = Text.empty
                                  , declarationImportant = False
                                  , declarationText = property <> ": ;"
                                  }
                              ]
                          )
                    , attributeQuote = DoubleQuoted
                    , attributeBefore = " "
                    }
                ]
                Text.empty
                NormalTag
            )
        )
    named :: Text -> ElementName
    named = elementName
