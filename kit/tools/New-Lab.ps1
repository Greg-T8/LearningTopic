[CmdletBinding()]
param(
    [string]$LabName,
    [int]$ExistingIssueNumber,
    [string]$Repo,

    # Project targeting: EITHER supply ProjectUrl OR (ProjectOwner + ProjectNumber)
    [string]$ProjectUrl,
    [string]$ProjectOwner,
    [int]$ProjectNumber = 2,

    [string]$LabTemplatePath = 'templates/labs/lab_template.md',
    [string]$PrTemplateFile  = 'pull_request_template_full.md'
)

$Main = {
    . $Helpers

    if (-not $LabName) { $LabName = Read-Host 'Lab name' }

    $repo    = Get-Repo -Repo $Repo
    $owner   = $repo.Split('/')[0]
    $slug    = Slugify $LabName
    $context = New-LabContext -Repo $repo -Owner $owner -Slug $slug

    $issue  = Ensure-LabIssue -Repo $repo -LabName $LabName -LabFile $context.LabFile -ExistingIssueNumber $ExistingIssueNumber
    Add-IssueToProject -Repo $repo -IssueNumber $issue -Owner $owner -ProjectUrl $ProjectUrl -ProjectNumber $ProjectNumber

    Initialize-LabFiles -TemplatePath $LabTemplatePath -LabDir $context.LabDir -LabFile $context.LabFile -Day $day -IssueNumber $issue
    Create-LabBranchAndCommit -Branch $context.Branch -LabFile $context.LabFile -LabName $LabName -IssueNumber $issue
    Open-LabPR -Repo $repo -PrTemplateFile $PrTemplateFile -PrTitle "[Lab] $LabName" -IssueNumber $issue -LabFile $context.LabFile

    Show-LabSummary -IssueNumber $issue -ProjectUrl $ProjectUrl -Branch $context.Branch -LabFile $context.LabFile
}

