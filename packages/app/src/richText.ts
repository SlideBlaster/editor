/**
 * WYSIWYG editing surface for node content (style-in-place). Contract: see richText.md.
 *
 * Three seams around a rich contenteditable:
 *  - `editableHtml`: NodeContent -> editing DOM. Like the engine render, but stamps the
 *    provenance the render omits (`data-run="latex:textbf|md:**|html:b|…"`), typesets
 *    math as atomic islands carrying their source (`data-tex`), and freezes every
 *    construct the editor can't edit inline as an indexed island (`data-atom`) whose
 *    model run is returned verbatim on read-back.
 *  - `readEditable`: editing DOM -> NodeContent. The inverse walk; tolerant of what a
 *    browser does to a contenteditable (bare <b>/<i>/<strike>, styled spans, <div> line
 *    wrapping, fragmented text nodes, ZWSP caret anchors).
 *  - `wireRichEditing`: the live behaviors — typed `$…$` / `**…**` / `\textbf{` convert
 *    on the fly (via execCommand so native undo stays coherent: Ctrl+Z restores the
 *    literal typed source), `}` exits a live LaTeX style span, Backspace re-opens a
 *    math island as its source (and arms/deletes other islands), paste and drop land
 *    as plain text.
 *
 * Dialect rules (design/format/node-content.md): an existing run keeps its dialect
 * (`data-run` survives execCommand splits — attributes are cloned); anything newly
 * authored by browser commands arrives as bare HTML elements and reads back as
 * html-dialect runs — the documented default dialect for new canvas content.
 */
import {
  inlineStyleOf,
  renderContent,
  serializeRuns,
  type LatexCommand,
  type ListItem,
  type NodeContent,
  type TextRun,
} from '@slideblaster/editor'
import { renderOptions } from './tableCompiler'

/** Zero-width space: the caret anchor Chromium needs at island/element boundaries.
 *  Inserted by the editor, stripped by the reader — never reaches the model. */
export const ZWSP = '\u200B'

const LATEX_COMMANDS = new Set(['textbf', 'emph', 'textit', 'underline'])
const STYLE_ELEMENT = { bold: 'strong', italic: 'em', underline: 'u', strike: 's' } as const
/** Bare elements a browser editing command may produce, and the html-run tag they read
 *  back as (`strike` is Chromium's strikeThrough output; the parser subset wants `s`). */
