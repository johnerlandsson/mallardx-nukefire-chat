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
