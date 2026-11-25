{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Tex.Reader
-- Description : Reads TeX input into the unified tree, rejecting malformed source.
--
-- Two failure modes are deliberately different.
--
-- /Malformed/ input — an unclosed group, an unmatched @}@, a mismatched
-- environment — is a syntax error with a position. It produces no tree. There is
-- no node for "broken brace", because such a node would have to be interpreted and
-- there is nothing to interpret.
--
-- /Unsupported/ input is well formed but outside the interpreted subset. It is
-- read, preserved and printable as 'Unresolved', and is read-only for the semantic
-- layer. Widening support means recognising more control sequences here; it never
-- means loosening the parser.
--
-- Errors are attributed to the /opening/ delimiter, so an unclosed group points at
-- the brace that needs closing rather than at the end of the file.
--
-- The reader never expands macros. Expansion is a separate pass, because a macro's
-- arity is known only from its definition, so at read time a following group cannot
-- be told apart from an ordinary sibling.
module SlideBlaster.Syntax.Tex.Reader
  ( readTex
  , readColourExpr
  , TexSyntaxError (..)
  , TexErrorKind (..)
  ) where

import SlideBlaster.Syntax.Ast
  ( ArgumentF (Angle, Mandatory, Optional)
  , BreakKind (HardBreak)
  , DefinitionF (..)
  , DefinitionForm (NewCommandForm, NewEnvironmentForm, ProvideCommandForm, RenewCommandForm, RenewEnvironmentForm)
  , ItemF (ItemF)
  , ListKind (Described, Ordered, Unordered)
  , MacroName (MacroName)
  , MathForm (DisplayDoubleDollar, InlineDollar)
  , Node
  , NodeF (..)
  , ParametersF (..)
  )
import SlideBlaster.Syntax.Fix (Fix (Fix, unFix))
import SlideBlaster.Syntax.Html.Reader (htmlEntityNode, htmlInline)
import SlideBlaster.Syntax.Markdown.Reader (markdownInline)
import SlideBlaster.Syntax.Style
  ( ColourExpr (ColourMix, ColourName, ColourTint)
  , Family (Monospace)
  , Literal (Literal)
  , Slant (Italic)
  , StyleValue
      ( SetFamily
      , SetForeground
      , SetHighlight
      , SetSlant
      , SetUnderline
      , SetVariant
      , SetWeight
      )
  , Variant (SmallCaps)
  , Weight (Bold)
  , styleMapFromList
  )
import SlideBlaster.Syntax.Surface
  ( Dialect (Html, Markdown, Tex)
  , HtmlSpelling (HtmlChars)
  , MdSpelling (MdChars)
  , Surface (HtmlSurface, MarkdownSurface, TexSurface)
  , TexSpelling (..)
  )

import Data.Maybe (listToMaybe)
import Data.Ratio ((%))
import Data.Set qualified as Set
import Control.Applicative (empty)
import Data.Char (isAlphaNum)
import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as Text
import Text.Megaparsec
  ( ParseError (FancyError, TrivialError)
  , ParseErrorBundle
  , Parsec
  , (<?>)
  , (<|>)
  , anySingle
  , bundleErrors
  , chunk
  , choice
  , customFailure
  , eof
  , errorOffset
  , getOffset
  , lookAhead
  , many
  , takeP
  , notFollowedBy
  , optional
  , runParser
  , satisfy
  , setOffset
  , takeWhile1P
  , takeWhileP
  , try
  )
import Text.Megaparsec.Char (char)
import Text.Megaparsec.Error
  ( ErrorFancy (ErrorCustom)
  , ShowErrorComponent (showErrorComponent)
  )

type TexParser = Parsec TexErrorKind Text

-- | What was wrong with the input.
data TexErrorKind
  = UnclosedGroup
  | UnclosedInlineMath
  | UnclosedDisplayMath
  | UnmatchedCloseBrace
  | UnclosedEnvironment !Text
  | MismatchedEnvironment !Text !Text
  | MalformedDefinition
  | MalformedColour
  deriving stock (Eq, Ord, Show)

instance ShowErrorComponent TexErrorKind where
  showErrorComponent kind =
    case kind of
      UnclosedGroup -> "unclosed group: this { is never closed"
      UnclosedInlineMath -> "unclosed inline math: this $ is never closed"
      UnclosedDisplayMath -> "unclosed display math: this $$ is never closed"
      UnmatchedCloseBrace -> "unmatched }: there is no open group to close"
      UnclosedEnvironment name ->
        "unclosed environment: \\begin{" <> Text.unpack name <> "} has no \\end"
      MismatchedEnvironment opened closed ->
        "mismatched environment: \\begin{"
          <> Text.unpack opened
          <> "} closed by \\end{"
          <> Text.unpack closed
          <> "}"
      MalformedDefinition -> "malformed definition"
      MalformedColour -> "malformed colour expression"

