# Repo context for Claude Code

This file is ambient context. Read it before making changes to this repo.

## What this repo is

`claude-config` is Ankit Singla's portable Claude Code setup. One declarative `settings.json` plus cross-platform installer scripts. Cloning the repo and running the installer gives any machine — Mac, Linux, or Windows — a fully-configured Claude Code with the same plugin marketplaces and plugins enabled.

Companion repo: [`ak-singla/claude-statusline`](https://github.com/ak-singla/claude-statusline).

It is intentionally a personal setup, not a generalized framework. It happens to be fork-friendly because it's structured cleanly, but generalization is a non-goal until/unless real demand emerges.

## How it works (the model)

Claude Code reads `~/.claude/settings.json` and merges it with any project-scope `.claude/settings.json` at runtime. Two keys matter here:

- **`extraKnownMarketplaces`** — registers a plugin marketplace (replaces `/plugin marketplace add`).
- **`enabledPlugins`** — turns plugins on by `plugin@marketplace` ID (replaces `/plugin install`).

The installer symlinks `~/.claude/settings.json` → this repo's `settings.json`. Edits to the repo file flow live to the running Claude Code; commits propagate to other machines via `git push` / `git pull`. The repo is the source of truth.

```
   Mac  ◀──┐         ┌──▶  Windows
           │         │
           └──repo───┘
```

## File map

| File | Role |
| --- | --- |
| `settings.json` | The whole config. Single source of truth. |
| `install.sh` | Linux/macOS installer. Bash + jq. Interactive merge by default. |
| `install.ps1` | Windows installer. PowerShell built-ins. Same UX as install.sh. |
| `README.md` | User-facing docs: quick start, merge mode, gotchas, fork instructions. |
| `.gitignore` | Excludes OS junk, editor junk, `*.backup-*`, `settings.local.json`. |
| `LICENSE` | MIT. |
| `CLAUDE.md` | This file. Repo context for Claude Code sessions. |

## Behavior contract for the installers

Both `install.sh` and `install.ps1` MUST stay in lockstep. If you change one, change the other. The user-visible behavior on both must match.

**Default mode** (interactive merge):

1. Sanity-check tooling (`jq` on bash; `claude` CLI presence is a warn, not a fail).
2. Detect existing `~/.claude/settings.json`. If it exists, isn't already our symlink, and parses as JSON, run merge.
3. Merge: diff `enabledPlugins` (where value === `true`) between machine and repo. Prompt per plugin in machine-only set with options `[k] keep / [d] drop / [a] keep-all / [s] skip-all`. Default on empty input is keep.
4. For each kept plugin: write the entry into the **repo's** `settings.json`. If the plugin's marketplace name (the part after `@`) isn't in repo's `extraKnownMarketplaces` but IS in machine's, copy the marketplace registration too.
5. Print a suggested `~/.claude/settings.local.json` snippet that captures everything from the existing file that doesn't belong in the team repo: dropped plugins (plus their marketplace registrations), orphan machine-only marketplaces, and non-plugin top-level keys (`hooks`, `permissions`, `statusLine`, `theme`, etc.). The script never writes `settings.local.json` itself — emitting the snippet keeps the user in control and respects the safety invariant about not touching files outside `settings.json`. If `settings.local.json` already exists, label the snippet "merge into existing"; otherwise label it "create the file and paste this".
6. Back up existing `~/.claude/settings.json` to `*.backup-<timestamp>`.
7. Symlink `~/.claude/settings.json` → repo's `settings.json`. On Windows, fall back to `Copy-Item` if symlink permission denied.
8. Snapshot the repo's `settings.json`, run side-channel installers (currently just `npx --yes get-shit-done-cc --claude --global`), diff what they wrote at the top level, restore the repo file, and emit any additions as a `settings.local.json` suggestion. This guard exists because `~/.claude/settings.json` is now a symlink to the repo file — without snapshot/restore, anything an installer writes (gsd adds a `hooks` block + `statusLine` with absolute Node and home paths) would land in the team repo and break every other machine on `git pull`.

**Flags:**

| Flag (bash) | Flag (PS) | Behavior |
| --- | --- | --- |
| *(none)* | *(none)* | Interactive merge + symlink. |
| `--force` / `--no-merge` | `-Force` | Skip prompts. Back up + symlink. |
| `--dry-run` | `-DryRun` | Print what would happen. Write nothing. |
| `--help` / `-h` | (use `Get-Help`) | Print help and exit. |

**Idempotency:** Re-running on a machine where the symlink already points at the repo file must exit cleanly with `settings.json already symlinked to this repo.`

**Safety invariants** (do not break these):

- Never delete or overwrite `~/.claude/settings.json` without making a timestamped backup first.
- Never write to `~/.claude/settings.json` if `--dry-run` is set.
- Never auto-merge non-plugin keys (`hooks`, `permissions`, `model`, `env`, etc.) — they're often machine-specific. Surface them; let the user move them to `settings.local.json`.
- Never assume Claude Code CLI is installed. Warn but continue.
- Never commit machine-specific data into the repo. The merge logic only ever copies `enabledPlugins` entries and `extraKnownMarketplaces` entries the user explicitly approved.
- Side-channel installers must not be allowed to mutate the team repo's `settings.json`. They write to `~/.claude/settings.json` — which is symlinked to the repo file — so wrap every side-channel call with snapshot-before / diff / restore-after, and surface the diff as a `settings.local.json` suggestion. Any new side-channel installer added to the bootstrap step must follow this pattern.

## Conventions

**Plugin IDs** are always written as `plugin-name@marketplace-name`. The marketplace name on the right side of `@` comes from each marketplace's `marketplace.json`, not necessarily the GitHub repo name. When adding a new plugin, verify the marketplace ID by running `/plugin` after a reload, or by reading the marketplace's README.

**Marketplace sources** in `extraKnownMarketplaces` use the GitHub source form:

```json
"<market-id>": {
  "source": { "source": "github", "repo": "<owner>/<repo>" }
}
```

Other source types (local path, URL) exist but aren't used in this repo.

**Side-channel installers** (npm-based, curl-based, anything not a marketplace plugin) live in the install scripts, not in `settings.json`. Keep them minimal — they break the declarative model and require re-running the installer to update.

**JSON formatting:** 2-space indent, no trailing newlines required, keys ordered as: `$schema` → `extraKnownMarketplaces` → `enabledPlugins`. The bash merge writes via `jq` (compact then re-emitted); PowerShell writes via `ConvertTo-Json -Depth 12`. Don't worry too much about formatting drift from merge writes — `jq -S` or a manual reformat is fine post-merge.

**Bash style:** `set -euo pipefail`. Stay bash 3.2 compatible — stock macOS `/bin/bash` is 3.2 and we don't want to require Homebrew bash. Concretely: use `while IFS= read -r line; do arr+=("$line"); done < <(...)` instead of `mapfile`; use `tr '[:upper:]' '[:lower:]'` instead of `${var,,}`; guard array iterations with `${arr[@]+"${arr[@]}"}` since under `set -u`, expanding an empty array errors on bash 3.2. The shebang stays `#!/usr/bin/env bash` (works for both 3.2 and 4+).

**PowerShell style:** PS 5.1 compatible (no PS 7+ only features). `Set-StrictMode` not currently set; consider adding `Set-StrictMode -Version 3.0` if scope creeps.

## Likely future changes

These are anticipated based on the design conversation that produced this repo. None are committed work — just things that might come up. Don't preemptively implement them.

- **Project-scope template** — a `.claude/settings.json` to drop into team project repos. Decided to defer until a project actually needs it.
- **Removing plugins via merge** — current merge is additive only (machine-only → repo). The reverse direction (plugin in repo but you want to disable on this machine without removing from repo) isn't handled. Could be a `settings.local.json` with `"enabledPlugins": { "x@y": false }` override pattern.
- **More side-channel installers** — list will grow. Consider extracting to a `bootstrap/` directory of small scripts, one per tool, that the main installer iterates.
- **Generalization to a template repo** — explicitly deferred. Don't build a "framework" version. If forks accumulate organically, revisit.
- **CI** — could add a GitHub Action that lints the JSON and runs `bash -n` / `pwsh -NoProfile -File install.ps1 -DryRun` on PRs. Low priority; the surface is small.

## When asked to add a plugin

1. Get the marketplace info: GitHub `owner/repo`, and the marketplace ID (from its `marketplace.json` or README).
2. Add to `extraKnownMarketplaces` if not already present.
3. Add to `enabledPlugins` as `<plugin-id>@<marketplace-id>: true`.
4. Update the plugin table in `README.md`.
5. Don't run the install script as part of the change. The user runs that on each of their machines after `git pull`.

## When asked to add a new installer flag or option

1. Update both `install.sh` and `install.ps1`. They must stay in sync.
2. Update the flag table in this file (CLAUDE.md) and the one in `README.md`.
3. Make sure the flag composes sanely with existing ones (`--dry-run` + `--force` should both work together).

## Things to NOT do

- Don't add Anthropic-internal URLs, MCP server endpoints, or anything that would only work for one company. This is a public personal repo.
- Don't add features that require running the installer to take effect for *existing* users — every change should work on first install AND on `git pull` + Claude Code restart of an already-installed setup.
- Don't introduce required dependencies beyond `jq` (bash) and built-ins (PowerShell). If something needs Python, Node, or Go to run, it doesn't belong in the installer path.
- Don't write to `~/.claude/` outside of `settings.json` and the timestamped backup file. The rest of that directory is Claude Code's, not ours.
- Don't break `--dry-run`. Every code path that would write or mutate state must be guarded by the dry-run check.

## Maintainer notes

- Owner: Ankit Singla (`ak-singla` on GitHub).
- Works across macOS, Linux, and Windows. Test on at least two of three before merging anything that touches installer logic.
- License: MIT. Keep it that way unless explicitly asked.
- The README is user-facing; this CLAUDE.md is for Claude Code sessions. Keep README's tone friendly/practical and CLAUDE.md's tone precise/contractual.
