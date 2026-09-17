# Vendored real AgentLab checkpoint validator

Read-only test data. Never executed outside `tests/fm-preservation-gate.test.sh`.
Vendored so that suite can exercise `fm_preservation_verify` against the real
AgentLab evidence-preservation validator (Git-backed checks, header/section
structure, manifest and decision-ledger resolution) instead of the
always-pass/FAILME stub used by the rest of that file's fixtures, per the
guardian's request on firstmate PR 3
([comment 5708894187](https://github.com/yagakeerthikiran/firstmate/pull/3#issuecomment-5708894187)):
tests using only a stub validator do not exercise the real validator's
Git-context-dependent behavior.

Source: `yagakeerthikiran/agentlab-shared-memory`, commit
`15f862b29216aa4d75b4714b157ebcf8b667f519` ("Add AgentLab evidence-preservation
lifecycle contract and enforcement") on branch `fm/al-evidence-preservation-lifecycle`
(the AgentLab-side counterpart of this same evidence-preservation programme,
not yet merged to that repository's `main` at the time of vendoring). This is
the commit that introduces both files below; neither has changed since.

| File                    | Blob SHA (`git hash-object`)              |
| ------------------------ | ------------------------------------------ |
| `validate-checkpoint.mjs` | `1494dee36f25f82871c769dc5f8ce5aa22dfe7d4` |
| `checkpoint-lib.mjs`      | `4ec412c6493eac82295d36154ae5fddab2dd5c7b` |

`validate-checkpoint.mjs` imports only `./checkpoint-lib.mjs`; no other
sibling module is required to run it.

Re-verify with (from a clone of `yagakeerthikiran/agentlab-shared-memory`):

```
git show 15f862b29216aa4d75b4714b157ebcf8b667f519:scripts/validate-checkpoint.mjs | git hash-object --stdin
git show 15f862b29216aa4d75b4714b157ebcf8b667f519:scripts/checkpoint-lib.mjs | git hash-object --stdin
```
