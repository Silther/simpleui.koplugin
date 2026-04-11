-- sui_bookfusion.lua — Simple UI
-- BookFusion landing page: shows the user's currently-reading books at the top
-- as a horizontal cover strip with large thumbnails, and shortcuts to the
-- Plan to Read and Favorites folders below.
--
-- Reuses the bookfusion.koplugin modules (bf_api, bf_settings, bf_browser,
-- bf_downloader, bf_covermenu) via package.path — KOReader's pluginloader
-- adds every enabled .koplugin directory to package.path so a direct
-- require() of "bf_*" works as long as the BookFusion plugin is enabled.

local Blitbuffer       = require("ffi/blitbuffer")
local CenterContainer  = require("ui/widget/container/centercontainer")
local DataStorage      = require("datastorage")
local Device           = require("device")
local Font             = require("ui/font")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local GestureRange     = require("ui/gesturerange")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local IconButton       = require("ui/widget/iconbutton")
local ImageWidget      = require("ui/widget/imagewidget")
local InputContainer   = require("ui/widget/container/inputcontainer")
local LeftContainer    = require("ui/widget/container/leftcontainer")
local LuaSettings      = require("luasettings")
local Size             = require("ui/size")
local TextBoxWidget    = require("ui/widget/textboxwidget")
local TextWidget       = require("ui/widget/textwidget")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local logger           = require("logger")
local _                = require("gettext")
local Screen           = Device.screen

local UI = require("sui_core")

-- Path of the persistent currently-reading cache. Stores the raw API
-- response so a fresh open paints immediately without hitting the network;
-- the user pulls fresh data via the title-bar sync button.
local CACHE_PATH = DataStorage:getDataDir() .. "/bookfusion_currently_reading.lua"

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Loads the BookFusion plugin sibling modules. Returns nil on failure so
-- callers can show a friendly "not installed" message instead of crashing.
local function _loadBF()
    local bf = {}
    local mods = {
        api        = "bf_api",
        settings   = "bf_settings",
        browser    = "bf_browser",
        downloader = "bf_downloader",
        covermenu  = "bf_covermenu",
    }
    for k, name in pairs(mods) do
        local ok, mod = pcall(require, name)
        if not ok then
            logger.warn("simpleui bookfusion: missing module", name, "—", tostring(mod))
            return nil
        end
        bf[k] = mod
    end
    return bf
end

-- Resolves the live BookFusion plugin instance attached to the FileManager so
-- we can reuse its already-built api/settings (avoids re-opening luasettings).
local function _liveBFPlugin()
    local FM = package.loaded["apps/filemanager/filemanager"]
    local fm = FM and FM.instance
    if not fm then return nil end
    if fm.bookfusion then return fm.bookfusion end
    if type(fm.plugins) == "table" then
        for _, p in ipairs(fm.plugins) do
            if p and p.name == "bookfusion" then return p end
        end
    end
    return nil
end

local function _showInfo(text)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = 3 })
end

-- ---------------------------------------------------------------------------
-- Persistent cache
-- Stores the raw API book array so the page paints from disk on open.
-- Cover thumbnails themselves live in CoverCache (bf_covercache) keyed by URL,
-- so once a sync has run, both metadata and images are available offline.
-- ---------------------------------------------------------------------------

local function _cacheStore()
    return LuaSettings:open(CACHE_PATH)
end

local function _loadCachedBooks()
    local s = _cacheStore()
    return s:readSetting("books")
end

local function _saveCachedBooks(books)
    local s = _cacheStore()
    s:saveSetting("books", books or {})
    s:saveSetting("synced_at", os.time())
    s:flush()
end

-- Aspect-ratio-preserving scale factor (mirrors bf_listmenu).
local function _coverScale(img_w, img_h, max_w, max_h)
    local fitted_w = math.floor(max_h * img_w / img_h + 0.5)
    if max_w >= fitted_w then
        return fitted_w / img_w
    end
    return math.floor(max_w * img_h / img_w + 0.5) / img_h
