-- |
-- Module      : SlideBlaster.Syntax.Command
-- Description : The edits a user interface may ask for, as data.
--
-- "SlideBlaster.Syntax.Edit" is the primitive: one property, one construct. A user
-- interface cannot call it. It has to /say/ what it wants, over a wire, about a
-- selection it made in a browser, and be told whether that was possible. This
-- module is that language.
--
-- A 'Command' is data rather than a function so it can be transported, checked
-- before anything is touched, and batched into one transaction. It is not
-- invertible and does not need to be: history is a source revision, and restoring
-- exact bytes is strictly more reliable than replaying an inverse.
--
-- == The interface does not choose a dialect
--
-- A created construct is written in the language that already surrounds it, which
-- the tree knows and the interface does not.
--
-- Authored input is one mixed language: LaTeX, Markdown and HTML are co-equal
-- notations that appear side by side, and there is no outermost one. So there is
-- no document dialect to fall back on. The dialect passed to 'applyCommand' is a
-- theme setting, consulted only when neither an enclosing construct nor the
-- content being wrapped settles the question -- as in an empty text box, where
-- nobody could know. See 'SlideBlaster.Syntax.Range.dialectAt'.
--
-- When the chosen dialect cannot spell a property, the notations it admits are
-- tried in order, and if none can, the command is refused.
--
-- == What clearing means
--
-- Pressing an active bold button means "this should no longer be bold", and how
-- that is written depends on the construct. Where it carries the fact itself, the
-- fact is removed and the spelling goes with it. Where boldness is inherited from
-- an ancestor, removing nothing would change nothing, so the opposing value is
-- set instead and LaTeX gets @\\textmd@. Deciding between the two is a semantic
-- judgement and stays here rather than in the host.
--
-- == Coalescing
--
-- A range edit can produce adjacent constructs that say the same thing, as
-- @\\textbf{Bo}\\textbf{ld}@ does. Those are merged, but only when this command
-- created both of them. Constructs the author wrote are never merged into one
-- another, because that would rewrite bytes outside the selection.
module SlideBlaster.Syntax.Command
  ( -- * Commands
    Target (..)
  , Effect (..)
  , Command (..)
  , CommandError (..)

    -- * Applying
  , applyCommand

    -- * Derived vocabulary
  , neutralStyle
  ) where

import SlideBlaster.Syntax.Ast
  ( Node
  , NodeF (Styled)
  , node
  , setPrimaryChildren
  )
import SlideBlaster.Syntax.Edit
  ( EditError (PathNotFound, UnspellableStyle)
  , clearStyleAt
  , setStyleAt
  , stylesInPlace
  )
import SlideBlaster.Syntax.Fix (unFix)
import SlideBlaster.Syntax.Inline
  ( ResolvedStyle
  , flattenInline
  , inlineRuns
  , runStyle
  , runText
  , styleHolds
  )
import SlideBlaster.Syntax.Path
  ( Path
  , pathFromList
  , pathToList
  , pathsOf
  , replaceAt
  , resolvePath
  )
import SlideBlaster.Syntax.Range
  ( Point
  , RangeError (RangeEmpty, RangePathNotRendered)
  , coverOf
  , dialectAt
  , extentOf
  , globalOffset
  , pathEntersExpansion
  , prepareSelection
  , runExtents
  )
import SlideBlaster.Syntax.Style
  ( StyleKey
      ( BackgroundKey
      , FamilyKey
      , ForegroundKey
      , HighlightKey
      , SlantKey
      , StrikeKey
      , UnderlineKey
      , VariantKey
      , WeightKey
      )
  , StyleValue (SetHighlight, SetSlant, SetStrike, SetUnderline, SetVariant, SetWeight)
  , Slant (Upright)
  , Variant (NormalVariant)
  , Weight (NormalWeight)
  , styleKey
  )
import SlideBlaster.Syntax.Surface (Dialect, hostedDialects)

import Control.Monad (foldM)
import Data.Foldable (toList)
import Data.List (sort, sortOn, unsnoc)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text

-- | What a command applies to.
data Target
  = -- | One whole construct, named structurally.
    At !Path
  | -- | A range of rendered characters, which may begin and end inside different
    -- constructs. The two points may be given in either order.
    Between !Point !Point
  deriving stock (Eq, Show)

