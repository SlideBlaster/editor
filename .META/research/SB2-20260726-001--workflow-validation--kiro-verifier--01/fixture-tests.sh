#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_directory}/../../.." && pwd)"

copy_metadata_fixture() {
  local destination="$1"
  mkdir -p "${destination}/scripts" "${destination}/.META/sources"
  cp -a "${repository_root}/scripts/session" "${destination}/scripts/"
  cp -a "${repository_root}/scripts/research" "${destination}/scripts/"
  cp -a "${repository_root}/.META/templates" "${destination}/.META/"
  cp -a "${repository_root}/.META/design" "${destination}/.META/"
  cp -a "${repository_root}/.META/knowledge" "${destination}/.META/"
  cp -a "${repository_root}/.META/sessions" "${destination}/.META/"
  cp -a "${repository_root}/.META/research" "${destination}/.META/"
  cp "${repository_root}/.META/README.md" "${destination}/.META/README.md"
  cp "${repository_root}/.META/sources/README.md" \
    "${destination}/.META/sources/README.md"
  cp -a "${repository_root}/.META/sources/manifests" \
    "${destination}/.META/sources/"
  cp "${repository_root}/.gitignore" "${destination}/.gitignore"
}

init_git() {
  local repository="$1"
  git -C "${repository}" init -q -b dev
  git -C "${repository}" config user.name 'Workflow Fixture'
  git -C "${repository}" config user.email 'workflow-fixture@example.invalid'
  git -C "${repository}" add .
  git -C "${repository}" commit -qm 'fixture base'
  git -C "${repository}" branch main
}

printf '%s\n' '== typed sessions, research, and worktrees =='
workflow_fixture="$(mktemp -d /tmp/slideblaster2-workflow-final.XXXXXX)"
copy_metadata_fixture "${workflow_fixture}"
init_git "${workflow_fixture}"

printf '%s\n' 'Initial research fixture prompt.' | \
  "${workflow_fixture}/scripts/session/create.sh" \
    research 'Research fixture' - SB2-20260726-002
test "$(cat "${workflow_fixture}/.META/sessions/SB2-20260726-002/.prompt")" = \
  'Initial research fixture prompt.'
test -f "${workflow_fixture}/.META/sessions/SB2-20260726-002/RESEARCH.md"
test -f "${workflow_fixture}/.META/sessions/SB2-20260726-002/STEERING.md"
test -f "${workflow_fixture}/.META/sessions/SB2-20260726-002/REVIEW.md"
test ! -e "${workflow_fixture}/.META/sessions/SB2-20260726-002/SPEC.md"
git -C "${workflow_fixture}" add .META/sessions/SB2-20260726-002
git -C "${workflow_fixture}" commit -qm 'register research session'

printf '%s\n' 'Initial maintenance fixture prompt.' | \
  "${workflow_fixture}/scripts/session/create.sh" \
    maintenance 'Maintenance fixture' - SB2-20260726-003
test "$(cat "${workflow_fixture}/.META/sessions/SB2-20260726-003/.prompt")" = \
  'Initial maintenance fixture prompt.'
test -f "${workflow_fixture}/.META/sessions/SB2-20260726-003/MAINTENANCE.md"
test -f "${workflow_fixture}/.META/sessions/SB2-20260726-003/STEERING.md"
test -f "${workflow_fixture}/.META/sessions/SB2-20260726-003/REVIEW.md"
test ! -e "${workflow_fixture}/.META/sessions/SB2-20260726-003/SLICES.md"
git -C "${workflow_fixture}" add .META/sessions/SB2-20260726-003
git -C "${workflow_fixture}" commit -qm 'register maintenance session'

printf '%s\n' 'Initial implementation fixture prompt.' | \
  "${workflow_fixture}/scripts/session/create.sh" \
    implementation 'Implementation fixture' - SB2-20260726-004
test "$(cat "${workflow_fixture}/.META/sessions/SB2-20260726-004/.prompt")" = \
  'Initial implementation fixture prompt.'
test -f "${workflow_fixture}/.META/sessions/SB2-20260726-004/SPEC.md"
test -f "${workflow_fixture}/.META/sessions/SB2-20260726-004/SLICES.md"
test -f "${workflow_fixture}/.META/sessions/SB2-20260726-004/STEERING.md"
test -f "${workflow_fixture}/.META/sessions/SB2-20260726-004/REVIEW.md"
git -C "${workflow_fixture}" add .META/sessions/SB2-20260726-004

