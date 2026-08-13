<div align="center">

# wt-cli

**Stop typing full paths and branch names to manage `git worktree`.**
List, create, jump into, and remove worktrees by number.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell: bash/zsh](https://img.shields.io/badge/shell-bash%20%7C%20zsh-89e051.svg)](#compatibility)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)](#compatibility)
[![Dependencies](https://img.shields.io/badge/dependencies-git%20%7C%20awk%20%7C%20curl-blue.svg)](#prerequisites)

</div>

---

`git worktree` is powerful and nobody remembers its syntax. `wt` gives every
worktree in your repo a number, so day-to-day worktree juggling turns into
one short command instead of a copy-pasted path.

```
$ wt list
ID   STATE    PATH                                    BRANCH
1    clean    ~/code/myapp-worktrees/feature-a         feature-a
2    dirty    ~/code/myapp-worktrees/hotfix-1          hotfix-1
3    missing  ~/code/myapp-worktrees/old-experiment    old-experiment

$ wt go 1
$ pwd
~/code/myapp-worktrees/feature-a

$ wt rm 3
Removing #3: ~/code/myapp-worktrees/old-experiment (branch: old-experiment)
```

## Contents

- [Why](#why)
- [Install](#install)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Commands](#commands)
- [wt vs. plain git worktree](#wt-vs-plain-git-worktree)
- [How it works](#how-it-works)
- [Compatibility](#compatibility)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Contributing](#contributing)
- [License](#license)

## Why

`git worktree` lets you check out several branches into sibling directories
at once — no more stashing to switch context. The catch: every one of its
subcommands wants a full path, and there's no built-in way to `cd` into one,
see which are dirty at a glance, or tear several down at once. `wt` is a thin
layer that fixes exactly that, and nothing else.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/mrx-arafat/wt-cli/main/install.sh | bash
```

Prefer not to pipe curl into a shell? Read the script first, then run it:

```sh
git clone https://github.com/mrx-arafat/wt-cli.git
cd wt-cli
cat install.sh   # read it
./install.sh
```

The installer:

1. Checks that `git`, `awk`, and `curl` are available — if not, prints the
   exact command to install them for your OS and exits (no silent `sudo`).
2. Copies `wt.sh` to `~/.wt-cli/wt.sh`.
3. Appends one `source` line to whichever of `~/.zshrc`, `~/.bashrc`,
   `~/.bash_profile` exist on your machine.

It's idempotent — run it again anytime (e.g. to pick up an update) and it
won't duplicate anything. Restart your shell afterward, or:

```sh
source ~/.wt-cli/wt.sh
```

## Prerequisites

| Tool | Why | Almost always already installed |
|---|---|---|
| `git` ≥ 2.5 | worktrees are a git feature | Yes, on any dev machine |
| `bash` or `zsh` | `wt` is a shell function | Yes, both ship on macOS and every mainstream Linux distro |
| `awk`, `curl` | parsing `git worktree list` output, fetching the script | Yes |

No compiler, no package manager dependency of its own, nothing to build.

## Quick start

```sh
cd your-repo

wt add feature-a          # new worktree + branch at ./.worktrees/feature-a
wt list                   # see it, numbered
wt go 1                   # cd into it
wt status                 # git status -sb across every worktree
wt rm 1                   # done with it — remove worktree + branch
```

## Commands

| Command | What it does |
|---|---|
| `wt` / `wt list` | Numbered table of every linked worktree in the current repo (ID, dirty/clean/missing state, path, branch) |
| `wt add <branch> [base]` | Create a worktree for `<branch>` at `<repo>/.worktrees/<branch>`. Reuses the branch if it exists locally or on `origin`; otherwise creates it from `[base]` (default `HEAD`) |
| `wt go <id>` | `cd` into the worktree with that ID |
| `wt status` | `git status -sb` for every linked worktree, one after another |
| `wt rm <id> [id...] [--keep-branch]` | Force-remove the worktree(s) at those IDs. Deletes the local branch too, unless `--keep-branch` |
| `wt clear` | Force-remove **every** linked worktree in the repo, and their local branches |
| `wt help` | Show the command list |

IDs come from `wt list` and are **recomputed every call** — they're
positions in `git worktree list`, not stored IDs. Run `wt list` right before
`wt rm` if you're not sure the numbering hasn't shifted.

`wt rm` and `wt clear` are destructive (`git worktree remove --force` +
`git branch -D`). They only touch worktrees git already knows about; they
never touch your main checkout.

## wt vs. plain git worktree

| Task | Plain `git` | `wt` |
|---|---|---|
| See all worktrees, with dirty state | `git worktree list` (no dirty indicator — you'd script your own loop) | `wt list` |
| Jump into one | no built-in way — copy the path, `cd` manually | `wt go 2` |
| Remove one, including its branch | `git worktree remove --force <path> && git branch -D <branch>` | `wt rm 2` |
| Remove everything | write your own loop | `wt clear` |

## How it works

`_wt_list_raw()` parses `git worktree list --porcelain` — git's
machine-readable format, blocks of `worktree <path>` / `branch <ref>`
separated by blank lines — with `awk`, skips your main checkout, and numbers
the rest.

`wt go <id>` changes your **current shell's** working directory. A
subprocess script can't do that; only something *sourced* into your
interactive shell can `cd` on your behalf. That's why `wt.sh` is meant to be
`source`d, not put on your `PATH` as an executable.

## Compatibility

Tested on bash 3.2+ (macOS default) and 5.x, and zsh 5.x, on macOS and Linux.

If you're extending this for another shell: zsh ties a lowercase `path`
array to `$PATH`. Naming a loop variable `path` silently breaks every `git`
call after the first assignment — `wt.sh` uses `wtpath` deliberately. Fish
uses fundamentally different syntax and isn't supported (PRs welcome).

## Troubleshooting

**`wt: command not found`** — restart your shell, or run
`source ~/.wt-cli/wt.sh`.

**`wt: not inside a git repo`** — `wt` operates on the repo in your current
directory; `cd` into one first.

**IDs don't match what I expected** — they're recomputed from
`git worktree list` every call, not stored. Run `wt list` again right before
`wt rm`/`wt go`.

## Uninstall

```sh
rm -rf ~/.wt-cli
```

Then remove the `# wt-cli: ...` block it added to your `~/.zshrc` /
`~/.bashrc` / `~/.bash_profile`.

## Contributing

Issues and PRs welcome — [github.com/mrx-arafat/wt-cli](https://github.com/mrx-arafat/wt-cli).
It's one shell file; keep changes small, test under both bash and zsh before
opening a PR.

## License

MIT — see [LICENSE](LICENSE).
