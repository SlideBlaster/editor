#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <SB2-YYYYMMDD-NNN> <task-slug> <agent-slug> [run]" >&2
  exit 2
}

[[ $# -eq 3 || $# -eq 4 ]] || usage
session_id="$1"
task_slug="$2"
agent_slug="$3"
requested_run="${4:-}"

[[ "${session_id}" =~ ^SB2-[0-9]{8}-[0-9]{3}$ ]] || usage
[[ "${task_slug}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || usage
[[ "${agent_slug}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || usage
[[ -z "${requested_run}" || "${requested_run}" =~ ^[0-9]{2}$ ]] || usage

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_directory}/../.." && pwd)"
research_root="${repository_root}/.META/research"
template="${repository_root}/.META/templates/research-artifact.md"
session_directory="${repository_root}/.META/sessions/${session_id}"

[[ -d "${session_directory}" ]] || {
  echo "Unknown session: ${session_id}" >&2
  exit 1
}
[[ -f "${template}" ]] || {
  echo "Missing research template: ${template}" >&2
  exit 1
}

if [[ -n "${requested_run}" ]]; then
  run_id="${requested_run}"
else
  highest=0
  shopt -s nullglob
  for path in "${research_root}/${session_id}--${task_slug}--${agent_slug}--"??; do
    [[ -d "${path}" ]] || continue
    suffix="${path##*--}"
    if [[ "${suffix}" =~ ^[0-9]{2}$ && 10#${suffix} -gt highest ]]; then
      highest=$((10#${suffix}))
    fi
  done
  shopt -u nullglob
  (( highest < 99 )) || {
    echo "No two-digit research run IDs remain for this task and agent." >&2
    exit 1
  }
  printf -v run_id '%02d' "$((highest + 1))"
fi

research_slug="${session_id}--${task_slug}--${agent_slug}--${run_id}"
research_directory="${research_root}/${research_slug}"
[[ ! -e "${research_directory}" ]] || {
  echo "Research artifact already exists: ${research_slug}" >&2
  exit 1
}

mkdir -p -- "${research_directory}"
cleanup=true
trap 'if [[ "${cleanup}" == true ]]; then rm -rf -- "${research_directory}"; fi' EXIT
sed \
  -e "s|{{RESEARCH_SLUG}}|${research_slug}|g" \
  -e "s|{{SESSION_ID}}|${session_id}|g" \
  -e "s|{{TASK_SLUG}}|${task_slug}|g" \
  -e "s|{{AGENT_SLUG}}|${agent_slug}|g" \
  -e "s|{{RUN_ID}}|${run_id}|g" \
  -e "s|{{DATE}}|$(date +%F)|g" \
  "${template}" >"${research_directory}/README.md"
cleanup=false
trap - EXIT
printf 'Created research artifact %s\n' "${research_slug}"
