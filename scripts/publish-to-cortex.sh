#!/usr/bin/env bash
# Publish selected ClaudeBar commits onto benjaminbelaga/Cortex `main`.
#
# WHY THIS EXISTS (2026-10-04)
#   ClaudeBar (Ben's development line) and Cortex (the public repo) do NOT share
#   a git history — different root commits — so a plain `git push cortex main`
#   is always rejected as non-fast-forward. Publishing was therefore done by
#   hand, five times in one night: create a branch from cortex/main, cherry-pick
#   the commits, resolve the conflicts that the divergent revisions produce
#   (usually by taking one side wholesale), run the gate, push. Every one of
#   those steps is mechanical except the conflict resolution, so this script
#   does the mechanical part and STOPS on the rest.
#
#   1. GitHub Actions policy: Cortex is `self_hosted_only` on the `cortex-ci`
#      lane. A push carrying a workflow that is not on that lane is rejected by
#      the pre-push hook. If your change touches .github/workflows/, check it
#      against the policy before blaming this script.
#   2. The push is fast-forward-only, never --force: Cortex history is never
#      rewritten by this script.
#   3. A cherry-pick conflict is NOT resolved automatically. The script stops,
#      tells you the files, and leaves you on the temporary branch.
#   4. This script runs `git checkout`. Never run it while another session
#      holds the `repo:` claim on this checkout — a whole-tree checkout in a
#      shared worktree is forbidden by the locking doctrine. Publish when you
#      are the only writer, or from a dedicated worktree.
#
# Usage:
#   scripts/publish-to-cortex.sh [--gate] [--dry-run] <commit> [<commit>...]
#   scripts/publish-to-cortex.sh --since-last   # commits in HEAD not yet in cortex
#
#   --gate      run scripts/gate-xcode27.sh on the staging branch before pushing
#   --dry-run   do everything except the final push
#
#   Every run also runs scripts/secret-scan.sh (gitleaks) on the commits being
#   published and refuses on any finding — Cortex is public, there is no undo.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="${CORTEX_REMOTE:-cortex}"
REMOTE_URL="${CORTEX_REMOTE_URL:-git@github.com:benjaminbelaga/Cortex.git}"
BRANCH="publish-to-cortex-$(date +%Y%m%d-%H%M%S)"

GATE=0
DRY_RUN=0
SINCE_LAST=0
COMMITS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --gate) GATE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --since-last) SINCE_LAST=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) echo "publish-to-cortex: unknown option $1" >&2; exit 2 ;;
    *) COMMITS+=("$1"); shift ;;
  esac
done

cd "$REPO"

# --- 0. preflight: clean tree, correct remote ------------------------------
if [ -n "$(git status --porcelain)" ]; then
  echo "publish-to-cortex: REFUSED — working tree is dirty. Commit or stash first:" >&2
  git status --short >&2
  exit 1
fi
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "publish-to-cortex: adding remote '$REMOTE' -> $REMOTE_URL"
  git remote add "$REMOTE" "$REMOTE_URL"
fi

echo "== 1/6 fetch $REMOTE"
git fetch "$REMOTE" main

# --- 2. resolve the commit list -------------------------------------------
if [ "$SINCE_LAST" -eq 1 ]; then
  # Commits whose subject is not already present on the Cortex side. Histories
  # are unrelated, so identity is by commit SUBJECT, which is the only stable
  # signal available and is what a human would compare anyway.
  mapfile -t COMMITS < <(
    git log --format='%h %s' "$(git merge-base --fork-point "$REMOTE/main" HEAD 2>/dev/null || echo HEAD)"..HEAD 2>/dev/null \
      | while read -r sha subject; do
          git log --format='%s' "$REMOTE/main" | grep -Fxq "$subject" || echo "$sha"
        done
  ) || true
fi
if [ "${#COMMITS[@]}" -eq 0 ]; then
  echo "publish-to-cortex: nothing to publish — pass commits, or use --since-last" >&2
  exit 1
fi

# Capture the branch we must return to BEFORE any checkout. Reading it from
# `HEAD@{1}` after `git checkout -b` returns the NEW branch (the reflog entry
# belongs to it), which left the caller stranded on the staging branch — the
# bug that put three commits on the Cortex line on 2026-10-04.
ORIGINAL_REF="$(git symbolic-ref --short -q HEAD || echo main)"

