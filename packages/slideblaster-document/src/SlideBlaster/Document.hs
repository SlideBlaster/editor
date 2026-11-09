-- |
-- Module      : SlideBlaster.Document
-- Description : Public source-locked document snapshot contract.
--
-- A document snapshot keeps one exact source revision, recoverable syntax,
-- diagnostics, and optional semantic meaning coherent. It does not parse a
-- format or grant semantic edits; format packages construct these values after
-- their own readers and provenance analysis.
module SlideBlaster.Document
  ( module SlideBlaster.Document.Diagnostic
  , module SlideBlaster.Document.Provenance
  , module SlideBlaster.Document.Snapshot
  ) where

import SlideBlaster.Document.Diagnostic
import SlideBlaster.Document.Provenance
import SlideBlaster.Document.Snapshot

