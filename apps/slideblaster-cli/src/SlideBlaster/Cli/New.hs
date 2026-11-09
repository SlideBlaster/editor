{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Cli.New
-- Description : @sb new@: scaffold a sample deck project.
--
-- Creates a folder holding a small deck in the @slideblaster: 1@ container, a
-- sample TikZ figure, and a @.gitignore@ that excludes the extension cache
-- (@.slideblaster/cache/@). Never overwrites: a non-empty target directory is
-- refused.
module SlideBlaster.Cli.New
  ( NewError (..)
  , scaffoldProject
  , sampleDeckName
  , gitignoreText
  ) where

import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  )
import System.FilePath (takeFileName, (</>))
import System.IO.Error (tryIOError)

-- | Why scaffolding was refused.
data NewError
  = TargetNotEmpty !FilePath
  | TargetIsFile !FilePath
  | NewIoError !FilePath !Text
  deriving (Eq, Show)

-- | The deck file written into a new project.
sampleDeckName :: FilePath
sampleDeckName = "talk.slideBlaster.md"

-- | Contents of the generated @.gitignore@.
gitignoreText :: Text
gitignoreText = ".slideblaster/cache/\n"

-- | Write the sample project; returns the files created (relative paths).
scaffoldProject :: FilePath -> IO (Either NewError [FilePath])
scaffoldProject dir = do
  isFile <- doesFileExist dir
  isDir <- doesDirectoryExist dir
  if isFile
    then pure (Left (TargetIsFile dir))
    else do
      occupied <- if isDir then not . null <$> listDirectory dir else pure False
      if occupied
        then pure (Left (TargetNotEmpty dir))
        else do
          written <- tryIOError (mapM write files)
          pure $ case written of
            Left problem -> Left (NewIoError dir (Text.pack (show problem)))
            Right names -> Right names
  where
    files =
      [ (sampleDeckName, sampleDeck (takeFileName' dir))
      , ("figures/pipeline.tikz", sampleFigure)
      , (".gitignore", gitignoreText)
      ]
    write (name, content) = do
      let path = dir </> name
      createDirectoryIfMissing True (dir </> parentOf name)
      ByteString.writeFile path (Encoding.encodeUtf8 content)
      pure name
    parentOf name = reverse (drop 1 (dropWhile (/= '/') (reverse name)))
    takeFileName' d = case takeFileName (stripTrailing d) of
      "" -> "Untitled talk"
      n -> Text.pack n
    stripTrailing = reverse . dropWhile (== '/') . reverse

sampleDeck :: Text -> Text
sampleDeck title =
  Text.unlines
    [ "---"
    , "slideblaster: 1"
    , "title: " <> title
    , "---"
    , ""
    , "## " <> title <> " {#title}"
    , ""
    , "A first SlideBlaster deck. Edit `" <> Text.pack sampleDeckName <> "` and save."
    , ""
    , "## A figure {#figure}"
    , ""
    , "\\figure{figures/pipeline.tikz}"
    , ""
    , "## Next steps {#next}"
    , ""
    , "- Slides start at a level-two heading."
    , "- Figures are TikZ files compiled to SVG by `sb serve`."
    , "- `sb check " <> Text.pack sampleDeckName <> "` lints the deck."
    ]

sampleFigure :: Text
sampleFigure =
  Text.unlines
    [ "\\begin{tikzpicture}[box/.style={draw, rounded corners, minimum width=2cm, minimum height=0.8cm}]"
    , "  \\node[box] (a) at (0,0) {Source};"
    , "  \\node[box] (b) at (3,0) {Core};"
    , "  \\node[box] (c) at (6,0) {Slides};"
    , "  \\draw[->] (a) -- (b);"
    , "  \\draw[->] (b) -- (c);"
    , "\\end{tikzpicture}"
    ]

