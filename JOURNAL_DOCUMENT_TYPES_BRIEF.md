# Journal Document Types Brief

Status: decided in outline, three open questions before planning
Date: 2026-09-21
Driver: David

## Framing

A journal document should be able to have a shape: a declared kind that says what
fields it carries, what it looks like, what it can do, and who may read it. The
Director picks that kind when creating a document, and a pre-filled starting
example can be copied from a library.

The engine already does this once, by hand, for negotiations. `NegotiationDocument`
is a journal document carrying an NPC's negotiation fields, seeded from a
compendium `Negotiator` archetype. It works and it ships. What it is not is
general: every new kind of shaped page costs a Lua subclass, a bespoke compendium
editor and a migration.

The goal is to make that pattern DATA. A document kind is declared in the
compendium; instances live in the journal; a kind can be added by a module without
Lua.

## Decision ledger

1. **The page IS the entity, not a pointer to one.** A negotiator is a journal
   document with negotiation fields on it, not a library row that a page links to.
   This follows the montage precedent (`Compendium.lua:7666`: "Montage Tests
   retired from the compendium: montages are now journal documents") and it is
   what the live `NegotiationDocument` already does.

2. **Types are declared as compendium data.** Schema (fields), defaults, document
   visibility and actions. Not a Lua subclass per kind.

3. **`docType` becomes data-driven.** The existing `docTypeInfo` table
   (`DocumentSystem.lua:62`) already carries name, icon, glyph, ord and `beat` per
   type - exactly the identity a declared kind needs. It becomes compendium rows;
   the hardcoded entries become seed data. This avoids standing up a second
   classification axis beside `nodeType` / `docType` / `documentTypes`.

4. **Two relationships, two mechanisms.**
   - Document -> **type**: a LIVE binding. Add a field to the type and existing
     pages of that type gain it.
   - Document -> **template**: a one-time COPY. A template is just a pre-filled
     starting instance.

5. **Archetypes become template documents.** Sample Negotiators stop being rows in
   a `negotiators` table and become documents under the journal's existing
   Templates folder. The `Negotiator` game type, its compendium tab
   (`Compendium.lua:7655`) and its bespoke editor (`Compendium.lua:7037-7268`) are
   retired.

6. **Document text lives only in `textStorage`.** Reached through
   `Get/SetTextContent`. A declared type must never carry a `content` field. Typed
   fields are fine - they auto-serialize, as `styleSheetId` and every
   `NegotiationDocument` field already do.

7. **Module distribution needs no new work.** Template documents ship as
   `data/objectTables/documents/*.yaml` with `parentFolder: templates`. Five
   already do.

## Evidence appendix

### Current state: templates (2026-09-21)

- The journal has a DM-only **Templates** root folder (`Journal.lua:2346`).
- `MarkdownDocument:ShowCreateDialog()` (`DocumentSystem/MarkdownDocCreate.lua`) is
  a working template picker: it walks every document whose `parentFolder` chain
  reaches the literal folder id `templates` (`:35`), lists them beside a "Blank
  Document" entry, and previews the selection.
- **New Document no longer calls it.** `Journal.lua:2498` records why: the picker
  detoured the six plain types through a second dialog. Commit `3f494e26`
  (2026-08-04) narrowed the New menu to plain markdown. The picker's only live
  caller is `InfoDocument.lua:70`, the map info-bubble path.
- Five templates ship as module content: `combat-encounter`, `montage`,
  `negotiation`, `npc`, `respite` under `data/objectTables/documents/`.

### Current state: the copy is incomplete

`MarkdownDocCreate.lua:46-47` copies exactly two things:

```lua
self:SetTextContent(template:GetTextContent())
self.annotations = DeepCopy(rawget(template, "annotations") or {})
```

Text and annotations. It does not copy `docType`, `styleSheetId`, or any typed
field. Copying a Sample Negotiator template through this path would lose
`attitude`, `startInterest`, `startPatience`, `impression`, `traits`, `offers` and
`hiddenFromPlayers` - everything that makes it a negotiator. **This copy is the
mechanism the whole feature rests on.**

### Current state: negotiation (two systems, one live)

| | `Draw Steel V/NegotiationRules.lua` | `Draw Steel Negotiation/NEG*.lua` |
|---|---|---|
| Added | 2026-07-12 (`5d4d6655`) | 2026-09-01 (`c30e68bd`) |
| Loaded | yes (`main.lua:478`) | **never, in any commit** |
| Negotiator stored in | `documents` table | mod document blob (`negLibrary`) |
| Page / negotiator | same object | page points at a row via `defid` |

The NEG suite (11 files, 6511 lines) was written and never wired in. It was
**deleted on 2026-09-21** as part of this work. Do not reason about negotiation
behaviour from it; it never executed.

The live shape:

- `Negotiator` (`NegotiationRules.lua:442`, table `negotiators`) is a Sample
  Negotiator archetype - reusable motivations, pitfalls, `impressionScore`.
- `NegotiationDocument` (`:742`, derives `CustomDocument`) is the prep page,
  carrying `npcName`, `npcDesc`, `portrait`, `sceneImage`, `hideName`, `attitude`,
  `startInterest`, `startPatience`, `impression`, `archetype`, `opening`,
  `stakes`, `traits`, `offers`, `summaries`.
- `SeedFromArchetype` COPIES from the archetype. `archetype` is documented as "a
  provenance label, not a live link". So the shipping behaviour today is already a
  stamp - hand-written, for one type.
- `CreateNew` sets `hiddenFromPlayers = true`, because "a negotiation page IS the
  secrets". A declared type must be able to set document visibility, not just
  fields; getting this wrong leaks adventure content to players.

Condemned ships The Archivist **twice**: as a `negotiators` row
(`data/condemned/objectTables/negotiators/the-archivist.yaml`) and as a
`NegotiationDocument` (`.../documents/negotiation-the-archivist.yaml`). The
`negotiators` table is doing double duty - generic archetypes and specific NPCs.

### Field kinds, derived from the real case

`NegotiationDocument` forces the minimum schema vocabulary. These are observed, not
invented:

| Kind | Example |
|---|---|
| scalar (number / string / bool) | `impression`, `opening`, `hideName` |
| enum from a rules catalog | `attitude` (a `NegotiationRules` attitude id) |
| asset reference | `portrait`, `sceneImage` |
| fixed-length list | `offers`, interest 0-5 |
| repeatable record list | `traits`: `{id, kind, name, line}` |
| document-level default | `hiddenFromPlayers = true` |

### Storage heterogeneity

There are ~35 `Compendium.Register{ contentType = ... }` tables, but they are not
one storage shape. Most are `dmhub.GetTable` names (`classes`, `races`,
`journalStyles`). Some are nav labels over bespoke panels. Any "reference another
content type" field needs a source adapter - `list()`, `get(id)`, `watch()` -
with a generic implementation for table-backed types.

`LinkResolution.lua` already provides much of this: `CustomDocument.ResolveLink`,
`SearchLinks`, `PreviewLink`, and `CreateEmbeddablePanel(content, args)` - a
generic "render any content inline".

### Hazard: the legacy `content` fallback

`CustomDocument:GetTextContent()` (`DocumentSystem.lua:258`) falls back to the dead
legacy `self.content` when `textStorage` is missing or has lost its metatable.
`CustomDocument.OnDeserialize` (`:194`) spells out the consequence: the next save
overwrites good DB data with empty content. `content` is undeclared on every live
type, so that fallback raises loudly rather than silently emptying a document -
which is the desired behaviour. Declaring `content` on a document type converts a
loud failure into silent data loss. Do not do it.

## Decision map

Settled: 1-7 in the ledger above.

Open, and blocking a plan:

1. **How does a declared type express an ACTION?** Fields are data;
   "Begin Negotiation" is code. Options, ascending in power:
   - display/open only - fully declarative, cannot express "Begin"
   - **registered verbs** - Lua registers named actions, the compendium row picks
     from that menu. Extensible by modules that ship Lua, declarative for everyone
     else. Current preference.
   - inline Lua on the compendium row - maximum power, but a new arbitrary-code
     surface inside shippable module content.

   A verb looks like it needs three parts, not one: `run`, `enabled`, and a
   `watch` path so the button can re-evaluate when state changes elsewhere. NOTE:
   that interface was derived from the deleted NEG code and must be re-validated
   against the live "Begin Negotiation" path before it is trusted.

2. **Does a generic field editor clear the bar?** Retiring the Negotiators tab
   means replacing ~230 hand-written lines (`Compendium.lua:7037-7268`). If the
   generated editor is worse than what it replaces, authoring regresses and the
   feature is a net loss for the person who uses it most.

3. **Migration.** Existing games hold live `negotiators` rows and
   `NegotiationDocument` pages; Condemned ships both. What converts, what is
   dropped, and does a Sample Negotiator become a template document automatically
   or by hand?

## Out of scope / rejected

- **A separate `journalTemplates` table.** There are ~75 hardcoded references to
  the `documents` table; a parallel table would silently miss link resolution,
  search, the Run, Flow and InfoDocument. Templates stay ordinary documents.
- **A fourth classification axis.** "Template" is a location (the Templates
  folder); "type" is `docType`, made data-driven. No new taxonomy.
- **Re-introducing a modal in front of New Document.** The reason the picker was
  unhooked (`Journal.lua:2498`) is the spec: blank creation stays one click. Types
  should be siblings in the same menu, not a dialog before it.

## Open questions

- Should template documents be read-only when module-shipped?
  `CustomDocument.readonly` exists and is gated in three places
  (`DocumentSystem.lua:184`, `:2025`, `:2077`) but nothing ever sets it.
- Do the hidden functional types (montage, heroic test) come back into the New
  menu once types are data-driven? `Journal.lua:2480` hides them deliberately.
- `docTypeInfo` carries an explicit `ord` field (5/10/20/...) that nothing reads,
  while the tree popup sorts alphabetically (`DocumentSystem.lua:903`). The ord
  was authored for this ordering.
- Does a negotiator page want default prose sections, or is it fields-only? The
  live `NegotiationDocument` derives from `CustomDocument`, not
  `MarkdownDocument`, and carries no body text today.

## Build order

1. **Make the template copy complete** - copy every serialized field, not just
   text and annotations (`MarkdownDocCreate.lua:46-47`). Useful on its own,
   independent of everything else, and it is the spine of the feature.
2. Make `docType` data-driven; seed from `docTypeInfo`.
3. Reconnect template/type choice to New Document as sibling menu entries.
4. Declared fields + generated editor, validated against `NegotiationDocument`.
5. Actions, once question 1 is answered.
6. Migrate Sample Negotiators to template documents; retire the `Negotiator`
   type, its tab and its editor.

## Parking lot

- `Journal.lua:2409` has a live `print("FRAGMENT::", ...)` firing on every journal
  asset refresh.
- `data/documentFolders/charactersheetblank.yaml` is `hidden: true` under
  `templates` - a retired earlier template attempt, worth reviving or purging.
- "Save as Template" from an open document is the feature users will ask for
  within a week of this shipping.
