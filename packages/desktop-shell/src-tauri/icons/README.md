# Icons

Placeholder PNGs (solid brand blue) so `tauri dev` runs out of the box on Linux.

Before packaging for release (`tauri build`, especially macOS/Windows), generate the
full cross-platform icon set from a single 1024x1024 source PNG:

```
corepack pnpm --filter @slideblaster/desktop-shell tauri icon path/to/icon.png
```

That regenerates these PNGs plus `icon.icns` (macOS) and `icon.ico` (Windows), and
you should then add those two files back to `bundle.icon` in `../tauri.conf.json`.
