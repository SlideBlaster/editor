import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  ANNOTATION_BINDING,
  BINDING_PATH,
  DRIVER_PATH,
  installTableAnnotation,
  patchDriver,
  type AnnotationFs,
} from './tableAnnotation'

const here = dirname(fileURLToPath(import.meta.url))

// A minimal fake of the two-line driver shape we anchor on.
const DRIVER = [
  'use LaTeXML::Common::Config;',
  'my $opts = LaTeXML::Common::Config->new(',
  '  input_limit => 100,',
  '  format      => "html5",',
  ');',
].join('\n')

/** An in-memory stand-in for the emscripten MEMFS. */
function fakeFs(
  seed: Record<string, string> = {},
): AnnotationFs & { files: Record<string, string> } {
  const files = { ...seed }
  return {
    files,
    writeFile(path, data) {
      files[path] = data
    },
    readFile(path) {
      const data = files[path]
      if (data === undefined) throw new Error(`ENOENT: ${path}`)
      return data
    },
  }
}

describe('patchDriver', () => {
  it('adds the preload right after the Config constructor', () => {
    const patched = patchDriver(DRIVER)
    expect(patched).toContain("preload => ['sbannot.ltxml']")
    expect(patched).toContain("paths => ['/sb']")
    // Inserted before the existing options, not after the closing paren.
    expect(patched.indexOf('sbannot')).toBeLessThan(patched.indexOf('input_limit'))
  })

  it('is idempotent — a driver already carrying the preload is untouched', () => {
    const once = patchDriver(DRIVER)
    expect(patchDriver(once)).toBe(once)
  })

  it('leaves a driver without the anchor unchanged', () => {
    const alien = 'print "no config here";'
    expect(patchDriver(alien)).toBe(alien)
  })
})

describe('installTableAnnotation', () => {
  it('writes the binding and patches the driver in the MEMFS', () => {
    const fs = fakeFs({ [DRIVER_PATH]: DRIVER })
    installTableAnnotation(fs)
    expect(fs.files[BINDING_PATH]).toBe(ANNOTATION_BINDING)
    expect(fs.files[DRIVER_PATH]).toContain("preload => ['sbannot.ltxml']")
  })

  it('swallows a missing driver (best-effort) but still writes the binding', () => {
    const fs = fakeFs() // no driver present
    expect(() => installTableAnnotation(fs)).not.toThrow()
    expect(fs.files[BINDING_PATH]).toBe(ANNOTATION_BINDING)
  })
})

describe('ANNOTATION_BINDING', () => {
  it('hooks the tabular cell elements and stamps data-sbx/y', () => {
    expect(ANNOTATION_BINDING).toContain("Tag('ltx:td', afterOpen")
    expect(ANNOTATION_BINDING).toContain("setAttribute($node, 'data:sbx'")
    expect(ANNOTATION_BINDING).toContain("setAttribute($node, 'data:sby'")
  })
})

describe('driver anchor is stable', () => {
  it('the shipped web driver still contains the string we inject after', () => {
    const driver = readFileSync(join(here, 'engine', 'latexml-driver-web.pl'), 'utf8')
    // If this anchor ever changes, the runtime patch silently disables annotation —
    // fail here instead so the binding injection is updated deliberately.
    expect(driver).toContain('LaTeXML::Common::Config->new(')
  })
})
