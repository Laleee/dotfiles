#!/usr/bin/env bash

set -eu
set -o pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-provision-test.XXXXXX")
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT HUP INT TERM

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  file=$1
  expected=$2
  grep -F -- "$expected" "$file" >/dev/null 2>&1 ||
    fail "$file does not contain: $expected"
}

assert_equals() {
  expected=$1
  actual=$2
  message=$3
  [ "$expected" = "$actual" ] ||
    fail "$message (expected '$expected', got '$actual')"
}

make_fake_user_tools() {
  fake_bin=$1
  mkdir -p "$fake_bin"

  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
set -eu
output=
url=
while [ "$#" -gt 0 ]; do
  case $1 in
    -o|--output) output=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
[ -n "$output" ]
case $url in
  *uv*) tool=uv ;;
  *herdr*) tool=herdr ;;
  *starship*) tool=starship ;;
  *) exit 64 ;;
esac
cat >"$output" <<INSTALLER
#!/bin/sh
set -eu
tool=$tool
marker="\$HOME/.\${tool}-installer-ran"
[ ! -e "\$marker" ] || exit 91
: >"\$marker"
mkdir -p "\$HOME/.local/bin"
if [ "\$tool" = uv ]; then
  printf '%s\n' "\${UV_NO_MODIFY_PATH:-unset}" >"\$HOME/.uv-no-modify-path"
  cat >"\$HOME/.local/bin/uv" <<'TOOL'
#!/bin/sh
[ "\$1 \$2" = "generate-shell-completion zsh" ] || exit 64
printf '#compdef uv\nuv completion\n'
TOOL
  cat >"\$HOME/.local/bin/uvx" <<'TOOL'
#!/bin/sh
[ "\$1 \$2" = "--generate-shell-completion zsh" ] || exit 64
printf '#compdef uvx\nuvx completion\n'
TOOL
  chmod +x "\$HOME/.local/bin/uv" "\$HOME/.local/bin/uvx"
elif [ "\$tool" = herdr ]; then
  cat >"\$HOME/.local/bin/herdr" <<'TOOL'
#!/bin/sh
[ "\$1 \$2" = "completion zsh" ] || exit 64
printf '#compdef herdr\nherdr completion\n'
TOOL
  chmod +x "\$HOME/.local/bin/herdr"
else
  [ "\$1" = --yes ] || exit 64
  [ "\$2" = --bin-dir ] || exit 64
  [ "\$3" = "\$HOME/.local/bin" ] || exit 64
  cat >"\$HOME/.local/bin/starship" <<'TOOL'
#!/bin/sh
printf 'starship 1.26.0\n'
TOOL
  chmod +x "\$HOME/.local/bin/starship"
fi
INSTALLER
EOF

  chmod +x "$fake_bin/curl"
}

test_common_provisioning_is_idempotent_and_regenerates_completions() {
  home="$TEST_TMP_ROOT/common-home"
  fake_bin="$TEST_TMP_ROOT/common-bin"
  mkdir -p "$home"
  make_fake_user_tools "$fake_bin"

  HOME="$home" PATH="$fake_bin:/usr/bin:/bin" \
    DOTFILES_UV_INSTALL_URL=https://example.test/uv \
    DOTFILES_HERDR_INSTALL_URL=https://example.test/herdr \
    bash "$REPO_ROOT/scripts/provision-common.sh"

  assert_equals 1 "$(cat "$home/.uv-no-modify-path")" \
    'uv installer must be prevented from editing profiles'
  [ ! -e "$home/.oh-my-zsh" ] || fail 'common provisioning unexpectedly cloned Oh My Zsh'

  completion_root="$home/.local/share/zsh/site-functions"
  completion_dir="$completion_root/.dotfiles-completions-current"
  assert_file_contains "$completion_dir/_herdr" 'herdr completion'
  assert_file_contains "$completion_dir/_uv" 'uv completion'
  assert_file_contains "$completion_dir/_uvx" 'uvx completion'

  printf 'stale\n' >"$completion_dir/_uv"
  HOME="$home" PATH="$fake_bin:/usr/bin:/bin" \
    DOTFILES_UV_INSTALL_URL=https://example.test/uv \
    DOTFILES_HERDR_INSTALL_URL=https://example.test/herdr \
    bash "$REPO_ROOT/scripts/provision-common.sh"
  assert_file_contains "$completion_dir/_uv" 'uv completion'
}

test_common_provisioning_does_not_clone_omz_or_plugins() {
  home="$TEST_TMP_ROOT/no-omz-home"
  bin="$TEST_TMP_ROOT/no-omz-bin"
  mkdir -p "$home" "$bin"
  cat >"$bin/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$DOTFILES_TEST_GIT_CALLS"
exit 99
EOF
  chmod +x "$bin/git"
  set +e
  HOME="$home" PATH="$bin:/usr/bin:/bin" DOTFILES_TEST_GIT_CALLS="$TEST_TMP_ROOT/git-calls" \
    bash -c '
      . "$1/scripts/provision-common.sh"
      install_uv_if_missing() { :; }
      install_herdr_if_missing() { :; }
      install_starship_if_missing() { :; }
      regenerate_completions() { :; }
      provision_common
    ' shell "$REPO_ROOT"
  status=$?
  set -e
  assert_equals 0 "$status" 'shell dependency provisioning failed without package manager paths'
  [ ! -e "$TEST_TMP_ROOT/git-calls" ] || fail 'shell dependency provisioning invoked git clone'
  [ ! -e "$home/.oh-my-zsh" ] || fail 'shell dependency provisioning created an OMZ directory'
}

test_brewfile_and_debian_packages_include_zsh_plugins() {
  assert_file_contains "$REPO_ROOT/Brewfile" 'brew "zsh-autosuggestions"'
  assert_file_contains "$REPO_ROOT/Brewfile" 'brew "zsh-syntax-highlighting"'
  assert_file_contains "$REPO_ROOT/scripts/provision-debian.sh" 'zsh-autosuggestions'
  assert_file_contains "$REPO_ROOT/scripts/provision-debian.sh" 'zsh-syntax-highlighting'
}

test_relative_xdg_data_home_publishes_completions_inside_home() {
  home="$TEST_TMP_ROOT/relative-data-home"
  work="$TEST_TMP_ROOT/relative-data-work"
  bin="$TEST_TMP_ROOT/relative-data-bin"
  completion_dir="$home/.local/share/zsh/site-functions/.dotfiles-completions-current"
  mkdir -p "$home" "$work" "$bin"

  for tool_name in herdr uv uvx; do
    cat >"$bin/$tool_name" <<'EOF'
#!/bin/sh
printf '%s completion\n' "${0##*/}"
EOF
    chmod +x "$bin/$tool_name"
  done

  (
    cd "$work"
    HOME="$home" XDG_DATA_HOME=relative-data PATH="$bin:/usr/bin:/bin" \
      bash -c '. "$1/scripts/provision-common.sh"; regenerate_completions' \
      shell "$REPO_ROOT"
  )

  assert_equals 'herdr completion' "$(cat "$completion_dir/_herdr")" \
    'relative XDG_DATA_HOME did not fall back to home-local completion storage'
  [ ! -e "$work/relative-data" ] ||
    fail 'relative XDG_DATA_HOME published completions relative to the working directory'
}

