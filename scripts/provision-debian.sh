#!/usr/bin/env bash

set -eu
set -o pipefail

DOTFILES_DEBIAN_SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/provision-common.sh
. "$DOTFILES_DEBIAN_SCRIPT_DIR/provision-common.sh"

DOTFILES_APT_GET_CMD=${DOTFILES_APT_GET_CMD:-apt-get}
DOTFILES_DPKG_QUERY_CMD=${DOTFILES_DPKG_QUERY_CMD:-dpkg-query}
DOTFILES_SUDO_CMD=${DOTFILES_SUDO_CMD-sudo}
DOTFILES_ID_CMD=${DOTFILES_ID_CMD:-id}
DOTFILES_UNAME_CMD=${DOTFILES_UNAME_CMD:-uname}
DOTFILES_TAR_CMD=${DOTFILES_TAR_CMD:-tar}
DOTFILES_NPM_CMD=${DOTFILES_NPM_CMD:-npm}
DOTFILES_OS_RELEASE_FILE=${DOTFILES_OS_RELEASE_FILE:-/etc/os-release}
DOTFILES_NEOVIM_RELEASE_BASE_URL=${DOTFILES_NEOVIM_RELEASE_BASE_URL:-https://github.com/neovim/neovim/releases/download/stable}
DOTFILES_APT_PACKAGES='ca-certificates curl git stow zsh fzf zoxide fd-find ripgrep nodejs npm build-essential graphviz shellcheck tar xz-utils'

require_debian_family() {
  local distribution_id
  local distribution_like
  if [ ! -r "$DOTFILES_OS_RELEASE_FILE" ]; then
    dotfiles_error "cannot identify Linux distribution: $DOTFILES_OS_RELEASE_FILE is missing"
    return 2
  fi

  distribution_id=$(sed -n 's/^ID=//p' "$DOTFILES_OS_RELEASE_FILE" | tr -d '"' | head -n 1)
  distribution_like=$(sed -n 's/^ID_LIKE=//p' "$DOTFILES_OS_RELEASE_FILE" | tr -d '"' | head -n 1)
  case " $distribution_id $distribution_like " in
    *' debian '*|*' ubuntu '*) return 0 ;;
    *)
      dotfiles_error "unsupported Linux distribution: ${distribution_id:-unknown}"
      return 2
      ;;
  esac
}

dotfiles_run_as_root() {
  local effective_uid
  effective_uid=$("$DOTFILES_ID_CMD" -u)
  if [ "$effective_uid" = 0 ] || [ -z "$DOTFILES_SUDO_CMD" ]; then
    DEBIAN_FRONTEND=noninteractive "$@"
  else
    "$DOTFILES_SUDO_CMD" env DEBIAN_FRONTEND=noninteractive "$@"
  fi
}

provision_debian_packages() {
  dotfiles_run_as_root "$DOTFILES_APT_GET_CMD" update
  # Word splitting is intentional: the constant is a portable Bash 3.2 list.
  # shellcheck disable=SC2086
  dotfiles_run_as_root "$DOTFILES_APT_GET_CMD" install -y \
    --no-install-recommends --no-upgrade $DOTFILES_APT_PACKAGES
}

neovim_archive_name() {
  local machine_architecture
  machine_architecture=$("$DOTFILES_UNAME_CMD" -m)
  case $machine_architecture in
    x86_64|amd64) printf '%s\n' nvim-linux-x86_64.tar.gz ;;
    arm64|aarch64) printf '%s\n' nvim-linux-arm64.tar.gz ;;
    *)
      dotfiles_error "unsupported Linux architecture: $machine_architecture"
      return 2
      ;;
  esac
}

neovim_archive_url() {
  printf '%s/%s\n' "$DOTFILES_NEOVIM_RELEASE_BASE_URL" "$(neovim_archive_name)"
}

