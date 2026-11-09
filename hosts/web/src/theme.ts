/**
 * Theme data on the host side (design 3.4): `themes/<name>/theme.json` + `theme.css`.
 * The core reads theme.json (regions, furniture, palette) itself and bakes the result into
 * plans; the host needs only the CSS (typography/chrome) and the body font for measuring.
 */
export interface ThemeRegion { readonly x: number; readonly y: number; readonly w: number; readonly h: number; readonly align?: string }

export interface ThemeData {
  readonly name: string;
  readonly title: string;
  readonly aspect: readonly [number, number];
  readonly palette: Readonly<Record<string, unknown>>;
  readonly fonts: { readonly body: string; readonly mono: string; readonly sizes: Readonly<Record<string, number>> };
  readonly regions: Readonly<Record<"title" | "body" | "footer" | "safe", ThemeRegion>>;
  readonly titleSlide: Readonly<Record<string, ThemeRegion>>;
  readonly furniture: readonly { readonly kind: string; readonly slides: string; readonly [key: string]: unknown }[];
  readonly prelude: string;
  readonly css: string;
}

export class ThemeError extends Error {
  constructor(message: string) { super(message); this.name = "ThemeError"; }
}

export function validateTheme(value: unknown): ThemeData {
  const theme = value as Record<string, any>;
  const need = (ok: boolean, what: string) => { if (!ok) throw new ThemeError(`theme.json: ${what}`); };
  need(typeof theme === "object" && theme !== null, "not an object");
  need(typeof theme.name === "string" && /^[a-z0-9-]+$/.test(theme.name), "name must be a lowercase identifier");
  need(Array.isArray(theme.aspect) && theme.aspect.length === 2 && theme.aspect.every((n: unknown) => typeof n === "number" && n > 0), "aspect");
  need(typeof theme.palette === "object" && theme.palette !== null, "palette");
  need(typeof theme.fonts?.body === "string" && typeof theme.fonts?.mono === "string", "fonts.body/mono");
  for (const region of ["title", "body", "footer", "safe"]) {
    const r = theme.regions?.[region];
    need(r !== undefined && ["x", "y", "w", "h"].every((k) => typeof r[k] === "number"), `regions.${region}`);
  }
  need(typeof theme.titleSlide === "object" && theme.titleSlide !== null, "titleSlide");
  need(Array.isArray(theme.furniture), "furniture");
  for (const item of theme.furniture) need(typeof item.kind === "string" && ["all", "first", "not-first"].includes(item.slides), "furniture entry");
  need(typeof theme.prelude === "string" && typeof theme.css === "string", "prelude/css");
  return theme as unknown as ThemeData;
}

export interface ThemeLoader {
  readonly css: string;
  readonly data: ThemeData;
}

export async function loadTheme(base: string, name: string, fetcher: (url: string) => Promise<{ ok: boolean; json(): Promise<unknown>; text(): Promise<string> }>): Promise<ThemeLoader> {
  if (!/^[a-z0-9-]+$/.test(name)) throw new ThemeError(`bad theme name ${name}`);
  const jsonResponse = await fetcher(`${base}themes/${name}/theme.json`);
  if (!jsonResponse.ok) throw new ThemeError(`theme ${name} not found`);
  const data = validateTheme(await jsonResponse.json());
  const cssResponse = await fetcher(`${base}themes/${name}/${data.css}`);
  return { data, css: cssResponse.ok ? await cssResponse.text() : "" };
}

export function applyThemeCss(doc: Document, name: string, css: string): void {
  const id = `sb-theme-${name}`;
  let style = doc.getElementById(id);
  if (style === null) {
    style = doc.createElement("style");
    style.id = id;
    doc.head.append(style);
  }
  style.textContent = css;
}
