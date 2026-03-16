-- module_reading_goals.lua — Simple UI
-- Reading Goals module: annual and daily progress bars with tap-to-set dialogs.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _               = require("gettext")
local Config          = require("config")

local UI      = require("ui")
local PAD     = UI.PAD
local MOD_GAP = UI.MOD_GAP
local LABEL_H = UI.LABEL_H

local _CLR_BAR_BG   = Blitbuffer.gray(0.15)
local _CLR_BAR_FG   = Blitbuffer.gray(0.75)
local _CLR_TEXT_PCT = Blitbuffer.gray(0.30)
local _CLR_TEXT_SUB = Blitbuffer.gray(0.45)
local _CLR_TEXT_BLK = Blitbuffer.COLOR_BLACK

-- All pixel constants computed once at load time.
local GOAL_ROW_H = Screen:scaleBySize(62)
local BAR_H      = math.max(1, math.floor(Screen:scaleBySize(10) * 0.90))
local BAR_GAP1   = Screen:scaleBySize(6)
local BAR_GAP2   = Screen:scaleBySize(5)

-- Year string cached for the session — used in several menu text_func callbacks.
local _YEAR_STR = os.date("%Y")

-- Settings keys.
local SHOW_ANNUAL = "navbar_reading_goals_show_annual"
local SHOW_DAILY  = "navbar_reading_goals_show_daily"

-- Returns true when the setting is on (nil = default on, false = explicitly off).
local function showAnnual() return G_reader_settings:readSetting(SHOW_ANNUAL) ~= false end
local function showDaily()  return G_reader_settings:readSetting(SHOW_DAILY)  ~= false end

local function getAnnualGoal()     return G_reader_settings:readSetting("navbar_reading_goal") or 0 end
local function getAnnualPhysical() return G_reader_settings:readSetting("navbar_reading_goal_physical") or 0 end
local function getDailyGoalSecs()  return G_reader_settings:readSetting("navbar_daily_reading_goal_secs") or 0 end

-- Formats a duration in seconds as "Xh Ym", "Xh", or "Ym".
local function formatDuration(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0m" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end

-- Stats cache — keyed by calendar date, invalidated on keep_cache=false refresh
-- or after the user saves a goal value.
local _stats_cache     = nil
local _stats_cache_day = nil

local function invalidateStatsCache()
    _stats_cache     = nil
    _stats_cache_day = nil
end

-- Queries the stats DB for books_read, year_secs, today_secs.
-- Results are cached for the rest of the current day to avoid repeated SQL on
-- every homescreen render (clock tick, cover poll, etc.).
local function getGoalStats(shared_conn)
    local today_key = os.date("%Y-%m-%d")
    if _stats_cache and _stats_cache_day == today_key then
        return _stats_cache[1], _stats_cache[2], _stats_cache[3]
    end

    local books_read, year_secs, today_secs = 0, 0, 0
    local conn     = shared_conn or Config.openStatsDB()
    if not conn then return books_read, year_secs, today_secs end
    local own_conn = not shared_conn

    pcall(function()
        local t           = os.date("*t")
        local year_start  = os.time{ year = t.year, month = 1, day = 1, hour = 0, min = 0, sec = 0 }
        local today_start = os.time() - (t.hour * 3600 + t.min * 60 + t.sec)

        local ry = conn:rowexec(string.format([[
            SELECT sum(s) FROM (
                SELECT sum(duration) AS s FROM page_stat
                WHERE start_time >= %d GROUP BY id_book, page);]], year_start))
        year_secs = tonumber(ry) or 0

        local rt = conn:rowexec(string.format([[
            SELECT sum(s) FROM (
                SELECT sum(duration) AS s FROM page_stat
                WHERE start_time >= %d GROUP BY id_book, page);]], today_start))
        today_secs = tonumber(rt) or 0

        -- Use pre-aggregated total_read_pages from the book table instead of
        -- recomputing via count(DISTINCT ps.page) + JOIN + GROUP BY.
        -- total_read_pages is kept up-to-date by insertDB() in the statistics
        -- plugin, and avoids the page-rescaling inaccuracies introduced by the
        -- page_stat view when a book has been read across different layouts.
        local tb = conn:rowexec([[
            SELECT count(*) FROM book
            WHERE pages > 0
              AND total_read_pages > 0
              AND CAST(total_read_pages AS REAL) / pages >= 0.99]])
        books_read = tonumber(tb) or 0
    end)

    if own_conn then pcall(function() conn:close() end) end

    _stats_cache     = { books_read, year_secs, today_secs }
    _stats_cache_day = today_key
    return books_read, year_secs, today_secs
end

-- Builds a filled/empty horizontal progress bar at width w.
local function buildProgressBar(w, pct)
    local fw = math.max(0, math.floor(w * math.min(pct, 1.0)))
    if fw <= 0 then
        return LineWidget:new{ dimen = Geom:new{ w = w, h = BAR_H }, background = _CLR_BAR_BG }
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = BAR_H },
        LineWidget:new{ dimen = Geom:new{ w = w,  h = BAR_H }, background = _CLR_BAR_BG },
        LineWidget:new{ dimen = Geom:new{ w = fw, h = BAR_H }, background = _CLR_BAR_FG },
    }
