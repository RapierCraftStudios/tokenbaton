#!/usr/bin/env bash
# Tests for `tokenbaton status | keepalive | login` with fake profiles and a
# stub `claude`. No network, never touches real ~/.claude-N.
#   bash tests/account-ctl.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
pass=0 fail=0

setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/home" "$T/acc"
  cp "$REPO"/bin/tokenbaton "$REPO"/bin/tokenbaton-ctl "$REPO"/bin/tokenbaton-profile "$T/bin/"
  # Stub claude: `auth status` refreshes an expired access token the way Claude
  # Code does (new tokens, expiries moved forward) and, with STUB_LEAK_LOCK, exits
  # without releasing the refresh lock; `auth login` writes a fresh login.
  cat > "$T/bin/claude" <<'SH'
#!/usr/bin/env bash
d="$CLAUDE_CONFIG_DIR"; echo "$d $*" >> "$TB_TEST/claude.calls"
now=$(( $(date +%s) * 1000 ))
if [[ "$1 $2" == "auth status" ]]; then
  [[ -n "${STUB_FAIL:-}" ]] && exit 0
  exp=$(sed -E 's/.*"expiresAt":([0-9]+).*/\1/' "$d/.credentials.json")
  if (( exp <= now )); then
    echo "{\"claudeAiOauth\":{\"accessToken\":\"NEWA\",\"refreshToken\":\"NEWR\",\"expiresAt\":$(( now + 28800000 )),\"refreshTokenExpiresAt\":$(( now + 90000000 ))},\"mcpOAuth\":{\"keep\":1}}" > "$d/.credentials.json"
    [[ -n "${STUB_LEAK_LOCK:-}" ]] && mkdir -p "$d.lock"
  fi
  exit 0
elif [[ "$1 $2" == "auth login" ]]; then
  [[ -n "${STUB_LOGIN_FAIL:-}" ]] && exit 1
  echo "{\"claudeAiOauth\":{\"accessToken\":\"A\",\"refreshToken\":\"R\",\"expiresAt\":$(( now + 28800000 )),\"refreshTokenExpiresAt\":$(( now + 90000000 ))}}" > "$d/.credentials.json"
  echo '{"oauthAccount":{"emailAddress":"new@example.com"}}' > "$d/.claude.json"
fi
SH
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH" HOME="$T/home" TOKENBATON_HOME="$T/acc" TOKENBATON_CLAUDE="$T/bin/claude" TB_TEST="$T" \
         TOKENBATON_LOCK_SETTLE=1 TOKENBATON_LOCK_STALE=60 TOKENBATON_PROFILES=3
  unset CLAUDE_CONFIG_DIR STUB_FAIL STUB_LEAK_LOCK STUB_LOGIN_FAIL
}
teardown() { rm -rf "$T"; }

# profile N ACCESS_EXPIRES_IN_S REFRESH_EXPIRES_IN_S EMAIL
profile() {
  local d="$HOME/.claude-$1" now; now=$(date +%s); mkdir -p "$d"
  echo "{\"claudeAiOauth\":{\"accessToken\":\"SECRET-A$1\",\"refreshToken\":\"SECRET-R$1\",\"expiresAt\":$(( (now + $2) * 1000 )),\"refreshTokenExpiresAt\":$(( (now + $3) * 1000 )),\"scopes\":[\"x\"]},\"mcpOAuth\":{\"keep\":1}}" > "$d/.credentials.json"
  chmod 600 "$d/.credentials.json"; touch -d '-2 hours' "$d/.credentials.json"
  echo "{\"oauthAccount\":{\"emailAddress\":\"$4\"}}" > "$d/.claude.json"
}
tb() { OUT="$("$T/bin/tokenbaton" "$@" 2>&1)"; RC=$?; }
ok() {
  if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); echo "FAIL $1"; echo "$OUT" | sed 's/^/     | /'; fi
}
calls() { grep -c "auth status" "$T/claude.calls" 2>/dev/null || echo 0; }

