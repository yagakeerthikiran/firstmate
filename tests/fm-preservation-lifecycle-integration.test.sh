#!/usr/bin/env bash
# Behavior tests for the captain's 2026-09-17 evidence-preservation lifecycle
# directive as wired into firstmate's mechanical lifecycle points not already
# owned by tests/fm-preservation-gate.test.sh (spawn/promote/teardown/session-id/
# brief-scaffold coverage lives there). This suite covers:
#   - bin/fm-preservation-manifest.sh: the canonical DriveLog-shaped PR manifest
#   - bin/fm-preservation-manifest-validate.mjs: the vendored schema validator
#   - the merge-readiness gate in bin/fm-pr-merge.sh
#   - the PR-body coordinate-line warning in bin/fm-pr-check.sh
#   - the preservation-staleness heartbeat wake
#   - the bootstrap PRESERVATION: diagnostic line
#   - bin/fm-stow-preservation.sh (the /stow mandatory-checkpoint helper)
#   - bin/fm-captain-packet.sh
#
# Every case builds a real, minimal AgentLab-shaped git repo with a bare
# origin remote, matching tests/fm-preservation-gate.test.sh's own convention,
# rather than mocking git.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

MANIFEST="$ROOT/bin/fm-preservation-manifest.sh"
MANIFEST_VALIDATE="$ROOT/bin/fm-preservation-manifest-validate.mjs"
TMP_ROOT=$(fm_test_tmproot fm-preservation-lifecycle-integration)

# --- fixture: a task with a full, valid preservation trail ------------------
#
# checkpoints/<home>/<task>/001--*--initial.md
# checkpoints/<home>/<task>/002--*--update.md
# checkpoints/<home>/<task>/003--*--final.md
# checkpoints/<home>/<task>/decisions.ledger.md (contains D-01)
# artifacts/<home>/<task>/test-evidence.md
#
# build_manifest_fixture <dir> <home> <task>: builds the repo at <dir>/src
# with a bare origin at <dir>/origin.git and an always-passing
# scripts/validate-checkpoint.mjs stub (this suite is not exercising that
# validator's own content rules, only the manifest generator's plumbing).
build_manifest_fixture() {
  local dir=$1 home=$2 task=$3
  local ck="checkpoints/$home/$task" ar="artifacts/$home/$task"
  mkdir -p "$dir/src/scripts" "$dir/src/$ck" "$dir/src/$ar"
  git init -q -b main "$dir/src"
  # Repo-local identity so bin/fm-preservation-manifest.sh's own `git commit`
  # (which relies on ambient identity, matching every other lifecycle script)
  # works under this suite's GIT_CONFIG_GLOBAL=/dev/null isolation.
  git -C "$dir/src" config user.email t@t
  git -C "$dir/src" config user.name t
  printf '%s\n' 'export {}' > "$dir/src/scripts/validate-checkpoint.mjs"
  printf '# initial checkpoint\n' > "$dir/src/$ck/001--fixture--initial.md"
  printf '# update checkpoint\n\nBranch recovery record present.\n' > "$dir/src/$ck/002--fixture--update.md"
  printf '# final checkpoint\n' > "$dir/src/$ck/003--fixture--final.md"
  {
    echo "# Decision ledger: $home/$task"
    echo
    echo "## D-01: use the sibling's fm-preservation-lib.sh API"
    echo "Status: accepted"
  } > "$dir/src/$ck/decisions.ledger.md"
  printf '# test evidence\n\nsuite passed: 12/12\n' > "$dir/src/$ar/test-evidence.md"
  git -C "$dir/src" add -A
  git -C "$dir/src" -c user.email=t@t -c user.name=t commit -q -m fixture
  git init -q --bare "$dir/origin.git"
  git -C "$dir/src" remote add origin "$dir/origin.git"
  git -C "$dir/src" push -q origin main
}

