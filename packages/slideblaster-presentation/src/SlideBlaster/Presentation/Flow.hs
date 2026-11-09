{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Presentation.Flow
-- Description : Frames from desugared flow content: audience scene and notes scene.
--
-- "SlideBlaster.Canvas.Flow" lowers a slide's flow body and picture block to
-- layer entries. This module assembles them into one 'Frame': the audience scene
-- (flow region nodes with picture nodes layered above) and, when the slide has
-- notes, a separate notes scene. Beats come from the audience scene alone
-- ("SlideBlaster.Presentation.Model"), so notes can never add a beat, even when
-- they contain @\\pause@ or overlay specs.
module SlideBlaster.Presentation.Flow
  ( FlowFrameError (..)
  , slideFrame
  , deckPresentation
  ) where

import SlideBlaster.Canvas qualified as Canvas
import SlideBlaster.Presentation.Animation (ReducedMotionPolicy (CompleteImmediately), emptyAnimationTimeline)
import SlideBlaster.Presentation.Model
  ( Frame
  , FrameId
  , Presentation
  , PresentationError
  , mkAspectRatio
  , mkFrame
  , mkFrameMetadata
  , mkNotes
  , mkPresentation
  , mkPresentationMetadata
  , noSlideRotation
  )
import SlideBlaster.Presentation.Scene (mkScene)

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Numeric.Natural (Natural)

-- | Why a frame or presentation could not be assembled.
data FlowFrameError
  = FlowPictureInvalid !Canvas.PictureError
  | FlowSceneInvalid
  | FlowAspectInvalid
  | FlowPresentationInvalid !PresentationError
  deriving stock (Eq, Show)

-- | Assemble one frame. The title is the navigation title; the second list is the
-- audience scene's layers (flow region nodes first, picture nodes above), the
-- third the notes scene's layers (empty means no notes).
slideFrame
  :: FrameId
  -> Text
  -> [Canvas.LayerEntry]
  -> [Canvas.LayerEntry]
  -> Either FlowFrameError Frame
slideFrame identity title audience notes = do
  audiencePicture <- either (Left . FlowPictureInvalid) Right (Canvas.mkPicture audience)
  audienceScene <- either (const (Left FlowSceneInvalid)) Right (mkScene audiencePicture emptyAnimationTimeline)
  notesValue <-
    if null notes
      then Right Nothing
      else do
        notesPicture <- either (Left . FlowPictureInvalid) Right (Canvas.mkPicture notes)
        noteScene <- either (const (Left FlowSceneInvalid)) Right (mkScene notesPicture emptyAnimationTimeline)
        Right (Just (mkNotes noteScene))
  Right (mkFrame identity (mkFrameMetadata title noSlideRotation) audienceScene notesValue)

-- | Assemble the presentation from its frames.
deckPresentation
  :: Text
  -> (Natural, Natural)
  -> Canvas.Theme
  -> NonEmpty Frame
  -> Either FlowFrameError Presentation
deckPresentation title (width, height) theme frames = do
  aspect <- either (const (Left FlowAspectInvalid)) Right (mkAspectRatio width height)
  either
    (Left . FlowPresentationInvalid)
    Right
    (mkPresentation (mkPresentationMetadata title aspect theme CompleteImmediately) frames)
