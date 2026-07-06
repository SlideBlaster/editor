# themeEditor.ts

`openThemeEditor(opts) -> { close }`: the **theme studio**, a direct-manipulation editor
over a `Theme` (ADR 0017) so an author shapes a theme on the slide itself, not by hand-
editing JSON or filling a form.

A centred modal with two areas:

- **Stage** — a faithful themed slide canvas (`#sb-te-preview > .sb-slide`) sized to the
  theme's aspect ratio. It is painted by `themeStylesheet(theme)`, scoped to the preview
  (`scopeCss`) so the type/colours match the real deck exactly; `container-type:inline-size`
  on the canvas makes the `cqw` type scale to the preview like a real slide. On top:
  - **Region boundaries** — each `layout.regions[i]` is a draggable + 8-handle-resizable
    rectangle editing its `RelRect` fractions, with the region name and a ghost of the
    seeded class' themed type inside. Edges snap to the canvas thirds, safe-area insets,
    and sibling region edges (orange guide lines).
  - **Logo** and **page number** — chips you drag freely; on drop they snap to the nearest
    of the nine anchors (`anchorFromCentre`, resting at `anchorRestPos`, matching
    furnitureCss). The logo has a resize grip driving `furniture.logo.size`.
- **Rail** — the non-spatial bits: theme name, aspect (16:9 / 4:3 / 16:10), palette
  (`#sb-te-color-{bg,ink,accent}`), object add/toggles (`+ region`, `#sb-te-logo-show`,
  `#sb-te-pn-show`), a context **inspector** (`#sb-te-inspector`) for the selected object
  (rename / seed-class / anchor / size / delete / page-number format), a
  "show boundaries on deck" toggle (`#sb-te-regions`), and **Save** (`#sb-te-save`).

Behaviour:

- Edits a `structuredClone` working copy; every change streams through `onChange(theme,
  {showRegions})` for **live preview** on the real deck behind, and `onSave(theme)` persists.
- Coupling is only the engine `Theme` model + `themeStylesheet`, so the module needs no
  `app.css` and is safe to build/verify against the engine alone. Stable ids above are
  the automation contract.

`createApp` wires it: the app-bar **Theme** button opens it; `onChange` updates a dynamic
`<style id="sb-theme">` (`themeStylesheet` + `furnitureCss`) and re-decorates the deck
(`furnitureHtml` per slide + a `regionRects` boundary overlay); `onSave` writes
`themes/<id>/theme.json` via the Storage port using `serializeTheme`. Loading a saved
theme back on boot is a follow-up (the theme-loader increment).