install_neovim_archive() (
  install_dir=$HOME/.local/opt/nvim
  if [ -x "$install_dir/bin/nvim" ]; then
    return 0
  fi
  if [ -e "$install_dir" ]; then
    dotfiles_error "refusing to replace existing incomplete Neovim path: $install_dir"
    return 1
  fi

  archive_name=$(neovim_archive_name)
  archive_root=${archive_name%.tar.gz}
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-neovim.XXXXXX")
  trap 'rm -rf "$temp_dir"' EXIT HUP INT TERM
  archive_path=$temp_dir/$archive_name

  "$DOTFILES_CURL_CMD" -fsSL -o "$archive_path" \
    "$DOTFILES_NEOVIM_RELEASE_BASE_URL/$archive_name"
  "$DOTFILES_TAR_CMD" -xzf "$archive_path" -C "$temp_dir"
  if [ ! -x "$temp_dir/$archive_root/bin/nvim" ]; then
    dotfiles_error 'downloaded Neovim archive does not contain bin/nvim'
    return 1
  fi

  mkdir -p "$HOME/.local/opt"
  mv "$temp_dir/$archive_root" "$install_dir"
)

ensure_nvim_link() {
  local nvim_source=$HOME/.local/opt/nvim/bin/nvim
  local nvim_link=$HOME/.local/bin/nvim
  if [ ! -x "$nvim_source" ]; then
    dotfiles_error "managed Neovim executable is missing: $nvim_source"
    return 1
  fi
  if [ -e "$nvim_link" ] || [ -L "$nvim_link" ]; then
    return 0
  fi
  mkdir -p "$HOME/.local/bin"
  ln -s "$nvim_source" "$nvim_link"
}

ensure_fd_link() {
  local fd_link=$HOME/.local/bin/fd
  local fdfind_path
  if [ -e "$fd_link" ] || [ -L "$fd_link" ]; then
    return 0
  fi
  if ! fdfind_path=$(command -v fdfind); then
    dotfiles_error 'fd-find is installed but fdfind is unavailable'
    return 1
  fi
  mkdir -p "$HOME/.local/bin"
  ln -s "$fdfind_path" "$fd_link"
}

install_tree_sitter_cli_if_missing() {
  if dotfiles_tool_path tree-sitter >/dev/null 2>&1; then
    diagnose_tree_sitter_cli \
      'refusing to replace the existing installation'
    return $?
  fi
  "$DOTFILES_NPM_CMD" install --global --prefix "$HOME/.local" tree-sitter-cli
  diagnose_tree_sitter_cli \
    'npm did not publish a usable Tree-sitter CLI under ~/.local/bin'
}

provision_debian() {
  require_debian_family
  provision_debian_packages
  install_neovim_archive
  ensure_nvim_link
  ensure_fd_link
  install_tree_sitter_cli_if_missing
  provision_common
  regenerate_completions
}

diagnose_debian_packages() {
  local package_status=0
  local package_name
  for package_name in $DOTFILES_APT_PACKAGES; do
    if ! "$DOTFILES_DPKG_QUERY_CMD" -W -f="\${Status}\\n" "$package_name" 2>/dev/null |
      grep -q '^install ok installed$'
    then
      dotfiles_error "missing apt package: $package_name"
      package_status=1
    fi
  done
  return "$package_status"
}

diagnose_debian() {
  local diagnostic_status=0
  if ! require_debian_family; then
    diagnostic_status=1
  fi
  if ! diagnose_debian_packages; then
    diagnostic_status=1
  fi
  if [ ! -x "$HOME/.local/opt/nvim/bin/nvim" ]; then
    dotfiles_error 'missing managed Neovim installation'
    diagnostic_status=1
  fi
  if [ ! -x "$HOME/.local/bin/fd" ]; then
    dotfiles_error 'missing fd compatibility command'
    diagnostic_status=1
  fi
  if ! diagnose_tree_sitter_cli \
    "run npm install --global --prefix $HOME/.local tree-sitter-cli"
  then
    diagnostic_status=1
  fi
  if ! diagnose_common; then
    diagnostic_status=1
  fi
  return "$diagnostic_status"
}

provision_debian_main() {
  local action=${1:-provision}
  case $action in
    provision) provision_debian ;;
    diagnose) diagnose_debian ;;
    *)
      dotfiles_error "usage: $0 [provision|diagnose]"
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  provision_debian_main "$@"
fi
