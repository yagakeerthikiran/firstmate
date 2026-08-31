#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
#
# A claim is honored only while its holder can still act. holder_state() is the
# ONE owner of that judgement and distinguishes every case the kernel exposes:
#   running | sleeping   holder can act        -> claim honored
#   stopped              SIGSTOP/Ctrl-Z (T/t)  -> claim honored for a grace
#                        window, then reclaimable; a suspended session cannot
#                        act, so it must not hold the fleet forever, but a
#                        momentary stop must not hand one fleet to two sessions
#   zombie               exited, unreaped (Z)  -> reclaimable at once
#   absent               no such process       -> reclaimable at once
#   not-harness          PID reused by another program -> reclaimable at once
#   unknown              state undetermined    -> FAIL SAFE, claim honored
# Existence is read from ps, not `kill -0`: kill returns EPERM (not ESRCH) for a
# process owned by another uid, which would misreport a live holder as dead.
# Every reclaim appends evidence to state/.lock-reclaimed.log before the claim
# is overwritten, so a disputed takeover is always reconstructable.
#
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
# Env:   FM_LOCK_STOPPED_GRACE  seconds a stopped holder keeps its claim (default 300)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
STOPPED_SINCE="$STATE/.lock-stopped-since"
RECLAIM_LOG="$STATE/.lock-reclaimed.log"
STOPPED_GRACE="${FM_LOCK_STOPPED_GRACE:-300}"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

looks_like_harness() {  # true if $1 is a process whose name/args match a harness
  local pid=$1 comm
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
}

# holder_state <pid>: echo exactly one of
# absent|zombie|stopped|running|sleeping|not-harness|unknown. Never fails.
holder_state() {
  local pid=$1 stat
  case "$pid" in ''|*[!0-9]*) echo unknown; return 0 ;; esac
  command -v ps >/dev/null 2>&1 || { echo unknown; return 0; }
  stat=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  # No ps record means the PID is gone. ps itself is present (checked above), so
  # this is a real absence rather than a missing tool.
  [ -n "$stat" ] || { echo absent; return 0; }
  case "$stat" in
    Z*)    echo zombie;  return 0 ;;
    T*|t*) echo stopped; return 0 ;;
  esac
  looks_like_harness "$pid" || { echo not-harness; return 0; }
  case "$stat" in
    R*)       echo running ;;
    S*|D*|I*) echo sleeping ;;
    *)        echo unknown ;;
  esac
}

# stopped_for <pid>: echo how many seconds $1 has been continuously stopped,
# tracking first observation in state/.lock-stopped-since. The marker is bound to
# the PID, so a reused PID or a holder that resumed and stopped again restarts
# the clock instead of inheriting a stale age.
stopped_for() {
  local pid=$1 now marker mpid msince
  now=$(date +%s)
  marker=$(cat "$STOPPED_SINCE" 2>/dev/null || true)
  mpid=${marker%% *}
  msince=${marker##* }
  if [ "$mpid" = "$pid" ] && [ -n "$msince" ] && [ "$msince" -eq "$msince" ] 2>/dev/null; then
    echo $(( now - msince ))
  else
    printf '%s %s\n' "$pid" "$now" > "$STOPPED_SINCE"
    echo 0
  fi
}

clear_stopped_marker() { rm -f "$STOPPED_SINCE"; }

# record_reclaim <old_pid> <state> <reason> <new_pid>: append takeover evidence
# BEFORE the claim is overwritten. Best effort - never blocks the reclaim.
record_reclaim() {
  local old=$1 state=$2 reason=$3 new=$4 cmd
  cmd=$(ps -o args= -p "$old" 2>/dev/null | tr '\t\n' '  ' | cut -c1-200)
  printf '%s\treclaimed_pid=%s\tstate=%s\treason=%s\tprior_cmd=%s\tnew_pid=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$old" "$state" "$reason" "${cmd:-<no ps record>}" "$new" \
    >> "$RECLAIM_LOG" 2>/dev/null || true
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null)
  state=$(holder_state "$old")
  case "$state" in
    running|sleeping)
      echo "lock: held by live harness pid $old (state: $state)" ;;
    unknown)
      echo "lock: held by pid $old (state undetermined - failing safe, treated as live)" ;;
    stopped)
      age=$(stopped_for "$old")
      if [ "$age" -lt "$STOPPED_GRACE" ]; then
        echo "lock: held by stopped harness pid $old (stopped ${age}s; reclaimable after ${STOPPED_GRACE}s)"
      else
        echo "lock: stale (pid $old stopped ${age}s, past the ${STOPPED_GRACE}s grace - a suspended session cannot act)"
      fi ;;
    zombie)
      echo "lock: stale (pid $old is a zombie - the harness has exited)" ;;
    absent)
      echo "lock: stale (pid $old dead or not a harness)" ;;
    not-harness)
      echo "lock: stale (pid $old is live but not a harness - the PID was reused by another program)" ;;
  esac
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null)
  if [ "$old" != "$me" ]; then
    state=$(holder_state "$old")
    case "$state" in
      running|sleeping)
        clear_stopped_marker
        echo "error: another live firstmate session holds the lock (pid $old, state: $state); operate read-only until resolved" >&2
        exit 1 ;;
      unknown)
        echo "error: another live firstmate session holds the lock (pid $old); its state could not be determined, so the claim is honored - operate read-only until resolved" >&2
        exit 1 ;;
      stopped)
        age=$(stopped_for "$old")
        if [ "$age" -lt "$STOPPED_GRACE" ]; then
          echo "error: another live firstmate session holds the lock (pid $old, stopped ${age}s); a briefly suspended session keeps its claim for ${STOPPED_GRACE}s - operate read-only until resolved" >&2
          exit 1
        fi
        record_reclaim "$old" "$state" "stopped ${age}s past ${STOPPED_GRACE}s grace" "$me"
        echo "note: reclaimed the lock from pid $old, suspended for ${age}s and unable to act (evidence: $RECLAIM_LOG)" >&2
        clear_stopped_marker ;;
      zombie|absent|not-harness)
        record_reclaim "$old" "$state" "holder $state" "$me"
        clear_stopped_marker ;;
    esac
  else
    clear_stopped_marker
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
