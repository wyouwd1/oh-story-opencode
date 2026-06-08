param(
    [Parameter(Mandatory=$true)]
    [string]$ClaudecodeRepo,

    [Parameter(Mandatory=$true)]
    [string]$OpencodeRepo,

    [switch]$AutoCommit = $false
)

$ErrorActionPreference = "Stop"

Write-Host "=== oh-story sync: claudecode → opencode ===" -ForegroundColor Cyan
Write-Host "Source : $ClaudecodeRepo"
Write-Host "Target : $OpencodeRepo"
Write-Host ""

# --- Step 1: Pull latest from claudecode ---
Write-Host "[1/5] Pulling oh-story-claudecode..." -ForegroundColor Yellow
Push-Location $ClaudecodeRepo
try {
    git fetch origin
    $localSha  = git rev-parse HEAD
    $remoteSha = git rev-parse origin/main
    if ($localSha -eq $remoteSha) {
        Write-Host "  Already up to date ($localSha)"
    } else {
        git pull --rebase origin main
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARNING: rebase conflicts detected, resolve manually then re-run" -ForegroundColor Red
            Write-Host "  Conflicted files:" -ForegroundColor Red
            git diff --name-only --diff-filter=U
            exit 1
        }
        Write-Host "  Updated: $localSha -> $(git rev-parse HEAD)"
    }
} finally {
    Pop-Location
}

# --- Step 2: Mirror files (exclude platform-specific dirs) ---
Write-Host "[2/5] Mirroring files..." -ForegroundColor Yellow

$excludeDirs = @(
    ".git",
    ".claude-plugin",
    ".claude",
    ".opencode",
    ".omc"
)
$excludeFiles = @(
    "opencode.json",
    "AGENTS.md",
    ".story-deployed"
)

$robocopyExclude = ($excludeDirs | ForEach-Object { "/XD `"$_`"" }) -join " "
$robocopyExclude += " " + (($excludeFiles | ForEach-Object { "/XF `"$_`"" }) -join " ")

# Mirror dirs
$dirs = @("skills", "scripts", "demo", ".github")
foreach ($d in $dirs) {
    $src = Join-Path $ClaudecodeRepo $d
    $dst = Join-Path $OpencodeRepo $d
    if (Test-Path $src) {
        robocopy $src $dst /MIR /NJH /NJS /NP /NFL /NDL /R:0 /W:0 $robocopyExclude.Split(" ")
        Write-Host "  Synced: $d/"
    }
}

# Mirror root files (selective, not all)
$rootFiles = @("README.md", "README_EN.md", "CHANGELOG.md", "LICENSE", "CONTRIBUTING.md", ".gitignore")
foreach ($f in $rootFiles) {
    $src = Join-Path $ClaudecodeRepo $f
    $dst = Join-Path $OpencodeRepo $f
    if (Test-Path $src) {
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-Host "  Synced: $f"
    }
}

# --- Step 3: Transform Claude Code → OpenCode references ---
Write-Host "[3/5] Applying OpenCode transformations..." -ForegroundColor Yellow

$transformations = @(
    @{
        Pattern = '\.claude/agents/'
        Replace = '.opencode/agents/'
        Files   = @("skills/*/SKILL.md", "skills/*/references/**/*.md")
    },
    @{
        Pattern = '\.claude-plugin/'
        Replace = '.opencode/'
        Files   = @("README.md", "README_EN.md")
    },
    @{
        Pattern = 'CLAUDE\.md'
        Replace = 'AGENTS.md'
        Files   = @("skills/story-setup/SKILL.md", "skills/story-setup/UPGRADING.md")
    },
    @{
        Pattern = 'settings\.local\.json'
        Replace = 'opencode.json'
        Files   = @("skills/story-setup/SKILL.md")
    }
)

Push-Location $OpencodeRepo
try {
    foreach ($t in $transformations) {
        foreach ($pattern in $t.Files) {
            $files = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
            foreach ($file in $files) {
                $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
                if ($content -match [regex]::Escape($t.Pattern)) {
                    $newContent = $content -replace [regex]::Escape($t.Pattern), $t.Replace
                    Set-Content -LiteralPath $file.FullName -Value $newContent -Encoding UTF8 -NoNewline
                    Write-Host "  Transformed: $($file.Name)  ($($t.Pattern) → $($t.Replace))"
                }
            }
        }
    }
} finally {
    Pop-Location
}

# --- Step 4: Show changes ---
Write-Host "[4/5] Changes to commit:" -ForegroundColor Yellow
Push-Location $OpencodeRepo
try {
    git status --short
    Write-Host ""
    git diff --stat
} finally {
    Pop-Location
}

# --- Step 5: Commit ---
if ($AutoCommit) {
    Write-Host "[5/5] Auto-committing..." -ForegroundColor Yellow
    Push-Location $OpencodeRepo
    try {
        $srcVer = & { Push-Location $ClaudecodeRepo; git describe --tags --always; Pop-Location }
        git add .
        git commit -m "sync: update from oh-story-claudecode $srcVer" -m "Automated sync: mirror + OpenCode transform"
        Write-Host "  Committed. Run 'git push origin main' to upload." -ForegroundColor Green
    } finally {
        Pop-Location
    }
} else {
    Write-Host "[5/5] Review changes above, then:" -ForegroundColor Yellow
    Write-Host "  cd $OpencodeRepo"
    Write-Host "  git add . && git commit -m 'sync: update from oh-story-claudecode'"
    Write-Host "  git push origin main"
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
