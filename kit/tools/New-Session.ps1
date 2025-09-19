<#
.SYNOPSIS
  Start a 1-hour learning session:
  - Creates a session branch (session/YYYY-MM-DD-topic-slug-L#)
  - Renders PR template (full/slim) with date/tech/topic/slug
  - Creates evidence folder under /sessions/YYYY-MM-DD-topic-slug/
  - Pushes branch and opens a PR (labeled "Session"; title encodes L1–L4)
  - Optionally starts a local 1-hour reminder timer

.EXAMPLE
  ./scripts/New-Session.ps1 -Tech "Kubernetes" -Topic "RBAC Basics" -Level L1 -Template slim

.PARAMETER Tech
  Technology focus (e.g., "Kubernetes", "Azure Networking", "C# LINQ").
  If omitted, attempts to infer from the repository name.

.PARAMETER Topic
  The specific topic/goal for this 1-hour block (used in title and slug).

.PARAMETER Level
  Outcome level to start at: L1, L2, L3, L4. (You can bump it before merging.)

.PARAMETER Template
  "slim" or "full" PR body variant.

.PARAMETER Minutes
  Duration for the local timer (default 60). Ignored if -SkipTimer is set.

.PARAMETER SkipTimer
  Don’t start the local reminder timer.

.PARAMETER DryRun
  Show what would happen without touching git/GitHub.
#>

[CmdletBinding()]
param(
    [string]$Tech,
    [Parameter(Mandatory)][string]$Topic,
    [ValidateSet('L1', 'L2', 'L3', 'L4')][string]$Level = 'L1',
    [ValidateSet('slim', 'full')][string]$Template = 'slim',
    [int]$Minutes = 60,
    [switch]$SkipTimer,
    [switch]$DryRun
)

# ---------------------------
# Helpers
# ---------------------------
function Stop-WithMessage($msg) { throw "[New-Session] $msg" }

function Require-Tool($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Stop-WithMessage "Required tool '$name' not found in PATH."
    }
}

function Get-RepoRoot {
    try {
        $root = git rev-parse --show-toplevel 2>$null
        if (-not $root) { Stop-WithMessage 'Not in a Git repository.' }
        return $root.Trim()
    }
    catch { Stop-WithMessage 'Unable to locate repository root.' }
}

function Slugify([string]$s) {
    ($s -replace '[^A-Za-z0-9 ]', '' -replace '\s+', '-').ToLower()
}

# ---------------------------
# Preconditions
# ---------------------------
Require-Tool git
Require-Tool gh

$RepoRoot = Get-RepoRoot
Set-Location $RepoRoot

# Infer $Tech from repo if not provided
if (-not $Tech) {
    $repoName = Split-Path -Leaf $RepoRoot
    $Tech = $repoName -replace '-', ' '
}

$Date = Get-Date -Format 'yyyy-MM-dd'
$Slug = Slugify $Topic
$Branch = "session/$Date-$Slug-$Level"

# Outcome text for title
$OutcomeMap = @{
    'L1' = 'L1 Framed'
    'L2' = 'L2 Built & Planned'
    'L3' = 'L3 Verified Core'
    'L4' = 'L4 Complete'
}
$OutcomeText = $OutcomeMap[$Level]

# ---------------------------
# Resolve template path
# ---------------------------
$TemplateCandidates = @(
    Join-Path $RepoRoot "templates\pull_requests\pull_request_template_$Template.md"),
Join-Path $RepoRoot ".github\pull_request_template_$Template.md"
)

$TemplatePath = $TemplateCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $TemplatePath) {
    Stop-WithMessage "PR template not found. Expected at: `n  templates/pull_requests/pull_request_template_$Template.md `n  or .github/pull_request_template_$Template.md"
}

# Rendered PR body saved at repo root (passed to gh --body-file)
$RenderedPath = Join-Path $RepoRoot 'pull_request_template.md'

