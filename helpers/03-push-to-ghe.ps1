#!/usr/bin/env pwsh
param(
  [Parameter(Mandatory = $true)]
  [string]$OutDir,                          # same OutDir as script 01

  [Parameter(Mandatory = $true)]
  [string]$TargetHost,                      # e.g. ghe.company.com

  [Parameter(Mandatory = $true)]
  [string]$TargetOrg,                       # e.g. test-org

  # Visibility of created repos: 'public' (github.com), 'internal' (GHES), or 'private'.
  [string]$Visibility = 'internal'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"


function Test-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Get-SourceIsTemplate([string]$sourceNwo) {
  # sourceNwo = owner/repo on github.com
  $token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } elseif ($env:GH_TOKEN) { $env:GH_TOKEN } else { $null }
  if (-not $token) { return $false }
  try {
    $meta = Invoke-RestMethod -Uri "https://api.github.com/repos/$sourceNwo" -Headers @{
      Authorization = "token $token"
      Accept        = "application/vnd.github+json"
    }
    return [bool]$meta.is_template
  } catch {
    return $false
  }
}

function Ensure-TargetRepo([string]$targetHost, [string]$targetOrg, [string]$repoName, [string]$visibility, [bool]$isTemplate) {
  $token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } elseif ($env:GH_TOKEN) { $env:GH_TOKEN } else { $null }
  if (-not $token) {
    throw "Set GITHUB_TOKEN or GH_TOKEN with repo creation rights on $targetHost"
  }

  $apiBase  = if ($targetHost -eq 'github.com') { 'https://api.github.com' } else { "https://$targetHost/api/v3" }
  $headers  = @{ Authorization = "token $token"; Accept = "application/vnd.github+json" }

  # Create if not exists (422 = already exists, that's fine)
  try {
    Invoke-RestMethod -Method Post -Uri "$apiBase/orgs/$targetOrg/repos" `
      -Headers $headers `
      -Body (@{ name = $repoName; visibility = $visibility } | ConvertTo-Json -Compress) `
      -ContentType "application/json" | Out-Null
    Write-Host "  Created ($visibility): $targetOrg/$repoName"
  } catch {
    $status = $_.Exception.Response.StatusCode.value__
    if ($status -ne 422) {
      Write-Warning "Could not create repo $targetOrg/$repoName (HTTP $status): $_"
    }
  }

  # Always patch visibility and template flag to match source
  try {
    Invoke-RestMethod -Method Patch -Uri "$apiBase/repos/$targetOrg/$repoName" `
      -Headers $headers `
      -Body (@{ visibility = $visibility; is_template = $isTemplate } | ConvertTo-Json -Compress) `
      -ContentType "application/json" | Out-Null
    Write-Host "  Visibility: '$visibility', template: $isTemplate — $targetOrg/$repoName"
  } catch {
    Write-Warning "Could not update settings for $targetOrg/$repoName : $_"
  }
}

Test-Command git

$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$reposFile = Join-Path $OutDir "repos.txt"
$clonesDir = Join-Path $OutDir "clones"

if (-not (Test-Path $reposFile)) { throw "repos.txt not found: $reposFile" }

$repos = Get-Content -LiteralPath $reposFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

foreach ($repo in $repos) {
  $repoName = ($repo -split '/')[1]
  $localPath = Join-Path $clonesDir ($repo -replace '/', '__')
  if (-not (Test-Path (Join-Path $localPath ".git"))) {
    Write-Warning "Missing local clone, skipping: $repo"
    continue
  }

  $targetUrl  = "https://$TargetHost/$TargetOrg/$repoName.git"
  $isTemplate = Get-SourceIsTemplate -sourceNwo $repo
  Write-Host "==> $repo -> $targetUrl (template: $isTemplate)"

  Ensure-TargetRepo -targetHost $TargetHost -targetOrg $TargetOrg -repoName $repoName -visibility $Visibility -isTemplate $isTemplate

  Push-Location $localPath
  try { git remote remove target 2>$null | Out-Null } catch {}
  git remote add target $targetUrl
  git push --mirror target
  Pop-Location
}

Write-Host "Push complete."