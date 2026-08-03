#!/usr/bin/env pwsh
param(
  [Parameter(Mandatory = $true)]
  [string]$SourceUrl,                    # e.g. https://github.com/skills/exercise-toolkit

  [string]$OutDir = "./exercise-toolkit-mirror",

  # Owners whose repos are bundled with GHES and do not need to be mirrored.
  # Everything else — including third-party orgs — will be cloned.
  [string[]]$BundledOwners = @('actions')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Parse-HostFromUrl([string]$url) {
  return ([Uri]$url).Host
}

function Parse-RepoNwoFromUrl([string]$url) {
  if ($url -notmatch '^https?://[^/]+/([^/]+)/([^/]+?)(?:\.git)?/?$') {
    throw "Cannot parse owner/repo from SourceUrl: $url"
  }
  return "$($Matches[1])/$($Matches[2])"
}

function Repo-ToDir([string]$clonesDir, [string]$repo) {
  return Join-Path $clonesDir ($repo -replace '/', '__')
}

function Clone-IfNeeded(
  [string]$sourceHost,
  [string]$repo,
  [string]$clonesDir,
  [System.Collections.Generic.HashSet[string]]$reposSet
) {
  $dir = Repo-ToDir -clonesDir $clonesDir -repo $repo
  if (Test-Path (Join-Path $dir ".git")) { return $true }

  $url = "https://$sourceHost/$repo.git"
  Write-Host "  Cloning $url"
  try {
    git clone --quiet $url $dir | Out-Null
    [void]$reposSet.Add($repo)
    return $true
  } catch {
    Write-Warning "Failed to clone $url (skipping). $_"
    return $false
  }
}

# Resolve the actual absolute paths to scan for a repo.
#   $scanRelPaths = $null   -> root-repo mode: scan all workflows + action definitions
#   $scanRelPaths = @(...)  -> dependency mode: scan only the specific files that are invoked
function Resolve-FilesToScan([string]$repoDir, $scanRelPaths) {
  if ($null -eq $scanRelPaths) {
    # Root repo — scan everything that could invoke external actions
    $files = @()
    $wfDir = Join-Path $repoDir ".github/workflows"
    if (Test-Path $wfDir) {
      $files += Get-ChildItem -Path $wfDir -Recurse -File -Include *.yml,*.yaml |
                Select-Object -ExpandProperty FullName
    }
    $files += Get-ChildItem -Path $repoDir -Recurse -File -Include action.yml,action.yaml |
              Select-Object -ExpandProperty FullName
    return $files
  }

  # Dependency repo — only scan the files we know are actually invoked
  $files = @()
  foreach ($rel in $scanRelPaths) {
    # For action.yml, also try action.yaml
    $candidates = if ($rel -eq 'action.yml') { @('action.yml', 'action.yaml') } else { @($rel) }
    foreach ($c in $candidates) {
      $abs = Join-Path $repoDir $c
      if (Test-Path $abs) { $files += $abs; break }
    }
  }
  return $files
}

# Extract external uses: references from a single YAML file.
# Returns objects with: Repo, Ref, Raw, ScanFile
#   ScanFile — the relative path to scan in the dependency repo:
#     action reference  (owner/repo@ref)                            -> 'action.yml'
#     reusable workflow (owner/repo/.github/workflows/file.yml@ref) -> '.github/workflows/file.yml'
function Extract-ExternalActionsFromYaml([string]$yamlFile) {
  $results = New-Object System.Collections.Generic.List[object]
  $lines   = Get-Content -LiteralPath $yamlFile -ErrorAction SilentlyContinue

  foreach ($line in $lines) {
    if ($line -notmatch '^\s*uses\s*:\s*["'']?([^"'']+)["'']?\s*$') { continue }

    $u = $Matches[1].Trim()
    if ([string]::IsNullOrWhiteSpace($u)) { continue }
    if ($u.StartsWith("./"))        { continue }   # local composite action
    if ($u.StartsWith("docker://")) { continue }   # Docker action
    if (-not $u.Contains("@"))      { continue }   # no pinned ref

    $parts     = $u.Split("@", 2)
    $left      = $parts[0]
    $ref       = $parts[1]

    if ($left -notmatch '^[^/]+/[^/]+') { continue }

    $segments  = $left.Split("/")
    $ownerRepo = "$($segments[0])/$($segments[1])"

    # Reusable workflow: owner/repo/.github/workflows/file.yml@ref  -> scan that specific file
    # Composite/Docker action: owner/repo@ref                        -> scan action.yml
    $scanFile  = if ($left -match '^[^/]+/[^/]+/(.+)$') { $Matches[1] } else { 'action.yml' }

    $results.Add([pscustomobject]@{
      Repo     = $ownerRepo
      Ref      = $ref
      Raw      = $u
      ScanFile = $scanFile
    })
  }

  return $results
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Test-Command git

$sourceHost = Parse-HostFromUrl $SourceUrl
$rootRepo   = Parse-RepoNwoFromUrl $SourceUrl

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir    = (Resolve-Path -LiteralPath $OutDir).Path
$clonesDir = Join-Path $OutDir "clones"

# Always start clean — remove any previous clones to avoid scanning rewritten files
if (Test-Path $clonesDir) {
  Write-Host "Cleaning previous clones in $clonesDir..."
  Remove-Item -Recurse -Force $clonesDir
}
New-Item -ItemType Directory -Force -Path $clonesDir | Out-Null

$reposFile    = Join-Path $OutDir "repos.txt"
$cloneMapFile = Join-Path $OutDir "clone-map.csv"
$refsFile     = Join-Path $OutDir "refs-by-repo.csv"

$bundledSet = [System.Collections.Generic.HashSet[string]]::new(
  [string[]]$BundledOwners,
  [System.StringComparer]::OrdinalIgnoreCase
)

$repos     = New-Object System.Collections.Generic.HashSet[string]

# ---------------------------------------------------------------------------
# First run: BFS discovery
# ---------------------------------------------------------------------------
$toScan    = @{ $rootRepo = $null }
$processed = New-Object System.Collections.Generic.HashSet[string]
$refsMap   = @{}

$queue = New-Object System.Collections.Generic.Queue[string]
$queue.Enqueue($rootRepo)

Write-Host "Discovering dependencies from $rootRepo..."
Write-Host "Skipping bundled owners: $($BundledOwners -join ', ')"
Write-Host ""

while ($queue.Count -gt 0) {
  $nextRepo = $queue.Dequeue()
  if ($processed.Contains($nextRepo)) { continue }
  [void]$processed.Add($nextRepo)

  # Skip repos bundled with GHES
  $repoOwner = $nextRepo.Split('/')[0]
  if ($bundledSet.Contains($repoOwner)) {
    Write-Host "  [bundled]  $nextRepo"
    continue
  }

  $ok = Clone-IfNeeded -sourceHost $sourceHost -repo $nextRepo -clonesDir $clonesDir -reposSet $repos
  if (-not $ok) { continue }

  $repoDir   = Repo-ToDir -clonesDir $clonesDir -repo $nextRepo
  $scanPaths = $toScan[$nextRepo]
  $yamlFiles = @(Resolve-FilesToScan -repoDir $repoDir -scanRelPaths $scanPaths)

  if ($yamlFiles.Count -eq 0) {
    Write-Host "  [no files] $nextRepo"
    continue
  }

  $label = if ($null -eq $scanPaths) { 'all workflows' } else { $scanPaths -join ', ' }
  Write-Host "  [scan: $label] $nextRepo"

  foreach ($yf in $yamlFiles) {
    $deps = Extract-ExternalActionsFromYaml -yamlFile $yf
    foreach ($d in $deps) {
      if (-not $refsMap.ContainsKey($nextRepo)) {
        $refsMap[$nextRepo] = New-Object System.Collections.Generic.HashSet[string]
      }
      [void]$refsMap[$nextRepo].Add("$($d.Repo)@$($d.Ref)")

      if ($processed.Contains($d.Repo)) { continue }

      if (-not $toScan.ContainsKey($d.Repo)) {
        # First time seeing this repo: register the specific file to scan and enqueue
        $toScan[$d.Repo] = [System.Collections.Generic.List[string]]@($d.ScanFile)
        $queue.Enqueue($d.Repo)
      } else {
        # Already queued: add the new file if not already tracked
        $existing = $toScan[$d.Repo]
        if ($null -ne $existing -and -not $existing.Contains($d.ScanFile)) {
          $existing.Add($d.ScanFile)
        }
      }
    }
  }
}

$reposSorted = $repos | Sort-Object
$reposSorted | Set-Content -LiteralPath $reposFile -Encoding UTF8

"repo,refs_seen" | Set-Content -LiteralPath $refsFile -Encoding UTF8
foreach ($r in ($processed | Sort-Object)) {
  $refsSeen = if ($refsMap.ContainsKey($r)) { ($refsMap[$r] | Sort-Object) -join ";" } else { "" }
  Add-Content -LiteralPath $refsFile -Encoding UTF8 -Value ('"{0}","{1}"' -f $r, ($refsSeen -replace '"', '""'))
}

"source_url,local_path" | Set-Content -LiteralPath $cloneMapFile -Encoding UTF8
foreach ($r in $reposSorted) {
  $src = "https://$sourceHost/$r.git"
  $lp  = Repo-ToDir -clonesDir $clonesDir -repo $r
  Add-Content -LiteralPath $cloneMapFile -Encoding UTF8 -Value ('"{0}","{1}"' -f $src, $lp)
}

Write-Host ""
Write-Host "Done."
Write-Host "Repos cloned:     $($reposSorted.Count)"
Write-Host "repos.txt:        $reposFile"
Write-Host "refs-by-repo.csv: $refsFile"
Write-Host "clone-map.csv:    $cloneMapFile"
Write-Host "Root local path:  $(Repo-ToDir -clonesDir $clonesDir -repo $rootRepo)"