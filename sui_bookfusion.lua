-- sui_bookfusion.lua — Simple UI / BookFusion tab
-- Native-feeling fullscreen widget that surfaces the user's BookFusion library
-- (Currently Reading carousel, To Be Read & Favorites grid subpages) without
-- duplicating any logic from bookfusion.koplugin — it calls the live BF plugin
-- instance registered on the FileManager under `fm.bookfusion`.
--
-- File layout (sections marked with banners below):
--   1. Settings   — knobs for scale & cols, ready for a future settings UI.
--   2. Cache      — LuaSettings-backed persistence for the three lists.
--   3. Data       — thin shims over fm.bookfusion (api, settings, browser).
--   4. Covers     — in-memory + disk cache + async download of cover_urls.
--   5. Tile       — BookTile InputContainer (cover + title + optional pct).
--   6. Widget     — fullscreen landing + subpages; InputContainer-based.
--   7. Module API — entry point called by sui_bottombar's navigate branch.
--
-- Design (v2, rewritten from the Menu-based v1):
--   • InputContainer subclass mirroring sui_homescreen's pattern: we build
--     our own TitleBar + content FrameContainer, so the whole page fits one
--     screen with no scrolling.  SUI's navbar is still injected automatically
--     thanks to `name = "bookfusion"` being in sui_patches' INJECT_NAMES.
--   • Landing page: header, "Currently Reading" carousel (N-per-page with
--     left/right arrows; full row centred, partial last row left-aligned),
--     "To Be Read" and "Favorites" buttons.
--   • Subpages (TBR / Favorites): grid of cover+title tiles with pagination.
--   • All sizes flow from four scale/count settings so a future settings
--     panel can expose them without touching this file's layout code.
--
-- Later TODOs (out of scope for v2):
--   • Per-book "already downloaded" indicator on tiles.
--   • In-place search on the landing (separate InputDialog flow).
--   • SUI-side settings panel (scale/cols/cache-TTL/list toggles).

local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage     = require("datastorage")
local Device          = require("device")
local Event           = require("ui/event")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local IconButton      = require("ui/widget/iconbutton")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local LuaSettings     = require("luasettings")
local NetworkMgr      = require("ui/network/manager")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local logger          = require("logger")
local _               = require("gettext")

local UI     = require("sui_core")
local Screen = Device.screen

-- Forward-declare so the widget class can reach `M._instance` in onCloseWidget.
local M = {}
M._instance = nil

-- ===========================================================================
-- 1. SETTINGS
-- ---------------------------------------------------------------------------
-- Four tunables exposed via Settings.*; each defaulted in code but ready for a
-- future SUI settings panel.  Using the `navbar_bookfusion_` prefix keeps the
-- keys namespaced alongside the rest of SUI's settings.
-- ===========================================================================

local Settings = {}

local SETK_COVER_SCALE = "navbar_bookfusion_cover_scale"  -- float, 0.6 .. 1.6
local SETK_TEXT_SCALE  = "navbar_bookfusion_text_scale"   -- float, 0.6 .. 1.6
local SETK_CR_COLS     = "navbar_bookfusion_cr_cols"      -- int,   2 .. 6
local SETK_GRID_COLS   = "navbar_bookfusion_grid_cols"    -- int,   2 .. 6

local function _clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function _readNum(key, default, lo, hi)
    local v = G_reader_settings:readSetting(key)
    local n = tonumber(v)
    if not n then return default end
    return _clamp(n, lo, hi)
end

function Settings.coverScale() return _readNum(SETK_COVER_SCALE, 1.0, 0.6, 1.6) end
function Settings.textScale()  return _readNum(SETK_TEXT_SCALE,  1.0, 0.6, 1.6) end
function Settings.crCols()     return math.floor(_readNum(SETK_CR_COLS,   3, 2, 6)) end
function Settings.gridCols()   return math.floor(_readNum(SETK_GRID_COLS, 4, 2, 6)) end

-- ===========================================================================
-- 2. CACHE
-- ---------------------------------------------------------------------------
-- LuaSettings-backed persistence for the three landing lists.  Survives
-- restarts; stored at <DataStorage>/simpleui_bookfusion_cache.lua.
-- Book records are slimmed to only the fields we render or need to delegate
-- back to the BookFusion plugin.
-- ===========================================================================

local Cache = {}

local CACHE_SCHEMA_VERSION = 1
local CACHE_DEFAULT_TTL    = 15 * 60  -- 15 minutes

Cache.LIST_KEYS = { "currently_reading", "planned_to_read", "favorites" }

Cache.LIST_PARAMS = {
    currently_reading = { list = "currently_reading", sort = "last_read_at-desc" },
    planned_to_read   = { list = "planned_to_read" },
    favorites         = { list = "favorites" },
}

local _cache_store

local function _cachePath()
    return DataStorage:getDataDir() .. "/simpleui_bookfusion_cache.lua"
end

local function _cacheOpen()
    if _cache_store then return _cache_store end
    local ok, s = pcall(function() return LuaSettings:open(_cachePath()) end)
    if not ok or not s then
        logger.warn("simpleui-bf cache: open failed:", tostring(s))
        return nil
    end
    _cache_store = s
    if s:readSetting("version") ~= CACHE_SCHEMA_VERSION then
        s:saveSetting("version", CACHE_SCHEMA_VERSION)
    end
    return s
end

local function _cacheSlotKey(k) return "list_" .. k end

function Cache.get(k)
    local s = _cacheOpen()
    if not s then return nil end
    local slot = s:readSetting(_cacheSlotKey(k))
    return type(slot) == "table" and slot or nil
end

function Cache.put(k, books)
    local s = _cacheOpen()
    if not s then return end
    local slim = {}
    if type(books) == "table" then
        for i = 1, #books do
            local b = books[i]
            if type(b) == "table" and b.id then
                -- Raw API shape: `book.cover = { url, width, height }` — see
                -- bookfusion.koplugin/bf_browser.lua:271-280 for reference.
                -- Flatten to our cache row so the widget doesn't have to
                -- re-traverse the nested table on every paint.
                local cover = b.cover
                slim[#slim + 1] = {
                    id         = b.id,
                    title      = b.title,
                    authors    = b.authors,
                    cover_url  = cover and cover.url    or b.cover_url,
                    cover_w    = cover and cover.width  or b.cover_w,
                    cover_h    = cover and cover.height or b.cover_h,
                    percentage = b.percentage,
                    format     = b.format,
                }
            end
        end
    end
    s:saveSetting(_cacheSlotKey(k), { books = slim, fetched_at = os.time() })
    pcall(function() s:flush() end)
