{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Deck
-- Description : Lossless bounded parser and verified edits for the STR-007 trial.
--
-- This portable package owns the provisional @.slide@ parent CST. Authored bytes
-- remain authoritative: syntax values contain only half-open parent spans and
-- semantic projection never prints the deck. Each audience body is admitted as
-- one implicit, bounded TikZ canvas. Unsupported statements and options remain
-- in the parent bytes and are read-only. The trial intentionally does not
-- support embedding a literal triple-quote sequence in a raw body.
module SlideBlaster.Deck
  ( DeckSyntax
  , DeckFieldKey (..)
  , DeckDocument
  , DeckEditError (..)
  , SlideSyntax
  , NoteSyntax
  , analyzeDeck
  , applyDeckCanvasEdit
  , writableNodePlacement
  , insertSlideAfter
  , deckSlides
  , slideFrameId
  , slideTitle
  , slideBodySpan
  , slideWholeSpan
  , slideNote
  , noteBodySpan
  , noteWholeSpan
  , bytesAtSpan
  ) where

import SlideBlaster.Canvas qualified as Canvas
import SlideBlaster.Document qualified as Document
import SlideBlaster.Presentation qualified as Presentation
import SlideBlaster.Source qualified as Source

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (chr, ord)
import Data.List (find, nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (mapMaybe)
import Data.Ratio (denominator, numerator, (%))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Word (Word8)

-- | Recoverable parent syntax. A failed parse retains the whole source span and
-- no partially admitted slides; a successful parse retains every structural
-- span while exact output remains 'Document.documentSource'.
data DeckSyntax = DeckSyntax
  { syntaxWholeSpan :: !(Maybe Source.SourceSpan)
  , syntaxDeckMetadataSpan :: !(Maybe Source.SourceSpan)
  , syntaxSlides :: ![SlideSyntax]
  }
  deriving stock (Eq, Show)

-- | One admitted slide header/body and its optional immediately associated note.
data SlideSyntax = SlideSyntax
  { slideFrameId :: !Presentation.FrameId
  , slideTitle :: !Text
  , slideIdentifierSpan :: !Source.SourceSpan
  , slideMetadataSpan :: !Source.SourceSpan
  , slideBodyDelimiterSpans :: !(Source.SourceSpan, Source.SourceSpan)
  , slideBodySpan :: !Source.SourceSpan
  , slideWholeSpan :: !Source.SourceSpan
  , slideNote :: !(Maybe NoteSyntax)
  , slideNodes :: ![NodeSyntax]
  , slideConnectors :: ![ConnectorSyntax]
  }
  deriving stock (Eq, Show)

-- | Exact note delimiters/body. Notes are retained and represented as a
-- separate empty semantic surface in this P0 trial; they are not editable.
data NoteSyntax = NoteSyntax
  { noteBodySpan :: !Source.SourceSpan
  , noteWholeSpan :: !Source.SourceSpan
  }
  deriving stock (Eq, Show)

-- | Parent-addressed writable fields.
data DeckFieldKey
  = DeckAudienceX !Presentation.FrameId !Canvas.NodeId
  | DeckAudienceY !Presentation.FrameId !Canvas.NodeId
  deriving stock (Eq, Ord, Show)

type DeckDocument =
  Document.DocumentSnapshot DeckSyntax DeckFieldKey Presentation.Presentation

data NodeSyntax = NodeSyntax
  { nodeSyntaxId :: !Canvas.NodeId
  , nodeSyntaxPoint :: !Canvas.Point
  , nodeSyntaxPort :: !Canvas.BorderPort
  , nodeSyntaxXSpan :: !Source.SourceSpan
  , nodeSyntaxYSpan :: !Source.SourceSpan
  , nodeSyntaxWritable :: !Bool
  , nodeSyntaxContent :: !Text
  }
  deriving stock (Eq, Show)

data DeckEditError
  = DeckNotReady
  | DeckStaleRevision !Source.Revision !Source.Revision
  | DeckActiveSlideMissing !Presentation.FrameId
  | DeckTargetMissing !Canvas.ElementId
  | DeckPlacementUnsupported !Canvas.Placement
  | DeckProjectionRejected
  | DeckSourceRejected !Source.ExactReplacementError
  | DeckVerificationRejected
  deriving stock (Eq, Show)

data ConnectorSyntax = ConnectorSyntax
  { connectorSyntaxId :: !Canvas.ConnectorId
  , connectorSyntaxStart :: !Canvas.NodeId
  , connectorSyntaxStartPort :: !Canvas.BorderPort
  , connectorSyntaxEnd :: !Canvas.NodeId
  , connectorSyntaxEndPort :: !Canvas.BorderPort
  }
  deriving stock (Eq, Show)

data ParseFailure = ParseFailure !Text !Int !Int

data Cursor = Cursor !ByteString !Int

data ParsedSlide = ParsedSlide !SlideSyntax !Int

data ParsedNode = ParsedNode !NodeSyntax !Int

-- | Analyze one exact parent snapshot. Structural or child ambiguity is
-- atomic: the result is syntax-only and retains every authoritative byte.
analyzeDeck :: Source.SourceBufferSnapshot -> DeckDocument
analyzeDeck source =
  case wholeSourceSpan source of
    Nothing -> syntaxFailure source Nothing "deck.source_span" 0 0
    Just whole ->
      case parseDeck source whole of
        Left (ParseFailure message start end) ->
          syntaxFailure source (Just whole) message start end
        Right syntax ->
          case deckPresentation syntax of
            Left message -> syntaxFailureWithSyntax source syntax message
            Right presentation ->
              Document.readyDocument
                source
                syntax
                presentation
                (deckProvenance syntax)
                []

-- | Return admitted slides in source order.
deckSlides :: DeckSyntax -> [SlideSyntax]
deckSlides = syntaxSlides

-- | Return the retained authored placement only when the node has a direct,
-- literal coordinate inverse. Relative or otherwise expanded options remain
-- admitted read-only and never receive drag authority.
writableNodePlacement
  :: Presentation.FrameId
  -> Canvas.NodeId
  -> DeckDocument
  -> Maybe Canvas.Placement
writableNodePlacement frame identity document = do
  _ <- Document.documentSemantic document
  slide <- find ((== frame) . slideFrameId) (syntaxSlides (Document.documentSyntax document))
  node <- find ((== identity) . nodeSyntaxId) (slideNodes slide)
  if nodeSyntaxWritable node
    then Just (Canvas.AbsolutePlacement (nodeSyntaxPoint node) (nodeSyntaxPort node))
    else Nothing

-- | Apply a direct-coordinate node move by replacing only the two coordinate
-- lexemes in the selected child body, then fully reparsing the parent and child
-- and checking the exact retained anchor semantic destination.
applyDeckCanvasEdit
  :: Presentation.FrameId
  -> Canvas.EditIntent
  -> DeckDocument
  -> Either DeckEditError DeckDocument
applyDeckCanvasEdit active operation document = do
  _ <- maybe (Left DeckNotReady) Right (Document.documentSemantic document)
  slide <- findSlide active (Document.documentSyntax document)
  case operation of
    Canvas.MoveElement element placement ->
      case (element, placement) of
        (Canvas.NodeElement identity, Canvas.AbsolutePlacement destination port) ->
          moveNode slide identity destination port
        (Canvas.NodeElement _, unsupported) -> Left (DeckPlacementUnsupported unsupported)
        _ -> Left (DeckTargetMissing element)
    _ -> Left DeckProjectionRejected
  where
    source = Document.documentSource document
    moveNode slide identity destination requestedPort = do
      node <-
        maybe
          (Left (DeckTargetMissing (Canvas.NodeElement identity)))
          Right
          (find ((== identity) . nodeSyntaxId) (slideNodes slide))
      if not (nodeSyntaxWritable node) || requestedPort /= nodeSyntaxPort node
        then Left (DeckPlacementUnsupported (Canvas.AbsolutePlacement destination requestedPort))
        else
          if nodeSyntaxPoint node == destination
            then Right document
            else do
              replacement <- coordinateReplacement source node destination
              successorSource <- mapLeft DeckSourceRejected (Source.applyExactReplacement replacement source)
              let successor = analyzeDeck successorSource
              _ <- maybe (Left DeckVerificationRejected) Right (Document.documentSemantic successor)
              successorSlide <- findSlide active (Document.documentSyntax successor)
              successorNode <-
                maybe
                  (Left DeckVerificationRejected)
                  Right
                  (find ((== identity) . nodeSyntaxId) (slideNodes successorSlide))
              if nodeSyntaxPoint successorNode == destination
                  && nodeSyntaxPort successorNode == requestedPort
                  && nodeSyntaxWritable successorNode
                  && parentIdentityExceptBody slide successorSlide
                then Right successor
                else Left DeckVerificationRejected

-- | Insert one deterministic minimal empty slide after the active slide. The
-- operation is one zero-width exact parent replacement and one full reparse.
insertSlideAfter
  :: Source.Revision
  -> Presentation.FrameId
  -> DeckDocument
  -> Either DeckEditError DeckDocument
insertSlideAfter expected active document = do
  _ <- maybe (Left DeckNotReady) Right (Document.documentSemantic document)
  let source = Document.documentSource document
  if expected /= Source.snapshotRevision source
    then Left (DeckStaleRevision expected (Source.snapshotRevision source))
    else do
      slide <- findSlide active (Document.documentSyntax document)
      insertion <- spanAt (insertionOffset slide)
      let generatedId = nextSlideId (syntaxSlides (Document.documentSyntax document))
          eol = inferredEol source (insertionOffset slide)
          bytes = eol <> eol <> "slide " <> encodeUtf8 generatedId <> " \"Untitled\" (" <> eol <> ") \"\"\"" <> eol <> eol <> "\"\"\"" <> eol
          replacement = Source.mkExactReplacement expected insertion ByteString.empty bytes
      successorSource <- mapLeft DeckSourceRejected (Source.applyExactReplacement replacement source)
      let successor = analyzeDeck successorSource
      presentation <- maybe (Left DeckVerificationRejected) Right (Document.documentSemantic successor)
      let frames = NonEmpty.toList (Presentation.presentationFrames presentation)
          expectedIndex = slideIndex active (syntaxSlides (Document.documentSyntax document)) + 1
      case drop expectedIndex frames of
        frame : _
          | Presentation.frameIdText (Presentation.frameId frame) == generatedId
              && Presentation.frameTitle frame == "Untitled" -> Right successor
        _ -> Left DeckVerificationRejected

parseDeck :: Source.SourceBufferSnapshot -> Source.SourceSpan -> Either ParseFailure DeckSyntax
parseDeck source whole = do
  let start = skipTrivia (Cursor bytes 0)
  afterDeck <- keyword "deck" start
  (_, afterTitle) <- optionalQuoted (skipTrivia afterDeck)
  (_, afterMetadata, metadataSpan) <- balanced 40 41 (skipTrivia afterTitle)
  parsed <- parseSlides (skipTrivia afterMetadata) []
  let slides = reverse parsed
  if null slides
    then failAt "deck.zero_slides" afterMetadata
    else do
      ensureEnd (skipTrivia (Cursor bytes (endOfSlides slides)))
      ensureUniqueFrames slides
      pure (DeckSyntax (Just whole) (Just metadataSpan) slides)
  where
    bytes = Source.snapshotBytes source
    parseSlides cursor accumulated
      | atEnd cursor = Right accumulated
      | hasPrefix "slide" cursor = do
          ParsedSlide rawSlide after <- parseSlide cursor
          slide <- parseSlidesWithBytes bytes rawSlide
          parseSlides (skipTrivia (setOffset after cursor)) (slide : accumulated)
      | hasPrefix "note" cursor = failAt "deck.orphan_note" cursor
      | otherwise = failAt "deck.trailing_source" cursor
    endOfSlides values =
      case reverse values of
        slide : _ -> spanEndInt (maybe (slideWholeSpan slide) noteWholeSpan (slideNote slide))
        [] -> 0

parseSlide :: Cursor -> Either ParseFailure ParsedSlide
parseSlide start = do
  afterKeyword <- keyword "slide" start
  (identityText, identitySpan, afterIdentity) <- identifier (skipTrivia afterKeyword)
  frame <- mapLeft (const (ParseFailure "deck.invalid_slide_id" (offset afterKeyword) (offset afterIdentity))) (Presentation.mkFrameId identityText)
  (title, afterTitle) <- quoted (skipTrivia afterIdentity)
  (_, afterMetadata, metadataSpan) <- balanced 40 41 (skipTrivia afterTitle)
  (body, openSpan, closeSpan, afterBody) <- rawBody (skipTrivia afterMetadata)
  let nodes = []
  let afterBodyTrivia = skipTrivia afterBody
  (noteValue, afterNote) <-
    if hasPrefix "note" afterBodyTrivia
      then do
        afterNoteKeyword <- keyword "note" afterBodyTrivia
        (noteSpanValue, _, _, noteEnd) <- rawBody (skipTrivia afterNoteKeyword)
        wholeNote <- makeSpan (offset afterBodyTrivia) (offset noteEnd)
        pure (Just (NoteSyntax noteSpanValue wholeNote), noteEnd)
      else pure (Nothing, afterBody)
  whole <- makeSpan (offset start) (offset afterBody)
  pure
    ( ParsedSlide
        SlideSyntax
          { slideFrameId = frame
          , slideTitle = title
          , slideIdentifierSpan = identitySpan
          , slideMetadataSpan = metadataSpan
          , slideBodyDelimiterSpans = (openSpan, closeSpan)
          , slideBodySpan = body
          , slideWholeSpan = whole
          , slideNote = noteValue
          , slideNodes = nodes
          , slideConnectors = []
          }
        (offset afterNote)
    )

parseCanvasBytes :: ByteString -> Source.SourceSpan -> Either ParseFailure ([NodeSyntax], [ConnectorSyntax])
parseCanvasBytes bytes body = do
  (nodes, connectors) <- go (skipTriviaBounded bytes (spanStartInt body) (spanEndInt body)) [] []
  let identities = fmap nodeSyntaxId nodes
      known = identities
      targets = foldMap (\connector -> [connectorSyntaxStart connector, connectorSyntaxEnd connector]) connectors
  if length identities /= length (nub identities)
    then Left (ParseFailure "deck.duplicate_node_id" (spanStartInt body) (spanEndInt body))
    else if any (`notElem` known) targets
      then Left (ParseFailure "deck.connector_target_missing" (spanStartInt body) (spanEndInt body))
      else Right (nodes, connectors)
  where
    go cursor accumulatedNodes accumulatedConnectors
      | cursor >= spanEndInt body = Right (reverse accumulatedNodes, reverse accumulatedConnectors)
      | "\\node" `ByteString.isPrefixOf` ByteString.drop cursor bytes = do
          ParsedNode node after <- parseNode bytes (spanEndInt body) cursor
          go (skipTriviaBounded bytes after (spanEndInt body)) (node : accumulatedNodes) accumulatedConnectors
      | "\\draw" `ByteString.isPrefixOf` ByteString.drop cursor bytes = do
          after <- statementEnd bytes (spanEndInt body) cursor
          connectors <- parseConnectors bytes cursor after
          go (skipTriviaBounded bytes after (spanEndInt body)) accumulatedNodes (reverse connectors <> accumulatedConnectors)
      | otherwise = do
          after <- statementEnd bytes (spanEndInt body) cursor
          go (skipTriviaBounded bytes after (spanEndInt body)) accumulatedNodes accumulatedConnectors

parseNode :: ByteString -> Int -> Int -> Either ParseFailure ParsedNode
parseNode bytes limit start = do
  let afterCommand = skipTriviaBounded bytes (start + 5) limit
  (options, afterOptions) <- optionalBalancedBytes bytes limit 91 93 afterCommand
  afterOpen <- expectByte bytes limit 40 (skipTriviaBounded bytes afterOptions limit) "deck.node_id_open"
  (identityText, _, afterIdentity) <- identifierAt bytes limit afterOpen
  identity <- maybe (Left (ParseFailure "deck.invalid_node_id" afterOpen afterIdentity)) Right (Canvas.nodeId identityText)
  afterClose <- expectByte bytes limit 41 afterIdentity "deck.node_id_close"
  afterAt <- expectAscii bytes limit "at" (skipTriviaBounded bytes afterClose limit) "deck.node_at"
  afterPointOpen <- expectByte bytes limit 40 (skipTriviaBounded bytes afterAt limit) "deck.node_point_open"
  (x, xSpan, afterX) <- coordinateAt bytes limit (skipTriviaBounded bytes afterPointOpen limit)
  afterComma <- expectByte bytes limit 44 (skipTriviaBounded bytes afterX limit) "deck.node_point_comma"
  (y, ySpan, afterY) <- coordinateAt bytes limit (skipTriviaBounded bytes afterComma limit)
  afterPointClose <- expectByte bytes limit 41 (skipTriviaBounded bytes afterY limit) "deck.node_point_close"
  contentOpen <- expectByte bytes limit 123 (skipTriviaBounded bytes afterPointClose limit) "deck.node_content_open"
  (contentSpan, afterContent) <- balancedAt bytes limit 123 125 (contentOpen - 1)
  semicolon <- expectByte bytes limit 59 (skipTriviaBounded bytes afterContent limit) "deck.node_semicolon"
  content <- decodeSpan bytes (innerSpan contentSpan)
  port <-
    maybe
      (Left (ParseFailure "deck.node_anchor_unsupported" afterCommand afterOptions))
      Right
      (optionPort options)
  let writable = not (hasRelativeOption options)
  pure
    ( ParsedNode
        ( NodeSyntax
            identity
            (Canvas.point (Canvas.canvasUnit x) (Canvas.canvasUnit y))
            port
            xSpan
            ySpan
            writable
            content
        )
        semicolon
    )

parseConnectors :: ByteString -> Int -> Int -> Either ParseFailure [ConnectorSyntax]
parseConnectors bytes start end =
  let statement = ByteString.take (end - start) (ByteString.drop start bytes)
   in if " to " `ByteString.isInfixOf` statement || not ("--" `ByteString.isInfixOf` statement)
        then Right []
        else
          case traverse endpointFromBytes (parenthesizedTokens statement) of
            Left _ -> Right []
            Right endpoints -> connectorsFromEndpoints start endpoints

connectorsFromEndpoints :: Int -> [(Canvas.NodeId, Canvas.BorderPort)] -> Either ParseFailure [ConnectorSyntax]
connectorsFromEndpoints statementStart endpoints = go (0 :: Int) endpoints
  where
    go _ [] = Right []
    go _ [_] = Right []
    go index (first : second : remaining) = do
      identity <-
        maybe
          (Left (ParseFailure "deck.connector_id" statementStart statementStart))
          Right
          (Canvas.connectorId ("path-" <> Text.pack (show statementStart) <> "-" <> Text.pack (show index)))
      let (startNode, startPort) = first
          (endNode, endPort) = second
          connector = ConnectorSyntax identity startNode startPort endNode endPort
      rest <- go (index + 1) (second : remaining)
      pure (connector : rest)

endpointFromBytes :: ByteString -> Either ParseFailure (Canvas.NodeId, Canvas.BorderPort)
endpointFromBytes raw =
  let text = Text.strip (Text.Encoding.decodeLatin1 raw)
      (name, suffix) = Text.breakOn "." text
   in case Canvas.nodeId name of
        Nothing -> Left (ParseFailure "deck.connector_endpoint" 0 0)
        Just identity -> Right (identity, endpointPort (Text.drop 1 suffix))

endpointPort :: Text -> Canvas.BorderPort
endpointPort value = case value of
  "north" -> Canvas.North
  "north east" -> Canvas.NorthEast
  "east" -> Canvas.East
  "south east" -> Canvas.SouthEast
  "south" -> Canvas.South
  "south west" -> Canvas.SouthWest
  "west" -> Canvas.West
  "north west" -> Canvas.NorthWest
  _ -> Canvas.Centre

parenthesizedTokens :: ByteString -> [ByteString]
parenthesizedTokens bytes = go 0
  where
    go index =
      case ByteString.elemIndex 40 (ByteString.drop index bytes) of
        Nothing -> []
        Just relativeOpen ->
          let open = index + relativeOpen
           in case ByteString.elemIndex 41 (ByteString.drop (open + 1) bytes) of
                Nothing -> []
                Just relativeClose ->
                  let close = open + 1 + relativeClose
                      token = ByteString.take (close - open - 1) (ByteString.drop (open + 1) bytes)
                   in token : go (close + 1)

-- parseSlide needs source bytes for child admission.
parseSlidesWithBytes :: ByteString -> SlideSyntax -> Either ParseFailure SlideSyntax
parseSlidesWithBytes bytes slide = do
  (nodes, connectors) <- parseCanvasBytes bytes (slideBodySpan slide)
  pure slide {slideNodes = nodes, slideConnectors = connectors}

-- Parent grammar helpers
rawBody :: Cursor -> Either ParseFailure (Source.SourceSpan, Source.SourceSpan, Source.SourceSpan, Cursor)
rawBody cursor = do
  afterOpen <- expect "\"\"\"" cursor
  openSpan <- makeSpan (offset cursor) (offset afterOpen)
  let remaining = ByteString.drop (offset afterOpen) (cursorBytes cursor)
  case ByteString.breakSubstring "\"\"\"" remaining of
    (_, suffix) | ByteString.null suffix -> failAt "deck.unclosed_raw_body" afterOpen
    (bodyBytes, _) -> do
      let bodyEnd = offset afterOpen + ByteString.length bodyBytes
          afterClose = setOffset (bodyEnd + 3) cursor
      bodySpan <- makeSpan (offset afterOpen) bodyEnd
      closeSpan <- makeSpan bodyEnd (bodyEnd + 3)
      pure (bodySpan, openSpan, closeSpan, afterClose)

balanced :: Word8 -> Word8 -> Cursor -> Either ParseFailure (Source.SourceSpan, Cursor, Source.SourceSpan)
balanced open close cursor = do
  end <- balancedEnd (cursorBytes cursor) (ByteString.length (cursorBytes cursor)) open close (offset cursor)
  spanValue <- makeSpan (offset cursor) end
  pure (spanValue, setOffset end cursor, spanValue)

balancedEnd :: ByteString -> Int -> Word8 -> Word8 -> Int -> Either ParseFailure Int
balancedEnd bytes limit open close start
  | start >= limit || ByteString.index bytes start /= open = Left (ParseFailure "deck.expected_balanced_open" start (min limit (start + 1)))
  | otherwise = go (start + 1) (1 :: Int) False False
  where
    go index depth quotedValue escaped
      | index >= limit = Left (ParseFailure "deck.unclosed_balanced" start limit)
      | quotedValue =
          let byte = ByteString.index bytes index
           in if escaped then go (index + 1) depth True False
              else if byte == 92 then go (index + 1) depth True True
              else if byte == 34 then go (index + 1) depth False False
              else go (index + 1) depth True False
      | otherwise =
          let byte = ByteString.index bytes index
           in if byte == 34 then go (index + 1) depth True False
              else if byte == open then go (index + 1) (depth + 1) False False
              else if byte == close && depth == 1 then Right (index + 1)
              else if byte == close then go (index + 1) (depth - 1) False False
              else go (index + 1) depth False False

quoted :: Cursor -> Either ParseFailure (Text, Cursor)
quoted cursor
  | peek cursor /= Just 34 = failAt "deck.expected_title" cursor
  | otherwise = go (offset cursor + 1) [] False
  where
    bytes = cursorBytes cursor
    go index characters escaped
      | index >= ByteString.length bytes = Left (ParseFailure "deck.unclosed_title" (offset cursor) index)
      | otherwise =
          let byte = ByteString.index bytes index
           in if escaped
                then case byte of
                  34 -> go (index + 1) ('"' : characters) False
                  92 -> go (index + 1) ('\\' : characters) False
                  _ -> Left (ParseFailure "deck.unsupported_title_escape" (index - 1) (index + 1))
                else if byte == 92 then go (index + 1) characters True
                else if byte == 34 then Right (Text.pack (reverse characters), setOffset (index + 1) cursor)
                else if byte < 32 then Left (ParseFailure "deck.control_in_title" index (index + 1))
                else case Text.Encoding.decodeUtf8' (ByteString.singleton byte) of
                  Right _ | byte < 128 -> go (index + 1) (chr (fromIntegral byte) : characters) False
                  _ -> decodeWhole index characters
    decodeWhole _ _ =
      let rest = ByteString.drop (offset cursor + 1) bytes
          (raw, suffix) = ByteString.break (== 34) rest
       in case (Text.Encoding.decodeUtf8' raw, ByteString.uncons suffix) of
            (Right text, Just _) -> Right (text, setOffset (offset cursor + 1 + ByteString.length raw + 1) cursor)
            _ -> Left (ParseFailure "deck.invalid_utf8_title" (offset cursor) (ByteString.length bytes))

optionalQuoted :: Cursor -> Either ParseFailure (Maybe Text, Cursor)
optionalQuoted cursor
  | peek cursor == Just 34 = do
      (value, next) <- quoted cursor
      pure (Just value, next)
  | otherwise = pure (Nothing, cursor)

identifier :: Cursor -> Either ParseFailure (Text, Source.SourceSpan, Cursor)
identifier cursor = identifierCursor cursor

identifierCursor :: Cursor -> Either ParseFailure (Text, Source.SourceSpan, Cursor)
identifierCursor cursor = do
  (value, spanValue, end) <- identifierAt (cursorBytes cursor) (ByteString.length (cursorBytes cursor)) (offset cursor)
  pure (value, spanValue, setOffset end cursor)

identifierAt :: ByteString -> Int -> Int -> Either ParseFailure (Text, Source.SourceSpan, Int)
identifierAt bytes limit start
  | start >= limit || not (identifierStart (ByteString.index bytes start)) = Left (ParseFailure "deck.invalid_identifier" start (min limit (start + 1)))
  | otherwise = do
      let end = advance bytes limit identifierContinue (start + 1)
      spanValue <- makeSpan start end
      text <- decodeSpan bytes spanValue
      pure (text, spanValue, end)

keyword :: ByteString -> Cursor -> Either ParseFailure Cursor
keyword value cursor = do
  after <- expect value cursor
  case peek after of
    Just byte | identifierContinue byte -> failAt "deck.keyword_boundary" after
    _ -> Right after

expect :: ByteString -> Cursor -> Either ParseFailure Cursor
expect value cursor
  | value `ByteString.isPrefixOf` ByteString.drop (offset cursor) (cursorBytes cursor) = Right (setOffset (offset cursor + ByteString.length value) cursor)
  | otherwise = failAt "deck.expected_token" cursor

ensureUniqueFrames :: [SlideSyntax] -> Either ParseFailure ()
ensureUniqueFrames slides =
  let ids = fmap slideFrameId slides
   in if length ids == length (nub ids)
        then Right ()
        else Left (ParseFailure "deck.duplicate_slide_id" 0 0)

ensureEnd :: Cursor -> Either ParseFailure ()
ensureEnd cursor
  | atEnd cursor = Right ()
  | otherwise = failAt "deck.trailing_source" cursor

-- Semantic admission
deckPresentation :: DeckSyntax -> Either Text Presentation.Presentation
deckPresentation syntax = do
  frames <- traverse slideFrame (syntaxSlides syntax)
  case frames of
    [] -> Left "deck.zero_slides"
    first : remaining ->
      mapLeft (const "deck.duplicate_slide_id")
        ( Presentation.mkPresentation
            (Presentation.mkPresentationMetadata "STR-007 trial" Presentation.defaultAspectRatio Canvas.defaultTheme Presentation.CompleteImmediately)
            (first :| remaining)
        )

slideFrame :: SlideSyntax -> Either Text Presentation.Frame
slideFrame slide = do
  connectorEntries <- traverse connectorEntry (slideConnectors slide)
  picture <- mapLeft (const "deck.duplicate_node_id") (Canvas.mkPicture (fmap nodeEntry (slideNodes slide) <> connectorEntries))
  scene <- mapLeft (const "deck.scene_invalid") (Presentation.mkScene picture Presentation.emptyAnimationTimeline)
  notes <- case slideNote slide of
    Nothing -> Right Nothing
    Just _ -> do
      noteScene <- mapLeft (const "deck.note_scene_invalid") (Presentation.mkScene Canvas.emptyPicture Presentation.emptyAnimationTimeline)
      Right (Just (Presentation.mkNotes noteScene))
  pure (Presentation.mkFrame (slideFrameId slide) (Presentation.mkFrameMetadata (slideTitle slide) Presentation.noSlideRotation) scene notes)

nodeEntry :: NodeSyntax -> Canvas.LayerEntry
nodeEntry node =
  Canvas.ObjectEntry
    ( Canvas.CanvasNode
        Canvas.Node
          { Canvas.nodeIdentifier = nodeSyntaxId node
          , Canvas.nodePlacement = Canvas.AbsolutePlacement (nodeSyntaxPoint node) (nodeSyntaxPort node)
          , Canvas.nodeOutline = Canvas.PrimitiveGeometry Canvas.RectangleOutline
          , Canvas.nodeContent = Canvas.content [Canvas.TextRun (Canvas.CanvasProvenance Canvas.LaTeX) (nodeSyntaxContent node)]
          , Canvas.nodePropertyOverrides = Canvas.emptyNodePropertyPatch
          , Canvas.nodeAnimationRefs = []
          , Canvas.nodeAccessibility = Canvas.DecorativeNode
          }
    )

deckProvenance :: DeckSyntax -> Document.ProvenanceMap DeckFieldKey
deckProvenance syntax =
  case Document.mkProjectionRule "deck.implicit-tikz.direct-coordinate" of
    Nothing -> Document.emptyProvenanceMap
    Just rule ->
      Document.provenanceFromList
        [ (field, if nodeSyntaxWritable node then Document.DirectSlot spanValue rule else Document.ReadOnly Document.MissingInverseRule (Just spanValue))
        | slide <- syntaxSlides syntax
        , node <- slideNodes slide
        , (field, spanValue) <-
            [ (DeckAudienceX (slideFrameId slide) (nodeSyntaxId node), nodeSyntaxXSpan node)
            , (DeckAudienceY (slideFrameId slide) (nodeSyntaxId node), nodeSyntaxYSpan node)
            ]
        ]

connectorEntry :: ConnectorSyntax -> Either Text Canvas.LayerEntry
connectorEntry connector = do
  path <-
    mapLeft (const "deck.connector_invalid")
      ( Canvas.mkConnectorPath
          ( Canvas.NodeAnchor (connectorSyntaxStart connector) (connectorSyntaxStartPort connector)
              :| [Canvas.NodeAnchor (connectorSyntaxEnd connector) (connectorSyntaxEndPort connector)]
          )
          [Canvas.StraightSegment]
          Canvas.OpenPath
      )
  pure
    ( Canvas.ObjectEntry
        ( Canvas.CanvasConnector
            Canvas.Connector
              { Canvas.connectorIdentifier = connectorSyntaxId connector
              , Canvas.connectorPath = path
              , Canvas.connectorLabel = Nothing
              , Canvas.connectorPropertyOverrides = Canvas.emptyConnectorPropertyPatch
              , Canvas.connectorAnimationRefs = []
              , Canvas.connectorAccessibility = Canvas.DecorativeNode
              }
        )
    )

-- Editing helpers
coordinateReplacement :: Source.SourceBufferSnapshot -> NodeSyntax -> Canvas.Point -> Either DeckEditError Source.ExactReplacement
coordinateReplacement source node destination = do
  let xValue = Canvas.canvasUnitValue (Canvas.pointX destination)
      yValue = Canvas.canvasUnitValue (Canvas.pointY destination)
  if not (terminatingDecimal xValue && terminatingDecimal yValue)
    then Left DeckProjectionRejected
    else pure ()
  combined <- maybe (Left DeckProjectionRejected) Right (Source.mkSourceSpan (Source.sourceSpanStart (nodeSyntaxXSpan node)) (Source.sourceSpanEnd (nodeSyntaxYSpan node)))
  let middle = bytesBetween source (Source.sourceSpanEnd (nodeSyntaxXSpan node)) (Source.sourceSpanStart (nodeSyntaxYSpan node))
      value = renderRational (Canvas.canvasUnitValue (Canvas.pointX destination)) <> middle <> renderRational (Canvas.canvasUnitValue (Canvas.pointY destination))
  pure (Source.mkExactReplacement (Source.snapshotRevision source) combined (bytesAtSpan source combined) value)

parentIdentityExceptBody :: SlideSyntax -> SlideSyntax -> Bool
parentIdentityExceptBody before after =
  slideFrameId before == slideFrameId after
    && slideTitle before == slideTitle after
    && isJustEq (slideNote before) (slideNote after)
  where
    isJustEq Nothing Nothing = True
    isJustEq (Just _) (Just _) = True
    isJustEq _ _ = False

findSlide :: Presentation.FrameId -> DeckSyntax -> Either DeckEditError SlideSyntax
findSlide identity syntax = maybe (Left (DeckActiveSlideMissing identity)) Right (find ((== identity) . slideFrameId) (syntaxSlides syntax))

nextSlideId :: [SlideSyntax] -> Text
nextSlideId slides = go (length slides + 1)
  where
    used = fmap (Presentation.frameIdText . slideFrameId) slides
    go number =
      let candidate = "slide-" <> Text.pack (show number)
       in if candidate `elem` used then go (number + 1) else candidate

slideIndex :: Presentation.FrameId -> [SlideSyntax] -> Int
slideIndex wanted = go 0
  where
    go index values = case values of
      [] -> index
      value : _ | slideFrameId value == wanted -> index
      _ : rest -> go (index + 1) rest

insertionOffset :: SlideSyntax -> Int
insertionOffset slide = spanEndInt (maybe (slideWholeSpan slide) noteWholeSpan (slideNote slide))

inferredEol :: Source.SourceBufferSnapshot -> Int -> ByteString
inferredEol source position =
  let prefix = ByteString.take position (Source.snapshotBytes source)
   in if "\r\n" `ByteString.isInfixOf` prefix then "\r\n" else "\n"

-- Generic byte helpers
syntaxFailure :: Source.SourceBufferSnapshot -> Maybe Source.SourceSpan -> Text -> Int -> Int -> DeckDocument
syntaxFailure source whole code start end = syntaxFailureWithSyntax source (DeckSyntax whole Nothing []) (diagnosticAt code start end)

syntaxFailureWithSyntax :: Source.SourceBufferSnapshot -> DeckSyntax -> Text -> DeckDocument
syntaxFailureWithSyntax source syntax code =
  Document.syntaxOnlyDocument source syntax (diagnostic code :| [])
  where
    diagnostic value =
      Document.mkDiagnostic Document.DiagnosticError (category value) (diagnosticCode value) "The provisional deck could not be admitted without ambiguity" (syntaxWholeSpan syntax)
    category value | "duplicate" `Text.isInfixOf` value = Document.MeaningAmbiguous
    category _ = Document.SyntaxMalformed

diagnosticAt :: Text -> Int -> Int -> Text
diagnosticAt code _ _ = code

diagnosticCode :: Text -> Document.DiagnosticCode
diagnosticCode value =
  case Document.mkDiagnosticCode value of
    Just result -> result
    Nothing -> case Document.mkDiagnosticCode "deck.invalid" of
      Just result -> result
      Nothing -> diagnosticCode "deck.invalid"

wholeSourceSpan :: Source.SourceBufferSnapshot -> Maybe Source.SourceSpan
wholeSourceSpan source = Source.sourceSpanFromInts 0 (ByteString.length (Source.snapshotBytes source))

bytesAtSpan :: Source.SourceBufferSnapshot -> Source.SourceSpan -> ByteString
bytesAtSpan source spanValue = ByteString.take (spanEndInt spanValue - spanStartInt spanValue) (ByteString.drop (spanStartInt spanValue) (Source.snapshotBytes source))

bytesBetween :: Source.SourceBufferSnapshot -> Source.ByteOffset -> Source.ByteOffset -> ByteString
bytesBetween source start end = ByteString.take (Source.unByteOffset end - Source.unByteOffset start) (ByteString.drop (Source.unByteOffset start) (Source.snapshotBytes source))

spanStartInt :: Source.SourceSpan -> Int
spanStartInt = Source.unByteOffset . Source.sourceSpanStart

spanEndInt :: Source.SourceSpan -> Int
spanEndInt = Source.unByteOffset . Source.sourceSpanEnd

makeSpan :: Int -> Int -> Either ParseFailure Source.SourceSpan
makeSpan start end = maybe (Left (ParseFailure "deck.source_span" start end)) Right (Source.sourceSpanFromInts start end)

spanAt :: Int -> Either DeckEditError Source.SourceSpan
spanAt value = maybe (Left DeckProjectionRejected) Right (Source.sourceSpanFromInts value value)

innerSpan :: Source.SourceSpan -> Source.SourceSpan
innerSpan spanValue =
  case Source.sourceSpanFromInts (spanStartInt spanValue + 1) (spanEndInt spanValue - 1) of
    Just result -> result
    Nothing -> spanValue

renderRational :: Rational -> ByteString
renderRational value
  | denominator value == 1 = ascii (show (numerator value))
  | otherwise = renderTerminating value

renderTerminating :: Rational -> ByteString
renderTerminating value =
  let sign = if value < 0 then "-" else ""
      magnitude = abs value
      scale = decimalScale (denominator magnitude) 0
      scaled = numerator magnitude * (10 ^ scale) `div` denominator magnitude
      digits = show scaled
      padded = replicate (max 0 (scale + 1 - length digits)) '0' <> digits
      split = length padded - scale
   in if scale == 0
        then ascii (sign <> padded)
        else ascii (sign <> take split padded <> "." <> drop split padded)

decimalScale :: Integer -> Int -> Int
decimalScale denominatorValue count
  | denominatorValue == 1 = count
  | denominatorValue `mod` 2 == 0 = decimalScale (denominatorValue `div` 2) (count + 1)
  | denominatorValue `mod` 5 == 0 = decimalScale (denominatorValue `div` 5) (count + 1)
  | otherwise = count

terminatingDecimal :: Rational -> Bool
terminatingDecimal value = removeFactor 5 (removeFactor 2 (denominator value)) == 1
  where
    removeFactor factor current
      | current `mod` factor == 0 = removeFactor factor (current `div` factor)
      | otherwise = current

coordinateAt :: ByteString -> Int -> Int -> Either ParseFailure (Rational, Source.SourceSpan, Int)
coordinateAt bytes limit start = do
  let end = advance bytes limit (\byte -> not (byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 44 || byte == 41)) start
  spanValue <- makeSpan start end
  value <- maybe (Left (ParseFailure "deck.invalid_coordinate" start end)) Right (parseRationalBytes (ByteString.take (end - start) (ByteString.drop start bytes)))
  pure (value, spanValue, end)

parseRationalBytes :: ByteString -> Maybe Rational
parseRationalBytes bytes =
  case Text.splitOn "/" (Text.Encoding.decodeLatin1 bytes) of
    [top, bottom] -> do
      a <- signedInteger top
      b <- unsignedInteger bottom
      if b == 0 then Nothing else Just (a % b)
    [decimal] -> parseDecimal decimal
    _ -> Nothing

parseDecimal :: Text -> Maybe Rational
parseDecimal value =
  let (sign, unsigned) = case Text.stripPrefix "-" value of
        Just rest -> (-1, rest)
        Nothing -> case Text.stripPrefix "+" value of
          Just rest -> (1, rest)
          Nothing -> (1, value)
   in case Text.splitOn "." unsigned of
        [whole] -> (fromInteger . (sign *) <$> unsignedInteger whole)
        [whole, fraction] -> do
          a <- unsignedInteger whole
          b <- unsignedInteger fraction
          let scale = 10 ^ Text.length fraction
          pure ((sign * (a * scale + b)) % scale)
        _ -> Nothing

signedInteger :: Text -> Maybe Integer
signedInteger value = case Text.stripPrefix "-" value of
  Just rest -> negate <$> unsignedInteger rest
  Nothing -> unsignedInteger value

unsignedInteger :: Text -> Maybe Integer
unsignedInteger value
  | Text.null value || not (Text.all (\c -> c >= '0' && c <= '9') value) = Nothing
  | otherwise = Just (Text.foldl' (\total c -> total * 10 + toInteger (ord c - ord '0')) 0 value)

optionPort :: ByteString -> Maybe Canvas.BorderPort
optionPort options =
  case mapMaybe anchorValue (Text.splitOn "," optionText) of
    [] -> Just Canvas.Centre
    [value] -> portValue value
    _ -> Nothing
  where
    optionText = Text.strip (Text.dropAround (\character -> character == '[' || character == ']') (Text.Encoding.decodeLatin1 options))
    anchorValue raw =
      let (key, remainder) = Text.breakOn "=" (Text.strip raw)
       in if Text.strip key == "anchor" && not (Text.null remainder)
            then Just (Text.strip (Text.drop 1 remainder))
            else Nothing
    portValue value = case value of
      "center" -> Just Canvas.Centre
      "centre" -> Just Canvas.Centre
      "north" -> Just Canvas.North
      "north east" -> Just Canvas.NorthEast
      "east" -> Just Canvas.East
      "south east" -> Just Canvas.SouthEast
      "south" -> Just Canvas.South
      "south west" -> Just Canvas.SouthWest
      "west" -> Just Canvas.West
      "north west" -> Just Canvas.NorthWest
      _ -> Nothing

hasRelativeOption :: ByteString -> Bool
hasRelativeOption options =
  case topLevelOptionItems options of
    Nothing -> True
    Just items -> any hasRelativeKey items
  where
    hasRelativeKey item =
      let withoutLeadingSpace = ByteString.dropWhile isAsciiWhitespace item
          (key, remainder) = ByteString.break (\byte -> isAsciiWhitespace byte || byte == 61) withoutLeadingSpace
          afterKey = ByteString.dropWhile isAsciiWhitespace remainder
       in key `elem` ["above", "below", "left", "right", "of"]
            && ByteString.take 1 afterKey == "="

topLevelOptionItems :: ByteString -> Maybe [ByteString]
topLevelOptionItems options
  | ByteString.null options = Just []
  | ByteString.length options < 2 || ByteString.head options /= 91 || ByteString.last options /= 93 = Nothing
  | otherwise = go 1 1 (0 :: Int) (0 :: Int) (0 :: Int) False False []
  where
    limit = ByteString.length options - 1
    go index itemStart braces parentheses brackets inQuotes escaped accumulated
      | index >= limit =
          if braces == 0 && parentheses == 0 && brackets == 0 && not inQuotes && not escaped
            then Just (reverse (optionItem itemStart limit : accumulated))
            else Nothing
      | escaped = go (index + 1) itemStart braces parentheses brackets inQuotes False accumulated
      | otherwise =
          case ByteString.index options index of
            92 -> go (index + 1) itemStart braces parentheses brackets inQuotes True accumulated
            34 -> go (index + 1) itemStart braces parentheses brackets (not inQuotes) False accumulated
            byte
              | inQuotes -> go (index + 1) itemStart braces parentheses brackets inQuotes False accumulated
              | byte == 123 -> go (index + 1) itemStart (braces + 1) parentheses brackets inQuotes False accumulated
              | byte == 125 && braces > 0 -> go (index + 1) itemStart (braces - 1) parentheses brackets inQuotes False accumulated
              | byte == 40 -> go (index + 1) itemStart braces (parentheses + 1) brackets inQuotes False accumulated
              | byte == 41 && parentheses > 0 -> go (index + 1) itemStart braces (parentheses - 1) brackets inQuotes False accumulated
              | byte == 91 -> go (index + 1) itemStart braces parentheses (brackets + 1) inQuotes False accumulated
              | byte == 93 && brackets > 0 -> go (index + 1) itemStart braces parentheses (brackets - 1) inQuotes False accumulated
              | byte == 44 && braces == 0 && parentheses == 0 && brackets == 0 ->
                  go (index + 1) (index + 1) braces parentheses brackets inQuotes False (optionItem itemStart index : accumulated)
              | byte == 125 || byte == 41 || byte == 93 -> Nothing
              | otherwise -> go (index + 1) itemStart braces parentheses brackets inQuotes False accumulated
    optionItem start end = ByteString.take (end - start) (ByteString.drop start options)

isAsciiWhitespace :: Word8 -> Bool
isAsciiWhitespace byte = byte == 32 || (byte >= 9 && byte <= 13)

optionalBalancedBytes :: ByteString -> Int -> Word8 -> Word8 -> Int -> Either ParseFailure (ByteString, Int)
optionalBalancedBytes bytes limit open close start
  | start < limit && ByteString.index bytes start == open = do
      end <- balancedEnd bytes limit open close start
      pure (ByteString.take (end - start) (ByteString.drop start bytes), end)
  | otherwise = pure (ByteString.empty, start)

balancedAt :: ByteString -> Int -> Word8 -> Word8 -> Int -> Either ParseFailure (Source.SourceSpan, Int)
balancedAt bytes limit open close start = do
  end <- balancedEnd bytes limit open close start
  spanValue <- makeSpan start end
  pure (spanValue, end)

statementEnd :: ByteString -> Int -> Int -> Either ParseFailure Int
statementEnd bytes limit start = go start (0 :: Int) False
  where
    go index depth escaped
      | index >= limit = Left (ParseFailure "deck.unclosed_statement" start limit)
      | escaped = go (index + 1) depth False
      | otherwise = case ByteString.index bytes index of
          92 -> go (index + 1) depth True
          123 -> go (index + 1) (depth + 1) False
          125 -> go (index + 1) (max 0 (depth - 1)) False
          59 | depth == 0 -> Right (index + 1)
          _ -> go (index + 1) depth False

expectByte :: ByteString -> Int -> Word8 -> Int -> Text -> Either ParseFailure Int
expectByte bytes limit wanted index code
  | index < limit && ByteString.index bytes index == wanted = Right (index + 1)
  | otherwise = Left (ParseFailure code index (min limit (index + 1)))

expectAscii :: ByteString -> Int -> ByteString -> Int -> Text -> Either ParseFailure Int
expectAscii bytes limit wanted index code
  | index + ByteString.length wanted <= limit && wanted `ByteString.isPrefixOf` ByteString.drop index bytes = Right (index + ByteString.length wanted)
  | otherwise = Left (ParseFailure code index (min limit (index + ByteString.length wanted)))

decodeSpan :: ByteString -> Source.SourceSpan -> Either ParseFailure Text
decodeSpan bytes spanValue = mapLeft (const (ParseFailure "deck.invalid_utf8" (spanStartInt spanValue) (spanEndInt spanValue))) (Text.Encoding.decodeUtf8' (ByteString.take (spanEndInt spanValue - spanStartInt spanValue) (ByteString.drop (spanStartInt spanValue) bytes)))

skipTrivia :: Cursor -> Cursor
skipTrivia cursor = setOffset (skipTriviaBounded (cursorBytes cursor) (offset cursor) (ByteString.length (cursorBytes cursor))) cursor

skipTriviaBounded :: ByteString -> Int -> Int -> Int
skipTriviaBounded bytes start limit = go start
  where
    go index
      | index >= limit = index
      | isSpaceByte (ByteString.index bytes index) = go (index + 1)
      | ByteString.index bytes index == 37 =
          case ByteString.elemIndex 10 (ByteString.take (limit - index) (ByteString.drop index bytes)) of
            Nothing -> limit
            Just relative -> go (index + relative + 1)
      | otherwise = index

advance :: ByteString -> Int -> (Word8 -> Bool) -> Int -> Int
advance bytes limit predicate start
  | start < limit && predicate (ByteString.index bytes start) = advance bytes limit predicate (start + 1)
  | otherwise = start

identifierStart :: Word8 -> Bool
identifierStart byte = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95

identifierContinue :: Word8 -> Bool
identifierContinue byte = identifierStart byte || (byte >= 48 && byte <= 57) || byte == 45

isSpaceByte :: Word8 -> Bool
isSpaceByte byte = byte == 32 || byte == 9 || byte == 10 || byte == 13

peek :: Cursor -> Maybe Word8
peek cursor
  | offset cursor >= ByteString.length (cursorBytes cursor) = Nothing
  | otherwise = Just (ByteString.index (cursorBytes cursor) (offset cursor))

hasPrefix :: ByteString -> Cursor -> Bool
hasPrefix value cursor = value `ByteString.isPrefixOf` ByteString.drop (offset cursor) (cursorBytes cursor)

atEnd :: Cursor -> Bool
atEnd cursor = offset cursor >= ByteString.length (cursorBytes cursor)

failAt :: Text -> Cursor -> Either ParseFailure value
failAt message cursor = Left (ParseFailure message (offset cursor) (min (ByteString.length (cursorBytes cursor)) (offset cursor + 1)))

offset :: Cursor -> Int
offset (Cursor _ value) = value

cursorBytes :: Cursor -> ByteString
cursorBytes (Cursor value _) = value

setOffset :: Int -> Cursor -> Cursor
setOffset value (Cursor bytes _) = Cursor bytes value

encodeUtf8 :: Text -> ByteString
encodeUtf8 = Text.Encoding.encodeUtf8

ascii :: String -> ByteString
ascii = ByteString.pack . fmap (fromIntegral . ord)

mapLeft :: (left -> other) -> Either left value -> Either other value
mapLeft convert result = case result of
  Left failure -> Left (convert failure)
  Right value -> Right value