end

-- Builds one goal row: title + percentage on top, progress bar, sub-text below.
-- When on_tap is provided the row becomes an InputContainer that fires the callback.
local function buildGoalRow(inner_w, title_str, pct, pct_str, sub_str, on_tap)
    local title_widget = TextWidget:new{
        text    = title_str,
        face    = Font:getFace("smallinfofont", Screen:scaleBySize(10)),
        bold    = true,
        fgcolor = _CLR_TEXT_BLK,
    }
    local top_h = title_widget:getSize().h
    local top_row = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = top_h },
        title_widget,
        RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = top_h },
            TextWidget:new{
                text    = pct_str,
                face    = Font:getFace("smallinfofont", Screen:scaleBySize(10)),
                bold    = true,
                fgcolor = _CLR_TEXT_PCT,
            },
        },
    }
    local content = VerticalGroup:new{
        align = "left",
        top_row,
        VerticalSpan:new{ width = BAR_GAP1 },
        buildProgressBar(inner_w, pct),
        VerticalSpan:new{ width = BAR_GAP2 },
        TextWidget:new{
            text      = sub_str,
            face      = Font:getFace("cfont", Screen:scaleBySize(9)),
            fgcolor   = _CLR_TEXT_SUB,
            width     = inner_w,
            max_line  = 1,
        },
    }
    local row = FrameContainer:new{
        bordersize = 0, padding = 0,
        dimen      = Geom:new{ w = inner_w, h = GOAL_ROW_H },
        content,
    }
    if not on_tap then return row end

    local tappable = InputContainer:new{
        dimen   = Geom:new{ w = inner_w, h = GOAL_ROW_H },
        [1]     = row,
        _on_tap = on_tap,
    }
    tappable.ges_events = {
        TapGoal = {
            GestureRange:new{
                ges   = "tap",
                range = function() return tappable.dimen end,
            },
        },
    }
    function tappable:onTapGoal()
        if self._on_tap then self._on_tap() end
        return true
    end
    return tappable
end

-- Refreshes the homescreen after a goal value is saved.
local function _refreshHS()
    local HS = package.loaded["homescreen"]
    if HS then HS.refresh(false) end
end

-- Opens a SpinWidget to set the annual book count goal.
local function showAnnualGoalDialog(on_confirm)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text  = _("Annual Reading Goal"),
        info_text   = string.format(_("Books to read in %s:"), _YEAR_STR),
        value       = (function() local g = getAnnualGoal(); return g > 0 and g or 12 end)(),
        value_min   = 0, value_max = 365, value_step = 1,
        ok_text     = _("Save"), cancel_text = _("Cancel"),
        callback    = function(spin)
            G_reader_settings:saveSetting("navbar_reading_goal", math.floor(spin.value))
            invalidateStatsCache()
            _refreshHS()
            if on_confirm then on_confirm() end
        end,
    })
end

-- Opens a SpinWidget to record physical books read this year.
local function showAnnualPhysicalDialog(on_confirm)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text  = string.format(_("Physical Books — %s"), _YEAR_STR),
        info_text   = _("Physical books read this year:"),
        value       = getAnnualPhysical(), value_min = 0, value_max = 365, value_step = 1,
        ok_text     = _("Save"), cancel_text = _("Cancel"),
        callback    = function(spin)
            G_reader_settings:saveSetting("navbar_reading_goal_physical", math.floor(spin.value))
            invalidateStatsCache()
            _refreshHS()
            if on_confirm then on_confirm() end
        end,
    })
end

-- Opens a single SpinWidget to set the daily reading goal in minutes (0 = disabled).
local function showDailySettingsDialog(on_confirm)
    local SpinWidget  = require("ui/widget/spinwidget")
    local cur_secs    = getDailyGoalSecs()
    local cur_minutes = math.floor(cur_secs / 60)
    UIManager:show(SpinWidget:new{
        title_text  = _("Daily Reading Goal"),
        info_text   = _("Minutes per day (0 = disabled):"),
        value       = cur_minutes, value_min = 0, value_max = 720, value_step = 5,
        ok_text     = _("Save"), cancel_text = _("Cancel"),
        callback    = function(spin)
            G_reader_settings:saveSetting("navbar_daily_reading_goal_secs",
                math.floor(spin.value) * 60)
            invalidateStatsCache()
            _refreshHS()
            if on_confirm then on_confirm() end
        end,
    })
