{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Inline
-- Description : Canonical lowering: authored tree to style-resolved flat runs.
--
-- The tree answers "what did the author write, and in which dialect". A renderer
-- asks a different question: "what characters go on screen, with what styling in
-- effect". This module derives the second from the first.
--
-- The result is deliberately /derived/ and disposable. It is never persisted and
-- never an edit target, because it has thrown away the information an edit needs:
-- nesting order, spelling, and dialect. Every run instead carries the 'Path' of
-- the construct it came from, so an interaction on screen resolves back into the
-- authored tree, which is where edits happen. That is the whole reason paths
-- exist.
--
-- Two style representations therefore coexist on purpose:
--
-- * 'SlideBlaster.Syntax.Style.StyleMap' is what the /source says/ at one
--   construct. It is partial and per-node, so nesting order survives and an edit
--   can change one property without asserting anything about the others.
-- * 'ResolvedStyle' is what is /in effect/ at one run. It is total, because a
--   renderer cannot act on "unspecified", and it is the accumulation of every
--   enclosing construct.
--
-- Lowering is a paramorphism: the fold needs each child's result and also its
-- original subtree, because a construct outside the supported subset is rendered
-- by reprinting its own exact source. The printer is exact, so an unsupported
-- construct still shows the author's bytes instead of vanishing.
--
-- Scope boundary, stated rather than hidden: this lowering is for /inline/
-- content. Block structure is descended into but not represented, so the items
-- of a list flatten into consecutive runs. A block lowering is separate work and
-- is not implied by this module.
module SlideBlaster.Syntax.Inline
  ( ResolvedStyle (..)
  , defaultStyle
  , RunKind (..)
  , InlineRun (..)
  , InlineIssue (..)
  , Inline (..)
  , flattenInline
  , opaqueInline
  , inlineText
  , coalesceRuns
  , styleHolds
  ) where

import SlideBlaster.Syntax.Ast
  ( MacroName
  , MathForm
  , Node
  , NodeF (..)
  )
import SlideBlaster.Syntax.Colour
  ( ColourError
  , Rgb
  , resolveColour
  )
import SlideBlaster.Syntax.Fix (Fix (Fix), para)
import SlideBlaster.Syntax.Path (Path, extendPath, rootPath)
import SlideBlaster.Syntax.Printer (printNode)
import SlideBlaster.Syntax.Style
  ( ColourExpr
  , Family (Serif)
  , Slant (Upright)
  , StyleMap
  , StyleValue (..)
  , Variant (NormalVariant)
  , Weight (NormalWeight)
  , styleMapToList
  )
import SlideBlaster.Syntax.Surface (Dialect, dialectOf, linkTarget)

import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as Text

-- | Every styling property, resolved to a definite value.
--
-- Total by construction: a renderer is never handed "unspecified".
data ResolvedStyle = ResolvedStyle
  { styleWeight :: !Weight
  , styleSlant :: !Slant
  , styleFamily :: !Family
  , styleVariant :: !Variant
  , styleUnderline :: !Bool
  , styleStrike :: !Bool
  , styleHighlight :: !Bool
  , styleForeground :: !(Maybe Rgb)
  , styleBackground :: !(Maybe Rgb)
  }
  deriving stock (Eq, Show)

-- | Unstyled body text: the state before any construct applies.
--
-- Colours are 'Nothing' rather than black, because "the author did not say" and
-- "the author said black" must stay distinguishable; the theme decides the
-- former.
defaultStyle :: ResolvedStyle
defaultStyle =
  ResolvedStyle
    { styleWeight = NormalWeight
    , styleSlant = Upright
    , styleFamily = Serif
    , styleVariant = NormalVariant
    , styleUnderline = False
    , styleStrike = False
    , styleHighlight = False
    , styleForeground = Nothing
    , styleBackground = Nothing
    }

-- | What a run represents, so a renderer can treat it correctly instead of
-- guessing from its text.
data RunKind
  = -- | Ordinary characters, ready to draw.
    PlainRun
  | -- | Mathematics, still in source form. The payload needs a math renderer;
    -- until there is one, showing the source is honest.
    MathRun !MathForm
  | -- | Preformatted text whose spacing is significant.
    VerbatimRun
  | -- | An explicit break authored in the source.
    BreakRun
  | -- | Outside the supported subset. The text is the construct's exact source,
    -- so nothing is lost on screen even though nothing is understood.
    OpaqueRun
  deriving stock (Eq, Show)

-- | One contiguous piece of content with its styling resolved.
data InlineRun = InlineRun
  { runKind :: !RunKind
  , runText :: !Text
  , runStyle :: !ResolvedStyle
  , -- | Where this came from, for resolving an interaction back to the tree.
    runPath :: !Path
  , -- | Which dialect authored it, so an edit here can be spelled that way.
    runDialect :: !(Maybe Dialect)
  , runLink :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | Something the lowering could not fully interpret.
--
-- Reported rather than thrown: a document with one unknown colour name is still
-- a document, and the caller decides whether that is a warning or a failure.
data InlineIssue
  = -- | A colour expression has no resolvable meaning.
    UnresolvableColour !Path !ColourError
  | -- | A macro use was never expanded, so its meaning is unknown here.
    UnexpandedMacro !Path !MacroName
  deriving stock (Eq, Show)

-- | The lowered content of one construct.
data Inline = Inline
  { inlineRuns :: ![InlineRun]
  , inlineIssues :: ![InlineIssue]
  }
  deriving stock (Eq, Show)

instance Semigroup Inline where
  left <> right =
    Inline
      (inlineRuns left <> inlineRuns right)
      (inlineIssues left <> inlineIssues right)

instance Monoid Inline where
  mempty = Inline [] []

-- | The concatenated visible text, ignoring styling.
inlineText :: Inline -> Text
inlineText = foldMap runText . inlineRuns

-- | Join neighbouring runs that a renderer would style identically.
--
-- Two uses. A host draws one element instead of several. And an edit can be
-- checked against its intent: a range edit divides a text construct in two, so the
-- tree that results and the tree read back from its printed source are not equal
-- as trees, while their coalesced runs are. Comparing those is what verifies that
-- patched source reparses to the meaning that was asked for.
--
-- Paths are dropped from the joined runs by keeping the first one's, so this is a
-- comparison and drawing aid, not something to address an edit through.
coalesceRuns :: Inline -> Inline
coalesceRuns (Inline runs issues) = Inline (go runs) issues
  where
    go remaining =
      case remaining of
        first : second : rest
          | joinable first second ->
              go (first {runText = runText first <> runText second} : rest)
          | otherwise -> first : go (second : rest)
        _ -> remaining
    joinable left right =
      runKind left == runKind right
        && runStyle left == runStyle right
        && runDialect left == runDialect right
        && runLink left == runLink right
        && plain (runKind left)
    -- Only plain text may be joined. Two adjacent maths or verbatim runs are
    -- separate constructs whose contents must not be run together, and two breaks
    -- are two breaks.
    plain kind =
      case kind of
        PlainRun -> True
        MathRun _ -> False
        VerbatimRun -> False
        BreakRun -> False
        OpaqueRun -> False

-- | The lowering of content that could not be read at all.
--
-- Needed because a reader failure and an unsupported construct are different
-- events with the same obligation: show the author's exact bytes. Callers that
-- decline to fail a whole document over one unreadable fragment use this, and the
-- result is still a well-formed lowering rather than a special case downstream.
opaqueInline :: Text -> Inline
opaqueInline source =
  Inline
    [ InlineRun
        { runKind = OpaqueRun
        , runText = source
        , runStyle = defaultStyle
        , runPath = rootPath
        , runDialect = Nothing
        , runLink = Nothing
        }
    ]
    []

-- | The environment carried down the tree while lowering.
data Env = Env
  { envStyle :: !ResolvedStyle
  , envLink :: !(Maybe Text)
  , envPath :: !Path
  }

-- | Lower a construct to resolved runs.
flattenInline :: Node -> Inline
flattenInline tree = para algebra tree (Env defaultStyle Nothing rootPath)

algebra :: NodeF (Node, Env -> Inline) -> Env -> Inline
algebra layer env =
  case layer of
    -- A text node's value is the character it denotes, not its spelling, so an
    -- escaped character and a literal one render identically. That is the
    -- payoff of keeping spelling in the surface.
    Text surface value -> emit PlainRun value (Just (dialectOf surface))
    Whitespace value -> emit PlainRun value Nothing
    -- Comments are authored content but not rendered content.
    Comment _ _ -> mempty
    Verbatim surface value -> emit VerbatimRun value (Just (dialectOf surface))
    Math form payload -> emit (MathRun form) payload Nothing
    Break _ surface -> emit BreakRun Text.empty (Just (dialectOf surface))
    -- A definition renders nothing; its body is a template, not content.
    Define _ -> mempty
    Foreign surface value -> emit OpaqueRun value (Just (dialectOf surface))
    -- A parameter outside an expansion has no value to render.
    Parameter _ -> opaque
    Alignment -> opaque
    -- A stand-alone overlay specification affects visibility, not characters.
    Overlay _ -> mempty
    Run _ _ -> descendAll
    Heading _ _ _ -> descendAll
    Quote _ _ -> descendAll
    Items _ _ _ _ -> descendAll
    Styled facts _ _ ->
      let (resolved, issues) = applyFacts (envPath env) facts (envStyle env)
       in Inline [] issues <> descendWith env {envStyle = resolved}
    Linked surface _ ->
      descendWith env {envLink = linkTarget surface}
    -- Rendering a macro use means rendering what it expanded to. Only the
    -- expansion is descended into: the arguments already appear inside it, and
    -- visiting them too would duplicate every argument on screen.
    MacroUse (Just expansion) _ _ ->
      descendIndices [0 .. length expansion - 1] env
    MacroUse Nothing name _ -> unexpanded name
    Environment (Just expansion) _ _ ->
      descendIndices [0 .. length expansion - 1] env
    Environment Nothing _ _ -> descendAll
    Unresolved name _ -> unexpanded name
  where
    emit kind value dialect =
      Inline
        [ InlineRun
            { runKind = kind
            , runText = value
            , runStyle = envStyle env
            , runPath = envPath env
            , runDialect = dialect
            , runLink = envLink env
            }
        ]
        []

    -- Reprint this construct's own source. Available because the fold retained
    -- each original subtree.
    opaque = emit OpaqueRun (printNode (Fix (fmap fst layer))) Nothing

    unexpanded name =
      opaque <> Inline [] [UnexpandedMacro (envPath env) name]

    descendAll = descendWith env

    descendWith childEnv =
      descendIndices [0 .. length (toList layer) - 1] childEnv

    -- Child index and path index are the same number because both come from
    -- Foldable order.
    descendIndices indices childEnv =
      foldMap
        ( \index ->
            case drop index (toList layer) of
              (_, child) : _ ->
                child childEnv {envPath = extendPath (envPath childEnv) index}
              [] -> mempty
        )
        indices

-- | Apply one construct's style facts to the style in effect.
--
-- Facts are keyed, so applying them in any order gives the same result; that is
-- why a single construct's facts need no ordering and nesting carries it instead.
applyFacts :: Path -> StyleMap -> ResolvedStyle -> (ResolvedStyle, [InlineIssue])
applyFacts path facts initial =
  foldl' step (initial, []) (styleMapToList facts)
  where
    step (style, issues) value =
      case value of
        SetWeight weight -> (style {styleWeight = weight}, issues)
        SetSlant slant -> (style {styleSlant = slant}, issues)
        SetFamily family -> (style {styleFamily = family}, issues)
        SetVariant variant -> (style {styleVariant = variant}, issues)
        SetUnderline flag -> (style {styleUnderline = flag}, issues)
        SetStrike flag -> (style {styleStrike = flag}, issues)
        SetHighlight flag -> (style {styleHighlight = flag}, issues)
        SetForeground expression ->
          case resolve expression of
            Right colour -> (style {styleForeground = Just colour}, issues)
            Left issue -> (style, issues <> [issue])
        SetBackground expression ->
          case resolve expression of
            Right colour -> (style {styleBackground = Just colour}, issues)
            Left issue -> (style, issues <> [issue])

    resolve :: ColourExpr -> Either InlineIssue Rgb
    resolve expression =
      case resolveColour expression of
        Right colour -> Right colour
        Left failure -> Left (UnresolvableColour path failure)

-- | Whether a resolved style already asserts what a style value would set.
--
-- This is what makes a toggle possible: pressing an active bold button has to
-- mean "stop being bold", and only the resolved style knows whether bold is
-- already in force, including when it is inherited from an ancestor rather than
-- stated here.
--
-- A colour holds when it resolves to the same sRGB triple, so @red@ and
-- @rgb(1,0,0)@ are the same fact under two spellings. An expression that cannot
-- be resolved holds nothing: refusing to guess is better than reporting a match
-- against a colour nobody can name.
styleHolds :: StyleValue -> ResolvedStyle -> Bool
styleHolds value style =
  case value of
    SetWeight weight -> styleWeight style == weight
    SetSlant slant -> styleSlant style == slant
    SetFamily family -> styleFamily style == family
    SetVariant variant -> styleVariant style == variant
    SetUnderline flag -> styleUnderline style == flag
    SetStrike flag -> styleStrike style == flag
    SetHighlight flag -> styleHighlight style == flag
    SetForeground expression -> sameColour expression (styleForeground style)
    SetBackground expression -> sameColour expression (styleBackground style)
  where
    sameColour expression current =
      case (resolveColour expression, current) of
        (Right wanted, Just present) -> wanted == present
        _ -> False
