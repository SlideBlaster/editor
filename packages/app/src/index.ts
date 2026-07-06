/**
 * Public surface of the shared editor app. Contract: see index.md.
 *
 * Both shells import `createApp` from here and mount it into their root element.
 */
export { createApp, type CreateAppOptions } from './createApp'
export type { AppPorts } from './workspace'
export { renderHome, type HomeDeps } from './home'
export {
  createProjectRegistry,
  type Project,
  type ProjectRegistry,
  type StorageLike,
} from './projects'
