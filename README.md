# Gravion CI

A collection of reusable GitHub Actions (composite actions) and reusable workflows for use across Gravion repositories.

## Repository Structure

```
dotnet/
├── build/                  # Checkout, build, and optionally publish a .NET project
├── test/                   # Run unit tests with Coverlet code coverage
├── setup/                  # Set up .NET SDK, NuGet cache, optional private feed
└── nuget/
    ├── pack/               # Pack a .NET project as a NuGet package
    └── publish/            # Publish .nupkg files to a NuGet feed
python/
├── build/                  # Checkout, set version, sync deps, and build a Python package
├── test/                   # Run pytest with code coverage
├── setup/                  # Set up uv and Python with dependency cache
└── pypi/
    └── publish/            # Publish to PyPI (Trusted Publishing) or a private feed
versioning/
├── determine-version/      # Determine SemVer from git history (GitVersion)
└── create-version-tag/     # Create and push a git tag
.github/workflows/
├── nuget-package.yml       # Reusable NuGet CI/CD workflow (version → build → test → pack → publish)
├── python-package.yml      # Reusable Python CI/CD workflow (version → build → test → publish)
└── node-ci.yml             # Reusable Node.js CI workflow
```

---

## Composite Actions

### `dotnet/setup`

Sets up the .NET SDK, NuGet package cache, and an optional private NuGet feed.
Supports GitHub Packages, Azure Artifacts, and JFrog Artifactory.

> Used internally by `dotnet/build`. Use directly when you need SDK setup without a full build.

**Usage:**

```yaml
- uses: GravionLabs/ci/dotnet/setup@main
  with:
    dotnet-version: '10.x'
    feed-url: https://pkgs.dev.azure.com/myorg/_packaging/myfeed/nuget/v3/index.json
    feed-username: myuser
    feed-token: ${{ secrets.AZURE_DEVOPS_PAT }}
```

**Inputs**

| Name             | Description                       | Required | Default        |
|------------------|-----------------------------------|----------|----------------|
| `dotnet-version` | .NET SDK version to install       | No       | `10.x`         |
| `feed-url`       | URL of the private NuGet feed     | No       | `''`           |
| `feed-name`      | Name to register the feed as      | No       | `private-feed` |
| `feed-username`  | Username for the private feed     | No       | `''`           |
| `feed-token`     | Token or PAT for the private feed | No       | `''`           |

---

### `dotnet/build`

Checks out the repository, sets up .NET, restores, builds, and optionally publishes a .NET project or solution.

**Usage:**

```yaml
- uses: GravionLabs/ci/dotnet/build@main
  with:
    dotnet-project: 'src/MyApp/MyApp.csproj'
    configuration: Release
    publish: 'true'                        # only for deployable apps
    feed-url: ${{ vars.NUGET_FEED_URL }}
    feed-token: ${{ secrets.NUGET_TOKEN }}
```

**Inputs**

| Name             | Description                              | Required | Default        |
|------------------|------------------------------------------|----------|----------------|
| `dotnet-version` | .NET SDK version to install              | No       | `10.x`         |
| `dotnet-project` | Path to project or solution file         | No       | `**/*.csproj`  |
| `configuration`  | Build configuration                      | No       | `Release`      |
| `publish`        | Publish app after build (`true`/`false`) | No       | `false`        |
| `nuget-config`   | Path to a `nuget.config` file            | No       | `''`           |
| `verbosity`      | MSBuild verbosity level                  | No       | `minimal`      |
| `feed-url`       | URL of a private NuGet restore feed      | No       | `''`           |
| `feed-name`      | Name to register the feed as             | No       | `private-feed` |
| `feed-username`  | Username for the private feed            | No       | `''`           |
| `feed-token`     | Token or PAT for the private feed        | No       | `''`           |

---

### `dotnet/test`

Runs unit tests with Coverlet code coverage via the XPlat collector (`--collect:"XPlat Code Coverage"`). Uploads test results and coverage reports as artifacts.

> **Prerequisite:** `dotnet/build` must have run in the same job (`--no-build` is set).

**Usage:**

```yaml
- uses: GravionLabs/ci/dotnet/test@main
  with:
    dotnet-project: 'tests/MyApp.Tests/MyApp.Tests.csproj'
    coverage-format: cobertura
```

**Inputs**

| Name              | Description                                                | Required | Default       |
|-------------------|------------------------------------------------------------|----------|---------------|
| `dotnet-project`  | Path to test project or solution                           | No       | `**/*.csproj` |
| `configuration`   | Build configuration                                        | No       | `Release`     |
| `coverage-format` | Coverage format (`cobertura`, `opencover`, `lcov`, `json`) | No       | `cobertura`   |
| `upload-results`  | Upload test + coverage artifacts                           | No       | `true`        |
| `verbosity`       | Verbosity level                                            | No       | `minimal`     |

