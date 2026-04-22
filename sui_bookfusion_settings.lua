-- sui_bookfusion_settings.lua — BookFusion tab settings menu tree
-- -----------------------------------------------------------------------------
-- Returns a single menu-item table that drops into SUI's existing
-- `menu_items.simpleui.sub_item_table` (see sui_menu.lua).  All settings are
-- read via `sui_bookfusion.Settings.*` accessors and written with
-- `G_reader_settings:saveSetting(KEY, v)` using the key constants the accessors
-- already know about — no second layer of state, no migration path to worry
-- about.  Changes repaint the BookFusion tab in place if it's the active
-- widget; otherwise they take effect on the next open.

local _          = require("gettext")
local Device     = require("device")
local Screen     = Device.screen
local SpinWidget = require("ui/widget/spinwidget")
local UIManager  = require("ui/uimanager")

local M = {}

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- Pull the Settings table from sui_bookfusion via the module export.  This
-- module is loaded lazily by sui_menu.lua, well after sui_bookfusion has
-- been required during plugin boot, so `package.loaded` is always populated
-- by the time we need it.
local function BF()   return require("sui_bookfusion") end
local function K(id)  return BF().Settings.KEYS[id]   end
local function S()    return BF().Settings            end

-- Save a setting and, if the BookFusion tab is currently on screen, rebuild
-- it in place so the change takes effect immediately.  When the tab isn't
-- open this is a no-op — the next open reads the fresh value.
local function saveAndRepaint(key, value)
    G_reader_settings:saveSetting(key, value)
    local bf = BF()
    local inst = bf._instance
    if inst and inst._rebuildAndRepaint then
        pcall(function() inst:_rebuildAndRepaint() end)
    end
end

