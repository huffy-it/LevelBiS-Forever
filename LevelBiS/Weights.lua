-- Weights.lua ---------------------------------------------------------------
-- Canonical stat keys, per-spec default stat weights, and Pawn string I/O.
-- Everything downstream (Scoring, Data, UI) uses the canonical keys below.
------------------------------------------------------------------------------
local ADDON, ns = ...
local L = ns.L

-- Canonical stat keys. The pipeline normalizes every source stat to one of
-- these; presets and item.st tables only ever use these keys.
ns.STAT_KEYS = {
    "str","agi","sta","int","spi",
    "ap","rap","feralap","sp","heal","mp5",
    "hit","spellhit","crit","spellcrit","haste","spellhaste","expertise",
    "dodge","parry","block","blockval","def","resil",
    "arcanesp","firesp","frostsp","holysp","naturesp","shadowsp","spen",
    -- `dps` is the weapon damage of whatever is in the slot; `rdps` is the
    -- same number when the slot is a bow, gun or thrown weapon. They are two
    -- keys because they are two different things to a hunter and the same
    -- thing to everyone else, and an item cannot say which it is -- its slot
    -- says it. A profile that leaves `rdps` unset falls back to `dps`, which is
    -- why every non-hunter preset sets it to zero explicitly: the published
    -- scales all say RangedDps=0, and dropping a zero would have meant "use
    -- the melee weight instead" -- a fury warrior's gun scored more than any
    -- piece of armour in the game.
    "armor","dps","rdps","spd",
}

local W = {}
ns.Weights = W

-- Bumped whenever the presets change in a way that makes already-saved profiles
-- wrong rather than merely different. Core compares it against the number in
-- SavedVariables and re-seeds the profiles when they disagree, because a profile
-- saved by an older build keeps its old numbers forever otherwise -- fixing the
-- presets would change nothing for anyone who had already logged in.
-- 2: ratings rescaled; they had been 5-10x above primary stats.
-- 3: replaced wholesale by the published 2.4.3 scales (see below).
-- 4: rdps, spd, the hunter's halved mana and the caster wand weight. A profile
--    seeded at 3 has no `rdps` at all, and an absent rdps falls back to the
--    melee weight -- which is how a level 68 warrior ended up with a rifle
--    scoring 308, second only to his main hand.
-- 5: parity with Pawn's published TBC scales for every supported stat. Removes
--    the levelling adjustments to stamina, hunter mana and caster wand DPS.
W.PRESET_REVISION = 5

------------------------------------------------------------------------------
-- Talent-tab order per class (used to auto-detect the active spec at login).
-- Index = in-game talent tab index (1..3).
------------------------------------------------------------------------------
W.SPEC_TABS = {
    WARRIOR = { "Arms", "Fury", "Protection" },
    PALADIN = { "Holy", "Protection", "Retribution" },
    HUNTER  = { "Beast Mastery", "Marksmanship", "Survival" },
    ROGUE   = { "Assassination", "Combat", "Subtlety" },
    PRIEST  = { "Discipline", "Holy", "Shadow" },
    SHAMAN  = { "Elemental", "Enhancement", "Restoration" },
    MAGE    = { "Arcane", "Fire", "Frost" },
    WARLOCK = { "Affliction", "Demonology", "Destruction" },
    DRUID   = { "Balance", "Feral (Cat)", "Restoration" }, -- tab 2 defaults to Cat
}

-- Full selectable spec list (adds specs not distinguishable by talent tab).
W.SPEC_LIST = {
    WARRIOR = { "Arms", "Fury", "Protection" },
    PALADIN = { "Holy", "Protection", "Retribution" },
    HUNTER  = { "Beast Mastery", "Marksmanship", "Survival" },
    ROGUE   = { "Assassination", "Combat", "Subtlety" },
    PRIEST  = { "Discipline", "Holy", "Shadow" },
    SHAMAN  = { "Elemental", "Enhancement", "Restoration" },
    MAGE    = { "Arcane", "Fire", "Frost" },
    WARLOCK = { "Affliction", "Demonology", "Destruction" },
    DRUID   = { "Balance", "Feral (Cat)", "Feral (Bear)", "Restoration" },
}

