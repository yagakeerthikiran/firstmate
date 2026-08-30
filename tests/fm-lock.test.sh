#!/usr/bin/env bash
# tests/fm-lock.test.sh - the session-claim state machine in bin/fm-lock.sh.
#
# The claim exists to guarantee exactly one session mutates a home. Honoring it
# too loosely lets two sessions spawn and merge against one fleet; honoring it
# too strictly wedges the home behind a holder that can no longer act. Both are
# safety failures, so every state the kernel can report is pinned here:
#
#   - running / sleeping   claim honored (holder can act)
#   - stopped (T/t)        honored inside the grace window, reclaimable after it
#                          (a Ctrl-Z'd session held one real home for 7 days)
#   - zombie (Z)           reclaimable at once (the harness has already exited)
#   - absent               reclaimable at once
#   - not-harness          reclaimable at once (PID reused by another program)
#   - undetermined         FAIL SAFE: claim honored, never stolen
#   - EPERM (other uid)    holder is LIVE, not dead - `ps`, not `kill -0`
#   - every reclaim leaves evidence before the claim is overwritten
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK_SH="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock-tests)

HOLDER_PID=999001

# make_case <name>: a home with state/ and a fakebin. Echoes "<state>|<fakebin>".
make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/fakebin"
  printf '%s|%s\n' "$dir/state" "$dir/fakebin"
}

# make_fake_ps <fakebin>: a `ps` that reports this test process (and every pid
# that is not HOLDER_PID) as a live `claude`, so harness_pid() resolves the
# caller deterministically, and reports HOLDER_PID with a caller-chosen
# stat/comm. An empty FM_TEST_HOLDER_STAT means "no ps record" (absent);
# FM_TEST_PS_BROKEN=1 makes every query fail, the undetermined case.
make_fake_ps() {
  local fakebin=$1
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
[ -n "\${FM_TEST_PS_BROKEN:-}" ] && exit 1
pid=""
prev=""
for arg in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$arg"
  prev="\$arg"
done
if [ "\$pid" = "$HOLDER_PID" ]; then
  stat=\${FM_TEST_HOLDER_STAT-Sl}
  comm=\${FM_TEST_HOLDER_COMM:-claude}
  [ -z "\$stat" ] && exit 1
  case "\$*" in
    *"stat="*) printf '%s\n' "\$stat"; exit 0 ;;
    *"comm="*) printf '/usr/local/bin/%s\n' "\$comm"; exit 0 ;;
    *"args="*) printf '%s --resume abc\n' "\$comm"; exit 0 ;;
    *"ppid="*) printf '1\n'; exit 0 ;;
  esac
  exit 1
fi
case "\$*" in
  *"stat="*) printf 'Sl\n'; exit 0 ;;
  *"comm="*) printf '/usr/local/bin/claude\n'; exit 0 ;;
  *"args="*) printf 'claude\n'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# run_lock <state> <fakebin> [args...]: fm-lock.sh against this fixture home.
run_lock() {
  local state=$1 fakebin=$2; shift 2
  PATH="$fakebin:/usr/bin:/bin" FM_STATE_OVERRIDE="$state" "$LOCK_SH" "$@" 2>&1
}

claim_held_by() {  # seed the lock file with HOLDER_PID
  printf '%s\n' "$HOLDER_PID" > "$1/.lock"
}

# --- honored states ----------------------------------------------------------

test_running_and_sleeping_holders_keep_the_claim() {
  local state fakebin out stat
  IFS='|' read -r state fakebin <<<"$(make_case honored)"
  make_fake_ps "$fakebin"
  for stat in Sl R Ss D I; do
    claim_held_by "$state"
    out=$(FM_TEST_HOLDER_STAT="$stat" run_lock "$state" "$fakebin")
    assert_contains "$out" "another live firstmate session holds the lock" \
      "stat $stat should have blocked acquisition"
    [ "$(cat "$state/.lock")" = "$HOLDER_PID" ] || fail "stat $stat: claim was overwritten"
  done
  pass "running and sleeping holders keep the claim"
}

test_undetermined_state_fails_safe() {
  local state fakebin out
  IFS='|' read -r state fakebin <<<"$(make_case undetermined)"
  make_fake_ps "$fakebin"
  claim_held_by "$state"
  # harness_pid() cannot resolve when ps is broken, so the script refuses before
  # it can ever overwrite a claim it could not evaluate. Either refusal is
  # correct; silently taking the lock is not.
  out=$(FM_TEST_PS_BROKEN=1 run_lock "$state" "$fakebin" || true)
  [ "$(cat "$state/.lock")" = "$HOLDER_PID" ] || fail "an unreadable holder state let the claim be stolen"
  assert_contains "$out" "error:" "an undetermined holder state should refuse, not proceed"
  pass "an undetermined holder state fails safe and never steals the claim"
}

