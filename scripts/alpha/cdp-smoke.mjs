// Minimal Chrome DevTools driver for smoke checks: node scripts/alpha/cdp-smoke.mjs <url> <out.png> [js-expression]
import { spawn } from "node:child_process";
import fs from "node:fs";
const [url, out, expr] = process.argv.slice(2);
const port = 9333;
const chrome = spawn("google-chrome", ["--headless=new","--no-sandbox","--disable-gpu",`--remote-debugging-port=${port}`,`--window-size=${process.env.WS || "1440,900"}`,"about:blank"],{stdio:"ignore"});
const sleep = (ms)=>new Promise(r=>setTimeout(r,ms));
let targets;
for (let i=0;i<50;i++){ try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); if (targets.find(t=>t.type==="page")) break; } catch {} await sleep(200); }
const page = targets.find(t=>t.type==="page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(r=>ws.onopen=r);
let id=0; const pending=new Map();
ws.onmessage=(e)=>{const m=JSON.parse(e.data); if(m.id&&pending.has(m.id)){pending.get(m.id)(m);pending.delete(m.id);}};
const call=(method,params={})=>new Promise(r=>{const i=++id;pending.set(i,r);ws.send(JSON.stringify({id:i,method,params}));});
await call("Page.enable"); await call("Runtime.enable");
await call("Page.navigate",{url});
await sleep(12000);
if (expr) { const r = await call("Runtime.evaluate",{expression:expr,returnByValue:true,awaitPromise:true}); console.log(JSON.stringify(r.result?.result?.value ?? r.result)); }
const shot = await call("Page.captureScreenshot",{format:"png"});
fs.writeFileSync(out, Buffer.from(shot.result.data,"base64"));
chrome.kill();
process.exit(0);
