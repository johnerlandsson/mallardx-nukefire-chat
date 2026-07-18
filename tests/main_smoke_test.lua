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
