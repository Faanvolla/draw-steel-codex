--Run from the codex root with ../dependencies/lua/bin/lua.exe tests/encounter_script_test.lua
--Exercises the pure Encounter of the Week script parser against the sample
--script from EncounterOfTheWeek.md and a few edge cases.
dofile("DMHub Game Rules/TestRiders.lua")
dofile("EncounterOfTheWeek/EncounterScript.lua")

local passed = 0
local function check(condition, message)
    if not condition then
        error("FAILED: " .. tostring(message), 2)
    end
    passed = passed + 1
end

local SAMPLE = [==[
# Montage

[[scene]]

## Round 1

## Opportunity: Mysterious Cottage

A mysterious cottage lays off the path. Dare you approach?

Options: Approaching the cottage, you see a witch within, brewing some potions in her cauldron.

### Negotiate with her for some aid

|Negotiation Test: Presence (Empathize, Lie, Flirt)
|You fail at the test
|You gain one Healing Potion
|Each party member gains one Healing Potion

### Steal some potions

|Thievery Test: Agility (Climb, Disguise, Sneak)
|You lose 6 Stamina.
|You lose 6 Stamina. Each party members gains one Healing Potion.
|Each party members gains one Healing Potion

## Opportunity: Elvish Village

An Elvish Village is nestled in the forest. Approach and ask for aid?

Options: Approaching the village you ask them for aid against dangers ahead.

### Ask for Aid

|Negotiation Test: Presence (Empathize, Nature)
|You fail at the test
|A Wode Elf Sentry joins you. +2 Malice
|A Wode Elf Sentry joins you

## Threat: Dangerous Beasts

Dangerous beasts lurk in the forest, a constant threat.

Consequence: Each party member loses 5 stamina.

Options: You try to deal with the threat.

### Hunt the Beasts

|Hunting Test: Might or Agility (Endurance, Track)
|You lose 5 stamina.
|You lose 5 stamina, the threat is vanquished.
|The threat is vanquished.

### Outsmart the Beasts


|Strategy Test: Reason (Strategy, Animal Handling)
|You fail at the test.
|+2 malice, the threat is vanquished.
|The threat is vanquished.


# Encounter

[[encounter]]
]==]

