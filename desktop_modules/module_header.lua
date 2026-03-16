-- module_header.lua — Simple UI
-- Header module: clock, date, quote of the day, or custom text.
-- The quote logic (previously in quoteswidget.lua) is integrated here
-- directly — no separate file needed.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local datetime        = require("datetime")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _               = require("gettext")

local UI   = require("ui")
local PAD  = UI.PAD
local PAD2 = UI.PAD2

local _CLR_TEXT_MID   = Blitbuffer.gray(0.45)
local _CLR_TEXT_QUOTE = Blitbuffer.COLOR_BLACK
local _CLR_TEXT_ATTR  = Blitbuffer.gray(0.40)

-- All pixel constants computed once at load time.
local CLOCK_H        = Screen:scaleBySize(54)
local CLOCK_FS       = Screen:scaleBySize(44)
local CLOCK_DIMEN    = Screen:scaleBySize(50)
local DATE_H         = Screen:scaleBySize(17)
local DATE_GAP       = Screen:scaleBySize(19)
local DATE_FS        = Screen:scaleBySize(11)
local CUSTOM_H       = Screen:scaleBySize(48)
local CUSTOM_FS      = Screen:scaleBySize(38)
local BOT_PAD_EXTRA  = Screen:scaleBySize(4)
local QUOTE_FS       = Screen:scaleBySize(11)
local QUOTE_ATTR_FS  = Screen:scaleBySize(9)
local QUOTE_GAP      = Screen:scaleBySize(4)
local QUOTE_ATTR_H   = Screen:scaleBySize(9) + Screen:scaleBySize(2)
-- Quote header height: PAD + up to 3 lines of text + gap + attribution + PAD2
local QUOTE_H        = PAD + QUOTE_FS * 3 + QUOTE_GAP + QUOTE_ATTR_H + PAD2

-- Precomputed heights per mode — avoids repeated arithmetic on every getHeight call.
local _clock_h      = CLOCK_H + PAD * 2 + PAD2
local _clock_date_h = _clock_h + DATE_H + DATE_GAP
local _custom_h     = CUSTOM_H + PAD * 2 + PAD2

-- ---------------------------------------------------------------------------
-- Quote engine (was quoteswidget.lua)
-- ---------------------------------------------------------------------------

local _quotes_cache = nil

-- Loads quotes from quotes.lua, which lives in the same plugin directory.
-- Uses a fixed relative path — more robust than debug.getinfo on e-readers.
local function loadQuotes()
    if _quotes_cache then return _quotes_cache end
    local _qpath = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
    local ok, data = pcall(dofile, _qpath .. "quotes.lua")
    if ok and type(data) == "table" and #data > 0 then
        _quotes_cache = data
    else
        -- Fallback so the widget is never blank.
        _quotes_cache = {
            { q = "A reader lives a thousand lives before he dies.",        a = "George R.R. Martin" },
            { q = "So many books, so little time.",                         a = "Frank Zappa" },
            { q = "I have always imagined that Paradise will be a kind of library.", a = "Jorge Luis Borges" },
            { q = "Sleep is good, he said, and books are better.",          a = "George R.R. Martin", b = "A Clash of Kings" },
        }
    end
    return _quotes_cache
end

local _last_idx = nil

-- Picks a random quote, never repeating the previous one.
local function pickQuote()
    local quotes = loadQuotes()
    local n = #quotes
    if n == 0 then return nil end
    if n == 1 then _last_idx = 1; return quotes[1] end
    local idx
    repeat idx = math.random(1, n) until idx ~= _last_idx
    _last_idx = idx
    return quotes[idx]
end

