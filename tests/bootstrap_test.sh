#!/usr/bin/env bash

set -eu
set -o pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-bootstrap-test.XXXXXX")
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT HUP INT TERM

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_equals() {
  expected=$1
  actual=$2
  message=$3
  [ "$expected" = "$actual" ] ||
    fail "$message (expected '$expected', got '$actual')"
}

assert_file_contains() {
  file=$1
  expected=$2
  grep -F -- "$expected" "$file" >/dev/null 2>&1 ||
    fail "$file does not contain: $expected"
}

run_bootstrap() {
  home=$1
  stow_cmd=$2
  receipt=$3
  shift 3
  HOME="$home" XDG_STATE_HOME=${DOTFILES_TEST_XDG_STATE_HOME:-$home/state} \
    DOTFILES_STOW_CMD="$stow_cmd" DOTFILES_TEST_RECEIPT="$receipt" \
    DOTFILES_TEST_REPO="$REPO_ROOT" \
    DOTFILES_TIMESTAMP=${DOTFILES_TEST_TIMESTAMP:-20260830T000000Z} \
    DOTFILES_TEST_FORCE_ROLLBACK_FAILURE=${DOTFILES_TEST_FORCE_ROLLBACK_FAILURE:-0} \
    bash -c '
      . "$1/bootstrap.sh"
      shift
      if [ "$DOTFILES_TEST_FORCE_ROLLBACK_FAILURE" -eq 1 ]; then
        dotfiles_rollback_migration() { return 1; }
      fi
      bootstrap_main "$@"
    ' shell "$REPO_ROOT" "$@"
}

make_stow_double() {
  destination=$1
  behavior=$2
  cat >"$destination" <<'EOF'
#!/bin/sh
set -eu
printf '%s|%s\n' "$PWD" "$*" >>"$DOTFILES_TEST_RECEIPT"

simulation=0
for argument in "$@"; do
  [ "$argument" = --simulate ] && simulation=1
done

case $DOTFILES_TEST_STOW_BEHAVIOR in
  conflict)
    [ "$simulation" -eq 1 ] && exit 1
    exit 90
    ;;
  migrate-success|deploy-failure)
    if [ "$simulation" -eq 1 ]; then
      [ -e "$HOME/.zshrc" ] || [ -L "$HOME/.zshrc" ] || exit 0
      exit 1
    fi
    ;;
  success)
    [ "$simulation" -eq 1 ] && exit 0
    ;;
  partial-nvim-deploy-failure)
    [ "$simulation" -eq 1 ] && exit 0
    ;;
  partial-managed-nvim-deploy-failure)
    [ "$simulation" -eq 1 ] && exit 0
    ;;
  fully-managed-nvim-success)
    exit 0
    ;;
  resimulation-failure)
    if [ "$simulation" -eq 1 ]; then
      simulation_count=$(grep -F -c -- '|--simulate ' "$DOTFILES_TEST_RECEIPT")
      [ "$simulation_count" -eq 1 ] && exit 0
      exit 21
    fi
    exit 90
    ;;
  *) exit 64 ;;
esac

link_managed() {
  source_path=$1
  destination_path=$2
  if [ -L "$destination_path" ] && [ "$destination_path" -ef "$source_path" ]; then
    return 0
  fi
  if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
    exit 93
  fi
  ln -s "$source_path" "$destination_path"
}

mkdir -p "$HOME/.config/nvim" "$HOME/.config/markdownlint" \
  "$HOME/.config/herdr" "$HOME/.config/git"
link_managed "$DOTFILES_TEST_REPO/zsh/.zshrc" "$HOME/.zshrc"
if [ "$DOTFILES_TEST_STOW_BEHAVIOR" = deploy-failure ]; then
  link_managed "$DOTFILES_TEST_REPO/nvim/.config/nvim/init.lua" "$HOME/.config/nvim/init.lua"
  exit 19
fi
if [ "$DOTFILES_TEST_STOW_BEHAVIOR" = partial-nvim-deploy-failure ]; then
  link_managed "$DOTFILES_TEST_REPO/nvim/.config/nvim/init.lua" "$HOME/.config/nvim/init.lua"
  exit 19
