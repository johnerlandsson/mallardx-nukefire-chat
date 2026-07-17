# NukeFire Chat

A Mallard plugin for the MUD [NukeFire](https://www.nukefire.org)
(`tdome.nukefire.org`). Captures tells, auction announcements, and gossip
into a tabbed chat panel, separate from the main output.

The panel is configurable via the gear icon on the right side, where you
can control per-channel settings:

- whether or not to gag the channel from the main output
- whether or not to play a notification sound
- whether or not to show a desktop (OS) notification

Currently supported channels: **tell**, **auction**, **gossip**. More will
be added as they come up in play.

## Credit

Architecture and UI ported from Discworld Chat, a sibling plugin for the
Discworld MUD, scoped down to NukeFire's fixed (non-dynamic) channel set.

## Design

See `docs/superpowers/specs/2026-07-18-nukefire-chat-design.md` for the full
design writeup, including why GMCP `Comm.Channel` and server-side channel
toggles were considered and rejected in favor of plain-text triggers and
client-side gag/sound/notify checkboxes.

## Install (dev)

Symlink this directory into Mallard's `plugins-dev/` folder, named after the
plugin id:

```sh
ln -s /home/john/dev/mallardx-nukefire-chat <mallard_app_data_dir>/plugins-dev/se.broaty.nukefire-chat
```

Then in Mallard: command palette → **Open Plugins…** → **Reload plugins**.
