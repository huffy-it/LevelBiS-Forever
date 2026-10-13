-- Locale.lua ----------------------------------------------------------------
-- English is the source text: every visible string is written in English and
-- looked up through ns.L. A locale file (Locales/*.lua) fills ns.L only when
-- the client runs that language; a missing entry falls back to the English.
------------------------------------------------------------------------------
local ADDON, ns = ...

ns.LOCALE = (GetLocale and GetLocale()) or "enUS"
ns.L = setmetatable({}, { __index = function(_, key) return key end })
