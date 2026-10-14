-- Profiles.lua --------------------------------------------------------------
-- Editor for the active spec's stat weights: the whole canonical key set laid
-- out at once, plus Pawn import/export.
--
-- The weights are the only thing standing between the item database and a
-- recommendation, so editing them had to stop being a chat command you type one
-- stat at a time. Every key is on screen because a weight of zero is a decision
-- too -- "this spec ignores spirit" is information, and hiding the unset keys
-- behind an "add stat" menu would bury it.
------------------------------------------------------------------------------
local ADDON, ns = ...
local L = ns.L
local S = ns.Scoring
local W = ns.Weights
local UI = ns.UI

local P = {}
ns.Profiles = P

local C = UI.C
local FONT_DISPLAY, FONT_BODY = UI.FONT_DISPLAY, UI.FONT_BODY
local text, fill = UI.text, UI.fill

-- English names for the canonical keys. The key itself stays visible in the
-- tooltip: it is what /lbis set and the Pawn map use.
local STAT_LABEL = {
    str = L["Strength"], agi = L["Agility"], sta = L["Stamina"], int = L["Intellect"],
    spi = L["Spirit"],
    ap = L["Attack Power"], rap = L["Ranged Attack Power"],
    feralap = L["Feral Attack Power"],
    sp = L["Spell Damage"], heal = L["Healing"], mp5 = L["Mana per 5 sec."],
    hit = L["Hit Rating"], spellhit = L["Spell Hit Rating"],
    crit = L["Crit Rating"], spellcrit = L["Spell Crit Rating"],
    haste = L["Haste Rating"], spellhaste = L["Spell Haste Rating"],
    expertise = L["Expertise Rating"],
    dodge = L["Dodge Rating"], parry = L["Parry Rating"], block = L["Block Rating"],
    blockval = L["Block Value"], def = L["Defense Rating"], resil = L["Resilience Rating"],
    arcanesp = L["Arcane Spell Damage"], firesp = L["Fire Spell Damage"],
    frostsp = L["Frost Spell Damage"], holysp = L["Holy Spell Damage"],
    naturesp = L["Nature Spell Damage"], shadowsp = L["Shadow Spell Damage"],
    spen = L["Spell Penetration"],
    armor = L["Armor"], dps = L["Weapon DPS"],
    rdps = L["Ranged DPS"], spd = L["Speed"],
}

-- Shared with the tooltip, which names the stats of a random-suffix roll.
function ns.StatLabel(key) return STAT_LABEL[key] or key end

