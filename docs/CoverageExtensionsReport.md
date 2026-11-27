# Coverage Extensions Report

What ForeverAPIExplorer needs next to finish covering the Forever API and to enrich what its probes record. It's based on a review of v0.3.0 (`ForeverAPIExplorer.lua`, `CharacterCapture.lua`) and on the captures published in ForeverAPIAtlas (`dist/catalog.json` from the 0.1.0 discovery scan, and `dist/character.json` from the 0.3.0 character capture, client 1.60.1, build 70938).

The evidence gaps come from checking the myDocs references (`WoWUIReference.md`, `LuaReference.md`, `ForeverSkillDataReference.md`) against those captures. Every claim in those documents is marked with one of these levels:

| Mark | Meaning |
|---|---|
| ✅ | Captured: called, with real returns observed |
| ☑️ | The symbol exists; its behavior wasn't observed |
| ❓ | Not found; inconclusive because the scan was truncated |
| ⚠️ | Can't be checked with the current Explorer |

Each item below says which of those markers it would resolve.

---

## Summary

| ID | Extension | Priority | Schema impact | Resolves |
|---|---|---|---|---|
| A1 | Prioritized multi-pass discovery scan | P0 | discovery v2 | Most ❓ (204 unscanned `C_*` namespaces, Enum members, `bit.*`) |
| A2 | Detect widgets, don't traverse them | P0 | discovery v2 | Frees the budget A1 needs |
| A4 | Widget method catalog via metatables | P0 | new section | ⚠️ widget methods (`SetResizeBounds`, `RegisterUnitEvent`, `SetFromAlpha`, tooltip setters) |
| B | Blizzard API documentation export | P0 | new SavedVariable | Signatures, events, structures; a new "documented" evidence level |
| D1 | Capture context | P0 | character v2 | Explains restricted / empty / nil results |
| D2 | Restricted-node reason | P0 | character v2 | Separates real secrets from detector failures |
| D3 | Presence probes | P0 | character v2 | Every ❓ named in myDocs, immediately |
| D4 | Profession follow-ups | P0 | none (new queries) | `ForeverSkillDataReference.md` §15 items 1, 4, 5 |
| A3 | Targeted subtree export + merge | P1 | discovery v2 | Fills gaps without a full rescan |
| A5 | XML template probe | P1 | new section | ⚠️ templates |
| A6 | Provenance via `issecurevariable` | P1 | discovery v2 | Separates Blizzard API from addon globals |
| C1 | Event validity probe | P1 | new section | ⚠️ every event name |
| C2 | Opt-in passive event log | P1 | new SavedVariable | Event payload types, secret payloads |
| D5 | Spell / item enrichment | P1 | none | `C_Spell` / `C_Item` contracts |
| D6 | Non-player unit probes (redacted) | P1 | character v2 | Secret-value behavior for target and nameplates |
| D7 | Safe UI getters (ping, CVars, addons) | P2 | none | Ping system, nameplate range |
| D8 | Guild trade-skill counts | P2 | none | §15 item 6 |
| E | Manual protection probe | P2 | new section | ⚠️ protection status |
| F | Format, importer, tooling | with P0 | — | Required by the schema bumps |

**Recommended release split:**
- **0.4.0** (character schema 2, discovery schema 2): every P0 item plus F.
- **0.5.0**: P1.
- **P2** whenever convenient.

---

## Cross-cutting rules

These apply to every extension. They restate and extend `CLAUDE.md`.

1. **Record, don't infer.**
   - Only listed read-only getters run.
   - New probe kinds (presence, template, event validity) record what they observe and never retry against a different contract.
2. **Never store or act on a secret.**
   - Every value a new probe returns goes through `Encode`.
   - Follow-up queries consume only `Public(...)` data, as they do today (`CharacterCapture.lua:49-61`).
3. **Redact other players** (user decision).
   - Any probe that can return another player's identity records the value's type, a count, and `redacted = true` instead of the name, GUID or realm.
   - NPC and creature data are kept.
   - The event log stores argument types only.
   - Guild data is counts only.
   - Decide this in the addon, not at import: the dumps travel, and the Atlas is public.
