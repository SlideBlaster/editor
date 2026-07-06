/*
 * WASM latexml worker (classic). Contract: adapters-shared/src/compile/workerLatexmlEngine.md.
 *
 * Hosts the Perl interpreter (perl-web.js + .wasm + .data) off the UI thread. Kept as
 * a dependency-free STATIC file (not bundled) so it can `importScripts` the emscripten
 * MODULARIZE glue, which module workers cannot. The @INC / driver constants below MUST
 * stay in lockstep with browserLatexmlEngine.ts (the same conversion, Node-side).
 *
 * Protocol (see createWorkerLatexmlEngine):
 *   in:  { type: 'init', jsUrl, wasmUrl, dataUrl }   once, before any convert
 *        { type: 'convert', id, tex }                 a full LaTeX document to convert
 *   out: { id, html } | { id, error }
 *
 * Conversions are serialized on one promise chain: a single Perl interpreter is not
 * re-entrant, so overlapping callMain() would corrupt state.
 */
'use strict'

// @INC inside the preloaded MEMFS (mounted at /sb): patched overlay, perl core, the
// XS pure-perl halves, then LaTeXML. Mirror of browserLatexmlEngine.ts INC_ARGS.
var INC_ARGS = ['/sb/overlay', '/sb/lib', '/sb/xml-libxml', '/sb/xml-libxslt', '/sb/perl5'].reduce(
  function (acc, p) {
    acc.push('-I', p)
    return acc
  },
  [],
)
var DRIVER = '/sb/driver.pl'
var IN = '/in.tex'
var OUT = '/out.html'

var modulePromise = null
var queue = Promise.resolve()

function boot(cfg) {
  if (!modulePromise) {
    importScripts(cfg.jsUrl) // defines self.createPerlModule (MODULARIZE factory)
    modulePromise = createPerlModule({
      noInitialRun: true,
      locateFile: function (path) {
        if (path.slice(-5) === '.wasm') return cfg.wasmUrl
        if (path.slice(-5) === '.data') return cfg.dataUrl
        return path
      },
      print: function () {},
      printErr: function () {},
    }).then(function (m) {
      m.ENV.PERL_HASH_SEED = '0' // deterministic output (matches native goldens)
      return m
    })
  }
  return modulePromise
}

function convert(m, tex) {
  m.FS.writeFile(IN, tex)
  try {
    m.FS.unlink(OUT)
  } catch (_) {
    // no prior output
  }
  var code = m.callMain(INC_ARGS.concat([DRIVER, IN, OUT]))
  var html
  try {
    html = m.FS.readFile(OUT, { encoding: 'utf8' })
  } catch (_) {
    throw new Error('WASM latexml produced no output (exit ' + code + ')')
  }
  if (!html) throw new Error('WASM latexml produced empty output (exit ' + code + ')')
  return html
}

var config = null

self.onmessage = function (event) {
  var msg = event.data
  if (!msg) return
  if (msg.type === 'init') {
    config = msg
    boot(config) // start booting eagerly so the first convert is warmer
    return
  }
  if (msg.type === 'convert') {
    var id = msg.id
    var tex = msg.tex
    queue = queue.then(function () {
      return boot(config)
        .then(function (m) {
          self.postMessage({ id: id, html: convert(m, tex) })
        })
        .catch(function (err) {
          self.postMessage({ id: id, error: (err && err.message) || String(err) })
        })
    })
  }
}
