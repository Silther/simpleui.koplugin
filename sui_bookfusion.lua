-- sui_bookfusion.lua — Simple UI / BookFusion tab
-- Native-feeling fullscreen widget that surfaces the user's BookFusion library
-- (Currently Reading carousel, Plan to Read & Favorites grid subpages) without
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
--     "Plan to Read" and "Favorites" buttons.
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

local SETK_COVER_SCALE      = "navbar_bookfusion_cover_scale"       -- float, 0.6 .. 1.6
local SETK_TEXT_SCALE       = "navbar_bookfusion_text_scale"        -- float, 0.6 .. 1.6
local SETK_CR_COLS          = "navbar_bookfusion_cr_cols"           -- int,   2 .. 6
local SETK_GRID_COLS        = "navbar_bookfusion_grid_cols"         -- int,   2 .. 6
local SETK_GRID_ROWS        = "navbar_bookfusion_grid_rows"         -- int,   1 .. 6
-- Search fetch floor: target min books per API call for in-place search.
-- Actual fetch_size rounds up to the nearest multiple of the display grid
-- (grid_rows × grid_cols) so every fetch ends on a clean display-page
-- boundary.  Hidden knob — not exposed in a settings UI.
local SETK_SEARCH_MIN_FETCH = "navbar_bookfusion_search_min_fetch"  -- int,   8 .. 100
-- Uniform covers: when true, every cover renders at the same tile shape by
-- scaling-to-fill + center-cropping overflow.  When false, each cover keeps
-- its native aspect ratio (best-fit + letterbox).  Default true — planned
-- toggle lives under SimpleUI › Library › Uniform covers.
local SETK_UNIFORM_COVERS   = "navbar_bookfusion_uniform_covers"    -- bool

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

function Settings.coverScale()     return _readNum(SETK_COVER_SCALE,     1.0, 0.6, 1.6) end
function Settings.textScale()      return _readNum(SETK_TEXT_SCALE,      1.0, 0.6, 1.6) end
function Settings.crCols()         return math.floor(_readNum(SETK_CR_COLS,          3,  2,   6)) end
function Settings.gridCols()       return math.floor(_readNum(SETK_GRID_COLS,        4,  2,   6)) end
function Settings.gridRows()       return math.floor(_readNum(SETK_GRID_ROWS,        2,  1,   6)) end
function Settings.searchMinFetch() return math.floor(_readNum(SETK_SEARCH_MIN_FETCH, 20, 8, 100)) end
-- Default-true: absent key / nil / truthy → uniform ON; explicit false → OFF.
function Settings.uniformCovers()  return G_reader_settings:nilOrTrue(SETK_UNIFORM_COVERS) end

-- Derived: books per API call for the current search session.
-- Rounds `searchMinFetch()` up to the nearest multiple of the display grid,
-- so every fetched chunk ends on a display-page boundary — we never show
-- "last row has 3 of 8 slots filled, tap › to get the rest".
function Settings.searchFetchSize(per_display_page)
    if not per_display_page or per_display_page < 1 then per_display_page = 1 end
    local min_fetch = Settings.searchMinFetch()
    return math.max(1, math.ceil(min_fetch / per_display_page)) * per_display_page
end

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
                    id            = b.id,
                    title         = b.title,
                    authors       = b.authors,
                    cover_url     = cover and cover.url    or b.cover_url,
                    cover_w       = cover and cover.width  or b.cover_w,
                    cover_h       = cover and cover.height or b.cover_h,
                    percentage    = b.percentage,
                    format        = b.format,
                    -- Preserved so bf_downloader.downloadBook can render its
                    -- "13.0 MB" subtitle and drive the progress bar — without
                    -- it the popup degrades to just a "Downloading …" line.
                    download_size = b.download_size,
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

-- Open the BookFusion plugin's native browser popup.
--
-- We build the Browser ourselves instead of calling `p:onSearchBooks()`:
-- the BF plugin's method constructs a fresh `Browser` local to the
-- function and drops the reference on return, relying on Lua's GC to keep
-- the instance alive via the closures captured inside `browser._menu`.
-- That worked fine for BF's own tools-menu entry (the tools menu closes
-- before the browser opens, so there are no live competing widgets) but
-- reliably dropped the popup when invoked from inside our BookFusionTab's
-- button callback — the browser was getting collected before its menu
-- could paint.  Holding the Browser on our module upvalue fixes it and
-- still cleans up on next open (or when the user closes our tab) because
-- the close_callback nils self._menu / we overwrite the reference here.
local _bf_browser_instance = nil
function Data.openBrowser()
    local p = Data.getPlugin()
    if not p or not p.api or not p.bf_settings then return false end
    local ok_req, Browser = pcall(require, "bf_browser")
    if not ok_req or not Browser then
        logger.warn("simpleui-bf: bf_browser not reachable")
        return false
    end
    -- Deferred by one UI tick so the button's flash/unhighlight refresh
    -- finishes before the popup's setDirty lands in the queue.
    UIManager:scheduleIn(0, function()
        local ok, err = pcall(function()
            _bf_browser_instance = Browser:new(p.api, p.bf_settings)
            _bf_browser_instance:show()
        end)
        if not ok then
            logger.warn("simpleui-bf: openBrowser failed:", tostring(err))
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = "BookFusion browse error:\n" .. tostring(err),
                timeout = 5,
            })
        end
    end)
    return true
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

function Data.fetchListAll(params, cb, opts)
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

        -- Optional progress enrichment: `/books/search` doesn't return
        -- reading progress (only book metadata), so when the caller needs
        -- it (e.g. Currently Reading) we follow up with one
        -- `api:getReadingPosition(id)` per book and attach `.percentage`
        -- as a 0..1 fraction (server sends 0..100.0000).  404 is
        -- whitelisted inside bf_api → (ok=true, data=nil) meaning "no
        -- remote position yet" → we simply leave percentage nil.
        --
        -- Cost: N serial HTTP GETs.  Acceptable for Currently Reading
        -- (usually ≤10 books); don't enable this for TBR / Favourites
        -- where we wouldn't render the bar anyway.
        if opts and opts.with_progress then
            for i = 1, #all do
                local b = all[i]
                if b and b.id then
                    local ok_p, pos = pcall(function()
                        local ok_r, data = api:getReadingPosition(b.id)
                        return ok_r and data or nil
                    end)
                    if ok_p and type(pos) == "table" then
                        local pct = tonumber(pos.percentage)
                        if pct then b.percentage = pct / 100 end
                    end
                end
            end
        end

        if cb then cb(true, all) end
    end)
end

