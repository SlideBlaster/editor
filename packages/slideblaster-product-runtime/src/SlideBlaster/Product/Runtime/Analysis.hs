{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Product.Runtime.Analysis
-- Description : The seam between deck analysis (format, flow desugaring) and the session.
--
-- The session state machine never parses deck bytes itself. An 'Analyzer' turns
-- exact deck bytes plus the other project files into frames, diagnostics and
-- block-render requests, and performs the one deterministic structural edit the
-- session offers (new slide). The production analyzer composes the deck,
-- syntax, canvas and presentation packages; tests supply small stand-ins.
module SlideBlaster.Product.Runtime.Analysis
  ( Analyzer (..)
  , Analysis (..)
  , AnalyzedFrame (..)
  , FrameOrigin (..)
  , Subsection (..)
  , FigureRequest (..)
  , ImageRequest (..)
  , DiagnosticItem (..)
  , routeDiagnostics
  ) where

import SlideBlaster.Canvas (Content, SourceRef)
import SlideBlaster.Presentation.Route qualified as Route
import SlideBlaster.Product.Runtime.SlidePlan (FrameInput)

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Text (Text)

-- | One diagnostic as projected on the wire (spans are UTF-8 byte offsets).
data DiagnosticItem = DiagnosticItem
  { diagnosticSeverity :: !Text
  , diagnosticCode :: !Text
  , diagnosticMessage :: !Text
  , diagnosticSpan :: !(Maybe (Int, Int))
  , diagnosticFrame :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | A block (figure) the provider must render.
data FigureRequest = FigureRequest
  { figureFrame :: !Text
  , figureRef :: !SourceRef
  , figureKind :: !Text
  , figureBody :: !ByteString
  , figureInputPath :: !(Maybe Text)
  , figurePreamble :: !ByteString
  , figurePalette :: ![(Text, Text)]
  , figureWidth :: !Double
  , figureInputs :: ![Text]
  , figureFirstLine :: !Int
  , figureUnits :: !(Maybe Double)
  -- ^ requested display width in slide units (@\\figure[width=W]@), if any
  }
  deriving stock (Eq, Show)

-- | A project image file referenced from deck content. The host paints bytes
-- the core embeds, so the core resolves the handle to the path itself.
data ImageRequest = ImageRequest
  { imageFrame :: !Text
  , imageRef :: !SourceRef
  -- ^ the content handle (@slide-x-image-1@)
  , imagePath :: !Text
  , imageUnits :: !(Maybe Double)
  -- ^ requested display width in slide units, if any
  , imageLine :: !Int
  -- ^ one-based line within the slide flow text
  }
  deriving stock (Eq, Show)

data AnalyzedFrame = AnalyzedFrame
  { frameKey :: !Text
  , frameTitleText :: !Text
  , frameSpan :: !(Int, Int)
  , frameScene :: !FrameInput
  , frameNotes :: !Content
  , frameOrigin :: !(Maybe FrameOrigin)
  -- ^ set on a slide spliced in from an included deck: it is read-only here
  }

-- | The included deck a slide comes from.
data FrameOrigin = FrameOrigin
  { originDeck :: !Text
  -- ^ the deck's namespace (its folder name or file stem)
  , originPath :: !Text
  -- ^ its deck file, relative to the including project's folder (@../talk/talk.slideBlaster.md@)
  }
  deriving stock (Eq, Show)

-- | A section of an included deck, shown under the parent section that holds
-- the include (or at top level when the include is outside every section).
data Subsection = Subsection
  { subId :: !Text
  , subTitle :: !Text
  , subParent :: !(Maybe Text)
  , subFrames :: ![Text]
  , subDeck :: !Text
  }
  deriving stock (Eq, Show)

data Analysis = Analysis
  { analysisTitle :: !Text
  , analysisTheme :: !Text
  , analysisFrames :: ![AnalyzedFrame]
  , analysisDiagnostics :: ![DiagnosticItem]
  , analysisFigures :: ![FigureRequest]
  , analysisImages :: ![ImageRequest]
  , analysisReady :: !Bool
  , analysisSections :: ![Route.Section]
  -- ^ sections (@# Title {#id}@) with their frames, in file order
  , analysisSubsections :: ![Subsection]
  -- ^ sections of included decks, nested under the parent section
  , analysisRoutes :: ![(Text, [Text])]
  -- ^ frontmatter @routes:@: route name to section ids; the first is the default
  }

data Analyzer = Analyzer
  { analyzeDeck :: Map Text ByteString -> Text -> ByteString -> Analysis
  -- ^ project files (excluding the deck), entry path, exact deck bytes
  , insertSlideAfter :: ByteString -> Maybe Text -> Maybe (ByteString, Text)
  -- ^ deck bytes, frame to insert after; new bytes and the minted frame id
  }

-- | Diagnostics for sections, routes and @\\route@ choices. The span function
-- locates a route's line in the frontmatter (the first argument is its
-- fallback, the frontmatter itself).
routeDiagnostics :: Maybe (Int, Int) -> (Text -> Maybe (Int, Int)) -> [Route.Section] -> [(Text, [Text])] -> [(Text, Text)] -> [DiagnosticItem]
routeDiagnostics fallback spanOf sections routes choices =
  fmap issue (Route.validateRoutes (fmap Route.sectionId sections) routes)
    <> [ DiagnosticItem "error" "route.unknown-choice" ("\\route names route " <> name <> ", which the frontmatter does not define") Nothing (Just frame)
       | (frame, name) <- choices
       , name `notElem` fmap fst routes
       ]
  where
    at name severity code message = DiagnosticItem severity code message (maybe fallback Just (spanOf name)) Nothing
    issue i = case i of
      Route.UnknownSection r s -> at r "error" "route.unknown-section" ("route " <> r <> " lists " <> s <> ", which is not a section id")
      Route.MissingSection r s -> at r "warning" "route.missing-section" ("route " <> r <> " never visits section " <> s)
      Route.DuplicateRoute r -> at r "error" "route.duplicate" ("route " <> r <> " is defined twice")
      Route.DuplicateEntry r s -> at r "error" "route.duplicate-entry" ("route " <> r <> " lists section " <> s <> " more than once")
