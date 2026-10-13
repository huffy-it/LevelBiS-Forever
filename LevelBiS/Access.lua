-- Access.lua ----------------------------------------------------------------
-- Personal access: which routes to an item THIS character can still use.
--
-- "Reachable" used to mean the level a source opens at. It now also means the
-- reputation you hold is enough and the quest route is not exhausted. Three
-- parts, kept apart on purpose:
--
--   1. Client adapters  (ReadFaction, ReadQuest): the only code that touches
--      the client API. Absent API, bad answer or error -> nil, never a thrown
--      error and never a guess.
--   2. Evidence cache   (state): refreshed from events, in bursts, and at login.
--      Ranking, tooltips and the window read ONLY this cache, so a hover or a
--      refresh never calls the client.
--   3. Evaluation       (RouteStatus, ItemStatus): pure functions of a route and
--      the cache. "unknown" is a third answer: it never blocks, and it is never
--      read as "zero reputation" or "quest not done".
--
-- The access revision (A.Revision) rises only when relevant evidence changes.
-- It belongs in every cache key whose answer depends on access.
--
-- Rules (documented in SPEC.md):
--   * Reputation is a requirement of the ITEM, checked when it is bought. It is
--     stamped (rf = faction, rr = required standing 1..8) onto the VENDOR
--     routes of an item that carries repf, and nowhere else. A drop or a quest
--     route of the same item stays open. Only the "Reachable" filter uses it.
--   * A quest route is exhausted only if it carries id and once=1 and the
--     client says that quest is completed. A quest in the log is not completed.
--   * A route marked ev (the pipeline proved the source exists only while a
--     calendar festivity runs: Brewfest, Hallow's End, Winter Veil, Darkmoon
--     Faire...) is closed unless that event is CONFIRMED active. The client
--     calendar (C_Calendar) was investigated and is not used: see SPEC.md. No
--     code reads it, so today no event is confirmed and every ev route is
--     closed; A.SetEventActive is the single place where a reliable reader would
--     write, and the rule already honours it. Unknown never opens a route.
--   * An item you wear or carry, or one that can be bought at the auction house
--     (bound on equip or on use), is never restricted by access.
------------------------------------------------------------------------------
local ADDON, ns = ...
local L = ns.L
local A = {}
ns.Access = A

local DEBOUNCE = 0.5          -- seconds: one refresh per burst of events

------------------------------------------------------------------------------
-- Standing scale (one place, tested)
------------------------------------------------------------------------------
-- cmangos SharedDefines.h ReputationRank: HATED=0 HOSTILE=1 UNFRIENDLY=2
-- NEUTRAL=3 FRIENDLY=4 HONORED=5 REVERED=6 EXALTED=7. The client's standingID
-- (GetFactionInfoByID, 3rd return) is 1=Hated ... 8=Exalted: one more. The
-- pipeline emits cmangos' number untouched in `repr`; this is the only place
-- that converts it.
A.MIN_STANDING, A.MAX_STANDING = 1, 8

function A.StandingFromCmangos(rank)
    if type(rank) ~= "number" or rank ~= math.floor(rank) or rank < 0 or rank > 7 then
        return nil
    end
    return rank + 1
end

local LABEL_EN = { L["Hated"], L["Hostile"], L["Unfriendly"], L["Neutral"], L["Friendly"],
                   L["Honored"], L["Revered"], L["Exalted"] }

-- The client's own word when it has one (FACTION_STANDING_LABEL1..8), so the
-- text matches the language of the game; the English name otherwise.
function A.StandingLabel(standing)
    local global = _G and _G["FACTION_STANDING_LABEL" .. tostring(standing)]
    if type(global) == "string" and global ~= "" then return global end
    return LABEL_EN[standing] or "?"
end

------------------------------------------------------------------------------
-- Evidence cache
------------------------------------------------------------------------------
local state = {
    standing = {},    -- [factionID] = 1..8, or false (asked, unknown)
    names = {},       -- [factionID] = localized name
    done = {},        -- [questID]   = true (sticky) or false; nil = never read
    owned = {},       -- [itemID]    = true: worn or in the bags
    events = {},      -- [eventID]   = true (confirmed active) | false; nil = unknown
}
A.state = state
local watch = { factions = {}, quests = {}, questSet = {}, sensitive = {} }
local revision = 0
local errors = {}     -- [api] = message; each failure is kept once, not repeated

