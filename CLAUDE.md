# CLAUDE.md

Instructions for AI coding agents working in this repo.

## What this is

An in-game research addon for WoW: Forever (Lua 5.1, interface 16001). It records which
Lua APIs the client exposes (`ForeverAPIExplorer.lua`, `/api export`) and what curated
getters return (`CharacterCapture.lua`, `/api character`), into `ForeverAPIExplorerDB` and
`ForeverAPIExplorerCharacterDB`. Other projects (the export addon, ForeverAPIAtlas) treat
its captures as the evidence for what the API does. The README documents the capture
format.

## Commands

Tests run the addon under real Lua 5.1 via `lupa`, with game functions mocked. Install
dependencies into the gitignored `.test-deps/`, then:

```
pip install --target .test-deps lupa jsonschema
python tests/test_character_capture.py
python tests/test_extended_capture.py
```

`test_extended_capture.py` also needs real dumps in `data/` (gitignored, local only); it
fails with FileNotFoundError without them. Say so rather than treating it as a code bug.

Try in game: `..\Install-DevelopmentAddOn.ps1 ForeverAPIExplorer`, `/reload`, run the
capture, `/reload` again, then `RetrieveOutput.ps1` copies the SavedVariables into
`data/`. Its paths are hard-coded; check them (its `$DataStoragePath` predates the move
into `AddOns\`).

Release: bump `## Version:` in the TOC; the user tags `vX.Y.Z` on `main`.

## Rules

- Never commit `data/`, SavedVariables or `*.tar.gz` bundles: captures hold character
  names and GUIDs.
- The capture format is consumed by `../ForeverAPIAtlas/scripts/import_dump.py`. Change it
  only by bumping the schema version, and update the importer and its tests with it.
- Record, don't infer: only listed getters run, nil positions and `false` are kept, errors
  are recorded not retried, and limits are flagged. Keep it that way.
- Never store or act on a secret value (`issecretvalue`): record a `restricted` node only.
- Mocks prove the Lua logic, not Forever's contracts. Don't claim an API works from a
  passing test; only a game capture shows that.
- Every behaviour change gets a test in `tests/`.
- CI: `secret-scan`, `codeql` and `dependency-review` must pass. Pin Actions to a full
  commit SHA with the version as a comment.
- Commits and pushes need the user's go-ahead. Work on a branch, open a PR.
