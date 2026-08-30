# Portable dotfiles

Portable Zsh, Neovim/LazyVim, Markdownlint, and Herdr configuration. Supported
platforms are macOS with Homebrew and current Debian/Ubuntu, each on `x86_64`
or `arm64` only. Deployment uses GNU Stow with `--no-folding`.

## First install

Clone your fork (or another local copy) and run the bootstrap script from the
repository root:

```sh
git clone <your-dotfiles-repository> ~/src/dotfiles
cd ~/src/dotfiles
./bootstrap.sh
```

On macOS, install Homebrew before running the script. On Debian/Ubuntu, the
script uses `apt-get` through `sudo` when necessary. The script installs only
missing dependencies, clones only missing shell dependencies, and deploys the
`zsh`, `nvim`, and `herdr` Stow packages to `$HOME`. It does not silently
upgrade installed packages or existing clones.

After provisioning completes, the default run simulates the Stow deployment
before it creates links. If one of these managed paths already exists but is
not managed by this repository, it stops without changing it:

- `~/.zshrc` and `~/.zprofile`
- `~/.config/nvim`
- `~/.config/markdownlint/.markdownlint.yaml`
- `~/.config/herdr/config.toml`

## Check before changing anything

Run the read-only preflight at any time:

```sh
./bootstrap.sh --check
```

It checks the platform, package/dependency presence, command availability, and
static Zsh completions. It does not provision, deploy links, migrate files, or
change the login shell. Exit status `0` means the checked prerequisites are
present, `1` means a checked prerequisite is missing, and `2` means an invalid
argument or unsupported platform. A nonzero result on a fresh machine is useful
preflight information, not a command to ignore; install the reported
prerequisites with the normal bootstrap flow when ready.

## Adopt an existing machine

After reviewing the paths above, explicitly adopt conflicting configuration:

```sh
./bootstrap.sh --migrate
```

`--migrate` moves only unmanaged managed paths to a timestamped backup before
deploying. The backup is at
`$XDG_STATE_HOME/dotfiles-backups/<UTC-timestamp>` (or, by default,
`~/.local/state/dotfiles-backups/<UTC-timestamp>`). The script prints the
backup path on a successful migration. It attempts an automatic rollback if
deployment fails.

For a manual rollback, use the backup directory printed by that migration:

```sh
backup_dir="<exact absolute backup path printed by --migrate>"
for path in \
  .zshrc \
  .zprofile \
  .config/nvim \
  .config/markdownlint/.markdownlint.yaml \
  .config/herdr/config.toml
do
  [ -e "$backup_dir/$path" ] || [ -L "$backup_dir/$path" ] || continue
  rm -rf "$HOME/$path"
  parent=${path%/*}
  [ "$parent" = "$path" ] && parent=.
  mkdir -p "$HOME/$parent"
  mv "$backup_dir/$path" "$HOME/$path"
done
```

Only restore paths that exist in that backup, and inspect the commands before
running: the loop removes only newly deployed versions of backed-up managed
paths. Herdr runtime data (such as history, caches, and other state) is never
tracked or moved; only `config.toml` is managed.

## Updates and customization

To update this checkout, review and fast-forward your chosen remote, then rerun
the bootstrap script. Repeating bootstrap is intended to be idempotent.

```sh
git pull --ff-only
./bootstrap.sh
```

The repository does not create, configure, or push a Git remote. To customize
it, fork it in your Git host's UI, clone your fork, and make normal Git changes
there. Keep machine-specific Zsh settings, aliases, and secrets out of the
repository in `~/.zshrc.local`; it is sourced when present before syntax
highlighting.

The installers deliberately do not update existing tools. If `uv` and Herdr
were installed by their respective direct installers, update them with their
own commands:

```sh
uv self update
herdr update
```

Use those commands only for installer-managed installations, not copies managed
by Homebrew or another package manager. Existing Homebrew copies of UV, Herdr,
or shell plugins should be cleaned up only after the Stow configuration and
login-shell tools have been verified; cleanup is intentionally outside
bootstrap.

Changing the login shell is also manual. After confirming the desired `zsh`
path is allowed by `/etc/shells`, run the following and then start a new login
session:

```sh
chsh -s "$(command -v zsh)"
```

## Neovim and optional tools

LazyVim requires Neovim **0.11.2 or newer**. Linux provisioning installs the
official stable Neovim archive under `~/.local/opt/nvim`; macOS obtains Neovim
from the Brewfile. A Nerd Font v3 is optional but enables editor icons.
`lazygit` is optional for the editor integration; it is included in the macOS
Brewfile and can be installed separately on Linux if desired.

Shell completion files for `herdr`, `uv`, and `uvx` are generated statically
during provisioning and loaded from the current completion release. They do not
run a tool on every shell startup. The Zsh configuration has a warm-start target
of a median of no more than 350 ms, without startup warnings.

## Upstream references

- [LazyVim requirements and installation](https://www.lazyvim.org/) — Neovim
  version requirement, optional Nerd Font v3 icons, and optional lazygit.
- [Neovim installation guide](https://github.com/neovim/neovim/blob/master/INSTALL.md)
- [UV installation guide](https://docs.astral.sh/uv/getting-started/installation/)
- [Herdr installation guide](https://herdr.dev/docs/install/)
