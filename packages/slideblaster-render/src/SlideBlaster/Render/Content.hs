{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Render.Content
-- Description : Dialect-free structured content for measurement and paint.
--
-- Markdown, LaTeX, HTML, citations, and compiled figures are lowered before
-- this boundary. Links, math, tables, highlighting, and inline overlays are
-- explicit presentation values; a host never reparses authored source.
module SlideBlaster.Render.Content
  ( RenderContent (..)
  , RenderHeadingLevel (..)
  , RenderContentRole (..)
  , RenderImageFit (..)
  , RenderHighlight (..)
  , RenderInlineVisibility (..)
  , RenderWebScheme (..)
  , RenderLinkTarget
  , RenderLinkTargetView (..)
  , RenderLinkError (..)
  , mkRenderWebLink
  , mkRenderEmailLink
  , mkRenderInternalLink
  , renderLinkTargetHref
  , renderLinkTargetView
  , RenderMathDisplay (..)
  , RenderMathTokenKind (..)
  , RenderMathNode (..)
  , RenderMathPresentation (..)
  , RenderTableSpan
  , mkRenderTableSpan
  , renderTableSpanValue
  , RenderTableCellKind (..)
  , RenderTableCell (..)
  , RenderTableRow (..)
  , RenderTable (..)
  , renderContentPlainText
  , renderContentResourceReferences
  ) where

import SlideBlaster.Render.Resource
  ( ResourceId
  , ResourceReference (..)
  , ResourceReferenceKind (ImageReference)
  )
import SlideBlaster.Render.Style
  ( RenderColour
  , RenderTypography
  , renderTypographyResourceReferences
  )

import Data.Char (isControl, isSpace)
import Data.List.NonEmpty (NonEmpty)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

-- | Structural roles translated by a host to its native content tree. Math
-- and tables have dedicated constructors because their presentation cannot be
-- recovered from a generic role.
data RenderHeadingLevel
  = RenderHeading1
  | RenderHeading2
  | RenderHeading3
  | RenderHeading4
  | RenderHeading5
  | RenderHeading6
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderContentRole
  = InlineFlow
  | ParagraphFlow
  | HeadingFlow !RenderHeadingLevel
  | StrongFlow
  | EmphasisFlow
  | CodeFlow
  | QuoteFlow
  | UnorderedListFlow
  | OrderedListFlow
  | ListItemFlow
  | CitationFlow
  | FootnoteFlow
  deriving stock (Eq, Ord, Show)

data RenderImageFit
  = RenderContainImage
  | RenderCoverImage
  | RenderStretchImage
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | A resolved highlight. Its colour is direct plan data rather than an
-- implicit browser @mark@ default.
data RenderHighlight
  = NoRenderHighlight
  | HighlightWith !RenderColour
  deriving stock (Eq, Ord, Show)

-- | Inline overlays preserve their layout box even while hidden. This is the
-- Beamer-style reveal rule and prevents reflow between overlay beats.
data RenderInlineVisibility
  = InlineVisible
  | InlineHiddenReserved
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderWebScheme
  = RenderHttp
  | RenderHttps
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RenderLinkTarget
  = RenderWebLink !RenderWebScheme !Text
  | RenderEmailLink !Text
  | RenderInternalLink !Text
  deriving stock (Eq, Ord, Show)

data RenderLinkTargetView
  = RenderWebLinkView !RenderWebScheme !Text
  | RenderEmailLinkView !Text
  | RenderInternalLinkView !Text
  deriving stock (Eq, Ord, Show)

data RenderLinkError
  = RenderLinkPayloadEmpty
  | RenderLinkPayloadContainsWhitespaceOrControl
  deriving stock (Eq, Show)

-- | Construct a web target from the already-separated scheme and the exact
-- authority/path/query/fragment suffix. The host only prefixes the scheme.
mkRenderWebLink
  :: RenderWebScheme
  -> Text
  -> Either RenderLinkError RenderLinkTarget
mkRenderWebLink scheme location = do
  validateLinkPayload location
  Right (RenderWebLink scheme location)

mkRenderEmailLink :: Text -> Either RenderLinkError RenderLinkTarget
mkRenderEmailLink address = do
  validateLinkPayload address
  Right (RenderEmailLink address)

-- | Construct a fragment target without the leading @#@.
mkRenderInternalLink :: Text -> Either RenderLinkError RenderLinkTarget
mkRenderInternalLink fragment = do
  validateLinkPayload fragment
  Right (RenderInternalLink fragment)

renderLinkTargetView :: RenderLinkTarget -> RenderLinkTargetView
renderLinkTargetView target =
  case target of
    RenderWebLink scheme location -> RenderWebLinkView scheme location
    RenderEmailLink address -> RenderEmailLinkView address
    RenderInternalLink fragment -> RenderInternalLinkView fragment

renderLinkTargetHref :: RenderLinkTarget -> Text
renderLinkTargetHref target =
  case target of
    RenderWebLink RenderHttp location -> "http://" <> location
    RenderWebLink RenderHttps location -> "https://" <> location
    RenderEmailLink address -> "mailto:" <> address
    RenderInternalLink fragment -> "#" <> fragment

data RenderMathDisplay
  = RenderInlineMath
  | RenderDisplayMath
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Literal MathML-like token classification. Token text is presentation text,
-- never TeX source.
data RenderMathTokenKind
  = RenderMathIdentifier
  | RenderMathNumber
  | RenderMathOperator
  | RenderMathText
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Closed math presentation tree. It is intentionally smaller than MathML
-- but covers the layout distinctions a target must not infer from TeX.
data RenderMathNode
  = RenderMathToken
      !RenderMathTokenKind
      !Text
      !RenderTypography
  | RenderMathRow !(NonEmpty RenderMathNode)
  | RenderMathFraction !RenderMathNode !RenderMathNode
  | RenderMathRoot !(Maybe RenderMathNode) !RenderMathNode
  | RenderMathScripts
      !RenderMathNode
      !(Maybe RenderMathNode)
      !(Maybe RenderMathNode)
  | RenderMathUnderOver
      !RenderMathNode
      !(Maybe RenderMathNode)
      !(Maybe RenderMathNode)
  | RenderMathFenced !Text !Text !RenderMathNode
  deriving stock (Eq, Ord, Show)

data RenderMathPresentation = RenderMathPresentation
  { renderMathDisplay :: !RenderMathDisplay
  , renderMathAccessibilityLabel :: !Text
  , renderMathRoot :: !RenderMathNode
  }
  deriving stock (Eq, Ord, Show)

newtype RenderTableSpan = RenderTableSpan Natural
  deriving stock (Eq, Ord, Show)

mkRenderTableSpan :: Natural -> Maybe RenderTableSpan
mkRenderTableSpan value
  | value == 0 = Nothing
  | otherwise = Just (RenderTableSpan value)

renderTableSpanValue :: RenderTableSpan -> Natural
renderTableSpanValue (RenderTableSpan value) = value

data RenderTableCellKind
  = RenderHeaderCell
  | RenderDataCell
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Physical table cell with explicit HTML-compatible row and column spans.
data RenderTableCell = RenderTableCell
  { renderTableCellKind :: !RenderTableCellKind
  , renderTableCellRowSpan :: !RenderTableSpan
  , renderTableCellColumnSpan :: !RenderTableSpan
  , renderTableCellContent :: ![RenderContent]
  }
  deriving stock (Eq, Ord, Show)

newtype RenderTableRow = RenderTableRow
  { renderTableRowCells :: [RenderTableCell]
  }
  deriving stock (Eq, Ord, Show)

data RenderTable = RenderTable
  { renderTableHeadRows :: ![RenderTableRow]
  , renderTableBodyRows :: ![RenderTableRow]
  }
  deriving stock (Eq, Ord, Show)

-- | Closed rendered content. Every constructor is directly translatable to a
-- target content tree and contains no HTML, TeX, CSS, or source dialect.
data RenderContent
  = RenderText !Text !RenderTypography !RenderHighlight
  | RenderContainer !RenderContentRole ![RenderContent]
  | RenderLink !RenderLinkTarget ![RenderContent]
  | RenderMath !RenderMathPresentation
  | RenderTableContent !RenderTable
  | RenderInlineOverlay !RenderInlineVisibility !RenderContent
  | RenderContentImage !ResourceId !Text !RenderImageFit
  | RenderHardLineBreak
  deriving stock (Eq, Ord, Show)

-- | Conservative literal-text projection used by non-layout-authoritative
-- measurers and accessibility diagnostics.
renderContentPlainText :: RenderContent -> Text
renderContentPlainText content =
  case content of
    RenderText value _ _ -> value
    RenderContainer _ children ->
      foldMap renderContentPlainText children
    RenderLink _ children ->
      foldMap renderContentPlainText children
    RenderMath presentation ->
      renderMathAccessibilityLabel presentation
    RenderTableContent table ->
      renderTablePlainText table
    RenderInlineOverlay _ child ->
      renderContentPlainText child
    RenderContentImage _ alternative _ -> alternative
    RenderHardLineBreak -> Text.singleton '\n'

renderContentResourceReferences
  :: RenderContent
  -> Set ResourceReference
renderContentResourceReferences content =
  case content of
    RenderText _ typography _ ->
      renderTypographyResourceReferences typography
    RenderContainer _ children ->
      foldMap renderContentResourceReferences children
    RenderLink _ children ->
      foldMap renderContentResourceReferences children
    RenderMath presentation ->
      renderMathResourceReferences (renderMathRoot presentation)
    RenderTableContent table ->
      renderTableResourceReferences table
    RenderInlineOverlay _ child ->
      renderContentResourceReferences child
    RenderContentImage resource _ _ ->
      Set.singleton (ResourceReference resource ImageReference)
    RenderHardLineBreak -> Set.empty

validateLinkPayload :: Text -> Either RenderLinkError ()
validateLinkPayload payload
  | Text.null payload = Left RenderLinkPayloadEmpty
  | Text.any (\value -> isSpace value || isControl value) payload =
      Left RenderLinkPayloadContainsWhitespaceOrControl
  | otherwise = Right ()

renderMathResourceReferences :: RenderMathNode -> Set ResourceReference
renderMathResourceReferences node =
  case node of
    RenderMathToken _ _ typography ->
      renderTypographyResourceReferences typography
    RenderMathRow children ->
      foldMap renderMathResourceReferences children
    RenderMathFraction numerator denominator ->
      renderMathResourceReferences numerator
        <> renderMathResourceReferences denominator
    RenderMathRoot degree radicand ->
      foldMap renderMathResourceReferences degree
        <> renderMathResourceReferences radicand
    RenderMathScripts base subscript superscript ->
      renderMathResourceReferences base
        <> foldMap renderMathResourceReferences subscript
        <> foldMap renderMathResourceReferences superscript
    RenderMathUnderOver base under over ->
      renderMathResourceReferences base
        <> foldMap renderMathResourceReferences under
        <> foldMap renderMathResourceReferences over
    RenderMathFenced _ _ child ->
      renderMathResourceReferences child

renderTableResourceReferences :: RenderTable -> Set ResourceReference
renderTableResourceReferences table =
  foldMap renderRowResourceReferences
    (renderTableHeadRows table <> renderTableBodyRows table)

renderRowResourceReferences :: RenderTableRow -> Set ResourceReference
renderRowResourceReferences =
  foldMap
    (foldMap renderContentResourceReferences . renderTableCellContent)
    . renderTableRowCells

renderTablePlainText :: RenderTable -> Text
renderTablePlainText table =
  Text.intercalate
    "\n"
    ( fmap renderRowPlainText
        (renderTableHeadRows table <> renderTableBodyRows table)
    )

renderRowPlainText :: RenderTableRow -> Text
renderRowPlainText =
  Text.intercalate "\t"
    . fmap (foldMap renderContentPlainText . renderTableCellContent)
    . renderTableRowCells
