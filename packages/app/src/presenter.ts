/**
 * Presenter mode: a live two-window show driven by one shared cursor. Contract: see
 * presenter.md. ADR 0019.
 *
 * "Present" opens two same-origin windows from the running editor — an AUDIENCE window
 * (the current slide, for the projector) and a PRESENTER CONSOLE (the current slide's
 * notes sidecar, the next-slide preview, a slide/step readout, and an elapsed timer).
 * Both are rendered up front from the current in-memory deck into a flat list of BEATS —
 * every `(frame, step)` pair in reading order, the same per-step frame list export uses.
 *
 * The two surfaces stay in lockstep because they share ONE integer cursor over the beat
 * list via a `BroadcastChannel`: a key or click in either window moves the cursor and
 * both repaint. The slide and its notes always render at the SAME step, so a `\pause` at
 * the same position on each lands on the same click for free (ADR 0018/0019). The step
 * count is the audience slide's own (`stepsOf`, cap to slide) — the notes never add steps.
 *
 * The documents are self-contained (deck CSS + slide HTML baked in), so the show keeps
 * working even if the editor window is closed. `window.open` + `BroadcastChannel` are a
 * browser-shell concern and live here, out of the headless engine.
 */
import { slideStylesheet, type Frame, type TikzPicture } from '@slideblaster/editor'
import { SLIDE_TYPE_CSS } from './slideType'
import { KATEX_CSS } from './katexInlineCss'

/** One presented moment: a slide at a step, with its notes sidecar at the SAME step. */
export interface Beat {
  /** Zero-based frame index in the deck. */
  frame: number
  /** One-based step within the frame (1..`steps`). */
  step: number
  /** The frame's total step count — the audience slide's own (cap to slide, ADR 0019). */
  steps: number
  /** The audience slide rendered at `step` (a self-contained `.sb-slide`). */
  slideHtml: string
  /** The notes sidecar rendered at `step`, or '' when the slide has no notes. */
  notesHtml: string
}

/** What `present` needs from the shell to build and open the show. */
export interface PresenterDeps {
  frames: readonly Frame[]
  /** Compile any async content (tables, citations) across the deck before rendering. */
  prepare(): Promise<void>
  /** Render a picture at a step to self-contained slide HTML (layout resolved internally). */
  renderAt(picture: TikzPicture, step: number): Promise<string>
  /** A picture's step count — the audience slide's own (`slideStepCount`); notes are not consulted. */
  stepsOf(picture: TikzPicture): number
  /** Deck title (window titles). */
  title: string
  /** The active theme's stylesheet + furniture CSS, so the windows match the live canvas. */
  themeCss: string
}

export type PresentResult =
  { ok: true } | { ok: false; reason: 'blocked' | 'empty' | 'error'; message?: string }

/**
 * Build the ordered beat list for a deck. For each frame, one beat per step
 * (`1..stepsOf(picture)` — cap to slide, ADR 0019), rendering the slide and its notes
 * sidecar at the SAME step. Layout resolution is the caller's concern (via `renderAt`),
 * which lets it resolve each picture's step-invariant layout once and reuse it.
 */
export async function buildBeats(
  frames: readonly Frame[],
  renderAt: (picture: TikzPicture, step: number) => string | Promise<string>,
  stepsOf: (picture: TikzPicture) => number,
): Promise<Beat[]> {
  const beats: Beat[] = []
  for (let frame = 0; frame < frames.length; frame++) {
    const f = frames[frame]!
    const steps = Math.max(1, stepsOf(f.picture))
    for (let step = 1; step <= steps; step++) {
      const slideHtml = await renderAt(f.picture, step)
      const notesHtml = f.notes ? await renderAt(f.notes, step) : ''
      beats.push({ frame, step, steps, slideHtml, notesHtml })
    }
  }
  return beats
}

/**
 * Open presenter mode. Opens the console window SYNCHRONOUSLY (so the pop-up rides the
 * user gesture), then compiles + renders the deck and writes the real document in. The
 * console offers "Open audience display" (a second in-window gesture) so both pop-ups
 * are user-initiated. Returns `{ok:false, reason:'blocked'}` if the console pop-up was
 * blocked, `'empty'` for an empty deck, `'error'` if rendering threw.
 */
