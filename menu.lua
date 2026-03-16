-- menu.lua — Simple UI
-- Builds the full settings submenu registered in the KOReader main menu
-- (Top Bar, Bottom Bar, Quick Actions, Pagination Bar).
-- Returns an installer: require("menu")(plugin) populates plugin.addToMainMenu.

local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local ConfirmBox      = require("ui/widget/confirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local PathChooser     = require("ui/widget/pathchooser")
local SortWidget      = require("ui/widget/sortwidget")
local Device          = require("device")
local Screen          = Device.screen
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local _ = require("gettext")

local Config    = require("config")
local UI        = require("ui")
local Bottombar = require("bottombar")

-- ---------------------------------------------------------------------------
-- Installer function
-- ---------------------------------------------------------------------------

return function(SimpleUIPlugin)

SimpleUIPlugin.addToMainMenu = function(self, menu_items)
    local plugin = self

    -- Local aliases for Config functions.
    local loadTabConfig       = Config.loadTabConfig
    local saveTabConfig       = Config.saveTabConfig
    local getCustomQAList     = Config.getCustomQAList
    local saveCustomQAList    = Config.saveCustomQAList
    local getCustomQAConfig   = Config.getCustomQAConfig
    local saveCustomQAConfig  = Config.saveCustomQAConfig
    local deleteCustomQA      = Config.deleteCustomQA
    local nextCustomQAId      = Config.nextCustomQAId
    local getTopbarConfig     = Config.getTopbarConfig
    local saveTopbarConfig    = Config.saveTopbarConfig
    local _ensureHomePresent  = Config._ensureHomePresent
    local _sanitizeLabel      = Config.sanitizeLabel
    local _homeLabel          = Config.homeLabel
    local _getNonFavoritesCollections = Config.getNonFavoritesCollections
    local ALL_ACTIONS         = Config.ALL_ACTIONS
    local ACTION_BY_ID        = Config.ACTION_BY_ID
    local TOPBAR_ITEMS        = Config.TOPBAR_ITEMS
    local TOPBAR_ITEM_LABEL   = Config.TOPBAR_ITEM_LABEL
    local MAX_CUSTOM_QA       = Config.MAX_CUSTOM_QA
    local CUSTOM_ICON         = Config.CUSTOM_ICON
    local CUSTOM_PLUGIN_ICON  = Config.CUSTOM_PLUGIN_ICON
    local CUSTOM_DISPATCHER_ICON = Config.CUSTOM_DISPATCHER_ICON
    local TOTAL_H             = Bottombar.TOTAL_H
    local MAX_LABEL_LEN       = Config.MAX_LABEL_LEN

    -- Hardware capability — evaluated once per menu session, not per item render.
    -- All pool builders (tabs, position, QA) share this single check so that
    -- "Brightness" appears consistently in every pool on devices that have a
    -- frontlight, and is absent on those that don't.
    local _has_fl = nil
    local function hasFrontlight()
        if _has_fl == nil then
            local ok, v = pcall(function() return Device:hasFrontlight() end)
            _has_fl = ok and v == true
        end
        return _has_fl
    end

    -- Returns true when the given action id should be shown in menus on this device.
    -- Currently only "frontlight" is hardware-gated; all other ids are always shown.
    local function actionAvailable(id)
        if id == "frontlight" then return hasFrontlight() end
        return true
    end

    -- -----------------------------------------------------------------------
    -- Mode radio-item helper
    -- -----------------------------------------------------------------------

    local function modeItem(label, mode_value)
        return {
            text         = label,
            radio        = true,
            checked_func = function() return Config.getNavbarMode() == mode_value end,
            callback     = function()
                G_reader_settings:saveSetting("navbar_mode", mode_value)
                plugin:_scheduleRebuild()
            end,
        }
    end

    -- -----------------------------------------------------------------------
    -- Tab and position menu builders
    -- -----------------------------------------------------------------------

    local function makePositionMenu(pos)
        local items        = {}
        local cached_tabs
        local cached_labels = {}

        local function getTabs()
            if not cached_tabs then cached_tabs = loadTabConfig() end
            return cached_tabs
        end

        local function getResolvedLabel(id)
            if not cached_labels[id] then
                if id:match("^custom_qa_%d+$") then
                    cached_labels[id] = getCustomQAConfig(id).label
                elseif id == "home" then
                    cached_labels[id] = _homeLabel()
                else
                    cached_labels[id] = (ACTION_BY_ID[id] and ACTION_BY_ID[id].label) or id
                end
            end
            return cached_labels[id]
        end

        local pool = {}
        for _i, action in ipairs(ALL_ACTIONS) do
            if actionAvailable(action.id) then pool[#pool + 1] = action.id end
        end
        for _i, qa_id in ipairs(getCustomQAList()) do pool[#pool + 1] = qa_id end

        for _i, id in ipairs(pool) do
            local _id = id
            items[#items + 1] = {
                text_func    = function()
                    local lbl  = getResolvedLabel(_id)
                    local tabs = getTabs()
                    for i, tid in ipairs(tabs) do
                        if tid == _id and i ~= pos then
                            return lbl .. "  (#" .. i .. ")"
                        end
                    end
                    return lbl
                end,
                checked_func = function() return getTabs()[pos] == _id end,
                callback     = function()
                    local tabs    = loadTabConfig()
                    cached_tabs   = nil
                    cached_labels = {}
                    local old_id  = tabs[pos]
                    if old_id == _id then return end
                    tabs[pos] = _id
                    for i, tid in ipairs(tabs) do
                        if i ~= pos and tid == _id then tabs[i] = old_id; break end
                    end
                    _ensureHomePresent(tabs)
                    saveTabConfig(tabs)
                    plugin:_scheduleRebuild()
                end,
            }
        end
        -- Pre-compute sort keys once so text_func is not called O(N log N) times
        -- during the sort comparison (#13).
        for _i, item in ipairs(items) do
            local t = item.text_func()
            item._sort_key = (t:match("^(.-)%s+%(#") or t):lower()
        end
        table.sort(items, function(a, b) return a._sort_key < b._sort_key end)
        for _i, item in ipairs(items) do item._sort_key = nil end
        return items
    end

    local function getActionLabel(id)
        if not id then return "?" end
        if id:match("^custom_qa_%d+$") then return getCustomQAConfig(id).label end
        if id == "home" then return _homeLabel() end
        return (ACTION_BY_ID[id] and ACTION_BY_ID[id].label) or id
    end

    local function makeTabsMenu()
        local items = {}

        items[#items + 1] = {
            text           = _("Arrange tabs"),
            keep_menu_open = true,
            separator      = true,
            callback       = function()
                local tabs       = loadTabConfig()
                local sort_items = {}
                for _i, tid in ipairs(tabs) do
                    sort_items[#sort_items + 1] = { text = getActionLabel(tid), orig_item = tid }
                end
                local sort_widget = SortWidget:new{
                    title             = _("Arrange tabs"),
                    item_table        = sort_items,
                    covers_fullscreen = true,
                    callback          = function()
                        local new_tabs = {}
                        for _i, item in ipairs(sort_items) do new_tabs[#new_tabs + 1] = item.orig_item end
                        _ensureHomePresent(new_tabs)
                        saveTabConfig(new_tabs)
                        plugin:_scheduleRebuild()
                    end,
                }
                UIManager:show(sort_widget)
            end,
        }

        local toggle_items = {}
        local action_pool  = {}
        for _i, action in ipairs(ALL_ACTIONS) do
            if actionAvailable(action.id) then action_pool[#action_pool + 1] = action.id end
        end
        for _i, qa_id in ipairs(getCustomQAList()) do action_pool[#action_pool + 1] = qa_id end

        for _i, aid in ipairs(action_pool) do
            local _aid = aid
            local _base_label = getActionLabel(_aid)
            toggle_items[#toggle_items + 1] = {
                _base        = _base_label,
                text_func    = function()
                    for _i, tid in ipairs(loadTabConfig()) do
                        if tid == _aid then return _base_label end
                    end
                    local rem = Config.MAX_TABS - #loadTabConfig()
                    if rem <= 0 then return _base_label .. "  (0 left)" end
                    if rem <= 2 then return _base_label .. "  (" .. rem .. " left)" end
                    return _base_label
                end,
                checked_func = function()
                    for _i, tid in ipairs(loadTabConfig()) do
                        if tid == _aid then return true end
                    end
                    return false
                end,
                radio    = false,
                callback = function()
                    local tabs       = loadTabConfig()
                    local active_pos = nil
                    for i, tid in ipairs(tabs) do
                        if tid == _aid then active_pos = i; break end
                    end
                    if active_pos then
                        if #tabs <= 2 then
                            UIManager:show(InfoMessage:new{
                                text = _("Minimum 2 tabs required. Select another tab first."), timeout = 2,
                            })
                            return
                        end
                        table.remove(tabs, active_pos)
                    else
                        if #tabs >= Config.MAX_TABS then
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Maximum %d tabs reached. Remove one first."), Config.MAX_TABS), timeout = 2,
                            })
                            return
                        end
                        tabs[#tabs + 1] = _aid
                    end
                    _ensureHomePresent(tabs)
                    saveTabConfig(tabs)
                    plugin:_scheduleRebuild()
                end,
            }
            ::continue_action::
        end
        table.sort(toggle_items, function(a, b) return a._base:lower() < b._base:lower() end)
        for _i, item in ipairs(toggle_items) do items[#items + 1] = item end
        return items
    end

    -- -----------------------------------------------------------------------
    -- Pagination bar menu builder
    -- -----------------------------------------------------------------------

    local function makePaginationBarMenu()
        return {
            {
                text_func    = function()
                    local state = G_reader_settings:nilOrTrue("navbar_pagination_visible") and _("On") or _("Off")
                    return _("Pagination Bar") .. " — " .. state
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("navbar_pagination_visible") end,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("navbar_pagination_visible")
                    G_reader_settings:saveSetting("navbar_pagination_visible", not on)
                    local state_text = on and _("hidden") or _("visible")
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Pagination bar will be %s after restart.\n\nRestart now?"), state_text),
                        ok_text = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            G_reader_settings:flush()
                            local ok_exit, ExitCode = pcall(require, "exitcode")
                            UIManager:quit((ok_exit and ExitCode and ExitCode.restart) or 85)
                        end,
                    })
                end,
            },
            {
                text           = _("Size"),
                sub_item_table = (function()
                    local sizes = {
                        { label = _("Extra Small"), key = "xs" },
                        { label = _("Small"),       key = "s"  },
                        { label = _("Default"),     key = "m"  },
                    }
                    local items = {}
                    for _i, s in ipairs(sizes) do
                        local key = s.key
                        items[#items + 1] = {
                            text         = s.label,
                            checked_func = function()
                                return (G_reader_settings:readSetting("navbar_pagination_size") or "s") == key
                            end,
                            callback     = function()
                                G_reader_settings:saveSetting("navbar_pagination_size", key)
                                UIManager:show(ConfirmBox:new{
                                    text = _("Pagination bar size will change after restart.\n\nRestart now?"),
                                    ok_text = _("Restart"), cancel_text = _("Later"),
                                    ok_callback = function()
                                        G_reader_settings:flush()
                                        local ok_exit, ExitCode = pcall(require, "exitcode")
                                        UIManager:quit((ok_exit and ExitCode and ExitCode.restart) or 85)
                                    end,
                                })
                            end,
                        }
                    end
                    return items
                end)(),
            },
        }
    end

    -- -----------------------------------------------------------------------
    -- Topbar menu builders
    -- -----------------------------------------------------------------------

    local function makeTopbarItemsMenu()
        local items = {}
        items[#items + 1] = {
            text         = _("Swipe Indicator"),
            checked_func = function() return G_reader_settings:nilOrTrue("navbar_topbar_swipe_indicator") end,
            callback = function()
                G_reader_settings:saveSetting("navbar_topbar_swipe_indicator",
                    not G_reader_settings:nilOrTrue("navbar_topbar_swipe_indicator"))
                plugin:_scheduleRebuild()
            end,
            separator = true,
        }

        local sorted_keys = {}
        for _i, k in ipairs(TOPBAR_ITEMS) do sorted_keys[#sorted_keys + 1] = k end
        table.sort(sorted_keys, function(a, b) return TOPBAR_ITEM_LABEL(a):lower() < TOPBAR_ITEM_LABEL(b):lower() end)

        for _i, key in ipairs(sorted_keys) do
            local k = key
            items[#items + 1] = {
                text_func    = function() return TOPBAR_ITEM_LABEL(k) end,
                -- Uses the cached config so opening the menu doesn't rebuild
                -- the config table once per item (#16).
                checked_func = function()
                    return (Config.getTopbarConfigCached().side[k] or "hidden") ~= "hidden"
                end,
                callback = function()
                    -- Reads fresh config for the mutation, then invalidates cache.
                    local cfg = getTopbarConfig()
                    if (cfg.side[k] or "hidden") == "hidden" then
                        local last_side = "right"
                        for _i, v in ipairs(cfg.order_left) do if v == k then last_side = "left"; break end end
                        cfg.side[k] = last_side
                        if last_side == "left" then
                            local found = false
                            for _i, v in ipairs(cfg.order_left) do if v == k then found = true; break end end
                            if not found then cfg.order_left[#cfg.order_left + 1] = k end
                        else
                            local found = false
                            for _i, v in ipairs(cfg.order_right) do if v == k then found = true; break end end
                            if not found then cfg.order_right[#cfg.order_right + 1] = k end
                        end
                    else
                        cfg.side[k] = "hidden"
                    end
                    saveTopbarConfig(cfg)   -- also calls Config.invalidateTopbarConfigCache()
                    plugin:_scheduleRebuild()
                end,
            }
        end
        items[#items].separator = true

        items[#items + 1] = {
            text           = _("Arrange Items"),
            keep_menu_open = true,
            callback       = function()
                local cfg        = getTopbarConfig()
                local SEP_LEFT   = "__sep_left__"
                local SEP_RIGHT  = "__sep_right__"
                local sort_items = {}
                sort_items[#sort_items + 1] = { text = "── " .. _("Left") .. " ──", orig_item = SEP_LEFT, dim = true }
                for _i, key in ipairs(cfg.order_left) do
                    if cfg.side[key] ~= "hidden" then
                        sort_items[#sort_items + 1] = { text = TOPBAR_ITEM_LABEL(key), orig_item = key }
                    end
                end
                sort_items[#sort_items + 1] = { text = "── " .. _("Right") .. " ──", orig_item = SEP_RIGHT, dim = true }
                for _i, key in ipairs(cfg.order_right) do
                    if cfg.side[key] ~= "hidden" then
                        sort_items[#sort_items + 1] = { text = TOPBAR_ITEM_LABEL(key), orig_item = key }
                    end
                end
                UIManager:show(SortWidget:new{
                    title             = _("Arrange Items"),
                    item_table        = sort_items,
                    covers_fullscreen = true,
                    callback          = function()
                        local sep_left_pos, sep_right_pos
                        for j, item in ipairs(sort_items) do
                            if item.orig_item == SEP_LEFT  then sep_left_pos  = j end
                            if item.orig_item == SEP_RIGHT then sep_right_pos = j end
                        end
                        if not sep_left_pos or not sep_right_pos or sep_left_pos > sep_right_pos
                                or (sort_items[1] and sort_items[1].orig_item ~= SEP_LEFT) then
                            UIManager:show(InfoMessage:new{
                                text    = _("Invalid arrangement.\nKeep items between the Left and Right separators."),
                                timeout = 3,
                            })
                            return
                        end
                        local new_left, new_right = {}, {}
                        local current_side = nil
                        for _i, item in ipairs(sort_items) do
                            if     item.orig_item == SEP_LEFT  then current_side = "left"
                            elseif item.orig_item == SEP_RIGHT then current_side = "right"
                            elseif current_side == "left"  then new_left[#new_left + 1] = item.orig_item;  cfg.side[item.orig_item] = "left"
                            elseif current_side == "right" then new_right[#new_right + 1] = item.orig_item; cfg.side[item.orig_item] = "right"
                            end
                        end
                        for _i, key in ipairs(cfg.order_left)  do if cfg.side[key] == "hidden" then new_left[#new_left + 1]   = key end end
                        for _i, key in ipairs(cfg.order_right) do if cfg.side[key] == "hidden" then new_right[#new_right + 1] = key end end
                        cfg.order_left  = new_left
                        cfg.order_right = new_right
                        saveTopbarConfig(cfg)
                        plugin:_scheduleRebuild()
                    end,
                })
            end,
        }
        return items
    end

    local function makeTopbarMenu()
        local function topbarSizeItem(label, key)
            return {
                text         = label,
                radio        = true,
                checked_func = function()
                    return (G_reader_settings:readSetting("navbar_topbar_size") or "default") == key
                end,
                callback = function()
                    G_reader_settings:saveSetting("navbar_topbar_size", key)
                    UI.invalidateDimCache()
                    plugin:_rewrapAllWidgets()
                    local ok_hs, HS = pcall(require, "homescreen")
                    if ok_hs and HS then HS.refresh(true) end
                end,
            }
        end
        return {
            {
                text_func    = function()
                    return _("Top Bar") .. " — " .. (G_reader_settings:nilOrTrue("navbar_topbar_enabled") and _("On") or _("Off"))
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("navbar_topbar_enabled") end,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
                    G_reader_settings:saveSetting("navbar_topbar_enabled", not on)
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Top Bar will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
                        ok_text = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            G_reader_settings:flush()
                            local ok_exit, ExitCode = pcall(require, "exitcode")
                            UIManager:quit((ok_exit and ExitCode and ExitCode.restart) or 85)
                        end,
                    })
                end,
            },
            {
                text = _("Size"),
                sub_item_table = {
                    topbarSizeItem(_("Default"), "default"),
                    topbarSizeItem(_("Large"),   "large"),
                },
            },
            { text = _("Items"), sub_item_table = makeTopbarItemsMenu() },
        }
    end

    -- -----------------------------------------------------------------------
    -- Bottom bar menu builder
    -- -----------------------------------------------------------------------

    local function makeNavbarMenu()
        local function barSizeItem(label, key)
            return {
                text         = label,
                radio        = true,
                checked_func = function()
                    return (G_reader_settings:readSetting("navbar_bar_size") or "default") == key
                end,
                callback = function()
                    G_reader_settings:saveSetting("navbar_bar_size", key)
                    UI.invalidateDimCache()
                    plugin:_rewrapAllWidgets()
                    local ok_hs, HS = pcall(require, "homescreen")
                    if ok_hs and HS then HS.refresh(true) end
                end,
            }
        end
        return {
            {
                text_func    = function()
                    return _("Bottom Bar") .. " — " .. (G_reader_settings:nilOrTrue("navbar_enabled") and _("On") or _("Off"))
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("navbar_enabled") end,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("navbar_enabled")
                    G_reader_settings:saveSetting("navbar_enabled", not on)
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Bottom Bar will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
                        ok_text = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            G_reader_settings:flush()
                            local ok_exit, ExitCode = pcall(require, "exitcode")
                            UIManager:quit((ok_exit and ExitCode and ExitCode.restart) or 85)
                        end,
                    })
                end,
                separator = true,
            },
            {
                text = _("Size"),
                sub_item_table = {
                    barSizeItem(_("Default"), "default"),
                    barSizeItem(_("Compact"), "compact"),
                },
            },
            {
                text = _("Type"),
                sub_item_table = {
                    modeItem(_("Icons") .. " + " .. _("Text"), "both"),
                    modeItem(_("Icons only"),                   "icons"),
                    modeItem(_("Text only"),                    "text"),
                },
            },
            {
                text_func = function()
                    local n = #loadTabConfig()
                    local remaining = Config.MAX_TABS - n
                    if remaining <= 0 then
                        return string.format(_("Tabs  (%d/%d — at limit)"), n, Config.MAX_TABS)
                    end
                    return string.format(_("Tabs  (%d/%d — %d left)"), n, Config.MAX_TABS, remaining)
                end,
                sub_item_table_func = makeTabsMenu,
            },
        }
    end

    plugin._makeNavbarMenu = makeNavbarMenu
    plugin._makeTopbarMenu = makeTopbarMenu

    -- -----------------------------------------------------------------------
    -- Quick Actions
    -- -----------------------------------------------------------------------

    local QA_CUSTOM_ICONS_DIR = "plugins/simpleui.koplugin/icons/custom"

    local function _loadCustomIconList()
        local icons = {}
        local attr  = lfs.attributes(QA_CUSTOM_ICONS_DIR)
        if not attr or attr.mode ~= "directory" then return icons end
        for fname in lfs.dir(QA_CUSTOM_ICONS_DIR) do
            if fname:match("%.[Ss][Vv][Gg]$") or fname:match("%.[Pp][Nn][Gg]$") then
                local path  = QA_CUSTOM_ICONS_DIR .. "/" .. fname
                local label = (fname:match("^(.+)%.[^%.]+$") or fname):gsub("_", " ")
                icons[#icons + 1] = { path = path, label = label }
            end
        end
        table.sort(icons, function(a, b) return a.label:lower() < b.label:lower() end)
        return icons
    end

    local function showIconPicker(current_icon, on_select, default_label)
        local ButtonDialog = require("ui/widget/buttondialog")
        local icons   = _loadCustomIconList()
        local buttons = {}
        local default_marker = (not current_icon) and "  ✓" or ""
        buttons[#buttons + 1] = {{
            text     = (default_label or _("Default (Folder)")) .. default_marker,
            callback = function() UIManager:close(plugin._qa_icon_picker); on_select(nil) end,
        }}
        if #icons == 0 then
            buttons[#buttons + 1] = {{ text = _("No icons found in:") .. "\n" .. QA_CUSTOM_ICONS_DIR, enabled = false }}
        else
            for _i, icon in ipairs(icons) do
                local p = icon
                buttons[#buttons + 1] = {{
                    text     = p.label .. ((current_icon == p.path) and "  ✓" or ""),
                    callback = function() UIManager:close(plugin._qa_icon_picker); on_select(p.path) end,
                }}
            end
        end
        buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(plugin._qa_icon_picker) end }}
        plugin._qa_icon_picker = ButtonDialog:new{ buttons = buttons }
        UIManager:show(plugin._qa_icon_picker)
    end

    local function _scanFMPlugins()
        local fm = plugin.ui
        if not fm then
            local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
            fm = ok_fm and FM and FM.instance
        end
        if not fm then return {} end
        local known = {
            { key = "history",     method = "onShowHist",          title = _("History") },
            { key = "bookinfo",    method = "onShowBookInfo",       title = _("Book Info") },
            { key = "collections", method = "onShowColl",           title = _("Favorites") },
            { key = "collections", method = "onShowCollList",       title = _("Collections") },
            { key = "filesearcher",method = "onShowFileSearch",     title = _("File Search") },
            { key = "folder_shortcuts", method = "onShowFolderShortcutsDialog", title = _("Folder Shortcuts") },
            { key = "dictionary",  method = "onShowDictionaryLookup", title = _("Dictionary Lookup") },
            { key = "wikipedia",   method = "onShowWikipediaLookup", title = _("Wikipedia Lookup") },
        }
        local results = {}
        for _i, entry in ipairs(known) do
            local mod = fm[entry.key]
            if mod and type(mod[entry.method]) == "function" then
                results[#results + 1] = { fm_key = entry.key, fm_method = entry.method, title = entry.title }
            end
        end
        local native_keys = { screenshot=true, menu=true, history=true, bookinfo=true, collections=true,
            filesearcher=true, folder_shortcuts=true, languagesupport=true, dictionary=true, wikipedia=true,
            devicestatus=true, devicelistener=true, networklistener=true }
        local our_name  = plugin.name or "simpleui"
        local seen_keys = {}

        -- Build a value→key reverse map once so the inner lookup is O(1)
        -- instead of O(N) per plugin found (#15).
        local fm_val_to_key = {}
        for k, v in pairs(fm) do
            if type(k) == "string" and type(v) == "table" then
                fm_val_to_key[v] = k
            end
        end

        for i = 1, #fm do
            local val = fm[i]
            if type(val) ~= "table" or type(val.name) ~= "string" then goto cont end
            local fm_key = fm_val_to_key[val]   -- O(1) lookup (#15)
            if not fm_key or native_keys[fm_key] or seen_keys[fm_key] or fm_key == our_name then goto cont end
            if type(val.addToMainMenu) ~= "function" then goto cont end
            seen_keys[fm_key] = true
            local method = nil
            for _i, pfx in ipairs({"onShow","show","open","launch","onOpen"}) do
                if type(val[pfx]) == "function" then method = pfx; break end
            end
            if not method then
                local cap = "on" .. fm_key:sub(1,1):upper() .. fm_key:sub(2)
                if type(val[cap]) == "function" then method = cap end
            end
            if method then
                local raw     = (val.name or fm_key):gsub("^filemanager", "")
                local display = raw:sub(1,1):upper() .. raw:sub(2)
                results[#results + 1] = { fm_key = fm_key, fm_method = method, title = display }
            end
            ::cont::
        end
        table.sort(results, function(a, b) return a.title < b.title end)
        return results
    end

    local function _scanDispatcherActions()
        local ok_d, Dispatcher = pcall(require, "dispatcher")
        if not ok_d or not Dispatcher then return {} end
        pcall(function() Dispatcher:init() end)
        local settingsList, dispatcher_menu_order
        local fn_idx = 1
        while true do
            local name, val = debug.getupvalue(Dispatcher.registerAction, fn_idx)
            if not name then break end
            if name == "settingsList"          then settingsList          = val end
            if name == "dispatcher_menu_order" then dispatcher_menu_order = val end
            fn_idx = fn_idx + 1
        end
        if type(settingsList) ~= "table" then return {} end
        local order = (type(dispatcher_menu_order) == "table" and dispatcher_menu_order)
            or (function() local t = {}; for k in pairs(settingsList) do t[#t+1] = k end; table.sort(t); return t end)()
        local results = {}
        for _i, action_id in ipairs(order) do
            local def = settingsList[action_id]
            if type(def) == "table" and def.title and def.category == "none"
                    and (def.condition == nil or def.condition == true) then
                results[#results + 1] = { id = action_id, title = tostring(def.title) }
            end
        end
        table.sort(results, function(a, b) return a.title < b.title end)
        return results
    end

    -- Full edit dialog for a Quick Action (path / collection / plugin / dispatcher).
    --
    -- All four flows share a single _buildSaveDialog() builder. Each flow only
    -- provides fields, a save_fn, a default icon, and an icon picker label.
    local function showQuickActionDialog(qa_id, on_done)
        local collections = _getNonFavoritesCollections()
        table.sort(collections, function(a, b) return a:lower() < b:lower() end)
        local cfg         = qa_id and getCustomQAConfig(qa_id) or {}
        local start_path  = cfg.path or G_reader_settings:readSetting("home_dir") or "/"
        local chosen_icon = cfg.icon

        local dlg_title = qa_id and _("Edit Quick Action") or _("New Quick Action")

        local function iconButtonLabel(default_lbl)
            if not chosen_icon then return default_lbl or _("Icon: Default") end
            local fname = chosen_icon:match("([^/]+)$") or chosen_icon
            local stem  = (fname:match("^(.+)%.[^%.]+$") or fname):gsub("_", " ")
            return _("Icon") .. ": " .. stem
        end

        local function commitQA(final_label, path, coll, default_icon, fm_key, fm_method, dispatcher_action)
            local final_id = qa_id or nextCustomQAId()
            if not qa_id then
                local list = getCustomQAList()
                list[#list + 1] = final_id
                saveCustomQAList(list)
            end
            saveCustomQAConfig(final_id, final_label, path, coll,
                chosen_icon or default_icon, fm_key, fm_method, dispatcher_action)
            plugin:_rebuildAllNavbars()
            if on_done then on_done() end
        end

        local active_dialog = nil

        local function _buildSaveDialog(spec)
            if active_dialog then UIManager:close(active_dialog); active_dialog = nil end

            local function openIconPicker()
                if active_dialog then UIManager:close(active_dialog); active_dialog = nil end
                showIconPicker(chosen_icon, function(new_icon)
                    chosen_icon = new_icon
                    _buildSaveDialog(spec)
                end, spec.icon_default_label)
            end

            local fields = {}
            for _i, f in ipairs(spec.fields) do
                fields[#fields + 1] = { description = f.description, text = f.text or "", hint = f.hint }
            end

            active_dialog = MultiInputDialog:new{
                title  = dlg_title,
                fields = fields,
                buttons = {
                    { { text = iconButtonLabel(spec.icon_default_label),
                        callback = function() openIconPicker() end } },
                    { { text = _("Cancel"),
                        callback = function() UIManager:close(active_dialog); active_dialog = nil end },
                      { text = _("Save"), is_enter_default = true,
                        callback = function()
                            local inputs = active_dialog:getFields()
                            if spec.validate then
                                local err = spec.validate(inputs)
                                if err then UIManager:show(InfoMessage:new{ text = err, timeout = 3 }); return end
                            end
                            UIManager:close(active_dialog); active_dialog = nil
                            spec.on_save(inputs)
                        end } },
                },
            }
            UIManager:show(active_dialog)
            pcall(function() active_dialog:onShowKeyboard() end)
        end

        local function openPathChooser()
            UIManager:show(PathChooser:new{
                select_directory = true, select_file = false, show_files = false,
                path = start_path, covers_fullscreen = true,
                height = Screen:getHeight() - TOTAL_H(),
                onConfirm = function(chosen_path)
                    _buildSaveDialog({
                        fields = {
                            { description = _("Name"),
                              text = cfg.label or (chosen_path:match("([^/]+)$") or ""),
                              hint = _("e.g. Books…") },
                            { description = _("Folder"), text = chosen_path, hint = "/path/to/folder" },
                        },
                        icon_default_label = _("Default (Folder)"),
                        validate = function(inputs)
                            local p = inputs[2] ~= "" and inputs[2] or chosen_path
                            local attr = lfs.attributes(p)
                            if not attr then return string.format(_("Folder not found:\n%s"), p) end
                            if attr.mode ~= "directory" then return string.format(_("Path is not a folder:\n%s"), p) end
                        end,
                        on_save = function(inputs)
                            local new_path = inputs[2] ~= "" and inputs[2] or chosen_path
                            commitQA(_sanitizeLabel(inputs[1]) or (new_path:match("([^/]+)$") or "?"),
                                new_path, nil, CUSTOM_ICON)
                        end,
                    })
                end,
            })
        end

        local function openCollectionPicker()
            local ButtonDialog = require("ui/widget/buttondialog")
            local buttons = {}
            for _i, coll_name in ipairs(collections) do
                local name = coll_name
                buttons[#buttons + 1] = {{ text = name, callback = function()
                    UIManager:close(plugin._qa_coll_picker)
                    _buildSaveDialog({
                        fields = { { description = _("Name"), text = cfg.label or name, hint = _("e.g. Sci-Fi…") } },
                        icon_default_label = _("Default (Folder)"),
                        on_save = function(inputs)
                            commitQA(_sanitizeLabel(inputs[1]) or name, nil, name, CUSTOM_ICON)
                        end,
                    })
                end }}
            end
            buttons[#buttons + 1] = {{ text = _("Cancel"),
                callback = function() UIManager:close(plugin._qa_coll_picker) end }}
            plugin._qa_coll_picker = ButtonDialog:new{ buttons = buttons }
            UIManager:show(plugin._qa_coll_picker)
        end

        local function openPluginPicker()
            local ButtonDialog   = require("ui/widget/buttondialog")
            local plugin_actions = _scanFMPlugins()
            if #plugin_actions == 0 then
                UIManager:show(InfoMessage:new{ text = _("No plugins found."), timeout = 3 }); return
            end
            local buttons = {}
            table.sort(plugin_actions, function(a, b) return a.title:lower() < b.title:lower() end)
            for _i, a in ipairs(plugin_actions) do
                local _a = a
                buttons[#buttons + 1] = {{ text = _a.title, callback = function()
                    UIManager:close(plugin._qa_plugin_picker)
                    _buildSaveDialog({
                        fields = { { description = _("Name"), text = cfg.label or _a.title, hint = _("e.g. Rakuyomi…") } },
                        icon_default_label = _("Default (Plugin)"),
                        on_save = function(inputs)
                            commitQA(_sanitizeLabel(inputs[1]) or _a.title,
                                nil, nil, CUSTOM_PLUGIN_ICON, _a.fm_key, _a.fm_method, nil)
                        end,
                    })
                end }}
            end
            buttons[#buttons + 1] = {{ text = _("Cancel"),
                callback = function() UIManager:close(plugin._qa_plugin_picker) end }}
            plugin._qa_plugin_picker = ButtonDialog:new{ buttons = buttons }
            UIManager:show(plugin._qa_plugin_picker)
        end

        local function openDispatcherPicker()
            local ButtonDialog = require("ui/widget/buttondialog")
            local actions = _scanDispatcherActions()
            if #actions == 0 then
                UIManager:show(InfoMessage:new{ text = _("No system actions found."), timeout = 3 }); return
            end
            local buttons = {}
            table.sort(actions, function(a, b) return a.title:lower() < b.title:lower() end)
            for _i, a in ipairs(actions) do
                local _a = a
                buttons[#buttons + 1] = {{ text = _a.title, callback = function()
                    UIManager:close(plugin._qa_dispatcher_picker)
                    _buildSaveDialog({
                        fields = { { description = _("Name"), text = cfg.label or _a.title, hint = _("e.g. Sleep, Refresh…") } },
                        icon_default_label = _("Default (System)"),
                        on_save = function(inputs)
                            commitQA(_sanitizeLabel(inputs[1]) or _a.title,
                                nil, nil, CUSTOM_DISPATCHER_ICON, nil, nil, _a.id)
                        end,
                    })
                end }}
            end
            buttons[#buttons + 1] = {{ text = _("Cancel"),
                callback = function() UIManager:close(plugin._qa_dispatcher_picker) end }}
            plugin._qa_dispatcher_picker = ButtonDialog:new{ buttons = buttons }
            UIManager:show(plugin._qa_dispatcher_picker)
        end

        local ButtonDialog = require("ui/widget/buttondialog")
        local choice_dialog
        choice_dialog = ButtonDialog:new{ buttons = {
            {{ text = _("Collection"), enabled = #collections > 0,
               callback = function() UIManager:close(choice_dialog); openCollectionPicker() end }},
            {{ text = _("Folder"),
               callback = function() UIManager:close(choice_dialog); openPathChooser() end }},
            {{ text = _("Plugin"),
               callback = function() UIManager:close(choice_dialog); openPluginPicker() end }},
            {{ text = _("System Actions"),
               callback = function() UIManager:close(choice_dialog); openDispatcherPicker() end }},
            {{ text = _("Cancel"),
               callback = function() UIManager:close(choice_dialog) end }},
        }}
        UIManager:show(choice_dialog)
    end
    local function makeQuickActionsMenu()
        local items   = {}
        local qa_list = getCustomQAList()
        items[#items + 1] = {
            text         = _("Create Quick Action"),
            enabled_func = function() return #getCustomQAList() < MAX_CUSTOM_QA end,
            callback     = function()
                if #getCustomQAList() >= MAX_CUSTOM_QA then
                    UIManager:show(InfoMessage:new{ text = string.format(_("Maximum %d quick actions reached. Delete one first."), MAX_CUSTOM_QA), timeout = 2 })
                    return
                end
                showQuickActionDialog(nil, nil)
            end,
        }
        if #qa_list == 0 then return items end
        items[#items].separator = true

        -- Pre-read all configs once, sort by label, then build menu items.
        -- Avoids calling getCustomQAConfig() O(N log N) times inside the sort
        -- comparator and once more per text_func on initial render (#14).
        local sorted_qa = {}
        for _i, qa_id in ipairs(qa_list) do
            local cfg = getCustomQAConfig(qa_id)
            sorted_qa[#sorted_qa+1] = { id = qa_id, label = cfg.label or qa_id }
        end
        table.sort(sorted_qa, function(a, b) return a.label:lower() < b.label:lower() end)

        for _i, entry in ipairs(sorted_qa) do
            local _id = entry.id
            items[#items + 1] = {
                text_func = function()
                    -- Re-read on each menu open so edits are reflected.
                    local c = getCustomQAConfig(_id)
                    local desc
                    if c.dispatcher_action and c.dispatcher_action ~= "" then desc = "⊕ " .. c.dispatcher_action
                    elseif c.plugin_key and c.plugin_key ~= "" then desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
                    elseif c.collection and c.collection ~= "" then desc = "⊞ " .. c.collection
                    else desc = c.path or _("not configured"); if #desc > 34 then desc = "…" .. desc:sub(-31) end end
                    return c.label .. "  |  " .. desc
                end,
                sub_item_table_func = function()
                    local sub = {}
                    sub[#sub + 1] = {
                        text_func = function()
                            local c = getCustomQAConfig(_id)
                            local desc
                            if c.plugin_key and c.plugin_key ~= "" then desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
                            elseif c.collection and c.collection ~= "" then desc = "⊞ " .. c.collection
                            else desc = c.path or _("not configured"); if #desc > 38 then desc = "…" .. desc:sub(-35) end end
                            return c.label .. "  |  " .. desc
                        end,
                        enabled = false,
                    }
                    sub[#sub + 1] = { text = _("Edit"),   callback = function() showQuickActionDialog(_id, nil) end }
                    sub[#sub + 1] = { text = _("Delete"), callback = function()
                        local c = getCustomQAConfig(_id)
                        UIManager:show(ConfirmBox:new{
                            text        = string.format(_("Delete quick action \"%s\"?"), c.label),
                            ok_text     = _("Delete"), cancel_text = _("Cancel"),
                            ok_callback = function()
                                deleteCustomQA(_id)
                                Config.invalidateTabsCache()
                                plugin:_rebuildAllNavbars()
                            end,
                        })
                    end }
                    return sub
                end,
            }
        end
        return items
    end

    plugin._makeQuickActionsMenu = makeQuickActionsMenu

    local function refreshHomescreen()
        -- Rebuild the widget tree immediately (synchronous) with keep_cache=false
        -- so that book modules (Currently Reading, Recent Books) re-prefetch their
        -- data. Using keep_cache=true would reuse _cached_books_state which was
        -- built before those modules were enabled (with current_fp=nil, recent_fps={})
        -- causing the newly-enabled modules to render empty until the next full open.
        -- Collections and other modules have no per-instance cache so this is a
        -- no-op cost for them.
        --
        -- We also schedule a setDirty via UIManager:nextTick to guarantee a repaint
        -- AFTER the menu widget is removed from the stack. Any setDirty fired while
        -- the menu is open is painted behind it; when the menu closes the UIManager
        -- only repaints the menu frame region, not the full HS. nextTick runs after
        -- the current event's onCloseWidget teardown, so the HS is the top widget
        -- by the time the dirty is processed.
        local HS = package.loaded["homescreen"]
        if not (HS and HS._instance) then return end
        local hs = HS._instance
        hs:_refreshImmediate(false)
        UIManager:nextTick(function()
            if HS._instance == hs and hs._navbar_container then
                UIManager:setDirty(hs, "ui")
            end
        end)
    end

    -- _goalTapCallback: shown when the user taps the Reading Goals widget on
    -- the Homescreen. Lets them set annual/physical goals.
    self._goalTapCallback = function()
        local goal     = G_reader_settings:readSetting("navbar_reading_goal") or 0
        local physical = G_reader_settings:readSetting("navbar_reading_goal_physical") or 0
        local ButtonDialog = require("ui/widget/buttondialog")
        local dlg
        dlg = ButtonDialog:new{ title = _("Annual Reading Goal"), buttons = {
            {{ text = goal > 0 and string.format(_("Digital: %d books in %s"), goal, os.date("%Y")) or string.format(_("Digital Goal  (%s)"), os.date("%Y")),
               callback = function()
                   UIManager:close(dlg)
                   local ok_rg, RG = pcall(require, "readinggoals")
                   if ok_rg and RG then RG.showAnnualGoalDialog(function() refreshHomescreen() end) end
               end }},
            {{ text = string.format(_("Physical: %d books in %s"), physical, os.date("%Y")),
               callback = function()
                   UIManager:close(dlg)
                   local ok_rg, RG = pcall(require, "readinggoals")
                   if ok_rg and RG then RG.showAnnualPhysicalDialog(function() refreshHomescreen() end) end
               end }},
        }}
        UIManager:show(dlg)
    end

    -- -----------------------------------------------------------------------
    -- Shared parametric helpers
    -- All menu-building functions below accept a `ctx` table:
    --   ctx.pfx       — settings key prefix, e.g. "navbar_homescreen_"
    --   ctx.pfx_qa    — QA settings prefix, e.g. "navbar_homescreen_quick_actions_"
    --   ctx.refresh   — zero-arg function to refresh the page after a change
    -- -----------------------------------------------------------------------

    local MAX_QA_ITEMS = 4  -- max actions per QA slot (used by makeQAMenu)

    local HOMESCREEN_CTX = {
        pfx     = "navbar_homescreen_",
        pfx_qa  = "navbar_homescreen_quick_actions_",
        refresh = refreshHomescreen,
    }

    local Registry = require("desktop_modules/moduleregistry")

    -- Returns number of active modules for a given ctx.
    local function countModules(ctx)
        return Registry.countEnabled(ctx.pfx)
    end

    -- getQAPool — builds the list of available actions for Quick Actions menus.
    -- Must be declared before makeQAMenu/makeModulesMenu which use it.
    local function getQAPool()
        local available = {}
        for _i, a in ipairs(ALL_ACTIONS) do
            if actionAvailable(a.id) then
                available[#available+1] = { id = a.id, label = a.id == "home" and Config.homeLabel() or a.label }
            end
        end
        for _i, qa_id in ipairs(getCustomQAList()) do
            local _qid = qa_id
            available[#available+1] = { id = _qid, label = getCustomQAConfig(_qid).label }
        end
        return available
    end

    -- Builds the QA slot sub-menu for a given ctx and slot number.
    local function makeQAMenu(ctx, slot_n)
        local items_key  = ctx.pfx_qa .. slot_n .. "_items"
        local labels_key = ctx.pfx_qa .. slot_n .. "_labels"
        local slot_label = string.format(_("Quick Actions %d"), slot_n)
        local function getItems() return G_reader_settings:readSetting(items_key) or {} end
        local function isSelected(id)
            for _i, v in ipairs(getItems()) do if v == id then return true end end
            return false
        end
        local function toggleItem(id)
            local items = getItems(); local new_items = {}; local found = false
            for _i, v in ipairs(items) do if v == id then found = true else new_items[#new_items+1] = v end end
            if not found then
                if #items >= MAX_QA_ITEMS then
                    UIManager:show(InfoMessage:new{ text = string.format(_("Maximum %d actions per module reached. Remove one first."), MAX_QA_ITEMS), timeout = 2 })
                    return
                end
                new_items[#new_items+1] = id
            end
            G_reader_settings:saveSetting(items_key, new_items); ctx.refresh()
        end
        local sub = {
            { text = _("Show Labels"),
              checked_func = function() return G_reader_settings:nilOrTrue(labels_key) end,
              keep_menu_open = true, callback = function()
                  G_reader_settings:saveSetting(labels_key, not G_reader_settings:nilOrTrue(labels_key)); ctx.refresh()
              end },
            { text = _("Arrange"), keep_menu_open = true, separator = true, callback = function()
                  local qa_ids = getItems()
                  if #qa_ids < 2 then UIManager:show(InfoMessage:new{ text = _("Add at least 2 actions to arrange."), timeout = 2 }); return end
                  local pool_labels = {}; for _i, a in ipairs(getQAPool()) do pool_labels[a.id] = a.label end
                  local sort_items = {}
                  for _i, id in ipairs(qa_ids) do sort_items[#sort_items+1] = { text = pool_labels[id] or id, orig_item = id } end
                  UIManager:show(SortWidget:new{ title = string.format(_("Arrange %s"), slot_label), covers_fullscreen = true, item_table = sort_items,
                      callback = function()
                          local new_order = {}; for _i, item in ipairs(sort_items) do new_order[#new_order+1] = item.orig_item end
                          G_reader_settings:saveSetting(items_key, new_order); ctx.refresh()
                      end })
              end },
        }
        local sorted_pool = {}
        for _i, a in ipairs(getQAPool()) do sorted_pool[#sorted_pool+1] = a end
        table.sort(sorted_pool, function(a, b) return a.label:lower() < b.label:lower() end)
        for _i, a in ipairs(sorted_pool) do
            local aid = a.id; local _lbl = a.label
            sub[#sub+1] = {
                text_func = function()
                    if isSelected(aid) then return _lbl end
                    local rem = MAX_QA_ITEMS - #getItems()
                    if rem <= 0 then return _lbl .. "  (0 left)" end
                    if rem <= 2 then return _lbl .. "  (" .. rem .. " left)" end
                    return _lbl
                end,
                checked_func = function() return isSelected(aid) end,
                keep_menu_open = true, callback = function() toggleItem(aid) end,
            }
        end
        return sub
    end

    -- Builds the full "Modules" sub-menu for a given ctx.
    -- Fully registry-driven: no module ids hardcoded here.
    local function makeModulesMenu(ctx)
        local MAX_MOD      = 3
        local NO_LIMIT_KEY = "navbar_homescreen_no_module_limit"

        local function isUnlimited()
            return G_reader_settings:readSetting(NO_LIMIT_KEY) == true
        end

        local function maxMsg()
            UIManager:show(InfoMessage:new{
                text = string.format(_("Maximum %d modules active. Disable one first."), MAX_MOD), timeout = 2 })
        end

        -- ctx_menu passed to each module's getMenuItems()
        local ctx_menu = {
            pfx           = ctx.pfx,
            pfx_qa        = ctx.pfx_qa,
            refresh       = ctx.refresh,
            UIManager     = UIManager,
            InfoMessage   = InfoMessage,
            SortWidget    = SortWidget,
            _             = _,
            MAX_LABEL_LEN = MAX_LABEL_LEN,
            makeQAMenu    = makeQAMenu,
            _cover_picker = nil,
        }

        local function loadOrder()
            local saved   = G_reader_settings:readSetting(ctx.pfx .. "module_order")
            local default = Registry.defaultOrder()
            if type(saved) ~= "table" or #saved == 0 then return default end
            local seen = {}; local result = {}
            for _loop_, v in ipairs(saved) do seen[v] = true; result[#result+1] = v end
            for _loop_, v in ipairs(default) do if not seen[v] then result[#result+1] = v end end
            return result
        end

        -- Toggle item for one module descriptor.
        -- Persistence is fully delegated to mod.setEnabled(pfx, on).
        local function makeToggleItem(mod)
            local _mod = mod
            return {
                text_func = function()
                    local base = _mod.name
                    if isUnlimited() then return base end
                    if Registry.isEnabled(_mod, ctx.pfx) then return base end
                    local rem = MAX_MOD - countModules(ctx)
                    if rem <= 0 then return base .. "  (0 left)" end
                    if rem <= 2 then return base .. "  (" .. rem .. " left)" end
                    return base
                end,
                checked_func   = function() return Registry.isEnabled(_mod, ctx.pfx) end,
                keep_menu_open = true,
                callback = function()
                    local on = Registry.isEnabled(_mod, ctx.pfx)
                    if not on and not isUnlimited() and countModules(ctx) >= MAX_MOD then maxMsg(); return end
                    if type(_mod.setEnabled) == "function" then
                        _mod.setEnabled(ctx.pfx, not on)
                    elseif _mod.enabled_key then
                        G_reader_settings:saveSetting(ctx.pfx .. _mod.enabled_key, not on)
                    end
                    ctx.refresh()
                end,
            }
        end

        -- Module Settings sub-menu: one entry per module that has getMenuItems.
        -- Count labels are provided by mod.getCountLabel(pfx) — no per-id special cases.
        local function makeModuleSettingsMenu()
            local items    = {}
            local qa_items = {}
            for _loop_, mod in ipairs(Registry.list()) do
                if type(mod.getMenuItems) == "function" then
                    local _mod = mod
                    local text_fn = function()
                        local count_lbl = type(_mod.getCountLabel) == "function"
                            and _mod.getCountLabel(ctx.pfx)
                        return count_lbl
                            and (_mod.name .. "  " .. count_lbl)
                            or   _mod.name
                    end
                    if _mod.id:match("^quick_actions_%d+$") then
                        qa_items[#qa_items + 1] = {
                            text_func           = text_fn,
                            sub_item_table_func = function() return _mod.getMenuItems(ctx_menu) end,
                        }
                    else
                        items[#items + 1] = {
                            text_func           = text_fn,
                            sub_item_table_func = function() return _mod.getMenuItems(ctx_menu) end,
                        }
                    end
                end
            end
            if #qa_items > 0 then
                items[#items + 1] = {
                    text                = _("Quick Actions"),
                    sub_item_table_func = function() return qa_items end,
                }
            end
            return items
        end

        -- Toggle items sorted alphabetically
        local toggles = {}
        for _loop_, mod in ipairs(Registry.list()) do
            toggles[#toggles+1] = makeToggleItem(mod)
        end
        table.sort(toggles, function(a, b)
            local ta = type(a.text_func) == "function" and a.text_func() or (a.text or "")
            local tb = type(b.text_func) == "function" and b.text_func() or (b.text or "")
            return ta:lower() < tb:lower()
        end)

        return {
            {
                text_func = function()
                    local n = countModules(ctx)
                    if isUnlimited() then
                        return string.format(_("Modules  (%d — no limit)"), n)
                    end
                    local rem = MAX_MOD - n
                    if rem <= 0 then return string.format(_("Modules  (%d/%d — at limit)"), n, MAX_MOD) end
                    return string.format(_("Modules  (%d/%d — %d left)"), n, MAX_MOD, rem)
                end,
                sub_item_table_func = function()
                    local result = {
                        {
                            text = _("Arrange Modules"), keep_menu_open = true,
                            callback = function()
                                local order      = loadOrder()
                                local sort_items = {}
                                for _loop_, key in ipairs(order) do
                                    local mod = Registry.get(key)
                                    if mod and Registry.isEnabled(mod, ctx.pfx) then
                                        sort_items[#sort_items+1] = { text = mod.name, orig_item = key }
                                    end
                                end
                                if #sort_items < 2 then
                                    UIManager:show(InfoMessage:new{
                                        text = _("Enable at least 2 modules to arrange."), timeout = 2 })
                                    return
                                end
                                UIManager:show(SortWidget:new{
                                    title = _("Arrange Modules"), item_table = sort_items,
                                    covers_fullscreen = true,
                                    callback = function()
                                        local new_active = {}; local active_set = {}
                                        for _loop_, item in ipairs(sort_items) do
                                            new_active[#new_active+1] = item.orig_item
                                            active_set[item.orig_item] = true
                                        end
                                        for _loop_, k in ipairs(loadOrder()) do
                                            if not active_set[k] then new_active[#new_active+1] = k end
                                        end
                                        G_reader_settings:saveSetting(ctx.pfx.."module_order", new_active)
                                        ctx.refresh()
                                    end,
                                })
                            end,
                        },
                        {
                            text = _("Module Settings"), separator = true,
                            sub_item_table_func = makeModuleSettingsMenu,
                        },
                        {
                            text = _("No Module Limit  ⚠ not recommended"),
                            checked_func = function() return isUnlimited() end,
                            keep_menu_open = true,
                            separator = true,
                            callback = function()
                                local on = isUnlimited()
                                G_reader_settings:saveSetting(NO_LIMIT_KEY, not on)
                                if not on then
                                    UIManager:show(InfoMessage:new{
                                        text = _("Module limit disabled. Enabling too many modules may slow down the homescreen significantly and modules may be clipped at the bottom of the page."),
                                        timeout = 4,
                                    })
                                end
                                ctx.refresh()
                            end,
                        },
                    }
                    for _loop_, t in ipairs(toggles) do result[#result+1] = t end
                    return result
                end,
            },
        }
    end

    -- -----------------------------------------------------------------------
    -- makeHomescreenMenu
    -- -----------------------------------------------------------------------

    local function makeHomescreenMenu()
        local ctx = HOMESCREEN_CTX
        local modules_items = makeModulesMenu(ctx)
        return {
            {
                text_func    = function()
                    local on = G_reader_settings:nilOrTrue("navbar_homescreen_enabled")
                    return _("Home Screen") .. " — " .. (on and _("On") or _("Off"))
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("navbar_homescreen_enabled") end,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("navbar_homescreen_enabled")
                    G_reader_settings:saveSetting("navbar_homescreen_enabled", not on)
                    plugin:_scheduleRebuild()
                end,
            },
            {
                text         = _("Start with Home Screen"),
                checked_func = function()
                    return G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
                    G_reader_settings:saveSetting("start_with", on and "filemanager" or "homescreen_simpleui")
                end,
                separator = true,
            },
            table.unpack(modules_items),
        }
    end



    -- Local helper: updates the active tab in the FileManager bar.
    function setActiveAndRefreshFM(plugin_ref, action_id, tabs)
        plugin_ref.active_action = action_id
        local fm = plugin_ref.ui
        if fm and fm._navbar_container then
            Bottombar.replaceBar(fm, Bottombar.buildBarWidget(action_id, fm._navbar_tabs or tabs), tabs)
            UIManager:setDirty(fm[1], "ui")
        end
        return action_id
    end

    -- -----------------------------------------------------------------------
    -- Main menu entry
    -- -----------------------------------------------------------------------

    -- sorting_hint = "tools" places this entry in the Tools section of the
    -- KOReader main menu (where Statistics, Terminal, etc. live).
    -- Using a dedicated key "simpleui" avoids colliding with the section table.
    --
    -- OPT-H: All sub-menus are now built lazily via sub_item_table_func.
    -- Previously makeNavbarMenu(), makePaginationBarMenu() and makeTopbarMenu()
    -- were called eagerly at registration time, creating hundreds of closures
    -- (checked_func, callback, enabled_func, etc.) even if the user never opens
    -- the menu. With sub_item_table_func the closures are only allocated when
    -- the user actually taps the menu entry.
    menu_items.simpleui = {
        sorting_hint = "tools",
        text = _("Simple UI"),
        sub_item_table = {
            {
                text_func    = function()
                    return _("Simple UI") .. " — " .. (G_reader_settings:nilOrTrue("simpleui_enabled") and _("On") or _("Off"))
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("simpleui_enabled") end,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("simpleui_enabled")
                    G_reader_settings:saveSetting("simpleui_enabled", not on)
                    UIManager:show(ConfirmBox:new{
                        text        = string.format(_("Simple UI will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
                        ok_text     = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            G_reader_settings:flush()
                            local ok_exit, ExitCode = pcall(require, "exitcode")
                            UIManager:quit((ok_exit and ExitCode and ExitCode.restart) or 85)
                        end,
                    })
                end,
                separator = true,
            },
            {
                text               = _("Settings"),
                sub_item_table_func = function()
                    return {
                        { text = _("Bottom Bar"),    sub_item_table_func = makeNavbarMenu },
                        { text = _("Home Screen"),     sub_item_table_func = makeHomescreenMenu },
                        { text = _("Pagination Bar"), sub_item_table_func = makePaginationBarMenu },
                        {
                            text_func = function()
                                local n   = #getCustomQAList()
                                local rem = MAX_CUSTOM_QA - n
                                if n == 0 then return _("Quick Actions") end
                                if rem <= 0 then
                                    return string.format(_("Quick Actions  (%d/%d — at limit)"), n, MAX_CUSTOM_QA)
                                end
                                return string.format(_("Quick Actions  (%d/%d — %d left)"), n, MAX_CUSTOM_QA, rem)
                            end,
                            sub_item_table_func = makeQuickActionsMenu,
                        },
                        { text = _("Top Bar"), sub_item_table_func = makeTopbarMenu },
                    }
                end,
            },
        },
    }
end -- addToMainMenu

end -- installer function