-- | A syntax error with the position of the construct responsible.
data TexSyntaxError = TexSyntaxError
  { texErrorKind :: !(Maybe TexErrorKind)
  , texErrorLine :: !Int
  , texErrorColumn :: !Int
  , texErrorMessage :: !Text
  }
  deriving stock (Eq, Show)

-- | Read well-formed TeX input into the tree.
readTex :: Text -> Either TexSyntaxError [Node]
readTex input =
  case runParser (texContent topContext <* atDocumentEnd) "source" input of
    Right nodes -> Right nodes
    Left bundle -> Left (toSyntaxError input bundle)

-- | Read one xcolor colour expression on its own.
--
-- A colour arrives from a user interface as the text an author would have typed,
-- because @blue!40!black@ is what belongs in the document and a resolved triple
-- would have thrown the authoring away. Parsing it is this module's job, since the
-- expression grammar is xcolor's and therefore TeX's.
readColourExpr :: Text -> Either TexSyntaxError ColourExpr
readColourExpr input =
  case runParser (colourExpr <* eof) "colour" input of
    Right expression -> Right expression
    Left bundle -> Left (toSyntaxError input bundle)

-- | At the outermost level a @}@ cannot close anything, so it is malformed.
atDocumentEnd :: TexParser ()
atDocumentEnd =
  eof <|> (lookAhead (char '}') *> customFailure UnmatchedCloseBrace)

tex :: NodeF Node -> Node
tex = Fix

texSurface :: TexSpelling -> Surface
texSurface = TexSurface

-- | One construct, or a declaration that adopts its following siblings.
data Read'
  = Plain !Node
  | Scoped !([Node] -> Node)

-- | What ends the run of content currently being read.
--
-- Both fields are context, not configuration. A @]@ closes an optional argument
-- but is ordinary inside a group nested in one, and a @\</@ closes an HTML element
-- but is ordinary text where no element is open. Carrying them explicitly is what
-- lets the same content parser serve every position without any of them guessing.
data Ctx = Ctx
  { ctxTerminator :: !(Maybe Char)
  , ctxInElement :: !Bool
  , ctxDialect :: !Dialect
  , -- | The Markdown delimiter that must close the construct being read, if one
    -- is open. Content stops before it so the delimiter is left for its opener.
    ctxCloser :: !(Maybe Text)
  , -- | Whether the next construct begins a line.
    --
    -- A Markdown list item is only a list item at the start of a line, so that the
    -- dash in @a - b@ stays a dash. The content loop knows this without looking
    -- backwards: it can see whether what it just parsed ended a line.
    ctxAtLineStart :: !Bool
  }

-- | Reading a whole fragment, with nothing open.
--
-- The dialect recorded here is the one plain characters are labelled with when
-- nothing else applies. It is not a claim that the input is a LaTeX document:
-- there is no outermost notation, and 'SlideBlaster.Syntax.Surface.spelledDialect'
-- is what stops an edit treating bare characters as a notation the author chose.
topContext :: Ctx
topContext =
  Ctx
    { ctxTerminator = Nothing
    , ctxInElement = False
    , ctxDialect = Tex
    , ctxCloser = Nothing
    , ctxAtLineStart = True
    }