-- Builds the quote widget for insertion in the header VerticalGroup.
local function buildQuoteWidget(inner_w)
    local q = pickQuote()
    if not q then
        return TextWidget:new{
            text    = _("No quotes found."),
            face    = Font:getFace("cfont", QUOTE_FS),
            fgcolor = _CLR_TEXT_MID,
            width   = inner_w,
        }
    end

    local attribution = "— " .. (q.a or "?")
    if q.b and q.b ~= "" then attribution = attribution .. ",  " .. q.b end

    local vg = VerticalGroup:new{ align = "center" }
    vg[#vg+1] = TextBoxWidget:new{
        text      = "\u{201C}" .. q.q .. "\u{201D}",
        face      = Font:getFace("cfont", QUOTE_FS),
        fgcolor   = _CLR_TEXT_QUOTE,
        width     = inner_w,
        alignment = "center",
    }
    vg[#vg+1] = VerticalSpan:new{ width = QUOTE_GAP }
    vg[#vg+1] = TextBoxWidget:new{
        text      = attribution,
        face      = Font:getFace("cfont", QUOTE_ATTR_FS),
        fgcolor   = _CLR_TEXT_ATTR,
        bold      = true,
        width     = inner_w,
        alignment = "center",
    }
    return vg
end

-- ---------------------------------------------------------------------------
-- Height and build helpers
-- ---------------------------------------------------------------------------

local function heightForMode(mode)
    if mode == "nothing"    then return 0 end
    if mode == "clock_date" then return _clock_date_h end
    if mode == "clock"      then return _clock_h end
    if mode == "custom"     then return _custom_h end
    if mode == "quote"      then return QUOTE_H end
    return _clock_h
end

local function buildForMode(w, mode, pool, ctx)
    if mode == "nothing" then return nil end
    local inner_w = w - PAD * 2
    local vg = VerticalGroup:new{ align = "center" }

    if mode == "clock" or mode == "clock_date" then
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = CLOCK_DIMEN },
            TextWidget:new{
                text = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")),
                face = Font:getFace("smallinfofont", CLOCK_FS),
                bold = true,
            },
        }
        if mode == "clock_date" then
            -- Reuse pool span for the gap between clock and date.
            if pool then
                if not pool[DATE_GAP] then
                    pool[DATE_GAP] = VerticalSpan:new{ width = DATE_GAP }
                end
                vg[#vg+1] = pool[DATE_GAP]
            else
                vg[#vg+1] = VerticalSpan:new{ width = DATE_GAP }
            end
            vg[#vg+1] = CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = DATE_H },
                TextWidget:new{
                    text    = os.date("%A, %d %B"),
                    face    = Font:getFace("smallinfofont", DATE_FS),
                    fgcolor = _CLR_TEXT_MID,
                },
            }
        end

    elseif mode == "custom" then
        local custom = G_reader_settings:readSetting(ctx.pfx .. "header_custom") or "KOReader"
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = CUSTOM_H },
            TextWidget:new{
                text  = custom,
                face  = Font:getFace("smallinfofont", CUSTOM_FS),
                bold  = true,
                width = w - PAD * 4,
            },
        }

    elseif mode == "quote" then
        vg[#vg+1] = buildQuoteWidget(inner_w)
    end

    return FrameContainer:new{
        bordersize     = 0,
        padding        = PAD,
        padding_bottom = PAD2 + BOT_PAD_EXTRA,
        vg,
    }
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------

local M = {}

M.id         = "header"
M.name       = _("Header")
M.label      = nil
M.default_on = true

-- Uses a dedicated "header_enabled" key, separate from the mode key
-- (pfx.."header"), so the toggle state is explicit and never inferred
-- from nil defaults — which caused the toggle-disables-on-first-click bug.
function M.isEnabled(pfx)
    local explicit = G_reader_settings:readSetting(pfx .. "header_enabled")
    if explicit ~= nil then return explicit == true end
    -- Backwards compatibility: derive from mode for installations that
    -- predate the header_enabled key.
    local mode = G_reader_settings:readSetting(pfx .. "header")
    return mode ~= "nothing"
end

function M.setEnabled(pfx, on)
    G_reader_settings:saveSetting(pfx .. "header_enabled", on)
    if on then
        local cur = G_reader_settings:readSetting(pfx .. "header")
        if cur == nil or cur == "nothing" then
            local last = G_reader_settings:readSetting(pfx .. "header_last") or "clock_date"
            G_reader_settings:saveSetting(pfx .. "header", last)
        end
    else
        local cur = G_reader_settings:readSetting(pfx .. "header") or "clock_date"
        if cur ~= "nothing" then
            G_reader_settings:saveSetting(pfx .. "header_last", cur)
        end
        G_reader_settings:saveSetting(pfx .. "header", "nothing")
    end
end

M.getCountLabel = nil

function M.build(w, ctx)
    local mode = G_reader_settings:readSetting(ctx.pfx .. "header") or "clock_date"
    return buildForMode(w, mode, ctx.vspan_pool, ctx)
end

function M.getHeight(ctx)
    local mode = G_reader_settings:readSetting(ctx.pfx .. "header") or "clock_date"
    return heightForMode(mode)
end

function M.getMenuItems(ctx_menu)
    local pfx        = ctx_menu.pfx
    local _UIManager = ctx_menu.UIManager
    local refresh    = ctx_menu.refresh
    local MAX_LBL    = ctx_menu.MAX_LABEL_LEN or 48
    local _lc        = ctx_menu._

    local function getMode()
        return G_reader_settings:readSetting(pfx .. "header") or "clock_date"
    end

    local PRESETS = {
        { key = "clock",      label = _lc("Clock") },
        { key = "clock_date", label = _lc("Clock") .. " + " .. _lc("Date") },
        { key = "quote",      label = _lc("Quote of the Day") },
    }
    local items = {}
    for _, p in ipairs(PRESETS) do
        local _key = p.key
        local _lbl = p.label
        items[#items+1] = {
            text         = _lbl,
            radio        = true,
            checked_func = function() return getMode() == _key end,
            callback     = function()
                G_reader_settings:saveSetting(pfx .. "header", _key)
                G_reader_settings:saveSetting(pfx .. "header_enabled", true)
                refresh()
            end,
        }
    end

    items[#items+1] = {
        text_func = function()
            local custom = G_reader_settings:readSetting(pfx .. "header_custom") or ""
            if getMode() == "custom" and custom ~= "" then
                return _lc("Custom Text") .. "  (" .. custom .. ")"
            end
            return _lc("Custom Text")
        end,
        radio          = true,
        checked_func   = function() return getMode() == "custom" end,
        keep_menu_open = true,
        callback = function()
            local InputDialog = require("ui/widget/inputdialog")
            local dlg
            dlg = InputDialog:new{
                title      = _lc("Header Text"),
                input      = G_reader_settings:readSetting(pfx .. "header_custom") or "",
                input_hint = _lc("e.g. My Library"),
                buttons = {{ {
                    text = _lc("Cancel"),
                    callback = function() _UIManager:close(dlg) end,
                }, {
                    text             = _lc("OK"),
                    is_enter_default = true,
                    callback = function()
                        local clean = dlg:getInputText():match("^%s*(.-)%s*$")
                        _UIManager:close(dlg)
                        if clean == "" then return end
                        if #clean > MAX_LBL then clean = clean:sub(1, MAX_LBL) end
                        G_reader_settings:saveSetting(pfx .. "header_custom", clean)
                        G_reader_settings:saveSetting(pfx .. "header", "custom")
                        G_reader_settings:saveSetting(pfx .. "header_enabled", true)
                        refresh()
                    end,
                } }},
            }
            _UIManager:show(dlg)
            pcall(function() dlg:onShowKeyboard() end)
        end,
    }
    return items
end

return M