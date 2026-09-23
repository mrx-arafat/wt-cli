#!/usr/bin/env bash
# wt-cli test suite - every case runs under bash AND zsh.
#
#   tests/wt_test.sh                        run everything
#   WT_TEST_SHELLS=zsh tests/wt_test.sh     one shell only
#   VERBOSE=1 tests/wt_test.sh              dump wt output under each failure
#
# Every case builds throwaway repos under one temp dir; nothing outside it is
# touched. wt runs with stdin/stdout redirected (not a TTY), so it never
# prompts or opens the interactive UI - except the tmux-driven TUI smoke test.

set -u

WT_SH="${WT_SH:-$(cd "$(dirname "$0")/.." && pwd -P)/wt.sh}"
SHELLS="${WT_TEST_SHELLS:-bash zsh}"
TMP=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wt-test.XXXXXX")" && pwd -P)
SOCK="wt-test-$$"
PASS=0 FAIL=0 SKIP=0 NOTES=""
OUT="" RC=0

tm() { tmux -L "$SOCK" -f /dev/null "$@"; }
cleanup() {
  command -v tmux >/dev/null 2>&1 && tm kill-server >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# Isolated git config: a user's global wt.postadd / wt.copy must not leak in.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig" NO_COLOR=1
export BASH_SILENCE_DEPRECATION_WARNING=1
unset BASH_ENV ENV
cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = wt test
	email = wt@test.invalid
[init]
	defaultBranch = main
[advice]
	detachedHead = false
EOF

# ---- assertions --------------------------------------------------------------

pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$1"
  [ -n "${VERBOSE:-}" ] && printf '%s\n' "$OUT" | head -40 | sed 's/^/      | /'
  return 0
}
assert_true() { local d="$1"; shift; if "$@"; then pass; else fail "$d"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then pass; else fail "$1 (expected '$3', got '$2')"; fi; }
assert_contains() { if printf '%s\n' "$2" | grep -qF -- "$3"; then pass; else fail "$1 (missing '$3')"; fi; }
assert_not_contains() { if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1 (unexpected '$3')"; else pass; fi; }

# has_token <text> <word>: some whitespace-separated field equals <word> exactly
# (so a name that only appears inside a PATH does not count).
has_token() { printf '%s\n' "$1" | awk -v t="$2" '{ for (i = 1; i <= NF; i++) if ($i == t) f = 1 } END { exit !f }'; }
last_line() { printf '%s\n' "$OUT" | awk 'NF { l = $0 } END { print l }'; }

# name_of <table> <id> <regex>: first token on row <id> ("3*" = 3) matching <regex>.
name_of() {
  printf '%s\n' "$1" | awk -v id="$2" -v re="$3" '
    { k = $1; sub(/\*$/, "", k) }
    k == id { for (i = 2; i <= NF; i++) if ($i ~ re) { print $i; exit } }'
}

# ---- fixtures ----------------------------------------------------------------

# wtrun <shell> <dir> <script>: fresh shell, source wt.sh, cd <dir>, run <script>.
# Sets OUT (stdout+stderr) and RC. stdin is /dev/null: never a TTY.
wtrun() {
  local pre=". '$WT_SH' || exit 98; cd '$2' || exit 99;"
  case "$1" in
    zsh) OUT=$(zsh -f -c "$pre $3" </dev/null 2>&1) ;;
    *) OUT=$(bash --norc --noprofile -c "$pre $3" </dev/null 2>&1) ;;
  esac
  RC=$?
}

# mkrepo <dir>: repo on main with one commit; .worktrees/ ignored like wt does.
mkrepo() {
  mkdir -p "$1" && git -C "$1" init -q && echo a >"$1/f" &&
    git -C "$1" add f && git -C "$1" commit -qm init &&
    echo '.worktrees/' >>"$1/.git/info/exclude"
}
# addwt <repo> <name> [branch]: linked worktree at <repo>/.worktrees/<name>, new branch
addwt() { git -C "$1" worktree add -q "$1/.worktrees/$2" -b "${3:-$2}" 2>/dev/null; }
# stalewt <repo> <name>: worktree whose directory was deleted behind git's back
stalewt() { addwt "$1" "$2" && rm -rf "$1/.worktrees/$2"; }

