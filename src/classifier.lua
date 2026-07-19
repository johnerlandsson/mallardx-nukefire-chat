-- NukeFire Chat line classifier.
--
-- Pure Lua, no host-API dependencies. Patterns confirmed against real
-- session log lines — see
-- docs/superpowers/specs/2026-07-18-nukefire-chat-design.md for examples.
--
-- Verb-channels (auction, gossip, and future ones like shout/holler/grats)
-- share the incoming shape "<speaker> <verb>, '<message>'". Auction has no
-- confirmed player-authored broadcast form (only "the Auctioneer" is ever
-- observed sending it). Gossip does have one — see is_outgoing_gossip
-- below — so it isn't purely incoming like the others. Add a new entry to
-- VERB_CHANNELS to support another channel once its exact verb is
-- confirmed in-game.

local M = {}

local VERB_CHANNELS = {
  { tab = "auction", verb = "auctions" },
  { tab = "gossip",  verb = "gossips" },
}

-- Outgoing gossip: "You gossip, 'Good thanks!'" — note the singular verb
-- (no trailing "s"), unlike the incoming "<speaker> gossips, '...'" shape
-- matched by match_verb_channel below. Confirmed in a real session log.
local function is_outgoing_gossip(line)
  return line:match("^You gossip, '") ~= nil
end

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
  if is_outgoing_group(line) then
    return { tab = "group", incoming = false }
  end
  if is_outgoing_gossip(line) then
    return { tab = "gossip", incoming = false }
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

return M
