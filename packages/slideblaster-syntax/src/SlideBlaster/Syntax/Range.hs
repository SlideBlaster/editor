-- |
-- Module      : SlideBlaster.Syntax.Range
-- Description : Turning a selection over rendered text into whole constructs.
--
-- A style edit applies to one construct, but a user selects a range of
-- characters, and that range rarely lines up with the tree. Selecting @ld ita@
-- across @\\textbf{Bold} \\textit{italic}@ starts inside one construct and ends
-- inside another. This module reduces such a range to a set of whole constructs,
-- so the edit itself stays the single-construct operation in
-- "SlideBlaster.Syntax.Edit".
--
-- == The character space
--
-- Offsets are measured in the concatenation of the run texts produced by
-- "SlideBlaster.Syntax.Inline", because that is exactly what the host rendered and
-- therefore what the user selected. Deriving the space from the runs rather than
-- recomputing it here means the two cannot disagree about where a character is.
--
-- == Splitting is invisible
--
-- Boundaries that fall inside a text node are made into node edges by splitting
-- that node into pieces held in a transparent container. Both operations are
-- printer-invisible: a transparent container prints its children and nothing
-- else, and the pieces concatenate to the original text, so preparing a selection
-- cannot change a single byte of the document. That is what makes it safe to
-- prepare a range before knowing whether the edit will succeed.
--
-- Splitting replaces one node with one node, so it never renumbers a sibling and
-- every other path stays valid across it.
--
-- == What is refused
--
-- A boundary inside a construct whose text is not its own source cannot be split,
-- because there is no way to divide @\\%@ into two halves that still print as
-- @\\%@. A range that reaches into a macro expansion is refused outright:
-- expansion is one-directional, so an edit there could never be written back.
module SlideBlaster.Syntax.Range
  ( -- * Naming a position
    Point (..)
  , RangeError (..)

    -- * The character space
  , Extents
  , runExtents
  , extentOf
  , globalOffset

    -- * Reducing a range to constructs
  , prepareSelection
  , coverOf

    -- * Context
  , enclosingDialect
  , uniformDialect
  , dialectAt
  , pathEntersExpansion
  ) where

import SlideBlaster.Syntax.Ast
  ( Node
  , NodeF (MacroUse, Run, Text)
  , node
  , nodeSpelledDialect
  , setPrimaryChildren
  )
import SlideBlaster.Syntax.Fix (unFix)
import SlideBlaster.Syntax.Inline (InlineRun (runPath, runText), flattenInline, inlineRuns)
import SlideBlaster.Syntax.Path
  ( Path
  , childAt
  , extendPath
  , pathFromList
  , pathToList
  , pathsOf
  , replaceAt
  , resolvePath
  , rootPath
  )
import SlideBlaster.Syntax.Printer (printNode)
import SlideBlaster.Syntax.Surface (Dialect, Surface (Transparent), dialectOf)

import Control.Monad (foldM)
import Data.Foldable (toList)
import Data.List (sort, unsnoc)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text qualified as Text

-- | A position the host can name: which rendered construct, and how many
-- characters into it.
--
-- The host gets both directly from a browser selection, because every run is
-- rendered as one element carrying its own path. Nothing has to be recovered by
-- counting from the start of the document.
data Point = Point
  { pointPath :: !Path
  , pointOffset :: !Int
  }
  deriving stock (Eq, Ord, Show)

-- | Why a range could not be reduced to constructs.
data RangeError
  = -- | The path names nothing, or nothing that was rendered, so it came from a
    -- different tree.
    RangePathNotRendered !Path
  | -- | The offset lies outside the construct it is measured in.
    RangeOffsetOutOfRange !Path !Int
  | -- | The boundary falls inside a construct whose text is not its own source,
    -- such as an escape, so no split can preserve it.
    RangeNotSplittable !Path
  | -- | The range selects no characters.
    RangeEmpty
  deriving stock (Eq, Show)

-- | Where each rendered construct sits in the character space, as a half-open
-- interval.
type Extents = Map Path (Int, Int)

