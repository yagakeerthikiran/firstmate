#!/usr/bin/env bash
# Preservation-checkpoint staleness scan
# (docs/evidence-preservation-lifecycle.md in yagakeerthikiran/agentlab-shared-memory
# is the canonical contract; bin/fm-preservation-lib.sh owns the receipt
# format and the authoritative, network-checking fm_preservation_verify gate
# that a spawn/promote/teardown/merge call actually enforces).
#
# This file is a separate, network-free ADVISORY scan for bin/fm-watch.sh's
# heartbeat and bin/fm-bootstrap.sh's session-start diagnostic: it flags a task
# whose newest local receipt looks older than its own current work, using only
# the receipt log and local git/mtime reads, never a fetch and never the
# validator. A task it does NOT flag is not thereby proven compliant - only
# fm_preservation_verify proves that; this is a cheap heads-up, not a gate.

_FM_PRESERVATION_STALENESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-lock-lib.sh
. "$_FM_PRESERVATION_STALENESS_LIB_DIR/fm-lock-lib.sh"

# fm_preservation_grace_seconds <config_dir>: reads config/preservation-grace-minutes
# (a plain positive integer of minutes; absent or malformed defaults to 30),
# converted to seconds.
fm_preservation_grace_seconds() {
  local config_dir=$1 raw=
  # A redirection's own "no such file" failure prints to the real terminal
  # regardless of a trailing 2>/dev/null on the same command (the failed
  # redirection is set up before that one takes effect), so existence is
  # checked first rather than relying on the redirect to fail silently.
  [ -f "$config_dir/preservation-grace-minutes" ] \
    && raw=$(tr -d '[:space:]' < "$config_dir/preservation-grace-minutes" 2>/dev/null || true)
  case "$raw" in
    ''|*[!0-9]*) raw=30 ;;
    0) raw=30 ;;
  esac
  echo $(( raw * 60 ))
}

# _fm_preservation_staleness_newest_recorded_at <state_dir> <id>: prints the
# newest receipt's recorded_at timestamp (any kind) in epoch seconds, or
# nothing when no receipt is recorded or the log is unreadable/empty.
_fm_preservation_staleness_newest_recorded_at() {
  local state_dir=$1 id=$2 path
  path="$state_dir/$id.preservation"
  [ -f "$path" ] || return 0
  node -e '
    const fs = require("node:fs");
    let lines;
    try { lines = fs.readFileSync(process.argv[1], "utf8").split("\n"); } catch { process.exit(0); }
    let newest = 0;
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      let obj;
      try { obj = JSON.parse(trimmed); } catch { continue; }
      const t = Date.parse(obj.recorded_at || "");
      if (!Number.isNaN(t) && t > newest) newest = t;
    }
    if (newest > 0) process.stdout.write(String(Math.floor(newest / 1000)));
  ' "$path" 2>/dev/null
}

# fm_preservation_stale_tasks <state_dir>: prints one task id per line for
# every ordinary ship/scout task (kind=secondmate is excluded; a secondmate is
# not a backlog work item) whose newest receipt is missing, or older than the
# configured grace relative to a reference time: the task's current branch
# head commit time via its recorded worktree (ship), or the newest
# data/<id>/*.md mtime (scout). A task with no readable reference (worktree
# gone, no worktree recorded yet, no report directory yet) is skipped rather
# than flagged, since staleness against nothing is not a meaningful signal.
# FM_HOME (with the usual FM_DATA_OVERRIDE/FM_CONFIG_OVERRIDE overrides)
# resolves data/ and config/, matching every other lifecycle script.
fm_preservation_stale_tasks() {
  local state_dir=$1
  local fm_home=${FM_HOME:-${FM_ROOT:-}}
  local data_dir="${FM_DATA_OVERRIDE:-$fm_home/data}"
  local config_dir="${FM_CONFIG_OVERRIDE:-$fm_home/config}"
  local grace meta id kind worktree reference recorded f mtime newest_mtime

  grace=$(fm_preservation_grace_seconds "$config_dir")
  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    case "$kind" in
      ship|scout) ;;
      *) continue ;;
    esac

    reference=
    if [ "$kind" = ship ]; then
      worktree=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ -n "$worktree" ] && [ -d "$worktree" ] || continue
      reference=$(git -C "$worktree" log -1 --format=%ct HEAD 2>/dev/null || true)
    else
      [ -d "$data_dir/$id" ] || continue
      newest_mtime=0
      for f in "$data_dir/$id"/*.md; do
        [ -e "$f" ] || continue
        mtime=$(fm_lock_path_mtime "$f") || continue
        case "$mtime" in ''|*[!0-9]*) continue ;; esac
        [ "$mtime" -le "$newest_mtime" ] || newest_mtime=$mtime
      done
      [ "$newest_mtime" -gt 0 ] && reference=$newest_mtime
    fi
    case "$reference" in ''|*[!0-9]*) continue ;; esac

    recorded=$(_fm_preservation_staleness_newest_recorded_at "$state_dir" "$id")
    if [ -z "$recorded" ]; then
      printf '%s\n' "$id"
      continue
    fi
    [ "$((reference - recorded))" -le "$grace" ] || printf '%s\n' "$id"
  done
}