function A.Revision() return revision end

local function remember(api, message)
    if errors[api] == nil then errors[api] = tostring(message) end
end
function A.Errors() return errors end

------------------------------------------------------------------------------
-- Client adapters
------------------------------------------------------------------------------
-- 2.5.x (Gethe/wow-ui-source, branch classic_anniversary): GetFactionInfoByID
-- is the global every Classic client has; C_QuestLog.IsQuestFlaggedCompleted
-- exists in the generated API documentation of that branch (QuestLog system)
-- and GetQuestsCompleted is the older table form. Whatever is missing is nil.

-- name, standingID (1..8) for a faction, or nil when the client has no answer
-- (API absent, faction unknown to this character, standingID 0 = unknown).
function A.ReadFaction(factionID)
    local fn = GetFactionInfoByID
    if type(fn) ~= "function" then return nil end
    local ok, name, _, standing = pcall(fn, factionID)
    if not ok then remember("GetFactionInfoByID", name) return nil end
    if type(standing) ~= "number" or standing < A.MIN_STANDING
       or standing > A.MAX_STANDING then
        return nil
    end
    return name, standing
end

-- Which quest API this client offers, in the order they are tried.
function A.QuestAPI()
    if type(C_QuestLog) == "table" and type(C_QuestLog.IsQuestFlaggedCompleted) == "function" then
        return "namespace"
    elseif type(IsQuestFlaggedCompleted) == "function" then
        return "global"
    elseif type(GetQuestsCompleted) == "function" then
        return "table"
    end
    return nil
end

-- true / false for a quest, nil when the client cannot say. `bulk` is the table
-- GetQuestsCompleted returned for this pass (only used by the "table" variant).
function A.ReadQuest(questID, bulk)
    local api = A.QuestAPI()
    if api == "table" then
        if type(bulk) ~= "table" then return nil end
        return bulk[questID] == true
    elseif api == nil then
        return nil
    end
    local ok, result
    if api == "namespace" then
        ok, result = pcall(C_QuestLog.IsQuestFlaggedCompleted, questID)
    else
        ok, result = pcall(IsQuestFlaggedCompleted, questID)
    end
    if not ok then remember("IsQuestFlaggedCompleted", result) return nil end
    if result == true or result == 1 then return true end
    if result == false then return false end
    return nil
end

local function readBulk()
    if A.QuestAPI() ~= "table" then return nil end
    local ok, result = pcall(GetQuestsCompleted)
    if not ok then remember("GetQuestsCompleted", result) return nil end
    return type(result) == "table" and result or nil
end

------------------------------------------------------------------------------
-- Reading the cache
------------------------------------------------------------------------------
-- Standing 1..8, or nil (unknown). Unknown is never zero.
function A.Reputation(factionID)
    local value = state.standing[factionID]
    return type(value) == "number" and value or nil
end

-- true / false / nil (unknown or not tracked).
function A.QuestCompleted(questID)
    return state.done[questID]
end

-- true only when the festival is CONFIRMED active; false (confirmed over) and
-- nil (never read) are both "not confirmed". Nothing reads the client today.
function A.EventActive(eventID)
    return state.events[eventID]
end

-- English name of a game_event the pipeline marks (data/game_event.entry), so
-- the sentence reads "Only during Brewfest". These are the names the enUS
-- client uses for the holidays: "Winter Veil", "Hallow's End", "Brewfest" and
-- "Darkmoon Faire". The three Darkmoon Faire events are one fair in three
-- cities. An event the pipeline starts marking without an entry here reads "a
-- seasonal event": add its verified name, a test checks the data against this
-- list.
local EVENT_PHRASE = {
    [2]  = L["Winter Veil"],
    [12] = L["Hallow's End"],
    [26] = L["Brewfest"],
    [78] = L["Darkmoon Faire"],
    [81] = L["Darkmoon Faire"],
    [84] = L["Darkmoon Faire"],
}
A.EVENT_PHRASE = EVENT_PHRASE

