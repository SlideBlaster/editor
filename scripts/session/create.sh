#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <implementation|research|maintenance> <title> <prompt-file|-> [SB2-YYYYMMDD-NNN]" >&2
  exit 2
}

[[ $# -eq 3 || $# -eq 4 ]] || usage
session_type="$1"
title="$2"
prompt_source="$3"
requested_id="${4:-}"

case "${session_type}" in
  implementation|research|maintenance) ;;
  *) usage ;;
esac
[[ -n "${title}" && "${title}" != *$'\n'* ]] || {
  echo "Session title must be non-empty and single-line." >&2
  exit 2
}
if [[ "${prompt_source}" != - ]]; then
  [[ -f "${prompt_source}" ]] || {
    echo "Prompt source is not a file: ${prompt_source}" >&2
    exit 2
  }
  [[ -s "${prompt_source}" ]] || {
    echo "Prompt source must not be empty: ${prompt_source}" >&2
    exit 2
  }
fi

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_directory}/../.." && pwd)"
sessions_directory="${repository_root}/.META/sessions"
template_directory="${repository_root}/.META/templates/session/${session_type}"
common_template_directory="${repository_root}/.META/templates/session/common"
today="$(date +%Y%m%d)"

git -C "${repository_root}" show-ref --verify --quiet refs/heads/dev || {
  echo "Local dev branch does not exist." >&2
  exit 1
}
current_branch="$(git -C "${repository_root}" symbolic-ref --quiet --short HEAD)" || {
  echo "Session registration requires a branch, not detached HEAD." >&2
  exit 1
}
[[ "${current_branch}" == dev ]] || {
  echo "Register new sessions from dev; current branch is ${current_branch}." >&2
  exit 1
}
[[ "$(git -C "${repository_root}" rev-parse HEAD)" == "$(git -C "${repository_root}" rev-parse dev)" ]] || {
  echo "Current HEAD is not the dev branch tip." >&2
  exit 1
}
[[ -z "$(git -C "${repository_root}" status --porcelain --untracked-files=normal)" ]] || {
  echo "Session registration requires a clean dev worktree." >&2
  exit 1
}

if [[ -n "${requested_id}" ]]; then
  session_id="${requested_id}"
else
  highest=0
  shopt -s nullglob
  for path in "${sessions_directory}/SB2-${today}-"???; do
    [[ -d "${path}" ]] || continue
    suffix="${path##*-}"
    if [[ "${suffix}" =~ ^[0-9]{3}$ ]] && (( 10#${suffix} > highest )); then
      highest=$((10#${suffix}))
    fi
  done
  shopt -u nullglob
  (( highest < 999 )) || {
    echo "No three-digit session IDs remain for ${today}." >&2
    exit 1
  }
  printf -v sequence '%03d' "$((highest + 1))"
  session_id="SB2-${today}-${sequence}"
fi

[[ "${session_id}" =~ ^SB2-[0-9]{8}-[0-9]{3}$ ]] || {
  echo "Invalid session ID: ${session_id}" >&2
  exit 2
}
session_date="${session_id:4:4}-${session_id:8:2}-${session_id:10:2}"
session_directory="${sessions_directory}/${session_id}"
[[ ! -e "${session_directory}" ]] || {
  echo "Session already exists: ${session_directory}" >&2
  exit 1
}
[[ -d "${template_directory}" && -d "${common_template_directory}" ]] || {
  echo "Missing session template directory." >&2
  exit 1
}

case "${session_type}" in
  implementation) type_template_files=(SESSION.md SPEC.md SLICES.md) ;;
  research) type_template_files=(SESSION.md RESEARCH.md) ;;
  maintenance) type_template_files=(SESSION.md MAINTENANCE.md) ;;
esac
common_template_files=(STEERING.md REVIEW.md)

mkdir -p -- "${session_directory}"
cleanup=true
trap 'if [[ "${cleanup}" == true ]]; then rm -rf -- "${session_directory}"; fi' EXIT
if [[ "${prompt_source}" == - ]]; then
  cat >"${session_directory}/.prompt"
else
  cat -- "${prompt_source}" >"${session_directory}/.prompt"
fi
[[ -s "${session_directory}/.prompt" ]] || {
  echo "The initiating prompt must not be empty." >&2
  exit 2
}
escaped_title="$(printf '%s' "${title}" | sed 's/[\&|]/\&/g')"
for file_name in "${type_template_files[@]}"; do
  source_path="${template_directory}/${file_name}"
  destination_path="${session_directory}/${file_name}"
  [[ -f "${source_path}" ]] || {
    echo "Missing template: ${source_path}" >&2
    exit 1
  }
  sed \
    -e "s|{{SESSION_ID}}|${session_id}|g" \
    -e "s|{{DATE}}|${session_date}|g" \
    -e "s|{{TITLE}}|${escaped_title}|g" \
    "${source_path}" >"${destination_path}"
done
for file_name in "${common_template_files[@]}"; do
  source_path="${common_template_directory}/${file_name}"
  destination_path="${session_directory}/${file_name}"
  [[ -f "${source_path}" ]] || {
    echo "Missing template: ${source_path}" >&2
    exit 1
  }
  sed \
    -e "s|{{SESSION_ID}}|${session_id}|g" \
    -e "s|{{DATE}}|${session_date}|g" \
    -e "s|{{TITLE}}|${escaped_title}|g" \
    "${source_path}" >"${destination_path}"
done
cleanup=false
trap - EXIT
printf 'Created %s session %s at %s\n' \
  "${session_type}" "${session_id}" "${session_directory}"
