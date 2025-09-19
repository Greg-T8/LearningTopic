<#
.SYNOPSIS
    Standardize GitHub issue labels across learning repos.

.DESCRIPTION
    This script deletes default labels and recreates a consistent label set
    for the LearningSessions workflow.

    Requirements:
    - GitHub CLI (gh) installed and authenticated
    - Run from the repo root or specify --repo explicitly

.EXAMPLE
    ./Setup-Labels.ps1
#>

# Define label schema
$labels = @(
    @{ name = "session";      color = "1f77b4"; description = "Daily or weekly study session" }
    @{ name = "lab";          color = "ff7f0e"; description = "Hands-on lab, the HOW of learning" }
    @{ name = "blocked";      color = "d62728"; description = "Work blocked by dependency" }
    @{ name = "reading";      color = "9467bd"; description = "Background reading or research" }
    @{ name = "review";       color = "2ca02c"; description = "Ready for review / PR review" }
    @{ name = "done";         color = "17becf"; description = "Completed and merged" }
    @{ name = "meta";         color = "8c564b"; description = "Meta: templates, process, repo hygiene" }
)

Write-Host "Cleaning up default labels..."
$defaultLabels = @("bug", "duplicate", "enhancement", "good first issue", "help wanted", "invalid", "question", "wontfix")
foreach ($dl in $defaultLabels) {
    gh label delete $dl --yes 2>$null
}

Write-Host "Creating standard labels..."
foreach ($label in $labels) {
    $exists = gh label list --json name | ConvertFrom-Json | Where-Object { $_.name -eq $label.name }
    if ($null -eq $exists) {
        gh label create $label.name `
            --color $label.color `
            --description $label.description
        Write-Host "  Created $($label.name)"
    }
    else {
        gh label edit $label.name `
            --color $label.color `
            --description $label.description
        Write-Host "  Updated $($label.name)"
    }
}

Write-Host "✅ Labels setup complete."
