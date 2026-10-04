#!/usr/bin/env bash
# Refuse to let a credential reach the public Cortex repository.
#
# Runs gitleaks (https://github.com/gitleaks/gitleaks) with the repository's
# .gitleaks.toml over a commit range, and exits non-zero on any finding. One
# scanner, three callers, so they cannot drift:
#
#   scripts/publish-to-cortex.sh   the staging branch, cortex/main..HEAD
#   .git/hooks/pre-push            every ref about to be pushed (install with
#                                  scripts/install-git-hooks.sh)
#   .github/workflows/tests.yml    the whole history, --all
#
# Usage:
#   scripts/secret-scan.sh [<git log args...>]
#     default range: origin/main..HEAD
#   scripts/secret-scan.sh --all              whole history
#   scripts/secret-scan.sh --worktree         uncommitted tree instead of commits
#
# Environment:
#   GITLEAKS_BIN   path to the gitleaks binary (default: `gitleaks` on PATH)
#
# Findings are printed REDACTED: the scanner must never echo the secret it
# just caught into a terminal, a CI log or a hook transcript.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
GITLEAKS="${GITLEAKS_BIN:-gitleaks}"
CONFIG="$REPO/.gitleaks.toml"

if ! command -v "$GITLEAKS" >/dev/null 2>&1; then
  cat >&2 <<MSG
secret-scan: gitleaks is not installed (looked for: $GITLEAKS)
  macOS:  brew install gitleaks
  other:  https://github.com/gitleaks/gitleaks/releases
  or set GITLEAKS_BIN=/path/to/gitleaks
MSG
  exit 2
fi
[ -f "$CONFIG" ] || { echo "secret-scan: missing $CONFIG" >&2; exit 2; }

cd "$REPO"

if [ "${1:-}" = "--worktree" ]; then
  echo "secret-scan: scanning the working tree"
  exec "$GITLEAKS" dir --config "$CONFIG" --redact --no-banner --exit-code 1 .
fi

if [ $# -eq 0 ]; then
  set -- "origin/main..HEAD"
fi
# `git log` arguments are passed through untouched, so a caller can scan
# `--all`, `A..B`, or `<sha> --not --remotes` alike.
echo "secret-scan: scanning commits: $*"
exec "$GITLEAKS" git --config "$CONFIG" --redact --no-banner --exit-code 1 \
  --log-opts="$*" .
