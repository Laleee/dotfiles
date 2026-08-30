#!/usr/bin/env bash

set -eu
set -o pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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

run_with_macos_functions() {
  home=$1
  stow_cmd=$2
  receipt=$3
  shift 3
  HOME="$home" XDG_STATE_HOME="$home/state" \
    DOTFILES_STOW_CMD="$stow_cmd" DOTFILES_TEST_RECEIPT="$receipt" \
    DOTFILES_TEST_REPO="$REPO_ROOT" DOTFILES_TIMESTAMP=20260830T000000Z \
    bash -c '
      . "$1/bootstrap.sh"
      shift
      dotfiles_detect_platform() { printf "%s\n" macos; }
      dotfiles_load_platform() { :; }
      provision_macos() { printf "%s\n" provision >>"$DOTFILES_TEST_RECEIPT"; }
      diagnose_macos() { printf "%s\n" diagnose >>"$DOTFILES_TEST_RECEIPT"; }
      bootstrap_main "$@"
    ' shell "$REPO_ROOT" "$@"
}

run_with_failed_macos_provision() {
  home=$1
  stow_cmd=$2
  receipt=$3
  HOME="$home" XDG_STATE_HOME="$home/state" \
    DOTFILES_STOW_CMD="$stow_cmd" DOTFILES_TEST_RECEIPT="$receipt" \
    DOTFILES_TEST_REPO="$REPO_ROOT" DOTFILES_TIMESTAMP=20260830T000000Z \
    bash -c '
      . "$1/bootstrap.sh"
      shift
      dotfiles_detect_platform() { printf "%s\n" macos; }
      dotfiles_load_platform() { :; }
      provision_macos() {
        false
        printf "%s\n" late-provision-step >>"$DOTFILES_TEST_RECEIPT"
      }
      bootstrap_main "$@"
    ' shell "$REPO_ROOT"
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
  *) exit 64 ;;
esac

mkdir -p "$HOME/.config/nvim" "$HOME/.config/markdownlint" "$HOME/.config/herdr"
ln -s "$DOTFILES_TEST_REPO/zsh/.zshrc" "$HOME/.zshrc"
if [ "$DOTFILES_TEST_STOW_BEHAVIOR" = deploy-failure ]; then
  ln -s "$DOTFILES_TEST_REPO/nvim/.config/nvim/init.lua" "$HOME/.config/nvim/init.lua"
  exit 19
fi
if [ "$DOTFILES_TEST_STOW_BEHAVIOR" = partial-nvim-deploy-failure ]; then
  ln -s "$DOTFILES_TEST_REPO/nvim/.config/nvim/init.lua" "$HOME/.config/nvim/init.lua"
  exit 19
fi
if [ "$DOTFILES_TEST_STOW_BEHAVIOR" = partial-managed-nvim-deploy-failure ]; then
  ln -s "$DOTFILES_TEST_REPO/nvim/.config/nvim/.neoconf.json" \
    "$HOME/.config/nvim/.neoconf.json"
  exit 19
fi
ln -s "$DOTFILES_TEST_REPO/zsh/.zprofile" "$HOME/.zprofile"
ln -s "$DOTFILES_TEST_REPO/nvim/.config/nvim/init.lua" "$HOME/.config/nvim/init.lua"
ln -s "$DOTFILES_TEST_REPO/nvim/.config/markdownlint/.markdownlint.yaml" \
  "$HOME/.config/markdownlint/.markdownlint.yaml"
ln -s "$DOTFILES_TEST_REPO/herdr/.config/herdr/config.toml" \
  "$HOME/.config/herdr/config.toml"
EOF
  chmod +x "$destination"
  DOTFILES_TEST_STOW_BEHAVIOR=$behavior
  export DOTFILES_TEST_STOW_BEHAVIOR
}

seed_managed_conflicts() {
  home=$1
  mkdir -p "$home/.config/nvim" "$home/.config/markdownlint" \
    "$home/.config/herdr/nested"
  printf 'old zshrc\n' >"$home/.zshrc"
  printf 'old zprofile\n' >"$home/.zprofile"
  printf 'old init\n' >"$home/.config/nvim/init.lua"
  printf 'old markdownlint\n' >"$home/.config/markdownlint/.markdownlint.yaml"
  printf 'old herdr config\n' >"$home/.config/herdr/config.toml"
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
  assert_equals 'keep history' "$(cat "$home/.config/herdr/history.db")" \
    'Herdr history was not preserved'
  assert_equals 'keep cache' "$(cat "$home/.config/herdr/nested/cache")" \
    'Herdr cache was not preserved'
  assert_equals 'keep unrelated' "$(cat "$home/notes.txt")" \
    'an unrelated path was changed'
}

