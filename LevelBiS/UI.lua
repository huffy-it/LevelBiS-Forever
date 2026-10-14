-- UI.lua --------------------------------------------------------------------
-- In-game window. One row per equip slot, grouped by the rules that actually
-- govern them (armor obeys the tier gate, jewellery has no proficiency gate,
-- weapons carry the 2H-vs-1H logic).
--
-- The window answers one question: which slot gains the most, and where does
-- that item come from. Everything is subordinated to that, which is why the
-- gap track -- not the score columns -- is the loudest thing on screen.
------------------------------------------------------------------------------
local ADDON, ns = ...
local L = ns.L
local S = ns.Scoring
local W = ns.Weights

local UI = {}
ns.UI = UI

------------------------------------------------------------------------------
-- Design tokens
--
-- The panel floats over unpredictable game backgrounds, so the dark ground is
-- legibility, not fashion. Two accents, each with exactly one job: teal never
-- means anything but "upgrade available", amber never means anything but
-- "where it comes from". Item quality colours are canonical and must stay the
-- only other saturated colour on screen, so the chrome is deliberately
-- desaturated to keep out of their way.
------------------------------------------------------------------------------
local C = {
    ink   = { 0.071, 0.078, 0.110 },  -- #12141C panel ground (cool, not neutral black)
    shelf = { 0.106, 0.122, 0.169 },  -- #1B1F2B alternating row band
    rule  = { 0.169, 0.192, 0.259 },  -- #2B3142 hairlines
    mist  = { 0.486, 0.522, 0.608 },  -- #7C859B labels, secondary text
    label = { 0.659, 0.694, 0.769 },  -- #A8B1C4 main-window secondary text
    bone  = { 0.902, 0.894, 0.875 },  -- #E6E4DF primary text
    zang  = { 0.204, 0.827, 0.753 },  -- #34D3C0 upgrade magnitude ONLY
    ember = { 0.878, 0.639, 0.251 },  -- #E0A340 provenance ONLY
}
local HEX = { mist = "ff7c859b", label = "ffa8b1c4", zang = "ff34d3c0", ember = "ffe0a340" }

-- Client faces, so nothing has to ship with the addon.
local FONT_DISPLAY = "Fonts\\MORPHEUS.TTF"   -- quest-log serif; titles
local FONT_BODY    = "Fonts\\FRIZQT__.TTF"   -- names and labels
local FONT_DATA    = "Fonts\\ARIALN.TTF"     -- every numeral, condensed

local SOLID = "Interface\\Buttons\\WHITE8X8"

-- One refresh for a burst of GET_ITEM_INFO_RECEIVED, not one per item.
-- C_Timer exists in 2.5.x; without it the refresh simply happens at once.
local function afterDelay(seconds, fn)
    if C_Timer and C_Timer.After then C_Timer.After(seconds, fn) else fn() end
end

-- 740, not 668: once the client started spelling the roll into the name, the
-- recommendation column was cutting a long name like "Crimson Beholder's Eye of
-- the Beast" in half. Every extra pixel goes to that column; measured against a
-- screenshot, not calculated.
local FRAME_W = 740
-- The header is derived from a handful of numbers, never from loose ones.
-- Under the level stepper there are two rows of filter controls: the
-- checkboxes (what content counts, what you can get at) and the three cycling
-- buttons (rolls, auction house, order). The summary line sits SUMMARY_DY under
-- the last of them; the column titles, the rule and the first row follow the
-- summary at fixed distances, so folded and open cannot drift apart.
local ROW_H, GROUP_H = 21, 20
-- Six text lines: replaces, changes, origin, reason, lifetime and the
-- alternative without a random roll (the last one at y = -104).
local DETAIL_H = 127
UI.DETAIL_H = DETAIL_H
local PLAN_ROWS, PLAN_ROW_H = 8, 38
local PRIORITY_H = 32
local ROW_X = 10 -- Shared origin for row contents and column headings.
local FILTER_Y1, FILTER_Y2 = -82, -104
-- The filter rows fold away (progressive disclosure): the answer is the grid,
-- and the filters are what you reach for when the answer is wrong. The summary
-- line stays in view either way and says what is active. Open, the summary sits
-- under the second row; closed, it takes the place of the first.
local SUMMARY_DY = 26
local SUMMARY_Y_OPEN, SUMMARY_Y_CLOSED = FILTER_Y2 - SUMMARY_DY, -86
local HEAD_DY, RULE_DY, GRID_DY, PLAN_DY = 26, 37, 46, 14   -- PLAN_DY: the plan tabs start this far above the grid
local function headerFor(summaryY) return -(summaryY - GRID_DY) end
local HEADER_H = headerFor(SUMMARY_Y_OPEN)   -- the open header: 176 px
UI.HEADER_H = HEADER_H
local HINT_H = 14

-- Column grid, kept in one place so headers and rows cannot drift apart.
-- Measured against a screenshot, not calculated: a long label ("Secundaria",
-- before the window was translated) was being cut to "Secunda..." at 58 px. The bar is 120 px wide: it only has to rank rows
-- against each other, and the 60 px it gave back go to the recommended name.
-- Reading left to right, every column ends before the next one starts:
--   track  144..264   recIcon 278..296   recName 302..572 (320 wide when the
--   row has no item and the text may run under the tag)   tag 576..634
--   delta  638..714, inside the 720 px row. The tag was 46 px and the client
--   cut "Maz BoP" to "Maz B..."; 58 px fits "Raid BoP" at size 10.
local X = {
    slot = 14, eqIcon = 82, eqScore = 104, track = 144, trackW = 120,
    recIcon = 278, recName = 302, nameW = 270, nameWide = 320,
    tag = 576, tagW = 58, delta = 638, deltaW = 76,
}

UI.COLUMNS = X

-- The grouping encodes the eligibility rules, so it is structure, not decor.
local GROUPS = {
    { title = L["ARMOR"],     slots = { "head", "shoulder", "chest", "wrist",
                                     "hands", "waist", "legs", "feet" } },
    { title = L["ACCESSORIES"], slots = { "neck", "back", "finger1", "finger2",
                                     "trinket1", "trinket2" } },
    { title = L["WEAPONS"],   slots = { "mainhand", "offhand", "ranged" } },
}

local SLOT_LABEL = {
    head = L["Head"], shoulder = L["Shoulder"], chest = L["Chest"], wrist = L["Wrist"],
    hands = L["Hands"], waist = L["Waist"], legs = L["Legs"], feet = L["Feet"],
    neck = L["Neck"], back = L["Back"], finger1 = L["Ring 1"], finger2 = L["Ring 2"],
    trinket1 = L["Trinket 1"], trinket2 = L["Trinket 2"],
    mainhand = L["Main Hand"], offhand = L["Off Hand"], ranged = L["Ranged"],
}

ns.SLOT_LABEL = SLOT_LABEL

local function setFont(fs, path, size)
    if not fs:SetFont(path, size) then
        fs:SetFont(FONT_BODY, size)  -- face missing: never leave the text blank
    end
    return fs
end

local function text(parent, font, size, color, layer)
    local fs = parent:CreateFontString(nil, layer or "ARTWORK")
    setFont(fs, font, size)
    fs:SetTextColor(color[1], color[2], color[3])
    return fs
end

local function fill(parent, color, alpha)
    local t = parent:CreateTexture(nil, "BACKGROUND")
    t:SetTexture(SOLID)
    t:SetVertexColor(color[1], color[2], color[3], alpha or 1)
    return t
end

-- Shared so the profile editor is the same object as the main window rather
-- than a lookalike with its own copy of the palette.
UI.C, UI.HEX, UI.SOLID = C, HEX, SOLID
UI.FONT_DISPLAY, UI.FONT_BODY, UI.FONT_DATA = FONT_DISPLAY, FONT_BODY, FONT_DATA
UI.text, UI.fill = text, fill

-- Tooltip with a title and any number of wrapped grey lines.
local function tooltipOn(widget, title, ...)
    local lines = { ... }
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText(title)
        for _, line in ipairs(lines) do
            GameTooltip:AddLine(line, 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
UI.TooltipOn = tooltipOn

-- A checkbox with its label. Shared with the weights panel, so both draw the
-- same control; `after` is what repaints once the setter has run.
local function checkbox(parent, label, x, y, getter, setter, after)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(18, 18); c:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    c.text = text(c, FONT_BODY, 11, C.label)
    c.text:SetPoint("LEFT", c, "RIGHT", 2, 0); c.text:SetText(label)
    c:SetScript("OnClick", function(self) setter(self:GetChecked()); after() end)
    c.sync = function(self) self:SetChecked(getter()) end
    return c
end
UI.Checkbox = checkbox

-- The harness draws nothing, so widths are estimated: a label is about 6.5 px
-- per character at 11 pt (the widest pitch measured against screenshots), plus
-- the box and a gap. Used to place the controls and to check they cannot
-- overlap in the 740 px window.
local CHAR_W, CHECK_BOX_W, CONTROL_GAP = 6.5, 20, 8
local function charCount(s) return #(s:gsub("[\128-\191]", "")) end
local function checkWidth(label)
    return CHECK_BOX_W + math.ceil(charCount(label) * CHAR_W) + CONTROL_GAP
end
UI.CheckWidth = checkWidth

-- A button's width from its longest text: about 6.8 px per character at 11 pt
-- plus 14 px of padding. Deliberately a little generous, since the harness
-- cannot measure the real font.
local BUTTON_CHAR_W, BUTTON_PAD = 6.8, 14
local function buttonWidth(longest)
    return math.ceil(charCount(longest) * BUTTON_CHAR_W) + BUTTON_PAD
end
UI.ButtonWidth = buttonWidth

------------------------------------------------------------------------------
-- Buttons
--
-- One flat button for the whole addon instead of the stock red-and-gold
-- UIPanelButtonTemplate. The look is the window's own: a 1 px hairline on the
-- row-band colour, text in the body face. The client draws the hover and the
-- pressed state itself (highlight and pushed textures), so no OnEnter/OnLeave
-- script is taken: callers keep those for their tooltips. What the client does
-- NOT keep once the template is gone is the disabled look, so Enable, Disable
-- and SetEnabled repaint it here.
--
--   quiet     transparent until hovered, secondary text: for the discreet
--             actions that should not compete with the answer.
--   selected  (SetSelected) the current tab: filled with the hairline colour,
--             primary text and a 1 px ivory underline.
------------------------------------------------------------------------------
local BUTTON_BACKDROP = {
    bgFile = SOLID, edgeFile = SOLID, edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
}

local function paintButton(b)
    local st = b.lbis
    local ground, edge, ink
    if st.selected then
        ground, edge, ink = C.rule, C.rule, C.bone
    elseif st.quiet then
        ink = C.label
    else
        ground, edge = C.shelf, C.rule
        -- Once a button has been asked to be selectable, "not selected" reads
        -- as secondary text; a plain button keeps the primary colour.
        ink = (st.selected == false) and C.label or C.bone
    end
    if not st.enabled then ink = C.mist end
    if ground then
        b:SetBackdropColor(ground[1], ground[2], ground[3], 1)
        b:SetBackdropBorderColor(edge[1], edge[2], edge[3], 1)
    else
        b:SetBackdropColor(C.shelf[1], C.shelf[2], C.shelf[3], 0)
        b:SetBackdropBorderColor(C.rule[1], C.rule[2], C.rule[3], 0)
    end
    b:GetFontString():SetTextColor(ink[1], ink[2], ink[3])
    if st.selected then b.underline:Show() else b.underline:Hide() end
    -- A disabled button must not light up under the pointer.
    b.hover:SetAlpha(st.enabled and 1 or 0)
end

-- White at `alpha`, as a colour texture when the client has it.
local function tint(tex, alpha)
    if tex.SetColorTexture then
        tex:SetColorTexture(1, 1, 1, alpha)
    else
        tex:SetTexture(SOLID); tex:SetVertexColor(1, 1, 1, alpha)
    end
end

function UI.Button(parent, quiet)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b.lbis = { quiet = quiet and true or false, enabled = true, selected = nil }
    b:SetBackdrop(BUTTON_BACKDROP)

    local label = text(b, FONT_BODY, 11, C.bone, "OVERLAY")
    label:SetPoint("LEFT", b, "LEFT", 4, 0)
    label:SetPoint("RIGHT", b, "RIGHT", -4, 0)
    label:SetJustifyH("CENTER"); label:SetWordWrap(false)
    b:SetFontString(label)

    -- Hover and press are textures of our own with the colour baked in.
    -- SetHighlightTexture(path) + SetVertexColor drew an opaque white block
    -- over the label in the client (the alpha was lost). A texture in the
    -- HIGHLIGHT layer shows under the pointer by itself, and SetColorTexture
    -- keeps its alpha.
    b.hover = b:CreateTexture(nil, "HIGHLIGHT")
    b.hover:SetAllPoints(b)
    tint(b.hover, 0.06)
    b.pressed = b:CreateTexture(nil, "ARTWORK")
    b.pressed:SetAllPoints(b)
    tint(b.pressed, 0.10)
    b:SetPushedTexture(b.pressed)
    b:SetPushedTextOffset(0, -1)

    b.underline = b:CreateTexture(nil, "OVERLAY")
    b.underline:SetTexture(SOLID)
    b.underline:SetVertexColor(C.bone[1], C.bone[2], C.bone[3], 1)
    b.underline:SetHeight(1)
    b.underline:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 1, 1)
    b.underline:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)

    local enable, disable, setEnabled = b.Enable, b.Disable, b.SetEnabled
    function b:Enable() enable(self); self.lbis.enabled = true; paintButton(self) end
    function b:Disable() disable(self); self.lbis.enabled = false; paintButton(self) end
    function b:SetEnabled(on)
        setEnabled(self, on and true or false)
        self.lbis.enabled = on and true or false
        paintButton(self)
    end
    function b:SetSelected(selected)
        self.lbis.selected = selected and true or false
        paintButton(self)
    end
    function b:IsSelected() return self.lbis.selected == true end

    paintButton(b)
    return b
