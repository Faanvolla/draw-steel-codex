local mod = dmhub.GetModLoading()

--The Director's Screen: a see-through dark band down the right side of the
--Director's table. What lies on it is the Director's alone; dragging an item
--off it onto the table shares it with the players, and dragging an item onto
--it stops sharing it (David, 2026-10-16).
--
--The side an item is on decides its share, as a guarantee (David,
--2026-10-16): on the screen it is never shared, and has no share button; on
--the table it is shared, unless the Director held it back with its share
--button (or unshared it another way, e.g. Map Settings), and then it shows
--faded (groupOpacity) while it is not the focused item, so a held-back item
--never passes for a shared one.
--
--  - The items are the table items that can be shared: map windows (whose
--    share is the map's Player Viewable), scene windows, NPC cards and
--    journal items, and minimized map and scene windows' buttons, which
--    stand for their windows. Tabletop.ScreenItems lists them.
--  - An item is on the screen when its middle is. It joins or leaves the
--    screen when the Director drops it (DirectorScreen.ItemDropped from each
--    item's drag): onto the screen unshares it, off it shares it.
--  - An item new on the table (a window, card or journal item opened any
--    way) is private if it lies on the open screen and shared with every
--    player anywhere else, including with the screen closed. One lying on
--    the screen that is already shared (a Player Viewable map's window) is
--    moved off it instead: opening a window never unshares a map.
--  - Something the Director drags onto the table (a map, scene, journal or
--    character row from a panel, a token out of its map, files from the
--    desktop) follows the drop's rule: dropped on the open screen it is
--    private, dropped anywhere else it is shared, even if it was held back
--    (DirectorScreen.ItemPlaced).
--  - The items on the table when the layout loads keep their shares: an
--    unshared one is held back (faded), not shared.
--  - Resizing the screen never shares or unshares: items on it are pushed
--    along to stay on it, and items on the table are pushed off it as it
--    widens. One that cannot get off (the screen is the whole table) goes
--    behind it, unshared.
--  - Nothing on it is ever shared: an item on it that gets shared some other
--    way (Map Settings) is moved off it.
--  - The screen resizes from its left edge or its tab, from the full width of
--    the table down to just the tab in the bottom-right corner. A click on the
--    tab opens or closes it. Closed, the items on it are hidden (stowed), and
--    focusing a stowed map window opens the screen again (Reveal).
--  - Its size and its items are saved with the table layout (per user, per
--    game). Players have no screen.
--  - While a maximized map or scene window covers the table, the screen is
--    gone, as if closed: its band and tab are hidden, so are the items on it,
--    and new items are shared (David, 2026-10-16). Maximizing never changes a
--    window's share, and the maximized window keeps its share button even if
--    it came from the screen; shared that way, it leaves the screen, and is
--    moved off it when restored.
--
--GameHud mounts two layers: the band itself under the windows (CreateLayer),
--and the tab and the drop hint over them (CreateTabLayer). Neither takes the
--mouse except at the edge grip and the tab, so the table, the maps and the
--windows under the band work as before.

--- @class DirectorScreenModule
DirectorScreen = {}

--One table item, as the screen sees it (Tabletop.ScreenItems makes these).
--- @class DirectorScreenItem
--- @field key string unique among the items ("map:<window id>", "card:<charid>"...)
--- @field rect nil|{x: number, y: number, w: number, h: number} where it lies on the table (documents-layer units); nil when it has no spot (maximized, docked on a rail)
--- @field move fun(x: number) moves it so its left edge is at x (kept on the table)
--- @field store TabletopShareStore its share
--- @field changed fun() call after its share was changed here
--- @field stow fun(stowed: boolean) hides it (the screen is closed) or shows it
--- @field panel fun(): Panel|nil what the Director sees of it on the table (faded while held back)
--- @field shareButton fun(): Panel|nil its share button (hidden while it is on the screen)
--- @field showBehind fun(behind: boolean) whether it lies behind the screen (hides its grey not-shared frame)
--- @field maximized nil|boolean a maximized window (never faded; keeps its share button)

--Sizes in documents-layer units (the table is ~1048 high).
local TAB_WIDTH = 14
local TAB_HEIGHT = 64
--between the tab and the bottom of the table.
local TAB_BOTTOM = 18
local GRIP_WIDTH = 12
--narrower than this past the right rail, the screen closes to its tab.
local MIN_OPEN = 90
--how much of the table a screen opened for the first time takes.
local DEFAULT_FRACTION = 0.22
--after the Director moves an item across the edge, its share takes a moment
--to come back from the server; meanwhile the item is not moved off the screen.
local GRACE_SECONDS = 2.5
--how long a drop waits for the item it makes (a bestiary creature's card
--waits for the new character; a file's map waits for its import).
local PLACED_SECONDS = 60
--a click that moved the tab less than this is a click, not a resize.
local CLICK_SLOP = 4
--how see-through an item held back on the table is while not focused.
local HELD_BACK_OPACITY = 0.45

--Covers: art shown on the screen, under its items. The art fills the screen's
--height and is cropped to its width (never stretched). It sticks to the
--screen's moving edge: `left` is the spot on the art (0..1) that the edge
--always shows, so the art travels with the edge and a wider screen shows more
--of it to the right. `veil` is the grey laid over the art to mix it into the
--band (the engine ignores alpha on image art, so it is veiled, not faded).
--Tune the veil's alpha by eye: this layer's blending is steep, e0 barely
--shows and f8 nearly hides the art. `tint` colors the art. A cover with no
--image is the plain band.
--More covers just add rows; choosing between them is still to come
--(2026-10-16, a test).
--- @class DirectorScreenCover
--- @field id string
--- @field image nil|string the bgimage id
--- @field width nil|number the image's size in pixels
--- @field height nil|number
--- @field left nil|number
--- @field tint nil|string
--- @field veil nil|string
local COVERS = {
    {id = "plain"},
    {id = "vasloria", image = "e83e6ea1-6212-4baf-8f26-a11bf7b85c6e", width = 2000, height = 633, left = 0, tint = "#ffffffff", veil = "#16171bf2"},
}
local COVER_ID = "vasloria"

--- @return DirectorScreenCover
local function CurrentCover()
    for _, cover in ipairs(COVERS) do
        if cover.id == COVER_ID then
            return cover
        end
    end
    return COVERS[1]
end

--The part of the cover's art a w x h screen shows: full height, cropped to the
--screen's shape, with its left edge at cover.left (pulled back once a wide
--screen would run off the art's right end).
--- @param cover DirectorScreenCover
--- @param w number
--- @param h number
--- @return {x1: number, y1: number, x2: number, y2: number}
local function CoverRect(cover, w, h)
    local frac = math.min(1, (w / h) / (cover.width / cover.height))
    local x1 = math.min(1 - frac, math.max(0, cover.left or 0))
    return {x1 = x1, y1 = 0, x2 = x1 + frac, y2 = 1}
end

--fraction: of the table's width; 0 while closed.
--lastFraction: the size it opens to from the tab.
--members: key -> true for the items on the screen.
--heldBack: key -> true for the items on the table the Director keeps from
--the players (unshared; drawn faded).
--known: key -> true for every item seen since the layout loaded; nil until
--the first look, which only records them (no item is new then).
--pushed: key -> true for a shared item the last look moved off the screen
--(if it is still on it, it cannot get off).
--faded: panel -> whether its fade is on (weak keys), so each look writes
--only what changed.
--grace: key -> time until which the item is left alone (GRACE_SECONDS).
--placed: key -> time until which a drop's item is awaited (ItemPlaced).
--drag: {key, centre, seen} while the Director drags an item; key is nil and
--fresh is true for something new dragged from a panel (NewItemDragging).
--resize: {offset, startX, moved} while the edge or the tab is dragged.
--passUntil: while a drag reports in (ItemDragging, NewItemDragging), the
--grip and the tab let the mouse through until this time (LetDragsThrough).
local g = {
    fraction = DEFAULT_FRACTION,
    lastFraction = DEFAULT_FRACTION,
    members = {},
    heldBack = {},
    known = nil,
    pushed = {},
    faded = setmetatable({}, {__mode = "k"}),
    grace = {},
    placed = {},
    drag = nil,
    resize = nil,
    passUntil = 0,
    passing = false,
    nextLook = 0,
    layer = nil,
    band = nil,
    grip = nil,
    cover = nil,
    coverVeil = nil,
    tabLayer = nil,
    tab = nil,
    tabFace = nil,
    hint = nil,
    hintLabel = nil,
    signature = nil,
}

local function Active()
    return dmhub.isDM and Tabletop.IsActive() and Tabletop.LayerReady()
end

local function IsOpen()
    return g.fraction > 0
end

--Whether a maximized window covers the table: the screen is then gone.
local function Hidden()
    return Tabletop.TableCovered()
end

--Open and not hidden: the screen is there, and works.
local function Shown()
    return IsOpen() and not Hidden()
end

--The table's size, in documents-layer units.
local function TableSize()
    local rect = Tabletop.LayerRect()
    return rect.w, rect.h
end

--How far in from the right the right icon rail reaches (0 with no rail).
local function RailReserve()
    local fn = rawget(_G, "RailRightColumnWidth")
    if fn == nil then
        return 0
    end
    return fn() or 0
end

--The x of the screen's left edge: the table's width while it is closed.
local function Edge()
    local w = TableSize()
    if not IsOpen() then
        return w
    end
    return math.floor(w * (1 - g.fraction))
end

local function Centre(rect)
    return rect.x + rect.w / 2
end

--Whether an item lying at rect is on the screen (never while it is gone).
local function OnScreen(rect)
    return Shown() and rect ~= nil and Centre(rect) >= Edge()
end

--The mouse, in documents-layer units.
local function MouseOnTable()
    local m = dmhub.mouseScreenPosition
    local screen = dmhub.screenDimensions
    local below = dmhub.screenDimensionsBelowTitlebar
    local _, h = TableSize()
    if below.y <= 0 then
        return m.x, m.y
    end
    local scale = h / below.y
    return m.x * scale, (m.y - (screen.y - below.y)) * scale
end

local function FindItem(key)
    for _, item in ipairs(Tabletop.ScreenItems()) do
        if item.key == key then
            return item
        end
    end
    return nil
end

----------------------------------------------------------------------
--Drawing the band and the tab.

local g_styles = {
    {
        selectors = {"directorScreenBand"},
        bgcolor = "#16171bcc",
    },
    {
        selectors = {"directorScreenBand", "dropTarget"},
        bgcolor = "#202127dd",
    },
    {
        selectors = {"directorScreenEdge"},
        bgcolor = "@bg",
    },
    {
        selectors = {"directorScreenEdge", "lit"},
        bgcolor = "@bgRaised",
    },
    {
        selectors = {"directorScreenEdge", "dropTarget"},
        bgcolor = "#ffffffa0",
    },
    {
        selectors = {"directorScreenEdge", "sharing"},
        bgcolor = "@share",
    },
    {
        selectors = {"directorScreenCaption"},
        color = "#ffffff70",
        fontSize = 13,
        bold = true,
        uppercase = true,
        width = "auto",
        height = "auto",
    },
    {
        selectors = {"directorScreenTab"},
        bgcolor = "clear",
    },
    {
        selectors = {"directorScreenTabFace"},
        bgcolor = "@bg",
    },
    {
        selectors = {"directorScreenTabFace", "lit"},
        bgcolor = "@bgRaised",
    },
    {
        selectors = {"directorScreenHint"},
        bgcolor = "#121316ee",
        borderColor = "#ffffff40",
    },
    {
        selectors = {"directorScreenHint", "sharing"},
        borderColor = "@share",
    },
    {
        selectors = {"directorScreenHintLabel"},
        color = "#ffffffe0",
        fontSize = 14,
        width = "auto",
        height = "auto",
    },
}

--Puts the band, its edge and the tab where the screen's size says. Cheap
--when nothing changed (the table resizing changes it too).
local function Layout(force)
    local band = g.band
    local tab = g.tab
    local face = g.tabFace
    if band == nil or not band.valid or tab == nil or not tab.valid or face == nil or not face.valid then
        return
    end
    local active = Active()
    local hidden = active and Hidden()
    local w, h = TableSize()
    local edge = Edge()
    local reserve = RailReserve()
    local signature = string.format("%s|%s|%d|%d|%d|%d", tostring(active), tostring(hidden), math.floor(w), math.floor(h), math.floor(edge), math.floor(reserve))
    if signature == g.signature and not force then
        return
    end
    g.signature = signature

    --a maximized window covering the table hides the band and the tab too.
    band:SetClass("collapsed", not active or hidden or not IsOpen())
    tab:SetClass("collapsed", not active or hidden)
    face:SetClass("collapsed", not active or hidden)
    if not active or hidden then
        return
    end
    band.x = edge
    band.selfStyle.width = math.max(1, w - edge)

    local cover = g.cover
    if cover ~= nil and cover.valid then
        local art = CurrentCover()
        cover:SetClass("collapsed", art.image == nil)
        local veil = g.coverVeil
        if veil ~= nil and veil.valid then
            veil.selfStyle.bgcolor = art.veil or "clear"
        end
        if art.image ~= nil and w - edge >= 1 and h >= 1 then
            cover.bgimage = art.image
            cover.selfStyle.bgcolor = art.tint or "#ffffffff"
            cover.selfStyle.imageRect = CoverRect(art, w - edge, h)
        end
    end

    --the tab hangs off the screen's edge, and never under the right rail.
    local right = math.min(edge, w - reserve)
    tab.x = math.max(0, right - TAB_WIDTH)
    tab.y = math.max(0, h - TAB_BOTTOM - TAB_HEIGHT)
    face.x = tab.x
    face.y = tab.y
end

local function SetFraction(fraction)
    g.fraction = math.max(0, math.min(1, fraction))
    Layout()
end

--Opens the screen to the size it last had.
local function Open()
    if IsOpen() then
        return
    end
    SetFraction(g.lastFraction or DEFAULT_FRACTION)
    Tabletop.SaveLayoutSoon()
end

local function Close()
    if not IsOpen() then
        return
    end
    g.lastFraction = g.fraction
    SetFraction(0)
    Tabletop.SaveLayoutSoon()
end

--The edge and the tab resize the screen: the edge follows the mouse. Below
--MIN_OPEN past the rail it shows closed, and is closed on release.
local function BeginResize()
    local mx = MouseOnTable()
    local w = TableSize()
    --closed, the edge is where the tab is drawn, so a pull starts from there.
    local edge = math.min(Edge(), w - RailReserve())
    g.resize = {offset = edge - mx, startX = mx, moved = false}
end

local function Resizing()
    local resize = g.resize
    if resize == nil then
        return
    end
    local mx = MouseOnTable()
    if math.abs(mx - resize.startX) > CLICK_SLOP then
        resize.moved = true
    end
    if not resize.moved then
        return
    end
    local w = TableSize()
    local edge = math.max(0, math.min(w, mx + resize.offset))
    local width = w - edge
    if width < RailReserve() + MIN_OPEN then
        SetFraction(0)
    else
        SetFraction(width / w)
    end
end

local function EndResize()
    local resize = g.resize
    g.resize = nil
    if resize == nil or not resize.moved then
        return false
    end
    if IsOpen() then
        g.lastFraction = g.fraction
    end
    Tabletop.SaveLayoutSoon()
    return true
end

--The drag events the edge and the tab share. dragMove is off, so the panel
--stays put and Layout moves it.
local function ResizeEvents(args)
    args.draggable = true
    args.dragMove = false
    args.beginDrag = function(element)
        BeginResize()
    end
    args.dragging = function(element)
        Resizing()
    end
    args.drag = function(element)
        EndResize()
    end
    return args
end

--The divider and the tab are one handle: hovering either lights both.
--- @param lit boolean
local function SetLit(lit)
    local band = g.band
    if band ~= nil and band.valid then
        for _, child in ipairs(band.children) do
            if child:HasClass("directorScreenEdge") then
                child:SetClass("lit", lit)
            end
        end
    end
    local face = g.tabFace
    if face ~= nil and face.valid then
        face:SetClass("lit", lit)
    end
end

--- The band under the windows: GameHud puts it straight before the
--- documents layer. Only its edge takes the mouse.
--- @return Panel
function DirectorScreen.CreateLayer()
    g.signature = nil
    --the band's grey over the art, so the art only partly shows through. It is
    --the art's child: a sibling drawn after it still ends up under the image.
    g.coverVeil = gui.Panel{
        floating = true,
        halign = "left",
        valign = "top",
        width = "100%",
        height = "100%",
        bgimage = "panels/square.png",
        interactable = false,
    }
    --the cover's art, under everything else on the band (Layout crops it).
    g.cover = gui.Panel{
        classes = {"collapsed"},
        floating = true,
        halign = "left",
        valign = "top",
        width = "100%",
        height = "100%",
        bgimage = "panels/square.png",
        interactable = false,
        children = {g.coverVeil},
    }
    g.band = gui.Panel{
        classes = {"directorScreenBand", "collapsed"},
        halign = "left",
        valign = "top",
        width = 1,
        height = "100%",
        bgimage = "panels/square.png",
        interactable = false,
        flow = "none",
        children = {
            g.cover,
            --the edge: a thin line, with a wider grip over it.
            gui.Panel{
                classes = {"directorScreenEdge"},
                floating = true,
                halign = "left",
                valign = "top",
                width = 2,
                height = "100%",
                bgimage = "panels/square.png",
                interactable = false,
            },
            gui.Panel(ResizeEvents{
                classes = {"directorScreenGrip"},
                create = function(element)
                    g.grip = element
                    element.interactable = not g.passing
                end,
                floating = true,
                halign = "left",
                valign = "top",
                x = -GRIP_WIDTH / 2,
                width = GRIP_WIDTH,
                height = "100%",
                bgimage = "panels/square.png",
                bgcolor = "clear",
                swallowPress = true,
                hoverCursor = "horizontal-expand",
                hover = function(element)
                    SetLit(true)
                end,
                dehover = function(element)
                    SetLit(false)
                end,
            }),
            gui.Panel{
                floating = true,
                halign = "left",
                valign = "top",
                x = 18,
                y = 14,
                width = "auto",
                height = "auto",
                flow = "horizontal",
                interactable = false,
                children = {
                    gui.Panel{
                        bgimage = "phosphor/eye-slash.png",
                        bgcolor = "#ffffff70",
                        width = 16,
                        height = 16,
                        valign = "center",
                        rmargin = 6,
                        interactable = false,
                    },
                    gui.Label{
                        classes = {"directorScreenCaption"},
                        text = "Director's Screen",
                        valign = "center",
                        interactable = false,
                    },
                },
            },
        },
    }
    g.layer = gui.Panel{
        id = "directorScreenLayer",
        styles = ThemeEngine.MergeTokens(g_styles),
        width = "100%",
        height = "100%",
        flow = "none",
        interactable = false,
        children = {g.band},
        create = function(element)
            Layout(true)
        end,
    }
    return g.layer
end

--- The tab and the drop hint, over the windows: GameHud puts it straight
--- after the tabletop's button layer. Only the tab takes the mouse.
--- @return Panel
function DirectorScreen.CreateTabLayer()
    g.signature = nil
    --The tab is two panels. The engine never moves the panel being dragged
    --(SheetPanel skips its position while it is _draggingPanel), so a tab
    --grabbed and dragged would stay behind until released. The grab area
    --(g.tab) is invisible; what is seen is g.tabFace, which takes no mouse,
    --is never dragged, and so follows the edge as Layout moves it.
    g.tabFace = gui.Panel{
        classes = {"directorScreenTabFace", "collapsed"},
        halign = "left",
        valign = "top",
        width = TAB_WIDTH,
        height = TAB_HEIGHT,
        bgimage = "panels/square.png",
        --rounded on the left only: its right side runs into the divider.
        cornerRadius = {x1 = 6, y1 = 0, x2 = 0, y2 = 6},
        interactable = false,
    }
    g.tab = gui.Panel(ResizeEvents{
        classes = {"directorScreenTab", "collapsed"},
        halign = "left",
        valign = "top",
        width = TAB_WIDTH,
        height = TAB_HEIGHT,
        bgimage = "panels/square.png",
        swallowPress = true,
        hoverCursor = "horizontal-expand",
        flow = "none",
        create = function(element)
            element.interactable = not g.passing
        end,
        hover = function(element)
            SetLit(true)
        end,
        dehover = function(element)
            SetLit(false)
        end,
        click = function(element)
            if IsOpen() then
                Close()
            else
                Open()
            end
        end,
    })
    g.hintLabel = gui.Label{
        classes = {"directorScreenHintLabel"},
        text = "",
        interactable = false,
    }
    g.hint = gui.Panel{
        classes = {"directorScreenHint", "collapsed"},
        halign = "left",
        valign = "top",
        width = "auto",
        height = "auto",
        hpad = 10,
        vpad = 6,
        bgimage = "panels/square.png",
        borderWidth = 1,
        cornerRadius = 6,
        flow = "horizontal",
        interactable = false,
        children = {
            gui.Panel{
                classes = {"directorScreenHintIcon"},
                bgimage = "phosphor/eye-slash.png",
                bgcolor = "#ffffffe0",
                width = 16,
                height = 16,
                valign = "center",
                rmargin = 8,
                interactable = false,
            },
            g.hintLabel,
        },
    }
    g.tabLayer = gui.Panel{
        id = "directorScreenTabLayer",
        styles = ThemeEngine.MergeTokens(g_styles),
        width = "100%",
        height = "100%",
        flow = "none",
        interactable = false,
        children = {g.tabFace, g.tab, g.hint},
        create = function(element)
            Layout(true)
        end,
    }
    return g.tabLayer
end

--While the Director drags an item: the band lights when the drop would put
--it behind the screen, the edge turns the share colour when the drop would
--share it, and a note by the mouse says which.
local function UpdateDropHint()
    local hint = g.hint
    if hint == nil or not hint.valid then
        return
    end
    local drag = g.drag
    local text = nil
    local sharing = false
    local over = false
    --with the screen closed (or gone under a maximized window), only
    --something new is shown: it will be shared.
    if drag ~= nil and Active() and (Shown() or drag.fresh) then
        local member = drag.key ~= nil and g.members[drag.key] == true
        over = Shown() and drag.centre >= Edge()
        if drag.fresh then
            if over then
                text = "Release to keep it behind the screen"
            else
                text = "Release to share it with the players"
                sharing = true
            end
        elseif over and not member then
            if drag.shared then
                text = "Release to hide it from the players"
            else
                text = "Release to keep it behind the screen"
            end
        elseif member and not over then
            text = "Release to share it with the players"
            sharing = true
        end
    end

    local band = g.band
    if band ~= nil and band.valid then
        band:SetClass("dropTarget", text ~= nil and not sharing)
        for _, child in ipairs(band.children) do
            if child:HasClass("directorScreenEdge") then
                child:SetClass("dropTarget", text ~= nil and not sharing)
                child:SetClass("sharing", sharing)
            end
        end
    end

    hint:SetClass("collapsed", text == nil)
    if text == nil then
        return
    end
    hint:SetClass("sharing", sharing)
    for _, child in ipairs(hint.children) do
        if child:HasClass("directorScreenHintIcon") then
            child.bgimage = cond(sharing, "phosphor/share-network.png", "phosphor/eye-slash.png")
        end
    end
    if g.hintLabel ~= nil and g.hintLabel.valid then
        g.hintLabel.text = text
    end
    local mx, my = MouseOnTable()
    local w, h = TableSize()
    hint.x = math.max(0, math.min(mx + 22, w - 320))
    hint.y = math.max(0, math.min(my + 26, h - 40))
end

--The grip and the tab catch the mouse, so to the engine a drag over them is
--over UI, not the table: a map row's window preview (or a card's) would drop
--back to the row while crossing the edge. Any drag reporting in makes them
--let the mouse through until a moment after the last report.
--- @param passing boolean
local function SetPassing(passing)
    if passing == g.passing then
        return
    end
    g.passing = passing
    for _, panel in ipairs({g.grip, g.tab}) do
        if panel ~= nil and panel.valid then
            panel.interactable = not passing
        end
    end
end

local function LetDragsThrough()
    g.passUntil = dmhub.Time() + 0.3
    SetPassing(true)
end

----------------------------------------------------------------------
--The items.

--- Called from an item's dragging event each frame: x is where its left
--- edge would land and width its width (documents-layer units). A nil key
--- (the drag is going somewhere other than the table) clears the hint.
--- @param key string|nil
--- @param x number
--- @param width number
function DirectorScreen.ItemDragging(key, x, width)
    LetDragsThrough()
    if key == nil or not Active() then
        if g.drag ~= nil then
            g.drag = nil
            UpdateDropHint()
        end
        return
    end
    local drag = g.drag
    if drag == nil or drag.key ~= key then
        local item = FindItem(key)
        drag = {key = key, shared = item ~= nil and item.store.state() ~= nil}
        g.drag = drag
    end
    drag.centre = x + width / 2
    drag.seen = dmhub.Time()
    UpdateDropHint()
end

--- Called each frame while the Director drags something new over the table
--- from a panel (a map, scene or character row, a token out of its map): x
--- is where the left edge of what the drop makes would land and width its
--- width (documents-layer units). It shows the drop's hint, as for an item.
--- @param x number
--- @param width number
function DirectorScreen.NewItemDragging(x, width)
    LetDragsThrough()
    if not Active() then
        return
    end
    local drag = g.drag
    if drag == nil or not drag.fresh then
        drag = {fresh = true}
        g.drag = drag
    end
    drag.centre = x + width / 2
    drag.seen = dmhub.Time()
    UpdateDropHint()
end

--Puts an item behind the screen (private) or out on the table (shared with
--every player, even one held back), changing its share to match.
--- @param item DirectorScreenItem
--- @param behind boolean
local function SetBehind(item, behind)
    local key = item.key
    g.grace[key] = dmhub.Time() + GRACE_SECONDS
    g.heldBack[key] = nil
    if behind then
        g.members[key] = true
        if item.store.state() ~= nil then
            item.store.unshare()
            item.changed()
        end
    else
        g.members[key] = nil
        if item.store.state() == nil then
            item.store.share()
            item.changed()
        end
    end
    Tabletop.SaveLayoutSoon()
end

--- Called when the Director drops an item on the table, after its new spot
--- is recorded. Moving it onto the screen stops sharing it; moving it off
--- shares it with every player. A nil key just ends the drag's hint.
--- @param key string|nil
function DirectorScreen.ItemDropped(key)
    SetPassing(false)
    if g.drag ~= nil then
        g.drag = nil
        UpdateDropHint()
    end
    if key == nil or not Active() then
        return
    end
    local item = FindItem(key)
    if item == nil or item.rect == nil then
        return
    end
    g.known = g.known or {}
    g.known[key] = true
    local onScreen = OnScreen(item.rect)
    if onScreen == (g.members[key] == true) then
        return
    end
    SetBehind(item, onScreen)
end

--The rule for an item a drop made or moved (ItemPlaced), once it is on the
--table: on the screen it is private, anywhere else (or with the screen
--closed) it is shared.
--- @param item DirectorScreenItem
local function SettlePlaced(item)
    g.placed[item.key] = nil
    g.known = g.known or {}
    g.known[item.key] = true
    if item.rect == nil then
        return
    end
    SetBehind(item, OnScreen(item.rect))
end

--- Called when the Director drops something onto the table that makes an
--- item there or moves one (a map, scene or journal row, a character or
--- bestiary row, a token out of its map, files from the desktop). Dropped on
--- the screen it is private; dropped anywhere else it is shared with every
--- player. The item may appear later (a creature's card waits for the new
--- character), so the screen waits a while for it. With the screen closed
--- every such drop is shared.
--- @param key string|nil
function DirectorScreen.ItemPlaced(key)
    SetPassing(false)
    if g.drag ~= nil then
        g.drag = nil
        UpdateDropHint()
    end
    if key == nil or not Active() then
        return
    end
    g.placed[key] = dmhub.Time() + PLACED_SECONDS
    local item = FindItem(key)
    if item ~= nil then
        SettlePlaced(item)
    end
end

--- Whether an item is hidden because it is on the closed screen (or on the
--- screen while a maximized window hides it).
--- @param key string|nil
--- @return boolean
function DirectorScreen.IsStowed(key)
    return key ~= nil and g.members[key] == true and not Shown() and dmhub.isDM
end

--- Opens the screen if an item on it is hidden by its being closed: the
--- Director went to it another way (focusing its map window). Hidden only
--- under a maximized window, it is already open and shows again on restore.
--- @param key string|nil
function DirectorScreen.Reveal(key)
    if DirectorScreen.IsStowed(key) and not IsOpen() then
        Open()
        for _, item in ipairs(Tabletop.ScreenItems()) do
            item.stow(false)
        end
    end
end

--- Whether the screen is open (not closed to its tab).
--- @return boolean
function DirectorScreen.IsOpen()
    return IsOpen()
end

--- Opens (true) or closes (false) the screen.
--- @param open boolean
function DirectorScreen.SetOpen(open)
    if open then
        Open()
    else
        Close()
    end
end

--- The screen's width as a fraction of the table (0 = closed), for tests.
--- @param fraction number
function DirectorScreen.SetFraction(fraction)
    if fraction > 0 then
        g.lastFraction = fraction
    end
    SetFraction(fraction)
    Tabletop.SaveLayoutSoon()
end

--- @param set table<string, boolean>
--- @return string[]
local function SortedKeys(set)
    local result = {}
    for key, _ in pairs(set) do
        result[#result+1] = key
    end
    table.sort(result)
    return result
end

--- The keys of the items on the screen, for tests.
--- @return string[]
function DirectorScreen.Members()
    return SortedKeys(g.members)
end

--- The keys of the items held back on the table (unshared, faded), for tests.
--- @return string[]
function DirectorScreen.HeldBack()
    return SortedKeys(g.heldBack)
end

--Shows an item as its side says: no share button on the screen, and faded
--while held back on the table and not focused. A maximized window is on
--neither side: it keeps its share button and is never faded.
--- @param item DirectorScreenItem
--- @param faded boolean
local function Present(item, faded)
    local behind = g.members[item.key] == true and Shown() and not item.maximized
    faded = faded and not item.maximized
    local button = item.shareButton()
    if button ~= nil and button.valid and button:HasClass("collapsed") ~= behind then
        button:SetClass("collapsed", behind)
    end
    item.showBehind(behind)
    local panel = item.panel()
    if panel ~= nil and panel.valid and g.faded[panel] ~= faded then
        g.faded[panel] = faded
        panel.selfStyle.groupOpacity = cond(faded, HELD_BACK_OPACITY, 1)
    end
end

--The focused item: the one the Director pressed or raised last (the
--engine's activationOrder, as the Ctrl+Tab switcher uses).
--- @param items DirectorScreenItem[]
--- @return string|nil
local function FocusedKey(items)
    local best, bestOrder = nil, 0
    for _, item in ipairs(items) do
        local panel = item.panel()
        if panel ~= nil and panel.valid and panel.activationOrder > bestOrder then
            best, bestOrder = item.key, panel.activationOrder
        end
    end
    return best
end

--Applies the side rule to one item (see the top of the file). first: the
--look right after the layout loaded, when nothing is new.
--- @param item DirectorScreenItem
--- @param first boolean
--- @return boolean changed whether the saved layout changed
local function KeepToItsSide(item, first)
    local key = item.key
    local rect = item.rect
    local open = Shown()
    local edge = Edge()
    local w = TableSize()
    local state = item.store.state()
    local isNew = not g.known[key] and not first
    g.known[key] = true

    if g.members[key] then
        if state ~= nil then
            --shared another way: nothing on the screen is shared, so it
            --comes off it, to just left of the edge.
            g.members[key] = nil
            if rect ~= nil then
                item.move(math.min(edge, w - RailReserve()) - rect.w - 16)
            end
            return true
        end
        if open and rect ~= nil and Centre(rect) < edge then
            --the screen narrowed under it: it moves along with the edge,
            --wholly onto the screen when it fits.
            item.move(math.max(edge - rect.w / 2 + 8, math.min(edge + 12, w - rect.w)))
            return true
        end
        return false
    end

    if OnScreen(rect) then
        --rect is not nil here (OnScreen checked it).
        --- @cast rect -nil
        if state == nil then
            --lying on the screen, unshared (opened there): it is behind it.
            g.members[key] = true
            g.heldBack[key] = nil
            g.pushed[key] = nil
            return true
        end
        if g.pushed[key] then
            --moved off last time and still on it: the screen is too wide
            --for it to get off, so it goes behind it.
            g.pushed[key] = nil
            SetBehind(item, true)
            return true
        end
        --shared, and the screen widened over it (or it opened there): off it
        --goes, wholly when it fits.
        g.pushed[key] = true
        item.move(math.min(edge - rect.w / 2 - 8, math.max(edge - 12 - rect.w, 0)))
        return true
    end
    g.pushed[key] = nil

    if isNew then
        --new on the table: shared, unless it is one the saved layout held back.
        if state == nil and not g.heldBack[key] then
            SetBehind(item, false)
            return true
        end
        return false
    end
    --on the table, its share is the Director's: unshared any way (its share
    --button, Map Settings) it is held back; shared again, it is not.
    local held = state == nil
    if (g.heldBack[key] == true) ~= held then
        g.heldBack[key] = held or nil
        return true
    end
    return false
end

--A look over the items, ten times a second: each is kept to its side's rule
--(KeepToItsSide), shown to match (Present), and hidden on the closed screen.
local function LookOverItems()
    local items = Tabletop.ScreenItems()
    local now = dmhub.Time()
    local open = Shown()
    local first = g.known == nil
    if first then
        g.known = {}
    end
    local present = {}
    local changed = false
    for key, deadline in pairs(g.placed) do
        if deadline < now then
            g.placed[key] = nil
        end
    end
    for _, item in ipairs(items) do
        local key = item.key
        present[key] = true
        --a drop's item, arrived: the drop's rule, not a new item's.
        if g.placed[key] ~= nil then
            SettlePlaced(item)
        end
        --left alone while dragged, and while a share it was just given is on
        --its way back from the server.
        local dragged = g.drag ~= nil and g.drag.key == key
        if not dragged and (g.grace[key] or 0) < now then
            if KeepToItsSide(item, first) then
                changed = true
            end
        end
        item.stow(g.members[key] == true and not open)
    end
    local focused = FocusedKey(items)
    for _, item in ipairs(items) do
        Present(item, g.heldBack[item.key] == true and item.key ~= focused)
    end
    for _, set in ipairs({g.members, g.heldBack}) do
        for key, _ in pairs(set) do
            if not present[key] then
                set[key] = nil
                changed = true
            end
        end
    end
    for key, _ in pairs(g.grace) do
        if not present[key] then
            g.grace[key] = nil
        end
    end
    for key, _ in pairs(g.pushed) do
        if not present[key] then
            g.pushed[key] = nil
        end
    end
    if changed then
        Tabletop.SaveLayoutSoon()
    end
end

--- The tabletop's think calls this (every 0.05 s).
function DirectorScreen.Sync()
    Layout()
    if g.passing and dmhub.Time() > g.passUntil then
        SetPassing(false)
    end
    if g.drag ~= nil and dmhub.Time() - (g.drag.seen or 0) > 0.3 then
        g.drag = nil
        UpdateDropHint()
    end
    if not Active() then
        return
    end
    local now = dmhub.Time()
    if now < g.nextLook then
        return
    end
    g.nextLook = now + 0.1
    LookOverItems()
end

--- The screen's part of the saved table layout.
--- @return table
function DirectorScreen.Save()
    return {
        fraction = g.fraction,
        lastFraction = g.lastFraction,
        members = DirectorScreen.Members(),
        heldBack = DirectorScreen.HeldBack(),
    }
end

--- Restores the screen from a saved table layout (nil: a new table).
--- @param saved table|nil
function DirectorScreen.Load(saved)
    g.members = {}
    g.heldBack = {}
    g.known = nil
    g.pushed = {}
    g.grace = {}
    g.placed = {}
    g.drag = nil
    g.resize = nil
    g.fraction = DEFAULT_FRACTION
    g.lastFraction = DEFAULT_FRACTION
    if type(saved) == "table" then
        g.fraction = math.max(0, math.min(1, tonumber(saved.fraction) or DEFAULT_FRACTION))
        g.lastFraction = math.max(0.05, math.min(1, tonumber(saved.lastFraction) or DEFAULT_FRACTION))
        for _, field in ipairs({"members", "heldBack"}) do
            local list = saved[field]
            if type(list) == "table" then
                for _, key in ipairs(list) do
                    if type(key) == "string" then
                        g[field][key] = true
                    end
                end
            end
        end
    end
    g.signature = nil
    Layout()
end
