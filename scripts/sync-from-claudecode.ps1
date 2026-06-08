#Requires -Version 7
<#
.SYNOPSIS
  Git-native incremental sync: oh-story-claudecode → oh-story-opencode

.DESCRIPTION
  基于 git diff 增量同步。不使用 robocopy/MIR，只处理实际变更的文件。
  追踪引用 (refs/sync/claudecode) 记录最近一次同步点，支持幂等执行。

.EXAMPLE
  .\scripts\sync-from-claudecode.ps1          # 预览变更
  .\scripts\sync-from-claudecode.ps1 -Apply   # 执行同步
  .\scripts\sync-from-claudecode.ps1 -Push    # 同步 + 推送
#>

param(
    [string]$ClaudecodePath = "D:\gz\skills\oh-story-claudecode",
    [switch]$Apply,
    [switch]$Push
)

$ErrorActionPreference = "Stop"
$syncRef  = "refs/sync/claudecode"
$syncHead = ".git/$syncRef"

# ── helpers ──

function git($args) { $res = & git @args 2>&1; if ($LASTEXITCODE -ne 0) { throw $res }; $res }
function _git($workDir, $args) { Push-Location $workDir; try { $res = & git @args 2>&1; if ($LASTEXITCODE -ne 0) { throw $res }; $res } finally { Pop-Location } }

function assert-ok {
    param($desc)
    Write-Host "  ✓ $desc" -ForegroundColor Green
}

function warn($msg) {
    Write-Host "  ⚠ $msg" -ForegroundColor Yellow
}

# ── step 0: guard ──

Write-Host "=== oh-story sync (git-native v2) ===" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $ClaudecodePath)) {
    Write-Host "ERROR: claudecode repo not found: $ClaudecodePath" -ForegroundColor Red
    Write-Host "Usage: .\scripts\sync-from-claudecode.ps1 -ClaudecodePath D:\path\to\repo"
    exit 1
}

# ── step 1: ensure remote ──

Write-Host "[1/5] Git topology" -ForegroundColor Yellow

$hasRemote = try { git remote get-url claudecode 2>$null; $true } catch { $false }
if (-not $hasRemote) {
    git remote add claudecode $ClaudecodePath
    Write-Host "  Added remote 'claudecode' → $ClaudecodePath"
} else {
    $url = git remote get-url claudecode
    Write-Host "  Remote 'claudecode' → $url"
}

# fetch latest
git fetch claudecode 2>&1 | Out-Null
$upstreamHead = _git $ClaudecodePath { git rev-parse --short=8 HEAD }
Write-Host "  Upstream HEAD : $upstreamHead (claudecode/main)"

# ── step 2: determine sync range ──

Write-Host ""
Write-Host "[2/5] Sync range" -ForegroundColor Yellow

if (Test-Path $syncHead) {
    $lastSync = Get-Content $syncHead -Raw
    try   { git rev-parse --verify "$lastSync^{commit}" 2>$null | Out-Null; $lastSyncValid = $true }
    catch { $lastSyncValid = $false }

    if ($lastSyncValid) {
        $lastSyncShort = git rev-parse --short=8 $lastSync
        Write-Host "  Last sync    : $lastSyncShort"
    } else {
        warn "stale sync ref; resetting to upstream HEAD"
        $lastSync = $null
    }
} else {
    Write-Host "  No sync marker — initial sync"
    $lastSync = $null
}

if (-not $lastSync) {
    # first-ever sync: diff from root commit of claudecode
    $lastSync = _git $ClaudecodePath { git rev-list --max-parents=0 HEAD }
    $lastSyncShort = git rev-parse --short=8 $lastSync
    Write-Host "  Range start   : $lastSyncShort (claudecode root)"
}

$currentUpstream = _git $ClaudecodePath { git rev-parse HEAD }

if ($lastSync -eq $currentUpstream) {
    Write-Host ""
    Write-Host "Already up to date. Nothing to sync." -ForegroundColor Green
    exit 0
}

$diffStat = _git $ClaudecodePath { git diff --stat $lastSync..HEAD }
$changedCount = ($diffStat | Measure-Object -Line).Lines
Write-Host "  Changed files : $changedCount"
Write-Host ""

# ── step 3: compute transformed diff ──

Write-Host "[3/5] Transform plan" -ForegroundColor Yellow

# Exclusion rules (files that exist ONLY in one platform)
$excludeGlobs = @(
    ".claude-plugin/**",
    ".claude/**",
    ".omc/**",
    "opencode.json",
    "AGENTS.md",
    ".story-deployed",
    ".sync-marker"
)

# Content transformations (regex → replacement)
$transforms = @(
    @{ Pattern = '\.claude/agents/';       Replace = '.opencode/agents/'       },
    @{ Pattern = '\.claude/skills/';       Replace = '.opencode/skills/'       },
    @{ Pattern = '\.claude-plugin/';       Replace = '.opencode/'              },
    @{ Pattern = '\bCLAUDE\.md\b';         Replace = 'AGENTS.md'               },
    @{ Pattern = 'settings\.local\.json';  Replace = 'opencode.json'           }
)