fi
if [ "$DOTFILES_TEST_STOW_BEHAVIOR" = partial-managed-nvim-deploy-failure ]; then
  link_managed "$DOTFILES_TEST_REPO/nvim/.config/nvim/.neoconf.json" \
    "$HOME/.config/nvim/.neoconf.json"
  exit 19
fi
link_managed "$DOTFILES_TEST_REPO/zsh/.zprofile" "$HOME/.zprofile"
source_root="$DOTFILES_TEST_REPO/nvim/.config/nvim"
find "$source_root" \( -type f -o -type l \) -print | while IFS= read -r source_file; do
  relative_path=${source_file#"$source_root"/}
  mkdir -p "$(dirname -- "$HOME/.config/nvim/$relative_path")"
  link_managed "$source_file" "$HOME/.config/nvim/$relative_path"
done
link_managed "$DOTFILES_TEST_REPO/nvim/.config/markdownlint/.markdownlint.yaml" \
  "$HOME/.config/markdownlint/.markdownlint.yaml"
link_managed "$DOTFILES_TEST_REPO/herdr/.config/herdr/config.toml" \
  "$HOME/.config/herdr/config.toml"
link_managed "$DOTFILES_TEST_REPO/git/.config/git/config" \
  "$HOME/.config/git/config"
EOF
  chmod +x "$destination"
  DOTFILES_TEST_STOW_BEHAVIOR=$behavior
  export DOTFILES_TEST_STOW_BEHAVIOR
}

seed_managed_conflicts() {
  home=$1
  mkdir -p "$home/.config/nvim" "$home/.config/markdownlint" \
    "$home/.config/herdr/nested" "$home/.config/git"
  printf 'old zshrc\n' >"$home/.zshrc"
  printf 'old zprofile\n' >"$home/.zprofile"
  printf 'old init\n' >"$home/.config/nvim/init.lua"
  printf 'old markdownlint\n' >"$home/.config/markdownlint/.markdownlint.yaml"
  printf 'old herdr config\n' >"$home/.config/herdr/config.toml"
  printf 'old git config\n' >"$home/.config/git/config"
  printf 'keep history\n' >"$home/.config/herdr/history.db"
  printf 'keep cache\n' >"$home/.config/herdr/nested/cache"
  printf 'keep unrelated\n' >"$home/notes.txt"
}

assert_originals_restored() {
  home=$1
  assert_equals 'old zshrc' "$(cat "$home/.zshrc")" '.zshrc was not restored'
  assert_equals 'old zprofile' "$(cat "$home/.zprofile")" '.zprofile was not restored'
  assert_equals 'old init' "$(cat "$home/.config/nvim/init.lua")" 'Neovim was not restored'
  assert_equals 'old markdownlint' \
    "$(cat "$home/.config/markdownlint/.markdownlint.yaml")" \
    'Markdownlint was not restored'
  assert_equals 'old herdr config' "$(cat "$home/.config/herdr/config.toml")" \
    'Herdr config was not restored'
  assert_equals 'old git config' "$(cat "$home/.config/git/config")" \
    'Git config was not restored'
  assert_equals 'keep history' "$(cat "$home/.config/herdr/history.db")" \
    'Herdr history was not preserved'
  assert_equals 'keep cache' "$(cat "$home/.config/herdr/nested/cache")" \
    'Herdr cache was not preserved'
  assert_equals 'keep unrelated' "$(cat "$home/notes.txt")" \
    'an unrelated path was changed'
}

test_invalid_arguments_exit_two() {
  home="$TEST_TMP_ROOT/arguments-home"
  mkdir -p "$home"

  set +e
  HOME="$home" bash "$REPO_ROOT/bootstrap.sh" --unknown >/dev/null 2>&1
  invalid_status=$?
  set -e
  assert_equals 2 "$invalid_status" 'invalid argument did not exit 2'
}

