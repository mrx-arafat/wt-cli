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
#   wt | wt ls                interactive manager on a TTY (plain table when piped)
#   wt ls -p [-a]             plain table: id / state / name / branch / sync / age / path
#   wt add <branch> [base]    create worktree (+ copy files, run hook, cd in)
#   wt go [id|name|branch]    cd into a worktree (no arg: picker)
#   wt main                   cd back to the main checkout
#   wt exec <id|name> <cmd...>     run a command inside a worktree
#   wt open <id|name>         open worktree in your editor
#   wt pr <number>            worktree from a GitHub pull request
#   wt status                 git status -sb for every linked worktree
#   wt clean                  remove worktrees whose branches are fully merged
#   wt rm [sel...] [-k] [-y]  remove worktree(s): 2 4 5 | 2,4 | 2-5 | name | all
#   wt clear                  remove ALL linked worktrees (= wt rm all)
#   wt prune                  drop stale entries whose directory was deleted
#   wt update                 self-update to the latest release (= wt-cli --update)
#   wt help | wt version      show help / version
#
# Config (via git config, no extra files):
#   git config wt.copy ".env .env.local"     files/globs copied from the main
#                                            checkout into every new worktree
#   git config wt.postadd "npm install"      command run inside a new worktree
#   git config wt.editor "code"              editor for `wt open`
#
# IDs are positional (recomputed each call): live worktrees first, stale last.
# Names are stable - prefer `wt go <name>` / `wt rm <name>` in scripts.
# Output uses color + emoji state badges when stdout is a tty; NO_COLOR=1 for plain.
#
# NOTE for zsh users: worktree paths are read into a loop variable. zsh ties a
# lowercase `path` array to `$PATH`, so this file deliberately never names a
# variable `path` (uses `wtpath`) - naming it `path` silently breaks every
# `git` call after the first assignment. `status` is read-only in zsh too.
# Also: a bare `local x` on an already-declared local PRINTS its value in zsh,
# so loop locals are declared once, then assigned.
# Rows are tab-separated and read with IFS=$'\t'. Tab is IFS *whitespace*, so
# consecutive tabs collapse and an empty field shifts every later column -
# that's why empty values are always written as "-".

WT_VERSION="3.1.0"

# Where this file lives, captured at source time so `wt update` can replace
# it in place (no forks here: this runs on every shell startup).
if [[ -n "${ZSH_VERSION:-}" ]]; then
  _WT_SELF="${(%):-%x}"
else
  _WT_SELF="${BASH_SOURCE[0]:-}"