test_invalid_arguments_and_unsupported_platform_exit_two() {
  home="$TEST_TMP_ROOT/arguments-home"
  bin="$TEST_TMP_ROOT/arguments-bin"
  mkdir -p "$home" "$bin"

  set +e
  HOME="$home" bash "$REPO_ROOT/bootstrap.sh" --unknown >/dev/null 2>&1
  invalid_status=$?
  set -e
  assert_equals 2 "$invalid_status" 'invalid argument did not exit 2'

  cat >"$bin/uname" <<'EOF'
#!/bin/sh
printf 'Plan9\n'
EOF
  chmod +x "$bin/uname"
  set +e
  unsupported_output=$(HOME="$home" DOTFILES_UNAME_CMD="$bin/uname" \
    bash "$REPO_ROOT/bootstrap.sh" --check 2>&1)
  unsupported_status=$?
  set -e
  assert_equals 2 "$unsupported_status" 'unsupported platform did not exit 2'
  case $unsupported_output in
    *'unsupported platform: Plan9'*) : ;;
    *) fail 'unsupported platform diagnostic is missing' ;;
  esac
}

test_check_dispatches_read_only_diagnostics() {
  home="$TEST_TMP_ROOT/check-home"
  stow="$TEST_TMP_ROOT/check-stow"
  receipt="$TEST_TMP_ROOT/check-receipt"
  mkdir -p "$home"
  make_stow_double "$stow" conflict

  run_with_macos_functions "$home" "$stow" "$receipt" --check

  assert_equals diagnose "$(cat "$receipt")" '--check did not dispatch diagnostics only'
  [ -z "$(find "$home" -mindepth 1 -print -quit)" ] || fail '--check mutated HOME'
}

test_failed_provisioning_never_deploys_after_a_later_success() {
  home="$TEST_TMP_ROOT/provision-failure-home"
  stow="$TEST_TMP_ROOT/provision-failure-stow"
  receipt="$TEST_TMP_ROOT/provision-failure-receipt"
  mkdir -p "$home"
  make_stow_double "$stow" success

  set +e
  run_with_failed_macos_provision "$home" "$stow" "$receipt" \
    >"$TEST_TMP_ROOT/provision-failure-run.out" 2>&1
  provisioning_status=$?
  set -e

  assert_equals 1 "$provisioning_status" 'failed provisioning did not exit 1'
  if [ -e "$receipt" ] && grep -F -- 'late-provision-step' "$receipt" >/dev/null 2>&1; then
    fail 'provisioning continued after an early failure'
  fi
  if [ -e "$receipt" ] && grep -F -- '|--no-folding' "$receipt" >/dev/null 2>&1; then
    fail 'failed provisioning attempted deployment'
  fi
  [ ! -L "$home/.zshrc" ] || fail 'failed provisioning deployed .zshrc'
}

