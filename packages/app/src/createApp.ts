/// <reference types="vite/client" />
/**
 * The reactive render + edit controller. Contract: see createApp.md.
 *
 * `createApp(root)` is the shared entry both shells (web, desktop) mount: it renders
 * the workspace chrome, injects the global stylesheets, and wires the two-way edit
 * loop. Everything here is platform-agnostic DOM + engine code, so it runs unchanged
 * in a browser tab and in a Tauri webview — the shells differ only in which adapters
 * they build around it. With `ports` wired (M3) the source of truth is a document in
 * the working copy: edits autosave through Storage, and the side panel adds the file
 * tree and local git history; without ports the bundled sample runs in memory.
 *
 * The engine, running unchanged in a browser, with a two-way edit loop:
 *   - text -> render: code pane -> fromMarkdown -> resolveLayout -> renderSlide (W2)
 *   - canvas -> text: a gesture -> E1 edit op -> toMarkdown -> code pane (W4)
 * The canvas is the whole deck in one continuous vertical scroll (deck.ts); a carousel
 * navigator rail (deckNav.ts) jumps between slides and stays synced to the scroll.
 * Both edit directions share one source of truth (the .slideBlaster.md text, A1).
 */
import {
  fromMarkdown,
  toMarkdown,
  parsePicture,
  serializePicture,
  getMeta,
  slideStylesheet,
  renderSlide,
  slideStepCount,
  resolveLayoutAsync,
  parseContent,
  findNode,
  placement,
  moveNodeTo,
  resizeNode,
  placeNodeRelative,
  createNode,
  deleteNode,
  setNodeContent,
  setNodeStyleClass,
  setNodeOptions,
  setNodeOverlay,
  styleClasses,
  isStyleKnobToken,
  createConnector,
  deleteConnector,
  updateConnector,
  setConnectorOptions,
  themeStylesheet,
  furnitureCss,
  furnitureHtml,
  regionRects,
  regionGuides,
  regionAt,
  slideBoxFromMeta,
  DEFAULT_SLIDE_BOX,
  serializeTheme,
  parseTheme,
  defaultTheme,
  type Theme,
  type SlideBox,
  type Layout,
  type Frame,
  type NodeContent,
  type Point,
  type RenderedSlide,
  type SlideDocument,
  type TikzPicture,
} from '@slideblaster/editor'
import initialSource from './sample.slideBlaster.md?raw'
import sampleBib from './sample.refs.bib?raw'
import exampleFlowchart from './examples/flowchart.tikz?raw'
import exampleShapes from './examples/shapes.tikz?raw'
import examplePipeline from './examples/pipeline.tikz?raw'
import { createCodePane, type CodePane } from './codePane'
import { minimalDiff } from './sourceDelta'
import {
  paintDeck,
  type DeckActions,
  type DeckHandle,
  type Selection,
  type ConnectorSelection,
  type Surface,
} from './deck'
import type { CurveFocus } from './connectorEditor'
import { paintDeckNav, type NavHandle } from './deckNav'
import { paintProperties, type PropSelection } from './properties'
import { openCreationMenu, type MenuItem } from './createMenu'
import { renderShapesPanel, SHAPE_DRAG_MIME } from './shapesPanel'
import { shapeById, shapeNodeOptions } from './shapes/catalog'
import { enableZoomPan } from './zoom'
import { createDomMeasurer } from './domMeasurer'
import { SLIDE_THEME_CSS, SLIDE_TYPE_CSS } from './slideType'
import { openThemeEditor, type ThemeEditorHandle } from './themeEditor'
import {
  renderOptions,
  installTableCompiler,
  scheduleTableCompile,
  ensureTables,
} from './tableCompiler'
import { installCiteCompiler, scheduleCiteCompile, ensureCitations } from './citeCompiler'
import { KATEX_CSS } from './katexInlineCss'
import { downloadDeckHtml, printDeck } from './export'
import { present } from './presenter'
import { renderChrome } from './chrome'
import { mountStyleToolbar } from './styleToolbar'
import { enableResizers } from './resizer'
import {
  bootDocument,
  createAutosave,
  rememberDoc,
  readRemote,
  writeRemote,
  isDocPath,
  isTikzPath,
  type AppPorts,
} from './workspace'
import { paintFileTree } from './fileTree'
import { createGitPanel, type GitPanelHandle } from './gitPanel'
import './app.css'

/**
 * Sibling assets seeded alongside the sample deck on a virgin working copy: the sample's
 * bibliography, plus a handful of standalone `.tikz` figures under `examples/` so a new
 * project opens with drawings to explore (open one from the file tree — each edits on the
 * canvas like a single-slide deck).
 */
const SEED_FILES: Record<string, string> = {
  'refs.bib': sampleBib,
  'examples/flowchart.tikz': exampleFlowchart,
  'examples/shapes.tikz': exampleShapes,
  'examples/pipeline.tikz': examplePipeline,
}

/**
 * Per-shell knobs. `shellTag` is the app-bar badge (e.g. "web-shell · M3").
 * `ports` wires the working copy in (storage/git/auth); without it the app runs
 * the bundled sample in memory (no persistence, side panel hidden).
 */
export interface CreateAppOptions {
  shellTag?: string
  ports?: AppPorts
  /** If set, show a "Projects" affordance in the app bar to return to the landing. */
  onExitToProjects?: () => void
}

interface State {
  source: string
  active: number // the slide most in view; drives the navigator highlight
  selected: Selection | null
  selectedConnector: ConnectorSelection | null
  // E4+: the anchor/dot (of the selected connector) whose tangent angles the panel edits. Set
  // by the connector editor on paint, carrying the live geometry the panel works against.
  focusedCurve: (CurveFocus & { frame: number; surface: Surface }) | null
  connectMode: boolean // E4: dragging a node draws an arrow instead of moving it
  autoEdit: Selection | null // W5: a just-created node to open in edit mode next paint
  // ADR 0018: overlay-step preview for the active slide (null = all-visible authoring view).
  preview: { frame: number; step: number } | null
}

/** The creation-menu catalogue (W5): each entry maps to a createNode spec. `body` is
 *  the initial raw content (parsed on insert); empty means an empty caret to type into. */
interface CatalogueEntry extends MenuItem {
  options: string[]
  body: string
}

const CATALOGUE: CatalogueEntry[] = [
  { id: 'text', label: 'Text', hint: 'plain', options: [], body: '' },
  { id: 'title', label: 'Title', hint: 'heading', options: ['title'], body: '' },
  { id: 'body', label: 'Body', hint: 'text block', options: ['body'], body: '' },
  { id: 'note', label: 'Note', hint: 'aside', options: ['note'], body: '' },
  { id: 'math', label: 'Math', hint: '$…$', options: [], body: '$x$' },
]

/**
 * A document codec: how an open file's on-disk text maps to the `SlideDocument` the
 * controller edits, and back. A deck (`.slideBlaster.md`) is markdown — frontmatter plus
 * `slide`/`notes` blocks. A figure (`.tikz`) is a bare slide-picture body wrapped as one
 * anonymous frame, so the entire controller (canvas, edit ops, undo, code pane) works on
 * it unchanged; only these two seam functions differ.
 */
interface DocCodec {
  kind: 'deck' | 'figure'
  /** Tolerant parse: a malformed edit keeps the last good render instead of blanking. */
  parse(source: string): { doc: SlideDocument } | { error: string }
  serialize(doc: SlideDocument): string
}

const deckCodec: DocCodec = {
  kind: 'deck',
  parse(source) {
    try {
      return { doc: fromMarkdown(source) }
    } catch (err) {
      return { error: err instanceof Error ? err.message : String(err) }
    }
  },
  serialize: toMarkdown,
}

