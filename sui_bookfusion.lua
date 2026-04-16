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
local IconWidget       = require("ui/widget/iconwidget")
local ImageWidget      = require("ui/widget/imagewidget")
local InputContainer   = require("ui/widget/container/inputcontainer")
local LeftContainer    = require("ui/widget/container/leftcontainer")
local LineWidget       = require("ui/widget/linewidget")
local LuaSettings      = require("luasettings")
local OverlapGroup     = require("ui/widget/overlapgroup")
local RightContainer   = require("ui/widget/container/rightcontainer")
local Size             = require("ui/size")
local TextBoxWidget    = require("ui/widget/textboxwidget")
local TextWidget       = require("ui/widget/textwidget")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local logger           = require("logger")
local _                = require("gettext")
local Screen           = Device.screen

local UI = require("sui_core")

-- Lazy-loaded heavy modules (loaded once on first use).
local RenderImage  -- require("ui/renderimage")
local CoverCache   -- require("bf_covercache")

local CACHE_PATH = DataStorage:getDataDir() .. "/bookfusion_currently_reading.lua"

-- Progress bar colours (matches SimpleUI home screen).
local _CLR_BAR_BG = Blitbuffer.gray(0.15)
local _CLR_BAR_FG = Blitbuffer.gray(0.75)

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
-- Persistent cache (singleton)
-- ---------------------------------------------------------------------------

local _cache  -- lazily opened LuaSettings instance

local function _cacheStore()
    if not _cache then
        _cache = LuaSettings:open(CACHE_PATH)
    end
    return _cache
end

local function _loadCachedList(key)
    return _cacheStore():readSetting(key or "books")
end

local function _saveCachedList(key, books)
    local s = _cacheStore()
    s:saveSetting(key or "books", books or {})
    s:saveSetting("synced_at", os.time())
    s:flush()
end

-- ---------------------------------------------------------------------------
-- Shared layout helpers
-- ---------------------------------------------------------------------------

-- Thin progress bar identical to the one on the SimpleUI home screen.
local function _progressBar(w, pct, bh)
    bh = bh or Screen:scaleBySize(4)
    local fw = math.max(0, math.floor(w * math.min(pct or 0, 1.0)))
    if fw <= 0 then
        return LineWidget:new{ dimen = Geom:new{ w = w, h = bh }, background = _CLR_BAR_BG }
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = bh },
        LineWidget:new{ dimen = Geom:new{ w = w,  h = bh }, background = _CLR_BAR_BG },
        LineWidget:new{ dimen = Geom:new{ w = fw, h = bh }, background = _CLR_BAR_FG },
    }
end

-- Reads percent_finished for a local file from DocSettings.
local function _readLocalPercent(filepath)
    local DocSettings = require("docsettings")
    if DocSettings and filepath then
        local ok, ds = pcall(DocSettings.open, DocSettings, filepath)
        if ok and ds then
            return ds:readSetting("percent_finished") or 0
        end
    end
    return 0
end

-- Aspect-ratio-preserving scale factor (mirrors bf_listmenu).
local function _coverScale(img_w, img_h, max_w, max_h)
    local fitted_w = math.floor(max_h * img_w / img_h + 0.5)
    if max_w >= fitted_w then
        return fitted_w / img_w
    end
    return math.floor(max_w * img_h / img_w + 0.5) / img_h
end

