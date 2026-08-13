#!/usr/bin/env bash
# wt-cli installer
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/mrx-arafat/wt-cli/main/install.sh | bash
#
# Or clone + run locally:
#   git clone https://github.com/mrx-arafat/wt-cli.git && cd wt-cli && ./install.sh
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/mrx-arafat/wt-cli/main"
INSTALL_DIR="$HOME/.wt-cli"
SCRIPT_PATH="$INSTALL_DIR/wt.sh"
SOURCE_LINE="[ -f \"$SCRIPT_PATH\" ] && source \"$SCRIPT_PATH\""
MARKER="# wt-cli: git worktree manager (https://github.com/mrx-arafat/wt-cli)"

mkdir -p "$INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/wt.sh" ]; then
  cp "$SCRIPT_DIR/wt.sh" "$SCRIPT_PATH"
else
  curl -fsSL "$REPO_RAW/wt.sh" -o "$SCRIPT_PATH"
fi
chmod 644 "$SCRIPT_PATH"

add_to_rc() {
  local rc="$1"
  [ -f "$rc" ] || touch "$rc"
  if ! grep -qF "$MARKER" "$rc" 2>/dev/null; then
    {
      echo ""
      echo "$MARKER"
      echo "$SOURCE_LINE"
    } >> "$rc"
    echo "  + added to $rc"
  else
    echo "  = already present in $rc"
  fi
}

echo "Installing wt-cli to $SCRIPT_PATH"

found_rc=0
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
  if [ -f "$rc" ]; then
    add_to_rc "$rc"
    found_rc=1
  fi
done

if [ "$found_rc" -eq 0 ]; then
  case "${SHELL:-}" in
    */zsh)  add_to_rc "$HOME/.zshrc" ;;
    *)      add_to_rc "$HOME/.bashrc" ;;
  esac
fi

echo ""
echo "Done. Restart your shell, or run:"
echo "  source $SCRIPT_PATH"
echo ""
echo "Then try:  wt list   (run inside any git repo)"
echo "Help:      wt help"