fi
[[ -z "$_WT_SELF" || "$_WT_SELF" == /* ]] || _WT_SELF="$PWD/$_WT_SELF"

# ---- data layer -------------------------------------------------------------

# One row per LINKED worktree (main checkout excluded), tab-separated:
#   id  path  branch  name  head  flags
# branch: "(detached)" / "(bare)" when not on a branch.
# name:   what you called it - the dir under <main>/.worktrees/, else the dir
#         basename (parent/basename when the basename is just the repo name).
# flags:  p = stale (directory deleted, prunable), l = locked, "-" = none.
# Live worktrees are numbered first and stale ones last, so the IDs you use
# day to day stay small even when a pile of dead entries exists.
_wt_list_raw() {
  git worktree list --porcelain 2>/dev/null | awk '
    function reset() { wtpath = ""; branch = ""; head = ""; flags = "" }
    function flush(   name, parent, pre, row) {
      if (wtpath == "") return
      if (main == "") {
        main = wtpath; mainbase = wtpath; sub(/.*\//, "", mainbase); reset(); return
      }
      pre = main "/.worktrees/"
      if (index(wtpath, pre) == 1) {
        name = substr(wtpath, length(pre) + 1)
      } else {
        name = wtpath; sub(/.*\//, "", name)
        if (name == mainbase) {
          parent = wtpath; sub(/\/[^\/]*$/, "", parent); sub(/.*\//, "", parent)
          name = parent "/" name
        }
      }
      if (branch == "") branch = "(detached)"
      if (head == "") head = "-"
      if (flags == "") flags = "-"
      row = wtpath "\t" branch "\t" name "\t" head "\t" flags
      if (index(flags, "p")) stale[++ns] = row; else live[++nl] = row
      reset()
    }
    /^worktree / { flush(); wtpath = substr($0, 10) }
    /^HEAD /     { head = substr($0, 6) }
    /^branch /   { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch) }
    /^detached/  { branch = "(detached)" }
    /^bare/      { branch = "(bare)" }
    /^locked/    { flags = flags "l" }
    /^prunable/  { flags = flags "p" }
    END {
      flush()
      for (i = 1; i <= nl; i++) printf "%d\t%s\n", i, live[i]
      for (i = 1; i <= ns; i++) printf "%d\t%s\n", nl + i, stale[i]
    }'
}

# Everything the table / TUI shows, one tab-separated row per linked worktree:
#   id name branch head7 state changes sync age dpath flags path
# state:   clean / dirty (uncommitted changes to TRACKED files) / missing
# sync:    ok / +ahead / -behind / +a-b vs upstream, "gone" (upstream deleted), "-"
# dpath:   path relative to the main checkout when inside it, else ~-shortened
# flags:   as _wt_list_raw, plus c = the worktree this shell is in
# The per-tree `git status` is the slow part, so all of them run in parallel,
# and every commit age comes from ONE `git log` call.
# Untracked files don't count as dirty - wt.copy drops .env files into every
# new worktree, and those would otherwise mark every tree dirty forever.
_wt_collect() {
  local rows tmp main here now
  rows=$(_wt_list_raw)
  [[ -z "$rows" ]] && return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/wt.XXXXXX") || return 1
  main=$(_wt_main_root)
  here=$(git rev-parse --show-toplevel 2>/dev/null)
  now=$(date +%s)
  (
    local id wtpath branch name head flags
    printf '%s\n' "$rows" | awk -F'\t' '$5 != "-" && $6 !~ /p/ { print $5 }' \
      | git log --no-walk=unsorted --ignore-missing --stdin --format='%H %ct' \
        >"$tmp/ages" 2>/dev/null &
    while IFS=$'\t' read -r id wtpath branch name head flags; do
      [[ -d "$wtpath" ]] || continue
      git -C "$wtpath" --no-optional-locks status --porcelain=v2 --branch -uno \
        >"$tmp/$id" 2>/dev/null &
    done <<EOF
$rows
EOF
    wait
  )
  printf '%s\n' "$rows" | awk -F'\t' -v OFS='\t' -v tmp="$tmp" -v now="$now" \
      -v main="$main" -v here="$here" -v home="$HOME" '
    function age(s,   d) {
      if (s == "") return "-"
      d = now - s; if (d < 0) d = 0
      if (d < 60)       return d "s"
      if (d < 3600)     return int(d / 60) "m"
      if (d < 86400)    return int(d / 3600) "h"
      if (d < 604800)   return int(d / 86400) "d"
      if (d < 2592000)  return int(d / 604800) "w"
      if (d < 31536000) return int(d / 2592000) "mo"
      return int(d / 31536000) "y"
    }
    BEGIN {
      while ((getline l < (tmp "/ages")) > 0) { split(l, a, " "); ct[a[1]] = a[2] }
    }
    {
      p = $2; fl = $6; st = "missing"; ch = 0; sy = "-"
      f = tmp "/" $1
      r = (getline l < f)
      if (r >= 0) {                      # status file exists: directory is there
        st = "clean"; up = 0; ab = 0
        while (r > 0) {
          if (l ~ /^# branch\.upstream /) up = 1
          else if (l ~ /^# branch\.ab /) {
            split(l, x, " "); ah = substr(x[3], 2) + 0; bh = substr(x[4], 2) + 0; ab = 1
          }
          else if (l !~ /^#/) ch++
          r = (getline l < f)
        }
        close(f)
        if (ch > 0) st = "dirty"
        if (ab) sy = (ah == 0 && bh == 0) ? "ok" : (ah > 0 ? "+" ah : "") (bh > 0 ? "-" bh : "")
        else if (up) sy = "gone"
      }
      dp = p
      if (index(p, main "/") == 1) dp = substr(p, length(main) + 2)
      else if (home != "" && index(p, home "/") == 1) dp = "~" substr(p, length(home) + 1)
      if (p == here) fl = (fl == "-" ? "" : fl) "c"
      hd = ($5 == "-") ? "-" : substr($5, 1, 7)
      print $1, $4, $3, hd, st, ch, sy, age(ct[$5]), dp, fl, p
    }'
  rm -rf "$tmp"
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

# Pretty label for a worktree path: relative to the main checkout, else ~/...
_wt_label() {
  local wtpath="$1" root; root=$(_wt_main_root)
  case "$wtpath" in
    "$root"/*) printf '%s\n' "${wtpath#"$root"/}" ;;
    *)         printf '%s\n' "${wtpath/#$HOME/~}" ;;
  esac
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

# ---- resolving what the user typed ------------------------------------------

# <key> -> worktree ID. Accepts a numeric ID, "." (the worktree you're in),
# an exact name, an exact branch, or a unique case-insensitive substring of
# either. Errors (to stderr) on no match / ambiguity.
_wt_resolve_id() {
  local key="$1" rows m n top
  rows=$(_wt_list_raw)
  [[ -z "$rows" ]] && { echo "wt: no linked worktrees" >&2; return 1; }
  case "$key" in
    ''|*[!0-9]*) ;;
    *)
      m=$(printf '%s\n' "$rows" | awk -F'\t' -v i="$key" '$1 == i { print $1 }')
      [[ -n "$m" ]] && { echo "$m"; return 0; }
      echo "wt: no worktree #$key (run: wt ls)" >&2; return 1 ;;
  esac
  if [[ "$key" == "." ]]; then
    top=$(git rev-parse --show-toplevel 2>/dev/null)
    m=$(printf '%s\n' "$rows" | awk -F'\t' -v p="$top" '$2 == p { print $1 }')
    [[ -n "$m" ]] && { echo "$m"; return 0; }
    echo "wt: you're not inside a linked worktree" >&2; return 1
  fi
  m=$(printf '%s\n' "$rows" | awk -F'\t' -v k="$key" '
    $4 == k { print $1; hit = 1; exit }
    $3 == k && b == "" { b = $1 }
    END { if (!hit && b != "") print b }')
  [[ -n "$m" ]] && { echo "$m"; return 0; }
  m=$(printf '%s\n' "$rows" | awk -F'\t' -v k="$key" '
    BEGIN { k = tolower(k) }
    index(tolower($4), k) || ($3 !~ /^\(/ && index(tolower($3), k)) { print $1 "\t" $4 "\t" $3 }')
  n=$(printf '%s' "$m" | grep -c . || true)
  if [[ "$n" -eq 1 ]]; then printf '%s\n' "$m" | cut -f1; return 0; fi
  if [[ "$n" -gt 1 ]]; then
    echo "wt: '$key' matches several worktrees - be more specific:" >&2
    printf '%s\n' "$m" | awk -F'\t' '{ printf "  #%s  %s  (%s)\n", $1, $2, $3 }' >&2
    return 1
  fi
  echo "wt: nothing matches '$key' (run: wt ls)" >&2
  return 1
}

# <key> -> worktree path.
_wt_resolve() {
  local id; id=$(_wt_resolve_id "$1") || return 1
  _wt_list_raw | awk -F'\t' -v i="$id" '$1 == i { print $2 }'
}

# Selectors ("2 4,5 7-9 all feat-a .") -> unique IDs in the order given,
# space-separated. Any bad selector aborts with NOTHING selected: never act
# on a partial guess when the next step deletes things.
_wt_select_ids() {
  local rows total tok lo hi id out=" "
  rows=$(_wt_list_raw)
  [[ -z "$rows" ]] && { echo "wt: no linked worktrees" >&2; return 1; }
  total=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    case "$tok" in
      all|-a|--all)
        id=1
        while [[ $id -le $total ]]; do
          [[ "$out" == *" $id "* ]] || out="$out$id "
          id=$((id + 1))
        done
        continue ;;
      *[!0-9]*)
        lo=${tok%%-*}; hi=${tok#*-}
        if [[ "$tok" == *-* && -n "$lo" && -n "$hi" && "$lo" != *[!0-9]* && "$hi" != *[!0-9]* ]]; then
          if [[ $lo -gt $hi ]]; then id=$lo; lo=$hi; hi=$id; fi
          if [[ $lo -lt 1 || $hi -gt $total ]]; then
            echo "wt: range $tok is outside 1-$total (run: wt ls)" >&2; return 1
          fi
          while [[ $lo -le $hi ]]; do
            [[ "$out" == *" $lo "* ]] || out="$out$lo "
            lo=$((lo + 1))
          done
          continue
        fi
        id=$(_wt_resolve_id "$tok") || return 1 ;;
      *)
        if [[ $tok -lt 1 || $tok -gt $total ]]; then
          echo "wt: no worktree #$tok (run: wt ls)" >&2; return 1
        fi
        id=$((tok + 0)) ;;
    esac
    [[ "$out" == *" $id "* ]] || out="$out$id "
  done <<EOF
$(printf '%s\n' "$1" | tr ', ' '\n\n')
EOF
  out="${out# }"; out="${out% }"
  [[ -z "$out" ]] && { echo "wt: nothing selected" >&2; return 1; }
  printf '%s\n' "$out"
}

# ---- removal ----------------------------------------------------------------

# What would be lost by removing this worktree (and its branch unless keep=1)?
# Prints e.g. "2 modified, 5 untracked, 3 unpushed commit(s)", or nothing.
# Untracked counts too: `worktree remove --force` deletes those files for
# good (ignored files like .env are not counted). Unpushed = commits reachable
# from nothing else (no other branch, remote-tracking ref or tag).
_wt_risk() {
  local wtpath="$1" branch="$2" head="$3" keep="$4" files="" c=""
  if [[ -d "$wtpath" ]]; then
    files=$(git -C "$wtpath" --no-optional-locks status --porcelain 2>/dev/null | awk '
      /^\?\?/ { u++; next } { m++ }
      END { if (m) s = m " modified"; if (u) s = s (s ? ", " : "") u " untracked"; printf "%s", s }')
  fi
  case "$branch" in
    "(bare)") ;;
    "(detached)")
      [[ "$head" != "-" ]] && c=$(git rev-list --count "$head" --not --branches --remotes --tags 2>/dev/null) ;;
    *)
      [[ "$keep" == 1 ]] \
        || c=$(git rev-list --count "refs/heads/$branch" --not --exclude="$branch" --branches --remotes --tags 2>/dev/null) ;;
  esac
  [[ -n "$c" && "$c" != 0 ]] && files="${files:+$files, }$c unpushed commit(s)"
  printf '%s' "$files"
}

# _wt_risk for many targets at once, in parallel (one git status each).
# stdin: _wt_list_raw rows. stdout: "id<TAB>risk" per row, risk "-" if safe.
_wt_risk_many() {
  local keep="$1" tmp id wtpath branch name head flags
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/wt.XXXXXX") || return 1
  (
    while IFS=$'\t' read -r id wtpath branch name head flags; do
      [[ -z "$id" ]] && continue
      _wt_risk "$wtpath" "$branch" "$head" "$keep" >"$tmp/$id" &
      printf '%s\n' "$id" >>"$tmp/order"
    done
    wait
  )
  while IFS= read -r id; do
    printf '%s\t%s\n' "$id" "$(cat "$tmp/$id" 2>/dev/null)" | awk -F'\t' -v OFS='\t' '{ if ($2 == "") $2 = "-"; print }'
  done <"$tmp/order"
  rm -rf "$tmp"
}

# If this shell is inside <path>, move it to the main checkout first -
# otherwise you'd be left standing in a deleted directory. Must run in the
# CURRENT shell (never inside $(...)).
_wt_leave_if_inside() {
  local target="$1" here real="" root
  here="$(pwd -P 2>/dev/null)/"
  [[ -d "$target" ]] && real=$(cd "$target" 2>/dev/null && pwd -P)
  if [[ "$PWD/" == "$target"/* || ( -n "$real" && "$here" == "$real"/* ) ]]; then
    root=$(_wt_main_root)
    [[ -n "$root" ]] && cd "$root" \
      && printf '%s-> moved you to the main checkout (%s)%s\n' "$_WT_DIM" "${root/#$HOME/~}" "$_WT_RESET"
  fi
  return 0
}

# Remove one worktree + its branch (unless keep=1). Prints one status line.
# Locked trees are skipped, the default branch is never deleted, and a stale
# entry (directory already gone) is pruned instead of removed.
# Does not prune other entries - callers run `git worktree prune` per batch.
_wt_remove_one() {
  local wtpath="$1" branch="$2" head="$3" flags="$4" keep="$5" label err note="" db
  label=$(_wt_label "$wtpath")
  if [[ "$flags" == *l* ]]; then
    printf '%s🔒 skipped %s%s - locked (unlock: git worktree unlock "%s")\n' \
      "$_WT_YELLOW" "$label" "$_WT_RESET" "$wtpath"
    return 1
  fi
  if [[ -d "$wtpath" ]]; then
    if ! err=$(git worktree remove --force "$wtpath" 2>&1); then
      printf '%s❌ %s: %s%s\n' "$_WT_RED" "$label" "$err" "$_WT_RESET"
      return 1
    fi
  else
    git worktree prune 2>/dev/null   # stale: drop the entry so the branch is free
  fi
  if [[ "$keep" != 1 && "$branch" != "(detached)" && "$branch" != "(bare)" ]]; then
    db=$(_wt_default_branch)
    if [[ "$branch" == "$db" ]]; then
      note="kept default branch $branch"
    elif git branch -D "$branch" >/dev/null 2>&1; then
      note="branch $branch deleted (was ${head:0:7})"
    else
      note="branch $branch kept (checked out elsewhere)"
    fi
  fi
  # Braces matter: bash 3.2 reads a multibyte char right after $VAR as part
  # of the variable name, turning "$_WT_DIM·" into garbage.
  [[ -n "$note" ]] && note=" ${_WT_DIM}· ${note}${_WT_RESET}"
  printf '%s🗑  removed%s %s%s%s%s\n' "$_WT_RED" "$_WT_RESET" "$_WT_BOLD" "$label" "$_WT_RESET" "$note"
}

# The `wt rm` flow: show what goes, warn about anything that would be lost,
# confirm on a TTY (default Yes when nothing is lost, No otherwise), remove.
# Non-interactive callers (scripts, agents) are not prompted - as in v2.
_wt_rm_ids() {
  local ids="$1" keep="$2" yes="$3" rows targets risks id wtpath branch name head flags risk
  local plan="" risky=0 count=0 removed=0 ans="" wn=4
  rows=$(_wt_list_raw)
  # Target rows in the order given, then every risk check in parallel.
  targets=$(printf '%s\n' "$rows" | awk -F'\t' -v ids=" $ids " '
    { row[$1] = $0 }
    END { n = split(ids, a, " "); for (i = 1; i <= n; i++) if (a[i] in row) print row[a[i]] }')
  risks=$(printf '%s\n' "$targets" | _wt_risk_many "$keep")
  while IFS=$'\t' read -r id wtpath branch name head flags; do
    [[ -z "$id" ]] && continue
    risk=$(printf '%s\n' "$risks" | awk -F'\t' -v i="$id" '$1 == i { print $2 }')
    [[ "$risk" != "-" && -n "$risk" ]] && risky=1
    [[ ${#name} -gt $wn ]] && wn=${#name}
    plan="$plan$id	$wtpath	$branch	$name	$head	$flags	${risk:--}
"
    count=$((count + 1))
  done <<EOF
$targets
EOF

  printf '\n%sRemove %d worktree(s)%s%s:\n' "$_WT_BOLD" "$count" \
    "$([[ "$keep" == 1 ]] && echo ", keeping branches" || echo " + their branches")" "$_WT_RESET"
  while IFS=$'\t' read -r id wtpath branch name head flags risk; do
    [[ -z "$id" ]] && continue
    [[ "$branch" == "(detached)" ]] && branch="@${head:0:7}"
    printf '  %s#%-3s%s %-*s  %s' "$_WT_DIM" "$id" "$_WT_RESET" "$wn" "$name" "$branch"
    [[ "$flags" == *l* ]] && printf '  %s🔒 locked - will be skipped%s' "$_WT_YELLOW" "$_WT_RESET"
    [[ "$risk" != "-" ]] && printf '  %s⚠ %s%s' "$_WT_YELLOW" "$risk" "$_WT_RESET"
    printf '\n'
  done <<EOF
$plan
EOF

  if [[ "$yes" != 1 && -t 0 ]]; then
    if [[ $risky -eq 1 ]]; then
      printf '%s⚠  the above would be lost for good.%s Remove? [y/N] ' "$_WT_YELLOW" "$_WT_RESET"
      read -r ans
      [[ "$ans" == [yY] || "$ans" == [yY][eE][sS] ]] || { echo "aborted - nothing removed"; return 1; }
    else
      printf 'Remove? [Y/n] '
      read -r ans
      [[ -z "$ans" || "$ans" == [yY] || "$ans" == [yY][eE][sS] ]] || { echo "aborted - nothing removed"; return 1; }
    fi
  fi
  echo
  while IFS=$'\t' read -r id wtpath branch name head flags risk; do
    [[ -z "$id" ]] && continue
    _wt_leave_if_inside "$wtpath"
    _wt_remove_one "$wtpath" "$branch" "$head" "$flags" "$keep" && removed=$((removed + 1))
  done <<EOF
$plan
EOF
  git worktree prune 2>/dev/null
  printf '\n%s✅ removed %d of %d worktree(s)%s\n\n' "$_WT_GREEN" "$removed" "$count" "$_WT_RESET"
  [[ $removed -eq $count ]]
}

# ---- presentation helpers ---------------------------------------------------

# Sets _WT_* globals for this call. Re-run every invocation (not once at
# source time) so piping/redirecting `wt ls > file` degrades to plain text.
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

_wt_no_worktrees() {
  printf '%s🥱 wt: no linked worktrees yet%s - try: %swt add <branch>%s\n' \
    "$_WT_DIM" "$_WT_RESET" "$_WT_CYAN" "$_WT_RESET"
}

# Static table (wt ls -p, or any non-TTY wt ls). Optional 2nd arg: rows
# already collected (the TUI passes its data so quitting costs nothing).
_wt_print_table() {
  local all="${1:-0}" data="${2:-}" root total stale width=0
  [[ -z "$data" ]] && data=$(_wt_collect)
  [[ -z "$data" ]] && { _wt_no_worktrees; return 0; }
  root=$(_wt_main_root)
  total=$(printf '%s\n' "$data" | wc -l | tr -d ' ')
  stale=$(printf '%s\n' "$data" | awk -F'\t' '$10 ~ /p/' | wc -l | tr -d ' ')
  if [[ -t 1 ]]; then _wt_tty_size; width=$_WT_COLS; fi
  printf '\n%s%swt%s %s· %s · %d worktree(s)%s%s\n\n' \
    "$_WT_BOLD" "$_WT_CYAN" "$_WT_RESET" "$_WT_DIM" "${root##*/}" "$((total - stale))" \
    "$([[ $stale -gt 0 ]] && printf ' + %d stale' "$stale")" "$_WT_RESET"
  printf '%s\n' "$data" | _wt_render static "$width" 0 1 0 " " "$all"
  [[ -t 1 ]] && printf '\n%sTip: wt go <id|name>  ·  wt rm <ids|name>  ·  wt  (interactive)  ·  wt help%s\n' \
    "$_WT_DIM" "$_WT_RESET"
  echo
}

