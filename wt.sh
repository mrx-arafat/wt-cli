# wt-cli: git worktree manager (bash + zsh)
# https://github.com/mrx-arafat/wt-cli
#
# This file is meant to be SOURCED, not executed:
#   source /path/to/wt.sh
#
# Commands:
#   wt list | wt              numbered list of linked worktrees (repo-scoped)
#   wt add <branch> [base]    create worktree for <branch> (existing/remote/new)
#   wt go <id>                cd into worktree by number
#   wt status                 git status -sb for every linked worktree
#   wt rm <id> [id...] [--keep-branch]   remove worktree(s) by number (force)
#   wt clear                  remove ALL linked worktrees (force) + their branches
#   wt help                   show this
#
# IDs are positional (recomputed each call) - always `wt list` right before `wt rm`.
#
# NOTE for zsh users: worktree paths are read into a loop variable. zsh ties a
# lowercase `path` array to `$PATH`, so this file deliberately never names a
# variable `path` (uses `wtpath`) - naming it `path` silently breaks every
# `git` call after the first assignment. If you fork this, keep that in mind.

_wt_list_raw() {
  git worktree list --porcelain 2>/dev/null | awk '
    BEGIN { idx = 0; main = "" }
    /^worktree /  { wtpath = substr($0, 10) }
    /^branch /    { branch = $2; sub("refs/heads/", "", branch) }
    /^detached/   { branch = "(detached)" }
    /^bare/       { branch = "(bare)" }
    /^$/          {
      if (main == "") { main = wtpath }
      else if (wtpath != "") { idx++; printf "%d\t%s\t%s\n", idx, wtpath, branch }
      wtpath = ""; branch = ""
    }
    END {
      if (wtpath != "") {
        if (main == "") { main = wtpath }
        else { idx++; printf "%d\t%s\t%s\n", idx, wtpath, branch }
      }
    }
  '
}

_wt_usage() {
  cat <<'EOF'
wt - git worktree manager

  wt list | wt              numbered list of linked worktrees
  wt add <branch> [base]    create worktree for <branch>
  wt go <id>                cd into worktree by number
  wt status                 git status -sb for every linked worktree
  wt rm <id> [id...] [--keep-branch]   remove worktree(s) by number (force)
  wt clear                  remove ALL linked worktrees + their branches
  wt help                   show this

IDs come from `wt list` and are recomputed every call.
EOF
}

wt() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "wt: not inside a git repo"; return 1
  fi
  local cmd="$1"; [[ $# -gt 0 ]] && shift

  case "$cmd" in
    list|ls|"")
      local rows; rows=$(_wt_list_raw)
      if [[ -z "$rows" ]]; then echo "wt: no linked worktrees"; return 0; fi
      printf "%-4s %-8s %-55s %s\n" "ID" "STATE" "PATH" "BRANCH"
      echo "$rows" | while IFS=$'\t' read -r idx wtpath branch; do
        local state="clean" shortpath="${wtpath/#$HOME/~}"
        if [[ ! -d "$wtpath" ]]; then
          state="missing"
        elif [[ -n $(git -C "$wtpath" status --porcelain 2>/dev/null) ]]; then
          state="dirty"
        fi
        printf "%-4s %-8s %-55s %s\n" "$idx" "$state" "$shortpath" "$branch"
      done
      ;;

    add)
      local branch="$1" base="$2"
      if [[ -z "$branch" ]]; then echo "usage: wt add <branch> [base]"; return 1; fi
      local root; root=$(git rev-parse --show-toplevel) || return 1
      local dest="$root/.worktrees/$branch"
      mkdir -p "$(dirname "$dest")"
      if git rev-parse --verify --quiet "$branch" &>/dev/null \
         || git ls-remote --exit-code --heads origin "$branch" &>/dev/null; then
        git worktree add "$dest" "$branch"
      else
        git worktree add -b "$branch" "$dest" ${base:+"$base"}
      fi
      ;;

    go|cd)
      local id="$1"
      if [[ -z "$id" ]]; then echo "usage: wt go <id>"; return 1; fi
      local wtpath; wtpath=$(_wt_list_raw | awk -F'\t' -v i="$id" '$1==i{print $2}')
      if [[ -z "$wtpath" ]]; then echo "wt: no worktree #$id (run: wt list)"; return 1; fi
      cd "$wtpath"
      ;;

    status|st)
      local rows; rows=$(_wt_list_raw)
      echo "$rows" | while IFS=$'\t' read -r idx wtpath branch; do
        echo "-- #$idx  $branch  (${wtpath/#$HOME/~}) --"
        git -C "$wtpath" status -sb 2>/dev/null
        echo
      done
      ;;

    rm|remove)
      local keep_branch=0
      local -a ids=()
      for a in "$@"; do
        if [[ "$a" == "--keep-branch" ]]; then keep_branch=1; else ids+=("$a"); fi
      done
      if [[ ${#ids[@]} -eq 0 ]]; then echo "usage: wt rm <id> [id...] [--keep-branch]"; return 1; fi
      local rows; rows=$(_wt_list_raw)
      for id in "${ids[@]}"; do
        local line wtpath branch
        line=$(echo "$rows" | awk -F'\t' -v i="$id" '$1==i')
        if [[ -z "$line" ]]; then echo "wt: no worktree #$id"; continue; fi
        wtpath=$(echo "$line" | cut -f2)
        branch=$(echo "$line" | cut -f3)
        echo "Removing #$id: ${wtpath/#$HOME/~} (branch: $branch)"
        git worktree remove --force "$wtpath"
        if [[ $keep_branch -eq 0 && "$branch" != "(detached)" && "$branch" != "(bare)" ]]; then
          git branch -D "$branch" 2>/dev/null
        fi
      done
      git worktree prune
      ;;

    clear)
      local rows; rows=$(_wt_list_raw)
      if [[ -z "$rows" ]]; then echo "wt: nothing to clear"; return 0; fi
      echo "$rows" | while IFS=$'\t' read -r idx wtpath branch; do
        echo "Removing #$idx: ${wtpath/#$HOME/~} (branch: $branch)"
        git worktree remove --force "$wtpath"
        if [[ "$branch" != "(detached)" && "$branch" != "(bare)" ]]; then
          git branch -D "$branch" 2>/dev/null
        fi
      done
      git worktree prune
      echo "All linked worktrees cleared."
      ;;

    help|-h|--help)
      _wt_usage
      ;;

    *)
      echo "wt: unknown subcommand '$cmd'"
      _wt_usage
      return 1
      ;;
  esac
}