test_status_reports_undetermined_state_as_live() {
  local state fakebin out
  IFS='|' read -r state fakebin <<<"$(make_case undetermined-status)"
  make_fake_ps "$fakebin"
  claim_held_by "$state"
  out=$(FM_TEST_HOLDER_STAT="?" run_lock "$state" "$fakebin" status)
  assert_contains "$out" "state undetermined" "status hid an undetermined holder state"
  assert_contains "$out" "failing safe" "status did not say the claim is honored"
  pass "status reports an undetermined holder state as honored, not stale"
}

# --- reclaimable states ------------------------------------------------------

test_zombie_holder_is_reclaimed_with_evidence() {
  local state fakebin out
  IFS='|' read -r state fakebin <<<"$(make_case zombie)"
  make_fake_ps "$fakebin"
  claim_held_by "$state"
  out=$(FM_TEST_HOLDER_STAT="Z" run_lock "$state" "$fakebin")
  assert_contains "$out" "lock acquired" "a zombie holder should not hold the claim"
  [ "$(cat "$state/.lock")" != "$HOLDER_PID" ] || fail "zombie holder kept the claim"
  assert_contains "$(cat "$state/.lock-reclaimed.log")" "state=zombie" \
    "reclaiming from a zombie left no evidence"
  pass "a zombie holder is reclaimed and the takeover is recorded"
}

test_absent_and_reused_pid_holders_are_reclaimed() {
  local state fakebin out
  IFS='|' read -r state fakebin <<<"$(make_case absent)"
  make_fake_ps "$fakebin"
  claim_held_by "$state"
  out=$(FM_TEST_HOLDER_STAT="" run_lock "$state" "$fakebin")
  assert_contains "$out" "lock acquired" "an absent holder should not hold the claim"
  assert_contains "$(cat "$state/.lock-reclaimed.log")" "state=absent" "absent reclaim left no evidence"

  IFS='|' read -r state fakebin <<<"$(make_case reused-pid)"
  make_fake_ps "$fakebin"
  claim_held_by "$state"
  out=$(FM_TEST_HOLDER_STAT="Sl" FM_TEST_HOLDER_COMM="postgres" run_lock "$state" "$fakebin")
  assert_contains "$out" "lock acquired" "a reused PID should not hold the claim"
  assert_contains "$(cat "$state/.lock-reclaimed.log")" "state=not-harness" "reuse reclaim left no evidence"
  pass "absent and PID-reused holders are reclaimed with evidence"
}

# --- the stopped state: the defect this suite exists for ---------------------

test_briefly_stopped_holder_keeps_the_claim() {
  local state fakebin out
  IFS='|' read -r state fakebin <<<"$(make_case stopped-brief)"
  make_fake_ps "$fakebin"
  claim_held_by "$state"
  out=$(FM_TEST_HOLDER_STAT="Tl" FM_LOCK_STOPPED_GRACE=300 run_lock "$state" "$fakebin")
  assert_contains "$out" "another live firstmate session holds the lock" \
    "a momentarily stopped holder must keep its claim - two live sessions on one fleet is worse"
  [ "$(cat "$state/.lock")" = "$HOLDER_PID" ] || fail "briefly stopped holder lost the claim"
  pass "a briefly stopped holder keeps its claim through the grace window"
}

test_long_stopped_holder_cannot_hold_forever() {
  local state fakebin out
  IFS='|' read -r state fakebin <<<"$(make_case stopped-wedged)"
  make_fake_ps "$fakebin"
  claim_held_by "$state"
  # Grace 0: the holder is past the window the moment it is observed stopped.
  out=$(FM_TEST_HOLDER_STAT="Tl" FM_LOCK_STOPPED_GRACE=0 run_lock "$state" "$fakebin")
  assert_contains "$out" "lock acquired" "a wedged suspended holder held the claim forever"
  assert_contains "$out" "suspended" "the reclaim did not explain itself"
  assert_contains "$(cat "$state/.lock-reclaimed.log")" "state=stopped" "stopped reclaim left no evidence"
  assert_contains "$(cat "$state/.lock-reclaimed.log")" "prior_cmd=claude" "evidence did not preserve the prior holder's identity"
  pass "a holder stopped past the grace window cannot hold the claim forever"
}

