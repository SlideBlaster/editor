# Third-party notices

## draw.io / diagrams.net shape stencils

`data/drawio/catalog-v1.json` contains geometry derived from the shape stencils
of draw.io (diagrams.net).

- Source: [draw.io](https://github.com/jgraph/drawio), directory
  `src/main/webapp/stencils/`, by JGraph Ltd and the draw.io contributors.
- Copyright: © JGraph Ltd and the draw.io contributors.
- License recorded by SlideBlaster 1: the imported shape/stencil snapshot was
  attributed under the [Creative Commons Attribution 4.0 International License
  (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/). The draw.io source
  code itself is Apache-2.0; no draw.io source code is included here.
- Modifications: mxGraph stencil XML was converted into normalized SVG path
  data. Original fill/stroke styling was dropped so presets inherit the
  SlideBlaster theme. Labels, categories, and search keywords were derived from
  stencil names and curated in SlideBlaster 1.
- Scope: only JGraph-authored generic-geometry sets were imported. Vendor and
  brand icon sets with additional terms were deliberately excluded.

The JSON records the exact SlideBlaster 1 source revisions and SHA-256 hashes
used for this migration. SlideBlaster 1 did not record the corresponding
draw.io upstream commit, so this snapshot must not be presented as a reproducible
upstream import until that pin has been reviewed and chosen.

This attribution is provided under CC BY 4.0 §3(a). Use of these shapes does not
imply endorsement by JGraph Ltd or the draw.io project.
