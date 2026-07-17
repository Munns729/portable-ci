#!/usr/bin/env bash
# portable-ci installer — clone the repo and link `ci` onto your PATH.
#
# Prefer to read before you run (recommended):
#   curl -fsSL https://raw.githubusercontent.com/Munns729/portable-ci/v1/install.sh -o install.sh
#   less install.sh          # it's ~70 lines; this is the whole installer
#   bash install.sh
#
# Or, if you'd rather not install at all, just grab the one script the product
# *is* (nothing else to audit) — see the README "one file, no clone" section.
#
# One-liner (unattended):
#   curl -fsSL https://raw.githubusercontent.com/Munns729/portable-ci/v1/install.sh | bash
#
# Knobs (env vars):
#   PORTABLE_CI_DIR       where to clone       (default: ~/.portable-ci)
#   PORTABLE_CI_BIN       where to link `ci`   (default: first writable of
#                         ~/.local/bin, /usr/local/bin)
#   PORTABLE_CI_REF       branch/tag/SHA       (default: v1)
#   PORTABLE_CI_DRY_RUN=1 print what would happen, then exit without doing it
set -euo pipefail

REPO_URL="${PORTABLE_CI_REPO_URL:-https://github.com/Munns729/portable-ci}"
DIR="${PORTABLE_CI_DIR:-$HOME/.portable-ci}"
REF="${PORTABLE_CI_REF:-v1}"
DRY_RUN="${PORTABLE_CI_DRY_RUN:-0}"

say()  { printf 'portable-ci install: %s\n' "$1"; }
die()  { printf 'portable-ci install: %s\n' "$1" >&2; exit 1; }

command -v git  >/dev/null 2>&1 || die "git is required but not found."
command -v bash >/dev/null 2>&1 || die "bash is required but not found."

# --- pick a bin dir on PATH we can write to (read-only; no side effects) ---
pick_bin() {
  if [ -n "${PORTABLE_CI_BIN:-}" ]; then printf '%s\n' "$PORTABLE_CI_BIN"; return; fi
  local d
  for d in "$HOME/.local/bin" /usr/local/bin; do
    if [ -d "$d" ] && [ -w "$d" ]; then printf '%s\n' "$d"; return; fi
  done
  printf '%s\n' "$HOME/.local/bin"   # default target; created later if missing
}
BIN="$(pick_bin)"

# --- say exactly what will happen, up front ---
say "plan:"
say "  clone/update $REPO_URL @ $REF  ->  $DIR"
say "  link         $DIR/bin/ci      ->  $BIN/ci"
if [ "$DRY_RUN" = "1" ]; then
  say "dry run (PORTABLE_CI_DRY_RUN=1) — nothing was changed."
  exit 0
fi

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
