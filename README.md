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
ln -s "$PWD/tokenbaton/bin/tokenbaton" "$PWD/tokenbaton/bin/tokenbaton-profile" ~/.local/bin/
```

## Set up accounts

Each account lives in its own Claude Code config folder, `~/.claude-1` … `~/.claude-N`.
Log in to each one once:

```sh
tokenbaton-profile 1     # then run /login inside Claude Code, then /exit
tokenbaton-profile 2     # same for each account you want in the rotation
```

Your conversations, settings, memory, `CLAUDE.md`, commands, agents, skills, plugins
and prompt history stay in `~/.claude` and are symlinked into every profile, so they
are shared by all of them. Only the login differs between accounts.

## Use

```sh
tokenbaton                 # start on the last-used account
tokenbaton 2               # start on account 2
tokenbaton 2 --resume ID   # any other arguments go straight to claude
```

- **Auto-switch:** once the session (5-hour) or weekly usage reaches the threshold
  and Claude is idle, the conversation moves to the next account that has room.
  A turn that is still running is never interrupted.
- **Manual switch:** type `/exit`, then press Enter at the `tokenbaton:` prompt. Type `q` to quit.
- **Follows you around:** if you `/resume` or `/clear` inside Claude Code, tokenbaton
  moves on with the conversation you're in now.
- **Every account full:** tokenbaton stays where it is and offers the manual prompt.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `TOKENBATON_SWITCH_AT` | `99` | Usage percent that triggers a switch. `0` turns auto-switch off. |
| `TOKENBATON_PROFILES` | `5` | Number of account profiles (`~/.claude-1` … `~/.claude-N`). |
| `TOKENBATON_HOME` | `~/.tokenbaton` | Where tokenbaton keeps its own small state files. |

## How it works

- **Login check:** an account counts as logged in when its `.credentials.json` has a
  refresh token that hasn't expired. tokenbaton reads the file directly and never
  runs `claude auth status`. On an expired access token, that command takes the
  refresh lock and exits without releasing it, which blocks every later refresh
  ("another Claude Code process is refreshing it").
- **Stale locks:** before launching an account, tokenbaton removes a `~/.claude-N.lock`
  that's over a minute old if no process is running on that account.
- **Usage:** each window checks its account's usage about once a minute. The result is
  cached for all windows.
- **Idle detection:** the session's live state comes from Claude Code's
  `sessions/<pid>.json`, and tokenbaton only switches while it says `idle`.

## Caveats

- Usage is read from the same endpoint Claude Code's `/usage` uses. It isn't a
  documented public API and may change. If it can't be read, auto-switch just doesn't fire.
- A message you're halfway through typing when a switch happens is lost.
- Only use accounts you're entitled to use, and make sure your setup complies with
  Anthropic's terms and your organisation's policies.

## License

[MIT](LICENSE)

tokenbaton is an independent project. It is not affiliated with or endorsed by
Anthropic. Claude and Claude Code are trademarks of Anthropic, PBC.
