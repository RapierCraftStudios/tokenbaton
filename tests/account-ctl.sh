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
elif [[ "$1" == "-p" ]]; then
  [[ -n "${STUB_PRIME_FAIL:-}" ]] && { echo "boom" >&2; exit 3; }
  # A message starts the account's idle windows.
  n="${d##*-}"; echo '{"five_hour":{"utilization":1,"resets_at":"2099-01-01T00:00:00.5+00:00"},"seven_day":{"utilization":2,"resets_at":"2099-01-05T00:00:00+00:00"}}' > "$TB_TEST/usage.$n.json"
  echo ok; exit 0
elif [[ "$1 $2" == "auth login" ]]; then
  [[ -n "${STUB_LOGIN_FAIL:-}" ]] && exit 1
  echo "{\"claudeAiOauth\":{\"accessToken\":\"A\",\"refreshToken\":\"R\",\"expiresAt\":$(( now + 28800000 )),\"refreshTokenExpiresAt\":$(( now + 90000000 ))}}" > "$d/.credentials.json"
  echo "{\"oauthAccount\":{\"emailAddress\":\"${STUB_LOGIN_EMAIL:-new@example.com}\",\"accountUuid\":\"${STUB_LOGIN_UUID:-u-new}\",\"organizationUuid\":\"org\"}}" > "$d/.claude.json"
fi
SH
  printf '#!/bin/sh\nshift 4; printf "%%s\\n" "$@" >> "%s/notify.calls"\n' "$T" > "$T/bin/notify-send"
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
# 1: access valid, login ends in 25h (inside the 72h warning window)
# 2: access expired, login fine     3: healthy
setup; profile 1 7200 90000 a@x.io; profile 2 -100 400000 b@x.io; profile 3 7200 400000 c@x.io
tb keepalive --dry-run
ok "dry-run: no claude calls, no notification" "[[ \$(calls) == 0 ]] && [[ ! -e '$T/notify.calls' ]]"
ok "dry-run: only the expired access token would renew" \
   "[[ \$(grep -c 'would renew' <<<\"\$OUT\") == 1 ]] && grep 'profile 2' <<<\"\$OUT\" | grep -q 'would renew'"
ok "dry-run reports no secrets" "! grep -q SECRET <<<\"\$OUT\""
teardown

setup; profile 1 7200 90000 a@x.io; profile 2 -100 400000 b@x.io; profile 3 7200 400000 c@x.io
tb keepalive
ok "keepalive exits 0" "[[ \$RC == 0 ]]"
ok "claude runs only for the expired access token" \
   "[[ \$(calls) == 1 ]] && grep -q \"^\$HOME/.claude-2 \" '$T/claude.calls'"
ok "expired access token renewed by claude" "grep -q NEWA '$HOME/.claude-2/.credentials.json'"
ok "a login near its end is not force-refreshed (a refresh can't extend it)" \
   "grep -q SECRET-A1 '$HOME/.claude-1/.credentials.json'"
ok "a login near its end is reported with the login command" \
   "grep 'profile 1' <<<\"\$OUT\" | grep -q 'LOGIN ENDS in 1d0h.*tokenbaton login 1'"
ok "and a desktop notification names it" "grep -q 'profile 1 (a@x.io) login ends' '$T/notify.calls' && ! grep -q 'profile 3' '$T/notify.calls'"
ok "other credential keys preserved, mode 0600" \
   "grep -q mcpOAuth '$HOME/.claude-2/.credentials.json' && [[ \$(stat -c %a '$HOME/.claude-2/.credentials.json') == 600 ]]"
ok "healthy profile untouched" "grep -q SECRET-A3 '$HOME/.claude-3/.credentials.json'"
ok "report says renewed, no secrets" "[[ \$(grep -c 'renewed' <<<\"\$OUT\") == 1 ]] && ! grep -qE 'SECRET|NEW[AR]' <<<\"\$OUT\""
teardown

# claude fails to refresh: reported, exit 1, credentials untouched
setup; profile 1 -100 400000 a@x.io; orig="$(cat "$HOME/.claude-1/.credentials.json")"
STUB_FAIL=1 tb keepalive
ok "failed renewal reported, exit 1" "[[ \$RC == 1 ]] && grep -q FAILED <<<\"\$OUT\""
ok "failed renewal leaves credentials as they were" "[[ \"\$(cat '$HOME/.claude-1/.credentials.json')\" == '$orig' ]]"
teardown