test_completion_failure_preserves_existing_set() {
  home="$TEST_TMP_ROOT/atomic-home"
  bin="$TEST_TMP_ROOT/atomic-bin"
  completion_root="$home/.local/share/zsh/site-functions"
  old_release="$completion_root/.dotfiles-completions-release.old"
  completion_dir="$completion_root/.dotfiles-completions-current"
  mkdir -p "$bin" "$old_release"
  printf 'old herdr\n' >"$old_release/_herdr"
  printf 'old uv\n' >"$old_release/_uv"
  printf 'old uvx\n' >"$old_release/_uvx"
  ln -s "${old_release##*/}" "$completion_dir"

  cat >"$bin/herdr" <<'EOF'
#!/bin/sh
printf 'new herdr\n'
EOF
  cat >"$bin/uv" <<'EOF'
#!/bin/sh
exit 7
EOF
  cat >"$bin/uvx" <<'EOF'
#!/bin/sh
printf 'new uvx\n'
EOF
  chmod +x "$bin/herdr" "$bin/uv" "$bin/uvx"

  set +e
  HOME="$home" PATH="$bin:/usr/bin:/bin" bash -c \
    '. "$1/scripts/provision-common.sh"; regenerate_completions' shell "$REPO_ROOT"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'completion generation unexpectedly succeeded'
  [ -z "$(find "$completion_root" -maxdepth 1 -type d -name '.dotfiles-completions-release.*' ! -name '.dotfiles-completions-release.old' -print -quit)" ] ||
    fail 'failed completion generation left its staging directory behind'
  assert_equals 'old herdr' "$(cat "$completion_dir/_herdr")" \
    'Herdr completion changed after a later generator failed'
  assert_equals 'old uv' "$(cat "$completion_dir/_uv")" \
    'UV completion changed after generation failed'
  assert_equals 'old uvx' "$(cat "$completion_dir/_uvx")" \
    'UVX completion changed after generation failed'
}

test_completion_publication_failure_preserves_existing_set() {
  home="$TEST_TMP_ROOT/publication-home"
  bin="$TEST_TMP_ROOT/publication-bin"
  completion_root="$home/.local/share/zsh/site-functions"
  completion_dir="$completion_root/.dotfiles-completions-current"
  mv_count="$TEST_TMP_ROOT/publication-mv-count"
  mkdir -p "$bin" "$completion_root"

  cat >"$bin/herdr" <<'EOF'
#!/bin/sh
printf '%s herdr\n' "$COMPLETION_VERSION"
EOF
  cat >"$bin/uv" <<'EOF'
#!/bin/sh
printf '%s uv\n' "$COMPLETION_VERSION"
EOF
  cat >"$bin/uvx" <<'EOF'
#!/bin/sh
printf '%s uvx\n' "$COMPLETION_VERSION"
EOF
  cat >"$bin/failing-mv" <<'EOF'
#!/bin/sh
set -eu
count=0
if [ -r "$DOTFILES_TEST_MV_COUNT" ]; then
  count=$(cat "$DOTFILES_TEST_MV_COUNT")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$DOTFILES_TEST_MV_COUNT"
if [ "$count" -eq 1 ]; then
  exit 73
fi
exec /bin/mv "$@"
EOF
  chmod +x "$bin/herdr" "$bin/uv" "$bin/uvx" "$bin/failing-mv"

  HOME="$home" PATH="$bin:/usr/bin:/bin" COMPLETION_VERSION=old \
    bash -c '. "$1/scripts/provision-common.sh"; regenerate_completions' shell "$REPO_ROOT"
  assert_equals 'old herdr' "$(cat "$completion_dir/_herdr")" 'initial Herdr completion is wrong'
  assert_equals 'old uv' "$(cat "$completion_dir/_uv")" 'initial UV completion is wrong'
  assert_equals 'old uvx' "$(cat "$completion_dir/_uvx")" 'initial UVX completion is wrong'

  set +e
  HOME="$home" PATH="$bin:/usr/bin:/bin" COMPLETION_VERSION=new \
    DOTFILES_MV_CMD="$bin/failing-mv" DOTFILES_TEST_MV_COUNT="$mv_count" \
    bash -c '. "$1/scripts/provision-common.sh"; regenerate_completions' shell "$REPO_ROOT"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'completion replacement unexpectedly succeeded'
  assert_equals 'old herdr' "$(cat "$completion_dir/_herdr")" \
    'Herdr completion changed after publication failed'
  assert_equals 'old uv' "$(cat "$completion_dir/_uv")" \
    'UV completion changed after publication failed'
  assert_equals 'old uvx' "$(cat "$completion_dir/_uvx")" \
    'UVX completion changed after publication failed'

  HOME="$home" PATH="$bin:/usr/bin:/bin" COMPLETION_VERSION=new \
    bash -c '. "$1/scripts/provision-common.sh"; regenerate_completions' shell "$REPO_ROOT"
  assert_equals 'new herdr' "$(cat "$completion_dir/_herdr")" 'Herdr completion was not published'
  assert_equals 'new uv' "$(cat "$completion_dir/_uv")" 'UV completion was not published'
  assert_equals 'new uvx' "$(cat "$completion_dir/_uvx")" 'UVX completion was not published'
  [ -L "$completion_dir" ] || fail 'atomic completion directory pointer is missing'
  release_count=$(find "$completion_root" -maxdepth 1 -type d \
    -name '.dotfiles-completions-release.*' | wc -l | tr -d ' ')
  assert_equals 1 "$release_count" \
    'successful completion publication did not remove the prior generated release'
}

test_completion_cleanup_rejects_traversal_pointer_targets() {
  home="$TEST_TMP_ROOT/completion-containment-home"
  bin="$TEST_TMP_ROOT/completion-containment-bin"
  completion_root="$home/.local/share/zsh/site-functions"
  completion_pointer="$completion_root/.dotfiles-completions-current"
  traversal_release="$completion_root/.dotfiles-completions-release.traversal"
  victim="$home/.local/share/zsh/victim"
  mkdir -p "$bin" "$traversal_release" "${victim%/*}"
  printf 'must survive\n' >"$victim"
  ln -s '.dotfiles-completions-release.traversal/../../victim' "$completion_pointer"

  cat >"$bin/herdr" <<'EOF'
#!/bin/sh
printf 'new herdr\n'
EOF
  cat >"$bin/uv" <<'EOF'
#!/bin/sh
printf 'new uv\n'
EOF
  cat >"$bin/uvx" <<'EOF'
#!/bin/sh
printf 'new uvx\n'
EOF
  chmod +x "$bin/herdr" "$bin/uv" "$bin/uvx"

  HOME="$home" PATH="$bin:/usr/bin:/bin" bash -c \
    '. "$1/scripts/provision-common.sh"; regenerate_completions' shell "$REPO_ROOT"

  assert_equals 'must survive' "$(cat "$victim")" \
    'completion cleanup removed a victim outside the generated release directory'
  assert_equals 'new herdr' "$(cat "$completion_pointer/_herdr")" \
    'completion publication did not replace the traversal pointer'
}

test_first_completion_publication_has_one_atomic_entry() {
  home="$TEST_TMP_ROOT/first-publication-home"
  bin="$TEST_TMP_ROOT/first-publication-bin"
  completion_dir="$home/.local/share/zsh/site-functions"
  mv_count="$TEST_TMP_ROOT/first-publication-mv-count"
  mkdir -p "$bin" "$completion_dir"

  cat >"$bin/herdr" <<'EOF'
#!/bin/sh
printf 'first herdr\n'
EOF
  cat >"$bin/uv" <<'EOF'
#!/bin/sh
printf 'first uv\n'
EOF
  cat >"$bin/uvx" <<'EOF'
#!/bin/sh
printf 'first uvx\n'
EOF
  cat >"$bin/killing-mv" <<'EOF'
#!/bin/sh
set -eu
count=0
if [ -r "$DOTFILES_TEST_MV_COUNT" ]; then
  count=$(cat "$DOTFILES_TEST_MV_COUNT")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$DOTFILES_TEST_MV_COUNT"
/bin/mv "$@"
if [ "$count" -eq 1 ]; then
  kill -KILL "$PPID"
fi
EOF
  chmod +x "$bin/herdr" "$bin/uv" "$bin/uvx" "$bin/killing-mv"

  set +e
  HOME="$home" PATH="$bin:/usr/bin:/bin" \
    DOTFILES_MV_CMD="$bin/killing-mv" DOTFILES_TEST_MV_COUNT="$mv_count" \
    bash -c '. "$1/scripts/provision-common.sh"; regenerate_completions' shell "$REPO_ROOT" \
    >/dev/null 2>&1
  publication_status=$?
  set -e

  assert_equals 137 "$publication_status" \
    'first publication was not terminated by SIGKILL after publication'
  assert_equals 1 "$(cat "$mv_count")" \
    'first completion publication used more than one rename'
  top_level_count=$(find "$completion_dir" -maxdepth 1 \
    \( -name _herdr -o -name _uv -o -name _uvx \) | wc -l | tr -d ' ')
  assert_equals 0 "$top_level_count" \
    'interrupted first publication exposed a partial top-level completion set'
  [ -L "$completion_dir/.dotfiles-completions-current" ] ||
    fail 'interrupted first publication did not preserve the published pointer'
  for completion_name in _herdr _uv _uvx; do
    [ -s "$completion_dir/.dotfiles-completions-current/$completion_name" ] ||
      fail "published completion directory is incomplete: $completion_name"
  done
}

