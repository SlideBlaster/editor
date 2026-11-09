#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
slideblaster2_root="$(cd -- "${script_directory}/.." && pwd)"
application_directory="${slideblaster2_root}/apps/slideblaster-web-wasm"
artifact_directory="${slideblaster2_root}/hosts/web/dist"
catalog_source_directory="${slideblaster2_root}/packages/slideblaster-catalog"
catalog_artifact_directory="${artifact_directory}/catalog"

if [[ -n "${WASM_GHC:-}" ]]; then
  wasm_ghc="${WASM_GHC}"
elif command -v wasm32-wasi-ghc-9.14 >/dev/null 2>&1; then
  wasm_ghc="$(command -v wasm32-wasi-ghc-9.14)"
elif command -v wasm32-wasi-ghc >/dev/null 2>&1; then
  wasm_ghc="$(command -v wasm32-wasi-ghc)"
else
  echo "No ghcup wasm32-wasi GHC was found. Set WASM_GHC explicitly." >&2
  exit 1
fi

tool_directory="$(dirname -- "${wasm_ghc}")"
compiler_name="$(basename -- "${wasm_ghc}")"
compiler_suffix="${compiler_name#wasm32-wasi-ghc}"
wasm_ghc_pkg="${WASM_GHC_PKG:-${tool_directory}/wasm32-wasi-ghc-pkg${compiler_suffix}}"
wasm_hsc2hs="${WASM_HSC2HS:-${tool_directory}/wasm32-wasi-hsc2hs${compiler_suffix}}"
wasm_cabal="${WASM_CABAL:-cabal}"
node_binary="${NODE_BINARY:-node}"

for executable in \
  "${wasm_ghc}" \
  "${wasm_ghc_pkg}" \
  "${wasm_hsc2hs}" \
  "${wasm_cabal}" \
  "${node_binary}"; do
  if ! command -v "${executable}" >/dev/null 2>&1; then
    echo "Required executable is unavailable: ${executable}" >&2
    exit 1
  fi
done

ghc_version="$("${wasm_ghc}" --numeric-version)"
if ! "${node_binary}" -e '
  const actual = process.argv[1].split(".").map(Number);
  const minimum = [9, 10, 1];
  while (actual.length < minimum.length) actual.push(0);
  const supported = actual.some(
    (part, index) =>
      part > minimum[index] &&
      actual.slice(0, index).every((earlier, earlierIndex) =>
        earlier === minimum[earlierIndex]
      ),
  ) || actual.every((part, index) => part === minimum[index]);
  process.exit(supported ? 0 : 1);
' "${ghc_version}"; then
  echo "GHC ${ghc_version} does not support the required GHC2024 language set." >&2
  echo "Use wasm32-wasi GHC 9.10.1 or newer; GHC 9.14.1 is the pinned baseline." >&2
  exit 1
fi

mkdir -p "${artifact_directory}" "${catalog_artifact_directory}"

cabal_toolchain=(
  "--builddir=dist-newstyle-wasm"
  "--with-compiler=${wasm_ghc}"
  "--with-hc-pkg=${wasm_ghc_pkg}"
  "--with-hsc2hs=${wasm_hsc2hs}"
)

(
  cd "${application_directory}"
  "${wasm_cabal}" build "${cabal_toolchain[@]}" exe:slideblaster-web-wasm
)

wasm_binary="$(
  cd "${application_directory}"
  "${wasm_cabal}" list-bin "${cabal_toolchain[@]}" exe:slideblaster-web-wasm
)"
output_wasm="${artifact_directory}/slideblaster-web-wasm.wasm"
output_js="${artifact_directory}/slideblaster-web-wasm.js"
post_link="$("${wasm_ghc}" --print-libdir)/post-link.mjs"

if [[ ! -f "${wasm_binary}" ]]; then
  echo "Cabal reported a missing Wasm executable: ${wasm_binary}" >&2
  exit 1
fi
if [[ ! -f "${post_link}" ]]; then
  echo "GHC JSFFI post-linker is unavailable: ${post_link}" >&2
  exit 1
fi

install -m 0644 "${wasm_binary}" "${output_wasm}"
"${node_binary}" "${post_link}" -i "${output_wasm}" -o "${output_js}"
install -m 0644 \
  "${catalog_source_directory}/data/drawio/catalog-v1.json" \
  "${catalog_artifact_directory}/catalog-v1.json"
install -m 0644 \
  "${catalog_source_directory}/THIRD_PARTY_NOTICES.md" \
  "${catalog_artifact_directory}/THIRD_PARTY_NOTICES.md"

echo "Built ${output_wasm}"
echo "Generated ${output_js}"
echo "Packaged ${catalog_artifact_directory}/catalog-v1.json"
echo "Packaged ${catalog_artifact_directory}/THIRD_PARTY_NOTICES.md"
