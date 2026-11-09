-- |
-- Module      : SlideBlaster.TikZ.Diagnostic
-- Description : Typed reader diagnostics for the bounded TikZ subset.
--
-- Diagnostics distinguish malformed, unsupported, and ambiguous source while
-- keeping authored bytes in the associated document snapshot.
module SlideBlaster.TikZ.Diagnostic
  ( Diagnostic
  , DiagnosticCategory (..)
  , DiagnosticCode (..)
  , diagnosticCategory
  , diagnosticCode
  , diagnosticMessage
  , diagnosticSpan
  ) where

import SlideBlaster.TikZ.Internal.Types
  ( Diagnostic
  , DiagnosticCategory (..)
  , DiagnosticCode (..)
  , diagnosticCategory
  , diagnosticCode
  , diagnosticMessage
  , diagnosticSpan
  )
