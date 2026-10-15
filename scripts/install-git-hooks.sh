#!/usr/bin/env bash
# Install the Cortex git hooks into this clone's .git/hooks.
#
# pre-push: runs scripts/secret-scan.sh on every ref about to leave this
# machine. A credential in a commit you are pushing aborts the push before a
# single byte reaches GitHub — the only moment at which a leak into a public
# repository is still free to undo.
#
# Usage: scripts/install-git-hooks.sh
# Bypass for one push (you had better be sure): git push --no-verify
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$(git -C "$REPO" rev-parse --git-path hooks)"
case "$HOOKS_DIR" in
  /*) ;;
  *) HOOKS_DIR="$REPO/$HOOKS_DIR" ;;
esac
mkdir -p "$HOOKS_DIR"

HOOK="$HOOKS_DIR/pre-push"
if [ -e "$HOOK" ] && ! grep -q 'secret-scan.sh' "$HOOK"; then
  echo "install-git-hooks: $HOOK already exists and is not ours — refusing to overwrite." >&2
  echo "  Move it aside, or add a call to scripts/secret-scan.sh to it by hand." >&2
  exit 1
fi

cat > "$HOOK" <<'HOOKEOF'
#!/usr/bin/env bash
# Installed by scripts/install-git-hooks.sh — do not edit here, edit the installer.
# git feeds one line per ref on stdin: <local ref> <local sha> <remote ref> <remote sha>
set -euo pipefail
REPO="$(git rev-parse --show-toplevel)"
ZERO="0000000000000000000000000000000000000000"
status=0
while read -r local_ref local_sha remote_ref remote_sha; do
  [ "$local_sha" = "$ZERO" ] && continue            # deleting a remote ref: nothing to scan
  if [ "$remote_sha" = "$ZERO" ]; then
    range="$local_sha --not --remotes"               # new remote branch: everything not yet on any remote
  else
    range="$remote_sha..$local_sha"
  fi
  if ! "$REPO/scripts/secret-scan.sh" $range; then
    echo "pre-push: REFUSED — a secret was found in the commits for $remote_ref (see above, redacted)." >&2
    echo "pre-push: rotate the credential first; then rewrite the commit (git rebase -i / git commit --amend)." >&2
    status=1
  fi
done
exit $status
HOOKEOF
chmod +x "$HOOK"
echo "install-git-hooks: installed $HOOK"