-- "Only during <event>" for a seasonal route or source, nil otherwise.
function A.SeasonNote(route)
    if not (route and route.ev) then return nil end
    return L["Only during %s"]:format(EVENT_PHRASE[route.ev] or L["a seasonal event"])
end

function A.Owns(itemID)
    return itemID ~= nil and state.owned[itemID] == true
end

------------------------------------------------------------------------------
-- Evaluation
------------------------------------------------------------------------------
-- "allowed" | "blocked" | "unknown", and a reason:
--   blocked  "seasonal" | "reputation" | "questDone"
--   unknown  "repUnknown" | "questUnknown"
--   allowed  "repOk" | "questOpen" | nil (nothing to check)
function A.RouteStatus(route)
    if not route then return "allowed" end
    -- Seasonal: closed unless the event is confirmed active. The other checks
    -- still apply when it is (a vendor in the event can ask for reputation).
    if route.ev and A.EventActive(route.ev) ~= true then
        return "blocked", "seasonal"
    end
    if route.rf and route.rr then
        local have = A.Reputation(route.rf)
        if have == nil then return "unknown", "repUnknown" end
        if have >= route.rr then return "allowed", "repOk" end
        return "blocked", "reputation"
    end
    if route.t == "quest" and route.once and route.id then
        local done = A.QuestCompleted(route.id)
        if done == true then return "blocked", "questDone" end
        if done == nil then return "unknown", "questUnknown" end
        return "allowed", "questOpen"
    end
    return "allowed"
end

-- Over every route of the item, access only (level and content filters are not
-- here): "allowed" if some route is allowed, "unknown" if none is but one could
-- be, "blocked" when every route is. An item with no routes is "allowed": the
-- absence of a source is not a fact.
function A.ItemStatus(item)
    local routes = item and (item.routes or item.src)
    if not routes or #routes == 0 then return "allowed" end
    local unknown, reason
    for _, route in ipairs(routes) do
        local status, why = A.RouteStatus(route)
        if status == "allowed" then return "allowed", why end
        if status == "unknown" then unknown = true end
        reason = reason or why
    end
    if unknown then return "unknown", "unknown" end
    return "blocked", reason
end

-- Words for a route, from the cache. nil when there is nothing worth saying:
-- an unread quest says nothing (there are over a thousand), an unread
-- reputation says it needs confirming.
function A.RouteNote(route)
    if not route then return nil end
    if route.rf and route.rr then
        local who = state.names[route.rf] or L["faction %s"]:format(tostring(route.rf))
        local text = L["Requires %s with %s"]:format(A.StandingLabel(route.rr), who)
        local have = A.Reputation(route.rf)
        if have then
            return text .. L[" · you have %s"]:format(A.StandingLabel(have))
        end
        return text .. L[" · personal access to confirm"]
    end
    if route.t == "quest" and route.once and route.id
       and A.QuestCompleted(route.id) == true then
        return L["Quest already completed"]
    end
    return nil
end

