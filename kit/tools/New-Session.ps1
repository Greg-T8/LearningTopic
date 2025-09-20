#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

param(
    [Parameter(Mandatory = $true)]
    [string]$Title,                          # Session title

    [string]$Repo = '.',                     # Local repo root
    [int]$DurationMinutes = 60,
    [string]$SessionTemplate = 'templates/labs/session_template.md',
    [string]$TimeZoneId = 'America/Chicago', # Deterministic timestamps

    # Optional GitHub automation (OFF by default)
    [switch]$CreateIssue,                    # Create/reuse a session issue
    [switch]$EnsurePR,                       # Ensure a PR exists and link the issue
    [string[]]$Labels = @('session','learning','daily'),

    # UX
    [switch]$Open,                           # Open created items
    [switch]$NoCommit                        # Skip git commit
)

$Main = {
    . $Config
    . $Helpers
    Initialize-Context
    $issue = $null
    if ($CreateIssue) { $issue = Ensure-SessionIssue -Title $IssueTitle -Labels $Labels -Repo $Repo }

    $pr = $null
    if ($EnsurePR)  { $pr = Ensure-PullRequest -Repo $Repo -Branch $CurrentBranch -SessionIssue $issue }

    New-SessionMarkdown -Path $SessionPath -Template $SessionTemplate -Context @{
        Title           = $Title
        Date            = $DateStamp
        Time            = $Clock
        DurationMinutes = $DurationMinutes
        Branch          = $CurrentBranch
        IssueNumber     = if ($issue) { $issue.number } else { '' }
        IssueUrl        = if ($issue) { $issue.url } else { '' }
        PrNumber        = if ($pr)    { $pr.number }    else { '' }
        PrUrl           = if ($pr)    { $pr.url }       else { '' }
    }

    if (-not $NoCommit) {
        git add -- $SessionPath
        git commit -m "session: $Title ($DateStamp $Clock) [skip ci]" | Out-Null
    }

    if ($Open) {
        Start-Item (Resolve-RelativePath -From (Get-Location) -To $SessionPath)
        if ($issue) { Start-Item $issue.url }
        if ($pr)    { Start-Item $pr.url }
    }

    Write-Host "✔ Session created:"
    Write-Host "  • Session : $(Resolve-RelativePath -From (Get-Location) -To $SessionPath)"
    if ($issue) { Write-Host "  • Issue   : #$($issue.number) $($issue.url)" }
    if ($pr)    { Write-Host "  • PR      : #$($pr.number) $($pr.url)" }
}

$Config = {
    function Get-NowLocal {
        param([string]$TzId)
        try { [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, [TimeZoneInfo]::FindSystemTimeZoneById($TzId)) }
        catch { Get-Date }
    }

    $script:Now        = Get-NowLocal -TzId $TimeZoneId
    $script:DateStamp  = $Now.ToString('yyyy-MM-dd')
    $script:TimeStamp  = $Now.ToString('HHmm')
    $script:Clock      = $Now.ToString('HH:mm')

    $script:RepoRoot      = Resolve-RepoRoot -Path $Repo
    $script:CurrentBranch = Get-CurrentBranch -RepoRoot $RepoRoot

    # Single session file: sessions/YYYY/YYYY-MM-DD__HHmm-<slug>.md
    $script:SessionsDir = Join-Path $RepoRoot ("sessions/{0}" -f $Now.ToString('yyyy'))
    $script:SessionName = ("{0}__{1}-{2}.md" -f $DateStamp, $TimeStamp, (To-Slug $Title))
    $script:SessionPath = Join-Path $SessionsDir $SessionName

    # Titles for optional GH bits
    $script:IssueTitle = "[Session] {0} ({1} {2})" -f $Title, $DateStamp, $Clock
    $script:PrTitle    = "[Sessions] {0}" -f $CurrentBranch
}

