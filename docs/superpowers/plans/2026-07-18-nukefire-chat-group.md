# NukeFire Chat — Group Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 5th fixed tab (Group) to the already-shipped NukeFire Chat plugin, capturing group chat and membership events with the same gag/sound/notify settings as the other channels.

**Architecture:** Extends the existing classifier/main.lua/chat.js/plugin.toml — no new files, no new mechanism. `src/classifier.lua` gains two new patterns (outgoing `You group-say, '...'` and a catch-all on the literal `[Group] ` tag). Everywhere else, `"group"` is just one more entry in the existing `CHANNEL_KEYS`/`TAB_LABELS`/`FIXED_TABS` constants, so the generic loops already in `main.lua` (settings init, settings-update handling) pick it up automatically.

**Tech Stack:** Same as the base plugin — Lua tested with `luajit`, JS tested with `node`, TOML validated with `python3 -c "import tomllib"`.

## Global Constraints

- Channel key is exactly `group` (lowercase), consistent with the existing `tell`/`auction`/`gossip` spelling convention.
- NukeFire always tags group output with the literal string `"[Group]"` regardless of the group's actual name (confirmed: `group new` produced `"[Group] Dilbo becomes leader of the group."`) — there is no dynamic group-name tracking to add, unlike Discworld's plugin. Do not introduce any group-name state.
- The incoming-group classifier is a catch-all on the `[Group] ` prefix, not an enumerated list of verb shapes — this is a deliberate design choice (see design doc's "Line classification" section) so an unseen future shape is captured without a code change. Do not narrow it to only the 4 observed shapes.
- Per the approved design: membership/meta lines (`joins the group.`, `has left the group.`, `becomes leader of the group.`) count as `incoming = true`, same as chat — they should chime/notify exactly like an incoming "says" line if the user has that setting on. No special-casing between chat and meta lines.
- Confirmed: no duplicate self-echo — the outgoing `You group-say, '...'` line is never also mirrored as a `[Group] <you> says, '...'` line. No self-name detection needed.
- Design doc: `docs/superpowers/specs/2026-07-18-nukefire-chat-design.md` (see the "Addendum: group channel" section and the updated "Line classification" section).
- Base plugin plan (for file locations and existing conventions): `docs/superpowers/plans/2026-07-18-nukefire-chat.md`.

---

### Task 1: `classifier.lua` — group patterns

**Files:**
- Modify: `src/classifier.lua`
- Modify: `tests/classifier_test.lua` (add cases; do not remove or alter existing tell/auction/gossip cases)

**Interfaces:**
- Consumes: nothing new — same pure-Lua module, no host API.
- Produces: `classifier.classify(line)` now also returns `{tab = "group", incoming = boolean}` for group lines, in addition to its existing `tell`/`auction`/`gossip`/`nil` returns. Task 2 (`main.lua`) relies on this.

- [ ] **Step 1: Write the failing tests**

Add these cases to `tests/classifier_test.lua`, inserting them after the existing gossip cases and before the "Non-events" section (do not touch any existing `check(...)` call):

```lua
-- Group
check("group: outgoing",
  classifier.classify("You group-say, 'hi'"),
  { tab = "group", incoming = false })

check("group: outgoing with url",
  classifier.classify("You group-say, 'Im actually running a new client called Mallard. https://mallard.vnsf.xyz/'"),
  { tab = "group", incoming = false })

check("group: incoming says",
  classifier.classify("[Group] Mallard says, 'hi'"),
  { tab = "group", incoming = true })

check("group: leader event",
  classifier.classify("[Group] Dilbo becomes leader of the group."),
  { tab = "group", incoming = true })

check("group: join event",
  classifier.classify("[Group] Mallard joins the group."),
  { tab = "group", incoming = true })

check("group: leave event",
  classifier.classify("[Group] Mallard has left the group."),
  { tab = "group", incoming = true })
```

Also add these to the existing "Non-events" section (alongside the other `check(...)` calls there, before the `if failures > 0 then` block):

```lua
check("non-event: similar-but-different bracket tag",
  classifier.classify("[Grouping] fake"), nil)
check("non-event: lowercase group tag",
  classifier.classify("[group] lowercase tag"), nil)
```

- [ ] **Step 2: Run tests to verify the new cases fail**

Run: `luajit tests/classifier_test.lua`
Expected: the 8 new `check(...)` calls print `FAIL` (group returns `nil` since `classifier.lua` doesn't recognize it yet); the pre-existing tell/auction/gossip/non-event cases still print `ok`.

- [ ] **Step 3: Add the group patterns**

In `src/classifier.lua`, add two new local functions. Place them after `is_incoming_tell` and before `match_verb_channel`:

```lua
-- Outgoing group say: "You group-say, 'hi'".
local function is_outgoing_group(line)
  return line:match("^You group%-say, '") ~= nil
end

-- Any [Group]-tagged line: says, joins, leaves, leader changes, and any
-- future shape not yet observed. NukeFire always tags group output with
-- the literal "[Group]", never a dynamic per-group name (unlike
-- Discworld's [Sailors]-style channels), so a prefix catch-all is both
-- correct and future-proof — no group-name state to track.
local function is_group_line(line)
  return line:match("^%[Group%] ") ~= nil
end
```

Then update `M.classify` to call them, inserting the group checks after the tell checks and before the verb-channel check:

```lua
function M.classify(line)
  if type(line) ~= "string" or line == "" then return nil end
  if is_outgoing_tell(line) then
    return { tab = "tell", incoming = false }
  end
  if is_incoming_tell(line) then
    return { tab = "tell", incoming = true }
  end
  if is_outgoing_group(line) then
    return { tab = "group", incoming = false }
  end
  if is_group_line(line) then
    return { tab = "group", incoming = true }
  end
  local verb_tab = match_verb_channel(line)
  if verb_tab then
    return { tab = verb_tab, incoming = true }
  end
  return nil
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `luajit tests/classifier_test.lua`
Expected: every case prints `ok`, including all pre-existing tell/auction/gossip/non-event cases (16 original + 8 new = 24 total), ending with `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add src/classifier.lua tests/classifier_test.lua
git commit -m "Add group channel classification (chat + membership events)"
```

---

### Task 2: Wire group into `main.lua`, `plugin.toml`, and `ui/chat.js`

**Files:**
- Modify: `src/main.lua`
- Modify: `tests/main_smoke_test.lua`
- Modify: `plugin.toml`
- Modify: `ui/chat.js`
- Modify: `tests/tab_index_test.js`

**Interfaces:**
- Consumes: `classifier.classify(line)` now returning `{tab="group", incoming}` (Task 1).
- Produces: `panel:post("settings", {sources, active_tab})` where `sources.group = {gag_main, sound, notify}` — same shape as the other 3 channels, just one more key. `ui/chat.js`'s `FIXED_TABS`/`TAB_LABELS` grow to 5 entries; `computeTabOrder()` needs no other change since it already just returns `FIXED_TABS`.

- [ ] **Step 1: Write the failing smoke-test assertions**

In `tests/main_smoke_test.lua`, change the two count assertions (there were 4 triggers/4 commands before group; adding group's 2 triggers and 1 keybinding command brings this to 6/5):

```lua
check("registers 6 triggers",              #calls.triggers, 6)
check("registers 5 tab commands",          #calls.commands, 5)
```

(These replace the existing `check("registers 4 triggers", ...)` and `check("registers 4 tab commands", ...)` lines — do not leave both old and new checks in the file.)

- [ ] **Step 2: Run the smoke test to verify it fails**

Run: `luajit tests/main_smoke_test.lua`
Expected: `FAIL registers 6 triggers — got 4, want 6` and `FAIL registers 5 tab commands — got 4, want 5` (main.lua doesn't wire group yet).

- [ ] **Step 3: Update `src/main.lua`**

Change the `CHANNEL_KEYS`/`TAB_LABELS` declarations (near the top of the file) from:

```lua
local CHANNEL_KEYS = { "tell", "auction", "gossip" }
local TAB_LABELS   = { tell = "Tell", auction = "Auction", gossip = "Gossip" }
```

to:

```lua
local CHANNEL_KEYS = { "tell", "auction", "gossip", "group" }
local TAB_LABELS   = { tell = "Tell", auction = "Auction", gossip = "Gossip", group = "Group" }
```

Change the tab-keybinding registration loop from:

```lua
for i = 1, 4 do
```

to:

```lua
for i = 1, 5 do
```

Add two new trigger registrations at the end of the existing trigger-registration block (after the gossip trigger, before the "Debounced flush + disconnect flush" section):

```lua
-- Outgoing group say: "You group-say, 'hi'"
mud.trigger([==[^You group-say, ']==], function(m)
  if route_line(m.text) then m:gag() end
end)

-- Any [Group]-tagged line: says/joins/leaves/leader-change/etc.
mud.trigger([==[^\[Group\] ]==], function(m)
  if route_line(m.text) then m:gag() end
end)
```

No other changes to `main.lua` — `init_sources()` and the `settings_update` handler both already loop over `CHANNEL_KEYS` generically, so they pick up `"group"` automatically.

- [ ] **Step 4: Run the smoke test to verify it passes**

Run: `luajit tests/main_smoke_test.lua`
Expected:
```
ok   registers 6 triggers
ok   registers 5 tab commands
ok   registers ready handler
ok   registers settings_update handler
ok   registers active_tab handler
ok   schedules flush timer
ok   registers disconnect flush

all main.lua smoke tests passed
```

- [ ] **Step 5: Update `plugin.toml`**

Change the `description` field from:

```toml
description = "A tabbed chat panel for capturing tells, auction, and gossip on NukeFire."
```

to:

```toml
description = "A tabbed chat panel for capturing tells, auction, gossip, and group chat on NukeFire."
```

Add a 5th keymap binding, after the existing `Ctrl+Shift+4` binding:

```toml
[[keymaps.bindings]]
combo   = "Ctrl+Shift+5"
command = "chat_tab_5"
label   = "Chat: go to tab 5 (Group)"
```

Update the `tab_keybindings` setting's `description` field from:

```toml
description = "When on, Ctrl+Shift+1..4 jump to the 1st-4th chat tab. Edit the combos in Settings → Keymaps (layer 'chat-tab-nav'). Turn off to leave your keymap untouched."
```

to:

```toml
description = "When on, Ctrl+Shift+1..5 jump to the 1st-5th chat tab. Edit the combos in Settings → Keymaps (layer 'chat-tab-nav'). Turn off to leave your keymap untouched."
```

- [ ] **Step 6: Validate the TOML**

Run: `python3 -c "import tomllib; tomllib.load(open('plugin.toml', 'rb')); print('plugin.toml: valid TOML')"`
Expected: `plugin.toml: valid TOML`

- [ ] **Step 7: Update the tab_index test's fixed order**

`ui/tab_index.js` itself needs no change — `tabIdForIndex` is order-agnostic, it just indexes whatever array it's given. Only the test's `order` array needs the 5th entry, so there's no red/green cycle here (nothing in production code to make it fail first). Replace the body of `tests/tab_index_test.js` (everything between the `require` line and the final pass/fail block) so the fixed order includes `"group"`:

```js
const { tabIdForIndex } = require("../ui/tab_index.js");

let failures = 0;
function check(label, got, want) {
  if (got === want) {
    console.log("ok   " + label);
  } else {
    failures++;
    console.log("FAIL " + label + " — got " + String(got) + ", want " + String(want));
  }
}

const order = ["all", "tell", "auction", "gossip", "group"];
check("index 1 -> all",              tabIdForIndex(order, 1), "all");
check("index 2 -> tell",             tabIdForIndex(order, 2), "tell");
check("index 3 -> auction",          tabIdForIndex(order, 3), "auction");
check("index 4 -> gossip",           tabIdForIndex(order, 4), "gossip");
check("index 5 (last) -> group",     tabIdForIndex(order, 5), "group");
check("last via order.length",       tabIdForIndex(order, order.length), "group");
check("index 6 (past end) -> undef", tabIdForIndex(order, 6), undefined);
check("index 0 -> undef",            tabIdForIndex(order, 0), undefined);
check("non-number -> undef",         tabIdForIndex(order, undefined), undefined);
check("non-array -> undef",          tabIdForIndex(null, 1), undefined);

if (failures > 0) {
  console.log("\n" + failures + " failure(s)");
  process.exit(1);
}
console.log("\nall passed");
```

- [ ] **Step 8: Run the test to confirm the new 5-element order resolves correctly**

Run: `node tests/tab_index_test.js`
Expected: all 10 cases pass (same expected output as Step 10 below) — this locks in the 5-tab order before `chat.js` is updated to actually use it in Step 9.

- [ ] **Step 9: Update `ui/chat.js`**

Change:

```js
const FIXED_TABS = ["all", "tell", "auction", "gossip"];
const TAB_LABELS = { all: "All", tell: "Tell", auction: "Auction", gossip: "Gossip" };
```

to:

```js
const FIXED_TABS = ["all", "tell", "auction", "gossip", "group"];
const TAB_LABELS = { all: "All", tell: "Tell", auction: "Auction", gossip: "Gossip", group: "Group" };
```

Change the `renderSettings()` function from:

```js
function renderSettings() {
  sourcesEl.replaceChildren();
  sourcesEl.appendChild(renderSourceRow("Tell", "tell"));
  sourcesEl.appendChild(renderSourceRow("Auction", "auction"));
  sourcesEl.appendChild(renderSourceRow("Gossip", "gossip"));
}
```

to:

```js
function renderSettings() {
  sourcesEl.replaceChildren();
  sourcesEl.appendChild(renderSourceRow("Tell", "tell"));
  sourcesEl.appendChild(renderSourceRow("Auction", "auction"));
  sourcesEl.appendChild(renderSourceRow("Gossip", "gossip"));
  sourcesEl.appendChild(renderSourceRow("Group", "group"));
}
```

No other changes to `chat.js` — `computeTabOrder()` already just returns `FIXED_TABS`, `renderSourceRow` is already generic over its `(label, key)` arguments, and `settings.sources` is populated wholesale from the Lua-side broadcast, so a `group` key just flows through.

- [ ] **Step 10: Syntax-check and re-run the JS tests**

Run: `node --check ui/chat.js`
Expected: no output, exit code 0.

Run: `node tests/tab_index_test.js`
Expected:
```
ok   index 1 -> all
ok   index 2 -> tell
ok   index 3 -> auction
ok   index 4 -> gossip
ok   index 5 (last) -> group
ok   last via order.length
ok   index 6 (past end) -> undef
ok   index 0 -> undef
ok   non-number -> undef
ok   non-array -> undef

all passed
```

- [ ] **Step 11: Re-run the full local test suite to confirm nothing regressed**

Run: `luajit tests/classifier_test.lua && luajit tests/flush_gate_test.lua && luajit tests/main_smoke_test.lua && node tests/tab_index_test.js && node --check ui/chat.js`
Expected: every suite prints its own "all ... passed"/clean output, no `FAIL` anywhere.

- [ ] **Step 12: Commit**

```bash
git add src/main.lua tests/main_smoke_test.lua plugin.toml ui/chat.js tests/tab_index_test.js
git commit -m "Wire group channel: main.lua triggers, plugin.toml keybinding, chat.js tab/settings"
```

---

### Task 3: Manual end-to-end verification in Mallard

**Files:** none (verification only)

- [ ] **Step 1: Reload plugins in Mallard**

Command palette → **Open Plugins…** → **Reload plugins**. (The plugin is already symlinked into `plugins-dev/` from the base build — no new symlink needed.)

- [ ] **Step 2: Confirm the 5th tab appears**

Chat panel now shows 5 tabs: All, Tell, Auction, Gossip, Group, plus the gear icon.

- [ ] **Step 3: Exercise group chat**

Join or form a group (`group new`, or join one) and have group members talk. Confirm both outgoing (`group-say`/`gs`) and incoming group chat land in **All** and **Group** with a `[Group]` tag.

- [ ] **Step 4: Exercise membership events**

Have someone join or leave the group (or trigger a leader change). Confirm these land in **Group** and **All** too, not just actual chat lines.

- [ ] **Step 5: Exercise settings**

Gear icon → confirm a 4th settings row for Group with gag/sound/notify checkboxes, working the same way as Tell/Auction/Gossip (toggle gag, confirm group lines disappear from main output but still show in Group and All).

- [ ] **Step 6: Exercise the new keybinding**

Ctrl+Shift+5 jumps to the Group tab. Ctrl+Shift+1..4 still work for the original 4 tabs.

- [ ] **Step 7: Exercise persistence**

Reload the plugin (or restart Mallard) and confirm Group's scrollback and settings are restored, same as the other channels.

---

## Self-Review Notes

- **Spec coverage:** every part of the design doc's group addendum maps to a task — classification (Task 1), routing/settings/keybinding/UI wiring (Task 2), manual verification (Task 3).
- **Placeholder scan:** no TBD/TODO markers; every step has complete, runnable code or an exact command with expected output, pre-verified in a scratch copy before this plan was written (classifier patterns, updated smoke-test counts, and the 5-tab order all ran successfully with `luajit`/`node` before committing to this plan).
- **Type/name consistency:** `"group"` as a channel key matches across `classifier.lua` (Task 1), `main.lua`'s `CHANNEL_KEYS`/`TAB_LABELS` (Task 2), `chat.js`'s `FIXED_TABS`/`TAB_LABELS`/`renderSettings()` (Task 2), and `plugin.toml`'s keymap label (Task 2). Trigger count (6) and command count (5) asserted in the smoke test match exactly what Task 2's `main.lua` edit registers.
