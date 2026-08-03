#!/usr/bin/env pwsh
#
# clone-repository.ps1
#
# Wraps the three migration scripts end-to-end:
#   1. Clone the source repo and its full GitHub Actions dependency graph
#   2. Rewrite all `uses:` owner references to the target org and commit
#   3. Push every cloned repo to the target GHE instance
#
# Usage:
#   ./clone-repository.ps1 `
#     -SourceUrl  https://github.com/skills/exercise-toolkit `
#     -TargetHost ghe.company.com `
#     -TargetOrg  my-org
#
# Optional:
#   -OutDir       ./skills-mirror   (working directory for clones + manifests)
#   -Visibility     internal         (internal/private/public — default: internal)
#   -NewOwner     my-org            (defaults to TargetOrg)
#
# Prerequisites:
#   - git must be in PATH
#   - GITHUB_TOKEN or GH_TOKEN must be set with repo-creation rights on TargetHost
#

param(
  [Parameter(Mandatory = $true)]
  [string]$SourceUrl,

  [Parameter(Mandatory = $true)]
  [string]$TargetHost,

  [Parameter(Mandatory = $true)]
  [string]$TargetOrg,

  [string]$OutDir = "./tmp-gh-mirror",
  # Visibility of created repos. Defaults to 'public' for github.com and
  # 'internal' for GitHub Enterprise Server (accessible to all enterprise members).
  # Override with 'private' if needed.
  [string]$Visibility = "",
  [string]$NewOwner = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptsDir = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($NewOwner)) {
  $NewOwner = $TargetOrg
}

if ([string]::IsNullOrWhiteSpace($Visibility)) {
  $Visibility = if ($TargetHost -eq 'github.com') { 'public' } else { 'internal' }
}
Write-Host "Repo visibility: $Visibility"

$OutDir = (New-Item -ItemType Directory -Force -Path $OutDir).FullName

# ---------------------------------------------------------------------------
# Step 1 — Clone source repo and all transitive action dependencies
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Step 1: Cloning dependency graph from $SourceUrl ==="
& "$ScriptsDir/helpers/01-clone-dependency-graph.ps1" -SourceUrl $SourceUrl -OutDir $OutDir

# ---------------------------------------------------------------------------
# Step 2 — Rewrite uses: owners in every cloned repo and commit the changes
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Step 2: Rewriting uses: references to '$NewOwner' ==="

$reposFile = Join-Path $OutDir "repos.txt"
$clonesDir = Join-Path $OutDir "clones"

$repos = Get-Content -LiteralPath $reposFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

foreach ($repo in $repos) {
  $repoDir = Join-Path $clonesDir ($repo -replace '/', '__')
  if (-not (Test-Path (Join-Path $repoDir ".git"))) {
    Write-Warning "Missing local clone, skipping rewrite: $repo"
    continue
  }

  $oldOwner = $repo.Split('/')[0]

  & "$ScriptsDir/helpers/02-rewrite-uses-owner.ps1" -RepoPath $repoDir -NewOwner $NewOwner -OldOwner $oldOwner -MirroredRepos $repos

  # Commit only if the rewrite changed anything
  Push-Location $repoDir
  try {
    $dirty = git status --porcelain
    if ($dirty) {
      git add -A
      git commit -m "chore: rewrite uses: references to $NewOwner"
      Write-Host "  Committed rewrites in $repo"
    }
  } finally {
    Pop-Location
  }
}

# ---------------------------------------------------------------------------
# Step 3 — Push all repos to the target GHE instance
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Step 3: Pushing to https://$TargetHost/$TargetOrg ==="
& "$ScriptsDir/helpers/03-push-to-ghe.ps1" `
  -OutDir $OutDir `
  -TargetHost $TargetHost `
  -TargetOrg $TargetOrg `
  -Visibility $Visibility

Write-Host ""
Write-Host "=== Migration complete ==="
Write-Host "Source : $SourceUrl"
Write-Host "Target : https://$TargetHost/$TargetOrg"
Write-Host "OutDir : $OutDir"
