local mod = dmhub.GetModLoading()

--Scene elements: what is placed on a scene from the Scenes library
--(ScenesPanel.lua). For now that is creature cards. A scene is a shared
--space: everyone looking at it -- in a tabletop scene window, maximized, or
--in the full-screen display -- sees the same cards in the same places, and
--sees them move and resize while they are dragged.
--
--Each scene keeps its elements in its own shared document,
--"sceneElements:<sceneid>":
--  edit          who may change the scene besides the Director: "none" (nobody),
--                "own" (players move and resize the cards of creatures they
--                control; the default) or "full" (players add, move, resize
--                and remove anything)
--  elements[id]  {kind, x, y, w, z, ...}: x, y the card's top-left and w its
--                width, as fractions of the scene's picture, so it sits on the
--                same spot of the art whatever size it is drawn at; z the
--                stacking order. A "creature" element has charid.
--  z             the last z handed out
--A position is written to the document once, when its drag ends. While the
--drag lasts the dragger streams it to everyone else as a best-effort remote
--event (MOVE_EVENT, about 20 a second), and their copies ease towards it.
--
--Speech: whoever controls a card (and the Director) can make it say a line.
--The line is not saved anywhere: it goes to everyone as a reliable remote
--event (SPEECH_EVENT) and shows as a bubble above the card for a few seconds.
--
--How drops reach a scene: its layer (SceneElements.CreateLayer, mounted by
--FullscreenDisplay.CreateSceneView over the picture) is one of ChatItemLinks'
--item drop targets, so character and bestiary rows, table cards and other
--scenes' cards dropped on it arrive as "itemLinkDrop"; it is also the
--engine's token drop target, so tokens dragged off a map arrive as
--"dropTokens". A maximized scene under the UI is the table's background and
--takes no mouse; the tabletop's own drop handlers pass drops on it here
--(SceneElements.DropOnBackground).

--- @class SceneElement
--- @field kind string
--- @field x number
--- @field y number
--- @field w number
--- @field z nil|number
--- @field charid nil|string

--- @class SceneElementKind
--- @field exists fun(el: SceneElement): boolean whether what it shows is still there
--- @field key fun(el: SceneElement): string what it shows; a change rebuilds its panel
--- @field build fun(el: SceneElement): Panel, number, number its face at its own size, and that size
--- @field controls fun(el: SceneElement): boolean whether this user controls it ("own" scenes)
--- @field item fun(el: SceneElement): nil|ChatItemLink the link a drag of it carries

SceneElements = {}

local MOVE_EVENT = "sceneElementMove"
local SPEECH_EVENT = "sceneElementSpeech"

--The longest line a card can say.
local SPEECH_LIMIT = 140

--A new card's width as a share of the picture's width, and the range a
--resize keeps to.
local DEFAULT_WIDTH = 0.12
local MIN_WIDTH = 0.04
local MAX_WIDTH = 0.6

--Several cards dropped at once step down-right by this much.
local CARD_STEP = 0.025

--The picture's height / width when a scene has none (or it has not loaded).
SceneElements.NO_ART_ASPECT = 9 / 16

--Someone else's streamed position is followed this long after their last
--message, or, after the message that ends their drag, until the document
--has the drop (at most FINAL_SECONDS).
local LIVE_SECONDS = 0.5
local FINAL_SECONDS = 3
local SEND_INTERVAL = 0.05

--This client's id on the move events, so it skips its own echo.
local g_clientId = dmhub.GenerateGuid()

local function DocId(sceneid)
    return "sceneElements:" .. sceneid
end

local function Doc(sceneid)
    return mod:GetDocumentSnapshot(DocId(sceneid))
end

--- The path of a scene's elements document, for monitorGame.
--- @param sceneid string
--- @return string
function SceneElements.DocPath(sceneid)
    return Doc(sceneid).path
end

local function Change(sceneid, description, fn)
    local doc = Doc(sceneid)
    doc:BeginChange()
    if type(doc.data.elements) ~= "table" then
        doc.data.elements = {}
    end
    fn(doc.data)
    doc:CompleteChange(description)
end

local function Clamp(v, lo, hi)
    if hi < lo then
        return lo
    end
    return math.max(lo, math.min(hi, v))
end

----------------------------------------------------------------------
--Who may change a scene.

--- The edit modes, in the order the Director's menu lists them.
SceneElements.EDIT_MODES = {
    {
        id = "none",
        text = "Only the Director",
        icon = "phosphor/lock-simple-fill.png",
        tip = "Only you can change what is in this scene",
    },
    {
        id = "own",
        text = "Players control their heroes",
        icon = "phosphor/user-fill.png",
        tip = "Players can move and resize their own heroes in this scene, but not add or remove anything",
    },
    {
        id = "full",
        text = "Players have full control",
        icon = "phosphor/users-three.png",
        tip = "Players can add, move, resize and remove anything in this scene",
    },
}

--- @param sceneid string
--- @return string mode "none", "own" or "full"
function SceneElements.EditMode(sceneid)
    local mode = Doc(sceneid).data.edit
    if mode == "none" or mode == "full" then
        return mode
    end
    return "own"
end

--- @param sceneid string
--- @return {id: string, text: string, icon: string, tip: string}
function SceneElements.EditModeInfo(sceneid)
    local mode = SceneElements.EditMode(sceneid)
    for _, info in ipairs(SceneElements.EDIT_MODES) do
        if info.id == mode then
            return info
        end
    end
    return SceneElements.EDIT_MODES[2]
