#!/usr/bin/env bash
# Publish a mechanical AgentLab "update" checkpoint for every in-flight ship/
# scout task and for the firstmate home itself, then record each receipt
# (docs/evidence-preservation-lifecycle.md in yagakeerthikiran/agentlab-shared-memory
# is the canonical contract; bin/fm-preservation-lib.sh owns the receipt log
# fm_preservation_verify checks). The `/stow` skill's "Open-record persistence"
# step invokes this before it may declare a session reset-safe: a pause is one
# of the lifecycle events the contract requires an update checkpoint for, and
# a session reset destroys anything that exists only in conversation.
#
# This is a MECHANICAL pause marker, not a substitute for the substantive
# checkpoints a crew member's own conversation must still publish when a real
# decision, requirement, or scope change happens (the brief's own
# "# Evidence preservation" section owns that duty). It fills only what git
# and the receipt log can supply without interpretation - branch/head state,
# session identity - and is explicit in the checkpoint body that it claims no
# session-specific decision or requirement content.
#
# Usage: fm-stow-preservation.sh [--task <task-id>]...
#   With no --task, targets every state/*.meta with kind=ship or kind=scout,
#   plus the firstmate home itself (home=firstmate-home, task-id=main, a fixed
#   conventional id since the primary home is not itself a backlog task).
#   One or more --task narrows the task set to just those ids; the firstmate
#   home's own checkpoint is always included.
#
# Fails closed (refuses, naming every failure, exit non-zero) rather than
# silently skipping: a missing AgentLab clone, a missing
# scripts/checkpoint-template.sh or scripts/publish-firstmate-checkpoint.sh at
# that clone (the sibling task's contract, not yet landed there, is refused
# the same way bin/fm-preservation-lib.sh's fm_preservation_verify refuses a
# missing scripts/validate-checkpoint.mjs), or a publish failure for any one
# target fails the whole run - never a partial "reset-safe" claim.
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

# shellcheck source=bin/fm-preservation-lib.sh
. "$SCRIPT_DIR/fm-preservation-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"

declare -a ONLY_TASKS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task)
      [ -n "${2:-}" ] || { echo "error: --task requires a value" >&2; exit 2; }
      ONLY_TASKS+=("$2")
      shift 2
      ;;
    --task=*) ONLY_TASKS+=("${1#--task=}"); shift ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

AGENTLAB_ROOT=$(fm_preservation_agentlab_root "$FM_HOME")
[ -d "$AGENTLAB_ROOT/.git" ] || {
  echo "REFUSED: preservation stow pass requires the AgentLab clone at $AGENTLAB_ROOT, which is absent" >&2
  exit 1
}
TEMPLATE_SCRIPT="$AGENTLAB_ROOT/scripts/checkpoint-template.sh"
PUBLISH_SCRIPT="$AGENTLAB_ROOT/scripts/publish-firstmate-checkpoint.sh"
[ -f "$TEMPLATE_SCRIPT" ] || {
  echo "REFUSED: preservation stow pass requires $TEMPLATE_SCRIPT, which is absent; refusing rather than skipping the checkpoint" >&2
  exit 1
}
[ -f "$PUBLISH_SCRIPT" ] || {
  echo "REFUSED: preservation stow pass requires $PUBLISH_SCRIPT, which is absent; refusing rather than skipping the checkpoint" >&2
  exit 1
}

