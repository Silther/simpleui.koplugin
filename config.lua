-- config.lua — Simple UI
-- Plugin-wide constants, action catalogue, tab/topbar configuration,
-- custom Quick Actions and settings migration.

local G_reader_settings = G_reader_settings
local logger            = require("logger")
local _                 = require("gettext")

-- ---------------------------------------------------------------------------
-- Public constants
-- ---------------------------------------------------------------------------

local M = {}

-- ---------------------------------------------------------------------------
-- Icon path registry — single source of truth for every SVG used by the plugin.
--
-- Two prefixes exist:
--   _P  = "plugins/simpleui.koplugin/icons/"   (own assets)
--   _KO = "resources/icons/mdlight/"            (KOReader built-in assets)
--
-- All modules must reference M.ICON.<key> instead of bare string literals.
-- Adding or renaming an icon only requires editing this one table.
-- ---------------------------------------------------------------------------

-- Resolve the plugin's own directory at load time so icon paths are absolute.
-- On Android/Nook the working directory is not the KOReader root, so relative
-- paths like "plugins/simpleui.koplugin/icons/..." silently fail to resolve
-- while KOReader's own assets (resources/icons/mdlight/...) work because the
-- engine has hardcoded fallbacks for its own resource tree.
-- Using an absolute path derived from this file's location is portable across
-- all platforms (Android, Kobo, Kindle, desktop emulator).
local _plugin_dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
local _P  = _plugin_dir .. "icons/"
local _KO = "resources/icons/mdlight/"

M.ICON = {
    -- Plugin icons
    library        = _P .. "library.svg",
    collections    = _P .. "collections.svg",
    history        = _P .. "history.svg",
    continue_      = _P .. "continue.svg",       -- trailing _ avoids clash with Lua keyword
    frontlight     = _P .. "frontlight.svg",
    stats          = _P .. "stats.svg",
    power          = _P .. "power.svg",
    plus_alt       = _P .. "plus_alt.svg",
    custom         = _P .. "custom.svg",
    custom_dir     = _P .. "custom",             -- directory, no trailing slash
    plugin         = _P .. "plugin.svg",

    -- KOReader built-in icons
    ko_home        = _KO .. "home.svg",
    ko_star        = _KO .. "star.empty.svg",
    ko_wifi_on     = _KO .. "wifi.open.100.svg",
    ko_wifi_off    = _KO .. "wifi.open.0.svg",
    ko_menu        = _KO .. "appbar.menu.svg",
    ko_settings    = _KO .. "appbar.settings.svg",
}

-- Legacy flat constants — kept for any external code that may reference them.
-- They resolve through the table above so there is still a single definition.
M.CUSTOM_ICON            = M.ICON.custom
M.CUSTOM_PLUGIN_ICON     = M.ICON.plugin
M.CUSTOM_DISPATCHER_ICON = M.ICON.ko_settings
M.DEFAULT_NUM_TABS       = 4
M.MAX_TABS               = 6
M.MAX_LABEL_LEN          = 20
M.MAX_CUSTOM_QA          = 10

M.DEFAULT_TABS = { "home", "collections", "history", "continue", "favorites" }

