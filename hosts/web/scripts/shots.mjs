#!/usr/bin/env node
// `sb shots DECK [-o DIR] [--compare] [--root DIR] [--size WxH]`
//
// Screenshots of every presented step, taken from the real audience window: `sb serve` runs the
// deck, the editor page presses Present, and the audience window is stepped with the arrow key, as
// in a talk. One PNG per step, named NNN-<frame>-s<step>.png, plus index.json.
//
// --compare also prints the deck with `sb build --pdf --steps`, rasterises every page (pdftoppm)
// and compares it with the shot of the same step. Every step that differs is listed and gets a
// side-by-side image (PDF | presenter | difference) in DIR/diff/. Exit status 1 when any differ.
//
// No dependencies: Chrome is driven over its DevTools protocol with Node's built-in WebSocket.
// Chrome: SB_CHROME, else google-chrome / chromium / chromium-browser on PATH.

import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// --- arguments -------------------------------------------------------------------------------
const argv = process.argv.slice(2);
const opt = { deck: null, out: null, compare: false, root: null, web: null, sb: process.env.SB ?? "sb", width: 1280, height: 720 };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  const value = () => { if (i + 1 >= argv.length) fail(`${a} needs a value`); return argv[++i]; };
  if (a === "-o") opt.out = value();
  else if (a === "--compare") opt.compare = true;
  else if (a === "--root") opt.root = value();
  else if (a === "--web") opt.web = value();
  else if (a === "--sb") opt.sb = value();
  else if (a === "--size") { const m = /^(\d+)x(\d+)$/.exec(value()); if (!m) fail("--size is WxH, e.g. 1280x720"); opt.width = +m[1]; opt.height = +m[2]; }
  else if (a.startsWith("-")) fail(`unknown shots option ${a}`);
  else if (opt.deck === null) opt.deck = a;
  else fail("shots takes exactly one deck");
}
if (opt.deck === null) fail("usage: sb shots DECK [-o DIR] [--compare] [--root DIR] [--size WxH]");

function fail(message) { console.error(`sb shots: ${message}`); process.exit(2); }

const deck = path.resolve(opt.deck);
if (!fs.existsSync(deck)) fail(`no such deck: ${opt.deck}`);
// The served project is the deck's own folder, as the desktop app and `sb build` open it.
const root = path.resolve(opt.root ?? path.dirname(deck));
const entry = path.relative(root, deck).split(path.sep).join("/");
if (entry.startsWith("..")) fail(`the deck is not inside --root ${root}`);
const web = opt.web === null ? null : path.resolve(opt.web);
const out = path.resolve(opt.out ?? path.join(path.dirname(deck), ".slideblaster", "shots"));
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const cleanup = [];
const finish = async (code) => { for (const f of cleanup.reverse()) { try { await f(); } catch { /* best effort */ } } process.exit(code); };
process.on("SIGINT", () => void finish(130));

// --- sb serve ----------------------------------------------------------------------------------
async function startServer() {
  const args = ["serve", root, "--port", "0", ...(web ? ["--web", web] : [])];
  const child = spawn(opt.sb, args, { stdio: ["ignore", "pipe", "pipe"] });
  cleanup.push(() => child.kill("SIGTERM"));
  let log = "";
  child.stderr.on("data", (d) => { log += d; });
  return await new Promise((resolve, reject) => {
    let buffer = "";
    child.stdout.on("data", (d) => {
      buffer += d;
      const m = /SB_READY port=(\d+)/.exec(buffer);
      if (m) resolve(+m[1]);
    });
    child.on("exit", (code) => reject(new Error(`sb serve exited (${code}): ${log.trim()}`)));
    child.on("error", reject);
  });
}

// --- Chrome over the DevTools protocol ---------------------------------------------------------
function findChrome() {
  if (process.env.SB_CHROME) return process.env.SB_CHROME;
  for (const name of ["google-chrome", "chromium", "chromium-browser", "google-chrome-stable"]) {
    const r = spawnSync("which", [name], { encoding: "utf8" });
    if (r.status === 0) return r.stdout.trim();
  }
  fail("no Chrome found: set SB_CHROME or install google-chrome / chromium");
}

async function startChrome() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "sb-shots-"));
  const child = spawn(findChrome(), [
    "--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--disable-popup-blocking",
    "--no-first-run", "--no-default-browser-check", "--hide-scrollbars", "--force-device-scale-factor=1",
    "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
    `--window-size=${opt.width},${opt.height}`, "about:blank",
  ], { stdio: "ignore" });
  cleanup.push(() => { child.kill("SIGTERM"); fs.rmSync(profile, { recursive: true, force: true }); });
  const portFile = path.join(profile, "DevToolsActivePort");
  for (let i = 0; i < 200 && !fs.existsSync(portFile); i++) await sleep(50);
  const [port, wsPath] = fs.readFileSync(portFile, "utf8").trim().split("\n");
  return connect(`ws://127.0.0.1:${port}${wsPath}`);
}