# ---- interactive UI (renderer + TUI) ----------------------------------------
# ---- display layer: table renderer + interactive manager ---------------------
# Needs from the data layer: _wt_collect, _wt_list_raw, _wt_main_root,
# _wt_state_emoji, _wt_risk_many, _wt_leave_if_inside, _wt_remove_one,
# _wt_print_table, wt add.
#
# The TUI renders INLINE (no alternate screen, like fzf --height): it remembers
# how many lines it drew and redraws by moving the cursor back up. Each frame
# costs one awk fork (+ one `stty size` in bash; zsh keeps $LINES/$COLUMNS).

_WT_ESC=$'\033'

# Table renderer. Input: _wt_collect rows on stdin. Runs under LC_ALL=C so
# awk counts bytes everywhere; dw()/cut()/tail() then count UTF-8 continuation
# bytes by hand so names like "café" still line up. Never pads multibyte
# strings with printf %-Ns (that pads by bytes).
_WT_AWK_RENDER='
function sp(k,   s) { s = ""; while (k > 200) { s = s SP; k -= 200 } return s substr(SP, 1, k) }
function dw(s,   t) { if (s !~ /[\200-\377]/) return length(s); t = s; return length(s) - gsub(/[\200-\277]/, "", t) }
function cut(s, w,   i, l, n) {
  if (s !~ /[\200-\377]/) return substr(s, 1, w)
  l = length(s); n = 0
  for (i = 1; i <= l; i++) if (substr(s, i, 1) !~ /[\200-\277]/ && ++n > w) return substr(s, 1, i - 1)
  return s
}
function tail(s, w,   i, n) {
  if (s !~ /[\200-\377]/) return substr(s, length(s) - w + 1)
  n = 0
  for (i = length(s); i >= 1; i--) if (substr(s, i, 1) !~ /[\200-\277]/ && ++n == w) return substr(s, i)
  return s
}
function fit(s, w,   l) {
  if (w <= 0) return ""
  l = dw(s)
  if (l > w) return cut(s, w - 1) "…"
  return s sp(w - l)
}
function fitl(s, w, pad,   l) {
  if (w <= 0) return ""
  l = dw(s)
  if (l > w) return "…" tail(s, w - 1)
  return pad ? s sp(w - l) : s
}
function take(w, lo,   t) {
  t = w - lo
  if (t <= 0 || d <= 0) return w
  if (t > d) t = d
  d -= t
  return w - t
}
function mx(a, b) { return a > b ? a : b }
function stcol(s) { return s == "clean" ? G : s == "dirty" ? Y : D }
function sycol(s) { if (s == "ok") return G; if (s == "-") return D; if (s == "gone") return RED; if (index(s, "-")) return Y; return C }
function badge(s) { return s == "clean" ? EC : s == "dirty" ? ED : s == "missing" ? EM : "      " }
function cells(i, pad) {
  return fit(vidd[i], wid) "  " badge(vst[i]) " " fit(vstw[i], 8) "  " fit(vnm[i], wnm) "  " fit(vbrd[i], wbr) "  " \
    fit(vsy[i], wsy) "  " fit(vag[i], wag) (showpath ? "  " fitl(vdp[i], wdp, pad) : "")
}
function row(i,   mk, s) {
  mk = index(marks, " " vid[i] " ") ? G "●" R : " "
  if (mode == "tui" && i == cur) return C B "❯" R mk " " INV B cells(i, 1) R
  s = fit(vidd[i], wid) "  " stcol(vst[i]) badge(vst[i]) " " fit(vstw[i], 8) R "  " \
    (vcur[i] ? B C : B) fit(vnm[i], wnm) R "  " (vdet[i] ? D : "") fit(vbrd[i], wbr) R "  " \
    sycol(vsy[i]) fit(vsy[i], wsy) R "  " D fit(vag[i], wag) R (showpath ? "  " D fitl(vdp[i], wdp, 0) R : "")
  return (mode == "tui" ? " " mk " " : "") s
}
BEGIN {
  FS = "\t"; F = tolower(ENVIRON["WT_F"]); EOL = (mode == "tui") ? K : ""
  SP = "                                                                                                    "; SP = SP SP
}
{ raw[++nr] = $0 }
END {
  for (i = 1; i <= nr; i++) {
    split(raw[i], f, "\t")
    if (index(f[10], "p")) { nst++; if (slo == "" || f[1] + 0 < slo) slo = f[1] + 0; if (f[1] + 0 > shi) shi = f[1] + 0 }
    else nlv++
  }
  collapse = (mode == "static" && !all && nst > 3)
  n = 0; wid = 2; wnm = 4; wbr = 6; wsy = 4; wag = 3; wdp = 4
  for (i = 1; i <= nr; i++) {
    split(raw[i], f, "\t")
    if (index(f[10], "p") && (mode == "tui" || collapse)) continue
    if (mode == "tui" && F != "" && !index(tolower(f[2] " " f[3]), F)) continue
    n++
    vid[n] = f[1]; vnm[n] = f[2]; vbr[n] = f[3]; vhd[n] = f[4]; vst[n] = f[5]; vsy[n] = f[7]; vag[n] = f[8]
    vdp[n] = f[9]; vfl[n] = f[10]; vpa[n] = f[11]
    vcur[n] = index(f[10], "c") > 0
    vidd[n] = f[1] (vcur[n] ? "*" : "")
    vstw[n] = f[5]
    if (f[5] == "dirty" && f[6] + 0 > 0) vstw[n] = "dirty " (f[6] + 0 > 99 ? "99+" : f[6] + 0)
    vdet[n] = (f[3] == "(detached)")
    vbrd[n] = vdet[n] ? "@" f[4] : f[3]
    wid = mx(wid, dw(vidd[n])); wnm = mx(wnm, dw(vnm[n])); wbr = mx(wbr, dw(vbrd[n]))
    wsy = mx(wsy, dw(vsy[n])); wag = mx(wag, dw(vag[n])); wdp = mx(wdp, dw(vdp[n]))
  }
  g = (mode == "tui") ? 3 : 0
  showpath = 1
  if (width > 0) {
    fixed = g + wid + wsy + wag + 25
    d = fixed + wnm + wbr + 2 + wdp - (width - 2)
    if (d > 0) {
      nn0 = wnm; nb0 = wbr
      wbr = take(wbr, 24); wdp = take(wdp, 16); wnm = take(wnm, 16); wbr = take(wbr, 12)
      if (d > 0) {
        showpath = 0; d -= wdp + 2
        if (d < 0) {
          give = -d; d = 0
          t = nn0 - wnm; if (t > give) t = give; wnm += t; give -= t
          t = nb0 - wbr; if (t > give) t = give; wbr += t
        }
      }
      wbr = take(wbr, 8); wnm = take(wnm, 8)
    }
  }
  if (mode == "tui") {
    if (cur == 0) { cur = 1; for (i = 1; i <= n; i++) if (vcur[i]) { cur = i; break } }
    if (cur > n) cur = n
    if (cur < 1) cur = 1
    if (h < 1) h = 1
    if (top > cur) top = cur
    if (cur >= top + h) top = cur - h + 1
    if (top > n - h + 1) top = n - h + 1
    if (top < 1) top = 1
    if (meta) {
      vids = " "; for (i = 1; i <= n; i++) vids = vids vid[i] " "
      printf "%d\t%d\t%d\t%d\t%d\t%s", n, (n ? cur : 0), top, nlv, nst, vids
      if (n) printf "\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", vid[cur], vnm[cur], vbr[cur], vhd[cur], vpa[cur], (vfl[cur] == "" ? "-" : vfl[cur]), vst[cur], vdp[cur]
      printf "\n"
    }
  }
  print (g ? "   " : "") B C fit("ID", wid) "  " fit("STATE", 15) "  " fit("NAME", wnm) "  " fit("BRANCH", wbr) "  " \
    fit("SYNC", wsy) "  " fit("AGE", wag) (showpath ? "  PATH" : "") R EOL
  if (mode == "tui") {
    if (n == 0) {
      print "   " D (F != "" ? "(no worktrees match \"" ENVIRON["WT_F"] "\")" : "(no live worktrees - p prunes the stale entries)") R EOL
      exit
    }
    last = top + h - 1; if (last > n) last = n
    for (i = top; i <= last; i++) print row(i) EOL
    exit
  }
  for (i = 1; i <= n; i++) print row(i)
  if (collapse) {
    ids = (slo == shi) ? "ID " slo : "IDs " slo "-" shi
    if (width > 0 && width < 100) print D "🗿 " nst " stale (" ids ") · wt prune" R
    else print D "🗿 " nst " stale entries (directory deleted, " ids ") · wt prune to clean up · wt ls -a to show" R
  }
}'