# ---- cases -------------------------------------------------------------------

case_ls_names() {
  local sh="$1" R="$TMP/ls-$1/r" sha tbl
  mkrepo "$R"
  addwt "$R" renamed original-name && git -C "$R/.worktrees/renamed" checkout -q -b something-else
  git -C "$R" worktree add -q --detach "$R/.worktrees/agent-7" HEAD
  git -C "$R" worktree add -q "$TMP/ls-$sh/ext-tree" -b ext
  sha=$(git -C "$R" rev-parse HEAD | cut -c1-7)
  wtrun "$sh" "$R" 'wt ls -p'
  tbl="$OUT"
  assert_true "ls[$sh] -p prints a NAME column" has_token "$tbl" NAME
  assert_true "ls[$sh] branch-switched tree shows name 'renamed'" has_token "$tbl" renamed
  assert_true "ls[$sh] ...and its branch 'something-else'" has_token "$tbl" something-else
  assert_true "ls[$sh] detached tree shows name 'agent-7'" has_token "$tbl" agent-7
  assert_true "ls[$sh] detached tree shows branch '@$sha'" has_token "$tbl" "@$sha"
  assert_true "ls[$sh] external tree shows name 'ext-tree'" has_token "$tbl" ext-tree
  wtrun "$sh" "$R" 'wt ls'
  assert_true "ls[$sh] non-TTY 'wt ls' prints the static table" has_token "$OUT" agent-7
}

case_stale_ids() {
  local sh="$1" R="$TMP/stale-$1/r" n all
  mkrepo "$R"
  for n in a-stale1 a-stale2 a-stale3 a-stale4; do stalewt "$R" "$n"; done
  addwt "$R" z-live1
  addwt "$R" z-live2
  wtrun "$sh" "$R" 'wt ls -p -a'
  all="$OUT"
  assert_true "stale[$sh] live trees numbered first (IDs 1-2)" \
    eval '[ -n "$(name_of "$all" 1 "^z-live")" ] && [ -n "$(name_of "$all" 2 "^z-live")" ]'
  assert_true "stale[$sh] -a lists stale trees individually, last (ID 6)" \
    eval '[ -n "$(name_of "$all" 6 "^a-stale")" ]'
  wtrun "$sh" "$R" 'wt ls -p'
  assert_true "stale[$sh] >3 stale collapse to one 'stale ... wt prune' line" \
    eval 'printf "%s\n" "$OUT" | grep "stale" | grep -q "wt prune"'
  assert_not_contains "stale[$sh] collapsed stale rows are not listed" "$OUT" "a-stale1"
}

case_resolve() {
  local sh="$1" R="$TMP/res-$1/r"
  mkrepo "$R"
  addwt "$R" renamed original-name && git -C "$R/.worktrees/renamed" checkout -q -b something-else
  git -C "$R" worktree add -q --detach "$R/.worktrees/agent-7" HEAD
  addwt "$R" feat-a
  addwt "$R" feat-b
  wtrun "$sh" "$R" 'wt go renamed >/dev/null 2>&1; pwd -P'
  assert_eq "resolve[$sh] 'wt go <name>' cds into it" "$(last_line)" "$R/.worktrees/renamed"
  wtrun "$sh" "$R" 'wt go something-else >/dev/null 2>&1; pwd -P'
  assert_eq "resolve[$sh] 'wt go <branch>' cds into it" "$(last_line)" "$R/.worktrees/renamed"
  wtrun "$sh" "$R" 'wt go AGENT >/dev/null 2>&1; pwd -P'
  assert_eq "resolve[$sh] unique case-insensitive substring" "$(last_line)" "$R/.worktrees/agent-7"
  wtrun "$sh" "$R" 'wt go feat; echo "rc=$?"; pwd -P'
  assert_true "resolve[$sh] ambiguous substring errors, lists matches, stays put" \
    eval 'printf "%s\n" "$OUT" | grep -q "rc=[1-9]" && has_token "$OUT" feat-a && has_token "$OUT" feat-b && [ "$(last_line)" = "$R" ]'
  wtrun "$sh" "$R" 'wt exec renamed pwd -P'
  assert_contains "resolve[$sh] 'wt exec <name>' runs inside it" "$OUT" "$R/.worktrees/renamed"
}

