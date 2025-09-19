<#
.SYNOPSIS
  Scaffolds or continues a lab by topic (no dates). Creates/uses labs/<slug>.md and a lab/<slug> branch.

.EXAMPLE
  ./New-Lab.ps1 -Title "Azure Firewall DNAT" -Push -OpenPR

.EXAMPLE
  ./New-Lab.ps1 -Title "Kubernetes HAProxy Load Balancer"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Title,

    [string]$Slug,

    # Repo root (where .git lives). Defaults to current directory.
    [string]$RepoRoot = ".",

    # If set, push the branch when a new file is created (or always if -AlwaysPush)
    [switch]$Push,

    # Always push branch (even if file already existed)
    [switch]$AlwaysPush,

    # If set, attempts to open a PR via gh CLI
    [switch]$OpenPR
)

function Ensure-Git() {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git is required but not found in PATH."
    }
}

function Ensure-Gh() {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warning "gh (GitHub CLI) not found. Skipping PR creation."
        return $false
    }
    return $true
}

function Resolve-RepoRoot($root) {
    $full = Resolve-Path -Path $root
    if (-not (Test-Path (Join-Path $full '.git'))) {
        throw "No .git folder found at '$full'. Set -RepoRoot to your repo root."
    }
    return $full
}

function New-Slug([string]$text) {
    $s = $text.Trim().ToLowerInvariant()
    $s = $s -replace "[^a-z0-9]+","-"
    $s = $s.Trim("-")
    if ([string]::IsNullOrWhiteSpace($s)) {
        throw "Unable to derive a slug from title '$text'."
    }
    return $s
}

function Get-TemplateContent($repoRoot) {
    $templatePath = Join-Path $repoRoot "templates/labs/lab_template.md"
    if (Test-Path $templatePath) {
        return Get-Content -Path $templatePath -Raw
    }

@"
---
title: "{{TITLE}}"
tags: []
status: "draft"
---

# {{TITLE}}

## Objective
<!-- What are we trying to learn/build? -->

## Prerequisites
<!-- Links, prior labs, environment notes -->

## Steps
1.

## Findings / Notes


## Next
-

"@
}

try {
    Ensure-Git
    $repo = Resolve-RepoRoot $RepoRoot

    if (-not $Slug) { $Slug = New-Slug $Title }

    $labsDir   = Join-Path $repo "labs"
    $labFile   = Join-Path $labsDir "$Slug.md"
    $branch    = "lab/$Slug"

    if (-not (Test-Path $labsDir)) { New-Item -ItemType Directory -Path $labsDir | Out-Null }

    Push-Location $repo
    try {
        # Sync main and create/switch branch
        git fetch --all --prune | Out-Null
        git checkout main | Out-Null
        git pull --ff-only | Out-Null

        $branchExists = (& git branch --list $branch) -ne $null
        if ($branchExists) {
            git switch $branch | Out-Null
            Write-Host "Switched to existing branch '$branch'."
        } else {
            git switch -c $branch | Out-Null
            Write-Host "Created and switched to branch '$branch'."
        }

        $created = $false
        if (-not (Test-Path $labFile)) {
            $tpl = Get-TemplateContent $repo
            $content = $tpl.Replace("{{TITLE}}", $Title)
            Set-Content -Path $labFile -Value $content -NoNewline
            git add $labFile | Out-Null
            git commit -m "Lab: initialize '$Title' ($Slug)" | Out-Null
            $created = $true
            Write-Host "Created new lab file: $($labFile.Substring($repo.Length+1))"
        } else {
            Write-Host "Lab file already exists: $($labFile.Substring($repo.Length+1))"
        }

        if ($AlwaysPush -or ($Push -and $created)) {
            # Ensure upstream
            git push -u origin $branch | Out-Null
            Write-Host "Pushed branch '$branch' to origin."
        }

        if ($OpenPR) {
            if (Ensure-Gh) {
                # Create a draft PR if one doesn't exist
                $existingPr = (gh pr list --head $branch --json number --jq '.[0].number' 2>$null)
                if ($existingPr) {
                    Write-Host "PR already exists: #$existingPr"
                } else {
                    $prTitle = "Lab: $Title"
                    $body = @"
This PR tracks work on the **$Title** lab.

- Lab file: \`labs/$Slug.md\`
- Branch: \`$branch\`

> Note: Sessions (dated) should reference and update this lab as needed.
"@
                    gh pr create --title "$prTitle" --body "$body" --base main --head $branch --draft | Out-Null
                    Write-Host "Opened draft PR: $prTitle"
                }
            }
        }

        Write-Host ""
        Write-Host "Next steps:"
        Write-Host "  - Edit: labs/$Slug.md"
        Write-Host "  - Commit changes on branch: $branch"
        Write-Host "  - Open/convert PR when ready (draft PR recommended while iterating)."
    }
    finally {
        Pop-Location
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
