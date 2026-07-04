/**
 * @slideblaster/editor public surface. Contract: see index.md.
 *
 * The six port interfaces plus the engine's format spine (M1): the document model,
 * the markdown container round-trip, and the TikZ picture parse/serialize.
 */
export * from './ports/index'
export * from './model/index'
export { fromMarkdown, toMarkdown } from './markdown/index'
export { parsePicture, serializePicture, styleClasses, role, placementToken } from './tikz/index'
export {
  parseContent,
  serializeContent,
  serializeRuns,
  inlineStyleOf,
  dialectOf,
  OutOfSubsetError,
} from './content/index'
export type { InlineStyle } from './content/index'
