-- Prices.lua ----------------------------------------------------------------
-- CS-5. Remembers the cheapest buyout the auction house has shown you for an
-- item, so the window can say "visto a 12g hace 2 días" and sort by gain per
-- gold.
--
-- This is a memory, not a scanner. Only what already passed across your screen
-- is stored (AUCTION_ITEM_LIST_UPDATE); a price you have not seen is not
-- invented and its cell stays empty. Reading the results is client API, not a
-- request of ours to the internet.
--
-- A price belongs to a purchase, and for an item that rolls a random suffix or
-- property the purchase is the item AND the roll: "Chestguard of the Bear" and
-- "Chestguard of the Monkey" share an itemID and are worth different amounts.
-- The identity is (itemID, rollId), taken from the link by S.LinkIdentity:
-- negative = suffix, positive = property, 0 = an item that does not roll.
-- Enchant, gems, uniqueID and level are not part of it. A rolling item whose
-- link names no roll has no identity and is ignored, never filed under 0.
--
-- Prices belong to the server, not to the character, so they live in the
-- account-wide LevelBiSDB, keyed by realm:
--     LevelBiSDB.prices[realm][itemID] = { v = { [tostring(rollId)] =
--                                           { c = copper per unit, t = time seen } } }
-- Gear does not stack, so there is no lot to model: `c` is per unit anyway.
--
-- The layout has its own revision, LevelBiSDB.priceSchema (absent = the first
-- layout, { c, t } straight under the itemID). It is not LevelBiSDB.schema,
-- which this file no longer writes.
------------------------------------------------------------------------------
local ADDON, ns = ...
local S = ns.Scoring

local KEEP_SECONDS = 30 * 24 * 3600   -- a month-old price is not a price
local SCHEMA = 2
local P = {}
ns.Prices = P

local function realm()
    return (GetRealmName and GetRealmName()) or "?"
end

local function now() return (time and time()) or 0 end

local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function validPrice(c) return finite(c) and c >= 1 end

local function whole(n) return finite(n) and n == math.floor(n) end

local function rollKey(rollId)
    if not whole(rollId) then return nil end
    return ("%d"):format(rollId)
end

-- "fixed" (does not roll), "random", or nil when the data does not know it.
local function kindOf(itemId)
    local item = ns.db and itemId and ns.db[itemId]
    if type(item) ~= "table" then return nil end
    if item.sg or item.pg then return "random" end
    return "fixed"
end

-- Is `roll` one this item can have? Fixed items have only 0; a suffix item
-- only negative rolls; a property item only positive ones.
local function rollFits(itemId, roll)
    local kind = kindOf(itemId)
    if kind == "fixed" then return roll == 0 end
    if kind ~= "random" then return false end
    local item = ns.db[itemId]
    if item.sg then return roll < 0 end
    return roll > 0
end

-- The storage key of a purchase, or nil when it has no valid identity.
-- Without a rollId only a fixed item qualifies: for a rolling item "the price"
-- does not exist, and answering with some roll's price would be a lie.
local function keyFor(itemId, rollId)
    if not whole(itemId) then return nil end
    local kind = kindOf(itemId)
    if rollId == nil then return kind == "fixed" and "0" or nil end
    if not whole(rollId) or not rollFits(itemId, rollId) then return nil end
    return rollKey(rollId)
end

local function InitDB()
    LevelBiSDB = type(LevelBiSDB) == "table" and LevelBiSDB or {}
    if type(LevelBiSDB.prices) ~= "table" then LevelBiSDB.prices = {} end
end

-- One saved record, in either layout, as a clean { v = {...} } or nil. Anything
-- that is not a positive finite price with a finite date is dropped.
--   * legacy { c, t }: only a fixed item can be placed (variant "0"). A rolling
--     item's record does not say which roll it was, and guessing -- above all
--     "the best one" -- would attach a price to a purchase nobody observed.
--   * current { v = { [key] = { c, t } } }: re-validated, so running this twice
--     changes nothing and a hand-damaged entry loses only its damaged part.
local function convert(itemId, entry)
    if type(entry) ~= "table" or not whole(itemId) then return nil end
    local kind = kindOf(itemId)
    if not kind then return nil end
    local out = {}
    if type(entry.v) == "table" then
        for key, var in pairs(entry.v) do
            local roll = tonumber(key)
            if whole(roll) and rollFits(itemId, roll) and type(var) == "table"
               and validPrice(var.c) and finite(var.t) then
                local k = rollKey(roll)
                local prev = out[k]
                if not prev or var.t > prev.t then
                    out[k] = { c = math.floor(var.c), t = var.t }
                end
            end
        end
    elseif kind == "fixed" and validPrice(entry.c) and finite(entry.t) then
        out["0"] = { c = math.floor(entry.c), t = entry.t }
    end
    if next(out) == nil then return nil end
    return { v = out }
end

