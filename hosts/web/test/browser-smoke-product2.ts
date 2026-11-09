// @ts-nocheck -- legacy Product/2 CDP smoke, ported verbatim from JS; typed rewrite is a known gap.
import assert from "node:assert/strict";
import { constants as fsConstants } from "node:fs";
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const hostRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fixturePath = path.join(hostRoot, "fixtures", "demo.slide");
const timeoutMilliseconds = 20_000;
const mimeTypes = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".tikz", "application/octet-stream"],
  [".wasm", "application/wasm"],
]);

let browser: any = null;
let profile: any = null;
let server: any = null;
let cdp: any = null;
let cleanupPromise: any = null;

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => {
    void cleanupResources("SIGKILL").then(
      () => process.exit(128),
      (error) => {
        console.error(error);
        process.exit(1);
      },
    );
  });
}

async function main() {
  try {
    const executable = await findBrowser();
    if (executable === null) {
      console.log("SKIP browser smoke: no compatible Chrome or Chromium executable is installed");
      process.exitCode = 0;
    } else {
      await runSmoke(executable);
    }
  } finally {
    await cleanupResources("SIGTERM");
  }
}

async function runSmoke(executable) {
  const fixture = await readFile(fixturePath);
  const fixtureBase16 = fixture.toString("hex");
  const expectedHeadlineMoved = replaceOnce(fixture, Buffer.from("(headline) at (1,8)"), Buffer.from("(headline) at (3,7)"));
  const expectedMoved = replaceOnce(fixture, Buffer.from("(source) at (11,7)"), Buffer.from("(source) at (12,6)"));

  const externalPageUrl = process.env.SLIDEBLASTER_BROWSER_URL;
  let pageUrl;
  if (externalPageUrl === undefined) {
    server = createServer();
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    assert(address !== null && typeof address === "object");
    pageUrl = `http://127.0.0.1:${address.port}/?productV2Test=1`;
  } else {
    const url = new URL(externalPageUrl);
    url.searchParams.set("productV2Test", "1");
    pageUrl = url.href;
  }

  profile = await mkdtemp(path.join(tmpdir(), "slideblaster-browser-smoke-"));
  const browserErrors = [];
  browser = spawn(executable, [
    "--headless=new", "--disable-background-networking", "--disable-component-update",
    "--disable-default-apps", "--disable-extensions", "--disable-sync",
    "--metrics-recording-only", "--no-first-run", "--no-default-browser-check",
    "--remote-debugging-port=0", `--user-data-dir=${profile}`, "about:blank",
  ], { stdio: ["ignore", "ignore", "pipe"] });
  browser.stderr.setEncoding("utf8");
  browser.stderr.on("data", (chunk) => browserErrors.push(chunk));

  const debuggingPort = await waitForDebuggingPort(profile, browser, browserErrors);
  const target = await createTarget(debuggingPort, "about:blank");
  cdp = await Cdp.connect(target.webSocketDebuggerUrl);
  const pageErrors = [];
  cdp.on("Runtime.exceptionThrown", (event) => pageErrors.push(`exception: ${event.exceptionDetails.text}`));
  cdp.on("Runtime.consoleAPICalled", (event) => {
    if (event.type === "error" || event.type === "assert") pageErrors.push(`console.${event.type}: ${event.args.map(remoteText).join(" ")}`);
  });
  cdp.on("Log.entryAdded", (event) => {
    if (event.entry.level === "error") pageErrors.push(`log: ${event.entry.text}`);
  });
  await Promise.all([
    cdp.send("Page.enable"), cdp.send("Runtime.enable"), cdp.send("Log.enable"),
    cdp.send("Emulation.setDeviceMetricsOverride", {
      width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false,
    }),
  ]);
  await cdp.send("Page.navigate", { url: pageUrl });

  const initial = await waitForState(
    (state) => state?.readiness === "ready" && state.authority === "writable" && state.lease === "writable",
    "initial exact demo deck",
  );
  assert.equal(initial.sourceBase16, fixtureBase16);
  assert.equal(initial.revision, 0);
  assert.equal(initial.navigator.count, 3);
  assert.equal(initial.navigator.activeFrame, "opening");
  assert.deepEqual(initial.navigator.items, ["opening", "questions", "finish"]);
  assert.equal(initial.navigator.thumbCount, 3);
  assert.equal(initial.navigator.cardCount, 3);
  assert.equal(initial.navigator.notesCount, 3);
  assert.equal(initial.navigator.verticalRail, true);
  assertFaithfulThumbnails(initial);
  assert.equal(initial.overflow, false);

  const focalBefore = centerOf(initial.headlineTarget, initial.canvas);
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseWheel", x: focalBefore.x, y: focalBefore.y, deltaX: 0, deltaY: -100, modifiers: 2,
  });
  const wheelZoomed = await waitForState((state) => state?.zoom > initial.zoom, "cursor-centred Ctrl-wheel zoom");
  const focalAfter = centerOf(wheelZoomed.headlineTarget, wheelZoomed.canvas);
  assert(Math.abs(focalAfter.x - focalBefore.x) <= 1, `wheel focal x drifted: ${focalAfter.x - focalBefore.x}`);
  assert(Math.abs(focalAfter.y - focalBefore.y) <= 1, `wheel focal y drifted: ${focalAfter.y - focalBefore.y}`);
  assert.equal(wheelZoomed.revision, initial.revision, "wheel zoom changed source revision");

  const burstStartedAt = Date.now();
  for (let sample = 0; sample < 40; sample += 1) {
    await cdp.send("Input.dispatchMouseEvent", {
      type: "mouseWheel", x: focalBefore.x, y: focalBefore.y, deltaX: 0, deltaY: -4, modifiers: 2,
    });
  }
  const expectedBurstZoom = wheelZoomed.zoom * Math.exp(4 * 0.0014) ** 40;
  const burstSettled = await waitForState(
    (state) => state !== null && Math.abs(state.zoom - expectedBurstZoom) < 1e-6,
    "every wheel sample applied without coalescing loss",
  );
  assert(Date.now() - burstStartedAt < 2000, "a 40-sample wheel burst must apply immediately");
  assert.equal(burstSettled.revision, initial.revision, "wheel burst changed source revision");
  assert.equal(
    burstSettled.trace.some((entry) => entry.request.command === "viewport_event"),
    false,
    "the viewport is local browser state and must not dispatch to the runtime",
  );
  const burstFocal = centerOf(burstSettled.headlineTarget, burstSettled.canvas);
  assert(Math.abs(burstFocal.x - focalBefore.x) <= 1.5, `burst focal x drifted: ${burstFocal.x - focalBefore.x}`);
  assert(Math.abs(burstFocal.y - focalBefore.y) <= 1.5, `burst focal y drifted: ${burstFocal.y - focalBefore.y}`);

  const wheelPanned = await (async () => {
    await cdp.send("Input.dispatchMouseEvent", {
      type: "mouseWheel", x: focalBefore.x, y: focalBefore.y, deltaX: 0, deltaY: 120,
    });
    return waitForState(
      (state) => state?.viewport.offsetY !== burstSettled.viewport.offsetY,
      "plain wheel pans the canvas",
    );
  })();
  assert.equal(wheelPanned.zoom, burstSettled.zoom, "plain wheel must not zoom");

  await clickAt(wheelPanned.zoomIn);
  const buttonZoomed = await waitForState((state) => state?.zoom > wheelPanned.zoom, "button centre zoom");
  await clickAt(buttonZoomed.zoomReadout);
  const reset = await waitForState((state) => state?.zoom === 1, "percentage reset");
  await clickAt(reset.zoomFit);
  const fitted = await waitForState((state) => state?.zoom !== reset.zoom, "Fit width");
  assert(Math.abs(fitted.activeSlide.width - fitted.deck.clientWidth * 0.98) <= 2,
    `Fit width mismatch: ${JSON.stringify({ slide: fitted.activeSlide.width, deck: fitted.deck.clientWidth })}`);

  for (let count = 0; count < 4; count += 1) {
    const before = await readState();
    await clickAt(before.zoomIn);
    await waitForState((state) => state?.zoom > before.zoom, `pan setup zoom ${count + 1}`);
  }
  const panReady = await readState();
  const panStart = { x: panReady.deck.left + panReady.deck.width / 2, y: panReady.deck.top + panReady.deck.height / 2 };
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...panStart, buttons: 0 });
  await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", ...panStart, button: "middle", buttons: 4, clickCount: 1 });
  await waitForState((state) => state?.viewportPanning === true, "middle pan capture");
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: panStart.x - 90, y: panStart.y - 70, button: "middle", buttons: 4 });
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: panStart.x - 90, y: panStart.y - 70, button: "middle", buttons: 0, clickCount: 1 });
  const middlePanned = await waitForState(
    (state) => state?.viewportPanning === false
      && (state.viewport.offsetX !== panReady.viewport.offsetX || state.viewport.offsetY !== panReady.viewport.offsetY),
    "middle-drag pan settlement",
  );
  assert.equal(middlePanned.revision, initial.revision, "middle pan changed source revision");
  assert.equal(middlePanned.zoom, panReady.zoom, "panning must not change zoom");

  await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", key: " ", code: "Space" });
  const spaceStart = { x: panStart.x + 30, y: panStart.y + 20 };
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...spaceStart, buttons: 0 });
  await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", ...spaceStart, button: "left", buttons: 1, clickCount: 1 });
  await waitForState((state) => state?.viewportPanning === true, "Space+primary pan capture");
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: spaceStart.x + 65, y: spaceStart.y + 45, button: "left", buttons: 1 });
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: spaceStart.x + 65, y: spaceStart.y + 45, button: "left", buttons: 0, clickCount: 1 });
  await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: " ", code: "Space" });
  const spacePanned = await waitForState((state) => state?.viewportPanning === false, "Space pan settlement");
  assert.equal(spacePanned.revision, initial.revision, "Space pan changed source revision");
  await clickAt(spacePanned.zoomReadout);
  const navigationReset = await waitForState((state) => state?.zoom === 1, "reset after pan");

  await press(navigationReset.headlineTarget, navigationReset.canvas);
  await waitForState(
    (state) => state?.pointerPhase === "pressed" && state.selection === "headline" && state.hasCapture,
    "unselected real headline press",
  );
  await observePreviewDuringBurst();
  const headlinePoints = interpolateSlidePoints([2.1, 7.4], [4, 6.5], 36);
  await burstPointerMoves(navigationReset.canvas, headlinePoints, 0);
  await releasePointer(slidePoint(navigationReset.canvas, 4, 6.5), 0);
  const headlineMoved = await waitForState(
    (state) => state?.revision === initial.revision + 1
      && state.pointerPhase === "idle"
      && state.lease === "writable",
    "verified real headline burst",
  );
  assert.equal(headlineMoved.previewObserved, true, "headline burst must produce a visible Haskell preview");
  assert.equal(headlineMoved.sourceBase16, expectedHeadlineMoved.toString("hex"));
  assert.equal(
    headlineMoved.trace.some((entry) => entry.response.kind === "pointer_preview_rejected"),
    false,
    "headline threshold crossing must not reject preview",
  );
  await clickAt(headlineMoved.undo);
  const headlineUndone = await waitForState(
    (state) => state?.sourceBase16 === fixtureBase16 && state.revision > headlineMoved.revision,
    "exact real headline undo",
  );

  await clickAt(headlineUndone.navigator.thumbBoxes[1]);
  const questionsByThumb = await waitForState(
    (state) => state?.navigator.activeFrame === "questions" && state.renderFrame === "questions",
    "Haskell thumbnail selection",
  );
  assert.equal(questionsByThumb.revision, headlineUndone.revision);
  assert(questionsByThumb.trace.some((entry) => entry.request.command === "select_slide"));
  await clickAt(questionsByThumb.navigator.thumbBoxes[0]);
  const opening = await waitForState(
    (state) => state?.navigator.activeFrame === "opening" && state.renderFrame === "opening",
    "return to opening through Haskell",
  );

  const canceled = await cancelTouchPointer(opening);
  assert.equal(canceled.sourceBase16, fixtureBase16);
  assert.equal(canceled.revision, opening.revision);
  assert.equal(canceled.pointerPhase, "idle");
  assert.equal(canceled.hasCapture, false);

  await press(canceled.sourceTarget, canceled.canvas);
  await waitForState(
    (state) => state?.pointerPhase === "pressed" && state.selection === "source" && state.hasCapture,
    "unselected source node press",
  );
  await observePreviewDuringBurst();
  const naturalPoints = interpolateSlidePoints([11.2, 6.8], [12, 6], 36);
  await burstPointerMoves(opening.canvas, naturalPoints, 0);
  await releasePointer(slidePoint(opening.canvas, 12, 6), 0);
  const moved = await waitForState(
    (state) => state?.revision === opening.revision + 1 && state.pointerPhase === "idle" && state.lease === "writable",
    "verified natural burst parent-lifted edit",
  );
  assert.equal(moved.previewObserved, true, "the burst must produce a visible Haskell preview before commit");
  assert.equal(moved.sourceBase16, expectedMoved.toString("hex"));
  assert.equal(moved.revision, opening.revision + 1, "one burst produces exactly one revision");
  assert.equal(moved.canUndo, true);

  await clickAt(moved.undo);
  const editUndone = await waitForState(
    (state) => state?.sourceBase16 === fixtureBase16 && state.revision > moved.revision,
    "exact natural burst undo",
  );

  await observePreviewDuringBurst();
  await press(editUndone.sourceTarget, editUndone.canvas);
  const fallbackPoints = interpolateSlidePoints([8, 7], [8.8, 5], 36);
  await burstPointerMoves(editUndone.canvas, fallbackPoints, 0);
  await releasePointer(slidePoint(editUndone.canvas, 8.8, 5), 0);
  const fallbackCommitted = await waitForState(
    (state) => state?.revision === editUndone.revision + 1 && state.pointerPhase === "idle" && state.canUndo,
    "unprojectable-snap fallback burst commit",
  );
  assert.equal(fallbackCommitted.previewObserved, true);
  assert.equal(fallbackCommitted.fallbackObserved, true, "Haskell fallback must become visible during the burst");
  assert.equal(fallbackCommitted.fallbackNoGuides, true, "fallback preview must remain guide-free");
  await clickAt(fallbackCommitted.undo);
  const fallbackUndone = await waitForState(
    (state) => state?.sourceBase16 === fixtureBase16 && state.revision > fallbackCommitted.revision,
    "exact fallback burst undo",
  );

  const altDestination = slidePoint(fallbackUndone.canvas, 12.4, 6.4);
  await press(fallbackUndone.sourceTarget, fallbackUndone.canvas);
  await movePointer(altDestination, 1);
  const altPreview = await waitForState(
    (state) => state?.pointerPhase === "dragging" && state.preview?.freeDrag === true,
    "explicit Alt free drag",
  );
  assert.deepEqual(altPreview.preview.guides, []);
  await releasePointer(altDestination, 1);
  const altCommitted = await waitForState(
    (state) => state?.revision > fallbackUndone.revision && state.pointerPhase === "idle" && state.canUndo,
    "explicit Alt commit",
  );
  await clickAt(altCommitted.undo);
  const altUndone = await waitForState(
    (state) => state?.sourceBase16 === fixtureBase16 && state.revision > altCommitted.revision,
    "explicit Alt exact undo",
  );

  await clickAt(altUndone.navigator.thumbBoxes[1]);
  const insertionBase = await waitForState(
    (state) => state?.navigator.activeFrame === "questions" && state.renderFrame === "questions",
    "questions selected before insertion",
  );
  await clickAt(insertionBase.deckAdd);
  const inserted = await waitForState(
    (state) => state?.navigator.count === 4 && state.navigator.activeFrame === "slide-4" && state.renderFrame === "slide-4",
    "New slide from rail",
  );
  const insertedBytes = inserted.sourceBase16;
  assert.equal(inserted.navigator.thumbCount, 4);
  assert.equal(inserted.navigator.cardCount, 4);
  await clickAt(inserted.undo);
  const insertionUndone = await waitForState(
    (state) => state?.sourceBase16 === fixtureBase16 && state.navigator.count === 3 && state.navigator.activeFrame === "questions",
    "exact New Slide undo",
  );
  await clickAt(insertionUndone.redo);
  const insertionRedone = await waitForState(
    (state) => state?.sourceBase16 === insertedBytes && state.navigator.count === 4 && state.navigator.activeFrame === "slide-4",
    "exact New Slide redo",
  );
  await clickAt(insertionRedone.undo);
  const baseline = await waitForState(
    (state) => state?.sourceBase16 === fixtureBase16 && state.navigator.count === 3,
    "restore baseline after redo proof",
  );

  await holdNextDispatch();
  await clickAt(baseline.navigator.thumbBoxes[1]);
  await waitForState((state) => state?.dispatchHeld === true, "held slide-selection dispatch");
  const newerDraft = `${baseline.sourceValue}\n`;
  await setSourceDraft(newerDraft);
  await releaseHeldDispatch();
  const raced = await waitForState(
    (state) => state?.draftDirty === true && state.sourceValue === newerDraft,
    "dirty draft survives older response",
  );
  assert.equal(raced.sourceBase16, fixtureBase16);
  await evaluate(`(() => { const source = document.querySelector("#source"); source.focus(); source.blur(); })()`);
  const applied = await waitForState(
    (state) => state?.draftDirty === false && state.sourceValue === newerDraft && state.revision > raced.revision,
    "quiet blur source apply",
  );

  const forbiddenCopy = [
    "Composition surface", "Product/2 runtime", "Demo status",
    "Haskell accepted", "Authored bytes", "Revision 0", "Browser path",
    "No snap guides", "web wasm", "Refresh state", "Apply displayed source", "Reopen fixture",
    "demo.slide",
  ];
  for (const copy of forbiddenCopy) assert.equal(applied.visibleText.includes(copy), false, `visible diagnostic copy: ${copy}`);
  assert.equal(applied.overflow, false);
  for (const width of [820, 560, 390]) {
    await cdp.send("Emulation.setDeviceMetricsOverride", {
      width, height: 844, deviceScaleFactor: 1, mobile: false,
    });
    await delay(100);
    const narrow = await readState();
    assert.equal(narrow.overflow, false, `${width}px viewport must not overflow`);
    assert.equal(narrow.navigator.thumbCount, 3);
    assert.equal(narrow.navigator.cardCount, 3);
    assert.equal(narrow.navigator.verticalRail, true, `${width}px rail must remain vertical`);
    assertFaithfulThumbnails(narrow);
  }

  const stale = await runIsolatedStaleRequest(fixtureBase16);
  assert.equal(stale.errorCode, "stale_revision");
  assert.equal(stale.sourcePreserved, true);
  assert.equal(stale.revisionPreserved, true);
  assert.deepEqual(pageErrors, [], "browser and console must report zero errors");

  const commands = applied.trace.map((entry) => entry.request.command);
  for (const expected of ["pointer_event", "select_slide", "new_slide", "undo", "redo", "replace_source"]) {
    assert(commands.includes(expected), `trace must include ${expected}`);
  }
  for (const obsolete of ["begin_drag", "preview_drag", "commit_drag", "select_node", "viewport_event"]) {
    assert.equal(commands.includes(obsolete), false);
  }
  console.log(`PASS browser smoke (${path.basename(executable)}): local cursor zoom/pan/Fit, exact node/history/New Slide, responsive width, and 0 errors`);
}