test_zsh_uses_atomic_completion_directory() {
  home="$TEST_TMP_ROOT/zsh-fpath-home"
  mkdir -p "$home"
  set +e
  HOME="$home" XDG_DATA_HOME="$home/.local/share" zsh -dfc \
    'source "$1"; [[ ${fpath[1]} == "$XDG_DATA_HOME/zsh/site-functions/.dotfiles-completions-current" ]]' \
    zsh "$REPO_ROOT/zsh/.zshrc"
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail 'Zsh fpath does not use the atomic completion directory'
}

test_zsh_falls_back_from_relative_xdg_data_home() {
  home="$TEST_TMP_ROOT/zsh-relative-data-home"
  mkdir -p "$home"
  set +e
  HOME="$home" XDG_DATA_HOME=relative-data zsh -dfc \
    'source "$1"; [[ ${fpath[1]} == "$HOME/.local/share/zsh/site-functions/.dotfiles-completions-current" ]]' \
    zsh "$REPO_ROOT/zsh/.zshrc"
  status=$?
  set -e
  [ "$status" -eq 0 ] ||
    fail 'Zsh accepted a relative XDG_DATA_HOME for completion discovery'
}

test_zsh_discovers_generated_completions_through_the_atomic_pointer() {
  home="$TEST_TMP_ROOT/zsh-completion-discovery-home"
  completion_root="$home/.local/share/zsh/site-functions"
  release="$completion_root/.dotfiles-completions-release.test"
  pointer="$completion_root/.dotfiles-completions-current"
  mkdir -p "$release"
  cat >"$release/_herdr" <<'EOF'
#compdef herdr
_herdr() { _arguments '*:argument:' }
EOF
  cat >"$release/_uv" <<'EOF'
#compdef uv
_uv() { _arguments '*:argument:' }
EOF
  cat >"$release/_uvx" <<'EOF'
#compdef uvx
_uvx() { _arguments '*:argument:' }
EOF
  ln -s "${release##*/}" "$pointer"

  set +e
  HOME="$home" XDG_DATA_HOME="$home/.local/share" zsh -dfc '
      source "$1"
      autoload -Uz compinit
      compinit -D
      for completion_name in _herdr _uv _uvx; do
        autoload +X "$completion_name" || exit 1
        [[ -n ${functions[$completion_name]} ]] || exit 1
      done
    ' zsh "$REPO_ROOT/zsh/.zshrc"
  status=$?
  set -e
  [ "$status" -eq 0 ] ||
    fail 'Zsh could not discover generated completions through the atomic pointer'
}

test_zsh_defines_the_documented_git_aliases() {
  home="$TEST_TMP_ROOT/zsh-alias-home"
  mkdir -p "$home"
  set +e
  HOME="$home" zsh -dfc '
      source "$1"
      [[ ${aliases[gst]} == "git status" ]] || exit 1
      [[ ${aliases[gt]} == "git tree" ]] || exit 1
      [[ ${aliases[ga]} == "git add" ]] || exit 1
      [[ ${aliases[gl]} == "git pull" ]] || exit 1
      [[ ${aliases[gc]} == "git commit --verbose" ]] || exit 1
      [[ ${aliases[gf]} == "git fetch" ]] || exit 1
      [[ ${aliases[gco]} == "git checkout" ]] || exit 1
      [[ ${aliases[grhh]} == "git reset --hard" ]] || exit 1
      [[ ${aliases[gp]} == "git push" ]] || exit 1
      [[ ${aliases[gd]} == "git diff" ]] || exit 1
    ' zsh "$REPO_ROOT/zsh/.zshrc"
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail 'Zsh Git aliases do not match the documented contract'
}

test_zsh_local_config_can_override_git_aliases() {
  home="$TEST_TMP_ROOT/zsh-local-alias-home"
  mkdir -p "$home"
  cat >"$home/.zshrc.local" <<'EOF'
alias gst='custom status'
alias gt='custom tree'
EOF
  set +e
  HOME="$home" zsh -dfc '
      source "$1"
      [[ ${aliases[gst]} == "custom status" ]] || exit 1
      [[ ${aliases[gt]} == "custom tree" ]] || exit 1
    ' zsh "$REPO_ROOT/zsh/.zshrc"
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail '.zshrc.local could not override repository Git aliases'
}

test_zsh_discovers_completions_after_native_compinit() {
  home="$TEST_TMP_ROOT/zsh-native-compinit-home"
  completion_root="$home/.local/share/zsh/site-functions"
  release="$completion_root/.dotfiles-completions-release.native"
  mkdir -p "$release"
  for name in herdr uv uvx; do
    cat >"$release/_$name" <<EOF
#compdef $name
_$name() { _message '$name generated completion'; }
EOF
  done
  ln -s "${release##*/}" "$completion_root/.dotfiles-completions-current"
  set +e
  HOME="$home" XDG_DATA_HOME="$home/.local/share" zsh -dfc '
      source "$1"
      (( $+functions[_herdr] )) || exit 1
      (( $+functions[_uv] )) || exit 1
      (( $+functions[_uvx] )) || exit 1
    ' zsh "$REPO_ROOT/zsh/.zshrc"
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail 'generated completions were not loaded by native compinit'
}

test_zsh_loads_plugins_in_required_order_from_homebrew_share() {
  home="$TEST_TMP_ROOT/zsh-plugin-order-home"
  prefix="$home/homebrew"
  mkdir -p "$home" "$prefix/share/zsh-autosuggestions" "$prefix/share/zsh-syntax-highlighting"
  cat >"$prefix/share/zsh-autosuggestions/zsh-autosuggestions.zsh" <<'EOF'
printf 'autosuggestions\n' >> "$DOTFILES_TEST_PLUGIN_ORDER"
EOF
  cat >"$prefix/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" <<'EOF'
printf 'syntax-highlighting\n' >> "$DOTFILES_TEST_PLUGIN_ORDER"
EOF
  cat >"$home/.zshrc.local" <<'EOF'
printf 'local\n' >> "$DOTFILES_TEST_PLUGIN_ORDER"
EOF
  set +e
  HOME="$home" HOMEBREW_PREFIX="$prefix" DOTFILES_TEST_PLUGIN_ORDER="$home/order" \
    zsh -dfc \
    'source "$1"' zsh "$REPO_ROOT/zsh/.zshrc"
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail 'Homebrew-share shell plugins could not be loaded'
  assert_equals 'autosuggestions
local
syntax-highlighting' "$(cat "$home/order")" \
    'shell plugin load order is not autosuggestions, local, syntax highlighting'
}

test_zsh_loads_plugins_from_usr_share_fallback() {
  if [ ! -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] ||
    [ ! -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] ||
    [ -r /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] ||
    [ -r /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] ||
    [ -r /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] ||
    [ -r /usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]
  then
    return 0
  fi

  home="$TEST_TMP_ROOT/zsh-usr-share-home"
  mkdir -p "$home"
  set +e
  HOME="$home" zsh -dfic '
      source "$1"
      (( $+functions[_zsh_autosuggest_start] )) || exit 1
      (( $+functions[_zsh_highlight] )) || exit 1
    ' zsh "$REPO_ROOT/zsh/.zshrc"
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail 'plugins were not loaded from the actual /usr/share layout'
}

