# NukeFire Chat — Design

Status: approved
Date: 2026-07-18

## Summary

A Mallard plugin for the MUD NukeFire (`tdome.nukefire.org`). Captures the
`tell`, `auction`, `gossip`, and `group` channels into a tabbed chat panel,
with per-channel settings for gagging from main output, sound, and desktop
notification. Modeled directly on the existing Discworld Chat plugin's
architecture (`/home/john/src/mallardx-discworld-chat`), scoped down to
NukeFire's needs.

More channels (shout, holler, grats) can be added later the same way, once
their exact line shapes are confirmed in-game.

### Addendum: group channel (added after v1)

v1 shipped with tell/auction/gossip only. Group was added once its line
shapes were confirmed in a real session (`group new`, another player
joining and chatting) — see the group rows and notes in Line classification
below. Unlike tell/auction/gossip, group required no new mechanism, only a
new classifier pattern-and-catch-all pair.

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

Fixed, not dynamic: **All**, **Tell**, **Auction**, **Gossip**, **Group**.
Unlike Discworld's channel set, NukeFire's tell/auction/gossip/group are not
user-joinable/discoverable in the way Discworld's arbitrary channels are —
there's no need for Discworld's pin-a-channel/"Channels" catch-all
machinery. Each is a first-class tab from the start. Group is appended last
(added after the original 4-tab v1), so tab order is
All/Tell/Auction/Gossip/Group.

Ctrl+Shift+1..5 jump to All/Tell/Auction/Gossip/Group respectively, gated by
a `tab_keybindings` setting (default on) — same pattern as Discworld's
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
| gossip | outgoing | `You gossip, 'Good thanks!'` | `^You gossip, '` |
| gossip | incoming | `an Azer guard gossips, 'I saw a room tear...'` | `^[A-Za-z][\w' -]*? gossips, '` |
| group | outgoing | `You group-say, 'hi'` | `^You group%-say, '` (Lua) / `^You group-say, '` (Rust) |
| group | incoming (catch-all) | `[Group] Mallard says, 'hi'` | `^%[Group%] ` (Lua) / `^\[Group\] ` (Rust) |

`classify(line)` returns `{ tab, incoming }` or `nil`. `incoming = false`
only for the outgoing-tell, outgoing-group, and outgoing-gossip shapes —
chime/notify never fire for the player's own traffic, matching Discworld's
rule that a user doesn't get chimed for their own messages.

**Correction (post-v1):** gossip was originally assumed always-incoming — no
player-authored broadcast form had been observed. A later session log showed
NukeFire does echo the player's own gossip, as `You gossip, 'msg'` (singular
verb, distinct from the incoming `<speaker> gossips, '...'` shape). Without a
matching pattern, outgoing gossip fell through `classify` entirely and was
never captured — not misfiled, just silently dropped from history and the
panel. Fixed by adding `is_outgoing_gossip` (`^You gossip, '`) and a matching
`mud.trigger` in `main.lua`. Auction's always-incoming assumption still
holds — no player-authored auction broadcast has been observed.

Note: gossip speakers are not always capitalized (`"an Azer guard"`, `"a
plague corpse"` — NPC-flavored gossip messages), so the leading-name pattern
must accept any case, unlike Discworld's incoming-tell pattern which
requires a capitalized first name.

Auction speaker is always `"the Auctioneer"` in observed data, but the
pattern is kept general (any name + `" auctions, '"`) rather than hardcoded,
in case players can also broadcast to the channel.

**Group is a catch-all on the `[Group] ` tag, not an enumerated set of
verbs.** Unlike Discworld, where each group has its own dynamic bracket name
(`[Sailors]`, `[PartyBoat!]`, ...) that has to be tracked as it's
created/renamed, NukeFire always tags group output with the literal string
`"[Group]"` regardless of the group's actual name (confirmed: `group new`
produced `"[Group] Dilbo becomes leader of the group."`, not
`"[Dilbo] ..."`). That means there's no group-name state to track at all —
any line starting with `[Group] ` unambiguously belongs to the group tab.
Four shapes have been observed (`says,`, `joins the group.`, `has left the
group.`, `becomes leader of the group.`), but the classifier doesn't
enumerate them — it matches the tag prefix generically, so an unseen future
shape (e.g. a decline-invitation message) is captured automatically without
a code change. Per-request, membership/meta lines count as `incoming = true`
same as chat — a join/leave will chime/notify same as an incoming "says" if
the user has that turned on for Group, no special-casing between the two.

