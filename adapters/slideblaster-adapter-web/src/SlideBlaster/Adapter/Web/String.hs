-- |
-- Module      : SlideBlaster.Adapter.Web.String
-- Description : JSFFI string marshalling at the Wasm executable boundary.
--
-- Re-exporting the 'JSString' constructor lets the composition root declare
-- static JSFFI exports without importing @GHC.Wasm.Prim@ itself.
module SlideBlaster.Adapter.Web.String
  ( JSString (..)
  , fromWebString
  , toWebString
  ) where

import GHC.Wasm.Prim (JSString (..), fromJSString, toJSString)

import Data.Text (Text)
import qualified Data.Text as Text

fromWebString :: JSString -> Text
fromWebString = Text.pack . fromJSString

toWebString :: Text -> JSString
toWebString = toJSString . Text.unpack