# rm_variant <shell> <label> <wt command> <removed: ids:N..|names:..|all|none> <keep 0|1> <expect error 0|1>
# Fresh repo with worktrees w1..w4 on branches b1..b4; checks exactly the
# expected trees (and branches, unless keep) are gone and nothing else is.
rm_variant() {
  local sh="$1" label="$2" cmd="$3" spec="$4" keep="$5" experr="$6"
  local R n b id removed=" " why="" gone bgone listed want wantb rc
  R="$TMP/rm-$sh-$(printf '%s' "$label" | tr -c 'a-zA-Z0-9' '_')/r"
  mkrepo "$R"
  for n in w1 w2 w3 w4; do addwt "$R" "$n" "b${n#w}"; done
  wtrun "$sh" "$R" 'wt ls -p'
  case "$spec" in
    all) removed=" w1 w2 w3 w4 " ;;
    none) removed=" " ;;
    names:*) removed=" ${spec#names:} " ;;
    ids:*)
      for id in ${spec#ids:}; do
        n=$(name_of "$OUT" "$id" '^w[0-9]$')
        [ -z "$n" ] && { fail "rm[$sh] $label: cannot map ID $id to a NAME (no NAME column?)"; return; }
        removed="$removed$n "
      done ;;
  esac
  wtrun "$sh" "$R" "$cmd"
  rc=$RC
  for n in w1 w2 w3 w4; do
    b="b${n#w}"
    case "$removed" in *" $n "*) want=1 ;; *) want=0 ;; esac
    wantb=$want; [ "$keep" = 1 ] && wantb=0
    gone=0; [ -d "$R/.worktrees/$n" ] || gone=1
    listed=0; git -C "$R" worktree list --porcelain | grep -q "/.worktrees/$n\$" && listed=1
    bgone=0; git -C "$R" show-ref --verify --quiet "refs/heads/$b" || bgone=1
    [ "$gone" = "$want" ] || why="$why $n:dir-$([ "$gone" = 1 ] && echo gone || echo kept)"
    [ "$want" = 1 ] && [ "$listed" = 1 ] && why="$why $n:still-in-git-list"
    [ "$bgone" = "$wantb" ] || why="$why $b:branch-$([ "$bgone" = 1 ] && echo gone || echo kept)"
  done
  if [ "$experr" = 1 ]; then [ "$rc" -ne 0 ] || why="$why exit=0"; else [ "$rc" -eq 0 ] || why="$why exit=$rc"; fi
  if [ -z "$why" ]; then pass; else fail "rm[$sh] $label:$why"; fi
}

case_rm() {
  local sh="$1"
  rm_variant "$sh" "ids '2 4'" 'wt rm 2 4' 'ids:2 4' 0 0
  rm_variant "$sh" "commas '1,3'" 'wt rm 1,3' 'ids:1 3' 0 0
  rm_variant "$sh" "range '2-3'" 'wt rm 2-3' 'ids:2 3' 0 0
  rm_variant "$sh" "by name" 'wt rm w2' 'names:w2' 0 0
  rm_variant "$sh" "all" 'wt rm all' all 0 0
  rm_variant "$sh" "--all" 'wt rm --all' all 0 0
  rm_variant "$sh" "-a" 'wt rm -a' all 0 0
  rm_variant "$sh" "wt clear" 'wt clear' all 0 0
  rm_variant "$sh" "-k keeps branch" 'wt rm 1 -k' 'ids:1' 1 0
  rm_variant "$sh" "--keep-branch" 'wt rm --keep-branch 2' 'ids:2' 1 0
  rm_variant "$sh" "invalid id deletes nothing" 'wt rm 1 99' none 0 1
}

