/**
 * Parse `*.slideBlaster.md` text into a SlideDocument. Contract: see fromMarkdown.md.
 *
 * Container only: YAML-ish frontmatter, then `##{#id}` slide sections each holding
 * one fenced ```slide block. The block body is handed to the TikZ parser.
 */
import type { DocumentMeta, Frame, SlideDocument } from '../model/document'
import { parsePicture } from '../tikz/parse'

const HEADING = /^##\s+(.*?)\s*\{#([^}]+)\}\s*$/
const FRONTMATTER_ENTRY = /^([^:]+):\s?(.*)$/

export function fromMarkdown(text: string): SlideDocument {
  const lines = text.split('\n')
  let i = 0

  const meta: DocumentMeta = { entries: [] }
  if (lines[0] === '---') {
    i = 1
    while (i < lines.length && lines[i] !== '---') {
      const match = FRONTMATTER_ENTRY.exec(lines[i]!)
      if (match) meta.entries.push({ key: match[1]!.trim(), value: match[2]! })
      i++
    }
    i++ // closing ---
    if (lines[i] === '') i++ // single blank line after frontmatter
  }

  const frames: Frame[] = []
  while (i < lines.length) {
    if (lines[i] === '') {
      i++
      continue
    }
    const heading = HEADING.exec(lines[i]!)
    if (!heading) throw new Error(`expected a slide heading '## Title {#id}', got: ${lines[i]}`)
    const title = heading[1]!
    const id = heading[2]!
    i++
    while (lines[i] === '') i++
    if (lines[i] !== '```slide') throw new Error(`expected a \`\`\`slide block for slide ${id}`)
    i++
    const bodyLines: string[] = []
    while (i < lines.length && lines[i] !== '```') {
      bodyLines.push(lines[i]!)
      i++
    }
    i++ // closing ```
    frames.push({ id, title, picture: parsePicture(bodyLines.join('\n')) })
  }

  return { meta, frames }
}
