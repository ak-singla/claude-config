# claude-config

My portable Claude Code setup. Clone, run one script, get a fully-configured Claude Code on any machine — Mac, Linux, or Windows.

Companion to my [claude-statusline](https://github.com/ak-singla/claude-statusline) repo.

---

## What this gives you

A single declarative `settings.json` that registers plugin marketplaces and turns on the plugins I use. Add a new machine? `git clone` + `./install.sh`. Add a new plugin? Edit one file, push, pull on the other machine, restart Claude Code.

## What's installed

| Plugin | Marketplace | What it does |
| --- | --- | --- |
| `skill-creator` | `claude-plugins-official` | Scaffold and edit Claude skills |
| `superpowers` | `claude-plugins-official` | Curated bundle of high-leverage commands |
| `frontend-design` | `claude-plugins-official` | Better defaults for UI / artifact work |
| `context-mode` | `mksglu/context-mode` | Context window management helpers |
| `claude-mem` | `thedotmack/claude-mem` | Persistent memory across sessions |
| `get-shit-done-cc` | npm (`npx`) | Productivity slash-commands; not a marketplace plugin, installed separately by the bootstrap script |

---

## Quick start

### macOS / Linux

```bash
git clone https://github.com/ak-singla/claude-config.git ~/claude-config
cd ~/claude-config
./install.sh
```

### Windows (PowerShell)

```powershell
git clone https://github.com/ak-singla/claude-config.git $HOME\claude-config
cd $HOME\claude-config
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

> Run PowerShell as Administrator (or enable Developer Mode) to get a real symlink. Otherwise the script falls back to copying — still works, but you'll need to re-run `install.ps1` after pulling repo updates.

After the script finishes, **restart Claude Code** (or run `/reload-plugins` in an active session). First launch fetches each marketplace from GitHub, which takes a few seconds.

Verify with `/plugin` — all five plugins should show as enabled.

> Requires `jq` on macOS/Linux (`brew install jq` or `sudo apt install jq`). PowerShell uses built-ins; nothing extra needed on Windows.

---

## Merge mode (the smart bit)

If you run the installer on a machine that **already has plugins enabled** that aren't in this repo, it won't silently drop them. Before swapping `~/.claude/settings.json`, the installer:

1. Diffs your existing config against the repo's `settings.json`.
2. Lists every plugin enabled here but missing from the repo.
3. Prompts you per-plugin:

   ```
   Found 2 plugin(s) enabled here but missing from repo:
         • pyright-lsp@claude-plugins-official
         • secret-tool@my-private-marketplace

     pyright-lsp@claude-plugins-official
       [k] keep (merge into repo)  [d] drop  [a] keep-all  [s] skip-all : k
   ```

4. For each "keep," writes the plugin entry into **the repo's `settings.json`** (and copies its marketplace registration too if the repo doesn't already have it).
5. Then does the symlink swap as usual.

The kept plugins are now staged git changes. Commit + push and the next `git pull` carries them to your other machines too. One decision, all machines updated.

### Flags

| Flag | Behavior |
| --- | --- |
| *(none)* | Default. Interactive merge, then symlink. |
| `--force` / `-Force` | Skip all prompts. Back up + symlink. (Same as the original behavior.) |
| `--no-merge` | Alias for `--force` (Linux/macOS only). |
| `--dry-run` / `-DryRun` | Show what would change. Don't write anything. |

### What about non-plugin keys?

If your existing `settings.json` has other top-level keys (`hooks`, `permissions`, `model`, etc.), the installer **does not** auto-merge those — they're often machine-specific. It lists them and recommends moving them to `~/.claude/settings.local.json`, which Claude Code loads alongside our symlinked file. That file is gitignored here by default.

---

## How it works

Claude Code reads two keys from `~/.claude/settings.json`:

- **`extraKnownMarketplaces`** — registers a plugin marketplace (replaces `/plugin marketplace add`)
- **`enabledPlugins`** — turns plugins on by `plugin@marketplace` ID (replaces `/plugin install`)

The installer symlinks `~/.claude/settings.json` → this repo's `settings.json`. Edits in the repo flow live to the running Claude Code. No more "did I install that on the laptop?"

```
~/.claude/settings.json  ──symlink──▶  ~/claude-config/settings.json (committed to git)
```

---

## Adding a new plugin

1. Find it (e.g. `someone/cool-plugin` on GitHub).
2. Edit `settings.json`:

   ```json
   {
     "extraKnownMarketplaces": {
       "cool-plugin": {
         "source": { "source": "github", "repo": "someone/cool-plugin" }
       }
     },
     "enabledPlugins": {
       "cool-plugin@cool-plugin": true
     }
   }
   ```

3. Commit + push.
4. On any machine: `git pull && /reload-plugins`.

> ⚠️ The marketplace name on the right side of `@` is whatever the marketplace declares in its `.claude-plugin/marketplace.json` — usually but not always the repo name. If `/plugin` doesn't list your plugin after a reload, check the marketplace's README for the exact ID.

## Removing a plugin

Set its value to `false` in `enabledPlugins`, or delete the line. Push, pull, reload.

---

## Project-scope sharing (for teammates)

For things specific to a project that the whole team should have, commit a `.claude/settings.json` at the **root of that project repo** with the same `extraKnownMarketplaces` + `enabledPlugins` keys. When a teammate clones and trusts the folder, Claude Code prompts them to install everything.

Keep this `claude-config` repo for **personal** stuff. Keep project repos for **team** stuff. Both stacks combine cleanly at runtime.

---

## Forking this for yourself

This is structured to be a usable template:

1. Fork or use as a template.
2. Edit `settings.json` — keep, swap, or remove plugins to taste.
3. Replace this README's plugin table with yours.
4. Run `./install.sh` (or `install.ps1`) on each of your machines.

There's nothing machine-specific in the repo, so the same checkout works everywhere.

---

## Caveats / known gotchas

- **Windows + official marketplace.** The `claude-plugins-official` marketplace is pre-registered on macOS but [not on Windows](https://github.com/anthropics/claude-code/issues/32268). This repo's `settings.json` registers it explicitly, so it works on both.
- **Auto-install prompt.** Project-scope `extraKnownMarketplaces` is supposed to prompt teammates on folder trust. There's [a known issue](https://github.com/anthropics/claude-code/issues/32606) where the prompt doesn't always fire. If skills don't appear, run `/reload-plugins` or run the installer to put the entries into user-scope.
- **`get-shit-done-cc` isn't declarative.** It's an npm-based installer, so it lives in the bootstrap script, not `settings.json`. Re-run the install script if you reinstall Node.

---

## License

MIT — see [LICENSE](./LICENSE).