export async function present(deps: PresenterDeps): Promise<PresentResult> {
  // Must run inside the click's synchronous prefix — before the first await — or the
  // browser blocks the pop-up.
  const win = window.open('', 'sb-presenter-console', 'width=1120,height=760')
  if (!win) return { ok: false, reason: 'blocked' }
  writePlaceholder(win, deps.title)

  try {
    await deps.prepare()
    const beats = await buildBeats(deps.frames, deps.renderAt, deps.stepsOf)
    if (beats.length === 0) {
      win.close()
      return { ok: false, reason: 'empty' }
    }
    const css = deckCss(deps.themeCss)
    const audienceDoc = buildAudienceDocument(beats, { title: deps.title, css })
    const consoleDoc = buildConsoleDocument(beats, { title: deps.title, css, audienceDoc })
    replaceDocument(win, consoleDoc)
    win.focus()
    return { ok: true }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    try {
      replaceDocument(win, errorDocument(message))
    } catch {
      /* window may have been closed */
    }
    return { ok: false, reason: 'error', message }
  }
}

/** The full deck stylesheet the windows inline (matches the live canvas + export). */
function deckCss(themeCss: string): string {
  return [slideStylesheet(), themeCss, SLIDE_TYPE_CSS, KATEX_CSS].join('\n')
}

// ── document builders ────────────────────────────────────────────

/** The audience window: only the current slide, centred and fittable to the projector.
 *  Exported for tests (pure string output); `present` composes it into the console doc. */
export function buildAudienceDocument(beats: Beat[], opts: { title: string; css: string }): string {
  const slides = beats.map((b) => b.slideHtml)
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${escapeHtml(opts.title)} — audience</title>
<style>
${opts.css}
${AUDIENCE_CSS}
</style>
</head>
<body class="sb-aud">
<div class="sb-aud-stage" id="sb-aud-stage"></div>
<div class="sb-aud-hint" id="sb-aud-hint">Arrow keys / click to advance · f for fullscreen</div>
<script>
const SLIDES = ${embedJson(slides)};
${AUDIENCE_JS}
</script>
</body>
</html>`
}

/** The presenter console: notes at the current step + next preview + readout + timer,
 *  and the button that opens the audience window (writing the embedded audience doc). */
function buildConsoleDocument(
  beats: Beat[],
  opts: { title: string; css: string; audienceDoc: string },
): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${escapeHtml(opts.title)} — presenter</title>
<style>
${opts.css}
${CONSOLE_CSS}
</style>
</head>
<body class="sb-con">
<header class="sb-con-bar">
  <span class="sb-con-pos" id="sb-con-pos"></span>
  <span class="sb-con-where" id="sb-con-where"></span>
  <span class="sb-con-timer" id="sb-con-timer">00:00</span>
  <button type="button" id="sb-con-audience">Open audience display</button>
</header>
<main class="sb-con-main">
  <section class="sb-con-notes" aria-label="Speaker notes">
    <div class="sb-con-notes-inner" id="sb-con-notes"></div>
  </section>
  <aside class="sb-con-side">
    <div class="sb-con-label">Next</div>
    <div class="sb-con-preview" id="sb-con-preview"></div>
  </aside>
</main>
<footer class="sb-con-controls">
  <button type="button" id="sb-con-prev">&lsaquo; Prev</button>
  <button type="button" id="sb-con-next">Next &rsaquo;</button>
</footer>
<script>
const BEATS = ${embedJson(beats)};
const AUDIENCE_DOC = ${embedString(opts.audienceDoc)};
${CONSOLE_JS}
</script>
</body>
</html>`
}

// ── embedded client runtimes (run in the pop-up windows) ─────────

