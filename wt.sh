# wt-cli: git worktree manager (bash + zsh)
# https://github.com/mrx-arafat/wt-cli
#
# This file is meant to be SOURCED, not executed:
#   source /path/to/wt.sh
#
# Because it runs inside your shell, `wt go` can cd your REAL shell -
# no subshells, no shell-integration hacks. That's the whole point.
#
# Commands:
#   wt list | wt              numbered table: state / sync / age / branch / path
#   wt add <branch> [base]    create worktree (+ copy files, run hook, cd in)
#   wt go [id|branch]         cd into a worktree (no arg: fzf or picker)
#   wt main                   cd back to the main checkout
#   wt exec <id|branch> <cmd...>   run a command inside a worktree
#   wt open <id|branch>       open worktree in your editor
#   wt pr <number>            worktree from a GitHub pull request
#   wt status                 git status -sb for every linked worktree
#   wt clean                  remove worktrees whose branches are fully merged
#   wt rm <id> [id...] [--keep-branch]   remove worktree(s) by number (force)
#   wt clear                  remove ALL linked worktrees (force) + their branches
#   wt help | wt version      show help / version
#
# Config (via git config, no extra files):
#   git config wt.copy ".env .env.local"     files/globs copied from the main
#                                            checkout into every new worktree
#   git config wt.postadd "npm install"      command run inside a new worktree
#   git config wt.editor "code"              editor for `wt open`
#
# IDs are positional (recomputed each call) - always `wt list` right before `wt rm`.
# Output uses color + emoji state badges when stdout is a tty; NO_COLOR=1 for plain.
#
# NOTE for zsh users: worktree paths are read into a loop variable. zsh ties a
# lowercase `path` array to `$PATH`, so this file deliberately never names a
# variable `path` (uses `wtpath`) - naming it `path` silently breaks every
# `git` call after the first assignment. If you fork this, keep that in mind.
# Also: a bare `local x` on an already-declared local PRINTS its value in zsh,
# so loop locals are declared once, then assigned.

WT_VERSION="2.0.0"

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

# Sets _WT_* globals for this call. Re-run every invocation (not once at
# source time) so piping/redirecting `wt list > file` degrades to plain text.
_wt_setup_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    _WT_RESET=$'\033[0m'
    _WT_BOLD=$'\033[1m'
    _WT_DIM=$'\033[2m'
    _WT_RED=$'\033[31m'
    _WT_GREEN=$'\033[32m'
    _WT_YELLOW=$'\033[33m'
    _WT_CYAN=$'\033[36m'
  else
    _WT_RESET='' _WT_BOLD='' _WT_DIM='' _WT_RED='' _WT_GREEN='' _WT_YELLOW='' _WT_CYAN=''
  fi
}

# State of a worktree: clean / dirty / missing (git tracks it, dir is gone).
# Dirty means uncommitted changes to TRACKED files (-uno). Untracked files
# don't count - wt.copy drops .env files into every new worktree, and those
# would otherwise mark every tree dirty forever.
_wt_state_word() {
  local wtpath="$1"
  if [[ ! -d "$wtpath" ]]; then
    echo missing
  elif [[ -n $(git -C "$wtpath" status --porcelain -uno 2>/dev/null) ]]; then
    echo dirty
  else
    echo clean
  fi
}

# Emoji badge per state, hand-padded with trailing spaces to ~6 display cells.
# printf %-Ns pads by BYTES, and emoji are multibyte - so alignment must be
# done by hand here, not with printf field widths.
_wt_state_emoji() {
  case "$1" in
    clean)   echo "✋😎🤚" ;;
    dirty)   echo "🍷    " ;;
    missing) echo "🗿🤙🏻  " ;;
  esac
}

_wt_state_color() {
  case "$1" in
    clean)   printf '%s' "$_WT_GREEN" ;;
    dirty)   printf '%s' "$_WT_YELLOW" ;;
    missing) printf '%s' "$_WT_DIM" ;;
  esac
}

