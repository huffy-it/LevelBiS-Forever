-- ProfSim.lua ---------------------------------------------------------------
-- M-9. "Which profession would give me the most?" answered with gear, not with
-- opinion: for every profession you do not have, rank the 17 slots as if you
-- had it at the highest skill your CURRENT level allows (deliberately not
-- the skill of the target level), and subtract the same ranking without it.
-- Swept over the levels from yours to 70 in steps of 5.
--
-- It costs a full ranking per profession and level, so it only runs under
-- /lbis profs sim, never in the window's refresh, and spreads itself over
-- frames when the client has C_Timer.
------------------------------------------------------------------------------
local ADDON, ns = ...
local S = ns.Scoring

local function Print(msg) ns.Print(msg) end

-- Skill ceiling a level allows: Apprentice at 5, Journeyman at 10, Expert at 20,
-- Artisan at 35, Master at 50. Declared from the game's own training rules.
function ns.SkillCap(level)
    if level >= 50 then return 375 end
    if level >= 35 then return 300 end
    if level >= 20 then return 225 end
    if level >= 10 then return 150 end
    if level >= 5 then return 75 end
    return 0
end

-- The trade skills that put gear in the data (craft sources and rprof).
local PROFESSIONS = { "Alchemy", "Blacksmithing", "Enchanting", "Engineering",
                      "Jewelcrafting", "Leatherworking", "Tailoring" }
local LABEL = {
    Alchemy = "Alquimia", Blacksmithing = "Herrería", Enchanting = "Encantamiento",
    Engineering = "Ingeniería", Jewelcrafting = "Joyería",
    Leatherworking = "Peletería", Tailoring = "Sastrería",
}
ns.PROFESSION_LABEL = LABEL

local function slotWord(name) return (ns.SLOT_LABEL and ns.SLOT_LABEL[name]) or name end