-- | Content nested inside a delimiter of its own.
--
-- The terminator is dropped because the inner delimiter closes first, while
-- whether an element is open is inherited: @\<em\>{a\</em\>@ leaves the group
-- unclosed, and reporting that is better than silently reading the close tag as
-- text.
nested :: Ctx -> Ctx
nested ctx =
  ctx {ctxTerminator = Nothing, ctxCloser = Nothing, ctxAtLineStart = False}

-- | Content inside a LaTeX delimiter: characters there are LaTeX, whatever
-- surrounds the whole construct.
texNested :: Ctx -> Ctx
texNested ctx = (nested ctx) {ctxDialect = Tex}

-- | Content inside an HTML element. A close tag now ends the run, and characters
-- belong to HTML, so an edit on them is written as HTML rather than as LaTeX.
htmlNested :: Ctx -> Ctx
htmlNested ctx = (nested ctx) {ctxInElement = True, ctxDialect = Html}

-- | Content inside a Markdown span, up to the delimiter that closes it.
--
-- Characters belong to Markdown, so an edit on them is written with Markdown
-- delimiters rather than in another notation.
markdownNested :: Text -> Ctx -> Ctx
markdownNested closer ctx =
  (nested ctx) {ctxDialect = Markdown, ctxCloser = Just closer}

-- | The content of one Markdown list item, which ends with its line.
--
-- The line ending is left unconsumed so the list can decide whether another item
-- follows it or the list is over.
markdownItem :: Ctx -> Ctx
markdownItem ctx =
  (nested ctx) {ctxDialect = Markdown, ctxCloser = Just "\n"}

-- | Parse a run of content, nesting scoped declarations into the remainder.
--
-- Never consumes a @}@, an @\\end@ or a close tag, so an enclosing construct can
-- close itself.
texContent :: Ctx -> TexParser [Node]
texContent ctx = go (ctxAtLineStart ctx)
  where
    go atLineStart = do
      next <- optional (try (texConstruct ctx {ctxAtLineStart = atLineStart}))
      case next of
        Nothing -> pure []
        Just (Plain parsed) -> (parsed :) <$> go (endsLine parsed)
        Just (Scoped build) -> do
          rest <- go False
          pure [build rest]

-- | Whether what follows a construct begins a line.
--
-- Indentation counts as still being at the start of one, because a run of
-- whitespace is read as a single construct: @\"\\n  \"@ leaves the parser at the
-- start of an indented line, which is where an indented list item lives.
endsLine :: Node -> Bool
endsLine parsed =
  case unFix parsed of
    Whitespace text ->
      let (before, after) = Text.breakOnEnd "\n" (Text.replace "\r" "\n" text)
       in not (Text.null before) && Text.all horizontalSpace after
    _ -> False
  where
    horizontalSpace c = c == ' ' || c == '\t'

texConstruct :: Ctx -> TexParser Read'
texConstruct ctx = do
  notFollowedBy (char '}')
  maybe (pure ()) (notFollowedBy . char) (ctxTerminator ctx)
  notFollowedBy (try (chunk "\\end"))
  notFollowedBy (try (chunk "\\item"))
  if ctxInElement ctx
    then notFollowedBy (try (chunk "</"))
    else pure ()
  -- An open Markdown span ends here, so its delimiter is left for the parser that
  -- opened it. Without this the closing delimiter would be read as a new opener.
  maybe (pure ()) (notFollowedBy . chunk) (ctxCloser ctx)
  choice
    [ Plain <$> texComment
    , Plain <$> texGroup ctx
    , Plain <$> texDisplayMath
    , Plain <$> texInlineMath
    , Plain <$> texParameter
    , -- HTML is tried before the characters that would otherwise absorb its
      -- delimiters. Both fall back to ordinary text, so a bare @&@ is still an
      -- alignment tab and a bare @<@ is still a character.
      Plain <$> htmlEntityNode
    , Plain <$> texAlignment
    , Plain <$> texWhitespace
    , Plain <$> overlaySpec
    , Plain <$> htmlInline (texContent (htmlNested ctx))
    , texControlSequence ctx
    , -- Markdown is tried before the characters that would absorb its delimiters,
      -- and only here: a delimiter inside a word has already been consumed as part
      -- of that word, which is how @snake_case@ stays one word.
      Plain
        <$> markdownInline
          (\closer -> texContent (markdownNested closer ctx))
          (texContent (markdownItem ctx))
          (ctxAtLineStart ctx)
    , Plain <$> texChars ctx
    , Plain <$> texAngle
    ]

texComment :: TexParser Node
texComment = do
  _ <- char '%'
  body <- takeWhileP Nothing (\c -> c /= '\n' && c /= '\r')
  pure (tex (Comment (texSurface TexComment) body))

texGroup :: Ctx -> TexParser Node
texGroup ctx = do
  opener <- getOffset
  _ <- char '{'
  children <- texContent (texNested ctx)
  closed <- optional (char '}')
  case closed of
    Just _ -> pure (tex (Run (texSurface TexBraceGroup) children))
    Nothing -> failAt opener UnclosedGroup

texInlineMath :: TexParser Node
texInlineMath = do
  opener <- getOffset
  _ <- try (char '$' <* notFollowedBy (char '$'))
  payload <- takeWhileP Nothing (/= '$')
  closed <- optional (char '$')
  case closed of
    Just _ -> pure (tex (Math InlineDollar payload))
    Nothing -> failAt opener UnclosedInlineMath