test_bootstrap_deploys_without_platform_provisioning() {
  home="$TEST_TMP_ROOT/deployment-only-home"
  bin="$TEST_TMP_ROOT/deployment-only-bin"
  stow="$TEST_TMP_ROOT/deployment-only-stow"
  receipt="$TEST_TMP_ROOT/deployment-only-receipt"
  mkdir -p "$home" "$bin"
  cat >"$bin/uname" <<'EOF'
#!/bin/sh
printf 'Plan9\n'
EOF
  chmod +x "$bin/uname"
  make_stow_double "$stow" success

  HOME="$home" DOTFILES_STOW_CMD="$stow" DOTFILES_UNAME_CMD="$bin/uname" \
    DOTFILES_TEST_RECEIPT="$receipt" DOTFILES_TEST_REPO="$REPO_ROOT" \
    bash "$REPO_ROOT/bootstrap.sh"

  [ -L "$home/.zshrc" ] || fail 'deployment-only bootstrap did not link .zshrc'
}

test_check_reports_dotfile_conflicts_without_running_stow() {
  home="$TEST_TMP_ROOT/check-home"
  stow="$TEST_TMP_ROOT/check-stow"
  receipt="$TEST_TMP_ROOT/check-receipt"
  mkdir -p "$home"
  printf 'unmanaged\n' >"$home/.zshrc"
  make_stow_double "$stow" conflict

  set +e
  check_output=$(run_bootstrap "$home" "$stow" "$receipt" --check 2>&1)
  check_status=$?
  set -e

  assert_equals 1 "$check_status" '--check accepted an unmanaged target'
  case $check_output in
    *"$home/.zshrc"*) : ;;
    *) fail '--check did not report the unmanaged target' ;;
  esac
  assert_equals unmanaged "$(cat "$home/.zshrc")" '--check mutated the conflict'
  [ ! -e "$receipt" ] || fail '--check invoked Stow'
}

test_check_reports_parent_conflicts_without_running_stow() {
  home="$TEST_TMP_ROOT/check-parent-home"
  stow="$TEST_TMP_ROOT/check-parent-stow"
  receipt="$TEST_TMP_ROOT/check-parent-receipt"
  mkdir -p "$home"
  printf 'blocks managed children\n' >"$home/.config"
  make_stow_double "$stow" success

  set +e
  check_output=$(run_bootstrap "$home" "$stow" "$receipt" --check 2>&1)
  check_status=$?
  set -e

  assert_equals 1 "$check_status" '--check accepted a blocking parent path'
  case $check_output in
    *"$home/.config"*) : ;;
    *) fail '--check did not report the blocking parent path' ;;
  esac
  assert_equals 'blocks managed children' "$(cat "$home/.config")" \
    '--check mutated the blocking parent path'
  [ ! -e "$receipt" ] || fail '--check invoked Stow for a parent conflict'
}

test_default_preflight_refuses_unmanaged_target() {
  home="$TEST_TMP_ROOT/conflict-home"
  stow="$TEST_TMP_ROOT/conflict-stow"
  receipt="$TEST_TMP_ROOT/conflict-receipt"
  mkdir -p "$home"
  printf 'unmanaged\n' >"$home/.zshrc"
  ln -s "$REPO_ROOT/zsh/.zprofile" "$home/.zprofile"
  make_stow_double "$stow" conflict

  set +e
  conflict_output=$(run_bootstrap "$home" "$stow" "$receipt" 2>&1)
  conflict_status=$?
  set -e

  assert_equals 1 "$conflict_status" 'default conflict did not exit 1'
  assert_equals unmanaged "$(cat "$home/.zshrc")" 'default conflict mutated .zshrc'
  case $conflict_output in
    *"$home/.zshrc"*) : ;;
    *) fail 'default conflict did not print the exact path' ;;
  esac
  case $conflict_output in
    *"$home/.zprofile"*) fail 'default conflict mislabeled a managed link' ;;
    *) : ;;
  esac
  case $conflict_output in
    *'--migrate'*) : ;;
    *) fail 'default conflict did not explain --migrate' ;;
  esac
  [ ! -e "$receipt" ] ||
    fail 'default conflict invoked Stow before refusal'
}

