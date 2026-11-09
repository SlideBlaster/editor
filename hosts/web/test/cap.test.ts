import test from "node:test";
import assert from "node:assert/strict";
import { createCapClient, relayBlockRender, svgIntrinsicSize, CapError } from "../src/cap/client.ts";
import type { SocketLike } from "../src/transport/transport.ts";

function fakeSocket(handler: (request: any, reply: (body: unknown) => void) => void) {
  const socket: SocketLike & { sent: any[]; push(body: unknown): void } = {
    readyState: 1, sent: [], onopen: null, onclose: null, onerror: null, onmessage: null,
    send(data) { const request = JSON.parse(data); socket.sent.push(request); queueMicrotask(() => handler(request, (b) => socket.push(b))); },
    close() { socket.onclose?.({}); },
    push(body) { socket.onmessage?.({ data: JSON.stringify(body) }); },
  };
  return socket;
}
const hello = { event: "hello", protocol: "slideblaster.cap/1", version: "0.2.0", root: "unit", providers: [{ id: "sb.tex", version: "0.2.0", slot: "block.render", kinds: ["tikz"], output: "image/svg+xml", available: false, missingTools: ["dvisvgm"] }] };

test("requests are pipelined, correlated by id, and errors carry the protocol code", async () => {
  const socket = fakeSocket((req, reply) => {
    if (req.op === "storage.read") reply({ id: req.id, ok: true, path: req.path, size: 3, sha256: "x", contentBase64: btoa("abc") });
    else if (req.op === "storage.list") reply({ id: req.id, ok: true, entries: [{ path: "a.md", kind: "file", size: 1 }] });
    else reply({ id: req.id, ok: false, error: { code: "not_found", message: "nope" } });
  });
  const client = createCapClient("ws://x/cap", () => socket);
  socket.push(hello);
  assert.equal((await client.ready()).root, "unit");
  const [bytes, entries] = await Promise.all([client.read("a.md"), client.listProject()]);
  assert.equal(new TextDecoder().decode(bytes), "abc");
  assert.equal(entries[0]!.path, "a.md");
  await assert.rejects(client.call("storage.delete"), (e: CapError) => e.code === "not_found");
  assert.deepEqual(socket.sent.map((r) => r.id), [1, 2, 3]);
});

test("save sends compare-and-replace bytes as base64 and null expected for create", async () => {
  const socket = fakeSocket((req, reply) => reply({ id: req.id, ok: true, path: req.path, sha256: "s", size: 2 }));
  const client = createCapClient("ws://x/cap", () => socket);
  await client.save("a.md", new Uint8Array([1, 2]), new Uint8Array([3]));
  await client.save("b.md", null, new Uint8Array([4]));
  assert.equal(socket.sent[0].expectedBase64, btoa("\u0001\u0002"));
  assert.equal(socket.sent[1].expectedBase64, null);
});

test("a closed connection rejects pending calls and later calls", async () => {
  const socket = fakeSocket(() => {});
  const client = createCapClient("ws://x/cap", () => socket);
  const pending = client.call("ping");
  socket.close();
  await assert.rejects(pending, (e: CapError) => e.code === "closed");
  await assert.rejects(client.call("ping"), (e: CapError) => e.code === "closed");
  assert.equal(client.state(), "closed");
});

test("watch events reach listeners", async () => {
  const socket = fakeSocket(() => {});
  const client = createCapClient("ws://x/cap", () => socket);
  const seen: unknown[] = [];
  client.onEvent((e) => seen.push(e));
  socket.push({ event: "watch", changes: [{ path: "figures/a.tikz", change: "modified" }] });
  assert.equal(seen.length, 1);
});

const effect = { ticket: 41, fingerprint: "ff", request: { slot: "block.render", kind: "tikz", fingerprint: "ff", input: { body: "x", width: 960 } } };

test("relay: a compiled artifact becomes a provider_result artifact in base16 with its intrinsic size", async () => {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="212.5" height="96"><rect/></svg>`;
  const sent: any[] = [];
  const out = await relayBlockRender(effect, { blockRender: async (r) => { sent.push(r); return { ticket: r.ticket, fingerprint: "ff", artifact: { mime: "image/svg+xml", encoding: "utf8", data: svg, size: svg.length, provenance: { provider: "sb.tex" } } }; } });
  assert.equal(sent[0].ticket, "t-41");
  assert.equal(sent[0].kind, "tikz");
  const a = out.artifact as any;
  assert.equal(new TextDecoder().decode(Uint8Array.from(a.bytesBase16.match(/../g).map((h: string) => parseInt(h, 16)))), svg);
  assert.deepEqual([a.width, a.height, a.provenance], [212.5, 96, "sb.tex"]);
});

test("relay: typed absence, errors and no provider all answer instead of throwing", async () => {
  const absent = await relayBlockRender(effect, { blockRender: async (r) => ({ ticket: r.ticket, fingerprint: "ff", absence: { reason: "tool_missing", provider: "sb.tex", tool: "dvisvgm" }, diagnostics: [{ severity: "warning", code: "provider.absent", message: "dvisvgm is not installed" }] }) });
  assert.equal((absent.diagnostics as any[])[0].absent, true);
  const failed = await relayBlockRender(effect, { blockRender: async (r) => ({ ticket: r.ticket, fingerprint: "ff", diagnostics: [{ severity: "error", code: "tex.error", message: "Undefined control sequence.", sourceLine: 14 }] }) });
  assert.equal((failed.diagnostics as any[])[0].line, 14);
  assert.equal((failed.diagnostics as any[])[0].absent, false);
  const none = await relayBlockRender(effect, null);
  assert.equal((none.diagnostics as any[])[0].absent, true);
  const thrown = await relayBlockRender(effect, { blockRender: async () => { throw new Error("socket closed"); } });
  assert.match((thrown.diagnostics as any[])[0].message, /socket closed/);
  const wrong = await relayBlockRender(effect, { blockRender: async () => ({ ticket: "t-99", fingerprint: "ff" }) });
  assert.equal((wrong.diagnostics as any[])[0].absent, true);
});

test("intrinsic SVG size reads width/height (pt converted) or the viewBox", () => {
  assert.deepEqual(svgIntrinsicSize(`<svg width="72pt" height="36pt"/>`), { width: 96, height: 48 });
  assert.deepEqual(svgIntrinsicSize(`<svg viewBox="0 0 560 220"/>`), { width: 560, height: 220 });
  assert.equal(svgIntrinsicSize("<div/>"), null);
});