# dead refresh token: no claude call, tells the owner the login command
setup; profile 4 -100 -50 d@x.io; TOKENBATON_PROFILES=4 tb keepalive
ok "dead profile: not touched, login command given" "[[ \$(calls) == 0 ]] && grep -q 'tokenbaton login 4' <<<\"\$OUT\""
ok "dead profile: notified" "grep -q 'profile 4 (d@x.io) is logged out' '$T/notify.calls'"
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
STUB_LOGIN_UUID=u-other tb login --new
ok "login --new picks the next free profile" "grep -q \"^\$HOME/.claude-3 \" '$T/claude.calls' && [[ -f '$HOME/.claude-3/.credentials.json' ]]"
STUB_LOGIN_FAIL=1 tb login 3
ok "failed login exits non-zero" "[[ \$RC != 0 ]]"
tb login x
ok "bad argument rejected" "[[ \$RC == 2 ]]"
teardown

# --- login rejects an account already on another profile
setup; mkdir -p "$HOME/.claude"
profile 1 7200 90000 a@x.io; echo '{"oauthAccount":{"emailAddress":"a@x.io","accountUuid":"u-a","organizationUuid":"org"}}' > "$HOME/.claude-1/.claude.json"
profile 2 7200 90000 b@x.io; echo '{"oauthAccount":{"emailAddress":"b@x.io","accountUuid":"u-b","organizationUuid":"org"}}' > "$HOME/.claude-2/.claude.json"
cp "$HOME/.claude-2/.credentials.json" "$T/creds2.before"
STUB_LOGIN_EMAIL=a@x.io STUB_LOGIN_UUID=u-a tb login 2
ok "duplicate login is rejected and names the other profile" "[[ \$RC == 1 ]] && grep -q 'rejected: a@x.io is already logged in on profile 1' <<<\"\$OUT\""
ok "rejected login puts the profile's previous login back" \
   "cmp -s '$T/creds2.before' '$HOME/.claude-2/.credentials.json' && grep -q b@x.io '$HOME/.claude-2/.claude.json'"
STUB_LOGIN_EMAIL=a@x.io STUB_LOGIN_UUID=u-a tb login 3
ok "duplicate on a fresh profile leaves it logged out" "[[ \$RC == 1 && ! -e '$HOME/.claude-3/.credentials.json' ]]"
STUB_LOGIN_EMAIL=a@x.io STUB_LOGIN_UUID=u-a tb login 1
ok "re-logging a profile into its own account is fine" "[[ \$RC == 0 ]]"
echo '{"oauthAccount":{"emailAddress":"a@x.io","accountUuid":"u-a","organizationUuid":"org"}}' > "$HOME/.claude-2/.claude.json"
tb status
ok "status flags an existing duplicate" "grep -qE '^ +2 .*DUPLICATE of 1' <<<\"\$OUT\" && ! grep -qE '^ +1 .*DUPLICATE' <<<\"\$OUT\""
teardown

# --- prime (delay 0 here; the random delay has its own tests below)
setup; profile 1 7200 90000 a@x.io; profile 2 7200 90000 b@x.io; profile 3 -100 -50 c@x.io
export TOKENBATON_USAGE_URL="file://$T/usage.{n}.json" TOKENBATON_PRIME_DELAY_MIN=0 TOKENBATON_PRIME_DELAY_MAX=0
echo '{"five_hour":{"utilization":10,"resets_at":"2099-01-01T00:00:00+00:00"},"seven_day":{"utilization":20,"resets_at":"2099-01-05T00:00:00+00:00"}}' > "$T/usage.1.json"
echo '{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":0,"resets_at":null}}' > "$T/usage.2.json"
tb prime --dry-run
ok "dry-run reports idle windows without sending" \
   "grep -q 'profile 2.*would prime (5h+7d idle)' <<<\"\$OUT\" && ! grep -q -- ' -p ' '$T/claude.calls' 2>/dev/null"
tb prime
ok "running windows are left alone" "grep -q 'profile 1.*ok, windows running' <<<\"\$OUT\" && ! grep -q \"^\$HOME/.claude-1 -p\" '$T/claude.calls'"
ok "idle account gets one short haiku question with no tools or session" \
   "[[ \$(grep -c \"^\$HOME/.claude-2 -p\" '$T/claude.calls') == 1 ]] && grep -q -- '--model haiku --tools  --strict-mcp-config --no-session-persistence' '$T/claude.calls'"
