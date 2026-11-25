// node tikz.mjs URL OUTDIR : look at the drawn TikZ figures of the scratch deck tikz-deck
import { spawn } from 'node:child_process';
import fs from 'node:fs';
const [url, out] = process.argv.slice(2);
const c = spawn('google-chrome', ['--headless=new','--no-sandbox',`--user-data-dir=/tmp/sb-chrome-tikz-${process.pid}`,'--remote-debugging-port=9386','--window-size=1500,1000','about:blank'], {stdio:'ignore'});
const sleep = ms => new Promise(r => setTimeout(r, ms));
await sleep(2500);
const tabs = await (await fetch('http://127.0.0.1:9386/json')).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map(); const logs = [];
ws.onmessage = m => { const j = JSON.parse(m.data);
  if (j.method === 'Runtime.consoleAPICalled' && ['error','warning'].includes(j.params.type)) logs.push(j.params.type + ': ' + j.params.args.map(a => a.value ?? a.description ?? '').join(' ').slice(0, 300));
  if (j.method === 'Runtime.exceptionThrown') logs.push('exception: ' + (j.params.exceptionDetails.exception?.description ?? j.params.exceptionDetails.text).slice(0, 400));
  if (j.id && pend.has(j.id)) pend.get(j.id)(j.result ?? j.error); };
const send = (method, params={}) => new Promise(r => { pend.set(++id, r); ws.send(JSON.stringify({id, method, params})); });
const ev = async (expression) => { const r = await send('Runtime.evaluate', {expression, returnByValue: true, awaitPromise: true}); return r.result?.value ?? (r.exceptionDetails ? 'EXC ' + r.exceptionDetails.text : undefined); };
const shot = async (name) => { const s = await send('Page.captureScreenshot', {format: 'png'}); fs.writeFileSync(`${out}/${name}.png`, Buffer.from(s.data, 'base64')); };
await send('Runtime.enable'); await send('Page.enable'); await send('Page.navigate', {url});
for (let i = 0; i < 60; i++) { await sleep(500); if (/\d+ slides/.test(await ev('document.getElementById("status")?.textContent ?? ""'))) break; }
await sleep(2500);
console.log('drawings:', await ev(`document.querySelectorAll('.sb-drawing').length`), 'nodes:', await ev(`document.querySelectorAll('.sb-drawing-node').length`));
console.log('fit (box width - text width, px):', await ev(`[...document.querySelectorAll('.sb-drawing-node')].slice(0, 14).map(n => { const b = n.getBoundingClientRect(), t = n.firstElementChild.getBoundingClientRect(); return n.textContent.slice(0, 10) + ' ' + (b.width - t.width).toFixed(1) + '/' + (b.height - t.height).toFixed(1); }).join(' | ')`));
await ev(`document.querySelector('.sb-drawing')?.scrollIntoView({block: 'center'})`); await sleep(500);
await shot('tikz-0');
if (process.env.SB_STEPS) await import(process.env.SB_STEPS).then(m => m.default({ev, send, sleep, shot})).catch(e => console.log("STEPS FAILED", e.message));
console.log(logs.slice(0, 12).join('\n'));
ws.close(); c.kill();