> The test project must have `coverlet.collector` as a NuGet dependency.

---

### `dotnet/nuget/pack`

Packs a .NET project as a NuGet package and uploads the `.nupkg` files as the `nupkgs` artifact.

> **Prerequisite:** `dotnet/build` must have run in the same job (`--no-build` is set).

**Usage:**

```yaml
- uses: GravionLabs/ci/dotnet/nuget/pack@main
  with:
    dotnet-project: 'src/MyLib/MyLib.csproj'
    version: ${{ steps.version.outputs.nuget-version }}
```

**Inputs**

| Name             | Description                 | Required | Default       |
|------------------|-----------------------------|----------|---------------|
| `dotnet-project` | Path to the project to pack | No       | `**/*.csproj` |
| `configuration`  | Build configuration         | No       | `Release`     |
| `version`        | NuGet package version       | **Yes**  | —             |

---

### `dotnet/nuget/publish`

Publishes `.nupkg` files to a NuGet feed. Supports GitHub Packages, Azure Artifacts, and JFrog Artifactory.

**Usage:**

```yaml
# Same job as pack:
- uses: GravionLabs/ci/dotnet/nuget/publish@main
  with:
    feed-url: https://nuget.pkg.github.com/GravionLabs/index.json
    api-key: ${{ secrets.GITHUB_TOKEN }}

# Separate job (downloads artifact first):
- uses: GravionLabs/ci/dotnet/nuget/publish@main
  with:
    feed-url: https://pkgs.dev.azure.com/myorg/_packaging/myfeed/nuget/v3/index.json
    api-key: ${{ secrets.AZURE_DEVOPS_PAT }}
    download-artifact: 'true'
```

**Inputs**

| Name                | Description                                  | Required | Default            |
|---------------------|----------------------------------------------|----------|--------------------|
| `feed-url`          | URL of the target NuGet feed                 | **Yes**  | —                  |
| `api-key`           | API key or PAT for the feed                  | **Yes**  | —                  |
| `nupkgs-path`       | Glob path to `.nupkg` files                  | No       | `./nupkgs/*.nupkg` |
| `download-artifact` | Download `nupkgs` artifact before publishing | No       | `false`            |
| `artifact-name`     | Name of the artifact to download             | No       | `nupkgs`           |
| `skip-duplicate`    | Skip if version already exists in feed       | No       | `true`             |

---

---

## Python Actions

### `python/setup`

