/** The document model. Contract: see index.md. */
export type { SlideDocument, DocumentMeta, FrontmatterEntry, Frame } from './document'
export { getMeta } from './document'
export type {
  TikzPicture,
  Statement,
  NodeStatement,
  PathStatement,
  CoordinateStatement,
  VerbatimStatement,
  Point,
} from './tikz'
export type {
  NodeContent,
  TextRun,
  ListItem,
  Column,
  MatrixCell,
  LatexCommand,
  MarkdownMarker,
  FragmentName,
  OverlaySpec,
  OverlayCommand,
  DeferredFeature,
  Dialect,
} from './content'