test_default_preflight_refuses_merge_compatible_unmanaged_nvim_before_stow() {
  home="$TEST_TMP_ROOT/preflight-nvim-home"
  stow="$TEST_TMP_ROOT/preflight-nvim-stow"
  receipt="$TEST_TMP_ROOT/preflight-nvim-receipt"
  mkdir -p "$home/.config/nvim/lua"
  printf 'keep user config\n' >"$home/.config/nvim/lua/user.lua"
  make_stow_double "$stow" success

  set +e
  preflight_output=$(run_bootstrap "$home" "$stow" "$receipt" 2>&1)
  preflight_status=$?
  set -e

  assert_equals 1 "$preflight_status" \
    'default preflight accepted a merge-compatible unmanaged Neovim directory'
  assert_equals 'keep user config' "$(cat "$home/.config/nvim/lua/user.lua")" \
    'default preflight changed the unmanaged Neovim file'
  case $preflight_output in
    *"$home/.config/nvim"*'--migrate'*) : ;;
    *) fail 'default preflight omitted the exact Neovim path or migration guidance' ;;
  esac
  [ ! -e "$receipt" ] ||
    fail 'default preflight invoked Stow before refusing the target'
  if [ -e "$home/.zshrc" ] || [ -L "$home/.zshrc" ]; then
    fail 'default preflight deployed configuration'
  fi
}

test_migration_backs_up_only_managed_targets_and_deploys() {
  home="$TEST_TMP_ROOT/migrate-home"
  stow="$TEST_TMP_ROOT/migrate-stow"
  receipt="$TEST_TMP_ROOT/migrate-receipt"
  backup="$home/state/dotfiles-backups/20260830T000000Z"
  mkdir -p "$home"
  seed_managed_conflicts "$home"
  make_stow_double "$stow" migrate-success

  run_bootstrap "$home" "$stow" "$receipt" --migrate

  assert_equals 'old zshrc' "$(cat "$backup/.zshrc")" 'backup omitted .zshrc'
  assert_equals 'old zprofile' "$(cat "$backup/.zprofile")" 'backup omitted .zprofile'
  assert_equals 'old init' "$(cat "$backup/.config/nvim/init.lua")" \
    'backup omitted Neovim'
  assert_equals 'old markdownlint' \
    "$(cat "$backup/.config/markdownlint/.markdownlint.yaml")" \
    'backup omitted Markdownlint'
  assert_equals 'old herdr config' "$(cat "$backup/.config/herdr/config.toml")" \
    'backup omitted Herdr config'
  assert_equals 'old git config' "$(cat "$backup/.config/git/config")" \
    'backup omitted Git config'
  [ ! -e "$backup/.config/herdr/history.db" ] || fail 'backup moved Herdr history'
  [ ! -e "$backup/.config/herdr/nested" ] || fail 'backup moved Herdr cache'
  assert_equals 'keep history' "$(cat "$home/.config/herdr/history.db")" \
    'migration changed Herdr history'
  assert_equals 'keep cache' "$(cat "$home/.config/herdr/nested/cache")" \
    'migration changed Herdr cache'
  assert_equals 'keep unrelated' "$(cat "$home/notes.txt")" \
    'migration changed an unrelated path'
  [ -L "$home/.zshrc" ] || fail 'migration did not deploy .zshrc'
  [ -L "$home/.config/nvim/init.lua" ] || fail 'migration did not deploy Neovim'
  [ -L "$home/.config/git/config" ] || fail 'migration did not deploy Git config'
  assert_file_contains "$receipt" \
    "$REPO_ROOT|--no-folding --target=$home zsh nvim herdr git"
  simulation_count=$(grep -F -c -- '|--simulate --no-folding' "$receipt")
  assert_equals 2 "$simulation_count" 'migration did not simulate before and after backup'
}

test_merge_compatible_migration_always_reports_created_backup() {
  home="$TEST_TMP_ROOT/merge-migrate-home"
  stow="$TEST_TMP_ROOT/merge-migrate-stow"
  receipt="$TEST_TMP_ROOT/merge-migrate-receipt"
  backup="$home/state/dotfiles-backups/20260830T000000Z"
  mkdir -p "$home/.config/nvim/lua"
  printf 'keep merge-compatible config\n' >"$home/.config/nvim/lua/user.lua"
  make_stow_double "$stow" success

  migration_output=$(run_bootstrap "$home" "$stow" "$receipt" --migrate)

  assert_equals "dotfiles: backup created at $backup" "$migration_output" \
    'merge-compatible migration did not report its created backup'
  assert_equals 'keep merge-compatible config' \
    "$(cat "$backup/.config/nvim/lua/user.lua")" \
    'merge-compatible migration did not back up the unmanaged Neovim directory'
  [ -L "$home/.config/nvim/init.lua" ] ||
    fail 'merge-compatible migration did not deploy Neovim'
}

