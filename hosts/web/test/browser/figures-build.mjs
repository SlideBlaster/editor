export default async function ({ev, send, sleep, shot}) {
  const mouse = (type, x, y, extra={}) => send('Input.dispatchMouseEvent', {type, x, y, button: 'left', buttons: type === 'mouseReleased' ? 0 : 1, clickCount: 1, ...extra});
  const click = async (x, y, extra={}) => { await mouse('mousePressed', x, y, extra); await mouse('mouseReleased', x, y, extra); };
  const dbl = async (x, y) => { await click(x, y); await mouse('mousePressed', x, y, {clickCount: 2}); await mouse('mouseReleased', x, y, {clickCount: 2}); };
  const drag = async (x1, y1, x2, y2, extra={}) => { await mouse('mousePressed', x1, y1, extra); for (let i = 1; i <= 6; i++) await mouse('mouseMoved', x1 + (x2 - x1) * i / 6, y1 + (y2 - y1) * i / 6, extra); await sleep(80); await mouse('mouseReleased', x2, y2, extra); };
  const key = (k, code, vk) => send('Input.dispatchKeyEvent', {type: 'keyDown', key: k, code, windowsVirtualKeyCode: vk}).then(() => send('Input.dispatchKeyEvent', {type: 'keyUp', key: k, code, windowsVirtualKeyCode: vk}));
  const type = async (text) => { for (const ch of text) { await send('Input.dispatchKeyEvent', {type: 'keyDown', text: ch, key: ch}); await send('Input.dispatchKeyEvent', {type: 'keyUp', key: ch}); } };
  const src = () => ev('new TextDecoder().decode(Uint8Array.from(window.sb.view().source.sourceBase16.match(/../g).map(h => parseInt(h, 16)))).split("## Inline")[1].split("```tikz")[1].split("```")[0].trim()');
  const D = `[...document.querySelectorAll('#deck-canvas .sb-drawing')].find(d => [...d.querySelectorAll('.sb-drawing-node')].some(n => n.textContent.trim() === 'one'))`;
  const box = async (expr) => JSON.parse(await ev(`JSON.stringify((() => { const e = ${expr}; if (!e) return null; const b = e.getBoundingClientRect(); return {x: b.left + b.width / 2, y: b.top + b.height / 2, l: b.left, t: b.top, r: b.right, b: b.bottom}; })())`));
  const node = (text) => box(`[...${D}.querySelectorAll('.sb-drawing-node')].find(n => n.textContent.trim() === ${JSON.stringify(text)})`);
  await ev(`${D}.scrollIntoView({block: 'center'})`); await sleep(500);
  const status = () => ev(`document.getElementById("status")?.textContent`);
  // a new node on empty ground, typed in at once
  let d = await box(D);
  await click(d.r - 30, d.b - 8); await sleep(900); d = await box(D);
  console.log('under dbl:', await ev(`(() => { const e = document.elementFromPoint(${d.r - 30}, ${d.b - 8}); return e.tagName + '.' + (e.getAttribute('class') ?? ''); })()`));
  await dbl(d.r - 30, d.b - 8); await sleep(1500);
  console.log('status:', await status());
  console.log('typing box:', await ev(`document.querySelector('.sb-drawing-typing')?.textContent ?? 'NONE'`));
  await type('fresh'); await key('Enter', 'Enter', 13); await sleep(1200);
  console.log('after add:\n' + await src());
  // a line from "one" to the new node, by the link handle
  let a = await node('one'); await click(a.x, a.y); await sleep(300);
  let h = await box(`document.querySelector('.sb-drawing-link')`); let f = await node('fresh');
  if (!h || !f) console.log('NO HANDLE OR NODE', !!h, !!f); else { await drag(h.x, h.y, f.x, f.y); await sleep(1200); }
  console.log('after link:\n' + await src());
  // resize "one"
  a = await node('one'); await click(a.x, a.y); await sleep(300);
  h = await box(`document.querySelector('.sb-drawing-resize')`);
  await drag(h.x, h.y, h.x + 40, h.y + 20); await sleep(1200);
  console.log('after resize:\n' + await src());
  // bend the new line
  await key('Escape', 'Escape', 27); await sleep(200);
  const q = JSON.parse(await ev(`JSON.stringify((() => { const all = [...${D}.querySelectorAll('path.sb-drawing-path')].filter(x => !x.hasAttribute('data-drawing-node')); const e = all[all.length - 1]; const l = e.getTotalLength(); const m = e.getPointAtLength(l / 2).matrixTransform(e.getScreenCTM()); return {x: m.x, y: m.y}; })())`));
  await click(q.x, q.y); await sleep(300);
  const r = await box(`document.querySelector('.sb-drawing-bar [title="Bent to the left"]')`);
  if (!r) console.log('NO ROUTE BUTTON; bar:', await ev(`[...document.querySelectorAll('.sb-drawing-bar .sb-style-button')].map(b => b.title).join(' | ')`)); else { await click(r.x, r.y); await sleep(1200); }
  console.log('after route:\n' + await src());
  // two nodes together
  await key('Escape', 'Escape', 27); await sleep(200);
  a = await node('one'); await click(a.x, a.y); await sleep(200);
  f = await node('fresh'); await click(f.x, f.y, {modifiers: 8}); await sleep(300);
  console.log('picked:', await ev(`document.querySelectorAll('.sb-drawing-node.sb-drawing-picked').length`));
  f = await node('fresh'); await drag(f.x, f.y, f.x + 30, f.y + 30); await sleep(1500);
  console.log('after group move:\n' + await src());
  console.log('status:', await status());
  await ev(`${D}.scrollIntoView({block: 'center'})`); await sleep(400);
  await shot('tikz-3');
}
