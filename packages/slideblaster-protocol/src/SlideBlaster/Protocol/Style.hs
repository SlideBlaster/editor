{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Protocol.Style
-- Description : JSON for the content style command, in both directions.
--
-- A style edit is the first command whose payload is a value from the syntax
-- package rather than a coordinate, so its wire form is defined here rather than
-- alongside the geometric commands.
--
-- Two things are deliberate. A colour crosses as the /expression/ the author would
-- have written, not as a resolved triple, because @blue!40!black@ is what belongs
-- in the document and resolving it on the way in would discard the authoring. And a
-- percentage crosses as its authored text, from which its value is then derived, so
-- a literal cannot arrive with a value disagreeing with its own spelling.
module SlideBlaster.Protocol.Style
  ( encodeCommand
  , parseCommand
  , encodeStyleError
  , dialectName
  , parseDialect
  ) where

import Data.Aeson (Value, object, (.:), (.=))
import Data.Aeson.Types (Parser, withObject)
import Data.Text (Text)
import Data.Text qualified as Text
import SlideBlaster.Source (revisionToWord64)
import SlideBlaster.Syntax.Command
  ( Command (Command)
  , Effect (ClearStyle, SetStyle, ToggleStyle)
  , Target (At, Between)
  , commandEffect
  , commandTarget
  )
import SlideBlaster.Syntax.Number (rationalText)
import SlideBlaster.Syntax.Tex.Reader (TexSyntaxError (texErrorMessage), readColourExpr)
import SlideBlaster.Syntax.Path (pathFromList, pathToList)
import SlideBlaster.Syntax.Range (Point (Point), pointOffset, pointPath)
import SlideBlaster.Syntax.Surface (Dialect (Html, Markdown, Tex))
import SlideBlaster.Syntax.Style
  ( ColourExpr (..)
  , ColourModel (..)
  , Family (..)
  , Literal (Literal, literalText)
  , Slant (..)
  , StyleKey (..)
  , StyleValue (..)
  , Variant (..)
  , Weight (..)
  )
import SlideBlaster.TikZ (StyleError (..))

-- | Encode a command for a fixture or a browser caller.
encodeCommand :: Command -> Value
encodeCommand command =
  object
    [ "target" .= encodeTarget (commandTarget command)
    , "effect" .= encodeEffect (commandEffect command)
    ]

parseCommand :: Value -> Parser Command
parseCommand =
  withObject "style command" $ \value -> do
    target <- value .: "target" >>= parseTarget
    effect <- value .: "effect" >>= parseEffect
    pure (Command target effect)

encodeTarget :: Target -> Value
encodeTarget target =
  case target of
    At path -> object ["kind" .= ("at" :: Text), "path" .= pathToList path]
    Between start end ->
      object
        [ "kind" .= ("between" :: Text)
        , "start" .= encodePoint start
        , "end" .= encodePoint end
        ]

parseTarget :: Value -> Parser Target
parseTarget =
  withObject "style target" $ \value -> do
    kind <- value .: "kind"
    case kind :: Text of
      "at" -> At . pathFromList <$> value .: "path"
      "between" -> do
        start <- value .: "start" >>= parsePoint
        end <- value .: "end" >>= parsePoint
        pure (Between start end)
      _ -> fail ("unknown style target: " <> Text.unpack kind)

encodePoint :: Point -> Value
encodePoint position =
  object
    [ "path" .= pathToList (pointPath position)
    , "offset" .= pointOffset position
    ]

parsePoint :: Value -> Parser Point
parsePoint =
  withObject "style point" $ \value -> do
    path <- value .: "path"
    offset <- value .: "offset"
    pure (Point (pathFromList path) offset)

encodeEffect :: Effect -> Value
encodeEffect effect =
  case effect of
    SetStyle value ->
      object ["kind" .= ("set" :: Text), "style" .= encodeStyleValue value]
    ClearStyle key ->
      object ["kind" .= ("clear" :: Text), "property" .= styleKeyName key]
    ToggleStyle value ->
      object ["kind" .= ("toggle" :: Text), "style" .= encodeStyleValue value]

parseEffect :: Value -> Parser Effect
parseEffect =
  withObject "style effect" $ \value -> do
    kind <- value .: "kind"
    case kind :: Text of
      "set" -> SetStyle <$> (value .: "style" >>= parseStyleValue)
      "clear" -> ClearStyle <$> (value .: "property" >>= parseStyleKey)
      "toggle" -> ToggleStyle <$> (value .: "style" >>= parseStyleValue)
      _ -> fail ("unknown style effect: " <> Text.unpack kind)

-- | The wire name of a notation.
--
-- Spelled as the notation is normally named rather than as the constructor, so an
-- interface offering the choice shows something an author recognises.
dialectName :: Dialect -> Text
dialectName dialect =
  case dialect of
    Tex -> "latex"
    Markdown -> "markdown"
    Html -> "html"

parseDialect :: Text -> Parser Dialect
parseDialect name =
  case name of
    "latex" -> pure Tex
    "markdown" -> pure Markdown
    "html" -> pure Html
    _ -> fail ("unknown notation: " <> Text.unpack name)

styleKeyName :: StyleKey -> Text
styleKeyName key =
  case key of
    WeightKey -> "weight"
    SlantKey -> "slant"
    FamilyKey -> "family"
    VariantKey -> "variant"
    UnderlineKey -> "underline"
    StrikeKey -> "strike"
    HighlightKey -> "highlight"
    ForegroundKey -> "foreground"
    BackgroundKey -> "background"

parseStyleKey :: Text -> Parser StyleKey
parseStyleKey name =
  case lookup name keysByName of
    Just key -> pure key
    Nothing -> fail ("unknown style property: " <> Text.unpack name)

keysByName :: [(Text, StyleKey)]
keysByName = [(styleKeyName key, key) | key <- [minBound .. maxBound]]

encodeStyleValue :: StyleValue -> Value
encodeStyleValue value =
  case value of
    SetWeight Bold -> named WeightKey "bold"
    SetWeight NormalWeight -> named WeightKey "normal"
    SetSlant Italic -> named SlantKey "italic"
    SetSlant Upright -> named SlantKey "upright"
    SetFamily Serif -> named FamilyKey "serif"
    SetFamily SansSerif -> named FamilyKey "sans"
    SetFamily Monospace -> named FamilyKey "mono"
    SetVariant SmallCaps -> named VariantKey "small_caps"
    SetVariant NormalVariant -> named VariantKey "normal"
    SetUnderline flag -> flagged UnderlineKey flag
    SetStrike flag -> flagged StrikeKey flag
    SetHighlight flag -> flagged HighlightKey flag
    SetForeground expression -> coloured ForegroundKey expression
    SetBackground expression -> coloured BackgroundKey expression
  where
    named key text =
      object ["property" .= styleKeyName key, "value" .= (text :: Text)]
    flagged key flag =
      object ["property" .= styleKeyName key, "value" .= flag]
    coloured key expression =
      object
        [ "property" .= styleKeyName key
        , "colour" .= encodeColour expression
        ]

parseStyleValue :: Value -> Parser StyleValue
parseStyleValue =
  withObject "style value" $ \value -> do
    property <- value .: "property"
    case property :: Text of
      "weight" -> value .: "value" >>= keyword weightByName SetWeight
      "slant" -> value .: "value" >>= keyword slantByName SetSlant
      "family" -> value .: "value" >>= keyword familyByName SetFamily
      "variant" -> value .: "value" >>= keyword variantByName SetVariant
      "underline" -> SetUnderline <$> value .: "value"
      "strike" -> SetStrike <$> value .: "value"
      "highlight" -> SetHighlight <$> value .: "value"
      "foreground" -> SetForeground <$> (value .: "colour" >>= parseColour)
      "background" -> SetBackground <$> (value .: "colour" >>= parseColour)
      _ -> fail ("unknown style property: " <> Text.unpack property)
  where
    keyword table build name =
      case lookup (name :: Text) table of
        Just found -> pure (build found)
        Nothing -> fail ("unknown style value: " <> Text.unpack name)

weightByName :: [(Text, Weight)]
weightByName = [("bold", Bold), ("normal", NormalWeight)]

slantByName :: [(Text, Slant)]
slantByName = [("italic", Italic), ("upright", Upright)]

familyByName :: [(Text, Family)]
familyByName = [("serif", Serif), ("sans", SansSerif), ("mono", Monospace)]

variantByName :: [(Text, Variant)]
variantByName = [("small_caps", SmallCaps), ("normal", NormalVariant)]

encodeColour :: ColourExpr -> Value
encodeColour expression =
  case expression of
    ColourName name ->
      object ["kind" .= ("name" :: Text), "name" .= name]
    ColourLiteral model text ->
      object
        [ "kind" .= ("literal" :: Text)
        , "model" .= modelName model
        , "text" .= text
        ]
    ColourTint base percentage ->
      object
        [ "kind" .= ("tint" :: Text)
        , "base" .= encodeColour base
        , "percentage" .= literalText percentage
        ]
    ColourMix base percentage other ->
      object
        [ "kind" .= ("mix" :: Text)
        , "base" .= encodeColour base
        , "percentage" .= literalText percentage
        , "other" .= encodeColour other
        ]
    ColourComplement base ->
      object ["kind" .= ("complement" :: Text), "base" .= encodeColour base]

parseColour :: Value -> Parser ColourExpr
parseColour =
  withObject "colour" $ \value -> do
    kind <- value .: "kind"
    case kind :: Text of
      "name" -> ColourName <$> value .: "name"
      "literal" -> do
        model <- value .: "model" >>= parseModel
        text <- value .: "text"
        pure (ColourLiteral model text)
      "tint" -> do
        base <- value .: "base" >>= parseColour
        percentage <- value .: "percentage" >>= parsePercentage
        pure (ColourTint base percentage)
      "mix" -> do
        base <- value .: "base" >>= parseColour
        percentage <- value .: "percentage" >>= parsePercentage
        other <- value .: "other" >>= parseColour
        pure (ColourMix base percentage other)
      "complement" -> ColourComplement <$> (value .: "base" >>= parseColour)
      -- An interface sends what the author typed. Parsing it here keeps the
      -- expression grammar in one place instead of reimplementing xcolor in a host.
      "expression" -> do
        text <- value .: "text"
        case readColourExpr text of
          Right expression -> pure expression
          Left problem ->
            fail
              ( "malformed colour expression: "
                  <> Text.unpack (texErrorMessage problem)
              )
      _ -> fail ("unknown colour expression: " <> Text.unpack kind)

-- | A percentage's value is derived from its authored text, so the two cannot
-- disagree however the caller wrote it.
parsePercentage :: Text -> Parser (Literal Rational)
parsePercentage text =
  case rationalText text of
    Just number -> pure (Literal number text)
    Nothing -> fail ("malformed percentage: " <> Text.unpack text)

modelName :: ColourModel -> Text
modelName model =
  case model of
    NamedModel -> "named"
    RgbModel -> "rgb"
    GrayModel -> "gray"
    HtmlModel -> "html"

parseModel :: Text -> Parser ColourModel
parseModel name =
  case lookup name modelsByName of
    Just model -> pure model
    Nothing -> fail ("unknown colour model: " <> Text.unpack name)

modelsByName :: [(Text, ColourModel)]
modelsByName = [(modelName model, model) | model <- [NamedModel, RgbModel, GrayModel, HtmlModel]]

-- | Encode a style refusal without disclosing authored content.
encodeStyleError :: StyleError -> Value
encodeStyleError problem =
  case problem of
    StyleStale expected actual ->
      object
        [ "kind" .= ("style_stale" :: Text)
        , "expected" .= revisionToWord64 expected
        , "actual" .= revisionToWord64 actual
        ]
    StyleSemanticsUnavailable ->
      object ["kind" .= ("style_semantics_unavailable" :: Text)]
    StyleTargetMissing _ ->
      object ["kind" .= ("style_target_missing" :: Text)]
    StyleContentUnreadable reason ->
      object
        [ "kind" .= ("style_content_unreadable" :: Text)
        , "detail" .= reason
        ]
    StyleRefused reason ->
      object ["kind" .= ("style_refused" :: Text), "detail" .= reason]
    StyleSourceCheckFailed _ ->
      object ["kind" .= ("style_source_check_failed" :: Text)]
    StyleVerificationFailed ->
      object ["kind" .= ("style_verification_failed" :: Text)]