test_incomplete_rollback_reports_exact_backup_path() {
  home="$TEST_TMP_ROOT/incomplete-rollback-home"
  stow="$TEST_TMP_ROOT/incomplete-rollback-stow"
  receipt="$TEST_TMP_ROOT/incomplete-rollback-receipt"
  backup="$home/state/dotfiles-backups/20260830T000000Z"
  mkdir -p "$home"
  printf 'old zshrc\n' >"$home/.zshrc"
  make_stow_double "$stow" resimulation-failure

  DOTFILES_TEST_FORCE_ROLLBACK_FAILURE=1
  export DOTFILES_TEST_FORCE_ROLLBACK_FAILURE
  set +e
  rollback_output=$(run_bootstrap "$home" "$stow" "$receipt" --migrate 2>&1)
  rollback_status=$?
  set -e
  unset DOTFILES_TEST_FORCE_ROLLBACK_FAILURE

  assert_equals 1 "$rollback_status" 'incomplete rollback did not exit 1'
  case $rollback_output in
    *"rollback was incomplete; restore $backup manually"*) : ;;
    *) fail 'incomplete rollback diagnostic omitted the exact backup path' ;;
  esac
}

test_backup_stage_restore_failure_reports_exact_backup_path() {
  home="$TEST_TMP_ROOT/backup-stage-rollback-home"
  backup="$home/state/dotfiles-backups/20260830T000000Z"
  mkdir -p "$home"
  printf 'old zshrc\n' >"$home/.zshrc"
  printf 'old zprofile\n' >"$home/.zprofile"

  set +e
  backup_output=$(HOME="$home" XDG_STATE_HOME="$home/state" \
    DOTFILES_TIMESTAMP=20260830T000000Z bash -c '
      . "$1/bootstrap.sh"
      mv() {
        if [ "$1" = "$HOME/.zprofile" ] ||
          [ "$1" = "$DOTFILES_BACKUP_ROOT/.zshrc" ]
        then
          return 73
        fi
        command mv "$@"
      }
      dotfiles_backup_managed_targets
    ' shell "$REPO_ROOT" 2>&1)
  backup_status=$?
  set -e

  assert_equals 1 "$backup_status" 'backup-stage rollback failure did not exit 1'
  case $backup_output in
    *"could not restore $home/.zshrc from $backup/.zshrc; backup remains at $backup"*) : ;;
    *) fail 'backup-stage rollback diagnostic omitted the restore source and exact backup path' ;;
  esac
}

test_rollback_retains_directory_backup_when_cleanup_leaves_destination() {
  home="$TEST_TMP_ROOT/cleanup-failure-home"
  backup="$home/state/dotfiles-backups/20260830T000000Z"
  mkdir -p "$home/.config/nvim" "$backup/.config/nvim"
  printf 'deployed\n' >"$home/.config/nvim/init.lua"
  printf 'original\n' >"$backup/.config/nvim/original.lua"

  set +e
  rollback_output=$(HOME="$home" bash -c '
    . "$1/bootstrap.sh"
    DOTFILES_BACKUP_ROOT=$2
    DOTFILES_ABSENT_TARGETS=("")
    DOTFILES_MOVED_TARGETS=("" ".config/nvim")
    rm() { return 73; }
    dotfiles_rollback_migration
  ' shell "$REPO_ROOT" "$backup" 2>&1)
  rollback_status=$?
  set -e

  assert_equals 1 "$rollback_status" 'cleanup failure did not make rollback fail'
  [ -f "$backup/.config/nvim/original.lua" ] ||
    fail 'rollback moved the original directory out of its backup after cleanup failed'
  [ ! -e "$home/.config/nvim/nvim" ] ||
    fail 'rollback nested the original directory inside the deployed directory'
  case $rollback_output in
    *"could not restore $home/.config/nvim from $backup/.config/nvim; destination still exists; backup remains at $backup"*) : ;;
    *) fail 'cleanup-failure rollback diagnostic omitted the retained directory backup' ;;
  esac
}