/**
 * A standalone `.tikz` figure: the file IS the picture body, so it becomes a single
 * frame with empty frontmatter (theme resolves to `default`) and no heading. `parsePicture`
 * never throws — unmodeled statements fall back to verbatim — so parse always succeeds.
 */
const figureCodec: DocCodec = {
  kind: 'figure',
  parse(source) {
    return {
      doc: {
        meta: { entries: [] },
        frames: [{ id: 'figure', title: '', picture: parsePicture(source) }],
      },
    }
  },
  serialize(doc) {
    return serializePicture(doc.frames[0]?.picture ?? { statements: [] })
  },
}

/** The codec for an open path: `.tikz` is a figure; everything else edits as a deck. */
function codecFor(path: string | null): DocCodec {
  return path && isTikzPath(path) ? figureCodec : deckCodec
}

/** A document with one frame's picture swapped — the unit of a canvas edit. */
function withFrame(doc: SlideDocument, index: number, picture: TikzPicture): SlideDocument {
  return {
    meta: doc.meta,
    frames: doc.frames.map((frame, i) => (i === index ? { ...frame, picture } : frame)),
  }
}

/** A document with one frame removed — the unit of a slide deletion (carousel + Delete). */
function withoutFrame(doc: SlideDocument, index: number): SlideDocument {
  return {
    meta: doc.meta,
    frames: doc.frames.filter((_, i) => i !== index),
  }
}

/** A document with a fresh blank slide appended — the unit of a "new slide" action. The id
 *  is the first `slide-N` not already taken, so it stays unique across earlier deletes. */
function withNewFrame(doc: SlideDocument): SlideDocument {
  const used = new Set(doc.frames.map((f) => f.id))
  let n = doc.frames.length + 1
  while (used.has(`slide-${n}`)) n++
  return {
    meta: doc.meta,
    frames: [...doc.frames, { id: `slide-${n}`, title: '', picture: { statements: [] } }],
  }
}

/** The picture behind a (frame, surface): the audience slide, or its notes sidecar (ADR 0019). */
function pictureOf(frame: Frame, surface: Surface): TikzPicture | undefined {
  return surface === 'notes' ? frame.notes : frame.picture
}

/** A document with one frame surface's picture swapped — `withFrame` generalised to notes. */
function withSurface(
  doc: SlideDocument,
  index: number,
  surface: Surface,
  picture: TikzPicture,
): SlideDocument {
  return {
    meta: doc.meta,
    frames: doc.frames.map((frame, i) =>
      i === index
        ? surface === 'notes'
          ? { ...frame, notes: picture }
          : { ...frame, picture }
        : frame,
    ),
  }
}

/** Count nodes whose content is out of subset (ADR 0015 error state) across the deck. */
function countErrorNodes(doc: SlideDocument): number {
  return doc.frames.reduce(
    (total, frame) =>
      total +
      frame.picture.statements.filter((s) => s.kind === 'node' && s.content.kind === 'error')
        .length,
    0,
  )
}

/**
 * Mount the editor into `root`: render the chrome, inject the stylesheets, and wire
 * the controller. Idempotent per document for styles; call once per shell on startup.
 */
/** Dashed boxes over a slide showing the theme's master-layout regions (editor preview). */
function regionsOverlayHtml(theme: Theme, box: SlideBox): string {
  const boxes = regionRects(theme, box)
    .map((r) => {
      const left = (r.left / box.width) * 100
      const width = ((r.right - r.left) / box.width) * 100
      const top = ((box.height - r.top) / box.height) * 100
      const height = ((r.top - r.bottom) / box.height) * 100
      const name = r.name.replace(/</g, '&lt;')
      return (
        `<div style="position:absolute;left:${left}%;top:${top}%;width:${width}%;height:${height}%;` +
        `border:0.2cqw dashed rgba(59,110,165,.85);box-sizing:border-box">` +
        `<span style="position:absolute;top:0;left:.3cqw;font-size:1.4cqw;color:rgba(59,110,165,.9)">${name}</span></div>`
      )
    })
    .join('')
  return `<div class="sb-theme-regions" style="position:absolute;inset:0;pointer-events:none">${boxes}</div>`
}