------------------------------------------------------------------------------
-- Default presets.
--
-- These are the published TBC 2.4.3 Pawn scales, derived from Elitist Jerks
-- and maxdps at the time, one per class and spec, normalised so that the
-- spec's primary stat is 1 -- strength for a strength melee, agility for an
-- agility melee, intellect for a healer, spell damage for a caster, stamina
-- for a tank. That is Pawn's own convention, which matters twice over: a
-- scale pasted in from elsewhere lands on the same footing as these, and what
-- `/lbis export` produces is readable by any Pawn user.
--
-- The values below are transcribed, not adjusted for levelling. Four kinds of entry in the source do not
-- survive the trip, because the addon has no such stat to weigh: armour
-- penetration, flat health and mana, health per five and resistances. Gems
-- and enchants you have already put in are deliberately excluded from both
-- sides of an item comparison. Sockets are not: since 0.19.0-sockets the
-- engine prices every socket of an item with item level 100 or more with the
-- best gem for these weights, on both sides, as Pawn does (Scoring.lua,
-- "Sockets"); the weights themselves are untouched. Nothing else was changed,
-- and no number was rounded.
--
-- Pawn gives caster wand DPS a weight of zero. LevelBiS still lists statless
-- wands by their own DPS when the ranged slot has no positive weighted result,
-- but that local ordering never enters the Pawn score or cross-slot gains.
--
-- WHY THE PRESETS BEFORE THESE WERE WRONG, twice over:
--
--   Revision 1 priced a point of combat rating above a point of primary stat
--   ("crit=10" against "str=2"). At level 70, 22.08 crit rating is 1% crit --
--   about one attack power, or half a strength. Vanilla gear beat Outland gear
--   in every slot.
--
--   Revision 2 fixed the ratings by hand and got the shape roughly right, but
--   the numbers were estimates written here rather than anyone's simulation
--   output.
--
-- The rogue's three specs share one scale: the source publishes rogue weights
-- per weapon slot (main hand, offhand, dagger ambush) rather than per talent
-- tree, and the main-hand scale is the one that describes armour.
--
-- THRESHOLDS STILL DO NOT FIT IN A LINEAR SCALE. Hit up to the cap is worth
-- far more than hit past it, and defense rating is prized only until 490
-- defense makes a tank crit-immune. A weighted sum cannot say either; the hit
-- weights assume you are under the cap, which while levelling you always are.
------------------------------------------------------------------------------
local T = {}

T.arms = { str=1, agi=0.69, sta=0.1, spi=0.05, ap=0.45, hit=1, crit=0.85,
           haste=0.57, expertise=1, dodge=0.05, parry=0.05, def=0.05,
           resil=0.2, armor=0.005, dps=5.31, rdps=0 }
T.fury = { str=1, agi=0.57, sta=0.1, spi=0.05, ap=0.54, hit=0.57,
           crit=0.7, haste=0.41, expertise=0.57, dodge=0.05, parry=0.12,
           def=0.05, resil=0.2, armor=0.005, dps=5.22, rdps=0 }
T.warprot = { str=0.33, agi=0.59, sta=1, spi=0.05, ap=0.06, hit=0.67,
              crit=0.28, haste=0.21, expertise=0.67, dodge=0.7, parry=0.58,
              block=0.59, blockval=0.35, def=0.81, resil=0.2, armor=0.02,
              dps=3.13, rdps=0 }
T.ret = { str=1, agi=0.64, sta=0.1, int=0.34, spi=0.05, ap=0.41, sp=0.33,
          mp5=1, hit=0.84, spellhit=0.21, crit=0.66, spellcrit=0.12,
          haste=0.25, spellhaste=0.04, expertise=0.87, dodge=0.05,
          parry=0.05, def=0.05, resil=0.2, holysp=0.33, spen=0.015,
          armor=0.005, dps=5.4, rdps=0 }
T.palaprot = { str=0.2, agi=0.6, sta=1, int=0.5, spi=0.05, ap=0.06, sp=0.44,
               mp5=1, hit=0.16, spellhit=0.78, crit=0.15, spellcrit=0.6,
               haste=0.5, spellhaste=0.12, expertise=0.27, dodge=0.7,
               parry=0.6, block=0.6, blockval=0.15, def=0.7, resil=0.2,
               holysp=0.44, spen=0.03, armor=0.02, dps=1.77, rdps=0 }
