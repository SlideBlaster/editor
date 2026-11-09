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
  ) where

import SlideBlaster.Canvas (SourceRef, contentNodes, emptyContent, identifierText)
import SlideBlaster.Presentation.Route qualified as Route
import SlideBlaster.Product.Runtime.Analysis
import SlideBlaster.Product.Runtime.ImageSize (imageDimensions, imageMime)
import SlideBlaster.Product.Runtime.Lower (FigureInfo (..), contentRoutes)
import SlideBlaster.Product.Runtime.Sha256 (sha256Hex)
import SlideBlaster.Product.Runtime.SlidePlan
import SlideBlaster.Product.Runtime.Theme
import SlideBlaster.Protocol.Session

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.List (findIndex)
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
  , openUndo :: ![ByteString]
  , openRedo :: ![ByteString]
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
  , openPresenter :: !(Maybe (Text, Int))
  , openRoute :: !(Maybe Text)
  -- ^ route chosen while presenting; none means the default route
  }

data Session = Session
  { sessionAnalyzer :: Analyzer
  , sessionNextId :: !Word64
  , sessionId :: !Word64
  , sessionOpen :: !(Maybe Open)
  }

newSession :: Analyzer -> Session
newSession analyzer = Session analyzer 1 0 Nothing

sessionRevision :: Session -> Maybe Word64
sessionRevision = fmap openRevision . sessionOpen

sessionSaved :: Session -> Maybe Word64
sessionSaved = fmap openSaved . sessionOpen

sessionDeckBytes :: Session -> Maybe ByteString
sessionDeckBytes = fmap openDeck . sessionOpen

type Step = Either SessionError (Session, Text, [Value])

-- | Run one request.
runSession :: Session -> SessionRequest -> Step
runSession session request =
  case request of
    OpenProject entry files -> openProject session entry files
    OpenSource bytes -> openProject session "deck.slideBlaster.md" [("deck.slideBlaster.md", bytes)]
    WorkspaceSnapshot -> withOpen session $ \open -> Right (session, "workspace_snapshot", [], open)
    ProjectFile path bytes -> withOpen session $ \open ->
      let files = maybe (Map.delete path (openFiles open)) (\b -> Map.insert path b (openFiles open)) bytes
       in if path == openEntry open
            then Right (session, "project_file_updated", [], open)
            else rean session open {openFiles = files} "project_file_updated"
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
                      Right
                        ( session
                        , "measurement_accepted"
                        , []
                        , open {openMeasured = Map.union (Map.fromList [(k, h) | (k, _, h) <- results]) (openMeasured open), openMeasureTicket = Nothing}
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
          open0 =
            Open
              { openEntry = entry, openFiles = others, openDeck = deck, openRevision = 1, openSaved = 1
              , openUndo = [], openRedo = [], openAnalysis = analysis, openTheme = builtinTheme
              , openActive = fromMaybe "" (listToMaybe' (fmap frameKey (analysisFrames analysis)))
              , openFigures = Map.empty, openRefFingerprint = Map.empty, openOutstanding = Map.empty
              , openNextTicket = 1, openViewTicket = 1, openMeasureTicket = Nothing
              , openMeasured = Map.empty, openPresenter = Nothing, openRoute = Nothing
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
        open {openDeck = new, openRevision = openRevision open + 1, openUndo = openDeck open : openUndo open, openRedo = []}
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
      (previous : rest) -> restore previous rest (openDeck open : openRedo open) "undone"
    Redo -> fenced $ case openRedo open of
      [] -> Left SessionHistoryUnavailable
      (next : rest) -> restore next (openDeck open : openUndo open) rest "redone"
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
    restore bytes undoStack redoStack kind =
      rean
        session
        open {openDeck = bytes, openRevision = openRevision open + 1, openUndo = undoStack, openRedo = redoStack}
        kind

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
      fresh = [(fp, r) | (fp, r) <- requests, not (Map.member fp (openFigures open))]
      (tickets, nextTicket) = assignTickets (openNextTicket open) fresh
      figures' =
        foldr
          (\(fp, r) acc -> Map.insert fp (initialStatus open r) acc)
          (openFigures open)
          fresh
      renderEffects =
        [ blockEffect t fp r (openFiles open) | (t, (fp, r)) <- tickets, hasInputs open r ]
      outstanding' = foldr (\(t, (fp, r)) acc -> if hasInputs open r then Map.insert t fp acc else acc) (openOutstanding open) tickets
      active = if openActive open `elem` fmap frameKey (analysisFrames analysis) then openActive open else fromMaybe "" (listToMaybe' (fmap frameKey (analysisFrames analysis)))
      measureKeys = [frameKey f | f <- analysisFrames analysis]
      measureTicket = nextTicket
      open' =
        open
          { openAnalysis = analysis
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
            , "items" .= measureItems open' theme
            ]
        | not (null measureKeys)
        ]
   in (kind, renderEffects <> measureEffect, open')

hasInputs :: Open -> FigureRequest -> Bool
hasInputs open request = maybe True (`Map.member` openFiles open) (figureInputPath request)

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
    body = maybe (figureBody request) (\path -> Map.findWithDefault ByteString.empty path (openFiles open)) (figureInputPath request)
    palette = Encoding.encodeUtf8 (Text.intercalate "," [n <> "=" <> h | (n, h) <- figurePalette request])
    width = Char8.pack (show (round (figureWidth request * 1000) :: Integer))
    inputs = concat [[Encoding.encodeUtf8 p, Map.findWithDefault ByteString.empty p (openFiles open)] | p <- Map.keys (Map.fromList [(p, ()) | p <- figureInputs request])]
    material = [Encoding.encodeUtf8 (figureKind request), body, figurePreamble request, palette, width] <> inputs
    part chunk = [chunk, nul]

utf8 :: ByteString -> Text
utf8 = Encoding.decodeUtf8With lenientDecode

blockEffect :: Word64 -> Text -> FigureRequest -> Map Text ByteString -> Value
blockEffect ticket fingerprint request files =
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
                , "lineMap" .= object ["file" .= figureInputPath request, "firstLine" .= figureFirstLine request]
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

figureInfo :: Open -> SourceRef -> FigureInfo
figureInfo open ref =
  case [r | r <- analysisImages (openAnalysis open), identifierText (imageRef r) == identifierText ref] of
    (image : _) -> imageInfo open image
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
    -- A requested display width scales the compiled figure, keeping its aspect.
    compiledSize figureRef' fp w h =
      case [u | r <- analysisFigures (openAnalysis open), identifierText (figureRef r) == identifierText figureRef', Just u <- [figureUnits r]] of
        (u : _) | w > 0 -> FigureReady fp (u * unitScale) (u * unitScale * h / w)
        _ -> FigureReady fp w h

-- Why a project image cannot be shown, or its bytes, media type and intrinsic size.
imageSource :: Open -> ImageRequest -> Either (Text, Text) (Text, ByteString, (Double, Double))
imageSource open r =
  case (imageMime path, Map.lookup path (openFiles open)) of
    (Nothing, _) -> Left ("unsupported_image", "unsupported image type: " <> imagePath r)
    (_, Nothing) -> Left ("missing_asset", "image file is missing: " <> imagePath r)
    (Just mime, Just bytes) -> Right (mime, bytes, fromMaybe (1, 1) (imageDimensions mime bytes))
  where
    path = fromMaybe (imagePath r) (Text.stripPrefix "./" (imagePath r))

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
       in FigureImage mime (base16Text bytes) (w * unitScale) (h * unitScale)

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