test_zsh_ignores_relative_homebrew_prefix_for_shell_code() {
  home="$TEST_TMP_ROOT/zsh-relative-homebrew-home"
  work="$TEST_TMP_ROOT/zsh-relative-homebrew-work"
  marker="$TEST_TMP_ROOT/zsh-relative-homebrew-sourced"
  mkdir -p "$home" "$work/bin" \
    "$work/share/zsh-autosuggestions" \
    "$work/share/zsh-syntax-highlighting" \
    "$work/opt/fzf/shell"
  for script in \
    "$work/share/zsh-autosuggestions/zsh-autosuggestions.zsh" \
    "$work/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" \
    "$work/opt/fzf/shell/key-bindings.zsh" \
    "$work/opt/fzf/shell/completion.zsh"
  do
    cat >"$script" <<'EOF'
print -r -- sourced >> "$DOTFILES_TEST_RELATIVE_PREFIX_MARKER"
EOF
  done
  cat >"$work/bin/fzf" <<'EOF'
#!/bin/sh
[ "$1" = --zsh ] || exit 64
exit 1
EOF
  chmod +x "$work/bin/fzf"

  set +e
  (
    cd "$work" || exit 1
    HOME="$home" HOMEBREW_PREFIX=. \
      DOTFILES_TEST_RELATIVE_PREFIX_MARKER="$marker" \
      PATH="$work/bin:/usr/bin:/bin" \
      zsh -dfc 'source "$1"' zsh "$REPO_ROOT/zsh/.zshrc" \
        2>"$home/stderr"
  )
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    cat "$home/stderr" >&2
    fail 'Zsh failed while rejecting a relative Homebrew prefix'
  fi
  [ ! -e "$marker" ] || fail 'relative HOMEBREW_PREFIX allowed shell code from the working directory'
}

test_fzf_modern_and_legacy_shell_integrations_preserve_bindings() {
  home="$TEST_TMP_ROOT/zsh-fzf-home"
  bin="$TEST_TMP_ROOT/zsh-fzf-bin"
  mkdir -p "$home" "$bin"
  cat >"$bin/fzf" <<'EOF'
#!/bin/sh
[ "$1" = --zsh ] || exit 64
printf '%s\n' \
  'function fzf-history-widget { :; }' \
  'function fzf-file-widget { :; }' \
  'function fzf-cd-widget { :; }' \
  'function fzf-completion { :; }' \
  'bindkey "^R" fzf-history-widget' \
  'bindkey "^T" fzf-file-widget' \
  'bindkey "^[c" fzf-cd-widget' \
  'bindkey "^I" fzf-completion'
EOF
  chmod +x "$bin/fzf"
  set +e
  HOME="$home" PATH="$bin:/usr/bin:/bin" zsh -dfic \
    'source "$1"; [[ $(bindkey "^R") == *fzf-history-widget* ]] && [[ $(bindkey "^T") == *fzf-file-widget* ]] && [[ $(bindkey "^[c") == *fzf-cd-widget* ]] && [[ $(bindkey "^I") == *fzf-completion* ]] && (( $+functions[fzf-completion] ))' \
    zsh "$REPO_ROOT/zsh/.zshrc"
  modern_status=$?
  set -e
  [ "$modern_status" -eq 0 ] || fail 'modern fzf --zsh integration did not preserve key bindings'
}

test_fzf_legacy_shell_scripts_preserve_key_bindings_and_completion() {
  home="$TEST_TMP_ROOT/zsh-fzf-legacy-home"
  prefix="$home/fzf-prefix"
  share="$prefix/opt/fzf/shell"
  mkdir -p "$home" "$share" "$home/bin"
  cat >"$home/bin/fzf" <<'EOF'
#!/bin/sh
[ "$1" = --zsh ] || exit 64
exit 1
EOF
  chmod +x "$home/bin/fzf"
  cat >"$share/key-bindings.zsh" <<'EOF'
function fzf-history-widget { :; }
function fzf-file-widget { :; }
function fzf-cd-widget { :; }
bindkey '^R' fzf-history-widget
bindkey '^T' fzf-file-widget
bindkey '^[c' fzf-cd-widget
EOF
  cat >"$share/completion.zsh" <<'EOF'
function fzf-completion { :; }
bindkey '^I' fzf-completion
EOF
  set +e
  HOME="$home" HOMEBREW_PREFIX="$prefix" PATH="$home/bin:/usr/bin:/bin" \
    zsh -dfic \
    'source "$1"; [[ $(bindkey "^R") == *fzf-history-widget* ]] && [[ $(bindkey "^T") == *fzf-file-widget* ]] && [[ $(bindkey "^[c") == *fzf-cd-widget* ]] && [[ $(bindkey "^I") == *fzf-completion* ]] && (( $+functions[fzf-completion] ))' \
    zsh "$REPO_ROOT/zsh/.zshrc"
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail 'legacy fzf shell scripts did not preserve bindings and completion'
}

test_fzf_legacy_fallback_uses_one_complete_installation() {
  packaged_root=
  for candidate in \
    /opt/homebrew/opt/fzf/shell \
    /usr/local/opt/fzf/shell \
    /usr/share/doc/fzf/examples \
    /usr/share/fzf/shell \
    /usr/share/fzf
  do
    if [ -r "$candidate/key-bindings.zsh" ] && [ -r "$candidate/completion.zsh" ]; then
      packaged_root=$candidate
      break
    fi
  done
  [ -n "$packaged_root" ] || return 0

  home="$TEST_TMP_ROOT/zsh-fzf-single-root-home"
  prefix="$home/fzf-prefix"
  incomplete_root="$prefix/opt/fzf/shell"
  marker="$home/incomplete-root-sourced"
  mkdir -p "$home/bin" "$incomplete_root"
  cat >"$home/bin/fzf" <<'EOF'
#!/bin/sh
[ "$1" = --zsh ] || exit 64
exit 1
EOF
  chmod +x "$home/bin/fzf"
  cat >"$incomplete_root/key-bindings.zsh" <<'EOF'
print -r -- sourced > "$DOTFILES_TEST_INCOMPLETE_FZF_MARKER"
EOF

  set +e
  HOME="$home" HOMEBREW_PREFIX="$prefix" \
    DOTFILES_TEST_INCOMPLETE_FZF_MARKER="$marker" \
    PATH="$home/bin:/usr/bin:/bin" \
    zsh -dfic '
      source "$1"
      (( $+functions[fzf-history-widget] )) || exit 1
      (( $+functions[fzf-completion] )) || exit 1
    ' zsh "$REPO_ROOT/zsh/.zshrc" 2>"$home/stderr"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    cat "$home/stderr" >&2
    fail 'legacy fzf fallback did not load a complete packaged integration'
  fi
  [ ! -e "$marker" ] || fail 'legacy fzf fallback mixed scripts from different installations'
}

test_zsh_initializes_starship_without_omz_theme_fallback() {
  home="$TEST_TMP_ROOT/zsh-starship-home"
  bin="$TEST_TMP_ROOT/zsh-starship-bin"
  mkdir -p "$home" "$bin"
  cat >"$bin/starship" <<'EOF'
#!/bin/sh
set -eu
[ "$1 $2" = 'init zsh' ]
printf '%s\n' 'STARSHIP_TEST_INIT=1' 'PROMPT=starship-test'
EOF
  chmod +x "$bin/starship"

  set +e
  HOME="$home" PATH="$bin:/usr/bin:/bin" zsh -dfc '
      source "$1"
      [[ "$ZLE_RPROMPT_INDENT" = 0 ]] || exit 1
      [[ "$STARSHIP_TEST_INIT" = 1 ]] || exit 1
      [[ "$PROMPT" = starship-test ]] || exit 1
    ' zsh "$REPO_ROOT/zsh/.zshrc"
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail 'Zsh did not initialize Starship without an Oh My Zsh fallback theme'
}

test_starship_config_is_focused_tokyo_night_two_line_prompt() {
  config="$REPO_ROOT/starship/.config/starship.toml"
  [ -r "$config" ] || fail 'Starship configuration is missing'
  assert_file_contains "$config" "format = '\$container\$username\$hostname\$directory\$git_branch\$git_status\$git_state\$line_break\$python\$jobs\$character'"
  assert_file_contains "$config" "right_format = '\$cmd_duration'"
  assert_file_contains "$config" 'scan_timeout = 30'
  assert_file_contains "$config" 'command_timeout = 500'
  assert_file_contains "$config" "style = 'bold #7aa2f7'"
  assert_file_contains "$config" "min_time = 2000"
  assert_file_contains "$config" "truncation_length = 3"
}

