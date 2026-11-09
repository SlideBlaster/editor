/**
 * KaTeX math provider (ported from editor/packages/app/src/math.ts). Fills the `math`
 * content host call: `renderMath` never throws, a bad formula is shown in place by
 * KaTeX's own error rendering. Preamble macros are already expanded by the core.
 */
import katex from "katex";

export function renderMath(tex: string, display: boolean): string {
  return katex.renderToString(tex, { displayMode: display, throwOnError: false, output: "htmlAndMathml", strict: "ignore" });
}

export interface MathProvider {
  render(tex: string, display: boolean): string;
}

export const katexProvider: MathProvider = { render: renderMath };