# "+ahead -behind" vs upstream, "ok" when in sync, "-" when no upstream.
# printf, not echo: zsh's builtin echo swallows a lone "-" (option terminator).
_wt_sync() {
  local wtpath="$1" counts ahead behind
  counts=$(git -C "$wtpath" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null) \
    || { printf '%s\n' "-"; return; }
  behind=$(echo "$counts" | awk '{print $1}')
  ahead=$(echo "$counts" | awk '{print $2}')
  if [[ "$ahead" == "0" && "$behind" == "0" ]]; then echo "ok"
  elif [[ "$behind" == "0" ]]; then echo "+$ahead"
  elif [[ "$ahead" == "0" ]]; then printf '%s\n' "-$behind"
  else printf '%s\n' "+$ahead-$behind"
  fi
}

# Compact relative age of last commit: "3d", "2w", "5mo", "1y", "4h", "12m".
_wt_age() {
  local wtpath="$1" rel
  rel=$(git -C "$wtpath" log -1 --format='%cr' 2>/dev/null) || { printf '%s\n' "-"; return; }
  [[ -z "$rel" ]] && { printf '%s\n' "-"; return; }
  echo "$rel" | sed -e 's/ ago//' \
    -e 's/ seconds*/s/' -e 's/ minutes*/m/' -e 's/ hours*/h/' \
    -e 's/ days*/d/' -e 's/ weeks*/w/' -e 's/ months*/mo/' -e 's/ years*/y/'
}

# Keep <main-root>/.worktrees/ out of `git status` noise, without touching
# the repo's tracked .gitignore. Uses the COMMON git dir so it works when
# called from inside any worktree.
_wt_ensure_exclude() {
  local commondir excl
  commondir=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
  excl="$commondir/info/exclude"
  mkdir -p "$commondir/info"
  grep -qxF '.worktrees/' "$excl" 2>/dev/null || echo '.worktrees/' >> "$excl"
}

# Resolve <id-or-branch> to a worktree path. Accepts a numeric ID, an exact
# branch name, or a unique branch substring. Prints the path, or errors.
_wt_resolve() {
  local key="$1" rows matches n
  rows=$(_wt_list_raw)
  [[ -z "$rows" ]] && { echo "wt: no linked worktrees" >&2; return 1; }
  case "$key" in
    (*[!0-9]*|'') ;;  # not purely numeric - fall through to branch matching
    (*)
      local by_id; by_id=$(echo "$rows" | awk -F'\t' -v i="$key" '$1==i{print $2}')
      [[ -n "$by_id" ]] && { echo "$by_id"; return 0; }
      echo "wt: no worktree #$key (run: wt list)" >&2; return 1 ;;
  esac
  matches=$(echo "$rows" | awk -F'\t' -v b="$key" '$3==b{print $2}')
  if [[ -n "$matches" ]]; then echo "$matches" | head -1; return 0; fi
  matches=$(echo "$rows" | awk -F'\t' -v b="$key" 'index($3,b)>0{print $2"\t"$3}')
  n=$(echo -n "$matches" | grep -c . 2>/dev/null || true)
  if [[ "$n" -eq 1 ]]; then echo "$matches" | cut -f1; return 0; fi
  if [[ "$n" -gt 1 ]]; then
    echo "wt: '$key' matches multiple branches:" >&2
    echo "$matches" | cut -f2 | sed 's/^/  /' >&2
    return 1
  fi
  echo "wt: nothing matches '$key' (run: wt list)" >&2
  return 1
}

# Main checkout root (first entry of `git worktree list`).
_wt_main_root() {
  git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}'
}

# Default branch: origin/HEAD if known, else main, else master.
_wt_default_branch() {
  local db
  db=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) && { echo "${db#origin/}"; return; }
  git show-ref --verify --quiet refs/heads/main && { echo main; return; }
  git show-ref --verify --quiet refs/heads/master && { echo master; return; }
  echo ""
}

