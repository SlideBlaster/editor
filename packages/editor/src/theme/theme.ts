/**
 * The structured theme model (ADR 0017). Contract: see theme.md.
 *
 * A theme is typed data in three layers — style, master layout, furniture — not
 * opaque CSS/HTML. This module defines the model and the built-in `defaultTheme`;
 * `css.ts` emits the style layer as a stylesheet. Layers 2 (regions) and 3
 * (furniture) are modelled here and consumed by later overlay/render increments.
 */

/** A colour: a palette key (resolved to a CSS var) or a literal CSS colour. */
export type Color = string

/** The deck's named colours. bg/ink/accent are well-known; extra entries are
 *  available by name to style classes and to TikZ `\draw`. */
export interface Palette {
  bg: Color
  ink: Color
  accent: Color
  [name: string]: Color
}

/** Font families plus a base type size (vh, slide-relative). `scale` is the modular
 *  ratio a theme editor uses to derive a heading ramp; classes may set explicit sizes. */
export interface TypeScale {
  bodyFamily: string
  headingFamily: string
  /** Base body size in cqw (container-query width vs the slide box, slideType.ts). */
  baseSize: number
  /** Modular ratio a theme editor uses to derive a heading ramp. */
  scale: number
  /** Body line-height (unitless). */
  lineHeight: number
}

export type Align = 'left' | 'center' | 'right'
export type Weight = 'normal' | 'bold' | number

/** A structured border (never a raw CSS string). `width`/`radius` in px. */
export interface Border {
  width: number
  color: Color
  radius?: number
}

/** The structured look of one semantic role — typed decls, not raw CSS (ADR 0017). */
export interface StyleDecls {
  /** 'body' | 'heading' resolve to the type families; any other string is a literal stack. */
  family?: 'body' | 'heading' | string
  /** Text size in cqw (slide-relative, slideType.ts); omitted -> inherits the base size. */
  size?: number
  weight?: Weight
  italic?: boolean
  /** Tracking in em (e.g. -0.01 to tighten a title). */
  letterSpacing?: number
  color?: Color
  background?: Color
  border?: Border
  align?: Align
}

/** Layer 1 — style: the visual defaults every slide inherits (class < node). */
export interface StyleLayer {
  palette: Palette
  type: TypeScale
  /** role -> look. title/subtitle/heading/body/caption/box/note and any custom role. */
  classes: Record<string, StyleDecls>
  /** Default relative-placement gap in slide units (the theme's `node distance`, ADR 0006). */
  nodeDistance: number
}

/** A rectangle relative to the slide box: fractions in [0,1], origin top-left, y-down
 *  (the overlay/DOM convention) — so it is aspect-ratio-agnostic (ADR 0017). */
export interface RelRect {
  x: number
  y: number
  w: number
  h: number
}

/** The nine placement slots furniture and region anchors resolve against. */
export type Anchor9 =
  | 'top-left'
  | 'top-center'
  | 'top-right'
  | 'mid-left'
  | 'center'
  | 'mid-right'
  | 'bottom-left'
  | 'bottom-center'
  | 'bottom-right'

/** A master-layout region: a soft guide + creation default, never placement (ADR 0017). */
export interface Region {
  name: string
  rect: RelRect
  /** Seeds the style class of a node CREATED inside the region (a move never reclassifies). */
  defaultClass?: string
  /** Seeds the created node's anchor. */
  defaultAnchor?: Anchor9
}

/** Layer 2 — master layout: named soft regions. */
export interface LayoutLayer {
  regions: Region[]
}

/** Inset of the furniture safe area from the slide edges, as fractions in [0,1]. */
export interface SafeArea {
  top: number
  right: number
  bottom: number
  left: number
}

export interface PageNumberFurniture {
  show: boolean
  /** Template; `{n}` -> slide index, `{total}` -> deck length. */
  format?: string
  anchor: Anchor9
  class?: string
}

export interface LogoFurniture {
  /** Project-relative path to an asset file. */
  asset: string
  anchor: Anchor9
  /** Width as a fraction of the slide box width. */
  size: number
}

/** A full-width header/footer band with left/center/right text slots. */
export interface BandFurniture {
  slots: { left?: string; center?: string; right?: string }
  class?: string
}

/** Layer 3 — furniture: deck-wide chrome the renderer draws on every slide. */
export interface FurnitureLayer {
  safeArea: SafeArea
  pageNumber?: PageNumberFurniture
  logo?: LogoFurniture
  header?: BandFurniture
  footer?: BandFurniture
}

/** Per-aspect-ratio geometry override (relative-by-default; override to pin a ratio). */
export interface AspectOverride {
  layout?: LayoutLayer
  furniture?: FurnitureLayer
}

export interface Aspect {
  /** Intended ratio, e.g. '16:9'. */
  default: string
  /** ratio -> geometry override. */
  overrides?: Record<string, AspectOverride>
}

/** A theme: one structured document, three layers, per ADR 0017. */
export interface Theme {
  id: string
  name: string
  description?: string
  style: StyleLayer
  layout: LayoutLayer
  furniture: FurnitureLayer
  aspect?: Aspect
}

/**
 * The built-in default theme: a clean, neutral identity every deck inherits until it
 * selects another. Reproduces the engine's prior look (bold title on white) and gives
 * sensible role defaults, a title/content master layout, and a page-number slot that
 * is off by default.
 */
export const defaultTheme: Theme = {
  id: 'default',
  name: 'Default',
  description: 'Clean neutral built-in theme.',
  style: {
    palette: { bg: '#ffffff', ink: '#1b1e28', accent: '#3b6ea5' },
    type: {
      bodyFamily: 'system-ui, sans-serif',
      headingFamily: 'system-ui, sans-serif',
      baseSize: 2.6,
      scale: 1.25,
      lineHeight: 1.3,
    },
    classes: {
      title: { family: 'heading', size: 4.2, weight: 'bold', letterSpacing: -0.01, color: 'ink' },
      subtitle: { size: 3.1, color: 'ink' },
      heading: { family: 'heading', size: 3.6, weight: 'bold', color: 'ink' },
      body: { size: 2.6, color: 'ink' },
      caption: { size: 2.1, color: 'ink' },
      box: { border: { width: 1, color: 'accent', radius: 6 } },
      note: { size: 2.2, background: '#fffbe6', border: { width: 1, color: '#e8d97a', radius: 4 } },
    },
    nodeDistance: 0.5,
  },
  layout: {
    regions: [
      {
        name: 'title',
        rect: { x: 0.06, y: 0.05, w: 0.88, h: 0.17 },
        defaultClass: 'title',
        defaultAnchor: 'top-left',
      },
      {
        name: 'content',
        rect: { x: 0.06, y: 0.26, w: 0.88, h: 0.68 },
        defaultClass: 'body',
        defaultAnchor: 'top-left',
      },
    ],
  },
  furniture: {
    safeArea: { top: 0.04, right: 0.04, bottom: 0.04, left: 0.04 },
    pageNumber: { show: false, format: '{n}', anchor: 'bottom-right' },
  },
  aspect: { default: '16:9' },
}
