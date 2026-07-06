/**
 * The file tree panel. Contract: see fileTree.md.
 *
 * A recursive view of the working copy (`.git` hidden): directories expand and
 * collapse, documents open in the editor, files can be created, renamed, and
 * deleted through the Storage port. Repainted whole on every change; expansion
 * state survives repaints.
 */
import type { FileEntry, StoragePort } from '@slideblaster/editor'
import { DOC_EXTENSION, isDocPath } from './workspace'
import { alertDialog, confirmDialog, promptDialog } from './dialog'

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

// Expanded-directory state per host element, surviving repaints.
const expandedByHost = new WeakMap<HTMLElement, Set<string>>()

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

export async function paintFileTree(host: HTMLElement, props: FileTreeProps): Promise<void> {
  const expanded = expandedByHost.get(host) ?? new Set<string>()
  expandedByHost.set(host, expanded)

  const tree = await buildTree(props.storage, '')
  host.replaceChildren()

  const head = document.createElement('div')
  head.className = 'side-title'
  const label = document.createElement('span')
  label.textContent = 'Files'

  // Create affordances: a deck (a presentation), any file, a folder, or an upload.
  // Grouped so they sit at the right of the title; each inherits `.side-title button`.
  const actions = document.createElement('div')
  actions.style.cssText = 'display:flex;gap:.25rem;flex-wrap:wrap;justify-content:flex-end'
  actions.append(
    titleAction('New deck', '▤', () => void createDoc(props)),
    titleAction('New file', '＋', () => void createFile(props)),
    titleAction('New folder', '🗀', () => void createFolder(props)),
    titleAction('Upload file', '⬆', () => uploadFiles(props)),
  )
  head.append(label, actions)
  host.append(head)

  const list = document.createElement('ul')
  list.className = 'file-tree'
  paintLevel(list, tree, props, expanded)
  host.append(list)
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

function paintLevel(
  list: HTMLElement,
  nodes: TreeNode[],
  props: FileTreeProps,
  expanded: Set<string>,
): void {
  for (const node of nodes) {
    const item = document.createElement('li')
    if (node.type === 'dir') paintDir(item, node, props, expanded)
    else paintFile(item, node, props)
    list.append(item)
  }
}

function paintDir(
  item: HTMLElement,
  node: TreeNode,
  props: FileTreeProps,
  expanded: Set<string>,
): void {
  const isOpen = expanded.has(node.path)
  const row = document.createElement('button')
  row.type = 'button'
  row.className = 'tree-row tree-dir'
  row.textContent = `${isOpen ? '▾' : '▸'} ${basename(node.path)}`
  row.addEventListener('click', () => {
    if (isOpen) expanded.delete(node.path)
    else expanded.add(node.path)
    props.onMutate() // repaint via the controller so every view stays consistent
  })
  item.append(row)
  if (isOpen) {
    const sub = document.createElement('ul')
    sub.className = 'file-tree'
    paintLevel(sub, node.children, props, expanded)
    item.append(sub)
  }
}

function paintFile(item: HTMLElement, node: TreeNode, props: FileTreeProps): void {
  const row = document.createElement('div')
  row.className = 'tree-row tree-file'
  if (node.path === props.currentPath) row.classList.add('is-current')

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

  const rename = iconButton('Rename', '✎', () => void renameFile(node.path, props))
  const del = iconButton('Delete', '×', () => void deleteFile(node.path, props))
  row.append(open, rename, del)
  item.append(row)
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

async function createDoc(props: FileTreeProps): Promise<void> {
  const name = await promptDialog({
    title: 'New deck',
    message: 'Subfolders are allowed, e.g. talks/demo.',
    label: 'Deck name',
    placeholder: 'talks/demo',
    confirmLabel: 'Create',
  })
  if (!name) return
  const path = name.endsWith(DOC_EXTENSION) ? name : `${name}${DOC_EXTENSION}`
  if (await props.storage.exists(path)) {
    await alertDialog({ title: 'Name taken', message: `${path} already exists.` })
    return
  }
  await props.storage.write(path, NEW_DOC_TEMPLATE)
  props.onMutate()
  props.onOpen(path)
}

/** Create an empty file at an arbitrary path (subfolders auto-created on write). */
async function createFile(props: FileTreeProps): Promise<void> {
  const path = (
    await promptDialog({
      title: 'New file',
      message: 'Subfolders are allowed, e.g. assets/notes.md.',
      label: 'File path',
      placeholder: 'notes.md',
      confirmLabel: 'Create',
    })
  )?.trim()
  if (!path) return
  if (await props.storage.exists(path)) {
    await alertDialog({ title: 'Name taken', message: `${path} already exists.` })
    return
  }
  await props.storage.write(path, '')
  props.onMutate()
  // A newly created deck opens straight away; other files just appear in the tree.
  if (isDocPath(path)) props.onOpen(path)
}

/** Create a folder by seeding a `.gitkeep` (git does not track empty dirs). */
async function createFolder(props: FileTreeProps): Promise<void> {
  const raw = (
    await promptDialog({
      title: 'New folder',
      message: 'Nested folders are allowed, e.g. talks/2026.',
      label: 'Folder path',
      placeholder: 'assets',
      confirmLabel: 'Create',
    })
  )?.trim()
  if (!raw) return
  const dir = raw.replace(/\/+$/, '')
  const keep = `${dir}/.gitkeep`
  if (await props.storage.exists(keep)) {
    await alertDialog({ title: 'Folder exists', message: `${dir} already exists.` })
    return
  }
  await props.storage.write(keep, '')
  props.onMutate()
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

async function renameFile(path: string, props: FileTreeProps): Promise<void> {
  const next = await promptDialog({
    title: 'Rename',
    label: 'New path',
    initialValue: path,
    confirmLabel: 'Rename',
  })
  if (!next || next === path) return
  const target = isDocPath(path) && !next.endsWith(DOC_EXTENSION) ? `${next}${DOC_EXTENSION}` : next
  if (await props.storage.exists(target)) {
    await alertDialog({ title: 'Name taken', message: `${target} already exists.` })
    return
  }
  // The Storage port has no rename; copy+delete is equivalent for the working copy.
  await props.storage.write(target, await props.storage.read(path))
  await props.storage.remove(path)
  props.onMutate()
  if (props.currentPath === path) props.onOpen(target)
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
