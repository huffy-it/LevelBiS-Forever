-- Core.lua ------------------------------------------------------------------
-- Bootstrap, saved variables, DB load, spec/level detection, slash commands.
-- Phase (a): everything is verifiable through /lbis chat commands (no UI yet).
------------------------------------------------------------------------------
local ADDON, ns = ...
local W = ns.Weights
local S = ns.Scoring

local PREFIX = "|cff33ff99LevelBiS|r: "
local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg)) end
ns.Print = Print

------------------------------------------------------------------------------
-- Load the static item DB (built into Data/*.lua as the LevelBiS_ItemDB global).
-- Wrapped in pcall so a malformed data file can never break login.
------------------------------------------------------------------------------
local function LoadDB()
    local ok, err = pcall(function()
        ns.db = LevelBiS_ItemDB or {}
        -- Random suffixes and properties, shared by every item that rolls
        -- them. An item points at a group; Scoring resolves the roll. Missing
        -- tables are not an error: the addon then behaves as it did before the
        -- data existed, which is to score those items on their base stats.
        ns.suffix = LevelBiS_Suffix or {}
        ns.suffixGroup = LevelBiS_SuffixGroup or {}
        ns.property = LevelBiS_Property or {}
        ns.propertyGroup = LevelBiS_PropertyGroup or {}
        ns.set = LevelBiS_Set or {}
        ns.consumables = LevelBiS_Consumables or {}
    end)
    if not ok then
        ns.db = {}
        Print("|cffff4040no pude cargar la base de items:|r " .. tostring(err))
    end
    local n = 0
    for _ in pairs(ns.db) do n = n + 1 end
    ns.dbCount = n
    -- Battleground quartermasters stand outside the battleground, so the
    -- pipeline cannot tell their gear is PvP. See PVP_VENDORS in Scoring.lua.
    if S.MarkPvPVendors then ns.pvpVendorSrc = S.MarkPvPVendors(ns.db) end
    -- Every legendary comes out of a raid, and thirteen of the sixteen arrive
    -- with no content on their source. See MarkLegendaries in Scoring.lua.
    if S.MarkLegendaries then ns.legendarySrc = S.MarkLegendaries(ns.db) end
    if S.MarkPhases then ns.phaseMarked = S.MarkPhases(ns.db) end
    -- Reputation on vendor routes and one-time quests (Access.lua); the
    -- evidence itself is read from the client on PLAYER_LOGIN and on events.
    if ns.Access and ns.Access.MarkRoutes then ns.accessMarked = ns.Access.MarkRoutes(ns.db) end
    if S.InvalidateIndex then S.InvalidateIndex() end
    return n
end

------------------------------------------------------------------------------
-- Saved variables
------------------------------------------------------------------------------
local function InitSV()
    LevelBiSCharDB = LevelBiSCharDB or {}
    local sv = LevelBiSCharDB
    sv.weights = sv.weights or {}          -- [class][spec] = weights table
    sv.settings = sv.settings or {}
    sv.settings.filters = sv.settings.filters or { minQuality = 2 } -- uncommon+
    -- Per-key defaults, so characters with an existing saved filters table
    -- still pick up options added in later versions.
    local flt = sv.settings.filters
    if flt.strictArmor == nil then flt.strictArmor = true end  -- only my armor tier
    if flt.noRaid == nil then flt.noRaid = true end            -- unreachable while levelling
    if flt.noPvP == nil then flt.noPvP = true end
    if flt.noDungeon == nil then flt.noDungeon = false end     -- dungeons are fair game
    -- On by default: without it the window offers gear that needs a profession
    -- (or a rank) you do not have, which is not a recommendation, it is a
    -- shopping list for somebody else.
    if flt.myProfsOnly == nil then flt.myProfsOnly = true end
    if flt.myFactionOnly == nil then flt.myFactionOnly = true end
    if flt.noRep == nil then flt.noRep = false end             -- reputation-gated
    if flt.onlyReachable == nil then flt.onlyReachable = true end
    -- Schema 2 splits the old combined switch without changing an existing
    -- character's result: old `onlyInstance=true` becomes the union of the two
    -- new buckets. The legacy key is then removed so future toggles are truly
    -- independent.
    if flt.onlyInstances == nil and flt.onlyQuests == nil then
        local legacy = flt.onlyInstance and true or false
        flt.onlyInstances, flt.onlyQuests = legacy, legacy
    else
        if flt.onlyInstances == nil then flt.onlyInstances = false end
        if flt.onlyQuests == nil then flt.onlyQuests = false end
    end
    flt.onlyInstance = nil
    sv.filterSchemaRevision = 2
    -- The inverse of excludeBoE: keep only what somebody can sell you. Off by
    -- default, because the window's first job is still "what is best", not
    -- "what is best that I can buy".
    if flt.onlyAH == nil then flt.onlyAH = false end
    -- Off by default: between level 61 and 69 the gear that rolls a random
    -- suffix outnumbers the gear that does not by four to one, so turning this
    -- on by default would hide most of what a levelling character can wear.
    if flt.noRandom == nil then flt.noRandom = false end
    -- Off by default for the same reason as noRandom: most of what a levelling
    -- character can reach in Outland rolls a suffix, and this hides all of it.
    if flt.fixedOnly == nil then flt.fixedOnly = false end
    if flt.fixedOnly then flt.noRandom = false end
    -- Same rule for the auction pair: "Subasta: solo" wins over "excluir", so a
    -- contradictory saved state reads the same in the button and in SetFilter.
    if flt.onlyAH then flt.excludeBoE = false end
    -- Pesos por nivel: aprobado el 6/10/2026, encendido por defecto. Los demás
    -- ajustes son opcionales y arrancan apagados.
    if flt.levelScale == nil then flt.levelScale = true end
    -- Fase del servidor (M-7): por defecto la actual, que se actualiza a mano en
    -- cada versión. Quien no la haya tocado la sigue; quien la fijó, no.
    if flt.maxPhase == nil or flt.maxPhase == sv.phaseDefault then
        flt.maxPhase = S.CURRENT_PHASE
    end
    sv.phaseDefault = S.CURRENT_PHASE
    if flt.ilvlCap == nil then flt.ilvlCap = false end
    if flt.hitCap == nil then flt.hitCap = false end
    if flt.dungeonMode ~= "normal" and flt.dungeonMode ~= "heroic" then flt.dungeonMode = nil end
    if sv.settings.tooltip == nil then sv.settings.tooltip = true end
    -- Order the window by how much each slot gains instead of by the paperdoll
    -- order. Off by default: the paperdoll order is the one you can find things
    -- in without reading.
    if sv.settings.sortByDelta == nil then sv.settings.sortByDelta = false end
    if sv.settings.sortByGold == nil then sv.settings.sortByGold = false end
    -- Filter rows folded away by default: the grid is the answer.
    if sv.settings.filtersOpen == nil then sv.settings.filtersOpen = false end
    if sv.settings.tooltipSrc == nil then sv.settings.tooltipSrc = true end
    -- Avisos de bolsas: apagados por defecto y solo con la ventana abierta.
    if sv.settings.bagAlerts == nil then sv.settings.bagAlerts = false end
    if sv.settings.rollAdvice == nil then sv.settings.rollAdvice = true end
    if sv.settings.questAdvice == nil then sv.settings.questAdvice = true end
    -- A spec chosen by hand, per talent group (dual specialization). Absent
    -- means "detect from talents". The pre-dual-spec `sv.activeSpec` is moved
    -- into the active group by ns:Refresh, the first moment the group is known.
    sv.specByGroup = sv.specByGroup or {}
    sv.targetLevel = sv.targetLevel         -- nil = current level

    -- Re-seed profiles saved by a build whose presets were wrong. Nothing is
    -- thrown away: the old tables move to sv.weightsBackup, and the message
    -- says so, because silently rewriting numbers somebody may have tuned by
    -- hand would be worse than the bug.
    if sv.weightsRevision ~= W.PRESET_REVISION then
        local had = next(sv.weights) ~= nil
        if had then
            sv.weightsBackup = sv.weights
            ns.weightsReseeded = true
        end
        sv.weights = {}
        sv.weightsRevision = W.PRESET_REVISION
    end
    return sv
end

-- Ensure a (class, spec) profile exists in SV; return it (editable, persisted).
local function EnsureProfile(class, spec)
    local sv = LevelBiSCharDB
    sv.weights[class] = sv.weights[class] or {}
    if not sv.weights[class][spec] then
        sv.weights[class][spec] = W.Default(class, spec)
    end
    W.RegisterContext(sv.weights[class][spec], class, spec)
    return sv.weights[class][spec]
end

------------------------------------------------------------------------------
-- Professions
--
-- The pipeline emits craft sources with the English profession name
-- ("Blacksmithing"), but the client only ever reports the LOCALIZED skill line
-- name, so a string compare would silently fail on a non-English client. The
-- bridge is the profession's own spell: GetSpellInfo returns its localized
-- name, which is exactly the skill line name, so the map is built at runtime
-- from the client's own strings.
--
-- 2.5.x has no GetProfessions(); skills come from GetSkillLineInfo, which hides
-- the children of a collapsed header. Headers themselves are always listed, so
-- the collapsed ones are recorded, everything is expanded for the scan, and
-- only those are collapsed again -- the player's skill window looks untouched.
------------------------------------------------------------------------------
local PROF_SPELL = {
    Alchemy = 2259, Blacksmithing = 2018, Enchanting = 7411, Engineering = 4036,
    Herbalism = 2366, Jewelcrafting = 25229, Leatherworking = 2108,
    Mining = 2575, Skinning = 8613, Tailoring = 3908,
    Cooking = 2550, ["First Aid"] = 3273, Fishing = 7620,
}

local profRank            -- [English profession name] = skill rank

local function scanProfessions()
    profRank = {}
    if type(GetNumSkillLines) ~= "function" then return end
    -- localized skill line name -> English key
    local localized = {}
    for eng, spellID in pairs(PROF_SPELL) do
        local name = GetSpellInfo(spellID)
        if name then localized[name] = eng end
    end

    local wasCollapsed = {}
    for i = 1, GetNumSkillLines() do
        local name, isHeader, isExpanded = GetSkillLineInfo(i)
        if isHeader and not isExpanded then wasCollapsed[name] = true end
    end
    if next(wasCollapsed) and ExpandSkillHeader then ExpandSkillHeader(0) end

    for i = 1, GetNumSkillLines() do
        local name, isHeader, _, rank = GetSkillLineInfo(i)
        local eng = (not isHeader) and name and localized[name]
        if eng then profRank[eng] = rank or 0 end
    end

    if next(wasCollapsed) and CollapseSkillHeader then
        for i = GetNumSkillLines(), 1, -1 do
            local name, isHeader = GetSkillLineInfo(i)
            if isHeader and wasCollapsed[name] then CollapseSkillHeader(i) end
        end
    end
end
ns.ScanProfessions = scanProfessions

-- Does the player have `prof`, at `minRank` or better? An unknown profession
-- (the pipeline omits it for trainer-taught recipes) counts as "yes": omitted
-- is unknown, and Scoring never turns unknown into a no.
function ns.HasProfession(prof, minRank)
    if not prof then return true end
    -- M-9: a profession being simulated is "had" at the simulated skill.
    if ns.simProfession and ns.simProfession.name == prof then
        return ns.simProfession.rank >= (minRank or 0)
    end
    if not profRank then scanProfessions() end
    local have = profRank[prof]
    if not have then return false end
    return have >= (minRank or 0)
end

-- Skill rank in a profession you really have, or nil.
function ns.ProfessionRank(prof)
    if not profRank then scanProfessions() end
    return profRank[prof]
end

-- Refresh cached player state + active weights.
function ns:Refresh()
    self.playerClass = select(2, UnitClass("player"))
    self.playerRace = select(2, UnitRace("player"))  -- token, e.g. "BloodElf"
    self.playerLevel = UnitLevel("player")
    if UnitAttackPower then
        local base, positive, negative = UnitAttackPower("player")
        self.weaponAttackPower = math.max(0, (base or 0) + (positive or 0) + (negative or 0))
    end
    self.playerSide = (UnitFactionGroup("player") == "Horde") and "H" or "A"
    local sv = LevelBiSCharDB
    local group = W.TalentGroup()
    sv.specByGroup = sv.specByGroup or {}
    if sv.activeSpec then
        sv.specByGroup[group] = sv.specByGroup[group] or sv.activeSpec
        sv.activeSpec = nil
    end
    local manual = sv.specByGroup[group]
    local spec = manual or W.DetectSpec(self.playerClass)
    -- validate spec belongs to class
    local valid = false
    for _, s in ipairs(W.SpecsFor(self.playerClass)) do if s == spec then valid = true break end end
    if not valid then spec = (W.SpecsFor(self.playerClass))[1]; manual = nil end
    self.activeSpec = spec
    self.specManual = manual ~= nil
    self.weights = EnsureProfile(self.playerClass, spec)
    S.UseProfile(self.weights)
end

-- Fix the spec by hand for the active talent group; nil returns to detection.
function ns.SetManualSpec(spec)
    local sv = LevelBiSCharDB
    sv.specByGroup = sv.specByGroup or {}
    sv.specByGroup[W.TalentGroup()] = spec
    ns:Refresh()
    if S.ClearLifetimeCache then S.ClearLifetimeCache() end
end

function ns:TargetLevel()
    return LevelBiSCharDB.targetLevel or self.playerLevel or UnitLevel("player")
end

-- M-3. What a level opens: the slots whose winner differs between the level
-- before and the level itself, under the filters in force. Same pair rules as
-- the window (S.BestForSlot). A slot that ends up with no winner is not an
-- opening. Returns { { slot=, id= }, ... } in window order.
function ns.LevelUnlocks(level)
    local out = {}
    if not (ns.db and ns.weights and level and level > 1) then return out end
    local filters = LevelBiSCharDB.settings.filters
    S.SetIgnoreRandom(filters.noRandom)
    for _, slot in ipairs(S.SLOT_ORDER) do
        local before = S.BestForSlot(slot, level - 1, ns.weights, ns.playerClass,
                                     level, filters)
        local after = S.BestForSlot(slot, level, ns.weights, ns.playerClass,
                                    level, filters)
        if after and (not before or before.id ~= after.id) then
            out[#out + 1] = { slot = slot, id = after.id }
        end
    end
    return out
end

local function UnlockMessage(level, list)
    local label = ns.SLOT_LABEL or {}
    local parts = {}
    for _, u in ipairs(list) do
        local item = ns.db[u.id]
        parts[#parts + 1] = ("%s (%s)"):format(label[u.slot] or u.slot,
            ns.LocalName(u.id, item))
    end
    local joined
    if #parts == 1 then joined = parts[1]
    else joined = table.concat(parts, ", ", 1, #parts - 1) .. " y " .. parts[#parts] end
    return ("A nivel %d se %s %d %s: %s."):format(level,
        #list == 1 and "abre" or "abren", #list,
        #list == 1 and "mejora" or "mejoras", joined)
end
ns.UnlockMessage = UnlockMessage

local MILESTONES = { 5,10,15,20,25,30,35,40,45,50,55,60,65,70 }
local function NextMilestone(cur)
    for _, m in ipairs(MILESTONES) do if m > cur then return m end end
    return 70
end
ns.NextMilestone = NextMilestone

-- Refresh the window if it exists and is shown (keeps chat + UI in sync).
local function RefreshUI()
    if ns.UI and LevelBiSFrame and LevelBiSFrame:IsShown() then
        ns.UI:Refresh()
    elseif ns.Profiles and ns.Profiles.Refresh then
        -- The weights panel carries switches of its own; keep them in step with
        -- a /lbis command even while the main window is closed.
        ns.Profiles:Refresh()
    end
end

------------------------------------------------------------------------------
-- Display helpers
------------------------------------------------------------------------------
local function QColor(q)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q or 1]
    return c and c.hex or "|cffffffff"
end

-- Clickable item link if GetItemInfo has it cached; otherwise colored [name].
--
-- An item that rolls a random suffix is named with the roll it was scored as,
-- because the base item and the roll are not the same purchase: "Warmaul
-- Epaulets" on its own is a name for twenty-five different shoulders, and the
-- one worth having is the one this says.
local function ItemLink(id, item)
    local suffix, variantId
    if item and (item.sg or item.pg) and S.BestVariant then
        local _, name, _, vid = S.BestVariant(item, ns.weights)
        suffix, variantId = name, vid
    end
    -- Ask the client for the rolled link first: it comes back localised, and
    -- clicking it opens the right item rather than the base one.
    if id and variantId then
        local rolled = select(2, GetItemInfo(
            ("item:%d:0:0:0:0:0:%d:0:0:0"):format(id, variantId)))
        if rolled then return rolled end
    end
    local link = id and select(2, GetItemInfo(id))
    local name = link or (item and item.n and (QColor(item.q) .. "[" .. item.n .. "]|r"))
                 or ("item:" .. tostring(id))
    if suffix then return name .. " |cffffd100" .. suffix .. "|r" end
    return name
end
ns.ItemLink = ItemLink

------------------------------------------------------------------------------
-- Names
------------------------------------------------------------------------------
-- The database ships English names, because that is what the world database
-- holds. The client has them in the game's own language, so ask it first and
-- keep the English one as the fallback: on a Spanish client the window read
-- "Crimson Beholder Eye" while the item's own tooltip said something else
-- entirely.
--
-- GetItemInfo is asynchronous the first time an item is asked for and returns
-- nil until the client has it, which is why the window listens for
-- GET_ITEM_INFO_RECEIVED. The English name shows for a moment and is replaced,
-- rather than being wrong for the session.
--
-- A roll is part of the name, and the client can spell that too, but only when
-- it is handed a link carrying the suffix -- field 7, negative for a suffix and
-- positive for a random property. Returns the name, and whether that name
-- already includes the roll.
-- The link the addon means when it recommends an item: the base item plus the
-- roll it was scored as. Handing this to SetHyperlink is what makes the client
-- draw the rolled stats and, when you hold shift, compare against them --
-- with the plain "item:<id>" it drew the base, whose stat block is empty, and
-- the comparison read as if every roll were a downgrade.
function ns.VariantLink(id, item)
    if not id then return nil end
    local variantId
    if item and (item.sg or item.pg) and ns.Scoring and ns.Scoring.BestVariant then
        variantId = select(4, ns.Scoring.BestVariant(item, ns.weights))
    end
    if not variantId then return "item:" .. id, nil end
    return ("item:%d:0:0:0:0:0:%d:0:0:0"):format(id, variantId), variantId
end

-- The purchase a recommendation stands for: itemID and the roll VariantLink
-- spells. nil roll = a rolling item with no concrete roll (noRandom, or nothing
-- worth scoring): then there is no price to look up, and the price of another
-- roll is never a substitute.
function ns.VariantIdentity(id, item)
    local link = ns.VariantLink(id, item)
    if not link then return nil end
    return S.LinkIdentity(link)
end

local localNames = {}
function ns.LocalName(id, item, variantId)
    local cached = id and localNames[id]
    if cached and cached.variantId == variantId then
        return cached.name, cached.rolled
    end
    if id and variantId then
        local link = ("item:%d:0:0:0:0:0:%d:0:0:0"):format(id, variantId)
        local info = { GetItemInfo(link) }
        S.ObserveBinding(id, info[14])
        if info[1] then
            localNames[id] = { name=info[1], variantId=variantId, rolled=true }
            return info[1], true
        end
    end
    local info = id and { GetItemInfo(id) } or {}
    local plain = info[1]
    if id then S.ObserveBinding(id, info[14]) end
    if plain and not variantId then
        localNames[id] = { name=plain, rolled=false }
    end
    -- Una entrada por objeto, reemplazada al cambiar de tirada. Nunca guardar
    -- el nombre inglés provisional como si fuera una respuesta del cliente.
    if not plain and cached and cached.variantId == variantId then
        return cached.name, cached.rolled
    end
    return plain or (item and item.n) or ("item:" .. tostring(id or 0)), false
end

------------------------------------------------------------------------------
-- Set bonuses
------------------------------------------------------------------------------
-- How many pieces of each set you have on, and which set (if any) sits in each
-- equipment slot. Recomputed whenever your gear changes: a set bonus is only
-- worth something relative to what you are already wearing, so every cached
-- score depends on this.
function ns.RefreshSetCounts()
    local counts, bySlot = {}, {}
    if ns.db then
        for _, def in pairs(S.SLOTS) do
            local id = S.EquippedItemID and S.EquippedItemID(def.slot)
            local item = id and ns.db[id]
            local setId = item and item.set
            if setId then
                counts[setId] = (counts[setId] or 0) + 1
                bySlot[def.slot] = setId
            end
        end
    end
    ns.setCounts, ns.setBySlot = counts, bySlot
    ns.RefreshHitRating()
    if S.ForgetScores then S.ForgetScores() end
end

-- Hit rating you carry now, for the optional hit cap (M-16). GetCombatRating
-- and the CR_* constants are not confirmed for this client, so both are
-- checked; without them the cap stays inactive and nothing else changes.
-- Hunters hit with ranged hit rating, everyone else with melee.
function ns.RefreshHitRating()
    ns.hitRating = nil
    if type(GetCombatRating) ~= "function" then return end
    local melee = ns.playerClass == "HUNTER" and (CR_HIT_RANGED or 7) or (CR_HIT_MELEE or 6)
    local ok, hit, spell = pcall(function()
        return GetCombatRating(melee), GetCombatRating(CR_HIT_SPELL or 8)
    end)
    if ok and type(hit) == "number" and type(spell) == "number" then
        ns.hitRating = { hit = hit, spellhit = spell }
    end
end

-- The lines a set piece adds to a tooltip: which set, how much of it you have,
-- and what the next threshold gives. A bonus that is not stats is named rather
-- than valued, the same way an on-use trinket is.
function ns.SetLines(item)
    local setId = item and item.set
    local entry = setId and ns.set and ns.set[setId]
    if not entry then return nil end
    local have = (ns.setCounts or {})[setId] or 0
    local total = 0
    for _ in pairs(entry.bonus or {}) do total = total + 1 end
    local lines = {
        ("|cffffd100%s|r |cff808080(llevas %d)|r"):format(entry.n or "?", have),
    }
    local thresholds = {}
    for need in pairs(entry.bonus or {}) do thresholds[#thresholds + 1] = need end
    for _, pair in ipairs(entry.named or {}) do thresholds[#thresholds + 1] = pair[1] end
    table.sort(thresholds)
    local seen = {}
    for _, need in ipairs(thresholds) do
        if not seen[need] then
            seen[need] = true
            local st = entry.bonus and entry.bonus[need]
            local text
            if st then
                local parts = {}
                for _, e in ipairs(S.VariantStatList(st) or {}) do
                    parts[#parts + 1] = ("+%d %s"):format(e[2], ns.StatLabel(e[1]))
                end
                text = table.concat(parts, ", ")
            end
            if not text then
                for _, pair in ipairs(entry.named or {}) do
                    if pair[1] == need then text = pair[2] end
                end
            end
            if text then
                local color = (have >= need) and "|cff40ff40" or "|cff808080"
                lines[#lines + 1] = ("%scon %d: %s|r"):format(color, need, text)
            end
        end
    end
    if #lines < 2 then return nil end
    return lines
end

-- The two lines a random-suffix item needs in a tooltip: the roll it is being
-- scored as, and what that roll gives. The client cannot draw them itself --
-- it is handed the base item, whose stat block is empty -- so hovering a
-- recommendation showed a name, an armour value and nothing else.
function ns.RollLines(item)
    if not (item and (item.sg or item.pg) and S.BestVariant) then return nil end
    local _, suffix, st = S.BestVariant(item, ns.weights)
    if not suffix then return nil end
    local parts = {}
    local list = S.VariantStatList(st)
    for i = 1, (list and #list or 0) do
        parts[i] = ("+%d %s"):format(list[i][2], ns.StatLabel(list[i][1]))
    end
    if #parts == 0 then return nil end
    return {
        ("|cffffd100%s|r"):format(suffix),
        ("|cff40ff40%s|r"):format(table.concat(parts, ", ")),
        "|cff808080Es la mejor tirada de este objeto. Otras tiradas dan otras "
        .. "estadísticas.|r",
    }
end

-- One-line source summary from item.src (full detail goes in tooltips, phase c).
------------------------------------------------------------------------------
-- Error capture
--
-- WoW swallows Lua errors unless scriptErrors is on, and an error inside an
-- OnUpdate fires every frame, which reads as lag rather than as a bug. This
-- chains the global handler so errors are recorded even with the display off:
-- `/lbis errors` prints them. Identical messages are counted, not repeated, so
-- a per-frame error shows up as one line with a large count.
------------------------------------------------------------------------------
local errorLog, errorOrder = {}, {}

local function recordError(msg)
    msg = tostring(msg)
    local e = errorLog[msg]
    if e then
        e.count = e.count + 1
    else
        errorLog[msg] = { count = 1, stack = debugstack(3, 6, 0) }
        errorOrder[#errorOrder + 1] = msg
        -- Keep only the most recent handful; a runaway error must not grow
        -- without bound.
        if #errorOrder > 10 then
            errorLog[table.remove(errorOrder, 1)] = nil
        end
    end
end

do
    local prev = geterrorhandler and geterrorhandler()
    if seterrorhandler then
        seterrorhandler(function(msg)
            pcall(recordError, msg)
            if prev then return prev(msg) end
        end)
    end
end

local SRC_LABEL = { drop="Cae de", quest="Misión", vendor="Vendedor",
                    craft="Se fabrica", world="Casa de subastas o drop de mundo" }
-- Same vocabulary as the window, so an item reads the same way in both places.
local SRC_CONTENT = { raid="Raid", dungeon="Mazmorra", pvp="PvP" }
function ns.SrcSummary(item)
    local src
    local filters = LevelBiSCharDB and LevelBiSCharDB.settings
                    and LevelBiSCharDB.settings.filters
    for _, candidate in ipairs((item and item.src) or {}) do
        if S.SourceAllowed and S.SourceAllowed(candidate, filters) then
            src = candidate
            break
        end
    end
    src = src or (item and item.src and item.src[1])
    if not src then return "" end
    local label = SRC_LABEL[src.t] or src.t
    local where = src.inst or src.zone or src.name or src.prof
                  or SRC_CONTENT[src.ct]
    if src.ct == "dungeon" then
        local difficulty = ({ [1]="normal", [2]="heroica", [3]="normal y heroica" })[src.diff]
        where = (where or "Mazmorra") .. " (" .. (difficulty or "dificultad sin verificar") .. ")"
    end
    local extra = ""
    if src.t == "drop" and src.pct then
        extra = string.format(" ~%.1f%% (aprox.)", src.pct)
    end
    return label .. (where and (": " .. tostring(where)) or "") .. extra
end

------------------------------------------------------------------------------
-- Command implementations
------------------------------------------------------------------------------
local Cmd = {}

function Cmd.help()
    Print("comandos:")
    Print("  /lbis                      abre o cierra la ventana")
    Print("  /lbis <ranura>             las 5 mejores de esa ranura")
    Print("  /lbis summary              las 17 ranuras, en texto")
    Print("  /lbis spec [nombre|auto]   ver, fijar o volver a detectar tu especialización")
    Print("  /lbis level [n|next]       nivel objetivo (vacío = el tuyo)")
    Print("  /lbis weights              ver tus pesos")
    Print("  /lbis edit                 abrir el editor de pesos")
    Print("  /lbis set <stat> <n|off>   cambiar o quitar un peso")
    Print("  /lbis reset                volver al preset de tu spec")
    Print("  /lbis filter [n] [on|off]  ver o cambiar un filtro")
    Print("  /lbis sort [delta|oro|slot] ordenar por mejora, por mejora por oro o por ranura")
    Print("  /lbis profs [sim]          tus profesiones; sim = qué profesión te daría más equipo")
    Print("  /lbis consumibles          elixires, comida y pociones según tus pesos")
    Print("  /lbis tooltip [src]        marcas en tooltips (src = solo la procedencia)")
    Print("  /lbis scan                 qué diría de lo que llevas en las bolsas")
    Print("  /lbis quest                qué recompensa elegir en la misión seleccionada")
    Print("  /lbis bags [on|off]        avisos de mejoras en bolsas (ventana abierta)")
    Print("  /lbis equip                equipa la última mejora avisada")
    Print("  /lbis access [refresh]     reputación y misiones únicas que ve «Alcanzable»")
    Print("  /lbis perf                 mide cuánto tarda cada cálculo en este cliente")
    Print("  /lbis phase [1-5|all|auto] contenido que cuenta según la fase del servidor")
    Print("  /lbis goal [70|leveling]   atajo: raids, heroicas y fase abierta a nivel 70")
    Print("  /lbis rolls [on|off]       consejo al tirar por un botín de grupo")
    Print("  /lbis import <texto>       importar una escala de Pawn")
    Print("  /lbis export               exportar tus pesos como escala de Pawn")
    Print("  /lbis explain <itemID>     explicar el puntaje de un item")
    Print("  /lbis test                 comprobar que todo carga")
    Print("  /lbis errors               errores capturados ('clear' los borra)")
    Print("  ranuras: " .. table.concat(S.SLOT_ORDER, ", "))
end

function Cmd.spec(arg)
    if arg and arg ~= "" then
        local want = arg:gsub("^%s+",""):gsub("%s+$","")
        if want:lower() == "auto" then
            ns.SetManualSpec(nil)
            RefreshUI()
            Print("especialización según tus talentos: |cffffd100" .. ns.activeSpec .. "|r")
            return
        end
        local match
        for _, s in ipairs(W.SpecsFor(ns.playerClass)) do
            if s:lower() == want:lower() then match = s break end
        end
        if not match then
            Print("no conozco esa especialización. tienes: " .. table.concat(W.SpecsFor(ns.playerClass), ", ")
                .. ", o |cffffd100auto|r para seguir tus talentos")
            return
        end
        ns.SetManualSpec(match)
        RefreshUI()
        Print("especialización activa: |cffffd100" .. match .. "|r. Vuelve a tus talentos con |cffffd100/lbis spec auto|r.")
    else
        Print(("|cffffd100%s %s|r, especialización |cffffd100%s|r (%s), nivel objetivo %d")
            :format(ns.playerRace or "?", ns.playerClass, ns.activeSpec,
                    ns.specManual and "elegida a mano" or "según tus talentos",
                    ns:TargetLevel()))
    end
end

function Cmd.level(arg)
    if arg == "next" then
        LevelBiSCharDB.targetLevel = NextMilestone(ns.playerLevel)
    elseif arg and arg:match("^%d+$") then
        LevelBiSCharDB.targetLevel = math.min(70, math.max(1, tonumber(arg)))
    elseif arg == "" or arg == nil then
        LevelBiSCharDB.targetLevel = nil
    end
    RefreshUI()
    Print("nivel objetivo: |cffffd100" .. ns:TargetLevel() .. "|r"
        .. (LevelBiSCharDB.targetLevel and "" or " (el tuyo)"))
end

-- M-7. The server phase the window counts content up to.
function ns.SetPhase(value)
    local flt = LevelBiSCharDB.settings.filters
    if value == "auto" then flt.maxPhase = S.CURRENT_PHASE return true end
    if value == "all" or value == "todas" then flt.maxPhase = 5 return true end
    local n = tonumber(value)
    if not n or n < 1 or n > 5 or n ~= math.floor(n) then return false end
    flt.maxPhase = n
    return true
end

function ns.PhaseLabel(n)
    n = n or S.CURRENT_PHASE
    return ("Fase %d: %s"):format(n, S.PHASE_NAMES[n] or "?")
end

function Cmd.phase(rest)
    rest = (rest or ""):lower()
    if rest ~= "" and not ns.SetPhase(rest) then
        Print("usa |cffffd100/lbis phase 1-5|r, |cffffd100all|r o |cffffd100auto|r")
        return
    end
    RefreshUI()
    local flt = LevelBiSCharDB.settings.filters
    Print(("contenido hasta la |cffffd100%s|r. La fase actual del servidor es la %d%s.")
        :format(ns.PhaseLabel(flt.maxPhase), S.CURRENT_PHASE,
                flt.maxPhase == S.CURRENT_PHASE and "" or " (cámbiala con auto)"))
end

-- M-10. One switch for the endgame question: every filter that keeps raids,
-- heroics and the open phase in view, at level 70. Not a BiS list: the same
-- ranking with the leveling filters lifted. The filters and the level you had
-- are kept, and "leveling" brings them back.
function ns.SetGoal(goal)
    local sv = LevelBiSCharDB.settings
    if goal == "endgame" then
        if not sv.goalBackup then
            local copy = {}
            for k, v in pairs(sv.filters) do copy[k] = v end
            sv.goalBackup = { filters = copy, targetLevel = LevelBiSCharDB.targetLevel or false }
        end
        local flt = sv.filters
        flt.noRaid, flt.noDungeon, flt.dungeonMode = false, false, nil
        flt.onlyInstances, flt.onlyQuests = false, false
        flt.onlyReachable, flt.ilvlCap = true, false
        flt.maxPhase = S.CURRENT_PHASE
        LevelBiSCharDB.targetLevel = 70
        sv.goal = "endgame"
    else
        local backup = sv.goalBackup
        if backup then
            sv.filters = backup.filters
            LevelBiSCharDB.targetLevel = backup.targetLevel or nil
        end
        sv.goalBackup, sv.goal = nil, nil
    end
    if S.ClearLifetimeCache then S.ClearLifetimeCache() end
    return sv.goal or "leveling"
end

function Cmd.goal(rest)
    rest = (rest or ""):lower()
    local want
    if rest == "70" or rest == "endgame" then want = "endgame"
    elseif rest == "leveling" or rest == "nivel" then want = "leveling"
    else want = (LevelBiSCharDB.settings.goal == "endgame") and "leveling" or "endgame" end
    local now = ns.SetGoal(want)
    RefreshUI()
    Print(("objetivo: |cffffd100%s|r"):format(now == "endgame"
        and "nivel 70 (raids, heroicas y la fase abierta)" or "leveling"))
end

function Cmd.edit()
    if ns.Profiles then ns.Profiles:Show()
    else Print("|cffff4040el editor de pesos no está cargado|r") end
end

function Cmd.weights(rest)
    if rest == "edit" or rest == "ui" then return Cmd.edit() end
    Print("pesos de |cffffd100" .. ns.playerClass .. " / " .. ns.activeSpec .. "|r:")
    local keys = {}
    for k in pairs(ns.weights) do keys[#keys+1] = k end
    table.sort(keys)
    local line = {}
    for _, k in ipairs(keys) do line[#line+1] = k .. "=" .. tostring(ns.weights[k]) end
    Print("  " .. table.concat(line, "  "))
end

function Cmd.import(arg)
    local res, err = W.ImportPawn(arg or "")
    if not res then Print("|cffff4040no pude importar:|r " .. tostring(err)) return end
    local prof = ns.weights
    for k in pairs(prof) do prof[k] = nil end
    for k, v in pairs(res.weights) do prof[k] = v end
    S.InvalidateProfile(prof); S.UseProfile(prof)
    RefreshUI()
    Print(("importados %d pesos en |cffffd100%s / %s|r"):format(
        (function() local c=0 for _ in pairs(res.weights) do c=c+1 end return c end)(),
        ns.playerClass, ns.activeSpec))
    if res.ignored and #res.ignored > 0 then
        Print("|cffffd100omitidos porque LevelBiS no los puntúa:|r "
              .. table.concat(res.ignored, ", "))
    end
end

function Cmd.export()
    Print("escala de Pawn, cópiala del chat:")
    Print(W.ExportPawn(ns.playerClass, ns.activeSpec, ns.weights))
end

-- valid canonical stat keys (for /lbis set)
local VALID_STAT = {}
for _, k in ipairs(ns.STAT_KEYS) do VALID_STAT[k] = true end

-- `/lbis set <stat> <n>` writes the number you type, zero included. To take a
-- stat out of the profile entirely, write `off`: absent and zero are not the
-- same thing to `rdps`, where absent means "fall back to the melee weight".
function Cmd.set(rest)
    local stat, val = rest:match("^(%S+)%s+(-?%d*%.?%d+)$")
    if not stat then
        stat = rest:match("^(%S+)%s+off$")
        if stat then val = nil else
            Print("se usa: /lbis set <stat> <valor>   (|cffffd100off|r la quita)")
            Print("stats: " .. table.concat(ns.STAT_KEYS, " "))
            return
        end
    end
    stat = stat:lower()
    if not VALID_STAT[stat] then Print("|cffff4040no conozco la stat '" .. stat .. "'|r") return end
    val = val and tonumber(val) or nil
    ns.weights[stat] = val
    S.InvalidateProfile(ns.weights); S.UseProfile(ns.weights)
    RefreshUI()
    Print(("%s = |cffffd100%s|r en %s / %s"):format(
        stat, val and tostring(val) or "quitada", ns.playerClass, ns.activeSpec))
end

function Cmd.reset()
    local def = W.Default(ns.playerClass, ns.activeSpec)
    for k in pairs(ns.weights) do ns.weights[k] = nil end
    for k, v in pairs(def) do ns.weights[k] = v end
    S.InvalidateProfile(ns.weights); S.UseProfile(ns.weights)
    RefreshUI()
    Print("pesos de vuelta al preset de |cffffd100" .. ns.playerClass .. " / " .. ns.activeSpec .. "|r")
end

function Cmd.tooltip(rest)
    local sv = LevelBiSCharDB.settings
    if rest == "src" or rest == "fuente" then
        sv.tooltipSrc = not sv.tooltipSrc
        Print("procedencia en tooltips: "
            .. (sv.tooltipSrc and "|cff40ff40on|r" or "|cffff6060off|r"))
        return
    end
    sv.tooltip = not sv.tooltip
    RefreshUI()
    Print("marcas en tooltips: " .. (sv.tooltip and "|cff40ff40on|r" or "|cffff6060off|r"))
end

-- Bag API. The TBC Anniversary client runs on the modern engine, where the
-- container functions live only in C_Container (documented by PickItRight as an
-- in-game "attempt to call a nil value"; Gargul, BigWigs, DBM and Details use
-- the same fallback). The global names stay as the fallback for older clients.
-- Resolved at call time, not load time: the stub swaps them per test.
local function ContainerAPI()
    local C = C_Container
    return (C and C.GetContainerNumSlots) or GetContainerNumSlots,
           (C and C.GetContainerItemLink) or GetContainerItemLink
end
ns.ContainerAPI = ContainerAPI

-- Scan bags and print the LevelBiS line each item would get (diagnostic).
function Cmd.scan()
    if not ns.MarkFor then Print("|cffff4040el módulo de tooltips no está cargado|r") return end
    local numSlots, itemLink = ContainerAPI()
    if not numSlots or not itemLink then
        Print("|cffff4040este cliente no expone la API de bolsas|r")
        return
    end
    local shown, scanned = 0, 0
    for bag = 0, 4 do
        local slots = numSlots(bag) or 0
        for slot = 1, slots do
            local link = itemLink(bag, slot)
            if link then
                scanned = scanned + 1
                local text = ns.MarkFor(link)
                if text then
                    shown = shown + 1
                    Print("  " .. link .. "  " .. text)
                    if shown >= 15 then Print("  |cff808080(y más, que no muestro)|r") return end
                end
            end
        end
    end
    Print(("miré %d items de tus bolsas; %d le sirven a tu spec"):format(scanned, shown))
    if shown == 0 then
        Print("  |cff808080(un item cuyas stats tu spec no pesa no sale acá)|r")
    end
end

local function printRankLine(i, entry, equipScore)
    local value = entry.fallbackScore or entry.score
    local abs, pct = S.Delta(value, equipScore)
    local delta = pct and string.format(" |cff808080(%+.0f / %+.1f%%)|r", abs, pct)
                        or string.format(" |cff808080(%+.0f)|r", abs)
    local score = entry.fallback and string.format("%.1f DPS", value)
                  or string.format("%.0f", value)
    if equipScore == nil then delta = " |cff808080(sin comparación)|r" end
    Print(("  %d. %s  |cff00ff00%s|r%s  %s"):format(
        i, ItemLink(entry.id, entry.item), score, delta, ns.SrcSummary(entry.item)))
end

function Cmd.slot(arg)
    local name = S.ResolveSlot(arg)
    if not name then Print("no conozco la ranura '" .. tostring(arg) .. "'. mira /lbis help") return end
    local tl, filters = ns:TargetLevel(), LevelBiSCharDB.settings.filters
    local def = S.SLOTS[name]
    local list = S.RankSlot(name, tl, ns.weights, ns.playerClass, ns.playerLevel, filters, 5)
    local fallback = list[1] and list[1].fallback
    local eqScore, _, _, _, state = S.EquippedScore(def.slot, ns.weights)
    if state == "empty" then eqScore = 0 end
    if fallback and state ~= "pending" then eqScore = S.EquippedWandDps(def.slot) end
    if state == "unpriceable" and not fallback then eqScore = nil end
    local equipped = eqScore and (fallback and string.format("%.1f DPS", eqScore)
                     or string.format("%.0f", eqScore))
                     or (state == "pending" and "equipo cargando" or "equipo sin tasar")
    Print(("las %d mejores de |cffffd100%s|r a nivel %d (llevas %s):")
        :format(#list, name, tl, equipped))
    if #list == 0 then Print("  (nada elegible con estos filtros)") end
    for i, e in ipairs(list) do printRankLine(i, e, eqScore) end
    -- Two thirds of the trinkets in the game are worth an on-use or on-proc
    -- effect and nothing else, and a weighted sum cannot price an effect. They
    -- are left out rather than ranked at zero; saying how many were left out
    -- is the difference between a short list and a wrong one.
    local mute = S.UnscorableCount(name, tl, ns.weights, ns.playerClass,
                                   ns.playerLevel, filters)
    if mute > 0 then
        Print(("  |cff808080y %d que no puedo puntuar: su valor es un efecto de "
               .. "uso o un proc, no estadísticas.|r"):format(mute))
    end
    if name == "mainhand" then
        local w = S.BestWeaponSetup(tl, ns.weights, ns.playerClass, ns.playerLevel, filters)
        if w and w.two then
            local oneStr = w.one.mh and string.format("1 mano %.0f + secundaria %.0f = %.0f",
                w.one.mh.score, w.one.oh and w.one.oh.score or 0, w.one.score) or "nada"
            Print(("  a dos manos %.0f contra %s  -> gana |cffffd100%s|r")
                :format(w.two.score, oneStr, w.better == "2h" and "el arma a dos manos" or "una mano + secundaria"))
            -- When the spec is committed, the numbers above are not what
            -- decided it, and presenting them as if they were would be a lie
            -- the first time they disagreed.
            local REASON = {
                ["2h"] = "tu especialización necesita un arma a dos manos",
                shield = "tu especialización necesita un escudo",
                dual   = "tu especialización pelea con dos armas",
            }
            if w.required then
                Print(("  |cff808080no lo decide el puntaje: %s.|r"):format(
                    REASON[w.required] or w.required))
            end
        end
    end
end

function Cmd.explain(arg)
    local id = tonumber((arg or ""):match("item:(%d+)")) or tonumber(arg)
    local item = id and ns.db and ns.db[id]
    if not item then
        Print("|cffff4040item ausente de la base:|r " .. tostring(arg or ""))
        return
    end
    local slotName = item.slot and S.INVTYPE_SLOT[item.slot]
    local def = slotName and S.SLOTS[slotName]
    if not def then
        Print("|cffff4040ese item carece de ranura puntuable|r")
        return
    end
    S.SetIgnoreRandom(LevelBiSCharDB.settings.filters.noRandom)
    S.UseProfile(ns.weights)
    item.id = id
    local detail = S.Explain(item, ns.weights, def.slot, slotName == "offhand")
    Print(("%s: |cff40ff40%.2f puntos|r"):format(ItemLink(id, item), detail.total))
    for _, part in ipairs(detail.parts) do
        local origin = part.origin == "suffix" and "sufijo" or "base"
        local label = ns.StatLabel and ns.StatLabel(part.key) or part.key
        Print(("  %s (%s): %g × %g = |cffffd100%.2f|r"):format(
            label, origin, part.value, part.weight, part.points))
    end
    if detail.suffix then Print("  tirada elegida: |cffffd100" .. detail.suffix .. "|r") end
    if detail.weaponAbility then
        Print(("  ajuste estimado por %s: %+.2f puntos"):format(
            detail.weaponAbility, detail.weaponPoints))
    end
    if detail.setPoints ~= 0 then
        Print(("  bono de conjunto al equiparlo: |cffffd100%.2f|r"):format(
            detail.setPoints))
    end
    if detail.total == 0 and item.sc == 19 and item.st and item.st.dps then
        Print(("  Pawn da 0; esta ranura ordena varitas por %.1f DPS."):format(
            item.st.dps))
    elseif #detail.parts == 0 and detail.setPoints == 0 then
        Print("  |cff808080ninguna estadística tiene peso en este perfil|r")
    end
end

function Cmd.summary()
    local tl = ns:TargetLevel()
    Print(("las 17 ranuras de |cffffd100%s / %s|r a nivel %d:"):format(
        ns.playerClass, ns.activeSpec, tl))
    -- RankAll, not RankSlot per row: it is what keeps a unique ring out of both
    -- finger slots.
    local ranked = S.RankAll(tl, ns.weights, ns.playerClass, ns.playerLevel,
                             LevelBiSCharDB.settings.filters, 1)
    -- Same order as the window. Two views of one answer that disagree about
    -- what matters most are two answers.
    local rows = {}
    for i, name in ipairs(S.SLOT_ORDER) do
        local def = S.SLOTS[name]
        local eq, _, _, _, state = S.EquippedScore(def.slot, ns.weights)
        if state == "empty" then eq = 0 end
        if state == "unpriceable" then eq = nil end
        local best = ranked[name] and ranked[name][1]
        local abs = best and eq and not best.fallback and S.Delta(best.score, eq) or 0
        if abs < 0 then abs = 0 end
        rows[i] = { name = name, eq = eq, best = best, abs = abs, home = i }
    end
    if LevelBiSCharDB.settings.sortByDelta then
        table.sort(rows, function(a, b)
            if a.abs ~= b.abs then return a.abs > b.abs end
            return a.home < b.home
        end)
    end
    for _, r in ipairs(rows) do
        if r.best then
            if r.best.fallback then
                local eqDps = S.EquippedWandDps(S.SLOTS[r.name].slot)
                Print(("  %-9s %s  |cff00ff00%.1f DPS|r contra %.1f DPS"):format(
                    r.name, ItemLink(r.best.id, r.best.item),
                    r.best.fallbackScore, eqDps))
            elseif r.eq == nil then
                Print(("  %-9s %s  |cff808080equipo sin comparación|r"):format(
                    r.name, ItemLink(r.best.id, r.best.item)))
            else
                local tag = r.abs > 0.5 and " |cff40ff40sube|r" or ""
                Print(("  %-9s %s  |cff00ff00%.0f|r contra %.0f%s"):format(
                    r.name, ItemLink(r.best.id, r.best.item), r.best.score, r.eq, tag))
            end
        else
            Print(("  %-9s |cff808080nada|r"):format(r.name))
        end
    end
end

-- Every filter is reachable here; the window surfaces the common ones as
-- checkboxes and cycling buttons but has no room for all of them. Mi armadura
-- (strictArmor), Sin PvP (noPvP) and Mi facción (myFactionOnly) have no control
-- in the window any more: this is where they are read and changed.
local FILTER_HELP = {
    { "strictArmor",   "recomendar solo mi tipo de armadura" },
    { "noRaid",        "descartar lo que solo cae en raid" },
    { "noDungeon",     "descartar lo que solo cae en mazmorra" },
    { "noPvP",         "descartar PvP y rangos de honor" },
    { "noRep",         "descartar lo que pide reputación" },
    { "myProfsOnly",   "solo lo que mis profesiones alcanzan" },
    { "myFactionOnly", "descartar misiones de la otra facción" },
    { "excludeBoE",    "descartar BoE (comprables en la subasta)" },
    { "onlyReachable", "solo lo que puedes conseguir: nivel mínimo, reputación suficiente, misiones únicas sin hacer y fuentes de temporada solo con su evento activo" },
    { "onlyInstances", "solo drops y vendedores de mazmorras o raids" },
    { "onlyQuests",    "solo recompensas de misión" },
    { "onlyAH",        "solo lo comprable (nada ligado al recoger)" },
    { "noRandom",      "puntuar solo lo garantizado, sin la tirada del sufijo" },
    { "fixedOnly",     "descartar todo lo que dependa de una tirada" },
    { "levelScale",    "escalar los índices de combate según el nivel" },
    { "ilvlCap",       "heurística: limitar el ilvl según el nivel" },
    { "hitCap",        "a nivel 70, no valorar el golpe por encima del tope" },
}

-- excludeBoE and onlyAH are opposites, and turning both on leaves the window
-- empty -- which reads as a bug, not as an answer. Whichever one you just
-- switched on wins; the other goes off, wherever the change came from. Same for
-- noRandom and fixedOnly. The window shows each pair as one cycling button.
local EXCLUSIVE = { excludeBoE = "onlyAH", onlyAH = "excludeBoE",
                    noRandom = "fixedOnly", fixedOnly = "noRandom" }
function ns.SetDungeonMode(mode)
    if mode ~= "normal" and mode ~= "heroic" and mode ~= "all" then return false end
    LevelBiSCharDB.settings.filters.dungeonMode = mode ~= "all" and mode or nil
    return true
end
function ns.SetFilter(key, value)
    local flt = LevelBiSCharDB.settings.filters
    if key == "onlyInstance" then
        flt.onlyInstances = value and true or false
        flt.onlyQuests = value and true or false
        return
    end
    flt[key] = value and true or false
    if flt[key] and EXCLUSIVE[key] then flt[EXCLUSIVE[key]] = false end
end

-- The window shows each exclusive pair (and the two sort flags) as one cycling
-- button. The flags stay what they were; these functions are the only place
-- that maps them to a state and back, and every write goes through
-- ns.SetFilter so the exclusions are not written a second time. A saved state
-- that contradicts itself reads as the rule InitSV applies: fixedOnly over
-- noRandom, onlyAH over excludeBoE, and gold over gain (what Refresh draws).
ns.ROLL_MODES = { "best", "ignore", "exclude" }
ns.AUCTION_MODES = { "include", "exclude", "only" }
ns.SORT_MODES = { "slot", "delta", "gold" }

function ns.RollMode(flt)
    flt = flt or LevelBiSCharDB.settings.filters
    if flt.fixedOnly then return "exclude" end
    if flt.noRandom then return "ignore" end
    return "best"
end

function ns.SetRollMode(mode)
    if mode == "best" then
        ns.SetFilter("noRandom", false); ns.SetFilter("fixedOnly", false)
    elseif mode == "ignore" then ns.SetFilter("noRandom", true)
    elseif mode == "exclude" then ns.SetFilter("fixedOnly", true)
    else return false end
    return true
end

function ns.AuctionMode(flt)
    flt = flt or LevelBiSCharDB.settings.filters
    if flt.onlyAH then return "only" end
    if flt.excludeBoE then return "exclude" end
    return "include"
end

function ns.SetAuctionMode(mode)
    if mode == "include" then
        ns.SetFilter("excludeBoE", false); ns.SetFilter("onlyAH", false)
    elseif mode == "exclude" then ns.SetFilter("excludeBoE", true)
    elseif mode == "only" then ns.SetFilter("onlyAH", true)
    else return false end
    return true
end

function ns.SortMode(sv)
    sv = sv or LevelBiSCharDB.settings
    if sv.sortByGold then return "gold" end
    if sv.sortByDelta then return "delta" end
    return "slot"
end

function ns.SetSortMode(mode)
    local sv = LevelBiSCharDB.settings
    if mode == "slot" then sv.sortByDelta, sv.sortByGold = false, false
    elseif mode == "delta" then sv.sortByDelta, sv.sortByGold = true, false
    elseif mode == "gold" then sv.sortByDelta, sv.sortByGold = false, true
    else return false end
    return true
end

-- The state after `current` in `list`; an unknown one starts over.
function ns.NextMode(list, current)
    for i, m in ipairs(list) do
        if m == current then return list[i % #list + 1] end
    end
    return list[1]
end

function ns.ResetFilters()
    LevelBiSCharDB.settings.filters = {
        minQuality = 2, strictArmor = true, noRaid = true, noPvP = true,
        myProfsOnly = true, myFactionOnly = true, onlyReachable = true,
        levelScale = true, ilvlCap = false, hitCap = false,
        maxPhase = S.CURRENT_PHASE,
    }
    S.SetIgnoreRandom(false)
end

-- Provenance is ONE label, never "Todas las procedencias" next to a narrowing
-- clause. With the auction house on, the instance and quest switches still
-- narrow it, so they follow the "Subasta" label instead of replacing it.
function ns.FilterSummary(filters)
    local content = filters.onlyInstances and filters.onlyQuests and "instancias o misiones"
                    or filters.onlyInstances and "instancias"
                    or filters.onlyQuests and "misiones"
    local parts
    if filters.onlyAH then
        parts = { "Subasta" }
        if content then parts[2] = content end
    elseif content then
        parts = { content:sub(1, 1):upper() .. content:sub(2) }
    else
        parts = { "Todas las procedencias" }
    end
    if filters.fixedOnly then parts[#parts+1] = "sin objetos aleatorios"
    elseif filters.noRandom then parts[#parts+1] = "sin puntuar tiradas" end
    if filters.dungeonMode then
        parts[#parts+1] = filters.dungeonMode == "heroic" and "mazmorras heroicas" or "mazmorras normales"
    end
    if filters.noDungeon then parts[#parts+1] = "sin mazmorras" end
    if filters.noRep then parts[#parts+1] = "sin reputación" end
    if filters.ilvlCap then parts[#parts+1] = "con tope de ilvl" end
    if filters.hitCap then parts[#parts+1] = "con tope de golpe" end
    return table.concat(parts, " · ")
end

function Cmd.filter(rest)
    if rest == "reset" then
        ns.ResetFilters(); RefreshUI(); Print("filtros restablecidos")
        return
    end
    local flt = LevelBiSCharDB.settings.filters
    local name, val = rest:match("^(%S*)%s*(%S*)$")
    if not name or name == "" then
        Print("filtros (|cffffd100/lbis filter <nombre> [on|off]|r):")
        for _, f in ipairs(FILTER_HELP) do
            Print(("  %-14s %s  |cff808080%s|r"):format(
                f[1], flt[f[1]] and "|cff40ff40on|r " or "|cffff6060off|r",
                f[2]))
        end
        Print("  difficulty: all / normal / heroic (dificultad de mazmorras)")
        return
    end
    if name:lower() == "difficulty" then
        if not ns.SetDungeonMode(val:lower()) then
            Print("Usa /lbis filter difficulty all, normal o heroic.")
            return
        end
        RefreshUI()
        Print(ns.FilterSummary(flt))
        return
    end
    local key
    for _, f in ipairs(FILTER_HELP) do
        if f[1]:lower() == name:lower() then key = f[1] end
    end
    if name:lower() == "onlyinstance" then key = "onlyInstance" end
    if not key then Print("|cffff4040no conozco el filtro '" .. name .. "'|r") return end
    local current = key == "onlyInstance" and flt.onlyInstances and flt.onlyQuests
                    or flt[key]
    if val == "on" then ns.SetFilter(key, true)
    elseif val == "off" then ns.SetFilter(key, false)
    else ns.SetFilter(key, not current) end
    RefreshUI()
    local state = key == "onlyInstance" and flt.onlyInstances and flt.onlyQuests
                  or flt[key]
    Print(("%s: %s"):format(key, state and "|cff40ff40on|r" or "|cffff6060off|r"))
end

-- Sorting is a setting, not a filter: it changes the order of the answer, not
-- which items are in it.
function Cmd.sort(rest)
    local sv = LevelBiSCharDB.settings
    rest = (rest or ""):lower()
    if rest == "delta" or rest == "mejora" or rest == "on" then
        ns.SetSortMode("delta")
    elseif rest == "oro" or rest == "gold" then
        ns.SetSortMode("gold")
    elseif rest == "slot" or rest == "ranura" or rest == "off" then
        ns.SetSortMode("slot")
    else
        ns.SetSortMode(sv.sortByDelta and "slot" or "delta")
    end
    RefreshUI()
    Print(("orden: %s"):format(sv.sortByGold and "|cff40ff40por mejora por oro|r"
        or sv.sortByDelta and "|cff40ff40por mejora|r" or "|cffffd100por ranura|r"))
end

function Cmd.profs(rest)
    if (rest or ""):lower() == "sim" then return ns.ProfSimRun() end
    scanProfessions()
    local any = false
    for prof, rank in pairs(profRank) do
        Print(("  %s |cffffd100%d|r"):format(prof, rank))
        any = true
    end
    if not any then Print("  (no se detectó ninguna profesión)") end
end

function Cmd.errors(arg)
    if arg == "clear" then
        wipe(errorLog); wipe(errorOrder)
        Print("registro de errores borrado")
        return
    end
    if #errorOrder == 0 then
        Print("ningún error desde que entraste")
        return
    end
    Print(("|cffff4040%d error(es):|r"):format(#errorOrder))
    for i, msg in ipairs(errorOrder) do
        local e = errorLog[msg]
        Print(("|cffffd100%d.|r %s |cff808080(x%d)|r"):format(i, msg, e.count))
        for line in tostring(e.stack):gmatch("[^\n]+") do
            if line:find("LevelBiS") then Print("     |cff808080" .. line .. "|r") end
        end
    end
    Print("|cff808080/lbis errors clear los borra|r")
end

function Cmd.test()
    local n = ns.dbCount or 0
    Print("comprobación: " .. n .. " items cargados.")
    if n == 0 then Print("  |cffff4040sin datos: ¿está cargando Data\\items_*.lua?|r") return end
    -- rank a couple of representative slots to prove the engine end-to-end
    for _, slot in ipairs({ "chest", "mainhand" }) do
        local list = S.RankSlot(slot, 70, ns.weights, ns.playerClass, ns.playerLevel, nil, 3)
        Print(("  %s: %d elegibles (mejor puntaje %.0f)"):format(
            slot, #list, list[1] and list[1].score or 0))
    end
    Print("  escala de Pawn: " .. W.ExportPawn(ns.playerClass, ns.activeSpec, ns.weights))
    Print("|cff40ff40todo en orden|r")
end

------------------------------------------------------------------------------
-- Slash dispatch
------------------------------------------------------------------------------
local function Handler(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "" or cmd == "show" or cmd == "ui" then
        if ns.UI then ns.UI:Toggle() else Cmd.summary() end
    elseif cmd == "summary" or cmd == "text" then Cmd.summary()
    elseif cmd == "help" then Cmd.help()
    elseif cmd == "spec" then Cmd.spec(rest)
    elseif cmd == "level" then Cmd.level(rest)
    elseif cmd == "weights" then Cmd.weights(rest)
    elseif cmd == "edit" then Cmd.edit()
    elseif cmd == "set" then Cmd.set(rest)
    elseif cmd == "reset" then Cmd.reset()
    elseif cmd == "tooltip" then Cmd.tooltip(rest)
    elseif cmd == "scan" then Cmd.scan()
    elseif cmd == "import" then Cmd.import(rest)
    elseif cmd == "export" then Cmd.export()
    elseif cmd == "explain" then Cmd.explain(rest)
    elseif cmd == "slot" then Cmd.slot(rest)
    elseif cmd == "test" then Cmd.test()
    elseif cmd == "errors" then Cmd.errors(rest)
    elseif cmd == "filter" or cmd == "filters" then Cmd.filter(rest)
    elseif cmd == "sort" or cmd == "orden" then Cmd.sort(rest)
    elseif cmd == "profs" or cmd == "professions" then Cmd.profs(rest)
    elseif cmd == "phase" or cmd == "fase" then Cmd.phase(rest)
    elseif cmd == "goal" or cmd == "objetivo" then Cmd.goal(rest)
    elseif ns.ExtraCmd and ns.ExtraCmd[cmd] then ns.ExtraCmd[cmd](rest)
    else Cmd.slot(cmd) end -- allow "/lbis chest" shorthand
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("SKILL_LINES_CHANGED")
-- Set bonuses are worth what your current gear makes them worth.
f:RegisterEvent("UNIT_INVENTORY_CHANGED")
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
f:RegisterEvent("UNIT_ATTACK_POWER")
-- Talents: spending points, the data arriving after login, and switching the
-- dual-spec group. Registering an event the client does not know is an error,
-- so the dual-spec one is only tried where its API exists, and inside pcall.
f:RegisterEvent("CHARACTER_POINTS_CHANGED")
f:RegisterEvent("PLAYER_TALENT_UPDATE")
if type(GetActiveTalentGroup) == "function" then
    pcall(f.RegisterEvent, f, "ACTIVE_TALENT_GROUP_CHANGED")
end
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        InitSV()
        LoadDB()
    elseif event == "PLAYER_LOGIN" then
        ns.loggedIn = true
        ns.RefreshSetCounts()
        ns:Refresh()
        SLASH_LEVELBIS1 = "/lbis"
        SLASH_LEVELBIS2 = "/levelbis"
        SlashCmdList["LEVELBIS"] = Handler
        Print(("listo: %d items, %s / %s. Escribe |cffffd100/lbis|r para abrir."):format(
            ns.dbCount or 0, ns.playerClass or "?", ns.activeSpec or "?"))
        if ns.weightsReseeded then
            Print("|cffffd100pesos actualizados.|r Ahora coinciden con las escalas "
                .. "publicadas para 2.4.3 en todas las estadísticas compatibles.")
            Print("  Los tuyos siguen en |cff808080LevelBiSCharDB.weightsBackup|r. "
                .. "Tócalos con |cffffd100/lbis edit|r.")
        end
    elseif event == "UNIT_ATTACK_POWER" then
        if arg1 ~= "player" or not UnitAttackPower then return end
        local base, positive, negative = UnitAttackPower("player")
        ns.weaponAttackPower = math.max(0, (base or 0) + (positive or 0) + (negative or 0))
        RefreshUI()
    elseif event == "UNIT_INVENTORY_CHANGED" or event == "PLAYER_EQUIPMENT_CHANGED" then
        if event == "UNIT_INVENTORY_CHANGED" and arg1 ~= "player" then return end
        -- What you are wearing is half of a set bonus's value.
        ns.RefreshSetCounts()
        RefreshUI()
    elseif event == "PLAYER_LEVEL_UP" then
        if arg1 then ns.playerLevel = arg1 end
        if arg1 and ns.loggedIn and ns.db then
            local list = ns.LevelUnlocks(arg1)
            if #list > 0 then Print(UnlockMessage(arg1, list)) end
        end
        RefreshUI()
    elseif event == "CHARACTER_POINTS_CHANGED" or event == "PLAYER_TALENT_UPDATE"
        or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        if not ns.loggedIn then return end
        local before = ns.activeSpec
        ns:Refresh()
        if ns.activeSpec ~= before then
            if S.ClearLifetimeCache then S.ClearLifetimeCache() end
            RefreshUI()
            Print(("especialización %s: |cffffd100%s|r")
                :format(ns.specManual and "de este grupo de talentos" or "según tus talentos",
                        ns.activeSpec))
        end
    elseif event == "SKILL_LINES_CHANGED" then
        profRank = nil   -- rescanned lazily; levelling a profession changes it
        if S.ClearLifetimeCache then S.ClearLifetimeCache() end
        RefreshUI()
    end
end)
