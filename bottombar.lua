-- bottombar.lua — Simple UI
-- Bottom tab bar: dimensions, widget construction, touch zones, navigation, rebuild helpers.

local FrameContainer  = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local LineWidget      = require("ui/widget/linewidget")
local TextWidget      = require("ui/widget/textwidget")
local ImageWidget     = require("ui/widget/imagewidget")
local Geom            = require("ui/geometry")
local Font            = require("ui/font")
local Blitbuffer      = require("ffi/blitbuffer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local Device          = require("device")
local Screen          = Device.screen
local logger          = require("logger")
local _               = require("gettext")

local Config = require("config")

local M = {}

-- Bar colors.
M.COLOR_INACTIVE_TEXT = Blitbuffer.gray(0.55)
M.COLOR_SEPARATOR     = Blitbuffer.gray(0.7)

-- ---------------------------------------------------------------------------
-- Dimension cache — computed once, invalidated on screen resize or size change.
-- ---------------------------------------------------------------------------

local _dim = {}

-- Reads the current navbar size setting and returns a scale factor.
-- "compact" shrinks the bar to ~78% — more content space, still tappable.
-- "default" is 1.0 (unchanged).
local function _getNavbarScale()
    local key = G_reader_settings:readSetting("navbar_bar_size") or "default"
    if key == "compact" then return 0.78 end
    return 1.0
end

function M.invalidateDimCache()
    _dim = {}
    _vspan_icon_top = nil
    _vspan_icon_txt = nil
    _old_touch_zones = nil
end

local function _cached(key, fn)
    if not _dim[key] then _dim[key] = fn() end
    return _dim[key]
end

-- Dimensions that scale with navbar size setting.
-- BOT_SP, TOP_SP, SEP_H and SIDE_M are structural/device-safe-area values —
-- they do not scale with the bar size.
function M.BAR_H()       return _cached("bar_h",   function() return math.floor(Screen:scaleBySize(96) * _getNavbarScale()) end) end
function M.ICON_SZ()     return _cached("icon_sz", function() return math.floor(Screen:scaleBySize(44) * _getNavbarScale()) end) end
function M.ICON_TOP_SP() return _cached("it_sp",   function() return math.floor(Screen:scaleBySize(10) * _getNavbarScale()) end) end
function M.ICON_TXT_SP() return _cached("itxt_sp", function() return math.floor(Screen:scaleBySize(4)  * _getNavbarScale()) end) end
function M.LABEL_FS()    return _cached("lbl_fs",  function() return math.floor(Screen:scaleBySize(9)  * _getNavbarScale()) end) end
function M.INDIC_H()     return _cached("indic_h", function() return math.floor(Screen:scaleBySize(3)  * _getNavbarScale()) end) end

-- Structural dimensions — not affected by the size setting.
function M.TOP_SP()      return _cached("top_sp",  function() return Screen:scaleBySize(2)  end) end
function M.BOT_SP()      return _cached("bot_sp",  function() return Screen:scaleBySize(12) end) end
function M.SIDE_M()      return _cached("side_m",  function() return Screen:scaleBySize(24) end) end
function M.SEP_H()       return _cached("sep_h",   function() return Screen:scaleBySize(1)  end) end

function M.TOTAL_H()
    if not G_reader_settings:nilOrTrue("navbar_enabled") then return 0 end
    return M.BAR_H() + M.TOP_SP() + M.BOT_SP()
end

-- ---------------------------------------------------------------------------
-- Pagination bar helpers
-- ---------------------------------------------------------------------------

function M.getPaginationIconSize()
    local key = G_reader_settings:readSetting("navbar_pagination_size") or "s"
    if key == "xs" then return Screen:scaleBySize(20)
    elseif key == "s" then return Screen:scaleBySize(28)
    else return Screen:scaleBySize(36) end
end

function M.getPaginationFontSize()
    local key = G_reader_settings:readSetting("navbar_pagination_size") or "s"
    if key == "xs" then return 11
    elseif key == "s" then return 14
    else return 20 end
end

-- Button field names used by resizePaginationButtons — defined once at module level (P8).
local _PAGINATION_BTN_NAMES = {
    "page_info_left_chev", "page_info_right_chev",
    "page_info_first_chev", "page_info_last_chev",
}

function M.resizePaginationButtons(widget, icon_size)
    pcall(function()
        for _i, name in ipairs(_PAGINATION_BTN_NAMES) do
            local btn = widget[name]
            if btn then
                btn.icon_width  = icon_size
                btn.icon_height = icon_size
                btn:init()
            end
        end
        local txt = widget.page_info_text
        if txt then
            txt.text_font_size = M.getPaginationFontSize()
            txt:init()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Visual construction
-- ---------------------------------------------------------------------------

-- Reused table for tab widths — avoids per-render allocation.
-- Returns a table of pixel widths for each tab, last tab absorbs rounding remainder.
local _tab_widths_cache = {}

function M.getTabWidths(num_tabs, usable_w)
    local base_w = math.floor(usable_w / num_tabs)
    for i = 1, num_tabs do
        _tab_widths_cache[i] = (i == num_tabs) and (usable_w - base_w * (num_tabs - 1)) or base_w
    end
    for i = num_tabs + 1, #_tab_widths_cache do _tab_widths_cache[i] = nil end
    return _tab_widths_cache
end

-- VerticalSpan singletons — created once per layout, reused across all tab cell renders.
-- Cleared by invalidateDimCache() on screen resize.
local _vspan_icon_top = nil
local _vspan_icon_txt = nil

-- Builds one tab cell: separator, active indicator, icon and/or label.
function M.buildTabCell(action_id, active, tab_w, mode)
    local action          = Config.getActionById(action_id)
    local indicator_color = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local vg              = VerticalGroup:new{ align = "center" }

    vg[#vg + 1] = LineWidget:new{
        dimen      = Geom:new{ w = tab_w, h = M.SEP_H() },
        background = M.COLOR_SEPARATOR,
    }
    vg[#vg + 1] = LineWidget:new{
        dimen      = Geom:new{ w = tab_w, h = M.INDIC_H() },
        background = indicator_color,
    }
    if not _vspan_icon_top then _vspan_icon_top = VerticalSpan:new{ width = M.ICON_TOP_SP() } end
    vg[#vg + 1] = _vspan_icon_top

    if mode == "icons" or mode == "both" then
        vg[#vg + 1] = ImageWidget:new{
            file    = action.icon,
            width   = M.ICON_SZ(),
            height  = M.ICON_SZ(),
            is_icon = true,
            alpha   = true,
        }
    end

    if mode == "text" or mode == "both" then
        if mode == "both" then
            if not _vspan_icon_txt then _vspan_icon_txt = VerticalSpan:new{ width = M.ICON_TXT_SP() } end
            vg[#vg + 1] = _vspan_icon_txt
        end
        vg[#vg + 1] = TextWidget:new{
            text    = action.label,
            face    = Font:getFace("cfont", M.LABEL_FS()),
            fgcolor = active and Blitbuffer.COLOR_BLACK or M.COLOR_INACTIVE_TEXT,
        }
    end

    return CenterContainer:new{
        dimen = Geom:new{ w = tab_w, h = M.BAR_H() },
        vg,
    }
end

-- Assembles the full bottom bar FrameContainer from all tab cells.
function M.buildBarWidget(active_action_id, tab_config, num_tabs, mode)
    num_tabs    = num_tabs or Config.getNumTabs()
    mode        = mode     or Config.getNavbarMode()
    local screen_w = Screen:getWidth()
    local side_m   = M.SIDE_M()
    local usable_w = screen_w - side_m * 2
    local widths   = M.getTabWidths(num_tabs, usable_w)
    local hg_args  = { align = "top" }

    for i = 1, num_tabs do
        local action_id = tab_config[i]
        hg_args[#hg_args + 1] = M.buildTabCell(action_id, action_id == active_action_id, widths[i], mode)
    end

    return FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = side_m,
        padding_right = side_m,
        margin        = 0,
        background    = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new(hg_args),
    }
end

-- Swaps the bar widget inside an already-wrapped widget, preserving overlap_offset.
function M.replaceBar(widget, new_bar, tabs)
    if not G_reader_settings:nilOrTrue("navbar_enabled") then
        if widget and tabs then widget._navbar_tabs = tabs end
        return
    end
    local container = widget._navbar_container
    if not container then return end
    local idx = widget._navbar_bar_idx
    if not idx then
        logger.err("simpleui: replaceBar called without _navbar_bar_idx — widget not initialised.")
        return
    end
    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    if widget._navbar_bar_idx_topbar_on ~= nil and widget._navbar_bar_idx_topbar_on ~= topbar_on then
        logger.warn("simpleui: replaceBar — bar_idx out of sync, skipping.")
        return
    end
    local old_bar = container[idx]
    if old_bar and old_bar.overlap_offset then
        new_bar.overlap_offset = old_bar.overlap_offset
    end
    container[idx]     = new_bar
    widget._navbar_bar = new_bar
    if tabs then widget._navbar_tabs = tabs end
end

-- ---------------------------------------------------------------------------
-- Touch zones
-- ---------------------------------------------------------------------------

function M.registerTouchZones(plugin, fm_self)
    local num_tabs = Config.getNumTabs()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local navbar_on = G_reader_settings:nilOrTrue("navbar_enabled")
    local bar_h    = navbar_on and M.BAR_H() or 0
    local side_m   = M.SIDE_M()
    local usable_w = screen_w - side_m * 2
    local bar_y    = navbar_on and (screen_h - bar_h - M.BOT_SP()) or screen_h
    local widths   = M.getTabWidths(num_tabs, usable_w)

    -- Unregister stale zones from any previous registration.
    if fm_self.unregisterTouchZones then
        local old_zones = {}
        for i = 1, Config.MAX_TABS do
            old_zones[#old_zones + 1] = { id = "navbar_pos_" .. i }
        end
        for _i, id in ipairs({
            "navbar_hold_start", "navbar_hold_settings",
        }) do
            old_zones[#old_zones + 1] = { id = id }
        end
        fm_self:unregisterTouchZones(old_zones)
    end

    local zones             = {}
    local cumulative_offset = 0

    -- One tap zone per tab; inactive slots are moved off-screen.
    for i = 1, Config.MAX_TABS do
        local pos    = i
        local active = (i <= num_tabs)
        local x_start, this_tab_w
        if active then
            x_start           = side_m + cumulative_offset
            this_tab_w        = widths[i]
            cumulative_offset = cumulative_offset + widths[i]
        else
            x_start    = screen_w + 1
            this_tab_w = 1
        end
        zones[#zones + 1] = {
            id          = "navbar_pos_" .. i,
            ges         = "tap",
            screen_zone = {
                ratio_x = x_start    / screen_w,
                ratio_y = bar_y      / screen_h,
                ratio_w = this_tab_w / screen_w,
                ratio_h = bar_h      / screen_h,
            },
            handler = function(_ges)
                if not active then return false end
                if pos > Config.getNumTabs() then return false end
                local t         = Config.loadTabConfig()
                local action_id = t[pos]
                if not action_id then return true end
                plugin:_onTabTap(action_id, fm_self)
                return true
            end,
        }
    end

    -- Hold anywhere on the bar to open the settings menu.
    local bar_screen_zone = {
        ratio_x = 0,
        ratio_y = bar_y / screen_h,
        ratio_w = 1,
        ratio_h = bar_h / screen_h,
    }
    zones[#zones + 1] = {
        id          = "navbar_hold_start",
        ges         = "hold",
        screen_zone = bar_screen_zone,
        handler     = function(_ges) return true end,
    }
    zones[#zones + 1] = {
        id          = "navbar_hold_settings",
        ges         = "hold_release",
        screen_zone = bar_screen_zone,
        handler = function(_ges)
            if not plugin._makeNavbarMenu then plugin:addToMainMenu({}) end
            local UI_mod    = require("ui")
            local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
            local top_offset = topbar_on and require("topbar").TOTAL_TOP_H() or 0
            -- Delegates to the shared implementation in ui.lua (#4).
            UI_mod.showSettingsMenu(_("Bottom Bar"), plugin._makeNavbarMenu,
                top_offset, screen_h, M.TOTAL_H())
            return true
        end,
    }

    fm_self:registerTouchZones(zones)
end

-- ---------------------------------------------------------------------------
-- Tab tap handler
-- ---------------------------------------------------------------------------

function M.onTabTap(plugin, action_id, fm_self)
    -- Action-only tabs: open their dialog/action without changing the active tab.
    -- The indicator stays on whatever tab was active before the tap.
    if action_id == "power"       then M.showPowerDialog(plugin);  return end
    if action_id == "wifi_toggle" then M.doWifiToggle(plugin);     return end
    if action_id == "frontlight"  then M.showFrontlightDialog();   return end

    -- Load tabs once — navigate reuses this table instead of reloading.
    local tabs = Config.loadTabConfig()

    -- Track whether this tab was already active before the tap.
    local already_active = (plugin.active_action == action_id)

    plugin.active_action = action_id
    if fm_self._navbar_container then
        M.replaceBar(fm_self, M.buildBarWidget(action_id, tabs), tabs)
        UIManager:setDirty(fm_self._navbar_container, "ui")
        UIManager:setDirty(fm_self, "ui")
    end
    pcall(function() plugin:_updateFMHomeIcon() end)
    plugin:_navigate(action_id, fm_self, tabs, already_active)
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

local function showUnavailable(msg)
    UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
end

local function setActiveAndRefreshFM(plugin, action_id, tabs)
    plugin.active_action = action_id
    local fm = plugin.ui
    if fm and fm._navbar_container then
        M.replaceBar(fm, M.buildBarWidget(action_id, fm._navbar_tabs or tabs), tabs)
        UIManager:setDirty(fm, "ui")
    end
    return action_id
end
-- Exported so patches.lua can delegate to it instead of duplicating the body (#3).
M.setActiveAndRefreshFM = setActiveAndRefreshFM

-- ---------------------------------------------------------------------------
-- classify_action: returns true when the action is "in-place" (executes
-- without opening a new fullscreen view) and must NOT close the homescreen.
-- Returns false for navigation actions that open a different screen.
-- ---------------------------------------------------------------------------
local function _isInPlaceAction(action_id)
    if action_id == "wifi_toggle" then return true end
    if action_id == "frontlight"  then return true end
    if action_id == "power"       then return true end
    if action_id == "stats_calendar" then return true end
    if action_id:match("^custom_qa_%d+$") then
        local cfg = Config.getCustomQAConfig(action_id)
        -- dispatcher_action and plugin_method are in-place (they toggle state
        -- or call a plugin method without opening a new fullscreen widget).
        -- collection and path navigate away — those must close the HS.
        if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then return true end
        if cfg.plugin_key and cfg.plugin_method and cfg.plugin_key ~= "" then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- _executeInPlace: runs an in-place action while keeping the HS open.
-- The HS is temporarily moved to the bottom of the window stack so that
-- Dispatcher:sendEvent and broadcastEvent reach FM plugins correctly.
-- After execution the HS is restored to the top and repainted.
-- ---------------------------------------------------------------------------
local function _executeInPlace(action_id, plugin, fm)
    local HS      = package.loaded["homescreen"]
    local hs_inst = HS and HS._instance
    local UI_mod  = require("ui")
    local stack   = UI_mod.getWindowStack()
    local hs_idx  = nil

    -- Sink the HS to position 1 so FM plugins receive events normally.
    if hs_inst then
        for i, entry in ipairs(stack) do
            if entry.widget == hs_inst then hs_idx = i; break end
        end
        if hs_idx and hs_idx > 1 then
            local entry = table.remove(stack, hs_idx)
            table.insert(stack, 1, entry)
        end
    end

    if action_id == "wifi_toggle" then
        M.doWifiToggle(plugin)

    elseif action_id == "frontlight" then
        M.showFrontlightDialog()

    elseif action_id == "power" then
        M.showPowerDialog(plugin)

    elseif action_id == "stats_calendar" then
        local ok, err = pcall(function()
            UIManager:broadcastEvent(require("ui/event"):new("ShowCalendarView"))
        end)
        if not ok then showUnavailable(_("Statistics plugin not available.")) end

    elseif action_id:match("^custom_qa_%d+$") then
        local cfg = Config.getCustomQAConfig(action_id)
        if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
            local ok_disp, Dispatcher = pcall(require, "dispatcher")
            if ok_disp and Dispatcher then
                local ok, err = pcall(function()
                    Dispatcher:execute({ [cfg.dispatcher_action] = true })
                end)
                if not ok then
                    logger.warn("simpleui: dispatcher_action failed:", cfg.dispatcher_action, tostring(err))
                    showUnavailable(string.format(_("System action error: %s"), tostring(err)))
                end
            else
                showUnavailable(_("Dispatcher not available."))
            end
        elseif cfg.plugin_key and cfg.plugin_method and cfg.plugin_key ~= "" then
            local plugin_inst = fm and fm[cfg.plugin_key]
            if plugin_inst and type(plugin_inst[cfg.plugin_method]) == "function" then
                local ok, err = pcall(function() plugin_inst[cfg.plugin_method](plugin_inst) end)
                if not ok then showUnavailable(string.format(_("Plugin error: %s"), tostring(err))) end
            else
                showUnavailable(string.format(_("Plugin not available: %s"), cfg.plugin_key))
            end
        end
    end

    -- Restore HS to its original position and repaint to reflect any changes
    -- from the action (e.g. nightmode inversion, frontlight level update).
    if hs_inst and hs_idx and hs_idx > 1 then
        for i, entry in ipairs(stack) do
            if entry.widget == hs_inst then
                local e = table.remove(stack, i)
                table.insert(stack, hs_idx, e)
                break
            end
        end
    end
    UIManager:setDirty(hs_inst or fm, "ui")
end

function M.navigate(plugin, action_id, fm_self, tabs, force)
    local fm = plugin.ui

    -- Detect if the homescreen is currently open (fm_self is the FM but the
    -- HS is on top — the tap came through the HS's injected bottombar).
    local HS = package.loaded["homescreen"]
    local hs_open = HS and HS._instance ~= nil

    -- In-place actions (toggle nightmode, frontlight, wifi, dispatcher, etc.)
    -- must NOT close the homescreen. Execute them directly and return.
    if hs_open and _isInPlaceAction(action_id) then
        _executeInPlace(action_id, plugin, fm)
        return
    end

    if hs_open then
        -- Navigate the FM while it's still covered by the HS.
        if action_id == "home" then
            local home = G_reader_settings:readSetting("home_dir")
            if home then
                if fm.file_chooser then
                    fm.file_chooser:changeToPath(home)
                    UIManager:setDirty(fm, "partial")
                else
                    -- file_chooser not yet created (FM is still initializing
                    -- after being rebuilt post-reader). The HS close below will
                    -- trigger a repaint that wakes the UIManager, so scheduleIn(0)
                    -- will run in the very next event cycle.
                    UIManager:scheduleIn(0, function()
                        local live = plugin.ui
                        if live and live.file_chooser then
                            live.file_chooser:changeToPath(home)
                            UIManager:setDirty(live, "partial")
                        end
                    end)
                end
            end
        end
        -- Close the HS before navigating to a new screen.
        local hs_inst = HS._instance
        hs_inst._navbar_closing_intentionally = true
        pcall(function() UIManager:close(hs_inst) end)
        hs_inst._navbar_closing_intentionally = nil
        -- Update the FM bar.
        if fm._navbar_container then
            M.replaceBar(fm, M.buildBarWidget(action_id, tabs), tabs)
            UIManager:setDirty(fm, "ui")
        end
        -- For "home" we're done — FM is already at the right path.
        if action_id == "home" then return end
        -- For other actions, fall through with fm_self = fm.
        fm_self = fm
    end

    -- Close any open sub-window before navigating (non-HS case).
    if fm_self ~= fm then
        fm_self._navbar_closing_intentionally = true
        pcall(function()
            if fm_self.onCloseAllMenus then fm_self:onCloseAllMenus()
            elseif fm_self.onClose     then fm_self:onClose() end
        end)
        fm_self._navbar_closing_intentionally = nil
    end

    if fm_self ~= fm and fm._navbar_container then
        M.replaceBar(fm, M.buildBarWidget(action_id, tabs), tabs)
        UIManager:setDirty(fm, "ui")
    end

    if action_id == "home" then
        local live_fm = plugin.ui or fm
        local home = G_reader_settings:readSetting("home_dir")
        if home and live_fm.file_chooser then
            live_fm.file_chooser:changeToPath(home)
            if force then UIManager:setDirty(live_fm, "partial") end
        elseif live_fm.file_chooser then
            UIManager:setDirty(live_fm, "partial")
        end

    elseif action_id == "collections" then
        if fm.collections then fm.collections:onShowCollList()
        else showUnavailable(_("Collections not available.")) end

    elseif action_id == "history" then
        local ok = pcall(function() fm.history:onShowHist() end)
        if not ok then showUnavailable(_("History not available.")) end

    elseif action_id == "homescreen" then
        local ok_hs, HS = pcall(require, "homescreen")
        if ok_hs and HS and type(HS.show) == "function" then
            local tabs = Config.loadTabConfig()
            -- QA taps from the homescreen must NOT go through _onTabTap:
            -- _onTabTap calls replaceBar(fm) which schedules a full FM repaint,
            -- and that repaint fires after the homescreen closes and interferes
            -- with dispatcher_action widgets that try to open on top of the FM.
            -- Call navigate directly with fm as the target — no bar replacement.
            local on_qa_tap = function(aid)
                plugin:_navigate(aid, fm, tabs, false)
            end
            local on_goal_tap = plugin._goalTapCallback or nil
            HS.show(on_qa_tap, on_goal_tap)
        else
            showUnavailable(_("Homescreen not available."))
        end

    elseif action_id == "favorites" then
        if fm.collections then fm.collections:onShowColl()
        else showUnavailable(_("Favorites not available.")) end

    elseif action_id == "continue" then
        local RH = package.loaded["readhistory"] or require("readhistory")
        local fp = RH and RH.hist and RH.hist[1] and RH.hist[1].file
        if fp then
            -- ReaderUI is always present — use package.loaded fast path to
            -- avoid pcall overhead. require() itself is cached after first load.
            local ReaderUI = package.loaded["apps/reader/readerui"]
                or require("apps/reader/readerui")
            ReaderUI:showReader(fp)
        else
            showUnavailable(_("No book in history."))
        end

    elseif action_id == "stats_calendar" then
        -- broadcastEvent reaches all widgets on the stack (including fm.statistics
        -- which is a registered FM plugin) regardless of which widget is on top.
        -- This works from the bottom bar, from QA in the Homescreen, and from
        -- any injected fullscreen widget. Using broadcastEvent directly avoids
        -- the Dispatcher's context checks which can silently no-op when the
        -- Homescreen is the top widget.
        local ok, err = pcall(function()
            UIManager:broadcastEvent(require("ui/event"):new("ShowCalendarView"))
        end)
        if not ok then showUnavailable(_("Statistics plugin not available.")) end
        return

    elseif action_id == "wifi_toggle" then
        M.doWifiToggle(plugin); return

    else
        if action_id:match("^custom_qa_%d+$") then
            local cfg = Config.getCustomQAConfig(action_id)
            -- dispatcher_action and plugin_method are handled by _executeInPlace
            -- when the HS is open (caught by _isInPlaceAction above). This branch
            -- only runs when the HS is already closed (e.g. tap from the FM bar).
            if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
                local ok_disp, Dispatcher = pcall(require, "dispatcher")
                if ok_disp and Dispatcher then
                    local ok, err = pcall(function()
                        Dispatcher:execute({ [cfg.dispatcher_action] = true })
                    end)
                    if not ok then
                        logger.warn("simpleui: dispatcher_action failed:", cfg.dispatcher_action, tostring(err))
                        showUnavailable(string.format(_("System action error: %s"), tostring(err)))
                    end
                else
                    showUnavailable(_("Dispatcher not available."))
                end
            elseif cfg.plugin_key and cfg.plugin_method and cfg.plugin_key ~= "" then
                local plugin_inst = fm and fm[cfg.plugin_key]
                if plugin_inst and type(plugin_inst[cfg.plugin_method]) == "function" then
                    local ok, err = pcall(function() plugin_inst[cfg.plugin_method](plugin_inst) end)
                    if not ok then showUnavailable(string.format(_("Plugin error: %s"), tostring(err))) end
                else
                    showUnavailable(string.format(_("Plugin not available: %s"), cfg.plugin_key))
                end
            elseif cfg.collection and cfg.collection ~= "" then
                if fm and fm.collections then
                    local ok, err = pcall(function() fm.collections:onShowColl(cfg.collection) end)
                    if not ok then showUnavailable(string.format(_("Collection not available: %s"), cfg.collection)) end
                end
            elseif cfg.path and cfg.path ~= "" then
                if fm.file_chooser then fm.file_chooser:changeToPath(cfg.path) end
            else
                showUnavailable(_("No folder, collection or plugin configured.\nGo to Simple UI → Settings → Quick Actions to set one."))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Simple device actions
-- ---------------------------------------------------------------------------

function M.doWifiToggle(plugin)
    local ok_hw, has_wifi = pcall(function() return Device:hasWifiToggle() end)
    if not (ok_hw and has_wifi) then
        UIManager:show(InfoMessage:new{ text = _("WiFi not available on this device."), timeout = 2 })
        return
    end
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_nm or not NetworkMgr then
        UIManager:show(InfoMessage:new{ text = _("Network manager unavailable."), timeout = 2 })
        return
    end
    local ok_state, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if not ok_state then wifi_on = false end
    if wifi_on then
        Config.wifi_optimistic = false
        pcall(function() NetworkMgr:turnOffWifi() end)
        UIManager:show(InfoMessage:new{ text = _("Wi-Fi off"), timeout = 1 })
    else
        Config.wifi_optimistic = true
        local ok_on, err = pcall(function() NetworkMgr:turnOnWifi() end)
        if not ok_on then
            logger.warn("simpleui: Wi-Fi turn-on error:", tostring(err))
            Config.wifi_optimistic = nil
        end
    end

    -- Immediately refresh the bar and topbar with the optimistic Wi-Fi state.
    if plugin then
        plugin:_rebuildAllNavbars()
        local Topbar = require("topbar")
        local cfg    = Config.getTopbarConfig()
        if (cfg.side["wifi"] or "hidden") ~= "hidden" then
            Topbar.scheduleRefresh(plugin, 0)
        end
    end

end

function M.refreshWifiIcon(plugin)
    Config.wifi_optimistic = nil
    plugin:_rebuildAllNavbars()
    plugin:_refreshCurrentView()
end

function M.showFrontlightDialog()
    local ok_f, has_fl = pcall(function() return Device:hasFrontlight() end)
    if not ok_f or not has_fl then
        UIManager:show(InfoMessage:new{
            text = _("Frontlight not available on this device."), timeout = 2,
        })
        return
    end
    UIManager:show(require("ui/widget/frontlightwidget"):new{})
end

-- ---------------------------------------------------------------------------
-- Bar rebuild helpers
-- ---------------------------------------------------------------------------

function M.rebuildAllNavbars(plugin)
    local UI        = require("ui")
    local Topbar    = require("topbar")
    M.invalidateDimCache()
    -- Read config once; these values are shared across every widget in the loop.
    local tabs      = Config.loadTabConfig()
    local num_tabs  = Config.getNumTabs()
    local mode      = Config.getNavbarMode()
    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    local stack     = UI.getWindowStack()  -- read once for the entire operation

    -- Build topbar once and reuse across all widgets — it is identical for all.
    local new_topbar = topbar_on and Topbar.buildTopbarWidget() or nil
    local seen      = {}

    local function rebuildWidget(w)
        if not w or not w._navbar_container or seen[w] then return end
        seen[w] = true
        M.replaceBar(w, M.buildBarWidget(plugin.active_action, tabs, num_tabs, mode), tabs)
        if new_topbar then
            UI.replaceTopbar(w, new_topbar)
        end
        plugin:_registerTouchZones(w)
        UIManager:setDirty(w, "ui")  -- single setDirty — container is a child of w
    end

    rebuildWidget(plugin.ui)
    local ok_icon, err_icon = pcall(function() plugin:_updateFMHomeIcon() end)
    if not ok_icon then logger.warn("simpleui: _updateFMHomeIcon failed:", tostring(err_icon)) end
    for _i, entry in ipairs(stack) do
        local ok, err = pcall(rebuildWidget, entry.widget)
        if not ok then logger.warn("simpleui: rebuildWidget failed:", tostring(err)) end
    end
end

function M.setPowerTabActive(plugin, active, prev_action)
    local tabs    = Config.loadTabConfig()
    local mode    = Config.getNavbarMode()
    local show_id = active and "power" or (prev_action or tabs[1] or "home")
    local seen    = {}

    if not active then plugin.active_action = show_id end

    local function updateWidget(w)
        if not w or not w._navbar_container or seen[w] then return end
        seen[w] = true
        M.replaceBar(w, M.buildBarWidget(show_id, tabs, nil, mode), tabs)
        UIManager:setDirty(w._navbar_container, "partial")
    end

    local UI    = require("ui")
    local stack = UI.getWindowStack()
    updateWidget(plugin.ui)
    for _i, entry in ipairs(stack) do
        local ok, err = pcall(updateWidget, entry.widget)
        if not ok then logger.warn("simpleui: setPowerTabActive updateWidget failed:", tostring(err)) end
    end
end

function M.rewrapAllWidgets(plugin)
    local UI        = require("ui")
    local tabs      = Config.loadTabConfig()
    local stack     = UI.getWindowStack()  -- read once for the entire operation
    local seen      = {}

    local function rewrapWidget(w)
        if not w or not w._navbar_container or seen[w] then return end
        seen[w] = true
        local inner = w._navbar_inner
        if not inner then return end
        -- wrapWithNavbar already builds bar AND topbar internally.
        -- We apply the returned topbar directly via applyNavbarState — no
        -- second buildTopbarWidget() call needed.
        local new_container, wrapped, bar, topbar, bar_idx, topbar_on2, topbar_idx =
            UI.wrapWithNavbar(inner, plugin.active_action or tabs[1] or "home", tabs)
        UI.applyNavbarState(w, new_container, bar, topbar, bar_idx, topbar_on2, topbar_idx, tabs)
        w[1] = wrapped
        plugin:_registerTouchZones(w)
        UIManager:setDirty(w, "ui")  -- single setDirty — container is a child of w
    end

    rewrapWidget(plugin.ui)
    for _i, entry in ipairs(stack) do
        local ok, err = pcall(rewrapWidget, entry.widget)
        if not ok then logger.warn("simpleui: rewrapWidget failed:", tostring(err)) end
    end
end

function M.restoreTabInFM(plugin, tabs, prev_action)
    local fm = plugin.ui
    if not (fm and fm._navbar_container) then return end
    local should_skip = false
    local UI = require("ui")
    pcall(function()
        for _i, entry in ipairs(UI.getWindowStack()) do
            if entry.widget and entry.widget._navbar_injected and entry.widget ~= fm then
                should_skip = true; return
            end
        end
    end)
    if should_skip then return end
    local t = tabs or Config.loadTabConfig()
    local Patches = require("patches")
    local restored = (fm.file_chooser and Patches._resolveTabForPath(fm.file_chooser.path, t))
                  or (t[1])
    plugin.active_action = restored
    M.replaceBar(fm, M.buildBarWidget(restored, t), t)
    UIManager:setDirty(fm, "ui")
end

-- ---------------------------------------------------------------------------
-- Power dialog
-- ---------------------------------------------------------------------------

function M.showPowerDialog(plugin)
    local ButtonDialog = require("ui/widget/buttondialog")
    plugin._power_dialog = ButtonDialog:new{
        buttons = {
            {{ text = _("Restart"), callback = function()
                UIManager:close(plugin._power_dialog)
                G_reader_settings:flush()
                local ok_exit, ExitCode = pcall(require, "exitcode")
                UIManager:quit((ok_exit and ExitCode and ExitCode.restart) or 85)
            end }},
            {{ text = _("Quit"), callback = function()
                UIManager:close(plugin._power_dialog)
                G_reader_settings:flush(); UIManager:quit(0)
            end }},
            {{ text = _("Cancel"), callback = function()
                UIManager:close(plugin._power_dialog)
            end }},
        },
    }
    UIManager:show(plugin._power_dialog)
end

return M