_wt_badges() {
  [[ -n "${_WT_EC:-}" ]] && return 0
  _WT_EC=$(_wt_state_emoji clean)
  _WT_ED=$(_wt_state_emoji dirty)
  _WT_EM=$(_wt_state_emoji missing)
}

# _wt_render_awk mode width cur top h marks all meta filter   (stdin: _wt_collect rows)
_wt_render_awk() {
  _wt_badges
  WT_F="$9" LC_ALL=C awk -v mode="$1" -v width="$2" -v cur="$3" -v top="$4" -v h="$5" -v marks="$6" -v all="$7" -v meta="$8" \
    -v R="$_WT_RESET" -v B="$_WT_BOLD" -v D="$_WT_DIM" -v RED="$_WT_RED" -v G="$_WT_GREEN" -v Y="$_WT_YELLOW" -v C="$_WT_CYAN" \
    -v INV="${_WT_ESC}[7m" -v K="${_WT_ESC}[K" -v EC="$_WT_EC" -v ED="$_WT_ED" -v EM="$_WT_EM" "$_WT_AWK_RENDER"
}

# _wt_render <static|tui> <width 0=unlimited> <cur> <top> <h> <marks " 1 4 "> <all 0|1>
# Prints the column header line, then rows. stdin: _wt_collect rows.
_wt_render() {
  _wt_render_awk "${1:-static}" "${2:-0}" "${3:-1}" "${4:-1}" "${5:-0}" "${6:- }" "${7:-0}" 0 ""
}

# Sets _WT_LINES / _WT_COLS. zsh keeps $LINES/$COLUMNS current (no fork).
_wt_tty_size() {
  local s=""
  if [[ -n "${ZSH_VERSION:-}" && "${LINES:-0}" -gt 0 && "${COLUMNS:-0}" -gt 0 ]]; then
    _WT_LINES=$LINES; _WT_COLS=$COLUMNS; return 0
  fi
  s=$(stty size </dev/tty 2>/dev/null)
  case "$s" in
    [0-9]*' '[0-9]*) _WT_LINES=${s% *}; _WT_COLS=${s#* } ;;
    *) _WT_LINES=$(tput lines 2>/dev/null || echo 24); _WT_COLS=$(tput cols 2>/dev/null || echo 80) ;;
  esac
  [[ "$_WT_LINES" -gt 0 && "$_WT_COLS" -gt 0 ]] 2>/dev/null || { _WT_LINES=24; _WT_COLS=80; }
}

# One more byte of an escape sequence into _WT_R, with a short timeout
# (bash 3.2's read -t only takes whole seconds).
_wt_readkey_t() {
  _WT_R=""
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    read -rs -k 1 -t 0.05 _WT_R
  else
    IFS= read -rsn1 -t 1 _WT_R
  fi
}

# Reads one keypress into _WT_K: up down left right pgup pgdn home end enter
# space bs del esc tab btab ctrlc ctrld ctrlu none, or the literal character.
_wt_readkey() {
  local k="" s=""
  _WT_K=""
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    read -rs -k 1 k || { _WT_K=eof; return 1; }
  else
    IFS= read -rsn1 k || { _WT_K=eof; return 1; }
  fi
  case "$k" in
    $'\e') ;;
    ''|$'\n'|$'\r') _WT_K=enter; return 0 ;;
    ' ') _WT_K=space; return 0 ;;
    $'\t') _WT_K=tab; return 0 ;;
    $'\x7f'|$'\b') _WT_K=bs; return 0 ;;
    $'\x03') _WT_K=ctrlc; return 0 ;;
    $'\x04') _WT_K=ctrld; return 0 ;;
    $'\x15') _WT_K=ctrlu; return 0 ;;
    [[:cntrl:]]) _WT_K=none; return 0 ;;
    *) _WT_K="$k"; return 0 ;;
  esac
  _wt_readkey_t || { _WT_K=esc; return 0; }
  if [[ "$_WT_R" != "[" && "$_WT_R" != "O" ]]; then _WT_K=esc; return 0; fi
  _wt_readkey_t || { _WT_K=esc; return 0; }
  case "$_WT_R" in
    A) _WT_K=up ;;
    B) _WT_K=down ;;
    C) _WT_K=right ;;
    D) _WT_K=left ;;
    H) _WT_K=home ;;
    F) _WT_K=end ;;
    Z) _WT_K=btab ;;
    [0-9])
      s="$_WT_R"
      while _wt_readkey_t && [[ "$_WT_R" != "~" && ${#s} -lt 4 ]]; do s="$s$_WT_R"; done
      case "$s" in
        1|7) _WT_K=home ;;
        4|8) _WT_K=end ;;
        3) _WT_K=del ;;
        5) _WT_K=pgup ;;
        6) _WT_K=pgdn ;;
        *) _WT_K=none ;;
      esac ;;
    *) _WT_K=none ;;
  esac
  return 0
}

# Copy text to the system clipboard. rc 1 when no clipboard tool is usable.
_wt_clip() {
  if command -v pbcopy >/dev/null 2>&1; then printf '%s' "$1" | pbcopy
  elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1; then printf '%s' "$1" | wl-copy
  elif [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then printf '%s' "$1" | xclip -selection clipboard
  elif [[ -n "${DISPLAY:-}" ]] && command -v xsel >/dev/null 2>&1; then printf '%s' "$1" | xsel --clipboard --input
  else return 1
  fi
}

# ---- interactive manager -------------------------------------------------------
# _wt_tui <browse|go|rm>. The helpers below share _wt_tui's locals (bash and
# zsh both scope `local` dynamically), and the key loop runs in the current
# shell - no pipe, no subshell - so `cd` sticks.

_wt_tui() {
  local mode="${1:-browse}"
  local data="" root repo mainbr saved="" oldint="" drawn=0 hv=1
  local cur=0 top=1 marks=" " filt="" typing=0 ui=list help=0 msg="" menu_i=1
  local inkind="" inbuf="" tgts="" tgtn=0 tgtname="" cfm="" cfmn=0 results="" act="" arg="" delok=0 k
  local vn=0 vcur=0 vtop=1 nlv=0 nst=0 vids=" " cid="" cname="" cbr="" chd="" cpath="" cfl="" cst="" cdp=""
  root=$(_wt_main_root); repo=${root##*/}
  mainbr=$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null) || mainbr="detached HEAD"
  _wt_badges
  printf '%s⏳ reading worktrees…%s' "$_WT_DIM" "$_WT_RESET"
  data=$(_wt_collect)
  printf '\r%s[K' "$_WT_ESC"
  if [[ -z "$data" ]]; then
    printf '%s🥱 wt: no linked worktrees yet%s - try: %swt add <branch>%s\n' "$_WT_DIM" "$_WT_RESET" "$_WT_CYAN" "$_WT_RESET"
    return 0
  fi
  saved=$(stty -g </dev/tty 2>/dev/null)
  # bash's `read -n` turns ISIG back on, so ctrl-c arrives as SIGINT and would
  # kill the loop with the terminal still raw. Trap it (bash only; zsh reads
  # it as a plain \x03 byte) and unwind just the pending read.
  _WT_INT=0
  if [[ -z "${ZSH_VERSION:-}" ]]; then
    oldint=$(trap -p INT)
    trap '_WT_INT=1; case "${FUNCNAME[0]:-}" in _wt_readkey*) return 1 ;; esac' INT
  fi
  _wt_tui_resume
  while [[ -z "$act" ]]; do
    _wt_tui_draw
    if ! _wt_readkey; then
      if [[ "$_WT_INT" == 1 ]]; then act=abort; else act=quit; fi
      break
    fi
    k=$_WT_K
    if [[ "$_WT_INT" == 1 ]]; then _WT_INT=0; k=ctrlc; fi
    msg=""
    case "$ui" in
      menu)    _wt_tui_key_menu ;;
      confirm) _wt_tui_key_confirm ;;
      input)   _wt_tui_key_input ;;
      *)       _wt_tui_key_list ;;
    esac
  done
  _wt_tui_end
  if [[ -z "${ZSH_VERSION:-}" ]]; then
    if [[ -n "$oldint" ]]; then eval "$oldint"; else trap - INT; fi
  fi
  _wt_tui_finish
}

_wt_tui_resume() {
  stty -echo -icanon -isig </dev/tty 2>/dev/null
  printf '%s[?25l' "$_WT_ESC"
  drawn=0
}

# Erase the drawn region, show the cursor, give the terminal back.
_wt_tui_end() {
  if (( drawn > 1 )); then printf '\r%s[%dA' "$_WT_ESC" $((drawn - 1)); else printf '\r'; fi
  printf '%s[J%s[?25h' "$_WT_ESC" "$_WT_ESC"
  drawn=0
  [[ -n "$saved" ]] && stty "$saved" </dev/tty 2>/dev/null
}

_wt_tui_reload() {
  data=$(_wt_collect)
  [[ -z "$data" ]] && act=empty
}

