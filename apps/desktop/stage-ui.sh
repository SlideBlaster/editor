#!/usr/bin/env bash
# stage-ui.sh: copy the built editor (hosts/web) into ui-dist/, the folder the desktop app embeds.
# The app serves these files itself; nothing is fetched from a server at run time.
# Build first: (cd ../../hosts/web && npm ci && npm run build) and ../../scripts/build-wasm.sh
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
web=$here/../../hosts/web
out=$here/ui-dist
[ -f "$web/dist/src/alpha.js" ] || { echo "stage-ui: hosts/web is not built (npm run build)" >&2; exit 1; }
[ -f "$web/dist/slideblaster-web-wasm.wasm" ] || { echo "stage-ui: the core is not built (scripts/build-wasm.sh)" >&2; exit 1; }
grep -qa sb_session_dispatch "$web/dist/slideblaster-web-wasm.wasm" || { echo "stage-ui: the built core is older than session/1 in the page; run scripts/build-wasm.sh" >&2; exit 1; }
rm -rf "$out"
mkdir -p "$out"
cp "$web"/index.html "$web"/console.html "$web"/audience.html "$web"/*.css "$out"/
# everything the pages load, without source maps and the offline viewer (that one is for `sb build`)
(cd "$web" && find dist -type f ! -name '*.map' ! -path 'dist/offline/*' -print0) | while IFS= read -r -d '' file; do
  mkdir -p "$out/$(dirname "$file")"
  cp "$web/$file" "$out/$file"
done
echo "staged $(find "$out" -type f | wc -l) files, $(du -sh "$out" | cut -f1), in $out"
