-- sui_bookfusion.lua — Simple UI / BookFusion tab
-- Native-feeling fullscreen widget that surfaces the user's BookFusion library
-- (Currently Reading, To Be Read, Favorites) without duplicating any logic
-- from bookfusion.koplugin — it calls the live BF plugin instance registered
-- on the FileManager under `fm.bookfusion` (set in bookfusion/main.lua:6).
--
-- File layout (sections marked with banners below):
--   1. Cache       — LuaSettings-backed persistence for the three lists.
--   2. Data bridge — thin shims over fm.bookfusion (api, settings, browser).
--   3. Widget      — the Menu subclass that draws the tab.
--   4. Module API  — entry point called by sui_bottombar's navigate branch.
--
-- Design notes:
--   • Rendering uses KOReader's Menu class with `title_bar_fm_style = true`
--     for FileManager-style chrome, wrapped automatically by SUI's navbar
--     (via sui_patches.patchUIManagerShow → widget.name == "bookfusion").
--   • Landing paints from cache (instant). A background refresh is kicked
--     off afterwards; results stream in as each list completes.
--   • Title-bar: left icon = search (delegates to BF browser for v1),
--     right icon = refresh (swapped in post-Menu.init; `_titlebar_inj_patched`
--     flag tells sui_titlebar.applyToInjected to leave it alone).
--
-- Later TODOs (out of scope for v1):
--   • Per-book "already downloaded" indicator on rows.
--   • In-place search (InputDialog + api:searchBooks) instead of delegating.
--   • SUI-side settings panel for this tab (cache TTL, list visibility, …).

local Menu        = require("ui/widget/menu")
local IconButton  = require("ui/widget/iconbutton")
local UIManager   = require("ui/uimanager")
local NetworkMgr  = require("ui/network/manager")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger      = require("logger")
local _           = require("gettext")

-- Forward-declare the module table so the widget class (defined below) can
-- reference `M._instance` in its onCloseWidget handler.
local M = {}
M._instance = nil

-- ===========================================================================
-- 1. CACHE
-- ---------------------------------------------------------------------------
-- Persistent cache for the three landing lists.  Uses LuaSettings (same
-- mechanism as bookfusion.koplugin/bf_settings.lua) so the cache survives
-- restarts without depending on rapidjson.
--
-- Storage file: <DataStorage>/simpleui_bookfusion_cache.lua
-- Per-list entry schema:
--   list_<key> = { books = {...}, fetched_at = <epoch> }
-- Book record kept minimal — only fields we render or need for drill-down:
--   { id, title, authors, cover_url, percentage, format }
-- ===========================================================================

local Cache = {}

local CACHE_SCHEMA_VERSION = 1
local CACHE_DEFAULT_TTL    = 15 * 60  -- 15 minutes

-- Keys recognised by the landing page. Order here is the render order.
Cache.LIST_KEYS = { "currently_reading", "planned_to_read", "favorites" }

-- Sort/filter parameters for each list, matching bf_browser.lua:77-103.
Cache.LIST_PARAMS = {
    currently_reading = { list = "currently_reading", sort = "last_read_at-desc" },
    planned_to_read   = { list = "planned_to_read" },
    favorites         = { list = "favorites" },
}

local _cache_store  -- lazy-opened LuaSettings instance

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

local function _cacheSlotKey(list_key) return "list_" .. list_key end

function Cache.get(list_key)
    local s = _cacheOpen()
    if not s then return nil end
    local slot = s:readSetting(_cacheSlotKey(list_key))
    if type(slot) ~= "table" then return nil end
    return slot
end

