# AGENTS.md

## Repository Snapshot

`GravionLabs/ci` provides reusable GitHub Actions composite actions and reusable workflows for .NET and Python CI/CD pipelines. All actions are composites; no standalone workflow files exist except the reusable `nuget-package.yml`.

## Repo Map

```
versioning/
  determine-version/    — GitVersion-based semantic versioning (outputs: semver, nuget-version, python-version, docker-version, …)
  create-version-tag/   — Creates and pushes a git tag from a version string

dotnet/
  setup/                — Installs .NET SDK, caches NuGet packages, optionally adds a private feed
  build/                — checkout + setup + restore + build (+ optional publish)
  test/                 — runs dotnet test with Coverlet coverage, uploads results/coverage as artifacts
  nuget/
    pack/               — dotnet pack → ./nupkgs/, uploads nupkgs artifact
    publish/            — dotnet nuget push to any feed (optionally downloads artifact first)
    verify-package/     — inspects packed .nupkg for required file paths

python/
  setup/                — Installs Python + uv
  build/                — build Python package
  test/                 — runs Python tests
  pypi/publish/         — publishes to PyPI

.github/workflows/
  nuget-package.yml     — Full NuGet CI/CD reusable workflow:
                          determine-version → build-test-pack (+ verify) → publish (main only)
```

## Reusable Workflow: `nuget-package.yml`

Call with `uses: GravionLabs/ci/.github/workflows/nuget-package.yml@main`.

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `dotnet-project` | No | `**/*.csproj` | Path to .csproj or .slnx |
| `dotnet-version` | No | `10.x` | .NET SDK version |
| `configuration` | No | `Release` | Build configuration |
| `gitversion-config-file` | No | `""` | Path to `GitVersion.yml` |
| `publish-feed-url` | **Yes** | — | Target NuGet feed URL |
| `feed-url` | No | `""` | Private restore feed URL |
| `feed-name` | No | `private-feed` | Private restore feed name |
| `feed-username` | No | `""` | Private feed username |
| `nuget-config` | No | `nuget.config` | NuGet config file path |
| `verbosity` | No | `minimal` | dotnet verbosity |
| `coverage-format` | No | `cobertura` | Coverage format |
| `force-publish` | No | `false` | Publish regardless of branch |
| `verify-package-files` | No | `""` | Newline-separated list of paths that must exist inside the .nupkg |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `publish-api-key` | **Yes** | NuGet API key or PAT |
| `feed-token` | No | Token for private restore feed |

### Behavior

- **Versioning is internal**: the workflow runs `determine-version` itself. Do NOT pass a `version:` input.
- **Publish only on `main`** unless `force-publish: true`.
- **verify-package** runs immediately after `pack` in the same job — no artifact download needed. It acts as a pre-publish gate on PRs and a post-pack sanity check on `main`.
- The `environment: nuget-publish` is required on the publish job — configure this in the repository settings.

### Common Feed URLs

```
nuget.org:           https://api.nuget.org/v3/index.json
GitHub Packages:     https://nuget.pkg.github.com/{owner}/index.json
Azure Artifacts:     https://pkgs.dev.azure.com/{org}/_packaging/{feed}/nuget/v3/index.json
JFrog Artifactory:   https://{domain}/artifactory/api/nuget/v3/{repo}
```

### Minimal Example

```yaml
jobs:
  package:
    name: Package
    uses: GravionLabs/ci/.github/workflows/nuget-package.yml@main
    with:
      dotnet-project: src/MyLib/MyLib.csproj
      gitversion-config-file: GitVersion.yml
      publish-feed-url: https://api.nuget.org/v3/index.json
    secrets:
      publish-api-key: ${{ secrets.NUGET_API_KEY }}
```

### With Package Verification

```yaml
with:
  dotnet-project: src/MyLib/MyLib.csproj
  gitversion-config-file: GitVersion.yml
  publish-feed-url: https://api.nuget.org/v3/index.json
  verify-package-files: |
    lib/net8.0/MyLib.dll
    lib/net10.0/MyLib.dll
    lib/net8.0/MyLib.xml
    README.md
    CHANGELOG.md
```

## Composite Actions

### `versioning/determine-version`

Runs GitVersion on the full git history (`fetch-depth: 0` required in caller).

**Key outputs:** `semver`, `nuget-version`, `npm-version`, `python-version`, `docker-version`, `major-minor-patch`.

### `versioning/create-version-tag`

Creates and pushes a `v{version}` tag. Idempotent — skips if tag already exists.
Requires `contents: write` permission.

### `dotnet/build`

Full checkout + SDK setup + restore + build. Optionally `publish: true` for apps.

### `dotnet/test`

Runs `dotnet test` with Coverlet. Uploads test results and coverage as artifacts.

### `dotnet/nuget/pack`

`dotnet pack` → `./nupkgs/`. Uploads `nupkgs` artifact. Requires `version` input.

### `dotnet/nuget/publish`

`dotnet nuget push` to any feed. Set `download-artifact: true` when running in a separate job.

### `dotnet/nuget/verify-package`

Inspects `./nupkgs/*.nupkg` for required paths. Must run in the same job as `pack`.

## Architecture and Conventions

- Versioning uses [GitVersion](https://gitversion.net/) — the repo needs a `GitVersion.yml`.
- All dotnet actions use `--no-build` where possible to avoid redundant builds.
- The `nupkgs` artifact is the handoff between `build-test-pack` and `publish` jobs.
- Python actions mirror the dotnet structure but use `uv` for package management.

## Safe Change Checklist

- When adding a new input to an action, add a corresponding entry to `nuget-package.yml` if it should be surfaced there.
- Run `python3 scripts/generate_docs.py` after changing action inputs/outputs to regenerate README tables.
- Add `<!-- action-docs:inputs source="..." -->` markers if adding a new action section to README.md.
