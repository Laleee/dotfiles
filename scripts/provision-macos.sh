#!/usr/bin/env bash

set -eu
set -o pipefail

DOTFILES_MACOS_SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/provision-common.sh
. "$DOTFILES_MACOS_SCRIPT_DIR/provision-common.sh"

DOTFILES_BREW_CMD=${DOTFILES_BREW_CMD:-brew}
DOTFILES_BREWFILE=${DOTFILES_BREWFILE:-$DOTFILES_MACOS_SCRIPT_DIR/../Brewfile}

require_homebrew() {
  if ! command -v "$DOTFILES_BREW_CMD" >/dev/null 2>&1 && [ ! -x "$DOTFILES_BREW_CMD" ]; then
    dotfiles_error 'Homebrew is required; install it before provisioning macOS'
    return 1
  fi
}

provision_macos_packages() {
  require_homebrew
  HOMEBREW_NO_AUTO_UPDATE=1 "$DOTFILES_BREW_CMD" bundle \
    --file="$DOTFILES_BREWFILE" --no-upgrade
}

provision_macos() {
  provision_macos_packages
  provision_common
  regenerate_completions
}

diagnose_brewfile_formulas() {
  local diagnostic_status=0
  local formula

  if [ ! -r "$DOTFILES_BREWFILE" ]; then
    dotfiles_error "Brewfile is not readable: $DOTFILES_BREWFILE"
    return 1
  fi

  while IFS= read -r formula; do
    if ! "$DOTFILES_BREW_CMD" list --versions "$formula" >/dev/null 2>&1; then
      dotfiles_error "missing Brewfile formula: $formula"
      diagnostic_status=1
    fi
  done < <(sed -n 's/^[[:space:]]*brew[[:space:]]*"\([^"]*\)".*/\1/p' "$DOTFILES_BREWFILE")

  return "$diagnostic_status"
}

diagnose_macos() {
  local diagnostic_status=0
  if ! require_homebrew; then
    diagnostic_status=1
  elif ! diagnose_brewfile_formulas; then
    diagnostic_status=1
  fi
  if ! diagnose_common; then
    diagnostic_status=1
  fi
  return "$diagnostic_status"
}

provision_macos_main() {
  local action=${1:-provision}
  case $action in
    provision) provision_macos ;;
    diagnose) diagnose_macos ;;
    *)
      dotfiles_error "usage: $0 [provision|diagnose]"
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  provision_macos_main "$@"
fi
