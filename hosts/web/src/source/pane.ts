/**
 * CodeMirror 6 source pane (design D10, F13).
 *
 *  - Markdown with `stex` highlighting for TeX/TikZ fences and inline `\commands`/`$math$`;
 *  - a diagnostics gutter fed by core diagnostics (UTF-8 spans converted to CM positions);
 *  - the exact-range replace seam: user transactions are reported as exact-byte
 *    `SourceEdit`s (range + expected bytes + replacement); core-driven changes
 *    (`setText`, `replaceBytes`) are applied silently, never echoed back as edits.
 *
 * The pane is the author's text; it never parses the deck or decides what an edit means.
 */
import { EditorState, Annotation, type Extension } from "@codemirror/state";
import { EditorView, keymap, lineNumbers, highlightActiveLine, drawSelection, Decoration, MatchDecorator, ViewPlugin, type DecorationSet, type ViewUpdate } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { HighlightStyle, StreamLanguage, syntaxHighlighting, indentOnInput, bracketMatching } from "@codemirror/language";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { stex } from "@codemirror/legacy-modes/mode/stex";
import { lintGutter, setDiagnostics, type Diagnostic as CmDiagnostic } from "@codemirror/lint";
import { tags } from "@lezer/highlight";
import { createOffsetMap, editsFromChanges, type SourceEdit } from "./offsets.ts";
import type { ByteRange, ViewDiagnostic } from "../protocol/session.ts";

const external = Annotation.define<boolean>();
const texLanguage = StreamLanguage.define(stex);

const highlight = HighlightStyle.define([
  { tag: tags.heading1, class: "cm-h cm-h1" },
  { tag: tags.heading2, class: "cm-h cm-h2" },
  { tag: tags.heading, class: "cm-h" },
  { tag: tags.strong, fontWeight: "700" },
  { tag: tags.emphasis, fontStyle: "italic" },
  { tag: tags.monospace, class: "cm-mono" },
  { tag: tags.link, class: "cm-link" },
  { tag: tags.url, class: "cm-url" },
  { tag: tags.quote, class: "cm-quote" },
  { tag: tags.meta, class: "cm-meta" },
  { tag: tags.processingInstruction, class: "cm-fence" },
  { tag: tags.keyword, class: "cm-tex-keyword" },
  { tag: tags.atom, class: "cm-tex-atom" },
  { tag: tags.comment, class: "cm-tex-comment" },
  { tag: tags.string, class: "cm-tex-string" },
  { tag: tags.number, class: "cm-tex-number" },
  { tag: tags.tagName, class: "cm-tex-tag" },
  { tag: tags.bracket, class: "cm-tex-bracket" },
]);

/** Inline TeX in Markdown prose: `\command` and `$math$` get classes without a nested parser. */
const inlineTex = new MatchDecorator({
  regexp: /\\[A-Za-z]+\*?|\$[^$\n]+\$|<\d*-?\d*(?:,\d*-?\d*)*>/g,
  decoration: (match) => Decoration.mark({ class: match[0]!.startsWith("\\") ? "cm-tex-command" : match[0]!.startsWith("$") ? "cm-tex-inline-math" : "cm-overlay-spec" }),
});
const inlineTexPlugin = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  constructor(view: EditorView) { this.decorations = inlineTex.createDeco(view); }
  update(update: ViewUpdate) { this.decorations = inlineTex.updateDeco(update, this.decorations); }
}, { decorations: (plugin) => plugin.decorations });

function codeLanguageFor(info: string) {
  const name = info.trim().split(/\s+/)[0]?.toLowerCase() ?? "";
  return ["tex", "latex", "slide", "tikz", "notes"].includes(name) ? texLanguage : null;
}

