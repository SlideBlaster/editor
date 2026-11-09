import { ensureKatexCss } from "../content/katex-css.ts";
import { createShikiHighlighter } from "../content/highlight.ts";
import { katexProvider } from "../content/math.ts";
import { createBrowserWindowOpener, mountConsole, openChannel } from "./windows.ts";

ensureKatexCss(document);
const opener = createBrowserWindowOpener(new URL("./", document.baseURI).href);
mountConsole({ doc: document, channel: openChannel(), paint: { math: katexProvider, highlighter: createShikiHighlighter() } }, () => { opener.openAudience(); });
