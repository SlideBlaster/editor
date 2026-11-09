#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 [SB2-YYYYMMDD-NNN]" >&2
  exit 2
}
[[ $# -le 1 ]] || usage
requested_id="${1:-}"

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_directory}/../.." && pwd)"
sessions_directory="${repository_root}/.META/sessions"
research_directory="${repository_root}/.META/research"

required_metadata=(
  .META/README.md
  .META/design/README.md
  .META/knowledge/README.md
  .META/research/README.md
  .META/sessions/README.md
  .META/sources/README.md
  .META/sources/manifests/README.md
  .META/templates/research-artifact.md
  .META/templates/session/common/STEERING.md
  .META/templates/session/common/REVIEW.md
  .META/templates/session/implementation/SESSION.md
  .META/templates/session/implementation/SPEC.md
  .META/templates/session/implementation/SLICES.md
  .META/templates/session/research/SESSION.md
  .META/templates/session/research/RESEARCH.md
  .META/templates/session/maintenance/SESSION.md
  .META/templates/session/maintenance/MAINTENANCE.md
)
for relative_path in "${required_metadata[@]}"; do
  [[ -f "${repository_root}/${relative_path}" ]] || {
    echo "Missing .META authority file: ${relative_path}" >&2
    exit 1
  }
done

field_value() {
  local field="$1"
  local record="$2"
  sed -n "s/^- ${field}: \`\([^\`]*\)\`$/\1/p" "${record}"
}

require_review_value() {
  local id="$1"
  local record="$2"
  local field="$3"
  local expected="$4"
  local actual
  actual="$(field_value "${field}" "${record}")"
  [[ "${actual}" == "${expected}" ]] || {
    echo "Session ${id} requires ${field}=${expected}; found ${actual:-<missing>}" >&2
    return 1
  }
}

require_review_recorded() {
  local id="$1"
  local record="$2"
  local field="$3"
  local actual
  actual="$(field_value "${field}" "${record}")"
  [[ -n "${actual}" && "${actual}" != pending ]] || {
    echo "Session ${id} requires recorded ${field}" >&2
    return 1
  }
}

validate_resolved_steering() {
  local id="$1"
  local steering="$2"
  awk '
    function finish_entry() {
      if (in_entry && dispositions != 1) invalid = 1
    }
    /^## STR-/ {
      finish_entry()
      if ($0 !~ /^## STR-[0-9][0-9][0-9]$/) invalid = 1
      in_entry = 1
      dispositions = 0
      next
    }
    in_entry && /^- Disposition:/ {
      dispositions++
      if ($0 !~ /^- Disposition: `(applied|deferred-by-user|superseded)`$/) {
        invalid = 1
      }
    }
    END {
      finish_entry()
      exit invalid
    }
  ' "${steering}" || {
    echo "Session ${id} has unresolved or invalid material steering" >&2
    return 1
  }
}

validate_state() {
  local id="$1"
  local status="$2"
  local review="$3"
  local steering="$4"
  local review_unit integration_commit artifact_revision closure_question

  case "${status}" in
    active|blocked|ready-for-demonstration|changes-requested|ready-for-review|approved-for-integration|integrated-awaiting-close|closed) ;;
    *)
      echo "Unsupported or missing session status for ${id}: ${status:-<empty>}" >&2
      return 1
      ;;
  esac

  case "${status}" in
    ready-for-review|approved-for-integration|integrated-awaiting-close|closed)
      artifact_revision="$(field_value "Artifact revision" "${review}")"
      [[ -n "${artifact_revision}" && "${artifact_revision}" != pending ]] || {
        echo "Session ${id} requires an exact non-pending Artifact revision" >&2
        return 1
      }
      require_review_value "${id}" "${review}" "Demonstration requested" yes
      require_review_recorded "${id}" "${review}" "Observation question"
      require_review_recorded "${id}" "${review}" "Observation response"
      require_review_value "${id}" "${review}" "User observed artifact" yes
      require_review_recorded "${id}" "${review}" "Acceptance question"
      require_review_recorded "${id}" "${review}" "Acceptance response"
      require_review_value "${id}" "${review}" "Specification or outcome accepted" yes
      require_review_value "${id}" "${review}" "Steering resolved" yes
      validate_resolved_steering "${id}" "${steering}"
      ;;
  esac
  case "${status}" in
    approved-for-integration|integrated-awaiting-close|closed)
      require_review_value "${id}" "${review}" "Product-owner review" approved
      require_review_recorded "${id}" "${review}" "Change review request"
      require_review_recorded "${id}" "${review}" "Change review response"
      review_unit="$(field_value "Review unit" "${review}")"
      [[ "${review_unit}" =~ ^(pr|mr|patch|diff|local-diff):[^[:space:]]+$ || \
        "${review_unit}" =~ ^commits:[0-9a-f]{40}\.\.[0-9a-f]{40}$ ]] || {
        echo "Session ${id} requires an exact pr:, mr:, commits:, patch:, diff:, or local-diff: Review unit" >&2
        return 1
      }
      ;;
  esac
  case "${status}" in
    integrated-awaiting-close|closed)
      require_review_value "${id}" "${review}" "Integrated to dev" yes
      integration_commit="$(field_value "Integration commit" "${review}")"
      [[ "${integration_commit}" =~ ^[0-9a-f]{40}$ ]] || {
        echo "Session ${id} requires a full Integration commit" >&2
        return 1
      }
      git -C "${repository_root}" merge-base --is-ancestor \
        "${integration_commit}" dev 2>/dev/null || {
        echo "Session ${id} integration commit is not contained in dev" >&2
        return 1
      }
      ;;
  esac
  if [[ "${status}" == closed ]]; then
    require_review_value "${id}" "${review}" "Closure requested" yes
    require_review_recorded "${id}" "${review}" "Closure question"
    closure_question="$(field_value "Closure question" "${review}")"
    [[ "${closure_question}" == *"${id}"* ]] || {
      echo "Session ${id} closure question must name the session ID" >&2
      return 1
    }
    require_review_recorded "${id}" "${review}" "Closure response"
    require_review_value "${id}" "${review}" "Product-owner closure" approved
  fi
}

