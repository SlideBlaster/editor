-- |
-- Module      : SlideBlaster.App.Navigation
-- Description : Stable-frame deck navigation independent of browser hosts.
--
-- Navigation is keyed by frame identity rather than array position. Switching
-- frames is source-neutral; callers reset document-relative selection and
-- gestures and select the correlated active audience paint.
module SlideBlaster.App.Navigation
  ( NavigationEntry (..)
  , DeckNavigation
  , navigationFromPresentation
  , reconcileNavigation
  , navigationEntries
  , navigationActiveFrame
  , navigationActiveIndex
  , navigationPrevious
  , navigationNext
  , navigationSelect
  , navigationCanPrevious
  , navigationCanNext
  ) where

import SlideBlaster.Presentation qualified as Presentation

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)

-- | Closed navigator row.
data NavigationEntry = NavigationEntry
  { navigationEntryFrame :: !Presentation.FrameId
  , navigationEntryTitle :: !Text
  }
  deriving stock (Eq, Show)

data DeckNavigation = DeckNavigation !(NonEmpty NavigationEntry) !Presentation.FrameId
  deriving stock (Eq, Show)

navigationFromPresentation :: Presentation.Presentation -> DeckNavigation
navigationFromPresentation presentation =
  let entries = fmap frameEntry (Presentation.presentationFrames presentation)
      first :| _ = entries
   in DeckNavigation entries (navigationEntryFrame first)

reconcileNavigation :: Maybe Presentation.FrameId -> Presentation.Presentation -> DeckNavigation
reconcileNavigation preferred presentation =
  let DeckNavigation entries fallback = navigationFromPresentation presentation
   in case preferred of
        Just wanted | any ((== wanted) . navigationEntryFrame) (NonEmpty.toList entries) -> DeckNavigation entries wanted
        _ -> DeckNavigation entries fallback

navigationEntries :: DeckNavigation -> NonEmpty NavigationEntry
navigationEntries (DeckNavigation entries _) = entries

navigationActiveFrame :: DeckNavigation -> Presentation.FrameId
navigationActiveFrame (DeckNavigation _ active) = active

navigationActiveIndex :: DeckNavigation -> Int
navigationActiveIndex (DeckNavigation entries active) = go 0 (NonEmpty.toList entries)
  where
    go index values = case values of
      [] -> 0
      entry : _ | navigationEntryFrame entry == active -> index
      _ : remaining -> go (index + 1) remaining

navigationPrevious :: DeckNavigation -> DeckNavigation
navigationPrevious navigation@(DeckNavigation entries _) =
  navigationSelectIndex (max 0 (navigationActiveIndex navigation - 1)) entries

navigationNext :: DeckNavigation -> DeckNavigation
navigationNext navigation@(DeckNavigation entries _) =
  navigationSelectIndex (min (NonEmpty.length entries - 1) (navigationActiveIndex navigation + 1)) entries

navigationSelect :: Presentation.FrameId -> DeckNavigation -> DeckNavigation
navigationSelect wanted navigation@(DeckNavigation entries _)
  | any ((== wanted) . navigationEntryFrame) (NonEmpty.toList entries) = DeckNavigation entries wanted
  | otherwise = navigation

navigationCanPrevious :: DeckNavigation -> Bool
navigationCanPrevious navigation = navigationActiveIndex navigation > 0

navigationCanNext :: DeckNavigation -> Bool
navigationCanNext navigation@(DeckNavigation entries _) = navigationActiveIndex navigation + 1 < NonEmpty.length entries

navigationSelectIndex :: Int -> NonEmpty NavigationEntry -> DeckNavigation
navigationSelectIndex wanted entries =
  case drop wanted (NonEmpty.toList entries) of
    entry : _ -> DeckNavigation entries (navigationEntryFrame entry)
    [] -> let first :| _ = entries in DeckNavigation entries (navigationEntryFrame first)

frameEntry :: Presentation.Frame -> NavigationEntry
frameEntry frame = NavigationEntry (Presentation.frameId frame) (Presentation.frameTitle frame)
