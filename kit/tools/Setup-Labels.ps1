# -------------------------------
# Detect current repo
# -------------------------------
try {
    $Repo = gh repo view --json nameWithOwner --jq ".nameWithOwner"
    if (-not $Repo) { throw "Not inside a GitHub repo directory or gh not authenticated." }
    Write-Host "Running Setup-Labels in repo: $Repo"
} catch {
    Write-Error $_
    exit 1
}

# -------------------------------
# Config Section
# -------------------------------
# Labels you want to remove (GitHub defaults)
$DefaultLabelsToRemove = @(
    "bug",
    "documentation",
    "duplicate",
    "enhancement",
    "good first issue",
    "help wanted",
    "invalid",
    "question",
    "wontfix"
)

# Labels you want to keep in this repo (will be created or updated)
$LabelsToEnsure = @(
    @{ Name = "type: session";       Color = "1f77b4"; Description = "Individual study session" },
    @{ Name = "type: lab";           Color = "ff7f0e"; Description = "Hands-on lab work" },
    @{ Name = "status: planned";     Color = "2ca02c"; Description = "Planned but not started" },
    @{ Name = "status: in-progress"; Color = "d62728"; Description = "Currently being worked on" },
    @{ Name = "status: complete";    Color = "9467bd"; Description = "Work finished" }
)

# -------------------------------
# Fetch existing labels once
# -------------------------------
$existing = @()
try {
    $existing = gh label list --repo $Repo --json name,color,description | ConvertFrom-Json
} catch {
    Write-Error "Failed to list labels for $Repo. $_"
    exit 1
}
$existingNames = $existing.name

# -------------------------------
# Remove default GitHub labels
# -------------------------------
foreach ($labelName in $DefaultLabelsToRemove) {
    if ($existingNames -contains $labelName) {
        Write-Host "Removing default label: '$labelName'"
        try {
            gh label delete "$labelName" --repo $Repo --yes | Out-Null
        } catch {
            Write-Warning "Could not remove label '$labelName': $_"
        }
    } else {
        Write-Host "Default label not present (skip): '$labelName'"
    }
}

# Refresh existing label list after removals
try {
    $existing = gh label list --repo $Repo --json name,color,description | ConvertFrom-Json
} catch {
    Write-Error "Failed to refresh labels for $Repo. $_"
    exit 1
}
$existingNames = $existing.name

# -------------------------------
# Ensure configured labels exist (create or update)
# -------------------------------
foreach ($label in $LabelsToEnsure) {
    $name  = $label.Name
    $color = $label.Color
    $desc  = $label.Description

    if ($existingNames -contains $name) {
        # Update color/description to match config
        Write-Host "Updating label: '$name'"
        try {
            gh label edit "$name" --repo $Repo --color $color --description "$desc" | Out-Null
        } catch {
            Write-Warning "Could not update label '$name': $_"
        }
    } else {
        # Create new label
        Write-Host "Creating label: '$name'"
        try {
            gh label create "$name" --repo $Repo --color $color --description "$desc" | Out-Null
        } catch {
            Write-Warning "Could not create label '$name': $_"
        }
    }
}

Write-Host "Label setup complete for $Repo."