texDisplayMath :: TexParser Node
texDisplayMath = do
  opener <- getOffset
  _ <- try (chunk "$$")
  payload <- mathPayload
  closed <- optional (try (chunk "$$"))
  case closed of
    Just _ -> pure (tex (Math DisplayDoubleDollar payload))
    Nothing -> failAt opener UnclosedDisplayMath
  where
    mathPayload = Text.concat <$> many (notFollowedBy (chunk "$$") *> one)
    one = Text.singleton <$> anySingle

-- | @#1@ is a parameter reference, @##@ is an escaped literal hash, and a bare @#@
-- is preserved as written. Treating a run of @#@ and digits as one token would
-- merge @#1#2@ into a single unusable parameter.
texParameter :: TexParser Node
texParameter = do
  _ <- char '#'
  trailing <-
    choice
      [ Text.singleton <$> satisfy isDigit
      , Text.singleton <$> char '#'
      , pure Text.empty
      ]
  pure (tex (Parameter trailing))

texAlignment :: TexParser Node
texAlignment = tex Alignment <$ char '&'

texWhitespace :: TexParser Node
texWhitespace = tex . Whitespace <$> takeWhile1P Nothing isTexSpace

-- | Ordinary characters, spelled in whichever dialect encloses them.
--
-- Characters look the same in every dialect, but they are not dialect-free: an
-- edit that wraps them has to be written in the language they sit in, and the
-- innermost open construct is what decides that.
-- | A run of ordinary characters.
--
-- Two things shorten the run. When a Markdown span is open it stops at the
-- delimiter that closes it, because checking only at the start of a construct is
-- not enough: those delimiters are ordinary characters, so without this @**x**@
-- reads @x**@ as one run and the closer never reaches the parser waiting for it.
-- The candidate is examined before being consumed so the stop is at the whole
-- delimiter rather than its first character, which matters because stopping at any
-- @*@ would make the lone one in @**a * b**@ look like an opener.
--
-- It also stops where a Markdown construct could begin, so that the reader is
-- offered the position at all. A maximal run would swallow the delimiters in
-- @a**b**@ and no emphasis would ever be seen inside a word.
texChars :: Ctx -> TexParser Node
texChars ctx = do
  candidate <- lookAhead (takeWhile1P Nothing ordinary)
  let wanted = untilMarkdown (beforeCloser candidate)
  if Text.null wanted
    then
      -- The closer begins here, so there are no characters to take and the
      -- delimiter belongs to whoever opened it.
      empty
    else do
      consumed <- takeP Nothing (Text.length wanted)
      pure (tex (Text (charSurface (ctxDialect ctx)) consumed))
  where
    ordinary c = isTexOrdinary c && Just c /= ctxTerminator ctx
    beforeCloser candidate =
      case ctxCloser ctx of
        Nothing -> candidate
        Just closer -> fst (Text.breakOn closer candidate)

-- | The characters of a run to consume before a Markdown construct could start.
--
-- Never empty for a non-empty run, so the reader always makes progress: where a
-- delimiter begins the run and the Markdown reader has already declined it, the
-- delimiter characters are taken as the literal text they are.
--
-- An underscore inside a word is not a delimiter, which is what keeps
-- @snake_case_name@ one word. An asterisk inside a word is one, because CommonMark
-- allows @a*b*c@ to emphasise while forbidding @a_b_c@.
untilMarkdown :: Text -> Text
untilMarkdown run =
  case breaks of
    [] -> run
    0 : _ -> Text.takeWhile startsMarkdown run
    index : _ -> Text.take index run
  where
    breaks =
      [ index
      | (index, character) <- zip [0 ..] (Text.unpack run)
      , startsMarkdown character
      , character /= '_' || not (precededByWord index)
      ]
    precededByWord index =
      case Text.unsnoc (Text.take index run) of
        Just (_, previous) -> isAlphaNum previous
        Nothing -> False

-- | Whether a character could begin an inline Markdown construct.
startsMarkdown :: Char -> Bool
startsMarkdown character = character `elem` ("*_~=`[" :: String)

-- | How ordinary characters are spelled in each notation.
--
-- Exhaustive rather than defaulted: a wildcard here labelled Markdown characters as
-- LaTeX, which made an edit inside @**bold**@ come out in the wrong notation.
charSurface :: Dialect -> Surface
charSurface dialect =
  case dialect of
    Tex -> texSurface TexChars
    Html -> HtmlSurface HtmlChars
    Markdown -> MarkdownSurface MdChars