4. **No side effects without an explicit command.**
   - Creating frames (A4, A5), loading an addon (B), and calling a possibly protected function (E) each happen only behind their own slash command.
   - Each one is reported in the capture's metadata.
5. **Schema changes bump the version.** The Atlas importer and its tests change in the same pull request (see F).
6. **Every behavior change gets a lupa test.** Mocks prove the Lua logic, not Forever's contracts.

---

## A. Discovery scanner (`ForeverAPIExplorer.lua`)

### A1. Prioritized multi-pass scan (P0)

**Problem:** the scanner is one breadth-first `next` traversal of `_G`, with `MAX_ENTRIES = 100000` (`ForeverAPIExplorer.lua:7`). The 0.1.0 capture hit the cap (`statistics.truncated = true`), and the budget went to the wrong places:

| Measure (from `catalog.json`) | Value |
|---|---|
| Top-level `_G` entries | 55,924 (56% of the budget) |
| Entries under `Enum` | 1,913 (enum *names* only; almost no members) |
| Entries per gamepad action-button frame | ~244 each, for dozens of frames |
| `C_*` namespaces with **no** children recorded | 204 of 272 |
| Notable empty namespaces | `C_Timer`, `C_Spell`, `C_Item`, `C_Map`, `C_ChatInfo`, `C_UnitAuras`, `C_VignetteInfo`, `C_Secrets`, `C_Texture`, `bit`, `GameTooltip`, `MenuUtil` |

**Design:** replace the single queue with ordered passes. Each pass draws on a shared budget and records its own statistics:

1. **`_G` keys**, the current depth-1 behavior. Kept first, because presence at the top level is the most-asked question.
2. **API tables**:
   - children of every `_G` key matching `^C_`;
   - `Enum` and each `Enum.X`, including member values, since enum constants are needed to call many APIs;
   - the Lua library tables: `bit`, `string`, `math`, `table`, `coroutine`.
3. **Other non-widget tables**, such as mixins and data tables. These are traversed as today, depth-limited.
4. **Widgets**, one exemplar per object type only (see A2).

The `visited` set stays global across passes, so aliases are still traversed once. Each record gains a `pass` field. `statistics` gains `passes = { {name, entries, truncated}, ... }`, so a truncated pass is visible on its own.

**Expected effect:** passes 1–2 are roughly 56k + (272 namespaces × ~40) + the Enum members, which fits well under 100k. All widget waste moves to the end.

**Tests:**
- A mock `_G` with a `C_Foo` namespace that's reached only after a large frame table → its children are captured even when the budget runs out during pass 3.
- `passes[i].truncated` is reported correctly.

### A2. Detect widgets, don't traverse them (P0)

**Problem:** every frame table carries its mixin methods directly on itself (for example `_G.ActionButton10.UpdatePingAttributes`), so each frame repeats the same few hundred paths.

**Design:** in `ProcessEntry` (`ForeverAPIExplorer.lua:135`), for a table value:
- Check `type(rawget(value, 0)) == "userdata"`, **or** a callable `value.GetObjectType` that succeeds under `pcall`.
- If it's a widget, record a `widgets` row with `{ path, objectType, name }` and don't queue it.
- Queue only the **first** widget of each `objectType` (in pass 4) as an exemplar.
- Add `statistics.widgets` and `statistics.widgetTypes`.

**Tests:** a mock frame (a table with a `[0]` userdata stand-in and `GetObjectType`) is recorded under `widgets` and isn't traversed. Only one exemplar is queued per type.

### A3. Targeted subtree export with merge (P1)

**Problem:** every `/api export` replaces `ForeverAPIExplorerDB`, so filling one gap means a full rescan.

**Design:** `/api export <path>` (e.g. `/api export C_Spell`) resolves the path, scans only that subtree with the full budget, and appends the result to `ForeverAPIExplorerDB.subtrees[path]` along with its own statistics and timestamp. The plain `/api export` keeps its current meaning. The Atlas importer unions the subtrees into the catalog (see F).