local function sweepLevels(from)
    local out, level = { from }, (math.floor(from / 5) + 1) * 5
    while level < 70 do out[#out + 1] = level; level = level + 5 end
    if from < 70 then out[#out + 1] = 70 end
    return out
end

local function winners(level, filters)
    local ranked = S.RankAll(level, ns.weights, ns.playerClass, ns.playerLevel, filters, 1)
    local scores, total = {}, 0
    for slot, list in pairs(ranked) do
        local top = list and list[1]
        if top and not top.fallback then
            scores[slot] = top.score
            total = total + top.score
        end
    end
    return scores, total
end

local function cloneFilters()
    local t = {}
    for k, v in pairs(LevelBiSCharDB.settings.filters) do t[k] = v end
    t.myProfsOnly = true      -- without it every craftable item is already in
    return t
end

-- Build a job: a list of ranking tasks run one at a time.
function ns.ProfSimStart(onDone)
    if not (ns.db and ns.weights) then return nil end
    local rank = ns.SkillCap(ns.playerLevel or 1)
    local job = {
        filters = cloneFilters(), rank = rank, levels = sweepLevels(ns.playerLevel or 1),
        base = {}, baseTotal = {}, results = {}, tasks = {}, done = false, onDone = onDone,
    }
    for _, level in ipairs(job.levels) do
        job.tasks[#job.tasks + 1] = { level = level }
    end
    for _, prof in ipairs(PROFESSIONS) do
        if not (ns.ProfessionRank and ns.ProfessionRank(prof)) then
            job.results[prof] = { prof = prof, slots = {}, area = 0, peak = 0 }
            for _, level in ipairs(job.levels) do
                job.tasks[#job.tasks + 1] = { level = level, prof = prof }
            end
        end
    end
    job.total, job.index = #job.tasks, 0
    return job
end

-- Run the next task. Returns true while there is more to do.
function ns.ProfSimStep(job)
    if job.done then return false end
    job.index = job.index + 1
    local task = job.tasks[job.index]
    if not task then job.done = true return false end
    S.SetIgnoreRandom(job.filters.noRandom)
    if not task.prof then
        job.base[task.level], job.baseTotal[task.level] = winners(task.level, job.filters)
    else
        ns.simProfession = { name = task.prof, rank = job.rank }
        local ok, scores = pcall(winners, task.level, job.filters)
        ns.simProfession = nil
        if ok then
            local res = job.results[task.prof]
            local base, gainSum = job.base[task.level] or {}, 0
            for slot, score in pairs(scores) do
                local gain = score - (base[slot] or 0)
                if gain > 0.5 then
                    local rec = res.slots[slot]
                    if not rec then rec = { gain = 0, from = task.level, to = task.level }; res.slots[slot] = rec end
                    rec.gain = math.max(rec.gain, gain)
                    rec.to = math.max(rec.to, task.level)
                    rec.from = math.min(rec.from, task.level)
                    gainSum = gainSum + gain
                end
            end
            res.area = res.area + gainSum
            local bt = job.baseTotal[task.level] or 0
            if bt > 0 then res.peak = math.max(res.peak, gainSum / bt * 100) end
        end
    end
    if job.index >= job.total then job.done = true end
    return not job.done
end

-- Results as an ordered list, best first, only professions that add something.
function ns.ProfSimResults(job)
    local out = {}
    for _, res in pairs(job.results) do
        if res.area > 0 then out[#out + 1] = res end
    end
    table.sort(out, function(a, b)
        if a.area ~= b.area then return a.area > b.area end
        return a.prof < b.prof
    end)
    return out
end

function ns.ProfSimLines(job)
    local lines = {}
    local list = ns.ProfSimResults(job)
    local first, last = job.levels[1], job.levels[#job.levels]
    if #list == 0 then
        lines[1] = ("Ninguna profesión te daría equipo mejor entre los niveles %d y %d "
            .. "con la habilidad %d, que es la que permite tu nivel."):format(first, last, job.rank)
        return lines
    end
    for i = 1, math.min(4, #list) do
        local res = list[i]
        local slots = {}
        for slot, rec in pairs(res.slots) do slots[#slots + 1] = { slot = slot, rec = rec } end
        table.sort(slots, function(a, b)
            if a.rec.gain ~= b.rec.gain then return a.rec.gain > b.rec.gain end
            return a.slot < b.slot
        end)
        local words, from, to = {}, math.huge, 0
        for j, s in ipairs(slots) do
            if j <= 3 then words[#words + 1] = slotWord(s.slot) end
            from, to = math.min(from, s.rec.from), math.max(to, s.rec.to)
        end
        local more = #slots > 3 and (" y %d más"):format(#slots - 3) or ""
        local when = (from == to) and ("a nivel %d"):format(from)
                     or ("entre los niveles %d y %d"):format(from, to)
        lines[#lines + 1] = ("%s: ganarías en %s%s %s, hasta +%.0f%% "
            .. "sobre lo mejor que consigues sin ella."):format(
            LABEL[res.prof] or res.prof, table.concat(words, ", "), more, when, res.peak)
    end
    return lines
end

local running
function ns.ProfSimRun()
    if running then Print("la simulación ya está en marcha.") return end
    local job = ns.ProfSimStart()
    if not job then Print("no hay datos para simular.") return end
    if job.rank == 0 then
        Print("a tu nivel aún no puedes aprender una profesión (se abre en el nivel 5).")
        return
    end
    ns.profSimResult = job
    local function finish()
        running = nil
        Print(("profesiones, con la habilidad |cffffd100%d|r que permite tu nivel:"):format(job.rank))
        for _, line in ipairs(ns.ProfSimLines(job)) do Print("  " .. line) end
        Print("  |cff808080Simulación: supone la receta aprendida; no cuenta materiales ni oro.|r")
    end
    if C_Timer and C_Timer.After then
        running = job
        Print(("simulando %d cálculos…"):format(job.total))
        local reported = 0
        local function tick()
            if running ~= job then return end
            local more = ns.ProfSimStep(job)
            local pct = math.floor(job.index / job.total * 4) * 25
            if pct > reported and pct < 100 then
                reported = pct
                Print(("  … %d%%"):format(pct))
            end
            if more then C_Timer.After(0, tick) else finish() end
        end
        C_Timer.After(0, tick)
    else
        running = job
        while ns.ProfSimStep(job) do end
        finish()
    end
end

ns.ExtraCmd = ns.ExtraCmd or {}
ns.ExtraCmd.profsim = function() ns.ProfSimRun() end