async function connect(url) {
  const ws = new WebSocket(url);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = () => reject(new Error("cannot reach Chrome")); });
  let id = 0;
  const pending = new Map();
  ws.onmessage = (m) => {
    const msg = JSON.parse(String(m.data));
    if (msg.id === undefined) return;
    const p = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) p.reject(new Error(`${p.method}: ${msg.error.message}`)); else p.resolve(msg.result);
  };
  const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const n = ++id;
    pending.set(n, { resolve, reject, method });
    ws.send(JSON.stringify({ id: n, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  /** A page (target) to drive: evaluate in it, press keys, take screenshots. */
  const attach = async (targetId) => {
    const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
    const s = (method, params) => send(method, params, sessionId);
    return {
      targetId,
      async eval(expression) {
        const r = await s("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
        if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
        return r.result.value;
      },
      async key(key, keyCode) {
        for (const type of ["keyDown", "keyUp"]) await s("Input.dispatchKeyEvent", { type, key, code: key, windowsVirtualKeyCode: keyCode });
      },
      size: (width, height) => s("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false }),
      front: () => s("Page.bringToFront"),
      async png() { return Buffer.from((await s("Page.captureScreenshot", { format: "png" })).data, "base64"); },
    };
  };
  return { send, attach, close: () => ws.close() };
}

async function until(what, test, ms = 60000, every = 100) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await test();
    if (v) return v;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(every);
  }
}

// Everything on the slide drawn: fonts, images, two frames.
const SETTLED = `(async () => {
  await document.fonts.ready;
  await Promise.all([...document.images].map((i) => i.complete ? null : i.decode().catch(() => null)));
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  return true;
})()`;

// --- shots -------------------------------------------------------------------------------------
async function takeShots(chrome, port) {
  const { targetId } = await chrome.send("Target.createTarget", { url: `http://127.0.0.1:${port}/?entry=${encodeURIComponent(entry)}` });
  const editor = await chrome.attach(targetId);
  await until("the editor to open the deck", () => editor.eval(`!!document.querySelector("#present-btn:not([disabled])")`), 180000);
  await editor.eval(SETTLED);
  await editor.eval(`document.getElementById("present-btn").click()`);
  const find = async (name) => (await chrome.send("Target.getTargets")).targetInfos.find((t) => t.type === "page" && t.url.includes(name));
  const audience = await chrome.attach((await until("the audience window", () => find("audience.html"), 20000)).targetId);
  const presenter = await chrome.attach((await until("the presenter console", () => find("console.html"), 20000)).targetId);
  await audience.size(opt.width, opt.height);
  await audience.front();
  // The "arrow keys / click to advance" hint fades after a few seconds in a talk; leave it out.
  await audience.eval(`(() => { const s = document.createElement("style"); s.textContent = ".aud-hint{display:none!important}"; document.head.append(s); return true; })()`);
  const where = () => presenter.eval(`document.getElementById("con-where")?.textContent ?? ""`);
  await until("the first slide", async () => /step \d+ \/ \d+/.test(await where()), 30000);
  await audience.key("Home", 36);
  await sleep(300);

  const shots = [];
  for (let n = 1; n <= 5000; n++) {
    const here = await where();
    await audience.eval(SETTLED);
    const frame = await audience.eval(`document.querySelector("#stage .sb-slide")?.dataset.frame ?? "unknown"`);
    const m = /Slide (\d+).*step (\d+) \/ (\d+)/.exec(here);
    const step = m ? +m[2] : 1;
    const file = `${String(n).padStart(3, "0")}-${frame.replace(/[^\w.-]+/g, "_")}-s${step}.png`;
    fs.writeFileSync(path.join(out, file), await audience.png());
    shots.push({ file, frame, step, steps: m ? +m[3] : 1, slide: m ? +m[1] : null });
    await audience.key("ArrowRight", 39);
    const moved = await until("the next step", async () => (await where()) !== here, 4000, 50).catch(() => false);
    if (!moved) break; // the last step: Next does nothing
  }
  fs.writeFileSync(path.join(out, "index.json"), JSON.stringify(shots, null, 1));
  console.log(`${shots.length} presented steps -> ${out}`);
  return shots;
}

// --- compare with the PDF ----------------------------------------------------------------------
async function compare(chrome, shots) {
  const pdf = path.join(out, "steps.pdf");
  const built = spawnSync(opt.sb, ["build", "--pdf", deck, "-o", pdf, "--steps", ...(web ? ["--web", web] : [])], { encoding: "utf8" });
  if (built.status !== 0) fail(`sb build --pdf failed:\n${built.stderr}`);
  for (const line of built.stderr.split("\n")) if (line.startsWith("warning")) console.log(line);
  const pages = path.join(out, "pdf");
  fs.mkdirSync(pages);
  const raster = spawnSync("pdftoppm", ["-png", "-scale-to-x", String(opt.width), "-scale-to-y", String(opt.height), pdf, path.join(pages, "page")], { encoding: "utf8" });
  if (raster.error) fail("pdftoppm (poppler-utils) is needed for --compare");
  const pageFiles = fs.readdirSync(pages).filter((f) => f.endsWith(".png")).sort();

  const { targetId } = await chrome.send("Target.createTarget", { url: "about:blank" });
  const page = await chrome.attach(targetId);
  // Both images shrunk to a quarter and greyed: anti-aliasing and hinting differences between
  // print and screen vanish, a moved, resized or missing element does not.
  await page.eval(`window.diff = async (a, b) => {
    const load = (src) => new Promise((ok, no) => { const i = new Image(); i.onload = () => ok(i); i.onerror = no; i.src = src; });
    const [A, B] = await Promise.all([load(a), load(b)]);
    const w = Math.round(A.width / 4), h = Math.round(A.height / 4);
    const grey = (img) => { const c = new OffscreenCanvas(w, h), x = c.getContext("2d"); x.drawImage(img, 0, 0, w, h);
      const d = x.getImageData(0, 0, w, h).data, g = new Float32Array(w * h);
      for (let i = 0; i < g.length; i++) g[i] = 0.3 * d[4 * i] + 0.59 * d[4 * i + 1] + 0.11 * d[4 * i + 2]; return g; };
    const ga = grey(A), gb = grey(B);
    // A cell differs only when nothing within two cells (8 px) of it in the other image is close:
    // print and screen space letters a little differently, so line ends shift by a few pixels.
    const near = (g, x, y, v) => { for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) {
      const X = x + dx, Y = y + dy; if (X >= 0 && Y >= 0 && X < w && Y < h && Math.abs(g[Y * w + X] - v) <= 48) return true; } return false; };
    let off = 0; const mask = new Uint8Array(w * h);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const i = y * w + x;
      if (!near(gb, x, y, ga[i]) || !near(ga, x, y, gb[i])) { off++; mask[i] = 1; }
    }
    const score = off / ga.length;
    if (score === 0) return { score };
    const W = A.width, H = A.height, c = new OffscreenCanvas(W * 3, H), x = c.getContext("2d");
    x.drawImage(A, 0, 0); x.drawImage(B, W, 0); x.globalAlpha = 0.35; x.drawImage(B, 2 * W, 0); x.globalAlpha = 1;
    x.fillStyle = "rgba(230,30,30,0.85)";
    for (let i = 0; i < mask.length; i++) if (mask[i]) x.fillRect(2 * W + (i % w) * 4, Math.floor(i / w) * 4, 4, 4);
    x.fillStyle = "#000"; x.font = "bold 28px sans-serif"; x.fillText("PDF", 16, H - 16); x.fillText("presenter", W + 16, H - 16); x.fillText("difference", 2 * W + 16, H - 16);
    const blob = await c.convertToBlob({ type: "image/png" });
    const bytes = new Uint8Array(await blob.arrayBuffer()); let s = ""; for (const b of bytes) s += String.fromCharCode(b);
    return { score, png: btoa(s) };
  }; true`);
  const dataUrl = (file) => `data:image/png;base64,${fs.readFileSync(file).toString("base64")}`;
  fs.mkdirSync(path.join(out, "diff"));
  const report = [];
  const n = Math.min(pageFiles.length, shots.length);
  for (let i = 0; i < n; i++) {
    const shot = shots[i];
    const r = await page.eval(`window.diff(${JSON.stringify(dataUrl(path.join(pages, pageFiles[i])))}, ${JSON.stringify(dataUrl(path.join(out, shot.file)))})`);
    if (r.score > 0.005) {
      const file = path.join("diff", shot.file);
      fs.writeFileSync(path.join(out, file), Buffer.from(r.png, "base64"));
      report.push(`differs  step ${i + 1}: ${shot.frame} step ${shot.step}/${shot.steps}  (${(r.score * 100).toFixed(1)}% of the slide)  ${file}`);
    }
  }
  if (pageFiles.length !== shots.length) {
    report.unshift(`count    the PDF has ${pageFiles.length} pages, the presentation ${shots.length} steps; steps after ${n} are not compared, and once one is missing every later pair is off by one`);
  }
  fs.writeFileSync(path.join(out, "report.txt"), report.join("\n") + "\n");
  if (report.length === 0) console.log(`all ${n} steps: the presenter matches the PDF`);
  else { for (const line of report) console.log(line); console.log(`${report.length} difference(s); details in ${path.join(out, "report.txt")}`); }
  return report.length === 0;
}

// --- main --------------------------------------------------------------------------------------
try {
  const port = await startServer();
  const chrome = await startChrome();
  cleanup.push(() => chrome.close());
  const shots = await takeShots(chrome, port);
  const same = opt.compare ? await compare(chrome, shots) : true;
  await finish(same ? 0 : 1);
} catch (error) {
  console.error(`sb shots: ${error instanceof Error ? error.message : String(error)}`);
  await finish(2);
}
