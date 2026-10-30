#!/usr/bin/env bash
# Regression tests: auto-switch must not depend on tokenbaton's per-window state
# files. A window whose go.<pid>.profile / .session / .started went missing, or
# that can't write go.<pid>.auto (full disk), still moves a conversation off a
# full account onto one with room, instead of falling back to the manual prompt.
#
# No network and no real claude: a fake tokenbaton-profile stands in for Claude
# Code, writing the session record tokenbaton watches, and usage comes from the
# status-line files (live.N).
#   bash tests/state-failsafe.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
pass=0 fail=0

setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/home/.claude/projects/p" "$T/acc"
  cp "$REPO/bin/tokenbaton" "$T/bin/tokenbaton"
  ln -s tokenbaton "$T/bin/claude-go"
  printf '#!/bin/sh\n' > "$T/bin/tokenbaton-statusline"
  cat > "$T/bin/tokenbaton-profile" <<'SH'
#!/usr/bin/env bash
# Fake: log the launch, apply the test's hooks, then act as Claude Code.
n="$1"; shift
acc="$TOKENBATON_HOME" w="$PPID"
echo "$n $*" >> "$TB_TEST/launches"
sid="" prev=""
for a in "$@"; do [[ "$prev" == --session-id || "$prev" == --resume ]] && sid="$a"; prev="$a"; done
[[ -n "$sid" ]] && echo '{"type":"user"}' >> "$HOME/.claude/projects/p/$sid.jsonl"
if [[ "$n" == 1 ]]; then
  [[ -n "${TB_RM:-}" ]] && for x in $TB_RM; do rm -f "$acc/go.$w.$x"; done
  [[ -n "${TB_SWEEP:-}" ]] && "$TB_TEST/bin/tokenbaton" --pick > /dev/null 2>&1
  ls "$acc" > "$TB_TEST/after-hooks"
  [[ -n "${TB_READONLY:-}" ]] && chmod a-w "$acc"
fi
dir="$HOME/.claude-$n"; mkdir -p "$dir/sessions"
printf '{"sessionId":"%s","startedAt":%s,"status":"%s"}' \
  "$sid" "$(( $(date +%s) * 1000 ))" "${TB_STATUS:-idle}" > "$dir/sessions/$$.json"
[[ "$n" == 1 ]] && exec sleep 60
exit 0
SH
  chmod +x "$T/bin/"*
  local now far; now="$(date +%s)"; far=$(( now + 3600 ))
  for n in 1 2; do
    mkdir -p "$T/home/.claude-$n"
    echo '{"claudeAiOauth":{"refreshToken":"r"}}' > "$T/home/.claude-$n/.credentials.json"
  done
  echo "100 $far 0 $far $now" > "$T/acc/live.1"
  echo "${ROOM2:-0} $far 0 $far $now" > "$T/acc/live.2"
  echo 1 > "$T/acc/current"
}

# Start a window on account 1 through $1 (tokenbaton or claude-go) and wait for
# it to end: it ends after relaunching on account 2, or is stopped after $2 seconds.
run() {
  local cmd="$1" limit="${2:-20}" pid i
  # Relative path: the window's command line is just ./<cmd>, whatever $T is.
  ( cd "$T/bin" && exec env -u CLAUDE_CONFIG_DIR HOME="$T/home" TOKENBATON_HOME="$T/acc" \
      TB_TEST="$T" TOKENBATON_PROFILES=2 TOKENBATON_CHECK_EVERY=1 \
      "./$cmd" 1 < /dev/null > "$T/out" 2>&1 ) &
  pid=$!
  for (( i = 0; i < limit * 10; i++ )); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null
  chmod -R u+w "$T/acc" 2>/dev/null
}

teardown() { chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"; }

check() {
  if eval "$2"; then pass=$((pass + 1)); echo "ok   - $1"
  else
    fail=$((fail + 1)); echo "FAIL - $1"
    sed 's/^/       launches: /' "$T/launches" 2>/dev/null
    sed 's/^/       out: /' "$T/out" 2>/dev/null
  fi
}

# The window was started with --session-id <id>; it must resume that id on account 2.
switched() {
  local sid
  sid="$(sed -n '1s/.*--session-id \([^ ]*\).*/\1/p' "$T/launches")"
  [[ -n "$sid" ]] && grep -q "^2 .*--resume $sid\$" "$T/launches" \
    && grep -q 'switching .* automatically' "$T/out" \
    && ! grep -q 'on next account, q to quit' "$T/out"
}

# --- tests ---------------------------------------------------------------

setup; run tokenbaton
check "baseline: full account switches automatically" switched
teardown

setup; TB_RM="profile session started" run tokenbaton
check "missing profile/session/started files: still switches the same conversation" switched
teardown

setup; TB_RM=profile TB_READONLY=1 run tokenbaton
check "state dir unwritable (no auto file can be written): still switches" switched
check "  ...and says so without a usage figure" "grep -q 'account 1 is at its usage limit' '$T/out'"
teardown

setup; TB_SWEEP=1 run claude-go
check "another window's start-up sweep keeps a live claude-go window's state" \
  "grep -q '^go\.[0-9]*\.profile\$' '$T/after-hooks'"
check "  ...and that window still switches" switched
teardown

setup; touch "$T/acc/go.999999999.profile" "$T/acc/go.999999999.auto"; run tokenbaton
check "a dead window's leftover files are removed" "[[ ! -e '$T/acc/go.999999999.profile' && ! -e '$T/acc/go.999999999.auto' ]]"
teardown

setup; TB_STATUS=busy TB_RM=profile run tokenbaton 4
check "a busy Claude is never closed, state files or not" "! grep -q '^2 ' '$T/launches'"
teardown

ROOM2=100 setup; TB_RM=profile run tokenbaton 4
check "no switch when no other account has room" "! grep -q '^2 ' '$T/launches'"
teardown

echo "$pass passed, $fail failed"
(( fail == 0 ))