_wt_usage() {
  cat <<EOF
${_WT_BOLD}${_WT_CYAN}wt${_WT_RESET} ${_WT_DIM}v${WT_VERSION} -${_WT_RESET} git worktree manager that lives in your shell

${_WT_BOLD}USAGE${_WT_RESET}
  wt                                    numbered list of worktrees in this repo
  wt <command> [args]

${_WT_BOLD}COMMANDS${_WT_RESET}
  ${_WT_CYAN}list${_WT_RESET}, ls                       table: ID / state / sync / age / branch / path
  ${_WT_CYAN}add${_WT_RESET}  <branch> [base]            create worktree + copy wt.copy files +
                                       run wt.postadd hook + cd into it
  ${_WT_CYAN}go${_WT_RESET}   [id|branch]                cd into a worktree; no arg = fzf / picker
  ${_WT_CYAN}main${_WT_RESET}                            cd back to the main checkout
  ${_WT_CYAN}exec${_WT_RESET} <id|branch> <cmd...>       run a command inside a worktree
  ${_WT_CYAN}open${_WT_RESET} <id|branch>                open worktree in your editor
  ${_WT_CYAN}pr${_WT_RESET}   <number>                   worktree from a GitHub pull request
  ${_WT_CYAN}status${_WT_RESET}, st                      git status -sb for every linked worktree
  ${_WT_CYAN}clean${_WT_RESET}                           remove fully-merged worktrees (confirms)
  ${_WT_CYAN}rm${_WT_RESET}   <id> [id...] [--keep-branch]  remove worktree(s) + branch (force)
  ${_WT_CYAN}clear${_WT_RESET}                           remove EVERY linked worktree + branch (force)
  ${_WT_CYAN}help${_WT_RESET} | ${_WT_CYAN}version${_WT_RESET}                  this help / version

${_WT_BOLD}STATE${_WT_RESET}
  ${_WT_GREEN}✋😎🤚 clean${_WT_RESET}     no uncommitted changes to tracked files
  ${_WT_YELLOW}🍷 dirty${_WT_RESET}       uncommitted changes to tracked files
  ${_WT_DIM}🗿🤙🏻 missing${_WT_RESET}   git still tracks it, the directory is gone

${_WT_BOLD}SYNC${_WT_RESET} (vs upstream)   ${_WT_DIM}ok${_WT_RESET} in sync  ·  ${_WT_DIM}+2${_WT_RESET} ahead  ·  ${_WT_DIM}-3${_WT_RESET} behind  ·  ${_WT_DIM}-${_WT_RESET} no upstream

${_WT_BOLD}CONFIG${_WT_RESET} (git config, per-repo or --global)
  wt.copy      space-separated files/globs copied from the main checkout
               into every new worktree     e.g. ${_WT_DIM}git config wt.copy ".env .env.local"${_WT_RESET}
  wt.postadd   command run inside a new worktree after create
                                           e.g. ${_WT_DIM}git config wt.postadd "npm install"${_WT_RESET}
  wt.editor    editor command for wt open  e.g. ${_WT_DIM}git config wt.editor "code"${_WT_RESET}

${_WT_BOLD}NOTES${_WT_RESET}
  - IDs come from 'wt list', recomputed every call - re-list before 'wt rm'.
  - Worktrees live at <repo>/.worktrees/<branch>, repo-local, git-ignored.
  - 'wt rm' / 'wt clear' are destructive: worktree removed with --force, local
    branch deleted too (skip with --keep-branch on 'wt rm'). 'wt clean' only
    touches branches already merged into the default branch, and confirms first.
  - Set NO_COLOR=1 to disable colors (emoji stay).

https://github.com/mrx-arafat/wt-cli
EOF
}

