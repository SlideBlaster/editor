/**
 * UTF-16 <-> UTF-8 offset translation for the exact-range replace seam. The core speaks
 * UTF-8 byte offsets (session/1 spans, `apply_source_replace`); CodeMirror speaks UTF-16
 * code units. This is pure arithmetic on the text the pane already holds, not parsing.
 */
const encoder = new TextEncoder();

export interface OffsetMap {
  /** UTF-8 byte offset of a UTF-16 position (positions inside a surrogate pair round down). */
  toByte(char: number): number;
  /** UTF-16 position of a UTF-8 byte offset (offsets inside a character round down). */
  toChar(byte: number): number;
  readonly byteLength: number;
  readonly charLength: number;
}

export function createOffsetMap(text: string): OffsetMap {
  // byteAt[i] = byte offset of UTF-16 unit i; length n + 1.
  const byteAt = new Uint32Array(text.length + 1);
  let bytes = 0;
  for (let i = 0; i < text.length; i += 1) {
    byteAt[i] = bytes;
    const code = text.charCodeAt(i);
    if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xd800 && code < 0xdc00 && i + 1 < text.length && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) < 0xe000) {
      bytes += 4;
      byteAt[i + 1] = bytes - 4; // the low surrogate shares its pair's start
      i += 1;
      // after the pair the next unit starts at `bytes`; byteAt[i + 1] is set next iteration
      continue;
    } else bytes += 3;
  }
  byteAt[text.length] = bytes;
  return {
    byteLength: bytes,
    charLength: text.length,
    toByte(char) {
      const clamped = Math.max(0, Math.min(text.length, char));
      return byteAt[clamped]!;
    },
    toChar(byte) {
      const target = Math.max(0, Math.min(bytes, byte));
      let lo = 0;
      let hi = text.length;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (byteAt[mid]! <= target) lo = mid; else hi = mid - 1;
      }
      // Never land between the halves of a surrogate pair.
      if (lo > 0 && lo < text.length && byteAt[lo] === byteAt[lo - 1] && text.charCodeAt(lo) >= 0xdc00 && text.charCodeAt(lo) < 0xe000) lo -= 1;
      return lo;
    },
  };
}

export interface SourceEdit {
  /** Byte range in the document *before* this edit. */
  readonly range: { readonly start: number; readonly end: number };
  readonly expected: Uint8Array;
  readonly replacement: Uint8Array;
}

/**
 * Turn CodeMirror change records (positions in the old document) into exact-byte edits,
 * ordered last-to-first so each range stays valid in the old coordinates when applied in
 * sequence.
 */
export function editsFromChanges(
  oldText: string,
  changes: readonly { fromA: number; toA: number; inserted: string }[],
): SourceEdit[] {
  if (changes.length === 0) return [];
  const map = createOffsetMap(oldText);
  const edits = changes.map((c) => ({
    range: { start: map.toByte(c.fromA), end: map.toByte(c.toA) },
    expected: encoder.encode(oldText.slice(c.fromA, c.toA)),
    replacement: encoder.encode(c.inserted),
  }));
  return edits.sort((a, b) => b.range.start - a.range.start);
}

/** Apply byte edits (in the order given) to bytes; used by tests and the offline fallback. */
export function applyEdits(source: Uint8Array, edits: readonly SourceEdit[]): Uint8Array {
  let current = source;
  for (const edit of edits) {
    const seen = current.slice(edit.range.start, edit.range.end);
    if (seen.length !== edit.expected.length || seen.some((b, i) => b !== edit.expected[i])) throw new Error("expected bytes differ");
    const next = new Uint8Array(current.length - seen.length + edit.replacement.length);
    next.set(current.subarray(0, edit.range.start), 0);
    next.set(edit.replacement, edit.range.start);
    next.set(current.subarray(edit.range.end), edit.range.start + edit.replacement.length);
    current = next;
  }
  return current;
}
