{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.TikZ.Internal.Parser
-- Description : Authoritative lossless reader for the Slice 1 literal grammar.
--
-- The reader never throws and never discards source. Supported input produces
-- semantic meaning plus direct coordinate provenance. Any other input produces
-- a syntax-only document whose single opaque region denotes the complete exact
-- source snapshot.
module SlideBlaster.TikZ.Internal.Parser
  ( parseSnapshot
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text.Encoding qualified as Text.Encoding
import Data.Word (Word8)
import SlideBlaster.Source
  ( SourceBufferSnapshot
  , SourceSpan
  , snapshotBytes
  , sourceSpanEnd
  , sourceSpanFromInts
  , sourceSpanStart
  , unByteOffset
  )
import SlideBlaster.TikZ.Internal.Decimal
  ( Coordinate
  , parseCoordinateBytes
  )
import SlideBlaster.TikZ.Internal.Types
  ( AnalysisState (..)
  , ConcreteSyntax (..)
  , Connector (..)
  , CoordinateProvenance (..)
  , Diagnostic (..)
  , DiagnosticCategory (..)
  , DiagnosticCode (..)
  , DocumentSnapshot (..)
  , Node (..)
  , NodeId
  , OpaqueKind (..)
  , OpaqueRegion (..)
  , Picture (..)
  , Point (..)
  , ContentProvenance (DirectContentSlot)
  , ReadyDocument (..)
  , mkNodeId
  )

-- | Parse and elaborate one exact source revision without losing any bytes.
parseSnapshot :: SourceBufferSnapshot -> DocumentSnapshot
parseSnapshot source =
  case sourceSpanFromInts 0 sourceLength of
    Nothing ->
      recoveredDocument
        source
        Nothing
        ( ParseFailure
            DiagnosticUnsupported
            SourceSpanDomainExceeded
            0
            0
            "The source exceeds the shared native/Wasm byte-offset domain"
        )
    Just wholeSpan ->
      case parseDocument bytes of
        Left failure ->
          recoveredDocument source (Just wholeSpan) failure
        Right
          ( ParsedDocument
              nodeSpan
              connectorSpan
              xSpan
              ySpan
              contentSpan
              picture
          ) ->
            DocumentSnapshot
              source
              ( SupportedConcrete
                  wholeSpan
                  nodeSpan
                  connectorSpan
                  xSpan
                  ySpan
              )
              ( AnalysisReady
                  ( ReadyDocument
                      picture
                      (DirectCoordinateSlots xSpan ySpan)
                      (DirectContentSlot contentSpan)
                  )
              )
  where
    bytes = snapshotBytes source
    sourceLength = ByteString.length bytes

data Cursor = Cursor !ByteString !Int

data ParseFailure = ParseFailure
  !DiagnosticCategory
  !DiagnosticCode
  !Int
  !Int
  !Text

data ParsedDocument = ParsedDocument
  !SourceSpan
  !SourceSpan
  !SourceSpan
  !SourceSpan
  !SourceSpan
  !Picture

data ParsedNode = ParsedNode
  !SourceSpan
  !SourceSpan
  !SourceSpan
  !SourceSpan
  !Node

data ParsedConnector = ParsedConnector
  !SourceSpan
  !Connector

data ParsedPoint = ParsedPoint
  !Point
  !SourceSpan
  !SourceSpan

parseDocument :: ByteString -> Either ParseFailure ParsedDocument
parseDocument bytes = do
  let afterLeadingTrivia = skipTrivia (Cursor bytes 0)
  (parsedNode, afterNode) <- parseNode afterLeadingTrivia
  let beforeConnector = skipTrivia afterNode
  (parsedConnector, afterConnector) <- parseConnector beforeConnector
  let finalCursor = skipTrivia afterConnector
  ensureEnd finalCursor
  let ParsedNode nodeSpan xSpan ySpan contentSpan node = parsedNode
      ParsedConnector connectorSpan connector = parsedConnector
  ensureConnectorTarget node connector connectorSpan
  Right
    ( ParsedDocument
        nodeSpan
        connectorSpan
        xSpan
        ySpan
        contentSpan
        (Picture node connector)
    )

ensureConnectorTarget
  :: Node
  -> Connector
  -> SourceSpan
  -> Either ParseFailure ()
ensureConnectorTarget (Node nodeId _ _) (Connector connectorId _) connectorSpan
  | nodeId == connectorId = Right ()
  | otherwise =
      Left
        ( ParseFailure
            DiagnosticUnsupported
            ConnectorTargetUnsupported
            (unByteOffset (sourceSpanStart connectorSpan))
            (unByteOffset (sourceSpanEnd connectorSpan))
            "The connector must start at the picture's only named node"
        )

parseNode :: Cursor -> Either ParseFailure (ParsedNode, Cursor)
parseNode startCursor = do
  afterCommand <-
    expectStatementCommand
      ExpectedNodeStatement
      (ascii "\\node")
      startCursor
  afterCommandBoundary <-
    ensureKeywordBoundary
      ExtraConstructUnsupported
      "Only the literal \\node command is supported here"
      afterCommand
  afterOptionsCheck <-
    rejectLeadingOption
      NodeOptionsUnsupported
      "Node options are outside the literal Slice 1 subset"
      (skipTrivia afterCommandBoundary)
  afterOpen <-
    expectToken
      (ascii "(")
      "Expected '(' before the node identifier"
      afterOptionsCheck
  (nodeId, afterIdentifier) <-
    parseIdentifier InvalidNodeIdentifier afterOpen
  afterClose <-
    expectToken
      (ascii ")")
      "Expected ')' after the node identifier"
      afterIdentifier
  afterAt <-
    expectToken
      (ascii "at")
      "Expected 'at' before the direct node coordinate"
      (skipTrivia afterClose)
  afterAtBoundary <-
    ensureKeywordBoundary
      ExpectedSyntaxToken
      "Expected trivia or '(' after 'at'"
      afterAt
  (ParsedPoint position xSpan ySpan, afterPoint) <-
    parsePoint (skipTrivia afterAtBoundary)
  afterTrailingOptionsCheck <-
    rejectLeadingOption
      NodeOptionsUnsupported
      "Node options are outside the literal Slice 1 subset"
      (skipTrivia afterPoint)
  afterContentOpen <-
    expectToken
      (ascii "{")
      "Expected '{' before node content"
      afterTrailingOptionsCheck
  (content, afterContent) <- parseContent afterContentOpen
  contentSpan <-
    spanFromOffsets
      startCursor
      (cursorOffset afterContentOpen)
      (cursorOffset afterContent - 1)
  afterSemicolon <-
    expectToken
      (ascii ";")
      "Expected ';' after the node statement"
      (skipTrivia afterContent)
  statementSpan <-
    spanFromOffsets
      startCursor
      (cursorOffset startCursor)
      (cursorOffset afterSemicolon)
  Right
    ( ParsedNode
        statementSpan
        xSpan
        ySpan
        contentSpan
        (Node nodeId position content)
    , afterSemicolon
    )

parseConnector :: Cursor -> Either ParseFailure (ParsedConnector, Cursor)
parseConnector startCursor = do
  afterCommand <-
    expectConnectorCommand startCursor
  afterCommandBoundary <-
    ensureKeywordBoundary
      ExtraConstructUnsupported
      "Only the literal \\draw command is supported here"
      afterCommand
  afterOptionsCheck <-
    rejectLeadingOption
      ConnectorOptionsUnsupported
      "Connector options are outside the literal Slice 1 subset"
      (skipTrivia afterCommandBoundary)
  afterOpen <-
    expectToken
      (ascii "(")
      "Expected '(' before the connector node identifier"
      afterOptionsCheck
  (nodeId, afterIdentifier) <-
    parseIdentifier InvalidConnectorIdentifier afterOpen
  afterClose <-
    expectToken
      (ascii ")")
      "Expected ')' after the connector node identifier"
      afterIdentifier
  afterSegment <- parseConnectorOperation (skipTrivia afterClose)
  (ParsedPoint endpoint _ _, afterPoint) <-
    parsePoint (skipTrivia afterSegment)
  afterSemicolon <-
    expectToken
      (ascii ";")
      "Expected ';' after the connector statement"
      (skipTrivia afterPoint)
  statementSpan <-
    spanFromOffsets
      startCursor
      (cursorOffset startCursor)
      (cursorOffset afterSemicolon)
  Right
    ( ParsedConnector
        statementSpan
        (Connector nodeId endpoint)
    , afterSemicolon
    )

parsePoint :: Cursor -> Either ParseFailure (ParsedPoint, Cursor)
parsePoint cursor = do
  afterOpen <-
    expectToken
      (ascii "(")
      "Expected '(' before a direct decimal point"
      cursor
  (xCoordinate, xSpan, afterX) <-
    parseCoordinateToken (skipTrivia afterOpen)
  afterComma <-
    expectToken
      (ascii ",")
      "Expected ',' between point coordinates"
      (skipTrivia afterX)
  (yCoordinate, ySpan, afterY) <-
    parseCoordinateToken (skipTrivia afterComma)
  afterClose <-
    expectToken
      (ascii ")")
      "Expected ')' after a direct decimal point"
      (skipTrivia afterY)
  Right
    (ParsedPoint (Point xCoordinate yCoordinate) xSpan ySpan, afterClose)

parseCoordinateToken
  :: Cursor
  -> Either ParseFailure (Coordinate, SourceSpan, Cursor)
parseCoordinateToken cursor =
  let start = cursorOffset cursor
      afterToken = advanceWhile (not . isCoordinateDelimiter) cursor
      end = cursorOffset afterToken
      token = sliceBytes cursor start end
   in if start == end
        then
          Left
            ( ParseFailure
                DiagnosticMalformed
                InvalidCoordinateToken
                start
                end
                "Expected a direct decimal coordinate token"
            )
        else
          case parseCoordinateBytes token of
            Left _ ->
              Left
                ( ParseFailure
                    DiagnosticUnsupported
                    InvalidCoordinateToken
                    start
                    end
                    "The coordinate is outside the bounded direct-decimal subset"
                )
            Right coordinate -> do
              tokenSpan <- spanFromOffsets cursor start end
              Right (coordinate, tokenSpan, afterToken)

parseIdentifier
  :: DiagnosticCode
  -> Cursor
  -> Either ParseFailure (NodeId, Cursor)
parseIdentifier code cursor =
  case peekByte cursor of
    Nothing ->
      invalidIdentifier "Expected a node identifier"
    Just firstByte
      | not (isIdentifierStart firstByte) ->
          invalidIdentifier
            "The node identifier must start with an ASCII letter or underscore"
      | otherwise ->
          let afterIdentifier =
                advanceWhile isIdentifierContinue cursor
              start = cursorOffset cursor
              end = cursorOffset afterIdentifier
              identifierBytes = sliceBytes cursor start end
           in case peekByte afterIdentifier of
                Just byte
                  | byte /= 41 ->
                      invalidIdentifier
                        "The node identifier contains a character outside the validated token grammar"
                _ ->
                  case Text.Encoding.decodeUtf8' identifierBytes of
                    Left _ ->
                      invalidIdentifier "The node identifier is not valid UTF-8"
                    Right identifierText ->
                      case mkNodeId identifierText of
                        Nothing ->
                          invalidIdentifier
                            "The node identifier is outside the validated token grammar"
                        Just nodeId ->
                          Right (nodeId, afterIdentifier)
  where
    invalidIdentifier message =
      Left
        ( ParseFailure
            DiagnosticUnsupported
            code
            (cursorOffset cursor)
            (min (cursorLength cursor) (cursorOffset cursor + 1))
            message
        )

parseContent :: Cursor -> Either ParseFailure (Text, Cursor)
parseContent cursor =
  case findContentEnd cursor of
    Nothing ->
      Left
        ( ParseFailure
            DiagnosticMalformed
            ExpectedSyntaxToken
            (cursorOffset cursor)
            (cursorLength cursor)
            "The node content is missing its closing '}'"
        )
    Just boundaryOffset ->
      let contentBytes =
            sliceBytes cursor (cursorOffset cursor) boundaryOffset
       in case Text.Encoding.decodeUtf8' contentBytes of
            Left _ ->
              Left
                ( ParseFailure
                    DiagnosticMalformed
                    InvalidUtf8Content
                    (cursorOffset cursor)
                    boundaryOffset
                    "Node content must be valid UTF-8"
                )
            Right content ->
              Right (content, setCursorOffset (boundaryOffset + 1) cursor)

expectConnectorCommand :: Cursor -> Either ParseFailure Cursor
expectConnectorCommand cursor
  | hasPrefix (ascii "\\draw") cursor =
      expectToken
        (ascii "\\draw")
        "Expected the connector statement"
        cursor
  | hasPrefix (ascii "\\node") cursor =
      Left
        ( ParseFailure
            DiagnosticAmbiguous
            MultipleConstructsAmbiguous
            (cursorOffset cursor)
            (min (cursorLength cursor) (cursorOffset cursor + 5))
            "The literal subset permits exactly one node"
        )
  | peekByte cursor == Just 92 =
      Left
        ( ParseFailure
            DiagnosticUnsupported
            ExpectedConnectorStatement
            (cursorOffset cursor)
            (min (cursorLength cursor) (cursorOffset cursor + 1))
            "Only one straight \\draw connector may follow the node"
        )
  | otherwise =
      Left
        ( ParseFailure
            DiagnosticMalformed
            ExpectedConnectorStatement
            (cursorOffset cursor)
            (min (cursorLength cursor) (cursorOffset cursor + 1))
            "Expected one straight \\draw connector after the node"
        )

parseConnectorOperation :: Cursor -> Either ParseFailure Cursor
parseConnectorOperation cursor
  | hasPrefix (ascii "--") cursor =
      expectToken
        (ascii "--")
        "Expected the straight '--' connector operation"
        cursor
  | otherwise =
      Left
        ( ParseFailure
            DiagnosticUnsupported
            ConnectorOperationUnsupported
            (cursorOffset cursor)
            (min (cursorLength cursor) (cursorOffset cursor + 2))
            "Only one straight '--' connector segment is supported"
        )

rejectLeadingOption
  :: DiagnosticCode
  -> Text
  -> Cursor
  -> Either ParseFailure Cursor
rejectLeadingOption code message cursor
  | peekByte cursor == Just 91 =
      Left
        ( ParseFailure
            DiagnosticUnsupported
            code
            (cursorOffset cursor)
            (min (cursorLength cursor) (cursorOffset cursor + 1))
            message
        )
  | otherwise = Right cursor

expectStatementCommand
  :: DiagnosticCode
  -> ByteString
  -> Cursor
  -> Either ParseFailure Cursor
expectStatementCommand code expected cursor
  | hasPrefix expected cursor =
      expectToken expected "Expected a supported statement" cursor
  | peekByte cursor == Just 92 =
      Left
        ( ParseFailure
            DiagnosticUnsupported
            code
            (cursorOffset cursor)
            (min (cursorLength cursor) (cursorOffset cursor + 1))
            "The statement is outside the literal Slice 1 subset"
        )
  | otherwise =
      Left
        ( ParseFailure
            DiagnosticMalformed
            code
            (cursorOffset cursor)
            (min (cursorLength cursor) (cursorOffset cursor + 1))
            "Expected a supported TikZ statement"
        )

expectToken
  :: ByteString
  -> Text
  -> Cursor
  -> Either ParseFailure Cursor
expectToken expected message cursor
  | hasPrefix expected cursor =
      Right (setCursorOffset (cursorOffset cursor + ByteString.length expected) cursor)
  | otherwise =
      Left
        ( ParseFailure
            DiagnosticMalformed
            ExpectedSyntaxToken
            (cursorOffset cursor)
            (min (cursorLength cursor) (cursorOffset cursor + 1))
            message
        )

ensureKeywordBoundary
  :: DiagnosticCode
  -> Text
  -> Cursor
  -> Either ParseFailure Cursor
ensureKeywordBoundary code message cursor =
  case peekByte cursor of
    Just byte
      | isIdentifierContinue byte ->
          Left
            ( ParseFailure
                DiagnosticUnsupported
                code
                (cursorOffset cursor)
                (min (cursorLength cursor) (cursorOffset cursor + 1))
                message
            )
    _ -> Right cursor

ensureEnd :: Cursor -> Either ParseFailure ()
ensureEnd cursor
  | cursorOffset cursor == cursorLength cursor = Right ()
  | hasPrefix (ascii "\\node") cursor || hasPrefix (ascii "\\draw") cursor =
      Left
        ( ParseFailure
            DiagnosticAmbiguous
            MultipleConstructsAmbiguous
            (cursorOffset cursor)
            (cursorLength cursor)
            "The literal subset permits exactly one node and one connector"
        )
  | otherwise =
      Left
        ( ParseFailure
            DiagnosticUnsupported
            ExtraConstructUnsupported
            (cursorOffset cursor)
            (cursorLength cursor)
            "Trailing source is outside the literal Slice 1 subset"
        )

recoveredDocument
  :: SourceBufferSnapshot
  -> Maybe SourceSpan
  -> ParseFailure
  -> DocumentSnapshot
recoveredDocument source wholeSpan failure =
  DocumentSnapshot
    source
    (RecoveredConcrete (opaqueRegion :| []))
    (AnalysisUnavailable (diagnostic :| []))
  where
    ParseFailure category code start end message = failure
    failureSpan =
      case wholeSpan of
        Nothing -> Nothing
        Just _ -> sourceSpanFromInts start end
    diagnostic = Diagnostic category code failureSpan message
    opaqueRegion = OpaqueRegion (opaqueKindFromCategory category) wholeSpan

opaqueKindFromCategory :: DiagnosticCategory -> OpaqueKind
opaqueKindFromCategory = \case
  DiagnosticMalformed -> OpaqueMalformed
  DiagnosticUnsupported -> OpaqueUnsupported
  DiagnosticAmbiguous -> OpaqueAmbiguous

spanFromOffsets
  :: Cursor
  -> Int
  -> Int
  -> Either ParseFailure SourceSpan
spanFromOffsets cursor start end =
  case sourceSpanFromInts start end of
    Just spanValue -> Right spanValue
    Nothing ->
      Left
        ( ParseFailure
            DiagnosticUnsupported
            SourceSpanDomainExceeded
            0
            (cursorLength cursor)
            "A parsed source span exceeds the shared byte-offset domain"
        )

skipTrivia :: Cursor -> Cursor
skipTrivia cursor =
  case peekByte cursor of
    Just byte
      | isTriviaSpace byte ->
          skipTrivia (setCursorOffset (cursorOffset cursor + 1) cursor)
    Just 37 ->
      skipTrivia (consumeComment cursor)
    _ -> cursor

consumeComment :: Cursor -> Cursor
consumeComment cursor =
  case ByteString.elemIndex 10 (cursorRemaining cursor) of
    Nothing -> setCursorOffset (cursorLength cursor) cursor
    Just relativeOffset ->
      setCursorOffset (cursorOffset cursor + relativeOffset + 1) cursor

-- | Find the @}@ that closes node content, at the depth the content began at.
--
-- The content is not read here, only delimited, so this must agree with TeX about
-- which bytes are delimiters and which are ordinary. Three rules matter:
--
-- * a backslash makes the following byte ordinary, so @\\{@ and @\\}@ do not
--   nest, and @\\\\@ escapes only itself;
-- * @%@ comments out the rest of its line, so a brace after it is not a
--   delimiter;
-- * every other @{@ nests and must be matched before the closing brace counts.
--
-- Interpreting the content is the syntax package's job. Getting these three rules
-- wrong here would hand it the wrong bytes, which is why the scan does not simply
-- look for the first brace.
findContentEnd :: Cursor -> Maybe Int
findContentEnd cursor = scan (cursorOffset cursor) (0 :: Int)
  where
    limit = cursorLength cursor

    scan offset depth
      | offset >= limit = Nothing
      | otherwise =
          case byteAt offset of
            Nothing -> Nothing
            Just 92 -> scan (offset + 2) depth
            Just 37 -> scan (endOfLine (offset + 1)) depth
            Just 123 -> scan (offset + 1) (depth + 1)
            Just 125
              | depth == 0 -> Just offset
              | otherwise -> scan (offset + 1) (depth - 1)
            Just _ -> scan (offset + 1) depth

    -- The newline terminating a comment is ordinary content, so stop on it rather
    -- than past it.
    endOfLine offset =
      case ByteString.elemIndex 10 (ByteString.drop offset allBytes) of
        Nothing -> limit
        Just relativeOffset -> offset + relativeOffset

    byteAt offset = ByteString.indexMaybe allBytes offset

    allBytes = case cursor of
      Cursor bytes _ -> bytes

advanceWhile :: (Word8 -> Bool) -> Cursor -> Cursor
advanceWhile predicate cursor =
  case peekByte cursor of
    Just byte
      | predicate byte ->
          advanceWhile predicate (setCursorOffset (cursorOffset cursor + 1) cursor)
    _ -> cursor

isCoordinateDelimiter :: Word8 -> Bool
isCoordinateDelimiter byte =
  isTriviaSpace byte || byte == 37 || byte == 44 || byte == 41

isTriviaSpace :: Word8 -> Bool
isTriviaSpace byte =
  byte == 32 || byte == 9 || byte == 10 || byte == 13

isIdentifierStart :: Word8 -> Bool
isIdentifierStart byte =
  (byte >= 65 && byte <= 90)
    || (byte >= 97 && byte <= 122)
    || byte == 95

isIdentifierContinue :: Word8 -> Bool
isIdentifierContinue byte =
  isIdentifierStart byte
    || (byte >= 48 && byte <= 57)
    || byte == 45

hasPrefix :: ByteString -> Cursor -> Bool
hasPrefix prefix cursor =
  prefix `ByteString.isPrefixOf` cursorRemaining cursor

peekByte :: Cursor -> Maybe Word8
peekByte cursor =
  fst <$> ByteString.uncons (cursorRemaining cursor)

cursorRemaining :: Cursor -> ByteString
cursorRemaining (Cursor bytes offset) = ByteString.drop offset bytes

cursorOffset :: Cursor -> Int
cursorOffset (Cursor _ offset) = offset

cursorLength :: Cursor -> Int
cursorLength (Cursor bytes _) = ByteString.length bytes

setCursorOffset :: Int -> Cursor -> Cursor
setCursorOffset offset (Cursor bytes _) = Cursor bytes offset

sliceBytes :: Cursor -> Int -> Int -> ByteString
sliceBytes (Cursor bytes _) start end =
  ByteString.take (end - start) (ByteString.drop start bytes)

ascii :: String -> ByteString
ascii = ByteString.pack . fmap (fromIntegral . fromEnum)
