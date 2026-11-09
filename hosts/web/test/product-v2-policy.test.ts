import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { redactProtocolExchange } from "../src/product-v2-policy.ts";

const hostRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const productionFiles = [
  "src/protocol/product-v2.ts",
  "src/product-v2-policy.ts",
  "src/ui/product-v2-renderer.ts",
  "src/main.ts",
];

test("trace retains raw-event correlation and Haskell outcomes without authored source", () => {
  const sourceBase16 = Buffer.from("</textarea><script>bad()</script>").toString("hex");
  const trace = redactProtocolExchange(
    {
      protocol: "slideblaster.product/2", command: "pointer_event",
      event: {
        type: "move", pointerId: 9,
        modifiers: { alt: true, shift: false, control: false, meta: false },
      },
      sourceBase16,
    },
    {
      ok: true, kind: "pointer_updated", actions: [{ kind: "show_preview" }],
      workspace: {
        source: { revision: 2, base16: sourceBase16 }, selection: "alpha",
        pointer: { phase: "dragging", pointerId: 9 },
        zoom: { value: { exact: "1", number: 1 } },
        preview: {
          nodeId: "alpha", centre: { x: { exact: "81/10" }, y: { exact: "71/10" } },
          freeDrag: true, guides: [], outcome: "verified",
        },
      },
    },
  );
  assert.deepEqual(trace.response.actions, ["show_preview"]);
  assert.equal(trace.request.event.modifiers.alt, true);
  assert.equal(trace.response.preview.freeDrag, true);
  const serialized = JSON.stringify(trace);
  assert.equal(serialized.includes(sourceBase16), false);
  assert.equal(serialized.includes("</textarea>"), false);
});

test("obsolete begin/preview/commit/select command pump is absent from owned production", async () => {
  const source = await readProduction();
  for (const forbidden of [
    "begin_drag", "preview_drag", "commit_drag", "select_node",
    "gestureFlow", "pumpGesture", "decidePreviewTransition",
  ]) {
    assert.equal(source.includes(forbidden), false, `production must not contain ${forbidden}`);
  }
});

test("local gesture threshold, snap/free, and revision arithmetic are absent", async () => {
  const source = await readProduction();
  for (const pattern of [
    /dragThreshold/i,
    /Math\.hypot/,
    /revision\s*\+\s*1/,
    /freeDrag\s*=|altKey\s*\?/,
    /canUndo\s*&&|canRedo\s*&&/,
  ]) {
    assert.equal(pattern.test(source), false, `production matched forbidden policy ${pattern}`);
  }
});

