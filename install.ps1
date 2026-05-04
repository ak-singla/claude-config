# claude-config install script (Windows / PowerShell)
#
# Default mode (interactive merge):
#   - Detects plugins enabled on this machine but missing from the repo.
#   - Prompts you per-plugin: keep (merge into repo) / drop / skip-all / keep-all.
#   - Writes merges back into the repo's settings.json so they propagate via git.
#   - Then symlinks (or copies) settings.json into ~/.claude/.
#
# Flags:
#   -Force      Skip prompts. Just back up + symlink/copy (no merge).
#   -DryRun     Show what would change; don't write anything.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Force
#
# Run as Administrator (or with Developer Mode enabled) to use a real symlink.
# Otherwise the script falls back to a plain copy.

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$RepoDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoSettings  = Join-Path $RepoDir "settings.json"
$ClaudeDir     = Join-Path $HOME ".claude"
$SettingsPath  = Join-Path $ClaudeDir "settings.json"
$Timestamp     = Get-Date -Format "yyyyMMdd-HHmmss"

function Write-Bold($msg)  { Write-Host $msg -ForegroundColor White }
function Write-Info($msg)  { Write-Host "  · $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Write-Fail($msg)  { Write-Host "  ✗ $msg" -ForegroundColor Red; exit 1 }

# ConvertFrom-Json into a hashtable, recursively. Works on PS 5.1+.
function ConvertTo-Hashtable($obj) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) {
        $ht = @{}
        foreach ($k in $obj.Keys) { $ht[$k] = ConvertTo-Hashtable $obj[$k] }
        return $ht
    }
    if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {
        return @($obj | ForEach-Object { ConvertTo-Hashtable $_ })
    }
    if ($obj.PSObject.Properties.Count -gt 0 -and $obj -isnot [string] -and $obj -isnot [valuetype]) {
        $ht = @{}
        foreach ($p in $obj.PSObject.Properties) { $ht[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $ht
    }
    return $obj
}

function Read-JsonFile($path) {
    $raw = Get-Content -Raw -Path $path -ErrorAction Stop
    return ConvertTo-Hashtable (ConvertFrom-Json $raw)
}

Write-Bold "claude-config installer"
Write-Host ""

# 1. Sanity checks ------------------------------------------------------------
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Warn2 "Claude Code CLI not found on PATH. Install from https://claude.com/code"
    Write-Warn2 "Continuing — settings will be staged for when you install it."
}

if (-not (Test-Path $ClaudeDir)) {
    New-Item -ItemType Directory -Path $ClaudeDir | Out-Null
}

# 2. Decide whether to do interactive merge ----------------------------------
$DoMerge = $false
if (-not $Force) {
    $existing = Get-Item $SettingsPath -Force -ErrorAction SilentlyContinue
    if ($existing -and $existing.LinkType -ne "SymbolicLink") {
        try {
            $null = Read-JsonFile $SettingsPath
            $DoMerge = $true
        } catch {
            Write-Warn2 "Existing $SettingsPath is not valid JSON. Skipping merge; will back up as-is."
        }
    }
}