end

------------------------------------------------------------------------------
-- Source lines for tooltips
------------------------------------------------------------------------------
local CONTENT_LABEL = { raid = L["Raid"], dungeon = L["Dungeon"], pvp = L["PvP"] }

local function srcLines(item)
    local out = {}
    if not (item and item.src) then return out end
    -- The level a source demands is the difference between "you can use this"
    -- and "you can get this", so it belongs on the line, not in a footnote.
    local function lvl(s)
        if s.t == "quest" then
            return s.access and ("  |c" .. HEX.mist .. L["from level %s"]:format(s.access) .. "|r") or ""
        end
        return (s.lvl and s.lvl > 0)
               and ("  |c" .. HEX.mist .. L["NPC level %s"]:format(s.lvl) .. "|r") or ""
    end
    if item.uniq then
        out[#out+1] = "|c" .. HEX.mist .. L["Unique: you cannot carry two"] .. "|r"
    end
    local sources = {}
    local filters = LevelBiSCharDB and LevelBiSCharDB.settings
                    and LevelBiSCharDB.settings.filters
    -- What you wear, carry or can buy at the auction house is never closed by
    -- reputation or a finished quest; see S.AccessExempt.
    local skipAccess = S.AccessExempt and S.AccessExempt(item, nil, filters)
    -- Requirement and standing, or "Quest already completed", from the cache.
    local function note(s)
        local text = ns.Access and ns.Access.RouteNote(s)
        return text and ("  |c" .. HEX.mist .. "· " .. text .. "|r") or ""
    end
    -- "Only during <event>": a fact about the source, shown whatever the
    -- filters say (the pipeline proved it exists only while the event runs).
    local function season(s)
        local text = ns.Access and ns.Access.SeasonNote and ns.Access.SeasonNote(s)
        return text and ("  |c" .. HEX.mist .. "· " .. text .. "|r") or ""
    end
    for i, s in ipairs(item.src) do
        sources[#sources+1] = {
            source = s, index = i,
            active = not S.SourceAllowed or S.SourceAllowed(s, filters, skipAccess),
            access = S.RouteAccess(s, filters),
        }
    end
    table.sort(sources, function(a, b)
        if a.active ~= b.active then return a.active end
        if a.active and a.access ~= b.access then return a.access < b.access end
        return a.index < b.index
    end)
    for _, rankedSource in ipairs(sources) do
        local s = rankedSource.source
        if s.t == "drop" then
            local where = ns.InstanceLabel(s.inst) or CONTENT_LABEL[s.ct]
                       or (s.u and L["Unknown source"]) or L["Open world"]
            if s.ct == "dungeon" then
                local difficulty = ({ [1]=L["normal"], [2]=L["heroic"], [3]=L["normal and heroic"] })[s.diff]
                where = where .. " (" .. (difficulty or L["difficulty unverified"]) .. ")"
            end
            local who = s.name and (" \226\128\148 " .. s.name) or ""
            local pct = s.pct and string.format("  ~%.1f%% " .. L["(approx.)"], s.pct) or ""
            out[#out+1] = "|c" .. HEX.ember .. L["Drops from:"] .. "|r " .. where .. who .. pct .. lvl(s)
                        .. season(s)
        elseif s.t == "quest" then
            local side = s.side == "A" and (" |cff4080ff" .. L["[Alliance]"] .. "|r")
                      or s.side == "H" and (" |cffff4040" .. L["[Horde]"] .. "|r") or ""
            out[#out+1] = "|c" .. HEX.ember .. L["Quest:"] .. "|r "
                        .. (s.name or ("#" .. tostring(s.id))) .. side .. lvl(s)
                        .. (s.u and (" · " .. L["access unverified"]) or "") .. note(s) .. season(s)
        elseif s.t == "vendor" then
            local cost = s.cost and (" · " .. L["requires special currency"]) or ""
            local where = s.inst and (" \226\128\148 " .. ns.InstanceLabel(s.inst))
                       or (s.ct and CONTENT_LABEL[s.ct] and (" \226\128\148 " .. CONTENT_LABEL[s.ct]))
                       or ""
            out[#out+1] = "|c" .. HEX.ember .. L["Vendor:"] .. "|r " .. (s.name or "?") .. where .. cost
                .. (s.u and (" · " .. L["access unverified"]) or "") .. note(s) .. season(s)
        elseif s.t == "craft" then
            out[#out+1] = "|c" .. HEX.ember .. L["Crafted:"] .. "|r " .. (s.prof or "?")
                        .. (s.skill and (" " .. L["(skill %s)"]:format(s.skill)) or "")
        elseif s.t == "world" then
            out[#out+1] = "|c" .. HEX.mist .. L["Auction House or world drop"] .. "|r"
        end
    end
    return out
end
ns.SrcLines = srcLines

local function iconFor(id)
    local t = (GetItemIcon and GetItemIcon(id)) or (id and select(10, GetItemInfo(id)))
    return t or "Interface\\Icons\\INV_Misc_QuestionMark"
end

------------------------------------------------------------------------------
-- Tooltip handlers
------------------------------------------------------------------------------
local function ItemButton_OnLeave() GameTooltip:Hide() end

local function EqIcon_OnEnter(self)
    if not self.slotID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if not GameTooltip:SetInventoryItem("player", self.slotID) then
        GameTooltip:SetText(L["Empty slot"]); GameTooltip:Show()
    end
end

local function RecIcon_OnEnter(self)
    if not self.itemId then return end
    local item = ns.db and ns.db[self.itemId]
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    -- The link carries the roll. With a plain "item:<id>" the client drew the
    -- base item -- an armour value and an empty stat block -- and holding
    -- shift compared your gear against THAT, so a helm worth +31/+31/+47 read
    -- as "-22 strength, -22 agility, -33 stamina". The client does the whole
    -- job correctly once it is told which item is meant.
    local link, variantId = ns.VariantLink(self.itemId, item)
    ns.tooltipSlot = self.slotName
    GameTooltip:SetHyperlink(link)
    ns.tooltipSlot = nil

    -- Everything below is only for the case where the client could not draw
    -- the roll itself. Tooltip.lua hooks OnTooltipSetItem, so SetHyperlink
    -- above has already added the rank line, the roll and the sources; adding
    -- them again here is what put the roll on the tooltip twice.
    if not (ns.TooltipMarked and ns.TooltipMarked(GameTooltip)) then
        local drawn = variantId and select(2, ns.LocalName(self.itemId, item, variantId))
        local roll = (not drawn) and ns.RollLines and ns.RollLines(item)
        if roll then
            GameTooltip:AddLine(" ")
            for _, l in ipairs(roll) do GameTooltip:AddLine(l, 1, 1, 1, true) end
        end
        local setLines = item and item.set and ns.SetLines and ns.SetLines(item)
        if setLines then
            GameTooltip:AddLine(" ")
            for _, l in ipairs(setLines) do GameTooltip:AddLine(l, 1, 1, 1, true) end
        end
        local lines = srcLines(item)
        if #lines > 0 then
            GameTooltip:AddLine(" ")
            for _, l in ipairs(lines) do GameTooltip:AddLine(l, 1, 1, 1, true) end
        end
    end
    GameTooltip:Show()
end

-- The link the client needs for a modified click: the roll goes with it, since
-- pasting or trying on the base item would be a different piece of gear from
-- the one the row recommends.
local function recommendedLink(itemId)
    local item = ns.db and ns.db[itemId]
    local vlink = ns.VariantLink and ns.VariantLink(itemId, item)
    return vlink and select(2, GetItemInfo(vlink))
           or select(2, GetItemInfo(itemId))
           or vlink
end

-- Shift links into chat and Ctrl opens the dressing room. HandleModifiedItemClick
-- resolves both when it exists; the direct calls are the fallback.
local function modifiedClick(self)
    local shift, ctrl = IsShiftKeyDown(), IsControlKeyDown()
    if not (self.itemId and (shift or ctrl)) then return false end
    local link = recommendedLink(self.itemId)
    if not link then return true end
    if type(HandleModifiedItemClick) == "function" then
        if pcall(HandleModifiedItemClick, link) then return true end
    end
    if shift and ChatEdit_InsertLink then
        ChatEdit_InsertLink(link)
    elseif ctrl and DressUpItemLink then
        DressUpItemLink(link)
    end
    return true
end

-- CS-4. The Blizzard auction globals are not confirmed for 2.5.x, so each one
-- is checked before it is used and the whole call sits inside pcall.
function UI.AuctionOpen()
    return AuctionFrame ~= nil and AuctionFrame.IsShown ~= nil and AuctionFrame:IsShown() or false
end

function UI.SearchAuction(itemId)
    local item = ns.db and ns.db[itemId]
    local variantId = item and (item.sg or item.pg) and ns.Scoring.BestVariant
                      and select(4, ns.Scoring.BestVariant(item, ns.weights)) or nil
    local name = ns.LocalName(itemId, item, variantId)
    if not (BrowseName and AuctionFrameBrowse_Search) then
        ns.Print(L["Cannot find the Auction House search in this client."])
        return false
    end
    local ok = pcall(function()
        if AuctionFrameTab1 and AuctionFrameBrowse and not AuctionFrameBrowse:IsShown() then
            AuctionFrameTab1:Click()
        end
        BrowseName:SetText(name)
        AuctionFrameBrowse_Search()
    end)
    if not ok then ns.Print(L["The Auction House search failed; type the name by hand."]) end
    UI.lastSearch = name
    return ok
end

local function Icon_OnClick(self)
    modifiedClick(self)
end

local function Name_OnEnter(self)
    if self.highlight then self.highlight:SetAlpha(0.10) end
    RecIcon_OnEnter(self)
end

local function Name_OnLeave(self)
    if self.highlight then self.highlight:SetAlpha(0) end
    ItemButton_OnLeave()
end

-- Plain click: with the auction house open and a buyable item, search for it;
-- otherwise open the detail. Alt-click always opens the detail.
local function Name_OnClick(self)
    if modifiedClick(self) then return end
    if not (self.slotName and self.itemId) then return end
    local item = ns.db and ns.db[self.itemId]
    if not IsAltKeyDown() and UI.AuctionOpen() and S.Auctionable(item, self.itemId) then
        UI.SearchAuction(self.itemId)
    else
        UI:ToggleDetail(self.slotName)
    end
end

------------------------------------------------------------------------------
-- Frame construction
------------------------------------------------------------------------------
local frame

local function makeIcon(parent, x)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(18, 18)
    b:SetPoint("LEFT", parent, "LEFT", x, 0)
    b.border = fill(b, C.rule)
    b.border:SetPoint("TOPLEFT", -1, 1)
    b.border:SetPoint("BOTTOMRIGHT", 1, -1)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetAllPoints()
    b.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b:SetScript("OnLeave", ItemButton_OnLeave)
    b:SetScript("OnClick", Icon_OnClick)
    return b
end

-- "Dun BoP": the cheapest allowed way to get it, then how it binds. nil when
-- the data names neither. Provenance never gets a guess.
local SOURCE_TAG = { quest = L["Qst"], vendor = L["Vnd"], craft = L["Crf"] }
local BIND_TAG = { [1] = "BoP", [2] = "BoE", [3] = "BoU" }
local function sourceTag(item, id, filters)
    local route = S.AllowedRoute(item, filters)
    local where
    if route then
        where = SOURCE_TAG[route.t]
        if not where and route.t == "drop" then
            where = route.ct == "raid" and L["Raid"] or route.ct == "dungeon" and L["Dun"]
                    or route.ct == "pvp" and L["PvP"] or L["Wld"]
        end
    end
    local bind = BIND_TAG[S.Binding(item, id) or -1]
    if not (where or bind) then return nil end
    return (where and ("|c" .. HEX.ember .. where .. "|r") or "")
           .. ((where and bind) and " " or "")
           .. (bind and ("|c" .. HEX.label .. bind .. "|r") or "")
end
UI.SourceTag = sourceTag

-- The signature element. Normalised inside the row (equipped / recommended),
-- which is what makes it comparable across slots -- raw scores are not, since
-- a two-hander dwarfs a ring. The teal remainder is the upgrade still on the
-- table, so reading the column down the window ranks where to spend effort.
local function makeTrack(parent, x, w)
    local t = CreateFrame("Frame", nil, parent)
    t:SetSize(w, 7)
    t:SetPoint("LEFT", parent, "LEFT", x, 0)
    t.bg = fill(t, C.rule, 0.55)
    t.bg:SetAllPoints()
    t.held = t:CreateTexture(nil, "ARTWORK")   -- what you already carry
    t.held:SetTexture(SOLID)
    t.held:SetVertexColor(C.mist[1], C.mist[2], C.mist[3], 0.45)
    t.held:SetPoint("TOPLEFT"); t.held:SetPoint("BOTTOMLEFT")
    t.gain = t:CreateTexture(nil, "OVERLAY")   -- what you would gain
    t.gain:SetTexture(SOLID)
    t.gain:SetVertexColor(C.zang[1], C.zang[2], C.zang[3], 1)
    t.gain:SetPoint("TOPLEFT", t.held, "TOPRIGHT")
    t.gain:SetPoint("BOTTOMLEFT", t.held, "BOTTOMRIGHT")
    t.width = w
    return t
end

-- ratio: how much of the recommended score you already hold (0..1).
local function setTrack(t, ratio, known)
    if not known then
        t.held:SetWidth(0.001); t.gain:SetWidth(0.001)
        return
    end
    ratio = math.max(0, math.min(1, ratio))
    local held = math.max(0.001, t.width * ratio)
    t.held:SetWidth(held)
    t.gain:SetWidth(math.max(0.001, t.width - held))
end

local function makeRow(parent, y)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(FRAME_W - 20, ROW_H)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", ROW_X, y)

    row.band = fill(row, C.shelf, 0)
    row.band:SetAllPoints()

    row.slot = text(row, FONT_BODY, 11, C.label)
    row.slot:SetPoint("LEFT", row, "LEFT", X.slot, 0)
    row.slot:SetWidth(66); row.slot:SetJustifyH("LEFT")

    row.eqIcon = makeIcon(row, X.eqIcon)
    row.eqIcon:SetScript("OnEnter", EqIcon_OnEnter)

    row.eqScore = text(row, FONT_DATA, 12, C.label)
    row.eqScore:SetPoint("LEFT", row, "LEFT", X.eqScore, 0)
    row.eqScore:SetWidth(32); row.eqScore:SetJustifyH("RIGHT")

    row.track = makeTrack(row, X.track, X.trackW)

    row.recIcon = makeIcon(row, X.recIcon)
    row.recIcon:SetScript("OnEnter", RecIcon_OnEnter)

    row.recName = text(row, FONT_BODY, 12, C.bone)
    row.recName:SetPoint("LEFT", row, "LEFT", X.recName, 0)
    row.recName:SetWidth(X.nameWide); row.recName:SetJustifyH("LEFT")
    row.recName:SetWordWrap(false)

    -- Where it comes from and how it binds, in the two accents the window
    -- already reserves: amber for provenance, grey for the rest. Read without
    -- opening the detail.
    row.tag = text(row, FONT_BODY, 10, C.label)
    row.tag:SetPoint("LEFT", row, "LEFT", X.tag, 0)
    row.tag:SetWidth(X.tagW); row.tag:SetJustifyH("RIGHT")
    row.tag:SetWordWrap(false)

    -- FontStrings do not receive the mouse. A transparent button over the
    -- complete name makes the large target behave like the small icon: hover
    -- shows the item, shift-click links it, and an ordinary click expands the
    -- comparison below the row.
    row.recHit = CreateFrame("Button", nil, row)
    row.recHit:SetPoint("TOPLEFT", row, "TOPLEFT", X.recName - 3, -1)
    row.recHit:SetPoint("BOTTOMRIGHT", row, "BOTTOMLEFT", X.delta - 4, 1)
    row.recHit.highlight = fill(row.recHit, C.zang, 0)
    row.recHit.highlight:SetAllPoints()
    row.recHit:SetScript("OnEnter", Name_OnEnter)
    row.recHit:SetScript("OnLeave", Name_OnLeave)
    row.recHit:SetScript("OnClick", Name_OnClick)

    row.priority = text(row, FONT_DATA, 10, C.zang)
    row.priority:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", X.slot, 3)
    row.priority:SetWidth(66); row.priority:SetJustifyH("LEFT")
    row.priority:SetText(L["Start here"])
    row.priority:Hide()

    row.priorityBorder = {}
    for edge = 1, 4 do
        local line = fill(row, C.zang, 0.75)
        row.priorityBorder[edge] = line
    end
    row.priorityBorder[1]:SetHeight(1)
    row.priorityBorder[1]:SetPoint("TOPLEFT"); row.priorityBorder[1]:SetPoint("TOPRIGHT")
    row.priorityBorder[2]:SetHeight(1)
    row.priorityBorder[2]:SetPoint("BOTTOMLEFT"); row.priorityBorder[2]:SetPoint("BOTTOMRIGHT")
    row.priorityBorder[3]:SetWidth(1)
    row.priorityBorder[3]:SetPoint("TOPLEFT"); row.priorityBorder[3]:SetPoint("BOTTOMLEFT")
    row.priorityBorder[4]:SetWidth(1)
    row.priorityBorder[4]:SetPoint("TOPRIGHT"); row.priorityBorder[4]:SetPoint("BOTTOMRIGHT")
    for _, line in ipairs(row.priorityBorder) do line:Hide() end

    row.delta = text(row, FONT_DATA, 13, C.zang)
    row.delta:SetPoint("LEFT", row, "LEFT", X.delta, 0)
    row.delta:SetWidth(X.deltaW); row.delta:SetJustifyH("RIGHT")
    row.delta:SetWordWrap(false)   -- "not compared" is one line, never two
    return row
end

local function makeDetail(parent)
    local d = CreateFrame("Frame", nil, parent)
    d:SetSize(FRAME_W - 28, DETAIL_H)
    d.bg = fill(d, C.shelf, 0.92); d.bg:SetAllPoints()
    d.rule = fill(d, C.zang, 0.65)
    d.rule:SetWidth(2); d.rule:SetPoint("TOPLEFT"); d.rule:SetPoint("BOTTOMLEFT")

    local function line(y, size, color)
        local fs = text(d, FONT_BODY, size, color)
        fs:SetPoint("TOPLEFT", d, "TOPLEFT", 10, y)
        fs:SetPoint("RIGHT", d, "RIGHT", -8, 0)
        fs:SetJustifyH("LEFT"); fs:SetWordWrap(false)
        return fs
    end
    d.items = line(-7, 11, C.bone)
    d.stats = line(-27, 10, C.label)
    d.source = line(-47, 10, C.label)
    d.reason = line(-66, 10, C.label)
    d.lifetime = line(-85, 10, C.label)

    -- The alternative without a random roll is three strings in a row so that
    -- the item name can be hovered and shift-clicked on its own: a FontString
    -- takes no mouse, so a button sits over exactly the name.
    local ALT_Y = -104
    d.altLead = text(d, FONT_BODY, 10, C.label)
    d.altLead:SetPoint("TOPLEFT", d, "TOPLEFT", 10, ALT_Y)
    d.altLead:SetJustifyH("LEFT"); d.altLead:SetWordWrap(false)
    d.altName = text(d, FONT_BODY, 10, C.bone)
    d.altName:SetPoint("TOPLEFT", d.altLead, "TOPRIGHT", 4, 0)
    d.altName:SetJustifyH("LEFT"); d.altName:SetWordWrap(false)
    d.altTail = text(d, FONT_BODY, 10, C.label)
    d.altTail:SetPoint("TOPLEFT", d.altName, "TOPRIGHT", 4, 0)
    d.altTail:SetPoint("RIGHT", d, "RIGHT", -8, 0)
    d.altTail:SetJustifyH("LEFT"); d.altTail:SetWordWrap(false)
    d.altHit = CreateFrame("Button", nil, d)
    d.altHit:SetPoint("TOPLEFT", d.altName, "TOPLEFT", -2, 2)
    d.altHit:SetPoint("BOTTOMRIGHT", d.altName, "BOTTOMRIGHT", 2, -2)
    d.altHit:SetScript("OnEnter", RecIcon_OnEnter)
    d.altHit:SetScript("OnLeave", ItemButton_OnLeave)
    -- Shift and Ctrl act on the item; a plain click has nothing to open here.
    d.altHit:SetScript("OnClick", function(self) modifiedClick(self) end)
    d.altHit:Hide()
    d:Hide()
    return d
end

local function makeGroupHeader(parent, y, title)
    local g = CreateFrame("Frame", nil, parent)
    g:SetSize(FRAME_W - 20, GROUP_H)
    g:SetPoint("TOPLEFT", parent, "TOPLEFT", ROW_X, y)

    local label = text(g, FONT_BODY, 10, C.label)
    label:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", X.slot, 4)
    label:SetText(title)

    local line = fill(g, C.rule)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", label, "BOTTOMRIGHT", 10, 3)
    line:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", -4, 3)
    return g
end

local function specDropdown_Init()
    for _, spec in ipairs(W.SpecsFor(ns.playerClass)) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = ns.SpecLabel(spec)
        info.checked = (spec == ns.activeSpec)
        info.func = function()
            ns.SetManualSpec(spec)
            UIDropDownMenu_SetText(frame.specDD, ns.SpecLabel(spec))
            UI:Refresh()
        end
        UIDropDownMenu_AddButton(info)
    end
end

local function build()
    frame = CreateFrame("Frame", "LevelBiSFrame", UIParent, "BackdropTemplate")
    frame:SetPoint(unpack(LevelBiSCharDB.settings.uiPoint
                          or { "CENTER", UIParent, "CENTER", 0, 0 }))
    -- A flat panel with a single hairline instead of the stock dialog carving,
    -- so the window reads as an instrument rather than a quest popup.
    frame:SetBackdrop({
        bgFile = SOLID, edgeFile = SOLID, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    frame:SetBackdropColor(C.ink[1], C.ink[2], C.ink[3], 1)
    frame:SetBackdropBorderColor(C.rule[1], C.rule[2], C.rule[3], 1)
    -- Another addon's tracker was drawing over the window. HIGH puts it above
    -- the ordinary panels without reaching the strata reserved for dialogs and
    -- tooltips; SetToplevel raises it over anything sharing that strata when
    -- you click it.
    -- Item names arrive from the server after the first ask, so a fresh login
    -- draws the English fallback and then has to be told to look again.
    frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    frame:SetScript("OnEvent", function(self, event, itemID, success)
        if event == "AUCTION_HOUSE_SHOW" or event == "AUCTION_HOUSE_CLOSED" then
            -- AuctionFrame may still report itself shown while the close event
            -- arrives, so the hint is read a moment later.
            afterDelay(0.2, UI.RefreshHint)
            return
        end
        if success == false then return end
        local relevant = false
        for _, row in ipairs(self.rows or {}) do
            if row.recIcon.itemId == itemID
               or (row.eqIcon.slotID and S.EquippedItemID(row.eqIcon.slotID) == itemID) then
                relevant = true
                break
            end
        end
        if not relevant then return end
        if self:IsShown() and not self.__lbisNameRefresh then
            self.__lbisNameRefresh = true
            afterDelay(0.5, function()
                self.__lbisNameRefresh = nil
                if self:IsShown() then UI:Refresh() end
            end)
        end
    end)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetMovable(true); frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "LevelBiSFrame") -- Esc closes

    local function savePoint()
        local p, _, rp, x, y = frame:GetPoint()
        LevelBiSCharDB.settings.uiPoint = { p, "UIParent", rp, x, y }
    end

    -- Dragging. OnMouseUp only fires if the button is released over the same
    -- region that got OnMouseDown, so releasing outside it would strand the
    -- frame on the cursor; the OnUpdate watchdog ends the drag from the button
    -- state instead, which holds wherever the pointer is.
    local moving = false
    local function stopDrag()
        frame:StopMovingOrSizing()  -- NOT StopMovingAndSizing; that is not the API
        frame:SetScript("OnUpdate", nil)
        moving = false
        pcall(savePoint)
    end
    local function startDrag()
        if moving then return end
        moving = true
        frame:StartMoving()
        frame:SetScript("OnUpdate", function()
            if not IsMouseButtonDown("LeftButton") then stopDrag() end
        end)
    end

    frame:SetScript("OnHide", function(self)
        self:StopMovingOrSizing()
        self:SetScript("OnUpdate", nil)
    end)
    frame:SetScript("OnMouseDown", startDrag)
    frame:SetScript("OnMouseUp", stopDrag)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", startDrag)
    frame:SetScript("OnDragStop", stopDrag)

    -- Masthead ---------------------------------------------------------------
    local title = text(frame, FONT_DISPLAY, 20, C.bone, "OVERLAY")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", X.slot, -12)
    title:SetText("LevelBiS")

    -- The recommendation is body text so it remains readable at this size.
    frame.lede = text(frame, FONT_BODY, 13, C.zang, "OVERLAY")
    frame.lede:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    frame.lede:SetWidth(FRAME_W - 60); frame.lede:SetJustifyH("LEFT")

    frame.who = text(frame, FONT_BODY, 11, C.label, "OVERLAY")
    frame.who:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -32, -16)
    frame.who:SetJustifyH("RIGHT")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)

    frame.weightsBtn = UI.Button(frame)
    frame.weightsBtn:SetSize(56, 19)
    frame.weightsBtn:SetText(L["Weights"])
    frame.weightsBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -36)
    frame.weightsBtn:SetScript("OnClick", function()
        if ns.Profiles then ns.Profiles:Toggle() end
    end)

    -- Controls ---------------------------------------------------------------
    frame.specDD = CreateFrame("Frame", "LevelBiSSpecDD", frame, "UIDropDownMenuTemplate")
    frame.specDD:SetPoint("TOPLEFT", frame, "TOPLEFT", X.slot - 16, -50)
    UIDropDownMenu_SetWidth(frame.specDD, 104)
    UIDropDownMenu_Initialize(frame.specDD, specDropdown_Init)

    local function stepBtn(label, x, w, onClick)
        local b = UI.Button(frame)
        b:SetSize(w, 19); b:SetText(label)
        b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -56)
        b:SetScript("OnClick", onClick)
        return b
    end
    frame.lvlLabel = text(frame, FONT_DATA, 13, C.bone, "OVERLAY")
    frame.lvlLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 140, -60)
    frame.lvlLabel:SetWidth(94); frame.lvlLabel:SetJustifyH("LEFT")

    stepBtn("<", 236, 22, function()
        LevelBiSCharDB.targetLevel = math.max(1, ns:TargetLevel() - 1); UI:Refresh() end)
    stepBtn(">", 260, 22, function()
        LevelBiSCharDB.targetLevel = math.min(70, ns:TargetLevel() + 1); UI:Refresh() end)
    stepBtn(L["Current"], 286, 50, function()
        LevelBiSCharDB.targetLevel = nil; UI:Refresh() end)
    -- The rest of the level row, left to right: the goal, the dungeon
    -- difficulty and the phase. They sit on the stepper's row so the question
    -- "which level, for what, up to where" reads in one line; their widths come
    -- from their longest text.
    local GOAL_W = buttonWidth(L["Goal: leveling"])
    local DIFFICULTY_W = buttonWidth(L["Dungeons: normal"])
    local PHASE_W = buttonWidth(L["Phase: %s"]:format(5))
    local goalX = 286 + 50 + CONTROL_GAP
    local difficultyX = goalX + GOAL_W + 6
    local phaseX = difficultyX + DIFFICULTY_W + 6

    -- M-10: leveling or level 70, as one switch.
    frame.goalBtn = stepBtn(L["Goal: leveling"], goalX, GOAL_W, function()
        ns.SetGoal(LevelBiSCharDB.settings.goal == "endgame" and "leveling" or "endgame")
        UI:Refresh()
    end)
    frame.goalBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText(L["Goal"])
        GameTooltip:AddLine(L["Level 70 includes raids, heroic dungeons and the open phase, without the leveling exclusions. Going back to Leveling restores your filters and your target level."], 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    frame.goalBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame.difficultyBtn = stepBtn(L["Dungeons: all"], difficultyX, DIFFICULTY_W, function()
        local current = LevelBiSCharDB.settings.filters.dungeonMode
        ns.SetDungeonMode(not current and "normal" or current == "normal" and "heroic" or "all")
        UI:Refresh()
    end)
    frame.difficultyBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText(L["Dungeon difficulty"])
        GameTooltip:AddLine(L["Cycles through all, normal and heroic. A specific difficulty requires a confirmed source; other sources keep their filters."], 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    frame.difficultyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- M-7: the phase the window counts content up to, always on screen so it is
    -- clear what is and is not being offered. Click steps through 1 to 5. The
    -- button says "Phase: N"; the full name of the phase is the tooltip's title.
    frame.phaseBtn = stepBtn(L["Phase: %s"]:format(5), phaseX, PHASE_W, function()
        local flt = LevelBiSCharDB.settings.filters
        local nextPhase = ((flt.maxPhase or S.CURRENT_PHASE) % 5) + 1
        ns.SetPhase(nextPhase)
        UI:Refresh()
    end)
    frame.phaseBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText(ns.PhaseLabel(LevelBiSCharDB.settings.filters.maxPhase))
        GameTooltip:AddLine(L["Phase %d is open today. Content counts up to the chosen phase; anything later (Zul'Aman, Sunwell, Quel'Danas) is not offered. One click moves to the next; /lbis phase auto goes back to the current one."]:format(S.CURRENT_PHASE),
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    frame.phaseBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Where every control of the header lands, kept so the harness can check
    -- that none overlaps another and none leaves the window (it draws nothing).
    -- The top row holds the title, the tabs and the class text; the Weights
    -- button sits one row under it (y = -36, 19 px tall, so it ends at -55 and
    -- the level row starts at -56).
    UI.controlLayout = {}
    local function recordControl(name, y, x, w, h)
        UI.controlLayout[#UI.controlLayout + 1] = { name = name, y = y, x = x, w = w, h = h }
    end
    UI.recordControl = recordControl
    recordControl("title", -14, 14, 104, 24)
    recordControl("Pesos", -36, FRAME_W - 14 - 56, 56, 19)
    recordControl("level", -56, 140, 94, 19)
    recordControl("<", -56, 236, 22, 19)
    recordControl(">", -56, 260, 22, 19)
    recordControl("Actual", -56, 286, 50, 19)
    recordControl("goal", -56, goalX, GOAL_W, 19)
    recordControl("difficulty", -56, difficultyX, DIFFICULTY_W, 19)
    recordControl("phase", -56, phaseX, PHASE_W, 19)

    local flt = function() return LevelBiSCharDB.settings.filters end
    local function repaint() UI:Refresh() end

    -- Row 1: what content counts and what you can get at. Only the switches
    -- that change what a levelling character is offered; the score adjustments
    -- live in the weights panel, and My armor, My faction and No PvP are
    -- reached with /lbis filter.
    local CHECKS = {
        { L["No raid"], "noRaid", L["Excludes what only drops in raids."] },
        { L["Instances"], "onlyInstances",
          L["Keeps drops and vendors from dungeons or raids. Quest rewards depend on the Quests checkbox."] },
        { L["Quests"], "onlyQuests",
          L["Keeps quest rewards. You can combine it with Instances."] },
        { L["My professions"], "myProfsOnly",
          L["Excludes what needs a profession, or a level of one, that you don't have: craftable items and also gadgets that require the skill to be equipped."] },
        { L["Reachable"], "onlyReachable",
          L["Keeps what you can get: enough reputation, unique quests not yet done, seasonal sources only during their event. A source's level always counts."] },
    }
    frame.checks = {}
    local cx = X.slot
    for _, def in ipairs(CHECKS) do
        local label, key, tip = def[1], def[2], def[3]
        -- ns.SetFilter, not a plain assignment: it keeps the exclusive pairs
        -- from both being on, wherever the change comes from.
        local c = checkbox(frame, label, cx, FILTER_Y1,
            function() return flt()[key] end,
            function(v) ns.SetFilter(key, v) end, repaint)
        tooltipOn(c, label, tip)
        frame.checks[#frame.checks + 1] = c
        recordControl(label, FILTER_Y1, cx, checkWidth(label))
        cx = cx + checkWidth(label)
    end

    -- Row 2: three buttons that cycle through their states, one per question
    -- that used to take two checkboxes. The flags underneath are the same ones;
    -- ns.*Mode reads them and ns.Set*Mode writes them through ns.SetFilter.
    local BUTTON_CHAR_W, CYCLE_GAP = 8.1, 6
    local CYCLES = {
        { prefix = L["Rolls"], modes = ns.ROLL_MODES,
          labels = { best = L["Best"], ignore = L["Ignore"], exclude = L["Exclude"] },
          get = function() return ns.RollMode(flt()) end, set = ns.SetRollMode,
          title = L["Random rolls"],
          tips = {
              L["What to do with items that have a random suffix or property. One click moves to the next state."],
              L["Best: scores each item on its best roll. It is an assumption, but it shows you what you could get."],
              L["Ignore: keeps the items but scores only what is guaranteed, weapon DPS included. You may miss upgrades that depend on the suffix."],
              L["Exclude: drops random items entirely. You also lose weapons whose DPS is guaranteed."],
          } },
        { prefix = L["Auction House"], modes = ns.AUCTION_MODES,
          labels = { include = L["Include"], exclude = L["Exclude"], only = L["Only"] },
          get = function() return ns.AuctionMode(flt()) end, set = ns.SetAuctionMode,
          title = L["Auction House"],
          tips = {
              L["What to do with what can be bought on the Auction House. One click moves to the next state."],
              L["Include: no restriction by binding."],
              L["Exclude: drops what can be bought on the Auction House."],
              L["Only: keeps only what someone can sell you, nothing Bind on Pickup. Your shopping list."],
          } },
        { prefix = L["Order"], modes = ns.SORT_MODES,
          labels = { slot = L["Slot"], delta = L["Upgrade"], gold = L["Gold"] },
          get = function() return ns.SortMode(LevelBiSCharDB.settings) end,
          set = ns.SetSortMode,
          title = L["Row order"],
          tips = {
              L["It does not filter: it changes the order of the answer. One click moves to the next state."],
              L["Slot: the paperdoll order, grouped into armor, accessories and weapons."],
              L["Upgrade: the slot you gain the most from is on top. The line marks 70% of the upgrade: that is where it pays to spend. Rings and trinkets no longer stay together."],
              L["Gold: sorts by what you gain per coin, using the price you saw on the Auction House. Anything with no price seen goes last: open the Auction House so it is remembered."],
          } },
    }
    frame.cycles = {}
    cx = X.slot
    for _, def in ipairs(CYCLES) do
        local widest = 0
        for _, label in pairs(def.labels) do
            widest = math.max(widest, charCount(def.prefix .. ": " .. label))
        end
        local w = math.ceil(widest * BUTTON_CHAR_W)
        local b = UI.Button(frame)
        b:SetSize(w, 19)
        b:SetPoint("TOPLEFT", frame, "TOPLEFT", cx, FILTER_Y2)
        b.sync = function(self)
            self:SetText(def.prefix .. ": " .. def.labels[def.get()])
        end
        b:SetScript("OnClick", function()
            def.set(ns.NextMode(def.modes, def.get()))
            UI:Refresh()
        end)
        tooltipOn(b, def.title, unpack(def.tips))
        b.def = def
        frame.cycles[#frame.cycles + 1] = b
        recordControl(def.prefix, FILTER_Y2, cx, w)
        cx = cx + w + CYCLE_GAP
    end

    frame.filtersBtn = UI.Button(frame)
    frame.filtersBtn:SetSize(110, 19)
    frame.filtersBtn:SetScript("OnClick", function()
        local sv = LevelBiSCharDB.settings
        sv.filtersOpen = not sv.filtersOpen
        UI:Refresh()
    end)
    frame.filtersBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText(L["Filters"])
        GameTooltip:AddLine(L["Shows or hides the filter checkboxes and the rolls, Auction House and order buttons. The summary next to it says what is active even when they are hidden."], 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    frame.filtersBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame.filterSummary = text(frame, FONT_BODY, 10, C.label, "OVERLAY")
    frame.filterSummary:SetPoint("TOPLEFT", frame, "TOPLEFT", 130, SUMMARY_Y_OPEN)
    frame.filterSummary:SetWidth(440)
    frame.filterSummary:SetHeight(14)
    frame.filterSummary:SetJustifyH("LEFT")
    local reset = UI.Button(frame, true)   -- quiet: it must not compete with the answer
    reset:SetSize(136, 19)
    reset:SetText(L["Reset filters"])
    reset:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, SUMMARY_Y_OPEN + 6)
    reset:SetScript("OnClick", function() ns.ResetFilters(); UI:Refresh() end)
    frame.resetFilters = reset
    local summaryHit = CreateFrame("Button", nil, frame)
    summaryHit:SetAllPoints(frame.filterSummary)
    summaryHit:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText(ns.FilterSummary(flt()))
        GameTooltip:AddLine(L["Content filters combine with Auction House. Instances and Quests add to each other. Each row says how many options it can score when you open its detail."], 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(L["Reset filters restores the initial selection. It keeps your weights and the row order."], 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(L["My armor, My faction and No PvP no longer have a checkbox: /lbis filter shows and changes them. The score adjustments are in Weights."], 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    summaryHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Column headers ---------------------------------------------------------
    frame.colHeads = {}
    local function colHead(label, x, w, justify)
        local h = text(frame, FONT_BODY, 9, C.label, "OVERLAY")
        h.dx = ROW_X + x
        frame.colHeads[#frame.colHeads + 1] = h
        h:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X + x, SUMMARY_Y_OPEN - HEAD_DY)
        h:SetWidth(w); h:SetJustifyH(justify or "LEFT")
        h:SetText(label)
        return h
    end
    colHead(L["SLOT"], X.slot, 58)
    colHead(L["EQUIPPED"], X.eqIcon, 54)
    colHead(L["UPGRADE AVAILABLE"], X.track, X.trackW)
    colHead(L["RECOMMENDED"], X.recIcon, X.delta - X.recIcon - 8)
    colHead(L["GAIN"], X.delta, X.deltaW, "RIGHT")

    local rule = fill(frame, C.rule)
    frame.rule = rule
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, SUMMARY_Y_OPEN - RULE_DY)
    rule:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, SUMMARY_Y_OPEN - RULE_DY)

    -- Tabs (M-4) --------------------------------------------------------------
    -- The window keeps one answer per screen. "Gear" is the grid, "Dungeons"
    -- turns the same ranking into a suggestion of where to go ("Which dungeon
    -- should I run?" is the question the tab answers and heads its page), and
    -- "Consumables" is what to bring. The current tab is marked as selected, not
    -- disabled: every tab stays clickable and keeps its normal look.
    frame.tabs = {}
    local TAB_Y, TAB_GAP = -14, 4
    local tabX = 120
    local function tabButton(label, key)
        local w = buttonWidth(label) + 6
        local b = UI.Button(frame)
        b:SetSize(w, 19); b:SetText(label)
        b:SetPoint("TOPLEFT", frame, "TOPLEFT", tabX, TAB_Y)
        b:SetScript("OnClick", function() UI:SetTab(key) end)
        frame.tabs[key] = b
        recordControl("tab " .. label, TAB_Y, tabX, w, 19)
        tabX = tabX + w + TAB_GAP
        return b
    end
    tabButton(L["Gear"], "gear")
    tabButton(L["Dungeons"], "plan")
    tabButton(L["Consumables"], "cons")
    -- The class and spec text is right-aligned against the close button; its
    -- width is an estimate (about 34 characters at most) so the harness can see
    -- it stays clear of the tabs.
    recordControl("class", TAB_Y, FRAME_W - 32 - math.ceil(34 * CHAR_W), math.ceil(34 * CHAR_W), 14)

    frame.plan = CreateFrame("Frame", nil, frame)
    frame.plan:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X, -(HEADER_H - PLAN_DY))
    frame.plan:SetSize(FRAME_W - 20, PLAN_ROWS * PLAN_ROW_H + 40)
    frame.plan.title = text(frame.plan, FONT_BODY, 10, C.label)
    frame.plan.title:SetPoint("TOPLEFT", frame.plan, "TOPLEFT", X.slot, 0)
    frame.plan.title:SetWidth(FRAME_W - 60); frame.plan.title:SetJustifyH("LEFT")
    frame.plan.rows = {}
    for i = 1, PLAN_ROWS do
        local r = {}
        r.head = text(frame.plan, FONT_BODY, 12, C.bone)
        r.head:SetPoint("TOPLEFT", frame.plan, "TOPLEFT", X.slot, -22 - (i - 1) * PLAN_ROW_H)
        r.head:SetWidth(FRAME_W - 60); r.head:SetJustifyH("LEFT")
        r.items = text(frame.plan, FONT_BODY, 10, C.label)
        r.items:SetPoint("TOPLEFT", r.head, "BOTTOMLEFT", 0, -3)
        r.items:SetWidth(FRAME_W - 60); r.items:SetJustifyH("LEFT")
        r.items:SetWordWrap(false)
        frame.plan.rows[i] = r
    end
    frame.plan:Hide()

    -- Rows, grouped ----------------------------------------------------------
    -- Built once, in paperdoll order, and re-pointed at refresh time when the
    -- window is sorted by upgrade instead. The row frames are reused and only
    -- `slotName` moves between them, so sorting never creates a frame.
    frame.rows = {}
    frame.groupHeads = {}
    local y, alt = -HEADER_H, false
    for _, group in ipairs(GROUPS) do
        frame.groupHeads[#frame.groupHeads + 1] = makeGroupHeader(frame, y, group.title)
        y = y - GROUP_H
        for _, name in ipairs(group.slots) do
            local row = makeRow(frame, y)
            row.slotName = name
            row.homeSlot = name   -- where this row sits with grouping on
            row.homeY = y
            row.band:SetAlpha(alt and 0.5 or 0)
            alt = not alt
            frame.rows[#frame.rows + 1] = row
            y = y - ROW_H
        end
    end
    frame.groupedH = -y + 12
    -- Sorted by upgrade there are no groups, so the three headers come out and
    -- the window loses exactly their height.
    frame.flatH = frame.groupedH - (#frame.groupHeads * GROUP_H)
    frame:SetSize(FRAME_W, frame.groupedH)

    -- The 70% line: above it is where most of the total gain is. Created here,
    -- shown only while sorting by upgrade.
    frame.cutLine = fill(frame, C.ember)
    frame.cutLine:SetHeight(1)
    frame.cutLine:Hide()
    -- No label beside the line. It used to carry "70% of the upgrade — from here
    -- up", right-aligned above the line, which landed exactly on the
    -- percentage of the row above it: the two overlapped and neither could be
    -- read. The sentence at the top of the window says the same thing and is
    -- always on screen whenever this line is, so the line is left to do the one
    -- thing a line does -- mark the place.

    frame.detail = makeDetail(frame)

    -- One quiet line at the foot: what a click does right now.
    frame.hint = text(frame, FONT_BODY, 9, C.mist, "OVERLAY")
    frame.hint:SetPoint("BOTTOM", frame, "BOTTOM", 0, 6)
    frame.hint:SetWidth(FRAME_W - 40); frame.hint:SetJustifyH("CENTER")
    -- The auction house changes what a click does; neither event is confirmed
    -- for this client, so they are registered inside pcall.
    pcall(frame.RegisterEvent, frame, "AUCTION_HOUSE_SHOW")
    pcall(frame.RegisterEvent, frame, "AUCTION_HOUSE_CLOSED")

    frame:Hide()
end

------------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------------
local function displayNumber(n)
    if math.abs(n - math.floor(n + 0.5)) < 0.01 then return tostring(math.floor(n + 0.5)) end
    return string.format("%.1f", n)
end

local function detailStats(best, equipped)
    local rec = {}
    for k, v in pairs(best.item.st or {}) do rec[k] = v end
    local _, _, variant = S.BestVariant(best.item, ns.weights)
    for k, v in pairs(variant or {}) do rec[k] = (rec[k] or 0) + v end

    local changes = {}
    for _, key in ipairs(ns.STAT_KEYS or {}) do
        local delta = (rec[key] or 0) - (equipped and equipped.st and equipped.st[key] or 0)
        if math.abs(delta) > 0.001 then
            local sign = delta > 0 and "+" or ""
            local color = delta > 0 and HEX.zang or "ffff8080"
            changes[#changes + 1] = "|c" .. color .. sign .. displayNumber(delta) .. " "
                                  .. (ns.StatLabel and ns.StatLabel(key) or key) .. "|r"
        end
    end
    if #changes == 0 then return L["No direct stat changes."] end
    local shown = {}
    for i = 1, math.min(6, #changes) do shown[i] = changes[i] end
    local tail = #changes > 6 and ("  ·  +" .. (#changes - 6) .. " " .. L["more"]) or ""
    return table.concat(shown, "  ·  ") .. tail
end

local function detailSource(item, filters)
    local lines = srcLines(item)
    local route, gate = S.AllowedRoute(item, filters)
    local skipAccess = S.AccessExempt and S.AccessExempt(item, nil, filters)
    local bestVisibleGate
    for _, source in ipairs(item.src or {}) do
        if S.SourceAllowed(source, filters, skipAccess) then
            local access = S.RouteAccess(source, filters)
            if not bestVisibleGate or access < bestVisibleGate then
                bestVisibleGate = access
            end
        end
    end
    if bestVisibleGate == nil or (gate and gate < bestVisibleGate) then
        if route then
            local kind = route.t == "quest" and L["Quest"] or route.t == "vendor" and L["Vendor"]
                         or route.t == "craft" and L["Crafting"]
                         or route.ct == "dungeon" and L["Dungeon"]
                         or route.ct == "raid" and L["Raid"] or L["Recorded source"]
            local difficulty = route.diff == 1 and (" " .. L["normal"])
                               or route.diff == 2 and (" " .. L["heroic"]) or ""
            return L["Source:"] .. " " .. kind .. difficulty
                   .. (gate and gate > 0 and (" · " .. L["access from level %s"]:format(gate)) or "")
                   .. " · " .. L["source with no visible name"]
                   .. (ns.Access and ns.Access.RouteNote(route)
                       and (" · " .. ns.Access.RouteNote(route)) or "")
                   .. (ns.Access and ns.Access.SeasonNote(route)
                       and (" · " .. ns.Access.SeasonNote(route)) or "")
        end
    end
    if #lines == 0 then return L["Source: no data."] end
    -- SrcLines puts the unique-equipped warning before provenance. Skip that
    -- warning here: this line answers where the recommendation comes from.
    local firstSource = item.uniq and 2 or 1
    local raw = lines[firstSource] or lines[1]
    local first = raw:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    -- Keep source types such as Quest and Vendor, but avoid two labels for drops.
    -- The words come from the same L entries srcLines used, so the stripping
    -- works in whichever language the client runs.
    local function pat(s) return (s:gsub("%p", "%%%0")) end
    first = first:gsub("^" .. pat(L["Drops from:"]) .. " ", ""):gsub(" — ", " · ")
                 :gsub("%s+" .. pat(L["level"]) .. " (%d+)", " · " .. L["level"] .. " %1")
    local remaining = #lines - firstSource
    local more = remaining > 0 and ("  ·  " .. L["%d more source(s) in the tooltip"]:format(remaining)) or ""
    return L["Source:"] .. " " .. first .. more
end

local function detailReason(slotName, best, filters)
    if best.fallback == "wandDps" then
        return L["Why: the wand with the highest DPS available; its effects are not priced."]
    end
    local detail = S.Explain(best.item, ns.weights, S.SLOTS[slotName].slot)
    local reason = L["Why: highest score with your weights"]
    for _, part in ipairs(detail and detail.parts or {}) do
        -- The stats of the ideal gems are not the item's own: they are named
        -- apart below, so "stands out" never credits the item with a gem's stat.
        if part.points > 0 and part.origin ~= "socket" then
            local label = ns.StatLabel and ns.StatLabel(part.key) or part.key
            reason = reason .. L["; %s stands out (%+.0f points)"]:format(label, part.points)
            break
        end
    end
    if detail and (detail.socketPoints or 0) >= 0.5 then
        reason = reason .. (" · " .. L["ideal gems %+.0f"]:format(detail.socketPoints))
    end
    local item = best.item
    if item.sg or item.pg then
        if filters.noRandom then
            reason = reason .. " · " .. L["roll ignored"]
        elseif select(4, S.BestVariant(item, ns.weights)) then
            reason = reason .. " · " .. L["best roll assumed"]
        end
    end
    return reason
end

-- M-11. The lifetime sweep scores every future level. Where the client has a
-- clock and C_Timer, it runs in slices of at most LIFETIME_BUDGET_MS and the
-- detail says "calculating…" until it finishes; otherwise it runs at once.
local LIFETIME_BUDGET_MS = 16
local function clock()
    if type(debugprofilestop) == "function" then return debugprofilestop() end
end
ns.Clock = clock

local function runJob(job, budget)
    local t0 = clock()
    if not t0 then S.LifetimeStep(job, 100) return true end
    repeat
        S.LifetimeStep(job, 1)
    until job.done or clock() - t0 >= budget
    return job.done
end

local function detailLifetime(slotName, best, level, filters)
    if level >= 70 then return L["Lifetime: level 70; there are no later levels."] end
    local job = S.LifetimeJob(slotName, best.id, level, ns.weights, ns.playerClass,
                              ns.playerLevel, filters)
    if not job.done then
        if C_Timer and C_Timer.After and clock() then
            if not runJob(job, LIFETIME_BUDGET_MS) then
                UI.lifetimeSlices = (UI.lifetimeSlices or 0) + 1
                local pending = UI.lifetimePending
                if not (pending and pending.key == job.key) then
                    UI.lifetimePending = job
                    local function continue()
                        if UI.lifetimePending ~= job then return end
                        if runJob(job, LIFETIME_BUDGET_MS) then
                            UI.lifetimePending = nil
                            if frame and frame:IsShown() then UI:Refresh() end
                        else
                            UI.lifetimeSlices = (UI.lifetimeSlices or 0) + 1
                            C_Timer.After(0, continue)
                        end
                    end
                    C_Timer.After(0, continue)
                end
                return L["Lifetime: calculating…"]
            end
        else
            S.LifetimeStep(job, 100)
        end
    end
    local changed, current = job.level, job.current
    if not current then return L["Lifetime: recompute the recommendation."] end
    if changed then
        return L["Lifetime: first recommendation change at level %d."]:format(changed)
    end
    return L["Lifetime: stays first until level 70."]
end

-- The line under the detail: the best alternative without a random roll and
-- what choosing it gives up against the recommendation. Returns the three
-- pieces the detail draws (lead, item name, tail) and the item to hover. The
-- amounts are always "against the recommendation"; "does not improve your gear" is the
-- only mention of what is worn.
local MINUS = "-"   -- ASCII: FRIZQT__ may lack U+2212 and draw a box

local function signed(value, unit)
    local n = math.floor(math.abs(value) + 0.5)
    if n == 0 then return "0" .. unit end
    return (value < 0 and MINUS or "+") .. n .. unit
end

local function detailAlternative(slotName, res)
    local lead = {
        same = L["The recommendation already has fixed stats"],
        none = L["No fixed alternative with these filters"],
        pending = L["Loading equipment…"],
    }
    if res.state ~= "ok" then
        return lead[res.state] or lead.none, "", "", nil
    end
    local alt = res.alt
    local qc = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[alt.item.q or 1]
    local name = (qc and qc.hex or "|cffffffff") .. ns.LocalName(alt.id, alt.item) .. "|r"
    local points = res.diff and math.floor(math.abs(res.diff) + 0.5) or 0
    local amount = signed(res.diff, "") .. " " .. (points == 1 and L["point"] or L["points"])
    if res.pct then amount = amount .. ", " .. signed(res.pct * 100, "%") end
    local tail = "(" .. (res.altBothHands and (L["two-hand"] .. ", ") or "") .. amount
                 .. " " .. L["vs the recommendation"] .. ")"
    if res.noUpgrade then tail = tail .. " · " .. L["does not improve your gear"] end
    return L["No random roll:"], name, tail, alt
end

-- Reputation or a one-time quest changed (Access.lua). The sweep in progress
-- describes the old character: dropping it makes its callback do nothing. The
-- repaint comes once, from AccessRefresh, after the burst of events.
function UI.OnAccessChanged()
    UI.lifetimePending = nil
end

function UI.AccessRefresh()
    if frame and frame:IsShown() then UI:Refresh() end
end

-- A new price was remembered: repaint, once per burst of auction updates.
function UI.OnPricesChanged()
    if not (frame and frame:IsShown()) or frame.__lbisPriceRefresh then return end
    frame.__lbisPriceRefresh = true
    afterDelay(1, function()
        frame.__lbisPriceRefresh = nil
        if frame:IsShown() then UI:Refresh() end
    end)
end

-- /lbis perf: measured in the client, with debugprofilestop, so the budget
-- (16 ms for a refresh) is compared with the real thing rather than a guess.
function UI.Perf()
    local c = clock()
    if not c then ns.Print(L["This client does not expose debugprofilestop."]) return end
    local function timed(fn)
        local t0 = clock()
        fn()
        return clock() - t0
    end
    local tl, filters = ns:TargetLevel(), LevelBiSCharDB.settings.filters
    local result = {}
    result.rank = timed(function()
        S.RankAll(tl, ns.weights, ns.playerClass, ns.playerLevel, filters, 1)
    end)
    result.refresh = frame and timed(function() UI:Refresh() end) or nil
    result.lifetime = timed(function()
        S.ClearLifetimeCache()
        local best = S.BestForSlot("head", tl, ns.weights, ns.playerClass, ns.playerLevel, filters)
        if best and tl < 70 then
            S.FirstReplacementLevel("head", best.id, tl, ns.weights, ns.playerClass,
                                    ns.playerLevel, filters)
        end
    end)
    result.plan = timed(function()
        S.DungeonPlan(tl, ns.weights, ns.playerClass, ns.playerLevel, filters, 5, 8)
    end)
    UI.perf = result
    local function line(name, ms, budget)
        local mark = (not budget or ms <= budget) and "|cff40ff40" or "|cffff6060"
        ns.Print(("  %-22s %s%.1f ms|r%s"):format(name, mark, ms,
            budget and L["  (budget %d)"]:format(budget) or ""))
    end
    ns.Print(L["Performance measured on this client:"])
    line(L["rank 17 slots"], result.rank, 16)
    if result.refresh then line(L["refresh the window"], result.refresh, 16) end
    line(L["lifetime (sweep)"], result.lifetime, nil)
    line(L["dungeon plan"], result.plan, nil)
    ns.Print(L["  lifetime is spread over 16 ms steps if it does not fit in one"])
end
ns.ExtraCmd = ns.ExtraCmd or {}
ns.ExtraCmd.perf = function() UI.Perf() end

-- Where the header ends, for the current fold state. Every y below the filter
-- rows is derived from the summary line, so open and closed cannot drift.
local function summaryY()
    return LevelBiSCharDB.settings.filtersOpen and SUMMARY_Y_OPEN or SUMMARY_Y_CLOSED
end
local function headerH() return headerFor(summaryY()) end

function UI.LayoutHeader()
    local open = LevelBiSCharDB.settings.filtersOpen and true or false
    local sy = summaryY()
    for _, cb in ipairs(frame.checks or {}) do
        if open then cb:Show() else cb:Hide() end
    end
    for _, b in ipairs(frame.cycles or {}) do
        if open then b:Show() else b:Hide() end
    end
    frame.filtersBtn:ClearAllPoints()
    frame.filtersBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, sy + 4)
    frame.filtersBtn:SetText(open and L["Hide filters"] or L["Show filters"])
    frame.filterSummary:ClearAllPoints()
    frame.filterSummary:SetPoint("TOPLEFT", frame, "TOPLEFT", 130, sy)
    frame.resetFilters:ClearAllPoints()
    frame.resetFilters:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, sy + 6)
    for _, h in ipairs(frame.colHeads) do
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", frame, "TOPLEFT", h.dx, sy - HEAD_DY)
    end
    frame.rule:ClearAllPoints()
    frame.rule:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, sy - RULE_DY)
    frame.rule:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, sy - RULE_DY)
    frame.plan:ClearAllPoints()
    frame.plan:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X, -(headerH() - PLAN_DY))
    UI.lastHeaderH = headerH()
end

-- What each click does, which is otherwise only in the author's head. The
-- first sentence changes with the auction house, since that is what moves it.
function UI.HintText()
    if UI.tab == "plan" or UI.tab == "cons" then return "" end
    local first = UI.AuctionOpen()
        and (L["Click: search the Auction House"] .. "  \194\183  " .. L["Alt-click: details"])
        or L["Click: details"]
    return first .. "  \194\183  " .. L["Shift-click: link in chat"]
           .. "  \194\183  " .. L["Ctrl-click: dressing room"]
end

function UI.RefreshHint()
    if not (frame and frame.hint) then return end
    frame.hint:SetText(UI.HintText())
end

function UI:SetTab(key)
    self.tab = (key == "plan" or key == "cons") and key or "gear"
    self:Refresh()
end

local function hideGrid()
    for _, row in ipairs(frame.rows) do row:Hide() end
    for _, g in ipairs(frame.groupHeads) do g:Hide() end
    for _, h in ipairs(frame.colHeads) do h:Hide() end
    frame.rule:Hide(); frame.detail:Hide(); frame.cutLine:Hide()
    UI.lastDetail = nil
    frame.plan:Show()
end

-- M-8. The third tab: what to bring, priced with your own weights.
function UI:RefreshConsumables(tl)
    hideGrid()
    local lines = ns.ConsumableLines(tl)
    UI.lastConsumables = lines
    local lede = (#lines > 0)
        and L["For level %d, with your weights: %s."]:format(tl, (lines[1].head:gsub("^[^:]*: ", "")))
        or L["No consumable scores with your weights at this level."]
    frame.lede:SetText(lede)
    UI.lastLede = lede
    frame.plan.title:SetText(L["The best for your spec and target level. Weights score the effect; potions, what they restore."])
    local texts = {}
    for i = 1, PLAN_ROWS do
        local r, l = frame.plan.rows[i], lines[i]
        r.head:SetText(l and l.head or "")
        r.items:SetText(l and l.detail or "")
        texts[i] = r.head:GetText()
    end
    UI.lastPlanLines = texts
    frame:SetHeight(headerH() - PLAN_DY + PLAN_ROWS * PLAN_ROW_H + 40 + 12)
    self:RefreshProfiles()
end

-- M-4. The second tab: where to go, offered as a suggestion.
function UI:RefreshPlan(tl, filters)
    hideGrid()
    local plan, total = S.DungeonPlan(tl, ns.weights, ns.playerClass, ns.playerLevel,
                                      filters, 5, PLAN_ROWS)
    UI.lastPlan = plan
    local lines = {}
    local lede
    if not plan then
        lede = L["Loading equipment… The suggestion will appear when the data is complete."]
        plan = {}
    elseif #plan == 0 then
        lede = L["With these filters no dungeon would upgrade you at this level."]
    else
        local first = plan[1]
        lede = L["You could run %s: %d %s, %.0f%% of your possible upgrade."]
            :format(ns.InstanceLabel(first.inst), first.slots, first.slots == 1 and L["slot"] or L["slots"], first.share)
    end
    frame.lede:SetText(lede)
    UI.lastLede = lede
    frame.plan.title:SetText(L["Which dungeon should I run? Level %d suggestions from your filters. Each sums the best it drops per slot."]:format(tl))
    for i = 1, PLAN_ROWS do
        local r, p = frame.plan.rows[i], plan[i]
        if p then
            local parts = {}
            for j = 1, math.min(3, #p.items) do
                local it = p.items[j]
                local item = ns.db[it.id]
                local variantId = item and select(4, S.BestVariant(item, ns.weights))
                parts[#parts + 1] = ("%s: %s"):format(SLOT_LABEL[it.slot] or it.slot,
                    (ns.LocalName(it.id, item, variantId)))
            end
            local more = #p.items > 3 and L["  ·  +%d more"]:format(#p.items - 3) or ""
            r.head:SetText(L["%d. %s  \194\183  %d %s  \194\183  %.0f%% of your upgrade"]:format(
                i, ns.InstanceLabel(p.inst), p.slots, p.slots == 1 and L["slot"] or L["slots"], p.share))
            r.items:SetText(table.concat(parts, "  \194\183  ") .. more)
            r.head:Show(); r.items:Show()
        else
            r.head:SetText(""); r.items:SetText("")
        end
        lines[i] = r.head:GetText()
    end
    UI.lastPlanLines = lines
    frame:SetHeight(headerH() - PLAN_DY + PLAN_ROWS * PLAN_ROW_H + 40 + 12)
    self:RefreshProfiles()
end

function UI:ToggleDetail(slotName)
    if self.expandedSlot == slotName then
        self.expandedSlot = nil
    else
        self.expandedSlot = slotName
    end
    self:Refresh()
end

function UI:Refresh()
    if not frame then return end
    UI.LayoutHeader()
    local tl = ns:TargetLevel()
    local filters = LevelBiSCharDB.settings.filters

    frame.who:SetText(("%s %s  \194\183  %s"):format(
        ns.playerRaceName or "?", ns.playerClassName or "?", ns.SpecLabel(ns.activeSpec)))
    frame.lvlLabel:SetText(LevelBiSCharDB.targetLevel and L["Level %d"]:format(tl)
        or L["Level %d (yours)"]:format(tl))
    UIDropDownMenu_SetText(frame.specDD, ns.SpecLabel(ns.activeSpec))
    for _, cb in ipairs(frame.checks or {}) do cb:sync() end
    for _, b in ipairs(frame.cycles or {}) do b:sync() end
    UI.lastFilterSummary = ns.FilterSummary(filters)
    frame.difficultyBtn:SetText(filters.dungeonMode == "normal" and L["Dungeons: normal"]
        or filters.dungeonMode == "heroic" and L["Dungeons: heroic"] or L["Dungeons: all"])
    frame.filterSummary:SetText(UI.lastFilterSummary)
    frame.phaseBtn:SetText(L["Phase: %s"]:format(filters.maxPhase or S.CURRENT_PHASE))
    frame.goalBtn:SetText(LevelBiSCharDB.settings.goal == "endgame"
        and L["Goal: level 70"] or L["Goal: leveling"])

    for key, b in pairs(frame.tabs or {}) do
        b:SetSelected(key == (UI.tab or "gear"))
    end
    UI.RefreshHint()
    if UI.tab == "plan" then return self:RefreshPlan(tl, filters) end
    if UI.tab == "cons" then return self:RefreshConsumables(tl) end
    frame.plan:Hide()
    for _, row in ipairs(frame.rows) do row:Show() end
    for _, h in ipairs(frame.colHeads) do h:Show() end
    frame.rule:Show()

    -- Ranked once for the whole window rather than per row: RankAll is what
    -- resolves the paired slots together, so a unique ring cannot win both
    -- finger slots.
    local ranked = S.RankAll(tl, ns.weights, ns.playerClass, ns.playerLevel,
                             filters, 1)

    -- Pass 1: score every slot. Nothing can be drawn until every delta is
    -- known, because the order of the window may depend on all of them.
    local data, order, totalGain, hasFallback = {}, {}, 0, false
    local hasPending = false
    for _, row in ipairs(frame.rows) do
        local name = row.homeSlot
        local def = S.SLOTS[name]
        local eqScore, eqId, eqItem, _, state = S.EquippedScore(def.slot, ns.weights)
        hasPending = hasPending or state == "pending"
        local best = ranked[name] and ranked[name][1]
        local abs, pct = 0, nil
        local fallbackEq
        if best and best.fallback == "wandDps" and state ~= "pending" then
            fallbackEq = S.EquippedWandDps(def.slot)
            _, pct = S.Delta(best.fallbackScore, fallbackEq)
            hasFallback = true
        elseif best and (state == "ready" or state == "empty") then
            abs, pct = S.Delta(best.score, eqScore or 0)
        end
        if abs < 0 then abs = 0 end   -- a downgrade is not a gain, it is zero
        data[name] = { def = def, eqScore = eqScore, eqId = eqId, eqItem = eqItem,
                       fallbackEq = fallbackEq, state = state,
                       best = best, abs = abs, pct = pct }
        order[#order + 1] = name
        totalGain = totalGain + abs
    end

    -- Pass 2: decide the order. Sorting is by the absolute score gained, not by
    -- the percentage the column shows: an empty slot has no percentage, and a
    -- big percentage over a bad item can still be a small gain.
    local byGold = LevelBiSCharDB.settings.sortByGold and true or false
    local sorted = (LevelBiSCharDB.settings.sortByDelta or byGold) and true or false
    local homeIdx = {}
    for i, n in ipairs(order) do homeIdx[n] = i end
    if sorted then
        -- Gain per gold (CS-5): only a price you have seen can be divided by.
        -- A slot without one goes after every priced slot, by gain, never
        -- ranked on an invented price.
        -- The price is the one of the exact roll the row recommends
        -- (ns.VariantIdentity); a roll never seen has no price and goes with
        -- the unpriced, however much another roll of the same item costs.
        -- Resolved once per slot, not once per comparison.
        local priced = {}
        local function perGold(name)
            local d = data[name]
            if priced[name] == nil then
                local copper
                if byGold and d.best and ns.Prices then
                    local pid, roll = ns.VariantIdentity(d.best.id, d.best.item)
                    copper = pid and ns.Prices.Get(pid, roll)
                end
                priced[name] = copper or false
            end
            local copper = priced[name]
            if byGold and copper and copper > 0 and d.abs > 0 then
                return d.abs / copper
            end
            return nil
        end
        table.sort(order, function(a, b)
            if byGold then
                local ga, gb = perGold(a), perGold(b)
                if ga and gb and ga ~= gb then return ga > gb end
                if (ga ~= nil) ~= (gb ~= nil) then return ga ~= nil end
            end
            local da, db = data[a].abs, data[b].abs
            if da ~= db then return da > db end
            return homeIdx[a] < homeIdx[b]  -- table.sort is not stable
        end)
        UI.lastGoldOrder = byGold and { unpack(order) } or nil
    end

    -- Where the top of the list stops being worth the gold: the last row inside
    -- the first 70% of everything there is to gain.
    local cutAfter
    if sorted and not byGold and totalGain > 0 and not hasPending then
        local acc, target = 0, totalGain * 0.70
        for i, name in ipairs(order) do
            acc = acc + data[name].abs
            if acc >= target then cutAfter = i break end
        end
    end


    local topName
    for _, name in ipairs(order) do
        if not topName or data[name].abs > data[topName].abs then topName = name end
    end
    -- By gold, the list's first row is the answer, whatever its absolute gain.
    if byGold and order[1] and data[order[1]].abs > 0 then topName = order[1] end
    UI.lastPriority = not hasPending and totalGain > 0 and topName or nil
    local function rowHeight(name)
        return name == UI.lastPriority and PRIORITY_H or ROW_H
    end

    -- Lay out rows again because one optional detail panel adds height between
    -- two rows. Group headings participate in the same flow, so opening a row
    -- can never draw through the next heading.
    local positions, detailY = {}, nil
    local layoutY = -headerH()
    if sorted then
        for _, name in ipairs(order) do
            positions[name] = layoutY
            layoutY = layoutY - rowHeight(name)
            if UI.expandedSlot == name and data[name].best then
                detailY = layoutY
                layoutY = layoutY - DETAIL_H
            end
        end
    else
        local gi = 0
        for _, group in ipairs(GROUPS) do
            gi = gi + 1
            local head = frame.groupHeads[gi]
            head:ClearAllPoints()
            head:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X, layoutY)
            layoutY = layoutY - GROUP_H
            for _, name in ipairs(group.slots) do
                positions[name] = layoutY
                layoutY = layoutY - rowHeight(name)
                if UI.expandedSlot == name and data[name].best then
                    detailY = layoutY
                    layoutY = layoutY - DETAIL_H
                end
            end
        end
    end

    for _, g in ipairs(frame.groupHeads) do
        if sorted then g:Hide() else g:Show() end
    end

    -- What the window actually drew, kept so the test harness can assert the
    -- order without reaching into a local frame. Plain values only.
    local gains = {}
    for name, d in pairs(data) do gains[name] = d.abs end
    UI.lastOrder, UI.lastGain, UI.lastCut = order, gains, cutAfter

    -- Pass 3: paint. Sorted, the rows pack from the top with no group headers;
    -- otherwise every row goes back to the y it was built at.
    for i, name in ipairs(order) do
        local row = frame.rows[i]
        local d = data[name]
        row.slotName = name
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X, positions[name])
        row:SetHeight(rowHeight(name))
        row.slot:SetText(SLOT_LABEL[name] or name)

        local priority = name == UI.lastPriority
        if priority then row.priority:Show() else row.priority:Hide() end
        row.slot:ClearAllPoints()
        row.slot:SetPoint("LEFT", row, "LEFT", X.slot, priority and 7 or 0)
        for _, line in ipairs(row.priorityBorder) do
            if priority then line:Show() else line:Hide() end
        end

        local eqScore, best = d.eqScore, d.best
        local eqTex = GetInventoryItemTexture("player", d.def.slot)
        row.eqIcon.slotID = d.def.slot
        row.eqIcon.tex:SetTexture(eqTex or "Interface\\PaperDoll\\UI-Backpack-EmptySlot")
        row.eqIcon.tex:SetDesaturated(eqTex == nil)
        if best and best.fallback == "wandDps" then
            row.eqScore:SetText((d.fallbackEq or 0) > 0
                and string.format("%.1f DPS", d.fallbackEq) or "\226\128\148")
        else
            row.eqScore:SetText(eqScore and string.format("%.0f", eqScore) or "\226\128\148")
        end

        if best then
            local item = best.item
            row.recIcon.itemId = best.id
            row.recIcon.slotName = name
            row.recHit.itemId = best.id
            row.recHit.slotName = name
            row.recIcon.tex:SetTexture(iconFor(best.id))
            row.recIcon.tex:SetDesaturated(false)
            local qc = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[item.q or 1]
            -- The roll is part of the name: "Warmaul Epaulets" alone names
            -- twenty-five different shoulders, and only one of them is the
            -- recommendation. The client is asked first so the row reads in
            -- the game's own language; if it cannot spell the roll, the
            -- English suffix is appended so the row still says which one.
            local suffix, variantId
            if item.sg or item.pg then
                local _, name, _, vid = S.BestVariant(item, ns.weights)
                suffix, variantId = name, vid
            end
            local label, rolled = ns.LocalName(best.id, item, variantId)
            if suffix and not rolled then label = label .. " " .. suffix end
            row.recName:SetText((qc and qc.hex or "|cffffffff") .. label .. "|r")
            row.recName:SetWidth(X.nameW)
            row.tag:SetText(sourceTag(item, best.id, filters) or "")

            local fallback = best.fallback == "wandDps"
            local eq = fallback and (d.fallbackEq or 0) or (eqScore or 0)
            local rec = fallback and best.fallbackScore or best.score
            setTrack(row.track, rec > 0 and (eq / rec) or 1, true)

            local pct = d.pct
            if d.state == "pending" or (d.state == "unpriceable" and not fallback) then
                setTrack(row.track, 0, false)
                row.delta:SetText(d.state == "pending" and L["loading"] or L["not compared"])
                row.delta:SetTextColor(C.label[1], C.label[2], C.label[3])
            elseif eq <= 0 then
                row.delta:SetText(L["new"])
                row.delta:SetTextColor(C.zang[1], C.zang[2], C.zang[3])
            elseif pct and pct > 0.5 then
                row.delta:SetText(string.format("+%.0f%%", pct))
                row.delta:SetTextColor(C.zang[1], C.zang[2], C.zang[3])
            else
                row.delta:SetText(L["up to date"])
                row.delta:SetTextColor(C.label[1], C.label[2], C.label[3])
            end
        else
            row.recIcon.itemId = nil
            row.recHit.itemId = nil
            row.recHit.slotName = name
            row.recIcon.tex:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
            row.recIcon.tex:SetDesaturated(true)
            -- An empty row says what to do about it. "No matches" is
            -- the search talking about itself; the filter that emptied the row
            -- is the useful thing to name.
            -- The off hand is a special case of empty: it is not that
            -- nothing fits, it is that the recommended weapon needs both
            -- hands. Saying "try fewer filters" there would send you
            -- looking for something that cannot exist.
            local twoHanded = name == "offhand" and ranked.mainhand
                              and ranked.mainhand[1]
                              and ranked.mainhand[1].item.slot == "INVTYPE_2HWEAPON"
            -- The third reason a row is empty: everything in the slot is
            -- there for an effect, not for stats. A paladin's librams and a
            -- druid's idols are the entire slot. "Try fewer filters"
            -- would be advice that cannot work.
            local unpriceable = not twoHanded and S.SlotIsUnpriceable
                                and S.SlotIsUnpriceable(name, tl, ns.weights,
                                    ns.playerClass, ns.playerLevel, filters)
            local emptyText = L["Nothing better; try fewer filters"]
            if twoHanded then
                emptyText = L["Taken by the two-hand weapon"]
            elseif unpriceable then
                emptyText = L["Here the value is an effect, not stats"]
            elseif filters.onlyAH and (filters.onlyInstances or filters.onlyQuests) then
                emptyText = L["Nothing buyable from these sources; check filters"]
            elseif filters.onlyAH then
                emptyText = L["Nothing buyable at this level"]
            elseif filters.onlyInstances and filters.onlyQuests then
                emptyText = L["Nothing in instances or quests yet"]
            elseif filters.onlyInstances then
                emptyText = L["Nothing in instances yet"]
            elseif filters.onlyQuests then
                emptyText = L["Nothing in quests yet"]
            end
            row.recName:SetText("|c" .. HEX.label .. emptyText .. "|r")
            row.recName:SetWidth(X.nameWide)
            row.tag:SetText("")
            setTrack(row.track, 0, false)
            row.delta:SetText("")
        end
    end

    frame:SetHeight(-layoutY + 12 + HINT_H)
    UI.RefreshHint()

    if detailY and UI.expandedSlot then
        local d = data[UI.expandedSlot]
        local best, link = d.best, GetInventoryItemLink("player", d.def.slot)
        local equippedName = L["Empty slot"]
        if link then
            equippedName = GetItemInfo(link) or L["Loading equipment…"]
        end
        local recName = ns.LocalName(best.id, best.item, select(4, S.BestVariant(best.item, ns.weights)))
        frame.detail.items:SetText(L["Replaces: %s"]:format(equippedName))
        local statsText = L["Changes: %s"]:format(detailStats(best, d.eqItem))
        if d.state == "pending" then statsText = L["Loading equipment stats…"] end
        local sourceText = detailSource(best.item, filters)
        local pid, roll = ns.VariantIdentity(best.id, best.item)
        local priceLine = pid and ns.Prices and ns.Prices.Text(pid, roll)
        if priceLine then sourceText = sourceText .. " · " .. priceLine end
        local reasonText = detailReason(UI.expandedSlot, best, filters)
        local lifetimeText = detailLifetime(UI.expandedSlot, best, tl, filters)
        frame.detail.stats:SetText(statsText)
        frame.detail.source:SetText(sourceText)
        frame.detail.reason:SetText(reasonText)
        frame.detail.lifetime:SetText(lifetimeText)
        -- Computed when the detail opens and kept while it is repainted (the
        -- engine's cache drops it when profile, filters, level or gear change).
        local alt = S.CachedFixedAlternative(UI.expandedSlot, tl, ns.weights,
                        ns.playerClass, ns.playerLevel, filters)
        local altLead, altName, altTail, altEntry = detailAlternative(UI.expandedSlot, alt)
        frame.detail.altLead:SetText(altLead)
        frame.detail.altName:SetText(altName)
        frame.detail.altTail:SetText(altTail)
        local hit = frame.detail.altHit
        if altEntry then
            hit.itemId = altEntry.id
            hit.slotName = alt.altBothHands and "mainhand" or UI.expandedSlot
            hit:Show()
        else
            hit.itemId, hit.slotName = nil, nil
            hit:Hide()
        end
        frame.detail:ClearAllPoints()
        frame.detail:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X + 4, detailY)
        frame.detail:Show()
        UI.lastDetail = { slot = UI.expandedSlot, current = equippedName,
                          recommended = recName,
                          stats = statsText, source = sourceText,
                          reason = reasonText, lifetime = lifetimeText,
                          alternative = (altLead .. " " .. altName .. " " .. altTail)
                              :gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("%s+$", ""):gsub("  +", " "),
                          alternativeState = alt.state, alternativeId = altEntry and altEntry.id }
    else
        frame.detail:Hide()
        UI.lastDetail = nil
    end

    if cutAfter then
        -- Keep the separator below the cutoff row, including its open detail.
        local cutSlot = order[cutAfter]
        local cy = positions[cutSlot] - rowHeight(cutSlot)
        if detailY and UI.expandedSlot == cutSlot then cy = cy - DETAIL_H end
        frame.cutLine:ClearAllPoints()
        frame.cutLine:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, cy)
        frame.cutLine:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, cy)
        frame.cutLine:Show()
    else
        frame.cutLine:Hide()
    end

    -- One line that answers the window, so the grid confirms it instead of
    -- having to be decoded. It names the slot the list puts first, and for the
    -- same reason: both go by the absolute gain. A lede that disagreed with row
    -- one would read as a bug.
    -- The same word the grid uses, spelled the same way: the sentence and the
    -- row it points at have to be recognisably the same thing.
    local function slotWord(name) return SLOT_LABEL[name] or name end

    local lede
    if hasPending then
        lede = L["Loading equipment… The priority will update when the data is complete."]
    elseif totalGain <= 0 and hasFallback then
        lede = L["No weighted upgrade; wands are sorted by DPS."]
    elseif totalGain <= 0 then
        lede = L["You are up to date. Raise the target level to see what comes next."]
    elseif byGold then
        lede = L["Sorted by upgrade per gold seen: the best return per coin is on top."]
    elseif sorted and cutAfter and cutAfter <= 3 then
        local list = slotWord(order[1])
        for i = 2, cutAfter do
            list = list .. ((i == cutAfter) and L[" and "] or ", ") .. slotWord(order[i])
        end
        lede = L["Start with %s: that is where 70%% of the upgrade is."]:format(list)
    elseif sorted and cutAfter then
        lede = L["The first %d slots are 70%% of the upgrade."]:format(cutAfter)
    else
        -- No percentage here on purpose. This names the slot that gains the
        -- most in absolute terms, and the "GAIN" column shows percentages: a
        -- number in the sentence invited the reader to compare the two and
        -- conclude the window was contradicting itself, because the biggest
        -- gain and the biggest percentage are usually different rows.
        local pct = data[topName].pct
        lede = (pct and pct > 0.5)
            and L["Start with %s: it gains the most."]:format(slotWord(topName))
            or  L["Start with %s: it is empty."]:format(slotWord(topName))
    end
    frame.lede:SetText(lede)
    UI.lastLede = lede

    self:RefreshProfiles()
    if ns.bindingChanged then
        ns.bindingChanged = nil
        if C_Timer and C_Timer.After and not frame.__lbisNameRefresh then
            frame.__lbisNameRefresh = true
            C_Timer.After(0.5, function()
                frame.__lbisNameRefresh = nil
                if frame:IsShown() then UI:Refresh() end
            end)
        end
    end
end

-- Keep the editor in step: changing spec or level from the main window changes
-- which profile is being edited.
function UI:RefreshProfiles()
    if ns.Profiles and ns.Profiles.Refresh then ns.Profiles:Refresh() end
end

function UI:Toggle()
    if not frame then build() end
    if frame:IsShown() then frame:Hide() else self:Refresh(); frame:Show() end
end

function UI:Show()
    if not frame then build() end
    self:Refresh(); frame:Show()
end

------------------------------------------------------------------------------
-- Minimap button
------------------------------------------------------------------------------
local function createMinimapButton()
    if LevelBiSMinimapButton then return end
    local sv = LevelBiSCharDB.settings
    sv.minimapAngle = sv.minimapAngle or 200

    local b = CreateFrame("Button", "LevelBiSMinimapButton", Minimap)
    b:SetSize(31, 31); b:SetFrameStrata("MEDIUM"); b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp")
    b:RegisterForDrag("LeftButton")

    local overlay = b:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53); overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(19, 19); icon:SetTexture("Interface\\Icons\\INV_Chest_Plate06")
    icon:SetPoint("CENTER", 1, 1); icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local function reposition()
        local a = math.rad(sv.minimapAngle)
        b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
    end
    reposition()

    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            sv.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            reposition()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnClick", function() UI:Toggle() end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("LevelBiS")
        GameTooltip:AddLine(L["|cffffffffClick:|r open   |cffffffffDrag:|r move"],
                            0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

------------------------------------------------------------------------------
-- Init at login (after Core has set player state)
------------------------------------------------------------------------------
local ef = CreateFrame("Frame")
ef:RegisterEvent("PLAYER_LOGIN")
ef:SetScript("OnEvent", function()
    createMinimapButton()
end)
