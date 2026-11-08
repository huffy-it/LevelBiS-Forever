-- Compat.lua ----------------------------------------------------------------
-- WoW: Forever runs the modern (Mainline) client, Interface 16001. Every call
-- into the client whose name or shape differs from the Classic one goes
-- through here, so the rest of the addon asks one question in one place.
--
-- Seen in the client on 7/11/2026 (build 1.60.1.70862): the globals
-- GetItemStats, GetItemInfo, GetTalentTabInfo, GetNumTalentTabs,
-- GetSpecialization, GetFactionInfoByID, GetSkillLineInfo, GetAuctionItemInfo
-- and GetSpellInfo do NOT exist; C_Item.GetItemStats, TooltipDataProcessor,
-- C_AuctionHouse, C_Reputation.GetFactionDataByID, C_Traits,
-- C_SpecializationInfo, GetProfessions and GetCombatRating do.
--
-- Each function is looked up when it is called, never cached at load: a test
-- (or another addon) that replaces a client function must be seen, and a
-- function the client does not have answers nil instead of raising.
------------------------------------------------------------------------------
local ADDON, ns = ...

-- The level cap. Forever stops at 60 for good; every "last level" in the
-- addon reads this instead of a number.
ns.MAX_LEVEL = 60

local API = {}
ns.API = API

-- A callable from a client namespace, or nil. Anything callable counts (the
-- test harness hands in host functions, which Lua sees as userdata).
local function callable(f)
    local kind = type(f)
    return (kind == "function" or kind == "userdata" or kind == "table") and f or nil
end

local function fn(space, name)
    local t = _G[space]
    return type(t) == "table" and callable(t[name]) or nil
end

------------------------------------------------------------------------------
-- Items
------------------------------------------------------------------------------
-- Same returns as the old global: name, link, quality, ilvl, required level,
-- type, subtype, stack, equip location, icon, sell price, classID, subclassID,
-- bind type... Asynchronous the first time (nil until GET_ITEM_INFO_RECEIVED).
function API.ItemInfo(item)
    if item == nil then return nil end
    local f = fn("C_Item", "GetItemInfo") or callable(GetItemInfo)
    if not f then return nil end
    return f(item)
end

-- { ITEM_MOD_*_SHORT = n, EMPTY_SOCKET_* = n, ... } for a link, or nil.
function API.ItemStats(link)
    local f = fn("C_Item", "GetItemStats") or callable(GetItemStats)
    if not (f and link) then return nil end
    return f(link)
end

function API.ItemIcon(id)
    if not id then return nil end
    local f = fn("C_Item", "GetItemIconByID") or callable(GetItemIcon)
    local icon = f and f(id)
    if icon then return icon end
    return (select(10, API.ItemInfo(id)))
end

function API.HasEquipItem()
    return (fn("C_Item", "EquipItemByName") or callable(EquipItemByName)) ~= nil
end

-- Equips a link, in a slot when given. Returns false when the client has no
-- way to do it, true when the call was made.
function API.EquipItem(link, slotID)
    local f = fn("C_Item", "EquipItemByName") or callable(EquipItemByName)
    if not f then return false end
    local ok = pcall(f, link, slotID)
    if not ok then pcall(f, link) end
    return true
end

------------------------------------------------------------------------------
-- Spells
------------------------------------------------------------------------------
-- The localized name of a spell, or nil.
function API.SpellName(spellID)
    local name = fn("C_Spell", "GetSpellName")
    if name then return name(spellID) end
    local info = fn("C_Spell", "GetSpellInfo")
    if info then
        local t = info(spellID)
        return type(t) == "table" and t.name or nil
    end
    if callable(GetSpellInfo) then return (GetSpellInfo(spellID)) end
    return nil
end

------------------------------------------------------------------------------
-- Reputation
------------------------------------------------------------------------------
-- name, standing (1 = Hated ... 8 = Exalted) or nil. C_Reputation answers a
-- table; `reaction` is the standing on the same 1..8 scale the old third
-- return used. Raises when the client does: the caller wraps it in pcall to
-- remember the failure.
function API.HasFactionData()
    return fn("C_Reputation", "GetFactionDataByID") ~= nil
end

function API.FactionStanding(factionID)
    local f = fn("C_Reputation", "GetFactionDataByID")
    if not f then return nil end
    local data = f(factionID)
    if type(data) ~= "table" then return nil end
    return data.name, data.reaction
end

------------------------------------------------------------------------------
-- Professions
------------------------------------------------------------------------------
-- { { name = localized, rank = n, skillLine = id }, ... } for every profession
-- the character has (the primary two, cooking, fishing, first aid...), or nil
-- when the client has no GetProfessions. GetProfessionInfo's seventh value is
-- the skill line ID, which does not depend on the language.
function API.Professions()
    if type(GetProfessions) ~= "function" or type(GetProfessionInfo) ~= "function" then
        return nil
    end
    local out = {}
    local indices = { GetProfessions() }
    -- GetProfessions returns nil holes for missing professions, so the table
    -- length is not reliable: walk the fixed number of positions it can fill.
    for i = 1, 6 do
        local index = indices[i]
        if index then
            local name, _, rank, _, _, _, skillLine = GetProfessionInfo(index)
            if name then
                out[#out + 1] = { name = name, rank = tonumber(rank) or 0,
                                  skillLine = tonumber(skillLine) }
            end
        end
    end
    return out
