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

dotfiles_data_home() {
  case ${XDG_DATA_HOME:-} in
    /*) printf '%s\n' "$XDG_DATA_HOME" ;;
    *) printf '%s\n' "$HOME/.local/share" ;;
  esac
}

dotfiles_neovim_version_is_supported() {
  local version=$1
  local major
  local minor
  local patch
  local remainder
  case $version in
    *.*.*) ;;
    *) return 1 ;;
  esac
  major=${version%%.*}
  remainder=${version#*.}
  minor=${remainder%%.*}
  patch=${remainder#*.}
  case $patch in
    *.*) return 1 ;;
  esac
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] || return 1
  case $major:$minor:$patch in
    *[!0-9:]*) return 1 ;;
  esac
  if [ "$major" -gt 0 ] || [ "$minor" -gt 11 ]; then
    return 0
  fi
  [ "$major" -eq 0 ] && [ "$minor" -eq 11 ] && [ "$patch" -ge 2 ]
}

diagnose_neovim_version() {
  local nvim_cmd
  local nvim_output
  local version_line
  local version
  if ! nvim_cmd=$(dotfiles_tool_path nvim 2>/dev/null); then
    dotfiles_error 'missing command: nvim; install Neovim 0.11.2 or newer manually'
    return 1
  fi
  if ! nvim_output=$("$nvim_cmd" --version 2>/dev/null); then
    dotfiles_error "Neovim command is unusable: $nvim_cmd"
    return 1
  fi
  version_line=$(printf '%s\n' "$nvim_output" | sed -n '1p')
  case $version_line in
    'NVIM v'*) version=${version_line#NVIM v} ;;
    *)
      dotfiles_error "cannot determine Neovim version from: $nvim_cmd"
      return 1
      ;;
  esac
  version=${version%%-*}
  if ! dotfiles_neovim_version_is_supported "$version"; then
    dotfiles_error \
      "Neovim $version is below required 0.11.2; update Neovim manually (bootstrap does not upgrade existing installations)"
    return 1
  fi
}

diagnose_tree_sitter_cli() {
  local guidance=$1
  if ! dotfiles_tool_path tree-sitter >/dev/null 2>&1; then
    dotfiles_error "missing command: tree-sitter; $guidance"
    return 1
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

cleanup_completion_publication() {
  publication_status=$?
  trap - EXIT HUP INT TERM
  if [ "$completion_committed" -ne 1 ]; then
    rm -rf "$completion_release_dir"
  fi
  rm -f "$completion_next_link"
  exit "$publication_status"
}

publish_completion_release() (
  completion_dir=$1
  completion_release_dir=$2
  completion_pointer=$completion_dir/.dotfiles-completions-current
  completion_next_link=$completion_dir/.dotfiles-completions-current.next.$$
  completion_old_pointer=
  completion_committed=0
  trap cleanup_completion_publication EXIT
  trap 'exit 1' HUP INT TERM

  if [ -e "$completion_pointer" ] || [ -L "$completion_pointer" ]; then
    if [ ! -L "$completion_pointer" ]; then
      dotfiles_error "completion pointer is not a symlink: $completion_pointer"
      return 1
    fi
    completion_old_pointer=$(readlink "$completion_pointer")
  fi

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
    .dotfiles-completions-release.*)
      case $completion_old_pointer in
        */*) ;;
        *) rm -rf -- "${completion_dir:?}/${completion_old_pointer:?}" ;;
      esac
      ;;
  esac
)

regenerate_completions() (
  completion_dir=$(dotfiles_data_home)/zsh/site-functions
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
  local data_home
  local completion_dir
  local completion_name
  if ! diagnose_neovim_version; then
    diagnostic_status=1
  fi
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

  data_home=$(dotfiles_data_home)
  completion_dir=$data_home/zsh/site-functions/.dotfiles-completions-current
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
