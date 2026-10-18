local mod = dmhub.GetModLoading()

local undeadGroup = {"Undead"}

local movementPause = 0.6
local abilityPause = 1.0

local dreadMarchBaseCost = 7
local dreadMarchBaseUndead = 4

local function LiveCreature(token)
    return token ~= nil and token.valid and not token.isObject
        and token.properties ~= nil and not token.properties:IsDead()
end

local function IsMinion(token)
    return token.properties:try_get("minion", false) == true
end

local function IsUndead(token)
    local keywords = token.properties:try_get("keywords")
    return type(keywords) == "table" and keywords["Undead"] == true
end

local function LocKey(loc)
    return loc.xyfloorOnly.str
end

--Maps can hold props and bystanders who are not in the fight.
local function InCombat(token)
    local queue = dmhub.initiativeQueue
    if queue == nil or queue.hidden then
        return true
    end
    local initiativeid = InitiativeQueue.GetInitiativeId(token)
    return initiativeid ~= nil and queue.entries[initiativeid] ~= nil
end

local function HostileCreatures(token)
    local result = {}
    for _,other in ipairs(dmhub.allTokens) do
        if LiveCreature(other) and not other:IsFriend(token) and InCombat(other) then
            result[#result+1] = other
        end
    end
    return result
end

local function FriendlyCreatures(token)
    local result = {}
    for _,other in ipairs(dmhub.allTokens) do
        if LiveCreature(other) and other:IsFriend(token) and InCombat(other) then
            result[#result+1] = other
        end
    end
    return result
end

local function CanSee(token, target)
    return token:GetLineOfSight(target, token.properties:GetPierceWalls()) > 0
end

local function FreeStrikeReach(token)
    local reach = 1
    for _,ability in ipairs(token.properties:GetActivatedAbilities()) do
        if ability.name == "Melee Free Strike" or ability.name == "Ranged Free Strike" then
            reach = math.max(reach, ability:GetRange(token.properties))
        end
    end
    return reach
end

local function NearestEnemyDistance(token, enemies)
    local nearest = math.huge
    for _,enemy in ipairs(enemies) do
        nearest = math.min(nearest, MonsterAI.TargetDistance(token, enemy))
    end
    return nearest
end

local function LandingIsFree(token, loc, reserved)
    if loc == nil or not loc.valid then
        return false
    end
    for _,occupied in ipairs(token:LocsOccupyingWhenAt(loc)) do
        if reserved[LocKey(occupied)] then
            return false
        end
        for _,other in ipairs(dmhub.GetTokensAtLoc(occupied) or {}) do
            if other.valid and other.charid ~= token.charid and not other.isObject then
                return false
            end
        end
    end
    return true
end

local function ReserveLanding(token, loc, reserved)
    for _,occupied in ipairs(token:LocsOccupyingWhenAt(loc)) do
        reserved[LocKey(occupied)] = true
    end
end

--Without this, the move and free strike prompts of marching undead go to the Director.
local function WithControlOf(ai, tokens, fn)
    local controls = {}
    for _,tok in ipairs(tokens) do
        if LiveCreature(tok) then
            controls[#controls+1] = {token = tok, info = ai:BeginTokenControl(tok)}
        end
    end
    local ok, err = ai:RunYieldingFunction(fn)
    for _,control in ipairs(controls) do
        pcall(function()
            ai:EndTokenControl(control.token, control.info)
        end)
    end
    if not ok then
        error(err)
    end
end

local g_hordeRoundByEncounter = {}

local function HordeTargets(token, ability, context)
    local result = {}
    for _,enemy in ipairs(context.enemyTokens or {}) do
        if LiveCreature(enemy) and enemy.properties:IsHero()
            and ability:TargetPassesFilter(token, enemy, {}) then
            result[#result+1] = enemy
        end
    end
    return result
end

local function ExecuteMapAbility(ai, caster, ability, targetTokens)
    local area = dmhub.CalculateShape{
        shape = "map",
        token = caster,
    }
    local targets = {}
    for _,target in ipairs(targetTokens) do
        targets[#targets+1] = {token = target}
    end
    ai:ExecuteAbility(caster, DeepCopy(ability), targets, {
        sleep = abilityPause,
        symbols = {targetArea = area},
        targetArea = area,
    })
end

MonsterAI:RegisterMaliceAbility{
    id = "Undead Malice: Ravenous Horde",
    monsterGroups = undeadGroup,
    abilities = {"Ravenous Horde"},
    description = "Spend 2 Malice to raise two rotting zombies next to each hero who has no enemy beside them. Never two rounds in a row.",
    score = function(self, ai, token, ability, context)
        local queue = context.initiativeQueue
        local round = context.round or 0
        local lastRound = queue ~= nil and g_hordeRoundByEncounter[queue.guid] or nil
        if lastRound ~= nil and round - lastRound <= 1 then
            return nil, "used this round or last round"
        end
        local targets = HordeTargets(token, ability, context)
        if #targets == 0 then
            return nil, "every hero already has an enemy beside them"
        end
        return {score = math.min(0.95, 0.62 + 0.07*#targets), heroes = #targets}
    end,
    execute = function(self, ai, token, scoringInfo, ability, context)
        local targets = HordeTargets(token, ability, context)
        if #targets == 0 then
            return
        end
        local maliceBefore = CharacterResource.GetMalice()
        ExecuteMapAbility(ai, token, ability, targets)
        --A cancelled cast does not count, so Ravenous Horde can still be used next round.
        local queue = context.initiativeQueue
        if queue ~= nil and CharacterResource.GetMalice() < maliceBefore then
            g_hordeRoundByEncounter[queue.guid] = context.round or 0
        end
    end,
}

local g_march = nil

local function MarchCandidates(token, ability, context)
    local enemies = {}
    for _,enemy in ipairs(context.enemyTokens or {}) do
        if LiveCreature(enemy) then
            enemies[#enemies+1] = enemy
        end
    end
    if #enemies == 0 then
        return {}, 0
    end

    local acting = {}
    for _,actor in ipairs(context.actingTokens or {}) do
        acting[actor.charid] = true
    end

    local candidates = {}
    local reachable = 0
    for _,undead in ipairs(FriendlyCreatures(token)) do
        --The march is refused if the caster cannot see every undead, so leave unseen ones out.
        if IsUndead(undead) and not undead.playerControlled
            and ability:TargetPassesFilter(token, undead, {})
            and (undead.charid == token.charid or CanSee(token, undead)) then
            local speed = undead.properties:CurrentMovementSpeed() or 0
            local nearest = NearestEnemyDistance(undead, enemies)
            --A rough straight-line guess; the move prompt finds the real path.
            local canReach = nearest <= speed + FreeStrikeReach(undead)
            local value = 0.1
            if canReach then
                reachable = reachable + 1
                value = cond(IsMinion(undead), 1, 1.5) + cond(acting[undead.charid], 0, 0.2)
            end
            candidates[#candidates+1] = {token = undead, value = value, nearest = nearest, canReach = canReach}
        end
    end
    table.sort(candidates, function(a, b)
        if a.value ~= b.value then
            return a.value > b.value
        end
        return a.nearest < b.nearest
    end)
    return candidates, reachable
end

local function MarchPlan(token, ability, context)
    local candidates, reachable = MarchCandidates(token, ability, context)
    local extraMalice = math.max(0, (context.malice or 0) - dreadMarchBaseCost)
    local count = math.max(dreadMarchBaseUndead, reachable)
    count = math.min(count, dreadMarchBaseUndead + extraMalice, #candidates)
    local chosen = {}
    local reaching = 0
    for i=1,count do
        chosen[#chosen+1] = candidates[i].token
        if candidates[i].canReach then
            reaching = reaching + 1
        end
    end
    return {
        undead = chosen,
        reaching = reaching,
        charges = math.max(0, count - dreadMarchBaseUndead),
    }
end

--Every creature has a ranged free strike, so without this melee undead would shoot from afar instead of closing in.
local function MarchProfile(token)
    local melee = true
    for _,ability in ipairs(token.properties:GetActivatedAbilities()) do
        if ability.categorization == "Signature Ability" then
            melee = ability:HasKeyword("Melee") and not ability:HasKeyword("Ranged")
            break
        end
    end
    if melee then
        return {melee = true, reach = 1}
    end
    return {melee = false, reach = FreeStrikeReach(token)}
end

local function MarchMovePrompt(ai, invokerToken, casterToken, abilityClone, symbols, options)
    if g_march == nil or not g_march.participants[casterToken.charid]
        or casterToken.playerControlled then
        return nil
    end
    local enemies = HostileCreatures(casterToken)
    if #enemies == 0 then
        return {targets = {}}
    end
    local profile = MarchProfile(casterToken)
    local reach = profile.reach

    local function SquareUtility(loc, target, nearest)
        local utility = -nearest
        if nearest <= reach then
            utility = 10 + MonsterAI.TargetStaminaBias(target)
            if not profile.melee and nearest <= 1 then
                utility = utility - 3
            end
        end
        return utility
    end

    local function NearestAt(loc)
        local target = enemies[1]
        local nearest = target:Distance(loc)
        for _,enemy in ipairs(enemies) do
            local dist = enemy:Distance(loc)
            if dist < nearest then
                nearest = dist
                target = enemy
            end
        end
        return target, nearest
    end

    local here, hereDist = NearestAt(casterToken.loc)
    local hereUtility = SquareUtility(casterToken.loc, here, hereDist)
    if hereDist <= reach and CanSee(casterToken, here) and (profile.melee or hereDist > 1) then
        return {targets = {}}
    end

    local range = abilityClone:GetRange(casterToken.properties, symbols)
    local reserved = g_march.reserved
    local candidates = {}
    for _,info in pairs(casterToken:CalculatePathfindingArea(range*10, {})) do
        local loc = info.loc
        if loc ~= nil and LocKey(loc) ~= LocKey(casterToken.loc) and LandingIsFree(casterToken, loc, reserved) then
            local target, nearest = NearestAt(loc)
            candidates[#candidates+1] = {
                loc = loc,
                target = target,
                inReach = nearest <= reach,
                utility = SquareUtility(loc, target, nearest) - (info.cost or 0)*0.002,
            }
        end
    end
    table.sort(candidates, function(a, b) return a.utility > b.utility end)

    local best = nil
    for i=1,math.min(10, #candidates) do
        local candidate = candidates[i]
        if not candidate.inReach then
            best = best or candidate
            break
        end
        local visible = false
        ai:ExecuteWithTheoreticalMovementLoc(casterToken, candidate.loc, function()
            visible = CanSee(casterToken, candidate.target)
        end)
        if visible then
            best = candidate
            break
        end
        best = best or candidate
    end
    if best == nil or best.utility <= hereUtility then
        return {targets = {}}
    end

    ReserveLanding(casterToken, best.loc, reserved)
    casterToken:MarkMovementArrow(best.loc, {straightline = false, ignorecreatures = false})
    MonsterAI.Sleep(movementPause)
    casterToken:ClearMovementArrow()
    return {targets = {{loc = best.loc}}}
end

--Each marching undead is asked to target itself before it moves; answer that for it.
local function MarchWrapperPrompt(ai, invokerToken, casterToken, abilityClone, symbols, options)
    if g_march == nil or not g_march.participants[casterToken.charid]
        or abilityClone.targetType ~= "self" then
        return nil
    end
    return {targets = {{token = casterToken}}}
end

--Keep any handler already under this name (the Decrepit Skeleton's) and pass it every prompt that is not part of a march.
local function InstallMarchPrompt(name, marchHandler)
    local existing = MonsterAI.prompts[name]
    if existing ~= nil and existing.undeadMarch then
        return
    end
    MonsterAI:RegisterPrompt{
        id = existing ~= nil and existing.id or "Undead: Dread March",
        undeadMarch = true,
        prompts = {name},
        handler = function(ai, invokerToken, casterToken, abilityClone, symbols, options)
            local result = marchHandler(ai, invokerToken, casterToken, abilityClone, symbols, options)
            if result == nil and existing ~= nil then
                return existing.handler(ai, invokerToken, casterToken, abilityClone, symbols, options)
            end
            return result
        end,
    }
end

local function RegisterMarchPrompts(tokens)
    for _,tok in ipairs(tokens) do
        local monsterType = tok.properties:try_get("monster_type", "")
        InstallMarchPrompt(monsterType .. ":Move Speed", MarchMovePrompt)
        InstallMarchPrompt(monsterType .. ":Invoked Ability", MarchWrapperPrompt)
    end
end

MonsterAI:RegisterMaliceAbility{
    id = "Undead Malice: Dread March",
    monsterGroups = undeadGroup,
    abilities = {"Dread March"},
    description = "Spend 7+ Malice to move four or more undead up to their speed into free strikes, when at least three of them can reach a hero.",
    score = function(self, ai, token, ability, context)
        local plan = MarchPlan(token, ability, context)
        if plan.reaching < 3 then
            return nil, string.format("only %d undead can reach a hero", plan.reaching)
        end
        --Not "targets": the decision log reads that field as a target list.
        return {
            score = math.min(0.95, 0.62 + 0.06*plan.reaching),
            marching = #plan.undead,
            reaching = plan.reaching,
            extraMalice = plan.charges,
        }
    end,
    execute = function(self, ai, token, scoringInfo, ability, context)
        context.malice = CharacterResource.GetMalice()
        local plan = MarchPlan(token, ability, context)
        if #plan.undead == 0 then
            return
        end

        local targets = {}
        local participants = {}
        for _,undead in ipairs(plan.undead) do
            targets[#targets+1] = {token = undead}
            participants[undead.charid] = true
        end

        local promptTokens = {token}
        for _,undead in ipairs(plan.undead) do
            promptTokens[#promptTokens+1] = undead
        end
        RegisterMarchPrompts(promptTokens)

        --Its target count is "Charges + 4", which the AI would read as 4, so set it on a copy.
        local march = ability:MakeTemporaryClone()
        march.numTargets = tostring(#targets)

        local maliceBefore = CharacterResource.GetMalice()
        g_march = {participants = participants, reserved = {}}
        local ok, err = ai:RunYieldingFunction(function()
            WithControlOf(ai, plan.undead, function()
                ai:ExecuteAbility(token, march, targets, {
                    symbols = {charges = plan.charges},
                    sleep = abilityPause,
                })
            end)
        end)
        g_march = nil
        if not ok then
            error(err)
        end

        --AI casts only pay the base 7 Malice, so pay for the extra undead here.
        local malice = CharacterResource.GetMalice()
        if plan.charges > 0 and malice <= maliceBefore - dreadMarchBaseCost then
            CharacterResource.SetMalice(malice - plan.charges,
                string.format("Dread March: %d extra undead", plan.charges))
        end
    end,
}

--The arms reach one square past the 3x3 block, so anything within 2 of the centre gets grabbed, undead too.
local graspingReach = 2

local function GraspingPlan(token, context)
    local enemies = {}
    for _,enemy in ipairs(context.enemyTokens or {}) do
        if LiveCreature(enemy) then
            enemies[#enemies+1] = enemy
        end
    end
    local allies = FriendlyCreatures(token)

    local seen = {}
    local best = nil
    for _,enemy in ipairs(enemies) do
        for dx=-graspingReach,graspingReach do
            for dy=-graspingReach,graspingReach do
                local center = enemy.loc:dir(dx, dy)
                local key = center.valid and LocKey(center) or nil
                if key ~= nil and not seen[key] then
                    seen[key] = true
                    local squares = {}
                    for sx=-1,1 do
                        for sy=-1,1 do
                            local square = center:dir(sx, sy)
                            if square.valid and square.isOnMap then
                                squares[#squares+1] = square
                            end
                        end
                    end
                    if #squares == 9 then
                        local caught = 0
                        local value = 0
                        for _,other in ipairs(enemies) do
                            if other:Distance(center) <= graspingReach then
                                caught = caught + 1
                                value = value + 1
                            end
                        end
                        for _,ally in ipairs(allies) do
                            if ally:Distance(center) <= graspingReach then
                                value = value - cond(IsMinion(ally), 0.6, 1)
                            end
                        end
                        if caught >= 2 and (best == nil or value > best.value) then
                            best = {center = center, squares = squares, caught = caught, value = value}
                        end
                    end
                end
            end
        end
    end
    return best
end

MonsterAI:RegisterMaliceAbility{
    id = "Undead Malice: The Grasping, the Hungry",
    monsterGroups = undeadGroup,
    abilities = {"The Grasping, the Hungry"},
    description = "Spend 5 Malice to raise grasping arms where at least two enemies, and few undead, would end their turns next to them.",
    score = function(self, ai, token, ability, context)
        local plan = GraspingPlan(token, context)
        if plan == nil or plan.value < 1.5 then
            return nil, "no spot catches two enemies without catching undead"
        end
        return {
            score = math.min(0.9, 0.58 + 0.07*plan.value),
            caught = plan.caught,
            center = plan.center,
        }
    end,
    execute = function(self, ai, token, scoringInfo, ability, context)
        local plan = GraspingPlan(token, context)
        if plan == nil then
            return
        end
        local area = dmhub.CalculateShape{
            shape = "locations",
            token = token,
            locations = plan.squares,
            checklos = false,
        }
        local targets = {}
        for _,square in ipairs(plan.squares) do
            targets[#targets+1] = {loc = square}
        end
        ai:ExecuteAbility(token, ability, targets, {
            sleep = abilityPause,
            symbols = {targetArea = area},
            targetArea = area,
        })
    end,
}