# write_receipt <state_dir> <id> <kind> <home> <path> <commit> [<app_head>]
write_receipt() {
  local state_dir=$1 id=$2 kind=$3 home=$4 path=$5 commit=$6 app_head=${7:-}
  mkdir -p "$state_dir"
  node -e '
    const fs = require("node:fs");
    const [p, id, kind, home, path, commit, appHead] = process.argv.slice(1);
    const now = new Date().toISOString();
    fs.appendFileSync(p, JSON.stringify({
      kind, task: id, home, commit, path,
      branch: "main", app_branch: "", app_head: appHead || "",
      timestamp: now, recorded_at: now,
    }) + "\n");
  ' "$state_dir/$id.preservation" "$id" "$kind" "$home" "$path" "$commit" "$app_head"
}

# seed_case <case_dir> <home> <task>: builds the fixture, a task meta file,
# and initial/final receipts (but not the manifest itself). Echoes the fixture
# commit SHA.
seed_case() {
  local case_dir=$1 home=$2 task=$3 sha
  build_manifest_fixture "$case_dir" "$home" "$task"
  sha=$(git -C "$case_dir/src" rev-parse HEAD)
  mkdir -p "$case_dir/state"
  fm_write_meta "$case_dir/state/$task.meta" "kind=ship" "mode=no-mistakes" "yolo=off"
  write_receipt "$case_dir/state" "$task" initial "$home" "checkpoints/$home/$task/001--fixture--initial.md" "$sha"
  write_receipt "$case_dir/state" "$task" final "$home" "checkpoints/$home/$task/003--fixture--final.md" "$sha"
  printf '%s\n' "$sha"
}

FAKE_GH_JSON='{"number":42,"baseRefName":"main","headRefOid":"111111111111111111111111111111111111abcd","body":""}'

# run_manifest <case_dir> [extra fm-preservation-manifest.sh args...]
run_manifest() {
  local case_dir=$1 task=$2
  shift 2
  local fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\$1" = pr ] && [ "\$2" = view ]; then
  printf '%s\\n' '$FAKE_GH_JSON'
  exit 0
fi
exit 2
SH
  chmod +x "$fakebin/gh"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_PRESERVATION_AGENTLAB_ROOT="$case_dir/src" \
    CLAUDE_CODE_SESSION_ID="00000000-0000-0000-0000-0000000000fm" \
    PATH="$fakebin:$PATH" \
    "$MANIFEST" "$task" --pr "https://github.com/acme/widgets/pull/42" "$@" 2>&1
}

test_manifest_refuses_without_final_receipt() {
  local dir out
  dir="$TMP_ROOT/no-final"
  build_manifest_fixture "$dir" home1 task1
  mkdir -p "$dir/state"
  fm_write_meta "$dir/state/task1.meta" "kind=ship"
  out=$(run_manifest "$dir" task1)
  case "$out" in
    *"REFUSED: preservation final"*) pass "manifest generator refuses without a final receipt" ;;
    *) fail "expected a final-receipt refusal, got: $out" ;;
  esac
}

test_manifest_refuses_without_test_evidence() {
  local dir out
  dir="$TMP_ROOT/no-test-evidence"
  seed_case "$dir" home1 task1 >/dev/null
  out=$(run_manifest "$dir" task1 --requirement-id R-1 --decision-id D-01)
  case "$out" in
    *"required category 'test_evidence'"*) pass "manifest generator refuses without a test_evidence artifact" ;;
    *) fail "expected a missing-test_evidence refusal, got: $out" ;;
  esac
}

test_manifest_refuses_without_requirement_id() {
  local dir out
  dir="$TMP_ROOT/no-requirement-id"
  seed_case "$dir" home1 task1 >/dev/null
  out=$(run_manifest "$dir" task1 --artifact "test_evidence=artifacts/home1/task1/test-evidence.md")
  case "$out" in
    *"--requirement-id is required"*) pass "manifest generator refuses without a requirement id" ;;
    *) fail "expected a missing-requirement-id refusal, got: $out" ;;
  esac
}

