// node step3.mjs URL OUTDIR : bent and right-angle arrows with labels on the scratch deck step3
import { spawn } from 'node:child_process';
import fs from 'node:fs';
const [url, out] = process.argv.slice(2);
const c = spawn('google-chrome', ['--headless=new','--no-sandbox',`--user-data-dir=/tmp/sb-chrome-step3-${process.pid}`,'--remote-debugging-port=9385','--window-size=1500,1000','about:blank'], {stdio:'ignore'});
const sleep = ms => new Promise(r => setTimeout(r, ms));
await sleep(2500);
const tabs = await (await fetch('http://127.0.0.1:9385/json')).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map(); const logs = [];
ws.onmessage = m => { const j = JSON.parse(m.data);
  if (j.method === 'Runtime.consoleAPICalled' && ['error','warning'].includes(j.params.type)) logs.push(j.params.type + ': ' + j.params.args.map(a => a.value ?? a.description ?? '').join(' ').slice(0, 300));
  if (j.method === 'Runtime.exceptionThrown') logs.push('exception: ' + (j.params.exceptionDetails.exception?.description ?? j.params.exceptionDetails.text).slice(0, 400));
  if (j.id && pend.has(j.id)) pend.get(j.id)(j.result ?? j.error); };
const send = (method, params={}) => new Promise(r => { pend.set(++id, r); ws.send(JSON.stringify({id, method, params})); });
const ev = async (expression) => { const r = await send('Runtime.evaluate', {expression, returnByValue: true, awaitPromise: true}); return r.result?.value ?? (r.exceptionDetails ? 'EXC ' + r.exceptionDetails.text : undefined); };
const mouse = (type, x, y, extra={}) => send('Input.dispatchMouseEvent', {type, x, y, button: 'left', buttons: type === 'mouseReleased' ? 0 : 1, clickCount: 1, ...extra});
const click = async (x, y, extra={}) => { await mouse('mousePressed', x, y, extra); await mouse('mouseReleased', x, y, extra); };
const dbl = async (x, y) => { await click(x, y); await mouse('mousePressed', x, y, {clickCount: 2}); await mouse('mouseReleased', x, y, {clickCount: 2}); };
const drag = async (x1, y1, x2, y2) => { await mouse('mousePressed', x1, y1); for (let i = 1; i <= 6; i++) await mouse('mouseMoved', x1 + (x2 - x1) * i / 6, y1 + (y2 - y1) * i / 6); await sleep(80); await mouse('mouseReleased', x2, y2); };
const key = (k, code, vk) => send('Input.dispatchKeyEvent', {type: 'keyDown', key: k, code, windowsVirtualKeyCode: vk}).then(() => send('Input.dispatchKeyEvent', {type: 'keyUp', key: k, code, windowsVirtualKeyCode: vk}));
const type = async (text) => { for (const ch of text) { await send('Input.dispatchKeyEvent', {type: 'keyDown', text: ch, key: ch}); await send('Input.dispatchKeyEvent', {type: 'keyUp', key: ch}); } };
const shot = async (name) => { const s = await send('Page.captureScreenshot', {format: 'png'}); fs.writeFileSync(`${out}/${name}.png`, Buffer.from(s.data, 'base64')); };
const rect = async (sel) => JSON.parse(await ev(`JSON.stringify((() => { const e = document.querySelector(${JSON.stringify(sel)}); if (!e) return null; const b = e.getBoundingClientRect(); return {x: b.left + b.width / 2, y: b.top + b.height / 2, w: b.width, h: b.height, l: b.left, t: b.top}; })())`));
await send('Runtime.enable'); await send('Page.enable'); await send('Page.navigate', {url});
for (let i = 0; i < 60; i++) { await sleep(500); if (/\d+ slides/.test(await ev('document.getElementById("status")?.textContent ?? ""'))) break; }
await sleep(1500);
await ev(`document.getElementById('view-source').click(); document.getElementById('view-notes').click()`); await sleep(600);
const show = async (frame) => { await ev(`document.querySelector('.deck-slide[data-frame="${frame}"]').scrollIntoView({block: 'center'})`); await sleep(600); };
await show('arrows'); await sleep(1500);
console.log('arrows items:', await ev(`[...document.querySelectorAll('.deck-slide[data-frame="arrows"] .sb-line-item')].map(e => e.tagName + (e.getAttribute('marker-end') ? '>' : '') + (e.getAttribute('marker-start') ? '<' : '')).join(' ')`), '| labels:', await ev(`document.querySelectorAll('.deck-slide[data-frame="arrows"] .sb-label-target').length`));
await shot('0-arrows');
const E = '.deck-slide[data-frame="edit"]';
await show('edit');
const src = () => ev('new TextDecoder().decode(Uint8Array.from(window.sb.view().source.sourceBase16.match(/../g).map(h => parseInt(h, 16)))).split("## Edit")[1].split("```slide")[1].split("```")[0].trim().split("\\n").pop()');
const mid = () => ev(`(() => { const l = document.querySelector('${E} .sb-edit-line'); const r = l.getBoundingClientRect(); return JSON.stringify({x: r.left + r.width / 2, y: r.top + r.height / 2}); })()`).then(JSON.parse);
const pickLine = async () => { const s = await rect(E); await click(s.l + 6, s.t + 6); await sleep(150); await ev(`(() => { const l = document.querySelector('${E} .sb-edit-line'); const r = l.getBoundingClientRect(); l.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true, button: 0, clientX: r.left, clientY: r.top})); })()`); await sleep(300); };
const press = async (title) => { const b = await rect(`${E} .sb-style-button[title="${title}"]`); if (!b) { console.log('NO BUTTON', title, '| have:', await ev(`[...document.querySelectorAll('${E} .sb-style-button')].map(b => b.title).join(' | ')`)); return; } await click(b.x, b.y); await sleep(900); };
await pickLine();
console.log('line bar:', await ev(`[...document.querySelectorAll('${E} .sb-style-button')].map(b => b.title).join(' | ')`));
console.log('handles:', await ev(`[...document.querySelectorAll('${E} .sb-line-point')].map(e => e.className.replace('sb-line-point ', '')).join(',')`));
await press('Right angle: across, then up or down'); console.log('hv:', await src());
await press('Right angle: up or down, then across'); console.log('vh:', await src());
await press('Curved (again for the other way)'); console.log('curve:', await src());
await shot('1-curve');
await press('Curved (again for the other way)'); console.log('curve again:', await src());
// bend handle: drag it across the chord
let h = await rect(`${E} .sb-line-point-bend`); console.log('bend handle:', !!h);
if (h) { await drag(h.x, h.y, h.x + 40, h.y - 90); await sleep(900); console.log('after bend drag:', await src()); }
await press('Straight'); console.log('straight:', await src());
// label: add with T, type, enter
await press('Add a label'); await type('yes'); await key('Enter', 'Enter', 13); await sleep(1000);
console.log('label added:', await src());
await pickLine();
await press('Label on the line'); console.log('on line:', await src());
await press('Label on the other side'); console.log('other side:', await src());
await shot('2-label');
// retype by double-clicking the label
let l = await rect(`${E} .sb-label-target`); console.log('label target:', !!l);
if (l) { await dbl(l.x, l.y); await sleep(400); await ev(`document.querySelector('${E} .sb-label-editor').select()`); await type('no'); await key('Enter', 'Enter', 13); await sleep(1000); console.log('retyped:', await src()); }
// waypoint: drag the dot in the middle
await pickLine();
h = await rect(`${E} .sb-line-point-new`); console.log('new-point handle:', !!h);
if (h) { await drag(h.x, h.y, h.x + 10, h.y - 120); await sleep(1000); console.log('point added:', await src()); }
await pickLine();
console.log('handles now:', await ev(`[...document.querySelectorAll('${E} .sb-line-point')].map(e => e.className.replace('sb-line-point ', '')).join(',')`));
h = await rect(`${E} .sb-line-point-at`);
if (h) { await drag(h.x, h.y, h.x + 100, h.y + 20); await sleep(1000); console.log('point moved:', await src()); }
await shot('3-point');
// moving a node: the line follows
const p = await rect(`${E} .sb-node-target[data-node="p"]`); await drag(p.x, p.y, p.x - 40, p.y + 80); await sleep(1000);
console.log('after node move, line:', await src());
await pickLine(); h = await rect(`${E} .sb-line-point-at`);
if (h) { await dbl(h.x, h.y); await sleep(1000); console.log('point removed:', await src()); }
console.log('status:', await ev('document.getElementById("status")?.textContent'), '| diagnostics:', await ev('JSON.stringify(window.sb.view().diagnostics).slice(0,300)'));
for (const l of logs.slice(0, 12)) console.log(l);
c.kill(); process.exit(0);
