/**
 * The stencil registry: normalized SVG path data for imported draw.io stencils.
 * Contract: see stencils.md.
 *
 * A stencil is a `\node` carrying a `stencil=<id>` option token (tikz/options `stencilId`);
 * this maps that id to a normalized SVG path `d` in a [0,1]x[0,1] y-down box. `render/shape`
 * drops that path under a `translate/scale` transform to fill the node's rect, so the palette
 * thumbnail and the canvas outline are drawn from the SAME data — they can never diverge.
 *
 * The `STENCILS` map itself is GENERATED from curated stencil JSON by
 * `packages/editor/tools/stencil-assemble.mjs`; this module is the stable lookup API over it.
 */
import type { Rect } from './shape'
import { STENCILS } from './stencils.generated'

/** The normalized path `d` for a stencil id, or undefined if the id is unknown. */
export function stencilPath(id: string): string | undefined {
  return STENCILS[id]
}

/** Round to 4 dp and trim trailing zeros — matches `render/shape`'s numeric output. */
function r(n: number): string {
  return String(Number(n.toFixed(4)))
}

/**
 * Place a normalized stencil path (`d` in a [0,1]x[0,1] box) into `rect`, in absolute SVG
 * user units. The scale is baked into the coordinates — NOT applied as an SVG `transform` —
 * so the stroke stays a slide-unit width like every other shape (a `scale()` transform would
 * fatten/distort it, and non-scaling-stroke would desync it from neighbours at zoom).
 *
 * The registry emits only absolute `M`/`L`/`C`/`Q`/`A`/`Z` commands. Coordinate pairs map by
 * `x -> rect.x + x*rect.width`, `y -> rect.y + y*rect.height`; an arc's leading `rx ry` scale
 * by width/height and its `rotation large sweep` flags pass through untouched. Unknown command
 * letters pass through verbatim.
 */
export function placeStencilPath(d: string, rect: Rect): string {
  const px = (x: number) => r(rect.x + x * rect.width)
  const py = (y: number) => r(rect.y + y * rect.height)
  const tokens = d.trim().split(/\s+/)
  const out: string[] = []
  let i = 0
  while (i < tokens.length) {
    const cmd = tokens[i++]
    if (cmd === undefined) break
    const n = (k: number) => Number(tokens[i + k])
    const raw = (k: number) => tokens[i + k] ?? '0'
    switch (cmd) {
      case 'M':
      case 'L':
        out.push(cmd, px(n(0)), py(n(1)))
        i += 2
        break
      case 'C':
        out.push(cmd, px(n(0)), py(n(1)), px(n(2)), py(n(3)), px(n(4)), py(n(5)))
        i += 6
        break
      case 'Q':
        out.push(cmd, px(n(0)), py(n(1)), px(n(2)), py(n(3)))
        i += 4
        break
      case 'A':
        // rx ry rotation large-arc sweep x y — radii scale per axis, flags pass through.
        out.push(
          cmd,
          r(n(0) * rect.width),
          r(n(1) * rect.height),
          raw(2),
          raw(3),
          raw(4),
          px(n(5)),
          py(n(6)),
        )
        i += 7
        break
      default:
        out.push(cmd) // 'Z' and any unexpected token
        break
    }
  }
  return out.join(' ')
}
