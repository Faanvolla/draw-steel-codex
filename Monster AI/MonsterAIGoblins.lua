local mod = dmhub.GetModLoading()

MonsterAI:RegisterTactic{
    id = "Goblin Sniper: Hold Position",
    monsters = {"Goblin Sniper"},
    description = "Snipers shoot without moving whenever possible, spreading fire among targets reachable from their current positions.",
    score = function(self, token, tokenLoc, enemy, ability)
        if token.properties:try_get("monster_type", "") ~= "Goblin Sniper"
            or ability.name ~= "Bow" then
            return
        end

        -- Target evaluation temporarily relocates the token. The zero-cost
        -- squad path still identifies its actual position before that probe.
        for _,member in ipairs(self.squadMembers) do
            if member.token.charid == token.charid then
                for _,path in pairs(member.paths or {}) do
                    if path.cost == 0 and path.loc.str == tokenLoc.str then
                        -- Outweigh movement bonuses and the 10000 repeat-target
                        -- penalty; stationary targets still use normal squad rules.
                        return 100000
                    end
                end
                return
            end
        end
    end,
}
