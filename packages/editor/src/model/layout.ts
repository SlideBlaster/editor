/**
 * Resolved geometry of a slide picture. Contract: see layout.md.
 *
 * The output of the measure->resolve pass (ADR 0014): every node gets a `center`
 * (slide space, y-up, 0..16 x 0..9) and a `size`. Slide space is unitless here; the
 * pixel transform is a render concern (B3). Nodes are in the same order as the
 * picture's node statements, so a renderer can zip layout with content.
 */
import type { Point } from './tikz'

export interface Size {
  width: number
  height: number
}

/** A node placed in slide space. `styleClasses` is carried for the renderer. */
export interface PlacedNode {
  name?: string
  center: Point
  size: Size
  styleClasses: string[]
}

export interface Layout {
  nodes: PlacedNode[]
}
