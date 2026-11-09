import test from "node:test";
import assert from "node:assert/strict";
import { applyEdits, createOffsetMap, editsFromChanges } from "../src/source/offsets.ts";

const sample = "aé€\u{1F600}b\n## Tête {#x}";
const bytes = new TextEncoder().encode(sample);

test("char to byte offsets agree with the UTF-8 encoding for 1-, 2-, 3- and 4-byte characters", () => {
  const map = createOffsetMap(sample);
  assert.equal(map.byteLength, bytes.length);
  let char = 0;
  for (const ch of sample) {
    assert.equal(map.toByte(char), new TextEncoder().encode(sample.slice(0, char)).length, `at ${char}`);
    char += ch.length;
  }
  assert.equal(map.toByte(sample.length), bytes.length);
});

test("byte to char is the inverse on character boundaries and rounds down inside a character", () => {
  const map = createOffsetMap(sample);
  let char = 0;
  for (const ch of sample) {
    assert.equal(map.toChar(map.toByte(char)), char);
    char += ch.length;
  }
  assert.equal(map.toChar(map.toByte(3) + 1), 3, "inside the euro sign rounds down");
  assert.equal(map.toChar(map.toByte(3) + 2), 3);
  assert.equal(map.toChar(1_000_000), sample.length);
  assert.equal(map.toChar(-4), 0);
});

test("multi-change transactions become exact-byte edits that apply last-to-first", () => {
  const text = "alpha é beta € gamma";
  const edits = editsFromChanges(text, [
    { fromA: 0, toA: 5, inserted: "ALPHA" },
    { fromA: 8, toA: 12, inserted: "" },
    { fromA: 13, toA: 13, inserted: "\u{1F600}" },
  ]);
  assert.deepEqual(edits.map((e) => e.range.start), [...edits.map((e) => e.range.start)].sort((a, b) => b - a));
  const result = new TextDecoder().decode(applyEdits(new TextEncoder().encode(text), edits));
  assert.equal(result, "ALPHA \u00e9  \u{1F600}\u20ac gamma");
});

test("an edit's expected bytes are exactly the replaced bytes", () => {
  const [edit] = editsFromChanges(sample, [{ fromA: 1, toA: 3, inserted: "X" }]);
  assert.equal(new TextDecoder().decode(edit!.expected), sample.slice(1, 3));
  assert.deepEqual(edit!.range, { start: 1, end: 1 + edit!.expected.length });
  assert.throws(() => applyEdits(new TextEncoder().encode("zzz"), [edit!]));
});
