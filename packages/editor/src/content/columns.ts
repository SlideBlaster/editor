/**
 * Pure structural edits on `columns` groups. Contract: see columns.md.
 *
 * These back the canvas grid affordance (ADR 0016): a gesture on a divider / "+"
 * produces exactly one of these immutable `NodeContent` transforms, from which the
 * controller derives the source and canvas deltas. They address the `groupIndex`-th
 * `columns` run in **document (pre-order) order** — the same order the renderer emits
 * `.sb-columns` elements, so a `data-path` index from the DOM maps here exactly.
 *
 * Everything else about the content is preserved (children, dialects, other runs), so
 * `serializeBody` round-trips byte-for-byte except at the columns touched.
 */
import type { Column, NodeContent, TextRun } from '../model/content'

/** Walk pre-order to the `groupIndex`-th `columns` run and replace its columns via `fn`. */
function transformColumnsGroup(
  content: NodeContent,
  groupIndex: number,
  fn: (columns: readonly Column[]) => Column[],
): NodeContent {
  if (content.kind !== 'text') return content
  let seen = -1
  const mapRuns = (runs: readonly TextRun[]): TextRun[] => runs.map(mapRun)
  const mapRun = (run: TextRun): TextRun => {
    switch (run.kind) {
      case 'columns': {
        // Count this group before recursing, so the pre-order index matches the DOM.
        const isTarget = ++seen === groupIndex
        const columns = run.columns.map((col) => ({ ...col, children: mapRuns(col.children) }))
        return { ...run, columns: isTarget ? fn(columns) : columns }
      }
      case 'latex':
      case 'markdown':
      case 'html':
      case 'overlay':
        return { ...run, children: mapRuns(run.children) }
      case 'list':
        return {
          ...run,
          items: run.items.map((item) => ({ ...item, children: mapRuns(item.children) })),
        }
      case 'matrix':
        return {
          ...run,
          rows: run.rows.map((row) => row.map((cell) => ({ children: mapRuns(cell.children) }))),
        }
      default:
        return run
    }
  }
  return { ...content, runs: mapRuns(content.runs) }
}

/**
 * Replace widths of specific columns in the `groupIndex`-th `columns` run. `patch`
 * maps a column index to its new raw `\column{…}` width; columns not in the patch keep
 * their source width (so a two-neighbour divider drag never rewrites the others).
 */
export function setColumnWidths(
  content: NodeContent,
  groupIndex: number,
  patch: Readonly<Record<number, string>>,
): NodeContent {
  return transformColumnsGroup(content, groupIndex, (columns) =>
    columns.map((col, i) => (i in patch ? { ...col, width: patch[i]! } : col)),
  )
}

/** Insert an empty column with `width` at position `at` (clamped) in the group. */
export function insertColumn(
  content: NodeContent,
  groupIndex: number,
  at: number,
  width: string,
): NodeContent {
  return transformColumnsGroup(content, groupIndex, (columns) => {
    const i = Math.max(0, Math.min(at, columns.length))
    return [...columns.slice(0, i), { width, children: [] }, ...columns.slice(i)]
  })
}

/** Remove the column at `at` in the group. No-op if out of range or it is the last one
 *  (a `columns` group keeps at least one column). */
export function removeColumn(content: NodeContent, groupIndex: number, at: number): NodeContent {
  return transformColumnsGroup(content, groupIndex, (columns) => {
    if (at < 0 || at >= columns.length || columns.length <= 1) return [...columns]
    return [...columns.slice(0, at), ...columns.slice(at + 1)]
  })
}
