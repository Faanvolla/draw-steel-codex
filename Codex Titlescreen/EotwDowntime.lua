local mod = dmhub.GetModLoading()

--Encounter of the Week Downtime: what heroes do in Blackbottom between
--encounters. Design: EncounterOfTheWeek/EncounterOfTheWeek.md, "Downtime".
--
--  * Heroes come home from the Town Gate with their wounds (lost Stamina,
--    spent Recoveries; see EotwRoster.SetWounds).
--  * At the Blue Fish Inn a player takes a Respite: every hero at home rests,
--    turning Victories into XP and into Downtime Activities (one each), and
--    regaining all Stamina and Recoveries. A hero who does not want to rest
--    can Catch Their Breath instead: spend a Recovery to regain Stamina.
--  * Downtime Activities are spent on Projects. A project roll is 2d10 + a
--    characteristic (+2 for a listed skill) with no tiers: the total is the
--    Project Points it adds. A natural 19 or 20 is a breakthrough: one more
--    roll, free. Expand the Guild (60 points, +30 each time, five times)
--    opens a hero slot.
--
--The City (cloudflare-game-server src/city-core.ts) holds each hero's
--Downtime count and every project's progress, so spending a Downtime
--Activity and adding its points is one atomic step there. The hero's own
--record (XP, Victories, Stamina) changes here and is pushed like any edit.

EotwDowntime = {}

local TEXT = "#efe4cc"
local DIM = "#c9bfa9"
local GOLD = "#d9b56a"
local AMBER = "#ffd38a"
local RED = "#ff8888"

--A natural roll of at least this is a breakthrough (Draw Steel: 19-20).
EotwDowntime.BREAKTHROUGH_NATURAL = 19

--Bumped whenever a project or a respite changes; UIs poll it.
EotwDowntime.revision = 0

--Dev (/eotwdowntime breakthrough): the next project roll counts as a natural 20.
EotwDowntime.forceBreakthrough = false

local function Bump()
    EotwDowntime.revision = EotwDowntime.revision + 1
end

--- projects ---------------------------------------------------------------

--What the town shows of each project the City knows (CITY_PROJECTS in
--city-core.ts holds the goals and what a completion does).
EotwDowntime.PROJECTS = {
    ["expand-guild"] = {
        id = "expand-guild",
        scope = "player",
        title = "Expand the Guild",
        icon = "phosphor/shield-star-fill.png",
        location = "guild",
        characteristics = { "rea", "prs" },
        skills = { "Brag", "Empathize", "Flirt", "Lead", "Perform", "Persuade" },
        --what completing it gives, shown under its cost.
        benefit = "+1 Hero Slot",
        --the line under the title, from the project's state (list-projects).
        blurb = function(state)
            if state ~= nil and state.maxed then
                return "The guild hall is as grand as it will get."
            end
            return "Recruit new Heroes into the Guild."
        end,
    },
}

--projectid -> the project's state as the City last reported it:
--{projectid, completions, maxCompletions, points, goal, maxed, recent, open}.
local m_projects = {}
local m_listing = false

--A project's last known state, or nil before the first list.
function EotwDowntime.GetProject(projectid)
    return m_projects[projectid]
end

--Ask the City for this account's projects (player scope) and cache them.
function EotwDowntime.RefreshProjects()
    local conn = EotwRoster.Connection()
    if conn == nil or not conn.connected or m_listing then
        return
    end
    m_listing = true
    conn:Request{
        action = "list-projects",
        args = { scope = "player" },
        success = function(result)
            m_listing = false
            for _, project in ipairs(result.projects or {}) do
                m_projects[project.projectid] = project
            end
            Bump()
        end,
        error = function(message)
            m_listing = false
            printf("EotW town: could not list projects: %s", tostring(message))
        end,
    }
end