ok "the prime message reads like an ordinary question" \
   "grep \"^\$HOME/.claude-2 -p\" '$T/claude.calls' | grep -q '?' && ! grep -qi 'reply with just' '$T/claude.calls'"
ok "primed account reports its new reset times and writes live.N" \
   "grep -q 'profile 2.*primed (5h+7d idle); now 5h 1%' <<<\"\$OUT\" && [[ \$(cut -d' ' -f1,3 '$T/acc/live.2') == '1 2' ]]"
ok "dead login is skipped, nothing printed secret" \
   "grep -q 'profile 3.*skipped: not logged in' <<<\"\$OUT\" && ! grep -q SECRET <<<\"\$OUT\" && [[ \$RC == 0 ]]"
echo '{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":3,"resets_at":"2099-01-05T00:00:00+00:00"}}' > "$T/usage.2.json"
STUB_PRIME_FAIL=1 tb prime
ok "failed prime is reported and exits non-zero" "grep -q 'profile 2.*FAILED to prime: claude exited 3: boom' <<<\"\$OUT\" && [[ \$RC == 1 ]]"
export TOKENBATON_SYSTEMCTL="$T/bin/systemctl" TOKENBATON_UNIT_DIR="$T/units"
printf '#!/bin/sh\necho "$@" >> "%s/systemctl.calls"\n' "$T" > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
tb prime --install
ok "prime --install writes a 5-minute timer logging to prime.log" \
   "grep -q 'RandomizedDelaySec=120' '$T/units/tokenbaton-prime.timer' && grep -q '\\*:00/5' '$T/units/tokenbaton-prime.timer' && grep -q 'tokenbaton-ctl prime' '$T/units/tokenbaton-prime.service' && grep -q prime.log '$T/units/tokenbaton-prime.service' && grep -q 'enable --now tokenbaton-prime.timer' '$T/systemctl.calls'"
tb prime --uninstall
ok "prime --uninstall removes its units" "[[ ! -e '$T/units/tokenbaton-prime.timer' ]]"
unset TOKENBATON_USAGE_URL TOKENBATON_SYSTEMCTL TOKENBATON_UNIT_DIR TOKENBATON_PRIME_DELAY_MIN TOKENBATON_PRIME_DELAY_MAX
teardown

# --- prime waits a random delay after a window goes idle
setup; profile 1 7200 90000 a@x.io
export TOKENBATON_USAGE_URL="file://$T/usage.{n}.json" TOKENBATON_PRIME_DELAY_MIN=10 TOKENBATON_PRIME_DELAY_MAX=20
echo '{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":4,"resets_at":"2099-01-05T00:00:00+00:00"}}' > "$T/usage.1.json"
TOKENBATON_PROFILES=1 tb prime --dry-run
ok "dry-run of a newly idle window schedules nothing" "[[ ! -e '$T/acc/prime.1' ]]"
TOKENBATON_PROFILES=1 tb prime
due=$(cat "$T/acc/prime.1" 2>/dev/null || echo 0); now=$(date +%s)
ok "newly idle window is not primed at once" "! grep -q -- ' -p ' '$T/claude.calls' 2>/dev/null && grep -q '5h idle; primes in 1' <<<\"\$OUT\""
ok "its prime time is 10-20 minutes out" "(( due >= now + 590 && due <= now + 1200 ))"
TOKENBATON_PROFILES=1 tb prime
ok "later runs keep the same prime time" "[[ \$(cat '$T/acc/prime.1') == $due ]] && ! grep -q -- ' -p ' '$T/claude.calls' 2>/dev/null"
echo $(( now - 1 )) > "$T/acc/prime.1"
TOKENBATON_PROFILES=1 tb prime
ok "once due it is primed and the schedule cleared" "grep -q -- ' -p ' '$T/claude.calls' && [[ ! -e '$T/acc/prime.1' ]] && grep -q 'primed (5h idle)' <<<\"\$OUT\""
echo 99999999999 > "$T/acc/prime.1"
TOKENBATON_PROFILES=1 tb prime
ok "a running window clears a leftover schedule" "[[ ! -e '$T/acc/prime.1' ]]"
unset TOKENBATON_USAGE_URL TOKENBATON_PRIME_DELAY_MIN TOKENBATON_PRIME_DELAY_MAX
teardown

echo "$pass passed, $fail failed"
(( fail == 0 ))
