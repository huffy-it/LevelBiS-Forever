-- Scoring.lua ---------------------------------------------------------------
-- Item eligibility (class/level/armor/weapon), weighted scoring, per-slot
-- ranking, and 2H vs 1H+offhand comparison. Reads the static DB at ns.db.
------------------------------------------------------------------------------
local ADDON, ns = ...
local S = {}
ns.Scoring = S

-- Armor subclasses
local ARMOR_MISC, ARMOR_CLOTH, ARMOR_LEATHER, ARMOR_MAIL, ARMOR_PLATE = 0, 1, 2, 3, 4
local ARMOR_SHIELD = 6
local RELIC_SUB = { [7]="PALADIN", [8]="DRUID", [9]="SHAMAN", [10]="DEATHKNIGHT" } -- libram/idol/totem/sigil

-- Item classes
local IC_WEAPON, IC_ARMOR = 2, 4

local SHIELD_USERS = { WARRIOR=true, PALADIN=true, SHAMAN=true }

-- Class/race restriction bits, matching item.cls / item.race from the pipeline
-- (absent on unrestricted items). Lua 5.1 has no bitwise operators, so the bit
-- test is arithmetic.
local CLASS_BIT = {
    WARRIOR=1, PALADIN=2, HUNTER=4, ROGUE=8, PRIEST=16,
    SHAMAN=64, MAGE=128, WARLOCK=256, DRUID=1024,
}
local RACE_BIT = {
    Human=1, Orc=2, Dwarf=4, NightElf=8, Scourge=16,
    Tauren=32, Gnome=64, Troll=128, BloodElf=512, Draenei=1024,
}

------------------------------------------------------------------------------
-- Dual wield
------------------------------------------------------------------------------
-- Who may hold a weapon in the off hand, and from what level. This is a
-- declared list for the same reason PVP_VENDORS is: the proof lives in
-- SkillLineAbility.dbc and the talent trees, neither of which is in the world
-- DB. It is short, it does not change, and every line is checkable in game.
--
-- What it fixes: the off-hand row was offering a one-handed sword to a
-- paladin, who cannot dual wield at all, and to a protection warrior, who
-- wants a shield. A recommendation you are unable to equip is worse than an
-- empty row.
--
-- The shaman is the only one whose dual wield is a talent rather than a
-- trainer skill: Enhancement, five tiers in, so twenty points, so level forty.
local DUAL_WIELD = {
    ROGUE   = { level = 10 },
    WARRIOR = { level = 20 },
    HUNTER  = { level = 20 },
    SHAMAN  = { level = 40, spec = "Enhancement" },
}

function S.CanDualWield(classToken, level, spec)
    local rule = DUAL_WIELD[classToken]
    if not rule then return false end
    if (level or 0) < rule.level then return false end
    if rule.spec and (spec or ns.activeSpec) ~= rule.spec then return false end
    return true
end

------------------------------------------------------------------------------
-- What a spec is required to hold
------------------------------------------------------------------------------
-- Some specs do not get to choose. Their defining talent names the weapon, and
-- a weighted sum has no way to say "this ability does not work without a
-- two-hander". Left to the numbers, the comparison told an arms warrior to
-- dual wield -- giving up Mortal Strike -- and told a protection warrior to
-- put a sword where his shield goes, because a weapon's damage outscores a
-- shield's armour on any scale that prices damage at all.
--
-- Each line names the talent that forces it, and the level at which that
-- talent becomes reachable; below that level the spec is not yet committed and
-- the comparison is left to decide on score, as it does for everyone else.
--
--   2h      the main hand must be a two-handed weapon, and nothing beside it
--   shield  the off hand must be a shield
--   dual    the off hand must be a weapon
local SPEC_WEAPON = {
    WARRIOR = {
        ["Arms"]       = { want = "2h",     level = 40 },  -- Mortal Strike
        ["Protection"] = { want = "shield", level = 10 },  -- Shield Slam, Shield Block
        ["Fury"]       = { want = "dual",   level = 20 },  -- Dual Wield Specialization
    },
    PALADIN = {
        ["Retribution"] = { want = "2h",     level = 30 }, -- Two-Handed Weapon Specialization
        ["Protection"]  = { want = "shield", level = 10 }, -- Holy Shield
    },
    SHAMAN = {
        ["Enhancement"] = { want = "dual", level = 40 },   -- Dual Wield
    },
    ROGUE = {
        ["Assassination"] = { want = "dual", level = 10 }, -- rogues always dual wield
        ["Combat"]        = { want = "dual", level = 10 },
        ["Subtlety"]      = { want = "dual", level = 10 },
    },
}

-- "2h", "shield", "dual", or nil when the spec is free to choose.
function S.RequiredHands(classToken, level, spec)
    local byClass = SPEC_WEAPON[classToken]
    local rule = byClass and byClass[spec or ns.activeSpec or ""]
    if not rule or (level or 0) < rule.level then return nil end
    if rule.want ~= "shield" and not S.CanDualWield(classToken, level, spec)
       and rule.want == "dual" then
        return nil          -- cannot dual wield yet, so it is not required
    end
    return rule.want
end

-- Inventory types that are a weapon rather than a shield or a held item.
local OFFHAND_WEAPON_INV = {
    INVTYPE_WEAPON = true, INVTYPE_WEAPONOFFHAND = true,
}
local ONE_HAND_INV = {
    INVTYPE_WEAPON = true, INVTYPE_WEAPONMAINHAND = true,
}
S.TWO_HAND_INV = { INVTYPE_2HWEAPON = true }
S.ONE_HAND_INV = ONE_HAND_INV
S.SHIELD_INV = { INVTYPE_SHIELD = true }
S.OFFHAND_WEAPON_INV = OFFHAND_WEAPON_INV

local function hasBit(mask, bit)
    if not mask or not bit then return true end -- unrestricted, or unknown token
    return math.floor(mask / bit) % 2 == 1
end

-- Highest armor subclass a class may wear, and the level it unlocks it.
-- { base = subclass usable from level 1, upg = higher subclass, upgLvl = level }
local ARMOR_RULE = {
    PRIEST  = { base=ARMOR_CLOTH },
    MAGE    = { base=ARMOR_CLOTH },
    WARLOCK = { base=ARMOR_CLOTH },
    ROGUE   = { base=ARMOR_LEATHER },
    DRUID   = { base=ARMOR_LEATHER },
    HUNTER  = { base=ARMOR_LEATHER, upg=ARMOR_MAIL,  upgLvl=40 },
    SHAMAN  = { base=ARMOR_LEATHER, upg=ARMOR_MAIL,  upgLvl=40 },
    WARRIOR = { base=ARMOR_MAIL,    upg=ARMOR_PLATE, upgLvl=40 },
    PALADIN = { base=ARMOR_MAIL,    upg=ARMOR_PLATE, upgLvl=40 },
}

-- Allowed weapon subclasses per class (TBC proficiencies).
-- 0 axe1h,1 axe2h,2 bow,3 gun,4 mace1h,5 mace2h,6 polearm,7 sword1h,8 sword2h,
-- 10 staff,13 fist,15 dagger,16 thrown,18 crossbow,19 wand
local function set(...) local t = {} for _, v in ipairs({...}) do t[v] = true end return t end
local WEAPON_ALLOW = {
    WARRIOR = set(0,1,4,5,7,8,6,10,13,15,2,3,18,16),
    PALADIN = set(0,1,4,5,7,8,6),
    HUNTER  = set(0,1,7,8,6,10,13,15,2,3,18,16),
    ROGUE   = set(4,7,15,13,2,3,18,16),
    PRIEST  = set(4,15,10,19),
    SHAMAN  = set(0,1,4,5,10,13,15),
    MAGE    = set(7,15,10,19),
    WARLOCK = set(7,15,10,19),
    DRUID   = set(4,5,10,13,15),
}

------------------------------------------------------------------------------
-- Slot definitions: name -> { slot = inventorySlotID, inv = {INVTYPE=true} }
------------------------------------------------------------------------------
local function invset(...) local t = {} for _, v in ipairs({...}) do t[v] = true end return t end
S.SLOTS = {
    head     = { slot=1,  inv=invset("INVTYPE_HEAD") },
    neck     = { slot=2,  inv=invset("INVTYPE_NECK") },
    shoulder = { slot=3,  inv=invset("INVTYPE_SHOULDER") },
    chest    = { slot=5,  inv=invset("INVTYPE_CHEST","INVTYPE_ROBE") },
    waist    = { slot=6,  inv=invset("INVTYPE_WAIST") },
    legs     = { slot=7,  inv=invset("INVTYPE_LEGS") },
    feet     = { slot=8,  inv=invset("INVTYPE_FEET") },
    wrist    = { slot=9,  inv=invset("INVTYPE_WRIST") },
    hands    = { slot=10, inv=invset("INVTYPE_HAND") },
    finger1  = { slot=11, inv=invset("INVTYPE_FINGER") },
    finger2  = { slot=12, inv=invset("INVTYPE_FINGER") },
    trinket1 = { slot=13, inv=invset("INVTYPE_TRINKET") },
    trinket2 = { slot=14, inv=invset("INVTYPE_TRINKET") },
    back     = { slot=15, inv=invset("INVTYPE_CLOAK") },
    mainhand = { slot=16, inv=invset("INVTYPE_WEAPON","INVTYPE_WEAPONMAINHAND","INVTYPE_2HWEAPON") },
    offhand  = { slot=17, inv=invset("INVTYPE_WEAPONOFFHAND","INVTYPE_SHIELD","INVTYPE_HOLDABLE","INVTYPE_WEAPON") },
    ranged   = { slot=18, inv=invset("INVTYPE_RANGED","INVTYPE_RANGEDRIGHT","INVTYPE_THROWN","INVTYPE_RELIC","INVTYPE_WAND") },
}
-- ordered list for iteration (17 slots)
S.SLOT_ORDER = {
    "head","neck","shoulder","chest","waist","legs","feet","wrist","hands",
    "finger1","finger2","trinket1","trinket2","back","mainhand","offhand","ranged",
}
S.SLOT_ALIAS = { cloak="back", ring="finger1", ring1="finger1", ring2="finger2",
                 trinket="trinket1", weapon="mainhand", mh="mainhand", oh="offhand",
                 wrists="wrist", bracers="wrist", gloves="hands", boots="feet",
                 belt="waist", helm="head", finger="finger1" }

function S.ResolveSlot(name)
    name = tostring(name or ""):lower()
    return S.SLOTS[name] and name or S.SLOT_ALIAS[name]
end

-- Hunters can equip thrown weapons, but their ranged rotation requires a
-- bow, gun or crossbow. Auto Shot (75), Arcane Shot (3044) and Steady Shot
-- (34120) have EquippedItemSubClassMask=262156 in cmangos spell_template:
-- subclasses 2, 3 and 18. Keep this separate from equip proficiency.
function S.Recommendable(item, classToken, level, spec)
    if classToken == "ROGUE" and (spec or ns.activeSpec) == "Assassination"
       and (level or ns.playerLevel or 0) >= 50 and item.ic == IC_WEAPON
       and not (item.slot == "INVTYPE_RANGED" or item.slot == "INVTYPE_RANGEDRIGHT"
                or item.slot == "INVTYPE_THROWN") then
        return item.sc == 15 -- Mutilar: EquippedItemSubClassMask=32768.
    end
    return not (classToken == "HUNTER" and item.slot == "INVTYPE_THROWN")
end

-- INVTYPE -> the canonical slot name whose ranking pool an item belongs to.
S.INVTYPE_SLOT = {
    INVTYPE_HEAD="head", INVTYPE_NECK="neck", INVTYPE_SHOULDER="shoulder",
    INVTYPE_CHEST="chest", INVTYPE_ROBE="chest", INVTYPE_WAIST="waist",
    INVTYPE_LEGS="legs", INVTYPE_FEET="feet", INVTYPE_WRIST="wrist",
    INVTYPE_HAND="hands", INVTYPE_FINGER="finger1", INVTYPE_TRINKET="trinket1",
    INVTYPE_CLOAK="back",
    INVTYPE_2HWEAPON="mainhand", INVTYPE_WEAPON="mainhand", INVTYPE_WEAPONMAINHAND="mainhand",
    INVTYPE_WEAPONOFFHAND="offhand", INVTYPE_SHIELD="offhand", INVTYPE_HOLDABLE="offhand",
    INVTYPE_RANGED="ranged", INVTYPE_RANGEDRIGHT="ranged", INVTYPE_THROWN="ranged",
    INVTYPE_RELIC="ranged", INVTYPE_WAND="ranged",
}

------------------------------------------------------------------------------
-- Slot index
--
-- The static DB holds ~10.7k items. Scanning all of them per query was fine
-- against the old synthetic fixture but is not: RankSlot runs once per slot on
-- every UI refresh, and RankOf runs on every single tooltip hover. Indexing the
-- DB once by slot pool turns each of those into a scan of only the few hundred
-- items that could ever fill that slot.
------------------------------------------------------------------------------
local slotIndex          -- [slotName] = { itemID, ... }
local lifetimeKey, lifetimeResult -- one on-demand result, never a growing cache

local fixedAltKey, fixedAltResult -- the open detail's fixed alternative (one entry)

function S.ClearLifetimeCache()
    lifetimeKey, lifetimeResult = nil, nil
    fixedAltKey, fixedAltResult = nil, nil
end

-- One INVTYPE can feed several pools (a 1H weapon ranks for both mainhand and
-- offhand; a ring for both finger slots), so this is built from SLOTS.inv.
local function invToSlots()
    local map = {}
    for name, def in pairs(S.SLOTS) do
        for inv in pairs(def.inv) do
            map[inv] = map[inv] or {}
            table.insert(map[inv], name)
        end
    end
    return map
