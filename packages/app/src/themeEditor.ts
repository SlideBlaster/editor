/**
 * The theme studio — a direct-manipulation editor over a `Theme` (ADR 0017). Contract: see
 * themeEditor.md.
 *
 * Instead of a form over the JSON, the author works on a faithful themed slide canvas:
 * region boundaries are draggable/resizable rectangles, and the logo and page number are
 * chips you drag to one of the nine anchors. A lean rail carries the non-spatial bits
 * (name, aspect, palette, the selected object's fields, save). Edits stream through
 * `onChange` for live preview on the real deck behind; `onSave` persists.
 *
 * Self-contained DOM (inline styles); the only engine coupling is the `Theme` model and
 * `themeStylesheet`, which renders the preview canvas exactly like the deck — so it is
 * safe to build/verify against the engine alone.
 */
import { themeStylesheet } from '@slideblaster/editor'
import type { Anchor9, Theme, Region, RelRect } from '@slideblaster/editor'

export interface ThemeEditorHandle {
  close(): void
}

export interface ThemeEditorOptions {
  theme: Theme
  showRegions: boolean
  /** Fires on every edit with the working theme, for live preview. */
  onChange: (theme: Theme, opts: { showRegions: boolean }) => void
  /** Persist the theme (write the JSON file). */
  onSave: (theme: Theme) => void | Promise<void>
  onClose?: () => void
}

/** The nine furniture/region anchor slots, row-major (top→bottom, left→right). */
const ANCHORS: Anchor9[] = [
  'top-left',
  'top-center',
  'top-right',
  'mid-left',
  'center',
  'mid-right',
  'bottom-left',
  'bottom-center',
  'bottom-right',
]

const ASPECTS = ['16:9', '4:3', '16:10'] as const

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: Partial<HTMLElementTagNameMap[K]> = {},
  style = '',
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag)
  Object.assign(node, props)
  if (style) node.style.cssText = style
  return node
}

const clamp01 = (n: number): number => Math.max(0, Math.min(1, n))

/** Parse an `w:h` ratio to its numeric value (width / height); default 16:9. */
function ratioOf(aspect: string): number {
  const m = /^\s*(\d+(?:\.\d+)?)\s*[:x/]\s*(\d+(?:\.\d+)?)\s*$/.exec(aspect)
  if (!m) return 16 / 9
  const w = Number(m[1])
  const h = Number(m[2])
  return w > 0 && h > 0 ? w / h : 16 / 9
}

/** Prefix every flat rule's selector list with `scope`, so an emitted stylesheet only
 *  paints inside the preview and never leaks onto the real deck. themeStylesheet is flat
 *  (no nesting / no @media), so a single-rule regex suffices. */
function scopeCss(css: string, scope: string): string {
  return css.replace(/([^{}]+)\{([^{}]*)\}/g, (_m, sel: string, body: string) => {
    const scoped = sel
      .split(',')
      .map((s) => `${scope} ${s.trim()}`)
      .join(',')
    return `${scoped}{${body}}`
  })
}

/** Row/column an anchor selects, in {-1,0,1} (0 = centre). */
function anchorAxes(a: Anchor9): { col: number; row: number } {
  const col = a.endsWith('left') ? -1 : a.endsWith('right') ? 1 : 0
  const row = a.startsWith('top') ? -1 : a.startsWith('bottom') ? 1 : 0
  return { col, row }
}

/** The nine-slot anchor nearest a centre point (fractions), matching furnitureCss. */
function anchorFromCentre(cx: number, cy: number): Anchor9 {
  const col = cx < 1 / 3 ? 'left' : cx < 2 / 3 ? 'center' : 'right'
  const row = cy < 1 / 3 ? 'top' : cy < 2 / 3 ? 'mid' : 'bottom'
  if (row === 'mid' && col === 'center') return 'center'
  if (col === 'center') return `${row}-center` as Anchor9
  if (row === 'mid') return `mid-${col}` as Anchor9
  return `${row}-${col}` as Anchor9
}

