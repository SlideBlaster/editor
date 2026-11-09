/**
 * FIXTURE STAND-IN for the Haskell core's `session/1` lowering. It emits the plans the
 * design's normative sample deck (alpha.md 3.5) lowers to, in the exact wire shape of
 * `docs/specs/session-v1-protocol.md`, so the painter, rail, presenter and smoke tests
 * run before (and independently of) the native core. Nothing in the real host imports
 * this except the `?fixture=1` development mode and tests.
 */
import type { Box, Content, Item, Plan, TextStyle } from "../protocol/plan.ts";
import { base16FromBytes, type NavigatorItem, type View, type ViewDiagnostic } from "../protocol/session.ts";

export interface SampleOptions {
  readonly revision: number;
  readonly source: Uint8Array;
  /** Slide titles as the (stand-in) core currently reads them from the source. */
  readonly titles?: Readonly<Record<string, string>>;
  readonly session?: number;
  readonly saved?: number;
  /** `pending` placeholder, `compiled` figure, `stale` figure with badge, `absent` provider. */
  readonly figure?: "pending" | "compiled" | "stale" | "absent";
  readonly logos?: Readonly<Record<string, string>>;
  readonly activeFrame?: string;
  readonly activeStep?: number;
}

const W = 1280;
const H = 720;
const ink = "#1a1a2e";
const font = "'Segoe UI', system-ui, -apple-system, sans-serif";
const body = (size: number, extra: Partial<TextStyle> = {}): TextStyle =>
  ({ font, size, weight: 400, italic: false, color: ink, align: "left", lineHeight: 1.35, ...extra });
const hexOf = (text: string): string => base16FromBytes(new TextEncoder().encode(text));
/** Theme 16x9 y-up unit box to session px (the core does this conversion for real). */
const unitBox = (x: number, y: number, w: number, h: number): Box => ({ x: x * 80, y: H - (y + h) * 80, width: w * 80, height: h * 80 });
const t = (text: string): Content => ({ t: "text", text });
const p = (...children: Content[]): Content => ({ t: "p", children });
const li = (reserved: boolean, ...children: Content[]): Content => reserved
  ? { t: "reserved", children: [{ t: "li", children }] }
  : { t: "li", children };

const archSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="560" height="220" viewBox="0 0 560 220" font-family="sans-serif" font-size="16">
<defs><marker id="a" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8z" fill="#1f4e79"/></marker></defs>
<g fill="#e8eef5" stroke="#1f4e79" stroke-width="2"><rect x="10" y="70" width="120" height="70" rx="8"/><rect x="220" y="20" width="120" height="70" rx="8"/><rect x="220" y="120" width="120" height="70" rx="8"/><rect x="430" y="70" width="120" height="70" rx="8"/></g>
<g fill="#1a1a2e" text-anchor="middle"><text x="70" y="110">P4 program</text><text x="280" y="60">Parser model</text><text x="280" y="160">Table model</text><text x="490" y="110">CTL* checker</text></g>
<g stroke="#1f4e79" stroke-width="2" marker-end="url(#a)" fill="none"><path d="M130,95 L220,60"/><path d="M130,115 L220,150"/><path d="M340,55 L430,90"/><path d="M340,155 L430,120"/></g></svg>`;

const p4 = [
  "control Ingress(inout headers h) {",
  "  table fwd { key = { h.ipv4.dst: lpm; } actions = { route; drop; } }",
  "  apply {",
  "    fwd.apply();",
  "  }",
  "}",
];

interface SlideDef {
  frame: string;
  title: string;
  steps: number;
  items: (step: number, o: SampleOptions) => Item[];
  notes?: string;
}

const defs: SlideDef[] = [
  {
    frame: "title", title: "P4Check", steps: 1,
    items: () => [
      text("t-title", unitBox(1.6, 5.0, 12.8, 1.5), body(56, { weight: 700, align: "center" }), [t("P4Check")]),
      text("t-sub", unitBox(1.6, 4.2, 12.8, 0.8), body(36, { align: "center", color: "#555555" }), [t("Branching-time model checking for P4")]),
      text("t-authors", unitBox(1.6, 3.4, 12.8, 0.6), body(28, { align: "center" }), [t("Tommaso Pacciani")]),
      text("t-inst", unitBox(1.6, 2.9, 12.8, 0.5), body(24, { align: "center", color: "#555555" }), [t("University of Amsterdam")]),
      text("t-date", unitBox(1.6, 2.4, 12.8, 0.5), body(24, { align: "center", color: "#555555" }), [t("2026-11")]),
    ],
  },
  {
    frame: "why", title: "Why verify data planes?", steps: 4,
    notes: "Open with the outage story. Step 3 is the pivot to model checking.",
    items: (s) => [
      flow("why-body", unitBox(0.9, 1.4, 14.2, 5.7), body(32), [
        { t: "ul", children: [
          li(false, t("Testing shows the presence of bugs, not their absence "), { t: "cite", children: [t("[1]")] }),
          li(s < 1, t("A P4 program is a state machine over packets")),
          li(s < 2, t("We check "), { t: "math", display: false, tex: "\\mathcal{M} \\models \\mathsf{AG}\\,\\neg\\mathit{bad}" }),
        ] },
        ...(s >= 3 ? [{ t: "box", title: [t("Definition: Safety")], fill: "#e8eef5", titleFill: "#1f4e79",
          children: [p(t("No reachable state satisfies "), { t: "math", display: false, tex: "\\mathit{bad}" }, t("."))] } as Content]
          : [{ t: "reserved", children: [{ t: "box", title: [t("Definition: Safety")], fill: "#e8eef5", titleFill: "#1f4e79", children: [p(t("No reachable state satisfies bad."))] }] } as Content]),
      ]),
      text("why-foot", unitBox(0.9, 0.85, 12.6, 0.5), body(20, { color: "#555555" }), [t("[1] E. W. Dijkstra, Notes on structured programming, 1970.")]),
    ],
  },
  {
    frame: "prog", title: "The program", steps: 2,
    items: (s) => [
      flow("prog-body", unitBox(0.9, 1.4, 14.2, 5.7), body(30), [
        { t: "columns", columns: [
          { width: "55%", children: [{ t: "codeblock", language: "p4", lines: p4, highlight: s === 0 ? [2] : [3, 4] }] },
          { width: "45%", children: [{ t: "box", title: [t("Observation")], fill: "#e9eefc", titleFill: "#2962ff",
            children: [p(t(`Table contents are ${s === 0 ? "fixed" : "symbolic"} during checking.`))] }] },
        ] },
      ]),
    ],
  },
  {
    frame: "arch", title: "Architecture", steps: 1,
    items: (_s, o) => {
      const box = unitBox(2.2, 1.6, 11.6, 5.4);
      const fingerprint = "9f2c1ab04e6d77f1";
      switch (o.figure ?? "compiled") {
        case "pending":
          return [{ kind: "placeholder", id: "arch-fig", box, label: "figures/p4checkarch.tikz", state: "pending", fingerprint }];
        case "absent":
          return [{ kind: "placeholder", id: "arch-fig", box, label: "figures/p4checkarch.tikz", state: "absent", fingerprint, message: "latex is not installed; cannot render tikz" }];
        default:
          return [{ kind: "figure", id: "arch-fig", box, fingerprint, artifact: { mime: "image/svg+xml", bytesBase16: hexOf(archSvg) }, fit: "contain", stale: o.figure === "stale" }];
      }
    },
  },
  {
    frame: "results", title: "Results", steps: 1,
    items: () => [
      flow("res-body", unitBox(0.9, 1.4, 9.5, 5.7), body(30), [
        { t: "table",
          head: [[cell("l", "Benchmark"), cell("r", "States"), cell("r", "Time (s)")]],
          body: [[cell("l", "basic_tunnel"), cell("r", "1 204"), cell("r", "0.8")], [cell("l", "load_balance"), cell("r", "48 911"), cell("r", "12.3")]] },
        p(t("Compared to the state of the art "), { t: "cite", children: [t("[2, 3]")] }, t(".")),
      ]),
      { kind: "rect", id: "tk", box: { x: 880, y: 460, width: 304, height: 88 }, fill: "#2e7d3226", stroke: { color: "#2e7d32", width: 2 }, radius: 8, opacity: 1, hit: { nodeId: "tk" } },
      text("tk-text", { x: 892, y: 470, width: 280, height: 68 }, body(26, { align: "center" }), [{ t: "math", display: false, tex: "\\mathsf{Reach}" }, t(" is decidable here")]),
      { kind: "line", id: "tk-arrow", from: { x: 1032, y: 460 }, to: { x: 1032, y: 330 }, stroke: { color: "#2e7d32", width: 2, dash: null }, arrow: "end", hit: { nodeId: "tk-arrow" } },
    ],
  },
  {
    frame: "refs", title: "References", steps: 1,
    items: () => [
      flow("refs-body", unitBox(0.9, 1.4, 14.2, 5.7), body(28), [
        { t: "ol", children: [
          li(false, t("E. W. Dijkstra. Notes on structured programming. 1970.")),
          li(false, t("P4LTL: runtime verification of P4 programs. 2020.")),
          li(false, t("bf4: towards bug-free P4 programs. SIGCOMM 2020.")),
        ] },
      ]),
    ],
  },
];

const cell = (align: "l" | "c" | "r", text: string) => ({ align, children: [t(text)] });
function text(id: string, box: Box, style: TextStyle, content: Content[]): Item {
  return { kind: "text", id, box, style, content, visibility: "visible" };
}
function flow(id: string, box: Box, style: TextStyle, content: Content[]): Item {
  return { kind: "flow", id, box, style, content };
}

function furniture(index: number, count: number, o: SampleOptions): Item[] {
  const logo = (name: string, box: Box): Item[] => o.logos?.[name] === undefined ? [] : [
    { kind: "image", id: `logo-${name}`, box, resource: { mime: "image/svg+xml", bytesBase16: o.logos[name]! }, alt: "logo", fit: "contain" },
  ];
  if (index === 0) {
    return [...logo("logo-fns", unitBox(4.1, 0.5, 3.35, 2.16)), ...logo("logo-uva", unitBox(8.4, 1.2, 3.6, 0.8))];
  }
  return [
    ...logo("logo-small", unitBox(14.11, 0.54, 1.44, 0.72)),
    text("f-page", unitBox(13.0, 0.3, 1, 0.5), body(20, { align: "right", color: "#555555" }), [t(`${index + 1}/${count}`)]),
    text("f-foot", unitBox(0.9, 0.3, 10, 0.5), body(20, { color: "#555555" }), [t("P4Check")]),
  ];
}

function planFor(def: SlideDef, index: number, count: number, step: number, o: SampleOptions, surface: "audience" | "notes"): Plan {
  const title = o.titles?.[def.frame] ?? def.title;
  const items: Item[] = surface === "notes"
    ? [flow(`${def.frame}-notes`, unitBox(0.9, 1.4, 14.2, 5.7), body(32), [p(t(def.notes ?? ""))])]
    : [
        ...furniture(index, count, o),
        ...(index === 0 ? [] : [text(`${def.frame}-title`, unitBox(0.9, 7.3, 14.2, 1.2), body(58, { weight: 400, color: "#000000" }), [t(title)])]),
        ...def.items(step, o).map((item) => (index === 0 && item.kind === "text" && item.id === "t-title"
          ? { ...item, content: [t(o.titles?.[def.frame] ?? "P4Check")] } : item)),
      ];
  return {
    protocol: "slideblaster.session/1", frame: def.frame, surface, step: step + 1, steps: def.steps,
    revision: o.revision, ticket: o.revision * 100 + index * 10 + step + (surface === "notes" ? 5 : 0),
    session: o.session ?? 1, coordinateSpace: "slide_y_down", size: { width: W, height: H },
    background: { fill: "#ffffff" }, items,
  };
}

export const sampleDiagnostics: readonly ViewDiagnostic[] = [
  { severity: "warning", code: "cite.bibliography-missing", message: "Bibliography refs.bib was not found; citations render unresolved", span: null, frame: "why" },
  { severity: "info", code: "frontmatter.unknown-key", message: "Unknown front-matter key retained", span: null, frame: null },
];

/** Locate a substring's UTF-8 byte span; used to give fixture diagnostics real spans. */
export function byteSpanOf(source: Uint8Array, needle: string, from = 0): { start: number; end: number } | null {
  const encoded = new TextEncoder().encode(needle);
  outer: for (let i = from; i + encoded.length <= source.length; i += 1) {
    for (let j = 0; j < encoded.length; j += 1) if (source[i + j] !== encoded[j]) continue outer;
    return { start: i, end: i + encoded.length };
  }
  return null;
}

export function buildSampleView(o: SampleOptions): View {
  const count = defs.length;
  const items: NavigatorItem[] = defs.map((def, index) => {
    const head = byteSpanOf(o.source, `## ${def.title}`) ?? byteSpanOf(o.source, "---") ?? { start: 0, end: 0 };
    const next = defs[index + 1];
    const end = next === undefined ? o.source.length : (byteSpanOf(o.source, `## ${next.title}`)?.start ?? o.source.length);
    return {
      frame: def.frame,
      title: o.titles?.[def.frame] ?? def.title,
      span: { start: index === 0 ? 0 : head.start, end },
      steps: def.steps,
      audience: planFor(def, index, count, def.steps - 1, o, "audience"),
      notes: def.notes === undefined ? null : planFor(def, index, count, 0, o, "notes"),
    };
  });
  const activeFrame = o.activeFrame ?? "title";
  const activeIndex = Math.max(0, defs.findIndex((d) => d.frame === activeFrame));
  const activeDef = defs[activeIndex]!;
  const step = Math.min(o.activeStep ?? activeDef.steps - 1, activeDef.steps - 1);
  const plan = planFor(activeDef, activeIndex, count, step, o, "audience");
  const diagnostics: ViewDiagnostic[] = sampleDiagnostics.map((d) => {
    const needle = d.code === "cite.bibliography-missing" ? "bibliography: refs.bib" : "institute: ";
    return { ...d, span: byteSpanOf(o.source, needle) };
  });
  return {
    revision: o.revision, session: o.session ?? 1, saved: o.saved ?? o.revision, ready: true,
    frontmatter: { title: "P4Check", theme: "fns", aspect: "16:9", size: { width: W, height: H } },
    navigator: { activeIndex, activeFrame, slideCount: count, items },
    active: { fence: { session: o.session ?? 1, revision: o.revision, ticket: plan.ticket, surface: { frame: activeFrame, kind: "audience" } }, plan, step: step + 1 },
    diagnostics,
    commands: {
      previous_slide: { enabled: activeIndex > 0 }, next_slide: { enabled: activeIndex < count - 1 },
      new_slide: { enabled: true }, undo: { enabled: o.revision > 0 }, redo: { enabled: false }, save: { enabled: (o.saved ?? o.revision) !== o.revision },
    },
    presenter: null,
  };
}

export const sampleFrames: readonly { frame: string; steps: number }[] = defs.map((d) => ({ frame: d.frame, steps: d.steps }));
export { planFor as samplePlanFor, defs as sampleDefs };
