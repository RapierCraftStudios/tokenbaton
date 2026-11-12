#!/usr/bin/env bash
# Account choice: new windows, headless picks and switches go to the account
# with the most weekly quota at risk (unused percent per hour to its weekly
# reset), then the lowest usage. No network: usage comes from live.N and a
# fresh endpoint cache (used.N).
#   bash tests/ranking.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
pass=0 fail=0

setup() {
  T="$(mktemp -d)"; mkdir -p "$T/bin" "$T/home" "$T/acc"
  cp "$REPO/bin/tokenbaton" "$T/bin/"
  printf '#!/bin/sh\necho "$1" > "%s/launched"\n' "$T" > "$T/bin/tokenbaton-profile"
  printf '#!/bin/sh\n' > "$T/bin/tokenbaton-statusline"
  chmod +x "$T/bin/"*
  now="$(date +%s)"
}
# acct N 5H% 7D% 7D_RESET_IN_S [ENDPOINT%]
acct() {
  mkdir -p "$T/home/.claude-$1"
  echo '{"claudeAiOauth":{"refreshToken":"r"}}' > "$T/home/.claude-$1/.credentials.json"
  echo "$2 $(( now + 3600 )) $3 $(( now + $4 )) $now" > "$T/acc/live.$1"
  echo "${5:-$3} $now" > "$T/acc/used.$1"
}
pick() {
  OUT="$(env -u CLAUDE_CONFIG_DIR HOME="$T/home" TOKENBATON_HOME="$T/acc" TOKENBATON_PROFILES="${P:-4}" \
         "$T/bin/tokenbaton" --pick 2>&1)"
}
check() {
  if eval "$2"; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (got: $OUT)"; fi
}

setup
acct 1 10 45 $(( 125 * 3600 ))     # 55% left over 5 days
acct 2 0 6 $(( 132 * 3600 ))       # 94% over 5.5 days
acct 3 0 3 $(( 18 * 3600 ))        # 97% over 18h: most at risk
acct 4 0 59 $(( 107 * 3600 ))
pick; check "picks the account whose unused weekly quota resets soonest" '[[ $OUT == 3 ]]'
acct 3 99 3 $(( 18 * 3600 ))
pick; check "skips an account at the switch threshold" '[[ $OUT == 2 ]]'
acct 3 0 3 $(( 18 * 3600 )) 99
pick; check "endpoint figure at the threshold also rules it out" '[[ $OUT == 2 ]]'
acct 3 0 3 $(( 18 * 3600 )); acct 2 0 99 $(( 2 * 3600 ))
pick; check "an almost-used-up week is not urgent" '[[ $OUT == 3 ]]'
rm -rf "$T"

setup
acct 1 30 20 $(( 100 * 3600 )); acct 2 5 20 $(( 100 * 3600 ))
P=2 pick; check "ties go to the lower usage" '[[ $OUT == 2 ]]'
echo "0 0 0 0 $now" > "$T/acc/live.1"; echo "0 $now" > "$T/acc/used.1"
acct 2 0 50 $(( 160 * 3600 ))
P=2 pick; check "an idle weekly window counts as a full week of quota" '[[ $OUT == 1 ]]'
rm -rf "$T"

setup
acct 1 0 50 $(( 100 * 3600 )); acct 2 0 0 $(( 10 * 3600 )); echo 1 > "$T/acc/current"
env -u CLAUDE_CONFIG_DIR HOME="$T/home" TOKENBATON_HOME="$T/acc" TOKENBATON_PROFILES=2 \
  "$T/bin/tokenbaton" </dev/null >/dev/null 2>&1; OUT="$(cat "$T/launched")"
check "a new window starts on the best account, not the last-used one" '[[ $OUT == 2 ]]'
env -u CLAUDE_CONFIG_DIR HOME="$T/home" TOKENBATON_HOME="$T/acc" TOKENBATON_PROFILES=2 TOKENBATON_START=last \
  "$T/bin/tokenbaton" </dev/null >/dev/null 2>&1; OUT="$(cat "$T/launched")"
check "TOKENBATON_START=last keeps the last-used account" '[[ $OUT == 1 ]]'
env -u CLAUDE_CONFIG_DIR HOME="$T/home" TOKENBATON_HOME="$T/acc" TOKENBATON_PROFILES=2 \
  "$T/bin/tokenbaton" 1 </dev/null >/dev/null 2>&1; OUT="$(cat "$T/launched")"
check "an explicit account number still wins" '[[ $OUT == 1 ]]'
rm -rf "$T"

echo "$pass passed, $fail failed"
(( fail == 0 ))
