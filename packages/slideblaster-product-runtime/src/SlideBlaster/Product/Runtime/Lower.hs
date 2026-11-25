{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.Lower
-- Description : Canvas content to the closed session/1 plan content tree.
--
-- Pure lowering of 'Canvas.Content' at one audience step into the JSON content
-- vocabulary of @docs/specs/session-v1-protocol.md@ section 5. Visibility at the
-- requested step is resolved here: later-step content becomes reserved geometry
-- (ADR 0018), never silently dropped. Provider artifacts substitute figures by
-- fingerprint through the supplied lookup; the host never resolves them.
module SlideBlaster.Product.Runtime.Lower
  ( FigureInfo (..)
  , lowerContent
  , contentStepCount
  , contentRoutes
  ) where

import SlideBlaster.Canvas
  ( mkOverlayStep
  , Content
  , ContentNode (..)
  , ContentItem (..)
  , ContentOverlayEvent (..)
  , ContainerKind (..)
  , InlineMark (..)
  , ListKind (..)
  , MathKind (..)
  , OverlayDirective (..)
  , OverlayHook
  , OverlayStep
  , content
  , contentOverlayEvents
  , contentNodes
  , identifierText
  , overlayFinalStep
  , overlayStepNumber
  , overlayVisibleAt
  , SourceBackedContent (..)
  , DerivedState (..)
  , TableModel (..)
  , TableCell (..)
  , TableRow (..)
  , SourceRef
  , CitationKey
  , sourceRef
  )

import Data.Aeson (Value (..), object, (.=))
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Data.Vector (fromList)
import SlideBlaster.Listing (Listing, LineRange (..), highlightedAt, listingHighlight, listingLanguage, listingLines)
import Numeric.Natural (Natural)

-- | State of a block-rendered figure as the core knows it.
data FigureInfo
  = FigureUnknown
  | FigurePending !Text
  | FigureReady !Text !Double !Double
  | FigureFailed !Text !Text
  | FigureAbsent !Text !Text
  | FigureDrawn !Value
  -- ^ a TikZ figure carried out here: a @drawing@ value, ready for the page
  | FigureImage !Text !Text !Double !Double
  | FigureImageRef !Text !Text !Double !Double
  -- ^ the same, with the bytes named rather than carried: media type, the name to ask for them by, width and height
  -- ^ embedded project image: media type, base16 bytes, display width and height in plan pixels
  deriving stock (Eq, Show)

-- | Lower content as it appears at one audience step.
lowerContent :: OverlayStep -> (SourceRef -> FigureInfo) -> [ContentNode] -> [Value]
lowerContent step figures nodes = snd (lowerSeq step figures 1 (resolvePauses nodes))

-- | Give every plain @\\pause@ its step. A pause shows what follows one step
-- after everything before it: after the pauses before it, and also after the
-- last step an overlay specification before it names. So
-- @\\only\<1\>{a} \\only\<2\>{b} \\pause c@ shows c on step 3. (Beamer
-- counts pauses on their own and would show c on step 2, together with b.)
resolvePauses :: [ContentNode] -> [ContentNode]
resolvePauses = snd . several (1, 1)
  where
    several state [] = (state, [])
    several state (node : rest) =
      let (state', node') = one state node
          (state'', rest') = several state' rest
       in (state'', node' : rest')
    -- the state: the step a pause has reached, and the last step named so far
    one state@(local, named) node =
      case node of
        OverlayPauseContent p PauseNext ->
          let next = max local named + 1
           in ((next, named), maybe node (OverlayPauseContent p . PauseAt) (mkOverlayStep next))
        OverlayPauseContent _ (PauseAt target) -> ((overlayStepNumber target, named), node)
        OverlayContent hook children ->
          let (state', children') = several (local, max named (overlayStepNumber (overlayFinalStep hook))) children
           in (state', OverlayContent hook children')
        StyledRun p style children -> let (state', children') = several state children in (state', StyledRun p style children')
        TransparentContainer p kind children -> let (state', children') = several state children in (state', TransparentContainer p kind children')
        _ -> (state, node)

-- | Number of audience steps content needs (at least one).
contentStepCount :: Content -> Int
contentStepCount value =
  fromIntegral (foldl max 1 (stepsOf 1 (contentOverlayEvents (content (resolvePauses (contentNodes value))))))
  where
    stepsOf :: Natural -> [ContentOverlayEvent] -> [Natural]
    stepsOf _ [] = []
    stepsOf local (event : rest) =
      case event of
        ContentOverlayHook hook ->
          overlayStepNumber (overlayFinalStep hook) : stepsOf local rest
        ContentOverlayPause PauseNext ->
          (local + 1) : stepsOf (local + 1) rest
        ContentOverlayPause (PauseAt target) ->
          let n = overlayStepNumber target in n : stepsOf n rest

-- | The route choices (@\\route{id}{label}@) in content, in reading order:
-- route id and the label's plain text.
contentRoutes :: [ContentNode] -> [(Text, Text)]
contentRoutes = concatMap node
  where
    node n = case n of
      TransparentContainer _ (GenericContainer name) children
        | Just route <- Text.stripPrefix "route:" name -> [(route, Text.strip (plain children))]
      TransparentContainer _ _ children -> contentRoutes children
      StyledRun _ _ children -> contentRoutes children
      OverlayContent _ children -> contentRoutes children
      ListContent _ _ items -> concatMap (contentRoutes . contentItemBody) (toList items)
      _ -> []
    plain = Text.concat . fmap text
    text n = case n of
      TextRun _ t -> t
      StyledRun _ _ children -> plain children
      TransparentContainer _ _ children -> plain children
      _ -> ""

type Lowered = (Natural, [Value])

lowerSeq :: OverlayStep -> (SourceRef -> FigureInfo) -> Natural -> [ContentNode] -> Lowered
lowerSeq _ _ local [] = (local, [])
lowerSeq step figures local (next : rest) =
  let (local', here) = lowerNode step figures local next
      (local'', later) = lowerSeq step figures local' rest
   in (local'', here <> later)

visibleNow :: OverlayStep -> Natural -> Bool
visibleNow step local = overlayStepNumber step >= local

reserve :: Bool -> Value -> Value
reserve True value = value
reserve False value = object ["t" .= ("reserved" :: Text), "children" .= [value]]

tagged :: Text -> [Value] -> Value
tagged tag children = object ["t" .= tag, "children" .= children]

lowerNode :: OverlayStep -> (SourceRef -> FigureInfo) -> Natural -> ContentNode -> Lowered
lowerNode step figures local contentNode =
  case contentNode of
    OverlayPauseContent _ PauseNext -> (local + 1, [])
    OverlayPauseContent _ (PauseAt target) -> (overlayStepNumber target, [])
    -- \\only: hidden content takes no space (dropped, not reserved).
    OverlayContent hook [TransparentContainer _ (GenericContainer "only") children] ->
      let (local', inner) = lowerSeq step figures local children
       in (local', if overlayVisibleAt step hook then inner else [])
    -- \\alert: emphasised on its steps, plain on the others.
    OverlayContent hook [TransparentContainer _ (GenericContainer "alert") children] ->
      let (local', inner) = lowerSeq step figures local children
       in (local', if overlayVisibleAt step hook then [object ["t" .= ("colour" :: Text), "color" .= ("#c62828" :: Text), "children" .= inner]] else inner)
    -- \\invisible: hidden, keeping its space, on its steps; shown on the others.
    OverlayContent hook [TransparentContainer _ (GenericContainer "invisible") children] ->
      let (local', inner) = lowerSeq step figures local children
       in (local', if overlayVisibleAt step hook then [object ["t" .= ("reserved" :: Text), "children" .= inner]] else inner)
    OverlayContent hook children ->
      let (local', inner) = lowerSeq step figures local children
       in (local', gate hook inner)
    -- A pause nested inside a container (a paragraph, a column) still advances the
    -- step for everything after the container, as in Beamer.
    _ -> (foldl advance local (contentOverlayEvents (content [contentNode])), fmap (reserve (visibleNow step local)) (lowerLeaf step figures local contentNode))
  where
    advance l event = case event of
      ContentOverlayPause PauseNext -> l + 1
      ContentOverlayPause (PauseAt target) -> overlayStepNumber target
      _ -> l
    gate :: OverlayHook -> [Value] -> [Value]
    gate hook inner
      | overlayVisibleAt step hook = inner
      | otherwise = fmap (reserve False) inner

-- Lower one non-pause node. Children are lowered at the node's own local step.
lowerLeaf :: OverlayStep -> (SourceRef -> FigureInfo) -> Natural -> ContentNode -> [Value]
lowerLeaf step figures local contentNode =
  case contentNode of
    TextRun _ text -> [textValue text]
    StyledRun _ marks children ->
      [wrapMarks (toList marks) (kids children)]
    TransparentContainer _ kind children -> [lowerContainer kind children]
    ListContent _ kind items ->
      [tagged (listTag kind) (fmap itemValue (toList items))]
    OpaqueMath _ kind tex ->
      [ object
          [ "t" .= ("math" :: Text)
          , "display" .= (kind == DisplayMath)
          , "tex" .= tex
          , "label" .= tex
          ]
      ]
    ImageContent _ asset alt ->
      case figures <$> sourceRef (identifierText asset) of
        Just FigureUnknown -> [legacyImage]
        Just info -> [imageValue (identifierText asset) alt info]
        Nothing -> [legacyImage]
      where
        legacyImage = object ["t" .= ("image" :: Text), "src" .= identifierText asset, "alt" .= alt]
    IncludeContent _ _ _ ->
      [unsupportedValue "include"]
    TableContent _ (DerivedReady (TableModel rows aligns)) ->
      let rowValues = toList rows
          cellValue column (TableCell colSpan rowSpan body) =
            object
              [ "align" .= (case drop column aligns of ("r" : _) -> "r"; ("c" : _) -> "c"; _ -> "l" :: Text)
              , "colspan" .= colSpan
              , "rowspan" .= rowSpan
              , "children" .= kids body
              ]
          rowValue (TableRow cells) = [cellValue c cell | (c, cell) <- zip [0 ..] (toList cells)]
       in [ object
              [ "t" .= ("table" :: Text)
              , "head" .= fmap rowValue (take 1 rowValues)
              , "body" .= fmap rowValue (drop 1 rowValues)
              ]
          ]
    TableContent _ _ -> [unsupportedValue "table"]
    CitationContent _ _ (DerivedReady resolved) ->
      [tagged "cite" (kids (contentNodes resolved))]
    CitationContent _ keys _ ->
      [tagged "cite" [textValue (renderKeys keys)]]
    CompiledFigureContent _ ref _ -> [figureValue (figures ref)]
    LineBreak _ -> [object ["t" .= ("br" :: Text)]]
    UnsupportedContent (SourceBackedContent _ _ _) -> [unsupportedValue "unsupported content"]
    OverlayContent _ _ -> []
    OverlayPauseContent _ _ -> []
    CodeContent _ listing ->
      [ object
          [ "t" .= ("codeblock" :: Text)
          , "language" .= (if Text.null (listingLanguage listing) then Null else String (listingLanguage listing))
          , "lines" .= listingLines listing
          , "highlight" .= highlightLines (fromIntegral (overlayStepNumber step)) listing
          ]
      ]
  where
    kids children = snd (lowerSeq step figures local children)
    lowerContainer kind children =
      case kind of
        GenericContainer name
          | Just language <- Text.stripPrefix "codeblock:" name ->
              object
                [ "t" .= ("codeblock" :: Text)
                , "language" .= (if Text.null language then Null else String language)
                , "lines" .= [line | TextRun _ line <- children]
                , "highlight" .= Null
                ]
          | Just em <- Text.stripPrefix "vspace:" name ->
              object ["t" .= ("vspace" :: Text), "em" .= (maybe 0 fst (either (const Nothing) Just (TextRead.double em)) :: Double)]
          | Just title <- Text.stripPrefix "box:" name ->
              boxValue (if Text.null title then [] else [textValue title]) (kids children) ""
          | name == "p" || name == "paragraph" -> tagged "p" (kids children)
          | name == "quote" -> tagged "quote" (kids children)
          | name == "footnote" -> tagged "footnote" (kids children)
          | Just route <- Text.stripPrefix "route:" name ->
              object ["t" .= ("route" :: Text), "route" .= route, "children" .= kids children]
          | otherwise -> container kind (kids children)
        BoxContainer options ->
          let titleKids = concat [kids inner | TransparentContainer _ (GenericContainer "box-title") inner <- children]
              bodyKids = concat [kids inner | TransparentContainer _ (GenericContainer "box-body") inner <- children]
           in boxValue titleKids bodyKids options
        HeadingContainer level -> tagged ("h" <> Text.pack (show (max 1 (min 6 level)))) (kids children)
        FigureContainer _ -> case kids children of
          [single] -> single
          several -> tagged "div" several
        ColumnsContainer ->
          object
            [ "t" .= ("columns" :: Text)
            , "columns"
                .= [ object ["width" .= width, "children" .= snd (lowerSeq step figures local inner)]
                   | TransparentContainer _ columnKind inner <- children
                   , Just width <- [columnWidth columnKind]
                   ]
            ]
        _ -> container kind (kids children)
    columnWidth columnKind =
      case columnKind of
        ColumnContainer width -> Just (Text.strip width)
        GenericContainer name -> Text.drop 7 <$> (if "column:" `Text.isPrefixOf` name then Just name else Nothing)
        _ -> Nothing
    itemValue item =
      let inner = snd (lowerSeq step figures local (contentItemBody item))
          shown = overlayVisibleAt step (contentItemOverlay item)
       in reserve shown (tagged "li" inner)

listTag :: ListKind -> Text
listTag UnorderedList = "ul"
listTag OrderedList = "ol"

boxValue :: [Value] -> [Value] -> Text -> Value
boxValue title body options =
  object
    [ "t" .= ("box" :: Text)
    , "title" .= (if null title then Null else Array (fromList title))
    , "fill" .= (case literalFill of Just c -> c; Nothing -> if alert then "#fdecea" else "#e9eefc" :: Text)
    , "titleFill" .= (if alert then "#b3261e" else "#2962ff" :: Text)
    , "children" .= body
    ]
  where
    alert = "alert" `Text.isInfixOf` options
    literalFill = case Text.breakOn "fill=#" options of
      (_, rest) | not (Text.null rest) -> Just (Text.take 7 (Text.drop 5 rest))
      _ -> Nothing

-- Highlighted line numbers of a listing at a step.
highlightLines :: Int -> Listing -> Value
highlightLines step listing =
  case concat [[from .. to] | LineRange from to <- highlightedAt step (listingHighlight listing)] of
    [] -> Null
    numbers -> Array (fromList (fmap (Number . fromIntegral) numbers))

container :: ContainerKind -> [Value] -> Value
container kind children =
  case kind of
    ColumnsContainer -> object ["t" .= ("columns" :: Text), "columns" .= [object ["width" .= Null, "children" .= children]]]
    GenericContainer name -> object ["t" .= ("div" :: Text), "class" .= name, "children" .= children]
    MatrixContainer -> object ["t" .= ("div" :: Text), "class" .= ("matrix" :: Text), "children" .= children]
    TableContainer -> object ["t" .= ("div" :: Text), "class" .= ("table" :: Text), "children" .= children]
    BoxContainer name -> object ["t" .= ("div" :: Text), "class" .= ("box " <> name), "children" .= children]
    FigureContainer name -> object ["t" .= ("div" :: Text), "class" .= ("figure " <> name), "children" .= children]
    ColumnContainer name -> object ["t" .= ("div" :: Text), "class" .= ("column " <> name), "children" .= children]
    HeadingContainer level -> object ["t" .= ("div" :: Text), "class" .= ("heading-" <> Text.pack (show level)), "children" .= children]

wrapMarks :: [InlineMark] -> [Value] -> Value
wrapMarks [] children = tagged "span" children
wrapMarks (mark : rest) children = foldl (\inner next -> wrapMark next [inner]) (wrapMark mark children) rest

wrapMark :: InlineMark -> [Value] -> Value
wrapMark mark inner =
  case mark of
    Strong -> tagged "strong" inner
    Emphasis -> tagged "em" inner
    InlineCode -> tagged "code" inner
    Underline -> tagged "u" inner
    Strike -> tagged "s" inner
    Highlight -> tagged "mark" inner
    LinkTarget href -> object ["t" .= ("link" :: Text), "href" .= href, "children" .= inner]
    InlineColour colour -> object ["t" .= ("colour" :: Text), "color" .= colour, "children" .= inner]

textValue :: Text -> Value
textValue text =
  object
    [ "t" .= ("text" :: Text)
    , "text" .= text
    , "bold" .= False
    , "italic" .= False
    , "mono" .= False
    , "color" .= Null
    ]

renderKeys :: NonEmpty CitationKey -> Text
renderKeys keys = "[" <> Text.intercalate "," (fmap identifierText (toList keys)) <> "]"

unsupportedValue :: Text -> Value
unsupportedValue label =
  object ["t" .= ("unsupported" :: Text), "label" .= label]

figureValue :: FigureInfo -> Value
figureValue info =
  case info of
    FigureReady fingerprint width height ->
      object
        [ "t" .= ("figure" :: Text)
        , "fingerprint" .= fingerprint
        , "width" .= width
        , "height" .= height
        ]
    FigureDrawn value -> value
    FigureImage mime bytes width height -> imageValue "" "" (FigureImage mime bytes width height)
    FigureImageRef mime ref width height -> imageValue "" "" (FigureImageRef mime ref width height)
    FigureUnknown -> placeholder "pending" "" "Figure"
    FigurePending fingerprint -> placeholder "pending" fingerprint "Compiling figure"
    FigureFailed fingerprint message -> placeholder "error" fingerprint message
    FigureAbsent fingerprint message -> placeholder "absent" fingerprint message

placeholder :: Text -> Text -> Text -> Value
placeholder state fingerprint label =
  object
    [ "t" .= ("placeholder" :: Text)
    , "state" .= state
    , "fingerprint" .= fingerprint
    , "label" .= label
    ]

-- An embedded image sized in slide units; any other state is a placeholder.
imageValue :: Text -> Text -> FigureInfo -> Value
imageValue src alt info =
  case info of
    FigureImage mime bytes width height ->
      object
        [ "t" .= ("image" :: Text)
        , "src" .= src
        , "alt" .= alt
        , "mime" .= mime
        , "bytesBase16" .= bytes
        , "width" .= width
        , "height" .= height
        ]
    FigureImageRef mime ref width height ->
      object
        [ "t" .= ("image" :: Text)
        , "src" .= src
        , "alt" .= alt
        , "mime" .= mime
        , "bytesRef" .= ref
        , "width" .= width
        , "height" .= height
        ]
    other -> figureValue other
