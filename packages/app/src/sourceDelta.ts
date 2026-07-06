/**
 * Minimal single-range diff between two source strings. Contract: see sourceDelta.md.
 *
 * The source half of the node-scoped commit (ADR 0016): after a canvas edit we
 * re-serialize the whole document (`toMarkdown`, cheap) and turn old -> new into the
 * one contiguous range that changed, so the code pane can apply it with
 * `replaceRange` and keep the caret — instead of a whole-document `setValue`. For a
 * localized content edit the change is contiguous, so the range is tight.
 */

/** A contiguous replacement: splice `text` into `[start, end)` of the old string. */
export interface RangeEdit {
  start: number
  end: number
  text: string
}

/**
 * The single contiguous range that differs between `oldStr` and `newStr`, found by
 * the longest common prefix and (non-overlapping) common suffix. Identical strings
 * yield an empty edit at their end. This is the minimal single-range edit; it is not
 * a multi-hunk diff (a node-scoped content edit only ever changes one region).
 */
export function minimalDiff(oldStr: string, newStr: string): RangeEdit {
  const maxStart = Math.min(oldStr.length, newStr.length)
  let start = 0
  while (start < maxStart && oldStr[start] === newStr[start]) start++

  // Common suffix, stopping so neither cursor crosses `start` (no overlap on pure
  // insert/delete, where the changed region is empty on one side).
  let endOld = oldStr.length
  let endNew = newStr.length
  while (endOld > start && endNew > start && oldStr[endOld - 1] === newStr[endNew - 1]) {
    endOld--
    endNew--
  }
  return { start, end: endOld, text: newStr.slice(start, endNew) }
}

/** Apply a `RangeEdit` — the inverse of `minimalDiff`: `applyRange(a, minimalDiff(a,b)) === b`. */
export function applyRange(s: string, edit: RangeEdit): string {
  return s.slice(0, edit.start) + edit.text + s.slice(edit.end)
}
