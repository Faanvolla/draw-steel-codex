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
    --id -> {figure = TableFigureLua, seq = number, private = boolean, blob = string}
    figures = {},
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

--Both stores hold two kinds of thing: "dice" and "figures" (TableFigures).
--- @param kind? string
--- @return table<string, table>
local function SharedItems(kind)
    local items = SharedDoc().data[kind or "dice"]
    if type(items) ~= "table" then
        return {}
    end
    return items
end

--- @return table<string, TableDieRecord>
local function SharedDice()
    return SharedItems("dice")
end

--The private store, as {dice = {...}, figures = {...}}.
--- @return table
local function ReadPrivate()
    local text = g_privateSetting:Get()
    if type(text) ~= "string" or text == "" then
        return {}
    end
    local parsed = dmhub.FromJson(text)
    if parsed == nil or type(parsed.result) ~= "table" then
        return {}
    end
    return parsed.result
end

--- @param kind? string
--- @return table<string, table>
local function PrivateItems(kind)
    local items = ReadPrivate()[kind or "dice"]
    if type(items) ~= "table" then
        return {}
    end
    return items
end

--- @return table<string, TableDieRecord>
local function PrivateDice()
    return PrivateItems("dice")
end

--- @param items table<string, table>
--- @param kind? string
local function SavePrivate(items, kind)
    local all = ReadPrivate()
    all[kind or "dice"] = items
    g_privateSetting:Set(dmhub.ToJson(all))
end

--Changes one record in its store: fn(record) edits it in place, or returns
--false to remove it.
--- @param id string
--- @param private boolean
--- @param description string
--- @param fn fun(record: table): nil|boolean
--- @param kind? string
local function Modify(id, private, description, fn, kind)
    kind = kind or "dice"
    if private then
        local items = PrivateItems(kind)
        local record = items[id]
        if record == nil then
            return
        end
        if fn(record) == false then
            items[id] = nil
        end
        SavePrivate(items, kind)
        return
    end
    local doc = SharedDoc()
    doc:BeginChange()
    doc.data[kind] = doc.data[kind] or {}
    local record = doc.data[kind][id]
    if record ~= nil then
        if fn(record) == false then
            doc.data[kind][id] = nil
        end
    end
    doc:CompleteChange(description, {undoable = false})
end

--Adds a record to a store.
--- @param id string
--- @param private boolean
--- @param record table
--- @param kind? string
local function Add(id, private, record, kind)
    kind = kind or "dice"
    if private then
        local items = PrivateItems(kind)
        items[id] = record
        SavePrivate(items, kind)
        return
    end
    local doc = SharedDoc()
    doc:BeginChange()
    doc.data[kind] = doc.data[kind] or {}
    doc.data[kind][id] = record
    doc:CompleteChange(cond(kind == "figures", "Add a table figure", "Add a table die"), {undoable = false})
end

