#!/usr/bin/env bash
# test/integration.sh — end-to-end install + save + load cycle.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t ccm-int-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.claude"

# Stub claude on PATH
STUB="$TMP/stub-bin"
mkdir -p "$STUB"
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
cat <<R
## SUMMARY
Integration test session.

## IN_PROGRESS
Verifying integration.
R
EOF
chmod +x "$STUB/claude"
export PATH="$STUB:$PATH"

# Fake project dir
PROJ="$TMP/proj"
mkdir -p "$PROJ"
cd "$PROJ"
git init -q
git remote add origin https://github.com/example/foo.git

# Install
bash "$REPO_ROOT/install.sh" --quiet

# Save with the fixture transcript
TRANSCRIPT="$TMP/transcript.jsonl"
cp "$REPO_ROOT/test/fixtures/transcripts/sample.jsonl" "$TRANSCRIPT"
"$REPO_ROOT/bin/ccm" save "$TRANSCRIPT"

# Verify timeline entry exists
PID="$("$REPO_ROOT/bin/ccm" id)"
PDIR="$HOME/.claude/context-manager/$PID"
test -d "$PDIR/timeline" || { echo "FAIL: no timeline dir"; exit 1; }
COUNT="$(ls -1 "$PDIR/timeline" | wc -l | tr -d ' ')"
test "$COUNT" -eq 1 || { echo "FAIL: expected 1 timeline entry, got $COUNT"; exit 1; }

# Load
OUT="$("$REPO_ROOT/bin/ccm" load)"
echo "$OUT" | grep -q "Restored Context" || { echo "FAIL: load output missing header"; exit 1; }
echo "$OUT" | grep -q "Verifying integration" || { echo "FAIL: load output missing in-progress"; exit 1; }

echo "integration: PASS"
