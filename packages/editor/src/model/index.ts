/** The document model. Contract: see index.md. */
export type { SlideDocument, DocumentMeta, FrontmatterEntry, Frame } from './document'
export { getMeta } from './document'
export type {
  TikzPicture,
  Statement,
  NodeStatement,
  NodeContent,
  PathStatement,
  CoordinateStatement,
  VerbatimStatement,
  Point,
} from './tikz'