-- | The interval of every construct that produced a run.
--
-- Only leaves appear here. Interior constructs get their interval from
-- 'extentOf', as the union of the leaves beneath them, so an interior interval
-- can never disagree with its contents.
runExtents :: Node -> Extents
runExtents tree =
  Map.fromListWith union (snd (foldl step (0, []) (inlineRuns (flattenInline tree))))
  where
    step (position, entries) run =
      let width = Text.length (runText run)
          next = position + width
       in (next, (runPath run, (position, next)) : entries)
    union (loLeft, hiLeft) (loRight, hiRight) =
      (min loLeft loRight, max hiLeft hiRight)

-- | The interval covered by a construct and everything beneath it.
--
-- 'Nothing' means the construct rendered nothing at all, as a comment does. Such
-- constructs are never included in a range, because there is no character of them
-- for the user to have selected.
extentOf :: Extents -> Path -> Maybe (Int, Int)
extentOf table path =
  case [interval | (leaf, interval) <- Map.toList table, covers (pathToList leaf)] of
    [] -> Nothing
    intervals -> Just (minimum (fmap fst intervals), maximum (fmap snd intervals))
  where
    prefix = pathToList path
    covers leaf = prefix == take (length prefix) leaf

-- | Where a point sits in the character space.
globalOffset :: Extents -> Point -> Either RangeError Int
globalOffset table (Point path offset) =
  case Map.lookup path table of
    Nothing -> Left (RangePathNotRendered path)
    Just (low, high)
      | offset < 0 || low + offset > high -> Left (RangeOffsetOutOfRange path offset)
      | otherwise -> Right (low + offset)

-- | Split text nodes so that both boundaries of a range fall between constructs
-- rather than inside one.
--
-- The returned tree prints byte for byte identically to its input. Offsets keep
-- their meaning across it, because splitting preserves every character.
--
-- Pieces are spliced into the parent's own child list, so they become siblings of
-- whatever surrounded the node that was divided. That matters for more than
-- tidiness: constructs an edit later creates from those pieces can only be merged
-- with their neighbours if they are actually adjacent to them. Where the parent
-- cannot hold a different number of children, the pieces go into a transparent
-- container instead, which is equally invisible to the printer but leaves them one
-- level deeper.
--
-- Splits are applied in descending path order so that dividing a later sibling
-- never renumbers an earlier one that is still to be divided.
prepareSelection :: Int -> Int -> Node -> Either RangeError Node
prepareSelection start end tree = foldM split tree ordered
  where
    ordered =
      reverse
        ( Map.toAscList
            ( Map.fromListWith
                (<>)
                [ (leaf, [boundary - low])
                | (leaf, (low, high)) <- Map.toList (runExtents tree)
                , boundary <- [start, end]
                , boundary > low
                , boundary < high
                ]
            )
        )
    split current (leaf, offsets) = do
      target <-
        maybe (Left (RangePathNotRendered leaf)) Right (resolvePath leaf current)
      (dialect, pieces) <- textPieces leaf (dedupe (sort offsets)) target
      insertPieces leaf dialect pieces current
    dedupe offsets =
      case offsets of
        first : second : rest
          | first == second -> dedupe (second : rest)
          | otherwise -> first : dedupe (second : rest)
        _ -> offsets

