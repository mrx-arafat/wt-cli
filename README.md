# wt-cli

A tiny `wt` shell command for managing `git worktree`s by number instead of
by path. List, create, jump into, and remove worktrees without typing full
paths or branch names every time.

Works in **bash** and **zsh**. No dependencies beyond `git`, `awk`, and a
POSIX-ish shell.

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

## Install

One-liner:

```sh
curl -fsSL https://raw.githubusercontent.com/mrx-arafat/wt-cli/main/install.sh | bash
```

Or clone and run it yourself (read the script first if you'd rather not pipe
curl into a shell):

```sh
git clone https://github.com/mrx-arafat/wt-cli.git
cd wt-cli
./install.sh
```

The installer copies `wt.sh` to `~/.wt-cli/wt.sh` and appends one `source`
line to whichever of `~/.zshrc`, `~/.bashrc`, `~/.bash_profile` exist on your
machine (idempotent — running it again is a no-op). Restart your shell, or:

```sh
source ~/.wt-cli/wt.sh
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

## Why a shell function and not a script

`wt go <id>` changes your current shell's working directory. A subprocess
script can't do that — only something *sourced* into your interactive shell
can `cd` on your behalf. That's why this ships as a file you `source`, not a
binary on your `PATH`.

## Uninstall

```sh
rm -rf ~/.wt-cli
```

Then remove the `# wt-cli: ...` block it added to your `~/.zshrc` /
`~/.bashrc` / `~/.bash_profile`.

## License

MIT — see [LICENSE](LICENSE).
