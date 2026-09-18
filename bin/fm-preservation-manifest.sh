#!/usr/bin/env bash
# Generate the canonical AgentLab PR-manifest for a task's pull request
# (docs/PRESERVATION_MANIFEST.md in yagakeerthikiran/drivelog, and the
# captain's 2026-09-17 evidence-preservation directive's "Manifest
# requirements" section). This is firstmate's mechanical enforcement seam for
# that manifest: it never fabricates content, and it refuses (exit non-zero,
# naming the missing item) rather than writing a manifest with a placeholder
# or an incomplete preservation_status.
#
# Usage:
#   fm-preservation-manifest.sh <task-id> --pr <github-pull-request-url>
#     [--home <agentlab-home>]
#     [--artifact <category>=<agentlab-clone-relative-path>]...
#     [--requirement-id <id>]...
#     [--decision-id <id>]...
#     [--crew-role <text>]
#     [--no-crew --no-crew-reason "<text>"]
#
# <task-id> must have a verified `final` preservation receipt on record
# already (bin/fm-preservation-lib.sh's fm_preservation_verify; publish one
# with the AgentLab publisher and bin/fm-preservation-record.sh first), and
# that receipt's own app_head must equal the live PR head reported by `gh`;
# a receipt recorded against an earlier head refuses rather than pinning a
# manifest to evidence the current head has already moved past.
#
# The five DriveLog manifest categories are requirements, decisions,
# test_evidence, branch_recovery and final_handoff. This script auto-detects
# three of them from the task's own checkpoint history in the AgentLab clone
# (`checkpoints/<home>/<task-id>/`):
#   requirements    <- the task's initial checkpoint (its receipt's own path)
#   final_handoff   <- the task's final checkpoint (its receipt's own path)
#   branch_recovery <- the newest update checkpoint (every checkpoint kind
#                       embeds a "Branch recovery record" section, so the
#                       freshest update is the freshest branch-state evidence;
#                       refused when no update checkpoint exists yet)
# test_evidence has no structural equivalent in the checkpoint contract and
# must be supplied explicitly with --artifact test_evidence=<path>. Additional
# --artifact flags of any category may add more evidence beyond the
# auto-detected minimum; they never replace an auto-detected entry.
#
# decision_ids default to every `D-<word>` reference found in the task's
# decisions.ledger.md; requirement_ids have no equivalent ledger and must be
# supplied explicitly with --requirement-id. At least one of each is required.
#
# FirstMate identity comes from bin/fm-session-id.sh against $FM_HOME. Crew
# identity comes from state/<id>.meta's session_id/model/role fields when
# present, else falls back to bin/fm-session-id.sh against the task's
# recorded worktree (state/<id>.meta's own worktree= field is not yet written
# by bin/fm-spawn.sh as of the fm-preservation-gate sibling branch; this is
# the documented fallback for that gap, not a duplicate of that script's
# ownership). Pass --no-crew --no-crew-reason "<text>" for a task firstmate
# did the work on directly under the AGENTS.md hard-rule-1 exception.
#
# On success: commits and pushes manifests/<owner>/<repo>/pr-<n>.json (and a
# validation receipt beside it) to the AgentLab clone's default branch, then
# re-verifies reachability from origin/main, and prints:
#   MANIFEST_COMMIT=<sha>
#   MANIFEST_PATH=manifests/<owner>/<repo>/pr-<n>.json
# On any gap, nothing is written or committed; the exact missing item and
# owner is printed to stderr and the script exits non-zero.
#
# The schema this enforces is vendored from DriveLog at
# guardian/preservation-evidence-check commit 55aae1e1 in
# bin/fm-preservation-manifest-validate.mjs (see that file's header for the
# re-sync procedure); this script never talks to DriveLog's GitHub Actions or
# API, only to the AgentLab clone and, read-only, to the application PR's forge.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-preservation-lib.sh
. "$SCRIPT_DIR/fm-preservation-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

