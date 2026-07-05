#!/usr/bin/env bash
# Link a browser-targeted perl-web module: MODULARIZE factory, the LaTeXML
# filesystem preloaded into MEMFS (no disk needed), reuse-friendly runtime.
# Reuses the already-compiled perl objects + static XS archives from the node build.
set -euo pipefail
ENG="$(cd "$(dirname "$0")" && pwd)"
TREE="$ENG/vendor/perl-5.38.2"
STAGE="$ENG/build/fsroot"
OUTDIR="$ENG/dist"
mkdir -p "$OUTDIR"
cd "$TREE"

OBJS="$(cat "$ENG/build/objs.txt")"

export TMPDIR="$ENG/tmp"
emcc -o "$OUTDIR/perl-web.js" -O2 \
  -sMODULARIZE=1 -sEXPORT_NAME=createPerlModule \
  -sENVIRONMENT=web,webview,worker,node \
  -sINVOKE_RUN=0 -sEXIT_RUNTIME=0 \
  -sALLOW_MEMORY_GROWTH=1 -sERROR_ON_UNDEFINED_SYMBOLS=0 \
  -sTOTAL_STACK=67108864 -sINITIAL_MEMORY=134217728 -sMAXIMUM_MEMORY=2147483648 \
  -sFORCE_FILESYSTEM=1 -sNODERAWFS=0 \
  -sEXPORTED_RUNTIME_METHODS=callMain,FS,ENV,stringToUTF8,UTF8ToString,lengthBytesUTF8 \
  --preload-file "$STAGE@/sb" \
  $OBJS \
  $(cat "$TREE/ext.libs")

echo "=== built ==="
ls -la "$OUTDIR"/perl-web.js "$OUTDIR"/perl-web.wasm "$OUTDIR"/perl-web.data | awk '{print $5, $NF}'
