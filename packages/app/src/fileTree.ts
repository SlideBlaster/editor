/**
 * The file tree panel. Contract: see fileTree.md.
 *
 * A recursive view of the working copy (`.git` hidden): directories expand and
 * collapse, documents open in the editor, files are created, renamed, and
 * deleted through the Storage port. Naming — new deck/file/folder and rename —
 * happens **inline** (a text field in the tree), never a popup. Repainted whole
 * on every change; expansion and the in-progress inline edit survive repaints.
 */
import type { FileEntry, StoragePort } from '@slideblaster/editor'
import { DOC_EXTENSION, isDocPath } from './workspace'
import { alertDialog, confirmDialog } from './dialog'

export interface FileTreeProps {
  storage: StoragePort
  /** The document currently open in the editor (highlighted). */
  currentPath: string | null
  /** Open a document in the editor. */
  onOpen(path: string): void
  /** A storage mutation happened (create/rename/delete): refresh dependent views. */
  onMutate(): void
}

interface TreeNode extends FileEntry {
  children: TreeNode[]
}

/** An in-progress inline edit. `rename` carries the path being renamed. */
type EditState = { kind: 'new-deck' | 'new-file' | 'new-folder' } | { kind: 'rename'; path: string }

// Per-host state that survives the whole-tree repaint.
const expandedByHost = new WeakMap<HTMLElement, Set<string>>()
const editingByHost = new WeakMap<HTMLElement, EditState | null>()

const NEW_DOC_TEMPLATE = [
  '---',
  'title: Untitled',
  '---',
  '',
  '## Slide 1 {#s1}',
  '',
  '```slide',
  '\\node[title] (title) at (8,8) {Untitled};',
  '```',
  '',
].join('\n')

const CREATE_META: Record<'new-deck' | 'new-file' | 'new-folder', { glyph: string; hint: string }> =
  {
    'new-deck': { glyph: '▤', hint: 'talks/demo' },
    'new-file': { glyph: '＋', hint: 'notes.md' },
    'new-folder': { glyph: '🗀', hint: 'assets' },
  }

