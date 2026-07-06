/**
 * Modal dialogs: promise-based replacements for window.confirm/prompt/alert.
 * Contract: see dialog.md. A single native <dialog> mounted in the top layer and
 * themed with the app's design tokens (app.css). Submitting (or Enter) confirms;
 * Escape, a backdrop click, or Cancel dismiss. Only one dialog exists at a time.
 */

export interface ConfirmOptions {
  title?: string
  message: string
  confirmLabel?: string
  cancelLabel?: string
  /** Style the confirm button as destructive (red). */
  danger?: boolean
}

export interface PromptOptions {
  title?: string
  message?: string
  /** Caption above the input. */
  label?: string
  initialValue?: string
  placeholder?: string
  confirmLabel?: string
  cancelLabel?: string
}

export interface AlertOptions {
  title?: string
  message: string
  confirmLabel?: string
}

/** Ask the user to confirm; resolves true if they confirm, false if they dismiss. */
export function confirmDialog(options: ConfirmOptions): Promise<boolean> {
  return openDialog({
    title: options.title,
    message: options.message,
    confirmLabel: options.confirmLabel ?? 'OK',
    cancelLabel: options.cancelLabel ?? 'Cancel',
    danger: options.danger,
  }).then((result) => result.confirmed)
}

/** Ask for a line of text; resolves the entered value, or null if dismissed. */
export function promptDialog(options: PromptOptions): Promise<string | null> {
  return openDialog({
    title: options.title,
    message: options.message,
    field: {
      label: options.label,
      initialValue: options.initialValue,
      placeholder: options.placeholder,
    },
    confirmLabel: options.confirmLabel ?? 'OK',
    cancelLabel: options.cancelLabel ?? 'Cancel',
  }).then((result) => (result.confirmed ? result.value : null))
}

/** Show a message with a single acknowledge button; resolves when dismissed. */
export function alertDialog(options: AlertOptions): Promise<void> {
  return openDialog({
    title: options.title,
    message: options.message,
    confirmLabel: options.confirmLabel ?? 'OK',
  }).then(() => undefined)
}

interface DialogConfig {
  title?: string
  message?: string
  /** When present, a text input is shown and its value is returned. */
  field?: { label?: string; initialValue?: string; placeholder?: string }
  confirmLabel: string
  /** When omitted (alert), no cancel button is rendered. */
  cancelLabel?: string
  danger?: boolean
}

interface DialogResult {
  confirmed: boolean
  value: string
}

let current: HTMLDialogElement | null = null

function openDialog(config: DialogConfig): Promise<DialogResult> {
  current?.close() // never two at once; the outgoing one settles as a dismissal

  return new Promise((resolve) => {
    const dialog = document.createElement('dialog')
    dialog.className = 'sb-dialog'
    current = dialog

    // A form with method="dialog" gives Enter-to-submit and closes without navigating.
    const form = document.createElement('form')
    form.method = 'dialog'
    form.className = 'sb-dialog-form'

    if (config.title) {
      const title = document.createElement('h2')
      title.className = 'sb-dialog-title'
      title.textContent = config.title
      form.append(title)
    }
    if (config.message) {
      const message = document.createElement('p')
      message.className = 'sb-dialog-message'
      message.textContent = config.message
      form.append(message)
    }

    let input: HTMLInputElement | null = null
    if (config.field) {
      const field = document.createElement('label')
      field.className = 'sb-dialog-field'
      if (config.field.label) {
        const caption = document.createElement('span')
        caption.className = 'sb-dialog-field-label'
        caption.textContent = config.field.label
        field.append(caption)
      }
      input = document.createElement('input')
      input.type = 'text'
      input.className = 'sb-dialog-input'
      input.value = config.field.initialValue ?? ''
      if (config.field.placeholder) input.placeholder = config.field.placeholder
      input.autocomplete = 'off'
      input.spellcheck = false
      field.append(input)
      form.append(field)
    }

    const actions = document.createElement('div')
    actions.className = 'sb-dialog-actions'

    if (config.cancelLabel) {
      const cancel = document.createElement('button')
      cancel.type = 'button'
      cancel.className = 'sb-dialog-button sb-dialog-cancel'
      cancel.textContent = config.cancelLabel
      cancel.addEventListener('click', () => dialog.close())
      actions.append(cancel)
    }

    const confirm = document.createElement('button')
    confirm.type = 'submit'
    confirm.className = config.danger
      ? 'sb-dialog-button sb-dialog-confirm is-danger'
      : 'sb-dialog-button sb-dialog-confirm'
    confirm.textContent = config.confirmLabel
    actions.append(confirm)

    form.append(actions)
    dialog.append(form)
    document.body.append(dialog)

    // Outcome, defaulting to dismissal — covers Escape, backdrop, and Cancel.
    let confirmed = false
    form.addEventListener('submit', () => {
      confirmed = true
    })

    // A click that lands on the <dialog> itself (not the form) is a backdrop click.
    dialog.addEventListener('click', (event) => {
      if (event.target === dialog) dialog.close()
    })

    // Single settle point for every close path (submit, Escape, backdrop, .close()).
    dialog.addEventListener('close', () => {
      const value = input?.value ?? ''
      dialog.remove()
      if (current === dialog) current = null
      resolve({ confirmed, value })
    })

    dialog.showModal()
    if (input) {
      input.focus()
      input.select()
    } else {
      confirm.focus()
    }
  })
}