end

--- The Director sets who may change the scene.
--- @param sceneid string
--- @param mode string
function SceneElements.SetEditMode(sceneid, mode)
    if not dmhub.isDM or SceneElements.EditMode(sceneid) == mode then
        return
    end
    Change(sceneid, "Change who can edit the scene", function(data)
        data.edit = mode
    end)
end

--- Whether this user may put things into the scene (and take them out).
--- @param sceneid string
--- @return boolean
function SceneElements.CanAdd(sceneid)
    return dmhub.isDM or SceneElements.EditMode(sceneid) == "full"
end

SceneElements.CanRemove = SceneElements.CanAdd

----------------------------------------------------------------------
--Element kinds.

--- @type table<string, SceneElementKind>
SceneElements.kinds = {}

SceneElements.kinds.creature = {
    exists = function(el)
        return type(el.charid) == "string" and dmhub.GetCharacterById(el.charid) ~= nil
    end,
    key = function(el)
        return tostring(el.charid)
    end,
    build = function(el)
        local tok = dmhub.GetCharacterById(el.charid)
        local w, h = Tabletop.CardSize()
        return Tabletop.CardFace(el.charid, tok), w, h
    end,
    controls = function(el)
        local tok = dmhub.GetCharacterById(el.charid)
        return tok ~= nil and tok.canControlAsUser == true
    end,
    item = function(el)
        return ChatItemLinks.CharacterItem(el.charid)
    end,
}

--- Whether this user may move and resize the element.
--- @param sceneid string
--- @param el SceneElement
--- @return boolean
function SceneElements.CanChange(sceneid, el)
    if dmhub.isDM then
        return true
    end
    local mode = SceneElements.EditMode(sceneid)
    if mode == "full" then
        return true
    end
    local kind = SceneElements.kinds[el.kind]
    return mode == "own" and kind ~= nil and kind.controls(el)
end

--- Whether this user may make the element speak: the Director, or whoever
--- controls it, whatever the scene's edit mode.
--- @param el SceneElement
--- @return boolean
function SceneElements.CanSpeak(el)
    if dmhub.isDM then
        return true
    end
    local kind = SceneElements.kinds[el.kind]
    return kind ~= nil and kind.controls(el)
end

local function ValidElement(el)
    if type(el) ~= "table" then
        return false
    end
    local kind = SceneElements.kinds[el.kind]
    return kind ~= nil and type(el.x) == "number" and type(el.y) == "number" and type(el.w) == "number" and kind.exists(el)
end

--- The scene's elements that can be drawn, by id.
--- @param sceneid string
--- @return table<string, SceneElement>
function SceneElements.Elements(sceneid)
    local out = {}
    local elements = Doc(sceneid).data.elements
    if type(elements) == "table" then
        for id, el in pairs(elements) do
            if ValidElement(el) then
                out[id] = el
            end
        end
    end
    return out
end

--- @param sceneid string
--- @return integer
function SceneElements.Count(sceneid)
    local n = 0
    for _ in pairs(SceneElements.Elements(sceneid)) do
        n = n + 1
    end
    return n
end

----------------------------------------------------------------------
--Changing a scene.

--Characters a scene just took, by charid: a table card dropped on a scene
--moves in, so it asks here whether to leave the table (TookCharacter).
local g_took = {}

--- Whether a scene took this character from a drop in the last half second.
--- @param charid string
--- @return boolean
function SceneElements.TookCharacter(charid)
    local t = g_took[charid]
    return t ~= nil and dmhub.Time() - t < 0.5
end

local function CardAspect()
    local w, h = Tabletop.CardSize()
    return h / w
end

local function ElementFor(data, charid)
    for id, el in pairs(data.elements) do
        if type(el) == "table" and el.kind == "creature" and el.charid == charid then
            return id
        end
    end
    return nil
end

--- Puts characters into a scene, the first centred on (cx, cy) (fractions of
--- the picture) and the rest stepping down-right. A character already in the
--- scene moves there instead: a scene holds one card per character.
--- @param sceneid string
--- @param charids string[]
--- @param cx number
--- @param cy number
--- @param artAspect nil|number the picture's height / width
function SceneElements.AddCreatures(sceneid, charids, cx, cy, artAspect)
    if #charids == 0 then
        return
    end
    local stretch = CardAspect() / (artAspect or SceneElements.NO_ART_ASPECT)
    Change(sceneid, "Add to scene", function(data)
        for i, charid in ipairs(charids) do
            local id = ElementFor(data, charid) or dmhub.GenerateGuid()
            local old = data.elements[id]
            local w = DEFAULT_WIDTH
            if type(old) == "table" and type(old.w) == "number" then
                w = old.w
            end
            local h = w * stretch
            data.z = (tonumber(data.z) or 0) + 1
            data.elements[id] = {
                kind = "creature",
                charid = charid,
                x = Clamp(cx - w / 2 + (i - 1) * CARD_STEP, 0, 1 - w),
                y = Clamp(cy - h / 2 + (i - 1) * CARD_STEP, 0, 1 - h),
                w = w,
                z = data.z,
            }
            g_took[charid] = dmhub.Time()
        end
    end)
end