# Plain text -> at most _WT_COLS-1 characters (callers add color around it).
_wt_tui_trunc() {
  local s="$1" w=$((_WT_COLS - 1))
  if (( ${#s} > w )); then s="${s:0:$((w - 1))}…"; fi
  printf '%s' "$s"
}

_wt_tui_draw() {
  local frame meta h rows footn=2 title plain pos fa fb out i lbl bar barplain sel hint pfx
  local R="$_WT_RESET" B="$_WT_BOLD" D="$_WT_DIM" C="$_WT_CYAN" Y="$_WT_YELLOW" RED="$_WT_RED" G="$_WT_GREEN"
  local INV="${_WT_ESC}[7m" EK="${_WT_ESC}[K"
  _wt_tty_size
  if [[ "$ui" == confirm ]]; then footn=$((2 + cfmn))
  elif [[ "$ui" == list && "$help" == 1 ]]; then footn=5
  fi
  h=$((_WT_LINES - 3 - footn)); (( h < 1 )) && h=1
  hv=$h
  frame=$(_wt_render_awk tui "$_WT_COLS" "$cur" "$top" "$h" "$marks" 0 1 "$filt" <<EOF
$data
EOF
)
  meta=${frame%%$'\n'*}; frame=${frame#*$'\n'}
  cid=""; cname=""; cbr=""; chd=""; cpath=""; cfl=""; cst=""; cdp=""
  IFS=$'\t' read -r vn vcur vtop nlv nst vids cid cname cbr chd cpath cfl cst cdp <<EOF
$meta
EOF
  if (( vn > 0 )); then cur=$vcur; else cur=1; fi
  top=$vtop
  if (( vn == 0 )); then rows=1; else rows=$((vn - vtop + 1)); (( rows > h )) && rows=$h; fi

  # title
  pfx="wt"; [[ "$mode" == go ]] && pfx="wt go"; [[ "$mode" == rm ]] && pfx="wt rm"
  title="${B}${C}${pfx}${R} ${D}·${R} ${B}${repo}${R} ${D}· ${nlv} worktree"; (( nlv == 1 )) || title="${title}s"
  plain="$pfx · $repo · $nlv worktrees"
  if (( _WT_COLS >= 70 )); then title="$title · on $mainbr"; plain="$plain · on $mainbr"; fi
  title="$title$R"
  if (( nst > 0 )); then title="$title ${Y}· $nst stale (p prune)$R"; plain="$plain · $nst stale (p prune)"; fi
  if (( typing )) || [[ "$mode" == go && -n "$filt" ]]; then
    title="$title  ${C}/${filt}${R}${INV} ${R}"; plain="$plain  /$filt "
  elif [[ -n "$filt" ]]; then
    title="$title  ${C}/${filt}${R} ${D}($vn)${R}"; plain="$plain  /$filt ($vn)"
  fi
  if (( vn > rows )); then
    pos="$vcur/$vn"
    if (( ${#plain} + ${#pos} + 2 < _WT_COLS )); then title="$title  ${D}${pos}${R}"; fi
  fi

  # footer line A: confirm header / one-shot message / cursor row details
  if [[ "$ui" == confirm ]]; then
    if (( tgtn == 1 )); then lbl="Delete ${tgtname}?"; else lbl="Delete ${tgtn} worktrees?"; fi
    fa="${RED}${B}$(_wt_tui_trunc "$lbl")${R}"
  elif [[ "$ui" == input ]]; then
    if [[ "$inkind" == exec ]]; then fa="${B}$(_wt_tui_trunc "Run a command in $cname:")${R}"
    else fa="${B}$(_wt_tui_trunc "New worktree - branch name (reused if it exists, else created from HEAD):")${R}"; fi
  elif [[ -n "$msg" ]]; then
    fa="$(_wt_tui_trunc "$msg")"
  elif (( vn > 0 )); then
    if [[ "$cbr" == "(detached)" ]]; then lbl="detached @${chd}"; else lbl="$cbr"; fi
    [[ "$cfl" == *l* ]] && lbl="${lbl} · locked"
    pos="${cpath/#$HOME/~}"; i=$((_WT_COLS - 5 - ${#lbl}))
    (( i < 12 )) && i=12
    (( ${#pos} > i )) && pos="…${pos: -$((i - 1))}"
    fa="${D}$(_wt_tui_trunc "${pos}  (${lbl})")${R}"
  elif [[ -n "$filt" ]]; then
    fa="${D}$(_wt_tui_trunc "esc clears the filter")${R}"
  else
    fa=""
  fi

  # footer line B: hints / menu / confirm keys / input
  case "$ui" in
    menu)
      i=1; bar=""; barplain=""
      for lbl in go open status exec "copy path" delete cancel; do
        (( _WT_COLS < 64 )) && [[ "$lbl" == "copy path" ]] && lbl="copy"
        if (( i == menu_i )); then sel="${INV}${B} $lbl ${R}"
        elif [[ "$lbl" == delete ]]; then sel="${RED} $lbl ${R}"
        else sel=" $lbl "; fi
        bar="$bar$sel "; barplain="$barplain $lbl  "
        i=$((i + 1))
      done
      lbl="$cname"; (( ${#lbl} > 20 )) && lbl="${lbl:0:19}…"
      if (( ${#barplain} + ${#lbl} + 4 < _WT_COLS )); then fb="${C}${B}${lbl}${R} ${D}›${R} $bar"; else fb="$bar"; fi ;;
    confirm)
      fb="${D}$(_wt_tui_trunc "y delete worktree + branch · k delete, keep branch · any other key cancels")${R}" ;;
    input)
      fb="${C}›${R} ${inbuf}${INV} ${R}  ${D}⏎ ok · esc cancel${R}" ;;
    *)
      if (( typing )); then hint="type to filter · ⏎ done · esc clear · ↑↓ move"
      elif [[ "$mode" == go ]]; then hint="type to filter · ↑↓ move · ⏎ go · esc cancel"
      elif [[ "$mode" == rm ]]; then hint="↑↓ move · space mark · a all · ⏎ delete · / filter · esc cancel"
      elif (( _WT_COLS >= 88 )); then hint="↑↓ move · ⏎ actions · space mark · / filter · d delete · n new · ? help · q quit"
      else hint="↑↓ ⏎ actions · / filter · d delete · ? help · q quit"; fi
      if [[ -n "${marks// /}" && "$mode" != go ]] && (( ! typing )); then
        i=$(printf '%s' "$marks" | wc -w | tr -d ' ')
        if [[ "$mode" == rm ]]; then hint="● ${i} marked · ⏎ delete them · space toggle · a all/none · esc unmark"
        else hint="● ${i} marked · d delete them · space toggle · a all/none · esc unmark · q quit"; fi
      fi
      fb="${D}$(_wt_tui_trunc "$hint")${R}"
      if [[ "$help" == 1 ]]; then
        fb="$fb$EK"$'\n'"${D}$(_wt_tui_trunc "↑↓ j/k move · PgUp/PgDn/Home/End jump · space mark · a mark all · / filter")${R}"
        fb="$fb$EK"$'\n'"${D}$(_wt_tui_trunc "⏎ actions · g go (cd) · o open in editor · s status · e run command · y copy path")${R}"
        fb="$fb$EK"$'\n'"${D}$(_wt_tui_trunc "d delete · n new worktree · m main checkout · p prune stale · r refresh · q quit")${R}"
      fi ;;
  esac

  out=""
  if (( drawn > 1 )); then out=$'\r'"${_WT_ESC}[$((drawn - 1))A"; elif (( drawn == 1 )); then out=$'\r'; fi
  out="$out$title$EK"$'\n'"$frame"$'\n'"$fa$EK"
  [[ "$ui" == confirm ]] && out="$out"$'\n'"$cfm"
  out="$out"$'\n'"$fb$EK${_WT_ESC}[J"
  printf '%s' "$out"
  drawn=$((2 + rows + footn))
}

_wt_tui_key_list() {
  local v rest allm
  if (( typing )) || [[ "$mode" == go ]]; then
    case "$k" in
      bs)
        if [[ -n "$filt" ]]; then filt=${filt%?}; cur=1; top=1; elif [[ "$mode" != go ]]; then typing=0; fi
        return ;;
      ctrlu) filt=""; cur=1; top=1; return ;;
      esc)
        if [[ -n "$filt" ]]; then filt=""; typing=0; cur=0; top=1; return; fi
        if [[ "$mode" != go ]]; then typing=0; return; fi ;;
      enter) if [[ "$mode" != go ]]; then typing=0; return; fi ;;
      space) filt="$filt "; cur=1; top=1; return ;;
      up|down|pgup|pgdn|home|end|ctrlc|ctrld|eof|tab|btab|left|right|del|none) ;;
      *) if [[ ${#k} -eq 1 ]]; then filt="$filt$k"; cur=1; top=1; return; fi ;;
    esac
  fi
  case "$k" in
    up|k)   cur=$((cur - 1)) ;;
    down|j) cur=$((cur + 1)) ;;
    pgup)   cur=$((cur - hv)); (( cur < 1 )) && cur=1 ;;
    pgdn)   cur=$((cur + hv)) ;;
    home)   cur=1 ;;
    end)    cur=$((vn > 0 ? vn : 1)) ;;
    space)
      (( vn > 0 )) || return
      if [[ "$marks" == *" $cid "* ]]; then marks=${marks/ $cid / }; else marks="$marks$cid "; fi
      cur=$((cur + 1)) ;;
    a)
      (( vn > 0 )) || return
      rest=$vids; allm=1
      while [[ -n "${rest// /}" ]]; do
        rest=${rest# }; v=${rest%% *}; rest=${rest#"$v"}
        [[ "$marks" == *" $v "* ]] || { allm=0; break; }
      done
      rest=$vids
      while [[ -n "${rest// /}" ]]; do
        rest=${rest# }; v=${rest%% *}; rest=${rest#"$v"}
        if (( allm )); then marks=${marks/ $v / }; elif [[ "$marks" != *" $v "* ]]; then marks="$marks$v "; fi
      done ;;
    /) typing=1 ;;
    enter)
      case "$mode" in
        go) _wt_tui_act go ;;
        rm) _wt_tui_act delete ;;
        *)  (( vn > 0 )) && { ui=menu; menu_i=1; } ;;
      esac ;;
    d|x|del) _wt_tui_act delete ;;
    p) _wt_tui_act prune ;;
    r) _wt_tui_act refresh ;;
    '?') help=$((1 - help)) ;;
    q|ctrld|eof) act=quit ;;
    ctrlc) act=abort ;;
    esc)
      if [[ -n "$filt" ]]; then filt=""; cur=0; top=1
      elif [[ -n "${marks// /}" ]]; then marks=" "
      else act=quit; fi ;;
    g|o|s|e|y|n|m)
      [[ "$mode" == browse ]] || return
      case "$k" in
        g) _wt_tui_act go ;;
        o) _wt_tui_act open ;;
        s) _wt_tui_act status ;;
        e) _wt_tui_act exec ;;
        y) _wt_tui_act copy ;;
        n) _wt_tui_act new ;;
        m) _wt_tui_act main ;;
      esac ;;
  esac
  (( cur < 1 )) && cur=1
  return 0
}

_wt_tui_key_menu() {
  case "$k" in
    left|up|btab|h)    menu_i=$((menu_i - 1)); (( menu_i < 1 )) && menu_i=7 ;;
    right|down|tab|l)  menu_i=$((menu_i + 1)); (( menu_i > 7 )) && menu_i=1 ;;
    enter)
      ui=list
      case "$menu_i" in
        1) _wt_tui_act go ;;
        2) _wt_tui_act open ;;
        3) _wt_tui_act status ;;
        4) _wt_tui_act exec ;;
        5) _wt_tui_act copy ;;
        6) _wt_tui_act delete ;;
      esac ;;
    g) ui=list; _wt_tui_act go ;;
    o) ui=list; _wt_tui_act open ;;
    s) ui=list; _wt_tui_act status ;;
    e) ui=list; _wt_tui_act exec ;;
    y|c) ui=list; _wt_tui_act copy ;;
    d|x|del) ui=list; _wt_tui_act delete ;;
    esc|q|ctrlc|ctrld|eof) ui=list ;;
  esac
  return 0
}

