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

check_prereqs() {
  local missing=()
  for bin in git awk curl; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  [ ${#missing[@]} -eq 0 ] && return 0

  echo "wt-cli: missing required tool(s): ${missing[*]}"
  echo ""
  case "$(uname -s)" in
    Darwin)
      echo "Install the Xcode Command Line Tools (provides git, curl, awk):"
      echo "  xcode-select --install"
      if command -v brew >/dev/null 2>&1; then
        echo "Or, with Homebrew:"
        echo "  brew install ${missing[*]}"
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        echo "  sudo apt-get update && sudo apt-get install -y ${missing[*]}"
      elif command -v dnf >/dev/null 2>&1; then
        echo "  sudo dnf install -y ${missing[*]}"
      elif command -v yum >/dev/null 2>&1; then
        echo "  sudo yum install -y ${missing[*]}"
      elif command -v pacman >/dev/null 2>&1; then
        echo "  sudo pacman -S --noconfirm ${missing[*]}"
      elif command -v apk >/dev/null 2>&1; then
        echo "  sudo apk add ${missing[*]}"
      elif command -v zypper >/dev/null 2>&1; then
        echo "  sudo zypper install -y ${missing[*]}"
      else
        echo "  install ${missing[*]} using your distro's package manager"
      fi
      ;;
    *)
      echo "  install ${missing[*]} using your platform's package manager"
      ;;
  esac
  echo ""
  echo "Then re-run this installer."
  return 1
}

check_prereqs || exit 1

mkdir -p "$INSTALL_DIR"

SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/wt.sh" ]; then
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
