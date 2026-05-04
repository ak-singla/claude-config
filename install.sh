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
      sed -n '2,16p' "$0" | sed 's/^# \?//'
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

  mapfile -t MACHINE_PLUGINS < <(
    jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "${SETTINGS_PATH}"
  )
  mapfile -t REPO_PLUGINS < <(
    jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "${REPO_SETTINGS}"
  )

  MACHINE_ONLY=()
  for p in "${MACHINE_PLUGINS[@]}"; do
    found=0
    for q in "${REPO_PLUGINS[@]}"; do
      [[ "$p" == "$q" ]] && { found=1; break; }
    done
    [[ $found -eq 0 ]] && MACHINE_ONLY+=("$p")
  done

  if [[ ${#MACHINE_ONLY[@]} -eq 0 ]]; then
    ok "No machine-only plugins. Repo already covers everything you have enabled."
  else
    info "Found ${#MACHINE_ONLY[@]} plugin(s) enabled here but missing from repo:"
    for p in "${MACHINE_ONLY[@]}"; do echo "      • $p"; done
    echo

    KEEP_ALL=0
    SKIP_ALL=0
    KEPT=()
    for p in "${MACHINE_ONLY[@]}"; do
      if [[ ${KEEP_ALL} -eq 1 ]]; then KEPT+=("$p"); continue; fi
      if [[ ${SKIP_ALL} -eq 1 ]]; then continue; fi

      while true; do
        printf "  %s\n" "$p"
        printf "    [k] keep (merge into repo)  [d] drop  [a] keep-all  [s] skip-all : "
        read -r choice </dev/tty
        case "${choice,,}" in
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

    OTHER_KEYS=$(jq -r '
      del(.enabledPlugins, .extraKnownMarketplaces, .skippedMarketplaces, .skippedPlugins)
      | keys[]?
    ' "${SETTINGS_PATH}")
    if [[ -n "${OTHER_KEYS}" ]]; then
      echo
      warn "Existing settings.json has other top-level keys we won't merge:"
      echo "${OTHER_KEYS}" | sed 's/^/      • /'
      warn "Move anything machine-specific to ~/.claude/settings.local.json (gitignored)."
      warn "It will load alongside our symlinked settings.json."
    fi
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
echo
bold "Running side-channel installers"
if command -v npx >/dev/null 2>&1; then
  if [[ ${DRY_RUN} -eq 1 ]]; then
    info "(dry-run) would run: npx --yes get-shit-done-cc --claude --global"
  else
    info "Installing get-shit-done-cc (global)…"
    npx --yes get-shit-done-cc --claude --global || warn "get-shit-done-cc install failed (non-fatal)"
    ok "get-shit-done-cc done"
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