-- | A @\<@ that begins no element is an ordinary character.
--
-- Reached only after 'htmlInline' has declined, so well-formed markup is never
-- captured here. This is what keeps widening the HTML subset from ever rejecting
-- input that used to read as text.
texAngle :: TexParser Node
texAngle = tex . Text (texSurface TexChars) . Text.singleton <$> char '<'

-- | Dispatch a control sequence to the construct it names, or preserve it.
texControlSequence :: Ctx -> TexParser Read'
texControlSequence ctx = do
  _ <- char '\\'
  name <- controlName
  dispatch ctx name

controlName :: TexParser Text
controlName = letters <|> singleAny
  where
    letters = takeWhile1P Nothing isTexLetter
    singleAny = Text.singleton <$> anySingle

dispatch :: Ctx -> Text -> TexParser Read'
dispatch ctx name
  | Just fact <- lookup name styleCommands =
      Plain <$> (styledCommand fact name <$> mandatoryGroup ctx)
  | Just fact <- lookup name styleDeclarations =
      pure (Scoped (styledDeclaration fact name))
  | name == "textcolor" = do
      colour <- bracedColour
      body <- mandatoryGroup ctx
      pure (Plain (styledCommandAs (SetForeground colour) (TexColourCommand name) body))
  | name == "color" = do
      colour <- bracedColour
      pure
        ( Scoped
            (styledCommandAs (SetForeground colour) (TexColourDeclaration name))
        )
  | Just form <- lookup name definitionForms = Plain <$> definition ctx form
  | Just form <- lookup name environmentDefinitionForms =
      Plain <$> environmentDefinition ctx form
  | Just slots <- lookup name knownCommands = Plain <$> knownCommand ctx name slots
  | name == "begin" = Plain <$> environment ctx
  | name == "\\" =
      pure (Plain (tex (Break HardBreak (texSurface (TexControlSymbol name)))))
  | isEscapableSpecial name =
      pure (Plain (tex (Text (texSurface TexEscaped) name)))
  | otherwise = pure (Plain (tex (Unresolved (MacroName name) [])))

-- | A backslash before one of these denotes the character itself, so the escape is
-- spelling and the node's text is the character.
isEscapableSpecial :: Text -> Bool
isEscapableSpecial name = name `elem` ["{", "}", "$", "%", "#", "&", "_"]

styledCommand :: StyleValue -> Text -> [Node] -> Node
styledCommand fact name = styledCommandAs fact (TexCommand name)

styledDeclaration :: StyleValue -> Text -> [Node] -> Node
styledDeclaration fact name = styledCommandAs fact (TexDeclaration name)

styledCommandAs :: StyleValue -> TexSpelling -> [Node] -> Node
styledCommandAs fact spelling children =
  tex (Styled (styleMapFromList [fact]) (texSurface spelling) children)

-- | Commands taking their content as an argument. The name is kept as spelling, so
-- @\\emph@ round-trips as @\\emph@ even though it means the same as @\\textit@ here.
styleCommands :: [(Text, StyleValue)]
styleCommands =
  [ ("textbf", SetWeight Bold)
  , ("textit", SetSlant Italic)
  , ("emph", SetSlant Italic)
  , ("underline", SetUnderline True)
  , ("hl", SetHighlight True)
  , ("texttt", SetFamily Monospace)
  , ("textsc", SetVariant SmallCaps)
  ]

-- | Declarations, whose scope is the remainder of the enclosing group.
styleDeclarations :: [(Text, StyleValue)]
styleDeclarations =
  [ ("bfseries", SetWeight Bold)
  , ("itshape", SetSlant Italic)
  , ("em", SetSlant Italic)
  , ("ttfamily", SetFamily Monospace)
  , ("scshape", SetVariant SmallCaps)
  ]

definitionForms :: [(Text, DefinitionForm)]
definitionForms =
  [ ("newcommand", NewCommandForm)
  , ("renewcommand", RenewCommandForm)
  , ("providecommand", ProvideCommandForm)
  ]

-- | A braced argument, read as mixed content.
mandatoryGroup :: Ctx -> TexParser [Node]
mandatoryGroup ctx = do
  opener <- getOffset
  _ <- char '{'
  children <- texContent (texNested ctx)
  closed <- optional (char '}')
  case closed of
    Just _ -> pure children
    Nothing -> failAt opener UnclosedGroup