ID=${1:-}
if [ -z "$ID" ] || ! fm_task_id_path_safe "$ID"; then
  echo "error: invalid or missing task id" >&2
  exit 2
fi
shift || true

PR_URL=
AGENTLAB_HOME=
declare -a ARTIFACT_ARGS=()
declare -a REQUIREMENT_IDS=()
declare -a DECISION_IDS=()
CREW_ROLE=
NO_CREW=0
NO_CREW_REASON=

want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$want_value" in
      pr-url) PR_URL=$a ;;
      home) AGENTLAB_HOME=$a ;;
      artifact) ARTIFACT_ARGS+=("$a") ;;
      requirement-id) REQUIREMENT_IDS+=("$a") ;;
      decision-id) DECISION_IDS+=("$a") ;;
      crew-role) CREW_ROLE=$a ;;
      no-crew-reason) NO_CREW_REASON=$a ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --pr) want_value=pr-url ;;
    --pr=*) PR_URL=${a#--pr=} ;;
    --home) want_value=home ;;
    --home=*) AGENTLAB_HOME=${a#--home=} ;;
    --artifact) want_value=artifact ;;
    --artifact=*) ARTIFACT_ARGS+=("${a#--artifact=}") ;;
    --requirement-id) want_value=requirement-id ;;
    --requirement-id=*) REQUIREMENT_IDS+=("${a#--requirement-id=}") ;;
    --decision-id) want_value=decision-id ;;
    --decision-id=*) DECISION_IDS+=("${a#--decision-id=}") ;;
    --crew-role) want_value=crew-role ;;
    --crew-role=*) CREW_ROLE=${a#--crew-role=} ;;
    --no-crew) NO_CREW=1 ;;
    --no-crew-reason) want_value=no-crew-reason ;;
    --no-crew-reason=*) NO_CREW_REASON=${a#--no-crew-reason=} ;;
    *) echo "error: unknown argument: $a" >&2; exit 2 ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 2; }
[ -n "$PR_URL" ] || { echo "error: --pr <url> is required" >&2; exit 2; }
if [ "$NO_CREW" = 1 ]; then
  [ -n "$NO_CREW_REASON" ] || { echo "error: --no-crew requires --no-crew-reason \"<text>\"" >&2; exit 2; }
fi

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no task record at $META" >&2; exit 1; }

fm_pr_url_parse "$PR_URL" || { echo "error: --pr must be a GitHub pull request URL (https://github.com/<owner>/<repo>/pull/<n>)" >&2; exit 2; }
[ "$FM_PR_PROVIDER" = github ] || { echo "error: preservation manifests currently support GitHub pull requests only" >&2; exit 1; }
OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO
PRNUM=$FM_PR_NUMBER

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI is required to read the live PR head/base/body" >&2; exit 1; }
PR_JSON=$(gh pr view "$PR_URL" --json number,baseRefName,headRefOid,body 2>&1) || {
  echo "error: could not read PR $PR_URL from GitHub: $PR_JSON" >&2
  exit 1
}
HEAD_SHA=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).headRefOid || "")' "$PR_JSON")
BASE_REF=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).baseRefName || "")' "$PR_JSON")
LIVE_NUMBER=$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).number || ""))' "$PR_JSON")
fm_pr_head_valid "$HEAD_SHA" || { echo "error: PR $PR_URL has no resolvable head SHA" >&2; exit 1; }
[ -n "$BASE_REF" ] || { echo "error: PR $PR_URL has no resolvable base branch" >&2; exit 1; }
[ "$LIVE_NUMBER" = "$PRNUM" ] || { echo "error: PR $PR_URL number mismatch ($LIVE_NUMBER != $PRNUM)" >&2; exit 1; }

