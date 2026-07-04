/**
 * Derived, read-only views over a node's raw option tokens. Contract: see
 * options.md. These recompute from `NodeStatement.options` (the serialization
 * truth) so they never desynchronize; nothing here is stored on the model.
 */
import type { NodeStatement } from '../model/tikz'

/** Bare (non `key=value`) tokens that name a style class, e.g. `title`, `body`. */
export function styleClasses(node: NodeStatement): string[] {
  return node.options.filter((token) => !token.includes('=') && !/^[<|>.-]+$/.test(token))
}

/** The `title` style class marks the slide's title node. */
export function role(node: NodeStatement): 'title' | undefined {
  return styleClasses(node).includes('title') ? 'title' : undefined
}

/** The first relative-placement token (`below=0.7 of title`), if any. */
export function placementToken(node: NodeStatement): string | undefined {
  return node.options.find((token) => /^(above|below|left|right)\b.*=.*\bof\b/.test(token))
}
