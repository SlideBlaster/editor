/**
 * Projects landing page. Contract: see home.md.
 *
 * The single entry surface: a list of projects (each a repo / working copy) with
 * open, create, and delete. Platform-agnostic DOM — the shell owns persistence
 * (the project registry) and working-copy creation, passed in as callbacks, so
 * this view is shared by both shells. Opening a project hands off to `createApp`.
 */
import type { Project } from './projects'
import { confirmDialog } from './dialog'
import './app.css'
import './home.css'

export interface HomeDeps {
  projects: Project[]
  /** Open a project into the editor. */
  onOpen(id: string): void
  /** Create a new empty local project with this name, then open it. */
  onCreate(name: string): void
  /** Forget a project (working-copy dir is left in place). */
  onDelete(id: string): void
}

export function renderHome(root: HTMLElement, deps: HomeDeps): void {
  root.replaceChildren(buildHome(deps))
}

function buildHome(deps: HomeDeps): HTMLElement {
  const page = el('div', 'home')
  const shell = el('div', 'home-shell')

  const header = el('header', 'home-header')
  const brand = el('div', 'home-brand')
  brand.textContent = 'SlideBlaster'
  const tagline = el('p', 'home-tagline')
  tagline.textContent = 'Your projects — each one a git repo of presentations and files.'
  header.append(brand, tagline)

  shell.append(header, buildCreate(deps), buildList(deps))
  page.append(shell)
  return page
}

/** The "new project" row: a name field + Create; Enter submits. */
function buildCreate(deps: HomeDeps): HTMLElement {
  const form = el('form', 'home-create')
  const input = document.createElement('input')
  input.type = 'text'
  input.placeholder = 'New project name'
  input.className = 'home-create-input'
  input.autocomplete = 'off'
  input.setAttribute('aria-label', 'New project name')
  const create = document.createElement('button')
  create.type = 'submit'
  create.className = 'home-create-button'
  create.textContent = 'New project'
  form.addEventListener('submit', (event) => {
    event.preventDefault()
    deps.onCreate(input.value.trim())
    input.value = ''
  })
  form.append(input, create)
  return form
}

function buildList(deps: HomeDeps): HTMLElement {
  if (deps.projects.length === 0) {
    const empty = el('div', 'home-empty')
    empty.textContent = 'No projects yet. Name one above to get started.'
    return empty
  }
  const list = el('ul', 'home-list')
  for (const project of deps.projects) list.append(buildCard(project, deps))
  return list
}

function buildCard(project: Project, deps: HomeDeps): HTMLElement {
  const item = document.createElement('li')
  item.className = 'home-card'

  const open = document.createElement('button')
  open.type = 'button'
  open.className = 'home-card-open'
  open.addEventListener('click', () => deps.onOpen(project.id))

  const name = el('span', 'home-card-name')
  name.textContent = project.name
  const meta = el('span', 'home-card-meta')
  meta.textContent = `Opened ${relativeTime(project.lastOpenedAt)}`
  open.append(name, meta)

  const remove = document.createElement('button')
  remove.type = 'button'
  remove.className = 'home-card-delete'
  remove.textContent = 'Delete'
  remove.title = `Delete ${project.name}`
  remove.addEventListener('click', async () => {
    const ok = await confirmDialog({
      title: 'Delete project',
      message: `Delete "${project.name}"?\nThis removes it from your list.`,
      confirmLabel: 'Delete',
      danger: true,
    })
    if (ok) deps.onDelete(project.id)
  })

  item.append(open, remove)
  return item
}

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className: string,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag)
  node.className = className
  return node
}

/** Coarse "x ago" without a date library; good enough for a project list. */
function relativeTime(epochMs: number): string {
  const seconds = Math.round((Date.now() - epochMs) / 1000)
  if (seconds < 60) return 'just now'
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.round(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.round(hours / 24)
  if (days < 30) return `${days}d ago`
  return new Date(epochMs).toLocaleDateString()
}