**Tests:**
- A subtree export leaves the main records untouched.
- A missing path is reported, not scanned.

### A4. Widget method catalog (P0)

**Problem:** widget methods (`SetPoint`, `SetResizeBounds`, `RegisterUnitEvent`, `SetFromAlpha`, `GameTooltip:SetSpellByID`, ...) are C methods reached through the widget's metatable `__index`. `next` on the frame never sees them. This is why `WoWUIReference.md` still has ⚠️ on every widget method.

**Design:** `/api widgets`:
- Out of combat only (`InCombatLockdown()`), create one hidden instance of each type:
  - Frame, Button, CheckButton, EditBox, Slider, StatusBar, ScrollFrame, Cooldown, GameTooltip, MessageFrame, ColorSelect, Model.
  - The regions Texture, FontString and Line, via a parent frame.
  - AnimationGroup, plus one Animation of each type: Alpha, Translation, Scale, Rotation, Path.
- For each instance, list `getmetatable(obj).__index`. If that's a table, record method names; if it's a function, record `indexIsFunction = true` and move on.
- Save the result as `ForeverAPIExplorerDB.widgetMethods[objectType] = { names... }`.
- The existing `GameTooltip` instance can be listed directly, without creating a new one.
- Frames can't be destroyed, so create each type **at most once per session**, reuse it, and record `framesCreated` in the metadata.

**Resolves:** all widget-method ⚠️ markers in `WoWUIReference.md` (§§9, 10, 12, 13, 19).

**Tests:** a mock `CreateFrame` returns objects whose metatable has `__index = { SetPoint = f, ... }` → the names are recorded. In combat → refused and reported.

### A5. XML template probe (P1)

**Problem:** XML templates aren't Lua globals, so the scan can never see them. Today the only evidence is indirect, such as `ButtonFrameTemplate_HidePortrait` or `TooltipBackdropTemplateMixin`.

**Design:** as part of `/api widgets`, for each entry in a curated list, call `pcall(CreateFrame, frameType, nil, hiddenParent, template)`. Record `{ template, frameType, exists, objectType, error }`. Starting list:

`BackdropTemplate`, `BasicFrameTemplate`, `BasicFrameTemplateWithInset`, `ButtonFrameTemplate`, `PortraitFrameTemplate`, `UIPanelDialogTemplate`, `TooltipBackdropTemplate`, `UIPanelButtonTemplate`, `UICheckButtonTemplate`, `InputBoxTemplate`, `OptionsSliderTemplate`, `MinimalSliderWithSteppersTemplate`, `UIPanelScrollFrameTemplate`, `CooldownFrameTemplate`, `WowStyle1DropdownTemplate`, `SecureActionButtonTemplate`, `SecureHandlerStateTemplate`, `SecureHandlerClickTemplate`.

Secure templates are created out of combat only. Each created frame stays hidden and unnamed.

**Resolves:** the template ⚠️ markers in `WoWUIReference.md` §§6, 11, 14, 18.

**Tests:** a mock `CreateFrame` that errors for unknown templates → `exists = false` with the error kept.

### A6. Provenance (P1)

**Problem:** the catalog mixes Blizzard API with addon globals (for example `AuctionatorShoppingListMixin` and `BagnonContainerItem*`), and the Atlas can't tell them apart. The README already flags missing "path provenance".

**Design:** for each top-level `_G` key, record `issecurevariable(_G, key)` (☑️ exists) as `secure = true|false` and `taintedBy = <addon name>` when it's insecure. Optionally list the loaded addons with `C_AddOns.GetNumAddOns` / `GetAddOnInfo` / `GetAddOnSecurity` (all ☑️). Keep the names of insecure (third-party) addons in the record, since they are public addon names, not personal data.

**Tests:** a mock `issecurevariable` returns `false, "SomeAddon"` for one key → it's recorded as such.

---

## B. Blizzard API documentation export (P0)

**Problem:** the biggest remaining unknowns are **signatures and events**, for example:
- the arguments of `C_Ping.SendMacroPing`;
- the payloads of `NAME_PLATE_UNIT_ADDED` and `SKILL_LINES_CHANGED`;
- the members of every `C_*` function's return table.