/** Top-left px of a chip resting at `anchor` in a `cw`×`ch` canvas, honouring the safe
 *  area — reproduces furnitureCss so the preview matches the render. */
function anchorRestPos(
  a: Anchor9,
  safe: { top: number; right: number; bottom: number; left: number },
  cw: number,
  ch: number,
  w: number,
  h: number,
): { left: number; top: number } {
  const { col, row } = anchorAxes(a)
  const left =
    col < 0 ? safe.left * cw : col > 0 ? cw - safe.right * cw - w : cw / 2 - w / 2
  const top = row < 0 ? safe.top * ch : row > 0 ? ch - safe.bottom * ch - h : ch / 2 - h / 2
  return { left, top }
}

/** Open the theme studio over `opts.theme`; returns a handle to close it. */
export function openThemeEditor(opts: ThemeEditorOptions): ThemeEditorHandle {
  const theme: Theme = structuredClone(opts.theme)
  let showRegions = opts.showRegions
  const emit = (): void => opts.onChange(theme, { showRegions })

  type Sel = { kind: 'region'; index: number } | { kind: 'logo' } | { kind: 'pageNumber' } | null
  let selection: Sel = null

  // --- shell ------------------------------------------------------------------------
  const backdrop = el(
    'div',
    { id: 'sb-theme-editor' },
    'position:fixed;inset:0;z-index:50;background:rgba(20,22,30,.5);display:flex;' +
      'align-items:center;justify-content:center;font-family:system-ui,sans-serif',
  )
  const modal = el(
    'div',
    {},
    'width:min(92vw,1120px);height:min(90vh,760px);background:#f6f7f9;color:#1b1e28;' +
      'border-radius:12px;box-shadow:0 12px 48px rgba(0,0,0,.35);display:flex;flex-direction:column;overflow:hidden',
  )
  backdrop.append(modal)

  // topbar -----------------------------------------------------------------------------
  const topbar = el(
    'div',
    {},
    'display:flex;align-items:center;gap:.75rem;padding:.6rem .9rem;border-bottom:1px solid #e2e4e9;background:#fff',
  )
  const nameInput = el(
    'input',
    { type: 'text', value: theme.name, title: 'Theme name' },
    'font-weight:600;font-size:.95rem;border:1px solid transparent;border-radius:6px;padding:.2rem .4rem;min-width:8rem',
  )
  nameInput.addEventListener('focus', () => (nameInput.style.borderColor = '#c9ccd4'))
  nameInput.addEventListener('blur', () => (nameInput.style.borderColor = 'transparent'))
  nameInput.addEventListener('input', () => {
    theme.name = nameInput.value
    emit()
  })
  const aspectSel = el('select', { title: 'Aspect ratio' }, 'font-size:.8rem;padding:.2rem')
  for (const a of ASPECTS)
    aspectSel.append(
      el('option', { value: a, textContent: a, selected: a === (theme.aspect?.default ?? '16:9') }),
    )
  aspectSel.addEventListener('change', () => {
    theme.aspect = { ...(theme.aspect ?? { default: '16:9' }), default: aspectSel.value }
    fitCanvas()
    renderCanvas()
    emit()
  })
  const closeBtn = el(
    'button',
    { type: 'button', textContent: '×', title: 'Close' },
    'margin-left:auto;border:0;background:none;font-size:1.4rem;line-height:1;cursor:pointer;color:#666',
  )
  closeBtn.addEventListener('click', () => close())
  topbar.append(
    el('strong', { textContent: 'Theme studio' }, 'font-size:.82rem;letter-spacing:.02em;color:#888'),
    nameInput,
    el('span', { textContent: 'aspect' }, 'font-size:.72rem;color:#999;margin-left:.4rem'),
    aspectSel,
    closeBtn,
  )
  modal.append(topbar)

  // body: stage + rail ----------------------------------------------------------------
  const body = el('div', {}, 'flex:1;display:flex;min-height:0')
  const stage = el(
    'div',
    { id: 'sb-te-stage' },
    'flex:1;min-width:0;display:flex;align-items:center;justify-content:center;padding:1.4rem;' +
      'background:repeating-conic-gradient(#eceef2 0 25%,#f6f7f9 0 50%) 0 0/22px 22px',
  )
  const preview = el('div', { id: 'sb-te-preview' }, 'position:relative;box-shadow:0 4px 18px rgba(0,0,0,.18)')
  const slide = el(
    'div',
    { className: 'sb-slide' },
    'position:relative;width:100%;height:100%;container-type:inline-size;overflow:hidden;border-radius:2px;background:#fff',
  )
  preview.append(slide)
  stage.append(preview)

  const rail = el(
    'div',
    {},
    'flex:0 0 16.5rem;overflow:auto;background:#fff;border-left:1px solid #e2e4e9;padding:.8rem .9rem',
  )
  body.append(stage, rail)
  modal.append(body)

  // scoped theme CSS: the preview canvas renders exactly like the deck ----------------
  const styleEl = el('style')
  modal.append(styleEl)
  const applyPreviewCss = (): void => {
    styleEl.textContent = scopeCss(themeStylesheet(theme), '#sb-te-preview')
  }

  // ==================================================================================
  // Canvas rendering — regions + furniture chips as interactive overlays
  // ==================================================================================
  let cw = 640
  let ch = 360

  function fitCanvas(): void {
    const r = ratioOf(theme.aspect?.default ?? '16:9')
    const availW = stage.clientWidth - 44
    const availH = stage.clientHeight - 44
    let w = availW
    let h = w / r
    if (h > availH) {
      h = availH
      w = h * r
    }
    cw = Math.max(240, Math.round(w))
    ch = Math.max(135, Math.round(h))
    preview.style.width = `${cw}px`
    preview.style.height = `${ch}px`
  }

  /** Pointer drag helper: reports deltas as canvas fractions from the press point. */
  function drag(
    handle: HTMLElement,
    onMove: (dxFrac: number, dyFrac: number, ev: PointerEvent) => void,
    onEnd?: () => void,
  ): void {
    handle.addEventListener('pointerdown', (ev) => {
      ev.preventDefault()
      ev.stopPropagation()
      handle.setPointerCapture(ev.pointerId)
      const startX = ev.clientX
      const startY = ev.clientY
      const move = (e: PointerEvent): void => onMove((e.clientX - startX) / cw, (e.clientY - startY) / ch, e)
      const up = (): void => {
        handle.removeEventListener('pointermove', move)
        handle.removeEventListener('pointerup', up)
        onEnd?.()
      }
      handle.addEventListener('pointermove', move)
      handle.addEventListener('pointerup', up)
    })
  }

  // Snap targets: canvas edges + centre + safe-area insets, plus sibling region edges.
  function snapXs(skip: number): number[] {
    const s = theme.furniture.safeArea
    const xs = [0, s.left, 0.5, 1 - s.right, 1]
    theme.layout.regions.forEach((rg, i) => {
      if (i !== skip) xs.push(rg.rect.x, rg.rect.x + rg.rect.w / 2, rg.rect.x + rg.rect.w)
    })
    return xs
  }
  function snapYs(skip: number): number[] {
    const s = theme.furniture.safeArea
    const ys = [0, s.top, 0.5, 1 - s.bottom, 1]
    theme.layout.regions.forEach((rg, i) => {
      if (i !== skip) ys.push(rg.rect.y, rg.rect.y + rg.rect.h / 2, rg.rect.y + rg.rect.h)
    })
    return ys
  }
  const SNAP = 0.012
  function snap(v: number, targets: number[]): number {
    let best = v
    let bestD = SNAP
    for (const t of targets) {
      const d = Math.abs(v - t)
      if (d < bestD) {
        bestD = d
        best = t
      }
    }
    return best
  }

  const guideLayer = el('div', {}, 'position:absolute;inset:0;pointer-events:none;z-index:5')
  function clearGuides(): void {
    guideLayer.textContent = ''
  }
  function guideX(x: number): void {
    guideLayer.append(
      el('div', {}, `position:absolute;left:${x * 100}%;top:0;bottom:0;width:0;border-left:1px dashed #ff8800`),
    )
  }
  function guideY(y: number): void {
    guideLayer.append(
      el('div', {}, `position:absolute;top:${y * 100}%;left:0;right:0;height:0;border-top:1px dashed #ff8800`),
    )
  }

  /** Build one interactive region box (drag body to move, corner/edge handles to resize). */
  function regionBox(rg: Region, index: number): HTMLElement {
    const rect = rg.rect
    const selected = selection?.kind === 'region' && selection.index === index
    const box = el(
      'div',
      { className: 'sb-te-region' },
      `position:absolute;left:${rect.x * 100}%;top:${rect.y * 100}%;width:${rect.w * 100}%;height:${rect.h * 100}%;` +
        `box-sizing:border-box;cursor:move;border:1.5px ${selected ? 'solid' : 'dashed'} ` +
        `${selected ? '#ff8800' : 'rgba(59,110,165,.85)'};` +
        `background:${selected ? 'rgba(255,136,0,.06)' : 'rgba(59,110,165,.04)'};z-index:${selected ? 4 : 3}`,
    )
    box.append(
      el(
        'span',
        { textContent: rg.name },
        'position:absolute;top:2px;left:4px;font-size:11px;font-weight:600;' +
          `color:${selected ? '#ff8800' : 'rgba(59,110,165,.95)'};background:rgba(255,255,255,.75);` +
          'padding:0 3px;border-radius:3px;pointer-events:none',
      ),
    )
    // Ghost of what a node created here inherits, styled by the theme for a real preview.
    if (rg.defaultClass && theme.style.classes[rg.defaultClass]) {
      const ghost = el('div', { className: 'sb-content' }, 'position:absolute;inset:0;padding:2%;pointer-events:none;opacity:.55;overflow:hidden')
      ghost.append(el('div', { className: `sb-style-${rg.defaultClass}`, textContent: sampleFor(rg.defaultClass) }))
      box.append(ghost)
    }

    // move
    let start: RelRect | null = null
    drag(
      box,
      (dx, dy) => {
        if (!start) start = { ...rect }
        clearGuides()
        let nx = clamp01(start.x + dx)
        let ny = clamp01(start.y + dy)
        nx = Math.min(nx, 1 - rect.w)
        ny = Math.min(ny, 1 - rect.h)
        // snap left, centre, or right edge to the guide set
        const xs = snapXs(index)
        const ys = snapYs(index)
        const sxl = snap(nx, xs)
        const sxr = snap(nx + rect.w, xs)
        if (sxl !== nx) { nx = sxl; guideX(sxl) } else if (sxr !== nx + rect.w) { nx = sxr - rect.w; guideX(sxr) }
        const syt = snap(ny, ys)
        const syb = snap(ny + rect.h, ys)
        if (syt !== ny) { ny = syt; guideY(syt) } else if (syb !== ny + rect.h) { ny = syb - rect.h; guideY(syb) }
        rect.x = nx
        rect.y = ny
        box.style.left = `${nx * 100}%`
        box.style.top = `${ny * 100}%`
        emit()
      },
      () => {
        start = null
        clearGuides()
        // Select on release, not on press: selecting re-renders the canvas, which would
        // destroy the element that just captured the pointer and abort the drag.
        select({ kind: 'region', index })
      },
    )

    // resize handles: only on the selected region (keeps unselected boundaries uncluttered).
    // hx/hy in {-1,0,1} = which edge each grip controls.
    const grips: Array<[number, number]> = selected ? [
      [-1, -1], [0, -1], [1, -1],
      [-1, 0], [1, 0],
      [-1, 1], [0, 1], [1, 1],
    ] : []
    for (const [hx, hy] of grips) {
      const cx = hx < 0 ? '0' : hx > 0 ? '100%' : '50%'
      const cy = hy < 0 ? '0' : hy > 0 ? '100%' : '50%'
      const cur =
        hx === 0 ? 'ns-resize' : hy === 0 ? 'ew-resize' : hx === hy ? 'nwse-resize' : 'nesw-resize'
      const grip = el(
        'div',
        {},
        `position:absolute;left:${cx};top:${cy};width:10px;height:10px;margin:-5px;border-radius:2px;` +
          `background:#fff;border:1.5px solid ${selected ? '#ff8800' : 'rgba(59,110,165,.85)'};cursor:${cur};z-index:6`,
      )
      let s0: RelRect | null = null
      drag(
        grip,
        (dx, dy) => {
          if (!s0) s0 = { ...rect }
          clearGuides()
          let { x, y, w, h } = s0
          if (hx < 0) { const nx = snap(clamp01(x + dx), snapXs(index)); w = w + (x - nx); x = nx; if (nx !== clamp01(s0.x + dx)) guideX(nx) }
          if (hx > 0) { const nr = snap(clamp01(x + w + dx), snapXs(index)); w = nr - x; if (nr !== clamp01(s0.x + s0.w + dx)) guideX(nr) }
          if (hy < 0) { const ny = snap(clamp01(y + dy), snapYs(index)); h = h + (y - ny); y = ny; if (ny !== clamp01(s0.y + dy)) guideY(ny) }
          if (hy > 0) { const nb = snap(clamp01(y + h + dy), snapYs(index)); h = nb - y; if (nb !== clamp01(s0.y + s0.h + dy)) guideY(nb) }
          w = Math.max(0.03, w)
          h = Math.max(0.03, h)
          rect.x = x; rect.y = y; rect.w = w; rect.h = h
          box.style.left = `${x * 100}%`; box.style.top = `${y * 100}%`
          box.style.width = `${w * 100}%`; box.style.height = `${h * 100}%`
          emit()
        },
        () => { s0 = null; clearGuides(); select({ kind: 'region', index }) },
      )
      box.append(grip)
    }
    return box
  }

  /** A furniture chip (logo / page number) that drags freely and snaps to an anchor. */
  function furnitureChip(
    kind: 'logo' | 'pageNumber',
    anchor: Anchor9,
    widthFrac: number,
    label: string,
  ): HTMLElement {
    const selected = selection?.kind === kind
    const w = Math.max(28, widthFrac * cw)
    const h = kind === 'logo' ? Math.max(20, w * 0.4) : 22
    const pos = anchorRestPos(anchor, theme.furniture.safeArea, cw, ch, w, h)
    const chip = el(
      'div',
      { className: `sb-te-chip sb-te-chip-${kind}` },
      `position:absolute;left:${pos.left}px;top:${pos.top}px;width:${w}px;height:${h}px;` +
        `display:flex;align-items:center;justify-content:center;font-size:11px;cursor:grab;` +
        `border-radius:4px;z-index:${selected ? 8 : 7};box-sizing:border-box;` +
        (kind === 'logo'
          ? `border:1.5px ${selected ? 'solid #ff8800' : 'dashed #888'};background:rgba(255,255,255,.85);color:#555`
          : `border:1px solid ${selected ? '#ff8800' : '#bbb'};background:rgba(255,255,255,.9);color:#333;padding:0 6px;width:auto;min-width:22px`),
    )
    chip.textContent = label
    let restW = w
    let restH = h
    drag(
      chip,
      (dx, dy) => {
        const left = pos.left + dx * cw
        const top = pos.top + dy * ch
        chip.style.left = `${left}px`
        chip.style.top = `${top}px`
        const cxFrac = clamp01((left + restW / 2) / cw)
        const cyFrac = clamp01((top + restH / 2) / ch)
        const a = anchorFromCentre(cxFrac, cyFrac)
        if (kind === 'logo' && theme.furniture.logo) theme.furniture.logo.anchor = a
        if (kind === 'pageNumber' && theme.furniture.pageNumber) theme.furniture.pageNumber.anchor = a
        emit()
      },
      () => {
        // Select on release: select() re-renders and would abort a live drag (see regionBox).
        select({ kind })
        emit()
      },
    )
    // A logo carries a resize grip (its width is the theme's `size`).
    if (kind === 'logo') {
      const grip = el(
        'div',
        {},
        'position:absolute;right:-5px;bottom:-5px;width:10px;height:10px;background:#fff;border:1.5px solid #ff8800;border-radius:2px;cursor:nwse-resize;z-index:9',
      )
      drag(
        grip,
        (dx) => {
          if (!theme.furniture.logo) return
          const nw = Math.max(0.04, Math.min(0.6, widthFrac + dx))
          theme.furniture.logo.size = Math.round(nw * 1000) / 1000
          restW = Math.max(28, nw * cw)
          chip.style.width = `${restW}px`
          chip.style.height = `${Math.max(20, restW * 0.4)}px`
          emit()
        },
        () => { select({ kind: 'logo' }); emit() },
      )
      chip.append(grip)
    }
    return chip
  }

  function renderCanvas(): void {
    // wipe overlays but keep the scoped-CSS-driven background
    slide.textContent = ''
    slide.append(guideLayer)
    clearGuides()
    theme.layout.regions.forEach((rg, i) => slide.append(regionBox(rg, i)))
    if (theme.furniture.logo) {
      const lg = theme.furniture.logo
      slide.append(furnitureChip('logo', lg.anchor, lg.size, lg.asset ? 'LOGO' : '+ logo'))
    }
    if (theme.furniture.pageNumber?.show) {
      const pn = theme.furniture.pageNumber
      slide.append(furnitureChip('pageNumber', pn.anchor, 0.05, '1'))
    }
  }

  // ==================================================================================
  // Rail — non-spatial controls + a context inspector for the selected object
  // ==================================================================================
  function section(title: string): HTMLElement {
    return el(
      'div',
      { textContent: title },
      'margin:.9rem 0 .35rem;font-size:.68rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:#8a8f99',
    )
  }
  function railRow(label: string, control: HTMLElement): HTMLElement {
    const r = el('label', {}, 'display:flex;align-items:center;gap:.5rem;margin:.3rem 0;font-size:.78rem;color:#444')
    r.append(el('span', { textContent: label }, 'flex:0 0 5.5rem;color:#666'), control)
    return r
  }
  function anchorSelect(value: Anchor9, onPick: (a: Anchor9) => void): HTMLSelectElement {
    const sel = el('select', {}, 'flex:1;font-size:.76rem;padding:.15rem')
    for (const a of ANCHORS) sel.append(el('option', { value: a, textContent: a, selected: a === value }))
    sel.addEventListener('change', () => onPick(sel.value as Anchor9))
    return sel
  }

  // palette
  rail.append(section('Palette'))
  for (const key of ['bg', 'ink', 'accent'] as const) {
    const input = el('input', {
      type: 'color',
      id: `sb-te-color-${key}`,
      value: toHexColor(theme.style.palette[key]),
    }, 'width:2.4rem;height:1.5rem;padding:0;border:1px solid #ccc;border-radius:4px')
    input.addEventListener('input', () => {
      theme.style.palette[key] = input.value
      applyPreviewCss()
      emit()
    })
    rail.append(railRow(key, input))
  }

  // objects: add region / logo / page number toggles
  rail.append(section('Objects'))
  const addRegionBtn = el(
    'button',
    { type: 'button', textContent: '+ region' },
    'font-size:.76rem;padding:.25rem .5rem;border:1px solid #c9ccd4;border-radius:5px;background:#fff;cursor:pointer;margin:.15rem .3rem .15rem 0',
  )
  addRegionBtn.addEventListener('click', () => {
    const idx = theme.layout.regions.length
    theme.layout.regions.push({ name: `region ${idx + 1}`, rect: { x: 0.3, y: 0.3, w: 0.4, h: 0.3 }, defaultClass: 'body' })
    renderCanvas()
    select({ kind: 'region', index: idx })
    emit()
  })
  const logoToggle = el('input', { type: 'checkbox', id: 'sb-te-logo-show', checked: !!theme.furniture.logo })
  logoToggle.addEventListener('change', () => {
    theme.furniture.logo = logoToggle.checked
      ? { asset: '', anchor: 'bottom-right', size: 0.12 }
      : undefined
    renderCanvas()
    select(logoToggle.checked ? { kind: 'logo' } : null)
    emit()
  })
  const pnToggle = el('input', { type: 'checkbox', id: 'sb-te-pn-show', checked: theme.furniture.pageNumber?.show ?? false })
  pnToggle.addEventListener('change', () => {
    theme.furniture.pageNumber = {
      show: pnToggle.checked,
      format: theme.furniture.pageNumber?.format ?? '{n}',
      anchor: theme.furniture.pageNumber?.anchor ?? 'bottom-right',
    }
    renderCanvas()
    select(pnToggle.checked ? { kind: 'pageNumber' } : null)
    emit()
  })
  rail.append(addRegionBtn)
  rail.append(railRow('logo', logoToggle), railRow('page number', pnToggle))

  // inspector for the current selection
  rail.append(section('Selected'))
  const inspector = el('div', { id: 'sb-te-inspector' }, 'min-height:2rem')
  rail.append(inspector)

  function renderInspector(): void {
    inspector.textContent = ''
    if (selection === null) {
      inspector.append(
        el('div', { textContent: 'Click a boundary, the logo, or the page number on the slide to edit it.' },
          'font-size:.74rem;color:#999;line-height:1.4'),
      )
      return
    }
    if (selection.kind === 'region') {
      const idx = selection.index
      const rg = theme.layout.regions[idx]
      if (!rg) return
      const name = el('input', { type: 'text', value: rg.name }, 'flex:1;font-size:.76rem;padding:.15rem')
      name.addEventListener('input', () => {
        rg.name = name.value
        renderCanvas()
        emit()
      })
      const cls = el('select', {}, 'flex:1;font-size:.76rem;padding:.15rem')
      cls.append(el('option', { value: '', textContent: '(none)', selected: !rg.defaultClass }))
      for (const c of Object.keys(theme.style.classes))
        cls.append(el('option', { value: c, textContent: c, selected: rg.defaultClass === c }))
      cls.addEventListener('change', () => {
        rg.defaultClass = cls.value || undefined
        renderCanvas()
        emit()
      })
      const anch = anchorSelect(rg.defaultAnchor ?? 'top-left', (a) => {
        rg.defaultAnchor = a
        emit()
      })
      const del = el(
        'button',
        { type: 'button', textContent: 'Delete region' },
        'font-size:.74rem;color:#b23;background:#fff;border:1px solid #e2b6bd;border-radius:5px;padding:.25rem .5rem;cursor:pointer;margin-top:.5rem',
      )
      del.addEventListener('click', () => {
        theme.layout.regions.splice(idx, 1)
        select(null)
        renderCanvas()
        emit()
      })
      const dims = el(
        'div',
        { textContent: `x ${pct(rg.rect.x)} · y ${pct(rg.rect.y)} · w ${pct(rg.rect.w)} · h ${pct(rg.rect.h)}` },
        'font-size:.7rem;color:#aaa;margin-top:.3rem',
      )
      inspector.append(railRow('name', name), railRow('seeds class', cls), railRow('seeds anchor', anch), dims, del)
      return
    }
    if (selection.kind === 'logo') {
      const lg = theme.furniture.logo
      if (!lg) return
      const asset = el('input', { type: 'text', placeholder: 'assets/logo.svg', value: lg.asset }, 'flex:1;font-size:.76rem;padding:.15rem')
      asset.addEventListener('input', () => {
        lg.asset = asset.value.trim()
        renderCanvas()
        emit()
      })
      const size = el('input', { type: 'range', min: '4', max: '50', value: String(Math.round(lg.size * 100)) }, 'flex:1')
      const sizeOut = el('span', { textContent: `${Math.round(lg.size * 100)}%` }, 'font-size:.72rem;color:#888;width:2.4rem')
      size.addEventListener('input', () => {
        lg.size = Number(size.value) / 100
        sizeOut.textContent = `${size.value}%`
        renderCanvas()
        emit()
      })
      const anch = anchorSelect(lg.anchor, (a) => {
        lg.anchor = a
        renderCanvas()
        emit()
      })
      const sizeRow = railRow('size', size)
      sizeRow.append(sizeOut)
      inspector.append(railRow('asset', asset), railRow('anchor', anch), sizeRow)
      return
    }
    // pageNumber
    const pn = theme.furniture.pageNumber
    if (!pn) return
    const fmt = el('input', { type: 'text', value: pn.format ?? '{n}' }, 'flex:1;font-size:.76rem;padding:.15rem')
    fmt.addEventListener('input', () => {
      pn.format = fmt.value
      emit()
    })
    const anch = anchorSelect(pn.anchor, (a) => {
      pn.anchor = a
      renderCanvas()
      emit()
    })
    inspector.append(
      railRow('format', fmt),
      railRow('anchor', anch),
      el('div', { textContent: '{n} = number, {total} = deck length' }, 'font-size:.7rem;color:#aaa;margin-top:.3rem'),
    )
  }

  function select(s: Sel): void {
    selection = s
    renderCanvas()
    renderInspector()
  }

  // deck-overlay toggle + save --------------------------------------------------------
  rail.append(section('Deck'))
  const regionsOn = el('input', { type: 'checkbox', id: 'sb-te-regions', checked: showRegions })
  regionsOn.addEventListener('change', () => {
    showRegions = regionsOn.checked
    emit()
  })
  rail.append(railRow('show boundaries', regionsOn))

  const actions = el('div', {}, 'display:flex;align-items:center;gap:.6rem;margin-top:1.1rem')
  const saveBtn = el(
    'button',
    { type: 'button', id: 'sb-te-save', textContent: 'Save theme' },
    'flex:1;padding:.5rem;border:1px solid #3b6ea5;background:#3b6ea5;color:#fff;border-radius:6px;cursor:pointer;font-size:.82rem',
  )
  const status = el('span', {}, 'font-size:.72rem;color:#3a7d44')
  saveBtn.addEventListener('click', () => {
    status.textContent = 'Saving…'
    Promise.resolve(opts.onSave(theme)).then(
      () => (status.textContent = 'Saved'),
      (e: unknown) => (status.textContent = 'Failed: ' + (e instanceof Error ? e.message : String(e))),
    )
  })
  actions.append(saveBtn, status)
  rail.append(actions)

  // deselect when clicking bare canvas
  slide.addEventListener('pointerdown', (e) => {
    if (e.target === slide || e.target === guideLayer) select(null)
  })
  backdrop.addEventListener('mousedown', (e) => {
    if (e.target === backdrop) close()
  })
  const onResize = (): void => {
    fitCanvas()
    renderCanvas()
  }
  window.addEventListener('resize', onResize)

  document.body.append(backdrop)
  applyPreviewCss()
  fitCanvas()
  renderCanvas()
  renderInspector()

  function close(): void {
    window.removeEventListener('resize', onResize)
    backdrop.remove()
    opts.onClose?.()
  }
  return { close }
}

/** Placeholder copy for a role, so the preview shows real themed type. */
function sampleFor(role: string): string {
  if (role === 'title') return 'Presentation title'
  if (role === 'subtitle') return 'A short subtitle'
  if (role === 'heading') return 'Section heading'
  if (role === 'caption') return 'A caption'
  return 'Body text sits here.'
}

const pct = (n: number): string => `${Math.round(n * 100)}%`

/** A color input needs `#rrggbb`; pass through hex, else fall back to black. */
function toHexColor(c: string): string {
  return /^#[0-9a-fA-F]{6}$/.test(c) ? c : '#000000'
}