-- Single-page search fetch.
--
-- Used by the in-place search flow, which — unlike `fetchListAll` — needs
-- to paginate ONE page at a time so the first results paint as soon as
-- possible and we don't over-fetch when the user only looks at page 1.
--
-- cb signature: `cb(ok, books, pagination)`
--   books      = Book[] (array) for this API page
--   pagination = { page, per_page, total } from the response headers
-- Deferred via scheduleIn(0, ...) so the caller's UI update (popup, etc.)
-- can paint before the HTTP round-trip blocks.
function Data.searchPage(query, api_page, per_page, cb)
    local api = Data.api()
    if not api then if cb then cb(false, "api_unavailable") end; return end
    UIManager:scheduleIn(0, function()
        local ok, books, pagination = api:searchBooks({
            query    = query,
            page     = api_page,
            per_page = per_page,
        })
        if not ok then if cb then cb(false, books) end; return end
        if cb then cb(true, books, pagination) end
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
--
-- TODO (cover loading reliability): bf_image_loader uses Trapper's
-- `dismissableRunInSubprocess`, so any user input during a sync kills the
-- in-flight download and the URL stays un-cached.  If the user keeps tapping
-- across refreshes, the same covers never land on disk and stay as
-- placeholders.  Needs a fix later — either make the sync non-dismissable,
-- or retry the dismissed URLs automatically on the next _prefetchVisibleCovers
-- pass instead of relying on the user to trigger another manual refresh.
-- ===========================================================================

local Covers = {}

local _bb_cache = {}  -- key = url  → { bb, w, h }

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

    -- Fall back to a reasonable default if the API didn't supply dims OR
    -- supplied something invalid (0, negative, or non-number).  Some books
    -- in the BookFusion catalogue really do ship with cover.width = 0 in
    -- the API response; `tonumber()` alone doesn't catch that, and passing
    -- 0 to scaleBlitBuffer produces a zero-pixel BB that paints solid black.
    local w = tonumber(api_w)
    local h = tonumber(api_h)
    if not w or w <= 0 then w = 400 end
    if not h or h <= 0 then h = 600 end

    local ok, new_bb = pcall(function()
        return RenderImage:renderImageData(data, #data, false, w, h)
    end)
    if not ok or not new_bb then return nil end
    new_bb:setAllocated(1)

    -- Use the BB's ACTUAL dimensions, not the values we asked for.  The
    -- decoders don't all honour the hint exactly (MuPDF / WebP / GifLib
    -- can return slightly different sizes), and downstream _bestFitScale
    -- needs the real dims to compute a correct scale factor.
    local actual_w = new_bb:getWidth()  or w
    local actual_h = new_bb:getHeight() or h
    if actual_w <= 0 or actual_h <= 0 then
        pcall(function() new_bb:free() end)
        return nil
    end

    _bb_cache[url] = { bb = new_bb, w = actual_w, h = actual_h }
    return new_bb, actual_w, actual_h
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

local COLOR_COVER_BORDER = Blitbuffer.COLOR_BLACK
local COVER_BORDER_SIZE  = 2  -- px; bumped from 1 for a slightly stronger outline
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
    -- Inner size must account for the 1px border so the FrameContainer's
    -- actual rendered outer size matches `w × h` exactly.  (FrameContainer
    -- computes its size as content_size + 2*bordersize.)  Using `w × h` for
    -- the CenterContainer's dimen would make the placeholder 2px wider and
    -- 2px taller than a real cover, causing subtle misalignment.
    local bw = COVER_BORDER_SIZE
    return FrameContainer:new{
        bordersize = bw, color = COLOR_COVER_BORDER,
        background = COLOR_COVER_BG,
        padding = 0, margin = 0,
        dimen = Geom:new{ w = w, h = h },
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * bw, h = h - 2 * bw },
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
--
-- fit_w is how wide the image would be if we scaled it to fill max_h.
-- If that width still fits within max_w, we're height-constrained → scale
-- by height (max_h / bb_h).  Otherwise we're width-constrained → scale by
-- width (max_w / bb_w).  Earlier versions had a typo that returned the
-- width-based factor in both branches, which let portrait covers overflow
-- their tile_h and bleed into the row below.
local function _bestFitScale(bb_w, bb_h, max_w, max_h)
    local fit_w = math.floor(max_h * bb_w / bb_h + 0.5)
    if max_w >= fit_w then
        return max_h / bb_h   -- height is the limiting axis
    else
        return max_w / bb_w   -- width is the limiting axis
    end
end

-- Cover-fill scale (the max of h and w ratios): the BB is sized so the
-- SHORTER axis matches the box exactly, guaranteeing the longer axis
-- overflows.  Combined with ImageWidget's width/height + center_x/y_ratio
-- cropping, this yields uniform tile shapes with the centered part of the
-- cover visible — the standard "cover" behaviour in CSS object-fit terms.
local function _coverFillScale(bb_w, bb_h, max_w, max_h)
    return math.max(max_w / bb_w, max_h / bb_h)
end

-- Build the cover widget AND report its actual rendered outer size (including
-- the 1px border on each side).  The caller (BookTile) uses this width so the
-- progress bar ends up exactly under the visible cover — no letterbox gap.
--
-- Two modes, chosen by Settings.uniformCovers():
--   • uniform = true  (default)  → scale-to-fill + centre-crop.  Every tile
--     is exactly box_w × box_h; box sets / landscape covers lose their edges
--     but the grid looks consistent.
--   • uniform = false             → best-fit + letterbox.  Each cover keeps
--     its native aspect, so shapes in the grid vary.
--
-- Returns: widget, actual_w, actual_h  (scaled-image + 2*border dims)
local function _coverImage(bb, bb_w, bb_h, box_w, box_h)
    -- Inner box inside the border on both sides.
    local inner_w = box_w - 2 * COVER_BORDER_SIZE
    local inner_h = box_h - 2 * COVER_BORDER_SIZE
    local uniform = Settings.uniformCovers()
    local bw = COVER_BORDER_SIZE

    if uniform then
        -- Scale-to-fill: ImageWidget with scale_factor = cover-fill grows
        -- the BB past inner_w × inner_h, then paints only the centred
        -- (inner_w × inner_h) region thanks to width/height + default
        -- center_x/y_ratio = 0.5 (imagewidget.lua:347-370, paintTo uses
        -- _offset_x/y to blit the cropped region).
        local scale = _coverFillScale(bb_w, bb_h, inner_w, inner_h)
        local ok, img = pcall(function()
            local w = ImageWidget:new{
                image            = bb,
                image_disposable = false,   -- owned by Covers cache
                scale_factor     = scale,
                width            = inner_w, -- paint-area — crops overflow
                height           = inner_h,
            }
            w:_render()
            return w
        end)
        if not (ok and img) then return nil, box_w, box_h end
        local frame = FrameContainer:new{
            bordersize = bw, color = COLOR_COVER_BORDER,
            padding = 0, margin = 0,
            dimen = Geom:new{ w = box_w, h = box_h },
            img,
        }
        return frame, box_w, box_h
    end

    -- Best-fit / letterbox mode — preserves native aspect ratio.
    local scale = _bestFitScale(bb_w, bb_h, inner_w, inner_h)
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
    if not (ok and img) then return nil, box_w, box_h end
    local sz = img:getSize()
    -- Frame hugs the scaled image: no CenterContainer, no letterbox whitespace.
    -- Tile VerticalGroup(align="center") centers this frame + the progress bar
    -- within the tile column, keeping them perfectly stacked.
    local actual_w = sz.w + 2 * bw  -- border on both sides
    local actual_h = sz.h + 2 * bw
    local frame = FrameContainer:new{
        bordersize = bw, color = COLOR_COVER_BORDER,
        padding = 0, margin = 0,
        dimen = Geom:new{ w = actual_w, h = actual_h },
        img,
    }
    return frame, actual_w, actual_h
end

-- Title label constrained to 2 rows.  TextBoxWidget has no native max_lines;
-- we size `height` to fit exactly 2 lines and let height_overflow_show_ellipsis
-- truncate a third line with "…".
--
-- Gotcha: `Font:getFace(name, size)` itself runs the size through
-- `Screen:scaleBySize` (font.lua:276) before handing it to FreeType.  If the
-- caller already pre-scaled the size (as we do — title_fs = scaleBySize(6))
-- the resulting `face.size` is *double*-scaled.  TextBoxWidget then computes
-- `line_height_px = round((1 + 0.3) * face.size)` (textboxwidget.lua:147), so
-- our height has to be derived from `face.size`, not the pre-scale `size` we
-- requested — otherwise on a high-DPI device `floor(height / line_height_px)`
-- falls to 1 and every title is truncated to a single line.  Computing
-- `line_h` from the built face (and adding a 1 px rounding margin) makes the
-- 2-row layout work regardless of the device's scale factor.
local function _titleLabel(title, w, font_size, lines)
    lines = lines or 2
    local face   = Font:getFace("cfont", font_size)
    local line_h = math.floor((1 + 0.3) * face.size + 0.5)
    return TextBoxWidget:new{
        text                          = title or _("Untitled"),
        face                          = face,
        width                         = w,
        alignment                     = "center",
        height                        = line_h * lines + 1,
        height_overflow_show_ellipsis = true,
    }
end

-- Progress bar — same shape as the home screen's "simple" bar style
-- (desktop_modules/module_books_shared.SH.progressBar): OverlapGroup stacks
-- a full-width dark track LineWidget under a fill-width light LineWidget.
-- No inline percentage label — user wants just the bar.
local BAR_BASE_H = Screen:scaleBySize(7)

local function _progressBar(pct, w)
    local bar_h = BAR_BASE_H
    local fill  = math.max(0, math.min(1, pct or 0))
    local fw    = math.max(0, math.floor(w * fill))
    if fw <= 0 then
        return LineWidget:new{
            dimen = Geom:new{ w = w, h = bar_h },
            background = COLOR_BAR_BG,
        }
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = bar_h },
        LineWidget:new{ dimen = Geom:new{ w = w,  h = bar_h }, background = COLOR_BAR_BG },
        LineWidget:new{ dimen = Geom:new{ w = fw, h = bar_h }, background = COLOR_BAR_FG },
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

    -- Cover (real or placeholder).  _coverImage returns the widget PLUS its
    -- actual rendered width/height (post best-fit scaling, including the 1px
    -- border on each side).  We use that actual width for the progress bar
    -- so it sits flush under the visible cover.  Placeholder covers fill the
    -- whole box, so actual_w falls back to cov_w in that branch.
    local cover, actual_w
    if book.cover_url and book.cover_url ~= "" then
        local bb, bb_w, bb_h = Covers.getBB(book.cover_url, book.cover_w, book.cover_h)
        if bb then cover, actual_w = _coverImage(bb, bb_w, bb_h, cov_w, cov_h) end
    end
    if not cover then
        cover    = _coverPlaceholder(book.title, cov_w, cov_h)
        actual_w = cov_w
    end

    -- Font sizes.  Title = 6px base (slightly smaller so longer titles can
    -- wrap onto a second line without blowing the tile height budget).
    -- Scaled by the user's text_scale setting.  No percentage text under
    -- the bar — the bar itself is the progress indicator per user spec.
    local txt_sc   = o.text_scale or 1.0
    local title_fs = math.max(6, math.floor(Screen:scaleBySize(6) * txt_sc))

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
        -- Cover→bar gap: 4px at base scale (tighter than the home screen's
        -- 6px because there's no author-descender above the bar here).
        vg[#vg+1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
        -- Bar width = cover's actual rendered width (after best-fit scaling),
        -- so it lines up perfectly under the visible cover even when the book
        -- cover's aspect ratio differs from the tile box's aspect.
        vg[#vg+1] = _progressBar(pct, actual_w)
    end
    vg[#vg+1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
    -- Title uses the full tile width so long titles can wrap/ellipse nicely
    -- across the tile rather than being cramped under a narrower cover.
    -- opts.title_lines lets callers pick 1 (subpage grids) or 2 (carousel);
    -- default is 2 so existing callers that don't set it keep the old behaviour.
    vg[#vg+1] = _titleLabel(book.title, w, title_fs, o.title_lines or 2)

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
    -- Signal to UIManager:setDirty that this widget contains cover art
    -- (photographs with many greyscale levels).  Without this, the initial
    -- "ui" refresh uses a bi-level pass and covers look washed out for up
    -- to ~30 s until the next full refresh.  Same hint sui_homescreen sets
    -- via `self.dithered = page_has_covers` (sui_homescreen.lua:2289).
    dithered           = true,
}

function BookFusionTab:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }

    -- View state:
    --   _view        : "landing" | "tbr" | "favorites"
    --   _cr_page     : 1-based carousel page (landing)
    --   _grid_page   : 1-based grid page (subpages)
    --   _refreshing  : single-flight guard
    --   _sync_popup  : InfoMessage shown during a manual sync (or nil)
    --   _cover_halt  : halt fn for current in-flight image-loader batch
    self._view      = self._view      or "landing"
    self._cr_page   = self._cr_page   or 1
    self._grid_page = self._grid_page or 1

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
    -- Title always reads "BookFusion" (app name — same pattern as the FM's
    -- fixed "Library" title).  The subtitle carries the navigation
    -- context: "Plan to Read" / "Favorites" / "Search: <query>", and is
    -- empty on the landing view.  Keeping the app name fixed at the top
    -- makes the tab feel consistent across drill-downs.
    local title = _("BookFusion")
    local subtitle, left_icon, left_cb
    if on_landing then
        -- Landing has no navigation context to display, so leave the
        -- subtitle unset (nil skips TitleBar's subtitle widget entirely —
        -- titlebar.lua:207).  Net effect: landing gets a shorter title
        -- bar than the subpage views, same as the FM when no path is set.
        subtitle  = nil
        left_icon = "appbar.search"
        left_cb   = function() self:_onLeftIcon() end
    elseif self._view == "tbr" then
        subtitle  = _("Plan to Read")
        left_icon = "chevron.left"
        left_cb   = function() self:_exitSubpage() end
    elseif self._view == "search" then
        -- Long queries: truncate so the subtitle stays single-line.  The
        -- full query stays in self._search_query for the re-search flow.
        local q = self._search_query or ""
        if #q > 24 then q = q:sub(1, 23) .. "…" end
        subtitle  = string.format(_("Search: %s"), q)
        left_icon = "chevron.left"
        left_cb   = function() self:_exitSearch() end
    else
        subtitle  = _("Favorites")
        left_icon = "chevron.left"
        left_cb   = function() self:_exitSubpage() end
    end
    local tb = TitleBar:new{
        show_parent              = self,
        fullscreen               = true,
        title                    = title,
        -- Match FileManager's explicit 6 px title_top_padding
        -- (filemanager.lua:125) so the BookFusion title bar has the same
        -- vertical footprint as the Library tab.  Without this the
        -- auto-compute at titlebar.lua:182-200 baseline-aligns title with
        -- icons, yielding a shorter bar that looks different from the FM.
        title_top_padding        = Screen:scaleBySize(6),
        -- Subtitle carries the navigation context (folder name / search
        -- query).  `nil` on landing (no context to show, no subtitle
        -- slot reserved → shorter bar); non-empty on drill-down views.
        subtitle                 = subtitle,
        -- Match FileManager (filemanager.lua:129): 5 px button padding so
        -- icons sit the same distance from the screen edge and the hit
        -- rects are the same size as the Library tab's.  Earlier this was
        -- bumped to 11 for visible breathing room, but now we're aligning
        -- to the FM look exactly.
        button_padding           = Screen:scaleBySize(5),
        left_icon                = left_icon,
        left_icon_size_ratio     = 1,
        left_icon_tap_callback   = left_cb,
        left_icon_hold_callback  = false,
        right_icon               = "cre.render.reload",
        right_icon_size_ratio    = 1,
        right_icon_tap_callback  = function() self:_onRightIcon() end,
        right_icon_hold_callback = false,
    }
    -- Strip TitleBar's asymmetric tap-zone padding on both icon buttons so
    -- their dimens become tight squares (icon_size × icon_size), matching
    -- what sui_titlebar._resizeAndStrip does to the FileManager's buttons.
    -- TitleBar defaults add `padding_right = 2*icon_size` (left button),
    -- `padding_left = 2*icon_size` (right button), and `padding_bottom =
    -- icon_size` on both (titlebar.lua:363-381), which extends the hitbox
    -- inward and downward — visually it makes the icon rectangles larger
    -- and creates a visible vertical separator line between the icons and
    -- the title.  Zeroing these + :update() mirrors the Library tab look.
    --
    -- Edge inset: zero ALL paddings so each button's dimen hugs the icon
    -- tightly (no edge-side fringe inside the hitbox), then push the
    -- button 18 px inward from the screen edge via overlap_offset —
    -- exactly how sui_titlebar places the FM buttons
    -- (sui_titlebar.lua:335-336 via _buttonX with pad=18).  Net effect:
    -- the hitbox rectangle sits 18 px from the edge, not at the edge
    -- with 18 px of inner padding.
    local edge_pad = Screen:scaleBySize(18)
    local sw       = Screen:getWidth()
    for _, btn in ipairs({ tb.left_button, tb.right_button }) do
        if btn then
            btn.padding_left   = 0
            btn.padding_right  = 0
            btn.padding_bottom = 0
            if btn.update then btn:update() end
        end
    end
    if tb.left_button then
        tb.left_button.overlap_align  = nil
        tb.left_button.overlap_offset = { edge_pad, 0 }
    end
    if tb.right_button then
        local iw = tb.right_button.width
                or (tb.right_button.image and tb.right_button.image.width)
                or Screen:scaleBySize(36)
        tb.right_button.overlap_align  = nil
        tb.right_button.overlap_offset = { sw - iw - edge_pad, 0 }
    end
    return tb
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

    -- Section label — bold + small + mid-gray.  Small enough not to compete
    -- with the covers, bold enough to read as a hierarchy signpost.
    local section_fs = math.max(6, math.floor(Screen:scaleBySize(7) * txt_sc))
    local button_fs  = math.max(7, math.floor(Screen:scaleBySize(8) * txt_sc))

    -- Fixed-height elements on the landing (top-down).  Used to compute
    -- carousel cover height so the page never needs scrolling.
    local section_lbl_h   = Screen:scaleBySize(10) + UI.PAD2
    local pre_section_gap = UI.PAD        -- gap between a heading and its content
    local button_h        = Screen:scaleBySize(36)
    -- tile_text_h must accommodate the actual 2-line rendered height of the
    -- title TextBoxWidget, which depends on face.size (double-scaled on hi-DPI
    -- devices via Font:getFace).  Compute it from the same face the tile will
    -- use so the budget stays accurate on every device.
    local _tile_title_fs   = math.max(6, math.floor(Screen:scaleBySize(6) * txt_sc))
    local _tile_title_face = Font:getFace("cfont", _tile_title_fs)
    local _tile_title_lh   = math.floor((1 + 0.3) * _tile_title_face.size + 0.5)
    local tile_text_h     = _tile_title_lh * 2 + Screen:scaleBySize(3)  -- 2 lines + rounding margin
    local tile_pct_h      = Screen:scaleBySize(11)  -- 7px bar + gap
    local top_pad         = UI.PAD
    local between_sections = UI.MOD_GAP   -- gap between CR row and Folders heading
    local bot_pad         = UI.PAD

    -- Arrow width + gap from the carousel.
    local arrow_w   = Screen:scaleBySize(36)
    -- Horizontal gap between arrow and cover: match the outer gap between
    -- arrow and screen edge (UI.SIDE_PAD) so each arrow sits dead-centre in
    -- the corridor between the frame edge and the first/last cover.
    local arrow_gap = UI.SIDE_PAD
    local carousel_inner_w = inner_w - 2 * (arrow_w + arrow_gap)

    -- Tile width from cols.
    local tile_gap = UI.PAD2
    local tile_w   = math.floor((carousel_inner_w - (cr_cols - 1) * tile_gap) / cr_cols)

    -- Carousel sizing — *natural*, not stretched.  We want Folders to sit
    -- right under its heading; any extra vertical space flows to the bottom
    -- pad instead of inflating the covers.  Cap cover height at a 1.55
    -- aspect ratio (typical book cover) AND at whatever the height budget
    -- can spare, whichever is smaller.
    local reserved = top_pad
                   + section_lbl_h + pre_section_gap + Screen:scaleBySize(6) -- CR heading (extra breathing room before covers)
                   + tile_text_h + tile_pct_h + Screen:scaleBySize(8) -- tile extras
                   + between_sections
                   + section_lbl_h + pre_section_gap                  -- Folders heading
                   + 3 * button_h + 2 * math.floor(UI.PAD / 2)        -- 3 nav buttons + 2 half-PAD gaps
                   + bot_pad
    local cover_budget = content_h - reserved
    local cover_h = math.min(math.floor(tile_w * 1.55 * cov_sc), cover_budget)
    if cover_h < Screen:scaleBySize(60) then cover_h = Screen:scaleBySize(60) end
    local tile_h = cover_h + tile_text_h + tile_pct_h + Screen:scaleBySize(8)

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

    -- Arrow buttons — native IconButton with default flash on tap.
    -- Vertical placement: we want the icon slightly BELOW the midline of
    -- (cover + progress bar), not the tile centre.  Wrapping the arrow in
    -- a CenterContainer of height = cover_h + cover→bar gap + bar_h +
    -- small nudge centres the icon within that region; the nudge puts it a
    -- few px below the true midline.  The HorizontalGroup below uses
    -- align="top" so each arrow's CenterContainer starts at the same y as
    -- the covers (y=0 of the carousel row), not vertically centred against
    -- the full tile height.
    local cover_bar_nudge = Screen:scaleBySize(8)   -- lower than pure centre
    local arrow_box_h = cover_h + Screen:scaleBySize(4) + BAR_BASE_H + cover_bar_nudge
    local function _arrow(icon, enabled, cb)
        local inner
        if enabled then
            inner = IconButton:new{
                icon        = icon,
                width       = arrow_w,
                height      = arrow_w,
                padding     = 0,
                callback    = cb,
                show_parent = self,
            }
        else
            -- Keep the column width so the carousel stays horizontally
            -- balanced when we're at the first / last page.
            inner = HorizontalSpan:new{ width = arrow_w }
        end
        return CenterContainer:new{
            dimen = Geom:new{ w = arrow_w, h = arrow_box_h },
            inner,
        }
    end
    local left_arrow  = _arrow("chevron.left",  self._cr_page > 1,          function() self:_cycleCarousel(-1) end)
    local right_arrow = _arrow("chevron.right", self._cr_page < total_pages, function() self:_cycleCarousel( 1) end)

    -- align = "top" anchors every child at y=0 of the row, so each arrow's
    -- CenterContainer establishes its own cover-aligned vertical frame.
    local carousel_row = HorizontalGroup:new{ align = "top",
        left_arrow,
        HorizontalSpan:new{ width = arrow_gap },
        carousel_body,
        HorizontalSpan:new{ width = arrow_gap },
        right_arrow,
    }

    -- Section label — bold + small + mid-grey.  Used for both
    -- "Currently Reading" and "Folders" so they read as peers.
    local SECTION_GRAY = Blitbuffer.gray(0.45)
    local function _sectionLabel(text)
        return LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = section_lbl_h },
            TextWidget:new{
                text    = text,
                face    = Font:getFace("cfont", section_fs),
                bold    = true,
                fgcolor = SECTION_GRAY,
            },
        }
    end
    -- Nav buttons — borderless, left-aligned label + chevron, no left pad
    -- so the label sits flush with the rest of the page's content column.
    --
    -- Square tap feedback: Button:init picks rounded corners whenever a
    -- `background` is passed (button.lua:224), and its flash routine
    -- re-rounds when either `radius == nil` OR `self.background` is
    -- truthy (button.lua:402).  Native square-flash recipe: `radius = 0`
    -- AND no `background` → init's else-branch keeps radius=0, flash's
    -- else-branch uses `invert = true` → square invert.
    local function _navButton(label, on_tap)
        return Button:new{
            text           = label .. " ›",
            align          = "left",
            width          = inner_w,
            height         = button_h,
            text_font_size = button_fs,
            text_font_bold = true,
            bordersize     = 0,
            radius         = 0,  -- keeps tap-feedback flash square
            padding_h      = Screen:scaleBySize(4),
            padding_v      = Screen:scaleBySize(4),
            callback       = on_tap,
        }
    end

    -- Build the page layout.
    --
    -- Structure:
    --   top_pad
    --   "Currently Reading"   (heading)
    --   pre_section_gap
    --   carousel              (covers + progress + title)
    --   between_sections
    --   "Folders"             (heading)
    --   pre_section_gap
    --   [ Plan to Read  › ]
    --   UI.PAD
    --   [ Favorites   › ]
    --   bot_pad
    local vg = VerticalGroup:new{ align = "left" }
    vg[#vg+1] = VerticalSpan:new{ width = top_pad }
    vg[#vg+1] = _sectionLabel(_("Currently Reading"))
    -- A touch more breathing room than the generic pre_section_gap so the
    -- covers don't feel crammed under the heading.  Folders still uses
    -- pre_section_gap below to keep its buttons close to its heading.
    vg[#vg+1] = VerticalSpan:new{ width = pre_section_gap + Screen:scaleBySize(6) }
    if #cr_books == 0 then
        -- First-time / after-clear-cache state.  We don't auto-sync (the tab
        -- is fully offline by spec), so nudge the user toward the refresh
        -- icon instead of showing a dead "No books" string.  A sync in
        -- progress is surfaced via the InfoMessage popup from _refreshLists,
        -- not an inline label.
        local empty_text
        if Cache.get("currently_reading") == nil then
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
    vg[#vg+1] = VerticalSpan:new{ width = between_sections }
    vg[#vg+1] = _sectionLabel(_("Folders"))
    vg[#vg+1] = VerticalSpan:new{ width = pre_section_gap }
    -- Half-PAD gap between folder buttons — just enough visual breathing
    -- room without making the section feel disconnected.
    local folder_gap = math.floor(UI.PAD / 2)
    vg[#vg+1] = _navButton(_("Plan to Read"),        function() self:_enterSubpage("tbr")       end)
    vg[#vg+1] = VerticalSpan:new{ width = folder_gap }
    vg[#vg+1] = _navButton(_("Favorites"),         function() self:_enterSubpage("favorites") end)
    vg[#vg+1] = VerticalSpan:new{ width = folder_gap }
    -- "Browse BookFusion" hands off to the BF plugin's own Menu widget
    -- (onSearchBooks), which lists every bookshelf + collection.  This is
    -- the escape hatch for anything outside the three cached lists above.
    vg[#vg+1] = _navButton(_("Browse BookFusion"), function() Data.openBrowser() end)
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
    -- Grid geometry is now fully driven by settings: fixed `rows × cols`
    -- per page, cover dimensions derived so the whole grid exactly fills
    -- the available area.  Defaults are 2 rows × 4 cols = 8 covers per
    -- page; both are clamped to 1..6 by the setting readers.
    local grid_cols = Settings.gridCols()
    local rows      = Settings.gridRows()

    -- Pager bar (prev / page / next) pinned at the bottom of the subpage.
    -- The subpage's title + back arrow live in the main TitleBar now, so
    -- there's no sub-header eating vertical space here.
    local pager_h = Screen:scaleBySize(32)

    -- Book source depends on the view:
    --   • tbr / favorites : pulled from the on-disk Cache (offline reads).
    --   • search          : in-memory self._search_results, appended to by
    --                       _fetchNextSearchPage as the user pages past what
    --                       we've buffered.  `books_total` is the authoritative
    --                       pager total — for cached lists it equals #books,
    --                       for search it comes from the API's total-count
    --                       header (self._search_total) so the pager shows
    --                       a correct "N / M" from the first render onward.
    local books, books_total
    if self._view == "search" then
        books       = self._search_results or {}
        books_total = math.max(self._search_total or 0, #books)
    elseif self._view == "tbr" then
        local slot  = Cache.get("planned_to_read"); books = (slot and slot.books) or {}
        books_total = #books
    else
        local slot  = Cache.get("favorites");       books = (slot and slot.books) or {}
        books_total = #books
    end

    -- Vertical paddings used both to size the grid area and to position
    -- the pager later on (see VG assembly below).  Declared once here so
    -- there's a single source of truth.
    local top_pad = Screen:scaleBySize(12)
    local bot_pad = Screen:scaleBySize(12)
    local grid_h  = content_h - top_pad - pager_h - bot_pad

    -- Unified horizontal padding: the gap between covers matches the gap
    -- between the outermost covers and the screen edge (the FrameContainer
    -- at the bottom of this function uses padding_left/right = UI.SIDE_PAD).
    local tile_gap = UI.SIDE_PAD
    local row_gap  = UI.PAD

    -- Subpage tiles show a 1-line title.  Reserve just one actual line of
    -- the rendered face height (same formula as _titleLabel uses) plus a
    -- few px of rounding margin.
    local _sub_title_fs   = math.max(6, math.floor(Screen:scaleBySize(6) * txt_sc))
    local _sub_title_face = Font:getFace("cfont", _sub_title_fs)
    local _sub_title_lh   = math.floor((1 + 0.3) * _sub_title_face.size + 0.5)
    local title_h_reserve = _sub_title_lh + Screen:scaleBySize(3)
    local cover_title_gap = Screen:scaleBySize(4)

    -- Tile dimensions derived from the configured rows × cols.
    local tile_w = math.floor((inner_w - (grid_cols - 1) * tile_gap) / grid_cols)
    -- Vertical budget per tile: total grid_h minus inter-row gaps, divided
    -- evenly across `rows`.  Cover_h gets whatever is left after the title
    -- strip.  If the budget isn't enough for a sensible cover, we fall
    -- back to a 1.5:1 aspect ratio on tile_w (scaled by cover_scale).
    local tile_budget_h  = math.floor((grid_h - (rows - 1) * row_gap) / rows)
    local cover_h        = tile_budget_h - title_h_reserve - cover_title_gap
    local aspect_cover_h = math.floor(tile_w * 1.5 * cov_sc)
    if cover_h > aspect_cover_h then cover_h = aspect_cover_h end
    if cover_h < Screen:scaleBySize(60) then cover_h = Screen:scaleBySize(60) end
    local tile_h  = cover_h + cover_title_gap + title_h_reserve
    local per_page = rows * grid_cols

    local total_pages = math.max(1, math.ceil(books_total / per_page))
    if self._grid_page > total_pages then self._grid_page = total_pages end
    if self._grid_page < 1 then self._grid_page = 1 end

    local start_idx = (self._grid_page - 1) * per_page + 1
    -- end_idx uses #books (not books_total) — the search view may declare
    -- more total pages than it has buffered right now, and we can only
    -- render books we actually have.  _cyclePage triggers a fetch before
    -- showing a page that would otherwise be empty.
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
                    title_lines   = 1,       -- single-line titles on subpages
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
        -- Empty-state copy differs by view.  During the first search fetch
        -- (no results yet AND no completed API page) we say "Searching…"
        -- so the user gets immediate feedback even if the "Searching…"
        -- InfoMessage popup fired too quickly to notice.
        local empty_text
        if self._view == "search" then
            if self._search_fetching or self._search_api_page == 0 then
                empty_text = _("Searching…")
            else
                empty_text = _("No books match your search.")
            end
        else
            empty_text = _("No books in this list.")
        end
        -- Drop the TextBoxWidget straight into the grid VG (no LeftContainer
        -- wrapper with h = tile_h).  LeftContainer vertically CENTRES its
        -- child within its dimen (leftcontainer.lua:23), which pushed the
        -- empty-state text to roughly the middle of the first tile row —
        -- awkward during "Searching…".  TextBoxWidget sizes itself to its
        -- text so it sits flush at the top of the grid area.
        grid[#grid+1] = TextBoxWidget:new{
            text  = empty_text,
            face  = Font:getFace("cfont",
                math.max(10, math.floor(Screen:scaleBySize(11) * txt_sc))),
            width = inner_w,
        }
    end

    -- Pager: subdued "X/Y" centred, arrows pinned to the edges.
    -- OverlapGroup lets each child anchor independently (left / center /
    -- right via overlap_align) inside the same footprint.  Each child is
    -- then wrapped in a CenterContainer of the same height as the pager
    -- so overlap_align (horizontal) + CenterContainer (vertical) combine
    -- into a proper 2-axis anchoring.
    local arrow_sz = Screen:scaleBySize(30)
    local function _pagerArrow(icon, enabled, cb, side)
        local inner
        if enabled then
            inner = IconButton:new{
                icon        = icon,
                width       = arrow_sz,
                height      = arrow_sz,
                padding     = 0,
                callback    = cb,
                show_parent = self,
            }
        else
            -- Keep the footprint so the text stays centred even at the edges.
            inner = HorizontalSpan:new{ width = arrow_sz }
        end
        return CenterContainer:new{
            dimen         = Geom:new{ w = arrow_sz, h = pager_h },
            overlap_align = side,
            inner,
        }
    end
    local pager_fs = math.max(6, math.floor(Screen:scaleBySize(7) * txt_sc))
    local pager_label = TextWidget:new{
        text    = string.format("%d / %d", self._grid_page, total_pages),
        face    = Font:getFace("cfont", pager_fs),
        fgcolor = Blitbuffer.gray(0.45),   -- subtle mid-grey
    }
    local pager = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = pager_h },
        _pagerArrow("chevron.left",  self._grid_page > 1,           function() self:_cyclePage(-1) end, "left"),
        CenterContainer:new{
            dimen         = Geom:new{ w = inner_w, h = pager_h },
            overlap_align = "center",
            pager_label,
        },
        _pagerArrow("chevron.right", self._grid_page < total_pages, function() self:_cyclePage( 1) end, "right"),
    }

    -- Layout: grid at top (with top_pad clearing the title-bar icon tap
    -- zones), then a flexible VerticalSpan that absorbs whatever vertical
    -- slack is left, then the pager pinned near the content-area bottom
    -- with its own trailing pad.
    --
    -- The flex_pad must be computed from the **actual** rows we placed
    -- (variable `placed` from the build loop above), not the `rows`
    -- budget — otherwise a short last page (e.g. only 1 row of books) is
    -- measured as if it had `rows` full rows, so flex_pad underestimates
    -- the slack and the pager floats well above the bottom.  top_pad /
    -- bot_pad were defined at the top of this function.
    local grid_h_actual = placed * tile_h + math.max(0, placed - 1) * row_gap
    local used_h = top_pad + grid_h_actual + pager_h + bot_pad
    local flex_pad = math.max(Screen:scaleBySize(4), content_h - used_h)

    local vg = VerticalGroup:new{ align = "left" }
    vg[#vg+1] = VerticalSpan:new{ width = top_pad }
    vg[#vg+1] = grid
    vg[#vg+1] = VerticalSpan:new{ width = flex_pad }
    vg[#vg+1] = pager
    vg[#vg+1] = VerticalSpan:new{ width = bot_pad }

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
        -- VerticalGroup caches _size and _offsets on first getSize() call
        -- (verticalgroup.lua:15-31).  Mutating slots in place leaves the
        -- cached offsets pointing at the PREVIOUS children's positions,
        -- so paintTo draws the new body at the old title bar's y — which
        -- now that the title bar changes height between landing (no
        -- subtitle) and subpages (with subtitle) produces a top overlap
        -- and a bottom gap.  resetLayout() clears the cache so offsets
        -- are recomputed from the fresh children on the next paint.
        self._body_vg:resetLayout()
    end
    -- Dithering hint for e-ink refreshes.  Without this, the first paint
    -- after a cover lands on screen uses a bi-level refresh that crushes
    -- photo tonality — covers look washed out / muted until KOReader
    -- happens to schedule a full refresh 30+ s later.  UIManager checks
    -- `widget.dithered` on setDirty (uimanager.lua:241) and routes the
    -- repaint through a proper dithered mode when the flag is set.  Same
    -- pattern sui_homescreen uses for its cover rows (sui_homescreen.lua:2289).
    self.dithered = true
    UIManager:setDirty(self, "ui", nil, true)
end

function BookFusionTab:_cycleCarousel(delta)
    self._cr_page = self._cr_page + delta
    self:_rebuildAndRepaint()
end

function BookFusionTab:_cyclePage(delta)
    local new_page = self._grid_page + delta

    -- In the search view, tapping › past the last fully-buffered display
    -- page needs an API round-trip.  Buffer only as much as the user has
    -- navigated to — no speculative prefetch.
    if self._view == "search" and delta > 0 then
        local per_page = Settings.gridRows() * Settings.gridCols()
        local needed   = new_page * per_page
        local have     = self._search_results and #self._search_results or 0
        local server_total = self._search_total or 0
        if have < needed and (server_total == 0 or have < server_total) then
            -- Fetch another API page, then advance, repaint, and queue
            -- cover downloads for the newly-visible books.
            NetworkMgr:runWhenOnline(function()
                if self._closed or self._view ~= "search" then return end
                self:_fetchNextSearchPage(function()
                    if self._closed or self._view ~= "search" then return end
                    self._grid_page = new_page
                    self:_rebuildAndRepaint()
                    self:_prefetchVisibleCovers()
                end)
            end)
            return
        end
    end

    self._grid_page = new_page
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

-- ---------------------------------------------------------------------------
-- In-place search
-- ---------------------------------------------------------------------------
-- User-initiated and session-scoped (search inherently can't be offline —
-- it's the one place in the tab that ALWAYS hits the network, by design):
--   • An API call only fires when the user explicitly submits a query
--     (no auto-search on tab open, no live-as-you-type debounce).
--   • Results live in self._search_results (module-local Lua array).
--   • No Cache.put — nothing persists across the tab's lifetime; a fresh
--     query always pulls fresh data from the server.
--   • Each API call fetches a page sized to the display grid (see
--     Settings.searchFetchSize) so the buffer always ends on a whole
--     display-page boundary.
--   • total_display_pages comes from the API's total-count header on the
--     FIRST response — the pager shows a correct "N / M" immediately, no
--     "+" suffix or later renumbering.
--   • Additional API pages are fetched on-demand when the user taps › past
--     what's currently buffered.

function BookFusionTab:_showSearchDialog()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title   = _("Search BookFusion"),
        input   = self._search_query or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id   = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local q = dialog:getInputText() or ""
                        q = q:gsub("^%s+", ""):gsub("%s+$", "")
                        UIManager:close(dialog)
                        if q == "" then return end
                        self:_enterSearch(q)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BookFusionTab:_enterSearch(query)
    -- Reset session state.
    self._search_query        = query
    self._search_results      = {}
    self._search_total        = 0
    self._search_api_page     = 0   -- 0 = nothing fetched yet
    self._search_api_per_page = Settings.searchFetchSize(
        Settings.gridRows() * Settings.gridCols())
    self._search_fetching     = nil
    self._grid_page           = 1

    -- Show the view immediately (empty-state "Searching…" branch) so the
    -- title bar swap is visible before network kicks in.
    self._view = "search"
    self:_rebuildAndRepaint()

    -- Kick the first API fetch (deferred so the rebuild paints first).
    NetworkMgr:runWhenOnline(function()
        if self._closed or self._view ~= "search" then return end
        self:_fetchNextSearchPage(function()
            if self._closed or self._view ~= "search" then return end
            self:_rebuildAndRepaint()
            self:_prefetchVisibleCovers()
        end)
    end)
end

function BookFusionTab:_fetchNextSearchPage(on_done)
    if self._search_fetching then return end
    if not self._search_query or self._search_query == "" then return end
    -- Stop if we've already fetched everything the server has.
    if self._search_total > 0 and #self._search_results >= self._search_total then
        if on_done then on_done() end
        return
    end
    self._search_fetching = true

    local InfoMessage = require("ui/widget/infomessage")
    local popup = InfoMessage:new{ text = _("Searching…"), timeout = 0 }
    self._search_popup = popup
    UIManager:show(popup)

    local next_api_page = self._search_api_page + 1
    Data.searchPage(self._search_query, next_api_page,
        self._search_api_per_page, function(ok, books, pagination)
        self._search_fetching = false
        if self._search_popup then
            pcall(function() UIManager:close(self._search_popup) end)
            self._search_popup = nil
        end
        if self._closed or self._view ~= "search" then return end
        if not ok or type(books) ~= "table" then
            logger.warn("simpleui-bf: search fetch failed:", tostring(books))
            UIManager:show(InfoMessage:new{
                text    = _("Couldn't search BookFusion."),
                timeout = 3,
            })
            if on_done then on_done() end
            return
        end
        -- Flatten each raw API book into the same slim shape Cache.put
        -- stores for the cached lists (nested `cover = {url, width, height}`
        -- → flat cover_url / cover_w / cover_h).  BookTile + Covers.getBB
        -- expect the flat shape; without this, every search result rendered
        -- as a placeholder because cover_url was always nil.
        for i = 1, #books do
            local b = books[i]
            if type(b) == "table" and b.id then
                local cover = b.cover
                self._search_results[#self._search_results + 1] = {
                    id            = b.id,
                    title         = b.title,
                    authors       = b.authors,
                    cover_url     = cover and cover.url    or b.cover_url,
                    cover_w       = cover and cover.width  or b.cover_w,
                    cover_h       = cover and cover.height or b.cover_h,
                    percentage    = b.percentage,
                    format        = b.format,
                    -- See Cache.put: preserved for bf_downloader's progress UI.
                    download_size = b.download_size,
                }
            end
        end
        self._search_api_page = next_api_page
        if pagination and pagination.total then
            self._search_total = pagination.total
        end
        if on_done then on_done() end
    end)
end

function BookFusionTab:_exitSearch()
    -- Cancel an in-flight popup if any.
    if self._search_popup then
        pcall(function() UIManager:close(self._search_popup) end)
        self._search_popup = nil
    end
    self._search_query        = nil
    self._search_results      = nil
    self._search_total        = 0
    self._search_api_page     = 0
    self._search_api_per_page = 0
    self._search_fetching     = nil
    self._view                = "landing"
    self:_rebuildAndRepaint()
end

function BookFusionTab:_onLeftIcon()
    -- On the landing: open the search InputDialog.  On subpages the left
    -- icon is a back chevron whose callback is wired in _buildTitleBar.
    self:_showSearchDialog()
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
    -- MUST NOT commit any state (self._refreshing, self._sync_popup) before
    -- we're inside the callback.  Otherwise the popup would stay on screen
    -- and future taps on ↻ would short-circuit via the `if self._refreshing`
    -- guard above.
    NetworkMgr:runWhenOnline(function()
        if self._closed then return end

        local pending = {}
        for _i, key in ipairs(Cache.LIST_KEYS) do
            if force or Cache.isStale(key) then
                pending[#pending+1] = key
            end
        end
        if #pending == 0 then return end

        self._refreshing = true

        -- Show a persistent "Syncing…" popup for as long as the fetch loop
        -- is running.  Replaces the old inline "(refreshing…)" headline
        -- note so the header stays clean.  `timeout = 0` keeps it up until
        -- we explicitly close it on the last step.
        local InfoMessage = require("ui/widget/infomessage")
        self._sync_popup = InfoMessage:new{
            text    = _("Syncing…"),
            timeout = 0,
        }
        UIManager:show(self._sync_popup)

        local idx, failed = 0, 0
        local function finish()
            self._refreshing = false
            if self._sync_popup then
                pcall(function() UIManager:close(self._sync_popup) end)
                self._sync_popup = nil
            end
            if failed > 0 then
                UIManager:show(InfoMessage:new{
                    text    = _("Couldn't refresh some BookFusion lists."),
                    timeout = 3,
                })
            end
            self:_prefetchVisibleCovers()
        end
        local function step()
            idx = idx + 1
            if idx > #pending then finish(); return end
            local key = pending[idx]
            local params = Cache.LIST_PARAMS[key] or { list = key }
            -- Enrich only Currently Reading with per-book reading position:
            -- that's the only list whose tiles render a progress bar.  TBR /
            -- Favourites would pay N extra HTTP GETs for data we'd throw
            -- away in `BookTile:init` (show_progress = false on those views).
            local fetch_opts = { with_progress = (key == "currently_reading") }
            Data.fetchListAll(params, function(ok, books)
                if ok and type(books) == "table" then
                    Cache.put(key, books)
                else
                    logger.warn("simpleui-bf: fetch failed for", key, tostring(books))
                    failed = failed + 1
                end
                if self._closed then return end
                self:_rebuildAndRepaint()
                step()
            end, fetch_opts)
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
    elseif self._view == "search" then
        local list = self._search_results or {}
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
    if self._sync_popup then
        pcall(function() UIManager:close(self._sync_popup) end)
        self._sync_popup = nil
    end
    if self._search_popup then
        pcall(function() UIManager:close(self._search_popup) end)
        self._search_popup = nil
    end
    -- Drop any in-memory search results so the next tab open starts clean.
    self._search_results = nil
    self._search_query   = nil
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

return M