/** Audience: paint the current slide; sync the cursor over the channel; keys/click advance. */
const AUDIENCE_JS = `
(function () {
  const ch = new BroadcastChannel('sb-presenter');
  const stage = document.getElementById('sb-aud-stage');
  const hint = document.getElementById('sb-aud-hint');
  let cursor = 0;
  const clamp = (c) => Math.max(0, Math.min(SLIDES.length - 1, c));
  function render() { stage.innerHTML = SLIDES[cursor] || ''; }
  function goto(c) { cursor = clamp(c); render(); }
  function nav(delta) { goto(cursor + delta); ch.postMessage({ t: 'goto', cursor: cursor }); }
  ch.onmessage = (e) => {
    const m = e.data;
    if (m.t === 'goto') goto(m.cursor);
    else if (m.t === 'hello') ch.postMessage({ t: 'goto', cursor: cursor });
  };
  addEventListener('keydown', (e) => {
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown' || e.key === 'PageDown' || e.key === ' ') { e.preventDefault(); nav(1); }
    else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp' || e.key === 'PageUp') { e.preventDefault(); nav(-1); }
    else if (e.key === 'Home') { e.preventDefault(); goto(0); ch.postMessage({ t: 'goto', cursor: cursor }); }
    else if (e.key === 'End') { e.preventDefault(); goto(SLIDES.length - 1); ch.postMessage({ t: 'goto', cursor: cursor }); }
    else if (e.key === 'f' || e.key === 'F') { e.preventDefault(); if (!document.fullscreenElement) document.documentElement.requestFullscreen(); else document.exitFullscreen(); }
  });
  addEventListener('click', () => nav(1));
  let hintTimer = setTimeout(() => hint.classList.add('sb-hidden'), 3500);
  render();
  ch.postMessage({ t: 'hello' });
})();
`.trim()

/** Console: paint notes + next preview + readout; run the timer; open the audience window. */
const CONSOLE_JS = `
(function () {
  const ch = new BroadcastChannel('sb-presenter');
  const notesEl = document.getElementById('sb-con-notes');
  const previewEl = document.getElementById('sb-con-preview');
  const posEl = document.getElementById('sb-con-pos');
  const whereEl = document.getElementById('sb-con-where');
  const timerEl = document.getElementById('sb-con-timer');
  let cursor = 0;
  let audienceWin = null;
  const clamp = (c) => Math.max(0, Math.min(BEATS.length - 1, c));
  function render() {
    const b = BEATS[cursor];
    notesEl.innerHTML = b.notesHtml || '<p class="sb-con-none">No notes for this slide.</p>';
    const next = BEATS[cursor + 1];
    previewEl.innerHTML = next ? next.slideHtml : '<p class="sb-con-none">End of deck.</p>';
    posEl.textContent = (cursor + 1) + ' / ' + BEATS.length;
    whereEl.textContent = 'Slide ' + (b.frame + 1) + ' · step ' + b.step + ' / ' + b.steps;
  }
  function goto(c) { cursor = clamp(c); render(); }
  function nav(delta) { goto(cursor + delta); ch.postMessage({ t: 'goto', cursor: cursor }); }
  ch.onmessage = (e) => {
    const m = e.data;
    if (m.t === 'goto') goto(m.cursor);
    else if (m.t === 'hello') ch.postMessage({ t: 'goto', cursor: cursor });
  };
  document.getElementById('sb-con-next').addEventListener('click', () => nav(1));
  document.getElementById('sb-con-prev').addEventListener('click', () => nav(-1));
  document.getElementById('sb-con-audience').addEventListener('click', () => {
    audienceWin = window.open('', 'sb-presenter-audience', 'width=1280,height=720');
    if (!audienceWin) return;
    audienceWin.document.open();
    audienceWin.document.write(AUDIENCE_DOC);
    audienceWin.document.close();
    audienceWin.focus();
    ch.postMessage({ t: 'goto', cursor: cursor });
  });
  addEventListener('keydown', (e) => {
    const t = e.target;
    if (t && (t.tagName === 'BUTTON')) t.blur();
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown' || e.key === 'PageDown' || e.key === ' ') { e.preventDefault(); nav(1); }
    else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp' || e.key === 'PageUp') { e.preventDefault(); nav(-1); }
    else if (e.key === 'Home') { e.preventDefault(); goto(0); ch.postMessage({ t: 'goto', cursor: cursor }); }
    else if (e.key === 'End') { e.preventDefault(); goto(BEATS.length - 1); ch.postMessage({ t: 'goto', cursor: cursor }); }
  });
  const start = Date.now();
  setInterval(() => {
    const s = Math.floor((Date.now() - start) / 1000);
    const mm = String(Math.floor(s / 60)).padStart(2, '0');
    const ss = String(s % 60).padStart(2, '0');
    timerEl.textContent = mm + ':' + ss;
  }, 1000);
  render();
})();
`.trim()

// ── window chrome CSS ────────────────────────────────────────────