-- Measured against a screenshot: at 126 px the longest labels (such as
-- "Spell Haste Rating") were cut mid-word. The label column takes 24 more
-- and the column pitch follows, which widens the panel and nothing else.
local COLS, ROW_H = 3, 23
local COL_PITCH, LABEL_W, BOX_W = 228, 150, 54
local PANEL_W = 14 + COLS * COL_PITCH + 14
-- Under the title, buttons and note sits one row of switches that change how
-- items are scored (they used to be in the main window's header). The fields
-- start under it.
local NOTE_END_H = 104
local SCORE_ROW_H = 24
local SCORE_Y = -(NOTE_END_H - 12)
local HEADER_H = NOTE_END_H + SCORE_ROW_H

local frame, dialog

------------------------------------------------------------------------------
-- Text transfer dialog (Pawn strings are far too long to type into chat)
------------------------------------------------------------------------------
local function buildDialog()
    local d = CreateFrame("Frame", "LevelBiSTextDialog", UIParent, "BackdropTemplate")
    d:SetSize(600, 96)
    d:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    d:SetFrameStrata("DIALOG")
    d:SetBackdrop({ bgFile = UI.SOLID, edgeFile = UI.SOLID, edgeSize = 1 })
    d:SetBackdropColor(C.ink[1], C.ink[2], C.ink[3], 0.98)
    d:SetBackdropBorderColor(C.rule[1], C.rule[2], C.rule[3], 1)
    d:EnableMouse(true)
    tinsert(UISpecialFrames, "LevelBiSTextDialog")

    d.title = text(d, FONT_BODY, 12, C.bone, "OVERLAY")
    d.title:SetPoint("TOPLEFT", d, "TOPLEFT", 14, -12)

    d.box = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    d.box:SetSize(560, 20)
    d.box:SetPoint("TOPLEFT", d, "TOPLEFT", 18, -34)
    d.box:SetAutoFocus(false)
    d.box:SetScript("OnEscapePressed", function(self) self:ClearFocus(); d:Hide() end)
    d.box:SetScript("OnEnterPressed", function(self)
        if d.onAccept then d.onAccept(self:GetText()) end
        self:ClearFocus(); d:Hide()
    end)

    d.hint = text(d, FONT_BODY, 10, C.mist, "OVERLAY")
    d.hint:SetPoint("TOPLEFT", d, "TOPLEFT", 18, -60)

    local close = CreateFrame("Button", nil, d, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", d, "TOPRIGHT", -2, -2)
    d:Hide()
    return d
end

-- onAccept = nil makes it read-only (export): the text is preselected to copy.
function P:TextDialog(title, initial, hint, onAccept)
    if not dialog then dialog = buildDialog() end
    dialog.title:SetText(title)
    dialog.hint:SetText(hint or "")
    dialog.onAccept = onAccept
    dialog.box:SetText(initial or "")
    dialog:Show()
    dialog.box:SetFocus()
    if not onAccept then dialog.box:HighlightText() end
end

------------------------------------------------------------------------------
-- Editor
------------------------------------------------------------------------------
local function pushToMain()
    if ns.UI and LevelBiSFrame and LevelBiSFrame:IsShown() then ns.UI:Refresh() end
end

-- Empty removes the stat; a typed 0 stores a real zero. They used to be the
-- same thing, and that was safe only while every weight defaulted to nothing.
-- It stopped being safe with `rdps`: absent means "fall back to the melee
-- weight", zero means "a gun is worth nothing to me", and collapsing the two
-- turned a warrior's rifle back into the best item in the game the first time
-- anybody opened the editor.
local function applyValue(key, raw)
    if raw == "" then
        ns.weights[key] = nil
        S.InvalidateProfile(ns.weights)
        S.UseProfile(ns.weights)
        pushToMain()
        return true
    end
    local val = tonumber(raw)
    if val == nil then return false end        -- caller restores the old text
    ns.weights[key] = val
    S.InvalidateProfile(ns.weights)
    S.UseProfile(ns.weights)
    pushToMain()
    return true
end

-- Replace the whole active profile in place: ns.weights is the table stored in
-- SavedVariables, so it is edited, never swapped.
local function replaceProfile(newWeights)
    for k in pairs(ns.weights) do ns.weights[k] = nil end
    for k, v in pairs(newWeights) do ns.weights[k] = v end
    S.InvalidateProfile(ns.weights)
    S.UseProfile(ns.weights)
    P:Refresh()
    pushToMain()
end

local function makeField(parent, key, col, row)
    local x = 14 + col * COL_PITCH
    local y = -HEADER_H - row * ROW_H

    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(COL_PITCH - 12, ROW_H)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    f:EnableMouse(true)

    local label = text(f, FONT_BODY, 11, C.mist)
    label:SetPoint("LEFT", f, "LEFT", 0, 0)
    label:SetWidth(LABEL_W); label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetText(STAT_LABEL[key] or key)

    local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    box:SetSize(BOX_W, 18)
    box:SetPoint("LEFT", f, "LEFT", LABEL_W + 8, 0)
    box:SetAutoFocus(false)
    box:SetJustifyH("RIGHT")
    box:SetMaxLetters(7)
    box.key = key

    local function restore()
        local v = ns.weights and ns.weights[key]
        -- `v == 0` is a value, not an absence: it has to show as "0".
        box:SetText((v ~= nil) and tostring(v) or "")
    end
    box.restore = restore

    box:SetScript("OnEnterPressed", function(self)
        if not applyValue(key, self:GetText()) then restore() end
        self:ClearFocus()
    end)
    box:SetScript("OnEditFocusLost", function(self)
        if not applyValue(key, self:GetText()) then restore() end
    end)
    box:SetScript("OnEscapePressed", function(self) restore(); self:ClearFocus() end)

    -- The canonical key is what /lbis set and the Pawn map speak, so it has to
    -- stay discoverable even though the label is translated.
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText(STAT_LABEL[key] or key)
        GameTooltip:AddLine(L["key: |cffffd100%s|r"]:format(key), 0.8, 0.8, 0.8)
        GameTooltip:AddLine(L["Empty removes the stat from the profile. A typed 0 is not the same: it keeps the stat at zero."],
                            0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return box
end

local function build()
    local perCol = math.ceil(#ns.STAT_KEYS / COLS)
    frame = CreateFrame("Frame", "LevelBiSWeightsFrame", UIParent, "BackdropTemplate")
    frame:SetSize(PANEL_W, HEADER_H + ROW_H * perCol + 14)
    -- Measures of the panel, for the harness (it draws nothing).
    P.metrics = { panelW = PANEL_W, headerH = HEADER_H, scoreY = SCORE_Y,
                  ruleY = -HEADER_H + 10, firstFieldY = -HEADER_H,
                  height = HEADER_H + ROW_H * perCol + 14, rows = perCol }
    frame:SetPoint(unpack(LevelBiSCharDB.settings.weightsPoint
                          or { "CENTER", UIParent, "CENTER", 0, -80 }))
    frame:SetBackdrop({ bgFile = UI.SOLID, edgeFile = UI.SOLID, edgeSize = 1 })
    frame:SetBackdropColor(C.ink[1], C.ink[2], C.ink[3], 0.96)
    frame:SetBackdropBorderColor(C.rule[1], C.rule[2], C.rule[3], 1)
    frame:SetMovable(true); frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "LevelBiSWeightsFrame")

    -- Same drag watchdog as the main window: OnMouseUp is not delivered when
    -- the button comes up outside the frame, which would strand it on the
    -- cursor. StopMovingOrSizing -- NOT StopMovingAndSizing, that is not the API.
    local moving = false
    local function stopDrag()
        frame:StopMovingOrSizing()
        frame:SetScript("OnUpdate", nil)
        moving = false
        local p, _, rp, x, y = frame:GetPoint()
        LevelBiSCharDB.settings.weightsPoint = { p, "UIParent", rp, x, y }
    end
    local function startDrag()
        if moving then return end
        moving = true
        frame:StartMoving()
        frame:SetScript("OnUpdate", function()
            if not IsMouseButtonDown("LeftButton") then stopDrag() end
        end)
    end
    frame:SetScript("OnMouseDown", startDrag)
    frame:SetScript("OnMouseUp", stopDrag)
    frame:SetScript("OnHide", function(self)
        self:StopMovingOrSizing(); self:SetScript("OnUpdate", nil)
    end)

    local title = text(frame, FONT_DISPLAY, 18, C.bone, "OVERLAY")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -12)
    title:SetText(L["Stat weights"])

    frame.who = text(frame, FONT_BODY, 11, C.mist, "OVERLAY")
    frame.who:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -38)

    frame.note = text(frame, FONT_BODY, 10, C.mist, "OVERLAY")
    frame.note:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -60)
    frame.note:SetWidth(PANEL_W - 200); frame.note:SetJustifyH("LEFT")
    frame.note:SetText(L["Saved per class and spec. Enter applies, and the main window updates instantly."])

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)

    local function btn(label, x, w, onClick)
        local b = UI.Button(frame)
        b:SetSize(w, 20); b:SetText(label)
        b:SetPoint("TOPRIGHT", frame, "TOPRIGHT", x, -34)
        b:SetScript("OnClick", onClick)
        return b
    end
    btn(L["Preset"], -14, 76, function()
        replaceProfile(W.Default(ns.playerClass, ns.activeSpec))
    end)
    btn(L["Export"], -94, 70, function()
        P:TextDialog(L["Export to Pawn"],
                     W.ExportPawn(ns.playerClass, ns.activeSpec, ns.weights),
                     L["Ctrl+C to copy. Esc closes."])
    end)
    btn(L["Import"], -168, 70, function()
        P:TextDialog(L["Import a Pawn scale"], "",
                     L["Paste the scale and press Enter."], function(str)
            local res, err = W.ImportPawn(str or "")
            if not res then
                ns.Print("|cffff4040" .. L["import failed:"] .. "|r " .. tostring(err))
                return
            end
            replaceProfile(res.weights)
            ns.Print(L["scale imported into |cffffd100%s / %s|r"]:format(
                ns.playerClassName or "?", ns.SpecLabel(ns.activeSpec)))
            if res.ignored and #res.ignored > 0 then
                ns.Print("|cffffd100" .. L["skipped because LevelBiS does not score them:"] .. "|r "
                         .. table.concat(res.ignored, ", "))
            end
        end)
    end)

    local rule = fill(frame, C.rule)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -HEADER_H + 10)
    rule:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -HEADER_H + 10)

    -- How items are scored, not which ones are in: the first three change the
    -- number (the editor's weights are the level-70 ones), the fourth is the
    -- bag warning. Same keys, same setters and same repaint as before.
    local function filters() return LevelBiSCharDB.settings.filters end
    local SCORE_SWITCHES = {
        { L["Level weights"], "levelScale",
          L["Ratings (hit, crit, haste…) are worth more the lower the level. The editor weights are the level 70 ones; this box scales them to the target level."] },
        { L["ilvl cap"], "ilvlCap",
          L["Heuristic: does not offer items with an ilvl far above the usual for that level. Useful with vendors and chests with no source level. It is not game data."] },
        { L["Hit cap (70)"], "hitCap",
          L["At level 70, hit above the cap adds nothing. Uses your current hit; does not count talents that lower the cap."] },
        { L["Bag alerts"], nil,
          L["Warns in chat when an item in your bags is an upgrade for a slot. Only works while the main window is open: closing it turns the alerts off. /lbis equip equips it."] },
    }
    frame.scoreChecks = {}
    local cx = 14
    for _, def in ipairs(SCORE_SWITCHES) do
        local label, key, tip = def[1], def[2], def[3]
        local getter, setter
        if key then
            getter = function() return filters()[key] end
            setter = function(v) ns.SetFilter(key, v) end
        else
            getter = function() return LevelBiSCharDB.settings.bagAlerts end
            setter = function(v) LevelBiSCharDB.settings.bagAlerts = v and true or false end
        end
        local c = UI.Checkbox(frame, label, cx, SCORE_Y, getter, setter, pushToMain)
        UI.TooltipOn(c, label, tip)
        frame.scoreChecks[#frame.scoreChecks + 1] = c
        cx = cx + UI.CheckWidth(label)
    end
    P.metrics.scoreRowEnd = cx

    frame.boxes = {}
    for i, key in ipairs(ns.STAT_KEYS) do
        local col = math.floor((i - 1) / perCol)
        local row = (i - 1) % perCol
        frame.boxes[key] = makeField(frame, key, col, row)
    end

    frame:Hide()
end

function P:Refresh()
    if not frame or not ns.weights then return end
    frame.who:SetText(("%s  \194\183  %s"):format(
        ns.playerClassName or "?", ns.SpecLabel(ns.activeSpec)))
    for key, box in pairs(frame.boxes) do
        if not box:HasFocus() then box.restore() end
        -- An unweighted stat is dimmed, so a profile reads at a glance as the
        -- handful of stats it actually cares about.
        local on = ns.weights[key] ~= nil
        local c = on and C.bone or C.mist
        box:SetTextColor(c[1], c[2], c[3])
    end
    for _, cb in ipairs(frame.scoreChecks or {}) do cb:sync() end
end

function P:Toggle()
    if not frame then build() end
    if frame:IsShown() then frame:Hide() else self:Refresh(); frame:Show() end
end

function P:Show()
    if not frame then build() end
    self:Refresh(); frame:Show()
end
