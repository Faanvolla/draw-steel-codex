local mod = dmhub.GetModLoading()

--Encounter of the Week custom interface: usurps the normal game hud via
--the GameHud.RegisterCustomInterface core hook (DMHub Core UI/Hud.lua).
--While active it removes the icon-rail button columns (the docks slide
--away with them), removes the "Panels" title-bar menu, removes Compendium
--access (menus, toolbar, search), and mounts a hero roster on the right
--edge of the screen (shrinking itself to fit when a full seven-hero
--roster is taller than the window): one card per hero showing portrait,
--name, stamina (with a recoveries circle beside it),
--heroic resource, surges, and condition icons. The local
--player's own heroes sit at the top, closer together, on a distinct
--backing. Clicking a card pops out the full character panel, which the
--characterPanelAccess override forces read-only for everyone.
--Design/plan doc: EncounterOfTheWeek/EncounterOfTheWeek.md.

--Hidden dev toggle: "/toggle eotw:forcecustomui" turns the custom
--interface on in ANY game (the authoring game included), for iterating on
--it without launching a real EotW game. The rails/title bar notice the
--flip within half a second.
setting{
    id = "eotw:forcecustomui",
    description = "Force the Encounter of the Week custom interface",
    default = false,
    storage = "preference",
}

--- Hero collection ----------------------------------------------------------

--A hero whose player never typed a name still has to label its card with
--something. (EncounterMontage.HeroDisplayName says the same thing; kept
--local here because this file only reaches that module defensively.)
local function HeroDisplayName(tok)
    local name = nil
    pcall(function() name = tok.name end)
    if name == nil or name == "" then
        return "Unnamed Hero"
    end
    return name
end

--Every hero on the map, the local player's own first. "Own" is strict
--ownership (ownerId == loginUserid), not canControl: the EotW host can
--control everything but only their claimed heroes are theirs.
--
--Enumerated exactly the way combat entry does it (GatherCombatSides in
--EncounterOfTheWeek.lua): every token on the map whose properties IsHero.
--NOT Party.GetPlayerCharacters, which silently drops any token with a blank
--name -- an unnamed hero fought in the encounter but was missing from this
--strip and from the montage (report QKG5YTWG).
local function CollectHeroes()
    local result = {}
    for _, tok in ipairs(dmhub.allTokens) do
        if tok ~= nil and tok.valid then
            local isHero = false
            pcall(function() isHero = tok.properties ~= nil and tok.properties:IsHero() end)
            if isHero then
                local mine = false
                pcall(function() mine = tok.ownerId ~= nil and tok.ownerId == dmhub.loginUserid end)
                result[#result+1] = {
                    charid = tok.charid,
                    mine = mine,
                    name = HeroDisplayName(tok),
                }
            end
        end
    end
    table.sort(result, function(a, b)
        if a.mine ~= b.mine then
            return a.mine
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.charid < b.charid
    end)
    return result
end

