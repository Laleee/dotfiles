#!/usr/bin/env bash

set -eu
set -o pipefail

DOTFILES_REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DOTFILES_STOW_CMD=${DOTFILES_STOW_CMD:-stow}
DOTFILES_UNAME_CMD=${DOTFILES_UNAME_CMD:-uname}
DOTFILES_DATE_CMD=${DOTFILES_DATE_CMD:-date}
DOTFILES_OS_RELEASE_FILE=${DOTFILES_OS_RELEASE_FILE:-/etc/os-release}

DOTFILES_MANAGED_TARGETS=(
  .zshrc
  .zprofile
  .config/nvim
  .config/markdownlint/.markdownlint.yaml
  .config/herdr/config.toml
)
# Bash 3.2 treats an empty array as unset under `set -u`. Keep an empty
# sentinel and skip it when iterating so sourceable functions remain portable.
DOTFILES_ABSENT_TARGETS=('')
DOTFILES_MOVED_TARGETS=('')
DOTFILES_BACKUP_ROOT=

bootstrap_error() {
  printf 'dotfiles: %s\n' "$*" >&2
}

bootstrap_usage() {
  bootstrap_error "usage: $0 [--check|--migrate]"
}

dotfiles_detect_architecture() {
  local machine_architecture
  if ! machine_architecture=$("$DOTFILES_UNAME_CMD" -m); then
    bootstrap_error 'cannot identify machine architecture'
    return 1
  fi
  case $machine_architecture in
    x86_64|amd64|arm64|aarch64) return 0 ;;
    *)
      bootstrap_error "unsupported architecture: $machine_architecture"
      return 2
      ;;
  esac
}

dotfiles_linux_is_debian_family() {
  local distribution_id
  local distribution_like
  if [ ! -r "$DOTFILES_OS_RELEASE_FILE" ]; then
    bootstrap_error \
      "cannot identify Linux distribution: $DOTFILES_OS_RELEASE_FILE is missing"
    return 2
  fi
  distribution_id=$(sed -n 's/^ID=//p' "$DOTFILES_OS_RELEASE_FILE" |
    tr -d '"' | head -n 1)
  distribution_like=$(sed -n 's/^ID_LIKE=//p' "$DOTFILES_OS_RELEASE_FILE" |
    tr -d '"' | head -n 1)
  case " $distribution_id $distribution_like " in
    *' debian '*|*' ubuntu '*) return 0 ;;
    *)
      bootstrap_error "unsupported Linux distribution: ${distribution_id:-unknown}"
      return 2
      ;;
  esac
}

dotfiles_detect_platform() {
  local operating_system
  if ! operating_system=$("$DOTFILES_UNAME_CMD" -s); then
    bootstrap_error 'cannot identify operating system'
    return 1
  fi
  case $operating_system in
    Darwin)
      dotfiles_detect_architecture || return $?
      printf '%s\n' macos
      ;;
    Linux)
      dotfiles_detect_architecture || return $?
      dotfiles_linux_is_debian_family || return $?
      printf '%s\n' debian
      ;;
    *)
      bootstrap_error "unsupported platform: $operating_system"
      return 2
      ;;
  esac
}

dotfiles_load_platform() {
  local platform=$1
  case $platform in
    macos)
      # shellcheck source=scripts/provision-macos.sh
      . "$DOTFILES_REPO_ROOT/scripts/provision-macos.sh"
      ;;
    debian)
      # shellcheck source=scripts/provision-debian.sh
      . "$DOTFILES_REPO_ROOT/scripts/provision-debian.sh"
      ;;
    *)
      bootstrap_error "unsupported platform: $platform"
      return 2
      ;;
  esac
}

dotfiles_diagnose_platform() {
  local platform=$1
  case $platform in
    macos) diagnose_macos ;;
    debian) diagnose_debian ;;
    *) return 2 ;;
  esac
}

dotfiles_provision_platform() {
  local platform=$1
  case $platform in
    macos) provision_macos ;;
    debian) provision_debian ;;
    *) return 2 ;;
  esac
}

