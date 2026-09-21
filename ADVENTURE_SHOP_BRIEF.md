# Adventure Shop Brief

> STATUS: LOCKED 2026-09-21 (Venla). Ready to build, in the phase order below.
> Delivery/updates and commerce posture are David's and outside this brief.
> The two UNVERIFIED items under Open questions must be checked before the
> phase that depends on them.

## Framing

**Problem:** The store can sell cosmetics (dice) but has no way to sell content.
We want to sell adventures with the same delight the 3D dice give -- a rich,
art-led showcase built from the adventure's own content (cover, a map flyover,
character art), instead of a flat store card.

**For whom:** Primarily the director/buyer browsing the shop (a prep surface --
richness beats speed). Secondarily the players who play the purchased adventure
but never touch the store.

**Why a showcase:** The dice preview sells dice because you see the actual
thing. For an adventure the actual thing is its art and its places: the cover
is the pitch, a flyover of a real map says "you will play HERE", and the
characters say "you will meet THEM". Merchandising, not decoration.

**Done (first ship):** An adventure appears in the store with its cover art;
its page shows a map flyover and a strip of character art from the book; you
can buy it; it lands in your account and can be brought into a game you run.

## Decision ledger

| Date | Decision | Rationale |
|---|---|---|
| 2026-09-03 | An adventure IS a module (maps, encounters, monsters, journal documents). The book is its shop presentation, not a new content container. | Reuse the existing module pipeline; the shop ad is presentation only. |
| 2026-09-03 | First-party only: MCDM decides what is sold. No creator marketplace in scope. | Simplifies authoring, entitlements, and curation; marketplace can be a later phase. |
| 2026-09-21 | Map flyover = a slow Lua-driven pan across a finished map image from the adventure, with place names fading in. Not a pre-rendered video, not a live render of the game map. | No engine build, no per-adventure video production, reuses art that already exists, and nothing from the unpurchased module has to load. |
| 2026-09-21 | Surfaces: grid tile = cover only (the square tileImage). Details page = cover hero + flyover + character strip + "what's inside" facts row. Featured banner = cover with the map pan drifting behind the title (the adventure's answer to the spinning die). | Tiles stay cheap and scannable; the richness lives where the buyer has already shown interest. |
| 2026-09-21 | Showcase content is pulled automatically from the adventure module by default, with a manual override (upload/swap images, edit place names and character captions) when the automatic result is not good enough. Authored by Venla in ShopAdmin, the same way dice banners are set up today. | Least setup per adventure; the override covers spoilers and weak auto-picks. |
| 2026-09-21 | "Automatic" happens at AUTHORING time, not browse time: a "Fill from adventure" button in ShopAdmin reads the module (admin owns it), picks cover / largest map / a few portraits, and COPIES them into the shop item's gallery with roles. Venla then adjusts. Customers only ever read the shop item, exactly like dice. Facts row comes from Module.contentSummary. | A customer's client cannot load unpurchased premium content, and browse-time picking could surface spoilers nobody reviewed. |
| 2026-09-21 | Owned state: grid tile shows a small "Owned" tag on the cover. Details page keeps the full showcase; price and Add to cart are replaced by "Start a new game with this adventure", with "Add as gift" still offered. | The shop becomes a way back into the adventure instead of a dead end once bought. |
| 2026-09-21 | Data model: showcase images live in the ShopItem gallery tagged with roles (cover / flyover map / character), extending David's tileImage/heroImage roles; place-name pins and character captions are stored on the ShopItem like diceBanner. Nothing lives on the Module. | One source for the customer shop, same shape as dice, no module republish needed to change the ad. |
| 2026-09-21 | Comfort/perf: the flyover animates only while visible, slow and gentle; with reduced motion it shows a still framed map with pins. Flat images only, so no render-texture budget concerns. | Accessibility without a separate code path for the static case. |
| 2026-09-21 | Phasing: (1) details-page showcase with manually authored roles in ShopAdmin, proven on The Red Road; (2) "Fill from adventure" auto-fill; (3) featured-banner variant and owned state. | Phase 1 is the core value and has no unverified dependencies. |
| 2026-09-21 | No 3D book. The showcase is a mix of the adventure's own art: one cover image, a map flyover, and a few smaller images (characters etc.) from the book. | Venla: a 3D book risks looking tacky. Real content art sells the adventure better than a prop, and needs no new engine rendering. |

## Evidence appendix

### Shop current-state audit (2026-09-03)

**The store can already sell content.** `ShopItem.ItemType` includes `Module`
(ShopInfo.cs:412); `Module.premium` (Module.cs:4283), `Module.owned`
(Module.cs:4137, inventory walk or Patreon entitlement), buy-prompt in
ModShare.lua:4775, auto-install on ownership (GameController.cs:10180,
`autoInstallShopModules`). Content sells at MODULE granularity only; no
per-asset gating exists. So "sell an adventure" is mostly presentation +
commerce-path work, not a new entitlement system.

**Shop UI:** one file, `Codex Titlescreen/CodexShopScreen.lua` (6.4k lines).
Items listed when `onsale` (or `preview` + dev pref) -- `ItemVisibleInShop`
(:33). Category strip exists but is collapsed "until we need categories"
(:4999); category filter compares `keywords` for EXACT equality (:4404).
Details page: `ShowShopItemDetails` (:4155).

**The "featured ad with a bg" pattern already exists for dice.** ShopDiceBanner
(CodexShopScreen.lua:910-1783): a 1232x706 3-layer sandwich -- background image,
live 3D die RenderTexture (`bgimage = "#DicePreview"`, premultiplied blend),
foreground image -- with crossfade rotation among up to 3 featured items
(`onsale` + `featured`). Grid tiles each get their own pooled preview scene/RT
via `#DicePreview:<assetid>:<seq>` (DiceSetPreviewManager.cs), drag-to-spin
wired through `dice.SetPreviewDragging`. A 3D book "ad" slots into exactly this
grammar.

**Purchase flow:** price is US CENTS (ShopInfo.cs:450; the "tokens" doc comment
at :79 is stale/wrong). Live path = Steam microtransactions
(`shop:BuyItemsWithSteam`, StoreInterface.cs:399, cloud steamPurchaseInit/
Finalize; refund support). Ownership = `/Patrons/{uid}/inventory/itemInstances`
instance; bundles expand client-side. Gift codes exist. DORMANT paths: dmhubapp
web checkout + Stripe subs (no Lua callers), and a fully-built server-side
Shopify pipeline (6 cloud-function files) with ZERO client surface.

**Admin tooling:** ShopAdmin.lua (Compendium > Assets > Shop): store state
(Not on store/Preview/Live/Live+Featured), keywords, price, type dropdown
(includes Module + module-id validation), featured-banner editor (bg/fg art,
live preview, drag positioning), images gallery, bundles, gift codes. Premium
module keys can even auto-create Module shop items server-side
(cloud-functions index.js:598 resolveModuleShopItem).

**Constraints/gotchas found:**
- MCDM white-label hardcodes `hasStoreAccess = false` (LuaInterface.cs:8777)
  and a `noCommerce` gate exists (CodexShopScreen.lua:6246) -- currently
  defeated by a force-enabled dev preference (CodexTitleBar.lua:20, looks like
  a shipped debug line). Selling adventures on Codex means DECIDING the
  commerce posture deliberately.
- `Assets/CoreAssets/Lua/shop-screen.txt` is a stale 2.9k-line fork of the shop
  used by the non-Codex titlescreen; changes diverge silently.
- Ownership checks are O(inventory) per call, on hot paths (Module.hide).
- `Bandwidth` item type is a dead enum member.

### Module/adventure content model (2026-09-03)

**A module can already carry a full adventure.** Payload = snapshot (maps,
characters, map folders/manifests/floors, codemods -- COPIED into the game on
install; ModuleManager.cs:1332,1487) + streamed (a CloudAssetInfo subset
mounted as a layered read-only asset store, NOT copied: compendium object
tables incl. documents and encounterScripts, monsters, images, audio, PDFs --
CloudAssetInfo.cs:537 MergeSubset, CloudAssetManager.cs:687). Dice and shop
items cannot ship in a module.

**The marketplace is NOT dormant.** Full browse UI ships today:
`ShowDownloadShareDialog` (ModShare.lua) with Hot/New/Best/Installed/
Purchased/Patreon tabs, search, ranking, votes, install counts
(/ModuleStats aggregation). What is missing is only creator-facing PRICING:
`resolveModuleShopItem` auto-creates the Module shop item at price 0,
onsale false; an admin prices it in ShopAdmin. "Premium" today in practice
means redeem-key (50/batch, 500/module) or Patreon entitlement.

**An adventure-book affordance already half-exists:** `Module.coverdoc`
(Module.cs:4124) -- publish dialog picks a Cover Document, install opens it
immediately (ModShare.lua:4408), and it doubles as the director welcome doc
(DocumentNewUser.lua:19). One doc only, no chapter model. Separately an
ordered "adventure documents" list exists per-game (Journal.lua:149-238,
slash-command only, lives in game state not the module).

**Fields ready to reuse:** `Module.publishingProperties` (free-form table --
obvious home for level range, session count, chapters); `ShopItem.autoInstall`
for modules with customer toggle; `ShopItem.bundle` unexploited for modules.

**Gotchas/risks found:**
- `premium`/`published` are CLIENT-WRITABLE (database.rules.json:284-297) --
  premium is not a trustworthy entitlement signal server-side; fine while
  price lives on the admin-only shop item, but worth tightening.
- Install is version-PINNED for users (autoUpdate false, ModuleManager.cs:1607);
  re-install takes updates -- and a re-install of an updated adventure silently
  overwrites director edits to its NPCs/maps (guid replace, skips owned chars).
- /ModuleFeedback installs/votes are client-forgeable -- never a sales figure.
- Premium modules already install bandwidth-free (Module.cs:4297).

### Engine 3D book capability check (2026-09-03)

> SUPERSEDED 2026-09-21: the 3D book was dropped (see ledger). Kept as a
> record of what the dice preview pipeline can do.

**The dice preview pipeline is directly reusable.** DicePreviewScene.cs:145 --
an offscreen prefab scene (`GameConfig.instance.dicePreviewScene`, :542) with
its own camera rendering to a RenderTexture; a singleton for the featured
banner plus pooled per-tile scenes via DiceSetPreviewManager (30-idle-frame
eviction). Transparent mode reconstructs alpha via a dual-clear blit
(DicePreviewScene.cs:341) so the live 3D composites OVER ad art -- exactly what
a book-on-a-background needs. Enter/Exit animations (PlayExit,
_replayAppearance) support the featured carousel crossfade.

**Embedding:** UI panels consume live RTs through `#special` bgimage ids
resolved in ImageDownloader.cs:636-709 (#DicePreview, #DicePreview:<key>,
#DiceIcon:, #MoveCrossSection, #spine:, #particlepreview:, #ObjectPreview...).
A `#BookPreview:<key>` handle is one more case + a manager. Mouse interaction
is routed from Lua (dice.SetPreviewDragging, DiceLua.cs:390; the try-roll cage
forwards MouseEnter/Click/DragThink/DragEnd).

**3D content loading:** dice are DiceController PREFABS instantiated from
GameConfig lists (DicePreviewScene.cs:855); materials load via Addressables
(DiceMaterialLoader.cs:56). A book mesh would ship the same way: an
addressable/GameConfig prefab. Cover/page textures can come from cloud images
(the preview bg quad already does assetInfo.images -> GetAndPollTexture,
DicePreviewScene.cs:297-303).

**Animation:** there is NO Unity Animator usage anywhere in Assets/Scripts --
every animation in this engine is code-driven. A page flip would be a scripted
rotation of a page quad about the spine axis, optionally with a small vertex
bend in the page shader. Spine (2D) and AVProVideo exist but do not fit a
rotatable 3D book.

## Decision map

1. **Showcase composition** -- DECIDED 2026-09-21: cover + map flyover +
   character images (no 3D book); flyover = Lua pan over a map image;
   surface split recorded in the ledger. (DECIDED)
2. **Shop surface** -- reuse Module itemType; tile / details / featured
   banner split DECIDED (ledger). The featured banner must be taught to
   accept adventures (today IsFeaturedDice requires itemType Dice).
   Category strip revival: NOT DECIDED, deferred until there are enough
   adventures to need it.
3. **Showcase content source** -- DECIDED: auto-fill from the module at
   authoring time, manual override; spoilers handled by Venla's review.
4. **Commerce posture** -- Steam MTX vs Shopify dual-listing; the MCDM
   white-label hasStoreAccess=false + forced dev-pref must be resolved
   deliberately. OWNED BY DAVID (2026-09-21) -- out of this brief's scope.
5. **Delivery & updates** -- ownership -> auto-install -> coverdoc opens;
   update policy (re-install overwrites director edits today).
   OWNED BY DAVID (Venla 2026-09-21) -- out of this brief's scope; the
   overwrite risk is recorded above for him.
6. **Authoring workflow** -- DECIDED: Venla, in ShopAdmin, like dice
   banners; "Fill from adventure" then adjust.
7. **Ad data model** -- DECIDED: ShopItem (gallery roles + stored pins and
   captions), not Module.publishingProperties.
8. **States** -- owned state DECIDED. Offline and refunds follow whatever
   the shop already does for any item; not redesigned here.
9. **Accessibility & perf** -- DECIDED (ledger).
10. **Phasing** -- DECIDED (ledger).

## Out of scope / rejected

- Creator marketplace / third-party sellers (rejected for now: first-party only,
  see ledger 2026-09-03).
- 3D book presentation (rejected 2026-09-21: risks looking tacky).
- Update/re-install policy and commerce posture (David's, not this brief).

## Open questions

- UNVERIFIED (check before build): can Lua enumerate a module's map images
  and monster/character portraits WITHOUT installing it? If not, "Fill from
  adventure" runs inside a game where the adventure is installed.
- UNVERIFIED: is there an existing "create a game from this module" flow the
  owned-state button can call, or does it need building?

