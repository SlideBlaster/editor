// node step2.mjs URL OUTDIR : multi-select, align, group drag, turn, flip, order, copy/paste on the scratch deck
import { spawn } from 'node:child_process';
import fs from 'node:fs';
const [url, out] = process.argv.slice(2);
const c = spawn('google-chrome', ['--headless=new','--no-sandbox',`--user-data-dir=/tmp/sb-chrome-step2-${process.pid}`,'--remote-debugging-port=9384','--window-size=1500,1000','about:blank'], {stdio:'ignore'});
const sleep = ms => new Promise(r => setTimeout(r, ms));
await sleep(2500);
const tabs = await (await fetch('http://127.0.0.1:9384/json')).json();
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
const drag = async (x1, y1, x2, y2, extra={}) => { await mouse('mousePressed', x1, y1, extra); for (let i = 1; i <= 6; i++) await mouse('mouseMoved', x1 + (x2 - x1) * i / 6, y1 + (y2 - y1) * i / 6, extra); await sleep(80); await mouse('mouseReleased', x2, y2, extra); };
const key = (k, code, vk, modifiers=0) => send('Input.dispatchKeyEvent', {type: 'keyDown', key: k, code, windowsVirtualKeyCode: vk, modifiers}).then(() => send('Input.dispatchKeyEvent', {type: 'keyUp', key: k, code, windowsVirtualKeyCode: vk, modifiers}));
const shot = async (name) => { const s = await send('Page.captureScreenshot', {format: 'png'}); fs.writeFileSync(`${out}/${name}.png`, Buffer.from(s.data, 'base64')); };
const rect = async (sel) => JSON.parse(await ev(`JSON.stringify((() => { const e = document.querySelector(${JSON.stringify(sel)}); if (!e) return null; const b = e.getBoundingClientRect(); return {x: b.left + b.width / 2, y: b.top + b.height / 2, w: b.width, h: b.height, l: b.left, t: b.top}; })())`));
await send('Runtime.enable'); await send('Page.enable'); await send('Page.navigate', {url});
for (let i = 0; i < 60; i++) { await sleep(500); if (/\d+ slides/.test(await ev('document.getElementById("status")?.textContent ?? ""'))) break; }
await sleep(1500);
await ev(`document.getElementById('view-source').click(); document.getElementById('view-notes').click()`); await sleep(600);
const F = '.deck-slide[data-frame="arrange"]';
await ev(`document.querySelector('${F}').scrollIntoView({block: 'center'})`); await sleep(500);
const src = () => ev('new TextDecoder().decode(Uint8Array.from(window.sb.view().source.sourceBase16.match(/../g).map(h => parseInt(h, 16)))).split("```slide")[1].split("```")[0].trim()');
const sel = () => ev(`[...document.querySelectorAll('${F} .sb-node-target.is-selected')].map(e => e.dataset.node).join(',') + ' lines=' + new Set([...document.querySelectorAll('${F} .sb-edit-line.is-selected')].map(e => e.dataset.line)).size`);
const node = (n) => rect(`${F} .sb-node-target[data-node="${n}"]`);
const bar = (title) => rect(`${F} .sb-style-button[title="${title}"]`);
const press = async (title) => { const b = await bar(title); if (!b) { console.log('NO BUTTON', title); return; } await click(b.x, b.y); await sleep(900); };
const slide = await rect(F);
console.log('start:\n' + await src());
await shot('0-start');
// 1. marquee over everything
await drag(slide.l + 8, slide.t + slide.h * 0.15, slide.l + slide.w - 8, slide.t + slide.h - 8); await sleep(400);
console.log('marquee selected:', await sel());
console.log('bar titles:', await ev(`[...document.querySelectorAll('${F} .sb-style-button')].map(b => b.title).join(' | ')`));
await shot('1-marquee');
// 2. align tops, then space evenly
await press('Align top edges'); console.log('after align top:\n' + await src());
await press('Space evenly left to right'); console.log('after spacing:\n' + await src());
console.log('still selected:', await sel());
await shot('2-aligned');
// 3. group drag by pressing one of them
let a = await node('a'); await drag(a.x, a.y, a.x + 40, a.y + 60); await sleep(900);
console.log('after group drag:\n' + await src()); console.log('selected:', await sel());
// 4. shift+click takes one out; arrow key nudges the rest
let c2 = await node('c'); await click(c2.x, c2.y, {modifiers: 8}); await sleep(300);
console.log('after shift-click c:', await sel());
await key('ArrowRight', 'ArrowRight', 39); await sleep(900);
console.log('after nudge:\n' + await src());
// 5. single: turn with the handle, quarter turn button, flip, order
await click(slide.l + 5, slide.t + 5); await sleep(200);
let b = await node('b'); await click(b.x, b.y); await sleep(400);
console.log('single selected:', await sel(), '| titles:', await ev(`[...document.querySelectorAll('${F} .sb-style-button')].map(b => b.title).slice(-8).join(' | ')`));
const knob = await rect(`${F} .sb-node-target[data-node="b"] .sb-node-turn`);
console.log('knob visible:', knob && knob.w > 0);
await drag(knob.x, knob.y, b.x + 80, b.y - 80); await sleep(900);   // 45 degrees clockwise on screen
console.log('after turn:', (await src()).split('\n').find(l => l.includes('(b)')));
await shot('3-turned');
await press('Turn left by a quarter'); console.log('after quarter:', (await src()).split('\n').find(l => l.includes('(b)')));
let d = await node('d'); await click(d.x, d.y); await sleep(400);
await press('Flip left to right'); console.log('after flip:', (await src()).split('\n').find(l => l.includes('(d)')));
console.log('flip painted:', await ev(`document.querySelector('${F} [data-item-id="pic-bg-d"] path')?.getAttribute('transform')`));
await press('Send to back'); console.log('after send to back:\n' + await src()); console.log('selected:', await sel());
// 6. copy two joined nodes, paste twice, cut one
await click(slide.l + 5, slide.t + 5); await sleep(200);
a = await node('a'); await click(a.x, a.y); b = await node('b'); await click(b.x, b.y, {modifiers: 8}); await sleep(300);
const lineHit = await ev(`(() => { const l = document.querySelector('${F} .sb-edit-line'); const r = l.getBoundingClientRect(); l.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true, button: 0, shiftKey: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2})); return 'ok'; })()`); await sleep(300);
console.log('for copy:', await sel());
const clip = await ev(`(() => { const dt = new DataTransfer(); document.dispatchEvent(new ClipboardEvent('copy', {clipboardData: dt, bubbles: true, cancelable: true})); window.__clip = dt.getData('text/plain'); return window.__clip; })()`);
console.log('copied text:\n' + clip);
for (let i = 0; i < 2; i++) { await ev(`(() => { const dt = new DataTransfer(); dt.setData('text/plain', window.__clip); document.dispatchEvent(new ClipboardEvent('paste', {clipboardData: dt, bubbles: true, cancelable: true})); })()`); await sleep(1200); }
console.log('after two pastes:\n' + await src()); console.log('selected:', await sel());
await key('d', 'KeyD', 68, 2); await sleep(1200);
console.log('after ctrl+d, statements:', (await src()).split('\n').length, 'selected:', await sel());
await key('a', 'KeyA', 65, 2); await sleep(300); console.log('ctrl+a:', await sel());
await shot('4-pasted');
const before = await src();
await key('ArrowDown', 'ArrowDown', 40); await sleep(900);
const nudged = await src();
console.log('undo buttons:', await ev(`[...document.querySelectorAll('button')].filter(b => b.textContent.trim() === 'Undo').map(b => b.id + ':' + b.disabled).join(',')`));
await ev(`[...document.querySelectorAll('button')].find(b => b.textContent.trim() === 'Undo').click()`); await sleep(900);
console.log('diff lines after undo:', (await src()).split('\n').filter((l, i) => l !== before.split('\n')[i]).length, 'of', before.split('\n').length);
console.log('group nudge changed:', nudged !== before, '| one undo restores:', (await src()) === before);
await ev(`document.querySelector('.deck-slide[data-frame="other"]').scrollIntoView({block: 'center'})`); await sleep(500);
const o = await rect('.deck-slide[data-frame="other"]');
await click(o.l + o.w * 0.5, o.t + o.h * 0.7); await sleep(300);
await ev(`(() => { const dt = new DataTransfer(); dt.setData('text/plain', window.__clip); document.dispatchEvent(new ClipboardEvent('paste', {clipboardData: dt, bubbles: true, cancelable: true})); })()`); await sleep(1500);
console.log('other slide after paste:\n' + await ev('new TextDecoder().decode(Uint8Array.from(window.sb.view().source.sourceBase16.match(/../g).map(h => parseInt(h, 16)))).split("## Other")[1]'));
await shot('5-other');
await ev(`document.querySelector('${F}').scrollIntoView({block: 'center'})`); await sleep(500);
const s2 = await rect(F); await click(s2.l + 5, s2.t + 5); await sleep(200);
await key('a', 'KeyA', 65, 2); await sleep(300);
await shot('4b-all');
await key('Delete', 'Delete', 46); await sleep(1200);
console.log('after delete all:', JSON.stringify(await src()));
console.log('status:', await ev('document.getElementById("status")?.textContent'), '| diagnostics:', await ev('JSON.stringify(window.sb.view().diagnostics).slice(0,200)'));
for (const l of logs.slice(0, 12)) console.log(l);
c.kill(); process.exit(0);
