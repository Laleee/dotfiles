#!/usr/bin/env bash

set -eu
set -o pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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
else
  cat >"\$HOME/.local/bin/herdr" <<'TOOL'
#!/bin/sh
[ "\$1 \$2" = "completion zsh" ] || exit 64
printf '#compdef herdr\nherdr completion\n'
TOOL
  chmod +x "\$HOME/.local/bin/herdr"
fi
INSTALLER
EOF

  cat >"$fake_bin/git" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = clone ]
shift
if [ "${1:-}" = --depth ]; then shift 2; fi
url=$1
destination=$2
[ ! -e "$destination" ] || exit 92
mkdir -p "$destination"
case $url in
  *ohmyzsh*) : >"$destination/oh-my-zsh.sh" ;;
  *zsh-autosuggestions*) : >"$destination/zsh-autosuggestions.zsh" ;;
  *zsh-syntax-highlighting*) : >"$destination/zsh-syntax-highlighting.zsh" ;;
  *) exit 64 ;;
esac
EOF
  chmod +x "$fake_bin/curl" "$fake_bin/git"
}

test_common_provisioning_is_idempotent_and_regenerates_completions() {
  home="$TEST_TMP_ROOT/common-home"
  fake_bin="$TEST_TMP_ROOT/common-bin"
  mkdir -p "$home"
  make_fake_user_tools "$fake_bin"

  HOME="$home" ZSH="$home/.oh-my-zsh" \
    ZSH_CUSTOM="$home/.oh-my-zsh/custom" PATH="$fake_bin:/usr/bin:/bin" \
    DOTFILES_UV_INSTALL_URL=https://example.test/uv \
    DOTFILES_HERDR_INSTALL_URL=https://example.test/herdr \
    bash "$REPO_ROOT/scripts/provision-common.sh"

  assert_equals 1 "$(cat "$home/.uv-no-modify-path")" \
    'uv installer must be prevented from editing profiles'
  [ -r "$home/.oh-my-zsh/oh-my-zsh.sh" ] || fail 'Oh My Zsh was not cloned'
  [ -r "$home/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ] ||
    fail 'zsh-autosuggestions was not cloned to the conventional OMZ path'
  [ -r "$home/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ] ||
    fail 'zsh-syntax-highlighting was not cloned to the conventional OMZ path'

  completion_root="$home/.local/share/zsh/site-functions"
  completion_dir="$completion_root/.dotfiles-completions-current"
  assert_file_contains "$completion_dir/_herdr" 'herdr completion'
  assert_file_contains "$completion_dir/_uv" 'uv completion'
  assert_file_contains "$completion_dir/_uvx" 'uvx completion'

  printf 'stale\n' >"$completion_dir/_uv"
  HOME="$home" ZSH="$home/.oh-my-zsh" \
    ZSH_CUSTOM="$home/.oh-my-zsh/custom" PATH="$fake_bin:/usr/bin:/bin" \
    DOTFILES_UV_INSTALL_URL=https://example.test/uv \
    DOTFILES_HERDR_INSTALL_URL=https://example.test/herdr \
    bash "$REPO_ROOT/scripts/provision-common.sh"
  assert_file_contains "$completion_dir/_uv" 'uv completion'
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
  HOME="$home" XDG_DATA_HOME="$home/.local/share" ZSH="$home/missing-oh-my-zsh" \
    ZSH_CUSTOM="$home/missing-oh-my-zsh/custom" zsh -dfc \
    'source "$1"; [[ ${fpath[1]} == "$XDG_DATA_HOME/zsh/site-functions/.dotfiles-completions-current" ]]' \
    zsh "$REPO_ROOT/zsh/.zshrc"
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail 'Zsh fpath does not use the atomic completion directory'
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
  HOME="$home" XDG_DATA_HOME="$home/.local/share" ZSH="$home/missing-oh-my-zsh" \
    ZSH_CUSTOM="$home/missing-oh-my-zsh/custom" zsh -dfc '
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
  HOME="$home" ZSH="$home/.oh-my-zsh" \
    ZSH_CUSTOM="$home/.oh-my-zsh/custom" PATH="/usr/bin:/bin" bash -c \
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
    'git neovim stow fzf zoxide fd ripgrep tree-sitter node lazygit graphviz shellcheck' \
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
  chmod +x "$bin/brew"

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
    DOTFILES_APT_GET_CMD="$bin/apt-get" DOTFILES_SUDO_CMD= \
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
    'ca-certificates curl git stow fzf zoxide fd-find ripgrep nodejs npm graphviz shellcheck tar xz-utils' \
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
  HOME="$home" ZSH="$home/.oh-my-zsh" \
    ZSH_CUSTOM="$home/.oh-my-zsh/custom" PATH="/usr/bin:/bin" bash -c \
    '. "$1/scripts/provision-common.sh"; diagnose_common >/dev/null' shell "$REPO_ROOT" \
    2>/dev/null
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'common diagnostics reported a missing installation as healthy'
  [ -z "$(find "$home" -mindepth 1 -print -quit)" ] || fail 'diagnostics mutated HOME'
}

test_common_provisioning_is_idempotent_and_regenerates_completions
test_completion_failure_preserves_existing_set
test_completion_publication_failure_preserves_existing_set
test_first_completion_publication_has_one_atomic_entry
test_zsh_uses_atomic_completion_directory
test_zsh_discovers_generated_completions_through_the_atomic_pointer
test_incomplete_uv_installation_is_not_replaced
test_failed_remote_installer_cleans_temp_directory
test_failed_neovim_download_cleans_temp_directory
test_macos_packages_require_brew_and_never_upgrade
test_macos_diagnostics_accept_installed_outdated_formulas_and_name_missing_formula
test_debian_archive_install_and_fd_link
test_root_debian_provisioning_does_not_require_sudo
test_arm64_archive_name_and_read_only_diagnostics
printf 'ok - provisioning behavior\n'