export async function paintFileTree(host: HTMLElement, props: FileTreeProps): Promise<void> {
  const expanded = expandedByHost.get(host) ?? new Set<string>()
  expandedByHost.set(host, expanded)
  const editing = editingByHost.get(host) ?? null

  const tree = await buildTree(props.storage, '')
  host.replaceChildren()

  // The input to focus once the tree is in the DOM (only one edit at a time).
  let activeInput: HTMLInputElement | null = null

  const repaint = (): void => void paintFileTree(host, props)
  const beginEdit = (state: EditState): void => {
    editingByHost.set(host, state)
    repaint()
  }
  const cancelEdit = (): void => {
    editingByHost.set(host, null)
    repaint()
  }
  const markInvalid = (input: HTMLInputElement): void => {
    input.style.borderColor = 'var(--danger)'
    input.focus()
  }

  // Header + create affordances (each opens an inline field, not a popup).
  const head = document.createElement('div')
  head.className = 'side-title'
  const label = document.createElement('span')
  label.textContent = 'Files'
  const actions = document.createElement('div')
  actions.style.cssText = 'display:flex;gap:.25rem;flex-wrap:wrap;justify-content:flex-end'
  actions.append(
    titleAction('New deck', '▤', () => beginEdit({ kind: 'new-deck' })),
    titleAction('New file', '＋', () => beginEdit({ kind: 'new-file' })),
    titleAction('New folder', '🗀', () => beginEdit({ kind: 'new-folder' })),
    titleAction('Upload file', '⬆', () => uploadFiles(props)),
  )
  head.append(label, actions)
  host.append(head)

  // Create an empty file / a deck / a folder from the inline name. Guarded by the
  // editing state so a stray blur after a successful write (repaint detaches the
  // input) is a no-op. On clash: keep editing and mark the field, unless the blur
  // is taking focus away — then just cancel so the user is never trapped.
  const commitCreate = async (
    kind: 'new-deck' | 'new-file' | 'new-folder',
    raw: string,
    input: HTMLInputElement,
    fromBlur: boolean,
  ): Promise<void> => {
    if (!editingByHost.get(host)) return
    const value = raw.trim()
    if (!value) return cancelEdit()

    if (kind === 'new-folder') {
      const dir = value.replace(/\/+$/, '')
      const keep = `${dir}/.gitkeep` // git does not track empty dirs
      if (await props.storage.exists(keep)) return fromBlur ? cancelEdit() : markInvalid(input)
      await props.storage.write(keep, '')
      editingByHost.set(host, null)
      props.onMutate()
      return
    }

    const path =
      kind === 'new-deck' && !value.endsWith(DOC_EXTENSION) ? value + DOC_EXTENSION : value
    if (await props.storage.exists(path)) return fromBlur ? cancelEdit() : markInvalid(input)
    await props.storage.write(path, kind === 'new-deck' ? NEW_DOC_TEMPLATE : '')
    editingByHost.set(host, null)
    props.onMutate()
    if (kind === 'new-deck' || isDocPath(path)) props.onOpen(path)
  }

  const commitRename = async (
    original: string,
    raw: string,
    input: HTMLInputElement,
    fromBlur: boolean,
  ): Promise<void> => {
    if (!editingByHost.get(host)) return
    const next = raw.trim()
    if (!next || next === original) return cancelEdit()
    const target =
      isDocPath(original) && !next.endsWith(DOC_EXTENSION) ? `${next}${DOC_EXTENSION}` : next
    if (await props.storage.exists(target)) return fromBlur ? cancelEdit() : markInvalid(input)
    // The Storage port has no rename; copy+delete is equivalent for the working copy.
    await props.storage.write(target, await props.storage.read(original))
    await props.storage.remove(original)
    editingByHost.set(host, null)
    props.onMutate()
    if (props.currentPath === original) props.onOpen(target)
  }

  // Drag a file into a folder (or onto the tree background = root). A move is
  // copy+delete (the Storage port has no move); the destination is auto-expanded
  // so the moved file is visible. A name clash at the destination is refused.
  const moveInto = async (src: string, destDir: string): Promise<void> => {
    const target = destDir ? `${destDir}/${basename(src)}` : basename(src)
    if (target === src) return // already there
    if (await props.storage.exists(target)) {
      await alertDialog({ title: 'Name taken', message: `${target} already exists.` })
      return
    }
    await props.storage.write(target, await props.storage.read(src))
    await props.storage.remove(src)
    if (destDir) expanded.add(destDir)
    props.onMutate()
    if (props.currentPath === src) props.onOpen(target)
  }

  const list = document.createElement('ul')
  list.className = 'file-tree'
  // Dropping onto the tree background (not a folder row) moves a file to the root.
  list.addEventListener('dragover', (event) => event.preventDefault())
  list.addEventListener('drop', (event) => {
    event.preventDefault()
    const src = event.dataTransfer?.getData('text/plain')
    if (src) void moveInto(src, '')
  })

  // A create edit shows its inline field as the first row.
  if (editing && editing.kind !== 'rename') {
    const meta = CREATE_META[editing.kind]
    const row = document.createElement('li')
    row.className = 'tree-row tree-edit-row'
    const glyph = document.createElement('span')
    glyph.className = 'tree-edit-glyph'
    glyph.textContent = meta.glyph
    const input = editInput(
      '',
      meta.hint,
      (value, el, fromBlur) => void commitCreate(editing.kind, value, el, fromBlur),
      cancelEdit,
    )
    row.append(glyph, input)
    list.append(row)
    activeInput = input
  }

  const renderLevel = (parent: HTMLElement, nodes: TreeNode[]): void => {
    for (const node of nodes) {
      const item = document.createElement('li')
      if (node.type === 'dir') {
        renderDir(item, node)
      } else if (editing?.kind === 'rename' && editing.path === node.path) {
        const input = editInput(
          node.path,
          '',
          (value, el, fromBlur) => void commitRename(node.path, value, el, fromBlur),
          cancelEdit,
        )
        const wrap = document.createElement('div')
        wrap.className = 'tree-row tree-edit-row'
        wrap.append(input)
        item.append(wrap)
        activeInput = input
      } else {
        renderFile(item, node)
      }
      parent.append(item)
    }
  }

  const renderDir = (item: HTMLElement, node: TreeNode): void => {
    const isOpen = expanded.has(node.path)
    const row = document.createElement('button')
    row.type = 'button'
    row.className = 'tree-row tree-dir'
    row.textContent = `${isOpen ? '▾' : '▸'} ${basename(node.path)}`
    row.addEventListener('click', () => {
      if (isOpen) expanded.delete(node.path)
      else expanded.add(node.path)
      repaint()
    })

    // A folder is a drop target: dropping a dragged file moves it inside.
    const highlight = (on: boolean): void => {
      row.style.background = on ? 'color-mix(in srgb, var(--accent) 22%, transparent)' : ''
    }
    row.addEventListener('dragover', (event) => {
      event.preventDefault()
      if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
      highlight(true)
    })
    row.addEventListener('dragleave', () => highlight(false))
    row.addEventListener('drop', (event) => {
      event.preventDefault()
      event.stopPropagation() // don't also trigger the root (move-to-root) handler
      highlight(false)
      const src = event.dataTransfer?.getData('text/plain')
      if (src) void moveInto(src, node.path)
    })
    item.append(row)
    if (isOpen) {
      const sub = document.createElement('ul')
      sub.className = 'file-tree'
      renderLevel(sub, node.children)
      item.append(sub)
    }
  }

  const renderFile = (item: HTMLElement, node: TreeNode): void => {
    const row = document.createElement('div')
    row.className = 'tree-row tree-file'
    if (node.path === props.currentPath) row.classList.add('is-current')

    // Draggable into folders (drop targets are dir rows / the tree root).
    row.draggable = true
    row.addEventListener('dragstart', (event) => {
      event.dataTransfer?.setData('text/plain', node.path)
      if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move'
    })

    const open = document.createElement('button')
    open.type = 'button'
    open.className = 'tree-name'
    open.textContent = basename(node.path)
    if (isDocPath(node.path)) {
      open.title = node.path
      open.addEventListener('click', () => props.onOpen(node.path))
    } else {
      open.disabled = true // assets are listed but not editable here
      open.title = `${node.path} (asset)`
    }

    const rename = iconButton('Rename', '✎', () => beginEdit({ kind: 'rename', path: node.path }))
    const del = iconButton('Delete', '×', () => void deleteFile(node.path, props))
    row.append(open, rename, del)
    item.append(row)
  }

  renderLevel(list, tree)
  host.append(list)

  if (activeInput) {
    activeInput.focus()
    if (activeInput.value) activeInput.select()
  }
}

