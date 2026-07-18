# NukeFire Chat — Design

Status: approved
Date: 2026-07-18

## Summary

A Mallard plugin for the MUD NukeFire (`tdome.nukefire.org`). Captures the
`tell`, `auction`, and `gossip` channels into a tabbed chat panel, with
per-channel settings for gagging from main output, sound, and desktop
notification. Modeled directly on the existing Discworld Chat plugin's
architecture (`/home/john/src/mallardx-discworld-chat`), scoped down to
NukeFire's needs.

More channels (shout, holler, grats, gsay) can be added later the same way,
once their exact line shapes are confirmed in-game.

## Why not GMCP `Comm.Channel`

NukeFire advertises a `Comm.Channel` GMCP package carrying `{chan, player,
msg}` for these channels. It was considered and rejected for v1:

- `msg` embeds raw ANSI/24-bit color escapes (e.g. per-character gradient
  colors on auction item names) — dirtier to parse than Mallard's
  already-color-stripped plain-text line spans.
- Event ordering relative to the matching plain-text line is not reliable
  (observed both orderings in a real session log), so correlating a GMCP
  event to "the next line" to decide whether to gag it is fragile.
- NukeFire's tell lines already disambiguate direction from the text alone
  (`You telepath X, '...'` vs `X telepaths to you, '...'`) — unlike
  Discworld, there's no self-utterance ambiguity GMCP is needed to resolve.

Plain-text `mud.trigger` regexes, same approach as Discworld Chat, are more
robust here and need no `gmcp_access` permission.

## Why not server-side channel toggles (`notell`/`nogossip`/`noauction`)

NukeFire supports opt-out commands per channel (confirmed in-game: `notell`,
`nogossip`, `noauction`, plus `nograts`/`noshout` for future channels), with
confirmation lines `"You are now deaf to <channel>."` /
`"You can now hear <channel>."`. This was explored as a replacement for the
gag checkbox (sending the real command instead of client-side hiding) but
rejected: the user asked to keep parity with Discworld Chat's proven
checkbox model (`gag_main` / `sound` / `notify`) instead. No `sends`
permission is needed as a result.

## Tabs

Fixed, not dynamic: **All**, **Tell**, **Auction**, **Gossip**. Unlike
Discworld's channel set, NukeFire's tell/auction/gossip are not
user-joinable/discoverable — there's no need for Discworld's
pin-a-channel/"Channels" catch-all machinery. Each of the three is a
first-class tab from the start.

Ctrl+Shift+1..4 jump to All/Tell/Auction/Gossip respectively, gated by a
`tab_keybindings` setting (default on) — same pattern as Discworld's
`chat-tab-nav` keymap layer, just fewer bindings.

## Line classification

Pure-Lua `src/classifier.lua`, unit-testable without host APIs, mirroring
Discworld's `classifier.lua`. Confirmed against real lines from
`/home/john/.local/share/net.mallard.app/logs/nukefire-2/2026-07-18.mallardlog`:

| Channel | Direction | Example line | Pattern |
|---|---|---|---|
| tell | outgoing | `You telepath Anne, 'Hello'` | `^You telepath .+, '` |
| tell | incoming | `Anne telepaths to you, 'hah hey'` | `^[A-Za-z][\w' -]*? telepaths to you, '` |
| auction | (always incoming) | `the Auctioneer auctions, 'Opening bid: ...'` | `^[A-Za-z][\w' -]*? auctions, '` |
| gossip | (always incoming) | `an Azer guard gossips, 'I saw a room tear...'` | `^[A-Za-z][\w' -]*? gossips, '` |

`classify(line)` returns `{ tab, incoming }` or `nil`. `incoming = false`
only for the outgoing-tell shape — chime/notify never fire for the player's
own tells, matching Discworld's rule that a user doesn't get chimed for
their own traffic.

Note: gossip speakers are not always capitalized (`"an Azer guard"`, `"a
plague corpse"` — NPC-flavored gossip messages), so the leading-name pattern
must accept any case, unlike Discworld's incoming-tell pattern which
requires a capitalized first name.

Auction speaker is always `"the Auctioneer"` in observed data, but the
pattern is kept general (any name + `" auctions, '"`) rather than hardcoded,
in case players can also broadcast to the channel.

## Routing & gagging (`src/main.lua`)

Same `route_line` shape as Discworld: each of the three `mud.trigger`
registrations calls `classifier.classify`, then:

- Looks up that channel's cached settings (`gag_main`, `sound`, `notify`).
- Posts `{tab, channel, text, ts}` to the panel and appends to the
  scrollback ring buffer.
