-- main.lua — Simple UI
-- Plugin entry point. Registers the plugin and delegates to specialised modules.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local logger          = require("logger")

local Config    = require("config")
local UI        = require("ui")
local Bottombar = require("bottombar")
local Topbar    = require("topbar")
local Patches   = require("patches")

local SimpleUIPlugin = WidgetContainer:new{
    name = "simpleui",

    active_action             = nil,
    _rebuild_scheduled        = false,
    _topbar_timer             = nil,
    _power_dialog             = nil,

    _orig_uimanager_show      = nil,
    _orig_uimanager_close     = nil,
    _orig_booklist_new        = nil,
    _orig_menu_new            = nil,
    _orig_menu_init           = nil,
    _orig_fmcoll_show         = nil,
    _orig_rc_remove           = nil,
    _orig_rc_rename           = nil,
    _orig_fc_init             = nil,
    _orig_fm_setup            = nil,

    _makeNavbarMenu           = nil,
    _makeTopbarMenu           = nil,
    _makeQuickActionsMenu     = nil,
    _goalTapCallback          = nil,
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function SimpleUIPlugin:init()
    local ok, err = pcall(function()
        Config.applyFirstRunDefaults()
        Config.migrateOldCustomSlots()
        Config.sanitizeQASlots()  -- remove orphaned custom QA ids from all slots
        self.ui.menu:registerToMainMenu(self)
        if G_reader_settings:nilOrTrue("simpleui_enabled") then
            Patches.installAll(self)
            if G_reader_settings:nilOrTrue("navbar_topbar_enabled") then
                Topbar.scheduleRefresh(self, 0)
            end
            -- Pre-load desktop modules during boot idle time so the first
            -- Homescreen open has no perceptible freeze. scheduleIn(2) runs
            -- after the FileManager UI is fully painted and stable.
            UIManager:scheduleIn(2, function()
                pcall(require, "desktop_modules/moduleregistry")
            end)
        end
    end)
    if not ok then logger.err("simpleui: init failed:", tostring(err)) end
end

function SimpleUIPlugin:onTeardown()
    if self._topbar_timer then
        UIManager:unschedule(self._topbar_timer)
        self._topbar_timer = nil
    end
    Patches.teardownAll(self)
end

-- ---------------------------------------------------------------------------
-- System events
-- ---------------------------------------------------------------------------

function SimpleUIPlugin:onScreenResize()
    UI.invalidateDimCache()
    UIManager:scheduleIn(0.2, function()
        self:_rewrapAllWidgets()
        self:_refreshCurrentView()
    end)
end

function SimpleUIPlugin:onNetworkConnected()
    Bottombar.refreshWifiIcon(self)
end

function SimpleUIPlugin:onNetworkDisconnected()
    Bottombar.refreshWifiIcon(self)
end

function SimpleUIPlugin:onSuspend()
    if self._topbar_timer then
        UIManager:unschedule(self._topbar_timer)
        self._topbar_timer = nil
    end
end

function SimpleUIPlugin:onResume()
    if G_reader_settings:nilOrTrue("navbar_topbar_enabled") then
        Topbar.scheduleRefresh(self, 0)
    end
    -- Only invalidate caches if we are returning from an active reading session.
    -- package.loaded["apps/reader/readerui"] is present while the reader is open;
    -- once it has closed, RUI.instance is nil. (#8)
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and not RUI.instance then
        local ok_rg, RG = pcall(require, "readinggoals")
        if ok_rg and RG and RG.Stats then RG.Stats.invalidateCache() end
        -- Invalidate reading_stats cache so today/avg/streak reflect the
        -- session that just ended. The cache is module-level and date-keyed,
        -- so without this it would stay stale until midnight.
        local ok_rs, RS = pcall(require, "desktop_modules/module_reading_stats")
        if ok_rs and RS and RS.invalidateCache then RS.invalidateCache() end
    end
end

function SimpleUIPlugin:onFrontlightStateChanged()
    if not G_reader_settings:nilOrTrue("navbar_topbar_enabled") then return end
    Topbar.scheduleRefresh(self, 0)
end

-- ---------------------------------------------------------------------------
-- Topbar delegation
-- ---------------------------------------------------------------------------

function SimpleUIPlugin:_registerTouchZones(fm_self)
    Bottombar.registerTouchZones(self, fm_self)
    Topbar.registerTouchZones(self, fm_self)

end

function SimpleUIPlugin:_scheduleTopbarRefresh(delay)
    Topbar.scheduleRefresh(self, delay)
end

function SimpleUIPlugin:_refreshTopbar()
    Topbar.refresh(self)
end

-- ---------------------------------------------------------------------------
-- Bottombar delegation
-- ---------------------------------------------------------------------------

function SimpleUIPlugin:_onTabTap(action_id, fm_self)
    Bottombar.onTabTap(self, action_id, fm_self)
end

function SimpleUIPlugin:_navigate(action_id, fm_self, tabs, force)
    Bottombar.navigate(self, action_id, fm_self, tabs, force)
end

function SimpleUIPlugin:_refreshCurrentView()
    local tabs      = Config.loadTabConfig()
    local action_id = self.active_action or tabs[1] or "home"
    self:_navigate(action_id, self.ui, tabs)
end

function SimpleUIPlugin:_rebuildAllNavbars()
    Bottombar.rebuildAllNavbars(self)
end

function SimpleUIPlugin:_rewrapAllWidgets()
    Bottombar.rewrapAllWidgets(self)
end

function SimpleUIPlugin:_restoreTabInFM(tabs, prev_action)
    Bottombar.restoreTabInFM(self, tabs, prev_action)
end

function SimpleUIPlugin:_setPowerTabActive(active, prev_action)
    Bottombar.setPowerTabActive(self, active, prev_action)
end

function SimpleUIPlugin:_showPowerDialog(fm_self)
    Bottombar.showPowerDialog(self, fm_self)
end

function SimpleUIPlugin:_doWifiToggle()
    Bottombar.doWifiToggle(self)
end

function SimpleUIPlugin:_doRotateScreen()
    Bottombar.doRotateScreen()
end

function SimpleUIPlugin:_showFrontlightDialog()
    Bottombar.showFrontlightDialog()
end

function SimpleUIPlugin:_scheduleRebuild()
    if self._rebuild_scheduled then return end
    self._rebuild_scheduled = true
    UIManager:scheduleIn(0.1, function()
        self._rebuild_scheduled = false
        self:_rebuildAllNavbars()
    end)
end


function SimpleUIPlugin:_updateFMHomeIcon() end

-- ---------------------------------------------------------------------------
-- Main menu entry (menu.lua is lazy-loaded on first access)
-- ---------------------------------------------------------------------------

local menu_module_loaded = false

function SimpleUIPlugin:addToMainMenu(menu_items)
    if not menu_module_loaded then
        menu_module_loaded = true
        local ok, err = pcall(function() require("menu")(SimpleUIPlugin) end)
        if not ok then
            menu_module_loaded = false  -- allow retry on next call
            logger.err("simpleui: menu.lua failed to load: " .. tostring(err))
            menu_items.simpleui = { sorting_hint = "tools", text = "Simple UI", sub_item_table = {} }
            return
        end
        -- menu.lua replaced SimpleUIPlugin.addToMainMenu. Call it directly
        -- via rawget so we bypass this wrapper and avoid infinite recursion.
        local real_fn = rawget(SimpleUIPlugin, "addToMainMenu")
        if real_fn then real_fn(self, menu_items) end
        return
    end
end

return SimpleUIPlugin