-- Integer spinner with a live accessor for the current value.
-- opts = { text, key, accessor (fn → current int), min, max, default, info }
local function intSpinItem(opts)
    return {
        text_func = function()
            return string.format("%s: %d", opts.text, opts.accessor())
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            UIManager:show(SpinWidget:new{
                title_text      = opts.text,
                info_text       = opts.info,
                value           = opts.accessor(),
                value_min       = opts.min,
                value_max       = opts.max,
                value_step      = 1,
                value_hold_step = 1,
                default_value   = opts.default,
                ok_text         = _("Set"),
                callback        = function(spin)
                    saveAndRepaint(opts.key, spin.value)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

-- Percentage spinner for 0..1 float settings displayed as 60%..160%.
-- opts = { text, key, accessor, min_pct, max_pct, step_pct, default_pct, info }
local function pctSpinItem(opts)
    return {
        text_func = function()
            return string.format("%s: %d%%", opts.text, math.floor(opts.accessor() * 100 + 0.5))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            UIManager:show(SpinWidget:new{
                title_text      = opts.text,
                info_text       = opts.info,
                value           = math.floor(opts.accessor() * 100 + 0.5),
                value_min       = opts.min_pct,
                value_max       = opts.max_pct,
                value_step      = opts.step_pct,
                value_hold_step = opts.step_pct,
                default_value   = opts.default_pct,
                unit            = "%",
                ok_text         = _("Set"),
                callback        = function(spin)
                    saveAndRepaint(opts.key, spin.value / 100)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

-- Default-true checkbox bound to a raw settings key + live accessor.
-- opts = { text, key, accessor (fn → bool) }
local function toggleItem(opts)
    return {
        text           = opts.text,
        keep_menu_open = true,
        checked_func   = function() return opts.accessor() end,
        callback       = function()
            saveAndRepaint(opts.key, not opts.accessor())
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Menu tree
-- ---------------------------------------------------------------------------

-- Title-scale spinner that's gated on a "show title" toggle — extracted
-- because both surfaces (carousel + folder grid) use the same shape.
-- The pctSpinItem helper can't express enabled_func, so we inline the
-- SpinWidget dance here.
local function titleScaleItem(opts)
    return {
        text_func = function()
            return string.format("%s: %d%%", opts.text,
                math.floor(opts.accessor() * 100 + 0.5))
        end,
        keep_menu_open = true,
        enabled_func   = opts.enabled_func,
        callback       = function(touchmenu_instance)
            UIManager:show(SpinWidget:new{
                title_text      = opts.text,
                info_text       = opts.info,
                value           = math.floor(opts.accessor() * 100 + 0.5),
                value_min       = 60,
                value_max       = 160,
                value_step      = 10,
                value_hold_step = 10,
                default_value   = 100,
                unit            = "%",
                ok_text         = _("Set"),
                callback        = function(spin)
                    saveAndRepaint(opts.key, spin.value / 100)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

function M.build()
    return {
        text = _("BookFusion"),
        sub_item_table = {
            -- ============================================================
            -- General — cross-cutting settings that apply to every surface.
            -- ============================================================
            {
                text = _("General"),
                sub_item_table = {
                    toggleItem{
                        text     = _("Uniform covers"),
                        key      = K("UNIFORM_COVERS"),
                        accessor = function() return S().uniformCovers() end,
                    },
                    pctSpinItem{
                        text     = _("Label scale"),
                        key      = K("LABEL_SCALE"),
                        accessor = function() return S().labelScale() end,
                        min_pct = 60, max_pct = 160, step_pct = 10, default_pct = 100,
                        info = _("Scales section headings, folder buttons, page numbers, and empty-state messages.  Does not affect the title bar."),
                    },
                    -- Download indicators — parent/child pair, no
                    -- render path yet.  Child's checked_func returns
                    -- false when the parent is off so the tick visibly
                    -- tracks "will this show on screen?" — raw value is
                    -- preserved so re-enabling restores the prior choice.
                    toggleItem{
                        text     = _("Show download indicator"),
                        key      = K("DL_IND_GLOBAL"),
                        accessor = function() return S().showDownloadIndicators() end,
                    },
                    {
                        text           = _("Show download indicator in search"),
                        keep_menu_open = true,
                        enabled_func   = function() return S().showDownloadIndicators() end,
                        checked_func   = function()
                            return S().showDownloadIndicators() and S().showDownloadIndicatorsSearch()
                        end,
                        callback       = function()
                            G_reader_settings:saveSetting(K("DL_IND_SEARCH"), not S().showDownloadIndicatorsSearch())
                            -- No repaint needed: toggle doesn't affect
                            -- any render path yet.  Swap to
                            -- saveAndRepaint() once it does.
                        end,
                    },
                },
            },
            -- ============================================================
            -- Carousel — landing page's Currently Reading row.
            -- User picks cover size; column count is derived from it and
            -- the available width (see _buildLanding).
            -- ============================================================
            {
                text = _("Carousel"),
                sub_item_table = {
                    pctSpinItem{
                        text     = _("Cover scale"),
                        key      = K("COVER_SCALE_CR"),
                        accessor = function() return S().coverScaleCarousel() end,
                        min_pct = 50, max_pct = 160, step_pct = 10, default_pct = 100,
                        info = _("Smaller covers fit more per row; bigger covers show fewer."),
                    },
                    toggleItem{
                        text     = _("Show book title"),
                        key      = K("SHOW_CR_TITLE"),
                        accessor = function() return S().showCarouselTitle() end,
                    },
                    titleScaleItem{
                        text         = _("Title text scale"),
                        key          = K("TEXT_SCALE_CR"),
                        accessor     = function() return S().textScaleCarousel() end,
                        enabled_func = function() return S().showCarouselTitle() end,
                        info         = _("Scales carousel book titles."),
                    },
                    toggleItem{
                        text     = _("Show progress indicator"),
                        key      = K("SHOW_CR_PROGRESS"),
                        accessor = function() return S().showCarouselProgress() end,
                    },
                    -- Style picker — radio pair.  KOReader TouchMenu
                    -- renders items with `radio = true` using a round
                    -- tick, so the group visually reads as mutually
                    -- exclusive.  Indent + enabled_func makes the pair
                    -- clearly dependent on the on/off toggle above.
                    {
                        text           = _("Progress bar"),
                        radio          = true,
                        keep_menu_open = true,
                        enabled_func   = function() return S().showCarouselProgress() end,
                        checked_func   = function() return S().progressStyleCarousel() == "bar" end,
                        callback       = function()
                            saveAndRepaint(K("CR_PROGRESS_STYLE"), "bar")
                        end,
                    },
                    {
                        text           = _("Percentage overlay"),
                        radio          = true,
                        keep_menu_open = true,
                        enabled_func   = function() return S().showCarouselProgress() end,
                        checked_func   = function() return S().progressStyleCarousel() == "overlay" end,
                        callback       = function()
                            saveAndRepaint(K("CR_PROGRESS_STYLE"), "overlay")
                        end,
                    },
                    toggleItem{
                        text     = _("Show page number"),
                        key      = K("SHOW_CR_PAGER"),
                        accessor = function() return S().showCarouselPager() end,
                    },
                },
            },
            -- ============================================================
            -- Folders — Plan to Read, Favorites, Search grids.
            -- User picks rows × cols; tile size is derived from screen
            -- geometry (no cover-scale knob on this surface).
            -- ============================================================
            {
                text = _("Folders"),
                sub_item_table = {
                    intSpinItem{
                        text     = _("Grid rows"),
                        key      = K("GRID_ROWS"),
                        accessor = function() return S().gridRows() end,
                        min = 1, max = 6, default = 2,
                    },
                    intSpinItem{
                        text     = _("Grid columns"),
                        key      = K("GRID_COLS"),
                        accessor = function() return S().gridCols() end,
                        min = 1, max = 7, default = 4,
                    },
                    toggleItem{
                        text     = _("Show book title"),
                        key      = K("SHOW_FOLDER_TITLE"),
                        accessor = function() return S().showFolderTitle() end,
                    },
                    titleScaleItem{
                        text         = _("Title text scale"),
                        key          = K("TEXT_SCALE_FOLDER"),
                        accessor     = function() return S().textScaleFolder() end,
                        enabled_func = function() return S().showFolderTitle() end,
                        info         = _("Scales folder / search book titles."),
                    },
                },
            },
        },
    }
end

return M