# fill_checkpoint <template-file> <out-file> <header-json> <branch-json>
# Fills the blank `Field:` header lines and `- Field: ` branch-recovery lines
# from the two JSON objects (field name -> value), and every numbered
# section's TODO body plus the Decision ledger references and State line
# TODOs with fixed, honest text: this pass claims no session-specific content.
fill_checkpoint() {
  local template=$1 out=$2 header_json=$3 branch_json=$4
  # shellcheck disable=SC2016 # single quotes are deliberate: this is a literal node program, not shell interpolation.
  node -e '
    const fs = require("node:fs");
    const [templatePath, outPath, headerJson, branchJson] = process.argv.slice(1);
    const header = JSON.parse(headerJson);
    const branch = JSON.parse(branchJson);
    let text = fs.readFileSync(templatePath, "utf8");
    for (const [k, v] of Object.entries(header)) {
      const re = new RegExp("^" + k.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + ":\\s*$", "m");
      text = text.replace(re, `${k}: ${v}`);
    }
    for (const [k, v] of Object.entries(branch)) {
      const re = new RegExp("^- " + k.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + ":\\s*$", "m");
      text = text.replace(re, `- ${k}: ${v}`);
    }
    const NOTE = "No session-specific decision or requirement change is recorded by this mechanical pause checkpoint; it exists only to keep this branch and session-identity state current. See this task'"'"'s own conversation-authored checkpoints for substantive updates.";
    text = text.replace(/^## \d+\. .+\n\nTODO\n/gm, (m) => m.replace(/^TODO$/m, NOTE));
    text = text.replace(/^## Decision ledger references\n\n<!--[\s\S]*?-->\n\nTODO\n/m,
      (m) => m.replace(/^TODO$/m, "None referenced by this mechanical pause checkpoint."));
    text = text.replace(/^## State line\n\n<!--[\s\S]*?-->\n\nTODO\n/m,
      (m) => m.replace(/^TODO$/m, "in progress - mechanical pause checkpoint published by fm-stow-preservation.sh"));
    fs.writeFileSync(outPath, text);
  ' "$template" "$out" "$header_json" "$branch_json"
}

# publish_one <home> <task-id> <worktree-or-empty> <record-receipt:0|1>
publish_one() {
  local home=$1 task=$2 worktree=$3 record_receipt=$4
  local session_out session_id resume_url
  local repo base_branch working_branch base_sha head_sha merge_base dirty changed untracked
  local tmp_out rc receipt_line

  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    session_out=$(env -u CLAUDE_CODE_SESSION_ID "$SCRIPT_DIR/fm-session-id.sh" "$worktree" 2>/dev/null) || session_out=""
  else
    session_out=$("$SCRIPT_DIR/fm-session-id.sh" "$FM_HOME" 2>/dev/null) || session_out=""
  fi
  session_id=$(printf '%s\n' "$session_out" | sed -n 's/^session_id=//p')
  resume_url=$(printf '%s\n' "$session_out" | sed -n 's/^resume_url=//p')
  [ -n "$session_id" ] || session_id="UNAVAILABLE could not be resolved by fm-session-id.sh"
  [ -n "$resume_url" ] || resume_url="UNAVAILABLE could not be resolved by fm-session-id.sh"

  repo="UNAVAILABLE no worktree recorded"
  base_branch="UNAVAILABLE no worktree recorded"
  working_branch="UNAVAILABLE no worktree recorded"
  base_sha="UNAVAILABLE no worktree recorded"
  head_sha="UNAVAILABLE no worktree recorded"
  merge_base="UNAVAILABLE no worktree recorded"
  dirty="UNAVAILABLE no worktree recorded"
  changed="UNAVAILABLE no worktree recorded"
  untracked="UNAVAILABLE no worktree recorded"
  if [ -n "$worktree" ] && [ -d "$worktree" ] && git -C "$worktree" rev-parse HEAD >/dev/null 2>&1; then
    repo=$(git -C "$worktree" remote get-url origin 2>/dev/null || echo "UNAVAILABLE no origin remote")
    base_branch=$(fm_default_branch "$worktree" 2>/dev/null || echo "UNAVAILABLE could not be determined")
    working_branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || echo UNAVAILABLE)
    head_sha=$(git -C "$worktree" rev-parse HEAD 2>/dev/null || echo UNAVAILABLE)
    if [ "$base_branch" != "${base_branch#UNAVAILABLE}" ]; then
      base_sha="UNAVAILABLE base branch could not be determined"
      merge_base="UNAVAILABLE base branch could not be determined"
    else
      base_sha=$(git -C "$worktree" rev-parse "origin/$base_branch" 2>/dev/null || git -C "$worktree" rev-parse "$base_branch" 2>/dev/null || echo UNAVAILABLE)
      merge_base=$(git -C "$worktree" merge-base "$base_sha" HEAD 2>/dev/null || echo UNAVAILABLE)
    fi
    if git -C "$worktree" diff --quiet 2>/dev/null && git -C "$worktree" diff --cached --quiet 2>/dev/null; then
      dirty=clean
    else
      dirty=dirty
    fi
    changed=$(git -C "$worktree" status --porcelain 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    [ -n "$changed" ] || changed="(none)"
    untracked=$(git -C "$worktree" status --porcelain 2>/dev/null | awk '$1=="??"{print $2}' | tr '\n' ' ')
    [ -n "$untracked" ] || untracked="(none)"
  fi

  # checkpoint-lib.mjs's headerFieldsForKind() gives an update/initial/final
  # checkpoint the FirstMate-labeled header block regardless of who publishes
  # it (only kind=crew-report gets the Crew-labeled block); this fills that
  # block with whichever identity fm-session-id.sh resolved above for THIS
  # target (a crew task's own session for a per-task pause, or the primary
  # firstmate session for the home's own pause).
  local header_json branch_json checkpoint_ts
  checkpoint_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  header_json=$(node -e '
    process.stdout.write(JSON.stringify({
      "FirstMate model": "UNAVAILABLE not recorded by this mechanical pass",
      "FirstMate Claude session ID": process.argv[1],
      "FirstMate resume URL": process.argv[2],
      "Initial session start": "UNAVAILABLE not tracked by this mechanical pass",
      "Checkpoint timestamp": process.argv[3],
      "Application repository": process.argv[4],
      "AgentLab report commit": "UNAVAILABLE not known until after this checkpoint is committed",
      "Current application branch": process.argv[5],
      "Current application head SHA": process.argv[6],
      "Associated PRs": "UNAVAILABLE not tracked by this mechanical pass",
    }));
  ' "$session_id" "$resume_url" "$checkpoint_ts" "$repo" "$working_branch" "$head_sha")
  branch_json=$(node -e '
    process.stdout.write(JSON.stringify({
      "Repository": process.argv[1],
      "Base branch": process.argv[2],
      "Working branch": process.argv[3],
      "Base SHA": process.argv[4],
      "Current head SHA": process.argv[5],
      "Merge base": process.argv[6],
      "Associated PR number and URL": "UNAVAILABLE not tracked by this mechanical pass",
      "Clean/dirty status": process.argv[7],
      "Changed-file inventory": process.argv[8],
      "Untracked-file inventory": process.argv[9],
      "Worktree path (historical context, non-durable)": process.argv[10] || "UNAVAILABLE no worktree recorded",
      "Commit list introduced by the branch": "UNAVAILABLE not tracked by this mechanical pass",
      "Files created, changed, deleted or intentionally left local": "UNAVAILABLE not tracked by this mechanical pass",
      "Current CI/check status": "UNAVAILABLE not tracked by this mechanical pass",
      "Deployment state": "UNAVAILABLE not tracked by this mechanical pass",
      "Database/migration state": "UNAVAILABLE not tracked by this mechanical pass",
      "Known divergence or rebase requirements": "UNAVAILABLE not tracked by this mechanical pass",
      "Exact safe continuation command or procedure": "UNAVAILABLE not tracked by this mechanical pass",
      "Artifacts belonging to this branch": "UNAVAILABLE not tracked by this mechanical pass",
      "Local-only artifacts already copied into AgentLab": "UNAVAILABLE not tracked by this mechanical pass",
    }));
  ' "$repo" "$base_branch" "$working_branch" "$base_sha" "$head_sha" "$merge_base" "$dirty" "$changed" "$untracked" "$worktree")

  local ckpt_tmp
  ckpt_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-stow-preservation.XXXXXX.md")
  "$TEMPLATE_SCRIPT" update > "$ckpt_tmp.raw"
  fill_checkpoint "$ckpt_tmp.raw" "$ckpt_tmp" "$header_json" "$branch_json"
  rm -f -- "$ckpt_tmp.raw"

  tmp_out=$(mktemp "${TMPDIR:-/tmp}/fm-stow-preservation-out.XXXXXX")
  rc=0
  ( cd "$AGENTLAB_ROOT" && "$PUBLISH_SCRIPT" --home "$home" --task "$task" --kind update --source "$ckpt_tmp" ) \
    > "$tmp_out" 2>&1 || rc=$?
  rm -f -- "$ckpt_tmp"
  if [ "$rc" -ne 0 ]; then
    echo "REFUSED: preservation stow checkpoint publish failed for $home/$task:" >&2
    cat "$tmp_out" >&2
    rm -f -- "$tmp_out"
    return 1
  fi
  if [ "$record_receipt" = 1 ]; then
    receipt_line=$(grep -m1 '^CHECKPOINT_RECEIPT=' "$tmp_out" || true)
    if [ -z "$receipt_line" ]; then
      echo "REFUSED: preservation stow checkpoint publish for $home/$task printed no CHECKPOINT_RECEIPT" >&2
      cat "$tmp_out" >&2
      rm -f -- "$tmp_out"
      return 1
    fi
    if ! printf '%s\n' "$receipt_line" | "$SCRIPT_DIR/fm-preservation-record.sh" "$task" --home "$home" >/dev/null; then
      echo "REFUSED: preservation stow checkpoint published for $home/$task but its receipt could not be recorded" >&2
      rm -f -- "$tmp_out"
      return 1
    fi
  fi
  rm -f -- "$tmp_out"
  echo "published: update checkpoint for $home/$task"
  return 0
}

FAILED=0
COUNT=0

if [ "${#ONLY_TASKS[@]}" -gt 0 ]; then
  for task in "${ONLY_TASKS[@]}"; do
    meta="$STATE/$task.meta"
    [ -f "$meta" ] || { echo "REFUSED: no task record at $meta" >&2; FAILED=1; continue; }
    home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$home" ] || home="firstmate-home"
    worktree=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    COUNT=$((COUNT + 1))
    publish_one "$home" "$task" "$worktree" 1 || FAILED=1
  done
else
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    task=$(basename "$meta" .meta)
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    case "$kind" in
      ship|scout) ;;
      *) continue ;;
    esac
    home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$home" ] || home="firstmate-home"
    worktree=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    COUNT=$((COUNT + 1))
    publish_one "$home" "$task" "$worktree" 1 || FAILED=1
  done
fi

COUNT=$((COUNT + 1))
publish_one firstmate-home main "$FM_ROOT" 0 || FAILED=1

[ "$FAILED" -eq 0 ] || {
  echo "REFUSED: preservation stow pass did not publish a checkpoint for every target; not safe to declare this session reset-safe" >&2
  exit 1
}
echo "preservation stow pass published $COUNT checkpoint(s)"