wt() {
  _wt_setup_colors

  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift

  case "$cmd" in
    help|-h|--help) _wt_usage; return 0 ;;
    version|-v|--version) echo "wt v${WT_VERSION}"; return 0 ;;
  esac

  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    printf '%s❌ wt: not inside a git repo%s\n' "$_WT_RED" "$_WT_RESET" >&2
    return 1
  fi

  case "$cmd" in
    list|ls|"")
      local rows; rows=$(_wt_list_raw)
      if [[ -z "$rows" ]]; then
        printf '%s🥱 wt: no linked worktrees yet%s - try: %swt add <branch>%s\n' \
          "$_WT_DIM" "$_WT_RESET" "$_WT_CYAN" "$_WT_RESET"
        return 0
      fi
      local root; root=$(_wt_main_root)
      local count; count=$(echo "$rows" | wc -l | tr -d ' ')

      printf '\n%s%swt%s %s· %s worktree(s) in %s%s\n\n' \
        "$_WT_BOLD" "$_WT_CYAN" "$_WT_RESET" "$_WT_DIM" "$count" "$(basename "$root")" "$_WT_RESET"
      printf "%s%s%-4s %-16s %-8s %-6s %-28s %s%s\n" \
        "$_WT_BOLD" "$_WT_CYAN" "ID" "STATE" "SYNC" "AGE" "BRANCH" "PATH" "$_WT_RESET"
      local state emoji color shortpath syncs age
      echo "$rows" | while IFS=$'\t' read -r idx wtpath branch; do
        state=$(_wt_state_word "$wtpath")
        emoji=$(_wt_state_emoji "$state")
        color=$(_wt_state_color "$state")
        syncs=$(_wt_sync "$wtpath")
        age=$(_wt_age "$wtpath")
        shortpath="${wtpath/#$HOME/~}"
        printf "%-4s ${color}%s %-8s${_WT_RESET} %-8s %-6s %-28s ${_WT_DIM}%s${_WT_RESET}\n" \
          "$idx" "$emoji" "$state" "$syncs" "$age" "$branch" "$shortpath"
      done
      printf '\n%sTip: wt go <ID>  ·  wt exec <ID> <cmd>  ·  wt rm <ID>  ·  wt help%s\n\n' "$_WT_DIM" "$_WT_RESET"
      ;;

    add)
      local branch="${1:-}" base="${2:-}"
      if [[ -z "$branch" ]]; then echo "usage: wt add <branch> [base]" >&2; return 1; fi
      # Anchor on the MAIN checkout, not the current worktree - otherwise
      # running `wt add` from inside a worktree nests trees recursively.
      local root; root=$(_wt_main_root)
      [[ -z "$root" ]] && { echo "wt: cannot find main checkout" >&2; return 1; }
      _wt_ensure_exclude
      local dest="$root/.worktrees/$branch"
      mkdir -p "$(dirname "$dest")"
      if git rev-parse --verify --quiet "$branch" &>/dev/null \
         || git ls-remote --exit-code --heads origin "$branch" &>/dev/null; then
        git worktree add "$dest" "$branch" || return 1
      else
        git worktree add -b "$branch" "$dest" ${base:+"$base"} || return 1
      fi

      # wt.copy: files/globs (relative to main root) copied into the worktree.
      # Typical use: .env files that are git-ignored but needed to run the app.
      local copyspec; copyspec=$(git config --get wt.copy 2>/dev/null || true)
      if [[ -n "$copyspec" ]]; then
        local mainroot; mainroot=$(_wt_main_root)
        local f
        # tr-split instead of unquoted expansion: zsh doesn't word-split
        # unquoted vars, and zsh's ${=var} is a bash parse error.
        echo "$copyspec" | tr ' ' '\n' | while IFS= read -r f; do
          [[ -z "$f" ]] && continue
          if [[ -e "$mainroot/$f" ]]; then
            cp -R "$mainroot/$f" "$dest/$f" 2>/dev/null \
              && printf '%s📋 copied%s %s\n' "$_WT_DIM" "$_WT_RESET" "$f"
          fi
        done
      fi

      # wt.postadd: setup command (npm install, direnv allow, ...) in the new tree.
      local hook; hook=$(git config --get wt.postadd 2>/dev/null || true)
      if [[ -n "$hook" ]]; then
        printf '%s⚙  running wt.postadd:%s %s\n' "$_WT_DIM" "$_WT_RESET" "$hook"
        ( cd "$dest" && eval "$hook" )
      fi

      printf '\n%s✅ ready%s -> %s%s%s\n\n' "$_WT_GREEN" "$_WT_RESET" "$_WT_CYAN" "${dest/#$HOME/~}" "$_WT_RESET"
      cd "$dest"
      ;;

    go|cd)
      local key="${1:-}" wtpath
      if [[ -z "$key" ]]; then
        local rows; rows=$(_wt_list_raw)
        [[ -z "$rows" ]] && { printf '%s🥱 wt: no linked worktrees yet%s\n' "$_WT_DIM" "$_WT_RESET"; return 0; }
        if command -v fzf &>/dev/null; then
          local picked
          picked=$(echo "$rows" | awk -F'\t' '{printf "%s  %s  %s\n", $1, $3, $2}' \
            | fzf --height=~40% --reverse --prompt="wt go > ") || return 1
          key=$(echo "$picked" | awk '{print $1}')
        else
          local state emoji
          echo "$rows" | while IFS=$'\t' read -r idx wtpath branch; do
            state=$(_wt_state_word "$wtpath")
            emoji=$(_wt_state_emoji "$state")
            printf '  %s) %s %s\n' "$idx" "$emoji" "$branch"
          done
          printf 'wt go > '
          read -r key
          [[ -z "$key" ]] && return 1
        fi
      fi
      wtpath=$(_wt_resolve "$key") || return 1
      printf '%s🚀 ->%s %s\n' "$_WT_CYAN" "$_WT_RESET" "${wtpath/#$HOME/~}"
      cd "$wtpath"
      ;;

    main|root)
      local mainroot; mainroot=$(_wt_main_root)
      [[ -z "$mainroot" ]] && { echo "wt: cannot find main checkout" >&2; return 1; }
      printf '%s🚀 ->%s %s %s(main)%s\n' "$_WT_CYAN" "$_WT_RESET" "${mainroot/#$HOME/~}" "$_WT_DIM" "$_WT_RESET"
      cd "$mainroot"
      ;;

    exec)
      local key="${1:-}"; [[ $# -gt 0 ]] && shift
      [[ "$1" == "--" ]] && shift
      if [[ -z "$key" || $# -eq 0 ]]; then echo "usage: wt exec <id|branch> <cmd...>" >&2; return 1; fi
      local wtpath; wtpath=$(_wt_resolve "$key") || return 1
      printf '%s⚙  %s%s in %s\n' "$_WT_DIM" "$*" "$_WT_RESET" "${wtpath/#$HOME/~}"
      ( cd "$wtpath" && "$@" )
      ;;

    open)
      local key="${1:-}"
      if [[ -z "$key" ]]; then echo "usage: wt open <id|branch>" >&2; return 1; fi
      local wtpath; wtpath=$(_wt_resolve "$key") || return 1
      local editor; editor=$(git config --get wt.editor 2>/dev/null || true)
      [[ -z "$editor" ]] && editor="${VISUAL:-${EDITOR:-}}"
      if [[ -z "$editor" ]]; then
        echo "wt: no editor - set one: git config wt.editor \"code\" (or \$EDITOR)" >&2
        return 1
      fi
      printf '%s🚀 %s%s %s\n' "$_WT_CYAN" "$editor" "$_WT_RESET" "${wtpath/#$HOME/~}"
      ( cd "$wtpath" && eval "$editor \"$wtpath\"" )
      ;;

    pr)
      local num="${1:-}"
      case "$num" in
        ''|*[!0-9]*) echo "usage: wt pr <number>   (GitHub PRs, via pull/N/head)" >&2; return 1 ;;
      esac
      local branch="pr/$num"
      printf '%s⬇  fetching PR #%s%s\n' "$_WT_DIM" "$num" "$_WT_RESET"
      git fetch origin "pull/$num/head:$branch" || {
        echo "wt: could not fetch PR #$num (GitHub remotes only)" >&2; return 1; }
      wt add "$branch"
      ;;

    status|st)
      local rows; rows=$(_wt_list_raw)
      if [[ -z "$rows" ]]; then
        printf '%s🥱 wt: no linked worktrees yet%s - try: %swt add <branch>%s\n' \
          "$_WT_DIM" "$_WT_RESET" "$_WT_CYAN" "$_WT_RESET"
        return 0
      fi
      local state emoji color syncs
      echo "$rows" | while IFS=$'\t' read -r idx wtpath branch; do
        state=$(_wt_state_word "$wtpath")
        emoji=$(_wt_state_emoji "$state")
        color=$(_wt_state_color "$state")
        syncs=$(_wt_sync "$wtpath")
        printf '\n%s#%s%s  %s%s %s%s  %s[%s]%s  %s(%s)%s\n' \
          "$_WT_BOLD" "$idx" "$_WT_RESET" "$color" "$emoji" "$branch" "$_WT_RESET" \
          "$_WT_DIM" "$syncs" "$_WT_RESET" \
          "$_WT_DIM" "${wtpath/#$HOME/~}" "$_WT_RESET"
        git -C "$wtpath" status -sb 2>/dev/null
      done
      echo
      ;;

    clean)
      local db; db=$(_wt_default_branch)
      [[ -z "$db" ]] && { echo "wt: cannot determine default branch" >&2; return 1; }
      local rows; rows=$(_wt_list_raw)
      [[ -z "$rows" ]] && { echo "wt: nothing to clean"; return 0; }
      local merged="" state
      while IFS=$'\t' read -r idx wtpath branch; do
        [[ "$branch" == "(detached)" || "$branch" == "(bare)" || "$branch" == "$db" ]] && continue
        state=$(_wt_state_word "$wtpath")
        [[ "$state" == "dirty" ]] && continue  # never clean uncommitted work
        if git merge-base --is-ancestor "$branch" "$db" 2>/dev/null; then
          merged="${merged}${idx}\t${wtpath}\t${branch}\n"
        fi
      done <<EOF