end

-- Promotes a book entry's cached cover (disk → in-memory blitbuffer) so it
-- renders immediately. Mirrors bf_listmenu's L1/L2 cache logic. Sets
-- lazy_load_cover = true if neither cache layer has the image, so the
-- bf_covermenu lazy loader picks it up.
local function _hydrateEntryCover(entry)
    if entry.cover_bb then
        entry.cover_bb:free()
        entry.cover_bb = nil
    end
    if entry.cover_data then
        local RenderImage = require("ui/renderimage")
        entry.cover_bb = RenderImage:renderImageData(
            entry.cover_data, #entry.cover_data, false, entry.cover_w, entry.cover_h)
        entry.cover_bb:setAllocated(1)
        entry.has_cover       = true
        entry.lazy_load_cover = false
        return
    end
    if entry.cover_url then
        local CoverCache = require("bf_covercache")
        local data = CoverCache.read(entry.cover_url)
        if data then
            local RenderImage = require("ui/renderimage")
            entry.cover_data = data
            entry.cover_bb = RenderImage:renderImageData(
                data, #data, false, entry.cover_w, entry.cover_h)
            entry.cover_bb:setAllocated(1)
            entry.has_cover       = true
            entry.lazy_load_cover = false
        else
            entry.lazy_load_cover = true
            entry.has_cover       = false
        end
    end
end

-- ---------------------------------------------------------------------------
-- Cover thumbnail widget
-- A single tappable book in the horizontal "Currently Reading" strip.
-- Renders a framed cover image with the title (and optional "Downloaded"
-- marker) below. Has an :update() method so the bf_covermenu lazy loader
-- can refresh the cover after the image data arrives.
-- ---------------------------------------------------------------------------

local BookCoverThumb = InputContainer:extend{
    entry      = nil,   -- book entry from _buildBookEntries
    menu       = nil,   -- parent menu (for onMenuSelect dispatch)
    thumb_w    = 0,
    thumb_h    = 0,
    caption_h  = 0,
}

function BookCoverThumb:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = self.thumb_w,
        h = self.thumb_h + self.caption_h,
    }
    self.ges_events.TapSelect = {
        GestureRange:new{ ges = "tap", range = self.dimen },
    }
    self:update()
end

function BookCoverThumb:update()
    local border = Size.border.thin
    local img_max_w = self.thumb_w - 2 * border
    local img_max_h = self.thumb_h - 2 * border

    local cover_widget
    local cover_bb_used = false

    if self.entry.has_cover and self.entry.cover_bb then
        cover_bb_used = true
        local bb_w = self.entry.cover_bb:getWidth()
        local bb_h = self.entry.cover_bb:getHeight()
        local img_w = self.entry.cover_w or bb_w
        local img_h = self.entry.cover_h or bb_h
        local scale_factor = _coverScale(img_w, img_h, img_max_w, img_max_h)
        local wimage = ImageWidget:new{
            image        = self.entry.cover_bb,
            scale_factor = scale_factor,
        }
        wimage:_render()
        local sz = wimage:getSize()
        cover_widget = CenterContainer:new{
            dimen = Geom:new{ w = self.thumb_w, h = self.thumb_h },
            FrameContainer:new{
                width      = sz.w + 2 * border,
                height     = sz.h + 2 * border,
                margin     = 0,
                padding    = 0,
                bordersize = border,
                wimage,
            },
        }
        if self.menu then self.menu._has_cover_images = true end
        self._has_cover_image = true
    else
        -- Placeholder frame while loading / when cover missing.
        local fake_w = math.floor(img_max_w * 0.85)
        local fake_h = img_max_h
        if self.entry.cover_w and self.entry.cover_h then
            local scale_factor = _coverScale(
                self.entry.cover_w, self.entry.cover_h, img_max_w, img_max_h)
            fake_w = math.floor(self.entry.cover_w * scale_factor)
            fake_h = math.floor(self.entry.cover_h * scale_factor)
        end
        cover_widget = CenterContainer:new{
            dimen = Geom:new{ w = self.thumb_w, h = self.thumb_h },
            FrameContainer:new{
                width      = fake_w + 2 * border,
                height     = fake_h + 2 * border,
                margin     = 0,
                padding    = 0,
                bordersize = border,
                CenterContainer:new{
                    dimen = Geom:new{ w = fake_w, h = fake_h },
                    TextWidget:new{
                        text = "\u{26F6}",
                        face = Font:getFace("cfont", math.max(14, math.floor(fake_h / 4))),
                    },
                },
            },
        }
    end

    -- Free unused cover_bb (mirrors bf_listmenu).
    if self.entry.cover_bb and not cover_bb_used then
        self.entry.cover_bb:free()
    end

    -- Caption: title (+ "Downloaded" marker if present).
    local caption_text = self.entry.book and self.entry.book.title or _("Untitled")
    if self.entry.mandatory then
        caption_text = caption_text .. "  · " .. self.entry.mandatory
    end
    local caption = TextBoxWidget:new{
        text                          = caption_text,
        face                          = Font:getFace("cfont", 14),
        width                         = self.thumb_w,
        height                        = self.caption_h,
        height_adjust                 = true,
        height_overflow_show_ellipsis = true,
        alignment                     = "center",
    }

    self[1] = CenterContainer:new{
        dimen = self.dimen:copy(),
        VerticalGroup:new{
            align = "center",
            cover_widget,
            VerticalSpan:new{ width = Screen:scaleBySize(4) },
            caption,
        },
    }
    self.refresh_dimen = self.dimen
end

function BookCoverThumb:onTapSelect()
    if self.menu and self.menu.onMenuSelect then
        self.menu:onMenuSelect(self.entry)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Folder row widget
-- A single tappable folder shortcut row beneath the cover strip.
-- ---------------------------------------------------------------------------

local FolderRow = InputContainer:extend{
    entry  = nil,
    menu   = nil,
    width  = 0,
    height = 0,
}

function FolderRow:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events.TapSelect = {
        GestureRange:new{ ges = "tap", range = self.dimen },
    }
    local pad_h = Screen:scaleBySize(16)
    self[1] = LeftContainer:new{
        dimen = self.dimen:copy(),
        HorizontalGroup:new{
            HorizontalSpan:new{ width = pad_h },
            TextWidget:new{
                text = self.entry.text,
                face = Font:getFace("cfont", 20),
                bold = true,
            },
        },
    }
end

function FolderRow:onTapSelect()
    if self.menu and self.menu.onMenuSelect then
        self.menu:onMenuSelect(self.entry)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Item-table builder
-- Returns { books = {...}, folders = {...} }. The book array drives the
-- horizontal cover strip; the folder array drives the bottom rows.
-- A flat compatibility list (books followed by folders) is also stashed on
-- the menu as item_table so Menu:init / FocusManager don't choke on emptiness.
-- ---------------------------------------------------------------------------

local function _buildBookEntries(bf, settings, books)
    if books == nil then return nil end
    local out = {}
    local Downloader   = bf.downloader
    local download_dir = Downloader.getDownloadDir(settings)
    for _i, book in ipairs(books) do
        local authors  = Downloader.formatAuthors(book.authors)
        local cover    = book.cover
        local filename = Downloader.buildFilename(book)
        local filepath = download_dir .. "/" .. filename
        local entry = {
            book            = book,
            authors_text    = authors ~= "" and authors or nil,
            cover_url       = cover and cover.url,
            cover_w         = cover and cover.width,
            cover_h         = cover and cover.height,
            lazy_load_cover = cover and cover.url ~= nil,
            has_cover       = false,
        }
        if Downloader.fileExists(filepath) then
            entry.mandatory = _("Downloaded")
        end
        out[#out + 1] = entry
    end
    return out
end

local function _buildFolderEntries()
    return {
        {
            text   = _("Plan to Read"),
            folder = { title = _("Plan to Read"), filters = { list = "planned_to_read" } },
        },
        {
            text   = _("Favorites"),
            folder = { title = _("Favorites"),    filters = { list = "favorites" } },
        },
    }
end

-- A non-empty placeholder so Menu:init doesn't divide by zero. The contents
-- are never actually rendered — _updateItemsBuildUI builds its own widget
-- tree from menu._books / menu._folders.
local function _placeholderItemTable()
    return { { text = "" } }
end

-- ---------------------------------------------------------------------------
-- Section header builder (used inside _updateItemsBuildUI)
-- ---------------------------------------------------------------------------

local function _sectionHeader(text, content_w)
    local pad_h = Screen:scaleBySize(16)
    local pad_v = Screen:scaleBySize(8)
    return FrameContainer:new{
        background    = nil,
        bordersize    = 0,
        padding_left  = pad_h,
        padding_right = pad_h,
        padding_top   = pad_v,
        padding_bot   = math.floor(pad_v / 2),
        width         = content_w,
        TextWidget:new{
            text   = text,
            face   = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            bold   = true,
        },
    }
end

local function _placeholderRow(text, content_w)
    local pad_h = Screen:scaleBySize(16)
    return FrameContainer:new{
        background    = nil,
        bordersize    = 0,
        padding_left  = pad_h,
        padding_right = pad_h,
        padding_top   = Screen:scaleBySize(4),
        padding_bot   = Screen:scaleBySize(4),
        width         = content_w,
        TextWidget:new{
            text    = text,
            face    = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Menu method overrides
-- ---------------------------------------------------------------------------

-- Custom dimension recalculation: no pagination footer, single page, the
-- whole content area is owned by our custom layout.
local function _recalculateDimen(self)
    local top_height = 0
    if self.title_bar and not self.no_title then
        top_height = self.title_bar:getHeight()
    end
    self.others_height   = top_height
    self.available_height = self.inner_dimen.h - top_height
    self.perpage          = math.max(#self.item_table, 1)
    self.page_num         = 1
    self.page             = 1
    self.item_dimen = Geom:new{
        x = 0, y = 0,
        w = self.inner_dimen.w,
        h = self.available_height,
    }
end

-- Custom item builder: composes the section headers, horizontal cover strip
-- (with paging arrows when more books exist than fit on one screen) and
-- folder rows directly into self.item_group. Populates self.layout for focus
-- management and self.items_to_update for the lazy cover loader.
local function _updateItemsBuildUI(self)
    local content_w = self.inner_dimen.w
    local content_h = self.available_height

    local books   = self._books
    local folders = self._folders or {}

    local vg = VerticalGroup:new{ align = "left" }

    -- ── Currently Reading ──
    table.insert(vg, _sectionHeader(_("Currently Reading"), content_w))

    if books == nil then
        table.insert(vg, _placeholderRow(_("Loading…"), content_w))
    elseif #books == 0 then
        table.insert(vg, _placeholderRow(_("No books currently reading."), content_w))
    else
        -- Strip layout constants. Arrow gutters are reserved even when
        -- there's only one page so the strip stays centered and doesn't
        -- visually shift between pages.
        local caption_h     = Screen:scaleBySize(44)
        local strip_pad_h   = Screen:scaleBySize(16)
        local cell_pad      = Screen:scaleBySize(16)
        local arrow_size    = Screen:scaleBySize(48)
        local strip_inner_w = content_w - 2 * (strip_pad_h + arrow_size + cell_pad)
        local strip_max_h   = math.floor(content_h * 0.72) - caption_h - Screen:scaleBySize(12)

        -- Cover sizing: guarantee that at least MIN_PER_PAGE thumbs fit
        -- horizontally (caller asked for "at least 3 per row"), then enlarge
        -- if there's vertical room. Cap to a maximum so single-book strips
        -- don't get an absurd cover on a tall screen.
        local MIN_PER_PAGE   = 3
        local max_thumb_w    = math.floor((strip_inner_w - (MIN_PER_PAGE - 1) * cell_pad) / MIN_PER_PAGE)
        local thumb_w_from_h = math.floor(strip_max_h * 2 / 3)
        local cap_thumb_w    = Screen:scaleBySize(220)  -- cosmetic upper bound
        local thumb_w        = math.min(max_thumb_w, thumb_w_from_h, cap_thumb_w)
        if thumb_w < Screen:scaleBySize(110) then
            thumb_w = Screen:scaleBySize(110)
        end
        local thumb_h = math.floor(thumb_w * 3 / 2)

        -- Compute how many fit horizontally with the chosen size. With the
        -- min_per_page floor above, this is always >= MIN_PER_PAGE on any
        -- screen wide enough to host them.
        local cell_w   = thumb_w + cell_pad
        local per_page = math.max(1, math.floor((strip_inner_w + cell_pad) / cell_w))

        local n           = #books
        local total_pages = math.max(1, math.ceil(n / per_page))
        local page        = self._strip_page or 1
        if page < 1 then page = 1 end
        if page > total_pages then page = total_pages end
        self._strip_page  = page
        self._strip_pages = total_pages

        local first_idx   = (page - 1) * per_page + 1
        local last_idx    = math.min(first_idx + per_page - 1, n)
        local visible_n   = last_idx - first_idx + 1

        -- Centre the visible thumbs in the strip's available width.
        local thumbs_used_w = visible_n * thumb_w + (visible_n - 1) * cell_pad
        local lead_pad      = math.max(0, math.floor((strip_inner_w - thumbs_used_w) / 2))

        local thumbs_hg = HorizontalGroup:new{ align = "top" }
        if lead_pad > 0 then
            table.insert(thumbs_hg, HorizontalSpan:new{ width = lead_pad })
        end
        for i = first_idx, last_idx do
            local entry = books[i]
            _hydrateEntryCover(entry)
            local thumb = BookCoverThumb:new{
                entry       = entry,
                menu        = self,
                thumb_w     = thumb_w,
                thumb_h     = thumb_h,
                caption_h   = caption_h,
                show_parent = self.show_parent,
            }
            table.insert(thumbs_hg, thumb)
            if i < last_idx then
                table.insert(thumbs_hg, HorizontalSpan:new{ width = cell_pad })
            end
            if entry.lazy_load_cover or (entry.cover_url and not entry.has_cover) then
                table.insert(self.items_to_update, thumb)
            end
            table.insert(self.layout, { thumb })
        end

        -- Page arrows. Always built so the strip width is stable across
        -- pages; hidden (replaced with a transparent span) at the edges.
        local function _strip_arrow(icon_name, enabled, on_tap)
            if enabled then
                return IconButton:new{
                    icon        = icon_name,
                    width       = arrow_size,
                    height      = arrow_size,
                    padding     = Screen:scaleBySize(4),
                    callback    = on_tap,
                    show_parent = self.show_parent,
                }
            end
            return HorizontalSpan:new{ width = arrow_size }
        end

        local left_arrow = _strip_arrow("chevron.left", page > 1, function()
            self._strip_page = (self._strip_page or 1) - 1
            self:updateItems()
        end)
        local right_arrow = _strip_arrow("chevron.right", page < total_pages, function()
            self._strip_page = (self._strip_page or 1) + 1
            self:updateItems()
        end)

        local strip_hg = HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = strip_pad_h },
            CenterContainer:new{
                dimen = Geom:new{ w = arrow_size, h = thumb_h },
                left_arrow,
            },
            HorizontalSpan:new{ width = cell_pad },
            CenterContainer:new{
                dimen = Geom:new{ w = strip_inner_w, h = thumb_h + caption_h },
                thumbs_hg,
            },
            HorizontalSpan:new{ width = cell_pad },
            CenterContainer:new{
                dimen = Geom:new{ w = arrow_size, h = thumb_h },
                right_arrow,
            },
            HorizontalSpan:new{ width = strip_pad_h },
        }

        if total_pages > 1 then
            table.insert(self.layout, { left_arrow, right_arrow })
        end

        table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(6) })
        table.insert(vg, strip_hg)

        -- "Page X of Y" indicator (only when more than one page).
        if total_pages > 1 then
            local page_label = TextWidget:new{
                text    = string.format("%d / %d", page, total_pages),
                face    = Font:getFace("cfont", 14),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            }
            table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(4) })
            table.insert(vg, CenterContainer:new{
                dimen = Geom:new{ w = content_w, h = page_label:getSize().h },
                page_label,
            })
        end
        table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(12) })
    end

    -- ── Folders ──
    table.insert(vg, _sectionHeader(_("Folders"), content_w))
    local row_h = Screen:scaleBySize(56)
    for _i, folder_entry in ipairs(folders) do
        local row = FolderRow:new{
            entry       = folder_entry,
            menu        = self,
            width       = content_w,
            height      = row_h,
            show_parent = self.show_parent,
        }
        table.insert(vg, row)
        table.insert(self.layout, { row })
    end

    table.insert(self.item_group, vg)