case_safety() {
  local sh="$1" R
  R="$TMP/safe-in-$sh/r"
  mkrepo "$R"; addwt "$R" w1; addwt "$R" w2
  wtrun "$sh" "$R" 'cd .worktrees/w1 && wt rm w1 >/dev/null 2>&1; pwd -P'
  assert_true "safety[$sh] rm from inside the target lands in the main checkout" \
    eval '[ "$(last_line)" = "$R" ] && [ ! -d "$R/.worktrees/w1" ]'

  R="$TMP/safe-default-$sh/r"
  mkrepo "$R"; git -C "$R" checkout -q -b dev
  git -C "$R" worktree add -q "$R/.worktrees/mainwt" main
  wtrun "$sh" "$R" 'wt rm mainwt'
  assert_true "safety[$sh] tree on default branch removed, branch 'main' kept" \
    eval '[ ! -d "$R/.worktrees/mainwt" ] && git -C "$R" show-ref --verify --quiet refs/heads/main'

  R="$TMP/safe-lock-$sh/r"
  mkrepo "$R"; addwt "$R" w1
  git -C "$R" worktree lock "$R/.worktrees/w1"
  wtrun "$sh" "$R" 'wt rm w1'
  assert_true "safety[$sh] locked tree skipped with a message" \
    eval 'printf "%s\n" "$OUT" | grep -qi lock && [ -d "$R/.worktrees/w1" ]'
}

case_prune() {
  local sh="$1" R="$TMP/prune-$1/r"
  mkrepo "$R"; addwt "$R" w1; stalewt "$R" s1; stalewt "$R" s2
  wtrun "$sh" "$R" 'wt prune'
  # strip paths first: temp dir names contain random digits
  assert_true "prune[$sh] reports 2 pruned" \
    eval 'printf "%s\n" "$OUT" | sed "s#[^ ]*/[^ ]*##g" | grep -Eq "(^|[^0-9])2([^0-9]|$)"'
  assert_true "prune[$sh] stale entries gone, live tree kept" \
    eval '! git -C "$R" worktree list --porcelain | grep -q prunable && git -C "$R" worktree list --porcelain | grep -q "/.worktrees/w1$"'
}

case_add() {
  local sh="$1" R="$TMP/add-$1/r"
  mkrepo "$R"; git -C "$R" tag v1
  wtrun "$sh" "$R" 'wt add v1 >/dev/null 2>&1; git symbolic-ref -q HEAD'
  assert_eq "add[$sh] 'wt add v1' with tag v1 creates branch v1 (not detached)" "$(last_line)" "refs/heads/v1"
  wtrun "$sh" "$R" "wt add 'bad..name'; echo \"rc=\$?\""
  assert_true "add[$sh] invalid branch name fails and creates nothing" \
    eval 'printf "%s\n" "$OUT" | grep -q "rc=[1-9]" && [ ! -e "$R/.worktrees/bad..name" ] && ! git -C "$R" show-ref --quiet --verify "refs/heads/bad..name"'
}

