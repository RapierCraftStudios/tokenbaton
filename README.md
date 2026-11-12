# tokenbaton

Hand your Claude Code conversation to the next account the moment the current one runs out of room.

`tokenbaton` runs Claude Code under several logged-in account profiles. When the
account a window is using reaches its usage limit (99% by default) and Claude is
idle, tokenbaton closes Claude, reopens **the same conversation** on the next
account that has room, and, if your last message was cut off by the limit, sends
`continue` so the work picks up again on its own. You don't have to `/exit`,
press Enter or retype anything.

```
❯ refactor the auth module
  ⎿  You've hit your session limit · resets 12:50pm
tokenbaton: account 1 is at 100% usage; switching 5a13f0e3 automatically
tokenbaton-profile: account 2 (~/.claude-2)
❯ continue
● Picking up where I left off…
```

## Install

Requirements: Linux or macOS, `bash` 4+, `python3`, and Claude Code (`claude` on your `PATH`).

```sh
git clone https://github.com/RapierCraftStudios/tokenbaton.git
ln -s "$PWD/tokenbaton/bin/tokenbaton" "$PWD/tokenbaton/bin/tokenbaton-profile" \
      "$PWD/tokenbaton/bin/tokenbaton-statusline" "$PWD/tokenbaton/bin/tokenbaton-exec" \
      "$PWD/tokenbaton/bin/tokenbaton-ctl" ~/.local/bin/
```

## Set up accounts

Each account lives in its own Claude Code config folder, `~/.claude-1` … `~/.claude-N`.
Log in to each one once:

```sh
tokenbaton login 1       # runs `claude auth login` for ~/.claude-1, then prints the email
tokenbaton login 2       # same for each account you want in the rotation
tokenbaton login --new   # the next free profile number (creates ~/.claude-N)
```

Extra arguments go to `claude auth login` (`--email you@example.com`, `--sso`).
Each profile must be a different account: a login to an account that is already
on another profile is rejected and the profile's previous login is put back, since
two profiles on one account share a single usage pool. `tokenbaton status` marks an
existing duplicate as `DUPLICATE of N`.
If you use more than 5 profiles, set `TOKENBATON_PROFILES`.

Your conversations, settings, memory, `CLAUDE.md`, commands, agents, skills, plugins
and prompt history stay in `~/.claude` and are symlinked into every profile, so they
are shared by all of them. Only the login differs between accounts.

## Use

```sh
tokenbaton                 # start on the best account (see "Which account")
tokenbaton 2               # start on account 2
tokenbaton 2 --resume ID   # any other arguments go straight to claude
```

- **Auto-switch:** once the session (5-hour) or weekly usage reaches the threshold
  and Claude is idle, the conversation moves to the best other account that has room.
  A turn that is still running is never interrupted. Background tasks Claude started
  (e.g. `claude -p` workers) are stopped, and the conversation is asked to restart
  the ones it still needs.
- **Manual switch:** type `/exit`, then press Enter at the `tokenbaton:` prompt. Type `q` to quit.
- **Follows you around:** if you `/resume` or `/clear` inside Claude Code, tokenbaton
  moves on with the conversation you're in now.
- **Which account:** new windows, switches and headless runs all go to the account
  with the most weekly quota at risk: the unused share of its weekly window per hour
  left before that window resets. Unused weekly quota is lost at the reset, so an
  account at 3% that resets in 18 hours goes before one at 6% that resets in 5 days.
  A weekly window that isn't running counts as a full week. Ties go to the lower
  usage; accounts at the switch threshold are skipped. Every window ranks the same
  way, so windows converge on one account and use accounts up one after another.
  `tokenbaton N` still starts on account N, and `TOKENBATON_START=last` starts new
  windows on the last-used account instead.
- **Every account full:** tokenbaton stays where it is and offers the manual prompt.

## Account health

```sh
tokenbaton status       # per profile: email, 5h/7d usage + reset, token expiry, usable?
tokenbaton keepalive    # renew logins that are about to expire
```

