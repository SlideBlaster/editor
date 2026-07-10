/**
 * Text-style toolbar (app bar). Contract: see styleToolbar.md.
 *
 * The style-in-place controls: a theme-styles dropdown that reclassifies the selected
 * node, a per-node font-size control (A- / value / A+), and Bold / Italic / Underline /
 * Strike / Highlight buttons that style the live selection inside the rich inline editor. The buttons act through the browser's editing
 * commands (`document.execCommand`) on the contenteditable — the same path native
 * Ctrl+B/I/U takes — so splitting, merging, and the collapsed-caret typing style are
 * native, and the editor's DOM->model read-back canonicalizes whatever they emit into
 * html-dialect runs (the default dialect for new canvas styling). Button pressed-state
 * follows the caret via `queryCommandState` on (rAF-coalesced) `selectionchange` —
 * true only when the whole selection carries the style, Docs semantics.
 *
 * Highlight is the exception: there is no native `execCommand`/`queryCommandState` for
 * `<mark>`, so it delegates to `toggleHighlight`/`isSelectionHighlighted` (richText.ts) —
 * apply still rides `execCommand('hiliteColor')` (undoable; read-back canonicalizes the
 * background span to a `mark` run), and pressed-state is a DOM check.
 *
 * Focus discipline: buttons prevent default on mousedown so a click never blurs the
 * editor (blur commits) or drops its selection. The dropdown is the exception — it
 * needs real focus to open, which blurs and commits an open editor first; the class
 * then applies to the still-selected node. That ordering is the natural one.
 */
import { isSelectionHighlighted, toggleHighlight } from './richText'

export interface StyleToolbarState {
  /** The active theme's role classes, in dropdown order. */
  classes(): string[]
  /** The selected node's class: a name, null (selected but unclassed), or undefined
   *  (no node selected — the dropdown disables). */
  currentClass(): string | null | undefined
  /** The selected node's effective text size in `cqw` (its override, else the resolved
   *  role/base size) plus the theme's modular step ratio, or undefined when no node is
   *  selected (the size control disables). */
  fontSize(): { value: number; step: number } | undefined
}

export interface StyleToolbarActions {
  /** Reclassify the selected node (empty string clears the class). */
  setStyleClass(styleClass: string): void
  /** Set the selected node's font size in `cqw`, or null to clear back to the theme role
   *  size (class < node). The controller normalizes a value equal to the inherited size to
   *  a clear, so resetting removes the token. */
  setFontSize(cqw: number | null): void
}

const COMMANDS = [
  { command: 'bold', label: '<b>B</b>', title: 'Bold (Ctrl+B)' },
  { command: 'italic', label: '<i>I</i>', title: 'Italic / emph (Ctrl+I)' },
  { command: 'underline', label: '<u>U</u>', title: 'Underline (Ctrl+U)' },
  { command: 'strikeThrough', label: '<s>S</s>', title: 'Strikethrough' },
  { command: 'highlight', label: '<mark>H</mark>', title: 'Highlight' },
] as const

/** The open rich inline editor, if any (the buttons' target). */
function richEditor(): HTMLElement | null {
  return document.querySelector<HTMLElement>('.sb-inline-editor[data-rich]')
}

function selectionInside(editor: HTMLElement): boolean {
  const selection = document.getSelection()
  return selection !== null && selection.rangeCount > 0 && editor.contains(selection.anchorNode)
}

/** Mount the toolbar into its app-bar host. `refresh()` re-reads the dropdown state —
 *  call it whenever the selection or document changes (render + select paths). */
