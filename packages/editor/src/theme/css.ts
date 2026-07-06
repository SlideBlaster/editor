/**
 * Emit the theme's style layer (layer 1) as a scoped stylesheet. Contract: see css.md.
 *
 * Structured `StyleDecls` -> CSS, scoped under `.sb-slide` so it styles slides only and
 * layers after the base `slideStylesheet()` (ADR 0014, one seam). The palette becomes
 * CSS custom properties; each role becomes a `.sb-style-<role>` rule; `class < node`
 * holds because per-node inline options are emitted after these class rules. Layers 2
 * (regions) and 3 (furniture) are not stylesheet output — they render in later increments.
 */
import type { Border, Color, StyleDecls, Theme, Weight } from './theme'

/** Palette key -> CSS custom-property name. */
function varName(key: string): string {
  return `--sb-${key}`
}

/** Resolve a colour: a palette key -> its CSS var; anything else -> the literal. */
function resolveColor(theme: Theme, color: Color): string {
  return color in theme.style.palette ? `var(${varName(color)})` : color
}

/** Resolve 'body'/'heading' to the theme's families; any other string is a literal stack. */
function resolveFamily(theme: Theme, family: string): string {
  if (family === 'body') return theme.style.type.bodyFamily
  if (family === 'heading') return theme.style.type.headingFamily
  return family
}

function weightCss(w: Weight): string {
  return typeof w === 'number' ? String(w) : w
}

function borderCss(theme: Theme, b: Border): string {
  const base = `border:${b.width}px solid ${resolveColor(theme, b.color)}`
  return b.radius !== undefined ? `${base};border-radius:${b.radius}px` : base
}

/** Structured decls -> a CSS declaration string (deterministic order). */
function declsCss(theme: Theme, d: StyleDecls): string {
  const out: string[] = []
  if (d.family !== undefined) out.push(`font-family:${resolveFamily(theme, d.family)}`)
  if (d.size !== undefined) out.push(`font-size:${d.size}cqw`)
  if (d.weight !== undefined) out.push(`font-weight:${weightCss(d.weight)}`)
  if (d.italic) out.push('font-style:italic')
  if (d.letterSpacing !== undefined) out.push(`letter-spacing:${d.letterSpacing}em`)
  if (d.color !== undefined) out.push(`color:${resolveColor(theme, d.color)}`)
  if (d.background !== undefined) out.push(`background:${resolveColor(theme, d.background)}`)
  if (d.border !== undefined) out.push(borderCss(theme, d.border))
  if (d.align !== undefined) out.push(`text-align:${d.align}`)
  return out.join(';')
}

/** `.sb-slide`: palette custom properties, background, and the base font family. */
function slideBase(theme: Theme): string {
  const vars = Object.entries(theme.style.palette).map(([k, v]) => `${varName(k)}:${v}`)
  return `.sb-slide{${vars.join(';')};background:var(${varName('bg')});font-family:${theme.style.type.bodyFamily}}`
}

/** `.sb-content`: the base type — size (cqw), line-height, ink — every node inherits. */
function contentBase(theme: Theme): string {
  const t = theme.style.type
  return `.sb-content{font-size:${t.baseSize}cqw;line-height:${t.lineHeight};color:var(${varName('ink')})}`
}

/**
 * The theme's style-layer stylesheet: palette + type scale + per-role looks, keyed on
 * `.sb-slide`/`.sb-content` so it applies wherever a slide mounts (canvas, thumbnails,
 * export, and the DOM measurer — the one-source rule in slideType.md). Inject AFTER
 * `slideStylesheet()`; per-node inline styles still win (class < node). Only layer 1 here.
 */
export function themeStylesheet(theme: Theme): string {
  const rules = [slideBase(theme), contentBase(theme)]
  for (const [role, decls] of Object.entries(theme.style.classes)) {
    const css = declsCss(theme, decls)
    if (css) rules.push(`.sb-slide .sb-style-${role}{${css}}`)
  }
  return rules.join('\n')
}
