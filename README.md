<div align="center">

# wt-cli

**The git worktree manager that lives in your shell.**
List, create, jump into, and remove worktrees by number - with native `cd`, no subshells.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell: bash/zsh](https://img.shields.io/badge/shell-bash%20%7C%20zsh-89e051.svg)](#compatibility)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)](#compatibility)
[![Dependencies](https://img.shields.io/badge/dependencies-git%20%7C%20awk%20%7C%20curl-blue.svg)](#prerequisites)

</div>

---

`git worktree` is powerful and nobody remembers its syntax.
`wt` gives every worktree in your repo a number, so day-to-day worktree juggling turns into one short command instead of a copy-pasted path.

```
$ wt list

wt · 3 worktree(s) in myapp

ID   STATE            SYNC     AGE    BRANCH           PATH
1    ✋😎🤚 clean    ok       2h     feature-auth     ~/code/myapp/.worktrees/feature-auth
2    🍷     dirty    +2       10m    hotfix-login     ~/code/myapp/.worktrees/hotfix-login
3    🗿🤙🏻   missing  -        3w     old-experiment   ~/code/myapp/.worktrees/old-experiment

$ wt go 1        # cd - in your REAL shell
$ wt exec 2 npm test
$ wt clean       # remove everything already merged
```

## Contents

- [Why](#why)
- [Install](#install)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Status badges](#status-badges)
- [Config](#config)
- [wt vs. other worktree tools](#wt-vs-other-worktree-tools)
- [How it works](#how-it-works)
- [Compatibility](#compatibility)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Contributing](#contributing)
- [License](#license)

## Why

`git worktree` lets you check out several branches into separate directories at once - no more stashing to switch context.
It is also the backbone of parallel AI-agent workflows: one agent per worktree, zero merge conflicts while they work.

The catch: every worktree subcommand wants a full path, there is no built-in way to `cd` into one, no dirty/ahead/behind overview, and no bulk teardown.
`wt` is a thin layer that fixes exactly that, and nothing else.

Because `wt` is **sourced into your shell** instead of running as a subprocess, `wt go` and `wt add` change your real shell's directory.
Standalone binaries physically cannot do this - they either spawn nested subshells or need per-shell integration hacks.

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

1. Checks that `git`, `awk`, and `curl` are available - if not, prints the exact command to install them for your OS and exits (no silent `sudo`).
2. Copies `wt.sh` to `~/.wt-cli/wt.sh`.
3. Appends one `source` line to whichever of `~/.zshrc`, `~/.bashrc`, `~/.bash_profile` exist on your machine.

It's idempotent - run it again anytime (e.g. to pick up an update) and it won't duplicate anything.
Restart your shell afterward, or:

```sh
source ~/.wt-cli/wt.sh
```

## Prerequisites

| Tool | Why | Almost always already installed |
|---|---|---|
| `git` ≥ 2.5 | worktrees are a git feature | Yes, on any dev machine |
| `bash` or `zsh` | `wt` is a shell function | Yes, both ship on macOS and every mainstream Linux distro |
| `awk`, `curl` | parsing `git worktree list` output, fetching the script | Yes |
| `fzf` (optional) | fuzzy picker for `wt go` with no arguments | Falls back to a numbered menu |

No compiler, no package manager dependency of its own, nothing to build.

## Quick start

```sh
cd your-repo

wt add feature-a          # worktree + branch at ./.worktrees/feature-a, cd in
# ... hack hack hack ...
wt main                   # back to the main checkout
wt list                   # see every worktree: state, sync, age
wt exec feature-a npm test   # run tests there without leaving this dir
wt clean                  # remove everything already merged (confirms first)
```

## Commands

| Command | What it does |
|---|---|
| `wt` / `wt list` | Numbered table of every linked worktree: ID, state, ahead/behind sync, last-commit age, branch, path |
| `wt add <branch> [base]` | Create a worktree at `<repo>/.worktrees/<branch>`, copy `wt.copy` files, run the `wt.postadd` hook, then `cd` into it. Reuses the branch if it exists locally or on `origin`; otherwise creates it from `[base]` (default `HEAD`) |
| `wt go [id\|branch]` | `cd` into a worktree. Accepts an ID, an exact branch, or a unique branch substring. With no argument: fzf picker if `fzf` is installed, else a numbered menu |
| `wt main` | `cd` back to the main checkout from anywhere |
| `wt exec <id\|branch> <cmd...>` | Run a command inside a worktree without leaving your current directory |
| `wt open <id\|branch>` | Open a worktree in your editor (`wt.editor` config, else `$VISUAL`/`$EDITOR`) |
| `wt pr <number>` | Fetch a GitHub pull request (`pull/N/head`) into a `pr/N` worktree |
| `wt status` | `git status -sb` for every linked worktree, with state and sync badges |
| `wt clean` | Remove every worktree whose branch is fully merged into the default branch. Skips dirty trees, lists what it will remove, asks once |
| `wt rm <id> [id...] [--keep-branch]` | Force-remove the worktree(s) at those IDs. Deletes the local branch too, unless `--keep-branch` |
| `wt clear` | Force-remove **every** linked worktree in the repo, and their local branches |
| `wt help` / `wt version` | Show the command list / version |

IDs come from `wt list` and are **recomputed every call** - they're positions in `git worktree list`, not stored IDs.
Run `wt list` right before `wt rm` if you're not sure the numbering hasn't shifted.

`wt rm` and `wt clear` are destructive (`git worktree remove --force` + `git branch -D`).
They only touch worktrees git already knows about; they never touch your main checkout.
`wt clean` is the polite sibling: it only offers branches already merged into your default branch, never touches dirty trees, and asks before acting.

Tab completion for subcommands and branch names is registered automatically for bash and zsh when you source `wt.sh`.

## Status badges

| Badge | State | Meaning |
|---|---|---|
| ✋😎🤚 | `clean` | no uncommitted changes to tracked files |
| 🍷 | `dirty` | uncommitted changes to tracked files |
| 🗿🤙🏻 | `missing` | git still tracks it, but the directory is gone |

Untracked files don't mark a tree dirty - `wt.copy` drops env files into every new worktree, and those would otherwise flag every tree forever.

The SYNC column compares each worktree to its upstream: `ok` in sync, `+2` two commits ahead, `-3` three behind, `+2-1` diverged, `-` no upstream.

## Config

All configuration lives in `git config` - per-repo by default, `--global` if you want it everywhere.
No dotfiles, no YAML.

```sh
# Files/globs copied from the main checkout into every new worktree.
# The classic use: git-ignored .env files your app needs to boot.
git config wt.copy ".env .env.local"

# Command run inside every new worktree after creation.
git config wt.postadd "npm install"

# Editor used by `wt open` (falls back to $VISUAL, then $EDITOR).
git config wt.editor "code"
```

Everything works with zero config - these just remove the per-worktree setup chores.

## wt vs. other worktree tools

| | plain `git` | phantom / gwq (binaries) | `wt` |
|---|---|---|---|
| See all worktrees + dirty state | script it yourself | yes | `wt list` |
| `cd` into a worktree | copy the path manually | subshell or shell-integration setup | native - `wt go 2` |
| Sync (ahead/behind) at a glance | script it yourself | partial | `wt list` SYNC column |
| Copy .env + run setup on create | manual | config file (TOML/JSON) | 2 lines of `git config` |
| Remove merged worktrees | write your own loop | varies | `wt clean` |
| PR checkout into a worktree | fetch + add by hand | yes (needs `gh`) | `wt pr 123` (pure git) |
| Install footprint | - | binary + completion setup | one sourced shell file |

## How it works

`_wt_list_raw()` parses `git worktree list --porcelain` - git's machine-readable format - with `awk`, skips your main checkout, and numbers the rest.

`wt go <id>` changes your **current shell's** working directory.
A subprocess can't do that; only something *sourced* into your interactive shell can `cd` on your behalf.
That's why `wt.sh` is meant to be `source`d, not put on your `PATH` as an executable.

Worktrees are created under `<repo>/.worktrees/`, which `wt` adds to `.git/info/exclude` automatically - your tracked `.gitignore` is never touched.
`wt add` anchors on the main checkout even when you run it from inside another worktree, so trees never nest.

## Compatibility

Tested on bash 3.2+ (macOS default) and 5.x, and zsh 5.x, on macOS and Linux.

Shell portability notes baked into the code, learned the hard way:

- zsh ties a lowercase `path` array to `$PATH` - naming a loop variable `path` silently breaks every `git` call after the first assignment (`wt.sh` uses `wtpath`).
- zsh's builtin `echo` swallows a lone `-` argument (option terminator) - `wt.sh` uses `printf` wherever a value can be a bare dash.
- A bare `local x` on an already-declared local **prints** its value in zsh - loop locals are declared once, then assigned.
- `printf %-Ns` pads by bytes, not display cells - emoji columns are hand-padded.

Fish uses fundamentally different syntax and isn't supported (PRs welcome).

## Troubleshooting

**`wt: command not found`** - restart your shell, or run `source ~/.wt-cli/wt.sh`.

**`wt: not inside a git repo`** - `wt` operates on the repo in your current directory; `cd` into one first.

**IDs don't match what I expected** - they're recomputed from `git worktree list` every call, not stored.
Run `wt list` again right before `wt rm`/`wt go`.

**`wt pr` fails** - it uses GitHub's `pull/N/head` refspec, which only exists on GitHub remotes.

**Colors look wrong / I want plain output** - set `NO_COLOR=1`.
Output degrades to plain automatically when piped or redirected.

## Uninstall

```sh
rm -rf ~/.wt-cli
```

Then remove the `# wt-cli: ...` block it added to your `~/.zshrc` / `~/.bashrc` / `~/.bash_profile`.

## Contributing

Issues and PRs welcome - [github.com/mrx-arafat/wt-cli](https://github.com/mrx-arafat/wt-cli).
It's one shell file; keep changes small, test under both bash and zsh before opening a PR.

## License

MIT - see [LICENSE](LICENSE).
