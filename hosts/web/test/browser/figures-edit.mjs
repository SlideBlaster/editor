export default async function ({ev, send, sleep, shot}) {
  const mouse = (type, x, y, extra={}) => send('Input.dispatchMouseEvent', {type, x, y, button: 'left', buttons: type === 'mouseReleased' ? 0 : 1, clickCount: 1, ...extra});
  const click = async (x, y) => { await mouse('mousePressed', x, y); await mouse('mouseReleased', x, y); };
  const drag = async (x1, y1, x2, y2) => { await mouse('mousePressed', x1, y1); for (let i = 1; i <= 6; i++) await mouse('mouseMoved', x1 + (x2 - x1) * i / 6, y1 + (y2 - y1) * i / 6); await sleep(80); await mouse('mouseReleased', x2, y2); };
  const key = (k, code, vk) => send('Input.dispatchKeyEvent', {type: 'keyDown', key: k, code, windowsVirtualKeyCode: vk}).then(() => send('Input.dispatchKeyEvent', {type: 'keyUp', key: k, code, windowsVirtualKeyCode: vk}));
  const type = async (text) => { for (const ch of text) { await send('Input.dispatchKeyEvent', {type: 'keyDown', text: ch, key: ch}); await send('Input.dispatchKeyEvent', {type: 'keyUp', key: ch}); } };
  const src = () => ev('new TextDecoder().decode(Uint8Array.from(window.sb.view().source.sourceBase16.match(/../g).map(h => parseInt(h, 16)))).split("```tikz")[1].split("```")[0].trim()');
  const at = async (text, last = true) => JSON.parse(await ev(`JSON.stringify((() => { const all = [...document.querySelectorAll('#deck-canvas .sb-drawing-node')].filter(n => n.textContent.trim() === ${JSON.stringify(text)}); const e = all[${last ? 'all.length - 1' : 0}]; if (!e) return null; e.scrollIntoView({block: 'center'}); const b = e.getBoundingClientRect(); return {x: b.left + b.width / 2, y: b.top + b.height / 2}; })())`));
  console.log('before:\n' + await src());
  let p = await at('one'); await sleep(300); p = await at('one');
  await drag(p.x, p.y, p.x - 60, p.y + 30); await sleep(1200);
  console.log('after drag:\n' + await src());
  p = await at('one'); await sleep(200); p = await at('one');
  await click(p.x, p.y); await sleep(200);
  console.log('bar buttons:', await ev(`[...document.querySelectorAll('.sb-drawing-bar .sb-style-button')].map(b => b.title).join(' | ')`));
  await mouse('mousePressed', p.x, p.y, {clickCount: 2}); await mouse('mouseReleased', p.x, p.y, {clickCount: 2}); await sleep(300);
  await type('first'); await key('Enter', 'Enter', 13); await sleep(1200);
  console.log('after retype:\n' + await src());
  p = await at('first'); await click(p.x, p.y); await sleep(300);
  const b = JSON.parse(await ev(`JSON.stringify((() => { const e = document.querySelector('.sb-drawing-bar [title="Fill: green"]'); if (!e) return null; const r = e.getBoundingClientRect(); return {x: r.left + r.width / 2, y: r.top + r.height / 2}; })())`));
  if (b) { await click(b.x, b.y); await sleep(1200); } else console.log('NO FILL BUTTON');
  console.log('after fill:\n' + await src());
  await shot('tikz-1');
  // the curved line: press on its middle
  await key('Escape', 'Escape', 27); await sleep(200);
  const q = JSON.parse(await ev(`JSON.stringify((() => { const d = [...document.querySelectorAll('#deck-canvas .sb-drawing')].pop(); const e = [...d.querySelectorAll('path.sb-drawing-path')].find(x => !x.hasAttribute('data-drawing-node')); const l = e.getTotalLength(); const m = e.getPointAtLength(l / 2).matrixTransform(e.getScreenCTM()); return {x: m.x, y: m.y}; })())`));
  console.log('under q:', await ev(`(() => { const e = document.elementFromPoint(${q.x}, ${q.y}); return e ? e.tagName + '.' + (e.getAttribute('class') ?? '') + ' at=' + e.getAttribute('data-drawing-at') : 'none'; })()`));
  await click(q.x, q.y); await sleep(300);
  console.log('picked:', await ev(`[...document.querySelectorAll('.sb-drawing-picked')].map(e => e.tagName + ' at=' + e.getAttribute('data-drawing-at')).join(', ')`));
  console.log('picked line:', await ev(`document.querySelectorAll('path.sb-drawing-picked').length`));
  await key('Delete', 'Delete', 46); await sleep(1200);
  console.log('after delete:\n' + await src());
  await key('z', 'KeyZ', 90); 
  // a figure in a file of its own
  p = await at('program', false); await sleep(300); p = await at('program', false);
  await click(p.x, p.y); await mouse('mousePressed', p.x, p.y, {clickCount: 2}); await mouse('mouseReleased', p.x, p.y, {clickCount: 2}); await sleep(300);
  console.log('typing in:', await ev(`(() => { const e = document.activeElement; return e ? e.tagName + '.' + (e.getAttribute('class') ?? '') + ' "' + (e.textContent ?? '').slice(0, 30) + '"' : 'none'; })()`), '| under p:', await ev(`(() => { const e = document.elementFromPoint(${p.x}, ${p.y}); return e ? e.tagName + '.' + (e.getAttribute('class') ?? '') : 'none'; })()`));
  await type('prog'); await key('Enter', 'Enter', 13); await sleep(1500);
  console.log('file node now:', await ev(`[...document.querySelectorAll('#deck-canvas .sb-drawing-node')].slice(1, 3).map(n => n.textContent).join(' | ')`));
  console.log("status:", await ev(`document.getElementById("status")?.textContent`));
  await shot("tikz-2");
}
