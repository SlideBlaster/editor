{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Syntax.Expand
-- Description : Bounded LaTeX2e macro expansion.
--
-- The reader cannot know a macro's arity, because arity comes from its definition,
-- so it emits every unknown control sequence as 'Unresolved' and leaves following
-- groups as ordinary siblings. This pass walks a run in document order carrying the
-- definitions seen so far and, on reaching a use of a defined macro, consumes the
-- required number of following group siblings as its arguments. That is how TeX
-- itself works.
--
-- Expansion preserves the tree's type, so substitution is an ordinary fold and
-- recursion into children needs no per-constructor rewriting. Two choices buy that:
-- a macro use carries its expansion as a 'Maybe' rather than the tree carrying a
-- phase parameter, and substituting an argument for a @#n@ parameter produces a
-- splice, so the rewrite is node-to-node rather than node-to-many.
--
-- Expansion is one-directional: the printer never reads an expansion, so editing a
-- construct inside one cannot rewrite the definition or any other use of it.
--
-- Only LaTeX2e definition forms are interpreted. Anything else, including @\\def@
-- with delimited parameters, remains 'Unresolved': preserved, printable, and
-- read-only.
module SlideBlaster.Syntax.Expand
  ( ExpansionError (..)
  , MacroEnv
  , emptyMacroEnv
  , expandTex
  , expandTexWith
  , expandedView
  , maximumExpansionDepth
  ) where

import SlideBlaster.Syntax.Ast
  ( ArgumentF (Angle, Mandatory, Optional)
  , DefinitionF (..)
  , DefinitionForm (NewEnvironmentForm, RenewEnvironmentForm)
  , ItemF (ItemF)
  , MacroName (..)
  , Node
  , NodeF (..)
  , ParametersF (..)
  )
import SlideBlaster.Syntax.Fix (Fix (Fix), cata, unFix)
import SlideBlaster.Syntax.Surface (Dialect (Tex), Surface (Transparent))

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

-- | Why expansion could not complete.
data ExpansionError
  = -- | A macro expanded into itself beyond 'maximumExpansionDepth'.
    ExpansionTooDeep !MacroName
  | -- | A macro use had fewer following group arguments than its arity requires.
    MissingArgument !MacroName !Int
  deriving stock (Eq, Show)

-- | Definitions in scope, keyed by name.
type MacroEnv = Map MacroName (DefinitionF Node)

emptyMacroEnv :: MacroEnv
emptyMacroEnv = Map.empty

-- | Guards against self-referential definitions such as @\\newcommand{\\a}{\\a}@,
-- which would otherwise expand forever.
maximumExpansionDepth :: Int
maximumExpansionDepth = 64

-- | Expand a run of nodes.
expandTex :: [Node] -> Either ExpansionError [Node]
expandTex nodes = snd <$> expandRun 0 emptyMacroEnv nodes

-- | Expand a run with a prelude of definitions in scope. The prelude is only
-- read for its definitions and is not part of the result.
expandTexWith :: [Node] -> [Node] -> Either ExpansionError [Node]
expandTexWith prelude nodes =
  drop (length definitions) . snd <$> expandRun 0 emptyMacroEnv (definitions <> nodes)
  where
    definitions = filter isDefinition prelude
    isDefinition current =
      case unFix current of
        Define _ -> True
        _ -> False

-- | Walk a run in document order, threading definitions forward.
--
-- A definition binds for the remainder of the run it appears in, matching TeX's
-- group scoping: the environment returned by a child run is discarded.
expandRun
  :: Int
  -> MacroEnv
  -> [Node]
  -> Either ExpansionError (MacroEnv, [Node])
expandRun depth env nodes =
  case nodes of
    [] -> Right (env, [])
    current : rest ->
      case unFix current of
        Define definition ->
          let extended = Map.insert (definitionKey definition) definition env
           in do
                (finalEnv, restNodes) <- expandRun depth extended rest
                pure (finalEnv, current : restNodes)
        Unresolved name []
          | Just definition <- Map.lookup name env ->
              expandUse depth env name definition rest
        Environment _ name body
          | Just definition <- Map.lookup (environmentKey name) env ->
              expandEnvironment depth env name definition body rest
        layer -> do
          expandedLayer <- mapChildRuns (fmap snd . expandRun depth env) layer
          (finalEnv, restNodes) <- expandRun depth env rest
          pure (finalEnv, Fix expandedLayer : restNodes)

-- | Expand one use of a defined macro, consuming its arguments from siblings.
expandUse
  :: Int
  -> MacroEnv
  -> MacroName
  -> DefinitionF Node
  -> [Node]
  -> Either ExpansionError (MacroEnv, [Node])
expandUse depth env name definition rest
  | depth >= maximumExpansionDepth = Left (ExpansionTooDeep name)
  | otherwise = do
      (arguments, remaining) <- takeArguments name arity rest
      let substituted =
            map (substitute (argumentBodies arguments)) (definitionBody definition)
      (_, expansion) <- expandRun (depth + 1) env substituted
      expandedArguments <- traverse (expandArgument depth env) arguments
      (finalEnv, restNodes) <- expandRun depth env remaining
      pure
        ( finalEnv
        , Fix (MacroUse (Just expansion) name expandedArguments) : restNodes
        )
  where
    arity = parameterCount (definitionParameters definition)

-- | The key under which a definition is stored. Environment definitions live in
-- their own namespace, because @\\newenvironment{x}@ and @\\newcommand{\\x}@ are
-- independent bindings.
definitionKey :: DefinitionF a -> MacroName
definitionKey definition
  | definitionForm definition `elem` [NewEnvironmentForm, RenewEnvironmentForm] =
      environmentKey (nameText (definitionName definition))
  | otherwise = definitionName definition
  where
    nameText (MacroName text) = text

environmentKey :: Text -> MacroName
environmentKey name = MacroName ("\\begin{" <> name <> "}")

-- | Expand one use of a user-defined environment. The arguments are the leading
-- group siblings of the body, as for a macro use; the expansion is the opening
-- text, the remaining content, and the closing text, with @\\bgroup .. \\egroup@
-- realised as the last argument of the command that precedes it, so that
-- @\\begin{block}{T} X \\end{block}@ expands to the same tree as @\\sbbox[..]{T}{X}@.
expandEnvironment
  :: Int
  -> MacroEnv
  -> Text
  -> DefinitionF Node
  -> [Node]
  -> [Node]
  -> Either ExpansionError (MacroEnv, [Node])
expandEnvironment depth env name definition body rest
  | depth >= maximumExpansionDepth = Left (ExpansionTooDeep (MacroName name))
  | otherwise = do
      (arguments, content) <- takeArguments (MacroName name) arity body
      let bodies = argumentBodies arguments
          opening = map (substitute bodies) (definitionBody definition)
          closing = map (substitute bodies) (maybe [] id (definitionClose definition))
      (_, expandedOpening) <- expandRun (depth + 1) env opening
      (_, expandedContent) <- expandRun depth env content
      (_, expandedClosing) <- expandRun (depth + 1) env closing
      (_, expandedBody) <- expandRun depth env body
      let expansion = mergeGroups (expandedOpening <> expandedContent <> expandedClosing)
      (finalEnv, restNodes) <- expandRun depth env rest
      pure (finalEnv, Fix (Environment (Just expansion) name expandedBody) : restNodes)
  where
    arity = parameterCount (definitionParameters definition)

-- | Realise @cmd{..}\\bgroup X \\egroup@ as @cmd{..}{X}@.
mergeGroups :: [Node] -> [Node]
mergeGroups nodes =
  case nodes of
    [] -> []
    current : following
      | Unresolved name arguments <- unFix current
      , name /= MacroName "bgroup"
      , name /= MacroName "egroup"
      , opener : afterOpener <- following
      , Unresolved (MacroName "bgroup") [] <- unFix opener
      , Just (inner, afterClose) <- closeGroup (0 :: Int) [] afterOpener ->
          Fix (Unresolved name (arguments <> [Mandatory Text.empty (mergeGroups inner)]))
            : mergeGroups afterClose
      | otherwise -> current : mergeGroups following
  where
    closeGroup depth collected remaining =
      case remaining of
        [] -> Nothing
        item : more ->
          case unFix item of
            Unresolved (MacroName "bgroup") [] ->
              closeGroup (depth + 1) (item : collected) more
            Unresolved (MacroName "egroup") []
              | depth == 0 -> Just (reverse collected, more)
              | otherwise -> closeGroup (depth - 1) (item : collected) more
            _ -> closeGroup depth (item : collected) more

-- | Replace every macro use and environment use by its expansion, throughout the
-- tree. The result is the tree a semantic pass reads: authored structure where
-- nothing was defined, and the expanded definition where something was. It is
-- derived and never printed back to source.
expandedView :: [Node] -> [Node]
expandedView = fmap (cata view)
  where
    view layer =
      case layer of
        MacroUse (Just expansion) _ _ -> Fix (Run (Transparent Tex) expansion)
        Environment (Just expansion) _ _ -> Fix (Run (Transparent Tex) expansion)
        other -> Fix other

argumentBodies :: [ArgumentF Node] -> [[Node]]
argumentBodies = map bodyOf
  where
    bodyOf argument =
      case argument of
        Mandatory _ children -> children
        Optional _ children -> children
        Angle _ _ -> []

-- | Take @arity@ braced group siblings, skipping and recording intervening
-- whitespace so it can be reprinted.
takeArguments
  :: MacroName
  -> Int
  -> [Node]
  -> Either ExpansionError ([ArgumentF Node], [Node])
takeArguments name arity = go 1 []
  where
    go index collected remaining
      | index > arity = Right (reverse collected, remaining)
      | otherwise =
          case peelGroup Text.empty remaining of
            Nothing -> Left (MissingArgument name index)
            Just (before, children, rest) ->
              go (index + 1) (Mandatory before children : collected) rest

    peelGroup before remaining =
      case remaining of
        [] -> Nothing
        current : rest ->
          case unFix current of
            Whitespace value -> peelGroup (before <> value) rest
            Run _ children -> Just (before, children, rest)
            _ -> Nothing

expandArgument
  :: Int
  -> MacroEnv
  -> ArgumentF Node
  -> Either ExpansionError (ArgumentF Node)
expandArgument depth env argument =
  case argument of
    Mandatory before children -> Mandatory before <$> expandChildren children
    Optional before children -> Optional before <$> expandChildren children
    Angle before spec -> Right (Angle before spec)
  where
    expandChildren children = snd <$> expandRun depth env children

-- | Replace each @#n@ in a definition body with the matching argument.
--
-- An ordinary bottom-up fold, because a parameter becomes a single splice node
-- rather than a sequence.
substitute :: [[Node]] -> Node -> Node
substitute arguments = cata rewrite
  where
    rewrite layer =
      case layer of
        Parameter index
          | Just replacement <- argumentAt index ->
              Fix (Run (Transparent Tex) replacement)
        _ -> Fix layer

    argumentAt index = do
      position <- parameterPosition index
      case drop (position - 1) arguments of
        found : _ -> Just found
        [] -> Nothing

    parameterPosition value =
      case Text.unpack value of
        [character]
          | character >= '1' && character <= '9' ->
              Just (fromEnum character - fromEnum '0')
        _ -> Nothing

-- | Apply a run transformation to every child run of a layer.
--
-- The one function that must enumerate constructors. Element-wise 'traverse' cannot
-- serve here: a macro use consumes following siblings, so expansion needs each child
-- /run/ rather than each child. Constructors with no child run pass through
-- untouched, which is possible only because expansion preserves the tree's type.
mapChildRuns
  :: (Applicative f)
  => ([Node] -> f [Node])
  -> NodeF Node
  -> f (NodeF Node)
mapChildRuns transform layer =
  case layer of
    Run surface children -> Run surface <$> transform children
    Styled facts surface children -> Styled facts surface <$> transform children
    Heading level surface children -> Heading level surface <$> transform children
    Quote surface children -> Quote surface <$> transform children
    Linked surface children -> Linked surface <$> transform children
    Items kind surface preamble items ->
      Items kind surface <$> transform preamble <*> traverse item items
    MacroUse expansion name arguments ->
      MacroUse
        <$> traverse transform expansion
        <*> pure name
        <*> traverse argument arguments
    Unresolved name arguments -> Unresolved name <$> traverse argument arguments
    Define definition -> Define <$> mapDefinition transform definition
    Text surface value -> pure (Text surface value)
    Whitespace value -> pure (Whitespace value)
    Comment surface value -> pure (Comment surface value)
    Verbatim surface value -> pure (Verbatim surface value)
    Break kind surface -> pure (Break kind surface)
    Foreign surface value -> pure (Foreign surface value)
    Math form payload -> pure (Math form payload)
    Parameter value -> pure (Parameter value)
    Alignment -> pure Alignment
    Overlay spec -> pure (Overlay spec)
    Environment expansion name body ->
      Environment <$> traverse transform expansion <*> pure name <*> transform body
  where
    item (ItemF surface label body) =
      ItemF surface <$> traverse transform label <*> transform body
    argument arg =
      case arg of
        Mandatory before children -> Mandatory before <$> transform children
        Optional before children -> Optional before <$> transform children
        Angle before spec -> pure (Angle before spec)

mapDefinition
  :: (Applicative f)
  => ([Node] -> f [Node])
  -> DefinitionF Node
  -> f (DefinitionF Node)
mapDefinition transform definition =
  rebuild
    <$> traverse transform (parameterOptionalDefault parameters)
    <*> transform (definitionBody definition)
    <*> traverse transform (definitionClose definition)
  where
    parameters = definitionParameters definition
    rebuild fallback body close =
      definition
        { definitionParameters = parameters {parameterOptionalDefault = fallback}
        , definitionBody = body
        , definitionClose = close
        }