test_manifest_refuses_without_update_checkpoint() {
  local dir sha out
  dir="$TMP_ROOT/no-update"
  mkdir -p "$dir/src/scripts" "$dir/src/checkpoints/home1/task1" "$dir/src/artifacts/home1/task1"
  git init -q -b main "$dir/src"
  printf '%s\n' 'export {}' > "$dir/src/scripts/validate-checkpoint.mjs"
  printf '# initial\n' > "$dir/src/checkpoints/home1/task1/001--fixture--initial.md"
  printf '# final\n' > "$dir/src/checkpoints/home1/task1/002--fixture--final.md"
  {
    echo "# Decision ledger"
    echo "## D-01: something"
  } > "$dir/src/checkpoints/home1/task1/decisions.ledger.md"
  printf '# evidence\n' > "$dir/src/artifacts/home1/task1/test-evidence.md"
  git -C "$dir/src" add -A
  git -C "$dir/src" -c user.email=t@t -c user.name=t commit -q -m fixture
  git init -q --bare "$dir/origin.git"
  git -C "$dir/src" remote add origin "$dir/origin.git"
  git -C "$dir/src" push -q origin main
  sha=$(git -C "$dir/src" rev-parse HEAD)
  mkdir -p "$dir/state"
  fm_write_meta "$dir/state/task1.meta" "kind=ship"
  write_receipt "$dir/state" task1 initial home1 "checkpoints/home1/task1/001--fixture--initial.md" "$sha"
  write_receipt "$dir/state" task1 final home1 "checkpoints/home1/task1/002--fixture--final.md" "$sha"
  out=$(run_manifest "$dir" task1 --requirement-id R-1 --artifact "test_evidence=artifacts/home1/task1/test-evidence.md")
  case "$out" in
    *"no update checkpoint found"*) pass "manifest generator refuses without an update checkpoint for branch_recovery" ;;
    *) fail "expected a missing-update-checkpoint refusal, got: $out" ;;
  esac
}

# seed_case leaves state/<id>.meta without session_id or worktree, so an
# ordinary (non --no-crew) manifest run cannot resolve crew identity from
# either source; this is the refusal case exercised directly.
test_manifest_refuses_without_crew_identity() {
  local dir out
  dir="$TMP_ROOT/no-crew-identity"
  seed_case "$dir" home1 task1 >/dev/null
  out=$(run_manifest "$dir" task1 --requirement-id R-1 --decision-id D-01 \
    --artifact "test_evidence=artifacts/home1/task1/test-evidence.md")
  case "$out" in
    *"crew session_id could not be resolved"*) pass "manifest generator refuses when crew identity cannot be resolved" ;;
    *) fail "expected a crew-identity refusal, got: $out" ;;
  esac
}

# seed_case_with_crew_identity <case_dir> <home> <task>: seed_case plus a
# recorded crew session_id/resume_url in state/<id>.meta, for cases that
# exercise the success path rather than the crew-identity refusal itself.
seed_case_with_crew_identity() {
  local case_dir=$1 home=$2 task=$3
  seed_case "$case_dir" "$home" "$task" >/dev/null
  {
    echo 'session_id=00000000-0000-0000-0000-0000000000cc'
    echo 'resume_url=https://claude.ai/code/session_00000000-0000-0000-0000-0000000000cc'
  } >> "$case_dir/state/$task.meta"
}

test_manifest_no_crew_flag_records_reason() {
  local dir out
  dir="$TMP_ROOT/no-crew-flag"
  seed_case "$dir" home1 task1 >/dev/null
  out=$(run_manifest "$dir" task1 --requirement-id R-1 --decision-id D-01 \
    --artifact "test_evidence=artifacts/home1/task1/test-evidence.md" \
    --no-crew --no-crew-reason "firstmate performed this directly under hard rule 1")
  case "$out" in
    *"MANIFEST_COMMIT="*) pass "manifest generator succeeds with --no-crew and a reason" ;;
    *) fail "expected a successful --no-crew manifest, got: $out" ;;
  esac
  local manifest_json
  manifest_json=$(git -C "$dir/src" show HEAD:manifests/acme/widgets/pr-42.json)
  assert_contains "$manifest_json" '"crew_participated": false' "manifest records crew_participated: false"
  assert_contains "$manifest_json" "firstmate performed this directly" "manifest records the no-crew reason"
}

