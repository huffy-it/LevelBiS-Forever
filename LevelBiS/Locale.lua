-- Locale.lua ----------------------------------------------------------------
-- English is the source text: every visible string is written in English and
-- looked up through ns.L. A locale file (Locales/*.lua) fills ns.L only when
-- the client runs that language; a missing entry falls back to the English.
------------------------------------------------------------------------------
local ADDON, ns = ...

ns.LOCALE = (GetLocale and GetLocale()) or "enUS"
ns.L = setmetatable({}, { __index = function(_, key) return key end })

-- Instance names in the data are English (cmangos). The client knows every
-- instance by its map ID in its own language, so the name shown is the
-- client's, with the English one as the fallback. Map IDs from the same
-- cmangos build the data comes from.
local INSTANCE_MAP = {
    ["Ahn'Qiraj Temple"] = 531,
    ["Altar of Atal'Hakkar"] = 109,
    ["Alterac Valley"] = 30,
    ["Auchenai Crypts"] = 558,
    ["Black Temple"] = 564,
    ["Blackfathom Deeps"] = 48,
    ["Blackrock Depths"] = 230,
    ["Blackrock Spire"] = 229,
    ["Blackwing Lair"] = 469,
    ["Deadmines"] = 36,
    ["Dire Maul"] = 429,
    ["Gnomeregan"] = 90,
    ["Gruul's Lair"] = 565,
    ["Hellfire Ramparts"] = 543,
    ["Hyjal Summit"] = 534,
    ["Karazhan"] = 532,
    ["Magisters' Terrace"] = 585,
    ["Magtheridon's Lair"] = 544,
    ["Mana Tombs"] = 557,
    ["Maraudon"] = 349,
    ["Molten Core"] = 409,
    ["Naxxramas"] = 533,
    ["Old Hillsbrad Foothills"] = 560,
    ["Onyxia's Lair"] = 249,
    ["Ragefire Chasm"] = 389,
    ["Razorfen Downs"] = 129,
    ["Razorfen Kraul"] = 47,
    ["Ruins of Ahn'Qiraj"] = 509,
    ["Scarlet Monastery"] = 189,
    ["Scholomance"] = 289,
    ["Serpentshrine Cavern"] = 548,
    ["Sethekk Halls"] = 556,
    ["Shadow Labyrinth"] = 555,
    ["Shadowfang Keep"] = 33,
    ["Stormwind Stockades"] = 34,
    ["Stratholme"] = 329,
    ["Sunwell Plateau"] = 580,
    ["The Arcatraz"] = 552,
    ["The Black Morass"] = 269,
    ["The Blood Furnace"] = 542,
    ["The Botanica"] = 553,
    ["The Eye"] = 550,
    ["The Mechanar"] = 554,
    ["The Shattered Halls"] = 540,
    ["The Slave Pens"] = 547,
    ["The Steamvault"] = 545,
    ["The Underbog"] = 546,
    ["Uldaman"] = 70,
    ["Wailing Caverns"] = 43,
    ["Zul'Aman"] = 568,
    ["Zul'Farrak"] = 209,
    ["Zul'Gurub"] = 309,
}

local instanceCache = {}
function ns.InstanceLabel(name)
    if not name then return nil end
    local cached = instanceCache[name]
    if cached then return cached end
    local label = name
    local id = INSTANCE_MAP[name]
    if id and GetRealZoneText then
        local ok, localized = pcall(GetRealZoneText, id)
        if ok and type(localized) == "string" and localized ~= "" then label = localized end
    end
    instanceCache[name] = label
    return label
end

-- Spec names are identifiers (saved, compared); this is the name to show.
function ns.SpecLabel(spec)
    return spec and ns.L[spec] or "?"
end