-- Persist a list. `books` is the raw array from bf_api.searchBooks; we keep
-- only the minimal fields we need so the cache stays small.
function Cache.put(list_key, books)
    local s = _cacheOpen()
    if not s then return end
    local slim = {}
    if type(books) == "table" then
        for i = 1, #books do
            local b = books[i]
            if type(b) == "table" and b.id then
                slim[#slim + 1] = {
                    id         = b.id,
                    title      = b.title,
                    authors    = b.authors,
                    cover_url  = b.cover_url,
                    percentage = b.percentage,
                    format     = b.format,
                }
            end
        end
    end
    s:saveSetting(_cacheSlotKey(list_key), {
        books      = slim,
        fetched_at = os.time(),
    })
    pcall(function() s:flush() end)
end

-- Returns true if the slot is missing OR older than `ttl` seconds.
function Cache.isStale(list_key, ttl)
    local slot = Cache.get(list_key)
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
-- 2. DATA BRIDGE
-- ---------------------------------------------------------------------------
-- Thin shims that reach the live bookfusion.koplugin instance registered on
-- the FileManager (or ReaderUI) as `.bookfusion` — plugins expose themselves
-- under their `name` attribute; see bookfusion/main.lua:6.
--
-- Every public function pcall-guards the cross-plugin call and returns nil /
-- false when the plugin is absent, so callers can render a friendly empty
-- state instead of crashing.
-- ===========================================================================

local Data = {}

function Data.getPlugin()
    local FM = package.loaded["apps/filemanager/filemanager"]
    local fm = FM and FM.instance
    if fm and fm.bookfusion then return fm.bookfusion end
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance and RUI.instance.bookfusion then
        return RUI.instance.bookfusion
    end
    return nil
end

function Data.isAvailable() return Data.getPlugin() ~= nil end

function Data.isLinked()
    local p = Data.getPlugin()
    if not p or not p.bf_settings then return false end
    local ok, yes = pcall(function() return p.bf_settings:isLoggedIn() end)
    return ok and yes or false
end

function Data.api()
    local p = Data.getPlugin()
    return p and p.api or nil
end

-- Fire the BookFusion plugin's own device-code link flow.
function Data.startLink()
    local p = Data.getPlugin()
    if not p or type(p.onLinkDevice) ~= "function" then return false end
    local ok, err = pcall(function() p:onLinkDevice() end)
    if not ok then logger.warn("simpleui-bf: startLink failed:", tostring(err)) end
    return ok
end

-- Open the BookFusion plugin's full browser (its own top-level view).
function Data.openBrowser()
    local p = Data.getPlugin()
    if not p or type(p.onSearchBooks) ~= "function" then return false end
    local ok, err = pcall(function() p:onSearchBooks() end)
    if not ok then logger.warn("simpleui-bf: openBrowser failed:", tostring(err)) end
    return ok
end

-- Invoke the BookFusion plugin's own "select book" flow (download or open).
-- We instantiate a throwaway Browser with the live api + settings so its
-- onSelectBook() can run without owning a visible Menu.
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

-- Paginate through api:searchBooks until every page is collected, then
-- invoke `cb(ok, books)` on the main thread.  Dispatched via
-- UIManager:scheduleIn(0, ...) so the caller's frame paints before network
-- I/O blocks.  Safety cap at 200 pages (10_000 books) — BookFusion accounts
-- never hit this in practice.
local FETCH_PER_PAGE = 50  -- bigger than bf_browser's 20 → fewer round-trips

function Data.fetchListAll(params, cb)
    local api = Data.api()
    if not api then
        if cb then cb(false, "api_unavailable") end
        return
    end
    UIManager:scheduleIn(0, function()
        local all  = {}
        local page = 1
        while true do
            local q = { page = page, per_page = FETCH_PER_PAGE }
            for k, v in pairs(params or {}) do q[k] = v end
            local ok, books, pagination = api:searchBooks(q)
            if not ok or type(books) ~= "table" then
                if cb then cb(false, books) end
                return
            end
            for i = 1, #books do all[#all + 1] = books[i] end
            local got = #books
            local total = pagination and pagination.total
            if got < FETCH_PER_PAGE then break end
            if total and #all >= total then break end
            page = page + 1
            if page > 200 then break end  -- safety belt
        end
        if cb then cb(true, all) end
    end)
