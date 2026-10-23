# What Nook can learn from Code

[Code]() is an open-source GUI for coding agents (Codex, Claude Code, Cursor,
OpenCode and others). It solves several of the problems Nook's workspace has, so its code and its internal notes are a
good source of field-tested lessons. This page records what we studied (October 2026) and what we brought to Nook.

> **License.** Code is **MIT**, like Nook. Even so, Nook re-implements ideas in its own style (Swift, Foundation-only
> core, Nook's naming) instead of porting TypeScript.

## Model manifest (implemented)

**The problem.** Nook hard-coded each agent's quick-pick models (`["", "sonnet", "opus", "haiku"]` in
`RunProvider.suggestedModels`). A new Claude model needed a Nook release, and a model the installed CLI was too old for
failed only after you sent the task.

**What Code does** (`apps/server/src/provider/model-manifest.json`, `packages/provider-core/src/server/ModelCatalog.ts`,
`docs/internals/model-manifest.md`):

- A **bundled manifest** allows offline startup; a copy fetched from the repository's `main` lets model data change
  between releases.
- A fetched copy must **pass validation** before it replaces the cache; a failed fetch or invalid data keeps the last
  usable manifest.
- A **newer bundle wins by `updatedAt`**, so a release can correct model data before the next successful fetch. Fetch
  time cannot tell which copy holds the newer edit; `updatedAt` can, so it is bumped on every change.
- Entries set `adapter.<agent>.minVersion`. A model above the installed CLI is reported as **update required**, and the
  picker says which update unlocks it. Codex still lists its own models (`model/list`), which cannot name models
  released after the installed build, so the manifest adds exactly those.
- `status: current | legacy` classifies models, `aliases` map short names, `badge: "new"` marks new ones.
- Tests use **synthetic model names**, so adding a model is a JSON edit that never needs a test change.

**In Nook:**

| Code | Nook |
|---|---|
| `model-manifest.json` | `apps/macos/Services/Workspace/model-manifest.json`, bundled as an app resource and fetched from `main` (`ModelManifest.remoteURL`) |
| Schema + adapter validation | `ModelManifest.parse` / `validate`: schema version 1, ids usable as a `--model` argument (no spaces, never starting with `-`), no id or alias used twice, the default listed, `minVersion` parseable and only under the owning agent's key, 256 KB at most |
| Cache keeps the last valid copy | `ModelManifest.accepting(_:over:)` returns nil for an invalid or older copy; `ModelManifestStore` stores only accepted bytes (`~/Library/Application Support/Nook/workspace/model-manifest.json`) |
| Newer bundle wins | `ModelManifest.preferred(bundled:cached:)` |
| `minVersion` against the CLI | `CLIVersion` parses `claude --version` ("2.1.280 (Claude Code)") and `codex --version` ("codex-cli 0.153.0"), numeric parts and pre-releases; `ModelManifest.requiredVersion` says "update" only when both versions are known |
| Codex discovery + manifest overlay | `ModelChoice.list`: the agent's own list first, in its order, classified by the manifest; then the manifest models it did not list (all of them for Claude, only the update-required ones when the agent lists its own) |
| `sortModelsForProviderInstance` (`apps/web/src/modelOrdering.ts`) | `ModelOrdering.sorted`: the agent default on top, then favorites, then the rest, each in the given order |
| Custom model ids | `ModelPreferences.customID` / `remembering`: type an id in the model search and pick "Use “…”"; the last eight per agent are kept |

**Wiring.** `WorkspaceManager+ModelManifest` loads the preferred copy at launch, reads the agents' versions (once, again
when the program moves or after half an hour) and builds the menus (`menuModelIDs`, `modelChoice`, `sameModel`) for the
composer's model picker (`AgentModelPicker`), the session settings (`NextTurnSettings` in `WorkspaceComponents.swift`),
Settings › Workspace › Models per agent, and the agent bridge's capability list. In the menus:

- A model that needs a newer agent shows "Needs Claude Code 2.1.300 or newer", cannot be picked, and its tooltip names
  the installed version.
- New models carry a "New" label; legacy ones stay hidden until you search, unless one is in use or a favorite.
- A star on each row toggles a favorite (`WorkspaceSettings.favoriteModels`); favorites are listed first.
- A saved alias ("opus") reads as its model and shows it chosen, and never waits on an update: the agent resolves an
  alias itself.

**Network rules.** The fetch goes through `NetworkGuard.fetch` (public hosts only, every redirect checked), at most every
six hours (`ModelManifestRefresh`), and never while **Settings › Workspace › Check for new models online** is off: then
only the bundled list is used and nothing goes online for it.

**Adding a model** is a JSON edit: add the entry, set `adapter.<agent>.minVersion` when it needs a newer CLI, and bump
`updatedAt`. `ModelManifestTests.testTheBundledManifestValidates` checks the file.

## Worth studying next

- **Provider compatibility ranges** (`compatibility` in the same manifest): per agent, which CLI versions are supported,
  degraded or broken, with a recommended range. Nook could warn before a session starts on a CLI known to break.
- **Default-model overlay** (`applyCatalogDefault`): the manifest can move the agent's default to a newer member of the
  same family, carrying its aliases along.
