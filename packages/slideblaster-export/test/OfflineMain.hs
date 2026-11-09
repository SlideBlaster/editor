{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Offline HTML export is deterministic, inert and network-free.
module Main (main) where

import SlideBlaster.Export.Offline

import Control.Monad (unless)
import Data.Aeson (object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Char8
import System.Exit (exitFailure)

main :: IO ()
main = do
  let deck = object ["title" .= ("A </script><b>deck" :: String), "slides" .= ([] :: [Int])]
      assets = offlineAssets "console.log('</script>');" "body{}</style>"
      page = exportDeckHtml assets deck
  check "deterministic" (page == exportDeckHtml assets deck)
  check "title escaped" ("<title>A &lt;/script&gt;&lt;b&gt;deck</title>" `isIn` page)
  check "exactly two script elements and one style" (count "<script" page == 2 && count "</script>" page == 2 && count "</style>" page == 1)
  check "payload inert" (not ("</script><b>" `isIn` page))
  check "no network references from the wrapper" (not ("http://" `isIn` page) && not ("https://" `isIn` page))
  check "viewer mount point present" ("id=\"sb-viewer\"" `isIn` page)
  let printed = exportDeckHtml assets {offlinePrint = Just (OfflinePrint True), offlineThemeStyle = "p{color:red}"} deck
  check "print config emitted" ("id=\"sb-print\" type=\"application/json\">{\"steps\":true}" `isIn` printed)
  check "theme style inlined" ("p{color:red}" `isIn` printed && count "</style>" printed == 1)
  check "no print config by default" (not ("sb-print" `isIn` page))
  let resolve p = if p == "f.woff2" then Just "data:font/woff2;base64,YWJj" else Nothing
  check "css url inlined" (inlineCssUrls resolve "a{src:url('f.woff2') format(x)}" == "a{src:url(data:font/woff2;base64,YWJj) format(x)}")
  check "css url left alone" (inlineCssUrls resolve "a{b:url(g.png) url(data:x) url(\"http://h/f.woff2\")}" == "a{b:url(g.png) url(data:x) url(\"http://h/f.woff2\")}")
  putStrLn "PASS: offline html"
  where
    check name ok = unless ok (putStrLn ("FAIL: " <> name) >> exitFailure)
    isIn needle hay = count needle hay > 0
    count :: ByteString -> ByteString -> Int
    count needle hay = length (Char8.breakSubstring needle hay `seq` splits needle hay) - 1
    splits needle hay =
      let (a, b) = Char8.breakSubstring needle hay
       in if Char8.null b then [a] else a : splits needle (Char8.drop (Char8.length needle) b)