git -C "${workflow_fixture}" commit -qm 'register implementation session'

implementation_session="${workflow_fixture}/.META/sessions/SB2-20260726-004"
cp "${implementation_session}/SESSION.md" \
  "${implementation_session}/SESSION.md.open"
sed -i 's/- Status: `active`/- Status: `closed`/' \
  "${implementation_session}/SESSION.md"
if "${workflow_fixture}/scripts/session/validate.sh" SB2-20260726-004 \
  >"${workflow_fixture}/unsupported-close.out" \
  2>"${workflow_fixture}/unsupported-close.err"; then
  echo 'Session closed without product-owner evidence was accepted.' >&2
  exit 1
fi
grep -Fq 'requires an exact non-pending Artifact revision' \
  "${workflow_fixture}/unsupported-close.err"
mv "${implementation_session}/SESSION.md.open" \
  "${implementation_session}/SESSION.md"
printf 'unsupported closure rejected: %s\n' \
  "$(cat "${workflow_fixture}/unsupported-close.err")"
rm -f "${workflow_fixture}/unsupported-close.out" \
  "${workflow_fixture}/unsupported-close.err"
registration_commit="$(git -C "${workflow_fixture}" rev-parse HEAD)"

"${workflow_fixture}/scripts/research/create.sh" \
  SB2-20260726-002 compile-time kiro-verifier 01
test -f "${workflow_fixture}/.META/research/SB2-20260726-002--compile-time--kiro-verifier--01/README.md"
git -C "${workflow_fixture}" add .META/research
git -C "${workflow_fixture}" commit -qm 'record research artifact'

if "${workflow_fixture}/scripts/session/worktree.sh" \
  plan SB2-20260726-004 --force; then
  echo 'Option-like worktree path was accepted.' >&2
  exit 1
else
  test "$?" -eq 2
fi

good_worktree="${workflow_fixture}-good"
"${workflow_fixture}/scripts/session/worktree.sh" create \
  SB2-20260726-004 "${good_worktree}" --confirm
printf '\nLater dev-only status note.\n' >> \
  "${workflow_fixture}/.META/sessions/SB2-20260726-004/SESSION.md"
git -C "${workflow_fixture}" add \
  .META/sessions/SB2-20260726-004/SESSION.md
git -C "${workflow_fixture}" commit -qm 'update implementation session on dev'
validation="$(
  "${workflow_fixture}/scripts/session/worktree.sh" validate \
    SB2-20260726-004 "${good_worktree}"
)"
printf '%s\n' "${validation}"
registration_short="$(
  git -C "${workflow_fixture}" rev-parse --short "${registration_commit}"
)"
grep -Fq "registration ${registration_short}" <<<"${validation}"

printf '%s\n' 'Initial wrong-base fixture prompt.' | \
  "${workflow_fixture}/scripts/session/create.sh" \
    implementation 'Wrong base fixture' - SB2-20260726-005
git -C "${workflow_fixture}" add .META/sessions/SB2-20260726-005
git -C "${workflow_fixture}" commit -qm 'register wrong-base session'
bad_worktree="${workflow_fixture}-bad"
git -C "${workflow_fixture}" worktree add -q \
  -b session/SB2-20260726-005 "${bad_worktree}" main
if "${workflow_fixture}/scripts/session/worktree.sh" validate \
  SB2-20260726-005 "${bad_worktree}" \
  >"${workflow_fixture}/bad-base.out" \
  2>"${workflow_fixture}/bad-base.err"; then
  echo 'Branch without its registration commit was accepted.' >&2
  exit 1
fi
grep -Fq 'does not contain its dev registration commit' \
  "${workflow_fixture}/bad-base.err"
printf 'wrong-base rejection: %s\n' \
  "$(cat "${workflow_fixture}/bad-base.err")"