# get file list
$changedFiles = _git $ClaudecodePath { git diff --name-only $lastSync..HEAD }

$includeFiles = @()
$excludeFiles = @()

foreach ($f in $changedFiles) {
    $excluded = $false
    foreach ($pat in $excludeGlobs) {
        if ($f -like $pat) {
            $excludeFiles += $f
            $excluded = $true
            break
        }
    }
    if (-not $excluded) { $includeFiles += $f }
}

Write-Host "  To sync  : $($includeFiles.Count) files"
Write-Host "  Excluded : $($excludeFiles.Count) files"
if ($excludeFiles.Count -gt 0) {
    foreach ($f in $excludeFiles) { Write-Host "    ✗ $f" -ForegroundColor DarkGray }
}

if ($includeFiles.Count -eq 0) {
    Write-Host ""
    Write-Host "No applicable files to sync." -ForegroundColor Green
    # still update sync ref
    $currentUpstream | Set-Content -NoNewline $syncHead
    exit 0
}

# detect transforms needed
$transformCount = 0
foreach ($f in $includeFiles) {
    $fullPath = Join-Path $ClaudecodePath $f
    if (-not (Test-Path $fullPath)) { continue }  # deleted file
    try {
        $content = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8 -ErrorAction Stop
        foreach ($t in $transforms) {
            if ($content -match [regex]::Escape($t.Pattern)) {
                $transformCount++
                break
            }
        }
    } catch {
        # binary file, skip
    }
}
Write-Host "  Transforms: $transformCount files need Claude→OpenCode substitution"
Write-Host ""

# ── step 4: apply ──

if (-not $Apply) {
    Write-Host "[4/5] Dry-run (use -Apply to execute)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Files that would be synced:"
    foreach ($f in $includeFiles) {
        $status = _git $ClaudecodePath { git diff --name-status $lastSync..HEAD -- $f }
        Write-Host "  $status"
    }
    Write-Host ""
    Write-Host "Run with -Apply to execute the sync."
    exit 0
}

Write-Host "[4/5] Applying changes" -ForegroundColor Yellow

$applied   = 0
$transformed = 0

foreach ($f in $includeFiles) {
    $srcPath = Join-Path $ClaudecodePath $f
    $dstPath = $f

    # handle deleted files
    if (-not (Test-Path $srcPath)) {
        if (Test-Path $dstPath) {
            Remove-Item -LiteralPath $dstPath
            Write-Host "  D  $f" -ForegroundColor Red
            $applied++
        }
        continue
    }

    # ensure parent dir exists
    $parent = Split-Path $dstPath -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    # read source
    try {
        $content = Get-Content -LiteralPath $srcPath -Raw -Encoding UTF8 -ErrorAction Stop
    } catch {
        # binary: direct copy
        Copy-Item -LiteralPath $srcPath -Destination $dstPath -Force
        Write-Host "  M  $f (binary)" -ForegroundColor DarkGray
        $applied++
        continue
    }

    # apply transforms
    $original = $content
    foreach ($t in $transforms) {
        $content = $content -replace [regex]::Escape($t.Pattern), $t.Replace
    }

    if ($content -ne $original) {
        $transformed++
        Write-Host "  T  $f" -ForegroundColor Magenta
    } else {
        Write-Host "  M  $f" -ForegroundColor DarkGray
    }

    # write
    Set-Content -LiteralPath $dstPath -Value $content -Encoding UTF8 -NoNewline
    $applied++
}

Write-Host ""
Write-Host "  Applied    : $applied files"
Write-Host "  Transformed: $transformed files"
Write-Host ""

# ── step 5: commit ──

Write-Host "[5/5] Commit" -ForegroundColor Yellow

$srcVer = _git $ClaudecodePath { git describe --tags --always 2>$null }
if (-not $srcVer) { $srcVer = $upstreamHead }

$shortCommit = _git $ClaudecodePath { git log -1 --format="%s" HEAD }

git add -A
$status = git status --porcelain
if (-not $status) {
    Write-Host "  No changes to commit." -ForegroundColor Green
} else {
    git commit -m "sync: $srcVer" -m "Source: claudecode $upstreamHead — $shortCommit"
    Write-Host "  Committed." -ForegroundColor Green
}

# update sync marker
$currentUpstream | Set-Content -NoNewline $syncHead
git add $syncHead
git commit --amend --no-edit 2>$null
Write-Host "  Sync ref updated → $upstreamHead"

if ($Push) {
    Write-Host ""
    Write-Host "Pushing..." -ForegroundColor Yellow
    git push origin main
    Write-Host "  Pushed to origin/main" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
Write-Host "Next sync: .\scripts\sync-from-claudecode.ps1 -Apply"
