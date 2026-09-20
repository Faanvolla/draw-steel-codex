--Encounter of the Week: the montage stage.
--
--The full-screen presentation every client sees while a montage beat plays:
--the scene as a backdrop, the round's Opportunities down the left and
--Threats down the right, the party's hero cards along the bottom (drag one
--onto an entry to approach it), and the current turn in the middle -- the
--approach text, the options with their power rolls, then the landed tier
--and what it did. After the last round the middle shows each unresolved
--threat in turn with the malice diamond and its consequence.
--
--Shown through GameHud's presented-dialog mechanism (the host presents it;
--every client, late joiners included, instantiates it from the shared
--presentdialog document). All state comes from EncounterMontage's document;
--this file never writes montage state, only requests.
--Design: EncounterOfTheWeek.md, "Encounter scripts: montage beats before combat".

local mod = dmhub.GetModLoading()

EncounterMontageStage = rawget(_G, "EncounterMontageStage") or {}

local DIALOG_ID = "eotwmontage"

local HEADER_HEIGHT = 76
--The montage header is auto-height so the intro prose can wrap; this is as
--far as it is allowed to push the body down (title + the intro's own
--maxHeight + the round line).
local HEADER_HEIGHT_MAX = 260
--where the right rail parks the malice / hero-token strip: the rail's top
--inset (IconRailTop, 64 at the default zoom) and its 12-unit edge margin.
--The stage covers the rail, so it shows the same strip in the same spot.
local POOLS_TOP = 64
local POOLS_RIGHT = 12
--a montage hero card (176 + its 46-tall skills block) plus one row of
--ally cards (80) and their gaps.
local HERO_ROW_HEIGHT = 320
local COLUMN_WIDTH = "25%"
local CENTER_WIDTH = "46%"

local TIER_RANGES = { "11 or lower", "12-16", "17+", "19-20" }

--the montage haul: one icon per distinct item a hero has been granted,
--stacked down a reserved gutter to the LEFT of their card. The gutter is
--always reserved (even empty) so the row of cards doesn't shuffle
--sideways the moment the first item lands.
local ITEM_ICON_SIZE = 30
local ITEM_STRIP_WIDTH = ITEM_ICON_SIZE + 4
--how far above its slot a newly granted item starts, how long it takes to
--fall into place, and how far apart two items landing in the same refresh
--are staggered (so a pair of grants reads as two pickups, not one thud).
local ITEM_DROP_HEIGHT = ITEM_ICON_SIZE + 14
local ITEM_DROP_TIME = 0.4
local ITEM_DROP_STAGGER = 0.18

--entry cards come and go with the rounds rather than sitting on the stage
--greyed out ahead of time: an entry materializes on the round it enters,
--and one that has been dealt with fades away when that round ends. How
--long each takes, how far apart two cards materializing together are
--staggered, and how far a card is offset while it is ramping in or out.
local ENTRY_APPEAR_TIME = 0.5
local ENTRY_APPEAR_STAGGER = 0.15
local ENTRY_FADE_TIME = 0.5
local ENTRY_APPEAR_OFFSET = 30

--the mounted stage (one per client) and the hero picked by a click, for
--the click-a-hero-then-click-an-entry alternative to dragging.
local m_root = nil
local m_selectedHero = nil

--The action bar renders above windows (renderOnTop), so it paints straight
--through a full-screen stage; the stage hides it through the transient
--"hideactionbar" setting the bar already monitors. It is REF COUNTED because
--one stage beat hands over to the next by creating the new stage before the
--old one is destroyed: the first stage up captures the value to put back and
--the last one down restores it, so the bar neither blinks through a cut nor
--stays hidden after the last stage goes.
local m_actionBarHiders = 0
local m_actionBarRestore = false

local function AcquireActionBarHide()
    if m_actionBarHiders == 0 then
        m_actionBarRestore = dmhub.GetSettingValue("hideactionbar")
        dmhub.SetSettingValue("hideactionbar", true)
    end
    m_actionBarHiders = m_actionBarHiders + 1
end

local function ReleaseActionBarHide()
    m_actionBarHiders = math.max(0, m_actionBarHiders - 1)
    if m_actionBarHiders > 0 then
        return
    end
    --A stage handing over to the next may be destroyed either side of the new
    --one's create, so do not put the bar back until we know nothing has taken
    --it straight back; otherwise the bar blinks through the cut.
    dmhub.Schedule(0.15, function()
        if mod.unloaded or m_actionBarHiders > 0 then
            return
        end
        dmhub.SetSettingValue("hideactionbar", m_actionBarRestore or false)
    end)
end

local function Broadcast(eventName, ...)
    if m_root ~= nil and m_root.valid then
        m_root:FireEventTree(eventName, ...)
    end
end

--what a pick-up or a click is offering to do with the selected hero:
--"approach" (take a beat) or "assist" (help the test in flight).
local m_selectMode = "approach"

local function SelectHero(charid, mode)
    m_selectedHero = charid
    m_selectMode = mode or "approach"
    Broadcast("selectHero", charid, m_selectMode)
end

--The heroes who could assist the turn in flight, keyed by charid, memoized
--for the life of one turn state so seven hero columns refreshing at 0.5s do
--not each walk the party's skill lists.
local m_assistCache = { key = nil, set = {}, list = {} }

local function AssistCache(m)
    local t = (m ~= nil and m.turn) or {}
    local key = table.concat({ tostring(t.seq), tostring(t.status), tostring(t.skillid), tostring(t.optionIndex) }, "|")
    if m_assistCache.key ~= key then
        local set = {}
        local list = {}
        if t.status == "assist" then
            local ok, candidates = pcall(function()
                --CurrentBeat returns (beat, script); bind it or the trailing
                --call expands BOTH into the argument list and the script
                --arrives as the "heroes" parameter, which ipairs walks as
                --empty -- every hero silently ineligible.
                local beat = EncounterMontage.CurrentBeat()
                return EncounterMontage.EligibleAssistants(m, beat)
            end)
            if ok and candidates ~= nil then
                list = candidates
                for _, candidate in ipairs(candidates) do
                    set[candidate.charid] = candidate
                end
            end
        end
        m_assistCache = { key = key, set = set, list = list }
    end
    return m_assistCache
end

--Keyed by charid, for the hero cards' "!" badge.
local function AssistCandidates(m)
    return AssistCache(m).set
end

--In Heroes() order, for the assist slot's "who could help" line.
local function AssistCandidatesList(m)
    return AssistCache(m).list
end

local function Hud()
    return rawget(_G, "EncounterOfTheWeekHud")
end