`status` never prints tokens. A `*` after a usage figure means the sample is from
before that window reset (so the real figure is now 0). `LOGIN ENDS` is when the
login runs out; `usable` is `no` once it has, and only an interactive
`tokenbaton login N` fixes that.

**Why logins die.** A Claude Code login lasts a fixed time from sign-in (about 30
days). Refreshing it doesn't extend that: on every refresh Claude Code keeps the
earlier of the old and new end dates, and once that date passes it treats the account
as logged out. Only an interactive `tokenbaton login N` starts a new login. The access
token (about 8 hours) is renewed along the way.

`tokenbaton keepalive` keeps every account ready and tells you in time:

- An expired access token is renewed, so the account is ready the moment a window
  switches to it. It runs the real `claude auth status` with `CLAUDE_CONFIG_DIR` set to
  the profile; that makes no model call and refreshes through Claude Code's own code
  path and file format. tokenbaton never calls the OAuth endpoint and never prints a token.
- A login that ends within `TOKENBATON_KEEPALIVE_HOURS` (default 72) is reported as
  `LOGIN ENDS in …` with the `tokenbaton login N` command, and a desktop notification
  (`notify-send`, or `osascript` on macOS) names it. A login that already ended is
  reported as `DEAD` the same way.
- Claude Code's refresh lock (`~/.claude-N.lock`) is respected: a lock touched in the
  last minute means someone is refreshing and the profile is skipped. Because `claude
  auth status` can exit without releasing that lock, tokenbaton removes it afterwards
  once it has stopped being touched.

```sh
tokenbaton keepalive --dry-run     # report only
tokenbaton keepalive --install     # systemd user timer, every 6 hours, log: ~/.tokenbaton/keepalive.log
tokenbaton keepalive --uninstall
# without systemd:  0 */6 * * * ~/.local/bin/tokenbaton keepalive >> ~/.tokenbaton/keepalive.log 2>&1
```

## Start idle usage clocks

A usage window only starts counting down when the account is next used, so an account
that sat idle after a reset loses that time. `tokenbaton prime` checks every logged-in
account on the usage endpoint and, for each one whose 5-hour or weekly window isn't
running, sends one short, ordinary question picked at random (`claude -p` on Haiku,
no tools, no MCP servers, no saved session; `TOKENBATON_PRIME_PROMPT` sets your own) so the reset clock starts now. Accounts whose windows are already
running are left alone.

It doesn't fire right at the reset: the first run that finds a window idle picks a
random delay (5 to 45 minutes by default, `TOKENBATON_PRIME_DELAY_MIN` / `_MAX`) and
primes once that has passed, so accounts start at irregular times. The timer itself
runs every 5 minutes, shifted by up to 2 random minutes each time. An expired access token is renewed first, as in `keepalive`.

```sh
tokenbaton prime --dry-run    # report which accounts would be primed
tokenbaton prime              # prime them now
tokenbaton prime --install    # systemd user timer, about every 5 minutes, log: ~/.tokenbaton/prime.log
tokenbaton prime --uninstall
# without systemd:  */5 * * * * ~/.local/bin/tokenbaton prime >> ~/.tokenbaton/prime.log 2>&1
```

Each prime costs one very small Haiku request on that account.

## Headless runs

Background tools that start `claude` themselves (`claude -p` scripts, CI helpers,
agent orchestrators) don't go through a `tokenbaton` window, so they stay on whatever
`CLAUDE_CONFIG_DIR` they were started with and stall when that account runs out.
`tokenbaton-exec` picks the account with the most room **each time it starts**, so a
long-running orchestrator spreads its workers over every account that has room:

```sh
tokenbaton --pick                      # print the account with the most room right now
tokenbaton-exec -p "summarise CHANGELOG.md"   # run one headless command on it

# Make every `claude` a tool starts go through tokenbaton-exec:
mkdir -p ~/.tokenbaton/shim && ln -sf "$(command -v tokenbaton-exec)" ~/.tokenbaton/shim/claude
env -u CLAUDE_CONFIG_DIR PATH="$HOME/.tokenbaton/shim:$PATH" my-orchestrator ...
```

