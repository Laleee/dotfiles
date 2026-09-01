#!/usr/bin/env bash

set -eu
set -o pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

bash_files() {
  printf '%s\n' "$REPO_ROOT/bootstrap.sh"
  printf '%s\n' "$REPO_ROOT/setup.sh"
  find "$REPO_ROOT/scripts" "$REPO_ROOT/tests" -type f -name '*.sh' -print | sort
}

zsh_files() {
  printf '%s\n' \
    "$REPO_ROOT/zsh/.zshrc" \
    "$REPO_ROOT/zsh/.zprofile"
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
  while IFS= read -r shell_file; do
    [ -n "$shell_file" ] || continue
    zsh -n "$shell_file"
  done < <(zsh_files)
}

run_shellcheck() {
  # ShellCheck supports sh/bash/dash/ksh, but not Zsh. Zsh files stay under
  # zsh -n above so their syntax is checked by the correct interpreter.
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '%s\n' 'skip - ShellCheck is not installed' >&2
  else
    (
      cd "$REPO_ROOT"
      while IFS= read -r shell_file; do
        [ -n "$shell_file" ] || continue
        shellcheck -x --shell=bash "$shell_file"
      done < <(bash_files)
    )
  fi
  printf '%s\n' 'note - ShellCheck does not support Zsh; zsh -n validates Zsh configs'
}

run_bash_syntax_checks
run_zsh_syntax_checks
run_shellcheck
bash "$REPO_ROOT/tests/provision_test.sh"
bash "$REPO_ROOT/tests/bootstrap_test.sh"
bash "$REPO_ROOT/tests/setup_test.sh"
bash "$REPO_ROOT/tests/git_test.sh"
printf '%s\n' 'ok - portable test runner'
