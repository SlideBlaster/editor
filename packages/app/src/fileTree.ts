/**
 * The file tree panel. Contract: see fileTree.md.
 *
 * A recursive view of the working copy (`.git` hidden): directories expand and
 * collapse, documents open in the editor, files are created, renamed, moved, and
 * deleted through the Storage port. Naming — new deck/file/folder and rename —
 * happens **inline** (a text field in the tree), never a popup. Selecting a
 * folder makes it the target for new items; files and folders drag to move.
 * Repainted whole on every change; expansion, selection, and the in-progress
 * inline edit survive repaints.
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
  /** A storage mutation happened (create/rename/move/delete): refresh dependent views. */
  onMutate(): void
}

interface TreeNode extends FileEntry {
  children: TreeNode[]
}

/** An in-progress inline edit. `rename` carries the path being renamed. */
type EditState = { kind: 'new-deck' | 'new-file' | 'new-folder' } | { kind: 'rename'; path: string }

/** A drag payload: which path is moving, and whether it is a file or a folder. */
interface DragPayload {
  path: string
  kind: 'file' | 'dir'
}

// Per-host state that survives the whole-tree repaint.
const expandedByHost = new WeakMap<HTMLElement, Set<string>>()
const editingByHost = new WeakMap<HTMLElement, EditState | null>()
const selectedByHost = new WeakMap<HTMLElement, string>() // active dir for new items ('' = root)

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

const SELECTED_BG = 'color-mix(in srgb, var(--accent) 14%, transparent)'
const DROP_BG = 'color-mix(in srgb, var(--accent) 28%, transparent)'

