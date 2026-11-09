/**
 * Shiki code highlighter with lazily loaded grammars (design D10). The core
 * (`shiki/core` + the JavaScript regex engine) and each language are separate chunks
 * fetched on first use; `p4` is the hand-written grammar. An unknown language, or any
 * failure, yields `null` and the painter keeps the plain, already-correct text.
 */
import { p4Grammar } from "./p4.tmLanguage.ts";

export interface HighlightToken {
  readonly text: string;
  readonly color?: string;
  /** Shiki bit set: 1 italic, 2 bold, 4 underline. */
  readonly fontStyle?: number;
}

export interface CodeHighlighter {
  /** Tokens per line, or `null` when the language is unknown to the provider. */
  highlight(code: string, language: string | null): Promise<HighlightToken[][] | null>;
}

type LangLoader = () => Promise<unknown>;

/** Static import specifiers so esbuild can split each grammar into its own chunk. */
export const languageLoaders: Readonly<Record<string, LangLoader>> = {
  p4: async () => p4Grammar,
  c: () => import("@shikijs/langs/c"),
  cpp: () => import("@shikijs/langs/cpp"),
  python: () => import("@shikijs/langs/python"),
  bash: () => import("@shikijs/langs/bash"),
  haskell: () => import("@shikijs/langs/haskell"),
  json: () => import("@shikijs/langs/json"),
  tex: () => import("@shikijs/langs/latex"),
  markdown: () => import("@shikijs/langs/markdown"),
  typescript: () => import("@shikijs/langs/typescript"),
  javascript: () => import("@shikijs/langs/javascript"),
  rust: () => import("@shikijs/langs/rust"),
  java: () => import("@shikijs/langs/java"),
  yaml: () => import("@shikijs/langs/yaml"),
  html: () => import("@shikijs/langs/html"),
  css: () => import("@shikijs/langs/css"),
};

const aliases: Readonly<Record<string, string>> = {
  sh: "bash", shell: "bash", zsh: "bash", hs: "haskell", py: "python", latex: "tex", md: "markdown",
  ts: "typescript", js: "javascript", "c++": "cpp", p4_16: "p4", rs: "rust", yml: "yaml",
};

export function canonicalLanguage(language: string | null): string | null {
  if (language === null) return null;
  const key = language.trim().toLowerCase();
  const name = aliases[key] ?? key;
  return Object.hasOwn(languageLoaders, name) ? name : null;
}

export interface ShikiHighlighterOptions {
  readonly loaders?: Readonly<Record<string, LangLoader>>;
  readonly onLoad?: (language: string) => void;
}

export function createShikiHighlighter(options: ShikiHighlighterOptions = {}): CodeHighlighter {
  const loaders = options.loaders ?? languageLoaders;
  let core: Promise<{ loadLanguage(...langs: unknown[]): Promise<void>; codeToTokensBase(code: string, o: { lang: string; theme: string }): { content: string; color?: string; fontStyle?: number }[][] }> | null = null;
  const loaded = new Map<string, Promise<void>>();
  const cache = new Map<string, HighlightToken[][]>();

  function ensureCore() {
    core ??= (async () => {
      const [{ createHighlighterCore }, { createJavaScriptRegexEngine }, theme] = await Promise.all([
        import("shiki/core"), import("shiki/engine/javascript"), import("@shikijs/themes/light-plus"),
      ]);
      return await createHighlighterCore({ themes: [theme.default], langs: [], engine: createJavaScriptRegexEngine() });
    })();
    return core;
  }

  return {
    async highlight(code, language) {
      const name = canonicalLanguage(language);
      if (name === null || loaders[name] === undefined) return null;
      const key = `${name}\u0000${code}`;
      const hit = cache.get(key);
      if (hit !== undefined) return hit;
      try {
        const highlighter = await ensureCore();
        if (!loaded.has(name)) {
          loaded.set(name, (async () => {
            const module = await loaders[name]!() as { default?: unknown };
            options.onLoad?.(name);
            await highlighter.loadLanguage(module.default ?? module);
          })());
        }
        await loaded.get(name);
        const lines = highlighter.codeToTokensBase(code, { lang: p4Aware(name), theme: "light-plus" })
          .map((line) => line.map((t) => ({ text: t.content, color: t.color, fontStyle: t.fontStyle })));
        cache.set(key, lines);
        return lines;
      } catch {
        return null;
      }
    },
  };
}

/** The hand-written grammar registers under its own name; bundled ones under theirs. */
function p4Aware(name: string): string {
  return name === "tex" ? "latex" : name;
}
