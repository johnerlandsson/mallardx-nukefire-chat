# NukeFire Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Mallard chat plugin for NukeFire that captures tell/auction/gossip into a tabbed panel with per-channel gag/sound/notify settings, matching Discworld Chat's architecture scoped to a fixed 3-channel set.

**Architecture:** Pure-Lua `src/classifier.lua` (line-shape → `{tab, incoming}`, unit-testable with no host APIs) feeds `src/main.lua`, which wires `mud.trigger` registrations, panel messaging (`mud.panel("chat")`), debounced scrollback persistence (`src/flush_gate.lua`, ported unchanged), and keymap-gated tab navigation. `ui/chat.html`/`chat.css`/`chat.js`/`tab_index.js` are Discworld Chat's panel shell ported with the dynamic pin/catch-all machinery removed in favor of 4 fixed tabs (All/Tell/Auction/Gossip).

**Tech Stack:** Lua (Mallard plugin sandbox, tested locally with `luajit`), vanilla JS/HTML/CSS panel (tested with `node`), TOML manifest.

## Global Constraints

- Plugin id: `se.broaty.nukefire-chat` (matches sibling `se.broaty.nukefire-misc` plugin's id namespace).
- World match: `tdome.nukefire.org:*` (from `/home/john/Downloads/nukefire.mallardworld` and the sibling plugin).
- `minimum_app_version = "0.10.0"` (keymap API floor, matches Discworld Chat).
- No `gmcp_access` or `sends` permission — plain-text triggers and client-side settings only (see design doc rationale). Only `permissions.notifications = true` is needed.
- Channel keys throughout code are exactly `tell`, `auction`, `gossip` (lowercase) — this exact spelling is relied on by storage keys, the settings-update message shape, and the JS `TAB_LABELS`/`FIXED_TABS` constants. Do not rename any of these three strings in one file without updating all others.
- Design doc: `docs/superpowers/specs/2026-07-18-nukefire-chat-design.md` — consult it for the *why* behind any decision below.
- Reference implementation: `/home/john/src/mallardx-discworld-chat` — consult for the original (dynamic, 2-source) version of any file being ported here.

---

### Task 1: Port `flush_gate.lua`

Pure debounce-gate logic, unchanged from Discworld Chat — decides whether a debounced storage write should fire on a given tick. No NukeFire-specific behavior; this is a straight port.

**Files:**
- Create: `src/flush_gate.lua`
- Test: `tests/flush_gate_test.lua`

**Interfaces:**
- Produces: `flush_gate.write_due(o)` where `o = {dirty, force, pending, elapsed_s, line_budget, max_age_s}` (all required except `force` which defaults false via the caller), returns `boolean`. Task 5 (`main.lua`) calls this for scrollback flush decisions.

- [ ] **Step 1: Write the failing test**

Create `tests/flush_gate_test.lua`:

```lua
-- Pure-Lua tests for flush_gate.write_due.
--
-- Run with: luajit tests/flush_gate_test.lua
--
-- flush_gate.lua has no host-API dependencies, so a vanilla Lua interpreter
-- is enough (same pattern as classifier_test.lua).

package.path = "src/?.lua;" .. package.path
local flush_gate = require("flush_gate")

local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("FAIL: %s — got %s, want %s", label, tostring(got), tostring(want)))
  else
    print("ok: " .. label)
  end
end

local function opts(o)
  return {
    dirty       = o.dirty,
    force       = o.force or false,
    pending     = o.pending or 0,
    elapsed_s   = o.elapsed_s or 0,
    line_budget = o.line_budget or 50,
    max_age_s   = o.max_age_s or 30,
  }
end

-- Clean state: nothing queued → never writes.
check("not dirty never writes", flush_gate.write_due(opts({ dirty = false, force = true, pending = 999, elapsed_s = 999 })), false)

-- Dirty but under both thresholds → coalesce (skip this tick).
check("dirty under thresholds waits", flush_gate.write_due(opts({ dirty = true, pending = 1, elapsed_s = 5 })), false)

-- Force always writes when dirty (disconnect / reload).
check("force writes when dirty", flush_gate.write_due(opts({ dirty = true, force = true, pending = 0, elapsed_s = 0 })), true)
-- ...but force on a clean buffer still writes nothing.
check("force on clean writes nothing", flush_gate.write_due(opts({ dirty = false, force = true })), false)

-- Line budget reached → write.
check("line budget triggers", flush_gate.write_due(opts({ dirty = true, pending = 50, elapsed_s = 1 })), true)
check("just under line budget waits", flush_gate.write_due(opts({ dirty = true, pending = 49, elapsed_s = 1 })), false)

-- Max age reached → write even with few lines.
check("max age triggers", flush_gate.write_due(opts({ dirty = true, pending = 1, elapsed_s = 30 })), true)
check("just under max age waits", flush_gate.write_due(opts({ dirty = true, pending = 1, elapsed_s = 29 })), false)

if failures == 0 then
  print("all flush_gate tests passed")
else
  print(failures .. " failure(s)")
  os.exit(1)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit tests/flush_gate_test.lua`
Expected: error such as `module 'flush_gate' not found` (src/flush_gate.lua doesn't exist yet).

- [ ] **Step 3: Write the module**

Create `src/flush_gate.lua`:

```lua
-- Decide whether a debounced full-blob storage write should fire on a tick.
--
-- Both blobs this guards — the scrollback ring and (in principle) any other
-- coalesced blob — are persisted as single storage blobs. Rewriting a whole
-- blob on every tick that touched it is O(blob) work to save O(1) new
-- changes: cheap per write, but it recurs every few seconds for the life of
-- the session and occasionally stalls tens of ms on a SQLite checkpoint.
-- Coalescing cuts the number of full-blob writes without changing what ends
-- up persisted.
--
-- Pure (no host-API dependencies) so it unit-tests under a vanilla `lua`,
-- same pattern as classifier.lua.

local M = {}

-- Returns true when the blob should be written now.
--   o.dirty       — are there unwritten changes?
--   o.force       — bypass coalescing (disconnect / plugin reload): never lose data
--   o.pending     — new entries queued since the last write
--   o.elapsed_s   — seconds since the last write
--   o.line_budget — write once this many entries have queued
--   o.max_age_s   — ...or once the oldest unwritten change is this old
function M.write_due(o)
  if not o.dirty then return false end
  if o.force then return true end
  if o.pending >= o.line_budget then return true end
  if o.elapsed_s >= o.max_age_s then return true end
  return false
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `luajit tests/flush_gate_test.lua`
Expected:
```
ok: not dirty never writes
ok: dirty under thresholds waits
ok: force writes when dirty
ok: force on clean writes nothing
ok: line budget triggers
ok: just under line budget waits
ok: max age triggers
ok: just under max age waits
all flush_gate tests passed
```

- [ ] **Step 5: Commit**

```bash
git add src/flush_gate.lua tests/flush_gate_test.lua
git commit -m "Port flush_gate debounce logic from Discworld Chat"
```

---

### Task 2: Port `tab_index.js`

Pure helper mapping a 1-based tab-strip position to a tab id, used by both the keymap-driven `goto_index` panel message and its own test. No NukeFire-specific behavior; straight port. The test is rewritten for NukeFire's fixed 4-tab order (Discworld's version tests a dynamic pinned-channel order that doesn't apply here).

**Files:**
- Create: `ui/tab_index.js`
- Test: `tests/tab_index_test.js`

**Interfaces:**
- Produces: `tabIdForIndex(order, index)` where `order` is a string array and `index` is 1-based, returns the tab id string or `undefined`. Task 6 (`ui/chat.js`) calls this from its `panel.on("goto_index", ...)` handler with `order = FIXED_TABS`.

- [ ] **Step 1: Write the failing test**

Create `tests/tab_index_test.js`:

```js
// Pure tests for tabIdForIndex. Run with: node tests/tab_index_test.js
// tab_index.js has no DOM/host dependencies, so plain node is enough.
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

const order = ["all", "tell", "auction", "gossip"];
check("index 1 -> all",              tabIdForIndex(order, 1), "all");
check("index 2 -> tell",             tabIdForIndex(order, 2), "tell");
check("index 3 -> auction",          tabIdForIndex(order, 3), "auction");
check("index 4 (last) -> gossip",    tabIdForIndex(order, 4), "gossip");
check("last via order.length",       tabIdForIndex(order, order.length), "gossip");
check("index 5 (past end) -> undef", tabIdForIndex(order, 5), undefined);
check("index 0 -> undef",            tabIdForIndex(order, 0), undefined);
check("non-number -> undef",         tabIdForIndex(order, undefined), undefined);
check("non-array -> undef",          tabIdForIndex(null, 1), undefined);

if (failures > 0) {
  console.log("\n" + failures + " failure(s)");
  process.exit(1);
}
console.log("\nall passed");
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node tests/tab_index_test.js`
Expected: `Error: Cannot find module '../ui/tab_index.js'`

- [ ] **Step 3: Write the module**

Create `ui/tab_index.js`:

```js
// Pure helper: map a 1-based strip position to a tab id.
// Shared by chat.js (loaded as a browser global) and tests (node require).
// The strip order is `["all", "tell", "auction", "gossip"]` — callers pass
// FIXED_TABS from chat.js.
function tabIdForIndex(order, index) {
  if (!Array.isArray(order)) return undefined;
  if (typeof index !== "number" || index < 1 || index > order.length) {
    return undefined;
  }
  return order[index - 1];
}

// Dual export: in the browser `module` is undefined and `tabIdForIndex`
// stays a global; under node the test can require() it.
if (typeof module !== "undefined" && module.exports) {
  module.exports = { tabIdForIndex };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node tests/tab_index_test.js`
Expected:
```
ok   index 1 -> all
ok   index 2 -> tell
ok   index 3 -> auction
ok   index 4 (last) -> gossip
ok   last via order.length
ok   index 5 (past end) -> undef
ok   index 0 -> undef
ok   non-number -> undef
ok   non-array -> undef

all passed
```

- [ ] **Step 5: Commit**

```bash
git add ui/tab_index.js tests/tab_index_test.js
git commit -m "Port tab_index helper from Discworld Chat, fixed 4-tab order"
```

---

### Task 3: `classifier.lua` — line classification

Pure-Lua classification of NukeFire chat lines into `{tab, incoming}`. This is the one genuinely new piece of parsing logic (Discworld's classifier handles different line shapes entirely). Patterns and examples are drawn from the real session log referenced in the design doc.

**Files:**
- Create: `src/classifier.lua`
- Test: `tests/classifier_test.lua`

**Interfaces:**
- Produces: `classifier.classify(line)` — `line` is a string, returns `{tab = "tell"|"auction"|"gossip", incoming = boolean}` or `nil` if the line isn't a recognized chat line. Task 5 (`main.lua`) calls this from `route_line`.

- [ ] **Step 1: Write the failing test**

Create `tests/classifier_test.lua`:

```lua
-- Pure-Lua tests for classifier.classify.
--
-- Run with: luajit tests/classifier_test.lua
--
-- classifier.lua has no host-API dependencies, so a vanilla Lua
-- interpreter is enough. The patterns are Lua patterns (not Rust regex),
-- so the system interpreter evaluates them identically to the plugin
-- sandbox. Examples are drawn from a real NukeFire session log — see
-- docs/superpowers/specs/2026-07-18-nukefire-chat-design.md.

package.path = "src/?.lua;" .. package.path
local classifier = require("classifier")

local failures = 0
local function check(label, got, want)
  local ok
  if want == nil then
    ok = got == nil
  else
    ok = type(got) == "table" and got.tab == want.tab and got.incoming == want.incoming
  end
  if ok then
    io.write("ok   " .. label .. "\n")
  else
    failures = failures + 1
    local function show(v)
      if type(v) == "table" then
        return string.format("{tab=%q, incoming=%s}", tostring(v.tab), tostring(v.incoming))
      end
      return tostring(v)
    end
    io.write(string.format("FAIL %s\n     got  = %s\n     want = %s\n",
      label, show(got), show(want)))
  end
end

-- Tell
check("outgoing tell",
  classifier.classify("You telepath Anne, 'Hello'"),
  { tab = "tell", incoming = false })

check("outgoing tell: long message with apostrophe",
  classifier.classify("You telepath Anne, 'I just wanted to test the tell command, So I know how to filter the text into it's own chat log.'"),
  { tab = "tell", incoming = false })

check("incoming tell",
  classifier.classify("Anne telepaths to you, 'hah hey'"),
  { tab = "tell", incoming = true })

check("outgoing verb 'tell' is not NukeFire's tell verb",
  classifier.classify("You tell Anne hi"),
  nil)

-- Auction
check("auction: opening bid",
  classifier.classify("the Auctioneer auctions, 'Opening bid: 250,000 credits. Bid with: bid min | bid <amount> | bid max <amount>.'"),
  { tab = "auction", incoming = true })

check("auction: final call",
  classifier.classify("the Auctioneer auctions, 'Final call: Item: a bonegate signet ring.'"),
  { tab = "auction", incoming = true })

-- Gossip
check("gossip: capitalized player-styled name",
  classifier.classify("Doom Herald of the Ashen City gossips, 'Got my hands on Ember Ward Kneeplate before I even realized I killed the corpse of Shai! #PricelessSwag'"),
  { tab = "gossip", incoming = true })

check("gossip: lowercase NPC-styled name ('an ...')",
  classifier.classify("an Azer guard gossips, 'I saw a room tear itself halfway into the world and then pretend that was normal.'"),
  { tab = "gossip", incoming = true })

check("gossip: lowercase NPC-styled name ('a ...')",
  classifier.classify("a plague corpse gossips, 'Lovely. A staircase. I was just thinking my day needed more stairs.'"),
  { tab = "gossip", incoming = true })

-- Non-events: lines that must NOT be classified as chat.
check("non-event: empty string", classifier.classify(""), nil)
check("non-event: nil input", classifier.classify(nil), nil)
check("non-event: toggle confirmation (off)",
  classifier.classify("You are now deaf to gossip."), nil)
check("non-event: toggle confirmation (on)",
  classifier.classify("You can now hear auctions."), nil)
check("non-event: unrelated system line",
  classifier.classify("You have no history in that channel."), nil)
check("non-event: who-list row",
  classifier.classify("[17 Ass] Vect Asdrubael   (nogos) (notell)"), nil)
check("non-event: prompt line",
  classifier.classify("< 938H 234M 446V (news) (motd) [Lvl 17, EXP to next: 268,073] >"), nil)

if failures > 0 then
  io.write(string.format("\n%d test(s) failed\n", failures))
  os.exit(1)
end
io.write("\nall tests passed\n")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit tests/classifier_test.lua`
Expected: error such as `module 'classifier' not found` (src/classifier.lua doesn't exist yet).

- [ ] **Step 3: Write the module**

Create `src/classifier.lua`:

```lua
-- NukeFire Chat line classifier.
--
-- Pure Lua, no host-API dependencies. Patterns confirmed against real
-- session log lines — see
-- docs/superpowers/specs/2026-07-18-nukefire-chat-design.md for examples.
--
-- Verb-channels (auction, gossip, and future ones like shout/holler/grats)
-- all share the shape "<speaker> <verb>, '<message>'" and are always
-- incoming (no player-authored broadcast form observed for these). Add a
-- new entry to VERB_CHANNELS to support another channel once its exact
-- verb is confirmed in-game.

local M = {}

local VERB_CHANNELS = {
  { tab = "auction", verb = "auctions" },
  { tab = "gossip",  verb = "gossips" },
}

-- Outgoing tell: "You telepath Anne, 'Hello'".
local function is_outgoing_tell(line)
  return line:match("^You telepath .-, '") ~= nil
end

-- Incoming tell: "Anne telepaths to you, 'hah hey'".
--
-- Speaker names on NukeFire are player character names (always
-- capitalized in observed data), but the leading-char check accepts any
-- case defensively, same reasoning Discworld Chat applies to family
-- names. The explicit "You " guard mirrors Discworld's defensive check
-- even though the verb shapes ("telepath" vs "telepaths to you") already
-- distinguish direction on their own.
local function is_incoming_tell(line)
  if line:sub(1, 4) == "You " then return false end
  return line:match("^[A-Za-z][%w '%-]- telepaths to you, '") ~= nil
end

-- Verb-channel lines: "the Auctioneer auctions, '...'", "an Azer guard
-- gossips, '...'". Speaker can be lowercase-leading (NPC-flavored gossip
-- messages like "an Azer guard" or "a plague corpse"), so the leading
-- character class accepts any case.
local function match_verb_channel(line)
  for _, c in ipairs(VERB_CHANNELS) do
    if line:match("^[A-Za-z][%w '%-]- " .. c.verb .. ", '") then
      return c.tab
    end
  end
  return nil
end

function M.classify(line)
  if type(line) ~= "string" or line == "" then return nil end
  if is_outgoing_tell(line) then
    return { tab = "tell", incoming = false }
  end
  if is_incoming_tell(line) then
    return { tab = "tell", incoming = true }
  end
  local verb_tab = match_verb_channel(line)
  if verb_tab then
    return { tab = verb_tab, incoming = true }
  end
  return nil
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `luajit tests/classifier_test.lua`
Expected:
```
ok   outgoing tell
ok   outgoing tell: long message with apostrophe
ok   incoming tell
ok   outgoing verb 'tell' is not NukeFire's tell verb
ok   auction: opening bid
ok   auction: final call
ok   gossip: capitalized player-styled name
ok   gossip: lowercase NPC-styled name ('an ...')
ok   gossip: lowercase NPC-styled name ('a ...')
ok   non-event: empty string
ok   non-event: nil input
ok   non-event: toggle confirmation (off)
ok   non-event: toggle confirmation (on)
ok   non-event: unrelated system line
ok   non-event: who-list row
ok   non-event: prompt line

all tests passed
```

- [ ] **Step 5: Commit**

```bash
git add src/classifier.lua tests/classifier_test.lua
git commit -m "Add NukeFire chat line classifier for tell/auction/gossip"
```

---

### Task 4: `plugin.toml` manifest

**Files:**
- Create: `plugin.toml`

**Interfaces:**
- Produces: the `chat` panel declaration (`ui/chat.html`, Task 6), the `chat-tab-nav` keymap layer and `chat_tab_1..4` command names (registered in Task 5's `main.lua`), and the `tab_keybindings` setting (read via `settings.get("tab_keybindings")` in Task 5).

- [ ] **Step 1: Write the manifest**

Create `plugin.toml`:

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

[permissions]
notifications = true

[worlds]
match = ["tdome.nukefire.org:*"]

[panels.chat]
title              = "Chat"
entry              = "ui/chat.html"
default_dock       = "below"
default_dock_after = "output"
default_size       = { width = 800, height = 200 }

[[keymaps]]
name = "chat-tab-nav"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+1"
command = "chat_tab_1"
label   = "Chat: go to tab 1 (All)"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+2"
command = "chat_tab_2"
label   = "Chat: go to tab 2 (Tell)"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+3"
command = "chat_tab_3"
label   = "Chat: go to tab 3 (Auction)"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+4"
command = "chat_tab_4"
label   = "Chat: go to tab 4 (Gossip)"

[settings.tab_keybindings]
type    = "bool"
default = true
label   = "Tab navigation keybindings"
description = "When on, Ctrl+Shift+1..4 jump to the 1st-4th chat tab. Edit the combos in Settings → Keymaps (layer 'chat-tab-nav'). Turn off to leave your keymap untouched."
```

- [ ] **Step 2: Validate TOML syntax**

Run: `python3 -c "import tomllib; tomllib.load(open('plugin.toml', 'rb')); print('plugin.toml: valid TOML')"`
Expected: `plugin.toml: valid TOML`

- [ ] **Step 3: Commit**

```bash
git add plugin.toml
git commit -m "Add NukeFire Chat plugin manifest"
```

---

### Task 5: `main.lua` — wiring

Wires the classifier into `mud.trigger` registrations, manages scrollback/settings storage, and handles panel messaging and tab keybindings. Depends on Tasks 1 and 3 (`flush_gate`, `classifier`) and is consumed by Task 6 (`ui/chat.js`) via the panel message contract below.

**Files:**
- Create: `src/main.lua`
- Test: `tests/main_smoke_test.lua` (new — stubs the Mallard host API surface so the file's top-level wiring can be exercised outside the real app; `main.lua` itself has no automated behavioral test beyond this because it's inseparable from host APIs the sandbox doesn't provide locally)

**Interfaces:**
- Consumes: `classifier.classify(line)` → `{tab, incoming}|nil` (Task 3); `flush_gate.write_due(o)` → `boolean` (Task 1).
- Produces (panel message contract with `ui/chat.js`, Task 6):
  - `panel:post("line", {tab, text, ts})` — one per routed chat line.
  - `panel:post("settings", {sources, active_tab})` where `sources = {tell = {gag_main, sound, notify}, auction = {...}, gossip = {...}}`.
  - `panel:on_message("ready", fn(payload))`, `panel:on_message("settings_update", fn(delta))` where `delta = {source = {<key> = {gag_main?, sound?, notify?}}}`, `panel:on_message("active_tab", fn({tab}))`.
  - `panel:post("goto_index", {index})` on `chat_tab_<1..4>` commands (hidden, keymap-only).

- [ ] **Step 1: Write the failing smoke test**

Create `tests/main_smoke_test.lua`:

```lua
-- Smoke test for main.lua's top-level wiring, run against a stubbed
-- Mallard host API surface (mud/storage/settings/world/ui globals) since
-- there's no real plugin sandbox available outside the app. This doesn't
-- verify behavior — classifier_test.lua and flush_gate_test.lua already
-- cover the logic main.lua delegates to — it verifies main.lua loads
-- without error and registers the triggers/commands/handlers it's
-- supposed to.
--
-- Run with: luajit tests/main_smoke_test.lua

package.path = "src/?.lua;" .. package.path

local calls = {
  triggers = {},
  commands = {},
  panel_messages = {},
  every = nil,
  disconnect = nil,
}

local function handle()
  return { enable = function() end, disable = function() end, remove = function() end }
end

storage = (function()
  local data = {}
  return {
    get = function(k) return data[k] end,
    set = function(k, v) data[k] = v end,
  }
end)()

settings = {
  get = function(k) return true end,
  on = function(evt, fn) end,
}

mud = {
  panel = function(id)
    return {
      on_message = function(self, name, fn) calls.panel_messages[name] = fn end,
      post = function(self, name, data) end,
    }
  end,
  trigger = function(pattern, fn) table.insert(calls.triggers, pattern); return handle() end,
  command = function(name, fn, opts) table.insert(calls.commands, name); return handle() end,
  every = function(ms, fn) calls.every = fn; return handle() end,
  play_sound = function(id) end,
  keymap = { activate = function() end, deactivate = function() end },
}

world = {
  on = function(evt, fn)
    if evt == "disconnect" then calls.disconnect = fn end
    return handle()
  end,
}

ui = { notify = function(title, body) end }

local ok, err = pcall(require, "main")
if not ok then
  print("FAIL: main.lua raised an error on load: " .. tostring(err))
  os.exit(1)
end

local failures = 0
local function check(label, got, want)
  if got == want then
    print("ok   " .. label)
  else
    failures = failures + 1
    print(string.format("FAIL %s — got %s, want %s", label, tostring(got), tostring(want)))
  end
end

check("registers 4 triggers",              #calls.triggers, 4)
check("registers 4 tab commands",          #calls.commands, 4)
check("registers ready handler",           type(calls.panel_messages["ready"]),           "function")
check("registers settings_update handler", type(calls.panel_messages["settings_update"]), "function")
check("registers active_tab handler",      type(calls.panel_messages["active_tab"]),      "function")
check("schedules flush timer",             type(calls.every),      "function")
check("registers disconnect flush",        type(calls.disconnect), "function")

if failures > 0 then
  print("\n" .. failures .. " failure(s)")
  os.exit(1)
end
print("\nall main.lua smoke tests passed")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit tests/main_smoke_test.lua`
Expected: `FAIL: main.lua raised an error on load: ...module 'main' not found...` (src/main.lua doesn't exist yet)

- [ ] **Step 3: Write the module**

Create `src/main.lua`:

```lua
-- NukeFire Chat — captures tell/auction/gossip into a tabbed chat panel.
--
-- Ported from Discworld Chat's architecture, scoped to NukeFire's fixed
-- tell/auction/gossip channels — see
-- docs/superpowers/specs/2026-07-18-nukefire-chat-design.md for the design
-- rationale (plain-text triggers over GMCP, fixed tabs over dynamic
-- pin+catch-all, gag/sound/notify checkboxes over server-side toggles).

local classifier = require("classifier")
local flush_gate = require("flush_gate")

local panel = mud.panel("chat")

local HISTORY_KEY    = "chat_history_v1"
local SOURCES_KEY    = "channel_settings_v1"
local ACTIVE_TAB_KEY = "active_tab_v1"

local CHANNEL_KEYS = { "tell", "auction", "gossip" }
local TAB_LABELS   = { tell = "Tell", auction = "Auction", gossip = "Gossip" }

local HISTORY_MAX         = 500
local PERSIST_DEBOUNCE_MS = 5000
local FLUSH_LINE_BUDGET   = 50
local FLUSH_MAX_AGE_S     = 30
local CHIME_DEBOUNCE_S    = 2

-- ---------------------------------------------------------------------
-- Storage + module-scope caches.
-- ---------------------------------------------------------------------

local function init_sources()
  local s = storage.get(SOURCES_KEY)
  if not s then s = {} end
  for _, key in ipairs(CHANNEL_KEYS) do
    if not s[key] then s[key] = {} end
    if s[key].gag_main == nil then s[key].gag_main = false end
    if s[key].sound    == nil then s[key].sound    = false end
    if s[key].notify   == nil then s[key].notify   = false end
  end
  return s
end

local sources_cache = init_sources()
local history_buf   = storage.get(HISTORY_KEY) or {}

local history_dirty      = false
local history_pending    = 0
local last_history_write = os.time()

-- Debounced scrollback flush; `force` (disconnect / reload) bypasses
-- coalescing so a clean exit never drops scrollback.
local function flush(force)
  local due = flush_gate.write_due({
    dirty       = history_dirty,
    force       = force == true,
    pending     = history_pending,
    elapsed_s   = os.time() - last_history_write,
    line_budget = FLUSH_LINE_BUDGET,
    max_age_s   = FLUSH_MAX_AGE_S,
  })
  if due then
    storage.set(HISTORY_KEY, history_buf)
    history_dirty      = false
    history_pending    = 0
    last_history_write = os.time()
  end
end

-- ---------------------------------------------------------------------
-- Scrollback — 500-entry ring buffer in plugin storage. Replayed when
-- the panel iframe (re-)mounts and posts a "ready" handshake.
-- ---------------------------------------------------------------------

local function persist(entry)
  history_buf[#history_buf + 1] = entry
  while #history_buf > HISTORY_MAX do table.remove(history_buf, 1) end
  history_dirty   = true
  history_pending = history_pending + 1
end

local function replay()
  for _, e in ipairs(history_buf) do
    panel:post("line", e)
  end
end

-- ---------------------------------------------------------------------
-- Settings.
-- ---------------------------------------------------------------------

local function full_settings()
  return {
    sources    = sources_cache,
    active_tab = storage.get(ACTIVE_TAB_KEY),
  }
end

local function broadcast_settings()
  panel:post("settings", full_settings())
end

-- ---------------------------------------------------------------------
-- Handshake + settings updates.
-- ---------------------------------------------------------------------

local last_replay_session = nil
panel:on_message("ready", function(payload)
  local session = type(payload) == "table" and payload.session or nil
  if session == nil or session ~= last_replay_session then
    replay()
    last_replay_session = session
  end
  broadcast_settings()
end)

-- Delta shape: { source = { tell = {gag_main?, sound?, notify?}, auction = {...}, gossip = {...} } }
panel:on_message("settings_update", function(delta)
  if type(delta) ~= "table" or type(delta.source) ~= "table" then return end
  for _, key in ipairs(CHANNEL_KEYS) do
    local upd = delta.source[key]
    if type(upd) == "table" then
      local entry = sources_cache[key]
      if upd.gag_main ~= nil then entry.gag_main = upd.gag_main and true or false end
      if upd.sound    ~= nil then entry.sound    = upd.sound    and true or false end
      if upd.notify   ~= nil then entry.notify   = upd.notify   and true or false end
    end
  end
  -- User-initiated change — flush eagerly rather than waiting on the
  -- debounce, same reasoning Discworld Chat applies to its channel toggles.
  storage.set(SOURCES_KEY, sources_cache)
  broadcast_settings()
end)

panel:on_message("active_tab", function(payload)
  if type(payload) ~= "table" then return end
  if type(payload.tab) == "string" then
    storage.set(ACTIVE_TAB_KEY, payload.tab)
  end
end)

-- ---------------------------------------------------------------------
-- Keyboard tab navigation.
-- ---------------------------------------------------------------------

for i = 1, 4 do
  mud.command("chat_tab_" .. i, function()
    panel:post("goto_index", { index = i })
  end, { hidden = true })
end

local function apply_tab_keymap()
  if settings.get("tab_keybindings") then
    mud.keymap.activate("chat-tab-nav")
  else
    mud.keymap.deactivate("chat-tab-nav")
  end
end

settings.on("change", function(key, new_val)
  if key == "tab_keybindings" then
    apply_tab_keymap()
  end
end)

apply_tab_keymap()

-- ---------------------------------------------------------------------
-- Line dispatch.
-- ---------------------------------------------------------------------

-- Chime/notify debounce: leading-edge throttle, same 2s window shared
-- across all three channels so a burst (e.g. rapid auctioneer lines)
-- doesn't spam sound/notifications.
local last_chime_ts  = 0
local last_notify_ts = 0

-- Returns true if the line should be gagged from the main output pane.
-- Always posts to the panel and persists — gag only affects main output,
-- never whether the plugin captures the line.
local function route_line(line_text)
  local routing = classifier.classify(line_text)
  if not routing then return false end

  local entry = sources_cache[routing.tab]
  local gag = entry.gag_main and true or false

  -- Chime/notify only fire for traffic the user didn't originate
  -- (classifier marks incoming=false only for the outgoing-tell shape).
  if routing.incoming then
    if entry.sound then
      local now = os.time()
      if now - last_chime_ts >= CHIME_DEBOUNCE_S then
        mud.play_sound("mallard:chime-high")
        last_chime_ts = now
      end
    end
    if entry.notify then
      local now = os.time()
      if now - last_notify_ts >= CHIME_DEBOUNCE_S then
        ui.notify(TAB_LABELS[routing.tab], line_text)
        last_notify_ts = now
      end
    end
  end

  local payload = { tab = routing.tab, text = line_text, ts = os.time() }
  panel:post("line", payload)
  persist(payload)

  return gag
end

-- ---------------------------------------------------------------------
-- Trigger registrations.
--
-- Patterns use Rust regex syntax (mud.trigger compiles via the regex
-- crate). Each is a coarse pre-filter; classifier.classify does the
-- actual routing decision from the same line text, so the trigger's only
-- other job is deciding gag via route_line's return value.
-- ---------------------------------------------------------------------

-- Outgoing tell: "You telepath Anne, 'Hello'"
mud.trigger([==[^You telepath .+?, ']==], function(m)
  if route_line(m.text) then m:gag() end
end)

-- Incoming tell: "Anne telepaths to you, 'hah hey'"
mud.trigger([==[^[A-Za-z][\w' -]*? telepaths to you, ']==], function(m)
  if route_line(m.text) then m:gag() end
end)

-- Auction: "the Auctioneer auctions, 'Opening bid: ...'"
mud.trigger([==[^[A-Za-z][\w' -]*? auctions, ']==], function(m)
  if route_line(m.text) then m:gag() end
end)

-- Gossip: "an Azer guard gossips, 'I saw a room tear...'"
mud.trigger([==[^[A-Za-z][\w' -]*? gossips, ']==], function(m)
  if route_line(m.text) then m:gag() end
end)

-- ---------------------------------------------------------------------
-- Debounced flush + disconnect flush.
-- ---------------------------------------------------------------------

mud.every(PERSIST_DEBOUNCE_MS, flush)
world.on("disconnect", function() flush(true) end)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `luajit tests/main_smoke_test.lua`
Expected:
```
ok   registers 4 triggers
ok   registers 4 tab commands
ok   registers ready handler
ok   registers settings_update handler
ok   registers active_tab handler
ok   schedules flush timer
ok   registers disconnect flush

all main.lua smoke tests passed
```

- [ ] **Step 5: Re-run all Lua tests together to confirm nothing regressed**

Run: `luajit tests/classifier_test.lua && luajit tests/flush_gate_test.lua && luajit tests/main_smoke_test.lua`
Expected: all three print their "all ... passed" lines with no `FAIL`.

- [ ] **Step 6: Commit**

```bash
git add src/main.lua tests/main_smoke_test.lua
git commit -m "Add main.lua wiring: triggers, panel messaging, scrollback, keymaps"
```

---

### Task 6: Panel UI (`ui/chat.html`, `ui/chat.css`, `ui/chat.js`)

Discworld Chat's panel shell ported with the dynamic pin/catch-all machinery removed: 4 fixed tabs (all/tell/auction/gossip), settings view lists exactly 3 channel rows (no add-channel input, no channel registry/remove button — those only existed to manage Discworld's dynamically-discovered channels).

**Files:**
- Create: `ui/chat.html`
- Create: `ui/chat.css`
- Create: `ui/chat.js`

**Interfaces:**
- Consumes: `tabIdForIndex(order, index)` (Task 2, loaded as a browser global via `<script src="tab_index.js">`); the panel message contract from Task 5 (`line`, `settings`, `goto_index` incoming; `ready`, `settings_update`, `active_tab` outgoing).
- Produces: no further consumers — this is the leaf UI layer.

- [ ] **Step 1: Write `ui/chat.html`**

Create `ui/chat.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>NukeFire Chat</title>
  <link rel="stylesheet" href="chat.css">
  <script src="tab_index.js" defer></script>
  <script src="chat.js" defer></script>
</head>
<body>
  <nav class="tabs" id="tabs" role="tablist"></nav>
  <main class="scrollback" id="scrollback"></main>
  <section class="settings" id="settings" hidden>
    <h2>Channels</h2>
    <div class="sources" id="sources"></div>
  </section>
  <div class="overflow-popover" id="overflow-popover" hidden></div>
</body>
</html>
```

- [ ] **Step 2: Write `ui/chat.css`**

Create `ui/chat.css`:

```css
/* Token vocabulary tracks Mallard's host theme (see src/themes.css in the
   mallard repo). The host pushes these vars onto :root as inline styles via
   a `set-theme` message on iframe ready and on every theme change; the
   values below are first-paint fallbacks only. Custom token names won't be
   touched by the push — stick to the host vocabulary. */
:root {
  --bg:           #0d0d0d;
  --bg-elevated:  #111111;
  --fg:           #dddddd;
  --fg-muted:     #888888;
  --border:       #2a2a2a;
  --accent:       #4ade80;
  --link:         #66ccff;
}

html, body { margin: 0; padding: 0; height: 100%; background: var(--bg); color: var(--fg); }
body { display: flex; flex-direction: column; overflow: hidden; border: 0; }

[hidden] { display: none !important; }

.tabs {
  display: flex;
  align-items: stretch;
  background: var(--bg-elevated);
  border: 0;
  border-bottom: 1px solid var(--border);
  margin: 0;
  padding: 0;
  flex-shrink: 0;
  overflow: hidden;
}

.tab {
  appearance: none;
  background: transparent;
  border: 0;
  border-right: 1px solid var(--border);
  color: var(--fg-muted);
  cursor: pointer;
  font: inherit;
  margin: 0;
  padding: 6px 9px;
  white-space: nowrap;
  flex-shrink: 0;
  box-sizing: border-box;
  line-height: 18px;
  display: inline-flex;
  align-items: center;
}

.tab.active {
  background: var(--bg);
  color: var(--accent);
}

/* Reserve the dot's slot on every tab so toggling the unread state
   doesn't reflow the tab bar. The slot is transparent until the tab
   gets .has-unread, at which point it fills with the accent color. The
   overflow ••• button gets a reserved slot too so its width is stable
   across has-unread toggles — otherwise collapseOverflow's cutoff math
   would shift when a hidden tab lights up. */
.tab::after {
  content: "";
  display: inline-block;
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: transparent;
  margin-left: 6px;
  vertical-align: middle;
  flex-shrink: 0;
}
.tab.has-unread::after { background: var(--accent); }
.tab.gear::after { display: none; }

.tab.gear,
.tab.overflow {
  padding: 6px 10px;
  justify-content: center;
}
.tab.overflow { margin-left: 0; }
.tab.gear {
  margin-left: auto;
  border-right: 0;
  color: var(--fg-muted);
}
.tab.gear:hover { color: var(--fg); }
.tab.gear.active { color: var(--accent); }
.tab.gear svg {
  display: block;
  width: 18px;
  height: 18px;
}

.scrollback {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 4px 8px;
}

.line {
  white-space: pre-wrap;
  margin: 0;
}

.line .ts  { color: var(--fg-muted); margin-right: 6px; }
.line .tag { color: var(--link);     margin-right: 6px; }

.line a.url {
  color: var(--link);
  text-decoration: underline;
  text-underline-offset: 2px;
  cursor: pointer;
}
.line a.url:hover { filter: brightness(1.15); }

/* --- Settings view --- */

.settings {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 8px 12px;
}

.settings h2 {
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--fg-muted);
  margin: 12px 0 6px;
  font-weight: 600;
}
.settings h2:first-child { margin-top: 0; }

.settings-row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 5px 6px;
  border-bottom: 1px solid var(--border);
}

.settings-name {
  flex: 0 0 auto;
  min-width: 100px;
  color: var(--fg);
}

.settings-toggle {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  color: var(--fg-muted);
  cursor: pointer;
  user-select: none;
}
.settings-toggle input { margin: 0; cursor: pointer; }

/* --- Overflow popover --- */

.overflow-popover {
  position: fixed;
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  display: flex;
  flex-direction: column;
  z-index: 10;
  min-width: 140px;
}

.overflow-popover .tab {
  border-right: 0;
  border-bottom: 1px solid var(--border);
  text-align: left;
}
.overflow-popover .tab:last-child { border-bottom: 0; }
```

- [ ] **Step 3: Write `ui/chat.js`**

Create `ui/chat.js`:

```js
// NukeFire Chat — panel UI logic.
//
// Receives :post("line", { tab, text, ts }) and :post("settings", …)
// messages from the Lua side via Mallard's panel SDK. Maintains per-tab
// FIFO ring buffers; renders only the active tab.
//
// Tabs: all, tell, auction, gossip — fixed, unlike Discworld Chat's
// dynamic pin+catch-all model, since NukeFire's channel set here is small
// and known ahead of time.

const BUFFER_MAX = 1000;
const FIXED_TABS = ["all", "tell", "auction", "gossip"];
const TAB_LABELS = { all: "All", tell: "Tell", auction: "Auction", gossip: "Gossip" };

const buffers = {};
let activeTab = "all";
let settings = { sources: { tell: {}, auction: {}, gossip: {} } };
let view = "chat"; // "chat" or "settings"

const tabsEl = document.getElementById("tabs");
const scrollback = document.getElementById("scrollback");
const settingsEl = document.getElementById("settings");
const sourcesEl = document.getElementById("sources");
const overflowPopover = document.getElementById("overflow-popover");

function pad(n) { return n < 10 ? "0" + n : "" + n; }
function formatTime(unix) {
  const d = new Date(unix * 1000);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

// URL autolinking — mirrors src-tauri/src/url_autolink.rs in Mallard proper
// so links in plugin content behave the same as links in the main output:
// the same shapes match (http(s)://, www., mailto:, bare host/path), the
// same trailing-punctuation trim runs, and the same "bare host with no path"
// guard prevents false positives on file names like `connection.lua`.
const URL_RE = new RegExp(
  [
    "https?://[^\\s<>\"'`]+",
    "www\\.[^\\s<>\"'`]+",
    "mailto:[^\\s<>\"'`]+",
    "[A-Za-z0-9][A-Za-z0-9-]*(?:\\.[A-Za-z0-9][A-Za-z0-9-]+)+/[^\\s<>\"'`]+",
  ].join("|"),
  "g",
);

function trimTrailingPunctuation(matched) {
  let end = matched.length;
  while (end > 0) {
    const c = matched[end - 1];
    if (c === "." || c === "," || c === ";" || c === ":" || c === "!" || c === "?") {
      end -= 1;
      continue;
    }
    const pair = c === ")" ? ["(", ")"]
      : c === "]" ? ["[", "]"]
      : c === "}" ? ["{", "}"]
      : c === ">" ? ["<", ">"]
      : null;
    if (!pair) break;
    const prefix = matched.slice(0, end);
    let opens = 0, closes = 0;
    for (const ch of prefix) { if (ch === pair[0]) opens++; else if (ch === pair[1]) closes++; }
    if (closes > opens) end -= 1; else break;
  }
  return matched.slice(0, end);
}

function linkTarget(matched) {
  if (matched.startsWith("http://") || matched.startsWith("https://") || matched.startsWith("mailto:")) {
    return matched;
  }
  return "https://" + matched;
}

// Build a document fragment from `text`, with detected URLs as anchors that
// route clicks through `panel.openUrl`. Anchors carry `href` so right-click
// "Copy link" works and middle-clickability surfaces; the click handler
// preventDefaults to keep the iframe from navigating away from itself.
function renderTextWithLinks(text) {
  const frag = document.createDocumentFragment();
  let cursor = 0;
  URL_RE.lastIndex = 0;
  let m;
  while ((m = URL_RE.exec(text)) !== null) {
    const matched = trimTrailingPunctuation(m[0]);
    if (!matched) continue;
    const start = m.index;
    const end = start + matched.length;
    URL_RE.lastIndex = end;
    if (start > cursor) frag.appendChild(document.createTextNode(text.slice(cursor, start)));
    const a = document.createElement("a");
    a.className = "url";
    a.textContent = matched;
    a.href = linkTarget(matched);
    a.rel = "noopener noreferrer";
    a.addEventListener("click", onUrlClick);
    a.addEventListener("auxclick", onUrlClick);
    frag.appendChild(a);
    cursor = end;
  }
  if (cursor === 0) {
    frag.appendChild(document.createTextNode(text));
  } else if (cursor < text.length) {
    frag.appendChild(document.createTextNode(text.slice(cursor)));
  }
  return frag;
}

function onUrlClick(e) {
  // Left and middle clicks; ignore modifier-clicks so the user can still
  // select-and-drag a URL into the system clipboard via Cmd+drag etc.
  if (e.type === "auxclick" && e.button !== 1) return;
  if (e.button !== undefined && e.button !== 0 && e.button !== 1) return;
  e.preventDefault();
  const url = e.currentTarget.href;
  if (typeof panel.openUrl === "function") panel.openUrl(url);
}

function computeTabOrder() {
  return FIXED_TABS;
}

function ensureBuffer(tabId) {
  if (!buffers[tabId]) buffers[tabId] = [];
  return buffers[tabId];
}

function tabLabel(tabId) {
  return TAB_LABELS[tabId] || tabId;
}

function renderLine({ tab, text, ts }) {
  const el = document.createElement("div");
  el.className = "line";
  const tag = `[${tabLabel(tab)}]`;
  el.innerHTML =
    `<span class="ts">${formatTime(ts)}</span>` +
    `<span class="tag">${tag}</span>`;
  el.appendChild(renderTextWithLinks(text));
  return el;
}

function isPinnedToBottom() {
  return scrollback.scrollHeight - scrollback.scrollTop - scrollback.clientHeight < 16;
}

// Every line goes to "all" and to its own tab — no catch-all/pin fan-out
// since tabs are fixed 1:1 with channels here (unlike Discworld's
// pinned-channel-into-Channels-tab fan-out).
function bufferPush(entry) {
  // Pre-mark seen if the entry is going to be visible right now, so the
  // tab the user is on never lights up its own dot for content it just
  // displayed.
  if (view === "chat" && entryBelongsInTab(entry, activeTab)) {
    entry.seen = true;
  }
  const targets = new Set(["all", entry.tab]);
  for (const t of targets) {
    const buf = ensureBuffer(t);
    buf.push(entry);
    if (buf.length > BUFFER_MAX) buf.shift();
  }
  return targets;
}

// Tab ids currently collapsed into the overflow "•••" button. Set by
// collapseOverflow; consulted by refreshUnreadDots so the overflow
// trigger lights up when a hidden tab has unread.
let overflowHiddenIds = [];

function isTabUnread(tabId) {
  const buf = buffers[tabId];
  if (!buf) return false;
  for (let i = 0; i < buf.length; i++) {
    if (!buf[i].seen) return true;
  }
  return false;
}

// Mark every entry in `tabId`'s buffer as seen. Entries are shared
// across buffers, so this clears the contribution of those entries in
// every tab that also holds them.
function markBufferSeen(tabId) {
  const buf = buffers[tabId];
  if (!buf) return;
  for (let i = 0; i < buf.length; i++) buf[i].seen = true;
}

function refreshUnreadDots() {
  const order = computeTabOrder();
  for (const id of order) {
    const flag = isTabUnread(id);
    const sel = `.tab[data-tab="${CSS.escape(id)}"]`;
    for (const btn of tabsEl.querySelectorAll(sel)) btn.classList.toggle("has-unread", flag);
    for (const btn of overflowPopover.querySelectorAll(sel)) btn.classList.toggle("has-unread", flag);
  }
  const overflowBtn = tabsEl.querySelector(".tab.overflow");
  if (overflowBtn) {
    overflowBtn.classList.toggle("has-unread", overflowHiddenIds.some(id => isTabUnread(id)));
  }
}

function entryBelongsInTab(entry, tab) {
  if (tab === "all") return true;
  return tab === entry.tab;
}

function appendToActive(entry) {
  if (view !== "chat") return;
  if (!entryBelongsInTab(entry, activeTab)) return;
  const wasPinned = isPinnedToBottom();
  scrollback.appendChild(renderLine(entry));
  while (scrollback.childElementCount > BUFFER_MAX) {
    scrollback.removeChild(scrollback.firstElementChild);
  }
  if (wasPinned) scrollback.scrollTop = scrollback.scrollHeight;
}

function rerenderActive() {
  scrollback.replaceChildren();
  const buf = buffers[activeTab] || [];
  for (const e of buf) scrollback.appendChild(renderLine(e));
  scrollback.scrollTop = scrollback.scrollHeight;
}

let activeTabRestored = false;

function switchTab(t) {
  const order = computeTabOrder();
  if (!order.includes(t)) return;
  activeTab = t;
  view = "chat";
  scrollback.hidden = false;
  settingsEl.hidden = true;
  markBufferSeen(t);
  renderTabs();
  rerenderActive();
  panel.post("active_tab", { tab: t });
  // Any explicit tab choice (including the restore call below) closes
  // the one-shot restore window so a late `settings` broadcast can't
  // yank the user back.
  activeTabRestored = true;
}

function openSettings() {
  view = "settings";
  scrollback.hidden = true;
  settingsEl.hidden = false;
  renderTabs();
  renderSettings();
  kickHandshake();
}

function makeTabButton(tabId, { overflow = false } = {}) {
  const btn = document.createElement("button");
  btn.className = "tab"
    + (tabId === activeTab && view === "chat" ? " active" : "")
    + (isTabUnread(tabId) ? " has-unread" : "");
  btn.dataset.tab = tabId;
  btn.role = "tab";
  btn.textContent = tabLabel(tabId);
  btn.addEventListener("click", () => {
    switchTab(tabId);
    if (overflow) hideOverflowPopover();
  });
  return btn;
}

const GEAR_SVG = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">' +
  '<path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.49.49 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54A.48.48 0 0 0 13.92 2h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.47c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6A3.6 3.6 0 1 1 12 8.4a3.6 3.6 0 0 1 0 7.2z"/>' +
  '</svg>';

function makeIconButton(content, className, onClick, { svg = false, title = "" } = {}) {
  const btn = document.createElement("button");
  btn.className = `tab ${className}` + (className === "gear" && view === "settings" ? " active" : "");
  if (svg) btn.innerHTML = content; else btn.textContent = content;
  if (title) btn.title = title;
  btn.addEventListener("click", onClick);
  return btn;
}

function hideOverflowPopover() {
  overflowPopover.hidden = true;
  overflowPopover.replaceChildren();
}

function showOverflowPopover(tabIds, anchorBtn) {
  overflowPopover.replaceChildren();
  for (const id of tabIds) {
    overflowPopover.appendChild(makeTabButton(id, { overflow: true }));
  }
  overflowPopover.hidden = false;
  const r = anchorBtn.getBoundingClientRect();
  overflowPopover.style.left = `${r.left}px`;
  overflowPopover.style.top = `${r.bottom}px`;
}

function renderTabs() {
  tabsEl.replaceChildren();
  const order = computeTabOrder();
  const gear = makeIconButton(GEAR_SVG, "gear", () => {
    if (view === "settings") switchTab(activeTab); else openSettings();
  }, { svg: true, title: "Settings" });

  // First-pass render — everything visible. Then measure and collapse.
  for (const id of order) tabsEl.appendChild(makeTabButton(id));
  tabsEl.appendChild(gear);

  requestAnimationFrame(() => collapseOverflow(order, gear));
}

function collapseOverflow(order, gear) {
  hideOverflowPopover();
  overflowHiddenIds = [];
  const barWidth = tabsEl.clientWidth;
  const gearWidth = gear.offsetWidth;
  const childButtons = Array.from(tabsEl.querySelectorAll(".tab:not(.gear):not(.overflow)"));

  let used = gearWidth;
  let overflowStart = -1;
  for (let i = 0; i < childButtons.length; i++) {
    used += childButtons[i].offsetWidth;
    if (used > barWidth) { overflowStart = i; break; }
  }
  if (overflowStart < 0) return;

  // Reserve space for the overflow button itself.
  const overflowBtn = makeIconButton("•••", "overflow", () => {
    const hiddenIds = order.slice(overflowStart);
    showOverflowPopover(hiddenIds, overflowBtn);
  });
  // Re-measure with overflow button width factored in: walk back until fits.
  // Insert temporarily to measure.
  tabsEl.insertBefore(overflowBtn, gear);
  const overflowWidth = overflowBtn.offsetWidth;

  // Recompute the cutoff with overflowWidth reserved.
  used = gearWidth + overflowWidth;
  overflowStart = -1;
  for (let i = 0; i < childButtons.length; i++) {
    used += childButtons[i].offsetWidth;
    if (used > barWidth) { overflowStart = i; break; }
  }
  if (overflowStart < 0) {
    overflowBtn.remove();
    return;
  }

  for (let i = overflowStart; i < childButtons.length; i++) {
    childButtons[i].remove();
  }
  // Rewire the overflow handler with the final hidden list.
  const hiddenIds = order.slice(overflowStart);
  overflowHiddenIds = hiddenIds;
  overflowBtn.onclick = () => showOverflowPopover(hiddenIds, overflowBtn);
  // Now that the overflow button exists, sync its dot — refreshUnreadDots
  // queries `.tab.overflow` so this couldn't run during makeTabButton.
  refreshUnreadDots();
}

// ---------------------------------------------------------------------
// Settings view rendering
// ---------------------------------------------------------------------

function sendUpdate(delta) {
  panel.post("settings_update", delta);
}

function renderSourceRow(label, key) {
  const row = document.createElement("div");
  row.className = "settings-row source-row";
  const name = document.createElement("span");
  name.className = "settings-name";
  name.textContent = label;
  row.appendChild(name);

  function sourceToggle(text, field) {
    const lab = document.createElement("label");
    lab.className = "settings-toggle";
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = !!(settings.sources[key] && settings.sources[key][field]);
    cb.addEventListener("change", () => {
      sendUpdate({ source: { [key]: { [field]: cb.checked } } });
    });
    lab.appendChild(cb);
    lab.appendChild(document.createTextNode(" " + text));
    return lab;
  }

  row.appendChild(sourceToggle("gag from main", "gag_main"));
  row.appendChild(sourceToggle("sound", "sound"));
  row.appendChild(sourceToggle("notify", "notify"));
  return row;
}

function renderSettings() {
  sourcesEl.replaceChildren();
  sourcesEl.appendChild(renderSourceRow("Tell", "tell"));
  sourcesEl.appendChild(renderSourceRow("Auction", "auction"));
  sourcesEl.appendChild(renderSourceRow("Gossip", "gossip"));
}

// ---------------------------------------------------------------------
// Panel SDK wiring
// ---------------------------------------------------------------------

panel.on("line", (payload) => {
  bufferPush(payload);
  appendToActive(payload);
  refreshUnreadDots();
});

let settingsReceived = false;
panel.on("settings", (payload) => {
  settingsReceived = true;
  if (payload && typeof payload === "object") {
    settings.sources = payload.sources || settings.sources;
    // Restore the persisted active tab once per iframe lifetime —
    // subsequent settings broadcasts (e.g. after a settings_update)
    // must not yank the user back if they've since clicked elsewhere.
    if (!activeTabRestored) {
      activeTabRestored = true;
      if (typeof payload.active_tab === "string" && payload.active_tab !== activeTab) {
        switchTab(payload.active_tab);
      }
    }
  }
  renderTabs();
  if (view === "settings") renderSettings();
});

// Keyboard tab navigation. main.lua's chat_tab_<n> commands (bound by the
// "chat-tab-nav" keymap layer) post these. We resolve the 1-based strip
// position against the fixed tab order and reuse switchTab(), so
// seen-marking, re-render, and active_tab persistence all happen exactly
// as on a click. Out-of-range = no-op.
panel.on("goto_index", (payload) => {
  const index = payload && payload.index;
  const id = tabIdForIndex(computeTabOrder(), index);
  if (id) switchTab(id);
});

window.addEventListener("resize", () => renderTabs());

document.addEventListener("click", (e) => {
  if (overflowPopover.hidden) return;
  if (overflowPopover.contains(e.target)) return;
  if (e.target.classList && e.target.classList.contains("overflow")) return;
  hideOverflowPopover();
});

renderTabs();

// Handshake with retry: Mallard's panel dispatcher drops messages when
// no Lua listener is yet registered, so our first "ready" can race the
// plugin's top-level code on a Mallard restart. Lua dedupes history
// replay by `session` so retries don't double-replay but a fresh iframe
// mount always gets history.
const READY_RETRY_MS = 500;
const READY_MAX_ATTEMPTS = 120; // ~60s total
const SESSION_ID = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
let readyAttempts = 0;
let readyTimer = null;
function sendReady() {
  readyTimer = null;
  if (settingsReceived) return;
  if (readyAttempts >= READY_MAX_ATTEMPTS) return;
  panel.post("ready", { session: SESSION_ID });
  readyAttempts += 1;
  readyTimer = setTimeout(sendReady, READY_RETRY_MS);
}
function kickHandshake() {
  if (settingsReceived) return;
  if (readyTimer) { clearTimeout(readyTimer); readyTimer = null; }
  readyAttempts = 0;
  sendReady();
}
```

- [ ] **Step 4: Syntax-check the JS**

Run: `node --check ui/chat.js`
Expected: no output, exit code 0.

- [ ] **Step 5: Re-run the tab_index test to confirm the shared module still matches usage**

Run: `node tests/tab_index_test.js`
Expected: `all passed` (same output as Task 2 Step 4 — confirms `FIXED_TABS`/`tabIdForIndex` usage in `chat.js` is consistent with the tested order).

- [ ] **Step 6: Commit**

```bash
git add ui/chat.html ui/chat.css ui/chat.js
git commit -m "Add NukeFire Chat panel UI: fixed 4-tab shell ported from Discworld Chat"
```

---

### Task 7: Manual end-to-end verification in Mallard

Everything up to here is testable in isolation (Lua modules with `luajit`, JS with `node`). This task is the acceptance step that exercises the real plugin inside the real app, since Mallard's host APIs (`mud.*`, `storage.*`, the panel iframe bridge) only exist at runtime — there's no way to automate this part.

**Files:** none (verification only)

- [ ] **Step 1: Symlink the plugin into Mallard's dev plugins folder**

```bash
ln -s /home/john/dev/mallardx-nukefire-chat "$(find /home/john/.local/share/net.mallard.app/plugins-dev -maxdepth 0)/se.broaty.nukefire-chat"
```

If that `find` substitution is inconvenient, symlink directly:

```bash
ln -s /home/john/dev/mallardx-nukefire-chat /home/john/.local/share/net.mallard.app/plugins-dev/se.broaty.nukefire-chat
```

- [ ] **Step 2: Reload plugins in Mallard**

In the running Mallard app: open the command palette → **Open Plugins…** → **Reload plugins**.

- [ ] **Step 3: Attach to a live NukeFire session**

Per the sibling `nukefire-misc` plugin's own README note: reloading only refreshes the plugin registry, it doesn't attach an already-loaded plugin to a world that connected before the plugin existed. If already connected to `tdome.nukefire.org`, either reconnect or toggle the plugin's per-world enabled switch off/on.

- [ ] **Step 4: Verify the Chat panel appears**

Confirm a "Chat" panel docks below the main output, with 4 tabs: All, Tell, Auction, Gossip, plus a gear icon.

- [ ] **Step 5: Exercise tell capture**

Send a tell (`telepath <name>, <message>` per the game's syntax) and have someone (or wait for someone) to tell you back. Confirm both the outgoing and incoming lines appear in the **All** and **Tell** tabs with a timestamp and `[Tell]` tag.

- [ ] **Step 6: Exercise auction and gossip capture**

Wait for (or trigger, if you have a way to) auction and gossip traffic. Confirm lines land in **All** plus their respective **Auction**/**Gossip** tabs.

- [ ] **Step 7: Exercise settings**

Click the gear icon. Confirm 3 rows (Tell, Auction, Gossip), each with "gag from main", "sound", "notify" checkboxes. Toggle "gag from main" for one channel, trigger a line on that channel, and confirm it no longer appears in the main output pane but still appears in its tab and in All.

- [ ] **Step 8: Exercise sound/notify**

Toggle "sound" on for a channel, trigger an incoming line on it, confirm a chime plays. Toggle "notify" on, trigger another incoming line, confirm a desktop notification appears. (Recall: outgoing tells never chime/notify — only incoming traffic does, per `classifier.classify`'s `incoming` flag.)

- [ ] **Step 9: Exercise tab keybindings**

Press Ctrl+Shift+1 through Ctrl+Shift+4 and confirm each jumps to All/Tell/Auction/Gossip respectively. In Settings → Keymaps, disable the `tab_keybindings` plugin setting and confirm the combos stop switching tabs (existing keymap untouched otherwise).

- [ ] **Step 10: Exercise persistence**

Reload the plugin (or restart Mallard) and confirm the scrollback in each tab and the last-viewed tab are restored.

- [ ] **Step 11: Bump the README status if everything passes**

No code change — this step is just confirming the plugin is usable end-to-end before considering the initial version done. If any step fails, file it as a follow-up rather than silently patching around it, since the design doc's "Known limitations" section should stay the authoritative list of what's not yet handled (e.g. the unverified `history <channel>` replay behavior).

---

## Self-Review Notes

- **Spec coverage:** every section of `docs/superpowers/specs/2026-07-18-nukefire-chat-design.md` maps to a task — classification (Task 3), routing/gagging (Task 5), storage (Task 5), UI (Task 6), manifest (Task 4), testing (Tasks 1–6 each carry their own), known limitations (called out explicitly in Task 7 rather than silently addressed).
- **Placeholder scan:** no TBD/TODO markers; every step has complete, runnable code or an exact command with expected output.
- **Type/name consistency:** `tab` values (`"tell"`, `"auction"`, `"gossip"`, `"all"`) match across `classifier.lua` (Task 3), `main.lua`'s `CHANNEL_KEYS`/`TAB_LABELS`/`sources_cache` (Task 5), and `chat.js`'s `FIXED_TABS`/`TAB_LABELS`/`settings.sources` (Task 6). The panel message names (`ready`, `settings_update`, `active_tab`, `line`, `settings`, `goto_index`) match on both sides. `tabIdForIndex(order, index)`'s signature (Task 2) matches its call site in Task 6.
