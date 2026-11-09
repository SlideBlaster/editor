-- |
-- Module      : SlideBlaster.Ports.Compile
-- Description : Structured external compiler jobs and typed outputs.
--
-- Compilers consume an exact source snapshot plus exact auxiliary workspace
-- entries. Browser/native adapters may use different engines, but unsupported
-- engines fail explicitly and cannot become an editable-render fallback.
module SlideBlaster.Ports.Compile
  ( CompileKind (..)
  , CompileRequest (..)
  , CompileResult (..)
  , CompilePortError (..)
  , validateCompileResult
  , CompilerPort
  , compilerPort
  , compilerKindProvision
  , runCompiler
  ) where

import SlideBlaster.Export (WorkspaceEntry)
import SlideBlaster.Ports.Capability
  ( CapabilityProvision (..)
  , RuntimeFailure
  )
import SlideBlaster.Source (SourceBufferSnapshot)

import Data.ByteString (ByteString)
import Data.Text (Text)

data CompileKind
  = LatexFragmentToHtml
  | TikzPictureToSvg
  | LatexProjectToPdf
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data CompileRequest = CompileRequest
  { compileKind :: !CompileKind
  , compilePrimarySource :: !SourceBufferSnapshot
  , compileAuxiliaryEntries :: ![WorkspaceEntry]
  }
  deriving stock (Eq, Show)

data CompileResult
  = CompiledHtml !Text
  | CompiledSvg !Text
  | CompiledPdf !ByteString
  deriving stock (Eq, Show)

data CompilePortError
  = CompileRuntimeFailure !RuntimeFailure
  | CompileKindUnsupported !CompileKind
  | CompileUnexpectedResult !CompileKind
  deriving stock (Eq, Show)

-- | Check that an adapter returned the media kind requested by Haskell.
validateCompileResult
  :: CompileRequest
  -> CompileResult
  -> Either CompilePortError CompileResult
validateCompileResult request result
  | resultMatches (compileKind request) result = Right result
  | otherwise = Left (CompileUnexpectedResult (compileKind request))

data CompilerPort m = CompilerPort
  { compilerKindProvision
      :: CompileKind
      -> CapabilityProvision ()
  , runCompiler
      :: CompileRequest
      -> m (Either CompilePortError CompileResult)
  }

-- | Construct a compiler boundary that always checks the returned media kind.
compilerPort
  :: Applicative m
  => (CompileKind -> CapabilityProvision ())
  -> (CompileRequest -> m (Either CompilePortError CompileResult))
  -> CompilerPort m
compilerPort kindProvision execute =
  CompilerPort
    { compilerKindProvision = kindProvision
    , runCompiler = \request ->
        case kindProvision (compileKind request) of
          CapabilityUnavailable _ ->
            pure (Left (CompileKindUnsupported (compileKind request)))
          CapabilityProvided () ->
            fmap
              (>>= validateCompileResult request)
              (execute request)
    }

resultMatches :: CompileKind -> CompileResult -> Bool
resultMatches kind result =
  case (kind, result) of
    (LatexFragmentToHtml, CompiledHtml _) -> True
    (TikzPictureToSvg, CompiledSvg _) -> True
    (LatexProjectToPdf, CompiledPdf _) -> True
    _ -> False