const BARE_STYLE_TAGS: Record<string, string> = {
  b: 'b',
  strong: 'strong',
  i: 'i',
  em: 'em',
  u: 'u',
  s: 's',
  strike: 's',
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function escapeAttr(s: string): string {
  return escapeHtml(s).replace(/"/g, '&quot;')
}

// ---------------------------------------------------------------------------
// NodeContent -> editable HTML
// ---------------------------------------------------------------------------

/** The provenance tag an editable style element carries (`data-run`). */
function runTag(run: TextRun): string | undefined {
  switch (run.kind) {
    case 'latex':
      return `latex:${run.command}`
    case 'markdown':
      return `md:${run.marker}`
    case 'html':
      return `html:${run.tag}`
    default:
      return undefined
  }
}

/** Rebuild the run a `data-run` provenance tag encodes (children already read). */
function runFromTag(tag: string, children: TextRun[]): TextRun | undefined {
  if (tag.startsWith('latex:')) {
    const command = tag.slice(6)
    if (LATEX_COMMANDS.has(command)) return { kind: 'latex', command: command as LatexCommand, children }
  }
  if (tag === 'md:*' || tag === 'md:**') {
    return { kind: 'markdown', marker: tag.slice(3) as '*' | '**', children }
  }
  if (tag.startsWith('html:')) return { kind: 'html', tag: tag.slice(5), children }
  return undefined
}

/** The element an editable style run renders as (same semantics as the engine render). */
function elementFor(run: TextRun & { kind: 'latex' | 'markdown' | 'html' }): string {
  const style = inlineStyleOf(run)
  if (style) return STYLE_ELEMENT[style]
  return run.kind === 'html' && /^(span|div)$/.test(run.tag) ? run.tag : 'span'
}

/** A math island: atomic, KaTeX-typeset, carrying its own source (KaTeX HTML drops it). */
function mathIslandHtml(source: string, display: boolean, fresh = false): string {
  return (
    `<span class="rt-atom rt-math" contenteditable="false"${fresh ? ' data-rt-new=""' : ''}` +
    ` data-tex="${escapeAttr(source)}" data-display="${display ? '1' : '0'}">` +
    `${renderOptions.renderMath!(source, display)}</span>`
  )
}

/**
 * Editable HTML for a node body. `atoms` collects every run the editor treats as an
 * opaque island (in encounter order); `readEditable` must receive the same array so
 * islands read back as their exact original runs.
 */
export function editableHtml(content: NodeContent, atoms: TextRun[]): string {
  if (content.kind !== 'text') return ''
  return htmlOfRuns(content.runs, atoms)
}

function htmlOfRuns(runs: readonly TextRun[], atoms: TextRun[]): string {
  return runs.map((run) => htmlOfRun(run, atoms)).join('')
}

function htmlOfRun(run: TextRun, atoms: TextRun[]): string {
  switch (run.kind) {
    case 'text':
      return escapeHtml(run.value)
    case 'math':
      return mathIslandHtml(run.source, run.display)
    case 'latex':
    case 'markdown':
    case 'html': {
      const tag = elementFor(run)
      return `<${tag} data-run="${escapeAttr(runTag(run)!)}">${htmlOfRuns(run.children, atoms)}</${tag}>`
    }
    case 'list': {
      const tag = run.ordered ? 'ol' : 'ul'
      const items = run.items
        .map(
          (item) =>
            `<li${item.spec ? ` data-spec="${escapeAttr(item.spec.raw)}"` : ''}>${htmlOfRuns(item.children, atoms)}</li>`,
        )
        .join('')
      return `<${tag} data-run="list:${run.dialect}">${items}</${tag}>`
    }
    default:
      return atomHtml(run, atoms)
  }
}

/** Freeze a construct the editor can't edit inline as an indexed, atomic island. The
 *  rendered preview keeps WYSIWYG (cites as [1], tables as tables); a construct with no
 *  visible render (`\pause`) shows its source as a chip so it can't become a caret trap. */
function atomHtml(run: TextRun, atoms: TextRun[]): string {
  const index = atoms.push(run) - 1
  const preview =
    run.kind === 'fragment'
      ? `<span class="rt-chip">${escapeHtml(serializeRuns([run]))}</span>`
      : renderContent({ kind: 'text', runs: [run] }, renderOptions)
  return `<span class="rt-atom" contenteditable="false" data-atom="${index}">${preview}</span>`
}

// ---------------------------------------------------------------------------
// Editable DOM -> NodeContent
// ---------------------------------------------------------------------------

/** Read the edited DOM back into a NodeContent. Whitespace-only content is `empty`
 *  (the just-created-node discard test). A trailing `<br>` is Chromium's caret
 *  placeholder, not content — the newline it contributed is stripped; a genuine
 *  trailing newline (a seeded text run) survives, so a no-op close stays a no-op. */
export function readEditable(root: HTMLElement, atoms: readonly TextRun[]): NodeContent {
  const runs: TextRun[] = []
  readNodes(root.childNodes, atoms, runs)
  if (root.lastChild instanceof HTMLElement && root.lastChild.tagName === 'BR') {
    trimTrailingNewline(runs)
  }
  const text = runs.length === 1 && runs[0]!.kind === 'text' ? runs[0]!.value : null
  if (runs.length === 0 || (text !== null && text.trim() === '')) return { kind: 'empty' }
  return { kind: 'text', runs }
}

function pushText(out: TextRun[], value: string): void {
  if (value === '') return
  const last = out[out.length - 1]
  if (last?.kind === 'text') out[out.length - 1] = { kind: 'text', value: last.value + value }
  else out.push({ kind: 'text', value })
}

/** Strip caret anchors (ZWSP) and normalize the NBSPs contenteditable inserts. */
function cleanText(value: string): string {
  return value.replace(/\u200B/g, '').replace(/\u00A0/g, ' ')
}

function readNodes(nodes: Iterable<Node>, atoms: readonly TextRun[], out: TextRun[]): void {
  for (const node of nodes) {
    if (node instanceof Text) {
      pushText(out, cleanText(node.data))
      continue
    }
    if (!(node instanceof HTMLElement)) continue
    const tag = node.tagName.toLowerCase()

    if (node.dataset.atom !== undefined) {
      const original = atoms[Number(node.dataset.atom)]
      if (original) out.push(original)
      continue
    }
    if (node.classList.contains('rt-math')) {
      const source = node.dataset.tex ?? ''
      if (source !== '') out.push({ kind: 'math', display: node.dataset.display === '1', source })
      continue
    }
    if (tag === 'br') {
      pushText(out, '\n')
      continue
    }
    if (tag === 'ul' || tag === 'ol') {
      out.push(readList(node, atoms))
      continue
    }
    const provenance = node.dataset.run
    if (provenance !== undefined && !provenance.startsWith('list:')) {
      const children: TextRun[] = []
      readNodes(node.childNodes, atoms, children)
      if (children.length === 0) continue // an emptied style span contributes nothing
      const run = runFromTag(provenance, children)
      if (run) out.push(run)
      else readNodes(node.childNodes, atoms, out) // unknown tag: unwrap
      continue
    }
    if (tag in BARE_STYLE_TAGS) {
      // Browser-authored styling (execCommand / Ctrl+B): html dialect — the documented
      // default for new canvas content.
      const children: TextRun[] = []
      readNodes(node.childNodes, atoms, children)
      if (children.length > 0) out.push({ kind: 'html', tag: BARE_STYLE_TAGS[tag]!, children })
      continue
    }
    if (tag === 'div') {
      // A contenteditable line: Chromium leaves the first line bare and wraps the rest
      // in <div>s; an empty line is <div><br></div> (one newline, not two).
      pushText(out, '\n')
      if (!(node.childNodes.length === 1 && node.firstChild instanceof HTMLElement && node.firstChild.tagName === 'BR')) {
        readNodes(node.childNodes, atoms, out)
      }
      continue
    }
    // Styled spans (execCommand's CSS mode / pasted remnants): positive styles wrap in
    // html runs; negation styles (font-weight:normal on un-bold inside a CSS-bold
    // container) have no model form and unwrap.
    const styled = styleWrapper(node)
    if (styled) {
      const children: TextRun[] = []
      readNodes(node.childNodes, atoms, children)
      if (children.length > 0) out.push(nestStyles(styled, children))
      continue
    }
    readNodes(node.childNodes, atoms, out) // anything else: unwrap (sanitization)
  }
}

/** The html-run tags an element's inline CSS expresses (positive styles only). */
function styleWrapper(el: HTMLElement): string[] | null {
  const tags: string[] = []
  const weight = el.style.fontWeight
  if (weight === 'bold' || weight === 'bolder' || Number(weight) >= 600) tags.push('b')
  if (el.style.fontStyle === 'italic' || el.style.fontStyle === 'oblique') tags.push('i')
  const deco = el.style.textDecoration + ' ' + el.style.textDecorationLine
  if (deco.includes('underline')) tags.push('u')
  if (deco.includes('line-through')) tags.push('s')
  return tags.length > 0 ? tags : null
}

function nestStyles(tags: string[], children: TextRun[]): TextRun {
  let run: TextRun = { kind: 'html', tag: tags[tags.length - 1]!, children }
  for (let i = tags.length - 2; i >= 0; i--) run = { kind: 'html', tag: tags[i]!, children: [run] }
  return run
}

function readList(el: HTMLElement, atoms: readonly TextRun[]): TextRun {
  const provenance = el.dataset.run
  const dialect =
    provenance === 'list:latex' ? 'latex' : provenance === 'list:html' ? 'html' : 'md'
  const items: ListItem[] = []
  for (const li of el.children) {
    if (li.tagName !== 'LI' || !(li instanceof HTMLElement)) continue
    const children: TextRun[] = []
    readNodes(li.childNodes, atoms, children)
    const spec = li.dataset.spec
    items.push(spec ? { children, spec: { raw: spec } } : { children })
  }
  return { kind: 'list', ordered: el.tagName === 'OL', dialect, items }
}

function trimTrailingNewline(runs: TextRun[]): void {
  const last = runs[runs.length - 1]
  if (last?.kind !== 'text' || !last.value.endsWith('\n')) return
  const value = last.value.slice(0, -1)
  if (value === '') runs.pop()
  else runs[runs.length - 1] = { kind: 'text', value }
}

// ---------------------------------------------------------------------------
// Live conversion scanners (pure — unit-tested)
// ---------------------------------------------------------------------------

/** `$…$` / `$$…$$` completed at the end of `upto` (the caret text up to the cursor). */
export function matchMath(
  upto: string,
): { start: number; source: string; display: boolean } | null {
  const display = /(^|[^\\$])\$\$([^$]+)\$\$$/.exec(upto)
  if (display && display[2]!.trim() !== '') {
    return { start: display.index + display[1]!.length, source: display[2]!, display: true }
  }
  const inline = /(^|[^\\$])\$([^$\n]+)\$$/.exec(upto)
  if (inline && inline[2]!.trim() !== '' && !inline[2]!.startsWith('$')) {
    return { start: inline.index + inline[1]!.length, source: inline[2]!, display: false }
  }
  return null
}

/** `**…**` / `*…*` completed at the end of `upto`. Bold wins over nested emphasis. */
export function matchMarkdown(
  upto: string,
): { start: number; marker: '*' | '**'; body: string } | null {
  const bold = /(^|[^*])\*\*([^*]+)\*\*$/.exec(upto)
  if (bold && bold[2]!.trim() !== '') {
    return { start: bold.index + bold[1]!.length, marker: '**', body: bold[2]! }
  }
  const em = /(^|[^*])\*([^*\s][^*]*)\*$/.exec(upto)
  if (em && em[2]!.trim() !== '') {
    return { start: em.index + em[1]!.length, marker: '*', body: em[2]! }
  }
  return null
}

/** A style command opener (`\textbf{`) just completed at the end of `upto`. */
export function matchLatexOpener(upto: string): { start: number; command: LatexCommand } | null {
  const m = /\\(textbf|emph|textit|underline)\{$/.exec(upto)
  return m ? { start: m.index, command: m[1] as LatexCommand } : null
}

const LATEX_ELEMENT: Record<LatexCommand, string> = {
  textbf: 'strong',
  emph: 'em',
  textit: 'em',
  underline: 'u',
}

// ---------------------------------------------------------------------------
// Live editing behaviors
// ---------------------------------------------------------------------------

/** Pad islands with ZWSP anchors where Chromium can't otherwise place a caret: at a
 *  parent's start/end and between adjacent islands. Re-run after any island surgery. */
export function padIslands(root: HTMLElement): void {
  const isIsland = (n: Node | null): boolean =>
    n instanceof HTMLElement && n.classList.contains('rt-atom')
  for (const island of root.querySelectorAll('.rt-atom')) {
    if (island.previousSibling === null || isIsland(island.previousSibling)) {
      island.before(document.createTextNode(ZWSP))
    }
    if (island.nextSibling === null) island.after(document.createTextNode(ZWSP))
  }
}

/** The collapsed caret's text node and offset, if it is inside `editor`. */
function caretText(editor: HTMLElement): { node: Text; offset: number } | null {
  const sel = window.getSelection()
  if (!sel || !sel.isCollapsed || sel.rangeCount === 0) return null
  const { anchorNode, anchorOffset } = sel
  if (!(anchorNode instanceof Text) || !editor.contains(anchorNode)) return null
  return { node: anchorNode, offset: anchorOffset }
}

function anchorElement(sel: Selection): Element | null {
  const node = sel.anchorNode
  return node instanceof Element ? node : (node?.parentElement ?? null)
}

/** Collapse the caret just after `el`, anchored by a ZWSP so typing stays outside. */
function placeCaretAfter(el: Element): void {
  const sel = window.getSelection()
  if (!sel) return
  let after = el.nextSibling
  if (!(after instanceof Text)) {
    after = document.createTextNode(ZWSP)
    el.after(after)
  } else if (!after.data.startsWith(ZWSP)) {
    after.insertData(0, ZWSP)
  }
  sel.collapse(after, 1)
}

/**
 * Replace `[start, end)` of a text node with `html` via execCommand, keeping native
 * undo coherent (Ctrl+Z restores the literal typed source). The fragment must mark its
 * root with `data-rt-new`; the caret then lands `inside` it (ZWSP-anchored — Chromium
 * cannot hold a caret in an empty inline element) or `after` it.
 */
function replaceSource(
  editor: HTMLElement,
  node: Text,
  start: number,
  end: number,
  html: string,
  caret: 'inside' | 'after',
): void {
  const sel = window.getSelection()
  if (!sel) return
  const range = document.createRange()
  range.setStart(node, start)
  range.setEnd(node, end)
  sel.removeAllRanges()
  sel.addRange(range)
  document.execCommand('insertHTML', false, html)
  const el = editor.querySelector<HTMLElement>('[data-rt-new]')
  if (!el) return
  el.removeAttribute('data-rt-new')
  if (caret === 'inside') {
    let anchor: Text
    if (el.firstChild instanceof Text) {
      anchor = el.firstChild
    } else {
      anchor = document.createTextNode(ZWSP)
      el.append(anchor)
    }
    sel.collapse(anchor, anchor.data.length)
  } else {
    placeCaretAfter(el)
  }
}

/** The island a backspace is about to delete. Chromium hands the deletion target as a
 *  StaticRange — a lone ZWSP anchor (consumed here, so the invisible anchor never
 *  costs a dead keypress; the island behind it is the real target), or a range
 *  enclosing the island itself, which may span the neighbouring text nodes. */
function islandBehindBackspace(sr: StaticRange): HTMLElement | null {
  if (sr.startContainer === sr.endContainer && sr.startContainer instanceof Text) {
    const text = sr.startContainer
    if (text.data.slice(sr.startOffset, sr.endOffset) !== ZWSP || sr.startOffset !== 0) return null
    const prev = text.previousSibling
    if (prev instanceof HTMLElement && prev.classList.contains('rt-atom')) {
      text.deleteData(0, 1)
      return prev
    }
    return null
  }
  const range = document.createRange()
  try {
    range.setStart(sr.startContainer, sr.startOffset)
    range.setEnd(sr.endContainer, sr.endOffset)
  } catch {
    return null
  }
  const root = range.commonAncestorContainer
  const scope = root instanceof Element ? root : root.parentElement
  if (!scope) return null
  const touched = [...scope.querySelectorAll<HTMLElement>('.rt-atom')].filter((island) =>
    range.intersectsNode(island),
  )
  return touched.length === 1 ? touched[0]! : null
}

/**
 * Wire the live style-in-place behaviors onto a rich contenteditable. All handlers
 * bail during IME composition; every content mutation goes through execCommand so the
 * native undo stack stays coherent.
 */
export function wireRichEditing(editor: HTMLElement): void {
  let composing = false
  editor.addEventListener('compositionstart', () => {
    composing = true
  })
  editor.addEventListener('compositionend', () => {
    composing = false
  })

  editor.addEventListener('beforeinput', (event) => {
    if (composing || event.isComposing) return
    const sel = window.getSelection()
    if (!sel) return

    // `}` exits the live LaTeX style span instead of landing as a brace.
    if (event.inputType === 'insertText' && event.data === '}' && sel.isCollapsed) {
      const host = anchorElement(sel)?.closest('[data-run^="latex:"]')
      if (host && editor.contains(host)) {
        event.preventDefault()
        placeCaretAfter(host)
        return
      }
    }

    if (event.inputType !== 'deleteContentBackward' || !sel.isCollapsed) return
    const targetRange = event.getTargetRanges()[0]
    const island = targetRange ? islandBehindBackspace(targetRange) : null
    if (island) {
      event.preventDefault()
      const range = document.createRange()
      range.selectNode(island)
      sel.removeAllRanges()
      sel.addRange(range)
      if (island.classList.contains('rt-math')) {
        // Re-open as source: the extra backspace turns the island back into `$…$`.
        // Delete-then-insert: insertText over a selected non-editable island inserts
        // nothing in Chromium, but after the delete the caret sits in editable text.
        const source = island.dataset.tex ?? ''
        const display = island.dataset.display === '1'
        document.execCommand('delete')
        document.execCommand('insertText', false, display ? `$$${source}$$` : `$${source}$`)
        // insertText over a fresh replacement can leave the text selected; the user
        // expects a caret at the end of the re-opened source, ready to edit.
        const after = window.getSelection()
        if (after && !after.isCollapsed) after.collapseToEnd()
      }
      // Other atoms stay selected (armed); the next backspace deletes them natively.
      return
    }
    // Backspace inside a style span holding only its caret anchor deletes the span
    // (otherwise the user is trapped in an invisible empty element).
    const host = anchorElement(sel)?.closest('[data-run]')
    if (host && editor.contains(host) && host.textContent === ZWSP) {
      event.preventDefault()
      const range = document.createRange()
      range.selectNode(host)
      sel.removeAllRanges()
      sel.addRange(range)
      document.execCommand('delete')
    }
  })

  editor.addEventListener('input', (event) => {
    const e = event as InputEvent
    if (composing || e.isComposing) return
    if (e.inputType !== 'insertText' || !e.data) return
    const trigger = e.data[e.data.length - 1]
    if (trigger !== '$' && trigger !== '*' && trigger !== '{') return
    const at = caretText(editor)
    if (!at) return
    const upto = at.node.data.slice(0, at.offset)

    if (trigger === '$') {
      const m = matchMath(upto)
      if (m) {
        replaceSource(editor, at.node, m.start, at.offset, mathIslandHtml(m.source, m.display, true), 'after')
        padIslands(editor)
      }
      return
    }
    if (trigger === '*') {
      const m = matchMarkdown(upto)
      if (!m) return
      const tag = m.marker === '**' ? 'strong' : 'em'
      const html = `<${tag} data-run="md:${m.marker}" data-rt-new="">${escapeHtml(m.body)}</${tag}>`
      replaceSource(editor, at.node, m.start, at.offset, html, 'after')
      return
    }
    const m = matchLatexOpener(upto)
    if (m) {
      // The opener converts the moment `{` completes it: an (anchored) empty styled
      // element with the caret inside — typing is live-bold until `}` exits.
      const tag = LATEX_ELEMENT[m.command]
      const html = `<${tag} data-run="latex:${m.command}" data-rt-new="">${ZWSP}</${tag}>`
      replaceSource(editor, at.node, m.start, at.offset, html, 'inside')
    }
  })

  // A full contenteditable accepts styled clipboard/drag HTML; plain text only.
  editor.addEventListener('paste', (event) => {
    event.preventDefault()
    const text = event.clipboardData?.getData('text/plain') ?? ''
    if (text !== '') document.execCommand('insertText', false, text)
  })
  editor.addEventListener('drop', (event) => event.preventDefault())
  editor.addEventListener('dragstart', (event) => event.preventDefault())

  // Clicking an island selects it whole — visible feedback for "this is one unit".
  editor.addEventListener('click', (event) => {
    const island =
      event.target instanceof Element ? event.target.closest('.rt-atom') : null
    if (!island || !editor.contains(island)) return
    const sel = window.getSelection()
    if (!sel) return
    const range = document.createRange()
    range.selectNode(island)
    sel.removeAllRanges()
    sel.addRange(range)
  })
}
