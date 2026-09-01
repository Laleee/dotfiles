#!/usr/bin/env bash

set -eu
set -o pipefail

DOTFILES_REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DOTFILES_STOW_CMD=${DOTFILES_STOW_CMD:-stow}
DOTFILES_DATE_CMD=${DOTFILES_DATE_CMD:-date}

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

dotfiles_validate_timestamp_override() {
  case ${DOTFILES_TIMESTAMP:-} in
    '') return 0 ;;
    .|..|*/*|*[!A-Za-z0-9._-]*)
      bootstrap_error 'DOTFILES_TIMESTAMP must be one safe basename'
      return 2
      ;;
    *) return 0 ;;
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

dotfiles_validate_parent_paths() {
  local relative_path
  local parent_path
  local destination
  local seen_parents=' '
  local conflict_found=0
  for relative_path in "${DOTFILES_MANAGED_TARGETS[@]}"; do
    parent_path=${relative_path%/*}
    while [ "$parent_path" != "$relative_path" ]; do
      case $seen_parents in
        *" $parent_path "*) ;;
        *)
          destination=$HOME/$parent_path
          if dotfiles_target_exists "$destination" && [ ! -d "$destination" ]; then
            bootstrap_error "unmanaged parent conflict: $destination"
            conflict_found=1
          fi
          seen_parents="$seen_parents$parent_path "
          ;;
      esac
      relative_path=$parent_path
      parent_path=${relative_path%/*}
    done
  done
  if [ "$conflict_found" -eq 1 ]; then
    bootstrap_error 'move these parent paths before deploying dotfiles'
    return 1
  fi
}

dotfiles_nvim_tree_is_managed() {
  local destination=$1
  local source_path=$DOTFILES_REPO_ROOT/nvim/.config/nvim
  local source_file
  local relative_path

  if [ -L "$destination" ]; then
    [ "$destination" -ef "$source_path" ]
    return $?
  fi
  [ -d "$destination" ] || return 1

  while IFS= read -r source_file; do
    relative_path=${source_file#"$source_path"/}
    [ -L "$destination/$relative_path" ] &&
      [ "$destination/$relative_path" -ef "$source_file" ] || return 1
  done < <(find "$source_path" \( -type f -o -type l \) -print)
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
      dotfiles_nvim_tree_is_managed "$destination"
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

dotfiles_have_unmanaged_migratable_targets() {
  local relative_path
  for relative_path in "${DOTFILES_MANAGED_TARGETS[@]}"; do
    if dotfiles_target_exists "$HOME/$relative_path" &&
      ! dotfiles_target_is_managed "$relative_path"
    then
      return 0
    fi
  done
  return 1
}

dotfiles_make_backup_root() {
  local state_root
  local state_home
  local timestamp
  dotfiles_validate_timestamp_override || return $?
  case ${XDG_STATE_HOME:-} in
    /*) state_home=$XDG_STATE_HOME ;;
    *) state_home=$HOME/.local/state ;;
  esac
  state_root=$state_home/dotfiles-backups
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
    if dotfiles_target_exists "$HOME/$relative_path"; then
      bootstrap_error \
        "could not restore $HOME/$relative_path from $DOTFILES_BACKUP_ROOT/$relative_path; destination still exists; backup remains at $DOTFILES_BACKUP_ROOT"
      restore_status=1
      continue
    fi
    mkdir -p "$(dirname -- "$HOME/$relative_path")"
    if ! mv "$DOTFILES_BACKUP_ROOT/$relative_path" "$HOME/$relative_path"; then
      bootstrap_error \
        "could not restore $HOME/$relative_path from $DOTFILES_BACKUP_ROOT/$relative_path; backup remains at $DOTFILES_BACKUP_ROOT"
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
      if ! rm -rf -- "${HOME:?}/${relative_path:?}"; then
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
    if dotfiles_target_exists "$HOME/$relative_path" &&
      ! dotfiles_target_is_managed "$relative_path"
    then
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

dotfiles_report_created_backup() {
  if [ -n "$DOTFILES_BACKUP_ROOT" ]; then
    printf 'dotfiles: backup created at %s\n' "$DOTFILES_BACKUP_ROOT"
  fi
}

dotfiles_report_incomplete_rollback() {
  bootstrap_error "rollback was incomplete; restore $DOTFILES_BACKUP_ROOT manually"
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
    if dotfiles_have_unmanaged_migratable_targets; then
      if ! dotfiles_backup_managed_targets; then
        return 1
      fi
      if ! dotfiles_stow_simulate; then
        bootstrap_error 'Stow simulation still fails after backing up managed targets'
        dotfiles_rollback_migration ||
          dotfiles_report_incomplete_rollback
        return 1
      fi
    fi
    if ! dotfiles_stow_deploy; then
      bootstrap_error 'Stow deployment failed; removing newly deployed links'
      dotfiles_rollback_migration ||
        dotfiles_report_incomplete_rollback
      return 1
    fi
    dotfiles_report_created_backup
    return 0
  fi

  if ! dotfiles_have_unmanaged_migratable_targets; then
    bootstrap_error 'Stow simulation failed and no managed target can be migrated'
    return 1
  fi
  if ! dotfiles_backup_managed_targets; then
    return 1
  fi
  if ! dotfiles_stow_simulate; then
    bootstrap_error 'Stow simulation still fails after backing up managed targets'
    dotfiles_rollback_migration ||
      dotfiles_report_incomplete_rollback
    return 1
  fi
  if ! dotfiles_stow_deploy; then
    bootstrap_error 'Stow deployment failed; restoring migrated targets'
    dotfiles_rollback_migration ||
      dotfiles_report_incomplete_rollback
    return 1
  fi
  dotfiles_report_created_backup
}

bootstrap_main() {
  local mode=deploy
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

  if [ "$mode" = migrate ]; then
    dotfiles_validate_timestamp_override || return $?
  fi

  dotfiles_validate_parent_paths || return 1

  if [ "$mode" = check ]; then
    if dotfiles_have_unmanaged_migratable_targets; then
      dotfiles_report_conflicts
      return 1
    fi
    return 0
  fi

  if [ "$mode" = deploy ] && dotfiles_have_unmanaged_migratable_targets; then
    dotfiles_report_conflicts
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