# ---------------------------
# Compose rendered PR body
# ---------------------------
$Body = (Get-Content $TemplatePath -Raw) `
    -replace '\{\{date\}\}', [Regex]::Escape($Date) `
    -replace '\{\{tech\}\}', [Regex]::Escape($Tech) `
    -replace '\{\{topic\}\}', [Regex]::Escape($Topic) `
    -replace '\{\{slug\}\}', [Regex]::Escape($Slug) `
    -replace '\{\{lab\}\}', '' `
    -replace '\{\{drill\}\}', '' `
    -replace '\{\{links\}\}', '' `
    -replace '\{\{fixes\}\}', '' `
    -replace '\{\{next\}\}', ''

if ($DryRun) {
    Write-Host "Would write PR body to: $RenderedPath"
}
else {
    $Body | Set-Content -Path $RenderedPath -Encoding UTF8
}

# ---------------------------
# Ensure sessions evidence folder
# ---------------------------
$SessionDir = Join-Path $RepoRoot ('sessions\{0}-{1}' -f $Date, $Slug)
if (-not (Test-Path $SessionDir)) {
    if ($DryRun) { Write-Host "Would create directory: $SessionDir" }
    else { New-Item -ItemType Directory -Force -Path $SessionDir | Out-Null }
}

# Seed a minimal README in the session folder (optional, helpful)
$SessionReadme = Join-Path $SessionDir 'README.md'
if (-not (Test-Path $SessionReadme)) {
    $seed = @"
# Session $Date — $Topic

- Evidence goes here (screenshots, CLI outputs, notes).
- Related lab(s): (link issues/files)
"@
    if ($DryRun) { Write-Host "Would create: $SessionReadme" }
    else { $seed | Set-Content -Path $SessionReadme -Encoding UTF8 }
}

# ---------------------------
# Create branch, commit scaffold, push
# ---------------------------
# Avoid branch collision: if exists, append numeric suffix
function Get-UniqueBranch([string]$b) {
    $candidate = $b; $n = 2
    while (git show-ref --verify --quiet "refs/heads/$candidate") {
        $candidate = "$b-$n"; $n++
    }
    return $candidate
}
$Branch = Get-UniqueBranch $Branch

$Title = "Session $Date — $Topic ($OutcomeText)"

if ($DryRun) {
    Write-Host "Would create branch: $Branch"
    Write-Host "Would git add: $RenderedPath, $SessionDir"
    Write-Host "Would commit & push, then create PR titled: $Title"
}
else {
    git checkout -b $Branch | Out-Null
    git add $RenderedPath $SessionDir
    git commit -m "Session $Date — $Topic ($Level scaffold)" | Out-Null
    git push -u origin $Branch | Out-Null

    # Ensure the generic Session label exists (no-op if already present)
    try {
        gh label create 'Session' --color F59E0B --description 'Learning session PR' 2>$null | Out-Null
    }
    catch { }

    # Create PR (body from rendered template)
    gh pr create --title $Title --body-file $RenderedPath --label 'Session' --fill | Out-Null
}

# ---------------------------
# Fetch PR info and optionally start the local timer
# ---------------------------
if (-not $DryRun) {
    try {
        $prInfo = gh pr view --json number, repository 2>$null | ConvertFrom-Json
        $PrNumber = $prInfo.number
        $RepoFull = $prInfo.repository.nameWithOwner
        $Owner, $Name = $RepoFull.Split('/')

        if (-not $SkipTimer) {
            $TimerScript = Join-Path $RepoRoot 'scripts\Start-SessionTimer.ps1'
            if (Test-Path $TimerScript) {
                & $TimerScript -RepoOwner $Owner -RepoName $Name -PrNumber $PrNumber -Minutes $Minutes
            }
            else {
                Write-Host 'Timer script not found at scripts/Start-SessionTimer.ps1 (skipping reminders).'
            }
        }
        Write-Host "✅ Session started: PR #$PrNumber — $Title"
    }
    catch {
        Write-Warning "Started session, but couldn't retrieve PR info or start timer: $($_.Exception.Message)"
    }
}
else {
    Write-Host '✅ Dry run complete.'
}