--the montage allies ride in the signature too, so a monster joining a
--hero rebuilds the column with its card.
local function RosterSignature(heroes)
    local parts = {}
    for _, entry in ipairs(heroes) do
        local allies = {}
        local montage = rawget(_G, "EncounterMontage")
        if montage ~= nil and montage.GetAllies ~= nil then
            pcall(function() allies = montage.GetAllies(entry.charid) or {} end)
        end
        parts[#parts+1] = string.format("%s:%s:%s", entry.charid, tostring(entry.mine), table.concat(allies, ","))
    end
    return table.concat(parts, "|")
end

--The condition + status-effect entries shown as icons on a card: the same
--table lookups the character panel's condition chips use.
local function CollectConditions(c)
    local entries = {}
    local conditionsTable = dmhub.GetTable("charConditions") or {}
    local inflicted = nil
    pcall(function() inflicted = c:try_get("inflictedConditions") end)
    for condid, _ in pairs(inflicted or {}) do
        local info = conditionsTable[condid]
        if info ~= nil then
            entries[#entries+1] = {
                icon = info.iconid,
                display = info.display or {},
                name = info.name or "Condition",
            }
        end
    end

    local ongoingTable = dmhub.GetTable("characterOngoingEffects") or {}
    local effects = nil
    pcall(function() effects = c:ActiveOngoingEffects() end)
    for _, entry in ipairs(effects or {}) do
        local info = ongoingTable[entry.ongoingEffectid]
        if info ~= nil and info.statusEffect then
            local icon = nil
            local display = nil
            pcall(function()
                icon = info:GetDisplayIcon()
                display = info:GetDisplayDisplay()
            end)
            if icon ~= nil then
                entries[#entries+1] = {
                    icon = icon,
                    display = display or {},
                    name = info.name or "Effect",
                }
            end
        end
    end
    return entries
end

--- Hero cards ---------------------------------------------------------------

--The hero-card style rules, shared by the right-rail roster and the montage
--stage (EncounterMontageStage.lua): both wrap them in their own MergeTokens /
--MergeStyles call so the theme tokens resolve for that cascade root.
--the montage card's extras (opts.showStats): the characteristics strip down
--the right edge and the skills line under the name. Declared up here rather
--than beside the other card constants because the style rules need them.
local SKILLS_HEIGHT = 46
local STAT_ROW_HEIGHT = 15
local STAT_CHIP_WIDTH = 36
--the stats card (opts.showStats) is drawn a fifth larger than the roster's
--(user direction 2026-09-21); uiscale scales its layout size too, so the
--stage rows budget for the scaled card (EncounterMontageStage's
--HERO_ROW_HEIGHT).
local STATS_CARD_UISCALE = 1.2

local g_heroCardRules = {
    {
        selectors = {"eotwHeroCard"},
        bgcolor = "#151515",
        border = 1,
        borderColor = "#000000cc",
        transitionTime = 0.15,
    },
    {
        selectors = {"eotwHeroCard", "hover"},
        brightness = 1.15,
        borderColor = "#ffffff88",
    },
    {
        selectors = {"eotwHeroCard", "mine"},
        border = 2,
        borderColor = "#6fa8ffcc",
    },
    {
        selectors = {"eotwHeroCard", "mine", "hover"},
        borderColor = "#9cc4ffff",
    },
    {
        selectors = {"eotwHeroCard", "stats"},
        uiscale = STATS_CARD_UISCALE,
    },
    --the hero whose test is in flight (the stage sets "active"): a gold
    --border and a small transform scale -- scale rather than uiscale so the
    --neighbours do not shuffle when the turn passes.
    {
        selectors = {"eotwHeroCard", "active"},
        border = 3,
        borderColor = "#ffd66bff",
        scale = 1.06,
    },
    {
        selectors = {"eotwCardOverlay"},
        bgcolor = "#000000c0",
    },
    {
        selectors = {"eotwCardOverlay", "mine"},
        bgcolor = "#0d1e31d0",
    },
    {
        selectors = {"eotwHeroName"},
        fontSize = 12,
        bold = true,
        color = "#ffffff",
        width = "100%",
        height = 15,
        textAlignment = "left",
        textWrap = false,
        bmargin = 3,
    },
    --montage only (opts.showStats): one chip per characteristic ("M +2")
    --stacked down the card's right edge, and the comma-separated skills
    --line under the name. Both read over artwork, hence the dark chip and
    --the light-but-not-white skills text.
    --one fixed chip width for all five rows (auto width let "M +2" and
    --"I +1" size differently, which left the column ragged), with the
    --letter in a left column and the score in a right one so both line up
    --down the strip.
    {
        selectors = {"eotwStatChip"},
        width = STAT_CHIP_WIDTH,
        height = STAT_ROW_HEIGHT,
        halign = "right",
        flow = "horizontal",
        bgimage = "panels/square.png",
        bgcolor = "#000000b0",
        cornerRadius = 3,
        hpad = 3,
        borderBox = true,
        tmargin = 1,
    },
    --the characteristic the test in flight is rolled with (the stage's
    --highlightCharacteristic event): gold chip, dark text.
    {
        selectors = {"eotwStatChip", "active"},
        bgcolor = "#ffd66bf0",
        border = 1,
        borderColor = "#fff2c0ff",
    },
    {
        selectors = {"eotwStatKey", "parent:active"},
        color = "#1a1200",
    },
    {
        selectors = {"eotwStatValue", "parent:active"},
        color = "#1a1200",
    },
    {
        selectors = {"eotwStatKey"},
        fontSize = 11,
        bold = true,
        color = "#ffffff",
        width = 12,
        height = "100%",
        halign = "left",
        valign = "center",
        textAlignment = "left",
        textWrap = false,
    },
    {
        selectors = {"eotwStatValue"},
        fontSize = 11,
        bold = true,
        color = "#ffffff",
        width = 18,
        height = "100%",
        halign = "right",
        valign = "center",
        textAlignment = "right",
        textWrap = false,
    },
    {
        selectors = {"eotwSkillsLine"},
        fontSize = 9,
        color = "#c6d0da",
        width = "100%",
        height = SKILLS_HEIGHT,
        textAlignment = "topleft",
        textWrap = true,
        bmargin = 2,
    },
    {
        selectors = {"eotwResIcon"},
        width = 17,
        height = 17,
        halign = "left",
        valign = "center",
        bgcolor = "white",
    },
    {
        selectors = {"eotwResValue"},
        fontSize = 14,
        bold = true,
        color = "#ffffff",
        width = "auto",
        height = "auto",
        --both the icon and the value align left so the flow packs
        --them together instead of spreading them across the row.
        halign = "left",
        valign = "center",
        lmargin = 3,
    },
    --the health bar's state tints, copied from the character
    --panel's HealthFill styles: success/warning/danger are the
    --documented theme tiers for stamina. The gradient overrides
    --the global fillBarFill's flat horizontal shade with a glossy
    --vertical one; grayscale stops so the bgcolor tint carries
    --the state color.
    {
        selectors = {"fillBarFill", "healthFill"},
        bgcolor = "@success",
        gradient = gui.Gradient{
            point_a = {x = 0, y = 0},
            point_b = {x = 0, y = 1},
            stops = {
                { position = 0, color = "#5A5A5A" },
                { position = 0.45, color = "#8E8E8E" },
                { position = 0.55, color = "#B4B4B4" },
                { position = 1, color = "#E4E4E4" },
            },
        },
    },
    {
        selectors = {"healthFill", "winded"},
        transitionTime = 0.4,
        bgcolor = "@warning",
    },
    {
        selectors = {"healthFill", "dying"},
        transitionTime = 0.4,
        bgcolor = "@danger",
    },
    {
        selectors = {"fillBarFill", "eotwTempFill"},
        bgcolor = "@accent",
        gradient = gui.Gradient{
            point_a = {x = 0, y = 0},
            point_b = {x = 0, y = 1},
            stops = {
                { position = 0, color = "#6A6A6A" },
                { position = 1, color = "#E4E4E4" },
            },
        },
    },
    {
        selectors = {"eotwBarLabel"},
        fontSize = 10,
        bold = true,
        color = "#ffffff",
        width = "100%",
        height = "100%",
        textAlignment = "center",
        textWrap = false,
    },
    --the recoveries circle to the left of the stamina bar: a dark disc
    --with a light ring and the count in white.
    {
        selectors = {"eotwRecoveriesCircle"},
        width = 16,
        height = 16,
        valign = "center",
        halign = "left",
        rmargin = 3,
        cornerRadius = 8,
        bgimage = "panels/square.png",
        bgcolor = "#000000aa",
        border = 1,
        borderColor = "#ffffffaa",
    },
    {
        selectors = {"eotwRecoveriesCircle", "empty"},
        borderColor = "#ff5555aa",
    },
    {
        selectors = {"eotwRecoveriesLabel"},
        fontSize = 10,
        bold = true,
        color = "#ffffff",
        width = "100%",
        height = "100%",
        halign = "center",
        valign = "center",
        textAlignment = "center",
        textWrap = false,
    },
    {
        selectors = {"eotwSurgeIcon"},
        width = 12,
        height = 12,
        valign = "center",
        lmargin = 1,
        bgimage = "game-icons/surge.png",
        bgcolor = "white",
    },
    --the hurt flash: a red wash over the whole card for a moment when the
    --creature loses stamina. It has to be its own floating overlay rather
    --than a tint on the card, because refreshCard writes
    --selfStyle.bgcolor = "white" to keep the portrait untinted and
    --selfStyle beats every class rule. Its own class also keeps it out of
    --the fight over {eotwHeroCard} borderColor that the stage's
    --selected/flashing rules would win.
    --
    --PulseClass applies the {hurt} rule instantly and then ramps it back
    --out over THAT rule's transitionTime, so the fade timing lives there,
    --not on the resting rule. The resting rule keeps the border WIDTH so
    --only the color animates -- a border whose width changed would shift
    --the panel's content box mid-flash.
    {
        selectors = {"eotwHurtFlash"},
        bgimage = "panels/square.png",
        bgcolor = "#ff3b3b00",
        border = 3,
        borderColor = "#ff808000",
    },
    {
        selectors = {"eotwHurtFlash", "hurt"},
        bgcolor = "#ff3b3baa",
        borderColor = "#ff8080ff",
        transitionTime = 0.45,
        easing = "easeOutCubic",
    },
    --the heal flash: the same overlay in green, for the other direction.
    --Everything the hurt flash's note above says applies here too -- it is
    --a second floating wash for the same reasons, and the fade lives on
    --the {healed} rule's transitionTime.
    --
    --A hero can be healed and hurt in the same instant (a montage clause
    --that costs Stamina and a heal landing together), so these are two
    --overlays rather than one with two colors: each pulses on its own and
    --the later one simply sits on top.
    {
        selectors = {"eotwHealFlash"},
        bgimage = "panels/square.png",
        bgcolor = "#3bff7b00",
        border = 3,
        borderColor = "#80ffa000",
    },
    {
        selectors = {"eotwHealFlash", "healed"},
        bgcolor = "#3bff7b99",
        borderColor = "#80ffa0ff",
        transitionTime = 0.45,
        easing = "easeOutCubic",
    },
}


local CARD_WIDTH = 132
local CARD_HEIGHT = 176
local OVERLAY_HEIGHT = 60
--condition chips in the card's top-right corner: the outer dark/red-bordered
--chip and the condition icon inside it.
local CONDITION_CHIP_SIZE = 26
local CONDITION_ICON_SIZE = 18

--The wash a card wears for a moment when its creature's stamina moves: red
--({eotwHurtFlash}, pulsed "hurt") for a loss, green ({eotwHealFlash},
--pulsed "healed") for a heal. The card pulses them from its own
--staminaLost / staminaGained handlers, which the card's stamina bar fires
--up the hierarchy.
local function CreateCardFlash(class, cornerRadius)
    return gui.Panel{
        classes = {class},
        floating = true,
        width = "100%",
        height = "100%",
        halign = "center",
        valign = "center",
        cornerRadius = cornerRadius,
        interactable = false,
    }
end

--The roster and the montage stage each build their own card for the same
--hero, so one point of damage (or one heal) gets noticed twice. Keyed by
--charid, these remember the stamina total the sound last fired for and
--when: whichever card sees the change first plays it and the other stays
--silent. (Attack.Hit already de-duplicates itself over 0.2s, but the two
--surfaces refresh on different cadences -- 0.5s on the stage, 1s on the
--roster -- so they can easily notice the same hit further apart than that.)
--
--The window is what makes it a de-duplicator rather than a mute: landing
--on the same total again later -- healed back up and hit for the same
--amount -- is a new hit and must sound like one.
local CARD_SOUND_DEDUP = 2
local g_hurtSound = {}
local g_healSound = {}

--2D, with no tokenid: the card is what the player is looking at, and
--during a montage the map is not even on screen to position it in.
local function FireCardSound(seen, charid, total, eventName)
    local now = dmhub.Time()
    local last = seen[charid]
    if last ~= nil and last.total == total and now - last.t < CARD_SOUND_DEDUP then
        return
    end
    seen[charid] = { total = total, t = now }
    audio.FireSoundEvent(eventName)
end

--How the bar slides to a new stamina value instead of snapping to it, so
--damage reads as a drain. The ease is exponential (tau), with a floor on
--the speed -- a full bar in MAX_TIME seconds -- so the exponential tail
--still lands promptly instead of creeping.
local STAMINA_SLIDE_TAU = 0.14
local STAMINA_SLIDE_MAX_TIME = 0.7
local STAMINA_SLIDE_THINK = 0.02

--The stamina bar: the character panel's health bar in miniature -- a
--theme-bordered track whose border and fill both track the
--healthy/winded/dying state (success/warning/danger, the documented
--stamina tiers), with a glossy vertical gradient on the fill, the
--cur/max numbers centered in white, and a temp-stamina segment in the
--accent color riding the end of the fill when the hero has any.
--
--A drop in stamina drains the fill down over ~0.3-0.7s (the numbers count
--with it), fires the generic hit sound, and fires "staminaLost" up the
--hierarchy so the card it sits on can flash red. A rise in stamina does
--the mirror image: the generic heal sound and "staminaGained", so the
--card flashes green.
local function CreateStaminaBar(charid)
    local fill = gui.Panel{
        classes = {"fillBarFill", "healthFill"},
        width = "0%",
        height = "100%-2",
        valign = "center",
        halign = "left",
        lmargin = 1,
        bgimage = true,
        interactable = false,
    }
    local tempFill = gui.Panel{
        classes = {"fillBarFill", "eotwTempFill"},
        width = "0%",
        height = "100%-2",
        valign = "center",
        halign = "left",
        bgimage = true,
        interactable = false,
    }
    local numbers = gui.Label{
        classes = {"eotwBarLabel"},
        floating = true,
        halign = "center",
        valign = "center",
        text = "",
        interactable = false,
    }

    --what the fill is drawn at right now, easing toward the true fraction
    --(m_targetPct). nil until the first refresh, which snaps: a card built
    --mid-encounter must not animate up from empty.
    local m_shownPct = nil
    local m_targetPct = 0
    --the clock for the slide, and the marker that one is running.
    local m_slideTime = nil
    --the values the numbers read.
    local m_cur, m_max, m_temp = 0, 0, 0
    --stamina + temp stamina as of the last refresh, so a drop can be
    --spotted. nil until the first refresh, so a card built on an already
    --hurt hero does not flash on arrival.
    local m_seenTotal = nil
    --stamina ALONE as of the last refresh, for spotting a heal. Temp
    --stamina is deliberately left out of this one: a grant of temp is not
    --healing (it has its own Notify.TempStamina_Gain elsewhere), and
    --counting it would flash the card green for it. nil on the same terms
    --as m_seenTotal.
    local m_seenCur = nil

    --paint the two fills and the numbers from m_shownPct.
    local function Paint()
        local pct = m_shownPct or 0
        fill.selfStyle.width = string.format("%f%%", pct * 98)
        local tempPct = 0
        if m_max > 0 and m_temp > 0 then
            tempPct = math.min(1 - pct, m_temp / m_max)
        end
        tempFill.selfStyle.width = string.format("%f%%", tempPct * 98)
        --mid-slide the number counts with the bar; once it lands the true
        --value shows. Only while stamina is positive: a dying hero's is
        --negative while the bar is pinned empty, and counting down to that
        --through the fraction would not reach it.
        local shown = m_cur
        if m_shownPct ~= m_targetPct and m_cur > 0 then
            shown = math.ceil(pct * m_max)
        end
        local text = string.format("%d/%d", shown, m_max)
        if m_temp > 0 then
            text = string.format("%s +%d", text, m_temp)
        end
        numbers.text = text
    end

    return gui.Panel{
        classes = {"bordered"},
        width = "100%",
        height = 14,
        flow = "horizontal",
        halign = "center",
        cornerRadius = 2,
        bgimage = true,
        bgcolor = "#00000066",
        interactable = false,
        fill,
        tempFill,
        numbers,

        --any character change (damage, healing, temp stamina) lands here
        --straight away, so the flash and the hit sound follow the hit
        --rather than the card's own refresh cadence (0.5s on the montage
        --stage, 1s on the roster), which stays as the fallback.
        monitorGame = "/characters",
        refreshGame = function(element)
            element:FireEvent("refreshCard")
        end,

        refreshCard = function(element)
            local tok = dmhub.GetCharacterById(charid)
            if tok == nil or not tok.valid or tok.properties == nil then
                return
            end
            local c = tok.properties
            local cur, max, temp = 0, 0, 0
            local winded, dying = false, false
            local ok = pcall(function()
                cur = c:CurrentHitpoints()
                max = c:MaxHitpoints()
                temp = c:TemporaryHitpoints() or 0
                winded = cur <= c:BloodiedThreshold()
                dying = c:IsDying()
            end)
            --a failed read leaves cur at 0, which would read as a wipeout
            --and drain the bar for no reason: leave it where it is.
            if not ok or max <= 0 then
                return
            end
            m_cur, m_max, m_temp = cur, max, temp
            m_targetPct = math.max(0, math.min(1, cur / max))

            --stamina lost: flash the card and play the hit. Temp stamina
            --is counted in, so a hit fully soaked by temp still reads as
            --one -- it is still damage taken.
            local total = cur + temp
            if m_seenTotal ~= nil and total < m_seenTotal then
                element:FireEventOnParents("staminaLost", m_seenTotal - total)
                FireCardSound(g_hurtSound, charid, total, "Attack.Hit")
            end
            m_seenTotal = total

            --stamina gained: flash the card green and play the heal. Off
            --`cur` rather than the total, so temp stamina landing does not
            --read as a heal, and a hero healed out of dying (cur going
            --from negative to positive) still does.
            if m_seenCur ~= nil and cur > m_seenCur then
                element:FireEventOnParents("staminaGained", cur - m_seenCur)
                FireCardSound(g_healSound, charid, cur, "Ability.Heal_Generic")
            end
            m_seenCur = cur

            if m_shownPct == nil then
                m_shownPct = m_targetPct
            elseif m_shownPct ~= m_targetPct then
                if m_slideTime == nil then
                    m_slideTime = dmhub.Time()
                end
                element.thinkTime = STAMINA_SLIDE_THINK
            end

            fill:SetClass("winded", winded)
            fill:SetClass("dying", dying)
            element:SetClass("borderSuccess", not winded and not dying)
            element:SetClass("borderWarning", winded and not dying)
            element:SetClass("borderDanger", dying)
            Paint()
        end,

        --only runs while the bar is catching up to a new value; the last
        --step takes thinkTime back off.
        think = function(element)
            local now = dmhub.Time()
            local dt = math.max(0, math.min(0.25, now - (m_slideTime or now)))
            m_slideTime = now
            local diff = m_targetPct - (m_shownPct or 0)
            local step = diff * (1 - math.exp(-dt / STAMINA_SLIDE_TAU))
            local floorStep = dt / STAMINA_SLIDE_MAX_TIME
            if math.abs(step) < floorStep then
                step = floorStep * cond(diff < 0, -1, 1)
            end
            if math.abs(step) >= math.abs(diff) then
                m_shownPct = m_targetPct
                m_slideTime = nil
                element.thinkTime = nil
            else
                m_shownPct = (m_shownPct or 0) + step
            end
            Paint()
        end,
    }
