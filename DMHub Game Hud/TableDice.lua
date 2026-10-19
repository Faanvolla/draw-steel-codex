local mod = dmhub.GetModLoading()

--Table dice (TABLE_DICE_BRIEF.md at the repo root): 3D dice the Director puts
--on the tabletop that stay there. Anyone can click one to roll it in place, or
--drag it and let go fast to throw it; it rests on whatever face it lands on.
--No chat message: it is a fidget roll.
--
--The engine draws, picks and animates each die (dice.CreateTableDie,
--TableDieLua). This file decides which dice exist and keeps everyone in step:
--  - Dice out on the table live in the shared document "tabledice". A roll is
--    written there as a small record (from, to, face, seed...) that the other
--    clients replay; a late joiner just sees the resting face.
--  - Dice behind the Director's Screen are the Director's alone: they live in
--    a per-game preference, so players' machines never receive them, and show
--    only while the screen is open.
--  - Spots are kept as fractions of the table, so every screen puts a die in
--    the same place on its own table.
--The Director adds dice from the dice button on the table (bottom left) or on
--the Director's Screen (beside its caption); right-click a die to roll or
--remove it.

TableDice = {}

local DOC_ID = "tabledice"

--The Director's private dice, as JSON {dice = {[id] = record}}.
local g_privateSetting = setting{
    id = "tabledice:private",
    storage = "pergamepreference",
    default = "",
}

--The dice set new dice wear ("" = the default set).
local g_setSetting = setting{
    id = "tabledice:set",
    storage = "pergamepreference",
    default = "",
}

--- @class TableDieRecord
--- @field faces number
--- @field model string
--- @field fx number spot, as a fraction of the table's width
--- @field fy number spot, as a fraction of the table's height
--- @field face number
--- @field yaw number
--- @field pick number
--- @field seq number bumped on every change, so clients see what is new
--- @field roll nil|table the latest roll, in table fractions
--- @field rollAt nil|number dmhub.serverTime when it started
--- @field rollBy nil|string who rolled it

local g = {
    --id -> {die = TableDieLua, seq = number, private = boolean}
    handles = {},
    layer = nil,
    tableButton = nil,
    menuAnchor = nil,
    --ids of rolls this client started and wrote, so it does not replay them.
    ownSeq = {},
}

----------------------------------------------------------------------
--Where things are: table fractions <-> screen pixels (top-left origin).

--- @return number w, number h the table's size (documents-layer units)
local function TableSize()
    local rect = Tabletop.LayerRect()
    return rect.w, rect.h
end

--- @return number scale layer units per screen pixel
--- @return number top the table's top, in screen pixels
local function Mapping()
    local _, h = TableSize()
    local screen = dmhub.screenDimensions
    local below = dmhub.screenDimensionsBelowTitlebar
    if below.y <= 0 then
        return 1, 0
    end
    return h / below.y, screen.y - below.y
end

--- @return number fx, number fy
local function ScreenToTable(px, py)
    local w, h = TableSize()
    local scale, top = Mapping()
    return (px * scale) / math.max(1, w), ((py - top) * scale) / math.max(1, h)
end

--- @return number px, number py
local function TableToScreen(fx, fy)
    local w, h = TableSize()
    local scale, top = Mapping()
    return (fx * w) / scale, top + (fy * h) / scale
end

--Throws stay on the table (screen pixels).
--- @return number x1, number y1, number x2, number y2
local function TableBounds()
    local w, h = TableSize()
    local scale, top = Mapping()
    return 0, top, w / scale, top + h / scale
end

----------------------------------------------------------------------
--The two stores.

local function SharedDoc()
    return mod:GetDocumentSnapshot(DOC_ID)
end

--- @return table<string, TableDieRecord>
local function SharedDice()
    local doc = SharedDoc()
    local dice = doc.data.dice
    if type(dice) ~= "table" then
        return {}
    end
    return dice
end

--- @return table<string, TableDieRecord>
local function PrivateDice()
    local text = g_privateSetting:Get()
    if type(text) ~= "string" or text == "" then
        return {}
    end
    local parsed = dmhub.FromJson(text)
    if parsed == nil or type(parsed.result) ~= "table" or type(parsed.result.dice) ~= "table" then
        return {}
    end
    return parsed.result.dice
end

--- @param dice table<string, TableDieRecord>
local function SavePrivate(dice)
    g_privateSetting:Set(dmhub.ToJson({dice = dice}))
end

--Changes one die's record in its store: fn(record) edits it in place, or
--returns false to remove it.
--- @param id string
--- @param private boolean
--- @param description string
--- @param fn fun(record: TableDieRecord): nil|boolean
local function Modify(id, private, description, fn)
    if private then
        local dice = PrivateDice()
        local record = dice[id]
        if record == nil then
            return
        end
        if fn(record) == false then
            dice[id] = nil
        end
        SavePrivate(dice)
        return
    end
    local doc = SharedDoc()
    doc:BeginChange()
    doc.data.dice = doc.data.dice or {}
    local record = doc.data.dice[id]
    if record ~= nil then
        if fn(record) == false then
            doc.data.dice[id] = nil
        end
    end
    doc:CompleteChange(description, {undoable = false})
end

