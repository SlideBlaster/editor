/**
 * Types shared across more than one port. Contract: see common.md.
 */

/** Cancels a subscription registered with a `watch` / `on` style call. */
export type Unsubscribe = () => void