-- | @\\newcommand{\\R}[2][d]{body}@ or @\\newcommand\\R{body}@.
definition :: Ctx -> DefinitionForm -> TexParser Node
definition ctx form = do
  (name, braced) <- definitionTarget
  count <- optional (try (bracketedInt <?> "parameter count"))
  fallback <- optional (try (bracketedContent ctx))
  body <- mandatoryGroup ctx
  pure
    ( tex
        ( Define
            DefinitionF
              { definitionForm = form
              , definitionName = MacroName name
              , definitionNameBraced = braced
              , definitionParameters =
                  ParametersF
                    { parameterCount = maybe 0 id count
                    , parameterOptionalDefault = fallback
                    }
              , definitionBody = body
              , definitionClose = Nothing
              }
        )
    )

definitionTarget :: TexParser (Text, Bool)
definitionTarget = braced <|> bare
  where
    braced = try $ do
      _ <- char '{'
      _ <- char '\\'
      name <- controlName
      _ <- char '}'
      pure (name, True)
    bare = do
      next <- optional (char '\\')
      case next of
        Nothing -> customFailure MalformedDefinition
        Just _ -> do
          name <- controlName
          pure (name, False)

bracketedInt :: TexParser Int
bracketedInt = do
  _ <- char '['
  digits <- takeWhile1P Nothing isDigit
  _ <- char ']'
  case readDecimalText digits of
    Just value -> pure value
    Nothing -> customFailure MalformedDefinition

bracketedContent :: Ctx -> TexParser [Node]
bracketedContent ctx = do
  _ <- char '['
  children <- texContent ctx {ctxTerminator = Just ']'}
  _ <- char ']'
  pure children

-- | @\\begin{name}...\\end{name}@. List environments are interpreted as lists,
-- verbatim-like environments are read raw, and every other environment is
-- retained as a generic 'Environment' whose body is mixed content.
environment :: Ctx -> TexParser Node
environment ctx = do
  opener <- getOffset
  name <- bracedName
  case lookup name listEnvironments of
    Just kind -> do
      preamble <- texContent (texNested ctx)
      items <- many (try (listItem ctx))
      closing <- closeEnvironment opener name
      if closing == name
        then
          pure
            (tex (Items kind (texSurface (TexEnvironment name)) preamble items))
        else failAt opener (MismatchedEnvironment name closing)
    Nothing
      | name `elem` verbatimEnvironments -> do
          raw <- rawUntilEnd opener name
          _ <- chunk ("\\end{" <> name <> "}")
          pure (tex (Environment Nothing name [tex (Foreign (texSurface TexChars) raw)]))
      | otherwise -> do
          body <- texContent (texNested ctx)
          closing <- closeEnvironment opener name
          if closing == name
            then pure (tex (Environment Nothing name body))
            else failAt opener (MismatchedEnvironment name closing)

-- | Consume @\\end{name}@ and return the name it closed.
closeEnvironment :: Int -> Text -> TexParser Text
closeEnvironment opener name = do
  ended <- optional (chunk "\\end")
  case ended of
    Nothing -> failAt opener (UnclosedEnvironment name)
    Just _ -> bracedName

-- | Environments whose content is never interpreted as TeX.
verbatimEnvironments :: [Text]
verbatimEnvironments = ["lstlisting", "verbatim", "Verbatim", "minted"]

-- | The raw text up to, not including, the matching @\\end{name}@.
rawUntilEnd :: Int -> Text -> TexParser Text
rawUntilEnd opener name = Text.concat <$> go
  where
    terminator = "\\end{" <> name <> "}"
    go = do
      chunkText <- takeWhileP Nothing (/= '\\')
      stop <- optional (lookAhead (chunk terminator))
      case stop of
        Just _ -> pure [chunkText]
        Nothing -> do
          next <- optional anySingle
          case next of
            Nothing -> failAt opener (UnclosedEnvironment name)
            Just character -> ((chunkText <> Text.singleton character) :) <$> go

listEnvironments :: [(Text, ListKind)]
listEnvironments =
  [ ("itemize", Unordered)
  , ("enumerate", Ordered)
  , ("description", Described)
  ]

listItem :: Ctx -> TexParser (ItemF Node)
listItem ctx = do
  _ <- chunk "\\item"
  label <- optional (try (bracketedContent ctx))
  body <- texContent (texNested ctx)
  pure (ItemF (texSurface TexItem) label body)

