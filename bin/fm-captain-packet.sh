#!/usr/bin/env bash
# Render the final captain packet for a task from durable records only
# (docs/evidence-preservation-lifecycle.md in yagakeerthikiran/agentlab-shared-memory
# is the canonical contract): a summary is never treated as a valid handoff
# by itself, so this refuses to render at all - rather than rendering a
# packet that merely claims completeness - unless a verified final
# preservation receipt is on record for the task.
#
# Usage: fm-captain-packet.sh <task-id>
#
# Prints a Markdown packet to stdout: PR URL, exact recorded head, the
# "merged" receipt's merge commit and base-head-after-merge (bin/fm-pr-merge.sh
# records this after a proven merge), the canonical AgentLab manifest's path
# and commit and preservation_status when one exists (GitHub only;
# bin/fm-preservation-manifest.sh), the final checkpoint's own AgentLab commit
# and path, and remaining blockers read from the task's own status log. Every
# field this script cannot resolve from a durable record reads exactly
# UNAVAILABLE plus the reason - never a placeholder invented here, and never a
# claim of test/review/deployment state this repository does not durably
# track. This script never talks to the network: everything it prints is
# already-recorded local state (the receipt log, the AgentLab clone's current
# HEAD, and the task's own status log).
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

ID=${1:-}
if [ -z "$ID" ] || ! fm_task_id_path_safe "$ID"; then
  echo "error: invalid or missing task id" >&2
  exit 2
fi

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no task record at $META" >&2; exit 1; }

field() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}
WORKTREE=$(field worktree)
PR_URL=$(field pr)
PR_HEAD=$(field pr_head)
[ -n "$PR_HEAD" ] || PR_HEAD="UNAVAILABLE (not recorded)"

if ! fm_preservation_verify "$STATE" "$ID" final "$WORKTREE"; then
  echo "error: cannot render a captain packet for $ID: $FM_PRESERVATION_VERIFY_ERROR" >&2
  exit 1
fi
FINAL_RECEIPT=$FM_PRESERVATION_VERIFY_RECEIPT
FINAL_COMMIT=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).commit||"")' "$FINAL_RECEIPT")
FINAL_PATH=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path||"")' "$FINAL_RECEIPT")

# Newest "merged" receipt, if bin/fm-pr-merge.sh has recorded one for this task.
RECORD_PATH=$(fm_preservation_record_path "$STATE" "$ID")
MERGED_RECEIPT=$(node -e '
  const fs = require("node:fs");
  const path = process.argv[1];
  let lines;
  try { lines = fs.readFileSync(path, "utf8").split("\n"); } catch { process.exit(0); }
  let latest = null;
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let obj;
    try { obj = JSON.parse(trimmed); } catch { continue; }
    if (obj && obj.kind === "merged") latest = obj;
  }
  if (latest) process.stdout.write(JSON.stringify(latest));
' "$RECORD_PATH" 2>/dev/null || true)
MERGE_COMMIT=UNAVAILABLE
BASE_HEAD_AFTER_MERGE=UNAVAILABLE
if [ -n "$MERGED_RECEIPT" ]; then
  MERGE_COMMIT=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).merge_commit||"UNAVAILABLE")' "$MERGED_RECEIPT")
  BASE_HEAD_AFTER_MERGE=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).base_head_after_merge||"UNAVAILABLE")' "$MERGED_RECEIPT")
fi

MANIFEST_PATH_REL="UNAVAILABLE (no GitHub PR recorded for this task)"
MANIFEST_COMMIT=UNAVAILABLE
MANIFEST_STATUS=UNAVAILABLE
MANIFEST_VALIDATOR_VERDICT=UNAVAILABLE
if [ -n "$PR_URL" ] && fm_pr_url_parse "$PR_URL" && [ "$FM_PR_PROVIDER" = github ]; then
  MANIFEST_REL="manifests/$FM_PR_OWNER/$FM_PR_REPO/pr-$FM_PR_NUMBER.json"
  RECEIPT_REL="manifests/$FM_PR_OWNER/$FM_PR_REPO/pr-$FM_PR_NUMBER.receipt.json"
  AGENTLAB_ROOT=$(fm_preservation_agentlab_root "$FM_HOME")
  if [ -d "$AGENTLAB_ROOT/.git" ]; then
    if MANIFEST_JSON=$(git -C "$AGENTLAB_ROOT" show "HEAD:$MANIFEST_REL" 2>/dev/null); then
      MANIFEST_PATH_REL=$MANIFEST_REL
      MANIFEST_COMMIT=$(git -C "$AGENTLAB_ROOT" log -1 --format=%H -- "$MANIFEST_REL" 2>/dev/null || echo UNAVAILABLE)
      MANIFEST_STATUS=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).preservation_status||"UNAVAILABLE")' "$MANIFEST_JSON")
      if RECEIPT_JSON=$(git -C "$AGENTLAB_ROOT" show "HEAD:$RECEIPT_REL" 2>/dev/null); then
        MANIFEST_VALIDATOR_VERDICT=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).verdict||"UNAVAILABLE")' "$RECEIPT_JSON")
      fi
    else
      MANIFEST_PATH_REL="UNAVAILABLE (no manifest committed at $MANIFEST_REL; run bin/fm-preservation-manifest.sh $ID --pr $PR_URL)"
    fi
  else
    MANIFEST_PATH_REL="UNAVAILABLE (AgentLab clone missing at $AGENTLAB_ROOT)"
  fi
fi

# Remaining blockers: the task's own status log, filtered to lines a captain
# would still need to act on. A status line is a wake event, not current
# state (AGENTS.md section 8), so this is read as evidence to relay, not as
# a verified live status.
STATUS_FILE="$STATE/$ID.status"
BLOCKERS=$(grep -E '^(blocked|needs-decision):' "$STATUS_FILE" 2>/dev/null || true)
[ -n "$BLOCKERS" ] || BLOCKERS="(none recorded in $STATUS_FILE)"

cat <<EOF
# Captain packet: $ID

- PR: ${PR_URL:-UNAVAILABLE (no pr= recorded in $META)}
- Recorded PR head: $PR_HEAD
- Merge commit: $MERGE_COMMIT
- Base head after merge: $BASE_HEAD_AFTER_MERGE
- AgentLab preservation manifest: $MANIFEST_PATH_REL
- Manifest commit: $MANIFEST_COMMIT
- Manifest preservation_status: $MANIFEST_STATUS
- Manifest validator receipt verdict: $MANIFEST_VALIDATOR_VERDICT
- Final AgentLab checkpoint commit: $FINAL_COMMIT
- Final AgentLab checkpoint path: $FINAL_PATH
- Remaining blockers (from $STATUS_FILE):
$BLOCKERS

Tests, independent review findings, and deployment state are not durably
tracked by firstmate outside the AgentLab checkpoints and manifest above;
read them from the final checkpoint at the path recorded above rather than
from this packet, which reports only what it can verify mechanically.
EOF
