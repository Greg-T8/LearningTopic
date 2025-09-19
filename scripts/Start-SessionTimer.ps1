<#
.SYNOPSIS
  Background reminder timer for a learning session (default 60 minutes).

.DESCRIPTION
  - Shows Windows toast notifications at 40, 55, and 60 minutes (configurable via -Minutes).
  - Optionally posts a "time's up" comment to the PR (requires gh CLI).
  - Runs as a Start-Job and returns immediately.

.PARAMETER RepoOwner
  GitHub repo owner, e.g. "Greg-T8".

.PARAMETER RepoName
  GitHub repo name, e.g. "LearningKubernetes".

.PARAMETER PrNumber
  Pull request number to comment on when time is up.

.PARAMETER Minutes
  Session duration in minutes (default 60). Toasts fire at (Minutes-20), (Minutes-5), and Minutes.

.PARAMETER NoGhComment
  Suppress posting a comment to the PR at the end (toast still shown).

.EXAMPLE
  .\scripts\Start-SessionTimer.ps1 -RepoOwner "Greg-T8" -RepoName "LearningAzure" -PrNumber 123
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$RepoOwner,
  [Parameter(Mandatory)][string]$RepoName,
  [Parameter(Mandatory)][int]$PrNumber,
  [int]$Minutes = 60,
  [switch]$NoGhComment
)

# --- helper: safe toast (works even if BurntToast not present) ---
function Send-Toast {
  param([string]$Title, [string]$Message)
  try {
    if (-not (Get-Module -ListAvailable -Name BurntToast)) {
      # Try to import; if missing, just Write-Host fallback
      Import-Module BurntToast -ErrorAction Stop
    } else {
      Import-Module BurntToast -ErrorAction Stop
    }
    New-BurntToastNotification -Text $Title, $Message | Out-Null
  } catch {
    Write-Host "[toast] $Title: $Message"
  }
}

# Normalize schedule points
if ($Minutes -lt 10) { $Minutes = 10 } # sanity guard
$now   = Get-Date
$at40  = $now.AddMinutes([math]::Max($Minutes - 20, 1))
$at55  = $now.AddMinutes([math]::Max($Minutes - 5,  1))
$atEnd = $now.AddMinutes($Minutes)

# Package args for the background job
$jobArgs = @{
  RepoOwner   = $RepoOwner
  RepoName    = $RepoName
  PrNumber    = $PrNumber
  At40        = $at40
  At55        = $at55
  AtEnd       = $atEnd
  NoGhComment = [bool]$NoGhComment
}

# --- background job body ---
$job = Start-Job -ScriptBlock {
  param(
    [string]$RepoOwner,
    [string]$RepoName,
    [int]$PrNumber,
    [datetime]$At40,
    [datetime]$At55,
    [datetime]$AtEnd,
    [bool]$NoGhComment
  )

  function Send-Toast {
    param([string]$Title, [string]$Message)
    try {
      if (-not (Get-Module -ListAvailable -Name BurntToast)) {
        Import-Module BurntToast -ErrorAction Stop
      } else {
        Import-Module BurntToast -ErrorAction Stop
      }
      New-BurntToastNotification -Text $Title, $Message | Out-Null
    } catch {
      Write-Host "[toast] $Title: $Message"
    }
  }

  # Helper to sleep until a timestamp (with small granularity)
  function Wait-Until([datetime]$ts) {
    while ((Get-Date) -lt $ts) {
      $remaining = [int]([TimeSpan]($ts - (Get-Date))).TotalSeconds
      Start-Sleep -Seconds ([math]::Min([math]::Max($remaining,1), 10))
    }
  }

  # 20 minutes remaining
  Wait-Until $At40
  Send-Toast "Session: 20 minutes left" "Wrap the main lab path. Start noting Drills & Evidence."

  # 5 minutes remaining
  Wait-Until $At55
  Send-Toast "Session: 5 minutes left" "Bump outcome (L1→L2→L3→L4), add Next Steps, prep to merge."

  # Time's up
  Wait-Until $AtEnd
  Send-Toast "Time’s up" "Close PR: tick Labs/Drills/Evidence, add What Broke & Next Steps, then merge."

  if (-not $NoGhComment) {
    # Post a gentle nudge on the PR (best-effort)
    try {
      $body = @"
⏱️ **1-hour session complete.**
- Mark final outcome (L1–L4) in the title
- Tick **Labs / Drills / Evidence**
- Add **What Broke / How I Fixed It** + **Next Steps**
- **Merge** this PR to close the session
"@
      & gh api "repos/$RepoOwner/$RepoName/issues/$PrNumber/comments" -f body="$body" | Out-Null
    } catch {
      Write-Host "[timer] Skipped PR comment: $($_.Exception.Message)"
    }
  }
} -ArgumentList $jobArgs.RepoOwner, $jobArgs.RepoName, $jobArgs.PrNumber, $jobArgs.At40, $jobArgs.At55, $jobArgs.AtEnd, $jobArgs.NoGhComment

Write-Host "⏳ Session timer started (job id $($job.Id)). Reminders at $($at40.ToShortTimeString()), $($at55.ToShortTimeString()), and $($atEnd.ToShortTimeString())."