WORKTREE=$(fm_meta_get "$META" worktree 2>/dev/null || true)
if [ -z "$WORKTREE" ]; then
  WORKTREE=$(grep '^worktree=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
fi

# --- final receipt: mandatory, no manifest without it ----------------------
if ! fm_preservation_verify "$STATE" "$ID" final "$WORKTREE"; then
  echo "error: $FM_PRESERVATION_VERIFY_ERROR" >&2
  exit 1
fi
FINAL_RECEIPT=$FM_PRESERVATION_VERIFY_RECEIPT
FINAL_HOME=$(node -e 'const o=JSON.parse(process.argv[1]);process.stdout.write(o.home||"")' "$FINAL_RECEIPT")
FINAL_PATH=$(node -e 'const o=JSON.parse(process.argv[1]);process.stdout.write(o.path||"")' "$FINAL_RECEIPT")
FINAL_APP_HEAD=$(node -e 'const o=JSON.parse(process.argv[1]);process.stdout.write(o.app_head||"")' "$FINAL_RECEIPT")
[ -n "$FINAL_APP_HEAD" ] && [ "$FINAL_APP_HEAD" = "$HEAD_SHA" ] || {
  echo "error: final preservation checkpoint for task $ID is stale: its recorded app head '${FINAL_APP_HEAD:-<none>}' does not match the live PR head $HEAD_SHA; publish an updated final checkpoint before generating the manifest" >&2
  exit 1
}

# --- initial receipt: mandatory for the requirements category --------------
if ! fm_preservation_verify "$STATE" "$ID" initial; then
  echo "error: $FM_PRESERVATION_VERIFY_ERROR" >&2
  exit 1
fi
INITIAL_RECEIPT=$FM_PRESERVATION_VERIFY_RECEIPT
INITIAL_PATH=$(node -e 'const o=JSON.parse(process.argv[1]);process.stdout.write(o.path||"")' "$INITIAL_RECEIPT")

HOME_SLUG=${AGENTLAB_HOME:-$FINAL_HOME}
[ -n "$HOME_SLUG" ] || { echo "error: could not determine the AgentLab home slug (pass --home explicitly)" >&2; exit 1; }

AGENTLAB_ROOT=$(fm_preservation_agentlab_root "$FM_HOME")
[ -d "$AGENTLAB_ROOT/.git" ] || { echo "error: AgentLab clone missing at $AGENTLAB_ROOT" >&2; exit 1; }
git -C "$AGENTLAB_ROOT" fetch origin --quiet
git -C "$AGENTLAB_ROOT" switch main --quiet
git -C "$AGENTLAB_ROOT" pull --ff-only origin main --quiet

DIRTY_OUTSIDE=$(git -C "$AGENTLAB_ROOT" status --porcelain -- . ':!manifests' 2>/dev/null || true)
[ -z "$DIRTY_OUTSIDE" ] || { echo "error: AgentLab clone has non-manifest working-tree changes; refusing to touch it: $DIRTY_OUTSIDE" >&2; exit 1; }

# --- branch_recovery: newest update checkpoint ------------------------------
sanitize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '/ :' '---' | sed -E 's/[^a-z0-9._-]+/-/g; s/-+/-/g; s/^-|-$//g'
}
HOME_SAFE=$(sanitize "$HOME_SLUG")
TASK_SAFE=$(sanitize "$ID")
CKPT_DIR="checkpoints/$HOME_SAFE/$TASK_SAFE"

UPDATE_PATH=$(git -C "$AGENTLAB_ROOT" ls-tree -r --name-only HEAD -- "$CKPT_DIR" 2>/dev/null \
  | grep -E "^${CKPT_DIR}/[0-9]{3}--.*--update\.md$" | sort | tail -1 || true)
[ -n "$UPDATE_PATH" ] || {
  echo "error: no update checkpoint found under $CKPT_DIR for the branch_recovery category; publish at least one update checkpoint before generating the manifest" >&2
  exit 1
}

