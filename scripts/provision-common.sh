#!/usr/bin/env bash

set -eu
set -o pipefail

DOTFILES_CURL_CMD=${DOTFILES_CURL_CMD:-curl}
DOTFILES_GIT_CMD=${DOTFILES_GIT_CMD:-git}
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
  if command -v uv >/dev/null 2>&1 || [ -x "$HOME/.local/bin/uv" ]; then
    return 0
  fi
  install_remote_script "$DOTFILES_UV_INSTALL_URL" uv-install.sh env UV_NO_MODIFY_PATH=1
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

regenerate_completions() (
  completion_dir=${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions
  mkdir -p "$completion_dir"
  stage_dir=$(mktemp -d "$completion_dir/.dotfiles-completions.XXXXXX")
  trap 'rm -rf "$stage_dir"' EXIT HUP INT TERM

  herdr_cmd=$(dotfiles_tool_path herdr)
  uv_cmd=$(dotfiles_tool_path uv)
  uvx_cmd=$(dotfiles_tool_path uvx)
  "$herdr_cmd" completion zsh >"$stage_dir/_herdr"
  "$uv_cmd" generate-shell-completion zsh >"$stage_dir/_uv"
  "$uvx_cmd" --generate-shell-completion zsh >"$stage_dir/_uvx"

  chmod 0644 "$stage_dir/_herdr" "$stage_dir/_uv" "$stage_dir/_uvx"
  mv "$stage_dir/_herdr" "$completion_dir/_herdr"
  mv "$stage_dir/_uv" "$completion_dir/_uv"
  mv "$stage_dir/_uvx" "$completion_dir/_uvx"
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
