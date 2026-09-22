local mod = dmhub.GetModLoading()

--- @class MonsterGroup: GameType
--- @field name string Display name.
--- @field tableName string Data table name ("MonsterGroup").
--- @field reach number Default reach in world units.
--- @field size string Size code (e.g. "1M", "2L").
--- @field weight number Weight category.
--- @field commonTraits table[] Traits shared by all monsters in this group.
--- @field languages MonsterGroupLanguage[] Languages spoken, each with a qualifier. Lossy by design: see languageNote.
--- @field keywords string[] Keyword tags (e.g. "humanoid", "undead").
--- @field attacks table[] Attack definitions for monsters in this group.
--- @field traits table[] Special trait entries.
--- @field maliceAbilities MaliceAbility[] Malice-cost special abilities for this group.
--- @field inherits table<string,boolean> Set of band ids whose malice abilities this band also gets.
--- @field bandScope string "band" (a real monster band) or "monster" (a creature-type keyword row). Bands-only surfaces filter on this.
--- @field loreSections MonsterGroupProse[] Ordered sub-headed lore passages. A band that opens with untitled prose carries it as a section with a blank heading.
--- @field associatedCreatures MonsterGroupProse[] The book's sidebar creatures, as prose.
--- @field tactics string How the band fights. Only a few bands have this.
--- @field sampleEncounters MonsterGroupEncounter[] Named, costed encounter rosters. Only a few bands have these.
--- @field languageNote string The book's languages sentence as printed. Canonical for display.
MonsterGroup = RegisterGameType("MonsterGroup")

--- A (heading, text) prose block -- used for both lore sections and the
--- book's associated-creature sidebars.
--- @class MonsterGroupProse
--- @field heading string
--- @field text string

--- One language the band speaks. The qualifier carries the book's hedging
--- ("Most goblins speak...", "can understand..."). The list cannot express
--- every case the book uses, so languageNote is what gets displayed.
--- @class MonsterGroupLanguage
--- @field id string Language table id.
--- @field qualifier string One of: all, most, some, few, understands.

--- A named encounter from the book, e.g. "Scout Patrol, 23 EV: Four lookouts,
--- eight scouts, one chirurgeon". Composition is prose for now; parsing it into
--- real monster references is backlogged.
--- @class MonsterGroupEncounter
--- @field name string
--- @field ev number
--- @field composition string

--- Language qualifiers, in descending order of how much of the band they cover.
MonsterGroup.languageQualifiers = {
    { id = "all", text = "all" },
    { id = "most", text = "most" },
    { id = "some", text = "some" },
    { id = "few", text = "few" },
    { id = "understands", text = "understands" },
}

function MonsterGroup.CreateNew(args)
    local params = {
        attacks = {},
        traits = {},
        maliceAbilities = {},
    }

    for k,v in pairs(args) do
        params[k] = v
    end

    return MonsterGroup.new(params)
end

MonsterGroup.tableName = "MonsterGroup"

--The group whose malice abilities every monster falls back to when its own band
--does not inherit them (see monster:FillMonsterActivatedAbilities). A setting
--rather than a literal guid so a game can point at a different group, and so
--that merging or deleting that row does not silently break default malice for
--every monster with nothing naming the cause. No editor: this is infrastructure,
--not something to change from the settings panel.
MonsterGroup.defaultMaliceGroupSetting = setting{
    id = "monstergroup:defaultmalicegroup",
    description = "Default Malice Group",
    help = "The monster group whose malice abilities apply to every monster that does not inherit them from its own band.",
    storage = "game",
    default = "69247753-5e1a-43b2-b48e-373c637939a0",
}

--- The id of the group holding the fallback malice abilities.
--- @return string
function MonsterGroup.DefaultMaliceGroupId()
    return MonsterGroup.defaultMaliceGroupSetting:Get()
end

--- True if this row is the default malice group rather than a real band.
function MonsterGroup:IsDefaultMaliceGroup()
    return self.id == MonsterGroup.DefaultMaliceGroupId()
end

MonsterGroup.name = "Monster Group"
MonsterGroup.reach = 5
MonsterGroup.size = "1M"
MonsterGroup.weight = 1

MonsterGroup.commonTraits = {}
MonsterGroup.languages = {}
MonsterGroup.keywords = {}
MonsterGroup.attacks = {}
MonsterGroup.traits = {}
MonsterGroup.maliceAbilities = {}

--A real band by default. The creature-type keyword rows that share this table
--(Fey, Construct, Humanoid, ...) are marked "monster" so band surfaces can
--filter them out. See MONSTER_BANDS_PRD.md section 6.4.
MonsterGroup.bandScope = "band"

MonsterGroup.loreSections = {}
MonsterGroup.associatedCreatures = {}
MonsterGroup.tactics = ""
MonsterGroup.sampleEncounters = {}
MonsterGroup.languageNote = ""

--True if this row is a real band rather than a creature-type keyword row.
--Absence means band: only the keyword rows are flagged, so a row written by
--anything that does not know about bandScope reads as a band, which is the
--right default for homebrew. Band surfaces filter on this and nothing else.
function MonsterGroup:IsBand()
    return self:try_get("bandScope", "band") ~= "monster"
end

function MonsterGroup.Get(id)
    local t = GetTableCached(MonsterGroup.tableName)
    return t[id]
end

function MonsterGroup:Render(args, options)
	args = args or {}

    local panelParams = {
        styles = Styles.Default,
        width = 500,
        height = "auto",
        flow = "vertical",

        gui.Label{
            classes = {"title"},
            text = self.name,
            width = "auto",
            height = "auto",
        }
    }

	for k,v in pairs(args or {}) do
		panelParams[k] = v
	end

    return gui.Panel(panelParams)

end

--- @class MaliceAbility:ActivatedAbility
MaliceAbility = RegisterGameType("MaliceAbility", "ActivatedAbility")

MaliceAbility.categorization = "Malice"
MaliceAbility.minLevel = 1

function MaliceAbility.Create(options)
	local args = ActivatedAbility.StandardArgs()

	if options ~= nil then
		for k,v in pairs(options) do
			args[k] = v
		end
	end

	return MaliceAbility.new(args)
end

--[[
function MaliceAbility:GenerateEditor()
    local resultPanel

    resultPanel = gui.Panel{
        classes = {"abilityEditor"},
        styles = {
            Styles.Form,

			{
				classes = {"formPanel"},
				width = 340,
			},
			{
				classes = {"formLabel"},
				halign = "left",
			},
			{
				classes = {"abilityEditor"},
				width = '100%',
				height = 'auto',
				flow = "horizontal",
				valign = "top",
			},
        },

        gui.Panel{
            width = "50%",
            halign = "left",
            height = "auto",
            flow = "vertical",
            valign = "top",

			gui.Panel{
				classes = {"abilityInfo", "formPanel"},
				gui.Label{
					classes = "formLabel",
					text = "Name:",
				},
				gui.Input{
					classes = "formInput",
					text = self.name,
					change = function(element)
						self.name = element.text
					end,
				},
			},
        }
    }

    return resultPanel
end
    --]]
