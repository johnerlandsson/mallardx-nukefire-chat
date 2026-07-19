-- NukeFire Chat — captures tell/auction/gossip/group into a tabbed chat panel.
--
-- Ported from Discworld Chat's architecture, scoped to NukeFire's fixed
-- tell/auction/gossip/group channels — see
-- docs/superpowers/specs/2026-07-18-nukefire-chat-design.md for the design
-- rationale (plain-text triggers over GMCP, fixed tabs over dynamic
-- pin+catch-all, gag/sound/notify checkboxes over server-side toggles).

local classifier = require("classifier")
local flush_gate = require("flush_gate")

local panel = mud.panel("chat")

local HISTORY_KEY    = "chat_history_v1"
local SOURCES_KEY    = "channel_settings_v1"
local ACTIVE_TAB_KEY = "active_tab_v1"

local CHANNEL_KEYS = { "tell", "auction", "gossip", "group" }
local TAB_LABELS   = { tell = "Tell", auction = "Auction", gossip = "Gossip", group = "Group" }

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

-- Delta shape: { source = { tell = {gag_main?, sound?, notify?}, auction = {...}, gossip = {...}, group = {...} } }
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

for i = 1, 5 do
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

-- Outgoing gossip: "You gossip, 'Good thanks!'"
mud.trigger([==[^You gossip, ']==], function(m)
  if route_line(m.text) then m:gag() end
end)

-- Outgoing group say: "You group-say, 'hi'"
mud.trigger([==[^You group-say, ']==], function(m)
  if route_line(m.text) then m:gag() end
end)

-- Any [Group]-tagged line: says/joins/leaves/leader-change/etc.
mud.trigger([==[^\[Group\] ]==], function(m)
  if route_line(m.text) then m:gag() end
end)

-- ---------------------------------------------------------------------
-- Debounced flush + disconnect flush.
-- ---------------------------------------------------------------------

mud.every(PERSIST_DEBOUNCE_MS, flush)
world.on("disconnect", function() flush(true) end)
