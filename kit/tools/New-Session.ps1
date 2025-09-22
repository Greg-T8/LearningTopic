#Requires -Version 7.4

param(
    [string]$Title = 'Test Session #45',      # Session title (prompted if empty)

    [int]$DurationMinutes = 60,
    [string]$SessionTemplate = '/kit/templates/session_template.md',
    [string]$TimeZoneId = 'America/Chicago',

    # Optional GitHub automation (OFF by default)
    [Boolean]$CreateIssue = $true,
    [switch]$EnsurePR,                       # Ensure a PR exists and link the issue
    [string[]]$Labels = @('type: session', 'no-exist'),

    # UX
    [switch]$Open,                           # Open created items
    [switch]$NoCommit                        # Skip git commit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Main = {
    . $Helpers
    . $Config

    Read-SessionTitle
    Initialize-Context
    $issue = $null
    if ($CreateIssue) { $issue = New-SessionIssue -Title $IssueTitle -Labels $Labels -Repo $RepoName }

    $pr = $null
    if ($EnsurePR) { $pr = Ensure-PullRequest -Repo $Repo -Branch $CurrentBranch -SessionIssue $issue }

    New-SessionMarkdown -Path $SessionPath -Template $SessionTemplatePath -Context @{
        Title           = $Title
        Date            = $DateStamp
        Time            = $Clock
        DurationMinutes = $DurationMinutes
        Branch          = $CurrentBranch
        IssueNumber     = if ($issue) { $issue.number } else { '' }
        IssueUrl        = if ($issue) { $issue.url } else { '' }
        PrNumber        = if ($pr) { $pr.number }    else { '' }
        PrUrl           = if ($pr) { $pr.url }       else { '' }
    }

    if (-not $NoCommit) {
        git add -- $SessionPath
        git commit -m "session: $Title ($DateStamp $Clock) [skip ci]" | Out-Null
    }

    if ($Open) {
        Start-Item (Resolve-RelativePath -From (Get-Location) -To $SessionPath)
        if ($issue) { Start-Item $issue.url }
        if ($pr) { Start-Item $pr.url }
    }

    Write-Host '✔ Session created:'
    Write-Host "  • Session : $(Resolve-RelativePath -From (Get-Location) -To $SessionPath)"
    if ($issue) { Write-Host "  • Issue   : #$($issue.number) $($issue.url)" }
    if ($pr) { Write-Host "  • PR      : #$($pr.number) $($pr.url)" }
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

    $script:RepoRoot      = Resolve-RepoRoot -Path '.'
    $script:RepoName      = Resolve-RepoName -RepoRoot $RepoRoot
    $script:CurrentBranch = Get-CurrentBranch -RepoRoot $RepoRoot

    # Single session file: sessions/YYYY/YYYY-MM-DD__HHmm-<slug>.md
    $script:SessionsDir         = Join-Path $RepoRoot ('sessions/{0}' -f $Now.ToString('yyyy'))
    $script:SessionName         = ('{0}-{1}-{2}.md' -f $DateStamp, $TimeStamp, (ConvertTo-Slug $Title))
    $script:SessionPath         = Join-Path $SessionsDir $SessionName
    $script:SessionTemplatePath = Resolve-RepoPath -RepoRoot $RepoRoot -Path $SessionTemplate

    # Titles for optional GH bits
    $script:IssueTitle = '[Session] {0} ({1} {2})' -f $Title, $DateStamp, $Clock
    $script:PrTitle    = '[Sessions] {0}' -f $CurrentBranch
}