end

local function buildIndex()
    slotIndex = {}
    for name in pairs(S.SLOTS) do slotIndex[name] = {} end
    local map = invToSlots()
    for id, item in pairs(ns.db or {}) do
        local names = item.slot and map[item.slot]
        if names then
            for _, name in ipairs(names) do
                local pool = slotIndex[name]
                pool[#pool + 1] = id
            end
        end
    end
end

-- Items in the pool for `slotName`, building the index on first use.
local function slotPool(slotName)
    if not slotIndex then buildIndex() end
    return slotIndex[slotName] or {}
end

-- Call when ns.db is replaced.
-- A new database means new items behind the same ids, so the score caches go
-- with the slot index. The reset itself lives below, next to the caches it
-- clears; the locals it touches are not in scope up here.
function S.InvalidateIndex()
    if S.ForgetInstanceLevels then S.ForgetInstanceLevels() end
    slotIndex = nil
    S.ClearLifetimeCache()
    if S.ForgetScores then S.ForgetScores() end
end

------------------------------------------------------------------------------
-- PvP vendors
------------------------------------------------------------------------------
-- A battleground quartermaster stands in Hillsbrad or in Ashenvale, not inside
-- a battleground, so the map he is on reads "open world" and his gear walked
-- straight past the "no PvP" filter -- eight of the slots a level 67 character
-- was told to fill with pre-TBC gear were Arathi Basin and Warsong Gulch sets.
-- The proof the pipeline would need is the currency (honor, marks of honor,
-- spirit shards), and that lives in ItemExtendedCost.dbc, which is not in the
-- world DB. So this is an explicit declared list, the same kind of override as
-- the 12 map names in build_db.py, and every entry was checked against what it
-- actually sells in the generated data.
--
-- A reputation quartermaster is deliberately NOT here: those items carry
-- `repf` (Logistics Officer Ulrike sells the Honor Hold sets for reputation,
-- not for honor), and calling them PvP would hide them behind a filter that is
-- on by default.
local PVP_VENDORS = {
    [12781] = true,   -- Master Sergeant Biggins          Insignia of the Alliance
    [12793] = true,   -- Brave Stonehide                  Insignia of the Horde
    [14753] = true,   -- Illiyana Moonblaze               Silverwing Sentinels (WSG)
    [14754] = true,   -- Kelm Hargunth                    Warsong Outriders (WSG)
    [15126] = true,   -- Rutherford Twing                 The Defilers (AB)
    [15127] = true,   -- Samuel Hawke                     League of Arathor (AB)
    [18266] = true,   -- Warrant Officer Tracy Proudwell  Hellfire towers
    [18267] = true,   -- Battlecryer Blackeye             Hellfire towers
    [18564] = true,   -- Horde Field Scout                Halaa / Spirit Towers
    [18581] = true,   -- Alliance Field Scout             Halaa / Spirit Towers
}

-- Every legendary in vanilla and TBC comes out of a raid: Sulfuras from Molten
-- Core, Thunderfury from Blackwing Lair, Atiesh from forty Naxxramas
-- fragments, the Warglaives and the six Tempest Keep weapons from their own
-- raids. Thirteen of the sixteen reach the addon with no content on their
-- source, because a legendary is assembled by a quest or dropped by a
-- script-summoned object rather than looted from a boss with a spawn point --
-- so "Sin raid" did not hide them, and a level 68 mage was being told his best
-- staff was Atiesh. Quality 5 is the proof the data does carry.
function S.MarkLegendaries(db)
    local n = 0
    for _, item in pairs(db or {}) do
        if item.q == 5 and item.src then
            for _, sources in ipairs({item.src, item.routes or {}}) do
                for _, src in ipairs(sources) do
                    if not src.ct then src.ct = "raid"; n = n + 1 end
                end
            end
        end
    end
    return n
end

-- Stamps ct="pvp" on the vendor sources above. One pass over the DB when it is
-- loaded, never from a hot path. A source that already carries a `ct` is left
-- alone: what the pipeline could resolve outranks this list. Returns how many
-- sources were marked.
function S.MarkPvPVendors(db)
    local n = 0
    for _, item in pairs(db or {}) do
        for _, src in ipairs({item.src or {}, item.routes or {}}) do
            for _, s in ipairs(src) do
                if s.t == "vendor" and not s.ct and s.npc and PVP_VENDORS[s.npc] then
                    s.ct = "pvp"
                    n = n + 1
                end
            end
        end
    end
    return n
end

------------------------------------------------------------------------------
-- Server phase (M-7)
------------------------------------------------------------------------------
-- cmangos models the game as of 2.4.3 and knows nothing about TBC Anniversary's
-- release phases, so everything that exists in the data is "available". These
-- two tables are DECLARED by hand, like PVP_VENDORS, and say what opens later:
--
--   PHASE.inst  the raid or dungeon, by the English name the data carries in
--               `inst`, and the phase it opens in. Anything not listed counts as
--               phase 1: leveling content and Karazhan, Gruul and Magtheridon.
--   PHASE.repf  a reputation whose gear exists only from a phase on. The
--               Shattered Sun Offensive (1077) is the Isle of Quel'Danas.
--
-- Not tracked, because the data has no handle for them: reputation vendors and
-- badge gear of the later phases, arena seasons.
S.PHASE = {
    inst = {
        ["Serpentshrine Cavern"] = 2, ["The Eye"] = 2,
        ["Hyjal Summit"] = 3, ["Black Temple"] = 3,
        ["Zul'Aman"] = 4,
        ["Sunwell Plateau"] = 5, ["Magisters' Terrace"] = 5,
    },
    repf = { [1077] = 5 },
}
S.PHASE_NAMES = {
    [1] = "Karazhan", [2] = "SSC y El Ojo", [3] = "BT y Hyjal",
    [4] = "Zul'Aman", [5] = "Sunwell",
}
-- Open on the server today: Black Temple and Hyjal, since 27/8/2026. Updated by
-- hand in every release; Zul'Aman and the Sunwell have only estimated dates.
S.CURRENT_PHASE = 3

local ROUTE_KEYS = { "t", "id", "ct", "side", "prof", "skill", "access", "diff", "u" }
local function sameRoute(a, b)
    for _, k in ipairs(ROUTE_KEYS) do
        if a[k] ~= b[k] then return false end
    end
    return true
end

-- Stamps `ph` on sources and routes, once, when the data loads. Routes carry no
-- instance name, so a route takes the earliest phase among the visible sources
-- that match it field for field; a route with no matching source has no
-- evidence and stays unmarked. Returns how many entries were marked.
function S.MarkPhases(db)
    local marked = 0
    for _, item in pairs(db or {}) do
        local repPhase = item.repf and S.PHASE.repf[item.repf]
        local function phaseOf(src)
            local p = src.inst and S.PHASE.inst[src.inst] or nil
            if repPhase then p = math.max(p or 1, repPhase) end
            return p
        end
        for _, src in ipairs(item.src or {}) do
            local p = phaseOf(src)
            if p then src.ph = p; marked = marked + 1 end
        end
        for _, route in ipairs(item.routes or {}) do
            local least
            for _, src in ipairs(item.src or {}) do
                if sameRoute(route, src) then
                    local p = src.ph or 1
                    if not least or p < least then least = p end
                end
            end
            if repPhase and not least then least = repPhase end
            if least and least > 1 then route.ph = least; marked = marked + 1 end
        end
    end
    return marked
end

-- The phase an item first becomes available in: the earliest of its routes.
function S.ItemPhase(item)
    local least
    for _, route in ipairs(item.routes or {}) do
        local p = route.ph or 1
        if not least or p < least then least = p end
    end
    return least
end

------------------------------------------------------------------------------
-- Eligibility
------------------------------------------------------------------------------
-- `strict` recommends only the class's top armor tier. A warrior CAN equip
-- leather, so the permissive rule is technically right, but scoring ignores
-- armor value entirely, so a leather piece with good strength would outrank
-- plate and get recommended to a plate wearer. Callers fall back to the
-- permissive rule when the strict pool for a slot comes out empty.
local function armorAllowed(classToken, level, sc, strict)
    local r = ARMOR_RULE[classToken]
    if not r then return true end
    local top = r.base
    if r.upg and level >= (r.upgLvl or 999) then top = r.upg end
    if strict then return sc == top end
    return sc <= top -- can always wear lower armor tiers
end

-- Can the given class (at `level`) equip this item at all? (ignores slot/req)
function S.CanUse(item, classToken, level, strictArmor)
    -- Hard class/race gates from the item itself come first: no amount of
    -- armor proficiency lets a warrior equip a warlock-only orb.
    if item.cls and not hasBit(item.cls, CLASS_BIT[classToken]) then return false end
    if item.race and not hasBit(item.race, RACE_BIT[ns.playerRace]) then return false end
    if item.ic == IC_ARMOR then
        local sc = item.sc or ARMOR_MISC
        if sc >= ARMOR_CLOTH and sc <= ARMOR_PLATE then
            return armorAllowed(classToken, level, sc, strictArmor)
        elseif sc == ARMOR_SHIELD then
            return SHIELD_USERS[classToken] == true
        elseif RELIC_SUB[sc] then
            return RELIC_SUB[sc] == classToken
        end
        return true -- cloak/neck/ring/trinket/misc: no proficiency gate
    elseif item.ic == IC_WEAPON then
        local allow = WEAPON_ALLOW[classToken]
        return allow ~= nil and allow[item.sc] == true
    end
    return true
end

------------------------------------------------------------------------------
-- Scoring (+ cache keyed by a profile hash)
------------------------------------------------------------------------------
S._cache = {}         -- [profileHash][itemID] = score
S._variantCache = {}  -- [profileHash][itemID] = { bonus, suffix name, stats }
S._socketCache = {}   -- [profileHash][itemID] = S.SocketInfo result, or false
S._gemCache = {}      -- [profileHash] = S.GemTable result (best gems per color)
local curHash, curCache, variantCache   -- variantCache: [itemID] = { bonus, suffix, stats }
local socketCache                       -- [itemID] = socket info, for the active profile

-- "Score only what is guaranteed": the roll of a random-suffix item is left
-- out entirely, so a piece whose base carries no stats -- which is most of
-- them -- falls to nothing and drops off the list, while a piece that has
-- stats of its own keeps exactly those. It is off by default, because between
-- level 61 and 69 the gear that rolls outnumbers the gear that does not by
-- four to one, and hiding it would hide the answer.
local ignoreRandom = false
function S.SetIgnoreRandom(value)
    value = value and true or false
    if value ~= ignoreRandom then
        ignoreRandom = value
        -- The scores cached under the old setting are not the scores now.
        curHash, curCache, variantCache, socketCache = nil, nil, nil, nil
    end
end

local function hashWeights(weights)
    local keys = {}
    for k in pairs(weights) do keys[#keys+1] = k end
    table.sort(keys)
    local buf = {}
    for _, k in ipairs(keys) do buf[#buf+1] = k .. "=" .. tostring(weights[k]) end
    return table.concat(buf, ";") .. (ignoreRandom and "|fixed" or "")
end

-- Point the cache at the active profile. Call before a batch of Score() calls.
function S.UseProfile(weights)
    curHash = hashWeights(weights)
    curCache = S._cache[curHash]
    if not curCache then curCache = {}; S._cache[curHash] = curCache end
    variantCache = S._variantCache[curHash]
    if not variantCache then variantCache = {}; S._variantCache[curHash] = variantCache end
    socketCache = S._socketCache[curHash]
    if not socketCache then socketCache = {}; S._socketCache[curHash] = socketCache end
    S._activeWeights = weights
end

-- Drop every cached score (all profiles). Called when the DB is replaced.
function S.ForgetScores()
    S._cache, S._variantCache = {}, {}
    S._socketCache, S._gemCache = {}, {}
    curCache, variantCache, socketCache, curHash = nil, nil, nil, nil
    S.ClearLifetimeCache()
end

function S.InvalidateProfile(weights)
    local hash = hashWeights(weights)
    S._cache[hash] = nil
    S._variantCache[hash] = nil
    S._socketCache[hash] = nil
    S._gemCache[hash] = nil
    if weights == S._activeWeights then
        curCache, variantCache, socketCache, curHash = nil, nil, nil, nil
    end
end

-- Raw weighted sum. Uses the active profile's cache when available.
-- Ranged weapons carry their damage in the same `dps` field as melee ones --
-- the slot is what tells the two apart. A hunter values a bow's damage far
-- above a sword's, so the `rdps` weight replaces `dps` in these slots, and
-- falls back to `dps` for the profiles that do not set it.
local RANGED_SLOT = {
    INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true,
}

-- Weighted sum of one stat table. Iterating the stats rather than the weights
-- is deliberate: an item carries a handful, a profile carries all 33.
local function weighted(st, weights, ranged)
    if not st then return 0 end
    local total = 0
    for k, v in pairs(st) do
        local w
        if ranged and k == "dps" then
            w = weights.rdps or weights.dps
        else
            w = weights[k]
        end
        if w then total = total + w * v end
    end
    return total
end

------------------------------------------------------------------------------
-- Random suffixes and random properties
------------------------------------------------------------------------------
-- Half the gear a character can actually reach in Outland is a random-suffix
-- green or blue: "Warmaul Epaulets of the Bear". The base item has no stats at
-- all, so before this existed the window compared a level 68 character's real
-- options against zero and answered with a level 50 quest green -- the only
-- thing left in the slot that carried numbers.
--
-- The pipeline gives each such item the group it rolls from (`sg`) and its own
-- budget (`sf`); Data/random.lua holds the allocation percentages, shared by
-- every item that rolls the same suffix. A stat is
--
--     floor(allocation * sf / 10000)
--
-- Random *properties* (`pg`, the older vanilla system) carry finished numbers
-- and need no arithmetic.
--
-- What gets scored is the BEST roll for the active weights, not an average:
-- the roll is what you shop for on the auction house, and naming it is the
-- useful half of the answer. Everything that shows a suffixed item says which
-- suffix it means.

-- Stats one suffix grants on one item. nil when the item does not roll.
function S.SuffixStats(item, suffixId)
    local suf = ns.suffix and ns.suffix[suffixId]
    if not suf or not item.sf then return nil end
    local st, any = {}, false
    for k, pct in pairs(suf.a) do
        local v = math.floor(pct * item.sf / 10000)
        if v > 0 then st[k] = v; any = true end
    end
    if not any then return nil end
    return st, suf.n
end

-- Best roll for `weights`: extra score, suffix name, its stat table, and the
-- suffix id (negative in an item link, which is how the client is asked to
-- spell the rolled name). Returns 0 for an item that does not roll at all.
function S.BestVariant(item, weights)
    weights = weights or S._activeWeights
    if not weights or not item or ignoreRandom then return 0 end
    local cacheable = variantCache and item.id and weights == S._activeWeights
    if cacheable then
        local c = variantCache[item.id]
        if c then return c[1], c[2], c[3], c[4] end
    end
    local ranged = RANGED_SLOT[item.slot]
    local bestScore, bestName, bestSt, bestId = 0, nil, nil, nil
    if item.sg and ns.suffixGroup then
        for _, sid in ipairs(ns.suffixGroup[item.sg] or {}) do
            local st, name = S.SuffixStats(item, sid)
            if st then
                local sc = weighted(st, weights, ranged)
                if sc > bestScore then
                    bestScore, bestName, bestSt, bestId = sc, name, st, -sid
                end
            end
        end
    elseif item.pg and ns.propertyGroup then
        for _, pid in ipairs(ns.propertyGroup[item.pg] or {}) do
            local prop = ns.property and ns.property[pid]
            if prop and prop.st then
                local sc = weighted(prop.st, weights, ranged)
                if sc > bestScore then
                    -- A random property is positive in a link, a suffix is
                    -- negative. Same field, opposite sign.
                    bestScore, bestName, bestSt, bestId = sc, prop.n, prop.st, pid
                end
            end
        end
    end
    if cacheable then
        variantCache[item.id] = { bestScore, bestName, bestSt, bestId }
    end
    return bestScore, bestName, bestSt, bestId
end

-- The roll's stats as "+38 sta, +25 str", in STAT_KEYS order so two items
-- read alike. The caller supplies the labels; this is the raw shape.
function S.VariantStatList(st)
    if not st then return nil end
    local out = {}
    for _, key in ipairs(ns.STAT_KEYS) do
        if st[key] then out[#out + 1] = { key, st[key] } end
    end
    if #out == 0 then return nil end
    return out
end

-- Name to show for an item, with the suffix it is being scored as.
function S.VariantName(item, weights)
    if not item then return nil end
    local name = item.n
    local _, suffix = S.BestVariant(item, weights)
    if suffix then return (name or "?") .. " " .. suffix, suffix end
    return name
end

------------------------------------------------------------------------------
-- Sockets
------------------------------------------------------------------------------
-- Real gems and enchants count on neither side of a comparison (see
-- S.UnmodifiedLink), but the sockets themselves do: a piece with two sockets
-- is worth more than the same piece without them, and ignoring that made the
-- addon call a 46-point item an upgrade over Sha'tari Wrought Greaves, whose
-- two sockets and bonus are worth another 17 points to a Fury warrior.
--
-- Every socket is priced with the best gem for the ACTIVE WEIGHTS, on both the
-- recommended and the equipped side, as Pawn does when "ignore sockets on
-- low-level items" is on:
--
--   * only on an item with item level >= SOCKET_MIN_ILVL. Below it the gems a
--     player puts in are not worth the cost of the socket, and Pawn leaves
--     them out too. It is the item level, not the player's level.
--   * the gem tier follows the item: item level >= SOCKET_EPIC_ILVL (Black
--     Temple and later, where players use epic cuts) prices with the best of
--     all rare and epic gems; anything below with the best rare gem. Sunwell
--     gems carry no phase evidence (they come from vendors and crafts that
--     name no instance), so none is held back by S.CURRENT_PHASE.
--   * for a colored socket, either the best gem of that color, summed over the
--     sockets and added to the value of the socket bonus (the "proper" way:
--     every gem matches and the bonus is active), or the best gem of any color
--     in every socket with no bonus (the "mismatched" way); whichever is worth
--     more. A gem satisfies a socket when its color mask includes the socket's
--     bit, so an orange gem fills red and yellow.
--   * a meta socket takes the best meta gem on its own. Only the plain stat of
--     a meta gem is priced; its special effect and its activation
--     requirement are not.
--
-- Everything is a function of the item and the weights, so it is cached per
-- weights hash next to the other score caches (UseProfile, InvalidateProfile
-- and ForgetScores handle it) and sits inside the cached part of S.Score.
--
-- Other paths, decided one by one:
--   * S.LevelScaleAdjustment and S.HitCapAdjustment add the ratings of the
--     ideal gems and bonus to those of the item, so a rating is scaled and
--     capped the same whether it comes from the item or from its sockets.
--   * S.StatsValue prices consumables, not gear; sockets do not apply.
--   * S.WeaponAdjustment is about swing speed and damage; sockets do not apply.
--   * The detail's stat changes (UI detailStats) list the item's own stats on
--     purpose: the ideal gems are a hypothesis, not a stat the item has.
S.SOCKET_MIN_ILVL = 100
S.SOCKET_EPIC_ILVL = 151

local SOCKET_META = 1
local SOCKET_ANY = 14  -- prismatic socket, and "a gem of any color"
local SOCKET_CODES = { 2, 4, 8, SOCKET_ANY }
local SOCKET_COLOR_WORD = {  -- for the explain line, feminine plural
    [2] = "rojas", [4] = "amarillas", [8] = "azules", [14] = "de cualquier color",
}

local GEM_TIER_MAX = { rare = 3, epic = 4 }  -- highest gem quality of each tier

local function betterGem(cur, value, id)
    return not cur or value > cur.value or (value == cur.value and id < cur.id)
end

-- Best gem per socket code and tier for `weights`:
--   { rare = { [2]=gem, [4]=gem, [8]=gem, [14]=gem }, epic = { ... }, meta = gem }
-- where gem = { value, st, id, n }. A missing entry means no gem of that kind
-- is worth anything with these weights. The epic tier also accepts rare gems:
-- nothing stops you putting one in an item that deserves better, and it keeps
-- a stat that has no epic cut (a purple dodge gem) from falling out. Ties go
-- to the lower item id so the result never depends on table order.
local function buildGemTable(weights)
    local gems = { rare = {}, epic = {} }
    for id, gem in pairs(ns.gems or {}) do
        local value = weighted(gem.st, weights)
        if value > 0 then
            local entry = { value = value, st = gem.st, id = id, n = gem.n }
            if gem.c == SOCKET_META then
                if betterGem(gems.meta, value, id) then gems.meta = entry end
            else
                for tier, maxQuality in pairs(GEM_TIER_MAX) do
                    if (gem.q or 3) <= maxQuality then
                        for _, code in ipairs(SOCKET_CODES) do
                            if code == SOCKET_ANY or hasBit(gem.c, code) then
                                if betterGem(gems[tier][code], value, id) then
                                    gems[tier][code] = entry
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return gems
end

function S.GemTable(weights)
    weights = weights or S._activeWeights
    if not weights then return { rare = {}, epic = {} } end
    local cacheable = curHash and weights == S._activeWeights
    if cacheable and S._gemCache[curHash] then return S._gemCache[curHash] end
    local gems = buildGemTable(weights)
    if cacheable then S._gemCache[curHash] = gems end
    return gems
end

-- What the sockets of an item add for `weights`, or nil when they add nothing
-- (no sockets, item level below the cut-off, or no gem worth anything):
--   value   points added to the score
--   stats   the stats of the chosen gems and, if used, the socket bonus
--   mode    "proper" (gems match the sockets, bonus active) or "mismatched"
--   tier    "rare" or "epic"
--   colored, metas   how many sockets of each kind
--   bonus   value of the socket bonus (only when mode is "proper")
--   picks   the chosen gems, one per socket
function S.SocketInfo(item, weights)
    local sockets = item and item.sk
    weights = weights or S._activeWeights
    if not (sockets and weights and (item.ilvl or 0) >= S.SOCKET_MIN_ILVL) then
        return nil
    end
    local cacheable = socketCache and item.id and not item._live
                      and weights == S._activeWeights
    if cacheable then
        local c = socketCache[item.id]
        if c ~= nil then return c or nil end
    end

    local gems = S.GemTable(weights)
    local tierName = item.ilvl >= S.SOCKET_EPIC_ILVL and "epic" or "rare"
    local tier = gems[tierName]
    local colored, metas, properValue = 0, 0, 0
    for _, code in ipairs(sockets) do
        if code == SOCKET_META then
            metas = metas + 1
        else
            colored = colored + 1
            local gem = tier[code]
            if gem then properValue = properValue + gem.value end
        end
    end
    local bonus = (colored > 0 and item.sb) and weighted(item.sb, weights) or 0
    properValue = properValue + bonus
    local any = tier[SOCKET_ANY]
    local mismatchedValue = colored * (any and any.value or 0)

    local stats, picks, value, mode = {}, {}, 0, nil
    local function take(gem, times)
        for k, v in pairs(gem.st) do stats[k] = (stats[k] or 0) + v * times end
        for _ = 1, times do picks[#picks + 1] = gem end
    end
    if colored > 0 then
        if properValue >= mismatchedValue then
            mode, value = "proper", properValue
            for _, code in ipairs(sockets) do
                if code ~= SOCKET_META and tier[code] then take(tier[code], 1) end
            end
            if item.sb then
                for k, v in pairs(item.sb) do stats[k] = (stats[k] or 0) + v end
            end
        elseif any then
            mode, value, bonus = "mismatched", mismatchedValue, 0
            take(any, colored)
        end
    end
    if metas > 0 and gems.meta then
        value = value + metas * gems.meta.value
        take(gems.meta, metas)
    end

    local info
    if value > 0 then
        info = { value = value, stats = stats, mode = mode, tier = tierName,
                 colored = colored, metas = metas, bonus = bonus, picks = picks }
    end
    if cacheable then socketCache[item.id] = info or false end
    return info
end

function S.SocketValue(item, weights)
    local info = S.SocketInfo(item, weights)
    return info and info.value or 0
end

-- "gemas azules ideales", "gema meta ideal"...: what the explain line says the
-- sockets were priced with.
function S.SocketSummary(info, item)
    if not info then return nil end
    local parts = {}
    if info.colored > 0 then
        if info.mode == "proper" then
            local seen, words = {}, {}
            for _, code in ipairs(item.sk) do
                if code ~= SOCKET_META and not seen[code] then
                    seen[code] = true
                    words[#words + 1] = SOCKET_COLOR_WORD[code] or "de otro color"
                end
            end
            parts[#parts + 1] = "gemas " .. table.concat(words, " y ") .. " ideales"
                                .. (info.bonus ~= 0 and ", con bono de ranuras" or "")
        else
            parts[#parts + 1] = "la mejor gema de cualquier color en cada ranura, sin bono"
        end
    end
    if info.metas > 0 then parts[#parts + 1] = "gema meta ideal" end
    return table.concat(parts, "; ")
end

-- An off-hand swing deals half the weapon's damage in TBC, so a weapon's `dps`
-- is worth half as much there as it is in the main hand. Without this the
-- comparison below added two full weapons together and dual wielding won every
-- time, for every spec, including the ones that cannot dual wield at all.
--
-- Uncached on purpose: the same item has two scores now depending on the hand,
-- and the cache is keyed by item id.
function S.ScoreOffhand(item, weights, slotID)
    weights = weights or S._activeWeights
    if not weights then return 0 end
    local total = S.Score(item, weights, slotID or 17)
    local dps = item.st and item.st.dps
    if dps and OFFHAND_WEAPON_INV[item.slot] then
        total = total - (weights.dps or 0) * dps * 0.5
    end
    return total
end

------------------------------------------------------------------------------
-- Set bonuses
------------------------------------------------------------------------------
-- A set bonus is worth nothing until you are wearing enough of the set, so
-- pricing a piece as if it carried its bonus would be wrong for the first one
-- and wrong again for the fifth. What IS knowable is exact: how many pieces of
-- that set you have on right now, and therefore which threshold this piece
-- would cross if you put it on. That, and only that, is added.
--
-- The counts come from your own character, so they change when you change gear
-- and the score cache goes with them (see ns.RefreshSetCounts in Core.lua).
function S.SetBonus(item, weights, slotID)
    weights = weights or S._activeWeights
    local setId = item and item.set
    if not (weights and setId and ns.set and ns.set[setId]) then return 0 end
    local entry = ns.set[setId]
    if not entry.bonus then return 0 end
    local counts = ns.setCounts or {}
    local have = counts[setId] or 0
    -- If the piece you are replacing is from the same set, putting this one on
    -- does not raise the count at all.
    local slotName = S.INVTYPE_SLOT and S.INVTYPE_SLOT[item.slot]
    local def = slotName and S.SLOTS[slotName]
    slotID = slotID or (def and def.slot)
    local bySlot = ns.setBySlot or {}
    if slotID and bySlot[slotID] == setId then have = have - 1 end
    local after, total = have + 1, 0
    for need, st in pairs(entry.bonus) do
        if need > have and need <= after then
            total = total + weighted(st, weights)
        end
    end
    return total
end

function S.Score(item, weights, slotID)
    weights = weights or S._activeWeights
    if not weights then return 0 end
    local cacheable = curCache and weights == S._activeWeights and item.id
                      and not item._live and not item._rolled
    local total
    if cacheable then
        local c = curCache[item.id]
        if c ~= nil then total = c end
    end
    if total == nil then
        total = weighted(item.st, weights, RANGED_SLOT[item.slot])
        if item.sg or item.pg then
            total = total + (S.BestVariant(item, weights))
        end
        -- The ideal-gem value of the sockets depends on the item and the
        -- weights only, so it belongs in this cached part. Recommended and
        -- equipped items both come through here (EquippedScore reads the
        -- same DB entry), which is what keeps the two sides symmetric.
        if item.sk then total = total + S.SocketValue(item, weights) end
        if cacheable then curCache[item.id] = total end
    end
    -- Set value depends on the exact equipment slot being replaced. It cannot
    -- live in the item-id cache: finger 1 and finger 2 may currently hold
    -- different sets even though both rank from the same item pool.
    if item.set then total = total + S.SetBonus(item, weights, slotID) end
    return total
end

------------------------------------------------------------------------------
-- Ranking
------------------------------------------------------------------------------
-- Ajuste de arma separado del puntaje Pawn. Hipótesis y fuentes:
-- WEAPON_RULES.md. Un uso de la habilidad por enfriamiento base, un objetivo;
-- no simula ira, talentos, procs ni daño total de una rotación.
local WEAPON_CYCLE = {
    WARRIOR = {
        Fury = { level=36, seconds=10, coefficient=1, normalized=true, both=true,
                 name="Torbellino" },
        Arms = { level=40, seconds=6, coefficient=1, normalized=true,
                 name="Golpe mortal" },
    },
    SHAMAN = { Enhancement = { level=40, seconds=10, coefficient=1, both=true,
                               name="Golpe de tormenta" } },
    PALADIN = { Retribution = { level=50, seconds=6, coefficient=1.1,
                                name="Golpe de cruzado" } },
}

local function profileSpec(weights, classToken)
    local context = ns.Weights.Context(weights)
    if context and context.class == classToken then return context.spec end
    return ns.activeSpec
end

function S.NormalizedSpeed(item)
    if item.sc == 15 then return 1.7 end
    if item.slot == "INVTYPE_2HWEAPON" then return 3.3 end
    if RANGED_SLOT[item.slot] then return 2.8 end
    return 2.4
end

function S.WeaponAdjustment(item, weights, slotID, level)
    if not item or item.ic ~= IC_WEAPON or (slotID ~= 16 and slotID ~= 17) then return 0 end
    if (weights.spd or 0) ~= 0 then return 0 end -- respetar velocidad personalizada
    local context = ns.Weights.Context(weights)
    if not context then return 0 end
    local rules = WEAPON_CYCLE[context.class]
    local rule = rules and rules[context.spec]
    level = level or (ns.TargetLevel and ns:TargetLevel()) or ns.playerLevel or 0
    if not rule or level < rule.level or (slotID == 17 and not rule.both) then return 0 end
    local st = item.st or {}
    if not st.dps or not st.spd or st.spd <= 0 or st.dps <= 0 then return 0 end
    local reference = item.slot == "INVTYPE_2HWEAPON" and 3.3 or 2.4
    local speed = rule.normalized and S.NormalizedSpeed(item) or st.spd
    local ap = ns.weaponAttackPower or 0
    local rate = rule.coefficient / rule.seconds
    -- Conserva el peso publicado para un arma de velocidad de referencia.
    -- Convierte la diferencia de daño por golpe a DPS equivalentes: evita
    -- sumar nuevamente toda la habilidad sobre un peso que ya valora DPS.
    local difference = st.dps * (st.spd - reference) + ap / 14 * (speed - reference)
    local effectiveDelta = difference * rate / (1 + reference * rate)
    effectiveDelta = math.max(-st.dps, effectiveDelta)
    local hand = slotID == 17 and 0.5 or 1
    return effectiveDelta * (weights.dps or 0) * hand, rule.name
end

------------------------------------------------------------------------------
-- Ajustes por nivel y por tope de golpe
------------------------------------------------------------------------------
-- Los presets están calibrados a nivel 70. Un índice de combate compra más
-- porcentaje cuanto más bajo es el nivel, así que a nivel 40 cada punto de
-- índice vale más que a 70. La conversión de TBC es conocida:
--
--     nivel <= 10:  2/52      nivel 11..60: (nivel-8)/52      nivel 61..70: 82/(262-3*nivel)
--
-- y los puntos de índice por 1% son (base * coeficiente): a 70, 22,08 de
-- crítico (14 * 82/52); a 60, 14. El peso de un índice a nivel L es el peso a 70
-- multiplicado por coeficiente(70) / coeficiente(L). Solo escalan estos índices;
-- el editor sigue mostrando los pesos a nivel 70. Apagado con
-- `filters.levelScale = false`.
local RATING_KEYS = {
    hit = true, spellhit = true, crit = true, spellcrit = true,
    haste = true, spellhaste = true, expertise = true,
    dodge = true, parry = true, block = true, def = true, resil = true,
}
S.RATING_KEYS = RATING_KEYS

local function ratingCoefficient(level)
    if level <= 10 then return 2 / 52 end
    if level <= 60 then return (level - 8) / 52 end
    return 82 / (262 - 3 * level)
end

function S.RatingScale(level)
    level = math.max(1, math.min(70, level or 70))
    return ratingCoefficient(70) / ratingCoefficient(level)
end

-- Opción guardada que afecta a la puntuación sin llegar en `filters`.
function S.Option(key)
    local sv = LevelBiSCharDB
    local flt = sv and sv.settings and sv.settings.filters
    return flt and flt[key] or false
end

local function scoreLevel(level)
    return level or (ns.TargetLevel and ns:TargetLevel()) or ns.playerLevel or 70
end

-- Puntos extra de los índices a este nivel. Parte del puntaje en caché (que es
-- a nivel 70) más (escala - 1) veces lo que aportan los índices del objeto.
function S.LevelScaleAdjustment(item, weights, level)
    if not (item and weights and S.Option("levelScale")) then return 0 end
    local m = S.RatingScale(scoreLevel(level))
    if m == 1 then return 0 end
    local sum = 0
    local function add(st)
        if not st then return end
        for k, v in pairs(st) do
            if RATING_KEYS[k] and weights[k] then sum = sum + weights[k] * v end
        end
    end
    add(item.st)
    if item.sg or item.pg then
        local _, _, variantStats = S.BestVariant(item, weights)
        add(variantStats)
    end
    -- Ratings that come from the ideal gems and the socket bonus scale like the
    -- ratings of the item itself; otherwise a socketed piece would be priced at
    -- level 70 and everything else at the target level.
    local socket = S.SocketInfo(item, weights)
    if socket then add(socket.stats) end
    return (m - 1) * sum
end

-- Tope de golpe (M-16). Opcional y solo a nivel 70, con tu golpe de verdad:
-- `ns.hitRating` lo lee Core con GetCombatRating. Valores declarados, a 70:
-- 9% cuerpo a cuerpo y a distancia contra un jefe de nivel 73 (142 de índice) y
-- 16% con hechizos (202). No cuenta talentos que bajan el tope, así que es
-- conservador: nunca te dice que ya llegaste cuando no es cierto.
S.HIT_CAP = { hit = 142, spellhit = 202 }

local function slotStat(slotID, key)
    local link = GetInventoryItemLink and GetInventoryItemLink("player", slotID)
    if not link then return 0 end
    local id = tonumber(link:match("item:(%d+)"))
    local item = ns.db and ns.db[id]
    local st
    if item and not S.LinkSuffix(link) then st = item.st
    else
        local live = S.LiveItem(S.UnmodifiedLink(link))
        st = live and live.st
    end
    return st and st[key] or 0
end

function S.HitCapActive(level)
    return S.Option("hitCap") and ns.playerLevel == 70 and scoreLevel(level) == 70
           and ns.hitRating ~= nil
end

function S.HitCapAdjustment(item, weights, slotID, level)
    if not (item and weights and slotID and S.HitCapActive(level)) then return 0 end
    local total = 0
    -- Hit from the ideal gems counts toward the cap like hit on the item. The
    -- gems were chosen by weight alone, without knowing the cap, so a piece can
    -- be credited a little more hit than fits; the cap trims exactly that.
    local socket = S.SocketInfo(item, weights)
    local socketStats = socket and socket.stats
    for key, cap in pairs(S.HIT_CAP) do
        local w = weights[key]
        local current = ns.hitRating[key]
        if w and w ~= 0 and current then
            local gain = item.st and item.st[key] or 0
            if item.sg or item.pg then
                local _, _, variantStats = S.BestVariant(item, weights)
                gain = gain + (variantStats and variantStats[key] or 0)
            end
            gain = gain + (socketStats and socketStats[key] or 0)
            if gain > 0 then
                -- Golpe del resto del equipo: el actual sin lo que esta ranura
                -- lleva puesto. Solo lo que cabe bajo el tope vale.
                local base = math.max(0, current - slotStat(slotID, key))
                local useful = math.min(base + gain, cap) - math.min(base, cap)
                total = total - w * (gain - useful)
            end
        end
    end
    return total
end

------------------------------------------------------------------------------
-- M-8. Consumables
------------------------------------------------------------------------------
-- Data/consumables.lua carries, for every elixir, flask, "Well Fed" food and
-- health or mana potion, the stats its spell grants (pipeline/build_consumables.py;
-- anything whose effect could not be followed to numbers is not in it). The
-- player's own weights price them, with the same level scale as gear, so the
-- recommendation comes from the scale and not from a list. Potions are priced
-- by what they restore, which is a different magnitude, and reported apart.
local MANA_CLASS = {
    PALADIN = true, HUNTER = true, PRIEST = true, SHAMAN = true,
    MAGE = true, WARLOCK = true, DRUID = true,
}

function S.StatsValue(st, weights, level)
    if not (st and weights) then return 0 end
    local scale = (S.Option("levelScale") and level) and S.RatingScale(level) or 1
    local total = 0
    for k, v in pairs(st) do
        local w = weights[k]
        if w then
            if scale ~= 1 and RATING_KEYS[k] then w = w * scale end
            total = total + w * v
        end
    end
    return total
end

-- The best of each kind for `level`: { battle, guardian, flask, food, hp, mana }
-- each as { id, entry, score }, plus `useFlask` (a flask replaces both
-- elixirs, so it wins only when it is worth more than the pair) and `pair`.
-- Items that score nothing for these weights are left out, not listed.
function S.BestConsumables(level, weights, classToken)
    local best = {}
    local function consider(kind, id, entry, score)
        local cur = best[kind]
        if score > 0 and (not cur or score > cur.score
            or (score == cur.score and (entry.sp or 0) < (cur.entry.sp or 0))) then
            best[kind] = { id = id, entry = entry, score = score }
        end
    end
    for id, entry in pairs(ns.consumables or {}) do
        if (entry.req or 0) <= (level or 70) then
            if entry.st then
                consider(entry.k, id, entry, S.StatsValue(entry.st, weights, level))
            elseif entry.k == "hp" or (entry.k == "mana" and MANA_CLASS[classToken]) then
                consider(entry.k, id, entry, ((entry.lo or 0) + (entry.hi or 0)) / 2)
            end
        end
    end
    local pair = (best.battle and best.battle.score or 0) + (best.guardian and best.guardian.score or 0)
    best.pair = pair
    best.useFlask = best.flask ~= nil and best.flask.score > pair
    return best
end

-- Punto único para puntuar recomendado, equipado y tooltip en la misma mano.
function S.ScoreForSlot(item, weights, slotID, level)
    weights = weights or S._activeWeights
    if not weights then return 0 end
    local total = slotID == 17 and S.ScoreOffhand(item, weights, slotID)
                                 or S.Score(item, weights, slotID)
    return total + S.WeaponAdjustment(item, weights, slotID, level)
           + S.LevelScaleAdjustment(item, weights, level)
           + S.HitCapAdjustment(item, weights, slotID, level)
end

function S.WeaponNote(item, weights, slotID)
    if not item or item.ic ~= IC_WEAPON then return nil end
    local context = ns.Weights.Context(weights)
    if not context then return nil end
    local _, ability = S.WeaponAdjustment(item, weights, slotID)
    if ability then
        return "Arma: ajuste estimado por " .. ability .. ". No equivale a DPS real."
    end
    if context.class == "ROGUE" then
        return context.spec == "Assassination"
            and "Mutilar requiere dos dagas. Venenos y rotación no están simulados."
            or "La velocidad afecta habilidades y venenos. El puntaje no simula la rotación."
    elseif context.class == "DRUID" and context.spec:find("Feral", 1, true) then
        return "En forma feral importan estadísticas y poder de ataque feral, no el DPS del arma."
    elseif context.class == "WARRIOR" or context.class == "PALADIN" or context.class == "SHAMAN" then
        return "Arma valorada por estadísticas. Procs, amenaza y rotación no están simulados."
    elseif context.class == "HUNTER" then
        return "El puntaje no simula la cadencia de disparos ni el combate cuerpo a cuerpo."
    end
end

-- Default filters are permissive. `filters` may set:
--   minQuality (number), excludeBoE (bool, drops bind==2), onlyAH (bool, keeps
--   only what can be bought), noRaid, noDungeon, noPvP, noRep, myProfsOnly,
--   myFactionOnly, strictArmor.
-- An item is filtered out only when EVERY source it has is excluded. Items with
-- no source at all are kept: the pipeline already drops those, and silently
-- hiding an item because its origin is unknown would be worse.
-- `skipAccess` leaves personal access (reputation, exhausted quests) out: see
-- S.AccessExempt, which says when that applies to an item.
function S.SourceAllowed(s, filters, skipAccess)
    filters = filters or {}
    local blocked = false
    local byContent = filters.noRaid or filters.noDungeon or filters.noPvP
                      or filters.onlyReachable or filters.dungeonMode
                      or filters.maxPhase
    if byContent then
        local ct = s.ct
        blocked = (ct == "raid" and filters.noRaid)
               or (ct == "dungeon" and filters.noDungeon)
               or (ct == "pvp" and filters.noPvP) or false
        if not blocked and ct == "dungeon" and filters.dungeonMode then
            local mask = s.diff or 0
            local bit = filters.dungeonMode == "heroic" and 2 or 1
            blocked = math.floor(mask / bit) % 2 ~= 1
        end
        -- Content that has not opened yet on this server (M-7). A source
        -- without `ph` has no evidence of a later phase and counts as available.
        if not blocked and filters.maxPhase and s.ph and s.ph > filters.maxPhase then
            blocked = true
        end
        -- `u` marks a creature the pipeline could not place in any map. An
        -- unknown location is not proof that a content exclusion allows it.
        if not blocked and s.u then blocked = true end
    end
    if not blocked and filters.myProfsOnly and s.t == "craft" and s.prof then
        blocked = not (ns.HasProfession and ns.HasProfession(s.prof, s.skill))
    end
    if not blocked and filters.myFactionOnly and s.side then
        blocked = (s.side ~= ns.playerSide)
    end
    -- "Alcanzable" also means: the reputation you hold is enough (vendor
    -- routes of an item that asks for one), a one-time quest you already
    -- turned in is not a way to get it again, and a festival source (`ev`)
    -- is only open while its event is confirmed active. Unknown evidence about
    -- reputation or a quest never blocks; an unconfirmed event always does.
    if not blocked and filters.onlyReachable and not skipAccess
       and (s.once or s.rf or s.ev) and ns.Access then
        blocked = ns.Access.RouteStatus(s) == "blocked"
    end

    -- Independent, complementary source buckets. A quest reward belongs to
    -- Missions even when the quest enters an instance. Instances contains
    -- drops and vendors physically located in a dungeon or raid. With both
    -- switches active, either bucket is accepted (union).
    local onlyInstances = filters.onlyInstances
    local onlyQuests = filters.onlyQuests
    if filters.onlyInstance then -- compatibility for callers using the old key
        onlyInstances, onlyQuests = true, true
    end
    if not blocked and (onlyInstances or onlyQuests) then
        local instanceSource = s.t ~= "quest"
                               and (s.ct == "dungeon" or s.ct == "raid")
        local questSource = s.t == "quest"
        blocked = not ((onlyInstances and instanceSource)
                       or (onlyQuests and questSource))
    end
    return not blocked
end

-- The least demanding verified route is the useful explanation for a BoP
-- recommendation. Routes, unlike the capped tooltip list, include every
-- distinct way of obtaining the item.
function S.RouteAccess(source, filters)
    local access = source.access or 0
    if source.diff == 2 or (source.diff == 3 and filters
       and filters.dungeonMode == "heroic") then
        access = math.max(70, access)
    end
    return access
end

-- Access never restricts what you already wear or carry, nor what the auction
-- house can sell you (bound on equip or on use): the other routes are not the
-- only way to it. Only matters when "Alcanzable" is on and the item has a route
-- that access could close (`acc`, stamped when the data loads).
function S.AccessExempt(item, id, filters)
    if not (item and item.acc and filters and filters.onlyReachable and ns.Access) then
        return false
    end
    id = id or item.id
    return ns.Access.Owns(id) or S.Auctionable(item, id)
end

function S.AllowedRoute(item, filters)
    local exempt = S.AccessExempt(item, nil, filters)
    -- An exempt item may still have routes that are open; show one of those
    -- before a route that access would otherwise have closed.
    for _, skip in ipairs(exempt and { false, true } or { false }) do
        local best, gate
        for _, source in ipairs(item.routes or item.src or {}) do
            if S.SourceAllowed(source, filters, skip) then
                local access = S.RouteAccess(source, filters)
                if not best or access < gate then best, gate = source, access end
            end
        end
        if best then return best, gate end
    end
    return nil, nil
end

local function sourceAllowed(item, filters, id)
    local bySource = filters.noRaid or filters.noDungeon or filters.noPvP
                     or filters.onlyReachable or filters.dungeonMode
                     or filters.maxPhase
                     or filters.myProfsOnly or filters.myFactionOnly
                     or filters.onlyInstances or filters.onlyQuests
                     or filters.onlyInstance
    if not bySource then return true end
    local src = item.routes or item.src
    if not src or #src == 0 then
        -- Unknown origin survives exclusion filters, because absence is not a
        -- fact. It cannot satisfy an affirmative "only this source" request.
        return not (filters.onlyInstances or filters.onlyQuests
                    or filters.onlyInstance)
    end
    local skip = S.AccessExempt(item, id, filters)
    for _, s in ipairs(src) do
        if S.SourceAllowed(s, filters, skip) then return true end
    end
    return false
end

-- The level at which an item is actually within reach: its own RequiredLevel,
-- or the level gate of its cheapest source when that is higher. Endgame quest
-- rewards almost all store RequiredLevel = 0, so without `alvl` a level 40
-- warrior was told to go get a level 58 quest chain reward.
function S.ReachLevel(item, filters, itemId)
    local req = item.req or 0
    -- Tradable gear can be acquired independently of the original boss.
    -- Source filters still constrain its provenance in passFilters.
    local binding = S.Binding(item, itemId)
    if (binding == 0 or binding == 2 or binding == 3) and req > 0 then return req end
    if item.routes then
        local gate = math.huge
        local skip = S.AccessExempt(item, itemId, filters)
        for _, source in ipairs(item.routes) do
            if S.SourceAllowed(source, filters, skip) then
                local access = S.RouteAccess(source, filters)
                gate = math.min(gate, access)
            end
        end
        return math.max(req, gate)
    end
    local alvl = item.alvl or 0
    return (alvl > req) and alvl or req
end

-- Capturas del cliente Anniversary (16/9/2026): estos
-- cuatro objetos dicen «Se liga al recogerlo», aunque cmangos declara BoE.
-- Respaldo mientras GetItemInfo carga; no modifica los datos de la fuente.
local CAPTURED_BINDING = { [30722]=1, [30729]=1, [30738]=1, [30740]=1 }
local clientBindings = {}

function S.ObserveBinding(id, binding)
    if ns.db and ns.db[id] and type(binding) == "number" then
        local previous = clientBindings[id]
        if previous == nil then previous = CAPTURED_BINDING[id] or ns.db[id].bind end
        if previous ~= binding then
            ns.bindingChanged = true
            S.ClearLifetimeCache()
        end
        clientBindings[id] = binding
    end
end

function S.Binding(item, id)
    id = id or item.id
    -- El ranking nunca pide datos al cliente: cada respuesta puede refrescarlo.
    if id and clientBindings[id] ~= nil then return clientBindings[id] end
    return (id and CAPTURED_BINDING[id]) or item.bind
end

-- La subasta acepta sin ligadura, BoE y ligado al usar. Una ligadura
-- ausente o de misión no demuestra que el objeto se pueda vender.
function S.Auctionable(item, id)
    if not item then return false end
    local binding = S.Binding(item, id)
    return binding == 0 or binding == 2 or binding == 3
end

-- Tope de ilvl por nivel: una HEURÍSTICA declarada, no un dato. Mide lo que la
-- propia base muestra: el equipo de leveling hasta 57 tiene ilvl de requisito
-- más 5 a 9 (percentil 97 de cada tramo de 5 niveles); de 58 a 60 llegan las
-- recompensas de Terrallende de nivel 100 a 105 y de 65 a 69 el equipo de
-- 115 a 125. Un objeto sin fuente que lo ate a un nivel (vendedor, cofre) solo
-- lo limita su requisito, y esto lo acota. Apagado por defecto: `ilvlCap`.
-- A nivel 70 no hay tope.
function S.IlvlCap(level)
    if not level or level >= 70 then return nil end
    if level <= 57 then return level + 15 end
    if level <= 60 then return 105 end
    if level <= 64 then return 115 end
    return 128
end

local function overIlvlCap(item, filters, level)
    if not (filters and filters.ilvlCap) then return false end
    local cap = S.IlvlCap(level)
    return cap ~= nil and (item.ilvl or 0) > cap
end

local function passFilters(item, filters, id)
    if not filters then return true end
    if filters.minQuality and (item.q or 0) < filters.minQuality then return false end
    local binding = item.bind
    if filters.excludeBoE then binding = S.Binding(item, id) end
    if filters.excludeBoE and binding == 2 then return false end
    if filters.onlyAH and not S.Auctionable(item, id) then return false end
    -- "Only what comes as it comes": drop anything whose stats depend on a
    -- roll. Deliberately separate from `noRandom`, which keeps such an item and
    -- scores only its guaranteed half -- 433 items, nearly all weapons, have
    -- guaranteed damage AND a roll, and `noRandom` still ranks them by that
    -- damage. This one removes them outright, which is the answer to a
    -- different question: what can I buy without hunting for a specific roll.
    if filters.fixedOnly and (item.sg or item.pg) then return false end
    if filters.noRep and item.repf then return false end
    -- Some items cannot be EQUIPPED without a profession (engineering gadgets,
    -- mostly). That is a property of the item, not of where it comes from, so
    -- it is checked here rather than per source.
    if filters.myProfsOnly and item.rprof
       and not (ns.HasProfession and ns.HasProfession(item.rprof, item.rskill)) then
        return false
    end
    if not sourceAllowed(item, filters, id) then return false end
    return true
end

-- Rows scoring below this fraction of the slot's winner are dropped. See the
-- note where it is applied.
local NOISE_FLOOR = 0.1

-- Returns a sorted (desc by score) list of { id, item, score } for a slot.
-- `exclude` is an optional set of item IDs to leave out (see S.RankAll: the
-- winner of finger1 must not also win finger2 when the item is unique).
-- `invAllow`, when given, keeps only these inventory types. It is how the
-- main-hand row is limited to two-handers once the comparison below has
-- decided that a two-hander wins.
function S.RankSlot(slotName, targetLevel, weights, classToken, level, filters,
                    topN, exclude, invAllow)
    topN = topN or 5
    local db = ns.db
    local resolved = S.ResolveSlot(slotName)
    local def = S.SLOTS[resolved]
    if not db or not def then return {} end
    -- The off hand holds a weapon only for those who can dual wield; for
    -- everyone else it is a shield or a held item, and offering a sword there
    -- is offering something they cannot equip.
    local eligibilityLevel = targetLevel or level or 0
    local spec = profileSpec(weights, classToken)
    local dualWield = S.CanDualWield(classToken, eligibilityLevel, spec)
    local offhand = (resolved == "offhand")
    S.SetIgnoreRandom(filters and filters.noRandom)
    S.UseProfile(weights)
    local out
    -- Try the class's own armor tier first, then relax if that leaves the slot
    -- empty (some slots have no plate option at low levels).
    local strict = not (filters and filters.strictArmor == false)
    local pool = slotPool(S.ResolveSlot(slotName))
    for _, useStrict in ipairs(strict and { true, false } or { false }) do
        out = {}
        local wandFallback = {}
        for _, id in ipairs(pool) do
            local item = db[id]
            local gate = item and ((filters and filters.onlyReachable == false)
                                   and (item.req or 0) or S.ReachLevel(item, filters, id))
            if item and not (exclude and exclude[id])
               and (not invAllow or invAllow[item.slot])
               and not (offhand and OFFHAND_WEAPON_INV[item.slot] and not dualWield)
               and gate <= targetLevel
               and S.CanUse(item, classToken, eligibilityLevel, useStrict)
               and S.Recommendable(item, classToken, eligibilityLevel, spec)
               and passFilters(item, filters, id)
               and not overIlvlCap(item, filters, targetLevel) then
                item.id = id
                -- An item worth nothing to this profile is not a worse answer,
                -- it is no answer. Two thirds of the trinkets in the database
                -- are like this: their value is an on-use or on-proc effect,
                -- which a weighted sum has no way to price. Left in, they were
                -- sorted by item id -- the tiebreak for equal scores -- so the
                -- bottom of every trinket list filled up with the oldest,
                -- lowest items in the game.
                local score = S.ScoreForSlot(item, weights, def.slot, eligibilityLevel)
                if score > 0 then
                    out[#out+1] = { id = id, item = item, score = score }
                elseif resolved == "ranged" and item.sc == 19
                       and item.st and (item.st.dps or 0) > 0 then
                    -- Pawn assigns caster RangedDps zero. A statless wand would
                    -- otherwise disappear, so the slot may fall back to local
                    -- wand DPS. This value is labelled and never mixed into
                    -- Pawn score or cross-slot improvement totals.
                    wandFallback[#wandFallback+1] = {
                        id = id, item = item, score = 0,
                        fallback = "wandDps", fallbackScore = item.st.dps,
                    }
                end
            end
        end
        if #out == 0 and #wandFallback > 0 then out = wandFallback end
        if #out > 0 then break end
    end
    table.sort(out, function(a, b)
        local av, bv = a.fallbackScore or a.score, b.fallbackScore or b.score
        if av == bv then return (a.id or 0) < (b.id or 0) end
        return av > bv
    end)
    -- The winner always stands. Below it, a row worth a tenth of the winner is
    -- noise dressed as an option -- it is there because the slot ran out of
    -- real candidates, and saying nothing is the more honest answer.
    local floor = (out[1] and (out[1].fallbackScore or out[1].score) or 0)
                  * NOISE_FLOOR
    for i = #out, 2, -1 do
        if (out[i].fallbackScore or out[i].score) < floor then out[i] = nil end
    end
    for _, entry in ipairs(out) do entry.candidateCount = #out end
    for i = #out, topN + 1, -1 do out[i] = nil end
    return out
end

-- True when a slot is empty because everything in it is unpriceable rather
-- than because the filters emptied it. A paladin's librams and a druid's idols
-- are the whole slot: they change a spell, they carry no stats, and no
-- weighted sum will ever rank them.
function S.SlotIsUnpriceable(slotName, targetLevel, weights, classToken, level, filters)
    return S.UnscorableCount(slotName, targetLevel, weights, classToken, level,
                             filters) > 0
end

-- How many items this slot holds that are eligible and pass the filters but
-- score nothing -- the on-use trinkets, mostly. The window cannot rank them
-- and does not show them; `/lbis slot` says how many it had to leave out, so
-- a short list reads as "this is all I can price", not as "this is all there
-- is".
function S.UnscorableCount(slotName, targetLevel, weights, classToken, level, filters)
    local db, def = ns.db, S.SLOTS[S.ResolveSlot(slotName)]
    if not db or not def then return 0 end
    S.SetIgnoreRandom(filters and filters.noRandom)
    S.UseProfile(weights)
    local n = 0
    for _, id in ipairs(slotPool(S.ResolveSlot(slotName))) do
        local item = db[id]
        local gate = item and ((filters and filters.onlyReachable == false)
                               and (item.req or 0) or S.ReachLevel(item, filters, id))
        if item and gate <= targetLevel
           and S.Recommendable(item, classToken, targetLevel, profileSpec(weights, classToken))
           and S.CanUse(item, classToken, targetLevel or level or 0,
                        not (filters and filters.strictArmor == false))
           and passFilters(item, filters, id)
           and not overIlvlCap(item, filters, targetLevel) then
            item.id = id
            local score = S.ScoreForSlot(item, weights, def.slot, targetLevel)
            local wand = S.ResolveSlot(slotName) == "ranged" and item.sc == 19
                         and item.st and (item.st.dps or 0) > 0
            if score <= 0 and not wand then n = n + 1 end
        end
    end
    return n
end

------------------------------------------------------------------------------
-- Paired slots
--
-- RankSlot works one slot at a time, so finger1 and finger2 -- which share a
-- pool -- both used to return the same winning ring, and you cannot equip two
-- copies of a unique item. The pairs are resolved together: the first slot
-- picks freely, and its winner is withheld from the second slot's pool when the
-- item is flagged unique (`uniq`, from item_template.maxcount = 1).
--
-- The winner is withheld unconditionally, not only when the item is flagged
-- unique. Two of the same trinket is a legitimate answer in the data (cmangos
-- marks neither Blackhand's Breadth nor Eye of the Beast as unique) but never a
-- useful one: showing the runner-up tells you your two best distinct options,
-- and the tooltip still says "Único" when the item is one you could not have
-- doubled anyway.
------------------------------------------------------------------------------
S.SLOT_PAIR = { finger1 = "finger2", trinket1 = "trinket2", mainhand = "offhand" }
local PAIR_SECOND = {}
for first, second in pairs(S.SLOT_PAIR) do PAIR_SECOND[second] = first end

-- Rank every slot at once, honouring pair exclusivity.
-- Returns { [slotName] = list }, each list as RankSlot returns it.
-- Rank every slot at once.
--
-- The two hands are NOT ranked independently. They used to be, and the window
-- answered every melee spec with a two-hander in one row and a one-handed
-- weapon in the other -- a pair nobody can equip. The comparison decides
-- first, and then each row is filled with something consistent with it.
function S.RankAll(targetLevel, weights, classToken, level, filters, topN)
    local out = {}
    for _, name in ipairs(S.SLOT_ORDER) do
        if not PAIR_SECOND[name] and name ~= "mainhand" then
            out[name] = S.RankSlot(name, targetLevel, weights, classToken, level,
                                   filters, topN)
        end
    end
    for first, second in pairs(S.SLOT_PAIR) do
        if first ~= "mainhand" then
            local won = out[first] and out[first][1]
            local exclude
            if won then exclude = { [won.id] = true } end
            out[second] = S.RankSlot(second, targetLevel, weights, classToken,
                                     level, filters, topN, exclude)
        end
    end

    local setup = S.BestWeaponSetup(targetLevel, weights, classToken, level, filters)
    if setup and setup.better == "2h" then
        out.mainhand = S.RankSlot("mainhand", targetLevel, weights, classToken,
                                  level, filters, topN, nil, S.TWO_HAND_INV)
        -- Both hands are the two-hander. An empty list here is the truth; the
        -- window says why.
        out.offhand = {}
    else
        out.mainhand = S.RankSlot("mainhand", targetLevel, weights, classToken,
                                  level, filters, topN, nil, S.ONE_HAND_INV)
        local won = out.mainhand[1]
        local required = setup and setup.required
        local ohInv = (required == "shield" and S.SHIELD_INV)
                      or (required == "dual" and S.OFFHAND_WEAPON_INV) or nil
        out.offhand = S.RankSlot("offhand", targetLevel, weights, classToken,
                                 level, filters, topN,
                                 won and { [won.id] = true } or nil, ohInv)
    end
    return out
end

-- Best two-handed vs best (1H mainhand + offhand). Returns a comparison table:
--   { two = {id,score}, one = {mh={id,score}, oh={id,score}, score}, better = "2h"|"1h" }
-- Two hands, one answer: the best two-hander against the best one-hander plus
-- the best thing that can go beside it.
--
-- Everything here goes through RankSlot rather than walking the database
-- again, which is what keeps the three answers under the same rules: the same
-- filters, the same level gates, the same dual-wield restriction, and an off
-- hand scored as an off hand -- half the weapon damage, because that is what
-- an off-hand swing deals.
--
-- What sits beside a one-hander is not always another weapon. For a paladin it
-- is a shield or a held item, because a paladin cannot dual wield; for a
-- protection warrior it is a shield too, and the shield's armour and block win
-- that comparison on the tank's own weights without anything here forcing it.
function S.BestWeaponSetup(targetLevel, weights, classToken, level, filters)
    if not ns.db then return nil end
    local required = S.RequiredHands(classToken, targetLevel or level or 0, profileSpec(weights, classToken))
    local two = S.RankSlot("mainhand", targetLevel, weights, classToken, level,
                           filters, 1, nil, S.TWO_HAND_INV)[1]
    local mh = S.RankSlot("mainhand", targetLevel, weights, classToken, level,
                          filters, 1, nil, S.ONE_HAND_INV)[1]
    -- A spec that must hold a shield is not offered a weapon there, and one
    -- that must dual wield is not offered a shield.
    local ohInv = (required == "shield" and S.SHIELD_INV)
                  or (required == "dual" and S.OFFHAND_WEAPON_INV) or nil
    local oh = S.RankSlot("offhand", targetLevel, weights, classToken, level,
                          filters, 1, mh and { [mh.id] = true } or nil, ohInv)[1]
    local oneScore = (mh and mh.score or 0) + (oh and oh.score or 0)
    local twoScore = two and two.score or 0
    local better
    if required == "2h" then better = "2h"
    elseif required then better = "1h"
    else better = (twoScore > oneScore) and "2h" or "1h" end
    return {
        two = two,
        one = { mh = mh, oh = oh, score = oneScore },
        better = better,
        required = required,
    }
end

-- Resolve one row using the same pair choices as RankAll. A lifetime query
-- must not rank offhand or a second ring independently of its partner.
function S.BestForSlot(slotName, targetLevel, weights, classToken, level, filters)
    local first = PAIR_SECOND[slotName]
    if slotName == "mainhand" or slotName == "offhand" then
        local setup = S.BestWeaponSetup(targetLevel, weights, classToken, level, filters)
        if not setup then return nil end
        if setup.better == "2h" then
            return slotName == "mainhand" and setup.two or nil
        end
        if slotName == "mainhand" then return setup.one.mh end
        return setup.one.oh
    end
    local exclude
    if first then
        local won = S.RankSlot(first, targetLevel, weights, classToken, level,
                               filters, 1)[1]
        if won then exclude = { [won.id] = true } end
    end
    return S.RankSlot(slotName, targetLevel, weights, classToken, level,
                      filters, 1, exclude)[1]
end

local function filterSignature(filters)
    local keys, parts = {}, {}
    for key in pairs(filters or {}) do keys[#keys+1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts+1] = key .. "=" .. tostring(filters[key])
    end
    return table.concat(parts, ";")
end

-- First future level where this row has a different winner. It scans each
-- level: eligibility, armor proficiency and weapon talents can change at
-- different thresholds, so the winner is not a monotone function of level.
-- nil means this item remains first through 70. The single-entry cache avoids
-- doing the scan again when the same open detail is repainted.
--
-- The scan is a job that can be run in slices (M-11): a client that finds the
-- whole sweep too slow for one frame steps it a few levels at a time.
-- The access revision: reputation and one-time quests change which routes
-- exist, so answers computed under an older one are not answers.
local function accessRevision()
    return ns.Access and ns.Access.Revision() or 0
end

local function lifetimeKeyFor(slotName, itemId, startLevel, weights, classToken,
                              playerLevel, filters)
    return table.concat({ slotName, tostring(itemId), tostring(startLevel),
        tostring(classToken), tostring(playerLevel), tostring(ns.playerRace),
        tostring(ns.playerSide), tostring(ns.weaponAttackPower),
        tostring(profileSpec(weights, classToken)), hashWeights(weights),
        filterSignature(filters), "acc" .. accessRevision() }, "|")
end

-- Returns a job. job.done tells whether job.level / job.current are final;
-- S.LifetimeStep(job, n) advances it by up to n levels.
function S.LifetimeJob(slotName, itemId, startLevel, weights, classToken,
                       playerLevel, filters)
    if not (S.SLOTS[slotName] and itemId and startLevel and weights) then
        return { done = true }
    end
    S.SetIgnoreRandom(filters and filters.noRandom)
    local key = lifetimeKeyFor(slotName, itemId, startLevel, weights, classToken,
                               playerLevel, filters)
    if lifetimeKey == key and lifetimeResult then
        return { done = true, level = lifetimeResult.level,
                 current = lifetimeResult.current, key = key }
    end
    local current = S.BestForSlot(slotName, startLevel, weights, classToken,
                                  playerLevel, filters)
    local stillFirst = current and current.id == itemId or false
    local job = { key = key, rev = accessRevision(), slot = slotName, itemId = itemId,
                  next = startLevel + 1,
                  weights = weights, class = classToken, playerLevel = playerLevel,
                  filters = filters, current = stillFirst, done = false }
    if not stillFirst or job.next > 70 then
        job.done = true
        lifetimeKey, lifetimeResult = key, { level = nil, current = stillFirst }
    end
    return job
end

function S.LifetimeStep(job, levels)
    if job.done then return job end
    -- Access changed while this sweep was running: what it found no longer
    -- describes the character. It ends without writing a result.
    if job.rev ~= nil and job.rev ~= accessRevision() then
        job.done, job.stale, job.level = true, true, nil
        return job
    end
    S.SetIgnoreRandom(job.filters and job.filters.noRandom)
    for _ = 1, levels or 8 do
        local best = S.BestForSlot(job.slot, job.next, job.weights, job.class,
                                   job.playerLevel, job.filters)
        if not best or best.id ~= job.itemId then
            job.level, job.done = job.next, true
            break
        end
        job.next = job.next + 1
        if job.next > 70 then job.done = true break end
    end
    if job.done then
        lifetimeKey, lifetimeResult = job.key, { level = job.level, current = job.current }
    end
    return job
end

function S.FirstReplacementLevel(slotName, itemId, startLevel, weights,
                                 classToken, playerLevel, filters)
    local job = S.LifetimeJob(slotName, itemId, startLevel, weights, classToken,
                              playerLevel, filters)
    S.LifetimeStep(job, 100)
    return job.level, job.current
end

------------------------------------------------------------------------------
-- M-4. Which dungeon to run
------------------------------------------------------------------------------
-- The window says which item you want; this says where to go. Every slot is
-- ranked from instance sources only, each candidate that beats what you wear
-- credits the instances it drops in, and an instance is worth the best gain it
-- offers per slot, summed over slots -- five rings from one dungeon are not
-- five upgrades. The share is against what the best item from ANY source would
-- add, so it reads as "this dungeon is 41% of what is on the table".
--
-- Names come from the visible sources (`inst`). An item whose dungeon is not
-- among its six visible sources is left out of the credit rather than given a
-- name it does not have.
-- The data marks some world creatures as dungeon sources: a creature that
-- spawns in the open world AND in an instance copy keeps its loot in both. A
-- level 30 Hillsbrad mob would then credit Old Hillsbrad Foothills, a level 66
-- dungeon. A source only counts for an instance whose own creatures are of a
-- similar level: no more than 15 below the highest one the data places there.
-- Derived from the data, not declared by hand; computed once.
local instanceTop
function S.ForgetInstanceLevels() instanceTop = nil end
local function instanceTopLevels()
    if instanceTop then return instanceTop end
    instanceTop = {}
    for _, item in pairs(ns.db or {}) do
        for _, src in ipairs(item.src or {}) do
            if src.inst and src.lvl and src.lvl > (instanceTop[src.inst] or 0) then
                instanceTop[src.inst] = src.lvl
            end
        end
    end
    return instanceTop
end
local PLAN_LEVEL_SLACK = 15

local function cloneFilters(filters)
    local t = {}
    for k, v in pairs(filters or {}) do t[k] = v end
    return t
end

------------------------------------------------------------------------------
-- Best alternative with no random roll
--
-- The recommendation can be a piece whose stats depend on a roll the player has
-- to hunt for. This answers the other question about the same slot: what is the
-- best thing that is what it says on the label, and how much does choosing it
-- cost against the recommendation. Data only; the window words it.
--
-- It is not a second engine. The alternative is the recommendation machinery
-- run again with `fixedOnly` on (objects that roll are removed, not just
-- stripped of their roll) and `noRandom` off; nothing is cloned back into the
-- stored filters. Weapons compare whole configurations (BestWeaponSetup, with
-- and without the filter), so a two-hander is set against main hand plus off
-- hand and never against one hand alone; rings and trinkets reuse the pair
-- rule of BestForSlot.
--
--   state  "same"     the recommendation for this slot already has fixed stats
--          "none"     no fixed candidate passes the filters
--          "pending"  the equipment of the slot is still loading
--          "ok"       `alt` is the fixed alternative
--   rec, alt          RankSlot entries ({ id, item, score }) for this slot
--   recScore, altScore  the slot's score; for the two weapon slots the score of
--                     the whole configuration (see above)
--   diff, pct         altScore - recScore, and diff / recScore (a fraction,
--                     nil unless recScore > 0). Always against the
--                     recommendation, never against what is equipped.
--   eqScore, noUpgrade  what you wear (nil when unknown), and whether the
--                     alternative fails to beat it
--   recUsesRoll       the recommendation is a rolling item scored WITH a roll
--                     (false under `noRandom`)
--   altBothHands      off hand row whose alternative is a two-hander
------------------------------------------------------------------------------
local function hasRoll(entry)
    return entry ~= nil and entry.item ~= nil
           and (entry.item.sg ~= nil or entry.item.pg ~= nil)
end

-- Score of what is worn in these slots; nil when some of it cannot be priced.
local function equippedTotal(slotNames, weights, targetLevel)
    local total, known = 0, true
    for _, name in ipairs(slotNames) do
        local eq, _, _, _, state = S.EquippedScore(S.SLOTS[name].slot, weights, targetLevel)
        if state == "pending" then return nil, "pending" end
        if state == "ready" then total = total + (eq or 0)
        elseif state ~= "empty" then known = false end
    end
    return known and total or nil, "ready"
end

function S.FixedAlternative(slotName, targetLevel, weights, classToken, level, filters)
    local resolved = S.ResolveSlot(slotName)
    if not (S.SLOTS[resolved] and ns.db and weights) then return { state = "none" } end
    local weapon = resolved == "mainhand" or resolved == "offhand"
    local names = weapon and { "mainhand", "offhand" } or { resolved }
    local original = filters and filters.noRandom
    local fixed = cloneFilters(filters)
    fixed.fixedOnly, fixed.noRandom = true, false

    -- Scored in the state the window itself is in, then put back.
    S.SetIgnoreRandom(original)
    S.UseProfile(weights)
    local result = { state = "none" }
    local eq, eqState = equippedTotal(names, weights, targetLevel)
    if eqState == "pending" then return { state = "pending" } end
    result.eqScore = eq

    local ok, err = pcall(function()
        local rec, alt, recScore, altScore
        if weapon then
            local function entryFor(setup, asAlternative)
                if setup.better == "2h" then
                    if resolved == "mainhand" or asAlternative then
                        return setup.two, setup.two and setup.two.score or 0
                    end
                    return nil, setup.two and setup.two.score or 0
                end
                return resolved == "mainhand" and setup.one.mh or setup.one.oh,
                       setup.one.score
            end
            local recSetup = S.BestWeaponSetup(targetLevel, weights, classToken, level, filters)
            if not recSetup then return end
            rec, recScore = entryFor(recSetup, false)
            if rec and hasRoll(rec) then
                local altSetup = S.BestWeaponSetup(targetLevel, weights, classToken,
                                                   level, fixed)
                if altSetup then
                    alt, altScore = entryFor(altSetup, true)
                    result.altBothHands = alt ~= nil and resolved == "offhand"
                                          and altSetup.better == "2h"
                end
            end
        else
            rec = S.BestForSlot(slotName, targetLevel, weights, classToken, level, filters)
            recScore = rec and rec.score
            if rec and hasRoll(rec) then
                alt = S.BestForSlot(slotName, targetLevel, weights, classToken, level, fixed)
                altScore = alt and alt.score
            end
        end
        result.rec, result.recScore = rec, recScore
        if not rec then return end
        result.recUsesRoll = hasRoll(rec) and not original
        if not hasRoll(rec) then
            result.state, result.alt, result.altScore = "same", rec, recScore
            result.diff, result.pct = 0, recScore > 0 and 0 or nil
            return
        end
        if not alt then return end
        result.state, result.alt, result.altScore = "ok", alt, altScore
        result.diff = altScore - recScore
        result.pct = recScore > 0 and (result.diff / recScore) or nil
    end)
    S.SetIgnoreRandom(original)
    S.UseProfile(weights)
    if not ok then error(err, 0) end
    if result.state == "ok" and eq ~= nil then
        result.noUpgrade = not (result.altScore > eq)
    end
    return result
end

-- The window repaints the open detail on every refresh; the answer only changes
-- with the inputs below, so one entry is kept and ClearLifetimeCache (profile,
-- spec, database, bindings, equipment) drops it. A pending answer is never kept.
function S.CachedFixedAlternative(slotName, targetLevel, weights, classToken, level, filters)
    local resolved = S.ResolveSlot(slotName)
    local def = S.SLOTS[resolved]
    if not (def and weights) then return S.FixedAlternative(slotName, targetLevel, weights,
                                                           classToken, level, filters) end
    S.SetIgnoreRandom(filters and filters.noRandom)   -- hashWeights reads it
    local worn = {}
    for _, name in ipairs((resolved == "mainhand" or resolved == "offhand")
                          and { "mainhand", "offhand" } or { resolved }) do
        worn[#worn + 1] = tostring(GetInventoryItemLink("player", S.SLOTS[name].slot))
    end
    local key = table.concat({ slotName, tostring(targetLevel), tostring(classToken),
        tostring(level), tostring(ns.playerRace), tostring(ns.playerSide),
        tostring(ns.weaponAttackPower), tostring(profileSpec(weights, classToken)),
        hashWeights(weights), filterSignature(filters), table.concat(worn, ","),
        "acc" .. accessRevision() }, "|")
    if fixedAltKey == key and fixedAltResult then return fixedAltResult end
    local result = S.FixedAlternative(slotName, targetLevel, weights, classToken,
                                      level, filters)
    if result.state ~= "pending" then fixedAltKey, fixedAltResult = key, result end
    return result
end

-- Returns { { inst, slots, gain, share, items = { {slot, id, gain} } } ... }
-- sorted by gain, plus the total on the table; or nil, "pending".
function S.DungeonPlan(targetLevel, weights, classToken, level, filters, depth, limit)
    if not ns.db then return {}, 0 end
    depth, limit = depth or 5, limit or 8
    local anyF = cloneFilters(filters)
    anyF.onlyInstances, anyF.onlyQuests = false, false
    local instF = cloneFilters(filters)
    instF.onlyInstances, instF.onlyQuests = true, false

    local equipped = {}
    for _, slotName in ipairs(S.SLOT_ORDER) do
        local def = S.SLOTS[slotName]
        local eq, _, _, _, state = S.EquippedScore(def.slot, weights, targetLevel)
        if state == "pending" then return nil, "pending" end
        equipped[slotName] = (state == "ready" or state == "empty") and (eq or 0) or nil
    end

    local overall = S.RankAll(targetLevel, weights, classToken, level, anyF, 1)
    local total = 0
    for slotName, list in pairs(overall) do
        local top = list and list[1]
        if top and not top.fallback and equipped[slotName] then
            total = total + math.max(0, top.score - equipped[slotName])
        end
    end

    local ranked = S.RankAll(targetLevel, weights, classToken, level, instF, depth)
    local byInst = {}
    for slotName, list in pairs(ranked) do
        local eq = equipped[slotName]
        for _, entry in ipairs(list or {}) do
            local gain = eq and not entry.fallback and (entry.score - eq) or 0
            if gain > 0.5 then
                for _, src in ipairs(entry.item.src or {}) do
                    local top = src.inst and instanceTopLevels()[src.inst] or 0
                    if src.inst and (src.ct == "dungeon" or src.ct == "raid")
                       and (src.lvl or top) >= top - PLAN_LEVEL_SLACK
                       and S.SourceAllowed(src, instF)
                       and S.RouteAccess(src, instF) <= targetLevel then
                        local rec = byInst[src.inst]
                        if not rec then rec = { inst = src.inst, perSlot = {} }; byInst[src.inst] = rec end
                        local cur = rec.perSlot[slotName]
                        if not cur or gain > cur.gain then
                            rec.perSlot[slotName] = { slot = slotName, id = entry.id, gain = gain }
                        end
                    end
                end
            end
        end
    end

    local out = {}
    for _, rec in pairs(byInst) do
        local items, gain = {}, 0
        for _, slotName in ipairs(S.SLOT_ORDER) do
            local it = rec.perSlot[slotName]
            if it then items[#items + 1] = it; gain = gain + it.gain end
        end
        table.sort(items, function(a, b) return a.gain > b.gain end)
        out[#out + 1] = {
            inst = rec.inst, slots = #items, gain = gain, items = items,
            share = total > 0 and math.min(100, gain / total * 100) or 0,
        }
    end
    table.sort(out, function(a, b)
        if a.gain ~= b.gain then return a.gain > b.gain end
        return a.inst < b.inst
    end)
    for i = #out, limit + 1, -1 do out[i] = nil end
    return out, total
end

------------------------------------------------------------------------------
-- Equipped item helpers
------------------------------------------------------------------------------
function S.EquippedItemID(slotID)
    local link = GetInventoryItemLink("player", slotID)
    if not link then return nil end
    return tonumber(link:match("item:(%d+)"))
end

-- Live stat resolution via the client's GetItemStats, so ANY real item can be
-- scored even when it's not in the static DB (bridge until the pipeline data is
-- in place; also covers items the DB doesn't contain). Locale-independent: the
-- keys returned by GetItemStats are ITEM_MOD_* constants, not display text.
local NORM_MAP = {
    damage_per_second="dps", resistance0_name="armor",
    strength="str", agility="agi", stamina="sta", intellect="int", spirit="spi",
    attack_power="ap", ranged_attack_power="rap",
    crit_rating="crit", hit_rating="hit", haste_rating="haste",
    crit_melee_rating="crit", hit_melee_rating="hit", haste_melee_rating="haste",
    crit_ranged_rating="crit", hit_ranged_rating="hit", haste_ranged_rating="haste",
    crit_spell_rating="spellcrit", hit_spell_rating="spellhit", haste_spell_rating="spellhaste",
    expertise_rating="expertise",
    spell_power="sp", spell_damage_done="sp", spell_healing_done="heal",
    mana_regeneration="mp5",
    defense_skill_rating="def", dodge_rating="dodge", parry_rating="parry",
    block_rating="block", block_value="blockval",
    resilience_rating="resil", spell_penetration="spen",
}

-- GetItemStats reports an empty socket as EMPTY_SOCKET_<COLOR> = how many. Read
-- from a link with its gems stripped (S.UnmodifiedLink), every socket is empty,
-- so the keys count all of them. The client's own constant names are used
-- as they are: none of them is localized.
local SOCKET_KEY = {
    EMPTY_SOCKET_META = 1, EMPTY_SOCKET_RED = 2, EMPTY_SOCKET_YELLOW = 4,
    EMPTY_SOCKET_BLUE = 8, EMPTY_SOCKET_PRISMATIC = 14,
}
local SOCKET_KEY_ORDER = { 1, 2, 4, 8, 14 }

-- Second return: the socket colors, as the pipeline writes them in `sk`, or nil.
function S.LiveStats(link)
    if type(GetItemStats) ~= "function" then return nil end
    local t = GetItemStats(link)
    if not t then return nil end
    local st, socketCount = {}, {}
    for k, v in pairs(t) do
        local socket = SOCKET_KEY[tostring(k)]
        if socket then
            socketCount[socket] = (socketCount[socket] or 0) + (tonumber(v) or 0)
        else
            local norm = tostring(k):gsub("^ITEM_MOD_", ""):gsub("_SHORT$", ""):lower()
            local key = NORM_MAP[norm]
            if key and v and v ~= 0 then st[key] = (st[key] or 0) + v end
        end
    end
    local sockets
    for _, code in ipairs(SOCKET_KEY_ORDER) do
        for _ = 1, socketCount[code] or 0 do
            sockets = sockets or {}
            sockets[#sockets + 1] = code
        end
    end
    return st, sockets
end

-- A concrete roll of an item the data knows: the base stats plus the stats of
-- the suffix or property named in field 7 of the link. GetItemStats is not
-- used for these on purpose. It leaves out every "Equip:" bonus that comes
-- from a spell -- spell damage, healing -- (PickItRight lost 23 spell power
-- in a comparison that way), and it is empty until the client has cached the
-- item. The base `st` already carries those auras, and Data/random.lua has the
-- roll, so the answer is exact, locale-free and never pending.
-- nil when the item is not in the data or the roll is not one it knows: then
-- the client's numbers are the only answer left.
function S.RolledItem(link)
    local id = tonumber((link or ""):match("item:(%d+)"))
    local base = id and ns.db and ns.db[id]
    local roll = S.LinkSuffix(link)
    if not (base and roll) then return nil end
    local extra, name
    if roll < 0 and base.sg then
        extra, name = S.SuffixStats(base, -roll)
    elseif roll > 0 and base.pg then
        local prop = ns.property and ns.property[roll]
        if prop and prop.st then extra, name = prop.st, prop.n end
    end
    if not extra then return nil end
    local item = {}
    for k, v in pairs(base) do item[k] = v end
    -- The roll is fixed now: no best-roll search on top of it.
    item.sg, item.pg = nil, nil
    local st = {}
    for k, v in pairs(base.st or {}) do st[k] = v end
    for k, v in pairs(extra) do st[k] = (st[k] or 0) + v end
    item.st, item.id, item._rolled, item._rollName = st, id, true, name
    -- Keep which roll this is (negative suffix, positive property): the price
    -- memory keys on it, and the name alone would not survive a locale.
    item._rollId = roll
    return item
end

-- Build a scoreable item table for any link, using GetItemInfo + GetItemStats.
-- Returns nil if the item isn't equippable or isn't cached yet.
-- A rolled item the data knows is answered from the data (S.RolledItem).
function S.LiveItem(link)
    local rolled = S.RolledItem(link)
    if rolled then return rolled end
    if type(GetItemInfo) ~= "function" then return nil, "pending" end
    local id = tonumber((link or ""):match("item:(%d+)"))
    local name, _, q, ilvl, req, _, _, _, equip, _, _, classID, subID, bind = GetItemInfo(link)
    if not name then return nil, "pending" end
    if not equip or equip == "" or equip == "INVTYPE_NON_EQUIP" then
        return nil, "unpriceable"
    end
    local st, sockets = S.LiveStats(link)
    if not st then return nil, "pending" end
    -- A concrete random roll must contribute a live stat. An empty table can
    -- arrive before the item cache is complete; scoring only intrinsic weapon
    -- fields here would recreate a smaller version of the +1019% bug.
    if S.LinkSuffix(link) and not next(st) then return nil, "pending" end
    -- A random roll changes attributes, not the base weapon damage or speed.
    -- Some client stat tables omit these fields. Fill only intrinsic fields
    -- from the known base, never the best possible suffix or other attributes.
    local base = ns.db and ns.db[id]
    if base and base.st then
        for _, key in ipairs({ "dps", "spd", "armor" }) do
            if st[key] == nil then st[key] = base.st[key] end
        end
    end
    local item = {
        id = id, n = name, ilvl = ilvl, req = req or 0, slot = equip,
        ic = classID, sc = subID, q = q, bind = bind, st = st,
        _live = true,
    }
    -- Sockets: the data's, with their bonus, when it knows the item (the same
    -- answer the recommendation gets); otherwise the client's, which names the
    -- colors but not the bonus.
    if base then
        item.sk, item.sb = base.sk, base.sb
    else
        item.sk = sockets
    end
    return item
end

-- EquippedScore returns score, itemID, item, isLive, state. The state is
-- ready, pending, empty or unpriceable; missing data is never a zero score.
-- Does this link carry a random suffix ("of the Bear")? Field 7 of an item link
-- is the suffix id, negative for the random ones.
--   item:ID:enchant:gem1:gem2:gem3:gem4:SUFFIX:uniqueID:...
function S.LinkSuffix(link)
    if not link then return nil end
    local suffix = link:match("item:%d+:%d*:%d*:%d*:%d*:%d*:(%-?%d+)")
    suffix = tonumber(suffix)
    if suffix and suffix ~= 0 then return suffix end
    return nil
end

-- Which purchase a link is: itemID plus the roll, and nothing else. Enchant,
-- gems, uniqueID and level are not part of it. The roll keeps its sign
-- (negative = random suffix, positive = random property): -5 and 5 are
-- different rolls of different tables and must never be merged.
--   * an item the data knows that does not roll            -> id, 0
--   * an item that rolls and whose link names its roll     -> id, roll
--   * an item that rolls and whose link names none         -> id, nil (unknown;
--     never 0, which is the identity of the fixed items)
--   * a roll of the wrong kind for its item (positive on a suffix item)
--     is as unknown as none.
-- Nothing here reads the localised name.
function S.LinkIdentity(link)
    local id = tonumber((link or ""):match("item:(%d+)"))
    if not id then return nil end
    local roll = S.LinkSuffix(link)
    local base = ns.db and ns.db[id]
    if base and base.sg then
        if roll and roll < 0 then return id, roll end
        return id, nil
    elseif base and base.pg then
        if roll and roll > 0 then return id, roll end
        return id, nil
    elseif base then
        return id, 0
    end
    return id, roll or 0
end

-- Remove enchant and gem fields while preserving the concrete random roll.
-- GetItemStats reads the whole hyperlink; scoring the original link would make
-- an equipped gem or enchant part of one side of the comparison even though
-- recommendations contain neither. Real gems and enchants therefore count on
-- neither side. What does count, on both, is the sockets: an item with item
-- level 100 or more is priced with the ideal gem in each (S.SocketInfo), and
-- the sockets are read from the data or, for an item outside it, from the
-- EMPTY_SOCKET_* keys that GetItemStats returns for this stripped link.
function S.UnmodifiedLink(link)
    local id = tonumber((link or ""):match("item:(%d+)"))
    if not id then return link end
    local suffix = S.LinkSuffix(link) or 0
    return ("item:%d:0:0:0:0:0:%d:0:0:0"):format(id, suffix)
end

function S.EquippedScore(slotID, weights, targetLevel)
    local link = GetInventoryItemLink("player", slotID)
    if not link then return nil, nil, nil, false, "empty" end
    local id = tonumber(link:match("item:(%d+)"))
    local item = ns.db and ns.db[id]
    -- The static DB stores the BASE item, and the suffix stats are not in it:
    -- the DBCs that hold them are not in the world database. So a "Chestguard
    -- of the Bear" would score as a bare chestguard -- often zero -- and every
    -- recommendation would look like an upgrade over what you are wearing. When
    -- the link says there is a suffix, LiveItem adds that exact roll from
    -- Data/random.lua (S.RolledItem); only a roll the data does not know falls
    -- back to the client's own numbers.
    if item and not S.LinkSuffix(link) then
        item.id = id
        local score = S.ScoreForSlot(item, weights, slotID, targetLevel)
        return score, id, item, false, score > 0 and "ready" or "unpriceable"
    end
    local live, state = S.LiveItem(S.UnmodifiedLink(link))
    if not live then
        return nil, id, nil, false, state
    end
    live.id = id
    local score = S.ScoreForSlot(live, weights, slotID, targetLevel)
    return score, id, live, true, score > 0 and "ready" or "unpriceable"
end

-- Local comparison value for the caster-wand fallback. This never enters the
-- Pawn score; it is used only when the ranged slot has no positive weighted
-- candidate and needs to order otherwise statless wands.
function S.EquippedWandDps(slotID)
    local id = S.EquippedItemID(slotID)
    local item = id and ns.db and ns.db[id]
    if item and item.sc == 19 and item.st then return item.st.dps or 0 end
    return 0
end

-- Explain one score as concrete value x weight contributions. The caller owns
-- presentation; stable ordering is supplied here so chat output and tests do
-- not depend on Lua table iteration order.
function S.Explain(item, weights, slotID, offhand)
    weights = weights or S._activeWeights
    if not (item and weights) then return nil end
    local ranged = RANGED_SLOT[item.slot]
    local parts = {}
    -- La misma escala por nivel que usa ScoreForSlot, para que las partes sumen.
    local levelMultiplier = S.Option("levelScale") and S.RatingScale(scoreLevel()) or 1
    local function addStats(st, origin)
        for _, key in ipairs(ns.STAT_KEYS) do
            local value = st and st[key]
            local weight
            if ranged and key == "dps" then weight = weights.rdps or weights.dps
            else weight = weights[key] end
            if weight and RATING_KEYS[key] and levelMultiplier ~= 1 then
                weight = weight * levelMultiplier
            end
            local factor = 1
            if slotID == 17 and key == "dps" and OFFHAND_WEAPON_INV[item.slot] then
                factor = 0.5
            end
            local points = value and weight and value * weight * factor or 0
            if points ~= 0 then
                parts[#parts+1] = {
                    key = key, value = value, weight = weight,
                    points = points, origin = origin,
                }
            end
        end
    end
    addStats(item.st, "base")
    local _, suffix, variantStats = S.BestVariant(item, weights)
    addStats(variantStats, "suffix")
    -- The stats of the ideal gems (and the socket bonus when it is used) are
    -- parts like any other, so the parts still add up to the total.
    local socket = S.SocketInfo(item, weights)
    addStats(socket and socket.stats, "socket")
    local socketPoints = 0
    for _, part in ipairs(parts) do
        if part.origin == "socket" then socketPoints = socketPoints + part.points end
    end
    local setPoints = S.SetBonus(item, weights, slotID)
    table.sort(parts, function(a, b)
        local aa, bb = math.abs(a.points), math.abs(b.points)
        if aa ~= bb then return aa > bb end
        if a.origin ~= b.origin then return a.origin < b.origin end
        return a.key < b.key
    end)
    local adjustment, ability = S.WeaponAdjustment(item, weights, slotID)
    local total = S.ScoreForSlot(item, weights, slotID)
    return { total = total, parts = parts, suffix = suffix,
             socket = socket, socketPoints = socketPoints,
             setPoints = setPoints, slotID = slotID,
             weaponPoints=adjustment, weaponAbility=ability,
             hitCapPoints = S.HitCapAdjustment(item, weights, slotID),
             levelScale = levelMultiplier }
end

-- Where does this item rank within its slot pool, for the active spec?
-- Uses effective level = max(targetLevel, item.req) so a not-yet-usable item is
-- ranked among the pool it would compete in. Returns:
--   rank(number), score(number), slotName(string), effLevel(number)
-- or nil if the class can't use it or it has no score.
function S.RankOf(itemId, targetLevel, weights, classToken, level, filters, slotHint)
    S.SetIgnoreRandom(filters and filters.noRandom)
    local db = ns.db
    local item = db and db[itemId]
    if not item or not item.slot then return nil end
    local slotName = slotHint or S.INVTYPE_SLOT[item.slot]
    local def = slotName and S.SLOTS[slotName]
    if not def or not def.inv[item.slot] then return nil end
    if not passFilters(item, filters or {}, itemId) then return nil end
    local gate = filters and filters.onlyReachable == false and (item.req or 0)
                 or S.ReachLevel(item, filters, itemId)
    local effLevel = math.min(70, math.max(targetLevel or 0, gate))
    if gate > effLevel then return nil end
    if not S.Recommendable(item, classToken, effLevel, profileSpec(weights, classToken)) then return nil end
    if not S.CanUse(item, classToken, effLevel, false) then return nil end
    if slotName == "mainhand" or slotName == "offhand" then
        local setup = S.BestWeaponSetup(effLevel, weights, classToken, level, filters)
        local bestRank, bestScore, bestSlot
        for _, hand in ipairs({ "mainhand", "offhand" }) do
            if (not slotHint or hand == slotHint) and S.SLOTS[hand].inv[item.slot]
               and not (hand == "offhand" and setup.better == "2h") then
                local allowed, exclude
                if hand == "mainhand" then
                    allowed = setup.better == "2h" and S.TWO_HAND_INV or S.ONE_HAND_INV
                else
                    allowed = setup.required == "shield" and S.SHIELD_INV
                              or setup.required == "dual" and S.OFFHAND_WEAPON_INV or nil
                    if setup.one.mh then exclude = { [setup.one.mh.id]=true } end
                end
                local rows = S.RankSlot(hand, effLevel, weights, classToken, level,
                                       filters, math.huge, exclude, allowed)
                for rank, entry in ipairs(rows) do
                    if entry.id == itemId and (not bestRank or rank < bestRank) then
                        bestRank, bestScore, bestSlot = rank, entry.score, hand
                    end
                end
            end
        end
        if not bestRank then return nil end
        return bestRank, bestScore, bestSlot, effLevel
    end
    -- Use the same armor fallback, paired exclusion and noise floor as the UI.
    local exclude
    local first = PAIR_SECOND[slotName]
    if first then
        local won = S.RankSlot(first, effLevel, weights, classToken, level, filters, 1)[1]
        if won then exclude = { [won.id] = true } end
    end
    local rows = S.RankSlot(slotName, effLevel, weights, classToken, level,
                           filters, math.huge, exclude)
    for rank, entry in ipairs(rows) do
        if entry.id == itemId and not entry.fallback then
            return rank, entry.score, slotName, effLevel
        end
    end
end

-- Delta helpers
function S.Delta(recScore, equipScore)
    equipScore = equipScore or 0
    local abs = recScore - equipScore
    local pct = (equipScore > 0) and (abs / equipScore * 100) or nil
    return abs, pct
end
