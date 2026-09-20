--Encounter of the Week: the script parser.
--
--The week's journal document is a SCRIPT: an ordered list of beats, each a
--"#" heading. "# Encounter" is the combat (the [[encounter]] island, played
--exactly as before); "# Montage" is a montage played before it. Design and
--grammar: EncounterOfTheWeek.md, "Encounter scripts: montage beats before
--combat".
--
--This module is PURE Lua: no engine globals are touched at load or parse
--time, so it runs under the bundled lua.exe (tests/encounter_script_test.lua).
--Anything that needs the engine (resolving item and monster names, the
--characteristic/skill tables) is injected by the caller.
--
--Parse output:
--  {
--    beats = { beat, ... },     -- document order
--    warnings = { "line N: ...", ... },
--    hasEncounterTag = bool,    -- a [[encounter]] island anywhere in the text
--  }
--  beat = { kind = "montage"|"narrative"|"encounter"|"unknown", title, line,
--           tags = {name,...},
--           -- montage only:
--           intro = "", sceneTag = "scene"|"scene:x"|nil,
--           rounds = { { number, line, entries = { entry, ... },
--                        scaling = { scalingDirective, ... } }, ... },
--           -- narrative only:
--           intro = "", sceneTag = ..., sections = { section, ... },
--           -- encounter only:
--           setup = { setupInstruction, ... } }
--  setupInstruction = { kind = "placeobjects"|"unknown", label = "Trap", line,
--                       text = "Place 4 Snare Trap objects in Trap zones and delete other Trap zones",
--                       -- placeobjects: qty = 4, object = "Snare Trap",
--                       -- zone = "trap" (lower-cased keyword name), deleteOthers = bool }
--  A "Label: Place <n> <Object> object(s) in <Zone> zone(s) [and delete
--  (the) other <Zone> zones]" paragraph under "# Encounter" is a setup
--  instruction the host runs once, right before the monsters are spawned:
--  <n> tiles are drawn at random from every <Zone> zone on the map, one
--  <Object> is placed on each, and with the delete clause every <Zone>
--  tile that was NOT drawn is removed from its zone record (a record left
--  with no tiles is deleted). Any other "Label:" paragraph there is an
--  unknown instruction (warning).
--  scalingDirective = { min = 3, max = 5 (nil = open-ended), line,
--                       removals = { opportunity = 1, threat = 1 },
--                       text = "3-5 Players: -1 Opportunity, -1 Threat" }
--  A "3-5 Players: -1 Opportunity, -1 Threat" line directly under a
--  "## Round N" heading. At that party size the round drops that many of
--  each kind, drawn at random (once, when the party has arrived) from the
--  entries THAT round introduces, skipping any marked "(Required)".
--  EncounterScript.ChooseRemovedEntries makes the draw; the montage stores
--  it and never shows or mentions what it dropped.
--  entry = { id, kind = "opportunity"|"threat", name, required, round, line,
--            description = "", approach = "", consequence = nil | { text, effects },
--            options = { option, ... } }
--  option = { name, line, text = "", roll = nil | { name, attr, tiers = {...},
--             teasers = { [tierIndex] = "..." | nil },
--             effects = { [tierIndex] = { effect, ... } },
--             riders = { rider, ... } } }
--  rider = { effect = "allow"|"edge"|"doubleedge"|"bane"|"doublebane",
--            text = "You are skilled in Magic or you are an Elementalist",
--            line, requirement = { text, unrecognized = bool,
--              alternatives = { { kind = "skill"|"language"|"kindred"|"unknown",
--                                 name = "magic" (normalized), text = clause }, ... } } }
--  See "riders" below for the line grammar and EvaluateRiders for how a
--  hero's facts are weighed against them.
--  A tier line may read "teaser => full text": tiers[t] is the full text
--  (the only part the effect grammar sees) and teasers[t] is what players
--  see before the roll lands. Lines without "=>" have no teaser.
--  section = { id, name, line, text = "", prompt = "", sceneTag = nil,
--              mode = "together"|"individual", modeExplicit = bool,
--              implicitOption = bool, options = { narrativeOption, ... } }
--  narrativeOption = { name, line, text = "", implicit = bool,
--                      effects = { effect, ... } }
--  effect = { kind = "item"|"stamina"|"heal"|"temphp"|"surges"|"recovery"|
--                    "loserecovery"|"herotoken"|"malice"|"ally"|"vanquish"|
--                    "initiative"|"nosurprise"|"knowstamina"|"revealzones"|"narrative",
--             target = "self"|"party", qty = n, name = "...", text = clause,
--             outcome = "win"|"lose"|"surprise"|"surprised" (initiative only),
--             keyword = "goblin" (knowstamina only: lower-cased, singular),
--             zone = "trap" (revealzones only: lower-cased, singular keyword name),
--             unrecognized = true (narrative clauses the grammar did not match) }

EncounterScript = rawget(_G, "EncounterScript") or {}

--cond() is an engine global; give the pure module its own when it is
--missing (the interpreter and the tests).
if rawget(_G, "cond") == nil then
    cond = function(c, a, b)
        if c then
            return a
        end
        return b
    end
end

local NUMBER_WORDS = {
    a = 1, an = 1, one = 1, two = 2, three = 3, four = 4, five = 5,
    six = 6, seven = 7, eight = 8, nine = 9, ten = 10,
}