- The pick uses the same login check and usage figures as the windows (status-line
  data and the shared usage endpoint, whichever is higher), covering the 5-hour, the
  weekly and every other account-wide limit.
- The pick uses the same ranking as new windows (see "Which account").
- Only accounts below `TOKENBATON_SWITCH_AT` are picked. For workers that run for a
  long time, a lower threshold (e.g. `TOKENBATON_SWITCH_AT=90`) leaves headroom.
- If no account has room, the command still runs, on the profile it was started with.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `TOKENBATON_CHECK_EVERY` | `5` | Seconds between usage checks in each window (how soon an idle, full account is switched). |
| `TOKENBATON_SWITCH_AT` | `99` | Usage percent that triggers a switch. `0` turns auto-switch off. |
| `TOKENBATON_PROFILES` | `5` | Number of account profiles (`~/.claude-1` … `~/.claude-N`). |
| `TOKENBATON_HOME` | `~/.tokenbaton` | Where tokenbaton keeps its own small state files. |
| `TOKENBATON_KEEPALIVE_HOURS` | `72` | `keepalive` warns this many hours before a login ends. |
| `TOKENBATON_START` | `best` | `last` starts a new window on the last-used account instead of the best one. |
| `TOKENBATON_PRIME_DELAY_MIN` / `_MAX` | `5` / `45` | `prime` waits a random number of minutes in this range after a window goes idle. |
| `TOKENBATON_PRIME_MODEL` | `haiku` | Model `prime` sends its message with. |

## How it works

- **Login check:** an account counts as logged in when its `.credentials.json` has a
  refresh token that hasn't expired. tokenbaton reads the file directly and never
  runs `claude auth status`. On an expired access token, that command takes the
  refresh lock and exits without releasing it, which blocks every later refresh
  ("another Claude Code process is refreshing it").
- **Stale locks:** before launching an account, tokenbaton removes a `~/.claude-N.lock`
  that's over a minute old if no process is running on that account.
- **Usage:** Claude Code reads the account's usage from the headers of every API
  response and hands it to its status line. tokenbaton launches Claude with a status
  line command (`tokenbaton-statusline`, passed with `--settings`, so your settings file
  isn't touched) that saves those figures per account and shows
  `account N · 5h X% · 7d Y%`. If your settings have their own `statusLine`, that runs
  instead and its output is shown. A usage window whose reset time has passed counts
  as 0.
- **Endpoint:** the status line only sees the 5-hour and weekly windows, and other
  machines and `claude -p` runs don't report through it, so tokenbaton also asks the
  usage endpoint `/usage` uses, at most once a minute per account, and takes the higher
  figure. A figure fetched before a reset the status line has since seen is ignored
  until the next fetch. Only one window asks at a time; it counts every limit not tied
  to a single model, and after a failure (the
  endpoint rate-limits busy accounts with HTTP 429) it keeps the last value and waits five
  minutes. If usage still can't be read, a usage-limit error in the conversation, from
  the current Claude process and not yet reset, counts as the account being full.
- **Idle detection:** the session's live state comes from Claude Code's
  `sessions/<pid>.json`, and tokenbaton only switches while it says `idle`, or
  `shell` (idle, with background tasks such as `claude -p` workers still running).
  In the `shell` case every process Claude started is stopped along with it, since the
  resumed conversation couldn't track them anyway.

## Caveats

- The usage endpoint isn't a documented public API and may change; the status line
  figures come from Claude Code itself.
- tokenbaton's `--settings` status line takes precedence over a `statusLine` set in a
  project's `.claude/settings.json`; one in your user settings is still run.
- A message you're halfway through typing when a switch happens is lost.
- Only use accounts you're entitled to use, and make sure your setup complies with
  Anthropic's terms and your organisation's policies.

## License

[MIT](LICENSE)

tokenbaton is an independent project. It is not affiliated with or endorsed by
Anthropic. Claude and Claude Code are trademarks of Anthropic, PBC.
