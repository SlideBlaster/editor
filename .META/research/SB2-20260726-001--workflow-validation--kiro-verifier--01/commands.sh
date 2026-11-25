#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_directory}/../../.." && pwd)"
cd -- "${repository_root}"

printf '%s\n' '== bash syntax and executable modes =='
for script in scripts/session/*.sh scripts/research/*.sh scripts/release/*.sh; do
  test -x "${script}"
  bash -n "${script}"
  printf 'ok %s\n' "${script}"
done

printf '%s\n' '== metadata =='
make metadata-validate

printf '%s\n' '== versions =='
make release-version-check

printf '%s\n' '== ignore boundaries =='
git check-ignore -q .META/sources/drawio
git check-ignore -q \
  .META/research/SB2-20260726-001--workflow-validation--kiro-verifier--01/artifacts/ignored-smoke.txt
if git check-ignore -q .META/sources/manifests/README.md; then
  echo 'Source manifests must remain trackable.' >&2
  exit 1
fi
if git check-ignore -q \
  .META/research/SB2-20260726-001--workflow-validation--kiro-verifier--01/README.md; then
  echo 'Research reports must remain trackable.' >&2
  exit 1
fi
for tracked_path in \
  .META/design/README.md \
  .META/knowledge/README.md \
  .META/sessions/SB2-20260726-001/.prompt \
  .META/sessions/SB2-20260726-001/STEERING.md \
  .META/sessions/SB2-20260726-001/REVIEW.md; do
  if git check-ignore -q "${tracked_path}"; then
    echo "Required .META authority record is ignored: ${tracked_path}" >&2
    exit 1
  fi
done
printf '%s\n' 'ignore boundaries passed'

printf '%s\n' '== option-like worktree path =='
if ./scripts/session/worktree.sh plan SB2-20260726-001 --force \
  >"${TMPDIR:-/tmp}/sb2-option-path.out" \
  2>"${TMPDIR:-/tmp}/sb2-option-path.err"; then
  echo 'Option-like worktree path was accepted.' >&2
  exit 1
fi
grep -Fq "must not begin with '-'" "${TMPDIR:-/tmp}/sb2-option-path.err"
printf '%s\n' 'option-like path rejected'

printf '%s\n' '== release fails closed before candidate commit =='
if ./scripts/release/verify.sh \
  >"${TMPDIR:-/tmp}/sb2-release-dirty.out" \
  2>"${TMPDIR:-/tmp}/sb2-release-dirty.err"; then
  echo 'Dirty release candidate was accepted.' >&2
  exit 1
fi
grep -Fq 'Release verification requires a clean worktree.' \
  "${TMPDIR:-/tmp}/sb2-release-dirty.err"
printf '%s\n' 'dirty release candidate rejected'

printf '%s\n' '== diff whitespace =='
git diff --check
printf '%s\n' 'all repository-local workflow checks passed'
