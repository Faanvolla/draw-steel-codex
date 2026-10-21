local mod = dmhub.GetModLoading()

--Monster AI for the gemstone dragons (Solo Gemstone Dragons draft). Only the
--Topaz Dragon exists so far; its siblings share the psionic field chassis and
--belong in this module as they arrive.

local topazMonster = {"Topaz Dragon"}
local topazGroup = {"Topaz Dragon"}

local movementPause = 0.6
local abilityPause = 1.0

local TRIGGERED_ACTION = "b9bc06dd-80f1-4f33-bc55-25c114e3300c"
local SPIKE_KEYWORD = "topazspike"
local PYRO_WAVE_COST = 10

--Candidate speech lines, kept together so they are easy to revise after playtesting.
local speech = {
    pyroWave = {"Burn, little sparks!", "Feel the fire under your feet!"},
    heatDeath = {"Your warmth is mine.", "Be still. Be cold."},
    topazFlare = {"My field burns!", "Closer, and be consumed!"},
    absoluteZero = {"Nothing moves at absolute zero.", "I take your heat and give you nothing."},
    siphon = {"The earth answers me.", "Topaz, rise!"},
}

local function LiveCreature(token)
    return token ~= nil and token.valid and not token.isObject and token.properties ~= nil
        and not token.properties:IsDead()
end

