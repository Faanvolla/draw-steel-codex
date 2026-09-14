--Run from the codex root: ../dependencies/lua/bin/lua.exe tests/ai_minion_critical_test.lua
--Exercise the real action cycle, selection and squad planning with simulated casts.
local file = assert(io.open("Monster AI/MonsterAI.lua", "r"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local function section(first, last)
    local start = assert(source:find(first, 1, true))
    return source:sub(start, assert(source:find(last, start + #first, true)) - 1)
end
local function noop() end
local function try_get(self, key, default)
    local value = self[key]
    if value == nil then return default end
    return value
end
function FindAbilityByName(abilities, name)
    for _,ability in ipairs(abilities) do
        if ability.name == name then return ability end
    end
end
function RunYieldingFunction(fn) return pcall(fn) end
function AIAbilityUnavailableReason() return "no action" end
table.values = function(t) local r = {}; for _,v in pairs(t) do r[#r+1] = v end; return r end
MonsterAI = {
    try_get = try_get,
    TokenIsLiveCombatant = function(t) return t ~= nil and t.valid end,
    TokenLogName = function(t) return t.name end,
    LocLogName = tostring, TargetsLogName = function() return "targets" end,
    AbilityActionLogName = function() return "Main Action" end,
    LogDecision = noop, LogMove = noop, SetLogContext = noop, SetMoveLogContext = noop,
    RefreshCombatants = noop, Sleep = noop,
}
local prefix = 'local g_moveResultExecuted="executed"; local g_moveResultNone="none"; local g_moveResultUnsafe="unsafe";\n'
assert(load(section("function MonsterAI:FindSquadActionToken()", "function MonsterAI:PlayTurnCoroutine")))()
assert(load(section("function MonsterAI:ExecuteSquadStrike(ability)", "function MonsterAI:FindBestMoveToUseStrike")))()
assert(load(section("function MonsterAI:CalculateRemainingMovementPaths", "function MonsterAI:CountPendingActivityReactions")))()
assert(load(prefix .. section("function MonsterAI:FindAndExecuteMove()", "function MonsterAI:ExecuteAbility(")))()
local runCycles = assert(load(prefix .. "return function(self, token, queue, initiativeid, squadid)\n" ..
    section("                    for cycle=1,6 do", "\n                end)") .. "\nend"))()

local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function fixture(count)
    local tokens, members, casts = {}, {}, {}
    local enemy = {charid = "enemy", name = "enemy", valid = true}
    tokens.enemy = enemy
    dmhub = {
        initiativeQueue = {hidden = false, round = 1},
        GetTokenById = function(id) return tokens[id] end,
        Schedule = function(_, fn) fn() end,
        MarkLineOfSight = function() return {DestroyLineOfSight = noop} end,
    }
    local ability = {name = "Whistling Axes", categorization = "Signature Ability"}
    function ability:CanAfford(t) return t.actions > 0 end
    for i=1,count do
        local t = {charid = tostring(i), name = "Minion " .. i, valid = true, actions = 1, moved = 0, loc = "start"}
        t.properties = {minion = true, monster_type = "Dwarf Axethrower", try_get = try_get,
            has_key = function(self, key) return self[key] ~= nil end,
            GetActivatedAbilities = function() return {ability} end,
            CurrentMovementSpeed = function() return 5 end,
            DistanceMovedThisTurn = function() return t.moved end,
            GetPierceWalls = function() return 0 end}
        tokens[t.charid] = t
        members[#members+1] = {token = t}
    end
    local ai = setmetatable({squadMembers = members, squadCaptain = false, casts = casts,
        pathBudgets = {}, moveCounts = {}, _tmp_failedMoves = {}}, {__index = MonsterAI})
    function ai:SetupCombatants(t) self.token = t; self.abilities = t.properties:GetActivatedAbilities() end
    function ai:GetMovementToken(t) return t end
    function ai:CalculateMovementPaths(t, budget)
        self.pathBudgets[#self.pathBudgets+1] = {token = t, budget = budget}
        return {{loc = budget > 0 and "attack position" or t.loc, cost = budget}}
    end
    function ai:FindSquadMemberStrikeOptions(member)
        if self.noTargets then return {} end
        return {{token = enemy, loc = member.paths[1].loc, cost = 0}}
    end
    function ai:MoveToken(t, loc)
        self.moveCounts[t.charid] = (self.moveCounts[t.charid] or 0) + 1
        t.loc = loc; t.moved = 5
        if self.afterMove then self.afterMove(t) end
        return nil, t.valid
    end
    function ai:ExecuteAbility(caster, _, _, options)
        local ids = {}
        for _,pair in ipairs(options.symbols.targetPairs) do
            local t = tokens[pair.a]
            check(t.valid and t.actions > 0, "every attacker must be alive and able to pay")
            t.actions = t.actions - 1
            ids[#ids+1] = t.charid
        end
        casts[#casts+1] = {caster = caster.charid, ids = ids}
        --The normal critical-hit rule restores a Main Action after the cast.
        if self.afterCast then self.afterCast(#casts, tokens) end
    end
    return ai, tokens, function()
        runCycles(ai, members[1].token, dmhub.initiativeQueue, "turn", "squad")
    end
end

local ai, tokens, run = fixture(1)
ai.afterCast = function(n) if n == 1 then tokens["1"].actions = 1 end end
run()
check(#ai.casts == 2, "single minion uses its critical-hit action")
check(tokens["1"].actions == 0, "extra action is spent")
check(ai.pathBudgets[#ai.pathBudgets].budget == 0, "critical does not restore movement")

ai, tokens, run = fixture(3)
ai.afterCast = function(n) if n == 1 then tokens["2"].actions = 1 end end
run()
check(#ai.casts == 2 and ai.casts[2].caster == "2", "critical on another squad member selects that actor")
check(#ai.casts[2].ids == 1 and ai.casts[2].ids[1] == "2", "spent squadmates cannot join the extra strike")
check(ai.moveCounts["1"] == 1 and ai.moveCounts["3"] == 1, "spent squadmates cannot move again")

ai, tokens, run = fixture(2)
run()
check(#ai.casts == 1, "ordinary squad turn still strikes once")

ai, tokens, run = fixture(2)
tokens["1"].actions = 0
run()
check(#ai.casts == 1 and ai.casts[1].caster == "2", "spent initial actor does not block another member")
check(#ai.casts[1].ids == 1, "initial planning also checks each member's resources")

ai, tokens, run = fixture(2)
ai.afterCast = function(n)
    if n == 1 then tokens["2"].actions = 1; tokens["1"].valid = false end
end
run()
check(#ai.casts == 2, "dead initial actor does not block surviving critical recipient")

ai, tokens, run = fixture(2)
ai.afterMove = function(t) if t.charid == "2" then tokens["1"].actions = 0 end end
run()
check(#ai.casts == 1 and #ai.casts[1].ids == 1, "reaction spending an action removes an earlier assignment")

ai, tokens, run = fixture(1)
ai.afterCast = function(n) if n < 3 then tokens["1"].actions = 1 end end
run()
check(#ai.casts == 3, "chained critical hits use successive extra actions")

ai, tokens, run = fixture(1)
ai.afterCast = function() tokens["1"].actions = 1 end
run()
check(#ai.casts == 6, "existing six-cycle safety cap remains")

ai, tokens, run = fixture(1)
ai.noTargets = true
run()
check(#ai.casts == 0 and ai.moveCounts["1"] == nil, "no legal targets ends the squad turn")

ai, tokens, run = fixture(1)
ai.afterCast = function() tokens["1"].actions = 1; ai._tmp_abortTurn = true end
run()
check(#ai.casts == 1, "stop request prevents the extra action")
print(string.format("PASS: %d minion critical-hit checks", checks))
