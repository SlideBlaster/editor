import assert from "node:assert/strict";
import { test } from "node:test";
import { heldKeySteps } from "../src/presenter/windows.ts";

test("a held key sends one step at a time and stops when it is let go", () => {
  const sent: string[] = [];
  let clock = 0;
  const keys = heldKeySteps((command) => sent.push(command), () => clock);
  keys.press("next", false);
  // repeats arrive every 30 ms while the first step is still being painted
  for (let i = 0; i < 5; i++) { clock += 30; keys.press("next", true); }
  assert.equal(sent.length, 1);
  keys.shown();
  keys.press("next", true);
  assert.equal(sent.length, 2);
  // shown at once, but repeats are still no faster than about eight a second
  keys.shown();
  clock += 30; keys.press("next", true);
  assert.equal(sent.length, 2);
  clock += 100; keys.press("next", true);
  assert.equal(sent.length, 3);
});

test("a fresh press is always sent, and a lost answer does not block for ever", () => {
  const sent: string[] = [];
  let clock = 0;
  const keys = heldKeySteps((command) => sent.push(command), () => clock);
  keys.press("next", false);
  keys.press("back", false);
  assert.deepEqual(sent, ["next", "back"]);
  clock += 1001; keys.press("next", true);
  assert.equal(sent.length, 3);
});
