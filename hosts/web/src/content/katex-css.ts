import { KATEX_CSS } from "../generated/katex-inline-css.ts";

export { KATEX_CSS };

/** Inject the self-contained KaTeX stylesheet once per document. */
export function ensureKatexCss(doc: Document): void {
  if (doc.getElementById("sb-katex-css") !== null) return;
  const style = doc.createElement("style");
  style.id = "sb-katex-css";
  style.textContent = KATEX_CSS;
  doc.head.append(style);
}
