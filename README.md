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
    ├── publish/            # Publish .nupkg files to a NuGet feed
    └── verify-package/     # Verify that expected files are present in a packed .nupkg
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
├── nuget-package.yml       # Reusable NuGet CI/CD workflow (version → build → test → pack → verify → publish)
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

<!-- action-docs:inputs source="dotnet/setup/action.yml" -->
| Name             | Description                                                                                 | Required | Default      |
|------------------|---------------------------------------------------------------------------------------------|----------|--------------|
| `dotnet-version` | Version of .NET SDK to use (e.g. 8.x, 9.x, 10.x)                                            | No       | 10.x         |
| `feed-url`       | URL of the private NuGet feed (GitHub Packages, Azure Artifacts, JFrog Artifactory)         | No       |              |
| `feed-name`      | Name to register the private feed as                                                        | No       | private-feed |
| `feed-username`  | Username for the private feed (e.g. GitHub username, Azure DevOps username, JFrog username) | No       |              |
| `feed-token`     | Access token or PAT for the private feed (e.g. GitHub PAT, Azure DevOps PAT, JFrog API key) | No       |              |
<!-- /action-docs:inputs -->

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

<!-- action-docs:inputs source="dotnet/build/action.yml" -->
| Name             | Description                                                                                  | Required | Default      |
|------------------|----------------------------------------------------------------------------------------------|----------|--------------|
| `dotnet-version` | Version of .NET SDK to use (e.g. 8.x, 9.x, 10.x)                                             | No       | 10.x         |
| `configuration`  | Build configuration (e.g. Debug or Release)                                                  | No       | Release      |
| `dotnet-project` | Path to the .NET project or solution file to build (e.g. MyProject.csproj or MySolution.sln) | No       | **/*.csproj  |
| `publish`        | Whether to publish the app after building (only for deployable apps, not libraries)          | No       | false        |
| `nuget-config`   | Path to a NuGet configuration file (optional, e.g. nuget.config)                             | No       | nuget.config |
| `verbosity`      | Verbosity level (quiet, minimal, normal, detailed, diagnostic)                               | No       | minimal      |
| `feed-url`       | URL of the private NuGet feed (GitHub Packages, Azure Artifacts, JFrog Artifactory)          | No       |              |
| `feed-name`      | Name to register the private feed as                                                         | No       | private-feed |
| `feed-username`  | Username for the private feed                                                                | No       |              |
| `feed-token`     | Access token or PAT for the private feed                                                     | No       |              |
<!-- /action-docs:inputs -->

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

<!-- action-docs:inputs source="dotnet/test/action.yml" -->
| Name              | Description                                                                            | Required | Default     |
|-------------------|----------------------------------------------------------------------------------------|----------|-------------|
| `configuration`   | Build configuration (e.g. Debug or Release)                                            | No       | Release     |
| `dotnet-project`  | Path to the .NET test project or solution file (e.g. MyTests.csproj or MySolution.sln) | No       | **/*.csproj |
| `coverage-format` | Coverage report format (cobertura, opencover, lcov, json)                              | No       | cobertura   |
| `upload-results`  | Whether to upload test results and coverage report as artifacts                        | No       | true        |
| `verbosity`       | Verbosity level (quiet, minimal, normal, detailed, diagnostic)                         | No       | minimal     |
<!-- /action-docs:inputs -->

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