export async function paintFileTree(host: HTMLElement, props: FileTreeProps): Promise<void> {
  const expanded = expandedByHost.get(host) ?? new Set<string>()
  expandedByHost.set(host, expanded)
  const editing = editingByHost.get(host) ?? null

  const tree = await buildTree(props.storage, '')

  // The "active" folder — new items are created here. Drop it if it no longer
  // exists (deleted/moved), so it never dangles across repaints.
  const dirPaths = new Set<string>()
  const collectDirs = (nodes: TreeNode[]): void => {
    for (const node of nodes)
      if (node.type === 'dir') {
        dirPaths.add(node.path)
        collectDirs(node.children)
      }
  }
  collectDirs(tree)
  let selectedDir = selectedByHost.get(host) ?? ''
  if (selectedDir && !dirPaths.has(selectedDir)) selectedDir = ''
  selectedByHost.set(host, selectedDir)

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
  const setSelected = (dir: string): void => {
    selectedDir = dir
    selectedByHost.set(host, dir)
  }
  const markInvalid = (input: HTMLInputElement): void => {
    input.style.borderColor = 'var(--danger)'
    input.focus()
  }
  const expandChain = (dir: string): void => {
    let acc = ''
    for (const seg of dir.split('/').filter(Boolean)) {
      acc = acc ? `${acc}/${seg}` : seg
      expanded.add(acc)
    }
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
    titleAction('Upload file', '⬆', () => uploadFiles(props, selectedDir)),
  )
  head.append(label, actions)
  host.append(head)

  // Create a file / deck / folder from the inline name, inside the active folder
  // (a leading "/" overrides to the root). Guarded by the editing state so a stray
  // blur after a successful write (repaint detaches the input) is a no-op. On
  // clash: keep editing and mark the field, unless a blur is taking focus away —
  // then just cancel so the user is never trapped.
  const commitCreate = async (
    kind: 'new-deck' | 'new-file' | 'new-folder',
    raw: string,
    input: HTMLInputElement,
    fromBlur: boolean,
  ): Promise<void> => {
    if (!editingByHost.get(host)) return
    const value = raw.trim()
    if (!value) return cancelEdit()
    const rel = value.startsWith('/')
      ? value.slice(1)
      : selectedDir
        ? `${selectedDir}/${value}`
        : value

    if (kind === 'new-folder') {
      const dir = rel.replace(/\/+$/, '')
      const keep = `${dir}/.gitkeep` // git does not track empty dirs
      if (await props.storage.exists(keep)) return fromBlur ? cancelEdit() : markInvalid(input)
      await props.storage.write(keep, '')
      editingByHost.set(host, null)
      expandChain(dir)
      setSelected(dir) // subsequent new items land in the folder just made
      props.onMutate()
      return
    }

    const path = kind === 'new-deck' && !rel.endsWith(DOC_EXTENSION) ? rel + DOC_EXTENSION : rel
    if (await props.storage.exists(path)) return fromBlur ? cancelEdit() : markInvalid(input)
    await props.storage.write(path, kind === 'new-deck' ? NEW_DOC_TEMPLATE : '')
    editingByHost.set(host, null)
    expandChain(dirname(path))
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

  // Move a file into a folder (or onto the tree background = root). A move is
  // copy+delete (the Storage port has no move); a name clash is refused.
  const moveFile = async (src: string, destDir: string): Promise<void> => {
    const target = destDir ? `${destDir}/${basename(src)}` : basename(src)
    if (target === src) return // already there
    if (await props.storage.exists(target)) {
      await alertDialog({ title: 'Name taken', message: `${target} already exists.` })
      return
    }
    await props.storage.write(target, await props.storage.read(src))
    await props.storage.remove(src)
    if (destDir) expandChain(destDir)
    props.onMutate()
    if (props.currentPath === src) props.onOpen(target)
  }

  // Move a whole folder (all its files) into another folder or the root, refusing
  // a move into itself/a descendant or onto a colliding path.
  const moveFolder = async (srcDir: string, destDir: string): Promise<void> => {
    const newRoot = destDir ? `${destDir}/${basename(srcDir)}` : basename(srcDir)
    if (newRoot === srcDir) return // already there
    if (newRoot.startsWith(`${srcDir}/`)) {
      await alertDialog({ title: 'Invalid move', message: 'A folder cannot move into itself.' })
      return
    }
    const files = await listFilesUnder(props.storage, srcDir)
    for (const file of files) {
      const rel = file.slice(srcDir.length + 1)
      if (await props.storage.exists(`${newRoot}/${rel}`)) {
        await alertDialog({ title: 'Name taken', message: `${newRoot}/${rel} already exists.` })
        return
      }
    }
    for (const file of files) {
      const rel = file.slice(srcDir.length + 1)
      await props.storage.write(`${newRoot}/${rel}`, await props.storage.read(file))
    }
    // Remove the whole source subtree (files + the now-empty dirs), so no empty
    // shell is left behind — `storage.remove` recurses and rmdirs.
    await props.storage.remove(srcDir)
    expandChain(newRoot)
    if (selectedDir === srcDir || selectedDir.startsWith(`${srcDir}/`)) {
      setSelected(newRoot + selectedDir.slice(srcDir.length))
    }
    const open = props.currentPath
    props.onMutate()
    if (open && open.startsWith(`${srcDir}/`))
      props.onOpen(`${newRoot}${open.slice(srcDir.length)}`)
  }

  const applyDrop = (raw: string | undefined, destDir: string): void => {
    if (!raw) return
    let payload: DragPayload
    try {
      payload = JSON.parse(raw) as DragPayload
    } catch {
      return
    }
    if (payload.kind === 'dir') void moveFolder(payload.path, destDir)
    else void moveFile(payload.path, destDir)
  }

  const list = document.createElement('ul')
  list.className = 'file-tree'
  // Dropping onto the tree background (not a row) moves the item to the root; a
  // click on the background clears the active folder back to the root.
  list.addEventListener('dragover', (event) => event.preventDefault())
  list.addEventListener('drop', (event) => {
    event.preventDefault()
    applyDrop(event.dataTransfer?.getData('text/plain'), '')
  })
  list.addEventListener('click', (event) => {
    if (event.target === list && selectedDir !== '') {
      setSelected('')
      repaint()
    }
  })

  // A create edit shows its inline field as the first row, prefixed with the
  // active folder so it is clear where the new item lands.
  if (editing && editing.kind !== 'rename') {
    const meta = CREATE_META[editing.kind]
    const row = document.createElement('li')
    row.className = 'tree-row tree-edit-row'
    const glyph = document.createElement('span')
    glyph.className = 'tree-edit-glyph'
    glyph.textContent = meta.glyph
    row.append(glyph)
    if (selectedDir) {
      const prefix = document.createElement('span')
      prefix.textContent = `${selectedDir}/`
      prefix.style.cssText = 'color:var(--muted);white-space:nowrap'
      row.append(prefix)
    }
    const input = editInput(
      '',
      meta.hint,
      (value, el, fromBlur) => void commitCreate(editing.kind, value, el, fromBlur),
      cancelEdit,
    )
    row.append(input)
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
    const isSelected = node.path === selectedDir
    const row = document.createElement('button')
    row.type = 'button'
    row.className = 'tree-row tree-dir'
    row.textContent = `${isOpen ? '▾' : '▸'} ${basename(node.path)}`
    if (isSelected) {
      row.style.background = SELECTED_BG
      row.style.color = 'var(--accent)'
    }
    // Click selects the folder (new items target it) and toggles expansion.
    row.addEventListener('click', () => {
      setSelected(node.path)
      if (isOpen) expanded.delete(node.path)
      else expanded.add(node.path)
      repaint()
    })

    // A folder both drags (to move its subtree) and accepts drops (into itself).
    row.draggable = true
    row.addEventListener('dragstart', (event) => {
      event.stopPropagation()
      event.dataTransfer?.setData('text/plain', payload(node.path, 'dir'))
      if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move'
    })
    const highlight = (on: boolean): void => {
      row.style.background = on ? DROP_BG : isSelected ? SELECTED_BG : ''
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
      applyDrop(event.dataTransfer?.getData('text/plain'), node.path)
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
      event.dataTransfer?.setData('text/plain', payload(node.path, 'file'))
      if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move'
    })

    const open = document.createElement('button')
    open.type = 'button'
    open.className = 'tree-name'
    open.textContent = basename(node.path)
    if (isDocPath(node.path)) {
      open.title = node.path
      // Opening a doc makes its folder the active target for new items.
      open.addEventListener('click', () => {
        setSelected(dirname(node.path))
        props.onOpen(node.path)
      })
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

/** Every file path under `dir`, recursively (dirs are implicit in the paths). */
async function listFilesUnder(storage: StoragePort, dir: string): Promise<string[]> {
  const out: string[] = []
  const walk = async (current: string): Promise<void> => {
    for (const entry of await storage.list(current)) {
      if (entry.path === '.git') continue
      if (entry.type === 'dir') await walk(entry.path)
      else out.push(entry.path)
    }
  }
  await walk(dir)
  return out
}

function payload(path: string, kind: 'file' | 'dir'): string {
  return JSON.stringify({ path, kind } satisfies DragPayload)
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

/** Upload files from disk into the active folder (root if none), binary-safe. */
function uploadFiles(props: FileTreeProps, destDir: string): void {
  const input = document.createElement('input')
  input.type = 'file'
  input.multiple = true
  input.addEventListener('change', () => {
    void (async () => {
      const files = Array.from(input.files ?? [])
      let wrote = 0
      for (const file of files) {
        const path = destDir ? `${destDir}/${file.name}` : file.name
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

function dirname(path: string): string {
  const i = path.lastIndexOf('/')
  return i === -1 ? '' : path.slice(0, i)
}