end

function Cache.isStale(k, ttl)
    local slot = Cache.get(k)
    if not slot or not slot.fetched_at then return true end
    return (os.time() - slot.fetched_at) > (ttl or CACHE_DEFAULT_TTL)
end

function Cache.clearAll()
    local s = _cacheOpen()
    if not s then return end
    for _i, k in ipairs(Cache.LIST_KEYS) do s:delSetting(_cacheSlotKey(k)) end
    pcall(function() s:flush() end)
end

-- ===========================================================================
-- 3. DATA BRIDGE
-- ---------------------------------------------------------------------------
-- Reaches the live bookfusion.koplugin instance registered on the FM (or RUI)
-- as `.bookfusion` (plugins expose themselves under self.name; see
-- bookfusion/main.lua:6).  Every call pcall-guards so missing plugin =>
-- friendly empty state rather than crash.
--
-- The full BookFusion API contract — every endpoint, request/response shape,
-- pagination rules, and the "watch out for this" traps (nested `cover`,
-- polymorphic `authors`, 4-decimal `percentage`) — is documented in
-- ../BOOKFUSION_API.md (one level above this plugin, in the BookFusion root).
-- Read that before touching any of the Data.* helpers below or the Cache.put
-- flattener above.
-- ===========================================================================

local Data = {}

function Data.getPlugin()
    local FM = package.loaded["apps/filemanager/filemanager"]
    if FM and FM.instance and FM.instance.bookfusion then return FM.instance.bookfusion end
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance and RUI.instance.bookfusion then return RUI.instance.bookfusion end
    return nil
end

function Data.isAvailable() return Data.getPlugin() ~= nil end

function Data.isLinked()
    local p = Data.getPlugin()
    if not p or not p.bf_settings then return false end
    local ok, yes = pcall(function() return p.bf_settings:isLoggedIn() end)
    return ok and yes or false
end

function Data.api() local p = Data.getPlugin(); return p and p.api or nil end

function Data.startLink()
    local p = Data.getPlugin()
    if not p or type(p.onLinkDevice) ~= "function" then return false end
    local ok, err = pcall(function() p:onLinkDevice() end)
    if not ok then logger.warn("simpleui-bf: startLink failed:", tostring(err)) end
    return ok
end

function Data.openBrowser()
    local p = Data.getPlugin()
    if not p or type(p.onSearchBooks) ~= "function" then return false end
    local ok, err = pcall(function() p:onSearchBooks() end)
    if not ok then logger.warn("simpleui-bf: openBrowser failed:", tostring(err)) end
    return ok
end

-- Instantiate a throwaway Browser with the live api+settings so its
-- onSelectBook() (download-or-open) flow runs without owning a visible Menu.
function Data.selectBook(book)
    local p = Data.getPlugin()
    if not p or not book then return false end
    local ok_req, Browser = pcall(require, "bf_browser")
    if not ok_req or not Browser then
        logger.warn("simpleui-bf: bf_browser not reachable")
        return false
    end
    local ok, err = pcall(function()
        local browser = Browser:new(p.api, p.bf_settings)
        browser:onSelectBook(book)
    end)
    if not ok then logger.warn("simpleui-bf: selectBook failed:", tostring(err)) end
    return ok
end

-- Paginate through api:searchBooks until every page is collected, then invoke
-- cb(ok, books) on the main thread.  per_page bigger than bf_browser's 20 to
-- cut round-trips; 200-page safety belt just in case.
local FETCH_PER_PAGE = 50

function Data.fetchListAll(params, cb)
    local api = Data.api()
    if not api then if cb then cb(false, "api_unavailable") end; return end
    UIManager:scheduleIn(0, function()
        local all, page = {}, 1
        while true do
            local q = { page = page, per_page = FETCH_PER_PAGE }
            for k, v in pairs(params or {}) do q[k] = v end
            local ok, books, pagination = api:searchBooks(q)
            if not ok or type(books) ~= "table" then
                if cb then cb(false, books) end; return
            end
            for i = 1, #books do all[#all + 1] = books[i] end
            local total = pagination and pagination.total
            if #books < FETCH_PER_PAGE then break end
            if total and #all >= total then break end
            page = page + 1
            if page > 200 then break end
        end
        if cb then cb(true, all) end
    end)
end

-- ===========================================================================
-- 4. COVERS
-- ---------------------------------------------------------------------------
-- Three-tier cover resolution:
--   L0: in-memory BlitBuffer keyed by (url, w, h)  → instant re-render
--   L1: disk bytes from bookfusion.koplugin/bf_covercache (shared cache
--       reachable via require() thanks to pluginloader adding BF's dir to
--       package.path) → decode + return
--   L2: HTTP fetch via bf_image_loader (async, Trapper subprocess) → on
--       success, write to disk cache and fire callback to repaint.
-- ===========================================================================

local Covers = {}

local _bb_cache = {}  -- key = url  → { bb, w, h }  (BB + its API-reported dims)