function assertFaithfulThumbnails(state) {
  assert.equal(state.navigator.thumbCardBoxes.length, state.navigator.cardCount);
  assert.deepEqual(state.navigator.thumbGeometryCounts, state.navigator.cardGeometryCounts);
  for (const box of state.navigator.thumbCardBoxes) {
    assert(box.width >= 80, `thumbnail must not collapse: ${JSON.stringify(box)}`);
    assert(Math.abs(box.width / box.height - 16 / 9) < 0.05, `thumbnail must remain 16:9: ${JSON.stringify(box)}`);
  }
}
async function runIsolatedStaleRequest(fixtureBase16) {
  return evaluate(`(async () => {
    const [{ loadSlideBlasterReactor }, protocol] = await Promise.all([
      import(new URL("./dist/src/wasm/load-reactor.js", location.href).href),
      import(new URL("./dist/src/protocol/product-v2.js", location.href).href),
    ]);
    const reactor = await loadSlideBlasterReactor();
    const dispatch = async (request) => protocol.decodeProductV2Response(
      await reactor.productV2Dispatch(JSON.stringify(request)),
    );
    const opened = await dispatch(protocol.requestOpenSource(${JSON.stringify(fixtureBase16)}));
    await dispatch(protocol.requestAcknowledgePaint(opened.workspace.renderOffer.fence));
    const stale = await dispatch(protocol.requestReplaceSource(99, ${JSON.stringify(fixtureBase16)}));
    const snapshot = await dispatch(protocol.requestWorkspaceSnapshot());
    return {
      errorCode: stale.ok ? null : stale.error.code,
      sourcePreserved: snapshot.workspace.source.base16 === ${JSON.stringify(fixtureBase16)},
      revisionPreserved: snapshot.workspace.source.revision === 0,
    };
  })()`);
}