--Moves a record from one store to the other (dragged across the screen's edge).
--- @param id string
--- @param toPrivate boolean
--- @param fx number
--- @param fy number
--- @param kind? string
local function Transfer(id, toPrivate, fx, fy, kind)
    kind = kind or "dice"
    local from = toPrivate and SharedItems(kind) or PrivateItems(kind)
    local record = from[id]
    if record == nil then
        return
    end
    local copy = DeepCopy(record)
    copy.fx, copy.fy = fx, fy
    copy.roll, copy.rollAt, copy.rollBy = nil, nil, nil
    copy.seq = (copy.seq or 0) + 1
    Modify(id, not toPrivate, "Move a table item", function() return false end, kind)
    Add(id, toPrivate, copy, kind)
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

--How far above a die's centre its menu opens, in screen pixels at scale 1
--(a little more than a die's half-height).
local DIE_MENU_GAP = 56

local function MenuAnchor()
    if g.menuAnchor == nil or not g.menuAnchor.valid then
        if g.layer == nil or not g.layer.valid then
            return nil
        end
        --menus open from this 1px panel, moved to where they belong
        --(ShowDieMenu puts it just above the die).
        g.menuAnchor = gui.Panel{
            width = 1,
            height = 1,
            floating = true,
            halign = "left",
            valign = "top",
            interactable = false,
        }
        g.layer:AddChild(g.menuAnchor)
        g.menuAnchor.popupPositioning = "panel"
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
--- roll (optional) is a throw as the engine's onRoll gives it (screen pixels):
--- the new die arrives by playing it, on every client.
--- @param roll? table
function TableDice.AddDie(faces, px, py, private, roll)
    if not dmhub.isDM then
        return
    end
    local fx, fy = ScreenToTable(px, py)
    --- @type TableDieRecord
    local record = {
        faces = faces,
        model = g_setSetting:Get() or "",
        fx = fx,
        fy = fy,
        --a d10 reads 0-9 on some sets: the engine settles on its real face.
        face = faces,
        yaw = math.random(-20, 20),
        pick = 0,
        seq = 1,
    }
    if roll ~= nil then
        local ffx, ffy = ScreenToTable(roll.fromx, roll.fromy)
        local tfx, tfy = ScreenToTable(roll.tox, roll.toy)
        record.fx, record.fy = tfx, tfy
        record.face, record.yaw, record.pick = roll.face, roll.yaw, roll.pick
        record.roll = {
            fromfx = ffx, fromfy = ffy, tofx = tfx, tofy = tfy,
            lift = roll.lift, face = roll.face, yaw = roll.yaw, pick = roll.pick,
            seed = roll.seed, duration = roll.duration,
        }
        record.rollAt = dmhub.serverTime
    end
    Add(dmhub.GenerateGuid(), private, record)
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
    --just above the die, opening upward so it never covers the die.
    local w, h = TableSize()
    local fx, fy = ScreenToTable(handle.die.x, handle.die.y)
    local scale = Mapping()
    anchor.x = fx * w
    anchor.y = fy * h - DIE_MENU_GAP * scale * handle.die.scale
    --the anchor's new spot is laid out next frame, and the menu places itself
    --from where the anchor is when it opens: so it opens a frame later.
    dmhub.Schedule(0.02, function()
        if mod.unloaded or not anchor.valid then
            return
        end
        local menu = gui.ContextMenu{
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
        if menu == nil then
            return
        end
        local style = menu.selfStyle
        if style ~= nil then
            style.valign = "top"
            style.halign = "center"
        end
        anchor.popup = menu
    end)
end

----------------------------------------------------------------------
--The table items drawer (TABLE_DICE_BRIEF.md, "The table items drawer"):
--slides up from the bottom of the table. Categories down its left side are by
--what a thing IS; search covers all of them; Recent and Favourites follow the
--Director. Click a tile to drop it near where the drawer opened, or drag it to
--a spot. Only dice are built so far: every other tile shows as coming soon.

local DRAWER_HEIGHT = 345
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
--The Director's uploaded figures, as JSON [{blob, name}], kept across games.
local g_figureLibrarySetting = setting{
    id = "tableitems:figures",
    storage = "preference",
    default = "",
}

--- @return {blob: string, name: string}[]
local function FigureLibrary()
    local text = g_figureLibrarySetting:Get()
    if type(text) ~= "string" or text == "" then
        return {}
    end
    local parsed = dmhub.FromJson(text)
    if parsed == nil or type(parsed.result) ~= "table" then
        return {}
    end
    local result = {}
    for _, entry in ipairs(parsed.result) do
        if type(entry) == "table" and type(entry.blob) == "string" then
            result[#result+1] = {blob = entry.blob, name = tostring(entry.name or "Figure")}
        end
    end
    return result
end

--- @param library {blob: string, name: string}[]
local function SaveFigureLibrary(library)
    g_figureLibrarySetting:Set(dmhub.ToJson(library))
end

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
--- @field dice nil|number[] dice shown live in its tile (TableDice previews), by face count
--- @field model nil|string a dice-set tile: the set its die wears ("" = default)
--- @field setValue nil|string a dice-set tile: the set picking it chooses
--- @field figureBlob nil|string a figure-library tile: the uploaded figure it places
--- @field opens nil|string a tile that opens a row under the category ("figures")
--- @field action nil|fun() a tile that does something other than place an item

--- @class TableItemCategory
--- @field id string
--- @field name string
--- @field icon string
--- @field test string what belongs here, in one line
--- @field items TableItemDef[]

--- @type TableItemCategory[]
local CATEGORIES = {
    {id = "dice", name = "Dice", icon = "phosphor/dice-five.png", test = "Something you roll.", items = {
        --only the dice Draw Steel uses: d10s (the 2d10 power roll), d6 and d3.
        {id = "2d10", dice = {10, 10}, name = "2d10", note = "Power roll pair", icon = "phosphor/dice-two.png", place = function(px, py, private)
            TableDice.AddDie(10, px - 34, py, private)
            TableDice.AddDie(10, px + 34, py, private)
        end},
        {id = "d10", dice = {10}, name = "d10", icon = "phosphor/polygon.png", place = DiePlacer(10)},
        {id = "d6", dice = {6}, name = "d6", icon = "phosphor/dice-six.png", place = DiePlacer(6)},
        {id = "d3", dice = {3}, name = "d3", icon = "phosphor/dice-three.png", place = DiePlacer(3)},
    }},
    {id = "trinkets", name = "Trinkets", icon = "phosphor/diamond.png", test = "Something you move or flip; it keeps no number.", items = {
        {id = "coin", name = "Coin", note = "Flip it", icon = "phosphor/coin.png"},
        {id = "gem", name = "Gem", icon = "phosphor/diamond.png"},
        {id = "skull", name = "Skull", icon = "phosphor/skull.png"},
        {id = "key", name = "Key", icon = "phosphor/key.png"},
        {id = "figure", name = "Figure", note = "Your 3D minis", icon = "phosphor/user.png", opens = "figures"},
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
    {selectors = {"tableDrawerTile", "selected"}, bgcolor = "@bgRaised", borderColor = "@fgStrong"},
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
    --- @type table[] the live dice on the tiles (SyncPreviews)
    previews = {},
    --a tile's row shown under its category ("figures"), or nil.
    openRow = nil,
    --- @type string[] names of STL files being prepared for the library
    uploading = {},
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

local SelectDiceSet

--Live dice in the drawer's tiles (Venla, 2026-10-20): each dice tile holds
--a real table die in the chosen set, so the drawer shows what you are about
--to put down. They are engine table dice like the ones on the table, only
--local and never stored. Click one to add that item; drag one out of the
--drawer and put it down, or throw it, and it lands there.
--g_drawer.previews: {die = TableDieLua, tile = Panel, item = TableItemDef,
--faces = number, index = number, x = number, y = number} for each die shown.

local PREVIEW_SCALE = 0.55
--a 2d10 tile's pair sits a little smaller, side by side (layer units apart).
local PAIR_SCALE = 0.45
local PAIR_SPREAD = 22

local function DestroyPreviews()
    for _, preview in ipairs(g_drawer.previews) do
        local object = preview.die or preview.figure
        if object ~= nil and object.valid then
            object:Destroy()
        end
    end
    g_drawer.previews = {}
end

--A panel's centre in screen pixels: its spot in the layer (as Tabletop's
--LayerRect measures it), then the layer's mapping onto the screen.
--- @param panel Panel
--- @return number|nil px, number|nil py
local function PanelCentreOnScreen(panel)
    local layer = g.layer
    if layer == nil or not layer.valid or panel == nil or not panel.valid then
        return nil, nil
    end
    local lp = layer.positionInScreenSpace
    local p = panel.positionInScreenSpace
    local left = lp.x - layer.renderedWidth / 2
    local top = lp.y + layer.renderedHeight / 2
    return LayerToScreen(p.x - left, top - p.y)
end

--The top of the drawer, in screen pixels: a die let go below it stays in.
local function DrawerTopOnScreen()
    local _, h = TableSize()
    local _, py = LayerToScreen(0, h - DRAWER_HEIGHT - 10)
    return py
end

--Where a preview die rests: on its tile, above the name.
--- @param preview table
--- @return number|nil px, number|nil py
local function PreviewSpot(preview)
    local px, py = PanelCentreOnScreen(preview.tile)
    if px == nil or py == nil then
        return nil, nil
    end
    local scale = Mapping()
    if preview.figure ~= nil then
        --a figure stands on its base and leans up the screen: its spot is low
        --in the tile so it sits above the name, under the row's label.
        return px, py + 4 / scale
    end
    local offset = 0
    if #preview.item.dice > 1 then
        offset = (preview.index - (#preview.item.dice + 1) / 2) * 2 * PAIR_SPREAD
    end
    return px + offset / scale, py - 14 / scale
end

local function PutBack(preview)
    local px, py = PreviewSpot(preview)
    if px == nil then
        return
    end
    if preview.figure ~= nil then
        if preview.figure.valid then
            preview.x, preview.y = px, py
            preview.figure:SetRest(px, py)
        end
        return
    end
    if preview.die.valid then
        preview.x, preview.y = px, py
        preview.die:SetRest(px, py, preview.faces, 0, 0)
    end
end

--A figure-library tile's live figure: click it to place the figure, or drag
--it out of the drawer and let go.
--- @param tile Panel
--- @param item TableItemDef
local function BuildFigurePreview(tile, item)
    local figure = dice.CreateTableFigure{blob = item.figureBlob, x = 0, y = 0, height = 46, tilt = 62}
    if figure == nil then
        return
    end
    local preview = {figure = figure, tile = tile, item = item}
    figure.callbacks = {
        onClick = function(x, y)
            local px, py = DropSpot()
            PlaceItem(item, px, py, g_drawer.private)
            PutBack(preview)
        end,
        onMove = function(x, y)
            if y < DrawerTopOnScreen() then
                local fx = ScreenToTable(x, y)
                PlaceItem(item, x, y, BehindScreen(fx))
            end
            PutBack(preview)
        end,
    }
    g_drawer.previews[#g_drawer.previews+1] = preview
    PutBack(preview)
end

--- @param tile Panel
--- @param item TableItemDef
--- @param faces number
--- @param index number
local function BuildPreview(tile, item, faces, index)
    local model = item.model
    if model == nil then
        model = g_setSetting:Get() or ""
    end
    local die = dice.CreateTableDie{
        faces = faces,
        model = cond(model == "", nil, model),
        x = 0,
        y = 0,
        face = faces,
        --a d4 stands tall: it sits a little smaller to fit its tile.
        scale = cond(#item.dice > 1, PAIR_SCALE, cond(faces == 4, PREVIEW_SCALE * 0.8, PREVIEW_SCALE)),
    }
    if die == nil then
        return
    end
    local preview = {die = die, tile = tile, item = item, faces = faces, index = index}
    --a dice-set tile's die: clicking or moving it picks the set; it stays put.
    if item.setValue ~= nil then
        die.callbacks = {
            onRoll = function(roll)
                PutBack(preview)
                SelectDiceSet(item.setValue)
            end,
            onMove = function(x, y)
                PutBack(preview)
                SelectDiceSet(item.setValue)
            end,
        }
        g_drawer.previews[#g_drawer.previews+1] = preview
        PutBack(preview)
        return
    end
    die.callbacks = {
        --clicked (a hop in place) or thrown: a click adds the item as its tile
        --would; a throw out of the drawer lands a die where it was thrown.
        onRoll = function(roll)
            if roll.toy >= DrawerTopOnScreen() then
                local px, py = DropSpot()
                PlaceItem(item, px, py, g_drawer.private)
            else
                local fx = ScreenToTable(roll.tox, roll.toy)
                TableDice.AddDie(faces, roll.tox, roll.toy, BehindScreen(fx), roll)
                NoteRecent(item.id)
                if not g_drawer.pinned then
                    CloseDrawer()
                end
            end
            PutBack(preview)
        end,
        --dragged and put down: on the table it lands there; back in the
        --drawer it returns to its tile.
        onMove = function(x, y)
            if y < DrawerTopOnScreen() then
                local fx = ScreenToTable(x, y)
                TableDice.AddDie(faces, x, y, BehindScreen(fx))
                NoteRecent(item.id)
                if not g_drawer.pinned then
                    CloseDrawer()
                end
            end
            PutBack(preview)
        end,
    }
    g_drawer.previews[#g_drawer.previews+1] = preview
    PutBack(preview)
end

--Keeps a live die on every dice tile showing: made when the drawer shows
--them, moved when a tile moves (a scroll, a resize), gone when it closes.
--The layer's think runs it.
local function SyncPreviews()
    local panel = g_drawer.panel
    local open = panel ~= nil and panel.valid and not panel:HasClass("collapsed")
    if not open or dice.CreateTableDie == nil then
        if #g_drawer.previews > 0 then
            DestroyPreviews()
        end
        return
    end
    if #g_drawer.previews == 0 and g_drawer.grid ~= nil and g_drawer.grid.valid then
        for _, tile in ipairs(g_drawer.grid.children) do
            local item = nil
            pcall(function() item = tile.data.item end)
            if item ~= nil and item.dice ~= nil then
                for index, faces in ipairs(item.dice) do
                    BuildPreview(tile, item, faces, index)
                end
            elseif item ~= nil and item.figureBlob ~= nil and dice.CreateTableFigure ~= nil then
                BuildFigurePreview(tile, item)
            end
        end
    end
    local x1, y1, x2, y2 = TableBounds()
    for _, preview in ipairs(g_drawer.previews) do
        local object = preview.die or preview.figure
        if object ~= nil and object.valid then
            object:SetBounds(x1, y1, x2, y2)
            local px, py = PreviewSpot(preview)
            --moved only when its tile did, and never mid-throw.
            if px ~= nil and (math.abs(px - (preview.x or 0)) > 1 or math.abs(py - (preview.y or 0)) > 1)
                and math.abs(object.x - (preview.x or 0)) < 1 and math.abs(object.y - (preview.y or 0)) < 1 then
                PutBack(preview)
            end
        end
    end
end

local RebuildDrawer

--Picks the set dice from the drawer wear, and shows it.
--- @param value string a dice set id ("" = default)
SelectDiceSet = function(value)
    g_setSetting:Set(value)
    RebuildDrawer()
end

--- @param item TableItemDef
--- @return Panel
local function BuildTile(item)
    local soon = item.place == nil and item.opens == nil and item.action == nil
    local open = item.opens ~= nil and g_drawer.openRow == item.opens
    return gui.Panel{
        classes = {"tableDrawerTile", cond(soon, "soon", cond(open, "selected", "ready"))},
        bgimage = "panels/square.png",
        width = TILE_WIDTH,
        height = TILE_HEIGHT,
        hmargin = 4,
        vmargin = 4,
        flow = "vertical",
        swallowPress = true,
        draggable = item.place ~= nil,
        data = {item = item},
        hover = function(element)
            if item.opens ~= nil then
                gui.Tooltip(cond(open, "Hide your figures", "Show your figures"))(element)
            elseif item.action ~= nil then
                gui.Tooltip(item.note or item.name)(element)
            elseif item.figureBlob ~= nil then
                gui.Tooltip("Click to add, or drag onto the table. Right-click to remove it from your figures.")(element)
            elseif soon then
                gui.Tooltip("Coming soon")(element)
            else
                gui.Tooltip("Click to add, or drag onto the table. Right-click to favourite.")(element)
            end
        end,
        click = function(element)
            if item.opens ~= nil then
                g_drawer.openRow = cond(open, nil, item.opens)
                RebuildDrawer()
                return
            end
            if item.action ~= nil then
                item.action()
                return
            end
            if soon then
                return
            end
            local px, py = DropSpot()
            PlaceItem(item, px, py, g_drawer.private)
        end,
        rightClick = function(element)
            if item.figureBlob ~= nil then
                local library = {}
                for _, entry in ipairs(FigureLibrary()) do
                    if entry.blob ~= item.figureBlob then
                        library[#library+1] = entry
                    end
                end
                SaveFigureLibrary(library)
                RebuildDrawer()
                return
            end
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
        --a real die rests here (SyncPreviews); other items show their icon.
        gui.Panel{
            classes = {"tableDrawerTileIcon"},
            bgimage = cond(item.dice ~= nil or item.figureBlob ~= nil, nil, item.icon),
            bgcolor = cond(item.dice ~= nil or item.figureBlob ~= nil, "clear", nil),
            width = 28,
            height = cond(item.dice ~= nil or item.figureBlob ~= nil, 44, 28),
            halign = "center",
            tmargin = cond(item.dice ~= nil or item.figureBlob ~= nil, 4, 12),
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
            textWrap = false,
            maxWidth = TILE_WIDTH - 8,
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

--The dice sets this account has, as tiles: each shows a d10 in its set.
--- @return TableItemDef[]
local function DiceSetItems()
    local result = {}
    for _, entry in ipairs(dice.GetAvailableDice()) do
        local value = entry.value
        if value == "Default" then
            value = ""
        end
        result[#result+1] = {
            id = "set:" .. tostring(value),
            name = tostring(entry.text),
            icon = "phosphor/dice-five.png",
            dice = {10},
            model = value,
            setValue = value,
        }
    end
    return result
end

--- @param item TableItemDef a dice-set item (DiceSetItems)
--- @return Panel
local function BuildSetTile(item)
    local chosen = (g_setSetting:Get() or "") == item.setValue
    return gui.Panel{
        classes = {"tableDrawerTile", cond(chosen, "selected", "ready")},
        bgimage = "panels/square.png",
        width = TILE_WIDTH,
        height = TILE_HEIGHT,
        hmargin = 4,
        vmargin = 4,
        flow = "vertical",
        swallowPress = true,
        data = {item = item},
        hover = gui.Tooltip("Dice from the drawer wear this set"),
        click = function(element)
            SelectDiceSet(item.setValue)
        end,
        gui.Panel{
            width = 28,
            height = 44,
            halign = "center",
            tmargin = 4,
            interactable = false,
        },
        gui.Label{
            classes = {"tableDrawerTileName"},
            text = item.name,
            fontSize = 12,
            textWrap = false,
            maxWidth = TILE_WIDTH - 8,
            tmargin = 6,
            interactable = false,
        },
    }
end

--- @param text string
--- @return Panel
local function SectionLabel(text)
    return gui.Label{
        classes = {"tableDrawerText"},
        text = text,
        width = "100%",
        tmargin = 4,
        lmargin = 4,
    }
end

RebuildDrawer = function()
    local grid = g_drawer.grid
    if grid == nil or not grid.valid then
        return
    end
    --the tiles are replaced: their dice go, and SyncPreviews makes new ones.
    DestroyPreviews()
    local items, text = ShownItems()
    local children = {}
    --the Dice category: the sets first, then the dice in the chosen set.
    if g_drawer.category == "dice" and g_drawer.search == "" then
        local current = g_setSetting:Get() or ""
        local currentName = "the default set"
        children[#children+1] = SectionLabel("Your dice sets")
        for _, setItem in ipairs(DiceSetItems()) do
            if setItem.setValue == current then
                currentName = setItem.name
            end
            children[#children+1] = BuildSetTile(setItem)
        end
        children[#children+1] = SectionLabel("In " .. currentName)
    end
    for _, item in ipairs(items) do
        children[#children+1] = BuildTile(item)
    end
    --Trinkets with Figure open: the uploaded figures, any being prepared,
    --and the tile that uploads another.
    if g_drawer.category == "trinkets" and g_drawer.search == "" and g_drawer.openRow == "figures" then
        children[#children+1] = SectionLabel("Your figures")
        for _, entry in ipairs(FigureLibrary()) do
            local blob = entry.blob
            local name = entry.name
            children[#children+1] = BuildTile{
                id = "figure:" .. blob,
                name = name,
                icon = "phosphor/user.png",
                figureBlob = blob,
                place = function(px, py, private)
                    TableDice.PlaceFigure(blob, name, px, py, private)
                end,
            }
        end
        for _, name in ipairs(g_drawer.uploading) do
            children[#children+1] = BuildTile{id = "uploading:" .. name, name = name, note = "Preparing...", icon = "phosphor/hourglass.png", action = function() end}
        end
        children[#children+1] = BuildTile{
            id = "upload-figure",
            name = "Upload STL",
            note = "Add a figure",
            icon = "phosphor/upload-simple-bold.png",
            action = function()
                TableDice.PickFigureFile()
            end,
        }
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

    --Clear dice: only shown on the Dice category.
    g_drawer.setRow = gui.Panel{
        width = "auto",
        height = 26,
        flow = "horizontal",
        valign = "center",
        lmargin = 12,
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

--- Whether a die was just right-clicked: the table's own right-click menu
--- (Tabletop.lua) stands down, as the same click also reaches the table.
--- @return boolean
function TableDice.DieJustRightClicked()
    return g.dieRightClickedAt ~= nil and dmhub.Time() - g.dieRightClickedAt < 0.5
end

--- For tests: opens a die's right-click menu, as a right-click on it would.
--- @param id string
function TableDice.DebugOpenDieMenu(id)
    ShowDieMenu(id)
end

--- Removes every die on the table (shared) or behind the screen (private).
--- @param private boolean
function TableDice.ClearDice(private)
    if private then
        SavePrivate({}, "dice")
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
    --a die thrown onto the table (out of the drawer) arrives by its throw.
    local roll = record.roll
    if roll ~= nil and record.rollAt ~= nil then
        local elapsed = dmhub.serverTime - record.rollAt
        if elapsed < (roll.duration or 1) then
            local x1, y1 = TableToScreen(roll.fromfx or record.fx, roll.fromfy or record.fy)
            local x2, y2 = TableToScreen(roll.tofx or record.fx, roll.tofy or record.fy)
            die:PlayRoll({
                fromx = x1, fromy = y1, tox = x2, toy = y2,
                lift = roll.lift, face = roll.face, yaw = roll.yaw, pick = roll.pick,
                seed = roll.seed, duration = roll.duration,
            }, math.max(0, elapsed))
        end
    end
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
            g.dieRightClickedAt = dmhub.Time()
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

local function DestroyFigures()
    for id, handle in pairs(g.figures) do
        if handle.figure.valid then
            handle.figure:Destroy()
        end
        g.figures[id] = nil
    end
end

local function DestroyAll()
    for id, handle in pairs(g.handles) do
        if handle.die.valid then
            handle.die:Destroy()
        end
        g.handles[id] = nil
    end
    DestroyFigures()
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

----------------------------------------------------------------------
--Figures: 3D miniatures from STL files (TableFigures.cs in the engine).
--The Director picks an STL; this machine simplifies it (cached), uploads the
--small simplified mesh, and stores only its blob id with the spot and pose,
--in the same two stores as the dice (kind "figures"). Every client makes
--the figure from the blob id. Anyone can drag a figure or click it to turn
--it; the Director right-clicks to turn or remove it.

--- @class TableFigureRecord
--- @field blob string the uploaded simplified mesh
--- @field name string
--- @field fx number
--- @field fy number
--- @field yaw number
--- @field tilt number
--- @field height number on-screen height in pixels
--- @field seq number

local FIGURE_HEIGHT = 150
local FIGURE_TILT = 62

--A figure's right-click menu (Director only): turn it, or take it away.
--- @param id string
local function ShowFigureMenu(id)
    local handle = g.figures[id]
    local anchor = MenuAnchor()
    if handle == nil or anchor == nil or not dmhub.isDM then
        return
    end
    local private = handle.private
    local w, h = TableSize()
    local fx, fy = ScreenToTable(handle.figure.x, handle.figure.y)
    local scale = Mapping()
    anchor.x = fx * w
    anchor.y = fy * h - (handle.figure.height * 0.55) * scale
    g.dieRightClickedAt = dmhub.Time()
    dmhub.Schedule(0.02, function()
        if mod.unloaded or not anchor.valid then
            return
        end
        local menu = gui.ContextMenu{
            entries = {
                {
                    text = "Turn",
                    click = function()
                        CloseMenu()
                        Modify(id, private, "Turn a table figure", function(r)
                            r.yaw = ((r.yaw or 0) + 45) % 360
                            r.seq = (r.seq or 0) + 1
                        end, "figures")
                    end,
                },
                {
                    text = "Remove Figure",
                    click = function()
                        CloseMenu()
                        Modify(id, private, "Remove a table figure", function() return false end, "figures")
                    end,
                },
            },
        }
        if menu == nil then
            return
        end
        local style = menu.selfStyle
        if style ~= nil then
            style.valign = "top"
            style.halign = "center"
        end
        anchor.popup = menu
    end)
end

--- Asks for an STL file and adds it to the Director's figures (the drawer's
--- Trinkets > Figure row). Nothing is placed: the figure is placed from there.
function TableDice.PickFigureFile()
    if not dmhub.isDM or dice.CreateTableFigure == nil then
        return
    end
    dmhub.OpenFileDialog{
        id = "tablefigure",
        extensions = {"stl"},
        multiFiles = false,
        prompt = "Choose a miniature (STL file)",
        open = function(path)
            TableDice.UploadFigureFile(path)
        end,
    }
end

--- Prepares an STL (simplified here, cached; a big file takes a while the
--- first time), uploads its small mesh, and adds it to the Director's figures.
--- @param path string
function TableDice.UploadFigureFile(path)
    local name = string.match(path, "([^/\\]+)%.[sS][tT][lL]$") or "Figure"
    local loader = dice.CreateTableFigure{path = path, x = -1000, y = -1000, height = FIGURE_HEIGHT, tilt = FIGURE_TILT}
    if loader == nil then
        gui.ModalMessage{title = "Figure", message = "That file could not be opened."}
        return
    end
    --only the upload needs it: it never shows.
    loader:SetVisible(false)
    g_drawer.uploading[#g_drawer.uploading+1] = name
    RebuildDrawer()
    local function Finish()
        for i, uploading in ipairs(g_drawer.uploading) do
            if uploading == name then
                table.remove(g_drawer.uploading, i)
                break
            end
        end
        if loader.valid then
            loader:Destroy()
        end
        RebuildDrawer()
    end
    local deadline = dmhub.Time() + 600
    local function Poll()
        if mod.unloaded or not loader.valid then
            return
        end
        local status = loader.status
        if status == "ready" then
            loader:Upload{
                done = function(blob)
                    local library = FigureLibrary()
                    local known = false
                    for _, entry in ipairs(library) do
                        if entry.blob == blob then
                            known = true
                        end
                    end
                    if not known then
                        library[#library+1] = {blob = blob, name = name}
                        SaveFigureLibrary(library)
                    end
                    Finish()
                end,
                error = function(message)
                    Finish()
                    gui.ModalMessage{title = "Figure", message = "The figure could not be uploaded: " .. tostring(message)}
                end,
            }
            return
        end
        if string.sub(status, 1, 5) == "error" or dmhub.Time() > deadline then
            Finish()
            gui.ModalMessage{title = "Figure", message = "That STL could not be read (" .. status .. ")."}
            return
        end
        dmhub.Schedule(0.25, Poll)
    end
    Poll()
end

--- Stands an uploaded figure at (px, py) screen pixels, for everyone.
--- @param blob string
--- @param name string
--- @param px number
--- @param py number
--- @param private boolean behind the Director's Screen
function TableDice.PlaceFigure(blob, name, px, py, private)
    if not dmhub.isDM then
        return
    end
    local fx, fy = ScreenToTable(px, py)
    Add(dmhub.GenerateGuid(), private, {
        blob = blob,
        name = name,
        fx = fx,
        fy = fy,
        yaw = 0,
        tilt = FIGURE_TILT,
        height = FIGURE_HEIGHT,
        seq = 1,
    }, "figures")
end

--- @param id string
--- @param record TableFigureRecord
--- @param private boolean
local function BuildFigure(id, record, private)
    local px, py = TableToScreen(record.fx or 0.5, record.fy or 0.5)
    local figure = dice.CreateTableFigure{
        blob = record.blob,
        x = px,
        y = py,
        height = record.height or FIGURE_HEIGHT,
        tilt = record.tilt or FIGURE_TILT,
        yaw = record.yaw or 0,
    }
    if figure == nil then
        return nil
    end
    local handle = {figure = figure, seq = record.seq or 0, private = private, blob = record.blob}
    figure.callbacks = {
        onMove = function(x, y)
            local h = g.figures[id]
            if h == nil then
                return
            end
            local fx, fy = ScreenToTable(x, y)
            if dmhub.isDM then
                local behind = BehindScreen(fx)
                if behind ~= h.private then
                    Transfer(id, behind, fx, fy, "figures")
                    return
                end
            end
            Modify(id, h.private, "Move a table figure", function(r)
                r.fx, r.fy = fx, fy
                r.seq = (r.seq or 0) + 1
                h.seq = r.seq
            end, "figures")
        end,
        --a click turns it a little, as you would a mini on the table.
        onClick = function(x, y)
            local h = g.figures[id]
            if h == nil then
                return
            end
            Modify(id, h.private, "Turn a table figure", function(r)
                r.yaw = ((r.yaw or 0) + 45) % 360
                r.seq = (r.seq or 0) + 1
            end, "figures")
        end,
        onRightClick = function(x, y)
            ShowFigureMenu(id)
        end,
    }
    return handle
end

--Keeps the engine's figures in line with the stores (TableDice.Sync).
--- @param covered boolean a maximized window covers the table
--- @param screenOpen boolean
--- @param x1 number
--- @param y1 number
--- @param x2 number
--- @param y2 number
local function SyncFigures(covered, screenOpen, x1, y1, x2, y2)
    if dice.CreateTableFigure == nil then
        return
    end
    local wanted = {}
    for id, record in pairs(SharedItems("figures")) do
        if type(record) == "table" and type(record.blob) == "string" then
            wanted[id] = {record = record, private = false}
        end
    end
    if dmhub.isDM then
        for id, record in pairs(PrivateItems("figures")) do
            if type(record) == "table" and type(record.blob) == "string" then
                wanted[id] = {record = record, private = true}
            end
        end
    end
    for id, handle in pairs(g.figures) do
        local want = wanted[id]
        if want == nil or not handle.figure.valid or want.private ~= handle.private or want.record.blob ~= handle.blob then
            if handle.figure.valid then
                handle.figure:Destroy()
            end
            g.figures[id] = nil
        end
    end
    for id, want in pairs(wanted) do
        local handle = g.figures[id]
        if handle == nil then
            handle = BuildFigure(id, want.record, want.private)
            g.figures[id] = handle
        elseif (want.record.seq or 0) ~= handle.seq then
            handle.seq = want.record.seq or 0
            local px, py = TableToScreen(want.record.fx or 0.5, want.record.fy or 0.5)
            handle.figure:SetRest(px, py)
            handle.figure.yaw = want.record.yaw or 0
            handle.figure.tilt = want.record.tilt or FIGURE_TILT
            handle.figure.height = want.record.height or FIGURE_HEIGHT
        end
        if handle ~= nil then
            handle.figure:SetBounds(x1, y1, x2, y2)
            handle.figure:SetVisible(not covered and (not want.private or screenOpen))
        end
    end
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
    SyncFigures(covered, screenOpen, x1, y1, x2, y2)
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
            SyncPreviews()
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
g_tableDiceUnload = function()
    DestroyAll()
    DestroyPreviews()
end