T.palaholy = { agi=0.05, sta=0.1, int=1, spi=0.28, heal=0.54, mp5=1.24,
               spellcrit=0.46, spellhaste=0.39, dodge=0.05, parry=0.05,
               block=0.01, def=0.05, resil=0.2, armor=0.005, rdps=0 }
T.huntbm = { str=0.05, agi=1, sta=0.1, int=0.8, spi=0.05, ap=0.43, rap=0.43,
             mp5=2.4, hit=1, crit=0.8, haste=0.5, expertise=0.05,
             dodge=0.05, parry=0.05, def=0.05, resil=0.2, armor=0.005,
             dps=0.75, rdps=2.4 }
T.huntmm = { str=0.05, agi=1, sta=0.1, int=0.9, spi=0.05, ap=0.55, rap=0.55,
             mp5=2.4, hit=1, crit=0.6, haste=0.4, expertise=0.05,
             dodge=0.05, parry=0.05, def=0.05, resil=0.2, armor=0.005,
             dps=0.75, rdps=2.6 }
T.huntsv = { str=0.05, agi=1, sta=0.1, int=0.8, spi=0.05, ap=0.55, rap=0.55,
             mp5=2.4, hit=1, crit=0.65, haste=0.4, expertise=0.05,
             dodge=0.05, parry=0.05, def=0.05, resil=0.2, armor=0.005,
             dps=1, rdps=2.4 }
T.rogue = { str=0.5, agi=1, sta=0.1, spi=0.05, ap=0.45, hit=1, crit=0.81,
            haste=0.9, expertise=1.1, dodge=0.05, parry=0.12, def=0.05,
            resil=0.2, armor=0.005, dps=3, rdps=0 }
T.priestholy = { agi=0.05, sta=0.1, int=1, spi=0.73, heal=0.81, mp5=1.35,
                 spellcrit=0.24, spellhaste=0.6, dodge=0.05, parry=0.05,
                 def=0.05, resil=0.2, armor=0.005, rdps=0 }
T.priestdisc = { agi=0.05, sta=0.1, int=1, spi=0.48, heal=0.72, mp5=1.19,
                 spellcrit=0.32, spellhaste=0.57, dodge=0.05, parry=0.05,
                 def=0.05, resil=0.2, armor=0.005, rdps=0 }
T.priestshadow = { agi=0.05, sta=0.1, int=0.19, spi=0.21, sp=1, mp5=1,
                   spellhit=1.12, spellcrit=0.76, spellhaste=0.65, dodge=0.05,
                   parry=0.05, def=0.05, resil=0.2, shadowsp=1, spen=0.08,
                   armor=0.005, rdps=0 }
T.shamele = { agi=0.05, sta=0.1, int=0.31, spi=0.09, sp=1, mp5=1.14,
              spellhit=0.9, spellcrit=1.05, spellhaste=0.9, dodge=0.05,
              parry=0.12, block=0.01, def=0.05, resil=0.2, naturesp=1,
              spen=0.38, armor=0.005, rdps=0 }
T.shamenh = { str=1, agi=0.87, sta=0.1, int=0.34, spi=0.05, ap=0.5, sp=0.3,
              mp5=1, hit=0.67, spellhit=0.223, crit=0.98, spellcrit=0.326,
              haste=0.64, spellhaste=0.08, expertise=1.5, dodge=0.05,
              parry=0.05, def=0.05, resil=0.2, naturesp=0.3, spen=0.11,
              armor=0.005, dps=3, rdps=0 }
T.shamresto = { agi=0.05, sta=0.1, int=1, spi=0.61, heal=0.9, mp5=1.33,
                spellcrit=0.48, spellhaste=0.74, dodge=0.05, parry=0.05,
                block=0.01, def=0.05, resil=0.2, armor=0.005, rdps=0 }
T.magearcane = { agi=0.05, sta=0.1, int=0.46, spi=0.59, sp=1, mp5=1.13,
                 spellhit=0.87, spellcrit=0.6, spellhaste=0.59, dodge=0.05,
                 parry=0.05, def=0.05, resil=0.2, arcanesp=0.88, firesp=0.064,
                 frostsp=0.52, spen=0.09, armor=0.005, rdps=0 }
