/**
 * The creation menu: a cursor-anchored popover for adding an element. Contract: see
 * createMenu.md. A single, self-contained overlay — summoned at a client point with a
 * catalogue, a type-to-filter input, and keyboard navigation. Picking an item fires
 * `onPick(id)`; Escape / an outside click fires `onDismiss()` and leaves no trace
 * (ux/creation-menu.md). Only one menu exists at a time.
 */
export interface MenuItem {
  id: string
  label: string
  hint?: string
}

export interface CreationMenuOptions {
  items: MenuItem[]
  onPick(id: string): void
  onDismiss(): void
}

let openMenu: (() => void) | null = null

export function closeCreationMenu(): void {
  openMenu?.()
}

export function openCreationMenu(
  clientX: number,
  clientY: number,
  options: CreationMenuOptions,
): void {
  closeCreationMenu() // never two at once

  const root = document.createElement('div')
  root.className = 'sb-create-menu'
  const input = document.createElement('input')
  input.className = 'sb-create-filter'
  input.type = 'text'
  input.placeholder = 'Add element…'
  input.spellcheck = false
  const list = document.createElement('ul')
  list.className = 'sb-create-list'
  root.append(input, list)
  document.body.append(root)

  // Position at the cursor, nudged back inside the viewport if it would overflow.
  root.style.left = `${clientX}px`
  root.style.top = `${clientY}px`
  const rect = root.getBoundingClientRect()
  if (rect.right > innerWidth) root.style.left = `${Math.max(4, clientX - rect.width)}px`
  if (rect.bottom > innerHeight) root.style.top = `${Math.max(4, clientY - rect.height)}px`

  let filter = ''
  let active = 0
  let settled = false

  const visible = (): MenuItem[] => {
    const q = filter.trim().toLowerCase()
    return q === ''
      ? options.items
      : options.items.filter((item) => item.label.toLowerCase().includes(q))
  }

  const close = (): void => {
    if (settled) return
    settled = true
    document.removeEventListener('pointerdown', onOutside, true)
    root.remove()
    if (openMenu === close) openMenu = null
  }

  const dismiss = (): void => {
    close()
    options.onDismiss()
  }

  const pick = (id: string): void => {
    close()
    options.onPick(id)
  }

  const renderList = (): void => {
    const items = visible()
    if (active >= items.length) active = Math.max(0, items.length - 1)
    list.replaceChildren()
    items.forEach((item, i) => {
      const li = document.createElement('li')
      li.className = i === active ? 'sb-create-item is-active' : 'sb-create-item'
      li.innerHTML = `<span class="sb-create-label"></span>`
      li.querySelector('.sb-create-label')!.textContent = item.label
      if (item.hint) {
        const hint = document.createElement('span')
        hint.className = 'sb-create-hint'
        hint.textContent = item.hint
        li.append(hint)
      }
      li.addEventListener('pointerdown', (event) => {
        event.preventDefault() // keep focus; commit the pick
        pick(item.id)
      })
      li.addEventListener('pointermove', () => {
        if (active !== i) {
          active = i
          renderList()
        }
      })
      list.append(li)
    })
  }

  const onOutside = (event: PointerEvent): void => {
    if (!root.contains(event.target as Node)) dismiss()
  }

  input.addEventListener('input', () => {
    filter = input.value
    active = 0
    renderList()
  })
  input.addEventListener('keydown', (event) => {
    const items = visible()
    if (event.key === 'Escape') {
      event.preventDefault()
      dismiss()
    } else if (event.key === 'Enter') {
      event.preventDefault()
      const chosen = items[active]
      if (chosen) pick(chosen.id)
    } else if (event.key === 'ArrowDown') {
      event.preventDefault()
      active = Math.min(active + 1, items.length - 1)
      renderList()
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      active = Math.max(active - 1, 0)
      renderList()
    }
  })

  document.addEventListener('pointerdown', onOutside, true)
  openMenu = close
  renderList()
  input.focus()
}