Installs [uv](https://docs.astral.sh/uv/) and the specified Python version with automatic dependency caching keyed on `uv.lock`.

> Used internally by `python/build`. Use directly when you need the environment without a full build.

**Usage:**

```yaml
- uses: GravionLabs/ci/python/setup@main
  with:
    python-version: '3.14'
```

**Inputs**

| Name             | Description                                   | Required | Default |
|------------------|-----------------------------------------------|----------|---------|
| `python-version` | Python version to install (e.g. `3.12`, `3.14`) | No       | `3.14`  |
| `uv-version`     | uv version to pin (e.g. `0.6.0`); omit for latest | No   | `''`    |

---

### `python/build`

Checks out the repository, sets the package version in `pyproject.toml`, installs dependencies via `uv sync --locked`, builds the package, and uploads the `dist/` directory as the `dist` artifact.

**Usage:**

```yaml
- uses: GravionLabs/ci/python/build@main
  with:
    version: ${{ steps.version.outputs.python-version }}
    working-directory: 'src/mypackage'
```

**Inputs**

| Name                | Description                                         | Required | Default |
|---------------------|-----------------------------------------------------|----------|---------|
| `python-version`    | Python version to use                               | No       | `3.14`  |
| `uv-version`        | uv version to pin; omit for latest                  | No       | `''`    |
| `version`           | Package version to set (e.g. `1.2.3` or `1.2.3a4`) | **Yes**  | —       |
| `working-directory` | Directory containing `pyproject.toml`               | No       | `.`     |
| `upload-artifact`   | Upload `dist/` as artifact                          | No       | `true`  |
| `artifact-name`     | Name of the uploaded artifact                       | No       | `dist`  |

> `uv sync --locked` fails the build if `uv.lock` is out of date, ensuring reproducible CI builds.

---

### `python/test`

Runs pytest with optional code coverage and uploads test results and coverage reports as artifacts.

> **Prerequisite:** `python/build` must have run in the same job (environment is already set up).

**Usage:**

```yaml
- uses: GravionLabs/ci/python/test@main
  with:
    pytest-args: 'tests/ -k "not slow"'
    coverage-report: xml
```

**Inputs**

| Name                | Description                                                            | Required | Default |
|---------------------|------------------------------------------------------------------------|----------|---------|
| `working-directory` | Directory containing `pyproject.toml`                                  | No       | `.`     |
| `pytest-args`       | Additional pytest arguments                                            | No       | `''`    |
| `coverage-report`   | Coverage format (`xml`, `html`, `term`, `term-missing`); empty = off   | No       | `xml`   |
| `upload-results`    | Upload test results and coverage as artifacts                          | No       | `true`  |

> The test project must have `pytest-cov` as a dev dependency for coverage to work.

---

### `python/pypi/publish`

Publishes Python packages from the `dist/` directory to PyPI or a private feed.
Supports [PyPI Trusted Publishing](https://docs.pypi.org/trusted-publishers/) (no token needed) as well as GitHub Packages, Azure Artifacts, and JFrog Artifactory.

**Usage:**

```yaml
# PyPI via Trusted Publishing (requires id-token: write permission):
- uses: GravionLabs/ci/python/pypi/publish@main
  with:
    download-artifact: 'true'

# Private feed:
- uses: GravionLabs/ci/python/pypi/publish@main
  with:
    feed-url: https://pkgs.dev.azure.com/myorg/_packaging/myfeed/pypi/upload/
    api-token: ${{ secrets.AZURE_DEVOPS_PAT }}
    download-artifact: 'true'
```

**Inputs**

| Name                | Description                                          | Required | Default |
|---------------------|------------------------------------------------------|----------|---------|
| `feed-url`          | Target package index URL; empty = PyPI                | No       | `''`    |
| `api-token`         | API token or PAT; not needed for PyPI Trusted Publishing | No    | `''`    |
| `download-artifact` | Download `dist` artifact before publishing           | No       | `false` |
| `artifact-name`     | Name of the artifact to download                     | No       | `dist`  |
| `skip-existing`     | Skip packages that already exist in the feed         | No       | `true`  |

---

### `versioning/determine-version`

Determines semantic versions from the git history using [GitVersion](https://gitversion.net/). Outputs version strings for all major ecosystems and prints a summary to the log.

> **Prerequisite:** The calling job must check out with `fetch-depth: 0`.

**Usage:**

```yaml
jobs:
  version:
    runs-on: ubuntu-latest
    outputs:
      semver: ${{ steps.version.outputs.semver }}
      nuget-version: ${{ steps.version.outputs.nuget-version }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Determine version
        id: version
        uses: GravionLabs/ci/versioning/determine-version@main
```

**Inputs**

| Name                      | Description                            | Required | Default                         |
|---------------------------|----------------------------------------|----------|---------------------------------|
| `gitversion-version-spec` | GitVersion tool version to install     | No       | `6.x`                           |
| `config-file-path`        | Path to a `GitVersion.yml` config file | No       | `''` (uses GitVersion defaults) |

**Outputs**

| Name                    | Example                      | Use case                                  |
|-------------------------|------------------------------|-------------------------------------------|
| `semver`                | `1.2.3-alpha.4`              | Docker tags, npm, Angular, NuGet, git tag |
| `major-minor-patch`     | `1.2.3`                      | Stable version (no pre-release suffix)    |
| `major`                 | `1`                          | Docker major tag                          |
| `minor`                 | `2`                          | Docker minor tag                          |
| `patch`                 | `3`                          | —                                         |
| `pre-release-tag`       | `alpha.4`                    | Conditional logic; empty on stable        |
| `pre-release-label`     | `alpha`                      | Conditional logic; empty on stable        |
| `pre-release-number`    | `4`                          | —                                         |
| `informational-version` | `1.2.3+Branch.main.Sha.abc…` | .NET `AssemblyInformationalVersion`       |
| `assembly-sem-ver`      | `1.2.0.0`                    | .NET `AssemblyVersion`                    |
| `assembly-sem-file-ver` | `1.2.3.0`                    | .NET `AssemblyFileVersion`                |
| `nuget-version`         | `1.2.3-alpha.4`              | NuGet packages                            |
| `npm-version`           | `1.2.3-alpha.4`              | npm / Angular packages                    |
| `python-version`        | `1.2.3a4`                    | Python / uv (PEP 440)                     |
| `docker-version`        | `1.2.3-alpha.4-abc1234`      | Docker image tags with commit hash        |

---

### `versioning/create-version-tag`

Creates and pushes a git tag. Idempotent — skips silently if the tag already exists.

> **Prerequisite:** The calling workflow must grant `permissions: contents: write`.

**Usage:**

```yaml
permissions:
  contents: write

steps:
  - uses: actions/checkout@v4
    with:
      fetch-depth: 0

  - name: Determine version
    id: version
    uses: GravionLabs/ci/versioning/determine-version@main

  - name: Tag release
    uses: GravionLabs/ci/versioning/create-version-tag@main
    with:
      version: ${{ steps.version.outputs.semver }}
```

**Inputs**

| Name         | Description                              | Required | Default |
|--------------|------------------------------------------|----------|---------|
| `version`    | Version to tag (e.g. `1.2.3-alpha.4`)    | **Yes**  | —       |
| `tag-prefix` | Prefix for the tag (e.g. `v` → `v1.2.3`) | No       | `v`     |

---

## Reusable Workflows

### `nuget-package.yml`

A complete NuGet CI/CD pipeline: determine version → build → test → pack → publish (on `main` only).

**Jobs:**

```
determine-version  →  build-test-pack  →  publish (main only, environment: nuget-publish)
```

**Usage:**

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  ci:
    uses: GravionLabs/ci/.github/workflows/nuget-package.yml@main
    with:
      dotnet-project: 'src/MyLib/MyLib.csproj'
      publish-feed-url: https://nuget.pkg.github.com/GravionLabs/index.json
    secrets:
      publish-api-key: ${{ secrets.GITHUB_TOKEN }}
```

**Inputs**

| Name                     | Description                   | Required | Default        |
|--------------------------|-------------------------------|----------|----------------|
| `dotnet-version`         | .NET SDK version              | No       | `10.x`         |
| `dotnet-project`         | Path to project or solution   | No       | `**/*.csproj`  |
| `configuration`          | Build configuration           | No       | `Release`      |
| `gitversion-config-file` | Path to `GitVersion.yml`      | No       | `''`           |
| `feed-url`               | Private restore feed URL      | No       | `''`           |
| `feed-name`              | Private restore feed name     | No       | `private-feed` |
| `feed-username`          | Private restore feed username | No       | `''`           |
| `publish-feed-url`       | Target publish feed URL       | **Yes**  | —              |
| `nuget-config`           | Path to `nuget.config`        | No       | `''`           |
| `verbosity`              | Verbosity level               | No       | `minimal`      |
| `coverage-format`        | Coverage report format        | No       | `cobertura`    |

**Secrets**

| Name              | Description                        | Required |
|-------------------|------------------------------------|----------|
| `feed-token`      | Token for the private restore feed | No       |
| `publish-api-key` | Token for the publish feed         | **Yes**  |

> The `publish` job uses `environment: nuget-publish`. Configure this environment in GitHub repository settings to add approval gates or deployment protection rules.

---

### `python-package.yml`

A complete Python CI/CD pipeline: determine version → build → test → publish (on `main` only).
Supports PyPI Trusted Publishing by default; pass `publish-feed-url` + `publish-api-token` for private feeds.

**Jobs:**

```
determine-version  →  build-test  →  publish (main only, environment: pypi-publish)
```

**Usage:**

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  ci:
    uses: GravionLabs/ci/.github/workflows/python-package.yml@main
    with:
      working-directory: 'src/mypackage'
    permissions:
      id-token: write  # for PyPI Trusted Publishing
```

**Inputs**

| Name                     | Description                              | Required | Default     |
|--------------------------|------------------------------------------|----------|-------------|
| `python-version`         | Python version to use                    | No       | `3.14`      |
| `uv-version`             | uv version to pin; omit for latest       | No       | `''`        |
| `working-directory`      | Directory containing `pyproject.toml`    | No       | `.`         |
| `gitversion-config-file` | Path to `GitVersion.yml`                 | No       | `''`        |
| `pytest-args`            | Additional pytest arguments              | No       | `''`        |
| `coverage-report`        | Coverage report format                   | No       | `xml`       |
| `publish-feed-url`       | Target feed URL; empty = PyPI            | No       | `''`        |

**Secrets**

| Name                 | Description                                             | Required |
|----------------------|---------------------------------------------------------|----------|
| `publish-api-token`  | API token for private feeds; omit for PyPI Trusted Publishing | No |

> The `publish` job uses `environment: pypi-publish`. Configure this environment in GitHub repository settings to add approval gates or deployment protection rules.

---

### `node-ci.yml`

A complete CI pipeline for Node.js projects: checkout → setup Node.js → install → build → test.

**Usage:**

```yaml
# .github/workflows/ci.yml
jobs:
  ci:
    uses: GravionLabs/ci/.github/workflows/node-ci.yml@main
    with:
      node-version: '20'
      working-directory: '.'
      run-tests: true
```

**Inputs**

| Name                | Description                      | Required | Default |
|---------------------|----------------------------------|----------|---------|
| `node-version`      | Node.js version to use           | No       | `20`    |
| `working-directory` | Path to the Node.js project root | No       | `.`     |
| `run-tests`         | Whether to run `npm test`        | No       | `true`  |

---

## Pinning to a Specific Version

To pin to a release tag or commit SHA instead of `@main`:

```yaml
uses: GravionLabs/ci/dotnet/build@v1.0.0
# or
uses: GravionLabs/ci/dotnet/build@<commit-sha>
```




