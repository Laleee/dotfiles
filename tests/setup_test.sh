#!/usr/bin/env bash

set -eu
set -o pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-setup-test.XXXXXX")
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

make_setup_doubles() {
  bin=$1
  mkdir -p "$bin"
  cat >"$bin/uname" <<'EOF'
#!/bin/sh
set -eu
case $1 in
  -s) printf '%s\n' "$DOTFILES_TEST_OS" ;;
  -m) printf '%s\n' "$DOTFILES_TEST_ARCH" ;;
  *) exit 64 ;;
esac
EOF
  cat >"$bin/bootstrap" <<'EOF'
#!/bin/sh
printf 'bootstrap:%s\n' "$*" >>"$DOTFILES_TEST_RECEIPT"
EOF
  cat >"$bin/provision-macos" <<'EOF'
#!/bin/sh
printf 'macos:%s\n' "$*" >>"$DOTFILES_TEST_RECEIPT"
EOF
  cat >"$bin/provision-debian" <<'EOF'
#!/bin/sh
printf 'debian:%s\n' "$*" >>"$DOTFILES_TEST_RECEIPT"
EOF
  chmod +x "$bin/uname" "$bin/bootstrap" \
    "$bin/provision-macos" "$bin/provision-debian"
}

run_setup() {
  bin=$1
  receipt=$2
  shift 2
  DOTFILES_SETUP_UNAME_CMD="$bin/uname" \
    DOTFILES_SETUP_BOOTSTRAP="$bin/bootstrap" \
    DOTFILES_SETUP_MACOS_PROVISIONER="$bin/provision-macos" \
    DOTFILES_SETUP_DEBIAN_PROVISIONER="$bin/provision-debian" \
    DOTFILES_TEST_RECEIPT="$receipt" "$@"
}

test_default_preflights_then_provisions_and_deploys_on_macos() {
  bin="$TEST_TMP_ROOT/macos-bin"
  receipt="$TEST_TMP_ROOT/macos-receipt"
  make_setup_doubles "$bin"

  DOTFILES_TEST_OS=Darwin DOTFILES_TEST_ARCH=arm64 \
    run_setup "$bin" "$receipt" bash "$REPO_ROOT/setup.sh"

  assert_equals 'bootstrap:--check
macos:provision
bootstrap:' "$(cat "$receipt")" \
    'default setup did not preserve preflight, provision, deploy ordering'
}

test_migrate_selects_debian_provisioning_and_forwards_the_mode() {
  bin="$TEST_TMP_ROOT/debian-bin"
  receipt="$TEST_TMP_ROOT/debian-receipt"
  os_release="$TEST_TMP_ROOT/os-release"
  make_setup_doubles "$bin"
  printf 'ID=ubuntu\nID_LIKE=debian\n' >"$os_release"

  DOTFILES_TEST_OS=Linux DOTFILES_TEST_ARCH=x86_64 \
    DOTFILES_SETUP_OS_RELEASE_FILE="$os_release" \
    run_setup "$bin" "$receipt" bash "$REPO_ROOT/setup.sh" --migrate

  assert_equals 'debian:provision
bootstrap:--migrate' "$(cat "$receipt")" \
    'migration setup selected or forwarded the wrong command'
}

test_failed_provisioning_prevents_deployment() {
  bin="$TEST_TMP_ROOT/failure-bin"
  receipt="$TEST_TMP_ROOT/failure-receipt"
  make_setup_doubles "$bin"
  cat >"$bin/provision-macos" <<'EOF'
#!/bin/sh
printf 'macos:%s\n' "$*" >>"$DOTFILES_TEST_RECEIPT"
exit 73
EOF
  chmod +x "$bin/provision-macos"

  set +e
  DOTFILES_TEST_OS=Darwin DOTFILES_TEST_ARCH=x86_64 \
    run_setup "$bin" "$receipt" bash "$REPO_ROOT/setup.sh"
  setup_status=$?
  set -e

  assert_equals 1 "$setup_status" 'setup did not normalize provisioning failure to 1'
  assert_equals 'bootstrap:--check
macos:provision' "$(cat "$receipt")" \
    'setup deployed after provisioning failed'
}

test_check_runs_both_diagnostics_and_dotfile_preflight() {
  bin="$TEST_TMP_ROOT/check-bin"
  receipt="$TEST_TMP_ROOT/check-receipt"
  make_setup_doubles "$bin"
  cat >"$bin/provision-macos" <<'EOF'
#!/bin/sh
printf 'macos:%s\n' "$*" >>"$DOTFILES_TEST_RECEIPT"
exit 1
EOF
  chmod +x "$bin/provision-macos"

  set +e
  DOTFILES_TEST_OS=Darwin DOTFILES_TEST_ARCH=x86_64 \
    run_setup "$bin" "$receipt" bash "$REPO_ROOT/setup.sh" --check
  check_status=$?
  set -e

  assert_equals 1 "$check_status" 'setup --check hid a failed diagnostic'
  assert_equals 'macos:diagnose
bootstrap:--check' "$(cat "$receipt")" \
    'setup --check did not run both read-only checks'
}

test_parent_conflict_prevents_provisioning() {
  home="$TEST_TMP_ROOT/parent-conflict-home"
  bin="$TEST_TMP_ROOT/parent-conflict-bin"
  receipt="$TEST_TMP_ROOT/parent-conflict-receipt"
  mkdir -p "$home"
  printf 'blocks managed children\n' >"$home/.config"
  make_setup_doubles "$bin"

  set +e
  HOME="$home" DOTFILES_TEST_OS=Darwin DOTFILES_TEST_ARCH=arm64 \
    DOTFILES_SETUP_UNAME_CMD="$bin/uname" \
    DOTFILES_SETUP_BOOTSTRAP="$REPO_ROOT/bootstrap.sh" \
    DOTFILES_SETUP_MACOS_PROVISIONER="$bin/provision-macos" \
    DOTFILES_SETUP_DEBIAN_PROVISIONER="$bin/provision-debian" \
    DOTFILES_TEST_RECEIPT="$receipt" bash "$REPO_ROOT/setup.sh" >/dev/null 2>&1
  setup_status=$?
  set -e

  assert_equals 1 "$setup_status" 'setup accepted a blocking parent path'
  [ ! -e "$receipt" ] || fail 'setup provisioned after parent preflight failed'
}

test_default_preflights_then_provisions_and_deploys_on_macos
test_migrate_selects_debian_provisioning_and_forwards_the_mode
test_failed_provisioning_prevents_deployment
test_check_runs_both_diagnostics_and_dotfile_preflight
test_parent_conflict_prevents_provisioning
printf 'ok - setup orchestration\n'