# --- decisions: the task's decision ledger ----------------------------------
LEDGER_PATH="$CKPT_DIR/decisions.ledger.md"
git -C "$AGENTLAB_ROOT" cat-file -e "HEAD:$LEDGER_PATH" 2>/dev/null || {
  echo "error: no decision ledger found at $LEDGER_PATH for the decisions category" >&2
  exit 1
}
if [ "${#DECISION_IDS[@]}" -eq 0 ]; then
  while IFS= read -r d; do
    [ -n "$d" ] && DECISION_IDS+=("$d")
  done < <(git -C "$AGENTLAB_ROOT" show "HEAD:$LEDGER_PATH" | grep -oE '\bD-[A-Za-z0-9-]+\b' | sort -u)
fi
[ "${#DECISION_IDS[@]}" -gt 0 ] || {
  echo "error: no decision_ids found in $LEDGER_PATH and none supplied with --decision-id" >&2
  exit 1
}
[ "${#REQUIREMENT_IDS[@]}" -gt 0 ] || {
  echo "error: at least one --requirement-id is required (no automatic requirement ledger exists)" >&2
  exit 1
}

# --- assemble the artifacts array ------------------------------------------
declare -A CATEGORY_SEEN=()
declare -a ARTIFACT_PATHS=()
declare -a ARTIFACT_CATEGORIES=()
declare -a ARTIFACT_BLOBS=()
SEEN_PATHS=""

add_artifact() {  # <category> <path>
  local category=$1 path=$2 blob
  case "$category" in
    requirements|decisions|test_evidence|branch_recovery|final_handoff) ;;
    *) echo "error: --artifact category must be one of requirements|decisions|test_evidence|branch_recovery|final_handoff (got $category)" >&2; exit 2 ;;
  esac
  case " $SEEN_PATHS " in
    *" $path "*) echo "error: duplicate artifact path: $path" >&2; exit 2 ;;
  esac
  SEEN_PATHS="$SEEN_PATHS $path"
  blob=$(git -C "$AGENTLAB_ROOT" rev-parse "HEAD:$path" 2>/dev/null) || {
    echo "error: artifact path not found at AgentLab HEAD: $path" >&2
    exit 1
  }
  ARTIFACT_PATHS+=("$path")
  ARTIFACT_CATEGORIES+=("$category")
  ARTIFACT_BLOBS+=("$blob")
  CATEGORY_SEEN[$category]=1
}

add_artifact requirements "$INITIAL_PATH"
add_artifact final_handoff "$FINAL_PATH"
add_artifact branch_recovery "$UPDATE_PATH"
add_artifact decisions "$LEDGER_PATH"

for entry in "${ARTIFACT_ARGS[@]}"; do
  case "$entry" in
    *=*) add_artifact "${entry%%=*}" "${entry#*=}" ;;
    *) echo "error: --artifact must be <category>=<path> (got $entry)" >&2; exit 2 ;;
  esac
done

for required in requirements decisions test_evidence branch_recovery final_handoff; do
  [ -n "${CATEGORY_SEEN[$required]:-}" ] || {
    echo "error: no artifact recorded for required category '$required'; pass --artifact $required=<agentlab-clone-relative-path>" >&2
    exit 1
  }
done

# --- crew identity -----------------------------------------------------------
CREW_PARTICIPATED=true
CREW_JSON='[]'
NO_CREW_REASON_OUT=
if [ "$NO_CREW" = 1 ]; then
  CREW_PARTICIPATED=false
  NO_CREW_REASON_OUT=$NO_CREW_REASON