end

-- ===========================================================================
-- 3. WIDGET
-- ---------------------------------------------------------------------------
-- KOReader Menu subclass.  Integration points with SUI:
--   • `name = "bookfusion"` is matched by sui_patches.lua:1193 to activate
--     the tab indicator in the bottom navbar.
--   • `covers_fullscreen = true` makes patchUIManagerShow wrap the widget
--     with SUI's navbar on UIManager:show.
--   • `_titlebar_inj_patched = true` (set in init) tells
--     sui_titlebar.applyToInjected to leave our custom title-bar buttons
--     alone — otherwise SUI's default (inj_right = false) would zero the
--     refresh button's dimen.
-- ===========================================================================

local BookFusionTab = Menu:extend{
    name                = "bookfusion",
    covers_fullscreen   = true,
    is_borderless       = true,
    is_popout           = false,
    title_bar_fm_style  = true,
    title               = _("BookFusion"),
    -- Left icon: search. v1 delegates to the BF plugin's own browser so the
    -- user still has a working search entry point. In-place search is a
    -- tracked later-TODO (user-confirmed scope).
    title_bar_left_icon = "appbar.search",
    -- Right icon (refresh) is NOT configurable via Menu's init; Menu always
    -- wires close_callback → right_icon="close". We swap the button post-init
    -- in _installTitleBarButtons(). `cre.render.reload` is the only reload-
    -- style icon shipped with mdlight.
}

-- Human-readable titles per list key.
local LIST_LABELS = {
    currently_reading = _("Currently Reading"),
    planned_to_read   = _("To Be Read"),
    favorites         = _("Favorites"),
}

