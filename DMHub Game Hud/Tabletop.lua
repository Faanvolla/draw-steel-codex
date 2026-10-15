local mod = dmhub.GetModLoading()

--Tabletop view (experimental). The screen shows a table, and maps live in
--windows on it that can be moved, resized, maximized and closed, instead of
--one map filling the screen. The engine still has a single current map, so
--only one window is live: the focused one, when its map is the current map.
--Every other window shows a frozen, greyed snapshot of what it last showed;
--clicking it travels to its map, which freezes the window that was live.
--
--Engine side: dmhub.tabletopMode, the "#MapView" and "#MapSnapshot:<mapid>"
--bgimages, and MapViewport.cs. Design, decisions and the to-do list are in
--TABLETOP_MAP_WINDOWS.md at the dmhub repo root.
--
--Turn it on with the "Tabletop View (experimental)" setting, or
--/toggle tabletop:enabled.

if rawget(_G, "Tabletop") == nil then
    Tabletop = {}
end

setting{
    id = "tabletop:enabled",
    description = "Tabletop View (experimental)",
    help = "Show maps in movable windows on a table instead of one map filling the screen.",
    storage = "preference",
    default = false,
    editor = "check",
}

--This user's window layout for this game, as JSON (see SaveLayout).
local g_layoutSetting = setting{
    id = "tabletop:layout",
    storage = "pergamepreference",
    default = "",
}

--The table's surface: one of the built-in surfaces, or "custom" for an
--image (g_surfaceImageSetting). Personal, like the rest of the table. The
--engine draws it (dmhub.tabletopSurface / dmhub.tabletopSurfaceImage).
local g_surfaceSetting = setting{
    id = "tabletop:surface",
    storage = "preference",
    default = "leather",
}

local g_surfaceImageSetting = setting{
    id = "tabletop:surfaceimage",
    storage = "preference",
    default = "",
}

local TABLE_SURFACES = {
    {id = "leather", text = "Leather Playmat"},
    {id = "wood", text = "Wood"},
    {id = "felt", text = "Felt"},
    {id = "slate", text = "Slate"},
}

--Surfaces still being developed: offered in the table menu only with the
--dev setting on, so they can be switched to and compared before they ship.
local DEV_TABLE_SURFACES = {
    {id = "stars", text = "Sea of Stars (dev)"},
}

local TITLE_HEIGHT = 30
local MIN_WIDTH = 360
local MIN_HEIGHT = 240

--Window records, in creation order. Each is
--{id, mapid, x, y, width, height, maximized} plus its live panel parts
--(panel, liveBody, frozenBody, ...), which are rebuilt with each GameHud.
local g_windows = {}

--The window the user last chose. It shows the live map once its map is the
--current map.
local g_focusedId = nil

--The window showing the live map right now. It changes only when the
--current map changes (or a window showing the current map is focused), so
--the old window stays live until the engine has frozen it on leaving.
local g_liveId = nil

--Set when a map is opened into a window before travelling there:
--{mapid, windowId} -- that window takes the map when we arrive.
local g_pendingAdopt = nil

--The current map last seen, to notice the engine changing it.
local g_lastMapId = nil

--The game the records belong to.
local g_gameid = nil

local g_layer = nil
--Over the whole hud: a maximized scene on show over the UI (Tabletop.CreateTopLayer).
local g_topLayer = nil
local g_restoreButton = nil

--The overlay the map HUD was last placed in (Refresh).
local g_lastHudHost = nil

function Tabletop.IsActive()
    return dmhub.GetSettingValue("tabletop:enabled") == true and dmhub.inGame and not dmhub.isLobbyGame
end

--The id of the window showing the live map, or nil.
function Tabletop.LiveWindowId()
    return g_liveId
end

local function WindowById(id)
    if id == nil then
        return nil
    end
    for _,rec in ipairs(g_windows) do
        if rec.id == id then
            return rec
        end
    end
    return nil
end

local function WindowForMap(mapid)
    for _,rec in ipairs(g_windows) do
        if rec.mapid == mapid then
            return rec
        end
    end
    return nil
end

local function MapName(mapid)
    local map = game.GetMap(mapid)
    if map == nil or not map.valid then
        return "(missing map)"
    end
    local name = map.description
    if type(name) ~= "string" or name == "" then
        return "(unnamed map)"
    end
    return name
end

local function DocumentsLayer()
    local hud = GameHud.instance
    if not hud then
        return nil
    end
    local layer = hud.documentsPanel
    if layer == nil or not layer.valid then
        return nil
    end
    return layer
end

----------------------------------------------------------------------
--Saving the layout (per user, per game, on this machine).

local g_saveScheduled = false

--Table state other parts of this file add to the saved layout: shares
--already seen (players), and NPC cards. Each is a function(out) that writes
--its own fields, and the matching loader reads them back.
local g_layoutWriters = {}

local function SaveLayout()
    local out = {windows = {}, focused = g_focusedId}
    for _,rec in ipairs(g_windows) do
        out.windows[#out.windows+1] = {
            id = rec.id,
            mapid = rec.mapid,
            x = rec.x,
            y = rec.y,
            width = rec.width,
            height = rec.height,
            maximized = rec.maximized == true,
            minimized = rec.minimized == true,
            iconX = rec.iconX,
            iconY = rec.iconY,
        }
    end
    for _, writer in ipairs(g_layoutWriters) do
        writer(out)
    end
    g_layoutSetting:Set(dmhub.ToJson(out))
end

local function SaveSoon()
    if g_saveScheduled then
        return
    end
    g_saveScheduled = true
    dmhub.Schedule(0.5, function()
        g_saveScheduled = false
        if mod.unloaded then
            return
        end
        SaveLayout()
    end)
end

local function LoadLayout()
    local text = g_layoutSetting:Get()
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local parsed = dmhub.FromJson(text)
    if parsed == nil or parsed.result == nil or type(parsed.result) ~= "table" then
        return nil
    end
    return parsed.result
end

----------------------------------------------------------------------
--Window placement, in the documents layer's units (its height is fixed;
--its width follows the screen's aspect).

local function LayerSize()
    local layer = DocumentsLayer()
    if layer == nil then
        return 1862, 1048
    end
    return layer.renderedWidth, layer.renderedHeight
end

--Centred, stepping down-right past any window already sitting at a spot so
--a new window never lands exactly on top of another.
local function DefaultPlacement()
    local w, h = LayerSize()
    local width = math.floor(w * 0.62)
    local height = math.floor(h * 0.68)
    local x0 = math.floor((w - width) / 2)
    local y0 = math.floor((h - height) / 2)
    for step = 0, 11 do
        local x = x0 + 28 * (step % 6)
        local y = y0 + 28 * (step % 6)
        local taken = false
        for _,rec in ipairs(g_windows) do
            if math.abs(rec.x - x) < 8 and math.abs(rec.y - y) < 8 then
                taken = true
                break
            end
        end
        if not taken then
            return x, y, width, height
        end
    end
    return x0, y0, width, height
end

--How much of a window must stay on the table: enough titlebar to grab.
local KEEP_ON_TABLE = 120

--Keeps a window's titlebar on the table: it may hang off the left, right
--and bottom edges, but never so far that it cannot be dragged back.
local function ClampWindow(rec, x, y)
    local w, h = LayerSize()
    x = math.max(KEEP_ON_TABLE - rec.width, math.min(x, w - KEEP_ON_TABLE))
    y = math.max(0, math.min(y, h - TITLE_HEIGHT))
    return x, y
end

--Distance within which a dropped window snaps to an edge.
local SNAP = 14

