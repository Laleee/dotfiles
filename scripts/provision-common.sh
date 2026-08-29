#!/usr/bin/env bash

set -eu
set -o pipefail

DOTFILES_CURL_CMD=${DOTFILES_CURL_CMD:-curl}
DOTFILES_GIT_CMD=${DOTFILES_GIT_CMD:-git}
DOTFILES_MV_CMD=${DOTFILES_MV_CMD:-mv}
DOTFILES_UV_INSTALL_URL=${DOTFILES_UV_INSTALL_URL:-https://astral.sh/uv/install.sh}
DOTFILES_HERDR_INSTALL_URL=${DOTFILES_HERDR_INSTALL_URL:-https://herdr.dev/install.sh}
DOTFILES_OMZ_URL=${DOTFILES_OMZ_URL:-https://github.com/ohmyzsh/ohmyzsh.git}
DOTFILES_AUTOSUGGESTIONS_URL=${DOTFILES_AUTOSUGGESTIONS_URL:-https://github.com/zsh-users/zsh-autosuggestions.git}
DOTFILES_SYNTAX_HIGHLIGHTING_URL=${DOTFILES_SYNTAX_HIGHLIGHTING_URL:-https://github.com/zsh-users/zsh-syntax-highlighting.git}

dotfiles_error() {
  printf 'dotfiles: %s\n' "$*" >&2
}

dotfiles_tool_path() {
  local tool_name=$1
  if [ -x "$HOME/.local/bin/$tool_name" ]; then
    printf '%s\n' "$HOME/.local/bin/$tool_name"
  else
    command -v "$tool_name"
  fi
}

install_remote_script() (
  installer_url=$1
  installer_name=$2
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-installer.XXXXXX")
  trap 'rm -rf "$temp_dir"' EXIT HUP INT TERM
  installer_path="$temp_dir/$installer_name"
  "$DOTFILES_CURL_CMD" -fsSL -o "$installer_path" "$installer_url"
  shift 2
  "$@" sh "$installer_path"
)

install_uv_if_missing() {
  local uv_available=0
  local uvx_available=0
  dotfiles_tool_path uv >/dev/null 2>&1 && uv_available=1
  dotfiles_tool_path uvx >/dev/null 2>&1 && uvx_available=1
  case $uv_available:$uvx_available in
    1:1) return 0 ;;
    1:0)
      dotfiles_error \
        'uv is installed but uvx is missing; refusing to replace the existing UV installation'
      return 1
      ;;
    0:1)
      dotfiles_error \
        'uvx is installed but uv is missing; refusing to replace the existing UV installation'
      return 1
      ;;
    0:0)
      install_remote_script "$DOTFILES_UV_INSTALL_URL" uv-install.sh \
        env UV_NO_MODIFY_PATH=1
      ;;
  esac
}

install_herdr_if_missing() {
  if command -v herdr >/dev/null 2>&1 || [ -x "$HOME/.local/bin/herdr" ]; then
    return 0
  fi
  install_remote_script "$DOTFILES_HERDR_INSTALL_URL" herdr-install.sh env
}

clone_if_missing() {
  local repository_url=$1
  local destination=$2
  if [ -e "$destination" ]; then
    return 0
  fi
  mkdir -p "$(dirname -- "$destination")"
  "$DOTFILES_GIT_CMD" clone --depth 1 "$repository_url" "$destination"
}

install_shell_dependencies() {
  local omz_dir=${ZSH:-$HOME/.oh-my-zsh}
  local custom_dir=${ZSH_CUSTOM:-$omz_dir/custom}
  clone_if_missing "$DOTFILES_OMZ_URL" "$omz_dir"
  clone_if_missing "$DOTFILES_AUTOSUGGESTIONS_URL" \
    "$custom_dir/plugins/zsh-autosuggestions"
  clone_if_missing "$DOTFILES_SYNTAX_HIGHLIGHTING_URL" \
    "$custom_dir/plugins/zsh-syntax-highlighting"
}

provision_common() {
  install_uv_if_missing
  install_herdr_if_missing
  install_shell_dependencies
}

completion_facades_ready() {
  local completion_dir=$1
  local completion_name
  local facade_target
  [ -L "$completion_dir/.dotfiles-completions-current" ] || return 1
  for completion_name in _herdr _uv _uvx; do
    [ -L "$completion_dir/$completion_name" ] || return 1
    facade_target=$(readlink "$completion_dir/$completion_name")
    [ "$facade_target" = ".dotfiles-completions-current/$completion_name" ] || return 1
  done
}

dotfiles_atomic_replace() {
  local replace_source=$1
  local replace_destination=$2
  case $OSTYPE in
    darwin*) "$DOTFILES_MV_CMD" -fh "$replace_source" "$replace_destination" ;;
    linux*) "$DOTFILES_MV_CMD" -Tf "$replace_source" "$replace_destination" ;;
    *)
      dotfiles_error 'unsupported platform for atomic path replacement'
      return 2
      ;;
  esac
}

