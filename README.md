# Forever API Explorer

An in-game research tool for WoW: Forever. It records which Lua APIs the client
exposes and what they return, so the
[export addon](https://github.com/thechainercygnus/character-planner-export) is built
on evidence, not guesses.

## Install and capture

Copy the complete `ForeverAPIExplorer` folder (including `CharacterCapture.lua`) into your Forever client's `Interface/AddOns` folder, replacing the previous version. Restart the client or reload the UI.

- `/api character` runs the curated character queries over multiple frames.
- `/api characterstatus` reports the last completed capture or current activity.
- `/api clearcharacter` removes only the character snapshot.
- `/api export`, `/api status`, `/api clear` retain the existing environment discovery behavior.

Wait for completion, then `/reload` or log out normally to persist SavedVariables. Run `RetrieveOutput.ps1` to copy the file. Dumps in `data/` stay local: the folder is gitignored, because captures hold character names and GUIDs. Both independent globals are saved in the same `ForeverAPIExplorer.lua` SavedVariables file: `ForeverAPIExplorerDB` (environment) and `ForeverAPIExplorerCharacterDB` (character). Each capture replaces only its own previous snapshot. The Forever API Atlas importer accepts original environment-only and combined files. With the separate (private) ForeverAPIAtlas checkout beside this repository, run `python ../ForeverAPIAtlas/scripts/import_dump.py data/<dump>.lua ../ForeverAPIAtlas/dist/catalog.json` to refresh both the catalog and `character.json`; it validates query counts and preserves typed returns. An environment-only import clears stale character evidence.

## Character format (schema 1)

The snapshot includes client/build metadata, addon version, start/end times, limits, summary counts and `queries`. Each query records a section, function path, typed arguments, timestamp, and status (`ok`, `unavailable`, or `error`). Successful queries include `returnCount` and an ordered array of typed `returns`. `{type="nil"}` preserves nil positions, including trailing nils; booleans retain false. Table nodes contain key/value entry pairs. Truncation markers identify depth, size, cycle/alias and unsupported number limits. Serialization errors are distinct from function errors; follow-up failures use `expansionError`.

Version 0.3.0 adds `{type=..., restricted=true}` nodes when the client's `issecretvalue` detector reports a secret (or the detector fails). No secret payload is stored or used to schedule further queries. `hasRestrictedValues` identifies affected successful queries, and `statistics.restrictedQueries` counts them separately from the three status totals. An `ok` query can contain restricted or truncated nodes; it does not imply all returns were extractable. Older clients without the detector retain the existing serialization error fallback. Stock Lua tests simulate detection with a sentinel; only the game can verify real secret-value behavior.

Only explicitly listed getter candidates run. Missing APIs are reported, not inferred from the partial discovery export. Modern quest, specialization, reputation, currency and spellbook getters are preferred when present; legacy getters provide fallbacks when the modern count/getter is absent. Runtime errors are preserved rather than silently retried against a different contract. Collection counts are capped at 1,000 entries each, and the complete queue at 10,000 queries; flags record reached limits.

`GetProfessions` indices feed deduplicated `GetProfessionInfo` queries. `C_TradeSkillUI.GetAllProfessionTradeSkillLines` IDs separately feed `GetProfessionInfoBySkillLineID`; those IDs are not interchangeable with profession indices. Profession metadata supplements the legacy general skills list and does not cover all non-profession skills.

Spellbook skill-line offsets/counts schedule item info and name queries for each distinct slot. Modern calls use the client's `Enum.SpellBookSpellBank.Player` value; when missing, `spellBankUnavailable` records that item enumeration was skipped. Legacy calls use the `spell` book. This covers returned player spellbook lines, not pet spellbooks, every obtainable spell, profession recipes, bags, banks or all currencies by ID.

Results reflect the current client context and cache. A successful call is not proof of complete data: reputation/currency headers may be collapsed, empty slots return nil, and some information may not be loaded. The capture does not expand UI headers, open windows, request remote data, or perform automatic event tracking. It spans multiple frames and is not atomic. Captured names, GUIDs, equipment and other character details should be reviewed before sharing.

## Development checks

Install `lupa` into a local `.test-deps` directory and run `python tests/test_extended_capture.py` (includes the original regression harness). The harness runs the addon with Lua 5.1 and mocks game functions; it cannot validate Forever's actual API contracts. The original environment dump remains untouched.

The modern profession, reputation and currency candidates follow Blizzard's generated API documentation, mirrored in [TradeSkillUI](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/TradeSkillUIDocumentation.lua), [ReputationInfo](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/ReputationInfoDocumentation.lua), and [CurrencyInfo](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/CurrencyInfoDocumentation.lua). Runtime presence and captured results establish which contracts work on Forever.

## Profiles and snapshot comparisons

The private atlas now provides normalized profiles, snapshot history, per-field source evidence and before/after comparisons. Existing imports append history automatically. To import all retained dumps, run `python ../ForeverAPIAtlas/scripts/build_profiles.py data ../ForeverAPIAtlas/dist`. See PROFILE_FORMAT.md in the atlas checkout for schema, comparison semantics and validation commands. No new addon version or game capture is required.

## License

[MIT](LICENSE). World of Warcraft names and game data belong to Blizzard
Entertainment. This project isn't affiliated with or endorsed by Blizzard.