-- Try L0 + L1 synchronously; never triggers network.
-- We decode at the API-reported cover_w × cover_h (mirroring bf_listmenu:546-548).
-- This is important: renderImageData without explicit dims returns a BB whose
-- memory is *owned by the JPEG document* (Pic.openJPGDocumentFromData) — when
-- the document goes out of scope the pixel data becomes invalid and the cover
-- paints as solid black.  Passing explicit w×h forces scaleBlitBuffer to
-- allocate a fresh independent BB which we own outright.
function Covers.getBB(url, api_w, api_h)
    if not url or url == "" then return nil end
    local entry = _bb_cache[url]
    if entry then return entry.bb, entry.w, entry.h end
    local ok_cc, CC = pcall(require, "bf_covercache")
    if not ok_cc or not CC then return nil end
    local data = CC.read(url)
    if not data then return nil end
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri or not RenderImage then return nil end

    -- Fall back to a reasonable default if the API didn't supply dims
    -- (typical book cover aspect ≈ 2:3).
    local w = tonumber(api_w) or 400
    local h = tonumber(api_h) or 600
    local ok, new_bb = pcall(function()
        return RenderImage:renderImageData(data, #data, false, w, h)
    end)
    if not ok or not new_bb then return nil end
    new_bb:setAllocated(1)
    _bb_cache[url] = { bb = new_bb, w = w, h = h }
    return new_bb, w, h
end

-- Kick off async fetch for each url not yet on disk.  `on_done(url)` fires on
-- the main thread after each cover is cached — caller repaints the tile.
-- Returns a halt fn that cancels the pending queue.
function Covers.fetchMissing(urls, on_done)
    local ok_cc, CC = pcall(require, "bf_covercache")
    if not ok_cc or not CC then return function() end end
    local missing = {}
    for i = 1, #urls do
        local u = urls[i]
        if u and u ~= "" and not CC.read(u) then missing[#missing + 1] = u end
    end
    if #missing == 0 then return function() end end
    local ok_il, ImageLoader = pcall(require, "bf_image_loader")
    if not ok_il or not ImageLoader then return function() end end
    local _batch, halt = ImageLoader:loadImages(missing, function(url, content)
        if content and #content > 0 then
            CC.write(url, content)
            if on_done then on_done(url) end
        end
    end)
    return halt or function() end
end

-- Drop the BB cache (called on widget close so memory is freed).
function Covers.freeAll()
    for k, entry in pairs(_bb_cache) do
        if entry and entry.bb and type(entry.bb.free) == "function" then
            pcall(entry.bb.free, entry.bb)
        end
        _bb_cache[k] = nil
    end
end

-- ===========================================================================
-- 5. TILE
-- ---------------------------------------------------------------------------
-- BookTile: cover + title + optional progress.  One InputContainer per tile
-- so each tile owns its tap gesture.  Uses a cover thumbnail when available;
-- falls back to a typographic placeholder (first two chars of the title).
-- ===========================================================================

local COLOR_COVER_BORDER = Blitbuffer.gray(0.45)
local COLOR_COVER_BG     = Blitbuffer.gray(0.95)
-- Match module_currently's palette so the progress bar looks identical to
-- the Home tab's Currently Reading card (module_currently.lua:47-49).
local COLOR_BAR_BG       = Blitbuffer.gray(0.15)  -- dark track
local COLOR_BAR_FG       = Blitbuffer.gray(0.75)  -- light fill

-- Grab the first N UTF-8 characters of s (byte-safe).
local function _firstChars(s, n)
    if not s or s == "" then return "?" end
    local out, count, i = {}, 0, 1
    while i <= #s and count < n do
        local byte = s:byte(i)
        local len = byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1
        out[#out + 1] = s:sub(i, i + len - 1)
        count = count + 1
        i = i + len
    end
    return table.concat(out)
end

local function _coverPlaceholder(title, w, h)
    return FrameContainer:new{
        bordersize = 1, color = COLOR_COVER_BORDER,
        background = COLOR_COVER_BG,
        padding = 0, margin = 0,
        dimen = Geom:new{ w = w, h = h },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text = _firstChars(title or "?", 2):upper(),
                face = Font:getFace("smallinfofont", Screen:scaleBySize(20)),
                bold = true,
            },
        },
    }
end

-- Compute a best-fit scale factor from the BB's native dims (bb_w × bb_h)
-- into the display box (max_w × max_h), preserving aspect.  Mirrors
-- bf_listmenu.getCachedCoverSize (bookfusion.koplugin/bf_listmenu.lua:35-46).
local function _bestFitScale(bb_w, bb_h, max_w, max_h)
    local fit_w = math.floor(max_h * bb_w / bb_h + 0.5)
    if max_w >= fit_w then
        return max_w / bb_w  -- height-constrained
    else
        return max_w / bb_w  -- width-constrained (same formula; kept for clarity)
    end
end

local function _coverImage(bb, bb_w, bb_h, box_w, box_h)
    -- Inner box inside the 1px border.
    local inner_w = box_w - 2
    local inner_h = box_h - 2
    local scale   = _bestFitScale(bb_w, bb_h, inner_w, inner_h)
    local ok, img = pcall(function()
        local w = ImageWidget:new{
            image            = bb,
            image_disposable = false,  -- owned by Covers cache; do not free here
            scale_factor     = scale,  -- ≠ 1 → _render() builds a fresh BB
        }
        -- Eagerly render now so the widget is ready to paint (and holds its
        -- own fresh BB, not a reference into the source document's memory).
        w:_render()
        return w
    end)
    if not (ok and img) then return nil end
    local sz = img:getSize()
    return FrameContainer:new{
        bordersize = 1, color = COLOR_COVER_BORDER,
        padding = 0, margin = 0,
        dimen = Geom:new{ w = box_w, h = box_h },
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            FrameContainer:new{
                bordersize = 0, padding = 0, margin = 0,
                width = sz.w, height = sz.h,
                img,
            },
        },
    }
end

-- Title label constrained to `max_lines` rows.  TextBoxWidget supports
-- height-based clipping + ellipsis when text overflows the allotted height
-- (height_overflow_show_ellipsis).  No max_lines attribute exists; we compute
-- the pixel height from font size × line_height × max_lines instead.
local function _titleLabel(title, w, font_size, max_lines)
    local lh_mul  = 1.25  -- approximate TextBoxWidget line pitch
    local line_h  = math.ceil(font_size * lh_mul)
    local max_h   = line_h * (max_lines or 2)
    return TextBoxWidget:new{
        text      = title or _("Untitled"),
        face      = Font:getFace("cfont", font_size),
        width     = w,
        alignment = "center",
        height                         = max_h,
        height_overflow_show_ellipsis  = true,
    }
end

-- Progress bar — structurally identical to module_currently's bar
-- (module_currently.lua:118-127): OverlapGroup stacks a full-width dark
-- "track" LineWidget under a fill-width light "fill" LineWidget.
local function _progressBar(pct, w, h)
    local fill = math.max(0, math.min(1, pct or 0))
    local fw   = math.max(0, math.floor(w * fill))
    if fw <= 0 then
        return LineWidget:new{
            dimen = Geom:new{ w = w, h = h },
            background = COLOR_BAR_BG,
        }
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        LineWidget:new{ dimen = Geom:new{ w = w,  h = h }, background = COLOR_BAR_BG },
        LineWidget:new{ dimen = Geom:new{ w = fw, h = h }, background = COLOR_BAR_FG },
    }