--- The Director drops bestiary creatures into a scene: each is created with
--- no map (as a drop on the bare table does) and enters the scene once the
--- game has it.
--- @param sceneid string
--- @param monsterids string[]
--- @param cx number
--- @param cy number
--- @param artAspect nil|number
function SceneElements.AddMonsters(sceneid, monsterids, cx, cy, artAspect)
    if not dmhub.isDM then
        return
    end
    for i, monsterid in ipairs(monsterids) do
        local tok = game.SpawnTokenFromBestiaryLocally(monsterid, nil)
        if tok ~= nil then
            tok:UploadToken()
            local charid = tok.charid
            local x = cx + (i - 1) * CARD_STEP
            local y = cy + (i - 1) * CARD_STEP
            dmhub.Coroutine(function()
                for _ = 1, 100 do
                    if mod.unloaded then
                        return
                    end
                    if dmhub.GetCharacterById(charid) ~= nil then
                        SceneElements.AddCreatures(sceneid, {charid}, x, y, artAspect)
                        return
                    end
                    coroutine.yield(0.05)
                end
            end)
        end
    end
    game.UpdateCharacterTokens()
end

--- Where an element is: its top-left and width (fractions of the picture).
--- It also comes to the front.
--- @param sceneid string
--- @param id string
--- @param x number
--- @param y number
--- @param w number
function SceneElements.Place(sceneid, id, x, y, w)
    Change(sceneid, "Move in scene", function(data)
        local el = data.elements[id]
        if type(el) ~= "table" then
            return
        end
        data.z = (tonumber(data.z) or 0) + 1
        el.x = x
        el.y = y
        el.w = w
        el.z = data.z
    end)
end

--- @param sceneid string
--- @param id string
function SceneElements.Remove(sceneid, id)
    Change(sceneid, "Remove from scene", function(data)
        data.elements[id] = nil
    end)
end

----------------------------------------------------------------------
--Live positions while someone drags.

--sceneid|id -> {x, y, w, t, final}
local g_live = {}

local function LiveKey(sceneid, id)
    return sceneid .. "|" .. id
end

local function SendMove(sceneid, id, x, y, w, final)
    --the last message must arrive (it hands over to the document), so it
    --goes through the game server; the stream is best-effort. A scene is not
    --on any map, so it reaches everyone, whatever map they are on.
    dmhub.BroadcastRemoteEvent(MOVE_EVENT, LiveKey(sceneid, id), {
        gameid = dmhub.gameid,
        from = g_clientId,
        sceneid = sceneid,
        id = id,
        x = x,
        y = y,
        w = w,
        final = final == true,
    }, final == true, true)
end

dmhub.RegisterRemoteEvent(MOVE_EVENT, function(info)
    if mod.unloaded or type(info) ~= "table" or info.gameid ~= dmhub.gameid or info.from == g_clientId then
        return
    end
    if type(info.sceneid) ~= "string" or type(info.id) ~= "string" then
        return
    end
    local x, y, w = tonumber(info.x), tonumber(info.y), tonumber(info.w)
    if x == nil or y == nil or w == nil then
        return
    end
    g_live[LiveKey(info.sceneid, info.id)] = {x = x, y = y, w = w, t = dmhub.Time(), final = info.final == true}
end)

--Where an element should be drawn now: someone's live drag, or the document.
local function TargetOf(sceneid, id, el)
    local key = LiveKey(sceneid, id)
    local live = g_live[key]
    if live ~= nil then
        local age = dmhub.Time() - live.t
        local landed = math.abs(el.x - live.x) < 1e-4 and math.abs(el.y - live.y) < 1e-4 and math.abs(el.w - live.w) < 1e-4
        if age < LIVE_SECONDS or (live.final and age < FINAL_SECONDS and not landed) then
            return live.x, live.y, live.w
        end
        g_live[key] = nil
    end
    return el.x, el.y, el.w
end

----------------------------------------------------------------------
--Speech bubbles.

--sceneid|id -> {text, t, dur}: what each card is saying, kept here (not per
--layer) so every view of the scene shows the same bubble.
local g_speech = {}