validate_session() {
  local directory="$1"
  local id="${directory##*/}"
  local record="${directory}/SESSION.md"
  local review="${directory}/REVIEW.md"
  local session_type status

  [[ "${id}" =~ ^SB2-[0-9]{8}-[0-9]{3}$ ]] || {
    echo "Invalid session directory name: ${id}" >&2
    return 1
  }
  for common_file in .prompt SESSION.md STEERING.md REVIEW.md; do
    [[ -s "${directory}/${common_file}" ]] || {
      echo "Missing or empty ${common_file} for ${id}" >&2
      return 1
    }
  done
  grep -Fqx -- "- ID: \`${id}\`" "${record}" || {
    echo "SESSION.md ID mismatch for ${id}" >&2
    return 1
  }
  session_type="$(field_value Type "${record}")"
  case "${session_type}" in
    implementation)
      [[ -f "${directory}/SPEC.md" && -f "${directory}/SLICES.md" ]] || {
        echo "Implementation session ${id} requires SPEC.md and SLICES.md" >&2
        return 1
      }
      grep -Fqx -- "## Delivery artifacts" "${directory}/SPEC.md" || {
        echo "Implementation specification ${id} must define delivery artifacts" >&2
        return 1
      }
      grep -Fqx -- "## Product-owner demonstration" "${directory}/SPEC.md" || {
        echo "Implementation specification ${id} must define its product-owner demonstration" >&2
        return 1
      }
      ;;
    research)
      [[ -f "${directory}/RESEARCH.md" ]] || {
        echo "Research session ${id} requires RESEARCH.md" >&2
        return 1
      }
      [[ ! -e "${directory}/SPEC.md" && ! -e "${directory}/SLICES.md" ]] || {
        echo "Research session ${id} must use its type-specific template" >&2
        return 1
      }
      ;;
    maintenance)
      [[ -f "${directory}/MAINTENANCE.md" ]] || {
        echo "Maintenance session ${id} requires MAINTENANCE.md" >&2
        return 1
      }
      [[ ! -e "${directory}/SPEC.md" && ! -e "${directory}/SLICES.md" ]] || {
        echo "Maintenance session ${id} must use its type-specific template" >&2
        return 1
      }
      ;;
    *)
      echo "Unsupported or missing session type for ${id}: ${session_type:-<empty>}" >&2
      return 1
      ;;
  esac
  grep -Fqx -- "- Session branch: \`session/${id}\`" "${record}" || {
    echo "SESSION.md branch mismatch for ${id}" >&2
    return 1
  }
  status="$(field_value Status "${record}")"
  validate_state "${id}" "${status}" "${review}" "${directory}/STEERING.md"
  printf 'Valid %s session (%s): %s\n' "${session_type}" "${status}" "${id}"
}

validate_research() {
  local directory="$1"
  local slug="${directory##*/}"
  local record="${directory}/README.md"
  local session_id

  [[ "${slug}" =~ ^(SB2-[0-9]{8}-[0-9]{3})--[a-z0-9]+(-[a-z0-9]+)*--[a-z0-9]+(-[a-z0-9]+)*--[0-9]{2}$ ]] || {
    echo "Invalid research slug: ${slug}" >&2
    return 1
  }
  session_id="${BASH_REMATCH[1]}"
  [[ -d "${sessions_directory}/${session_id}" ]] || {
    echo "Research ${slug} refers to unknown session ${session_id}" >&2
    return 1
  }
  [[ -f "${record}" ]] || {
    echo "Missing README.md for research ${slug}" >&2
    return 1
  }
  grep -Fqx -- "- Slug: \`${slug}\`" "${record}" || {
    echo "Research README slug mismatch for ${slug}" >&2
    return 1
  }
  grep -Fqx -- "- Session: \`${session_id}\`" "${record}" || {
    echo "Research README session mismatch for ${slug}" >&2
    return 1
  }
  printf 'Valid research artifact: %s\n' "${slug}"
}

if [[ -n "${requested_id}" ]]; then
  [[ "${requested_id}" =~ ^SB2-[0-9]{8}-[0-9]{3}$ ]] || usage
  [[ -d "${sessions_directory}/${requested_id}" ]] || {
    echo "Unknown session: ${requested_id}" >&2
    exit 1
  }
  validate_session "${sessions_directory}/${requested_id}"
else
  shopt -s nullglob
  session_paths=("${sessions_directory}"/SB2-*)
  research_paths=("${research_directory}"/SB2-*--*)
  shopt -u nullglob
  for directory in "${session_paths[@]}"; do
    [[ -d "${directory}" ]] && validate_session "${directory}"
  done
  for directory in "${research_paths[@]}"; do
    [[ -d "${directory}" ]] && validate_research "${directory}"
  done
  if [[ ${#session_paths[@]} -eq 0 ]]; then
    echo ".META is valid; no session records exist."
  fi
fi
