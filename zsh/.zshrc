# Keep history at a useful size without relying on a machine-specific path.
HISTFILE="${ZDOTDIR:-$HOME}/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt EXTENDED_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE \
  HIST_REDUCE_BLANKS SHARE_HISTORY

# Static completions are published as one atomic release by provisioning.
typeset -U fpath
if [[ ${XDG_DATA_HOME:-} == /* ]]; then
  _dotfiles_data_home=$XDG_DATA_HOME
else
  _dotfiles_data_home=$HOME/.local/share
fi
fpath=("$_dotfiles_data_home/zsh/site-functions/.dotfiles-completions-current" $fpath)
unset _dotfiles_data_home

# Keep completion prefixes available to fzf-tab and label completion groups.
zstyle ':completion:*' menu no
zstyle ':completion:*:descriptions' format '[%d]'

# Native Zsh completion also discovers generated Herdr, UV, and UVX files.
autoload -Uz compinit
_dotfiles_zcompdump="${ZDOTDIR:-$HOME}/.zcompdump"
_dotfiles_zcompdump_stale=( "$_dotfiles_zcompdump"(N.mh+24) )
if [[ ! -s $_dotfiles_zcompdump || $#_dotfiles_zcompdump_stale -gt 0 ]]; then
  compinit -i -d "$_dotfiles_zcompdump"
else
  compinit -C -i -d "$_dotfiles_zcompdump"
fi
unset _dotfiles_zcompdump _dotfiles_zcompdump_stale

_dotfiles_source_plugin() {
  local plugin_name=$1
  local script_name=$2
  local share_dir
  local plugin_path
  local -a plugin_share_dirs

  plugin_share_dirs=()
  [[ ${HOMEBREW_PREFIX:-} == /* ]] &&
    plugin_share_dirs+=("$HOMEBREW_PREFIX/share")
  plugin_share_dirs+=(/opt/homebrew/share /usr/local/share /usr/share)

  for share_dir in "${plugin_share_dirs[@]}"; do
    plugin_path="$share_dir/$plugin_name/$script_name"
    if [[ -r $plugin_path ]]; then
      source "$plugin_path"
      return 0
    fi
  done
  return 1
}

# Keep user-installed tools available and avoid duplicate PATH entries.
typeset -U path
path=("$HOME/.local/bin" $path)

if (( $+commands[nvim] )); then
  export EDITOR='nvim'
  export VISUAL='nvim'
  export GIT_EDITOR='nvim'
  alias nv='nvim'
fi

if (( $+commands[zoxide] )); then
  eval "$(zoxide init zsh)"
fi

if (( $+commands[herdr] )); then
  alias h='herdr'
  alias hs='herdr status'
  alias hu='herdr update'
fi
case $OSTYPE in
  darwin*) alias ls='ls -G' ;;
  linux*) alias ls='ls --color=auto' ;;
esac
alias l='ls -lah'
alias ll='ls -lh'
alias la='ls -lAh'
alias gst='git status'
alias gt='git tree'
alias ga='git add'
alias gl='git pull'
alias gc='git commit --verbose'
alias gf='git fetch'
alias gco='git checkout'
alias grhh='git reset --hard'
alias gp='git push'
alias gd='git diff'

_dotfiles_init_fzf_fallback() {
  local script_root
  local -a fzf_script_roots

  fzf_script_roots=()
  [[ ${HOMEBREW_PREFIX:-} == /* ]] &&
    fzf_script_roots+=("$HOMEBREW_PREFIX/opt/fzf/shell")
  fzf_script_roots+=(
    /opt/homebrew/opt/fzf/shell
    /usr/local/opt/fzf/shell
    /usr/share/doc/fzf/examples
    /usr/share/fzf/shell
    /usr/share/fzf
  )

  for script_root in "${fzf_script_roots[@]}"; do
    if [[ -r "$script_root/key-bindings.zsh" &&
          -r "$script_root/completion.zsh" ]]; then
      source "$script_root/key-bindings.zsh" || return
      source "$script_root/completion.zsh" || return
      return 0
    fi
  done

  return 0
}

_dotfiles_init_fzf() {
  local fzf_init
  (( $+commands[fzf] )) || return 0

  if fzf_init=$(fzf --zsh 2>/dev/null); then
    eval "$fzf_init"
  else
    _dotfiles_init_fzf_fallback
  fi
}

_dotfiles_init_fzf

_dotfiles_source_fzf_tab() {
  local data_home
  local plugin_path
  local -a plugin_paths

  if [[ ${XDG_DATA_HOME:-} == /* ]]; then
    data_home=$XDG_DATA_HOME
  else
    data_home=$HOME/.local/share
  fi

  plugin_paths=()
  if [[ ${HOMEBREW_PREFIX:-} == /* ]]; then
    plugin_paths+=(
      "$HOMEBREW_PREFIX/opt/fzf-tab/share/fzf-tab/fzf-tab.zsh"
      "$HOMEBREW_PREFIX/share/fzf-tab/fzf-tab.zsh"
    )
  fi
  plugin_paths+=(
    "$data_home/zsh/plugins/fzf-tab/fzf-tab.zsh"
    /opt/homebrew/opt/fzf-tab/share/fzf-tab/fzf-tab.zsh
    /opt/homebrew/share/fzf-tab/fzf-tab.zsh
    /usr/local/opt/fzf-tab/share/fzf-tab/fzf-tab.zsh
    /usr/local/share/fzf-tab/fzf-tab.zsh
    /usr/share/fzf-tab/fzf-tab.zsh
  )

  for plugin_path in "${plugin_paths[@]}"; do
    if [[ -r $plugin_path ]]; then
      source "$plugin_path"
      return 0
    fi
  done
  return 1
}

# fzf-tab wraps the completion widget installed by compinit and fzf.
(( $+commands[fzf] )) && _dotfiles_source_fzf_tab || true

# Keep fzf-tab compact and useful in Herdr's inline terminal panes.
zstyle ':fzf-tab:*' fzf-flags \
  --height=40% \
  --border=rounded \
  '--color=fg:#c8d3f5,fg+:#c8d3f5,bg:#222436,bg+:#2d3f76,hl:#7dcfff,hl+:#7dcfff,info:#e0af68,prompt:#7aa2f7,pointer:#bb9af7,marker:#9ece6a,spinner:#bb9af7,header:#7dcfff,border:#444a73,separator:#444a73,scrollbar:#444a73'
zstyle ':fzf-tab:*' group-colors \
  $'\033[38;2;122;162;247m' $'\033[38;2;125;207;255m' \
  $'\033[38;2;158;206;106m' $'\033[38;2;224;175;104m' \
  $'\033[38;2;187;154;247m' $'\033[38;2;247;118;142m' \
  $'\033[38;2;115;218;202m' $'\033[38;2;192;202;245m' \
  $'\033[38;2;122;162;247m' $'\033[38;2;125;207;255m' \
  $'\033[38;2;158;206;106m' $'\033[38;2;224;175;104m' \
  $'\033[38;2;187;154;247m' $'\033[38;2;247;118;142m' \
  $'\033[38;2;115;218;202m' $'\033[38;2;192;202;245m'
zstyle ':fzf-tab:*' switch-group '<' '>'
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -la -- "$realpath"'

# Autosuggestions must load after fzf-tab and before local ZLE customizations.
_dotfiles_source_plugin zsh-autosuggestions zsh-autosuggestions.zsh || true

# Machine-local customizations are deliberately untracked and can override
# any repository-provided aliases or integrations above.
[[ -r "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"

# Starship owns the prompt when installed. Without it, native Zsh remains in
# charge and no fallback theme is selected.
export ZLE_RPROMPT_INDENT=0
if (( $+commands[starship] )); then
  eval "$(starship init zsh)"
fi

# Syntax highlighting must be loaded last so it can wrap every line-editor
# widget and any widgets added by local customization or Starship.
_dotfiles_source_plugin zsh-syntax-highlighting zsh-syntax-highlighting.zsh || true

# Reassert the prompt anchor contract after the final plugin has loaded.
ZLE_RPROMPT_INDENT=0

unset -f _dotfiles_source_plugin _dotfiles_init_fzf_fallback _dotfiles_init_fzf \
  _dotfiles_source_fzf_tab