--Adds a die to a store.
--- @param id string
--- @param private boolean
--- @param record TableDieRecord
local function Add(id, private, record)
    if private then
        local dice = PrivateDice()
        dice[id] = record
        SavePrivate(dice)
        return
    end
    local doc = SharedDoc()
    doc:BeginChange()
    doc.data.dice = doc.data.dice or {}
    doc.data.dice[id] = record
    doc:CompleteChange("Add a table die", {undoable = false})
end

--Moves a die from one store to the other (dragged across the screen's edge).
--- @param id string
--- @param toPrivate boolean
--- @param fx number
--- @param fy number
local function Transfer(id, toPrivate, fx, fy)
    local from = toPrivate and SharedDice() or PrivateDice()
    local record = from[id]
    if record == nil then
        return
    end
    local copy = DeepCopy(record) --[[@as TableDieRecord]]
    copy.fx, copy.fy = fx, fy
    copy.roll, copy.rollAt, copy.rollBy = nil, nil, nil
    copy.seq = (copy.seq or 0) + 1
    Modify(id, not toPrivate, "Move a table die", function() return false end)
    Add(id, toPrivate, copy)
end

----------------------------------------------------------------------
--What the Director's Screen means for a die.

--Whether a spot (table fractions) is behind the open Director's Screen.
local function BehindScreen(fx)
    if not dmhub.isDM or rawget(_G, "DirectorScreen") == nil then
        return false
    end
    local edge = DirectorScreen.EdgeX()
    if edge == nil then
        return false
    end
    local w = TableSize()
    return fx * w >= edge
end

----------------------------------------------------------------------
--The menus.

local function MenuAnchor()
    if g.menuAnchor == nil or not g.menuAnchor.valid then
        if g.layer == nil or not g.layer.valid then
            return nil
        end
        g.menuAnchor = gui.Panel{
            width = 1,
            height = 1,
            floating = true,
            interactable = false,
        }
        g.layer:AddChild(g.menuAnchor)
        g.menuAnchor.popupPositioning = "mouse"
    end
    return g.menuAnchor
end

local function CloseMenu()
    local anchor = g.menuAnchor
    if anchor ~= nil and anchor.valid then
        anchor.popup = nil
    end
end

--- Puts a new die on the table, resting showing its highest face.
--- @param faces number
--- @param px number screen pixels
--- @param py number
--- @param private boolean behind the Director's Screen
function TableDice.AddDie(faces, px, py, private)
    if not dmhub.isDM then
        return
    end
    local fx, fy = ScreenToTable(px, py)
    Add(dmhub.GenerateGuid(), private, {
        faces = faces,
        model = g_setSetting:Get() or "",
        fx = fx,
        fy = fy,
        --a d10 reads 0-9 on some sets: the engine settles on its real face.
        face = faces,
        yaw = math.random(-20, 20),
        pick = 0,
        seq = 1,
    })
end

--A die's right-click menu (Director only): roll it, or take it away.
--- @param id string
local function ShowDieMenu(id)
    local handle = g.handles[id]
    local anchor = MenuAnchor()
    if handle == nil or anchor == nil or not dmhub.isDM then
        return
    end
    local private = handle.private
    anchor.popup = gui.ContextMenu{
        entries = {
            {
                text = "Remove Die",
                click = function()
                    CloseMenu()
                    Modify(id, private, "Remove a table die", function() return false end)
                end,
            },
        },
    }
end

----------------------------------------------------------------------
--The table items drawer (TABLE_DICE_BRIEF.md, "The table items drawer"):
--slides up from the bottom of the table. Categories down its left side are by
--what a thing IS; search covers all of them; Recent and Favourites follow the
--Director. Click a tile to drop it near where the drawer opened, or drag it to
--a spot. Only dice are built so far: every other tile shows as coming soon.

local DRAWER_HEIGHT = 310
--past the left icon rail.
local DRAWER_LEFT = 64
local TILE_WIDTH = 104
local TILE_HEIGHT = 86
local RECENT_MAX = 8

--What the Director placed lately, and starred: item ids, per user.
local g_recentSetting = setting{
    id = "tableitems:recent",
    storage = "preference",
    default = "",
}
local g_favouritesSetting = setting{
    id = "tableitems:favourites",
    storage = "preference",
    default = "",
}

--- @param s table a setting holding a JSON list of item ids
--- @return string[]
local function ReadIds(s)
    local text = s:Get()
    if type(text) ~= "string" or text == "" then
        return {}
    end
    local parsed = dmhub.FromJson(text)
    if parsed == nil or type(parsed.result) ~= "table" then
        return {}
    end
    local result = {}
    for _, id in ipairs(parsed.result) do
        if type(id) == "string" then
            result[#result+1] = id
        end
    end
    return result
end

--- @param s table
--- @param ids string[]
local function WriteIds(s, ids)
    s:Set(dmhub.ToJson(ids))
end

--A die placer: drop `faces` at (px, py) screen pixels.
--- @param faces number
--- @return fun(px: number, py: number, private: boolean)
local function DiePlacer(faces)
    return function(px, py, private)
        TableDice.AddDie(faces, px, py, private)
    end
end

--- @class TableItemDef
--- @field id string
--- @field name string
--- @field note nil|string
--- @field icon string
--- @field place nil|fun(px: number, py: number, private: boolean) nil = coming soon

--- @class TableItemCategory
--- @field id string
--- @field name string
--- @field icon string
--- @field test string what belongs here, in one line
--- @field items TableItemDef[]

--- @type TableItemCategory[]
local CATEGORIES = {
    {id = "dice", name = "Dice", icon = "phosphor/dice-five.png", test = "Something you roll.", items = {
        {id = "d20", name = "d20", note = "Roll anywhere", icon = "phosphor/polygon.png", place = DiePlacer(20)},
        {id = "2d10", name = "2d10", note = "Power roll pair", icon = "phosphor/dice-two.png", place = function(px, py, private)
            TableDice.AddDie(10, px - 34, py, private)
            TableDice.AddDie(10, px + 34, py, private)
        end},
        {id = "d6", name = "d6", icon = "phosphor/dice-six.png", place = DiePlacer(6)},
        {id = "d3", name = "d3", icon = "phosphor/dice-three.png", place = DiePlacer(3)},
        {id = "d4", name = "d4", icon = "phosphor/triangle.png", place = DiePlacer(4)},
        {id = "d8", name = "d8", icon = "phosphor/diamond.png", place = DiePlacer(8)},
        {id = "d10", name = "d10", icon = "phosphor/polygon.png", place = DiePlacer(10)},
        {id = "d12", name = "d12", icon = "phosphor/polygon.png", place = DiePlacer(12)},
        {id = "fistful", name = "Fistful", note = "Any mix", icon = "phosphor/dice-five.png"},
        {id = "spinner", name = "Spinner", note = "Your own labels", icon = "phosphor/chart-pie-slice.png"},
    }},
    {id = "trinkets", name = "Trinkets", icon = "phosphor/diamond.png", test = "Something you move or flip; it keeps no number.", items = {
        {id = "coin", name = "Coin", note = "Flip it", icon = "phosphor/coin.png"},
        {id = "gem", name = "Gem", icon = "phosphor/diamond.png"},
        {id = "skull", name = "Skull", icon = "phosphor/skull.png"},
        {id = "key", name = "Key", icon = "phosphor/key.png"},
        {id = "standee", name = "Standee", note = "Any character", icon = "phosphor/user.png"},
        {id = "pointer", name = "Pointer", icon = "phosphor/arrow-fat-right.png"},
        {id = "stamp", name = "Stamp", icon = "phosphor/stamp.png"},
        {id = "ruler", name = "Ruler", icon = "phosphor/ruler.png"},
    }},
    {id = "trackers", name = "Trackers", icon = "phosphor/plus-minus.png", test = "Something that holds a value people change.", items = {
        {id = "malice", name = "Malice", note = "Director's pool", icon = "phosphor/fire.png"},
        {id = "victories", name = "Victories", note = "Party", icon = "phosphor/trophy.png"},
        {id = "counter", name = "Counter", note = "Any name", icon = "phosphor/plus-minus.png"},
        {id = "sandtimer", name = "Sand timer", note = "Flip to start", icon = "phosphor/hourglass.png"},
        {id = "rounds", name = "Round tracker", icon = "phosphor/arrows-clockwise.png"},
        {id = "countdown", name = "Countdown", icon = "phosphor/timer.png"},
        {id = "initiative", name = "Initiative strip", icon = "phosphor/list-numbers.png"},
        {id = "vote", name = "Vote", note = "One token each", icon = "phosphor/check-square.png"},
    }},
    {id = "cards", name = "Cards", icon = "phosphor/cards.png", test = "Something you draw, flip or deal.", items = {
        {id = "deck", name = "Deck", note = "Draw and flip", icon = "phosphor/cards.png"},
        {id = "card", name = "Single card", icon = "phosphor/cards-three.png"},
        {id = "hand", name = "Hand", note = "Deal to a player", icon = "phosphor/hand.png"},
    }},
    {id = "handouts", name = "Handouts", icon = "phosphor/scroll.png", test = "Something people read or look at.", items = {
        {id = "picture", name = "Picture", icon = "phosphor/image.png"},
        {id = "letter", name = "Letter", icon = "phosphor/envelope-simple.png"},
        {id = "mapscrap", name = "Map scrap", icon = "phosphor/map-trifold.png"},
        {id = "sticky", name = "Sticky note", icon = "phosphor/note.png"},
        {id = "facedown", name = "Face-down", note = "Flip to reveal", icon = "phosphor/eye-slash.png"},
        {id = "journalpage", name = "Journal page", icon = "phosphor/book-open.png"},
    }},
    {id = "buttons", name = "Buttons", icon = "phosphor/cursor-click.png", test = "Something you press to make the app do something.", items = {
        {id = "soundpad", name = "Sound pad", note = "From the soundboard", icon = "phosphor/speaker-high.png"},
        {id = "script", name = "Script button", icon = "phosphor/code.png"},
        {id = "musicbox", name = "Music box", icon = "phosphor/music-notes.png"},
        {id = "starttimer", name = "Start timer", icon = "phosphor/timer.png"},
    }},
    {id = "zones", name = "Zones", icon = "phosphor/frame-corners.png", test = "An area other things go in.", items = {
        {id = "dicetray", name = "Dice tray", note = "Rolls land inside", icon = "phosphor/tray.png"},
        {id = "playmat", name = "Play mat", icon = "phosphor/squares-four.png"},
        {id = "spotlight", name = "Spotlight", note = "Dims the rest", icon = "phosphor/sun.png"},
        {id = "frame", name = "Frame", note = "Group things", icon = "phosphor/frame-corners.png"},
    }},
}

--- @param id string
--- @return nil|TableItemDef
local function FindTableItem(id)
    for _, cat in ipairs(CATEGORIES) do
        for _, item in ipairs(cat.items) do
            if item.id == id then
                return item
            end
        end
    end
    return nil
end

--Quiet raised hovers, no accent fills (the house style for rows and tiles).
local g_drawerStyles = {
    {selectors = {"tableDrawer"}, bgcolor = "@bg", borderColor = "@border", borderWidth = 1, cornerRadius = 10},
    {selectors = {"tableDrawerDivider"}, bgcolor = "@border"},
    {selectors = {"tableDrawerCat"}, bgcolor = "clear", cornerRadius = 6},
    {selectors = {"tableDrawerCat", "hover"}, bgcolor = "@bgRaised"},
    {selectors = {"tableDrawerCat", "selected"}, bgcolor = "@bgRaised"},
    {selectors = {"tableDrawerCatLabel"}, color = "@fg", fontSize = 14, width = "auto", height = "auto"},
    {selectors = {"tableDrawerCatLabel", "parent:selected"}, color = "@fgStrong"},
    {selectors = {"tableDrawerCatIcon"}, bgcolor = "@fgMuted"},
    {selectors = {"tableDrawerCatIcon", "parent:selected"}, bgcolor = "@fgStrong"},
    {selectors = {"tableDrawerTile"}, bgcolor = "@bgAlt", borderColor = "@border", borderWidth = 1, cornerRadius = 8},
    {selectors = {"tableDrawerTile", "hover"}, bgcolor = "@bgRaised"},
    {selectors = {"tableDrawerTileIcon"}, bgcolor = "@fg"},
    {selectors = {"tableDrawerTileName"}, color = "@fgStrong", fontSize = 14, width = "auto", height = "auto", halign = "center"},
    {selectors = {"tableDrawerTileNote"}, color = "@fgMuted", fontSize = 11, width = "auto", height = "auto", halign = "center"},
    {selectors = {"tableDrawerTileIcon", "parent:soon"}, opacity = 0.4},
    {selectors = {"tableDrawerTileName", "parent:soon"}, opacity = 0.4},
    {selectors = {"tableDrawerTileNote", "parent:soon"}, opacity = 0.7},
    {selectors = {"tableDrawerText"}, color = "@fgMuted", fontSize = 12, width = "auto", height = "auto"},
    {selectors = {"tableDrawerToggle"}, bgcolor = "clear", cornerRadius = 6},
    {selectors = {"tableDrawerToggle", "hover"}, bgcolor = "@bgRaised"},
    {selectors = {"tableDrawerToggleLabel"}, color = "@fgMuted", fontSize = 12, width = "auto", height = "auto"},
    {selectors = {"tableDrawerToggleLabel", "parent:selected"}, color = "@fgStrong"},
    {selectors = {"tableDrawerToggleIcon"}, bgcolor = "@fgMuted"},
    {selectors = {"tableDrawerToggleIcon", "parent:selected"}, bgcolor = "@fgStrong"},
    {selectors = {"tableItemsButton"}, bgcolor = "@bg", borderColor = "@border", borderWidth = 1, cornerRadius = 8},
    {selectors = {"tableItemsButton", "hover"}, bgcolor = "@bgRaised"},
    {selectors = {"tableItemsButton", "selected"}, bgcolor = "@bgRaised", borderColor = "@fgMuted"},
    {selectors = {"tableItemsButtonIcon"}, bgcolor = "@fg"},
}

--The drawer while it exists. category is a category id, "recent" or
--"favourites"; private means clicked tiles land behind the Director's Screen.
local g_drawer = {
    --- @type Panel|nil
    panel = nil,
    --- @type Panel|nil
    grid = nil,
    --- @type Panel|nil
    side = nil,
    --- @type Panel|nil
    setRow = nil,
    --- @type Panel|nil
    title = nil,
    --- @type Panel|nil
    searchInput = nil,
    private = false,
    category = "dice",
    search = "",
    pinned = false,
    placed = 0,
}

--- @return boolean
function TableDice.DrawerOpen()
    return g_drawer.panel ~= nil and g_drawer.panel.valid and not g_drawer.panel:HasClass("collapsed")
end

local function CloseDrawer()
    if g_drawer.panel ~= nil and g_drawer.panel.valid then
        g_drawer.panel:SetClass("collapsed", true)
    end
    if g.tableButton ~= nil and g.tableButton.valid then
        g.tableButton:SetClass("selected", false)
    end
end

--Layer units to screen pixels (top-left origin).
local function LayerToScreen(x, y)
    local scale, top = Mapping()
    return x / scale, top + y / scale
end

--Where a clicked tile lands: above the drawer near its left, or just inside
--the Director's Screen when it was opened there; each a little further along
--so they don't pile up.
local function DropSpot()
    local w, h = TableSize()
    local step = (g_drawer.placed % 8) * 70
    g_drawer.placed = g_drawer.placed + 1
    local y = h - DRAWER_HEIGHT - 70
    local x = DRAWER_LEFT + 140 + step
    if g_drawer.private and rawget(_G, "DirectorScreen") ~= nil then
        local edge = DirectorScreen.EdgeX()
        if edge ~= nil then
            x = math.min(w - 80, edge + 110 + step)
        end
    end
    return LayerToScreen(x, y)
end

--- @param id string
local function NoteRecent(id)
    local result = {id}
    for _, other in ipairs(ReadIds(g_recentSetting)) do
        if other ~= id and #result < RECENT_MAX then
            result[#result+1] = other
        end
    end
    WriteIds(g_recentSetting, result)
end

--- @param id string
local function ToggleFavourite(id)
    local result = {}
    local found = false
    for _, other in ipairs(ReadIds(g_favouritesSetting)) do
        if other == id then
            found = true
        else
            result[#result+1] = other
        end
    end
    if not found then
        result[#result+1] = id
    end
    WriteIds(g_favouritesSetting, result)
end

--- @param item TableItemDef
--- @param px number
--- @param py number
--- @param private boolean
local function PlaceItem(item, px, py, private)
    if item.place == nil then
        return
    end
    item.place(px, py, private)
    NoteRecent(item.id)
    if not g_drawer.pinned then
        CloseDrawer()
    end
end

local RebuildDrawer

--- @param item TableItemDef
--- @return Panel
local function BuildTile(item)
    local soon = item.place == nil
    return gui.Panel{
        classes = {"tableDrawerTile", cond(soon, "soon", "ready")},
        bgimage = "panels/square.png",
        width = TILE_WIDTH,
        height = TILE_HEIGHT,
        hmargin = 4,
        vmargin = 4,
        flow = "vertical",
        swallowPress = true,
        draggable = not soon,
        hover = function(element)
            if soon then
                gui.Tooltip("Coming soon")(element)
            else
                gui.Tooltip("Click to add, or drag onto the table. Right-click to favourite.")(element)
            end
        end,
        click = function(element)
            if soon then
                return
            end
            local px, py = DropSpot()
            PlaceItem(item, px, py, g_drawer.private)
        end,
        rightClick = function(element)
            ToggleFavourite(item.id)
            RebuildDrawer()
        end,
        --dropped on the table: it goes there, private if behind the screen.
        drag = function(element)
            local mouse = dmhub.mouseScreenPosition
            local fx, fy = ScreenToTable(mouse.x, mouse.y)
            local _, h = TableSize()
            --let go over the drawer: nothing.
            if fy * h > h - DRAWER_HEIGHT - 12 then
                return
            end
            PlaceItem(item, mouse.x, mouse.y, BehindScreen(fx))
        end,
        gui.Panel{
            classes = {"tableDrawerTileIcon"},
            bgimage = item.icon,
            width = 28,
            height = 28,
            halign = "center",
            tmargin = 12,
            interactable = false,
        },
        gui.Label{
            classes = {"tableDrawerTileName"},
            text = item.name,
            tmargin = 6,
            interactable = false,
        },
        gui.Label{
            classes = {"tableDrawerTileNote"},
            text = cond(soon, "Coming soon", item.note or ""),
            interactable = false,
        },
    }
end

--What the drawer shows now: a search across everything, or one category.
--- @return TableItemDef[] items
--- @return string text the line above the tiles
local function ShownItems()
    if g_drawer.search ~= "" then
        local result = {}
        for _, cat in ipairs(CATEGORIES) do
            for _, item in ipairs(cat.items) do
                local text = string.lower(item.name .. " " .. (item.note or "") .. " " .. cat.name)
                if string.find(text, g_drawer.search, 1, true) ~= nil then
                    result[#result+1] = item
                end
            end
        end
        return result, cond(#result == 0, "Nothing matches.", "Results")
    end
    if g_drawer.category == "recent" or g_drawer.category == "favourites" then
        local recent = g_drawer.category == "recent"
        local result = {}
        for _, id in ipairs(ReadIds(cond(recent, g_recentSetting, g_favouritesSetting))) do
            local item = FindTableItem(id)
            if item ~= nil then
                result[#result+1] = item
            end
        end
        if recent then
            return result, cond(#result == 0, "Things you add show up here.", "What you added lately.")
        end
        return result, cond(#result == 0, "Right-click any tile to add it here.", "Your favourites.")
    end
    for _, cat in ipairs(CATEGORIES) do
        if cat.id == g_drawer.category then
            return cat.items, cat.test
        end
    end
    return {}, ""
end

RebuildDrawer = function()
    local grid = g_drawer.grid
    if grid == nil or not grid.valid then
        return
    end
    local items, text = ShownItems()
    local children = {}
    for _, item in ipairs(items) do
        children[#children+1] = BuildTile(item)
    end
    grid.children = children
    local title = g_drawer.title
    if title ~= nil and title.valid then
        title.text = text
    end
    local side = g_drawer.side
    if side ~= nil and side.valid then
        for _, row in ipairs(side.children) do
            local catid = nil
            pcall(function() catid = row.data.catid end)
            if catid ~= nil then
                row:SetClass("selected", g_drawer.search == "" and catid == g_drawer.category)
            end
        end
    end
    local setRow = g_drawer.setRow
    if setRow ~= nil and setRow.valid then
        setRow:SetClass("collapsed", g_drawer.category ~= "dice" or g_drawer.search ~= "")
    end
end

--- @param catid string
--- @param name string
--- @param icon string
--- @return Panel
local function CategoryRow(catid, name, icon)
    return gui.Panel{
        classes = {"tableDrawerCat"},
        bgimage = "panels/square.png",
        width = "100%",
        height = 26,
        flow = "horizontal",
        hpad = 8,
        borderBox = true,
        data = {catid = catid},
        click = function(element)
            g_drawer.category = catid
            g_drawer.search = ""
            local input = g_drawer.searchInput
            if input ~= nil and input.valid then
                input.text = ""
            end
            RebuildDrawer()
        end,
        gui.Panel{
            classes = {"tableDrawerCatIcon"},
            bgimage = icon,
            width = 16,
            height = 16,
            valign = "center",
            rmargin = 8,
            interactable = false,
        },
        gui.Label{
            classes = {"tableDrawerCatLabel"},
            text = name,
            valign = "center",
            interactable = false,
        },
    }
end

--- @return Panel
local function BuildDrawer()
    local sideRows = {
        CategoryRow("recent", "Recent", "phosphor/clock-counter-clockwise.png"),
        CategoryRow("favourites", "Favourites", "phosphor/star.png"),
        gui.Panel{
            classes = {"tableDrawerDivider"},
            bgimage = "panels/square.png",
            width = "100%",
            height = 1,
            vmargin = 4,
        },
    }
    for _, cat in ipairs(CATEGORIES) do
        sideRows[#sideRows+1] = CategoryRow(cat.id, cat.name, cat.icon)
    end
    g_drawer.side = gui.Panel{
        width = 168,
        height = "100%",
        flow = "vertical",
        pad = 10,
        borderBox = true,
        children = sideRows,
    }

    --the dice set new dice wear: only shown on the Dice category.
    local options = {}
    for _, entry in ipairs(dice.GetAvailableDice()) do
        local value = entry.value
        if value == "Default" then
            value = ""
        end
        options[#options+1] = {id = value, text = tostring(entry.text)}
    end
    g_drawer.setRow = gui.Panel{
        width = "auto",
        height = 26,
        flow = "horizontal",
        valign = "center",
        lmargin = 12,
        gui.Label{
            classes = {"tableDrawerText"},
            text = "Dice set",
            valign = "center",
            rmargin = 8,
        },
        gui.Dropdown{
            width = 180,
            height = 24,
            fontSize = 12,
            valign = "center",
            options = options,
            idChosen = g_setSetting:Get() or "",
            change = function(element)
                ---@cast element Dropdown
                g_setSetting:Set(element.idChosen or "")
            end,
        },
        --takes every die off the table (or from behind the screen).
        gui.Panel{
            classes = {"tableDrawerToggle"},
            bgimage = "panels/square.png",
            width = "auto",
            height = 26,
            hpad = 8,
            lmargin = 8,
            borderBox = true,
            flow = "horizontal",
            valign = "center",
            click = function(element)
                TableDice.ClearDice(g_drawer.private)
            end,
            hover = gui.Tooltip("Take every die off the table (or from behind the screen, when opened there)"),
            gui.Panel{
                classes = {"tableDrawerToggleIcon"},
                bgimage = "phosphor/trash.png",
                width = 14,
                height = 14,
                valign = "center",
                rmargin = 6,
                interactable = false,
            },
            gui.Label{
                classes = {"tableDrawerToggleLabel"},
                text = "Clear dice",
                valign = "center",
                interactable = false,
            },
        },
    }

    g_drawer.searchInput = gui.SearchInput{
        placeholderText = "Search everything",
        text = "",
        borderBox = true,
        width = 260,
        height = 24,
        valign = "center",
        editlag = 0.1,
        edit = function(element)
            g_drawer.search = string.lower(element.text or "")
            RebuildDrawer()
        end,
        change = function(element)
            g_drawer.search = string.lower(element.text or "")
            RebuildDrawer()
        end,
    }

    local pinToggle = gui.Panel{
        classes = {"tableDrawerToggle"},
        bgimage = "panels/square.png",
        width = "auto",
        height = 26,
        hpad = 8,
        borderBox = true,
        flow = "horizontal",
        valign = "center",
        halign = "right",
        click = function(element)
            g_drawer.pinned = not g_drawer.pinned
            element:SetClass("selected", g_drawer.pinned)
        end,
        hover = gui.Tooltip("Keep the drawer open after adding something"),
        gui.Panel{
            classes = {"tableDrawerToggleIcon"},
            bgimage = "phosphor/push-pin.png",
            width = 14,
            height = 14,
            valign = "center",
            rmargin = 6,
            interactable = false,
        },
        gui.Label{
            classes = {"tableDrawerToggleLabel"},
            text = "Keep open",
            valign = "center",
            interactable = false,
        },
    }

    local closeButton = gui.Panel{
        classes = {"tableDrawerToggle"},
        bgimage = "panels/square.png",
        width = 26,
        height = 26,
        valign = "center",
        halign = "right",
        lmargin = 4,
        click = function(element)
            CloseDrawer()
        end,
        hover = gui.Tooltip("Close"),
        gui.Panel{
            classes = {"tableDrawerToggleIcon"},
            bgimage = "phosphor/x.png",
            width = 14,
            height = 14,
            halign = "center",
            valign = "center",
            interactable = false,
        },
    }

    local header = gui.Panel{
        width = "100%",
        height = 30,
        flow = "horizontal",
        g_drawer.searchInput,
        g_drawer.setRow,
        pinToggle,
        closeButton,
    }

    g_drawer.title = gui.Label{
        classes = {"tableDrawerText"},
        text = "",
        tmargin = 8,
        bmargin = 4,
    }

    g_drawer.grid = gui.Panel{
        width = "100%",
        height = "100%-70",
        flow = "horizontal",
        wrap = true,
        vscroll = true,
        valign = "top",
    }

    local main = gui.Panel{
        width = "100%-169",
        height = "100%",
        flow = "vertical",
        pad = 12,
        borderBox = true,
        header,
        g_drawer.title,
        g_drawer.grid,
    }

    g_drawer.panel = gui.Panel{
        classes = {"tableDrawer", "collapsed"},
        bgimage = "panels/square.png",
        floating = true,
        halign = "left",
        valign = "bottom",
        x = DRAWER_LEFT,
        bmargin = 10,
        width = string.format("100%%-%d", DRAWER_LEFT + 16),
        height = DRAWER_HEIGHT,
        flow = "horizontal",
        swallowPress = true,
        g_drawer.side,
        gui.Panel{
            classes = {"tableDrawerDivider"},
            bgimage = "panels/square.png",
            width = 1,
            height = "100%",
        },
        main,
    }
    return g_drawer.panel
end

--- Opens the drawer, or closes it if it is already open from the same place.
--- private: tiles clicked in land behind the Director's Screen.
--- @param private boolean
function TableDice.ToggleDrawer(private)
    local panel = g_drawer.panel
    if not dmhub.isDM or panel == nil or not panel.valid then
        return
    end
    if TableDice.DrawerOpen() and g_drawer.private == private then
        CloseDrawer()
        return
    end
    g_drawer.private = private
    panel:SetClass("collapsed", false)
    panel:SetAsLastSibling()
    if g.tableButton ~= nil and g.tableButton.valid then
        g.tableButton:SetClass("selected", not private)
    end
    RebuildDrawer()
end

--- For tests: every die this client shows, as {id, faces, face, private, x, y}.
--- @return table[]
function TableDice.DebugDice()
    local result = {}
    for id, handle in pairs(g.handles) do
        result[#result+1] = {id = id, faces = handle.faces, face = handle.die.face, private = handle.private, x = handle.die.x, y = handle.die.y}
    end
    return result
end

--- Removes every die on the table (shared) or behind the screen (private).
--- @param private boolean
function TableDice.ClearDice(private)
    if private then
        SavePrivate({})
        return
    end
    local doc = SharedDoc()
    doc:BeginChange()
    doc.data.dice = {}
    doc:CompleteChange("Remove table dice", {undoable = false})
end

--- The dice button for the Director's Screen's caption row (DirectorScreen.lua).
--- @return Panel
function TableDice.CreateScreenButton()
    return gui.Panel{
        classes = {"tableDiceButton"},
        bgimage = "phosphor/package.png",
        bgcolor = "#ffffff70",
        width = 16,
        height = 16,
        valign = "center",
        lmargin = 10,
        swallowPress = true,
        hover = function(element)
            element.selfStyle.bgcolor = "#ffffffe0"
            gui.Tooltip("Table items: add things behind the screen")(element)
        end,
        dehover = function(element)
            element.selfStyle.bgcolor = "#ffffff70"
        end,
        click = function(element)
            TableDice.ToggleDrawer(true)
        end,
    }
end

----------------------------------------------------------------------
--Keeping the engine's dice in step with the stores.

--- @param id string
--- @param record TableDieRecord
--- @param private boolean
--- @return nil|{die: TableDieLua, seq: number, private: boolean}
local function BuildDie(id, record, private)
    local px, py = TableToScreen(record.fx or 0.5, record.fy or 0.5)
    local model = record.model --[[@as string|nil]]
    if model == "" then
        model = nil
    end
    local die = dice.CreateTableDie{
        faces = record.faces or 20,
        model = model,
        x = px,
        y = py,
        face = record.face,
        yaw = record.yaw or 0,
    }
    if die == nil then
        return nil
    end
    local handle = {die = die, seq = record.seq or 0, private = private, faces = record.faces, model = record.model}
    die:SetRest(px, py, record.face or 1, record.yaw or 0, record.pick or 0)
    die.callbacks = {
        onRoll = function(roll)
            local h = g.handles[id]
            if h == nil then
                return
            end
            local ffx, ffy = ScreenToTable(roll.fromx, roll.fromy)
            local tfx, tfy = ScreenToTable(roll.tox, roll.toy)
            local shared = {
                fromfx = ffx, fromfy = ffy, tofx = tfx, tofy = tfy,
                lift = roll.lift, face = roll.face, yaw = roll.yaw, pick = roll.pick,
                seed = roll.seed, duration = roll.duration,
            }
            Modify(id, h.private, "Roll a table die", function(r)
                r.fx, r.fy = tfx, tfy
                r.face, r.yaw, r.pick = roll.face, roll.yaw, roll.pick
                r.roll = shared
                r.rollAt = dmhub.serverTime
                r.rollBy = dmhub.userid
                r.seq = (r.seq or 0) + 1
                h.seq = r.seq
            end)
        end,
        onMove = function(x, y)
            local h = g.handles[id]
            if h == nil then
                return
            end
            local fx, fy = ScreenToTable(x, y)
            --the Director moves a die across the screen's edge: its privacy follows.
            if dmhub.isDM then
                local behind = BehindScreen(fx)
                if behind ~= h.private then
                    Transfer(id, behind, fx, fy)
                    return
                end
            end
            Modify(id, h.private, "Move a table die", function(r)
                r.fx, r.fy = fx, fy
                r.roll, r.rollAt, r.rollBy = nil, nil, nil
                r.seq = (r.seq or 0) + 1
                h.seq = r.seq
            end)
        end,
        onRightClick = function(x, y)
            ShowDieMenu(id)
        end,
    }
    return handle
end

--- @param handle {die: TableDieLua, seq: number, private: boolean}
--- @param record TableDieRecord
local function UpdateDie(handle, record)
    if (record.seq or 0) == handle.seq then
        return
    end
    handle.seq = record.seq or 0
    local roll = record.roll
    if roll ~= nil and record.rollBy ~= dmhub.userid and record.rollAt ~= nil then
        local fx1, fy1 = TableToScreen(roll.fromfx or record.fx, roll.fromfy or record.fy)
        local fx2, fy2 = TableToScreen(roll.tofx or record.fx, roll.tofy or record.fy)
        handle.die:PlayRoll({
            fromx = fx1, fromy = fy1, tox = fx2, toy = fy2,
            lift = roll.lift, face = roll.face, yaw = roll.yaw, pick = roll.pick,
            seed = roll.seed, duration = roll.duration,
        }, math.max(0, dmhub.serverTime - record.rollAt))
        return
    end
    local px, py = TableToScreen(record.fx or 0.5, record.fy or 0.5)
    handle.die:SetRest(px, py, record.face or 1, record.yaw or 0, record.pick or 0)
end

local function DestroyAll()
    for id, handle in pairs(g.handles) do
        if handle.die.valid then
            handle.die:Destroy()
        end
        g.handles[id] = nil
    end
end

--Every die that should exist, with whether it is private.
--- @return table<string, {record: TableDieRecord, private: boolean}>
local function Wanted()
    local result = {}
    for id, record in pairs(SharedDice()) do
        if type(record) == "table" then
            result[id] = {record = record, private = false}
        end
    end
    if dmhub.isDM then
        for id, record in pairs(PrivateDice()) do
            if type(record) == "table" then
                result[id] = {record = record, private = true}
            end
        end
    end
    return result
end

--- Brings the engine's dice in line with the stores; the layer's think runs it.
function TableDice.Sync()
    --an engine older than table dice has no CreateTableDie: nothing to show.
    if dice.CreateTableDie == nil or not Tabletop.IsActive() or not Tabletop.LayerReady() then
        DestroyAll()
        return
    end
    local covered = Tabletop.TableCovered()
    local screenOpen = rawget(_G, "DirectorScreen") ~= nil and DirectorScreen.IsOpen()
    local x1, y1, x2, y2 = TableBounds()

    local wanted = Wanted()
    for id, handle in pairs(g.handles) do
        local want = wanted[id]
        --gone, or rebuilt as another type, set or store.
        if want == nil or not handle.die.valid or want.private ~= handle.private
            or want.record.faces ~= handle.faces or want.record.model ~= handle.model then
            if handle.die.valid then
                handle.die:Destroy()
            end
            g.handles[id] = nil
        end
    end
    for id, want in pairs(wanted) do
        local handle = g.handles[id]
        if handle == nil then
            handle = BuildDie(id, want.record, want.private)
            g.handles[id] = handle
        else
            UpdateDie(handle, want.record)
        end
        if handle ~= nil then
            handle.die:SetBounds(x1, y1, x2, y2)
            handle.die:SetVisible(not covered and (not want.private or screenOpen))
        end
    end
end

----------------------------------------------------------------------
--The layer: the table's dice button, the menus' anchor, and the sync.

--- GameHud mounts this over the windows. Only the Director's dice button takes
--- the mouse.
--- @return Panel
function TableDice.CreateLayer()
    g.tableButton = gui.Panel{
        classes = {"tableItemsButton", "collapsed"},
        floating = true,
        halign = "left",
        valign = "bottom",
        x = 72,
        bmargin = 22,
        width = 36,
        height = 36,
        bgimage = "panels/square.png",
        swallowPress = true,
        flow = "none",
        hover = gui.Tooltip("Table items"),
        click = function(element)
            TableDice.ToggleDrawer(false)
        end,
        gui.Panel{
            classes = {"tableItemsButtonIcon"},
            bgimage = "phosphor/package.png",
            width = 20,
            height = 20,
            halign = "center",
            valign = "center",
            interactable = false,
        },
    }
    g.layer = gui.Panel{
        id = "tableDiceLayer",
        width = "100%",
        height = "100%",
        flow = "none",
        interactable = false,
        styles = ThemeEngine.MergeTokens(g_drawerStyles),
        children = {g.tableButton, BuildDrawer()},
        thinkTime = 0.05,
        think = function(element)
            if mod.unloaded then
                return
            end
            local shown = dmhub.isDM and Tabletop.IsActive() and not Tabletop.TableCovered()
            local button = g.tableButton
            if button ~= nil and button.valid and button:HasClass("collapsed") == shown then
                button:SetClass("collapsed", not shown)
            end
            --the table went away (a window maximized): so does the drawer.
            if not shown and TableDice.DrawerOpen() then
                CloseDrawer()
            end
            --the screen closed under a drawer opened from it.
            if g_drawer.private and TableDice.DrawerOpen() and rawget(_G, "DirectorScreen") ~= nil and not DirectorScreen.IsOpen() then
                CloseDrawer()
            end
            TableDice.Sync()
        end,
        destroy = function(element)
            DestroyAll()
        end,
    }
    return g.layer
end

--A reload: the dice the old copy of this file made go with it.
if rawget(_G, "g_tableDiceUnload") ~= nil then
    pcall(g_tableDiceUnload)
end
g_tableDiceUnload = DestroyAll