# --- status
setup; now=$(date +%s)
profile 1 7200 90000 a@x.io; profile 2 -100 -50 b@x.io; echo 1 > "$T/acc/current"
echo "40 $(( now + 3600 )) 10 $(( now + 86400 )) $now" > "$T/acc/live.1"
echo "90 $(( now - 60 )) 20 $(( now + 86400 )) $now" > "$T/acc/live.2"
tb status
ok "status lists emails" "grep -q a@x.io <<<\"\$OUT\" && grep -q b@x.io <<<\"\$OUT\""
ok "status marks current account" "grep -qE '^\* +1 ' <<<\"\$OUT\""
ok "status marks stale 5h sample whose window reset" "grep -q 'was 90%\\*' <<<\"\$OUT\""
ok "status: expired refresh is not usable and says how to log in" "grep -q 'tokenbaton login 2' <<<\"\$OUT\""
ok "status: live profile usable" "grep -E ' a@x.io ' <<<\"\$OUT\" | grep -q yes"
ok "status prints no secrets" "! grep -q SECRET <<<\"\$OUT\""
teardown

# --- keepalive
setup; profile 1 7200 90000 a@x.io; profile 2 -100 90000 b@x.io; profile 3 7200 400000 c@x.io
tb keepalive --dry-run
ok "dry-run: no claude calls" "[[ \$(calls) == 0 ]]"
ok "dry-run: near-expiry refresh and expired access would renew; healthy left" \
   "[[ \$(grep -c 'would renew' <<<\"\$OUT\") == 2 ]] && grep -E 'profile 3' <<<\"\$OUT\" | grep -q 'ok, no action'"
ok "dry-run reports no secrets" "! grep -q SECRET <<<\"\$OUT\""
teardown

setup; profile 1 7200 90000 a@x.io; profile 2 -100 90000 b@x.io; profile 3 7200 400000 c@x.io
tb keepalive
ok "keepalive exits 0" "[[ \$RC == 0 ]]"
ok "keepalive ran claude for profiles 1 and 2 only, with their config dirs" \
   "[[ \$(calls) == 2 ]] && grep -q \"^\$HOME/.claude-1 \" '$T/claude.calls' && grep -q \"^\$HOME/.claude-2 \" '$T/claude.calls' && ! grep -q claude-3 '$T/claude.calls'"
ok "expired access token renewed by claude" "grep -q NEWA '$HOME/.claude-2/.credentials.json'"
ok "forced refresh when only refresh token is near expiry" "grep -q NEWA '$HOME/.claude-1/.credentials.json'"
ok "other credential keys preserved, mode 0600" \
   "grep -q mcpOAuth '$HOME/.claude-1/.credentials.json' && [[ \$(stat -c %a '$HOME/.claude-1/.credentials.json') == 600 ]]"
ok "healthy profile untouched" "grep -q SECRET-A3 '$HOME/.claude-3/.credentials.json'"
ok "report says renewed, no secrets" "[[ \$(grep -c 'renewed' <<<\"\$OUT\") == 2 ]] && ! grep -qE 'SECRET|NEW[AR]' <<<\"\$OUT\""
teardown

# claude fails to refresh: original access expiry restored (not left zeroed), exit 1
setup; profile 1 7200 90000 a@x.io; orig="$(cat "$HOME/.claude-1/.credentials.json")"
STUB_FAIL=1 tb keepalive
ok "failed renewal reported, exit 1" "[[ \$RC == 1 ]] && grep -q FAILED <<<\"\$OUT\""
ok "failed renewal leaves credentials as they were" "[[ \"\$(cat '$HOME/.claude-1/.credentials.json')\" == '$orig' ]]"
teardown