export function mountStyleToolbar(
  host: HTMLElement,
  state: StyleToolbarState,
  actions: StyleToolbarActions,
): { refresh(): void } {
  const dropdown = document.createElement('select')
  dropdown.id = 'style-class'
  dropdown.title = 'Text style (theme role) of the selected box'
  dropdown.addEventListener('change', () => actions.setStyleClass(dropdown.value))
  host.append(dropdown)

  // Font size (node-grain, pairs with the styles dropdown): A- / value / A+. Unlike the
  // format buttons it does NOT preventDefault — like the dropdown, taking focus first blurs
  // (and commits) an open inline editor, then the size applies to the still-selected node.
  const round = (n: number): number => Math.round(n * 100) / 100
  const sizeGroup = document.createElement('span')
  sizeGroup.className = 'font-size-control'
  const decButton = document.createElement('button')
  decButton.type = 'button'
  decButton.innerHTML = 'A&minus;'
  decButton.title = 'Decrease text size'
  decButton.addEventListener('click', () => {
    const fs = state.fontSize()
    if (fs) actions.setFontSize(round(fs.value / fs.step))
  })
  const sizeInput = document.createElement('input')
  sizeInput.type = 'number'
  sizeInput.min = '0'
  sizeInput.step = '0.1'
  sizeInput.id = 'font-size'
  sizeInput.title =
    'Text size of the selected box (% of slide width); clear to use the style default'
  sizeInput.addEventListener('change', () => {
    const value = Number.parseFloat(sizeInput.value)
    actions.setFontSize(Number.isFinite(value) && value > 0 ? round(value) : null)
  })
  const incButton = document.createElement('button')
  incButton.type = 'button'
  incButton.innerHTML = 'A&plus;'
  incButton.title = 'Increase text size'
  incButton.addEventListener('click', () => {
    const fs = state.fontSize()
    if (fs) actions.setFontSize(round(fs.value * fs.step))
  })
  sizeGroup.append(decButton, sizeInput, incButton)
  host.append(sizeGroup)

  const updateSize = (): void => {
    const fs = state.fontSize()
    const disabled = fs === undefined
    decButton.disabled = disabled
    incButton.disabled = disabled
    sizeInput.disabled = disabled
    // Don't clobber the field while the user is typing into it.
    if (document.activeElement !== sizeInput) sizeInput.value = fs ? String(round(fs.value)) : ''
  }

  const buttons = COMMANDS.map((spec) => {
    const button = document.createElement('button')
    button.type = 'button'
    button.innerHTML = spec.label
    button.title = spec.title
    button.dataset.format = spec.command
    // Never steal focus: a blur would commit-and-close the editor mid-gesture.
    button.addEventListener('mousedown', (event) => event.preventDefault())
    button.addEventListener('click', () => {
      const editor = richEditor()
      if (!editor || !selectionInside(editor)) return
      if (spec.command === 'highlight') toggleHighlight(editor)
      else document.execCommand(spec.command)
      updateButtons()
    })
    host.append(button)
    return button
  })

  const updateButtons = (): void => {
    const editor = richEditor()
    const active = editor !== null && selectionInside(editor)
    for (const button of buttons) {
      button.disabled = !active
      const command = button.dataset.format!
      let on = false
      if (active && editor) {
        on =
          command === 'highlight'
            ? isSelectionHighlighted(editor)
            : document.queryCommandState(command)
      }
      button.classList.toggle('is-active', on)
    }
  }

  // Follow the caret. selectionchange only exists on document; coalesce to a frame.
  let queued = false
  document.addEventListener('selectionchange', () => {
    if (queued) return
    queued = true
    requestAnimationFrame(() => {
      queued = false
      updateButtons()
    })
  })

  const refresh = (): void => {
    const classes = state.classes()
    const wanted = ['', ...classes]
    if ([...dropdown.options].map((o) => o.value).join('\n') !== wanted.join('\n')) {
      dropdown.replaceChildren(
        new Option('Style', ''),
        ...classes.map((c) => new Option(c[0]!.toUpperCase() + c.slice(1), c)),
      )
    }
    const current = state.currentClass()
    dropdown.disabled = current === undefined
    dropdown.value = current ?? ''
    updateSize()
    updateButtons()
  }
  refresh()
  return { refresh }
}
