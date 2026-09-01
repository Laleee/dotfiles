# Portable dotfiles

Portable Zsh, Neovim/LazyVim, Markdownlint, and Herdr configuration. Supported
platforms are macOS with Homebrew and current Debian/Ubuntu, each on `x86_64`
or `arm64` only. Deployment uses GNU Stow with `--no-folding`.

## First install

Clone your fork (or another local copy) and run the machine setup entry point
from the repository root:

```sh
git clone <your-dotfiles-repository> ~/src/dotfiles
cd ~/src/dotfiles
./setup.sh
```

On macOS, install Homebrew before running the script. On Debian/Ubuntu, the
script uses `apt-get` through `sudo` when necessary and includes `zsh` and the
`build-essential` compiler toolchain. The script installs only missing
dependencies, clones only missing shell dependencies, and deploys the `zsh`,
`nvim`, and `herdr` Stow packages to `$HOME`. It does not silently upgrade
installed packages, user-local tools, or existing clones.

`setup.sh` is only an orchestrator: it runs a dotfile conflict preflight, calls
the matching existing `scripts/provision-macos.sh` or
`scripts/provision-debian.sh` provisioner, and then calls `bootstrap.sh` to
deploy configuration. `bootstrap.sh` itself never installs packages, downloads
tools, clones plugins, or generates completions.

Before provisioning, setup checks all five managed targets below. If one
already exists but is not managed by this repository, it prints the exact path
and stops without provisioning or changing `$HOME`. Once that preflight is
clear, setup provisions the machine and bootstrap simulates the Stow deployment
before creating links:

- `~/.zshrc` and `~/.zprofile`
- `~/.config/nvim`
- `~/.config/markdownlint/.markdownlint.yaml`
- `~/.config/herdr/config.toml`

To deploy only the repository configuration on an already provisioned machine,
run:

```sh
./bootstrap.sh
```

## Check before changing anything

Run the read-only preflight at any time:

```sh
./setup.sh --check
```

It runs the platform provisioner's diagnostics and bootstrap's managed-path
conflict check. Together they check the platform, package/dependency presence,
usable commands, Neovim version 0.11.2 or newer, Tree-sitter CLI, static Zsh
completions, and dotfile conflicts. It does not provision, deploy links,
migrate files, upgrade an existing tool, or change the login shell. Exit status
`0` means both checks passed, `1` means a checked prerequisite or target needs
attention, and `2` means an invalid argument or unsupported platform.

To check only whether the managed dotfile targets and their parent paths are
clear, without requiring the provisioning tools to be installed, run
`./bootstrap.sh --check`.

## Adopt an existing machine

After reviewing the paths above, explicitly adopt conflicting configuration:

```sh
./setup.sh --migrate
```

Setup provisions the machine first, then bootstrap moves only unmanaged managed
paths to a timestamped backup before deploying. If the machine is already
provisioned, `./bootstrap.sh --migrate` performs only the migration and
deployment. The backup is at
`$XDG_STATE_HOME/dotfiles-backups/<UTC-timestamp>` (or, by default,
`~/.local/state/dotfiles-backups/<UTC-timestamp>`). The script prints the
backup path on a successful migration. It attempts an automatic rollback if
deployment fails.

Only absolute `XDG_STATE_HOME` and `XDG_DATA_HOME` values are honored. Relative
values safely fall back to `~/.local/state` and `~/.local/share`, respectively,
so backup and completion paths cannot escape through the working directory.

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
setup. Provisioning and deployment are intended to be idempotent.

```sh
git pull --ff-only
./setup.sh
```

Use `./bootstrap.sh` instead when only repository-managed configuration changed
and you do not want to run provisioning.

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
provisioning.

Provisioning also leaves an existing Neovim or Tree-sitter CLI installation in
place. If `./setup.sh --check` reports an old Neovim, update it manually through
its package manager or the upstream installation procedure; provisioning will
not replace it automatically.

Changing the login shell is also manual. After confirming the desired `zsh`
path is allowed by `/etc/shells`, run the following and then start a new login
session:

```sh
chsh -s "$(command -v zsh)"
```

## Neovim and optional tools

LazyVim requires Neovim **0.11.2 or newer**. Linux provisioning installs the
official stable Neovim archive under `~/.local/opt/nvim` and, when the path is
free, publishes it as `~/.local/bin/nvim`; macOS obtains Neovim from the
Brewfile. The deployed Zsh configuration adds `~/.local/bin` to `PATH`.

LazyVim parser support also requires the Tree-sitter CLI and a C compiler.
macOS gets `tree-sitter-cli` from the Brewfile. Debian/Ubuntu gets the compiler
through `build-essential`; when `tree-sitter` is missing, the Debian provisioner
installs it once in the user prefix with:

```sh
npm install --global --prefix "$HOME/.local" tree-sitter-cli
```

An existing `tree-sitter` command is never silently upgraded. A Nerd Font v3
is optional but enables editor icons.
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