test_starship_installer_is_idempotent_and_uses_user_prefix() {
  home="$TEST_TMP_ROOT/starship-installer-home"
  bin="$TEST_TMP_ROOT/starship-installer-bin"
  calls="$TEST_TMP_ROOT/starship-installer-calls"
  mkdir -p "$home" "$bin"
  cat >"$bin/curl" <<'EOF'
#!/bin/sh
set -eu
output=
url=
while [ "$#" -gt 0 ]; do
  case $1 in
    -o|--output) output=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\n' "$url" >>"$DOTFILES_TEST_STARSHIP_CALLS"
cat >"$output" <<'INSTALLER'
#!/bin/sh
set -eu
[ "$1" = --yes ]
[ "$2" = --bin-dir ]
[ "$3" = "$HOME/.local/bin" ]
mkdir -p "$3"
cat >"$3/starship" <<'TOOL'
#!/bin/sh
printf 'starship 1.26.0\n'
TOOL
chmod +x "$3/starship"
INSTALLER
EOF
  chmod +x "$bin/curl"

  for _run_number in 1 2; do
    HOME="$home" PATH="$bin:/usr/bin:/bin" \
      DOTFILES_CURL_CMD="$bin/curl" DOTFILES_TEST_STARSHIP_CALLS="$calls" \
      DOTFILES_STARSHIP_INSTALL_URL=https://example.test/starship \
      bash -c '. "$1/scripts/provision-common.sh"; install_starship_if_missing' \
      shell "$REPO_ROOT"
  done

  assert_equals 1 "$(wc -l <"$calls" | tr -d ' ')" \
    'Starship was installed more than once'
  assert_equals 'starship 1.26.0' "$("$home/.local/bin/starship" --version)" \
    'Starship was not installed into the user prefix'
}

test_incomplete_uv_installation_is_not_replaced() {
  home="$TEST_TMP_ROOT/incomplete-uv-home"
  bin="$TEST_TMP_ROOT/incomplete-uv-bin"
  curl_marker="$TEST_TMP_ROOT/incomplete-uv-curl-ran"
  mkdir -p "$home" "$bin"
  cat >"$bin/uv" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat >"$bin/curl" <<'EOF'
#!/bin/sh
: >"$DOTFILES_TEST_CURL_MARKER"
exit 99
EOF
  chmod +x "$bin/uv" "$bin/curl"

  set +e
  diagnostic=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
    DOTFILES_CURL_CMD="$bin/curl" DOTFILES_TEST_CURL_MARKER="$curl_marker" \
    bash -c '. "$1/scripts/provision-common.sh"; install_uv_if_missing' shell "$REPO_ROOT" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'incomplete UV installation was accepted'
  assert_equals \
    'dotfiles: uv is installed but uvx is missing; refusing to replace the existing UV installation' \
    "$diagnostic" 'incomplete UV diagnostic is not precise'
  [ ! -e "$curl_marker" ] || fail 'incomplete UV installation was silently replaced'
}

test_common_diagnostics_reject_outdated_neovim_with_manual_guidance() {
  home="$TEST_TMP_ROOT/outdated-nvim-home"
  bin="$TEST_TMP_ROOT/outdated-nvim-bin"
  completion_dir="$home/.local/share/zsh/site-functions/.dotfiles-completions-current"
  prefix="$home/homebrew"
  mkdir -p "$bin" "$prefix/share/zsh-autosuggestions" \
    "$prefix/share/zsh-syntax-highlighting" "$completion_dir"
  : >"$prefix/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
  : >"$prefix/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
  for completion_name in _herdr _uv _uvx; do
    printf 'completion\n' >"$completion_dir/$completion_name"
  done
  for tool_name in uv uvx herdr starship; do
    cat >"$bin/$tool_name" <<'EOF'
#!/bin/sh
exit 0
EOF
  done
  cat >"$bin/nvim" <<'EOF'
#!/bin/sh
printf 'NVIM v0.10.4\n'
EOF
  chmod +x "$bin/uv" "$bin/uvx" "$bin/herdr" "$bin/nvim"

  set +e
  diagnostic=$(HOME="$home" HOMEBREW_PREFIX="$prefix" PATH="$bin:/usr/bin:/bin" \
    bash -c '. "$1/scripts/provision-common.sh"; diagnose_common' \
    shell "$REPO_ROOT" 2>&1)
  status=$?
  set -e

  assert_equals 1 "$status" 'common diagnostics accepted Neovim below 0.11.2'
  assert_equals \
    'dotfiles: Neovim 0.10.4 is below required 0.11.2; update Neovim manually (bootstrap does not upgrade existing installations)' \
    "$diagnostic" 'outdated Neovim guidance is not precise'

  cat >"$bin/nvim" <<'EOF'
#!/bin/sh
printf 'NVIM v0.11.2\n'
EOF
  chmod +x "$bin/nvim"
  HOME="$home" HOMEBREW_PREFIX="$prefix" PATH="$bin:/usr/bin:/bin" bash -c \
    '. "$1/scripts/provision-common.sh"; diagnose_common' shell "$REPO_ROOT"

  rm "$bin/starship"
  set +e
  diagnostic=$(HOME="$home" HOMEBREW_PREFIX="$prefix" PATH="$bin:/usr/bin:/bin" \
    bash -c '. "$1/scripts/provision-common.sh"; diagnose_common' \
    shell "$REPO_ROOT" 2>&1)
  status=$?
  set -e
  assert_equals 1 "$status" 'common diagnostics accepted missing Starship'
  assert_equals 'dotfiles: missing command: starship' "$diagnostic" \
    'common diagnostics did not name missing Starship precisely'
}

test_neovim_diagnostics_suppress_current_directory_log() {
  home="$TEST_TMP_ROOT/nvim-log-home"
  bin="$TEST_TMP_ROOT/nvim-log-bin"
  working_dir="$TEST_TMP_ROOT/nvim-log-working"
  mkdir -p "$home" "$bin" "$working_dir"
  cat >"$bin/nvim" <<'EOF'
#!/bin/sh
if [ "${NVIM_LOG_FILE:-}" != /dev/null ]; then
  : >nvim.log
fi
printf 'NVIM v0.11.2\n'
EOF
  chmod +x "$bin/nvim"

  (cd "$working_dir" && HOME="$home" PATH="$bin:/usr/bin:/bin" bash -c '
    . "$1/scripts/provision-common.sh"
    diagnose_neovim_version
  ' shell "$REPO_ROOT")

  [ ! -e "$working_dir/nvim.log" ] ||
    fail 'Neovim diagnostics created runtime state in the current directory'
}

test_failed_remote_installer_cleans_temp_directory() {
  home="$TEST_TMP_ROOT/failed-installer-home"
  bin="$TEST_TMP_ROOT/failed-installer-bin"
  temp_dir="$TEST_TMP_ROOT/failed-installer-tmp"
  mkdir -p "$home" "$bin" "$temp_dir"
  cat >"$bin/curl" <<'EOF'
#!/bin/sh
exit 9
EOF
  chmod +x "$bin/curl"

  set +e
  HOME="$home" TMPDIR="$temp_dir" PATH="$bin:/usr/bin:/bin" \
    DOTFILES_CURL_CMD="$bin/curl" bash -c \
    '. "$1/scripts/provision-common.sh"; install_uv_if_missing' shell "$REPO_ROOT"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'failed installer download unexpectedly succeeded'
  [ -z "$(find "$temp_dir" -mindepth 1 -print -quit)" ] ||
    fail 'failed installer download left a temporary directory behind'
}

test_failed_neovim_download_cleans_temp_directory() {
  home="$TEST_TMP_ROOT/failed-neovim-home"
  bin="$TEST_TMP_ROOT/failed-neovim-bin"
  temp_dir="$TEST_TMP_ROOT/failed-neovim-tmp"
  mkdir -p "$home" "$bin" "$temp_dir"
  cat >"$bin/uname" <<'EOF'
#!/bin/sh
printf 'x86_64\n'
EOF
  cat >"$bin/curl" <<'EOF'
#!/bin/sh
exit 9
EOF
  chmod +x "$bin/uname" "$bin/curl"

  set +e
  HOME="$home" TMPDIR="$temp_dir" PATH="$bin:/usr/bin:/bin" \
    DOTFILES_UNAME_CMD="$bin/uname" DOTFILES_CURL_CMD="$bin/curl" bash -c \
    '. "$1/scripts/provision-debian.sh"; install_neovim_archive' shell "$REPO_ROOT"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'failed Neovim download unexpectedly succeeded'
  [ -z "$(find "$temp_dir" -mindepth 1 -print -quit)" ] ||
    fail 'failed Neovim download left a temporary directory behind'
}

test_macos_packages_require_brew_and_never_upgrade() {
  home="$TEST_TMP_ROOT/macos-home"
  bin="$TEST_TMP_ROOT/macos-bin"
  receipts="$TEST_TMP_ROOT/brew-receipts"
  mkdir -p "$home" "$bin" "$receipts"

  set +e
  HOME="$home" PATH="/usr/bin:/bin" bash -c \
    '. "$1/scripts/provision-macos.sh"; provision_macos_packages' shell "$REPO_ROOT" \
    2>/dev/null
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'macOS provisioning accepted missing Homebrew'

  cat >"$bin/brew" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = bundle ]
shift
saw_no_upgrade=false
brewfile=
while [ "$#" -gt 0 ]; do
  case $1 in
    --no-upgrade) saw_no_upgrade=true ;;
    --file=*) brewfile=${1#--file=} ;;
  esac
  shift
done
[ "$saw_no_upgrade" = true ]
[ -r "$brewfile" ]
sed -n 's/^brew "\([^"]*\)"$/\1/p' "$brewfile" >"$DOTFILES_TEST_RECEIPTS/formulas"
EOF
  chmod +x "$bin/brew"

  HOME="$home" PATH="$bin:/usr/bin:/bin" DOTFILES_BREW_CMD="$bin/brew" \
    DOTFILES_TEST_RECEIPTS="$receipts" bash -c \
    '. "$1/scripts/provision-macos.sh"; provision_macos_packages' shell "$REPO_ROOT"

  assert_equals \
    'git neovim stow fzf zsh-autosuggestions zsh-syntax-highlighting zoxide fd ripgrep tree-sitter-cli node lazygit graphviz shellcheck starship' \
    "$(tr '\n' ' ' <"$receipts/formulas" | sed 's/ $//')" \
    'Brewfile formulas differ from the required portable toolset'
}

test_macos_diagnostics_accept_installed_outdated_formulas_and_name_missing_formula() {
  home="$TEST_TMP_ROOT/macos-diagnostic-home"
  bin="$TEST_TMP_ROOT/macos-diagnostic-bin"
  bundle_check_marker="$TEST_TMP_ROOT/macos-bundle-check-ran"
  formula_calls="$TEST_TMP_ROOT/macos-diagnostic-formula-calls"
  mkdir -p "$home" "$bin"

  cat >"$bin/brew" <<'EOF'
#!/bin/sh
set -eu
case $1 in
  bundle)
    [ "$2" = check ]
    : >"$DOTFILES_TEST_BUNDLE_CHECK_MARKER"
    exit 1
    ;;
  list)
    [ "$2" = --versions ]
    formula=$3
    printf '%s\n' "$formula" >>"$DOTFILES_TEST_FORMULA_CALLS"
    if [ "$formula" = "${DOTFILES_TEST_MISSING_FORMULA:-}" ]; then
      exit 1
    fi
    printf '%s 1.0\n' "$formula"
    ;;
  *) exit 64 ;;
esac
EOF
  cat >"$bin/tree-sitter" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$bin/brew" "$bin/tree-sitter"

  set +e
  diagnostic=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
    DOTFILES_BREW_CMD="$bin/brew" DOTFILES_TEST_BUNDLE_CHECK_MARKER="$bundle_check_marker" \
    DOTFILES_TEST_FORMULA_CALLS="$formula_calls" \
    bash -c '. "$1/scripts/provision-macos.sh"; diagnose_common() { return 0; }; diagnose_macos' \
    shell "$REPO_ROOT" 2>&1)
  status=$?
  set -e
  assert_equals 0 "$status" \
    'macOS diagnostics rejected installed formulas because bundle check considered them outdated'
  assert_equals '' "$diagnostic" \
    'macOS diagnostics emitted an error for installed formulas'
  [ ! -e "$bundle_check_marker" ] ||
    fail 'macOS diagnostics invoked currency-based brew bundle check'
  assert_equals "$(sed -n 's/^brew "\([^"]*\)"$/\1/p' "$REPO_ROOT/Brewfile" | sort)" \
    "$(sort -u "$formula_calls")" \
    'macOS diagnostics did not check every Brewfile formula by installed presence'

  set +e
  diagnostic=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
    DOTFILES_BREW_CMD="$bin/brew" DOTFILES_TEST_BUNDLE_CHECK_MARKER="$bundle_check_marker" \
    DOTFILES_TEST_FORMULA_CALLS="$formula_calls" DOTFILES_TEST_MISSING_FORMULA=fd \
    bash -c '. "$1/scripts/provision-macos.sh"; diagnose_common() { return 0; }; diagnose_macos' \
    shell "$REPO_ROOT" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'macOS diagnostics accepted a missing Brewfile formula'
  assert_equals 'dotfiles: missing Brewfile formula: fd' "$diagnostic" \
    'macOS diagnostics did not name the missing Brewfile formula precisely'
}

test_macos_diagnostics_require_usable_tree_sitter_command() {
  home="$TEST_TMP_ROOT/macos-tree-sitter-home"
  bin="$TEST_TMP_ROOT/macos-tree-sitter-bin"
  mkdir -p "$home" "$bin"
  cat >"$bin/brew" <<'EOF'
#!/bin/sh
set -eu
[ "$1 $2" = "list --versions" ]
printf '%s 1.0\n' "$3"
EOF
  cat >"$bin/tree-sitter" <<'EOF'
#!/bin/sh
exit 42
EOF
  chmod +x "$bin/brew" "$bin/tree-sitter"

  set +e
  diagnostic=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
    DOTFILES_BREW_CMD="$bin/brew" bash -c '
      . "$1/scripts/provision-macos.sh"
      diagnose_common() { :; }
      diagnose_macos
    ' shell "$REPO_ROOT" 2>&1)
  status=$?
  set -e

  assert_equals 1 "$status" 'macOS diagnostics accepted unusable Tree-sitter CLI'
  assert_equals \
    "dotfiles: Tree-sitter CLI is unusable: $bin/tree-sitter; install the tree-sitter-cli Homebrew formula manually" \
    "$diagnostic" 'macOS Tree-sitter diagnostic guidance is not precise'
}

test_macos_provision_rejects_unusable_tree_sitter_command() {
  home="$TEST_TMP_ROOT/macos-provision-tree-sitter-home"
  bin="$TEST_TMP_ROOT/macos-provision-tree-sitter-bin"
  mkdir -p "$home" "$bin"
  cat >"$bin/brew" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat >"$bin/tree-sitter" <<'EOF'
#!/bin/sh
exit 42
EOF
  chmod +x "$bin/brew" "$bin/tree-sitter"

  set +e
  diagnostic=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
    DOTFILES_BREW_CMD="$bin/brew" bash -c '
      . "$1/scripts/provision-macos.sh"
      provision_common() { :; }
      regenerate_completions() { :; }
      provision_macos
    ' shell "$REPO_ROOT" 2>&1)
  status=$?
  set -e

  assert_equals 1 "$status" 'macOS provisioning accepted unusable Tree-sitter CLI'
  assert_equals \
    "dotfiles: Tree-sitter CLI is unusable: $bin/tree-sitter; install the tree-sitter-cli Homebrew formula manually" \
    "$diagnostic" 'macOS provisioning did not explain the unusable Tree-sitter CLI'
}

make_nvim_fixture() {
  architecture=$1
  fixture_root="$TEST_TMP_ROOT/nvim-fixture-$architecture"
  archive="$TEST_TMP_ROOT/nvim-$architecture.tar.gz"
  mkdir -p "$fixture_root/nvim-linux-$architecture/bin"
  cat >"$fixture_root/nvim-linux-$architecture/bin/nvim" <<'EOF'
#!/bin/sh
printf 'fixture nvim\n'
EOF
  chmod +x "$fixture_root/nvim-linux-$architecture/bin/nvim"
  tar -C "$fixture_root" -czf "$archive" "nvim-linux-$architecture"
  printf '%s\n' "$archive"
}

test_debian_provision_publishes_nvim_without_overwriting_existing_path() {
  home="$TEST_TMP_ROOT/nvim-link-home"
  bin="$TEST_TMP_ROOT/nvim-link-bin"
  existing_home="$TEST_TMP_ROOT/nvim-existing-link-home"
  mkdir -p "$home/.local/opt/nvim/bin" "$bin" \
    "$existing_home/.local/opt/nvim/bin" "$existing_home/.local/bin"
  cat >"$home/.local/opt/nvim/bin/nvim" <<'EOF'
#!/bin/sh
printf 'managed nvim\n'
EOF
  cp "$home/.local/opt/nvim/bin/nvim" "$existing_home/.local/opt/nvim/bin/nvim"
  cat >"$existing_home/.local/bin/nvim" <<'EOF'
#!/bin/sh
printf 'existing nvim\n'
EOF
  chmod +x "$home/.local/opt/nvim/bin/nvim" \
    "$existing_home/.local/opt/nvim/bin/nvim" "$existing_home/.local/bin/nvim"

  for provision_home in "$home" "$existing_home"; do
    HOME="$provision_home" PATH="$bin:/usr/bin:/bin" bash -c '
      . "$1/scripts/provision-debian.sh"
      require_debian_family() { :; }
      provision_debian_packages() { :; }
      install_neovim_archive() { :; }
      ensure_fd_link() { :; }
      install_tree_sitter_cli_if_missing() { :; }
      provision_common() { :; }
      regenerate_completions() { :; }
      provision_debian
    ' shell "$REPO_ROOT"
  done

  [ -L "$home/.local/bin/nvim" ] || fail 'managed Neovim was not published on PATH'
  assert_equals "$home/.local/opt/nvim/bin/nvim" "$(readlink "$home/.local/bin/nvim")" \
    'managed Neovim link points at the wrong executable'
  assert_equals 'managed nvim' \
    "$(PATH="$home/.local/bin:$bin:/usr/bin:/bin" nvim)" \
    'published Neovim is not usable through the deployed PATH'
  [ ! -L "$existing_home/.local/bin/nvim" ] ||
    fail 'provisioning overwrote an existing Neovim path'
  assert_equals 'existing nvim' "$("$existing_home/.local/bin/nvim")" \
    'provisioning changed an existing Neovim command'
}

test_debian_tree_sitter_cli_is_installed_once_in_user_prefix() {
  home="$TEST_TMP_ROOT/tree-sitter-home"
  bin="$TEST_TMP_ROOT/tree-sitter-bin"
  receipt="$TEST_TMP_ROOT/tree-sitter-npm-receipt"
  mkdir -p "$home" "$bin"
  cat >"$bin/npm" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$DOTFILES_TEST_NPM_RECEIPT"
[ "$1 $2 $3" = "install --global --prefix" ]
[ "$4" = "$HOME/.local" ]
[ "$5" = tree-sitter-cli ]
mkdir -p "$HOME/.local/bin"
cat >"$HOME/.local/bin/tree-sitter" <<'TOOL'
#!/bin/sh
printf 'tree-sitter 0.25.0\n'
TOOL
chmod +x "$HOME/.local/bin/tree-sitter"
EOF
  chmod +x "$bin/npm"

  for _run_number in 1 2; do
    HOME="$home" PATH="$bin:/usr/bin:/bin" \
      DOTFILES_TEST_NPM_RECEIPT="$receipt" bash -c '
        . "$1/scripts/provision-debian.sh"
        require_debian_family() { :; }
        provision_debian_packages() { :; }
        install_neovim_archive() { :; }
        ensure_nvim_link() { :; }
        ensure_fd_link() { :; }
        provision_common() { :; }
        regenerate_completions() { :; }
        provision_debian
      ' shell "$REPO_ROOT"
  done

  assert_equals 1 "$(wc -l <"$receipt" | tr -d ' ')" \
    'existing Tree-sitter CLI was silently upgraded'
  assert_equals "install --global --prefix $home/.local tree-sitter-cli" \
    "$(cat "$receipt")" 'Tree-sitter CLI used the wrong npm installation contract'
  assert_equals 'tree-sitter 0.25.0' \
    "$(PATH="$home/.local/bin:$bin:/usr/bin:/bin" tree-sitter --version)" \
    'Tree-sitter CLI is not usable from the deployed PATH'
}

test_debian_provision_rejects_unusable_existing_tree_sitter_command() {
  home="$TEST_TMP_ROOT/debian-broken-tree-sitter-home"
  bin="$TEST_TMP_ROOT/debian-broken-tree-sitter-bin"
  receipt="$TEST_TMP_ROOT/debian-broken-tree-sitter-npm-receipt"
  mkdir -p "$home" "$bin"
  cat >"$bin/tree-sitter" <<'EOF'
#!/bin/sh
exit 42
EOF
  cat >"$bin/npm" <<'EOF'
#!/bin/sh
printf 'called\n' >>"$DOTFILES_TEST_NPM_RECEIPT"
EOF
  chmod +x "$bin/tree-sitter" "$bin/npm"

  set +e
  diagnostic=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
    DOTFILES_TEST_NPM_RECEIPT="$receipt" bash -c '
      . "$1/scripts/provision-debian.sh"
      install_tree_sitter_cli_if_missing
    ' shell "$REPO_ROOT" 2>&1)
  status=$?
  set -e

  assert_equals 1 "$status" 'Debian provisioning accepted unusable Tree-sitter CLI'
  assert_equals \
    "dotfiles: Tree-sitter CLI is unusable: $bin/tree-sitter; refusing to replace the existing installation" \
    "$diagnostic" 'Debian provisioning did not explain the unusable Tree-sitter CLI'
  [ ! -e "$receipt" ] || fail 'Debian provisioning replaced an existing Tree-sitter command'
}

test_debian_diagnostics_require_tree_sitter_cli_with_install_guidance() {
  home="$TEST_TMP_ROOT/tree-sitter-diagnostic-home"
  bin="$TEST_TMP_ROOT/tree-sitter-diagnostic-bin"
  mkdir -p "$home/.local/opt/nvim/bin" "$home/.local/bin" "$bin"
  for command_path in \
    "$home/.local/opt/nvim/bin/nvim" "$home/.local/bin/fd"
  do
    cat >"$command_path" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$command_path"
  done

  set +e
  diagnostic=$(HOME="$home" PATH="$home/.local/bin:$bin:/usr/bin:/bin" bash -c '
    . "$1/scripts/provision-debian.sh"
    require_debian_family() { :; }
    diagnose_debian_packages() { :; }
    diagnose_common() { :; }
    diagnose_debian
  ' shell "$REPO_ROOT" 2>&1)
  status=$?
  set -e

  assert_equals 1 "$status" 'Debian diagnostics accepted missing Tree-sitter CLI'
  assert_equals \
    "dotfiles: missing command: tree-sitter; run npm install --global --prefix $home/.local tree-sitter-cli" \
    "$diagnostic" 'Debian Tree-sitter diagnostic guidance is not precise'
}

test_debian_archive_install_and_fd_link() {
  home="$TEST_TMP_ROOT/debian-home"
  bin="$TEST_TMP_ROOT/debian-bin"
  receipts="$TEST_TMP_ROOT/debian-receipts"
  archive=$(make_nvim_fixture x86_64)
  mkdir -p "$home" "$bin" "$receipts"

  cat >"$bin/uname" <<'EOF'
#!/bin/sh
printf 'x86_64\n'
EOF
  cat >"$bin/curl" <<'EOF'
#!/bin/sh
set -eu
output=
url=
while [ "$#" -gt 0 ]; do
  case $1 in
    -o|--output) output=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\n' "$url" >"$DOTFILES_TEST_RECEIPTS/nvim-url"
cp "$DOTFILES_TEST_NVIM_ARCHIVE" "$output"
EOF
  cat >"$bin/fdfind" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat >"$bin/apt-get" <<'EOF'
#!/bin/sh
set -eu
if [ "$1" = update ]; then
  : >"$DOTFILES_TEST_RECEIPTS/apt-update"
  exit 0
fi
[ "$1" = install ]
shift
saw_no_upgrade=false
packages=
for argument in "$@"; do
  case $argument in
    --no-upgrade) saw_no_upgrade=true ;;
    -*) ;;
    *) packages="$packages $argument" ;;
  esac
