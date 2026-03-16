-- module_quick_actions.lua — Simple UI
-- Módulo: Quick Actions (3 slots independentes).
-- Substitui quickactionswidget.lua — contém todo o código de widget.
-- Expõe sub_modules = { slot1, slot2, slot3 } para o registry.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _               = require("gettext")
local Config          = require("config")

local UI  = require("ui")
local PAD = UI.PAD

local _CLR_BAR_FG = Blitbuffer.gray(0.75)

local ICON_SZ    = Screen:scaleBySize(52)
local FRAME_PAD  = Screen:scaleBySize(18)
local FRAME_SZ   = ICON_SZ + FRAME_PAD * 2
local CORNER_R   = Screen:scaleBySize(22)
local LBL_SP     = Screen:scaleBySize(7)
local LBL_H      = Screen:scaleBySize(20)
local QA_TOP_PAD           = Screen:scaleBySize(28)
local QA_TOP_PAD_NO_LABELS = Screen:scaleBySize(36)

-- ---------------------------------------------------------------------------
-- Custom QA id validity cache — module-level so it is built at most once per
-- render cycle (previously rebuilt inside buildQAWidget per slot per call).
-- Invalidated by invalidateCustomQACache() which is called whenever the
-- master list changes (deletion, creation, sanitize).
-- ---------------------------------------------------------------------------
local _custom_qa_valid       = nil   -- set<id> or nil (nil = stale)

local function _buildCustomQAValid()
    local list = G_reader_settings:readSetting("navbar_custom_qa_list") or {}
    local s = {}
    for _, id in ipairs(list) do s[id] = true end
    _custom_qa_valid = s
end

local function getCustomQAValid()
    if not _custom_qa_valid then _buildCustomQAValid() end
    return _custom_qa_valid
end

local function invalidateCustomQACache()
    _custom_qa_valid = nil
end

-- ---------------------------------------------------------------------------
-- Action entry resolution
-- ---------------------------------------------------------------------------
local _STATIC_ACTION_MAP = {
    home           = { icon = Config.ICON.library,     label = _("Library")     },
    collections    = { icon = Config.ICON.collections, label = _("Collections") },
    history        = { icon = Config.ICON.history,     label = _("History")     },
    continue       = { icon = Config.ICON.continue_,   label = _("Continue")    },
    favorites      = { icon = Config.ICON.ko_star,     label = _("Favorites")   },
    frontlight     = { icon = Config.ICON.frontlight,  label = _("Brightness")  },
    stats_calendar = { icon = Config.ICON.stats,       label = _("Stats")       },
}

local function getEntry(action_id)
    if _STATIC_ACTION_MAP[action_id] then return _STATIC_ACTION_MAP[action_id] end
    if action_id == "wifi_toggle" then
        return { icon = Config.wifiIcon(), label = _("Wi-Fi") }
    end
    if tostring(action_id):match("^custom_qa_%d+$") then
        local cfg = G_reader_settings:readSetting("navbar_cqa_" .. action_id) or {}
        return {
            icon  = cfg.icon or Config.ICON.custom,
            label = cfg.label or action_id,
        }
    end
    return { icon = Config.ICON.ko_home, label = action_id }
end

