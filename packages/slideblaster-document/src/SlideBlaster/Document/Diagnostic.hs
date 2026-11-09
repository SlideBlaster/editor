-- |
-- Module      : SlideBlaster.Document.Diagnostic
-- Description : Target-neutral document diagnostics.
--
-- Diagnostics distinguish severity from category and carry an optional exact
-- source span. Stable machine codes are non-empty; human messages may evolve
-- without changing command policy.
module SlideBlaster.Document.Diagnostic
  ( Diagnostic
  , DiagnosticCategory (..)
  , DiagnosticCode
  , DiagnosticSeverity (..)
  , diagnosticCategory
  , diagnosticCode
  , diagnosticCodeText
  , diagnosticMessage
  , diagnosticSeverity
  , diagnosticSpan
  , isHardDiagnostic
  , mkDiagnostic
  , mkDiagnosticCode
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import SlideBlaster.Source (SourceSpan)

-- | Whether a diagnostic is informational, lossy-but-actionable, or blocking.
data DiagnosticSeverity
  = DiagnosticInformation
  | DiagnosticWarning
  | DiagnosticError
  deriving (Eq, Ord, Show)

-- | The stable policy class of a diagnostic.
data DiagnosticCategory
  = SyntaxMalformed
  | SyntaxUnsupported
  | MeaningAmbiguous
  | ReferenceMissing
  | LayoutUnresolved
  | ExportFidelity
  | CapabilityUnavailable
  | InternalInvariant
  deriving (Eq, Ord, Show)

-- | A stable non-empty machine-readable diagnostic identifier.
newtype DiagnosticCode = DiagnosticCode Text
  deriving (Eq, Ord, Show)

-- | A diagnostic attached to one document revision.
data Diagnostic = Diagnostic
  !DiagnosticSeverity
  !DiagnosticCategory
  !DiagnosticCode
  !Text
  !(Maybe SourceSpan)
  deriving (Eq, Show)

-- | Construct a stable code, rejecting empty or whitespace-only values.
mkDiagnosticCode :: Text -> Maybe DiagnosticCode
mkDiagnosticCode value
  | Text.null (Text.strip value) = Nothing
  | otherwise = Just (DiagnosticCode value)

-- | Return the wire and policy spelling of a diagnostic code.
diagnosticCodeText :: DiagnosticCode -> Text
diagnosticCodeText (DiagnosticCode value) = value

-- | Construct a typed diagnostic.
mkDiagnostic
  :: DiagnosticSeverity
  -> DiagnosticCategory
  -> DiagnosticCode
  -> Text
  -> Maybe SourceSpan
  -> Diagnostic
mkDiagnostic = Diagnostic

-- | Return the severity used by command and persistence policy.
diagnosticSeverity :: Diagnostic -> DiagnosticSeverity
diagnosticSeverity (Diagnostic value _ _ _ _) = value

-- | Return the stable policy category.
diagnosticCategory :: Diagnostic -> DiagnosticCategory
diagnosticCategory (Diagnostic _ value _ _ _) = value

-- | Return the stable machine code.
diagnosticCode :: Diagnostic -> DiagnosticCode
diagnosticCode (Diagnostic _ _ value _ _) = value

-- | Return the human-facing explanation.
diagnosticMessage :: Diagnostic -> Text
diagnosticMessage (Diagnostic _ _ _ value _) = value

-- | Return the exact affected source span when one is known.
diagnosticSpan :: Diagnostic -> Maybe SourceSpan
diagnosticSpan (Diagnostic _ _ _ _ value) = value

-- | Test whether a diagnostic blocks semantic commands or durable publish.
isHardDiagnostic :: Diagnostic -> Bool
isHardDiagnostic diagnosticValue =
  diagnosticSeverity diagnosticValue == DiagnosticError

