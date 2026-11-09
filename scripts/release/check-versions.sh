#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_directory}/../.." && pwd)"
version_file="${repository_root}/VERSION"

[[ -f "${version_file}" ]] || {
  echo "Missing VERSION file." >&2
  exit 1
}
product_version="$(tr -d '[:space:]' <"${version_file}")"
[[ "${product_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "VERSION must contain one semantic product version: ${product_version}" >&2
  exit 1
}
expected_cabal_version="${product_version}.0"

cabal_files=(
  adapters/slideblaster-adapter-native/slideblaster-adapter-native.cabal
  adapters/slideblaster-adapter-web/slideblaster-adapter-web.cabal
  apps/slideblaster-cli/slideblaster-cli.cabal
  apps/slideblaster-web-wasm/slideblaster-web-wasm.cabal
  packages/slideblaster-app/slideblaster-app.cabal
  packages/slideblaster-canvas/slideblaster-canvas.cabal
  packages/slideblaster-catalog/slideblaster-catalog.cabal
  packages/slideblaster-deck/slideblaster-deck.cabal
  packages/slideblaster-extension/slideblaster-extension.cabal
  packages/slideblaster-listing/slideblaster-listing.cabal
  packages/slideblaster-cite/slideblaster-cite.cabal
  packages/slideblaster-document/slideblaster-document.cabal
  packages/slideblaster-engine/slideblaster-engine.cabal
  packages/slideblaster-export/slideblaster-export.cabal
  packages/slideblaster-ports/slideblaster-ports.cabal
  packages/slideblaster-product-runtime/slideblaster-product-runtime.cabal
  packages/slideblaster-presentation/slideblaster-presentation.cabal
  packages/slideblaster-protocol/slideblaster-protocol.cabal
  packages/slideblaster-render/slideblaster-render.cabal
  packages/slideblaster-source/slideblaster-source.cabal
  packages/slideblaster-syntax/slideblaster-syntax.cabal
  packages/slideblaster-tikz/slideblaster-tikz.cabal
)

mapfile -t discovered_files < <(
  cd -- "${repository_root}"
  find adapters apps packages -type f -name '*.cabal' -print | sort
)
mapfile -t expected_files < <(printf '%s\n' "${cabal_files[@]}" | sort)
if [[ "${#discovered_files[@]}" -ne 22 ]] || \
   [[ "$(printf '%s\n' "${discovered_files[@]}")" != "$(printf '%s\n' "${expected_files[@]}")" ]]; then
  echo "Expected exactly the 22 declared Cabal files; update this checker deliberately." >&2
  printf 'Discovered:\n%s\n' "$(printf '  %s\n' "${discovered_files[@]}")" >&2
  exit 1
fi

for relative_path in "${cabal_files[@]}"; do
  declared_version="$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\).*$/\1/p' "${repository_root}/${relative_path}")"
  [[ "${declared_version}" == "${expected_cabal_version}" ]] || {
    echo "Version mismatch in ${relative_path}: expected ${expected_cabal_version}, found ${declared_version:-<missing>}" >&2
    exit 1
  }
done

printf 'Version %s maps consistently to Cabal %s across all 22 packages.\n' \
  "${product_version}" "${expected_cabal_version}"
