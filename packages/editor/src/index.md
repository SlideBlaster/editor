# @slideblaster/editor (public surface)

The package entry point. Re-exports the port interfaces (`./ports`) and the engine's
**format spine**: the document model (`./model`), the markdown container round-trip
(`fromMarkdown` / `toMarkdown`), and the TikZ picture parse/serialize
(`parsePicture` / `serializePicture`).

Still to attach at later M1 stages: the tri-dialect node-content grammar, layout,
the HTML/SVG renderer, and edit ops.

Also exported: the structured **theme** model and its style-layer stylesheet
(`defaultTheme`, `themeStylesheet`, and the `Theme` types; ADR 0017). See
[theme/theme.md](theme/theme.md).