Neither the discovery scan nor the character capture can produce these.

**Evidence that a source exists:** `_G.APIDocumentation_LoadUI` ✅ is in the catalog. That's the loader for Blizzard's load-on-demand `Blizzard_APIDocumentation` / `Blizzard_APIDocumentationGenerated` addons. These contain machine-readable definitions of every documented system's functions, events and tables. `C_AddOns.DoesAddOnExist`, `IsAddOnLoaded`, `LoadAddOn` and `GetAddOnInfo` ☑️ exist to load them.

**Design:** `/api docs`:

1. For each candidate addon name (`Blizzard_APIDocumentationGenerated`, `Blizzard_APIDocumentation`), record `DoesAddOnExist`, `IsAddOnLoaded` and `GetAddOnInfo`.
2. If one exists but isn't loaded, `C_AddOns.LoadAddOn` it, and record the result and any reason string. This is a deliberate side effect, so it runs only on this command.
3. Walk the documentation tables the addon registers. On Retail that's `APIDocumentation.systems` (each system has `Name`, `Namespace`, `Functions`, `Events`, `Tables`). Don't assume the shape: walk it with the same bounded `Encode` used by the character capture, and record whatever structure is there.
4. Store it in a new SavedVariable, `ForeverAPIExplorerDocsDB`, with `schemaVersion`, `client`, `addonVersion`, the loaded addon's name and version, and per-system entries. Keep every field verbatim, including any secret-related annotations the docs carry (newer Retail docs mark which arguments and returns can be secret). Their presence on Forever is itself evidence.
5. `/api cleardocs` removes it.

**Evidence level:** this is *documentation*, not observed behavior. The Atlas should show a fourth level, "documented", next to captured / exists / not found. A documented signature tells you how to call a function; only a capture proves what it returns on Forever.

**Size:** the Retail docs run to several MB of Lua. Measure the SavedVariables size in the first run, and if needed split by system (`/api docs C_TradeSkillUI`). Record `statistics.systems`, `functions`, `events`, `tables` and `truncated`.

**Resolves:**
- The signature questions throughout myDocs.
- The event lists for C1, which turn `WoWUIReference.md` §10 and `ForeverSkillDataReference.md` §11 from "unverified" into "documented", and then into "confirmed" via C1.

**Tests:**
- A mock `C_AddOns` plus a mock `APIDocumentation.systems` → the definitions are serialized, the load is recorded, and the size limits are flagged.
- A missing addon → reported as unavailable, nothing loaded.

---

## C. Events

The Atlas captures no events today, so every event name in myDocs is ⚠️.

### C1. Event validity probe (P1)

**Design:** `/api eventcheck`:
- For each candidate, on a dedicated scratch frame, run `ok, err = pcall(frame.RegisterEvent, frame, name)`, then `UnregisterEvent`.
- Record `{ event, valid = ok, error }`.
- Cross-check with `GetFramesRegisteredForEvent(name)` (☑️), under `pcall`.

**Candidates:**
- All event names from B, when available.
- A curated fallback list: the events the myDocs references and planned addons rely on.
  - `PLAYER_LOGIN`, `ADDON_LOADED`, `PLAYER_ENTERING_WORLD`, `PLAYER_REGEN_DISABLED/ENABLED`
  - `UNIT_HEALTH`, `UNIT_POWER_UPDATE`, `UNIT_AURA`, `PLAYER_TARGET_CHANGED`
  - `NAME_PLATE_UNIT_ADDED/REMOVED`, `SKILL_LINES_CHANGED`, `CHAT_MSG_SKILL`, `TRADE_SKILL_SHOW/CLOSE/LIST_UPDATE`
  - `SPELLS_CHANGED`, `LEARNED_SPELL_IN_TAB`, `ACTIONBAR_SLOT_CHANGED`, `BAG_UPDATE`, `PLAYER_LEVEL_UP`, `ZONE_CHANGED_NEW_AREA`
  - `ADDON_ACTION_BLOCKED`, `ADDON_ACTION_FORBIDDEN`, `COMBAT_LOG_EVENT_UNFILTERED`

