# Research artifact: workflow-validation

- Slug: `SB2-20260726-001--workflow-validation--kiro-verifier--01`
- Session: `SB2-20260726-001`
- Task: `workflow-validation`
- Agent: `kiro-verifier`
- Run: `01`
- Created: `2026-07-26`
- Status: `concluded`

## Question

Do the dependency-free session, prompt, steering, specification-demonstration,
research, worktree, product-owner closure, and release helpers enforce the
accepted workflow without mutating product code or granting automatic
acceptance, closure, or release authority?

## Source and provenance

The tested source is the uncommitted `dev` worktree based on preservation commit
`4c39b9a`. Tests copy only `.META` scaffolding and workflow scripts into isolated
Git fixtures under `/tmp`; `.META/sources/drawio/` is not copied or traversed.
Legacy `../design/` and `../knowledge/` content is not copied or modified.

## Reproduction

Run repository-local checks and capture their result:

```bash
.META/research/SB2-20260726-001--workflow-validation--kiro-verifier--01/commands.sh \
  | tee .META/research/SB2-20260726-001--workflow-validation--kiro-verifier--01/results.txt
```

Run every mutating behavior only in disposable fixtures:

```bash
.META/research/SB2-20260726-001--workflow-validation--kiro-verifier--01/fixture-tests.sh \
  2>&1 | tee \
  .META/research/SB2-20260726-001--workflow-validation--kiro-verifier--01/fixture-results.txt
```

The scripts and captured transcripts are the exact evidence. The latest fixture
created research, maintenance, and implementation sessions with exact `.prompt`
content and common steering/review records. It rejected unsupported closure,
created and revalidated a correctly registered external worktree after later
`dev` movement, rejected an option-like path and a branch based on `main`, and
accepted fixture-only closure only after all explicit product-owner and
integration prerequisites were supplied.

Latest workflow fixture identifiers:

- fixture: `/tmp/slideblaster2-workflow-final.4yGH4t`;
- immutable registration: `95110bab6e1582038ee349436983247cec1516a6`;
- explicit closure integration: `616c1eef81a124b17919054bc8556b6761fbd00e`.

Before accepting that fixture-only closure, the suite separately rejected a
missing closure response, a malformed review unit, pending material steering,
and an attempt to mask one missing steering disposition with a duplicate
allowed disposition in another entry.

The release fixture `/tmp/slideblaster2-release-final.b5KLwE` proved preview was
non-mutating, exact confirmation performed only a local fast-forward, no push
command exists, and a later same-version advance was rejected.

## Environment

Linux, Git, Bash, GNU core utilities, Python 3, and existing Cabal metadata. No
package, network dependency, product build, or product code mutation is used.

## Observations

- All session types preserve the supplied initiating prompt exactly.
- Implementation specifications require one artifact and product-owner
  demonstration contract; slices do not duplicate it.
- A `closed` status with pending evidence fails validation.
- Closure validates only with exact artifact revision, demonstration request,
  observation, outcome acceptance, resolved steering, approved exact review
  unit, a full integration commit contained in `dev`, and explicit closure.
- Worktree ancestry remains anchored to the immutable record-add commit.
- Release preview and promotion remain product-owner-confirmed, local, and
  push-free.

## Limitations

This verifies repository process, not Haskell, Wasm, or browser behavior. It does
not migrate or reindex legacy design and knowledge; that is reserved for a
future dedicated session. Hosted branch protection and CI remain deferred.

## Conclusion

The revised scaffold passed repository-local checks, the adversarial isolated
fixture suite, and final independent read-only audit. It is suitable for
product-owner demonstration and exact local-diff review. This report is evidence,
not automatic product-owner acceptance, change approval, integration, or session
closure.