test_migration_rejects_unsafe_timestamp_before_mutation() {
  home="$TEST_TMP_ROOT/unsafe-timestamp-home"
  stow="$TEST_TMP_ROOT/unsafe-timestamp-stow"
  receipt="$TEST_TMP_ROOT/unsafe-timestamp-receipt"
  escaped="$home/state/escaped-backup"
  mkdir -p "$home"
  printf 'old zshrc\n' >"$home/.zshrc"
  make_stow_double "$stow" migrate-success

  DOTFILES_TEST_TIMESTAMP='../escaped-backup'
  export DOTFILES_TEST_TIMESTAMP
  set +e
  timestamp_output=$(run_bootstrap "$home" "$stow" "$receipt" --migrate 2>&1)
  timestamp_status=$?
  set -e
  unset DOTFILES_TEST_TIMESTAMP

  assert_equals 2 "$timestamp_status" 'unsafe migration timestamp did not exit 2'
  case $timestamp_output in
    *'DOTFILES_TIMESTAMP must be one safe basename'*) : ;;
    *) fail 'unsafe migration timestamp diagnostic is missing' ;;
  esac
  assert_equals 'old zshrc' "$(cat "$home/.zshrc")" \
    'unsafe migration timestamp moved the managed target'
  [ ! -e "$escaped" ] || fail 'unsafe migration timestamp escaped the backup root'
  [ ! -e "$receipt" ] ||
    fail 'unsafe migration timestamp invoked Stow before rejection'
}

test_relative_xdg_state_home_falls_back_inside_home() {
  home="$TEST_TMP_ROOT/relative-state-home"
  work="$TEST_TMP_ROOT/relative-state-work"
  stow="$TEST_TMP_ROOT/relative-state-stow"
  receipt="$TEST_TMP_ROOT/relative-state-receipt"
  backup="$home/.local/state/dotfiles-backups/20260830T000000Z"
  mkdir -p "$home" "$work"
  printf 'old zshrc\n' >"$home/.zshrc"
  make_stow_double "$stow" migrate-success

  DOTFILES_TEST_XDG_STATE_HOME=relative-state
  export DOTFILES_TEST_XDG_STATE_HOME
  migration_output=$(
    cd "$work"
    run_bootstrap "$home" "$stow" "$receipt" --migrate
  )
  unset DOTFILES_TEST_XDG_STATE_HOME

  assert_equals "dotfiles: backup created at $backup" "$migration_output" \
    'relative XDG_STATE_HOME did not fall back to the home-local state directory'
  assert_equals 'old zshrc' "$(cat "$backup/.zshrc")" \
    'state fallback omitted the migrated target'
  [ ! -e "$work/relative-state" ] ||
    fail 'relative XDG_STATE_HOME created backup state relative to the working directory'
}

test_failed_deployment_removes_new_links_and_restores_every_target() {
  home="$TEST_TMP_ROOT/rollback-home"
  stow="$TEST_TMP_ROOT/rollback-stow"
  receipt="$TEST_TMP_ROOT/rollback-receipt"
  backup="$home/state/dotfiles-backups/20260830T000000Z"
  mkdir -p "$home"
  seed_managed_conflicts "$home"
  make_stow_double "$stow" deploy-failure

  set +e
  run_bootstrap "$home" "$stow" "$receipt" --migrate \
    >"$TEST_TMP_ROOT/rollback-run.out" 2>&1
  deployment_status=$?
  set -e

  assert_equals 1 "$deployment_status" 'failed deployment did not exit 1'
  assert_originals_restored "$home"
  [ ! -e "$backup/.zshrc" ] || fail 'rollback left the restored .zshrc in backup'
  [ ! -e "$backup/.config/nvim" ] || fail 'rollback left restored Neovim in backup'
}

