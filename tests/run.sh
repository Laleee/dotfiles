#!/usr/bin/env bash

set -eu
set -o pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

bash_files() {
  find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o -type f -name '*.sh' -print | sort
}

run_bash_syntax_checks() {
  while IFS= read -r shell_file; do
    [ -n "$shell_file" ] || continue
    bash -n "$shell_file"
  done < <(bash_files)
}

run_zsh_syntax_checks() {
  if ! command -v zsh >/dev/null 2>&1; then
    printf '%s\n' 'dotfiles tests require zsh for completion discovery' >&2
    return 1
  fi
  zsh -n "$REPO_ROOT/zsh/.zshrc"
}

run_shellcheck() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '%s\n' 'skip - ShellCheck is not installed' >&2
    return 0
  fi
  while IFS= read -r shell_file; do
    [ -n "$shell_file" ] || continue
    shellcheck --shell=bash "$shell_file"
  done < <(bash_files)
}

run_bash_syntax_checks
run_zsh_syntax_checks
run_shellcheck
bash "$REPO_ROOT/tests/provision_test.sh"
bash "$REPO_ROOT/tests/bootstrap_test.sh"
printf '%s\n' 'ok - portable test runner'