Confirmed (session log, `group new` → another player joining and chatting):
no duplicate self-echo — the outgoing `You group-say, '...'` line is never
also mirrored as a `[Group] <you> says, '...'` line, so there's no
self-name-detection problem here the way Discworld needs GMCP `Char.Info`
to solve for its own channel echoes.

## Routing & gagging (`src/main.lua`)

Same `route_line` shape as Discworld: each `mud.trigger` registration
(tell×2, auction, gossip, group×2) calls `classifier.classify`, then:

- Looks up that channel's cached settings (`gag_main`, `sound`, `notify`).
- Posts `{tab, channel, text, ts}` to the panel and appends to the
  scrollback ring buffer.
- Chimes/notifies only when `incoming = true` and the relevant setting is
  on, sharing Discworld's 2s leading-edge debounce so a burst (e.g. several
  rapid auctioneer lines, or several group-join messages) doesn't spam
  sound/notifications.
- Returns whether to gag; the trigger calls `m:gag()` if so.

No channel-registry/pin bookkeeping, no self-name GMCP lookup — Discworld
machinery that doesn't apply here (see the group catch-all note above for
why NukeFire needs no group-name tracking either, unlike Discworld's dynamic
per-group bracket names).

## Storage

- `chat_history_v1` — 500-entry scrollback ring buffer, replayed to the
  panel iframe on `ready`. Debounced flush (write every 50 new lines or 30s,
  whichever first; forced flush on disconnect/reload) via `flush_gate.lua`,
  ported unchanged from Discworld Chat.
- `channel_settings_v1` — `{ tell = {...}, auction = {...}, gossip = {...},
  group = {...} }`, each `{ gag_main, sound, notify }`, all defaulting to
  `false`. Written
  eagerly on user change (settings toggles are rare and user-initiated, so
  no debounce needed — same reasoning Discworld applies to its channel
  registry's structural changes).
- `active_tab_v1` — last-viewed tab, restored on panel mount.

## UI

Ports Discworld Chat's panel shell (`ui/chat.html`, `chat.css`, `chat.js`,
`tab_index.js`) with:

- `FIXED_TABS` is `["all", "tell", "auction", "gossip", "group"]`, no pinned
  tabs, no "Channels" catch-all tab.
- Settings view lists the 4 channels, each with `gag_main`/`sound`/`notify`
  checkboxes — Discworld's "Sources" section generalized to 4 sources
  instead of 2 (tells/group), and no separate "Channels" add/list UI since
  there's no dynamic channel registry.
- URL autolinking, line rendering, theming: ported unchanged.

## Manifest (`plugin.toml`)

```toml
id = "se.broaty.nukefire-chat"
name = "NukeFire Chat"
version = "0.1.0"
description = "A tabbed chat panel for capturing tells, auction, gossip, and group chat on NukeFire."
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
# Ctrl+Shift+1..5 -> All/Tell/Auction/Gossip/Group

[settings.tab_keybindings]
type    = "bool"
default = true
```

`id`/`authors`/world-match/`minimum_app_version` pattern match the sibling
`se.broaty.nukefire-misc` plugin already installed for this MUD
(`/home/john/dev/mallardx-nukefire-misc`). No `gmcp_access` or `sends`
permission needed.

## Testing

- `tests/classifier_test.lua` — the patterns above against real example
  lines pulled from the session log (both positive matches and near-miss
  negatives, e.g. a gossip-shaped line that shouldn't match auction, or a
  `[17 Ass] ...` who-list row that shouldn't match the `[Group]` catch-all).
- `tests/flush_gate_test.lua` — ported unchanged from Discworld Chat (pure
  logic, no host dependency).
- `tests/tab_index_test.js` — `tabIdForIndex` against the fixed 5-tab order.

## Known limitations (v1)

- Only tell/auction/gossip/group are captured; other channels (shout,
  holler, grats) are not yet classified and will pass through unmodified.
  As of this writing, none of shout/holler/grats have been observed firing
  in a real session, so their line shapes are still unconfirmed.
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
