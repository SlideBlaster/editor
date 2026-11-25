-- |
-- Module      : SlideBlaster.Syntax.Tikz.Ast
-- Description : The syntax tree of TikZ pictures.
--
-- The tree follows TikZ's own scanner (@tikz.code.tex@: the central dispatcher
-- @\\tikz\@handle@ and the handlers it names) and the path operations, commands
-- and coordinate systems the manual declares. Every node carries the 'Span' of
-- the source it was read from, in characters, so the tree is a view of the text:
-- the text itself is the printed form, and an edit replaces a span.
--
-- Three things are kept apart, as in the TeX reader:
--
-- * what is read and understood is a typed node;
-- * what is well formed but not a picture statement (a macro definition, a
--   library call, a command of some package) is 'ItemCommand', kept as written;
-- * a statement that starts as a path but cannot be read is 'ItemUnread' with
--   the reason, so one bad statement does not hide the rest of the picture.
module SlideBlaster.Syntax.Tikz.Ast
  ( Span (..)
  , spanLength
  , Document (..)
  , Chunk (..)
  , Picture (..)
  , Item (..)
  , PathCommand (..)
  , PathOp (..)
  , Join (..)
  , Target (..)
  , Arc (..)
  , Round (..)
  , PlotData (..)
  , Node (..)
  , NodeKind (..)
  , NodePart (..)
  , Foreach (..)
  , Braced (..)
  , Coordinate (..)
  , Relative (..)
  , CoordBody (..)
  , Options (..)
  , Option (..)
  , Value (..)
  , itemSpan
  , opSpan
  , nodeName
  , nodeAt
  , nodeOptions
  ) where

import Data.Text (Text)

-- | Half-open range of characters in the source: start and end.
data Span = Span !Int !Int
  deriving stock (Eq, Ord, Show)

spanLength :: Span -> Int
spanLength (Span a b) = b - a

-- | A TeX source that holds pictures: what stands between them is kept as written.
newtype Document = Document [Chunk]
  deriving stock (Eq, Show)

data Chunk
  = -- | Text outside any picture.
    ChunkText !Span
  | -- | @\\begin{tikzpicture}[options] .. \\end{tikzpicture}@; the span is the whole environment.
    ChunkPicture !Span !(Maybe Options) !Picture
  | -- | @\\tikz[options]{..}@ or @\\tikz[options] .. ;@
    ChunkInline !Span !(Maybe Options) !Picture
  deriving stock (Eq, Show)

-- | The statements of a picture body, in source order. The span is the body.
data Picture = Picture !Span ![Item]
  deriving stock (Eq, Show)

data Item
  = -- | @\\path@, @\\draw@, @\\fill@, @\\node@, @\\coordinate@, @\\matrix@, @\\pic@ .. up to its semicolon.
    ItemPath !PathCommand
  | -- | @\\begin{scope}[options] .. \\end{scope}@, or @\\scoped[options]{..}@ / @\\scoped[options] \\draw ..;@
    ItemScope !Span !(Maybe Options) !Picture
  | -- | @\\foreach \\x [options] in {list} { statements }@
    ItemForeach !Span !Foreach !Picture
  | -- | @\\tikzset{..}@
    ItemSet !Span !Options
  | -- | @\\tikzstyle{name}=[..]@ (or @+=@): the name, whether it appends, the options.
    ItemStyle !Span !Text !Bool !Options
  | -- | @\\begin{pgfonlayer}{name} .. \\end{pgfonlayer}@
    ItemLayer !Span !Text !Picture
  | -- | @\\only\<2-\>{ statements }@ (also @\\uncover@, @\\visible@, @\\invisible@, @\\onslide@, @\\alt@'s
    -- first branch is not read): the command, its overlay specification, the statements.
    ItemOverlay !Span !Text !Braced !Picture
  | -- | A command that is not a picture statement, with the arguments that follow it:
    -- @\\def\\r{2}@, @\\pgfmathsetmacro{\\a}{3*2}@, @\\usetikzlibrary{calc}@, @\\cat{file}@.
    -- The name is without the backslash; the arguments are as written.
    ItemCommand !Span !Text ![Braced]
  | -- | A comment line.
    ItemComment !Span
  | -- | A path statement that could not be read: where it is and why.
    ItemUnread !Span !Text
  deriving stock (Eq, Show)

-- | One path statement. @command@ is the name as written (@draw@, @node@);
-- @overlay@ is a beamer specification @\<2-\>@ after the command.
data PathCommand = PathCommand
  { pathSpan :: !Span
  , pathCommand :: !Text
  , pathOverlay :: !(Maybe Braced)
  , pathOps :: ![PathOp]
  }
  deriving stock (Eq, Show)

-- | How two points of a path are joined by a line.
data Join
  = -- | @--@
    JoinLine
  | -- | @-|@: horizontally, then vertically
    JoinHV
  | -- | @|-@: vertically, then horizontally
    JoinVH
  deriving stock (Eq, Show)