cleanup_completion_transaction() {
  transaction_status=$?
  trap - EXIT HUP INT TERM

  if [ "$completion_committed" -ne 1 ]; then
    if [ "$completion_scaffold_started" -eq 1 ]; then
      if [ "$completion_had_pointer" -eq 1 ]; then
        rm -f "$completion_restore_link"
        ln -s "$completion_old_pointer" "$completion_restore_link"
        DOTFILES_MV_CMD=mv dotfiles_atomic_replace \
          "$completion_restore_link" "$completion_pointer"
      else
        rm -f "$completion_pointer"
      fi

      for completion_name in _herdr _uv _uvx; do
        rm -f "$completion_dir/.$completion_name.next.$$"
        rm -f "$completion_dir/$completion_name"
        if [ -e "$completion_backup_dir/.has-$completion_name" ]; then
          mv "$completion_backup_dir/$completion_name" \
            "$completion_dir/$completion_name"
        fi
      done
    fi
    rm -rf "$completion_release_dir"
  fi

  rm -f "$completion_next_link" "$completion_restore_link"
  [ -z "$completion_backup_dir" ] || rm -rf "$completion_backup_dir"
  [ -z "$completion_legacy_dir" ] || rm -rf "$completion_legacy_dir"
  exit "$transaction_status"
}

publish_completion_release() (
  completion_dir=$1
  completion_release_dir=$2
  completion_pointer=$completion_dir/.dotfiles-completions-current
  completion_next_link=$completion_dir/.dotfiles-completions-current.next.$$
  completion_restore_link=$completion_dir/.dotfiles-completions-current.restore.$$
  completion_backup_dir=
  completion_legacy_dir=
  completion_old_pointer=
  completion_had_pointer=0
  completion_scaffold_started=0
  completion_committed=0
  trap cleanup_completion_transaction EXIT
  trap 'exit 1' HUP INT TERM

  if completion_facades_ready "$completion_dir"; then
    completion_old_pointer=$(readlink "$completion_pointer")
  else
    completion_backup_dir=$(mktemp -d "$completion_dir/.dotfiles-completions-backup.XXXXXX")
    completion_legacy_dir=$(mktemp -d "$completion_dir/.dotfiles-completions-legacy.XXXXXX")

    if [ -e "$completion_pointer" ] || [ -L "$completion_pointer" ]; then
      if [ ! -L "$completion_pointer" ]; then
        dotfiles_error "completion pointer is not a symlink: $completion_pointer"
        return 1
      fi
      completion_had_pointer=1
      completion_old_pointer=$(readlink "$completion_pointer")
    fi

    for completion_name in _herdr _uv _uvx; do
      if [ -d "$completion_dir/$completion_name" ] &&
        [ ! -L "$completion_dir/$completion_name" ]
      then
        dotfiles_error "completion path is a directory: $completion_dir/$completion_name"
        return 1
      fi
      if [ -e "$completion_dir/$completion_name" ] ||
        [ -L "$completion_dir/$completion_name" ]
      then
        cp -P "$completion_dir/$completion_name" \
          "$completion_backup_dir/$completion_name"
        : >"$completion_backup_dir/.has-$completion_name"
      fi
      if [ -r "$completion_dir/$completion_name" ]; then
        cp "$completion_dir/$completion_name" "$completion_legacy_dir/$completion_name"
      else
        cp "$completion_release_dir/$completion_name" "$completion_legacy_dir/$completion_name"
      fi
    done

    ln -s "${completion_legacy_dir##*/}" "$completion_next_link"
    dotfiles_atomic_replace "$completion_next_link" "$completion_pointer"
    completion_scaffold_started=1

    for completion_name in _herdr _uv _uvx; do
      completion_facade_next=$completion_dir/.$completion_name.next.$$
      ln -s ".dotfiles-completions-current/$completion_name" \
        "$completion_facade_next"
      dotfiles_atomic_replace "$completion_facade_next" \
        "$completion_dir/$completion_name"
    done
  fi

  rm -f "$completion_next_link"
  ln -s "${completion_release_dir##*/}" "$completion_next_link"
  # Ignore interactive termination only across the atomic pointer swap and
  # commit marker. SIGKILL leaves the published release in place.
  trap '' HUP INT TERM
  if dotfiles_atomic_replace "$completion_next_link" "$completion_pointer"; then
    completion_committed=1
  else
    publication_status=$?
    trap 'exit 1' HUP INT TERM
    return "$publication_status"
  fi
  trap 'exit 1' HUP INT TERM

  case $completion_old_pointer in
    .dotfiles-completions-release.*|.dotfiles-completions-legacy.*)
      rm -rf "$completion_dir/$completion_old_pointer"
      ;;
  esac
)