local function trim(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function lower(s)
    return string.lower(s)
end

--"one" / "3" / "a" -> number, or nil.
function EncounterScript.ParseQuantity(word)
    if word == nil then
        return nil
    end
    word = lower(trim(word))
    local n = tonumber(word)
    if n ~= nil then
        return math.floor(n)
    end
    return NUMBER_WORDS[word]
end

--A stable id fragment from a name: lowercase, runs of non-alphanumerics
--become single dashes.
local function Slug(name)
    local s = lower(trim(name))
    s = string.gsub(s, "[^%w]+", "-")
    s = string.gsub(s, "^%-+", "")
    s = string.gsub(s, "%-+$", "")
    return s
end

--- effect clauses ---------------------------------------------------------

--The mode marker paragraph of a narrative section: "Choose together:",
--"Choose individually:", "Each hero chooses:", ... Returns "together",
--"individual", "prompt" (a bare "Options:"/"Choose:" that only carries the
--prompt text) or nil when the label is not a marker at all.
local function NarrativeMode(label)
    local lc = lower(trim(label or ""))
    if lc == "" then
        return nil
    end
    local function has(word)
        return string.find(lc, word, 1, true) ~= nil
    end
    if has("together") or has("as one") or has("as a group") or has("agree") or has("unanimous") then
        return "together"
    end
    if has("individual") or has("separately") or has("each hero") or has("each of you")
        or has("their own") or has("each player") then
        return "individual"
    end
    if lc == "options" or lc == "option" or lc == "choose" or lc == "choice" or lc == "prompt" then
        return "prompt"
    end
    return nil
end

--Split one tier line into clauses on . , ; ! ? -- each clause trimmed,
--empties dropped, and each kept with its POSITION: { text, from, to },
--1-based inclusive byte offsets of the trimmed clause in the original
--line. The offsets are what lets a display highlight the recognized words
--in place (EncounterScript.MarkupRules).
--
--! and ? are separators because flavour prose in front of a mechanical
--clause is the norm ("You make off with some potions! Each party member
--gains one Healing Potion"); without them the whole line is one
--unrecognized clause and the mechanical half never lands.
local function SplitClauseSpans(text)
    text = text or ""
    local spans = {}
    local n = #text
    local pos = 1
    while pos <= n + 1 do
        local cut = string.find(text, "[%.,;!%?]", pos)
        local last = (cut or n + 1) - 1
        if last >= pos then
            local piece = string.sub(text, pos, last)
            --trim by measuring what comes off each end, so the offsets
            --still point at the clause inside the untouched line.
            local from = pos + #string.match(piece, "^%s*")
            local to = last - #string.match(piece, "%s*$")
            if to >= from then
                spans[#spans + 1] = { text = string.sub(text, from, to), from = from, to = to }
            end
        end
        if cut == nil then
            break
        end
        pos = cut + 1
    end
    return spans
end

--Just the clause text, in order.
local function SplitClauses(text)
    local result = {}
    for _, span in ipairs(SplitClauseSpans(text)) do
        result[#result + 1] = span.text
    end
    return result
end

--Match "you <verb> <rest>" or "each party member[s] <verb>[s] <rest>" and
--return the single capture in <rest> plus the target it landed on. <verb> is
--a plain word ("gain", "heal"); the party spelling adds the "s".
local function MatchSelfOrParty(lc, verb, rest)
    local capture = string.match(lc, "^you " .. verb .. " " .. rest .. "$")
    if capture ~= nil then
        return capture, "self"
    end
    capture = string.match(lc, "^each party members? " .. verb .. "s? " .. rest .. "$")
    if capture ~= nil then
        return capture, "party"
    end
    return nil
end

--Match one clause against the effect grammar. Matching is case-insensitive
--but names are taken from the original text (position captures), so an item
--or monster name keeps its spelling.
local function ParseClause(clause)
    local lc = lower(clause)

    --- boons --------------------------------------------------------------
    --These are matched BEFORE the generic "you gain <qty> <item>" rule
    --below, which would otherwise swallow "you gain 5 temporary stamina" as
    --an item named "temporary stamina".

    --Surges only exist inside a fight, so "at the start of the next combat"
    --is flavor on a clause that is deferred to the encounter anyway. The
    --clause splitter cuts it off at a comma (recognized as narrative below);
    --without the comma it is stripped here.
    local boon = string.gsub(lc, "^at the start of the next %a+,?%s*", "")

    --"you gain <n> temporary stamina" / "each party member gains <n> ..."
    local word, target = MatchSelfOrParty(lc, "gain", "(%S+) temporary stamina")
    if word ~= nil and EncounterScript.ParseQuantity(word) ~= nil then
        return { kind = "temphp", target = target, qty = EncounterScript.ParseQuantity(word), text = clause }
    end

    --"you heal <n> stamina" ("regain"/"recover" are spelled the same way)
    for _, verb in ipairs({ "heal", "regain", "recover" }) do
        word, target = MatchSelfOrParty(lc, verb, "(%S+) stamina")
        if word ~= nil and EncounterScript.ParseQuantity(word) ~= nil then
            return { kind = "heal", target = target, qty = EncounterScript.ParseQuantity(word), text = clause }
        end
    end

    --"you gain <n> surge[s]" / "each party member gains <n> surge[s]"
    word, target = MatchSelfOrParty(boon, "gain", "(%S+) surges?")
    if word ~= nil and EncounterScript.ParseQuantity(word) ~= nil then
        return { kind = "surges", target = target, qty = EncounterScript.ParseQuantity(word), text = clause }
    end

    --"your recovery value is increased by <n>" / "+<n> recovery value"
    local n = string.match(lc, "^your recovery value is increased by (%S+)$")
        or string.match(lc, "^%+?%s*(%S+) recovery value$")
        or string.match(lc, "^you gain (%S+) recovery value$")
    if n ~= nil and EncounterScript.ParseQuantity(n) ~= nil then
        return { kind = "recovery", target = "self", qty = EncounterScript.ParseQuantity(n), text = clause }
    end
    n = string.match(lc, "^each party members?'?s? recovery value is increased by (%S+)$")
    if n ~= nil and EncounterScript.ParseQuantity(n) ~= nil then
        return { kind = "recovery", target = "party", qty = EncounterScript.ParseQuantity(n), text = clause }
    end

    --"you lose a recovery" / "each party member loses two recoveries": the
    --recovery is gone off the hero's pool, with no Stamina back for it (a
    --montage cost, not Draw Steel's recovery SPEND).
    for _, noun in ipairs({ "recovery", "recoveries" }) do
        word, target = MatchSelfOrParty(lc, "lose", "(%S+) " .. noun)
        if word ~= nil and EncounterScript.ParseQuantity(word) ~= nil then
            return { kind = "loserecovery", target = target, qty = EncounterScript.ParseQuantity(word), text = clause }
        end
    end

    --"+<n> hero token[s]" / "you gain <n> hero token[s]". Hero tokens are one
    --pool the whole party draws on, so there is no self/party distinction.
    n = string.match(lc, "^%+?%s*(%S+) hero tokens?$")
        or string.match(lc, "^you gain (%S+) hero tokens?$")
        or string.match(lc, "^gain %+?(%S+) hero tokens?$")
        or string.match(lc, "^the party gains (%S+) hero tokens?$")
        or string.match(lc, "^each party members? gains? (%S+) hero tokens?$")
    if n ~= nil and EncounterScript.ParseQuantity(n) ~= nil then
        return { kind = "herotoken", qty = EncounterScript.ParseQuantity(n), text = clause }
    end

    --"you gain <qty> <item>"
    local qty, pos = string.match(lc, "^you gain (%S+) ()%S")
    if qty ~= nil and EncounterScript.ParseQuantity(qty) ~= nil then
        return { kind = "item", target = "self", qty = EncounterScript.ParseQuantity(qty),
                 name = trim(string.sub(clause, pos)), text = clause }
    end

    --"each party member[s] gain[s] <qty> <item>"
    qty, pos = string.match(lc, "^each party members? gains? (%S+) ()%S")
    if qty ~= nil and EncounterScript.ParseQuantity(qty) ~= nil then
        return { kind = "item", target = "party", qty = EncounterScript.ParseQuantity(qty),
                 name = trim(string.sub(clause, pos)), text = clause }
    end

    --"you lose <n> stamina"
    local n = string.match(lc, "^you lose (%S+) stamina$")
    if n ~= nil and EncounterScript.ParseQuantity(n) ~= nil then
        return { kind = "stamina", target = "self", qty = EncounterScript.ParseQuantity(n), text = clause }
    end

    --"each party member[s] lose[s] <n> stamina"
    n = string.match(lc, "^each party members? loses? (%S+) stamina$")
    if n ~= nil and EncounterScript.ParseQuantity(n) ~= nil then
        return { kind = "stamina", target = "party", qty = EncounterScript.ParseQuantity(n), text = clause }
    end

    --"+<n> malice" / "<n> malice" / "gain <n> malice"
    n = string.match(lc, "^%+?%s*(%S+) malice$") or string.match(lc, "^gain %+?(%S+) malice$")
    if n ~= nil and EncounterScript.ParseQuantity(n) ~= nil then
        return { kind = "malice", qty = EncounterScript.ParseQuantity(n), text = clause }
    end

    --"a <monster> joins you" / "an <monster> joins you" / "<monster> joins you"
    pos = string.match(lc, "^an? ()%S.- joins you$") or string.match(lc, "^()%S.- joins you$")
    if pos ~= nil then
        local name = string.sub(clause, pos)
        name = trim(string.sub(name, 1, #name - #" joins you"))
        if name ~= "" then
            return { kind = "ally", name = name, text = clause }
        end
    end

    --"the threat is vanquished" / "threat vanquished" / "you vanquish the threat"
    if string.match(lc, "^the threat is vanquished$") or string.match(lc, "^threat vanquished$")
        or string.match(lc, "^you vanquish the threat$") or string.match(lc, "^each party member vanquishes the threat$") then
        return { kind = "vanquish", text = clause }
    end

    --"you know the stamina of goblins": monster intelligence, party-wide and
    --for the whole campaign (it lands in the shared monsterKnowledge document).
    local keyword = EncounterScript.ParseKnowStaminaClause(lc)
    if keyword ~= nil then
        return { kind = "knowstamina", keyword = keyword, text = clause }
    end

    --"reveal traps during the next combat": the Trap zones become visible
    --to the players (and their zone overlay is switched on) for the fight.
    local zone = EncounterScript.ParseRevealZonesClause(lc)
    if zone ~= nil then
        return { kind = "revealzones", zone = zone, text = clause }
    end

    --"you cannot be surprised": party-wide immunity for the next encounter.
    --Checked BEFORE the initiative clauses, whose "^you .*surprised$" rule
    --would otherwise read this as its own opposite (the heroes begin the
    --encounter surprised).
    if EncounterScript.ParseSurpriseImmunityClause(lc) then
        return { kind = "nosurprise", text = clause }
    end

    --Initiative outcomes for the NEXT encounter. The last one applied
    --during the montage wins (a later tier or consequence overrides an
    --earlier one). "surprised"/"surprise" also lose/win initiative and put
    --the surprised condition on every creature of the losing side.
    local outcome = EncounterScript.ParseInitiativeClause(lc)
    if outcome ~= nil then
        return { kind = "initiative", outcome = outcome, text = clause }
    end

    --"you fail (at) the test" and friends: narrative, recognized. A bare
    --"at the start of the next combat" is the lead-in of a boon clause the
    --splitter cut at its comma -- recognized so it warns about nothing.
    if string.match(lc, "^you fail") or string.match(lc, "^you succeed") or string.match(lc, "^nothing happens")
        or string.match(lc, "^at the start of the next %a+$") then
        return { kind = "narrative", text = clause }
    end

    return { kind = "narrative", text = clause, unrecognized = true }
end

--"You know the Stamina of Goblins" and its spellings. Returns the monster
--keyword, lower-cased and singular ("goblins" -> "goblin"), or nil. The
--keyword is matched at run time against each monster's stat-block keywords
--(MonsterKnowledge), so "Goblin" covers everything the rules tag Goblin:
--goblins, bugbears, hobgoblins, worgs and so on.
--  "you know the stamina of goblins" / "you learn the stamina of goblins"
--  "the party knows the stamina of goblins"
--  "each party member knows the stamina of goblins"
--  "you know the stamina of the goblins" / "... of every goblin" / "... of all goblins"
function EncounterScript.ParseKnowStaminaClause(lc)
    lc = trim(lc)
    local rest = string.match(lc, "^you (.+)$")
        or string.match(lc, "^the party (.+)$")
        or string.match(lc, "^each party members? (.+)$")
    if rest == nil then
        return nil
    end
    local keyword = string.match(rest, "^knows? the stamina of (.+)$")
        or string.match(rest, "^learns? the stamina of (.+)$")
    if keyword == nil then
        return nil
    end
    keyword = trim(keyword)
    keyword = string.match(keyword, "^the (.+)$") or string.match(keyword, "^every (.+)$")
        or string.match(keyword, "^all (.+)$") or string.match(keyword, "^any (.+)$") or keyword
    keyword = trim(keyword)
    if keyword == "" or string.find(keyword, " ", 1, true) ~= nil then
        --stat-block keywords are single words; a phrase is not one.
        return nil
    end
    if #keyword > 3 and string.sub(keyword, -1) == "s" and string.sub(keyword, -2) ~= "ss" then
        keyword = string.sub(keyword, 1, -2)
    end
    return keyword
end

--Lower-case a keyword name and drop a trailing plural "s" ("traps" ->
--"trap"; "boss" keeps its s). nil for an empty name or a phrase.
local function SingularKeyword(name)
    name = trim(lower(name or ""))
    if name == "" or string.find(name, " ", 1, true) ~= nil then
        return nil
    end
    if #name > 3 and string.sub(name, -1) == "s" and string.sub(name, -2) ~= "ss" then
        name = string.sub(name, 1, -2)
    end
    return name
end

--"Reveal Traps during the next combat" and its spellings. Returns the zone
--keyword name, lower-cased and singular ("traps" -> "trap"), or nil. The
--name is matched at run time against the map's environmental keywords, so
--any zone type an author paints can be revealed this way.
--  "reveal traps" / "reveal the traps" / "reveal the trap zones"
--  "reveal traps during the next combat" / "... in the next encounter" / "... during combat"
--  "the traps are revealed" / "the trap zones are revealed during the next combat"
function EncounterScript.ParseRevealZonesClause(lc)
    lc = trim(lc)
    --the timing suffix is flavour: the reveal always lands when combat comes.
    lc = string.gsub(lc, "%s+during the next %a+$", "")
    lc = string.gsub(lc, "%s+in the next %a+$", "")
    lc = string.gsub(lc, "%s+during combat$", "")
    lc = string.gsub(lc, "%s+in combat$", "")
    lc = string.gsub(lc, "%s+for the next %a+$", "")
    local rest = string.match(lc, "^reveal (.+)$")
    if rest == nil then
        rest = string.match(lc, "^(.-) are revealed$") or string.match(lc, "^(.-) is revealed$")
    end
    if rest == nil then
        return nil
    end
    rest = trim(rest)
    rest = string.match(rest, "^the (.+)$") or string.match(rest, "^all (.+)$")
        or string.match(rest, "^every (.+)$") or rest
    rest = string.gsub(rest, "%s+zones?$", "")
    return SingularKeyword(rest)
end

--The player-facing line for a zone reveal: "The Traps will be revealed
--during the next combat".
function EncounterScript.DescribeRevealZones(zone)
    zone = tostring(zone or "")
    local shown = string.upper(string.sub(zone, 1, 1)) .. string.sub(zone, 2) .. "s"
    return string.format("The %s will be revealed during the next combat", shown)
end

--A setup instruction under "# Encounter" (the paragraph after its label):
--  "Place 4 Snare Trap objects in Trap zones and delete other Trap zones"
--  "Place one Pit object in the Pit zones"
--  "Place 4 Snare Trap objects in Trap zones and remove the remaining Trap zones"
--Returns { kind = "placeobjects", qty, object, zone, deleteOthers } or nil.
function EncounterScript.ParseSetupInstruction(text)
    local original = trim(text or "")
    local lc = lower(original)
    lc = string.gsub(lc, "%.$", "")
    local qtyWord, rest = string.match(lc, "^place (%S+) (.+)$")
    if qtyWord == nil then
        return nil
    end
    local qty = EncounterScript.ParseQuantity(qtyWord)
    if qty == nil then
        return nil
    end
    local object, zoneText = string.match(rest, "^(.-) objects? in (.+)$")
    if object == nil then
        return nil
    end
    object = trim(object)
    local zone, tail = string.match(zoneText, "^(.-) zones?(.*)$")
    if zone == nil then
        return nil
    end
    zone = string.match(zone, "^the (.+)$") or zone
    zone = SingularKeyword(zone)
    if object == "" or zone == nil then
        return nil
    end
    tail = trim(tail or "")
    local deleteOthers = false
    if tail ~= "" then
        local verb, others = string.match(tail, "^and (%a+) (.+)$")
        if verb ~= "delete" and verb ~= "remove" then
            return nil
        end
        others = string.match(others, "^the (.+)$") or others
        others = string.match(others, "^other (.+)$") or string.match(others, "^remaining (.+)$")
            or string.match(others, "^unused (.+)$") or string.match(others, "^extra (.+)$")
        if others == nil then
            return nil
        end
        others = string.gsub(others, "%s+zones?$", "")
        if SingularKeyword(others) ~= zone then
            return nil
        end
        deleteOthers = true
    end
    --the object name keeps the author's capitalisation: it is what the
    --lookup reports when nothing matches.
    local objectStart = #("place " .. qtyWord .. " ") + 1
    local objectShown = trim(string.sub(original, objectStart, objectStart + #object - 1))
    if lower(objectShown) ~= object then
        objectShown = object
    end
    return { kind = "placeobjects", qty = qty, object = objectShown, zone = zone, deleteOthers = deleteOthers }
end

--"You cannot be surprised" and its spellings. The heroes still LOSE the
--initiative to a "surprised" outcome -- only the Surprised condition is
--withheld, and from the whole party, whoever earned it.
--  "you cannot be surprised" / "can not" / "can't"
--  "the party cannot be surprised" / "each party member cannot be surprised"
--  "you are immune to surprise" / "the party is immune to surprise"
function EncounterScript.ParseSurpriseImmunityClause(lc)
    lc = trim(lc)
    local rest = string.match(lc, "^you (.+)$")
        or string.match(lc, "^the party (.+)$")
        or string.match(lc, "^each party members? (.+)$")
    if rest == nil then
        return false
    end
    return rest == "cannot be surprised" or rest == "can not be surprised"
        or rest == "can't be surprised"
        or rest == "are immune to surprise" or rest == "is immune to surprise"
        or rest == "is not surprised" or rest == "are not surprised"
end

--Match a lower-cased clause against the initiative grammar. Returns
--"surprised" (the heroes begin the encounter surprised), "surprise" (the
--heroes surprise the enemy), "win", "lose", or nil.
--  "you begin the encounter surprised" / "you start the next encounter surprised"
--  "you are surprised" / "the party begins the encounter surprised"
--  "you surprise the enemy" / "you surprise the enemies" / "the enemy is surprised"
--  "you win initiative" / "you win the initiative" / "you lose initiative"
function EncounterScript.ParseInitiativeClause(lc)
    lc = trim(lc)
    if string.match(lc, "^you win the initiative$") or string.match(lc, "^you win initiative$")
        or string.match(lc, "^the party wins the initiative$") or string.match(lc, "^the party wins initiative$") then
        return "win"
    end
    if string.match(lc, "^you lose the initiative$") or string.match(lc, "^you lose initiative$")
        or string.match(lc, "^the party loses the initiative$") or string.match(lc, "^the party loses initiative$") then
        return "lose"
    end
    if string.match(lc, "^you surprise the enem") or string.match(lc, "^the party surprises the enem")
        or string.match(lc, "^the enem[a-z]* [a-z]* surprised$") then
        return "surprise"
    end
    --"you begin/start the (next) encounter surprised", "you are surprised",
    --"the party begins ... surprised": anything by the heroes ending in
    --"surprised" that is not about the enemy.
    if string.match(lc, "^you .*surprised$") or string.match(lc, "^the party .*surprised$")
        or string.match(lc, "^each party member .*surprised$") then
        return "surprised"
    end
    return nil
end

--The roll header shown on an option card before anyone takes the roll:
--"Presence (Empathize, Lie, Flirt)" -> "Presence". The skills are only
--discovered in the roll dialog (user direction 2026-09-19).
function EncounterScript.AttrWithoutSkills(attr)
    local stripped = string.gsub(attr or "", "%s*%b()", "")
    return trim(stripped)
end

--- riders ------------------------------------------------------------------
--
--A test may carry riders: "|<Effect>: <requirement>" lines after its
--tiers (Allow / Edge / Double Edge / Bane / Double Bane, with "you are
--skilled in X" / "you speak X" / "you are a X" requirements). The grammar
--and the weighing live in core, TestRiders (DMHub Game Rules/TestRiders.lua),
--shared with the journal's own power-roll blocks; these are the names the
--rest of the codemod (and the tests) use. TestRiders is looked up at call
--time so this module still loads on its own.
local function Riders()
    local tr = rawget(_G, "TestRiders")
    if tr == nil then
        error("TestRiders (DMHub Game Rules/TestRiders.lua) is not loaded")
    end
    return tr
end

function EncounterScript.RiderLabel(effect)
    return Riders().Label(effect)
end

function EncounterScript.RiderBoons(effect)
    return Riders().Boons(effect)
end

function EncounterScript.ParseRiderLine(text)
    return Riders().ParseRiderLine(text)
end

function EncounterScript.NormalizeName(name)
    return Riders().NormalizeName(name)
end

function EncounterScript.ParseRequirement(text)
    return Riders().ParseRequirement(text)
end

function EncounterScript.RequirementMet(req, facts)
    return Riders().RequirementMet(req, facts)
end

function EncounterScript.EvaluateRiders(riders, facts)
    return Riders().Evaluate(riders, facts)
end

--Split a tier line on its first "=>" into (teaser, fullText). A line with
--no "=>" returns (nil, line). Both halves are trimmed; an empty teaser is
--returned as "" so the caller can warn.
function EncounterScript.SplitTeaser(tierText)
    local teaser, fullText = string.match(tierText or "", "^(.-)=>(.*)$")
    if teaser == nil then
        return nil, trim(tierText or "")
    end
    return trim(teaser), trim(fullText)
end

--What a tier row should read for a viewer: the full text when the tier has
--landed (or has no teaser), the teaser otherwise.
function EncounterScript.TierDisplayText(roll, t, landed)
    local teaser = roll.teasers ~= nil and roll.teasers[t] or nil
    if landed or teaser == nil then
        return roll.tiers[t]
    end
    return teaser
end

--Parse a tier line (or a Consequence: line) into its effects, each with
--the position of the clause it came from: { from, to, effect }.
function EncounterScript.ParseEffectSpans(text)
    local result = {}
    for _, span in ipairs(SplitClauseSpans(text or "")) do
        result[#result + 1] = { from = span.from, to = span.to, effect = ParseClause(span.text) }
    end
    return result
end

--Parse a tier line (or a Consequence: line) into its effects.
function EncounterScript.ParseEffects(text)
    local result = {}
    for _, span in ipairs(EncounterScript.ParseEffectSpans(text)) do
        result[#result + 1] = span.effect
    end
    return result
end

--Does this parsed clause actually DO anything? "narrative" is both the
--flavour the grammar recognizes as flavour ("you fail the test") and
--everything it did not understand at all; every other kind changes the
--game state.
function EncounterScript.EffectIsMechanical(effect)
    return effect ~= nil and effect.kind ~= "narrative"
end

--Wrap every mechanically recognized clause of a line in open ... close,
--leaving the flavour, the punctuation and anything the grammar did not
--understand exactly as written. The caller supplies the tags (the stage
--passes rich-text colour tags), so this stays engine-free and testable.
function EncounterScript.MarkupRules(text, open, close)
    text = text or ""
    if open == nil or open == "" then
        return text
    end
    close = close or ""
    local out = {}
    local copied = 1
    for _, span in ipairs(EncounterScript.ParseEffectSpans(text)) do
        if EncounterScript.EffectIsMechanical(span.effect) then
            out[#out + 1] = string.sub(text, copied, span.from - 1)
            out[#out + 1] = open
            out[#out + 1] = string.sub(text, span.from, span.to)
            out[#out + 1] = close
            copied = span.to + 1
        end
    end
    if copied == 1 then
        return text
    end
    out[#out + 1] = string.sub(text, copied)
    return table.concat(out)
end

--- power roll attr ---------------------------------------------------------

--"Presence (Empathize, Lie, Flirt)" -> characteristics set + skills list.
--attributesInfo: { [attrid] = { description = "Presence", ... } }
--skillOptions:   { { id = skillid, text = "Empathize" }, ... }
--The same substring rule PowerRollDisplay's press handler uses, so a
--script rolls exactly what the journal's own power-roll link would.
function EncounterScript.ParseAttr(attr, attributesInfo, skillOptions)
    local text = lower(attr or "")
    local characteristics = {}
    for attrid, info in pairs(attributesInfo or {}) do
        local desc = info.description
        if type(desc) == "string" and desc ~= "" and string.find(text, lower(desc), 1, true) ~= nil then
            characteristics[attrid] = true
        end
    end
    local skills = {}
    for _, skillInfo in ipairs(skillOptions or {}) do
        local name = skillInfo.text
        if type(name) == "string" and name ~= "" and string.find(text, lower(name), 1, true) ~= nil then
            skills[#skills + 1] = skillInfo.id
        end
    end
    return characteristics, skills
end

--- party-size scaling -------------------------------------------------------

--A "3-5 Players: -1 Opportunity, -1 Threat" line under a "## Round N"
--heading: at that party size the round drops that many of each kind, drawn
--at random from the entries the round introduces (see ChooseRemovedEntries).
--The range may be "3", "3-5" or "3+", and "Players" may be "Heroes".
--Returns { min, max = nil when open-ended,
--          removals = { opportunity = 1, threat = 1 }, text } or nil.
function EncounterScript.ParseScalingDirective(text)
    local original = trim(text or "")
    local lc = string.gsub(lower(original), "%.$", "")
    local range, word, rest = string.match(lc, "^([%d][%d%s%-+]*)%s+(%a+)%s*:%s*(.+)$")
    if range == nil then
        return nil
    end
    if word ~= "players" and word ~= "player" and word ~= "heroes" and word ~= "hero" then
        return nil
    end
    range = trim(range)
    local min, max
    local lo, hi = string.match(range, "^(%d+)%s*%-%s*(%d+)$")
    if lo ~= nil then
        min, max = tonumber(lo), tonumber(hi)
    elseif string.match(range, "^%d+%+$") then
        min = tonumber(string.match(range, "^(%d+)%+$"))
    elseif string.match(range, "^%d+$") then
        min, max = tonumber(range), tonumber(range)
    else
        return nil
    end
    if min == nil or (max ~= nil and max < min) then
        return nil
    end

    local removals = {}
    local any = false
    for clause in string.gmatch(rest, "[^,;]+") do
        clause = trim(clause)
        if clause ~= "" then
            --"-1 opportunity"; a bare "1 opportunity" means the same thing,
            --and nothing is ever ADDED by a directive.
            local sign, qtyWord, kind = string.match(clause, "^([%-+]?)%s*(%S+)%s+(%a+)$")
            if kind == nil or sign == "+" then
                return nil
            end
            local qty = EncounterScript.ParseQuantity(qtyWord)
            if qty == nil or qty < 0 then
                return nil
            end
            kind = string.gsub(kind, "ies$", "y")
            kind = string.gsub(kind, "s$", "")
            if kind ~= "opportunity" and kind ~= "threat" then
                return nil
            end
            removals[kind] = (removals[kind] or 0) + qty
            any = true
        end
    end
    if not any then
        return nil
    end
    return { min = min, max = max, removals = removals, text = original }
end

--Does this line LOOK like a party-size directive? A typo'd one then warns
--instead of quietly becoming montage intro prose.
function EncounterScript.IsScalingDirectiveLine(text)
    local lc = lower(trim(text or ""))
    return string.match(lc, "^%d[%d%s%-+]*%s+players?%s*:") ~= nil
        or string.match(lc, "^%d[%d%s%-+]*%s+heroe?s?%s*:") ~= nil
end

--How many entries of each kind a round drops for a party of `partySize`.
--Every directive whose range covers the size applies, cumulatively.
function EncounterScript.ScalingRemovals(round, partySize)
    local removals = {}
    partySize = tonumber(partySize) or 0
    for _, d in ipairs((round and round.scaling) or {}) do
        if partySize >= d.min and (d.max == nil or partySize <= d.max) then
            for kind, n in pairs(d.removals) do
                removals[kind] = (removals[kind] or 0) + n
            end
        end
    end
    return removals
end

--Does any round of this montage carry a party-size directive?
function EncounterScript.HasScaling(beat)
    for _, r in ipairs((beat and beat.rounds) or {}) do
        if #(r.scaling or {}) > 0 then
            return true
        end
    end
    return false
end

--Does the round that introduces this entry carry a party-size directive?
--Such a round shows nothing at all until the removals have been rolled: a
--card that is about to be removed must never appear.
function EncounterScript.RoundHasScaling(beat, roundNumber)
    for _, r in ipairs((beat and beat.rounds) or {}) do
        if r.number == roundNumber and #(r.scaling or {}) > 0 then
            return true
        end
    end
    return false
end

--The entry ids a montage beat removes for a party of `partySize`, as
--{ [entryId] = true }. Candidates are only the entries the directive's own
--round INTRODUCES -- never one carried over from an earlier round -- and
--never one whose heading said "(Required)". A round that asks for more than
--it has drops everything it can.
--`rand(n)` returns an integer in 1..n; math.random by default (the tests
--pass a deterministic one).
function EncounterScript.ChooseRemovedEntries(beat, partySize, rand)
    rand = rand or function(n) return math.random(n) end
    local removed = {}
    for _, r in ipairs((beat and beat.rounds) or {}) do
        local removals = EncounterScript.ScalingRemovals(r, partySize)
        for _, kind in ipairs({ "opportunity", "threat" }) do
            local count = removals[kind] or 0
            if count > 0 then
                local pool = {}
                for _, e in ipairs(r.entries) do
                    if e.kind == kind and not e.required then
                        pool[#pool + 1] = e.id
                    end
                end
                for _ = 1, math.min(count, #pool) do
                    local idx = rand(#pool)
                    removed[pool[idx]] = true
                    table.remove(pool, idx)
                end
            end
        end
    end
    return removed
end

--- the document ------------------------------------------------------------

local function SplitLines(text)
    local lines = {}
    text = string.gsub(text or "", "\r\n", "\n")
    text = string.gsub(text, "\r", "\n")
    --the journal stores a soft line break (shift+enter) as a vertical
    --tab; its own renderer treats it as a newline, so we must too, or a
    --rider typed that way rides along inside the tier line above it.
    text = string.gsub(text, "\v", "\n")
    for line in string.gmatch(text .. "\n", "(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

function EncounterScript.Parse(text)
    local lines = SplitLines(text)
    local result = { beats = {}, warnings = {}, hasEncounterTag = false }

    local function Warn(lineIndex, fmt, ...)
        result.warnings[#result.warnings + 1] = string.format("line %d: " .. fmt, lineIndex, ...)
    end

    local beat = nil      --current beat
    local round = nil     --current round (montage)
    local entry = nil     --current entry (montage)
    local section = nil   --current section (narrative)
    local option = nil    --current option (montage entry or narrative section)
    local paragraph = {}  --accumulating prose lines
    local paragraphLine = 0

    local function EnsureRound(lineIndex)
        if round == nil then
            round = { number = 1, line = lineIndex, entries = {}, scaling = {}, implicit = true }
            beat.rounds[#beat.rounds + 1] = round
        end
        return round
    end

    local function FlushParagraph()
        if #paragraph == 0 then
            return
        end
        local text = trim(table.concat(paragraph, "\n"))
        paragraph = {}
        if text == "" then
            return
        end
        if beat == nil then
            --prose before the first beat is ignored (a doc title, notes).
            return
        end
        if beat.kind == "narrative" then
            if option ~= nil then
                option.text = cond(option.text == "", text, option.text .. "\n\n" .. text)
                return
            end
            if section ~= nil then
                local label, rest = string.match(text, "^([%a][%a \t'%-]*):%s*(.*)$")
                local mode = label ~= nil and NarrativeMode(label) or nil
                if mode ~= nil then
                    if mode ~= "prompt" then
                        section.mode = mode
                        section.modeExplicit = true
                    end
                    rest = trim(rest or "")
                    if rest ~= "" then
                        section.prompt = cond(section.prompt == "", rest, section.prompt .. "\n\n" .. rest)
                    end
                    return
                end
                section.text = cond(section.text == "", text, section.text .. "\n\n" .. text)
                return
            end
            beat.intro = cond(beat.intro == "", text, beat.intro .. "\n\n" .. text)
            return
        end
        if beat.kind == "encounter" then
            --"Label: instruction" paragraphs are setup instructions the host
            --runs before spawning the monsters; other prose is notes.
            --One instruction per LINE (adjacent lines are one paragraph).
            local lineIndex = paragraphLine
            for _, l in ipairs(SplitLines(text)) do
                local label, rest = string.match(trim(l), "^([%a][%a '%-]*):%s*(.*)$")
                if label ~= nil then
                    local instruction = EncounterScript.ParseSetupInstruction(rest)
                    if instruction == nil then
                        Warn(lineIndex, "unrecognized encounter setup instruction '%s: %s'; ignored", label, rest)
                        instruction = { kind = "unknown" }
                    end
                    instruction.label = trim(label)
                    instruction.text = trim(rest)
                    instruction.line = lineIndex
                    beat.setup[#beat.setup + 1] = instruction
                end
                lineIndex = lineIndex + 1
            end
            return
        end
        if beat.kind ~= "montage" then
            return
        end
        if option ~= nil then
            option.text = cond(option.text == "", text, option.text .. "\n\n" .. text)
            return
        end
        if entry ~= nil then
            local label, rest = string.match(text, "^(%a+):%s*(.*)$")
            local key = label ~= nil and lower(label) or nil
            if key == "options" or key == "option" then
                entry.approach = cond(entry.approach == "", rest, entry.approach .. "\n\n" .. rest)
                return
            end
            if key == "consequence" or key == "consequences" then
                if entry.kind ~= "threat" then
                    Warn(paragraphLine, "Consequence: on an opportunity (%s) is ignored", entry.name)
                    return
                end
                entry.consequence = { text = rest, effects = EncounterScript.ParseEffects(rest) }
                return
            end
            if EncounterScript.IsScalingDirectiveLine(text) then
                Warn(paragraphLine, "party-size directive '%s' must sit directly under its '## Round N' heading, above the entries; ignored", trim(text))
                return
            end
            entry.description = cond(entry.description == "", text, entry.description .. "\n\n" .. text)
            return
        end
        if round ~= nil then
            --directly under a "## Round N" heading: party-size directives
            --("3-5 Players: -1 Opportunity, -1 Threat"), one per LINE.
            --Anything else in the paragraph is still montage prose.
            local leftover = {}
            local lineIndex = paragraphLine
            for _, l in ipairs(SplitLines(text)) do
                local t = trim(l)
                if EncounterScript.IsScalingDirectiveLine(t) then
                    local directive = EncounterScript.ParseScalingDirective(t)
                    if directive == nil then
                        Warn(lineIndex, "party-size directive '%s' not understood; ignored (use '3-5 Players: -1 Opportunity, -1 Threat')", t)
                    else
                        directive.line = lineIndex
                        round.scaling[#round.scaling + 1] = directive
                    end
                elseif t ~= "" then
                    leftover[#leftover + 1] = t
                end
                lineIndex = lineIndex + 1
            end
            if #leftover == 0 then
                return
            end
            text = table.concat(leftover, "\n")
        end
        beat.intro = cond(beat.intro == "", text, beat.intro .. "\n\n" .. text)
    end

    local i = 1
    while i <= #lines do
        local raw = lines[i]
        local line = trim(raw)

        local h1 = string.match(line, "^#%s+(.+)$")
        local h2 = string.match(line, "^##%s+(.+)$")
        local h3 = string.match(line, "^###%s+(.+)$")
        --a longer heading matches the shorter patterns too; disambiguate.
        if h3 ~= nil then h2 = nil; h1 = nil end
        if h2 ~= nil then h1 = nil end
        if h1 == nil and h2 == nil and h3 == nil and string.match(line, "^####") then
            --deeper headings are prose
            h1, h2, h3 = nil, nil, nil
        end

        if h1 ~= nil then
            FlushParagraph()
            local title = trim(h1)
            local kind = lower(title)
            if kind ~= "montage" and kind ~= "encounter" and kind ~= "narrative" then
                Warn(i, "unknown beat '%s' (expected Montage, Narrative or Encounter); ignored", title)
                kind = "unknown"
            end
            beat = { kind = kind, title = title, line = i, tags = {} }
            if kind == "montage" then
                beat.intro = ""
                beat.rounds = {}
            elseif kind == "narrative" then
                beat.intro = ""
                beat.sections = {}
            elseif kind == "encounter" then
                beat.setup = {}
            end
            result.beats[#result.beats + 1] = beat
            round, entry, section, option = nil, nil, nil, nil
        elseif h2 ~= nil then
            FlushParagraph()
            local title = trim(h2)
            if beat ~= nil and beat.kind == "narrative" then
                section = {
                    name = title,
                    line = i,
                    text = "",
                    prompt = "",
                    mode = "together",
                    options = {},
                }
                section.id = string.format("s%d/%s", #beat.sections + 1, Slug(title))
                beat.sections[#beat.sections + 1] = section
                option = nil
            elseif beat == nil or beat.kind ~= "montage" then
                Warn(i, "'## %s' outside a montage or narrative beat; ignored", title)
            else
                local roundNumber = string.match(lower(title), "^round%s+(%d+)$")
                local entryKind, entryName = string.match(title, "^(%a+):%s*(.+)$")
                entryKind = entryKind ~= nil and lower(entryKind) or nil
                if roundNumber ~= nil then
                    round = { number = tonumber(roundNumber), line = i, entries = {}, scaling = {} }
                    beat.rounds[#beat.rounds + 1] = round
                    entry, option = nil, nil
                elseif entryKind == "opportunity" or entryKind == "threat" then
                    EnsureRound(i)
                    --"## Opportunity: Hunter's Camp (Required)": never
                    --removed by a party-size directive, and the tag itself
                    --is not part of the name shown anywhere.
                    local entryTitle = trim(entryName)
                    local required = false
                    local beforeTag, tag = string.match(entryTitle, "^(.-)%s*%(([^()]*)%)%s*$")
                    if beforeTag ~= nil and lower(trim(tag)) == "required" and trim(beforeTag) ~= "" then
                        required = true
                        entryTitle = trim(beforeTag)
                    end
                    entry = {
                        kind = entryKind,
                        name = entryTitle,
                        required = required,
                        round = round.number,
                        line = i,
                        description = "",
                        approach = "",
                        consequence = nil,
                        options = {},
                    }
                    entry.id = string.format("r%d/%s/%s", round.number, entryKind, Slug(entry.name))
                    round.entries[#round.entries + 1] = entry
                    option = nil
                else
                    Warn(i, "'## %s' is not 'Round N', 'Opportunity: ...' or 'Threat: ...'; ignored", title)
                end
            end
        elseif h3 ~= nil then
            FlushParagraph()
            local title = trim(h3)
            if beat ~= nil and beat.kind == "narrative" then
                if section == nil then
                    Warn(i, "'### %s' outside a narrative '## section'; ignored", title)
                else
                    option = { name = title, line = i, text = "", effects = {} }
                    section.options[#section.options + 1] = option
                end
            elseif entry == nil then
                Warn(i, "'### %s' outside an opportunity/threat; ignored", title)
            else
                option = { name = title, line = i, text = "", roll = nil }
                entry.options[#entry.options + 1] = option
            end
        elseif string.match(line, "^%[%[.+%]%]$") then
            --a rich-tag island on a line of its own
            FlushParagraph()
            local tagText = string.match(line, "^%[%[(.+)%]%]$")
            local tagName = lower(string.match(tagText, "^(.-):") or tagText)
            if tagName == "encounter" then
                result.hasEncounterTag = true
            end
            if beat ~= nil then
                beat.tags[#beat.tags + 1] = tagText
                if beat.kind == "montage" and tagName == "scene" and beat.sceneTag == nil then
                    beat.sceneTag = tagText
                end
                if beat.kind == "narrative" and tagName == "scene" then
                    --inside a section it is that section's backdrop; above
                    --them all it is the beat's.
                    if section ~= nil then
                        if section.sceneTag == nil then
                            section.sceneTag = tagText
                        end
                    elseif beat.sceneTag == nil then
                        beat.sceneTag = tagText
                    end
                end
                if tagName == "encounter" and beat.encounterTag == nil then
                    beat.encounterTag = tagText
                end
            end
        elseif string.match(line, "^|") and beat ~= nil and beat.kind == "narrative" then
            --a narrative option's rules text: one "|clause. clause" line per
            --line, the same clause grammar a montage tier line uses.
            FlushParagraph()
            local effectText = trim(string.gsub(string.match(line, "^|(.*)$") or "", "|%s*$", ""))
            if option == nil then
                Warn(i, "'|%s' is not under a '### option'; ignored", effectText)
            elseif effectText ~= "" then
                for _, effect in ipairs(EncounterScript.ParseEffects(effectText)) do
                    if effect.unrecognized then
                        Warn(i, "unrecognized effect '%s' (shown as text only)", effect.text)
                    end
                    option.effects[#option.effects + 1] = effect
                end
            end
        elseif string.match(line, "^|") then
            --a power roll block: "|Name: Attr" then 3-4 "|tier" lines
            FlushParagraph()
            local name, attr = string.match(line, "^|([^|]+): ([^|]+)$")
            if name == nil then
                Warn(i, "'|' line is not a power roll header (|Name: Attr); ignored")
            else
                local tiers = {}
                local riders = {}
                local j = i + 1
                while j <= #lines do
                    local tierText = string.match(trim(lines[j]), "^|([^|]*)$")
                    if tierText == nil then
                        break
                    end
                    --"|Edge: you speak Caelian" is a rider, not a tier
                    local effect, requirementText = EncounterScript.ParseRiderLine(trim(tierText))
                    if effect ~= nil then
                        if requirementText == "" then
                            Warn(j, "rider '%s' has no requirement; ignored", trim(tierText))
                        else
                            local requirement = EncounterScript.ParseRequirement(requirementText)
                            for _, alt in ipairs(requirement.alternatives) do
                                if alt.kind == "unknown" then
                                    Warn(j, "requirement '%s' not understood (use 'you are skilled in X', 'you speak X' or 'you are a X'); never met", alt.text)
                                end
                            end
                            riders[#riders + 1] = { effect = effect, text = requirementText, requirement = requirement, line = j }
                        end
                    elseif #tiers >= 4 then
                        break
                    else
                        tiers[#tiers + 1] = trim(tierText)
                    end
                    j = j + 1
                end
                if #tiers < 3 then
                    Warn(i, "power roll '%s' has %d tier lines (need 3, optionally 4); ignored", trim(name), #tiers)
                elseif option == nil then
                    Warn(i, "power roll '%s' is not under a '### option'; ignored", trim(name))
                elseif option.roll ~= nil then
                    Warn(i, "option '%s' already has a power roll; '%s' ignored", option.name, trim(name))
                else
                    local roll = { name = trim(name), attr = trim(attr), tiers = tiers, teasers = {}, effects = {}, riders = riders }
                    for t, tierText in ipairs(tiers) do
                        local teaser, fullText = EncounterScript.SplitTeaser(tierText)
                        if teaser == "" then
                            Warn(i + t, "tier %d of '%s' has an empty teaser before '=>'; shown in full", t, trim(name))
                            teaser = nil
                        end
                        tiers[t] = fullText
                        roll.teasers[t] = teaser
                        roll.effects[t] = EncounterScript.ParseEffects(fullText)
                        for _, effect in ipairs(roll.effects[t]) do
                            if effect.unrecognized then
                                Warn(i + t, "unrecognized effect '%s' (shown as text only)", effect.text)
                            end
                        end
                    end
                    option.roll = roll
                end
                i = j - 1
            end
        elseif line == "" then
            FlushParagraph()
        else
            if #paragraph == 0 then
                paragraphLine = i
            end
            paragraph[#paragraph + 1] = line
        end
        i = i + 1
    end
    FlushParagraph()

    --post-parse checks
    for _, b in ipairs(result.beats) do
        if b.kind == "montage" then
            if #b.rounds == 0 then
                Warn(b.line, "montage has no opportunities or threats")
            end
            for _, r in ipairs(b.rounds) do
                for _, d in ipairs(r.scaling or {}) do
                    for kind, n in pairs(d.removals) do
                        local pool = 0
                        for _, e in ipairs(r.entries) do
                            if e.kind == kind and not e.required then
                                pool = pool + 1
                            end
                        end
                        if n > pool then
                            Warn(d.line, "'%s' drops %d %s but round %d introduces only %d that may be removed", d.text, n, kind, r.number, pool)
                        end
                    end
                end
                for _, e in ipairs(r.entries) do
                    if #e.options == 0 then
                        Warn(e.line, "%s '%s' has no options", e.kind, e.name)
                    end
                    for _, o in ipairs(e.options) do
                        if o.roll == nil then
                            Warn(o.line, "option '%s' has no power roll", o.name)
                        end
                    end
                    if e.kind == "threat" and e.consequence == nil then
                        Warn(e.line, "threat '%s' has no Consequence:", e.name)
                    end
                    if e.consequence ~= nil then
                        for _, effect in ipairs(e.consequence.effects) do
                            if effect.unrecognized then
                                Warn(e.line, "unrecognized consequence '%s' (shown as text only)", effect.text)
                            end
                        end
                    end
                end
            end
        elseif b.kind == "narrative" then
            if #b.sections == 0 then
                Warn(b.line, "narrative beat has no '## <section>' headings")
            end
            for _, sec in ipairs(b.sections) do
                if #sec.options == 0 then
                    --text that simply appears: everyone acknowledges it.
                    sec.options[1] = { name = "Proceed", line = sec.line, text = "", effects = {}, implicit = true }
                    sec.implicitOption = true
                elseif #sec.options > 1 and not sec.modeExplicit then
                    Warn(sec.line, "section '%s' does not say 'Choose together:' or 'Choose individually:'; assuming together", sec.name)
                end
            end
        elseif b.kind == "encounter" and b.encounterTag == nil then
            Warn(b.line, "encounter beat has no [[encounter]] island under it")
        end
    end

    --implicit encounter: no beats at all, but an [[encounter]] island
    if #result.beats == 0 and result.hasEncounterTag then
        result.beats[1] = { kind = "encounter", title = "Encounter", line = 0, tags = { "encounter" }, setup = {}, implicit = true }
    end

    return result
end

--Every entry of a montage beat, in document order, each with its round.
function EncounterScript.MontageEntries(beat)
    local result = {}
    for _, r in ipairs((beat and beat.rounds) or {}) do
        for _, e in ipairs(r.entries) do
            result[#result + 1] = e
        end
    end
    return result
end

function EncounterScript.FindEntry(beat, entryId)
    for _, e in ipairs(EncounterScript.MontageEntries(beat)) do
        if e.id == entryId then
            return e
        end
    end
    return nil
end

--Entries available in a given round: everything introduced in that round
--or an earlier one (opportunities and threats both persist round to round
---- user direction 2026-09-18).
function EncounterScript.EntriesForRound(beat, roundNumber)
    local result = {}
    for _, r in ipairs((beat and beat.rounds) or {}) do
        if r.number <= roundNumber then
            for _, e in ipairs(r.entries) do
                result[#result + 1] = e
            end
        end
    end
    return result
end

--The highest round number in the montage (1 when there are no explicit
--rounds).
function EncounterScript.RoundCount(beat)
    local n = 0
    for _, r in ipairs((beat and beat.rounds) or {}) do
        if r.number > n then
            n = r.number
        end
    end
    if n == 0 then
        n = 1
    end
    return n
end

--Every section of a narrative beat, in document order.
function EncounterScript.NarrativeSections(beat)
    return (beat and beat.sections) or {}
end

function EncounterScript.FindSection(beat, sectionId)
    for _, sec in ipairs(EncounterScript.NarrativeSections(beat)) do
        if sec.id == sectionId then
            return sec
        end
    end
    return nil
end

function EncounterScript.SectionCount(beat)
    return #EncounterScript.NarrativeSections(beat)
end

--Every item and monster name the script references, for validation.
function EncounterScript.ReferencedNames(parse)
    local items, monsters = {}, {}
    local function Collect(effects)
        for _, effect in ipairs(effects or {}) do
            if effect.kind == "item" then
                items[effect.name] = true
            elseif effect.kind == "ally" then
                monsters[effect.name] = true
            end
        end
    end
    for _, b in ipairs(parse.beats or {}) do
        for _, sec in ipairs(EncounterScript.NarrativeSections(b)) do
            for _, o in ipairs(sec.options) do
                Collect(o.effects)
            end
        end
        for _, e in ipairs(EncounterScript.MontageEntries(b)) do
            if e.consequence ~= nil then
                Collect(e.consequence.effects)
            end
            for _, o in ipairs(e.options) do
                if o.roll ~= nil then
                    for _, effects in pairs(o.roll.effects) do
                        Collect(effects)
                    end
                end
            end
        end
    end
    return items, monsters
end

--Plain-text dump of a parse, for the /eotwscript command and tests.
function EncounterScript.Describe(parse)
    local out = {}
    local function line(fmt, ...)
        out[#out + 1] = string.format(fmt, ...)
    end
    for bi, b in ipairs(parse.beats or {}) do
        line("beat %d: %s (%s)%s", bi, b.title, b.kind, cond(b.implicit, " [implicit]", ""))
        if b.kind == "encounter" then
            for _, ins in ipairs(b.setup or {}) do
                if ins.kind == "placeobjects" then
                    line("  setup %s: place %d x '%s' in %s zones%s", ins.label, ins.qty, ins.object, ins.zone,
                        cond(ins.deleteOthers, ", delete the other " .. ins.zone .. " zones", ""))
                else
                    line("  setup %s: UNRECOGNIZED '%s'", ins.label, ins.text)
                end
            end
        end
        if b.kind == "narrative" then
            if b.sceneTag ~= nil then
                line("  scene: [[%s]]", b.sceneTag)
            end
            for _, sec in ipairs(b.sections) do
                line("  section: %s  [%s] (%s)", sec.name, sec.id, sec.mode)
                if sec.sceneTag ~= nil then
                    line("    scene: [[%s]]", sec.sceneTag)
                end
                if sec.prompt ~= "" then
                    line("    prompt: %s", sec.prompt)
                end
                for _, o in ipairs(sec.options) do
                    line("    option: %s%s", o.name, cond(o.implicit, " (implicit)", ""))
                    for _, effect in ipairs(o.effects) do
                        line("      - %s", EncounterScript.DescribeEffect(effect))
                    end
                end
            end
        elseif b.kind == "montage" then
            if b.sceneTag ~= nil then
                line("  scene: [[%s]]", b.sceneTag)
            end
            for _, r in ipairs(b.rounds) do
                line("  round %d%s", r.number, cond(r.implicit, " (implicit)", ""))
                for _, d in ipairs(r.scaling or {}) do
                    local parts = {}
                    for kind, n in pairs(d.removals) do
                        parts[#parts + 1] = string.format("-%d %s", n, kind)
                    end
                    table.sort(parts)
                    line("    scaling: %d%s players -> %s", d.min,
                        cond(d.max == nil, "+", cond(d.max == d.min, "", "-" .. tostring(d.max))),
                        table.concat(parts, ", "))
                end
                for _, e in ipairs(r.entries) do
                    line("    %s: %s%s  [%s]", e.kind, e.name, cond(e.required, " (required)", ""), e.id)
                    if e.consequence ~= nil then
                        line("      consequence: %s", e.consequence.text)
                        for _, effect in ipairs(e.consequence.effects) do
                            line("        - %s", EncounterScript.DescribeEffect(effect))
                        end
                    end
                    for _, o in ipairs(e.options) do
                        line("      option: %s", o.name)
                        if o.roll ~= nil then
                            line("        roll: %s: %s", o.roll.name, o.roll.attr)
                            for t, tierText in ipairs(o.roll.tiers) do
                                if o.roll.teasers[t] ~= nil then
                                    line("        tier %d: [%s] => %s", t, o.roll.teasers[t], tierText)
                                else
                                    line("        tier %d: %s", t, tierText)
                                end
                                for _, effect in ipairs(o.roll.effects[t]) do
                                    line("          - %s", EncounterScript.DescribeEffect(effect))
                                end
                            end
                            for _, rider in ipairs(o.roll.riders or {}) do
                                local alts = {}
                                for _, alt in ipairs(rider.requirement.alternatives) do
                                    alts[#alts + 1] = string.format("%s=%s", alt.kind, alt.name)
                                end
                                line("        %s: %s (%s)", EncounterScript.RiderLabel(rider.effect), rider.text, table.concat(alts, " | "))
                            end
                        end
                    end
                end
            end
        end
    end
    for _, w in ipairs(parse.warnings or {}) do
        line("WARNING %s", w)
    end
    return table.concat(out, "\n")
end

--"1 surge" / "2 surges": a count with the noun it counts, correctly
--pluralized. The plural defaults to the singular with an "s" on the end;
--pass it explicitly for anything irregular. Written without cond() so the
--pure-Lua parser tests can call it with no engine globals present.
function EncounterScript.Plural(qty, singular, plural)
    if qty == 1 then
        return string.format("%d %s", qty, singular)
    end
    return string.format("%d %s", qty, plural or (singular .. "s"))
end

function EncounterScript.DescribeEffect(effect)
    if effect.kind == "item" then
        return string.format("%s gains %d x %s", cond(effect.target == "party", "every hero", "the hero"), effect.qty, effect.name)
    elseif effect.kind == "stamina" then
        return string.format("%s loses %d stamina", cond(effect.target == "party", "every hero", "the hero"), effect.qty)
    elseif effect.kind == "heal" then
        return string.format("%s heals %d stamina", cond(effect.target == "party", "every hero", "the hero"), effect.qty)
    elseif effect.kind == "temphp" then
        return string.format("%s gains %d temporary stamina", cond(effect.target == "party", "every hero", "the hero"), effect.qty)
    elseif effect.kind == "surges" then
        return string.format("%s gains %s at the start of the next combat", cond(effect.target == "party", "every hero", "the hero"), EncounterScript.Plural(effect.qty, "surge"))
    elseif effect.kind == "recovery" then
        return string.format("%s recovery value is increased by %d until the next respite", cond(effect.target == "party", "every hero's", "the hero's"), effect.qty)
    elseif effect.kind == "loserecovery" then
        return string.format("%s loses %s", cond(effect.target == "party", "every hero", "the hero"), EncounterScript.Plural(effect.qty, "recovery", "recoveries"))
    elseif effect.kind == "herotoken" then
        return string.format("the party gains %s", EncounterScript.Plural(effect.qty, "hero token"))
    elseif effect.kind == "malice" then
        return string.format("+%d malice", effect.qty)
    elseif effect.kind == "ally" then
        return string.format("%s joins the hero", effect.name)
    elseif effect.kind == "vanquish" then
        return "the threat is vanquished"
    elseif effect.kind == "initiative" then
        return EncounterScript.DescribeInitiativeOutcome(effect.outcome)
    elseif effect.kind == "nosurprise" then
        return EncounterScript.DescribeSurpriseImmunity()
    elseif effect.kind == "knowstamina" then
        return EncounterScript.DescribeKnowStamina(effect.keyword)
    elseif effect.kind == "revealzones" then
        return EncounterScript.DescribeRevealZones(effect.zone)
    end
    return string.format("narrative%s: %s", cond(effect.unrecognized, " (unrecognized)", ""), effect.text)
end

--The player-facing line for a stamina reveal: "The party knows the Stamina
--of Goblins".
function EncounterScript.DescribeKnowStamina(keyword)
    keyword = tostring(keyword or "")
    local shown = string.upper(string.sub(keyword, 1, 1)) .. string.sub(keyword, 2) .. "s"
    return string.format("The party knows the Stamina of %s", shown)
end

--The player-facing line for an initiative outcome (also what the stage
--shows in the applied-effects list).
function EncounterScript.DescribeInitiativeOutcome(outcome)
    if outcome == "surprised" then
        return "The heroes will begin the encounter surprised"
    elseif outcome == "surprise" then
        return "The heroes will surprise the enemy"
    elseif outcome == "win" then
        return "The heroes will win initiative"
    elseif outcome == "lose" then
        return "The heroes will lose initiative"
    end
    return string.format("initiative: %s", tostring(outcome))
end

--The player-facing line for the surprise-immunity boon.
function EncounterScript.DescribeSurpriseImmunity()
    return "The heroes cannot be surprised"
end