printf '%s\n' '== explicit product-owner closure state =='
closed_session="${workflow_fixture}/.META/sessions/SB2-20260726-003"
integration_commit="$(git -C "${workflow_fixture}" rev-parse HEAD)"
review_base="$(git -C "${workflow_fixture}" rev-parse "${integration_commit}^")"
sed -i \
  -e 's/- Status: `active`/- Status: `closed`/' \
  -e "s/- Artifact revision: \`pending\`/- Artifact revision: \`${integration_commit}\`/" \
  -e 's/- Demonstration requested: `pending`/- Demonstration requested: `yes`/' \
  -e 's/- Observation question: `pending`/- Observation question: `Can you observe the fixture outcome?`/' \
  -e 's/- Observation response: `pending`/- Observation response: `Yes, the fixture outcome is visible.`/' \
  -e 's/- User observed artifact: `pending`/- User observed artifact: `yes`/' \
  -e 's/- Acceptance question: `pending`/- Acceptance question: `Does the fixture outcome meet its intended outcome?`/' \
  -e 's/- Acceptance response: `pending`/- Acceptance response: `Yes, the fixture outcome is accepted.`/' \
  -e 's/- Specification or outcome accepted: `pending`/- Specification or outcome accepted: `yes`/' \
  -e 's/- Steering resolved: `pending`/- Steering resolved: `yes`/' \
  -e "s/- Review unit: \`pending\`/- Review unit: \`commits:${review_base}..${integration_commit}\`/" \
  -e 's/- Change review request: `pending`/- Change review request: `Please review the recorded fixture commit range.`/' \
  -e 's/- Change review response: `pending`/- Change review response: `The fixture commit range is approved.`/' \
  -e 's/- Product-owner review: `pending`/- Product-owner review: `approved`/' \
  -e 's/- Integrated to dev: `pending`/- Integrated to dev: `yes`/' \
  -e "s/- Integration commit: \`pending\`/- Integration commit: \`${integration_commit}\`/" \
  -e 's/- Closure requested: `pending`/- Closure requested: `yes`/' \
  -e 's/- Closure question: `pending`/- Closure question: `Do you approve closing fixture session SB2-20260726-003?`/' \
  -e 's/- Closure response: `pending`/- Closure response: `Yes, close fixture session SB2-20260726-003.`/' \
  -e 's/- Product-owner closure: `pending`/- Product-owner closure: `approved`/' \
  "${closed_session}/SESSION.md" "${closed_session}/REVIEW.md"

sed -i 's/- Closure response: `Yes, close fixture session SB2-20260726-003.`/- Closure response: `pending`/' \
  "${closed_session}/REVIEW.md"
if missing_response="$("${workflow_fixture}/scripts/session/validate.sh" \
  SB2-20260726-003 2>&1)"; then
  echo 'Closure without an explicit response was accepted.' >&2
  exit 1
fi
grep -Fq 'requires recorded Closure response' <<<"${missing_response}"
sed -i 's/- Closure response: `pending`/- Closure response: `Yes, close fixture session SB2-20260726-003.`/' \
  "${closed_session}/REVIEW.md"

exact_review="commits:${review_base}..${integration_commit}"
sed -i "s|${exact_review}|not-an-exact-change-unit|" \
  "${closed_session}/REVIEW.md"
if bad_review="$("${workflow_fixture}/scripts/session/validate.sh" \
  SB2-20260726-003 2>&1)"; then
  echo 'Malformed review unit was accepted.' >&2
  exit 1
fi
grep -Fq 'requires an exact pr:, mr:, commits:, patch:, diff:, or local-diff:' \
  <<<"${bad_review}"
sed -i "s|not-an-exact-change-unit|${exact_review}|" \
  "${closed_session}/REVIEW.md"

cat >>"${closed_session}/STEERING.md" <<'STEERING'

## STR-999

- Disposition: `pending`
STEERING
if pending_steering="$("${workflow_fixture}/scripts/session/validate.sh" \
  SB2-20260726-003 2>&1)"; then
  echo 'Closure with pending steering was accepted.' >&2
  exit 1
fi
grep -Fq 'has unresolved or invalid material steering' <<<"${pending_steering}"
sed -i 's/- Disposition: `pending`/- Disposition: `applied`/' \
  "${closed_session}/STEERING.md"
steering_backup="$(mktemp /tmp/sb2-steering-backup.XXXXXX)"
cp "${closed_session}/STEERING.md" "${steering_backup}"
cat >>"${closed_session}/STEERING.md" <<'STEERING'
- Disposition: `applied`

## STR-998

This entry deliberately has no disposition.
STEERING
if masked_steering="$("${workflow_fixture}/scripts/session/validate.sh" \
  SB2-20260726-003 2>&1)"; then
  echo 'Duplicate steering disposition masked a missing disposition.' >&2
  exit 1