regenerate_completions() (
  completion_dir=${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions
  mkdir -p "$completion_dir"
  completion_release_dir=$(mktemp -d "$completion_dir/.dotfiles-completions-release.XXXXXX")
  trap 'rm -rf "$completion_release_dir"' HUP INT TERM

  herdr_cmd=$(dotfiles_tool_path herdr)
  uv_cmd=$(dotfiles_tool_path uv)
  uvx_cmd=$(dotfiles_tool_path uvx)
  if ! "$herdr_cmd" completion zsh >"$completion_release_dir/_herdr" ||
    ! "$uv_cmd" generate-shell-completion zsh >"$completion_release_dir/_uv" ||
    ! "$uvx_cmd" --generate-shell-completion zsh >"$completion_release_dir/_uvx"
  then
    rm -rf "$completion_release_dir"
    return 1
  fi

  chmod 0644 "$completion_release_dir/_herdr" \
    "$completion_release_dir/_uv" "$completion_release_dir/_uvx"
  publish_completion_release "$completion_dir" "$completion_release_dir"
)

diagnose_common() {
  local diagnostic_status=0
  local tool_name
  local omz_dir
  local custom_dir
  local dependency_path
  local completion_dir
  local completion_name
  for tool_name in uv uvx herdr; do
    if ! dotfiles_tool_path "$tool_name" >/dev/null 2>&1; then
      dotfiles_error "missing command: $tool_name"
      diagnostic_status=1
    fi
  done

  omz_dir=${ZSH:-$HOME/.oh-my-zsh}
  custom_dir=${ZSH_CUSTOM:-$omz_dir/custom}
  for dependency_path in \
    "$omz_dir/oh-my-zsh.sh" \
    "$custom_dir/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" \
    "$custom_dir/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
  do
    if [ ! -r "$dependency_path" ]; then
      dotfiles_error "missing shell dependency: $dependency_path"
      diagnostic_status=1
    fi
  done

  completion_dir=${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions
  for completion_name in _herdr _uv _uvx; do
    if [ ! -s "$completion_dir/$completion_name" ]; then
      dotfiles_error "missing completion: $completion_dir/$completion_name"
      diagnostic_status=1
    fi
  done
  return "$diagnostic_status"
}

provision_common_main() {
  local action=${1:-provision}
  case $action in
    provision)
      provision_common
      regenerate_completions
      ;;
    diagnose)
      diagnose_common
      ;;
    *)
      dotfiles_error "usage: $0 [provision|diagnose]"
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  provision_common_main "$@"
fi
