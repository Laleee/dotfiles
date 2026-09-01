#!/usr/bin/env bash

set -eu
set -o pipefail

DOTFILES_SETUP_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DOTFILES_SETUP_UNAME_CMD=${DOTFILES_SETUP_UNAME_CMD:-uname}
DOTFILES_SETUP_OS_RELEASE_FILE=${DOTFILES_SETUP_OS_RELEASE_FILE:-/etc/os-release}
DOTFILES_SETUP_BOOTSTRAP=${DOTFILES_SETUP_BOOTSTRAP:-$DOTFILES_SETUP_ROOT/bootstrap.sh}
DOTFILES_SETUP_MACOS_PROVISIONER=${DOTFILES_SETUP_MACOS_PROVISIONER:-$DOTFILES_SETUP_ROOT/scripts/provision-macos.sh}
DOTFILES_SETUP_DEBIAN_PROVISIONER=${DOTFILES_SETUP_DEBIAN_PROVISIONER:-$DOTFILES_SETUP_ROOT/scripts/provision-debian.sh}

setup_error() {
  printf 'dotfiles: %s\n' "$*" >&2
}

setup_usage() {
  setup_error "usage: $0 [--check|--migrate]"
}

setup_detect_architecture() {
  local machine_architecture
  if ! machine_architecture=$("$DOTFILES_SETUP_UNAME_CMD" -m); then
    setup_error 'cannot identify machine architecture'
    return 1
  fi
  case $machine_architecture in
    x86_64|amd64|arm64|aarch64) return 0 ;;
    *)
      setup_error "unsupported architecture: $machine_architecture"
      return 2
      ;;
  esac
}

setup_linux_is_debian_family() {
  local distribution_id
  local distribution_like
  if [ ! -r "$DOTFILES_SETUP_OS_RELEASE_FILE" ]; then
    setup_error \
      "cannot identify Linux distribution: $DOTFILES_SETUP_OS_RELEASE_FILE is missing"
    return 2
  fi
  distribution_id=$(sed -n 's/^ID=//p' "$DOTFILES_SETUP_OS_RELEASE_FILE" |
    tr -d '"' | head -n 1)
  distribution_like=$(sed -n 's/^ID_LIKE=//p' "$DOTFILES_SETUP_OS_RELEASE_FILE" |
    tr -d '"' | head -n 1)
  case " $distribution_id $distribution_like " in
    *' debian '*|*' ubuntu '*) return 0 ;;
    *)
      setup_error "unsupported Linux distribution: ${distribution_id:-unknown}"
      return 2
      ;;
  esac
}

setup_detect_platform() {
  local operating_system
  if ! operating_system=$("$DOTFILES_SETUP_UNAME_CMD" -s); then
    setup_error 'cannot identify operating system'
    return 1
  fi
  case $operating_system in
    Darwin)
      setup_detect_architecture || return $?
      printf '%s\n' macos
      ;;
    Linux)
      setup_detect_architecture || return $?
      setup_linux_is_debian_family || return $?
      printf '%s\n' debian
      ;;
    *)
      setup_error "unsupported platform: $operating_system"
      return 2
      ;;
  esac
}

setup_provisioner() {
  case $1 in
    macos) printf '%s\n' "$DOTFILES_SETUP_MACOS_PROVISIONER" ;;
    debian) printf '%s\n' "$DOTFILES_SETUP_DEBIAN_PROVISIONER" ;;
    *) return 2 ;;
  esac
}

setup_run_provisioner() {
  local provisioner=$1
  if ! "$provisioner" provision; then
    return 1
  fi
}

setup_run_checks() {
  local provisioner=$1
  local check_status=0
  "$provisioner" diagnose || check_status=1
  "$DOTFILES_SETUP_BOOTSTRAP" --check || check_status=1
  return "$check_status"
}

setup_main() {
  local mode=deploy
  local platform
  local provisioner
  if [ "$#" -gt 1 ]; then
    setup_usage
    return 2
  fi
  case ${1:-} in
    '') ;;
    --check) mode=check ;;
    --migrate) mode=migrate ;;
    *)
      setup_usage
      return 2
      ;;
  esac

  platform=$(setup_detect_platform) || return $?
  provisioner=$(setup_provisioner "$platform") || return $?

  case $mode in
    check) setup_run_checks "$provisioner" ;;
    deploy)
      "$DOTFILES_SETUP_BOOTSTRAP" --check
      setup_run_provisioner "$provisioner"
      "$DOTFILES_SETUP_BOOTSTRAP"
      ;;
    migrate)
      setup_run_provisioner "$provisioner"
      "$DOTFILES_SETUP_BOOTSTRAP" --migrate
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  setup_main "$@"
fi
