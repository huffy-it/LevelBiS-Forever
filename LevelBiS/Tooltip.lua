-- Tooltip.lua ---------------------------------------------------------------
-- Global item marking: on any item tooltip (bags, loot, AH, vendor, chat
-- links), if the item is usable by the active spec, append its rank within its
-- slot for the current target level:  "LevelBiS: #N in slot for
-- <spec> at level <X>".
-- Toggle with the "Tooltip tags" checkbox or LevelBiSCharDB.settings.tooltip.
------------------------------------------------------------------------------
local ADDON, ns = ...
local L = ns.L
local S = ns.Scoring

local function rankColor(rank)
    if rank == 1 then return "|cff1eff00" end          -- best
    if rank <= 5 then return "|cffffd100" end          -- top 5
    if rank <= 15 then return "|cffffffff" end
    return "|cff808080"
end

-- Compute the LevelBiS line for a link, or nil if it shouldn't be marked.
-- DB item -> rank within its slot pool; otherwise live-scored vs equipped.
-- Shared by the tooltip hook and /lbis scan.
function ns.MarkFor(link)
    if not (ns.db and ns.playerClass and LevelBiSCharDB) then return nil end
    local id = tonumber((link or ""):match("item:(%d+)"))
    if not id then return nil end
    local tl = ns:TargetLevel()
    local filters = LevelBiSCharDB.settings.filters

    -- A link that already carries a suffix is a specific roll, and the client
    -- knows exactly what that roll gave, so it is scored on the stats it
    -- really has rather than on what the base item COULD roll.
    --
    -- One exception, and it is the addon's own link: when the roll on the link
    -- is the very roll this item was ranked as, the database answer is the
    -- right one and the rank line is what the reader wants. Without this, the
    -- window's own hover lost "best in slot" the moment the link
    -- started carrying the suffix.
    local linkSuffix = S.LinkSuffix(link)
    local dbItem = ns.db[id]
    local ownRoll = dbItem and linkSuffix
                    and linkSuffix == select(4, S.BestVariant(dbItem, ns.weights))
    if dbItem and (not linkSuffix or ownRoll) then
        local rank, score, slotName, effLevel =
            S.RankOf(id, tl, ns.weights, ns.playerClass, ns.playerLevel, filters, ns.tooltipSlot)
        if not rank then return nil end
        -- Rank 1 gets a word, not a number: "the best one" is the answer,
        -- "#1" is the answer's index. The score is left out on purpose -- the
        -- window and /lbis slot are where numbers belong.
        local where = (rank == 1) and L["best in slot"]
                      or L["%s#%d|r in slot"]:format(rankColor(rank), rank)
        if slotName == "mainhand" or slotName == "offhand" then
            where = where .. (slotName == "mainhand" and L[" (main hand)"] or L[" (off hand)"])
        end
        return ("|cff33ff99LevelBiS:|r " .. L["%s%s for %s at level %d"])
            :format((rank == 1) and rankColor(1) or "", where,
                    ns.activeSpec or "?", effLevel)
    end

    -- live path: item not in DB, score it from the client's stats
    local live = S.LiveItem(S.UnmodifiedLink(link))
    if not live then return nil end
    local hasStat = false
    for _ in pairs(live.st) do hasStat = true break end
    if not (hasStat or live.sk) then return nil end
    local effLevel = math.min(70, math.max(tl or 0, live.req or 0))
    if not S.CanUse(live, ns.playerClass, effLevel) then return nil end
    if not S.Recommendable(live, ns.playerClass, effLevel) then return nil end
    local slotName = ns.tooltipSlot or S.INVTYPE_SLOT[live.slot]
    if not slotName then return nil end
    if not S.SLOTS[slotName].inv[live.slot] then return nil end
    local required = S.RequiredHands(ns.playerClass, effLevel)
    if slotName == "mainhand" and ((required == "2h" and not S.TWO_HAND_INV[live.slot])
       or (required and required ~= "2h" and S.TWO_HAND_INV[live.slot])) then return nil end
    if slotName == "offhand" and ((required == "2h")
       or (required == "shield" and not S.SHIELD_INV[live.slot])
       or (required == "dual" and not S.OFFHAND_WEAPON_INV[live.slot])) then return nil end
    S.UseProfile(ns.weights); live.id = id
    local score = S.ScoreForSlot(live, ns.weights, S.SLOTS[slotName].slot, effLevel)
    if score <= 0 then return nil end
    local eq, _, _, _, state = S.EquippedScore(S.SLOTS[slotName].slot, ns.weights, effLevel)
    if state == "pending" then return "|cff33ff99LevelBiS:|r " .. L["Loading equipment…"] end
    if state == "unpriceable" then
        return "|cff33ff99LevelBiS:|r " .. L["Your current gear has no comparable value."]
    end
    eq = eq or 0
    local abs, pct = S.Delta(score, eq)
    -- A roll other than the one the window ranks (scored from the data with
    -- that exact roll), or an item outside the data (the client's own stats),
    -- against what you are wearing. One verdict, no arithmetic.
    local verdict
    if state == "empty" then
        verdict = "|cff40ff40" .. L["better than nothing: your slot is empty"] .. "|r"
    elseif abs > 0.5 then
        verdict = ("|cff40ff40" .. L["upgrade%s over what you have equipped"] .. "|r")
            :format(pct and L[" of %.0f%%"]:format(pct) or "")
    elseif abs < -0.5 then
        verdict = "|cffff6060" .. L["worse than what you have equipped"] .. "|r"
    else
        verdict = "|cff808080" .. L["same as what you have equipped"] .. "|r"
    end
    local origin = live._rolled and L["with this roll"] or L["outside the database"]
    return ("|cff33ff99LevelBiS:|r %s  |cff808080(%s)|r"):format(verdict, origin)
end

-- True if this tooltip already carries our line. Asking the tooltip itself is
-- the only reliable check: OnTooltipSetItem fires again on every rebuild (bag
-- items refresh while shown), and a rebuild wipes every line — so a remembered
-- flag would suppress the re-add and the line would vanish after a frame.
-- Exposed: the window's own hover adds sources too, and must not repeat what
-- this file already put on the tooltip.
local function alreadyMarked(tt)
    local name = tt.GetName and tt:GetName()
    if not name then return false end
    for i = 1, tt:NumLines() do
        local fs = _G[name .. "TextLeft" .. i]
        local txt = fs and fs:GetText()
        if txt and txt:find("LevelBiS:", 1, true) then return true end
    end
    return false
end

ns.TooltipMarked = function(tt) return alreadyMarked(tt) end

local function addMark(tt)
    if not tt or LevelBiSCharDB == nil then return end
    local settings = LevelBiSCharDB.settings
    if settings and settings.tooltip == false then return end
    if not tt.GetItem then return end
    local _, link = tt:GetItem()
    if not link then return end
    -- Re-entrancy guard: our own tt:Show() below can drive the tooltip through
    -- OnTooltipSetItem again before AddLine is visible to alreadyMarked, which
    -- showed up as a duplicated line on unique items.
    if tt.__lbisBusy or alreadyMarked(tt) then return end
    -- pcall: a bug in scoring must never break the game's tooltip.
    local ok, text = pcall(ns.MarkFor, link)
    if not ok or type(text) ~= "string" then return end
    tt.__lbisBusy = true
    tt:AddLine(text)
    local weaponID = tonumber(link:match("item:(%d+)"))
    local weapon = weaponID and ns.db and ns.db[weaponID]
    if weapon then
        local slot = ns.tooltipSlot or S.INVTYPE_SLOT[weapon.slot]
        local note = S.WeaponNote(weapon, ns.weights, S.SLOTS[slot] and S.SLOTS[slot].slot)
        if note then tt:AddLine(note, 0.8, 0.8, 0.8, true) end
    end
    -- For an item that has not rolled yet, say which roll the rank assumes and
    -- what it gives. Without this the tooltip rates a shoulder you are looking
    -- at in the auction house by a suffix it may not have, and the client's own
    -- stat block -- the base item's -- is empty.
    local rollId = tonumber(link:match("item:(%d+)"))
    local rolled = rollId and ns.db and ns.db[rollId]
    -- Only when the link does NOT already carry the roll: if it does, the
    -- client has drawn the real stats a few lines above this one.
    if rolled and not S.LinkSuffix(link) and ns.RollLines then
        local okRoll, roll = pcall(ns.RollLines, rolled)
        if okRoll and roll then
            for i = 1, #roll do tt:AddLine(roll[i], 1, 1, 1, true) end
        end
    end
    -- A set piece is worth what the rest of the set makes it worth, so the
    -- tooltip says how much of it you have on and what the next threshold
    -- gives. The client's own set block lists the pieces; this one answers
    -- "is putting this on worth anything to me right now".
    if rolled and rolled.set and ns.SetLines then
        local okSet, setLines = pcall(ns.SetLines, rolled)
        if okSet and setLines then
            for i = 1, #setLines do tt:AddLine(setLines[i], 1, 1, 1, true) end
        end
    end
    -- Where it comes from is the other half of the answer, and a tooltip in the
    -- auction house or a loot window is exactly where you need it. Capped at
    -- three lines: an item with sixteen drop rows would push the tooltip off
    -- the screen, and the window's own hover shows the full list.
    if settings and settings.tooltipSrc ~= false and ns.SrcLines then
        local id = tonumber(link:match("item:(%d+)"))
        local item = id and ns.db and ns.db[id]
        if item then
            local okSrc, lines = pcall(ns.SrcLines, item)
            if okSrc and type(lines) == "table" then
                for i = 1, math.min(#lines, 3) do tt:AddLine(lines[i], 1, 1, 1, true) end
                if #lines > 3 then
                    tt:AddLine(("|cff808080" .. L["and %d more source(s)"] .. "|r"):format(#lines - 3))
                end
            end
        end
    end
    -- M-15: why it is an upgrade, in one line. The live path already says so in
    -- its own verdict, so this is only for what that line leaves unsaid.
    if not text:find(L["over what you have equipped"], 1, true) and ns.ReasonLine then
        local okReason, reason = pcall(ns.ReasonLine, link)
        if okReason and reason then tt:AddLine("|cff808080" .. reason .. "|r", 1, 1, 1, true) end
    end
    -- M-1: the reward this addon would pick for the open quest.
    local pickId = tonumber(link:match("item:(%d+)"))
    if pickId and ns.questPick and ns.questPick[pickId] then
        -- Advisor's line is L["Choose %s: %s."]; its start, up to the first %s,
        -- is what the pattern anchors on, in whichever language is loaded.
        local lead = (L["Choose %s: %s."]:match("^(.-)%%s") or ""):gsub("%p", "%%%0")
        local this = L["Choose this one:"]:gsub("%%", "%%%%")
        tt:AddLine("|cff33ff99" .. ns.questPick[pickId]:gsub("|H.-|h(.-)|h", "%1")
                   :gsub("^" .. lead .. "[^:]*:", this) .. "|r")
    end
    -- The price this addon has seen for it, if the auction house ever showed
    -- one. Never a guess: no sighting, no line.
    -- The price is the one of the roll this tooltip shows: a link without its
    -- roll on a rolling item has none to look up.
    local priceId, priceRoll = S.LinkIdentity(link)
    local priceLine = priceId and ns.Prices and ns.Prices.Text(priceId, priceRoll)
    if priceLine then tt:AddLine("|cff808080" .. priceLine .. "|r") end
    tt:Show() -- re-fit after adding a line
    tt.__lbisBusy = nil
end

local function hook(tt)
    if not tt then return end
    tt:HookScript("OnTooltipSetItem", addMark)
end

local ef = CreateFrame("Frame")
ef:RegisterEvent("PLAYER_LOGIN")
ef:SetScript("OnEvent", function()
    hook(GameTooltip)
    hook(ItemRefTooltip)
    hook(ShoppingTooltip1)
    hook(ShoppingTooltip2)
end)
