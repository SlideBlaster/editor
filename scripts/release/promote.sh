#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 [--execute --confirm <VERSION>]" >&2
  exit 2
}

execute=false
confirmation=""
if [[ $# -eq 0 ]]; then
  :
elif [[ $# -eq 3 && "$1" == --execute && "$2" == --confirm ]]; then
  execute=true
  confirmation="$3"
else
  usage
fi

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_directory}/../.." && pwd)"
product_version="$(tr -d '[:space:]' <"${repository_root}/VERSION")"

"${script_directory}/verify.sh"
old_main="$(git -C "${repository_root}" rev-parse main)"
new_main="$(git -C "${repository_root}" rev-parse dev)"

printf 'Promotion plan for release %s:\n' "${product_version}"
printf '  main %s\n' "$(git -C "${repository_root}" rev-parse --short main)"
printf '  dev  %s\n' "$(git -C "${repository_root}" rev-parse --short dev)"
printf '  action: local fast-forward of main to dev; no push\n'

if [[ "${execute}" == false ]]; then
  echo "No branch was changed. The product owner may rerun with:"
  printf '  %q --execute --confirm %q\n' "$0" "${product_version}"
  exit 0
fi
[[ "${confirmation}" == "${product_version}" ]] || {
  echo "Confirmation must exactly match VERSION (${product_version})." >&2
  exit 2
}

if git -C "${repository_root}" worktree list --porcelain | \
   grep -Fqx 'branch refs/heads/main'; then
  echo "Refusing to move main while it is checked out in a worktree." >&2
  exit 1
fi

git -C "${repository_root}" merge-base --is-ancestor "${old_main}" "${new_main}"
git -C "${repository_root}" branch -f main "${new_main}"
printf 'Promoted local main to %s for release %s. Nothing was pushed.\n' \
  "$(git -C "${repository_root}" rev-parse --short main)" "${product_version}"