<!-- action-docs:inputs source="dotnet/nuget/pack/action.yml" -->
| Name             | Description                                                   | Required | Default     |
|------------------|---------------------------------------------------------------|----------|-------------|
| `dotnet-project` | Path to the .NET project file to pack (e.g. MyProject.csproj) | No       | **/*.csproj |
| `configuration`  | Build configuration (e.g. Debug or Release)                   | No       | Release     |
| `version`        | Version to use for the NuGet package (e.g. 1.2.3)             | **Yes**  | —           |
<!-- /action-docs:inputs -->

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

<!-- action-docs:inputs source="dotnet/nuget/publish/action.yml" -->
| Name                | Description                                                                                                                                                                                                                                                          | Required | Default          |
|---------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|------------------|
| `feed-url`          | URL of the target NuGet feed:   GitHub Packages:   https://nuget.pkg.github.com/{owner}/index.json   Azure Artifacts:   https://pkgs.dev.azure.com/{org}/_packaging/{feed}/nuget/v3/index.json   JFrog Artifactory: https://{domain}/artifactory/api/nuget/v3/{repo} | **Yes**  | —                |
| `api-key`           | API key or PAT for the target feed (GitHub PAT, Azure DevOps PAT, JFrog API key)                                                                                                                                                                                     | **Yes**  | —                |
| `nupkgs-path`       | Path to the .nupkg files to publish                                                                                                                                                                                                                                  | No       | ./nupkgs/*.nupkg |
| `download-artifact` | Whether to download the nupkgs artifact before publishing (set to true when running in a separate job)                                                                                                                                                               | No       | false            |
| `artifact-name`     | Name of the artifact to download (only used when download-artifact is true)                                                                                                                                                                                          | No       | nupkgs           |
| `skip-duplicate`    | Skip pushing packages that already exist in the feed instead of failing                                                                                                                                                                                              | No       | true             |
<!-- /action-docs:inputs -->

---

### `dotnet/nuget/verify-package`

Verifies that a set of expected file paths are present inside a packed `.nupkg`.
Must be called **in the same job as `dotnet/nuget/pack`** — the `./nupkgs/` directory
must already be populated.

> Used automatically by `nuget-package.yml` when `verify-package-files` is set.

**Usage:**

```yaml
- uses: GravionLabs/ci/dotnet/nuget/pack@main
  with:
    dotnet-project: 'src/MyLib/MyLib.csproj'
    version: ${{ steps.version.outputs.nuget-version }}

- uses: GravionLabs/ci/dotnet/nuget/verify-package@main
  with:
    files: |
      lib/net8.0/MyLib.dll
      lib/net10.0/MyLib.dll
      lib/net8.0/MyLib.xml
      README.md
```

**Inputs**

<!-- action-docs:inputs source="dotnet/nuget/verify-package/action.yml" -->
| Name    | Description                                                                                                                                 | Required | Default |
|---------|---------------------------------------------------------------------------------------------------------------------------------------------|----------|---------|
| `files` | Newline-separated list of file paths that must exist inside the .nupkg. Example:   lib/net8.0/MyLib.dll   lib/net10.0/MyLib.xml   README.md | **Yes**  | —       |
<!-- /action-docs:inputs -->

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

<!-- action-docs:inputs source="python/setup/action.yml" -->
| Name             | Description                                         | Required | Default |
|------------------|-----------------------------------------------------|----------|---------|
| `python-version` | Python version to use (e.g. 3.12, 3.13)             | No       | 3.14    |
| `uv-version`     | uv version to install (e.g. 0.6.0); omit for latest | No       |         |
<!-- /action-docs:inputs -->

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

<!-- action-docs:inputs source="python/build/action.yml" -->
| Name                | Description                                                            | Required | Default |
|---------------------|------------------------------------------------------------------------|----------|---------|
| `python-version`    | Python version to use (e.g. 3.12, 3.13)                                | No       | 3.14    |
| `uv-version`        | uv version to install (e.g. 0.6.0); omit for latest                    | No       |         |
| `version`           | Version to set on the package (e.g. 1.2.3 or 1.2.3a4 for pre-releases) | **Yes**  | —       |
| `working-directory` | Directory containing pyproject.toml                                    | No       | .       |
| `upload-artifact`   | Whether to upload the built dist/ directory as an artifact             | No       | true    |
| `artifact-name`     | Name of the artifact to upload                                         | No       | dist    |
<!-- /action-docs:inputs -->

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

<!-- action-docs:inputs source="python/test/action.yml" -->
| Name                | Description                                                                              | Required | Default |
|---------------------|------------------------------------------------------------------------------------------|----------|---------|
| `working-directory` | Directory containing pyproject.toml                                                      | No       | .       |
| `pytest-args`       | Additional arguments to pass to pytest (e.g. tests/ -k "not slow")                       | No       |         |
| `coverage-report`   | Coverage report format (xml, html, term, term-missing); set to empty to disable coverage | No       | xml     |
| `upload-results`    | Whether to upload test results and coverage report as artifacts                          | No       | true    |
<!-- /action-docs:inputs -->

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

<!-- action-docs:inputs source="python/pypi/publish/action.yml" -->
| Name                | Description                                                                                                                                                                                                                                                                                               | Required | Default |
|---------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|---------|
| `feed-url`          | URL of the target package index. Leave empty to publish to PyPI via Trusted Publishing.   GitHub Packages:   https://nuget.pkg.github.com/{owner}/   Azure Artifacts:   https://pkgs.dev.azure.com/{org}/_packaging/{feed}/pypi/upload/   JFrog Artifactory: https://{domain}/artifactory/api/pypi/{repo} | No       |         |
| `api-token`         | API token or PAT for the target feed (not required when using PyPI Trusted Publishing)                                                                                                                                                                                                                    | No       |         |
| `download-artifact` | Whether to download the dist artifact before publishing (set to true when running in a separate job)                                                                                                                                                                                                      | No       | false   |
| `artifact-name`     | Name of the artifact to download (only used when download-artifact is true)                                                                                                                                                                                                                               | No       | dist    |
| `skip-existing`     | Skip publishing packages that already exist in the feed instead of failing                                                                                                                                                                                                                                | No       | true    |
<!-- /action-docs:inputs -->

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

<!-- action-docs:inputs source="versioning/determine-version/action.yml" -->
| Name                      | Description                                                                                   | Required | Default |
|---------------------------|-----------------------------------------------------------------------------------------------|----------|---------|
| `gitversion-version-spec` | GitVersion tool version to install (semver range)                                             | No       | 6.x     |
| `config-file-path`        | Path to the GitVersion.yml configuration file (optional, uses GitVersion defaults if not set) | No       |         |
<!-- /action-docs:inputs -->

**Outputs**

<!-- action-docs:outputs source="versioning/determine-version/action.yml" -->
| Name                    | Description                                                                            |
|-------------------------|----------------------------------------------------------------------------------------|
| `semver`                | Full SemVer (e.g. 1.2.3-alpha.4) — use for npm, Angular, NuGet, Docker                 |
| `major-minor-patch`     | Stable version without pre-release (e.g. 1.2.3)                                        |
| `major`                 | Major version number (e.g. 1)                                                          |
| `minor`                 | Minor version number (e.g. 2)                                                          |
| `patch`                 | Patch version number (e.g. 3)                                                          |
| `pre-release-tag`       | Full pre-release tag (e.g. alpha.4); empty on stable releases                          |
| `pre-release-label`     | Pre-release label (e.g. alpha, beta, rc); empty on stable releases                     |
| `pre-release-number`    | Pre-release number (e.g. 4)                                                            |
| `informational-version` | Long version with branch and SHA — use for .NET AssemblyInformationalVersion           |
| `assembly-sem-ver`      | Assembly-compatible version (e.g. 1.2.0.0) — use for .NET AssemblyVersion              |
| `assembly-sem-file-ver` | Assembly file version (e.g. 1.2.3.0) — use for .NET AssemblyFileVersion                |
| `nuget-version`         | NuGet-compatible version (e.g. 1.2.3-alpha.4)                                          |
| `npm-version`           | npm-compatible SemVer (e.g. 1.2.3-alpha.4)                                             |
| `python-version`        | PEP 440-compatible version (e.g. 1.2.3a4) — use for Python / uv packages               |
| `docker-version`        | SemVer with short commit hash (e.g. 1.2.3-alpha.4-abc1234) — use for Docker image tags |
<!-- /action-docs:outputs -->

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

<!-- action-docs:inputs source="versioning/create-version-tag/action.yml" -->
| Name         | Description                                                                      | Required | Default |
|--------------|----------------------------------------------------------------------------------|----------|---------|
| `version`    | Version to tag (e.g. the semver output of determine-version, e.g. 1.2.3-alpha.4) | **Yes**  | —       |
| `tag-prefix` | Prefix to prepend to the version when creating the tag (e.g. "v" → v1.2.3)       | No       | v       |
<!-- /action-docs:inputs -->

---

## Reusable Workflows

### `nuget-package.yml`

A complete NuGet CI/CD pipeline: determine version → build → test → pack → verify → publish (on `main` only).

**Jobs:**

```
determine-version  →  build-test-pack (→ verify, if verify-package-files set)  →  publish (main only, environment: nuget-publish)
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
      gitversion-config-file: GitVersion.yml
      publish-feed-url: https://nuget.pkg.github.com/GravionLabs/index.json
      verify-package-files: |
        lib/net8.0/MyLib.dll
        lib/net10.0/MyLib.dll
        README.md
    secrets:
      publish-api-key: ${{ secrets.GITHUB_TOKEN }}
```

**Inputs**

| Name                     | Description                                                   | Required | Default        |
|--------------------------|---------------------------------------------------------------|----------|----------------|
| `dotnet-version`         | .NET SDK version                                              | No       | `10.x`         |
| `dotnet-project`         | Path to project or solution                                   | No       | `**/*.csproj`  |
| `configuration`          | Build configuration                                           | No       | `Release`      |
| `gitversion-config-file` | Path to `GitVersion.yml`                                      | No       | `''`           |
| `feed-url`               | Private restore feed URL                                      | No       | `''`           |
| `feed-name`              | Private restore feed name                                     | No       | `private-feed` |
| `feed-username`          | Private restore feed username                                 | No       | `''`           |
| `publish-feed-url`       | Target publish feed URL                                       | **Yes**  | —              |
| `nuget-config`           | Path to `nuget.config`                                        | No       | `''`           |
| `verbosity`              | Verbosity level                                               | No       | `minimal`      |
| `coverage-format`        | Coverage report format                                        | No       | `cobertura`    |
| `force-publish`          | Publish regardless of branch (for pre-release from branches)  | No       | `false`        |
| `verify-package-files`   | Newline-separated paths to verify inside the `.nupkg`         | No       | `''`           |

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