fi
grep -Fq 'has unresolved or invalid material steering' <<<"${masked_steering}"
mv "${steering_backup}" "${closed_session}/STEERING.md"
printf '%s\n' 'missing closure response, malformed review unit, pending steering, and disposition masking rejected'

git -C "${workflow_fixture}" add .META/sessions/SB2-20260726-003
git -C "${workflow_fixture}" commit -qm 'record explicit fixture closure'
"${workflow_fixture}/scripts/session/validate.sh" SB2-20260726-003
printf 'explicit closure accepted at integration %s\n' "${integration_commit}"

printf 'workflow fixture: %s\n' "${workflow_fixture}"
printf 'immutable registration: %s\n' "${registration_commit}"

printf '%s\n' '== release preview and explicit fixture-only promotion =='
release_fixture="$(mktemp -d /tmp/slideblaster2-release-final.XXXXXX)"
mkdir -p "${release_fixture}/scripts"
cp -a "${repository_root}/scripts/release" "${release_fixture}/scripts/"
git -C "${release_fixture}" init -q -b dev
git -C "${release_fixture}" config user.name 'Release Fixture'
git -C "${release_fixture}" config user.email 'release-fixture@example.invalid'
printf 'bootstrap\n' >"${release_fixture}/README"
git -C "${release_fixture}" add README
git -C "${release_fixture}" commit -qm 'bootstrap'
git -C "${release_fixture}" branch main

cabal_files=(
  adapters/slideblaster-adapter-native/slideblaster-adapter-native.cabal
  adapters/slideblaster-adapter-web/slideblaster-adapter-web.cabal
  apps/slideblaster-cli/slideblaster-cli.cabal
  apps/slideblaster-web-wasm/slideblaster-web-wasm.cabal
  packages/slideblaster-app/slideblaster-app.cabal
  packages/slideblaster-canvas/slideblaster-canvas.cabal
  packages/slideblaster-catalog/slideblaster-catalog.cabal
  packages/slideblaster-document/slideblaster-document.cabal
  packages/slideblaster-engine/slideblaster-engine.cabal
  packages/slideblaster-export/slideblaster-export.cabal
  packages/slideblaster-ports/slideblaster-ports.cabal
  packages/slideblaster-presentation/slideblaster-presentation.cabal
  packages/slideblaster-protocol/slideblaster-protocol.cabal
  packages/slideblaster-render/slideblaster-render.cabal
  packages/slideblaster-source/slideblaster-source.cabal
  packages/slideblaster-tikz/slideblaster-tikz.cabal
)
for relative_path in "${cabal_files[@]}"; do
  mkdir -p "${release_fixture}/$(dirname -- "${relative_path}")"
  printf 'name: smoke\nversion: 0.1.0.0\n' > \
    "${release_fixture}/${relative_path}"
done
printf '0.1.0\n' >"${release_fixture}/VERSION"
printf '# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-07-26\n' > \
  "${release_fixture}/CHANGELOG.md"
git -C "${release_fixture}" add .
git -C "${release_fixture}" commit -qm 'prepare release 0.1.0'

"${release_fixture}/scripts/release/verify.sh"
old_main="$(git -C "${release_fixture}" rev-parse main)"
"${release_fixture}/scripts/release/promote.sh"
test "$(git -C "${release_fixture}" rev-parse main)" = "${old_main}"
"${release_fixture}/scripts/release/promote.sh" --execute --confirm 0.1.0
test "$(git -C "${release_fixture}" rev-parse main)" = \
  "$(git -C "${release_fixture}" rev-parse dev)"
if grep -R -E '(^|[[:space:]])git([[:space:]].*)?[[:space:]]push([[:space:]]|$)' \
  "${release_fixture}/scripts/release"; then
  echo 'Release helper contains a push command.' >&2
  exit 1
fi
printf 'later same-version change\n' >"${release_fixture}/later"
git -C "${release_fixture}" add later
git -C "${release_fixture}" commit -qm 'later same-version change'
if "${release_fixture}/scripts/release/verify.sh" \
  >"${release_fixture}/same-version.out" \
  2>"${release_fixture}/same-version.err"; then
  echo 'Same-version main advance was accepted.' >&2
  exit 1
fi
grep -Fq 'Every main advance requires a new product version' \
  "${release_fixture}/same-version.err"
printf 'same-version rejection: %s\n' \
  "$(cat "${release_fixture}/same-version.err")"
printf 'release fixture: %s\n' "${release_fixture}"
printf '%s\n' 'all isolated workflow fixture checks passed'