-- Fallback tab IDs used when a duplicate 'home' is detected.
M.NON_HOME_DEFAULTS = {}
for _i, id in ipairs(M.DEFAULT_TABS) do
    if id ~= "home" then M.NON_HOME_DEFAULTS[#M.NON_HOME_DEFAULTS + 1] = id end
end

-- ---------------------------------------------------------------------------
-- Predefined action catalogue
-- ---------------------------------------------------------------------------

M.ALL_ACTIONS = {
    { id = "home",           label = _("Library"),        icon = M.ICON.library     },
    { id = "homescreen",     label = _("Home"),           icon = M.ICON.ko_home     },
    { id = "collections",    label = _("Collections"),    icon = M.ICON.collections },
    { id = "history",        label = _("History"),        icon = M.ICON.history     },
    { id = "continue",       label = _("Continue"),       icon = M.ICON.continue_   },
    { id = "favorites",      label = _("Favorites"),      icon = M.ICON.ko_star     },
    { id = "wifi_toggle",    label = _("Wi-Fi"),          icon = M.ICON.ko_wifi_on  },
    { id = "frontlight",     label = _("Brightness"),     icon = M.ICON.frontlight  },
    { id = "stats_calendar", label = _("Stats"),          icon = M.ICON.stats       },
    { id = "power",          label = _("Power"),          icon = M.ICON.power       },
}

-- Fast lookup map keyed by action ID.
M.ACTION_BY_ID = {}
for _i, a in ipairs(M.ALL_ACTIONS) do M.ACTION_BY_ID[a.id] = a end

-- ---------------------------------------------------------------------------
-- Topbar configuration
-- ---------------------------------------------------------------------------

M.TOPBAR_ITEMS = { "clock", "wifi", "brightness", "battery", "disk", "ram" }

local _topbar_item_labels = nil

function M.TOPBAR_ITEM_LABEL(k)
    if not _topbar_item_labels then
        _topbar_item_labels = {
            clock      = _("Clock"),
            wifi       = _("WiFi"),
            brightness = _("Brightness"),
            battery    = _("Battery"),
            disk       = _("Disk Usage"),
            ram        = _("RAM Usage"),
        }
    end
    return _topbar_item_labels[k] or k
end

-- Returns the normalised topbar config, migrating legacy formats when needed.
function M.getTopbarConfig()
    local raw = G_reader_settings:readSetting("navbar_topbar_config")
    local cfg = { side = {}, order_left = {}, order_right = {}, show = {}, order = {} }
    if type(raw) == "table" then
        if type(raw.side) == "table" then
            for k, v in pairs(raw.side) do cfg.side[k] = v end
        end
        if type(raw.order_left) == "table" then
            for _i, v in ipairs(raw.order_left) do cfg.order_left[#cfg.order_left + 1] = v end
        end
        if type(raw.order_right) == "table" then
            for _i, v in ipairs(raw.order_right) do cfg.order_right[#cfg.order_right + 1] = v end
        end
        if not next(cfg.side) and type(raw.show) == "table" then
            for k, v in pairs(raw.show) do
                cfg.side[k] = v and "right" or "hidden"
            end
            if type(raw.order) == "table" then
                for _i, v in ipairs(raw.order) do
                    if v ~= "clock" and cfg.side[v] == "right" then
                        cfg.order_right[#cfg.order_right + 1] = v
                    end
                end
            end
        end
    end
    if not next(cfg.side) then
        cfg.side        = { clock = "left", battery = "right", wifi = "right" }
        cfg.order_left  = { "clock" }
        cfg.order_right = { "wifi", "battery" }
    end
    if #cfg.order_left == 0 then
        for k, s in pairs(cfg.side) do
            if s == "left" and k ~= "clock" then cfg.order_left[#cfg.order_left + 1] = k end
        end
        if cfg.side["clock"] == "left" then
            table.insert(cfg.order_left, 1, "clock")
        end
    end
    if #cfg.order_right == 0 then
        for k, s in pairs(cfg.side) do
            if s == "right" then cfg.order_right[#cfg.order_right + 1] = k end
        end
    end
    return cfg
end

function M.saveTopbarConfig(cfg)
    G_reader_settings:saveSetting("navbar_topbar_config", cfg)
    M.invalidateTopbarConfigCache()
    -- Also invalidate topbar.lua's own local config cache so that
    -- buildTopbarWidget() uses the new config immediately on the next rebuild.
    local tb = package.loaded["topbar"]
    if tb and tb.invalidateConfigCache then tb.invalidateConfigCache() end
end

-- ---------------------------------------------------------------------------
-- Custom Quick Actions
-- ---------------------------------------------------------------------------

-- Key cache: avoids rebuilding "navbar_cqa_<id>" strings on every call.
-- These keys are stable within a session (IDs never change after creation).
local _qa_key_cache = {}
local function getQASettingsKey(qa_id)
    local k = _qa_key_cache[qa_id]
    if not k then
        k = "navbar_cqa_" .. qa_id
        _qa_key_cache[qa_id] = k
    end
    return k
end

function M.getCustomQAList()
    return G_reader_settings:readSetting("navbar_custom_qa_list") or {}
end

function M.saveCustomQAList(list)
    G_reader_settings:saveSetting("navbar_custom_qa_list", list)
end

function M.getCustomQAConfig(qa_id)
    local cfg = G_reader_settings:readSetting(getQASettingsKey(qa_id)) or {}
    return {
        label             = cfg.label or qa_id,
        path              = cfg.path,
        collection        = cfg.collection,
        plugin_key        = cfg.plugin_key,
        plugin_method     = cfg.plugin_method,
        dispatcher_action = cfg.dispatcher_action,
        icon              = cfg.icon,
    }
end

function M.saveCustomQAConfig(qa_id, label, path, collection, icon, plugin_key, plugin_method, dispatcher_action)
    G_reader_settings:saveSetting(getQASettingsKey(qa_id), {
        label             = label,
        path              = path,
        collection        = collection,
        plugin_key        = plugin_key,
        plugin_method     = plugin_method,
        dispatcher_action = dispatcher_action,
        icon              = icon,
    })
end

function M.deleteCustomQA(qa_id)
    G_reader_settings:delSetting(getQASettingsKey(qa_id))
    _qa_key_cache[qa_id] = nil  -- remove from key cache
    local list = M.getCustomQAList()
    local new_list = {}
    for _i, id in ipairs(list) do
        if id ~= qa_id then new_list[#new_list + 1] = id end
    end
    M.saveCustomQAList(new_list)
    -- Invalidate the module-level QA validity cache so the next render does
    -- not show a deleted action.
    local mqa = package.loaded["desktop_modules/module_quick_actions"]
    if mqa and mqa.invalidateCustomQACache then mqa.invalidateCustomQACache() end
    local tabs = G_reader_settings:readSetting("navbar_tabs")
    if type(tabs) == "table" then
        local new_tabs = {}
        for _i, id in ipairs(tabs) do
            if id ~= qa_id then new_tabs[#new_tabs + 1] = id end
        end
        G_reader_settings:saveSetting("navbar_tabs", new_tabs)
    end
    -- Remove from all page QA slots
    for _i, pfx in ipairs({ "navbar_homescreen_quick_actions_" }) do
        for slot = 1, 3 do
            local key = pfx .. slot .. "_items"
            local dqa = G_reader_settings:readSetting(key)
            if type(dqa) == "table" then
                local new_dqa = {}
                for _i, id in ipairs(dqa) do
                    if id ~= qa_id then new_dqa[#new_dqa + 1] = id end
                end
                G_reader_settings:saveSetting(key, new_dqa)
            end
        end
    end
end

-- Removes all custom QA entries that reference a deleted collection name.
-- Called by patches.lua when removeCollection fires.
function M.purgeQACollection(coll_name)
    local list    = M.getCustomQAList()
    local changed = false
    for _i, qa_id in ipairs(list) do
        local cfg = M.getCustomQAConfig(qa_id)
        if cfg.collection == coll_name then
            -- Wipe the collection field so the QA becomes unconfigured
            -- (keeps the entry visible so the user knows to reconfigure).
            M.saveCustomQAConfig(qa_id, cfg.label, cfg.path, nil,
                cfg.icon, cfg.plugin_key, cfg.plugin_method, cfg.dispatcher_action)
            changed = true
        end
    end
    return changed
end

-- Updates collection references in all custom QAs after a rename.
function M.renameQACollection(old_name, new_name)
    local list    = M.getCustomQAList()
    local changed = false
    for _i, qa_id in ipairs(list) do
        local cfg = M.getCustomQAConfig(qa_id)
        if cfg.collection == old_name then
            M.saveCustomQAConfig(qa_id, cfg.label, cfg.path, new_name,
                cfg.icon, cfg.plugin_key, cfg.plugin_method, cfg.dispatcher_action)
            changed = true
        end
    end
    return changed
end

-- Removes orphaned custom QA ids from all QA slots.
-- An id is orphaned when it is referenced in a slot but not in the master list.
-- Safe to call at startup and after any QA deletion.
function M.sanitizeQASlots()
    local list = M.getCustomQAList()
    local valid = {}
    for _i, id in ipairs(list) do valid[id] = true end
    local changed = false
    for _, pfx in ipairs({ "navbar_homescreen_quick_actions_" }) do
        for slot = 1, 3 do
            local key  = pfx .. slot .. "_items"
            local items = G_reader_settings:readSetting(key)
            if type(items) == "table" then
                local clean = {}
                for _i, id in ipairs(items) do
                    -- Keep built-in action ids and valid custom QA ids
                    if not id:match("^custom_qa_%d+$") or valid[id] then
                        clean[#clean+1] = id
                    else
                        changed = true
                    end
                end
                if changed then G_reader_settings:saveSetting(key, clean) end
            end
        end
    end
    if changed then
        local mqa = package.loaded["desktop_modules/module_quick_actions"]
        if mqa and mqa.invalidateCustomQACache then mqa.invalidateCustomQACache() end
    end
    return changed
end

function M.nextCustomQAId()
    local list  = M.getCustomQAList()
    local max_n = 0
    for _i, id in ipairs(list) do
        local n = tonumber(id:match("^custom_qa_(%d+)$"))
        if n and n > max_n then max_n = n end
    end
    local n = max_n + 1
    while G_reader_settings:readSetting("navbar_cqa_custom_qa_" .. n) do n = n + 1 end
    return "custom_qa_" .. n
end

-- ---------------------------------------------------------------------------
-- Tab configuration
-- ---------------------------------------------------------------------------

-- In-memory cache to avoid repeated settings reads.
local _tabs_cache = nil

function M.invalidateTabsCache()
    _tabs_cache = nil
end

function M.loadTabConfig()
    if _tabs_cache then return _tabs_cache end
    local cfg = G_reader_settings:readSetting("navbar_tabs")
    local result = {}
    if type(cfg) == "table" and #cfg >= 2 and #cfg <= M.MAX_TABS then
        for i = 1, #cfg do
            local id = cfg[i]
            if M.ACTION_BY_ID[id] or id:match("^custom_qa_%d+$") then
                result[#result + 1] = id
            else
                logger.warn("simpleui: loadTabConfig: ignoring unknown tab id: " .. tostring(id))
            end
        end
    else
        for i = 1, M.DEFAULT_NUM_TABS do
            result[i] = M.DEFAULT_TABS[i] or M.ALL_ACTIONS[2].id
        end
    end
    M._ensureHomePresent(result)
    _tabs_cache = result
    return _tabs_cache
end

function M.saveTabConfig(tabs)
    _tabs_cache = nil
    G_reader_settings:saveSetting("navbar_tabs", tabs)
end

function M.getNumTabs()
    -- Read the cache directly to avoid any table allocation (P2).
    if _tabs_cache then return #_tabs_cache end
    return #M.loadTabConfig()
end

-- Cached navbar mode — "both", "icons", or "text".
-- Invalidated by saveNavbarMode() whenever the user changes the setting.
local _navbar_mode_cache = nil

function M.getNavbarMode()
    if not _navbar_mode_cache then
        _navbar_mode_cache = G_reader_settings:readSetting("navbar_mode") or "both"
    end
    return _navbar_mode_cache
end

function M.saveNavbarMode(mode)
    _navbar_mode_cache = nil
    G_reader_settings:saveSetting("navbar_mode", mode)
end

function M._ensureHomePresent(tabs)
    local home_pos = nil
    local used = {}
    for i, id in ipairs(tabs) do
        if id == "home" then
            if not home_pos then home_pos = i; used[id] = true end
        else
            used[id] = true
        end
    end
    for i, id in ipairs(tabs) do
        if id == "home" and i ~= home_pos then
            for _i, fid in ipairs(M.NON_HOME_DEFAULTS) do
                if not used[fid] then
                    tabs[i] = fid; used[fid] = true; break
                end
            end
        end
    end
    return tabs
end

function M.tabInTabs(tab_id, tabs)
    for _i, tid in ipairs(tabs) do
        if tid == tab_id then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Action resolution — returns live label/icon for dynamic actions
-- ---------------------------------------------------------------------------

-- Optimistic Wi-Fi state, updated immediately on toggle.
M.wifi_optimistic = nil

function M.homeLabel()
    return _("Library")
end

function M.homeIcon()
    return M.ICON.library
end

-- Module-level cache for the two heavy requires used every bar rebuild.
local _Device     = nil
local _NetworkMgr = nil
local function getDevice()
    if not _Device then _Device = require("device") end
    return _Device
end
local function getNetworkMgr()
    if not _NetworkMgr then
        local ok, nm = pcall(require, "ui/network/manager")
        if ok and nm then _NetworkMgr = nm end
    end
    return _NetworkMgr
end
M.getNetworkMgr = getNetworkMgr

-- Hardware capability — does not change during a session.
-- nil = not yet tested, false = no wifi toggle, true = has wifi toggle.
local _has_wifi_toggle = nil
local function deviceHasWifi()
    if _has_wifi_toggle == nil then
        local ok, v = pcall(function() return getDevice():hasWifiToggle() end)
        _has_wifi_toggle = ok and v == true
    end
    return _has_wifi_toggle
end

function M.wifiIcon()
    if M.wifi_optimistic ~= nil then
        return M.wifi_optimistic and M.ICON.ko_wifi_on or M.ICON.ko_wifi_off
    end
    if not deviceHasWifi() then return M.ICON.ko_wifi_off end
    local NetworkMgr = getNetworkMgr()
    if not NetworkMgr then return M.ICON.ko_wifi_off end
    local ok_state, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if ok_state and wifi_on then return M.ICON.ko_wifi_on end
    return M.ICON.ko_wifi_off
end

-- Mutable sentinel reused on every bar rebuild for wifi_toggle.
-- Avoids allocating a new table each time the icon state is queried.
local _wifi_action_live = { id = "wifi_toggle", label = "", icon = "" }

function M.getActionById(id)
    if id and id:match("^custom_qa_%d+$") then
        local cfg = M.getCustomQAConfig(id)
        local default_icon
        if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
            default_icon = M.CUSTOM_DISPATCHER_ICON
        elseif cfg.plugin_key and cfg.plugin_key ~= "" then
            default_icon = M.CUSTOM_PLUGIN_ICON
        else
            default_icon = M.CUSTOM_ICON
        end
        return { id = id, label = cfg.label, icon = cfg.icon or default_icon }
    end
    local a = M.ACTION_BY_ID[id]
    if not a then
        logger.warn("simpleui: unknown action id: " .. tostring(id) .. ", falling back to home")
        return M.ALL_ACTIONS[1]
    end
    if id == "wifi_toggle" then
        -- Mutate in place — label is static, icon reflects current wifi state.
        _wifi_action_live.label = a.label
        _wifi_action_live.icon  = M.wifiIcon()
        return _wifi_action_live
    end
    -- All other actions (including "home") are static; return directly from the catalogue.
    return a
end

-- ---------------------------------------------------------------------------
-- Settings migration
-- ---------------------------------------------------------------------------

function M.sanitizeLabel(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$")
    if #s == 0 then return nil end
    if #s > M.MAX_LABEL_LEN then s = s:sub(1, M.MAX_LABEL_LEN) end
    return s
end

function M.migrateOldCustomSlots()
    if G_reader_settings:readSetting("navbar_custom_qa_migrated_v1") then return end
    local id_map  = {}
    local qa_list = M.getCustomQAList()
    local qa_set  = {}
    for _i, id in ipairs(qa_list) do qa_set[id] = true end

    for slot = 1, 4 do
        local old_id = "custom_" .. slot
        local cfg    = G_reader_settings:readSetting("navbar_custom_" .. slot)
        if type(cfg) == "table" and (cfg.path or cfg.collection) then
            local new_id = M.nextCustomQAId()
            M.saveCustomQAConfig(new_id, cfg.label or (_("Custom") .. " " .. slot), cfg.path, cfg.collection)
            if not qa_set[new_id] then
                qa_list[#qa_list + 1] = new_id
                qa_set[new_id]        = true
            end
            id_map[old_id] = new_id
            logger.info("simpleui: migrated " .. old_id .. " -> " .. new_id)
        end
    end

    M.saveCustomQAList(qa_list)

    local tabs = G_reader_settings:readSetting("navbar_tabs")
    if type(tabs) == "table" then
        -- Build a new table instead of mutating while iterating (B6).
        local new_tabs, changed = {}, false
        for _i, id in ipairs(tabs) do
            if id_map[id] then
                new_tabs[#new_tabs + 1] = id_map[id]; changed = true
            elseif id:match("^custom_%d+$") and not id:match("^custom_qa_") then
                changed = true  -- discard stale legacy ID
            else
                new_tabs[#new_tabs + 1] = id
            end
        end
        if changed then G_reader_settings:saveSetting("navbar_tabs", new_tabs) end
    end

    for slot = 1, 3 do
        local key = "navbar_homescreen_quick_actions_" .. slot .. "_items"
        local dqa = G_reader_settings:readSetting(key)
        if type(dqa) == "table" then
            local changed = false
            local new_dqa = {}
            for _i, id in ipairs(dqa) do
                if id_map[id] then
                    new_dqa[#new_dqa + 1] = id_map[id]; changed = true
                elseif not id:match("^custom_%d+$") or id:match("^custom_qa_") then
                    new_dqa[#new_dqa + 1] = id
                else
                    changed = true
                end
            end
            if changed then G_reader_settings:saveSetting(key, new_dqa) end
        end
    end

    G_reader_settings:saveSetting("navbar_custom_qa_migrated_v1", true)

    local legacy_enabled = G_reader_settings:readSetting("navbar_enabled")
    if legacy_enabled ~= nil and G_reader_settings:readSetting("simpleui_enabled") == nil then
        G_reader_settings:saveSetting("simpleui_enabled", legacy_enabled)
    end
end

-- ---------------------------------------------------------------------------
-- First-run defaults — written once on fresh install, never overwritten.
-- Guard key: "simpleui_defaults_v1". Idempotent: safe to call on every init.
-- ---------------------------------------------------------------------------

function M.applyFirstRunDefaults()
    if G_reader_settings:readSetting("simpleui_defaults_v1") then return end

    -- Bottom bar
    G_reader_settings:saveSetting("navbar_enabled",        true)
    G_reader_settings:saveSetting("navbar_topbar_enabled", true)
    G_reader_settings:saveSetting("navbar_mode",           "both")
    G_reader_settings:saveSetting("navbar_bar_size",       "default")
    G_reader_settings:saveSetting("navbar_tabs",
        { "home", "homescreen", "history", "continue", "power" })

    -- Top bar: clock left, battery + wifi right; rest hidden
    M.saveTopbarConfig({
        side        = { clock = "left", battery = "right", wifi = "right" },
        order_left  = { "clock" },
        order_right = { "wifi", "battery" },
    })

    -- Homescreen modules: header + currently + recent on; everything else off
    local PFX = "navbar_homescreen_"
    G_reader_settings:saveSetting(PFX .. "header_enabled",  true)
    G_reader_settings:saveSetting(PFX .. "header",          "clock_date")
    G_reader_settings:saveSetting(PFX .. "currently",       true)
    G_reader_settings:saveSetting(PFX .. "recent",          true)
    G_reader_settings:saveSetting(PFX .. "collections",     false)
    G_reader_settings:saveSetting(PFX .. "reading_goals",   false)
    G_reader_settings:saveSetting(PFX .. "reading_stats_enabled",          false)
    G_reader_settings:saveSetting(PFX .. "quick_actions_1_enabled",        false)
    G_reader_settings:saveSetting(PFX .. "quick_actions_2_enabled",        false)
    G_reader_settings:saveSetting(PFX .. "quick_actions_3_enabled",        false)

    -- General
    G_reader_settings:saveSetting("start_with", "filemanager")

    G_reader_settings:saveSetting("simpleui_defaults_v1", true)
end

function M.reset()
    _tabs_cache                  = nil
    _navbar_mode_cache           = nil
    M.wifi_optimistic            = nil
    M.cover_extraction_pending   = false
    _Device                      = nil
    _NetworkMgr                  = nil
    _has_wifi_toggle             = nil
    _topbar_item_labels          = nil
    _SQ3                         = nil
    _lfs_mod                     = nil
    _BookInfoManager             = nil
    _topbar_cfg_menu_cache       = nil
    _ReadCollection              = nil
    -- Clear QA key cache so re-enable starts clean
    for k in pairs(_qa_key_cache) do _qa_key_cache[k] = nil end
    -- Release all cached cover bitmaps (OPT-D)
    M.clearCoverCache()
end

-- ---------------------------------------------------------------------------
-- BookInfoManager — centralised cover cache shared by the Homescreen and
-- collectionswidget.lua, avoiding duplicate discovery logic (fix #17).
-- ---------------------------------------------------------------------------

-- Shared cover-extraction pending flag.
-- Previously each module kept its own flag, causing up to 2 parallel poll
-- timers (60 × 0.5 s each). One centralised flag prevents duplicates.
M.cover_extraction_pending = false

local _BookInfoManager = nil

function M.getBookInfoManager()
    if _BookInfoManager then return _BookInfoManager end
    local ok, bim = pcall(require, "bookinfomanager")
    if ok and bim and type(bim) == "table" and bim.getBookInfo then
        _BookInfoManager = bim; return bim
    end
    ok, bim = pcall(require, "plugins/coverbrowser.koplugin/bookinfomanager")
    if ok and bim and type(bim) == "table" and bim.getBookInfo then
        _BookInfoManager = bim; return bim
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Cover bitmap LRU cache — OPT-D
--
-- getCoverBB always returns a bitmap already scaled to exactly w×h pixels.
-- Previously the raw native bitmap was cached and ImageWidget was asked to
-- scale it on every paint (scale_factor=0). Because each book cover has
-- different native proportions, the scale_factor differed per book and
-- KOReader produced negative initial_offsets (crop), causing distortion.
--
-- Fix: scale once at cache-fill time, store the correctly-sized bitmap,
-- pass it to ImageWidget with scale_factor=1 (no further scaling).
-- The cached bitmaps are now owned by us, so we free them on eviction.
-- ---------------------------------------------------------------------------

local BIM_MAX_COVERS   = 8
local _bim_cover_cache = {}
local _bim_cover_order = {}

local function _bimEvict()
    while #_bim_cover_order > BIM_MAX_COVERS do
        local oldest = table.remove(_bim_cover_order, 1)
        -- Do NOT call bb:free() here. The evicted bitmap may still be
        -- referenced by an ImageWidget in the current widget tree.
        -- clearCoverCache() handles explicit freeing when it is safe to do so
        -- (called from onCloseWidget, after the tree is torn down).
        _bim_cover_cache[oldest] = nil
    end
end

local function _scaleBBToSlot(bb, target_w, target_h)
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not (ok_ri and RenderImage) then return bb end
    local src_w = bb:getWidth()
    local src_h = bb:getHeight()
    if src_w <= 0 or src_h <= 0 then return bb end
    if src_w == target_w and src_h == target_h then return bb end
    local scale_factor = math.min(target_w / src_w, target_h / src_h)
    local scaled_w = math.min(math.floor(src_w * scale_factor + 0.5), target_w)
    local scaled_h = math.min(math.floor(src_h * scale_factor + 0.5), target_h)
    local ok_sc, scaled_bb = pcall(function()
        return RenderImage:scaleBlitBuffer(bb, scaled_w, scaled_h)
    end)
    if not (ok_sc and scaled_bb) then return bb end
    if scaled_w == target_w and scaled_h == target_h then return scaled_bb end
    local ok_blit, Blitbuffer = pcall(require, "ffi/blitbuffer")
    if not (ok_blit and Blitbuffer) then return scaled_bb end
    local ok_slot, slot_bb = pcall(function()
        return Blitbuffer.new(target_w, target_h, scaled_bb:getType())
    end)
    if not (ok_slot and slot_bb) then return scaled_bb end
    pcall(function() slot_bb:fill(Blitbuffer.COLOR_WHITE) end)
    local off_x = math.floor((target_w - scaled_w) / 2)
    local off_y = math.floor((target_h - scaled_h) / 2)
    pcall(function()
        slot_bb:blitFrom(scaled_bb, off_x, off_y, 0, 0, scaled_w, scaled_h)
    end)
    pcall(function() scaled_bb:free() end)
    return slot_bb
end

function M.getCoverBB(filepath, w, h)
    local key    = filepath .. "|" .. w .. "x" .. h
    local cached = _bim_cover_cache[key]
    if cached then
        for i = #_bim_cover_order, 1, -1 do
            if _bim_cover_order[i] == key then
                table.remove(_bim_cover_order, i); break
            end
        end
        _bim_cover_order[#_bim_cover_order + 1] = key
        return cached
    end
    local bim = M.getBookInfoManager()
    if not bim then return nil end
    local ok, bookinfo = pcall(function() return bim:getBookInfo(filepath, true) end)
    if not ok then return nil end
    if bookinfo and bookinfo.cover_fetched and bookinfo.has_cover and bookinfo.cover_bb then
        local bb = _scaleBBToSlot(bookinfo.cover_bb, w, h)
        _bim_cover_cache[key]                   = bb
        _bim_cover_order[#_bim_cover_order + 1] = key
        _bimEvict()
        return bb
    end
    if not M.cover_extraction_pending then
        M.cover_extraction_pending = true
        pcall(function()
            bim:extractInBackground({{
                filepath    = filepath,
                cover_specs = { max_cover_w = w, max_cover_h = h },
            }})
        end)
    end
    return nil
end

-- Releases all cover bitmaps (owned by us — scaled copies).
function M.clearCoverCache()
    for _, bb in pairs(_bim_cover_cache) do
        pcall(function() bb:free() end)
    end
    _bim_cover_cache = {}
    _bim_cover_order = {}
end

-- ---------------------------------------------------------------------------
-- Topbar config cache — shared between topbar.lua and menu.lua so that
-- checked_func callbacks don't rebuild the config table on every render (#16).
-- Invalidated automatically by saveTopbarConfig().
-- ---------------------------------------------------------------------------

local _topbar_cfg_menu_cache = nil

function M.getTopbarConfigCached()
    if not _topbar_cfg_menu_cache then
        _topbar_cfg_menu_cache = M.getTopbarConfig()
    end
    return _topbar_cfg_menu_cache
end

function M.invalidateTopbarConfigCache()
    _topbar_cfg_menu_cache = nil
end
-- ---------------------------------------------------------------------------

local _SQ3     = nil  -- cached ljsqlite3 module
local _lfs_mod = nil  -- cached lfs module

function M.getStatsDbPath()
    return require("datastorage"):getSettingsDir() .. "/statistics.sqlite3"
end

-- Opens a new SQLite connection to the statistics DB.
-- Returns the connection on success, or nil on any failure.
function M.openStatsDB()
    if not _SQ3 then
        local ok, s = pcall(require, "lua-ljsqlite3/init")
        if not ok or not s then return nil end
        _SQ3 = s
    end
    if not _lfs_mod then
        local ok, l = pcall(require, "libs/libkoreader-lfs")
        if not ok or not l then return nil end
        _lfs_mod = l
    end
    local db_path = M.getStatsDbPath()
    if not _lfs_mod.attributes(db_path, "mode") then return nil end
    local ok, conn = pcall(function() return _SQ3.open(db_path) end)
    return ok and conn or nil
end

-- ---------------------------------------------------------------------------
-- Collection helpers
-- ---------------------------------------------------------------------------

local _ReadCollection
function M.getReadCollection()
    if not _ReadCollection then
        local ok, rc = pcall(require, "readcollection")
        if ok then _ReadCollection = rc end
    end
    return _ReadCollection
end

function M.getNonFavoritesCollections()
    local rc = M.getReadCollection()
    if not rc then return {} end
    if rc._read then pcall(function() rc:_read() end) end
    local coll = rc.coll
    if not coll then return {} end
    local fav   = rc.default_collection_name or "favorites"
    local names = {}
    for name in pairs(coll) do
        if name ~= fav then names[#names + 1] = name end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

function M.isFavoritesWidget(w)
    if not w or w.name ~= "collections" then return false end
    local rc = M.getReadCollection()
    if not rc then return false end
    return w.path == rc.default_collection_name
end

return M