--The ids of the characteristics a project allows, with display names, in
--the game system's own order: { {id, name}, ... }.
local function ProjectCharacteristics(project)
    local result = {}
    for _, attrid in ipairs(project.characteristics) do
        local info = creature.attributesInfo[attrid]
        result[#result+1] = { id = attrid, name = info ~= nil and info.description or attrid }
    end
    return result
end

--The hero's modifier for a characteristic (0 if it cannot be read).
local function CharacteristicValue(tok, attrid)
    local value = 0
    pcall(function() value = tok.properties:GetAttribute(attrid):Modifier() end)
    return value
end

--The project's listed skills this hero is trained in, by name.
local function TrainedProjectSkills(tok, project)
    local trained = {}
    pcall(function()
        for _, skill in ipairs(Skill.SkillsInfo) do
            for _, name in ipairs(project.skills) do
                if skill.name == name and tok.properties:ProficientInSkill(skill) then
                    trained[#trained+1] = name
                end
            end
        end
    end)
    return trained
end

--- respite and catching breath ----------------------------------------------

--A respite in progress, kept until every hero is pushed and the City has
--credited the Downtime, so a crash or a dropped connection resumes it:
--{ [userid] = { respiteid, grants = {heroid = amount}, pushed = {heroid = true}, stage } }.
setting{
    id = "eotw:pendingRespite",
    default = "",
    storage = "preference",
}

--A project roll whose dice have landed but the City has not yet recorded:
--{ [userid] = { rollid, projectid, heroid, natural, total, characteristic, skill, breakthroughOf } }.
setting{
    id = "eotw:pendingProjectRoll",
    default = "",
    storage = "preference",
}

local function LoadMine(settingid)
    local all = {}
    local text = dmhub.GetSettingValue(settingid)
    if type(text) == "string" and text ~= "" then
        --FromJson answers {success, result}, not the decoded value.
        local parsed = dmhub.FromJson(text)
        if type(parsed) == "table" and parsed.success and type(parsed.result) == "table" then
            all = parsed.result
        end
    end
    return all, all[dmhub.loginUserid]
end

local function SaveMine(settingid, value)
    local all = LoadMine(settingid)
    all[dmhub.loginUserid] = value
    dmhub.SetSettingValue(settingid, dmhub.ToJson(all))
end

--A hero's Victories (0 if unreadable).
local function Victories(tok)
    local v = 0
    pcall(function() v = tok.properties:GetVictories() or 0 end)
    return math.max(0, math.floor(v))
end

--Stamina and Recoveries for display: cur, max, recoveries left, recovery max.
local function Vitals(tok)
    local cur, max, left, rmax = 0, 0, 0, 0
    pcall(function()
        local props = tok.properties
        cur = props:CurrentHitpoints()
        max = props:MaxHitpoints()
        local id = CharacterResource.recoveryResourceId
        rmax = props:GetResources()[id] or 0
        left = math.max(0, rmax - (props:GetResourceUsage(id, "long") or 0))
    end)
    return cur, max, left, rmax
end

--Every living roster hero with what a respite would do for them:
--{ {hero, tok, away, victories, canRest, reason}, ... } in roster order.
function EotwDowntime.RestCandidates()
    local result = {}
    local away = EotwRoster.AwayHeroes()
    for _, hero in ipairs(EotwRoster.GetHeroes() or {}) do
        local tok = dmhub.GetCharacterById(hero.heroid)
        local entry = { hero = hero, tok = tok, away = away[hero.heroid], victories = 0, canRest = false }
        if entry.away ~= nil then
            entry.reason = string.format("Away: %s", entry.away)
        elseif tok == nil or not EotwRoster.IsInStep(hero.heroid) then
            entry.reason = "Loading..."
        else
            entry.victories = Victories(tok)
            entry.canRest = true
        end
        result[#result+1] = entry
    end
    return result
end

local m_respiteBusy = false

--Is a respite being written right now?
function EotwDowntime.RespiteBusy()
    return m_respiteBusy
end

--Rest one hero's working copy for this respite, unless it already has.
local function RestHero(tok, respiteid, victories)
    local done = false
    pcall(function()
        local stamps = rawget(tok.properties, "eotwRespites")
        done = type(stamps) == "table" and stamps[respiteid] ~= nil
    end)
    if done then
        return
    end
    tok:ModifyProperties{
        description = "Respite at the Blue Fish Inn",
        undoable = false,
        execute = function()
            local props = tok.properties
            --heals, turns Victories into XP and refreshes Recoveries.
            props:Rest("long")
            local stamps = {}
            local old = rawget(props, "eotwRespites")
            if type(old) == "table" then
                for k, v in pairs(old) do
                    stamps[k] = v
                end
            end
            stamps[respiteid] = victories
            props.eotwRespites = stamps
        end,
    }
end

--Carry a pending respite forward: rest and push each hero not yet pushed,
--then credit the Downtime with the City. Safe to call again at any stage.
local function ContinueRespite(onDone)
    local _, pending = LoadMine("eotw:pendingRespite")
    if type(pending) ~= "table" or type(pending.respiteid) ~= "string" then
        m_respiteBusy = false
        if onDone ~= nil then
            onDone(true)
        end
        return
    end
    m_respiteBusy = true
    local conn = EotwRoster.Connection()
    if conn == nil or not conn.connected then
        m_respiteBusy = false
        if onDone ~= nil then
            onDone(false, "not connected")
        end
        return
    end
    pending.pushed = pending.pushed or {}

    --first every hero's record, one push at a time.
    for heroid, amount in pairs(pending.grants or {}) do
        if not pending.pushed[heroid] then
            if EotwRoster.FindHero(heroid) == nil then
                --dismissed or fallen meanwhile: nothing to rest or credit.
                pending.grants[heroid] = nil
                SaveMine("eotw:pendingRespite", pending)
            elseif not EotwRoster.IsInStep(heroid) then
                --an import is in flight; try again shortly.
                dmhub.Schedule(1, function()
                    if not mod.unloaded then
                        ContinueRespite(onDone)
                    end
                end)
                return
            else
                local tok = dmhub.GetCharacterById(heroid)
                RestHero(tok, pending.respiteid, amount)
                --let the property write land before the export, as JoinRoster does.
                dmhub.Schedule(0.3, function()
                    if mod.unloaded then
                        return
                    end
                    EotwRoster.PushHero(heroid, function(ok, message)
                        if not ok then
                            --a stale copy reloads from the city; the next
                            --pass rests it again (it carries no stamp).
                            m_respiteBusy = false
                            if onDone ~= nil then
                                onDone(false, message)
                            end
                            return
                        end
                        pending.pushed[heroid] = true
                        SaveMine("eotw:pendingRespite", pending)
                        ContinueRespite(onDone)
                    end)
                end)
                return
            end
        end
    end

    --then the Downtime, credited once per hero for this respite.
    local grants = {}
    for heroid, amount in pairs(pending.grants or {}) do
        grants[#grants+1] = { heroid = heroid, amount = amount }
    end
    if #grants == 0 then
        SaveMine("eotw:pendingRespite", nil)
        m_respiteBusy = false
        Bump()
        if onDone ~= nil then
            onDone(true)
        end
        return
    end
    conn:Request{
        action = "grant-downtime",
        args = { grantid = pending.respiteid, grants = grants },
        success = function(result)
            SaveMine("eotw:pendingRespite", nil)
            m_respiteBusy = false
            for heroid, downtime in pairs(result.downtime or {}) do
                EotwRoster.SetListedDowntime(heroid, downtime)
            end
            Bump()
            EotwRoster.Refresh()
            if onDone ~= nil then
                onDone(true)
            end
        end,
        error = function(message)
            m_respiteBusy = false
            printf("EotW town: the Downtime from the respite was not credited yet: %s", tostring(message))
            if onDone ~= nil then
                onDone(false, message)
            end
        end,
    }
end

--Take a respite: every hero at home (not away in a party) rests at once.
--onDone(ok, message) when it has all reached the City.
function EotwDowntime.TakeRespite(onDone)
    if m_respiteBusy then
        return
    end
    local _, pending = LoadMine("eotw:pendingRespite")
    if type(pending) == "table" then
        --finish the one already under way first.
        ContinueRespite(onDone)
        return
    end
    local grants = {}
    local count = 0
    for _, entry in ipairs(EotwDowntime.RestCandidates()) do
        if entry.canRest then
            grants[entry.hero.heroid] = entry.victories
            count = count + 1
        end
    end
    if count == 0 then
        if onDone ~= nil then
            onDone(false, "None of your heroes are at home to rest.")
        end
        return
    end
    SaveMine("eotw:pendingRespite", {
        respiteid = dmhub.GenerateGuid(),
        grants = grants,
        pushed = {},
        stage = "new",
    })
    ContinueRespite(onDone)
end

--Can this hero catch their breath? Returns nil if so, else why not.
function EotwDowntime.CatchBreathBlocked(heroid)
    local tok = dmhub.GetCharacterById(heroid)
    if tok == nil or not EotwRoster.IsInStep(heroid) then
        return "Loading..."
    end
    if EotwRoster.AwayHeroes()[heroid] ~= nil then
        return "This hero is away in a party."
    end
    local cur, max, left = Vitals(tok)
    if cur >= max then
        return "Already at full Stamina."
    end
    if left <= 0 then
        return "No Recoveries left. Take a respite to regain them."
    end
    return nil
end

--Catch Your Breath in town: spend one Recovery to regain Stamina equal to
--the hero's recovery value, without resting (Victories stay unspent).
function EotwDowntime.CatchBreath(heroid, onDone)
    local tok = dmhub.GetCharacterById(heroid)
    if tok == nil or EotwDowntime.CatchBreathBlocked(heroid) ~= nil then
        return
    end
    tok:ModifyProperties{
        description = "Catch Your Breath",
        undoable = false,
        execute = function()
            local props = tok.properties
            props:Heal(props:RecoveryAmount(), "Use Recovery")
            props:ConsumeResource(CharacterResource.recoveryResourceId, "long", 1, "Caught their breath at the inn")
        end,
    }
    Bump()
    dmhub.Schedule(0.3, function()
        if mod.unloaded then
            return
        end
        EotwRoster.PushHero(heroid, function(ok, message)
            Bump()
            if onDone ~= nil then
                onDone(ok, message)
            end
        end)
    end)
end

--- project rolls ----------------------------------------------------------

--Send a rolled project roll to the City. The pending entry stays until the
--City answers, so a dropped connection sends it again later (the City
--ignores a rollid it has already recorded). onDone(ok, resultOrMessage).
local function SendProjectRoll(roll, onDone)
    local conn = EotwRoster.Connection()
    if conn == nil or not conn.connected then
        if onDone ~= nil then
            onDone(false, "Not connected to the town. Your roll is saved and will be recorded when you reconnect.")
        end
        return
    end
    conn:Request{
        action = "project-roll",
        args = {
            rollid = roll.rollid,
            projectid = roll.projectid,
            heroid = roll.heroid,
            natural = roll.natural,
            total = roll.total,
            characteristic = roll.characteristic,
            skill = roll.skill,
            breakthroughOf = roll.breakthroughOf,
        },
        success = function(result)
            SaveMine("eotw:pendingProjectRoll", nil)
            if type(result.project) == "table" then
                m_projects[result.project.projectid] = result.project
            end
            EotwRoster.SetListedDowntime(roll.heroid, result.downtime)
            EotwRoster.SetListedSlots(result.slots)
            Bump()
            if onDone ~= nil then
                onDone(true, result)
            end
        end,
        error = function(message)
            --the City refused it (no Downtime left, the project is done...):
            --it will never take this roll, so let it go.
            SaveMine("eotw:pendingProjectRoll", nil)
            Bump()
            if onDone ~= nil then
                onDone(false, message)
            end
        end,
    }
end

--Record a project roll left over from a dropped connection. Called when the
--town connects.
function EotwDowntime.ResumePending()
    local _, roll = LoadMine("eotw:pendingProjectRoll")
    if type(roll) == "table" and type(roll.rollid) == "string" and type(roll.natural) == "number" then
        SendProjectRoll(roll, function(ok, result)
            if ok then
                printf("EotW town: recorded a project roll left over from last time (+%s)", tostring(roll.total))
            end
        end)
    end
    local _, respite = LoadMine("eotw:pendingRespite")
    if type(respite) == "table" then
        ContinueRespite(nil)
    end
end

--The roll formula's bonus and a description of it, for a hero working on a
--project with a characteristic and (optionally) one of its skills.
function EotwDowntime.RollBonus(tok, attrid, skill)
    local value = CharacteristicValue(tok, attrid)
    local info = creature.attributesInfo[attrid]
    local parts = { "2d10", string.format("%+d %s", value, info ~= nil and info.description or attrid) }
    local bonus = value
    if skill ~= nil and skill ~= "" then
        bonus = bonus + 2
        parts[#parts+1] = string.format("+2 %s", skill)
    end
    return bonus, table.concat(parts, " ")
end

--Roll for a project and record it. args = {projectid, heroid, characteristic,
--skill, breakthroughOf?, begin = function(rollInfo, bonus) (the dice are
--thrown), rolled = function(natural, total), done = function(ok,
--resultOrMessage), previewPanel?, cancel?}. With previewPanel (a
--gui.DicePreview cage) the dice are only ARMED: they rest in the cage until
--the player clicks or throws them, and cancel() fires if a throw is too
--weak to roll. The dice are real 3D dice (dmhub.Roll works at the
--titlescreen); the City spends the Downtime only when it records the roll.
function EotwDowntime.Roll(args)
    local project = EotwDowntime.PROJECTS[args.projectid]
    local tok = dmhub.GetCharacterById(args.heroid)
    if project == nil or tok == nil then
        args.done(false, "That hero is not ready yet.")
        return
    end
    local bonus = EotwDowntime.RollBonus(tok, args.characteristic, args.skill)
    local roll = {
        rollid = dmhub.GenerateGuid(),
        projectid = args.projectid,
        heroid = args.heroid,
        characteristic = args.characteristic,
        skill = args.skill or "",
        breakthroughOf = args.breakthroughOf,
    }
    local title = cond(args.breakthroughOf ~= nil, "Breakthrough: ", "Project Roll: ") .. project.title
    dmhub.Roll{
        roll = string.format("2d10%+d", bonus),
        description = title,
        preview = args.previewPanel ~= nil,
        previewPanel = args.previewPanel,
        cancel = function()
            if not mod.unloaded and args.cancel ~= nil then
                args.cancel()
            end
        end,
        --the dice are thrown: rollInfo.rolls carries each die's guid, whose
        --chat.DiceEvents report the face it shows as it tumbles.
        begin = function(rollInfo)
            if not mod.unloaded and args.begin ~= nil then
                args.begin(rollInfo, bonus)
            end
        end,
        complete = function(rollInfo)
            if mod.unloaded then
                return
            end
            roll.natural = math.floor(tonumber(rollInfo.naturalRoll) or 0)
            roll.total = math.floor(tonumber(rollInfo.total) or 0)
            --dev: /eotwdowntime breakthrough makes this roll a natural 20.
            if EotwDowntime.forceBreakthrough then
                EotwDowntime.forceBreakthrough = false
                roll.natural = 20
                roll.total = 20 + bonus
                printf("EotW town (dev): this project roll counts as a natural 20 (the dice said %d)", math.floor(tonumber(rollInfo.naturalRoll) or 0))
            end
            --kept until the City has it: a crash now must not lose the roll.
            SaveMine("eotw:pendingProjectRoll", roll)
            if args.rolled ~= nil then
                args.rolled(roll.natural, roll.total)
            end
            SendProjectRoll(roll, args.done)
        end,
    }
end

--The open breakthrough (free follow-up roll) a hero has on a project, or nil.
function EotwDowntime.OpenBreakthrough(projectid, heroid)
    local state = m_projects[projectid]
    for _, r in ipairs(state ~= nil and state.open or {}) do
        if r.heroid == heroid then
            return r
        end
    end
    return nil
end

--- shared UI bits -----------------------------------------------------------

--A dramatic banner for the town: the game's own swords-and-band banner
--(DramaticBanner), mounted once on the town screen, since the titlescreen
--has no game HUD to carry it. Returns false if it could not be shown.
local m_bannerPanel = nil
local function ShowBanner(host, text, subtitle)
    local ok = pcall(function()
        if m_bannerPanel == nil or not m_bannerPanel.valid then
            m_bannerPanel = gui.Panel{
                floating = true,
                width = "100%",
                height = "100%",
                interactable = false,
                DramaticBanner.Create(),
            }
            host:AddChild(m_bannerPanel)
        else
            --on top of whatever opened since.
            m_bannerPanel:SetAsLastSibling()
        end
        DramaticBanner.Show{ text = text, subtitle = subtitle }
    end)
    return ok
end

--How long a gain takes to ease into place on a project bar, in seconds.
local BAR_ANIMATION_SECONDS = 0.9

--A project's progress bar: a gold fill for the points so far and an amber
--"ghost" segment past it previewing a roll's points while its dice tumble.
--Returns the bar panel and a controller:
--  ctl.Set(points, goal)        show this at once (stops any animation)
--  ctl.Update(points, goal)     ease up to a higher value of the same goal,
--                               else Set
--  ctl.Preview(points)          the ghost: this many points past the fill
--                               (nil hides it)
--  ctl.WatchDice(rolls, bonus)  preview the running total of these tumbling
--                               dice (rollInfo.rolls) plus bonus
--  ctl.StopDice()               stop watching the dice
--  ctl.AnimateTo(points, onDone) ease the fill (and its count) up to points
--  ctl.Busy()                   is an animation running?
local function ProgressBar(height)
    local fill = gui.Panel{
        floating = true,
        halign = "left",
        width = "0%",
        height = "100%",
        bgimage = "panels/square.png",
        bgcolor = GOLD,
        cornerRadius = 4,
        interactable = false,
    }
    --the preview of a roll's points: a layer BEHIND the fill reaching to
    --fill + preview, so the part past the fill shows, and the fill eats into
    --it as the gain animates in. Width 0 while there is no preview.
    local ghost = gui.Panel{
        floating = true,
        halign = "left",
        width = "0%",
        height = "100%",
        bgimage = "panels/square.png",
        bgcolor = "#ffd38a",
        opacity = 0.55,
        cornerRadius = 4,
        interactable = false,
    }
    local label = gui.Label{
        text = "",
        fontSize = 15,
        bold = true,
        color = TEXT,
        width = "auto",
        height = "auto",
        halign = "center",
        valign = "center",
        floating = true,
        textWrap = false,
        interactable = false,
    }

    --shown = the points the fill shows now (fractional while animating);
    --preview = the ghost's points; anim = {from, to, start, onDone}.
    local s = { shown = 0, goal = 0, preview = nil, anim = nil, dice = nil, faces = {}, bonus = 0, pulse = 0 }

    local function Paint()
        local goal = s.goal
        local shown = math.min(s.shown, goal)
        local fraction = 0
        if goal > 0 then
            fraction = math.max(0, math.min(1, shown / goal))
        end
        fill.selfStyle.width = string.format("%.2f%%", fraction * 100)
        --the ghost reaches from the bar's start to where the preview would
        --land; the fill drawn over it hides all but the gain.
        local ghostTo = 0
        if s.preview ~= nil and goal > 0 then
            local previewTo = (s.anim ~= nil and s.anim.from or s.shown) + s.preview
            ghostTo = math.max(0, math.min(1, previewTo / goal))
        end
        ghost.selfStyle.width = string.format("%.2f%%", ghostTo * 100)
        local count = math.floor(shown + 0.5)
        if s.preview ~= nil and s.anim == nil then
            --bold, in the label's own color: amber text vanished over the gold.
            label.text = string.format("%d <b>+ %d</b> / %d", count, math.max(0, s.preview), goal)
        else
            label.text = string.format("%d / %d", count, goal)
        end
        --dark text once the gold reaches the middle, where the label sits.
        label.selfStyle.color = cond(fraction > 0.5, "#1b140c", TEXT)
    end

    local bar
    bar = gui.Panel{
        width = "100%",
        height = height,
        bgimage = "panels/square.png",
        bgcolor = "#2c261c",
        cornerRadius = 4,
        borderWidth = 1,
        borderColor = "#5a4b33",
        flow = "none",
        styles = {
            --a brief glow as a gain lands.
            { selectors = { "eotwBarFlash" }, brightness = 1, transitionTime = 0.4 },
            { selectors = { "eotwBarFlash", "flash" }, brightness = 1.8, transitionTime = 0.08 },
        },
        classes = { "eotwBarFlash" },
        thinkTime = 0.03,
        think = function(element)
            local now = dmhub.Time()
            if s.anim ~= nil then
                local t = math.min(1, (now - s.anim.start) / BAR_ANIMATION_SECONDS)
                --ease out: quick at first, settling into place.
                local eased = 1 - (1 - t) ^ 3
                s.shown = s.anim.from + (s.anim.to - s.anim.from) * eased
                if t >= 1 then
                    local onDone = s.anim.onDone
                    s.shown = s.anim.to
                    s.anim = nil
                    s.preview = nil
                    element:PulseClass("flash")
                    Paint()
                    if onDone ~= nil then
                        onDone()
                    end
                    return
                end
                Paint()
            elseif s.preview ~= nil then
                --the ghost breathes while the dice decide.
                s.pulse = s.pulse + 0.15
                ghost.selfStyle.opacity = 0.45 + 0.25 * math.sin(s.pulse)
            end
        end,
        --fired by chat.DiceEvents for each die as it tumbles: num is the face
        --it shows now. Once every die has shown a face, preview their sum.
        diceface = function(element, diceguid, num, timeRemaining)
            if s.dice == nil then
                return
            end
            s.faces[diceguid] = num
            local total = s.bonus
            for _, roll in ipairs(s.dice) do
                local face = s.faces[roll.guid]
                if face == nil then
                    return
                end
                total = total + face
            end
            s.preview = math.max(0, total)
            Paint()
        end,
        --behind to front: the preview, the fill, the count.
        ghost,
        fill,
        label,
    }

    local ctl = {}
    function ctl.Set(points, goal)
        s.anim = nil
        s.shown = points or 0
        s.goal = goal or 0
        Paint()
    end
    function ctl.Busy()
        return s.anim ~= nil
    end
    function ctl.Update(points, goal)
        if s.anim ~= nil then
            return
        end
        if goal == s.goal and points > s.shown then
            ctl.AnimateTo(points)
        elseif points ~= s.shown or goal ~= s.goal then
            ctl.Set(points, goal)
        end
    end
    function ctl.Preview(points)
        s.preview = points
        ghost.selfStyle.opacity = 0.55
        Paint()
    end
    function ctl.StopDice()
        if s.dice ~= nil and bar.valid then
            for _, roll in ipairs(s.dice) do
                pcall(function() chat.DiceEvents(roll.guid):Unlisten(bar) end)
            end
        end
        s.dice = nil
    end
    function ctl.WatchDice(rolls, bonus)
        ctl.StopDice()
        s.dice = {}
        s.faces = {}
        s.bonus = bonus or 0
        for _, roll in ipairs(rolls or {}) do
            if not roll.dropped then
                s.dice[#s.dice+1] = roll
                pcall(function() chat.DiceEvents(roll.guid):Listen(bar) end)
            end
        end
    end
    function ctl.AnimateTo(points, onDone)
        s.anim = { from = s.shown, to = points, start = dmhub.Time(), onDone = onDone }
    end
    return bar, ctl
end

--A two-click button: the first click asks, the second within 4s confirms.
local function ConfirmButton(text, confirmText, width, onConfirm)
    local confirming = false
    return gui.Button{
        text = text,
        fontSize = 20,
        width = width,
        height = 46,
        resetConfirm = function(element)
            confirming = false
            element.text = text
        end,
        click = function(element)
            if not confirming then
                confirming = true
                element.text = confirmText
                element:ScheduleEvent("resetConfirm", 4)
                return
            end
            confirming = false
            element.text = text
            onConfirm(element)
        end,
    }
end

local function Portrait(tok, width, height)
    local portrait = nil
    if tok ~= nil then
        pcall(function() portrait = tok.offTokenPortrait end)
    end
    if type(portrait) ~= "string" or portrait == "" then
        return gui.Panel{
            interactable = false,
            width = width,
            height = height,
            valign = "center",
            bgimage = "panels/square.png",
            bgcolor = "#ffffff10",
            cornerRadius = 6,
            gui.Panel{
                interactable = false,
                width = "60%",
                height = "100% width",
                halign = "center",
                valign = "center",
                bgimage = "phosphor/user-fill.png",
                bgcolor = "#ffffff2a",
            },
        }
    end
    local rect = nil
    pcall(function() rect = tok:GetPortraitRectForAspect(width / height, portrait) end)
    return gui.Panel{
        interactable = false,
        width = width,
        height = height,
        valign = "center",
        bgimage = portrait,
        bgcolor = "white",
        cornerRadius = 6,
        borderWidth = 1,
        borderColor = "#8c7a55",
        imageRect = rect,
    }
end

--A small amber hammer chip with a count, for Downtime Activities.
local function HammerChip(count)
    return gui.Panel{
        width = "auto",
        height = 22,
        flow = "horizontal",
        hpad = 6,
        borderBox = true,
        valign = "center",
        bgimage = "panels/square.png",
        bgcolor = "#3a2a10",
        cornerRadius = 6,
        borderWidth = 1,
        borderColor = "#e0a43a",
        interactable = false,
        gui.Panel{
            width = 14,
            height = 14,
            valign = "center",
            bgimage = "phosphor/hammer-fill.png",
            bgcolor = AMBER,
            interactable = false,
        },
        gui.Label{
            text = tostring(count),
            fontSize = 14,
            bold = true,
            color = AMBER,
            width = "auto",
            height = "auto",
            valign = "center",
            lmargin = 4,
            interactable = false,
        },
    }
end

--- the project roll dialog ----------------------------------------------------

--A choice among options (the roll dialog's characteristic): dark when idle,
--warmer on hover, gold-framed when chosen. The text never changes color.
local TOGGLE_STYLES = {
    { selectors = { "eotwToggle" }, bgcolor = "#1d1913", borderWidth = 1, borderColor = "#5a4b33" },
    { selectors = { "eotwToggle", "hover" }, bgcolor = "#2c2318", borderColor = "#8c7a55" },
    { selectors = { "eotwToggle", "selected" }, bgcolor = "#3a2e1a", borderWidth = 2, borderColor = GOLD },
    { selectors = { "eotwToggle", "selected", "hover" }, bgcolor = "#463720", borderWidth = 2, borderColor = GOLD },
}

--The heroes who could work on a project now: at home and loaded, in roster
--order. Each entry: {hero, tok, downtime, breakthrough (an open free roll)}.
local function ProjectWorkers(projectid)
    local result = {}
    local away = EotwRoster.AwayHeroes()
    for _, hero in ipairs(EotwRoster.GetHeroes() or {}) do
        local tok = dmhub.GetCharacterById(hero.heroid)
        if tok ~= nil and away[hero.heroid] == nil then
            result[#result+1] = {
                hero = hero,
                tok = tok,
                downtime = EotwRoster.GetDowntime(hero.heroid),
                breakthrough = EotwDowntime.OpenBreakthrough(projectid, hero.heroid),
            }
        end
    end
    return result
end

--The best characteristic for this hero on this project.
local function BestCharacteristic(tok, project)
    local best, bestValue = project.characteristics[1], nil
    for _, attrid in ipairs(project.characteristics) do
        local v = CharacteristicValue(tok, attrid)
        if bestValue == nil or v > bestValue then
            best, bestValue = attrid, v
        end
    end
    return best
end

--The project roll dialog: pick who works on it, with which characteristic
--and skill, then roll. Stays open so several Downtime Activities can be
--spent in a row; a breakthrough offers its free roll here.
function EotwDowntime.ShowRollDialog(host, projectid)
    local project = EotwDowntime.PROJECTS[projectid]
    if project == nil then
        return
    end

    --what the dialog has chosen, and where the last roll stands.
    local state = {
        heroid = nil,
        characteristic = nil,
        skill = nil,
        rolling = false,
        resultText = "",
        resultDetail = "",
        --this dialog's roll completed the project.
        completed = false,
        breakthrough = false,
        message = "",
    }

    local dlg = nil
    local body = nil
    local hintLabel = nil
    local finishButton = nil

    --the project's line and bar sit above the re-rendered body, so a gain
    --animating on the bar is never rebuilt mid-way.
    local blurbLabel = gui.Label{
        text = "",
        fontSize = 16,
        italics = true,
        color = DIM,
        width = "100%",
        height = "auto",
        bmargin = 8,
    }
    local bar, barCtl = ProgressBar(26)
    do
        local st = EotwDowntime.GetProject(projectid)
        barCtl.Set(st ~= nil and tonumber(st.points) or 0, st ~= nil and tonumber(st.goal) or 0)
    end

    --pick a default hero: one owed a free breakthrough roll, else the one
    --with the most Downtime.
    local function ChooseDefaultHero()
        local workers = ProjectWorkers(projectid)
        local best = nil
        for _, w in ipairs(workers) do
            if w.breakthrough ~= nil then
                return w
            end
            if best == nil or w.downtime > best.downtime then
                best = w
            end
        end
        return best
    end

    local function SelectHero(w)
        if w == nil then
            state.heroid = nil
            return
        end
        state.heroid = w.hero.heroid
        state.characteristic = BestCharacteristic(w.tok, project)
        local trained = TrainedProjectSkills(w.tok, project)
        state.skill = trained[1]
    end

    local Render

    --The dice rest in a cage at the bottom of the dialog, armed with the
    --current choices; clicking or throwing them makes the roll. armedSignature
    --is what they are armed with (nil = not armed): a change of hero,
    --characteristic, skill or free roll re-arms them.
    local cage = nil
    local armedSignature = nil

    local function Disarm()
        armedSignature = nil
        if cage ~= nil and cage.valid then
            pcall(function() cage:CancelDicePreviewRoll() end)
        end
    end

    local function ArmDice(signature)
        Disarm()
        if cage == nil or not cage.valid or state.heroid == nil then
            return
        end
        armedSignature = signature
        local breakthrough = EotwDowntime.OpenBreakthrough(projectid, state.heroid)
        local before = EotwDowntime.GetProject(projectid)
        local goalBefore = before ~= nil and tonumber(before.goal) or 0
        EotwDowntime.Roll{
            previewPanel = cage,
            projectid = projectid,
            heroid = state.heroid,
            characteristic = state.characteristic,
            skill = state.skill,
            breakthroughOf = breakthrough ~= nil and breakthrough.rollid or nil,
            --the player threw the dice: the roll is under way, and the bar
            --previews what they show as they tumble.
            begin = function(rollInfo, bonus)
                armedSignature = nil
                state.rolling = true
                state.message = ""
                state.resultText = "..."
                state.resultDetail = "The dice are rolling."
                state.breakthrough = false
                if bar.valid then
                    barCtl.WatchDice(rollInfo.rolls, bonus)
                end
                Render()
            end,
            --a throw too weak to roll: the dice go back to rest, armed again.
            cancel = function()
                armedSignature = nil
                Render()
            end,
            rolled = function(natural, total)
                state.resultText = string.format("+%d", math.max(0, total))
                state.resultDetail = string.format("natural %d", natural)
                state.breakthrough = natural >= EotwDowntime.BREAKTHROUGH_NATURAL
                if bar.valid then
                    barCtl.StopDice()
                    barCtl.Preview(math.max(0, total))
                end
                Render()
            end,
            done = function(ok, result)
                if mod.unloaded then
                    return
                end
                if not ok then
                    state.rolling = false
                    state.message = tostring(result)
                    if bar.valid then
                        barCtl.StopDice()
                        barCtl.Preview(nil)
                    end
                    Render()
                    return
                end
                local tok = dmhub.GetCharacterById(state.heroid)
                local name = tok ~= nil and tok.name or "Your hero"
                local p = result.project or {}

                --the banners wait for the gain to settle on the bar.
                local function Announce()
                    if mod.unloaded then
                        return
                    end
                    if result.breakthrough then
                        local subtitle = string.format("%s made a breakthrough on %s", name, project.title)
                        if result.refunded then
                            subtitle = string.format("%s finished %s with a breakthrough: the extra roll comes back as a Downtime Activity", name, project.title)
                        end
                        ShowBanner(host, "Breakthrough!", subtitle)
                    end
                    if result.completed then
                        local text = project.title .. "!"
                        local subtitle = "The project is complete."
                        if projectid == "expand-guild" then
                            text = "The Guild Expands!"
                            subtitle = string.format("You now have %d hero slots.", EotwRoster.Slots())
                        end
                        --after the breakthrough banner, if both.
                        dmhub.Schedule(cond(result.breakthrough, 4.5, 0), function()
                            if not mod.unloaded then
                                ShowBanner(host, text, subtitle)
                            end
                        end)
                    end
                end

                if result.completed then
                    state.resultDetail = state.resultDetail .. cond(p.maxed, " -- the project is finished", " -- complete! Any extra points are lost")
                    if result.refunded then
                        --the City gave the breakthrough's extra roll back.
                        state.resultDetail = state.resultDetail .. string.format(". The breakthrough refunds a Downtime Activity to %s", name)
                    end
                else
                    state.resultDetail = state.resultDetail .. " -- " .. tostring(name)
                end

                if not bar.valid then
                    state.rolling = false
                    Announce()
                    return
                end
                if result.completed then
                    --fill to the end and stay full: the project is done (it
                    --has ended; a next expansion has to be started anew).
                    state.completed = true
                    barCtl.AnimateTo(goalBefore, function()
                        Announce()
                        state.rolling = false
                        Render()
                    end)
                else
                    barCtl.AnimateTo(tonumber(p.points) or 0, function()
                        state.rolling = false
                        Announce()
                        Render()
                    end)
                end
                Render()
            end,
        }
    end

    Render = function()
        if body == nil or not body.valid then
            return
        end
        local projectState = EotwDowntime.GetProject(projectid)
        local workers = ProjectWorkers(projectid)
        local chosen = nil
        for _, w in ipairs(workers) do
            if w.hero.heroid == state.heroid then
                chosen = w
            end
        end
        if chosen == nil and not state.rolling then
            SelectHero(ChooseDefaultHero())
            for _, w in ipairs(workers) do
                if w.hero.heroid == state.heroid then
                    chosen = w
                end
            end
        end

        local children = {}

        blurbLabel.text = project.blurb(projectState)
        --a finished project's bar stays full; only one under way follows the City.
        if projectState ~= nil and projectState.active == true and not state.rolling and not barCtl.Busy() then
            barCtl.Update(tonumber(projectState.points) or 0, tonumber(projectState.goal) or 0)
        end

        --who works on it.
        children[#children+1] = gui.Label{
            text = "Who works on it",
            fontSize = 15,
            color = DIM,
            width = "100%",
            height = "auto",
            tmargin = 14,
            bmargin = 4,
        }
        local chips = {}
        for _, w in ipairs(workers) do
            local selected = state.heroid == w.hero.heroid
            local usable = w.downtime > 0 or w.breakthrough ~= nil
            chips[#chips+1] = gui.Panel{
                width = "auto",
                height = 40,
                flow = "horizontal",
                hpad = 8,
                borderBox = true,
                hmargin = 3,
                vmargin = 3,
                bgimage = "panels/square.png",
                bgcolor = cond(selected, "#3a2e1a", "#1d1913"),
                borderWidth = cond(selected, 2, 1),
                borderColor = cond(selected, GOLD, "#5a4b33"),
                cornerRadius = 6,
                opacity = cond(usable, 1, 0.5),
                press = function()
                    if state.rolling then
                        return
                    end
                    audio.FireSoundEvent("Mouse.Click")
                    SelectHero(w)
                    state.message = ""
                    Render()
                end,
                linger = function(element)
                    if w.breakthrough ~= nil then
                        gui.Tooltip("A breakthrough roll is waiting: the next roll is free.")(element)
                    elseif not usable then
                        gui.Tooltip("No Downtime Activities. Rest at the Blue Fish Inn to earn them.")(element)
                    end
                end,
                Portrait(w.tok, 24, 32),
                gui.Label{
                    text = w.tok.name or "Hero",
                    fontSize = 16,
                    color = TEXT,
                    width = "auto",
                    height = "auto",
                    valign = "center",
                    hmargin = 6,
                    interactable = false,
                },
                HammerChip(w.downtime),
                gui.Label{
                    classes = { cond(w.breakthrough ~= nil, "visible", "collapsed") },
                    text = "free roll",
                    fontSize = 13,
                    italics = true,
                    color = AMBER,
                    width = "auto",
                    height = "auto",
                    valign = "center",
                    lmargin = 6,
                    interactable = false,
                },
            }
        end
        if #chips == 0 then
            chips[1] = gui.Label{
                text = "None of your heroes are at home.",
                fontSize = 16,
                italics = true,
                color = DIM,
                width = "auto",
                height = "auto",
            }
        end
        children[#children+1] = gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            wrap = true,
            children = chips,
        }

        if chosen ~= nil then
            --the characteristic.
            local options = {}
            for _, c in ipairs(ProjectCharacteristics(project)) do
                local selected = state.characteristic == c.id
                --a toggle with its own look (a stock button's hover turns
                --the text black, unreadable on the selected dark fill).
                local classes = { "eotwToggle" }
                if selected then
                    classes[#classes+1] = "selected"
                end
                options[#options+1] = gui.Panel{
                    classes = classes,
                    styles = TOGGLE_STYLES,
                    width = 170,
                    height = 36,
                    hmargin = 4,
                    bgimage = "panels/square.png",
                    cornerRadius = 6,
                    press = function()
                        if state.rolling then
                            return
                        end
                        audio.FireSoundEvent("Mouse.Click")
                        state.characteristic = c.id
                        Render()
                    end,
                    gui.Label{
                        text = string.format("%s %+d", c.name, CharacteristicValue(chosen.tok, c.id)),
                        fontSize = 16,
                        color = TEXT,
                        width = "auto",
                        height = "auto",
                        halign = "center",
                        valign = "center",
                        interactable = false,
                    },
                }
            end
            children[#children+1] = gui.Panel{
                width = "100%",
                height = "auto",
                flow = "horizontal",
                tmargin = 12,
                gui.Label{
                    text = "Characteristic",
                    fontSize = 15,
                    color = DIM,
                    width = 140,
                    height = "auto",
                    valign = "center",
                },
                gui.Panel{
                    width = "auto",
                    height = "auto",
                    flow = "horizontal",
                    children = options,
                },
            }

            --the skill.
            local trained = TrainedProjectSkills(chosen.tok, project)
            local skillOptions = { { id = "", text = "No skill" } }
            for _, name in ipairs(trained) do
                skillOptions[#skillOptions+1] = { id = name, text = string.format("%s (+2)", name) }
            end
            children[#children+1] = gui.Panel{
                width = "100%",
                height = "auto",
                flow = "horizontal",
                tmargin = 8,
                gui.Label{
                    text = "Skill",
                    fontSize = 15,
                    color = DIM,
                    width = 140,
                    height = "auto",
                    valign = "center",
                },
                gui.Dropdown{
                    width = 240,
                    height = 34,
                    fontSize = 16,
                    --the open list needs the themed sheet; the titlescreen's
                    --legacy styles leave it as bare labels.
                    styles = ThemeEngine.GetStyles(),
                    options = skillOptions,
                    idChosen = state.skill or "",
                    change = function(element)
                        ---@cast element Dropdown
                        local id = element.idChosen
                        state.skill = cond(id ~= nil and id ~= "", id, nil)
                        Render()
                    end,
                },
                gui.Label{
                    text = cond(#trained == 0, "None of " .. table.concat(project.skills, ", "), table.concat(project.skills, ", ")),
                    fontSize = 13,
                    italics = true,
                    color = DIM,
                    width = 320,
                    height = "auto",
                    valign = "center",
                    lmargin = 10,
                },
            }

            local _, formula = EotwDowntime.RollBonus(chosen.tok, state.characteristic, state.skill)
            children[#children+1] = gui.Label{
                text = formula,
                fontSize = 18,
                color = TEXT,
                width = "100%",
                height = "auto",
                tmargin = 12,
            }
        end

        --the result of the last roll.
        children[#children+1] = gui.Panel{
            width = "100%",
            height = 96,
            flow = "vertical",
            tmargin = 10,
            gui.Label{
                classes = { cond(state.breakthrough, "visible", "collapsed") },
                text = "Breakthrough!",
                fontFace = "display",
                fontSize = 30,
                color = AMBER,
                width = "auto",
                height = "auto",
                halign = "center",
            },
            gui.Label{
                text = state.resultText,
                fontSize = 40,
                bold = true,
                color = GOLD,
                width = "auto",
                height = "auto",
                halign = "center",
            },
            gui.Label{
                text = state.resultDetail,
                fontSize = 15,
                color = DIM,
                width = "auto",
                height = "auto",
                halign = "center",
            },
        }

        children[#children+1] = gui.Label{
            text = state.message,
            fontSize = 15,
            color = RED,
            width = "100%",
            height = 22,
            textAlignment = "center",
        }

        body.children = children

        --the dice: armed with the current choices when a roll is possible.
        local free = chosen ~= nil and chosen.breakthrough ~= nil
        local projectActive = projectState ~= nil and projectState.active == true
        local canRoll = chosen ~= nil and (free or chosen.downtime > 0) and projectActive
        local chosenName = "your hero"
        local freeRollid = ""
        if chosen ~= nil then
            chosenName = tostring(chosen.tok.name or chosenName)
            if chosen.breakthrough ~= nil then
                freeRollid = tostring(chosen.breakthrough.rollid)
            end
        end
        --finished: the project is done, or no hero at home has a roll left
        --(no Downtime, no free breakthrough). Then the dice give way to a big
        --Close; otherwise the X in the corner is the way out.
        local anyCanWork = false
        for _, w in ipairs(workers) do
            if w.downtime > 0 or w.breakthrough ~= nil then
                anyCanWork = true
            end
        end
        local finished = not state.rolling and (state.completed or not projectActive or not anyCanWork)
        if finishButton ~= nil and finishButton.valid then
            finishButton:SetClass("collapsed", not finished)
        end

        local hint = ""
        if state.rolling then
            hint = ""
        elseif canRoll and free then
            hint = string.format("Breakthrough! Click or throw the dice for %s's free roll.", chosenName)
        elseif canRoll then
            hint = "Click or throw the dice to roll. It spends one of this hero's Downtime Activities."
        elseif state.completed then
            hint = string.format("Project complete! %s.", tostring(project.benefit or "Done"))
        elseif not projectActive then
            hint = "This project is not under way."
        elseif chosen == nil then
            hint = "None of your heroes are at home."
        elseif not anyCanWork then
            hint = "Your heroes have no Downtime Activities left. Rest at the Blue Fish Inn to earn more."
        else
            hint = "This hero has no Downtime Activities. Choose another hero, or rest at the Blue Fish Inn."
        end
        if hintLabel ~= nil and hintLabel.valid then
            hintLabel.text = hint
        end
        if not state.rolling then
            if canRoll then
                local signature = table.concat({
                    tostring(state.heroid), tostring(state.characteristic), tostring(state.skill),
                    freeRollid,
                }, "|")
                if signature ~= armedSignature then
                    ArmDice(signature)
                end
            elseif armedSignature ~= nil then
                Disarm()
            end
        end
    end

    --A fixed size, so nothing jumps as the rows change during a roll: the
    --header, bar and choices hang from the top, the hint and the dice sit
    --on the bottom, and the space between absorbs the changes. (A fixed
    --height with flow "vertical" would spread the rows out instead.)
    dlg = gui.Panel{
        floating = true,
        width = 860,
        height = 820,
        halign = "center",
        valign = "center",
        bgimage = "panels/square.png",
        bgcolor = "#14110dff",
        borderWidth = 2,
        borderColor = "#8c7a55",
        cornerRadius = 10,
        flow = "none",
        pad = 24,
        borderBox = true,
        styles = { Styles.Default },
        captureEscape = true,
        escapePriority = EscapePriority.EXIT_MODAL_DIALOG,
        escape = function(element)
            if not state.rolling then
                barCtl.StopDice()
                Disarm()
                element:DestroySelf()
            end
        end,
        data = { seen = -1 },
        thinkTime = 0.5,
        think = function(element)
            local rev = EotwDowntime.revision + EotwRoster.revision * 100000
            if element.data.seen ~= rev and not state.rolling then
                element.data.seen = rev
                Render()
            end
        end,
        --the top: title, the project's line and bar, then the choices.
        gui.Panel{
            floating = true,
            halign = "center",
            valign = "top",
            width = "100%",
            height = "auto",
            flow = "vertical",
            gui.Panel{
                width = "100%",
                height = "auto",
                flow = "horizontal",
                bmargin = 6,
                gui.Panel{
                    width = 30,
                    height = 30,
                    valign = "center",
                    rmargin = 10,
                    bgimage = "phosphor/hammer-fill.png",
                    bgcolor = GOLD,
                },
                gui.Label{
                    text = project.title .. ": Project Roll",
                    fontSize = 28,
                    bold = true,
                    color = TEXT,
                    width = "auto",
                    height = "auto",
                    valign = "center",
                },
            },
            blurbLabel,
            bar,
            gui.Panel{
                width = "100%",
                height = "auto",
                flow = "vertical",
                create = function(element)
                    body = element
                end,
            },
        },

        --the bottom: how to roll (or why not) over the dice.
        gui.Panel{
            floating = true,
            halign = "center",
            valign = "bottom",
            width = "100%",
            height = "auto",
            flow = "vertical",

            --a fixed height: the line empties while the dice roll.
            gui.Label{
                text = "",
                fontSize = 16,
                italics = true,
                color = AMBER,
                width = "100%",
                height = 46,
                textAlignment = "center",
                create = function(element)
                    hintLabel = element
                end,
            },

            --The dice, resting until clicked or thrown -- the same kind of dice
            --cage the game's roll dialog has (a gui.DicePreview armed by
            --dmhub.Roll{preview = true, previewPanel = cage}). Built once: a
            --rebuild would drop the armed roll.
            gui.DicePreview{
                width = "70%",
                height = 120,
                halign = "center",
                bgimage = true,
                bgcolor = "white",
                styles = { gui.Style{ opacity = 0 } },
                draggable = true,
                dragMove = false,
                create = function(element)
                    ---@cast element DicePreview
                    cage = element
                    element:SetAsDicePreviewPanel(true)
                    --thrown dice roll out across the whole screen, not just the cage.
                    pcall(function() element.dicePreviewScreenBounds = true end)
                    --the body is in place by now: render, which arms the dice.
                    Render()
                end,
                destroy = function(element)
                    ---@cast element DicePreview
                    pcall(function() element:CancelDicePreviewRoll() end)
                    element:SetAsDicePreviewPanel(false)
                end,
                --input goes through the cage's own methods, so only THIS
                --dialog's dice react.
                hover = function(element)
                    ---@cast element DicePreview
                    pcall(function() element:DicePreviewMouseEnter() end)
                end,
                dehover = function(element)
                    ---@cast element DicePreview
                    pcall(function() element:DicePreviewMouseLeave() end)
                end,
                click = function(element)
                    ---@cast element DicePreview
                    if armedSignature ~= nil then
                        pcall(function() element:DicePreviewClick() end)
                    end
                end,
                dragging = function(element)
                    ---@cast element DicePreview
                    pcall(function() element:DicePreviewDragThink() end)
                end,
                drag = function(element)
                    ---@cast element DicePreview
                    pcall(function() element:DicePreviewDragEnd() end)
                end,
            },

            --where the dice were, once there is nothing left to roll: a big
            --Close (see `finished` in Render). Floats over the empty cage.
            gui.Button{
                classes = { "collapsed" },
                floating = true,
                halign = "center",
                valign = "bottom",
                bmargin = 34,
                text = "Close",
                fontSize = 24,
                width = 260,
                height = 54,
                create = function(element)
                    finishButton = element
                    --built after the dice cage's first render: show it now if
                    --the dialog opened with nothing left to roll.
                    Render()
                end,
                click = function()
                    if state.rolling then
                        return
                    end
                    if dlg ~= nil and dlg.valid then
                        barCtl.StopDice()
                        Disarm()
                        dlg:DestroySelf()
                    end
                end,
            },
        },

        --close: an X in the top-right corner (not while dice are in the air).
        gui.Panel{
            floating = true,
            halign = "right",
            valign = "top",
            x = 10,
            y = -10,
            width = 22,
            height = 22,
            bgimage = "phosphor/x-bold.png",
            styles = {
                { selectors = { "eotwDialogClose" }, bgcolor = DIM },
                { selectors = { "eotwDialogClose", "hover" }, bgcolor = "#ffffff", scale = 1.15 },
            },
            classes = { "eotwDialogClose" },
            linger = gui.Tooltip("Close"),
            press = function()
                if state.rolling then
                    return
                end
                audio.FireSoundEvent("UI.WindowClose")
                if dlg ~= nil and dlg.valid then
                    barCtl.StopDice()
                    Disarm()
                    dlg:DestroySelf()
                end
            end,
        },
    }
    host:AddChild(dlg)
end

--- projects under way (the Hero's Guild) -------------------------------------------

--Is this project under way (started and not yet completed)?
function EotwDowntime.IsActive(projectid)
    local state = m_projects[projectid]
    return state ~= nil and state.active == true
end

--Could this project be started now? Not while it is under way or finished,
--nor before the City has listed it.
function EotwDowntime.CanStart(projectid)
    local state = m_projects[projectid]
    return state ~= nil and state.active ~= true and state.maxed ~= true
end

--Should the Guild offer to start this project? Whenever it is listed and
--not under way -- even when it can never complete again, so the screen
--does not give away how many times it can be done (the dialog then says
--the guild cannot grow).
function EotwDowntime.CanOffer(projectid)
    local state = m_projects[projectid]
    return state ~= nil and state.active ~= true
end

--Start a project, so heroes can spend Downtime on it. onDone(ok, message).
function EotwDowntime.StartProject(projectid, onDone)
    local conn = EotwRoster.Connection()
    if conn == nil or not conn.connected then
        if onDone ~= nil then
            onDone(false, "Not connected to the town.")
        end
        return
    end
    conn:Request{
        action = "start-project",
        args = { projectid = projectid },
        success = function(result)
            if type(result.project) == "table" then
                m_projects[result.project.projectid] = result.project
            end
            Bump()
            if onDone ~= nil then
                onDone(true)
            end
        end,
        error = function(message)
            if onDone ~= nil then
                onDone(false, message)
            end
        end,
    }
end

--Ask whether to start a project: what it does, what it costs, how it is
--worked on. Start sends start-project.
function EotwDowntime.ShowStartProjectDialog(host, projectid)
    local project = EotwDowntime.PROJECTS[projectid]
    local state = m_projects[projectid]
    if project == nil then
        return
    end
    local goal = state ~= nil and tonumber(state.goal) or 0
    --a project that can never complete again: the dialog says so instead
    --of offering to start it (the Guild still offers it; see CanOffer).
    local maxed = state ~= nil and state.maxed == true
    local statusLabel = gui.Label{
        text = "",
        fontSize = 15,
        color = RED,
        width = "100%",
        height = 22,
        textAlignment = "center",
    }
    local dlg
    dlg = gui.Panel{
        floating = true,
        width = 720,
        height = "auto",
        halign = "center",
        valign = "center",
        bgimage = "panels/square.png",
        bgcolor = "#14110dff",
        borderWidth = 2,
        borderColor = "#8c7a55",
        cornerRadius = 10,
        flow = "vertical",
        pad = 28,
        borderBox = true,
        styles = { Styles.Default },
        captureEscape = true,
        escapePriority = EscapePriority.EXIT_MODAL_DIALOG,
        escape = function(element)
            element:DestroySelf()
        end,
        gui.Panel{
            width = "auto",
            height = "auto",
            flow = "horizontal",
            halign = "center",
            gui.Panel{
                width = 30,
                height = 30,
                valign = "center",
                rmargin = 10,
                bgimage = project.icon,
                bgcolor = GOLD,
            },
            gui.Label{
                text = string.format("Start a Project: %s?", project.title),
                fontSize = 28,
                bold = true,
                color = TEXT,
                width = "auto",
                height = "auto",
                valign = "center",
            },
        },
        gui.Label{
            text = project.blurb(state),
            fontSize = 18,
            italics = true,
            color = DIM,
            width = "100%",
            height = "auto",
            textAlignment = "center",
            vmargin = 10,
        },
        gui.Label{
            text = cond(maxed, "The guildmasters shake their heads: there is no room left to grow.", string.format("%d Project Points to complete.", goal)),
            fontSize = 20,
            color = TEXT,
            width = "100%",
            height = "auto",
            textAlignment = "center",
            tmargin = 6,
        },
        gui.Label{
            classes = { cond(maxed, "collapsed", "eotwBenefit") },
            text = project.benefit,
            fontSize = 22,
            bold = true,
            color = GOLD,
            width = "100%",
            height = "auto",
            textAlignment = "center",
            vmargin = 6,
        },
        statusLabel,
        gui.Panel{
            width = "auto",
            height = "auto",
            flow = "horizontal",
            halign = "center",
            tmargin = 8,
            gui.Button{
                classes = { cond(maxed, "collapsed", "eotwStart") },
                text = "Start Project",
                fontSize = 20,
                width = 220,
                height = 46,
                hmargin = 6,
                click = function()
                    audio.FireSoundEvent("Mouse.Click")
                    EotwDowntime.StartProject(projectid, function(ok, message)
                        if mod.unloaded then
                            return
                        end
                        if not ok then
                            if statusLabel.valid then
                                statusLabel.text = tostring(message)
                            end
                            return
                        end
                        if dlg ~= nil and dlg.valid then
                            dlg:DestroySelf()
                        end
                    end)
                end,
            },
            gui.Button{
                text = "Not Now",
                fontSize = 20,
                width = 180,
                height = 46,
                hmargin = 6,
                click = function()
                    dlg:DestroySelf()
                end,
            },
        },
    }
    host:AddChild(dlg)
end

--A project's card: its progress, what it takes, the latest rolls, and the
--way in to the roll dialog. host is the panel to mount the roll dialog on
--(the town screen).
function EotwDowntime.ProjectCard(host, projectid)
    local project = EotwDowntime.PROJECTS[projectid]
    local bar, barCtl = ProgressBar(22)

    local titleLabel = gui.Label{
        text = project.title,
        fontSize = 22,
        bold = true,
        color = TEXT,
        width = "auto",
        height = "auto",
        valign = "center",
    }
    local stepLabel = gui.Label{
        text = "",
        fontSize = 15,
        color = DIM,
        width = "auto",
        height = "auto",
        valign = "center",
        lmargin = 10,
    }
    local blurbLabel = gui.Label{
        text = "",
        fontSize = 15,
        italics = true,
        color = DIM,
        width = "100%",
        height = "auto",
        vmargin = 4,
    }
    local needsLabel = gui.Label{
        text = string.format("Reason or Presence  -  %s", table.concat(project.skills, ", ")),
        fontSize = 14,
        color = DIM,
        width = "100%",
        height = "auto",
        tmargin = 6,
    }
    local recentLabel = gui.Label{
        text = "",
        fontSize = 14,
        color = DIM,
        width = "100%",
        height = "auto",
        tmargin = 4,
    }
    local workButton = gui.Button{
        text = "Work on This Project",
        fontSize = 18,
        width = 250,
        height = 40,
        halign = "right",
        linger = function(element)
            if element.data.reason ~= nil then
                gui.Tooltip(element.data.reason)(element)
            end
        end,
        data = { reason = nil },
        click = function(element)
            if element.data.reason ~= nil then
                return
            end
            EotwDowntime.ShowRollDialog(host, projectid)
        end,
    }

    local function Refresh()
        local state = EotwDowntime.GetProject(projectid)
        blurbLabel.text = project.blurb(state)
        --no "expansion N of M": how many there can be is not shown.
        stepLabel.text = ""
        if state ~= nil then
            --a gain eases into place; anything else shows at once.
            barCtl.Update(tonumber(state.points) or 0, tonumber(state.goal) or 0)
        end

        local parts = {}
        for i, r in ipairs(state ~= nil and state.recent or {}) do
            if i > 4 then
                break
            end
            local text = string.format("%s +%d", tostring(r.heroName or "Hero"), tonumber(r.total) or 0)
            if r.breakthrough then
                text = text .. string.format(" <color=%s>breakthrough</color>", AMBER)
            end
            parts[#parts+1] = text
        end
        recentLabel.text = cond(#parts > 0, "Latest: " .. table.concat(parts, "  -  "), "No one has worked on it yet.")

        --who can work on it now.
        local anyDowntime, anyBreakthrough = false, false
        for _, w in ipairs(ProjectWorkers(projectid)) do
            if w.downtime > 0 then
                anyDowntime = true
            end
            if w.breakthrough ~= nil then
                anyBreakthrough = true
            end
        end
        local reason = nil
        if state == nil or state.active ~= true then
            reason = "This project is not under way."
        elseif not anyDowntime and not anyBreakthrough then
            reason = "None of your heroes at home have Downtime Activities. Rest at the Blue Fish Inn to earn them."
        end
        workButton.data.reason = reason
        workButton.selfStyle.opacity = cond(reason == nil, 1, 0.45)
        workButton.text = cond(anyBreakthrough, "Breakthrough Roll Waiting", "Work on This Project")
    end

    EotwDowntime.RefreshProjects()

    return gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",
        bgimage = "panels/square.png",
        --translucent like the scene's own card: the art reads through.
        bgcolor = "#0e0b08dc",
        borderWidth = 1,
        borderColor = "#d9b56a77",
        cornerRadius = 10,
        pad = 16,
        borderBox = true,
        data = { seen = -1 },
        thinkTime = 0.5,
        think = function(element)
            local rev = EotwDowntime.revision + EotwRoster.revision * 100000
            if element.data.seen ~= rev then
                element.data.seen = rev
                Refresh()
            end
        end,
        create = function(element)
            Refresh()
        end,
        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            gui.Panel{
                width = 22,
                height = 22,
                valign = "center",
                rmargin = 8,
                bgimage = project.icon,
                bgcolor = GOLD,
            },
            titleLabel,
            stepLabel,
            gui.Label{
                text = "Project under way",
                fontSize = 13,
                italics = true,
                color = GOLD,
                width = "auto",
                height = "auto",
                halign = "right",
                valign = "center",
            },
        },
        blurbLabel,
        bar,
        needsLabel,
        recentLabel,
        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            tmargin = 6,
            workButton,
        },
    }
end

--The project card for the free space on a location's scene: shown only
--while the project is under way. width in the scene's units.
function EotwDowntime.ProjectSidePanel(host, projectid, width)
    local panel
    panel = gui.Panel{
        classes = { "collapsed" },
        width = width,
        height = "auto",
        flow = "vertical",
        data = { seen = -1 },
        --a collapsed panel stops thinking, so the watcher is a sibling
        --below that stays alive.
        EotwDowntime.ProjectCard(host, projectid),
    }
    local watcher = gui.Panel{
        width = 1,
        height = 1,
        interactable = false,
        data = { seen = -1 },
        thinkTime = 0.25,
        think = function(element)
            local rev = EotwDowntime.revision
            if element.data.seen ~= rev and panel.valid then
                element.data.seen = rev
                panel:SetClass("collapsed", not EotwDowntime.IsActive(projectid))
            end
        end,
    }
    EotwDowntime.RefreshProjects()
    return gui.Panel{
        width = "auto",
        height = "auto",
        flow = "vertical",
        children = { panel, watcher },
    }
end

--- the Blue Fish Inn ----------------------------------------------------------

--One hero's row at the inn: portrait, name, Stamina and Recoveries, what a
--respite would give them, and Catch Your Breath.
local function InnRow(entry, onChanged)
    local hero = entry.hero
    local tok = entry.tok
    local summary = hero.summary or {}
    local name = (tok ~= nil and tok.name) or summary.name or "Hero"

    local vitals = "-"
    local barFraction = 0
    local dying = false
    if tok ~= nil then
        local cur, max, left, rmax = Vitals(tok)
        vitals = string.format("Stamina %d/%d  -  Recoveries %d/%d", cur, max, left, rmax)
        if max > 0 then
            barFraction = math.max(0, math.min(1, cur / max))
        end
        dying = EotwRoster.TokenIsDying(tok)
    end

    local gains
    if not entry.canRest then
        gains = gui.Label{
            text = entry.reason or "",
            fontSize = 14,
            italics = true,
            color = DIM,
            width = 150,
            height = "auto",
            valign = "center",
            textAlignment = "right",
        }
    else
        gains = gui.Panel{
            width = 150,
            height = "auto",
            flow = "vertical",
            valign = "center",
            gui.Panel{
                width = "auto",
                height = "auto",
                flow = "horizontal",
                halign = "right",
                gui.Panel{
                    width = 16,
                    height = 16,
                    valign = "center",
                    bgimage = "phosphor/trophy-fill.png",
                    bgcolor = GOLD,
                },
                gui.Label{
                    text = string.format("%d", entry.victories),
                    fontSize = 16,
                    bold = true,
                    color = GOLD,
                    width = "auto",
                    height = "auto",
                    valign = "center",
                    lmargin = 4,
                },
            },
            gui.Label{
                text = cond(entry.victories > 0,
                    string.format("+%d XP  -  +%d Downtime", entry.victories, entry.victories),
                    "Full rest"),
                fontSize = 13,
                color = cond(entry.victories > 0, AMBER, DIM),
                width = "auto",
                height = "auto",
                halign = "right",
            },
        }
    end

    local breathReason = EotwDowntime.CatchBreathBlocked(hero.heroid)
    local breathButton = gui.Button{
        text = "Catch Breath",
        fontSize = 14,
        width = 120,
        height = 30,
        valign = "center",
        lmargin = 10,
        opacity = cond(breathReason == nil, 1, 0.4),
        linger = function(element)
            if breathReason ~= nil then
                gui.Tooltip(breathReason)(element)
            elseif tok ~= nil then
                local amount = 0
                pcall(function() amount = tok.properties:RecoveryAmount() end)
                gui.Tooltip(string.format("Spend a Recovery to regain %d Stamina, without resting. Victories stay unspent.", amount))(element)
            end
        end,
        click = function()
            if breathReason ~= nil then
                return
            end
            audio.FireSoundEvent("Mouse.Click")
            EotwDowntime.CatchBreath(hero.heroid, onChanged)
            onChanged()
        end,
    }

    return gui.Panel{
        width = "100%",
        height = 68,
        flow = "horizontal",
        vmargin = 2,
        hpad = 8,
        borderBox = true,
        bgimage = "panels/square.png",
        bgcolor = "#1d1913",
        cornerRadius = 6,
        opacity = cond(entry.away ~= nil, 0.5, 1),
        Portrait(tok, 42, 56),
        gui.Panel{
            width = "100%-370",
            height = "auto",
            flow = "vertical",
            valign = "center",
            lmargin = 10,
            gui.Label{
                text = name,
                fontSize = 18,
                bold = true,
                color = TEXT,
                width = "100%",
                height = "auto",
                textWrap = false,
                minFontSize = 12,
            },
            gui.Panel{
                width = "100%",
                height = 6,
                vmargin = 3,
                bgimage = "panels/square.png",
                bgcolor = "#2c261c",
                cornerRadius = 3,
                flow = "none",
                gui.Panel{
                    width = string.format("%.1f%%", barFraction * 100),
                    height = "100%",
                    halign = "left",
                    bgimage = "panels/square.png",
                    bgcolor = cond(barFraction >= 1, "#5f9a4a", "#c0563a"),
                    cornerRadius = 3,
                },
            },
            gui.Label{
                text = cond(dying, string.format("<color=#ff8f7a>Dying</color>  -  %s", vitals), vitals),
                fontSize = 13,
                color = DIM,
                width = "100%",
                height = "auto",
            },
        },
        gains,
        breathButton,
    }
end

--The Blue Fish Inn's card: every hero with their wounds, Take a Respite for
--all of them, Catch Your Breath for one, and where to spend Downtime after.
--host mounts dialogs; openLocation(id) goes to another town location.
function EotwDowntime.InnPanel(host, openLocation)
    local listPanel = nil
    local footerLabel = nil
    local statusLabel = nil
    local afterPanel = nil
    local respiteButton = nil

    local Rebuild
    Rebuild = function()
        if listPanel == nil or not listPanel.valid then
            return
        end
        local candidates = EotwDowntime.RestCandidates()
        local rows = {}
        local resting, victories = 0, 0
        for _, entry in ipairs(candidates) do
            rows[#rows+1] = InnRow(entry, Rebuild)
            if entry.canRest then
                resting = resting + 1
                victories = victories + entry.victories
            end
        end
        if EotwRoster.GetHeroes() == nil then
            rows[1] = gui.Label{ text = "The innkeeper is checking the guest book...", fontSize = 16, italics = true, color = DIM, width = "auto", height = "auto", halign = "center", vmargin = 20 }
        elseif #rows == 0 then
            rows[1] = gui.Label{ text = "You have no heroes. Visit the Hero's Guild.", fontSize = 16, italics = true, color = DIM, width = "auto", height = "auto", halign = "center", vmargin = 20 }
        end
        listPanel.children = rows

        if footerLabel ~= nil and footerLabel.valid then
            if resting == 0 then
                footerLabel.text = "None of your heroes are at home to rest."
            else
                footerLabel.text = string.format("%d %s rest: Victories become XP%s, and Stamina and Recoveries are restored.",
                    resting, cond(resting == 1, "hero", "heroes"),
                    cond(victories > 0, string.format(" and %d Downtime %s", victories, cond(victories == 1, "Activity", "Activities")), ""))
            end
        end
        if respiteButton ~= nil and respiteButton.valid then
            respiteButton.selfStyle.opacity = cond(resting > 0 and not EotwDowntime.RespiteBusy(), 1, 0.45)
        end

        --where to spend Downtime: shown once any hero at home has some.
        if afterPanel ~= nil and afterPanel.valid then
            local total = 0
            for _, entry in ipairs(candidates) do
                if entry.away == nil then
                    total = total + EotwRoster.GetDowntime(entry.hero.heroid)
                end
            end
            local children = {}
            if total > 0 then
                children[#children+1] = gui.Panel{
                    width = "auto",
                    height = "auto",
                    flow = "horizontal",
                    valign = "center",
                    HammerChip(total),
                    gui.Label{
                        text = string.format("Your heroes have %d Downtime %s to spend on projects.", total, cond(total == 1, "Activity", "Activities")),
                        fontSize = 15,
                        color = TEXT,
                        width = "auto",
                        height = "auto",
                        valign = "center",
                        lmargin = 8,
                    },
                }
                local anyActive = false
                for id, project in pairs(EotwDowntime.PROJECTS) do
                    local state = EotwDowntime.GetProject(id)
                    if state ~= nil and state.active == true then
                        anyActive = true
                        children[#children+1] = gui.Button{
                            text = string.format("%s (%d/%d)", project.title, tonumber(state.points) or 0, tonumber(state.goal) or 0),
                            fontSize = 15,
                            width = 300,
                            height = 34,
                            tmargin = 6,
                            linger = gui.Tooltip("Go to the Hero's Guild to work on it."),
                            click = function()
                                openLocation(project.location)
                            end,
                        }
                    end
                end
                if not anyActive then
                    --no project under way: point the way to where one starts.
                    children[#children+1] = gui.Button{
                        text = "Go to the Hero's Guild",
                        fontSize = 15,
                        width = 300,
                        height = 34,
                        tmargin = 6,
                        linger = gui.Tooltip("No project is under way. When your roster is full, the guild can start one to expand."),
                        click = function()
                            openLocation("guild")
                        end,
                    }
                end
            end
            afterPanel.children = children
            afterPanel:SetClass("collapsed", #children == 0)
        end
    end

    EotwDowntime.RefreshProjects()

    return gui.Panel{
        width = "100%",
        height = "100%",
        flow = "vertical",
        data = { seen = -1 },
        thinkTime = 0.5,
        think = function(element)
            local rev = EotwDowntime.revision + EotwRoster.revision * 100000
            if element.data.seen ~= rev then
                element.data.seen = rev
                Rebuild()
            end
        end,

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            gui.Label{
                text = "Take a Respite",
                fontSize = 26,
                bold = true,
                color = TEXT,
                width = "auto",
                height = "auto",
                valign = "center",
            },
            gui.Label{
                text = "24 hours of rest",
                fontSize = 16,
                italics = true,
                color = DIM,
                width = "auto",
                height = "auto",
                halign = "right",
                valign = "center",
            },
        },
        gui.Label{
            text = "Rest together and every hero at home turns their Victories into XP and Downtime Activities, and recovers fully. Or just catch your breath: spend a Recovery and keep your Victories for the next fight.",
            fontSize = 15,
            italics = true,
            color = DIM,
            width = "100%",
            height = "auto",
            vmargin = 8,
        },
        gui.Panel{
            width = "100%",
            height = "100%-330",
            flow = "vertical",
            vscroll = true,
            rpad = 12,
            borderBox = true,
            create = function(element)
                listPanel = element
                Rebuild()
            end,
        },
        gui.Label{
            text = "",
            fontSize = 15,
            color = TEXT,
            width = "100%",
            height = "auto",
            tmargin = 10,
            create = function(element)
                footerLabel = element
            end,
        },
        gui.Label{
            text = "",
            fontSize = 15,
            color = RED,
            width = "100%",
            height = 22,
            create = function(element)
                statusLabel = element
            end,
        },
        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            gui.Panel{
                width = "auto",
                height = "auto",
                halign = "right",
                create = function(element)
                    respiteButton = element
                end,
                ConfirmButton("Take a Respite", "Rest Now? (Victories become XP)", 360, function()
                    if EotwDowntime.RespiteBusy() then
                        return
                    end
                    audio.FireSoundEvent("Mouse.Click")
                    if statusLabel ~= nil and statusLabel.valid then
                        statusLabel.text = ""
                    end
                    EotwDowntime.TakeRespite(function(ok, message)
                        if mod.unloaded then
                            return
                        end
                        if not ok and statusLabel ~= nil and statusLabel.valid then
                            statusLabel.text = tostring(message)
                        end
                        Rebuild()
                    end)
                    Rebuild()
                end),
            },
        },
        gui.Panel{
            classes = { "collapsed" },
            width = "100%",
            height = "auto",
            flow = "vertical",
            tmargin = 12,
            create = function(element)
                afterPanel = element
            end,
        },
    }
end

--- dev commands ---------------------------------------------------------------

--The roster heroes a dev command names: those whose name starts with
--`name` (case-insensitive), or every hero at home when name is empty.
local function DevHeroes(name)
    local result = {}
    local away = EotwRoster.AwayHeroes()
    name = string.lower(name or "")
    for _, hero in ipairs(EotwRoster.GetHeroes() or {}) do
        local tok = dmhub.GetCharacterById(hero.heroid)
        local heroName = (tok ~= nil and tok.name) or (hero.summary or {}).name or ""
        if name == "" then
            if away[hero.heroid] == nil then
                result[#result+1] = hero
            end
        elseif string.sub(string.lower(heroName), 1, #name) == name then
            result[#result+1] = hero
        end
    end
    return result
end

local function DevHeroName(hero)
    local tok = dmhub.GetCharacterById(hero.heroid)
    return (tok ~= nil and tok.name) or (hero.summary or {}).name or hero.heroid
end

--Change a roster hero's working copy and push it (dev commands only).
local function DevModifyHero(hero, description, execute)
    local tok = dmhub.GetCharacterById(hero.heroid)
    if tok == nil or not EotwRoster.IsInStep(hero.heroid) then
        printf("EotW town (dev): %s is not loaded yet; try again in a moment", DevHeroName(hero))
        return
    end
    tok:ModifyProperties{
        description = description,
        undoable = false,
        execute = function()
            execute(tok.properties)
        end,
    }
    dmhub.Schedule(0.3, function()
        if not mod.unloaded then
            EotwRoster.PushHero(hero.heroid)
        end
    end)
end

local DEV_USAGE = [[Usage: /eotwdowntime <command> (open the town first)
  grant <n> [hero]      give n Downtime Activities (project rolls) to the hero, or to every hero at home
  victories <n> [hero]  give n Victories, to try a respite
  wound <n> [hero]      take n Stamina and spend one Recovery, to try Catch Breath
  breakthrough          the next project roll counts as a natural 20
  resetproject          forget Expand the Guild's progress, rolls and built slots (city admins)
  state                 print each hero's Downtime, the roster slots and the projects
[hero] matches the start of a hero's name, case-insensitive.]]

pcall(function()
    Commands.RegisterMacro{
        name = "eotwdowntime",
        summary = "dev: grant Downtime, Victories or wounds to town heroes",
        doc = DEV_USAGE,
        command = function(str)
            if not (dmhub.GetSettingValue("dev") or dmhub.isAdminAccount) then
                print("EotW town: /eotwdowntime is a developer command")
                return
            end
            local arg = string.gsub(str or "", "^%s*(.-)%s*$", "%1")
            local verb, rest = string.match(arg, "^(%S+)%s*(.*)$")
            verb = string.lower(verb or "")
            local amount, name = string.match(rest or "", "^(%-?%d+)%s*(.*)$")
            local n = math.floor(tonumber(amount) or 0)

            if verb == "breakthrough" then
                EotwDowntime.forceBreakthrough = not EotwDowntime.forceBreakthrough
                printf("EotW town (dev): next project roll is %s", cond(EotwDowntime.forceBreakthrough, "a natural 20", "rolled normally"))
                return
            end

            if verb == "resetproject" then
                local conn = EotwRoster.Connection()
                if conn == nil or not conn.connected then
                    print("EotW town (dev): open the town first (no city connection)")
                    return
                end
                conn:Request{
                    action = "dev-reset-project",
                    args = { projectid = "expand-guild" },
                    success = function(result)
                        if type(result.project) == "table" then
                            m_projects[result.project.projectid] = result.project
                        end
                        EotwRoster.SetListedSlots(result.slots)
                        Bump()
                        EotwRoster.Refresh()
                        printf("EotW town (dev): Expand the Guild reset (not started); %s slots", tostring(result.slots))
                    end,
                    error = function(message)
                        printf("EotW town (dev): reset refused: %s", tostring(message))
                    end,
                }
                return
            end

            if verb == "state" then
                printf("EotW town (dev): %d of %d slots used", EotwRoster.LivingCount(), EotwRoster.Slots())
                for _, hero in ipairs(EotwRoster.GetHeroes() or {}) do
                    local tok = dmhub.GetCharacterById(hero.heroid)
                    local victories, xp = 0, 0
                    if tok ~= nil then
                        pcall(function()
                            victories = tok.properties:GetVictories()
                            xp = tok.properties:try_get("xp", 0)
                        end)
                    end
                    local cur, max, left, rmax = 0, 0, 0, 0
                    if tok ~= nil then
                        cur, max, left, rmax = Vitals(tok)
                    end
                    printf("  %s: Downtime %d, Victories %d, XP %d, Stamina %d/%d, Recoveries %d/%d%s",
                        DevHeroName(hero), EotwRoster.GetDowntime(hero.heroid), victories, xp, cur, max, left, rmax,
                        cond(EotwRoster.IsDying(hero.heroid), " (dying)", ""))
                end
                for id, _ in pairs(EotwDowntime.PROJECTS) do
                    local s = EotwDowntime.GetProject(id)
                    if s == nil then
                        printf("  project %s: not listed yet", id)
                    else
                        printf("  project %s: %d/%d, %d completed, %d open breakthrough(s)", id,
                            tonumber(s.points) or 0, tonumber(s.goal) or 0, tonumber(s.completions) or 0, #(s.open or {}))
                    end
                end
                EotwDowntime.RefreshProjects()
                return
            end

            if (verb ~= "grant" and verb ~= "victories" and verb ~= "wound") or amount == nil then
                print(DEV_USAGE)
                return
            end
            local heroes = DevHeroes(name)
            if #heroes == 0 then
                printf("EotW town (dev): no hero matches '%s' (is the town open?)", tostring(name))
                return
            end

            if verb == "grant" then
                local conn = EotwRoster.Connection()
                if conn == nil or not conn.connected then
                    print("EotW town (dev): open the town first (no city connection)")
                    return
                end
                local grants = {}
                for _, hero in ipairs(heroes) do
                    grants[#grants+1] = { heroid = hero.heroid, amount = n }
                end
                conn:Request{
                    action = "grant-downtime",
                    args = { grantid = "dev-" .. dmhub.GenerateGuid(), grants = grants },
                    success = function(result)
                        for heroid, downtime in pairs(result.downtime or {}) do
                            EotwRoster.SetListedDowntime(heroid, downtime)
                            local hero = EotwRoster.FindHero(heroid)
                            printf("EotW town (dev): %s now has %s Downtime", hero ~= nil and DevHeroName(hero) or heroid, tostring(downtime))
                        end
                        Bump()
                    end,
                    error = function(message)
                        printf("EotW town (dev): grant refused: %s", tostring(message))
                    end,
                }
            elseif verb == "victories" then
                for _, hero in ipairs(heroes) do
                    DevModifyHero(hero, "Dev: Victories", function(props)
                        props:SetVictories(math.max(0, props:GetVictories() + n))
                    end)
                    printf("EotW town (dev): %s gains %d Victories", DevHeroName(hero), n)
                end
            elseif verb == "wound" then
                for _, hero in ipairs(heroes) do
                    DevModifyHero(hero, "Dev: wounds", function(props)
                        props.damage_taken = math.max(0, (props.damage_taken or 0) + n)
                        props:ConsumeResource(CharacterResource.recoveryResourceId, "long", 1, "Dev: wounded")
                    end)
                    printf("EotW town (dev): %s takes %d damage and spends a Recovery", DevHeroName(hero), n)
                end
            end
        end,
    }
end)