test_manifest_succeeds_end_to_end() {
  local dir out commit
  dir="$TMP_ROOT/success"
  seed_case_with_crew_identity "$dir" home1 task1
  out=$(run_manifest "$dir" task1 --requirement-id R-1 --requirement-id R-2 \
    --artifact "test_evidence=artifacts/home1/task1/test-evidence.md")
  case "$out" in
    *"MANIFEST_COMMIT="*"MANIFEST_PATH=manifests/acme/widgets/pr-42.json"*) ;;
    *) fail "expected a successful manifest generation, got: $out" ;;
  esac
  commit=$(printf '%s\n' "$out" | sed -n 's/^MANIFEST_COMMIT=//p')
  git -C "$dir/src" cat-file -e "$commit^{commit}" || fail "manifest commit $commit not found in AgentLab clone"
  git -C "$dir/src" fetch origin -q
  git -C "$dir/src" merge-base --is-ancestor "$commit" origin/main \
    || fail "manifest commit $commit is not reachable from origin/main"
  local manifest_json
  manifest_json=$(git -C "$dir/src" show "$commit:manifests/acme/widgets/pr-42.json")
  assert_contains "$manifest_json" '"preservation_status": "complete"' "manifest is marked complete"
  assert_contains "$manifest_json" '"application_head_sha": "111111111111111111111111111111111111abcd"' "manifest pins the live PR head"
  assert_contains "$manifest_json" '"pull_request_number": 42' "manifest pins the PR number"
  assert_contains "$manifest_json" '"crew_participated": true' "manifest records crew participation"
  assert_contains "$manifest_json" '"D-01"' "manifest auto-extracts the decision id from the ledger"
  assert_contains "$manifest_json" '"R-1"' "manifest records the supplied requirement id"
  git -C "$dir/src" cat-file -e "$commit:manifests/acme/widgets/pr-42.receipt.json" \
    || fail "validator receipt not committed beside the manifest"

  # And the vendored schema validator independently agrees.
  git -C "$dir/src" show "$commit:manifests/acme/widgets/pr-42.json" > "$dir/manifest-copy.json"
  node "$MANIFEST_VALIDATE" "$dir/manifest-copy.json" \
    --repository acme/widgets --pr 42 --head 111111111111111111111111111111111111abcd --base main \
    || fail "vendored validateManifest rejected a manifest the generator considered complete"
  pass "manifest generator produces a schema-valid, pushed, reachable manifest end to end"
}

test_manifest_rerun_after_new_head_updates_in_place() {
  local dir out1 out2 manifest_json
  dir="$TMP_ROOT/rerun"
  seed_case_with_crew_identity "$dir" home1 task1
  out1=$(run_manifest "$dir" task1 --requirement-id R-1 --artifact "test_evidence=artifacts/home1/task1/test-evidence.md")
  case "$out1" in *"MANIFEST_COMMIT="*) ;; *) fail "first manifest run failed: $out1" ;; esac
  FAKE_GH_JSON='{"number":42,"baseRefName":"main","headRefOid":"222222222222222222222222222222222222abcd","body":""}'
  out2=$(run_manifest "$dir" task1 --requirement-id R-1 --artifact "test_evidence=artifacts/home1/task1/test-evidence.md")
  case "$out2" in *"MANIFEST_COMMIT="*) ;; *) fail "second manifest run failed: $out2" ;; esac
  manifest_json=$(git -C "$dir/src" show HEAD:manifests/acme/widgets/pr-42.json)
  assert_contains "$manifest_json" '"application_head_sha": "222222222222222222222222222222222222abcd"' \
    "re-running the manifest generator after a new PR head updates the same manifest path in place"
  pass "manifest re-run after a PR head change updates the manifest in place"
}