function createServer() {
  return http.createServer(async (request, response) => {
    try {
      const requestUrl = new URL(request.url ?? "/", "http://127.0.0.1");
      if (requestUrl.pathname === "/favicon.ico") {
        response.writeHead(204).end();
        return;
      }
      const relative = requestUrl.pathname === "/" ? "index.html" : requestUrl.pathname.slice(1);
      const filePath = path.resolve(hostRoot, relative);
      if (filePath !== hostRoot && !filePath.startsWith(`${hostRoot}${path.sep}`)) {
        response.writeHead(403).end("Forbidden");
        return;
      }
      const body = await readFile(filePath);
      response.writeHead(200, {
        "Content-Type": mimeTypes.get(path.extname(filePath)) ?? "application/octet-stream",
        "Cache-Control": "no-store",
      });
      response.end(body);
    } catch (error) {
      response.writeHead(error?.code === "ENOENT" ? 404 : 500).end("Not found");
    }
  });
}

async function findBrowser() {
  const names = [
    ...(process.env.CHROME_BIN ? [process.env.CHROME_BIN] : []),
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "chromium-browser",
  ];
  const directories = (process.env.PATH ?? "").split(path.delimiter);
  for (const name of names) {
    const candidates = path.isAbsolute(name) ? [name] : directories.map((directory) => path.join(directory, name));
    for (const candidate of candidates) {
      try {
        await access(candidate, fsConstants.X_OK);
        return candidate;
      } catch {
        // Try the next installed-browser candidate.
      }
    }
  }
  return null;
}

