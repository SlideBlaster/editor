{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Deck.PictureEdit
-- Description : Verified canvas edits of a slide's @```slide@ picture block.
--
-- What a person does on the canvas (drop a node, drag it, retype it, connect
-- two nodes, attach one to another, delete something) becomes one exact replacement inside that
-- slide's picture block. Statement text is never reprinted: an edit splices the
-- one part it changes (a point, a content, a name) or adds or removes whole
-- statements, so untouched source keeps its bytes.
--
-- Every edit is then verified: the successor deck is read again, must be
-- ready, must show the same slides, and its picture block must read as exactly
-- the statements the edit intended. Text that would escape its braces or close
-- the block therefore rejects the edit instead of changing its meaning.
module SlideBlaster.Deck.PictureEdit
  ( PictureOp (..)
  , Layer (..)
  , OptionChange (..)
  , applyOptions
  , PictureEditError (..)
  , editPicture
  , pictureEditMessage
  ) where

import SlideBlaster.Canvas.Flow (PictureEndpoint (..), parseDraw)
import SlideBlaster.Deck.Container (Container (..), SlideEntry (..), Span (..))
import SlideBlaster.Deck.Markdown
  ( DeckConfig (..)
  , DeckSlide (..)
  , MarkdownDeck (..)
  , MarkdownDeckDocument
  , MarkdownDeckSyntax (..)
  , analyzeMarkdownDeckWith
  , slidePictureFences
  )
import SlideBlaster.Document qualified as Document
import SlideBlaster.Source qualified as Source
import SlideBlaster.Syntax.Picture (DrawJoin (..), DrawLabel (..), DrawPath (..), DrawPoint (..), DrawStep (..), NodeSpans (..), Statement (..), attachSides, attachmentOf, catOf, catParts, nodeSpans, optionItems, optionPairs, printDraw, readDraw, readPicture, statementText)

import Data.ByteString qualified as ByteString
import Data.Char (isAlphaNum, isSpace)
import Control.Monad (foldM)
import Data.List (nub, sortOn)
import Data.Ratio ((%))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.Unsafe (lengthWord8)

-- | One canvas edit. Coordinates are slide units (origin bottom-left) and are
-- written with at most two decimals. A node is addressed by its id: its name,
-- or @picture-N@ for the unnamed N-th statement. A line is @line-N@.
data PictureOp
  = -- | Options (may be empty), centre and content of a new node.
    AddNode !Text !Rational !Rational !Text
  | -- | Put a node at a point; an attached node is detached.
    MoveNode !Text !Rational !Rational
  | -- | Attach a node to a side of another (@above@, @below@, @left@, @right@
    -- or a diagonal such as @above right@), at a written distance or the default
    -- one, so it follows that node; its own point is dropped from the source.
    -- The target may also be the slide's @title@ or @body@.
    AttachNode !Text !Text !Text !(Maybe Rational)
  | SetNodeText !Text !Text
  | -- | Change the options of a node or line (@line-N@): how it looks.
    SetOptions !Text ![OptionChange]
  | -- | An arrow from the first node to the second; unnamed nodes get a name.
    ConnectNodes !Text !Text
  | -- | Remove a node (with the lines that end on it) or a line. Nodes attached
    -- to a removed node stay where they are: the list gives each one's point.
    DeleteItem !Text ![(Text, Rational, Rational)]
  | -- | Remove several nodes, lines and included pictures at once (ids as they
    -- are before the edit); the list pins the nodes attached to removed ones.
    DeleteItems ![Text] ![(Text, Rational, Rational)]
  | -- | Move a node among the nodes: later statements are painted on top.
    Reorder !Text !Layer
  | -- | Add copies of the given statements (nodes, and lines between them),
    -- shifted by a distance in slide units. Every copied node gets a new name.
    PasteStatements !Text !Rational !Rational
  | -- | Several edits as one, each applied to what the one before left.
    Batch ![PictureOp]
  | -- | How a line goes between its points: @straight@, @hv@ (along x, then
    -- y), @vh@, @bend left@ or @bend right@, a bend by the given degrees or by
    -- what it had (else TikZ's own 30).
    SetRoute !Text !Text !(Maybe Rational)
  | -- | The text of a line's label, numbered from 1 as written; 0 adds one on
    -- the middle step; an empty text removes the label.
    SetLineLabel !Text !Int !Text
  | -- | Change the options of a line's label: where it sits and how it looks.
    SetLabelOptions !Text !Int ![OptionChange]
  | -- | Put a point into a line's step (numbered from 1), so it goes through it.
    AddLinePoint !Text !Int !Rational !Rational
  | -- | Move a written point of a line (points numbered from 0).
    MoveLinePoint !Text !Int !Rational !Rational
  | -- | Take a point between the ends out of a line.
    RemoveLinePoint !Text !Int
  | -- | Bring a picture file onto the slide: @\\cat[shift={(x,y)}]{path};@.
    AddInclude !Text !Rational !Rational
  | -- | Give an included picture (@cat-N@) a shift, in slide units.
    MoveInclude !Text !Rational !Rational
  deriving stock (Eq, Show)

-- | Where a node goes in the painting order.
data Layer = ToFront | ToBack | Forward | Backward
  deriving stock (Eq, Show)

-- | One change to an option list, by key.
data OptionChange
  = -- | @key=value@, or the bare @key@ when there is no value; replaces the
    -- option of that key where it stands, else is added at the end.
    SetOption !Text !(Maybe Text)
  | RemoveOption !Text
  deriving stock (Eq, Show)

-- | An option list with the changes made; untouched options keep their text.
applyOptions :: [OptionChange] -> Text -> Text
applyOptions changes options = tidy (foldl step (optionItems options) changes)
  where
    keyOf item = Text.unwords (Text.words (fst (Text.breakOn "=" item)))
    written key value = key <> maybe "" ("=" <>) value
    step items one =
      case one of
        RemoveOption key -> filter ((/= key) . keyOf) items
        SetOption key value
          | any ((== key) . keyOf) items -> [if keyOf item == key then Text.takeWhile isSpace item <> written key value else item | item <- items]
          | null items -> [written key value]
          | otherwise -> take (length items - 1) items <> fmap (Text.dropWhileEnd isSpace) (drop (length items - 1) items) <> [" " <> written key value]
    tidy items =
      case items of
        first : rest -> Text.intercalate "," (Text.stripStart first : rest)
        [] -> ""

data PictureEditError
  = PictureNotReady
  | PictureSlideMissing !Text
  | PictureNotEditable !Text
  | PictureItemMissing !Text
  | PictureSourceRejected
  | PictureVerificationRejected
  deriving stock (Eq, Show)

-- | A sentence for the person who made the edit.
pictureEditMessage :: PictureEditError -> Text
pictureEditMessage failure =
  case failure of
    PictureNotReady -> "the deck has errors; fix them in the source first"
    PictureSlideMissing slide -> "this slide cannot be edited on the canvas (" <> slide <> ")"
    PictureNotEditable reason -> reason
    PictureItemMissing item -> "there is no " <> item <> " on this slide any more"
    PictureSourceRejected -> "the source changed underneath the edit"
    PictureVerificationRejected -> "the edit would not read back as intended (check braces in the text); nothing was changed"

-- Where a node is: at a point, or on a side of another node.
data Place = PlaceAt !Rational !Rational | PlaceBeside !Text !Text !(Maybe Rational)
  deriving stock (Eq, Show)

-- What a statement means, for comparing before and after: a node's options
-- (without the one that attaches it), name, place and content.
data Meaning
  = NodeMeaning ![Text] !(Maybe Text) !Place !Text
  | OtherMeaning !Text
  deriving stock (Eq, Show)

meaning :: Statement -> Meaning
meaning statement =
  case statement of
    NodeStatement options name x y body _ -> NodeMeaning (plainOptions options) name (PlaceAt x y) body
    AttachedStatement options name side target gap body _ -> NodeMeaning (plainOptions options) name (PlaceBeside side target gap) body
    OpaqueStatement raw -> OtherMeaning (Text.strip raw)

meanings :: [Statement] -> [Meaning]
meanings = filter (/= OtherMeaning "") . fmap meaning

-- An option that attaches its node: @below=of a@.
attaches :: Text -> Bool
attaches item = attachmentOf item /= Nothing

plainOptions :: Text -> [Text]
plainOptions = fmap Text.strip . filter (not . attaches) . optionItems

-- | Apply one edit to the named slide. Returns the successor document and the
-- id of a node the edit created.
editPicture
  :: DeckConfig
  -> Text
  -> PictureOp
  -> MarkdownDeckDocument
  -> Either PictureEditError (MarkdownDeckDocument, [Text])
editPicture config slide op document = do
  deck <- maybe (Left PictureNotReady) Right (Document.documentSemantic document)
  container <- maybe (Left PictureNotReady) Right (syntaxContainer (Document.documentSyntax document))
  entry <- slideEntryOf container deck slide
  -- names that are there to attach or draw to without being statements of the
  -- slide: its regions, and the named nodes of the picture files it includes
  let outside =
        slideRegions
          <> [ name
             | (_, body) <- slidePictureFences entry
             , statement <- readPicture body
             , Just (_, path) <- [catOf (statementText statement)]
             , Just text <- [configReadFile config path]
             , included <- readPicture text
             , Just name <- [nameOf included]
             ]
  let source = Document.documentSource document
      bytes = Source.snapshotBytes source
  (start, end, new, expected, created) <-
    case slidePictureFences entry of
      [] ->
        case op of
          _ | creates op -> do
            Change bodies wanted made <- change outside op [""]
            if Text.null (Text.strip (Text.concat bodies)) then Left (PictureItemMissing (targetOf op)) else Right ()
            let body = Text.concat bodies
                Span bodyStart _ = slideBodySpan entry
                kept = Text.dropWhileEnd isSpace (slideBodyText entry)
                tailText = Text.drop (Text.length kept) (slideBodyText entry)
                at = bodyStart + lengthWord8 kept
                opening = if Text.null kept then "\n" else "\n\n"
                closing = if "\n" `Text.isPrefixOf` tailText then "" else "\n"
            Right (at, at, opening <> "```slide\n" <> body <> "```" <> closing, wanted, made)
          _ -> Left (PictureItemMissing (targetOf op))
      fences@((firstBase, _) : _) -> do
        Change bodies' wanted made <- change outside op (fmap snd fences)
        -- One replacement over the blocks the edit touched: what lies between
        -- two blocks is carried over as it is, and the common start and end of
        -- old and new are left out, so the edit covers only what changed.
        let ends = [base + lengthWord8 body | (base, body) <- fences]
            between = [decoded (ByteString.take (next - end) (ByteString.drop end bytes)) | (end, (next, _)) <- zip ends (drop 1 fences)]
            decoded = Encoding.decodeUtf8Lenient
            weave blocks = Text.concat (concat (zipWith (\block gap -> [block, gap]) blocks (between <> [""])))
            (old, new) = (weave (fmap snd fences), weave bodies')
            (same, oldRest, newRest) = maybe ("", old, new) id (Text.commonPrefixes old new)
            suffix = commonSuffix oldRest newRest
            oldMiddle = Text.dropEnd (Text.length suffix) oldRest
            newMiddle = Text.dropEnd (Text.length suffix) newRest
            at = firstBase + lengthWord8 same
        Right (at, at + lengthWord8 oldMiddle, newMiddle, wanted, made)
  target <- maybe (Left PictureSourceRejected) Right (Source.sourceSpanFromInts start end)
  let old = ByteString.take (end - start) (ByteString.drop start bytes)
      replacement = Source.mkExactReplacement (Source.snapshotRevision source) target old (Encoding.encodeUtf8 new)
  successorSource <- either (const (Left PictureSourceRejected)) Right (Source.applyExactReplacement replacement source)
  let successor = analyzeMarkdownDeckWith config successorSource
      verified = do
        deck' <- Document.documentSemantic successor
        container' <- syntaxContainer (Document.documentSyntax successor)
        entry' <- either (const Nothing) Just (slideEntryOf container' deck' slide)
        case slidePictureFences entry' of
          fences'@(_ : _) | fmap deckSlideId (deckSlides deck') == fmap deckSlideId (deckSlides deck) -> Just (meanings (concatMap (readPicture . snd) fences'))
          _ -> Nothing
  if verified == Just expected then Right (successor, created) else Left PictureVerificationRejected

targetOf :: PictureOp -> Text
targetOf op =
  case op of
    AddNode {} -> "node"
    MoveNode node _ _ -> "node " <> node
    AttachNode node _ _ _ -> "node " <> node
    SetNodeText node _ -> "node " <> node
    SetOptions item _ -> item
    ConnectNodes from _ -> "node " <> from
    DeleteItem item _ -> item
    AddInclude path _ _ -> path
    MoveInclude item _ _ -> item
    DeleteItems items _ -> Text.intercalate ", " items
    Reorder node _ -> "node " <> node
    PasteStatements {} -> "node"
    Batch ops -> maybe "node" targetOf (case ops of first : _ -> Just first; [] -> Nothing)
    SetRoute line _ _ -> line
    SetLineLabel line _ _ -> line
    SetLabelOptions line _ _ -> line
    AddLinePoint line _ _ _ -> line
    MoveLinePoint line _ _ _ -> line
    RemoveLinePoint line _ -> line

-- Whether an edit can start a picture on a slide that has none.
creates :: PictureOp -> Bool
creates op =
  case op of
    AddNode {} -> True
    PasteStatements {} -> True
    Batch (first : _) -> creates first
    _ -> False

-- The new text of each block, the meanings they must read back as, and a
-- created node id.
data Change = Change ![Text] ![Meaning] ![Text]

-- A node statement found by id: its number, the offsets of its parts, itself.
type Found = (Int, NodeSpans, Statement)

-- An edit over the slide's picture blocks. Statements are numbered across
-- the blocks in order; a new statement goes into the last block.
change :: [Text] -> PictureOp -> [Text] -> Either PictureEditError Change
change outside op bodies =
  case op of
    AddInclude path x y ->
      let line = includeText "" "" path (rounded x) (rounded y) ";"
       in Right (Change (appendTo (rebuiltList []) line) (meanings statements <> [OtherMeaning line]) [])
    MoveInclude item x y -> do
      (n, (lead, options, path, after)) <- includeNamed item
      let line = includeText lead options path (rounded x) (rounded y) after
      Right (Change (rebuilt [(n, line)]) (expecting [(n, const (OpaqueStatement line))]) [])
    AddNode options x y text ->
      let name = freshName (usedNames statements)
          (x', y') = (rounded x, rounded y)
          statement =
            "\\node"
              <> (if Text.null (Text.strip options) then "" else "[" <> Text.strip options <> "]")
              <> " (" <> name <> ") at " <> pointText x' y' <> " {" <> text <> "};"
       in Right (Change (appendTo (rebuiltList []) statement) (meanings statements <> [NodeMeaning (plainOptions options) (Just name) (PlaceAt x' y') text]) [name])
    MoveNode node x y -> do
      found@(index, _, _) <- nodeNamed node
      let (x', y') = (rounded x, rounded y)
      Right (Change (rebuilt [(index, placedAt found x' y')]) (expecting [(index, setPlace (PlaceAt x' y'))]) [])
    AttachNode node side target gap -> do
      (index, spans, statement) <- nodeNamed node
      if side `elem` attachSides then Right () else Left (PictureNotEditable "a node attaches above, below, left or right of another, or on a diagonal")
      -- the slide's own title and body are there to attach to without being statements
      (targetIndex, targetName, targetRaw) <-
        case nodeNamed target of
          Right (i, targetSpans, targetStatement) ->
            let (name, raw, _) = named (usedNames statements) targetSpans targetStatement in Right (i, name, raw)
          Left missing
            | target `elem` outside -> Right (0, target, "")
            | otherwise -> Left missing
      if index == targetIndex || node `elem` chainFrom target then Left (PictureNotEditable "these nodes would be attached to each other in a circle") else Right ()
      let gap' = rounded <$> gap
          option = side <> "=" <> maybe "" (\d -> number d <> " ") gap' <> "of " <> targetName
          items = optionItems (optionsOf statement)
          options'
            | any attaches items = Text.intercalate "," [if attaches item then Text.takeWhile isSpace item <> option else item | item <- items]
            | null items = option
            | otherwise = Text.dropWhileEnd isSpace (optionsOf statement) <> ", " <> option
          raw = spliceAll ([setOptions spans options'] <> maybe [] (\(a, b) -> [(a, b, "")]) (spansAt spans)) (statementText statement)
      Right (Change (rebuilt ([(index, raw)] <> [(targetIndex, targetRaw) | targetIndex > 0])) (expecting ([(index, setPlace (PlaceBeside side targetName gap'))] <> [(targetIndex, setName targetName) | targetIndex > 0])) [])
    SetNodeText node text -> do
      (index, spans, statement) <- nodeNamed node
      let raw = splice (spansContent spans) text (statementText statement)
      Right (Change (rebuilt [(index, raw)]) (expecting [(index, setContent text)]) [])
    SetOptions item changes -> do
      if all sound changes then Right () else Left (PictureNotEditable "an option cannot hold brackets, a semicolon or a line break")
      case Text.stripPrefix "line-" item >>= readIndex of
        Just n ->
          case [(raw, spans) | (i, OpaqueStatement raw) <- numbered, i == n, Just _ <- [parseDraw raw], Just spans <- [drawSpans raw]] of
            (raw, (insertAt, range)) : _ ->
              let options' = applyOptions changes (maybe "" (\(a, b) -> Text.take (b - a) (Text.drop a raw)) range)
                  raw' = spliceAll [optionsEdit insertAt range options'] raw
               in Right (Change (rebuilt [(n, raw')]) (expecting [(n, const (OpaqueStatement raw'))]) [])
            [] -> Left (PictureItemMissing "line")
        Nothing -> do
          (index, spans, statement) <- nodeNamed item
          -- the option that attaches a node is placement, not looks: it is not touched here
          if any (\c -> attaches (changeKey c <> "=of x")) changes then Left (PictureNotEditable "attach a node by dropping it beside another") else Right ()
          let options' = applyOptions changes (optionsOf statement)
              raw = spliceAll [setOptions spans options'] (statementText statement)
          Right (Change (rebuilt [(index, raw)]) (expecting [(index, setOptionsOf options')]) [])
    SetRoute item route angle -> do
      (n, path) <- lineNamed item
      let bent this other old =
            let before = case old of JoinTo options -> options; _ -> ""
                kept = case [v | (k, Just v) <- optionPairs before, k == this || k == other] of v : _ -> Just (Text.strip v); [] -> Nothing
             in JoinTo (applyOptions [RemoveOption other, SetOption this (maybe kept (Just . number . rounded) angle)] before)
      join <- case route of
        "straight" -> Right (const JoinStraight)
        "hv" -> Right (const JoinHV)
        "vh" -> Right (const JoinVH)
        "bend left" -> Right (bent "bend left" "bend right")
        "bend right" -> Right (bent "bend right" "bend left")
        _ -> Left (PictureNotEditable "a line goes straight, at a right angle, or bends left or right")
      relined n path {drawSteps = [step {stepJoin = join (stepJoin step)} | step <- drawSteps path]}
    SetLineLabel item index text -> do
      (n, path) <- lineNamed item
      let steps = drawSteps path
          blank = Text.null (Text.strip text)
      if index == 0
        then do
          if blank then Left (PictureNotEditable "a label needs some text") else Right ()
          let middle = length steps `div` 2
          relined n path {drawSteps = [if k == middle then step {stepLabels = stepLabels step <> [DrawLabel "auto" text]} else step | (k, step) <- zip [0 ..] steps]}
        else relabelled n path index (\label -> if blank then Nothing else Just label {drawLabelContent = text})
    SetLabelOptions item index changes -> do
      if all sound changes then Right () else Left (PictureNotEditable "an option cannot hold brackets, a semicolon or a line break")
      (n, path) <- lineNamed item
      relabelled n path index (\label -> Just label {drawLabelOptions = applyOptions changes (drawLabelOptions label)})
    AddLinePoint item at x y -> do
      (n, path) <- lineNamed item
      let steps = drawSteps path
      if at < 1 || at > length steps then Left (PictureItemMissing "line step") else Right ()
      let split step =
            [ step {stepPoint = DrawAt (rounded x) (rounded y), stepAfter = []}
            , DrawStep (case stepJoin step of bend@(JoinTo _) -> bend; _ -> JoinStraight) [] (stepPoint step) (stepAfter step)
            ]
      relined n path {drawSteps = concat [if k == at then split step else [step] | (k, step) <- zip [1 ..] steps]}
    MoveLinePoint item at x y -> do
      (n, path) <- lineNamed item
      let points = drawStart path : fmap stepPoint (drawSteps path)
      case drop at points of
        DrawAt _ _ : _ | at >= 0 ->
          let to = DrawAt (rounded x) (rounded y)
           in relined n (if at == 0 then path {drawStart = to} else path {drawSteps = [if k == at then step {stepPoint = to} else step | (k, step) <- zip [1 ..] (drawSteps path)]})
        _ : _ | at >= 0 -> Left (PictureNotEditable "this end follows its node")
        _ -> Left (PictureItemMissing "line point")
    RemoveLinePoint item at -> do
      (n, path) <- lineNamed item
      let steps = drawSteps path
      case (drop (at - 1) steps, at >= 1 && at < length steps) of
        (first@DrawStep {stepPoint = DrawAt _ _} : second : later, True) ->
          relined n path {drawSteps = take (at - 1) steps <> [DrawStep (stepJoin first) (stepLabels first <> stepAfter first <> stepLabels second) (stepPoint second) (stepAfter second)] <> later}
        _ -> Left (PictureNotEditable "only a point between the ends can be taken out")
    ConnectNodes from to -> do
      -- an end may be a node of an included picture, known here only by its name
      let end used name =
            case nodeNamed name of
              Right (i, spans, statement) -> let (written, raw, used') = named used spans statement in Right (i, written, [(i, raw)], used')
              Left missing
                | name `elem` outside -> Right (0, name, [], used)
                | otherwise -> Left missing
      (fromIndex, fromName, fromEdit, used) <- end (usedNames statements) from
      (toIndex, toName, toEdit, _) <- end used to
      if from == to || (fromIndex > 0 && fromIndex == toIndex) then Left (PictureNotEditable "an arrow needs two different nodes") else Right ()
      let line = "\\draw[->] (" <> fromName <> ") -- (" <> toName <> ");"
      Right (Change (appendTo (rebuiltList (fromEdit <> toEdit)) line) (expecting ([(fromIndex, setName fromName) | fromIndex > 0] <> [(toIndex, setName toName) | toIndex > 0]) <> [OtherMeaning line]) [])
    DeleteItem item pins -> change outside (DeleteItems [item] pins) bodies
    DeleteItems items pins -> do
      found <- traverse removed items
      let direct = fmap fst found
          gone = [name | (_, Just name) <- found]
          lines' = [i | (i, OpaqueStatement raw) <- numbered, Just (_, ends) <- [parseDraw raw], any (\name -> EndpointNode name `elem` ends) gone]
          followers = [(i, s) | (i, s@AttachedStatement {attachedTarget = target}) <- numbered, target `elem` gone, i `notElem` direct]
      -- each node attached to a removed one is put at its given point
      kept <- traverse (\(i, s) -> maybe (Left (PictureNotEditable "a node attached to this one has no place to stay")) (\(x, y) -> (\node -> (i, node, rounded x, rounded y)) <$> nodeNamed (nodeIdOf i s)) (lookup (nodeIdOf i s) [(n, (x, y)) | (n, x, y) <- pins])) followers
      Right (removing (nub (direct <> lines')) [(i, placedAt node x y, setPlace (PlaceAt x y)) | (i, node, x, y) <- kept])
    Reorder node layer -> do
      (index, _, _) <- nodeNamed node
      let slots = [i | (i, s) <- numbered, isNode s]
          (below, above) = (takeWhile (/= index) slots, drop 1 (dropWhile (/= index) slots))
          destination = case layer of
            ToFront -> lastOr index above
            ToBack -> headOr index below
            Forward -> headOr index above
            Backward -> lastOr index below
          count = length numbered
          order
            | destination > index = [1 .. index - 1] <> [index + 1 .. destination] <> [index] <> [destination + 1 .. count]
            | otherwise = [1 .. destination - 1] <> [index] <> [destination .. index - 1] <> [index + 1 .. count]
          -- the statements change places; the blank space in front of each place stays
          lead i = Text.takeWhile isSpace (textAt i)
          core i = Text.dropWhile isSpace (textAt i)
          textAt i = maybe "" statementText (lookup i numbered)
          moved = [(slot, s) | (slot, from) <- zip [1 :: Int ..] order, Just s <- [lookup from numbered]]
      if destination == index then Left (PictureNotEditable (if layer `elem` [ToFront, Forward] then "it is already in front" else "it is already at the back")) else Right ()
      Right
        ( Change
            (fmap Text.concat (perBlock [(slot, lead slot <> core from) | (slot, from) <- zip [1 :: Int ..] order]))
            (meanings (fmap snd moved))
            [nodeIdOf slot s | (slot, s) <- moved, slot == destination]
        )
    PasteStatements text dx dy -> do
      let incoming = readPicture text
          -- every copied node gets a name of its own; a copied name maps to the new one
          (_, renamed) = foldl (\(used, acc) s -> let name = freshName used in (name : used, acc <> [(s, name)])) (usedNames statements, []) (filter isNode incoming)
          names = [(old, new) | (s, new) <- renamed, Just old <- [nameOf s]]
          here = usedNames statements <> outside
          moved v d = rounded (v + d)
          bracket options = if Text.null (Text.strip options) then "" else "[" <> options <> "]"
          copy s =
            case s of
              NodeStatement options _ x y body _ -> do
                new <- newName s
                let (x', y') = (moved x dx, moved y dy)
                Right [("\\node" <> bracket (Text.strip options) <> " (" <> new <> ") at " <> pointText x' y' <> " {" <> body <> "};", NodeMeaning (plainOptions options) (Just new) (PlaceAt x' y') body)]
              AttachedStatement options _ side target gap body _ -> do
                new <- newName s
                let target' = maybe target id (lookup target names)
                    gap' = rounded <$> gap
                    option = side <> "=" <> maybe "" (\d -> number d <> " ") gap' <> "of " <> target'
                    options' = Text.strip (Text.intercalate "," [if attaches item then Text.takeWhile isSpace item <> option else item | item <- optionItems options])
                if target' `elem` (fmap snd names <> here) then Right () else Left (PictureNotEditable ("a copied node is attached to " <> target <> ", which is not on this slide"))
                Right [("\\node" <> bracket options' <> " (" <> new <> ") {" <> body <> "};", NodeMeaning (plainOptions options') (Just new) (PlaceBeside side target' gap') body)]
              OpaqueStatement raw
                | Just path <- readDraw raw
                , Just start' : steps' <- fmap end (drawStart path : fmap stepPoint (drawSteps path))
                , Just points' <- sequence steps' ->
                    let line = printDraw path {drawLead = "", drawTail = "", drawStart = start', drawSteps = [step {stepPoint = point'} | (step, point') <- zip (drawSteps path) points']}
                     in Right [(line, OtherMeaning line)]
              _ -> Right []
          newName s = maybe (Left PictureSourceRejected) Right (lookup (statementText s) [(statementText n, new) | (n, new) <- renamed])
          -- a line is copied when every node it joins is copied too
          end point = case point of
            DrawNode name anchor -> (\new -> DrawNode new anchor) <$> lookup name names
            DrawAt x y -> Just (DrawAt (moved x dx) (moved y dy))
      copies <- concat <$> traverse copy incoming
      if null copies then Left (PictureNotEditable "there is nothing to paste here") else Right ()
      Right (Change (appendTo (rebuiltList []) (Text.intercalate "\n" (fmap fst copies))) (meanings statements <> fmap snd copies) (fmap snd renamed))
    Batch ops -> foldM also (Change bodies (meanings statements) []) ops
      where
        -- each step reads what the one before wrote, and must itself read back as intended
        also (Change current _ made) one = do
          Change next wanted more <- change outside one current
          if meanings (concatMap readPicture next) == wanted then Right (Change next wanted (made <> more)) else Left PictureVerificationRejected
  where
    tagged = [(block, statement) | (block, body) <- zip [0 :: Int ..] bodies, statement <- readPicture body]
    statements = fmap snd tagged
    numbered = zip [1 :: Int ..] statements
    blockOf index = maybe 0 fst (lookup index (zip [1 :: Int ..] tagged))
    -- numbered pieces back into one list of pieces per block
    perBlock pieces = [[piece | (i, piece) <- pieces, blockOf i == block] | block <- [0 .. length bodies - 1]]
    headOr fallback list = case list of first : _ -> first; [] -> fallback
    lastOr fallback list = case reverse list of final : _ -> final; [] -> fallback
    -- what an id to delete is: its statement number, and its name when it is a node
    removed item
      | Right (n, _) <- includeNamed item = Right (n, Nothing)
      | Just n <- Text.stripPrefix "line-" item >>= readIndex =
          case [() | (i, OpaqueStatement raw) <- numbered, i == n, Just _ <- [parseDraw raw]] of
            [] -> Left (PictureItemMissing "line")
            _ -> Right (n, Nothing)
      | otherwise = (\(i, _, _) -> (i, Just item)) <$> nodeNamed item
    lineNamed item =
      case [(n, path) | Just n <- [Text.stripPrefix "line-" item >>= readIndex], (i, OpaqueStatement raw) <- numbered, i == n, Just path <- [readDraw raw]] of
        found : _ -> Right found
        [] -> Left (PictureItemMissing "line")
    -- a line written anew: it must read back as exactly the path meant
    relined n path =
      let raw = printDraw path
       in if readDraw raw == Just path then Right (Change (rebuilt [(n, raw)]) (expecting [(n, const (OpaqueStatement raw))]) []) else Left PictureSourceRejected
    -- change (or, with Nothing, remove) the label of that number, counted as written
    relabelled n path index alter =
      let visit count labels = foldl (\(seen, kept) label -> if seen + 1 == index then (seen + 1, kept <> maybe [] pure (alter label)) else (seen + 1, kept <> [label])) (count, []) labels
          (total, steps') =
            foldl
              ( \(count, done) step ->
                  let (afterBefore, before') = visit count (stepLabels step)
                      (afterAll, after') = visit afterBefore (stepAfter step)
                   in (afterAll, done <> [step {stepLabels = before', stepAfter = after'}])
              )
              (0 :: Int, [])
              (drawSteps path)
       in if index < 1 || index > total then Left (PictureItemMissing "label") else relined n path {drawSteps = steps'}
    includeNamed item =
      case [(n, parts) | Just n <- [Text.stripPrefix "cat-" item >>= readIndex], (i, OpaqueStatement raw) <- numbered, i == n, Just parts <- [catParts raw]] of
        found : _ -> Right found
        [] -> Left (PictureItemMissing "included picture")
    includeText lead options path x y after =
      let shift = if x == 0 && y == 0 then RemoveOption "shift" else SetOption "shift" (Just ("{" <> pointText x y <> "}"))
          options' = applyOptions [shift] options
       in lead <> "\\cat" <> (if Text.null (Text.strip options') then "" else "[" <> options' <> "]") <> "{" <> path <> "}" <> after
    nodeNamed :: Text -> Either PictureEditError Found
    nodeNamed node =
      case [(i, spans, s) | (i, s) <- numbered, isNode s, nodeIdOf i s == node, Just spans <- [nodeSpans (statementText s)]] of
        found : _ -> Right found
        [] -> Left (PictureItemMissing ("node " <> node))
    -- the ids a node is attached through, starting from one node
    chainFrom start = go [] start
      where
        go seen current
          | current `elem` seen = seen
          | otherwise =
              case [target | (i, s@AttachedStatement {attachedTarget = target}) <- numbered, nodeIdOf i s == current] of
                next : _ -> go (current : seen) next
                [] -> current : seen
    expecting updates = meanings [maybe s (\f -> f s) (lookup i updates) | (i, s) <- numbered]
    rebuiltList edits = [(i, maybe (statementText s) id (lookup i edits)) | (i, s) <- numbered]
    rebuilt = fmap Text.concat . perBlock . rebuiltList
    -- A new statement goes after the last finished one, on its own line, and
    -- the block keeps ending with a line break.
    appendTo numberedPieces statement =
      let blocks = perBlock numberedPieces
          (finished, trailing) = span (\p -> ";" `Text.isSuffixOf` p) (concat (drop (length blocks - 1) blocks))
          prefix = Text.concat finished
          rest = Text.concat trailing
          after = maybe rest id (Text.stripPrefix "\n" (Text.dropWhile (\c -> c == ' ' || c == '\t' || c == '\r') rest))
          closed = if Text.null after || "\n" `Text.isSuffixOf` after then after else after <> "\n"
       in fmap Text.concat (take (length blocks - 1) blocks) <> [prefix <> (if Text.null prefix || "\n" `Text.isSuffixOf` prefix then "" else "\n") <> statement <> "\n" <> closed]
    removing indexes replaced =
      let kept = [(i, s) | (i, s) <- numbered, i `notElem` indexes]
          texts = fmap Text.concat (perBlock [(i, maybe (statementText s) id (lookup i [(j, raw) | (j, raw, _) <- replaced])) | (i, s) <- kept])
          tidy text body = if "\n" `Text.isPrefixOf` text && not ("\n" `Text.isPrefixOf` body) then Text.drop 1 text else text
       in Change (zipWith tidy texts bodies) (meanings [maybe s (\f -> f s) (lookup i [(j, f) | (j, _, f) <- replaced]) | (i, s) <- kept]) []
    named used spans statement =
      case nameOf statement of
        Just name | validName name -> (name, statementText statement, used)
        _ ->
          let name = freshName used
           in (name, splice (spansNameInsert spans, spansNameInsert spans) (" (" <> name <> ")") (statementText statement), name : used)

changeKey :: OptionChange -> Text
changeKey one =
  case one of
    SetOption key _ -> key
    RemoveOption key -> key

-- A change that cannot break out of its option list.
sound :: OptionChange -> Bool
sound one =
  case one of
    RemoveOption key -> plain key
    SetOption key value -> plain key && maybe True plain value && not (Text.null (Text.strip key))
  where
    plain t = not (Text.any (`elem` ("[];\n\r{}" :: String)) t)

-- Where the options of a @\\draw@ statement sit: where a @[..]@ group would go,
-- and the options inside an existing one.
drawSpans :: Text -> Maybe (Int, Maybe (Int, Int))
drawSpans raw = do
  let offsetOf remaining = Text.length raw - Text.length remaining
      lead = Text.stripStart (dropComments (Text.stripStart raw))
      dropComments t = if "%" `Text.isPrefixOf` t then dropComments (Text.stripStart (Text.dropWhile (/= '\n') t)) else t
  afterDraw <- Text.stripPrefix "\\draw" lead
  case Text.uncons (Text.stripStart afterDraw) of
    Just ('[', rest) ->
      let (inside, _) = Text.break (== ']') rest
          start = offsetOf rest
       in Just (offsetOf afterDraw, Just (start, start + Text.length inside))
    _ -> Just (offsetOf afterDraw, Nothing)

-- The edit that makes an option group read as the given text.
optionsEdit :: Int -> Maybe (Int, Int) -> Text -> (Int, Int, Text)
optionsEdit insertAt range options =
  case range of
    Just (a, b)
      | Text.null (Text.strip options) -> (a - 1, b + 1, "")
      | otherwise -> (a, b, options)
    Nothing
      | Text.null (Text.strip options) -> (insertAt, insertAt, "")
      | otherwise -> (insertAt, insertAt, "[" <> options <> "]")

setOptionsOf :: Text -> Statement -> Statement
setOptionsOf options statement =
  case statement of
    NodeStatement _ name x y text raw -> NodeStatement options name x y text raw
    AttachedStatement _ name side target gap text raw -> AttachedStatement options name side target gap text raw
    other -> other

-- The raw text of a node statement put at a point: an absolute node gets the
-- new point; an attached one loses its attaching option and gains @at (x,y)@.
placedAt :: Found -> Rational -> Rational -> Text
placedAt (_, spans, statement) x y =
  case spansPoint spans of
    Just range -> splice range (pointText x y) raw
    Nothing ->
      let options' = Text.stripStart (Text.intercalate "," (filter (not . attaches) (optionItems (optionsOf statement))))
          open = spansContentOpen spans
          spaced = open > 0 && isSpace (Text.index raw (open - 1))
       in spliceAll [setOptions spans options', (open, open, (if spaced then "" else " ") <> "at " <> pointText x y <> " ")] raw
  where
    raw = statementText statement

pointText :: Rational -> Rational -> Text
pointText x y = "(" <> number x <> "," <> number y <> ")"

-- The edit that makes a node's options read as the given text; an empty text
-- removes the brackets, and a node without brackets gets them.
setOptions :: NodeSpans -> Text -> (Int, Int, Text)
setOptions spans options =
  case spansOptions spans of
    Just (a, b)
      | Text.null (Text.strip options) -> (a - 1, b + 1, "")
      | otherwise -> (a, b, options)
    Nothing
      | Text.null (Text.strip options) -> (spansOptionsInsert spans, spansOptionsInsert spans, "")
      | otherwise -> (spansOptionsInsert spans, spansOptionsInsert spans, "[" <> options <> "]")

isNode :: Statement -> Bool
isNode statement =
  case statement of
    OpaqueStatement _ -> False
    _ -> True

optionsOf :: Statement -> Text
optionsOf statement =
  case statement of
    NodeStatement options _ _ _ _ _ -> options
    AttachedStatement options _ _ _ _ _ _ -> options
    OpaqueStatement _ -> ""

nameOf :: Statement -> Maybe Text
nameOf statement =
  case statement of
    NodeStatement _ name _ _ _ _ -> name
    AttachedStatement _ name _ _ _ _ _ -> name
    OpaqueStatement _ -> Nothing

-- Intended changes of meaning, on the read statement.
setName :: Text -> Statement -> Statement
setName name statement =
  case statement of
    NodeStatement options _ x y text raw -> NodeStatement options (Just name) x y text raw
    AttachedStatement options _ side target gap text raw -> AttachedStatement options (Just name) side target gap text raw
    other -> other

setContent :: Text -> Statement -> Statement
setContent text statement =
  case statement of
    NodeStatement options name x y _ raw -> NodeStatement options name x y text raw
    AttachedStatement options name side target gap _ raw -> AttachedStatement options name side target gap text raw
    other -> other

setPlace :: Place -> Statement -> Statement
setPlace place statement =
  case (place, statement) of
    (PlaceAt x y, NodeStatement options name _ _ text raw) -> NodeStatement options name x y text raw
    (PlaceAt x y, AttachedStatement options name _ _ _ text raw) -> NodeStatement options name x y text raw
    (PlaceBeside side target gap, NodeStatement options name _ _ text raw) -> AttachedStatement options name side target gap text raw
    (PlaceBeside side target gap, AttachedStatement options name _ _ _ text raw) -> AttachedStatement options name side target gap text raw
    (_, other) -> other

-- | Names a picture can attach to that the slide itself provides.
slideRegions :: [Text]
slideRegions = ["title", "body"]

nodeIdOf :: Int -> Statement -> Text
nodeIdOf index statement =
  case nameOf statement of
    Just name | validName name -> name
    _ -> "picture-" <> Text.pack (show index)

validName :: Text -> Bool
validName name = not (Text.null name) && Text.all (\c -> isAlphaNum c || c == '-' || c == '_') name

usedNames :: [Statement] -> [Text]
usedNames statements = [name | Just name <- fmap nameOf statements]

freshName :: [Text] -> Text
freshName used =
  case [candidate | k <- [1 :: Int ..], let candidate = "n" <> Text.pack (show k), candidate `notElem` used] of
    name : _ -> name
    [] -> "n"

readIndex :: Text -> Maybe Int
readIndex text
  | not (Text.null text) && Text.all (\c -> c >= '0' && c <= '9') text = Just (Text.foldl' (\acc c -> acc * 10 + (fromEnum c - fromEnum '0')) 0 text)
  | otherwise = Nothing

splice :: (Int, Int) -> Text -> Text -> Text
splice (from, to) new text = Text.take from text <> new <> Text.drop to text

-- Several replacements at once, given by their offsets in the original text.
-- Applied from the end backwards; at one offset a removal goes before an
-- insertion, so the inserted text stays in front of what followed.
spliceAll :: [(Int, Int, Text)] -> Text -> Text
spliceAll edits text = foldl (\acc (from, to, new) -> splice (from, to) new acc) text (sortOn (\(from, to, _) -> (negate from, negate to)) edits)

commonSuffix :: Text -> Text -> Text
commonSuffix a b = Text.reverse (maybe "" (\(same, _, _) -> same) (Text.commonPrefixes (Text.reverse a) (Text.reverse b)))

-- Two decimals at most, as written.
rounded :: Rational -> Rational
rounded value = (round (value * 100) :: Integer) % 100

number :: Rational -> Text
number value =
  let hundredths = round (value * 100) :: Integer
      (whole, fraction) = abs hundredths `divMod` 100
      sign = if hundredths < 0 then "-" else ""
      digits
        | fraction == 0 = ""
        | fraction `mod` 10 == 0 = "." <> Text.pack (show (fraction `div` 10))
        | fraction < 10 = ".0" <> Text.pack (show fraction)
        | otherwise = "." <> Text.pack (show fraction)
   in sign <> Text.pack (show whole) <> digits

-- The container entry of a slide the deck itself wrote (not the generated
-- title slide or a divider).
slideEntryOf :: Container -> MarkdownDeck -> Text -> Either PictureEditError SlideEntry
slideEntryOf container deck slide =
  case lookup slide (zip [deckSlideId s | s <- deckSlides deck, not (deckSlideIsTitle s)] (containerSlides container)) of
    Just entry -> Right entry
    Nothing -> Left (PictureSlideMissing slide)