end

-- Module API.
local M = {}

M.id          = "reading_goals"
M.name        = _("Reading Goals")
M.label       = _("Reading Goals")
M.enabled_key = "reading_goals"
M.default_on  = true

M.showAnnualGoalDialog     = showAnnualGoalDialog
M.showAnnualPhysicalDialog = showAnnualPhysicalDialog
M.showDailySettingsDialog  = showDailySettingsDialog
M.invalidateCache          = invalidateStatsCache

function M.build(w, ctx)
    local show_ann = showAnnual()
    local show_day = showDaily()
    if not show_ann and not show_day then return nil end

    local inner_w                          = w - PAD * 2
    local books_read, year_secs, today_secs = getGoalStats(ctx.db_conn)
    local refresh_fn                        = ctx.on_goal_tap

    local on_annual_tap = function() showAnnualGoalDialog(refresh_fn)    end
    local on_daily_tap  = function() showDailySettingsDialog(refresh_fn) end

    local rows = VerticalGroup:new{ align = "left" }

    if show_ann then
        local goal    = getAnnualGoal()
        local read    = books_read + getAnnualPhysical()
        local pct     = (goal > 0) and (read / goal) or 0
        local pct_str = string.format("%d%%", math.floor(pct * 100))
        local books_str
        if goal > 0 and pct >= 1.0 then
            books_str = string.format(_("Goal reached! %d books read."), read)
        elseif goal > 0 then
            books_str = string.format(_("%d / %d books"), read, goal)
        else
            books_str = string.format(_("%d books this year"), read)
        end
        rows[#rows+1] = buildGoalRow(inner_w, _YEAR_STR, pct, pct_str,
            books_str .. "  ·  " .. formatDuration(year_secs), on_annual_tap)
    end

    if show_ann and show_day then
        rows[#rows+1] = VerticalSpan:new{ width = MOD_GAP * 2 }
    end

    if show_day then
        local goal_secs = getDailyGoalSecs()
        local pct       = (goal_secs > 0) and (today_secs / goal_secs) or 0
        local pct_str   = string.format("%d%%", math.floor(pct * 100))
        local day_sub
        if goal_secs <= 0 then
            day_sub = string.format(_("%s read today"), formatDuration(today_secs))
        elseif pct >= 1.0 then
            day_sub = string.format(_("Goal reached! %s / %s read"),
                formatDuration(today_secs), formatDuration(goal_secs))
        else
            local rem = math.max(0, goal_secs - today_secs)
            day_sub = string.format(_("%s / %s · %s to go"),
                formatDuration(today_secs), formatDuration(goal_secs), formatDuration(rem))
        end
        rows[#rows+1] = buildGoalRow(inner_w,
            _("Today") .. "  " .. os.date("%d %b"),
            pct, pct_str, day_sub, on_daily_tap)
    end

    return FrameContainer:new{
        bordersize    = 0, padding = 0,
        padding_left  = PAD, padding_right = PAD,
        rows,
    }
end

function M.getHeight(_ctx)
    local n = (showAnnual() and 1 or 0) + (showDaily() and 1 or 0)
    return LABEL_H + n * GOAL_ROW_H + (n == 2 and MOD_GAP * 2 or 0)
end

function M.getMenuItems(ctx_menu)
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._
    return {
        { text         = _lc("Annual Goal"),
          checked_func = function() return showAnnual() end,
          keep_menu_open = true,
          callback = function()
              G_reader_settings:saveSetting(SHOW_ANNUAL, not showAnnual())
              refresh()
          end },
        { text_func = function()
              local g = getAnnualGoal()
              return g > 0
                  and string.format(_lc("  Set Goal  (%d books in %s)"), g, _YEAR_STR)
                  or  string.format(_lc("  Set Goal  (%s)"), _YEAR_STR)
          end,
          keep_menu_open = true,
          callback = function() showAnnualGoalDialog(refresh) end },
        { text_func = function()
              local p = getAnnualPhysical()
              return string.format(_lc("  Physical Books  (%d in %s)"), p, _YEAR_STR)
          end,
          keep_menu_open = true,
          callback = function() showAnnualPhysicalDialog(refresh) end },
        { text         = _lc("Daily Goal"),
          checked_func = function() return showDaily() end,
          keep_menu_open = true,
          callback = function()
              G_reader_settings:saveSetting(SHOW_DAILY, not showDaily())
              refresh()
          end },
        { text_func = function()
              local secs = getDailyGoalSecs()
              local m    = math.floor(secs / 60)
              if secs <= 0 then return _lc("  Set Goal  (disabled)")
              else              return string.format(_lc("  Set Goal  (%d min/day)"), m) end
          end,
          keep_menu_open = true,
          callback = function() showDailySettingsDialog(refresh) end },
    }
end

return M