-- ---------------------------------------------------------------------------
-- Core widget builder (shared by all slots)
-- ---------------------------------------------------------------------------
local function buildQAWidget(w, action_ids, show_labels, on_tap_fn)
    if not action_ids or #action_ids == 0 then return nil end

    -- Filter invalid custom QA ids using the module-level validity cache.
    -- Previously each call rebuilt the set from settings — now it is shared
    -- across all slots for the lifetime of a single render cycle.
    local valid_ids = {}
    local cqa_valid = getCustomQAValid()
    for _, aid in ipairs(action_ids) do
        if aid:match("^custom_qa_%d+$") then
            if cqa_valid[aid] then valid_ids[#valid_ids + 1] = aid end
        else
            valid_ids[#valid_ids + 1] = aid
        end
    end
    if #valid_ids == 0 then return nil end

    local n        = math.min(#valid_ids, 4)
    local inner_w  = w - PAD * 2
    local lbl_h    = show_labels and LBL_H or 0
    local lbl_sp   = show_labels and LBL_SP or 0
    local gap      = n <= 1 and 0 or math.floor((inner_w - n * FRAME_SZ) / (n - 1))
    local left_off = n == 1 and math.floor((inner_w - FRAME_SZ) / 2) or 0

    local row = HorizontalGroup:new{ align = "top" }

    for i = 1, n do
        local aid   = valid_ids[i]
        local entry = getEntry(aid)

        local icon_frame = FrameContainer:new{
            bordersize = Screen:scaleBySize(1),
            color      = _CLR_BAR_FG,
            background = Blitbuffer.COLOR_WHITE,
            radius     = CORNER_R,
            padding    = FRAME_PAD,
            ImageWidget:new{
                file    = entry.icon,
                width   = ICON_SZ,
                height  = ICON_SZ,
                is_icon = true,
                alpha   = true,
            },
        }

        local col = VerticalGroup:new{ align = "center" }
        col[#col + 1] = icon_frame
        if show_labels then
            col[#col + 1] = VerticalSpan:new{ width = lbl_sp }
            col[#col + 1] = CenterContainer:new{
                dimen = Geom:new{ w = FRAME_SZ, h = lbl_h },
                TextWidget:new{
                    text    = entry.label,
                    face    = Font:getFace("cfont", Screen:scaleBySize(9)),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    width   = FRAME_SZ,
                },
            }
        end

        local col_h    = FRAME_SZ + lbl_sp + lbl_h
        local tappable = InputContainer:new{
            dimen      = Geom:new{ w = FRAME_SZ, h = col_h },
            [1]        = col,
            _on_tap_fn = on_tap_fn,
            _action_id = aid,
        }
        tappable.ges_events = {
            TapQA = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapQA()
            if self._on_tap_fn then self._on_tap_fn(self._action_id) end
            return true
        end

        if i > 1 then
            row[#row + 1] = HorizontalSpan:new{ width = gap }
        end
        row[#row + 1] = tappable
    end

    return FrameContainer:new{
        bordersize = 0, padding = 0,
        padding_left = PAD + left_off,
        row,
    }
end

-- ---------------------------------------------------------------------------
-- Slot factory — creates one module descriptor per slot
-- ---------------------------------------------------------------------------
local function makeSlot(slot)
    -- Keys built at call-time using ctx.pfx — works for any page prefix.
    local slot_suffix = "quick_actions_" .. slot

    local S = {}
    S.id         = "quick_actions_" .. slot
    S.name       = string.format(_("Quick Actions %d"), slot)
    S.label      = nil
    S.default_on = false

    function S.isEnabled(pfx)
        return G_reader_settings:readSetting(pfx .. slot_suffix .. "_enabled") == true
    end

    function S.setEnabled(pfx, on)
        G_reader_settings:saveSetting(pfx .. slot_suffix .. "_enabled", on)
    end

    local MAX_QA = 4
    function S.getCountLabel(pfx)
        local n   = #(G_reader_settings:readSetting(pfx .. slot_suffix .. "_items") or {})
        local rem = MAX_QA - n
        if n == 0   then return nil end
        if rem <= 0 then return string.format("(%d/%d — at limit)", n, MAX_QA) end
        return string.format("(%d/%d — %d left)", n, MAX_QA, rem)
    end

    function S.build(w, ctx)
        if not S.isEnabled(ctx.pfx) then return nil end
        local items_key   = ctx.pfx .. slot_suffix .. "_items"
        local labels_key  = ctx.pfx .. slot_suffix .. "_labels"
        local qa_ids      = G_reader_settings:readSetting(items_key) or {}
        local show_labels = G_reader_settings:nilOrTrue(labels_key)
        return buildQAWidget(w, qa_ids, show_labels, ctx.on_qa_tap)
    end

    function S.getHeight(ctx)
        local labels_key  = ctx.pfx .. slot_suffix .. "_labels"
        local show_labels = G_reader_settings:nilOrTrue(labels_key)
        local col_h  = show_labels and (FRAME_SZ + LBL_SP + LBL_H) or FRAME_SZ
        local qa_top = show_labels and QA_TOP_PAD or QA_TOP_PAD_NO_LABELS
        return qa_top + col_h
    end

    function S.getMenuItems(ctx_menu)
        if type(ctx_menu.makeQAMenu) == "function" then
            return ctx_menu.makeQAMenu(ctx_menu, slot)
        end
        return {}
    end

    return S
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------
local M = {}
M.sub_modules = { makeSlot(1), makeSlot(2), makeSlot(3) }

-- Also expose layout constants for menu.lua (MAX_QA_ITEMS referenced there)
M.FRAME_SZ             = FRAME_SZ
M.QA_TOP_PAD           = QA_TOP_PAD
M.QA_TOP_PAD_NO_LABELS = QA_TOP_PAD_NO_LABELS
-- Invalidates the module-level custom-QA validity cache.
-- Call after any change to "navbar_custom_qa_list" (delete, create, sanitize).
M.invalidateCustomQACache = invalidateCustomQACache

return M