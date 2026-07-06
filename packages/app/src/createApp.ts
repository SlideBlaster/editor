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
  getMeta,
  slideStylesheet,
  renderSlide,
  resolveLayoutAsync,
  parseContent,
  findNode,
  moveNodeTo,
  placeNodeRelative,
  createNode,
  deleteNode,
  setNodeContent,
  createConnector,
  deleteConnector,
  updateConnector,
  setConnectorOptions,
  type NodeContent,
  type RenderedSlide,
  type SlideDocument,
  type TikzPicture,
} from '@slideblaster/editor'
import initialSource from './sample.slideBlaster.md?raw'
import sampleBib from './sample.refs.bib?raw'
import { createCodePane, type CodePane } from './codePane'
import { minimalDiff } from './sourceDelta'
import {
  paintDeck,
  type DeckActions,
  type DeckHandle,
  type Selection,
  type ConnectorSelection,
} from './deck'
import { paintDeckNav, type NavHandle } from './deckNav'
import { paintProperties, type PropSelection } from './properties'
import { openCreationMenu, type MenuItem } from './createMenu'
import { enableZoomPan } from './zoom'
import { createDomMeasurer } from './domMeasurer'
import { SLIDE_TYPE_CSS } from './slideType'
import {
  renderOptions,
  installTableCompiler,
  scheduleTableCompile,
  ensureTables,
} from './tableCompiler'
import { installCiteCompiler, scheduleCiteCompile, ensureCitations } from './citeCompiler'
import { KATEX_CSS } from './katexInlineCss'
import { downloadDeckHtml, printDeck } from './export'
import { renderChrome } from './chrome'
import { enableResizers } from './resizer'
import {
  bootDocument,
  createAutosave,
  rememberDoc,
  readRemote,
  writeRemote,
  type AppPorts,
} from './workspace'
import { paintFileTree } from './fileTree'
import { createGitPanel, type GitPanelHandle } from './gitPanel'
import './app.css'

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
  connectMode: boolean // E4: dragging a node draws an arrow instead of moving it
  autoEdit: Selection | null // W5: a just-created node to open in edit mode next paint
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

/** Tolerant parse: a malformed edit keeps the last good render instead of blanking. */
function parse(source: string): { doc: SlideDocument } | { error: string } {
  try {
    return { doc: fromMarkdown(source) }
  } catch (err) {
    return { error: err instanceof Error ? err.message : String(err) }
  }
}

