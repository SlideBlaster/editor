import { ensureKatexCss } from "../content/katex-css.ts";
import { createShikiHighlighter } from "../content/highlight.ts";
import { katexProvider } from "../content/math.ts";
import { mountAudience, openChannel } from "./windows.ts";

ensureKatexCss(document);
mountAudience({ doc: document, channel: openChannel(), paint: { math: katexProvider, highlighter: createShikiHighlighter() } });
