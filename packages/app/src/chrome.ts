/**
 * Shared workspace chrome. Contract: see chrome.md.
 *
 * The app shell markup (app bar, code/deck workspace, navigator rail, zoom control,
 * status bar) that every shell mounts identically. Lifted out of each shell's
 * index.html so the two shells (web, desktop) share one DOM structure — the element
 * IDs the controller (createApp.ts) queries live here. `shellTag` is the only
 * per-shell text (e.g. "web-shell · M2" vs "desktop · M5").
 */

/** Render the workspace chrome into `root`, returning it for chaining. */
export function renderChrome(root: HTMLElement, opts: { shellTag: string }): HTMLElement {
  root.classList.add('app')
  root.innerHTML = `
    <header class="app-bar">
      <span class="app-name">SlideBlaster</span>
      <span class="app-doc" id="doc-title"></span>
      <div class="tool-actions" role="group" aria-label="Tools">
        <button type="button" id="undo" aria-label="Undo" title="Undo (Ctrl+Z)">Undo</button>
        <button type="button" id="redo" aria-label="Redo" title="Redo (Ctrl+Shift+Z)">Redo</button>
        <button type="button" id="connect-toggle" aria-pressed="false">&rarr; Connect</button>
      </div>
      <div class="step-actions" id="step-control" role="group" aria-label="Overlay step" hidden>
        <button type="button" data-step="prev" aria-label="Previous step" title="Previous step (,)">&lsaquo;</button>
        <span id="step-readout" title="Overlay step of the active slide">All</span>
        <button type="button" data-step="next" aria-label="Next step" title="Next step (.)">&rsaquo;</button>
      </div>
      <div class="present-actions" id="present-actions" role="group" aria-label="Present">
        <button type="button" id="present" title="Present: open audience + speaker-notes windows">Present</button>
      </div>
      <div class="export-actions" id="export-actions" role="group" aria-label="Export">
        <button type="button" data-export="print">Print / PDF</button>
        <button type="button" data-export="html">Export HTML</button>
      </div>
      <span class="app-tag">${escapeText(opts.shellTag)}</span>
    </header>
    <main class="workspace">
      <aside class="side-panel" id="side-panel" aria-label="Workspace" hidden>
        <div class="side-section" id="file-tree"></div>
        <div class="side-section side-section-grow" id="git-panel"></div>
      </aside>
      <div class="gutter" id="side-resizer" role="separator" aria-orientation="vertical" aria-label="Resize file panel" tabindex="0"></div>
      <section class="editor">
        <div class="editor-head" id="editor-head">sample.slideBlaster.md</div>
        <div class="code-host" id="code"></div>
      </section>
      <div class="gutter" id="editor-resizer" role="separator" aria-orientation="vertical" aria-label="Resize editor" tabindex="0"></div>
      <nav class="deck-rail" id="deck-rail" aria-label="Slides" hidden></nav>
      <section class="preview">
        <div class="deck" id="deck"></div>
        <aside class="props-panel" id="props" aria-label="Properties" hidden></aside>
        <div class="zoom-control" id="zoom-control">
          <button type="button" data-zoom="out" aria-label="Zoom out">&minus;</button>
          <button type="button" data-zoom="reset" id="zoom-readout">100%</button>
          <button type="button" data-zoom="in" aria-label="Zoom in">+</button>
          <button type="button" data-zoom="fit" aria-label="Fit width">Fit</button>
        </div>
        <div class="parse-error" id="error" hidden></div>
        <div class="status-bar" id="status"></div>
      </section>
    </main>`
  return root
}

function escapeText(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