-- | Where an operation ends: a coordinate, or back at the start of the subpath.
data Target
  = TargetAt !Coordinate
  | TargetCycle !Span
  deriving stock (Eq, Show)

-- | The two ways an arc is written.
data Arc
  = -- | @arc (start:end:radius)@ or @(start:end:x and y)@, each part as written
    ArcOld !Text !Text !Text
  | -- | @arc[start angle=.., end angle=.., radius=..]@
    ArcKeys !Options
  deriving stock (Eq, Show)

-- | The two ways a circle or an ellipse is written.
data Round
  = -- | @circle (radius)@, @ellipse (x and y)@, as written between the parentheses
    RoundOld !Text
  | -- | @circle[radius=..]@; no options at all means the radius set earlier
    RoundKeys !(Maybe Options)
  deriving stock (Eq, Show)

data PlotData
  = PlotCoordinates ![Coordinate]
  | PlotFile !Braced
  | PlotFunction !Braced
  | -- | @plot (\\x, {sin(\\x r)})@: the coordinate expression
    PlotExpression !Coordinate
  deriving stock (Eq, Show)

-- | One operation of a path. Operations that draw from the current point to a
-- target carry the nodes written between them (@-- node {x} (b)@): those sit
-- on that part of the path.
data PathOp
  = -- | A coordinate on its own: move there.
    OpMove !Span !Coordinate
  | OpLine !Span !Join ![PathOp] !Target
  | -- | @.. controls c and d .. target@
    OpCurve !Span !Coordinate !(Maybe Coordinate) ![PathOp] !Target
  | OpRectangle !Span ![PathOp] !Target
  | OpCircle !Span !Round
  | OpEllipse !Span !Round
  | OpArc !Span !Arc
  | OpGrid !Span !(Maybe Options) !Target
  | -- | @parabola[options] bend b target@
    OpParabola !Span !(Maybe Options) !(Maybe Coordinate) !Target
  | OpSin !Span !Target
  | OpCos !Span !Target
  | -- | @plot@, or @-- plot@ when the flag is set
    OpPlot !Span !Bool !(Maybe Options) !PlotData
  | -- | @to[options] labels target@
    OpTo !Span ![Options] ![PathOp] !Target
  | -- | @edge[options] labels target@
    OpEdge !Span ![Options] ![PathOp] !Target
  | OpEdgeFromParent !Span !(Maybe Options) ![PathOp]
  | OpNode !Node
  | -- | @node also[late options](name)@
    OpNodeAlso !Span !(Maybe Options) !Text
  | -- | @[options]@ in the middle of a path
    OpOptions !Span !Options
  | -- | @{ .. }@: a scope within the path
    OpScope !Span ![PathOp]
  | -- | @foreach \\x in {list} { path }@
    OpForeach !Span !Foreach ![PathOp]
  | -- | @let \\p1 = (a), \\n1 = {..} in@: the assignments as written
    OpLet !Span !Text
  | -- | @child[options] foreach .. { path }@
    OpChild !Span ![Options] ![Foreach] !(Maybe [PathOp])
  | -- | @decorate[options] { subpath }@
    OpDecorate !Span !(Maybe Options) ![PathOp]
  | -- | @svg[options] {path data}@
    OpSvg !Span !(Maybe Options) !Braced
  | -- | @graph[options] { .. }@, the group as written
    OpGraph !Span !(Maybe Options) !Braced
  | -- | @l-system[options]@ or @lindenmayer system[options]@
    OpLSystem !Span !(Maybe Options)
  | -- | @\\pgfextra{code}@ or @\\pgfextra code \\endpgfextra@
    OpExtra !Span
  | -- | @:attribute = {..}@ (animations)
    OpAnimation !Span
  | -- | A macro standing in a path (it expands to path text): the name without the backslash.
    OpMacro !Span !Text
  deriving stock (Eq, Show)

data NodeKind
  = KindNode
  | KindCoordinate
  | KindPic
  deriving stock (Eq, Show)

-- | What may be written between @node@ and its text, in any order and any number of times.
data NodePart
  = PartOptions !Options
  | PartName !Span !Text
  | PartAt !Span !Coordinate
  | PartAnimation !Span
  deriving stock (Eq, Show)

-- | @node foreach .. [options] (name) at (c) {text}@. A coordinate has no
-- text; a node may have none only when an option supplies it (@node contents@).
data Node = Node
  { nodeSpan :: !Span
  , nodeKind :: !NodeKind
  , nodeForeach :: ![Foreach]
  , nodeParts :: ![NodePart]
  , nodeText :: !(Maybe Braced)
  }
  deriving stock (Eq, Show)

-- | @\\x/\\y [options] in {list}@: the variables as written (with their
-- slashes), the options, and the list (a braced list, or a macro holding one).
data Foreach = Foreach
  { foreachSpan :: !Span
  , foreachVariables :: !Text
  , foreachOptions :: !(Maybe Options)
  , foreachList :: !Braced
  }
  deriving stock (Eq, Show)