end

-- Drops the page_info BottomContainer from the menu's outer OverlapGroup so
-- pagination footer is never painted. Must run AFTER Menu:init has built
-- self[1] = FrameContainer{ OverlapGroup{ content_group, page_return, footer } }.
-- Indices match koreader/frontend/ui/widget/menu.lua menu.lua:896-919.
local function _stripPaginationFooter(menu)
    local frame = menu[1]
    if not frame then return end
    local overlap = frame[1]
    if not overlap then return end
    -- Footer is the third positional child of the OverlapGroup. Walk
    -- defensively in case future KOReader changes shuffle the order.
    for i = #overlap, 1, -1 do
        local child = overlap[i]
        if child == menu.page_info or (child and child[1] == menu.page_info) then
            table.remove(overlap, i)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Page widget
-- ---------------------------------------------------------------------------

M._instance = nil

function M.show()
    local bf = _loadBF()
    if not bf then
        _showInfo(_("BookFusion plugin is not installed or enabled."))
        return
    end

    local bf_plugin = _liveBFPlugin()
    local settings  = (bf_plugin and bf_plugin.bf_settings) or bf.settings:new()
    local api       = (bf_plugin and bf_plugin.api)         or bf.api:new(settings)

    if not settings:isLoggedIn() then
        _showInfo(_("Link your BookFusion account first (Tools → BookFusion)."))
        return
    end

    if M._instance then return end

    local Menu = require("ui/widget/menu")
    local PageMenu = Menu:extend{}

    local browser = bf.browser:new(api, settings)
    local menu
    local syncing = false  -- guards against re-entrant sync taps

    local function open_folder(folder)
        if not folder then return end
        if menu then
            menu._navbar_closing_intentionally = true
            UIManager:close(menu)
        end
        local nbrowser = bf.browser:new(api, settings)
        nbrowser:show()
        nbrowser:openBookList(folder.title, folder.filters)
    end

    -- Pulls fresh currently-reading data from the API, writes it to cache,
    -- and re-renders the strip. Shows a transient "Syncing…" InfoMessage so
    -- the user gets feedback while the network round-trip is in flight.
    local function doSync()
        if syncing then return end
        syncing = true
        local InfoMessage = require("ui/widget/infomessage")
        local NetworkMgr  = require("ui/network/manager")
        local notice = InfoMessage:new{ text = _("Syncing…") }
        UIManager:show(notice)
        UIManager:scheduleIn(0.05, function()
            NetworkMgr:runWhenOnline(function()
                local ok, data = api:searchBooks{
                    list     = "currently_reading",
                    sort     = "last_read_at-desc",
                    page     = 1,
                    per_page = 20,
                }
                UIManager:close(notice)
                syncing = false
                if not ok then
                    _showInfo(_("Sync failed."))
                    return
                end
                _saveCachedBooks(data or {})
                if M._instance == menu then
                    menu._books      = _buildBookEntries(bf, settings, data or {})
                    menu._strip_page = 1
                    menu:updateItems()
                end
            end)
        end)
    end

    local function doSearch()
        if menu then
            menu._navbar_closing_intentionally = true
            UIManager:close(menu)
        end
        local nbrowser = bf.browser:new(api, settings)
        nbrowser:show()
        nbrowser:showBookSearchDialog()
    end

    -- Build a custom title bar so we can put a refresh icon on the right
    -- (Menu's default close_callback would otherwise commandeer right_icon
    -- with a "close" button — see TitleBar:init line 87). The bottom navbar
    -- handles tab switching, so we don't need an explicit close button here.
    local title_bar = TitleBar:new{
        width                   = Screen:getWidth(),
        fullscreen              = "true",
        align                   = "center",
        title                   = _("BookFusion"),
        left_icon               = "appbar.search",
        left_icon_tap_callback  = doSearch,
        right_icon              = "cre.render.reload",
        right_icon_tap_callback = doSync,
    }

    menu = PageMenu:new{
        name              = "bookfusion",
        title             = _("BookFusion"),
        item_table        = _placeholderItemTable(),
        height            = UI.getContentHeight(),
        y                 = UI.getContentTop(),
        _navbar_height_reduced = true,
        is_borderless     = true,
        is_popout         = false,
        covers_fullscreen = true,
        custom_title_bar  = title_bar,
        onMenuSelect = function(_self_menu, item)
            if not item then return end
            local ok, err = pcall(function()
                if item.book then
                    browser:onSelectBook(item.book)
                elseif item.folder then
                    open_folder(item.folder)
                end
            end)
            if not ok then
                logger.warn("simpleui bookfusion: onMenuSelect error:", tostring(err))
                _showInfo("Error:\n" .. tostring(err))
            end
        end,
        close_callback = function()
            if menu then UIManager:close(menu) end
        end,
    }

    -- Initial state: try the disk cache first; only auto-fetch if there is
    -- no cache yet (so first-time users still see content without having to
    -- tap sync). Folder shortcuts are always available.
    local cached_books = _loadCachedBooks()
    menu._books      = cached_books and _buildBookEntries(bf, settings, cached_books) or nil
    menu._folders    = _buildFolderEntries()
    menu._strip_page = 1

    -- Plug in our custom layout / orchestration. We still reuse bf_covermenu's
    -- updateItems for the lazy image-loading pipeline (it iterates
    -- self.items_to_update and calls item:update() after each cover loads),
    -- but pair it with our own _recalculateDimen and _updateItemsBuildUI.
    menu.updateItems          = bf.covermenu.updateItems
    menu.onCloseWidget        = function(self_w)
        M._instance = nil
        if bf.covermenu.onCloseWidget then
            return bf.covermenu.onCloseWidget(self_w)
        end
    end
    menu._recalculateDimen   = _recalculateDimen
    menu._updateItemsBuildUI = _updateItemsBuildUI
    menu._do_cover_images    = true

    -- No pagination footer: drop it from the outer OverlapGroup and stub
    -- updatePageInfo so subsequent updateItems calls don't try to repaint it.
    _stripPaginationFooter(menu)
    menu.updatePageInfo = function() end

    -- Opt out of sui_titlebar's injected-button rewrite, which would
    -- otherwise zero our custom right button (the sync icon) when
    -- "inj_right" is not enabled in the SimpleUI titlebar config. We
    -- already provide both search and sync ourselves, so the SimpleUI
    -- title-bar pass has nothing useful to add here.
    menu._titlebar_inj_patched = true

    -- Force a re-layout now that the placeholder item_table has been replaced
    -- with our custom builder; the original Menu:init already called
    -- updateItems once with the listmenu defaults.
    menu:updateItems()

    M._instance = menu
    UIManager:show(menu)

    -- First-time users have no cache yet — kick off an initial sync so they
    -- see real data instead of an empty strip. Subsequent opens are
    -- cache-only until the user taps the refresh button.
    if cached_books == nil then
        UIManager:scheduleIn(0.2, doSync)
    end
end

return M
