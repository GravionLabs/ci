# AGENTS.md

## Repository Snapshot

`GravionLabs/ci` provides reusable GitHub Actions composite actions and reusable workflows for .NET, Python, and Docker CI/CD pipelines.

## Repo Map

```
versioning/
  determine-version/    — GitVersion-based semantic versioning (outputs: semver, nuget-version, python-version, docker-version, major, minor, patch, …)
  create-version-tag/   — Creates and pushes a git tag from a version string
  gh-release/           — Creates a GitHub Release with optional changelog extraction

dotnet/
  setup/                — Installs .NET SDK, caches NuGet packages, optionally adds a private feed
  build/                — checkout + setup + restore + build (+ optional publish); default dotnet-project: **/*.{sln,slnx}
  test/                 — runs dotnet test with Coverlet coverage; default test-project: test/**/*.Test.csproj
  nuget/
    pack/               — dotnet pack → ./nupkgs/, uploads nupkgs artifact; default dotnet-project: **/*.{sln,slnx}
    publish/            — dotnet nuget push to any feed (optionally downloads artifact first)
    verify-package/     — inspects packed .nupkg for required file paths

python/
  setup/                — Installs Python + uv
  build/                — build Python package
  test/                 — runs Python tests
  pypi/publish/         — publishes to PyPI or private feed; credential input: api-key

docker/
  lint/                 — Lint Dockerfile with hadolint; includes checkout
  build/                — checkout + setup QEMU + buildx + build (no push); validates multi-arch build
  publish/              — setup QEMU + buildx + login + compute tags + build+push; NO checkout

.github/workflows/
  nuget-package.yml     — Full NuGet CI/CD: determine-version → build-test-pack (+ verify) → publish (main only)
  python-package.yml    — Full Python CI/CD: determine-version → build-test → publish (main only)
  docker-package.yml    — Full Docker CI/CD: determine-version ‖ lint → build-publish → release (main only)
  node-ci.yml           — Node.js CI: checkout → setup → install → build → test
  sync-wiki.yml         — Wiki sync: docs/**/*.md + README.md → GitHub Wiki
```

## Reusable Workflow: `nuget-package.yml`

Call with `uses: GravionLabs/ci/.github/workflows/nuget-package.yml@main`.

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `dotnet-project` | No | `**/*.{sln,slnx}` | Path to .sln/.slnx or .csproj |
| `test-project` | No | `test/**/*.Test.csproj` | Glob for test projects |
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
      publish-feed-url: https://api.nuget.org/v3/index.json
    secrets:
      publish-api-key: ${{ secrets.NUGET_API_KEY }}
```

## Reusable Workflow: `docker-package.yml`

Call with `uses: GravionLabs/ci/.github/workflows/docker-package.yml@main`.

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `image-name` | **Yes** | — | Image name without registry (e.g. `org/myapp`) |
| `registry` | No | `ghcr.io` | Container registry hostname |
| `dockerfile` | No | `Dockerfile` | Path to the Dockerfile |
| `context` | No | `.` | Docker build context |
| `platforms` | No | `linux/amd64,linux/arm64` | Target platforms |
| `build-args` | No | `""` | Newline-separated build arguments |
| `gitversion-config-file` | No | `""` | Path to `GitVersion.yml` |
| `main-branch` | No | `main` | Branch from which full version tags are published |
| `force-publish` | No | `false` | Publish regardless of branch |
| `changelog-file` | No | `CHANGELOG.md` | Path to changelog for release notes |
| `release-tag-prefix` | No | `v` | Git tag prefix |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `registry-username` | **Yes** | Registry username |
| `registry-token` | **Yes** | Registry token (e.g. `GITHUB_TOKEN` for GHCR) |

### Tag Strategy

- **On `main`:** `latest`, `{major}`, `{major}.{minor}`, `{major}.{minor}.{patch}`, `{docker-version}`
- **On other branches:** `{docker-version}` only (e.g. `1.2.3-alpha.4-abc1234`)

### Minimal Example

```yaml
jobs:
  docker:
    uses: GravionLabs/ci/.github/workflows/docker-package.yml@main
    with:
      image-name: ${{ github.repository }}
    secrets:
      registry-username: ${{ github.actor }}
      registry-token: ${{ secrets.GITHUB_TOKEN }}
    permissions:
      packages: write
      contents: write