$Helpers = {
    function Read-SessionTitle {
        if ([string]::IsNullOrWhiteSpace($Title)) {
            $Title = Read-Host -Prompt 'Enter session title'
            if ([string]::IsNullOrWhiteSpace($Title)) {
                throw 'A non-empty session title is required.'
            }
            # Recompute derived names that depend on $Title
            $script:SessionName = ('{0}-{1}-{2}.md' -f $DateStamp, $TimeStamp, (ConvertTo-Slug $Title))
            $script:SessionPath = Join-Path $SessionsDir $SessionName
            $script:IssueTitle  = '[Session] {0} ({1} {2})' -f $Title, $DateStamp, $Clock
        }
    }

    function Initialize-Context {
        Confirm-Tool -Name 'git' -Check 'git --version'
        Push-Location $RepoRoot
        try { git rev-parse --is-inside-work-tree *> $null } catch { throw "Not a git repository: $RepoRoot" }
        if ($CreateIssue -or $EnsurePR) { Confirm-Tool -Name 'gh' -Check 'gh --version' }
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
    else { 'N/A' }
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
            -replace '(^# Session:\s).*', "`${1}$($Context.Title)" `
            -replace '(?m)(^\*\*Date:\*\*\s).*', "`${1}$($Context.Date)" `
            -replace '(?m)(^\*\*Duration:\*\*\s).*', "`${1}$($Context.DurationMinutes) minutes" `
            -replace '(?m)(^\*\*Branch:\*\*\s).*', "`${1}$($Context.Branch)" `
            -replace '\$ISSUE_NUMBER', { [string]$Context.IssueNumber } `
            -replace '\$ISSUE_URL', { [string]$Context.IssueUrl } `
            -replace '\$PR_NUMBER', { [string]$Context.PrNumber } `
            -replace '\$PR_URL', { [string]$Context.PrUrl }

        Set-Content -Path $Path -Value $content -Encoding UTF8
    }


    function New-SessionIssue {
        param(
            [Parameter(Mandatory)] [string]$Title,
            [Parameter(Mandatory)] [string[]]$Labels,
            [Parameter(Mandatory)] [string]$Repo
        )

        # Reuse existing open issue with same title
        $existing = gh issue list --repo $Repo --state open --search "in:title $Title" --json "number,title,url" | ConvertFrom-Json
        if ($existing -and $existing.Count -ge 1) { return $existing[0] }

        # Fetch repo label names
        $repoLabels = gh label list --repo $Repo --json name 2>$null | ConvertFrom-Json
        $repoLabelNames = @()
        if ($repoLabels) { $repoLabelNames = $repoLabels | ForEach-Object { $_.name } }

        # Case-insensitive set of existing labels
        $labelSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in $repoLabelNames) { [void]$labelSet.Add(($n ?? '').Trim()) }

        # Normalize requested labels (trim, dedupe, non-empty)
        $requested = [System.Linq.Enumerable]::ToArray(
            [System.Linq.Enumerable]::Distinct(
                [System.Linq.Enumerable]::Where($Labels, [Func[string, bool]] { param($x) -not [string]::IsNullOrWhiteSpace($x) }),
                [System.StringComparer]::OrdinalIgnoreCase
            )
        )

        $valid   = New-Object System.Collections.Generic.List[string]
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($l in $requested) {
            $t = $l.Trim()
            if ($labelSet.Contains($t)) { [void]$valid.Add($t) } else { [void]$missing.Add($t) }
        }

        if ($missing.Count -gt 0) {
            Write-Warning ('The following labels do not exist in {0} and will be ignored: {1}' -f $Repo, ($missing -join ', '))
        }

        # Build label args only for labels that actually exist
        $labelArgs = @()
        foreach ($l in $valid) { $labelArgs += @('--label', "`"$l`"") }

        $body = @(
            "Session: $Title"
            "Date: $DateStamp"
            "Time: $Clock"
            "Duration: $DurationMinutes minutes"
            "Branch: $CurrentBranch"
            ''
            '_Auto-created by New-Session.ps1_'
        ) -join "`n"

        gh issue create --repo $Repo --title $Title --body $body @labelArgs | ConvertFrom-Json
    }

    function Ensure-PullRequest {
        param(
            [Parameter(Mandatory)] [string]$Repo,
            [Parameter(Mandatory)] [string]$Branch,
            [Parameter(Mandatory)] $SessionIssue
        )
        $pr = gh pr view --repo $Repo --json number, url, headRefName, baseRefName, state 2>$null | ConvertFrom-Json
        if (-not $pr) {
            $body = if ($SessionIssue) { "Tracking sessions for **$Branch**.`n`nLinked session issue: #$($SessionIssue.number)" } else { "Tracking sessions for **$Branch**." }
            $pr   = gh pr create --repo $Repo --title $PrTitle --body $body --head $Branch --fill --json number, url | ConvertFrom-Json
        }
        elseif ($SessionIssue) {
            gh pr edit --repo $Repo --add-issue $SessionIssue.number | Out-Null
        }
        return $pr
    }

    function Confirm-Tool {
        param(
            [Parameter(Mandatory)]
            [string]$Name,
            [Parameter(Mandatory)]
            [string]$Check
        )
        try {
            Invoke-Expression $Check *> $null
        }
        catch { throw "Required tool not found: $Name" }
    }

    function Resolve-RepoRoot {
        param([string]$Path)
        if ($Path -eq '.' -or -not $Path) {
            $root = git rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -eq 0 -and $root) { return $root }
            # Fallback to current dir
            return (Resolve-Path '.').Path
        }
        # Given path: ensure it's absolute
        return (Resolve-Path $Path).Path
    }

    function Resolve-RepoName {
        # Returns repo name in "owner/repo" format
        param([string]$RepoRoot)
        #
        # Ensure we are working with a full path
        $fullPath = Resolve-Path -Path $RepoRoot

        # Run git to get the remote URL
        $remoteUrl = git -C $fullPath remote get-url origin 2>$null

        if (-not $remoteUrl) {
            throw "Could not resolve remote URL from $fullPath"
        }

        if ($remoteUrl -match 'github\.com[:/](.+?)(?:\.git)?$') {
            return $Matches[1]
        }
        else {
            throw "Unexpected remote URL format: $remoteUrl"
        }
    }

    function Resolve-RepoPath {
        param(
            [Parameter(Mandatory)] [string]$RepoRoot,
            [Parameter(Mandatory)] [string]$Path
        )

        if ([string]::IsNullOrWhiteSpace($Path)) { return (Resolve-Path $RepoRoot).Path }

        # Treat leading / or \ (without drive) as repo-root-relative:  "/kit/.." -> "<RepoRoot>\kit\.."
        if ($Path -match '^[\\/]' -and -not ($Path -match '^[A-Za-z]:')) {
            $rel = $Path.TrimStart('\', '/')
            return (Resolve-Path (Join-Path $RepoRoot $rel)).Path
        }

        # Normal relative path -> relative to repo root
        if (-not [IO.Path]::IsPathRooted($Path)) {
            return (Resolve-Path (Join-Path $RepoRoot $Path)).Path
        }

        # Already absolute (C:\..., \\server\share, /abs)
        return (Resolve-Path $Path).Path
    }


    function Get-CurrentBranch {
        param([string]$RepoRoot)
        Push-Location $RepoRoot
        try {
            $b = (git rev-parse --abbrev-ref HEAD).Trim()
            if (-not $b) { throw 'No branch detected' }
            return $b
        }
        finally { Pop-Location }
    }

    function ConvertTo-Slug {
        param([string]$Text)
        $s = $Text.ToLowerInvariant()
        $s = $s -replace '[^a-z0-9]+', '-'
        $s = $s.Trim('-')
        if (-not $s) { $s = 'session' }
        return $s
    }

    function Resolve-RelativePath {
        param([string]$From, [string]$To)
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
