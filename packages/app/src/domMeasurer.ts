/**
 * DOM text measurer. Contract: see domMeasurer.md.
 *
 * The real answer to the layout pass's `BatchMeasurer` seam (Track-0 spike): render
 * each node's actual HTML into an offscreen slide and read its box, instead of the
 * naive character estimate. Because the slide's type is proportional (cqw against the
 * slide box, slideType.ts), measuring at one fixed reference width yields slide-unit
 * sizes that hold at every rendered size — thumbnail, canvas, or exported page.
 *
 * It implements `BatchMeasurer` (async + batched): async so it can await
 * `document.fonts.ready` (and, later, math typesetting) before trusting any box;
 * batched so a slide's nodes are inserted together, laid out in one reflow, and read
 * in one pass. Results are cached by content, so re-rendering the whole deck on every
 * keystroke only measures the nodes that actually changed.
 */
import {
  renderContent,
  type BatchMeasurer,
  type MeasureInput,
  type Size,
} from '@slideblaster/editor'
import { SLIDE_THEME_CSS, SLIDE_TYPE_CSS } from './slideType'
import { renderOptions } from './tableCompiler'

const SLIDE_W = 16
/** Reference slide width in px. Larger = finer sub-pixel precision; the unit result
 *  is width-invariant (type is cqw), so any value is correct — 1600 gives 100px/unit. */
const REF_PX = 1600
const PER_UNIT = REF_PX / SLIDE_W
/** Floors so an empty or whitespace node still has a grabbable box (mirrors the naive measurer). */
const MIN_W = 1
const MIN_H = 0.6

/** Structural overrides for the offscreen slide — metrics-neutral (no font changes). */
const MEASURE_CSS = [
  '.sb-measure-root{position:fixed;left:-10000px;top:0;visibility:hidden;pointer-events:none}',
  // Let the slide grow to its content instead of clipping to 16:9, so tall nodes measure true.
  '.sb-measure-root .sb-slide{height:auto;overflow:visible}',
  // Flow the nodes as blocks (the display slide positions them absolutely).
  '.sb-measure-root .sb-content{position:static}',
  '.sb-measure-root .sb-node{position:static;display:block}',
].join('\n')

export interface DomMeasurer extends BatchMeasurer {
  /** Drop all cached boxes so the next measure re-reads the DOM. Called when a
   *  deferred table finishes compiling: its content key is unchanged but its true
   *  size is now larger than the placeholder that was measured. */
  reset(): void
  dispose(): void
}

export function createDomMeasurer(): DomMeasurer {
  ensureStyle()
  const root = document.createElement('div')
  root.className = 'sb-measure-root'
  const slide = document.createElement('div')
  slide.className = 'sb-slide'
  slide.style.width = `${REF_PX}px`
  const content = document.createElement('div')
  content.className = 'sb-content'
  slide.append(content)
  root.append(slide)
  document.body.append(root)

  const cache = new Map<string, Size>()
  let fontsReady: Promise<unknown> | null = null

  const measureMisses = (inputs: readonly MeasureInput[]): void => {
    const els: HTMLElement[] = []
    content.replaceChildren()
    for (const input of inputs) {
      const el = document.createElement('div')
      el.className = ['sb-node', ...input.styleClasses.map((c) => `sb-style-${c}`)].join(' ')
      // Fixed `text width` wraps to that width (read the height); otherwise take the
      // node's natural width (widest line) with `max-content`.
      el.style.width =
        input.textWidth !== undefined ? `${input.textWidth * PER_UNIT}px` : 'max-content'
      // `minimum height` is a grow-only floor: the box reads at least this tall, but taller
      // content still wins (CSS min-height never clips), matching the naive measurer.
      if (input.minHeight !== undefined) el.style.minHeight = `${input.minHeight * PER_UNIT}px`
      el.innerHTML = renderContent(input.content, renderOptions)
      content.append(el)
      els.push(el)
    }
    // One forced reflow, then read every box.
    inputs.forEach((input, i) => {
      const rect = els[i]!.getBoundingClientRect()
      cache.set(keyOf(input), {
        width: Math.max(MIN_W, rect.width / PER_UNIT),
        height: Math.max(MIN_H, rect.height / PER_UNIT),
      })
    })
    content.replaceChildren()
  }

  return {
    async measureAll(inputs) {
      if (fontsReady === null) fontsReady = document.fonts?.ready ?? Promise.resolve()
      await fontsReady
      const misses = inputs.filter((i) => !cache.has(keyOf(i)))
      if (misses.length > 0) measureMisses(dedupe(misses))
      return inputs.map((i) => cache.get(keyOf(i))!)
    },
    reset() {
      cache.clear()
    },
    dispose() {
      root.remove()
    },
  }
}

/** Cache key: same content + style + fixed width + height floor ⇒ same box. */
function keyOf(input: MeasureInput): string {
  return JSON.stringify([
    input.content,
    input.styleClasses,
    input.textWidth ?? null,
    input.minHeight ?? null,
  ])
}

/** Drop repeats within a batch so identical nodes are measured once. */
function dedupe(inputs: MeasureInput[]): MeasureInput[] {
  const seen = new Set<string>()
  return inputs.filter((i) => {
    const k = keyOf(i)
    if (seen.has(k)) return false
    seen.add(k)
    return true
  })
}

let styleInjected = false
function ensureStyle(): void {
  if (styleInjected) return
  styleInjected = true
  const style = document.createElement('style')
  style.dataset.sb = 'measure'
  style.textContent = `${SLIDE_THEME_CSS}\n${SLIDE_TYPE_CSS}\n${MEASURE_CSS}`
  document.head.append(style)
}
