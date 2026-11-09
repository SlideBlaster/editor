-- |
-- Module      : SlideBlaster.Adapter.Web
-- Description : Public browser capability surface for the Wasm composition.
--
-- Every browser effect available to Haskell is re-exported from this module.
-- The individual capability modules delegate to the single versioned host-call
-- boundary.
module SlideBlaster.Adapter.Web
  ( module SlideBlaster.Adapter.Web.HostCall
  , module SlideBlaster.Adapter.Web.Log
  , module SlideBlaster.Adapter.Web.Measure
  , module SlideBlaster.Adapter.Web.Storage
  , module SlideBlaster.Adapter.Web.String
  ) where

import SlideBlaster.Adapter.Web.HostCall
import SlideBlaster.Adapter.Web.Log
import SlideBlaster.Adapter.Web.Measure
import SlideBlaster.Adapter.Web.Storage
import SlideBlaster.Adapter.Web.String