# login rewritten minutes ago (a live session just refreshed it): no forced refresh
setup; profile 1 7200 90000 a@x.io; touch "$HOME/.claude-1/.credentials.json"
tb keepalive
ok "recently renewed login is left alone" "[[ \$(calls) == 0 ]] && grep -q 'by a live session' <<<\"\$OUT\""
teardown

# dead refresh token: no claude call, tells the owner the login command
setup; profile 4 -100 -50 d@x.io; TOKENBATON_PROFILES=4 tb keepalive
ok "dead profile: not touched, login command given" "[[ \$(calls) == 0 ]] && grep -q 'tokenbaton login 4' <<<\"\$OUT\""
teardown

# fresh refresh lock (another process is refreshing): left alone
setup; profile 1 -100 90000 a@x.io; mkdir "$HOME/.claude-1.lock"
tb keepalive
ok "live refresh lock respected" "[[ \$(calls) == 0 ]] && grep -q busy <<<\"\$OUT\" && [[ -d '$HOME/.claude-1.lock' ]]"
teardown

# claude exits without releasing the lock: cleared once it stops being touched
setup; profile 1 -100 90000 a@x.io
STUB_LEAK_LOCK=1 tb keepalive
ok "leaked refresh lock is cleared" "[[ ! -e '$HOME/.claude-1.lock' ]] && grep -q renewed <<<\"\$OUT\""
teardown

# stale lock from an earlier crash does not block
setup; profile 1 -100 90000 a@x.io; mkdir "$HOME/.claude-1.lock"; touch -d '-5 min' "$HOME/.claude-1.lock"
tb keepalive
ok "stale lock cleared, profile renewed" "grep -q renewed <<<\"\$OUT\""
teardown

# --- timer install/uninstall (stub systemctl)
setup; mkdir "$T/units"
printf '#!/bin/sh\necho "$@" >> "%s/systemctl.calls"\n' "$T" > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
export TOKENBATON_SYSTEMCTL="$T/bin/systemctl" TOKENBATON_UNIT_DIR="$T/units"
tb keepalive --install
ok "install writes service+timer, enables timer" \
   "[[ -f '$T/units/tokenbaton-keepalive.timer' && -f '$T/units/tokenbaton-keepalive.service' ]] && grep -q 'enable --now tokenbaton-keepalive.timer' '$T/systemctl.calls'"
ok "timer runs every 6h and logs to keepalive.log" \
   "grep -q '00/6:00:00' '$T/units/tokenbaton-keepalive.timer' && grep -q 'keepalive.log' '$T/units/tokenbaton-keepalive.service' && grep -q 'tokenbaton-ctl keepalive' '$T/units/tokenbaton-keepalive.service'"
tb keepalive --uninstall
ok "uninstall removes units" "[[ ! -e '$T/units/tokenbaton-keepalive.timer' && ! -e '$T/units/tokenbaton-keepalive.service' ]]"
unset TOKENBATON_SYSTEMCTL TOKENBATON_UNIT_DIR
teardown

# --- login
setup; mkdir -p "$HOME/.claude"; profile 1 7200 90000 a@x.io; echo 1 > "$T/acc/current"
tb login 2
ok "login N runs claude auth login in that profile and prints the email" \
   "[[ \$RC == 0 ]] && grep -q 'auth login' '$T/claude.calls' && grep -q \"^\$HOME/.claude-2 \" '$T/claude.calls' && grep -q new@example.com <<<\"\$OUT\""
ok "login does not move the current-account marker" "[[ \$(cat '$T/acc/current') == 1 ]]"
tb login --new
ok "login --new picks the next free profile" "grep -q \"^\$HOME/.claude-3 \" '$T/claude.calls' && [[ -f '$HOME/.claude-3/.credentials.json' ]]"
STUB_LOGIN_FAIL=1 tb login 3
ok "failed login exits non-zero" "[[ \$RC != 0 ]]"
tb login x
ok "bad argument rejected" "[[ \$RC == 2 ]]"
teardown

echo "$pass passed, $fail failed"
(( fail == 0 ))