test_default_refuses_conflict_after_simulation() {
  home="$TEST_TMP_ROOT/conflict-home"
  stow="$TEST_TMP_ROOT/conflict-stow"
  receipt="$TEST_TMP_ROOT/conflict-receipt"
  mkdir -p "$home"
  printf 'unmanaged\n' >"$home/.zshrc"
  ln -s "$REPO_ROOT/zsh/.zprofile" "$home/.zprofile"
  make_stow_double "$stow" conflict

  set +e
  conflict_output=$(run_with_macos_functions "$home" "$stow" "$receipt" 2>&1)
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
  assert_file_contains "$receipt" \
    "$REPO_ROOT|--simulate --no-folding --target=$home zsh nvim herdr"
  if grep -F -- "$REPO_ROOT|--no-folding" "$receipt" >/dev/null 2>&1; then
    fail 'default conflict attempted a real deployment'
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

  run_with_macos_functions "$home" "$stow" "$receipt" --migrate

  assert_equals 'old zshrc' "$(cat "$backup/.zshrc")" 'backup omitted .zshrc'
  assert_equals 'old zprofile' "$(cat "$backup/.zprofile")" 'backup omitted .zprofile'
  assert_equals 'old init' "$(cat "$backup/.config/nvim/init.lua")" \
    'backup omitted Neovim'
  assert_equals 'old markdownlint' \
    "$(cat "$backup/.config/markdownlint/.markdownlint.yaml")" \
    'backup omitted Markdownlint'
  assert_equals 'old herdr config' "$(cat "$backup/.config/herdr/config.toml")" \
    'backup omitted Herdr config'
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
  assert_file_contains "$receipt" \
    "$REPO_ROOT|--no-folding --target=$home zsh nvim herdr"
  simulation_count=$(grep -F -c -- '|--simulate --no-folding' "$receipt")
  assert_equals 2 "$simulation_count" 'migration did not simulate before and after backup'
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
  run_with_macos_functions "$home" "$stow" "$receipt" --migrate \
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
  run_with_macos_functions "$home" "$stow" "$receipt" --migrate \
    >"$TEST_TMP_ROOT/partial-nvim-run.out" 2>&1
  deployment_status=$?
  set -e

  assert_equals 1 "$deployment_status" 'partial Neovim deployment did not exit 1'
  assert_equals 'keep nvim state' "$(cat "$home/.config/nvim/lua/user.lua")" \
    'rollback changed pre-existing Neovim state'
  [ ! -e "$home/.config/nvim/init.lua" ] && [ ! -L "$home/.config/nvim/init.lua" ] ||
    fail 'rollback left a partial Neovim link'
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
  run_with_macos_functions "$home" "$stow" "$receipt" --migrate \
    >"$TEST_TMP_ROOT/partial-managed-nvim-run.out" 2>&1
  deployment_status=$?
  set -e

  assert_equals 1 "$deployment_status" 'partial managed Neovim deployment did not exit 1'
  [ -L "$home/.config/nvim/init.lua" ] ||
    fail 'rollback removed the original managed Neovim link'
  [ "$home/.config/nvim/init.lua" -ef "$REPO_ROOT/nvim/.config/nvim/init.lua" ] ||
    fail 'rollback changed the original managed Neovim link'
  [ ! -e "$home/.config/nvim/.neoconf.json" ] &&
    [ ! -L "$home/.config/nvim/.neoconf.json" ] ||
    fail 'rollback left the added partially managed Neovim link'
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

  run_with_macos_functions "$home" "$stow" "$receipt" --migrate

  [ ! -e "$home/state/dotfiles-backups/20260830T000000Z" ] ||
    fail 'migration backed up a fully managed Neovim tree'
  simulation_count=$(grep -F -c -- '|--simulate --no-folding' "$receipt")
  assert_equals 1 "$simulation_count" 'migration re-simulated a fully managed Neovim tree'
  assert_file_contains "$receipt" \
    "$REPO_ROOT|--no-folding --target=$home zsh nvim herdr"
}

test_successful_default_deploys_with_exact_contract() {
  home="$TEST_TMP_ROOT/success-home"
  stow="$TEST_TMP_ROOT/success-stow"
  receipt="$TEST_TMP_ROOT/success-receipt"
  mkdir -p "$home"
  make_stow_double "$stow" success

  run_with_macos_functions "$home" "$stow" "$receipt"

  assert_file_contains "$receipt" \
    "$REPO_ROOT|--simulate --no-folding --target=$home zsh nvim herdr"
  assert_file_contains "$receipt" \
    "$REPO_ROOT|--no-folding --target=$home zsh nvim herdr"
  [ -L "$home/.zshrc" ] || fail 'default mode did not deploy configuration'
}

test_invalid_arguments_and_unsupported_platform_exit_two
test_check_dispatches_read_only_diagnostics
test_failed_provisioning_never_deploys_after_a_later_success
test_default_refuses_conflict_after_simulation
test_migration_backs_up_only_managed_targets_and_deploys
test_failed_deployment_removes_new_links_and_restores_every_target
test_failed_deployment_removes_link_inside_existing_nvim_directory
test_failed_deployment_restores_partially_managed_nvim_directory
test_migration_does_not_back_up_a_fully_managed_nvim_tree
test_successful_default_deploys_with_exact_contract
printf 'ok - bootstrap behavior\n'