-- | Divide one text node at the given interior offsets.
--
-- Only a node whose printed form equals its own text can be divided. Reading that
-- condition off the printer rather than off the spelling means it stays true for
-- any spelling added later: there is no way to divide @\\%@ into halves that still
-- print as @\\%@.
textPieces :: Path -> [Int] -> Node -> Either RangeError (Dialect, [Node])
textPieces path offsets target =
  case unFix target of
    Text surface value
      | printNode target == value ->
          Right (dialectOf surface, [node (Text surface piece) | piece <- cut 0 offsets value])
    _ -> Left (RangeNotSplittable path)
  where
    cut _ [] rest = [rest]
    cut previous (offset : remaining) rest =
      let (piece, tail') = Text.splitAt (offset - previous) rest
       in piece : cut offset remaining tail'

-- | Put the pieces where the divided node was.
insertPieces :: Path -> Dialect -> [Node] -> Node -> Either RangeError Node
insertPieces leaf dialect pieces current =
  case unsnoc (pathToList leaf) of
    Nothing -> container
    Just (parentIndices, index) ->
      let parentPath = pathFromList parentIndices
       in case resolvePath parentPath current of
            Nothing -> Left (RangePathNotRendered leaf)
            Just parentNode ->
              let children = toList (unFix parentNode)
                  spliced = take index children <> pieces <> drop (index + 1) children
               in case setPrimaryChildren spliced parentNode of
                    Nothing -> container
                    Just rebuilt ->
                      maybe
                        (Left (RangePathNotRendered leaf))
                        Right
                        (replaceAt parentPath rebuilt current)
  where
    container =
      maybe
        (Left (RangePathNotRendered leaf))
        Right
        (replaceAt leaf (node (Run (Transparent dialect) pieces)) current)

-- | The outermost constructs entirely inside a range.
--
-- Descent stops as soon as a construct is fully covered, so a range that happens
-- to cover all of @\\textit{a b}@ yields that one construct rather than its
-- three children. That is what lets a single style edit wrap it once.
--
-- The returned paths are pairwise unrelated: none is an ancestor of another.
-- Wrapping a construct only adds depth beneath its own path, so the paths stay
-- valid however many of them are applied, in any order.
coverOf :: Int -> Int -> Node -> [Path]
coverOf start end tree = descend rootPath tree
  where
    table = runExtents tree
    descend path current =
      case extentOf table path of
        Nothing -> []
        Just (low, high)
          | high <= start || low >= end -> []
          | low >= start && high <= end && low < high -> [path]
          | otherwise ->
              concat
                ( zipWith
                    (\index child -> descend (extendPath path index) child)
                    [0 ..]
                    (toList (unFix current))
                )

-- | The dialect surrounding a position: the innermost construct on the way to it
-- that determines one.
--
-- This is what an edit spells a new construct in. 'Nothing' means nothing on the
-- path determines a dialect, which leaves the ambient dialect of the containing
-- document as the only answer.
enclosingDialect :: Path -> Node -> Maybe Dialect
enclosingDialect path tree = descend Nothing (pathToList path) tree
  where
    descend found indices current =
      let here =
            case nodeSpelledDialect (unFix current) of
              Just dialect -> Just dialect
              Nothing -> found
       in case indices of
            [] -> here
            index : remaining ->
              case childAt index current of
                Nothing -> here
                Just child -> descend here remaining child

-- | The one notation everything under a path is written in, if they agree.
--
-- Consulted when nothing encloses a position, which happens at the top of a
-- fragment: there is no outermost notation to inherit, because authored input is
-- one mixed language rather than a document in one of them. If everything being
-- wrapped is HTML then HTML is what the author is writing there, whatever else the
-- file contains elsewhere.
--
-- Constructs that commit to no notation are ignored rather than counted as
-- disagreement, so wrapping @\<em\>a\</em\> b@ still answers HTML.
uniformDialect :: Path -> Node -> Maybe Dialect
uniformDialect path tree =
  case resolvePath path tree of
    Nothing -> Nothing
    Just subtree ->
      case Set.toList (foldMap stated (pathsOf subtree)) of
        [only] -> Just only
        _ -> Nothing
  where
    stated (_, found) = maybe Set.empty Set.singleton (nodeSpelledDialect (unFix found))

-- | The notation a construct created at a path must be written in.
--
-- Three steps, in order. An enclosing construct settles it, because a new
-- construct placed inside one is written in that one's language. Failing that, the
-- content being wrapped settles it when it agrees with itself. Failing that nobody
-- knows -- an empty text box has no notation -- and the caller's default decides,
-- which is a theme setting rather than a property of the file.
dialectAt :: Dialect -> Path -> Node -> Dialect
dialectAt fallback path tree =
  case enclosingDialect path tree of
    Just dialect -> dialect
    Nothing -> fromMaybe fallback (uniformDialect path tree)

-- | Whether a path passes into the expansion of a macro use.
--
-- An expansion is a derived reading of the document, not part of it, so nothing
-- inside one can be edited: there is no source there to change. The expansion
-- occupies the first child positions of a 'MacroUse', ahead of its arguments,
-- which is the same order every other traversal sees.
pathEntersExpansion :: Path -> Node -> Bool
pathEntersExpansion path tree = descend (pathToList path) tree
  where
    descend indices current =
      case indices of
        [] -> False
        index : remaining ->
          case unFix current of
            MacroUse (Just expansion) _ _
              | index < length expansion -> True
            _ -> maybe False (descend remaining) (childAt index current)