else
  KIND=$(fm_meta_get "$META" kind 2>/dev/null || true)
  ROLE=${CREW_ROLE:-${KIND:-crew}}
  SESSION_ID=$(fm_meta_get "$META" session_id 2>/dev/null || true)
  RESUME_REF=$(fm_meta_get "$META" resume_url 2>/dev/null || true)
  if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = UNAVAILABLE ]; then
    if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
      # -u: this process's own CLAUDE_CODE_SESSION_ID (firstmate's session, not
      # the crew's) would otherwise shadow the worktree argument below.
      SESSION_OUT=$(env -u CLAUDE_CODE_SESSION_ID "$SCRIPT_DIR/fm-session-id.sh" "$WORKTREE" 2>/dev/null) || SESSION_OUT=""
      SESSION_ID=$(printf '%s\n' "$SESSION_OUT" | sed -n 's/^session_id=//p')
      RESUME_REF=$(printf '%s\n' "$SESSION_OUT" | sed -n 's/^resume_url=//p')
    fi
  fi
  if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = UNAVAILABLE ]; then
    echo "error: crew session_id could not be resolved for task $ID (state/$ID.meta has no session_id and bin/fm-session-id.sh could not resolve one from its recorded worktree); pass identity via state/$ID.meta or run with --no-crew --no-crew-reason once this is genuinely firstmate-only work" >&2
    exit 1
  fi
  CREW_JSON=$(node -e '
    process.stdout.write(JSON.stringify([{
      role: process.argv[1],
      task: process.argv[2],
      session_id: process.argv[3],
      resume_reference: process.argv[4],
    }]));
  ' "$ROLE" "$ID" "$SESSION_ID" "$RESUME_REF")
fi

# --- firstmate identity -------------------------------------------------------
FM_SESSION_OUT=$("$SCRIPT_DIR/fm-session-id.sh" "$FM_HOME" 2>/dev/null) || FM_SESSION_OUT=""
FM_SESSION_ID=$(printf '%s\n' "$FM_SESSION_OUT" | sed -n 's/^session_id=//p')
FM_RESUME_REF=$(printf '%s\n' "$FM_SESSION_OUT" | sed -n 's/^resume_url=//p')
[ -n "$FM_SESSION_ID" ] || {
  echo "error: supervising FirstMate session_id could not be resolved from $FM_HOME (bin/fm-session-id.sh)" >&2
  exit 1
}

# --- build the manifest object ----------------------------------------------
MANIFEST_REL="manifests/$OWNER/$REPO/pr-$PRNUM.json"
RECEIPT_REL="manifests/$OWNER/$REPO/pr-$PRNUM.receipt.json"
MANIFEST_ABS="$AGENTLAB_ROOT/$MANIFEST_REL"
GENERATED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

ARTIFACTS_JSON=$(node -e '
  const paths = JSON.parse(process.argv[1]);
  const categories = JSON.parse(process.argv[2]);
  const blobs = JSON.parse(process.argv[3]);
  const out = paths.map((p, i) => ({ path: p, category: categories[i], blob_sha: blobs[i] }));
  process.stdout.write(JSON.stringify(out));
' "$(node -e 'process.stdout.write(JSON.stringify(process.argv.slice(1)))' "${ARTIFACT_PATHS[@]}")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv.slice(1)))' "${ARTIFACT_CATEGORIES[@]}")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv.slice(1)))' "${ARTIFACT_BLOBS[@]}")")

REQUIREMENT_IDS_JSON=$(node -e 'process.stdout.write(JSON.stringify(process.argv.slice(1)))' "${REQUIREMENT_IDS[@]}")
DECISION_IDS_JSON=$(node -e 'process.stdout.write(JSON.stringify(process.argv.slice(1)))' "${DECISION_IDS[@]}")

