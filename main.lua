-- Harvest Post, the script half. Four small pieces in one file:
--
--   1. The post: once a game day, a letter with a little present arrives in
--      the mailbox. A setting decides the present. A timer tries again later.
--   2. The fruit contest, on fair day only: a question (cmd.ask), an entry
--      fee (cmd.take_bells) and a thank-you letter from letters.json.
--   3. A line at 6 PM on fair day (hour_changed, cmd.show_line).
--   4. A function other mods can call (remote.add, mod.json "exports").
--
-- An event handler never changes the game itself. It QUEUES a command, and the
-- game applies it at the end of a frame's update, once the player is free.
-- mod.json must name each command in "permissions". command_finished then
-- says how each one went, whatever kind it was.
--
-- The game's cap is per town, not per player: 3 letters a day from one mod,
-- so in a town of four the fourth resident to play that day gets none.

local MOD = "example.harvest-post"
local FAIR = "harvest-fair" -- a day's id in calendar.json
local ENTRY_FEE = 100

-- Fruit: always a fine present (the shop's item rules refuse money, turnips,
-- tickets, grab bags, fossils and reserve ids).
local GIFTS = { 0x2800, 0x2801, 0x2802, 0x2803, 0x2804 }

-- The game day as one number, 20261112, or nil before a town is loaded.
local function today()
  local t = game.town()
  if not t then return nil end
  return t.year * 10000 + t.month * 100 + t.day
end

-- Is one of this mod's calendar days today? game.calendar_today() lists the
-- ids of this mod's own days that fall on the town's date, and only its own.
local function is_today(day_id)
  for _, id in ipairs(game.calendar_today()) do
    if id == day_id then return true end
  end
  return false
end

-- store.town() names the town the store is for. It starts with "v:" away from
-- home, on a friend's town, where a take is refused.
local function at_home()
  local town = store.town()
  return town ~= nil and town:sub(1, 2) ~= "v:"
end

-- ── 4. A function for other mods ────────────────────────────────────────────
-- remote.add offers it while the script loads. mod.json "exports" lists the
-- names a mod offers, each with a line that says what it returns. Another mod
-- names this one in "optional_depends" and asks with remote.call.
remote.add("fair_today", function()
  return is_today(FAIR)
end)

-- ── 1. The post ─────────────────────────────────────────────────────────────