-- | What a command does.
--
-- There are two, not three: a toggle is not a separate effect, because the host
-- already knows the style in effect on every run it rendered and can therefore
-- say which of these it means.
data Effect
  = -- | Make this property hold.
    SetStyle !StyleValue
  | -- | Make this property not hold.
    ClearStyle !StyleKey
  | -- | Make this property hold unless it already does everywhere in the
    -- selection, in which case make it stop holding.
    --
    -- This is what a toolbar button means, and it is resolved here rather than by
    -- the interface. The interface would have to recompute which constructs the
    -- selection covers in order to decide, and a second implementation of that is
    -- a second chance to disagree with this one.
    ToggleStyle !StyleValue
  deriving stock (Eq, Show)

data Command = Command
  { commandTarget :: !Target
  , commandEffect :: !Effect
  }
  deriving stock (Eq, Show)

-- | Why a command was refused. In every case the tree is returned unchanged.
data CommandError
  = -- | The target does not resolve against this tree.
    CommandTargetNotFound !Path
  | -- | The target lies inside a macro expansion, which has no source to edit.
    CommandInsideExpansion !Path
  | -- | The range could not be reduced to constructs.
    CommandRange !RangeError
  | -- | Neither the enclosing dialect nor any dialect it hosts can write this
    -- property.
    CommandUnspellable !Dialect !StyleKey
  | -- | The property has no opposing value, so it cannot be cleared where it is
    -- inherited rather than carried.
    CommandNotClearable !StyleKey
  deriving stock (Eq, Show)

-- | The value that makes a property stop applying, where one exists.
--
-- Colour has none: without knowing what the surrounding text inherits there is no
-- value that means "no longer this colour". Family has none either, because the
-- roman, sans and mono families are three alternatives rather than one state and
-- its negation, so choosing one would change the appearance in a way that was not
-- asked for.
neutralStyle :: StyleKey -> Maybe StyleValue
neutralStyle key =
  case key of
    WeightKey -> Just (SetWeight NormalWeight)
    SlantKey -> Just (SetSlant Upright)
    VariantKey -> Just (SetVariant NormalVariant)
    UnderlineKey -> Just (SetUnderline False)
    StrikeKey -> Just (SetStrike False)
    HighlightKey -> Just (SetHighlight False)
    FamilyKey -> Nothing
    ForegroundKey -> Nothing
    BackgroundKey -> Nothing

-- | Carry out a command.
--
-- The dialect is the containing document's, used only where the tree itself does
-- not determine one.
applyCommand :: Dialect -> Command -> Node -> Either CommandError Node
applyCommand ambient (Command target effect) tree =
  case target of
    At path -> do
      guardExpansion path tree
      extent <-
        maybe
          (Left (CommandRange (RangePathNotRendered path)))
          Right
          (extentOf (runExtents tree) path)
      decided <- decide effect (fst extent) (snd extent) tree
      (edited, created) <- applyAt ambient decided path tree
      Right (coalesce [path | created] edited)
    Between first second -> do
      let table = runExtents tree
      firstOffset <- mapRange (globalOffset table first)
      secondOffset <- mapRange (globalOffset table second)
      let start = min firstOffset secondOffset
          end = max firstOffset secondOffset
      if start == end
        then Left (CommandRange RangeEmpty)
        else do
          prepared <- mapRange (prepareSelection start end tree)
          let paths = coverOf start end prepared
          if null paths
            then Left (CommandRange RangeEmpty)
            else do
              mapM_ (`guardExpansion` prepared) paths
              -- Decided once, for the whole selection, so a range that is partly
              -- bold becomes wholly bold instead of alternating construct by
              -- construct.
              decided <- decide effect start end prepared
              (edited, created) <- foldM (step ambient decided) (prepared, []) paths
              Right (coalesce created edited)
  where
    step dialect what (current, created) path = do
      (next, wasCreated) <- applyAt dialect what path current
      Right (next, if wasCreated then path : created else created)

