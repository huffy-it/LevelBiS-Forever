-- Advisor.lua ---------------------------------------------------------------
-- Answers "is this item better than what I wear?" for items that appear while
-- you play, instead of for the level you are planning for:
--
--   M-1   quest reward choices (on accepting, on turning in, and /lbis quest)
--   M-2   upgrades that reach your bags (off by default; only with the window open)
--   M-14  group loot rolls
--   M-15  the reason line on a tooltip
--
-- All four share ns.Evaluate, which scores the item for the slot it would take
-- and against what is in that slot now. The scoring is the window's own, so a
-- verdict here and a row there cannot disagree.
------------------------------------------------------------------------------
local ADDON, ns = ...
local S = ns.Scoring
local L = ns.L

local function Print(msg) ns.Print(msg) end

local function afterDelay(seconds, fn)
    if C_Timer and C_Timer.After then C_Timer.After(seconds, fn) else fn() end
end

local function slotWord(name)
    return (ns.SLOT_LABEL and ns.SLOT_LABEL[name]) or name
end

local function settings() return LevelBiSCharDB and LevelBiSCharDB.settings or {} end

------------------------------------------------------------------------------
-- Evaluate
------------------------------------------------------------------------------
-- Returns a table, or nil plus the reason:
--   "pending"  the client has not sent the item yet
--   "unusable" your class cannot equip it, or it is not for your spec
--   "nodata"   nothing to judge it with
-- The table: { id, slot, gain, pct, score, eq, empty, better, unpriced,
--              assumedRoll }
--   gain         absolute score gained over what the slot holds (negative: loss)
--   pct          gain as a percentage of the held item, nil for an empty slot
--   better       gain is worth acting on
--   unpriced     the item is worth nothing to a weighted sum (a proc trinket)
--   assumedRoll  the item rolls a suffix and was scored on its best roll
-- A ring or trinket is compared with the slot it would actually replace, and a
-- two-hander with both hands.
function ns.Evaluate(link, level)
    if not (link and ns.db and ns.weights and ns.playerClass) then return nil, "nodata" end
    local id = tonumber(link:match("item:(%d+)"))
    if not id then return nil, "nodata" end
    level = level or ns.playerLevel or 1
    local filters = settings().filters or {}
    local base = ns.db[id]
    local item, assumed
    if base and not S.LinkSuffix(link) then
        item = base
        assumed = (base.sg or base.pg) and not filters.noRandom or false
    else
        local state
        item, state = S.LiveItem(S.UnmodifiedLink(link))
        if not item then
            return nil, (state == "pending") and "pending" or "unusable"
        end
    end
    if not item.slot then return nil, "unusable" end
    item.id = id
    local effLevel = math.min(70, math.max(level, item.req or 0))
    if not S.CanUse(item, ns.playerClass, effLevel) then return nil, "unusable" end
    if not S.Recommendable(item, ns.playerClass, effLevel, ns.activeSpec) then
        return nil, "unusable"
    end
    local required = S.RequiredHands(ns.playerClass, effLevel, ns.activeSpec)
    local dual = S.CanDualWield(ns.playerClass, effLevel, ns.activeSpec)
    local twoHand = S.TWO_HAND_INV[item.slot]
    S.SetIgnoreRandom(filters.noRandom)
    S.UseProfile(ns.weights)

    local best
    for _, slotName in ipairs(S.SLOT_ORDER) do
        local def = S.SLOTS[slotName]
        local fits = def.inv[item.slot] == true
        if fits and slotName == "mainhand" then
            if required == "2h" and not twoHand then fits = false end
            if required and required ~= "2h" and twoHand then fits = false end
        elseif fits and slotName == "offhand" then
            if required == "2h" then fits = false
            elseif required == "shield" and not S.SHIELD_INV[item.slot] then fits = false
            elseif required == "dual" and not S.OFFHAND_WEAPON_INV[item.slot] then fits = false
            elseif S.OFFHAND_WEAPON_INV[item.slot] and not dual then fits = false end
        end
        if fits then
            local score = S.ScoreForSlot(item, ns.weights, def.slot, effLevel)
            local eq, _, _, _, state = S.EquippedScore(def.slot, ns.weights, effLevel)
            if state == "pending" then return nil, "pending" end
            if state ~= "unpriceable" then
                eq = eq or 0
                if slotName == "mainhand" and twoHand then
                    -- A two-hander also takes the off hand out of play.
                    local off, _, _, _, offState = S.EquippedScore(
                        S.SLOTS.offhand.slot, ns.weights, effLevel)
                    if offState == "pending" then return nil, "pending" end
                    eq = eq + (off or 0)
                end
                local gain = score - eq
                if not best or gain > best.gain then
                    best = {
                        id = id, slot = slotName, gain = gain, score = score, eq = eq,
                        empty = (state == "empty"),
                        pct = (eq > 0) and (gain / eq * 100) or nil,
                    }
                end
            end
        end
    end
    if not best then return nil, "unusable" end
    best.better = best.gain > 0.5
    best.unpriced = best.score <= 0
    best.assumedRoll = assumed
    return best