end

local BookTile = InputContainer:extend{}

-- opts = { book, w, h, cover_h, show_progress, on_tap, text_scale }
function BookTile:init()
    local o = self.opts
    local book = o.book or {}
    local w    = o.w
    local h    = o.h
    local cov_w = w
    local cov_h = o.cover_h

    -- Cover (real or placeholder).  Covers.getBB returns the BB plus its
    -- native dims; _coverImage scales best-fit into the tile's cover box.
    local cover
    if book.cover_url and book.cover_url ~= "" then
        local bb, bb_w, bb_h = Covers.getBB(book.cover_url, book.cover_w, book.cover_h)
        if bb then cover = _coverImage(bb, bb_w, bb_h, cov_w, cov_h) end
    end
    if not cover then cover = _coverPlaceholder(book.title, cov_w, cov_h) end

    -- Font sizes — tightened after feedback.  Title = 8px base, scaled by
    -- user's text_scale setting.  Percentage text under the bar was removed
    -- per user spec — just a bare progress bar.
    local txt_sc   = o.text_scale or 1.0
    local title_fs = math.max(8, math.floor(Screen:scaleBySize(8) * txt_sc))

    -- Layout order (per user spec, feedback pass 3):
    --     cover
    --     └─ progress bar (only when show_progress; sits FLUSH under cover)
    --     small gap
    --     title
    --
    -- The bar is visually an extension of the cover so it should butt up
    -- against the cover's bottom edge with no gap in between.
    local vg = VerticalGroup:new{ align = "center" }
    vg[#vg+1] = cover
    if o.show_progress then
        local pct = tonumber(book.percentage) or 0
        -- Bar height matches module_currently (_BASE_BAR_H = 7).
        local bar_h = Screen:scaleBySize(7)
        vg[#vg+1] = _progressBar(pct, w, bar_h)
    end
    vg[#vg+1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
    vg[#vg+1] = _titleLabel(book.title, w, title_fs, 2)

    self.dimen = Geom:new{ w = w, h = h }
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        dimen = Geom:new{ w = w, h = h },
        vg,
    }

    -- Tap gesture: whole tile tappable.  Each BookTile gets its own dimen
    -- closure — OverlapGroup / HorizontalGroup updates self.dimen.x/y at
    -- paint time, so the range function resolves live.
    self.ges_events = {
        TapBookTile = {
            GestureRange:new{
                ges = "tap",
                range = function() return self.dimen end,
            },
        },
    }
end

function BookTile:onTapBookTile()
    if self.opts and type(self.opts.on_tap) == "function" then
        self.opts.on_tap(self.opts.book)
    end
    return true
end

-- ===========================================================================
-- 6. WIDGET
-- ---------------------------------------------------------------------------
-- Fullscreen landing + subpage navigation.
-- ===========================================================================

local BookFusionTab = InputContainer:extend{
    name               = "bookfusion",
    covers_fullscreen  = true,
    is_borderless      = true,
    disable_double_tap = true,
}

function BookFusionTab:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }

    -- View state:
    --   _view        : "landing" | "tbr" | "favorites"
    --   _cr_page     : 1-based carousel page (landing)
    --   _grid_page   : 1-based grid page (subpages)
    --   _progress    : [list_key] = "refreshing" | "error"
    --   _refreshing  : single-flight guard
    --   _cover_halt  : halt fn for current in-flight image-loader batch
    self._view      = self._view      or "landing"
    self._cr_page   = self._cr_page   or 1
    self._grid_page = self._grid_page or 1
    self._progress  = self._progress  or {}

    -- Title bar — rebuilt on every view change in _rebuildAndRepaint so the
    -- left icon reflects the current mode (search on landing, back arrow on
    -- subpages).  SUI's INJECT_NAMES matches our widget.name and
    -- patchUIManagerShow injects the navbar beneath it.
    self.title_bar = self:_buildTitleBar()
    -- Tell sui_titlebar.applyToInjected (sui_titlebar.lua:787) to leave our
    -- bespoke title bar alone — otherwise its inj_right=false default would
    -- zero the right button's dimen and strip our refresh affordance.
    self._titlebar_inj_patched = true

    -- Build the PERSISTENT outer tree once; subsequent rebuilds mutate the
    -- body slot inside `self._body_vg`, so sui_patches' navbar wrap (which
    -- retains a reference to `self[1]` via _navbar_inner) is never torn
    -- down.  Structure:
    --   self[1] = FrameContainer (full screen, white background)
    --     └── self._body_vg = VerticalGroup
    --          ├── [1] = self.title_bar           (fixed)
    --          └── [2] = body widget              (replaced on rebuild)
    self._body_vg    = VerticalGroup:new{ align = "left" }
    self._body_vg[1] = self.title_bar
    self._body_vg[2] = self:_buildBodyContent()
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen      = Geom:new{ w = sw, h = sh },
        self._body_vg,
    }

    -- Block taps/holds that land in the bottom-bar area so they never reach
    -- our content (same pattern as sui_homescreen).
    local bar_y = sh - self:_navbarH()
    local function _inBar(ges) return ges and ges.pos and ges.pos.y >= bar_y end
    self._inBar = _inBar
    self.ges_events = {
        BookFusionTap = {
            GestureRange:new{ ges = "tap",   range = function() return self.dimen end },
        },
        BookFusionHold = {
            GestureRange:new{ ges = "hold",  range = function() return self.dimen end },
        },
    }
end

-- Navbar height probe — Bottombar.TOTAL_H() from sui_bottombar.  Failure-safe
-- so if the module hasn't loaded yet we conservatively assume 0.
function BookFusionTab:_navbarH()
    local BB = package.loaded["sui_bottombar"]
    if BB and BB.TOTAL_H then
        local ok, h = pcall(BB.TOTAL_H); if ok then return h end
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Content builders
-- ---------------------------------------------------------------------------