```

## Composite Actions

### `versioning/determine-version`

Runs GitVersion on the full git history (`fetch-depth: 0` required in caller).

**Key outputs:** `semver`, `nuget-version`, `npm-version`, `python-version`, `docker-version`, `major`, `minor`, `patch`, `major-minor-patch`.

### `versioning/create-version-tag`

Creates and pushes a `v{version}` tag. Idempotent — skips if tag already exists.
Requires `contents: write` permission.

### `dotnet/build`

Full checkout + SDK setup + restore + build. Optionally `publish: true` for apps.
Default `dotnet-project`: `**/*.{sln,slnx}`.

### `dotnet/test`

Runs `dotnet test` with Coverlet. Default `test-project`: `test/**/*.Test.csproj`.
Uploads test results and coverage as artifacts.

### `dotnet/nuget/pack`

`dotnet pack` → `./nupkgs/`. Uploads `nupkgs` artifact. Requires `version` input.
Default `dotnet-project`: `**/*.{sln,slnx}`.

### `dotnet/nuget/publish`

`dotnet nuget push` to any feed. Set `download-artifact: true` when running in a separate job.

### `dotnet/nuget/verify-package`

Inspects `./nupkgs/*.nupkg` for required paths. Must run in the same job as `pack`.

### `docker/lint`

Lints a Dockerfile with hadolint. Inputs: `dockerfile`, `hadolint-config`. Includes checkout.

### `docker/build`

Builds a multi-arch image (no push) to validate the build. Includes checkout.
Inputs: `image-name`, `dockerfile`, `context`, `platforms`, `build-args`.

### `docker/publish`

Builds and pushes a multi-arch image with version tags. **No checkout** — runs after `docker/build` in the same job.
Inputs: `image-name`, `registry`, `registry-username`, `registry-token`, `dockerfile`, `context`, `platforms`, `build-args`, `docker-version`, `major`, `minor`, `patch`, `main-branch`.

## Architecture and Conventions

- Versioning uses [GitVersion](https://gitversion.net/) — the repo needs a `GitVersion.yml`.
- All dotnet actions use `--no-build` where possible to avoid redundant builds.
- The `nupkgs` artifact is the handoff between `build-test-pack` and `publish` jobs.
- Python actions mirror the dotnet structure but use `uv` for package management.
- Docker multi-arch builds require QEMU (ARM emulation) — always set up via `docker/setup-qemu-action`.
- `docker/publish` has no checkout step; it relies on the checkout done by `docker/build` in the same job.
- **`dotnet-project` vs `test-project`**: these are intentionally separate. `dotnet-project` targets the solution/library (`.sln`/`.slnx`); `test-project` targets the test projects (`.csproj`).

## Parameter Naming Conventions

- Tool-specific identifiers get a tool prefix: `dotnet-version`, `dotnet-project`, `test-project`, `python-version`, `uv-version`, `gitversion-version-spec`, `gitversion-config-file`.
- Generic flags do not: `configuration`, `verbosity`, `coverage-format`, `upload-results`.
- Infrastructure params: `feed-url`, `feed-name`, `feed-token`, `api-key`.
- Credential secrets follow the pattern `publish-api-key` (not `api-token`).

## Safe Change Checklist

- When adding a new input to an action, add a corresponding entry to the relevant reusable workflow if it should be surfaced there.
- Run `python3 scripts/generate_docs.py` after changing action inputs/outputs to regenerate README tables.
- Add `<!-- action-docs:inputs source="..." -->` markers if adding a new action section to README.md.
- For glob inputs in bash `run:` steps, always add `shopt -s globstar nullglob` before the command.


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
