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
