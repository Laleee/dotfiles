# Oh My Zsh is optional, so retain a usable shell when it is not installed.
export ZSH="${ZSH:-$HOME/.oh-my-zsh}"
export ZSH_CUSTOM="${ZSH_CUSTOM:-$ZSH/custom}"
ZSH_THEME="robbyrussell"

# Keep history at a useful size without relying on a machine-specific path.
HISTFILE="${ZDOTDIR:-$HOME}/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000

# Static completions are installed separately; expose them before Oh My Zsh
# initializes completion.
typeset -U fpath
fpath=("${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions" $fpath)

# Enable only plugins that are available. Custom plugins use the conventional
# Oh My Zsh locations under $ZSH_CUSTOM/plugins.
plugins=(git)
if [[ -r "$ZSH_CUSTOM/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]]; then
  plugins+=(zsh-autosuggestions)
fi
if (( $+commands[fzf] )) && [[ -d "$ZSH/plugins/fzf" ]]; then
  plugins+=(fzf)
fi

if [[ -r "$ZSH/oh-my-zsh.sh" ]]; then
  source "$ZSH/oh-my-zsh.sh"
elif [[ -r "$ZSH_CUSTOM/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]]; then
  source "$ZSH_CUSTOM/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
fi

export EDITOR='nvim'
export VISUAL='nvim'
export GIT_EDITOR='nvim'

# Keep user-installed tools available and avoid duplicate PATH entries.
typeset -U path
path=("$HOME/.local/bin" $path)

if (( $+commands[zoxide] )); then
  eval "$(zoxide init zsh)"
fi

if (( $+commands[herdr] )); then
  alias h='herdr'
  alias hs='herdr status'
  alias hu='herdr update'
fi
alias nv='nvim'

# Machine-local customizations are deliberately untracked.
[[ -r "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"

# Load syntax highlighting last so it can wrap every line-editor widget.
if [[ -r "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]]; then
  source "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi
