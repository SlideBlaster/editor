{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty (..))
import SlideBlaster.Document
import SlideBlaster.Source
  ( snapshotBytes
  , snapshotFromBytes
  , sourceSpanFromInts
  )
import System.Exit (exitFailure)

main :: IO ()
main = do
  results <-
    sequence
      [ check "ready snapshots retain exact source and meaning" readyLaw
      , check "syntax-only snapshots retain exact source and diagnostics" syntaxOnlyLaw
      , check "provenance distinguishes direct and read-only fields" provenanceLaw
      , check "machine codes and projection rules reject empty names" nonEmptyNamesLaw
      ]
  if and results then pure () else exitFailure

check :: String -> Bool -> IO Bool
check name passed = do
  putStrLn ((if passed then "PASS " else "FAIL ") <> name)
  pure passed

readyLaw :: Bool
readyLaw =
  case (mkDiagnosticCode "SB-DOC-WARN", mkProjectionRule "move-node", sourceSpanFromInts 0 3) of
    (Just code, Just rule, Just spanValue) ->
      let source = snapshotFromBytes "abc"
          warning =
            mkDiagnostic
              DiagnosticWarning
              SyntaxUnsupported
              code
              "retained warning"
              (Just spanValue)
          provenance =
            provenanceFromList
              [ ("node.x" :: String, DirectSlot spanValue rule)
              ]
          document =
            readyDocument source ("syntax" :: String) (42 :: Int) provenance [warning]
       in snapshotBytes (documentSource document) == "abc"
            && documentSyntax document == "syntax"
            && documentSemantic document == Just 42
            && documentProvenance document == Just provenance
            && documentDiagnostics document == [warning]
    _ -> False

syntaxOnlyLaw :: Bool
syntaxOnlyLaw =
  case mkDiagnosticCode "SB-DOC-PARSE" of
    Nothing -> False
    Just code ->
      let source = snapshotFromBytes "{"
          failure =
            mkDiagnostic
              DiagnosticError
              SyntaxMalformed
              code
              "unclosed group"
              Nothing
          document =
            syntaxOnlyDocument
              source
              ("recovered-syntax" :: String)
              (failure :| [])
              :: DocumentSnapshot String String Int
       in snapshotBytes (documentSource document) == "{"
            && documentSemantic document == Nothing
            && documentProvenance document == Nothing
            && documentDiagnostics document == [failure]
            && isHardDiagnostic failure

provenanceLaw :: Bool
provenanceLaw =
  case (mkProjectionRule "move-node", sourceSpanFromInts 1 2) of
    (Just rule, Just spanValue) ->
      let provenance =
            insertOrigin
              ("opaque" :: String)
              (ReadOnly UnsupportedSyntax (Just spanValue))
              ( insertOrigin
                  "node.x"
                  (DirectSlot spanValue rule)
                  emptyProvenanceMap
              )
       in lookupOrigin "node.x" provenance == Just (DirectSlot spanValue rule)
            && lookupOrigin "opaque" provenance
              == Just (ReadOnly UnsupportedSyntax (Just spanValue))
            && length (provenanceToList provenance) == 2
    _ -> False

nonEmptyNamesLaw :: Bool
nonEmptyNamesLaw =
  mkDiagnosticCode "   " == Nothing
    && mkProjectionRule "" == Nothing

