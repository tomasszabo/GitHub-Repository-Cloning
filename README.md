# GitHub Repository Cloning

Migrates one or more GitHub repositories and their full transitive [GitHub Actions](https://docs.github.com/en/actions) dependency graphs to a GitHub Enterprise (GHE) instance. It recursively discovers all action dependencies referenced via `uses:` in workflow files and `action.yml` definitions, clones them, rewrites owner references to point to the target org, and pushes everything to the destination.

## Prerequisites

- [PowerShell 7+](https://github.com/PowerShell/PowerShell) (`pwsh`)
- `git` in PATH, authenticated for both the source and target hosts (e.g. via [Git Credential Manager](https://github.com/git-ecosystem/git-credential-manager))
- A `GITHUB_TOKEN` or `GH_TOKEN` environment variable with **`repo`** scope and repo-creation rights on the target org

Set the token before running:

```powershell
# Option 1 — set manually
$env:GITHUB_TOKEN = "ghp_your_token_here"

# Option 2 — reuse the token stored by the GitHub CLI
$env:GITHUB_TOKEN = (gh auth token)
```

## Usage

```powershell
$env:GITHUB_TOKEN = (gh auth token)   # or set manually

./clone-repository.ps1 `
  -SourceUrl  @('https://github.com/skills/exercise-toolkit', 'https://github.com/actions/checkout') `
  -TargetHost ghe.company.com `
  -TargetOrg  my-org
```

### Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-SourceUrl` | Yes | | One or more source repository URLs to migrate |
| `-TargetHost` | Yes | | Hostname of the target GHE instance |
| `-TargetOrg` | Yes | | Organisation on the target host to push repos into |
| `-OutDir` | No | `./tmp-gh-mirror` | Working directory for local clones and manifests |
| `-Visibility` | No | auto | Repo visibility: `public` (default for github.com), `internal` (default for GHES), or `private` |
| `-NewOwner` | No | `$TargetOrg` | Owner name used when rewriting `uses:` references |

## What it does

1. **Clone** — recursively discovers and clones the source repos and every action dependency found in `.github/workflows/` and `action.yml` files.
2. **Rewrite** — updates all `uses: owner/repo@ref` references in workflow files to point to the target org, then commits the changes locally.
3. **Push** — creates each repo in the target GHE org (if it doesn't exist) and pushes a full mirror.

## Output

After a successful run, `OutDir` contains:

```
tmp-gh-mirror/
├── clones/                  # local mirror of every discovered repo
├── repos.txt                # list of all repos (owner/repo, one per line)
├── clone-map.csv            # maps source URLs to local clone paths
└── refs-by-repo.csv         # dependency refs seen per repo
```

## Project structure

```
clone-repository.ps1         # entry point
helpers/
├── 01-clone-dependency-graph.ps1
├── 02-rewrite-uses-owner.ps1
└── 03-push-to-ghe.ps1
```