async function waitForDebuggingPort(directory, child, errors) {
  const portFile = path.join(directory, "DevToolsActivePort");
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`Chrome exited before CDP was ready (${child.exitCode}):\n${errors.join("")}`);
    }
    try {
      const [port] = (await readFile(portFile, "utf8")).trim().split("\n");
      if (/^[0-9]+$/.test(port)) {
        return Number(port);
      }
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    await delay(50);
  }
  throw new Error(`Timed out waiting for Chrome CDP:\n${errors.join("")}`);
}

async function createTarget(port, pageUrl) {
  const response = await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(pageUrl)}`, { method: "PUT" });
  if (!response.ok) {
    throw new Error(`Chrome target creation failed with HTTP ${response.status}`);
  }
  return response.json();
}

async function waitForState(predicate, description) {
  const deadline = Date.now() + timeoutMilliseconds;
  let latest = null;
  while (Date.now() < deadline) {
    latest = await readState();
    if (predicate(latest)) return latest;
    await delay(50);
  }
  throw new Error(`Timed out waiting for ${description}; latest state: ${JSON.stringify(latest)}`);
}

async function readState() {
  return evaluate(`(async () => {
    const activeFrame = document.querySelector(".deck-row.is-current")?.dataset.frame;
    const root = activeFrame === undefined ? null : document.querySelector(
      '.deck-row[data-frame="' + CSS.escape(activeFrame) + '"] .deck-slide > .product-v2-render-surface:not(.static-surface)'
    );
    const source = document.querySelector("#source");
    if (!root || !source) return null;
    const testApi = await import(new URL("./dist/src/main.js", location.href).href);
    const testState = testApi.readProductV2TestState();
    const workspace = testState.workspace;
    if (workspace === null) return null;
    const box = (element) => {
      if (!element) return null;
      const value = element.getBoundingClientRect();
      return { left: value.left, top: value.top, width: value.width, height: value.height };
    };
    const headlineTarget = root.querySelector('.product-v2-node-target[data-node-id="headline"]');
    const sourceTarget = root.querySelector('.product-v2-node-target[data-node-id="source"]');
    const pointerId = Number(root.dataset.smokePointerId);
    const exactNumber = (value) => value === null || value === undefined
      ? null
      : typeof value === "object" ? value.number : Number(value);
    const thumbs = Array.from(document.querySelectorAll(".slide-thumb"));
    const thumbCards = Array.from(document.querySelectorAll(".thumb-card"));
    const cards = Array.from(document.querySelectorAll(".deck-row"));
    const geometryCount = (element) => element.querySelectorAll(
      ".product-v2-rectangle, .product-v2-connector",
    ).length;
    const railStyle = getComputedStyle(document.querySelector("#slide-items"));
    return {
      revision: workspace.source.revision,
      sourceBase16: workspace.source.base16,
      readiness: workspace.readiness,
      authority: workspace.authority,
      selection: workspace.selection,
      canUndo: workspace.canUndo,
      canRedo: workspace.canRedo,
      pointerPhase: workspace.pointer.phase,
      zoom: testState.viewport.zoom,
      viewport: testState.viewport,
      viewportPanning: testState.viewport.panning,
      preview: workspace.preview === null ? null : {
        nodeId: workspace.preview.nodeId,
        centre: { x: exactNumber(workspace.preview.centre.x), y: exactNumber(workspace.preview.centre.y) },
        freeDrag: workspace.preview.freeDrag,
        guides: workspace.preview.guides.map((guide) => guide.kind),
        outcome: workspace.preview.outcome,
      },
      navigator: {
        active: workspace.navigator.activeIndex,
        activeFrame: workspace.navigator.activeFrame,
        count: workspace.navigator.slideCount,
        items: workspace.navigator.items.map((item) => item.frame),
        thumbCount: thumbs.length,
        cardCount: cards.length,
        notesCount: document.querySelectorAll(".deck-note").length,
        thumbBoxes: thumbs.map(box),
        thumbCardBoxes: thumbCards.map(box),
        thumbGeometryCounts: thumbCards.map(geometryCount),
        cardGeometryCounts: cards.map((row) => geometryCount(row.querySelector(".deck-slide"))),
        verticalRail: railStyle.flexDirection === "column",
      },
      renderFrame: workspace.displayedRender?.fence?.surface?.frame
        ?? workspace.renderOffer?.fence?.surface?.frame ?? null,
      trace: testState.trace,
      dispatchHeld: testState.dispatchHeld,
      draftDirty: testState.draft.dirty,
      sourceValue: source.value,
      lease: root.dataset.lease,
      canvas: box(root),
      deck: (() => {
        const deck = document.querySelector("#deck");
        return { ...box(deck), scrollLeft: deck.scrollLeft, scrollTop: deck.scrollTop, clientWidth: deck.clientWidth };
      })(),
      activeSlide: box(document.querySelector(".deck-row.is-current .deck-slide")),
      headlineTarget: box(headlineTarget),
      sourceTarget: box(sourceTarget),
      undo: box(document.querySelector("#undo")),
      redo: box(document.querySelector("#redo")),
      deckAdd: box(document.querySelector("#deck-add")),
      zoomIn: box(document.querySelector("#zoom-in")),
      zoomReadout: box(document.querySelector("#zoom-readout")),
      zoomFit: box(document.querySelector("#zoom-fit")),
      visibleText: document.body.innerText,
      overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth
        || document.body.scrollWidth > document.body.clientWidth,
      lastPointerId: Number.isSafeInteger(pointerId) ? pointerId : null,
      hasCapture: Number.isSafeInteger(pointerId) && Array.from(
        root.querySelectorAll(".product-v2-node-target"),
      ).some((node) => node.hasPointerCapture(pointerId)),
      previewObserved: window.__productV2BurstObservation?.preview === true,
      fallbackObserved: window.__productV2BurstObservation?.fallback === true,
      fallbackNoGuides: window.__productV2BurstObservation?.fallbackNoGuides === true,
    };
  })()`);
}
async function captureScreenshot(directory, name) {
  if (directory === null) return;
  const result = await cdp.send("Page.captureScreenshot", {
    format: "png",
    fromSurface: true,
    captureBeyondViewport: false,
  });
  const destination = path.join(directory, name);
  await writeFile(destination, Buffer.from(result.data, "base64"));
}

async function clickAt(box, clippingBox = null) {
  const { x, y } = centerOf(box, clippingBox);
  await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", buttons: 1, clickCount: 1 });
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", buttons: 0, clickCount: 1 });
}

async function drag(box, destination, clippingBox) {
  const start = centerOf(box, clippingBox);
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...start, buttons: 0 });
  await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", ...start, button: "left", buttons: 1, clickCount: 1 });
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: destination.x, y: destination.y, button: "left", buttons: 1 });
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: destination.x, y: destination.y, button: "left", buttons: 0, clickCount: 1 });
}

async function cancelTouchPointer(state) {
  const start = centerOf(state.sourceTarget, state.canvas);
  await evaluate(`(() => {
    window.__productV2PointerCancelCount = 0;
    const root = document.querySelector(".deck-row.is-current .deck-slide > .product-v2-render-surface:not(.static-surface)");
    root.addEventListener("pointercancel", () => { window.__productV2PointerCancelCount += 1; }, { once: true });
  })()`);
  await cdp.send("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 1 });
  try {
    await cdp.send("Input.dispatchTouchEvent", {
      type: "touchStart",
      touchPoints: [{ x: start.x, y: start.y, radiusX: 1, radiusY: 1, force: 1, id: 51 }],
    });
    await waitForState(
      (current) => current?.pointerPhase === "pressed" && current.selection === "source",
      "real touch pointer press before cancel",
    );
    let previousPreview = null;
    for (const [x, y] of interpolateSlidePoints([11.15, 6.85], [11.7, 6.3], 5)) {
      const point = slidePoint(state.canvas, x, y);
      await cdp.send("Input.dispatchTouchEvent", {
        type: "touchMove",
        touchPoints: [{ x: point.x, y: point.y, radiusX: 1, radiusY: 1, force: 1, id: 51 }],
      });
      const moved = await waitForState(
        (current) => current?.pointerPhase === "dragging"
          && current.preview !== null
          && JSON.stringify(current.preview.centre) !== previousPreview,
        "stepwise Haskell touch preview",
      );
      previousPreview = JSON.stringify(moved.preview.centre);
    }
    await cdp.send("Input.dispatchTouchEvent", { type: "touchCancel", touchPoints: [] });
    const canceled = await waitForState(
      (current) => current?.pointerPhase === "idle" && current.lease === "writable",
      "real Chrome pointercancel settlement",
    );
    assert.equal(await evaluate("window.__productV2PointerCancelCount"), 1);
    return canceled;
  } finally {
    await cdp.send("Emulation.setTouchEmulationEnabled", { enabled: false });
  }
}

function centerOf(box, clippingBox) {
  if (clippingBox === null) {
    return { x: box.left + box.width / 2, y: box.top + box.height / 2 };
  }
  const left = Math.max(box.left, clippingBox.left);
  const top = Math.max(box.top, clippingBox.top);
  const right = Math.min(box.left + box.width, clippingBox.left + clippingBox.width);
  const bottom = Math.min(box.top + box.height, clippingBox.top + clippingBox.height);
  assert(right > left && bottom > top, `pointer target must intersect canvas: ${JSON.stringify({ box, clippingBox })}`);
  return { x: (left + right) / 2, y: (top + bottom) / 2 };
}

async function evaluate(expression: string): Promise<any> {
  const result = await cdp.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (result.exceptionDetails) {
    throw new Error(`Browser evaluation failed: ${result.exceptionDetails.text}`);
  }
  return result.result.value;
}

async function press(box, clippingBox) {
  const start = centerOf(box, clippingBox);
  await evaluate(`(() => {
    const root = document.querySelector(".deck-row.is-current .deck-slide > .product-v2-render-surface:not(.static-surface)");
    root.addEventListener("pointerdown", (event) => {
      root.dataset.smokePointerId = String(event.pointerId);
    }, { once: true, capture: true });
  })()`);
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...start, buttons: 0 });
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mousePressed", ...start, button: "left", buttons: 1, clickCount: 1,
  });
  const pointerId = await evaluate("Number(document.querySelector('.deck-row.is-current .deck-slide > .product-v2-render-surface:not(.static-surface)').dataset.smokePointerId)");
  assert(Number.isSafeInteger(pointerId));
  return pointerId;
}

async function observePreviewDuringBurst() {
  await evaluate(`(() => {
    window.__productV2BurstObservation = { preview: false, fallback: false, fallbackNoGuides: false };
    const inspect = () => {
      const ghost = document.querySelector(".deck-row.is-current .product-v2-node-ghost");
      if (ghost === null) return;
      window.__productV2BurstObservation.preview = true;
      if (ghost.dataset.previewFreeDrag === "true") {
        window.__productV2BurstObservation.fallback = true;
        window.__productV2BurstObservation.fallbackNoGuides = document.querySelectorAll(
          ".deck-row.is-current .product-v2-guide",
        ).length === 0;
      }
    };
    new MutationObserver(inspect).observe(document.querySelector("#deck-canvas"), {
      attributes: true, childList: true, subtree: true,
    });
    inspect();
  })()`);
}

async function burstPointerMoves(canvas, points, modifiers) {
  assert(points.length >= 30, "a physical regression burst requires at least 30 moves");
  for (const [x, y] of points) await movePointer(slidePoint(canvas, x, y), modifiers);
}

function interpolateSlidePoints(start, end, count) {
  return Array.from({ length: count }, (_, index) => {
    const ratio = count === 1 ? 1 : index / (count - 1);
    return [
      start[0] + (end[0] - start[0]) * ratio,
      start[1] + (end[1] - start[1]) * ratio,
    ];
  });
}

async function movePointer(destination, modifiers = 0) {
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseMoved", x: destination.x, y: destination.y,
    button: "left", buttons: 1, modifiers,
  });
}

async function releasePointer(destination, modifiers = 0) {
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseReleased", x: destination.x, y: destination.y,
    button: "left", buttons: 0, clickCount: 1, modifiers,
  });
}

async function focusNodeTarget() {
  await evaluate(`document.querySelector("#canvas-render-host .product-v2-node-target")?.focus()`);
}

async function pressKeyboardKey(key, code) {
  await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", key, code });
  await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key, code });
}

async function setSourceDraft(text) {
  await evaluate(`(() => {
    const source = document.querySelector("#source");
    source.value = ${JSON.stringify(text)};
    source.dispatchEvent(new Event("input", { bubbles: true }));
  })()`);
}

async function holdNextDispatch() {
  await evaluate(`import(new URL("./dist/src/main.js", location.href).href).then(
    (module) => module.holdNextProductV2DispatchForTest()
  )`);
}

async function releaseHeldDispatch() {
  await evaluate(`import(new URL("./dist/src/main.js", location.href).href).then(
    (module) => module.releaseProductV2DispatchForTest()
  )`);
}

function slidePoint(canvas, x, y) {
  return {
    x: canvas.left + (canvas.width * x) / 16,
    y: canvas.top + (canvas.height * (9 - y)) / 9,
  };
}

function replaceOnce(source, needle, replacement) {
  const start = source.indexOf(needle);
  assert.notEqual(start, -1, `fixture must contain ${needle.toString()}`);
  assert.equal(source.indexOf(needle, start + 1), -1, `fixture must contain ${needle.toString()} once`);
  return Buffer.concat([source.subarray(0, start), replacement, source.subarray(start + needle.length)]);
}

function remoteText(argument) {
  return argument.value === undefined ? argument.description ?? argument.type : String(argument.value);
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function cleanupResources(initialSignal) {
  if (cleanupPromise === null) {
    cleanupPromise = (async () => {
      cdp?.close();
      cdp = null;
      const child = browser;
      if (child !== null && child.exitCode === null && child.signalCode === null) {
        child.kill(initialSignal);
        if (initialSignal !== "SIGKILL") {
          const exited = await Promise.race([
            onceExit(child).then(() => true),
            delay(2_000).then(() => false),
          ]);
          if (!exited) {
            child.kill("SIGKILL");
          }
        }
        await onceExit(child);
      }
      browser = null;
      if (server !== null) {
        await new Promise((resolve) => server.close(resolve));
        server = null;
      }
      if (profile !== null) {
        const directory = profile;
        await removeProfile(directory);
        profile = null;
      }
    })();
  }
  return cleanupPromise;
}

function onceExit(child) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  return new Promise((resolve) => child.once("exit", resolve));
}

async function removeProfile(directory) {
  let lastError = null;
  for (let attempt = 0; attempt < 20; attempt += 1) {
    try {
      await rm(directory, { recursive: true, force: true, maxRetries: 2, retryDelay: 25 });
      await delay(50);
      await access(directory);
      lastError = new Error(`temporary Chrome profile was recreated: ${directory}`);
    } catch (error) {
      if (error?.code === "ENOENT") {
        return;
      }
      lastError = error;
      if (!["ENOTEMPTY", "EBUSY", "EPERM"].includes(error?.code)) {
        throw error;
      }
    }
    await delay(50);
  }
  throw lastError ?? new Error(`could not verify temporary Chrome profile removal: ${directory}`);
}

class Cdp {
  static async connect(url) {
    const socket = new WebSocket(url);
    await new Promise((resolve, reject) => {
      socket.addEventListener("open", resolve, { once: true });
      socket.addEventListener("error", () => reject(new Error("Could not connect to Chrome CDP")), { once: true });
    });
    return new Cdp(socket);
  }

  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
    socket.addEventListener("message", (event) => this.receive(JSON.parse(event.data)));
    socket.addEventListener("close", () => {
      for (const { reject } of this.pending.values()) reject(new Error("Chrome CDP connection closed"));
      this.pending.clear();
    });
  }

  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  on(method, listener) {
    const listeners = this.listeners.get(method) ?? [];
    listeners.push(listener);
    this.listeners.set(method, listeners);
  }

  receive(message) {
    if (message.id !== undefined) {
      const pending = this.pending.get(message.id);
      if (pending === undefined) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(`${message.error.code}: ${message.error.message}`));
      else pending.resolve(message.result);
      return;
    }
    for (const listener of this.listeners.get(message.method) ?? []) listener(message.params);
  }

  close() {
    this.socket.close();
  }
}

await main();