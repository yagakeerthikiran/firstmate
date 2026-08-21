#!/usr/bin/env bash
# Behavior tests for the spawn worktree-isolation guard.
#
# The guard must fail closed when the resolved pane directory is not a worktree
# of the project's own repository. The regression shapes are a foreign repo
# root and a repo nested inside the checkout: both are git toplevels distinct
# from the primary, so a toplevel-only guard lets them through and the spawn
# records the wrong worktree path in state/<id>.meta - the exact path
# fm-teardown hard-resets and removes. These tests pin behavior, not source
# text: exit code, hook placement on disk, the recorded meta line, and the
# primary checkout staying untouched. A later loosening of the guard that
# still looks right in the code fails here because the on-disk outcome
# reverts, for instance a foreign repo receiving the hook file again.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-isolation)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_isolation_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/checkout"
  wt="$case_dir/worktree"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' claude > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

run_isolation_spawn() {
  local home=$1 pane=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_refused_isolation() {
  local out=$1 pane=$2 home=$3 proj=$4 id=$5
  assert_contains "$out" "did not yield an isolated worktree" \
    "refusal must use the isolation guard error message"
  assert_absent "$proj/.claude/settings.local.json" \
    "refused spawn must leave the primary checkout config untouched"
  assert_absent "$pane/.claude/settings.local.json" \
    "refused spawn must not install the Stop hook at $pane"
  assert_absent "$home/state/$id.meta" \
    "refused spawn must not record meta (teardown removes whatever worktree= records)"
}

# Foreign repo root: an unrelated standalone repository, not a worktree of the
# project. The guard must refuse, and the refusal must leave no hook and no
# meta anywhere. Fails on the toplevel-only guard, which launches into the
# foreign repo and records worktree=$foreign in meta.
test_foreign_repo_root_is_refused() {
  local rec id out status foreign
  id=iso-foreign-k1
  rec=$(make_isolation_case foreign-refused "$id")
  read_case_record "$rec"
  foreign="$CASE_DIR/foreign"
  fm_git_init_commit "$foreign"

  out=$(run_isolation_spawn "$HOME_DIR" "$foreign" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "spawn into a foreign repo root must be refused"
  assert_refused_isolation "$out" "$foreign" "$HOME_DIR" "$PROJ_DIR" "$id"
  pass "foreign repo root refused, no hook and no meta written"
}

# Nested repo: an independent git repo checked out inside the primary's tree.
# Its toplevel differs from the primary (so a toplevel-only guard passes it)
# but teardown would hard-reset and remove live checkout contents. The guard
# must refuse and leave the checkout and the state directory untouched.
test_nested_repo_inside_checkout_is_refused() {
  local rec id out status nested
  id=iso-nested-k2
  rec=$(make_isolation_case nested-refused "$id")
  read_case_record "$rec"
  nested="$PROJ_DIR/inner"
  fm_git_init_commit "$nested"

  out=$(run_isolation_spawn "$HOME_DIR" "$nested" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "spawn into a repo nested inside the checkout must be refused"
  assert_refused_isolation "$out" "$nested" "$HOME_DIR" "$PROJ_DIR" "$id"
  pass "nested repo refused, no hook and no meta written"
}

# Regression lock: a subdirectory of a foreign repo was already refused by the
# pane-vs-toplevel check and must stay refused with the same message.
test_foreign_repo_subdir_stays_refused() {
  local rec id out status foreign sub
  id=iso-subdir-k4
  rec=$(make_isolation_case subdir-refused "$id")
  read_case_record "$rec"
  foreign="$CASE_DIR/foreign"
  sub="$foreign/sub"
  fm_git_init_commit "$foreign"
  mkdir -p "$sub"
  printf 'nested file\n' > "$sub/nested.txt"

  out=$(run_isolation_spawn "$HOME_DIR" "$sub" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "subdirectory of a foreign repo must stay refused"
  assert_refused_isolation "$out" "$sub" "$HOME_DIR" "$PROJ_DIR" "$id"
  pass "foreign repo subdirectory stays refused"
}

# Regression lock: a genuine linked worktree of the project must keep passing.
# This must stay green both before and after the correction: the same-check
# assertion must never refuse a real treehouse worktree, and the primary
# checkout must receive no hook.
test_linked_worktree_still_accepted() {
  local rec id out status
  id=iso-linked-k3
  rec=$(make_isolation_case linked-accepted "$id")
  read_case_record "$rec"

  out=$(run_isolation_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn into a genuine linked worktree must keep succeeding"
  assert_contains "$out" "spawned $id harness=claude" "linked-worktree spawn did not report success"
  assert_present "$WT_DIR/.claude/settings.local.json" "linked-worktree hook must be installed in the worktree"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "meta must record the linked worktree path"
  assert_absent "$PROJ_DIR/.claude/settings.local.json" "primary checkout must receive no hook"
  pass "linked worktree accepted, hook in worktree, meta correct, primary untouched"
}

test_foreign_repo_root_is_refused
test_nested_repo_inside_checkout_is_refused
test_foreign_repo_subdir_stays_refused
test_linked_worktree_still_accepted

echo "# all fm-spawn-isolation tests passed"