$rows
EOF
      merged=$(printf '%b' "$merged")
      if [[ -z "$merged" ]]; then
        printf '%s✅ nothing merged into %s - all worktrees still in play%s\n' "$_WT_GREEN" "$db" "$_WT_RESET"
        return 0
      fi
      printf '\n%sMerged into %s%s%s (safe to remove):%s\n' "$_WT_BOLD" "$_WT_CYAN" "$db" "$_WT_RESET" "$_WT_RESET"
      echo "$merged" | while IFS=$'\t' read -r idx wtpath branch; do
        printf '  #%s  %s  %s(%s)%s\n' "$idx" "$branch" "$_WT_DIM" "${wtpath/#$HOME/~}" "$_WT_RESET"
      done
      printf 'Remove these? [y/N] '
      local ans; read -r ans
      [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "aborted"; return 0; }
      echo "$merged" | while IFS=$'\t' read -r idx wtpath branch; do
        printf '%s☠️😎 killing%s %s\n' "$_WT_RED" "$_WT_RESET" "$branch"
        git worktree remove --force "$wtpath"
        git branch -D "$branch" 2>/dev/null
      done
      git worktree prune
      printf '\n%s✅ cleaned%s\n\n' "$_WT_GREEN" "$_WT_RESET"
      ;;

    rm|remove)
      local keep_branch=0
      local -a ids=()
      local a
      for a in "$@"; do
        if [[ "$a" == "--keep-branch" ]]; then keep_branch=1; else ids+=("$a"); fi
      done
      if [[ ${#ids[@]} -eq 0 ]]; then echo "usage: wt rm <id> [id...] [--keep-branch]" >&2; return 1; fi
      local rows; rows=$(_wt_list_raw)
      local removed=0
      local id line wtpath branch
      for id in "${ids[@]}"; do
        line=$(echo "$rows" | awk -F'\t' -v i="$id" '$1==i')
        if [[ -z "$line" ]]; then
          printf '%swt: no worktree #%s%s\n' "$_WT_RED" "$id" "$_WT_RESET" >&2
          continue
        fi
        wtpath=$(echo "$line" | cut -f2)
        branch=$(echo "$line" | cut -f3)
        printf '%s☠️😎 killing #%s%s -> %s%s%s  %s(%s)%s\n' \
          "$_WT_RED" "$id" "$_WT_RESET" "$_WT_CYAN" "$branch" "$_WT_RESET" \
          "$_WT_DIM" "${wtpath/#$HOME/~}" "$_WT_RESET"
        git worktree remove --force "$wtpath"
        if [[ $keep_branch -eq 0 && "$branch" != "(detached)" && "$branch" != "(bare)" ]]; then
          git branch -D "$branch" 2>/dev/null
        fi
        removed=$((removed + 1))
      done
      git worktree prune
      printf '\n%s✅ removed %d worktree(s)%s\n\n' "$_WT_GREEN" "$removed" "$_WT_RESET"
      ;;

    clear)
      local rows; rows=$(_wt_list_raw)
      if [[ -z "$rows" ]]; then echo "wt: nothing to clear"; return 0; fi
      local count; count=$(echo "$rows" | wc -l | tr -d ' ')
      printf '\n%s%s☠️😎 wiping %s worktree(s) - no mercy, no undo%s\n\n' \
        "$_WT_BOLD" "$_WT_YELLOW" "$count" "$_WT_RESET"
      echo "$rows" | while IFS=$'\t' read -r idx wtpath branch; do
        printf '%s☠️😎 #%s%s -> %s%s%s  %s(%s)%s\n' \
          "$_WT_RED" "$idx" "$_WT_RESET" "$_WT_CYAN" "$branch" "$_WT_RESET" \
          "$_WT_DIM" "${wtpath/#$HOME/~}" "$_WT_RESET"
        git worktree remove --force "$wtpath"
        if [[ "$branch" != "(detached)" && "$branch" != "(bare)" ]]; then
          git branch -D "$branch" 2>/dev/null
        fi
      done
      git worktree prune
      printf '\n%s✅ all linked worktrees cleared%s\n\n' "$_WT_GREEN" "$_WT_RESET"
      ;;

    *)
      printf '%swt: unknown subcommand '"'"'%s'"'"'%s\n' "$_WT_RED" "$cmd" "$_WT_RESET" >&2
      _wt_usage
      return 1
      ;;
  esac
}