echo "== 2/6 staging branch $BRANCH from $REMOTE/main (returns to $ORIGINAL_REF)"
echo "   commits: ${COMMITS[*]}"
git branch -D "$BRANCH" >/dev/null 2>&1 || true
git checkout -q -b "$BRANCH" "$REMOTE/main"

cleanup() {
  local rc=$?
  git checkout -q "$ORIGINAL_REF" 2>/dev/null || true
  [ "$rc" -eq 0 ] && git branch -D "$BRANCH" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

echo "== 3/6 cherry-pick"
if ! git cherry-pick "${COMMITS[@]}"; then
  cat >&2 <<'EOF'

publish-to-cortex: CHERRY-PICK CONFLICT — this needs a human decision.

The two trees have diverged (Cortex often holds an older revision of the same
file). You are still on the staging branch. Options:

  * take the ClaudeBar version of a whole file (what the 2026-10-03 publishes did):
      git checkout --theirs -- <path> && git add <path> && git cherry-pick --continue
  * take the Cortex version:
      git checkout --ours -- <path> && git add <path> && git cherry-pick --continue
  * abandon:                              git cherry-pick --abort && git checkout main

Then re-run this script's steps 4-6 by hand, or push the staging branch as-is.
EOF
  trap - EXIT INT TERM
  exit 1
fi

echo "== 4/6 workflow policy (Cortex = self-hosted cortex-ci only)"
POLICY="$HOME/.claude/scripts/github-actions-policy.py"
SSOT="$HOME/repos/ecosystem/inventory/github-actions-runners-ssot.yaml"
if [ -f "$POLICY" ] && [ -f "$SSOT" ]; then
  if ! YOYAKU_CI_SSOT="$SSOT" python3 "$POLICY" lint . --repo benjaminbelaga/Cortex >/dev/null; then
    echo "publish-to-cortex: REFUSED — a workflow in this tree is not on the cortex-ci lane." >&2
    YOYAKU_CI_SSOT="$SSOT" python3 "$POLICY" lint . --repo benjaminbelaga/Cortex >&2 || true
    exit 1
  fi
  echo "   ok — workflows pass the Cortex policy"
else
  echo "   WARN: policy or SSOT missing — skipping the pre-flight lint (the push hook still enforces it)"
fi

echo "== 4b/6 secret scan ($REMOTE/main..HEAD, redacted output)"
# Cortex is PUBLIC. A credential that reaches its main is leaked the moment
# it lands, whatever happens next, so this step cannot be skipped or made
# advisory. The scanner's allowlist (.gitleaks.toml) holds test fixtures only.
command -v "${GITLEAKS_BIN:-gitleaks}" >/dev/null 2>&1 || brew install gitleaks
if ! ./scripts/secret-scan.sh "$REMOTE/main..HEAD"; then
  echo "publish-to-cortex: REFUSED — a secret is in the commits being published. Rotate it, rewrite the commit, retry." >&2
  exit 1
fi

if [ "$GATE" -eq 1 ]; then
  echo "== 5/6 gate (release of the staging tree)"
  ./scripts/gate-xcode27.sh >"${TMPDIR:-/tmp}/publish-to-cortex-gate.log" 2>&1 \
    || { echo "publish-to-cortex: REFUSED — gate failed (see ${TMPDIR:-/tmp}/publish-to-cortex-gate.log)"; tail -20 "${TMPDIR:-/tmp}/publish-to-cortex-gate.log" >&2; exit 1; }
  tail -1 "${TMPDIR:-/tmp}/publish-to-cortex-gate.log"
else
  echo "== 5/6 gate skipped (pass --gate to require it)"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "== 6/6 DRY RUN — staging branch $BRANCH is ready, nothing pushed"
  trap - EXIT INT TERM
  exit 0
fi

echo "== 6/6 push (fast-forward only)"
git push "$REMOTE" "$BRANCH:main"
echo "publish-to-cortex: OK — $(git rev-parse "$BRANCH") is now Cortex main"