$Helpers = {
    function Initialize-Context {
        Ensure-Tool -Name 'git' -Check 'git --version'
        Push-Location $RepoRoot
        try { git rev-parse --is-inside-work-tree *> $null } catch { throw "Not a git repository: $RepoRoot" }
        if ($CreateIssue -or $EnsurePR) { Ensure-Tool -Name 'gh' -Check 'gh --version' }
        Write-Host "Repo: $RepoRoot"
        Write-Host "Branch: $CurrentBranch"
    }

    function New-SessionMarkdown {
        param(
            [Parameter(Mandatory)] [string]$Path,
            [Parameter(Mandatory)] [string]$Template,
            [Parameter(Mandatory)] [hashtable]$Context
        )
        New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null

        $content = if (Test-Path $Template) { Get-Content -Path $Template -Raw } else {
@"
# Session: $($Context.Title)

**Date:** $($Context.Date)
**Time:** $($Context.Time)
**Duration:** $($Context.DurationMinutes) minutes
**Branch:** $($Context.Branch)
**Linked Issue/PR:** $(
    if ($Context.IssueNumber -and $Context.PrNumber) { "#$($Context.IssueNumber) / #$($Context.PrNumber)" }
    elseif ($Context.IssueNumber) { "#$($Context.IssueNumber)" }
    elseif ($Context.PrNumber) { "#$($Context.PrNumber)" }
    else { "N/A" }
)

## Objective

Short statement of what this session will accomplish.

## Plan

- Step 1
- Step 2
- Step 3

## Notes

- Key findings
- Commands run
- Follow-ups

## Evidence

- Screenshot or output snippet reference

"@
        }

        $content = $content `
            -replace '\$TITLE',            [regex]::Escape($Context.Title) `
            -replace '\$DATE',             [regex]::Escape($Context.Date) `
            -replace '\$TIME',             [regex]::Escape($Context.Time) `
            -replace '\$DURATION',         [regex]::Escape([string]$Context.DurationMinutes) `
            -replace '\$BRANCH',           [regex]::Escape($Context.Branch) `
            -replace '\$ISSUE_NUMBER',     [regex]::Escape([string]$Context.IssueNumber) `
            -replace '\$ISSUE_URL',        [regex]::Escape([string]$Context.IssueUrl) `
            -replace '\$PR_NUMBER',        [regex]::Escape([string]$Context.PrNumber) `
            -replace '\$PR_URL',           [regex]::Escape([string]$Context.PrUrl)

        Set-Content -Path $Path -Value $content -Encoding UTF8
    }

    function Ensure-SessionIssue {
        param(
            [Parameter(Mandatory)] [string]$Title,
            [Parameter(Mandatory)] [string[]]$Labels,
            [Parameter(Mandatory)] [string]$Repo
        )
        $existing = gh issue list --repo $Repo --state open --search "`"$Title`"" --json number,title,url | ConvertFrom-Json
        if ($existing -and $existing.Count -ge 1) { return $existing[0] }

        $labelArgs = @()
        foreach ($l in $Labels) { $labelArgs += @('--label', $l) }

        $body = @(
            "Session: $Title"
            "Date: $DateStamp"
            "Time: $Clock"
            "Duration: $DurationMinutes minutes"
            "Branch: $CurrentBranch"
            ""
            "_Auto-created by New-Session.ps1_"
        ) -join "`n"

        gh issue create --repo $Repo --title $Title --body $body @labelArgs --json number,title,url | ConvertFrom-Json
    }

    function Ensure-PullRequest {
        param(
            [Parameter(Mandatory)] [string]$Repo,
            [Parameter(Mandatory)] [string]$Branch,
            [Parameter(Mandatory)] $SessionIssue
        )
        $pr = gh pr view --repo $Repo --json number,url,headRefName,baseRefName,state 2>$null | ConvertFrom-Json
        if (-not $pr) {
            $body = if ($SessionIssue) { "Tracking sessions for **$Branch**.`n`nLinked session issue: #$($SessionIssue.number)" } else { "Tracking sessions for **$Branch**." }
            $pr   = gh pr create --repo $Repo --title $PrTitle --body $body --head $Branch --fill --json number,url | ConvertFrom-Json
        } elseif ($SessionIssue) {
            gh pr edit --repo $Repo --add-issue $SessionIssue.number | Out-Null
        }
        return $pr
    }

    function Ensure-Tool {
        param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Check)
        try { Invoke-Expression $Check *> $null } catch { throw "Required tool not found: $Name" }
    }

    function Resolve-RepoRoot {
        param([string]$Path)
        if ($Path -eq '.' -or -not $Path) {
            $root = git rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -eq 0 -and $root) { return $root }
            return (Resolve-Path '.').Path
        }
        return (Resolve-Path $Path).Path
    }

    function Get-CurrentBranch {
        param([string]$RepoRoot)
        Push-Location $RepoRoot
        try {
            $b = (git rev-parse --abbrev-ref HEAD).Trim()
            if (-not $b) { throw "No branch detected" }
            return $b
        } finally { Pop-Location }
    }

    function To-Slug {
        param([string]$Text)
        $s = $Text.ToLowerInvariant()
        $s = $s -replace '[^a-z0-9]+','-'
        $s = $s.Trim('-')
        if (-not $s) { $s = 'session' }
        return $s
    }

    function Resolve-RelativePath {
        param([string]$From,[string]$To)
        $fromUri = [Uri]((Resolve-Path $From).Path + [IO.Path]::DirectorySeparatorChar)
        $toUri   = [Uri](Resolve-Path $To).Path
        return $fromUri.MakeRelativeUri($toUri).ToString()
    }

    function Start-Item {
        param([string]$Target)
        if ($IsWindows) { Start-Process $Target | Out-Null }
        elseif ($IsMacOS) { & open $Target | Out-Null }
        else { & xdg-open $Target | Out-Null }
    }
}

& $Main
