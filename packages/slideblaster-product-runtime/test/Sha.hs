module Main (main) where

import SlideBlaster.Product.Runtime.Sha256 (sha256Hex)

import Control.Monad (unless)
import Data.ByteString.Char8 qualified as Char8
import System.Exit (exitFailure)

main :: IO ()
main = do
  check "empty" "" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  check "abc" "abc" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  check "two blocks" "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
  check "million a" (replicate 1000000 'a') "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
  putStrLn "PASS: sha256 vectors"
  where
    check name input expected =
      unless (sha256Hex (Char8.pack input) == expected) (putStrLn ("FAIL: " <> name) >> exitFailure)
