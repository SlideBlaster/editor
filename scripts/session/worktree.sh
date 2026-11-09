#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  worktree.sh plan <SB2-YYYYMMDD-NNN> <path>
  worktree.sh create <SB2-YYYYMMDD-NNN> <path> --confirm
  worktree.sh validate <SB2-YYYYMMDD-NNN> <path>
USAGE
  exit 2
}

[[ $# -ge 3 ]] || usage
action="$1"
session_id="$2"
worktree_path="$3"
confirmation="${4:-}"
[[ $# -le 4 ]] || usage
[[ "${session_id}" =~ ^SB2-[0-9]{8}-[0-9]{3}$ ]] || usage
[[ "${worktree_path}" != -* ]] || {
  echo "Worktree path must not begin with '-': ${worktree_path}" >&2
  exit 2
}

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_directory}/../.." && pwd)"
session_relative_path=".META/sessions/${session_id}/SESSION.md"
session_directory="${repository_root}/.META/sessions/${session_id}"
branch="session/${session_id}"

[[ -d "${session_directory}" ]] || {
  echo "Create and validate the session record first: ${session_id}" >&2
  exit 1
}
"${script_directory}/validate.sh" "${session_id}" >/dev/null

git -C "${repository_root}" show-ref --verify --quiet refs/heads/dev || {
  echo "Local dev branch does not exist." >&2
  exit 1
}
git -C "${repository_root}" cat-file -e \
  "dev:${session_relative_path}" 2>/dev/null || {
  echo "Session ${session_id} is not registered in dev; commit its record first." >&2
  exit 1
}
registration_commit="$(
  git -C "${repository_root}" log --diff-filter=A --format=%H --reverse \
    dev -- "${session_relative_path}" | head -n 1
)"
[[ -n "${registration_commit}" ]] || {
  echo "Cannot locate the dev registration commit for ${session_id}." >&2
  exit 1
}

validate_worktree() {
  [[ -d "${worktree_path}" ]] || {
    echo "Worktree path does not exist: ${worktree_path}" >&2
    return 1
  }
  local actual_branch actual_common expected_common
  actual_branch="$(git -C "${worktree_path}" symbolic-ref --quiet --short HEAD)" || {
    echo "Worktree has detached HEAD: ${worktree_path}" >&2
    return 1
  }
  [[ "${actual_branch}" == "${branch}" ]] || {
    echo "Expected branch ${branch}, found ${actual_branch}" >&2
    return 1
  }
  actual_common="$(cd -- "$(git -C "${worktree_path}" rev-parse --path-format=absolute --git-common-dir)" && pwd)"
  expected_common="$(cd -- "$(git -C "${repository_root}" rev-parse --path-format=absolute --git-common-dir)" && pwd)"
  [[ "${actual_common}" == "${expected_common}" ]] || {
    echo "Path belongs to a different Git repository: ${worktree_path}" >&2
    return 1
  }
  git -C "${repository_root}" merge-base --is-ancestor \
    "${registration_commit}" "${branch}" || {
    echo "Session branch does not contain its dev registration commit: ${branch}" >&2
    return 1
  }
  printf 'Valid worktree for %s (registration %s): %s\n' \
    "${session_id}" "$(git -C "${repository_root}" rev-parse --short "${registration_commit}")" \
    "$(cd -- "${worktree_path}" && pwd)"
}

case "${action}" in
  plan)
    [[ $# -eq 3 ]] || usage
    printf 'Would create external-capable worktree:\n  git worktree add -b %q %q dev\n' \
      "${branch}" "${worktree_path}"
    ;;
  create)
    [[ "${confirmation}" == "--confirm" ]] || {
      echo "Creation requires an explicit --confirm; use 'plan' first." >&2
      exit 2
    }
    git -C "${repository_root}" show-ref --verify --quiet "refs/heads/${branch}" && {
      echo "Branch already exists: ${branch}" >&2
      exit 1
    }
    [[ ! -e "${worktree_path}" ]] || {
      echo "Worktree path already exists: ${worktree_path}" >&2
      exit 1
    }
    git -C "${repository_root}" worktree add -b "${branch}" "${worktree_path}" dev
    validate_worktree
    ;;
  validate)
    [[ $# -eq 3 ]] || usage
    validate_worktree
    ;;
  *) usage ;;
esac