--A class list from optional entries: false/nil entries are dropped, so the
--list never has holes (the engine stops at the first nil).
local function Classes(...)
    local result = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v then
            result[#result + 1] = v
        end
    end
    return result
end

local function StageRules()
    local rules = {}
    local hud = Hud()
    if hud ~= nil and hud.HeroCardRules ~= nil then
        for _, rule in ipairs(hud.HeroCardRules()) do
            rules[#rules + 1] = rule
        end
    end
    local own = {
        {
            selectors = {"eotwStageTitle"},
            fontSize = 34,
            bold = true,
            color = "#ffffff",
            width = "auto",
            height = "auto",
            textAlignment = "center",
        },
        {
            selectors = {"eotwStageSubtitle"},
            fontSize = 16,
            color = "#d0d0d0",
            width = "auto",
            height = "auto",
            textAlignment = "center",
            maxWidth = 1100,
        },
        {
            --The montage's context prose (the paragraph under "# Montage").
            --It stands in for the Director's read-aloud, so it is sized to
            --be read at a glance from across the table and wraps to as many
            --lines as the writing needs; the header grows to fit it.
            selectors = {"eotwMontageIntro"},
            fontSize = 19,
            italics = true,
            color = "#efe4cc",
            width = "auto",
            height = "auto",
            maxWidth = 1000,
            --about seven wrapped lines: a generous read-aloud paragraph.
            --Past that the header would start eating the entry columns, so
            --the prose is clipped instead (HEADER_HEIGHT_MAX matches).
            maxHeight = 186,
            textAlignment = "center",
            tmargin = 2,
            bmargin = 4,
        },
        {
            selectors = {"eotwStageRound"},
            fontSize = 18,
            bold = true,
            color = "#ffd66b",
            width = "auto",
            height = "auto",
            textAlignment = "center",
        },
        {
            selectors = {"eotwColumnTitle"},
            fontSize = 22,
            bold = true,
            color = "#ffffff",
            width = "100%",
            height = 30,
            textAlignment = "center",
            bmargin = 6,
        },
        {
            selectors = {"eotwEntryCard"},
            bgcolor = "#0f1318e6",
            border = 2,
            borderColor = "#ffffff40",
            cornerRadius = 8,
            transitionTime = 0.15,
        },
        {
            selectors = {"eotwEntryCard", "opportunity"},
            borderColor = "#d4a83ab0",
        },
        {
            selectors = {"eotwEntryCard", "threat"},
            borderColor = "#c0392bb0",
        },
        --highlight states tint the card's background toward its accent colour rather than
        --raising brightness: brightness washes out the child labels and made them unreadable.
        {
            selectors = {"eotwEntryCard", "hover"},
            bgcolor = "#1d2430f2",
            borderColor = "#ffffffc0",
        },
        {
            selectors = {"eotwEntryCard", "opportunity", "hover"},
            bgcolor = "#2a2313f2",
            borderColor = "#d4a83aff",
        },
        {
            selectors = {"eotwEntryCard", "threat", "hover"},
            bgcolor = "#2a1613f2",
            borderColor = "#c0392bff",
        },
        {
            selectors = {"eotwEntryCard", "done"},
            brightness = 0.55,
            saturation = 0.3,
        },
        {
            selectors = {"eotwEntryCard", "active"},
            bgcolor = "#1d2430f2",
            borderColor = "#ffffffff",
        },
        {
            selectors = {"eotwEntryCard", "opportunity", "active"},
            bgcolor = "#2a2313f2",
            borderColor = "#f0c75cff",
        },
        {
            selectors = {"eotwEntryCard", "threat", "active"},
            bgcolor = "#2a1613f2",
            borderColor = "#e05a4aff",
        },
        --an entry the dragged / selected hero may be dropped on.
        {
            selectors = {"eotwEntryCard", "droppable"},
            bgcolor = "#243044f2",
            borderColor = "#ffffffff",
            border = 3,
        },
        {
            selectors = {"eotwEntryCard", "opportunity", "droppable"},
            bgcolor = "#372d15f2",
            borderColor = "#f0c75cff",
            border = 3,
        },
        {
            selectors = {"eotwEntryCard", "threat", "droppable"},
            bgcolor = "#371a15f2",
            borderColor = "#e05a4aff",
            border = 3,
        },
        --materializing in, and fading out again. Same shape as the item
        --drop-in above: the card is put into the start state IMMEDIATELY
        --(SetClassTreeImmediate ignores transitionTime), so it simply
        --starts small, transparent and pushed down; taking the class off
        --ramps THIS rule back out over its own transitionTime, which is
        --the animation. The timing therefore has to live on the rule
        --whose match changes, not on a resting-state rule.
        --
        --Style opacity is NOT inherited by children (SheetPanel applies it
        --to its own background, SheetLabel to its own text), so the class
        --goes on the whole card subtree and the opacity rule is written
        --without "eotwEntryCard" so it matches the labels inside too. The
        --transform bits (scale, y) move children with the card, so they
        --stay on the card alone.
        {
            selectors = {"eotwEntryAppear"},
            opacity = 0,
            transitionTime = ENTRY_APPEAR_TIME,
            easing = "easeOutCubic",
        },
        {
            selectors = {"eotwEntryCard", "eotwEntryAppear"},
            scale = 0.85,
            y = ENTRY_APPEAR_OFFSET,
            transitionTime = ENTRY_APPEAR_TIME,
            easing = "easeOutCubic",
        },
        --an entry dealt with this round fades away once the round ends,
        --and is destroyed when the fade has run.
        {
            selectors = {"eotwEntryLeave"},
            opacity = 0,
            transitionTime = ENTRY_FADE_TIME,
            easing = "easeInCubic",
        },
        {
            selectors = {"eotwEntryCard", "eotwEntryLeave"},
            scale = 0.9,
            transitionTime = ENTRY_FADE_TIME,
            easing = "easeInCubic",
        },
        {
            selectors = {"eotwEntryName"},
            fontSize = 19,
            bold = true,
            color = "#ffffff",
            width = "100%",
            height = "auto",
            textAlignment = "left",
        },
        {
            selectors = {"eotwEntryDesc"},
            fontSize = 14,
            color = "#dcdcdc",
            width = "100%",
            height = "auto",
            textAlignment = "left",
            tmargin = 4,
        },
        {
            selectors = {"eotwEntryStatus"},
            fontSize = 13,
            italics = true,
            color = "#b0b0b0",
            width = "100%",
            height = "auto",
            textAlignment = "left",
            tmargin = 6,
        },
        --the strip of items a hero has picked up this montage, down the
        --left edge of their card.
        {
            selectors = {"eotwItemIcon"},
            width = ITEM_ICON_SIZE,
            height = ITEM_ICON_SIZE,
            halign = "center",
            valign = "top",
            bmargin = 4,
            cornerRadius = 5,
            border = 1,
            borderColor = "#ffffff50",
            bgcolor = "white",
        },
        {
            selectors = {"eotwItemIcon", "hover"},
            borderColor = "#ffd66bff",
            brightness = 1.25,
        },
        --an item being carried to another hero.
        {
            selectors = {"eotwItemIcon", "dragging"},
            opacity = 0.4,
        },
        --a hero card that can take the item being dragged.
        {
            selectors = {"eotwHeroCard", "droppable"},
            borderColor = "#ffd66bff",
            border = 3,
            brightness = 1.15,
        },
        --the drop-in. An icon is BORN with "dropIn", and a rule that is
        --present at construction applies at full strength immediately, so
        --the icon simply starts raised and transparent; taking the class
        --off ramps that rule back OUT over its own transitionTime, which
        --is the fall. The timing therefore has to live on THIS rule -- the
        --one whose match changes -- not on a rule for the resting state
        --(verified live: a resting-state rule's y never arrives at all,
        --because style y accumulates over every matching rule rather than
        --being overridden by the last one). (Style y is a post-layout
        --render offset and NEGATIVE y is up.)
        {
            selectors = {"eotwItemIcon", "dropIn"},
            y = -ITEM_DROP_HEIGHT,
            opacity = 0,
            transitionTime = ITEM_DROP_TIME,
            easing = "easeOutCubic",
        },
        --a second copy of an item the hero already has bumps the icon it
        --already owns instead of adding a new one, so that gain gets a
        --pulse (PulseClass applies this instantly and fades it back out
        --over the rule's transitionTime).
        {
            selectors = {"eotwItemIcon", "bump"},
            scale = 1.3,
            brightness = 1.5,
            transitionTime = 0.3,
            easing = "easeOutCubic",
        },
        {
            selectors = {"eotwItemQty"},
            fontSize = 10,
            bold = true,
            color = "#ffffff",
            width = "auto",
            height = "auto",
            halign = "right",
            valign = "bottom",
            textAlignment = "right",
            bgimage = "panels/square.png",
            bgcolor = "#000000c0",
            cornerRadius = 3,
            hpad = 2,
        },
        {
            selectors = {"eotwTurnPanel"},
            bgcolor = "#0b0e12e0",
            border = 2,
            borderColor = "#ffffff30",
            cornerRadius = 10,
        },
        {
            selectors = {"eotwTurnTitle"},
            fontSize = 26,
            bold = true,
            color = "#ffffff",
            width = "100%",
            height = "auto",
            textAlignment = "center",
        },
        {
            selectors = {"eotwTurnText"},
            fontSize = 16,
            color = "#e6e6e6",
            width = "100%",
            height = "auto",
            textAlignment = "center",
            vmargin = 6,
        },
        {
            selectors = {"eotwTurnHint"},
            fontSize = 15,
            italics = true,
            color = "#b8b8b8",
            width = "100%",
            height = "auto",
            textAlignment = "center",
            vmargin = 6,
        },
        {
            selectors = {"eotwOptionCard"},
            bgcolor = "#161b22f0",
            border = 1,
            borderColor = "#ffffff30",
            cornerRadius = 6,
            transitionTime = 0.12,
        },
        {
            selectors = {"eotwOptionCard", "actionable", "hover"},
            borderColor = "#ffffffc0",
            brightness = 1.2,
        },
        {
            selectors = {"eotwOptionCard", "chosen"},
            borderColor = "#ffd66bff",
        },
        --a test only some heroes may take: violet when this hero unlocked
        --it, dimmed and inert when they did not
        {
            selectors = {"eotwOptionCard", "unlocked"},
            borderColor = "#c58cffc0",
            bgcolor = "#1d1626f0",
        },
        {
            selectors = {"eotwOptionCard", "unlocked", "actionable", "hover"},
            borderColor = "#e2c6ffff",
        },
        {
            selectors = {"eotwOptionCard", "locked"},
            borderColor = "#ffffff18",
            brightness = 0.55,
        },
        {
            selectors = {"eotwRider"},
            fontSize = 13,
            color = "#a8a8a8",
            width = "100%",
            height = "auto",
            textAlignment = "left",
            bmargin = 3,
        },
        {
            selectors = {"eotwRider", "unlocked"},
            color = "#d9b3ff",
            bold = true,
        },
        {
            selectors = {"eotwRider", "locked"},
            color = "#e08c8c",
        },
        {
            selectors = {"eotwRider", "met"},
            color = "#9be29b",
            bold = true,
        },
        {
            selectors = {"eotwRider", "hurt"},
            color = "#e08c8c",
            bold = true,
        },
        {
            selectors = {"eotwRider", "unmet"},
            color = "#6a6a6a",
        },
        {
            selectors = {"eotwOptionName"},
            fontSize = 18,
            bold = true,
            color = "#ffffff",
            width = "100%",
            height = "auto",
            textAlignment = "left",
        },
        {
            selectors = {"eotwOptionRoll"},
            fontSize = 15,
            bold = true,
            color = "#9cc4ff",
            width = "100%",
            height = "auto",
            textAlignment = "left",
            bmargin = 4,
        },
        {
            selectors = {"eotwTierRange"},
            fontSize = 13,
            bold = true,
            color = "#a0a0a0",
            width = 80,
            height = "auto",
            textAlignment = "left",
            valign = "top",
        },
        {
            selectors = {"eotwTierText"},
            fontSize = 14,
            color = "#d8d8d8",
            width = "100%-84",
            height = "auto",
            textAlignment = "left",
            valign = "top",
        },
        {
            selectors = {"eotwTierRange", "landed"},
            color = "#ffd66b",
        },
        {
            selectors = {"eotwTierText", "landed"},
            color = "#ffd66b",
            bold = true,
        },
        {
            selectors = {"eotwTierText", "dim"},
            color = "#707070",
        },
        {
            selectors = {"eotwTierRange", "dim"},
            color = "#606060",
        },
        {
            selectors = {"eotwAppliedLine"},
            fontSize = 16,
            bold = true,
            color = "#8ee08e",
            width = "100%",
            height = "auto",
            textAlignment = "center",
            vmargin = 2,
        },
        --the assist slot: where a second hero is dropped to lend a hand to
        --a test that landed below tier 3.
        {
            selectors = {"eotwAssistSlot"},
            bgcolor = "#161b22f0",
            border = 2,
            borderColor = "#ffffff40",
            borderWidth = 2,
            cornerRadius = 8,
            transitionTime = 0.15,
        },
        {
            selectors = {"eotwAssistSlot", "droppable"},
            bgcolor = "#1b2740f2",
            borderColor = "#9cc4ffff",
            border = 3,
        },
        {
            selectors = {"eotwAssistTitle"},
            fontSize = 18,
            bold = true,
            color = "#9cc4ff",
            width = "100%",
            height = "auto",
            textAlignment = "center",
        },
        --the "!" a hero wears while they could assist the test in flight.
        {
            selectors = {"eotwAssistBadge"},
            bgcolor = "#1b2740ff",
            borderColor = "#9cc4ffff",
            border = 2,
            cornerRadius = 11,
        },
        {
            selectors = {"eotwAssistBadgeText"},
            fontSize = 16,
            bold = true,
            color = "#9cc4ff",
            width = "auto",
            height = "auto",
            halign = "center",
            valign = "center",
            textAlignment = "center",
        },
        {
            selectors = {"eotwHeroCard", "acted"},
            saturation = 0.15,
            brightness = 0.45,
        },
        {
            selectors = {"eotwHeroCard", "dragging"},
            brightness = 1.2,
        },
        {
            selectors = {"eotwHeroCard", "selected"},
            borderColor = "#ffd66bff",
            border = 3,
            brightness = 1.15,
        },
        --the narrative stage: the section's prose, the option cards as drop
        --targets, the chips saying who chose what, and the flash that
        --settles a split decision.
        {
            selectors = {"eotwNarrativeText"},
            fontSize = 20,
            color = "#e8e4dc",
            width = "100%",
            height = "auto",
            textAlignment = "center",
            bmargin = 12,
        },
        {
            selectors = {"eotwNarrativePrompt"},
            fontSize = 17,
            italics = true,
            color = "#ffd66b",
            width = "100%",
            height = "auto",
            textAlignment = "center",
            bmargin = 10,
        },
        {
            selectors = {"eotwOptionCard", "droppable"},
            bgcolor = "#243018f2",
            borderColor = "#b8e04aff",
        },
        {
            selectors = {"eotwOptionCard", "flashing"},
            bgcolor = "#2a2313f2",
            borderColor = "#ffd66bff",
            brightness = 1.2,
        },
        {
            selectors = {"eotwChoiceChip"},
            fontSize = 13,
            color = "#9cc4ff",
            width = "100%",
            height = "auto",
            textAlignment = "center",
            tmargin = 6,
        },
        {
            selectors = {"eotwHeroChoice"},
            fontSize = 12,
            bold = true,
            color = "#b8e04a",
            width = 132,
            height = "auto",
            textAlignment = "center",
            tmargin = 2,
        },
        {
            selectors = {"eotwHeroChoice", "waiting"},
            color = "#d0d0d0",
            bold = false,
            italics = true,
        },
        {
            selectors = {"eotwDecideBanner"},
            fontSize = 26,
            bold = true,
            color = "#ffd66b",
            width = "100%",
            height = "auto",
            textAlignment = "center",
            vmargin = 6,
        },
        {
            selectors = {"eotwDecideName"},
            fontSize = 34,
            bold = true,
            color = "#ffffff",
            width = "100%",
            height = "auto",
            textAlignment = "center",
        },
        {
            selectors = {"eotwHeroCard", "flashing"},
            borderColor = "#ffd66bff",
            border = 4,
            brightness = 1.35,
        },
    }
    for _, rule in ipairs(own) do
        rules[#rules + 1] = rule
    end
    return rules
end

--- small builders ----------------------------------------------------------------

local function Portrait(charid, size)
    return gui.Panel{
        width = size,
        height = size,
        cornerRadius = 6,
        bgimage = "panels/square.png",
        bgcolor = "#222222",
        interactable = false,
        create = function(element)
            local tok = dmhub.GetCharacterById(charid)
            if tok == nil or not tok.valid then
                return
            end
            local portrait = nil
            pcall(function() portrait = tok.offTokenPortrait end)
            if portrait ~= nil and portrait ~= "" then
                element.bgimage = portrait
                element.selfStyle.bgcolor = "white"
                local rect = nil
                pcall(function() rect = tok:GetPortraitRectForAspect(1, portrait) end)
                element.selfStyle.imageRect = rect
            end
        end,
    }
end

local function MaliceIcon(size)
    local hud = Hud()
    local diamond = nil
    if hud ~= nil and hud.CreateMaliceDiamond ~= nil then
        diamond = hud.CreateMaliceDiamond()
    end
    return gui.Panel{
        width = size,
        height = size,
        halign = "center",
        valign = "center",
        interactable = false,
        uiscale = size / 26,
        diamond,
    }
end

--The recognized-rules colours: the green the applied-effect lines already
--use, and a muted version of it for a dimmed row.
local RULES_COLOR = "#8ee08e"
local RULES_COLOR_DIM = "#5d7a5d"

--What one tier row reads. A tier with a "teaser => full text" line shows
--only its teaser until it is the landed tier
--(EncounterScript.TierDisplayText); tiers not achieved keep their teaser.
--
--Wherever the FULL text is on show -- the landed tier, and any tier
--written without a teaser -- every clause the effect grammar recognizes is
--coloured the applied-effect green, so a player can see at a glance which
--words the montage will actually act on and which are flavour. A teaser is
--never marked: the grammar only ever parses the full text.
local function TierText(roll, t, landed, dim)
    local text = EncounterScript.TierDisplayText(roll, t, landed)
    local teaser = roll.teasers ~= nil and roll.teasers[t] or nil
    if (not landed) and teaser ~= nil then
        return text
    end
    local color = dim and RULES_COLOR_DIM or RULES_COLOR
    return EncounterScript.MarkupRules(text, string.format("<color=%s>", color), "</color>")
end

local function TierRows(roll, landedTier, dimOthers)
    local rows = {}
    for t in ipairs(roll.tiers) do
        local range = TIER_RANGES[t] or ""
        if #roll.tiers == 4 and t == 3 then
            range = "17-18"
        end
        local landed = landedTier == t
        local dim = dimOthers and landedTier ~= nil and not landed
        local tierText = TierText(roll, t, landed, dim)
        rows[#rows + 1] = gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            vmargin = 1,
            interactable = false,
            gui.Label{ classes = Classes("eotwTierRange", landed and "landed", dim and "dim"), text = range, interactable = false },
            gui.Label{ classes = Classes("eotwTierText", landed and "landed", dim and "dim"), text = tierText, interactable = false },
        }
        rows[#rows].data = { roll = roll, tier = t }
    end
    return rows
end

--Re-mark a set of tier rows with the landed tier (nil = none landed yet).
--Live rows follow the dice, so a teaser is revealed while the running tier
--sits on it and hidden again when the dice move on.
local function SetLandedTier(rows, landedTier)
    for t, row in ipairs(rows) do
        local landed = landedTier == t
        local dim = landedTier ~= nil and not landed
        for _, label in ipairs(row.children) do
            label:SetClass("landed", landed)
            label:SetClass("dim", dim)
        end
        local d = row.data
        if d ~= nil and d.roll ~= nil then
            row.children[2].text = TierText(d.roll, t, landed, dim)
        end
    end
end

--The tier rows of the option being rolled, highlighting the tier the dice
--are landing on WHILE they tumble, the way the remote ability card's tier
--table does (Timeline/AbilitySidebar.lua). The roll dialog broadcasts its
--state to the shared ability document (BroadcastDialogState ->
--CharacterPanel.UpdateAbilitySharing): while rollState is "rolling" we
--look up the chat message by dialogState.rollId, subscribe to each die's
--DiceEvents and recompute the running tier on every 'diceface'; when the
--dice settle, or once rollState is "finished", the broadcast
--highlightedTier (which already includes post-roll edges/banes) wins.
--The roller's own client reads the same document it writes, so every
--client runs the one code path. Falls back to plain rows on a core
--without the share exports.
local function LiveTierRows(roll)
    local rows = TierRows(roll, nil, true)
    if CharacterPanel.AbilityShareDocPath == nil or CharacterPanel.GetAbilityShareData == nil then
        return rows
    end

    local function ShareState()
        local share = nil
        pcall(function() share = CharacterPanel.GetAbilityShareData() end)
        if share == nil then
            return nil
        end
        return share.dialogState
    end

    --the tier a running total of the dice would land on, using the roll
    --message's own edges/banes/tier shifts.
    local function RunningTier(d, total)
        local rm = d.rollMsg
        local tier = 1
        pcall(function()
            tier = RollUtils.DiceResultToTier{
                total = total,
                naturalRoll = total - d.mod,
                boons = rm.boons,
                banes = rm.banes,
                tiers = rm.tiers,
                autosuccess = rm.autosuccess,
                autofailure = rm.autofailure,
                nottierthree = rm.nottierthree,
                nottierone = rm.nottierone,
            }
        end)
        return tier
    end

    return {
        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "vertical",
            interactable = false,
            children = rows,
            data = { rollId = nil, finished = false },

            monitorGame = CharacterPanel.AbilityShareDocPath(),
            refreshGame = function(element)
                element:FireEvent("syncRoll")
            end,
            create = function(element)
                element:FireEvent("syncRoll")
            end,

            syncRoll = function(element)
                local ds = ShareState()
                if ds == nil then
                    return
                end
                local d = element.data

                if ds.rollState == "rolling" and ds.rollId ~= nil and ds.rollId ~= d.rollId then
                    local rollMsg = nil
                    for _, msg in ipairs(chat.messages) do
                        if msg.key == ds.rollId then
                            rollMsg = msg
                            break
                        end
                    end
                    if rollMsg == nil then
                        --the chat message lands a beat after the broadcast.
                        element:ScheduleEvent("syncRoll", 0.1)
                        return
                    end
                    local flat = rollMsg.total or 0
                    local numDice = 0
                    for _, r in ipairs(rollMsg.rolls or {}) do
                        flat = flat - r.result
                        local events = chat.DiceEvents(r.guid)
                        if events ~= nil then
                            events:Listen(element)
                            numDice = numDice + 1
                        end
                    end
                    element.data = {
                        rollId = ds.rollId,
                        rollMsg = rollMsg,
                        mod = flat,
                        numDice = numDice,
                        faces = {},
                        endTime = nil,
                        finished = false,
                    }
                    element.thinkTime = 0.1
                    if numDice == 0 and rollMsg.total ~= nil then
                        element.data.finished = true
                        SetLandedTier(rows, RunningTier(element.data, rollMsg.total))
                    else
                        SetLandedTier(rows, nil)
                    end
                    return
                end

                --not animating (or already settled): the broadcast tier is
                --authoritative, and it moves with post-roll edges/banes.
                if d.rollId == nil or d.finished then
                    if ds.rollState == "finished" or ds.rollState == "rolling" then
                        SetLandedTier(rows, ds.highlightedTier)
                    elseif d.rollId == nil then
                        SetLandedTier(rows, nil)
                    end
                end
            end,

            diceface = function(element, diceguid, num, timeRemaining)
                local d = element.data
                if d == nil or d.rollId == nil or d.finished then
                    return
                end
                local endTime = dmhub.Time() + (timeRemaining or 0)
                d.faces[diceguid] = num
                if d.endTime == nil or endTime > d.endTime then
                    d.endTime = endTime
                end
                local total = d.mod
                local count = 0
                for _, value in pairs(d.faces) do
                    count = count + 1
                    total = total + value
                end
                if count == d.numDice then
                    SetLandedTier(rows, RunningTier(d, total))
                end
            end,

            think = function(element)
                local d = element.data
                if d == nil or d.rollId == nil or d.finished then
                    element.thinkTime = nil
                    return
                end
                if d.endTime ~= nil and dmhub.Time() > d.endTime and d.rollMsg.total ~= nil then
                    d.finished = true
                    element.thinkTime = nil
                    SetLandedTier(rows, RunningTier(d, d.rollMsg.total))
                    --pick up the broadcast tier if it has already moved on.
                    element:FireEvent("syncRoll")
                end
            end,
        },
    }
end

--- entry cards ---------------------------------------------------------------------

--One entry's card. An entry is only ever carded from the round it enters
--onwards (the columns used to carry every entry of the beat, greyed out
--with an "Appears in round N" line; user direction 2026-09-19: an entry
--the party cannot reach yet should not be on the stage at all). `appearIn`
--is the delay after which it materializes -- nil for the cards that come
--up with the stage itself, a stagger offset for the ones a new round
--introduces.
local function CreateEntryCard(entry, appearIn)
    local statusLabel = gui.Label{
        classes = {"eotwEntryStatus"},
        text = "",
        interactable = false,
    }
    local nameChildren = {
        gui.Label{ classes = {"eotwEntryName"}, text = entry.name, interactable = false, width = cond(entry.kind == "threat", "100%-30", "100%") },
    }
    if entry.kind == "threat" then
        nameChildren[#nameChildren + 1] = MaliceIcon(22)
    end
    local nameRow = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "horizontal",
        interactable = false,
        children = nameChildren,
    }
    local card = gui.Panel{
        classes = {"eotwEntryCard", entry.kind},
        width = "100%",
        height = "auto",
        flow = "vertical",
        pad = 10,
        borderBox = true,
        vmargin = 5,
        bgimage = "panels/square.png",
        dragTarget = true,
        dragTargetPriority = 10,
        data = { entryId = entry.id, kind = entry.kind, available = false },

        nameRow,
        gui.Label{ classes = {"eotwEntryDesc"}, text = entry.description, interactable = false },
        statusLabel,

        --the click alternative to dragging: a hero picked by a click on
        --its card, then a click here, approaches.
        press = function(element)
            local heroid = m_selectedHero
            if heroid == nil or m_selectMode ~= "approach" or not element.data.available or not EncounterMontage.LocalUserCanAct(heroid) then
                return
            end
            audio.FireSoundEvent("Mouse.Click")
            SelectHero(nil)
            EncounterMontage.SendRequest("approach", { heroid = heroid, entryId = entry.id })
        end,

        --highlight while a hero is being dragged or has been clicked. A
        --hero picked up to ASSIST is not going anywhere near an entry, so
        --those drags leave the columns alone.
        dragTargets = function(element, on, mode)
            element:SetClass("droppable", on == true and (mode or "approach") == "approach" and element.data.available)
        end,
        selectHero = function(element, heroid, mode)
            element:SetClass("droppable", heroid ~= nil and (mode or "approach") == "approach" and element.data.available)
        end,

        refreshMontage = function(element, m)
            --a card on its way out keeps the face it had when the round
            --ended; it is only fading.
            if element.data.leaving then
                return
            end
            local available = EncounterMontage.EntryAvailable(m, entry)
            local done = false
            local status = ""
            if entry.kind == "opportunity" then
                if (m.taken or {})[entry.id] then
                    done = true
                    status = "Taken"
                end
            else
                if (m.vanquished or {})[entry.id] then
                    done = true
                    status = "Vanquished"
                end
            end
            --a resolved turn is over: its entry is open again at once (an
            --unvanquished threat may be tried by the next hero).
            local active = m.turn ~= nil and m.turn.entryId == entry.id and m.turn.status ~= "resolved"
            if active then
                status = string.format("%s is here", m.turn.heroName or "A hero")
            elseif status == "" and available then
                status = "Drag a hero here"
            end
            element.data.available = available and not active
            element:SetClass("done", done)
            element:SetClass("active", active)
            element:SetClass("droppable", m_selectedHero ~= nil and m_selectMode == "approach" and element.data.available)
            statusLabel.text = status
        end,

        --the round ended and this entry was dealt with: fade the card away
        --and drop it, so the columns carry only what is still in play.
        leave = function(element)
            if element.data.leaving then
                return
            end
            element.data.leaving = true
            element.data.available = false
            element:SetClassTree("eotwEntryLeave", true)
            element:ScheduleEvent("gone", ENTRY_FADE_TIME + 0.05)
        end,
        gone = function(element)
            element:DestroySelf()
        end,
    }

    if appearIn ~= nil then
        --into the start state with no ramp, then a frame (plus this card's
        --stagger) later the class comes off and the transition runs.
        card:SetClassTreeImmediate("eotwEntryAppear", true)
        dmhub.Schedule(0.05 + appearIn, function()
            if mod.unloaded or card == nil or not card.valid then
                return
            end
            card:SetClassTree("eotwEntryAppear", false)
        end)
    end

    return card
end

--- the turn panel -----------------------------------------------------------------

local function IsMyTurn(m)
    return m.turn ~= nil and m.turn.userid == dmhub.loginUserid
end

--One line per rider on a test ("Edge: You speak Caelian"), coloured by how
--it fell for the hero at the entry when a verdict is known: an Allow rider
--reads "Unlocked" (violet) once met; an edge/bane rider lights green/red
--when it applies and dims when it does not. With no verdict (nobody at the
--entry) the lines are plain.
--A hero who does not meet an Allow requirement is not read the requirement
--back at them: every unmet Allow on the card collapses into one plain line
--(user direction 2026-09-19).
local function RiderRows(roll, verdict)
    local rows = {}
    local saidLocked = false
    for _, row in ipairs(TestRiders.DescribeRows(roll.riders, verdict)) do
        local text = string.format("%s: %s", row.label, row.text)
        if row.state == "locked" then
            if saidLocked then
                goto continue
            end
            saidLocked = true
            text = "You are missing a requirement for this option"
        end
        rows[#rows + 1] = gui.Label{
            classes = Classes("eotwRider", row.state),
            text = text,
            interactable = false,
        }
        ::continue::
    end
    return rows
end

--The last card on a turn: the hero stands there and does nothing. It reads
--like an option and costs like one -- the turn ends, spent.
local function PassCard()
    return gui.Panel{
        classes = {"eotwOptionCard", "actionable"},
        width = "100%",
        height = "auto",
        flow = "vertical",
        pad = 10,
        borderBox = true,
        vmargin = 5,
        bgimage = "panels/square.png",
        children = {
            gui.Label{ classes = {"eotwOptionName"}, text = "Pass", interactable = false },
            gui.Label{
                classes = {"eotwEntryDesc"},
                text = "Not very heroic, but you choose to do nothing",
                interactable = false,
            },
        },
        press = function(element)
            audio.FireSoundEvent("Mouse.Click")
            EncounterMontage.SendRequest("pass", {})
        end,
    }
end

local function OptionCard(entry, option, index, m)
    local mine = IsMyTurn(m) and m.turn.status == "choosing"
    local chosen = m.turn ~= nil and m.turn.optionIndex == index
    local landed = nil
    if chosen and m.turn.status == "resolved" then
        landed = m.turn.tier
    elseif chosen and (m.turn.status == "assist" or m.turn.status == "assisting") then
        --while the assist window is open the test's own tier is what is on
        --the table; an assist may still move it before anything is applied.
        landed = m.turn.baseTier
    end
    local children = {
        gui.Label{ classes = {"eotwOptionName"}, text = option.name, interactable = false },
    }
    if option.text ~= "" then
        children[#children + 1] = gui.Label{ classes = {"eotwEntryDesc"}, text = option.text, interactable = false }
    end
    --the option's riders, weighed against the hero standing at the entry:
    --an unmet Allow locks the card; a met one marks it special and says why.
    local verdict = nil
    if m.turn ~= nil and m.turn.heroid ~= nil then
        verdict = EncounterMontage.RiderVerdict(m.turn.heroid, option)
    end
    local locked = verdict ~= nil and not verdict.allowed
    local unlocked = verdict ~= nil and verdict.gated and verdict.allowed
    if option.roll ~= nil then
        children[#children + 1] = gui.Label{ classes = {"eotwOptionRoll"}, text = string.format("%s: %s", option.roll.name, EncounterScript.AttrWithoutSkills(option.roll.attr)), interactable = false }
        for _, row in ipairs(RiderRows(option.roll, verdict)) do
            children[#children + 1] = row
        end
        local rows
        if chosen and m.turn.status == "rolling" then
            rows = LiveTierRows(option.roll)
        else
            rows = TierRows(option.roll, landed, true)
        end
        for _, row in ipairs(rows) do
            children[#children + 1] = row
        end
    end
    return gui.Panel{
        classes = Classes("eotwOptionCard", mine and not locked and "actionable", chosen and "chosen", locked and "locked", unlocked and "unlocked"),
        width = "100%",
        height = "auto",
        flow = "vertical",
        pad = 10,
        borderBox = true,
        vmargin = 5,
        bgimage = "panels/square.png",
        children = children,
        press = function(element)
            if not mine or option.roll == nil or locked then
                return
            end
            audio.FireSoundEvent("Mouse.Click")
            EncounterMontage.SendRequest("choose", { optionIndex = index })
        end,
    }
end

--How an assist changed the test, in one line.
local function DescribeAssist(a, baseTier, finalTier)
    local what = "lent a hand"
    if a.outcome == "bane" then
        what = "fumbled it: a bane"
    elseif a.outcome == "edge" then
        what = "helped: an edge"
    elseif a.outcome == "doubleedge" then
        what = "helped brilliantly: a double edge"
    end
    local line = string.format("%s %s", a.heroName or "A hero", what)
    if baseTier ~= nil and finalTier ~= nil then
        if finalTier ~= baseTier then
            line = string.format("%s -- tier %d becomes tier %d", line, baseTier, finalTier)
        else
            line = string.format("%s -- still tier %d", line, finalTier)
        end
    end
    return line
end

--Where a second hero is dropped to assist the test in flight. Only heroes
--with an applicable skill the acting hero is not already using may land
--here; the host re-checks every drop.
local function AssistSlot(candidates)
    local names = {}
    for _, candidate in ipairs(candidates) do
        names[#names + 1] = string.format("%s (%s)", candidate.name or "", candidate.skillName or "")
    end
    return gui.Panel{
        classes = {"eotwAssistSlot"},
        width = "100%",
        height = "auto",
        flow = "vertical",
        pad = 10,
        borderBox = true,
        vmargin = 8,
        bgimage = "panels/square.png",
        dragTarget = true,
        dragTargetPriority = 20,
        data = { assistSlot = true },

        gui.Label{ classes = {"eotwAssistTitle"}, text = "Assist this test", interactable = false },
        gui.Label{
            classes = {"eotwTurnHint"},
            text = cond(#names > 0,
                string.format("Drag a hero here to help: %s", table.concat(names, ", ")),
                "Nobody here has an applicable skill."),
            interactable = false,
        },
        gui.Label{
            classes = {"eotwEntryDesc"},
            width = "100%",
            textAlignment = "center",
            text = "Assisting costs that hero their turn this round. They roll: 11 or lower gives the test a bane, 12-16 an edge, 17+ a double edge.",
            interactable = false,
        },

        --the click alternative to dragging, mirroring the entry cards.
        press = function(element)
            local heroid = m_selectedHero
            if heroid == nil or m_selectMode ~= "assist" or not EncounterMontage.LocalUserCanAssist(heroid) then
                return
            end
            audio.FireSoundEvent("Mouse.Click")
            SelectHero(nil)
            EncounterMontage.SendRequest("assist", { heroid = heroid })
        end,
        dragTargets = function(element, on, mode)
            element:SetClass("droppable", on == true and mode == "assist")
        end,
        selectHero = function(element, heroid, mode)
            element:SetClass("droppable", heroid ~= nil and mode == "assist")
        end,
    }
end

local function BuildTurnChildren(m, beat)
    local children = {}
    local function Add(child)
        children[#children + 1] = child
    end

    if m.phase == "arriving" then
        Add(gui.Label{ classes = {"eotwTurnTitle"}, text = "Gathering the party" })
        Add(gui.Label{ classes = {"eotwTurnHint"}, text = "The montage begins once every hero has arrived." })
        return children
    end

    if m.phase == "done" then
        if m.lastApplied ~= nil and #(m.lastApplied.applied or {}) > 0 then
            Add(gui.Label{ classes = {"eotwTurnHint"}, text = string.format("%s:", m.lastApplied.entryName or "") })
            for _, line in ipairs(m.lastApplied.applied) do
                Add(gui.Label{ classes = {"eotwAppliedLine"}, text = line })
            end
            Add(gui.Panel{ width = "60%", height = 1, bgimage = "panels/square.png", bgcolor = "#ffffff30", halign = "center", vmargin = 10 })
        end
        Add(gui.Label{ classes = {"eotwTurnTitle"}, text = "The montage is over" })
        Add(gui.Label{ classes = {"eotwTurnHint"}, text = "Draw Steel!" })
        return children
    end

    if m.phase == "consequences" then
        local idx = m.consequenceIndex or 1
        local entryId = (m.consequences or {})[idx]
        local entry = entryId ~= nil and EncounterScript.FindEntry(beat, entryId) or nil
        if m.lastApplied ~= nil and #(m.lastApplied.applied or {}) > 0 then
            Add(gui.Label{ classes = {"eotwTurnHint"}, text = string.format("%s:", m.lastApplied.entryName or "") })
            for _, line in ipairs(m.lastApplied.applied) do
                Add(gui.Label{ classes = {"eotwAppliedLine"}, text = line })
            end
            Add(gui.Panel{ width = "60%", height = 1, bgimage = "panels/square.png", bgcolor = "#ffffff30", halign = "center", vmargin = 10 })
        end
        if entry == nil then
            Add(gui.Label{ classes = {"eotwTurnTitle"}, text = "The montage is over" })
            return children
        end
        Add(gui.Label{ classes = {"eotwTurnHint"}, text = "An unresolved threat" })
        Add(gui.Panel{
            width = "auto",
            height = "auto",
            flow = "horizontal",
            halign = "center",
            MaliceIcon(44),
            gui.Label{ classes = {"eotwTurnTitle"}, width = "auto", text = entry.name, lmargin = 12, valign = "center" },
        })
        if entry.description ~= "" then
            Add(gui.Label{ classes = {"eotwTurnText"}, text = entry.description })
        end
        if entry.consequence ~= nil then
            Add(gui.Label{ classes = {"eotwTurnText"}, text = "Consequence: " .. entry.consequence.text, bold = true })
        else
            Add(gui.Label{ classes = {"eotwTurnHint"}, text = "No consequence is written for this threat." })
        end
        Add(gui.Button{
            text = "Continue",
            halign = "center",
            tmargin = 14,
            width = 180,
            height = 44,
            fontSize = 20,
            click = function(element)
                EncounterMontage.SendRequest("continue", {})
                element:SetClass("hidden", true)
            end,
        })
        return children
    end

    --whose move it is now: shown whenever the floor is free, which includes
    --over a resolved turn -- its result never holds the next hero up.
    local function AddYourMove()
        local mine = {}
        for _, hero in ipairs(EncounterMontage.Heroes()) do
            if EncounterMontage.LocalUserCanAct(hero.charid) then
                mine[#mine + 1] = hero.name
            end
        end
        if #mine > 0 then
            Add(gui.Label{ classes = {"eotwTurnHint"}, text = string.format("Your move: drag %s onto an Opportunity or a Threat, or click the hero and then click where they go.", table.concat(mine, " or ")) })
        else
            Add(gui.Label{ classes = {"eotwTurnHint"}, text = "Waiting for the other heroes to act." })
        end
    end

    local t = m.turn
    if t == nil then
        Add(gui.Label{ classes = {"eotwTurnTitle"}, text = string.format("Round %d", m.round or 1) })
        AddYourMove()
        local last = (m.log or {})[#(m.log or {})]
        if last ~= nil and not last.consequence then
            Add(gui.Panel{ width = "60%", height = 1, bgimage = "panels/square.png", bgcolor = "#ffffff30", halign = "center", vmargin = 10 })
            if last.passed then
                Add(gui.Label{ classes = {"eotwTurnText"}, text = string.format("%s approached %s and did nothing.", last.heroName or "A hero", last.entryName or "") })
            else
                Add(gui.Label{ classes = {"eotwTurnText"}, text = string.format("%s: %s (%s, tier %d)", last.heroName or "", last.entryName or "", last.optionName or "", last.tier or 0) })
            end
            for _, line in ipairs(last.applied or {}) do
                Add(gui.Label{ classes = {"eotwAppliedLine"}, text = line })
            end
        end
        return children
    end

    local entry = EncounterScript.FindEntry(beat, t.entryId)
    if entry == nil then
        Add(gui.Label{ classes = {"eotwTurnHint"}, text = "..." })
        return children
    end

    Add(gui.Panel{
        width = "auto",
        height = "auto",
        flow = "horizontal",
        halign = "center",
        Portrait(t.heroid, 56),
        gui.Label{ classes = {"eotwTurnTitle"}, width = "auto", text = string.format("%s approaches %s", t.heroName or "A hero", entry.name), lmargin = 12, valign = "center" },
    })
    if entry.approach ~= "" then
        Add(gui.Label{ classes = {"eotwTurnText"}, text = entry.approach })
    end

    if t.status == "choosing" then
        if IsMyTurn(m) then
            Add(gui.Label{ classes = {"eotwTurnHint"}, text = "Choose how to approach it:" })
        else
            Add(gui.Label{ classes = {"eotwTurnHint"}, text = string.format("%s is choosing...", t.heroName or "The hero") })
        end
        for i, option in ipairs(entry.options) do
            Add(OptionCard(entry, option, i, m))
        end
        if IsMyTurn(m) then
            --no free withdrawal: having approached, the only way out is to
            --do nothing, which costs the hero their turn (user direction
            --2026-09-19).
            Add(PassCard())
        end
    elseif t.status == "rolling" then
        local option = entry.options[t.optionIndex or 0]
        if option ~= nil then
            Add(OptionCard(entry, option, t.optionIndex, m))
        end
        if IsMyTurn(m) then
            Add(gui.Label{ classes = {"eotwTurnHint"}, text = "Make your roll." })
        else
            Add(gui.Label{ classes = {"eotwTurnHint"}, text = string.format("%s is rolling...", t.heroName or "The hero") })
        end
    elseif t.status == "assist" or t.status == "assisting" then
        --the test has landed below tier 3: before its effects are applied,
        --a hero with an applicable skill may still step in.
        local option = entry.options[t.optionIndex or 0]
        if option ~= nil then
            Add(OptionCard(entry, option, t.optionIndex, m))
        end
        local rolled = string.format("%s rolled tier %d", t.heroName or "The hero", t.baseTier or t.tier or 0)
        if t.baseTotal ~= nil then
            rolled = string.format("%s (%s)", rolled, tostring(t.baseTotal))
        end
        Add(gui.Label{ classes = {"eotwTurnTitle"}, text = rolled, tmargin = 6 })

        if t.status == "assisting" then
            local a = t.assist or {}
            Add(gui.Label{
                classes = {"eotwTurnHint"},
                text = string.format("%s is assisting with %s...", a.heroName or "A hero", a.skillName or "their skill"),
            })
            local assistRoll = { tiers = EncounterMontage.ASSIST_TIERS }
            for _, row in ipairs(LiveTierRows(assistRoll)) do
                Add(row)
            end
        else
            --with nobody able to help there is nothing to offer: the host is
            --already closing the window, so show the wait rather than an
            --empty slot (user direction 2026-09-19).
            local candidates = AssistCandidatesList(m)
            if #candidates == 0 then
                Add(gui.Label{ classes = {"eotwTurnHint"}, text = "Taking the result..." })
                return children
            end
            Add(AssistSlot(candidates))
            if IsMyTurn(m) then
                Add(gui.Button{
                    text = "Take the result",
                    halign = "center",
                    tmargin = 4,
                    width = 200,
                    height = 40,
                    click = function(element)
                        EncounterMontage.SendRequest("noassist", {})
                        element:SetClass("hidden", true)
                    end,
                })
            else
                Add(gui.Label{
                    classes = {"eotwTurnHint"},
                    text = string.format("%s is deciding whether to take it.", t.heroName or "The hero"),
                })
            end
        end
    elseif t.status == "resolved" then
        local option = entry.options[t.optionIndex or 0]
        if option ~= nil then
            Add(OptionCard(entry, option, t.optionIndex, m))
        end
        local tierLabel = string.format("Tier %d", t.tier or 0)
        if t.tier == 4 then
            tierLabel = "Critical"
        end
        if t.total ~= nil then
            tierLabel = string.format("%s (rolled %s)", tierLabel, tostring(t.total))
        end
        Add(gui.Label{ classes = {"eotwTurnTitle"}, text = tierLabel, tmargin = 6 })
        if t.assist ~= nil and t.assist.status == "resolved" then
            Add(gui.Label{ classes = {"eotwTurnHint"}, text = DescribeAssist(t.assist, t.baseTier, t.tier) })
        end
        for _, line in ipairs(t.applied or {}) do
            Add(gui.Label{ classes = {"eotwAppliedLine"}, text = line })
        end
        Add(gui.Panel{ width = "60%", height = 1, bgimage = "panels/square.png", bgcolor = "#ffffff30", halign = "center", vmargin = 10 })
        AddYourMove()
    end
    return children
end

local function TurnSignature(m)
    local t = m.turn or {}
    local a = t.assist or {}
    return table.concat({
        tostring(m.phase), tostring(m.round), tostring(t.seq), tostring(t.status), tostring(t.optionIndex),
        tostring(t.rollSeq), tostring(t.tier), tostring(m.consequenceIndex), tostring(#(m.log or {})),
        tostring(dmhub.loginUserid == t.userid),
        tostring(a.rollSeq), tostring(a.status), tostring(a.tier),
    }, "|")
end

--- the hero row ---------------------------------------------------------------------

local function HeroSignature(heroes)
    local parts = {}
    for _, hero in ipairs(heroes) do
        local allies = EncounterMontage.GetAllies(hero.charid)
        parts[#parts + 1] = hero.charid .. ":" .. table.concat(allies, ",")
    end
    return table.concat(parts, "|")
end

--- the montage haul ------------------------------------------------------------------

local function ItemGear(itemid)
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    return gearTable[itemid]
end

--The sound a landing item makes: the same pair the in-combat giveItem float
--plays over the token (TokenUI's "giveItem" animation), so picking something
--up in a montage sounds like picking something up in a fight.
--
--"Each party member gains X" lands the same item in four strips at the same
--instant, and four copies of one sample is a mush rather than four pickups,
--so an identical event inside SOUND_COALESCE seconds is dropped. Landings
--that are genuinely apart (the per-strip stagger, or a later beat) are
--further apart than that and all still play.
local SOUND_COALESCE = 0.1
local g_lastPickupSound = {}

local function PlayItemPickupSound(itemid)
    local item = ItemGear(itemid)
    local special = false
    if item ~= nil then
        pcall(function() special = EquipmentCategory.IsTreasure(item) end)
    end
    local eventName = cond(special, "UI.Inv_Item_Pickup_Special", "UI.Inv_Item_Pickup_Gnrc")
    local now = dmhub.Time()
    if g_lastPickupSound[eventName] ~= nil and now - g_lastPickupSound[eventName] < SOUND_COALESCE then
        return
    end
    g_lastPickupSound[eventName] = now
    audio.FireSoundEvent(eventName)
end

--Does the local user drive this hero in their own right? (The Director
--counts.) Gates the item drag: only the hero's own player may hand their
--haul to someone else.
local function LocalUserControlsHero(charid)
    local tok = dmhub.GetCharacterById(charid)
    if tok == nil or not tok.valid then
        return false
    end
    local mine = false
    pcall(function() mine = tok.canControlAsUser end)
    if mine == nil then
        pcall(function() mine = tok.canControl end)
    end
    return mine == true
end

--One item icon in `charid`'s haul. `animate` plays the drop-in: the icon
--starts a slot-height above where it belongs, transparent, and falls into
--place while the pickup sound plays. `delay` staggers it behind other items
--landing in the same refresh. Returns { panel, Update(entry) }.
--
--Hovering shows the item's full tooltip. The hero's own player may drag the
--icon onto another hero's card to hand over ONE of the item (a stack takes
--one drag per unit); the host moves it between inventories ("giveItem").
local function CreateItemIcon(entry, animate, delay, charid)
    local qtyLabel = gui.Label{
        classes = {"eotwItemQty"},
        text = "",
        interactable = false,
    }

    local classes = {"eotwItemIcon"}
    if animate then
        classes[#classes + 1] = "dropIn"
    end

    local m_qty = nil
    --Set while a giveItem is in flight and this icon is showing the handed-
    --off outcome ahead of the host's reply. Cleared by the Update the
    --resulting refresh brings, or by the safety restore below.
    local m_handoff = false
    local HandOff

    local icon = gui.Panel{
        classes = classes,
        bgimage = "panels/square.png",
        data = { itemid = entry.itemid, charid = charid },
        draggable = charid ~= nil and LocalUserControlsHero(charid),
        beginDrag = function(element)
            element:SetClass("dragging", true)
            element.tooltip = nil
            SelectHero(nil)
            Broadcast("dragTargets", true, "item", charid)
        end,
        canDragOnto = function(element, target)
            if not target:HasClass("eotwHeroCard") or target:HasClass("eotwAllyCard") then
                return false
            end
            local targetId = target.data ~= nil and target.data.charid or nil
            return targetId ~= nil and targetId ~= charid and LocalUserControlsHero(charid)
        end,
        drag = function(element, target)
            element:SetClass("dragging", false)
            Broadcast("dragTargets", false)
            if target == nil or target.data == nil or target.data.charid == nil or not LocalUserControlsHero(charid) then
                return
            end
            audio.FireSoundEvent("Mouse.Click")
            --The item is gone from this hero the moment it is dropped, as
            --far as this strip is concerned. Without that, clearing
            --"dragging" snaps the icon back into its old slot at full
            --opacity and it sits there until the host's giveItem reply
            --comes back -- the flash. Show the outcome now and let the
            --refresh reconcile it.
            HandOff()
            EncounterMontage.SendRequest("giveItem", { heroid = charid, targetId = target.data.charid, itemid = entry.itemid })
        end,
        hover = function(element)
            local item = ItemGear(entry.itemid)
            local tooltipFn = rawget(_G, "CreateItemTooltip")
            if item ~= nil and tooltipFn ~= nil then
                local ok = pcall(function()
                    element.tooltip = tooltipFn(item, { valign = "center", width = 360 }, nil)
                end)
                if ok then
                    return
                end
            end
            gui.Tooltip(entry.name or "Item")(element)
        end,
        qtyLabel,
    }

    --`animateChange` is for a refresh that lands while the stage is up: a
    --repeat grant bumps this icon's quantity rather than adding an icon, so
    --that gain announces itself with the same sound and a pulse.
    local function Update(newEntry, animateChange)
        local item = ItemGear(newEntry.itemid)
        local iconid = nil
        if item ~= nil then
            pcall(function() iconid = item:GetIcon() end)
        end
        if iconid ~= nil and iconid ~= "" then
            icon.bgimage = iconid
            icon.selfStyle.bgcolor = "white"
        else
            icon.bgimage = "panels/square.png"
            icon.selfStyle.bgcolor = "#232a33"
        end
        local qty = newEntry.qty or 1
        if m_handoff then
            if qty > (m_qty or 0) then
                --a refresh driven by something else, carrying a document
                --that predates our giveItem: keep showing the handoff
                --rather than snapping the item back for an instant.
                return
            end
            --the document has caught up with the handoff.
            m_handoff = false
            icon:SetClass("collapsed", false)
        end
        qtyLabel.text = cond(qty > 1, string.format("x%d", qty), "")
        qtyLabel:SetClass("collapsed", qty <= 1)
        if animateChange and m_qty ~= nil and qty > m_qty then
            icon:PulseClass("bump")
            PlayItemPickupSound(newEntry.itemid)
        end
        m_qty = qty
    end

    --One of this item has just been handed to another hero. A stack simply
    --loses one from its count; the last one leaves the strip, which is what
    --the refresh will do to it anyway, so collapsing it now means the
    --strip reflows once rather than snapping back and then reflowing.
    HandOff = function()
        local prevQty = m_qty or 1
        local qty = prevQty - 1
        m_handoff = true
        m_qty = qty
        if qty <= 0 then
            icon:SetClass("collapsed", true)
        else
            qtyLabel.text = cond(qty > 1, string.format("x%d", qty), "")
            qtyLabel:SetClass("collapsed", qty <= 1)
        end
        --if the reply never lands (rejected, or the host went away) put the
        --icon back rather than leaving the haul short an item forever.
        dmhub.Schedule(2, function()
            if mod.unloaded or icon == nil or not icon.valid or not m_handoff then
                return
            end
            m_handoff = false
            m_qty = prevQty
            icon:SetClass("collapsed", false)
            qtyLabel.text = cond(prevQty > 1, string.format("x%d", prevQty), "")
            qtyLabel:SetClass("collapsed", prevQty <= 1)
        end)
    end

    Update(entry)

    if animate then
        --a frame for the strip to lay the icon out in its raised start
        --state before the class comes off and the transition runs.
        dmhub.Schedule(0.05 + (delay or 0), function()
            if mod.unloaded or icon == nil or not icon.valid then
                return
            end
            icon:SetClass("dropIn", false)
            PlayItemPickupSound(entry.itemid)
        end)
    end

    return { panel = icon, Update = Update }
end

--The gutter of item icons beside one hero's card. Items already in the
--document when the strip is built appear instantly (a rebuilt hero row must
--not replay the whole montage); anything that lands afterwards drops in.
local function CreateItemStrip(charid)
    local m_icons = {}
    local m_count = 0
    --the first refreshMontage is the one that comes straight after this
    --strip is created, so it populates silently.
    local m_primed = false

    return gui.Panel{
        width = ITEM_STRIP_WIDTH,
        height = "auto",
        flow = "vertical",
        halign = "left",
        valign = "top",
        refreshMontage = function(element)
            local entries = EncounterMontage.GetItems(charid)
            local children = {}
            local added = false
            --items landing together drop one after another, not all at once.
            local newCount = 0
            --an item that left this haul (given to another hero) had its
            --icon destroyed when it dropped out of `children`; forget it so
            --the item coming back gets a fresh icon rather than an Update
            --on a dead panel.
            local present = {}
            for _, entry in ipairs(entries) do
                present[entry.itemid] = true
            end
            for itemid, icon in pairs(m_icons) do
                if not present[itemid] or not icon.panel.valid then
                    m_icons[itemid] = nil
                end
            end
            for _, entry in ipairs(entries) do
                local icon = m_icons[entry.itemid]
                if icon == nil then
                    icon = CreateItemIcon(entry, m_primed, newCount * ITEM_DROP_STAGGER, charid)
                    m_icons[entry.itemid] = icon
                    newCount = newCount + 1
                    added = true
                else
                    icon.Update(entry, m_primed)
                end
                children[#children + 1] = icon.panel
            end
            if added or #children ~= m_count then
                m_count = #children
                element.children = children
            end
            m_primed = true
        end,
    }
end

--- the hero column -------------------------------------------------------------------

--A hero may be picked up to take a beat, or -- while a test waits on an
--assist -- to lend a hand to it. Returns the mode, or nil when this card
--must not move at all.
local function DragMode(charid)
    if EncounterMontage.LocalUserCanAct(charid) then
        return "approach"
    end
    if EncounterMontage.LocalUserCanAssist(charid) then
        return "assist"
    end
    return nil
end

local function CreateHeroColumn(hero)
    local hud = Hud()
    local charid = hero.charid
    local card = nil
    --the "!" over a hero who could assist the test in flight. Top-CENTER of
    --the card: the trigger corner owns the top left and the condition chips
    --the top right.
    local assistBadge = gui.Panel{
        classes = {"eotwAssistBadge", "collapsed"},
        floating = true,
        halign = "center",
        valign = "top",
        y = 3,
        width = 22,
        height = 22,
        bgimage = "panels/square.png",
        interactable = false,
        thinkTime = 0.05,
        think = function(element)
            local r = (math.sin(dmhub.Time() * 2 * math.pi / 1.2) + 1) / 2
            element.selfStyle.scale = 0.9 + 0.2 * r
        end,
        gui.Label{ classes = {"eotwAssistBadgeText"}, text = "!", interactable = false },
    }
    if hud ~= nil and hud.CreateHeroCard ~= nil then
        card = hud.CreateHeroCard({ charid = charid, mine = false, name = hero.name }, {
            halign = "center",
            --only a hero the local user controls, and only while that hero
            --can still take a beat (or assist the one in flight): a card
            --nobody here can act with must not even pick up (the drop gates
            --below reject it anyway, but a player dragging someone else's
            --hero around reads as allowed).
            draggable = DragMode(charid) ~= nil,
            --another hero's item icon may be dropped here to hand it over
            --(CreateItemIcon). Only an "item" drag lights the card up, and
            --never the card of the hero the item is coming from.
            dragTarget = true,
            dragTargetPriority = 10,
            dragTargets = function(element, on, mode, sourceCharid)
                element:SetClass("droppable", on == true and mode == "item" and sourceCharid ~= charid)
            end,
            --the montage is where the party weighs who should take a beat,
            --so these cards carry the characteristics and skills the roster's
            --do not.
            showStats = true,
            click = function(element, openCharacterPanel)
                local mode = DragMode(charid)
                if mode ~= nil then
                    audio.FireSoundEvent("Mouse.Click")
                    if m_selectedHero == charid then
                        SelectHero(nil)
                    else
                        SelectHero(charid, mode)
                    end
                    return
                end
                openCharacterPanel(element)
            end,
            beginDrag = function(element)
                element:SetClass("dragging", true)
                local mode = DragMode(charid) or "approach"
                SelectHero(nil)
                Broadcast("dragTargets", true, mode)
            end,
            canDragOnto = function(element, target)
                if target:HasClass("eotwAssistSlot") then
                    return EncounterMontage.LocalUserCanAssist(charid)
                end
                if not target:HasClass("eotwEntryCard") then
                    return false
                end
                if not target.data.available then
                    return false
                end
                return EncounterMontage.LocalUserCanAct(charid)
            end,
            drag = function(element, target)
                element:SetClass("dragging", false)
                Broadcast("dragTargets", false)
                if target == nil then
                    return
                end
                if target:HasClass("eotwAssistSlot") and EncounterMontage.LocalUserCanAssist(charid) then
                    audio.FireSoundEvent("Mouse.Click")
                    EncounterMontage.SendRequest("assist", { heroid = charid })
                elseif target:HasClass("eotwEntryCard") and EncounterMontage.LocalUserCanAct(charid) then
                    audio.FireSoundEvent("Mouse.Click")
                    EncounterMontage.SendRequest("approach", { heroid = charid, entryId = target.data.entryId })
                end
            end,
        })
        card:AddChild(assistBadge)
    else
        card = gui.Label{ width = 132, height = 176, text = hero.name, bgimage = "panels/square.png", bgcolor = "#333333" }
    end

    --the haul gutter and the card, side by side; the ally row below stays
    --centered under the pair.
    local cardRow = gui.Panel{
        width = "auto",
        height = "auto",
        flow = "horizontal",
        halign = "center",
        valign = "top",
        CreateItemStrip(charid),
        card,
    }

    local allyRow = gui.Panel{
        width = 132,
        height = "auto",
        flow = "horizontal",
        halign = "center",
        wrap = true,
        tmargin = 4,
        create = function(element)
            local minis = {}
            for _, allyId in ipairs(EncounterMontage.GetAllies(charid)) do
                if hud ~= nil and hud.CreateAllyCard ~= nil then
                    minis[#minis + 1] = hud.CreateAllyCard(allyId)
                end
            end
            element.children = minis
        end,
    }

    return gui.Panel{
        width = "auto",
        height = "auto",
        flow = "vertical",
        halign = "center",
        valign = "top",
        hmargin = 6,
        data = { charid = charid },
        cardRow,
        allyRow,
        refreshMontage = function(element, m)
            local acted = (m.acted or {})[charid] == true or m.phase ~= "rounds"
            card:SetClass("acted", acted)
            local mode = DragMode(charid)
            card.draggable = mode ~= nil
            --every hero who COULD assist wears the "!", not just the local
            --user's: the party is deciding together who steps in.
            assistBadge:SetClass("collapsed", AssistCandidates(m)[charid] == nil)
            if m_selectedHero == charid and mode == nil then
                SelectHero(nil)
            end
            card:SetClass("selected", m_selectedHero == charid)
        end,
        selectHero = function(element, heroid)
            card:SetClass("selected", heroid == charid)
        end,
    }
end

--- the stage ---------------------------------------------------------------------------

--The scene art behind a stage, aspect-fit exactly like FullscreenDisplay
--does it. Shared by the montage and the narrative stage.
local function CreateBackdrop()
    return gui.Panel{
        floating = true,
        classes = {"hidden"},
        width = "100%",
        height = "100%",
        halign = "center",
        valign = "center",
        bgimage = "panels/square.png",
        bgcolor = "white",
        interactable = false,
        --aspect-fit the scene art exactly like FullscreenDisplay does.
        imageLoaded = function(element)
            if element.bgsprite == nil then
                return
            end
            local w = element.parent.renderedWidth
            local h = element.parent.renderedHeight
            if w == 0 or h == 0 then
                return
            end
            local aspect = h / w
            local imageAspect = element.bgsprite.dimensions.y / element.bgsprite.dimensions.x
            if aspect > imageAspect then
                element.selfStyle.height = "100%"
                element.selfStyle.width = string.format("%f%% height", 100 / imageAspect)
            else
                element.selfStyle.width = "100%"
                element.selfStyle.height = string.format("%f%% width", 100 * imageAspect)
            end
        end,
        screenResized = function(element)
            element:ScheduleEvent("imageLoaded", 0.5)
        end,
    }
end

local function CreateDim()
    return gui.Panel{
        floating = true,
        width = "100%",
        height = "100%",
        bgimage = "panels/square.png",
        bgcolor = "#000000a8",
        interactable = false,
    }
end

--The encounter pools (malice + hero tokens): exactly the right rail's strip,
--floated where the rail keeps it, because the stage covers the rail.
local function CreatePoolsPanel()
    local hud = Hud()
    if hud == nil or hud.CreateEncounterPoolsPanel == nil then
        return nil
    end
    return gui.Panel{
        floating = true,
        width = "auto",
        height = "auto",
        halign = "right",
        valign = "top",
        tmargin = POOLS_TOP,
        rmargin = POOLS_RIGHT,
        hud.CreateEncounterPoolsPanel(),
    }
end

--`args.embedded` means this stage is a BODY inside the mounted script stage
--(CreateScriptStage below), which owns the chrome both beat kinds share --
--the opaque background, the scene art, the dim, the pools strip, the hidden
--action bar, the held loading screen -- so that none of it blinks when the
--script moves from one beat to the next.
local function CreateStage(args)
    local embedded = args ~= nil and args.embedded == true
    local m_builtBeat = nil
    --the header height the body is currently sized against (SyncHeaderHeight).
    local m_headerHeight = nil
    local m_turnSignature = nil
    local m_heroSignature = nil
    local m_scene = nil

    --cond() evaluates both branches, so build these only when we own them.
    local backdrop, dim = nil, nil
    if not embedded then
        backdrop = CreateBackdrop()
        dim = CreateDim()
    end

    local titleLabel = gui.Label{ classes = {"eotwStageTitle"}, text = "Montage", halign = "center" }
    local introLabel = gui.Label{ classes = {"eotwStageSubtitle", "eotwMontageIntro"}, text = "", halign = "center" }
    local roundLabel = gui.Label{ classes = {"eotwStageRound"}, text = "", halign = "center" }
    --Auto height, not the fixed HEADER_HEIGHT: the intro prose wraps to as
    --many lines as it needs, and the body below is re-sized from what the
    --header actually rendered (SyncHeaderHeight).
    local header = gui.Panel{
        width = "100%",
        height = "auto",
        minHeight = HEADER_HEIGHT,
        flow = "vertical",
        halign = "center",
        valign = "top",
        titleLabel,
        introLabel,
        roundLabel,
    }

    local opportunities = gui.Panel{ width = "100%", height = "auto", flow = "vertical", halign = "center", valign = "top" }
    local threats = gui.Panel{ width = "100%", height = "auto", flow = "vertical", halign = "center", valign = "top" }

    local function Column(title, list)
        return gui.Panel{
            width = COLUMN_WIDTH,
            height = "100%",
            flow = "vertical",
            halign = "center",
            valign = "top",
            hmargin = 10,
            gui.Label{ classes = {"eotwColumnTitle"}, text = title },
            gui.Panel{
                width = "100%",
                height = "100%-36",
                vscroll = true,
                halign = "center",
                valign = "top",
                list,
            },
        }
    end

    local turnBody = gui.Panel{
        width = "100%-40",
        height = "auto",
        flow = "vertical",
        halign = "center",
        valign = "top",
    }
    local turnPanel = gui.Panel{
        classes = {"eotwTurnPanel"},
        width = CENTER_WIDTH,
        height = "100%",
        flow = "vertical",
        halign = "center",
        valign = "top",
        bgimage = "panels/square.png",
        pad = 20,
        borderBox = true,
        vscroll = true,
        turnBody,
    }

    local body = gui.Panel{
        width = "100%-40",
        height = string.format("100%%-%d", HEADER_HEIGHT + HERO_ROW_HEIGHT),
        flow = "horizontal",
        halign = "center",
        valign = "top",
        Column("Opportunities", opportunities),
        turnPanel,
        Column("Threats", threats),
    }

    --auto width + left-aligned columns: the cards pack together and the
    --row as a whole sits centered (center-aligned children of a horizontal
    --flow would be spread across the full width instead).
    local heroRow = gui.Panel{
        width = "auto",
        height = HERO_ROW_HEIGHT,
        flow = "horizontal",
        halign = "center",
        valign = "bottom",
        tmargin = 10,
    }

    local pools = nil
    if not embedded then
        pools = CreatePoolsPanel()
    end

    --The columns only ever hold what is in play: an entry gets a card the
    --round it enters (materializing as it arrives) and loses it at the end
    --of the round it was dealt with in (fading out first). m_cards holds
    --the live cards by entry id -- a card that has begun to leave is taken
    --out of here immediately, so nothing tries to bring it back.
    local m_cards = {}
    local m_entryRound = nil
    local m_entryPhase = nil
    --true while a round's party-size draw has not been made yet: its entries
    --are withheld entirely rather than shown and then taken away.
    local m_entryDrawPending = false

    local function EntryDone(m, entry)
        if entry.kind == "opportunity" then
            return (m.taken or {})[entry.id] == true
        end
        return (m.vanquished or {})[entry.id] == true
    end

    --Cards for the entries this round introduces. `animate` gives each one
    --the materialize ramp, staggered so a round that opens with three
    --entries reads as three arrivals rather than one pop; the beat's first
    --round comes up with the stage itself and so is built settled.
    --`keepDone` is for a build from cold (a join or a resume mid-montage):
    --an entry dealt with in an earlier round has already faded away on
    --everyone else's stage, so it is not put back here either.
    local function AddEntriesForRound(beat, round, animate, m, keepDone, startDelay)
        local delay = startDelay or 0
        for _, entry in ipairs(EncounterScript.MontageEntries(beat)) do
            if entry.round == round and m_cards[entry.id] == nil
                and not EncounterMontage.EntryHidden(m, beat, entry)
                and (keepDone or not EntryDone(m, entry)) then
                local card = CreateEntryCard(entry, cond(animate, delay, nil))
                m_cards[entry.id] = card
                if entry.kind == "opportunity" then
                    opportunities:AddChild(card)
                else
                    threats:AddChild(card)
                end
                if animate then
                    delay = delay + ENTRY_APPEAR_STAGGER
                end
            end
        end
    end

    local function ClearEntries()
        for _, card in pairs(m_cards) do
            if card.valid then
                card:DestroySelf()
            end
        end
        m_cards = {}
        opportunities.children = {}
        threats.children = {}
    end

    --Everything the party dealt with, now that the round it happened in is
    --over, leaves the columns.
    local function RetireDoneEntries(m)
        local taken = m.taken or {}
        local vanquished = m.vanquished or {}
        local n = 0
        for id, card in pairs(m_cards) do
            if not card.valid then
                m_cards[id] = nil
            elseif cond(card.data.kind == "opportunity", taken[id], vanquished[id]) == true then
                m_cards[id] = nil
                card:FireEvent("leave")
                n = n + 1
            end
        end
        return n
    end

    --Bring the columns into line with the round (and the phase: the last
    --round ending into the consequences retires that round's kills too).
    local function SyncEntries(m, beat, rebuilt)
        local round = m.round or 1
        local phase = m.phase
        --the draw landing is a rebuild: the entries it let through have to
        --arrive, and the round number has not changed to bring them in.
        local drawPending = m.removed == nil and EncounterScript.HasScaling(beat)
        local drawLanded = m_entryDrawPending and not drawPending
        m_entryDrawPending = drawPending
        if rebuilt or m_entryRound == nil or round < m_entryRound or drawLanded then
            ClearEntries()
            for r = 1, round do
                --what was dealt with in the round still running stays on
                --the board with its "Taken" / "Vanquished" line; anything
                --older, or anything at all once the rounds are over, has
                --already gone.
                AddEntriesForRound(beat, r, false, m, r == round and phase == "rounds")
            end
        elseif round > m_entryRound then
            --what is leaving goes first: the new round's entries wait for
            --the old cards to finish fading and the columns to close up,
            --so the two animations read as one hand-over rather than a
            --scramble.
            local leaving = RetireDoneEntries(m)
            local startDelay = cond(leaving > 0, ENTRY_FADE_TIME + 0.1, 0)
            for r = m_entryRound + 1, round do
                AddEntriesForRound(beat, r, true, m, true, startDelay)
            end
        elseif phase ~= m_entryPhase and m_entryPhase == "rounds" then
            --the final round has ended; there is no round after it to
            --clear the board, so the phase change does it.
            RetireDoneEntries(m)
        end
        m_entryRound = round
        m_entryPhase = phase
    end

    local function RefreshHeroes(m)
        local heroes = EncounterMontage.Heroes()
        local sig = HeroSignature(heroes)
        if sig ~= m_heroSignature then
            m_heroSignature = sig
            local columns = {}
            for _, hero in ipairs(heroes) do
                columns[#columns + 1] = CreateHeroColumn(hero)
            end
            heroRow.children = columns
        end
    end

    --The header is auto-height so the intro prose can wrap; the body's
    --height is arithmetic off it, so follow what the header actually
    --rendered rather than the HEADER_HEIGHT floor.
    local function SyncHeaderHeight()
        if not header.valid then
            return
        end
        local h = math.max(HEADER_HEIGHT, math.min(HEADER_HEIGHT_MAX, math.ceil(header.renderedHeight or 0)))
        if h ~= m_headerHeight then
            m_headerHeight = h
            body.selfStyle.height = string.format("100%%-%d", h + HERO_ROW_HEIGHT)
        end
    end

    local resultPanel
    local function Refresh(element)
        SyncHeaderHeight()
        local m = EncounterMontage.GetState()
        local beat, script = EncounterMontage.CurrentBeat()
        if m == nil or beat == nil then
            return
        end
        local rebuilt = m_builtBeat ~= m.beatIndex
        if rebuilt then
            m_builtBeat = m.beatIndex
            m_entryRound = nil
            m_entryPhase = nil
            introLabel.text = beat.intro or ""
            introLabel:SetClass("collapsed", (beat.intro or "") == "")
            m_turnSignature = nil
            if not embedded then
                local scene = EncounterMontage.SceneImage(script, beat)
                if scene ~= m_scene then
                    m_scene = scene
                    if scene ~= nil then
                        backdrop.bgimage = scene
                        backdrop:SetClass("hidden", false)
                        backdrop:ScheduleEvent("imageLoaded", 0.2)
                    else
                        backdrop:SetClass("hidden", true)
                    end
                end
            end
        end

        SyncEntries(m, beat, rebuilt)

        local rounds = EncounterScript.RoundCount(beat)
        if m.phase == "arriving" then
            roundLabel.text = "Waiting for players to arrive..."
        elseif m.phase == "consequences" then
            roundLabel.text = "Consequences"
        elseif m.phase == "done" then
            roundLabel.text = "Complete"
        else
            local text = string.format("Round %d of %d", m.round or 1, rounds)
            roundLabel.text = text
        end

        RefreshHeroes(m)

        local sig = TurnSignature(m)
        if sig ~= m_turnSignature then
            m_turnSignature = sig
            turnBody.children = BuildTurnChildren(m, beat)
        end

        element:FireEventTree("refreshMontage", m)
    end

    resultPanel = gui.Panel{
        styles = ThemeEngine.MergeStyles(StageRules()),
        width = "100%",
        height = "100%",
        halign = "center",
        valign = "center",
        flow = "vertical",
        bgimage = cond(embedded, nil, "panels/square.png"),
        bgcolor = cond(embedded, "#00000000", "#05070a"),
        swallowPress = true,

        children = Classes(backdrop, dim, header, body, heroRow, pools),

        monitorGame = EncounterMontage.DocPath(),
        refreshGame = function(element)
            Refresh(element)
        end,

        create = function(element)
            Refresh(element)
            if not embedded then
                AcquireActionBarHide()
                element:ScheduleEvent("releaseLoadingScreen", 0.1)
            end
        end,

        destroy = function(element)
            if not embedded then
                ReleaseActionBarHide()
            end
        end,

        releaseLoadingScreen = function(element)
            pcall(function() dmhub.ReleaseLoadingScreen() end)
        end,

        thinkTime = 0.5,
        think = function(element)
            if mod.unloaded then
                element:DestroySelf()
                return
            end
            pcall(EncounterMontage.ClientTick)
            SyncHeaderHeight()
            element:FireEventTree("refreshCard")
        end,
    }

    ThemeEngine.OnThemeChanged(mod, function()
        if resultPanel ~= nil and resultPanel.valid then
            resultPanel.styles = ThemeEngine.MergeStyles(StageRules())
        end
    end)

    m_root = resultPanel
    m_selectedHero = nil

    return resultPanel
end

EncounterMontageStage.Create = CreateStage

--- the narrative stage -------------------------------------------------------
--
--The same frame (scene backdrop, header, hero row, pools) around a different
--middle: the section's text, its options as cards, and what the party's
--choices did. A section is either AGREED UPON -- one vote per player, a split
--settled by a random pick the stage flashes through first -- or taken by EACH
--HERO ON THEIR OWN, in which case a hero is dragged (or clicked) onto the
--option they take, exactly like approaching a montage entry.

--how many times the flash steps through the players before it lands.
local DECIDE_FLASH_STEPS = 21

--The candidate a split decision is flashing on right now, given the time
--since it started. Deterministic (it is a function of decision.startedAt and
--the server clock, both shared), decelerating, and lands on the winner.
local function FlashCandidateIndex(decision, now)
    local candidates = decision.candidates or {}
    local n = #candidates
    if n == 0 then
        return 1
    end
    local winner = 1
    for i, candidate in ipairs(candidates) do
        if candidate.key == decision.winner then
            winner = i
        end
    end
    local total = EncounterNarrative.DECIDE_FLASH_SECONDS or 3.2
    local elapsed = now - (tonumber(decision.startedAt) or now)
    if elapsed >= total then
        return winner, true
    end
    --a step count that is a multiple of the candidate count would start the
    --flash ON the winner, which gives the answer away; shift it by one.
    local steps_total = DECIDE_FLASH_STEPS
    if n > 1 and steps_total % n == 0 then
        steps_total = steps_total + 1
    end
    local p = math.max(0, elapsed / total)
    --ease out: the steps come fast and slow to a stop.
    local steps = math.floor(steps_total * (1 - (1 - p) * (1 - p)))
    --start so that the last step lands exactly on the winner.
    local start = ((winner - 1) - steps_total) % n
    return ((start + steps) % n) + 1, false
end

local function NarrativeChoiceFor(m, section, heroEntry)
    return EncounterNarrative.ChoiceForHero(m, section, heroEntry)
end

--Who chose this option, as a display line ("Kira, Brann").
local function ChoosersOfOption(m, section, index)
    local names = {}
    local heroes = EncounterMontage.Heroes()
    for _, voter in ipairs(EncounterNarrative.Voters(section, heroes)) do
        local choice = (m.choices or {})[voter.key]
        if choice ~= nil and tonumber(choice.optionIndex) == index then
            names[#names + 1] = voter.name
        end
    end
    return names
end

local function NarrativeOptionCard(section, option, index)
    local children = {
        gui.Label{ classes = {"eotwOptionName"}, text = option.name, interactable = false },
    }
    if option.text ~= "" then
        children[#children + 1] = gui.Label{ classes = {"eotwEntryDesc"}, text = option.text, interactable = false }
    end
    for _, effect in ipairs(option.effects or {}) do
        children[#children + 1] = gui.Label{
            classes = {"eotwAppliedLine"},
            text = EncounterScript.DescribeEffect(effect),
            interactable = false,
        }
    end
    local chooserLabel = gui.Label{ classes = {"eotwChoiceChip"}, text = "", interactable = false }
    children[#children + 1] = chooserLabel

    --individual sections take a hero (dragged or clicked); agreed ones take
    --the local player's vote straight off the card.
    local function CanTakeHero(heroid)
        return section.mode == "individual" and heroid ~= nil
            and EncounterNarrative.LocalUserCanChooseFor(heroid)
    end

    return gui.Panel{
        classes = {"eotwOptionCard"},
        width = 300,
        height = "auto",
        flow = "vertical",
        pad = 10,
        borderBox = true,
        margin = 6,
        valign = "top",
        bgimage = "panels/square.png",
        dragTarget = true,
        dragTargetPriority = 10,
        data = { optionIndex = index },
        children = children,

        press = function(element)
            local m = EncounterNarrative.GetState()
            if m == nil or m.phase ~= "choosing" then
                return
            end
            if section.mode == "individual" then
                local heroid = m_selectedHero
                if not CanTakeHero(heroid) or m_selectMode ~= "narrative" then
                    return
                end
                audio.FireSoundEvent("Mouse.Click")
                SelectHero(nil)
                EncounterNarrative.Choose(index, heroid)
                return
            end
            if EncounterNarrative.LocalUserPendingChoice() then
                audio.FireSoundEvent("Mouse.Click")
                EncounterNarrative.Choose(index)
            end
        end,

        dragTargets = function(element, on, mode)
            element:SetClass("droppable", on == true and (mode or "") == "narrative")
        end,
        selectHero = function(element, heroid, mode)
            element:SetClass("droppable", heroid ~= nil and (mode or "") == "narrative" and CanTakeHero(heroid))
        end,

        refreshNarrative = function(element, m)
            local chosen = false
            if m.phase == "resolved" and m.result ~= nil then
                if m.result.mode == "individual" then
                    for _, group in ipairs(m.result.groups or {}) do
                        if group.optionIndex == index then
                            chosen = true
                        end
                    end
                else
                    chosen = m.result.optionIndex == index
                end
            end
            element:SetClass("chosen", chosen)

            local actionable = false
            if m.phase == "choosing" then
                if section.mode == "individual" then
                    actionable = CanTakeHero(m_selectedHero)
                else
                    actionable = EncounterNarrative.LocalUserPendingChoice()
                end
            end
            element:SetClass("actionable", actionable)
            element:SetClass("droppable", section.mode == "individual" and CanTakeHero(m_selectedHero))

            --while the choices are still coming in, the names are hidden in
            --an agreed-upon section: a vote nobody can see is an honest one.
            local names = {}
            if m.phase ~= "choosing" or section.mode == "individual" then
                names = ChoosersOfOption(m, section, index)
            end
            chooserLabel.text = cond(#names > 0, table.concat(names, ", "), "")
            chooserLabel:SetClass("collapsed", #names == 0)
        end,

        narrativeFlash = function(element, optionIndex)
            element:SetClass("flashing", optionIndex == index)
        end,
    }
end

--One hero's card on the narrative stage: draggable onto an option while its
--owner still owes this section a choice, with the choice they made (or their
--player's, in an agreed-upon section) written under it.
local function CreateNarrativeHeroColumn(hero, section)
    local hud = Hud()
    local charid = hero.charid
    local card = nil
    local individual = section ~= nil and section.mode == "individual"

    local waitingBadge = gui.Panel{
        classes = {"eotwAssistBadge", "collapsed"},
        floating = true,
        halign = "center",
        valign = "top",
        y = 3,
        width = 22,
        height = 22,
        bgimage = "panels/square.png",
        interactable = false,
        thinkTime = 0.05,
        think = function(element)
            local r = (math.sin(dmhub.Time() * 2 * math.pi / 1.2) + 1) / 2
            element.selfStyle.scale = 0.9 + 0.2 * r
        end,
        gui.Label{ classes = {"eotwAssistBadgeText"}, text = "?", interactable = false },
    }

    if hud ~= nil and hud.CreateHeroCard ~= nil then
        card = hud.CreateHeroCard({ charid = charid, mine = false, name = hero.name }, {
            halign = "center",
            draggable = individual and EncounterNarrative.LocalUserCanChooseFor(charid),
            showStats = true,
            click = function(element, openCharacterPanel)
                if individual and EncounterNarrative.LocalUserCanChooseFor(charid) then
                    audio.FireSoundEvent("Mouse.Click")
                    if m_selectedHero == charid then
                        SelectHero(nil)
                    else
                        SelectHero(charid, "narrative")
                    end
                    return
                end
                openCharacterPanel(element)
            end,
            beginDrag = function(element)
                element:SetClass("dragging", true)
                SelectHero(nil)
                Broadcast("dragTargets", true, "narrative")
            end,
            canDragOnto = function(element, target)
                if not target:HasClass("eotwOptionCard") then
                    return false
                end
                return individual and EncounterNarrative.LocalUserCanChooseFor(charid)
            end,
            drag = function(element, target)
                element:SetClass("dragging", false)
                Broadcast("dragTargets", false)
                if target == nil or not target:HasClass("eotwOptionCard") then
                    return
                end
                if individual and EncounterNarrative.LocalUserCanChooseFor(charid) then
                    audio.FireSoundEvent("Mouse.Click")
                    EncounterNarrative.Choose(target.data.optionIndex, charid)
                end
            end,
        })
        card:AddChild(waitingBadge)
    else
        card = gui.Label{ width = 132, height = 176, text = hero.name, bgimage = "panels/square.png", bgcolor = "#333333" }
    end

    local choiceLabel = gui.Label{ classes = {"eotwHeroChoice", "waiting"}, text = "", halign = "center" }

    local cardRow = gui.Panel{
        width = "auto",
        height = "auto",
        flow = "horizontal",
        halign = "center",
        valign = "top",
        CreateItemStrip(charid),
        card,
    }

    local allyRow = gui.Panel{
        width = 132,
        height = "auto",
        flow = "horizontal",
        halign = "center",
        wrap = true,
        tmargin = 4,
        create = function(element)
            local minis = {}
            for _, allyId in ipairs(EncounterMontage.GetAllies(charid)) do
                if hud ~= nil and hud.CreateAllyCard ~= nil then
                    minis[#minis + 1] = hud.CreateAllyCard(allyId)
                end
            end
            element.children = minis
        end,
    }

    return gui.Panel{
        width = "auto",
        height = "auto",
        flow = "vertical",
        halign = "center",
        valign = "top",
        hmargin = 6,
        data = { charid = charid },
        cardRow,
        choiceLabel,
        allyRow,

        refreshNarrative = function(element, m)
            local choice = NarrativeChoiceFor(m, section, hero)
            local chosen = choice ~= nil
            card:SetClass("acted", chosen or m.phase ~= "choosing")
            local canChoose = individual and EncounterNarrative.LocalUserCanChooseFor(charid)
            card.draggable = canChoose
            --a "?" over every hero still owed a choice (their own in an
            --individual section, their player's in an agreed one), so the
            --party can see who they are waiting on.
            waitingBadge:SetClass("collapsed", chosen or m.phase ~= "choosing")
            if m_selectedHero == charid and not canChoose then
                SelectHero(nil)
            end
            card:SetClass("selected", m_selectedHero == charid)

            local text = ""
            local waiting = true
            if m.phase == "choosing" then
                if chosen then
                    waiting = false
                    if individual then
                        text = (section.options[tonumber(choice.optionIndex) or 0] or {}).name or "Chosen"
                    else
                        --an agreed-upon vote stays secret until they are all in.
                        text = "Ready"
                    end
                else
                    text = "Choosing..."
                end
            elseif chosen then
                waiting = false
                local index = tonumber(choice.optionIndex) or 0
                text = (section.options[index] or {}).name or ""
            end
            choiceLabel.text = text
            choiceLabel:SetClass("collapsed", text == "")
            choiceLabel:SetClass("waiting", waiting)
        end,

        selectHero = function(element, heroid)
            card:SetClass("selected", heroid == charid)
        end,

        narrativeFlashHeroes = function(element, heroids)
            local on = false
            for _, id in ipairs(heroids or {}) do
                if id == charid then
                    on = true
                end
            end
            card:SetClass("flashing", on)
        end,
    }
end

--The lines the stage shows once a section has resolved.
local function NarrativeResultChildren(m, section)
    local children = {}
    local result = m.result or {}
    if result.mode == "individual" then
        for _, group in ipairs(result.groups or {}) do
            children[#children + 1] = gui.Label{
                classes = {"eotwTurnTitle"},
                text = string.format("%s -- %s", group.optionName or "", table.concat(group.heroNames or {}, ", ")),
                interactable = false,
            }
            for _, line in ipairs(group.applied or {}) do
                children[#children + 1] = gui.Label{ classes = {"eotwAppliedLine"}, text = line, interactable = false }
            end
        end
        if #children == 0 then
            children[#children + 1] = gui.Label{ classes = {"eotwTurnText"}, text = "The party moves on.", interactable = false }
        end
        return children
    end

    children[#children + 1] = gui.Label{
        classes = {"eotwTurnTitle"},
        text = result.optionName or "",
        interactable = false,
    }
    if result.decidedBy ~= nil and m.decision ~= nil then
        children[#children + 1] = gui.Label{
            classes = {"eotwTurnHint"},
            text = string.format("The party could not agree -- %s decided", tostring(m.decision.winnerName or "someone")),
            interactable = false,
        }
    end
    for _, line in ipairs(result.applied or {}) do
        children[#children + 1] = gui.Label{ classes = {"eotwAppliedLine"}, text = line, interactable = false }
    end
    if #(result.applied or {}) == 0 then
        children[#children + 1] = gui.Label{ classes = {"eotwTurnText"}, text = "The party moves on.", interactable = false }
    end
    return children
end

local function CreateNarrativeStage(args)
    local embedded = args ~= nil and args.embedded == true
    local m_sectionKey = nil
    local m_heroSignature = nil
    local m_scene = nil
    local m_flashIndex = nil

    --cond() evaluates both branches, so build these only when we own them.
    local backdrop, dim = nil, nil
    if not embedded then
        backdrop = CreateBackdrop()
        dim = CreateDim()
    end

    local titleLabel = gui.Label{ classes = {"eotwStageTitle"}, text = "", halign = "center" }
    local introLabel = gui.Label{ classes = {"eotwStageSubtitle"}, text = "", halign = "center" }
    local statusLabel = gui.Label{ classes = {"eotwStageRound"}, text = "", halign = "center" }
    local header = gui.Panel{
        width = "100%",
        height = HEADER_HEIGHT,
        flow = "vertical",
        halign = "center",
        valign = "top",
        titleLabel,
        introLabel,
        statusLabel,
    }

    local textLabel = gui.Label{ classes = {"eotwNarrativeText"}, text = "", halign = "center" }
    local promptLabel = gui.Label{ classes = {"eotwNarrativePrompt"}, text = "", halign = "center" }
    local optionsRow = gui.Panel{
        width = "auto",
        maxWidth = "100%",
        height = "auto",
        flow = "horizontal",
        wrap = true,
        halign = "center",
        valign = "top",
    }
    local resultPanel = gui.Panel{
        classes = {"collapsed"},
        width = "100%",
        height = "auto",
        flow = "vertical",
        halign = "center",
        valign = "top",
        tmargin = 10,
    }

    --the split-decision flash: the banner names whoever it is on right now
    --and the hero cards of that player light up with it.
    local decideName = gui.Label{ classes = {"eotwDecideName"}, text = "", halign = "center" }
    local decideOption = gui.Label{ classes = {"eotwTurnText"}, text = "", halign = "center" }
    local decidePanel = gui.Panel{
        classes = {"collapsed"},
        width = "100%",
        height = "auto",
        flow = "vertical",
        halign = "center",
        valign = "top",
        vmargin = 8,
        gui.Label{ classes = {"eotwDecideBanner"}, text = "The party is split!", halign = "center" },
        decideName,
        decideOption,
    }

    local centerBody = gui.Panel{
        width = "100%-40",
        height = "auto",
        flow = "vertical",
        halign = "center",
        valign = "top",
        textLabel,
        promptLabel,
        decidePanel,
        optionsRow,
        resultPanel,
    }
    local center = gui.Panel{
        classes = {"eotwTurnPanel"},
        width = "68%",
        height = "auto",
        maxHeight = "100%",
        flow = "vertical",
        halign = "center",
        valign = "top",
        bgimage = "panels/square.png",
        pad = 20,
        borderBox = true,
        vscroll = true,
        centerBody,
    }
    local body = gui.Panel{
        width = "100%-40",
        height = string.format("100%%-%d", HEADER_HEIGHT + HERO_ROW_HEIGHT),
        flow = "horizontal",
        halign = "center",
        valign = "top",
        center,
    }

    local heroRow = gui.Panel{
        width = "auto",
        height = HERO_ROW_HEIGHT,
        flow = "horizontal",
        halign = "center",
        valign = "bottom",
        tmargin = 10,
    }

    local pools = nil
    if not embedded then
        pools = CreatePoolsPanel()
    end

    local function RefreshHeroes(section)
        local heroes = EncounterMontage.Heroes()
        local sig = string.format("%s|%s", HeroSignature(heroes), tostring(section ~= nil and section.mode or ""))
        if sig ~= m_heroSignature then
            m_heroSignature = sig
            local columns = {}
            for _, hero in ipairs(heroes) do
                columns[#columns + 1] = CreateNarrativeHeroColumn(hero, section)
            end
            heroRow.children = columns
        end
    end

    local stage
    local function Refresh(element)
        local m = EncounterNarrative.GetState()
        local beat, script = EncounterNarrative.CurrentBeat()
        if m == nil or beat == nil then
            return
        end
        local sections = EncounterScript.NarrativeSections(beat)
        local index = math.max(1, math.min(#sections, tonumber(m.sectionIndex) or 1))
        local section = sections[index]
        if section == nil then
            return
        end

        --a new section rebuilds the middle (and re-hangs the scene art).
        local key = string.format("%s|%s", tostring(m.beatIndex), section.id)
        if key ~= m_sectionKey then
            m_sectionKey = key
            m_flashIndex = nil
            titleLabel.text = section.name
            textLabel.text = section.text
            textLabel:SetClass("collapsed", section.text == "")
            local intro = cond(index == 1, beat.intro or "", "")
            introLabel.text = intro
            introLabel:SetClass("collapsed", intro == "")
            local cards = {}
            for i, option in ipairs(section.options) do
                cards[#cards + 1] = NarrativeOptionCard(section, option, i)
            end
            optionsRow.children = cards
            if not embedded then
                local scene = EncounterNarrative.SceneImage(script, beat, section)
                if scene ~= m_scene then
                    m_scene = scene
                    if scene ~= nil then
                        backdrop.bgimage = scene
                        backdrop:SetClass("hidden", false)
                        backdrop:ScheduleEvent("imageLoaded", 0.2)
                    else
                        backdrop:SetClass("hidden", true)
                    end
                end
            end
        end

        --the prompt line: the author's, plus how this section is decided.
        local how = cond(section.mode == "individual",
            "Each hero chooses for themselves.",
            "The party must agree.")
        if section.implicitOption then
            how = "Everyone must be ready to move on."
        end
        promptLabel.text = trim(string.format("%s %s", section.prompt or "", how))

        if m.phase == "arriving" then
            statusLabel.text = "Waiting for the party to arrive..."
        elseif m.phase == "done" then
            statusLabel.text = "Complete"
        else
            local pending = EncounterNarrative.PendingVoters(m, section, nil)
            local text = string.format("Section %d of %d", index, #sections)
            if m.phase == "choosing" and #pending > 0 then
                text = string.format("%s  --  still to choose: %s", text, table.concat(pending, ", "))
            elseif m.phase == "deciding" then
                text = string.format("%s  --  deciding...", text)
            end
            statusLabel.text = text
        end

        decidePanel:SetClass("collapsed", m.phase ~= "deciding")
        resultPanel:SetClass("collapsed", m.phase ~= "resolved" and m.phase ~= "done")
        if m.phase == "resolved" then
            resultPanel.children = NarrativeResultChildren(m, section)
        end

        RefreshHeroes(section)
        element:FireEventTree("refreshNarrative", m)
    end

    stage = gui.Panel{
        styles = ThemeEngine.MergeStyles(StageRules()),
        width = "100%",
        height = "100%",
        halign = "center",
        valign = "center",
        flow = "vertical",
        bgimage = cond(embedded, nil, "panels/square.png"),
        bgcolor = cond(embedded, "#00000000", "#05070a"),
        swallowPress = true,

        children = Classes(backdrop, dim, header, body, heroRow, pools),

        monitorGame = EncounterMontage.DocPath(),
        refreshGame = function(element)
            Refresh(element)
        end,

        create = function(element)
            Refresh(element)
            if not embedded then
                AcquireActionBarHide()
                element:ScheduleEvent("releaseLoadingScreen", 0.1)
            end
        end,

        destroy = function(element)
            if not embedded then
                ReleaseActionBarHide()
            end
        end,

        releaseLoadingScreen = function(element)
            pcall(function() dmhub.ReleaseLoadingScreen() end)
        end,

        thinkTime = 0.05,
        think = function(element)
            if mod.unloaded then
                element:DestroySelf()
                return
            end
            local m = EncounterNarrative.GetState()
            if m ~= nil and m.phase == "deciding" and m.decision ~= nil then
                local index, landed = FlashCandidateIndex(m.decision, dmhub.serverTime)
                if index ~= m_flashIndex then
                    m_flashIndex = index
                    local candidate = (m.decision.candidates or {})[index]
                    if candidate ~= nil then
                        decideName.text = tostring(candidate.name or "")
                        decideOption.text = tostring(candidate.optionName or "")
                        element:FireEventTree("narrativeFlash", candidate.optionIndex)
                        element:FireEventTree("narrativeFlashHeroes", candidate.heroids)
                        if not landed then
                            audio.FireSoundEvent("Mouse.Click")
                        end
                    end
                end
            elseif m_flashIndex ~= nil then
                m_flashIndex = nil
                element:FireEventTree("narrativeFlash", nil)
                element:FireEventTree("narrativeFlashHeroes", {})
            end
            element:FireEventTree("refreshCard")
        end,
    }

    ThemeEngine.OnThemeChanged(mod, function()
        if stage ~= nil and stage.valid then
            stage.styles = ThemeEngine.MergeStyles(StageRules())
        end
    end)

    m_root = stage
    m_selectedHero = nil

    return stage
end

EncounterMontageStage.CreateNarrative = CreateNarrativeStage

--- the mounted script stage ---------------------------------------------------
--
--What is actually presented, ONCE, for the whole run of stage beats. It owns
--everything the two beat kinds share and everything that must not blink when
--the script moves on: the opaque background, the scene art, the dim, the
--pools strip, the hidden action bar and the held loading screen. Inside it
--sits one body -- the montage's or the narrative's -- and a beat change swaps
--only that, so two beats naming the same [[scene]] cut with nothing moving
--but the cards.
--
--Why it has to be this way: GameHud destroys and re-creates a presented
--dialog whenever its args change, so carrying the beat index in the args made
--every beat change a full teardown -- a frame of bare map, which reads as a
--flicker. The args are constant now (EncounterMontage.Present) and the live
--beat is read from the document this panel already monitors.

--Drive a screen transition's CrossFade from 1 -> 0 and free it at the end.
--(The idiom is ThemeSettingsDialog's: the engine holds a snapshot of the
--screen over everything, we change what is underneath, and the snapshot
--dissolves away to reveal it.)
local function FadeOutScreenTransition(transition, duration)
    local startTime = dmhub.Time()
    local tick
    tick = function()
        if transition == nil then
            return
        end
        if mod.unloaded then
            pcall(function() transition:Destroy() end)
            return
        end
        local t = (dmhub.Time() - startTime) / duration
        if t >= 1 then
            pcall(function()
                transition:CrossFade(0)
                transition:Destroy()
            end)
            return
        end
        pcall(function() transition:CrossFade(1 - t) end)
        dmhub.Schedule(0.01, tick)
    end
    dmhub.Schedule(0.01, tick)
end

--The beat the script is on, as the host stamped it.
local function CurrentScriptBeat()
    local beat, index, script = nil, 1, nil
    pcall(function()
        script = EncounterMontage.FindMapScript()
        index = tonumber(EncounterMontage.GetDoc().data.beat) or 1
        beat = script.parse.beats[index]
    end)
    return beat, index, script
end

--The backdrop for whatever is on screen: a narrative section may override its
--beat's scene, a montage always uses the beat's.
local function CurrentSceneImage(beat, index, script)
    if beat == nil or script == nil then
        return nil
    end
    if beat.kind == "narrative" then
        local runtime = rawget(_G, "EncounterNarrative")
        if runtime == nil then
            return nil
        end
        --Only let a SECTION pick the scene while the live narrative state is
        --this beat's. Across a handover the previous beat's state is briefly
        --still on the document, and borrowing its section would swap the
        --backdrop to something that is not on screen and straight back again.
        local section = nil
        local state = runtime.GetState()
        if state ~= nil and state.beatIndex == index then
            section = runtime.CurrentSection()
        end
        return runtime.SceneImage(script, beat, section)
    end
    return EncounterMontage.SceneImage(script, beat)
end

local function CreateScriptStage(args)
    local backdrop = CreateBackdrop()
    local dim = CreateDim()
    local pools = CreatePoolsPanel()
    local m_kind = nil
    local m_scene = nil
    local m_dismissed = false

    --one child, sized to fill: the montage's body or the narrative's.
    local bodyHolder = gui.Panel{
        width = "100%",
        height = "100%",
        halign = "center",
        valign = "center",
        flow = "vertical",
    }

    --The script has handed the map back: go, but go like a cut-scene. Snapshot
    --the screen, hide ourselves underneath it (revealing the battlefield the
    --encounter beat has already set up), then dissolve the snapshot away. The
    --host takes the panel down for real once the dissolve has played
    --(EncounterMontage.DismissStage), so there is no rush here.
    local function Dismiss(element)
        if m_dismissed then
            return
        end
        m_dismissed = true
        local started = false
        pcall(function()
            local transition
            transition = dmhub.StartScreenTransition(function()
                if element ~= nil and element.valid then
                    element:SetClass("hidden", true)
                end
                FadeOutScreenTransition(transition, EncounterMontage.STAGE_DISMISS_SECONDS or 0.8)
            end)
            started = transition ~= nil
        end)
        if not started and element ~= nil and element.valid then
            --an engine without the transition bridge: just go.
            element:SetClass("hidden", true)
        end
    end

    local function Refresh(element)
        if EncounterMontage.DismissAt() ~= nil then
            Dismiss(element)
            return
        end

        local beat, index, script = CurrentScriptBeat()
        local kind = beat ~= nil and beat.kind or nil
        if kind ~= "montage" and kind ~= "narrative" then
            --a beat that does not own the stage, or a script we cannot read:
            --hold what is up rather than tearing the surface down. The host
            --hides the stage when it really means to hand the map back.
            return
        end

        if kind ~= m_kind then
            m_kind = kind
            if kind == "narrative" then
                bodyHolder.children = { CreateNarrativeStage{ embedded = true } }
            else
                bodyHolder.children = { CreateStage{ embedded = true } }
            end
        end

        local scene = CurrentSceneImage(beat, index, script)
        if scene ~= m_scene then
            m_scene = scene
            if scene ~= nil then
                backdrop.bgimage = scene
                backdrop:SetClass("hidden", false)
                backdrop:ScheduleEvent("imageLoaded", 0.2)
            else
                backdrop:SetClass("hidden", true)
            end
        end
    end

    local stage
    stage = gui.Panel{
        --The backdrop, the dim and the pools strip used to hang under a stage
        --root that carried these; keep them in the same style scope now that
        --they live out here. The body inside sets them again for its own
        --subtree, which costs nothing -- they are the same rules.
        styles = ThemeEngine.MergeStyles(StageRules()),
        width = "100%",
        height = "100%",
        halign = "center",
        valign = "center",
        flow = "vertical",
        bgimage = "panels/square.png",
        bgcolor = "#05070a",
        swallowPress = true,

        --backdrop, dim and pools all float, so bodyHolder is the only child
        --in the flow and takes the whole surface.
        children = Classes(backdrop, dim, bodyHolder, pools),

        monitorGame = EncounterMontage.DocPath(),
        refreshGame = function(element)
            Refresh(element)
        end,

        create = function(element)
            Refresh(element)
            AcquireActionBarHide()
            --Entering an EotW game holds the loading screen until the opening
            --beat is on screen (EncounterOfTheWeek.md, the loading-screen
            --hold). We are it: let the screen fade over us, a beat later so
            --the first layout is in. Harmless when nothing is held.
            element:ScheduleEvent("releaseLoadingScreen", 0.1)
        end,

        destroy = function(element)
            ReleaseActionBarHide()
        end,

        releaseLoadingScreen = function(element)
            pcall(function() dmhub.ReleaseLoadingScreen() end)
        end,

        thinkTime = 0.25,
        think = function(element)
            if mod.unloaded then
                element:DestroySelf()
                return
            end
            Refresh(element)
        end,
    }

    ThemeEngine.OnThemeChanged(mod, function()
        if stage ~= nil and stage.valid then
            stage.styles = ThemeEngine.MergeStyles(StageRules())
        end
    end)

    return stage
end

EncounterMontageStage.CreateScriptStage = CreateScriptStage

pcall(function()
    GameHud.RegisterPresentableDialog{
        id = DIALOG_ID,
        keeplocal = false,
        create = function(args)
            return CreateScriptStage(args or {})
        end,
    }
end)
