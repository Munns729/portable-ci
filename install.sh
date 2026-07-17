#!/usr/bin/env bash
# portable-ci installer — clone the repo and link `ci` onto your PATH.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/Munns729/portable-ci/main/install.sh | bash
#
# Knobs (env vars):
#   PORTABLE_CI_DIR   where to clone       (default: ~/.portable-ci)
#   PORTABLE_CI_BIN   where to link `ci`   (default: first writable of
#                     ~/.local/bin, /usr/local/bin)
#   PORTABLE_CI_REF   branch/tag/SHA       (default: main)
set -euo pipefail

REPO_URL="${PORTABLE_CI_REPO_URL:-https://github.com/Munns729/portable-ci}"
DIR="${PORTABLE_CI_DIR:-$HOME/.portable-ci}"
REF="${PORTABLE_CI_REF:-main}"

say()  { printf 'portable-ci install: %s\n' "$1"; }
die()  { printf 'portable-ci install: %s\n' "$1" >&2; exit 1; }

command -v git  >/dev/null 2>&1 || die "git is required but not found."
command -v bash >/dev/null 2>&1 || die "bash is required but not found."

# --- fetch or update the checkout ---
if [ -d "$DIR/.git" ]; then
  say "updating existing checkout at $DIR"
  git -C "$DIR" fetch --quiet origin "$REF"
  git -C "$DIR" checkout --quiet "$REF"
  git -C "$DIR" pull --quiet --ff-only origin "$REF" || true
else
  say "cloning $REPO_URL into $DIR"
  git clone --quiet "$REPO_URL" "$DIR"
  git -C "$DIR" checkout --quiet "$REF"
fi
chmod +x "$DIR/bin/ci"

# --- pick a bin dir on PATH we can write to ---
pick_bin() {
  if [ -n "${PORTABLE_CI_BIN:-}" ]; then printf '%s\n' "$PORTABLE_CI_BIN"; return; fi
  local d
  for d in "$HOME/.local/bin" /usr/local/bin; do
    if [ -d "$d" ] && [ -w "$d" ]; then printf '%s\n' "$d"; return; fi
  done
  # default target; created below if missing
  printf '%s\n' "$HOME/.local/bin"
}
BIN="$(pick_bin)"
mkdir -p "$BIN" 2>/dev/null || die "cannot create $BIN — set PORTABLE_CI_BIN to a writable dir on your PATH."
[ -w "$BIN" ] || die "$BIN is not writable — set PORTABLE_CI_BIN, or re-run with sudo."

ln -sf "$DIR/bin/ci" "$BIN/ci"
say "linked ci -> $BIN/ci"

# --- verify it's reachable ---
if command -v ci >/dev/null 2>&1 && [ "$(command -v ci)" = "$BIN/ci" ]; then
  say "done. Next: cd into your project, then run 'ci init' and 'ci run'."
else
  say "done, but $BIN is not on your PATH yet."
  say "add it with:  export PATH=\"$BIN:\$PATH\"   (put this in your shell rc file)"
  say "then run 'ci init' in your project."
fi