--- the sample script --------------------------------------------------------
local parse = EncounterScript.Parse(SAMPLE)
check(#parse.warnings == 0, "sample parses with no warnings: " .. table.concat(parse.warnings, " | "))
check(#parse.beats == 2, "two beats")
check(parse.beats[1].kind == "montage", "first beat is the montage")
check(parse.beats[2].kind == "encounter", "second beat is the encounter")
check(parse.beats[2].encounterTag == "encounter", "encounter beat carries its island tag")
check(parse.hasEncounterTag, "encounter tag seen")

local montage = parse.beats[1]
check(montage.sceneTag == "scene", "scene tag captured")
check(#montage.rounds == 1 and montage.rounds[1].number == 1, "one explicit round")
check(EncounterScript.RoundCount(montage) == 1, "round count 1")
local entries = montage.rounds[1].entries
check(#entries == 3, "three entries in round 1")

local cottage = entries[1]
check(cottage.kind == "opportunity" and cottage.name == "Mysterious Cottage", "cottage entry")
check(cottage.id == "r1/opportunity/mysterious-cottage", "stable entry id: " .. cottage.id)
check(cottage.description == "A mysterious cottage lays off the path. Dare you approach?", "cottage description")
check(cottage.approach == "Approaching the cottage, you see a witch within, brewing some potions in her cauldron.", "cottage approach text")
check(cottage.consequence == nil, "opportunities have no consequence")
check(#cottage.options == 2, "two cottage options")

local negotiate = cottage.options[1]
check(negotiate.name == "Negotiate with her for some aid", "option name")
check(negotiate.roll ~= nil, "option has a roll")
check(negotiate.roll.name == "Negotiation Test", "roll name")
check(negotiate.roll.attr == "Presence (Empathize, Lie, Flirt)", "roll attr")
check(#negotiate.roll.tiers == 3, "three tiers")
check(negotiate.roll.effects[1][1].kind == "narrative" and not negotiate.roll.effects[1][1].unrecognized, "fail clause is recognized narrative")
local t2 = negotiate.roll.effects[2]
check(#t2 == 1 and t2[1].kind == "item" and t2[1].target == "self" and t2[1].qty == 1 and t2[1].name == "Healing Potion", "tier 2: you gain one Healing Potion")
local t3 = negotiate.roll.effects[3]
check(#t3 == 1 and t3[1].kind == "item" and t3[1].target == "party" and t3[1].qty == 1 and t3[1].name == "Healing Potion", "tier 3: each party member gains one Healing Potion")

local steal = cottage.options[2]
local s2 = steal.roll.effects[2]
check(#s2 == 2, "tier 2 of steal has two clauses")
check(s2[1].kind == "stamina" and s2[1].target == "self" and s2[1].qty == 6, "you lose 6 stamina")
check(s2[2].kind == "item" and s2[2].target == "party" and s2[2].name == "Healing Potion", "party members gains (plural) handled")

local village = entries[2]
local aid = village.options[1]
local a2 = aid.roll.effects[2]
check(#a2 == 2 and a2[1].kind == "ally" and a2[1].name == "Wode Elf Sentry", "ally clause keeps its spelling: " .. tostring(a2[1].name))
check(a2[2].kind == "malice" and a2[2].qty == 2, "+2 Malice")
check(#aid.roll.effects[3] == 1 and aid.roll.effects[3][1].kind == "ally", "tier 3 ally only")

local beasts = entries[3]
check(beasts.kind == "threat", "threat entry")
check(beasts.consequence ~= nil and beasts.consequence.text == "Each party member loses 5 stamina.", "consequence text")
check(#beasts.consequence.effects == 1 and beasts.consequence.effects[1].kind == "stamina" and beasts.consequence.effects[1].target == "party" and beasts.consequence.effects[1].qty == 5, "consequence effect")
check(beasts.approach == "You try to deal with the threat.", "threat approach")
local hunt = beasts.options[1]
check(hunt.roll.attr == "Might or Agility (Endurance, Track)", "hunt attr")
local h2 = hunt.roll.effects[2]
check(#h2 == 2 and h2[1].kind == "stamina" and h2[1].qty == 5 and h2[2].kind == "vanquish", "lose 5, vanquished")
check(#hunt.roll.effects[3] == 1 and hunt.roll.effects[3][1].kind == "vanquish", "tier 3 vanquished")
local outsmart = beasts.options[2]
check(outsmart.roll ~= nil, "blank lines before the roll block are fine")
local o2 = outsmart.roll.effects[2]
check(#o2 == 2 and o2[1].kind == "malice" and o2[1].qty == 2 and o2[2].kind == "vanquish", "+2 malice, vanquished")

--- helpers -------------------------------------------------------------------
check(EncounterScript.FindEntry(montage, "r1/threat/dangerous-beasts") == beasts, "FindEntry")
check(#EncounterScript.EntriesForRound(montage, 1) == 3, "entries for round 1")
check(#EncounterScript.EntriesForRound(montage, 5) == 3, "entries persist into later rounds")
local items, monsters = EncounterScript.ReferencedNames(parse)
check(items["Healing Potion"] and monsters["Wode Elf Sentry"], "referenced names")
check(EncounterScript.ParseQuantity("three") == 3 and EncounterScript.ParseQuantity("12") == 12 and EncounterScript.ParseQuantity("an") == 1 and EncounterScript.ParseQuantity("lots") == nil, "quantities")

--ParseAttr with injected tables
local attributesInfo = {
    mgt = { description = "Might" }, agl = { description = "Agility" }, rea = { description = "Reason" },
    inu = { description = "Intuition" }, prs = { description = "Presence" },
}
local skillOptions = {
    { id = "empathize", text = "Empathize" }, { id = "lie", text = "Lie" }, { id = "flirt", text = "Flirt" },
    { id = "track", text = "Track" }, { id = "endurance", text = "Endurance" }, { id = "nature", text = "Nature" },
}
local chars, skills = EncounterScript.ParseAttr("Might or Agility (Endurance, Track)", attributesInfo, skillOptions)
check(chars.mgt and chars.agl and not chars.prs, "two characteristics")
table.sort(skills)
check(#skills == 2 and skills[1] == "endurance" and skills[2] == "track", "two skills")
chars, skills = EncounterScript.ParseAttr("Presence (Empathize, Lie, Flirt)", attributesInfo, skillOptions)
check(chars.prs and #skills == 3, "presence + three skills")

--Describe runs
local text = EncounterScript.Describe(parse)
check(string.find(text, "beat 1: Montage", 1, true) ~= nil, "describe")

--- edge cases ----------------------------------------------------------------
--no beats + island = implicit encounter
local implicit = EncounterScript.Parse("Some notes\n\n[[encounter]]\n")
check(#implicit.beats == 1 and implicit.beats[1].kind == "encounter" and implicit.beats[1].implicit, "implicit encounter beat")
check(#implicit.warnings == 0, "implicit encounter has no warnings")

--no island, no beats = nothing
local nothing = EncounterScript.Parse("Just prose.")
check(#nothing.beats == 0, "no beats")

--no round heading = implicit round 1; four-tier roll; unknown clause warns
local edge = EncounterScript.Parse([[
# Montage

Some intro prose.

## Threat: Rockfall

Rocks.

### Dodge

|Dodge Test: Agility (Jump)
|You lose 3 stamina and drop your torch
|You lose 1 stamina
|The threat is vanquished
|The threat is vanquished, you gain two Healing Potion
]])
check(#edge.beats == 1, "edge: one beat")
local eb = edge.beats[1]
check(eb.intro == "Some intro prose.", "intro captured")
check(#eb.rounds == 1 and eb.rounds[1].implicit and eb.rounds[1].number == 1, "implicit round")
local rock = eb.rounds[1].entries[1]
check(rock.id == "r1/threat/rockfall", "rock id")
check(#rock.options[1].roll.tiers == 4, "four tiers")
check(rock.options[1].roll.effects[4][2].kind == "item" and rock.options[1].roll.effects[4][2].qty == 2, "critical tier item x2")
check(rock.options[1].roll.effects[1][1].unrecognized == true, "unknown clause flagged")
local sawUnrecognized, sawNoConsequence = false, false
for _, w in ipairs(edge.warnings) do
    if string.find(w, "unrecognized effect", 1, true) then sawUnrecognized = true end
    if string.find(w, "has no Consequence", 1, true) then sawNoConsequence = true end
end
check(sawUnrecognized and sawNoConsequence, "warnings for unknown clause and missing consequence")

--initiative clauses: tier lines and a Consequence: line
local init = EncounterScript.Parse([[
# Montage

## Threat: Scouts

Enemy scouts watch the road.

Consequence: You begin the encounter surprised.

### Ambush them

|Stealth Test: Agility (Sneak)
|You lose initiative.
|You win the initiative
|You surprise the enemy, +1 malice
]])
local scouts = init.beats[1].rounds[1].entries[1]
check(scouts.consequence.effects[1].kind == "initiative" and scouts.consequence.effects[1].outcome == "surprised", "consequence: surprised")
local ie = scouts.options[1].roll.effects
check(ie[1][1].kind == "initiative" and ie[1][1].outcome == "lose", "tier 1: lose initiative")
check(ie[2][1].kind == "initiative" and ie[2][1].outcome == "win", "tier 2: win initiative")
check(ie[3][1].kind == "initiative" and ie[3][1].outcome == "surprise" and ie[3][2].kind == "malice", "tier 3: surprise the enemy + malice")
check(#init.warnings == 0, "initiative clauses are recognized: " .. table.concat(init.warnings, "; "))
check(EncounterScript.ParseInitiativeClause("you start the next encounter surprised") == "surprised", "start the next encounter surprised")
check(EncounterScript.ParseInitiativeClause("the party begins the encounter surprised") == "surprised", "the party begins surprised")
check(EncounterScript.ParseInitiativeClause("you are surprised") == "surprised", "you are surprised")
check(EncounterScript.ParseInitiativeClause("you surprise the enemies") == "surprise", "surprise the enemies")
check(EncounterScript.ParseInitiativeClause("the enemy is surprised") == "surprise", "the enemy is surprised")
check(EncounterScript.ParseInitiativeClause("you lose the initiative") == "lose", "lose the initiative")
check(EncounterScript.ParseInitiativeClause("you lose 5 stamina") == nil, "stamina is not initiative")
check(string.find(EncounterScript.DescribeEffect(ie[3][1]), "surprise the enemy", 1, true) ~= nil, "describe initiative")

--unknown beat kind, stray headings
local stray = EncounterScript.Parse("# Narration\n\nhello\n\n## Opportunity: X\n\n### Y\n")
check(stray.beats[1].kind == "unknown", "unknown beat kind")
check(#stray.warnings >= 3, "warnings for unknown beat and stray headings: " .. #stray.warnings)

--multiple rounds: entries introduced in round 2 are not available in round 1
local rounds = EncounterScript.Parse([[
# Montage
## Round 1
## Opportunity: A
### a
|T: Might
|x
|y
|z
## Round 2
## Threat: B
Consequence: +1 malice
### b
|T: Might
|x
|y
|z
]])
local mb = rounds.beats[1]
check(EncounterScript.RoundCount(mb) == 2, "two rounds")
check(#EncounterScript.EntriesForRound(mb, 1) == 1 and #EncounterScript.EntriesForRound(mb, 2) == 2, "round-2 entry appears from round 2")
check(mb.rounds[2].entries[1].consequence.effects[1].kind == "malice", "consequence malice")

--boon clauses: heal, temporary stamina, surges, recovery value, hero tokens.
--Every one of these has to beat the generic "you gain <qty> <item>" rule.
local boons = EncounterScript.Parse([[
# Montage
## Opportunity: Camp
### Cook a hearty meal
|Cooking Test: Reason
|You fail at the test.
|You heal 6 stamina. Your Recovery Value is increased by 2.
|Each party member heals 6 stamina. Each party member's Recovery Value is increased by 2.
### Receive a blessing
|Blessing Test: Presence
|You gain 5 temporary stamina.
|At the start of the next combat, you gain 2 surges.
|At the start of the next combat you gain 3 surges. +1 hero token.
]])
check(#boons.warnings == 0, "boon clauses are recognized: " .. table.concat(boons.warnings, "; "))
local meal = boons.beats[1].rounds[1].entries[1].options[1].roll.effects
check(meal[2][1].kind == "heal" and meal[2][1].target == "self" and meal[2][1].qty == 6, "you heal 6 stamina")
check(meal[2][2].kind == "recovery" and meal[2][2].target == "self" and meal[2][2].qty == 2, "recovery value +2")
check(meal[3][1].kind == "heal" and meal[3][1].target == "party", "each party member heals")
check(meal[3][2].kind == "recovery" and meal[3][2].target == "party", "each party member's recovery value")
local blessing = boons.beats[1].rounds[1].entries[1].options[2].roll.effects
check(blessing[1][1].kind == "temphp" and blessing[1][1].qty == 5, "5 temporary stamina, not an item")
check(blessing[2][1].kind == "narrative" and not blessing[2][1].unrecognized, "'at the start of the next combat' is recognized")
check(blessing[2][2].kind == "surges" and blessing[2][2].qty == 2, "2 surges after the comma")
check(blessing[3][1].kind == "surges" and blessing[3][1].qty == 3, "3 surges with the lead-in attached")
check(blessing[3][2].kind == "herotoken" and blessing[3][2].qty == 1, "+1 hero token")
--"you lose a recovery": the recovery is gone, with no healing for it
local lost = EncounterScript.ParseEffects(
    "You lose a recovery. You lose two recoveries. Each party member loses a recovery. Each party member loses two recoveries")
check(lost[1].kind == "loserecovery" and lost[1].target == "self" and lost[1].qty == 1, "you lose a recovery")
check(lost[2].kind == "loserecovery" and lost[2].target == "self" and lost[2].qty == 2, "you lose two recoveries")
check(lost[3].kind == "loserecovery" and lost[3].target == "party" and lost[3].qty == 1, "each party member loses a recovery")
check(lost[4].kind == "loserecovery" and lost[4].target == "party" and lost[4].qty == 2, "each party member loses two recoveries")
check(EncounterScript.ParseEffects("You lose 3 recoveries")[1].qty == 3, "digits work for a recovery loss")
check(EncounterScript.DescribeEffect(lost[2]) == "the hero loses 2 recoveries", "recovery loss is described with the irregular plural")
check(EncounterScript.DescribeEffect(lost[3]) == "every hero loses 1 recovery", "party recovery loss description")
--losing stamina and losing recoveries stay apart
check(EncounterScript.ParseEffects("You lose 6 stamina")[1].kind == "stamina", "losing stamina is not a recovery loss")
--the Recovery Value boon is still its own effect
check(EncounterScript.ParseEffects("Your Recovery Value is increased by 2")[1].kind == "recovery", "recovery value boon is not a loss")

--the generic item rule still wins for anything that is not a boon
local item = EncounterScript.Parse("# Montage\n## Opportunity: X\n### y\n|T: Might\n|You gain one Healing Potion\n|You gain 2 Rations\n|You regain 3 stamina\n")
local ie2 = item.beats[1].rounds[1].entries[1].options[1].roll.effects
check(ie2[1][1].kind == "item" and ie2[1][1].name == "Healing Potion", "healing potion is still an item")
check(ie2[2][1].kind == "item" and ie2[2][1].qty == 2 and ie2[2][1].name == "Rations", "rations are still an item")
check(ie2[3][1].kind == "heal" and ie2[3][1].qty == 3, "regain stamina is a heal")
--"you cannot be surprised" must NOT fall into the "^you .*surprised$"
--initiative rule, which would make it mean its own opposite.
local immune = EncounterScript.ParseEffects("+2 hero tokens. You cannot be surprised.")
check(immune[1].kind == "herotoken" and immune[1].qty == 2, "+2 hero tokens (plural)")
check(immune[2].kind == "nosurprise", "you cannot be surprised is immunity, not 'begins surprised'")
check(EncounterScript.ParseEffects("The party cannot be surprised")[1].kind == "nosurprise", "the party cannot be surprised")
check(EncounterScript.ParseEffects("Each party member cannot be surprised")[1].kind == "nosurprise", "each party member cannot be surprised")
check(EncounterScript.ParseEffects("You can't be surprised")[1].kind == "nosurprise", "you can't be surprised")
check(EncounterScript.ParseEffects("You are immune to surprise")[1].kind == "nosurprise", "you are immune to surprise")
local stillSurprised = EncounterScript.ParseEffects("You are surprised")
check(stillSurprised[1].kind == "initiative" and stillSurprised[1].outcome == "surprised", "'you are surprised' still means surprised")
check(string.find(EncounterScript.DescribeEffect(immune[2]), "cannot be surprised", 1, true) ~= nil, "describe surprise immunity")
--"you know the stamina of goblins": monster intelligence reveal by keyword
local know = EncounterScript.ParseEffects("You know the Stamina of Goblins.")
check(know[1].kind == "knowstamina" and know[1].keyword == "goblin", "you know the stamina of goblins -> goblin")
check(EncounterScript.ParseEffects("The party knows the stamina of the goblins")[1].keyword == "goblin", "the party knows ... the goblins")
check(EncounterScript.ParseEffects("Each party member knows the Stamina of every Goblin")[1].keyword == "goblin", "each party member ... every goblin")
check(EncounterScript.ParseEffects("You learn the stamina of all undead")[1].keyword == "undead", "learn ... all undead (no plural strip on -d)")
check(EncounterScript.ParseEffects("You know the stamina of Boss")[1].keyword == "boss", "double-s keyword keeps its s (exact)")
check(EncounterScript.ParseEffects("You know the stamina of the goblin warband")[1].kind == "narrative", "multi-word keyword is narrative")
check(EncounterScript.DescribeEffect(know[1]) == "The party knows the Stamina of Goblins", "describe know stamina")
--"you vanquish the threat" is the active spelling of "the threat is vanquished"
check(EncounterScript.ParseEffects("You vanquish the threat.")[1].kind == "vanquish", "you vanquish the threat")
check(EncounterScript.ParseEffects("You fail to vanquish the threat.")[1].kind == "narrative", "failing to vanquish is narrative")
check(not EncounterScript.ParseEffects("You fail to vanquish the threat.")[1].unrecognized, "failing to vanquish is recognized")

--- narrative beats ----------------------------------------------------------

local NARRATIVE = [==[
# Narrative

[[scene]]

The party sets out at dawn.

## The Crossroads

The road forks at a weathered shrine.

Choose together: Which way do you go?

### Take the high road

The long way, but the safer one.

|+1 hero token

### Take the low road

|+2 malice
|You gain one Healing Potion

## The Shrine

[[scene:shrine]]

Each of you may leave an offering.

Choose individually:

### Offer a coin

|You gain 1 Healing Potion

### Walk on

## A Quiet Mile

Nothing happens for a while.

# Encounter

[[encounter]]
]==]

local nar = EncounterScript.Parse(NARRATIVE)
check(#nar.beats == 2, "narrative script has two beats")
check(nar.beats[1].kind == "narrative", "beat 1 is a narrative")
check(nar.beats[2].kind == "encounter", "beat 2 is the encounter")
check(nar.beats[1].sceneTag == "scene", "narrative beat scene tag")
check(nar.beats[1].intro == "The party sets out at dawn.", "narrative intro")
check(#nar.beats[1].sections == 3, "three sections")

local sec1 = nar.beats[1].sections[1]
check(sec1.name == "The Crossroads", "section 1 name")
check(sec1.id == "s1/the-crossroads", "section 1 id")
check(sec1.mode == "together" and sec1.modeExplicit, "section 1 is an agreed choice")
check(sec1.prompt == "Which way do you go?", "section 1 prompt")
check(sec1.text == "The road forks at a weathered shrine.", "section 1 text")
check(#sec1.options == 2, "section 1 has two options")
check(sec1.options[1].name == "Take the high road", "option 1 name")
check(sec1.options[1].text == "The long way, but the safer one.", "option 1 description")
check(#sec1.options[1].effects == 1 and sec1.options[1].effects[1].kind == "herotoken", "option 1 grants a hero token")
check(sec1.options[1].effects[1].qty == 1, "option 1 grants one hero token")
check(#sec1.options[2].effects == 2, "option 2 has two effect lines")
check(sec1.options[2].effects[1].kind == "malice" and sec1.options[2].effects[1].qty == 2, "option 2 adds malice")
check(sec1.options[2].effects[2].kind == "item" and sec1.options[2].effects[2].name == "Healing Potion", "option 2 grants a potion")

local sec2 = nar.beats[1].sections[2]
check(sec2.mode == "individual" and sec2.modeExplicit, "section 2 is an individual choice")
check(sec2.sceneTag == "scene:shrine", "section 2 has its own scene")
check(nar.beats[1].sceneTag == "scene", "a section scene does not overwrite the beat's")
check(sec2.prompt == "", "section 2 has no prompt text")
check(#sec2.options == 2 and #sec2.options[2].effects == 0, "a bare option has no effects")

local sec3 = nar.beats[1].sections[3]
check(sec3.implicitOption and #sec3.options == 1, "a section with no options gets an implicit one")
check(sec3.options[1].name == "Proceed" and sec3.options[1].implicit, "the implicit option is Proceed")
check(sec3.mode == "together", "sections default to choosing together")

--an options block with no marker warns but still parses as "together"
local unmarked = EncounterScript.Parse("# Narrative\n## X\ntext\n### a\n### b\n")
check(unmarked.beats[1].sections[1].mode == "together", "unmarked multi-option section defaults to together")
check(not unmarked.beats[1].sections[1].modeExplicit, "unmarked section is not explicit")
local warned = false
for _, w in ipairs(unmarked.warnings) do
    if string.find(w, "Choose together", 1, true) ~= nil then
        warned = true
    end
end
check(warned, "unmarked multi-option section warns")

--alternate spellings of the two markers
local spellings = {
    ["Choose as a group:"] = "together",
    ["The party must agree:"] = "together",
    ["Decide together:"] = "together",
    ["Choose individually:"] = "individual",
    ["Each hero chooses:"] = "individual",
    ["Choose separately:"] = "individual",
    ["Each of you decides:"] = "individual",
}
for marker, mode in pairs(spellings) do
    local parse = EncounterScript.Parse("# Narrative\n## X\n" .. marker .. "\n### a\n### b\n")
    check(parse.beats[1].sections[1].mode == mode, marker .. " -> " .. mode)
end

--a bare "Options:" sets the prompt without changing the mode
local bare = EncounterScript.Parse("# Narrative\n## X\nOptions: pick one\n### a\n|+1 hero token\n### b\n")
check(bare.beats[1].sections[1].prompt == "pick one", "Options: sets the prompt")
check(not bare.beats[1].sections[1].modeExplicit, "Options: does not set the mode")

--the initiative and boon clauses work in a narrative option too
local boon = EncounterScript.Parse("# Narrative\n## X\nChoose together:\n### a\n|Each party member gains 5 temporary stamina. You win initiative.\n")
local beffects = boon.beats[1].sections[1].options[1].effects
check(beffects[1].kind == "temphp" and beffects[1].target == "party", "narrative party temp stamina")
check(beffects[2].kind == "initiative" and beffects[2].outcome == "win", "narrative initiative clause")

--an orphaned "|" line in a narrative warns instead of being read as a roll
local orphan = EncounterScript.Parse("# Narrative\n## X\n|+1 hero token\n")
check(#orphan.beats[1].sections[1].options == 1, "orphan effect line leaves the implicit option")
local orphanWarned = false
for _, w in ipairs(orphan.warnings) do
    if string.find(w, "### option", 1, true) ~= nil then
        orphanWarned = true
    end
end
check(orphanWarned, "orphan effect line warns")

--narrative names are collected for validation
local items, monsters = EncounterScript.ReferencedNames(nar)
check(items["Healing Potion"], "narrative item names are referenced")
check(next(monsters) == nil, "no monsters in the narrative sample")

--describe dumps sections
local described = EncounterScript.Describe(nar)
check(string.find(described, "section: The Crossroads", 1, true) ~= nil, "describe lists sections")
check(string.find(described, "the party gains 1 hero token", 1, true) ~= nil, "describe lists narrative effects")

--"teaser => full text" tier lines: players see the teaser until the tier
--lands; only the full text is parsed for effects.
local teased = EncounterScript.Parse([[
# Montage

## Opportunity: Hunter's Camp

An abandoned camp.

### Track the Goblins

|Tracking Test: Intuition (Track, Nature, Alertness)
|You fail at the test.
|A little wisdom => You learn some of the hunter's wisdom; +1 hero token.
|A wealth of wisdom=>+1 hero token. You know the Stamina of Goblins => really.
|=> A critical with an empty teaser, +2 hero tokens
]])
local track = teased.beats[1].rounds[1].entries[1].options[1].roll
check(track.teasers[1] == nil and track.tiers[1] == "You fail at the test.", "tier 1: no teaser")
check(track.teasers[2] == "A little wisdom", "tier 2 teaser")
check(track.tiers[2] == "You learn some of the hunter's wisdom; +1 hero token.", "tier 2 full text")
check(track.effects[2][2].kind == "herotoken" and track.effects[2][2].qty == 1, "tier 2 effects parsed from the full text only")
check(track.teasers[3] == "A wealth of wisdom", "tier 3 teaser, no spaces around =>")
check(track.tiers[3] == "+1 hero token. You know the Stamina of Goblins => really.", "first => splits; later ones are text")
check(track.teasers[4] == nil and track.tiers[4] == "A critical with an empty teaser, +2 hero tokens", "empty teaser dropped")
check(track.effects[4][2].kind == "herotoken" and track.effects[4][2].qty == 2, "tier 4 effects")
local sawEmptyTeaser = false
for _, w in ipairs(teased.warnings) do
    if string.find(w, "empty teaser", 1, true) then sawEmptyTeaser = true end
end
check(sawEmptyTeaser, "empty teaser warned")
check(EncounterScript.TierDisplayText(track, 2, false) == "A little wisdom", "display: teaser before landing")
check(EncounterScript.TierDisplayText(track, 2, true) == track.tiers[2], "display: full text once landed")
check(EncounterScript.TierDisplayText(track, 1, false) == track.tiers[1], "display: no teaser = full text")
check(EncounterScript.TierDisplayText({ tiers = { "a", "b", "c" } }, 2, false) == "b", "display: roll with no teasers table")
local t0, f0 = EncounterScript.SplitTeaser("plain line")
check(t0 == nil and f0 == "plain line", "SplitTeaser: no =>")

--the option card hides the skill list; only the characteristic(s) show
check(EncounterScript.AttrWithoutSkills("Presence (Empathize, Lie, Flirt, Persuade)") == "Presence", "skills stripped")
check(EncounterScript.AttrWithoutSkills("Might or Agility (Endurance, Track)") == "Might or Agility", "two characteristics kept")
check(EncounterScript.AttrWithoutSkills("Reason") == "Reason", "no skills = unchanged")

--- highlighting the recognized rules in a tier line -------------------------

--the clause offsets point at the clause inside the untouched line
local spans = EncounterScript.ParseEffectSpans("You slip past them! You gain 2 surges, and nothing else")
check(#spans == 3, "three clauses")
check(spans[1].effect.kind == "narrative" and spans[1].effect.unrecognized, "flavour is unrecognized")
check(spans[2].effect.kind == "surges", "the mechanical clause parses")
local line = "You slip past them! You gain 2 surges, and nothing else"
check(string.sub(line, spans[2].from, spans[2].to) == "You gain 2 surges", "span offsets bracket the clause exactly")
check(string.sub(line, spans[3].from, spans[3].to) == "and nothing else", "the trailing clause needs no terminator")

--only the mechanical clauses are wrapped; punctuation and flavour are left alone
local marked = EncounterScript.MarkupRules(line, "<b>", "</b>")
check(marked == "You slip past them! <b>You gain 2 surges</b>, and nothing else", "markup wraps only the recognized clause")
check(EncounterScript.MarkupRules("You fail at the test.", "<b>", "</b>") == "You fail at the test.", "recognized flavour is not marked")
check(EncounterScript.MarkupRules("Nothing here matches", "<b>", "</b>") == "Nothing here matches", "unrecognized text is not marked")
check(EncounterScript.MarkupRules("You gain 2 surges", nil, nil) == "You gain 2 surges", "no tags = text unchanged")
check(EncounterScript.MarkupRules(nil, "<b>", "</b>") == "", "nil text is empty")
local two = EncounterScript.MarkupRules("You lose 6 Stamina. Each party member gains one Healing Potion.", "[", "]")
check(two == "[You lose 6 Stamina]. [Each party member gains one Healing Potion].", "every mechanical clause is marked")
check(EncounterScript.EffectIsMechanical(spans[2].effect) and not EncounterScript.EffectIsMechanical(spans[1].effect), "EffectIsMechanical")

--montage parsing is untouched by the narrative branch
check(EncounterScript.SectionCount(nar.beats[1]) == 3, "SectionCount")
check(EncounterScript.FindSection(nar.beats[1], "s2/the-shrine") == sec2, "FindSection")

--- riders: requirements that gate or modify a test ------------------------

local RIDERS = table.concat({
    "# Montage", "## Round 1", "## Opportunity: Cottage", "Options: x", "### Consult her on the arcane",
    "|Arcana Test: Reason (Magic, Alchemy)", "|You fail.", "|You gain one Healing Potion", "|Each party member gains one Healing Potion",
    "|Allow: You are skilled in Magic, Alchemy or Psionics, or you are an Elementalist",
    "|Edge: You speak Caelian", "|Double Bane: You are a Dwarf", "|Requires: frobnicate", "|Edge:",
    "### Plain", "|Plain Test: Might", "|a", "|b", "|c", "|d", "|Edge: you are a Polder",
    "# Encounter", "[[encounter]]" }, "\n")
local rp = EncounterScript.Parse(RIDERS)
local arcane = rp.beats[1].rounds[1].entries[1].options[1].roll
check(#arcane.tiers == 3 and #arcane.riders == 4, "riders are not tiers: 3 tiers, 4 riders")
check(arcane.riders[1].effect == "allow" and arcane.riders[2].effect == "edge" and arcane.riders[3].effect == "doublebane" and arcane.riders[4].effect == "allow", "rider effects, Requires = Allow")
local alts = arcane.riders[1].requirement.alternatives
check(#alts == 4 and alts[1].kind == "skill" and alts[1].name == "magic" and alts[2].name == "alchemy" and alts[3].name == "psionics", "comma list inherits the skill kind")
check(alts[4].kind == "kindred" and alts[4].name == "elementalist", "', or you are an X' is a kindred clause")
check(arcane.riders[2].requirement.alternatives[1].kind == "language" and arcane.riders[2].requirement.alternatives[1].name == "caelian", "you speak X")
check(arcane.riders[4].requirement.unrecognized and arcane.riders[4].requirement.alternatives[1].kind == "unknown", "unknown clause flagged")
local sawUnknown, sawEmpty = false, false
for _, w in ipairs(rp.warnings) do
    if string.find(w, "frobnicate", 1, true) then sawUnknown = true end
    if string.find(w, "no requirement", 1, true) then sawEmpty = true end
end
check(sawUnknown and sawEmpty, "unknown and empty riders warn")
local plain = rp.beats[1].rounds[1].entries[1].options[2].roll
check(#plain.tiers == 4 and #plain.riders == 1, "a rider after a 4th tier still parses")

check(EncounterScript.NormalizeName("Elf, High") == "high elf", "compendium 'Elf, High' normalizes to 'high elf'")
check(EncounterScript.ParseRiderLine("You succeed: something") == nil, "a tier line with a colon is not a rider")

local mage = { skill = { magic = true }, language = { caelian = true }, kindred = { ["high elf"] = true } }
local v = EncounterScript.EvaluateRiders(arcane.riders, mage)
check(v.gated and not v.allowed, "the unknown Requires line is never met, so the roll is locked")
check(v.unlockedBy == "You are skilled in Magic" and v.boons == 1 and v.banes == 0 and #v.applied == 1, "edge applied with its reason")
local v2 = EncounterScript.EvaluateRiders({ arcane.riders[1], arcane.riders[2], arcane.riders[3] }, mage)
check(v2.allowed and v2.unlockedBy == "You are skilled in Magic" and #v2.unmet == 1, "allowed once the bad line is gone; the Dwarf bane is unmet")
local dwarf = EncounterScript.EvaluateRiders({ arcane.riders[1], arcane.riders[3] }, { skill = {}, language = {}, kindred = { dwarf = true } })
check(not dwarf.allowed and dwarf.banes == 2 and dwarf.boons == 0, "a Dwarf with no magic: locked, double bane")
local elementalist = EncounterScript.EvaluateRiders({ arcane.riders[1] }, { kindred = { elementalist = true } })
check(elementalist.allowed and elementalist.unlockedBy == "you are an Elementalist", "an Elementalist unlocks by class")
local free = EncounterScript.EvaluateRiders({}, {})
check(free.allowed and not free.gated and free.boons == 0, "no riders = allowed")
check(EncounterScript.RequirementMet(EncounterScript.ParseRequirement("you are an Elf"), { kindred = { ["high elf"] = true } }), "a fact ending in the wanted name counts")
check(not EncounterScript.RequirementMet(EncounterScript.ParseRequirement("you are skilled in Magic"), { skill = { magician = true } }), "no substring match")
check(EncounterScript.RiderLabel("doubleedge") == "Double Edge" and EncounterScript.RiderBoons("doublebane") == -2, "labels and boons")

--the sample script has no riders and parses exactly as before
check(#negotiate.roll.riders == 0, "a roll without riders has an empty riders list")

--- traps: encounter setup instructions + zone reveals ----------------------

local TRAPS = table.concat({
    "# Montage", "## Round 1", "## Opportunity: Watchtower", "Options: x", "### Scout ahead",
    "|Scouting Test: Intuition (Alertness)", "|You fail.", "|You spot some tracks.", "|Reveal Traps during the next combat.",
    "# Encounter", "Some notes for the author.",
    "Trap: Place 4 Snare Trap objects in Trap zones and delete other Trap zones.",
    "Pit: Place one Pit object in the Pit zones",
    "Rubble: Place two Rubble Pile objects in Rubble zones and remove the remaining Rubble zones.",
    "Bogus: Do something else entirely.",
    "[[encounter]]" }, "\n")
local tp = EncounterScript.Parse(TRAPS)
local enc = tp.beats[2]
check(enc.kind == "encounter" and #enc.setup == 4, "four setup instructions under # Encounter")
local trap = enc.setup[1]
check(trap.kind == "placeobjects" and trap.label == "Trap" and trap.qty == 4 and trap.object == "Snare Trap" and trap.zone == "trap" and trap.deleteOthers, "Trap: place 4 Snare Trap objects ... and delete other Trap zones")
check(enc.setup[2].kind == "placeobjects" and enc.setup[2].qty == 1 and enc.setup[2].object == "Pit" and enc.setup[2].zone == "pit" and not enc.setup[2].deleteOthers, "Place one Pit object in the Pit zones (no delete)")
check(enc.setup[3].kind == "placeobjects" and enc.setup[3].qty == 2 and enc.setup[3].object == "Rubble Pile" and enc.setup[3].zone == "rubble" and enc.setup[3].deleteOthers, "remove the remaining X zones = delete")
check(enc.setup[4].kind == "unknown" and enc.setup[4].label == "Bogus", "an unknown instruction is kept as unknown")
local sawBogus = false
for _, w in ipairs(tp.warnings) do
    if string.find(w, "Bogus", 1, true) then sawBogus = true end
end
check(sawBogus, "an unknown setup instruction warns")
check(EncounterScript.ParseSetupInstruction("Place 4 Snare Trap objects in Trap zones and delete other Pit zones") == nil, "delete clause naming a different zone is rejected")
check(EncounterScript.ParseSetupInstruction("Place lots of things") == nil, "no quantity = not an instruction")
local reveal = tp.beats[1].rounds[1].entries[1].options[1].roll.effects[3]
check(reveal[1].kind == "revealzones" and reveal[1].zone == "trap", "Reveal Traps during the next combat -> trap")
check(EncounterScript.ParseEffects("Reveal the trap zones")[1].zone == "trap", "reveal the trap zones")
check(EncounterScript.ParseEffects("Reveal traps")[1].zone == "trap", "reveal traps")
check(EncounterScript.ParseEffects("The traps are revealed during the next encounter")[1].zone == "trap", "the traps are revealed ...")
check(EncounterScript.ParseEffects("Reveal all Pits in the next combat")[1].zone == "pit", "reveal all pits in the next combat")
check(EncounterScript.ParseEffects("Reveal the secret passage")[1].kind == "narrative", "a multi-word reveal is narrative")
check(EncounterScript.DescribeEffect(reveal[1]) == "The Traps will be revealed during the next combat", "describe reveal")
check(EncounterScript.EffectIsMechanical(reveal[1]), "reveal is mechanical")
check(string.find(EncounterScript.Describe(tp), "setup Trap: place 4 x 'Snare Trap' in trap zones, delete the other trap zones", 1, true) ~= nil, "dump lists setup")
check(#EncounterScript.Parse("[[encounter]]").beats[1].setup == 0, "implicit encounter has an empty setup list")

--- party-size scaling and "(Required)" ------------------------------------

local SCALING = [==[
# Montage

The party crosses the moor.

## Round 1
3-5 Players: -1 Opportunity, -1 Threat
3 Players: -1 Threat

## Opportunity: Hunter's Camp (Required)

### Search it
|Search: Might
|You lose 1 stamina
|You gain a Rope
|You gain two Ropes

## Opportunity: Standing Stones

### Read them
|Read: Reason
|You fail the test
|You gain 1 hero token
|You gain 2 hero tokens

## Threat: Mire

Consequence: You lose 2 stamina

### Wade
|Wade: Might
|You lose 1 stamina
|You gain a Rope
|You gain two Ropes

## Threat: Fog

Consequence: You lose the initiative

### Wait
|Wait: Reason
|You fail the test
|You gain 1 hero token
|You gain 2 hero tokens

## Round 2
6+ Heroes: -1 Opportunity

## Opportunity: Ford

### Cross
|Cross: Agility
|You fail the test
|You gain 1 hero token
|You gain 2 hero tokens
]==]

local sp = EncounterScript.Parse(SCALING)
local sb = sp.beats[1]
check(#sb.rounds[1].scaling == 2, "two party-size directives on round 1")
check(sb.intro == "The party crosses the moor.", "a directive is not montage intro prose")
check(sb.rounds[1].entries[1].required and sb.rounds[1].entries[1].name == "Hunter's Camp", "(Required) sets the flag and leaves the name")
check(sb.rounds[1].entries[2].required == false, "an untagged entry is not required")

local rem = EncounterScript.ScalingRemovals(sb.rounds[1], 3)
check(rem.opportunity == 1 and rem.threat == 2, "matching directives stack for a party of 3")
check(EncounterScript.ScalingRemovals(sb.rounds[1], 5).threat == 1, "only the range directive covers a party of 5")
check(next(EncounterScript.ScalingRemovals(sb.rounds[1], 6)) == nil, "a party of 6 is outside 3-5")
check(EncounterScript.ScalingRemovals(sb.rounds[2], 99).opportunity == 1, "6+ is open-ended")

--a deterministic draw: always the first of the pool
local first = function(n) return 1 end
local removed = EncounterScript.ChooseRemovedEntries(sb, 3, first)
check(removed["r1/opportunity/hunter-s-camp"] == nil, "(Required) is never drawn")
check(removed["r1/opportunity/standing-stones"] == true, "the removable opportunity is drawn instead")
check(removed["r1/threat/mire"] and removed["r1/threat/fog"], "two threats asked for, two threats drawn")
check(removed["r2/opportunity/ford"] == nil, "a round-1 directive does not reach round 2")
check(EncounterScript.ChooseRemovedEntries(sb, 7, first)["r2/opportunity/ford"] == true, "a round-2 directive draws from round 2")
check(next(EncounterScript.ChooseRemovedEntries(sb, 2, first)) == nil, "a party outside every range loses nothing")
check(EncounterScript.HasScaling(sb) and EncounterScript.RoundHasScaling(sb, 2), "HasScaling / RoundHasScaling")
check(not EncounterScript.HasScaling(EncounterScript.Parse(SAMPLE).beats[1]), "a montage with no directives has no scaling")

check(EncounterScript.ParseScalingDirective("4+ Players: -1 Threat").max == nil, "N+ is open-ended")
check(EncounterScript.ParseScalingDirective("3 Players: -2 Opportunities").removals.opportunity == 2, "plural kind")
check(EncounterScript.ParseScalingDirective("3-5 players: -one opportunity").removals.opportunity == 1, "a spelled-out quantity")
check(EncounterScript.ParseScalingDirective("3-5 Players: +1 Opportunity") == nil, "a directive never ADDS")
check(EncounterScript.ParseScalingDirective("5-3 Players: -1 Threat") == nil, "a backwards range is rejected")
check(EncounterScript.ParseScalingDirective("Options: approach the fire") == nil, "an Options: paragraph is not a directive")
check(EncounterScript.IsScalingDirectiveLine("3-5 Players: nonsense") and EncounterScript.ParseScalingDirective("3-5 Players: nonsense") == nil, "a malformed directive is recognized and rejected")

local overdraw = EncounterScript.Parse(table.concat({
    "# Montage", "", "## Round 1", "3 Players: -2 Threats", "",
    "## Threat: Mire", "", "Consequence: You lose 2 stamina", "",
    "### Wade", "|Wade: Might", "|You lose 1 stamina", "|You gain a Rope", "|You gain two Ropes" }, "\n"))
local sawOverdraw = false
for _, w in ipairs(overdraw.warnings) do
    if string.find(w, "introduces only 1", 1, true) then sawOverdraw = true end
end
check(sawOverdraw, "asking for more than the round has warns")
check(EncounterScript.ChooseRemovedEntries(overdraw.beats[1], 3, first)["r1/threat/mire"] == true, "and drops everything it can")
check(string.find(EncounterScript.Describe(sp), "scaling: 3-5 players -> -1 opportunity, -1 threat", 1, true) ~= nil, "dump lists the directives")
check(string.find(EncounterScript.Describe(sp), "Hunter's Camp (required)", 1, true) ~= nil, "dump marks required entries")

print(string.format("encounter_script_test: %d checks passed", passed))
