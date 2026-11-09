{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Extension.Slot
-- Description : The closed registry of extension slots.
--
-- Slots are a closed sum: the core owns the request and result types of every
-- slot, and a provider owns only the effect. Alpha executes 'BlockRender' only;
-- 'BlockEdit' is interface-only (a manifest may declare it, the broker never
-- dispatches it) so later editable providers need no format change.
module SlideBlaster.Extension.Slot
  ( Slot (..)
  , SlotStatus (..)
  , allSlots
  , parseSlot
  , slotName
  , slotStatus
  ) where

import Data.Text (Text)

-- | An extension point of the product.
data Slot
  = BlockRender
  | BlockEdit
  | ContentHost
  | Capability
  | ExportTarget
  | UiContribution
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Whether alpha dispatches requests for a slot.
data SlotStatus = Dispatched | InterfaceOnly
  deriving (Eq, Show)

-- | Every slot, in declaration order.
allSlots :: [Slot]
allSlots = [minBound .. maxBound]

-- | The wire name, for example @block.render@.
slotName :: Slot -> Text
slotName slot = case slot of
  BlockRender -> "block.render"
  BlockEdit -> "block.edit"
  ContentHost -> "content.host"
  Capability -> "capability"
  ExportTarget -> "export.target"
  UiContribution -> "ui.contribution"

-- | Inverse of 'slotName'; unknown names are rejected.
parseSlot :: Text -> Maybe Slot
parseSlot name = lookup name [(slotName slot, slot) | slot <- allSlots]

-- | Alpha dispatch status of a slot.
slotStatus :: Slot -> SlotStatus
slotStatus slot = case slot of
  BlockRender -> Dispatched
  _ -> InterfaceOnly