# ---- tab completion ---------------------------------------------------------
# Completes subcommands, then branch names for go/exec/open/rm.

_wt_branches() { _wt_list_raw | cut -f3; }

if [[ -n "${ZSH_VERSION:-}" ]]; then
  _wt_complete_zsh() {
    local -a subcmds branches
    subcmds=(list add go main exec open pr status clean rm clear help version)
    if (( CURRENT == 2 )); then
      compadd -a subcmds
    else
      case "${words[2]}" in
        go|exec|open|rm)
          branches=(${(f)"$(_wt_branches 2>/dev/null)"})
          compadd -a branches ;;
      esac
    fi
  }
  compdef _wt_complete_zsh wt 2>/dev/null || true
elif [[ -n "${BASH_VERSION:-}" ]]; then
  _wt_complete_bash() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    if [[ $COMP_CWORD -eq 1 ]]; then
      COMPREPLY=($(compgen -W "list add go main exec open pr status clean rm clear help version" -- "$cur"))
    else
      case "${COMP_WORDS[1]}" in
        go|exec|open|rm)
          COMPREPLY=($(compgen -W "$(_wt_branches 2>/dev/null | tr '\n' ' ')" -- "$cur")) ;;
      esac
    fi
  }
  complete -F _wt_complete_bash wt 2>/dev/null || true
fi
