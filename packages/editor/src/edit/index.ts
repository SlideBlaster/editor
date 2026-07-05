/** Node-granular edit operations (E1+). Contract: see index.md. */
export {
  findNode,
  uniqueName,
  moveNodeTo,
  createNode,
  deleteNode,
  setNodeContent,
  placeNodeRelative,
  adjustPlacement,
} from './ops'
export type { NodeSpec } from './ops'