# Self-update: an old install is replaced from WT_UPDATE_URL and reloaded in
# the running shell; same version = no-op; a bad download is refused.
case_update() {
  local sh="$1" D="$TMP/upd-$1" cur
  cur=$(sed -n 's/^WT_VERSION="\(.*\)"/\1/p' "$WT_SH")
  mkdir -p "$D/inst"
  sed 's/^WT_VERSION=.*/WT_VERSION="0.0.1"/' "$WT_SH" >"$D/inst/wt.sh"
  cp "$WT_SH" "$D/pub.sh"
  echo 'echo not wt' >"$D/bad.sh"
  WT_SH="$D/inst/wt.sh" wtrun "$sh" "$D" "WT_UPDATE_URL='file://$D/pub.sh' wt update; echo \"rc=\$? v=\$WT_VERSION\""
  assert_true "update[$sh] old install is replaced and reloaded in this shell" \
    eval 'cmp -s "$D/inst/wt.sh" "$D/pub.sh" && printf "%s\n" "$OUT" | grep -q "rc=0 v=$cur"'
  WT_SH="$D/inst/wt.sh" wtrun "$sh" "$D" "WT_UPDATE_URL='file://$D/pub.sh' wt-cli --update; echo \"rc=\$?\""
  assert_true "update[$sh] wt-cli --update on the latest says up to date" \
    eval 'printf "%s\n" "$OUT" | grep -qi "up to date" && printf "%s\n" "$OUT" | grep -q "rc=0"'
  sed 's/^WT_VERSION=.*/WT_VERSION="0.0.1"/' "$WT_SH" >"$D/inst/wt.sh"
  cp "$D/inst/wt.sh" "$D/before.sh"
  WT_SH="$D/inst/wt.sh" wtrun "$sh" "$D" "WT_UPDATE_URL='file://$D/bad.sh' wt update; echo \"rc=\$?\""
  assert_true "update[$sh] a download that is not wt.sh is refused, install untouched" \
    eval 'cmp -s "$D/inst/wt.sh" "$D/before.sh" && printf "%s\n" "$OUT" | grep -q "rc=[1-9]"'
}

case_perf() {
  local sh="$1" R="$TMP/perf-$1/r" i=1 secs TIMEFORMAT='%3R'
  mkrepo "$R"
  while [ $i -le 20 ]; do addwt "$R" "p$i"; i=$((i + 1)); done
  { time wtrun "$sh" "$R" 'wt ls -p'; } 2>"$TMP/perf-time"
  secs=$(tail -1 "$TMP/perf-time")
  NOTES="$NOTES
perf[$sh]: wt ls -p over 20 worktrees took ${secs}s"
  assert_true "perf[$sh] wt ls -p lists all 20 worktrees" \
    eval '[ "$RC" -eq 0 ] && has_token "$OUT" p1 && has_token "$OUT" p20'
}

# ---- TUI smoke (tmux) ----------------------------------------------------------

pane() { tm capture-pane -p -J -t wt 2>/dev/null; }
# wait_for <fixed text> [secs]: poll the pane until the text shows up
wait_for() {
  local i=0 lim=$((${2:-6} * 20))
  while [ $i -lt $lim ]; do
    pane | grep -qF -- "$1" && return 0
    sleep 0.05; i=$((i + 1))
  done
  return 1
}
# wait_prompt [secs]: the shell is idle again (last non-empty line is the prompt)
wait_prompt() {
  local i=0 lim=$((${1:-6} * 20))
  while [ $i -lt $lim ]; do
    [ "$(pane | awk 'NF { l = $0 } END { sub(/[ \t]+$/, "", l); print l }')" = "WTP>" ] && return 0
    sleep 0.05; i=$((i + 1))
  done
  return 1
}
tui_bail() { fail "tui[$1]: $2"; tm kill-server >/dev/null 2>&1; }