done
[ "$saw_no_upgrade" = true ]
printf '%s\n' "${packages# }" >"$DOTFILES_TEST_RECEIPTS/apt-packages"
EOF
  chmod +x "$bin/uname" "$bin/curl" "$bin/fdfind" "$bin/apt-get"

  HOME="$home" PATH="$bin:/usr/bin:/bin" \
    DOTFILES_UNAME_CMD="$bin/uname" DOTFILES_CURL_CMD="$bin/curl" \
    DOTFILES_APT_GET_CMD="$bin/apt-get" DOTFILES_SUDO_CMD='' \
    DOTFILES_TEST_RECEIPTS="$receipts" DOTFILES_TEST_NVIM_ARCHIVE="$archive" \
    bash -c '. "$1/scripts/provision-debian.sh"; provision_debian_packages; install_neovim_archive; ensure_fd_link' shell "$REPO_ROOT"

  assert_equals \
    'https://github.com/neovim/neovim/releases/download/stable/nvim-linux-x86_64.tar.gz' \
    "$(cat "$receipts/nvim-url")" 'wrong stable Neovim archive URL'
  [ -x "$home/.local/opt/nvim/bin/nvim" ] || fail 'Neovim was not installed in the managed prefix'
  [ -L "$home/.local/bin/fd" ] || fail 'fd compatibility link was not created'
  assert_equals "$bin/fdfind" "$(readlink "$home/.local/bin/fd")" \
    'fd compatibility link points at the wrong executable'
  assert_equals \
    'ca-certificates curl git stow zsh zsh-autosuggestions zsh-syntax-highlighting fzf zoxide fd-find ripgrep nodejs npm build-essential graphviz shellcheck tar xz-utils' \
    "$(cat "$receipts/apt-packages")" 'apt package set differs from the required dependencies'

  before=$(stat -c %Y "$home/.local/opt/nvim" 2>/dev/null || stat -f %m "$home/.local/opt/nvim")
  mv "$archive" "$archive.unavailable"
  HOME="$home" PATH="$bin:/usr/bin:/bin" \
    DOTFILES_UNAME_CMD="$bin/uname" DOTFILES_CURL_CMD="$bin/curl" \
    DOTFILES_TEST_RECEIPTS="$receipts" DOTFILES_TEST_NVIM_ARCHIVE="$archive" \
    bash -c '. "$1/scripts/provision-debian.sh"; install_neovim_archive' shell "$REPO_ROOT"
  after=$(stat -c %Y "$home/.local/opt/nvim" 2>/dev/null || stat -f %m "$home/.local/opt/nvim")
  assert_equals "$before" "$after" 'existing managed Neovim was unexpectedly replaced'
}