end

--Heroic resource, icon only: the class's heroic resource icon (the
--character panel's own source) with the current value beside it. Surges
--are NOT here -- they render as per-surge icons in the card's bottom-right
--corner (CreateSurgeCorner).
local function CreateResourceRow(charid)
    local hrIcon = gui.Panel{
        classes = {"eotwResIcon"},
        interactable = false,
        refreshCard = function(element)
            local tok = dmhub.GetCharacterById(charid)
            if tok == nil or not tok.valid or tok.properties == nil then
                return
            end
            local icon = nil
            pcall(function()
                local classInfo = tok.properties:GetClass()
                if classInfo ~= nil then
                    icon = classInfo:try_get("heroicResourceIcon")
                end
            end)
            element:SetClass("hidden", icon == nil)
            if icon ~= nil then
                element.selfStyle.bgimage = icon
            end
        end,
        linger = function(element)
            local tok = dmhub.GetCharacterById(charid)
            if tok ~= nil and tok.valid and tok.properties ~= nil then
                local name = nil
                pcall(function() name = tok.properties:GetHeroicResourceName() end)
                gui.Tooltip(name or "Heroic Resource")(element)
            end
        end,
    }
    local hrValue = gui.Label{
        classes = {"eotwResValue"},
        text = "0",
        interactable = false,
        refreshCard = function(element)
            local tok = dmhub.GetCharacterById(charid)
            if tok == nil or not tok.valid or tok.properties == nil then
                return
            end
            local value = 0
            pcall(function() value = tok.properties:GetHeroicOrMaliceResources() or 0 end)
            element.text = tostring(value)
        end,
    }
    return gui.Panel{
        width = "100%",
        height = 19,
        flow = "horizontal",
        halign = "left",
        valign = "center",
        hrIcon,
        hrValue,
    }
end

