/**
 * @slideblaster/editor public surface. Contract: see index.md.
 *
 * The six port interfaces plus the engine's format spine (M1): the document model,
 * the markdown container round-trip, and the TikZ picture parse/serialize.
 */
export * from './ports/index'
export * from './model/index'
export { fromMarkdown, toMarkdown } from './markdown/index'
export {
  parsePicture,
  serializePicture,
  styleClasses,
  role,
  placementToken,
  placement,
  parseConnector,
  serializeConnector,
} from './tikz/index'
export type { Placement, ConnectorPath, Anchor, CurveControls } from './tikz/index'
export {
  parseContent,
  serializeContent,
  serializeBody,
  serializeRuns,
  inlineStyleOf,
  dialectOf,
  setColumnWidths,
  insertColumn,
  removeColumn,
  OutOfSubsetError,
} from './content/index'
export type { InlineStyle } from './content/index'
export {
  resolveLayout,
  resolveLayoutAsync,
  anchor,
  findPlaced,
  isAnchorName,
  naiveMeasurer,
  asBatch,
} from './layout/index'
export type {
  AnchorName,
  Measurer,
  MeasureInput,
  BatchMeasurer,
  Layout,
  PlacedNode,
  Size,
} from './layout/index'
export { renderContent, renderSlide, slideStylesheet, connectorsOf } from './render/index'
export type { RenderOptions, Connector } from './render/index'
export {
  findNode,
  uniqueName,
  moveNodeTo,
  createNode,
  deleteNode,
  setNodeContent,
  placeNodeRelative,
  adjustPlacement,
  createConnector,
  deleteConnector,
  updateConnector,
  connectorOptions,
  setConnectorOptions,
} from './edit/index'
export type { NodeSpec } from './edit/index'