end

-- "+12% in Hands", "empty slot in Hands" or "upgrade in Hands".
function ns.GainText(ev)
    local where = slotWord(ev.slot)
    if ev.empty then return L["empty slot in %s"]:format(where) end
    if ev.pct then return (L["+%.0f%% in %s"]):format(ev.pct, where) end
    return L["upgrade in %s"]:format(where)
end

------------------------------------------------------------------------------
-- M-1. Quest rewards
------------------------------------------------------------------------------
-- The price a vendor pays: the 11th value of GetItemInfo. Unknown until the
-- client has the item; an unknown price never decides anything.
local function sellPrice(link, count)
    if not link or type(GetItemInfo) ~= "function" then return nil end
    local sp = select(11, GetItemInfo(link))
    if type(sp) == "number" and sp > 0 then return sp * (count or 1) end
    return nil
end

local function money(copper)
    return ns.Prices and ns.Prices.Money(copper) or tostring(copper)
end

-- Choose between reward options. `options` is { { link=, count= }, ... }.
-- Returns the chosen index (or nil), the message, and whether any option was
-- still pending.
function ns.ChooseReward(options)
    local evals, pending, bestIdx = {}, false, nil
    for i, opt in ipairs(options) do
        local ev, reason = ns.Evaluate(opt.link)
        evals[i] = ev
        if reason == "pending" then pending = true end
        if ev and ev.better and not ev.unpriced
           and (not bestIdx or ev.gain > evals[bestIdx].gain) then
            bestIdx = i
        end
    end
    if pending then return nil, nil, true end
    if bestIdx then
        local ev = evals[bestIdx]
        local text = L["Choose %s: %s."]:format(options[bestIdx].link, ns.GainText(ev))
        if ev.assumedRoll then text = text .. " " .. L["Assumes the best roll."] end
        return bestIdx, text
    end
    -- Nothing improves anything: the most valuable thing to sell.
    local sellIdx, sellBest
    for i, opt in ipairs(options) do
        local price = sellPrice(opt.link, opt.count)
        if price and (not sellBest or price > sellBest) then sellIdx, sellBest = i, price end
    end
    if sellIdx and #options > 1 then
        return sellIdx, L["None of them is an upgrade; %s sells for more (%s)."]:format(
            options[sellIdx].link, money(sellBest))
    end
    return nil, L["None of them is an upgrade."]
end

