{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.Session
-- Description : Pure session/1 state machine (docs/specs/session-v1-protocol.md).
--
-- One value owns the project, exact deck bytes, revision, undo/redo history,
-- analysis, theme, figure artifacts and their tickets, measurement results and
-- presenter position. 'runSession' maps one decoded request to a successor
-- state, a response kind, and host effects; failure returns no successor.
-- No IO: storage, providers and watching are effects interpreted by a driver.
module SlideBlaster.Product.Runtime.Session
  ( Session
  , newSession
  , runSession
  , viewValue
  , deckExportValue
  , sessionRevision
  , sessionSaved
  , sessionDeckBytes
  , nodeSizesPath
  , sessionNodeSizesFile
  ) where

import SlideBlaster.Canvas (OverlayStep, SourceRef, contentNodes, emptyContent, firstOverlayStep, identifierText, mkOverlayStep)
import SlideBlaster.Canvas.Flow (PictureItem (..), PictureNode (..))
import SlideBlaster.Deck.PictureEdit (Layer (..), OptionChange (..), PictureOp (..))
import SlideBlaster.Product.Runtime.Picture (PictureEnv (..), libraryFileOf, libraryNames, naturalSize, optionKeys, pictureCentres, pictureMeasureItems)
import Data.Set qualified as Set
import SlideBlaster.Presentation.Route qualified as Route
import SlideBlaster.Product.Runtime.Analysis
import SlideBlaster.Product.Runtime.ImageSize (imageDimensions, imageMime)
import SlideBlaster.Product.Runtime.Drawing (drawnFigure, figureMeasureItems, figurePlace, figureSizes)
import SlideBlaster.Syntax.Tikz.Edit qualified as Tikz
import SlideBlaster.Product.Runtime.Lower (FigureInfo (..), contentRoutes)
import SlideBlaster.Product.Runtime.Sha256 (sha256Hex)
import SlideBlaster.Product.Runtime.SlidePlan
import SlideBlaster.Product.Runtime.Theme
import SlideBlaster.Protocol.Session

import Data.Aeson (Value (..), decodeStrict, encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Scientific (toRealFloat)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.List (findIndex)
import Data.Bits (xor)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word64)

data FigureStatus
  = FigurePendingStatus
  | FigureReadyStatus !ProviderArtifact
  | FigureFailedStatus ![ProviderDiagnostic]

data Open = Open
  { openEntry :: !Text
  , openFiles :: !(Map Text ByteString)
  , openDeck :: !ByteString
  , openRevision :: !Word64
  , openSaved :: !Word64
  , openUndo :: ![Snapshot]
  , openRedo :: ![Snapshot]
  , openAnalysis :: Analysis
  , openTheme :: !Theme
  , openActive :: !Text
  , openFigures :: !(Map Text FigureStatus)
  , openRefFingerprint :: !(Map Text Text)
  , openOutstanding :: !(Map Word64 Text)
  , openNextTicket :: !Word64
  , openViewTicket :: !Word64
  , openMeasureTicket :: !(Maybe (Word64, [Text]))
  , openMeasured :: !(Map Text Double)
  , openNodeSizes :: !(Map Text (Double, Double))
  -- ^ measured content sizes of picture nodes, kept across edits (by options and content)
  , openImageRefs :: !Bool
  , openBlobs :: !(Map Text Text)
  -- ^ for each image file, the name its bytes are asked for by: it changes when the bytes do
  , openDrawn :: !(Map Text (Maybe Value))
  -- ^ each TikZ figure as the core draws it (by its reference), or nothing when it is left to TeX:
  -- worked out once when the deck or the measured sizes change, not for every plan
  , openNodeStyle :: !ByteString
  -- ^ the type those sizes were measured in; a change empties them
  , openPresenter :: !(Maybe (Text, Int))
  , openRoute :: !(Maybe Text)
  -- ^ route chosen while presenting; none means the default route
  }

data Session = Session
  { sessionAnalyzer :: Analyzer
  , sessionNextId :: !Word64
  , sessionId :: !Word64
  , sessionOpen :: !(Maybe Open)
  , sessionImageRefs :: !Bool
  -- ^ whether plans name their images instead of carrying them (the page then asks once for each)
  }

newSession :: Analyzer -> Session
newSession analyzer = Session analyzer 1 0 Nothing False

sessionRevision :: Session -> Maybe Word64
sessionRevision = fmap openRevision . sessionOpen

sessionSaved :: Session -> Maybe Word64
sessionSaved = fmap openSaved . sessionOpen

sessionDeckBytes :: Session -> Maybe ByteString
sessionDeckBytes = fmap openDeck . sessionOpen

-- | Where measured node sizes are kept between runs, as a project file. The
-- editor's page measures; @sb build@ has no page, so it lays pictures out from
-- what the editor last measured for the same content and type.
nodeSizesPath :: Text
nodeSizesPath = ".slideblaster/cache/node-sizes.json"

-- | The measured node sizes to keep, or nothing when there are none.
sessionNodeSizesFile :: Session -> Maybe ByteString
sessionNodeSizesFile session = do
  open <- sessionOpen session
  if Map.null (openNodeSizes open)
    then Nothing
    else
      Just . LazyByteString.toStrict . encode $
        object
          [ "style" .= utf8 (openNodeStyle open)
          , "sizes" .= object [Key.fromText key .= [w, h] | (key, (w, h)) <- Map.toList (openNodeSizes open)]
          ]

-- Sizes read back from that file: the type they were measured in, and the sizes.
readNodeSizes :: ByteString -> Maybe (ByteString, Map Text (Double, Double))
readNodeSizes bytes =
  case decodeStrict bytes of
    Just (Object file)
      | Just (String style) <- KeyMap.lookup "style" file
      , Just (Object sizes) <- KeyMap.lookup "sizes" file ->
          Just
            ( Encoding.encodeUtf8 style
            , Map.fromList [(Key.toText key, (toRealFloat w, toRealFloat h)) | (key, Array pair) <- KeyMap.toList sizes, [Number w, Number h] <- [foldr (:) [] pair]]
            )
    _ -> Nothing

type Step = Either SessionError (Session, Text, [Value])

-- A step of history: the deck's text, and the figure files that step had different.
data Snapshot = Snapshot !ByteString ![(Text, ByteString)]

-- | Run one request.
runSession :: Session -> SessionRequest -> Step
runSession session request =
  case request of
    OpenProject entry files -> openProject session entry files
    OpenSource bytes -> openProject session "deck.slideBlaster.md" [("deck.slideBlaster.md", bytes)]
    WorkspaceSnapshot -> withOpen session $ \open -> Right (session, "workspace_snapshot", [], open)
    ImageRefs on -> Right (session {sessionImageRefs = on, sessionOpen = fmap (\open -> open {openImageRefs = on}) (sessionOpen session)}, "image_refs_set", [])
    Resources refs -> withOpen session $ \open ->
      Right
        ( session
        , "resources"
        , [ object ["kind" .= ("resource" :: Text), "ref" .= ref, "mime" .= mime, "bytesBase16" .= base16Text bytes]
          | ref <- refs
          , (path, key) <- Map.toList (openBlobs open)
          , key == ref
          , Just mime <- [imageMime path]
          , Just bytes <- [Map.lookup path (openFiles open)]
          ]
            -- bytes named by what they are (a logo, a compiled figure): found among the files and the figures
            <> [ object ["kind" .= ("resource" :: Text), "ref" .= ref, "mime" .= mime, "bytesBase16" .= base16Text bytes]
               | ref <- refs
               , "b" `Text.isPrefixOf` ref
               , (mime, bytes) <-
                   take 1
                     [ found
                     | found@(_, candidate) <-
                         [(fromMaybe "application/octet-stream" (imageMime path), bytes') | (path, bytes') <- Map.toList (openFiles open)]
                           <> [(artifactMime a, artifactBytes a) | FigureReadyStatus a <- Map.elems (openFigures open)]
                     , ("b" <> Text.pack (show (ByteString.length candidate)) <> "-") `Text.isPrefixOf` ref
                     , contentRef candidate == ref
                     ]
               ]
        , open
        )
    ProjectFile path bytes -> withOpen session $ \open ->
      let files = maybe (Map.delete path (openFiles open)) (\b -> Map.insert path b (openFiles open)) bytes
          blobs = maybe (Map.delete path (openBlobs open)) (\b -> if imageMime path == Nothing then openBlobs open else Map.insert path (blobKey path b) (openBlobs open)) bytes
       in if path == openEntry open
            then Right (session, "project_file_updated", [], open)
            else rean session open {openFiles = files, openBlobs = blobs} "project_file_updated"
    ApplySourceReplace revision start end expected replacement -> withOpen session $ \open -> do
      checkRevision revision open
      let bytes = openDeck open
          s = fromIntegral start
          e = fromIntegral end
      if start > end || e > ByteString.length bytes
        then Left (SessionEditRejected "span out of bounds")
        else
          if ByteString.take (e - s) (ByteString.drop s bytes) /= expected
            then Left (SessionEditRejected "expected bytes do not match")
            else
              let new = ByteString.concat [ByteString.take s bytes, replacement, ByteString.drop e bytes]
               in changeDeck session open new "source_replaced"
    ReplaceSource revision bytes -> withOpen session $ \open -> do
      checkRevision revision open
      changeDeck session open bytes "source_replaced"
    SessionCommand name revision -> withOpen session $ \open -> command session open name revision
    PictureEdit revision frame op -> withOpen session $ \open -> do
      checkRevision revision open
      target <- maybe (Left SessionUnknownFrame) Right (listToMaybe' [f | f <- analysisFrames (openAnalysis open), frameKey f == frame])
      if frameOrigin target /= Nothing then Left (SessionEditRejected includeReadOnly) else Right ()
      -- plan pixels (y down) to slide units (y up)
      let (_, planHeight) = themePlanSize (openTheme open)
          ux x = toRational (x / unitScale)
          uy y = toRational ((planHeight - y) / unitScale)
          picture = frameInputPicture (frameScene target)
          -- nodes attached to a removed node stay where the layout has them
          pinsFor items =
            let centres = pictureCentres (PictureEnv (openNodeSizes open) (pictureRegions (openTheme open))) picture
             in [(pictureNodeId n, toRational x, toRational y) | PictureNodeItem n <- picture, Just (_, to) <- [pictureNodeAttached n], to `elem` items, pictureNodeId n `notElem` items, Just (x, y) <- [lookup (pictureNodeId n) centres]]
          convert one = case one of
            PictureBatch ops -> Batch (fmap convert ops)
            PictureRoute line to bend -> SetRoute line to (toRational <$> bend)
            PictureLabelText line index text -> SetLineLabel line index text
            PictureLabelStyle line index set remove -> SetLabelOptions line index (fmap RemoveOption remove <> fmap (uncurry SetOption) set)
            PictureAddPoint line step x y -> AddLinePoint line step (ux x) (uy y)
            PictureMovePoint line point x y -> MoveLinePoint line point (ux x) (uy y)
            PictureRemovePoint line point -> RemoveLinePoint line point
            PictureDeleteMany items -> DeleteItems items (pinsFor items)
            PictureReorder node to -> Reorder node (case to of "front" -> ToFront; "back" -> ToBack; "forward" -> Forward; _ -> Backward)
            PicturePaste text x y -> PasteStatements text (toRational (x / unitScale)) (toRational (negate y / unitScale))
            PictureAddNode options x y text -> AddNode options (ux x) (uy y) text
            PictureMoveNode node x y -> MoveNode node (ux x) (uy y)
            PictureAttach node side to gap -> AttachNode node side to (fmap (\d -> toRational (d / unitScale)) gap)
            PictureSetText node text -> SetNodeText node text
            PictureStyle item set remove -> SetOptions item (fmap RemoveOption remove <> fmap (uncurry SetOption) set)
            -- a box no bigger than its content needs no minimum; a circle has one size
            PictureResize node width height ->
              let (naturalW, naturalH) = case [naturalSize (openNodeSizes open) n | PictureNodeItem n <- picture, pictureNodeId n == node] of
                    size : _ -> size
                    [] -> (0, 0)
                  circle = or ["circle" `elem` optionKeys (pictureNodeOptions n) | PictureNodeItem n <- picture, pictureNodeId n == node]
                  grid v = fromIntegral (round (v / unitScale * 20) :: Integer) / 20 :: Double
                  shown v = Text.pack (trimZeros (show (grid v)))
                  trimZeros t = if ".0" `isSuffixOf'` t then take (length t - 2) t else t
                  isSuffixOf' suffix t = drop (length t - length suffix) t == suffix
                  minimum' key wanted natural
                    | grid wanted > natural + 0.02 = SetOption key (Just (shown wanted))
                    | otherwise = RemoveOption key
               in SetOptions node $
                    if circle
                      then [minimum' "minimum size" (max width height) (max naturalW naturalH), RemoveOption "minimum width", RemoveOption "minimum height"]
                      else [minimum' "minimum width" width naturalW, minimum' "minimum height" height naturalH]
            PictureConnect from to -> ConnectNodes from to
            -- a shift is a distance: right and down in pixels, right and up in units
            PictureAddInclude path x y -> AddInclude path (toRational (x / unitScale)) (toRational (negate y / unitScale))
            PictureMoveInclude item x y -> MoveInclude item (toRational (x / unitScale)) (toRational (negate y / unitScale))
            PictureDelete item -> DeleteItem item (pinsFor [item])
      (bytes, made) <- either (Left . SessionEditRejected) Right (editPicture (sessionAnalyzer session) (openFiles open) (openEntry open) (openDeck open) frame (convert op))
      (s, k, e, o) <- changeDeck session open bytes "picture_edited"
      Right (s, k, e <> [object ["kind" .= ("node_created" :: Text), "frame" .= frame, "node" .= node] | node <- made], o {openActive = frame})
    FigureEdit revision ref op -> withOpen session $ \open -> do
      checkRevision revision open
      wanted <- maybe (Left (SessionEditRejected "that figure is not there any more")) Right (listToMaybe' [r | r <- analysisFigures (openAnalysis open), identifierText (figureRef r) == ref, figureKind r == "tikz"])
      let path = resolveProjectPath open <$> figureInputPath wanted
          bodyBytes = maybe (figureBody wanted) (fromMaybe ByteString.empty . projectFile open) path
          body = utf8 bodyBytes
          place = figurePlace (figureSizes (openNodeSizes open)) (utf8 (figurePreamble wanted)) (figurePalette wanted)
          change one = case one of
            FigureMove at dx dy -> Tikz.MoveItem at dx dy
            FigureText at new -> Tikz.SetText at new
            FigureOption at key value -> Tikz.SetOption at key value
            FigureDelete at -> Tikz.DeleteItem at
            FigureAddNode x y options written -> Tikz.AddNode x y options written
            FigureAddLine from to options -> Tikz.AddLine from to options
            FigureResize at width height -> Tikz.Resize at width height
            FigureRoute at to -> Tikz.SetRoute at to
            FigureBatch ops -> Tikz.Batch (fmap change ops)
      new <- either (Left . SessionEditRejected) Right (Tikz.editFigure place (change op) body)
      let newBytes = Encoding.encodeUtf8 new
      case path of
        -- a figure written in the deck: the deck's text changes, and undo takes it back
        Nothing ->
          case ByteString.breakSubstring bodyBytes (openDeck open) of
            (_, rest) | ByteString.null rest || ByteString.null bodyBytes -> Left (SessionEditRejected "cannot find this figure's text in the deck")
            (before, rest) -> changeDeck session open (before <> newBytes <> ByteString.drop (ByteString.length bodyBytes) rest) "figure_edited"
        -- a figure in a file of its own: the file changes, and the host writes it
        Just file -> do
          (s, k, e, o) <- rean session open {openFiles = Map.insert file newBytes (openFiles open), openUndo = Snapshot (openDeck open) [(file, bodyBytes)] : openUndo open, openRedo = []} "figure_edited"
          Right (s, k, e <> [object ["kind" .= ("file.write" :: Text), "path" .= file, "expectedBase16" .= encodeBase16 bodyBytes, "bytesBase16" .= encodeBase16 newBytes]], o)
    SelectSlide frame -> withOpen session $ \open ->
      if frame `elem` frameKeys open
        then Right (session, "slide_selected", [], open {openActive = frame})
        else Left SessionUnknownFrame
    AcknowledgePaint fence -> withOpen session $ \open -> do
      checkFence fence open
      Right (session, "paint_acknowledged", [], open)
    PaintCompletion fence _ -> withOpen session $ \open -> do
      checkFence fence open
      Right (session, "paint_completed", [], open)
    MeasurementResult ticket results -> withOpen session $ \open ->
      case openMeasureTicket open of
        Just (expected, keys)
          | expected == ticket ->
              let returned = fmap (\(k, _, _) -> k) results
               in if length returned == length keys && all (`elem` keys) returned && length (nubText returned) == length returned
                    then
                      -- node sizes change the picture's geometry, so the plans are offered anew
                      let nodes = Map.fromList [(k, (w, h)) | (k, w, h) <- results, "node:" `Text.isPrefixOf` k]
                       in Right
                            ( session
                            , "measurement_accepted"
                            , []
                            , open
                                { openMeasured = Map.union (Map.fromList [(k, h) | (k, _, h) <- results, not ("node:" `Text.isPrefixOf` k)]) (openMeasured open)
                                , openNodeSizes = Map.union nodes (openNodeSizes open)
                                , openDrawn = if Map.null nodes then openDrawn open else drawnFigures open (openAnalysis open) (Map.union nodes (openNodeSizes open))
                                , openViewTicket = if Map.null nodes then openViewTicket open else openViewTicket open + 1
                                , openMeasureTicket = Nothing
                                }
                            )
                    else Left SessionMeasurementMismatch
        _ -> Left SessionStaleTicket
    ProviderResult ticket fingerprint outcome -> withOpen session $ \open ->
      case Map.lookup ticket (openOutstanding open) of
        Just expected
          | expected == fingerprint ->
              let status = case outcome of
                    ProviderArtifactOutcome artifact -> FigureReadyStatus artifact
                    ProviderDiagnosticsOutcome diagnostics -> FigureFailedStatus diagnostics
               in Right
                    ( session
                    , "provider_result_accepted"
                    , []
                    , open
                        { openFigures = Map.insert fingerprint status (openFigures open)
                        , openOutstanding = Map.delete ticket (openOutstanding open)
                        , openViewTicket = openViewTicket open + 1
                        }
                    )
        _ -> Right (session, "provider_result_ignored", [], open)
    StorageResult _ revision ok -> withOpen session $ \open ->
      Right (session, "storage_acknowledged", [], if ok && revision <= openRevision open then open {openSaved = revision} else open)
    PresentOpen start -> withOpen session $ \open ->
      let frame = fromMaybe (openActive open) start
       in if frame `elem` frameKeys open
            then Right (session, "presenting", [presentEffect "open" frame 1], open {openPresenter = Just (frame, 1), openActive = frame, openRoute = Nothing})
            else Left SessionUnknownFrame
    PresentClose -> withOpen session $ \open ->
      Right (session, "presentation_closed", [presentEffect "close" (openActive open) 1], open {openPresenter = Nothing})
    PresentStep direction -> withOpen session $ \open ->
      case openPresenter open of
        Nothing -> Left (SessionDisabled "not_presenting")
        Just (frame, step) ->
          let (frame', step') = presenterMove open direction frame step
           in Right (session, "presenter_moved", [presentEffect "goto" frame' step'], open {openPresenter = Just (frame', step'), openActive = frame'})
    PresentRoute route -> withOpen session $ \open ->
      case openPresenter open of
        Nothing -> Left (SessionDisabled "not_presenting")
        Just (frame, _)
          | route `notElem` Route.routeIds (routesOf open) -> Left (SessionDisabled "unknown_route")
          | otherwise ->
              let target = fromMaybe frame (Route.frameAfterChoice (routesOf open) route frame)
               in Right (session, "presenter_moved", [presentEffect "goto" target 1], open {openPresenter = Just (target, 1), openActive = target, openRoute = Just route})
    PresentGoto frame step -> withOpen session $ \open ->
      if frame `elem` frameKeys open
        then
          let step' = max 1 (min (frameSteps open frame) (fromMaybe 1 step))
           in Right (session, "presenter_moved", [presentEffect "goto" frame step'], open {openPresenter = Just (frame, step'), openActive = frame})
        else Left SessionUnknownFrame

nubText :: [Text] -> [Text]
nubText = Map.keys . Map.fromList . fmap (\k -> (k, ()))

-- Wrap a transition that yields a new Open; effects are derived after the
-- request by 'finish' so figure and measurement effects are never forgotten.
withOpen :: Session -> (Open -> Either SessionError (Session, Text, [Value], Open)) -> Step
withOpen session body =
  case sessionOpen session of
    Nothing -> Left SessionNotOpen
    Just open -> do
      (session', kind, effects, open') <- body open
      Right (session' {sessionOpen = Just open'}, kind, effects)

checkRevision :: Word64 -> Open -> Either SessionError ()
checkRevision requested open
  | requested == openRevision open = Right ()
  | otherwise = Left (SessionStale requested (openRevision open))

checkFence :: FenceValue -> Open -> Either SessionError ()
checkFence fence open
  | fenceRevision fence == openRevision open && fenceTicket fence == openViewTicket open = Right ()
  | otherwise = Left SessionPaintFenceMismatch

frameKeys :: Open -> [Text]
frameKeys = fmap frameKey . analysisFrames . openAnalysis

-- | Sections and routes of the deck as the presenter navigates them.
routesOf :: Open -> Route.Routes
routesOf open = Route.mkRoutes (frameKeys open) (analysisSections (openAnalysis open)) (analysisRoutes (openAnalysis open))

frameSteps :: Open -> Text -> Int
frameSteps open frame =
  case [frameStepCount (frameScene f) | f <- analysisFrames (openAnalysis open), frameKey f == frame] of
    (n : _) -> n
    [] -> 1

presenterMove :: Open -> Direction -> Text -> Int -> (Text, Int)
presenterMove open direction frame step =
  case direction of
    StepNext
      | step < frameSteps open frame -> (frame, step + 1)
      | otherwise -> maybe (frame, step) (\f -> (f, 1)) (neighbour 1)
    StepPrevious
      | step > 1 -> (frame, step - 1)
      | otherwise -> maybe (frame, step) (\f -> (f, frameSteps open f)) (neighbour (-1))
  where
    -- the active route's order; a frame the route does not hold falls back to file order
    routeKeys = Route.routeFrames (routesOf open) (openRoute open)
    keys = if frame `elem` routeKeys then routeKeys else frameKeys open
    neighbour delta = do
      index <- findIndex (== frame) keys
      let target = index + delta
      nth keys target

presentEffect :: Text -> Text -> Int -> Value
presentEffect op frame step =
  object ["kind" .= ("present" :: Text), "op" .= op, "frame" .= frame, "step" .= step, "window" .= ("presenter" :: Text)]

openProject :: Session -> Text -> [(Text, ByteString)] -> Step
openProject session entry files =
  case lookup entry files of
    Nothing -> Left (SessionProjectInvalid "entry deck is not among the files")
    Just deck ->
      let others = Map.delete entry (Map.fromList files)
          sid = sessionNextId session
          session' = session {sessionId = sid, sessionNextId = sid + 1}
          analysis = analyzeDeck (sessionAnalyzer session) others entry deck
          kept = lookup nodeSizesPath files >>= readNodeSizes
          open0 =
            Open
              { openEntry = entry, openFiles = others, openDeck = deck, openRevision = 1, openSaved = 1
              , openUndo = [], openRedo = [], openAnalysis = analysis, openTheme = builtinTheme
              , openActive = fromMaybe "" (listToMaybe' (fmap frameKey (analysisFrames analysis)))
              , openFigures = Map.empty, openRefFingerprint = Map.empty, openOutstanding = Map.empty
              , openNextTicket = 1, openViewTicket = 1, openMeasureTicket = Nothing
              , openMeasured = Map.empty, openImageRefs = sessionImageRefs session, openBlobs = Map.fromList [(path, blobKey path bytes) | (path, bytes) <- Map.toList others, imageMime path /= Nothing], openDrawn = Map.empty, openNodeSizes = maybe Map.empty snd kept, openNodeStyle = maybe ByteString.empty fst kept, openPresenter = Nothing, openRoute = Nothing
              }
          (kind, effects, opened) = reanalyse session' open0 "project_opened"
       in Right (session' {sessionOpen = Just opened}, kind, effects)

listToMaybe' :: [a] -> Maybe a
listToMaybe' (x : _) = Just x
listToMaybe' [] = Nothing

changeDeck :: Session -> Open -> ByteString -> Text -> Either SessionError (Session, Text, [Value], Open)
changeDeck session open new kind
  | new == openDeck open = Right (session, kind, [], open)
  | otherwise =
      rean
        session
        open {openDeck = new, openRevision = openRevision open + 1, openUndo = Snapshot (openDeck open) [] : openUndo open, openRedo = []}
        kind

rean :: Session -> Open -> Text -> Either SessionError (Session, Text, [Value], Open)
rean session open kind =
  let (kind', effects, open') = reanalyse session open kind
   in Right (session, kind', effects, open')

command :: Session -> Open -> CommandName -> Maybe Word64 -> Either SessionError (Session, Text, [Value], Open)
command session open name revision =
  case name of
    PreviousSlide -> move (-1)
    NextSlide -> move 1
    Save ->
      Right
        ( session
        , "save_requested"
        , [ object
              [ "kind" .= ("storage" :: Text), "op" .= ("write" :: Text), "path" .= openEntry open
              , "bytesBase16" .= encodeBase16 (openDeck open), "revision" .= openRevision open ]
          ]
        , open
        )
    NewSlide -> fenced $ do
      unless' (analysisReady (openAnalysis open)) (SessionDisabled "source_not_ready")
      unless' (not (activeIncluded open)) (SessionEditRejected includeReadOnly)
      (bytes, frame) <- maybe (Left (SessionEditRejected "cannot insert a slide")) Right (insertSlideAfter (sessionAnalyzer session) (openDeck open) (Just (openActive open)))
      (s, k, e, o) <- changeDeck session open bytes "slide_created"
      Right (s, k, e, o {openActive = frame})
    Undo -> fenced $ case openUndo open of
      [] -> Left SessionHistoryUnavailable
      (previous : rest) -> restore previous rest (back previous : openRedo open) "undone"
    Redo -> fenced $ case openRedo open of
      [] -> Left SessionHistoryUnavailable
      (next : rest) -> restore next (back next : openUndo open) rest "redone"
  where
    unless' ok failure = if ok then Right () else Left failure
    fenced action = maybe (Right ()) (`checkRevision` open) revision >> action
    keys = frameKeys open
    move delta =
      case findIndex (== openActive open) keys of
        Just index
          | Just target <- nth keys (index + delta) ->
              Right (session, "slide_selected", [], open {openActive = target})
        _ -> Left (SessionDisabled "no_such_slide")
    -- what takes a step back again: the deck as it is, and the files the step changes as they are
    back (Snapshot _ files) = Snapshot (openDeck open) [(file, fromMaybe ByteString.empty (Map.lookup file (openFiles open))) | (file, _) <- files]
    restore (Snapshot bytes files) undoStack redoStack kind = do
      (s, k, e, o) <-
        rean
          session
          open
            { openDeck = bytes
            , openFiles = foldr (\(file, was) -> Map.insert file was) (openFiles open) files
            , openRevision = openRevision open + 1
            , openUndo = undoStack
            , openRedo = redoStack
            }
          kind
      -- a figure file put back is written, as its edit was
      Right (s, k, e <> [object ["kind" .= ("file.write" :: Text), "path" .= file, "expectedBase16" .= encodeBase16 (fromMaybe ByteString.empty (Map.lookup file (openFiles open))), "bytesBase16" .= encodeBase16 was] | (file, was) <- files], o)

-- Whether the active slide comes from an included deck, which is read-only here.
activeIncluded :: Open -> Bool
activeIncluded open = or [frameOrigin f /= Nothing | f <- analysisFrames (openAnalysis open), frameKey f == openActive open]

includeReadOnly :: Text
includeReadOnly = "include.read_only: this slide comes from an included deck; open that deck to edit it"

-- Re-run analysis and derive effects: block.render for figures not yet known,
-- and one measure batch for flow bodies.
reanalyse :: Session -> Open -> Text -> (Text, [Value], Open)
reanalyse session open kind =
  let analysis = analyzeDeck (sessionAnalyzer session) (openFiles open) (openEntry open) (openDeck open)
      theme = themeFor open
      requests = [(fingerprintOf open r, r) | r <- analysisFigures analysis]
      -- a figure the core draws itself is not sent to TeX
      drawnNow = drawnFigures open analysis sizes
      drawable r = maybe False (/= Nothing) (Map.lookup (identifierText (figureRef r)) drawnNow)
      fresh = [(fp, r) | (fp, r) <- requests, not (Map.member fp (openFigures open)), not (drawable r)]
      (tickets, nextTicket) = assignTickets (openNextTicket open) fresh
      figures' =
        foldr
          (\(fp, r) acc -> Map.insert fp (initialStatus open r) acc)
          (openFigures open)
          fresh
      renderEffects =
        [ blockEffect t fp r {figureInputPath = resolveProjectPath open <$> figureInputPath r} (openEntry open) (openFiles open) | (t, (fp, r)) <- tickets, hasInputs open r ]
      outstanding' = foldr (\(t, (fp, r)) acc -> if hasInputs open r then Map.insert t fp acc else acc) (openOutstanding open) tickets
      active = if openActive open `elem` fmap frameKey (analysisFrames analysis) then openActive open else fromMaybe "" (listToMaybe' (fmap frameKey (analysisFrames analysis)))
      nodeStyle = LazyByteString.toStrict (encode (fmap (nodeRoleStyle theme) ["title", "subtitle", "body", "small", "code"]))
      sizes = if nodeStyle == openNodeStyle open then openNodeSizes open else Map.empty
      nodeItems =
        Map.toList . Map.fromList $
          concat
            [ pictureMeasureItems sizes (frameInputColours scene) (nodeRoleStyle theme) (finalStep scene) (figureInfo open {openAnalysis = analysis}) (frameInputPicture scene)
            | f <- analysisFrames analysis
            , let scene = frameScene f
            ]
            <> concat [ figureMeasureItems (nodeRoleStyle theme "body") sizes (utf8 (figurePreamble r)) (figurePalette r) (utf8 (maybe (figureBody r) (fromMaybe ByteString.empty . projectFile open . resolveProjectPath open) (figureInputPath r)))
               | r <- analysisFigures analysis
               , figureKind r == "tikz"
               ]
      measureKeys = [frameKey f | f <- analysisFrames analysis] <> fmap fst nodeItems
      measureTicket = nextTicket
      open' =
        open
          { openAnalysis = analysis
          , openNodeSizes = sizes
          , openDrawn = drawnNow
          , openNodeStyle = nodeStyle
          , openTheme = theme
          , openActive = active
          , openFigures = figures'
          , openRefFingerprint = Map.fromList [(identifierText (figureRef r), fp) | (fp, r) <- requests]
          , openOutstanding = outstanding'
          , openNextTicket = nextTicket + 1
          , openViewTicket = openViewTicket open + 1
          , openMeasureTicket = if null measureKeys then Nothing else Just (measureTicket, measureKeys)
          , openMeasured = Map.empty
          , openPresenter = openPresenter open
          }
      measureEffect =
        [ object
            [ "kind" .= ("measure" :: Text)
            , "ticket" .= measureTicket
            , "items" .= (measureItems open' theme <> fmap snd nodeItems)
            ]
        | not (null measureKeys)
        ]
   in (kind, renderEffects <> measureEffect, open')

-- The step at which all of a slide shows.
finalStep :: FrameInput -> OverlayStep
finalStep scene = fromMaybe firstOverlayStep (mkOverlayStep (fromIntegral (max 1 (frameStepCount scene))))

hasInputs :: Open -> FigureRequest -> Bool
hasInputs open request = maybe True (\path -> Map.member (resolveProjectPath open path) (openFiles open)) (figureInputPath request)

initialStatus :: Open -> FigureRequest -> FigureStatus
initialStatus open request
  | hasInputs open request = FigurePendingStatus
  | otherwise =
      FigureFailedStatus
        [ ProviderDiagnostic "error" "missing_asset" ("figure source is missing: " <> fromMaybe "" (figureInputPath request)) Nothing False ]

assignTickets :: Word64 -> [a] -> ([(Word64, a)], Word64)
assignTickets start items = (zip [start ..] items, start + fromIntegral (length items))

themeFor :: Open -> Theme
themeFor open =
  case themeFile open "theme.json" of
    Just bytes -> either (const builtinTheme) id (parseTheme bytes)
    Nothing -> builtinTheme

assetLookup :: Open -> Text -> Maybe (Text, ByteString)
assetLookup open asset = do
  bytes <- themeFile open asset
  Just (mimeFor asset, bytes)

-- | A file of the deck's theme: @themes/<name>/@ next to the deck first, as @sb build@ (which
-- takes the deck's folder as the project) and the editor's stylesheet loader see it, then at the
-- project root, where the bundled themes are offered. A deck in a subfolder of the open project
-- is laid out with the theme it is printed with.
themeFile :: Open -> Text -> Maybe ByteString
themeFile open file =
  case [bytes | dir <- dirs, Just bytes <- [Map.lookup (dir <> "themes/" <> name <> "/" <> file) (openFiles open)]] of
    bytes : _ -> Just bytes
    [] -> Nothing
  where
    name = analysisTheme (openAnalysis open)
    deckDir = fst (Text.breakOnEnd "/" (openEntry open))
    dirs = if Text.null deckDir then [""] else [deckDir, ""]

mimeFor :: Text -> Text
mimeFor path
  | ".svg" `Text.isSuffixOf` path = "image/svg+xml"
  | ".png" `Text.isSuffixOf` path = "image/png"
  | ".jpg" `Text.isSuffixOf` path || ".jpeg" `Text.isSuffixOf` path = "image/jpeg"
  | otherwise = "application/octet-stream"

-- | Core-computed fingerprint (spec 2.1).
fingerprintOf :: Open -> FigureRequest -> Text
fingerprintOf open request =
  Text.pack (sha256Hex (ByteString.concat (concatMap part material)))
  where
    nul = ByteString.singleton 0
    body = maybe (figureBody request) (fromMaybe ByteString.empty . projectFile open) (figureInputPath request)
    palette = Encoding.encodeUtf8 (Text.intercalate "," [n <> "=" <> h | (n, h) <- figurePalette request])
    width = Char8.pack (show (round (figureWidth request * 1000) :: Integer))
    inputs = concat [[Encoding.encodeUtf8 p, Map.findWithDefault ByteString.empty p (openFiles open)] | p <- Map.keys (Map.fromList [(p, ()) | p <- figureInputs request])]
    material = [Encoding.encodeUtf8 (figureKind request), body, figurePreamble request, palette, width] <> inputs
    part chunk = [chunk, nul]

utf8 :: ByteString -> Text
utf8 = Encoding.decodeUtf8With lenientDecode

-- The line map names the file a compile error is reported in: the figure's own
-- file, or the deck for a figure written in it.
blockEffect :: Word64 -> Text -> FigureRequest -> Text -> Map Text ByteString -> Value
blockEffect ticket fingerprint request entry files =
  object
    [ "kind" .= ("block.render" :: Text)
    , "ticket" .= ticket
    , "fingerprint" .= fingerprint
    , "request"
        .= object
          [ "slot" .= ("block.render" :: Text)
          , "kind" .= figureKind request
          , "fingerprint" .= fingerprint
          , "deadline" .= (60000 :: Int)
          , "input"
              .= object
                [ "body" .= utf8 body
                , "preamble" .= utf8 (figurePreamble request)
                , "palette" .= [object ["name" .= n, "hex" .= h] | (n, h) <- figurePalette request]
                , "width" .= figureWidth request
                , "inputs" .= [object ["path" .= p, "contentBase64" .= base64 (Map.findWithDefault ByteString.empty p files)] | p <- figureInputs request]
                , "lineMap" .= object ["file" .= fromMaybe entry (figureInputPath request), "firstLine" .= figureFirstLine request]
                ]
          ]
    ]
  where
    body = maybe (figureBody request) (\path -> Map.findWithDefault ByteString.empty path files) (figureInputPath request)

base64 :: ByteString -> Text
base64 bytes = Text.pack (go (ByteString.unpack bytes))
  where
    table = ['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "+/"
    sym n = fromMaybe 'A' (nth table (n `mod` 64 :: Int))
    go (a : b : c : rest) =
      let n = fromIntegral a * 65536 + fromIntegral b * 256 + fromIntegral c :: Int
       in [sym (n `div` 262144), sym (n `div` 4096), sym (n `div` 64), sym n] <> go rest
    go [a, b] =
      let n = fromIntegral a * 65536 + fromIntegral b * 256 :: Int
       in [sym (n `div` 262144), sym (n `div` 4096), sym (n `div` 64), '=']
    go [a] =
      let n = fromIntegral a * 65536 :: Int
       in [sym (n `div` 262144), sym (n `div` 4096), '=', '=']
    go [] = []

-- Lowered body content per frame, used for measurement requests.
measureItems :: Open -> Theme -> [Value]
measureItems open theme =
  [ object
      [ "key" .= frameKey f
      , "content" .= frameBodyContent (contextFor open (frameStepCount (frameScene f)) f) (frameScene f)
      , "width" .= width
      ]
  | f <- analysisFrames (openAnalysis open)
  ]
  where
    (_, _, width, _) = regionBox theme (Map.findWithDefault (Region 0 0 0 0 "left") "body" (themeRegions theme))

-- Page numbers, section and progress follow the active route; a frame the
-- route does not hold is numbered by file order.
contextFor :: Open -> Int -> AnalyzedFrame -> PlanContext
contextFor open step f =
  PlanContext
    { planSession = 0
    , planRevision = openRevision open
    , planTicket = openViewTicket open
    , planPage = page
    , planPages = pages
    , planDeckTitle = analysisTitle (openAnalysis open)
    , planSection = maybe "" Route.sectionTitle (Route.sectionOfFrame routes (frameKey f))
    , planProgress = Just (fromIntegral page / fromIntegral (max 1 pages))
    , planSectionProgress = sectionProgress
    , planStep = step
    , planSurface = "audience"
    , planFigures = figureInfo open
    , planAsset = assetLookup open
    , planArtifacts = artifactsFor open f
    , planByRef = openImageRefs open
    , planNodeSizes = openNodeSizes open
    }
  where
    routes = routesOf open
    placed = Route.position routes (openRoute open) (frameKey f)
    keys = frameKeys open
    (page, pages) = case placed of
      Just p -> (Route.positionPage p, Route.positionPages p)
      Nothing -> (maybe 1 (+ 1) (findIndex (== frameKey f) keys), length keys)
    sectionProgress = do
      p <- placed
      _ <- Route.positionSection p
      Just (fromIntegral (Route.positionSectionPage p) / fromIntegral (max 1 (Route.positionSectionPages p)))

-- Every TikZ figure of the deck as the core draws it, with the sizes measured so far.
drawnFigures :: Open -> Analysis -> Map Text (Double, Double) -> Map Text (Maybe Value)
drawnFigures open analysis sizes =
  Map.fromList
    [ (identifierText (figureRef r), drawnFigure (identifierText (figureRef r)) (figureInputPath r) (figureSizes sizes) (utf8 (figurePreamble r)) (figurePalette r) (figureUnits r) (utf8 body))
    | r <- analysisFigures analysis
    , figureKind r == "tikz"
    , let body = maybe (figureBody r) (fromMaybe ByteString.empty . projectFile open . resolveProjectPath open) (figureInputPath r)
    ]

figureInfo :: Open -> SourceRef -> FigureInfo
figureInfo open ref =
  case [r | r <- analysisImages (openAnalysis open), identifierText (imageRef r) == identifierText ref] of
    (image : _) -> imageInfo open image
    []
      | Just value <- drawn -> FigureDrawn value
    [] ->
      case Map.lookup (identifierText ref) (openRefFingerprint open) of
        Nothing -> FigureUnknown
        Just fp ->
          case Map.lookup fp (openFigures open) of
            Nothing -> FigurePending fp
            Just FigurePendingStatus -> FigurePending fp
            Just (FigureReadyStatus artifact) -> compiledSize ref fp (artifactWidth artifact) (artifactHeight artifact)
            Just (FigureFailedStatus diagnostics) ->
              case diagnostics of
                (d : _) | providerAbsent d -> FigureAbsent fp (providerMessage d)
                (d : _) -> FigureFailed fp (providerMessage d)
                [] -> FigureFailed fp "figure failed"
  where
    -- a TikZ figure the core can carry out itself is drawn without TeX, as parts the canvas can edit
    drawn = Map.lookup (identifierText ref) (openDrawn open) >>= id
    -- A requested display width scales the compiled figure, keeping its aspect.
    compiledSize figureRef' fp w h =
      case [u | r <- analysisFigures (openAnalysis open), identifierText (figureRef r) == identifierText figureRef', Just u <- [figureUnits r]] of
        (u : _) | w > 0 -> FigureReady fp (u * unitScale) (u * unitScale * h / w)
        _ -> FigureReady fp w h

-- Why a project image cannot be shown, or its bytes, media type and intrinsic size.
imageSource :: Open -> ImageRequest -> Either (Text, Text) (Text, ByteString, (Double, Double))
imageSource open r =
  case (imageMime path, projectFile open path) of
    (Nothing, _) -> Left ("unsupported_image", "unsupported image type: " <> imagePath r)
    (_, Nothing) -> Left ("missing_asset", "image file is missing: " <> imagePath r)
    (Just mime, Just bytes) -> Right (mime, bytes, fromMaybe (1, 1) (imageDimensions mime bytes))
  where
    path = fromMaybe (imagePath r) (Text.stripPrefix "./" (imagePath r))

-- The name an image's bytes are asked for by: its path, its length and a sum over its bytes.
blobKey :: Text -> ByteString -> Text
blobKey path bytes =
  let sum' = ByteString.foldl' (\acc byte -> (acc `xor` fromIntegral byte) * 1099511628211) (14695981039346656037 :: Word64) bytes
   in path <> "@" <> Text.pack (show (ByteString.length bytes)) <> "-" <> Text.pack (show sum')

-- | A file the deck names (image, figure source), as sb build reads it: relative to the deck's
-- folder first, then from the project root.
resolveProjectPath :: Open -> Text -> Text
resolveProjectPath open path =
  fromMaybe path (listToMaybe' [c | c <- candidates, Map.member c (openFiles open)])
  where
    deckDir = fst (Text.breakOnEnd "/" (openEntry open))
    candidates = [normalisePath (deckDir <> path) | not (Text.null deckDir)] <> [path]

projectFile :: Open -> Text -> Maybe ByteString
projectFile open path = Map.lookup (resolveProjectPath open path) (openFiles open)

-- "a/b/../c" -> "a/c"; leading ".." that would leave the project are kept (and find nothing).
normalisePath :: Text -> Text
normalisePath = Text.intercalate "/" . reverse . foldl step [] . Text.splitOn "/"
  where
    step acc "." = acc
    step acc "" = acc
    step (prev : acc) ".." | prev /= ".." = acc
    step acc segment = segment : acc

-- An image embeds its bytes. @width=W@ sets the width in slide units; otherwise
-- the image takes the body width, shrunk to fit the body height. Plan content
-- sizes are in plan pixels ('unitScale' per slide unit).
imageInfo :: Open -> ImageRequest -> FigureInfo
imageInfo open r =
  case imageSource open r of
    Left (_, message) -> FigureFailed "" message
    Right (mime, bytes, (iw, ih)) ->
      let ratio = ih / iw
          (bodyW, bodyH) = case Map.lookup "body" (themeRegions (openTheme open)) of
            Just region -> (regionW region, regionH region)
            Nothing -> (16, 9)
          (w, h) = case imageUnits r of
            Just u -> (u, u * ratio)
            Nothing | bodyW * ratio > bodyH -> (bodyH / ratio, bodyH)
            Nothing -> (bodyW, bodyW * ratio)
          resolved = resolveProjectPath open (fromMaybe (imagePath r) (Text.stripPrefix "./" (imagePath r)))
       in case Map.lookup resolved (openBlobs open) of
            Just ref | openImageRefs open -> FigureImageRef mime ref (w * unitScale) (h * unitScale)
            _ -> FigureImage mime (base16Text bytes) (w * unitScale) (h * unitScale)

artifactsFor :: Open -> AnalyzedFrame -> Map Text (Text, ByteString)
artifactsFor open f =
  Map.fromList
    [ (fp, (artifactMime a, artifactBytes a))
    | r <- analysisFigures (openAnalysis open)
    , figureFrame r == frameKey f
    , Just fp <- [Map.lookup (identifierText (figureRef r)) (openRefFingerprint open)]
    , Just (FigureReadyStatus a) <- [Map.lookup fp (openFigures open)]
    ]

-- | The full view value for the current state.
viewValue :: Session -> Value
viewValue session =
  case sessionOpen session of
    Nothing -> object ["ready" .= False]
    Just open -> openView session open

openView :: Session -> Open -> Value
openView session open =
  object
    [ "revision" .= openRevision open
    , "session" .= sessionId session
    , "saved" .= openSaved open
    , "ready" .= analysisReady analysis
    , "frontmatter" .= object ["title" .= analysisTitle analysis, "theme" .= analysisTheme analysis, "aspect" .= ("16:9" :: Text), "size" .= object ["width" .= w, "height" .= h]]
    , "source" .= object ["sourceBase16" .= encodeBase16 (openDeck open)]
    , "pictureFiles" .= [path | path <- Map.keys (openFiles open), ".tikz" `Text.isSuffixOf` path, path /= openEntry open, not ("shapes/" `Text.isPrefixOf` path)]
    , -- library files the deck's nodes name styles from that the project does not hold: a
      -- host with a shipped library supplies them (@project_file@)
      "needs"
        .= Set.toList
          ( Set.fromList
              [ path
              | f <- analysisFrames analysis
              , PictureNodeItem n <- frameInputPicture (frameScene f)
              , name <- libraryNames (pictureNodeOptions n)
              , Just path <- [libraryFileOf name]
              , not (Map.member path (openFiles open))
              ]
          )
    , "navigator" .= navigator
    , "sections" .= sectionsValue
    , "subsections" .= subsectionsValue
    , "routes" .= routesValue
    , "active" .= activeValue
    , "diagnostics" .= (fmap diagnosticValue (analysisDiagnostics analysis) <> figureDiagnostics open <> overflowDiagnostics open)
    , "commands" .= commands
    , "presenter" .= presenterValue
    ]
  where
    analysis = openAnalysis open
    theme = openTheme open
    (w, h) = themePlanSize theme
    frames = analysisFrames analysis
    keys = fmap frameKey frames
    activeIndex = fromMaybe 0 (findIndex (== openActive open) keys)
    planFor surface step f =
      let scene = frameScene f
          notesScene = scene {frameInputTitle = emptyContent, frameInputBody = frameNotes f, frameInputTitleSlide = Nothing, frameInputPicture = [], frameInputFooter = emptyContent}
          ctx = (contextFor open step f) {planSurface = surface}
       in if surface == "notes" then buildPlan theme ctx notesScene else buildPlan theme ctx scene
    routes = routesOf open
    frameByKey key = listToMaybe' [f | f <- frames, frameKey f == key]
    navigator =
      object
        [ "activeIndex" .= activeIndex
        , "activeFrame" .= openActive open
        , "slideCount" .= length frames
        , "items" .= fmap navItem frames
        ]
    navItem f =
      object
        [ "frame" .= frameKey f
        , "title" .= frameTitleText f
        , "section" .= fmap Route.sectionId (Route.sectionOfFrame routes (frameKey f))
        , "span" .= object ["start" .= fst (frameSpan f), "end" .= snd (frameSpan f)]
        , "subsection" .= fmap subId (listToMaybe' [s | s <- analysisSubsections analysis, frameKey f `elem` subFrames s, not (any (\t -> subId t /= subId s && frameKey f `elem` subFrames t && subId s `elem` ancestors t) (analysisSubsections analysis))])
        , "origin" .= fmap (\o -> object ["deck" .= originDeck o, "path" .= originPath o, "readOnly" .= True, "code" .= ("include.read_only" :: Text)]) (frameOrigin f)
        , "steps" .= frameStepCount (frameScene f)
        , "audience" .= planFor "audience" (frameStepCount (frameScene f)) f
        , "notes" .= planFor "notes" 1 f
        ]
    sectionsValue =
      [ object
          [ "id" .= Route.sectionId section
          , "title" .= Route.sectionTitle section
          , "frames" .= Route.sectionFrames section
          , "first" .= listToMaybe' (Route.sectionFrames section)
          , "last" .= listToMaybe' (reverse (Route.sectionFrames section))
          ]
      | section <- Route.routesSections routes
      ]
    -- subsection ids above a subsection, for picking the innermost one of a frame
    ancestors t = go (subParent t)
      where
        go Nothing = []
        go (Just p) = p : maybe [] (go . subParent) (listToMaybe' [x | x <- analysisSubsections analysis, subId x == p])
    subsectionsValue =
      [ object
          [ "id" .= subId sub
          , "title" .= subTitle sub
          , "parent" .= subParent sub
          , "deck" .= subDeck sub
          , "frames" .= subFrames sub
          , "first" .= listToMaybe' (subFrames sub)
          , "last" .= listToMaybe' (reverse (subFrames sub))
          ]
      | sub <- analysisSubsections analysis
      ]
    routesValue =
      [ object
          [ "id" .= name
          , "default" .= (Just name == Route.defaultRoute routes)
          , "sections" .= fmap Route.sectionId (Route.routeSections routes (Just name))
          , "frames" .= Route.routeFrames routes (Just name)
          ]
      | name <- Route.routeIds routes
      ]
    activeValue =
      case [f | f <- frames, frameKey f == openActive open] of
        (f : _) ->
          let step = frameStepCount (frameScene f)
              plan = planFor "audience" step f
           in object
                [ "fence" .= object ["session" .= sessionId session, "revision" .= openRevision open, "ticket" .= openViewTicket open, "frame" .= frameKey f, "surface" .= ("audience" :: Text)]
                , "plan" .= plan
                , "step" .= step
                ]
        [] -> Null
    -- the active route's frame order, with the steps of each
    routeOrder = Route.routeFrames routes (openRoute open)
    stepsOf key = maybe 1 (frameStepCount . frameScene) (frameByKey key)
    presenterValue =
      case openPresenter open of
        Nothing -> Null
        Just (frame, step) ->
          case frameByKey frame of
            Just f ->
              let order = if frame `elem` routeOrder then routeOrder else keys
                  index = fromMaybe 0 (findIndex (== frame) order)
                  cursor = sum (fmap stepsOf (take index order)) + step - 1
               in object
                    [ "frame" .= frame
                    , "step" .= step
                    , "steps" .= frameStepCount (frameScene f)
                    , "audience" .= planFor "audience" step f
                    , "notes" .= planFor "notes" 1 f
                    , "next" .= nextPlan order index f step
                    , "cursor" .= cursor
                    , "total" .= sum (fmap stepsOf order)
                    , "slide" .= object ["number" .= (index + 1), "count" .= length order]
                    , "route" .= object ["id" .= openRoute open, "default" .= Route.defaultRoute routes, "frames" .= order]
                    , "choices" .= [object ["route" .= r, "label" .= label] | (r, label) <- contentRoutes (contentNodes (frameInputBody (frameScene f))), r `elem` Route.routeIds routes]
                    ]
            Nothing -> Null
    nextPlan order index f step
      | step < frameStepCount (frameScene f) = planFor "audience" (step + 1) f
      | otherwise = case drop (index + 1) order >>= (\key -> maybe [] (: []) (frameByKey key)) of
          (g : _) -> planFor "audience" 1 g
          [] -> Null
    commands =
      object
        [ "previous_slide" .= enable (activeIndex > 0) "no_previous_slide"
        , "next_slide" .= enable (activeIndex + 1 < length frames) "no_next_slide"
        , "new_slide" .= (if activeIncludedFrame then enable False "include.read_only" else enable (analysisReady analysis) "source_not_ready")
        , "undo" .= enable (not (null (openUndo open))) "nothing_to_undo"
        , "redo" .= enable (not (null (openRedo open))) "nothing_to_redo"
        , "save" .= enable True "none"
        ]
    activeIncludedFrame = activeIncluded open
    enable True _ = object ["enabled" .= True]
    enable False reason = object ["enabled" .= False, "reason" .= (reason :: Text)]

diagnosticValue :: DiagnosticItem -> Value
diagnosticValue d =
  object
    [ "severity" .= diagnosticSeverity d
    , "code" .= diagnosticCode d
    , "message" .= diagnosticMessage d
    , "span" .= fmap (\(s, e) -> object ["start" .= s, "end" .= e]) (diagnosticSpan d)
    , "frame" .= diagnosticFrame d
    ]

figureDiagnostics :: Open -> [Value]
figureDiagnostics open =
  [ diagnosticValue (DiagnosticItem "error" code message (sourceLine open (imageFrame r) (Just (imagePath r))) (Just (imageFrame r)))
  | r <- analysisImages (openAnalysis open)
  , Left (code, message) <- [imageSource open r]
  ]
  <>
  [ diagnosticValue (DiagnosticItem "error" (if providerAbsent d then "provider_absent" else providerCode d) (providerMessage d) (sourceLine open (figureFrame r) (figureInputPath r)) (Just (figureFrame r)))
  | r <- analysisFigures (openAnalysis open)
  , Just fp <- [Map.lookup (identifierText (figureRef r)) (openRefFingerprint open)]
  , Just (FigureFailedStatus ds) <- [Map.lookup fp (openFigures open)]
  , d <- take 1 ds
  ]

-- The source line that names a figure: the line holding its path inside the
-- slide's span, else the whole slide.
sourceLine :: Open -> Text -> Maybe Text -> Maybe (Int, Int)
sourceLine open frame path' = do
  f <- listToMaybe' [f | f <- analysisFrames (openAnalysis open), frameKey f == frame]
  let (start, end) = frameSpan f
      slide = ByteString.take (end - start) (ByteString.drop start (openDeck open))
  case path' of
    Nothing -> Just (start, end)
    Just path ->
      let (before, after) = ByteString.breakSubstring (Encoding.encodeUtf8 path) slide
       in if ByteString.null after
            then Just (start, end)
            else
              let lineStart = maybe 0 (+ 1) (ByteString.elemIndexEnd 10 before)
                  lineEnd = ByteString.length before + fromMaybe (ByteString.length after) (ByteString.elemIndex 10 after)
               in Just (start + lineStart, start + lineEnd)

overflowDiagnostics :: Open -> [Value]
overflowDiagnostics open =
  [ diagnosticValue (DiagnosticItem "warning" "overflow" "slide content is taller than its region" (Just (frameSpan f)) (Just (frameKey f)))
  | f <- analysisFrames (openAnalysis open)
  , Just measured <- [Map.lookup (frameKey f) (openMeasured open)]
  , measured > regionHeight
  ]
  where
    (_, _, _, regionHeight) = regionBox (openTheme open) (Map.findWithDefault (Region 0 0 0 0 "left") "body" (themeRegions (openTheme open)))

-- | Total list indexing.
nth :: [a] -> Int -> Maybe a
nth items index
  | index < 0 = Nothing
  | otherwise = listToMaybe' (drop index items)

-- | Whole-deck export value: every slide with one audience plan per step plus
-- notes, in the session/1 plan vocabulary. Nothing here depends on a host.
deckExportValue :: Session -> Maybe Value
deckExportValue session = do
  open <- sessionOpen session
  let analysis = openAnalysis open
      theme = openTheme open
      (w, h) = themePlanSize theme
      frames = analysisFrames analysis
      routes = routesOf open
      slide f =
        let steps = frameStepCount (frameScene f)
            ctx step surface = (contextFor open step f) {planSurface = surface}
            choices = [(route, target) | (route, _) <- contentRoutes (contentNodes (frameInputBody (frameScene f))), Just target <- [Route.frameAfterChoice routes route (frameKey f)]]
            continues =
              [ object ["route" .= name, "title" .= Route.sectionTitle next, "frame" .= first]
              | Just section <- [Route.sectionOfFrame routes (frameKey f)]
              , lastFrame section == Just (frameKey f)
              , (name, next) <- Route.continuations routes section
              , first : _ <- [Route.sectionFrames next]
              ]
         in object $
              [ "frame" .= frameKey f
              , "title" .= frameTitleText f
              , "steps" .= steps
              , "plans" .= [buildPlan theme (ctx step "audience") (frameScene f) | step <- [1 .. steps]]
              , "notes" .= buildPlan theme (ctx 1 "notes") ((frameScene f) {frameInputTitle = emptyContent, frameInputBody = frameNotes f, frameInputTitleSlide = Nothing, frameInputPicture = [], frameInputFooter = emptyContent})
              ]
                <> ["choices" .= object [Key.fromText route .= target | (route, target) <- choices] | not (null choices)]
                <> ["continue" .= continues | not (null continues)]
      lastFrame section = listToMaybe' (reverse (Route.sectionFrames section))
  Just
    ( object
        [ "protocol" .= sessionProtocol
        , "title" .= analysisTitle analysis
        , "theme" .= themeName theme
        , "size" .= object ["width" .= w, "height" .= h]
        , "slides" .= fmap slide frames
        , "order" .= Route.exportOrder routes
        , "diagnostics" .= (fmap diagnosticValue (analysisDiagnostics analysis) <> figureDiagnostics open)
        ]
    )
