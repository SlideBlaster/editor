/**
 * @slideblaster/adapters-shared public surface. Contract: see index.md.
 *
 * Platform-independent adapters shared by browser and native shells. Present so
 * far: the WASM latexml Compile adapter (ADR 0009, Track-0 spike) as a scaffold —
 * real glue around an engine that is not built yet. The Collab client lands at M6.
 */
export {
  WasmLatexmlCompiler,
  CompileError,
  buildTableDocument,
  finalizeHtml,
} from './compile/wasmLatexmlCompiler'
export type { LatexmlEngine, WasmLatexmlCompilerDeps } from './compile/wasmLatexmlCompiler'