Store the results in the discovery DB as `events = { ... }`.

**Tests:** a mock frame whose `RegisterEvent` errors for unknown names → `valid = false`, the error is kept, and the frame ends up unregistered.

### C2. Opt-in passive event log (P1)

**Design:** `/api events start [seconds]` and `/api events stop`:
- Use a dedicated frame with `RegisterAllEvents` (⚠️ check it with A4 first; fall back to registering every C1-valid event).
- For each event, record `count`, `firstAt`, `lastAt`, and up to N argument *signatures*: the argument count and each argument's type, encoded so that secrets become `restricted` nodes with a reason (D2).
- **Store no argument values.** Chat, party and guild events carry other players' names (rule 3).
- Bound it with a default time limit of 300 s, a cap of 500 distinct events, and 5 signatures per event. Stop automatically when a limit is reached, and flag which one.
- Store the log in a new SavedVariable, `ForeverAPIExplorerEventsDB`, or a section of the discovery DB (decide in F).

**Value:** this confirms which events actually fire, with which payload shapes, and whether payloads are secret in or out of combat. For example: does `UNIT_HEALTH` deliver a secret, and when does `SKILL_LINES_CHANGED` fire?

**Tests:**
- Synthetic `OnEvent` calls → counts and signatures are recorded, values are never stored, the limits stop the log, and a secret sentinel argument → a restricted node.

---

## D. Character capture (`CharacterCapture.lua`)

### D1. Capture context (P0)

**Problem:** a nil, empty or restricted result can't be interpreted without knowing the context. For example, `UnitHealth("player")` came back secret, but the capture doesn't say whether the character was in combat, in an instance, or resting.

**Design:** add `result.context = { start = {...}, finish = {...} }`, built by a `Context()` helper that calls each getter under `pcall` and passes every return through `Encode`:
- `InCombatLockdown()`, `UnitAffectingCombat("player")`
- `IsInInstance()`, `IsResting()`, `GetZoneText()`, `C_Map.GetBestMapForUnit("player")` (if it resolves)
- `C_TradeSkillUI.IsTradeSkillReady()` (whether a profession window is open)
- `canaccesssecrets()` (☑️)
- `GetTime()`

Per query, add a cheap `inCombat = InCombatLockdown()` and `durationMs` from `debugprofilestop()` deltas (☑️).

**Tests:** context nodes are present at the start and finish. `inCombat` toggles when the mock changes mid-capture.

### D2. Restricted-node reason (P0)

**Problem:** `Encode` marks a node `restricted` both when `issecretvalue` returns true **and** when the detector itself errors (`CharacterCapture.lua:13-19`). The two have different meanings. Arguments are encoded too, but a secret argument can't actually occur from the curated list.

**Design:** add `node.restrictedReason = "secret" | "detectorError"`, and keep the detector's error string (truncated) in `budget.detectorErrors`. Add per-query counters `restrictedSecret` / `restrictedDetectorError`, plus totals in `statistics`.

**Tests:** extend the sentinel test in `test_extended_capture.py`. Value 777 → `"secret"`; a detector that errors on tables → `"detectorError"`.

### D3. Presence probes (P0)

**Problem:** many ❓ markers mean only "the scan never reached it". A full A1 rescan fixes most of them, but a cheap direct check settles them right away and still works when the scan is truncated.

**Design:** a new probe kind that resolves a path and records its Lua type **without calling anything**:
- `Resolve` (`CharacterCapture.lua:63-70`) currently returns only functions. Add `ResolveAny(path)` returning `found, type`.
- Indexing goes through `__index`, so presence probes also see widget methods on existing globals (`GameTooltip.SetSpellByID`).
- Records use `kind = "presence"`, `status = "present" | "absent"` and `resolvedType`.
- They're counted separately from call statuses, so the `ok + error + unavailable == queries` invariant isn't broken.

