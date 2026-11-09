{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Adapter.Native.Tex
-- Description : The native @sb.tex@ provider: TeX to SVG in a throwaway directory.
--
-- Builds the standalone document with the shared request builder, writes it and
-- the resolved @\\input@ closure into a fresh temporary directory outside the
-- project, then runs
--
-- > latex -interaction=nonstopmode -halt-on-error -no-shell-escape figure.tex
-- > dvisvgm --no-fonts --exact-bbox -o figure.svg figure.dvi
--
-- under the manifest's timeout and size limits. A TeX failure becomes one
-- diagnostic carrying the first @! ...@ line of the log and the figure source
-- line recovered from the @%%sb-line@ markers. The resulting SVG is sanitised.
-- The temporary directory is always removed.
module SlideBlaster.Adapter.Native.Tex
  ( TexConfig (..)
  , runTex
  ) where

import SlideBlaster.Adapter.Native.Process
import SlideBlaster.Adapter.Native.Provider
import SlideBlaster.Adapter.Native.Sanitize (sanitizeSvg)
import SlideBlaster.Extension

import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.Encoding.Error qualified as Encoding
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory
  ( createDirectory
  , createDirectoryIfMissing
  , doesFileExist
  , removePathForcibly
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isAlreadyExistsError, tryIOError)
import System.Process (getCurrentPid)

-- | Where the tools are and what the run may consume.
data TexConfig = TexConfig
  { texLatex :: !FilePath
  , texDvisvgm :: !FilePath
  , texTempRoot :: !FilePath
  , texTimeoutMs :: !Int
  , texMaxBytes :: !Int
  }

-- | Compile a @tikz@ or @tex@ block to SVG bytes.
runTex :: TexConfig -> BlockRequest -> IO ProviderOutcome
runTex config request =
  bracket (makeWorkDirectory (texTempRoot config)) removePathForcibly $ \work -> do
    let document = buildTikzDocument request
    writeResult <- tryIOError $ do
      ByteString.writeFile (work </> "figure.tex") (Encoding.encodeUtf8 document)
      mapM_ (writeInput work) (requestInputs request)
    case writeResult of
      Left problem -> pure (ProviderFailed [plainError "io.error" (Text.pack (show problem))])
      Right () -> do
        latex <-
          runLimited
            RunSpec
              { runExecutable = texLatex config
              , runArguments = ["-interaction=nonstopmode", "-halt-on-error", "-no-shell-escape", "figure.tex"]
              , runWorkingDirectory = Just work
              , runStdin = ByteString.empty
              , runTimeoutMs = texTimeoutMs config
              , runMaxStdout = 16777216
              }
        case latex of
          RunSpawnFailed why -> pure (ProviderFailed [plainError "spawn.failed" why])
          RunTimedOut -> pure (ProviderAbsent (TimedOut "sb.tex" (texTimeoutMs config)))
          RunTooLarge -> pure (ProviderAbsent (LimitExceeded "sb.tex" (texMaxBytes config)))
          RunExited (ExitFailure _) out _ -> texFailure work document request out
          RunExited ExitSuccess _ _ -> convert work
  where
    convert work = do
      svg <-
        runLimited
          RunSpec
            { runExecutable = texDvisvgm config
            , runArguments = ["--no-fonts", "--exact-bbox", "-o", "figure.svg", "figure.dvi"]
            , runWorkingDirectory = Just work
            , runStdin = ByteString.empty
            , runTimeoutMs = texTimeoutMs config
            , runMaxStdout = 16777216
            }
      case svg of
        RunSpawnFailed why -> pure (ProviderFailed [plainError "spawn.failed" why])
        RunTimedOut -> pure (ProviderAbsent (TimedOut "sb.tex" (texTimeoutMs config)))
        RunTooLarge -> pure (ProviderAbsent (LimitExceeded "sb.tex" (texMaxBytes config)))
        RunExited (ExitFailure _) out err ->
          pure (ProviderFailed [plainError "dvisvgm.error" (firstLine (Encoding.decodeUtf8With Encoding.lenientDecode (err <> out)))])
        RunExited ExitSuccess _ _ -> do
          present <- doesFileExist (work </> "figure.svg")
          if not present
            then pure (ProviderFailed [plainError "dvisvgm.error" "dvisvgm produced no output"])
            else do
              bytes <- ByteString.readFile (work </> "figure.svg")
              if ByteString.length bytes > texMaxBytes config
                then pure (ProviderAbsent (LimitExceeded "sb.tex" (texMaxBytes config)))
                else
                  pure . ProviderArtifact . Encoding.encodeUtf8 . sanitizeSvg $
                    Encoding.decodeUtf8With Encoding.lenientDecode bytes

writeInput :: FilePath -> ResolvedInput -> IO ()
writeInput work input
  | isSafeRelativePath (inputPath input) = do
      let target = work </> Text.unpack (inputPath input)
      createDirectoryIfMissing True (takeDirectory target)
      ByteString.writeFile target (inputBytes input)
  | otherwise = pure ()

-- Turn a failed latex run into a located diagnostic.
texFailure :: FilePath -> Text -> BlockRequest -> ByteString -> IO ProviderOutcome
texFailure work document request stdout = do
  let logPath = work </> "figure.log"
  haveLog <- doesFileExist logPath
  logBytes <- if haveLog then ByteString.readFile logPath else pure stdout
  let logText = Encoding.decodeUtf8With Encoding.lenientDecode logBytes
      stdoutText = Encoding.decodeUtf8With Encoding.lenientDecode stdout
      parsed = case parseTexLog logText of
        Just e -> Just e
        Nothing -> parseTexLog stdoutText
      message = maybe (lastNonEmpty stdoutText) texErrorMessage parsed
      texLine = parsed >>= texErrorLine
      bodyLine = texLine >>= mapTexLine document
      firstLine' = maybe 1 lineMapFirstLine (requestLineMap request)
  pure . ProviderFailed $
    [ Diagnostic
        { diagnosticSeverity = SeverityError
        , diagnosticCode = "tex.error"
        , diagnosticMessage = message
        , diagnosticTexLine = texLine
        , diagnosticSourceLine = (\n -> n + firstLine' - 1) <$> bodyLine
        , diagnosticFile = lineMapFile <$> requestLineMap request
        }
    ]

plainError :: Text -> Text -> Diagnostic
plainError code message = Diagnostic SeverityError code message Nothing Nothing Nothing

firstLine :: Text -> Text
firstLine t = case filter (not . Text.null) (Text.strip <$> Text.lines t) of
  l : _ -> l
  [] -> "unknown error"

lastNonEmpty :: Text -> Text
lastNonEmpty t = case reverse (filter (not . Text.null) (Text.strip <$> Text.lines t)) of
  l : _ -> l
  [] -> "latex failed"

-- A fresh, uniquely named directory under the temp root (outside the project).
makeWorkDirectory :: FilePath -> IO FilePath
makeWorkDirectory root = do
  createDirectoryIfMissing True root
  pid <- getCurrentPid
  go pid (0 :: Int)
  where
    go pid attempt = do
      now <- getMonotonicTimeNSec
      let candidate = root </> ("sb-tex-" <> show pid <> "-" <> show now <> "-" <> show attempt)
      created <- tryIOError (createDirectory candidate)
      case created of
        Right () -> pure candidate
        Left problem
          | isAlreadyExistsError problem && attempt < 50 -> go pid (attempt + 1)
          | otherwise -> ioError problem
