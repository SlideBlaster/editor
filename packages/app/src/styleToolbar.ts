/**
 * Text-style toolbar (app bar). Contract: see styleToolbar.md.
 *
 * The style-in-place controls: a theme-styles dropdown that reclassifies the selected
 * node, and Bold / Italic / Underline / Strike buttons that style the live selection
 * inside the rich inline editor. The buttons act through the browser's editing
 * commands (`document.execCommand`) on the contenteditable — the same path native
 * Ctrl+B/I/U takes — so splitting, merging, and the collapsed-caret typing style are
 * native, and the editor's DOM->model read-back canonicalizes whatever they emit into
 * html-dialect runs (the default dialect for new canvas styling). Button pressed-state
 * follows the caret via `queryCommandState` on (rAF-coalesced) `selectionchange` —
 * true only when the whole selection carries the style, Docs semantics.
 *
 * Focus discipline: buttons prevent default on mousedown so a click never blurs the
 * editor (blur commits) or drops its selection. The dropdown is the exception — it
 * needs real focus to open, which blurs and commits an open editor first; the class
 * then applies to the still-selected node. That ordering is the natural one.
 */
export interface StyleToolbarState {
  /** The active theme's role classes, in dropdown order. */
  classes(): string[]
  /** The selected node's class: a name, null (selected but unclassed), or undefined
   *  (no node selected — the dropdown disables). */
  currentClass(): string | null | undefined
}

export interface StyleToolbarActions {
  /** Reclassify the selected node (empty string clears the class). */
  setStyleClass(styleClass: string): void
}

const COMMANDS = [
  { command: 'bold', label: '<b>B</b>', title: 'Bold (Ctrl+B)' },
  { command: 'italic', label: '<i>I</i>', title: 'Italic / emph (Ctrl+I)' },
  { command: 'underline', label: '<u>U</u>', title: 'Underline (Ctrl+U)' },
  { command: 'strikeThrough', label: '<s>S</s>', title: 'Strikethrough' },
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
      document.execCommand(spec.command)
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
      button.classList.toggle(
        'is-active',
        active && document.queryCommandState(button.dataset.format!),
      )
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
    updateButtons()
  }
  refresh()
  return { refresh }
}