------------------------------------------------------------------------------
-- Data marking (once, when the database loads)
------------------------------------------------------------------------------
-- Stamps, on sources and routes:
--   once  on quest sources, from the route with the same id (the display list
--         does not carry it: the data would grow for nothing)
--   rf/rr on VENDOR sources and routes of an item with repf: faction and the
--         client-scale standing it needs. A requirement of "Hated" is trivially
--         met and is not stamped.
-- and collects what the cache has to watch. Returns the number of stamps.
function A.MarkRoutes(db)
    local factions, quests = {}, {}
    watch = { factions = {}, quests = {}, questSet = {}, sensitive = {}, seasonalRoutes = 0 }
    local stamped = 0
    local seasonal = 0
    for id, item in pairs(db or {}) do
        local onceById
        local sensitive = false
        for _, route in ipairs(item.routes or {}) do
            if route.ev then
                sensitive = true
                seasonal = seasonal + 1
            end
            if route.t == "quest" and route.id and route.once then
                onceById = onceById or {}
                onceById[route.id] = true
                if not watch.questSet[route.id] then
                    watch.questSet[route.id] = true
                    quests[#quests + 1] = route.id
                end
                sensitive = true
            end
        end
        if onceById then
            for _, src in ipairs(item.src or {}) do
                if src.t == "quest" and onceById[src.id] and not src.once then
                    src.once = 1
                    stamped = stamped + 1
                end
            end
        end
        local required = item.repf and A.StandingFromCmangos(item.repr or 0)
        if required and required > A.MIN_STANDING then
            local hit = false
            for _, list in ipairs({ item.src or {}, item.routes or {} }) do
                for _, s in ipairs(list) do
                    if s.t == "vendor" then
                        s.rf, s.rr = item.repf, required
                        stamped = stamped + 1
                        hit = true
                    end
                end
            end
            if hit then
                sensitive = true
                if not factions[item.repf] then
                    factions[item.repf] = true
                    watch.factions[#watch.factions + 1] = item.repf
                end
            end
        end
        if sensitive then
            item.acc = 1
            watch.sensitive[id] = true
        end
    end
    watch.quests = quests
    watch.seasonalRoutes = seasonal
    table.sort(watch.factions)
    table.sort(watch.quests)
    return stamped
end

-- How many routes of the loaded data carry ev.
function A.SeasonalRoutes()
    return watch.seasonalRoutes or 0
end

function A.Watching()
    return #watch.factions, #watch.quests
end

-- Copies of what the cache watches: faction IDs and one-time quest IDs.
function A.WatchedIDs()
    local factions, quests = {}, {}
    for i, id in ipairs(watch.factions) do factions[i] = id end
    for i, id in ipairs(watch.quests) do quests[i] = id end
    return factions, quests
end

------------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------------
local pending = { faction = false, quest = false, owned = false }
local timerPending = false
local needsNotify = false

-- Relevant evidence changed: a new revision, and everything that was computed
-- with the old one goes. Cheap and immediate; repainting waits for the burst.
local function bump()
    revision = revision + 1
    needsNotify = true
    local S = ns.Scoring
    if S and S.ClearLifetimeCache then S.ClearLifetimeCache() end
    if ns.UI and ns.UI.OnAccessChanged then ns.UI.OnAccessChanged() end
end

-- The one writer of event evidence (it sits here because it needs bump). A
-- route stays closed until this says true; a change in what is confirmed is a
-- change of access revision.
function A.SetEventActive(eventID, active)
    if type(eventID) ~= "number" then return end
    if active ~= true and active ~= false then active = nil end
    if state.events[eventID] == active then return end
    state.events[eventID] = active
    bump()
end

local function refreshFactions()
    local changed = false
    for _, id in ipairs(watch.factions) do
        local name, standing = A.ReadFaction(id)
        local new = standing or false
        if (state.standing[id] or false) ~= new then changed = true end
        state.standing[id] = new
        if name then state.names[id] = name end
    end
    return changed
end

local function refreshQuests()
    if A.QuestAPI() == nil then return false end
    local changed = false
    local bulk = readBulk()
    for _, id in ipairs(watch.quests) do
        -- A completed quest stays completed: a late or empty answer from the
        -- client must not reopen a route.
        if state.done[id] ~= true then
            local value = A.ReadQuest(id, bulk)
            if value ~= nil and state.done[id] ~= value then
                state.done[id] = value
                changed = true
            end
        end
    end
    return changed
end

local function refreshOwned()
    local S = ns.Scoring
    local now = {}
    if S and S.EquippedItemID then
        for slot = 0, 19 do
            local ok, id = pcall(S.EquippedItemID, slot)
            if ok and id then now[id] = true end
        end
    end
    if ns.ContainerAPI then
        local okAPI, numSlots, itemLink = pcall(ns.ContainerAPI)
        if okAPI and numSlots and itemLink then
            for bag = 0, 4 do
                local okN, n = pcall(numSlots, bag)
                for slot = 1, (okN and tonumber(n) or 0) do
                    local okL, link = pcall(itemLink, bag, slot)
                    local id = okL and type(link) == "string"
                               and tonumber(link:match("item:(%d+)"))
                    if id then now[id] = true end
                end
            end
        end
    end
    -- Only an item whose routes depend on access can change the answer.
    local changed = false
    for id in pairs(now) do
        if not state.owned[id] and watch.sensitive[id] then changed = true end
    end
    for id in pairs(state.owned) do
        if not now[id] and watch.sensitive[id] then changed = true end
    end
    state.owned = now
    return changed
end

-- Brings the cache up to date now. `which` limits it ("faction", "quest",
-- "owned"); nil does all three. Returns whether the revision rose.
function A.Refresh(which)
    local changed = false
    if not which or which == "faction" then changed = refreshFactions() or changed end
    if not which or which == "quest" then changed = refreshQuests() or changed end
    if not which or which == "owned" then changed = refreshOwned() or changed end
    if changed then bump() end
    return changed
end

local function notify()
    if not needsNotify then return end
    needsNotify = false
    if ns.UI and ns.UI.AccessRefresh then ns.UI.AccessRefresh() end
end

local function after(seconds, fn)
    if C_Timer and C_Timer.After then C_Timer.After(seconds, fn) else fn() end
end

-- Event bursts (a quest turn-in fires several log updates, a loot pass many
-- bag updates) become one refresh and one repaint.
local function run()
    timerPending = false
    local ok, err = pcall(function()
        if pending.faction then pending.faction = false; A.Refresh("faction") end
        if pending.quest then pending.quest = false; A.Refresh("quest") end
        if pending.owned then pending.owned = false; A.Refresh("owned") end
    end)
    if not ok then remember("refresh", err) end
    notify()
end

function A.Request(kind)
    pending[kind] = true
    if timerPending then return end
    timerPending = true
    after(DEBOUNCE, run)
end

-- QUEST_TURNED_IN names the quest: that is evidence by itself.
function A.NoteCompleted(questID)
    if type(questID) ~= "number" or not watch.questSet[questID] then return end
    if state.done[questID] == true then return end
    state.done[questID] = true
    bump()
    A.Request("quest")   -- one repaint, and the log reconciles the rest
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------
local f = CreateFrame("Frame")
-- An event the client does not know is an error when registered.
for _, event in ipairs({ "PLAYER_LOGIN", "UPDATE_FACTION", "QUEST_TURNED_IN",
                         "QUEST_LOG_UPDATE", "PLAYER_EQUIPMENT_CHANGED",
                         "BAG_UPDATE_DELAYED" }) do
    pcall(f.RegisterEvent, f, event)
end
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        local ok, err = pcall(function() A.Refresh(); notify() end)
        if not ok then remember("login", err) end
    elseif event == "UPDATE_FACTION" then
        A.Request("faction")
    elseif event == "QUEST_TURNED_IN" then
        A.NoteCompleted(arg1)
    elseif event == "QUEST_LOG_UPDATE" then
        A.Request("quest")
    else -- gear or bags
        A.Request("owned")
    end
end)

------------------------------------------------------------------------------
-- /lbis access
------------------------------------------------------------------------------
-- What this client offers and what the cache holds: the thing to read when a
-- route is blocked or open and it should not be.
ns.ExtraCmd = ns.ExtraCmd or {}
ns.ExtraCmd.access = function(rest)
    local print_ = ns.Print or print
    if (rest or ""):lower() == "refresh" then
        A.Refresh()
        notify()
    end
    local known, total = 0, #watch.factions
    for _, id in ipairs(watch.factions) do
        if A.Reputation(id) then known = known + 1 end
    end
    local done, tracked = 0, #watch.quests
    for _, id in ipairs(watch.quests) do
        if state.done[id] == true then done = done + 1 end
    end
    print_(L["personal access, revision %d."]:format(revision))
    print_(L["  reputation: %s, %d of %d factions read."]:format(
        type(GetFactionInfoByID) == "function" and "GetFactionInfoByID" or L["no API"],
        known, total))
    print_(L["  quests: %s, %d of %d one-time quests completed."]:format(
        A.QuestAPI() or L["no API"], done, tracked))
    local confirmed = 0
    for _, active in pairs(state.events) do
        if active == true then confirmed = confirmed + 1 end
    end
    print_(L["  season: %d event routes; the calendar is not read, so they are closed under \"Reachable\" except for %d confirmed event(s)."]:format(
        A.SeasonalRoutes(), confirmed))
    local failed = false
    for api, message in pairs(errors) do
        failed = true
        print_(L["  %s error: %s"]:format(api, message))
    end
    if not failed then print_(L["  no client errors."]) end
    print_(L["  /lbis access refresh re-reads the client."])
end