**Initial list:** everything ❓ in myDocs.
- Timers, bit operations, spells, items:
  - `C_Timer.After`, `NewTicker`, `NewTimer`
  - `bit.band`, `bor`, `bxor`, `bnot`, `lshift`, `rshift`
  - `C_Spell.GetSpellInfo`, `GetSpellTexture`, `GetSpellCooldown`
  - `C_Item.GetItemInfo`, `GetItemInfoInstant`, `GetItemIconByID`
- Maps, textures, chat and auras:
  - `C_Map.GetBestMapForUnit`, `C_Texture.GetAtlasInfo`
  - `C_ChatInfo.SendAddonMessage`, `RegisterAddonMessagePrefix`, `SendChatMessage`
  - `C_UnitAuras.GetAuraDataByIndex`, `GetPlayerAuraBySpellID`, `AuraUtil.ForEachAura`
- Vignettes and secrets: `C_VignetteInfo.GetVignettes`, `GetVignetteInfo`, plus every `C_Secrets.*` name taken from B once available
- Menus and tooltips:
  - `MenuUtil.CreateContextMenu`
  - `GameTooltip.SetSpellByID`, `SetItemByID`, `SetUnit`, `SetHyperlink`, `SetAction`
- Older globals: `CombatLogGetCurrentEventInfo`, `GetSkillLineInfo`, `GetMouseFocus`, `GetSpellInfo`, `GetSpellCooldown`, `InterfaceOptions_AddCategory`

**Tests:**
- A present function, a present table, an absent path, and a path through a metatable `__index` → each is recorded correctly.
- The call-status invariant still holds.

### D4. Profession follow-ups (P0)

From `myDocs/ForeverSkillDataReference.md` §15. All of these are read-only getters.

1. Feed `GetProfessionInfo` return 7 (the skill line ID) into `C_TradeSkillUI.GetProfessionInfoBySkillLineID`. This covers First Aid `129`, Cooking `185` and Fishing `356`, which `GetAllProfessionTradeSkillLines` omits. Deduplicate against the IDs already queued (`CharacterCapture.lua:138-149`).
2. For each learned skill line, call `GetTradeSkillDisplayName(id)`, `GetTradeSkillTexture(id)`, `GetProfessionChildSkillLineID(id)` and `GetProfessionSpells(id)`.
3. Context-dependent, no arguments: `GetBaseProfessionInfo()`, `GetChildProfessionInfo()`, `GetChildProfessionInfos()`, `IsTradeSkillReady()`. With D1's context, a later capture with the window open can be compared against one with it closed.
4. Spellbook entries for professions: for each `GetProfessionInfo` result, call `C_SpellBook.GetSpellBookItemInfo` / `GetSpellBookItemName` for slots `spellOffset + 1 … spellOffset + numAbilities`, reusing `Spells()` (`CharacterCapture.lua:171-193`) and its `spellSlots` deduplication.
5. **Optional recipe pass**, only when `IsTradeSkillReady()` is true at the start: `C_TradeSkillUI.GetAllRecipeIDs()` → `GetRecipeInfo(id)` for the first N (bounded by `BoundedCount`), with `recipeLimitReached` flagged.
6. Profession enum: `Enum.Profession` members come from A1 pass 2. No character query is needed.

**Tests:** a mock `GetProfessionInfo` returning a skill line not in `GetAllProfessionTradeSkillLines` → the follow-up is queued once. The offset/count slots are queued and deduplicated. The recipe pass runs only when the window is ready.

### D5. Spell and item enrichment (P1)

