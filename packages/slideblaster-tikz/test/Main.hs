{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Executable laws for the bounded lossless TikZ Slice 1 core.
--
-- These tests exercise exact source identity, recovery, render derivation, and
-- the full candidate/reparse/semantic-verification move transaction.
module Main (main) where

import Control.Monad (replicateM, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as Text.Encoding
import Paths_slideblaster_tikz (getDataFileName)
import SlideBlaster.Canvas qualified as CommonCanvas
import SlideBlaster.Document qualified as CommonDocument
import SlideBlaster.Presentation qualified as CommonPresentation
import SlideBlaster.Source
  ( revisionFromWord64
  , snapshotBytes
  , snapshotFromBytes
  , snapshotRevision
  )
import SlideBlaster.Syntax.Command
  ( Command (Command)
  , Effect (SetStyle, ToggleStyle)
  , Target (Between)
  )
import SlideBlaster.Syntax.Inline (InlineRun (runPath))
import SlideBlaster.Syntax.Surface (Dialect (Html, Tex))
import SlideBlaster.Syntax.Range qualified as Range
import SlideBlaster.Syntax.Style
  ( Slant (Italic)
  , StyleValue (SetSlant, SetUnderline, SetWeight)
  , Weight (Bold)
  )
import SlideBlaster.TikZ
import SlideBlaster.TikZ.NodeContent (nodeContentRuns, readNodeContent)
import SlideBlaster.TikZ.Adapter
import SlideBlaster.TikZ.Internal.Edit
  ( applyMoveNodeWithCoordinateRenderer
  )
import System.Exit (exitFailure)

main :: IO ()
main = do
  run "prop_exactRoundTripPreservesBytes" exactIdentity
  run "prop_noncanonicalTriviaRemainsLossless" noncanonicalTrivia
  run "prop_moveChangesOnlyCoordinateSlots" moveIsTokenLocal
  run "prop_singleFieldMovePreservesOtherSpelling" singleFieldMove
  run "prop_connectorPlanFollowsMovedNode" connectorFollowsNode
  run "prop_staleRevisionCannotCommit" staleMove
  run "prop_noOpPreservesBytesAndRevision" noOpMove
  run "prop_recoveryRetainsMalformedAndUnsupportedBytes" recoveryRetention
  run "prop_realHeadlineOptionsRemainExactAndUnsupported" realHeadlineOptionsRemainExact
  run "prop_smallArbitraryInputsNeverLoseBytes" arbitraryRecoveryIdentity
  run "prop_directInvalidSourceRemainsAuthoritative" directInvalidSource
  run "prop_directSourceReplacementIsRevisionFenced" directSourceStale
  run "prop_ambiguousAndUnsupportedMovesAreTyped" unavailableMoveErrors
  run "prop_missingMoveTargetIsTyped" missingMoveTarget
  run "prop_verificationFailureIsAtomic" semanticVerificationFailure
  run "prop_unicodeAndCrlfRemainExact" unicodeAndCrlf
  run "prop_decimalSemanticsAreExact" exactDecimalSemantics
  run "prop_nestedNodeContentIsAdmitted" nestedNodeContent
  run "prop_unbalancedNodeContentStaysMalformed" unbalancedNodeContent
  run "prop_styleEditChangesOnlyNodeContent" styleIsContentLocal
  run "prop_styleEditIsRevisionFenced" staleStyle
  run "prop_styleEditRespectsAuthoredDialect" styleDialects
  run "prop_styleEditOnUnreadableContentIsRefused" styleUnreadable
  run "prop_toggleRemovesTheAuthorsOwnCommand" toggleRemovesCommand
  run "prop_themeDefaultDecidesUnsettledNotation" themeDefaultDecides
  run "prop_markdownContentIsEditableAsMarkdown" markdownEdit
  run "prop_commonAdmissionIsReady" commonAdmissionReady
  run "prop_commonMovePreservesExactLocality" commonMoveLocality
  run "prop_commonConnectorGeometryFollowsUnchangedStatement" commonConnectorFollows
  run "prop_commonNoOpPreservesAuthority" commonNoOp
  run "prop_commonUnsupportedPlacementIsAtomic" commonUnsupportedPlacement
  run "prop_commonSyntaxOnlyRetainsSourceAuthority" commonSyntaxOnlyAuthority

-- | A style edit must rewrite the content bytes and nothing else, so the
-- surrounding statement keeps its exact authored spelling.
styleIsContentLocal :: IO ()
styleIsContentLocal = do
  let source =
        "%lead\n\\node  (a)  at ( +001.50 , 2 )  {Bold};  %tail\n\\draw (a) -- (9,8);\n"
      document = openTikzBytes (ByteString.Char8.pack source)
  intent <- boldFirstWord document
  edited <- requireStyled document intent
  assertEqual
    "only the content bytes changed"
    ( ByteString.Char8.pack
        "%lead\n\\node  (a)  at ( +001.50 , 2 )  {\\textbf{Bo}ld};  %tail\n\\draw (a) -- (9,8);\n"
    )
    (exactDocumentBytes edited)

-- | A toggle over content that already has the property removes the author's
-- command, through the whole verified transaction.
--
-- The interface sends one effect and the tree decides it means removal. The result
-- has to survive being written into the source and read back, which is what makes
-- this different from the pure law: a wrong removal would leave content that no
-- longer reparses to what was intended, and the transaction would refuse.
toggleRemovesCommand :: IO ()
toggleRemovesCommand = do
  let source = "\\node (a) at (1,2) {x \\textbf{bold} y};\n\\draw (a) -- (9,8);\n"
      document = openTikzBytes (ByteString.Char8.pack source)
  -- Select exactly the four characters of "bold", which is the run the author's
  -- command already covers, and toggle bold.
  -- Words and whitespace are separate constructs, so "bold" is the third run.
  points <- renderedRange document 2 0 2 4
  intent <- styleIntent document (ToggleStyle (SetWeight Bold)) points
  edited <- requireStyled document intent
  assertEqual
    "the author's own command is gone and nothing opposes it"
    (ByteString.Char8.pack "\\node (a) at (1,2) {x bold y};\n\\draw (a) -- (9,8);\n")
    (exactDocumentBytes edited)

-- | Where nothing settles which notation to use, the theme's default does.
--
-- Bare text commits to no notation -- @plain@ is the same bytes in LaTeX, Markdown
-- and HTML -- and nothing encloses it here, so the same gesture on the same bytes
-- writes LaTeX under one theme and HTML under another. That is the whole reason the
-- setting exists: a file has no dialect to consult.
themeDefaultDecides :: IO ()
themeDefaultDecides = do
  let source = "\\node (a) at (1,2) {plain};\n\\draw (a) -- (9,8);\n"
      document = openTikzBytes (ByteString.Char8.pack source)
  points <- renderedRange document 0 0 0 5
  underTex <- styleIntentUnder Tex document (SetStyle (SetWeight Bold)) points
  underHtml <- styleIntentUnder Html document (SetStyle (SetWeight Bold)) points
  texEdited <- requireStyled document underTex
  htmlEdited <- requireStyled document underHtml
  assertEqual
    "a LaTeX theme default writes LaTeX"
    (ByteString.Char8.pack "\\node (a) at (1,2) {\\textbf{plain}};\n\\draw (a) -- (9,8);\n")
    (exactDocumentBytes texEdited)
  assertEqual
    "an HTML theme default writes HTML"
    ( ByteString.Char8.pack
        "\\node (a) at (1,2) {<b>plain</b>};\n\\draw (a) -- (9,8);\n"
    )
    (exactDocumentBytes htmlEdited)

-- | Markdown written directly in content is read, edited, and re-spelled as
-- Markdown, through the whole verified transaction.
--
-- Nothing declares a Markdown region: the delimiters sit in the text beside LaTeX
-- and HTML. An edit inside one is written with Markdown delimiters because that is
-- what encloses it, and the result must reparse to the same meaning or the
-- transaction refuses -- which is what makes this stronger than a printing law.
markdownEdit :: IO ()
markdownEdit = do
  let source = "\\node (a) at (1,2) {**bold** \\textit{tex} <em>html</em>};\n\\draw (a) -- (9,8);\n"
      document = openTikzBytes (ByteString.Char8.pack source)
  -- The runs are: "bold", " ", "tex", " ", "html". Italicise inside the Markdown
  -- span, whose notation must win over the LaTeX theme default.
  points <- renderedRange document 0 0 0 4
  intent <- styleIntentUnder Tex document (SetStyle (SetSlant Italic)) points
  edited <- requireStyled document intent
  assertEqual
    "the edit is written with Markdown delimiters"
    ( ByteString.Char8.pack
        "\\node (a) at (1,2) {***bold*** \\textit{tex} <em>html</em>};\n\\draw (a) -- (9,8);\n"
    )
    (exactDocumentBytes edited)

-- | A canvas drawn from an older revision cannot commit.
staleStyle :: IO ()
staleStyle = do
  let document = openTikzBytes styleFixture
  intent <- boldFirstWord document
  first <- requireStyled document intent
  case applyStyleNode intent first of
    Left (StyleStale _ _) -> pure ()
    other ->
      failTest ("a stale style edit committed or failed wrongly: " <> show other)

-- | Each construct is re-spelled in the language that authored it, in one document
-- containing both.
styleDialects :: IO ()
styleDialects = do
  let source =
        "\\node (a) at (1,2) {\\textbf{a}<em>b</em>c};\n\\draw (a) -- (9,8);\n"
      document = openTikzBytes (ByteString.Char8.pack source)
  -- Underline everything from the start of "a" to the end of "b": the LaTeX
  -- construct must gain \underline and the HTML one <u>.
  points <- renderedRange document 0 0 1 1
  intent <- styleIntent document (SetStyle (SetUnderline True)) points
  edited <- requireStyled document intent
  assertEqual
    "each dialect is re-spelled in itself"
    ( ByteString.Char8.pack
        "\\node (a) at (1,2) {\\underline{\\textbf{a}}<u><em>b</em></u>c};\n\\draw (a) -- (9,8);\n"
    )
    (exactDocumentBytes edited)

-- | Content the reader cannot read has no structure to address, so an edit to it
-- is refused and the source is untouched.
styleUnreadable :: IO ()
styleUnreadable = do
  let source = "\\node (a) at (1,2) {$unclosed};\n\\draw (a) -- (9,8);\n"
      bytes = ByteString.Char8.pack source
      document = openTikzBytes bytes
  intent <- boldFirstWord document
  case applyStyleNode intent document of
    Left (StyleContentUnreadable _) ->
      assertEqual "the source is unchanged" bytes (exactDocumentBytes document)
    other ->
      failTest ("an unreadable content edit was not refused: " <> show other)

styleFixture :: ByteString
styleFixture =
  ByteString.Char8.pack "\\node (a) at (1,2) {Bold};\n\\draw (a) -- (9,8);\n"

-- | An intent aimed at the document's own node, at its current revision.
--
-- The identity comes from the picture rather than being written out again, so a
-- fixture and its intent cannot disagree.
styleIntent :: DocumentSnapshot -> Effect -> (Range.Point, Range.Point) -> IO StyleNode
styleIntent = styleIntentUnder Tex

-- | As 'styleIntent', with an explicit theme default notation.
styleIntentUnder
  :: Dialect
  -> DocumentSnapshot
  -> Effect
  -> (Range.Point, Range.Point)
  -> IO StyleNode
styleIntentUnder themeDialect document effect (start, end) = do
  picture <- requirePicture document
  pure
    ( styleNode
        (snapshotRevision (documentSourceSnapshot document))
        (nodeId (pictureNode picture))
        themeDialect
        (Command (Between start end) effect)
    )

-- | Bold the first two characters the node renders.
boldFirstWord :: DocumentSnapshot -> IO StyleNode
boldFirstWord document = do
  points <- renderedRange document 0 0 0 2
  styleIntent document (SetStyle (SetWeight Bold)) points

-- | Two positions named the way a host names them: by rendered run and offset.
renderedRange :: DocumentSnapshot -> Int -> Int -> Int -> Int -> IO (Range.Point, Range.Point)
renderedRange document fromRun fromOffset toRun toOffset = do
  picture <- requirePicture document
  let runs = nodeContentRuns (readNodeContent (nodeContent (pictureNode picture)))
      pointAt index offset =
        case drop index runs of
          found : _ -> Right (Range.Point (runPath found) offset)
          [] -> Left ("no rendered run at index " <> show index)
  case (pointAt fromRun fromOffset, pointAt toRun toOffset) of
    (Right start, Right end) -> pure (start, end)
    (Left problem, _) -> failTest problem
    (_, Left problem) -> failTest problem

requireStyled :: DocumentSnapshot -> StyleNode -> IO DocumentSnapshot
requireStyled document intent =
  case applyStyleNode intent document of
    Right successor -> pure successor
    Left failure -> failTest ("style edit was refused: " <> show failure)

-- | Node content may contain balanced groups, so authored markup reaches the
-- syntax package instead of being refused at the picture reader.
--
-- The reader still only delimits the content; interpreting it belongs to
-- "SlideBlaster.Syntax". What is asserted here is that the right bytes are handed
-- over, including when braces nest, when a brace is escaped, and when a comment
-- would otherwise hide the closing brace.
nestedNodeContent :: IO ()
nestedNodeContent = do
  let expectContent source expected = do
        let document = openTikzBytes (ByteString.Char8.pack source)
        assertEqual
          ("nested content is byte identity: " <> source)
          (ByteString.Char8.pack source)
          (exactDocumentBytes document)
        picture <- requirePicture document
        assertEqual
          ("node content: " <> source)
          expected
          (nodeContent (pictureNode picture))
  expectContent
    "\\node (a) at (1,2) {\\textbf{bold}};\n\\draw (a) -- (9,8);\n"
    "\\textbf{bold}"
  expectContent
    "\\node (a) at (1,2) {\\textbf{a \\textit{b} c}};\n\\draw (a) -- (9,8);\n"
    "\\textbf{a \\textit{b} c}"
  -- An escaped brace is content, not a delimiter.
  expectContent
    "\\node (a) at (1,2) {a \\{ b};\n\\draw (a) -- (9,8);\n"
    "a \\{ b"
  -- A comment hides the brace that follows it on the same line.
  expectContent
    "\\node (a) at (1,2) {a % }\n};\n\\draw (a) -- (9,8);\n"
    "a % }\n"
  expectContent
    "\\node (a) at (1,2) {};\n\\draw (a) -- (9,8);\n"
    ""

-- | An unbalanced group is malformed, not unsupported: there is no closing brace,
-- so the statement never ends. Widening the accepted content must not weaken this.
unbalancedNodeContent :: IO ()
unbalancedNodeContent = do
  let source =
        ByteString.Char8.pack
          "\\node (a) at (1,2) {\\textbf{bold};\n\\draw (a) -- (9,8);\n"
      document = openTikzBytes source
  assertEqual
    "unbalanced content is still byte identity"
    source
    (exactDocumentBytes document)
  case documentSemanticState document of
    SemanticallyReady _ ->
      failTest "unbalanced node content was accepted as a picture"
    SyntaxOnly _ -> pure ()

run :: String -> IO () -> IO ()
run name check = do
  check
  putStrLn ("PASS: " <> name)

exactIdentity :: IO ()
exactIdentity = do
  let document = openTikzBytes canonicalFixture
  assertEqual "opening is byte identity" canonicalFixture (exactDocumentBytes document)
  assertEqual "supported input has no diagnostics" [] (documentDiagnostics document)
  assertEqual "supported input has no opaque regions" [] (documentOpaqueRegions document)
  case documentSemanticState document of
    SyntaxOnly diagnostics ->
      failTest ("supported fixture was syntax-only: " <> show diagnostics)
    SemanticallyReady picture -> do
      assertEqual
        "node semantic point"
        (point (coordinateFromInteger 1) (coordinateFromInteger 2))
        (nodePosition (pictureNode picture))
      assertEqual
        "connector endpoint"
        (point (coordinateFromInteger 9) (coordinateFromInteger 8))
        (connectorEnd (pictureConnector picture))

noncanonicalTrivia :: IO ()
noncanonicalTrivia = do
  let document = openTikzBytes noncanonicalFixture
  assertEqual
    "comments, spacing, and CRLF stay exact"
    noncanonicalFixture
    (exactDocumentBytes document)
  picture <- requirePicture document
  expectedX <- requireCoordinate "+001.5000"
  expectedY <- requireCoordinate "-000.00"
  assertEqual
    "noncanonical decimals elaborate by value"
    (point expectedX expectedY)
    (nodePosition (pictureNode picture))

moveIsTokenLocal :: IO ()
moveIsTokenLocal = do
  let document = openTikzBytes noncanonicalFixture
  nodeIdentity <- requireNodeId "alpha"
  let source = documentSourceSnapshot document
      destination =
        point (coordinateFromInteger 4) (coordinateFromInteger 5)
      intent = moveNode (snapshotRevision source) nodeIdentity destination
  moved <- requireRight "move was rejected" (applyMoveNode intent document)
  assertEqual
    "only the two direct decimal tokens become canonical"
    movedNoncanonicalFixture
    (exactDocumentBytes moved)
  assertEqual
    "one semantic transaction advances the revision once"
    (revisionFromWord64 1)
    (snapshotRevision (documentSourceSnapshot moved))

singleFieldMove :: IO ()
singleFieldMove = do
  let document = openTikzBytes noncanonicalFixture
  nodeIdentity <- requireNodeId "alpha"
  originalX <- requireCoordinate "+001.5000"
  let destination = point originalX (coordinateFromInteger 7)
      intent =
        moveNode
          (snapshotRevision (documentSourceSnapshot document))
          nodeIdentity
          destination
  moved <- requireRight "single-field move was rejected" (applyMoveNode intent document)
  assertEqual
    "an unchanged x token keeps its noncanonical spelling"
    movedOnlyYFixture
    (exactDocumentBytes moved)

connectorFollowsNode :: IO ()
connectorFollowsNode = do
  let document = openTikzBytes canonicalFixture
  nodeIdentity <- requireNodeId "alpha"
  let destination =
        point (coordinateFromInteger 6) (coordinateFromInteger 7)
      intent =
        moveNode
          (snapshotRevision (documentSourceSnapshot document))
          nodeIdentity
          destination
  moved <- requireRight "move was rejected" (applyMoveNode intent document)
  plan <- requireRight "moved picture did not render" (renderDocument moved)
  assertEqual
    "connector start resolves from the moved node"
    destination
    (renderConnectorStart (renderPlanConnector plan))
  assertEqual
    "connector absolute endpoint remains unchanged"
    (point (coordinateFromInteger 9) (coordinateFromInteger 8))
    (renderConnectorEnd (renderPlanConnector plan))

staleMove :: IO ()
staleMove = do
  let document = openTikzBytes canonicalFixture
      originalRevision =
        snapshotRevision (documentSourceSnapshot document)
  nodeIdentity <- requireNodeId "alpha"
  updated <-
    requireRight
      "direct source update was rejected"
      (replaceAuthoredSource originalRevision validChangedContent document)
  let staleIntent =
        moveNode
          originalRevision
          nodeIdentity
          (point (coordinateFromInteger 3) (coordinateFromInteger 4))
      bytesBeforeAttempt = exactDocumentBytes updated
  case applyMoveNode staleIntent updated of
    Left MoveStale {} ->
      assertEqual
        "stale rejection leaves the new source exact"
        bytesBeforeAttempt
        (exactDocumentBytes updated)
    other -> failTest ("stale move was not fenced: " <> show other)

noOpMove :: IO ()
noOpMove = do
  let document = openTikzBytes noncanonicalFixture
  picture <- requirePicture document
  nodeIdentity <- requireNodeId "alpha"
  let intent =
        moveNode
          (snapshotRevision (documentSourceSnapshot document))
          nodeIdentity
          (nodePosition (pictureNode picture))
  unchanged <- requireRight "no-op move was rejected" (applyMoveNode intent document)
  assertEqual
    "no-op does not canonicalize source"
    noncanonicalFixture
    (exactDocumentBytes unchanged)
  assertEqual
    "no-op does not advance revision"
    (snapshotRevision (documentSourceSnapshot document))
    (snapshotRevision (documentSourceSnapshot unchanged))

recoveryRetention :: IO ()
recoveryRetention = do
  assertRecovered
    "malformed source"
    DiagnosticMalformed
    malformedFixture
  assertRecovered
    "unsupported source"
    DiagnosticUnsupported
    unsupportedFixture
  assertRecovered
    "mismatched connector target"
    DiagnosticUnsupported
    mismatchedConnectorFixture
  assertRecovered
    "node options"
    DiagnosticUnsupported
    nodeOptionsFixture
  assertRecovered
    "connector operation"
    DiagnosticUnsupported
    connectorOperationFixture

arbitraryRecoveryIdentity :: IO ()
arbitraryRecoveryIdentity =
  mapM_ checkLength [0 .. 4]
  where
    alphabet = [0, 10, 13, 37, 40, 41, 59, 92, 123, 125, 255]
    checkLength lengthValue =
      mapM_
        checkBytes
        (ByteString.pack <$> replicateM lengthValue alphabet)
    checkBytes bytes =
      assertEqual
        "arbitrary source remains byte-exact"
        bytes
        (exactDocumentBytes (openTikzBytes bytes))

realHeadlineOptionsRemainExact :: IO ()
realHeadlineOptionsRemainExact = do
  let document = openTikzBytes realHeadlineFixture
  assertEqual "real headline child bytes remain exact" realHeadlineFixture (exactDocumentBytes document)
  case documentSemanticState document of
    SyntaxOnly diagnostics ->
      assertEqual
        "real headline options have one unsupported diagnostic"
        [DiagnosticUnsupported]
        (fmap diagnosticCategory (NonEmpty.toList diagnostics))
    SemanticallyReady picture ->
      failTest ("legacy bounded TikZ adapter misrepresented anchored headline: " <> show picture)

realHeadlineFixture :: ByteString
realHeadlineFixture =
  "\\node[\n  anchor=north west,\n  text width=7cm,\n  style=display\n] (headline) at (1,8) {\nSmall systems,\\\\\nclear thinking.\n};\n"

directInvalidSource :: IO ()
directInvalidSource = do
  let document = openTikzBytes canonicalFixture
      beforeRevision =
        snapshotRevision (documentSourceSnapshot document)
  invalid <-
    requireRight
      "invalid direct source was not admitted"
      (replaceAuthoredSource beforeRevision malformedFixture document)
  assertEqual
    "direct invalid bytes become authoritative"
    malformedFixture
    (exactDocumentBytes invalid)
  assertEqual
    "direct invalid replacement advances once"
    (revisionFromWord64 1)
    (snapshotRevision (documentSourceSnapshot invalid))
  case documentSemanticState invalid of
    SemanticallyReady picture ->
      failTest ("invalid direct source retained writable semantics: " <> show picture)
    SyntaxOnly _ -> pure ()
  nodeIdentity <- requireNodeId "alpha"
  let intent =
        moveNode
          (snapshotRevision (documentSourceSnapshot invalid))
          nodeIdentity
          (point (coordinateFromInteger 3) (coordinateFromInteger 4))
  case applyMoveNode intent invalid of
    Left MoveSemanticsUnavailable -> pure ()
    other ->
      failTest
        ("malformed direct source accepted a semantic move: " <> show other)

directSourceStale :: IO ()
directSourceStale = do
  let document = openTikzBytes canonicalFixture
      originalRevision =
        snapshotRevision (documentSourceSnapshot document)
  updated <-
    requireRight
      "valid direct update was rejected"
      (replaceAuthoredSource originalRevision validChangedContent document)
  case replaceAuthoredSource originalRevision canonicalFixture updated of
    Left DirectSourceStale {} ->
      assertEqual
        "stale direct replacement is atomic"
        validChangedContent
        (exactDocumentBytes updated)
    other ->
      failTest
        ("stale direct source replacement was not fenced: " <> show other)

commonAdmissionReady :: IO ()
commonAdmissionReady = do
  bytes <- readCommonFixture
  document <- requireRight "common TikZ admission failed" (analyzeCommonTikz (snapshotFromBytes bytes))
  assertEqual
    "common admission retains fixture bytes"
    bytes
    (snapshotBytes (CommonDocument.documentSource document))
  case CommonDocument.documentSemantic document of
    Nothing -> failTest "supported common TikZ fixture was syntax-only"
    Just presentation -> do
      let picture = commonPicture presentation
      assertEqual
        "common admission contains node and connector"
        2
        (length (CommonCanvas.pictureElements picture))

commonMoveLocality :: IO ()
commonMoveLocality = do
  document <- commonFixtureDocument
  nodeIdentity <- requireCommonNodeId "alpha"
  let destination = commonPointFromIntegers 4 5
      operation =
        CommonCanvas.MoveElement
          (CommonCanvas.NodeElement nodeIdentity)
          (CommonCanvas.AbsolutePlacement destination CommonCanvas.Centre)
  successor <- requireCommonSuccessor operation document
  assertEqual
    "common move rewrites only direct coordinate tokens"
    movedNoncanonicalFixture
    (snapshotBytes (CommonDocument.documentSource successor))
  assertEqual
    "common move advances exact source once"
    (revisionFromWord64 1)
    (snapshotRevision (CommonDocument.documentSource successor))

commonConnectorFollows :: IO ()
commonConnectorFollows = do
  document <- commonFixtureDocument
  nodeIdentity <- requireCommonNodeId "alpha"
  connectorIdentity <- requireCommonConnectorId "alpha-connector"
  let destination = commonPointFromIntegers 6 7
      operation =
        CommonCanvas.MoveElement
          (CommonCanvas.NodeElement nodeIdentity)
          (CommonCanvas.AbsolutePlacement destination CommonCanvas.Centre)
  successor <- requireCommonSuccessor operation document
  unless
    ( ByteString.Char8.pack "\\draw\t(alpha) -- (9.0 , 8);\r\n"
        `ByteString.isInfixOf` snapshotBytes (CommonDocument.documentSource successor)
    )
    (failTest "common move changed connector statement bytes")
  presentation <- requireCommonPresentation successor
  let picture = commonPicture presentation
  connector <-
    case CommonCanvas.findElement
      (CommonCanvas.ConnectorElement connectorIdentity)
      picture of
      Just (CommonCanvas.CanvasConnector value) -> pure value
      other -> failTest ("common connector missing: " <> show other)
  size <-
    requireRight
      "common connector test size"
      (CommonCanvas.mkSize (CommonCanvas.canvasUnit 1) (CommonCanvas.canvasUnit 1))
  resolved <-
    requireRight
      "common connector resolution"
      ( CommonCanvas.resolveConnectorPath
          (Map.singleton nodeIdentity (CommonCanvas.box destination size))
          (CommonCanvas.connectorPath connector)
      )
  case CommonCanvas.resolvedSegments resolved of
    [CommonCanvas.ResolvedStraight start endpoint] -> do
      assertEqual "common connector start follows successor node" destination start
      assertEqual
        "common connector endpoint remains source-authored"
        (commonPointFromIntegers 9 8)
        endpoint
    other -> failTest ("unexpected common connector geometry: " <> show other)

commonNoOp :: IO ()
commonNoOp = do
  document <- commonFixtureDocument
  nodeIdentity <- requireCommonNodeId "alpha"
  let original = commonPointFromRationals (3 / 2) 0
      operation =
        CommonCanvas.MoveElement
          (CommonCanvas.NodeElement nodeIdentity)
          (CommonCanvas.AbsolutePlacement original CommonCanvas.Centre)
  result <- requireRight "common no-op was rejected" (applyCommonTikzEdit operation document)
  case result of
    TikzCanvasUnchanged preserved ->
      assertEqual
        "common no-op preserves exact document"
        document
        preserved
    TikzCanvasVerified _ -> failTest "common no-op produced a verified successor"

commonUnsupportedPlacement :: IO ()
commonUnsupportedPlacement = do
  document <- commonFixtureDocument
  nodeIdentity <- requireCommonNodeId "alpha"
  let before = CommonDocument.documentSource document
      unsupported = CommonCanvas.GeneratedPlacement (commonPointFromIntegers 3 4) CommonCanvas.Centre
      operation =
        CommonCanvas.MoveElement
          (CommonCanvas.NodeElement nodeIdentity)
          unsupported
  case applyCommonTikzEdit operation document of
    Left (TikzCanvasPlacementUnsupported actual) ->
      assertEqual "unsupported placement is reported exactly" unsupported actual
    other -> failTest ("unsupported common placement crossed projection: " <> show other)
  assertEqual
    "unsupported common placement leaves exact authority unchanged"
    before
    (CommonDocument.documentSource document)

commonSyntaxOnlyAuthority :: IO ()
commonSyntaxOnlyAuthority = do
  let source = snapshotFromBytes malformedFixture
  document <- requireRight "malformed common admission failed" (analyzeCommonTikz source)
  assertEqual
    "syntax-only common document retains exact source"
    source
    (CommonDocument.documentSource document)
  assertEqual
    "syntax-only common document exposes no semantics"
    Nothing
    (CommonDocument.documentSemantic document)
  nodeIdentity <- requireCommonNodeId "alpha"
  let operation =
        CommonCanvas.MoveElement
          (CommonCanvas.NodeElement nodeIdentity)
          ( CommonCanvas.AbsolutePlacement
              (commonPointFromIntegers 3 4)
              CommonCanvas.Centre
          )
  case applyCommonTikzEdit operation document of
    Left (TikzCanvasProjectionFailed MoveSemanticsUnavailable) -> pure ()
    other -> failTest ("syntax-only authority accepted a canvas edit: " <> show other)
  assertEqual
    "syntax-only rejection leaves source exact"
    source
    (CommonDocument.documentSource document)

readCommonFixture :: IO ByteString
readCommonFixture = do
  path <- getDataFileName "test/fixtures/common-noncanonical.tikz"
  bytes <- ByteString.readFile path
  assertEqual "tracked common fixture has exact expected bytes" noncanonicalFixture bytes
  pure bytes

commonFixtureDocument :: IO CommonTikzDocument
commonFixtureDocument = do
  bytes <- readCommonFixture
  requireRight "common fixture admission" (analyzeCommonTikz (snapshotFromBytes bytes))

requireCommonSuccessor
  :: CommonCanvas.EditIntent
  -> CommonTikzDocument
  -> IO CommonTikzDocument
requireCommonSuccessor operation document = do
  result <- requireRight "common TikZ move failed" (applyCommonTikzEdit operation document)
  case result of
    TikzCanvasUnchanged _ -> failTest "byte-changing common move was classified as no-op"
    TikzCanvasVerified successor -> pure successor

requireCommonPresentation
  :: CommonTikzDocument
  -> IO CommonPresentation.Presentation
requireCommonPresentation document =
  case CommonDocument.documentSemantic document of
    Nothing -> failTest "expected ready common presentation"
    Just presentation -> pure presentation

commonPicture :: CommonPresentation.Presentation -> CommonCanvas.Picture
commonPicture presentation =
  CommonPresentation.frameAudiencePicture
    (NonEmpty.head (CommonPresentation.presentationFrames presentation))

requireCommonNodeId :: Text -> IO CommonCanvas.NodeId
requireCommonNodeId value =
  case CommonCanvas.nodeId value of
    Nothing -> failTest ("invalid common node id: " <> show value)
    Just identity -> pure identity

requireCommonConnectorId :: Text -> IO CommonCanvas.ConnectorId
requireCommonConnectorId value =
  case CommonCanvas.connectorId value of
    Nothing -> failTest ("invalid common connector id: " <> show value)
    Just identity -> pure identity

commonPointFromIntegers :: Integer -> Integer -> CommonCanvas.Point
commonPointFromIntegers x y =
  commonPointFromRationals (fromInteger x) (fromInteger y)

commonPointFromRationals :: Rational -> Rational -> CommonCanvas.Point
commonPointFromRationals x y =
  CommonCanvas.point (CommonCanvas.canvasUnit x) (CommonCanvas.canvasUnit y)

unavailableMoveErrors :: IO ()
unavailableMoveErrors = do
  nodeIdentity <- requireNodeId "alpha"
  let ambiguous = openTikzBytes ambiguousFixture
      unsupported = openTikzBytes unsupportedFixture
      destination =
        point (coordinateFromInteger 3) (coordinateFromInteger 4)
      intentFor document =
        moveNode
          (snapshotRevision (documentSourceSnapshot document))
          nodeIdentity
          destination
  case applyMoveNode (intentFor ambiguous) ambiguous of
    Left MoveTargetAmbiguous {} -> pure ()
    other -> failTest ("ambiguous source returned the wrong edit error: " <> show other)
  case applyMoveNode (intentFor unsupported) unsupported of
    Left MoveProjectionUnsupported {} -> pure ()
    other -> failTest ("unsupported source returned the wrong edit error: " <> show other)

missingMoveTarget :: IO ()
missingMoveTarget = do
  let document = openTikzBytes canonicalFixture
  missingId <- requireNodeId "missing"
  let intent =
        moveNode
          (snapshotRevision (documentSourceSnapshot document))
          missingId
          (point (coordinateFromInteger 3) (coordinateFromInteger 4))
  case applyMoveNode intent document of
    Left MoveTargetMissing {} -> pure ()
    other -> failTest ("missing move target returned the wrong error: " <> show other)

semanticVerificationFailure :: IO ()
semanticVerificationFailure = do
  let document = openTikzBytes canonicalFixture
      sourceBefore = exactDocumentBytes document
      revisionBefore =
        snapshotRevision (documentSourceSnapshot document)
  nodeIdentity <- requireNodeId "alpha"
  let intent =
        moveNode
          revisionBefore
          nodeIdentity
          (point (coordinateFromInteger 4) (coordinateFromInteger 5))
  case
      applyMoveNodeWithCoordinateRenderer
        (const (ByteString.Char8.pack "999"))
        intent
        document
    of
      Left (MoveVerificationFailed VerificationSemanticMismatch) -> do
        assertEqual
          "failed verification leaves source bytes unchanged"
          sourceBefore
          (exactDocumentBytes document)
        assertEqual
          "failed verification leaves revision unchanged"
          revisionBefore
          (snapshotRevision (documentSourceSnapshot document))
      other ->
        failTest
          ("incorrect inverse projection crossed verification: " <> show other)

unicodeAndCrlf :: IO ()
unicodeAndCrlf = do
  let document = openTikzBytes unicodeCrlfFixture
  picture <- requirePicture document
  assertEqual
    "Unicode content decodes semantically"
    "π 😀"
    (nodeContent (pictureNode picture))
  nodeIdentity <- requireNodeId "unicode_node"
  let intent =
        moveNode
          (snapshotRevision (documentSourceSnapshot document))
          nodeIdentity
          (point (coordinateFromInteger 3) (coordinateFromInteger 4))
  moved <- requireRight "Unicode/CRLF move was rejected" (applyMoveNode intent document)
  assertEqual
    "Unicode and CRLF bytes outside coordinate tokens stay exact"
    movedUnicodeCrlfFixture
    (exactDocumentBytes moved)

exactDecimalSemantics :: IO ()
exactDecimalSemantics = do
  noncanonical <- requireCoordinate "+001.5000"
  negativeFraction <- requireCoordinate "-1.5"
  scaled <-
    requireRight
      "valid scaled coordinate rejected"
      (coordinateFromScaled 15 1)
  negativeZero <- requireCoordinate "-000.00"
  assertEqual "equivalent decimals compare exactly" scaled noncanonical
  assertEqual "canonical decimal spelling" "1.5" (coordinateToText noncanonical)
  assertEqual "negative zero normalizes" "0" (coordinateToText negativeZero)
  assertEqual
    "cross-scale ordering compares semantic values"
    LT
    (compare noncanonical (coordinateFromInteger 2))
  assertEqual
    "negative cross-scale ordering compares semantic values"
    GT
    (compare negativeFraction (coordinateFromInteger (-2)))

assertRecovered
  :: String
  -> DiagnosticCategory
  -> ByteString
  -> IO ()
assertRecovered label expectedCategory bytes = do
  let document = openTikzBytes bytes
  assertEqual (label <> " remains exact") bytes (exactDocumentBytes document)
  case documentSemanticState document of
    SemanticallyReady picture ->
      failTest (label <> " unexpectedly elaborated: " <> show picture)
    SyntaxOnly diagnostics ->
      assertEqual
        (label <> " diagnostic category")
        expectedCategory
        (diagnosticCategory (NonEmpty.head diagnostics))
  case documentOpaqueRegions document of
    [region] ->
      assertEqual
        (label <> " opaque bytes")
        bytes
        (opaqueRegionBytes document region)
    regions ->
      failTest
        (label <> " did not produce one complete opaque region: " <> show regions)

requirePicture :: DocumentSnapshot -> IO Picture
requirePicture document =
  case documentSemanticState document of
    SyntaxOnly diagnostics ->
      failTest ("expected semantic picture, got: " <> show diagnostics)
    SemanticallyReady picture -> pure picture

requireNodeId :: Text -> IO NodeId
requireNodeId value =
  case mkNodeId value of
    Nothing -> failTest ("test node id was invalid: " <> show value)
    Just nodeIdentity -> pure nodeIdentity

requireCoordinate :: Text -> IO Coordinate
requireCoordinate value =
  requireRight
    ("test coordinate was invalid: " <> show value)
    (coordinateFromDecimalText value)

requireRight :: Show problem => String -> Either problem value -> IO value
requireRight label result =
  case result of
    Left problem -> failTest (label <> ": " <> show problem)
    Right value -> pure value

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $
    failTest (label <> ": expected " <> show expected <> ", got " <> show actual)

failTest :: String -> IO value
failTest message = do
  putStrLn ("FAIL: " <> message)
  exitFailure

canonicalFixture :: ByteString
canonicalFixture =
  ByteString.Char8.pack
    "\\node (alpha) at (1,2) {hello};\n\\draw (alpha) -- (9,8);\n"

validChangedContent :: ByteString
validChangedContent =
  ByteString.Char8.pack
    "\\node (alpha) at (1,2) {hello!};\n\\draw (alpha) -- (9,8);\n"

noncanonicalFixture :: ByteString
noncanonicalFixture =
  Text.Encoding.encodeUtf8
    "% lead\r\n\\node % command\r\n (alpha)\t at ( +001.5000 % x\r\n ,\t -000.00 ) {héllo}; % between\r\n\\draw\t(alpha) -- (9.0 , 8);\r\n"

movedNoncanonicalFixture :: ByteString
movedNoncanonicalFixture =
  Text.Encoding.encodeUtf8
    "% lead\r\n\\node % command\r\n (alpha)\t at ( 4 % x\r\n ,\t 5 ) {héllo}; % between\r\n\\draw\t(alpha) -- (9.0 , 8);\r\n"

movedOnlyYFixture :: ByteString
movedOnlyYFixture =
  Text.Encoding.encodeUtf8
    "% lead\r\n\\node % command\r\n (alpha)\t at ( +001.5000 % x\r\n ,\t 7 ) {héllo}; % between\r\n\\draw\t(alpha) -- (9.0 , 8);\r\n"

malformedFixture :: ByteString
malformedFixture =
  ByteString.Char8.pack
    "\\node (alpha) at (1,2) {hello}\n\\draw (alpha) -- (9,8);\n"

unsupportedFixture :: ByteString
unsupportedFixture =
  ByteString.Char8.pack
    "\\node (alpha) at (1,2) {hello};\n\\path (alpha) -- (9,8);\n"

mismatchedConnectorFixture :: ByteString
mismatchedConnectorFixture =
  ByteString.Char8.pack
    "\\node (alpha) at (1,2) {hello};\n\\draw (other) -- (9,8);\n"

nodeOptionsFixture :: ByteString
nodeOptionsFixture =
  ByteString.Char8.pack
    "\\node[draw] (alpha) at (1,2) {hello};\n\\draw (alpha) -- (9,8);\n"

connectorOperationFixture :: ByteString
connectorOperationFixture =
  ByteString.Char8.pack
    "\\node (alpha) at (1,2) {hello};\n\\draw (alpha) to (9,8);\n"

ambiguousFixture :: ByteString
ambiguousFixture =
  ByteString.Char8.pack
    "\\node (alpha) at (1,2) {hello};\n\\node (beta) at (3,4) {extra};\n\\draw (alpha) -- (9,8);\n"

unicodeCrlfFixture :: ByteString
unicodeCrlfFixture =
  Text.Encoding.encodeUtf8
    "% π remains\r\n\\node (unicode_node) at (+001.00, -02.0) {π 😀};\r\n\\draw (unicode_node) -- (9,8);\r\n"

movedUnicodeCrlfFixture :: ByteString
movedUnicodeCrlfFixture =
  Text.Encoding.encodeUtf8
    "% π remains\r\n\\node (unicode_node) at (3, 4) {π 😀};\r\n\\draw (unicode_node) -- (9,8);\r\n"