local function SetSpeech(sceneid, id, text)
    --long lines stay up longer, so they can be read.
    g_speech[LiveKey(sceneid, id)] = {text = text, t = dmhub.Time(), dur = Clamp(3 + #text * 0.06, 4, 12)}
end

--- Makes a card in a scene say a line: a bubble above it, for everyone.
--- @param sceneid string
--- @param id string the element id
--- @param text string
function SceneElements.Say(sceneid, id, text)
    text = trim(text or ""):sub(1, SPEECH_LIMIT)
    if text == "" then
        return
    end
    SetSpeech(sceneid, id, text)
    dmhub.BroadcastRemoteEvent(SPEECH_EVENT, LiveKey(sceneid, id), {
        gameid = dmhub.gameid,
        from = g_clientId,
        sceneid = sceneid,
        id = id,
        text = text,
    }, true, true)
end

dmhub.RegisterRemoteEvent(SPEECH_EVENT, function(info)
    if mod.unloaded or type(info) ~= "table" or info.gameid ~= dmhub.gameid or info.from == g_clientId then
        return
    end
    if type(info.sceneid) ~= "string" or type(info.id) ~= "string" or type(info.text) ~= "string" then
        return
    end
    local text = trim(info.text):sub(1, SPEECH_LIMIT)
    if text ~= "" then
        SetSpeech(info.sceneid, info.id, text)
    end
end)

--- What a card is saying now, and how faded the bubble is (1 = solid).
--- @return nil|string, number
local function SpeechOf(sceneid, id)
    local key = LiveKey(sceneid, id)
    local s = g_speech[key]
    if s == nil then
        return nil, 0
    end
    local left = s.dur - (dmhub.Time() - s.t)
    if left <= 0 then
        g_speech[key] = nil
        return nil, 0
    end
    return s.text, Clamp(left / 0.5, 0, 1)
end

----------------------------------------------------------------------
--The layer drawn over a scene's picture.

--Every built layer, to find the one under the mouse (DropOnBackground).
local g_layers = setmetatable({}, {__mode = "k"})

--The drag of a card in a scene, or of one of its resize grips:
--{layer, sceneid, id, item, grip, canMove, canRemove, x, y, w, ...}
local g_drag = nil

--- The mouse as fractions of a layer (top-left origin; outside it is outside 0-1).
--- @param layer Panel
--- @return number, number
local function MouseFraction(layer)
    local p = layer.mousePoint
    return p.x, 1 - p.y
end

local function MouseInside(layer)
    local x, y = MouseFraction(layer)
    return x >= 0 and x <= 1 and y >= 0 and y <= 1
end

--- The stage's height / width.
--- @param layer Panel
--- @return number
local function StageAspect(layer)
    return layer.data.sh / math.max(1, layer.data.sw)
end

--- For debugging over MCP: every live layer's scene, stage size, whether it
--- is the table's background, and where the mouse is on it.
--- @return string
function SceneElements.DescribeLayers()
    local lines = {}
    for layer in pairs(g_layers) do
        if layer.valid then
            local fx, fy = MouseFraction(layer)
            lines[#lines+1] = string.format("%s stage=%dx%d background=%s count=%s mouse=%.3f,%.3f",
                layer.data.sceneid, math.floor(layer.data.sw), math.floor(layer.data.sh),
                tostring(layer.data.background), tostring(layer.data.count), fx, fy)
        end
    end
    return table.concat(lines, "\n")
end

local function BackgroundLayerUnderMouse()
    for layer in pairs(g_layers) do
        if layer.valid and layer.data.background and MouseInside(layer) then
            return layer
        end
    end
    return nil
end

--- A drop on the bare table (the tabletop's drop handlers ask): when the
--- table's background is a scene (maximized under the UI, or the full-screen
--- display under it) the creatures enter it at the mouse instead.
--- @param charids nil|string[]
--- @param monsterids nil|string[]
--- @return boolean taken
function SceneElements.DropOnBackground(charids, monsterids)
    local layer = BackgroundLayerUnderMouse()
    if layer == nil then
        return false
    end
    local sceneid = layer.data.sceneid
    if not SceneElements.CanAdd(sceneid) then
        return false
    end
    local fx, fy = MouseFraction(layer)
    if charids ~= nil and #charids > 0 then
        SceneElements.AddCreatures(sceneid, charids, fx, fy, StageAspect(layer))
        return true
    end
    if monsterids ~= nil and #monsterids > 0 then
        SceneElements.AddMonsters(sceneid, monsterids, fx, fy, StageAspect(layer))
        return true
    end
    return false
end

local SCENE_STYLES = {
    {
        selectors = {"sceneElementAway"},
        opacity = 0.45,
    },
    {
        selectors = {"sceneElementGhost"},
        opacity = 0.5,
    },
    --(the ring only while shown: a border ignores the hidden chrome's opacity.)
    {
        selectors = {"sceneElementClose"},
        bgcolor = "#1d1915d0",
        borderColor = "#d8d0c2",
        borderWidth = 0,
    },
    {
        selectors = {"sceneElementClose", "shown"},
        borderWidth = 1,
    },
    {
        selectors = {"sceneElementClose", "hover"},
        bgcolor = "#a3322bff",
    },
    {
        selectors = {"sceneElementSpeak", "hover"},
        bgcolor = "#3d6e8cff",
    },
}

--The bubble's paper and ink.
local BUBBLE_COLOR = "#f4efe4"
local BUBBLE_INK = "#1d1915"

local function Styles()
    local styles = Tabletop.CardStyles()
    for _, rule in ipairs(SCENE_STYLES) do
        styles[#styles+1] = rule
    end
    return styles
end

--Draws an item at (x, y, w): fractions of the stage.
local function Position(layer, item, x, y, w)
    item.cur = {x = x, y = y, w = w}
    local sw, sh = layer.data.sw, layer.data.sh
    local W = w * sw
    local H = W * item.nativeH / item.nativeW
    local panel = item.panel
    panel.x = x * sw
    panel.y = y * sh
    panel.selfStyle.width = W
    panel.selfStyle.height = H
    item.scaler.selfStyle.scale = W / item.nativeW
end

--The height of an item as a fraction of the stage, at width w.
local function HeightFraction(layer, item, w)
    return w * (item.nativeH / item.nativeW) / StageAspect(layer)
end

--- @param sceneid string
--- @param options nil|{onCount: nil|fun(count: integer)}
--- @return Panel
function SceneElements.CreateLayer(sceneid, options)
    options = options or {}
    --id -> {id, el, key, panel, scaler, nativeW, nativeH, cur, grips, close,
    --speak, editing, speech}
    local m_items = {}
    local m_order = nil
    local m_ghost = nil
    local m_refresh = 0
    local Restage
    local layer

    --Over every card: the speech bubbles, and the box a line is typed into.
    local m_speechLayer = gui.Panel{
        halign = "left",
        valign = "top",
        width = 1,
        height = 1,
        flow = "none",
    }

    local function DestroyGhost()
        if m_ghost ~= nil and m_ghost.valid then
            m_ghost:DestroySelf()
        end
        m_ghost = nil
    end

    --The card a drop here would make, following the mouse while something
    --is dragged over the scene.
    local function ShowGhost(item)
        DestroyGhost()
        if item == nil or not SceneElements.CanAdd(sceneid) then
            return
        end
        local face = nil
        if item.kind == "character" and dmhub.GetCharacterById(item.id) ~= nil then
            face = Tabletop.CardFace(item.id, dmhub.GetCharacterById(item.id))
        elseif item.kind == "monster" and assets.monsters[item.id] ~= nil then
            face = Tabletop.BestiaryCardFace(assets.monsters[item.id].info)
        end
        if face == nil then
            return
        end
        local cw, ch = Tabletop.CardSize()
        local W = DEFAULT_WIDTH * layer.data.sw
        local H = W * ch / cw
        --born under the mouse: the think that moves it runs a frame later,
        --and until then it would sit at the scene's top-left.
        local fx, fy = MouseFraction(layer)
        m_ghost = gui.Panel{
            styles = Styles(),
            classes = {"sceneElementGhost"},
            halign = "left",
            valign = "top",
            x = fx * layer.data.sw - W / 2,
            y = fy * layer.data.sh - H / 2,
            width = W,
            height = H,
            flow = "none",
            gui.Panel{
                halign = "center",
                valign = "center",
                width = cw,
                height = ch,
                scale = W / cw,
                face,
            },
        }
        layer:AddChild(m_ghost)
        m_ghost:FireEventTree("refreshCard")
        m_ghost:SetClassTree("sceneElementGhost", true)
        m_ghost:MakeNonInteractiveRecursive()
    end

    local function MoveGhost()
        if m_ghost == nil or not m_ghost.valid then
            return
        end
        local fx, fy = MouseFraction(layer)
        m_ghost.x = fx * layer.data.sw - m_ghost.selfStyle.width / 2
        m_ghost.y = fy * layer.data.sh - m_ghost.selfStyle.height / 2
        m_ghost:SetAsLastSibling()
    end

    --The first item a drag offers that this scene can take.
    local function DroppableItem(items)
        for _, item in ipairs(items or {}) do
            if (item.kind == "character" or item.kind == "monster") and item.fromScene ~= sceneid then
                return item
            end
        end
        return nil
    end

    local function TakeDrop(items)
        DestroyGhost()
        if not SceneElements.CanAdd(sceneid) then
            return
        end
        local fx, fy = MouseFraction(layer)
        local charids = {}
        local monsterids = {}
        for _, item in ipairs(items or {}) do
            if item.kind == "character" and type(item.id) == "string" then
                if item.fromScene == nil then
                    charids[#charids+1] = item.id
                elseif item.fromScene ~= sceneid and SceneElements.CanRemove(item.fromScene) then
                    --a card from another scene moves here.
                    SceneElements.Remove(item.fromScene, item.fromElement)
                    charids[#charids+1] = item.id
                end
            elseif item.kind == "monster" and type(item.id) == "string" then
                monsterids[#monsterids+1] = item.id
            end
        end
        SceneElements.AddCreatures(sceneid, charids, fx, fy, StageAspect(layer))
        SceneElements.AddMonsters(sceneid, monsterids, fx, fy, StageAspect(layer))
    end

    local function CharacterItems(charids)
        local items = {}
        for _, charid in ipairs(charids or {}) do
            items[#items+1] = ChatItemLinks.CharacterItem(charid)
        end
        return items
    end

    ------------------------------------------------------------------
    --Dragging a card: moving it within its scene, or out of it.

    local function DragItemLink(item)
        local kind = SceneElements.kinds[item.el.kind]
        local link = kind.item(item.el)
        if link == nil then
            return {}
        end
        local copy = {}
        for k, v in pairs(link) do
            copy[k] = v
        end
        --another scene that takes it moves it there (TakeDrop).
        copy.fromScene = sceneid
        copy.fromElement = item.id
        return {copy}
    end

    local function EndPreview()
        if g_drag ~= nil and g_drag.preview ~= nil and g_drag.preview.valid then
            g_drag.preview:DestroySelf()
        end
        if g_drag ~= nil then
            g_drag.preview = nil
        end
    end

    --Whether a drag released now lands back in this scene.
    local function OverHome()
        if layer.data.background then
            return MouseInside(layer) and dmhub.tokenDropTargetUnderMouse == nil
        end
        return dmhub.tokenDropTargetUnderMouse == layer
    end

    local function BeginDrag(item)
        local fx, fy = MouseFraction(layer)
        local cur = item.cur or {x = item.el.x, y = item.el.y, w = item.el.w}
        g_drag = {
            layer = layer,
            sceneid = sceneid,
            id = item.id,
            item = item,
            canMove = SceneElements.CanChange(sceneid, item.el),
            canRemove = SceneElements.CanRemove(sceneid),
            grabX = fx - cur.x,
            grabY = fy - cur.y,
            x = cur.x,
            y = cur.y,
            w = cur.w,
            lastSend = 0,
            moved = false,
        }
    end

    local function Stream(final)
        local drag = g_drag
        if drag == nil then
            return
        end
        local now = dmhub.Time()
        if final or now - drag.lastSend >= SEND_INTERVAL then
            drag.lastSend = now
            SendMove(sceneid, drag.id, drag.x, drag.y, drag.w, final)
        end
    end

    local function Dragging(item, element)
        local drag = g_drag
        if drag == nil or drag.item ~= item then
            return
        end
        ChatItemLinks.Dragging(function()
            return DragItemLink(item)
        end, {source = element})

        local home = OverHome()
        if home and drag.canMove then
            local fx, fy = MouseFraction(layer)
            drag.x = Clamp(fx - drag.grabX, 0, 1 - drag.w)
            drag.y = Clamp(fy - drag.grabY, 0, 1 - HeightFraction(layer, item, drag.w))
            drag.moved = true
            Position(layer, item, drag.x, drag.y, drag.w)
            Stream(false)
        end
        local away = not home
        if element:HasClass("sceneElementAway") ~= away then
            element:SetClassTree("sceneElementAway", away)
        end

        --over the bare table it would leave the scene for a card there.
        local toTable = away and drag.canRemove and Tabletop.IsActive() and dmhub.panelDropSurface == "table" and item.el.kind == "creature"
        if toTable then
            if drag.preview == nil or not drag.preview.valid then
                drag.preview = Tabletop.BuildCardPreview(item.el.charid)
            end
            if drag.preview ~= nil then
                local mouse = dmhub.mouseScreenPosition
                drag.preview.x, drag.preview.y = Tabletop.CardDropPlacement(mouse.x, mouse.y, 1)
                drag.preview:SetAsLastSibling()
            end
        else
            EndPreview()
        end
    end

    local function Drop(item, element)
        local drag = g_drag
        if drag == nil or drag.item ~= item then
            return
        end
        --the chat takes a link; another scene takes the card (TakeDrop).
        local taken = ChatItemLinks.Dropped()
        local home = OverHome()
        local toTable = not home and drag.canRemove and Tabletop.IsActive() and dmhub.panelDropSurface == "table"
        EndPreview()
        g_drag = nil
        element:SetClassTree("sceneElementAway", false)
        if taken then
            return
        end
        if home and drag.canMove and drag.moved then
            SceneElements.Place(sceneid, item.id, drag.x, drag.y, drag.w)
            item.pending = {x = drag.x, y = drag.y, w = drag.w, t = dmhub.Time()}
            SendMove(sceneid, item.id, drag.x, drag.y, drag.w, true)
            return
        end
        if toTable and item.el.kind == "creature" then
            local mouse = dmhub.mouseScreenPosition
            local x, y = Tabletop.CardDropPlacement(mouse.x, mouse.y, 1)
            SceneElements.Remove(sceneid, item.id)
            Tabletop.OpenCard(item.el.charid, {x = x, y = y, placed = true})
        end
    end

    ------------------------------------------------------------------
    --Resizing: a grip on each corner keeps the opposite corner in place.

    local GRIP = 14

    local function Grip(item, hx, hy)
        local cursor = cond(hx == hy, "diagonal-expand", "diagonal-expand-mirror")
        local found = false
        for _, id in ipairs(dmhub.cursorIds or {}) do
            if id == cursor then
                found = true
            end
        end
        if not found then
            cursor = "diagonal-expand"
        end
        return gui.Panel{
            floating = true,
            width = GRIP,
            height = GRIP,
            halign = cond(hx < 0, "left", "right"),
            valign = cond(hy < 0, "top", "bottom"),
            x = cond(hx < 0, -GRIP / 2, GRIP / 2),
            y = cond(hy < 0, -GRIP / 2, GRIP / 2),
            bgimage = true,
            bgcolor = "clear",
            hoverCursor = cursor,
            swallowPress = true,
            draggable = true,
            dragMove = false,
            beginDrag = function(element)
                local cur = item.cur or {x = item.el.x, y = item.el.y, w = item.el.w}
                local h = HeightFraction(layer, item, cur.w)
                g_drag = {
                    layer = layer,
                    sceneid = sceneid,
                    id = item.id,
                    item = item,
                    grip = true,
                    --the corner that stays put.
                    ax = cond(hx < 0, cur.x + cur.w, cur.x),
                    ay = cond(hy < 0, cur.y + h, cur.y),
                    x = cur.x,
                    y = cur.y,
                    w = cur.w,
                    lastSend = 0,
                    moved = false,
                }
            end,
            dragging = function(element)
                local drag = g_drag
                if drag == nil or drag.item ~= item or not drag.grip then
                    return
                end
                local fx, fy = MouseFraction(layer)
                local sw, sh = layer.data.sw, layer.data.sh
                local a = item.nativeH / item.nativeW
                --in stage pixels, projected onto the card's diagonal.
                local wantW = math.abs(fx - drag.ax) * sw
                local wantH = math.abs(fy - drag.ay) * sh
                local W = (wantW + wantH * a) / (1 + a * a)
                local w = Clamp(W / sw, MIN_WIDTH, MAX_WIDTH)
                --and it stays on the picture.
                local roomX = cond(hx < 0, drag.ax, 1 - drag.ax)
                local roomY = cond(hy < 0, drag.ay, 1 - drag.ay)
                w = math.min(w, roomX, roomY / math.max(0.0001, HeightFraction(layer, item, 1)))
                local h = HeightFraction(layer, item, w)
                drag.w = w
                drag.x = cond(hx < 0, drag.ax - w, drag.ax)
                drag.y = cond(hy < 0, drag.ay - h, drag.ay)
                drag.moved = true
                Position(layer, item, drag.x, drag.y, drag.w)
                Stream(false)
            end,
            drag = function(element)
                local drag = g_drag
                if drag == nil or drag.item ~= item then
                    return
                end
                g_drag = nil
                if drag.moved then
                    SceneElements.Place(sceneid, item.id, drag.x, drag.y, drag.w)
                    item.pending = {x = drag.x, y = drag.y, w = drag.w, t = dmhub.Time()}
                    SendMove(sceneid, item.id, drag.x, drag.y, drag.w, true)
                end
            end,
        }
    end

    ------------------------------------------------------------------
    --Building the cards.

    local function ShowChrome(item, on)
        if item.close ~= nil and item.close.valid then
            item.close:SetClassTree("shown", on)
        end
    end

    local function ShowMenu(item, element)
        local entries = {}
        if SceneElements.CanRemove(sceneid) then
            if Tabletop.IsActive() and item.el.kind == "creature" then
                entries[#entries+1] = {
                    text = "Move to the Table",
                    click = function()
                        element.popup = nil
                        local charid = item.el.charid
                        SceneElements.Remove(sceneid, item.id)
                        Tabletop.OpenCard(charid, {placed = true})
                    end,
                }
            end
            entries[#entries+1] = {
                text = "Remove from Scene",
                click = function()
                    element.popup = nil
                    SceneElements.Remove(sceneid, item.id)
                end,
            }
        end
        if #entries > 0 then
            element.tooltip = nil
            element.popup = gui.ContextMenu{entries = entries}
        end
    end

    --Shows the grips and the close button only to those who may use them.
    local function UpdatePermissions(item)
        local canChange = SceneElements.CanChange(sceneid, item.el)
        for _, grip in ipairs(item.grips) do
            if grip:HasClass("collapsed") == canChange then
                grip:SetClass("collapsed", not canChange)
            end
        end
        local canRemove = SceneElements.CanRemove(sceneid)
        if item.close:HasClass("collapsed") == canRemove then
            item.close:SetClass("collapsed", not canRemove)
        end
    end

    local function BuildItem(id, el)
        local kind = SceneElements.kinds[el.kind]
        local face, nativeW, nativeH = kind.build(el)
        local item = {id = id, el = el, key = kind.key(el), nativeW = nativeW, nativeH = nativeH}

        item.scaler = gui.Panel{
            halign = "center",
            valign = "center",
            width = nativeW,
            height = nativeH,
            scale = 1,
            face,
        }

        item.close = gui.Panel{
            classes = {"sceneElementClose", "tabletopCardChrome"},
            floating = true,
            halign = "right",
            valign = "top",
            x = 8,
            y = -8,
            width = 20,
            height = 20,
            cornerRadius = 10,
            bgimage = "panels/square.png",
            --the press reaches the card, so hovering here keeps it hovered.
            swallowPress = false,
            hover = gui.Tooltip("Remove from the scene"),
            click = function(element)
                SceneElements.Remove(sceneid, id)
            end,
            gui.Panel{
                classes = {"tabletopCardChrome"},
                width = 10,
                height = 10,
                halign = "center",
                valign = "center",
                bgimage = "window-chrome/chrome-close.png",
                bgcolor = "white",
                interactable = false,
            },
        }

        item.grips = {
            Grip(item, -1, -1),
            Grip(item, 1, -1),
            Grip(item, -1, 1),
            Grip(item, 1, 1),
        }

        local children = {item.scaler, item.close}
        for _, grip in ipairs(item.grips) do
            children[#children+1] = grip
        end

        item.panel = gui.Panel{
            styles = Styles(),
            classes = {"tabletopCard", "sceneElement"},
            halign = "left",
            valign = "top",
            width = 10,
            height = 10,
            cornerRadius = 8,
            flow = "none",
            draggable = true,
            --the drag moves the card itself (Dragging), within the scene.
            dragMove = false,
            swallowPress = true,
            raiseOnPress = true,
            data = {charid = el.charid},
            hover = function(element)
                ShowChrome(item, true)
            end,
            dehover = function(element)
                ShowChrome(item, false)
            end,
            rightClick = function(element)
                ShowMenu(item, element)
            end,
            beginDrag = function(element)
                BeginDrag(item)
            end,
            dragging = function(element)
                Dragging(item, element)
            end,
            drag = function(element)
                Drop(item, element)
            end,
            create = function(element)
                element:FireEventTree("refreshCard")
            end,
            children = children,
        }
        UpdatePermissions(item)
        layer:AddChild(item.panel)
        return item
    end

    local function Sync()
        local elements = SceneElements.Elements(sceneid)
        for id, item in pairs(m_items) do
            local el = elements[id]
            local kind = el ~= nil and SceneElements.kinds[el.kind] or nil
            if el == nil or kind == nil or kind.key(el) ~= item.key or not item.panel.valid then
                if item.panel.valid then
                    item.panel:DestroySelf()
                end
                m_items[id] = nil
            end
        end
        local count = 0
        local order = {}
        for id, el in pairs(elements) do
            count = count + 1
            local item = m_items[id]
            if item == nil then
                item = BuildItem(id, el)
                m_items[id] = item
            end
            --a card being dragged here keeps the drag's spot.
            if g_drag == nil or g_drag.item ~= item then
                item.el = el
            end
            UpdatePermissions(item)
            order[#order+1] = item
        end
        table.sort(order, function(a, b)
            local za, zb = tonumber(a.el.z) or 0, tonumber(b.el.z) or 0
            if za ~= zb then
                return za < zb
            end
            return a.id < b.id
        end)
        local ids = {}
        for i, item in ipairs(order) do
            ids[i] = item.id
        end
        local signature = table.concat(ids, ",")
        if signature ~= m_order then
            m_order = signature
            for _, item in ipairs(order) do
                item.panel:SetAsLastSibling()
            end
        end
        if count ~= layer.data.count then
            layer.data.count = count
            if options.onCount ~= nil then
                options.onCount(count)
            end
        end
    end

    --Redraws every card at its current place on a resized stage.
    Restage = function()
        for _, item in pairs(m_items) do
            if item.panel.valid and item.cur ~= nil then
                Position(layer, item, item.cur.x, item.cur.y, item.cur.w)
            end
        end
    end

    --Eases every card towards where it should be (a remote drag, or the
    --document); a card this user is dragging is where the drag has it.
    local function Animate()
        for id, item in pairs(m_items) do
            if item.panel.valid and (g_drag == nil or g_drag.item ~= item) then
                local tx, ty, tw = TargetOf(sceneid, id, item.el)
                --this user's own drop, until the document has it.
                local pending = item.pending
                if pending ~= nil then
                    local landed = math.abs(item.el.x - pending.x) < 1e-4 and math.abs(item.el.y - pending.y) < 1e-4 and math.abs(item.el.w - pending.w) < 1e-4
                    if landed or dmhub.Time() - pending.t > FINAL_SECONDS then
                        item.pending = nil
                    else
                        tx, ty, tw = pending.x, pending.y, pending.w
                    end
                end
                local cur = item.cur
                if cur == nil then
                    Position(layer, item, tx, ty, tw)
                else
                    local dx, dy, dw = tx - cur.x, ty - cur.y, tw - cur.w
                    if math.abs(dx) > 1e-4 or math.abs(dy) > 1e-4 or math.abs(dw) > 1e-4 then
                        Position(layer, item, cur.x + dx * 0.45, cur.y + dy * 0.45, cur.w + dw * 0.45)
                    elseif dx ~= 0 or dy ~= 0 or dw ~= 0 then
                        Position(layer, item, tx, ty, tw)
                    end
                end
            end
        end
        MoveGhost()
        --the cards' portraits, stamina and conditions repaint twice a second.
        local now = dmhub.Time()
        if now - m_refresh > 0.5 then
            m_refresh = now
            for _, item in pairs(m_items) do
                if item.panel.valid then
                    item.panel:FireEventTree("refreshCard")
                end
            end
        end
    end

    layer = gui.Panel{
        classes = {"sceneElementsLayer", ChatItemLinks.ITEM_DROP_TARGET_CLASS},
        halign = "center",
        valign = "center",
        width = 1,
        height = 1,
        flow = "none",
        --drop targets are found by what is under the mouse, so the layer
        --needs a (clear) background to count over the picture.
        bgimage = "panels/square.png",
        bgcolor = "clear",
        tokenDropTarget = true,
        data = {sceneid = sceneid, sw = 1, sh = 1, background = false, count = 0},
        monitorGame = SceneElements.DocPath(sceneid),
        refreshGame = function(element)
            Sync()
        end,
        create = function(element)
            Sync()
        end,
        destroy = function(element)
            DestroyGhost()
        end,

        --the picture's rectangle in the view (FullscreenDisplay.CreateSceneView).
        setStage = function(element, w, h)
            if math.abs(w - element.data.sw) < 0.5 and math.abs(h - element.data.sh) < 0.5 then
                return
            end
            element.data.sw = math.max(1, w)
            element.data.sh = math.max(1, h)
            element.selfStyle.width = element.data.sw
            element.selfStyle.height = element.data.sh
            --every card moves with the stage now, not on the next think, so a
            --resizing window carries its cards smoothly.
            Restage()
        end,

        --the table's background (a maximized scene under the UI): the mouse
        --goes through it to the table, so the tabletop's drop handlers pass
        --drops on it here (DropOnBackground). Its cards still take the mouse.
        setBackground = function(element, background)
            background = background == true
            if element.data.background ~= background then
                element.data.background = background
                element.interactable = not background
            end
        end,

        thinkTime = 0.03,
        think = function(element)
            Animate()
        end,

        --panel drags (rows, table cards, other scenes' cards; ChatItemLinks).
        itemLinkDragHover = function(element, items)
            if items == nil then
                DestroyGhost()
            else
                ShowGhost(DroppableItem(items))
            end
        end,
        itemLinkDrop = function(element, items)
            TakeDrop(items)
        end,

        --map tokens dragged off the board.
        tokenDragEnter = function(element, info)
            ShowGhost(DroppableItem(CharacterItems(info.charids)))
        end,
        tokenDragLeave = function(element)
            DestroyGhost()
        end,
        dropTokens = function(element, info)
            TakeDrop(CharacterItems(info.charids))
        end,
    }
    g_layers[layer] = true
    return layer
end
