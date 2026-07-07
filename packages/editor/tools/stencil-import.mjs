#!/usr/bin/env node
/**
 * stencil-import: mxGraph stencil XML -> normalized SlideBlaster stencil JSON.
 *
 * The first, mechanical stage of the stencil pipeline (design/format/stencil-pipeline.md).
 * A draw.io stencil is an XML `<shape>` whose `<background>`/`<foreground>` draw with
 * HTML5-Canvas-like primitives (`move`/`line`/`curve`/`quad`/`arc`/`close`, and the
 * self-contained `rect`/`roundrect`/`ellipse`) in the shape's own `w`x`h` coordinate box.
 * Those primitives map 1:1 to an SVG path, so this converter is pure geometry: it flattens
 * every drawing op into ONE SVG `d` string in a normalized [0,1]x[0,1] box (y-down, ready to
 * drop under a `translate/scale` transform). Fill vs stroke intent is discarded — a stencil
 * shape renders as an outline that inherits the node's theme stroke/fill, matching the rest
 * of the library.
 *
 * Output is intermediate JSON (one file per input, `<set>.stencils.json`), not TS: the
 * curation swarm edits the JSON (labels, keywords, category, dropping junk), then
 * `stencil-assemble.mjs` deterministically renders the two generated TS files.
 *
 * Usage:  node stencil-import.mjs <set> <in.xml> [out.json]
 *   <set>  short set key + category, e.g. `flowchart` or `electrical/resistors`
 *   writes <out.json> (default: <basename>.stencils.json in cwd).
 *
 * No dependencies (Node >=18, ESM). The stencil XML subset is small and regular enough to
 * parse with scoped regexes; this is build-time tooling, not shipped runtime.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { basename } from 'node:path'

/** Round to 4 dp, trim trailing zeros — stable, compact path output. */
const r = (n) => String(Number(n.toFixed(4)))

/** kebab slug of a shape name: lowercase, non-alphanumerics -> single '-'. */
const slug = (s) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')

/** Title-case a set key segment for a category label (`lean_mapping` -> `Lean Mapping`). */
const titleCase = (s) =>
  s
    .replace(/[_-]+/g, ' ')
    .replace(/\b\w/g, (c) => c.toUpperCase())
    .trim()

/** Parse the attributes of a single tag body (`x="5" y="0"`) into a plain object. */
function attrs(body) {
  const out = {}
  for (const m of body.matchAll(/([\w-]+)\s*=\s*"([^"]*)"/g)) out[m[1]] = m[2]
  return out
}
const num = (v, dflt = 0) => {
  const n = Number(v)
  return Number.isFinite(n) ? n : dflt
}

/**
 * Flatten one shape's inner XML (background + foreground) to a normalized SVG `d`.
 * `W`/`H` are the shape's coordinate box; every coordinate is divided by them so the path
 * lives in [0,1]. Drawing ops are emitted in document order; `move` and the self-contained
 * `rect`/`roundrect`/`ellipse` each open a new subpath.
 */