/** A document with one frame's picture swapped — the unit of a canvas edit. */
function withFrame(doc: SlideDocument, index: number, picture: TikzPicture): SlideDocument {
  return {
    meta: doc.meta,
    frames: doc.frames.map((frame, i) => (i === index ? { ...frame, picture } : frame)),
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
    connectMode: false,
    autoEdit: null,
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
  let codePane: CodePane
  let deckHandle: DeckHandle | null = null
  let navHandle: NavHandle | null = null
  const measurer = createDomMeasurer()
  // Monotonic render token: a slow async paint that finishes after a newer edit is dropped.
  let renderSeq = 0

  // Working copy (M3): which document is open, its debounced persistence, and the
  // side-panel views. All null/absent when the shell wired no ports (in-memory mode).
  const ports = opts.ports ?? null
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
    const frame = state.selected?.frame ?? state.selectedConnector?.frame ?? null
    const selection: PropSelection = state.selected
      ? { kind: 'node', name: state.selected.name }
      : state.selectedConnector
        ? { kind: 'connector', index: state.selectedConnector.index }
        : null
    const picture = frame !== null ? (currentDoc?.frames[frame]?.picture ?? null) : null
    paintProperties(propsHost, {
      selection,
      picture,
      actions: {
        moveNode: (name, center) => frame !== null && actions.move(frame, name, center),
        bindNode: (name, binding) => frame !== null && actions.bind(frame, name, binding),
        setConnectorOptions: (index, options) => {
          const target = frame !== null ? currentDoc?.frames[frame] : undefined
          if (currentDoc && target && frame !== null)
            commit(
              withFrame(currentDoc, frame, setConnectorOptions(target.picture, index, options)),
            )
        },
      },
    })
  }

  /** Mount (or clear) the selected node's column grid affordance without a repaint — the
   *  selection-change path, since `select` deliberately does not re-render the canvas. */
  const mountColumnEditors = (): void => {
    const sel = state.selected
    const picture = sel && currentDoc ? currentDoc.frames[sel.frame]?.picture : undefined
    const node = sel && picture ? findNode(picture, sel.name) : undefined
    deckHandle?.setColumnEditors(
      sel && node ? { frame: sel.frame, name: sel.name, content: node.content } : null,
    )
  }

  /** Apply an edit op result: snapshot for undo, re-serialize, sync the code pane, render. */
  const commit = (doc: SlideDocument): void => {
    undoStack.push(state.source) // the pre-edit source is the undo target
    if (undoStack.length > HISTORY_LIMIT) undoStack.shift()
    redoStack.length = 0 // a new edit invalidates the redo branch
    state.source = toMarkdown(doc)
    codePane.setValue(state.source)
    persist()
    void render()
  }

  /**
   * Node-scoped commit for a content edit (ADR 0016): apply the new node content, then
   * derive both deltas instead of a whole-scene round-trip — splice the code pane at the
   * one changed range (`minimalDiff`, caret kept) and re-paint just this frame's card and
   * thumbnail. Undo/persist are unchanged; only the paint is localized.
   */
  const commitContent = (frame: number, name: string, content: NodeContent): void => {
    const target = currentDoc?.frames[frame]
    if (!currentDoc || !target) return
    const doc = withFrame(currentDoc, frame, setNodeContent(target.picture, name, content))

    undoStack.push(state.source)
    if (undoStack.length > HISTORY_LIMIT) undoStack.shift()
    redoStack.length = 0
    const next = toMarkdown(doc)
    const edit = minimalDiff(state.source, next)
    codePane.replaceRange(edit.start, edit.end, edit.text)
    state.source = next
    currentDoc = doc
    persist()
    scheduleTableCompile(doc) // the edit may have introduced a table; keep compilation live
    scheduleCiteCompile(doc) // the edit may have changed a \cite or the bibliography

    // Canvas delta: only this frame's card + thumbnail, everything else untouched.
    const ctx = {
      selected: state.selected,
      selectedConnector: state.selectedConnector,
      connectMode: state.connectMode,
    }
    void deckHandle?.repaintFrame(frame, doc.frames[frame]!, ctx)
    navHandle?.repaintThumb(frame, doc.frames[frame]!)
    undoButton.disabled = undoStack.length === 0
    redoButton.disabled = redoStack.length === 0
  }

  /** Restore a source from history, syncing the pane and clearing transient selections. */
  const restore = (source: string): void => {
    state.source = source
    codePane.setValue(source)
    state.selected = null
    state.selectedConnector = null
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

  /** Render every frame to self-contained HTML for export — same measurements as the canvas. */
  const collectSlides = async (doc: SlideDocument): Promise<RenderedSlide[]> => {
    await ensureTables(doc) // the export must not race the async table compile
    await ensureCitations(doc) // resolve \cite numbering + bibliography before export
    return Promise.all(
      doc.frames.map(async (frame, index) => ({
        index,
        html: renderSlide(
          frame.picture,
          await resolveLayoutAsync(frame.picture, measurer),
          renderOptions,
        ),
      })),
    )
  }

  const actions: DeckActions = {
    select(frame, name) {
      state.selected = name === null ? null : { frame, name }
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
      setStatus()
      paintPanel()
    },
    connect(frame, from, to) {
      const target = currentDoc?.frames[frame]
      if (!currentDoc || !target) return
      commit(withFrame(currentDoc, frame, createConnector(target.picture, from, to)))
    },
    selectConnector(frame, index) {
      state.selectedConnector = index === null ? null : { frame, index }
      if (index !== null) state.selected = null // connector and node selection are exclusive
      void render() // cheap re-render to reflect the connector highlight (no drag in flight)
    },
    updateConnector(frame, index, path) {
      const target = currentDoc?.frames[frame]
      if (!currentDoc || !target) return
      commit(withFrame(currentDoc, frame, updateConnector(target.picture, index, path)))
    },
    move(frame, name, center) {
      const target = currentDoc?.frames[frame]
      if (!currentDoc || !target) return
      commit(withFrame(currentDoc, frame, moveNodeTo(target.picture, name, center)))
    },
    bind(frame, name, binding) {
      const target = currentDoc?.frames[frame]
      if (!currentDoc || !target) return
      commit(withFrame(currentDoc, frame, placeNodeRelative(target.picture, name, binding)))
    },
    requestCreate(frame, center, client) {
      if (!currentDoc?.frames[frame]) return
      // Summon the creation menu at the cursor; picking inserts at the slide point,
      // selects the new node, and opens it in edit mode (ux/creation-menu.md).
      openCreationMenu(client.x, client.y, {
        items: CATALOGUE,
        onDismiss: () => {}, // an exploratory summon leaves no trace
        onPick: (id) => {
          const entry = CATALOGUE.find((item) => item.id === id)
          const target = currentDoc?.frames[frame]
          if (!entry || !currentDoc || !target) return
          const { picture, name } = createNode(target.picture, {
            at: center,
            options: entry.options,
            content: parseContent(entry.body),
          })
          state.selected = { frame, name }
          state.autoEdit = { frame, name }
          commit(withFrame(currentDoc, frame, picture))
        },
      })
    },
    remove(frame, name) {
      const target = currentDoc?.frames[frame]
      if (!currentDoc || !target) return
      if (state.selected?.frame === frame && state.selected.name === name) state.selected = null
      commit(withFrame(currentDoc, frame, deleteNode(target.picture, name)))
    },
    editContent(frame, name, body) {
      // parseContent tolerates out-of-subset input: it lands as error content that
      // re-serializes verbatim (source kept) and renders as a marked error (ADR 0015).
      commitContent(frame, name, parseContent(body))
    },
    editContentModel(frame, name, content) {
      commitContent(frame, name, content)
    },
  }

  const render = async (): Promise<void> => {
    const result = parse(state.source)
    if ('error' in result) {
      errorBanner.textContent = result.error
      errorBanner.hidden = false
      return // keep the last good canvas/navigator
    }
    errorBanner.hidden = true

    const doc = result.doc
    currentDoc = doc
    scheduleTableCompile(doc) // compile any new tables out of band; they pop in on onReady
    scheduleCiteCompile(doc) // resolve citations out of band; they pop in on onReady
    docTitle.textContent = getMeta(doc.meta, 'title') ?? 'Untitled'
    const maxIndex = Math.max(0, doc.frames.length - 1)
    state.active = Math.min(state.active, maxIndex)
    if (state.selected && state.selected.frame > maxIndex) state.selected = null
    if (state.selectedConnector && state.selectedConnector.frame > maxIndex)
      state.selectedConnector = null

    const seq = ++renderSeq
    const autoEdit = state.autoEdit
    state.autoEdit = null // consumed by this paint (value captured in props below)
    const handle = await paintDeck(deck, {
      frames: doc.frames,
      selected: state.selected,
      selectedConnector: state.selectedConnector,
      connectMode: state.connectMode,
      autoEdit,
      actions,
      measurer,
      isStale: () => seq !== renderSeq,
      onActiveChange: (index) => {
        state.active = index
        navHandle?.setActive(index)
      },
    })
    if (handle === null) return // a newer render superseded this one
    deckHandle = handle
    navHandle = paintDeckNav(deckRail, {
      frames: doc.frames,
      active: state.active,
      onSelect: (index) => deckHandle?.scrollToSlide(index),
    })
    undoButton.disabled = undoStack.length === 0
    redoButton.disabled = redoStack.length === 0
    setStatus()
    paintPanel()
  }

  // Compile port (latexml tables): compile out of band, then drop the placeholder
  // measurement and re-render so the table appears at its true size (tableCompiler.md).
  installTableCompiler(ports?.compile, {
    onReady: () => {
      measurer.reset()
      void render()
    },
  })

  // Citations: load the bibliography (Storage port) + number the deck out of band,
  // then re-measure and re-render so `[?]` placeholders resolve (citeCompiler.md).
  installCiteCompiler(ports?.storage, {
    onReady: () => {
      measurer.reset()
      void render()
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

  // Keyboard: undo/redo, Delete, Escape — but never while typing in a field (the code
  // pane, the inline editor, or the creation-menu filter keep their native behaviour,
  // including the textarea's own undo).
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
    // Slide navigation by keyboard (PageUp/Down, Home/End).
    const last = currentDoc ? currentDoc.frames.length - 1 : 0
    if (event.key === 'PageDown') {
      event.preventDefault()
      deckHandle?.scrollToSlide(Math.min(state.active + 1, last))
      return
    }
    if (event.key === 'PageUp') {
      event.preventDefault()
      deckHandle?.scrollToSlide(Math.max(state.active - 1, 0))
      return
    }
    if (event.key === 'Home') {
      event.preventDefault()
      deckHandle?.scrollToSlide(0)
      return
    }
    if (event.key === 'End') {
      event.preventDefault()
      deckHandle?.scrollToSlide(last)
      return
    }
    if (event.key !== 'Delete' && event.key !== 'Backspace') return
    if (state.selectedConnector) {
      event.preventDefault()
      const { frame, index } = state.selectedConnector
      const target = currentDoc?.frames[frame]
      if (!currentDoc || !target) return
      state.selectedConnector = null
      commit(withFrame(currentDoc, frame, deleteConnector(target.picture, index)))
    } else if (state.selected) {
      event.preventDefault()
      actions.remove(state.selected.frame, state.selected.name)
    }
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
          if (button.dataset.export === 'print') await printDeck(slides, { title })
          else await downloadDeckHtml(slides, { title })
        } catch (err) {
          status.textContent = `Export failed: ${err instanceof Error ? err.message : String(err)}`
        } finally {
          button.disabled = false
        }
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

  /** Switch the editor to `path`: flush (or drop) pending saves, load, reset history. */
  const openDoc = async (path: string): Promise<void> => {
    if (!ports || !autosave) return
    // A pending save of a deleted/renamed-away file must not resurrect it.
    if (currentPath && (await ports.storage.exists(currentPath))) await autosave.flush()
    else autosave.discard()
    const source = await ports.storage.readText(path)
    currentPath = path
    rememberDoc(path)
    editorHead.textContent = path
    undoStack.length = 0
    redoStack.length = 0
    state.source = source
    state.active = 0
    state.selected = null
    state.selectedConnector = null
    state.autoEdit = null
    codePane.setValue(source)
    await render()
    await refreshTree()
  }

  /** After a file-tree mutation: reopen if the current doc vanished, repaint views. */
  const onWorkspaceMutated = async (): Promise<void> => {
    if (!ports) return
    if (currentPath && !(await ports.storage.exists(currentPath))) {
      autosave?.discard()
      currentPath = null
      await openDoc(await bootDocument(ports.storage, initialSource, { 'refs.bib': sampleBib }))
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
            : await bootDocument(ports.storage, initialSource, { 'refs.bib': sampleBib })
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
        await openDoc(await bootDocument(ports.storage, initialSource, { 'refs.bib': sampleBib }))
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
  style.textContent = `${slideStylesheet()}\n${SLIDE_TYPE_CSS}\n${KATEX_CSS}`
  document.head.append(style)
}
