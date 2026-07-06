/** Theme model + style-layer stylesheet + region geometry (ADR 0017). See theme.md, css.md, regions.md. */
export * from './theme'
export { themeStylesheet } from './css'
export { regionRects, regionAt, regionGuides, slideBoxFromMeta, DEFAULT_SLIDE_BOX } from './regions'
export type { RegionRect, RegionGuides, SlideBox } from './regions'
export { serializeTheme, parseTheme, ThemeParseError } from './serialize'
export { furnitureHtml, furnitureCss } from './furniture'
export type { FurnitureContext } from './furniture'