test_failed_deployment_removes_link_inside_existing_nvim_directory() {
  home="$TEST_TMP_ROOT/partial-nvim-home"
  stow="$TEST_TMP_ROOT/partial-nvim-stow"
  receipt="$TEST_TMP_ROOT/partial-nvim-receipt"
  mkdir -p "$home/.config/nvim/lua" "$home/.config/herdr"
  printf 'keep nvim state\n' >"$home/.config/nvim/lua/user.lua"
  printf 'keep history\n' >"$home/.config/herdr/history.db"
  make_stow_double "$stow" partial-nvim-deploy-failure

  set +e
  run_bootstrap "$home" "$stow" "$receipt" --migrate \
    >"$TEST_TMP_ROOT/partial-nvim-run.out" 2>&1
  deployment_status=$?
  set -e

  assert_equals 1 "$deployment_status" 'partial Neovim deployment did not exit 1'
  assert_equals 'keep nvim state' "$(cat "$home/.config/nvim/lua/user.lua")" \
    'rollback changed pre-existing Neovim state'
  if [ -e "$home/.config/nvim/init.lua" ] ||
    [ -L "$home/.config/nvim/init.lua" ]
  then
    fail 'rollback left a partial Neovim link'
  fi
  assert_equals 'keep history' "$(cat "$home/.config/herdr/history.db")" \
    'rollback changed unrelated Herdr state'
}

test_failed_deployment_restores_partially_managed_nvim_directory() {
  home="$TEST_TMP_ROOT/partial-managed-nvim-home"
  stow="$TEST_TMP_ROOT/partial-managed-nvim-stow"
  receipt="$TEST_TMP_ROOT/partial-managed-nvim-receipt"
  mkdir -p "$home/.config/nvim" "$home/.config/herdr"
  ln -s "$REPO_ROOT/nvim/.config/nvim/init.lua" "$home/.config/nvim/init.lua"
  printf 'keep history\n' >"$home/.config/herdr/history.db"
  make_stow_double "$stow" partial-managed-nvim-deploy-failure

  set +e
  run_bootstrap "$home" "$stow" "$receipt" --migrate \
    >"$TEST_TMP_ROOT/partial-managed-nvim-run.out" 2>&1
  deployment_status=$?
  set -e

  assert_equals 1 "$deployment_status" 'partial managed Neovim deployment did not exit 1'
  [ -L "$home/.config/nvim/init.lua" ] ||
    fail 'rollback removed the original managed Neovim link'
  [ "$home/.config/nvim/init.lua" -ef "$REPO_ROOT/nvim/.config/nvim/init.lua" ] ||
    fail 'rollback changed the original managed Neovim link'
  if [ -e "$home/.config/nvim/.neoconf.json" ] ||
    [ -L "$home/.config/nvim/.neoconf.json" ]
  then
    fail 'rollback left the added partially managed Neovim link'
  fi
  assert_equals 'keep history' "$(cat "$home/.config/herdr/history.db")" \
    'rollback changed unrelated Herdr state'
}