const AUDIENCE_CSS = [
  '*{box-sizing:border-box;margin:0}',
  'html,body{height:100%}',
  '.sb-aud{background:#000;display:flex;align-items:center;justify-content:center;height:100%;cursor:none}',
  '.sb-aud-stage{width:min(100vw, calc(100vh * 16 / 9));aspect-ratio:16/9}',
  '.sb-aud-stage .sb-slide{width:100%;height:100%}',
  '.sb-aud-hint{position:fixed;bottom:1rem;left:50%;transform:translateX(-50%);color:#9aa;font:14px system-ui;background:rgba(0,0,0,0.6);padding:.4rem .8rem;border-radius:.4rem;transition:opacity .6s;cursor:default}',
  '.sb-aud-hint.sb-hidden{opacity:0}',
].join('\n')

const CONSOLE_CSS = [
  '*{box-sizing:border-box;margin:0}',
  'html,body{height:100%}',
  '.sb-con{display:flex;flex-direction:column;height:100%;background:#0e0f13;color:#e7e7ea;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif}',
  '.sb-con-bar{display:flex;align-items:center;gap:1rem;padding:.6rem 1rem;background:#16171d;border-bottom:1px solid #26272f}',
  '.sb-con-pos{font-weight:700;font-variant-numeric:tabular-nums}',
  '.sb-con-where{color:#a9abb6}',
  '.sb-con-timer{margin-left:auto;font-variant-numeric:tabular-nums;font-size:1.1rem}',
  '.sb-con-bar button,.sb-con-controls button{background:#2a2c36;color:#e7e7ea;border:1px solid #3a3d49;border-radius:.4rem;padding:.4rem .8rem;font:inherit;cursor:pointer}',
  '.sb-con-bar button:hover,.sb-con-controls button:hover{background:#343642}',
  '.sb-con-main{flex:1;display:flex;gap:1rem;padding:1rem;min-height:0}',
  '.sb-con-notes{flex:2;min-width:0;overflow:auto;border-radius:.5rem;padding:1rem}',
  // Notes are a full slide picture: render them exactly as on the canvas. `.sb-slide` keeps
  // its own 16:9 aspect-ratio and theme background (from slideStylesheet); we only drop the
  // canvas shadow. Never override aspect-ratio/height — that stretched it into a white panel.
  '.sb-con-notes .sb-slide{box-shadow:none}',
  '.sb-con-none{color:#8a8c96;font-style:italic}',
  '.sb-con-side{flex:1;min-width:0;display:flex;flex-direction:column;gap:.5rem}',
  '.sb-con-label{text-transform:uppercase;letter-spacing:.08em;font-size:.75rem;color:#a9abb6}',
  '.sb-con-preview{background:#000;border-radius:.5rem;aspect-ratio:16/9;overflow:hidden;display:flex;align-items:center;justify-content:center}',
  '.sb-con-preview .sb-slide{width:100%;height:100%}',
  '.sb-con-controls{display:flex;gap:.6rem;justify-content:center;padding:.6rem 1rem 1rem}',
  '.sb-con-controls button{min-width:8rem;font-size:1rem}',
].join('\n')

// ── small helpers ────────────────────────────────────────────────

/** Placeholder shown in the console window while the deck compiles + renders. */
function writePlaceholder(win: Window, title: string): void {
  replaceDocument(
    win,
    `<!doctype html><html><head><meta charset="utf-8"><title>${escapeHtml(title)} — presenter</title></head>` +
      `<body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;` +
      `background:#0e0f13;color:#e7e7ea;font:16px system-ui">Preparing presenter…</body></html>`,
  )
}

function errorDocument(message: string): string {
  return (
    `<!doctype html><html><head><meta charset="utf-8"><title>Presenter error</title></head>` +
    `<body style="margin:0;padding:2rem;background:#0e0f13;color:#e7e7ea;font:16px system-ui">` +
    `<h1 style="font-size:1.2rem">Presenter failed to start</h1><pre style="white-space:pre-wrap;color:#f2a">${escapeHtml(message)}</pre></body></html>`
  )
}

function replaceDocument(win: Window, html: string): void {
  win.document.open()
  win.document.write(html)
  win.document.close()
}

/** Embed a value as a JS literal inside a <script>, neutralising `</script>` breakout. */
function embedJson(value: unknown): string {
  return JSON.stringify(value).replace(/</g, '\\u003c')
}

/** Embed a string as a JS string literal, neutralising `</script>` breakout. */
function embedString(value: string): string {
  return JSON.stringify(value).replace(/</g, '\\u003c')
}

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}