# --- vendored validator: schema-only unit checks -----------------------------

test_validator_rejects_missing_category() {
  local dir manifest
  dir="$TMP_ROOT/validator-missing-category"
  mkdir -p "$dir"
  manifest="$dir/m.json"
  node -e '
    const fs = require("node:fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({
      schema_version: 1, application_repository: "acme/widgets", pull_request_number: 1,
      application_head_sha: "1".repeat(40), application_base_ref: "main",
      preservation_status: "complete",
      firstmate: { session_id: "s", resume_reference: "r" },
      crew_participated: false, crew: [], no_crew_reason: "solo",
      artifacts: [{ path: "manifests/acme/widgets/x.md", category: "decisions", blob_sha: "2".repeat(40) }],
      requirement_ids: ["R-1"], decision_ids: ["D-1"],
      generated_utc: new Date().toISOString(), local_only_artifacts: 0, unpreserved_items: [],
    }));
  ' "$manifest"
  if node "$MANIFEST_VALIDATE" "$manifest" --repository acme/widgets --pr 1 --head "$(printf '1%.0s' $(seq 1 40))" --base main >/tmp/validator-out 2>&1; then
    fail "validator accepted a manifest missing four of five required categories"
  fi
  assert_grep "missing required artifact category" /tmp/validator-out "validator names the missing category"
  pass "vendored validator rejects a manifest missing required categories"
}

test_validator_accepts_a_complete_manifest() {
  local dir manifest head
  dir="$TMP_ROOT/validator-complete"
  mkdir -p "$dir"
  manifest="$dir/m.json"
  head=$(printf 'a%.0s' $(seq 1 40))
  node -e '
    const fs = require("node:fs");
    const head = process.argv[2];
    const sha = () => "b".repeat(40);
    fs.writeFileSync(process.argv[1], JSON.stringify({
      schema_version: 1, application_repository: "acme/widgets", pull_request_number: 7,
      application_head_sha: head, application_base_ref: "main",
      preservation_status: "complete",
      firstmate: { session_id: "fm-1", resume_reference: "https://claude.ai/code/session_fm-1" },
      crew_participated: true,
      crew: [{ role: "ship crew", task: "task1", session_id: "c-1", resume_reference: "https://claude.ai/code/session_c-1" }],
      artifacts: [
        { path: "checkpoints/home/task/001--x--initial.md", category: "requirements", blob_sha: sha() },
        { path: "checkpoints/home/task/decisions.ledger.md", category: "decisions", blob_sha: sha() },
        { path: "artifacts/home/task/tests.md", category: "test_evidence", blob_sha: sha() },
        { path: "checkpoints/home/task/002--x--update.md", category: "branch_recovery", blob_sha: sha() },
        { path: "checkpoints/home/task/003--x--final.md", category: "final_handoff", blob_sha: sha() },
      ],
      requirement_ids: ["R-1"], decision_ids: ["D-1"],
      generated_utc: new Date().toISOString(), local_only_artifacts: 0, unpreserved_items: [],
    }));
  ' "$manifest" "$head"
  node "$MANIFEST_VALIDATE" "$manifest" --repository acme/widgets --pr 7 --head "$head" --base main \
    || fail "validator rejected a schema-complete manifest"
  pass "vendored validator accepts a schema-complete manifest"
}

test_manifest_refuses_without_final_receipt
test_manifest_refuses_without_test_evidence
test_manifest_refuses_without_requirement_id
test_manifest_refuses_without_update_checkpoint
test_manifest_refuses_without_crew_identity
test_manifest_no_crew_flag_records_reason
test_manifest_succeeds_end_to_end
test_manifest_rerun_after_new_head_updates_in_place
test_validator_rejects_missing_category
test_validator_accepts_a_complete_manifest
echo "# all fm-preservation-lifecycle-integration tests passed"