test_stopped_clock_is_bound_to_the_pid() {
  local state fakebin marker
  IFS='|' read -r state fakebin <<<"$(make_case stopped-clock)"
  make_fake_ps "$fakebin"
  claim_held_by "$state"
  # A stale marker from a DIFFERENT pid must not age out the current holder.
  printf '424242 1\n' > "$state/.lock-stopped-since"
  FM_TEST_HOLDER_STAT="Tl" FM_LOCK_STOPPED_GRACE=300 run_lock "$state" "$fakebin" >/dev/null
  [ "$(cat "$state/.lock")" = "$HOLDER_PID" ] || fail "a stale marker from another pid aged out the wrong holder"
  marker=$(cat "$state/.lock-stopped-since")
  case "$marker" in "$HOLDER_PID "*) ;; *) fail "stopped marker was not rebound to the observed holder: $marker" ;; esac
  pass "the stopped clock is bound to the holder pid, not inherited"
}

test_resumed_holder_clears_the_stopped_clock() {
  local state fakebin
  IFS='|' read -r state fakebin <<<"$(make_case stopped-resumed)"
  make_fake_ps "$fakebin"
  claim_held_by "$state"
  FM_TEST_HOLDER_STAT="Tl" FM_LOCK_STOPPED_GRACE=300 run_lock "$state" "$fakebin" >/dev/null
  [ -f "$state/.lock-stopped-since" ] || fail "stopped holder did not start the clock"
  FM_TEST_HOLDER_STAT="Sl" FM_LOCK_STOPPED_GRACE=300 run_lock "$state" "$fakebin" >/dev/null
  assert_absent "$state/.lock-stopped-since" "a resumed holder did not clear the stopped clock"
  pass "a holder that resumes clears its stopped clock"
}

test_status_distinguishes_every_state() {
  local state fakebin
  IFS='|' read -r state fakebin <<<"$(make_case status-matrix)"
  make_fake_ps "$fakebin"
  assert_contains "$(run_lock "$state" "$fakebin" status)" "lock: free" "no lock file should read as free"
  claim_held_by "$state"
  assert_contains "$(FM_TEST_HOLDER_STAT=Sl run_lock "$state" "$fakebin" status)" \
    "lock: held by live harness pid" "sleeping holder misreported"
  assert_contains "$(FM_TEST_HOLDER_STAT=Z run_lock "$state" "$fakebin" status)" \
    "zombie" "zombie holder misreported"
  assert_contains "$(FM_TEST_HOLDER_STAT='' run_lock "$state" "$fakebin" status)" \
    "lock: stale" "absent holder misreported"
  rm -f "$state/.lock-stopped-since"
  assert_contains "$(FM_TEST_HOLDER_STAT=Tl FM_LOCK_STOPPED_GRACE=300 run_lock "$state" "$fakebin" status)" \
    "stopped harness" "stopped-within-grace holder misreported"
  rm -f "$state/.lock-stopped-since"
  assert_contains "$(FM_TEST_HOLDER_STAT=Tl FM_LOCK_STOPPED_GRACE=0 run_lock "$state" "$fakebin" status)" \
    "lock: stale" "stopped-past-grace holder misreported"
  pass "status distinguishes free, live, stopped, zombie, and absent holders"
}

# --- existence oracle --------------------------------------------------------

test_other_uid_holder_is_live_not_dead() {
  local state fakebin out real_pid
  IFS='|' read -r state fakebin <<<"$(make_case eperm)"
  # No fake ps: use the REAL ps against a REAL process this test cannot signal.
  # `kill -0` on another uid's pid returns EPERM, not ESRCH - the old oracle read
  # that as "dead". PID 1 is owned by root, so it exercises exactly that path.
  # It is correctly reclaimable (init is not a harness), but it must be judged
  # LIVE-but-not-a-harness, never absent: reading a live holder as absent is the
  # bug that would let one uid steal another's claim.
  real_pid=1
  printf '%s\n' "$real_pid" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_SH" status 2>&1)
  assert_contains "$out" "is live but not a harness" \
    "a live process owned by another uid was not detected as existing (EPERM read as dead)"
  pass "a live holder owned by another uid is detected as live, not absent"
}

test_running_and_sleeping_holders_keep_the_claim
test_undetermined_state_fails_safe
test_status_reports_undetermined_state_as_live
test_zombie_holder_is_reclaimed_with_evidence
test_absent_and_reused_pid_holders_are_reclaimed
test_briefly_stopped_holder_keeps_the_claim
test_long_stopped_holder_cannot_hold_forever
test_stopped_clock_is_bound_to_the_pid
test_resumed_holder_clears_the_stopped_clock
test_status_distinguishes_every_state
test_other_uid_holder_is_live_not_dead