-- | An effect whose toggle has been resolved.
--
-- Private, and the reason @applyAt@ needs no case for a toggle: by the time a
-- construct is edited the question has already been answered, and the type says
-- so rather than a comment promising it.
data Decided
  = DoSet !StyleValue
  | DoClear !StyleKey

-- | Resolve a toggle into the set or clear it means here; leave other effects
-- alone.
--
-- A toggle clears only when the property already holds across every character in
-- the selection. Anything less becomes a set, which is what a reader expects: a
-- range where one word is already bold becomes entirely bold on the first press,
-- not partly unbolded.
decide :: Effect -> Int -> Int -> Node -> Either CommandError Decided
decide effect start end tree =
  case effect of
    SetStyle value -> Right (DoSet value)
    ClearStyle key -> Right (DoClear key)
    ToggleStyle value
      | null covered -> Left (CommandRange RangeEmpty)
      | all (styleHolds value) covered -> Right (DoClear (styleKey value))
      | otherwise -> Right (DoSet value)
      where
        covered = stylesOver start end tree

-- | The resolved style of every rendered character in a half-open range.
--
-- The character space is the one 'runExtents' derives, so what is measured here
-- and what a point resolves to cannot drift apart.
stylesOver :: Int -> Int -> Node -> [ResolvedStyle]
stylesOver start end tree =
  snd (foldl step (0, []) (inlineRuns (flattenInline tree)))
  where
    step (position, kept) run =
      let width = Text.length (runText run)
          next = position + width
       in ( next
          , if width > 0 && position < end && next > start
              then runStyle run : kept
              else kept
          )

mapRange :: Either RangeError a -> Either CommandError a
mapRange = either (Left . CommandRange) Right

guardExpansion :: Path -> Node -> Either CommandError ()
guardExpansion path tree
  | pathEntersExpansion path tree = Left (CommandInsideExpansion path)
  | otherwise = Right ()

-- | Apply an effect at one construct, reporting whether a construct was created
-- there.
applyAt :: Dialect -> Decided -> Path -> Node -> Either CommandError (Node, Bool)
applyAt ambient effect path tree = do
  target <-
    maybe (Left (CommandTargetNotFound path)) Right (resolvePath path tree)
  let enclosing = dialectAt ambient path tree
  case effect of
    DoSet value -> do
      let created = not (stylesInPlace (styleKey value) target)
      edited <- setIn enclosing path value tree
      Right (edited, created)
    DoClear key -> clearOver enclosing key path tree

-- | Make a property stop holding over a whole construct.
--
-- Removing the fact from the construct's own facts is not enough. A selection
-- covering @\\textbf{ab}@ resolves to the container above it, which carries
-- nothing, and stating the opposing value there would produce
-- @\\textmd{\\textbf{ab}}@ — still bold, in LaTeX and on screen, so the edit
-- would not have done what it said. Every assertion of the property inside the
-- construct has to go.
--
-- The opposing value is stated only when the property still holds afterwards,
-- which means it comes from an ancestor outside the selection and there is
-- nothing inside to remove. Clearing preserves each node's shape, so the paths
-- collected up front stay valid while they are used.
clearOver
  :: Dialect -> StyleKey -> Path -> Node -> Either CommandError (Node, Bool)
clearOver enclosing key path tree = do
  stripped <- foldM removeOne tree carriers
  case neutralStyle key of
    Just neutral
      | stillHolds neutral path stripped -> do
          edited <- setIn enclosing path neutral stripped
          Right (edited, True)
      | otherwise -> Right (stripped, False)
    Nothing
      -- No value means "not this", so the only way to clear is to remove what
      -- asserts it. Nothing to remove is a refusal rather than a silent no-op,
      -- because the property does still hold and saying otherwise would be false.
      | null carriers -> Left (CommandNotClearable key)
      | otherwise -> Right (stripped, False)
  where
    carriers = carriersUnder key path tree
    removeOne current carrier =
      mapEdit enclosing key (clearStyleAt carrier key current)

-- | Every construct at or under a path that asserts a property itself, deepest
-- first.
carriersUnder :: StyleKey -> Path -> Node -> [Path]
carriersUnder key path tree =
  case resolvePath path tree of
    Nothing -> []
    Just subtree ->
      sortOn
        (negate . length . pathToList)
        [ absolute
        | (relative, found) <- pathsOf subtree
        , stylesInPlace key found
        , let absolute = pathFromList (pathToList path <> pathToList relative)
        ]