-- Construct a fresh TitleBar for the current _view.  On the landing page the
-- left icon is "search" (v1: delegates to BF browser).  On subpages it's a
-- back chevron so tapping returns to the landing without having to use the
-- body's sub-header — which previously sat under the search icon's extended
-- tap zone and ate the user's back taps.
--
-- Styling knobs (button_padding, icon_size_ratio, title_top_padding) are
-- chosen to match Menu's title_bar_fm_style defaults (menu.lua:727-733) but
-- with button_padding bumped to 11 (the TitleBar default, not the fm-style 5)
-- so the icons have visible breathing room from the screen edges.
function BookFusionTab:_buildTitleBar()
    local on_landing = (self._view == "landing")
    local title, left_icon, left_cb
    if on_landing then
        title     = _("BookFusion")
        left_icon = "appbar.search"
        left_cb   = function() self:_onLeftIcon() end
    elseif self._view == "tbr" then
        title     = _("To Be Read")
        left_icon = "chevron.left"
        left_cb   = function() self:_exitSubpage() end
    else
        title     = _("Favorites")
        left_icon = "chevron.left"
        left_cb   = function() self:_exitSubpage() end
    end
    return TitleBar:new{
        show_parent              = self,
        fullscreen               = true,
        title                    = title,
        title_top_padding        = Screen:scaleBySize(6),
        button_padding           = Screen:scaleBySize(11),  -- outer edge gap
        left_icon                = left_icon,
        left_icon_size_ratio     = 1,
        left_icon_tap_callback   = left_cb,
        left_icon_hold_callback  = false,
        right_icon               = "cre.render.reload",
        right_icon_size_ratio    = 1,
        right_icon_tap_callback  = function() self:_onRightIcon() end,
        right_icon_hold_callback = false,
    }
end

-- Available area under the title bar, above the SUI navbar.  Safe to call
-- during init() because both TitleBar:getSize and UI.getContentHeight are
-- static computations — neither depends on the navbar wrap having happened.
function BookFusionTab:_contentDimen()
    local sw = Screen:getWidth()
    local title_h = self.title_bar and self.title_bar:getSize().h or 0
    -- UI.getContentHeight() = Screen:getHeight() - navbar - (maybe topbar),
    -- so it already accounts for the SUI chrome below us.
    local widget_h = UI.getContentHeight()
    local body_h = widget_h - title_h
    return sw, title_h, body_h
end

-- Builds just the body widget (no title bar, no outer frame) — what we swap
-- into the stable `self._body_vg[2]` slot on state change.
function BookFusionTab:_buildBodyContent()
    local sw, _title_h, body_h = self:_contentDimen()

    if not Data.isAvailable() then
        return self:_buildEmptyState(sw, body_h,
            _("BookFusion plugin is not installed."),
            _("Install it from the KOReader plugins directory to enable this tab."),
            nil)
    elseif not Data.isLinked() then
        return self:_buildEmptyState(sw, body_h,
            _("Not linked yet."),
            _("Link your BookFusion account to see your library here."),
            { label = _("Link device"), callback = function() Data.startLink() end })
    elseif self._view == "landing" then
        return self:_buildLanding(sw, body_h)
    else
        return self:_buildSubpage(sw, body_h)
    end
end