$Helpers = {
    function Fail($msg) { Write-Error $msg; exit 1 }
    function Run($cmd) { Write-Host ">> $cmd" -ForegroundColor Cyan; Invoke-Expression $cmd }

    function Get-Repo {
        param([string]$Repo)
        if ($Repo) { return $Repo }
        $url = (git remote get-url origin) 2>$null
        if (-not $url) { Fail 'Cannot infer repo. Provide -Repo owner/repo.' }
        if ($url -match '[:/]([^/]+/[^/\.]+)(\.git)?$') { return $Matches[1] }
        Fail "Failed to parse owner/repo from origin URL '$url'"
    }

    function Slugify([string]$s) {
        $t = $s.Trim().ToLower()
        $t = $t -replace '[^a-z0-9\- ]', ''
        $t = $t -replace '\s+', '-'
        $t = $t -replace '\-+', '-'
        return $t.Trim('-')
    }

    function Today() { (Get-Date).ToString($script:DateFormat) }

    function New-LabContext {
        param(
            [Parameter(Mandatory)] [string]$Repo,
            [Parameter(Mandatory)] [string]$Owner,
            [Parameter(Mandatory)] [string]$Slug
        )

        # Compute next 2-digit index under "labs"
        $labsRoot = 'labs'
        if (-not (Test-Path -Path $LabsRoot -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $LabsRoot | Out-Null
        }

        $existingIndexes = Get-ChildItem -Path $LabsRoot -Directory |
            ForEach-Object {
                if ($_.Name -match '^(?<n>\d{2})-') { [int]$Matches['n'] }
            }

        $nextIndex = if ($existingIndexes) { ($existingIndexes | Measure-Object -Maximum).Maximum + 1 } else { 1 }
        $indexStr  = '{0:D2}' -f $nextIndex

        # Use index in both folder and branch
        $branch = "lab/$indexStr-$Slug"

        $labDir  = Join-Path -Path $labsRoot -ChildPath "$indexStr-$Slug"
        $labFile = Join-Path -Path $labDir  -ChildPath "$Slug.md"

        [pscustomobject]@{
            Repo    = $Repo
            Owner   = $Owner
            Branch  = $branch
            LabDir  = $labDir
            LabFile = $labFile
        }
    }

    function Add-IssueToProject {
        param(
            [Parameter(Mandatory)] [string]$Repo,
            [Parameter(Mandatory)] [int]$IssueNumber,
            [Parameter(Mandatory)] [string]$Owner,
            [string]$ProjectUrl,
            [int]$ProjectNumber
        )
        $issueUrl = "https://github.com/$Repo/issues/$IssueNumber"
        if ($ProjectUrl) {
            Run "gh project item-add --url `"$ProjectUrl`" --owner `"$Owner`" --url `"$issueUrl`""
        }
        elseif ($Owner -and $ProjectNumber) {
            Run "gh project item-add --owner `"$Owner`" --number $ProjectNumber --url `"$issueUrl`""
        }
        else {
            Write-Host 'No project info provided. Skipping project add.'
        }
    }

    function Ensure-LabIssue {
        param(
            [Parameter(Mandatory)] [string]$Repo,
            [Parameter(Mandatory)] [string]$LabName,
            [Parameter(Mandatory)] [string]$LabFile,
            [int]$ExistingIssueNumber
        )
        if ($ExistingIssueNumber) {
            Write-Host "Using existing issue #$ExistingIssueNumber"
            return $ExistingIssueNumber
        }

        $body = @'
**Objective**
Briefly describe the learning objective.

**Definition of Done**
- [ ] Lab notes committed in `$labFile`
- [ ] Learning outcomes captured
- [ ] PR merged

**Links**
- (add resources)
'@

        $createIssueCmd = "gh issue create -R $Repo --title `"$LabName`" --body @'`n$body`n'@ --label `"type: lab`" --label `"status: planned`""
        $issueUrlOut = (Run $createIssueCmd | Select-Object -Last 1)
        if ($issueUrlOut -notmatch '/issues/(\d+)$') { Fail "Could not parse created issue number from: $issueUrlOut" }
        return [int]$Matches[1]
    }

    function Initialize-LabFiles {
        param(
            [Parameter(Mandatory)] [string]$TemplatePath,
            [Parameter(Mandatory)] [string]$LabDir,
            [Parameter(Mandatory)] [string]$LabFile,
            [Parameter(Mandatory)] [string]$Day,
            [Parameter(Mandatory)] [int]$IssueNumber
        )
        if (-not (Test-Path $TemplatePath)) { Fail "Template not found: $TemplatePath" }
        New-Item -ItemType Directory -Force -Path $LabDir | Out-Null
        (Get-Content $TemplatePath) `
            -replace '\*\*Date:\*\*.*', "**Date:** $Day" `
            -replace '\*\*Linked Issue/PR:\*\*.*', "**Linked Issue/PR:** #$IssueNumber" `
      | Set-Content $LabFile -NoNewline
        Add-Content $LabFile "`r`n`r`n## Sessions`r`n"
    }

    function Create-LabBranchAndCommit {
        param(
            [Parameter(Mandatory)] [string]$Branch,
            [Parameter(Mandatory)] [string]$LabFile,
            [Parameter(Mandatory)] [string]$LabName,
            [Parameter(Mandatory)] [int]$IssueNumber
        )
        Run "git checkout -b `"$Branch`""
        Run "git add `"$LabFile`""
        Run "git commit -m `"chore(lab): scaffold $LabName (#$IssueNumber)`""
        Run "git push -u origin `"$Branch`""
    }

    function Open-LabPR {
        param(
            [Parameter(Mandatory)] [string]$Repo,
            [Parameter(Mandatory)] [string]$PrTemplateFile,
            [Parameter(Mandatory)] [string]$PrTitle,
            [Parameter(Mandatory)] [int]$IssueNumber,
            [Parameter(Mandatory)] [string]$LabFile
        )
        $prBody = @"
Closes #$IssueNumber

This PR scaffolds the lab and initial notes under \`$LabFile\`.
"@
        Run "gh pr create -R $Repo --title `"$PrTitle`" --body @'$prBody'@ --draft --fill --template `"$PrTemplateFile`""
    }

    function Show-LabSummary {
        param(
            [Parameter(Mandatory)] [int]$IssueNumber,
            [string]$ProjectUrl,
            [Parameter(Mandatory)] [string]$Branch,
            [Parameter(Mandatory)] [string]$LabFile
        )
        Write-Host "`n✅ Lab ready:"
        Write-Host ('  - Issue:       #{0}' -f $IssueNumber)
        Write-Host ('  - Project:     {0}' -f ($(if ($ProjectUrl) { $ProjectUrl }else { '(skipped)' })))
        Write-Host ('  - Branch:      {0}  (you are here)' -f $Branch)
        Write-Host ('  - File:        {0}' -f $LabFile)
    }
}

& $Main
