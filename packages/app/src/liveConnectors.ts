/**
 * Live connector re-routing during a node drag/resize. Contract: see liveConnectors.md.
 *
 * A node move/resize previews by translating/scaling the node in place — but the arrows
 * attached to it are drawn in the geometry SVG at resolved slide coordinates, so without
 * help they sit frozen until the commit re-render and then jump to their new endpoints
 * (the "snappy" feel). This recomputes every connector against a layout with the dragged
 * node's box replaced by its live on-screen box, then rewrites the SVG path data in place —
 * both the visible arrow (`.sb-arrow`, geometry layer) and the overlay hit-line
 * (`[data-connector]`) — so an attached arrow tracks the node continuously. Only paths whose
 * geometry actually changed are touched (unattached arrows resolve identically and are
 * skipped). The commit's re-render then rebuilds them for real — same geometry, no jump.
 */
import {
  connectorsOf,
  type Layout,
  type PlacedNode,
  type Point,
  type TikzPicture,
} from '@slideblaster/editor'
import type { SnapSize } from './snap'

export function rerouteConnectors(
  picture: TikzPicture,
  layout: Layout,
  node: PlacedNode,
  box: { center: Point; size: SnapSize },
  slideEl: HTMLElement,
  overlay: HTMLElement,
): void {
  // Same layout with just the dragged node's box swapped for its live one; node-anchored
  // endpoints (`(name)` / `(name.north)`) resolve against the new center/size and re-route.
  const patched: Layout = {
    ...layout,
    nodes: layout.nodes.map((n) => (n === node ? { ...n, center: box.center, size: box.size } : n)),
  }
  for (const connector of connectorsOf(picture, patched)) {
    const arrow = slideEl.querySelector<SVGPathElement>(
      `path.sb-arrow[data-arrow="${connector.index}"]`,
    )
    if (arrow && arrow.getAttribute('d') !== connector.pathData)
      arrow.setAttribute('d', connector.pathData)
    const hit = overlay.querySelector<SVGPathElement>(`path[data-connector="${connector.index}"]`)
    if (hit && hit.getAttribute('d') !== connector.pathData)
      hit.setAttribute('d', connector.pathData)
  }
}