-- Empty-state panel used for "plugin not installed" / "not linked".
function BookFusionTab:_buildEmptyState(sw, content_h, title, sub, action)
    local inner_w = sw - 2 * UI.SIDE_PAD
    local vg = VerticalGroup:new{ align = "center" }
    vg[#vg+1] = VerticalSpan:new{ width = math.floor(content_h * 0.25) }
    vg[#vg+1] = TextBoxWidget:new{
        text = title, face = Font:getFace("cfont", Screen:scaleBySize(14)),
        width = inner_w, alignment = "center", bold = true,
    }
    vg[#vg+1] = VerticalSpan:new{ width = UI.PAD }
    vg[#vg+1] = TextBoxWidget:new{
        text = sub, face = Font:getFace("cfont", Screen:scaleBySize(11)),
        width = inner_w, alignment = "center",
    }
    if action then
        vg[#vg+1] = VerticalSpan:new{ width = UI.MOD_GAP }
        vg[#vg+1] = Button:new{
            text = action.label,
            width = math.floor(inner_w * 0.6),
            callback = action.callback,
        }
    end
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        dimen = Geom:new{ w = sw, h = content_h },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = content_h },
            vg,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Landing page: Currently Reading carousel + TBR / Favorites buttons.
-- ---------------------------------------------------------------------------
function BookFusionTab:_buildLanding(sw, content_h)
    local inner_w  = sw - 2 * UI.SIDE_PAD
    local txt_sc   = Settings.textScale()
    local cov_sc   = Settings.coverScale()
    local cr_cols  = Settings.crCols()

    -- Section label = subtle, non-bold, slightly smaller ("Currently Reading"
    -- should not compete visually with the covers).  Button label stays
    -- readable.  Both can be tuned via navbar_bookfusion_text_scale.
    local section_fs = math.max(8,  math.floor(Screen:scaleBySize(9)  * txt_sc))
    local button_fs  = math.max(10, math.floor(Screen:scaleBySize(11) * txt_sc))

    -- Fixed-height elements on the landing (top-down), used to compute the
    -- carousel cover height so the page never needs scrolling.
    local section_lbl_h = Screen:scaleBySize(12) + UI.PAD2
    local pre_carousel_gap = UI.PAD               -- breathing room label→covers
    local button_h      = Screen:scaleBySize(36)
    local tile_text_h   = Screen:scaleBySize(22)  -- 2 lines of 8px title
    local tile_pct_h    = Screen:scaleBySize(11)  -- just the 7px bar + gap
    local top_pad       = UI.PAD
    local mid_gap       = UI.MOD_GAP
    local bot_pad       = UI.MOD_GAP              -- generous bottom gap

    -- Height budget left for the carousel row (cover + text + bar).
    local reserved  = top_pad + section_lbl_h + pre_carousel_gap
                    + mid_gap + button_h + UI.PAD + button_h + bot_pad
    local carousel_avail_h = content_h - reserved
    local tile_h = math.max(Screen:scaleBySize(120), carousel_avail_h)
    local cover_h = tile_h - tile_text_h - tile_pct_h - Screen:scaleBySize(8)

    -- Arrow width + gap from the carousel.
    local arrow_w = Screen:scaleBySize(36)
    local arrow_gap = UI.PAD2
    local carousel_inner_w = inner_w - 2 * (arrow_w + arrow_gap)

    -- Tile width from cols.
    local tile_gap = UI.PAD2
    local tile_w = math.floor((carousel_inner_w - (cr_cols - 1) * tile_gap) / cr_cols)
    -- Enforce cover aspect <= 1.55 ratio so wide tiles don't get oversize covers.
    local max_cover_h = math.floor(tile_w * 1.55 * cov_sc)
    if cover_h > max_cover_h then cover_h = max_cover_h end
    if cover_h < Screen:scaleBySize(60) then cover_h = Screen:scaleBySize(60) end

    -- Current-reading books from cache.
    local cr_slot = Cache.get("currently_reading")
    local cr_books = (cr_slot and cr_slot.books) or {}

    -- Pagination for carousel.
    local total_pages = math.max(1, math.ceil(#cr_books / cr_cols))
    if self._cr_page > total_pages then self._cr_page = total_pages end
    if self._cr_page < 1 then self._cr_page = 1 end

    local start_idx = (self._cr_page - 1) * cr_cols + 1
    local end_idx   = math.min(#cr_books, start_idx + cr_cols - 1)
    local visible   = end_idx - start_idx + 1

    -- Build tiles for the current page.
    local tiles = HorizontalGroup:new{ align = "top" }
    for i = start_idx, end_idx do
        if i > start_idx then
            tiles[#tiles+1] = HorizontalSpan:new{ width = tile_gap }
        end
        tiles[#tiles+1] = BookTile:new{
            opts = {
                book          = cr_books[i],
                w             = tile_w,
                h             = tile_h,
                cover_h       = cover_h,
                show_progress = true,
                text_scale    = txt_sc,
                on_tap        = function(b) Data.selectBook(b) end,
            },
        }
    end

    -- Alignment: full row centred, partial row left-aligned.
    local carousel_body
    if visible == cr_cols then
        carousel_body = CenterContainer:new{
            dimen = Geom:new{ w = carousel_inner_w, h = tile_h },
            tiles,
        }
    else
        carousel_body = LeftContainer:new{
            dimen = Geom:new{ w = carousel_inner_w, h = tile_h },
            tiles,
        }
    end

    -- Arrow buttons (disabled-looking when at edges; we simply hide via
    -- a same-sized blank to keep horizontal balance).
    local function _arrow(icon, enabled, cb)
        if not enabled then
            return HorizontalSpan:new{ width = arrow_w }
        end
        return IconButton:new{
            icon        = icon,
            width       = arrow_w,
            height      = arrow_w,
            padding     = 0,
            allow_flash = false,
            callback    = cb,
            show_parent = self,
        }
    end
    local left_arrow  = _arrow("chevron.left",  self._cr_page > 1,          function() self:_cycleCarousel(-1) end)
    local right_arrow = _arrow("chevron.right", self._cr_page < total_pages, function() self:_cycleCarousel( 1) end)

    local carousel_row = HorizontalGroup:new{ align = "center",
        left_arrow,
        HorizontalSpan:new{ width = arrow_gap },
        carousel_body,
        HorizontalSpan:new{ width = arrow_gap },
        right_arrow,
    }

    -- Section label — deliberately subdued: small, non-bold, mid-grey.
    -- It's a signpost, not a headline.
    local SECTION_GRAY = Blitbuffer.gray(0.45)
    local function _sectionLabel(text, note)
        local face = Font:getFace("cfont", section_fs)
        local display = (note and note ~= "") and (text .. "   " .. note) or text
        return LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = section_lbl_h },
            TextWidget:new{
                text    = display,
                face    = face,
                fgcolor = SECTION_GRAY,
            },
        }
    end
    local cr_note
    if self._progress.currently_reading == "refreshing" then
        cr_note = "(" .. _("refreshing…") .. ")"
    elseif self._progress.currently_reading == "error" then
        cr_note = "(" .. _("offline") .. ")"
    end

    -- Nav buttons — borderless (per spec), left-aligned label with a
    -- chevron on the right.  Acts as a big tappable row rather than a
    -- "button" shape.
    local function _navButton(label, badge_count, on_tap)
        local count_text = badge_count and ("  (" .. tostring(badge_count) .. ")") or ""
        return Button:new{
            text           = label .. count_text .. "   ›",
            align          = "left",
            width          = inner_w,
            height         = button_h,
            text_font_size = button_fs,
            text_font_bold = false,
            bordersize     = 0,                -- remove visible border
            background     = Blitbuffer.COLOR_WHITE,
            padding        = Screen:scaleBySize(4),
            callback       = on_tap,
        }
    end

    local tbr_slot    = Cache.get("planned_to_read")
    local fav_slot    = Cache.get("favorites")
    local tbr_count   = tbr_slot and tbr_slot.books and #tbr_slot.books or nil
    local fav_count   = fav_slot and fav_slot.books and #fav_slot.books or nil

    -- Build the page layout.
    local vg = VerticalGroup:new{ align = "left" }
    vg[#vg+1] = VerticalSpan:new{ width = top_pad }
    vg[#vg+1] = _sectionLabel(_("Currently Reading"), cr_note)
    -- Visual breathing room between the subtle label and the cover row.
    vg[#vg+1] = VerticalSpan:new{ width = pre_carousel_gap }
    if #cr_books == 0 then
        -- First-time / after-clear-cache state.  We don't auto-sync (the tab
        -- is fully offline by spec), so nudge the user toward the refresh
        -- icon instead of showing a dead "No books" string.
        local empty_text
        if self._progress.currently_reading == "refreshing" then
            empty_text = _("Loading…")
        elseif Cache.get("currently_reading") == nil then
            empty_text = _("Tap ↻ to sync your BookFusion library.")
        else
            empty_text = _("No books in this list.")
        end
        vg[#vg+1] = LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = tile_h },
            TextBoxWidget:new{
                text = empty_text,
                face = Font:getFace("cfont",
                    math.max(10, math.floor(Screen:scaleBySize(11) * txt_sc))),
                width = inner_w,
            },
        }
    else
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = tile_h },
            carousel_row,
        }
    end
    vg[#vg+1] = VerticalSpan:new{ width = mid_gap }
    vg[#vg+1] = _navButton(_("To Be Read"),  tbr_count, function() self:_enterSubpage("tbr")       end)
    vg[#vg+1] = VerticalSpan:new{ width = UI.PAD }
    vg[#vg+1] = _navButton(_("Favorites"),   fav_count, function() self:_enterSubpage("favorites") end)
    vg[#vg+1] = VerticalSpan:new{ width = bot_pad }

    -- Apply side-padding frame and clamp to content height.
    return FrameContainer:new{
        bordersize = 0, margin = 0,
        padding_left = UI.SIDE_PAD, padding_right = UI.SIDE_PAD,
        padding_top = 0, padding_bottom = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = sw, h = content_h },
        vg,
    }
end

-- ---------------------------------------------------------------------------
-- Subpage: TBR / Favorites grid (covers + names, no progress).
-- ---------------------------------------------------------------------------
function BookFusionTab:_buildSubpage(sw, content_h)
    local inner_w   = sw - 2 * UI.SIDE_PAD
    local txt_sc    = Settings.textScale()
    local cov_sc    = Settings.coverScale()
    local grid_cols = Settings.gridCols()

    -- Pager bar (prev / page / next) pinned at the bottom of the subpage.
    -- The subpage's title + back arrow live in the main TitleBar now, so
    -- there's no sub-header eating vertical space here.
    local pager_h = Screen:scaleBySize(36)

    local books
    if self._view == "tbr" then
        local slot = Cache.get("planned_to_read"); books = (slot and slot.books) or {}
    else
        local slot = Cache.get("favorites");       books = (slot and slot.books) or {}
    end

    -- Compute tile dims from available area minus top gap + pager.
    local grid_h = content_h - pager_h - UI.PAD * 2
    local tile_gap = UI.PAD2
    local row_gap  = UI.PAD
    local tile_w = math.floor((inner_w - (grid_cols - 1) * tile_gap) / grid_cols)
    -- We reserve ~28px below each cover for the title line.
    local title_h_reserve = Screen:scaleBySize(28)
    -- How many rows fit in grid_h given tile_w + aspect + title?
    -- Work out tile_h first:
    local cover_h = math.floor(tile_w * 1.5 * cov_sc)
    local tile_h  = cover_h + Screen:scaleBySize(4) + title_h_reserve
    local rows = math.max(1, math.floor((grid_h + row_gap) / (tile_h + row_gap)))
    if rows < 1 then rows = 1 end
    local per_page = rows * grid_cols

    local total_pages = math.max(1, math.ceil(#books / per_page))
    if self._grid_page > total_pages then self._grid_page = total_pages end
    if self._grid_page < 1 then self._grid_page = 1 end

    local start_idx = (self._grid_page - 1) * per_page + 1
    local end_idx   = math.min(#books, start_idx + per_page - 1)

    -- Build grid rows.
    local grid = VerticalGroup:new{ align = "left" }
    local i = start_idx
    local placed = 0
    while i <= end_idx do
        local row_end = math.min(end_idx, i + grid_cols - 1)
        local row = HorizontalGroup:new{ align = "top" }
        for j = i, row_end do
            if j > i then row[#row+1] = HorizontalSpan:new{ width = tile_gap } end
            row[#row+1] = BookTile:new{
                opts = {
                    book       = books[j],
                    w          = tile_w,
                    h          = tile_h,
                    cover_h    = cover_h,
                    show_progress = false,  -- subpages omit progress per spec
                    text_scale = txt_sc,
                    on_tap     = function(b) Data.selectBook(b) end,
                },
            }
        end
        -- Pad partial last row so left-alignment looks intentional.
        grid[#grid+1] = LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = tile_h },
            row,
        }
        i = row_end + 1
        placed = placed + 1
        if placed < rows and i <= end_idx then
            grid[#grid+1] = VerticalSpan:new{ width = row_gap }
        end
    end
    if #grid == 0 then
        grid[#grid+1] = LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = tile_h },
            TextBoxWidget:new{
                text = _("No books in this list."),
                face = Font:getFace("cfont",
                    math.max(10, math.floor(Screen:scaleBySize(11) * txt_sc))),
                width = inner_w,
            },
        }
    end

    -- Pager: "‹  Page X / Y  ›"
    local function _pagerArrow(icon, enabled, cb)
        if not enabled then return HorizontalSpan:new{ width = Screen:scaleBySize(32) } end
        return IconButton:new{
            icon = icon,
            width = Screen:scaleBySize(32), height = Screen:scaleBySize(32),
            padding = 0, allow_flash = false,
            callback = cb, show_parent = self,
        }
    end
    local pager = HorizontalGroup:new{ align = "center",
        _pagerArrow("chevron.left",  self._grid_page > 1,           function() self:_cyclePage(-1) end),
        HorizontalSpan:new{ width = UI.PAD },
        TextWidget:new{
            text = string.format(_("Page %d / %d"), self._grid_page, total_pages),
            face = Font:getFace("cfont", math.max(10, math.floor(Screen:scaleBySize(11) * txt_sc))),
        },
        HorizontalSpan:new{ width = UI.PAD },
        _pagerArrow("chevron.right", self._grid_page < total_pages, function() self:_cyclePage( 1) end),
    }

    -- Top pad MUST be ≥ icon_size so the first grid row sits below the
    -- title bar's IconButton extended tap zones (padding_bottom = icon_size;
    -- titlebar.lua:381/388).  Otherwise the back-arrow or refresh-icon tap
    -- zone would swallow taps on the top row of covers.
    local vg = VerticalGroup:new{ align = "left" }
    vg[#vg+1] = VerticalSpan:new{ width = Screen:scaleBySize(32) }
    vg[#vg+1] = grid
    vg[#vg+1] = VerticalSpan:new{ width = UI.PAD }
    vg[#vg+1] = CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = pager_h },
        pager,
    }

    return FrameContainer:new{
        bordersize = 0, margin = 0,
        padding_left = UI.SIDE_PAD, padding_right = UI.SIDE_PAD,
        padding_top = 0, padding_bottom = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = sw, h = content_h },
        vg,
    }
end

-- ---------------------------------------------------------------------------
-- State transitions + repaint
-- ---------------------------------------------------------------------------

function BookFusionTab:_rebuildAndRepaint()
    -- Mutate both slots of our persistent VerticalGroup in place — keeps
    -- sui_patches' navbar wrap intact (it references our FrameContainer via
    -- _navbar_inner; we're only changing the FC's VG children).  Rebuilding
    -- the title bar here is what swaps left icon (search ↔ back) on view
    -- transitions.
    if self._body_vg then
        local new_tb = self:_buildTitleBar()
        self.title_bar    = new_tb
        self._body_vg[1]  = new_tb
        self._body_vg[2]  = self:_buildBodyContent()
    end
    UIManager:setDirty(self, "ui")
end

function BookFusionTab:_cycleCarousel(delta)
    self._cr_page = self._cr_page + delta
    self:_rebuildAndRepaint()
end

function BookFusionTab:_cyclePage(delta)
    self._grid_page = self._grid_page + delta
    self:_rebuildAndRepaint()
end

function BookFusionTab:_enterSubpage(which)
    self._view = which
    self._grid_page = 1
    -- Offline by design: render from disk cache only.  Covers that haven't
    -- been downloaded yet show the typographic placeholder; tapping ↻
    -- while on this subpage is how the user opts in to fetching them.
    self:_rebuildAndRepaint()
end

function BookFusionTab:_exitSubpage()
    self._view = "landing"
    self:_rebuildAndRepaint()
end

function BookFusionTab:_onLeftIcon()
    -- v1 behaviour: delegate to BF plugin's own search-capable browser.
    Data.openBrowser()
end

function BookFusionTab:_onRightIcon()
    if not Data.isAvailable() or not Data.isLinked() then
        self:_rebuildAndRepaint()
        return
    end
    self:_refreshLists(true)
end

-- Consume taps/holds in the navbar band so they never reach content tiles.
function BookFusionTab:onBookFusionTap(_args, ges)
    if self._inBar and self._inBar(ges) then return true end
end
function BookFusionTab:onBookFusionHold(_args, ges)
    if self._inBar and self._inBar(ges) then return true end
end

-- ---------------------------------------------------------------------------
-- Refresh + cover prefetch
-- ---------------------------------------------------------------------------

function BookFusionTab:_refreshLists(force)
    if not Data.isLinked() then return end
    if self._refreshing then return end

    -- runWhenOnline prompts the user to turn on Wi-Fi if it's off.  If the
    -- user *cancels* that prompt, our callback is never invoked — so we
    -- MUST NOT commit any state (self._refreshing, self._progress) before
    -- we're inside the callback.  Otherwise the "refreshing…" label would
    -- stay on screen forever and future taps on ↻ would short-circuit via
    -- the `if self._refreshing then return end` guard above.
    NetworkMgr:runWhenOnline(function()
        if self._closed then return end
        self._refreshing = true

        local pending = {}
        for _i, key in ipairs(Cache.LIST_KEYS) do
            if force or Cache.isStale(key) then
                pending[#pending+1] = key
                self._progress[key] = "refreshing"
            end
        end
        if #pending == 0 then
            self._refreshing = false
            return
        end
        self:_rebuildAndRepaint()

        local idx = 0
        local function step()
            idx = idx + 1
            if idx > #pending then
                self._refreshing = false
                self:_prefetchVisibleCovers()
                return
            end
            local key = pending[idx]
            local params = Cache.LIST_PARAMS[key] or { list = key }
            Data.fetchListAll(params, function(ok, books)
                if ok and type(books) == "table" then
                    Cache.put(key, books)
                    self._progress[key] = nil
                else
                    logger.warn("simpleui-bf: fetch failed for", key, tostring(books))
                    self._progress[key] = "error"
                end
                if self._closed then return end
                self:_rebuildAndRepaint()
                step()
            end)
        end
        step()
    end)
end

-- Kick off async downloads for the covers currently on screen.
function BookFusionTab:_prefetchVisibleCovers()
    if self._cover_halt then pcall(self._cover_halt); self._cover_halt = nil end
    local books = {}
    if self._view == "landing" then
        local slot = Cache.get("currently_reading")
        local list = (slot and slot.books) or {}
        for i = 1, #list do books[#books+1] = list[i] end
    else
        local k = (self._view == "tbr") and "planned_to_read" or "favorites"
        local slot = Cache.get(k)
        local list = (slot and slot.books) or {}
        for i = 1, #list do books[#books+1] = list[i] end
    end
    local urls = {}
    for i = 1, #books do
        local u = books[i] and books[i].cover_url
        if u and u ~= "" then urls[#urls+1] = u end
    end
    self._cover_halt = Covers.fetchMissing(urls, function(_url)
        -- A cover landed on disk: repaint (the tile's next build picks it up
        -- via Covers.getBB which now finds it in the cache).
        if self._closed then return end
        self:_rebuildAndRepaint()
    end)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function BookFusionTab:onShow()
    -- The tab is fully offline by design.  Opening it triggers ZERO network
    -- traffic: we render whatever is already in the on-disk list cache and
    -- the on-disk cover cache.  The user explicitly opts in to sync by
    -- tapping the ↻ icon in the title bar, which fires _refreshLists(true)
    -- → pulls fresh list JSON + downloads the current view's missing covers.
    --
    -- Rationale: many BookFusion users read on devices that spend most of
    -- their lives with Wi-Fi off (battery life, airplane mode).  Silent
    -- background syncs would pop the KOReader Wi-Fi prompt every time they
    -- switch to the tab — noisy and surprising.
end

function BookFusionTab:onCloseWidget()
    self._closed = true
    if self._cover_halt then pcall(self._cover_halt); self._cover_halt = nil end
    Covers.freeAll()
    if M._instance == self then M._instance = nil end
end

-- Back gesture closes the tab to the FM underneath.  Inside a subpage, the
-- first Back returns to landing; second Back closes.
function BookFusionTab:onClose()
    if self._view ~= "landing" then
        self:_exitSubpage()
        return true
    end
    UIManager:close(self)
    return true
end

-- ===========================================================================
-- 7. MODULE API  (called by sui_bottombar's navigate branch)
-- ===========================================================================

function M.show(_on_qa_tap)
    if M._instance then
        pcall(function() UIManager:close(M._instance) end)
        M._instance = nil
    end
    local w = BookFusionTab:new{}
    M._instance = w
    UIManager:show(w)
end

function M.close()
    if M._instance then
        pcall(function() UIManager:close(M._instance) end)
        M._instance = nil
    end
end

-- Exposed for debugging / potential future settings UI.
M._Settings = Settings
M._Cache    = Cache
M._Data     = Data
M._Covers   = Covers

return M