T.magefire = { agi=0.05, sta=0.1, int=0.44, spi=0.066, sp=1, mp5=0.9,
               spellhit=0.93, spellcrit=0.77, spellhaste=0.82, dodge=0.05,
               parry=0.05, def=0.05, resil=0.2, arcanesp=0.168, firesp=0.94,
               frostsp=0.32, spen=0.09, armor=0.005, rdps=0 }
T.magefrost = { agi=0.05, sta=0.1, int=0.37, spi=0.06, sp=1, mp5=0.8,
                spellhit=1.22, spellcrit=0.58, spellhaste=0.63, dodge=0.05,
                parry=0.05, def=0.05, resil=0.2, arcanesp=0.13, firesp=0.05,
                frostsp=0.95, spen=0.07, armor=0.005, rdps=0 }
T.lockafl = { agi=0.05, sta=0.1, int=0.4, spi=0.1, sp=1, mp5=1, spellhit=1.2,
              spellcrit=0.39, spellhaste=0.78, dodge=0.05, parry=0.05,
              def=0.05, resil=0.2, firesp=0.35, shadowsp=0.91, spen=0.08,
              armor=0.005, rdps=0 }
T.lockdemo = { agi=0.05, sta=0.1, int=0.4, spi=0.5, sp=1, mp5=1, spellhit=1.2,
               spellcrit=0.66, spellhaste=0.7, dodge=0.05, parry=0.05,
               def=0.05, resil=0.2, firesp=0.8, shadowsp=0.8, spen=0.08,
               armor=0.005, rdps=0 }
T.lockdest = { agi=0.05, sta=0.1, int=0.34, spi=0.25, sp=1, mp5=0.65,
               spellhit=1.6, spellcrit=0.87, spellhaste=1.15, dodge=0.05,
               parry=0.05, def=0.05, resil=0.2, firesp=0.23, shadowsp=0.95,
               spen=0.08, armor=0.005, rdps=0 }
T.druidbal = { agi=0.05, sta=0.1, int=0.38, spi=0.34, sp=1, mp5=0.58,
               spellhit=1.21, spellcrit=0.62, spellhaste=0.8, dodge=0.05,
               parry=0.05, def=0.05, resil=0.2, arcanesp=0.64, naturesp=0.43,
               spen=0.21, armor=0.005, rdps=0 }
T.druidcat = { str=1.48, agi=1, sta=0.1, int=0.1, spi=0.05, ap=0.59,
               feralap=0.59, heal=0.025, mp5=0.3, hit=0.61, crit=0.59,
               haste=0.43, expertise=0.61, dodge=0.05, parry=0.05, def=0.05,
               resil=0.2, armor=0.02, rdps=0 }
T.druidbear = { str=0.2, agi=0.48, sta=1, int=0.1, spi=0.05, ap=0.34,
                feralap=0.34, heal=0.025, mp5=0.3, hit=0.16, crit=0.15,
                haste=0.31, expertise=0.18, dodge=0.38, def=0.26, resil=0.2,
                naturesp=0.025, armor=0.1, rdps=0 }
T.druidresto = { agi=0.05, sta=0.1, int=1, spi=0.87, heal=1.21, mp5=1.7,
                 spellcrit=0.35, spellhaste=0.49, dodge=0.05, parry=0.05,
                 def=0.05, resil=0.2, armor=0.005, rdps=0 }