# 3. Interactive merge --------------------------------------------------------
if ($DoMerge) {
    Write-Bold "Comparing existing settings against repo"

    $machine = Read-JsonFile $SettingsPath
    $repo    = Read-JsonFile $RepoSettings

    $machinePlugins = @()
    if ($machine.enabledPlugins) {
        $machinePlugins = $machine.enabledPlugins.Keys |
            Where-Object { $machine.enabledPlugins[$_] -eq $true }
    }
    $repoPlugins = @()
    if ($repo.enabledPlugins) {
        $repoPlugins = $repo.enabledPlugins.Keys |
            Where-Object { $repo.enabledPlugins[$_] -eq $true }
    }

    $machineOnly = @($machinePlugins | Where-Object { $_ -notin $repoPlugins })

    $kept = @()
    if ($machineOnly.Count -eq 0) {
        Write-Ok "No machine-only plugins. Repo already covers everything you have enabled."
    } else {
        Write-Info "Found $($machineOnly.Count) plugin(s) enabled here but missing from repo:"
        foreach ($p in $machineOnly) { Write-Host "      • $p" }
        Write-Host ""

        $keepAll = $false
        $skipAll = $false

        foreach ($p in $machineOnly) {
            if ($keepAll) { $kept += $p; continue }
            if ($skipAll) { continue }

            while ($true) {
                Write-Host "  $p"
                $choice = (Read-Host "    [k] keep (merge into repo)  [d] drop  [a] keep-all  [s] skip-all").ToLower()
                if ($choice -eq '' -or $choice -eq 'k') { $kept += $p; break }
                elseif ($choice -eq 'd') { break }
                elseif ($choice -eq 'a') { $keepAll = $true; $kept += $p; break }
                elseif ($choice -eq 's') { $skipAll = $true; break }
                else { Write-Host "    Please answer k/d/a/s." }
            }
        }

        if ($kept.Count -gt 0) {
            Write-Host ""
            Write-Info "Merging $($kept.Count) plugin(s) into repo settings.json..."

            if (-not $repo.enabledPlugins)         { $repo.enabledPlugins = @{} }
            if (-not $repo.extraKnownMarketplaces) { $repo.extraKnownMarketplaces = @{} }

            foreach ($id in $kept) {
                $repo.enabledPlugins[$id] = $true

                $marketName = ($id -split "@", 2)[1]
                if ($marketName -and `
                    -not $repo.extraKnownMarketplaces.ContainsKey($marketName) -and `
                    $machine.extraKnownMarketplaces -and `
                    $machine.extraKnownMarketplaces.ContainsKey($marketName)) {
                    $repo.extraKnownMarketplaces[$marketName] = `
                        $machine.extraKnownMarketplaces[$marketName]
                }
            }

            $merged = $repo | ConvertTo-Json -Depth 12

            if ($DryRun) {
                Write-Info "(dry-run) repo settings.json would become:"
                $merged.Split("`n") | ForEach-Object { Write-Host "      $_" }
            } else {
                Set-Content -Path $RepoSettings -Value $merged -Encoding UTF8
                Write-Ok "Updated $RepoSettings"
                Write-Warn2 "Don't forget: ``git add settings.json && git commit && git push``"
                Write-Warn2 "-> then ``git pull`` on your other machines to receive these."
            }
        }
    }

    # Build a suggested settings.local.json from anything in the machine's old
    # settings that doesn't belong in the team repo: dropped plugins (+ their
    # marketplace registrations), orphan machine-only marketplaces, and any
    # non-plugin top-level keys (hooks, permissions, statusLine, theme, etc.).
    $dropped = @($machineOnly | Where-Object { $_ -notin $kept })

    $reservedKeys = @('enabledPlugins','extraKnownMarketplaces','skippedMarketplaces','skippedPlugins')
    $otherKeys = @($machine.Keys | Where-Object { $_ -notin $reservedKeys })

    $extraMarkets = [ordered]@{}
    if ($machine.extraKnownMarketplaces) {
        foreach ($mk in $machine.extraKnownMarketplaces.Keys) {
            if (-not $repo.extraKnownMarketplaces -or -not $repo.extraKnownMarketplaces.ContainsKey($mk)) {
                $extraMarkets[$mk] = $machine.extraKnownMarketplaces[$mk]
            }
        }
    }

    if ($dropped.Count -gt 0 -or $otherKeys.Count -gt 0 -or $extraMarkets.Count -gt 0) {
        Write-Host ""
        if ($otherKeys.Count -gt 0) {
            Write-Warn2 "Non-plugin top-level keys found (these belong in settings.local.json, not the team repo):"
            foreach ($k in $otherKeys) { Write-Host "      • $k" }
        }
        if ($dropped.Count -gt 0) {
            Write-Warn2 "Dropped plugins (preserved below so you can keep them locally):"
            foreach ($p in $dropped) { Write-Host "      • $p" }
        }

        $suggestion = [ordered]@{}
        if ($extraMarkets.Count -gt 0) {
            $suggestion.extraKnownMarketplaces = $extraMarkets
        }
        if ($dropped.Count -gt 0) {
            $droppedPlugins = [ordered]@{}
            foreach ($id in $dropped) { $droppedPlugins[$id] = $true }
            $suggestion.enabledPlugins = $droppedPlugins
        }
        foreach ($k in $otherKeys) {
            $suggestion[$k] = $machine[$k]
        }

        $localPath = Join-Path $ClaudeDir "settings.local.json"
        Write-Host ""
        if (Test-Path $localPath) {
            Write-Info "Merge this snippet into your existing $localPath"
        } else {
            Write-Info "Suggested $localPath (create the file and paste this)"
        }
        $suggestionJson = $suggestion | ConvertTo-Json -Depth 12
        $suggestionJson.Split("`n") | ForEach-Object { Write-Host "      $_" }
    }
    Write-Host ""
}