dotfiles_stow_simulate() (
  cd "$DOTFILES_REPO_ROOT"
  "$DOTFILES_STOW_CMD" --simulate --no-folding --target="$HOME" \
    zsh nvim herdr
)

dotfiles_stow_deploy() (
  cd "$DOTFILES_REPO_ROOT"
  "$DOTFILES_STOW_CMD" --no-folding --target="$HOME" zsh nvim herdr
)

dotfiles_target_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

dotfiles_target_is_managed() {
  local relative_path=$1
  local destination=$HOME/$relative_path
  local source_path
  case $relative_path in
    .zshrc) source_path=$DOTFILES_REPO_ROOT/zsh/.zshrc ;;
    .zprofile) source_path=$DOTFILES_REPO_ROOT/zsh/.zprofile ;;
    .config/nvim)
      source_path=$DOTFILES_REPO_ROOT/nvim/.config/nvim
      if [ -L "$destination" ] && [ "$destination" -ef "$source_path" ]; then
        return 0
      fi
      [ -d "$destination" ] && [ -L "$destination/init.lua" ] &&
        [ "$destination/init.lua" -ef "$source_path/init.lua" ]
      return $?
      ;;
    .config/markdownlint/.markdownlint.yaml)
      source_path=$DOTFILES_REPO_ROOT/nvim/$relative_path
      ;;
    .config/herdr/config.toml)
      source_path=$DOTFILES_REPO_ROOT/herdr/$relative_path
      ;;
    *) return 1 ;;
  esac
  [ -L "$destination" ] && [ "$destination" -ef "$source_path" ]
}

dotfiles_report_conflicts() {
  local relative_path
  local conflict_found=0
  for relative_path in "${DOTFILES_MANAGED_TARGETS[@]}"; do
    if dotfiles_target_exists "$HOME/$relative_path" &&
      ! dotfiles_target_is_managed "$relative_path"
    then
      bootstrap_error "unmanaged conflict: $HOME/$relative_path"
      conflict_found=1
    fi
  done
  if [ "$conflict_found" -eq 1 ]; then
    bootstrap_error 'rerun with --migrate to back up these paths'
  else
    bootstrap_error 'Stow simulation failed before deployment'
  fi
}

dotfiles_record_target_state() {
  local relative_path
  DOTFILES_ABSENT_TARGETS=('')
  DOTFILES_MOVED_TARGETS=('')
  DOTFILES_BACKUP_ROOT=
  for relative_path in "${DOTFILES_MANAGED_TARGETS[@]}"; do
    if ! dotfiles_target_exists "$HOME/$relative_path"; then
      DOTFILES_ABSENT_TARGETS+=("$relative_path")
    fi
  done
}

dotfiles_have_migratable_targets() {
  local relative_path
  for relative_path in "${DOTFILES_MANAGED_TARGETS[@]}"; do
    if dotfiles_target_exists "$HOME/$relative_path"; then
      return 0
    fi
  done
  return 1
}