W.PRESETS = {
    WARRIOR = { ["Arms"]=T.arms, ["Fury"]=T.fury, ["Protection"]=T.warprot },
    PALADIN = {
        ["Holy"]=T.palaholy, ["Protection"]=T.palaprot, ["Retribution"]=T.ret,
    },
    HUNTER = {
        ["Beast Mastery"]=T.huntbm, ["Marksmanship"]=T.huntmm,
        ["Survival"]=T.huntsv,
    },
    ROGUE = { ["Assassination"]=T.rogue, ["Combat"]=T.rogue, ["Subtlety"]=T.rogue },
    PRIEST = {
        ["Discipline"]=T.priestdisc, ["Holy"]=T.priestholy,
        ["Shadow"]=T.priestshadow,
    },
    SHAMAN = {
        ["Elemental"]=T.shamele, ["Enhancement"]=T.shamenh,
        ["Restoration"]=T.shamresto,
    },
    MAGE = {
        ["Arcane"]=T.magearcane, ["Fire"]=T.magefire, ["Frost"]=T.magefrost,
    },
    WARLOCK = {
        ["Affliction"]=T.lockafl, ["Demonology"]=T.lockdemo,
        ["Destruction"]=T.lockdest,
    },
    DRUID = {
        ["Balance"]=T.druidbal, ["Feral (Cat)"]=T.druidcat,
        ["Feral (Bear)"]=T.druidbear, ["Restoration"]=T.druidresto,
    },
}

------------------------------------------------------------------------------
-- Pawn string interop.  Maps our canonical keys <-> Pawn stat identifiers so
-- users can paste a Pawn/Wowhead/AMR weight string, or export ours to them.
------------------------------------------------------------------------------
W.PAWN_MAP = {
    Strength="str", Agility="agi", Stamina="sta", Intellect="int", Spirit="spi",
    Ap="ap", Rap="rap", FeralAp="feralap",
    HitRating="hit", SpellHitRating="spellhit",
    CritRating="crit", SpellCritRating="spellcrit",
    HasteRating="haste", SpellHasteRating="spellhaste",
    ExpertiseRating="expertise",
    SpellDamage="sp", Healing="heal", Mp5="mp5", SpellPenetration="spen",
    DodgeRating="dodge", ParryRating="parry", BlockRating="block",
    BlockValue="blockval", DefenseRating="def", Resilience="resil",
    ResilienceRating="resil",
    Armor="armor", MeleeDps="dps", RangedDps="rdps",
    ArcaneSpellDamage="arcanesp", FireSpellDamage="firesp",
    FrostSpellDamage="frostsp", HolySpellDamage="holysp",
    NatureSpellDamage="naturesp", ShadowSpellDamage="shadowsp",
    -- common aliases seen in the wild
    Hit="hit", Crit="crit", Haste="haste", Dodge="dodge", Parry="parry",
    Dps="dps",
}
-- reverse map for export (canonical -> preferred Pawn name)
local PAWN_OUT = {}
do
    local pref = {
        str="Strength", agi="Agility", sta="Stamina", int="Intellect", spi="Spirit",
        ap="Ap", rap="Rap", feralap="FeralAp",
        hit="HitRating", spellhit="SpellHitRating",
        crit="CritRating", spellcrit="SpellCritRating", haste="HasteRating",
        spellhaste="SpellHasteRating", expertise="ExpertiseRating",
        sp="SpellDamage", heal="Healing", mp5="Mp5", spen="SpellPenetration",
        dodge="DodgeRating", parry="ParryRating", block="BlockRating",
        blockval="BlockValue", def="DefenseRating", resil="Resilience",
        armor="Armor", dps="MeleeDps", rdps="RangedDps",
        arcanesp="ArcaneSpellDamage", firesp="FireSpellDamage",
        frostsp="FrostSpellDamage", holysp="HolySpellDamage",
        naturesp="NatureSpellDamage", shadowsp="ShadowSpellDamage",
    }
    for k, v in pairs(pref) do PAWN_OUT[k] = v end
end