test_migration_does_not_back_up_a_fully_managed_nvim_tree() {
  home="$TEST_TMP_ROOT/fully-managed-nvim-home"
  stow="$TEST_TMP_ROOT/fully-managed-nvim-stow"
  receipt="$TEST_TMP_ROOT/fully-managed-nvim-receipt"
  source_path="$REPO_ROOT/nvim/.config/nvim"
  mkdir -p "$home/.config/nvim"
  while IFS= read -r source_file; do
    relative_path=${source_file#"$source_path"/}
    mkdir -p "$(dirname "$home/.config/nvim/$relative_path")"
    ln -s "$source_file" "$home/.config/nvim/$relative_path"
  done < <(find "$source_path" \( -type f -o -type l \) -print)
  make_stow_double "$stow" fully-managed-nvim-success

  run_bootstrap "$home" "$stow" "$receipt" --migrate

  [ ! -e "$home/state/dotfiles-backups/20260830T000000Z" ] ||
    fail 'migration backed up a fully managed Neovim tree'
  simulation_count=$(grep -F -c -- '|--simulate --no-folding' "$receipt")
  assert_equals 1 "$simulation_count" 'migration re-simulated a fully managed Neovim tree'
  assert_file_contains "$receipt" \
    "$REPO_ROOT|--no-folding --target=$home zsh nvim herdr git"
}

test_successful_default_deploys_with_exact_contract() {
  home="$TEST_TMP_ROOT/success-home"
  stow="$TEST_TMP_ROOT/success-stow"
  receipt="$TEST_TMP_ROOT/success-receipt"
  mkdir -p "$home"
  make_stow_double "$stow" success

  run_bootstrap "$home" "$stow" "$receipt"

  assert_file_contains "$receipt" \
    "$REPO_ROOT|--simulate --no-folding --target=$home zsh nvim herdr git"
  assert_file_contains "$receipt" \
    "$REPO_ROOT|--no-folding --target=$home zsh nvim herdr git"
  [ -L "$home/.zshrc" ] || fail 'default mode did not deploy configuration'
  [ -L "$home/.config/git/config" ] || fail 'default mode did not deploy Git config'
}

test_real_stow_smoke_validates_package_layout_and_no_folding() {
  home="$TEST_TMP_ROOT/real-stow-home"
  mkdir -p "$home"
  command -v stow >/dev/null 2>&1 || fail 'real GNU Stow is required for the smoke test'

  (
    cd "$REPO_ROOT"
    stow --simulate --no-folding --target="$home" zsh nvim herdr git
    stow --no-folding --target="$home" zsh nvim herdr git
  )

  if [ ! -d "$home/.config" ] || [ -L "$home/.config" ]; then
    fail 'real Stow folded the shared .config directory'
  fi
  if [ ! -d "$home/.config/nvim" ] || [ -L "$home/.config/nvim" ]; then
    fail 'real Stow folded the Neovim package directory'
  fi
  for linked_path in \
    .zshrc \
    .zprofile \
    .config/nvim/init.lua \
    .config/markdownlint/.markdownlint.yaml \
    .config/herdr/config.toml \
    .config/git/config
  do
    [ -L "$home/$linked_path" ] ||
      fail "real Stow did not deploy the expected leaf link: $linked_path"
  done
  [ "$home/.config/nvim/init.lua" -ef "$REPO_ROOT/nvim/.config/nvim/init.lua" ] ||
    fail 'real Stow linked Neovim from the wrong package source'
}

test_bootstrap_is_idempotent_and_never_writes_herdr_runtime_state_to_repository() {
  home="$TEST_TMP_ROOT/idempotent-home"
  stow="$TEST_TMP_ROOT/idempotent-stow"
  receipt="$TEST_TMP_ROOT/idempotent-receipt"
  repository_state_before=$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all --ignored)
  mkdir -p "$home/.config/herdr"
  printf 'keep history\n' >"$home/.config/herdr/history.db"
  make_stow_double "$stow" success

  run_bootstrap "$home" "$stow" "$receipt"
  run_bootstrap "$home" "$stow" "$receipt"

  assert_equals 2 "$(grep -F -c -- '|--no-folding' "$receipt")" \
    'two bootstrap runs did not deploy twice'
  [ -L "$home/.zshrc" ] || fail 'second bootstrap run removed .zshrc'
  assert_equals 'keep history' "$(cat "$home/.config/herdr/history.db")" \
    'bootstrap changed Herdr runtime history'
  [ ! -e "$REPO_ROOT/herdr/.config/herdr/history.db" ] ||
    fail 'Herdr runtime history was written inside the repository'
  assert_equals "$repository_state_before" \
    "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all --ignored)" \
    'bootstrap changed the repository while preserving Herdr runtime state'
}

test_invalid_arguments_exit_two
test_bootstrap_deploys_without_platform_provisioning
test_check_reports_dotfile_conflicts_without_running_stow
test_check_reports_parent_conflicts_without_running_stow
test_default_preflight_refuses_unmanaged_target
test_default_preflight_refuses_merge_compatible_unmanaged_nvim_before_stow
test_migration_backs_up_only_managed_targets_and_deploys
test_merge_compatible_migration_always_reports_created_backup
test_incomplete_rollback_reports_exact_backup_path
test_backup_stage_restore_failure_reports_exact_backup_path
test_rollback_retains_directory_backup_when_cleanup_leaves_destination
test_migration_rejects_unsafe_timestamp_before_mutation
test_relative_xdg_state_home_falls_back_inside_home
test_failed_deployment_removes_new_links_and_restores_every_target
test_failed_deployment_removes_link_inside_existing_nvim_directory
test_failed_deployment_restores_partially_managed_nvim_directory
test_migration_does_not_back_up_a_fully_managed_nvim_tree
test_successful_default_deploys_with_exact_contract
test_real_stow_smoke_validates_package_layout_and_no_folding
test_bootstrap_is_idempotent_and_never_writes_herdr_runtime_state_to_repository
printf 'ok - bootstrap behavior\n'
