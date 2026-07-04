/**
 * Compile port — content the renderer cannot produce itself.
 * Contract: see compile.md.
 */

/** Content kinds an adapter may support. `table` is the only v1 kind. */
export type CompileKind = 'table'

export interface CompilePort {
  /** Whether this adapter can compile the given kind (capability probe). */
  supports(kind: CompileKind): boolean
  /** Compile a LaTeX table environment to standalone, self-contained HTML. */
  tableToHtml(latex: string): Promise<string>
}