case_tui() {
  local sh="$1" R="$TMP/tui-$1/r" n2 shcmd
  if ! command -v tmux >/dev/null 2>&1; then
    SKIP=$((SKIP + 1)); NOTES="$NOTES
tui[$sh]: skipped (tmux not installed)"; return
  fi
  mkrepo "$R"; addwt "$R" w1; addwt "$R" w2; addwt "$R" w3
  wtrun "$sh" "$R" 'wt ls -p'
  n2=$(name_of "$OUT" 2 '^w[0-9]$')
  [ -z "$n2" ] && { fail "tui[$sh]: cannot map ID 2 to a NAME (no NAME column?)"; return; }
  case "$sh" in zsh) shcmd="zsh -f" ;; *) shcmd="bash --norc --noprofile" ;; esac
  tm kill-server >/dev/null 2>&1
  tm new-session -d -s wt -x 100 -y 30 \
    "env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL='$GIT_CONFIG_GLOBAL' BASH_SILENCE_DEPRECATION_WARNING=1 TERM=xterm-256color $shcmd" ||
    { fail "tui[$sh]: tmux could not start"; return; }
  tm send-keys -t wt "PS1='WTP> '; . '$WT_SH'; cd '$R'; clear" Enter
  wait_prompt 5 || { tui_bail "$sh" "shell never became ready"; return; }

  # navigate: Down -> Enter (action menu) -> g (go) cds the real shell
  tm send-keys -t wt 'wt ls' Enter
  wait_for NAME 5 || { tui_bail "$sh" "'wt ls' never showed the NAME header"; return; }
  assert_true "tui[$sh] 'wt ls' shows rows" eval 'pane | grep -q w3'
  tm send-keys -t wt Down
  tm send-keys -t wt Enter
  tm send-keys -t wt g
  wait_prompt 5 || { tui_bail "$sh" "Down/Enter/g did not return to the prompt"; return; }
  tm send-keys -t wt 'echo "PWD=$(pwd -P)"' Enter
  assert_true "tui[$sh] Down, Enter, g cds into row 2 ($n2)" wait_for "PWD=$R/.worktrees/$n2" 3

  # q leaves the static table on screen
  tm send-keys -t wt 'clear' Enter
  wait_prompt 3
  tm send-keys -t wt 'wt ls' Enter
  wait_for NAME 5 || { tui_bail "$sh" "second 'wt ls' never rendered"; return; }
  tm send-keys -t wt q
  wait_prompt 5 || { tui_bail "$sh" "q did not quit"; return; }
  assert_true "tui[$sh] q leaves the table visible" eval 'pane | grep -q NAME && pane | grep -q w3'

  # Ctrl-C restores the terminal (echo/icanon/isig back on)
  tm send-keys -t wt 'clear' Enter
  wait_prompt 3
  tm send-keys -t wt 'wt ls' Enter
  wait_for NAME 5 || { tui_bail "$sh" "third 'wt ls' never rendered"; return; }
  tm send-keys -t wt C-c
  wait_prompt 5 || { tui_bail "$sh" "Ctrl-C did not quit"; return; }
  tm send-keys -t wt 'for f in echo icanon isig; do stty -a | tr " " "\n" | grep -qx -- "-$f" && printf "B%sD-%s " A $f; done; echo TTYCHK' Enter
  wait_for TTYCHK 3
  assert_true "tui[$sh] Ctrl-C restores the terminal" eval '! pane | grep -q "BAD-" && pane | grep -qx "TTYCHK"'
  tm kill-server >/dev/null 2>&1
}

# ---- run -----------------------------------------------------------------------

[ -f "$WT_SH" ] || { echo "wt.sh not found at $WT_SH" >&2; exit 2; }
for sh in $SHELLS; do
  command -v "$sh" >/dev/null 2>&1 || { NOTES="$NOTES
$sh: not installed, skipped"; continue; }
  case_ls_names "$sh"
  case_stale_ids "$sh"
  case_resolve "$sh"
  case_rm "$sh"
  case_safety "$sh"
  case_prune "$sh"
  case_add "$sh"
  case_update "$sh"
  case_perf "$sh"
  case_tui "$sh"
done

printf '%s\n' "$NOTES" | sed '/^$/d'
printf '\n%d passed, %d failed, %d skipped  (wt %s; %s)\n' "$PASS" "$FAIL" "$SKIP" \
  "$(sed -n 's/^WT_VERSION="\(.*\)"/\1/p' "$WT_SH")" "$SHELLS"
[ "$FAIL" -eq 0 ]
