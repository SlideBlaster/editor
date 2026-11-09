#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_directory}/../.." && pwd)"

"${script_directory}/check-versions.sh"
product_version="$(tr -d '[:space:]' <"${repository_root}/VERSION")"
changelog="${repository_root}/CHANGELOG.md"

[[ -f "${changelog}" ]] || {
  echo "Missing CHANGELOG.md." >&2
  exit 1
}
grep -Fqx '## [Unreleased]' "${changelog}" || {
  echo "CHANGELOG.md must retain an Unreleased section." >&2
  exit 1
}
grep -Eq "^## \[${product_version//./\.}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "${changelog}" || {
  echo "CHANGELOG.md needs a dated ${product_version} release entry." >&2
  exit 1
}

for branch in dev main; do
  git -C "${repository_root}" show-ref --verify --quiet "refs/heads/${branch}" || {
    echo "Missing local branch: ${branch}" >&2
    exit 1
  }
done
if git -C "${repository_root}" cat-file -e main:VERSION 2>/dev/null; then
  main_version="$(git -C "${repository_root}" show main:VERSION | tr -d '[:space:]')"
  [[ "${main_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "main contains an invalid VERSION: ${main_version}" >&2
    exit 1
  }
  [[ "${product_version}" != "${main_version}" ]] || {
    echo "Every main advance requires a new product version; main is already ${main_version}." >&2
    exit 1
  }
fi

current_branch="$(git -C "${repository_root}" symbolic-ref --quiet --short HEAD)" || {
  echo "Release verification requires a branch, not detached HEAD." >&2
  exit 1
}
[[ "${current_branch}" == dev ]] || {
  echo "Release candidates are verified from dev; current branch is ${current_branch}." >&2
  exit 1
}
[[ "$(git -C "${repository_root}" rev-parse HEAD)" == "$(git -C "${repository_root}" rev-parse dev)" ]] || {
  echo "Current HEAD is not the dev branch tip." >&2
  exit 1
}
[[ -z "$(git -C "${repository_root}" status --porcelain --untracked-files=normal)" ]] || {
  echo "Release verification requires a clean worktree." >&2
  exit 1
}
git -C "${repository_root}" merge-base --is-ancestor main dev || {
  echo "main is not an ancestor of dev; fast-forward promotion is impossible." >&2
  exit 1
}

printf 'Release candidate %s is clean on dev; main can fast-forward to %s.\n' \
  "${product_version}" "$(git -C "${repository_root}" rev-parse --short dev)"