-- Parse a Pawn scale string into { weights=table, name=str, class=str, spec=str }.
-- Returns nil, errmsg on failure. Tolerant of spacing and unknown stats.
function W.ImportPawn(str)
    if type(str) ~= "string" then return nil, L["not a string"] end
    local body = str:match("%(%s*Pawn%s*:%s*v%d+%s*:%s*(.-)%s*%)")
    if not body then return nil, L["not a Pawn v1 string"] end
    local name = body:match('^%s*"(.-)"') or "Imported"
    local class = body:match("Class%s*=%s*(%a+)")
    local spec  = body:match("Spec%s*=%s*(%a+)")
    local weights, found, ignored, ignoredSet = {}, false, {}, {}
    for stat, val in body:gmatch("([%a][%w]*)%s*=%s*(-?%d*%.?%d+)") do
        local key = W.PAWN_MAP[stat]
        if key then
            weights[key] = tonumber(val); found = true
        elseif stat ~= "Class" and stat ~= "Spec" and not ignoredSet[stat] then
            ignoredSet[stat] = true
            ignored[#ignored + 1] = stat
        end
    end
    if not found then return nil, L["no recognized stats"] end
    table.sort(ignored)
    return { weights = weights, name = name, class = class, spec = spec,
             ignored = ignored }
end

-- Build a Pawn string from a weights table.
function W.ExportPawn(classToken, specName, weights)
    local parts = {}
    if classToken then parts[#parts+1] = "Class=" .. classToken:sub(1,1) .. classToken:sub(2):lower() end
    if specName then parts[#parts+1] = "Spec=" .. specName:gsub("%s","") end
    for k in pairs(weights) do
        local pn = PAWN_OUT[k]
        if pn then parts[#parts+1] = pn .. "=" .. tostring(weights[k]) end
    end
    local label = (classToken and specName) and (classToken:sub(1,1)..classToken:sub(2):lower()..": "..specName) or "LevelBiS"
    return string.format('( Pawn: v1: "%s": %s )', label, table.concat(parts, ", "))
end

------------------------------------------------------------------------------
-- Runtime helpers
------------------------------------------------------------------------------

-- Copy the preset for class/spec (never hand out the shared preset table).
local contexts = setmetatable({}, { __mode = "k" })
function W.RegisterContext(weights, classToken, specName)
    contexts[weights] = { class=classToken, spec=specName }
end
function W.Context(weights)
    return contexts[weights]
end

function W.Default(classToken, specName)
    local byClass = W.PRESETS[classToken]
    local preset = byClass and (byClass[specName] or select(2, next(byClass)))
    local out = {}
    if preset then for k, v in pairs(preset) do out[k] = v end end
    W.RegisterContext(out, classToken, specName)
    return out
end

-- List of selectable spec names for a class.
function W.SpecsFor(classToken)
    return W.SPEC_LIST[classToken] or {}
end

-- Points spent in one talent tab. The TBC Anniversary client has been seen
-- returning 0 from GetTalentTabInfo's pointsSpent for every tab, which made the
-- first spec win for everybody (documented by PickItRight against a real
-- 10/0/44 mage). Summing the rank of each talent is what reports the build
-- correctly; pointsSpent stays as the fallback for a client without
-- GetTalentInfo. tonumber() because a not-yet-synced value can arrive as "".
-- The extra parentheses keep select() to one value: tonumber() takes a second
-- argument as the base, and GetTalentInfo's next value is the talent's max
-- rank -- a 1-rank talent made it base 1, an error that stopped the login.
local function tabPoints(tab)
    local sum = 0
    if type(GetNumTalents) == "function" and type(GetTalentInfo) == "function" then
        for i = 1, (tonumber(GetNumTalents(tab)) or 0) do
            sum = sum + (tonumber((select(5, GetTalentInfo(tab, i)))) or 0)
        end
    end
    if sum == 0 and type(GetTalentTabInfo) == "function" then
        sum = tonumber((select(3, GetTalentTabInfo(tab)))) or 0
    end
    return sum
end

-- Detect the current spec from talent points; falls back to first spec.
-- Second return: total points seen, so the caller can tell "no talents yet"
-- (or not synced yet) from a real detection.
function W.DetectSpec(classToken)
    local tabs = W.SPEC_TABS[classToken]
    if not tabs then return nil, 0 end
    if type(GetNumTalentTabs) ~= "function" then return tabs[1], 0 end
    local best, bestPts, total = 1, -1, 0
    for i = 1, (tonumber(GetNumTalentTabs()) or 3) do
        local pts = tabPoints(i)
        total = total + pts
        if pts > bestPts then best, bestPts = i, pts end
    end
    return tabs[best] or tabs[1], total
end

-- Active talent group: 1 or 2. TBC Anniversary has dual specialization; a
-- client without it has a single group.
function W.TalentGroup()
    if type(GetActiveTalentGroup) == "function" then
        return tonumber(GetActiveTalentGroup()) or 1
    end
    return 1
end