function toPathData(inner, W, H) {
  const nx = (x) => r(num(x) / W)
  const ny = (y) => r(num(y) / H)
  // arc radii scale with their axis; a rough but faithful normalization for outlines.
  const nrx = (v) => r(num(v) / W)
  const nry = (v) => r(num(v) / H)
  const cmds = []
  const tag = /<(move|line|curve|quad|arc|close|rect|roundrect|ellipse)\b([^>]*?)\/?>/g
  let m
  while ((m = tag.exec(inner))) {
    const a = attrs(m[2])
    switch (m[1]) {
      case 'move':
        cmds.push(`M ${nx(a.x)} ${ny(a.y)}`)
        break
      case 'line':
        cmds.push(`L ${nx(a.x)} ${ny(a.y)}`)
        break
      case 'curve':
        cmds.push(`C ${nx(a.x1)} ${ny(a.y1)} ${nx(a.x2)} ${ny(a.y2)} ${nx(a.x3)} ${ny(a.y3)}`)
        break
      case 'quad':
        cmds.push(`Q ${nx(a.x1)} ${ny(a.y1)} ${nx(a.x2)} ${ny(a.y2)}`)
        break
      case 'arc':
        cmds.push(
          `A ${nrx(a.rx)} ${nry(a.ry)} ${num(a['x-axis-rotation'])} ` +
            `${num(a['large-arc-flag'])} ${num(a['sweep-flag'])} ${nx(a.x)} ${ny(a.y)}`,
        )
        break
      case 'close':
        cmds.push('Z')
        break
      case 'rect': {
        const x = num(a.x),
          y = num(a.y),
          w = num(a.w),
          h = num(a.h)
        cmds.push(
          `M ${nx(x)} ${ny(y)} L ${nx(x + w)} ${ny(y)} L ${nx(x + w)} ${ny(y + h)} ` +
            `L ${nx(x)} ${ny(y + h)} Z`,
        )
        break
      }
      case 'roundrect': {
        const x = num(a.x),
          y = num(a.y),
          w = num(a.w),
          h = num(a.h)
        // arcsize is a percentage of the shorter side (mxGraph semantics).
        const rad = (Math.min(w, h) * num(a.arcsize, 0)) / 100
        const rw = nrx(rad),
          rh = nry(rad)
        cmds.push(
          `M ${nx(x + rad)} ${ny(y)} L ${nx(x + w - rad)} ${ny(y)} ` +
            `A ${rw} ${rh} 0 0 1 ${nx(x + w)} ${ny(y + rad)} L ${nx(x + w)} ${ny(y + h - rad)} ` +
            `A ${rw} ${rh} 0 0 1 ${nx(x + w - rad)} ${ny(y + h)} L ${nx(x + rad)} ${ny(y + h)} ` +
            `A ${rw} ${rh} 0 0 1 ${nx(x)} ${ny(y + h - rad)} L ${nx(x)} ${ny(y + rad)} ` +
            `A ${rw} ${rh} 0 0 1 ${nx(x + rad)} ${ny(y)} Z`,
        )
        break
      }
      case 'ellipse': {
        const x = num(a.x),
          y = num(a.y),
          w = num(a.w),
          h = num(a.h)
        const cy = ny(y + h / 2)
        cmds.push(
          `M ${nx(x)} ${cy} A ${nrx(w / 2)} ${nry(h / 2)} 0 0 1 ${nx(x + w)} ${cy} ` +
            `A ${nrx(w / 2)} ${nry(h / 2)} 0 0 1 ${nx(x)} ${cy} Z`,
        )
        break
      }
    }
  }
  return cmds.join(' ')
}

/** Default drop size (slide units) preserving the shape's natural aspect, longer side ~2.4. */
function defaultSize(W, H) {
  const MAX = 2.4,
    MIN = 0.8
  let w = MAX,
    h = MAX
  if (W >= H) h = Math.max(MIN, (MAX * H) / W)
  else w = Math.max(MIN, (MAX * W) / H)
  return { width: Number(w.toFixed(2)), height: Number(h.toFixed(2)) }
}

function convert(setKey, xml) {
  const category = setKey.split('/').map(titleCase).join(' / ')
  const filePrefix = setKey.split('/').pop()
  const shapes = []
  const seen = new Set()
  const shapeRe = /<shape\b([^>]*)>([\s\S]*?)<\/shape>/g
  let m
  while ((m = shapeRe.exec(xml))) {
    const a = attrs(m[1])
    const name = (a.name || '').trim()
    if (!name) continue
    const W = num(a.w, 100),
      H = num(a.h, 100)
    const d = toPathData(m[2], W, H)
    if (!d) continue // no geometry (e.g. text-only / image stencils) — skip
    let id = `${filePrefix}.${slug(name)}`
    while (seen.has(id)) id += '_' // guard against slug collisions within a set
    seen.add(id)
    const words = Array.from(
      new Set(
        slug(name)
          .split('-')
          .filter((w) => w.length > 1),
      ),
    )
    shapes.push({
      id,
      label: name,
      category,
      keywords: words,
      options: ['draw', `stencil=${id}`],
      size: defaultSize(W, H),
      aspect: a.aspect || 'variable',
      d,
    })
  }
  return { set: setKey, category, shapes }
}

// --- CLI -------------------------------------------------------------------
const [, , setKey, inPath, outPath] = process.argv
if (!setKey || !inPath) {
  console.error('usage: node stencil-import.mjs <set> <in.xml> [out.json]')
  process.exit(2)
}
const out = outPath || `${basename(inPath).replace(/\.xml$/, '')}.stencils.json`
const result = convert(setKey, readFileSync(inPath, 'utf8'))
writeFileSync(out, JSON.stringify(result, null, 2) + '\n')
console.error(`${result.set}: ${result.shapes.length} shapes -> ${out}`)