-- Brings LevelBiSDB.prices to the current layout, once. It needs the item data
-- (to know which items roll); if that is not loaded -- or failed to load and is
-- empty -- it does nothing and tries again on the next use, so a data problem
-- can never be mistaken for "every item is unknown" and wipe the prices.
local function migrate()
    InitDB()
    if (tonumber(LevelBiSDB.priceSchema) or 1) >= SCHEMA then return true end
    if not (ns.db and next(ns.db)) then return false end
    for r, b in pairs(LevelBiSDB.prices) do
        if type(b) ~= "table" then
            LevelBiSDB.prices[r] = nil
        else
            local ids = {}
            for id in pairs(b) do ids[#ids + 1] = id end
            for _, id in ipairs(ids) do
                b[id] = convert(id, b[id])
            end
            if next(b) == nil then LevelBiSDB.prices[r] = nil end
        end
    end
    LevelBiSDB.priceSchema = SCHEMA
    return true
end

local function bucket(create)
    if not migrate() then return nil end
    local r = realm()
    local b = LevelBiSDB.prices[r]
    if type(b) ~= "table" then
        if not create then return nil end
        b = {}
        LevelBiSDB.prices[r] = b
    end
    return b
end

-- Drops every variant older than a month. Also done on each query (P.Get), so
-- a price does not outlive its month just because the session did.
local function prune()
    local b = bucket(false)
    if not b then return end
    local limit = now() - KEEP_SECONDS
    for id, entry in pairs(b) do
        if type(entry) ~= "table" or type(entry.v) ~= "table" then
            b[id] = nil
        else
            for key, var in pairs(entry.v) do
                if type(var) ~= "table" or not finite(var.t) or var.t < limit then
                    entry.v[key] = nil
                end
            end
            if next(entry.v) == nil then b[id] = nil end
        end
    end
end

-- One page of results: keep the cheapest per-unit buyout of each (item, roll)
-- the addon knows about. The latest sighting of a variant replaces the previous
-- one -- a price that went up is as much a fact as one that went down -- and
-- touches no other variant. An offer whose roll the link does not name is
-- ignored.
function P.Scan()
    if not (GetNumAuctionItems and GetAuctionItemInfo and GetAuctionItemLink and ns.db) then
        return 0
    end
    if not migrate() then return 0 end
    local n = GetNumAuctionItems("list") or 0
    local best = {}   -- best[id][key] = copper per unit
    for i = 1, n do
        local link = GetAuctionItemLink("list", i)
        local id, roll = S.LinkIdentity(link)
        local key = id and roll ~= nil and ns.db[id] and keyFor(id, roll)
        if key then
            -- Buyout is the tenth return since vanilla; count is the third.
            local _, _, count, _, _, _, _, _, _, buyout = GetAuctionItemInfo("list", i)
            if type(count) == "number" and count > 0 and type(buyout) == "number" and buyout > 0 then
                local each = math.floor(buyout / count)
                if validPrice(each) then
                    local row = best[id]
                    if not row then row = {}; best[id] = row end
                    if not row[key] or each < row[key] then row[key] = each end
                end
            end
        end
    end
    local b = bucket(true)
    if not b then return 0 end
    local stamp, seen = now(), 0
    for id, row in pairs(best) do
        local entry = b[id]
        if type(entry) ~= "table" or type(entry.v) ~= "table" then
            entry = { v = {} }
            b[id] = entry
        end
        for key, copper in pairs(row) do
            entry.v[key] = { c = copper, t = stamp }
            seen = seen + 1
        end
    end
    if seen > 0 and ns.UI and ns.UI.OnPricesChanged then ns.UI.OnPricesChanged() end
    return seen
end

-- copper, seconds since seen -- or nil when no price was ever seen, it has
-- expired, or the purchase has no identity (a rolling item without its roll).
function P.Get(itemId, rollId)
    local key = keyFor(itemId, rollId)
    if not key then return nil end
    local b = bucket(false)
    local entry = b and b[itemId]
    local var = type(entry) == "table" and type(entry.v) == "table" and entry.v[key]
    if type(var) ~= "table" or not validPrice(var.c) or not finite(var.t) then return nil end
    local age = now() - var.t
    if age > KEEP_SECONDS then
        entry.v[key] = nil
        if next(entry.v) == nil then b[itemId] = nil end
        return nil
    end
    return var.c, math.max(0, age)
end

function P.Money(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor(copper % 10000 / 100)
    local c = copper % 100
    if g > 0 then return s > 0 and ("%dg %ds"):format(g, s) or ("%dg"):format(g) end
    if s > 0 then return c > 0 and ("%ds %dc"):format(s, c) or ("%ds"):format(s) end
    return ("%dc"):format(c)
end

function P.Age(seconds)
    if seconds < 3600 then return "hace menos de una hora" end
    if seconds < 86400 then
        local h = math.floor(seconds / 3600)
        return h == 1 and "hace 1 hora" or ("hace %d horas"):format(h)
    end
    local d = math.floor(seconds / 86400)
    return d == 1 and "hace 1 día" or ("hace %d días"):format(d)
end

-- "visto a 12g hace 2 días", or nil.
function P.Line(itemId, rollId)
    local copper, age = P.Get(itemId, rollId)
    if not copper then return nil end
    return ("visto a %s %s"):format(P.Money(copper), P.Age(age))
end

-- What to show where the price goes: the line when there is a price, and for a
-- rolling item whose roll is known but never priced, a sentence that says so
-- instead of staying silent (or worse, showing another roll's price). Nothing
-- for a fixed item without price, for an item outside the data, or for a
-- rolling item with no concrete roll.
function P.Text(itemId, rollId)
    local line = P.Line(itemId, rollId)
    if line then return line end
    if rollId ~= nil and kindOf(itemId) == "random" and keyFor(itemId, rollId) then
        return "Precio de esta tirada: todavía sin observar"
    end
    return nil
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        InitDB()
        prune()
    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        pcall(P.Scan)
    end
end)
