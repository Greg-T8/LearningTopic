<#
.SYNOPSIS
    Creates a new lab in the repo following LearningSessions conventions.

.DESCRIPTION
    - Creates a new branch: lab/YYYY-MM-DD-topic-slug
    - Creates a folder in labs/YYYY-MM-DD-topic-slug
    - Copies lab_template.md into the new folder
    - Stages and commits the new lab
    - Provides next steps for the user

.PARAMETER Topic
    The short slug or description of the lab topic (e.g., rbac-custom-role).

.EXAMPLE
    ./New-Lab.ps1 -Topic "rbac-custom-role"
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$Topic
)

# Ensure git is available
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "Git is not installed or not in PATH."
    exit 1
}

# Format date and slug
$today = Get-Date -Format "yyyy-MM-dd"
$slug  = $Topic.ToLower().Replace(" ", "-")
$branch = "lab/$today-$slug"
$folder = "labs/$today-$slug"

# Check if folder already exists
if (Test-Path $folder) {
    Write-Error "Folder $folder already exists. Choose a different topic or delete the existing one."
    exit 1
}

# Create branch
git checkout -b $branch

# Create folder and copy template
New-Item -ItemType Directory -Path $folder | Out-Null

$template = "lab_template.md"
$target   = Join-Path $folder "README.md"

if (-not (Test-Path $template)) {
    Write-Error "Template file $template not found."
    exit 1
}

Copy-Item $template $target

# Stage and commit
git add $folder
git commit -m "Lab: Initialize $slug ($today)"

Write-Host "✅ New lab created:"
Write-Host "   Branch: $branch"
Write-Host "   Folder: $folder"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Open $target and edit the lab content."
Write-Host "  2. Push your branch: git push -u origin $branch"
Write-Host "  3. Open a Pull Request when the lab is ready."