_wt_tui_key_confirm() {
  case "$k" in
    y|Y) ui=list; _wt_tui_delete 0 ;;
    k|K) ui=list; _wt_tui_delete 1 ;;
    *)   ui=list; msg="cancelled - nothing deleted" ;;
  esac
  return 0
}

_wt_tui_key_input() {
  case "$k" in
    enter)
      ui=list
      if [[ -z "${inbuf// /}" ]]; then msg="cancelled"; return 0; fi
      if [[ "$inkind" == exec ]]; then act=exec; arg="$cpath"; else act=add; arg="$inbuf"; fi ;;
    esc|ctrlc|ctrld|eof) ui=list; msg="cancelled" ;;
    bs)    inbuf=${inbuf%?} ;;
    ctrlu) inbuf="" ;;
    space) inbuf="$inbuf " ;;
    *)     [[ ${#k} -eq 1 ]] && inbuf="$inbuf$k" ;;
  esac
  return 0
}

# Run an action on the cursor row (or the marked rows, for delete).
_wt_tui_act() {
  local editor
  case "$1" in
    go|open|exec|status|copy|delete)
      if (( vn == 0 )) && [[ "$1" != delete || -z "${marks// /}" ]]; then msg="nothing selected"; return 0; fi ;;
  esac
  case "$1" in
    go|open|exec|status)
      if [[ "$cst" == missing ]]; then msg="⚠ $cname: directory is gone - p prunes stale entries"; return 0; fi ;;
  esac
  case "$1" in
    go)     act=go; arg="$cpath" ;;
    main)   act=main; arg="$root" ;;
    open)
      editor=$(git config --get wt.editor 2>/dev/null || true)
      [[ -z "$editor" ]] && editor="${VISUAL:-${EDITOR:-}}"
      if [[ -z "$editor" ]]; then msg="no editor set - git config --global wt.editor code"; return 0; fi
      act=open; arg="$cpath" ;;
    exec)   ui=input; inkind=exec; inbuf="" ;;
    new)    ui=input; inkind=new; inbuf="" ;;
    copy)
      if _wt_clip "$cpath"; then msg="📋 copied ${cpath/#$HOME/~}"; else msg="no clipboard tool - path: ${cpath/#$HOME/~}"; fi ;;
    status) _wt_tui_status ;;
    delete) _wt_tui_confirm_build ;;
    prune)  _wt_tui_prune ;;
    refresh) _wt_tui_reload; marks=" "; msg="↻ refreshed" ;;
  esac
  return 0
}

_wt_tui_status() {
  local p="$cpath" n="$cname"
  _wt_tui_end
  {
    printf '%s%s%s  %s%s%s\n\n' "$_WT_BOLD" "$n" "$_WT_RESET" "$_WT_DIM" "${p/#$HOME/~}" "$_WT_RESET"
    git -C "$p" -c color.ui=always status -sb
    printf '\n%sChanges%s\n' "$_WT_BOLD" "$_WT_RESET"
    if git -C "$p" diff --quiet HEAD 2>/dev/null; then
      printf '%s(no uncommitted changes to tracked files)%s\n' "$_WT_DIM" "$_WT_RESET"
    else
      git -C "$p" -c color.ui=always diff --stat HEAD
    fi
    printf '\n%sRecent commits%s\n' "$_WT_BOLD" "$_WT_RESET"
    git -C "$p" -c color.ui=always log --oneline --decorate -15
  } 2>&1 | if command -v less >/dev/null 2>&1; then less -R; else cat; fi
  _wt_tui_resume
}

