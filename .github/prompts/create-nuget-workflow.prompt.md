---
description: Scaffold a .github/workflows/ci.yml using the GravionLabs/ci nuget-package reusable workflow
---

Create a `.github/workflows/ci.yml` file for a .NET NuGet library using the `GravionLabs/ci` reusable workflow.

## Requirements

Use `GravionLabs/ci/.github/workflows/nuget-package.yml@main` as the reusable workflow.

Ask the user for the following information if not already provided:

1. **Project path** — relative path to the `.csproj` file (e.g. `src/MyLib/MyLib.csproj`)
2. **Target feed** — where to publish (nuget.org / GitHub Packages / Azure Artifacts / JFrog)
3. **GitVersion config** — is there a `GitVersion.yml` in the repo root?
4. **Target frameworks** — which TFMs does the project target? (needed for `verify-package-files`)
5. **Expected package contents** — should the package contain a `README.md`? A `CHANGELOG.md`? An icon?
6. **Private restore feed** — is there a private NuGet feed needed for restore?

## Output

Generate a complete `ci.yml` following this structure:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  package:
    name: Package
    uses: GravionLabs/ci/.github/workflows/nuget-package.yml@main
    with:
      dotnet-project: <project-path>
      gitversion-config-file: GitVersion.yml      # omit if no GitVersion.yml
      publish-feed-url: <feed-url>
      verify-package-files: |                      # include all expected .nupkg paths
        lib/<tfm>/<LibName>.dll
        lib/<tfm>/<LibName>.xml                    # if XML docs are generated
        README.md                                  # if README is packed
        CHANGELOG.md                               # if CHANGELOG is packed
    secrets:
      publish-api-key: ${{ secrets.NUGET_API_KEY }}
```

## Rules

- **Do NOT add a `version:` input** — versioning is handled internally by the reusable workflow.
- **Do NOT add a separate `determine-version` job** — it runs inside the reusable workflow.
- One TFM entry per expected file (e.g. `lib/net8.0/MyLib.dll`, `lib/net10.0/MyLib.dll`).
- Use `secrets.NUGET_API_KEY` for nuget.org; adjust secret name for other feeds.
- For GitHub Packages, set `publish-feed-url: https://nuget.pkg.github.com/{owner}/index.json` and use `secrets.GITHUB_TOKEN`.
- Add `force-publish: true` only if explicitly requested (e.g. for pre-release from feature branches).

## Feed URL Reference

| Feed | URL Pattern |
|---|---|
| nuget.org | `https://api.nuget.org/v3/index.json` |
| GitHub Packages | `https://nuget.pkg.github.com/{owner}/index.json` |
| Azure Artifacts | `https://pkgs.dev.azure.com/{org}/_packaging/{feed}/nuget/v3/index.json` |
| JFrog Artifactory | `https://{domain}/artifactory/api/nuget/v3/{repo}` |
