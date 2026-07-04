/**
 * The format invariants as reusable predicates. Contract: see invariants.md.
 *
 * These encode the five laws from slideblaster-md.md so they can drive both
 * example (golden) and property-based tests.
 */
import type { SlideDocument } from '../model/document'
import type { NodeStatement, Statement } from '../model/tikz'
import { fromMarkdown } from '../markdown/fromMarkdown'
import { toMarkdown } from '../markdown/toMarkdown'

/** Order-insensitive structural equality key for plain-data models. */
export function stableStringify(value: unknown): string {
  return JSON.stringify(sortKeys(value))
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys)
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {}
    for (const key of Object.keys(value as object).sort()) {
      const child = (value as Record<string, unknown>)[key]
      if (child !== undefined) out[key] = sortKeys(child)
    }
    return out
  }
  return value
}

/** Invariant 1 — round-trip: `fromMarkdown(toMarkdown(model)) == model`. */
export function modelRoundTrips(doc: SlideDocument): boolean {
  return stableStringify(fromMarkdown(toMarkdown(doc))) === stableStringify(doc)
}

/** Invariant 2 — canonical form: `toMarkdown(fromMarkdown(text)) == text`. */
export function textIsCanonical(text: string): boolean {
  return toMarkdown(fromMarkdown(text)) === text
}

function isNode(statement: Statement): statement is NodeStatement {
  return statement.kind === 'node'
}

/** Node names in document order — the stable-identity fingerprint (invariant 4). */
export function nodeNames(doc: SlideDocument): (string | undefined)[] {
  return doc.frames.flatMap((frame) => frame.picture.statements.filter(isNode).map((n) => n.name))
}

/** Invariant 4 — stable identity: names survive the round-trip unchanged. */
export function identityPreserved(doc: SlideDocument): boolean {
  return (
    stableStringify(nodeNames(fromMarkdown(toMarkdown(doc)))) === stableStringify(nodeNames(doc))
  )
}