export interface SourcePane {
  readonly element: HTMLElement;
  readonly view: EditorView;
  getText(): string;
  /** Replace the whole document silently (adoption of core bytes: open, undo, redo). */
  setText(text: string): void;
  /** Exact-range replace driven by the core or a toolbar; silent, preserves selection mapping. */
  replaceBytes(range: ByteRange, text: string): void;
  /** Select and scroll a core-supplied byte range into view (click-to-source). */
  revealBytes(range: ByteRange): void;
  setDiagnostics(diagnostics: readonly ViewDiagnostic[]): void;
  /** Called for every user transaction with its exact-byte edits (last-to-first). */
  onEdit(listener: (edits: SourceEdit[], text: string) => void): () => void;
  /** Caret position as a UTF-8 byte offset (preview follows the caret). */
  onCaret(listener: (byte: number) => void): () => void;
  /** Selection as a byte range, or null when collapsed. */
  selectionBytes(): ByteRange | null;
  setDirty(dirty: boolean): void;
  focus(): void;
  destroy(): void;
}

export function createSourcePane(parent: HTMLElement, initial = ""): SourcePane {
  const editListeners = new Set<(edits: SourceEdit[], text: string) => void>();
  const caretListeners = new Set<(byte: number) => void>();
  const extensions: Extension[] = [
    lineNumbers(),
    history(),
    drawSelection(),
    indentOnInput(),
    bracketMatching(),
    highlightActiveLine(),
    EditorView.lineWrapping,
    keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
    markdown({ base: markdownLanguage, codeLanguages: (info) => codeLanguageFor(info) }),
    inlineTexPlugin,
    syntaxHighlighting(highlight),
    lintGutter(),
    EditorView.contentAttributes.of({ "aria-label": "Source", spellcheck: "false" }),
    EditorView.updateListener.of((update) => {
      if (update.docChanged && !update.transactions.every((t) => t.annotation(external) === true)) {
        const oldText = update.startState.doc.toString();
        const changes: { fromA: number; toA: number; inserted: string }[] = [];
        update.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => changes.push({ fromA, toA, inserted: inserted.toString() }));
        const edits = editsFromChanges(oldText, changes);
        const text = update.state.doc.toString();
        for (const listener of [...editListeners]) listener(edits, text);
      }
      if (update.selectionSet || update.docChanged) {
        const head = update.state.selection.main.head;
        const byte = createOffsetMap(update.state.doc.toString()).toByte(head);
        for (const listener of [...caretListeners]) listener(byte);
      }
    }),
  ];
  const view = new EditorView({ state: EditorState.create({ doc: initial, extensions }), parent });
  view.dom.classList.add("sb-source-editor");

  return {
    element: view.dom,
    view,
    getText: () => view.state.doc.toString(),
    setText(text) {
      if (text === view.state.doc.toString()) return;
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, annotations: external.of(true), selection: { anchor: Math.min(view.state.selection.main.head, text.length) } });
    },
    replaceBytes(range, text) {
      const map = createOffsetMap(view.state.doc.toString());
      view.dispatch({ changes: { from: map.toChar(range.start), to: map.toChar(range.end), insert: text }, annotations: external.of(true) });
    },
    revealBytes(range) {
      const map = createOffsetMap(view.state.doc.toString());
      const from = map.toChar(range.start);
      const to = Math.max(from, map.toChar(range.end));
      view.dispatch({ selection: { anchor: from, head: to }, effects: EditorView.scrollIntoView(from, { y: "center" }) });
    },
    setDiagnostics(diagnostics) {
      const map = createOffsetMap(view.state.doc.toString());
      const mapped: CmDiagnostic[] = [];
      for (const d of diagnostics) {
        if (d.span === null) continue;
        const from = map.toChar(d.span.start);
        const to = Math.max(from, map.toChar(d.span.end));
        mapped.push({ from, to: Math.min(view.state.doc.length, to === from ? Math.min(from + 1, view.state.doc.length) : to), severity: d.severity, message: d.message, source: d.code });
      }
      view.dispatch(setDiagnostics(view.state, mapped));
    },
    onEdit(listener) { editListeners.add(listener); return () => editListeners.delete(listener); },
    onCaret(listener) { caretListeners.add(listener); return () => caretListeners.delete(listener); },
    selectionBytes() {
      const { from, to } = view.state.selection.main;
      if (from === to) return null;
      const map = createOffsetMap(view.state.doc.toString());
      return { start: map.toByte(from), end: map.toByte(to) };
    },
    setDirty(dirty) { view.dom.dataset.dirty = String(dirty); },
    focus: () => view.focus(),
    destroy: () => view.destroy(),
  };
}