- Chimes/notifies only when `incoming = true` and the relevant setting is
  on, sharing Discworld's 2s leading-edge debounce so a burst (e.g. several
  rapid auctioneer lines) doesn't spam sound/notifications.
- Returns whether to gag; the trigger calls `m:gag()` if so.

No group-membership detection, no channel-registry/pin bookkeeping, no
self-name GMCP lookup — all Discworld machinery that doesn't apply to a
fixed 3-channel, no-self-ambiguity setup.

## Storage

- `chat_history_v1` — 500-entry scrollback ring buffer, replayed to the
  panel iframe on `ready`. Debounced flush (write every 50 new lines or 30s,
  whichever first; forced flush on disconnect/reload) via `flush_gate.lua`,
  ported unchanged from Discworld Chat.
- `channel_settings_v1` — `{ tell = {...}, auction = {...}, gossip = {...}
  }`, each `{ gag_main, sound, notify }`, all defaulting to `false`. Written
  eagerly on user change (settings toggles are rare and user-initiated, so
  no debounce needed — same reasoning Discworld applies to its channel
  registry's structural changes).
- `active_tab_v1` — last-viewed tab, restored on panel mount.

## UI

Ports Discworld Chat's panel shell (`ui/chat.html`, `chat.css`, `chat.js`,
`tab_index.js`) with:

- `FIXED_TABS` reduced to `["all", "tell", "auction", "gossip"]`, no pinned
  tabs, no "Channels" catch-all tab.
- Settings view lists the 3 channels, each with `gag_main`/`sound`/`notify`
  checkboxes — Discworld's "Sources" section generalized to 3 sources
  instead of 2 (tells/group), and no separate "Channels" add/list UI since
  there's no dynamic channel registry.
- URL autolinking, line rendering, theming: ported unchanged.

## Manifest (`plugin.toml`)

```toml
id = "se.broaty.nukefire-chat"
name = "NukeFire Chat"
version = "0.1.0"
description = "A tabbed chat panel for capturing tells, auction, and gossip on NukeFire."
language = "lua"
entry = "src/main.lua"
mallard_api_version = "1.0"
minimum_app_version = "0.10.0"
authors = ["John"]
license = "MIT"

[worlds]
match = ["tdome.nukefire.org:*"]

[permissions]
notifications = true

[panels.chat]
title              = "Chat"
entry              = "ui/chat.html"
default_dock       = "below"
default_dock_after = "output"
default_size       = { width = 800, height = 200 }

[[keymaps]]
name = "chat-tab-nav"
# Ctrl+Shift+1..4 -> All/Tell/Auction/Gossip

[settings.tab_keybindings]
type    = "bool"
default = true
```

`id`/`authors`/world-match/`minimum_app_version` pattern match the sibling
`se.broaty.nukefire-misc` plugin already installed for this MUD
(`/home/john/dev/mallardx-nukefire-misc`). No `gmcp_access` or `sends`
permission needed.

## Testing

- `tests/classifier_test.lua` — the 4 patterns above against real example
  lines pulled from the session log (both positive matches and near-miss
  negatives, e.g. a gossip-shaped line that shouldn't match auction).
- `tests/flush_gate_test.lua` — ported unchanged from Discworld Chat (pure
  logic, no host dependency).
- `tests/tab_index_test.js` — `tabIdForIndex` against the fixed 4-tab order.

## Known limitations (v1)

- Only tell/auction/gossip are captured; other channels (shout, holler,
  grats, gsay) are not yet classified and will pass through unmodified. As
  of this writing, none of shout/holler/grats have been observed firing in
  a real session, so their line shapes are still unconfirmed.
- `(Skynet)` broadcasts (level-up and remort announcements, e.g. `"(Skynet)
  Attention: Freejack Mickey has reached level 50 in ..."` and `"(Skynet)
  Freejack Corvus has Remorted!"`) are deliberately NOT captured. Unlike
  tell/auction/gossip, Skynet isn't in NukeFire's GMCP `Comm.Channel.List`
  and has no `no<channel>`-style opt-out — it's a system achievement
  broadcast, not a chat channel, and was judged out of scope for a chat
  plugin. Revisit if it turns out to be worth decluttering from main
  output.
- No server-side channel toggle integration — gag/sound/notify are
  client-side only, matching Discworld Chat's model. A channel that's noisy
  can still be muted server-side manually via `notell`/`nogossip`/
  `noauction`, independent of this plugin.
- No replay-marker suppression (Discworld's `htell` handling) — NukeFire's
  `history <channel>` output format wasn't observed with actual history
  present in the session log, so duplicate-on-replay behavior is unverified.