# Resolve the delete targets (by path, so a renumbering can't hit the wrong
# tree) and build the confirm lines with what each deletion would lose.
# tgts rows: id path branch name head flags state risk
_wt_tui_confirm_build() {
  local ids sel risks id p br name hd fl st risk line plain shown=0 more=0 wn wb
  local R="$_WT_RESET" D="$_WT_DIM" Y="$_WT_YELLOW" G="$_WT_GREEN" EK="${_WT_ESC}[K"
  if [[ -n "${marks// /}" ]]; then ids="$marks"; else ids=" $cid "; fi
  sel=$(_wt_list_raw | WT_DATA="$data" awk -F'\t' -v OFS='\t' -v ids="$ids" '
    BEGIN { n = split(ENVIRON["WT_DATA"], L, "\n")
            for (i = 1; i <= n; i++) { split(L[i], f, "\t"); if (index(ids, " " f[1] " ")) { want[f[11]] = 1; st[f[11]] = f[5] } } }
    ($2 in want) { print $0, st[$2] }')
  if [[ -z "$sel" ]]; then msg="nothing to delete - the list changed, r refreshes"; return 0; fi
  risks=$(printf '%s\n' "$sel" | _wt_risk_many 0)
  tgts=$({ printf '%s\n' "$risks"; printf '@@\n'; printf '%s\n' "$sel"; } | awk -F'\t' -v OFS='\t' '
    $0 == "@@" { s = 1; next }
    !s { r[$1] = $2; next }
    { print $0, (($1 in r) && r[$1] != "" ? r[$1] : "-") }')
  tgtn=0; cfm=""
  wn=$(printf '%s\n' "$tgts" | awk -F'\t' 'NR <= 5 { l = length($4); if (l > m) m = l } END { print (m > 24 ? 24 : m) }')
  wb=$(printf '%s\n' "$tgts" | awk -F'\t' 'NR <= 5 { b = ($3 == "(detached)") ? 8 : length($3); if (b > m) m = b } END { print (m > 32 ? 32 : m) }')
  while IFS=$'\t' read -r id p br name hd fl st risk; do
    tgtn=$((tgtn + 1)); tgtname="$name"
    if (( shown >= 5 )); then more=$((more + 1)); continue; fi
    shown=$((shown + 1))
    [[ "$br" == "(detached)" ]] && br="@${hd:0:7}"
    (( ${#br} > wb )) && br="${br:0:$((wb - 1))}…"
    (( ${#name} > wn )) && name="${name:0:$((wn - 1))}…"
    while (( ${#name} < wn )); do name="$name "; done
    while (( ${#br} < wb )); do br="$br "; done
    if [[ "$fl" == *l* ]]; then
      plain="  • ${name}  ${br}  🔒 locked - will be skipped (git worktree unlock first)"
      line="  • ${_WT_BOLD}${name}${R}  ${D}${br}${R}  ${Y}🔒 locked - will be skipped (git worktree unlock first)${R}"
    elif [[ "$st" == missing ]]; then
      plain="  • ${name}  ${br}  directory already gone"
      line="  • ${_WT_BOLD}${name}${R}  ${D}${br}  directory already gone${R}"
    elif [[ "$risk" != "-" ]]; then
      plain="  • ${name}  ${br}  ⚠ ${risk}"
      line="  • ${_WT_BOLD}${name}${R}  ${D}${br}${R}  ${Y}⚠ ${risk}${R}"
    else
      plain="  • ${name}  ${br}  ✓ nothing to lose"
      line="  • ${_WT_BOLD}${name}${R}  ${D}${br}${R}  ${G}✓ nothing to lose${R}"
    fi
    (( ${#plain} > _WT_COLS - 1 )) && line="${D}$(_wt_tui_trunc "$plain")${R}"
    if [[ -n "$cfm" ]]; then cfm="${cfm}${EK}"$'\n'"${line}"; else cfm="$line"; fi
  done <<EOT
$tgts
EOT
  if (( more > 0 )); then cfm="${cfm}${EK}"$'\n'"  ${D}…and ${more} more${R}"; fi
  cfm="${cfm}${EK}"
  cfmn=$((shown + (more > 0 ? 1 : 0)))
  ui=confirm
}

_wt_tui_delete() {
  local keep="$1" id p br name hd fl st risk line ok=0 bad=0 names="" failed="" why="" before moved=0
  results=""
  while IFS=$'\t' read -r id p br name hd fl st risk; do
    [[ -z "$p" ]] && continue
    before=$PWD
    _wt_leave_if_inside "$p" >/dev/null      # its notice would tear the frame
    [[ "$PWD" != "$before" ]] && moved=1
    if line=$(_wt_remove_one "$p" "$br" "$hd" "$fl" "$keep" 2>&1 </dev/null); then
      ok=$((ok + 1))
      if [[ -n "$names" ]]; then names="${names}, ${name}"; else names="$name"; fi
    else
      bad=$((bad + 1))
      if [[ -n "$failed" ]]; then failed="${failed}, ${name}"; else failed="$name"; why="$line"; fi
    fi
    results="${results}${line}"$'\n'
  done <<EOT
$tgts
EOT
  git worktree prune 2>/dev/null
  if (( moved )); then
    results="${results}${_WT_DIM}-> moved you to the main checkout (${root/#$HOME/~})${_WT_RESET}"$'\n'
  fi
  marks=" "; tgts=""; cfm=""; cfmn=0
  delok=$ok
  msg=""
  (( ok > 0 )) && msg="🗑  removed ${ok}: ${names}"
  (( ok > 0 && keep == 1 )) && msg="${msg} (branches kept)"
  if (( bad > 0 )); then
    if (( bad == 1 )); then
      why=$(printf '%s' "$why" | sed "s/${_WT_ESC}\[[0-9;]*m//g")
      failed="$why"
    else
      failed="❌ failed: ${failed}"
    fi
    if [[ -n "$msg" ]]; then msg="${msg} · ${failed}"; else msg="$failed"; fi
  fi
  (( moved )) && msg="${msg} · you were moved to the main checkout"
  if [[ "$mode" == rm ]]; then act=deleted; return 0; fi
  _wt_tui_reload
  return 0
}

_wt_tui_prune() {
  local n
  n=$(git worktree prune -v 2>&1 | grep -c '^Removing' || true)
  _wt_tui_reload
  marks=" "
  if [[ "$n" == 1 ]]; then msg="🧹 pruned 1 stale entry"
  elif [[ "$n" -gt 0 ]]; then msg="🧹 pruned ${n} stale entries"
  else msg="nothing to prune"; fi
}

# After the region is erased: do whatever the user picked.
_wt_tui_finish() {
  local lbl editor
  case "$act" in
    quit)
      [[ "$mode" == browse ]] && _wt_print_table 0 "$data"
      return 0 ;;
    go|main)
      cd "$arg" || return 1
      if [[ "$act" == main ]]; then
        printf '%s🚀 ->%s %s %s(main checkout, %s)%s\n' "$_WT_CYAN" "$_WT_RESET" "${arg/#$HOME/~}" "$_WT_DIM" "$mainbr" "$_WT_RESET"
      else
        if [[ "$cbr" == "(detached)" ]]; then lbl="@${chd}"; else lbl="$cbr"; fi
        printf '%s🚀 ->%s %s%s%s %s(%s)  %s%s\n' "$_WT_CYAN" "$_WT_RESET" "$_WT_BOLD" "$cname" "$_WT_RESET" \
          "$_WT_DIM" "$lbl" "${arg/#$HOME/~}" "$_WT_RESET"
      fi ;;
    open)
      editor=$(git config --get wt.editor 2>/dev/null || true)
      [[ -z "$editor" ]] && editor="${VISUAL:-${EDITOR:-}}"
      printf '%s🚀 %s%s %s\n' "$_WT_CYAN" "$editor" "$_WT_RESET" "${arg/#$HOME/~}"
      ( cd "$arg" && eval "$editor \"$arg\"" ) ;;
    exec)
      printf '%s⚙  %s%s in %s\n' "$_WT_DIM" "$inbuf" "$_WT_RESET" "${arg/#$HOME/~}"
      ( cd "$arg" && eval "$inbuf" ) ;;
    add)
      wt add "$arg" ;;
    deleted|empty)
      [[ -n "$results" ]] && printf '%s' "$results"
      if [[ "$act" == empty ]]; then
        printf '%s🥱 no linked worktrees left%s\n' "$_WT_DIM" "$_WT_RESET"
      elif (( delok > 0 )); then
        printf '\n%s✅ removed %d worktree(s)%s\n\n' "$_WT_GREEN" "$delok" "$_WT_RESET"
      fi ;;
  esac
}

# a < b for dotted versions ("3.2.0" < "3.10.0").
_wt_version_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); if (m > n) n = m
    for (i = 1; i <= n; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 1 }'
}

# `wt update` / `wt-cli --update`: download the latest wt.sh, make sure it IS
# wt.sh and parses in this shell, swap it in atomically, reload it right here.
# Anything off (network, 404 page, syntax error) leaves the install untouched.
_wt_update() {
  local force=0 a url target tmp newver oldver="$WT_VERSION" shname
  for a in "$@"; do
    case "$a" in
      -f|--force) force=1 ;;
      *) echo "usage: wt update [--force]" >&2; return 1 ;;
    esac
  done
  url="${WT_UPDATE_URL:-https://raw.githubusercontent.com/mrx-arafat/wt-cli/main/wt.sh}"
  target="${_WT_SELF:-}"
  [[ -f "$target" ]] || target="$HOME/.wt-cli/wt.sh"
  if [[ ! -f "$target" || ! -w "$target" || ! -w "$(dirname "$target")" ]]; then
    printf '%s❌ wt: cannot write %s - reinstall with install.sh%s\n' "$_WT_RED" "${target/#$HOME/~}" "$_WT_RESET" >&2
    return 1
  fi
  tmp="$target.new.$$"
  printf '%s⬇  checking for a newer wt...%s\n' "$_WT_DIM" "$_WT_RESET"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 30 "$url" -o "$tmp" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 30 -O "$tmp" "$url"
  else
    false
  fi || {
    rm -f "$tmp"
    printf '%s❌ wt: download failed (%s) - your install is untouched%s\n' "$_WT_RED" "$url" "$_WT_RESET" >&2
    return 1
  }
  newver=$(awk -F'"' '/^WT_VERSION=/ { print $2; exit }' "$tmp" 2>/dev/null)
  shname=bash; [[ -n "${ZSH_VERSION:-}" ]] && shname=zsh
  if [[ -z "$newver" ]] || ! "$shname" -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    printf '%s❌ wt: the download is not a valid wt.sh - your install is untouched%s\n' "$_WT_RED" "$_WT_RESET" >&2
    return 1
  fi
  if [[ $force -eq 0 && "$newver" == "$oldver" ]]; then
    rm -f "$tmp"
    printf '%s✅ wt v%s is up to date%s\n' "$_WT_GREEN" "$oldver" "$_WT_RESET"
    return 0
  fi
  if [[ $force -eq 0 ]] && _wt_version_lt "$newver" "$oldver"; then
    rm -f "$tmp"
    printf '%s✅ your wt v%s is newer than the published v%s%s - keep it, or: wt update --force\n' \
      "$_WT_GREEN" "$oldver" "$newver" "$_WT_RESET"
    return 0
  fi
  chmod 644 "$tmp" && mv -f "$tmp" "$target" || {
    rm -f "$tmp"
    printf '%s❌ wt: could not replace %s%s\n' "$_WT_RED" "${target/#$HOME/~}" "$_WT_RESET" >&2
    return 1
  }
  # shellcheck disable=SC1090
  source "$target"
  _wt_setup_colors
  printf '%s✅ updated wt v%s -> v%s%s  %s(%s)%s\n' "$_WT_GREEN" "$oldver" "$WT_VERSION" "$_WT_RESET" \
    "$_WT_DIM" "${target/#$HOME/~}" "$_WT_RESET"
  printf '%s   already-open shells keep the old version until: source %s%s\n' \
    "$_WT_DIM" "${target/#$HOME/~}" "$_WT_RESET"
  printf '%s   what changed: https://github.com/mrx-arafat/wt-cli/commits/main%s\n' "$_WT_DIM" "$_WT_RESET"
}

_wt_usage() {
  cat <<EOF
${_WT_BOLD}${_WT_CYAN}wt${_WT_RESET} ${_WT_DIM}v${WT_VERSION} -${_WT_RESET} git worktree manager that lives in your shell

${_WT_BOLD}USAGE${_WT_RESET}
  wt                          interactive manager (plain table when piped)
  wt <command> [args]         target = ID, name, branch, substring, or .

${_WT_BOLD}COMMANDS${_WT_RESET}
  ${_WT_CYAN}ls${_WT_RESET} [-p] [-a]                -p plain table, -a list stale entries
  ${_WT_CYAN}add${_WT_RESET} <name> [base]           create worktree + branch, cd into it
  ${_WT_CYAN}go${_WT_RESET} [target]                 cd into a worktree (no arg: picker)
  ${_WT_CYAN}main${_WT_RESET}                        cd back to the main checkout
  ${_WT_CYAN}exec${_WT_RESET} <target> <cmd...>      run a command inside a worktree
  ${_WT_CYAN}open${_WT_RESET} <target>               open a worktree in your editor
  ${_WT_CYAN}pr${_WT_RESET} <number>                 worktree from a GitHub pull request
  ${_WT_CYAN}status${_WT_RESET}, st                  git status -sb for every worktree
  ${_WT_CYAN}rm${_WT_RESET} <sel...> [-k] [-y]       delete worktree(s) + branch (no arg: picker)
                              sel: 2 4 5 · 2,4,5 · 2-5 · target · all
                              -k keep branch · -y skip the prompt
  ${_WT_CYAN}clear${_WT_RESET}                       same as: wt rm all
  ${_WT_CYAN}clean${_WT_RESET}                       delete fully-merged worktrees (confirms)
  ${_WT_CYAN}prune${_WT_RESET}                       drop stale entries (directory deleted)
  ${_WT_CYAN}update${_WT_RESET} [--force]             self-update to the latest (= wt-cli --update)
  ${_WT_CYAN}help${_WT_RESET} | ${_WT_CYAN}version${_WT_RESET}              this help / version

${_WT_BOLD}INTERACTIVE${_WT_RESET} ${_WT_DIM}(wt, wt ls, wt go, wt rm on a terminal)${_WT_RESET}
  arrows/jk move  enter actions  space mark  a mark all  / filter  ? help
  g go  o open  s status  e exec  y copy  d delete  n new  m main
  p prune  r refresh  q quit

${_WT_BOLD}STATE${_WT_RESET}
  ${_WT_GREEN}✋😎🤚 clean${_WT_RESET}     no uncommitted changes to tracked files
  ${_WT_YELLOW}🍷 dirty${_WT_RESET}       uncommitted changes to tracked files
  ${_WT_DIM}🗿🤙🏻 missing${_WT_RESET}   directory is gone (stale entry) - clear with wt prune

${_WT_BOLD}SYNC${_WT_RESET} (vs upstream)   ${_WT_DIM}ok${_WT_RESET} in sync  ·  ${_WT_DIM}+2${_WT_RESET} ahead  ·  ${_WT_DIM}-3${_WT_RESET} behind  ·  ${_WT_DIM}gone${_WT_RESET} upstream deleted  ·  ${_WT_DIM}-${_WT_RESET} none

${_WT_BOLD}CONFIG${_WT_RESET} (git config, per-repo or --global)
  wt.copy      files/globs copied into new worktrees   ${_WT_DIM}".env .env.local"${_WT_RESET}
  wt.postadd   command run in each new worktree        ${_WT_DIM}"npm install"${_WT_RESET}
  wt.editor    editor for wt open and the o key        ${_WT_DIM}"code"${_WT_RESET}

${_WT_BOLD}NOTES${_WT_RESET}
  - rm asks first on a terminal and warns about uncommitted files / unpushed
    commits; scripts get no prompt. The default branch is never deleted.
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
    update|upgrade|--update|--upgrade|self-update) _wt_update "$@"; return ;;
  esac

  if ! git rev-parse --git-dir &>/dev/null; then
    printf '%s❌ wt: not inside a git repo%s\n' "$_WT_RED" "$_WT_RESET" >&2
    return 1
  fi

  case "$cmd" in
    list|ls|"")
      local plain=0 all=0 a
      for a in "$@"; do
        case "$a" in
          -p|--plain) plain=1 ;;
          -a|--all) all=1 ;;
          *) echo "usage: wt ls [-p|--plain] [-a|--all]" >&2; return 1 ;;
        esac
      done
      if [[ $plain -eq 0 && -t 0 && -t 1 ]]; then
        _wt_tui browse
      else
        _wt_print_table "$all"
      fi
      ;;

    add|new)
      local branch="${1:-}" base="${2:-}"
      if [[ -z "$branch" ]]; then echo "usage: wt add <branch> [base]" >&2; return 1; fi
      if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
        printf '%swt: %s is not a valid branch name%s\n' "$_WT_RED" "'$branch'" "$_WT_RESET" >&2
        return 1
      fi
      # Anchor on the MAIN checkout, not the current worktree - otherwise
      # running `wt add` from inside a worktree nests trees recursively.
      local root; root=$(_wt_main_root)
      [[ -z "$root" ]] && { echo "wt: cannot find main checkout" >&2; return 1; }
      local dest="$root/.worktrees/$branch"
      if [[ -e "$dest" ]]; then
        echo "wt: ${dest/#$HOME/~} already exists - wt go $branch" >&2
        return 1
      fi
      _wt_ensure_exclude
      mkdir -p "$(dirname "$dest")"
      # Always end up ON a branch named <branch>: a tag or commit that happens
      # to share the name must not produce a detached worktree.
      if git show-ref --verify --quiet "refs/heads/$branch"; then
        git worktree add "$dest" "$branch" || return 1
      elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        git worktree add --track -b "$branch" "$dest" "origin/$branch" || return 1
      elif git remote get-url origin &>/dev/null \
           && git ls-remote --exit-code --heads origin "$branch" &>/dev/null; then
        printf '%s⬇  fetching origin/%s%s\n' "$_WT_DIM" "$branch" "$_WT_RESET"
        git fetch -q origin "refs/heads/$branch:refs/remotes/origin/$branch" || return 1
        git worktree add --track -b "$branch" "$dest" "origin/$branch" || return 1
      else
        git worktree add -b "$branch" "$dest" ${base:+"$base"} || return 1
      fi

      # wt.copy: files/globs (relative to main root) copied into the worktree.
      # Typical use: .env files that are git-ignored but needed to run the app.
      local copyspec; copyspec=$(git config --get wt.copy 2>/dev/null || true)
      if [[ -n "$copyspec" ]]; then
        local f
        # tr-split instead of unquoted expansion: zsh doesn't word-split
        # unquoted vars, and zsh's ${=var} is a bash parse error.
        while IFS= read -r f; do
          [[ -z "$f" ]] && continue
          if [[ -e "$root/$f" ]]; then
            mkdir -p "$(dirname "$dest/$f")"
            cp -R "$root/$f" "$dest/$f" 2>/dev/null \
              && printf '%s📋 copied%s %s\n' "$_WT_DIM" "$_WT_RESET" "$f"
          fi
        done <<EOF
$(printf '%s\n' "$copyspec" | tr ' ' '\n')
EOF
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
      local key="${1:-}" id line wtpath branch name head flags
      if [[ -z "$key" ]]; then
        if [[ -t 0 && -t 1 ]]; then _wt_tui go; return; fi
        echo "usage: wt go <id|name|branch>" >&2; return 1
      fi
      id=$(_wt_resolve_id "$key") || return 1
      line=$(_wt_list_raw | awk -F'\t' -v i="$id" '$1 == i')
      IFS=$'\t' read -r id wtpath branch name head flags <<EOF
$line
EOF
      if [[ ! -d "$wtpath" ]]; then
        printf '%swt: %s is gone from disk%s - clean up with: wt prune\n' "$_WT_RED" "$name" "$_WT_RESET" >&2
        return 1
      fi
      [[ "$branch" == "(detached)" ]] && branch="@${head:0:7}"
      printf '%s🚀 ->%s %s%s%s %s(%s)%s %s\n' "$_WT_CYAN" "$_WT_RESET" "$_WT_BOLD" "$name" "$_WT_RESET" \
        "$_WT_DIM" "$branch" "$_WT_RESET" "${wtpath/#$HOME/~}"
      cd "$wtpath"
      ;;

    main|root)
      local mainroot; mainroot=$(_wt_main_root)
      [[ -z "$mainroot" ]] && { echo "wt: cannot find main checkout" >&2; return 1; }
      printf '%s🚀 ->%s %s %s(main)%s\n' "$_WT_CYAN" "$_WT_RESET" "${mainroot/#$HOME/~}" "$_WT_DIM" "$_WT_RESET"
      cd "$mainroot"
      ;;

    exec|x)
      local key="${1:-}"; [[ $# -gt 0 ]] && shift
      [[ "${1:-}" == "--" ]] && shift
      if [[ -z "$key" || $# -eq 0 ]]; then echo "usage: wt exec <id|name> <cmd...>" >&2; return 1; fi
      local wtpath; wtpath=$(_wt_resolve "$key") || return 1
      printf '%s⚙  %s%s in %s\n' "$_WT_DIM" "$*" "$_WT_RESET" "${wtpath/#$HOME/~}"
      ( cd "$wtpath" && "$@" )
      ;;

    open)
      local key="${1:-.}"
      local wtpath; wtpath=$(_wt_resolve "$key") || return 1
      local editor; editor=$(git config --get wt.editor 2>/dev/null || true)
      [[ -z "$editor" ]] && editor="${VISUAL:-${EDITOR:-}}"
      if [[ -z "$editor" ]]; then
        echo "wt: no editor - set one: git config wt.editor \"code\" (or \$EDITOR)" >&2
        return 1
      fi
      printf '%s🚀 %s%s %s\n' "$_WT_CYAN" "$editor" "$_WT_RESET" "${wtpath/#$HOME/~}"
      ( cd "$wtpath" && eval "$editor \"\$wtpath\"" )
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
      local data; data=$(_wt_collect)
      [[ -z "$data" ]] && { _wt_no_worktrees; return 0; }
      local id name branch head state changes syncs age dpath flags wtpath color
      while IFS=$'\t' read -r id name branch head state changes syncs age dpath flags wtpath; do
        [[ "$branch" == "(detached)" ]] && branch="@$head"
        case "$state" in
          clean) color=$_WT_GREEN ;; dirty) color=$_WT_YELLOW ;; *) color=$_WT_DIM ;;
        esac
        printf '\n%s#%s%s  %s%s %s%s  %s%s%s  %s[%s]  (%s)%s\n' \
          "$_WT_BOLD" "$id" "$_WT_RESET" "$color" "$(_wt_state_emoji "$state")" "$state" "$_WT_RESET" \
          "$_WT_BOLD" "$name" "$_WT_RESET" "$_WT_DIM" "$syncs" "$branch" "$_WT_RESET"
        if [[ "$state" == missing ]]; then
          printf '%s   directory is gone - wt prune%s\n' "$_WT_DIM" "$_WT_RESET"
        else
          git -C "$wtpath" -c color.status=always status -sb 2>/dev/null
        fi
      done <<EOF
