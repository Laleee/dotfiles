#!/usr/bin/env bash

set -eu
set -o pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-test.XXXXXX")
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT HUP INT TERM

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_equals() {
  expected=$1
  actual=$2
  message=$3
  [ "$expected" = "$actual" ] ||
    fail "$message (expected '$expected', got '$actual')"
}

test_tree_aliases_and_graph_palette() {
  home="$TEST_TMP_ROOT/alias-home"
  repository="$TEST_TMP_ROOT/repository"
  mkdir -p "$home/.config/git" "$repository"
  ln -s "$REPO_ROOT/git/.config/git/config" "$home/.config/git/config"
  git -C "$repository" init -q
  git -C "$repository" -c user.name='Test User' -c user.email=test@example.test \
    commit --allow-empty -q -m 'initial commit'

  tree_output=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    git -C "$repository" tree --color=never)
  gt_output=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    git -C "$repository" gt --color=never)
  palette=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    git config --global --get log.graphColors)

  assert_equals "$tree_output" "$gt_output" 'git gt did not delegate to git tree'
  case $tree_output in
    *'initial commit'*'<Test User>'*) : ;;
    *) fail 'git tree did not render the requested commit format' ;;
  esac
  assert_equals \
    '#7aa2f7,#bb9af7,#7dcfff,#9ece6a,#e0af68,#f7768e,#ff9e64' \
    "$palette" 'Git graph palette is wrong'
}

test_xdg_config_complements_base_and_local_config() {
  home="$TEST_TMP_ROOT/home"
  repository="$TEST_TMP_ROOT/layered-repository"
  mkdir -p "$home/.config/git" "$repository"
  ln -s "$REPO_ROOT/git/.config/git/config" "$home/.config/git/config"
  git config --file "$home/.gitconfig" user.name 'Base User'
  git config --file "$home/.gitconfig" user.email base@example.test
  git config --file "$home/.gitconfig" log.graphColors red

  git -C "$repository" init -q
  git -C "$repository" config user.name 'Local User'
  git -C "$repository" config user.email local@example.test
  HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    git -C "$repository" commit --allow-empty -q -m 'layered config'

  tree_output=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    git -C "$repository" tree --color=never)
  palette=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    git config --global --get log.graphColors)
  identity=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    git -C "$repository" config --get user.name)

  case $tree_output in
    *'layered config'*'<Local User>'*) : ;;
    *) fail 'XDG alias did not preserve repository-local identity' ;;
  esac
  assert_equals red "$palette" 'base Git config did not override the XDG palette'
  assert_equals 'Local User' "$identity" 'XDG config overrode local identity'
}

test_tree_aliases_and_graph_palette
test_xdg_config_complements_base_and_local_config
printf 'ok - Git configuration\n'
