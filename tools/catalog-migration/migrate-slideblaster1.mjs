#!/usr/bin/env node
/**
 * One-time, deterministic migration of SlideBlaster 1's generated draw.io
 * TypeScript registries into the language-neutral catalog-v1 JSON snapshot.
 *
 * This does not fetch draw.io and is not the future upstream importer. It
 * preserves the already-reviewed 2,257-row snapshot while the Haskell importer
 * and a reviewed upstream pin are established.
 */
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import vm from 'node:vm'

const [, , definitionsPath, geometryPath, outputPath] = process.argv

if (!definitionsPath || !geometryPath || !outputPath) {
  process.stderr.write(
    'usage: migrate-slideblaster1.mjs <stencils.generated.ts> ' +
      '<render/stencils.generated.ts> <catalog-v1.json>\n',
  )
  process.exit(2)
}

const LEGACY_DEFINITIONS_COMMIT = 'e67c13abbdaf00065b7337419dc8b9b99301d98e'
const LEGACY_GEOMETRY_COMMIT = '3d9545017bbf682a73b9b364fe69b0c670c39fb3'
const LEGACY_DEFINITIONS_SHA256 = 'f3f3d0caf172c582c941449aa2a8635b37aa5bcf055a03dba69817915a47066b'
const LEGACY_GEOMETRY_SHA256 = '300c9b1f7fa864dda8b79395bacbdce5652fb5b38ec35e57e928249fbd189228'
const EXPECTED_SHAPE_COUNT = 2257

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function evaluateGenerated(source, declaration, binding) {
  const executable = source
    .replace(/^import type .*$/gm, '')
    .replace(declaration, `globalThis.${binding} =`)
  const context = Object.create(null)
  vm.runInNewContext(executable, context, { timeout: 10_000 })
  return context[binding]
}

const definitionBytes = readFileSync(resolve(definitionsPath))
const geometryBytes = readFileSync(resolve(geometryPath))
const definitionsHash = sha256(definitionBytes)
const geometryHash = sha256(geometryBytes)

if (definitionsHash !== LEGACY_DEFINITIONS_SHA256) {
  throw new Error(
    `definition registry does not match ${LEGACY_DEFINITIONS_COMMIT}: ${definitionsHash}`,
  )
}
if (geometryHash !== LEGACY_GEOMETRY_SHA256) {
  throw new Error(
    `geometry registry does not match ${LEGACY_GEOMETRY_COMMIT}: ${geometryHash}`,
  )
}

const rows = evaluateGenerated(
  definitionBytes.toString('utf8'),
  'export const STENCIL_SHAPES: ShapeDef[] =',
  'rows',
)
const geometry = evaluateGenerated(
  geometryBytes.toString('utf8'),
  'export const STENCILS: Record<string, string> =',
  'geometry',
)

if (!Array.isArray(rows)) throw new Error('definition registry did not evaluate to an array')
if (rows.length !== EXPECTED_SHAPE_COUNT) {
  throw new Error(`expected ${EXPECTED_SHAPE_COUNT} shapes, received ${rows.length}`)
}
const seen = new Set()
const shapes = rows.map((row) => {
  if (seen.has(row.id)) throw new Error(`duplicate shape id: ${row.id}`)
  seen.add(row.id)
  const path = geometry[row.id]
  if (typeof path !== 'string' || path.length === 0) {
    throw new Error(`missing geometry for shape: ${row.id}`)
  }
  return {
    id: row.id,
    label: row.label,
    category: row.category,
    keywords: row.keywords,
    size: row.size,
    aspect: row.aspect ?? 'variable',
    path,
  }
})

const unreferencedGeometry = Object.keys(geometry).filter((id) => !seen.has(id))
if (unreferencedGeometry.length > 0) {
  throw new Error(`unreferenced geometry rows: ${unreferencedGeometry.slice(0, 10).join(', ')}`)
}

const snapshot = {
  schemaVersion: 1,
  provenance: {
    migrationSource: 'SlideBlaster 1 generated registries',
    definitionsCommit: LEGACY_DEFINITIONS_COMMIT,
    geometryCommit: LEGACY_GEOMETRY_COMMIT,
    definitionsSha256: definitionsHash,
    geometrySha256: geometryHash,
    drawioRepository: 'https://github.com/jgraph/drawio',
    drawioUpstreamCommit: null,
    upstreamCommitStatus:
      'not recorded by SlideBlaster 1; choose and review a pin before upstream regeneration',
  },
  attribution: {
    title: 'draw.io / diagrams.net shape stencils',
    author: 'JGraph Ltd and the draw.io contributors',
    license: 'CC BY 4.0',
    source: 'https://github.com/jgraph/drawio/tree/dev/src/main/webapp/stencils',
  },
  shapes,
}

const resolvedOutput = resolve(outputPath)
mkdirSync(dirname(resolvedOutput), { recursive: true })
writeFileSync(resolvedOutput, `${JSON.stringify(snapshot)}\n`)
process.stderr.write(`migrated ${shapes.length} shapes -> ${resolvedOutput}\n`)
