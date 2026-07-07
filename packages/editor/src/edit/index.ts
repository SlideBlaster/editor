/** Node-granular edit operations (E1+). Contract: see index.md. */
export {
  findNode,
  uniqueName,
  moveNodeTo,
  resizeNode,
  createNode,
  deleteNode,
  setNodeContent,
  setNodeStyleClass,
  setNodeOptions,
  setNodeOverlay,
  placeNodeRelative,
  adjustPlacement,
  createConnector,
  deleteConnector,
  updateConnector,
  connectorOptions,
  setConnectorOptions,
} from './ops'
export type { NodeSpec } from './ops'