- **Spells:** for each `spellID` from `C_SpellBook.GetSpellBookItemInfo` (✅ returns `spellID`, read via `Public`), call `C_Spell.GetSpellInfo`, `C_Spell.GetSpellTexture` and `C_Spell.GetSpellCooldown` (when D3 shows they're present), plus `C_SpellBook.GetSpellBookItemTexture` / `GetSpellBookItemCooldown(slot, bank)` (☑️).
- **Items:** for each equipped item ID, call `C_Item.GetItemInfoInstant(id)` and `C_Item.GetItemInfo(id)`.
  - Note that item info can return nil until the item is cached.
  - Record that as-is, without calling `C_Item.RequestLoadItemDataByID`: requesting remote data is out of scope (README).
  - The equipped-item capture itself returned no values for slot 1 in 0.3.0. Check whether that slot was empty.

**Tests:** spell IDs from mocked book items → `C_Spell` queries queued once per ID. Absent `C_Spell` → nothing queued, and the absence is visible via D3.

### D6. Non-player unit probes, redacted (P1)

**Problem:** every unit query uses `"player"`. The open questions for the planned nameplate addon are about **other** units: are their names and GUIDs secret, in and out of combat, and are their health and cast info secret?

**Design:**
- **Units:** `target`, `focus`, `mouseover`, `pet`, and `nameplate1 … nameplateN`, with N bounded by `#C_NamePlate.GetNamePlates()` (via `Public`) and capped at 40.
- **Getters per unit:**
  - existence and identity: `UnitExists`, `UnitIsPlayer`, `UnitName`, `UnitGUID`
  - state and health: `UnitIsDead`, `UnitHealth`, `UnitHealthMax`, `UnitHealthPercent`
  - classification: `UnitCanAttack("player", unit)`, `UnitReaction("player", unit)`, `UnitClassification`, `UnitCreatureType`
  - casting: `UnitCastingInfo`, `UnitChannelInfo`
- **Gating:** query the rest of a unit's getters only if `UnitExists(unit)` returned true.
- **Redaction (rule 3):**
  - If `UnitIsPlayer(unit)` is true, or isn't extractable (restricted or errored), then `UnitName`, `UnitGUID`, the realm part and any player-identifying strings are encoded as `{ type = "string", redacted = true }`.
  - For GUIDs, keep only the prefix before the first `-` (e.g. `"Player"`, `"Creature"`). That's enough to classify the unit without identifying anyone.
  - NPC (`Creature-`, `Vehicle-`) names and GUIDs are kept.
  - Redaction happens inside `Encode`'s caller **before** anything is stored. Redacted values are never used for follow-ups.
- **Context:** combine with D1 so each unit query shows whether it ran in combat. Document a capture protocol in the README: one capture out of combat with an NPC targeted, one in combat with nameplates visible.

**Tests:**
- A mock `UnitIsPlayer` returns true for `target` → the name and GUID are redacted, and the prefix is kept.
- An NPC target → kept.
- A restricted `UnitIsPlayer` result → redacted (fail closed).
- `UnitExists` false → no further queries for that unit.

### D7. Safe UI getters (P2)

- **Ping:** `C_Ping.IsPingSystemEnabled()`, `GetCooldownInfo()`, `GetDefaultPingOptions()` (all ☑️). Don't call `SendMacroPing` or `TogglePingListener`, which have side effects (see E).
- **CVars:** `C_CVar.GetCVar(name)` for a curated list: `nameplateMaxDistance`, `nameplateShowEnemies`, `nameplateShowFriends`, `SoftTargetEnemy`, `SoftTargetInteract`, `scriptErrors`, `taintLog`. Optionally use `ConsoleGetAllCommands()` (☑️) to list CVar names only (bounded).
- **Addons:** `C_AddOns.GetNumAddOns()` and `GetAddOnInfo(i)`, keeping only rows whose name starts with `Blizzard_`. Third-party addon lists describe the user's setup and add nothing to API coverage.

### D8. Guild trade-skill counts (P2)

`GetNumGuildTradeSkill()` (☑️) gives a count only. Don't call `GetGuildTradeSkillInfo`, which returns guild members' names (rule 3). If its shape is ever needed, capture a single row with every string redacted.

---

## E. Protection status (P2, manual only)

**Problem:** whether a function is protected decides whole addon designs, such as auto-ping versus key-press ping. The Atlas can't show protection, and nothing can capture it safely in bulk, because calling a protected function performs its action.

**Design:** `/api protect <path>`, accepted only for paths on a hard-coded allowlist of harmless, reversible calls (initially `C_Ping.TogglePingListener` with `false`). It:
1. Registers `ADDON_ACTION_BLOCKED` and `ADDON_ACTION_FORBIDDEN` on a scratch frame.
2. Calls the function from `C_Timer.After(0, ...)`, so no hardware event is attached. Calling from the slash command itself would count as a key press.
3. Records `{ path, args, blocked = bool, forbidden = bool, eventArgs (encoded), callStatus }`, then unregisters.

Store the results in a `protection` section of the character DB. Document that each entry is a single manual observation.

**Tests:** a mock timer and synthetic `ADDON_ACTION_BLOCKED` → `blocked = true`. A path not on the allowlist → refused, with nothing called.

---

## F. Format, importer and tooling

The capture format is a contract with `../ForeverAPIAtlas/scripts/import_dump.py` (`CLAUDE.md`). Required changes, in the same release as the P0 items:

**Explorer**
- Character `schemaVersion = 2` for D1–D3 and D6. The new record fields are `kind`, `inCombat`, `durationMs`, `restrictedReason`, `redacted`, `context`, `resolvedType` and `status = "present"|"absent"` for presence probes, plus new statistics counters.
- Discovery `schemaVersion = 2` for A1/A2/A6: the `pass`, `secure` and `taintedBy` fields, `widgets`, `widgetMethods`, `templates`, `events`, `subtrees`, and `statistics.passes`.
- New SavedVariables, `ForeverAPIExplorerDocsDB` (B) and `ForeverAPIExplorerEventsDB` (C2), added to `## SavedVariables` in the TOC, each with its own clear command.
- The README's format sections are updated together with the version bump.
- `RetrieveOutput.ps1`: the hard-coded paths are stale (`CLAUDE.md`). Parameterize the SavedVariables folder and the data path, and default the data path to the repo's `data/`.

**Atlas** (`../ForeverAPIAtlas`)
- `import_dump.py`:
  - `validate_character` asserts `schemaVersion == 1` (line 55). Accept 1 and 2, and validate the new counters (presence counts outside the ok/error/unavailable sum).
  - `parse_variables` rejects any SavedVariables name except the two current ones (line 45). Add `ForeverAPIExplorerDocsDB` and `ForeverAPIExplorerEventsDB`.
  - Discovery v2: import `widgets`, `widgetMethods`, `templates`, `events` and `subtrees`, and union the subtrees into `catalog.json`.
- Evidence levels: add "documented" (B), and show `restrictedReason`, `redacted`, `inCombat` and context in the character view.
- Update `profile.schema.json`, `PROFILE_FORMAT.md` and the tests together (Atlas `CLAUDE.md`). Missing or restricted values must never show up as zero or false.
- Privacy check in the importer as defence in depth: reject any v2 record whose unit argument isn't `"player"` and that carries an unredacted `Player-` GUID.

---

## Tests

Extend the existing lupa harness (`tests/test_character_capture.py`, `tests/test_extended_capture.py`) rather than adding a new framework. New mock building blocks:

- A widget mock: a table with a userdata stand-in at `[0]`, `GetObjectType`, and a metatable `__index` method table.
- `CreateFrame` mocks that accept or reject template names.
- A frame whose `RegisterEvent` errors for unknown events, and an `OnEvent` driver for synthetic events.
- `issecretvalue` variants: a sentinel secret, and a detector that errors on some types.
- `UnitIsPlayer` / `UnitExists` mocks for redaction and gating.
- `C_AddOns` + `APIDocumentation` mocks for B.
- A schema-2 fixture dump for the Atlas importer tests.

Tests that use a real dump still need local files in `data/`. Report a skip; don't count it as a pass (`CLAUDE.md`).

---

## What this doesn't cover

- **Runtime behavior beyond one capture.** Every result is a single observation in one context. D1 makes the context visible, but proving behavior across contexts takes several captures.
- **Server-side data** that needs requests (item cache warm-up, remote recipe data). Deliberately out of scope.
- **Exact signatures** for functions that aren't in the API documentation (most Lua FrameXML functions). Read those from Blizzard's FrameXML source.
