/**
 * @slideblaster/adapters-shared public surface. Contract: see index.md.
 *
 * Platform-independent adapters shared by browser and native shells. Present so
 * far: the WASM latexml Compile adapter (ADR 0009) — the built emscripten engine
 * plus the in-process (`createBrowserLatexmlEngine`) and worker-hosted
 * (`createWorkerLatexmlEngine`) drivers, wired into web-shell. The Collab client
 * lands at M6.
 */
export {
  WasmLatexmlCompiler,
  CompileError,
  buildTableDocument,
  finalizeHtml,
} from './compile/wasmLatexmlCompiler'
export type { LatexmlEngine, WasmLatexmlCompilerDeps } from './compile/wasmLatexmlCompiler'
export { createBrowserLatexmlEngine } from './compile/browserLatexmlEngine'
export type {
  BrowserLatexmlEngineOptions,
  PerlModule,
  PerlModuleFactory,
} from './compile/browserLatexmlEngine'
export { createWorkerLatexmlEngine } from './compile/workerLatexmlEngine'
export type { LatexmlWorker } from './compile/workerLatexmlEngine'
export {
  ANNOTATION_BINDING,
  installTableAnnotation,
  patchDriver,
} from './compile/tableAnnotation'
export type { AnnotationFs } from './compile/tableAnnotation'
