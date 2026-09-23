<div align="center">

# wt-cli

**The git worktree manager that lives in your shell.**
List, create, jump into, and remove worktrees by number or name - interactively or in one short command, with native `cd`, no subshells.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell: bash/zsh](https://img.shields.io/badge/shell-bash%20%7C%20zsh-89e051.svg)](#compatibility)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)](#compatibility)
[![Dependencies](https://img.shields.io/badge/dependencies-git%20%7C%20awk%20%7C%20curl-blue.svg)](#prerequisites)

</div>

---

`git worktree` is powerful and nobody remembers its syntax.
`wt` gives every worktree in your repo a number and a name, so day-to-day worktree juggling turns into one keypress or one short command instead of a copy-pasted path.

```
$ wt ls -p

wt · myapp · 3 worktree(s) + 12 stale

ID  STATE            NAME     BRANCH        SYNC  AGE  PATH
1   ✋😎🤚 clean     agent-7  @460fb96      -     1d   .worktrees/agent-7
2*  ✋😎🤚 clean     auth     feature-auth  ok    2h   .worktrees/auth
3   🍷     dirty 2   hotfix   hotfix-login  +2    10m  .worktrees/hotfix
🗿 12 stale entries (directory deleted, IDs 4-15) · wt prune to clean up · wt ls -a to show

$ wt             # same list, interactive: arrows, Enter for actions, d delete
$ wt go hotfix   # cd - in your REAL shell
$ wt rm 2-3      # shows what goes, asks, deletes
$ wt clean       # remove everything already merged
```

## Contents

- [Why](#why)
- [Install](#install)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Interactive mode](#interactive-mode)
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

No compiler, no package manager dependency of its own, nothing to build.
The interactive mode is plain shell too - no `fzf` or other optional tools needed.

## Quick start

```sh
cd your-repo

wt add feature-a          # worktree + branch at ./.worktrees/feature-a, cd in
# ... hack hack hack ...
wt main                   # back to the main checkout
wt                        # interactive: arrows, Enter for actions, q to quit
wt ls -p                  # plain table: state, name, branch, sync, age
wt exec feature-a npm test   # run tests there without leaving this dir
wt rm 2-4                 # delete worktrees 2, 3, 4 (shows what goes, asks first)
wt clean                  # remove everything already merged (confirms first)
```

## Interactive mode

Run `wt` (or `wt ls`) in a terminal and the table becomes navigable.
It draws inline under your prompt, like `fzf --height` - no full-screen takeover - and quitting leaves the plain table in your scrollback.

| Key | Action |
|---|---|
| `↑` `↓` / `j` `k`, `PgUp` `PgDn`, `Home` `End` | move |
| `Enter` | action menu for the highlighted worktree: go, open, status, exec, copy path, delete, cancel |
| `g` | `cd` into it - your real shell |
| `o` | open it in your editor |
| `s` | `git status` + recent log in your pager |
| `e` | run a command inside it |
| `y` | copy its path to the clipboard |
| `d` | delete the marked worktrees, or the highlighted one - asks first |
| `space` / `a` | mark / mark all |
| `/` | filter by name or branch |
| `n` | new worktree |
| `m` | jump to the main checkout |
| `p` | prune stale entries |
| `r` | refresh |
| `?` | show all keys |
| `q` / `Esc` | quit |

The delete confirm lists what will go and warns about uncommitted files or unpushed commits.
`y` deletes worktree and branch, `k` deletes the worktree but keeps the branch, anything else cancels.

`wt go` and `wt rm` with no arguments open the same picker - `Enter` goes, or deletes the marked set.
Piped output, or `wt ls -p`, is always the plain table, so scripts and AI agents never get an interactive screen.

## Commands

| Command | What it does |
|---|---|
| `wt` / `wt ls` | On a terminal: the [interactive manager](#interactive-mode). Piped, or with `-p`/`--plain`: numbered table of every linked worktree - ID, state, name, branch, ahead/behind sync, last-commit age, path. `-a`/`--all` lists stale entries one by one |
| `wt add <name> [base]` | Create a worktree at `<repo>/.worktrees/<name>` on a branch named `<name>`, copy `wt.copy` files, run the `wt.postadd` hook, then `cd` into it. Reuses the branch if it exists locally or on `origin`; otherwise creates it from `[base]` (default `HEAD`) |
| `wt go [target]` | `cd` into a worktree. No argument: interactive picker |
| `wt main` | `cd` back to the main checkout from anywhere |
| `wt exec <target> <cmd...>` | Run a command inside a worktree without leaving your current directory |
| `wt open <target>` | Open a worktree in your editor (`wt.editor` config, else `$VISUAL`/`$EDITOR`) |
| `wt pr <number>` | Fetch a GitHub pull request (`pull/N/head`) into a `pr/N` worktree |
| `wt status` | `git status -sb` for every linked worktree, with state and sync badges |
| `wt rm <selector...>` | Delete worktree(s) and their local branches. Selectors: `2 4 5`, `2,4,5`, `2-5`, a target, `all` (or `-a`/`--all`). `-k`/`--keep-branch` keeps branches, `-y`/`--yes` skips the prompt. No argument: multi-select picker |
| `wt clear` | Same as `wt rm all` |
| `wt clean` | Remove every worktree whose branch is fully merged into the default branch. Skips dirty trees, lists what it will remove, asks once |
| `wt prune` | Drop stale entries - worktrees git still tracks whose directory was deleted |
| `wt help` / `wt version` | Show the command list / version |

A **target** is an ID, a worktree name (its directory name - what you passed to `wt add`), a branch, or a unique case-insensitive substring of either.
`.` is the worktree you are in.

IDs are positions, **recomputed every call** - not stored.
Live worktrees are numbered first and stale entries last, so the numbers you use stay small.
Names don't shift, so prefer them in scripts: `wt rm hotfix`.

### Deleting worktrees

`wt rm` removes the worktree (`git worktree remove --force`) and its local branch (`git branch -D`).
On a terminal it first shows what will be deleted and asks.
The default answer is Yes when nothing would be lost, and No - with a ⚠ warning - when a target has uncommitted files or unpushed commits.
`-y` skips the prompt; scripts and agents (no terminal) are never prompted, same as before.

If your shell is inside a worktree you delete, `wt` moves it to the main checkout first.
The default branch is never deleted, locked worktrees are skipped, and an invalid selector aborts before anything is removed.
Your main checkout is never touched.

`wt clean` is the polite sibling: it only offers branches already merged into your default branch, never touches dirty trees, and asks before acting.

Tab completion for subcommands, worktree names, and branches is registered automatically for bash and zsh when you source `wt.sh`.

## Status badges

| Badge | State | Meaning |
|---|---|---|
| ✋😎🤚 | `clean` | no uncommitted changes to tracked files |
| 🍷 | `dirty` | uncommitted changes to tracked files |
| 🗿🤙🏻 | `missing` | git still tracks it, but the directory is gone - listed last, collapsed into one line, dropped by `wt prune` |

Untracked files don't mark a tree dirty - `wt.copy` drops env files into every new worktree, and those would otherwise flag every tree forever.
Deleting is stricter: the `wt rm` confirm does warn about untracked files, because those are lost for good.

The SYNC column compares each worktree to its upstream: `ok` in sync, `+2` two commits ahead, `-3` three behind, `+2-1` diverged, `-` no upstream.

Detached worktrees show `@<sha>` in the BRANCH column.
A `*` after an ID marks the worktree you are in.
Columns shrink to fit your terminal width, and paths inside the repo are shown relative to it (`.worktrees/auth`).

## Config

All configuration lives in `git config` - per-repo by default, `--global` if you want it everywhere.
No dotfiles, no YAML.

```sh
# Files/globs copied from the main checkout into every new worktree.
# The classic use: git-ignored .env files your app needs to boot.
git config wt.copy ".env .env.local"

# Command run inside every new worktree after creation.
git config wt.postadd "npm install"

# Editor used by `wt open` and the `o` key (falls back to $VISUAL, then $EDITOR).
git config wt.editor "code"
```

Everything works with zero config - these just remove the per-worktree setup chores.

## wt vs. other worktree tools

| | plain `git` | phantom / gwq (binaries) | `wt` |
|---|---|---|---|
| See all worktrees + dirty state | script it yourself | yes | `wt ls` |
| Browse, open, and delete from one screen | - | varies | `wt` interactive mode |
| `cd` into a worktree | copy the path manually | subshell or shell-integration setup | native - `wt go 2` or `wt go auth` |
| Sync (ahead/behind) at a glance | script it yourself | partial | `wt ls` SYNC column |
| Copy .env + run setup on create | manual | config file (TOML/JSON) | 2 lines of `git config` |
| Delete several at once | one path at a time | varies | `wt rm 2-5`, or mark + `d` |
| Remove merged worktrees | write your own loop | varies | `wt clean` |
| PR checkout into a worktree | fetch + add by hand | yes (needs `gh`) | `wt pr 123` (pure git) |
| Install footprint | - | binary + completion setup | one sourced shell file |

## How it works

`_wt_list_raw()` parses `git worktree list --porcelain` - git's machine-readable format - with `awk`, skips your main checkout, and numbers the rest: live worktrees first, stale entries last.

`wt ls` runs `git status` for every worktree in parallel and fetches all last-commit ages with a single `git log` call, so the table stays fast with dozens of worktrees.

`wt go <target>` changes your **current shell's** working directory.
A subprocess can't do that; only something *sourced* into your interactive shell can `cd` on your behalf.
That's why `wt.sh` is meant to be `source`d, not put on your `PATH` as an executable.
The interactive mode runs inside your shell the same way, so picking "go" really does `cd`.

Worktrees are created under `<repo>/.worktrees/`, which `wt` adds to `.git/info/exclude` automatically - your tracked `.gitignore` is never touched.
`wt add` anchors on the main checkout even when you run it from inside another worktree, so trees never nest.
`wt add <name>` always lands on a branch called `<name>` - a tag or commit with the same name no longer yields a detached worktree - and invalid branch names are rejected before anything is created.
It only asks the network about `origin` when no local or remote-tracking ref already matches.

## Compatibility

Tested on bash 3.2+ (macOS default) and 5.x, and zsh 5.x, on macOS and Linux.

Shell portability notes baked into the code, learned the hard way:

- zsh ties a lowercase `path` array to `$PATH` - naming a loop variable `path` silently breaks every `git` call after the first assignment (`wt.sh` uses `wtpath`).
- zsh's builtin `echo` swallows a lone `-` argument (option terminator) - `wt.sh` uses `printf` wherever a value can be a bare dash.
- A bare `local x` on an already-declared local **prints** its value in zsh - loop locals are declared once, then assigned.
- `printf %-Ns` pads by bytes, not display cells - emoji columns are hand-padded.
- bash 3.2's `read -t` only takes whole seconds - a bare `Esc` in interactive mode can take up to a second to register there; `q` quits instantly.

Fish uses fundamentally different syntax and isn't supported (PRs welcome).

## Troubleshooting

**`wt: command not found`** - restart your shell, or run `source ~/.wt-cli/wt.sh`.

**`wt: not inside a git repo`** - `wt` operates on the repo in your current directory; `cd` into one first.

**My worktree's name was missing from the list** - fixed in v3.
Older versions showed only the branch, so a worktree whose branch you switched, or whose HEAD was detached (agents, tags, rebases), lost its name.
The NAME column now always shows the directory name, and `wt go <name>` / `wt rm <name>` work with it.

**IDs shifted / don't match what I expected** - they're recomputed from `git worktree list` every call, not stored.
Stale entries now sort last, so live IDs stay put; `wt prune` removes the stale ones, and names never shift.

**I just want the plain table** - `wt ls -p`.
Piped or redirected output is always plain.

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