-- "present" is a setting from mod.json, set by the player on the Mods tab.
-- It is a World setting (the default scope), so it is part of the town: a
-- visitor lent this mod runs the host's choice. A World setting may decide
-- what the town gets, so the letter command below is allowed after it.
local function present()
  if settings.get("present") == "none" then return nil end
  -- rng() counts the numbers this mod has drawn in this town today and keeps
  -- that count with the town, so a reload carries on from it: reloading the
  -- game cannot reroll the present.
  return GIFTS[rng(#GIFTS)]
end

local function send_today()
  local day = today()
  if not day or store.player.get("sent") == day then return end
  local gift = present()
  local id, why, code = cmd.send_letter{ text = message("letter"), item = gift, from = message("from") }
  if id then
    store.player.set("sent", day)
    log("letter #" .. id .. " queued" .. (gift and string.format(" with item 0x%04X", gift) or ", no present"))
  else
    log("no letter today: " .. why .. " (" .. code .. ")")
    -- The town's letters for today are used up: do not ask again until tomorrow.
    if code == "command-day-cap" then store.player.set("sent", day) end
  end
end

-- Try again later. timer.after counts GAME minutes and keeps the timer with
-- this town's data, so it still fires after a save and a reload. One timer per
-- resident is enough: a second refusal finds the first still waiting. The name
-- comes back in timer_fired, and the data says whose letter it was.
--
-- The timer's id is kept in the town's store under the resident's id, not in
-- store.player. The timer may fire while another resident plays, and only the
-- town's store can be cleared then.
local RETRY_MINUTES = 30
local function retry_key(id) return "retry:" .. tostring(id) end
local function retry_later()
  local p = game.player()
  if not p or store.get(retry_key(p.id)) then return end
  local id, why, code = timer.after(RETRY_MINUTES, "retry", p.id)
  if id then
    store.set(retry_key(p.id), id)
  else
    log("no retry timer: " .. why .. " (" .. code .. ")")
  end
end

-- The letter got through some other way first: the waiting timer is not
-- needed now. timer.cancel answers true when there was one to cancel.
local function cancel_retry()
  local p = game.player()
  if not p then return end
  local timer_id = store.get(retry_key(p.id))
  if timer_id then
    log("retry timer cancelled: " .. tostring(timer.cancel(timer_id)))
    store.set(retry_key(p.id), nil)
  end
end

-- ── 2. The fruit contest ────────────────────────────────────────────────────

local ask_id = nil   -- the contest question, while it is out
local thanks = {}    -- command ids of thank-you letters, so their results are not the post's

-- cmd.ask puts a question with 2 to 4 answers in the player's thought window.
-- The pick comes back in question_answered. Asked once per fair day per
-- resident, in their own town.
local function invite()
  local day = today()
  if not day or ask_id or not at_home() or not is_today(FAIR) then return end
  if store.player.get("contest") == day then return end
  local id, why, code = cmd.ask{ text = message("contest"), choices = { "Apple", "Pear", "Not today" } }
  if id then
    ask_id = id
    store.player.set("contest", day) -- asked today, whatever the answer
  else
    log("no contest question: " .. why .. " (" .. code .. ")")
  end
end

-- e.choice counts from 1 and e.text is the answer. Both are nil when the
-- player closed the window with no pick.
on("question_answered", function(e)
  if e.id ~= ask_id then return end
  ask_id = nil
  if e.choice == nil or e.choice == 3 then
    log("contest: not entered")
    return
  end
  -- take_bells shows the game's own question, which names the amount and this
  -- mod, so the player always sees what they pay. Its one result comes back in
  -- command_finished: via "taken", or command-declined for a no.
  local id, why, code = cmd.take_bells{ amount = ENTRY_FEE }
  if id then
    store.player.set("fruit", e.text)
  else
    log("contest: no entry fee asked: " .. why .. " (" .. code .. ")")
  end
end)

-- ── 3. A line at 6 PM on fair day ───────────────────────────────────────────

-- hour_changed fires on the game's own hourly update. cmd.show_line puts a
-- line in the player's thought window once the player is free.
on("hour_changed", function(e)
  if e.hour ~= 18 or not is_today(FAIR) then return end
  local id, why, code = cmd.show_line(message("packing_up"))
  if not id then log("no packing-up line: " .. why .. " (" .. code .. ")") end
end)

-- ── Events ──────────────────────────────────────────────────────────────────

-- A new day, and the first scene of each session (a game loaded on a day it
-- already saw does not run day_started again).
on("day_started", send_today)
on("scene_entered", function(e)
  send_today()
  if e.name == "town" then invite() end
end)

-- What happened to each command. e.command names its kind. e.via says how it
-- was applied ("mailbox" or "post_office" for a letter, "taken" for a take,
-- "shown" for a line or a question). A refusal has e.code (stable, for the
-- script) and e.message (for the log).
on("command_finished", function(e)
  if e.command == "take_bells" then
    if e.ok then
      log("contest: entered with " .. tostring(store.player.get("fruit")) .. ", " .. ENTRY_FEE .. " Bells paid")
      -- the letters.json template: header, body, sign-off, present and paper
      local id, why, code = cmd.send_letter{ template = "fair-thanks" }
      if id then thanks[id] = true else log("no thank-you letter: " .. why .. " (" .. code .. ")") end
    else
      -- command-declined: the player said no. command-not-held: the wallet
      -- holds less than the fee. Nothing was taken either way.
      log("contest: no entry (" .. e.code .. ")")
    end
    return
  end
  if e.command ~= "send_letter" then return end -- the line and the question report "shown"
  if thanks[e.id] then
    thanks[e.id] = nil
    log("thank-you letter " .. (e.ok and ("delivered via " .. e.via) or ("not delivered: " .. e.message)))
    return
  end
  if e.ok then
    log("letter #" .. e.id .. " delivered via " .. e.via)
    cancel_retry()
  elseif e.code == "command-day-cap" then
    log("letter #" .. e.id .. " not delivered: " .. e.message)
  else
    -- Refused for now (in The City, visiting a friend, both boxes full): the
    -- day's letter is owed again. The next scene tries, and so does a timer
    -- half a game hour from now, for a player who stays where they are.
    -- Away from home, store and timers live in memory only. A result that
    -- arrives there clears "sent" in that copy, not at home, so the letter is
    -- not owed again today. Tomorrow's comes as usual.
    log("letter #" .. e.id .. " not delivered: " .. e.message)
    store.player.set("sent", nil)
    retry_later()
  end
end)

-- The timer is gone once it fires, so its mark goes too, whoever is playing.
-- Send only to the resident it was set for: another resident may be playing by
-- now, and has a letter of their own.
on("timer_fired", function(e)
  if e.name ~= "retry" then return end
  store.set(retry_key(e.data), nil)
  local p = game.player()
  if p and p.id == e.data then send_today() end
end)

-- The player read a letter. e.letter names a letters.json letter as
-- "<mod id>:<letter id>" when a mod mailed it: the contest's thank-you, or
-- Apple Day's, which calendar.json mails with no script at all.
on("letter_read", function(e)
  if e.first_time and e.letter and e.letter:sub(1, #MOD + 1) == MOD .. ":" then
    log("read " .. e.letter)
  end
end)