MANIFEST_JSON=$(node -e '
  const [ownerRepo, prNumber, headSha, baseRef, fmSession, fmResume,
    crewParticipated, crewJson, noCrewReason, artifactsJson,
    requirementIdsJson, decisionIdsJson, generatedUtc] = process.argv.slice(1);
  const manifest = {
    schema_version: 1,
    application_repository: ownerRepo,
    pull_request_number: Number(prNumber),
    application_head_sha: headSha,
    application_base_ref: baseRef,
    preservation_status: "complete",
    firstmate: { session_id: fmSession, resume_reference: fmResume },
    crew_participated: crewParticipated === "true",
    crew: JSON.parse(crewJson),
    artifacts: JSON.parse(artifactsJson),
    requirement_ids: JSON.parse(requirementIdsJson),
    decision_ids: JSON.parse(decisionIdsJson),
    generated_utc: generatedUtc,
    local_only_artifacts: 0,
    unpreserved_items: [],
  };
  if (crewParticipated !== "true") manifest.no_crew_reason = noCrewReason;
  process.stdout.write(JSON.stringify(manifest, null, 2) + "\n");
' "$OWNER/$REPO" "$PRNUM" "$HEAD_SHA" "$BASE_REF" "$FM_SESSION_ID" "$FM_RESUME_REF" \
  "$CREW_PARTICIPATED" "$CREW_JSON" "$NO_CREW_REASON_OUT" "$ARTIFACTS_JSON" \
  "$REQUIREMENT_IDS_JSON" "$DECISION_IDS_JSON" "$GENERATED_UTC")

MANIFEST_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-preservation-manifest.XXXXXX")
printf '%s' "$MANIFEST_JSON" > "$MANIFEST_TMP"

# --- local schema validation (never fabricates, never bypassed) -------------
if ! VALIDATOR_OUT=$(node "$SCRIPT_DIR/fm-preservation-manifest-validate.mjs" "$MANIFEST_TMP" \
  --repository "$OWNER/$REPO" --pr "$PRNUM" --head "$HEAD_SHA" --base "$BASE_REF" 2>&1); then
  rm -f -- "$MANIFEST_TMP"
  echo "error: generated manifest failed schema validation; nothing was written:" >&2
  printf '%s\n' "$VALIDATOR_OUT" >&2
  exit 1
fi

RECEIPT_JSON=$(node -e '
  process.stdout.write(JSON.stringify({
    verdict: "pass",
    checked_utc: process.argv[1],
    application_head_sha: process.argv[2],
    manifest_path: process.argv[3],
  }, null, 2) + "\n");
' "$GENERATED_UTC" "$HEAD_SHA" "$MANIFEST_REL")

mkdir -p "$(dirname "$MANIFEST_ABS")"
cp "$MANIFEST_TMP" "$MANIFEST_ABS"
rm -f -- "$MANIFEST_TMP"
printf '%s' "$RECEIPT_JSON" > "$AGENTLAB_ROOT/$RECEIPT_REL"

git -C "$AGENTLAB_ROOT" add "$MANIFEST_REL" "$RECEIPT_REL"
STAGED_OUTSIDE=$(git -C "$AGENTLAB_ROOT" diff --cached --name-only | grep -vE '^manifests/' || true)
if [ -n "$STAGED_OUTSIDE" ]; then
  echo "error: non-manifest files staged in the AgentLab clone; refusing" >&2
  git -C "$AGENTLAB_ROOT" reset HEAD -- "$MANIFEST_REL" "$RECEIPT_REL" >/dev/null 2>&1 || true
  exit 1
fi
if git -C "$AGENTLAB_ROOT" diff --cached --quiet; then
  echo "No manifest changes to commit for PR #$PRNUM at head $HEAD_SHA."
  echo "MANIFEST_PATH=$MANIFEST_REL"
  exit 0
fi

git -C "$AGENTLAB_ROOT" commit -m "AgentLab manifest: $OWNER/$REPO PR #$PRNUM at $HEAD_SHA" --quiet
COMMIT_SHA=$(git -C "$AGENTLAB_ROOT" rev-parse HEAD)
git -C "$AGENTLAB_ROOT" push origin main --quiet

git -C "$AGENTLAB_ROOT" fetch origin --quiet
git -C "$AGENTLAB_ROOT" merge-base --is-ancestor "$COMMIT_SHA" origin/main || {
  echo "error: manifest committed but $COMMIT_SHA is not reachable from origin/main after push" >&2
  exit 1
}

echo "MANIFEST_COMMIT=$COMMIT_SHA"
echo "MANIFEST_PATH=$MANIFEST_REL"
