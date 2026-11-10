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
docker/
├── lint/                   # Lint a Dockerfile using hadolint
├── build/                  # Build a multi-arch Docker image (no push — validates build)
└── publish/                # Build and push a multi-arch Docker image with version tags
versioning/
├── determine-version/      # Determine SemVer from git history (GitVersion)
├── create-version-tag/     # Create and push a git tag
├── gh-release/             # Create the GitHub Release; optionally recreate release/next afterwards
├── move-major-tag/         # Move the major tag (v1) to a release tag (v1.4.0)
├── mark-merged-issues/     # Label issues merged into a release/* branch (removed again by close-release-issues)
└── close-merged-issues/    # Close the issues merged into a release/* branch and comment where they ship
issues/
└── conventions/            # Set the "[Level] " title prefix and flag missing required sections of issues
project/
└── needs/                  # Keep the project field Needs current (Sync-ProjectNeeds.ps1 of the github-project skill)
wiki/
└── sync/                   # Sync docs/**/*.md and README.md to the GitHub Wiki
rust/
├── setup/                  # Set up the Rust toolchain and cargo cache (optionally Tauri system libraries)
├── ci/                     # cargo fmt --check, clippy -D warnings and tests with a single setup
├── release-binary/         # Build, pack (tar.gz/zip + SHA-256), smoke test and upload a versioned binary for one target
tauri/
├── draft-release/          # Create or find the draft release of a version, so parallel installer jobs share it
├── installers/             # Versioned Tauri 2 installers for one runner, attached to the draft release
node/
├── setup/                  # Set up Node.js and npm cache
├── build/                  # Install deps and build a Node.js project
├── test/                   # Run Node.js unit tests with coverage collection and result publishing
├── ci/                     # Lint → build → test with a single setup and dependency installation
└── publish/                # Configure npm registry auth and publish a package
.github/workflows/
├── nuget-package.yml       # Reusable NuGet CI/CD workflow (version → build → test → pack → verify → publish)
├── python-package.yml      # Reusable Python CI/CD workflow (version → build → test → publish)
├── docker-package.yml      # Reusable Docker CI/CD workflow (version → lint → build → publish → release)
├── node-package.yml        # Reusable Node.js Package CI/CD workflow
├── angular-package.yml     # Reusable Angular Package CI/CD workflow (Angular CLI defaults)
├── tauri-app.yml           # Reusable Rust CLI and Tauri 2 app workflow (version → checks → binaries ‖ installers → publish → changelog)
├── pr-checks.yml           # Reusable PR checks workflow (readiness and ADR checks, aggregate "PR checks")
├── issues.yml              # Reusable issue workflow (add to project, title/section conventions, project Needs)
├── issue-events.yml        # This repository's caller of issues.yml (workflow "Issue events")
├── project-needs.yml       # Central nightly Needs sync of the whole project (workflow "Project needs")
├── release-branch.yml      # Reusable release-branch workflow (release PR, closes merged issues, Needs sync)
└── sync-wiki.yml           # Reusable Wiki sync workflow (docs → GitHub Wiki)
```

---

## Composite Actions

### `dotnet/setup`

Sets up the .NET SDK, NuGet package cache, and an optional private NuGet feed.
Supports GitHub Packages, Azure Artifacts, and JFrog Artifactory.

> Used internally by `dotnet/build`. Use directly when you need SDK setup without a full build.

**Usage:**

```yaml
- uses: GravionLabs/ci/dotnet/setup@v1
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
- uses: GravionLabs/ci/dotnet/build@v1
  with:
    dotnet-project: 'MyApp.sln'
    configuration: Release
    publish: 'true'                        # only for deployable apps
    feed-url: ${{ vars.NUGET_FEED_URL }}
    feed-token: ${{ secrets.NUGET_TOKEN }}
```

**Inputs**

<!-- action-docs:inputs source="dotnet/build/action.yml" -->
| Name             | Description                                                                         | Required | Default         |
|------------------|-------------------------------------------------------------------------------------|----------|-----------------|
| `dotnet-version` | Version of .NET SDK to use (e.g. 8.x, 9.x, 10.x)                                    | No       | 10.x            |
| `configuration`  | Build configuration (e.g. Debug or Release)                                         | No       | Release         |
| `dotnet-project` | Path to a .NET project (.csproj) or solution (.sln/.slnx) file to build             | No       | **/*.{sln,slnx} |
| `publish`        | Whether to publish the app after building (only for deployable apps, not libraries) | No       | false           |
| `nuget-config`   | Path to a NuGet configuration file (optional, e.g. nuget.config)                    | No       | nuget.config    |
| `verbosity`      | Verbosity level (quiet, minimal, normal, detailed, diagnostic)                      | No       | minimal         |
| `feed-url`       | URL of the private NuGet feed (GitHub Packages, Azure Artifacts, JFrog Artifactory) | No       |                 |
| `feed-name`      | Name to register the private feed as                                                | No       | private-feed    |
| `feed-username`  | Username for the private feed                                                       | No       |                 |
| `feed-token`     | Access token or PAT for the private feed                                            | No       |                 |
<!-- /action-docs:inputs -->

---

### `dotnet/test`

Runs unit tests with Coverlet code coverage via the XPlat collector (`--collect:"XPlat Code Coverage"`). Uploads test results and coverage reports as artifacts.

> **Prerequisite:** `dotnet/build` must have run in the same job (`--no-build` is set).

**Usage:**

```yaml
- uses: GravionLabs/ci/dotnet/test@v1
  with:
    test-project: 'test/**/*.Test.csproj'
    coverage-format: cobertura
```

**Inputs**

<!-- action-docs:inputs source="dotnet/test/action.yml" -->
| Name              | Description                                                                         | Required | Default               |
|-------------------|-------------------------------------------------------------------------------------|----------|-----------------------|
| `test-project`    | Path or glob for the .NET test projects to run (e.g. test/**/*.Test.csproj)         | No       | test/**/*.Test.csproj |
| `configuration`   | Build configuration (e.g. Debug or Release)                                         | No       | Release               |
| `coverage-format` | Coverage report format (cobertura, opencover, lcov, json)                           | No       | cobertura             |
| `upload-results`  | Whether to upload test results and coverage report as artifacts                     | No       | true                  |
| `publish-results` | Whether to publish test results as a GitHub Check Run and coverage as a job summary | No       | true                  |
| `verbosity`       | Verbosity level (quiet, minimal, normal, detailed, diagnostic)                      | No       | minimal               |
<!-- /action-docs:inputs -->

> The test project must have `coverlet.collector` as a NuGet dependency.

---

### `dotnet/nuget/pack`

Packs a .NET project as a NuGet package and uploads the `.nupkg` files as the `nupkgs` artifact.

> **Prerequisite:** `dotnet/build` must have run in the same job (`--no-build` is set).

**Usage:**

```yaml
- uses: GravionLabs/ci/dotnet/nuget/pack@v1
  with:
    dotnet-project: 'MyLib.sln'
    version: ${{ steps.version.outputs.nuget-version }}
```

**Inputs**

<!-- action-docs:inputs source="dotnet/nuget/pack/action.yml" -->
| Name             | Description                                                            | Required | Default         |
|------------------|------------------------------------------------------------------------|----------|-----------------|
| `dotnet-project` | Path to a .NET project (.csproj) or solution (.sln/.slnx) file to pack | No       | **/*.{sln,slnx} |
| `configuration`  | Build configuration (e.g. Debug or Release)                            | No       | Release         |
| `version`        | Version to use for the NuGet package (e.g. 1.2.3)                      | **Yes**  | —               |
<!-- /action-docs:inputs -->

---

### `dotnet/nuget/publish`

Publishes `.nupkg` files to a NuGet feed. Supports GitHub Packages, Azure Artifacts, and JFrog Artifactory.

**Usage:**

```yaml
# Same job as pack:
- uses: GravionLabs/ci/dotnet/nuget/publish@v1
  with:
    feed-url: https://nuget.pkg.github.com/GravionLabs/index.json
    api-key: ${{ secrets.GITHUB_TOKEN }}

# Separate job (downloads artifact first):
- uses: GravionLabs/ci/dotnet/nuget/publish@v1
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
- uses: GravionLabs/ci/dotnet/nuget/pack@v1
  with:
    dotnet-project: 'MyLib.sln'
    version: ${{ steps.version.outputs.nuget-version }}

- uses: GravionLabs/ci/dotnet/nuget/verify-package@v1
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
- uses: GravionLabs/ci/python/setup@v1
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
- uses: GravionLabs/ci/python/build@v1
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
- uses: GravionLabs/ci/python/test@v1
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
- uses: GravionLabs/ci/python/pypi/publish@v1
  with:
    download-artifact: 'true'

# Private feed:
- uses: GravionLabs/ci/python/pypi/publish@v1
  with:
    feed-url: https://pkgs.dev.azure.com/myorg/_packaging/myfeed/pypi/upload/
    api-key: ${{ secrets.AZURE_DEVOPS_PAT }}
    download-artifact: 'true'
```

**Inputs**

<!-- action-docs:inputs source="python/pypi/publish/action.yml" -->
| Name                | Description                                                                                                                                                                                                                                                                                               | Required | Default |
|---------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|---------|
| `feed-url`          | URL of the target package index. Leave empty to publish to PyPI via Trusted Publishing.   GitHub Packages:   https://nuget.pkg.github.com/{owner}/   Azure Artifacts:   https://pkgs.dev.azure.com/{org}/_packaging/{feed}/pypi/upload/   JFrog Artifactory: https://{domain}/artifactory/api/pypi/{repo} | No       |         |
| `api-key`           | API token or PAT for the target feed (not required when using PyPI Trusted Publishing)                                                                                                                                                                                                                    | No       |         |
| `download-artifact` | Whether to download the dist artifact before publishing (set to true when running in a separate job)                                                                                                                                                                                                      | No       | false   |
| `artifact-name`     | Name of the artifact to download (only used when download-artifact is true)                                                                                                                                                                                                                               | No       | dist    |
| `skip-existing`     | Skip publishing packages that already exist in the feed instead of failing (checks feed-url via --check-url; no-op for PyPI Trusted Publishing)                                                                                                                                                           | No       | true    |
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
        uses: GravionLabs/ci/versioning/determine-version@v1
```

**Inputs**