test("the viewport is local browser state and never reaches the runtime", async () => {
  const viewport = await readFile(path.join(hostRoot, "src/ui/viewport.ts"), "utf8");
  for (const forbidden of [
    "protocol/product-v2.js", "productV2Dispatch", "requestViewportEvent",
    "enqueue(", "await ", "workspace.", ".revision", "sourceBase16",
  ]) {
    assert.equal(viewport.includes(forbidden), false, `the local viewport must not contain ${forbidden}`);
  }
  assert.match(viewport, /canvas\.style\.transform = `translate\(/);

  const main = await readFile(path.join(hostRoot, "src/main.ts"), "utf8");
  assert.doesNotMatch(main, /viewport_event|requestViewportEvent/);
  assert.match(main, /viewport\.zoomByWheel\(event\)/);
  assert.match(main, /viewport\.panByWheel\(event\)/);
  assert.match(main, /viewport\.applyZoomCommand\("fit_width"\)/);
  assert.match(main, /viewport\.beginPan\(event\)/);
  assert.doesNotMatch(main, /--product-zoom/);

  const styles = await readFile(path.join(hostRoot, "styles.css"), "utf8");
  assert.doesNotMatch(styles, /--product-zoom/, "zoom must not drive slide layout");
  assert.match(styles, /\.deck-canvas \{[^}]*transform-origin: 0 0/);
});

test("renderer mechanically coalesces pointermove through animation frames", async () => {
  const renderer = await readFile(path.join(hostRoot, "src/ui/product-v2-renderer.ts"), "utf8");
  assert.match(renderer, /pointermove/);
  assert.match(renderer, /requestAnimationFrame\(flushMoves\)/);
  assert.match(renderer, /pendingMoves\.set\(event\.pointerId, fact\)/);
  assert.match(renderer, /setPointerCapture/);
  assert.match(renderer, /lostpointercapture/);
  assert.match(renderer, /pointerTransport\.cancel\(pointerId, \{ type: "lost_capture"/);
  assert.match(renderer, /dragstart.*preventDefault/);
});

test("main invokes only the Product V2 JSFFI dispatch and interprets returned actions", async () => {
  const main = await readFile(path.join(hostRoot, "src/main.ts"), "utf8");
  assert.match(main, /reactor\.productV2Dispatch/);
  assert.doesNotMatch(main, /reactor\.dispatch\(|reactor\.productDispatch\(/);
  assert.match(main, /for \(const action of response\.actions\)/);
  assert.match(main, /return enqueue\(requestPointerEvent\(event\)\)/);
});

async function readProduction() {
  return (await Promise.all(
    productionFiles.map((file) => readFile(path.join(hostRoot, file), "utf8")),
  )).join("\n");
}

test("keyboard activation is forwarded through the frozen Haskell request and focus action", async () => {
  const production = await readProduction();
  assert.match(production, /requestActivateNode\(surface, nodeId\)/);
  assert.match(production, /event\.key !== "Enter" && event\.key !== " "/);
  assert.match(production, /action\.kind === "focus_node"/);
  assert.doesNotMatch(production, /selection\s*=\s*target\.dataset\.nodeId/);
});

test("source adoption is fenced and diagnostic DOM receives only redacted records", async () => {
  const main = await readFile(path.join(hostRoot, "src/main.ts"), "utf8");
  assert.match(main, /captureDraftFence\(\)/);
  assert.match(main, /currentDraftMatches\(context\.draftFence\)/);
  assert.match(main, /elements\.output\.textContent = JSON\.stringify\(trace/);
  assert.doesNotMatch(main, /elements\.output\.textContent = JSON\.stringify\(response/);
  assert.doesNotMatch(main, /dataset\.protocolTrace/);
});


test("New Slide is a visible native button with an accessible name", async () => {
  const html = await readFile(path.join(hostRoot, "index.html"), "utf8");
  const identifier = html.indexOf('id="new-slide"');
  assert.notEqual(identifier, -1);
  const start = html.lastIndexOf("<button", identifier);
  const end = html.indexOf("</button>", identifier);
  assert.notEqual(start, -1);
  assert.notEqual(end, -1);
  const button = html.slice(start, end + "</button>".length);
  const openingTag = button.slice(0, button.indexOf(">") + 1);
  assert.doesNotMatch(openingTag, /\shidden(?:\s|=|>)/);
  assert.match(button, />\s*\+ Slide\s*<\/button>/);
  assert.match(openingTag, /title="Add a slide after the current slide"/);
});

test("workspace markup contains only implemented compact commands and legacy columns", async () => {
  const html = await readFile(path.join(hostRoot, "index.html"), "utf8");
  for (const required of [
    'id="view-source"', 'id="undo"', 'id="redo"', 'id="new-slide"',
    'id="editor-pane"', 'id="deck-rail"', 'id="slide-items"',
    'id="deck-add"', 'id="deck-canvas"', 'id="zoom-control"', 'id="status"',
  ]) assert.equal(html.includes(required), true, `missing ${required}`);
  for (const forbidden of [
    "Composition surface", "Product/2 runtime", "Demo status", "Authored bytes",
    "Browser path", "Refresh state", "Apply displayed source", "Reopen fixture",
    "web wasm · product/2", "demo.slide", "Connect", 'id="present"', 'id="export"',
    'id="view-shapes"', 'id="view-files"',
  ]) assert.equal(html.includes(forbidden), false, `diagnostic/placeholder copy remains: ${forbidden}`);
});

test("source admission and slide selection remain thin Haskell requests", async () => {
  const main = await readFile(path.join(hostRoot, "src/main.ts"), "utf8");
  assert.match(main, /source\.addEventListener\("blur", \(\) => applyDraft\(\)\)/);
  assert.match(main, /requestReplaceSource\(/);
  assert.match(main, /requestSelectSlide\(item\.frame\)/);
  assert.match(main, /requestViewCommand\(event\.key === "ArrowUp"/);
  assert.doesNotMatch(main, /fromMarkdown|parsePicture|activeIndex\s*[+\-]/);
});