dotfiles_make_backup_root() {
  local state_root
  local timestamp
  state_root=${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-backups
  if [ -n "${DOTFILES_TIMESTAMP:-}" ]; then
    timestamp=$DOTFILES_TIMESTAMP
  elif ! timestamp=$("$DOTFILES_DATE_CMD" -u '+%Y%m%dT%H%M%SZ'); then
    bootstrap_error 'could not create a backup timestamp'
    return 1
  fi
  DOTFILES_BACKUP_ROOT=$state_root/$timestamp
  mkdir -p "$state_root"
  if ! mkdir "$DOTFILES_BACKUP_ROOT"; then
    bootstrap_error "backup path already exists: $DOTFILES_BACKUP_ROOT"
    return 1
  fi
}

dotfiles_restore_moved_targets() {
  local relative_path
  local restore_status=0
  for relative_path in "${DOTFILES_MOVED_TARGETS[@]}"; do
    [ -n "$relative_path" ] || continue
    mkdir -p "$(dirname -- "$HOME/$relative_path")"
    if ! mv "$DOTFILES_BACKUP_ROOT/$relative_path" "$HOME/$relative_path"; then
      bootstrap_error "could not restore $HOME/$relative_path"
      restore_status=1
    fi
  done
  return "$restore_status"
}

dotfiles_remove_new_deployment() {
  local relative_path
  local cleanup_status=0
  for relative_path in \
    "${DOTFILES_ABSENT_TARGETS[@]}" "${DOTFILES_MOVED_TARGETS[@]}"
  do
    [ -n "$relative_path" ] || continue
    if dotfiles_target_exists "$HOME/$relative_path"; then
      if ! rm -rf -- "$HOME/$relative_path"; then
        bootstrap_error "could not remove newly deployed path: $HOME/$relative_path"
        cleanup_status=1
      fi
    fi
  done
  return "$cleanup_status"
}

dotfiles_rollback_migration() {
  local rollback_status=0
  if ! dotfiles_remove_new_deployment; then
    rollback_status=1
  fi
  if ! dotfiles_restore_moved_targets; then
    rollback_status=1
  fi
  return "$rollback_status"
}

dotfiles_backup_managed_targets() {
  local relative_path
  local destination
  dotfiles_make_backup_root || return 1
  for relative_path in "${DOTFILES_MANAGED_TARGETS[@]}"; do
    if dotfiles_target_exists "$HOME/$relative_path"; then
      destination=$DOTFILES_BACKUP_ROOT/$relative_path
      mkdir -p "$(dirname -- "$destination")"
      if ! mv "$HOME/$relative_path" "$destination"; then
        bootstrap_error "could not back up $HOME/$relative_path"
        dotfiles_restore_moved_targets || :
        return 1
      fi
      DOTFILES_MOVED_TARGETS+=("$relative_path")
    fi
  done
}

dotfiles_deploy_default() {
  if ! dotfiles_stow_simulate; then
    dotfiles_report_conflicts
    return 1
  fi
  if ! dotfiles_stow_deploy; then
    bootstrap_error 'Stow deployment failed'
    return 1
  fi
}

dotfiles_deploy_migration() {
  dotfiles_record_target_state
  if dotfiles_stow_simulate; then
    if ! dotfiles_stow_deploy; then
      bootstrap_error 'Stow deployment failed; removing newly deployed links'
      dotfiles_rollback_migration ||
        bootstrap_error 'rollback was incomplete; restore the backup manually'
      return 1
    fi
    return 0
  fi

  if ! dotfiles_have_migratable_targets; then
    bootstrap_error 'Stow simulation failed and no managed target can be migrated'
    return 1
  fi
  if ! dotfiles_backup_managed_targets; then
    return 1
  fi
  if ! dotfiles_stow_simulate; then
    bootstrap_error 'Stow simulation still fails after backing up managed targets'
    dotfiles_rollback_migration ||
      bootstrap_error 'rollback was incomplete; restore the backup manually'
    return 1
  fi
  if ! dotfiles_stow_deploy; then
    bootstrap_error 'Stow deployment failed; restoring migrated targets'
    dotfiles_rollback_migration ||
      bootstrap_error "rollback was incomplete; restore $DOTFILES_BACKUP_ROOT manually"
    return 1
  fi
  printf 'dotfiles: backup created at %s\n' "$DOTFILES_BACKUP_ROOT"
}

bootstrap_main() {
  local mode=deploy
  local platform
  if [ "$#" -gt 1 ]; then
    bootstrap_usage
    return 2
  fi
  case ${1:-} in
    '') ;;
    --check) mode=check ;;
    --migrate) mode=migrate ;;
    *)
      bootstrap_usage
      return 2
      ;;
  esac

  platform=$(dotfiles_detect_platform) || return $?
  dotfiles_load_platform "$platform" || return $?
  if [ "$mode" = check ]; then
    if ! dotfiles_diagnose_platform "$platform"; then
      return 1
    fi
    return 0
  fi

  if ! dotfiles_provision_platform "$platform"; then
    bootstrap_error 'provisioning failed'
    return 1
  fi
  case $mode in
    deploy) dotfiles_deploy_default ;;
    migrate) dotfiles_deploy_migration ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  bootstrap_main "$@"
fi