$data
EOF
      echo
      ;;

    clean)
      local yes=0; [[ "${1:-}" == -y || "${1:-}" == --yes ]] && yes=1
      local db; db=$(_wt_default_branch)
      [[ -z "$db" ]] && { echo "wt: cannot determine default branch" >&2; return 1; }
      local rows; rows=$(_wt_list_raw)
      [[ -z "$rows" ]] && { echo "wt: nothing to clean"; return 0; }
      local merged="" id wtpath branch name head flags
      while IFS=$'\t' read -r id wtpath branch name head flags; do
        [[ "$branch" == "(detached)" || "$branch" == "(bare)" || "$branch" == "$db" ]] && continue
        [[ -d "$wtpath" && -n $(git -C "$wtpath" --no-optional-locks status --porcelain 2>/dev/null) ]] \
          && continue  # never clean uncommitted (or untracked) work
        if git merge-base --is-ancestor "refs/heads/$branch" "$db" 2>/dev/null \
           || { git show-ref --verify --quiet "refs/remotes/origin/$db" \
                && git merge-base --is-ancestor "refs/heads/$branch" "origin/$db" 2>/dev/null; }; then
          merged="$merged$id "
        fi
      done <<EOF
$rows
EOF
      if [[ -z "$merged" ]]; then
        printf '%s✅ nothing merged into %s - all worktrees still in play%s\n' "$_WT_GREEN" "$db" "$_WT_RESET"
        return 0
      fi
      printf '\n%s🧹 merged into %s%s%s - safe to remove%s\n' "$_WT_DIM" "$_WT_CYAN" "$db" "$_WT_DIM" "$_WT_RESET"
      if [[ $yes -eq 0 && ! -t 0 ]]; then
        echo; echo "wt: not a terminal - re-run with: wt clean -y" >&2; return 1
      fi
      _wt_rm_ids "${merged% }" 0 "$yes"
      ;;

    rm|remove|delete|del|clear)
      local keep=0 yes=0 sel="" a ids
      [[ "$cmd" == clear ]] && sel="all"
      for a in "$@"; do
        case "$a" in
          -k|--keep-branch) keep=1 ;;
          -y|--yes|-f|--force) yes=1 ;;
          -a|--all) sel="$sel all" ;;
          -*) echo "wt: unknown flag $a - usage: wt rm <ids|name|all> [-k] [-y]" >&2; return 1 ;;
          *) sel="$sel $a" ;;
        esac
      done
      if [[ -z "${sel// /}" ]]; then
        if [[ -t 0 && -t 1 ]]; then _wt_tui rm; return; fi
        echo "usage: wt rm <id|name|range|all> [...] [-k|--keep-branch] [-y|--yes]" >&2
        return 1
      fi
      [[ -z "$(_wt_list_raw)" ]] && { _wt_no_worktrees; return 0; }
      ids=$(_wt_select_ids "$sel") || return 1
      _wt_rm_ids "$ids" "$keep" "$yes"
      ;;

    prune)
      local before after
      before=$(git worktree list --porcelain 2>/dev/null | grep -c '^worktree ')
      git worktree prune
      after=$(git worktree list --porcelain 2>/dev/null | grep -c '^worktree ')
      printf '%s🧹 pruned %d stale entr%s%s\n' "$_WT_GREEN" "$((before - after))" \
        "$([[ $((before - after)) -eq 1 ]] && echo y || echo ies)" "$_WT_RESET"
      ;;

    *)
      printf '%swt: unknown subcommand '"'"'%s'"'"'%s\n' "$_WT_RED" "$cmd" "$_WT_RESET" >&2
      _wt_usage
      return 1
      ;;
  esac
}

# `wt-cli` is the project name people remember: `wt-cli --update`,
# `wt-cli --version` and friends all just forward to wt.
wt-cli() { wt "$@"; }

# ---- tab completion ---------------------------------------------------------
# Completes subcommands, then worktree names + branches for go/exec/open/rm.

_wt_names() {
  _wt_list_raw | awk -F'\t' '{ print $4; if ($3 !~ /^\(/ && $3 != $4) print $3 }'
}

if [[ -n "${ZSH_VERSION:-}" ]]; then
  _wt_complete_zsh() {
    local -a subcmds names
    subcmds=(list ls add go main exec open pr status clean rm clear prune update help version)
    if (( CURRENT == 2 )); then
      compadd -a subcmds
    else
      case "${words[2]}" in
        go|cd|exec|x|open|rm|remove|delete|del)
          names=(${(f)"$(_wt_names 2>/dev/null)"})
          compadd -a names ;;
      esac
    fi
  }
  compdef _wt_complete_zsh wt 2>/dev/null || true
elif [[ -n "${BASH_VERSION:-}" ]]; then
  _wt_complete_bash() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    if [[ $COMP_CWORD -eq 1 ]]; then
      COMPREPLY=($(compgen -W "list ls add go main exec open pr status clean rm clear prune update help version" -- "$cur"))
    else
      case "${COMP_WORDS[1]}" in
        go|cd|exec|x|open|rm|remove|delete|del)
          COMPREPLY=($(compgen -W "$(_wt_names 2>/dev/null | tr '\n' ' ')" -- "$cur")) ;;
      esac
    fi
  }
  complete -F _wt_complete_bash wt 2>/dev/null || true
fi
