#!/usr/bin/env bash
# Fetch the prebuilt LaTeXML browser runtime (perl-web.js/.wasm/.data) from the
# "engine-v1" GitHub Release instead of committing ~21 MB of binaries to git.
#
# Idempotent and sha256-verified: a file already present with the right hash is
# left untouched, so this is cheap to run before every build. SlideBlaster/editor
# is public, so no auth/token is needed (plain curl on the release download URL).
# Rebuild the runtime with build-web.sh, then cut a new engine-vN release and bump
# the tag + hashes below. See README.md.
set -euo pipefail

repo="SlideBlaster/editor"
tag="engine-v1"
dist="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dist"
base="https://github.com/${repo}/releases/download/${tag}"

mkdir -p "$dist"
while read -r name want; do
  [ -n "$name" ] || continue
  dest="$dist/$name"
  if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$want" ]; then
    echo "engine: $name present and verified"
    continue
  fi
  echo "engine: fetching $name from release $tag"
  curl -fSL --retry 3 --retry-delay 2 -o "$dest.tmp" "$base/$name"
  got="$(sha256sum "$dest.tmp" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    rm -f "$dest.tmp"
    { echo "engine: ERROR checksum mismatch for $name"; echo "  want $want"; echo "  got  $got"; } >&2
    exit 1
  fi
  mv -f "$dest.tmp" "$dest"
  echo "engine: $name ok"
done <<'EOF'
perl-web.js 1488facaa260de51b99072828a4f47deedec893bb64b63c978eef99028190184
perl-web.wasm 5fb001706f5d482cbbce54da9a2191d413c41868f17fc73fdb4aabcbddf332ff
perl-web.data c46eee15d690dbe88a7d2b61731ac9a47736ef716bd1bc6573005266dabdd995
EOF
echo "engine: browser runtime ready in $dist"
