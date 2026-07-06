/**
 * Serialize a SlideDocument to canonical `*.slideBlaster.md` text. Contract: see
 * toMarkdown.md.
 */
import type { SlideDocument } from '../model/document'
import { serializePicture } from '../tikz/serialize'

export function toMarkdown(doc: SlideDocument): string {
  const parts: string[] = []

  if (doc.meta.entries.length) {
    parts.push('---')
    for (const entry of doc.meta.entries) parts.push(`${entry.key}: ${entry.value}`)
    parts.push('---')
    parts.push('')
  }

  for (const frame of doc.frames) {
    parts.push(`## ${frame.title} {#${frame.id}}`)
    parts.push('')
    parts.push('```slide')
    parts.push(serializePicture(frame.picture))
    parts.push('```')
    // The presenter-notes sidecar, when present, as a second fenced block (ADR 0019).
    if (frame.notes) {
      parts.push('')
      parts.push('```notes')
      parts.push(serializePicture(frame.notes))
      parts.push('```')
    }
    parts.push('')
  }

  return parts.join('\n')
}
