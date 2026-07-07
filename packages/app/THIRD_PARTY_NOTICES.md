# Third-party notices

SlideBlaster bundles third-party assets. Their licenses and required attributions
are reproduced below.

## draw.io / diagrams.net shape stencils

The shapes library (`packages/app/src/shapes/stencils.generated.ts` and the geometry
registry `packages/editor/src/render/stencils.generated.ts`) is **derived from the shape
stencils of draw.io (diagrams.net)**.

- **Source:** draw.io — <https://github.com/jgraph/drawio>
  (`src/main/webapp/stencils/`), by JGraph Ltd and the draw.io contributors.
- **Copyright:** © JGraph Ltd and the draw.io contributors.
- **License:** the draw.io _source code_ is Apache License 2.0; the shape/stencil
  _assets_ imported here are licensed **Creative Commons Attribution 4.0 International
  (CC BY 4.0)** — <https://creativecommons.org/licenses/by/4.0/>.
- **Modifications:** the mxGraph stencil XML was converted into normalized SVG path
  data and TikZ node-option presets (see `design/format/stencil-pipeline.md`). The
  original fill/stroke styling was dropped so shapes inherit SlideBlaster's theme; labels,
  categories, and search keywords were derived from the stencil names. **No draw.io source
  code is included** — only the shape geometry.
- **Scope:** only the JGraph-authored, cleanly-licensed generic-geometry sets were
  imported — Arrows, Basic, BPMN, Cabinets, Electrical, EIP, Floorplan, Flowchart, Fluid
  Power, Lean Mapping, Mockup, Networks, PID, Rack (general), Signs, Sitemap. **Vendor and
  brand icon sets were deliberately excluded** (AWS, Azure, GCP, Cisco, IBM, Kubernetes,
  Oracle, Salesforce, VMware, Alibaba, Citrix, Android, iOS, Office, and vendor-named rack
  faceplates), as those carry additional third-party terms.

This attribution is provided under CC BY 4.0 §3(a). Use of these shapes does not imply
endorsement by JGraph Ltd or the draw.io project.