local function EnemyTokens(token)
    local result = {}
    for _,other in ipairs(dmhub.allTokens) do
        if LiveCreature(other) and not other:IsFriend(token) then
            result[#result+1] = other
        end
    end
    return result
end

local function PsychicImmune(target)
    if target == nil or target.properties == nil then
        return false
    end
    local ok, value = pcall(function()
        return ExecuteGoblinScript('Immunities("Psychic")', target.properties:LookupSymbol{}, 0, "Topaz AI")
    end)
    return ok and (tonumber(value) or 0) > 0
end

local function FieldSize(token)
    local value = ExecuteGoblinScript("PsionicFieldSize", token.properties:LookupSymbol{}, 0, "Topaz AI")
    return math.max(0, tonumber(value) or 0)
end

local function Malice()
    return tonumber(CharacterResource.GetMalice()) or 0
end

local function MoveCinematically(ai, token, loc)
    if loc ~= nil and not ai:MovementTokenIsAtLoc(token, loc) then
        ai:MoveToken(token, loc, {maxCost = 10000, ignoreFalling = false})
        ai.Sleep(movementPause)
    end
end

local function TokensInArea(casterToken, ability, area)
    local result = {}
    for _,target in pairs(dmhub.tokenInfo.TokensInShape(area)) do
        if target.valid and not target.isObject and ability:TargetPassesFilter(casterToken, target, {targetArea = area}) then
            result[#result+1] = {token = target}
        end
    end
    return result
end

local function CountByAllegiance(casterToken, targets)
    local enemies, allies, slowed = 0, 0, 0
    for _,info in ipairs(targets) do
        local target = info.token
        if LiveCreature(target) and target.charid ~= casterToken.charid then
            if target:IsFriend(casterToken) then
                allies = allies + 1
            else
                enemies = enemies + 1
                if target.properties:HasNamedCondition("Slowed") then
                    slowed = slowed + 1
                end
            end
        end
    end
    return enemies, allies, slowed
end

local function BuildCubeArea(token, ability, anchor)
    return dmhub.CalculateShape{
        shape = "cube",
        targetPoint = token:PosAtLoc(anchor),
        token = token,
        range = ability:GetRange(token.properties),
        radius = ability:GetRadius(token.properties),
        checklos = false,
        altitude = anchor.altitude * dmhub.unitsPerSquare,
    }
end

local function BuildLineArea(token, ability, originLoc, targetLoc)
    return dmhub.CalculateShape{
        shape = "line",
        targetPoint = token:PosAtLoc(targetLoc),
        token = token,
        range = ability:GetRange(token.properties),
        radius = ability:GetRadius(token.properties),
        locOverride = originLoc,
        checklos = true,
        altitude = originLoc.altitude * dmhub.unitsPerSquare,
    }
end

--Best cube for an area ability: anchors on and around each enemy in range,
--scored by enemies caught minus allies caught. extraScore(area, targets) can
--add ability-specific value.
local function FindBestCubePlan(token, ability, extraScore)
    local range = ability:GetRange(token.properties)
    local radius = math.max(1, tonumber(ability:GetRadius(token.properties)) or 1)
    local best = nil
    local checked = {}
    for _,enemy in ipairs(EnemyTokens(token)) do
        for dx = 1 - radius, 0 do
            for dy = 1 - radius, 0 do
                local anchor = enemy.loc:dir(dx, dy)
                local key = string.format("%d,%d", anchor.x, anchor.y)
                if not checked[key] and token:Distance(anchor) <= range then
                    checked[key] = true
                    local area = BuildCubeArea(token, ability, anchor)
                    local targets = TokensInArea(token, ability, area)
                    local enemies, allies = CountByAllegiance(token, targets)
                    local value = enemies - allies*2
                    if extraScore ~= nil then
                        value = value + extraScore(area, targets)
                    end
                    if enemies > 0 and (best == nil or value > best.value) then
                        best = {anchor = anchor, enemies = enemies, allies = allies, value = value}
                    end
                end
            end
        end
    end
    return best
end

local function ExecuteAreaAbility(ai, token, ability, area, targets, options)
    options = options or {}
    local symbols = options.symbols or {}
    symbols.targetArea = area
    ai:ExecuteAbility(token, ability, targets, {
        sleep = abilityPause,
        symbols = symbols,
        targetArea = area,
    })
end

--Line plans from every square the dragon can still reach: lines are "within 1",
--so their origin is wherever the dragon stands when it breathes.
local function FindBestLinePlan(ai, token, ability, slowedBonus)
    local length = ability:GetRange(token.properties)
    local enemies = EnemyTokens(token)
    local candidates = {}
    for _,info in pairs(ai.paths or {}) do
        for _,enemy in ipairs(enemies) do
            if info.loc:DistanceInTiles(enemy.loc) <= length + 2 then
                candidates[#candidates+1] = {targetLoc = enemy.loc, locOverride = info.loc, cost = info.cost or 0}
            end
        end
    end
    if #candidates == 0 then
        for _,enemy in ipairs(enemies) do
            candidates[#candidates+1] = {targetLoc = enemy.loc, locOverride = token.loc, cost = 0}
        end
    end

    local plan = ai:FindBestLinePlan(token, ability, {
        candidates = candidates,
        logPlan = false,
        scorefn = function(target, candidate)
            if not LiveCreature(target) or target.charid == token.charid then
                return 0
            end
            if target:IsFriend(token) then
                return -2
            end
            local value = 1
            if slowedBonus ~= nil and target.properties:HasNamedCondition("Slowed") then
                value = value + slowedBonus
            end
            return value - (candidate.cost or 0)*0.0001
        end,
    })
    if plan == nil then
        return nil
    end
    local numEnemies, allies, slowed = CountByAllegiance(token, plan.targets)
    if numEnemies == 0 then
        return nil
    end
    return {
        loc = plan.locOverride or token.loc,
        targetLoc = plan.targetLoc,
        enemies = numEnemies,
        allies = allies,
        slowed = slowed,
        value = plan.score,
    }
end

local function ExecuteLinePlan(ai, token, ability, plan)
    MoveCinematically(ai, token, plan.loc)
    local area = BuildLineArea(token, ability, token.loc, plan.targetLoc)
    local targets = TokensInArea(token, ability, area)
    ExecuteAreaAbility(ai, token, ability, area, targets)
end

--------------------------------------------------------------------------------
-- Main actions.
--------------------------------------------------------------------------------

local function RaysIgnisTargetScore(target, edges)
    if target.isObject then
        return 0.05
    end
    local value = 1 + (edges or 0)*0.1 + MonsterAI.TargetStaminaBias(target)
    if PsychicImmune(target) then
        value = value + 0.2
    end
    return value
end

MonsterAI:RegisterMove{
    id = "Topaz Dragon: Rays Ignis",
    category = "Main Actions",
    monsters = topazMonster,
    abilities = {"Rays Ignis"},
    description = "Fire burning rays at two enemies, preferring those with a psychic immunity (the rays have an edge against them).",
    score = function(self, ai, token, ability)
        local loc, targetScore = ai:FindBestMoveToUseStrike(token, ability, RaysIgnisTargetScore)
        if loc ~= nil then
            return {score = 1.1 + math.min(0.15, (targetScore or 0)*0.03), loc = loc}
        end
    end,
    execute = function(self, ai, token, scoringInfo, ability)
        MoveCinematically(ai, token, scoringInfo.loc)
        local targets = ai:FindValidTargetsOfStrike(token, ability, scoringInfo.loc)
        table.sort(targets, function(a, b)
            return RaysIgnisTargetScore(a.token, a.edges) > RaysIgnisTargetScore(b.token, b.edges)
        end)
        table.resize_array(targets, ability:GetNumTargets(token))
        ai:ExecuteAbility(token, ability, targets, {sleep = abilityPause})
    end,
}

MonsterAI:RegisterMove{
    id = "Topaz Dragon: Rays Frigidus",
    category = "Main Actions",
    monsters = topazMonster,
    abilities = {"Rays Frigidus"},
    description = "Freeze a line of enemies, especially ones already slowed (they become restrained); preferred over Rays Ignis once it catches two or more.",
    score = function(self, ai, token, ability)
        local plan = FindBestLinePlan(ai, token, ability, 0.5)
        if plan == nil or plan.allies > 0 then
            return nil, "no line catches enemies without allies"
        end
        if plan.enemies < 2 and plan.slowed == 0 then
            return nil, "a single unslowed enemy is better served by Rays Ignis"
        end
        plan.score = 0.75 + 0.15*math.min(4, plan.enemies) + 0.2*math.min(2, plan.slowed)
        return plan
    end,
    execute = function(self, ai, token, scoringInfo, ability)
        ExecuteLinePlan(ai, token, ability, scoringInfo)
    end,
}

MonsterAI:RegisterMove{
    id = "Topaz Dragon: Pyro Wave",
    category = "Main Actions",
    monsters = topazMonster,
    abilities = {"Pyro Wave"},
    description = "Spend 10 Malice on Pyro Wave when its 10 x 4 line catches three or more enemies (two when Malice is plentiful).",
    score = function(self, ai, token, ability)
        local plan = FindBestLinePlan(ai, token, ability, nil)
        if plan == nil or plan.allies > 0 then
            return nil, "no line catches enemies without allies"
        end
        local needed = cond(Malice() >= PYRO_WAVE_COST + 5, 2, 3)
        if plan.enemies < needed then
            return nil, string.format("only %d enemies in the best line", plan.enemies)
        end
        plan.score = 1.7 + 0.1*math.min(4, plan.enemies - needed)
        return plan
    end,
    execute = function(self, ai, token, scoringInfo, ability)
        MoveCinematically(ai, token, scoringInfo.loc)
        ai:Speech(token, speech.pyroWave)
        ai.Sleep(0.4)
        local area = BuildLineArea(token, ability, token.loc, scoringInfo.targetLoc)
        local targets = TokensInArea(token, ability, area)
        ExecuteAreaAbility(ai, token, ability, area, targets)
    end,
}

--------------------------------------------------------------------------------
-- Topaz Siphon: three spikes. The first cube is the ability's own target; the
-- second and third arrive as prompts, answered from the plan stored here.
--------------------------------------------------------------------------------

--charid -> list of {anchor} still to place this cast.
local g_pendingSpikes = {}

local function ExistingSpikes()
    return Encounter.GetTargetableObjectsWithKeyword(SPIKE_KEYWORD)
end

local function SquaresOf(area)
    local result = {}
    for _,loc in ipairs(area.locations or {}) do
        result[#result+1] = loc
    end
    return result
end

local function ChebyshevToSquares(loc, squares)
    local best = 999
    for _,sq in ipairs(squares) do
        best = math.min(best, math.max(math.abs(loc.x - sq.x), math.abs(loc.y - sq.y)))
    end
    return best
end

--Up to three non-overlapping 2 cubes. A cube is worth its occupants (each takes
--the eruption) plus every enemy it newly brings within 2 of a spike (each pays
--5 cold and a Malice at the start of the round). Allies and the dragon's own
--squares are avoided.
local function PlanSiphon(token, ability)
    local range = ability:GetRange(token.properties)
    local enemies = EnemyTokens(token)
    if #enemies == 0 then
        return nil
    end

    local blocked = {}
    for _,loc in ipairs(token:LocsOccupyingWhenAt(token.loc) or {}) do
        blocked[string.format("%d,%d", loc.x, loc.y)] = true
    end

    local covered = {}
    for _,enemy in ipairs(enemies) do
        if ExecuteGoblinScript(string.format('DistanceToObjectWithKeyword("%s")', SPIKE_KEYWORD), enemy.properties:LookupSymbol{}, 999, "Topaz AI") <= 2 then
            covered[enemy.charid] = true
        end
    end
    --existing spike footprints, as squares, so new cubes do not overlap them.
    for _,spike in ipairs(ExistingSpikes()) do
        for dx = -1, 1 do
            for dy = -1, 1 do
                local l = spike.loc:dir(dx, dy)
                blocked[string.format("%d,%d", l.x, l.y)] = true
            end
        end
    end

    local candidates = {}
    local seen = {}
    for _,enemy in ipairs(enemies) do
        for dx = -2, 1 do
            for dy = -2, 1 do
                local anchor = enemy.loc:dir(dx, dy)
                local key = string.format("%d,%d", anchor.x, anchor.y)
                if not seen[key] and token:Distance(anchor) <= range then
                    seen[key] = true
                    local area = BuildCubeArea(token, ability, anchor)
                    local squares = SquaresOf(area)
                    local ok = #squares > 0
                    for _,sq in ipairs(squares) do
                        if blocked[string.format("%d,%d", sq.x, sq.y)] or not sq.isOnMap then
                            ok = false
                        end
                    end
                    if ok then
                        local _, allies = CountByAllegiance(token, TokensInArea(token, ability, area))
                        if allies == 0 then
                            candidates[#candidates+1] = {anchor = anchor, area = area, squares = squares}
                        end
                    end
                end
            end
        end
    end

    local chosen = {}
    local total = 0
    for pick = 1, 3 do
        local best, bestValue = nil, nil
        for _,c in ipairs(candidates) do
            local overlaps = false
            for _,other in ipairs(chosen) do
                if ChebyshevToSquares(c.anchor, other.squares) <= 1 then
                    overlaps = true
                end
            end
            if not overlaps then
                local value = 0
                for _,enemy in ipairs(enemies) do
                    local distance = ChebyshevToSquares(enemy.loc, c.squares)
                    if distance == 0 then
                        value = value + 1
                    end
                    if distance <= 2 and not covered[enemy.charid] then
                        value = value + 0.6
                    end
                end
                if bestValue == nil or value > bestValue then
                    best, bestValue = c, value
                end
            end
        end
        if best == nil then
            break
        end
        chosen[#chosen+1] = best
        total = total + bestValue
        for _,enemy in ipairs(enemies) do
            if ChebyshevToSquares(enemy.loc, best.squares) <= 2 then
                covered[enemy.charid] = true
            end
        end
    end

    if #chosen == 0 then
        return nil
    end
    return {spikes = chosen, value = total}
end

MonsterAI:RegisterMove{
    id = "Topaz Dragon: Topaz Siphon",
    category = "Maneuvers",
    monsters = topazMonster,
    abilities = {"Topaz Siphon"},
    description = "Raise three topaz spikes on and around enemies so the round-start pulse drains them for Malice; stops adding spikes once the board is saturated.",
    score = function(self, ai, token, ability)
        if #ExistingSpikes() >= 6 then
            return nil, "six or more spikes already stand"
        end
        local plan = PlanSiphon(token, ability)
        if plan == nil or plan.value < 1 then
            return nil, "no spike placement reaches an enemy"
        end
        plan.score = 0.75 + 0.05*math.min(4, plan.value)
        return plan
    end,
    execute = function(self, ai, token, scoringInfo, ability)
        local spikes = scoringInfo.spikes
        local first = spikes[1]
        local pending = {}
        for i = 2, 3 do
            if spikes[i] ~= nil then
                pending[#pending+1] = spikes[i].anchor
            end
        end
        g_pendingSpikes[token.charid] = pending
        ai:Speech(token, speech.siphon)
        ai.Sleep(0.3)
        local area = BuildCubeArea(token, ability, first.anchor)
        ExecuteAreaAbility(ai, token, ability, area, TokensInArea(token, ability, area))
        g_pendingSpikes[token.charid] = nil
    end,
}

--The second and third spike. Topaz Siphon's own targetArea is passed down to its
--invokes, so the answer must carry the new cube as targetArea, not just a location.
MonsterAI:RegisterPrompt{
    prompts = {"Topaz Dragon:Topaz Siphon"},
    handler = function(ai, invokerToken, casterToken, abilityClone, symbols, options)
        local pending = g_pendingSpikes[casterToken.charid]
        local anchor = nil
        if pending ~= nil and #pending > 0 then
            anchor = table.remove(pending, 1)
        else
            --no plan (a Director-cast Siphon while the AI runs): place the best spot now.
            local plan = PlanSiphon(casterToken, abilityClone)
            anchor = plan ~= nil and plan.spikes[1].anchor or nil
        end
        if anchor == nil then
            return nil
        end
        local area = BuildCubeArea(casterToken, abilityClone, anchor)
        symbols.targetArea = area
        return {targets = TokensInArea(casterToken, abilityClone, area), targetArea = area}
    end,
}

--------------------------------------------------------------------------------
-- Start-of-turn Malice features.
--------------------------------------------------------------------------------

--Malice the dragon keeps back for Pyro Wave when three or more enemies are
--close enough to line up this turn.
local function MaliceReserve(token)
    local malice = Malice()
    if malice < PYRO_WAVE_COST then
        return 0
    end
    local near = 0
    for _,enemy in ipairs(EnemyTokens(token)) do
        if token:Distance(enemy) <= 11 then
            near = near + 1
        end
    end
    return cond(near >= 3, PYRO_WAVE_COST, 0)
end

local function CanSpareMalice(token, cost)
    return Malice() - cost >= MaliceReserve(token)
end

MonsterAI:RegisterMaliceAbility{
    id = "Topaz Dragon Malice: Solo Action",
    monsterGroups = topazGroup,
    abilities = {"Solo Action"},
    description = "Spend 5 Malice for an extra main action while enemies remain, unless it would leave too little for Pyro Wave.",
    score = function(self, ai, token, ability, context)
        if #context.enemyTokens == 0 then
            return nil, "no enemies"
        end
        if not CanSpareMalice(token, 5) then
            return nil, "keeping Malice for Pyro Wave"
        end
        return {score = 0.78}
    end,
}

MonsterAI:RegisterMaliceAbility{
    id = "Topaz Dragon Malice: Thermal Exchange",
    monsterGroups = topazGroup,
    abilities = {"Thermal Exchange"},
    description = "Sap a 3 cube holding two or more enemies: they are slowed (P<2) in difficult terrain, and it explodes next turn.",
    score = function(self, ai, token, ability, context)
        if not CanSpareMalice(token, 5) then
            return nil, "keeping Malice for Pyro Wave"
        end
        local plan = FindBestCubePlan(token, ability, function(area, targets)
            local slowable = 0
            for _,info in ipairs(targets) do
                local t = info.token
                if LiveCreature(t) and not t:IsFriend(token)
                    and t.properties:AttributeForPotencyResistance("prs") < 2 then
                    slowable = slowable + 1
                end
            end
            return slowable*0.3
        end)
        if plan == nil or plan.allies > 0 or plan.enemies < 2 then
            return nil, "no 3 cube holds two or more enemies without allies"
        end
        return {score = math.min(0.9, 0.62 + 0.06*plan.enemies), anchor = plan.anchor}
    end,
    execute = function(self, ai, token, scoringInfo, ability, context)
        local area = BuildCubeArea(token, ability, scoringInfo.anchor)
        ExecuteAreaAbility(ai, token, ability, area, TokensInArea(token, ability, area))
    end,
}

MonsterAI:RegisterMaliceAbility{
    id = "Topaz Dragon Malice: Psi Boost",
    monsterGroups = topazGroup,
    abilities = {"Psi Boost"},
    description = "Spend 3 Malice to empower the next psionic ability: +2 damage per target when enemies are clustered, otherwise a double edge.",
    minimumScore = 0.65,
    score = function(self, ai, token, ability, context)
        if #context.enemyTokens == 0 then
            return nil, "no enemies"
        end
        if not CanSpareMalice(token, 3) then
            return nil, "keeping Malice for Pyro Wave"
        end
        --boosts only help an ability the dragon can use this turn.
        local inReach = 0
        for _,enemy in ipairs(context.enemyTokens) do
            if token:Distance(enemy) <= 5 + token.properties:CurrentMovementSpeed() then
                inReach = inReach + 1
            end
        end
        if inReach == 0 then
            return nil, "no enemy within reach of a psionic ability this turn"
        end
        local mode = cond(inReach >= 3, 2, 1)
        return {score = 0.67, mode = mode}
    end,
    execute = function(self, ai, token, scoringInfo, ability, context)
        ai:ExecuteAbility(token, ability, nil, {sleep = 0.5, symbols = {mode = scoringInfo.mode}})
    end,
}

--------------------------------------------------------------------------------
-- Villain actions.
--------------------------------------------------------------------------------

MonsterAI:RegisterVillainAction{
    id = "Topaz Dragon: Heat Death",
    monsters = topazMonster,
    abilities = {"Heat Death"},
    description = "Drain the heat from the 4 cube holding the most enemies, especially flying ones.",
    score = function(self, ai, token, ability, context)
        local plan = FindBestCubePlan(token, ability, function(area, targets)
            local midair = 0
            for _,info in ipairs(targets) do
                if not info.token:IsFriend(token) and (tonumber(ExecuteGoblinScript("FloorAltitude", info.token.properties:LookupSymbol{}, 0, "Topaz AI")) or 0) > 0 then
                    midair = midair + 1
                end
            end
            return midair*0.5
        end)
        if plan == nil then
            return nil
        end
        return {score = math.min(1, 0.4 + 0.15*plan.value), anchor = plan.anchor}
    end,
    execute = function(self, ai, token, scoringInfo, ability, context)
        ai:Speech(token, speech.heatDeath)
        ai.Sleep(0.4)
        local area = BuildCubeArea(token, ability, scoringInfo.anchor)
        ExecuteAreaAbility(ai, token, ability, area, TokensInArea(token, ability, area))
    end,
}

MonsterAI:RegisterVillainAction{
    id = "Topaz Dragon: Topaz Flare",
    monsters = topazMonster,
    abilities = {"Topaz Flare"},
    description = "Expand the field to a 5 aura that explodes each round, sooner when enemies already crowd within 5.",
    score = function(self, ai, token, ability, context)
        local near = 0
        for _,enemy in ipairs(EnemyTokens(token)) do
            if token:Distance(enemy) <= 5 then
                near = near + 1
            end
        end
        return {score = math.min(1, 0.45 + 0.12*near)}
    end,
    execute = function(self, ai, token, scoringInfo, ability, context)
        ai:Speech(token, speech.topazFlare)
        ai.Sleep(0.4)
        ai:ExecuteAbility(token, ability, nil, {sleep = abilityPause})
    end,
}

MonsterAI:RegisterVillainAction{
    id = "Topaz Dragon: Absolute Zero",
    monsters = topazMonster,
    abilities = {"Absolute Zero"},
    description = "Encase itself in 50 temporary Stamina, more urgently the more Stamina it has lost.",
    score = function(self, ai, token, ability, context)
        local p = token.properties
        local lost = 1 - p:CurrentHitpoints()/math.max(1, p:MaxHitpoints())
        return {score = math.min(1, 0.35 + lost)}
    end,
    execute = function(self, ai, token, scoringInfo, ability, context)
        ai:Speech(token, speech.absoluteZero)
        ai.Sleep(0.4)
        ai:ExecuteAbility(token, ability, nil, {sleep = abilityPause})
    end,
}

--------------------------------------------------------------------------------
-- Triggered actions.
--------------------------------------------------------------------------------

local function TriggeredActionAvailable(token)
    local p = token.properties
    local available = (p:GetResources()[TRIGGERED_ACTION] or 0) - p:GetResourceUsage(TRIGGERED_ACTION, "round")
    return available > 0
end

--Both Absorption triggers (the triggered action and the 2+ Malice free version)
--show the text "Absorption", so one handler serves both; the Malice version is
--the one whose ActiveTrigger carries a Malice cost.
--The trigger cannot see the incoming damage type, so the dragon always takes
--the energy in (mode 2 = the "Absorb the Energy" option): turning its own rays
--to the attacker's element is the stat block's intent, and the halving is the same.
MonsterAI:RegisterTrigger{
    id = "Topaz Dragon: Absorption",
    monsters = topazMonster,
    triggers = {"Absorption"},
    description = "Halve typed damage with the triggered action, absorbing the energy into Rays Ignis and Pyro Wave. Pay Malice for the free version only once the triggered action is spent, and only with Malice to spare (or when winded).",
    handler = function(ai, token, triggerInfo)
        local cost = tonumber(triggerInfo.heroicResourceCost) or 0
        if cost <= 0 then
            return {activate = true, mode = 2}
        end
        if TriggeredActionAvailable(token) then
            return {dismiss = true}
        end
        local malice = Malice()
        local winded = token.properties:CurrentHitpoints() <= token.properties:MaxHitpoints()/2
        if malice >= cost and (winded or malice - cost >= 5) then
            return {activate = true, mode = 2}
        end
        return {dismiss = true}
    end,
}

--Collapsing the field costs no Stamina, so it is worth it for anything End
--Effect would end; the shared decision rates the effects.
MonsterAI:RegisterTrigger{
    id = "Topaz Dragon: Collapse Topaz Field",
    monsters = topazMonster,
    abilities = {"Collapse Topaz Field"},
    triggers = {"Collapse Topaz Field"},
    description = "Shrink the field by 2 at the start of the turn to end a save-ends effect bad enough to be worth ending.",
    handler = function(ai, token, triggerInfo)
        if FieldSize(token) < 2 then
            return {dismiss = true}
        end
        local decision = MonsterAI.EndEffectDecision(token, triggerInfo)
        return decision
    end,
}
