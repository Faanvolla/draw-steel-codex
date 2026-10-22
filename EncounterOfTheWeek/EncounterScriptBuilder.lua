local mod = dmhub.GetModLoading()

--Encounter of the Week: the Encounter Builder.
--
--The whole-script view of the builder window (EncounterMontageBuilder.lua
--owns the window, the session, the undo stack and the shared form pieces;
--this file draws its "script" view). It shows the script as an author thinks
--of it: the optional features it turns on, the Town Gate text, the beats in
--the order they play (narratives, montages, the encounter) and the
--Conclusion / Defeat screens. Each has a form; a montage opens the Montage
--Builder. As everywhere in the builder, the markdown stays the source of
--truth: every change is a line patch on the document the text came from.
--Design: EncounterOfTheWeek.md, "The Encounter Builder".
--
--Every function takes `ctx`, the window's toolkit (see "What the script
--view builds with" in EncounterMontageBuilder.lua): session, Commit, Do,
--Refresh, OutcomeEditor, PickDropdown, NameOptions, Word, TextBox, Label,
--Row, SmallButton, ConfirmButton, close, ScrollEditorTop, OpenMontage.

EncounterScriptBuilder = {}
local S = EncounterScriptBuilder
local E = EncounterScriptEdit

local KIND_COLOR = {
    narrative = "#7fb7d9",
    montage = "#6fae7a",
    encounter = "#c46a6a",
    story = "#c9a96a",
    features = "#d9b3ff",
}
local PROBLEM_COLOR = "#e88a8a"
local ON_COLOR = "#7fd97f"

--The story screens, in the order they are seen.
local STORY = {
    towngate = { key = "towngate", title = "Town Gate", note = "Shown in town under the encounter while a party forms: why the heroes should come.",
        starter = "Why the heroes have come here." },
    conclusion = { key = "conclusion", title = "Conclusion", note = "The story screen after a victory, before the heroes return to Blackbottom.",
        starter = "What the heroes' victory means." },
    defeat = { key = "defeat", title = "Defeat", note = "The story screen after a defeat.",
        starter = "What the heroes' defeat means." },
}

local function trim(s)
    return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"))
end

local function lower(s)
    return string.lower(s or "")
end

--A patch (or nil + why) as a list for Commit.
local function One(patch, why)
    if patch == nil then
        return nil, why
    end
    return { patch }
end

local function DocsTable()
    return dmhub.GetTable("documents") or {}
end