<!-- action-docs:inputs source="versioning/determine-version/action.yml" -->
| Name                      | Description                                                                                                                                                                                                                                                                    | Required | Default |
|---------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|---------|
| `gitversion-version-spec` | GitVersion tool version to install (semver range)                                                                                                                                                                                                                              | No       | 6.x     |
| `gitversion-config-file`  | Path to the GitVersion.yml configuration file (optional, uses GitVersion defaults if not set)                                                                                                                                                                                  | No       |         |
| `conventional-commits`    | Bump the version from Conventional Commits (fix/perf/revert = patch, feat = minor, type! or BREAKING CHANGE = major; +semver: stays as escape hatch). 'false' keeps the plain GitVersion defaults.                                                                             | No       | true    |
| `channel`                 | Release channel: 'auto' derives it from the branch (main = stable, release/* = rc, every other branch = beta; tags = stable); 'stable', 'rc' or 'beta' override it. rc and beta give <next stable>-rc<nnn> / -beta<nnn> (n = commits since the last version source, at least 1, zero-padded to 3 digits). | No       | auto    |
<!-- /action-docs:inputs -->

**Versioning model (Conventional Commits).** With `conventional-commits: true` (default) the bump comes from the commit messages that reach the branch: `fix:`, `perf:`, `revert:` (and any other type, e.g. `docs:`) give a patch, `feat:` a minor, `<type>!:` or a `BREAKING CHANGE:` footer a major. `+semver: major|minor|patch` stays as an escape hatch (for example the jump to 1.0.0). `conventional-commits: false` keeps the plain GitVersion defaults. The caller's `GitVersion.yml` needs only `mode`, `next-version` and an optional `label`.

- The PR title is the squash commit and carries the bump: feature PRs into `release/**` are squash merged by convention (the ruleset also allows merge, so it does not enforce this), so the title is the one checked place and discarded intermediate commits do not count (a `feat!:` line in the squash body is no major). A feature PR merged with a merge commit brings its intermediate commits to GitVersion and git-cliff; `pr-checks/title` checks the title against the commits.
- `release/next` into the default branch stays a merge commit (no squash), otherwise the `feat:`/`fix:` commits are invisible to GitVersion and git-cliff. Merge methods per ruleset: `release/**`: merge and squash (squash is the convention for feature PRs, merge for the merge-back of `main` after a hotfix, which keeps the merge ancestry); default branch: merge only; hotfixes into `main` with a merge commit.
- Limit in 0.x: a breaking change jumps to 1.0.0 (GitVersion has no "bump minor pre major"). Avoid `!` in 0.x repositories or use `+semver: minor` deliberately.
- The reusable `*-package.yml` workflows and `tauri-app.yml` pass the input `conventional-commits` through. Test: `bash tests/conventional-commits.test.sh`.

**Release channel.** The branch decides the channel, callers need no `prerelease` input: `main` (and tag builds) is `stable` and keeps the GitVersion version; `release/*` is `rc` (`<next stable>-rc<nnn>`, e.g. `1.2.0-rc010`); every other branch is `beta` (`<next stable>-beta<nnn>`). `n` is the number of commits since the last version source (at least 1), zero-padded to 3 digits and without a dot: GitHub sorts releases by comparing the pre-release part as text, so `rc.9` would list above `rc.10`, and SemVer forbids a leading zero in a numeric identifier (`rc.010`). The alphanumeric `rc010` sorts correctly as text and as SemVer up to 999. The input `channel` (`stable`, `rc`, `beta`; default `auto`) overrides the rule. The outputs `channel` and `is-prerelease` come next to the existing ones; `semver`, `nuget-version`, `npm-version`, `python-version` (`1.2.0rc3`, `1.2.0b3`) and `docker-version` follow the channel. Existing callers on `@v1` see no change on `main`. Test: `bash tests/release-channel.test.sh`.

- **Beta builds create no tag and no release.** A caller gates tag, release and publish steps on `needs.determine-version.outputs.channel != 'beta'`; `rc` creates a pre-release tag `v<version>` (`is-prerelease` marks the release as pre-release). To keep the beta installers, upload them as workflow artifacts instead of attaching them to a release (for example `actions/upload-artifact` on the bundle directory `src-tauri/target/<target>/release/bundle/`, `retention-days: 7`).
- **Tauri installers and MSI.** WiX needs a numeric version, so `tauri/installers` skips the MSI on Windows when `version` has a suffix (`1.2.0-rc003`, `1.2.0-beta001`) and builds the NSIS installer only; a `--bundles` in `args` takes precedence.

**Outputs**

<!-- action-docs:outputs source="versioning/determine-version/action.yml" -->
| Name                    | Description                                                                            |
|-------------------------|----------------------------------------------------------------------------------------|
| `channel`               | Release channel: stable, rc or beta                                                    |
| `is-prerelease`         | 'true' on rc and beta, 'false' on stable                                               |
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
    uses: GravionLabs/ci/versioning/determine-version@v1

  - name: Tag release
    uses: GravionLabs/ci/versioning/create-version-tag@v1
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

### `versioning/gh-release`

Creates the version tag and the GitHub Release (notes from git-cliff, a CHANGELOG.md section or GitHub), runs `close-release-issues` (`close-issues`) as a safety net for the issues delivered by a merged release PR that are still open (`close-merged-issues` closes them at merge), and optionally recreates the rolling release branch.

**`recreate-branch`** (default empty = off): set it to `release/next` and, after the release, the branch is pushed from the released commit when it does not exist on origin. An existing branch is never moved or force-pushed. **Callers whose repository has `delete_branch_on_merge` should set it**: merging the release PR then deletes `release/next`, and without this input the next cycle starts only after a manual `github-release cut`. The recreated branch has no commits ahead of the default branch, so `versioning/release-pr` opens no (empty) release PR for it; GitVersion gives it the next minor from the caller's branch config. The step needs only `contents: write`. A push made with the default `GITHUB_TOKEN` triggers no workflows: pass a PAT as `token` (it is also what the changelog commit needs on a protected default branch) when the new branch must trigger them, e.g. `release-branch.yml`. The `*-package.yml` workflows pass the input through (`recreate-branch`).

```yaml
  - uses: GravionLabs/ci/versioning/gh-release@v1
    with:
      version: ${{ needs.determine-version.outputs.semver }}
      recreate-branch: release/next
```

**`version-command`** (default empty = off, behaviour unchanged): a shell command run right after the checkout with `VERSION` set (version without tag prefix, prerelease included, e.g. `1.0.0-rc.1`), before the changelog commit. Use it to write the version into project files, e.g. `sed -i "s/^version = .*/version = \"$VERSION\"/" Cargo.toml`. Every file it changes is committed together with `CHANGELOG.md` in the one `[skip ci]` commit that is then tagged (`git add -A`, so the command should leave no stray files). The command comes from the caller and runs through `bash -c`, never through `${{ }}` in a script. Writing versions for specific file formats is up to the command. Test: `bash tests/version-command.test.sh`.

**Inputs**

<!-- action-docs:inputs source="versioning/gh-release/action.yml" -->
| Name                     | Description                                                                                                                                                                                                                                                                                                                                                                           | Required | Default             |
|--------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|---------------------|
| `version`                | Version to release (e.g. 1.2.3 or 1.2.3-alpha.4)                                                                                                                                                                                                                                                                                                                                      | **Yes**  | —                   |
| `tag-prefix`             | Prefix for the git tag (e.g. "v" → v1.2.3)                                                                                                                                                                                                                                                                                                                                            | No       | v                   |
| `changelog-file`         | Path to a CHANGELOG.md file to extract release notes from                                                                                                                                                                                                                                                                                                                             | No       | CHANGELOG.md        |
| `generate-release-notes` | Fall back to GitHub auto-generated release notes if no changelog section is found                                                                                                                                                                                                                                                                                                     | No       | true                |
| `cliff-config`           | Path to a cliff.toml configuration file for git-cliff. When set, git-cliff generates release notes from Conventional Commits instead of extracting from CHANGELOG.md. Requires git history (fetch-depth: 0).                                                                                                                                                                          | No       |                     |
| `update-changelog`       | When cliff-config is set, regenerate CHANGELOG.md from the full git history and commit it (with [skip ci]) before creating the release tag.                                                                                                                                                                                                                                           | No       | false               |
| `version-command`        | Shell command run after the checkout with VERSION set (the version without tag prefix, e.g. 1.0.0-rc.1), before the changelog commit, to write the version into project files. Every file it changes is committed together with the changelog in the one [skip ci] commit that gets tagged. Empty = off.                                                                              | No       |                     |
| `close-issues`           | After the release, close the issues delivered by a merged release/<x.y> PR still open (versioning/close-release-issues, a safety net: close-merged-issues closes them at merge). Needs issues: write and pull-requests: read; without them the step only prints a warning. A no-op for commits that are not a merged release PR.                                                      | No       | true                |
| `recreate-branch`        | Branch to recreate after the release, normally release/next. When set and the branch does not exist on origin, it is pushed from the released commit; an existing branch is never moved or force-pushed. Empty = off. Needs contents: write; a push made with the default GITHUB_TOKEN triggers no workflows, pass a PAT as token when the new branch must (e.g. release-branch.yml). | No       |                     |
| `token`                  | GitHub token used for checkout and git push operations. Override with a PAT when the default GITHUB_TOKEN cannot push to protected branches.                                                                                                                                                                                                                                          | No       | ${{ github.token }} |
<!-- /action-docs:inputs -->

Test: `bash tests/recreate-branch.test.sh` (local bare origin).

### `versioning/move-major-tag`

Moves the major tag (`v1`) to the commit of a release tag (`v1.4.0`) and force-pushes it, so callers on `@v1` get
every 1.x release. A pre-release (`1.5.0-beta.1`) is skipped; a new major creates `v2` and leaves `v1` where it is.
Idempotent. Run it after `create-version-tag`; the `release` job of this repository's `ci.yml` does.

> **Prerequisite:** The calling workflow must grant `permissions: contents: write`, and no tag ruleset may block
> force-pushing `v*` tags for the workflow token.

**Usage:**

```yaml
  - name: Tag release
    uses: GravionLabs/ci/versioning/create-version-tag@v1
    with:
      version: ${{ steps.version.outputs.semver }}

  - name: Move major tag
    uses: GravionLabs/ci/versioning/move-major-tag@v1
    with:
      version: ${{ steps.version.outputs.semver }}
```

**Inputs**

<!-- action-docs:inputs source="versioning/move-major-tag/action.yml" -->
| Name         | Description                                                                                                         | Required | Default |
|--------------|---------------------------------------------------------------------------------------------------------------------|----------|---------|
| `version`    | Released version (e.g. the semver output of determine-version, e.g. 1.4.0); a pre-release (1.4.0-beta.1) is skipped | **Yes**  | —       |
| `tag-prefix` | Prefix of the release tag and the major tag (e.g. "v" → v1.4.0 and v1)                                              | No       | v       |
<!-- /action-docs:inputs -->

Test: `bash tests/move-major-tag.test.sh`.

### `versioning/mark-merged-issues`

> **Deprecated:** replaced by [`versioning/close-merged-issues`](#versioningclose-merged-issues), which closes the issues at merge instead of labelling them. It prints a `::warning::` when used and will be removed in the next major.

On every push to a `release/*` branch (incl. `release/next`), labels the open issues delivered to it with `merged` and comments once. `close-release-issues` removes the label when the release lands.

With `project-status` set (e.g. `In release`), the project items of the labelled issues also get that Status. The status is applied to the whole labelled set of the run, including issues labelled earlier, so a manually chosen Status may be overwritten; items already `Done` or already at that Status are skipped. A project without a Status option of that name gets one warning. Project failures only warn and never fail the job.

> **Prerequisite:** `permissions: contents: read`, `issues: write`, `pull-requests: read`. The project API needs `project-token`: a classic PAT with scope `project` (fine-grained tokens cannot access user-owned projects). Without project access the step warns once and does not fail.

**Usage:**

```yaml
on:
  push:
    branches: ['release/**']
permissions:
  contents: read
  issues: write
  pull-requests: read

steps:
  - uses: GravionLabs/ci/versioning/mark-merged-issues@v1
    with:
      project-status: In release
      project-token: ${{ secrets.GH_PAT }}
```

**Inputs**

<!-- action-docs:inputs source="versioning/mark-merged-issues/action.yml" -->
| Name             | Description                                                                                | Required | Default             |
|------------------|--------------------------------------------------------------------------------------------|----------|---------------------|
| `release-branch` | Release branch (release/*); defaults to the ref that triggered the workflow                | No       |                     |
| `base`           | Base branch the release lands on; defaults to the repository default branch                | No       |                     |
| `label`          | Label for issues merged into the release branch                                            | No       | merged              |
| `token`          | GitHub token used for the gh CLI                                                           | No       | ${{ github.token }} |
| `dry-run`        | Print the issues that would be labelled without changing anything                          | No       | false               |
| `project-status` | Status to set on the project items of the labelled issues (e.g. "In release"); empty = off | No       |                     |
| `project-token`  | Token for the project API (classic PAT with scope project); defaults to token              | No       |                     |
<!-- /action-docs:inputs -->

**Outputs**

<!-- action-docs:outputs source="versioning/mark-merged-issues/action.yml" -->
| Name       | Description                                                                                           |
|------------|-------------------------------------------------------------------------------------------------------|
| `labelled` | Space-separated numbers of the issues newly labelled in this run (empty when none, also on a dry run) |
<!-- /action-docs:outputs -->

### `versioning/close-merged-issues`

On every push to a `release/*` branch (incl. `release/next`), closes the open issues delivered to it as completed and comments once on each: ``Merged into `<branch>` in #<pr>, ships with <milestone title>.`` (without a milestone: `ships with the next release`; a commit without PR number is named by its short SHA).

- **Closing references:** `Closes`, `Fixes` and `Resolves #n` in the bodies of the PRs merged into the branch since it left the base, and in the footer lines of the commit messages of `base...branch` (not the subject line). `Refs #n` never closes: partial deliveries use it with `## Not delivered`. Pull requests and closed issues are skipped.
- **Parents** labeled `pbi` or `feature` (same repository) whose sub-issues are all closed are closed too, repeating upwards; an `epic` never.
- The label `merged` (set by `mark-merged-issues`) is removed from every issue it closes, so issues labelled before are closed on the first run through the same references.
- Idempotent: a closed issue is skipped, and the comment is written only after the close succeeded, so a rerun closes and comments nothing. Missing permissions only warn (exit 0).

> **Prerequisite:** `permissions: contents: read`, `issues: write`, `pull-requests: read`.

**Usage:**

```yaml
on:
  push:
    branches: ['release/**']
permissions:
  contents: read
  issues: write
  pull-requests: read

steps:
  - uses: GravionLabs/ci/versioning/close-merged-issues@v1
```

**Inputs**

<!-- action-docs:inputs source="versioning/close-merged-issues/action.yml" -->
| Name             | Description                                                                 | Required | Default             |
|------------------|-----------------------------------------------------------------------------|----------|---------------------|
| `release-branch` | Release branch (release/*); defaults to the ref that triggered the workflow | No       |                     |
| `base`           | Base branch the release lands on; defaults to the repository default branch | No       |                     |
| `token`          | GitHub token used for the gh CLI                                            | No       | ${{ github.token }} |
| `dry-run`        | Print the issues that would be closed without changing anything             | No       | false               |
<!-- /action-docs:inputs -->

**Outputs**

<!-- action-docs:outputs source="versioning/close-merged-issues/action.yml" -->
| Name     | Description                                                                                   |
|----------|-----------------------------------------------------------------------------------------------|
| `closed` | Space-separated numbers of the issues closed in this run (empty when none, also on a dry run) |
<!-- /action-docs:outputs -->

Test: `GITHUB_REPOSITORY=<owner/repo> RELEASE_BRANCH=release/next DRY_RUN=true bash versioning/close-merged-issues/close.sh` (`GH_TOKEN` set); unit tests against a fake `gh`: `bash tests/versioning.test.sh`.

---

### `pr-checks.yml`

Reusable workflow with the pull request checks of a repository. Call it from a workflow on `pull_request`; it checks out no code and runs with `permissions: {}` at the top and the least per job.

- **`readiness`** (input `readiness`): runs [`pr-checks/readiness`](#pr-checksreadiness). The PR body must close at least one issue (`Closes|Fixes|Resolves #n`; PRs from `release/**` are exempt, input `require-issue`), and each closed issue must have none of the `not-ready-labels` and no open "blocked by" issue. The job summary lists every problem.
- **`adr`** (input `adr`): runs [`pr-checks/adr`](#pr-checksadr). It reads `.agents/config.json` of the **base** branch; without `governance.adrPaths` it is skipped green with a notice. A PR whose changed files match `governance.adrPaths` (globs), or that closes an issue labelled `needs-decision`, must add or change a `<governance.adrDir>/*.md`; a new ADR needs a `Status:` line (`Proposed`, `Accepted`, `Superseded`, `Deprecated`) and a number not used in `adrDir` of the base branch. A label of `governance.skipLabels` (default `skip-adr`) skips the check and the summary says so. Needs `contents: read`, `issues: read`, `pull-requests: read`.
- **`spec`** (input `spec`): runs [`pr-checks/spec`](#pr-checksspec). It reads `governance.specMap` and `governance.specMode` from `.agents/config.json` of the **base** branch; without a map it is skipped green with a notice. For each map entry (glob to spec path or list of spec paths) with a changed file under the glob but none of its specs changed, `specMode: warn` (default) writes a warning annotation and the summary and passes, `require` fails. A line `no spec change needed` in the PR body turns the failure into a warning, named in the summary. Tests and `.md` files under the globs are not counted. Needs `contents: read`, `pull-requests: read`.
- **`title`** (input `title`): runs [`pr-checks/title`](#pr-checkstitle). The PR title, read through the API (so also after an `edited` event), must match `^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([^)]+\))?!?: .+`. It must agree with the commits (`pulls/<nr>/commits`): if a commit has `!` after its type or a `BREAKING CHANGE:` or `BREAKING-CHANGE:` footer the title needs `!`, and if a commit is `feat:` the title must be `feat`. A PR into the default branch from a branch other than `release/**` (hotfix) also needs every commit to be a Conventional Commit (merge commits are ignored; the API lists at most 250 commits). Release PRs from `release/**` and merge-back PRs (head is the default branch) of the same repository are exempt; a fork branch with such a name is checked. Needs `pull-requests: read`.
- **`result`**, named **`PR checks`**: needs every job, runs always, fails when a job failed or was cancelled and passes on skipped jobs. **This is the only check a ruleset requires**; job names may change, this one must not.

| Input | Default | Description |
|---|---|---|
| `readiness` | `true` | Run the readiness job |
| `adr` | `true` | Run the adr job |
| `spec` | `true` | Run the spec job |
| `title` | `true` | Run the title job |
| `not-ready-labels` | `needs-refinement,needs-decision` | Labels that make a closed issue not ready |
| `require-issue` | `true` | Fail a PR that closes no issue (release PRs exempt) |

The `governance` keys of `.agents/config.json` (names fixed here; GravionLabs/skills#65 that documents them in the skills is pending):

```json
{ "governance": { "adrPaths": ["src/**", "**/*.proto"], "adrDir": "docs/adr", "skipLabels": ["skip-adr"], "specMap": { "src/api/**": "docs/spec/api.md" }, "specMode": "warn" } }
```

```yaml
name: PR checks
on:
  pull_request:
    branches: [main, 'release/**']
    types: [opened, edited, synchronize, reopened]
permissions: {}
jobs:
  pr-checks:
    permissions:
      contents: read
      issues: read
      pull-requests: read
    uses: GravionLabs/ci/.github/workflows/pr-checks.yml@v1
```

A repository that wants only the title check turns the others off:

```yaml
jobs:
  pr-checks:
    permissions:
      pull-requests: read
    uses: GravionLabs/ci/.github/workflows/pr-checks.yml@v1
    with:
      readiness: false
      adr: false
      spec: false
```

> The check name that reaches the ruleset is `<caller job id or name> / PR checks`; keep the caller job id `pr-checks` in every repository so the name is the same everywhere.

This repository's own caller is `.github/workflows/pr-checks-caller.yml`: `title` and `readiness` run, `adr` and `spec` are off.

Tests: `node --test "tests/pr-checks/*.test.mjs"` and `bash tests/pr-checks-workflow.test.sh` (needs `yq` and `jq`); the `test-pr-checks` job of `ci.yml` runs both and runs the action against the pull request.

### `pr-checks/readiness`

Fails when a pull request closes no issue (release PRs exempt) or closes an issue that is not ready: it carries a not-ready label or is blocked by an issue that is still open. Run it on `pull_request`; needs `issues: read` and `pull-requests: read`. The PR body is read through the API, so an edit after the event is seen.

<!-- action-docs:inputs source="pr-checks/readiness/action.yml" -->
| Name               | Description                                                                                    | Required | Default                         |
|--------------------|------------------------------------------------------------------------------------------------|----------|---------------------------------|
| `not-ready-labels` | Comma-separated labels that make an issue not ready                                            | No       | needs-refinement,needs-decision |
| `require-issue`    | Fail when the PR body closes no issue; PRs from release/** branches are exempt (true or false) | No       | true                            |
| `token`            | Token with issues and pull-requests read access                                                | No       | ${{ github.token }}             |
<!-- /action-docs:inputs -->

### `pr-checks/title`

Fails when the pull request title is not a Conventional Commit, contradicts the commits (breaking commit without `!`, `feat:` commit under another type) or, for a hotfix PR into the default branch, when a commit is not a Conventional Commit. Release and merge-back PRs are exempt. Needs `pull-requests: read`.

<!-- action-docs:inputs source="pr-checks/title/action.yml" -->
| Name    | Description                          | Required | Default             |
|---------|--------------------------------------|----------|---------------------|
| `token` | Token with pull-requests read access | No       | ${{ github.token }} |
<!-- /action-docs:inputs -->

### `pr-checks/adr`

Fails when a pull request touches `governance.adrPaths` (or closes an issue labelled `needs-decision`) without an added or changed ADR in `governance.adrDir`, or adds an ADR without a valid `Status:` line or with a number already used on the base branch. A renamed file counts by its new name; a deleted ADR does not count. Config is read from the base branch through the API; without `governance.adrPaths` the action is skipped green. Needs `contents: read`, `issues: read`, `pull-requests: read`.

Limits: glob patterns support `**`, `*` and `?` but not `{a,b}` or `[...]` (such a pattern never matches). `governance.adrDir` is required once `governance.adrPaths` is set. The Status rule needs a `Status:` line; a `## Status` heading does not count.

<!-- action-docs:inputs source="pr-checks/adr/action.yml" -->
| Name    | Description                                               | Required | Default             |
|---------|-----------------------------------------------------------|----------|---------------------|
| `token` | Token with contents, issues and pull-requests read access | No       | ${{ github.token }} |
<!-- /action-docs:inputs -->

### `pr-checks/spec`

Warns (`governance.specMode: warn`, default) or fails (`require`) when a pull request changes files under a glob of `governance.specMap` (glob to spec path, or to a list of spec paths) without changing any mapped spec. A line `no spec change needed` in the PR body (plain, as list item or ticked checkbox) turns a failure into a warning and the summary names it. Tests (`tests/`, `*.test.*`, `*_test.*`, `*.Tests/`) and `.md` files are not counted. Config is read from the base branch through the API; without `governance.specMap` the action is skipped green. Needs `contents: read`, `pull-requests: read`. Same glob limits as `pr-checks/adr`.

<!-- action-docs:inputs source="pr-checks/spec/action.yml" -->
| Name    | Description                                       | Required | Default             |
|---------|---------------------------------------------------|----------|---------------------|
| `token` | Token with contents and pull-requests read access | No       | ${{ github.token }} |
<!-- /action-docs:inputs -->

### `issues/conventions`

Sets the `[Level] ` title prefix from the level label of an issue and flags issues that miss required sections. Run it on `issues` events; used by `issues.yml`.

- **Title:** the first label of `levels` that the issue carries decides the prefix (`epic` becomes `[Epic]`, `pbi` `[PBI]`, others capitalized). Existing leading `[...]` prefixes and the legacy `Epic:`, `Feature:`, `Bug:` prefixes are replaced by exactly one `[Level] `. Issues without a level label are left alone.
- **Sections:** for levels listed in `required-sections`, a missing heading (`##` to `####`, case-insensitive) adds the label `needs-refinement` and one comment (marked with `<!-- gravionlabs-ci:issue-conventions -->`, updated in place, never duplicated). Once all sections exist the label is removed; when the level label changes to one without required sections, the label is removed only if the action set it (its comment says so).
- **Milestone rule** (on `milestoned`/`demilestoned`): an Epic never has a milestone, so it is removed with the comment `An Epic never has a milestone (milestone rule), removed <title>.`. A Feature with a milestone gets one comment (marker `<!-- gravionlabs-ci:milestone-rule -->`, updated in place, set to "resolved" once fixed) listing its open sub-issues outside that milestone (other milestone, none, or another repository) as `<owner>/<repo>#<n> (<milestone|none>)`. A PBI or Bug milestoned or demilestoned re-checks its parent Feature (same repository) the same way. Issues without a level label are left alone.

> **Prerequisite:** `permissions: issues: write`. The default `token` is the `GITHUB_TOKEN`, so the edits it makes trigger no further workflow run.

**Usage:**

```yaml
on:
  issues:
    types: [opened, edited, labeled, unlabeled, reopened]
permissions:
  issues: write

steps:
  - uses: GravionLabs/ci/issues/conventions@v1
    with:
      required-sections: '{"task":["Files","Done when"]}'
```

**Inputs**

<!-- action-docs:inputs source="issues/conventions/action.yml" -->
| Name                | Description                                                                                                                                            | Required | Default                   |
|---------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|----------|---------------------------|
| `levels`            | Comma-separated level labels in precedence order; the label becomes the title prefix (known ones as Epic, Feature, PBI, Task, Bug, others capitalized) | No       | epic,feature,pbi,task,bug |
| `required-sections` | JSON map of level label to required headings, e.g. {"task":["Files","Done when"]}; empty or {} disables the section check                              | No       | {}                        |
| `token`             | Token with issues write access                                                                                                                         | No       | ${{ github.token }}       |
<!-- /action-docs:inputs -->

Test: `node --test "issues/conventions/*.test.mjs"` (quote the glob: Node 24 treats a bare directory as a file); Node 21+).

### `project/needs`

Keeps the project field `Needs` current by running `Sync-ProjectNeeds.ps1` of the skill [`github-project`](.agents/skills/github-project/SKILL.md) of this repository (see [Project standard](docs/project-standard.md)). Used by the `needs` job of `issues.yml`; run it on `issues`, `pull_request_target`, `schedule` or `workflow_dispatch`.

- **Event mode (`mode: event`):** syncs the issue of the event plus its parent. Issue events: `labeled`, `unlabeled`, `closed`, `reopened`, `milestoned`, `demilestoned` (the field `Current`); dependents are synced too on `closed`, `reopened` and when the label `merged` is added or removed. Pull requests (`pull_request_target`): the issue number is the leading number of the head branch after an optional `<prefix>/` (`feat/63-x`, `63-x`); a branch without one logs a notice and does nothing.
- **Full mode (`mode: full`):** syncs every item of the calling repository; `schedule` and `workflow_dispatch` events without a mode do this too.
- **Project mode (`mode: project`):** syncs every item of the project regardless of repository (items are read without the `q=repo:` filter; sub-issue, blocker and pull request lookups use each item's own repository). Wins over `issues`.
- **Security:** nothing is checked out; the script is read from the action's own repository ref, the calling repository and PR code are never checked out, and event data (head ref, label) reaches the script through the environment only.
- **Token:** classic PAT with the scope `project`, plus `repo` for a private repository; a user-owned project is not writable with the `GITHUB_TOKEN`. The step works in a job with `permissions: {}`. No token: one warning, green step.

**Usage:**

```yaml
on:
  schedule:
    - cron: '17 3 * * *'
permissions: {}

steps:
  - uses: GravionLabs/ci/project/needs@v1
    with:
      project-url: https://github.com/users/<owner>/projects/<n>
      mode: project
      token: ${{ secrets.PROJECT_TOKEN }}
```

**Inputs**

<!-- action-docs:inputs source="project/needs/action.yml" -->
| Name          | Description                                                                                                                                                                                                                           | Required | Default |
|---------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|---------|
| `project-url` | Project URL, https://github.com/users/<owner>/projects/<n> or https://github.com/orgs/<owner>/projects/<n>                                                                                                                            | **Yes**  | —       |
| `token`       | Classic PAT with the scope project, plus repo for a private repository (a user-owned project is not writable with the GITHUB_TOKEN); empty skips the sync with a warning                                                              | No       |         |
| `mode`        | event: sync the issue of the event (and its parent, plus dependents on blocker events); full: sync every item of the calling repository; project: sync every item of the project, regardless of repository (the central nightly sync) | No       | event   |
| `issues`      | Issue numbers (space, comma or newline separated) to sync with their parents and dependents; overrides the event (mode full and project still win)                                                                                    | No       |         |
<!-- /action-docs:inputs -->

Test: `bash tests/project-needs.test.sh` (stub `pwsh`, no network).

---

## Rust Actions

### `rust/setup`

Installs the Rust toolchain (the repository's `rust-toolchain.toml`, or an explicit `toolchain`, or stable), adds components and targets, and caches cargo builds with `Swatinem/rust-cache`. With `tauri-linux-deps: 'true'` it installs the Linux system libraries that Tauri 2 needs (webkit2gtk 4.1). The Linux packages (Tauri libraries plus `linux-packages`) come from a GitHub Actions cache (`awalsh128/cache-apt-pkgs-action`, SHA-pinned) keyed by package list and a version string made of `runner.os`, the runner image (`ImageOS`, for example `ubuntu24`) and `apt-cache-version`, so ubuntu-22.04 and ubuntu-24.04 do not share a cache; the mirror is used only on a cache miss. The apt index is refreshed before the cache step (a stale index of the runner image makes the mirror answer 404 for replaced package versions), and the packages are checked afterwards with `dpkg -s`: when one is missing (an empty cache from a failed install), they are installed directly. To bust the cache, change `apt-cache-version` (for example `v2`). On a cache hit the packages are restored without running their install scripts (`execute_install_scripts: false`): fine for `-dev` libraries, but a `linux-packages` entry that needs its postinst script would break only on a hit. Other runners skip the step.

**Usage:**

```yaml
- uses: GravionLabs/ci/rust/setup@v1
  with:
    tauri-linux-deps: 'true'
```

**Inputs**

<!-- action-docs:inputs source="rust/setup/action.yml" -->
| Name                | Description                                                                                                                                                 | Required | Default        |
|---------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|----------------|
| `toolchain`         | Toolchain to install (stable, 1.94.1, ...). Leave empty to use rust-toolchain.toml of the repository, or stable when there is none.                         | No       |                |
| `components`        | Comma-separated components (for example rustfmt,clippy). Added to those of rust-toolchain.toml.                                                             | No       | rustfmt,clippy |
| `targets`           | Comma-separated extra targets (for example aarch64-unknown-linux-gnu)                                                                                       | No       |                |
| `cache`             | Cache cargo builds with Swatinem/rust-cache                                                                                                                 | No       | true           |
| `cache-key`         | Extra cache key, for example the matrix target when several jobs share a runner OS                                                                          | No       |                |
| `workspaces`        | Cargo workspaces for the cache (rust-cache syntax, e.g. ". -> target"). Empty uses the repository root.                                                     | No       |                |
| `tauri-linux-deps`  | Install the system libraries Tauri 2 needs on Linux runners (webkit2gtk 4.1 and friends). Ignored on other runners.                                         | No       | false          |
| `linux-packages`    | Space-separated extra apt packages to install on Linux runners (for example libgtk-layer-shell-dev), besides the Tauri libraries. Ignored on other runners. | No       |                |
| `apt-cache-version` | Cache version of the Linux apt packages (tauri-linux-deps, linux-packages). Change it to discard the cache and download the packages again.                 | No       | v1             |
<!-- /action-docs:inputs -->

---

### `rust/ci`

Runs `cargo fmt --all --check`, `cargo clippy --all-targets -- -D warnings` and `cargo test` after one `rust/setup`. `exclude` leaves crates out of clippy and test (a Tauri crate that needs system libraries), `packages` limits the run to some crates. With `tauri-linux-deps` or `linux-packages` the apt packages come from the cache of `rust/setup`; `apt-cache-version` is forwarded to it, change it (for example `v2`) to bust the cache.

**Usage:**

```yaml
- uses: GravionLabs/ci/rust/ci@v1
  with:
    exclude: 'myapp-tauri'
```

**Inputs**

<!-- action-docs:inputs source="rust/ci/action.yml" -->
| Name                | Description                                                                                                                                 | Required | Default |
|---------------------|---------------------------------------------------------------------------------------------------------------------------------------------|----------|---------|
| `toolchain`         | Toolchain (empty: rust-toolchain.toml, else stable)                                                                                         | No       |         |
| `working-directory` | Directory of the Cargo workspace                                                                                                            | No       | .       |
| `exclude`           | Space-separated crates to leave out of clippy and test (for example a Tauri crate that needs system libraries)                              | No       |         |
| `packages`          | Space-separated crates to check instead of the whole workspace. Takes precedence over exclude.                                              | No       |         |
| `run-fmt`           | Run cargo fmt --check                                                                                                                       | No       | true    |
| `run-clippy`        | Run cargo clippy with -D warnings                                                                                                           | No       | true    |
| `run-tests`         | Run cargo test                                                                                                                              | No       | true    |
| `all-features`      | Pass --all-features to clippy and test                                                                                                      | No       | false   |
| `locked`            | Pass --locked to clippy and test (fail when Cargo.lock needs an update)                                                                     | No       | true    |
| `tauri-linux-deps`  | Install the Tauri system libraries on Linux (needed when a Tauri crate is checked)                                                          | No       | false   |
| `linux-packages`    | Space-separated extra apt packages to install on Linux runners, besides the Tauri libraries                                                 | No       |         |
| `apt-cache-version` | Cache version of the Linux apt packages (tauri-linux-deps, linux-packages). Change it to discard the cache and download the packages again. | No       | v1      |
<!-- /action-docs:inputs -->

---

### `rust/release-binary`

Builds one binary for one target with a given version: writes the version into the workspace `Cargo.toml` for this build only, runs `cargo build --release`, packs the binary with the extra files (`tar.gz`, or `zip` on Windows) and a SHA-256 file, runs a smoke test and uploads the artifact named after the target. Use it in a matrix of targets after `determine-version`; builds that are not releases should pass `0.0.<run number>`.

**Usage:**

```yaml
- uses: GravionLabs/ci/rust/release-binary@v1
  with:
    version: ${{ needs.determine-version.outputs.semver }}
    package: myapp-cli
    binary: myapp
    target: ${{ matrix.target }}
```

**Inputs**

<!-- action-docs:inputs source="rust/release-binary/action.yml" -->
| Name              | Description                                                                                                                                            | Required | Default   |
|-------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|----------|-----------|
| `version`         | Version to build (SemVer). Written into the workspace Cargo.toml for this build only. Non-release builds should pass 0.0.<run number>.                 | **Yes**  | —         |
| `package`         | Crate to build (cargo -p). Several crates are separated by spaces.                                                                                     | **Yes**  | —         |
| `binary`          | Name of the binary the crate produces (without .exe). With several crates, the names of all binaries separated by spaces; the first names the archive. | **Yes**  | —         |
| `target`          | Rust target triple (for example x86_64-unknown-linux-gnu)                                                                                              | **Yes**  | —         |
| `archive-name`    | Base name of the archive. Default: <first binary>-<target>                                                                                             | No       |           |
| `extra-files`     | Space-separated files to pack next to the binary (for example README.md)                                                                               | No       | README.md |
| `smoke-test-args` | Arguments to run the packed binary with as a smoke test (empty to skip)                                                                                | No       | --version |
| `checkout`        | Check out the repository first                                                                                                                         | No       | true      |
| `upload`          | Upload the archive and its checksum as the artifact <target>                                                                                           | No       | true      |
<!-- /action-docs:inputs -->

**Outputs:** `archive` (file name of the archive).

## Tauri Actions

Release the installers of a Tauri 2 application in two steps. A matrix of installer jobs must not each create the release: parallel jobs then end up with two drafts and the assets split between them. `tauri/draft-release` creates the draft once (or finds it), and every `tauri/installers` job uploads into that draft by its id.

```yaml
jobs:
  draft:
    needs: determine-version
    runs-on: ubuntu-latest
    permissions: { contents: write }
    outputs:
      release-id: ${{ steps.draft.outputs.release-id }}
    steps:
      - id: draft
        uses: GravionLabs/ci/tauri/draft-release@v1
        with:
          version: ${{ needs.determine-version.outputs.semver }}

  installers:
    needs: [determine-version, draft]
    strategy:
      fail-fast: false
      matrix:
        include:
          - { os: ubuntu-24.04, target: x86_64-unknown-linux-gnu }
          - { os: macos-latest, target: aarch64-apple-darwin }
          - { os: windows-latest, target: x86_64-pc-windows-msvc }
    runs-on: ${{ matrix.os }}
    permissions: { contents: write }
    steps:
      - uses: GravionLabs/ci/tauri/installers@v1
        with:
          version: ${{ needs.determine-version.outputs.semver }}
          target: ${{ matrix.target }}
          release-id: ${{ needs.draft.outputs.release-id }}
          signing-private-key: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY }}
          signing-private-key-password: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY_PASSWORD }}
```

The publish job then publishes the draft. Only builds from `main` should create the draft; other builds pass no `release-id` and only build.

`latest.json` of the updater is written by every installer job. If concurrent writes still lose a platform (check the published `latest.json`), set `strategy.max-parallel: 1` on the installers job.

### `tauri/draft-release`

**Inputs:** `version` (required), `token` (default `github.token`), `tag-prefix` (default `v`). **Outputs:** `release-id`, `tag`.

### `tauri/installers`

Sets the version in `package.json`, `src-tauri/tauri.conf.json` and `Cargo.toml`, installs Node, Rust (with the Tauri Linux libraries) and the dependencies, and runs `tauri-apps/tauri-action` for the matrix target.

**Inputs**

<!-- action-docs:inputs source="tauri/installers/action.yml" -->
| Name                           | Description                                                                                                                                                                                  | Required | Default                                |
|--------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|----------------------------------------|
| `version`                      | Version to build (SemVer; WiX/MSI needs a numeric one: with a suffix such as 1.2.0-rc003 the MSI is skipped on Windows and only the NSIS installer is built)                                  | **Yes**  | —                                      |
| `target`                       | Rust target triple of this matrix entry                                                                                                                                                      | **Yes**  | —                                      |
| `release-id`                   | Id of the draft release to attach the installers to (output of tauri/draft-release). Empty: build only, upload nothing.                                                                      | No       |                                        |
| `args`                         | Extra arguments for tauri build (for example --config src-tauri/tauri.bundle.conf.json)                                                                                                      | No       |                                        |
| `version-files`                | Space-separated JSON files whose version field is set                                                                                                                                        | No       | package.json src-tauri/tauri.conf.json |
| `cargo-toml`                   | Cargo.toml whose first package/workspace version line is set                                                                                                                                 | No       | Cargo.toml                             |
| `node-version-file`            | File with the Node.js version (for example .nvmrc)                                                                                                                                           | No       | .nvmrc                                 |
| `package-manager`              | pnpm or npm                                                                                                                                                                                  | No       | pnpm                                   |
| `linux-packages`               | Space-separated extra apt packages to install on a Linux runner, besides the Tauri libraries (for example libgtk-layer-shell-dev)                                                            | No       |                                        |
| `apt-cache-version`            | Cache version of the Linux apt packages (tauri-linux-deps, linux-packages). Change it to discard the cache and download the packages again.                                                  | No       | v1                                     |
| `token`                        | GITHUB_TOKEN with contents: write                                                                                                                                                            | No       | ${{ github.token }}                    |
| `signing-private-key`          | Private key that signs the update packages (secret TAURI_SIGNING_PRIVATE_KEY). Empty: unsigned updater artifacts are not created.                                                            | No       |                                        |
| `signing-private-key-password` | Password of the signing key                                                                                                                                                                  | No       |                                        |
| `sidecar-package`              | Crates to build as sidecar binaries (cargo build --release -p …), several separated by spaces. Empty: no sidecars. The binaries are listed in bundle.externalBin of tauri.conf.json.         | No       |                                        |
| `sidecar-binary`               | Names of the binaries the sidecar crates produce (without .exe), several separated by spaces. Each is copied to <sidecar-dir>/<name>-<target>[.exe], the name Tauri expects for externalBin. | No       |                                        |
| `sidecar-dir`                  | Directory for the sidecar files (must match the externalBin paths)                                                                                                                           | No       | src-tauri/binaries                     |
| `checkout`                     | Check out the repository first                                                                                                                                                               | No       | true                                   |
<!-- /action-docs:inputs -->

**Sidecar binaries (`bundle.externalBin`).** Tauri ships extra binaries (a CLI, an MCP server) with the installers when they are listed in `bundle.externalBin` of `tauri.conf.json`. Every entry `<path>/<name>` needs a file `<path>/<name>-<target-triple>[.exe]` before `tauri build`, and ends up as `<name>[.exe]` next to the application executable (Windows install directory, `Contents/MacOS` on macOS) or in `/usr/bin` (`.deb`, `.rpm`). Set `sidecar-package` and `sidecar-binary` and the action builds the crates for `target` after the version was set, copies each binary to `<sidecar-dir>/<name>-<target>[.exe]` and runs `<binary> --version` as a smoke test. `sidecar-dir` must match the `externalBin` path (default `src-tauri/binaries`). Without the inputs nothing changes.

```yaml
- uses: GravionLabs/ci/tauri/installers@v1
  with:
    version: ${{ needs.determine-version.outputs.build-version }}
    target: x86_64-unknown-linux-gnu
    sidecar-package: myapp-cli myapp-mcp
    sidecar-binary: myapp myapp-mcp
# tauri.conf.json: "bundle": { "externalBin": ["binaries/myapp", "binaries/myapp-mcp"] }
```

---

## Reusable Workflow: `tauri-app.yml`

For a Rust CLI, a Tauri 2 application, or both. `determine-version` runs first and every other job reads the version from its outputs. A push to the default branch is a release; every other run builds with `0.0.<run number>` and publishes nothing.

```
determine-version → ci → draft ─→ installers ─┐
                        └──────→ build (CLI) ─┴→ publish → update-changelog
```

**Usage:**

```yaml
name: release
on:
  push:
    branches: [main]
  workflow_dispatch:
concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false
jobs:
  release:
    uses: GravionLabs/ci/.github/workflows/tauri-app.yml@v1
    permissions:
      contents: write
      issues: write
      pull-requests: read
      id-token: write
      attestations: write
    with:
      ci-exclude: myapp-tauri
      cli-package: myapp-cli
      cli-binary: myapp
      tauri: true
      installer-args: --config src-tauri/tauri.bundle.conf.json
    secrets: inherit
```

The caller decides when it runs (the matrix of macOS and Windows runners is expensive: run it on pushes to the default branch and on demand, not on every pull request). Without `cli-package` no CLI binaries are built, without `tauri` no installers.

**Inputs:** `gitversion-config-file` (`GitVersion.yml`), `ci-exclude`, `cli-package` and `cli-binary` (several, separated by spaces, go into one archive per target), `cli-matrix`, `tauri`, `installer-matrix`, `installer-args`, `installer-linux-packages`, `apt-cache-version` (cache version of the apt packages of the Linux installer job only; the checks install none), `installer-sidecars` (JSON `{"package":"…","binary":"…","dir":"…"}`, see `tauri/installers`), `cliff-config` (`cliff.toml`), `recreate-branch` (default empty = off; e.g. `release/next`: after the release the `publish` job pushes the branch from the released commit when it is missing on origin, through `versioning/gh-release/recreate-branch.sh`, never forcing or moving an existing one; set it when the repository deletes merged branches; the push uses the CI app token or `GH_PAT` when set, so the new branch starts `release-branch.yml`, else `github.token`, which starts no workflow). Test: `bash tests/tauri-app-workflow.test.sh`. **Secrets:** `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, `CI_APP_ID`, `CI_APP_PRIVATE_KEY` (GitHub App `GravionLabs CI`, see "GitHub App") and `GH_PAT` (deprecated fallback), all optional.

**Release assets and provenance:** after all uploads the `publish` job downloads the release's assets into a temporary directory under `RUNNER_TEMP` (never into the caller's checkout, so a repository `assets/` directory is not hashed) and writes `SHA256SUMS` over every binary (CLI archives, `.exe`, `.msi`, `.dmg`, `.deb`, `.rpm`, `.AppImage`, `.app.tar.gz`; not `*.sig`, `latest.json` or the earlier `SHA256SUMS`), checks it with `sha256sum -c` and uploads it with `--clobber`. When the calling repository is public (`github.event.repository.private == false`) the SHA-pinned `actions/attest-build-provenance` attests the listed files (`subject-checksums` points to `SHA256SUMS`); a private repository keeps `SHA256SUMS` and skips the attestation without failing. The calling job must grant `id-token: write` and `attestations: write` (besides `contents: write`, `issues: write`, `pull-requests: read`), or the reusable workflow fails at startup. Verify a download:

```bash
sha256sum -c --ignore-missing SHA256SUMS
gh attestation verify <asset> --repo <owner>/<repo>
```

**GitVersion pitfall:** do not pin `next-version` in `GitVersion.yml` to an old minor, or the release is numbered as a patch of that minor (a release of 0.5 was published as 0.4.3). Ask for a minor or major bump with `+semver: minor` or `+semver: major` in a commit message of the release.

---

## Node.js Actions

### `node/setup`

Sets up Node.js with `actions/setup-node`, enables the package manager globally (pnpm via `npm install -g`), and configures caching for the package manager.

**Usage:**

```yaml
- uses: GravionLabs/ci/node/setup@v1
  with:
    node-version: '26'
    package-manager: 'pnpm'
```

**Inputs**

<!-- action-docs:inputs source="node/setup/action.yml" -->
| Name                      | Description                                                                                                                             | Required | Default |
|---------------------------|-----------------------------------------------------------------------------------------------------------------------------------------|----------|---------|
| `node-version`            | Version of Node.js to use (e.g. 24, 26)                                                                                                 | No       | 26      |
| `package-manager`         | Package manager to use (npm, pnpm, yarn)                                                                                                | No       | npm     |
| `package-manager-version` | Version of the package manager to install (e.g. pnpm 11.6.0). Leave empty to auto-detect from the packageManager field in package.json. | No       |         |
<!-- /action-docs:inputs -->

---

### `node/build`

Installs dependencies and builds a Node.js project. Calls `node/setup` internally, then runs the package manager's install command and the configured build command.

**Usage:**

```yaml
- uses: GravionLabs/ci/node/build@v1
  with:
    package-manager: 'pnpm'
```

**Inputs**

<!-- action-docs:inputs source="node/build/action.yml" -->
| Name                      | Description                                                                                                                                        | Required | Default |
|---------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|----------|---------|
| `node-version`            | Version of Node.js to use (e.g. 24, 26)                                                                                                            | No       | 26      |
| `package-manager`         | Package manager to use (npm, pnpm, yarn)                                                                                                           | No       | npm     |
| `package-manager-version` | Version of the package manager to install (e.g. pnpm 11.6.0). Leave empty to auto-detect from the packageManager field in package.json.            | No       |         |
| `working-directory`       | Working directory containing the Node.js project                                                                                                   | No       | .       |
| `build-command`           | Override the build command. If empty, automatically determined from the package-manager input (e.g. npm run build, pnpm run build, yarn run build) | No       |         |
<!-- /action-docs:inputs -->

---

### `node/ci`

Runs lint, build, and test with a single setup and dependency installation. Wraps `node/setup`, lint, `node/build`, and `node/test` in a single action to avoid redundant installs. Lint runs before build for fast failure.

**Usage:**

```yaml
- uses: GravionLabs/ci/node/ci@v1
  with:
    package-manager: 'pnpm'
    run-lint: true
```

**Inputs**

<!-- action-docs:inputs source="node/ci/action.yml" -->
| Name                      | Description                                                                                                                             | Required | Default   |
|---------------------------|-----------------------------------------------------------------------------------------------------------------------------------------|----------|-----------|
| `node-version`            | Version of Node.js to use (e.g. 24, 26)                                                                                                 | No       | 26        |
| `package-manager`         | Package manager to use (npm, pnpm, yarn)                                                                                                | No       | npm       |
| `package-manager-version` | Version of the package manager to install (e.g. pnpm 11.6.0). Leave empty to auto-detect from the packageManager field in package.json. | No       |           |
| `working-directory`       | Working directory containing the Node.js project                                                                                        | No       | .         |
| `run-lint`                | Whether to run the lint step                                                                                                            | No       | true      |
| `lint-command`            | Override the lint command. If empty, auto-detected from package-manager.                                                                | No       |           |
| `build-command`           | Override the build command. If empty, auto-detected from package-manager.                                                               | No       |           |
| `run-tests`               | Whether to run the test suite                                                                                                           | No       | true      |
| `test-command`            | Override the test command. If empty, auto-detected from package-manager.                                                                | No       |           |
| `coverage-format`         | Coverage report format for the summary (cobertura, lcov)                                                                                | No       | cobertura |
| `upload-results`          | Whether to upload test results and coverage report as artifacts                                                                         | No       | true      |
| `publish-results`         | Whether to publish test results as a GitHub Check Run and coverage as a job summary                                                     | No       | true      |
<!-- /action-docs:inputs -->

---

### `node/test`

Runs Node.js unit tests with code coverage collection and result publishing. Calls `node/setup` internally, installs dependencies, runs tests, then uploads results and publishes a coverage summary.

**Usage:**

```yaml
- uses: GravionLabs/ci/node/test@v1
  with:
    package-manager: 'pnpm'
```

**Inputs**

<!-- action-docs:inputs source="node/test/action.yml" -->
| Name                      | Description                                                                                                                                                                                                                         | Required | Default   |
|---------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|-----------|
| `node-version`            | Version of Node.js to use (e.g. 24, 26)                                                                                                                                                                                             | No       | 26        |
| `package-manager`         | Package manager to use (npm, pnpm, yarn)                                                                                                                                                                                            | No       | npm       |
| `package-manager-version` | Version of the package manager to install (e.g. pnpm 11.6.0). Leave empty to auto-detect from the packageManager field in package.json.                                                                                             | No       |           |
| `working-directory`       | Working directory containing the Node.js project                                                                                                                                                                                    | No       | .         |
| `test-command`            | Override the test command. If empty, automatically determined from the package-manager input (e.g. npm run test:ci, pnpm run test:ci, yarn run test:ci). Must produce JUnit XML at test-results/junit.xml and coverage at coverage/ | No       |           |
| `coverage-format`         | Coverage report format for the summary (cobertura, lcov)                                                                                                                                                                            | No       | cobertura |
| `upload-results`          | Whether to upload test results and coverage report as artifacts                                                                                                                                                                     | No       | true      |
| `publish-results`         | Whether to publish test results as a GitHub Check Run and coverage as a job summary                                                                                                                                                 | No       | true      |
<!-- /action-docs:inputs -->

---

### `node/publish`

Configures npm registry authentication and publishes a Node.js package to the target registry. Supports npm, pnpm, and yarn. For pnpm 11+, sets `npm-auth-type=legacy` to skip unsupported OIDC token exchange.

Supports both same-job and cross-job publish patterns:
- **Same job** (after `setup/build/test`): leave `download-artifact: false`
- **Separate job**: set `download-artifact: true` and specify the `artifact-name`

**Usage:**

```yaml
- uses: GravionLabs/ci/node/publish@v1
  with:
    package-manager: 'pnpm'
    registry-url: 'https://npm.pkg.github.com/'
    npm-token: ${{ secrets.GH_PAT }}
```

**Inputs**

<!-- action-docs:inputs source="node/publish/action.yml" -->
| Name                      | Description                                                                                                                                                                                                                                                       | Required | Default                     |
|---------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|-----------------------------|
| `package-manager`         | Package manager to use (npm, pnpm, yarn)                                                                                                                                                                                                                          | No       | npm                         |
| `package-manager-version` | Version of the package manager to install (e.g. pnpm 11.6.0). Leave empty to auto-detect from the packageManager field in package.json.                                                                                                                           | No       |                             |
| `registry-url`            | URL of the npm registry (e.g. https://npm.pkg.github.com/)                                                                                                                                                                                                        | No       | https://npm.pkg.github.com/ |
| `npm-token`               | NPM token or GitHub PAT for registry authentication                                                                                                                                                                                                               | **Yes**  | —                           |
| `publish-command`         | Override the publish command. If empty, automatically determined from package-manager and publish-directory.                                                                                                                                                      | No       |                             |
| `publish-directory`       | Directory to publish from (e.g. dist/my-lib). Appended to the default publish command when no publish-command override is given.                                                                                                                                  | No       |                             |
| `publish-directories`     | Newline-separated directories to publish, one package each (for example several libraries of one workspace). Added to publish-directory; each directory gets the version and its own publish. publish-command runs once per directory with PUBLISH_DIRECTORY set. | No       |                             |
| `working-directory`       | Working directory containing the Node.js project                                                                                                                                                                                                                  | No       | .                           |
| `download-artifact`       | Whether to download the package artifact before publishing (set to true when running in a separate job)                                                                                                                                                           | No       | false                       |
| `artifact-name`           | Name of the artifact to download (only used when download-artifact is true)                                                                                                                                                                                       | No       | npm-package                 |
| `artifact-path`           | Subdirectory (relative to working-directory) the artifact was uploaded from. upload-artifact stores files relative to that directory, so the download restores them under the same prefix. Leave empty when the whole working directory was uploaded.             | No       |                             |
| `version`                 | Version to set in package.json before publishing (e.g. from GitVersion). Applied after artifact download so it works with both local and artifact-based publishing.                                                                                               | No       |                             |
<!-- /action-docs:inputs -->

---

## Docker Actions

### `docker/lint`

Lints a Dockerfile using [hadolint](https://github.com/hadolint/hadolint). Includes checkout.

**Usage:**

```yaml
- uses: GravionLabs/ci/docker/lint@v1
  with:
    dockerfile: Dockerfile
```

<!-- action-docs:inputs source="docker/lint/action.yml" -->
| Name              | Description                                                 | Required | Default    |
|-------------------|-------------------------------------------------------------|----------|------------|
| `dockerfile`      | Path to the Dockerfile to lint                              | No       | Dockerfile |
| `hadolint-config` | Path to a hadolint configuration file (e.g. .hadolint.yaml) | No       |            |
<!-- /action-docs:inputs -->

---

### `docker/build`

Builds a multi-architecture Docker image (ARM64 + AMD64) without pushing. Validates the build succeeds. Includes checkout.

**Usage:**

```yaml
- uses: GravionLabs/ci/docker/build@v1
  with:
    image-name: ghcr.io/org/myapp
```

<!-- action-docs:inputs source="docker/build/action.yml" -->
| Name         | Description                                                         | Required | Default                 |
|--------------|---------------------------------------------------------------------|----------|-------------------------|
| `image-name` | Image name used for labelling (e.g. ghcr.io/org/myapp or org/myapp) | **Yes**  | —                       |
| `dockerfile` | Path to the Dockerfile                                              | No       | Dockerfile              |
| `context`    | Docker build context path                                           | No       | .                       |
| `platforms`  | Comma-separated target platforms (e.g. linux/amd64,linux/arm64)     | No       | linux/amd64,linux/arm64 |
| `build-args` | Newline-separated list of build arguments (KEY=VALUE)               | No       |                         |
<!-- /action-docs:inputs -->

---

### `docker/publish`

Builds and pushes a multi-arch Docker image to a container registry with version tags.
**Does not perform a checkout** — run `docker/build` (or `actions/checkout`) in the same job first.

**Tag strategy:**
- **Always:** `{registry}/{image-name}:{docker-version}` (e.g. `ghcr.io/org/app:1.2.3-abc1234`)
- **On main branch only:** `latest`, `{major}`, `{major}.{minor}`, `{major}.{minor}.{patch}`

**Usage:**

```yaml
- uses: GravionLabs/ci/docker/publish@v1
  with:
    image-name: org/myapp
    registry-username: ${{ github.actor }}
    registry-token: ${{ secrets.GITHUB_TOKEN }}
    docker-version: ${{ steps.version.outputs.docker-version }}
    major: ${{ steps.version.outputs.major }}
    minor: ${{ steps.version.outputs.minor }}
    patch: ${{ steps.version.outputs.patch }}
```

<!-- action-docs:inputs source="docker/publish/action.yml" -->
| Name                | Description                                                                                                               | Required | Default                 |
|---------------------|---------------------------------------------------------------------------------------------------------------------------|----------|-------------------------|
| `image-name`        | Image name without registry prefix (e.g. org/myapp or myapp)                                                              | **Yes**  | —                       |
| `registry`          | Container registry hostname (e.g. ghcr.io, docker.io)                                                                     | No       | ghcr.io                 |
| `registry-username` | Username for authenticating to the registry                                                                               | **Yes**  | —                       |
| `registry-token`    | Token or password for authenticating to the registry                                                                      | **Yes**  | —                       |
| `dockerfile`        | Path to the Dockerfile                                                                                                    | No       | Dockerfile              |
| `context`           | Docker build context path                                                                                                 | No       | .                       |
| `platforms`         | Comma-separated target platforms (e.g. linux/amd64,linux/arm64)                                                           | No       | linux/amd64,linux/arm64 |
| `build-args`        | Newline-separated list of build arguments (KEY=VALUE)                                                                     | No       |                         |
| `docker-version`    | Full Docker version tag including commit hash (e.g. 1.2.3-alpha.4-abc1234) — from determine-version docker-version output | **Yes**  | —                       |
| `major`             | Major version number (e.g. 1) — from determine-version major output                                                       | **Yes**  | —                       |
| `minor`             | Minor version number (e.g. 2) — from determine-version minor output                                                       | **Yes**  | —                       |
| `patch`             | Patch version number (e.g. 3) — from determine-version patch output                                                       | **Yes**  | —                       |
| `main-branch`       | Name of the main branch; semantic version tags are only published from this branch                                        | No       | main                    |
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
    uses: GravionLabs/ci/.github/workflows/nuget-package.yml@v1
    with:
      dotnet-project: 'MyLib.sln'
      test-project: 'test/**/*.Test.csproj'
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
| `dotnet-project`         | Path to a .NET project (.csproj) or solution (.sln/.slnx)    | No       | `**/*.{sln,slnx}` |
| `test-project`          | Path or glob for the test projects to run                     | No       | `test/**/*.Test.csproj`  |
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
| `CI_APP_ID` / `CI_APP_PRIVATE_KEY` | GitHub App `GravionLabs CI` (see above): its token pushes the changelog commit of `update-changelog`; the app must be a ruleset bypass actor |
| `GH_PAT` | Deprecated, fallback without the app: admin PAT for the changelog commit of `update-changelog` when a ruleset requires a pull request on the default branch; falls back to `GITHUB_TOKEN` | No |

> The `publish` job uses `environment: nuget-publish`. Configure this environment in GitHub repository settings to add approval gates or deployment protection rules.

---

### `python-package.yml`

A complete Python CI/CD pipeline: determine version → build → test → publish (on `main` only).
Supports PyPI Trusted Publishing by default; pass `publish-feed-url` + `publish-api-key` for private feeds.

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
    uses: GravionLabs/ci/.github/workflows/python-package.yml@v1
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
| `publish-api-key`    | API token for private feeds; omit for PyPI Trusted Publishing | No |
| `CI_APP_ID` / `CI_APP_PRIVATE_KEY` | GitHub App `GravionLabs CI` (see above): its token pushes the changelog commit of `update-changelog`; the app must be a ruleset bypass actor |
| `GH_PAT` | Deprecated, fallback without the app: admin PAT for the changelog commit of `update-changelog` when a ruleset requires a pull request on the default branch; falls back to `GITHUB_TOKEN` | No |

> The `publish` job uses `environment: pypi-publish`. Configure this environment in GitHub repository settings to add approval gates or deployment protection rules.

---

### `docker-package.yml`

A complete Docker CI/CD pipeline: determine version → lint Dockerfile → build multi-arch image → publish with version tags → create GitHub release (on `main` only).

**Jobs:**
- `determine-version` and `lint` run in parallel for fast feedback
- `build-publish` builds for `linux/amd64` and `linux/arm64` and pushes to the registry
- `release` creates a GitHub Release (on `main` only)

**Tag strategy on `main`:** `latest`, `{major}`, `{major}.{minor}`, `{major}.{minor}.{patch}`, `{docker-version}`  
**Tag strategy on other branches:** `{docker-version}` only (e.g. `1.2.3-alpha.4-abc1234`)

**Usage:**

```yaml
# .github/workflows/docker.yml
on:
  push:
    branches: [main]
  pull_request:

jobs:
  docker:
    uses: GravionLabs/ci/.github/workflows/docker-package.yml@v1
    with:
      image-name: ${{ github.repository }}
    secrets:
      registry-username: ${{ github.actor }}
      registry-token: ${{ secrets.GITHUB_TOKEN }}
    permissions:
      packages: write
      contents: write
```

| Input                   | Required | Default                    | Description                                              |
|-------------------------|----------|----------------------------|----------------------------------------------------------|
| `image-name`            | **Yes**  | —                          | Image name without registry (e.g. `org/myapp`)           |
| `registry`              | No       | `ghcr.io`                  | Container registry hostname                              |
| `dockerfile`            | No       | `Dockerfile`               | Path to the Dockerfile                                   |
| `context`               | No       | `.`                        | Docker build context path                                |
| `platforms`             | No       | `linux/amd64,linux/arm64`  | Comma-separated target platforms                         |
| `build-args`            | No       | `""`                       | Newline-separated build arguments (KEY=VALUE)            |
| `gitversion-config-file`| No       | `""`                       | Path to `GitVersion.yml`                                 |
| `main-branch`           | No       | `main`                     | Branch from which full version tags are published        |
| `force-publish`         | No       | `false`                    | Publish regardless of branch                             |
| `changelog-file`        | No       | `CHANGELOG.md`             | Path to changelog for release notes                      |
| `release-tag-prefix`    | No       | `v`                        | Git tag prefix (e.g. `v` → `v1.2.3`)                    |
| `recreate-branch`       | No       | `""`                       | Branch (e.g. `release/next`) recreated from the released commit when missing; an existing branch is never moved |

| Secret              | Required | Description                                          |
|---------------------|----------|------------------------------------------------------|
| `registry-username` | **Yes**  | Username for the container registry                  |
| `registry-token`    | **Yes**  | Token for the container registry (e.g. `GITHUB_TOKEN` for GHCR) |
| `CI_APP_ID` / `CI_APP_PRIVATE_KEY` | No | GitHub App `GravionLabs CI` (see above); its token pushes the changelog commit of `update-changelog` |
| `GH_PAT`            | No       | Deprecated, fallback without the app: admin PAT for the changelog commit of `update-changelog` when a ruleset requires a pull request on the default branch; falls back to `GITHUB_TOKEN` |

### GitHub App `GravionLabs CI` (CI token)

The CI automation runs as a GitHub App instead of the user PAT `GH_PAT`: an installation token has its own rate limit, so CI no longer competes with local agents for the 5000 GraphQL points per hour of one user. The reusable workflows (`nuget-package.yml`, `python-package.yml`, `docker-package.yml`, `tauri-app.yml`, `release-branch.yml`) and `ci.yml` mint the token with the SHA-pinned `actions/create-github-app-token` when both secrets are set, and pass it where `GH_PAT` was used (release PR, changelog commit). Without the app they fall back to `GH_PAT` (deprecated) and then to `github.token`.

| Secret | Description |
|---|---|
| `CI_APP_ID` | ID of the GitHub App (the numeric App ID, passed as `app-id`) |
| `CI_APP_PRIVATE_KEY` | Private key (PEM, whole file) of the app |

Setup (maintainer, once):

1. Create the app `GravionLabs CI` (Settings > Developer settings > GitHub Apps) with the repository permissions Contents (write), Issues (write), Pull requests (write), Workflows (write, Renovate updates workflow files), Checks (read), Commit statuses (read), Metadata (read). No webhook. Projects permissions do not help: an app cannot access a project owned by a user (see below).
2. Generate a private key, install the app on all GravionLabs repositories.
3. Store `CI_APP_ID` and `CI_APP_PRIVATE_KEY` as organization or per repository secrets (a caller without `secrets: inherit` passes both: `CI_APP_ID: ${{ secrets.CI_APP_ID }}`).
4. Add the app as bypass actor to the rulesets `main` (changelog commit on the default branch requires a pull request) and, where release PRs are created, as needed.
5. Delete the secret `GH_PAT` once every repository runs on the app (it stays supported as a fallback until then).

Project steps keep a classic PAT: project 17 belongs to the user `GravionLabs`, and a GitHub App cannot access user-owned projects (only organization projects; moving to an organization is GravionLabs/ci#128). `PROJECT_TOKEN` is therefore used for `add-to-project`, the Needs sync and the project Status. The Needs sync and the project Status read and write through the REST `projectsV2` endpoints (`GET /users|orgs/<owner>/projectsV2/<n>/fields` and `/items?fields[]=<id>&q=repo:<o/r>`, `PATCH .../items/<id>`) plus the REST issue endpoints (`sub_issues`, `dependencies/blocked_by`, `dependencies/blocking`, `pulls`), so they draw on the REST budget only and make no GraphQL call. What stays on GraphQL: `actions/add-to-project` (external action) and the field/option/view administration of `Set-ProjectStandard.ps1` (no REST update endpoint for single-select options; not part of the CI steps).

Renovate (`renovate.yml`) runs as the app, not as the PAT: it has its own rate limit, its pull requests are authored by the bot (the maintainer can approve them) and, unlike with the `GITHUB_TOKEN`, they trigger the PR checks. It needs the Workflows permission.

### `issues.yml`

Reusable workflow for issue and pull request events, three independent jobs:

- **`add-to-project`** adds new issues and pull requests (`issues` opened, reopened, transferred; `pull_request_target` opened, reopened) to a project with the SHA-pinned `actions/add-to-project`. Off when `project-url` is empty.
- **`conventions`** runs [`issues/conventions`](#issuesconventions) on open issues (`issues` opened, edited, labeled, unlabeled, reopened, milestoned, demilestoned).
- **`needs`** (opt-in, input `needs: true`, requires `project-url`) keeps the project field `Needs` current with [`project/needs`](#projectneeds). Event mode: `issues` labeled, unlabeled, closed, reopened, milestoned, demilestoned and `pull_request_target` opened, closed, ready_for_review (the issue is taken from the head branch); with `mode: full` or on `schedule` / `workflow_dispatch` it syncs every item of the calling repository, with `mode: project` every item of the project, any repository. Per-issue concurrency group, newer runs cancel older ones; `permissions: {}`; never checks out the caller or PR code.

**Usage:**

```yaml
on:
  issues:
    types: [opened, edited, labeled, unlabeled, reopened, transferred, closed, milestoned, demilestoned]
  pull_request_target:
    types: [opened, reopened, closed, ready_for_review]
permissions:
  issues: write
jobs:
  issues:
    uses: GravionLabs/ci/.github/workflows/issues.yml@v1
    with:
      project-url: https://github.com/users/<owner>/projects/<n>
      needs: true
      required-sections: '{"pbi":["Acceptance criteria"],"task":["Files","Done when"]}'
    secrets: inherit
```

This repository calls it from `.github/workflows/issue-events.yml` (workflow "Issue events", formerly `add-to-project.yml`). The extra event types `closed` and `ready_for_review` only matter to the `needs` job; the other jobs ignore them.

**Central nightly sync** (repairs missed events, e.g. a cancelled run): one run per night syncs every item of the project across all repositories (mode `project`). Other repositories of the project need no `project-needs.yml`, only the event caller above. This repository's copy is `.github/workflows/project-needs.yml`; run it in one repository per project:

```yaml
name: Project needs
on:
  schedule:
    - cron: '17 3 * * *'   # off the full hour
  workflow_dispatch:
permissions: {}
jobs:
  needs:
    permissions:
      issues: write   # GitHub validates the permissions of every job of issues.yml at startup
    uses: GravionLabs/ci/.github/workflows/issues.yml@v1
    with:
      project-url: https://github.com/users/<owner>/projects/<n>
      needs: true
      mode: project
    secrets:
      PROJECT_TOKEN: ${{ secrets.PROJECT_TOKEN }}
```

**Inputs**

| Input               | Required | Default                    | Description                                                                                                  |
|---------------------|----------|----------------------------|--------------------------------------------------------------------------------------------------------------|
| `project-url`       | No       | `""`                       | Project URL (`https://github.com/users/<owner>/projects/<n>`); empty disables `add-to-project`               |
| `required-sections` | No       | `{}`                       | JSON map of level label to required headings, e.g. `{"pbi":["Acceptance criteria"],"task":["Files","Done when"]}`; `{}` disables the section check |
| `levels`            | No       | `epic,feature,pbi,task,bug` | Comma-separated level labels in precedence order                                                             |
| `needs`             | No       | `false`                    | Run the `needs` job (requires `project-url`)                                                                 |
| `mode`              | No       | `event`                    | `needs` job: `event` (sync the issue of the event), `full` (every item of the calling repository) or `project` (every item of the project, any repository) |

**Secrets**

| Secret          | Required | Description                                                                                                   |
|-----------------|----------|---------------------------------------------------------------------------------------------------------------|
| `GH_PAT`        | No       | Deprecated, use `PROJECT_TOKEN`: fallback of `PROJECT_TOKEN` |
| `PROJECT_TOKEN` | No       | Classic PAT with the scope `project`, plus `repo` for a private repository, for `add-to-project` and the `needs` job; `PROJECT_TOKEN \|\| GH_PAT` is used |

**Token notes**

- `PROJECT_TOKEN` (for `add-to-project`, else `GH_PAT`) must be a classic PAT with the scopes `project` and `repo`: neither the `GITHUB_TOKEN` nor a GitHub App can write to a user-owned project. Without it the job logs one warning and stays green.
- `needs` uses `secrets.PROJECT_TOKEN || secrets.GH_PAT`: a classic PAT with scope `project`, plus `repo` for a private repository (fine-grained tokens cannot access user-owned projects). No token = one warning, job green. `cancel-in-progress` is on, so a `merged` label event can be cancelled by the next event on the same issue; the central nightly sync repairs it.
- `conventions` writes with the `GITHUB_TOKEN`, so its own edits (title, label, comment) trigger no rerun. The calling job must grant `issues: write`; the workflow requests no more.
- `pull_request_target` is safe here: no job checks out PR code and titles and bodies are only read through the API, never through `${{ }}` expressions. Dependabot and fork PRs receive the secret too.
- Tests: `bash tests/issues-workflow.test.sh` (workflow invariants), `bash tests/project-needs.test.sh` (`project/needs`) and `node --test "issues/conventions/*.test.mjs"`; the `actionlint` job of `ci.yml` lints all workflows.

---

### `release-branch.yml`

Reusable workflow for pushes to a release branch. One job, three steps in order; it has no triggers of its own, the caller triggers it on `push` to `release/**`:

1. `versioning/release-pr` keeps the PR `release: <x.y>` (`release: next` for `release/next`) from the release branch to the default branch open and current (never merges).
2. `versioning/close-merged-issues` closes the open issues merged into the branch (it replaces `mark-merged-issues`, which labelled them). Its output `closed` holds the issues closed in the run. The inputs `label` and `project-status` stay for one major as no-ops: a caller that passes them gets a deprecation warning, not a failure.
3. [`project/needs`](#projectneeds) syncs the project field `Needs` of exactly those issues (input `issues`), with parents and dependents. Skipped when `project-url` is empty or nothing was closed; on a dry run it only prints that it would sync (a dry run closes nothing). Only issues closed in the run are synced: a failed sync is not retried by a rerun, because those issues are then already closed.

A reverted PR: its issues stay closed; reopen them by hand.

This repository calls the workflow itself by its local path: `.github/workflows/release-branch-caller.yml` (push to `release/**`, plus `workflow_dispatch` with `dry-run`).

**One-time run (`workflow_dispatch`):** the caller workflow can also trigger on `workflow_dispatch` with a boolean input `dry-run` that it passes on, so each repository can close today's issues that already carry `merged` without a new push:

```sh
gh workflow run release-branch.yml --ref release/next -f dry-run=true   # prints what would be closed
gh workflow run release-branch.yml --ref release/next                   # closes them
```

```yaml
on:
  push:
    branches: ['release/**']
  workflow_dispatch:
    inputs:
      dry-run:
        type: boolean
        default: false
# ... and in the job: with: { dry-run: "${{ inputs.dry-run || false }}" }
```

No checkout; `permissions: {}` at the top, the job requests `contents: read`, `issues: write`, `pull-requests: write`, which the calling job must grant.

**Usage:**

```yaml
on:
  push:
    branches: ['release/**']
permissions: {}
jobs:
  release-branch:
    permissions:
      contents: read
      issues: write
      pull-requests: write
    uses: GravionLabs/ci/.github/workflows/release-branch.yml@v1
    with:
      project-url: https://github.com/users/<owner>/projects/<n>
    secrets: inherit
```

**Inputs**

| Input            | Required | Default       | Description                                                                                              |
|------------------|----------|---------------|----------------------------------------------------------------------------------------------------------|
| `release-branch` | No       | `""`          | Release branch, e.g. `release/next`; empty = the triggering ref                                          |
| `base`           | No       | `""`          | Base branch of the release PR; empty = the repository default branch                                     |
| `label`          | No       | `""`          | Deprecated no-op (warning when set), removed in the next major                                           |
| `project-status` | No       | `""`          | Deprecated no-op (warning when set), removed in the next major                                           |
| `project-url`    | No       | `""`          | Project URL for the Needs sync of the closed issues; empty disables the sync                           |
| `require-pat`    | No       | `false`       | Fail instead of warning when neither the app secrets nor `GH_PAT` are set                                              |
| `dry-run`        | No       | `false`       | Print what would change without changing anything                                                        |

**Secrets**

| Secret          | Required | Description                                                                                                  |
|-----------------|----------|--------------------------------------------------------------------------------------------------------------|
| `CI_APP_ID`, `CI_APP_PRIVATE_KEY` | No | GitHub App `GravionLabs CI` (see above): its installation token creates the release PR, so the required checks run |
| `GH_PAT`        | No       | Deprecated, fallback without the app: classic PAT with the scope `repo` (and `workflow`) for the release PR |
| `PROJECT_TOKEN` | No       | Classic PAT with the scope `project` (plus `repo` for a private repository) for project Status and Needs; falls back to `GH_PAT` |

**Token requirements**

- A PR created with the `GITHUB_TOKEN` triggers no `pull_request` workflows, so its required checks never run and the PR stays blocked: pass the app secrets (or the deprecated `GH_PAT`). Without them the job warns once and uses the `GITHUB_TOKEN`; with `require-pat: true` it fails.
- The `GITHUB_TOKEN` cannot write to a user-owned project, and fine-grained tokens cannot access user-owned projects: Status and Needs need a classic PAT with the scope `project` (`PROJECT_TOKEN`, or `GH_PAT` carrying `repo`, `workflow` and `project` as one token). Without a project token the project steps warn and the job stays green.
- The secret names match `issues.yml`, so `secrets: inherit` works.
- The actions are referenced at `@v1`, the moving major tag (see "Pinning to a Specific Version").
- Tests: `bash tests/release-branch-workflow.test.sh`; the `actionlint` job of `ci.yml` lints the workflow.

---

### `node/ci`

Composite action that lints, builds, and tests a Node.js project with a single setup and dependency installation. Runs lint before build for fast failure.

**Usage:**

```yaml
- uses: GravionLabs/ci/node/ci@v1
  with:
    node-version: '26'
    working-directory: '.'
    package-manager: 'pnpm'
    run-lint: true
```

**Inputs**

| Name                | Description                                                    | Required | Default                        |
|---------------------|----------------------------------------------------------------|----------|--------------------------------|
| `node-version`      | Node.js version to use                                         | No       | `26`                           |
| `working-directory` | Working directory of the project                               | No       | `.`                            |
| `package-manager`   | Package manager to use (`npm`, `pnpm`, `yarn`)                 | No       | `npm`                          |
| `package-manager-version` | Package manager version (e.g. `11.6.0`). Empty = auto-detect from `packageManager` field | No       | `""`                           |
| `run-lint`          | Whether to run the lint step before build                      | No       | `true`                         |
| `lint-command`      | Override the lint command (empty = auto-detected)              | No       | `""`                           |
| `build-command`     | Override the build command (empty = auto-detected)             | No       | `""`                           |
| `run-tests`         | Whether to run the test suite                                  | No       | `true`                         |
| `test-command`      | Override the test command (empty = auto-detected)              | No       | `""`                           |
| `coverage-format`   | Coverage report format (`cobertura`, `lcov`)                   | No       | `cobertura`                    |
| `upload-results`    | Upload test results and coverage artifacts                     | No       | `true`                         |
| `publish-results`   | Publish test results as a Check Run and coverage summary       | No       | `true`                         |

---

## Pages Actions

### `vitepress-pages.yml`

Builds a VitePress site and deploys it to GitHub Pages; a repository needs only a short caller. Pull requests and manual runs build as a dry run (site tests, dead links, no upload); a push to `main` with `deploy: true` uploads `<site-path>/.vitepress/dist` and deploys (environment `github-pages`). The Node version comes from `.nvmrc`; install uses the lockfile (`npm ci` or `pnpm install --frozen-lockfile` in `site-path`; the lockfile and, for pnpm, the `packageManager` field come from `site-path`, else from the repository root when the site is a workspace member), then `test`, then `build` with `SITE_BASE=/<repository>/`. A pull request replaces its own run, deployments queue.

| Input | Required | Default | Description |
|---|---|---|---|
| `site-path` | No | `site` | Directory of the VitePress site |
| `package-manager` | No | `npm` | `npm` or `pnpm` |
| `pre-build` | No | `""` | Shell command at the repository root after the install |
| `deploy` | No | `true` | `false` builds only, also on `main` |

```yaml
name: Pages
on:
  push:
    branches: [main]
  pull_request:
    paths: ['site/**', '.github/workflows/pages.yml']
  workflow_dispatch:
permissions:
  contents: read
  pages: write
  id-token: write
jobs:
  pages:
    uses: GravionLabs/ci/.github/workflows/vitepress-pages.yml@v1
    with:
      deploy: ${{ vars.DEPLOY_PAGES == 'true' }}
```

Settings -> Pages -> Source must be "GitHub Actions". Test: `bash tests/vitepress-pages-workflow.test.sh`.

---

### `pages/deploy`

> **Deprecated:** use the reusable workflow [`vitepress-pages.yml`](#vitepress-pagesyml). This action and `deploy-pages.yml` are removed in the next major.

Builds a [MkDocs Material](https://squidfunk.github.io/mkdocs-material/) site and uploads it as a GitHub Pages artifact.
**Does not perform a checkout** — the caller is responsible for checking out the repository first.

**Usage:**

```yaml
- uses: actions/checkout@v4
- uses: GravionLabs/ci/pages/deploy@v1
  with:
    mkdocs-config-file: mkdocs.yml
```

<!-- action-docs:inputs source="pages/deploy/action.yml" -->
| Name                 | Description                                             | Required | Default    |
|----------------------|---------------------------------------------------------|----------|------------|
| `docs-path`          | Path to the docs directory (relative to workspace root) | No       | docs       |
| `mkdocs-config-file` | Path to the mkdocs.yml configuration file               | No       | mkdocs.yml |
| `python-version`     | Python version to use for building the docs             | No       | 3.12       |
<!-- /action-docs:inputs -->

---

### `pages/docfx`

Builds a [DocFX](https://dotnet.github.io/docfx/) site from a .NET solution (including XML doc generation) and uploads it as a GitHub Pages artifact.
**Does not perform a checkout** — the caller is responsible for checking out the repository first.

**Usage:**

```yaml
- uses: actions/checkout@v4
- uses: GravionLabs/ci/pages/docfx@v1
  with:
    solution: MyLib.slnx
```

**Full example (Pages job):**

```yaml
pages:
  runs-on: ubuntu-latest
  permissions:
    contents: read
    pages: write
    id-token: write
  environment:
    name: github-pages
    url: ${{ steps.deploy.outputs.page_url }}
  steps:
    - uses: actions/checkout@v4
    - uses: GravionLabs/ci/pages/docfx@v1
      with:
        solution: MyLib.slnx
    - uses: actions/deploy-pages@v4
      id: deploy
```

<!-- action-docs:inputs source="pages/docfx/action.yml" -->
| Name             | Description                                                                          | Required | Default         |
|------------------|--------------------------------------------------------------------------------------|----------|-----------------|
| `dotnet-version` | .NET SDK version to install (e.g. 10.x)                                              | No       | 10.x            |
| `solution`       | Path or glob for the .NET solution or project file to build (for XML doc generation) | No       | **/*.{sln,slnx} |
| `docfx-json`     | Path to the docfx.json configuration file                                            | No       | docfx.json      |
| `site-output`    | Directory where DocFX writes the generated site (must match dest in docfx.json)      | No       | _site           |
<!-- /action-docs:inputs -->

---


## `scripts/Set-RepoRulesets.ps1`

Requires the check of the reusable workflow `pr-checks.yml` in every repository: it adds the context to the `required_status_checks` rule of the existing rulesets `main` (default branch) and `release` (`release/**`), creating the rule, or the ruleset, when missing. An existing ruleset without a `pull_request` rule (`main` or `release`) gets it, so the check applies to PRs. The `pull_request` rule also gets `allowed_merge_methods`: `["merge"]` for `main` (Conventional Commits stay visible to GitVersion and git-cliff), `["merge", "squash"]` for `release`; an existing ruleset is updated when they differ. Other rules, parameters and bypass actors stay; the `required_reviewers` and `require_extra_approval_for_unattributed_changes` parameters are not sent back (the API answers HTTP 422; omitting the flag leaves its default `true`). Only a non-empty `required_reviewers` blocks a ruleset: it is skipped completely (no merge methods and no `PR checks` context), with a warning saying so and exit 1.

```powershell
pwsh scripts/Set-RepoRulesets.ps1 -Repo ci,py-common                # dry run: prints the plan per repository
pwsh scripts/Set-RepoRulesets.ps1 -All -Replace ready -Apply       # every repository; removes the superseded check `ready`
```

| Parameter | Description |
|---|---|
| `-Repo` | Repository names (`name` or `owner/name`) |
| `-All` | Every non-archived repository of `-Owner` (default `GravionLabs`) |
| `-Context` | Required check context, default `PR checks`. GitHub names the check of a reusable-workflow job `<caller job id> / <job name>`; the callers use the job id `pr-checks`, so the check list shows `pr-checks / PR checks`: pass `-Context 'pr-checks / PR checks'` when that is the name that appears |
| `-Replace` | Contexts removed in the same update (e.g. `ready`) |
| `-Apply` | Write the changes; without it the script is a dry run and makes no write call |

- Skipped with a warning: a repository without a caller of `GravionLabs/ci/.github/workflows/pr-checks.yml` under `.github/workflows` (a required check that never runs would block every PR); archived repositories are skipped.
- Token: `gh` with a classic PAT with scope `repo` (administration of the repository, needed to write rulesets) or a fine-grained token with `Administration: write`.
- Rollback: delete the ruleset (the dry run prints the id of each ruleset it would change; Settings > Rules > Rulesets, or `gh api -X DELETE repos/<owner>/<repo>/rulesets/<id>`) and recreate it from the dry run output without the check.
- Tests: `npm test` (`tests/project/set-repo-rulesets.test.ts`, stubbed `gh`, needs pwsh).

## Releasing ci

- Work goes through PRs into the rolling `release/next` branch (CI checks run on those PRs). Hotfixes are the exception: `fix/<nr>-<slug>` from `main`, merged directly into `main`, then merge `main` back into `release/next`.
- `GitVersion.yml` sets only `branches: release: { regex: ^release/next$ }` (no `increment`): the version follows the Conventional Commits, on `release/next` and on `main` alike. `release/next` carries a pre-release version (GitVersion's default label, observed as `1.1.0-beta.1`, not configured here).
- Merging `release/next` into `main` releases the next version; the `release` job of `ci.yml` tags it (`v<x.y.z>`), publishes it and moves the major tag `v<major>` to it (`versioning/move-major-tag`). Callers use `@v1`, never `@main` or a commit SHA.
- **Self-references follow the major tag.** Every `uses: GravionLabs/ci/...` inside this repository (reusable workflows, composite actions) is `@v<major>` of the next release, so a caller on `@v1` runs the actions of the same line. `tests/self-references.test.sh` fails on `@main`, a SHA or another major; a breaking change (`feat!:`) raises them to `@v2` in the same pull request. A caller pinned to an exact `@v1.x.y` still gets the nested actions of `@v1`.
- **The bump comes from Conventional Commits.** `ci.yml` runs `determine-version` with `conventional-commits: 'true'`: a `feat:` commit (squashed PR title) on `release/next` makes the merge into `main` a minor, `<type>!:` or a `BREAKING CHANGE:` footer a major, everything else a patch. No `+semver: minor` footer is needed; `+semver:` stays as an escape hatch. Without the rules a plain `--no-ff` merge is only a patch (GitVersion ignores the branch rule on `main`); `tests/determine-version.test.sh` asserts that, `tests/conventional-commits.test.sh` the Conventional Commit cases.
- Patch releases come only from hotfixes merged directly into `main` (for example `1.1.1`).

---

## Pinning to a Specific Version

> **Use the moving major tag `@v1`.** The `release` job moves `v1` to every 1.x release: fixes and features arrive
> without a pull request, a breaking change becomes `v2` and is taken over deliberately. Do not use `@main` (every
> merge reaches you, breaking or not) or a commit SHA (nobody moves it; the reusable workflows call their actions at
> `@v1` anyway). Renovate: keep `GravionLabs/ci` out of `helpers:pinGitHubActionDigests` (`pinDigests: false`).

```yaml
# Recommended — follows latest v1.x.y patches and features, no breaking changes
uses: GravionLabs/ci/dotnet/build@v1

# Exact release — only to hold back a single release while it is being fixed; nested actions still follow @v1
uses: GravionLabs/ci/dotnet/build@v1.2.3
```

See [CHANGELOG.md](CHANGELOG.md) for what changed between versions.

---

## `wiki/sync`

Syncs `docs/**/*.md` and `README.md` to the GitHub Wiki. Automatically initializes the wiki on first run if no pages have been created yet.

File names are derived from the docs path: `docs/concepts/plugins.md` → `Concepts-Plugins.md`. `README.md` maps to `Home.md`.

> Requires **Wikis** to be enabled in the repository settings (Settings → General → Features → Wikis).

**Usage (via reusable workflow — recommended):**

```yaml
# .github/workflows/sync-wiki.yml
name: Sync Wiki

on:
  push:
    branches: [main]
    paths:
      - 'README.md'
      - 'docs/**/*.md'
  workflow_dispatch:

permissions:
  contents: write

jobs:
  sync-wiki:
    uses: GravionLabs/ci/.github/workflows/sync-wiki.yml@v1
    secrets: inherit
```

**Usage (composite action directly):**

```yaml
- uses: GravionLabs/ci/wiki/sync@v1
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    docs-path: docs          # optional, default: docs
    readme-path: README.md   # optional, default: README.md
```

**Inputs**

| Name          | Description                                                             | Required | Default              |
|---------------|-------------------------------------------------------------------------|----------|----------------------|
| `token`       | GitHub token with `contents: write` permission                          | Yes      |                      |
| `repository`  | Target repository (`owner/repo`). Defaults to the calling repository.   | No       | `github.repository`  |
| `docs-path`   | Path to the docs directory                                              | No       | `docs`               |
| `readme-path` | Path to the README file (maps to `Home.md` in the wiki)                 | No       | `README.md`          |



