#!/usr/bin/env bash
# Build LaTeXML's external C dependencies to WebAssembly static archives.
# All three verified building with emscripten 3.1.6 in this spike:
#   libxml2  2.9.14 -> .libs/libxml2.a    (~1.7M)   behind XML::LibXML
#   libxslt  1.1.37 -> libxslt/.libs/libxslt.a   (~264K)  behind XML::LibXSLT
#   libexslt 1.1.37 -> libexslt/.libs/libexslt.a (~78K)   EXSLT, used by LaTeXML XSLT
#
# NOT covered here (decide in roadmap): Berkeley DB (libdb) for DB_File, and
# zlib (use emscripten's built-in port: -sUSE_ZLIB=1).
#
# Versions are pinned to match the native LaTeXML 0.8.8 toolchain on the dev box
# (libxml2 2.9.14, XML::LibXML 2.0134, XML::LibXSLT 2.002001).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
V="$HERE/vendor"
mkdir -p "$V"; cd "$V"

fetch() { [ -d "$2" ] || { curl -sL -o "$3" "$1"; tar xf "$3"; }; }

# --- libxml2 ---
fetch "https://download.gnome.org/sources/libxml2/2.9/libxml2-2.9.14.tar.xz" \
      "libxml2-2.9.14" "libxml2.tar.xz"
( cd libxml2-2.9.14
  emconfigure ./configure --host=wasm32 --disable-shared --enable-static \
    --without-python --without-zlib --without-lzma --without-iconv \
    --without-http --without-ftp --without-modules CFLAGS="-O2"
  emmake make -j"$(nproc)" libxml2.la )
XML2="$V/libxml2-2.9.14"

# --- libxslt + libexslt (need libxml2 headers) ---
fetch "https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.37.tar.xz" \
      "libxslt-1.1.37" "libxslt.tar.xz"
( cd libxslt-1.1.37
  emconfigure ./configure --host=wasm32 --disable-shared --enable-static \
    --without-python --without-crypto --without-debug \
    LIBXML_CFLAGS="-I$XML2/include" LIBXML_LIBS="-L$XML2/.libs -lxml2" \
    CFLAGS="-O2 -I$XML2/include"
  emmake make -j"$(nproc)" -C libxslt  libxslt.la
  emmake make -j"$(nproc)" -C libexslt libexslt.la )

echo "== WASM C archives =="
ls -lh "$XML2/.libs/libxml2.a" \
       "$V/libxslt-1.1.37/libxslt/.libs/libxslt.a" \
       "$V/libxslt-1.1.37/libexslt/.libs/libexslt.a"
