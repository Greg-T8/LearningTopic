[CmdletBinding()]
param(
    [string]$DefaultBranch = 'main',
    [string]$Repo,
    [int]$DurationMinutes = 60,

    # Project targeting: EITHER supply ProjectUrl OR (ProjectOwner + ProjectNumber)
    [string]$ProjectUrl,
    [string]$ProjectOwner,
    [int]$ProjectNumber
)

$Main = {
    . $Helpers
    . $Config   # include only if needed

    Validate-Branch -DefaultBranch $script:DefaultBranch

    $repo  = Resolve-Repo -Repo $script:Repo
    $owner = $repo.Split('/')[0]

    $context = Get-LabContext -Repo $repo
    $stamp   = Get-NowStamp

    $session = New-SessionIssue `
        -Repo          $repo `
        -Slug          $context.Slug `
        -Stamp         $stamp `
        -DurationMins  $script:DurationMinutes `
        -LabIssue      $context.LabIssue `
        -Branch        $context.Branch `
        -LabFileUrl    $context.LabFileUrl

    Add-IssueToProject `
        -Repo           $repo `
        -IssueNumber    $session.Number `
        -Owner          $owner `
        -ProjectUrl     $script:ProjectUrl `
        -ProjectOwner   $script:ProjectOwner `
        -ProjectNumber  $script:ProjectNumber

    Update-LabFileSessionsSection `
        -LabFile       $context.LabFile `
        -Stamp         $stamp `
        -Branch        $context.Branch `
        -SessionNumber $session.Number

    Commit-And-Push -LabFile $context.LabFile -Slug $context.Slug -Stamp $stamp -SessionNumber $session.Number

    Show-Summary -SessionNumber $session.Number -LabIssue $context.LabIssue -LabFile $context.LabFile
}

$Config = {
    # Shared values, constants, or settings
    $script:DefaultBranch   = $DefaultBranch
    $script:Repo            = $Repo
    $script:DurationMinutes = $DurationMinutes
    $script:ProjectUrl      = $ProjectUrl
    $script:ProjectOwner    = $ProjectOwner
    $script:ProjectNumber   = $ProjectNumber
}

$Helpers = {
    function Fail([string]$Message) { Write-Error $Message; exit 1 }
    function Run([string]$Command) {
        Write-Host ">> $Command" -ForegroundColor Cyan
        Invoke-Expression $Command
    }
    function Get-NowStamp { (Get-Date).ToString('yyyy-MM-dd HH:mm') }

    function Resolve-Repo {
        param([string]$Repo)
        if ($Repo) { return $Repo }
        $url = (git remote get-url origin) 2>$null
        if (-not $url) { Fail 'Cannot infer repo. Provide -Repo owner/repo.' }
        if ($url -match '[:/]([^/]+/[^/\.]+)(\.git)?$') { return $Matches[1] }
        Fail "Failed to parse owner/repo from origin URL '$url'"
    }

    function Validate-Branch {
        param([string]$DefaultBranch)
        $branch = (git rev-parse --abbrev-ref HEAD).Trim()
        if (-not $branch) { Fail 'Not in a git repo?' }
        if ($branch -eq $DefaultBranch) { Fail "You are on '$DefaultBranch'. Switch to a lab branch (lab/yyyy-mm-dd-slug)." }
        if ($branch -notmatch '^lab/(\d{4}-\d{2}-\d{2})-([a-z0-9-]+)$') {
            Fail "Branch '$branch' doesn't match expected 'lab/yyyy-mm-dd-slug'."
        }
    }

    function Get-LabContext {
        param([string]$Repo)

        $branch = (git rev-parse --abbrev-ref HEAD).Trim()
        if ($branch -notmatch '^lab/(\d{4}-\d{2}-\d{2})-([a-z0-9-]+)$') {
            Fail "Branch '$branch' doesn't match expected 'lab/yyyy-mm-dd-slug'."
        }
        $day  = $Matches[1]
        $slug = $Matches[2]

        $labDir  = "labs/$day-$slug"
        $labFile = "$labDir/$day-$slug.md"
        if (-not (Test-Path $labFile)) { Fail "Lab file not found at $labFile" }

        # Extract linked issue number from markdown
        $labIssue = $null
        Get-Content $labFile | ForEach-Object {
            if ($_ -match '^\*\*Linked Issue/PR:\*\*\s*#(\d+)\s*$') { $labIssue = [int]$Matches[1] }
        }
        if (-not $labIssue) { Fail "Could not find '**Linked Issue/PR:** #<num>' in $labFile" }

        $labFileUrl = "https://github.com/$Repo/blob/$branch/$labFile"

        [pscustomobject]@{
            Branch     = $branch
            Day        = $day
            Slug       = $slug
            LabDir     = $labDir
            LabFile    = $labFile
            LabIssue   = $labIssue
            LabFileUrl = $labFileUrl
        }
    }

    function New-SessionIssue {
        param(
            [string]$Repo,
            [string]$Slug,
            [string]$Stamp,
            [int]$DurationMins,
            [int]$LabIssue,
            [string]$Branch,
            [string]$LabFileUrl
        )

        $title = "[Session] $Slug — $Stamp ($DurationMins min)"

        $body = @"
**Lab**: #$LabIssue
**Lab Notes**: [$Slug.md]($LabFileUrl)

**Plan**
- What will I do this session?

**Outcome**
- What did I do? What did I learn?
"@

        $cmd = "gh issue create -R $Repo --title `"$title`" --body @'$body'@ --label `"type: session`" --label `"status: in-progress`""
        $createdUrlOut = (Run $cmd | Select-Object -Last 1)

        if ($createdUrlOut -notmatch '/issues/(\d+)$') {
            Fail 'Could not determine session issue number.'
        }

        [pscustomobject]@{
            Number = [int]$Matches[1]
            Title  = $title
        }
    }

    function Add-IssueToProject {
        param(
            [string]$Repo,
            [int]$IssueNumber,
            [string]$Owner,
            [string]$ProjectUrl,
            [string]$ProjectOwner,
            [int]$ProjectNumber
        )
        $issueUrl = "https://github.com/$Repo/issues/$IssueNumber"

        if ($ProjectUrl) {
            Run "gh project item-add --url `"$ProjectUrl`" --owner `"$Owner`" --url `"$issueUrl`""
        }
        elseif ($ProjectOwner -and $ProjectNumber) {
            Run "gh project item-add --owner `"$ProjectOwner`" --number $ProjectNumber --url `"$issueUrl`""
        }
        else {
            Write-Host 'No project info provided. Skipping project add.'
        }
    }

    function Update-LabFileSessionsSection {
        param(
            [string]$LabFile,
            [string]$Stamp,
            [string]$Branch,
            [int]$SessionNumber
        )

        $sessionBlock = @"
<details open>
<summary>Session on $Stamp</summary>

- Issue: #$SessionNumber
- Branch: $Branch

Notes:

</details>

"@

        $content = Get-Content $LabFile -Raw

        if ($content -match '(^|\r?\n)##\s+Sessions') {
            # Split at the Sessions header (preserve everything after)
            $parts = $content -split '(^|\r?\n)##\s+Sessions', 2, 'IgnoreCase'
            if ($parts.Count -eq 2) {
                $prefix = $parts[0]
                $sessionsHeaderAndRest = ($content -substring $prefix.Length)
                # Close any existing open detail blocks
                $sessionsHeaderAndRest = ($sessionsHeaderAndRest -replace '<details\s+open>', '<details>')
                # Insert new open block immediately after '## Sessions'
                $sessionsHeaderAndRest = $sessionsHeaderAndRest -replace '(^|\r?\n)(##\s+Sessions\s*\r?\n+)', "`$1`$2$sessionBlock", 1
                $content = $prefix + $sessionsHeaderAndRest
            }
            else {
                $content = $content + "`r`n## Sessions`r`n$sessionBlock"
            }
        }
        else {
            $content = $content + "`r`n## Sessions`r`n$sessionBlock"
        }

        Set-Content $LabFile $content
    }

    function Commit-And-Push {
        param(
            [string]$LabFile,
            [string]$Slug,
            [string]$Stamp,
            [int]$SessionNumber
        )
        Run "git add `"$LabFile`""
        Run "git commit -m `"docs(session): $Slug @ $Stamp (#$SessionNumber)`""
        Run 'git push'
    }

    function Show-Summary {
        param(
            [int]$SessionNumber,
            [int]$LabIssue,
            [string]$LabFile
        )
        Write-Host "`n✅ Session created and recorded:"
        Write-Host "  - Issue:    #$SessionNumber (added to project if configured)"
        Write-Host "  - Lab:      #$LabIssue"
        Write-Host "  - File:     $LabFile (new block is <details open>)"
    }
}

& $Main