# 4. Back up existing settings.json + link/copy ------------------------------
if (Test-Path $SettingsPath) {
    $existing = Get-Item $SettingsPath -Force
    $alreadyLinked = ($existing.LinkType -eq "SymbolicLink" `
                       -and $existing.Target[0] -eq $RepoSettings)

    if ($alreadyLinked) {
        Write-Ok "settings.json already symlinked to this repo."
    } else {
        $backup = "$SettingsPath.backup-$Timestamp"
        if ($DryRun) {
            Write-Info "(dry-run) would back up $SettingsPath -> $backup"
        } else {
            Move-Item -Path $SettingsPath -Destination $backup
            Write-Ok "Backed up existing settings.json -> $backup"
        }
    }
}

if (-not (Test-Path $SettingsPath)) {
    if ($DryRun) {
        Write-Info "(dry-run) would link/copy $SettingsPath -> $RepoSettings"
    } else {
        $linked = $false
        try {
            New-Item -ItemType SymbolicLink -Path $SettingsPath -Target $RepoSettings -ErrorAction Stop | Out-Null
            Write-Ok "Linked $SettingsPath -> $RepoSettings"
            $linked = $true
        } catch {
            Write-Warn2 "Symlink failed (need Admin or Developer Mode). Falling back to copy."
        }
        if (-not $linked) {
            Copy-Item -Path $RepoSettings -Destination $SettingsPath
            Write-Ok "Copied $RepoSettings -> $SettingsPath"
            Write-Warn2 "NOTE: This is a copy, not a link. Re-run install.ps1 after pulling repo updates."
        }
    }
}

# 5. Side-channel installers -------------------------------------------------
# These can write to ~/.claude/settings.json -- which is now a symlink (or
# copy) to the team repo. Their additions are typically machine-specific
# (absolute paths, Node version, etc.) and must NOT be committed. Snapshot
# the repo file beforehand, run the installer, diff what it added, restore
# the repo file, and emit the additions as a settings.local.json suggestion.
Write-Host ""
Write-Bold "Running side-channel installers"
if (Get-Command npx -ErrorAction SilentlyContinue) {
    if ($DryRun) {
        Write-Info "(dry-run) would run: npx --yes get-shit-done-cc --claude --global"
        Write-Info "(dry-run) any settings.json keys it added would be captured and offered as a settings.local.json suggestion; the team repo file would stay clean"
    } else {
        $snapshot = [System.IO.Path]::GetTempFileName()
        Copy-Item -Path $RepoSettings -Destination $snapshot -Force

        Write-Info "Installing get-shit-done-cc (global)..."
        try {
            npx --yes get-shit-done-cc --claude --global
        } catch {
            Write-Warn2 "get-shit-done-cc install failed (non-fatal)"
        }

        # Diff: top-level keys in post that differ from pre (deep comparison via JSON).
        $pre  = Read-JsonFile $snapshot
        $post = Read-JsonFile $RepoSettings
        $sideAdds = [ordered]@{}
        foreach ($k in $post.Keys) {
            $preVal  = $pre[$k]
            $postVal = $post[$k]
            $preJson  = if ($null -eq $preVal)  { $null } else { ConvertTo-Json $preVal  -Depth 12 -Compress }
            $postJson = if ($null -eq $postVal) { $null } else { ConvertTo-Json $postVal -Depth 12 -Compress }
            if ($preJson -ne $postJson) { $sideAdds[$k] = $postVal }
        }

        # Restore the team repo file regardless of what the installer wrote.
        Copy-Item -Path $snapshot -Destination $RepoSettings -Force
        Remove-Item -Path $snapshot -Force

        if ($sideAdds.Count -gt 0) {
            Write-Ok "get-shit-done-cc installed (machine-specific additions captured below)."
            Write-Host ""
            $localPath = Join-Path $ClaudeDir "settings.local.json"
            Write-Warn2 "Side-channel installer wrote machine-specific keys to settings.json."
            Write-Warn2 "Restored the team repo file. Add these to $localPath"
            if (Test-Path $localPath) {
                Write-Warn2 "($localPath already exists -- merge the keys below into it)"
            }
            $addsJson = $sideAdds | ConvertTo-Json -Depth 12
            $addsJson.Split("`n") | ForEach-Object { Write-Host "      $_" }
        } else {
            Write-Ok "get-shit-done-cc done"
        }
    }
} else {
    Write-Warn2 "npx not found — skipping get-shit-done-cc. Install Node.js to enable."
}

# 6. Done --------------------------------------------------------------------
Write-Host ""
Write-Bold "All set."
Write-Host @"

Next steps:
  1. Restart Claude Code (or run /reload-plugins inside an active session).
  2. Run /plugin to verify the plugins are listed and enabled.
  3. If a merge happened, commit & push so other machines pick it up:
       cd "$RepoDir"
       git diff settings.json
       git add settings.json; git commit -m "merge: <plugin> from <machine>"; git push
"@