-- Promotes a book entry's cached cover (disk -> in-memory blitbuffer).
local function _hydrateEntryCover(entry)
    -- Fast path: already decoded into a live blitbuffer — reuse across
    -- page turns instead of freeing and re-decoding each render.
    if entry.has_cover and entry.cover_bb then return end
    if entry.cover_bb then
        entry.cover_bb:free()
        entry.cover_bb = nil
    end
    if entry.cover_data then
        if not RenderImage then RenderImage = require("ui/renderimage") end
        entry.cover_bb = RenderImage:renderImageData(
            entry.cover_data, #entry.cover_data, false, entry.cover_w, entry.cover_h)
        entry.cover_bb:setAllocated(1)
        entry.has_cover       = true
        entry.lazy_load_cover = false
        return
    end
    if entry.cover_url then
        if not CoverCache then CoverCache = require("bf_covercache") end
        local data = CoverCache.read(entry.cover_url)
        if data then
            if not RenderImage then RenderImage = require("ui/renderimage") end
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

-- Computes cover thumbnail sizing for a grid / strip layout.
-- opts fields:
--   available_w  : total width for covers (excluding outer padding/arrows)
--   max_h        : maximum cover height (nil = uncapped)
--   min_per_row  : minimum covers per row (default 3)
--   cap_thumb_w  : cosmetic upper bound on thumb width (default 220)
--   min_thumb_w  : floor thumb width (default 80)
-- Returns { thumb_w, thumb_h, cols }
local function _computeThumbSize(opts)
    local cell_pad   = Screen:scaleBySize(opts.cell_pad or 16)
    local min_n      = opts.min_per_row or 3
    local cap_w      = Screen:scaleBySize(opts.cap_thumb_w or 220)
    local min_w      = Screen:scaleBySize(opts.min_thumb_w or 80)
    local avail_w    = opts.available_w

    local max_thumb_w = math.floor((avail_w - (min_n - 1) * cell_pad) / min_n)
    local thumb_w     = math.min(max_thumb_w, cap_w)

    -- Optionally constrain by height.
    if opts.max_h then
        local from_h = math.floor(opts.max_h * 2 / 3)
        thumb_w = math.min(thumb_w, from_h)
    end

    if thumb_w < min_w then thumb_w = min_w end
    local thumb_h = math.floor(thumb_w * 3 / 2)
    local cols = math.max(1, math.floor((avail_w + cell_pad) / (thumb_w + cell_pad)))

    return { thumb_w = thumb_w, thumb_h = thumb_h, cols = cols }
end

-- Forward declaration — defined after _buildCoverRows so it can be referenced.
local BookCoverThumb

-- Cheap "is this cover already on disk?" check. Lets us decide whether to
-- hydrate locally (fast) or queue a URL fetch (network). lfs.attributes with
-- "mode" is a single stat syscall — no file read.
local _lfs
local function _isInDiskCache(cover_url)
    if not cover_url then return false end
    if not _lfs then _lfs = require("libs/libkoreader-lfs") end
    if not CoverCache then CoverCache = require("bf_covercache") end
    return _lfs.attributes(CoverCache.path(cover_url), "mode") == "file"
end

-- Hydrates queued thumbs' covers one-at-a-time on the event loop so a page
-- turn can paint its placeholders immediately and covers pop in afterward.
-- Each menu:updateItems() bumps a generation; any in-flight step whose gen
-- no longer matches aborts, so rapid page flips don't stack up.
local function _kickAsyncHydration(menu)
    local pending = menu._pending_cover_hydration
    menu._pending_cover_hydration = nil
    if not pending or #pending == 0 then return end

    menu._hydration_gen = (menu._hydration_gen or 0) + 1
    local gen = menu._hydration_gen
    local i = 1

    local function step()
        if menu._hydration_gen ~= gen then return end
        if menu._view ~= "folder" then return end
        if i > #pending then return end

        local thumb = pending[i]
        i = i + 1
        if thumb and thumb.entry then
            local entry = thumb.entry
            if not (entry.has_cover and entry.cover_bb) then
                _hydrateEntryCover(entry)
                if entry.has_cover and entry.cover_bb then
                    thumb:update()
                    if thumb[1] and thumb[1].dimen then
                        UIManager:setDirty(menu.show_parent, function()
                            return "ui", thumb[1].dimen
                        end)
                    end
                end
            end
        end
        UIManager:nextTick(step)
    end
    UIManager:nextTick(step)
end

-- Builds a navigation arrow (enabled = tappable IconButton, disabled = spacer).
local function _buildArrow(icon, size, pad, enabled, callback, show_parent)
    if enabled then
        return IconButton:new{
            icon        = icon,
            width       = size,
            height      = size,
            padding     = pad,
            callback    = callback,
            show_parent = show_parent,
        }
    end
    return HorizontalSpan:new{ width = size + 2 * (pad or 0) }
end

-- Builds rows of BookCoverThumb widgets from entries[start_idx..end_idx].
-- Appends rows to `vg`, layout rows to `layout`, lazy-load items to
-- `items_to_update`. Returns the number of rows actually built.
local function _buildCoverRows(params)
    local entries    = params.entries
    local start_idx  = params.start_idx
    local end_idx    = params.end_idx
    local thumb_w    = params.thumb_w
    local thumb_h    = params.thumb_h
    local caption_h  = params.caption_h
    local bar_total_h = params.bar_total_h
    local cell_pad   = params.cell_pad
    local grid_pad_h = params.grid_pad_h
    local cols       = params.cols
    local max_rows   = params.max_rows or 999
    local menu       = params.menu
    local vg         = params.vg
    local layout     = params.layout
    local items_to_update = params.items_to_update

    local idx = start_idx
    local rows_built = 0
    for _ = 1, max_rows do
        if idx > end_idx then break end
        local row_hg = HorizontalGroup:new{ align = "top" }
        if grid_pad_h > 0 then
            table.insert(row_hg, HorizontalSpan:new{ width = grid_pad_h })
        end
        local row_layout = {}
        for c = 1, cols do
            if idx > end_idx then break end
            local entry = entries[idx]
            -- NOTE: we no longer call _hydrateEntryCover(entry) here. Decoding
            -- covers synchronously during the page build is what made page
            -- turns feel slow. Instead, thumbs render a placeholder if the
            -- entry isn't already hydrated in memory, and we queue them for
            -- async hydration (disk read + decode) after the page paints, or
            -- for a URL fetch (via covermenu's items_to_update loader) when
            -- the cover isn't cached on disk yet.
            local thumb = BookCoverThumb:new{
                entry       = entry,
                menu        = menu,
                thumb_w     = thumb_w,
                thumb_h     = thumb_h,
                caption_h   = caption_h,
                bar_total_h = bar_total_h,
                show_parent = menu.show_parent,
            }
            table.insert(row_hg, thumb)
            table.insert(row_layout, thumb)
            local has_live_cover = entry.has_cover and entry.cover_bb
            if not has_live_cover then
                if entry.cover_data or _isInDiskCache(entry.cover_url) then
                    -- Bytes already local — async decode on the event loop.
                    if menu._pending_cover_hydration then
                        table.insert(menu._pending_cover_hydration, thumb)
                    end
                elseif entry.cover_url then
                    -- Cache miss: covermenu's URL fetcher will pick it up.
                    entry.lazy_load_cover = true
                    table.insert(items_to_update, thumb)
                end
            end
            if c < cols and idx < end_idx then
                table.insert(row_hg, HorizontalSpan:new{ width = cell_pad })
            end
            idx = idx + 1
        end
        table.insert(vg, row_hg)
        table.insert(layout, row_layout)
        rows_built = rows_built + 1
        if idx <= end_idx then
            table.insert(vg, VerticalSpan:new{ width = cell_pad })
        end
    end
    return rows_built
end

-- Section header used in both home and folder views.
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
            text    = text,
            face    = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            bold    = true,
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

-- Wraps a VerticalGroup in a full-height white background so view switching
-- doesn't leave stale pixels.
local function _wrapInBackground(content_w, content_h, vg)
    return OverlapGroup:new{
        dimen           = Geom:new{ w = content_w, h = content_h },
        allow_mirroring = false,
        LineWidget:new{
            dimen      = Geom:new{ w = content_w, h = content_h },
            background = Blitbuffer.COLOR_WHITE,
        },
        vg,
    }
end

-- ---------------------------------------------------------------------------
-- Item-table builder
-- ---------------------------------------------------------------------------

-- In-place update of download status and progress on existing entries.
-- Pass first/last to limit the refresh to a slice (e.g. just the visible
-- grid page); defaults to the whole list.
local function _refreshDownloadStatus(entries, bf, settings, with_progress, first, last)
    if not entries then return end
    local n = #entries
    if n == 0 then return end
    first = math.max(1, first or 1)
    last  = math.min(n, last or n)
    local Downloader   = bf.downloader
    local download_dir = Downloader.getDownloadDir(settings)
    for i = first, last do
        local entry = entries[i]
        if entry and entry.book then
            local filepath = download_dir .. "/" .. Downloader.buildFilename(entry.book)
            if Downloader.fileExists(filepath) then
                entry.mandatory = _("Downloaded")
                if with_progress then
                    entry.percent = _readLocalPercent(filepath)
                end
            else
                entry.mandatory = nil
                if with_progress then
                    entry.percent = entry.book.cloud_percent or 0
                end
            end
        end
    end
end

-- Builds book entry table from raw API book array. Does NOT check file
-- _refreshDownloadStatus also updates in-place on every updateItems, but we
-- set the initial mandatory/percent here so entries are correct from the start.
local function _buildBookEntries(bf, settings, books, with_progress)
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
            if with_progress then
                entry.percent = _readLocalPercent(filepath)
            end
        elseif with_progress then
            entry.percent = book.cloud_percent or 0
        end
        out[#out + 1] = entry
    end
    return out
end

local function _buildFolderEntries()
    return {
        {
            text   = _("Plan to Read"),
            folder = { title = _("Plan to Read"), filters = { list = "planned_to_read" }, cache_key = "planned_to_read" },
        },
        {
            text   = _("Favorites"),
            folder = { title = _("Favorites"), filters = { list = "favorites" }, cache_key = "favorites" },
        },
        {
            text   = _("Browse BookFusion"),
            browse = true,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Cover thumbnail widget
-- ---------------------------------------------------------------------------

-- Assigned to the forward-declared local above _buildCoverRows.
BookCoverThumb = InputContainer:extend{
    entry       = nil,
    menu        = nil,
    thumb_w     = 0,
    thumb_h     = 0,
    caption_h   = 0,
    bar_total_h = 0,
}

function BookCoverThumb:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = self.thumb_w,
        h = self.thumb_h + self.bar_total_h + self.caption_h,
    }
    self.ges_events.TapSelect = {
        GestureRange:new{ ges = "tap", range = self.dimen },
    }
    self:update()
end

function BookCoverThumb:update()
    local border    = Size.border.thin
    local img_max_w = self.thumb_w - 2 * border
    local img_max_h = self.thumb_h - 2 * border
    local entry     = self.entry

    local cover_widget
    local cover_bb_used = false

    if entry.has_cover and entry.cover_bb then
        cover_bb_used = true
        local img_w = entry.cover_w or entry.cover_bb:getWidth()
        local img_h = entry.cover_h or entry.cover_bb:getHeight()
        local scale_factor = _coverScale(img_w, img_h, img_max_w, img_max_h)
        -- image_disposable = false: we own entry.cover_bb and reuse it across
        -- renders. Without this, ImageWidget's _render() calls scaleBlitBuffer
        -- with free_orig_bb = nil (~= false), which frees our source bb.
        -- The entry's cover_bb is then a dangling pointer; my early-return in
        -- _hydrateEntryCover would reuse it on the next render → crash.
        local wimage = ImageWidget:new{
            image             = entry.cover_bb,
            image_disposable  = false,
            scale_factor      = scale_factor,
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
        if entry.cover_w and entry.cover_h then
            local scale_factor = _coverScale(entry.cover_w, entry.cover_h, img_max_w, img_max_h)
            fake_w = math.floor(entry.cover_w * scale_factor)
            fake_h = math.floor(entry.cover_h * scale_factor)
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

    -- Free unused cover_bb.
    if entry.cover_bb and not cover_bb_used then
        entry.cover_bb:free()
        entry.cover_bb = nil
    end

    -- Not-downloaded badge: small framed down-arrow in the bottom-right corner.
    if not entry.mandatory then
        local badge_pad  = Screen:scaleBySize(4)
        local badge_size = Screen:scaleBySize(22)
        local badge = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = border,
            margin     = 0,
            padding    = 0,
            IconWidget:new{
                icon   = "move.down",
                width  = badge_size - 2 * border,
                height = badge_size - 2 * border,
            },
        }
        badge.overlap_offset = {
            self.thumb_w - badge_size - badge_pad,
            self.thumb_h - badge_size - badge_pad,
        }
        cover_widget = OverlapGroup:new{
            dimen           = Geom:new{ w = self.thumb_w, h = self.thumb_h },
            allow_mirroring = false,
            cover_widget,
            badge,
        }
    end

    -- Caption.
    local caption = TextBoxWidget:new{
        text                          = entry.book and entry.book.title or _("Untitled"),
        face                          = Font:getFace("cfont", 14),
        width                         = self.thumb_w,
        height                        = self.caption_h,
        height_adjust                 = true,
        height_overflow_show_ellipsis = true,
        alignment                     = "center",
    }

    local vg = VerticalGroup:new{ align = "center" }
    table.insert(vg, cover_widget)

    if self.bar_total_h > 0 then
        local bar_gap = Screen:scaleBySize(4)
        local bar_h   = Screen:scaleBySize(5)
        table.insert(vg, VerticalSpan:new{ width = bar_gap })
        table.insert(vg, _progressBar(self.thumb_w, entry.percent or 0, bar_h))
        table.insert(vg, VerticalSpan:new{ width = bar_gap })
    else
        table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    end

    table.insert(vg, caption)
    self[1] = vg
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
    local chevron_size = Screen:scaleBySize(20)
    self[1] = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        LeftContainer:new{
            dimen = self.dimen:copy(),
            HorizontalGroup:new{
                HorizontalSpan:new{ width = pad_h },
                TextWidget:new{
                    text = self.entry.text,
                    face = Font:getFace("cfont", 20),
                    bold = true,
                },
            },
        },
        RightContainer:new{
            dimen = self.dimen:copy(),
            HorizontalGroup:new{
                IconWidget:new{
                    icon   = "chevron.right",
                    width  = chevron_size,
                    height = chevron_size,
                    dim    = true,
                },
                HorizontalSpan:new{ width = pad_h },
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
-- Back-navigation row
-- ---------------------------------------------------------------------------

local BackRow = InputContainer:extend{
    text   = "",
    menu   = nil,
    width  = 0,
    height = 0,
}

function BackRow:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events.TapSelect = {
        GestureRange:new{ ges = "tap", range = self.dimen },
    }
    local pad_h = Screen:scaleBySize(16)
    local chevron_size = Screen:scaleBySize(20)
    self[1] = LeftContainer:new{
        dimen = self.dimen:copy(),
        HorizontalGroup:new{
            HorizontalSpan:new{ width = pad_h },
            IconWidget:new{
                icon   = "chevron.left",
                width  = chevron_size,
                height = chevron_size,
            },
            HorizontalSpan:new{ width = Screen:scaleBySize(4) },
            TextWidget:new{
                text = self.text,
                face = Font:getFace("cfont", 20),
                bold = true,
            },
        },
    }
end

function BackRow:onTapSelect()
    if self.menu then
        local m = self.menu
        local key = m._folder_current_key
        if key and m._folder_grid_page_by_key then
            m._folder_grid_page_by_key[key] = m._folder_grid_page
        end
        m._view = "home"
        m._folder_grid_page = 1
        m:updateItems()
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Pagination helpers (used by both strip and folder grid)
-- ---------------------------------------------------------------------------

local function _paginateIndex(total_items, per_page, current_page)
    local total_pages = math.max(1, math.ceil(total_items / per_page))
    local page = math.max(1, math.min(current_page or 1, total_pages))
    local first_idx = (page - 1) * per_page + 1
    local last_idx  = math.min(first_idx + per_page - 1, total_items)
    return page, total_pages, first_idx, last_idx
end

-- Builds a centred "< page / total >" navigation bar.
local function _buildPageNav(params)
    local page        = params.page
    local total_pages = params.total_pages
    local display_total = params.display_total or total_pages
    local arrow_size  = params.arrow_size
    local arrow_pad   = params.arrow_pad or Screen:scaleBySize(4)
    local cell_pad    = params.cell_pad
    local grid_pad_h  = params.grid_pad_h or 0
    local grid_w      = params.grid_w
    local menu        = params.menu
    local on_prev     = params.on_prev
    local on_next     = params.on_next
    local next_enabled = params.next_enabled
    if next_enabled == nil then next_enabled = page < total_pages end

    local arrow_cell = arrow_size + 2 * arrow_pad

    local left_arrow = _buildArrow("chevron.left", arrow_size, arrow_pad,
        page > 1, on_prev, menu.show_parent)
    local right_arrow = _buildArrow("chevron.right", arrow_size, arrow_pad,
        next_enabled, on_next, menu.show_parent)

    -- Wrap disabled arrows in fixed-width containers for stable layout.
    local function _wrap(arrow)
        return CenterContainer:new{
            dimen = Geom:new{ w = arrow_cell, h = arrow_size },
            arrow,
        }
    end

    local page_label = TextWidget:new{
        text    = string.format("%d / %d", page, display_total),
        face    = Font:getFace("cfont", 14),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local hg = HorizontalGroup:new{ align = "center" }
    if grid_pad_h > 0 then
        table.insert(hg, HorizontalSpan:new{ width = grid_pad_h })
    end
    table.insert(hg, _wrap(left_arrow))
    table.insert(hg, HorizontalSpan:new{ width = cell_pad })
    table.insert(hg, CenterContainer:new{
        dimen = Geom:new{
            w = grid_w - 2 * (arrow_cell + cell_pad),
            h = arrow_size,
        },
        page_label,
    })
    table.insert(hg, HorizontalSpan:new{ width = cell_pad })
    table.insert(hg, _wrap(right_arrow))
    if grid_pad_h > 0 then
        table.insert(hg, HorizontalSpan:new{ width = grid_pad_h })
    end

    return hg, left_arrow, right_arrow
end

-- ---------------------------------------------------------------------------
-- Inline folder view (cover grid)
-- ---------------------------------------------------------------------------

local function _buildFolderViewUI(self)
    local content_w = self.inner_dimen.w
    local content_h = self.available_height
    local vg = VerticalGroup:new{ align = "left" }

    -- Back row.
    local back_h = Screen:scaleBySize(48)
    local back_row = BackRow:new{
        text   = self._folder_title or _("Back"),
        menu   = self,
        width  = content_w,
        height = back_h,
    }
    table.insert(vg, back_row)
    table.insert(self.layout, { back_row })

    local books = self._folder_books

    if books == nil then
        table.insert(vg, _placeholderRow(_("Loading…"), content_w))
        table.insert(self.item_group, _wrapInBackground(content_w, content_h, vg))
        return
    end
    if #books == 0 then
        table.insert(vg, _placeholderRow(_("No books found."), content_w))
        table.insert(self.item_group, _wrapInBackground(content_w, content_h, vg))
        return
    end

    -- Grid constants.
    local caption_h   = Screen:scaleBySize(36)
    local bar_total_h = 0
    local cell_pad    = Screen:scaleBySize(10)
    local grid_pad_h  = Screen:scaleBySize(12)
    local grid_w      = content_w - 2 * grid_pad_h
    local nav_h       = Screen:scaleBySize(40)

    local sizing = _computeThumbSize{
        available_w  = grid_w,
        cell_pad     = 10,
        min_per_row  = 4,
        cap_thumb_w  = 180,
        min_thumb_w  = 80,
    }
    local thumb_w = sizing.thumb_w
    local thumb_h = sizing.thumb_h
    local cols    = sizing.cols

    local cell_total_h = thumb_h + bar_total_h + caption_h
    local remaining_h  = content_h - back_h - nav_h - Screen:scaleBySize(20)
    local max_rows     = math.max(1, math.floor((remaining_h + cell_pad) / (cell_total_h + cell_pad)))
    local per_page     = cols * max_rows
    self._folder_grid_per_page = per_page

    local n = #books
    local page, total_pages, first_idx, last_idx = _paginateIndex(n, per_page, self._folder_grid_page)
    self._folder_grid_page = page

    -- Fresh queue for this render. _buildCoverRows appends thumbs that need
    -- an async local hydrate (disk-cached bytes → blitbuffer); menu.updateItems
    -- drains it after the page paints.
    self._pending_cover_hydration = {}

    table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(4) })

    -- Build cover rows.
    local rows_built = _buildCoverRows{
        entries    = books,
        start_idx  = first_idx,
        end_idx    = last_idx,
        thumb_w    = thumb_w,
        thumb_h    = thumb_h,
        caption_h  = caption_h,
        bar_total_h = bar_total_h,
        cell_pad   = cell_pad,
        grid_pad_h = grid_pad_h,
        cols       = cols,
        max_rows   = max_rows,
        menu       = self,
        vg         = vg,
        layout     = self.layout,
        items_to_update = self.items_to_update,
    }

    -- Bottom navigation.
    local has_more_api = self._folder_total and n < self._folder_total
    -- Watermark prefetch: fire a silent fetch whenever the user is within
    -- one local page of the tail and the server has more. Without this,
    -- prefetch only happens on the user's next-tap, so fast consecutive
    -- turns can still block.
    if has_more_api and not self._folder_fetching
            and (total_pages - page) <= 1 and self._fetchFolderPage then
        self._fetchFolderPage({ silent = true })
    end
    local arrow_size = Screen:scaleBySize(40)
    local nav_hg, left_arrow, right_arrow = _buildPageNav{
        page        = page,
        total_pages = total_pages,
        display_total = (has_more_api and self._folder_total and per_page > 0)
            and math.ceil(self._folder_total / per_page) or total_pages,
        arrow_size  = arrow_size,
        cell_pad    = cell_pad,
        grid_pad_h  = grid_pad_h,
        grid_w      = grid_w,
        menu        = self,
        next_enabled = page < total_pages or has_more_api,
        on_prev = function()
            self._folder_grid_page = page - 1
            self:updateItems()
        end,
        on_next = function()
            if page < total_pages then
                -- Data already loaded locally — advance immediately.
                self._folder_grid_page = page + 1
                self:updateItems()
                -- Prefetch next API batch in the background so the NEXT
                -- page turn is also instant.
                if self._fetchFolderPage then
                    self._fetchFolderPage({ silent = true })
                end
            elseif has_more_api and self._fetchFolderPage then
                -- On the last locally-loaded page but more exist on the
                -- server. Fetch the next batch and advance when it arrives.
                -- Show a transient "Loading…" indicator so the user knows
                -- the page turn is waiting on the network. A timeout is
                -- set as a safety net in case _fetchFolderPage short-
                -- circuits (e.g. concurrent fetch in flight) and never
                -- calls our on_done.
                local InfoMessage = require("ui/widget/infomessage")
                local loading = InfoMessage:new{ text = _("Loading…"), timeout = 10 }
                UIManager:show(loading)
                self._fetchFolderPage({
                    on_done = function()
                        UIManager:close(loading)
                        if self._view == "folder" then
                            self._folder_grid_page = page + 1
                            self:updateItems()
                        end
                    end,
                })
            end
        end,
    }

    -- Push nav to bottom with a spacer.
    local top_gap = Screen:scaleBySize(4)
    local used_h  = back_h + top_gap
        + rows_built * cell_total_h
        + math.max(0, rows_built - 1) * cell_pad
    local nav_bottom_margin = Screen:scaleBySize(16)
    local bottom_spacer = content_h - used_h - Screen:scaleBySize(4) - arrow_size - nav_bottom_margin
    if bottom_spacer > 0 then
        table.insert(vg, VerticalSpan:new{ width = bottom_spacer })
    end
    table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    table.insert(vg, nav_hg)
    table.insert(self.layout, { left_arrow, right_arrow })

    table.insert(self.item_group, _wrapInBackground(content_w, content_h, vg))
end

-- ---------------------------------------------------------------------------
-- Home view builder
-- ---------------------------------------------------------------------------

local function _buildHomeViewUI(self)
    local content_w = self.inner_dimen.w
    local content_h = self.available_height
    local books     = self._books
    local folders   = self._folders or {}
    local vg        = VerticalGroup:new{ align = "left" }

    -- Currently Reading section.
    table.insert(vg, _sectionHeader(_("Currently Reading"), content_w))

    if books == nil then
        table.insert(vg, _placeholderRow(_("Loading…"), content_w))
    elseif #books == 0 then
        table.insert(vg, _placeholderRow(_("No books currently reading."), content_w))
    else
        local caption_h   = Screen:scaleBySize(44)
        local bar_total_h = Screen:scaleBySize(13)  -- gap(4) + bar(5) + gap(4)
        local strip_pad_h = Screen:scaleBySize(16)
        local cell_pad    = Screen:scaleBySize(16)
        local arrow_size  = Screen:scaleBySize(48)
        local strip_inner_w = content_w - 2 * (strip_pad_h + arrow_size + cell_pad)
        local strip_max_h   = math.floor(content_h * 0.72) - caption_h - bar_total_h - Screen:scaleBySize(12)

        local sizing = _computeThumbSize{
            available_w  = strip_inner_w,
            max_h        = strip_max_h,
            cell_pad     = 16,
            min_per_row  = 3,
            cap_thumb_w  = 220,
            min_thumb_w  = 110,
        }
        local thumb_w  = sizing.thumb_w
        local thumb_h  = sizing.thumb_h
        local per_page = sizing.cols

        local n = #books
        local page, total_pages, first_idx, last_idx = _paginateIndex(n, per_page, self._strip_page)
        self._strip_page = page
        local visible_n = last_idx - first_idx + 1

        -- Left-align partial last pages; centre full pages.
        local thumbs_used_w = visible_n * thumb_w + (visible_n - 1) * cell_pad
        local lead_pad = 0
        if visible_n >= per_page then
            lead_pad = math.max(0, math.floor((strip_inner_w - thumbs_used_w) / 2))
        end

        -- Build thumbnail row.
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
                bar_total_h = bar_total_h,
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

        -- Strip arrows.
        local left_arrow = _buildArrow("chevron.left", arrow_size, Screen:scaleBySize(4),
            page > 1,
            function() self._strip_page = page - 1; self:updateItems() end,
            self.show_parent)
        local right_arrow = _buildArrow("chevron.right", arrow_size, Screen:scaleBySize(4),
            page < total_pages,
            function() self._strip_page = page + 1; self:updateItems() end,
            self.show_parent)

        local strip_hg = HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = strip_pad_h },
            CenterContainer:new{
                dimen = Geom:new{ w = arrow_size, h = thumb_h },
                left_arrow,
            },
            HorizontalSpan:new{ width = cell_pad },
            LeftContainer:new{
                dimen = Geom:new{ w = strip_inner_w, h = thumb_h + bar_total_h + caption_h },
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

    -- Folders section.
    table.insert(vg, _sectionHeader(_("Folders"), content_w))
    local row_h = Screen:scaleBySize(56)
    for _, folder_entry in ipairs(folders) do
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

    table.insert(self.item_group, _wrapInBackground(content_w, content_h, vg))
end

-- ---------------------------------------------------------------------------
-- Menu method overrides
-- ---------------------------------------------------------------------------

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

local function _updateItemsBuildUI(self)
    if self._view == "folder" then
        return _buildFolderViewUI(self)
    end
    return _buildHomeViewUI(self)
end

-- Drops the page_info BottomContainer from the menu's outer OverlapGroup.
local function _stripPaginationFooter(menu)
    local frame = menu[1]
    if not frame then return end
    local overlap = frame[1]
    if not overlap then return end
    for i = #overlap, 1, -1 do
        local child = overlap[i]
        if child == menu.page_info or (child and child[1] == menu.page_info) then
            table.remove(overlap, i)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Title bar builder
-- ---------------------------------------------------------------------------

local function _createTitleBar(doSearch, doSync)
    local tb_btn_pad  = Screen:scaleBySize(5)
    local tb_side_pad = Screen:scaleBySize(18)
    local title_bar = TitleBar:new{
        width                   = Screen:getWidth(),
        fullscreen              = "true",
        align                   = "center",
        title                   = _("BookFusion"),
        title_top_padding       = Screen:scaleBySize(6),
        button_padding          = tb_btn_pad,
        left_icon               = "appbar.search",
        left_icon_size_ratio    = 1,
        left_icon_tap_callback  = doSearch,
        right_icon              = "cre.render.reload",
        right_icon_size_ratio   = 1,
        right_icon_tap_callback = doSync,
    }
    -- Strip oversized hitbox and reposition buttons to match library tab.
    local icon_w = Screen:scaleBySize(40)
    if title_bar.left_button then
        title_bar.left_button.padding_right  = 0
        title_bar.left_button.padding_bottom = 0
        title_bar.left_button.overlap_align  = nil
        title_bar.left_button.overlap_offset = { tb_side_pad, 0 }
        title_bar.left_button:update()
    end
    if title_bar.right_button then
        title_bar.right_button.padding_left   = 0
        title_bar.right_button.padding_bottom = 0
        title_bar.right_button.overlap_align  = nil
        title_bar.right_button.overlap_offset = { Screen:getWidth() - icon_w - tb_side_pad, 0 }
        title_bar.right_button:update()
    end
    return title_bar
end

-- ---------------------------------------------------------------------------
-- onMenuSelect handler builder
-- ---------------------------------------------------------------------------

local function _makeOnMenuSelect(bf, settings, api, menu_ref, openFolderInline)
    return function(_self_menu, item)
        if not item then return end
        local ok, err = pcall(function()
            if item.book then
                local Downloader   = bf.downloader
                local download_dir = Downloader.getDownloadDir(settings)
                local filepath     = download_dir .. "/" .. Downloader.buildFilename(item.book)
                if Downloader.fileExists(filepath) then
                    local ButtonDialog = require("ui/widget/buttondialog")
                    local ConfirmBox   = require("ui/widget/confirmbox")
                    local T            = require("ffi/util").template
                    local bdialog
                    bdialog = ButtonDialog:new{
                        title   = item.book.title or _("Untitled"),
                        buttons = {
                            {{ text = _("Read"), callback = function()
                                UIManager:close(bdialog)
                                local ReaderUI = require("apps/reader/readerui")
                                ReaderUI:showReader(filepath)
                            end }},
                            {{ text = _("Remove from device"), callback = function()
                                UIManager:close(bdialog)
                                UIManager:show(ConfirmBox:new{
                                    text = T(_("Remove \"%1\" from this device?"),
                                           item.book.title or _("Untitled")),
                                    ok_text = _("Remove"),
                                    ok_callback = function()
                                        os.remove(filepath)
                                        item.mandatory = nil
                                        local menu = menu_ref()
                                        if menu then menu:updateItems() end
                                    end,
                                })
                            end }},
                        },
                    }
                    UIManager:show(bdialog)
                else
                    local function _onDownloaded()
                        item.mandatory = _("Downloaded")
                        local menu = menu_ref()
                        if menu then menu:updateItems() end
                    end
                    Downloader.confirmDownload(api, settings, item.book, _onDownloaded)
                end
            elseif item.folder then
                openFolderInline(item.folder)
            elseif item.browse then
                local nbrowser = bf.browser:new(api, settings)
                nbrowser:show()
                if nbrowser._menu then
                    nbrowser._menu._navbar_closing_intentionally = true
                end
            end
        end)
        if not ok then
            logger.warn("simpleui bookfusion: onMenuSelect error:", tostring(err))
            _showInfo("Error:\n" .. tostring(err))
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

    -- Guard against double-show.
    if M._instance then
        local dominated = false
        local found     = false
        pcall(function()
            for _, entry in ipairs(UI.getWindowStack()) do
                if entry.widget == M._instance then
                    found = true
                elseif found and entry.widget and entry.widget.covers_fullscreen then
                    dominated = true
                end
            end
        end)
        if found and not dominated then return end
        if found then
            pcall(function() UIManager:close(M._instance) end)
        end
        M._instance = nil
    end

    local Menu = require("ui/widget/menu")
    local PageMenu = Menu:extend{}

    local menu
    local syncing = false

    -- Returns the current menu (for closures that outlive menu reassignment).
    local function menuRef() return menu end

    -- Opens a bookshelf inline as a cover grid.
    local function openFolderInline(folder)
        if not folder then return end
        menu._view              = "folder"
        menu._folder_title      = folder.title
        menu._folder_filters    = folder.filters
        menu._folder_cache_key  = folder.cache_key
        menu._folder_query      = folder.query

        -- Remember the user's last grid page for this folder/query so
        -- re-opening resumes where they left off (within the session).
        local key = folder.cache_key
            or (folder.query and folder.query ~= "" and ("search:" .. folder.query))
            or nil
        menu._folder_current_key = key
        menu._folder_grid_page_by_key = menu._folder_grid_page_by_key or {}
        menu._folder_grid_page = (key and menu._folder_grid_page_by_key[key]) or 1

        if folder.cache_key then
            local cached = _loadCachedList(folder.cache_key)
            if cached then
                menu._folder_raw_books = cached
                menu._folder_books     = _buildBookEntries(bf, settings, cached, false)
                menu._folder_api_page  = 1
                menu._folder_total     = #cached
                menu:updateItems()
                return
            end
        end

        menu._folder_books     = nil
        menu._folder_raw_books = {}
        menu._folder_api_page  = 0
        menu._folder_total     = nil
        menu._folder_fetching  = nil
        menu:updateItems()
        -- Load one API page; _fetchOne renders per batch and the watermark
        -- prefetch in _buildFolderViewUI keeps the buffer warm.
        menu._fetchFolderPage({ count = 1 })
    end

    -- Fetches a single book list from the API and caches it.
    local function syncList(list_filter, cache_key)
        local params = { page = 1, per_page = 50 }
        if list_filter then
            params.list = list_filter
            params.sort = "last_read_at-desc"
        end
        local ok, data = api:searchBooks(params)
        if not ok then return nil end
        data = data or {}
        _saveCachedList(cache_key, data)
        return data
    end

    local function doSync()
        if syncing then return end
        syncing = true
        local InfoMessage = require("ui/widget/infomessage")
        local NetworkMgr  = require("ui/network/manager")
        local notice = InfoMessage:new{ text = _("Syncing…") }
        UIManager:show(notice)
        UIManager:scheduleIn(0.05, function()
            NetworkMgr:runWhenOnline(function()
                local cr_data = syncList("currently_reading", "books")
                if cr_data == nil then
                    UIManager:close(notice)
                    syncing = false
                    _showInfo(_("Sync failed."))
                    return
                end

                if M._instance == menu then
                    menu._books      = _buildBookEntries(bf, settings, cr_data, true)
                    menu._strip_page = 1
                    menu:updateItems()
                end

                syncList("planned_to_read", "planned_to_read")
                syncList("favorites", "favorites")

                if M._instance == menu and menu._view == "folder" and menu._folder_cache_key then
                    local fresh = _loadCachedList(menu._folder_cache_key)
                    if fresh then
                        menu._folder_raw_books = fresh
                        menu._folder_books     = _buildBookEntries(bf, settings, fresh, false)
                        menu._folder_total     = #fresh
                        menu:updateItems()
                    end
                end

                -- Fetch cloud reading progress for currently-reading books.
                for _, book in ipairs(cr_data) do
                    if book.id then
                        local p_ok, pos = api:getReadingPosition(book.id)
                        if p_ok and pos and pos.percentage then
                            book.cloud_percent = pos.percentage / 100
                        end
                    end
                end
                _saveCachedList("books", cr_data)

                UIManager:close(notice)
                syncing = false

                if M._instance == menu then
                    menu._books = _buildBookEntries(bf, settings, cr_data, true)
                    menu:updateItems()
                end
            end)
        end)
    end

    local function doSearch()
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new{
            title = _("Search books"),
            input = "",
            buttons = {
                {
                    {
                        text     = _("Cancel"),
                        id       = "close",
                        callback = function() UIManager:close(dialog) end,
                    },
                    {
                        text             = _("Search"),
                        is_enter_default = true,
                        callback = function()
                            local query = dialog:getInputText()
                            UIManager:close(dialog)
                            if query and query ~= "" then
                                openFolderInline({
                                    title   = _("Search: ") .. query,
                                    filters = {},
                                    query   = query,
                                })
                            end
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    -- Fetches the next API page of books for the current folder view.
    --
    -- opts.silent   = true: background prefetch — no error messages, no UI
    --                 update, just appends data for the next page turn.
    -- opts.on_done  = optional callback after a successful fetch.
    -- opts.count    = fetch N API pages in a row (default 1). Used for the
    --                 initial load (count=2) so pages 1+2 are ready.
    --
    -- Read-ahead strategy:
    --   openFolderInline → fetchFolderPage({ count = 2 })  (loads pages 1+2)
    --   on_next          → advance grid page, then
    --                      fetchFolderPage({ silent = true })  (prefetch next)
    --   The grid never blocks unless the user outruns the prefetcher.
    local function fetchFolderPage(opts)
        opts = opts or {}

        -- Guard: nothing to do if we already have everything.
        if menu._folder_total then
            local n = menu._folder_raw_books and #menu._folder_raw_books or 0
            if n >= menu._folder_total then return end
        end

        -- Prevent concurrent fetches.
        if menu._folder_fetching then return end
        menu._folder_fetching = true

        local remaining = opts.count or 1

        local NetworkMgr = require("ui/network/manager")
        NetworkMgr:runWhenOnline(function()
            UIManager:scheduleIn(0.05, function()
                -- Bail if the folder view was closed while we waited.
                if not menu or menu._view ~= "folder" then
                    menu._folder_fetching = nil
                    return
                end

                local function _fetchOne(on_batch_done)
                    local grid_pp = menu._folder_grid_per_page or 8
                    local params = {
                        page     = (menu._folder_api_page or 0) + 1,
                        per_page = grid_pp * 2,
                    }
                    for k, v in pairs(menu._folder_filters or {}) do
                        params[k] = v
                    end
                    local has_query = menu._folder_query and menu._folder_query ~= ""
                    if has_query then
                        params.query = menu._folder_query
                    end
                    -- For text queries let the server rank by relevance;
                    -- only force the list ordering when browsing a folder.
                    if not params.sort and not has_query then
                        params.sort = "added_at-desc"
                    end

                    local ok, data, pagination = api:searchBooks(params)
                    if not ok then
                        if not opts.silent then
                            _showInfo(_("Failed to load books."))
                            if menu._folder_books == nil then
                                menu._folder_books = {}
                            end
                        end
                        on_batch_done(true)  -- stop looping
                        return
                    end

                    if pagination then
                        menu._folder_api_page = pagination.page or ((menu._folder_api_page or 0) + 1)
                        menu._folder_total    = pagination.total
                    else
                        menu._folder_api_page = (menu._folder_api_page or 0) + 1
                    end

                    -- Incremental build: only build entries for the new
                    -- batch and append them, instead of rebuilding the
                    -- full list each fetch (was O(n) per batch).
                    local new_entries = _buildBookEntries(bf, settings, data or {}, false)
                    for _i, book in ipairs(data or {}) do
                        table.insert(menu._folder_raw_books, book)
                    end
                    menu._folder_books = menu._folder_books or {}
                    for _i, entry in ipairs(new_entries or {}) do
                        table.insert(menu._folder_books, entry)
                    end

                    -- Are there more API pages to fetch?
                    local all_loaded = menu._folder_total
                        and #menu._folder_raw_books >= menu._folder_total
                    on_batch_done(all_loaded)
                end

                -- Fetch `remaining` API pages sequentially.
                local function _loop()
                    _fetchOne(function(done)
                        remaining = remaining - 1
                        if done or remaining <= 0 or menu._view ~= "folder" then
                            menu._folder_fetching = nil
                            -- Refresh UI after all batches complete.
                            if M._instance == menu and menu._view == "folder" then
                                menu:updateItems()
                            end
                            if opts.on_done then opts.on_done() end
                        else
                            _loop()
                        end
                    end)
                end
                _loop()
            end)
        end)
    end

    local title_bar = _createTitleBar(doSearch, doSync)

    menu = PageMenu:new{
        name              = "bookfusion",
        title             = _("BookFusion"),
        item_table        = { { text = "" } },  -- placeholder for Menu:init
        height            = UI.getContentHeight(),
        y                 = UI.getContentTop(),
        _navbar_height_reduced = true,
        is_borderless     = true,
        is_popout         = false,
        covers_fullscreen = true,
        custom_title_bar  = title_bar,
        onMenuSelect      = _makeOnMenuSelect(bf, settings, api, menuRef, openFolderInline),
        close_callback = function()
            if menu then UIManager:close(menu) end
        end,
    }

    -- Initial state from disk cache.
    local cached_books = _loadCachedList("books")
    menu._books      = cached_books and _buildBookEntries(bf, settings, cached_books, true) or nil
    menu._folders    = _buildFolderEntries()
    menu._strip_page = 1

    -- Wire up custom layout using bf_covermenu's updateItems for lazy cover loading.
    local _base_updateItems = bf.covermenu.updateItems
    menu.updateItems = function(self_menu, ...)
        -- Only refresh the list that's actually on screen — the non-visible
        -- list hasn't changed and re-stat'ing its files on every page turn
        -- is wasted work. Within the folder view, further restrict to the
        -- visible grid slice so the file-stat loop doesn't walk hundreds
        -- of off-screen entries on every turn.
        if self_menu._view == "folder" then
            local entries = self_menu._folder_books
            if entries and #entries > 0 then
                local pp = self_menu._folder_grid_per_page or #entries
                local p  = self_menu._folder_grid_page or 1
                local first = (p - 1) * pp + 1
                local last  = first + pp - 1
                pcall(_refreshDownloadStatus, entries, bf, settings, false, first, last)
            end
        else
            pcall(_refreshDownloadStatus, self_menu._books, bf, settings, true)
        end
        _base_updateItems(self_menu, ...)
        UIManager:setDirty(self_menu.show_parent, function()
            return "ui", Geom:new{
                x = 0,
                y = UI.getContentTop(),
                w = Screen:getWidth(),
                h = UI.getContentHeight(),
            }
        end)
        -- Page has painted — drain the async cover hydration queue. Visible
        -- thumbs that had cached bytes on disk will pop in progressively.
        if self_menu._view == "folder" then
            _kickAsyncHydration(self_menu)
        end
    end
    menu.onCloseWidget = function(self_w)
        M._instance = nil
        if bf.covermenu and bf.covermenu.onCloseWidget then
            return bf.covermenu.onCloseWidget(self_w)
        end
    end
    menu._recalculateDimen   = _recalculateDimen
    menu._updateItemsBuildUI = _updateItemsBuildUI
    menu._do_cover_images    = true
    menu._fetchFolderPage    = fetchFolderPage
    menu._loadMoreFolderBooks = function()
        local old_n = menu._folder_books and #menu._folder_books or 0
        fetchFolderPage({ advance_from = old_n })
    end

    _stripPaginationFooter(menu)
    menu.updatePageInfo = function() end
    menu._titlebar_inj_patched = true

    menu:updateItems()
    M._instance = menu
    UIManager:show(menu)

    if cached_books == nil then
        UIManager:scheduleIn(0.2, doSync)
    end
end

return M
