#!/usr/bin/env bash
# Tests for scripts/secret-scan.sh, .gitleaks.toml and the pre-push hook.
#
# No network, no writes outside a temp directory. Needs gitleaks on PATH or
# GITLEAKS_BIN set.
#
#     scripts/tests/test_secret_scan.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GITLEAKS="${GITLEAKS_BIN:-gitleaks}"
command -v "$GITLEAKS" >/dev/null 2>&1 || { echo "SKIP: gitleaks not installed"; exit 0; }
export GITLEAKS_BIN="$GITLEAKS"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0

# A fake AWS access key id: the gitleaks `aws-access-token` rule is a pure
# regex match (AKIA + 16 upper/digits), so this is deterministic. Not Amazon's
# documented AKIAIOSFODNN7EXAMPLE, which gitleaks allowlists. Built by
# concatenation so this test file never contains the pattern itself.
FAKE_SECRET="AKIA$(printf 'Q7X2M9P4L6R8T3V5')"

# ---- fixture repo: a clone of the scripts + config, with its own history ----
mk_repo() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  cp "$ROOT/.gitleaks.toml" "$dir/"
  cp "$ROOT/scripts/secret-scan.sh" "$ROOT/scripts/install-git-hooks.sh" "$dir/scripts/"
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.name=t -c user.email=t@t config commit.gpgsign false
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@t commit -qm "base"
}
commit_file() { # repo path content message
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$4"
}

# 1. The real repository is clean over its whole history (baseline).
"$ROOT/scripts/secret-scan.sh" --all >/dev/null 2>&1 || fail "the Cortex history itself has a finding"
pass=$((pass+1))

# 2. A commit carrying a credential is refused; output is redacted.
R="$TMP/leak"; mk_repo "$R"
BASE="$(git -C "$R" rev-parse HEAD)"
commit_file "$R" "config.env" "AWS_ACCESS_KEY_ID=$FAKE_SECRET" "oops"
set +e; out="$("$R/scripts/secret-scan.sh" "$BASE..HEAD" 2>&1)"; rc=$?; set -e
[ "$rc" -eq 1 ] || fail "expected exit 1 on a leaked key, got $rc: $out"
case "$out" in *"$FAKE_SECRET"*) fail "the scanner printed the secret it caught" ;; esac
pass=$((pass+1))

# 3. The known test fixtures are allowlisted, nothing else on the same line is.
F="$TMP/fixtures"; mk_repo "$F"
BASE="$(git -C "$F" rev-parse HEAD)"
commit_file "$F" "Fixture.swift" '"api_key": "sk-ant-test-key-12345", "cookie": "login_aliyunid_ticket=abc123"' "fixtures"
"$F/scripts/secret-scan.sh" "$BASE..HEAD" >/dev/null 2>&1 || fail "allowlisted fixtures were reported"
pass=$((pass+1))

# 4. --worktree catches an uncommitted credential.
W="$TMP/worktree"; mk_repo "$W"
printf 'token=%s\n' "$FAKE_SECRET" > "$W/notes.txt"
set +e; "$W/scripts/secret-scan.sh" --worktree >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 1 ] || fail "--worktree missed an uncommitted key (rc=$rc)"
pass=$((pass+1))

# 5. The pre-push hook blocks a push that carries a credential, and lets a
#    clean push through. Pushes go to a local bare remote — no network.
H="$TMP/hooked"; mk_repo "$H"
git init -q --bare "$TMP/remote.git"
git -C "$H" remote add origin "$TMP/remote.git"
"$H/scripts/install-git-hooks.sh" >/dev/null
[ -x "$H/.git/hooks/pre-push" ] || fail "hook not installed"
git -C "$H" push -q origin main 2>/dev/null || fail "clean initial push was refused"
commit_file "$H" "leak.txt" "key: $FAKE_SECRET" "leak"
set +e; out="$(git -C "$H" push origin main 2>&1)"; rc=$?; set -e
[ "$rc" -ne 0 ] || fail "pre-push let a credential through"
case "$out" in *"pre-push: REFUSED"*) ;; *) fail "hook did not explain the refusal: $out" ;; esac
case "$out" in *"$FAKE_SECRET"*) fail "hook output contains the secret" ;; esac
git -C "$H" reset -q --hard HEAD~1
commit_file "$H" "ok.txt" "nothing to see" "clean"
git -C "$H" push -q origin main 2>/dev/null || fail "clean follow-up push was refused"
pass=$((pass+1))

# 6. The installer refuses to clobber a foreign pre-push hook.
X="$TMP/foreign"; mk_repo "$X"
mkdir -p "$X/.git/hooks"; printf '#!/bin/sh\nexit 0\n' > "$X/.git/hooks/pre-push"
set +e; "$X/scripts/install-git-hooks.sh" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 1 ] || fail "installer overwrote a foreign hook (rc=$rc)"
pass=$((pass+1))

echo "OK: $pass secret-scan checks passed"