environmentDefinitionForms :: [(Text, DefinitionForm)]
environmentDefinitionForms =
  [ ("newenvironment", NewEnvironmentForm)
  , ("renewenvironment", RenewEnvironmentForm)
  ]

-- | @\\newenvironment{name}[n][default]{begin}{end}@.
environmentDefinition :: Ctx -> DefinitionForm -> TexParser Node
environmentDefinition ctx form = do
  name <- bracedName
  count <- optional (try (bracketedInt <?> "parameter count"))
  fallback <- optional (try (bracketedContent ctx))
  opening <- mandatoryGroup ctx
  closing <- mandatoryGroup ctx
  pure
    ( tex
        ( Define
            DefinitionF
              { definitionForm = form
              , definitionName = MacroName name
              , definitionNameBraced = True
              , definitionParameters =
                  ParametersF
                    { parameterCount = maybe 0 id count
                    , parameterOptionalDefault = fallback
                    }
              , definitionBody = opening
              , definitionClose = Just closing
              }
        )
    )

-- | One argument position of a command whose syntax the reader understands.
data Slot = SlotAngle | SlotOptional | SlotMandatory
  deriving stock (Eq)

-- | Commands whose arguments the reader attaches, so the semantic layer sees
-- them as arguments rather than as following siblings. Optional positions that
-- are absent are skipped; the first absent mandatory position ends the
-- argument list.
knownCommands :: [(Text, [Slot])]
knownCommands =
  [ ("sbbox", [SlotAngle, SlotOptional, SlotMandatory, SlotMandatory])
  , ("figure", [SlotAngle, SlotOptional, SlotMandatory])
  , ("footnote", [SlotMandatory])
  , ("route", [SlotMandatory, SlotMandatory])
  , ("cite", [SlotOptional, SlotOptional, SlotMandatory])
  , ("citep", [SlotOptional, SlotOptional, SlotMandatory])
  , ("citet", [SlotOptional, SlotOptional, SlotMandatory])
  , ("citeauthor", [SlotMandatory])
  , ("citeyear", [SlotMandatory])
  , ("citefootnote", [SlotOptional, SlotMandatory])
  , ("nocite", [SlotMandatory])
  , ("only", [SlotAngle, SlotMandatory])
  , ("uncover", [SlotAngle, SlotMandatory])
  , ("onslide", [SlotAngle, SlotMandatory])
  , ("visible", [SlotAngle, SlotMandatory])
  , ("invisible", [SlotAngle, SlotMandatory])
  , ("alert", [SlotAngle, SlotMandatory])
  , ("matrix", [SlotMandatory])
  , ("printbibliography", [SlotOptional])
  , ("pause", [SlotOptional])
  , ("alt", [SlotAngle, SlotMandatory, SlotMandatory])
  , ("includegraphics", [SlotOptional, SlotMandatory])
  , ("lstinputlisting", [SlotOptional, SlotMandatory])
  ]

knownCommand :: Ctx -> Text -> [Slot] -> TexParser Node
knownCommand ctx name slots = tex . Unresolved (MacroName name) <$> go slots
  where
    go [] = pure []
    go (slot : remaining) = do
      found <- optional (try (argumentFor slot))
      case found of
        Just argument -> (argument :) <$> go remaining
        Nothing
          | slot == SlotMandatory -> pure []
          | otherwise -> go remaining
    argumentFor slot =
      case slot of
        SlotAngle -> do
          before <- horizontalSpace
          spec <- angleSpec
          pure (Angle before spec)
        SlotOptional -> do
          before <- horizontalSpace
          children <- bracketedContent (nested ctx)
          pure (Optional before children)
        SlotMandatory -> do
          before <- argumentSpace
          children <- mandatoryGroup ctx
          pure (Mandatory before children)

-- | Spaces and tabs.
horizontalSpace :: TexParser Text
horizontalSpace = takeWhileP Nothing (\c -> c == ' ' || c == '\t')

-- | Whitespace between a command and a mandatory argument: horizontal space and
-- at most one line ending, as TeX allows.
argumentSpace :: TexParser Text
argumentSpace = do
  first <- horizontalSpace
  ending <- optional (chunk "\r\n" <|> chunk "\n")
  case ending of
    Nothing -> pure first
    Just newline -> do
      second <- horizontalSpace
      pure (first <> newline <> second)

-- | @\<spec>@ with its brackets consumed, returning the specification.
angleSpec :: TexParser Text
angleSpec = do
  _ <- char '<'
  spec <- takeWhile1P Nothing isSpecChar
  _ <- char '>'
  pure spec

