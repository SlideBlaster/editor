/**
 * What the page needs from wherever the project's files live, when the core runs in the page
 * (milestone W-web) instead of inside `sb serve`. The in-page transport performs the session's
 * `storage` and `block.render` effects through this, and feeds file changes back to the core.
 *
 * Implementations: the desktop shell (`shell-host.ts`, real files through the app), and `sb serve`'s
 * `/cap` socket (`cap-host.ts`, the same core in a plain browser tab for development and tests).
 */
import type { PdfExportResult } from "../ui/export-pdf.ts";

export interface ProjectFile {
  readonly path: string;
  readonly bytes: Uint8Array;
}

export interface ProjectChange {
  readonly path: string;
  /** The file's new bytes, or `null` when it was deleted. */
  readonly bytes: Uint8Array | null;
}

export type WriteResult = { readonly ok: true } | { readonly ok: false; readonly reason: string };

/** A `provider_result` body: exactly one of `artifact` or `diagnostics`. */
export type ProviderOutcome =
  | { readonly artifact: { readonly mime: string; readonly bytesBase16: string; readonly width: number; readonly height: number; readonly provenance: string } }
  | { readonly diagnostics: readonly { readonly severity: string; readonly code: string; readonly message: string; readonly line: number | null; readonly absent: boolean }[] };

export interface ProjectHost {
  /** Every project file the core may read (not caches or git), paths relative to the project. */
  list(): Promise<ProjectFile[]>;
  /** One project file, or `null` when it does not exist. */
  read(path: string): Promise<Uint8Array | null>;
  /** Replace a file only if it still holds `expected` (`null`: it must not exist). */
  write(path: string, expected: Uint8Array | null, bytes: Uint8Array): Promise<WriteResult>;
  /** Keep a derived file (measured node sizes) inside the project's cache folder. */
  writeCache(path: string, bytes: Uint8Array): Promise<void>;
  /** Compile one figure (`block.render` request as the core wrote it). Never rejects for provider faults. */
  renderBlock(request: Record<string, unknown>): Promise<ProviderOutcome>;
  /** Files changed outside the editor. */
  onChange(listener: (changes: readonly ProjectChange[]) => void): () => void;
  /** Write `<deck>.pdf` beside the deck. */
  exportPdf(entry: string, steps: boolean): Promise<PdfExportResult>;
}

export function absentOutcome(code: string, message: string): ProviderOutcome {
  return { diagnostics: [{ severity: "error", code, message, line: null, absent: true }] };
}

export function failedOutcome(code: string, message: string): ProviderOutcome {
  return { diagnostics: [{ severity: "error", code, message, line: null, absent: false }] };
}

// --- one byte string for several: [count] then, per part, [length][bytes]; lengths are u32 LE ----

export function packParts(parts: readonly Uint8Array[]): Uint8Array {
  let size = 4;
  for (const part of parts) size += 4 + part.length;
  const out = new Uint8Array(size);
  const view = new DataView(out.buffer);
  view.setUint32(0, parts.length, true);
  let at = 4;
  for (const part of parts) {
    view.setUint32(at, part.length, true);
    out.set(part, at + 4);
    at += 4 + part.length;
  }
  return out;
}

export function unpackParts(packed: Uint8Array): Uint8Array[] {
  const view = new DataView(packed.buffer, packed.byteOffset, packed.byteLength);
  if (packed.length < 4) throw new Error("packed bytes are too short");
  const count = view.getUint32(0, true);
  const parts: Uint8Array[] = [];
  let at = 4;
  for (let index = 0; index < count; index += 1) {
    if (at + 4 > packed.length) throw new Error("packed bytes end inside a length");
    const length = view.getUint32(at, true);
    at += 4;
    if (at + length > packed.length) throw new Error("packed bytes end inside a part");
    parts.push(packed.subarray(at, at + length));
    at += length;
  }
  return parts;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** A file listing as `[path, bytes, path, bytes, ...]` parts. */
export function unpackFiles(packed: Uint8Array): ProjectFile[] {
  const parts = unpackParts(packed);
  if (parts.length % 2 !== 0) throw new Error("a packed file listing has an odd number of parts");
  const files: ProjectFile[] = [];
  for (let index = 0; index < parts.length; index += 2) files.push({ path: decoder.decode(parts[index]), bytes: parts[index + 1]! });
  return files;
}

export function packFiles(files: readonly ProjectFile[]): Uint8Array {
  return packParts(files.flatMap((file) => [encoder.encode(file.path), file.bytes]));
}