local function questOptions(kind)
    local out = {}
    if not (GetNumQuestChoices and GetQuestItemLink) then return out end
    for i = 1, (GetNumQuestChoices() or 0) do
        local link = GetQuestItemLink("choice", i)
        local count = GetQuestItemInfo and select(3, GetQuestItemInfo("choice", i)) or 1
        if link then out[#out + 1] = { link = link, count = count or 1 } end
    end
    return out
end

-- The same, from the quest log: no verified counter exists there, so it reads
-- until the first empty index, with a cap of ten.
local function questLogOptions()
    local out = {}
    if not GetQuestLogItemLink then return out end
    for i = 1, 10 do
        local link = GetQuestLogItemLink("choice", i)
        if not link then break end
        out[#out + 1] = { link = link, count = 1 }
    end
    return out
end

ns.questPick = {}   -- [itemID] = text, shown on that item's tooltip

local function advise(options, retried)
    if #options == 0 then return end
    local idx, text, pending = ns.ChooseReward(options)
    if pending then
        if not retried then afterDelay(1, function() advise(options, true) end) end
        return
    end
    wipe(ns.questPick)
    if idx then
        local id = tonumber(options[idx].link:match("item:(%d+)"))
        if id then ns.questPick[id] = text end
    end
    if text then Print(text) end
end

function ns.QuestAdvice() if settings().questAdvice ~= false then advise(questOptions()) end end
function ns.QuestLogAdvice() advise(questLogOptions()) end

------------------------------------------------------------------------------
-- M-2. Upgrades in the bags
------------------------------------------------------------------------------
local equipVersion = 0
local seen = {}            -- [link] = equipVersion when last judged
local lastAlert            -- { link =, slot = }
ns.lastBagAlerts = {}

-- Equipment changed: what was judged earlier may now read differently.
function ns.BagsEquipmentChanged() equipVersion = equipVersion + 1 end

local function windowOpen()
    return LevelBiSFrame ~= nil and LevelBiSFrame.IsShown ~= nil and LevelBiSFrame:IsShown()
end

function ns.BagScan()
    if not (settings().bagAlerts and windowOpen()) then return 0 end
    local numSlots, itemLink = ns.ContainerAPI()
    if not (numSlots and itemLink) then return 0 end
    local alerts = 0
    for bag = 0, 4 do
        for slot = 1, (numSlots(bag) or 0) do
            local link = itemLink(bag, slot)
            if link and seen[link] ~= equipVersion then
                local ev, reason = ns.Evaluate(link)
                if reason ~= "pending" then seen[link] = equipVersion end
                if ev and ev.better and not ev.unpriced and alerts < 3 then
                    alerts = alerts + 1
                    lastAlert = { link = link, slot = ev.slot }
                    ns.lastBagAlerts[#ns.lastBagAlerts + 1] = link
                    Print(L["Bag upgrade: %s %s. |cffffd100/lbis equip|r equips it."]:format(
                        link, ns.GainText(ev)))
                end
            end
        end
    end
    return alerts
end

-- Equip the last alert. Out of combat only, and never past the client's own
-- bind-on-equip confirmation.
function ns.EquipLastAlert()
    if not lastAlert then Print(L["There is no pending upgrade in your bags."]) return false end
    if InCombatLockdown and InCombatLockdown() then
        Print(L["You cannot equip in combat."])
        return false
    end
    if type(EquipItemByName) ~= "function" then
        Print(L["This client does not expose EquipItemByName."])
        return false
    end
    local slotID = S.SLOTS[lastAlert.slot] and S.SLOTS[lastAlert.slot].slot
    local ok = pcall(EquipItemByName, lastAlert.link, slotID)
    if not ok then pcall(EquipItemByName, lastAlert.link) end
    lastAlert = nil
    return true
end

------------------------------------------------------------------------------
-- M-14. Loot rolls
------------------------------------------------------------------------------
local advisedRoll = {}

function ns.RollAdvice(rollID, retried)
    if settings().rollAdvice == false or not GetLootRollItemLink then return end
    local link = GetLootRollItemLink(rollID)
    if not link then return end
    local ev, reason = ns.Evaluate(link)
    if reason == "pending" then
        if not retried then afterDelay(1, function() ns.RollAdvice(rollID, true) end) end
        return
    end
    if advisedRoll[rollID] == link then return end
    advisedRoll[rollID] = link
    if ev and ev.better and not ev.unpriced then
        Print(L["|cff40ff40Need:|r %s %s."]:format(link, ns.GainText(ev)))
    elseif ev and not ev.unpriced then
        Print(L["|cffffd100Greed:|r %s is not an upgrade."]:format(link))
    elseif reason == "unusable" then
        Print(L["|cffffd100Greed:|r %s is not for your class or spec."]:format(link))
    end
end

------------------------------------------------------------------------------
-- M-15. The reason on a tooltip
------------------------------------------------------------------------------
-- One short sentence: how much it improves, and what it mostly comes from.
-- nil when it does not improve anything.
function ns.ReasonLine(link)
    local ev = ns.Evaluate(link)
    if not (ev and ev.better and not ev.unpriced) then return nil end
    local item = ns.db and ns.db[ev.id]
    local main
    if item then
        local detail = S.Explain(item, ns.weights, S.SLOTS[ev.slot].slot)
        local mainPoints = 0
        for _, part in ipairs(detail and detail.parts or {}) do
            -- A gem's stat is not the item's: the sockets are named as one.
            if part.points > 0 and part.origin ~= "socket" then
                main = ns.StatLabel and ns.StatLabel(part.key) or part.key
                mainPoints = part.points
                break
            end
        end
        if detail and (detail.socketPoints or 0) > mainPoints then
            main = L["its sockets with ideal gems"]
        end
    end
    local head = ev.empty and L["Fills an empty slot: %s"]:format(slotWord(ev.slot))
                 or (L["%.0f%% upgrade in %s"]:format(ev.pct or 0, slotWord(ev.slot))
                     .. " " .. L["over what you have equipped"])
    -- Lower-case only a plain ASCII first letter: string.lower works on bytes,
    -- and an accented capital is two bytes in UTF-8.
    if main and main:byte(1) and main:byte(1) < 128 then
        main = main:sub(1, 1):lower() .. main:sub(2)
    end
    return head .. (main and (L[", mostly from %s"]:format(main)) or "") .. "."
end

------------------------------------------------------------------------------
-- M-8. Consumables
------------------------------------------------------------------------------
local function statText(st)
    local parts = {}
    for _, pair in ipairs(S.VariantStatList(st) or {}) do
        parts[#parts + 1] = ("%+d %s"):format(pair[2],
            ns.StatLabel and ns.StatLabel(pair[1]) or pair[1])
    end
    return table.concat(parts, ", ")
end

-- What to bring at `level`, as { head =, detail = } lines: flask or the pair of
-- elixirs, food, and the potions. Empty when nothing scores for these weights.
function ns.ConsumableLines(level)
    local out = {}
    if not (ns.consumables and ns.weights) then return out end
    level = level or ns:TargetLevel()
    local best = S.BestConsumables(level, ns.weights, ns.playerClass)
    local function name(b) return (ns.LocalName(b.id, { n = b.entry.n })) end
    local function line(label, b, extra)
        out[#out + 1] = {
            head = ("%s: %s"):format(label, name(b)),
            detail = (L["%s%s · level %d"]):format(statText(b.entry.st), extra or "", b.entry.req or 0),
            id = b.id, kind = b.entry.k,
        }
    end
    if best.useFlask then
        line(L["Flask"], best.flask, L[" · replaces both elixirs"])
    else
        if best.battle then line(L["Battle Elixir"], best.battle) end
        if best.guardian then line(L["Guardian Elixir"], best.guardian) end
    end
    if best.food then line(L["Food"], best.food, L[" (Well Fed)"]) end
    local function potion(label, b)
        out[#out + 1] = {
            head = ("%s: %s"):format(label, name(b)),
            detail = (L["restores %d-%d · level %d"]):format(b.entry.lo, b.entry.hi, b.entry.req or 0),
            id = b.id, kind = b.entry.k,
        }
    end
    if best.hp then potion(L["Health Potion"], best.hp) end
    if best.mana then potion(L["Mana Potion"], best.mana) end
    return out
end

------------------------------------------------------------------------------
-- Commands and events
------------------------------------------------------------------------------
ns.ExtraCmd = ns.ExtraCmd or {}

local function toggle(key, rest, label)
    local sv = settings()
    rest = (rest or ""):lower()
    if rest == "on" then sv[key] = true
    elseif rest == "off" then sv[key] = false
    else sv[key] = not sv[key] end
    Print(("%s: %s"):format(label, sv[key] and L["|cff40ff40enabled|r"] or L["|cffff6060disabled|r"]))
    if ns.UI and ns.UI.Refresh and LevelBiSFrame and LevelBiSFrame:IsShown() then ns.UI:Refresh() end
end

local function consumablesCmd()
    local level = ns:TargetLevel()
    local lines = ns.ConsumableLines(level)
    if #lines == 0 then
        Print(L["No consumable scores with your weights at this level."])
        return
    end
    Print(L["Consumables for level |cffffd100%d|r, based on your weights:"]:format(level))
    for _, l in ipairs(lines) do
        Print(("  %s |cff808080%s|r"):format(l.head, l.detail))
    end
end
ns.ExtraCmd.consumibles = consumablesCmd
ns.ExtraCmd.consumables = consumablesCmd
ns.ExtraCmd.equip = function() ns.EquipLastAlert() end
ns.ExtraCmd.quest = function() ns.QuestLogAdvice() end
ns.ExtraCmd.bags = function(rest)
    toggle("bagAlerts", rest, L["Bag alerts (only with the window open)"])
end
ns.ExtraCmd.rolls = function(rest)
    local sv = settings()
    rest = (rest or ""):lower()
    if rest == "off" then sv.rollAdvice = false
    elseif rest == "on" then sv.rollAdvice = true
    else sv.rollAdvice = (sv.rollAdvice == false) end
    Print(L["Roll advice: %s"]:format(sv.rollAdvice ~= false
        and L["|cff40ff40enabled|r"] or L["|cffff6060disabled|r"]))
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("QUEST_DETAIL")
f:RegisterEvent("QUEST_COMPLETE")
f:RegisterEvent("START_LOOT_ROLL")
f:RegisterEvent("CONFIRM_LOOT_ROLL")
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        -- BAG_UPDATE_DELAYED is confirmed in this client by PickItRight; it is
        -- still registered inside pcall, because an unknown event is an error.
        pcall(f.RegisterEvent, f, "BAG_UPDATE_DELAYED")
    elseif event == "QUEST_DETAIL" or event == "QUEST_COMPLETE" then
        afterDelay(0.2, function() pcall(ns.QuestAdvice) end)
    elseif event == "START_LOOT_ROLL" or event == "CONFIRM_LOOT_ROLL" then
        pcall(ns.RollAdvice, arg1)
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        ns.BagsEquipmentChanged()
    elseif event == "BAG_UPDATE_DELAYED" then
        pcall(ns.BagScan)
    end
end)