end

------------------------------------------------------------------------------
-- Specialization
------------------------------------------------------------------------------
-- index (1..n), specID, name of the active specialization; nil when the
-- client has none chosen yet (a fresh character) or no such API.
function API.ActiveSpec()
    local get = fn("C_SpecializationInfo", "GetSpecialization")
    local info = fn("C_SpecializationInfo", "GetSpecializationInfo")
    if not get then return nil end
    local index = tonumber(get())
    if not index or index < 1 then return nil end
    local id, name
    if info then id, name = info(index) end
    return index, tonumber(id), name
end

function API.NumSpecs()
    local f = fn("C_SpecializationInfo", "GetNumSpecializations")
    return f and tonumber(f()) or nil
end

-- Active talent group (dual specialization): 1 or 2. Not confirmed which of
-- these the Forever client has, so all are tried in order.
function API.TalentGroup()
    local f = fn("C_SpecializationInfo", "GetActiveSpecGroup")
              or callable(GetActiveSpecGroup)
              or callable(GetActiveTalentGroup)
    if not f then return 1 end
    return tonumber(f()) or 1
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------
-- The modern client raises on an event it does not know, and several names
-- changed or are unconfirmed in Forever. Each one is tried on its own; the
-- ones that took are returned as a set.
function API.RegisterEvents(frame, ...)
    local took = {}
    for i = 1, select("#", ...) do
        local event = select(i, ...)
        if pcall(frame.RegisterEvent, frame, event) then took[event] = true end
    end
    return took
end

------------------------------------------------------------------------------
-- Tooltips
------------------------------------------------------------------------------
-- OnTooltipSetItem no longer exists; every item tooltip (bags, loot, chat
-- links, comparison tooltips) goes through TooltipDataProcessor. `handler`
-- receives the tooltip and the tooltip data. Returns true when hooked.
function API.HookItemTooltips(handler)
    local add = fn("TooltipDataProcessor", "AddTooltipPostCall")
    local kind = type(Enum) == "table" and type(Enum.TooltipDataType) == "table"
                 and Enum.TooltipDataType.Item
    if not (add and kind ~= nil) then return false end
    add(kind, handler)
    return true
end

------------------------------------------------------------------------------
-- Auction house (C_AuctionHouse, AuctionHouseFrame)
------------------------------------------------------------------------------
function API.AuctionOpen()
    local f = AuctionHouseFrame
    return type(f) == "table" and type(f.IsShown) == "function" and f:IsShown() or false
end

-- Can this client search the auction house by name from outside its frame?
function API.CanSearchAuction()
    local f = AuctionHouseFrame
    local bar = type(f) == "table" and f.SearchBar
    return type(bar) == "table" and type(bar.SearchBox) == "table"
           and type(bar.SearchBox.SetText) == "function"
           and type(bar.StartSearch) == "function"
end

-- Types the name into the auction house's own search box and starts the
-- search there, so the results land where the player is looking. Raises if
-- the frame refuses: the caller wraps it in pcall.
function API.SearchAuction(name)
    local f = AuctionHouseFrame
    if type(f.SetDisplayMode) == "function" and type(AuctionHouseFrameDisplayMode) == "table"
       and AuctionHouseFrameDisplayMode.Buy then
        f:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
    end
    f.SearchBar.SearchBox:SetText(name)
    f.SearchBar:StartSearch()
end

-- The offers of one item the auction house is showing (after the player
-- opened it): { { link =, count =, buyout = total copper }, ... }.
function API.ItemSearchResults(itemKey)
    local num = fn("C_AuctionHouse", "GetNumItemSearchResults")
    local get = fn("C_AuctionHouse", "GetItemSearchResultInfo")
    local out = {}
    if not (num and get and itemKey) then return out end
    for i = 1, (tonumber(num(itemKey)) or 0) do
        local r = get(itemKey, i)
        if type(r) == "table" then
            out[#out + 1] = { link = r.itemLink, count = r.quantity, buyout = r.buyoutAmount }
        end
    end
    return out
end

-- The browse list (one line per item): { { id =, suffix =, each = copper }, ... }.
-- `minPrice` is per unit. `suffix` is the item key's own field; whether it is
-- the random suffix of the link is not confirmed, so the caller only trusts
-- lines where it is absent or zero.
function API.BrowseResults()
    local get = fn("C_AuctionHouse", "GetBrowseResults")
    local out = {}
    if not get then return out end
    for _, r in ipairs(get() or {}) do
        local key = type(r) == "table" and r.itemKey
        if type(key) == "table" and key.itemID then
            out[#out + 1] = { id = key.itemID, suffix = key.itemSuffix, each = r.minPrice }
        end
    end
    return out
end

function API.HasAuctionHouse()
    return fn("C_AuctionHouse", "GetItemSearchResultInfo") ~= nil
           or fn("C_AuctionHouse", "GetBrowseResults") ~= nil
end
