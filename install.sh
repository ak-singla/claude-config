#!/usr/bin/env bash
# claude-config install script (macOS / Linux)
#
# Default mode (interactive merge):
#   - Detects plugins enabled on this machine but missing from the repo.
#   - Prompts you per-plugin: keep (merge into repo) / drop / skip-all / keep-all.
#   - Writes merges back into the repo's settings.json so they propagate via git.
#   - Then symlinks ~/.claude/settings.json to the repo file.
#
# Flags:
#   --force      Skip all prompts. Just back up + symlink (no merge).
#   --no-merge   Alias for --force.
#   --dry-run    Show what would change; don't write anything.
#
# Requires: jq (brew install jq | apt install jq | dnf install jq)

set -euo pipefail

REPO_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_SETTINGS="${REPO_DIR}/settings.json"
CLAUDE_DIR="${HOME}/.claude"
SETTINGS_PATH="${CLAUDE_DIR}/settings.json"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

FORCE=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --force|--no-merge) FORCE=1 ;;
    --dry-run)          DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed -E 's/^#[[:space:]]?//'
      exit 0
      ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
info()  { printf "  \033[36m·\033[0m %s\n" "$*"; }
ok()    { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn()  { printf "  \033[33m!\033[0m %s\n" "$*"; }
fail()  { printf "  \033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }

bold "claude-config installer"
echo

# 1. Sanity checks ------------------------------------------------------------
command -v jq >/dev/null 2>&1 || \
  fail "jq is required. Install: 'brew install jq' (mac) or 'sudo apt install jq' (linux)."

if ! command -v claude >/dev/null 2>&1; then
  warn "Claude Code CLI not found on PATH. Install from https://claude.com/code"
  warn "Continuing — settings will be staged for when you install it."
fi

# Plugin runtime advisories (non-fatal). Some plugins have their own runtime
# prereqs that the installer can't satisfy from settings.json alone. Warn
# loudly so missing runtimes don't manifest later as cryptic hook errors.
# Per the safety invariant in CLAUDE.md, we never make these required deps.
if jq -e '.enabledPlugins["claude-mem@thedotmack"] == true' "${REPO_SETTINGS}" >/dev/null 2>&1; then
  if ! command -v bun >/dev/null 2>&1 && [[ ! -x "${HOME}/.bun/bin/bun" ]]; then
    warn "claude-mem is enabled but 'bun' is not on PATH."
    warn "Its hooks (Stop, SessionStart, PostToolUse, etc.) will fail until installed."
    warn "Install:  curl -fsSL https://bun.sh/install | bash"
    warn "Then add this to ~/.zprofile (login shells must see bun for hooks):"
    warn '    export BUN_INSTALL="$HOME/.bun"'
    warn '    export PATH="$BUN_INSTALL/bin:$PATH"'
  fi
fi

mkdir -p "${CLAUDE_DIR}"

# 2. Decide whether to do interactive merge ----------------------------------
DO_MERGE=0
if [[ ${FORCE} -eq 0 && -e "${SETTINGS_PATH}" && ! -L "${SETTINGS_PATH}" ]]; then
  if jq -e . "${SETTINGS_PATH}" >/dev/null 2>&1; then
    DO_MERGE=1
  else
    warn "Existing ${SETTINGS_PATH} is not valid JSON. Skipping merge; will back up as-is."
  fi
fi

# 3. Interactive merge --------------------------------------------------------
if [[ ${DO_MERGE} -eq 1 ]]; then
  bold "Comparing existing settings against repo"

  MACHINE_PLUGINS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && MACHINE_PLUGINS+=("$line")
  done < <(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "${SETTINGS_PATH}")

  REPO_PLUGINS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && REPO_PLUGINS+=("$line")
  done < <(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "${REPO_SETTINGS}")

  MACHINE_ONLY=()
  for p in ${MACHINE_PLUGINS[@]+"${MACHINE_PLUGINS[@]}"}; do
    found=0
    for q in ${REPO_PLUGINS[@]+"${REPO_PLUGINS[@]}"}; do
      [[ "$p" == "$q" ]] && { found=1; break; }
    done
    [[ $found -eq 0 ]] && MACHINE_ONLY+=("$p")
  done

  KEPT=()
  if [[ ${#MACHINE_ONLY[@]} -eq 0 ]]; then
    ok "No machine-only plugins. Repo already covers everything you have enabled."
  else
    info "Found ${#MACHINE_ONLY[@]} plugin(s) enabled here but missing from repo:"
    for p in "${MACHINE_ONLY[@]}"; do echo "      • $p"; done
    echo

    KEEP_ALL=0
    SKIP_ALL=0
    for p in "${MACHINE_ONLY[@]}"; do
      if [[ ${KEEP_ALL} -eq 1 ]]; then KEPT+=("$p"); continue; fi
      if [[ ${SKIP_ALL} -eq 1 ]]; then continue; fi

      while true; do
        printf "  %s\n" "$p"
        printf "    [k] keep (merge into repo)  [d] drop  [a] keep-all  [s] skip-all : "
        read -r choice </dev/tty
        choice_lc=$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')
        case "$choice_lc" in
          k|"") KEPT+=("$p"); break ;;
          d)    break ;;
          a)    KEEP_ALL=1; KEPT+=("$p"); break ;;
          s)    SKIP_ALL=1; break ;;
          *)    echo "    Please answer k/d/a/s." ;;
        esac
      done
    done

    if [[ ${#KEPT[@]} -gt 0 ]]; then
      echo
      info "Merging ${#KEPT[@]} plugin(s) into repo settings.json…"

      KEPT_JSON=$(printf '%s\n' "${KEPT[@]}" | jq -R . | jq -s .)

      # For each kept plugin "name@market", also copy its marketplace
      # registration from the machine file if the repo doesn't have it.
      MERGED=$(jq \
        --argjson kept "$KEPT_JSON" \
        --slurpfile machine "${SETTINGS_PATH}" '
          . as $repo
          | reduce $kept[] as $id (
              $repo;
              .enabledPlugins[$id] = true
              | ($id | split("@")[1]) as $market
              | if (.extraKnownMarketplaces[$market] // null) == null
                  and ($machine[0].extraKnownMarketplaces[$market] // null) != null
                then .extraKnownMarketplaces[$market] =
                       $machine[0].extraKnownMarketplaces[$market]
                else . end
            )
        ' "${REPO_SETTINGS}")

      if [[ ${DRY_RUN} -eq 1 ]]; then
        info "(dry-run) repo settings.json would become:"
        echo "$MERGED" | sed 's/^/      /'
      else
        echo "$MERGED" > "${REPO_SETTINGS}"
        ok "Updated ${REPO_SETTINGS}"
        warn "Don't forget: \`git add settings.json && git commit && git push\`"
        warn "→ then \`git pull\` on your other machines to receive these."
      fi
    fi
  fi

  # Build a suggested settings.local.json from anything in the machine's old
  # settings that doesn't belong in the team repo: dropped plugins (+ their
  # marketplace registrations), orphan machine-only marketplaces, and any
  # non-plugin top-level keys (hooks, permissions, statusLine, theme, etc.).
  DROPPED=()
  for p in ${MACHINE_ONLY[@]+"${MACHINE_ONLY[@]}"}; do
    found=0
    for q in ${KEPT[@]+"${KEPT[@]}"}; do
      [[ "$p" == "$q" ]] && { found=1; break; }
    done
    [[ $found -eq 0 ]] && DROPPED+=("$p")
  done

  OTHER_KEYS=$(jq -r '
    del(.enabledPlugins, .extraKnownMarketplaces, .skippedMarketplaces, .skippedPlugins)
    | keys[]?
  ' "${SETTINGS_PATH}")

  EXTRA_MARKETS_COUNT=$(jq -r '
    ((.extraKnownMarketplaces // {}) | keys) as $mk
    | $mk | length
  ' "${SETTINGS_PATH}")
  REPO_MARKETS_JSON=$(jq -r '(.extraKnownMarketplaces // {}) | keys' "${REPO_SETTINGS}")
  MACHINE_ONLY_MARKETS=$(jq -r --argjson repoKeys "$REPO_MARKETS_JSON" '
    ((.extraKnownMarketplaces // {}) | keys)
    | map(select(. as $k | $repoKeys | index($k) | not))
    | .[]?
  ' "${SETTINGS_PATH}")

  if [[ ${#DROPPED[@]} -gt 0 || -n "${OTHER_KEYS}" || -n "${MACHINE_ONLY_MARKETS}" ]]; then
    echo
    if [[ -n "${OTHER_KEYS}" ]]; then
      warn "Non-plugin top-level keys found (these belong in settings.local.json, not the team repo):"
      echo "${OTHER_KEYS}" | sed 's/^/      • /'
    fi
    if [[ ${#DROPPED[@]} -gt 0 ]]; then
      warn "Dropped plugins (preserved below so you can keep them locally):"
      for p in "${DROPPED[@]}"; do echo "      • $p"; done
    fi

    if [[ ${#DROPPED[@]} -gt 0 ]]; then
      DROPPED_JSON=$(printf '%s\n' "${DROPPED[@]}" | jq -R . | jq -s .)
    else
      DROPPED_JSON='[]'
    fi

    SUGGESTED=$(jq -n \
      --slurpfile machine "${SETTINGS_PATH}" \
      --slurpfile repo "${REPO_SETTINGS}" \
      --argjson dropped "$DROPPED_JSON" '
        ($machine[0]) as $m
        | ($repo[0])    as $r
        | ($m | del(.enabledPlugins, .extraKnownMarketplaces, .skippedMarketplaces, .skippedPlugins)) as $other
        | ($dropped | map({(.): true}) | add // {}) as $droppedPlugins
        | (($m.extraKnownMarketplaces // {})
           | with_entries(select(($r.extraKnownMarketplaces // {})[.key] == null))) as $extraMarkets
        | (if ($extraMarkets   | length) > 0 then {extraKnownMarketplaces: $extraMarkets}   else {} end)
        + (if ($droppedPlugins | length) > 0 then {enabledPlugins:        $droppedPlugins} else {} end)
        + $other
      ')

    LOCAL_PATH="${CLAUDE_DIR}/settings.local.json"
    echo
    if [[ -e "${LOCAL_PATH}" ]]; then
      info "Merge this into your existing ${LOCAL_PATH}:"
    else
      info "Suggested ${LOCAL_PATH} (create the file and paste this):"
    fi
    echo "${SUGGESTED}" | sed 's/^/      /'
  fi
  echo
fi

# 4. Back up existing settings.json + symlink --------------------------------
if [[ -e "${SETTINGS_PATH}" || -L "${SETTINGS_PATH}" ]]; then
  if [[ -L "${SETTINGS_PATH}" ]] && [[ "$(readlink "${SETTINGS_PATH}")" == "${REPO_SETTINGS}" ]]; then
    ok "settings.json already symlinked to this repo."
  else
    BACKUP="${SETTINGS_PATH}.backup-${TIMESTAMP}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
      info "(dry-run) would back up ${SETTINGS_PATH} → ${BACKUP}"
    else
      mv "${SETTINGS_PATH}" "${BACKUP}"
      ok "Backed up existing settings.json → ${BACKUP}"
    fi
  fi
fi

if [[ ! -L "${SETTINGS_PATH}" && ! -e "${SETTINGS_PATH}" ]]; then
  if [[ ${DRY_RUN} -eq 1 ]]; then
    info "(dry-run) would symlink ${SETTINGS_PATH} → ${REPO_SETTINGS}"
  else
    ln -s "${REPO_SETTINGS}" "${SETTINGS_PATH}"
    ok "Linked ${SETTINGS_PATH} → ${REPO_SETTINGS}"
  fi
fi

# 5. Side-channel installers (npm-based, not marketplace plugins) ------------
# These can write to ~/.claude/settings.json — which is now a symlink to the
# team repo. Their additions are typically machine-specific (absolute paths,
# Node Cellar version, etc.) and must NOT be committed. Snapshot the repo
# file beforehand, run the installer, diff what it added, restore the repo
# file, and emit the additions as a settings.local.json suggestion.
echo
bold "Running side-channel installers"
if command -v npx >/dev/null 2>&1; then
  if [[ ${DRY_RUN} -eq 1 ]]; then
    info "(dry-run) would run: npx --yes get-shit-done-cc --claude --global"
    info "(dry-run) any settings.json keys it added would be captured and offered as a settings.local.json suggestion; the team repo file would stay clean"
  else
    SNAPSHOT=$(mktemp)
    cp "${REPO_SETTINGS}" "${SNAPSHOT}"

    info "Installing get-shit-done-cc (global)…"
    npx --yes get-shit-done-cc --claude --global || warn "get-shit-done-cc install failed (non-fatal)"

    # Diff: top-level keys in post that differ from pre (deep comparison).
    SIDE_ADDS=$(jq -n \
      --slurpfile pre  "${SNAPSHOT}" \
      --slurpfile post "${REPO_SETTINGS}" '
        ($pre[0]) as $a | ($post[0]) as $b
        | $b | with_entries(select(($a[.key] // null) != .value))
      ')

    # Restore the team repo file regardless of what the installer wrote.
    cp "${SNAPSHOT}" "${REPO_SETTINGS}"
    rm -f "${SNAPSHOT}"

    if [[ -n "${SIDE_ADDS}" && "${SIDE_ADDS}" != "{}" ]]; then
      ok "get-shit-done-cc installed (machine-specific additions captured below)."
      echo
      LOCAL_PATH="${CLAUDE_DIR}/settings.local.json"
      warn "Side-channel installer wrote machine-specific keys to settings.json."
      warn "Restored the team repo file. Add these to ${LOCAL_PATH}:"
      if [[ -e "${LOCAL_PATH}" ]]; then
        warn "(${LOCAL_PATH} already exists — merge the keys below into it)"
      fi
      echo "${SIDE_ADDS}" | sed 's/^/      /'
    else
      ok "get-shit-done-cc done"
    fi
  fi
else
  warn "npx not found — skipping get-shit-done-cc. Install Node.js to enable."
fi

# 6. Done --------------------------------------------------------------------
echo
bold "All set."
cat <<EOF

Next steps:
  1. Restart Claude Code (or run /reload-plugins inside an active session).
  2. Run /plugin to verify the plugins are listed and enabled.
  3. If a merge happened, commit & push so other machines pick it up:
       cd "${REPO_DIR}"
       git diff settings.json
       git add settings.json && git commit -m "merge: <plugin> from <machine>" && git push
EOF
