/**
 * The source code pane. Contract: see codePane.md.
 *
 * A swappable widget behind a tiny interface (get/set value + onChange). W2 backs
 * it with a plain <textarea> so the reactive round-trip lands with zero deps and
 * zero risk; a Monaco editor (roadmap workstream 2) drops in later without touching
 * the controller, since the seam is just "source string in, source string out".
 */
export interface CodePane {
  getValue(): string
  setValue(value: string): void
}

export function createCodePane(
  host: HTMLElement,
  opts: { value: string; onChange: (value: string) => void },
): CodePane {
  const textarea = document.createElement('textarea')
  textarea.className = 'code-input'
  textarea.spellcheck = false
  textarea.wrap = 'off'
  textarea.value = opts.value
  textarea.addEventListener('input', () => opts.onChange(textarea.value))
  host.append(textarea)

  return {
    getValue: () => textarea.value,
    setValue: (value: string) => {
      textarea.value = value
    },
  }
}