--The recoveries circle: the hero's remaining recoveries (max minus the
--ones spent this long rest), in a small ringed disc. The ring turns red
--when none are left.
local function CreateRecoveriesCircle(charid)
    local label = gui.Label{
        classes = {"eotwRecoveriesLabel"},
        text = "0",
        interactable = false,
    }
    return gui.Panel{
        classes = {"eotwRecoveriesCircle"},
        label,
        refreshCard = function(element)
            local tok = dmhub.GetCharacterById(charid)
            if tok == nil or not tok.valid or tok.properties == nil then
                return
            end
            local current = 0
            pcall(function()
                local c = tok.properties
                local id = CharacterResource.recoveryResourceId
                local max = c:GetResources()[id] or 0
                local used = c:GetResourceUsage(id, "long") or 0
                current = math.max(0, max - used)
            end)
            label.text = tostring(current)
            element:SetClass("empty", current <= 0)
        end,
        linger = function(element)
            local tok = dmhub.GetCharacterById(charid)
            if tok == nil or not tok.valid or tok.properties == nil then
                return
            end
            local current, max, recoveryValue = 0, 0, nil
            pcall(function()
                local c = tok.properties
                local id = CharacterResource.recoveryResourceId
                max = c:GetResources()[id] or 0
                local used = c:GetResourceUsage(id, "long") or 0
                current = math.max(0, max - used)
                recoveryValue = c:RecoveryAmount()
            end)
            local lines = {
                string.format("<b>Recoveries: %d / %d</b>", current, max),
            }
            if recoveryValue ~= nil then
                lines[#lines+1] = string.format("Recovery Value: %d Stamina", recoveryValue)
            end
            gui.Tooltip(table.concat(lines, "\n"))(element)
        end,
    }
end

--The hero card's stamina row: the recoveries circle on the left, the
--stamina bar filling the rest. The bar keeps firing staminaLost /
--staminaGained up through this row to the card.
local function CreateStaminaRow(charid)
    return gui.Panel{
        width = "100%",
        height = 16,
        flow = "horizontal",
        halign = "center",
        valign = "center",
        interactable = false,
        CreateRecoveriesCircle(charid),
        gui.Panel{
            width = "100%-19",
            height = "auto",
            valign = "center",
            interactable = false,
            CreateStaminaBar(charid),
        },
    }
end

--One surge icon PER available surge, in the card's bottom-right corner --
--and nothing at all when the hero has none. Rebuilt only when the count
--changes; display capped at 9 icons (they would outgrow the card).
local function CreateSurgeCorner(charid)
    return gui.Panel{
        floating = true,
        halign = "right",
        valign = "bottom",
        x = -4,
        y = -3,
        width = "auto",
        height = 13,
        flow = "horizontal",
        interactable = false,
        data = { count = nil },
        refreshCard = function(element)
            local tok = dmhub.GetCharacterById(charid)
            if tok == nil or not tok.valid or tok.properties == nil then
                return
            end
            local surges = 0
            pcall(function() surges = tok.properties:GetAvailableSurges() or 0 end)
            if surges == element.data.count then
                return
            end
            element.data.count = surges
            local icons = {}
            for i = 1, math.min(surges, 9) do
                icons[#icons+1] = gui.Panel{
                    classes = {"eotwSurgeIcon"},
                    interactable = false,
                }
            end
            element.children = icons
        end,
    }
end

--A gently pulsing "!" trigger badge in the card's top-left corner while
--the hero has an available (non-hostile, undismissed) trigger -- the same
--test the Monster AI's trigger-reaction dice uses. Hostile prompts are
--skipped because they never expire and would pulse forever. Hover lists
--the pending triggers; clicking centers the map on the hero and selects
--them (selection only takes for a hero the user controls). Rebuilt only
--when the set of trigger ids changes.
local function CreateTriggerCorner(charid)
    local badge = gui.TriggerPanel{
        width = 22,
        height = 22,
        halign = "left",
        valign = "top",
        swallowPress = true,
        data = { tooltipText = "" },
        hover = function(element)
            element.tooltip = element.data.tooltipText
        end,
        press = function(element)
            audio.FireSoundEvent("Mouse.Click")
            dmhub.CenterOnToken(charid, function()
                dmhub.SelectToken(charid)
            end)
        end,
        thinkTime = 0.03,
        think = function(element)
            local r = (math.sin(dmhub.Time() * 2 * math.pi / 1.4) + 1) / 2
            element.selfStyle.opacity = 0.6 + 0.4 * r
            element.selfStyle.scale = 0.92 + 0.16 * r
        end,
    }

    return gui.Panel{
        classes = {"collapsed"},
        floating = true,
        halign = "left",
        valign = "top",
        x = 4,
        y = 4,
        width = 22,
        height = 22,
        styles = Styles.TriggerStyles,
        data = { sig = nil },
        refreshCard = function(element)
            local tok = dmhub.GetCharacterById(charid)
            if tok == nil or not tok.valid or tok.properties == nil then
                return
            end
            local triggers = nil
            pcall(function() triggers = tok.properties:GetAvailableTriggers(true) end)
            local ids = {}
            local lines = {}
            if triggers ~= nil then
                for id, t in pairs(triggers) do
                    if not t.hostile then
                        ids[#ids+1] = id
                        local text = t.text
                        if t.powerRollModifier then
                            text = t.powerRollModifier:try_get("name") or text
                        end
                        if text ~= nil and text ~= "" then
                            lines[#lines+1] = text
                        end
                    end
                end
            end
            table.sort(ids)
            local sig = table.concat(ids, ",")
            if sig == element.data.sig then
                return
            end
            element.data.sig = sig
            if #ids == 0 then
                element:SetClass("collapsed", true)
                return
            end
            table.sort(lines)
            local name = HeroDisplayName(tok)
            local tip = string.format("%s has a trigger available.", name)
            if #lines > 0 then
                tip = tip .. "\n\n" .. table.concat(lines, "\n")
            end
            tip = tip .. "\n\nClick to jump to " .. name .. "."
            badge.data.tooltipText = tip
            element:SetClass("collapsed", false)
        end,
        badge,
    }
end

--MONTAGE ONLY (opts.showStats). The five characteristics down the card's
--right edge, one chip each, initial + score ("M +2") so the whole set fits
--in the artwork's margin. Ordered by the attribute's own `order` (Might,
--Agility, Reason, Intuition, Presence -- MARIP), read from the game system
--rather than hardcoded so a system with other characteristics still works.
local function CreateStatStrip(charid)
    local attrList = {}
    for _, info in pairs(creature.attributesInfo) do
        attrList[#attrList+1] = info
    end
    table.sort(attrList, function(a, b) return a.order < b.order end)

    local rows = {}
    for _, info in ipairs(attrList) do
        local attrid = info.id
        local initial = string.sub(info.description, 1, 1)
        rows[#rows+1] = gui.Panel{
            classes = {"eotwStatChip"},
            interactable = false,
            --the stage fires this down the card with the attrid the test in
            --flight is rolled with (nil = none): that chip turns gold.
            highlightCharacteristic = function(element, activeAttrid)
                element:SetClass("active", activeAttrid == attrid)
            end,
            gui.Label{
                classes = {"eotwStatKey"},
                text = initial,
                interactable = false,
            },
            gui.Label{
                classes = {"eotwStatValue"},
                text = "",
                interactable = false,
                refreshCard = function(element)
                    local tok = dmhub.GetCharacterById(charid)
                    if tok == nil or not tok.valid or tok.properties == nil then
                        return
                    end
                    local value = nil
                    pcall(function() value = tok.properties:GetAttribute(attrid):Modifier() end)
                    if value == nil then
                        return
                    end
                    element.text = string.format("%+d", value)
                end,
            },
        }
    end

    --below the condition chips (top-right) and above the overlay, so the
    --strip never collides with either.
    return gui.Panel{
        floating = true,
        halign = "right",
        valign = "top",
        x = -3,
        y = 34,
        width = "auto",
        height = "auto",
        flow = "vertical",
        interactable = false,
        children = rows,
    }
end

--MONTAGE ONLY (opts.showStats). The hero's trained skills, comma separated,
--on the line under their name. Skills do not change during an encounter, so
--the (30-odd skill) proficiency sweep runs at most every few seconds rather
--than on every refreshCard tick.
local SKILLS_RECHECK_SECONDS = 5

--The skill the test in flight is using (the stage's highlightSkill event)
--is set in gold within the line.
local SKILL_HIGHLIGHT_COLOR = "#ffd66b"

local function CreateSkillsLine(charid)
    --skills = the proficient {id, name} pairs in display order; skillid =
    --the one to highlight, nil for none. Rendered again whenever either
    --changes.
    local function Render(element)
        local parts = {}
        for _, skill in ipairs(element.data.skills) do
            if skill.id == element.data.skillid then
                parts[#parts+1] = string.format("<color=%s><b>%s</b></color>", SKILL_HIGHLIGHT_COLOR, skill.name)
            else
                parts[#parts+1] = skill.name
            end
        end
        element.text = table.concat(parts, ", ")
    end

    return gui.Label{
        classes = {"eotwSkillsLine"},
        text = "",
        interactable = false,
        data = { nextCheck = 0, signature = nil, skills = {}, skillid = nil },
        refreshCard = function(element)
            local now = dmhub.Time()
            if now < element.data.nextCheck then
                return
            end
            element.data.nextCheck = now + SKILLS_RECHECK_SECONDS
            local tok = dmhub.GetCharacterById(charid)
            if tok == nil or not tok.valid or tok.properties == nil then
                return
            end
            local skills = {}
            local ids = {}
            pcall(function()
                --Skill.SkillsInfo is already sorted by name.
                for _, skill in ipairs(Skill.SkillsInfo) do
                    if tok.properties:ProficientInSkill(skill) then
                        skills[#skills+1] = { id = skill.id, name = skill.name }
                        ids[#ids+1] = skill.id
                    end
                end
            end)
            local signature = table.concat(ids, ",")
            if signature == element.data.signature then
                return
            end
            element.data.signature = signature
            element.data.skills = skills
            Render(element)
        end,
        highlightSkill = function(element, skillid)
            if skillid == element.data.skillid then
                return
            end
            element.data.skillid = skillid
            Render(element)
        end,
    }
end

--opts (all optional):
--  halign      the card's halign (default "right", the roster's edge)
--  draggable   non-nil = the drag callbacks below are passed through to
--              the panel (the montage stage); the value itself is the
--              card's starting draggable state, which the caller may flip
--              later (the stage makes only the local user's own heroes
--              draggable, and only while they can act)
--  canDragOnto, drag, beginDrag   drag callbacks (see Definitions/Panel.lua)
--  useClick    use the click event for the character-panel popout instead
--              of press (press also fires when a drag gesture ends)
--  click       replaces the character-panel popout with this handler
--              (element, OpenCharacterPanel) -- the second argument is the
--              default behavior, for handlers that fall back to it
--  showStats   the montage stage's fuller card: the characteristics strip
--              down the right edge and the skills line under the name (the
--              roster's cards are too crowded for either)
local function CreateHeroCard(entry, opts)
    opts = opts or {}
    local charid = entry.charid
    local mineClass = nil
    if entry.mine then
        mineClass = "mine"
    end

    local nameLabel = gui.Label{
        classes = {"eotwHeroName"},
        text = entry.name,
        interactable = false,
    }

    --condition icons over the artwork, packed into the TOP-RIGHT corner
    --(user direction 2026-08-29 -- they used to center across the top);
    --rebuilt only when the set actually changes. Each icon sits on a dark
    --red-bordered chip so it reads against any portrait.
    local conditionsRow = gui.Panel{
        floating = true,
        halign = "right",
        valign = "top",
        x = -4,
        y = 4,
        width = CARD_WIDTH - 8,
        height = "auto",
        flow = "horizontal",
        wrap = true,
        interactable = false,
        data = { signature = nil },
        refreshCard = function(element)
            local tok = dmhub.GetCharacterById(charid)
            if tok == nil or not tok.valid or tok.properties == nil then
                return
            end
            local entries = CollectConditions(tok.properties)
            local parts = {}
            for _, cond in ipairs(entries) do
                parts[#parts+1] = tostring(cond.icon)
            end
            local sig = table.concat(parts, "|")
            if sig == element.data.signature then
                return
            end
            element.data.signature = sig
            local icons = {}
            for _, cond in ipairs(entries) do
                local condName = cond.name
                --halign right on every chip is what right-packs the row:
                --the flow layout places the trailing run of halign="right"
                --children against the right edge, in order.
                icons[#icons+1] = gui.Panel{
                    halign = "right",
                    width = CONDITION_CHIP_SIZE,
                    height = CONDITION_CHIP_SIZE,
                    lmargin = 3,
                    bmargin = 3,
                    bgimage = "panels/square.png",
                    bgcolor = "#000000cc",
                    cornerRadius = 6,
                    border = 2,
                    borderColor = "#cc2222ff",
                    linger = function(iconElement)
                        gui.Tooltip(condName)(iconElement)
                    end,
                    gui.Panel{
                        width = CONDITION_ICON_SIZE,
                        height = CONDITION_ICON_SIZE,
                        halign = "center",
                        valign = "center",
                        bgimage = cond.icon,
                        bgcolor = cond.display.bgcolor or "white",
                        hueshift = cond.display.hueshift or 0,
                        saturation = cond.display.saturation or 1,
                        brightness = cond.display.brightness or 1,
                        interactable = false,
                    },
                }
            end
            element.children = icons
        end,
    }

    --the bottom-third overlay: name, stamina bar, resource icons on a
    --semi-opaque plate over the artwork. On the montage card the skills
    --line sits under the name, and the plate grows to make room for it.
    local overlayChildren = { nameLabel }
    if opts.showStats then
        overlayChildren[#overlayChildren+1] = CreateSkillsLine(charid)
    end
    overlayChildren[#overlayChildren+1] = CreateStaminaRow(charid)
    overlayChildren[#overlayChildren+1] = CreateResourceRow(charid)

    local overlayHeight = OVERLAY_HEIGHT
    local cardHeight = CARD_HEIGHT
    if opts.showStats then
        overlayHeight = OVERLAY_HEIGHT + SKILLS_HEIGHT
        --the plate grows downward out of the artwork rather than eating into
        --it: the card itself gets the extra height (EncounterMontageStage's
        --HERO_ROW_HEIGHT budgets for it).
        cardHeight = CARD_HEIGHT + SKILLS_HEIGHT
    end

    local overlay = gui.Panel{
        classes = {"eotwCardOverlay", mineClass},
        floating = true,
        halign = "center",
        valign = "bottom",
        width = "100%",
        height = overlayHeight,
        flow = "vertical",
        bgimage = "panels/square.png",
        cornerRadius = 8,
        hpad = 6,
        vpad = 4,
        borderBox = true,
        interactable = false,

        children = overlayChildren,
    }

    --the red wash for a hit and the green one for a heal, over the artwork
    --and the overlay alike.
    local hurtFlash = CreateCardFlash("eotwHurtFlash", 8)
    local healFlash = CreateCardFlash("eotwHealFlash", 8)

    --the card IS the portrait: full-bleed artwork with the overlay and
    --condition chips floating on top.
    local function OpenCharacterPanel(element)
        audio.FireSoundEvent("Mouse.Click")
        local toggle = rawget(_G, "ToggleCharacterPanelDocument")
        if toggle ~= nil then
            --anchored to this card: the window opens right beside it
            --instead of at the remembered/center position.
            toggle(charid, nil, element)
        end
    end

    --no holes in the class list: the engine stops at the first nil.
    local cardClasses = {"eotwHeroCard"}
    if mineClass ~= nil then
        cardClasses[#cardClasses+1] = mineClass
    end
    if opts.showStats then
        cardClasses[#cardClasses+1] = "stats"
    end

    local cardArgs = {
        classes = cardClasses,
        width = CARD_WIDTH,
        height = cardHeight,
        halign = opts.halign or "right",
        cornerRadius = 8,
        bgimage = "panels/square.png",
        swallowPress = true,

        data = { charid = charid, mine = entry.mine },

        refreshCard = function(element)
            local tok = dmhub.GetCharacterById(charid)
            if tok == nil or not tok.valid then
                return
            end
            nameLabel.text = HeroDisplayName(tok)
            local portrait = nil
            pcall(function() portrait = tok.offTokenPortrait end)
            if portrait ~= nil and portrait ~= "" then
                --bgcolor white keeps the artwork untinted; the card's
                --border and the overlay carry the mine/others styling.
                element.bgimage = portrait
                element.selfStyle.bgcolor = "white"
                local rect = nil
                pcall(function() rect = tok:GetPortraitRectForAspect(CARD_WIDTH / cardHeight, portrait) end)
                element.selfStyle.imageRect = rect
            end
        end,

        --fired up from the stamina bar in the overlay when this hero loses
        --or regains stamina.
        staminaLost = function(element)
            hurtFlash:PulseClass("hurt")
        end,

        staminaGained = function(element)
            healFlash:PulseClass("healed")
        end,

        conditionsRow,
        overlay,
        CreateSurgeCorner(charid),
        CreateTriggerCorner(charid),
    }
    if opts.showStats then
        cardArgs[#cardArgs+1] = CreateStatStrip(charid)
    end
    --last, so the washes sit over every other layer of the card.
    cardArgs[#cardArgs+1] = hurtFlash
    cardArgs[#cardArgs+1] = healFlash
    if opts.click ~= nil then
        cardArgs.click = function(element)
            opts.click(element, OpenCharacterPanel)
        end
    elseif opts.useClick then
        cardArgs.click = OpenCharacterPanel
    else
        cardArgs.press = OpenCharacterPanel
    end
    if opts.draggable ~= nil then
        cardArgs.draggable = opts.draggable == true
        cardArgs.canDragOnto = opts.canDragOnto
        cardArgs.drag = opts.drag
        cardArgs.beginDrag = opts.beginDrag
    end
    --the card as a drop target (the montage drops item icons on it).
    if opts.dragTarget then
        cardArgs.dragTarget = true
        cardArgs.dragTargetPriority = opts.dragTargetPriority
        cardArgs.dragTargets = opts.dragTargets
    end
    return gui.Panel(cardArgs)
end

--A half-size card for a monster that joined a hero during a montage
--(EncounterMontage): portrait, name and stamina bar. Sits under the hero's
--card in the roster and on the montage stage.
local ALLY_CARD_WIDTH = 62
local ALLY_CARD_HEIGHT = 80

local function CreateAllyCard(charid)
    local nameLabel = gui.Label{
        classes = {"eotwHeroName"},
        fontSize = 10,
        height = 12,
        text = "",
        interactable = false,
    }
    local overlay = gui.Panel{
        classes = {"eotwCardOverlay"},
        floating = true,
        halign = "center",
        valign = "bottom",
        width = "100%",
        height = 30,
        flow = "vertical",
        bgimage = "panels/square.png",
        cornerRadius = 6,
        hpad = 3,
        vpad = 2,
        borderBox = true,
        interactable = false,
        nameLabel,
        CreateStaminaBar(charid),
    }
    local hurtFlash = CreateCardFlash("eotwHurtFlash", 6)
    local healFlash = CreateCardFlash("eotwHealFlash", 6)
    return gui.Panel{
        classes = {"eotwHeroCard", "eotwAllyCard"},
        width = ALLY_CARD_WIDTH,
        height = ALLY_CARD_HEIGHT,
        halign = "left",
        hmargin = 1,
        cornerRadius = 6,
        bgimage = "panels/square.png",
        swallowPress = true,
        data = { charid = charid },
        press = function(element)
            audio.FireSoundEvent("Mouse.Click")
            local toggle = rawget(_G, "ToggleCharacterPanelDocument")
            if toggle ~= nil then
                toggle(charid, nil, element)
            end
        end,
        linger = function(element)
            gui.Tooltip(nameLabel.text)(element)
        end,
        refreshCard = function(element)
            local tok = dmhub.GetCharacterById(charid)
            if tok == nil or not tok.valid then
                element:SetClass("collapsed", true)
                return
            end
            element:SetClass("collapsed", false)
            --an ally is a MONSTER that joined a hero, so no "Unnamed Hero".
            nameLabel.text = tok.name or ""
            local portrait = nil
            pcall(function() portrait = tok.offTokenPortrait end)
            if portrait ~= nil and portrait ~= "" then
                element.bgimage = portrait
                element.selfStyle.bgcolor = "white"
                local rect = nil
                pcall(function() rect = tok:GetPortraitRectForAspect(ALLY_CARD_WIDTH / ALLY_CARD_HEIGHT, portrait) end)
                element.selfStyle.imageRect = rect
            end
        end,
        --fired up from the stamina bar in the overlay.
        staminaLost = function(element)
            hurtFlash:PulseClass("hurt")
        end,
        staminaGained = function(element)
            healFlash:PulseClass("healed")
        end,
        overlay,
        hurtFlash,
        healFlash,
    }
end

--The montage allies of a hero (charids), or an empty list.
local function AlliesOf(charid)
    local montage = rawget(_G, "EncounterMontage")
    if montage == nil or montage.GetAllies == nil then
        return {}
    end
    local allies = {}
    pcall(function() allies = montage.GetAllies(charid) end)
    return allies or {}
end

--- The roster panel ---------------------------------------------------------

--The vertical space the column has to live in, in the rail wrapper's own
--(pre-Font-Size-zoom) units. The wrapper is anchored under the title bar
--at the rail's top inset and renders at the rail-mode Font Size zoom, so
--the budget is the layer height less that inset and a bottom breathing
--gap, divided back out of the zoom.
--
--Layer height is measured the way the rail measures it (the documents
--layer is ~1048 units tall, not 1080 -- see IconRailUIHeight in
--DocumentSystem). The inset mirrors IconRailTop() there; the constants
--are duplicated rather than shared because both are file locals.
local ROSTER_BOTTOM_GAP = 12
--the smallest the column will shrink to before it just overflows: past
--this the cards are unreadable and clipping is the better failure.
local ROSTER_MIN_SCALE = 0.4

--the encounter-pools strip (malice + hero tokens) sits ABOVE the roster in
--the same right-rail wrapper, so its height plus the gap below it comes
--off the roster's budget (see CreateEncounterPoolsPanel).
local POOLS_HEIGHT = 40
local POOLS_GAP = 8
--one pool's slot in the strip. Two pools make a strip exactly as wide as a
--hero card; a third (Intelligence) makes it half a card wider.
local POOL_CELL_WIDTH = CARD_WIDTH / 2

local function RosterHeightBudget()
    local layerHeight = 1048
    pcall(function()
        local h = GameHud.instance.documentsPanel.renderedHeight
        if type(h) == "number" and h > 100 then
            layerHeight = h
        end
    end)

    local zoom = 1
    pcall(function()
        zoom = PanelDocument.WindowUIScale() or 1
    end)
    if type(zoom) ~= "number" or zoom <= 0 then
        zoom = 1
    end

    --IconRailTop(): max(64, (ICON_RAIL_BUTTON + RAIL_STOP_GAP) * zoom + RAIL_STOP_GAP)
    local topInset = (40 + 12) * zoom + 12
    if topInset < 64 then
        topInset = 64
    end

    local budget = (layerHeight - topInset - POOLS_HEIGHT - POOLS_GAP - ROSTER_BOTTOM_GAP) / zoom
    if budget < 100 then
        budget = 100
    end
    return budget
end

--Built fresh by the custom-interface rail host each time the rails build.
--Rebuilds its cards when party membership changes; individual card stats
--refresh on a 1s think plus the /characters monitor for prompt updates.
--With a full seven-hero roster the column is taller than the screen, so
--it shrinks itself to fit (see FitToScreen).
local function CreateHeroRosterPanel()
    local m_signature = nil
    --the column's unscaled height, accumulated as the cards are built.
    local m_contentHeight = 0
    local m_appliedScale = nil
    local m_fittedWhenAttached = false

    --Shrink the whole column, anchored to its top-RIGHT corner (the side
    --it hangs from), until it fits the screen. uiscale is a render-time
    --zoom around the pivot -- the same recipe the rail roots use for the
    --Font Size zoom -- so the layout inside the cards is untouched.
    --NOTE: selfStyle.uiscale is write-only; never read it back.
    local function FitToScreen(element)
        local scale = 1
        if m_contentHeight > 0 then
            local budget = RosterHeightBudget()
            if m_contentHeight > budget then
                scale = budget / m_contentHeight
                if scale < ROSTER_MIN_SCALE then
                    scale = ROSTER_MIN_SCALE
                end
            end
        end
        if scale == m_appliedScale then
            return
        end
        m_appliedScale = scale
        element.selfStyle.pivot = {x = 1, y = 1}
        element.selfStyle.uiscale = scale
    end

    local function Refresh(element)
        --Collapsed for the duration of a montage beat (the rail below
        --owns the class): nothing to rebuild, and dropping the signature
        --makes the column rebuild from scratch when it comes back.
        if element:HasClass("collapsed") then
            m_signature = nil
            return
        end

        local heroes = CollectHeroes()
        local sig = RosterSignature(heroes)
        if sig ~= m_signature then
            m_signature = sig
            local cards = {}
            local seenOther = false
            local height = 0
            for _, entry in ipairs(heroes) do
                local card = CreateHeroCard(entry)
                if entry.mine then
                    card.selfStyle.vmargin = 2
                    height = height + CARD_HEIGHT + 4
                else
                    --a wider gap separates the local player's group from
                    --everyone else's heroes.
                    if not seenOther then
                        card.selfStyle.tmargin = 16
                        card.selfStyle.bmargin = 3
                        seenOther = true
                        height = height + CARD_HEIGHT + 19
                    else
                        card.selfStyle.vmargin = 3
                        height = height + CARD_HEIGHT + 6
                    end
                end
                cards[#cards+1] = card
                --monsters that joined this hero in the montage ride under
                --its card as half-size cards.
                local allies = AlliesOf(entry.charid)
                if #allies > 0 then
                    local minis = {}
                    for _, allyId in ipairs(allies) do
                        minis[#minis+1] = CreateAllyCard(allyId)
                    end
                    cards[#cards+1] = gui.Panel{
                        width = CARD_WIDTH,
                        height = "auto",
                        flow = "horizontal",
                        wrap = true,
                        halign = "right",
                        bmargin = 3,
                        children = minis,
                    }
                    height = height + (ALLY_CARD_HEIGHT + 3) * math.ceil(#allies / 2)
                end
            end
            m_contentHeight = height
            element.children = cards
        end
        --cheap enough to re-check every tick: the budget also moves when
        --the window is resized or the Font Size zoom changes, neither of
        --which touches the roster signature.
        FitToScreen(element)
        element:FireEventTree("refreshCard")
    end

    return gui.Panel{
        id = "eotwHeroRoster",
        width = "auto",
        height = "auto",
        flow = "vertical",
        halign = "right",
        valign = "top",

        styles = ThemeEngine.MergeTokens(g_heroCardRules),

        create = function(element)
            Refresh(element)
        end,

        --the rail wrapper's own 0.5s cadence. Its first tick is the first
        --moment the column is certainly attached to the documents layer,
        --which is when a pivot write actually sticks (the same reason the
        --rail roots fire setRailScale after AddChild), so the fit is
        --forced once more there.
        refreshRail = function(element)
            if not m_fittedWhenAttached then
                m_fittedWhenAttached = true
                m_appliedScale = nil
            end
            FitToScreen(element)
        end,

        --any character change (stamina, conditions, new heroes) lands
        --here; the think below is the fallback for combat-scoped resource
        --changes that do not touch /characters.
        monitorGame = "/characters",
        refreshGame = function(element)
            Refresh(element)
        end,

        thinkTime = 1,
        think = function(element)
            if mod.unloaded then
                element:DestroySelf()
                return
            end
            Refresh(element)
        end,
    }
end

--- Encounter pools: malice + hero tokens -------------------------------------

--A strip above the roster showing the two encounter-wide pools everyone
--cares about and which no card can carry: the monsters' Malice and the
--party's shared Hero Tokens. Read-only for everyone (strict rules: malice
--is spent by the Monster AI, hero tokens through the game's own flows);
--hovering a cell shows the pool's change history. Both pools live in the
--shared global-resource document, so that document is monitored for
--prompt updates; the 1s think covers the combat-state gating (malice
--reads as 0 outside combat without the document changing).
local function PoolValue(kind)
    local value = 0
    pcall(function()
        if kind == "malice" then
            value = CharacterResource.GetMalice() or 0
        elseif kind == "intelligence" then
            value = EncounterMontage.GetIntelligence()
        else
            value = CharacterResource.GetGlobalResource(CharacterResource.heroTokenId) or 0
        end
    end)
    return value
end

local function PoolHistory(kind)
    local history = {}
    pcall(function()
        if kind == "intelligence" then
            history = EncounterMontage.GetIntelligenceHistory()
            return
        end
        local id = cond(kind == "malice", CharacterResource.maliceResourceId, CharacterResource.heroTokenId)
        history = CharacterResource.GetGlobalResourceHistory(id) or {}
    end)
    return history
end

--Intelligence is an optional feature: only a week whose script asked for it
--("Unlock: Intelligence") has a pool, and until it does the strip carries
--the two pools it always has.
local function IntelligenceUnlocked()
    local on = false
    pcall(function() on = EncounterMontage.FeatureUnlocked("intelligence") end)
    return on
end

--Which pool (if any) the stage is explaining right now. While a narrative
--section's "Unlock: <Feature>" callout is up, that pool's cell blinks a white
--rectangle so the party can see WHICH number the explanation is about.
local function AnnouncedFeature()
    local feature = nil
    pcall(function()
        local narrative = rawget(_G, "EncounterNarrative")
        if narrative ~= nil and narrative.ActiveAnnounce ~= nil then
            local announce = narrative.ActiveAnnounce()
            feature = announce ~= nil and announce.feature or nil
        end
    end)
    return feature
end

--the malice cost diamond the action bar / initiative bar use, shrunk to
--fit the strip: a rotated square with the split-shade gradient and the
--red inner diamond, no number inside (the count sits beside it).
local function CreateMaliceDiamond()
    return gui.Panel{
        classes = {"costDiamond", "malice"},
        styles = { Styles.ActionMenu },
        interactable = false,
        rotate = 135,
        width = 18,
        height = 18,
        halign = "center",
        valign = "center",
        hmargin = 0,
        bgcolor = "white",
        border = { x1 = 0, y1 = 2, x2 = 2, y2 = 0 },
        gradient = Styles.Ability.maliceDiamondGradient,

        gui.Panel{
            classes = {"costInnerDiamond", "malice"},
            interactable = false,
        },
    }
end

--What each pool IS, over and above the change history the cell already
--shows on hover: a player meeting the strip for the first time gets told
--what the number is for. The hero token copy is the character panel's own
--tooltip (MCDMCharacterPanel HERO_TOKEN_TOOLTIP), kept word for word so the
--two never drift apart.
local POOL_TITLE = {
    malice = "Malice",
    herotokens = "Hero Tokens",
    intelligence = "Intelligence",
}

local POOL_EXPLANATION = {
    malice = [==[**Malice**

This is a power used by Monsters to charge their most powerful abilities. Beware that it will be used against you in battle!]==],

    herotokens = [==[**Hero Tokens**
* You can spend a hero token to gain two surges.
* You can spend a hero token when you fail a saving throw to succeed instead.
* You can reroll the result of a test. You must use the new result.
* You can spend 2 hero tokens to regain Stamina equal to your Recovery value without spending a Recovery.]==],

    intelligence = [==[**Intelligence**

The amount of awareness you have of what you are up against. It can be used at the start of a fight to control how much you know about the encounter.]==],
}

local POOL_TOOLTIP_WIDTH = 420

--One tooltip card: the explanation, then the pool's change history under it
--when there is any. The history cannot simply go in gui.StatsHistoryTooltip's
--own `text` argument -- that is a bare auto-width label, so a paragraph handed
--to it runs off the screen in a single line -- and the panel it returns paints
--no background of its own here, so the card's chrome is this panel's.
local function CreatePoolTooltip(kind, description)
    --- @type Panel[]
    local children = {
        gui.Label{
            markdown = true,
            text = POOL_EXPLANATION[kind],
            width = "auto",
            height = "auto",
            maxWidth = POOL_TOOLTIP_WIDTH,
            fontSize = 20,
            color = "#ffffff",
        },
    }

    local entries = PoolHistory(kind)
    if entries ~= nil and #entries > 0 then
        children[#children+1] = gui.StatsHistoryTooltip{
            description = description,
            entries = entries,
        }
    end

    --the standard tooltip chrome (CreateTooltipPanel's own styling), so a
    --pool tooltip looks like every other tooltip in the game.
    return gui.Panel{
        bgimage = "panels/square.png",
        bgcolor = "#000000ff",
        border = 1,
        borderColor = "#000000ff",
        cornerRadius = 10,
        hpad = 20,
        vpad = 14,
        width = "auto",
        height = "auto",
        flow = "vertical",
        halign = "center",
        valign = "bottom",
        children = children,
    }
end

local function CreatePoolCell(kind)
    local icon
    if kind == "malice" then
        icon = CreateMaliceDiamond()
    elseif kind == "intelligence" then
        icon = gui.Panel{
            classes = {"eotwPoolIcon", "intelligence"},
            bgimage = "phosphor/brain.png",
            interactable = false,
        }
    else
        icon = gui.Panel{
            classes = {"eotwPoolIcon"},
            bgimage = "drawsteel/hero-token.png",
            interactable = false,
        }
    end

    local value = gui.Label{
        classes = {"eotwPoolValue"},
        text = "0",
        interactable = false,
        data = { value = nil },
        refreshPools = function(element)
            local n = PoolValue(kind)
            if n ~= element.data.value then
                element.data.value = n
                element.text = string.format("%d", n)
            end
        end,
    }

    local description = POOL_TITLE[kind]

    --The blink: a white rectangle over the cell, invisible until the stage is
    --explaining this pool. It floats, so it frames the cell without taking
    --part in its layout, and it fades in and out on the shared blink clock so
    --it pulses in step with the callout that sent the party looking.
    local highlight = gui.Panel{
        floating = true,
        interactable = false,
        width = "100%",
        height = "100%",
        halign = "center",
        valign = "center",
        bgimage = "panels/square.png",
        bgcolor = "#00000000",
        border = 2,
        borderColor = "#ffffffff",
        cornerRadius = 6,
        opacity = 0,
        --selfStyle is write-mostly here: reading back a key the style never
        --set raises ("Error indexing userdata"), so the last value we wrote
        --is kept in data and the think only writes when it changes.
        data = { blinking = false, opacity = 0 },
        blinkPool = function(element, feature)
            element.data.blinking = (feature == kind)
        end,
        thinkTime = 0.05,
        think = function(element)
            local alpha = 0
            if element.data.blinking then
                pcall(function() alpha = EncounterMontage.FeatureBlinkAlpha() end)
            end
            if alpha ~= element.data.opacity then
                element.data.opacity = alpha
                element.selfStyle.opacity = alpha
            end
        end,
    }

    return gui.Panel{
        classes = {"eotwPoolCell"},
        data = { kind = kind },
        --a panel with no bgimage is not hit-tested, so the cell needs a
        --(fully transparent) one of its own or the pointer sails past it to
        --the strip behind and neither the hover tint nor the tooltip fires.
        bgimage = "panels/square.png",
        bgcolor = "#00000000",
        --the diamond is rotated, so give it a square slot of its own to
        --spin in rather than letting the flow measure its unrotated box.
        gui.Panel{
            width = 26,
            height = 26,
            halign = "left",
            valign = "center",
            interactable = false,
            icon,
        },
        value,
        highlight,

        hover = function(element)
            element.tooltip = CreatePoolTooltip(kind, description)
        end,
    }
end

local function CreateEncounterPoolsPanel()
    local cells = {
        CreatePoolCell("malice"),
        CreatePoolCell("herotokens"),
        CreatePoolCell("intelligence"),
    }
    --the strip grows a cell wide when the week has an Intelligence pool, so
    --three pools are never squeezed into two pools' worth of strip.
    local m_cellCount = nil
    local strip

    local m_announced = nil

    local function RefreshLayout()
        local intelligence = IntelligenceUnlocked()
        cells[3]:SetClass("collapsed", not intelligence)
        --the blink follows whatever the stage is explaining; nil turns every
        --cell's rectangle off again.
        local announced = AnnouncedFeature()
        if announced ~= m_announced then
            m_announced = announced
            strip:FireEventTree("blinkPool", announced)
        end
        local count = cond(intelligence, 3, 2)
        if count ~= m_cellCount then
            m_cellCount = count
            strip.selfStyle.width = POOL_CELL_WIDTH * count
            for _, cell in ipairs(cells) do
                cell.selfStyle.width = string.format("%.4f%%", 100 / count)
            end
        end
    end

    strip = gui.Panel{
        id = "eotwEncounterPools",
        classes = {"eotwPoolsStrip"},
        --a plain panel paints no background without a bgimage.
        bgimage = "panels/square.png",
        width = CARD_WIDTH,
        height = POOLS_HEIGHT,
        flow = "horizontal",
        halign = "right",
        valign = "top",
        bmargin = POOLS_GAP,

        styles = ThemeEngine.MergeTokens{
            {
                selectors = {"eotwPoolsStrip"},
                bgcolor = "#000000c0",
                border = 1,
                borderColor = "#000000cc",
                cornerRadius = 8,
            },
            {
                selectors = {"eotwPoolCell"},
                width = "50%",
                height = "100%",
                --padding inside the 50%, not on top of it (two cells must
                --fit the strip exactly).
                borderBox = true,
                flow = "horizontal",
                halign = "left",
                valign = "center",
                hpad = 8,
                transitionTime = 0.15,
            },
            {
                selectors = {"eotwPoolCell", "hover"},
                brightness = 1.3,
            },
            {
                selectors = {"eotwPoolIcon"},
                width = 20,
                height = 20,
                halign = "center",
                valign = "center",
                bgcolor = "white",
            },
            {
                selectors = {"eotwPoolValue"},
                fontSize = 16,
                bold = true,
                color = "#ffffff",
                width = "auto",
                height = "auto",
                halign = "left",
                valign = "center",
                lmargin = 4,
            },
        },

        children = cells,

        create = function(element)
            RefreshLayout()
            element:FireEventTree("refreshPools")
        end,

        monitorGame = CharacterResource.GlobalResourcePath(),
        refreshGame = function(element)
            RefreshLayout()
            element:FireEventTree("refreshPools")
        end,

        --Four times a second, not once: this panel monitors the global
        --RESOURCE document, so nothing here fires when the script document
        --changes -- and Intelligence, the feature gate and the unlock blink
        --all live there. A tick is a handful of table reads.
        thinkTime = 0.25,
        think = function(element)
            if mod.unloaded then
                element:DestroySelf()
                return
            end
            RefreshLayout()
            element:FireEventTree("refreshPools")
        end,
    }

    return strip
end

--The whole right-rail widget: the pools strip above the hero roster. Both
--pack against the right edge; the roster's own fit-to-screen shrink
--pivots on its top-right corner so the strip above it is untouched.
local function CreateRightRailPanel()
    local roster = CreateHeroRosterPanel()

    return gui.Panel{
        id = "eotwRightRail",
        width = "auto",
        height = "auto",
        flow = "vertical",
        halign = "right",
        valign = "top",
        CreateEncounterPoolsPanel(),
        roster,

        --The hero roster is combat-only (user direction 2026-09-18):
        --while a montage beat is on screen the stage draws its own hero
        --cards along the bottom, so the side column would just duplicate
        --them. The pools strip above stays up either way -- it carries
        --malice and the party's hero tokens, which the stage does not
        --show. The toggle lives here, on a panel that is never collapsed
        --itself, so it keeps ticking while the roster is down.
        thinkTime = 0.5,
        think = function(element)
            local montagePresented = false
            pcall(function()
                montagePresented = EncounterMontage.IsPresented()
            end)
            roster:SetClass("collapsed", montagePresented)
        end,
    }
end

--- Kept rail buttons (bottom-left corner) -----------------------------------

local RAIL_BUTTON_SIZE = 40

--A rail-style button for one registered dockable panel: the standard
--iconRailButton look (the custom rail wrapper carries IconRailStyles), the
--panel's registered icon, its unread badge, the active underline, and the
--same open path the real rail button uses. Returns nil if the panel is
--not registered.
local function CreatePanelButton(panelName)
    local reg = nil
    pcall(function() reg = DockablePanel.GetRegistration(panelName) end)
    if reg == nil then
        return nil
    end
    local panelKey = string.lower(panelName)

    --unread badge: a 1x1 anchor on the button's top-right corner the
    --badge centers on, refreshed on the wrapper's refreshRail cadence --
    --the same recipe as the real rail button's new-content marker.
    local badge = nil
    if reg.hasNewContent ~= nil then
        local m_shownCount = nil
        badge = gui.Panel{
            floating = true,
            halign = "left",
            valign = "top",
            x = RAIL_BUTTON_SIZE - 3,
            y = 2,
            width = 1,
            height = 1,
            flow = "none",
            interactable = false,
            refreshRail = function(element)
                local shown = false
                pcall(function() shown = PanelDocument.IsPanelActive(panelKey) end)
                if shown and reg.markContentSeen ~= nil then
                    pcall(reg.markContentSeen)
                end
                local count = nil
                local hasNew = false
                pcall(function() hasNew = reg.hasNewContent() end)
                if (not shown) and hasNew then
                    count = 1
                    if reg.newContentCount ~= nil then
                        pcall(function() count = reg.newContentCount() or 1 end)
                    end
                    if count < 1 then
                        count = 1
                    end
                end
                if count == m_shownCount then
                    return
                end
                m_shownCount = count
                if count == nil then
                    element.children = {}
                else
                    element.children = {
                        gui.NewContentAlert{
                            count = count,
                            size = 16,
                            halign = "center",
                            valign = "center",
                            x = 0,
                            y = 0,
                            interactable = false,
                        },
                    }
                end
            end,
        }
    end

    return gui.Panel{
        classes = {"iconRailButton"},
        width = RAIL_BUTTON_SIZE,
        height = RAIL_BUTTON_SIZE,
        vmargin = 4,
        bgimage = "panels/square.png",
        blurBackground = true,
        swallowPress = true,

        --the rail-button identity shared chrome looks for. No slot: a
        --provider widget is not on the rail's slot grid. The chat speech
        --bubble finds its anchor this way (DocumentSystem's
        --FindChatRailButton), so a message arriving while chat is closed
        --bubbles off THIS button during the takeover, montage included.
        data = { key = panelKey },

        press = function(element)
            audio.FireSoundEvent("Mouse.Click")
            DockablePanel.LaunchPanelByName(panelName, "toggle")
        end,

        hover = function(element)
            gui.Tooltip(panelName)(element)
        end,

        --lit state while the panel's window is up (the underline below
        --reveals on the "active" class, and the icon brightens).
        refreshRail = function(element)
            local shown = false
            pcall(function() shown = PanelDocument.IsPanelShown(panelKey) end)
            element:SetClass("active", shown)
        end,

        gui.Panel{
            classes = {"iconRailIcon"},
            bgimage = reg.icon,
            width = 20,
            height = 20,
            halign = "center",
            valign = "center",
            interactable = false,
        },

        gui.Panel{
            classes = {"iconRailActiveMark"},
            bgimage = true,
            width = 16,
            height = 2,
            halign = "center",
            valign = "bottom",
            y = -3,
            interactable = false,
        },

        badge,
    }
end

--The bottom-left corner strip: the Journal, Chat and Action Log buttons
--survive the takeover (user direction 2026-08-28 for chat/log,
--2026-08-30 for the journal) so players keep the encounter's briefing
--documents, chat, and the roll history. Journal sits ABOVE the other two
--(vertical flow, so first in the list is the topmost button).
local function CreateCornerButtonsPanel()
    local buttons = {}
    for _, name in ipairs({"Journal", "Chat", "Action Log"}) do
        buttons[#buttons+1] = CreatePanelButton(name)
    end
    if #buttons == 0 then
        return nil
    end
    return gui.Panel{
        id = "eotwCornerButtons",
        width = "auto",
        height = "auto",
        flow = "vertical",
        halign = "left",
        children = buttons,
    }
end

--- Exports -------------------------------------------------------------------

--Shared with the montage stage (EncounterMontageStage.lua), which shows the
--same hero cards along the bottom of the screen.
EncounterOfTheWeekHud = rawget(_G, "EncounterOfTheWeekHud") or {}
EncounterOfTheWeekHud.CreateHeroCard = CreateHeroCard
EncounterOfTheWeekHud.CreateAllyCard = CreateAllyCard
EncounterOfTheWeekHud.CreateStaminaBar = CreateStaminaBar
EncounterOfTheWeekHud.CreateMaliceDiamond = CreateMaliceDiamond
EncounterOfTheWeekHud.CreateEncounterPoolsPanel = CreateEncounterPoolsPanel
EncounterOfTheWeekHud.CollectHeroes = CollectHeroes
EncounterOfTheWeekHud.HeroCardRules = function()
    return g_heroCardRules
end

--- The custom-interface registration ----------------------------------------

--pcall: an older core codex without the hook just shows the normal hud.
pcall(function()
    GameHud.RegisterCustomInterface{
        id = "eotw",

        active = function()
            if dmhub.GetSettingValue("eotw:forcecustomui") == true then
                return true
            end
            local eotw = rawget(_G, "EncounterOfTheWeekGame")
            if eotw == nil or not eotw.IsEotwGame() then
                return false
            end
            --the Director-UI escape hatch (or a --director debug window)
            --restores the whole normal interface for debugging/manual
            --recovery.
            if eotw.ShowDirectorUI ~= nil then
                return not eotw.ShowDirectorUI()
            end
            return dmhub.GetSettingValue("eotw:showdirectorui") ~= true
        end,

        suppressRails = true,

        --the pools strip + roster hang off the RIGHT edge; the kept rail
        --buttons stay in the bottom-LEFT corner where the real rail's are.
        railPanel = function(side)
            if side == "right" then
                return CreateRightRailPanel()
            end
            return nil
        end,

        railBottomPanel = function(side)
            if side == "left" then
                return CreateCornerButtonsPanel()
            end
            return nil
        end,

        suppressTitlebarMenu = { ["Panels"] = true },

        suppressPanel = { ["Compendium"] = true },

        suppressSearchBucket = { ["compendium"] = true },

        --every hero's panel may be opened by anyone, read-only -- your own
        --included (strict rules: state changes go through the action bar
        --and the game's own flows, never sheet edits). Non-hero tokens
        --keep the normal rules.
        characterPanelAccess = function(token)
            local playerControlled = false
            pcall(function() playerControlled = token.playerControlled end)
            if playerControlled then
                return "view"
            end
            return nil
        end,
    }
end)
