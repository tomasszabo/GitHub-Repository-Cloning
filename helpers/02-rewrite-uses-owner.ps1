#!/usr/bin/env pwsh
param(
  [Parameter(Mandatory = $true)]
  [string]$RepoPath,                        # local path of mirrored repo

  [Parameter(Mandatory = $true)]
  [string]$NewOwner,                        # e.g. sombrerita

  [Parameter(Mandatory = $true)]
  [string]$OldOwner,                        # original owner on the source host (e.g. skills)

  [Parameter(Mandatory = $true)]
  [string[]]$MirroredRepos                  # list of "owner/repo" that were cloned and will be pushed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Build a set of repo names (without owner) that are being mirrored.
# Only uses: references to these repos will have their owner rewritten.
$mirroredRepoNames = [System.Collections.Generic.HashSet[string]]::new(
  [string[]]($MirroredRepos | ForEach-Object { $_.Split('/')[1] }),
  [System.StringComparer]::OrdinalIgnoreCase
)

$changed = 0

# ---------------------------------------------------------------------------
# 1. Rewrite uses: references in workflow YAML and action definition files
# ---------------------------------------------------------------------------
$yamlFiles = @()
$wfDir = Join-Path $RepoPath ".github/workflows"
if (Test-Path $wfDir) {
  $yamlFiles += Get-ChildItem -Path $wfDir -Recurse -File -Include *.yml,*.yaml
}
$yamlFiles += Get-ChildItem -Path $RepoPath -Recurse -File -Include action.yml,action.yaml

foreach ($f in $yamlFiles) {
  $lines   = Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue
  $updated = $lines | ForEach-Object {
    $line = $_
    # Match: uses: owner/repo@ref  or  uses: owner/repo/.github/workflows/file.yml@ref
    if ($line -match '^(\s*uses\s*:\s*["'']?)([^\/\s"'']+)\/([^@\s"''\/]+)(\/[^@\s"'']*)?@([^\s"'']+)(["'']?\s*)$') {
      $prefix   = $Matches[1]
      $owner    = $Matches[2]
      $repoName = $Matches[3]
      $path     = $Matches[4]   # empty for actions, e.g. /.github/workflows/file.yml for reusable workflows
      $ref      = $Matches[5]
      $suffix   = $Matches[6]

      if (-not $line.TrimStart().StartsWith('./') -and
          -not $line.TrimStart().StartsWith('docker://') -and
          $mirroredRepoNames.Contains($repoName)) {

        # Reusable workflow: pin to main (tag may predate the workflow file)
        $newRef = if ($path -and $path.Contains('.github/workflows')) { 'main' } else { $ref }
        $line   = "$prefix$NewOwner/$repoName$path@$newRef$suffix"
      }
    }
    $line
  }

  $newContent = $updated -join "`n"
  $oldContent = $lines -join "`n"

  if ($newContent -ne $oldContent) {
    Set-Content -LiteralPath $f.FullName -Value $newContent -Encoding UTF8
    Write-Host "  [yaml] $($f.FullName)"
    $changed++
  }
}

# ---------------------------------------------------------------------------
# 2. Rewrite GitHub URLs and template links in content files
#    Targets README.md, markdown docs, and any text file that may contain
#    hardcoded links like:
#      https://github.com/skills/repo  ->  https://github.com/sombrerita/repo
#      template_owner=skills           ->  template_owner=sombrerita
# ---------------------------------------------------------------------------
$contentFiles = Get-ChildItem -Path $RepoPath -Recurse -File -Include *.md,*.mdx,*.txt,*.html,*.json,*.yml,*.yaml |
  Where-Object { $_.FullName -notlike '*/.git/*' -and $_.FullName -notlike '*\.git\*' }

foreach ($f in $contentFiles) {
  $content = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
  if ($null -eq $content) { continue }

  $updated = $content `
    -replace "github\.com/$([regex]::Escape($OldOwner))/", "github.com/$NewOwner/" `
    -replace "template_owner=$([regex]::Escape($OldOwner))", "template_owner=$NewOwner"

  if ($updated -ne $content) {
    Set-Content -LiteralPath $f.FullName -Value $updated -Encoding UTF8
    Write-Host "  [content] $($f.FullName)"
    $changed++
  }
}

Write-Host "Files changed: $changed"