export function createApp(root: HTMLElement, opts: CreateAppOptions = {}): void {
  renderChrome(root, { shellTag: opts.shellTag ?? 'SlideBlaster' })
  injectGlobalStyles()
  enableResizers(root) // drag handles between the file tree, editor, and slide canvas

  // A project is one working copy; when the shell can switch projects it passes
  // `onExitToProjects`, and the app bar gets a back-to-landing button.
  if (opts.onExitToProjects) {
    const back = document.createElement('button')
    back.type = 'button'
    back.id = 'exit-projects'
    back.textContent = '← Projects'
    back.title = 'Back to projects'
    // Self-contained styling (tokens from app.css) so this needs no app.css edit.
    back.style.cssText =
      'margin-right:.5rem;border:1px solid var(--line);border-radius:6px;' +
      'background:var(--surface);color:var(--ink);font:inherit;font-size:.74rem;' +
      'padding:.24rem .66rem;cursor:pointer;'
    back.addEventListener('click', () => opts.onExitToProjects?.())
    root.querySelector('.app-bar')?.prepend(back)
  }

  // Scope element lookups to the mounted root, so the shell owns nothing but this node.
  const qs = <T extends HTMLElement>(selector: string): T => {
    const el = root.querySelector<T>(selector)
    if (!el) throw new Error(`missing element: ${selector}`)
    return el
  }

  const state: State = {
    source: initialSource,
    active: 0,
    selected: null,
    selectedConnector: null,
    focusedCurve: null,
    connectMode: false,
    autoEdit: null,
    preview: null,
  }
  // Source-history undo/redo: each committed canvas edit snapshots the prior source.
  const undoStack: string[] = []
  const redoStack: string[] = []
  const HISTORY_LIMIT = 100
  const deck = qs('#deck')
  const deckRail = qs('#deck-rail') // the carousel navigator: a vertical rail beside the canvas
  const errorBanner = qs('#error')
  const docTitle = qs('#doc-title')
  const status = qs('#status')
  const undoButton = qs<HTMLButtonElement>('#undo')
  const redoButton = qs<HTMLButtonElement>('#redo')
  const propsHost = qs('#props')
  const editorHead = qs('#editor-head')
  let currentDoc: SlideDocument | null = null
  // How the open file's text maps to/from the edited document; set per-open in `openDoc`.
  let codec: DocCodec = deckCodec
  let codePane: CodePane
  let deckHandle: DeckHandle | null = null
  let navHandle: NavHandle | null = null
  const measurer = createDomMeasurer()
  // Monotonic render token: a slow async paint that finishes after a newer edit is dropped.
  let renderSeq = 0
  // A slide to scroll the canvas to once the next render has painted the (rebuilt) deck DOM
  // — set by a structural edit (new slide) whose commit re-renders asynchronously.
  let pendingScroll: number | null = null

  // Working copy (M3): which document is open, its debounced persistence, and the
  // side-panel views. All null/absent when the shell wired no ports (in-memory mode).
  const ports = opts.ports ?? null

  // Active theme (ADR 0017): a live-updatable style layer plus per-slide furniture/region
  // decoration over the painted deck. Starts from the built-in default; the editor edits
  // it and saves to themes/<id>/theme.json.
  let activeTheme: Theme = defaultTheme
  let showRegions = false
  const themeStyleEl = document.createElement('style')
  themeStyleEl.id = 'sb-theme'
  document.head.append(themeStyleEl)
  const applyThemeCss = (): void => {
    themeStyleEl.textContent = `${themeStylesheet(activeTheme)}\n${furnitureCss(activeTheme)}`
  }
  const decorateDeck = (): void => {
    const total = currentDoc?.frames.length ?? 0
    // A figure is a standalone picture, not a slide in a deck: no page-number/logo furniture.
    const furniture = codec.kind !== 'figure'
    deck.querySelectorAll<HTMLElement>('.sb-slide').forEach((slide) => {
      const card = slide.closest<HTMLElement>('[data-frame]')
      const index = card ? Number(card.dataset.frame) : 0
      slide.querySelector('.sb-furniture')?.remove()
      const chrome = furniture ? furnitureHtml(activeTheme, { index, total }) : ''
      if (chrome) slide.insertAdjacentHTML('beforeend', chrome)
      slide.querySelector('.sb-theme-regions')?.remove()
      if (showRegions)
        slide.insertAdjacentHTML('beforeend', regionsOverlayHtml(activeTheme, currentBox()))
    })
  }
  applyThemeCss()
  // Load the open doc's saved theme (themes/<id>/theme.json; the id is its `theme`
  // frontmatter, else 'default') back on open — closing the save/load loop the editor's
  // onSave opens. A missing file uses the built-in default; a corrupt one falls back too
  // and warns, since a theme must never block opening a document.
  const loadActiveTheme = async (): Promise<void> => {
    let next: Theme = defaultTheme
    const id = (currentDoc && getMeta(currentDoc.meta, 'theme')) || 'default'
    const path = `themes/${id}/theme.json`
    if (ports && (await ports.storage.exists(path))) {
      try {
        next = parseTheme(await ports.storage.readText(path))
      } catch (e) {
        status.textContent = `Theme "${id}" is invalid; using the default (${e instanceof Error ? e.message : String(e)}).`
      }
    }
    activeTheme = next
    applyThemeCss()
    decorateDeck()
  }
  // The open document's slide box (ADR 0017 aspect ratio; default 16x9). One source for the
  // render width, the DOM measurer, and region geometry, so all three agree on the shape.
  const currentBox = (): SlideBox =>
    currentDoc ? slideBoxFromMeta(currentDoc.meta) : DEFAULT_SLIDE_BOX
  // Region snap references for the drag snapper: the active theme's master-layout edges +
  // centres in slide space (y-up), resolved against the doc's box. Soft guides shown only
  // while a node is moving — the "boundaries on move" of ADR 0017, distinct from the
  // always-on showRegions overlay.
  const themeSnapRefs = (): { xs: readonly number[]; ys: readonly number[] } =>
    regionGuides(activeTheme, currentBox())
  let currentPath: string | null = null
  let gitPanel: GitPanelHandle | null = null
  const autosave = ports
    ? createAutosave(ports.storage, { onWrite: () => void gitPanel?.refresh() })
    : null

  /** Persist the current source to the working copy (debounced; no-op in memory mode). */
  const persist = (): void => {
    if (autosave && currentPath) autosave.schedule(currentPath, state.source)
  }

  const setStatus = (): void => {
    // Out-of-subset nodes take precedence: surface the document error state (ADR 0015).
    const errors = currentDoc ? countErrorNodes(currentDoc) : 0
    if (errors > 0) {
      status.textContent = `${errors} node${errors > 1 ? 's' : ''} out of subset — source kept, fix to render (ADR 0015)`
      return
    }
    if (state.connectMode) {
      status.textContent =
        'Connect mode — drag from one node to another to draw an arrow (Esc to exit)'
      return
    }
    if (state.selectedConnector) {
      status.textContent = `Selected arrow on slide ${state.selectedConnector.frame + 1} — Delete to remove`
      return
    }
    status.textContent = state.selected
      ? `Selected ${state.selected.name} on slide ${state.selected.frame + 1} — drag to move, double-click to edit, Delete to remove`
      : 'Scroll to move through slides · click to select · double-click to edit or add'
  }

  /** Repaint the properties panel for the current selection (node or connector). Cheap;
   *  called on selection (no re-render) and after every render. */
  const paintPanel = (): void => {
    const sel = state.selected ?? state.selectedConnector ?? null
    const frame = sel?.frame ?? null
    const surface: Surface = sel?.surface ?? 'slide'
    const selection: PropSelection = state.selected
      ? { kind: 'node', name: state.selected.name }
      : state.selectedConnector
        ? { kind: 'connector', index: state.selectedConnector.index }
        : null
    const target = frame !== null ? currentDoc?.frames[frame] : undefined
    const picture = target ? (pictureOf(target, surface) ?? null) : null
    // Curve-angle editing is offered only when the focused curve belongs to the arrow that
    // is actually selected (a stale focus from a since-deselected connector is ignored).
    const curveFocus =
      state.selectedConnector &&
      state.focusedCurve &&
      state.focusedCurve.frame === state.selectedConnector.frame &&
      state.focusedCurve.surface === state.selectedConnector.surface &&
      state.focusedCurve.index === state.selectedConnector.index
        ? state.focusedCurve
        : null
    paintProperties(propsHost, {
      selection,
      picture,
      curveFocus,
      actions: {
        moveNode: (name, center) => frame !== null && actions.move(frame, surface, name, center),
        bindNode: (name, binding) => frame !== null && actions.bind(frame, surface, name, binding),
        resizeNode: (name, patch) => frame !== null && actions.resize(frame, surface, name, patch),
        setConnectorOptions: (index, options) => {
          const p = target ? pictureOf(target, surface) : undefined
          if (currentDoc && p && frame !== null)
            commit(withSurface(currentDoc, frame, surface, setConnectorOptions(p, index, options)))
        },
        updateConnectorPath: (index, path) => {
          const p = target ? pictureOf(target, surface) : undefined
          if (currentDoc && p && frame !== null)
            commit(withSurface(currentDoc, frame, surface, updateConnector(p, index, path)))
        },
        setNodeOverlay: (name, spec) => {
          const p = target ? pictureOf(target, surface) : undefined
          if (currentDoc && p && frame !== null)
            commit(withSurface(currentDoc, frame, surface, setNodeOverlay(p, name, spec)))
        },
        setNodeStyle: (name, options) => {
          const p = target ? pictureOf(target, surface) : undefined
          if (currentDoc && p && frame !== null)
            commit(withSurface(currentDoc, frame, surface, setNodeOptions(p, name, options)))
        },
      },
    })
  }

  /** Mount (or clear) the selected node's column grid affordance without a repaint — the
   *  selection-change path, since `select` deliberately does not re-render the canvas. */
  const mountColumnEditors = (): void => {
    const sel = state.selected
    const target = sel && currentDoc ? currentDoc.frames[sel.frame] : undefined
    const picture = sel && target ? pictureOf(target, sel.surface) : undefined
    const node = sel && picture ? findNode(picture, sel.name) : undefined
    deckHandle?.setColumnEditors(
      sel && node
        ? { frame: sel.frame, surface: sel.surface, name: sel.name, content: node.content }
        : null,
    )
  }

  /** Apply an edit op result: snapshot for undo, re-serialize, sync the code pane, render. */
  const commit = (doc: SlideDocument): void => {
    undoStack.push(state.source) // the pre-edit source is the undo target
    if (undoStack.length > HISTORY_LIMIT) undoStack.shift()
    redoStack.length = 0 // a new edit invalidates the redo branch
    state.source = codec.serialize(doc)
    codePane.setValue(state.source)
    persist()
    void render()
  }

  /**
   * Append a blank slide and reveal it — the "new slide" action shared by the top-bar button
   * and the carousel's add affordance (one semantic action, two triggers). Undoable like any
   * edit (it goes through commit). Deck-only: a standalone `.tikz` figure is a single picture.
   */
  const addSlide = (): void => {
    if (!currentDoc || codec.kind === 'figure') return
    const doc = withNewFrame(currentDoc)
    const index = doc.frames.length - 1
    state.active = index // focus the freshly added slide
    state.selected = null
    state.selectedConnector = null
    pendingScroll = index // scroll the canvas to it once the rebuilt deck paints
    commit(doc)
  }

  /**
   * Insert a catalogue shape as a new node at a slide point (the shapes panel). A shape is a
   * curated preset of TikZ node options (shapes/catalog): dropping it is just `createNode`
   * with those options, so it is byte-identical to a hand-typed `\node[...]` and the engine
   * renders/moves/resizes/serializes it with no special case. Selects the new node (no
   * auto-edit — a shape is a box; double-click adds a label later).
   */
  const insertShapeAt = (frame: number, surface: Surface, center: Point, shapeId: string): void => {
    const shape = shapeById(shapeId)
    const target = currentDoc?.frames[frame]
    const source = target ? pictureOf(target, surface) : undefined
    if (!shape || !currentDoc || !source) return
    const { picture, name } = createNode(source, {
      at: center,
      options: shapeNodeOptions(shape),
      content: parseContent(shape.body),
    })
    state.selected = { frame, surface, name }
    commit(withSurface(currentDoc, frame, surface, picture))
  }

  /**
   * Node-scoped commit for a content edit (ADR 0016): apply the new node content, then
   * derive both deltas instead of a whole-scene round-trip — splice the code pane at the
   * one changed range (`minimalDiff`, caret kept) and re-paint just this frame's card and
   * thumbnail. Undo/persist are unchanged; only the paint is localized.
   */
  const commitContent = (
    frame: number,
    surface: Surface,
    name: string,
    content: NodeContent,
  ): void => {
    const target = currentDoc?.frames[frame]
    const picture = target ? pictureOf(target, surface) : undefined
    if (!currentDoc || !target || !picture) return
    const doc = withSurface(currentDoc, frame, surface, setNodeContent(picture, name, content))

    undoStack.push(state.source)
    if (undoStack.length > HISTORY_LIMIT) undoStack.shift()
    redoStack.length = 0
    const next = codec.serialize(doc)
    const edit = minimalDiff(state.source, next)
    codePane.replaceRange(edit.start, edit.end, edit.text)
    state.source = next
    currentDoc = doc
    persist()
    scheduleTableCompile(doc) // the edit may have introduced a table; keep compilation live
    scheduleCiteCompile(doc) // the edit may have changed a \cite or the bibliography

    // Canvas delta: only this frame surface's card, everything else untouched.
    const ctx = {
      selected: state.selected,
      selectedConnector: state.selectedConnector,
      selectedCurve: state.focusedCurve
        ? {
            frame: state.focusedCurve.frame,
            surface: state.focusedCurve.surface,
            anchor: state.focusedCurve.anchor,
          }
        : null,
      connectMode: state.connectMode,
      ...(state.preview?.frame === frame ? { step: state.preview.step } : {}),
      snapRefs: themeSnapRefs(),
      slideWidth: currentBox().width,
    }
    void deckHandle?.repaintFrame(frame, surface, doc.frames[frame]!, ctx)
    // The navigator thumbnail shows the audience slide, so only a slide edit changes it.
    if (surface === 'slide') void navHandle?.repaintThumb(frame, doc.frames[frame]!)
    undoButton.disabled = undoStack.length === 0
    redoButton.disabled = redoStack.length === 0
  }

  /** Restore a source from history, syncing the pane and clearing transient selections. */
  const restore = (source: string): void => {
    state.source = source
    codePane.setValue(source)
    state.selected = null
    state.selectedConnector = null
    state.focusedCurve = null
    persist()
    void render()
  }

  const undo = (): void => {
    const prev = undoStack.pop()
    if (prev === undefined) return
    redoStack.push(state.source)
    restore(prev)
  }

  const redo = (): void => {
    const next = redoStack.pop()
    if (next === undefined) return
    undoStack.push(state.source)
    restore(next)
  }

  /**
   * Render the deck to self-contained HTML for export — same measurements as the canvas.
   * One page per overlay step (ADR 0018): a slide with N steps expands to N pages, each
   * rendered at that step. Geometry is step-invariant, so layout is resolved once per slide
   * and reused across its steps.
   */
  const collectSlides = async (doc: SlideDocument): Promise<RenderedSlide[]> => {
    await ensureTables(doc) // the export must not race the async table compile
    await ensureCitations(doc) // resolve \cite numbering + bibliography before export
    const slideWidth = slideBoxFromMeta(doc.meta).width // aspect ratio (ADR 0017)
    measurer.setSlideWidth(slideWidth) // measure the export at the doc's box, like the canvas
    const perFrame = await Promise.all(
      doc.frames.map(async (frame) => {
        const layout = await resolveLayoutAsync(frame.picture, measurer)
        const steps = slideStepCount(frame.picture)
        return Array.from({ length: steps }, (_, i) =>
          renderSlide(frame.picture, layout, { ...renderOptions, step: i + 1, slideWidth }),
        )
      }),
    )
    // Furniture (page number, logo, bands) prints too (ADR 0017): it's frame, not content,
    // and belongs on every exported page. Inject it inside each .sb-slide (the positioned
    // box) so it anchors identically to the canvas; {n}/{total} number the flattened pages.
    const rendered = perFrame.flat()
    const total = rendered.length
    return rendered.map((html, index) => {
      const chrome = furnitureHtml(activeTheme, { index, total })
      const withChrome = chrome
        ? html.slice(0, html.lastIndexOf('</div>')) + chrome + '</div>'
        : html
      return { index, html: withChrome }
    })
  }

  const actions: DeckActions = {
    select(frame, surface, name) {
      state.selected = name === null ? null : { frame, surface, name }
      state.focusedCurve = null // leaving a connector drops any curve-angle focus
      if (state.selectedConnector) {
        // Selecting a node clears any connector selection — needs a re-render (which
        // mounts the column affordance via paintCanvas).
        state.selectedConnector = null
        void render()
      } else {
        // Cheap selection: mount/clear the column grid affordance without a repaint.
        mountColumnEditors()
      }
      deckHandle?.showSelection(state.selected)
      styleToolbar.refresh() // the dropdown tracks the selected node without a repaint
      setStatus()
      paintPanel()
    },
    connect(frame, surface, from, to) {
      const target = currentDoc?.frames[frame]
      const picture = target ? pictureOf(target, surface) : undefined
      if (!currentDoc || !picture) return
      commit(withSurface(currentDoc, frame, surface, createConnector(picture, from, to)))
    },
    selectConnector(frame, surface, index) {
      // No-op when the selection is unchanged — critically, the connect-mode drag clears the
      // connector selection on pointerdown (selectConnector(null)); if that already-null case
      // still re-rendered, the full deck rebuild (host.replaceChildren) would destroy the node
      // handle mid-gesture, dropping its pointer capture so the drag never draws an arrow.
      const prev = state.selectedConnector
      const next = index === null ? null : { frame, surface, index }
      if (
        (prev === null && next === null) ||
        (prev !== null &&
          next !== null &&
          prev.frame === next.frame &&
          prev.surface === next.surface &&
          prev.index === next.index)
      )
        return
      state.selectedConnector = next
      if (index !== null) state.selected = null // connector and node selection are exclusive
      state.focusedCurve = null // the editor re-emits fresh focus for the new arrow on paint
      void render() // re-render to reflect the connector highlight (no drag in flight here)
    },
    focusConnectorCurve(frame, surface, focus) {
      // Fired by the connector editor (on paint, and when a control handle is grabbed): pin
      // the segment the panel edits, carrying its live geometry. Panel-only, never a render.
      state.focusedCurve = focus ? { ...focus, frame, surface } : null
      paintPanel()
    },
    updateConnector(frame, surface, index, path) {
      const target = currentDoc?.frames[frame]
      const picture = target ? pictureOf(target, surface) : undefined
      if (!currentDoc || !picture) return
      commit(withSurface(currentDoc, frame, surface, updateConnector(picture, index, path)))
    },
    move(frame, surface, name, center) {
      const target = currentDoc?.frames[frame]
      const picture = target ? pictureOf(target, surface) : undefined
      if (!currentDoc || !picture) return
      commit(withSurface(currentDoc, frame, surface, moveNodeTo(picture, name, center)))
    },
    resize(frame, surface, name, patch) {
      const target = currentDoc?.frames[frame]
      const source = target ? pictureOf(target, surface) : undefined
      if (!currentDoc || !source) return
      let picture = resizeNode(source, name, {
        ...(patch.textWidth !== undefined ? { textWidth: patch.textWidth } : {}),
        ...(patch.minHeight !== undefined ? { minHeight: patch.minHeight } : {}),
        ...(patch.scaleX !== undefined ? { scaleX: patch.scaleX } : {}),
        ...(patch.scaleY !== undefined ? { scaleY: patch.scaleY } : {}),
      })
      // Keep the dragged edge's opposite side anchored — but only for absolute nodes; a
      // relatively-placed node keeps its binding and re-resolves its own center.
      const node = findNode(picture, name)
      if (patch.center && node && placement(node) === undefined) {
        picture = moveNodeTo(picture, name, patch.center)
      }
      commit(withSurface(currentDoc, frame, surface, picture))
    },
    bind(frame, surface, name, binding) {
      const target = currentDoc?.frames[frame]
      const picture = target ? pictureOf(target, surface) : undefined
      if (!currentDoc || !picture) return
      commit(withSurface(currentDoc, frame, surface, placeNodeRelative(picture, name, binding)))
    },
    requestCreate(frame, surface, center, client) {
      const t = currentDoc?.frames[frame]
      if (!t || !pictureOf(t, surface)) return
      // Summon the creation menu at the cursor; picking inserts at the slide point,
      // selects the new node, and opens it in edit mode (ux/creation-menu.md).
      openCreationMenu(client.x, client.y, {
        items: CATALOGUE,
        onDismiss: () => {}, // an exploratory summon leaves no trace
        onPick: (id) => {
          const entry = CATALOGUE.find((item) => item.id === id)
          const target = currentDoc?.frames[frame]
          const source = target ? pictureOf(target, surface) : undefined
          if (!entry || !currentDoc || !source) return
          // Creation seeding (ADR 0017): a node made inside a master-layout region with no
          // explicit class inherits the region's defaultClass. Creation-only — a later move
          // never reclassifies (regions are soft guides, not placement).
          const options = [...entry.options]
          if (surface === 'slide' && options.length === 0) {
            const region = regionAt(activeTheme, center, currentBox())
            if (region?.defaultClass) options.unshift(region.defaultClass)
          }
          const { picture, name } = createNode(source, {
            at: center,
            options,
            content: parseContent(entry.body),
          })
          state.selected = { frame, surface, name }
          state.autoEdit = { frame, surface, name }
          commit(withSurface(currentDoc, frame, surface, picture))
        },
      })
    },
    remove(frame, surface, name) {
      const target = currentDoc?.frames[frame]
      const picture = target ? pictureOf(target, surface) : undefined
      if (!currentDoc || !picture) return
      if (
        state.selected?.frame === frame &&
        state.selected.surface === surface &&
        state.selected.name === name
      )
        state.selected = null
      commit(withSurface(currentDoc, frame, surface, deleteNode(picture, name)))
    },
    editContent(frame, surface, name, body) {
      // parseContent tolerates out-of-subset input: it lands as error content that
      // re-serializes verbatim (source kept) and renders as a marked error (ADR 0015).
      commitContent(frame, surface, name, parseContent(body))
    },
    editContentModel(frame, surface, name, content) {
      commitContent(frame, surface, name, content)
    },
    addNotes(frame) {
      const target = currentDoc?.frames[frame]
      if (!currentDoc || !target || target.notes) return
      // Seed the sidecar with one empty body node and open it for editing (ADR 0019).
      const { picture, name } = createNode(
        { statements: [] },
        { at: { x: 8, y: 5 }, options: ['body'], content: parseContent('') },
      )
      state.selected = { frame, surface: 'notes', name }
      state.autoEdit = { frame, surface: 'notes', name }
      commit(withSurface(currentDoc, frame, 'notes', picture))
    },
  }

  // The picture behind the current node selection (shared by the style toolbar reads).
  const selectedPicture = (): { picture: TikzPicture; sel: Selection } | undefined => {
    const sel = state.selected
    const target = sel ? currentDoc?.frames[sel.frame] : undefined
    const picture = target ? pictureOf(target, sel!.surface) : undefined
    return sel && picture ? { picture, sel } : undefined
  }

  // Text-style toolbar (style-in-place): theme-styles dropdown + B/I/U/S. The buttons
  // act on the rich inline editor's live selection (no app plumbing); the dropdown
  // reclassifies the selected node through the standard commit (undo, splice, repaint).
  const styleToolbar = mountStyleToolbar(
    qs('#text-actions'),
    {
      classes: () => Object.keys(activeTheme.style.classes),
      currentClass: () => {
        const at = selectedPicture()
        const node = at ? findNode(at.picture, at.sel.name) : undefined
        if (!node) return undefined
        // The theme ROLE is the first bare token that is not a style knob (`draw`, `ellipse`,
        // `thick`, …), so a shape's paint tokens are never mistaken for its role.
        return styleClasses(node).find((c) => !isStyleKnobToken(c)) ?? null
      },
    },
    {
      setStyleClass: (styleClass) => {
        const at = selectedPicture()
        if (!at || !currentDoc) return
        const picture = setNodeStyleClass(at.picture, at.sel.name, styleClass || null)
        commit(withSurface(currentDoc, at.sel.frame, at.sel.surface, picture))
      },
    },
  )

  const render = async (): Promise<void> => {
    const result = codec.parse(state.source)
    if ('error' in result) {
      errorBanner.textContent = result.error
      errorBanner.hidden = false
      return // keep the last good canvas/navigator
    }
    errorBanner.hidden = true

    const doc = result.doc
    currentDoc = doc
    // Aspect ratio (ADR 0017): size the measurer to this doc's box BEFORE any layout is
    // resolved, so measured node boxes are in the right units for a non-16:9 deck.
    measurer.setSlideWidth(slideBoxFromMeta(doc.meta).width)
    scheduleTableCompile(doc) // compile any new tables out of band; they pop in on onReady
    scheduleCiteCompile(doc) // resolve citations out of band; they pop in on onReady
    docTitle.textContent = getMeta(doc.meta, 'title') ?? 'Untitled'
    const maxIndex = Math.max(0, doc.frames.length - 1)
    state.active = Math.min(state.active, maxIndex)
    if (state.selected && state.selected.frame > maxIndex) state.selected = null
    if (state.selectedConnector && state.selectedConnector.frame > maxIndex)
      state.selectedConnector = null
    if (state.preview && state.preview.frame > maxIndex) state.preview = null
    if (!state.selectedConnector) state.focusedCurve = null // no arrow selected -> no curve focus

    const seq = ++renderSeq
    const autoEdit = state.autoEdit
    state.autoEdit = null // consumed by this paint (value captured in props below)
    const handle = await paintDeck(deck, {
      frames: doc.frames,
      notes: codec.kind !== 'figure', // a bare figure has no presenter-notes sidecar
      selected: state.selected,
      selectedConnector: state.selectedConnector,
      selectedCurve: state.focusedCurve
        ? {
            frame: state.focusedCurve.frame,
            surface: state.focusedCurve.surface,
            anchor: state.focusedCurve.anchor,
          }
        : null,
      connectMode: state.connectMode,
      autoEdit,
      preview: state.preview,
      snapRefs: themeSnapRefs(),
      slideWidth: currentBox().width,
      actions,
      measurer,
      isStale: () => seq !== renderSeq,
      // A scroll report: reflect it in the highlight + step control. It must NOT scroll back
      // (the scroll is what triggered this) — recentering is selectSlide's job on an explicit
      // jump. Decoupled so an already-in-view slide still updates the highlight on click.
      onActiveChange: (index) => setActiveSlide(index),
    })
    if (handle === null) return // a newer render superseded this one
    deckHandle = handle
    decorateDeck() // theme furniture + optional region boundaries over the painted deck
    // A structural edit (new slide) asked to reveal a slide once its deck DOM exists.
    if (pendingScroll !== null) {
      deckHandle.scrollToSlide(pendingScroll)
      pendingScroll = null
    }
    // A figure is a single picture: no deck rail (the navigator is a multi-slide affordance).
    // Capture whether the rail holds focus BEFORE it is rebuilt, so a re-render the carousel
    // itself caused (deleting a slide) can hand focus back to the active thumb — keeping the
    // rail "directly selected" for a follow-up Delete/arrow.
    const railHadFocus = deckRail.contains(document.activeElement)
    navHandle =
      codec.kind === 'figure'
        ? null
        : await paintDeckNav(deckRail, {
            frames: doc.frames,
            active: state.active,
            measurer,
            slideWidth: currentBox().width,
            // Click/arrow selects a slide: highlight it immediately (not after a scroll that
            // may never come — e.g. the 2nd of two slides already in view) AND recentre.
            onSelect: (index) => selectSlide(index),
            onAdd: addSlide,
            focusActive: railHadFocus,
          })
    undoButton.disabled = undoStack.length === 0
    redoButton.disabled = redoStack.length === 0
    setStatus()
    paintPanel()
    updateStepControl()
    styleToolbar.refresh()
  }

  // An out-of-band repaint (a table/citation resolving) rebuilds the deck DOM, which
  // would silently destroy an open inline editor mid-type — losing the edit. Hold the
  // repaint until the edit settles (commit/cancel both remove the editor).
  const renderWhenEditingSettles = (): void => {
    if (root.querySelector('.sb-inline-editor')) {
      setTimeout(renderWhenEditingSettles, 400)
      return
    }
    void render()
  }

  // Compile port (latexml tables): compile out of band, then drop the placeholder
  // measurement and re-render so the table appears at its true size (tableCompiler.md).
  installTableCompiler(ports?.compile, {
    onReady: () => {
      measurer.reset()
      renderWhenEditingSettles()
    },
  })

  // Citations: load the bibliography (Storage port) + number the deck out of band,
  // then re-measure and re-render so `[?]` placeholders resolve (citeCompiler.md).
  installCiteCompiler(ports?.storage, {
    onReady: () => {
      measurer.reset()
      renderWhenEditingSettles()
    },
  })

  codePane = createCodePane(qs('#code'), {
    value: state.source,
    onChange: (value) => {
      state.source = value
      persist()
      void render()
    },
  })

  // Connect mode (E4): a toolbar toggle. In connect mode dragging a node draws an arrow.
  const connectToggle = qs<HTMLButtonElement>('#connect-toggle')
  const setConnectMode = (on: boolean): void => {
    state.connectMode = on
    state.selectedConnector = null
    connectToggle.classList.toggle('is-active', on)
    connectToggle.setAttribute('aria-pressed', String(on))
    void render()
    setStatus()
  }
  connectToggle.addEventListener('click', () => setConnectMode(!state.connectMode))

  // Undo / redo toolbar buttons (keyboard: Ctrl/Cmd+Z, Ctrl/Cmd+Shift+Z).
  undoButton.addEventListener('click', () => undo())
  redoButton.addEventListener('click', () => redo())

  // New slide: the top-bar twin of the carousel's add affordance — one action, two triggers.
  qs<HTMLButtonElement>('#new-slide').addEventListener('click', () => addSlide())

  // Keyboard: undo/redo, Delete, Escape — but never while typing in a field (the code
  // pane, the inline editor, or the creation-menu filter keep their native behaviour,
  // including the textarea's own undo).
  // Overlay step control (ADR 0018): scrub the active slide through its build steps. The
  // preview is per active slide; every other slide (and the default) renders all-visible.
  const stepControl = qs('#step-control')
  const stepReadout = qs('#step-readout')

  /** The step currently previewed for `frame`, or undefined (all-visible). */
  const previewStep = (frame: number): number | undefined =>
    state.preview?.frame === frame ? state.preview.step : undefined

  /** Ctx a single-frame repaint needs: current selection + this frame's preview step. */
  const repaintCtx = (frame: number) => ({
    selected: state.selected,
    selectedConnector: state.selectedConnector,
    selectedCurve: state.focusedCurve
      ? {
          frame: state.focusedCurve.frame,
          surface: state.focusedCurve.surface,
          anchor: state.focusedCurve.anchor,
        }
      : null,
    connectMode: state.connectMode,
    ...(previewStep(frame) !== undefined ? { step: previewStep(frame) } : {}),
    snapRefs: themeSnapRefs(),
    slideWidth: currentBox().width,
  })

  /** Repaint one frame's cards in place (its preview step changed), leaving the rest
   *  untouched. The step drives BOTH surfaces — the notes render at the same step (ADR 0019). */
  const repaintFrameStep = (frame: number): void => {
    const f = currentDoc?.frames[frame]
    if (!f) return
    void deckHandle?.repaintFrame(frame, 'slide', f, repaintCtx(frame))
    if (f.notes) void deckHandle?.repaintFrame(frame, 'notes', f, repaintCtx(frame))
  }

  /** Return a previewed slide to its all-visible authoring view. */
  const clearPreview = (): void => {
    const prev = state.preview
    state.preview = null
    if (prev) repaintFrameStep(prev.frame)
    updateStepControl()
  }

  /** Reflect the active slide's step count and current preview in the app-bar control. */
  function updateStepControl(): void {
    const picture = currentDoc?.frames[state.active]?.picture
    const count = picture ? slideStepCount(picture) : 1
    stepControl.hidden = count <= 1
    if (count <= 1) return
    const step = previewStep(state.active)
    stepReadout.textContent = step === undefined ? `All / ${count}` : `${step} / ${count}`
  }

  /** Scrub the active slide's preview by `delta` through All -> 1 -> ... -> N (All = 0). */
  const stepBy = (delta: number): void => {
    const picture = currentDoc?.frames[state.active]?.picture
    if (!picture) return
    const count = slideStepCount(picture)
    if (count <= 1) return
    const current = previewStep(state.active) ?? 0
    const next = Math.max(0, Math.min(count, current + delta))
    state.preview = next === 0 ? null : { frame: state.active, step: next }
    repaintFrameStep(state.active)
    updateStepControl()
  }

  stepControl.querySelectorAll<HTMLButtonElement>('button').forEach((button) => {
    button.addEventListener('click', () => stepBy(button.dataset.step === 'next' ? 1 : -1))
  })

  /**
   * Make `index` the active slide and reflect it everywhere at once — the carousel highlight,
   * the step control, and any per-slide overlay preview. This is the single owner of "which
   * slide is current", called both by a scroll report (`onActiveChange`) and by an explicit
   * jump (`selectSlide`). Setting the highlight here, instead of waiting for a scroll event,
   * is what fixes selecting a slide that is already in view (e.g. the 2nd of two slides): the
   * scroll can't move, so no scroll event would ever arrive to move the highlight.
   */
  const setActiveSlide = (index: number): void => {
    const last = currentDoc ? currentDoc.frames.length - 1 : 0
    const clamped = Math.min(Math.max(index, 0), Math.max(0, last))
    const changed = clamped !== state.active
    state.active = clamped
    navHandle?.setActive(clamped)
    // Overlay preview is per active slide; moving to another returns it to all-visible.
    if (changed && state.preview && state.preview.frame !== clamped) clearPreview()
    updateStepControl()
  }

  /**
   * Jump to a slide from an explicit gesture (carousel click/arrows, PageUp/Down, Home/End):
   * make it active immediately (highlight now) and best-effort recentre the canvas on it.
   * Decoupling the highlight from the scroll is the fix for the two-slide case above.
   */
  const selectSlide = (index: number): void => {
    setActiveSlide(index)
    deckHandle?.scrollToSlide(state.active)
  }

  document.addEventListener('keydown', (event) => {
    const el = document.activeElement
    const typing = el instanceof HTMLTextAreaElement || el instanceof HTMLInputElement
    if (typing) return
    const mod = event.metaKey || event.ctrlKey
    if (mod && event.key.toLowerCase() === 'z') {
      event.preventDefault()
      if (event.shiftKey) redo()
      else undo()
      return
    }
    if (mod && event.key.toLowerCase() === 'y') {
      event.preventDefault()
      redo() // Windows-style redo
      return
    }
    if (event.key === 'Escape' && state.connectMode) {
      event.preventDefault()
      setConnectMode(false)
      return
    }
    // Slide navigation by keyboard (PageUp/Down, Home/End). Route through selectSlide so the
    // carousel highlight follows even when the canvas can't scroll further (e.g. the last
    // slide can't be centred) — the same decoupling that fixes a carousel click. selectSlide
    // clamps, so out-of-range targets are safe.
    const last = currentDoc ? currentDoc.frames.length - 1 : 0
    if (event.key === 'PageDown') {
      event.preventDefault()
      selectSlide(state.active + 1)
      return
    }
    if (event.key === 'PageUp') {
      event.preventDefault()
      selectSlide(state.active - 1)
      return
    }
    if (event.key === 'Home') {
      event.preventDefault()
      selectSlide(0)
      return
    }
    if (event.key === 'End') {
      event.preventDefault()
      selectSlide(last)
      return
    }
    // Overlay step scrubbing on the active slide (ADR 0018): `.` forward, `,` back.
    if (event.key === '.' || event.key === ',') {
      event.preventDefault()
      stepBy(event.key === '.' ? 1 : -1)
      return
    }
    if (event.key !== 'Delete' && event.key !== 'Backspace') return
    if (state.selectedConnector) {
      event.preventDefault()
      const { frame, surface, index } = state.selectedConnector
      const target = currentDoc?.frames[frame]
      const picture = target ? pictureOf(target, surface) : undefined
      if (!currentDoc || !picture) return
      state.selectedConnector = null
      commit(withSurface(currentDoc, frame, surface, deleteConnector(picture, index)))
    } else if (state.selected) {
      event.preventDefault()
      actions.remove(state.selected.frame, state.selected.surface, state.selected.name)
    } else if (codec.kind !== 'figure' && currentDoc && deckRail.contains(document.activeElement)) {
      // A slide is *directly selected* in the carousel (the rail holds focus), so Delete
      // targets the whole active slide — the one the carousel highlights (state.active).
      // When focus is anywhere else the highlight is only a "you are here" indicator, so
      // Delete does nothing to slides (removing one on an unfocused rail is too destructive).
      // Undoable like any edit (via commit); a deck needs at least one slide, so the last is
      // never deletable.
      event.preventDefault()
      if (currentDoc.frames.length <= 1) {
        status.textContent = 'Cannot delete the last slide — a deck needs at least one.'
      } else {
        commit(withoutFrame(currentDoc, state.active))
      }
    }
  })

  // Shapes panel: the draw.io-style library rail. Clicking a shape drops it at the active
  // slide's centre; dragging one onto the canvas drops it at the cursor (handled below).
  renderShapesPanel(qs('#shapes-panel'), {
    onInsert: (shapeId) => {
      const box = currentBox()
      insertShapeAt(state.active, 'slide', { x: box.width / 2, y: box.height / 2 }, shapeId)
    },
  })

  // Drag a shape from the panel onto a slide -> insert at the cursor. The deck is the drop
  // zone; the dropped-on card carries its (frame, surface) and holds the .sb-slide whose box
  // maps the client point to slide space (the same mapping the canvas gestures use).
  const isShapeDrag = (event: DragEvent): boolean =>
    event.dataTransfer?.types.includes(SHAPE_DRAG_MIME) ?? false
  deck.addEventListener('dragover', (event) => {
    if (!isShapeDrag(event)) return
    event.preventDefault() // permit the drop
    event.dataTransfer!.dropEffect = 'copy'
    deck.classList.add('shape-drop-active')
  })
  deck.addEventListener('dragleave', (event) => {
    if (event.target === deck) deck.classList.remove('shape-drop-active')
  })
  deck.addEventListener('drop', (event) => {
    deck.classList.remove('shape-drop-active')
    const shapeId = event.dataTransfer?.getData(SHAPE_DRAG_MIME)
    if (!shapeId) return
    event.preventDefault()
    const card = (event.target as HTMLElement).closest<HTMLElement>('.deck-slide, .deck-note')
    const slideEl = card?.querySelector<HTMLElement>('.sb-slide')
    if (!card || !slideEl || card.dataset.frame === undefined) return
    const frame = Number(card.dataset.frame)
    const surface: Surface = card.dataset.surface === 'notes' ? 'notes' : 'slide'
    const box = currentBox()
    const rect = slideEl.getBoundingClientRect()
    insertShapeAt(
      frame,
      surface,
      {
        x: ((event.clientX - rect.left) / rect.width) * box.width,
        y: box.height - ((event.clientY - rect.top) / rect.height) * box.height,
      },
      shapeId,
    )
  })

  // Zoom & pan the deck canvas (Ctrl/pinch to zoom, middle/Space-drag to pan).
  const zoomReadout = qs('#zoom-readout')
  const zoom = enableZoomPan(deck, {
    onChange: (value) => {
      zoomReadout.textContent = `${Math.round(value * 100)}%`
    },
  })
  qs('#zoom-control')
    .querySelectorAll<HTMLButtonElement>('button')
    .forEach((button) => {
      button.addEventListener('click', () => {
        if (button.dataset.zoom === 'in') zoom.zoomIn()
        else if (button.dataset.zoom === 'out') zoom.zoomOut()
        else if (button.dataset.zoom === 'fit') zoom.fitWidth()
        else zoom.reset()
      })
    })

  // Export: render the whole deck to a self-contained document, then print (Save as
  // PDF) or download the .html. Both use the DOM-measured layout, so exports are faithful.
  qs('#export-actions')
    .querySelectorAll<HTMLButtonElement>('button')
    .forEach((button) => {
      button.addEventListener('click', async () => {
        if (!currentDoc) return
        const title = getMeta(currentDoc.meta, 'title') ?? 'Slides'
        button.disabled = true
        try {
          const slides = await collectSlides(currentDoc)
          // The export must carry the active theme's style + furniture CSS, so the printed
          // page matches the canvas (default theme's CSS is the fallback inside export).
          const themeCss = `${themeStylesheet(activeTheme)}\n${furnitureCss(activeTheme)}`
          const slideWidth = currentBox().width // aspect ratio (ADR 0017)
          if (button.dataset.export === 'print')
            await printDeck(slides, { title, themeCss, slideWidth })
          else await downloadDeckHtml(slides, { title, themeCss, slideWidth })
        } catch (err) {
          status.textContent = `Export failed: ${err instanceof Error ? err.message : String(err)}`
        } finally {
          button.disabled = false
        }
      })
    })

  // Present (ADR 0019): open the audience + speaker-notes windows, driven by one shared
  // cursor. Rendered from the current in-memory deck (reflects unsaved edits), so tables
  // and citations are compiled first. `present` opens the console window synchronously in
  // this click so the pop-up is not blocked, then renders and writes it in.
  qs('#present').addEventListener('click', () => {
    if (!currentDoc) return
    const doc = currentDoc
    const title = getMeta(doc.meta, 'title') ?? 'Slides'
    // One layout per picture, resolved on first use and reused across its steps (geometry
    // is step-invariant, ADR 0018) — and across the slide/notes of a frame.
    const layouts = new Map<TikzPicture, Layout>()
    void present({
      frames: doc.frames,
      title,
      themeCss: `${themeStylesheet(activeTheme)}\n${furnitureCss(activeTheme)}`,
      prepare: async () => {
        await ensureTables(doc)
        await ensureCitations(doc)
      },
      renderAt: async (picture, step) => {
        let layout = layouts.get(picture)
        if (!layout) {
          layout = await resolveLayoutAsync(picture, measurer)
          layouts.set(picture, layout)
        }
        return renderSlide(picture, layout, { ...renderOptions, step })
      },
      stepsOf: (picture) => slideStepCount(picture),
    }).then((result) => {
      if (!result.ok) {
        status.textContent =
          result.reason === 'blocked'
            ? 'Presenter: allow pop-ups for this site to present.'
            : result.reason === 'empty'
              ? 'Nothing to present yet.'
              : `Presenter failed: ${result.message ?? 'unknown error'}`
      }
    })
  })

  // Theme editor (ADR 0017): a structured GUI over the active theme with live preview.
  const themeButton = document.createElement('button')
  themeButton.type = 'button'
  themeButton.textContent = 'Theme'
  themeButton.title = 'Edit the deck theme'
  qs('#export-actions').append(themeButton)
  let themeEditor: ThemeEditorHandle | null = null
  themeButton.addEventListener('click', () => {
    if (themeEditor) {
      themeEditor.close()
      return
    }
    themeEditor = openThemeEditor({
      theme: activeTheme,
      showRegions,
      onChange: (t, o) => {
        activeTheme = t
        showRegions = o.showRegions
        applyThemeCss()
        decorateDeck()
      },
      onSave: async (t) => {
        if (!ports) throw new Error('This shell has no storage to save into.')
        const id = (currentDoc && getMeta(currentDoc.meta, 'theme')) || 'default'
        await ports.storage.write(`themes/${id}/theme.json`, serializeTheme(t))
      },
      onClose: () => {
        themeEditor = null
      },
    })
  })

  // Working-copy boot (M3): open a document from storage, reveal the side panel
  // (file tree + source control), and keep everything refreshed on mutation.
  // Without ports the app stays on the bundled in-memory sample (pre-M3 behaviour).
  const fileTreeHost = ports ? qs('#file-tree') : null

  const refreshTree = async (): Promise<void> => {
    if (!ports || !fileTreeHost) return
    await paintFileTree(fileTreeHost, {
      storage: ports.storage,
      currentPath,
      onOpen: (path) => void openDoc(path),
      onMutate: () => void onWorkspaceMutated(),
    })
  }

  /**
   * Show/hide deck-only chrome for the open document's kind. A figure (`.tikz`) is a single
   * standalone picture, so it drops the slide navigator rail and the presenter/export/theme
   * controls (all multi-slide/deck concepts). Inline `display` beats stylesheet rules — e.g.
   * `.deck-rail{display:flex}` defeats the `[hidden]` attribute — so toggle it directly.
   */
  const applyDocModeChrome = (): void => {
    const deckOnly = codec.kind !== 'figure'
    deckRail.style.display = deckOnly ? '' : 'none'
    if (!deckOnly) deckRail.replaceChildren() // drop stale thumbnails so nothing lingers hidden
    for (const id of ['#present-actions', '#export-actions', '#new-slide']) {
      qs<HTMLElement>(id).style.display = deckOnly ? '' : 'none'
    }
  }

  /** Switch the editor to `path`: flush (or drop) pending saves, load, reset history. */
  const openDoc = async (path: string): Promise<void> => {
    if (!ports || !autosave) return
    // A pending save of a deleted/renamed-away file must not resurrect it.
    if (currentPath && (await ports.storage.exists(currentPath))) await autosave.flush()
    else autosave.discard()
    const source = await ports.storage.readText(path)
    currentPath = path
    codec = codecFor(path) // pick deck vs figure BEFORE render()/loadActiveTheme read the doc
    // Only decks are auto-reopened on boot (findDocs is deck-only); don't let a figure
    // clobber the last-deck memory a reload would otherwise fall back to.
    if (isDocPath(path)) rememberDoc(path)
    editorHead.textContent = path
    undoStack.length = 0
    redoStack.length = 0
    state.source = source
    state.active = 0
    state.selected = null
    state.selectedConnector = null
    state.autoEdit = null
    codePane.setValue(source)
    applyDocModeChrome()
    await render()
    await loadActiveTheme() // the doc may select a saved theme; apply it over the fresh paint
    await refreshTree()
  }

  /** After a file-tree mutation: reopen if the current doc vanished, repaint views. */
  const onWorkspaceMutated = async (): Promise<void> => {
    if (!ports) return
    if (currentPath && !(await ports.storage.exists(currentPath))) {
      autosave?.discard()
      currentPath = null
      await openDoc(await bootDocument(ports.storage, initialSource, SEED_FILES))
    } else {
      await refreshTree()
    }
    void gitPanel?.refresh()
  }

  if (ports && autosave) {
    qs('#side-panel').hidden = false
    gitPanel = createGitPanel(qs('#git-panel'), {
      git: ports.git,
      auth: ports.auth,
      beforeCommit: () => autosave.flush(),
      getRemote: () => readRemote(),
      setRemote: (remote) => writeRemote(remote),
      // A pull rewrites files on disk; drop any pending edit and reopen so the
      // canvas/code pane show the pulled content (re-boot if it was removed).
      afterPull: async () => {
        autosave.discard()
        const path =
          currentPath && (await ports.storage.exists(currentPath))
            ? currentPath
            : await bootDocument(ports.storage, initialSource, SEED_FILES)
        await openDoc(path)
      },
      onError: (message) => {
        status.textContent = message
      },
      onInfo: (message) => {
        status.textContent = message
      },
    })
    // Last-resort flush; the 400ms debounce keeps the unload race window small.
    window.addEventListener('beforeunload', () => void autosave.flush())
    void (async () => {
      try {
        await openDoc(await bootDocument(ports.storage, initialSource, SEED_FILES))
      } catch (err) {
        errorBanner.textContent = `workspace failed to open: ${err instanceof Error ? err.message : String(err)}`
        errorBanner.hidden = false
      }
      await gitPanel?.refresh()
    })()
  } else {
    void render()
  }
}

// Inject the engine's base stylesheet, the shared slide type scale, and the KaTeX
// stylesheet once; app.css layers the workspace chrome. SLIDE_TYPE_CSS is keyed on
// .sb-slide so the deck, thumbnails, the measurer, and the export match; KATEX_CSS
// (fonts embedded) styles the math the renderMath seam emits, document-wide.
// Guarded by a marker id so a re-mount (or a shell mounting twice) injects once.
function injectGlobalStyles(): void {
  if (document.getElementById('sb-global-styles')) return
  const style = document.createElement('style')
  style.id = 'sb-global-styles'
  style.textContent = `${slideStylesheet()}\n${SLIDE_THEME_CSS}\n${SLIDE_TYPE_CSS}\n${KATEX_CSS}`
  document.head.append(style)
}