async function buildTree(storage: StoragePort, dir: string): Promise<TreeNode[]> {
  const entries = await storage.list(dir)
  return Promise.all(
    entries
      .filter((entry) => entry.path !== '.git')
      .map(async (entry): Promise<TreeNode> => ({
        ...entry,
        children: entry.type === 'dir' ? await buildTree(storage, entry.path) : [],
      })),
  )
}

/**
 * An inline naming field. Enter commits, Escape cancels, blur commits a non-empty
 * value (or cancels). `onCommit(value, input, fromBlur)` owns validation and may
 * keep the field open (e.g. on a name clash); `onCancel` discards the edit.
 */
function editInput(
  initialValue: string,
  placeholder: string,
  onCommit: (value: string, input: HTMLInputElement, fromBlur: boolean) => void,
  onCancel: () => void,
): HTMLInputElement {
  const input = document.createElement('input')
  input.type = 'text'
  input.className = 'tree-edit-input'
  input.value = initialValue
  input.placeholder = placeholder
  input.autocomplete = 'off'
  input.spellcheck = false
  input.style.cssText =
    'flex:1;min-width:0;box-sizing:border-box;border:1px solid var(--accent);border-radius:5px;' +
    'background:var(--bg);color:var(--ink);font:inherit;font-size:.78rem;padding:.12rem .35rem'
  input.addEventListener('input', () => {
    input.style.borderColor = 'var(--accent)'
  })
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault()
      onCommit(input.value, input, false)
    } else if (event.key === 'Escape') {
      event.preventDefault()
      onCancel()
    }
  })
  input.addEventListener('blur', () => onCommit(input.value, input, true))
  return input
}

function iconButton(title: string, glyph: string, onClick: () => void): HTMLButtonElement {
  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'tree-action'
  button.title = title
  button.setAttribute('aria-label', title)
  button.textContent = glyph
  button.addEventListener('click', onClick)
  return button
}

/** A compact title-bar action button (styled by `.side-title button`). */
function titleAction(title: string, glyph: string, onClick: () => void): HTMLButtonElement {
  const button = document.createElement('button')
  button.type = 'button'
  button.title = title
  button.setAttribute('aria-label', title)
  button.textContent = glyph
  button.addEventListener('click', onClick)
  return button
}

/** Upload one or more files from disk into the working-copy root (binary-safe). */
function uploadFiles(props: FileTreeProps): void {
  const input = document.createElement('input')
  input.type = 'file'
  input.multiple = true
  input.addEventListener('change', () => {
    void (async () => {
      const files = Array.from(input.files ?? [])
      let wrote = 0
      for (const file of files) {
        const path = file.name
        if (await props.storage.exists(path)) {
          await alertDialog({ title: 'Name taken', message: `${path} already exists; skipped.` })
          continue
        }
        await props.storage.write(path, new Uint8Array(await file.arrayBuffer()))
        wrote += 1
      }
      if (wrote > 0) props.onMutate()
    })()
  })
  input.click()
}

async function deleteFile(path: string, props: FileTreeProps): Promise<void> {
  const ok = await confirmDialog({
    title: 'Delete file',
    message: `Delete ${path}?\nHistory keeps committed versions.`,
    confirmLabel: 'Delete',
    danger: true,
  })
  if (!ok) return
  await props.storage.remove(path)
  props.onMutate()
}

function basename(path: string): string {
  return path.split('/').pop() ?? path
}