--Where a window dropped at (x, y) lands: snapped flush to the table's
--edges or to another window's edges (side by side, or aligned) when it
--is close, then kept on the table.
local function SnapWindow(rec, x, y)
    local w, h = LayerSize()
    local xs = {0, w - rec.width}
    local ys = {0, h - rec.height}
    for _, other in ipairs(g_windows) do
        if other ~= rec and not other.maximized and not other.minimized then
            xs[#xs+1] = other.x
            xs[#xs+1] = other.x + other.width
            xs[#xs+1] = other.x - rec.width
            xs[#xs+1] = other.x + other.width - rec.width
            ys[#ys+1] = other.y
            ys[#ys+1] = other.y + other.height
            ys[#ys+1] = other.y - rec.height
            ys[#ys+1] = other.y + other.height - rec.height
        end
    end
    local function nearest(value, candidates)
        local best, bestDist = value, SNAP + 1
        for _, c in ipairs(candidates) do
            local d = math.abs(c - value)
            if d < bestDist then
                best, bestDist = c, d
            end
        end
        return best
    end
    return ClampWindow(rec, nearest(x, xs), nearest(y, ys))
end

local function NewWindowRecord(mapid)
    local x, y, width, height = DefaultPlacement()
    return {
        id = dmhub.GenerateGuid(),
        mapid = mapid,
        x = x,
        y = y,
        width = width,
        height = height,
        maximized = false,
    }
end

----------------------------------------------------------------------
--Building windows.

local Refresh
local Focus
local CloseWindow
local ToggleMaximize
local Minimize
local RestoreWindow
local RequestClose
local ShareControl
local UpdateShare
--Share stores and the player's viewable-map tracking (one table: this file
--is at Lua's 200-local limit). See the Sharing section.
local g_sharing = {}
local IsShared
local IsForcedHere
local ShowPreviewTooltip
local IsOpen
local Travel
local SyncShares
local SyncCards
local TeardownCards
local SyncDocItems
local TeardownDocItems
local LoadDocItems
local SyncSurface
local SyncSceneWindows
local TeardownSceneWindows
local LoadSceneWindows
local AnySceneMaximized
local UnmaximizeScenes
local UpdateSceneTitleControls

--The rail layout key of a window docked to the icon rail (RailEntryTypes).
local function RailKey(rec)
    return "mapwindow:" .. rec.id
end

--Docked on a rail that is actually showing (with the rail off, a docked
--window's button goes back on the table).
local function IsDocked(rec)
    return RailModeActive() and IconRailKeySlot(RailKey(rec)) ~= nil
end

--A caption control in the native style of the app's title bar: a
--full-height hover zone with a centred window-chrome glyph (see
--CodexTitleBar's CreateWindowControl). args: icon, click, rightClick, hover,
--danger, width, iconSize, flip (draw the glyph upside down), iconChildren
--(panels drawn over the glyph).
--When a caption control or one of this file's menu entries last acted. The
--same click can also reach a window under it -- a context menu's items take
--no clicks themselves, so the press and release land on whatever is below --
--and a window's click focuses (and travels to) its map, a control's click
--minimizes or closes. Windows and controls ignore clicks for a moment after.
local g_controlClickTime = -1

local function GuardClicks()
    g_controlClickTime = dmhub.Time()
end

local function ClicksGuarded()
    return dmhub.Time() - g_controlClickTime < 0.6
end

--A context-menu entry that guards the windows under the menu (see above).
local function GuardedEntry(text, action)
    return {
        text = text,
        click = function()
            GuardClicks()
            action()
        end,
    }
end

local function WindowControl(args)
    local click = args.click
    local classes = {"tabletopControl"}
    local iconClasses = {"tabletopControlIcon"}
    if args.danger then
        classes[#classes+1] = "tabletopControlDanger"
        iconClasses[#iconClasses+1] = "tabletopControlIconDanger"
    end
    return gui.Panel{
        classes = classes,
        bgimage = true,
        width = args.width or 36,
        height = "100%",
        valign = "center",
        --passPress: the press (and hover) reach the panel around the control,
        --so a card's titlebar stays shown, and drags the card.
        swallowPress = args.passPress ~= true,
        hover = args.hover,
        rightClick = args.rightClick,
        click = function(element)
            if ClicksGuarded() then
                return
            end
            GuardClicks()
            if click ~= nil then
                click(element)
            end
        end,
        gui.Panel{
            classes = iconClasses,
            bgimage = args.icon,
            width = args.iconSize or 14,
            height = args.iconSize or 14,
            halign = "center",
            valign = "center",
            scale = cond(args.flip, {x = 1, y = -1}, {x = 1, y = 1}),
            interactable = false,
            setIcon = function(element, icon)
                element.bgimage = icon
            end,
            children = args.iconChildren,
        },
    }
end

--The floor stepper in the live window's titlebar: the floor being viewed,
--with the floor-down/up keybinds' action on either side (a player looks
--up through the floors above their token instead). Shown only when the
--map has more than one floor.
local function TopLevelFloorCount()
    local map = game.currentMap
    if map == nil then
        return 0
    end
    local count = 0
    for _, f in ipairs(map.floors or {}) do
        if f.parentFloor == nil then
            count = count + 1
        end
    end
    return count
end

local function CurrentFloorName()
    local floor = game.currentFloor
    if floor == nil then
        return ""
    end
    if floor.parentFloor ~= nil then
        local parent = game.GetFloor(floor.parentFloor)
        if parent ~= nil then
            floor = parent
        end
    end
    local name = floor.description
    if type(name) ~= "string" or name == "" then
        return "Floor"
    end
    return name
end

local function BuildFloorControl(rec)
    local label = gui.Label{
        classes = {"tabletopFloorText"},
        width = "auto",
        maxWidth = 140,
        height = "100%",
        valign = "center",
        hmargin = 2,
        textWrap = false,
        textOverflow = "ellipsis",
        text = "",
    }
    return gui.Panel{
        classes = {"collapsed"},
        flow = "horizontal",
        width = "auto",
        height = "100%",
        valign = "center",
        rmargin = 6,
        --fired by the titlebar's controls row (a collapsed panel does not
        --think, so this one cannot poll for itself).
        updateFloor = function(element)
            local show = rec.id == Tabletop.LiveWindowId() and TopLevelFloorCount() > 1
            element:SetClass("collapsed", not show)
            if show then
                local text = CurrentFloorName()
                if label.text ~= text then
                    label.text = text
                end
            end
        end,
        WindowControl{
            icon = "phosphor/caret-down-fill.png",
            width = 22,
            iconSize = 11,
            hover = gui.Tooltip("Floor down"),
            click = function()
                FloorNavigation.ChangeFloorRelative(-1)
            end,
        },
        label,
        WindowControl{
            icon = "phosphor/caret-down-fill.png",
            flip = true,
            width = 22,
            iconSize = 11,
            hover = gui.Tooltip("Floor up"),
            click = function()
                FloorNavigation.ChangeFloorRelative(1)
            end,
        },
    }
end

local function BringToFront(rec)
    if rec.panel ~= nil and rec.panel.valid then
        rec.panel:SetAsLastSibling()
    end
end

--Briefly lights a window's border: the engine moved us to a map that was
--already open in it (a token travelled there, a journal link...).
local function Highlight(rec)
    local panel = rec.panel
    if panel == nil or not panel.valid then
        return
    end
    panel:SetClass("tabletopHighlight", true)
    dmhub.Schedule(1.2, function()
        if panel.valid then
            panel:SetClass("tabletopHighlight", false)
        end
    end)
end

--A panel's styles reach every panel below it, so the window's styles are
--split by where they are needed. The live body hosts the map's HUD (the
--initiative bar), which must lay out exactly as it does over the full-screen
--map, so the theme goes on the titlebar and the frozen body, never on an
--ancestor of the live body.

--The window frame itself. Selector-only, so nothing in the body matches.
local g_windowStyles = {
    {
        selectors = {"tabletopWindow"},
        bgcolor = "#100d0bff",
        borderWidth = 2,
        borderColor = "#00000099",
    },
    {
        selectors = {"tabletopWindow", "focused"},
        borderColor = "#b8925acc",
    },
    {
        selectors = {"tabletopWindow", "tabletopHighlight"},
        borderColor = "#ffd27aff",
        transitionTime = 0.25,
    },
}

local g_titleStyles = {
    {
        selectors = {"tabletopTitle"},
        bgcolor = "#1d1915ff",
    },
    {
        selectors = {"tabletopTitleText"},
        color = "#d9d1c4",
        fontSize = 14,
    },
    --caption controls, in the native style of the app's own title bar
    --(CodexTitleBar's CreateWindowControl and its titleBarStyleExtras).
    {
        selectors = {"tabletopControl"},
        bgcolor = "clear",
    },
    {
        selectors = {"tabletopControl", "hover"},
        bgcolor = "#ffffff1f",
    },
    {
        selectors = {"tabletopControl", "press"},
        bgcolor = "#ffffff33",
    },
    {
        selectors = {"tabletopControlDanger", "hover"},
        bgcolor = "#c42b1c",
    },
    {
        selectors = {"tabletopControlDanger", "press"},
        bgcolor = "#b3271a",
    },
    {
        selectors = {"tabletopControlIcon"},
        bgcolor = "#d4d4d4",
    },
    {
        selectors = {"tabletopControlIconDanger", "parent:hover"},
        bgcolor = "#ffffff",
    },
    {
        selectors = {"tabletopControl", "tabletopControlDisabled"},
        bgcolor = "clear",
    },
    {
        selectors = {"tabletopControlIcon", "parent:tabletopControlDisabled"},
        opacity = 0.35,
    },
    --the Director's share toggle: lit while the item is shared with every
    --player, only its top half lit while shared with some of them.
    {
        selectors = {"tabletopControlIcon", "parent:tabletopShared"},
        bgcolor = "@share",
    },
    {
        selectors = {"tabletopShareHalf"},
        bgcolor = "@share",
    },
    {
        selectors = {"tabletopFloorText"},
        color = "#d9d1c4",
        fontSize = 12,
    },
    --a frozen window's map is in combat.
    {
        selectors = {"tabletopCombatBadge"},
        bgcolor = "#e0503f",
    },
}

local g_frozenStyles = {
    {
        selectors = {"tabletopFrozen"},
        bgcolor = "#8a8a8aff",
        saturation = 0.12,
    },
    {
        selectors = {"tabletopFrozen", "hover"},
        bgcolor = "#b0b0b0ff",
    },
    {
        selectors = {"tabletopFrozen", "tabletopPlaceholder"},
        bgcolor = "#1b1814ff",
    },
    {
        selectors = {"tabletopFrozen", "tabletopPlaceholder", "hover"},
        bgcolor = "#26221cff",
    },
    {
        selectors = {"tabletopFrozenHint"},
        color = "#e8e0d2",
        fontSize = 16,
        opacity = 0,
    },
    {
        selectors = {"tabletopFrozenHint", "parent:hover"},
        opacity = 1,
        transitionTime = 0.15,
    },
}

--Puts the engine's defaults back for everything in the map overlay. The
--documents layer the window lives in has a style with no selector (centred,
--100% x 100%), and a style with no selector applies to every panel below it.
--Over the full-screen map the HUD gets the engine defaults instead (top-left,
--100 x 100), and the closer ancestor's style wins, so this undoes the layer's.
local g_overlayStyles = {
    {
        valign = "top",
        halign = "left",
        width = 100,
        height = 100,
    },
}

local function BuildWindow(rec)
    local panel

    --the Director's shape overlay, cropped the same way as the map.
    local liveChildren = {}
    if dmhub.isDM then
        liveChildren[#liveChildren+1] = gui.Panel{
            floating = true,
            interactable = false,
            width = "100%",
            height = "100%",
            bgimage = "#ShapesView",
            bgcolor = "white",
        }
    end

    --The map's own HUD, drawn over the map inside this window: the initiative
    --bar moves in here while this window is live, and dialogs presented for
    --this map (the "Draw Steel" banner) open here (MapOverlayHost). It has
    --no bgimage, so it takes no mouse itself.
    local overlay = gui.Panel{
        styles = g_overlayStyles,
        floating = true,
        width = "100%",
        height = "100%",
        --a window narrower than the HUD shrinks it to fit.
        thinkTime = 0.25,
        think = function(element)
            if rec.id == g_liveId then
                Tabletop.ScaleMapHuds(element)
            end
        end,
    }
    liveChildren[#liveChildren+1] = overlay

    --The live map: this panel's rectangle of the screen-aligned map image.
    --It does not block the map, so clicks, drags and the wheel inside it
    --reach the map; swallowPress keeps them from also dragging the window.
    --It only carries "#MapView" while this window is live (Refresh): a
    --panel showing it is where the engine puts the map, even for a frame.
    local liveBody = gui.Panel{
        classes = {"collapsed"},
        width = "100%",
        height = "100% available",
        bgimage = "panels/square.png",
        bgcolor = "white",
        blocksGameInteraction = false,
        swallowPress = true,
        children = liveChildren,
    }

    local frozenHint = gui.Label{
        classes = {"tabletopFrozenHint"},
        width = "auto",
        height = "auto",
        halign = "center",
        valign = "center",
        bold = true,
        text = "Click to view",
    }

    --Not the live map: the snapshot of what this window last showed, or
    --the map's loading-screen art before it has been shown this session.
    local frozenBody = gui.Panel{
        styles = ThemeEngine.MergeStyles(g_frozenStyles),
        classes = {"tabletopFrozen"},
        width = "100%",
        height = "100% available",
        bgimage = "panels/square.png",
        click = function(element)
            if ClicksGuarded() then
                return
            end
            Focus(rec)
        end,
        frozenHint,
    }

    local nameLabel = gui.Label{
        classes = {"tabletopTitleText"},
        width = "auto",
        height = "100%",
        valign = "center",
        hmargin = 8,
        textWrap = false,
        text = MapName(rec.mapid),
    }

    --Where the live window shows the map's status: the Round panel (moved
    --here from the title bar) and its own map cluster.
    local initiativeSlot = gui.Panel{
        flow = "horizontal",
        width = "auto",
        height = "100%",
        valign = "center",
    }

    local mapCluster = CodexTitleBar.CreateMapCluster{nameWidth = 200}

    local liveStatus = gui.Panel{
        classes = {"collapsed"},
        flow = "horizontal",
        width = "auto",
        height = "100%",
        valign = "center",
        lmargin = 6,
        initiativeSlot,
        mapCluster,
    }

    --a frozen window whose map is in combat.
    local combatBadge = gui.Panel{
        classes = {"tabletopCombatBadge", "collapsed"},
        bgimage = "phosphor/sword-fill.png",
        width = 14,
        height = 14,
        valign = "center",
        lmargin = 10,
        hover = gui.Tooltip("This map is in combat"),
    }

    local maximizeButton = WindowControl{
        icon = "window-chrome/chrome-maximize.png",
        click = function(element)
            ToggleMaximize(rec)
        end,
    }

    local controls = {BuildFloorControl(rec)}

    --the Director makes the map Player Viewable, for all players or chosen
    --ones, which opens it on their tables. Sharing again after stopping
    --also puts it back on tables whose players closed it.
    local share = nil
    if dmhub.isDM then
        share = ShareControl{
            store = g_sharing.MapStore(rec.mapid),
            what = "this map",
            iconSize = 15,
            changed = function()
                Refresh()
            end,
        }
        controls[#controls+1] = share.button
    end

    controls[#controls+1] = WindowControl{
        icon = "window-chrome/chrome-minimize.png",
        click = function(element)
            Minimize(rec)
        end,
    }
    controls[#controls+1] = maximizeButton
    controls[#controls+1] = WindowControl{
        danger = true,
        icon = "window-chrome/chrome-close.png",
        click = function(element)
            RequestClose(rec)
        end,
    }

    --the GameHud cascade carries no theme, so the themed controls up here
    --(the buttons, the map cluster) get it from the titlebar.
    local titlebar = gui.Panel{
        styles = ThemeEngine.MergeStyles(g_titleStyles),
        classes = {"tabletopTitle"},
        flow = "horizontal",
        width = "100%",
        height = TITLE_HEIGHT,
        bgimage = "panels/square.png",
        children = {
            --the badge travels with the name it belongs to.
            gui.Panel{
                flow = "horizontal",
                width = "auto",
                height = "100%",
                valign = "center",
                combatBadge,
                nameLabel,
            },
            liveStatus,
            gui.Panel{
                floating = true,
                flow = "horizontal",
                width = "auto",
                height = "100%",
                halign = "right",
                thinkTime = 0.5,
                think = function(element)
                    controls[1]:FireEvent("updateFloor")
                end,
                children = controls,
            },
        },
    }

    local doc = {
        try_get = function(self, key)
            return rawget(self, key)
        end,
    }

    local resizePanel = gui.WindowResizePanel(doc, rec.width, rec.height, {
        minWidth = MIN_WIDTH,
        minHeight = MIN_HEIGHT,
        onResized = function(dialog, moved)
            rec.width = dialog.selfStyle.width
            rec.height = dialog.selfStyle.height
            rec.x, rec.y = ClampWindow(rec, dialog.x, dialog.y)
            if rec.x ~= dialog.x or rec.y ~= dialog.y then
                dialog.x = rec.x
                dialog.y = rec.y
            end
            SaveSoon()
        end,
    })

    panel = gui.Panel{
        styles = g_windowStyles,
        classes = {"tabletopWindow"},
        --click-to-front: a press anywhere on it, even on the live map inside
        --(MapViewport raises the live window), raises it (engine walk).
        raiseOnPress = true,
        flow = "vertical",
        x = rec.x,
        y = rec.y,
        width = rec.width,
        height = rec.height,
        halign = "left",
        valign = "top",
        bgimage = "panels/square.png",
        swallowPress = true,
        draggable = true,
        drag = function(element)
            if rec.maximized then
                return
            end
            rec.x, rec.y = SnapWindow(rec, element.xdrag, element.ydrag)
            element.x = rec.x
            element.y = rec.y
            SaveSoon()
        end,
        click = function(element)
            if ClicksGuarded() then
                return
            end
            Focus(rec)
        end,
        children = {
            titlebar,
            liveBody,
            frozenBody,
            resizePanel,
            share and share.frame,
        },
    }

    rec.panel = panel
    rec.titlebar = titlebar
    rec.liveBody = liveBody
    rec.overlay = overlay
    rec.frozenBody = frozenBody
    rec.nameLabel = nameLabel
    rec.liveStatus = liveStatus
    rec.initiativeSlot = initiativeSlot
    rec.resizePanel = resizePanel
    rec.maximizeButton = maximizeButton
    rec.share = share
    rec.combatBadge = combatBadge
    rec.shownState = nil
end

--Puts a built window in its layer: the documents layer, mixed in with
--journals and panel windows, or the bottom tabletop layer when maximized,
--so the docks and the rest of the hud sit over it as they do over a
--full-screen map.
local function PlaceWindow(rec)
    local panel = rec.panel
    if panel == nil or not panel.valid then
        return
    end

    local target = DocumentsLayer()
    if rec.maximized then
        target = g_layer
    end
    if target == nil or not target.valid then
        return
    end

    if panel.parent ~= target then
        if panel.parent ~= nil then
            panel:Unparent()
        end
        target:AddChild(panel)
    end

    if rec.maximized then
        panel.x = 0
        panel.y = 0
        panel.selfStyle.width = "100%"
        panel.selfStyle.height = "100%"
    else
        panel.x = rec.x
        panel.y = rec.y
        panel.selfStyle.width = rec.width
        panel.selfStyle.height = rec.height
    end

    rec.titlebar:SetClass("collapsed", rec.maximized == true)
    rec.resizePanel:SetClass("collapsed", rec.maximized == true)
    panel.draggable = rec.maximized ~= true
    Tabletop.ApplyCollapsed(rec)
end

--A minimized window is its button (on the table or the rail); the panel
--stays built so restoring it is instant (Refresh re-applies this to every
--window). A maximized window (map or scene), or a scene shown under the UI,
--does not hide the other windows: it sits at the bottom of the stack, and
--they float over it (David, 2026-10-14).
function Tabletop.ApplyCollapsed(rec)
    local panel = rec.panel
    if panel == nil or not panel.valid then
        return
    end
    local collapsed = rec.minimized == true
    if panel:HasClass("collapsed") ~= collapsed then
        panel:SetClass("collapsed", collapsed)
    end
end

----------------------------------------------------------------------
--Minimized windows: a rail-style button floating on the table, or docked
--on the icon rail (RailEntryTypes "mapwindow"). Clicking it restores the
--window; a window collapses into its button and grows back out of it.

local BUTTON_SIZE = 40
local ANIM_SECONDS = 0.26

--Floating buttons and the collapse animation live here, above the map
--windows and journals (Tabletop.CreateButtonLayer).
local g_buttonLayer = nil

local function ButtonScale()
    return PanelDocument.WindowUIScale()
end

--A panel's rectangle in the documents layer's units (origin top-left).
--positionInScreenSpace is the panel's centre in layer units, y up.
local function LayerRect(panel, size)
    local layer = DocumentsLayer()
    if layer == nil or panel == nil or not panel.valid then
        return nil
    end
    local lp = layer.positionInScreenSpace
    local left = lp.x - layer.renderedWidth / 2
    local top = lp.y + layer.renderedHeight / 2
    local p = panel.positionInScreenSpace
    local w = size or panel.renderedWidth
    local h = size or panel.renderedHeight
    return {x = p.x - left - w / 2, y = top - p.y - h / 2, w = w, h = h}
end

--Where the window is on the table, maximized or not.
local function WindowRect(rec)
    if rec.maximized then
        local w, h = LayerSize()
        return {x = 0, y = 0, w = w, h = h}
    end
    return {x = rec.x, y = rec.y, w = rec.width, h = rec.height}
end

--The window's docked button on the rail, if the rail has drawn it.
local function RailButton(rec)
    local layer = DocumentsLayer()
    if layer == nil then
        return nil
    end
    local key = RailKey(rec)
    for _, rail in ipairs(layer.children) do
        if rail.valid and rail:HasClass("iconRail") then
            for _, button in ipairs(rail.children) do
                local buttonKey = nil
                pcall(function()
                    buttonKey = button.data.key
                end)
                if buttonKey == key then
                    return button
                end
            end
        end
    end
    return nil
end

--Where the window's button is: its rail button when docked, else its spot
--on the table.
local function ButtonRect(rec)
    local size = BUTTON_SIZE * ButtonScale()
    if IsDocked(rec) then
        local button = RailButton(rec)
        local rect = LayerRect(button, size)
        if rect ~= nil then
            return rect
        end
    end
    return {x = rec.iconX or 0, y = rec.iconY or 0, w = size, h = size}
end

--A window-shaped stand-in that flies between two rectangles, showing what
--the window shows, then calls done. Ease in-out cubic.
local function AnimateGhost(rec, from, to, done)
    local layer = g_buttonLayer
    if layer == nil or not layer.valid or from == nil or to == nil then
        done()
        return
    end
    local image, placeholder = Tabletop.FrozenImage(rec)
    local start = dmhub.Time()
    local function lerp(a, b, t)
        return a + (b - a) * t
    end
    local ghost = gui.Panel{
        floating = true,
        interactable = false,
        halign = "left",
        valign = "top",
        x = from.x,
        y = from.y,
        width = from.w,
        height = from.h,
        bgimage = image,
        bgcolor = cond(placeholder, "#1b1814ff", "white"),
        borderWidth = 2,
        borderColor = "#b8925acc",
        cornerRadius = 6,
        thinkTime = 0.01,
        think = function(element)
            local t = math.min(1, (dmhub.Time() - start) / ANIM_SECONDS)
            local e
            if t < 0.5 then
                e = 4 * t * t * t
            else
                e = 1 - ((-2 * t + 2) ^ 3) / 2
            end
            element.x = lerp(from.x, to.x, e)
            element.y = lerp(from.y, to.y, e)
            element.selfStyle.width = math.max(1, lerp(from.w, to.w, e))
            element.selfStyle.height = math.max(1, lerp(from.h, to.h, e))
            element.selfStyle.cornerRadius = lerp(6, 8, e)
            if t >= 1 then
                element:DestroySelf()
                done()
            end
        end,
    }
    layer:AddChild(ghost)
end

--Builds (or rebuilds) a minimized window's floating button on the table.
--A docked window has no floating button: the rail draws it.
local function UpdateTableButton(rec)
    local want = rec.minimized == true and not IsDocked(rec) and g_buttonLayer ~= nil and g_buttonLayer.valid
    if not want then
        if rec.button ~= nil and rec.button.valid then
            rec.button:DestroySelf()
        end
        rec.button = nil
        return
    end
    if rec.button ~= nil and rec.button.valid then
        return
    end

    local scale = ButtonScale()
    local button
    button = gui.Panel{
        classes = {"iconRailButton", "tabletopTableButton"},
        bgimage = true,
        blurBackground = true,
        floating = true,
        halign = "left",
        valign = "top",
        x = rec.iconX or 0,
        y = rec.iconY or 0,
        width = BUTTON_SIZE,
        height = BUTTON_SIZE,
        flow = "none",
        swallowPress = true,
        draggable = true,

        --drag it onto either icon rail to dock it there.
        canDragOnto = function(element, target)
            return target:HasClass("iconRail") or target:HasClass("iconRailButton")
        end,
        dragging = function(element, target)
            IconRailDocDragging(target)
            ChatItemLinks.Dragging(function() return {ChatItemLinks.MapItem(rec.mapid)} end)
        end,
        drag = function(element, target)
            IconRailDocDragging(nil)
            --dropped on the chat: a link to the map, and the button stays put.
            if ChatItemLinks.Dropped() then
                return
            end
            if target ~= nil and target.valid and (target:HasClass("iconRail") or target:HasClass("iconRailButton")) then
                if IconRailKeyDrop(RailKey(rec), target) then
                    UpdateTableButton(rec)
                    SaveSoon()
                    return
                end
            end
            local w, h = LayerSize()
            local size = BUTTON_SIZE * scale
            rec.iconX = math.max(0, math.min(element.xdrag, w - size))
            rec.iconY = math.max(0, math.min(element.ydrag, h - size))
            element.x = rec.iconX
            element.y = rec.iconY
            SaveSoon()
        end,
        click = function(element)
            if ClicksGuarded() then
                return
            end
            RestoreWindow(rec)
        end,
        hover = function(element)
            ShowPreviewTooltip(rec, element)
        end,
        rightClick = function(element)
            element.popup = gui.ContextMenu{
                entries = {
                    GuardedEntry("Restore", function()
                        element.popup = nil
                        RestoreWindow(rec)
                    end),
                    GuardedEntry("Dock to Left Rail", function()
                        element.popup = nil
                        IconRailKeyAdd(RailKey(rec), "left")
                        UpdateTableButton(rec)
                    end),
                    GuardedEntry("Dock to Right Rail", function()
                        element.popup = nil
                        IconRailKeyAdd(RailKey(rec), "right")
                        UpdateTableButton(rec)
                    end),
                    GuardedEntry("Close Map Window", function()
                        element.popup = nil
                        RequestClose(rec)
                    end),
                },
            }
        end,

        gui.Panel{
            classes = {"iconRailIcon"},
            bgimage = "phosphor/map-trifold.png",
            width = 20,
            height = 20,
            halign = "center",
            valign = "center",
            interactable = false,
        },

        --the map is in combat: the window's combat badge, on the button
        --(kept up to date by the button's think: a hidden panel does not think).
        gui.Panel{
            classes = {"tabletopButtonCombat", "hidden"},
            bgimage = "phosphor/sword-fill.png",
            bgcolor = "#e0503f",
            floating = true,
            width = 12,
            height = 12,
            halign = "right",
            valign = "top",
            x = -3,
            y = 3,
            interactable = false,
        },

        thinkTime = 1,
        think = function(element)
            local inCombat = Tabletop.MapInCombat(rec.mapid)
            for _, child in ipairs(element.children) do
                if child:HasClass("tabletopButtonCombat") then
                    child:SetClass("hidden", not inCombat)
                end
            end
        end,
    }
    local layer = g_buttonLayer --[[@as Panel]]
    layer:AddChild(button)
    button.selfStyle.pivot = {x = 0, y = 1}
    button.selfStyle.uiscale = scale
    rec.button = button
end

--Collapses a window into its button: on the table where its middle was
--(or where its button was left last time), or on the rail if docked.
Minimize = function(rec)
    if rec.minimized or IsForcedHere(rec) then
        return
    end
    if rec.id == g_liveId then
        --the button's preview and the animation show the map as it was left.
        dmhub.CaptureMapSnapshot()
    end
    local from = WindowRect(rec)
    if rec.iconX == nil then
        local size = BUTTON_SIZE * ButtonScale()
        rec.iconX = math.floor(from.x + from.w / 2 - size / 2)
        rec.iconY = math.floor(from.y + from.h / 2 - size / 2)
    end
    rec.minimized = true
    if g_focusedId == rec.id then
        g_focusedId = nil
    end
    if rec.maximized then
        --the Director stopped looking at it: the players are released.
        Tabletop.SetForced(rec.mapid, false)
    end
    PlaceWindow(rec)
    Refresh()
    local to = ButtonRect(rec)
    AnimateGhost(rec, from, to, function()
        if IsOpen(rec) and rec.minimized then
            UpdateTableButton(rec)
            if rec.button ~= nil and rec.button.valid then
                rec.button:PulseClass("justDropped")
            end
        end
    end)
    SaveSoon()
end

--Grows a minimized window back out of its button and focuses it (which
--travels to its map; the travel starts with the animation, so the map is
--loading while the window opens).
RestoreWindow = function(rec)
    if not rec.minimized then
        Focus(rec)
        return
    end
    local from = ButtonRect(rec)
    rec.minimized = false
    UpdateTableButton(rec)
    g_focusedId = rec.id
    Travel(rec.mapid)
    AnimateGhost(rec, from, WindowRect(rec), function()
        if IsOpen(rec) and not rec.minimized then
            PlaceWindow(rec)
            if rec.maximized then
                Tabletop.SetForced(rec.mapid, true)
            end
            Focus(rec)
        end
    end)
    SaveSoon()
end

--Takes the live map status back from whichever window holds it.
local function ReleaseMapStatus()
    CodexTitleBar.SetInitiativeStatusHost(nil)
    CodexTitleBar.SetMapStatusInWindow(false)
end

----------------------------------------------------------------------
--Map HUD: GameHud elements that belong to the current map rather than to
--the screen -- the initiative bar, since initiative is per map. GameHud
--builds each inside a full-size slot (MapHudSlot). In tabletop mode it moves
--into the live window's overlay, and back to its slot otherwise.

local g_mapHuds = {}

--Wraps panel (nil passes through) in its GameHud slot. Called from the
--GameHud child list.
function Tabletop.MapHudSlot(panel)
    if panel == nil then
        return nil
    end
    local slot = gui.Panel{
        width = "100%",
        height = "100%",
        panel,
    }
    --drop entries left over from earlier GameHuds.
    local kept = {}
    for _,entry in ipairs(g_mapHuds) do
        if entry.slot.valid then
            kept[#kept+1] = entry
        end
    end
    kept[#kept+1] = {slot = slot, panel = panel}
    g_mapHuds = kept
    return slot
end

--The width the map HUD (the initiative bar's card row and its margins)
--needs at full size.
local HUD_FULL_WIDTH = 1180

--Shrinks the map HUD, about its top centre, to fit a window narrower than
--it; full size again in a wide window or back in its slot (host nil).
function Tabletop.ScaleMapHuds(host)
    local scale = 1
    if host ~= nil and host.valid and host.renderedWidth > 0 then
        scale = math.min(1, host.renderedWidth / HUD_FULL_WIDTH)
    end
    scale = math.floor(scale * 100 + 0.5) / 100
    for _,entry in ipairs(g_mapHuds) do
        if entry.panel.valid and entry.scale ~= scale then
            entry.scale = scale
            entry.panel.selfStyle.pivot = {x = 0.5, y = 1}
            entry.panel.selfStyle.uiscale = scale
        end
    end
end

--Puts the map HUD into host (the live window's overlay), or back into its
--slots when host is nil. On the empty table (tabletop on, no live window)
--the slots are hidden: there is no map to show it over.
local function PlaceMapHuds(host)
    local hide = host == nil and Tabletop.IsActive()
    for _,entry in ipairs(g_mapHuds) do
        if entry.slot.valid and entry.panel.valid then
            local target = host
            if target == nil or not target.valid then
                target = entry.slot
            end
            if entry.panel.parent ~= target then
                entry.panel:Unparent()
                target:AddChild(entry.panel)
            end
            entry.slot:SetClass("collapsed", hide)
        end
    end
    Tabletop.ScaleMapHuds(host)
end

local function DestroyWindowPanel(rec)
    if rec.panel ~= nil and rec.panel.valid then
        if rec.id == g_liveId then
            --take the map's status and HUD out first, or they go with it.
            ReleaseMapStatus()
            PlaceMapHuds(nil)
        end
        rec.panel:DestroySelf()
    end
    rec.panel = nil
end

----------------------------------------------------------------------
--Which window is live, and what each window shows.

local function ResolveLive()
    local current = game.currentMapId
    local live = WindowById(g_liveId)
    if live ~= nil and live.mapid == current then
        return
    end

    local focused = WindowById(g_focusedId)
    if focused ~= nil and focused.mapid == current then
        g_liveId = focused.id
        return
    end

    local other = WindowForMap(current)
    g_liveId = other ~= nil and other.id or nil
end

--What a frozen window shows, and whether that is just a placeholder (no
--snapshot this session and no loading-screen art).
local function FrozenImage(rec)
    if dmhub.HasMapSnapshot(rec.mapid) then
        return "#MapSnapshot:" .. rec.mapid, false
    end
    local map = game.GetMap(rec.mapid)
    if map ~= nil and map.valid and type(map.loadingScreenImage) == "string" and map.loadingScreenImage ~= "" then
        return map.loadingScreenImage, false
    end
    return "panels/square.png", true
end

Tabletop.FrozenImage = FrozenImage

--Whether a map's own initiative is running (initiative is per map).
function Tabletop.MapInCombat(mapid)
    local queue = dmhub.GetMapInitiativeQueue(mapid)
    return queue ~= nil and not queue.hidden
end

--The hover card for a minimized window's button (floating or docked): the
--map's name, whether it is in combat or shared, and what it last showed.
ShowPreviewTooltip = function(rec, element)
    local image, placeholder = FrozenImage(rec)
    local width = 260
    local height = math.floor(width * rec.height / math.max(1, rec.width))
    height = math.max(110, math.min(200, height))

    local status = {}
    local queue = dmhub.GetMapInitiativeQueue(rec.mapid)
    if queue ~= nil and not queue.hidden then
        status[#status+1] = string.format("In combat - Round %d", queue.round)
    end
    if IsShared(rec.mapid) then
        status[#status+1] = cond(dmhub.isDM, "Shared with players", "Shared by the Director")
    end
    status[#status+1] = "Click to open"

    local content = gui.Panel{
        flow = "vertical",
        width = "auto",
        height = "auto",
        gui.Label{
            text = MapName(rec.mapid),
            bold = true,
            fontSize = 16,
            color = "#f2ede1",
            width = "auto",
            height = "auto",
            halign = "left",
            textWrap = false,
        },
        gui.Label{
            text = table.concat(status, "  -  "),
            fontSize = 12,
            color = "#bdb3a4",
            width = "auto",
            height = "auto",
            halign = "left",
            textWrap = false,
            bmargin = 6,
        },
        gui.Panel{
            bgimage = image,
            bgcolor = cond(placeholder, "#1b1814ff", "white"),
            width = width,
            height = height,
            halign = "left",
            cornerRadius = 4,
            saturation = cond(placeholder, 1, 0.85),
        },
    }
    element.tooltip = gui.TooltipFrame(content)
end

local function FrozenTitle(rec)
    local name = MapName(rec.mapid)
    local queue = dmhub.GetMapInitiativeQueue(rec.mapid)
    if queue ~= nil and not queue.hidden then
        return string.format("%s - Round %d", name, queue.round)
    end
    return name
end

--A maximized window's own controls, shown in the app title bar beside the
--map's name (the window's titlebar is hidden). They use the title bar's
--windowControl classes, so they match the app's own caption buttons.
local function TitleBarControl(icon, tooltip, click)
    return gui.Panel{
        classes = {"windowControl"},
        bgimage = true,
        width = 36,
        height = "100%",
        valign = "center",
        hover = gui.Tooltip(tooltip),
        click = click,
        gui.Panel{
            classes = {"windowControlIcon"},
            bgimage = icon,
            width = 14,
            height = 14,
            halign = "center",
            valign = "center",
            interactable = false,
        },
    }
end

local function UpdateRestoreButton(show)
    if show then
        if g_restoreButton == nil or not g_restoreButton.valid then
            g_restoreButton = gui.Panel{
                flow = "horizontal",
                width = "auto",
                height = "100%",
                valign = "center",
                lmargin = 6,
                TitleBarControl("window-chrome/chrome-minimize.png", "Minimize the map window", function(element)
                    local rec = WindowById(g_liveId)
                    if rec ~= nil then
                        Minimize(rec)
                    end
                end),
                TitleBarControl("window-chrome/chrome-restore.png", "Restore the map window", function(element)
                    local rec = WindowById(g_liveId)
                    if rec ~= nil and rec.maximized then
                        ToggleMaximize(rec)
                    end
                end),
            }
        end
        CodexTitleBar.SetMapWindowControls(g_restoreButton)
    else
        CodexTitleBar.SetMapWindowControls(nil)
        g_restoreButton = nil
    end
end

Refresh = function()
    ResolveLive()

    local liveRec = WindowById(g_liveId)
    local liveShown = liveRec ~= nil and liveRec.panel ~= nil and liveRec.panel.valid and not liveRec.minimized
    local statusInWindow = liveRec ~= nil and liveShown and not liveRec.maximized

    --move the Round panel out of a window before that window stops being
    --live, then into the new live window.
    if not statusInWindow then
        ReleaseMapStatus()
    end

    --no window shows the map (the empty table): the hidden map's name and
    --Round stay out of the title bar too.
    if not liveShown then
        CodexTitleBar.SetMapStatusInWindow(true)
    end

    for _,rec in ipairs(g_windows) do
        local panel = rec.panel
        if panel ~= nil and panel.valid then
            local live = rec.id == g_liveId
            panel:SetClass("focused", rec.id == g_focusedId)

            local liveImage = cond(live, "#MapView", "panels/square.png")
            if rec.liveImage ~= liveImage then
                rec.liveImage = liveImage
                rec.liveBody.bgimage = liveImage
            end
            rec.liveBody:SetClass("collapsed", not live)
            rec.frozenBody:SetClass("collapsed", live)
            rec.liveStatus:SetClass("collapsed", not live)
            rec.nameLabel:SetClass("collapsed", live)

            if not live then
                local image, placeholder = FrozenImage(rec)
                if rec.frozenImage ~= image then
                    rec.frozenImage = image
                    rec.frozenBody.bgimage = image
                end
                rec.frozenBody:SetClass("tabletopPlaceholder", placeholder)
                local title = FrozenTitle(rec)
                if rec.nameLabel.text ~= title then
                    rec.nameLabel.text = title
                end
            end

            rec.combatBadge:SetClass("collapsed", live or not Tabletop.MapInCombat(rec.mapid))
            UpdateShare(rec.share)
            Tabletop.ApplyCollapsed(rec)
        end
        UpdateTableButton(rec)
    end

    if statusInWindow and liveRec ~= nil then
        CodexTitleBar.SetMapStatusInWindow(true)
        CodexTitleBar.SetInitiativeStatusHost(liveRec.initiativeSlot)
    end

    local hudHost = nil
    if liveShown and liveRec ~= nil then
        hudHost = liveRec.overlay
    end
    PlaceMapHuds(hudHost)
    --keyed on the host actually being on screen (a window growing back out
    --of its button is still collapsed for the length of the animation).
    local visibleHost = Tabletop.MapOverlayHost()
    if visibleHost ~= g_lastHudHost then
        g_lastHudHost = visibleHost
        if visibleHost ~= nil then
            --a dialog presented for this map while no window showed it
            --(the "Draw Steel" banner) can open now.
            Tabletop.RecheckPresentedDialog()
        end
    end

    if AnySceneMaximized() then
        --a maximized scene window has the title bar's window controls.
        UpdateSceneTitleControls()
    else
        UpdateRestoreButton(liveShown and liveRec ~= nil and liveRec.maximized == true and not IsForcedHere(liveRec))
    end
end

----------------------------------------------------------------------
--Opening, focusing, closing.

--The map a travel was last started to, so a second click while it loads
--does not start another (cleared when the current map changes).
local g_travelTarget = nil

Travel = function(mapid)
    if mapid == game.currentMapId then
        return
    end
    if g_travelTarget ~= nil and g_travelTarget.mapid == mapid and dmhub.Time() < g_travelTarget.time + 10 then
        return
    end
    local map = game.GetMap(mapid)
    if map ~= nil and map.valid then
        g_travelTarget = {mapid = mapid, time = dmhub.Time()}
        map:Travel()
    end
end

IsOpen = function(rec)
    for _,other in ipairs(g_windows) do
        if other == rec then
            return true
        end
    end
    return false
end

local function EnsureBuilt(rec)
    if rec.panel == nil or not rec.panel.valid then
        BuildWindow(rec)
    end
    PlaceWindow(rec)
end

Focus = function(rec)
    --a click on a window's close button also reaches the window itself.
    if not IsOpen(rec) then
        return
    end
    if rec.minimized then
        RestoreWindow(rec)
        return
    end
    BringToFront(rec)
    if g_focusedId ~= rec.id then
        g_focusedId = rec.id
        SaveSoon()
    end
    Travel(rec.mapid)
    Refresh()
end

CloseWindow = function(rec)
    DestroyWindowPanel(rec)
    if rec.button ~= nil and rec.button.valid then
        rec.button:DestroySelf()
    end
    rec.button = nil
    if IsDocked(rec) then
        IconRailKeyPurge(RailKey(rec))
    end
    if rec.maximized then
        Tabletop.SetForced(rec.mapid, false)
    end
    for i,other in ipairs(g_windows) do
        if other == rec then
            table.remove(g_windows, i)
            break
        end
    end
    if g_focusedId == rec.id then
        g_focusedId = nil
    end
    local wasLive = g_liveId == rec.id
    if wasLive then
        --the map stays loaded but hidden: the table with no map on it.
        g_liveId = nil
    end
    Refresh()
    if wasLive and g_liveId == nil then
        --no window shows the loaded map any more, so its tokens cannot stay
        --selected (the action bar and sheets would still act on them).
        dmhub.selectedTokens = {}
    end
    SaveSoon()
end

--A window the Director has forced maximized here cannot be closed.
RequestClose = function(rec)
    if IsForcedHere(rec) then
        return
    end
    CloseWindow(rec)
end

ToggleMaximize = function(rec)
    if IsForcedHere(rec) then
        return
    end
    rec.maximized = not rec.maximized
    if rec.maximized then
        --one maximized window at a time
        UnmaximizeScenes()
        for _,other in ipairs(g_windows) do
            if other ~= rec and other.maximized then
                other.maximized = false
                PlaceWindow(other)
                Tabletop.SetForced(other.mapid, false)
            end
        end
    end
    PlaceWindow(rec)
    --the Director's maximize is forced on the tables of the map's players.
    Tabletop.SetForced(rec.mapid, rec.maximized == true)
    Focus(rec)
    SaveSoon()
end

--Opens a map on the table (the Maps panel calls this in tabletop mode).
--A map that already has a window focuses it. Otherwise it opens in the
--focused window, or in a new window when there is no focused window or
--options.newWindow is set.
function Tabletop.OpenMap(mapid, options)
    options = options or {}

    local existing = WindowForMap(mapid)
    if existing ~= nil then
        Focus(existing)
        return
    end

    local focused = WindowById(g_focusedId)
    if focused ~= nil and not options.newWindow then
        if focused.id == g_liveId and mapid ~= game.currentMapId then
            --the window keeps showing its map until we arrive, so the engine
            --can freeze it on the way out; then it takes the new map.
            g_pendingAdopt = {mapid = mapid, windowId = focused.id}
            Travel(mapid)
            return
        end
        focused.mapid = mapid
        if focused.panel ~= nil and focused.panel.valid then
            focused.nameLabel.text = MapName(mapid)
        end
        Focus(focused)
        SaveSoon()
        return
    end

    local rec = NewWindowRecord(mapid)
    g_windows[#g_windows+1] = rec
    EnsureBuilt(rec)
    Focus(rec)
    SaveSoon()
end

--The engine changed the current map (travel, a token moving maps, a
--journal link...). A window already showing the new map takes over, with
--a highlight when the change was not the user's own click; otherwise the
--window that was live, or the one waiting for this map, shows it now.
local function OnCurrentMapChanged(newMapId)
    local adopt = g_pendingAdopt
    g_pendingAdopt = nil
    g_travelTarget = nil

    local requested = WindowById(g_focusedId)
    local target = WindowForMap(newMapId)
    local unrequested = requested == nil or requested.mapid ~= newMapId

    if target == nil then
        local adopter = nil
        if adopt ~= nil and adopt.mapid == newMapId then
            adopter = WindowById(adopt.windowId)
            unrequested = false
        end
        adopter = adopter or WindowById(g_liveId) or requested
        if adopter ~= nil then
            adopter.mapid = newMapId
            if adopter.panel ~= nil and adopter.panel.valid then
                adopter.nameLabel.text = MapName(newMapId)
            end
            target = adopter
            unrequested = false
        end
    end

    if target ~= nil then
        --a window that just took the new map stays where it is in the stack
        --(the user may be working in the Maps panel above it); a different
        --window taking over comes forward.
        if target.id ~= g_liveId then
            BringToFront(target)
        end
        g_liveId = target.id
        g_focusedId = target.id
        if target.minimized then
            --we are on its map now: it opens back up.
            RestoreWindow(target)
        end
        if unrequested then
            Highlight(target)
        end
    else
        g_liveId = nil
    end

    Refresh()
    SaveSoon()
end

----------------------------------------------------------------------
--Lifecycle: the tabletop layer is rebuilt with every GameHud; the window
--records survive and are rebuilt into it.

local function Teardown()
    for _,rec in ipairs(g_windows) do
        DestroyWindowPanel(rec)
        if rec.button ~= nil and rec.button.valid then
            rec.button:DestroySelf()
        end
        rec.button = nil
    end
    ReleaseMapStatus()
    PlaceMapHuds(nil)
    UpdateRestoreButton(false)
end

--Where a dialog presented for the current map (args.mapid, e.g. the "Draw
--Steel" banner) opens in the tabletop view: over the map inside its live
--window. nil when the view is off, or no window shows the map (the empty
--table), in which case GameHud waits rather than show it over the table.
function Tabletop.MapOverlayHost()
    if not Tabletop.IsActive() then
        return nil
    end
    local live = WindowById(g_liveId)
    if live == nil or live.minimized or live.overlay == nil or not live.overlay.valid then
        return nil
    end
    --covered by another maximized window: not on screen either.
    if live.panel == nil or not live.panel.valid or live.panel:HasClass("collapsed") then
        return nil
    end
    return live.overlay
end

local function MapExists(mapid)
    local map = game.GetMap(mapid)
    return map ~= nil and map.valid
end

----------------------------------------------------------------------
--Dialogs presented for a map (the "Draw Steel" banner) that this client
--missed because no window showed the map. GameHud drops a dialog past its
--ttl; one this client never showed is instead shown the next time a window
--shows its map, while that map is still in combat.

--How long a missed map dialog keeps waiting for its window.
local LATE_DIALOG_SECONDS = 1800

--Presentations this client has shown (or that predate its arrival).
local g_shownMapDialogs = {}

local function MapDialogKey(data)
    return string.format("%s|%s|%s", tostring(data.timestamp), tostring(data.dialog.dialog), tostring(data.dialog.args.mapid))
end

function Tabletop.NoteMapDialogShown(data)
    g_shownMapDialogs[MapDialogKey(data)] = true
end

function Tabletop.ShowLateMapDialog(data)
    if not Tabletop.IsActive() then
        return false
    end
    local mapid = data.dialog.args.mapid
    if mapid == nil or mapid ~= game.currentMapId or g_shownMapDialogs[MapDialogKey(data)] then
        return false
    end
    if Tabletop.MapOverlayHost() == nil or not Tabletop.MapInCombat(mapid) then
        return false
    end
    return TimestampAgeInSeconds(data.timestamp) < LATE_DIALOG_SECONDS
end

--A client arriving mid-combat does not replay the banner it was not
--there for.
local function NoteExistingMapDialog()
    local data = mod:GetDocumentSnapshot("presentdialog").data
    if type(data.dialog) == "table" and type(data.dialog.args) == "table" and data.dialog.args.mapid ~= nil then
        Tabletop.NoteMapDialogShown(data)
    end
end

--Called when a window starts showing the map: GameHud re-checks the
--presented dialog (it otherwise only looks when the document changes).
function Tabletop.RecheckPresentedDialog()
    local hud = GameHud.instance
    if hud ~= nil and hud.parentPanel ~= nil and hud.parentPanel.valid then
        hud.parentPanel:FireEvent("refreshGame")
    end
end

----------------------------------------------------------------------
--Sharing. The Director shares table items -- NPC cards, journal entries
--and scenes -- with the players' tables through the "tabletop" shared
--document:
--  data.items[itemId]  {kind = "card", charid = ..., seq = n}
--                      {kind = "doc", entryid = ..., seq = n} (a journal entry)
--                      {kind = "scene", sceneid = ..., seq = n} (a Scenes library scene)
--  data.seq            the last seq handed out
--  data.forced[mapid]  true while the Director has that map maximized
--An item shared with only some players also has users = {userid = seq}
--and all = false (all = true once every player is back in users). Without
--users it goes to every player, including ones who join later.
--Each share, and each re-share, takes a new seq. A player's table opens
--every item shared with them whose seq it has not seen yet, then leaves it
--to them: they keep, move or close it, and it comes back only when it is
--shared with them again.
--A map the Director maximizes is forced maximized on the tables of the
--players with a token on it until the Director restores it.
--Maps are not in the document: a map window's share button is the map's
--Player Viewable setting, for all players or chosen ones (g_sharing.MapStore).
--A player's table opens a map when it becomes viewable for them and closes
--it when it stops, unless they have a token there (SyncViewableMaps).

local SHARE_DOC = "tabletop"

local function ShareDoc()
    return mod:GetDocumentSnapshot(SHARE_DOC)
end

local function SharedItems()
    local items = ShareDoc().data.items
    if type(items) ~= "table" then
        return {}
    end
    return items
end

local function CardItemId(charid)
    return "card:" .. charid
end

--Whether an item goes to every player: item.all, or no item.users at all
--(as with every share made before sharing with some players).
local function SharedWithAll(item)
    return item.users == nil or item.all == true
end

--The seq a player's table opens a shared item at, or nil when the item is
--not shared with them. item.users maps userid -> seq for players given
--their own seq (added one at a time); the rest of "all" use item.seq.
local function ShareSeqFor(item, userid)
    if type(item.users) == "table" and item.users[userid] ~= nil then
        return tonumber(item.users[userid])
    end
    if SharedWithAll(item) then
        return tonumber(item.seq)
    end
    return nil
end

--The players an item can be shared with: everyone in the game but the
--Directors, by name.
local function SharePlayers()
    local result = {}
    for _, uid in ipairs(dmhub.users) do
        if not dmhub.IsUserDM(uid) then
            result[#result+1] = uid
        end
    end
    table.sort(result, function(a, b)
        return string.lower(dmhub.GetDisplayName(a) or "") < string.lower(dmhub.GetDisplayName(b) or "")
    end)
    return result
end

--nil (not shared), "all" or "some" (shared with only some players).
local function ShareState(itemId)
    local item = SharedItems()[itemId]
    if type(item) ~= "table" then
        return nil
    end
    if SharedWithAll(item) then
        return "all"
    end
    return "some"
end

--Shared at all for the Director; shared with this user for a player.
local function IsItemSharedHere(itemId)
    local item = SharedItems()[itemId]
    if type(item) ~= "table" then
        return false
    end
    return dmhub.isDM or ShareSeqFor(item, dmhub.userid) ~= nil
end

function Tabletop.IsCardShared(charid)
    return IsItemSharedHere(CardItemId(charid))
end

--Shares (or shares again) an item: it opens on every player's table.
local function ShareItem(itemId, item)
    local doc = ShareDoc()
    doc:BeginChange()
    if type(doc.data.items) ~= "table" then
        doc.data.items = {}
    end
    doc.data.seq = (tonumber(doc.data.seq) or 0) + 1
    item.seq = doc.data.seq
    doc.data.items[itemId] = item
    doc:CompleteChange("Share on the table", {undoable = false})
end

local function UnshareItem(itemId)
    local doc = ShareDoc()
    if type(doc.data.items) ~= "table" or doc.data.items[itemId] == nil then
        return
    end
    doc:BeginChange()
    doc.data.items[itemId] = nil
    doc:CompleteChange("Stop sharing on the table", {undoable = false})
end

--Shares an item with every player, now and joining later. Players who did
--not have it get a new seq, so it opens on their tables; the rest keep
--theirs, so a table where it was closed is left alone.
local function ShareWithAll(itemId, newItem)
    local current = SharedItems()[itemId]
    if type(current) ~= "table" then
        ShareItem(itemId, newItem)
        return
    end
    local doc = ShareDoc()
    doc:BeginChange()
    doc.data.seq = (tonumber(doc.data.seq) or 0) + 1
    local item = doc.data.items[itemId]
    local users = {}
    for _, uid in ipairs(SharePlayers()) do
        users[uid] = ShareSeqFor(item, uid) or doc.data.seq
    end
    item.users = users
    item.all = true
    doc:CompleteChange("Share on the table", {undoable = false})
end

--Shares an item with one more player (it opens on their table at a new
--seq), or stops sharing it with one. Every player then gets their own entry
--in item.users; with all of them in it, it counts as shared with all again,
--and with none of them it is not shared at all.
local function SetSharedWithPlayer(itemId, newItem, userid, on)
    if type(SharedItems()[itemId]) ~= "table" and not on then
        return
    end
    local players = SharePlayers()
    local doc = ShareDoc()
    doc:BeginChange()
    if type(doc.data.items) ~= "table" then
        doc.data.items = {}
    end
    --a new seq even when nothing opens anywhere: the seq changing is how
    --the Director's other windows notice the share changed.
    doc.data.seq = (tonumber(doc.data.seq) or 0) + 1
    local item = doc.data.items[itemId]
    if type(item) ~= "table" then
        item = newItem
        item.seq = doc.data.seq
        item.users = {}
        item.all = false
        doc.data.items[itemId] = item
    end
    local users = {}
    for _, uid in ipairs(players) do
        users[uid] = ShareSeqFor(item, uid)
    end
    if on then
        users[userid] = users[userid] or doc.data.seq
    else
        users[userid] = nil
    end
    local count = 0
    for _, uid in ipairs(players) do
        if users[uid] ~= nil then
            count = count + 1
        end
    end
    if count == 0 then
        doc.data.items[itemId] = nil
    else
        item.users = users
        item.all = count == #players
    end
    doc:CompleteChange("Share on the table", {undoable = false})
end

--A share control reads and changes its item's share through a store, so a
--map's button can work on the map's Player Viewable setting while cards,
--journal entries and scenes use the shared document.
--- @class TabletopShareStore
--- @field state fun(): nil|string nil, "all" or "some"
--- @field isSharedWith fun(userid: string): boolean
--- @field share fun() share with every player (a click)
--- @field unshare fun()
--- @field shareAll fun() "All players" in the menu
--- @field setPlayer fun(userid: string, on: boolean)

--- @param itemId string
--- @param newItem fun(): table the item record to share (kind and id)
--- @return TabletopShareStore
g_sharing.DocStore = function(itemId, newItem)
    return {
        state = function()
            return ShareState(itemId)
        end,
        isSharedWith = function(userid)
            local item = SharedItems()[itemId]
            return type(item) == "table" and ShareSeqFor(item, userid) ~= nil
        end,
        share = function()
            ShareItem(itemId, newItem())
        end,
        unshare = function()
            UnshareItem(itemId)
        end,
        shareAll = function()
            ShareWithAll(itemId, newItem())
        end,
        setPlayer = function(userid, on)
            SetSharedWithPlayer(itemId, newItem(), userid, on)
        end,
    }
end

--A map's share is its Player Viewable setting: on for every player
--(players joining later too), or for the players picked one by one.
--- @param mapid string
--- @return TabletopShareStore
g_sharing.MapStore = function(mapid)
    local function Map()
        local map = game.GetMap(mapid)
        if map == nil or not map.valid then
            return nil
        end
        return map
    end
    return {
        state = function()
            local map = Map()
            if map == nil then
                return nil
            end
            if map.playerViewableAll then
                return "all"
            end
            if next(map.playerViewableUsers or {}) ~= nil then
                return "some"
            end
            return nil
        end,
        isSharedWith = function(userid)
            local map = Map()
            return map ~= nil and map:IsPlayerViewableFor(userid)
        end,
        share = function()
            local map = Map()
            if map ~= nil then
                map:SetPlayerViewable(true, nil)
            end
        end,
        unshare = function()
            local map = Map()
            if map ~= nil then
                map:SetPlayerViewable(false, nil)
            end
        end,
        shareAll = function()
            local map = Map()
            if map ~= nil then
                map:SetPlayerViewable(true, nil)
            end
        end,
        setPlayer = function(userid, on)
            local map = Map()
            if map == nil then
                return
            end
            local players = SharePlayers()
            local users = {}
            for _, uid in ipairs(players) do
                if map:IsPlayerViewableFor(uid) then
                    users[uid] = true
                end
            end
            users[userid] = on or nil
            local count = 0
            for _, uid in ipairs(players) do
                if users[uid] then
                    count = count + 1
                end
            end
            --every player picked counts as all players again, as with shares.
            if count > 0 and count == #players then
                map:SetPlayerViewable(true, nil)
            else
                map:SetPlayerViewable(false, users)
            end
        end,
    }
end

--Shared at all for the Director; viewable by this user for a player.
IsShared = function(mapid)
    local store = g_sharing.MapStore(mapid)
    if dmhub.isDM then
        return store.state() ~= nil
    end
    return store.isSharedWith(dmhub.userid)
end

--The players an item is shared with, by name, for its tooltip.
--- @param store TabletopShareStore
local function SharedNames(store)
    local names = {}
    for _, uid in ipairs(SharePlayers()) do
        if store.isSharedWith(uid) then
            names[#names+1] = dmhub.GetDisplayName(uid) or "?"
        end
    end
    return table.concat(names, ", ")
end

--The Director's pick of players for an item, opened by right-clicking its
--share control. It stays open, rebuilt after each pick, so several players
--can be checked or unchecked in a row.
local function ShowSharePlayersMenu(share, element)
    local store = share.store
    local state = store.state()
    local players = SharePlayers()

    local function Changed()
        UpdateShare(share)
        if share.changed ~= nil then
            share.changed()
        end
        if element.valid then
            ShowSharePlayersMenu(share, element)
        end
    end

    --(the first entry never gets a divider after it, so the heading keeps
    --one between "All players" and the players.)
    local entries = {
        {text = "Share with:", disabled = true, group = "heading"},
        {
            text = "All players",
            check = state == "all",
            group = "all",
            click = function()
                GuardClicks()
                if state == "all" then
                    store.unshare()
                else
                    store.shareAll()
                end
                Changed()
            end,
        },
    }
    for _, uid in ipairs(players) do
        local on = store.isSharedWith(uid)
        entries[#entries+1] = {
            text = dmhub.GetDisplayName(uid) or "?",
            check = on,
            group = "players",
            click = function()
                GuardClicks()
                store.setPlayer(uid, not on)
                Changed()
            end,
        }
    end
    if #players == 0 then
        entries[#entries+1] = {text = "No players in this game", disabled = true, group = "players"}
    end
    element.popup = gui.ContextMenu{entries = entries}
end

--The frame drawn around a table item while the Director shares it.
local function ShareFrame(cornerRadius)
    return gui.Panel{
        styles = ThemeEngine.MergeTokens{
            {
                selectors = {"tabletopShareFrame"},
                borderColor = "@share",
            },
        },
        classes = {"tabletopShareFrame", "collapsed"},
        floating = true,
        interactable = false,
        halign = "center",
        valign = "center",
        width = "100%",
        height = "100%",
        bgimage = "panels/square.png",
        bgcolor = "clear",
        borderWidth = 2,
        cornerRadius = cornerRadius or 0,
    }
end

--The Director's share toggle for a table item. A click shares it with
--every player or stops sharing it; a right-click picks players one by one.
--Returns {button, frame, itemId, ...}: the button goes in the titlebar's
--controls, the frame among the item's own children, and UpdateShare keeps
--both current.
--args: store (a TabletopShareStore), or itemId and newItem, a function
--making the item record to share (kind and id), for an item in the shared
--document; what ("this map") for the tooltip; changed, called after the
--Director changes the share; iconSize, width, passPress and beforeHover
--(called before the tooltip shows) for the button; cornerRadius for the
--frame.
ShareControl = function(args)
    local icon = "phosphor/share-network.png"
    --lit over the top half of the glyph while shared with some players.
    --imageRect counts up from the bottom, so the top half is 0.5 to 1.
    local half = gui.Panel{
        classes = {"tabletopShareHalf", "collapsed"},
        bgimage = icon,
        width = "100%",
        height = "50%",
        halign = "center",
        valign = "top",
        imageRect = {x1 = 0, y1 = 0.5, x2 = 1, y2 = 1},
        interactable = false,
    }
    local share = {
        store = args.store or g_sharing.DocStore(args.itemId, args.newItem),
        changed = args.changed,
        half = half,
        frame = ShareFrame(args.cornerRadius),
    }
    share.button = WindowControl{
        icon = icon,
        iconSize = args.iconSize,
        width = args.width,
        passPress = args.passPress,
        iconChildren = {half},
        hover = function(element)
            if args.beforeHover ~= nil then
                args.beforeHover()
            end
            local state = share.store.state()
            local text
            if state == "all" then
                text = "Shared with all players. Click to stop sharing; right-click to choose players."
            elseif state == "some" then
                text = string.format("Shared with %s. Click to stop sharing; right-click to choose players.", SharedNames(share.store))
            else
                text = string.format("Share %s with the players' tables. Right-click to choose players.", args.what or "this")
            end
            gui.Tooltip(text)(element)
        end,
        click = function(element)
            if share.store.state() ~= nil then
                share.store.unshare()
            else
                share.store.share()
            end
            UpdateShare(share)
            if share.changed ~= nil then
                share.changed()
            end
        end,
        rightClick = function(element)
            element.tooltip = nil
            ShowSharePlayersMenu(share, element)
        end,
    }
    UpdateShare(share)
    return share
end

--Brings a share control (nil for players, who have none) and its item's
--frame up to date with the shared document.
UpdateShare = function(share)
    if share == nil then
        return
    end
    local state = share.store.state()
    share.button:SetClass("tabletopShared", state == "all")
    share.half:SetClass("collapsed", state ~= "some")
    share.frame:SetClass("collapsed", state == nil)
end

--The Director maximizing (or restoring) a map forces it maximized (or
--releases it) on the tables of the players with a token on it.
local function SetForced(mapid, forced)
    if not dmhub.isDM then
        return
    end
    local doc = ShareDoc()
    local current = type(doc.data.forced) == "table" and doc.data.forced[mapid] == true
    if current == forced then
        return
    end
    doc:BeginChange()
    if type(doc.data.forced) ~= "table" then
        doc.data.forced = {}
    end
    if forced then
        doc.data.forced[mapid] = true
    else
        doc.data.forced[mapid] = nil
    end
    doc:CompleteChange("Force a map maximized", {undoable = false})
end
Tabletop.SetForced = SetForced

function Tabletop.ShareCard(charid)
    ShareItem(CardItemId(charid), {kind = "card", charid = charid})
end

function Tabletop.UnshareCard(charid)
    UnshareItem(CardItemId(charid))
end

--Whether this player controls a token on a map (any map, not just the
--current one: every client has every character's location).
local function LocalPlayerHasTokenOn(mapid)
    for _, tok in pairs(game.GetGameGlobalCharacters()) do
        if tok.mapid == mapid and tok.canControlAsUser then
            local despawned = false
            pcall(function()
                despawned = tok.despawned == true
            end)
            if not despawned then
                return true
            end
        end
    end
    return false
end

--Whether this user may open a map: the Director always; a player when it
--is Player Viewable for them or one of their tokens is on it (the same
--rule as the player's Maps panel).
function Tabletop.CanAccessMap(mapid)
    if dmhub.isDM then
        return true
    end
    local map = game.GetMap(mapid)
    if map == nil or not map.valid then
        return false
    end
    --a map opened from a chat link (Tabletop.OpenLinkedMap) stays open for
    --this session.
    if map.playerViewable or dmhub.HasLinkedMapView(mapid) then
        return true
    end
    return LocalPlayerHasTokenOn(mapid)
end

--- Opens a map from a chat link (ChatItemLinks.lua), in a new window, or
--- brings its window up. A player who could not open the map gets a view of
--- it on this client until the app closes (dmhub.GrantLinkedMapView); the
--- map's Player Viewable setting is not changed.
--- @param mapid string
function Tabletop.OpenLinkedMap(mapid)
    if not Tabletop.CanAccessMap(mapid) then
        dmhub.GrantLinkedMapView(mapid)
    end
    Tabletop.OpenMap(mapid, {newWindow = true})
end

IsForcedHere = function(rec)
    return rec.forced == true
end

--A map made Player Viewable for this player turns up on their table: its window
--comes forward, or a new one opens beside the others. It does not travel
--there; the player clicks it when they want to look.
local function OpenSharedMap(mapid)
    local rec = WindowForMap(mapid)
    if rec == nil then
        rec = NewWindowRecord(mapid)
        g_windows[#g_windows+1] = rec
        EnsureBuilt(rec)
    end
    if rec.minimized then
        if rec.button ~= nil and rec.button.valid then
            rec.button:PulseClass("justDropped")
        end
    else
        BringToFront(rec)
        Highlight(rec)
    end
    Refresh()
end

--Forces (or releases) the Director's maximized maps on this player's
--table: a map with one of their tokens on it is opened, maximized and
--focused, and cannot be restored, minimized or closed while forced.
local function ApplyForced(forced)
    if dmhub.isDM then
        return
    end
    if type(forced) ~= "table" then
        forced = {}
    end
    for mapid, on in pairs(forced) do
        if on == true and MapExists(mapid) and LocalPlayerHasTokenOn(mapid) then
            local rec = WindowForMap(mapid)
            if rec == nil then
                rec = NewWindowRecord(mapid)
                g_windows[#g_windows+1] = rec
                EnsureBuilt(rec)
            end
            if not rec.forced then
                rec.forced = true
                rec.prevMaximized = rec.maximized == true
                rec.minimized = false
                UpdateTableButton(rec)
                for _, other in ipairs(g_windows) do
                    if other ~= rec and other.maximized and not other.forced then
                        other.maximized = false
                        PlaceWindow(other)
                    end
                end
                rec.maximized = true
                PlaceWindow(rec)
                Focus(rec)
            end
        end
    end
    for _, rec in ipairs(g_windows) do
        if rec.forced and not (forced[rec.mapid] == true and LocalPlayerHasTokenOn(rec.mapid)) then
            rec.forced = false
            rec.maximized = rec.prevMaximized == true
            rec.prevMaximized = nil
            PlaceWindow(rec)
            Refresh()
        end
    end
end

--Shares this player's table has already opened: itemId -> seq.
local g_seenShares = {}
--What SyncShares last acted on, so it only does work when the document changes.
local g_shareSignature = nil
--What SyncViewableMaps tracks. seen: the maps that were Player Viewable for
--this player when their table last looked (mapid -> true), saved with the
--layout so a map made viewable while they were away still opens. seed: a
--table saved before seen was kept takes the current list without opening
--anything. nextCheck: when to look again.
g_sharing.viewable = {seen = {}, seed = false, nextCheck = 0}

g_layoutWriters[#g_layoutWriters+1] = function(out)
    out.seenShares = g_seenShares
    out.viewableMaps = g_sharing.viewable.seen
end

SyncShares = function()
    local doc = ShareDoc()
    local items = SharedItems()

    local forcedIds = {}
    if type(doc.data.forced) == "table" then
        for mapid, on in pairs(doc.data.forced) do
            if on == true then
                forcedIds[#forcedIds+1] = mapid
            end
        end
    end
    table.sort(forcedIds)
    local signature = string.format("%s|%s", tostring(doc.data.seq), table.concat(forcedIds, ","))
    if signature == g_shareSignature then
        return
    end
    g_shareSignature = signature

    if dmhub.isDM then
        Refresh()
        return
    end

    local opened = false
    for itemId, item in pairs(items) do
        local seq = type(item) == "table" and ShareSeqFor(item, dmhub.userid) or 0
        if seq > (tonumber(g_seenShares[itemId]) or 0) then
            g_seenShares[itemId] = seq
            opened = true
            if item.kind == "card" and type(item.charid) == "string" then
                Tabletop.OpenCard(item.charid, {shared = true})
            elseif item.kind == "doc" and type(item.entryid) == "string" then
                Tabletop.OpenDocItem(item.entryid, {shared = true})
            elseif item.kind == "scene" and type(item.sceneid) == "string" then
                Tabletop.OpenScene(item.sceneid, {shared = true})
            end
        end
    end
    ApplyForced(doc.data.forced)
    if opened then
        SaveSoon()
    end
end

--A player's table follows the maps' Player Viewable settings, which the
--Director's share buttons write: a map that becomes viewable for this
--player opens on their table, and one that stops closes, unless one of
--their tokens is on it. Checked four times a second.
g_sharing.SyncViewableMaps = function()
    if dmhub.isDM or dmhub.Time() < g_sharing.viewable.nextCheck then
        return
    end
    g_sharing.viewable.nextCheck = dmhub.Time() + 0.25

    local maps = game.maps
    if #maps == 0 then
        --the game's maps are not in yet; an empty list would close everything.
        return
    end
    local now = {}
    for _, map in ipairs(maps) do
        if map.valid and map.playerViewable then
            now[map.id] = true
        end
    end

    if g_sharing.viewable.seed then
        g_sharing.viewable.seed = false
        g_sharing.viewable.seen = now
        SaveSoon()
        return
    end

    local changed = false
    for mapid in pairs(now) do
        if not g_sharing.viewable.seen[mapid] then
            changed = true
            OpenSharedMap(mapid)
        end
    end
    for mapid in pairs(g_sharing.viewable.seen) do
        if not now[mapid] then
            changed = true
            local rec = WindowForMap(mapid)
            if rec ~= nil and not Tabletop.CanAccessMap(mapid) then
                CloseWindow(rec)
            end
        end
    end
    if changed then
        g_sharing.viewable.seen = now
        SaveSoon()
    end
end

--The forced state also depends on where this player's tokens are, which
--changes without the document changing; re-checked once a second.
local function RecheckForced()
    if not dmhub.isDM then
        ApplyForced(ShareDoc().data.forced)
    end
end

----------------------------------------------------------------------
--NPC cards: characters shown on the table as cards (the Encounter of the
--Week hero card), whether or not they are on a map. Dropping a creature
--from the bestiary or the character list onto the bare table makes one
--(a bestiary creature is created with no map), and so does dragging a
--token out of its map window. Cards sit among the map windows and
--journals, are per user like windows, and the Director can share them.
--
--Hovering a card shows a small see-through titlebar just above it, with the
--Director's share toggle and the close X. Any edge or corner resizes it; the
--hero card is always built at its own size and scaled, so it keeps its shape.
--The Director can drag a card onto the live map window: its placement ghost
--shows there, and the drop teleports the character to that spot.

--{charid, x, y, scale} for each card on this user's table.
local g_cards = {}

local CARD_GAP = 24
local CARD_TITLE_HEIGHT = 22
local CARD_MIN_SCALE = 0.6
local CARD_MAX_SCALE = 3
--the corner resize grips: CARD_GRIP square, CARD_GRIP_OUT of it outside the card.
local CARD_GRIP = 18
local CARD_GRIP_OUT = 8
--the edge resize grips: CARD_EDGE thick, CARD_EDGE_OUT of it outside the card.
--The top grips run along the top of the titlebar, not the card, so the
--titlebar itself is never a resize spot; its corner grips are the smaller
--CARD_TOP_GRIP, CARD_TOP_GRIP_OUT of it outside, to stay off its controls.
local CARD_EDGE = 8
local CARD_EDGE_OUT = 4
local CARD_TOP_GRIP = 12
local CARD_TOP_GRIP_OUT = 8

--The card the Director is dragging: {card, overMap, ghost}. overMap is true
--while its placement ghost shows on the map, where a drop teleports the
--character; ghost is the faded copy left at the card's spot meanwhile, to
--show the card stays on the table.
local g_cardDrag = nil

--The hero card's own size, before a card's scale.
local function CardSize()
    return EotwHeroCard.CARD_WIDTH, EotwHeroCard.CARD_HEIGHT
end

--A table item's own size, before its scale: a card's, or what a document
--item's baseSize says (its shape depends on what it shows). The resize grips
--and ApplyCardScale work on either.
local function ItemSize(item)
    if item.baseSize ~= nil then
        return item.baseSize()
    end
    return CardSize()
end

local function CardById(charid)
    for _, card in ipairs(g_cards) do
        if card.charid == charid then
            return card
        end
    end
    return nil
end

--The card's own styles: the hero card's rules, after a reset of the
--journal layer's selector-less centring (see g_overlayStyles).
local function CardStyles()
    local styles = {
        {
            valign = "top",
            halign = "left",
            width = 100,
            height = 100,
        },
        --the titlebar and every part of it, shown while the card is hovered
        --(opacity doesn't reach children, so each part carries the class).
        {
            selectors = {"tabletopCardChrome"},
            opacity = 0,
            transitionTime = 0.15,
        },
        {
            selectors = {"tabletopCardChrome", "shown"},
            opacity = 1,
            transitionTime = 0.1,
        },
        {
            selectors = {"tabletopCardTitle"},
            bgcolor = "#1d1915a0",
        },
        --over the map, the card steps aside for its placement ghost. Scale,
        --not opacity, because opacity doesn't reach children.
        {
            selectors = {"tabletopCard", "tabletopCardOverMap"},
            scale = 0.01,
        },
        --the faded copy left in the card's place meanwhile. Opacity is per
        --panel, so the class goes on every part of the copy (SetClassTree);
        --it fades label text too.
        {
            selectors = {"tabletopCardGhost"},
            opacity = 0.4,
            saturation = 0.5,
        },
    }
    for _, rule in ipairs(ThemeEngine.MergeTokens(EotwHeroCard.rules) or {}) do
        styles[#styles+1] = rule
    end
    return styles
end

--Screen pixels (top-left origin, as the engine's drop events report them)
--to the documents layer's units.
local function ScreenToLayer(px, py)
    local layer = DocumentsLayer()
    local screen = dmhub.screenDimensions
    local below = dmhub.screenDimensionsBelowTitlebar
    if layer == nil or below.y <= 0 then
        return px, py
    end
    local scale = layer.renderedHeight / below.y
    return px * scale, (py - (screen.y - below.y)) * scale
end

local function IsHeroToken(tok)
    local hero = false
    pcall(function()
        hero = tok.properties:IsHero() == true
    end)
    return hero
end

--The hero card face for a character, at its own size. options are passed
--on to CreateHeroCard (dismiss, ...).
local function CardFace(charid, tok)
    return EotwHeroCard.CreateHeroCard({charid = charid, mine = false, name = tok.name}, {
        halign = "left",
        showResources = false,
        noRecoveries = not IsHeroToken(tok),
        --the press reaches the card's frame, which is what drags (and
        --swallows the press for the map); a click still opens the sheet.
        passPress = true,
        useClick = true,
        --a monster from the bestiary has no name of its own.
        displayName = function(t)
            return creature.GetTokenDescription(t)
        end,
        --where the creature is: a card can stand for a token on a map.
        subtitle = function(t)
            local mapid = t.mapid
            if mapid == nil or mapid == "" then
                return "Not on a map"
            end
            return MapName(mapid)
        end,
    })
end

local CloseCard

--Puts a card's resize grip on its edge or corner of the card's current size,
--and stretches an edge grip along the edge between the corner grips. The
--top grips sit on the top of the titlebar (just above the card), and the
--side grips run up beside the titlebar to meet them.
local function PlaceGrip(card, grip)
    local w, h = ItemSize(card)
    local s = card.scale or 1
    local W = math.floor(w * s)
    local H = math.floor(h * s)
    local hx = grip.data.hx
    local hy = grip.data.hy
    local inset = CARD_GRIP - CARD_GRIP_OUT
    local topInset = CARD_TOP_GRIP - CARD_TOP_GRIP_OUT
    local top = -CARD_TITLE_HEIGHT
    local corner = hx ~= 0 and hy ~= 0

    local x, width
    if hx == 0 then
        local edgeInset = cond(hy < 0, topInset, inset)
        x = edgeInset
        width = math.max(1, W - 2 * edgeInset)
    elseif corner and hy < 0 then
        x = cond(hx < 0, -CARD_TOP_GRIP_OUT, W - topInset)
        width = CARD_TOP_GRIP
    elseif corner then
        x = cond(hx < 0, -CARD_GRIP_OUT, W - inset)
        width = CARD_GRIP
    else
        x = cond(hx < 0, -CARD_EDGE_OUT, W - (CARD_EDGE - CARD_EDGE_OUT))
        width = CARD_EDGE
    end

    local y, height
    if hy == 0 then
        y = top + topInset
        height = math.max(1, H - inset - y)
    elseif hy < 0 then
        if corner then
            y = top - CARD_TOP_GRIP_OUT
            height = CARD_TOP_GRIP
        else
            y = top - CARD_EDGE_OUT
            height = CARD_EDGE
        end
    elseif corner then
        y = H - inset
        height = CARD_GRIP
    else
        y = H - (CARD_EDGE - CARD_EDGE_OUT)
        height = CARD_EDGE
    end

    grip.selfStyle.width = width
    grip.selfStyle.height = height
    grip.data.homeX = x
    grip.data.homeY = y
    grip.x = x
    grip.y = y
end

--Sizes a built card to its scale. except: a grip being dragged, which is
--left where the drag has it until the drag ends.
local function ApplyCardScale(card, except)
    local panel = card.panel
    if panel == nil or not panel.valid then
        return
    end
    local w, h = ItemSize(card)
    local s = card.scale or 1
    panel.selfStyle.width = math.floor(w * s)
    panel.selfStyle.height = math.floor(h * s)
    card.scaler.selfStyle.scale = s
    for _, grip in ipairs(card.grips) do
        if grip ~= except then
            PlaceGrip(card, grip)
        end
    end
end

local function MirrorDiagonalCursor()
    for _, id in ipairs(dmhub.cursorIds or {}) do
        if id == "diagonal-expand-mirror" then
            return id
        end
    end
    return "diagonal-expand"
end

--A grip on one edge or corner that resizes the card, keeping its shape.
--hx/hy say where it sits: -1 left/top, 1 right/bottom, 0 along the middle
--of that axis. The opposite edge stays put; an edge grip keeps the card's
--top or left where it is. A corner drag is projected onto the diagonal.
local function CardGrip(card, hx, hy)
    local cursor
    if hx == 0 then
        cursor = "vertical-expand"
    elseif hy == 0 then
        cursor = "horizontal-expand"
    elseif hx == hy then
        cursor = "diagonal-expand"
    else
        cursor = MirrorDiagonalCursor()
    end
    --whether a grip is hovered or dragged. The titlebar shows while the card
    --or a grip is hovered: hover events for the two can come in either order
    --as the mouse crosses a grip into the card, so each keeps its own flag.
    local function SetGripHover(on)
        card.gripHovered = on
        local titlebar = card.titlebar
        if titlebar ~= nil and titlebar.valid then
            titlebar:SetClassTree("shown", on or card.cardHovered == true)
        end
    end
    return gui.Panel{
        styles = {
            {
                width = CARD_GRIP,
                height = CARD_GRIP,
                halign = "left",
                valign = "top",
            },
        },
        floating = true,
        swallowPress = true,
        bgimage = true,
        bgcolor = "clear",
        hoverCursor = cursor,
        draggable = true,
        data = {
            hx = hx,
            hy = hy,
            homeX = 0,
            homeY = 0,
        },
        --a grip swallows the press, so hovering it does not hover the card;
        --it keeps the card's titlebar shown itself (the top grips sit on it).
        hover = function(element)
            SetGripHover(true)
        end,
        dehover = function(element)
            if not element.data.dragging then
                SetGripHover(false)
            end
        end,
        beginDrag = function(element)
            local w, h = ItemSize(card)
            local s = card.scale or 1
            card.panel:SetAsLastSibling()
            --the card's origin is fixed for the right edge and the bottom, so
            --size = drag position + this offset there.
            element.data.grabX = w * s - element.data.homeX
            element.data.grabY = h * s - element.data.homeY
            element.data.dragging = true
        end,
        dragging = function(element)
            local panel = card.panel
            if panel == nil or not panel.valid or not element.data.dragging then
                return
            end
            local w, h = ItemSize(card)
            local curW = w * (card.scale or 1)
            local curH = h * (card.scale or 1)
            --left and top are measured in the card's own frame, which this
            --drag moves, so the shift settles back to zero as the card follows.
            local wantW, wantH
            if hx > 0 then
                wantW = element.xdrag + element.data.grabX
            elseif hx < 0 then
                wantW = curW - (element.xdrag - element.data.homeX)
            end
            if hy > 0 then
                wantH = element.ydrag + element.data.grabY
            elseif hy < 0 then
                wantH = curH - (element.ydrag - element.data.homeY)
            end
            local s
            if wantW ~= nil and wantH ~= nil then
                s = (wantW * w + wantH * h) / (w * w + h * h)
            elseif wantW ~= nil then
                s = wantW / w
            else
                s = wantH / h
            end
            --growing left or up stops at the table's edge (and leaves room
            --for the titlebar), as moving the card does.
            if hx < 0 then
                s = math.min(s, (card.x + curW) / w)
            end
            if hy < 0 then
                s = math.min(s, (card.y + curH - CARD_TITLE_HEIGHT) / h)
            end
            s = math.max(CARD_MIN_SCALE, math.min(CARD_MAX_SCALE, s))
            if hx < 0 then
                card.x = card.x + (curW - w * s)
                panel.x = card.x
            end
            if hy < 0 then
                card.y = card.y + (curH - h * s)
                panel.y = card.y
            end
            card.scale = s
            ApplyCardScale(card, element)
        end,
        drag = function(element)
            element.data.dragging = false
            PlaceGrip(card, element)
            SetGripHover(false)
            SaveSoon()
        end,
    }
end

--Every resize grip for a card or document item: the edges first, so the
--corners sit above where they meet.
local function CardGrips(card)
    return {
        CardGrip(card, 0, -1),
        CardGrip(card, 0, 1),
        CardGrip(card, -1, 0),
        CardGrip(card, 1, 0),
        CardGrip(card, -1, -1),
        CardGrip(card, 1, -1),
        CardGrip(card, -1, 1),
        CardGrip(card, 1, 1),
    }
end

--Shows or hides the faded copy of a dragged card at the card's spot on the
--table, building it the first time the drag reaches the map. It is a plain
--copy of the face: no titlebar or grips, and it takes no input.
local function ShowCardGhost(drag, show)
    local ghost = drag.ghost
    if ghost == nil or not ghost.valid then
        if not show then
            return
        end
        local card = drag.card
        local layer = DocumentsLayer()
        local tok = dmhub.GetCharacterById(card.charid)
        if layer == nil or tok == nil or card.panel == nil or not card.panel.valid then
            return
        end
        local w, h = CardSize()
        ghost = gui.Panel{
            classes = {"tabletopCardGhost"},
            styles = CardStyles(),
            halign = "left",
            valign = "top",
            x = card.x,
            y = card.y,
            width = math.floor(w * card.scale),
            height = math.floor(h * card.scale),
            flow = "none",
            interactable = false,
            create = function(element)
                element:FireEventTree("refreshCard")
                element:SetClassTree("tabletopCardGhost", true)
            end,
            gui.Panel{
                halign = "center",
                valign = "center",
                width = w,
                height = h,
                scale = card.scale,
                CardFace(card.charid, tok),
            },
        }
        layer:AddChild(ghost)
        --the dragged card stays above its copy.
        card.panel:SetAsLastSibling()
        drag.ghost = ghost
    end
    ghost:SetClass("collapsed", not show)
end

local function DestroyCardGhost(drag)
    if drag.ghost ~= nil and drag.ghost.valid then
        drag.ghost:DestroySelf()
    end
    drag.ghost = nil
end

--Ends the Director's card drag. Placement mode (the card's focus) holds
--until the engine has handled the release this frame.
local function EndCardDrag(drag, panel)
    DestroyCardGhost(drag)
    dmhub.Schedule(0.2, function()
        if g_cardDrag == drag then
            g_cardDrag = nil
        end
        if panel.valid and gui.GetFocus() == panel then
            gui.SetFocus(nil)
        end
    end)
end

local function BuildCard(card)
    local layer = DocumentsLayer()
    local tok = dmhub.GetCharacterById(card.charid)
    if layer == nil or tok == nil then
        return
    end
    local w, h = CardSize()
    card.scale = card.scale or 1

    card.scaler = gui.Panel{
        halign = "center",
        valign = "center",
        width = w,
        height = h,
        scale = card.scale,
        CardFace(card.charid, tok),
    }

    local controls = {}
    local share = nil
    if dmhub.isDM then
        share = ShareControl{
            itemId = CardItemId(card.charid),
            newItem = function()
                return {kind = "card", charid = card.charid}
            end,
            what = "this card",
            iconSize = 12,
            width = 26,
            passPress = true,
            cornerRadius = 8,
        }
        controls[#controls+1] = share.button
    end
    controls[#controls+1] = WindowControl{
        danger = true,
        icon = "window-chrome/chrome-close.png",
        iconSize = 12,
        width = 26,
        passPress = true,
        hover = gui.Tooltip("Take off the table"),
        click = function(element)
            CloseCard(card)
        end,
    }

    --the GameHud cascade carries no theme, so the titlebar brings it, as a
    --map window's does.
    local titlebar = gui.Panel{
        styles = ThemeEngine.MergeStyles(g_titleStyles),
        classes = {"tabletopCardTitle", "tabletopCardChrome"},
        floating = true,
        halign = "left",
        valign = "top",
        y = -CARD_TITLE_HEIGHT,
        width = "100%",
        height = CARD_TITLE_HEIGHT,
        bgimage = "panels/square.png",
        cornerRadius = 6,
        flow = "horizontal",
        --the share light follows the shared document.
        thinkTime = 1,
        think = function(element)
            UpdateShare(share)
        end,
        gui.Panel{
            flow = "horizontal",
            width = "auto",
            height = "100%",
            halign = "right",
            children = controls,
        },
    }
    titlebar:SetClassTree("tabletopCardChrome", true)

    card.titlebar = titlebar
    card.grips = CardGrips(card)

    local children = {card.scaler, titlebar}
    if share ~= nil then
        children[#children+1] = share.frame
    end
    for _, grip in ipairs(card.grips) do
        children[#children+1] = grip
    end

    local panel = gui.Panel{
        classes = {"tabletopCard"},
        styles = CardStyles(),
        halign = "left",
        valign = "top",
        x = card.x,
        y = card.y,
        width = math.floor(w * card.scale),
        height = math.floor(h * card.scale),
        flow = "none",
        draggable = true,
        swallowPress = true,
        --placement mode reads the focused panel's charid (CharacterPanel's
        --dmhub.GetSelectedCharacters) while the Director drags the card.
        data = {
            charid = card.charid,
            tabletopCard = true,
        },
        --click-to-front from a press anywhere on it (engine walk).
        raiseOnPress = true,
        --a hovered grip keeps the titlebar up too (see CardGrip).
        hover = function(element)
            card.cardHovered = true
            titlebar:SetClassTree("shown", true)
        end,
        dehover = function(element)
            card.cardHovered = false
            titlebar:SetClassTree("shown", card.gripHovered == true)
        end,
        beginDrag = function(element)
            if dmhub.isDM then
                g_cardDrag = {card = card, overMap = false}
                gui.SetFocus(element)
            end
        end,
        dragging = function(element)
            ChatItemLinks.Dragging(function() return {ChatItemLinks.CharacterItem(card.charid)} end)
            if g_cardDrag == nil or g_cardDrag.card ~= card then
                return
            end
            dmhub.SetDraggingMonster()
            local overMap = dmhub.tabletopDragSurface == "map"
            if overMap ~= g_cardDrag.overMap then
                g_cardDrag.overMap = overMap
                element:SetClass("tabletopCardOverMap", overMap)
                ShowCardGhost(g_cardDrag, overMap)
            end
        end,
        drag = function(element)
            --dropped on the chat: a link to the character; the card stays.
            local toChat = ChatItemLinks.Dropped()
            local drag = g_cardDrag
            if drag ~= nil and drag.card == card then
                element:SetClass("tabletopCardOverMap", false)
                EndCardDrag(drag, element)
                if drag.overMap or toChat then
                    --dropped on the map: the engine teleports the character
                    --there, and the card stays where it was.
                    element.x = card.x
                    element.y = card.y
                    return
                end
            end
            if toChat then
                element.x = card.x
                element.y = card.y
                return
            end
            local lw, lh = LayerSize()
            card.x = math.max(0, math.min(element.xdrag, lw - 60))
            card.y = math.max(CARD_TITLE_HEIGHT, math.min(element.ydrag, lh - 60))
            element.x = card.x
            element.y = card.y
            element:SetAsLastSibling()
            SaveSoon()
        end,
        --the card's portrait, stamina and conditions repaint on this cadence.
        thinkTime = 0.5,
        think = function(element)
            if dmhub.GetCharacterById(card.charid) == nil then
                --the character was deleted: its card goes too.
                CloseCard(card)
                return
            end
            element:FireEventTree("refreshCard")
        end,
        create = function(element)
            element:FireEventTree("refreshCard")
        end,
        children = children,
    }
    layer:AddChild(panel)
    card.panel = panel
    for _, grip in ipairs(card.grips) do
        PlaceGrip(card, grip)
    end
end

--Puts a character's card on this user's table (or brings its card
--forward). options.x/y place the card (documents-layer units), moving it if
--it is already on the table;
--options.shared marks a card that arrived from the Director's share.
function Tabletop.OpenCard(charid, options)
    options = options or {}
    if not Tabletop.IsActive() or dmhub.GetCharacterById(charid) == nil then
        return
    end
    local w, h = LayerSize()
    local card = CardById(charid)
    if card == nil then
        local cw, ch = CardSize()
        card = {
            charid = charid,
            x = options.x or math.floor((w - cw) / 2),
            y = options.y or math.floor((h - ch) / 2),
            scale = 1,
        }
        g_cards[#g_cards+1] = card
    elseif options.x ~= nil and options.y ~= nil then
        --dropped on the table again: the card moves to the drop, keeping its size.
        card.x = options.x
        card.y = options.y
    end
    card.x = math.max(0, math.min(card.x, w - 140))
    card.y = math.max(CARD_TITLE_HEIGHT, math.min(card.y, h - 200))
    if card.panel == nil or not card.panel.valid then
        BuildCard(card)
    else
        card.panel.x = card.x
        card.panel.y = card.y
    end
    if card.panel ~= nil and card.panel.valid then
        card.panel:SetAsLastSibling()
        card.panel:PulseClass("tabletopHighlight")
    end
    SaveSoon()
end

CloseCard = function(card)
    if g_cardDrag ~= nil and g_cardDrag.card == card then
        DestroyCardGhost(g_cardDrag)
    end
    if card.panel ~= nil and card.panel.valid then
        card.panel:DestroySelf()
    end
    card.panel = nil
    for i, other in ipairs(g_cards) do
        if other == card then
            table.remove(g_cards, i)
            break
        end
    end
    SaveSoon()
end

TeardownCards = function()
    if g_cardDrag ~= nil then
        DestroyCardGhost(g_cardDrag)
    end
    for _, card in ipairs(g_cards) do
        if card.panel ~= nil and card.panel.valid then
            card.panel:DestroySelf()
        end
        card.panel = nil
    end
end

SyncCards = function()
    for _, card in ipairs(g_cards) do
        if card.panel == nil or not card.panel.valid then
            BuildCard(card)
        end
    end
end

g_layoutWriters[#g_layoutWriters+1] = function(out)
    local cards = {}
    for _, card in ipairs(g_cards) do
        cards[#cards+1] = {charid = card.charid, x = card.x, y = card.y, scale = card.scale}
    end
    out.cards = cards
end

local function LoadCards(layout)
    g_cards = {}
    if layout == nil or type(layout.cards) ~= "table" then
        return
    end
    for _, saved in ipairs(layout.cards) do
        if type(saved) == "table" and type(saved.charid) == "string" and dmhub.GetCharacterById(saved.charid) ~= nil and CardById(saved.charid) == nil then
            g_cards[#g_cards+1] = {
                charid = saved.charid,
                x = tonumber(saved.x) or 100,
                y = tonumber(saved.y) or 100,
                scale = math.max(CARD_MIN_SCALE, math.min(CARD_MAX_SCALE, tonumber(saved.scale) or 1)),
            }
        end
    end
end

--Where the cards for a drop at the mouse go: the first centred on the
--mouse, the rest stepping down-right (documents-layer units).
local function DropPlacement(screenx, screeny, i)
    local x, y = ScreenToLayer(screenx, screeny)
    local w, h = CardSize()
    return math.floor(x - w / 2) + (i - 1) * CARD_GAP, math.floor(y - h / 2) + (i - 1) * CARD_GAP
end

----------------------------------------------------------------------
--A character or bestiary row dragged out of its panel (CharacterPanel.lua
--calls these from the row's drag events). Over the bare table it shows as
--the cards a drop there makes; over the live map window only the engine's
--placement ghost shows. The row itself shrinks away in both cases (scale,
--since opacity doesn't reach children), and is back over any panel.

--{row, previews = {panel...}, rowHidden, seen}
local g_rowDrag = nil

local MAX_PREVIEW_CARDS = 4

--options.think/thinkTime: a think for the preview (it keeps thinking while
--non-interactive).
local function BuildPreviewCard(charid, options)
    options = options or {}
    local layer = DocumentsLayer()
    local tok = dmhub.GetCharacterById(charid)
    if layer == nil or tok == nil then
        return nil
    end
    local w, h = CardSize()
    local panel = gui.Panel{
        styles = CardStyles(),
        halign = "left",
        valign = "top",
        width = w,
        height = h,
        flow = "none",
        thinkTime = options.thinkTime,
        think = options.think,
        CardFace(charid, tok),
    }
    layer:AddChild(panel)
    panel:FireEventTree("refreshCard")
    --it rides under the mouse, so it must not count as a panel there (the
    --engine's table-drop test) or take the drop.
    panel:MakeNonInteractiveRecursive()
    return panel
end

function Tabletop.CharacterRowDragEnded(row)
    local drag = g_rowDrag
    if drag == nil or (row ~= nil and drag.row ~= row) then
        return
    end
    g_rowDrag = nil
    if drag.rowHidden and drag.row.valid then
        drag.row.selfStyle.scale = 1
    end
    for _, preview in ipairs(drag.previews) do
        if preview.valid then
            preview:DestroySelf()
        end
    end
end

--The card face for a bestiary creature, which is not a character until a
--drop creates it: the hero card's frame with its portrait, name and the
--"Not on a map" line the card it becomes will show. tok is the bestiary
--entry's token (assets.monsters[id].info).
local function BestiaryCardFace(tok)
    local w, h = CardSize()
    local name = ""
    pcall(function() name = creature.GetTokenDescription(tok) end)
    local face = gui.Panel{
        classes = {"eotwHeroCard"},
        width = w,
        height = h,
        halign = "left",
        cornerRadius = 8,
        bgimage = "panels/square.png",
        gui.Panel{
            classes = {"eotwCardOverlay"},
            floating = true,
            halign = "center",
            valign = "bottom",
            width = "100%",
            height = "auto",
            flow = "vertical",
            bgimage = "panels/square.png",
            cornerRadius = 8,
            hpad = 6,
            vpad = 4,
            borderBox = true,
            gui.Label{
                classes = {"eotwHeroName"},
                text = name,
            },
            gui.Label{
                classes = {"eotwHeroPlayer"},
                text = "Not on a map",
            },
        },
    }
    EotwHeroCard.ApplyPortrait(face, tok, w / h)
    return face
end

local function BuildBestiaryPreviewCard(monsterid)
    local layer = DocumentsLayer()
    local monster = assets.monsters[monsterid]
    if layer == nil or monster == nil then
        return nil
    end
    local w, h = CardSize()
    local panel = gui.Panel{
        styles = CardStyles(),
        halign = "left",
        valign = "top",
        width = w,
        height = h,
        flow = "none",
        BestiaryCardFace(monster.info),
    }
    layer:AddChild(panel)
    panel:MakeNonInteractiveRecursive()
    return panel
end

--The shared body of a row drag: count is how many cards a drop makes, and
--buildPreview(i) builds the preview of the i-th.
local function RowDragging(row, count, buildPreview)
    if not Tabletop.IsActive() then
        return
    end
    if g_rowDrag ~= nil and g_rowDrag.row ~= row then
        Tabletop.CharacterRowDragEnded(nil)
    end
    if g_rowDrag == nil then
        g_rowDrag = {row = row, previews = {}, rowHidden = false}
    end
    local drag = g_rowDrag
    drag.seen = dmhub.Time()

    local surface = dmhub.tabletopDragSurface
    local hideRow = surface ~= nil
    if hideRow ~= drag.rowHidden then
        drag.rowHidden = hideRow
        row.selfStyle.scale = cond(hideRow, 0.01, 1)
    end

    local onTable = surface == "table"
    if onTable and #drag.previews == 0 then
        for i = 1, math.min(count, MAX_PREVIEW_CARDS) do
            drag.previews[#drag.previews+1] = buildPreview(i)
        end
    end

    local mouse = nil
    if onTable then
        mouse = dmhub.mouseScreenPosition
    end
    for i, preview in ipairs(drag.previews) do
        if preview.valid then
            preview:SetClass("collapsed", not onTable)
            if mouse ~= nil then
                preview.x, preview.y = DropPlacement(mouse.x, mouse.y, i)
                preview:SetAsLastSibling()
            end
        end
    end
end

function Tabletop.CharacterRowDragging(row, charids)
    RowDragging(row, #charids, function(i)
        return BuildPreviewCard(charids[i])
    end)
end

--A bestiary row (CharacterPanel.lua): the same, with one preview per
--creature the drop creates (quantity: 4 for a minion squad).
function Tabletop.BestiaryRowDragging(row, monsterid, quantity)
    RowDragging(row, quantity, function(i)
        return BuildBestiaryPreviewCard(monsterid)
    end)
end

Tabletop.BestiaryRowDragEnded = Tabletop.CharacterRowDragEnded

----------------------------------------------------------------------
--A token dragged out of its map window. Over the bare table the engine
--hides the move preview and lists the dragged tokens in
--dmhub.tabletopTokenDrag; faded copies of the cards a drop makes follow the
--mouse, where the drop puts them (tabletopTokenDropped, DropPlacement).

--{key, previews = {panel...}}: key is the dragged charids, joined.
local g_tokenDrag = nil

local function EndTokenDragPreview()
    local drag = g_tokenDrag
    if drag == nil then
        return
    end
    g_tokenDrag = nil
    for _, preview in ipairs(drag.previews) do
        if preview.valid then
            preview:DestroySelf()
        end
    end
end

--Starts, moves or ends the previews to match the engine's drag. Sync calls
--it to notice a drag start; the first preview's think then calls it every
--frame, since Sync's cadence would trail the mouse.
local UpdateTokenDragPreview

UpdateTokenDragPreview = function()
    local charids = dmhub.tabletopTokenDrag
    if charids == nil or not Tabletop.IsActive() then
        EndTokenDragPreview()
        return
    end
    local key = table.concat(charids, ",")
    if g_tokenDrag ~= nil and g_tokenDrag.key ~= key then
        EndTokenDragPreview()
    end
    if g_tokenDrag == nil then
        g_tokenDrag = {key = key, previews = {}}
        for i, charid in ipairs(charids) do
            if i > MAX_PREVIEW_CARDS then
                break
            end
            local options = {}
            if i == 1 then
                options = {
                    thinkTime = 0.01,
                    think = function(element)
                        UpdateTokenDragPreview()
                    end,
                }
            end
            local preview = BuildPreviewCard(charid, options)
            if preview ~= nil then
                preview:SetClassTree("tabletopCardGhost", true)
                g_tokenDrag.previews[#g_tokenDrag.previews+1] = preview
            end
        end
    end

    local mouse = dmhub.mouseScreenPosition
    for i, preview in ipairs(g_tokenDrag.previews) do
        if preview.valid then
            preview.x, preview.y = DropPlacement(mouse.x, mouse.y, i)
            preview:SetAsLastSibling()
        end
    end
end

----------------------------------------------------------------------
--A map row dragged out of the Maps panel (MapsPanel.lua calls these from
--the row's drag events). Over the bare table the row steps aside and the
--window a drop makes follows the mouse; the drop opens the map in a new
--window there, or moves the map's window there if it already has one.

--{row, mapid, preview, rowHidden, seen}
local g_mapRowDrag = nil

--The window a map dropped at the mouse gets: its own window's size (or a
--new window's), centred on the mouse and kept wholly on the table when it
--fits. Documents-layer units.
local function MapDropRect(mapid)
    local rec = WindowForMap(mapid)
    local width, height
    if rec ~= nil and not rec.maximized then
        width, height = rec.width, rec.height
    else
        local _, _, w, h = DefaultPlacement()
        width, height = w, h
    end
    local mouse = dmhub.mouseScreenPosition
    local mx, my = ScreenToLayer(mouse.x, mouse.y)
    local tw, th = LayerSize()
    local x = math.floor(mx - width / 2)
    local y = math.floor(my - height / 2)
    x = math.max(0, math.min(x, tw - width))
    y = math.max(0, math.min(y, th - height))
    return x, y, width, height
end

--What the drop will make: a window frame with the map's name and its
--snapshot (or loading-screen art). Built non-interactive, since it rides
--under the mouse and must not count as a panel there.
local function BuildMapDropPreview(mapid, width, height)
    local layer = DocumentsLayer()
    if layer == nil then
        return nil
    end
    local image, placeholder = FrozenImage({mapid = mapid})
    local panel = gui.Panel{
        flow = "vertical",
        halign = "left",
        valign = "top",
        width = width,
        height = height,
        bgimage = "panels/square.png",
        bgcolor = "#100d0bff",
        borderWidth = 2,
        borderColor = "#b8925acc",
        gui.Panel{
            flow = "horizontal",
            width = "100%",
            height = TITLE_HEIGHT,
            bgimage = "panels/square.png",
            bgcolor = "#1d1915ff",
            gui.Label{
                width = "auto",
                height = "100%",
                halign = "left",
                valign = "center",
                hmargin = 8,
                textWrap = false,
                color = "#d9d1c4",
                fontSize = 14,
                text = MapName(mapid),
            },
        },
        gui.Panel{
            width = "100%",
            height = "100% available",
            bgimage = image,
            bgcolor = cond(placeholder, "#1b1814ff", "#8a8a8aff"),
            saturation = cond(placeholder, 1, 0.12),
        },
    }
    layer:AddChild(panel)
    panel:MakeNonInteractiveRecursive()
    return panel
end

function Tabletop.MapRowDragEnded(row)
    local drag = g_mapRowDrag
    if drag == nil or (row ~= nil and drag.row ~= row) then
        return
    end
    g_mapRowDrag = nil
    if drag.rowHidden and drag.row.valid then
        drag.row.selfStyle.scale = 1
    end
    if drag.preview ~= nil and drag.preview.valid then
        drag.preview:DestroySelf()
    end
end

function Tabletop.MapRowDragging(row, mapid)
    if not Tabletop.IsActive() then
        return
    end
    if g_mapRowDrag ~= nil and g_mapRowDrag.row ~= row then
        Tabletop.MapRowDragEnded(nil)
    end
    if g_mapRowDrag == nil then
        g_mapRowDrag = {row = row, mapid = mapid, rowHidden = false}
    end
    local drag = g_mapRowDrag
    drag.seen = dmhub.Time()

    local onTable = dmhub.panelDropSurface == "table"
    if onTable ~= drag.rowHidden then
        drag.rowHidden = onTable
        row.selfStyle.scale = cond(onTable, 0.01, 1)
    end

    if not onTable then
        if drag.preview ~= nil and drag.preview.valid then
            drag.preview:SetClass("collapsed", true)
        end
        return
    end

    local x, y, width, height = MapDropRect(mapid)
    if drag.preview == nil or not drag.preview.valid then
        drag.preview = BuildMapDropPreview(mapid, width, height)
    end
    local preview = drag.preview
    if preview ~= nil and preview.valid then
        preview:SetClass("collapsed", false)
        preview.x = x
        preview.y = y
        preview:SetAsLastSibling()
    end
end

--A map row released with no drop target under it. On the bare table the
--map opens in a new window under the mouse, or its window moves there.
--Anywhere else it does nothing. Returns true if the drop was taken.
function Tabletop.MapRowDropped(mapid)
    if not Tabletop.IsActive() or dmhub.panelDropSurface ~= "table" then
        return false
    end
    local map = game.GetMap(mapid)
    if map == nil or not map.valid then
        return false
    end

    local x, y = MapDropRect(mapid)
    local rec = WindowForMap(mapid)
    if rec ~= nil then
        --a maximized window stays maximized: the drop just brings it up.
        if not rec.maximized and not IsForcedHere(rec) then
            rec.x, rec.y = x, y
            if not rec.minimized then
                PlaceWindow(rec)
            end
        end
        --Focus restores a minimized window, growing it out to its new spot.
        Focus(rec)
        Highlight(rec)
        SaveSoon()
        return true
    end

    rec = NewWindowRecord(mapid)
    rec.x, rec.y = x, y
    g_windows[#g_windows+1] = rec
    EnsureBuilt(rec)
    Focus(rec)
    SaveSoon()
    return true
end

--A drag can end without the row hearing of it (the row rebuilt mid-drag):
--the previews go once its drag events stop.
local function CheckRowDragEnded()
    if g_rowDrag ~= nil and dmhub.Time() - (g_rowDrag.seen or 0) > 0.3 then
        Tabletop.CharacterRowDragEnded(nil)
    end
    if g_mapRowDrag ~= nil and dmhub.Time() - (g_mapRowDrag.seen or 0) > 0.3 then
        Tabletop.MapRowDragEnded(nil)
    end
end

--A creature dragged from the bestiary or the character list and dropped on
--the bare table (outside any map window; the engine reports it). Existing
--characters get a card; bestiary creatures are created with no map first.
dmhub.RegisterEventHandler("tabletopCreatureDropped", function(info)
    if mod.unloaded or not Tabletop.IsActive() or type(info) ~= "table" then
        return
    end
    local screenx = tonumber(info.screenx) or 0
    local screeny = tonumber(info.screeny) or 0
    if type(info.charids) == "table" then
        for i, charid in ipairs(info.charids) do
            --a card the Director dragged back onto the table has moved
            --itself (its drag puts the engine in placement mode).
            if g_cardDrag == nil or g_cardDrag.card.charid ~= charid then
                local x, y = DropPlacement(screenx, screeny, i)
                Tabletop.OpenCard(charid, {x = x, y = y})
            end
        end
    elseif dmhub.isDM then
        local monsterids = info.monsterids
        if type(monsterids) ~= "table" then
            monsterids = {info.monsterid}
        end
        for i, monsterid in ipairs(monsterids) do
            local tok = game.SpawnTokenFromBestiaryLocally(monsterid, nil)
            if tok ~= nil then
                tok:UploadToken()
                local charid = tok.charid
                local cx, cy = DropPlacement(screenx, screeny, i)
                --the new character arrives in the game's character list a
                --moment after the upload.
                dmhub.Coroutine(function()
                    for _ = 1, 100 do
                        if mod.unloaded then
                            return
                        end
                        if dmhub.GetCharacterById(charid) ~= nil then
                            Tabletop.OpenCard(charid, {x = cx, y = cy})
                            return
                        end
                        coroutine.yield(0.05)
                    end
                end)
            end
        end
        game.UpdateCharacterTokens()
    end
    --the dragged row stays the focus, which would keep its placement ghost
    --following the mouse back into a map window.
    gui.SetFocus(nil)
end)

--A token dragged out of its map window and released on the table: the
--move is cancelled (engine side) and the token gets a card.
dmhub.RegisterEventHandler("tabletopTokenDropped", function(info)
    if mod.unloaded or not Tabletop.IsActive() or type(info) ~= "table" then
        return
    end
    local screenx = tonumber(info.screenx) or 0
    local screeny = tonumber(info.screeny) or 0
    local charids = info.charids
    if type(charids) ~= "table" then
        charids = {info.charid}
    end
    for i, charid in ipairs(charids) do
        local x, y = DropPlacement(screenx, screeny, i)
        Tabletop.OpenCard(charid, {x = x, y = y})
    end
end)

----------------------------------------------------------------------
--Journal entries on the table. Dragging a journal row (a document, PDF,
--image or PDF bookmark) out of the journal onto the bare table puts the
--entry there as an item: a document shows as a tile with its icon and name,
--a PDF as its cover, an image or bookmark as itself. A click opens it as the
--journal would. Items move, resize and share like NPC cards (the same hover
--titlebar and edge and corner grips), and are per user like the rest of the table.
--A shared item opens for players even when the entry is not in their
--journal: the Director sharing it is what shows it to them.
--(Journal.lua's row drag calls Tabletop.JournalRowDragging and
--JournalEntryDropped; a drop on the map makes an info bubble instead.)
do
    --{entryid, x, y, scale} for each item on this user's table, plus its
    --built parts (panel, scaler, face, grips) and baseSize.
    local g_docItems = {}

    local DOC_TILE_WIDTH = 240
    local DOC_TILE_HEIGHT = 76
    local DOC_PICTURE_WIDTH = 200
    local DOC_PICTURE_INSET = 2

    local function DocItemId(entryid)
        return "doc:" .. entryid
    end

    local function DocItemById(entryid)
        for _, item in ipairs(g_docItems) do
            if item.entryid == entryid then
                return item
            end
        end
        return nil
    end

    --(LinkResolution.lua; looked up per call, as it may load after this file.)
    local function EntryIcon(entry)
        return CustomDocument.JournalEntryIcon(entry)
    end

    local function EntryPicture(entry)
        return CustomDocument.JournalEntryPicture(entry)
    end

    --The item's own size, before its scale: a fixed tile for a document; a
    --picture's width with its shape kept (within reason) inside a thin frame.
    local function DocBaseSize(entry)
        local _, aspect = EntryPicture(entry)
        if aspect == nil then
            return DOC_TILE_WIDTH, DOC_TILE_HEIGHT
        end
        aspect = math.max(0.4, math.min(1.6, aspect))
        local inner = DOC_PICTURE_WIDTH - DOC_PICTURE_INSET * 2
        return DOC_PICTURE_WIDTH, math.floor(inner * aspect) + DOC_PICTURE_INSET * 2
    end

    local function DocStyles()
        return {
            {
                valign = "top",
                halign = "left",
                width = 100,
                height = 100,
            },
            --the hover titlebar, as on NPC cards.
            {
                selectors = {"tabletopCardChrome"},
                opacity = 0,
                transitionTime = 0.15,
            },
            {
                selectors = {"tabletopCardChrome", "shown"},
                opacity = 1,
                transitionTime = 0.1,
            },
            {
                selectors = {"tabletopCardTitle"},
                bgcolor = "#1d1915a0",
            },
            {
                selectors = {"tabletopDocFace"},
                bgcolor = "#1d1915f2",
                borderColor = "#d9d1c440",
                borderWidth = 1,
                cornerRadius = 6,
            },
            {
                selectors = {"tabletopDocFace", "lit"},
                borderColor = "#d9b56a",
                transitionTime = 0.1,
            },
            {
                selectors = {"tabletopDocFace", "tabletopHighlight"},
                borderColor = "#f0d48a",
                borderWidth = 3,
                transitionTime = 0.2,
            },
            {
                selectors = {"tabletopDocIcon"},
                bgcolor = "#d9d1c4",
            },
            {
                selectors = {"tabletopDocTitle"},
                color = "#efe8dc",
                bold = true,
            },
            {
                selectors = {"tabletopDocKind"},
                color = "#a39a8c",
                fontSize = 11,
            },
        }
    end

    --The item's face at its own size: the tile or the picture. The tile's
    --name label takes a refreshDoc event that keeps it current.
    local function DocFace(entry, w, h)
        local picture = EntryPicture(entry)
        if picture == nil then
            local icon = gui.Panel{
                classes = {"tabletopDocIcon"},
                bgimage = EntryIcon(entry),
                width = 34,
                height = 34,
                valign = "center",
                rmargin = 12,
                interactable = false,
            }
            return gui.Panel{
                classes = {"tabletopDocFace"},
                bgimage = "panels/square.png",
                width = w,
                height = h,
                flow = "horizontal",
                hpad = 14,
                borderBox = true,
                interactable = false,
                icon,
                gui.Panel{
                    width = w - 14 * 2 - 34 - 12,
                    height = "auto",
                    valign = "center",
                    flow = "vertical",
                    interactable = false,
                    gui.Label{
                        classes = {"tabletopDocTitle"},
                        width = "100%",
                        height = "auto",
                        maxHeight = 44,
                        fontSize = 16,
                        textWrap = true,
                        textOverflow = "ellipsis",
                        text = entry.description or "",
                        refreshDoc = function(element, e)
                            element.text = e.description or ""
                        end,
                    },
                    gui.Label{
                        classes = {"tabletopDocKind"},
                        width = "100%",
                        height = "auto",
                        text = CustomDocument.JournalEntryKindName(entry),
                    },
                },
            }
        end

        return gui.Panel{
            classes = {"tabletopDocFace"},
            bgimage = "panels/square.png",
            width = w,
            height = h,
            interactable = false,
            gui.Panel{
                width = w - DOC_PICTURE_INSET * 2,
                height = h - DOC_PICTURE_INSET * 2,
                halign = "center",
                valign = "center",
                bgimage = picture,
                bgcolor = "white",
                cornerRadius = 5,
                interactable = false,
            },
        }
    end

    local CloseDocItem

    --The icon rail is the workspace's button bar ("New Experimental UI").
    local function RailInUse()
        return dmhub.GetSettingValue("iconrail") == true and rawget(_G, "IconRailKeyAdd") ~= nil
    end

    --Turns a table item into a rail button: place(key) puts the entry's
    --rail key on a rail and says whether it did; then the item leaves the
    --table, as a minimized map window's button does when docked.
    local function DockDocItem(item, place)
        if not place(CustomDocument.JournalRailKey(item.entryid)) then
            return false
        end
        CloseDocItem(item)
        return true
    end

    local function BuildDocItem(item)
        local layer = DocumentsLayer()
        local entry = CustomDocument.FindJournalEntry(item.entryid)
        if layer == nil or entry == nil then
            return
        end
        local w, h = DocBaseSize(entry)
        item.baseSize = function()
            return w, h
        end
        item.scale = item.scale or 1

        local face = DocFace(entry, w, h)
        item.face = face
        item.scaler = gui.Panel{
            halign = "center",
            valign = "center",
            width = w,
            height = h,
            scale = item.scale,
            interactable = false,
            face,
        }

        --the item's own hover preview gives way to a titlebar control's tooltip.
        local function HidePreview()
            if item.panel ~= nil and item.panel.valid then
                item.panel.tooltip = nil
            end
        end

        local controls = {}
        local share = nil
        if dmhub.isDM then
            share = ShareControl{
                itemId = DocItemId(item.entryid),
                newItem = function()
                    return {kind = "doc", entryid = item.entryid}
                end,
                what = "this",
                iconSize = 12,
                width = 26,
                passPress = true,
                beforeHover = HidePreview,
                cornerRadius = 6,
            }
            controls[#controls+1] = share.button
        end
        controls[#controls+1] = WindowControl{
            danger = true,
            icon = "window-chrome/chrome-close.png",
            iconSize = 12,
            width = 26,
            passPress = true,
            hover = function(element)
                HidePreview()
                gui.Tooltip("Take off the table")(element)
            end,
            click = function(element)
                CloseDocItem(item)
            end,
        }

        --the GameHud cascade carries no theme, so the titlebar brings it.
        local titlebar = gui.Panel{
            styles = ThemeEngine.MergeStyles(g_titleStyles),
            classes = {"tabletopCardTitle", "tabletopCardChrome"},
            floating = true,
            halign = "left",
            valign = "top",
            y = -CARD_TITLE_HEIGHT,
            width = "100%",
            height = CARD_TITLE_HEIGHT,
            bgimage = "panels/square.png",
            cornerRadius = 6,
            flow = "horizontal",
            gui.Panel{
                flow = "horizontal",
                width = "auto",
                height = "100%",
                halign = "right",
                children = controls,
            },
        }
        titlebar:SetClassTree("tabletopCardChrome", true)

        item.titlebar = titlebar
        item.grips = CardGrips(item)

        local children = {item.scaler, titlebar}
        if share ~= nil then
            children[#children+1] = share.frame
        end
        for _, grip in ipairs(item.grips) do
            children[#children+1] = grip
        end

        local panel = gui.Panel{
            classes = {"tabletopDoc"},
            --click-to-front from a press anywhere on it (engine walk).
            raiseOnPress = true,
            styles = DocStyles(),
            halign = "left",
            valign = "top",
            x = item.x,
            y = item.y,
            width = math.floor(w * item.scale),
            height = math.floor(h * item.scale),
            flow = "none",
            bgimage = "panels/square.png",
            bgcolor = "clear",
            draggable = true,
            swallowPress = true,
            hoverCursor = "hand",
            hover = function(element)
                item.cardHovered = true
                titlebar:SetClassTree("shown", true)
                face:SetClass("lit", true)
                CustomDocument.ShowJournalPreview(element, item.entryid)
            end,
            dehover = function(element)
                item.cardHovered = false
                titlebar:SetClassTree("shown", item.gripHovered == true)
                face:SetClass("lit", false)
            end,
            click = function(element)
                if ClicksGuarded() then
                    return
                end
                local e = CustomDocument.FindJournalEntry(item.entryid)
                if e ~= nil then
                    CustomDocument.OpenContent(e)
                end
            end,
            rightClick = function(element)
                element.tooltip = nil
                local entries = {
                    GuardedEntry("Open", function()
                        element.popup = nil
                        CustomDocument.OpenContent(CustomDocument.FindJournalEntry(item.entryid))
                    end),
                }
                if RailInUse() then
                    entries[#entries+1] = GuardedEntry("Dock to Left Rail", function()
                        element.popup = nil
                        DockDocItem(item, function(key) return IconRailKeyAdd(key, "left") end)
                    end)
                    entries[#entries+1] = GuardedEntry("Dock to Right Rail", function()
                        element.popup = nil
                        DockDocItem(item, function(key) return IconRailKeyAdd(key, "right") end)
                    end)
                end
                entries[#entries+1] = GuardedEntry("Take off the table", function()
                    element.popup = nil
                    CloseDocItem(item)
                end)
                element.popup = gui.ContextMenu{entries = entries}
            end,
            beginDrag = function(element)
                element.tooltip = nil
            end,
            --drag it onto either icon rail and it becomes a button there
            --that opens the entry (and leaves the table).
            canDragOnto = function(element, target)
                return target:HasClass("iconRail") or target:HasClass("iconRailButton")
            end,
            dragging = function(element, target)
                IconRailDocDragging(target)
                ChatItemLinks.Dragging(function() return {ChatItemLinks.DocItem(item.entryid)} end)
            end,
            drag = function(element, target)
                IconRailDocDragging(nil)
                --dropped on the chat: a link to the entry; the item stays.
                if ChatItemLinks.Dropped() then
                    element.x = item.x
                    element.y = item.y
                    return
                end
                if target ~= nil and target.valid and (target:HasClass("iconRail") or target:HasClass("iconRailButton")) then
                    if DockDocItem(item, function(key) return IconRailKeyDrop(key, target) end) then
                        return
                    end
                end
                local lw, lh = LayerSize()
                item.x = math.max(0, math.min(element.xdrag, lw - 60))
                item.y = math.max(CARD_TITLE_HEIGHT, math.min(element.ydrag, lh - 60))
                element.x = item.x
                element.y = item.y
                element:SetAsLastSibling()
                SaveSoon()
            end,
            --renames reach the item, a deleted entry takes it off the table,
            --and the share light follows the shared document.
            thinkTime = 1,
            think = function(element)
                local e = CustomDocument.FindJournalEntry(item.entryid)
                if e == nil then
                    CloseDocItem(item)
                    return
                end
                element:FireEventTree("refreshDoc", e)
                UpdateShare(share)
            end,
            children = children,
        }
        layer:AddChild(panel)
        item.panel = panel
        for _, grip in ipairs(item.grips) do
            PlaceGrip(item, grip)
        end
    end

    --Puts a journal entry on this user's table (or brings its item forward).
    --options.screen: the mouse in screen pixels, where a drop centres the
    --item (moving it if it is already on the table); options.shared marks
    --an item that arrived from the Director's share.
    function Tabletop.OpenDocItem(entryid, options)
        options = options or {}
        local entry = CustomDocument.FindJournalEntry(entryid)
        if not Tabletop.IsActive() or entry == nil then
            return
        end
        local lw, lh = LayerSize()
        local bw, bh = DocBaseSize(entry)
        local item = DocItemById(entryid)
        local scale = 1
        if item ~= nil then
            scale = item.scale or 1
        end
        local x, y = nil, nil
        if options.screen ~= nil then
            local mx, my = ScreenToLayer(options.screen.x, options.screen.y)
            x = math.floor(mx - bw * scale / 2)
            y = math.floor(my - bh * scale / 2)
        end
        if item == nil then
            item = {
                entryid = entryid,
                x = x or math.floor((lw - bw) / 2),
                y = y or math.floor((lh - bh) / 2),
                scale = 1,
            }
            g_docItems[#g_docItems+1] = item
        elseif x ~= nil then
            item.x = x
            item.y = y
        end
        item.x = math.max(0, math.min(item.x, lw - 60))
        item.y = math.max(CARD_TITLE_HEIGHT, math.min(item.y, lh - 60))
        if item.panel == nil or not item.panel.valid then
            BuildDocItem(item)
        else
            item.panel.x = item.x
            item.panel.y = item.y
        end
        if item.panel ~= nil and item.panel.valid then
            item.panel:SetAsLastSibling()
            item.face:PulseClass("tabletopHighlight")
        end
        SaveSoon()
    end

    CloseDocItem = function(item)
        if item.panel ~= nil and item.panel.valid then
            item.panel:DestroySelf()
        end
        item.panel = nil
        for i, other in ipairs(g_docItems) do
            if other == item then
                table.remove(g_docItems, i)
                break
            end
        end
        SaveSoon()
    end

    TeardownDocItems = function()
        for _, item in ipairs(g_docItems) do
            if item.panel ~= nil and item.panel.valid then
                item.panel:DestroySelf()
            end
            item.panel = nil
        end
    end

    g_layoutWriters[#g_layoutWriters+1] = function(out)
        local docs = {}
        for _, item in ipairs(g_docItems) do
            docs[#docs+1] = {entryid = item.entryid, x = item.x, y = item.y, scale = item.scale}
        end
        out.docs = docs
    end

    LoadDocItems = function(layout)
        g_docItems = {}
        if layout == nil or type(layout.docs) ~= "table" then
            return
        end
        for _, saved in ipairs(layout.docs) do
            if type(saved) == "table" and type(saved.entryid) == "string" and CustomDocument.FindJournalEntry(saved.entryid) ~= nil
                    and DocItemById(saved.entryid) == nil then
                g_docItems[#g_docItems+1] = {
                    entryid = saved.entryid,
                    x = tonumber(saved.x) or 100,
                    y = tonumber(saved.y) or 100,
                    scale = math.max(CARD_MIN_SCALE, math.min(CARD_MAX_SCALE, tonumber(saved.scale) or 1)),
                }
            end
        end
    end

    --A journal row being dragged: over the bare table the row steps aside
    --(scale, since opacity doesn't reach children) and the item a drop
    --there makes follows the mouse. {row, entryid, preview, rowHidden, seen}
    local g_journalDrag = nil

    function Tabletop.JournalRowDragEnded(row)
        local drag = g_journalDrag
        if drag == nil or (row ~= nil and drag.row ~= row) then
            return
        end
        g_journalDrag = nil
        if drag.rowHidden and drag.row.valid then
            drag.row.selfStyle.scale = 1
        end
        if drag.preview ~= nil and drag.preview.valid then
            drag.preview:DestroySelf()
        end
    end

    function Tabletop.JournalRowDragging(row, entryid)
        if not Tabletop.IsActive() then
            return
        end
        if g_journalDrag ~= nil and g_journalDrag.row ~= row then
            Tabletop.JournalRowDragEnded(nil)
        end
        local entry = CustomDocument.FindJournalEntry(entryid)
        if entry == nil then
            return
        end
        if g_journalDrag == nil then
            g_journalDrag = {row = row, entryid = entryid, rowHidden = false}
        end
        local drag = g_journalDrag
        drag.seen = dmhub.Time()

        local onTable = dmhub.panelDropSurface == "table"
        if onTable ~= drag.rowHidden then
            drag.rowHidden = onTable
            row.selfStyle.scale = cond(onTable, 0.01, 1)
        end

        if onTable and drag.preview == nil then
            local layer = DocumentsLayer()
            if layer ~= nil then
                local w, h = DocBaseSize(entry)
                --at the item's current size when it is already on the table.
                local existing = DocItemById(entryid)
                local s = 1
                if existing ~= nil then
                    s = existing.scale or 1
                end
                drag.preview = gui.Panel{
                    styles = DocStyles(),
                    halign = "left",
                    valign = "top",
                    width = w,
                    height = h,
                    scale = s,
                    flow = "none",
                    DocFace(entry, w, h),
                }
                layer:AddChild(drag.preview)
                --it rides under the mouse, so it must not count as a panel
                --there (dmhub.panelDropSurface) or take the drop.
                drag.preview:MakeNonInteractiveRecursive()
            end
        end
        local preview = drag.preview
        if preview ~= nil and preview.valid then
            preview:SetClass("collapsed", not onTable)
            if onTable then
                local mouse = dmhub.mouseScreenPosition
                local mx, my = ScreenToLayer(mouse.x, mouse.y)
                --scale is about the panel's centre, so it is centred on the
                --mouse by its unscaled size.
                local w, h = DocBaseSize(entry)
                preview.x = math.floor(mx - w / 2)
                preview.y = math.floor(my - h / 2)
                preview:SetAsLastSibling()
            end
        end
    end

    SyncDocItems = function()
        --a drag can end without the row hearing of it (the journal rebuilt
        --mid-drag): the preview goes once its drag events stop.
        if g_journalDrag ~= nil and dmhub.Time() - (g_journalDrag.seen or 0) > 0.3 then
            Tabletop.JournalRowDragEnded(nil)
        end
        for _, item in ipairs(g_docItems) do
            if item.panel == nil or not item.panel.valid then
                BuildDocItem(item)
            end
        end
    end
end

----------------------------------------------------------------------
--Scene windows. A scene from the Scenes library (ScenesPanel.lua) dragged
--onto the table -- or clicked in the panel -- opens in its own window: the
--picture (a still or a looping video) with its caption. Scene windows move,
--resize, maximize and close like map windows, and the Director's share icon
--puts them on the players' tables. The Director maximizing one shows it full
--screen to everyone; the title bar's Players / All control
--(FullscreenDisplay.UpdatePresentationBar) can narrow it to the players,
--with Below UI beside it, and closing the window stops showing it. Scenes
--are per user like the rest of the table.
do
    --{id, sceneid, x, y, width, height, maximized} plus the built panel parts.
    local g_sceneWindows = {}

    --The title bar's controls while a scene window is maximized.
    local g_sceneTitleControls = nil

    local SCENE_MIN_WIDTH = 240
    local SCENE_MIN_HEIGHT = 160

    local function SceneItemId(sceneid)
        return "scene:" .. sceneid
    end

    local function SceneWindowFor(sceneid)
        for _, rec in ipairs(g_sceneWindows) do
            if rec.sceneid == sceneid then
                return rec
            end
        end
        return nil
    end

    local function MaximizedScene()
        for _, rec in ipairs(g_sceneWindows) do
            if rec.maximized then
                return rec
            end
        end
        return nil
    end

    AnySceneMaximized = function()
        return MaximizedScene() ~= nil
    end

    --The Director's maximized scene shown to the Players only: it stays
    --maximized (so the title bar keeps its controls) but is not drawn here.
    local function SceneHiddenHere(rec)
        return rec.maximized and dmhub.isDM and Scenes.ShowState(rec.sceneid) == true
    end

    --- The scene in this user's maximized scene window, or nil.
    --- @return nil|string
    function Tabletop.MaximizedSceneId()
        if not Tabletop.IsActive() then
            return nil
        end
        local rec = MaximizedScene()
        if rec == nil then
            return nil
        end
        return rec.sceneid
    end

    --A new scene window: a 16:9 picture under its titlebar, centred, stepping
    --past any scene window already there.
    local function ScenePlacement()
        local w, h = LayerSize()
        local width = math.floor(w * 0.42)
        local height = math.floor(width * 9 / 16) + TITLE_HEIGHT
        local x0 = math.floor((w - width) / 2)
        local y0 = math.floor((h - height) / 2)
        for step = 0, 11 do
            local x = x0 + 28 * (step % 6)
            local y = y0 + 28 * (step % 6)
            local taken = false
            for _, rec in ipairs(g_sceneWindows) do
                if math.abs(rec.x - x) < 8 and math.abs(rec.y - y) < 8 then
                    taken = true
                    break
                end
            end
            if not taken then
                return x, y, width, height
            end
        end
        return x0, y0, width, height
    end

    local ToggleSceneMaximize
    local CloseSceneWindow

    --Only the Director's maximized scene shown to the Players alone is hidden
    --here. Like map windows, a scene window is never hidden by a maximized
    --window: the maximized one sits under it (ApplyCollapsed).
    local function ApplySceneCollapsed(rec)
        local panel = rec.panel
        if panel == nil or not panel.valid then
            return
        end
        local covered = rec.maximized == true and SceneHiddenHere(rec)
        if panel:HasClass("collapsed") ~= covered then
            panel:SetClass("collapsed", covered)
        end
    end

    --A maximized scene goes over everything (the top layer, over the whole
    --hud) while it is on show and the title bar's Below UI is off -- the way
    --the players see it (David, 2026-10-14). Otherwise it sits at the bottom
    --like a maximized map, and a player's own maximized scene that is not
    --on show always does.
    local function SceneOnTop(rec)
        return rec.maximized == true and Scenes.ShowState(rec.sceneid) ~= false and not Scenes.IsBelowUI()
    end

    --The layer a scene window belongs in: among the windows and journals;
    --maximized, the bottom tabletop layer (under the docks, as a maximized
    --map is) or the top layer (SceneOnTop).
    local function SceneLayer(rec)
        if not rec.maximized then
            return DocumentsLayer()
        end
        if SceneOnTop(rec) then
            return g_topLayer
        end
        return g_layer
    end

    --Puts a built scene window in its layer (SceneLayer). Maximized it fills,
    --cropping; in a window it shows the whole picture.
    local function PlaceSceneWindow(rec)
        local panel = rec.panel
        if panel == nil or not panel.valid then
            return
        end
        local target = SceneLayer(rec)
        if target == nil or not target.valid then
            return
        end
        if panel.parent ~= target then
            if panel.parent ~= nil then
                panel:Unparent()
            end
            target:AddChild(panel)
        end
        if rec.maximized then
            panel.x = 0
            panel.y = 0
            panel.selfStyle.width = "100%"
            panel.selfStyle.height = "100%"
        else
            panel.x = rec.x
            panel.y = rec.y
            panel.selfStyle.width = rec.width
            panel.selfStyle.height = rec.height
        end
        rec.titlebar:SetClass("collapsed", rec.maximized == true)
        rec.resizePanel:SetClass("collapsed", rec.maximized == true)
        rec.view:FireEvent("setFit", cond(rec.maximized, "cover", "contain"))
        panel.draggable = rec.maximized ~= true
        ApplySceneCollapsed(rec)
    end

    local function RefreshSceneWindow(rec)
        if rec.panel == nil or not rec.panel.valid then
            return
        end
        local name = Scenes.Name(rec.sceneid)
        if rec.nameLabel.text ~= name then
            rec.nameLabel.text = name
        end
        rec.view:FireEvent("showScene", Scenes.ViewInfo(rec.sceneid))
        UpdateShare(rec.share)
        rec.showingBadge:SetClass("collapsed", not (dmhub.isDM and Scenes.PresentedId() == rec.sceneid))
    end

    local function BuildSceneWindow(rec)
        local view = FullscreenDisplay.CreateSceneView{fit = "contain", textScale = 0.5}

        local nameLabel = gui.Label{
            classes = {"tabletopTitleText"},
            width = "auto",
            height = "100%",
            valign = "center",
            hmargin = 8,
            textWrap = false,
            text = Scenes.Name(rec.sceneid),
        }

        --the Director is showing this scene to the players.
        local showingBadge = gui.Panel{
            classes = {"tabletopControlIcon", "collapsed"},
            bgimage = "phosphor/eye-fill.png",
            width = 14,
            height = 14,
            valign = "center",
            lmargin = 8,
            hover = gui.Tooltip("Showing to the players"),
        }

        local controls = {}
        local share = nil
        if dmhub.isDM then
            share = ShareControl{
                itemId = SceneItemId(rec.sceneid),
                newItem = function()
                    return {kind = "scene", sceneid = rec.sceneid}
                end,
                what = "this scene",
                iconSize = 15,
            }
            controls[#controls+1] = share.button
            controls[#controls+1] = WindowControl{
                icon = "phosphor/gear-six-fill.png",
                iconSize = 14,
                hover = gui.Tooltip("Edit scene"),
                click = function(element)
                    Scenes.ShowEditor(rec.sceneid)
                end,
            }
        end
        controls[#controls+1] = WindowControl{
            icon = "window-chrome/chrome-maximize.png",
            hover = gui.Tooltip(cond(dmhub.isDM, "Maximize and show to everyone (choose Players in the title bar to show only them)", "Maximize")),
            click = function(element)
                ToggleSceneMaximize(rec)
            end,
        }
        controls[#controls+1] = WindowControl{
            danger = true,
            icon = "window-chrome/chrome-close.png",
            click = function(element)
                CloseSceneWindow(rec)
            end,
        }

        local titlebar = gui.Panel{
            styles = ThemeEngine.MergeStyles(g_titleStyles),
            classes = {"tabletopTitle"},
            flow = "horizontal",
            width = "100%",
            height = TITLE_HEIGHT,
            bgimage = "panels/square.png",
            gui.Panel{
                flow = "horizontal",
                width = "auto",
                height = "100%",
                valign = "center",
                showingBadge,
                nameLabel,
            },
            gui.Panel{
                floating = true,
                flow = "horizontal",
                width = "auto",
                height = "100%",
                halign = "right",
                children = controls,
            },
        }

        local resizeDoc = {
            try_get = function(self, key)
                return rawget(self, key)
            end,
        }
        local resizePanel = gui.WindowResizePanel(resizeDoc, rec.width, rec.height, {
            minWidth = SCENE_MIN_WIDTH,
            minHeight = SCENE_MIN_HEIGHT,
            onResized = function(dialog, moved)
                rec.width = dialog.selfStyle.width
                rec.height = dialog.selfStyle.height
                rec.x, rec.y = ClampWindow(rec, dialog.x, dialog.y)
                if rec.x ~= dialog.x or rec.y ~= dialog.y then
                    dialog.x = rec.x
                    dialog.y = rec.y
                end
                SaveSoon()
            end,
        })

        local panel = gui.Panel{
            styles = g_windowStyles,
            classes = {"tabletopWindow"},
            --click-to-front from a press anywhere on it (engine walk).
            raiseOnPress = true,
            flow = "vertical",
            x = rec.x,
            y = rec.y,
            width = rec.width,
            height = rec.height,
            halign = "left",
            valign = "top",
            bgimage = "panels/square.png",
            swallowPress = true,
            draggable = true,
            drag = function(element)
                if rec.maximized then
                    return
                end
                rec.x, rec.y = SnapWindow(rec, element.xdrag, element.ydrag)
                element.x = rec.x
                element.y = rec.y
                SaveSoon()
            end,
            click = function(element)
                if ClicksGuarded() or rec.maximized then
                    return
                end
                element:SetAsLastSibling()
            end,
            children = {
                titlebar,
                gui.Panel{
                    width = "100%",
                    height = "100% available",
                    flow = "none",
                    view,
                },
                resizePanel,
                share and share.frame,
            },
        }

        rec.panel = panel
        rec.titlebar = titlebar
        rec.view = view
        rec.nameLabel = nameLabel
        rec.showingBadge = showingBadge
        rec.share = share
        rec.resizePanel = resizePanel
        RefreshSceneWindow(rec)
    end

    local function EnsureSceneBuilt(rec)
        if rec.panel == nil or not rec.panel.valid then
            BuildSceneWindow(rec)
        end
        PlaceSceneWindow(rec)
    end

    --The title bar's controls for a maximized scene window: its name, restore
    --and close (the window's own titlebar is hidden while maximized).
    UpdateSceneTitleControls = function()
        local rec = MaximizedScene()
        if rec == nil then
            return
        end
        if g_sceneTitleControls == nil or not g_sceneTitleControls.valid or g_sceneTitleControls.data.recid ~= rec.id then
            g_sceneTitleControls = gui.Panel{
                flow = "horizontal",
                width = "auto",
                height = "100%",
                valign = "center",
                lmargin = 6,
                data = {recid = rec.id},
                gui.Label{
                    width = "auto",
                    height = "100%",
                    valign = "center",
                    hmargin = 8,
                    fontSize = 14,
                    color = "#d9d1c4",
                    textWrap = false,
                    text = Scenes.Name(rec.sceneid),
                },
                TitleBarControl("window-chrome/chrome-restore.png", "Restore the scene window", function(element)
                    local current = MaximizedScene()
                    if current ~= nil then
                        ToggleSceneMaximize(current)
                    end
                end),
                TitleBarControl("window-chrome/chrome-close.png", "Close the scene window", function(element)
                    local current = MaximizedScene()
                    if current ~= nil then
                        CloseSceneWindow(current)
                    end
                end),
            }
        end
        CodexTitleBar.SetMapWindowControls(g_sceneTitleControls)
    end

    --A map window being maximized: scene windows step down.
    UnmaximizeScenes = function()
        for _, rec in ipairs(g_sceneWindows) do
            if rec.maximized then
                rec.maximized = false
                PlaceSceneWindow(rec)
            end
        end
        FullscreenDisplay.UpdatePresentationBar()
    end

    ToggleSceneMaximize = function(rec)
        rec.maximized = not rec.maximized
        if rec.maximized then
            --one maximized window at a time: maps or scenes.
            for _, other in ipairs(g_sceneWindows) do
                if other ~= rec and other.maximized then
                    other.maximized = false
                    PlaceSceneWindow(other)
                end
            end
            for _, other in ipairs(g_windows) do
                if other.maximized and not IsForcedHere(other) then
                    other.maximized = false
                    PlaceWindow(other)
                    Tabletop.SetForced(other.mapid, false)
                end
            end
            --the Director maximizing a scene shows it to everyone; the title
            --bar then narrows it to the Players. One already on show keeps
            --its audience.
            if dmhub.isDM and not Scenes.ShowState(rec.sceneid) then
                Scenes.Present(rec.sceneid, "all")
            end
        end
        PlaceSceneWindow(rec)
        if not rec.maximized and rec.panel ~= nil and rec.panel.valid then
            rec.panel:SetAsLastSibling()
        end
        Refresh()
        FullscreenDisplay.UpdatePresentationBar()
        SaveSoon()
    end

    CloseSceneWindow = function(rec)
        if rec.panel ~= nil and rec.panel.valid then
            rec.panel:DestroySelf()
        end
        rec.panel = nil
        for i, other in ipairs(g_sceneWindows) do
            if other == rec then
                table.remove(g_sceneWindows, i)
                break
            end
        end
        if rec.maximized then
            rec.maximized = false
            CodexTitleBar.SetMapWindowControls(nil)
        end
        --closing a scene's window is how the Director stops showing it.
        if dmhub.isDM and Scenes.PresentedId() == rec.sceneid then
            Scenes.Present(rec.sceneid, false)
        end
        Refresh()
        FullscreenDisplay.UpdatePresentationBar()
        SaveSoon()
    end

    --- Opens a scene on this user's table, or brings its window forward.
    --- options.x/y: where the window goes (documents-layer units);
    --- options.shared: it arrived from the Director's share.
    --- @param sceneid string
    --- @param options nil|{x: nil|number, y: nil|number, shared: nil|boolean}
    function Tabletop.OpenScene(sceneid, options)
        options = options or {}
        if not Tabletop.IsActive() or Scenes.Get(sceneid) == nil then
            return
        end
        local rec = SceneWindowFor(sceneid)
        if rec == nil then
            local x, y, width, height = ScenePlacement()
            rec = {
                id = dmhub.GenerateGuid(),
                sceneid = sceneid,
                x = options.x or x,
                y = options.y or y,
                width = width,
                height = height,
                maximized = false,
            }
            rec.x, rec.y = ClampWindow(rec, rec.x, rec.y)
            g_sceneWindows[#g_sceneWindows+1] = rec
        elseif options.x ~= nil and not rec.maximized then
            rec.x, rec.y = ClampWindow(rec, options.x, options.y)
        end
        EnsureSceneBuilt(rec)
        if not rec.maximized and rec.panel ~= nil and rec.panel.valid then
            rec.panel:SetAsLastSibling()
        end
        Highlight(rec)
        SaveSoon()
    end

    ----------------------------------------------------------------------
    --A scene row dragged out of the Scenes panel. Over the bare table the row
    --steps aside and the window a drop makes follows the mouse.

    --{row, sceneid, preview, rowHidden, seen}
    local g_sceneRowDrag = nil

    local function SceneDropRect(sceneid)
        local rec = SceneWindowFor(sceneid)
        local width, height
        if rec ~= nil and not rec.maximized then
            width, height = rec.width, rec.height
        else
            local _, _, w, h = ScenePlacement()
            width, height = w, h
        end
        local mouse = dmhub.mouseScreenPosition
        local mx, my = ScreenToLayer(mouse.x, mouse.y)
        local tw, th = LayerSize()
        local x = math.floor(mx - width / 2)
        local y = math.floor(my - height / 2)
        x = math.max(0, math.min(x, tw - width))
        y = math.max(0, math.min(y, th - height))
        return x, y, width, height
    end

    local function BuildSceneDropPreview(sceneid, width, height)
        local layer = DocumentsLayer()
        if layer == nil then
            return nil
        end
        local scene = Scenes.Get(sceneid) or {}
        local image = scene.image
        if type(image) ~= "string" or FullscreenDisplay.IsVideo(image) then
            image = nil
        end
        local panel = gui.Panel{
            flow = "vertical",
            halign = "left",
            valign = "top",
            width = width,
            height = height,
            bgimage = "panels/square.png",
            bgcolor = "#100d0bff",
            borderWidth = 2,
            borderColor = "#b8925acc",
            gui.Panel{
                flow = "horizontal",
                width = "100%",
                height = TITLE_HEIGHT,
                bgimage = "panels/square.png",
                bgcolor = "#1d1915ff",
                gui.Label{
                    width = "auto",
                    height = "100%",
                    halign = "left",
                    valign = "center",
                    hmargin = 8,
                    textWrap = false,
                    color = "#d9d1c4",
                    fontSize = 14,
                    text = Scenes.Name(sceneid),
                },
            },
            gui.Panel{
                width = "100%",
                height = "100% available",
                bgimage = image or "panels/square.png",
                bgcolor = cond(image ~= nil, "white", "#1b1814ff"),
            },
        }
        layer:AddChild(panel)
        panel:MakeNonInteractiveRecursive()
        return panel
    end

    function Tabletop.SceneRowDragEnded(row)
        local drag = g_sceneRowDrag
        if drag == nil or (row ~= nil and drag.row ~= row) then
            return
        end
        g_sceneRowDrag = nil
        if drag.rowHidden and drag.row.valid then
            drag.row.selfStyle.scale = 1
        end
        if drag.preview ~= nil and drag.preview.valid then
            drag.preview:DestroySelf()
        end
    end

    function Tabletop.SceneRowDragging(row, sceneid)
        if not Tabletop.IsActive() then
            return
        end
        if g_sceneRowDrag ~= nil and g_sceneRowDrag.row ~= row then
            Tabletop.SceneRowDragEnded(nil)
        end
        if g_sceneRowDrag == nil then
            g_sceneRowDrag = {row = row, sceneid = sceneid, rowHidden = false}
        end
        local drag = g_sceneRowDrag
        drag.seen = dmhub.Time()

        local onTable = dmhub.panelDropSurface == "table"
        if onTable ~= drag.rowHidden then
            drag.rowHidden = onTable
            row.selfStyle.scale = cond(onTable, 0.01, 1)
        end

        if not onTable then
            if drag.preview ~= nil and drag.preview.valid then
                drag.preview:SetClass("collapsed", true)
            end
            return
        end

        local x, y, width, height = SceneDropRect(sceneid)
        if drag.preview == nil or not drag.preview.valid then
            drag.preview = BuildSceneDropPreview(sceneid, width, height)
        end
        local preview = drag.preview
        if preview ~= nil and preview.valid then
            preview:SetClass("collapsed", false)
            preview.x = x
            preview.y = y
            preview:SetAsLastSibling()
        end
    end

    --- A scene row released with no drop target under it: on the bare table
    --- the scene opens there (or its window moves there). Returns true if the
    --- drop was taken.
    --- @param sceneid string
    --- @return boolean
    function Tabletop.SceneRowDropped(sceneid)
        if not Tabletop.IsActive() or dmhub.panelDropSurface ~= "table" or Scenes.Get(sceneid) == nil then
            return false
        end
        local x, y = SceneDropRect(sceneid)
        Tabletop.OpenScene(sceneid, {x = x, y = y})
        return true
    end

    ----------------------------------------------------------------------
    --Lifecycle and saving.

    --What the windows last reacted to (shares, the scene on show, whether a
    --scene shows under the UI here), and the next once-a-second refresh,
    --which picks up library edits.
    local g_sceneSignature = nil
    local g_nextSceneRefresh = 0

    SyncSceneWindows = function()
        --the library is ScenesPanel.lua, in another mod.
        if rawget(_G, "Scenes") == nil then
            return
        end
        if g_sceneRowDrag ~= nil and dmhub.Time() - (g_sceneRowDrag.seen or 0) > 0.3 then
            Tabletop.SceneRowDragEnded(nil)
        end

        --a deleted scene takes its window with it.
        for i = #g_sceneWindows, 1, -1 do
            local rec = g_sceneWindows[i]
            if Scenes.Get(rec.sceneid) == nil then
                CloseSceneWindow(rec)
            end
        end

        for _, rec in ipairs(g_sceneWindows) do
            if rec.panel == nil or not rec.panel.valid then
                EnsureSceneBuilt(rec)
            elseif rec.panel.parent ~= SceneLayer(rec) then
                --Below UI flipped, or the scene went on or off show.
                PlaceSceneWindow(rec)
            else
                ApplySceneCollapsed(rec)
            end
        end

        local signature = string.format("%s|%s", tostring(ShareDoc().data.seq), tostring(Scenes.PresentedId()))
        if signature ~= g_sceneSignature or dmhub.Time() >= g_nextSceneRefresh then
            g_sceneSignature = signature
            g_nextSceneRefresh = dmhub.Time() + 1
            for _, rec in ipairs(g_sceneWindows) do
                RefreshSceneWindow(rec)
            end
            --a maximized scene restored with the layout gets its title bar
            --control (it only rebuilds when something changed).
            FullscreenDisplay.UpdatePresentationBar()
        end
    end

    TeardownSceneWindows = function()
        for _, rec in ipairs(g_sceneWindows) do
            if rec.panel ~= nil and rec.panel.valid then
                rec.panel:DestroySelf()
            end
            rec.panel = nil
        end
        g_sceneTitleControls = nil
        g_sceneSignature = nil
    end

    g_layoutWriters[#g_layoutWriters+1] = function(out)
        local list = {}
        for _, rec in ipairs(g_sceneWindows) do
            list[#list+1] = {
                id = rec.id,
                sceneid = rec.sceneid,
                x = rec.x,
                y = rec.y,
                width = rec.width,
                height = rec.height,
                maximized = rec.maximized == true,
            }
        end
        out.scenes = list
    end

    LoadSceneWindows = function(layout)
        g_sceneWindows = {}
        if layout == nil or type(layout.scenes) ~= "table" or rawget(_G, "Scenes") == nil then
            return
        end
        for _, saved in ipairs(layout.scenes) do
            if type(saved) == "table" and type(saved.sceneid) == "string" and Scenes.Get(saved.sceneid) ~= nil
                    and SceneWindowFor(saved.sceneid) == nil then
                local rec = {
                    id = saved.id or dmhub.GenerateGuid(),
                    sceneid = saved.sceneid,
                    x = tonumber(saved.x) or 100,
                    y = tonumber(saved.y) or 100,
                    width = math.max(SCENE_MIN_WIDTH, tonumber(saved.width) or 640),
                    height = math.max(SCENE_MIN_HEIGHT, tonumber(saved.height) or 400),
                    maximized = saved.maximized == true and MaximizedScene() == nil,
                }
                rec.x, rec.y = ClampWindow(rec, rec.x, rec.y)
                g_sceneWindows[#g_sceneWindows+1] = rec
            end
        end
    end
end

--First time in this game (or the view was just turned on): restore the
--saved layout, else open one window on the map we are on.
local function InitForGame()
    g_windows = {}
    g_focusedId = nil
    g_liveId = nil
    g_pendingAdopt = nil
    g_lastMapId = game.currentMapId

    local layout = LoadLayout()
    g_seenShares = {}
    g_shareSignature = nil
    if layout ~= nil and type(layout.seenShares) == "table" then
        g_seenShares = layout.seenShares
    end
    --a new table opens every map viewable for this player; one saved before
    --the list was kept only starts tracking from here.
    g_sharing.viewable.seen = {}
    g_sharing.viewable.seed = false
    g_sharing.viewable.nextCheck = 0
    if layout ~= nil and type(layout.viewableMaps) == "table" then
        g_sharing.viewable.seen = layout.viewableMaps
    elseif layout ~= nil then
        g_sharing.viewable.seed = true
    end
    LoadCards(layout)
    LoadDocItems(layout)
    LoadSceneWindows(layout)
    NoteExistingMapDialog()
    if layout ~= nil and type(layout.windows) == "table" then
        for _,saved in ipairs(layout.windows) do
            --a player's table keeps only maps they can still open (no longer
            --Player Viewable for them, their token moved on).
            if type(saved) == "table" and type(saved.mapid) == "string" and MapExists(saved.mapid) and WindowForMap(saved.mapid) == nil
                    and Tabletop.CanAccessMap(saved.mapid) then
                local rec = {
                    id = saved.id or dmhub.GenerateGuid(),
                    mapid = saved.mapid,
                    x = tonumber(saved.x) or 100,
                    y = tonumber(saved.y) or 100,
                    width = math.max(MIN_WIDTH, tonumber(saved.width) or 800),
                    height = math.max(MIN_HEIGHT, tonumber(saved.height) or 600),
                    maximized = saved.maximized == true,
                    minimized = saved.minimized == true,
                    iconX = tonumber(saved.iconX),
                    iconY = tonumber(saved.iconY),
                }
                --the screen may be smaller than when it was saved.
                rec.x, rec.y = ClampWindow(rec, rec.x, rec.y)
                g_windows[#g_windows+1] = rec
            end
        end
        if WindowById(layout.focused) ~= nil then
            g_focusedId = layout.focused
        end
    end

    --the map we are on is the quick one to show: focus its window, or open one.
    local current = WindowForMap(game.currentMapId)
    if current == nil and #g_windows == 0 then
        current = NewWindowRecord(game.currentMapId)
        g_windows[#g_windows+1] = current
    end
    if current ~= nil then
        g_focusedId = current.id
    end
end

--Once a second: close windows whose map was deleted, and refresh the
--frozen windows' titles (another map's combat moves on without us).
local g_nextHousekeeping = 0

local function Housekeeping()
    for i = #g_windows, 1, -1 do
        local rec = g_windows[i]
        if not MapExists(rec.mapid) then
            CloseWindow(rec)
        end
    end
    RecheckForced()
    Refresh()
end

local function Sync()
    local active = Tabletop.IsActive()
    if dmhub.tabletopMode ~= active then
        dmhub.tabletopMode = active
    end

    CheckRowDragEnded()
    UpdateTokenDragPreview()

    --the bottom layer is the table (it takes the table's right-click) only
    --while the view is on; otherwise it must not cover the full-screen map.
    if g_layer ~= nil and g_layer.valid and g_layer.data.table ~= active then
        g_layer.data.table = active
        g_layer.bgimage = cond(active, "panels/square.png", false)
        g_layer.selfStyle.bgcolor = "clear"
        g_layer.interactable = active
    end
    if active then
        SyncSurface()
    end

    if not active then
        if #g_windows > 0 or g_gameid ~= nil then
            Teardown()
            TeardownCards()
            TeardownDocItems()
            TeardownSceneWindows()
            g_windows = {}
            g_gameid = nil
            --docked map windows leave the rail with the view.
            IconRailRebuildSoon()
        end
        return
    end

    if g_gameid ~= dmhub.gameid then
        Teardown()
        TeardownCards()
        TeardownDocItems()
        TeardownSceneWindows()
        g_gameid = dmhub.gameid
        InitForGame()
        IconRailRebuildSoon()
    end

    if DocumentsLayer() == nil or g_layer == nil or not g_layer.valid then
        return
    end

    SyncShares()
    g_sharing.SyncViewableMaps()
    SyncCards()
    SyncDocItems()
    SyncSceneWindows()

    local built = false
    for _,rec in ipairs(g_windows) do
        if rec.panel == nil or not rec.panel.valid then
            EnsureBuilt(rec)
            built = true
        end
    end

    if game.currentMapId ~= g_lastMapId then
        g_lastMapId = game.currentMapId
        OnCurrentMapChanged(game.currentMapId)
    elseif built then
        Refresh()
        --windows are rebuilt in creation order; the live one belongs on top.
        local live = WindowById(g_liveId)
        if live ~= nil and not live.maximized then
            BringToFront(live)
        end
    elseif dmhub.Time() >= g_nextHousekeeping then
        g_nextHousekeeping = dmhub.Time() + 1
        Housekeeping()
    end
end

--The engine fires this inside the map change itself, so the windows swap
--in the same frame the new map is built (hidden behind the dissolve).
dmhub.RegisterEventHandler("ChangeCurrentFloor", function()
    if mod.unloaded or not Tabletop.IsActive() then
        return
    end
    Sync()
end)

--Lets the user pick or upload an image to cover the table.
local function ShowCustomSurfaceDialog()
    local dialog = gui.Panel{
        classes = {"framedPanel"},
        styles = ThemeEngine.GetStyles(),
        width = 440,
        height = "auto",
        halign = "center",
        valign = "center",
        flow = "vertical",
        pad = 20,
        borderBox = true,
        gui.Label{
            classes = {"modalTitle"},
            text = "Table Image",
        },
        gui.Label{
            text = "Choose or upload an image to cover the table.",
            width = "100%",
            height = "auto",
            textAlignment = "center",
            vmargin = 10,
        },
        gui.IconEditor{
            library = "coverart",
            width = 320,
            height = 180,
            halign = "center",
            allowNone = false,
            value = g_surfaceImageSetting:Get(),
            change = function(element)
                if element.value ~= nil and element.value ~= "" then
                    g_surfaceImageSetting:Set(element.value)
                    g_surfaceSetting:Set("custom")
                end
            end,
        },
        gui.Button{
            text = "Done",
            halign = "center",
            tmargin = 16,
            click = function(element)
                gui.CloseModal()
            end,
        },
    }
    gui.ShowModal(dialog)
end

--Right-click on the bare table: the surfaces, one flat list (a submenu
--opened near a screen corner lands on top of its own menu).
local function ShowTableMenu(element)
    local current = g_surfaceSetting:Get()
    local entries = {}
    --only the current surface carries a check (check = false would draw an
    --empty box on every other row).
    local function AddSurfaces(surfaces)
        for _, surface in ipairs(surfaces) do
            local id = surface.id
            local entry = GuardedEntry(surface.text, function()
                element.popup = nil
                g_surfaceSetting:Set(id)
            end)
            entry.check = (current == id) or nil
            entries[#entries+1] = entry
        end
    end
    AddSurfaces(TABLE_SURFACES)
    if dmhub.GetSettingValue("dev") then
        AddSurfaces(DEV_TABLE_SURFACES)
    end
    local imageEntry = GuardedEntry("Table Image...", function()
        element.popup = nil
        ShowCustomSurfaceDialog()
    end)
    imageEntry.check = (current == "custom") or nil
    entries[#entries+1] = imageEntry
    entries[#entries+1] = GuardedEntry("Turn Off Tabletop View", function()
        element.popup = nil
        dmhub.SetSettingValue("tabletop:enabled", false)
    end)
    element.popup = gui.ContextMenu{
        entries = entries,
    }
end

--Keeps the engine's table surface in step with this user's choice.
SyncSurface = function()
    local surface = g_surfaceSetting:Get()
    local image = g_surfaceImageSetting:Get()
    if image == "" then
        image = nil
    end
    if dmhub.tabletopSurface ~= surface then
        dmhub.tabletopSurface = surface
    end
    if dmhub.tabletopSurfaceImage ~= image then
        dmhub.tabletopSurfaceImage = image
    end
end

--The bottom layer of the GameHud: maximized windows live here, under the
--docks and the rest of the hud, and its think drives the tabletop. While
--the view is on it is the table itself (a clear image, so it takes the
--right-click), and it never blocks the map's own input.
function Tabletop.CreateLayer()
    g_layer = gui.Panel{
        id = "tabletopLayer",
        width = "100%",
        height = "100%",
        interactable = false,
        --not a blocker: a creature dropped on the bare table is a table drop
        --(the engine walks up from the panel hit to the first swallowPress
        --panel looking for one that blocks game interaction).
        blocksGameInteraction = false,
        swallowPress = true,
        data = {table = false},
        rightClick = function(element)
            if Tabletop.IsActive() then
                ShowTableMenu(element)
            end
        end,
        thinkTime = 0.05,
        think = function(element)
            Sync()
        end,
        create = function(element)
            Sync()
        end,
        destroy = function(element)
            --the hud is going; its windows go with it and are rebuilt into
            --the next one.
            ReleaseMapStatus()
            UpdateRestoreButton(false)
        end,
    }
    return g_layer
end

--The layer over the whole hud: a maximized scene window on show with Below
--UI off sits here, over the docks, rails and dialogs, as the players see it
--(SceneOnTop). GameHud puts it straight after the over-the-UI fullscreen
--display. It has no image, so when empty it takes no mouse.
function Tabletop.CreateTopLayer()
    g_topLayer = gui.Panel{
        id = "tabletopTopLayer",
        width = "100%",
        height = "100%",
        interactable = false,
    }
    return g_topLayer
end

--The layer over the map windows and journals: minimized windows' floating
--buttons, and the collapse animation. GameHud puts it straight after the
--documents layer. It has no image, so the table under it stays clickable.
function Tabletop.CreateButtonLayer()
    g_buttonLayer = gui.Panel{
        id = "tabletopButtonLayer",
        styles = MapButtons.Styles(),
        width = "100%",
        height = "100%",
        interactable = false,
    }
    return g_buttonLayer
end

--the buttons' hover fill and icon colors follow the theme.
ThemeEngine.OnThemeChanged(mod, function()
    if g_buttonLayer ~= nil and g_buttonLayer.valid then
        g_buttonLayer.styles = MapButtons.Styles()
        g_buttonLayer:UpdateStyle()
    end
end)

--Minimized windows docked on the icon rail ("mapwindow:<window id>" in the
--rail layout; see RailEntryTypes in DocumentSystem.lua). The docked button
--stays on the rail while its window is open, lit, like a panel's button.
RailEntryTypes = rawget(_G, "RailEntryTypes") or {}
RailEntryTypes.mapwindow = {
    available = function(id)
        return Tabletop.IsActive() and WindowById(id) ~= nil
    end,
    name = function(id)
        local rec = WindowById(id)
        if rec == nil then
            return "Map Window"
        end
        return MapName(rec.mapid)
    end,
    icon = function(id)
        return "phosphor/map-trifold.png"
    end,
    isActive = function(id)
        local rec = WindowById(id)
        return rec ~= nil and not rec.minimized
    end,
    --opens a minimized window; a window that is open but not the one in
    --use comes forward; the window in use collapses back onto the rail.
    activate = function(id, element)
        local rec = WindowById(id)
        if rec == nil then
            return
        end
        if rec.minimized then
            RestoreWindow(rec)
        elseif g_focusedId ~= rec.id then
            Focus(rec)
        else
            Minimize(rec)
        end
    end,
    hover = function(id, element)
        local rec = WindowById(id)
        if rec ~= nil then
            ShowPreviewTooltip(rec, element)
        end
    end,
    menu = function(id, element)
        local rec = WindowById(id)
        if rec == nil then
            return {}
        end
        return {
            GuardedEntry(cond(rec.minimized, "Restore", "Minimize"), function()
                element.popup = nil
                if rec.minimized then
                    RestoreWindow(rec)
                else
                    Minimize(rec)
                end
            end),
            GuardedEntry("Close Map Window", function()
                element.popup = nil
                RequestClose(rec)
            end),
        }
    end,
    --taken off the rail: a minimized window's button goes back on the
    --table, next to the rail it left.
    onRemove = function(id)
        local rec = WindowById(id)
        if rec == nil then
            return
        end
        if rec.minimized then
            local w = LayerSize()
            rec.iconX = math.min(rec.iconX or 80, w - 80)
            rec.iconY = rec.iconY or 120
        end
        UpdateTableButton(rec)
        SaveSoon()
    end,
}

--Right-click entries for a map row in the Maps panel.
function Tabletop.MapContextMenuEntries(mapid)
    if not Tabletop.IsActive() then
        return {}
    end
    return {
        {
            text = "Open in New Map Window",
            click = function()
                Tabletop.OpenMap(mapid, {newWindow = true})
            end,
        },
    }
end