--A narrative scene's written choices. A scene with none gets an implicit
--"Proceed" from the parser, which has no line of its own to edit.
local function RealOptions(section)
    local result = {}
    for _, o in ipairs(section.options or {}) do
        if not o.implicit then
            result[#result + 1] = o
        end
    end
    return result
end

--- reading the script ----------------------------------------------------------------

--What a beat is called on the outline: a narrative by its first scene.
function S.BeatLabel(beat)
    if beat.kind == "narrative" then
        local first = beat.sections ~= nil and beat.sections[1] or nil
        if first ~= nil then
            return "Narrative: " .. first.name
        end
        return "Narrative"
    elseif beat.kind == "montage" then
        return "Montage"
    elseif beat.kind == "encounter" then
        return "Encounter"
    end
    return beat.title or "Beat"
end

--One line saying what is in a beat.
function S.BeatSummary(beat)
    if beat.kind == "narrative" then
        local options = 0
        for _, s in ipairs(beat.sections or {}) do
            options = options + #RealOptions(s)
        end
        return string.format("%d scene%s, %d choice%s", #(beat.sections or {}), cond(#(beat.sections or {}) == 1, "", "s"),
            options, cond(options == 1, "", "s"))
    elseif beat.kind == "montage" then
        local entries = 0
        for _, r in ipairs(beat.rounds or {}) do
            entries = entries + #(r.entries or {})
        end
        return string.format("%d round%s, %d opportunit%s and threats", #(beat.rounds or {}), cond(#(beat.rounds or {}) == 1, "", "s"),
            entries, cond(entries == 1, "y", "ies"))
    elseif beat.kind == "encounter" then
        local parts = { cond(beat.encounterTag ~= nil, "monsters placed", "NO monsters ([[encounter]] missing)") }
        if #(beat.setup or {}) > 0 then
            parts[#parts + 1] = string.format("%d setup line%s", #beat.setup, cond(#beat.setup == 1, "", "s"))
        end
        if #(beat.reinforcements or {}) > 0 then
            parts[#parts + 1] = string.format("%d reinforcement group%s", #beat.reinforcements, cond(#beat.reinforcements == 1, "", "s"))
        end
        return table.concat(parts, ", ")
    end
    return ""
end

--Where each beat sits in the master document: { [beatIndex] = { first,
--last, shared } } in master lines. A beat written in an included document
--sits at its include link; `shared` when one link brings in several
--top-level sections (it cannot be moved or deleted on its own here).
function S.RootSpans(session)
    local parse = session.parse
    local lines = E.Split(session.texts[session.rootId] or "").lines
    local elements = {}
    for i, b in ipairs(parse.beats or {}) do
        if (b.line or 0) > 0 then
            elements[#elements + 1] = { beat = i, line = b.line }
        end
    end
    for _, st in pairs(parse.story or {}) do
        elements[#elements + 1] = { line = st.line }
    end
    for _, d in pairs(parse.delves or {}) do
        elements[#elements + 1] = { line = d.line }
    end
    if parse.part ~= nil then
        elements[#elements + 1] = { line = parse.part.line }
    end
    local starts, count = {}, {}
    for _, el in ipairs(elements) do
        el.root = E.RootLine(parse, el.line)
        if el.root ~= nil then
            if count[el.root] == nil then
                starts[#starts + 1] = el.root
            end
            count[el.root] = (count[el.root] or 0) + 1
        end
    end
    table.sort(starts)
    local spans = {}
    for _, el in ipairs(elements) do
        if el.beat ~= nil and el.root ~= nil then
            local last = #lines
            for _, st in ipairs(starts) do
                if st > el.root then
                    last = st - 1
                    break
                end
            end
            while last > el.root and trim(lines[last]) == "" do
                last = last - 1
            end
            spans[el.beat] = { first = el.root, last = last, shared = count[el.root] > 1 }
        end
    end
    return spans
end

--The last non-blank line of the master document.
local function LastTextLine(session)
    local lines = E.Split(session.texts[session.rootId] or "").lines
    local last = #lines
    while last > 0 and trim(lines[last]) == "" do
        last = last - 1
    end
    return last
end

--Every "Unlock: <feature>" in the script: { { feature, line, beat, section } }.
function S.Unlocks(session)
    local result = {}
    for _, b in ipairs(session.parse.beats or {}) do
        for _, u in ipairs(b.unlocks or {}) do
            result[#result + 1] = { feature = u.feature, line = u.line, beat = b }
        end
        for _, sec in ipairs(b.sections or {}) do
            for _, u in ipairs(sec.unlocks or {}) do
                result[#result + 1] = { feature = u.feature, line = u.line, beat = b, section = sec }
            end
        end
    end
    return result
end

--How many outcomes in the script grant Intelligence.
function S.IntelligenceGrants(session)
    local n = 0
    local function Scan(effects)
        for _, e in ipairs(effects or {}) do
            if e.kind == "intelligence" then
                n = n + 1
            end
        end
    end
    for _, b in ipairs(session.parse.beats or {}) do
        for _, sec in ipairs(b.sections or {}) do
            for _, o in ipairs(sec.options or {}) do
                Scan(o.effects)
            end
        end
        for _, e in ipairs(EncounterScript.MontageEntries(b)) do
            if e.consequence ~= nil then
                Scan(e.consequence.effects)
            end
            for _, o in ipairs(e.options or {}) do
                for _, effects in ipairs(EncounterScript.OptionEffectLists(o)) do
                    Scan(effects)
                end
            end
        end
    end
    return n
end

--Parser notes the builder shows as a choice rather than a problem: the
--form already says it ("Enter: where their group was placed").
local NOT_PROBLEMS = { "have no 'Enter:' zone" }

--Problems (not text-only notes) inside the element headed at `line`.
local function Problems(session, line, level)
    local result = {}
    for _, w in ipairs(EncounterMontageBuilder.WarningsIn(session, line, level)) do
        local note = w.textOnly
        for _, pattern in ipairs(NOT_PROBLEMS) do
            if string.find(w.message or "", pattern, 1, true) ~= nil then
                note = true
            end
        end
        if not note then
            result[#result + 1] = w
        end
    end
    return result
end

--- changing the script's structure ---------------------------------------------------

--Move beat `index` up (-1) or down (+1) past its neighbour.
function S.MoveBeat(ctx, index, dir)
    local session = ctx.session
    local beats = session.parse.beats
    local other = index + dir
    if beats[index] == nil or beats[other] == nil then
        return
    end
    local spans = S.RootSpans(session)
    local a, b = spans[math.min(index, other)], spans[math.max(index, other)]
    if a == nil or b == nil or a.shared or b.shared then
        session.status = "Not moved: that beat shares its journal document with other sections; move it in the journal."
        ctx.Refresh()
        return
    end
    local lines = E.Split(session.texts[session.rootId]).lines
    local swapped, map = E.SwapBlocks(lines, a.first, a.last, b.first, b.last)
    local region = {}
    for l = a.first, b.last do
        region[#region + 1] = swapped[l]
    end
    local ok, changed = pcall(E.Apply, session.texts, { E.Patch(session.rootId, a.first, b.last, region) })
    if not ok then
        session.status = "Not moved: " .. tostring(changed)
        ctx.Refresh()
        return
    end
    ctx.Do(function()
        if EncounterMontageBuilder.CommitTexts(session, string.format("Moved '%s' %s.", S.BeatLabel(beats[index]), cond(dir < 0, "earlier", "later")),
            changed, { [session.rootId] = map }) then
            session.scriptSelected = { kind = "beat", index = other }
        end
    end)
end

--Delete beat `index` (with the blank lines after it).
function S.DeleteBeat(ctx, index)
    local session = ctx.session
    local beat = session.parse.beats[index]
    local span = S.RootSpans(session)[index]
    if beat == nil or span == nil then
        return
    end
    if span.shared then
        session.status = "Not deleted: that beat shares its journal document with other sections; delete it in the journal."
        ctx.Refresh()
        return
    end
    local lines = E.Split(session.texts[session.rootId]).lines
    local last = span.last
    while last < #lines and trim(lines[last + 1]) == "" do
        last = last + 1
    end
    session.scriptSelected = nil
    ctx.Commit(string.format("Deleted '%s'.", S.BeatLabel(beat)), { E.Patch(session.rootId, span.first, last, {}) }, nil, { keepTags = true })
end

--Add a new beat of `kind`: a narrative or montage goes in front of the
--encounter (the fight comes last), an encounter at the end.
function S.AddBeat(ctx, kind)
    local session = ctx.session
    local beats = session.parse.beats or {}
    local spans = S.RootSpans(session)
    local encounterIndex = nil
    for i, b in ipairs(beats) do
        if b.kind == "encounter" and spans[i] ~= nil then
            encounterIndex = i
        end
    end
    local anchor = nil
    if kind ~= "encounter" and encounterIndex ~= nil then
        anchor = spans[encounterIndex].first - 1
        --insert after the blank line(s) above the encounter, not between them.
        local lines = E.Split(session.texts[session.rootId]).lines
        while anchor > 0 and trim(lines[anchor]) == "" do
            anchor = anchor - 1
        end
    else
        for i = #beats, 1, -1 do
            if spans[i] ~= nil then
                anchor = spans[i].last
                break
            end
        end
        anchor = anchor or LastTextLine(session)
    end
    local block = kind == "narrative" and E.NarrativeBeatBlock() or (kind == "montage" and E.MontageBeatBlock() or E.EncounterBeatBlock())
    local patch = E.InsertBlockAfterDocLine(session.texts, session.rootId, anchor, block)
    local before = #beats
    ctx.Do(function()
        if EncounterMontageBuilder.Commit(session, string.format("Added a %s beat.", kind), { patch }, nil, { keepTags = true }) then
            --select the new beat: the first of that kind starting below the anchor.
            local newBeats = session.parse.beats
            local newSpans = S.RootSpans(session)
            local best = nil
            for i, b in ipairs(newBeats) do
                local span = newSpans[i]
                if b.kind == kind and span ~= nil and span.first > anchor and (best == nil or span.first < newSpans[best].first) then
                    best = i
                end
            end
            if best ~= nil then
                session.scriptSelected = { kind = "beat", index = best }
            end
            if #newBeats <= before then
                session.status = "Added, but the new beat did not parse: check the journal."
            end
        end
    end)
    ctx.ScrollEditorTop()
end

--Add a story screen (Town Gate, Conclusion, Defeat) at the end of the master.
function S.AddStory(ctx, key)
    local session = ctx.session
    local info = STORY[key]
    local patch = E.InsertBlockAfterDocLine(session.texts, session.rootId, LastTextLine(session), E.StoryBlock(info.title, info.starter))
    session.scriptSelected = { kind = "story", key = key }
    ctx.Commit(string.format("Added the %s text.", info.title), { patch }, nil, { keepTags = true })
end

--Turn a feature on (an "Unlock:" line in the first narrative beat, made if
--there is none) or off (every "Unlock:" line for it goes).
function S.SetFeature(ctx, feature, on)
    local session = ctx.session
    local parse = session.parse
    if not on then
        local patches = {}
        for _, u in ipairs(S.Unlocks(session)) do
            if u.feature == feature.key then
                local p = E.PatchExpanded(parse, u.line, u.line, {})
                if p ~= nil then
                    patches[#patches + 1] = p
                end
            end
        end
        ctx.Commit(string.format("Turned %s off.", feature.name), patches)
        return
    end
    for _, b in ipairs(parse.beats or {}) do
        if b.kind == "narrative" then
            local after = b.line
            for _, span in ipairs(b.introLines or {}) do
                after = math.max(after, span[2])
            end
            ctx.Commit(string.format("Turned %s on (in the first narrative).", feature.name),
                One(E.InsertBlockAfter(parse, session.texts, after, { E.UnlockLine(feature.name) })))
            return
        end
    end
    --no narrative yet: one at the start, which unlocks it as the game opens.
    local spans = S.RootSpans(session)
    local anchor = spans[1] ~= nil and spans[1].first - 1 or LastTextLine(session)
    local lines = E.Split(session.texts[session.rootId]).lines
    while anchor > 0 and trim(lines[anchor]) == "" do
        anchor = anchor - 1
    end
    local block = { "# Narrative", "", "The heroes prepare for what lies ahead.", "", E.UnlockLine(feature.name), "",
        "## Preparations", "", "Describe the scene." }
    ctx.Commit(string.format("Turned %s on (in a new narrative at the start).", feature.name),
        { E.InsertBlockAfterDocLine(session.texts, session.rootId, anchor, block) }, nil, { keepTags = true })
end

--- the outline (left) ------------------------------------------------------------------

local function Card(ctx, selection, color, kindText, title, sub, problems, tools)
    local session = ctx.session
    local s = session.scriptSelected
    local isSelected = s ~= nil and s.kind == selection.kind and s.index == selection.index and s.key == selection.key
    ---@type Panel[]
    local children = {
        ctx.Row({
            gui.Label{ fontSize = 11, bold = true, color = color, width = "auto", height = "auto", valign = "center", rmargin = 6, text = kindText },
            gui.Label{ fontSize = 15, bold = true, width = "100%-170", height = "auto", textWrap = true, text = title },
            gui.Panel{ width = "auto", height = "auto", halign = "right", flow = "horizontal", children = tools or {} },
        }),
    }
    if sub ~= nil and sub ~= "" then
        children[#children + 1] = ctx.Label(sub, { "mbSub" })
    end
    if problems ~= nil and problems > 0 then
        children[#children + 1] = ctx.Label(string.format("%d problem%s", problems, cond(problems == 1, "", "s")), { "mbProblem" })
    end
    return gui.Panel{
        classes = { "mbCard", cond(isSelected, "selected", nil) },
        borderColor = cond(isSelected, nil, color),
        children = children,
        click = function()
            session.scriptSelected = selection
            ctx.Refresh()
            ctx.ScrollEditorTop()
        end,
    }
end

local function TinyButton(text, tooltip, onClick)
    return gui.Button{
        classes = { "sizeXs" },
        width = 24,
        height = 22,
        lmargin = 2,
        text = text,
        hover = gui.Tooltip(tooltip),
        click = function()
            onClick()
        end,
    }
end

function S.Outline(ctx)
    local session = ctx.session
    local parse = session.parse
    local children = {}

    if parse.part ~= nil then
        children[#children + 1] = ctx.Label(string.format("Part %d of a series%s.", parse.part.number,
            parse.part.title ~= nil and (": " .. parse.part.title) or ""), { "mbSub" })
    end

    --optional features.
    local unlocked = EncounterScript.UnlockedFeatures(parse)
    local featureNames = {}
    for _, f in pairs(EncounterScript.FEATURES) do
        featureNames[#featureNames + 1] = f.name .. ": " .. cond(unlocked[f.key], "on", "off")
    end
    table.sort(featureNames)
    children[#children + 1] = Card(ctx, { kind = "features" }, KIND_COLOR.features, "FEATURES", "Optional features",
        table.concat(featureNames, "  |  "), 0, {})

    --before the adventure.
    children[#children + 1] = ctx.Label("Before the adventure", { "mbHeading" }, { tmargin = 10 })
    local story = parse.story or {}
    if story.towngate ~= nil then
        children[#children + 1] = Card(ctx, { kind = "story", key = "towngate" }, KIND_COLOR.story, "STORY", "Town Gate",
            string.sub(story.towngate.text or "", 1, 80), #Problems(session, story.towngate.line, 1), {})
    else
        children[#children + 1] = ctx.Row({ ctx.SmallButton("+ Town Gate text", function() ctx.Do(function() S.AddStory(ctx, "towngate") end) end) }, { fit = true })
    end

    --the beats, in the order they play.
    children[#children + 1] = ctx.Label("The adventure, in order", { "mbHeading" }, { tmargin = 10 })
    local beats = parse.beats or {}
    local spans = S.RootSpans(session)
    local hasEncounter = false
    for i, beat in ipairs(beats) do
        local index = i
        if beat.kind == "encounter" then
            hasEncounter = true
        end
        local tools = {}
        if not beat.implicit and spans[i] ~= nil then
            if i > 1 then
                tools[#tools + 1] = TinyButton("^", "Play this earlier", function() S.MoveBeat(ctx, index, -1) end)
            end
            if i < #beats then
                tools[#tools + 1] = TinyButton("v", "Play this later", function() S.MoveBeat(ctx, index, 1) end)
            end
        end
        local problems = 0
        if (beat.line or 0) > 0 then
            problems = #Problems(session, beat.line, 1)
        end
        children[#children + 1] = Card(ctx, { kind = "beat", index = index }, KIND_COLOR[beat.kind] or "#b0b0b0",
            string.format("%d. %s", i, string.upper(beat.kind)), S.BeatLabel(beat), S.BeatSummary(beat), problems, tools)
    end
    if #beats == 0 then
        children[#children + 1] = ctx.Label("No beats yet.", { "mbSub" })
    end
    local addRow = {
        ctx.SmallButton("+ Narrative", function() S.AddBeat(ctx, "narrative") end),
        ctx.SmallButton("+ Montage", function() S.AddBeat(ctx, "montage") end),
    }
    if not hasEncounter then
        addRow[#addRow + 1] = ctx.SmallButton("+ Encounter", function() S.AddBeat(ctx, "encounter") end)
    end
    children[#children + 1] = ctx.Row(addRow, { fit = true, tmargin = 4 })
    children[#children + 1] = ctx.Label("A narrative or montage is added in front of the encounter; ^ and v change the order.", { "mbSub" })

    --after the adventure.
    children[#children + 1] = ctx.Label("After the adventure", { "mbHeading" }, { tmargin = 10 })
    local missing = {}
    for _, key in ipairs({ "conclusion", "defeat" }) do
        local st = story[key]
        if st ~= nil then
            children[#children + 1] = Card(ctx, { kind = "story", key = key }, KIND_COLOR.story, "STORY", STORY[key].title,
                string.sub(st.text or "", 1, 80), #Problems(session, st.line, 1), {})
        else
            local k = key
            missing[#missing + 1] = ctx.SmallButton("+ " .. STORY[key].title .. " text", function() ctx.Do(function() S.AddStory(ctx, k) end) end)
        end
    end
    if #missing > 0 then
        children[#children + 1] = ctx.Row(missing, { fit = true })
    end
    return children
end

--- the editors (right) -----------------------------------------------------------------

local function OpenInJournal(ctx, line)
    local docid = E.Source(ctx.session.parse, line)
    local doc = DocsTable()[docid]
    ctx.close()
    if doc ~= nil then
        doc:ShowDocument{}
    end
end


--- the combat Encounter Builder for an [[encounter]] island ---------------------------

--The document and data key of the [[encounter]] island on expanded line
--`line` (the journal keys repeated tags by order: "encounter",
--"encounter-1", ...). nil when that line holds no such tag.
local function IslandKey(session, line)
    local docid, at = E.Source(session.parse, line)
    if docid == nil then
        return nil
    end
    for _, o in ipairs(E.TagOccurrences(E.Split(session.texts[docid] or "").lines)) do
        if o.line == at and lower(string.match(o.name, "^[^:]*") or "") == "encounter" then
            return docid, o.key
        end
    end
    return nil
end

--The encounter an island holds, or nil when it has none saved yet.
local function IslandEncounter(session, line)
    local docid, key = IslandKey(session, line)
    local doc = docid ~= nil and DocsTable()[docid] or nil
    local result = nil
    if doc ~= nil then
        pcall(function()
            local tag = (doc:try_get("annotations") or {})[key]
            if tag ~= nil then
                result = tag:try_get("encounter")
            end
        end)
    end
    return result
end

--One line about an island's monsters: who, and the encounter value.
local function IslandSummary(session, line)
    local encounter = IslandEncounter(session, line)
    if encounter == nil then
        return "No monsters yet."
    end
    local text, ev = nil, nil
    pcall(function() text = encounter:Describe() end)
    pcall(function() ev = encounter:CountEDS() end)
    --one line: the description's lines joined, no separator left dangling.
    text = (string.gsub(trim(tostring(text or "")), "%s*[\r\n]+%s*", "; "))
    if text == "" then
        text = "No monsters yet."
    end
    if ev ~= nil and ev > 0 then
        text = string.format("%s  (EV %d)", text, ev)
    end
    return text
end

--Open the combat Encounter Builder (the same one the journal island's
--settings button opens) on the island at expanded line `line`. This window
--closes so the map is free for staging monsters; every Save in the
--Encounter Builder writes the encounter back into the script document under
--the island's key. Reopen the Encounter Builder from the Game menu after.
function S.OpenCombatBuilder(ctx, line)
    local session = ctx.session
    local docid, key = IslandKey(session, line)
    if docid == nil or key == nil then
        session.status = "Could not find that [[encounter]] island in its document."
        ctx.Refresh()
        return
    end
    ctx.close()
    --after this window's own uploads land (an island just added).
    dmhub.Schedule(0.5, function()
        if mod.unloaded then
            return
        end
        local doc = DocsTable()[docid]
        if doc == nil then
            return
        end
        local existing = nil
        pcall(function() existing = (doc:try_get("annotations") or {})[key] end)
        --work on a copy: it only reaches the document when Save is pressed.
        local tag = existing ~= nil and DeepCopy(existing) or RichEncounter.Create()
        tag.encounter:CreateEditorDialog{
            mode = "Save",
            journal = true,
            save = function()
                local live = DocsTable()[docid]
                if live == nil then
                    return
                end
                --script documents are journal (markdown) documents.
                ---@cast live MarkdownDocument
                local original = DeepCopy(live)
                local annotations = live:try_get("annotations") or {}
                annotations[key] = DeepCopy(tag)
                live.annotations = annotations
                live:Upload(original)
            end,
        }
    end)
end

--The "Open Combat Encounter Builder" button for the island on expanded line
--`line`; with no line, `addIsland()` writes the [[encounter]] tag first and
--returns the new island's line.
local function CombatBuilderButton(ctx, line, addIsland)
    return gui.Button{
        classes = { "sizeS" },
        width = "auto",
        height = 30,
        hpad = 14,
        borderBox = true,
        text = "Open Combat Encounter Builder",
        hover = gui.Tooltip("Pick the monsters, balance the encounter and place them on the map. Saving there saves them into this script."),
        click = function()
            local target = line
            if target == nil and addIsland ~= nil then
                ctx.Do(function() target = addIsland() end)
            end
            if target ~= nil then
                S.OpenCombatBuilder(ctx, target)
            end
        end,
    }
end

--`skip` = { [message] = true }: already shown further in (a reinforcement's own).
local function ProblemLabels(ctx, line, level, children, skip)
    for _, w in ipairs(Problems(ctx.session, line, level)) do
        if skip == nil or not skip[w.message] then
            children[#children + 1] = ctx.Label(w.message, { "mbProblem" })
        end
    end
end

function S.FeaturesEditor(ctx)
    local session = ctx.session
    local children = { ctx.Label("OPTIONAL FEATURES", { "mbHeading" }, { color = KIND_COLOR.features }) }
    children[#children + 1] = ctx.Label("Parts of Encounter of the Week a script turns on for itself. A feature the script does not turn on is not part of the game at all.", { "mbSub" })
    local unlocked = EncounterScript.UnlockedFeatures(session.parse)
    local unlocks = S.Unlocks(session)
    local keys = {}
    for k in pairs(EncounterScript.FEATURES) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local feature = EncounterScript.FEATURES[key]
        local on = unlocked[key] == true
        local section = {
            gui.Check{
                classes = { "sizeXs" },
                fontSize = 16,
                width = 400,
                height = 26,
                text = feature.name,
                value = on,
                change = function(element)
                    ctx.Do(function() S.SetFeature(ctx, feature, element.value == true) end)
                end,
            },
            ctx.Label("Turns on " .. feature.summary .. ".", { "mbSub" }),
        }
        if on then
            for _, u in ipairs(unlocks) do
                if u.feature == key then
                    local where = S.BeatLabel(u.beat)
                    if u.section ~= nil then
                        where = string.format("the scene '%s' of %s", u.section.name, where)
                    end
                    section[#section + 1] = ctx.Label(string.format("ON: explained to the party when %s opens.", where), { "mbRule" }, { color = ON_COLOR })
                end
            end
            if key == "intelligence" then
                local grants = S.IntelligenceGrants(session)
                if grants == 0 then
                    section[#section + 1] = ctx.Label("Nothing in the script grants Intelligence yet: add 'Reward: Intelligence' to some outcomes.", { "mbProblem" })
                else
                    section[#section + 1] = ctx.Label(string.format("%d outcome%s grant%s Intelligence.", grants, cond(grants == 1, "", "s"), cond(grants == 1, "s", "")), { "mbSub" })
                end
            end
            section[#section + 1] = ctx.Label("What the party is told: " .. tostring(feature.explanation or ""), { "mbSub" })
        else
            section[#section + 1] = ctx.Label("OFF. Ticking it writes 'Unlock: " .. feature.name .. "' into the first narrative beat (one is made at the start if the script has none), so the party is told about it as that beat opens.", { "mbSub" })
            if key == "intelligence" and S.IntelligenceGrants(session) > 0 then
                section[#section + 1] = ctx.Label("Some outcomes grant Intelligence, but it is off: the party could never spend it.", { "mbProblem" })
            end
        end
        children[#children + 1] = gui.Panel{ classes = { "mbSection" }, children = section }
    end
    return children
end

function S.StoryEditor(ctx, key)
    local session = ctx.session
    local parse = session.parse
    local st = (parse.story or {})[key]
    local info = STORY[key]
    local children = { ctx.Label(string.upper(info.title), { "mbHeading" }, { color = KIND_COLOR.story }) }
    children[#children + 1] = ctx.Label(info.note, { "mbSub" })
    if st == nil then
        children[#children + 1] = ctx.Row({ ctx.SmallButton("+ Add it", function() ctx.Do(function() S.AddStory(ctx, key) end) end) }, { fit = true })
        return children
    end
    children[#children + 1] = ctx.TextBox(st.text, function(text)
        ctx.Commit(string.format("Edited the %s text.", info.title), E.SetProse(parse, session.texts, st.textLines, st.line, text))
    end, { multiline = true, minHeight = 120, maxHeight = 500, placeholder = info.starter })
    if st.sceneTag ~= nil then
        children[#children + 1] = ctx.Label("Backdrop: its [[scene]] picture (set in the journal).", { "mbSub" })
    end
    ProblemLabels(ctx, st.line, 1, children)
    children[#children + 1] = ctx.Row({
        ctx.SmallButton("Open in journal", function() OpenInJournal(ctx, st.line) end),
        ctx.ConfirmButton("Delete this text", function()
            session.scriptSelected = nil
            ctx.Commit(string.format("Deleted the %s text.", info.title), E.DeleteElement(parse, session.texts, st.line, 1), nil, { keepTags = true })
        end),
    }, { fit = true, tmargin = 8 })
    return children
end

--A narrative option's rules: one outcome editor per "|" line.
local function NarrativeRules(ctx, o, children)
    local session = ctx.session
    local parse = session.parse
    local lines = o.ruleLines or {}
    if #lines == 0 then
        children[#children + 1] = ctx.OutcomeEditor("", function(text)
            if trim(text) ~= "" then
                ctx.Commit("Added what a choice does.", E.InsertAfterElement(parse, session.texts, o.line, 3, { "|" .. E.LineText(text) }))
            end
        end, nil, { placeholder = "What happens when it is chosen (optional words)" })
        return
    end
    for _, l in ipairs(lines) do
        local lineNo = l
        local docid, at = E.Source(parse, lineNo)
        local raw = E.Split(session.texts[docid] or "").lines[at] or ""
        local lead = string.match(raw, "^(%s*)") or ""
        local text = trim((string.gsub(string.gsub(raw, "^%s*|", ""), "|%s*$", "")))
        children[#children + 1] = ctx.OutcomeEditor(text, function(newText)
            if trim(newText) == "" then
                ctx.Commit("Removed what a choice does.", E.DeleteLine(parse, lineNo))
            else
                ctx.Commit("Edited what a choice does.", E.SetLine(parse, lineNo, lead .. "|" .. E.LineText(newText)))
            end
        end, nil, { placeholder = "What happens when it is chosen (optional words)" })
    end
end

function S.NarrativeEditor(ctx, beat, index)
    local session = ctx.session
    local parse = session.parse
    local children = { ctx.Label(string.upper(S.BeatLabel(beat)), { "mbHeading" }, { color = KIND_COLOR.narrative }) }
    children[#children + 1] = ctx.Label("A story beat on the stage: its scenes play in order, and each may ask the party a choice.", { "mbSub" })
    children[#children + 1] = ctx.Label("Intro: shown when the beat opens", { "mbFieldLabel" })
    children[#children + 1] = ctx.TextBox(beat.intro, function(text)
        ctx.Commit("Edited the narrative's intro.", E.SetProse(parse, session.texts, beat.introLines, beat.line, text))
    end, { multiline = true, placeholder = "The heroes gather before the road ahead." })
    for _, u in ipairs(beat.unlocks or {}) do
        children[#children + 1] = ctx.Label(string.format("Turns on %s as it opens (Optional features).", u.name), { "mbRule" }, { color = ON_COLOR })
    end
    if beat.sceneTag ~= nil then
        children[#children + 1] = ctx.Label("Backdrop: its [[scene]] picture (set in the journal).", { "mbSub" })
    end

    for si, sec in ipairs(beat.sections or {}) do
        local s = sec
        local options = RealOptions(s)
        local sc = {}
        sc[#sc + 1] = ctx.Row({
            gui.Label{ classes = { "mbHeading" }, color = KIND_COLOR.narrative, width = "auto", height = "auto", valign = "center", rmargin = 8,
                text = string.format("SCENE %d", si) },
            ctx.TextBox(s.name, function(text)
                text = (string.gsub(E.LineText(text), "^#+%s*", ""))
                if text ~= "" then
                    ctx.Commit("Renamed a scene.", E.SetLine(parse, s.line, "## " .. text))
                end
            end, { width = 320, height = 28 }),
        }, { fit = true })
        sc[#sc + 1] = ctx.Label("What happens", { "mbFieldLabel" })
        sc[#sc + 1] = ctx.TextBox(s.text, function(text)
            ctx.Commit("Edited a scene's text.", E.SetProse(parse, session.texts, s.textLines, s.line, text))
        end, { multiline = true, placeholder = "The road forks beneath a lightning-split oak." })
        for _, u in ipairs(s.unlocks or {}) do
            sc[#sc + 1] = ctx.Label(string.format("Turns on %s when this scene arrives.", u.name), { "mbRule" }, { color = ON_COLOR })
        end

        --who chooses, and the question.
        local function WriteMode(mode, prompt)
            local line = E.NarrativeModeLine(mode, prompt)
            local spans = s.promptLines
            if spans ~= nil and #spans > 0 then
                ctx.Commit("Edited a scene's choice.", One(E.PatchExpanded(parse, spans[1][1], spans[#spans][2], { line })))
            else
                local after = s.line
                for _, span in ipairs(s.textLines or {}) do
                    after = math.max(after, span[2])
                end
                ctx.Commit("Edited a scene's choice.", One(E.InsertBlockAfter(parse, session.texts, after, { line })))
            end
        end
        if #options > 0 then
            sc[#sc + 1] = ctx.Label("The choice", { "mbFieldLabel" })
            sc[#sc + 1] = ctx.Row({
                ctx.PickDropdown({
                    { id = "together", text = "The party chooses together" },
                    { id = "individual", text = "Each hero chooses for themselves" },
                }, s.mode, function(id) WriteMode(id, s.prompt) end, { width = 260, lmargin = 0,
                    tooltip = "Together: one vote per player, and a split vote is settled at random. Each hero: every hero picks, and each choice applies to those who took it." }),
                ctx.TextBox(s.prompt, function(text) WriteMode(s.mode, text) end, { width = 420, height = 24, placeholder = "The question (optional): Which way do you go?" }),
            }, { fit = true })
            if not s.modeExplicit and #options >= 2 then
                sc[#sc + 1] = ctx.Label("Not written yet: pick who chooses to make it explicit.", { "mbSub" })
            end
        else
            sc[#sc + 1] = ctx.Label("No choices: the party reads it and presses on.", { "mbSub" })
        end

        for oi, opt in ipairs(options) do
            local o = opt
            local oc = {}
            oc[#oc + 1] = ctx.Row({
                gui.Label{ classes = { "mbSub" }, bold = true, width = "auto", height = "auto", valign = "center", rmargin = 8, text = string.format("CHOICE %d", oi) },
                ctx.TextBox(o.name, function(text)
                    text = (string.gsub(E.LineText(text), "^#+%s*", ""))
                    if text ~= "" then
                        ctx.Commit("Renamed a choice.", E.SetLine(parse, o.line, E.OptionHeadingLine(text)))
                    end
                end, { width = 320, height = 26 }),
                ctx.ConfirmButton("Delete", function()
                    ctx.Commit(string.format("Deleted the choice '%s'.", o.name), E.DeleteElement(parse, session.texts, o.line, 3), nil, { keepTags = true })
                end),
            }, { fit = true })
            oc[#oc + 1] = ctx.TextBox(o.text, function(text)
                ctx.Commit("Edited a choice's text.", E.SetProse(parse, session.texts, o.textLines, o.line, text))
            end, { multiline = true, minHeight = 26, placeholder = "Shown with the choice (optional): The ridge path is longer but safer." })
            NarrativeRules(ctx, o, oc)
            sc[#sc + 1] = gui.Panel{ classes = { "mbSection" }, children = oc }
        end

        sc[#sc + 1] = ctx.Row({
            ctx.SmallButton("+ Choice", function()
                local last = options[#options]
                if last ~= nil then
                    ctx.Commit("Added a choice.", E.InsertAfterElement(parse, session.texts, last.line, 3, E.OptionBlock("New choice", "", {})))
                else
                    ctx.Commit("Added a choice.", E.InsertAfterElement(parse, session.texts, s.line, 2,
                        { E.NarrativeModeLine("together", "What do you do?"), "", E.OptionHeadingLine("New choice") }))
                end
            end),
            ctx.ConfirmButton("Delete scene", function()
                ctx.Commit(string.format("Deleted the scene '%s'.", s.name), E.DeleteElement(parse, session.texts, s.line, 2), nil, { keepTags = true })
            end),
        }, { fit = true, tmargin = 4 })
        children[#children + 1] = gui.Panel{ classes = { "mbSection" }, children = sc }
    end

    ProblemLabels(ctx, beat.line, 1, children)
    children[#children + 1] = ctx.Row({
        ctx.SmallButton("+ Scene", function()
            local last = beat.sections ~= nil and beat.sections[#beat.sections] or nil
            if last ~= nil then
                ctx.Commit("Added a scene.", E.InsertAfterElement(parse, session.texts, last.line, 2, E.NarrativeSectionBlock("New Scene")))
            else
                ctx.Commit("Added a scene.", E.InsertAfterElement(parse, session.texts, beat.line, 1, E.NarrativeSectionBlock("New Scene")))
            end
        end),
        ctx.SmallButton("Open in journal", function() OpenInJournal(ctx, beat.line) end),
        ctx.ConfirmButton("Delete this narrative", function() ctx.Do(function() S.DeleteBeat(ctx, index) end) end),
    }, { fit = true, tmargin = 8 })
    return children
end

function S.MontageEditor(ctx, beat, index)
    local children = { ctx.Label("MONTAGE", { "mbHeading" }, { color = KIND_COLOR.montage }) }
    children[#children + 1] = ctx.Label("Rounds of opportunities and threats: each hero takes a turn at one, with tests, scenes and delves.", { "mbSub" })
    children[#children + 1] = ctx.Row({
        gui.Button{
            classes = { "sizeS" },
            width = "auto",
            height = 34,
            hpad = 16,
            borderBox = true,
            text = "Open in the Montage Builder",
            click = function()
                ctx.OpenMontage(beat)
            end,
        },
    }, { fit = true, vmargin = 8 })
    if trim(beat.intro or "") ~= "" then
        children[#children + 1] = ctx.Label(beat.intro, { "mbSub" })
    end
    for _, r in ipairs(beat.rounds or {}) do
        local names = {}
        for _, e in ipairs(r.entries or {}) do
            names[#names + 1] = e.name
        end
        children[#children + 1] = ctx.Label(string.format("Round %s: %s", tostring(r.number), cond(#names == 0, "(empty)", table.concat(names, ", "))), { "mbSub" })
    end
    ProblemLabels(ctx, beat.line, 1, children)
    children[#children + 1] = ctx.Row({
        ctx.SmallButton("Open in journal", function() OpenInJournal(ctx, beat.line) end),
        ctx.ConfirmButton("Delete this montage", function() ctx.Do(function() S.DeleteBeat(ctx, index) end) end),
    }, { fit = true, tmargin = 8 })
    return children
end

--- the encounter --------------------------------------------------------------------------

local SETUP_KINDS = {
    { id = "placeobjects", text = "Place objects in zones" },
    { id = "bystanders", text = "Bystanders (stay out of initiative)" },
    { id = "victory", text = "Extra way to win" },
}

local function Numbers(lo, hi)
    local options = {}
    for n = lo, hi do
        options[#options + 1] = { id = tostring(n), text = tostring(n) }
    end
    return options
end

--A new setup instruction of `kind`, using names from this map where it has them.
local function NewSetup(kind)
    local lists = EncounterMontageBuilder.Lists()
    if kind == "bystanders" then
        return { kind = "bystanders", label = "Bystanders", names = { "Civilian" } }
    elseif kind == "victory" then
        return { kind = "victory" }
    end
    local zone = "trap"
    for _, z in ipairs(lists.zones) do
        if lower(z) == "trap" then
            zone = "trap"
            break
        end
        zone = lower(z)
    end
    return { kind = "placeobjects", label = "Trap", qty = 2, object = lists.objects[1] or "Snare Trap", zone = zone, deleteOthers = true }
end

local function SetupRow(ctx, ins)
    local session = ctx.session
    local parse = session.parse
    local lists = EncounterMontageBuilder.Lists()
    local function Write(newIns)
        ctx.Commit("Edited a setup line.", E.SetLine(parse, ins.line, E.SetupLine(newIns)))
    end
    local function Copy()
        local c = {}
        for k, v in pairs(ins) do c[k] = v end
        return c
    end
    ---@type Panel[]
    local row = {}
    if ins.kind == "placeobjects" then
        row[#row + 1] = ctx.TextBox(ins.label, function(text)
            local c = Copy()
            c.label = (string.gsub(E.LineText(text), ":", ""))
            Write(c)
        end, { width = 90, height = 24 })
        row[#row + 1] = ctx.Word("Place")
        row[#row + 1] = ctx.PickDropdown(Numbers(1, 12), tostring(ins.qty), function(id)
            local c = Copy()
            c.qty = tonumber(id)
            Write(c)
        end, { width = 56 })
        if #lists.objects > 0 then
            local options, chosen = ctx.NameOptions(lists.objects, ins.object)
            row[#row + 1] = ctx.PickDropdown(options, chosen, function(id)
                local c = Copy()
                c.object = id
                Write(c)
            end, { width = 190, menuWidth = 260, search = true, tooltip = "An object on this map; one is copied onto each drawn tile." })
        else
            row[#row + 1] = ctx.TextBox(ins.object, function(text)
                local c = Copy()
                c.object = E.LineText(text)
                Write(c)
            end, { width = 160, height = 24 })
        end
        row[#row + 1] = ctx.Word("objects in")
        local zoneOptions, zoneChosen = ctx.NameOptions(lists.zones, ins.zone)
        row[#row + 1] = ctx.PickDropdown(zoneOptions, zoneChosen, function(id)
            local c = Copy()
            c.zone = lower(id)
            Write(c)
        end, { width = 130 })
        row[#row + 1] = ctx.Word("zones")
        row[#row + 1] = gui.Check{
            classes = { "sizeXs" },
            width = 230,
            height = 24,
            valign = "center",
            text = "and delete the other ones",
            value = ins.deleteOthers == true,
            hover = gui.Tooltip("Every tile of that zone type that was not drawn is removed, so only the placed ones matter."),
            change = function(element)
                local c = Copy()
                c.deleteOthers = element.value == true
                Write(c)
            end,
        }
    elseif ins.kind == "bystanders" then
        row[#row + 1] = ctx.TextBox(ins.label, function(text)
            local c = Copy()
            c.label = (string.gsub(E.LineText(text), ":", ""))
            Write(c)
        end, { width = 110, height = 24 })
        row[#row + 1] = ctx.TextBox(table.concat(ins.names or {}, ", "), function(text)
            local c = Copy()
            c.names = {}
            for part in string.gmatch(E.LineText(text), "[^,]+") do
                if trim(part) ~= "" then
                    c.names[#c.names + 1] = trim(part)
                end
            end
            if #c.names > 0 then
                Write(c)
            end
        end, { width = 260, height = 24, placeholder = "Civilian, Old Tam" })
        row[#row + 1] = ctx.Word("tokens stay out of initiative")
    elseif ins.kind == "victory" then
        row[#row + 1] = ctx.Word("The heroes also win when every")
        local options, chosen = ctx.NameOptions(lists.keywords, ins.who ~= nil and (ins.whoText or ins.who) or nil, { { id = "", text = "enemy" } })
        row[#row + 1] = ctx.PickDropdown(options, chosen or "", function(id)
            Write({ kind = "victory", who = cond(id == "", nil, lower(id)), whoText = cond(id == "", nil, id) })
        end, { width = 160, menuWidth = 220, search = true })
        row[#row + 1] = ctx.Word("on the map is defeated")
    else
        local docid, at = E.Source(parse, ins.line)
        row[#row + 1] = ctx.TextBox(E.Split(session.texts[docid] or "").lines[at] or "", function(text)
            ctx.Commit("Edited a setup line.", E.SetLine(parse, ins.line, E.LineText(text)))
        end, { width = 520, height = 24 })
    end
    row[#row + 1] = gui.Button{ classes = { "sizeXs" }, width = 22, height = 22, lmargin = 6, valign = "center", text = "x",
        hover = gui.Tooltip("Remove this line"),
        click = function()
            ctx.Commit("Removed a setup line.", E.DeleteLine(parse, ins.line))
        end }
    return ctx.Row(row, { fit = true, vmargin = 2 })
end

--The "Arrive:" form of a reinforcement group.
local function ScheduleRow(ctx, r)
    local session = ctx.session
    local parse = session.parse
    local schedule = r.schedule or { rounds = { [3] = true } }
    local function Write(newSchedule)
        local line = E.ArriveLine(newSchedule)
        if r.scheduleLine ~= nil then
            ctx.Commit("Edited when reinforcements arrive.", E.SetLine(parse, r.scheduleLine, line))
        else
            ctx.Commit("Set when reinforcements arrive.", One(E.InsertBlockAfter(parse, session.texts, r.line, { line })))
        end
    end
    local mode = cond(schedule.rounds ~= nil, "rounds", "every")
    ---@type Panel[]
    local row = {
        ctx.Word("Arrive", { hmargin = 0 }),
        ctx.PickDropdown({ { id = "rounds", text = "on rounds" }, { id = "every", text = "every N rounds" } }, mode, function(id)
            if id == "rounds" then
                Write({ rounds = { [3] = true } })
            else
                Write({ every = 2, from = 2 })
            end
        end, { width = 150 }),
    }
    if mode == "rounds" then
        local list = {}
        for n in pairs(schedule.rounds or {}) do
            list[#list + 1] = n
        end
        table.sort(list)
        local parts = {}
        for i, n in ipairs(list) do
            parts[i] = tostring(n)
        end
        row[#row + 1] = ctx.TextBox(table.concat(parts, ", "), function(text)
            local rounds, any = {}, false
            for n in string.gmatch(text or "", "%d+") do
                rounds[tonumber(n)] = true
                any = true
            end
            if any then
                Write({ rounds = rounds })
            end
        end, { width = 120, height = 24, placeholder = "3, or 2, 4" })
    else
        row[#row + 1] = ctx.Word("every")
        row[#row + 1] = ctx.PickDropdown(Numbers(1, 5), tostring(schedule.every or 1), function(id)
            Write({ every = tonumber(id), from = schedule.from, to = schedule.to })
        end, { width = 56 })
        row[#row + 1] = ctx.Word("round(s) from round")
        row[#row + 1] = ctx.PickDropdown(Numbers(1, 10), tostring(schedule.from or 1), function(id)
            Write({ every = schedule.every, from = tonumber(id), to = schedule.to })
        end, { width = 56 })
        local untilOptions = { { id = "", text = "on" } }
        for _, o in ipairs(Numbers(1, 12)) do
            untilOptions[#untilOptions + 1] = { id = o.id, text = "until " .. o.text }
        end
        row[#row + 1] = ctx.PickDropdown(untilOptions, schedule.to ~= nil and tostring(schedule.to) or "", function(id)
            Write({ every = schedule.every, from = schedule.from, to = tonumber(id) })
        end, { width = 96 })
    end
    if r.schedule == nil then
        row[#row + 1] = ctx.Word("(not set: they never arrive)", { color = PROBLEM_COLOR })
    end
    return ctx.Row(row, { fit = true, vmargin = 2 })
end

local function ReinforcementEditor(ctx, r)
    local session = ctx.session
    local parse = session.parse
    local lists = EncounterMontageBuilder.Lists()
    local rc = {}
    rc[#rc + 1] = ctx.Row({
        gui.Label{ classes = { "mbHeading" }, color = KIND_COLOR.encounter, width = "auto", height = "auto", valign = "center", rmargin = 8, text = "REINFORCEMENTS" },
        ctx.TextBox(r.name, function(text)
            text = E.LineText(text)
            if text ~= "" then
                ctx.Commit("Renamed reinforcements.", E.SetLine(parse, r.line, "## Reinforcements: " .. text))
            end
        end, { width = 280, height = 28 }),
    }, { fit = true })
    rc[#rc + 1] = ScheduleRow(ctx, r)

    --where they come in.
    local zoneOptions, zoneChosen = ctx.NameOptions(lists.zones, r.zone, { { id = "", text = "where their group was placed" } })
    rc[#rc + 1] = ctx.Row({
        ctx.Word("Enter", { hmargin = 0 }),
        ctx.PickDropdown(zoneOptions, zoneChosen or "", function(id)
            if id == "" then
                if r.zoneLine ~= nil then
                    ctx.Commit("Reinforcements arrive where they were placed.", E.DeleteLine(parse, r.zoneLine))
                end
            elseif r.zoneLine ~= nil then
                ctx.Commit("Changed where reinforcements enter.", E.SetLine(parse, r.zoneLine, E.EnterLine(id)))
            else
                ctx.Commit("Set where reinforcements enter.", One(E.InsertBlockAfter(parse, session.texts, r.scheduleLine or r.line, { E.EnterLine(id) })))
            end
        end, { width = 240, tooltip = "A zone type on the map: they appear on its tiles." }),
    }, { fit = true, vmargin = 2 })

    --what they shout as they arrive.
    for _, sh in ipairs(r.shoutLines or {}) do
        local shout = sh
        rc[#rc + 1] = ctx.Row({
            ctx.Word("Shout", { hmargin = 0 }),
            ctx.TextBox(shout.text, function(text)
                if trim(text) == "" then
                    ctx.Commit("Removed a shout.", E.DeleteLine(parse, shout.line))
                else
                    ctx.Commit("Edited a shout.", E.SetLine(parse, shout.line, E.ShoutLine(text)))
                end
            end, { width = 420, height = 24 }),
            gui.Button{ classes = { "sizeXs" }, width = 22, height = 22, lmargin = 6, valign = "center", text = "x",
                click = function() ctx.Commit("Removed a shout.", E.DeleteLine(parse, shout.line)) end },
        }, { fit = true, vmargin = 1 })
    end

    --the groups that come, one per arrival, in turn.
    local groups = #(r.islands or {})
    if groups == 0 then
        rc[#rc + 1] = ctx.Label("No groups of monsters yet: '+ Group' adds one.", { "mbProblem" })
    end
    for gi, island in ipairs(r.islands or {}) do
        rc[#rc + 1] = ctx.Label(string.format("Group %d%s: %s", gi, cond(groups > 1, string.format(" (arrival %d, %d, ...)", gi, gi + groups), ""),
            IslandSummary(session, island.line)), { "mbSub" }, { tmargin = 4 })
        rc[#rc + 1] = ctx.Row({ CombatBuilderButton(ctx, island.line) }, { fit = true })
    end
    ProblemLabels(ctx, r.line, 2, rc)
    rc[#rc + 1] = ctx.Row({
        ctx.SmallButton("+ Shout", function()
            local after = r.line
            if r.shoutLines ~= nil and #r.shoutLines > 0 then
                after = r.shoutLines[#r.shoutLines].line
            elseif r.zoneLine ~= nil or r.scheduleLine ~= nil then
                after = math.max(r.zoneLine or 0, r.scheduleLine or 0)
            end
            ctx.Commit("Added a shout.", One(E.InsertBlockAfter(parse, session.texts, after, { E.ShoutLine("Here they come!") })))
        end),
        ctx.SmallButton("+ Group", function()
            local after = r.line
            for _, island in ipairs(r.islands or {}) do
                after = math.max(after, island.line)
            end
            ctx.Commit("Added a reinforcement group.", One(E.InsertBlockAfter(parse, session.texts, after, { "[[encounter]]" })), nil, { keepTags = true })
        end),
        ctx.ConfirmButton("Delete", function()
            ctx.Commit(string.format("Deleted the reinforcements '%s'.", r.name), E.DeleteElement(parse, session.texts, r.line, 2), nil, { keepTags = true })
        end),
    }, { fit = true, tmargin = 4 })
    return gui.Panel{ classes = { "mbSection" }, children = rc }
end

function S.EncounterEditor(ctx, beat, index)
    local session = ctx.session
    local parse = session.parse
    local children = { ctx.Label("ENCOUNTER", { "mbHeading" }, { color = KIND_COLOR.encounter }) }
    children[#children + 1] = ctx.Label("The fight. Setup runs once, just before the monsters appear.", { "mbSub" })

    --the monsters.
    local mc = { ctx.Label("The monsters", { "mbFieldLabel" }) }
    if beat.encounterTag ~= nil then
        mc[#mc + 1] = ctx.Label(IslandSummary(session, beat.encounterLine), { "mbSub" })
        mc[#mc + 1] = ctx.Row({ CombatBuilderButton(ctx, beat.encounterLine) }, { fit = true, tmargin = 4 })
    else
        mc[#mc + 1] = ctx.Label("No monsters yet.", { "mbSub" })
        --the button writes the [[encounter]] tag the monsters are saved under.
        mc[#mc + 1] = ctx.Row({
            CombatBuilderButton(ctx, nil, function()
                if not EncounterMontageBuilder.Commit(session, "Added the encounter island.",
                    { E.InsertBlockAfter(parse, session.texts, beat.line, { "[[encounter]]" }) }, nil, { keepTags = true }) then
                    return nil
                end
                local updated = session.parse.beats[index]
                return updated ~= nil and updated.encounterLine or nil
            end),
        }, { fit = true, tmargin = 4 })
    end
    children[#children + 1] = gui.Panel{ classes = { "mbSection" }, children = mc }

    --setup lines.
    local sc = { ctx.Label("Setup and victory", { "mbFieldLabel" }) }
    for _, ins in ipairs(beat.setup or {}) do
        sc[#sc + 1] = SetupRow(ctx, ins)
    end
    if #(beat.setup or {}) == 0 then
        sc[#sc + 1] = ctx.Label("None: the fight starts as the map is laid out.", { "mbSub" })
    end
    local addOptions = { { id = "", text = "+ Add setup..." } }
    for _, k in ipairs(SETUP_KINDS) do
        addOptions[#addOptions + 1] = k
    end
    sc[#sc + 1] = gui.Dropdown{
        classes = { "sizeXs" },
        width = 260,
        height = 24,
        tmargin = 2,
        halign = "left",
        options = addOptions,
        idChosen = "",
        change = function(element)
            ---@cast element Dropdown
            local kind = element.idChosen
            if type(kind) ~= "string" or kind == "" then
                return
            end
            local after = beat.line
            for _, ins in ipairs(beat.setup or {}) do
                after = math.max(after, ins.line)
            end
            ctx.Commit("Added a setup line.", One(E.InsertBlockAfter(parse, session.texts, after, { E.SetupLine(NewSetup(kind)) })))
        end,
    }
    sc[#sc + 1] = ctx.Label("Place objects: draws that many tiles of the zone type and copies the object onto each (traps). Bystanders: tokens on the map that never take a turn. Extra way to win: on top of defeating the encounter.", { "mbSub" })
    children[#children + 1] = gui.Panel{ classes = { "mbSection" }, children = sc }

    --reinforcements (each shows its own problems).
    local shown = {}
    for _, r in ipairs(beat.reinforcements or {}) do
        children[#children + 1] = ReinforcementEditor(ctx, r)
        for _, w in ipairs(Problems(session, r.line, 2)) do
            shown[w.message] = true
        end
    end

    ProblemLabels(ctx, beat.line, 1, children, shown)
    children[#children + 1] = ctx.Row({
        ctx.SmallButton("+ Reinforcements", function()
            ctx.Commit("Added reinforcements.", E.InsertAfterElement(parse, session.texts, beat.line, 1, E.ReinforcementBlock("New Arrivals")), nil, { keepTags = true })
        end),
        ctx.ConfirmButton("Delete the encounter", function() ctx.Do(function() S.DeleteBeat(ctx, index) end) end),
    }, { fit = true, tmargin = 8 })
    return children
end

--- the editor for what is picked ---------------------------------------------------------

function S.Editor(ctx)
    local session = ctx.session
    local sel = session.scriptSelected
    if sel ~= nil and sel.kind == "features" then
        return S.FeaturesEditor(ctx)
    elseif sel ~= nil and sel.kind == "story" then
        return S.StoryEditor(ctx, sel.key)
    elseif sel ~= nil and sel.kind == "beat" then
        local beat = (session.parse.beats or {})[sel.index]
        if beat ~= nil then
            if beat.kind == "narrative" then
                return S.NarrativeEditor(ctx, beat, sel.index)
            elseif beat.kind == "montage" then
                return S.MontageEditor(ctx, beat, sel.index)
            elseif beat.kind == "encounter" then
                if beat.implicit then
                    return { ctx.Label("The encounter comes from the map's own encounter, not from a script line.", { "mbSub" }) }
                end
                return S.EncounterEditor(ctx, beat, sel.index)
            end
        end
    end
    return {
        ctx.Label("Pick a part of the script on the left.", { "mbHeading" }),
        ctx.Label("The script plays top to bottom: the Town Gate text in town, then each beat in order (narratives, montages, the encounter), then the Conclusion or Defeat screen. Optional features (like Intelligence) are turned on at the top.", { "mbSub" }),
        ctx.Label("Every change is written straight into the journal document it came from and re-checked with the game's own parser. Undo takes back one change at a time.", { "mbSub" }),
    }
end