-- | Whether a property still holds anywhere under a path, given the value that
-- would mean it does not.
--
-- Judged from the resolved style of the rendered characters, so a fact inherited
-- from an ancestor outside the selection counts. That is exactly the case where
-- the opposing value has to be stated, because there is nothing inside to remove.
stillHolds :: StyleValue -> Path -> Node -> Bool
stillHolds neutral path tree =
  case extentOf (runExtents tree) path of
    Nothing -> False
    Just (low, high) -> not (all (styleHolds neutral) (stylesOver low high tree))

-- | Try the enclosing dialect, then the dialects it hosts, until one can write
-- the property.
--
-- The ladder is never empty, so exhausting it means no admissible dialect can
-- spell the property, and the enclosing one is what the refusal names.
setIn :: Dialect -> Path -> StyleValue -> Node -> Either CommandError Node
setIn enclosing path value tree = attempt (hostedDialects enclosing)
  where
    attempt candidates =
      case candidates of
        [] -> Left (CommandUnspellable enclosing (styleKey value))
        dialect : remaining ->
          case setStyleAt dialect path value tree of
            Right edited -> Right edited
            Left (UnspellableStyle _ _) -> attempt remaining
            Left (PathNotFound missing) -> Left (CommandTargetNotFound missing)

mapEdit :: Dialect -> StyleKey -> Either EditError Node -> Either CommandError Node
mapEdit enclosing key result =
  case result of
    Right edited -> Right edited
    Left (PathNotFound missing) -> Left (CommandTargetNotFound missing)
    Left (UnspellableStyle _ _) -> Left (CommandUnspellable enclosing key)

-- | Merge adjacent constructs that this command created and that now say the same
-- thing.
--
-- Only constructs named in the given paths are candidates, so nothing the author
-- wrote is ever absorbed into a neighbour. Groups are merged from the right so
-- that earlier positions stay valid, and deeper parents first so that a merge
-- never invalidates one still to come.
coalesce :: [Path] -> Node -> Node
coalesce created tree = foldl mergeUnder tree deepestFirst
  where
    byParent :: Map Path [Int]
    byParent =
      Map.fromListWith
        (<>)
        [ (pathFromList parent, [index])
        | path <- created
        , Just (parent, index) <- [unsnoc (pathToList path)]
        ]
    deepestFirst =
      sortOn (negate . length . pathToList . fst) (Map.toList byParent)
    mergeUnder current (parent, indices) =
      case resolvePath parent current of
        Nothing -> current
        Just parentNode ->
          let children = toList (unFix parentNode)
              merged =
                foldl mergeGroup children (reverse (consecutiveRuns (sort indices)))
           in if length merged == length children
                then current
                else case setPrimaryChildren merged parentNode of
                  Nothing -> current
                  Just rebuilt -> fromMaybe current (replaceAt parent rebuilt current)
    mergeGroup children group
      | first : _ : _ <- group
      , selected <- [child | (index, child) <- zip [0 ..] children, index `elem` group]
      , Just single <- mergeAll selected =
          take first children <> [single] <> drop (first + length group) children
      | otherwise = children
    mergeAll nodes =
      case nodes of
        [] -> Nothing
        firstNode : rest ->
          case unFix firstNode of
            Styled facts surface children -> absorb facts surface children rest
            _ -> Nothing
      where
        absorb facts surface acc remaining =
          case remaining of
            [] -> Just (node (Styled facts surface acc))
            next : rest ->
              case unFix next of
                Styled otherFacts otherSurface otherChildren
                  | otherFacts == facts
                  , otherSurface == surface ->
                      absorb facts surface (acc <> otherChildren) rest
                _ -> Nothing

-- | Maximal groups of consecutive integers in an ascending list.
consecutiveRuns :: [Int] -> [[Int]]
consecutiveRuns = foldr step []
  where
    step value groups =
      case groups of
        group@(next : _) : rest
          | next == value + 1 -> (value : group) : rest
        _ -> [value] : groups