isSpecChar :: Char -> Bool
isSpecChar c = Char.isDigit c || c `elem` ("-,+|()" :: String)

-- | A stand-alone overlay specification: it must contain a digit or @+@, which
-- no HTML tag name begins with.
overlaySpec :: TexParser Node
overlaySpec = try $ do
  spec <- angleSpec
  if Text.any (\c -> Char.isDigit c || c == '+') spec
    then pure (tex (Overlay spec))
    else empty

bracedName :: TexParser Text
bracedName = do
  _ <- char '{'
  name <- takeWhile1P Nothing (\c -> c /= '}' && c /= '{')
  _ <- char '}'
  pure name

-- | @{red}@, @{red!50}@, @{red!50!black}@.
bracedColour :: TexParser ColourExpr
bracedColour = do
  _ <- char '{'
  expression <- colourExpr
  _ <- char '}'
  pure expression

colourExpr :: TexParser ColourExpr
colourExpr = do
  base <- ColourName <$> colourName
  parts <- many (char '!' *> percentageAndOptionalBase)
  pure (foldl' apply base parts)
  where
    apply accumulated (percentage, Nothing) = ColourTint accumulated percentage
    apply accumulated (percentage, Just other) =
      ColourMix accumulated percentage other

percentageAndOptionalBase :: TexParser (Literal Rational, Maybe ColourExpr)
percentageAndOptionalBase = do
  written <- takeWhile1P Nothing (\c -> isDigit c || c == '.')
  other <- optional (try (char '!' *> (ColourName <$> colourName)))
  case readRationalText written of
    Nothing -> customFailure MalformedColour
    Just value -> pure (Literal value written, other)

-- | Total decimal conversion. 'read' is forbidden in production code.
readDecimalText :: Text -> Maybe Int
readDecimalText value
  | Text.null value = Nothing
  | Text.all isDigit value = Just (Text.foldl' step 0 value)
  | otherwise = Nothing
  where
    step accumulated character =
      accumulated * 10 + (fromEnum character - fromEnum '0')

-- | Total conversion of an unsigned decimal literal, such as @50@ or @12.5@.
readRationalText :: Text -> Maybe Rational
readRationalText value =
  case Text.splitOn "." value of
    [whole] -> toRational <$> readDecimalText whole
    [whole, fractional] -> do
      wholePart <- orZero whole
      fractionalPart <- orZero fractional
      let denominator = 10 ^ Text.length fractional :: Integer
      pure (toRational wholePart + (toInteger fractionalPart % denominator))
    _ -> Nothing
  where
    orZero part
      | Text.null part = Just 0
      | otherwise = readDecimalText part

isDigit :: Char -> Bool
isDigit c = c >= '0' && c <= '9'

colourName :: TexParser Text
colourName =
  takeWhile1P Nothing (\c -> isTexLetter c || (c >= '0' && c <= '9'))

failAt :: Int -> TexErrorKind -> TexParser a
failAt offset kind = do
  setOffset offset
  customFailure kind

isTexOrdinary :: Char -> Bool
isTexOrdinary c =
  not (isTexSpace c)
    && c /= '\\'
    && c /= '{'
    && c /= '}'
    && c /= '$'
    && c /= '%'
    && c /= '#'
    && c /= '&'
    && c /= '<'

isTexSpace :: Char -> Bool
isTexSpace c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

isTexLetter :: Char -> Bool
isTexLetter c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

toSyntaxError :: Text -> ParseErrorBundle Text TexErrorKind -> TexSyntaxError
toSyntaxError input bundle =
  TexSyntaxError
    { texErrorKind = kind
    , texErrorLine = Text.count "\n" prefix + 1
    , texErrorColumn = Text.length (Text.takeWhileEnd (/= '\n') prefix) + 1
    , texErrorMessage =
        maybe "unexpected input" (Text.pack . showErrorComponent) kind
    }
  where
    firstError = head' (bundleErrors bundle)
    prefix = maybe Text.empty (\e -> Text.take (errorOffset e) input) firstError
    kind = firstError >>= customKind

head' :: (Foldable f) => f a -> Maybe a
head' = listToMaybe . foldr (:) []

-- | Recover the typed component of an error raised by 'customFailure'.
customKind :: ParseError Text TexErrorKind -> Maybe TexErrorKind
customKind err =
  case err of
    TrivialError {} -> Nothing
    FancyError _ items ->
      listToMaybe [kind | ErrorCustom kind <- Set.toList items]