-- Normalise `book.authors` to a single display string.
-- BookFusion's API returns an array of author objects like
-- `{ { name = "Jane Doe", id = 1 }, ... }` — not plain strings — so a naive
-- `table.concat(a, ", ")` crashes with "invalid value (table) at index ?".
-- Mirrors bf_downloader.formatAuthors (bookfusion.koplugin/bf_downloader.lua:243).
local function _authorsLine(book)
    local a = book.authors
    if not a then return nil end
    if type(a) == "string" then return a end
    if type(a) ~= "table" then return nil end
    local names = {}
    for i = 1, #a do
        local entry = a[i]
        if type(entry) == "string" then
            names[#names + 1] = entry
        elseif type(entry) == "table" and entry.name then
            names[#names + 1] = entry.name
        end
    end
    if #names == 0 then return nil end
    return table.concat(names, ", ")
end

-- Build a single header row. `select_enabled = false` makes the row truly
-- non-tappable (Menu:onMenuSelect short-circuits on the flag, so the default
-- onMenuChoice never fires); `dim` + `bold` give the visual treatment.
local function _headerItem(label, note)
    local text = label
    if note and note ~= "" then text = label .. "  " .. note end
    return {
        text           = text,
        dim            = true,
        bold           = true,
        select_enabled = false,
        _sui_bf_header = true,
    }
end

-- Build a book row.  `on_tap` is the callback (delegates through Data).
local function _bookItem(book, on_tap)
    local author = _authorsLine(book)
    local text   = book.title or _("Untitled")
    if author and author ~= "" then
        text = text .. "  —  " .. author
    end
    local mandatory = nil
    if type(book.percentage) == "number" and book.percentage > 0 then
        mandatory = string.format("%d%%", math.floor(book.percentage * 100 + 0.5))
    end
    return {
        text         = text,
        mandatory    = mandatory,
        callback     = function() on_tap(book) end,
        _sui_bf_book = true,
    }
end

-- Empty-state row. If no callback is provided, the row is visually dim AND
-- non-tappable; otherwise it's a normal tappable row.
local function _infoRow(text, callback)
    return {
        text           = "  " .. text,
        dim            = callback == nil,
        select_enabled = callback ~= nil and true or false,
        callback       = callback,
    }
end

-- Build the full item table from what is currently in the cache.
-- `progress` is an optional { [list_key] = "refreshing"|"error" } map used
-- to annotate headers while a background fetch is in flight.
local function _buildItemsFromCache(progress, on_tap, on_more)
    local items = {}

    if not Data.isAvailable() then
        items[#items + 1] = _headerItem(_("BookFusion"))
        items[#items + 1] = _infoRow(_("BookFusion plugin is not installed."))
        items[#items + 1] = _infoRow(_("Install it from the KOReader plugins directory to enable this tab."))
        return items
    end

    if not Data.isLinked() then
        items[#items + 1] = _headerItem(_("BookFusion"))
        items[#items + 1] = _infoRow(_("Link your BookFusion account to get started."), function()
            Data.startLink()
        end)
        return items
    end

    -- NOTE: iterate with `_i`, not `_`.  Inside this loop we call gettext
    -- via `_(...)` — the local gettext handle captured at module top.
    -- Binding the iterator variable to `_` would shadow that handle with a
    -- number, producing "attempt to call local '_' (a number value)".
    for _i, key in ipairs(Cache.LIST_KEYS) do
        local label = LIST_LABELS[key] or key
        local state = progress and progress[key]
        local note
        if state == "refreshing" then
            note = "(" .. _("refreshing…") .. ")"
        elseif state == "error" then
            note = "(" .. _("offline") .. ")"
        end
        items[#items + 1] = _headerItem(label, note)

        local slot = Cache.get(key)
        local books = slot and slot.books or {}
        if #books == 0 then
            if state == "refreshing" then
                items[#items + 1] = _infoRow(_("Loading…"))
            else
                items[#items + 1] = _infoRow(_("No books in this list."))
            end
        else
            for i = 1, #books do
                items[#items + 1] = _bookItem(books[i], on_tap)
            end
        end

        items[#items + 1] = {
            text     = "  " .. _("More on BookFusion…"),
            callback = function() on_more(key) end,
        }
    end

    return items
end

-- ---------------------------------------------------------------------------
-- Widget lifecycle
-- ---------------------------------------------------------------------------

function BookFusionTab:init()
    self._progress = {}  -- per-list refresh state: [key] = "refreshing"|"error"
    self.item_table = _buildItemsFromCache(
        self._progress,
        function(book) self:_onBookTap(book) end,
        function(key) self:_onMoreTap(key) end
    )
    -- No custom onMenuSelect: the default in Menu calls onMenuChoice which
    -- in turn calls item.callback — exactly what we want.  No close_callback:
    -- we want the tab to stay visible after a book tap (download dialog
    -- appears on top; when it closes the tab is still there).

    Menu.init(self)

    -- Swap the Menu-generated close button (right corner) for our refresh
    -- button.  Menu unconditionally wires close_callback → right_icon="close"
    -- (menu.lua:734) so this is the only injection point.  We rebuild the
    -- IconButton in place and replace it inside the TitleBar's OverlapGroup.
    self:_installTitleBarButtons()
    -- Tell sui_titlebar.applyToInjected (sui_titlebar.lua:787) to leave our
    -- custom buttons alone — otherwise the default (inj_right=false) would
    -- zero the dimen and destroy the refresh affordance.
    self._titlebar_inj_patched = true
end

function BookFusionTab:_installTitleBarButtons()
    local tb = self.title_bar
    if not tb or not tb.right_button then return end
    local old = tb.right_button
    local new = IconButton:new{
        icon           = "cre.render.reload",
        width          = old.width,
        height         = old.height,
        padding        = old.padding,
        padding_left   = old.padding_left,
        padding_bottom = old.padding_bottom,
        overlap_align  = "right",
        callback       = function() self:onRightButtonTap() end,
        allow_flash    = false,  -- no full-screen flash on refresh tap
        show_parent    = self,
    }
    for i, child in ipairs(tb) do
        if child == old then tb[i] = new; break end
    end
    tb.right_button = new
end

function BookFusionTab:_rebuild()
    local items = _buildItemsFromCache(
        self._progress,
        function(book) self:_onBookTap(book) end,
        function(key) self:_onMoreTap(key) end
    )
    self:switchItemTable(self.title or _("BookFusion"), items)
end

function BookFusionTab:_onBookTap(book)
    Data.selectBook(book)
end

function BookFusionTab:_onMoreTap(_key)
    -- v1: delegate to the BookFusion plugin's own browser (top-level view).
    -- Landing directly on a specific list would require a public entry point
    -- on the BF plugin; tracked as Open Question Q1 in the plan.
    Data.openBrowser()
end

-- Title-bar LEFT button (search icon). Until in-place search is built,
-- delegate to the BF plugin's own browser (it has its own search dialog).
function BookFusionTab:onLeftButtonTap()
    Data.openBrowser()
end

-- Title-bar RIGHT button (refresh icon). Forces a fetch of all three lists
-- bypassing the TTL check; useful when the user just added a book on the
-- BookFusion web app and wants to see it on-device immediately.
function BookFusionTab:onRightButtonTap()
    if not Data.isAvailable() or not Data.isLinked() then
        self:_rebuild()  -- nothing to refresh; repaint the empty-state
        return
    end
    self:_refreshLists(true)
end

-- Kick off a refresh for every list that is stale (or all of them if forced).
function BookFusionTab:_refreshLists(force)
    if not Data.isLinked() then return end
    if self._refreshing then return end  -- one concurrent pass
    self._refreshing = true

    local pending = {}
    for _i, key in ipairs(Cache.LIST_KEYS) do
        if force or Cache.isStale(key) then
            pending[#pending + 1] = key
            self._progress[key] = "refreshing"
        end
    end
    if #pending == 0 then
        self._refreshing = false
        return
    end
    self:_rebuild()

    local idx = 0
    local function step()
        idx = idx + 1
        if idx > #pending then
            self._refreshing = false
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
            self:_rebuild()
            step()
        end)
    end

    NetworkMgr:runWhenOnline(function() step() end)
end

function BookFusionTab:onShow()
    -- UIManager broadcasts a "Show" event when the widget is added to the
    -- stack (uimanager.lua:186), which dispatches to this handler.
    -- Schedule the refresh so the first paint lands before any network I/O.
    UIManager:scheduleIn(0.1, function()
        if self._closed then return end
        self:_refreshLists(false)
    end)
    return Menu.onShow and Menu.onShow(self)
end

-- Fires after UIManager has removed the widget from the stack (back-button,
-- tab swap, etc.). Set the _closed flag so async fetch callbacks bail
-- instead of trying to rebuild a dead widget.
function BookFusionTab:onCloseWidget()
    self._closed = true
    if M._instance == self then M._instance = nil end
    if Menu.onCloseWidget then Menu.onCloseWidget(self) end
end

-- ===========================================================================
-- 4. MODULE API  (called by sui_bottombar navigate branch)
-- ===========================================================================

function M.show(_on_qa_tap)
    -- Close any previous instance to avoid stacking (same pattern as Homescreen).
    if M._instance then
        pcall(function() UIManager:close(M._instance) end)
        M._instance = nil
    end
    local w = BookFusionTab:new{}
    M._instance = w
    -- UIManager:show broadcasts a Show event which dispatches onShow on w
    -- (uimanager.lua:186), so the initial refresh is kicked off there.
    UIManager:show(w)
end

function M.close()
    if M._instance then
        pcall(function() UIManager:close(M._instance) end)
        M._instance = nil
    end
end

-- Exposed for tests / debugging.
M._Cache = Cache
M._Data  = Data

return M
