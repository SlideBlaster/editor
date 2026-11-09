import test from "node:test";
import assert from "node:assert/strict";
import { parseHTML } from "linkedom";
import { currentFolder, installSidebar, presentationLabel, resolveDeckFolder, type ShellBridge, type ShellPresentation } from "../src/ui/sidebar.ts";

test("label: title, else last path segment", () => {
  assert.equal(presentationLabel({ path: "/a/b/talk", title: "My Talk" }), "My Talk");
  assert.equal(presentationLabel({ path: "/a/b/talk/", title: " " }), "talk");
  assert.equal(presentationLabel({ path: "C:\\decks\\intro", title: "" }), "intro");
});

function setup(items: ShellPresentation[]) {
  const { document } = parseHTML(`<main id="w"><aside id="s" hidden></aside></main><button id="t" hidden></button>`);
  const calls: string[] = [];
  const shell: ShellBridge = {
    listPresentations: async () => items,
    openPresentation: async (p) => { calls.push(`open ${p}`); },
    addPresentation: async () => { calls.push("add"); },
    removePresentation: async (p) => { calls.push(`remove ${p}`); return items.filter((i) => i.path !== p); },
  };
  const store = new Map<string, string>();
  const api = installSidebar({
    doc: document as unknown as Document, shell, root: document.getElementById("s") as HTMLElement,
    toggle: document.getElementById("t") as HTMLButtonElement, workspace: document.getElementById("w") as HTMLElement,
    onError: (m) => calls.push(`error ${m}`), storage: { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => void store.set(k, v) },
  });
  return { document, calls, api, store };
}

const items: ShellPresentation[] = [
  { path: "/d/one", title: "One", lastOpened: 2, current: true },
  { path: "/d/two", title: "two", lastOpened: 1, current: false },
];

test("sidebar lists, highlights the current deck, switches and removes", async () => {
  const { document, calls, api } = setup(items);
  await api.refresh();
  const rows = [...document.querySelectorAll(".pres-item")];
  assert.equal(rows.length, 2);
  assert.equal(rows[0].getAttribute("data-current"), "true");
  assert.equal(document.getElementById("s")!.hidden, false);
  (rows[0].querySelector(".pres-open") as HTMLElement).click(); // current: no-op
  (rows[1].querySelector(".pres-open") as HTMLElement).click();
  (document.querySelector(".pres-add") as HTMLElement).click();
  (rows[1].querySelector(".pres-remove") as HTMLElement).click();
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(calls, ["open /d/two", "add", "remove /d/two"]);
  assert.equal(document.querySelectorAll(".pres-item").length, 1);
});

test("toggle collapses and remembers", () => {
  const { document, store } = setup(items);
  const w = document.getElementById("w")!;
  assert.equal(w.dataset.presentations, "open");
  document.getElementById("t")!.click();
  assert.equal(w.dataset.presentations, "collapsed");
  assert.equal(store.get("sb.presentations.collapsed"), "1");
});

test("included sub-presentations nest under their entry and switch the deck", async () => {
  const nested: ShellPresentation[] = [
    {
      path: "/d/parent", title: "Parent", lastOpened: 2, current: false,
      children: [
        { path: "/d/kid", title: "Kid", current: false, children: [{ path: "/d/kid/grand", title: "Grand", current: false, children: [] }] },
        { path: "/d/other", title: "Other", current: true, children: [] },
      ],
    },
    { path: "/d/two", title: "two", lastOpened: 1, current: false },
  ];
  const { document, calls, api } = setup(nested);
  await api.refresh();
  assert.equal(document.querySelectorAll(".pres-item").length, 2, "sub-decks are not top-level rows");
  const subs = [...document.querySelectorAll(".pres-sub-item")];
  assert.deepEqual(subs.map((e) => e.getAttribute("data-depth")), ["1", "2", "1"]);
  assert.equal(document.querySelector('.pres-sub-item[data-depth="2"]')!.parentElement!.parentElement!.getAttribute("data-depth"), "1");
  (subs[1].querySelector(".pres-open") as HTMLElement).click();
  (subs[2].querySelector(".pres-open") as HTMLElement).click(); // current: no-op
  assert.deepEqual(calls, ["open /d/kid/grand"]);
  assert.equal(currentFolder(nested), "/d/other");
});

test("an included deck's folder resolves against the open deck's folder", () => {
  assert.equal(resolveDeckFolder("/d/parent", "../kid/talk.slideBlaster.md"), "/d/kid");
  assert.equal(resolveDeckFolder("/d/parent", "kid/grand/g.slideBlaster.md"), "/d/parent/kid/grand");
  assert.equal(resolveDeckFolder("C:\\decks\\p", "..\\k\\t.slideBlaster.md"), "C:\\decks\\k");
});