test_root_debian_provisioning_does_not_require_sudo() {
  home="$TEST_TMP_ROOT/root-debian-home"
  bin="$TEST_TMP_ROOT/root-debian-bin"
  apt_marker="$TEST_TMP_ROOT/root-debian-apt-ran"
  mkdir -p "$home" "$bin"
  cat >"$bin/id" <<'EOF'
#!/bin/sh
[ "$1" = -u ]
printf '0\n'
EOF
  cat >"$bin/sudo" <<'EOF'
#!/bin/sh
exit 91
EOF
  cat >"$bin/apt-get" <<'EOF'
#!/bin/sh
: >"$DOTFILES_TEST_APT_MARKER"
exit 0
EOF
  chmod +x "$bin/id" "$bin/sudo" "$bin/apt-get"

  HOME="$home" PATH="$bin:/usr/bin:/bin" DOTFILES_ID_CMD="$bin/id" \
    DOTFILES_APT_GET_CMD="$bin/apt-get" DOTFILES_TEST_APT_MARKER="$apt_marker" \
    bash -c '. "$1/scripts/provision-debian.sh"; provision_debian_packages' shell "$REPO_ROOT"
  [ -e "$apt_marker" ] || fail 'root Debian provisioning did not invoke apt-get directly'
}

test_arm64_archive_name_and_read_only_diagnostics() {
  home="$TEST_TMP_ROOT/diagnostic-home"
  bin="$TEST_TMP_ROOT/diagnostic-bin"
  mkdir -p "$home" "$bin"
  cat >"$bin/uname" <<'EOF'
#!/bin/sh
printf 'aarch64\n'
EOF
  chmod +x "$bin/uname"

  url=$(HOME="$home" PATH="$bin:/usr/bin:/bin" DOTFILES_UNAME_CMD="$bin/uname" \
    bash -c '. "$1/scripts/provision-debian.sh"; neovim_archive_url' shell "$REPO_ROOT")
  assert_equals \
    'https://github.com/neovim/neovim/releases/download/stable/nvim-linux-arm64.tar.gz' \
    "$url" 'wrong arm64 Neovim archive URL'

  set +e
  diagnostic=$(HOME="$home" PATH="/usr/bin:/bin" bash -c \
    '. "$1/scripts/provision-common.sh"; diagnose_common' shell "$REPO_ROOT" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'common diagnostics reported a missing installation as healthy'
  case $diagnostic in
    *oh-my-zsh*|*'missing shell dependency'*)
      fail 'common diagnostics still checks removed Oh My Zsh dependencies' ;;
  esac
  [ -z "$(find "$home" -mindepth 1 -print -quit)" ] || fail 'diagnostics mutated HOME'
}

test_common_provisioning_is_idempotent_and_regenerates_completions
test_common_provisioning_does_not_clone_omz_or_plugins
test_brewfile_and_debian_packages_include_zsh_plugins
test_relative_xdg_data_home_publishes_completions_inside_home
test_completion_failure_preserves_existing_set
test_completion_publication_failure_preserves_existing_set
test_completion_cleanup_rejects_traversal_pointer_targets
test_first_completion_publication_has_one_atomic_entry
test_zsh_uses_atomic_completion_directory
test_zsh_falls_back_from_relative_xdg_data_home
test_zsh_discovers_generated_completions_through_the_atomic_pointer
test_zsh_defines_the_documented_git_aliases
test_zsh_local_config_can_override_git_aliases
test_zsh_discovers_completions_after_native_compinit
test_zsh_loads_plugins_in_required_order_from_homebrew_share
test_zsh_loads_plugins_from_usr_share_fallback
test_zsh_ignores_relative_homebrew_prefix_for_shell_code
test_fzf_modern_and_legacy_shell_integrations_preserve_bindings
test_fzf_legacy_shell_scripts_preserve_key_bindings_and_completion
test_fzf_legacy_fallback_uses_one_complete_installation
test_zsh_initializes_starship_without_omz_theme_fallback
test_starship_config_is_focused_tokyo_night_two_line_prompt
test_starship_installer_is_idempotent_and_uses_user_prefix
test_incomplete_uv_installation_is_not_replaced
test_common_diagnostics_reject_outdated_neovim_with_manual_guidance
test_neovim_diagnostics_suppress_current_directory_log
test_failed_remote_installer_cleans_temp_directory
test_failed_neovim_download_cleans_temp_directory
test_macos_packages_require_brew_and_never_upgrade
test_macos_diagnostics_accept_installed_outdated_formulas_and_name_missing_formula
test_macos_diagnostics_require_usable_tree_sitter_command
test_macos_provision_rejects_unusable_tree_sitter_command
test_debian_provision_publishes_nvim_without_overwriting_existing_path
test_debian_tree_sitter_cli_is_installed_once_in_user_prefix
test_debian_provision_rejects_unusable_existing_tree_sitter_command
test_debian_diagnostics_require_tree_sitter_cli_with_install_guidance
test_debian_archive_install_and_fd_link
test_root_debian_provisioning_does_not_require_sudo
test_arm64_archive_name_and_read_only_diagnostics
printf 'ok - provisioning behavior\n'