-- | A group or a single token standing for one: the span includes the braces
-- when there are any, the text is what is inside.
data Braced = Braced !Span !Text
  deriving stock (Eq, Show)

data Relative
  = -- | @(..)@
    Absolute
  | -- | @+(..)@: relative to the current point, which stays
    RelativeStay
  | -- | @++(..)@: relative to the current point, which moves
    RelativeMove
  deriving stock (Eq, Show)

-- | A coordinate: the span covers the signs and the parentheses.
data Coordinate = Coordinate
  { coordSpan :: !Span
  , coordRelative :: !Relative
  , coordOptions :: !(Maybe Options)
  -- ^ @([xshift=2pt] a.north)@
  , coordBody :: !CoordBody
  , coordText :: !Text
  -- ^ what stands between the parentheses, after the options
  }
  deriving stock (Eq, Show)

-- | The forms TikZ tells apart in @\\tikz\@\@scan\@\@no\@calculator@, in its order.
data CoordBody
  = -- | @(canvas cs:x=1cm,y=2cm)@: the system and its keys
    CoordSystem !Text !Options
  | -- | @(intersection of a--b and c--d)@, as written
    CoordIntersection !Text
  | -- | @(a |- b)@: the x of the first, the y of the second
    CoordVH !CoordBody !CoordBody
  | -- | @(a -| b)@: the y of the first, the x of the second
    CoordHV !CoordBody !CoordBody
  | -- | @(angle:radius)@ or @(angle:x and y)@; the angle may be a direction (@north@)
    CoordPolar !Text !Text !(Maybe Text)
  | -- | @(x,y)@: each part a number, a dimension or an expression, as written
    CoordXY !Text !Text
  | CoordXYZ !Text !Text !Text
  | -- | @(name)@ or @(name.anchor)@; a macro holding a name reads as a name too
    CoordNode !Text !(Maybe Text)
  | -- | @($ .. $)@ (the calc library), as written between the dollars
    CoordCalc !Text
  | -- | A macro standing where a coordinate is expected (it expands to one): its name without the backslash.
    CoordMacro !Text
  deriving stock (Eq, Show)

-- | An option list: the span of what stands between the brackets (or braces).
data Options = Options !Span ![Option]
  deriving stock (Eq, Show)

-- | One entry of an option list, split as pgfkeys splits it. The key has its
-- spaces normalised; a handler is what follows the last @/.@ (@style@,
-- @append style@, @code@, @default@).
data Option = Option
  { optionSpan :: !Span
  , optionKey :: !Text
  , optionHandler :: !(Maybe Text)
  , optionValue :: !(Maybe Value)
  }
  deriving stock (Eq, Show)

-- | The value of an option: its span as written (with outer braces), its text
-- with one pair of outer braces and outer spaces taken off, as pgfkeys does.
data Value = Value !Span !Text
  deriving stock (Eq, Show)

itemSpan :: Item -> Span
itemSpan item =
  case item of
    ItemPath command -> pathSpan command
    ItemScope s _ _ -> s
    ItemForeach s _ _ -> s
    ItemSet s _ -> s
    ItemStyle s _ _ _ -> s
    ItemLayer s _ _ -> s
    ItemOverlay s _ _ _ -> s
    ItemCommand s _ _ -> s
    ItemComment s -> s
    ItemUnread s _ -> s

opSpan :: PathOp -> Span
opSpan op =
  case op of
    OpMove s _ -> s
    OpLine s _ _ _ -> s
    OpCurve s _ _ _ _ -> s
    OpRectangle s _ _ -> s
    OpCircle s _ -> s
    OpEllipse s _ -> s
    OpArc s _ -> s
    OpGrid s _ _ -> s
    OpParabola s _ _ _ -> s
    OpSin s _ -> s
    OpCos s _ -> s
    OpPlot s _ _ _ -> s
    OpTo s _ _ _ -> s
    OpEdge s _ _ _ -> s
    OpEdgeFromParent s _ _ -> s
    OpNode node -> nodeSpan node
    OpNodeAlso s _ _ -> s
    OpOptions s _ -> s
    OpScope s _ -> s
    OpForeach s _ _ -> s
    OpLet s _ -> s
    OpChild s _ _ _ -> s
    OpDecorate s _ _ -> s
    OpSvg s _ _ -> s
    OpGraph s _ _ -> s
    OpLSystem s _ -> s
    OpExtra s -> s
    OpAnimation s -> s
    OpMacro s _ -> s

-- | The name a node is given with @(name)@: the last one written wins.
nodeName :: Node -> Maybe Text
nodeName node = case reverse [name | PartName _ name <- nodeParts node] of
  name : _ -> Just name
  [] -> Nothing

-- | Where a node is put with @at@: the last one written wins.
nodeAt :: Node -> Maybe Coordinate
nodeAt node = case reverse [at | PartAt _ at <- nodeParts node] of
  at : _ -> Just at
  [] -> Nothing

-- | All the options of a node, in the order written.
nodeOptions :: Node -> [Option]
nodeOptions node = concat [options | PartOptions (Options _ options) <- nodeParts node]
