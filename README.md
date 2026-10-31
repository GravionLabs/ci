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
└── mark-merged-issues/     # Label issues merged into a release/* branch (removed again by close-release-issues)
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
├── issues.yml              # Reusable issue workflow (add to project, title/section conventions, project Needs)
├── issue-events.yml        # This repository's caller of issues.yml (workflow "Issue events")
├── project-needs.yml       # This repository's hourly full Needs sync (workflow "Project needs")
├── release-branch.yml      # Reusable release-branch workflow (release PR, merged label, project Status, Needs sync)
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
- uses: GravionLabs/ci/dotnet/test@main
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
- uses: GravionLabs/ci/dotnet/nuget/pack@main
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
    dotnet-project: 'MyLib.sln'
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
        uses: GravionLabs/ci/versioning/determine-version@main
```

**Inputs**

<!-- action-docs:inputs source="versioning/determine-version/action.yml" -->
| Name                      | Description                                                                                   | Required | Default |
|---------------------------|-----------------------------------------------------------------------------------------------|----------|---------|
| `gitversion-version-spec` | GitVersion tool version to install (semver range)                                             | No       | 6.x     |
| `gitversion-config-file`  | Path to the GitVersion.yml configuration file (optional, uses GitVersion defaults if not set) | No       |         |
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

### `versioning/mark-merged-issues`

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
  - uses: GravionLabs/ci/versioning/mark-merged-issues@main
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

---

### `issues/conventions`

Sets the `[Level] ` title prefix from the level label of an issue and flags issues that miss required sections. Run it on `issues` events; used by `issues.yml`.

- **Title:** the first label of `levels` that the issue carries decides the prefix (`epic` becomes `[Epic]`, `pbi` `[PBI]`, others capitalized). Existing leading `[...]` prefixes and the legacy `Epic:`, `Feature:`, `Bug:` prefixes are replaced by exactly one `[Level] `. Issues without a level label are left alone.
- **Sections:** for levels listed in `required-sections`, a missing heading (`##` to `####`, case-insensitive) adds the label `needs-refinement` and one comment (marked with `<!-- gravionlabs-ci:issue-conventions -->`, updated in place, never duplicated). Once all sections exist the label is removed; when the level label changes to one without required sections, the label is removed only if the action set it (its comment says so).

> **Prerequisite:** `permissions: issues: write`. The default `token` is the `GITHUB_TOKEN`, so the edits it makes trigger no further workflow run.

**Usage:**

```yaml
on:
  issues:
    types: [opened, edited, labeled, unlabeled, reopened]
permissions:
  issues: write

steps:
  - uses: GravionLabs/ci/issues/conventions@main
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

Keeps the project field `Needs` current by running `Sync-ProjectNeeds.ps1` of the skill [`github-project`](.apm/skills/github-project/SKILL.md) of this repository (see [Project standard](docs/project-standard.md)). Used by the `needs` job of `issues.yml`; run it on `issues`, `pull_request_target`, `schedule` or `workflow_dispatch`.

- **Event mode (`mode: event`):** syncs the issue of the event plus its parent. Issue events: `labeled`, `unlabeled`, `closed`, `reopened`; dependents are synced too on `closed`, `reopened` and when the label `merged` is added or removed. Pull requests (`pull_request_target`): the issue number is the leading number of the head branch after an optional `<prefix>/` (`feat/63-x`, `63-x`); a branch without one logs a notice and does nothing.
- **Full mode (`mode: full`):** syncs every item of the repository; `schedule` and `workflow_dispatch` events always do this.
- **Security:** nothing is checked out; the script is read from the action's own repository ref, the calling repository and PR code are never checked out, and event data (head ref, label) reaches the script through the environment only.
- **Token:** classic PAT with the scope `project`, plus `repo` for a private repository; a user-owned project is not writable with the `GITHUB_TOKEN`. The step works in a job with `permissions: {}`. No token: one warning, green step.

**Usage:**

```yaml
on:
  schedule:
    - cron: '0 * * * *'
permissions: {}

steps:
  - uses: GravionLabs/ci/project/needs@main
    with:
      project-url: https://github.com/users/<owner>/projects/<n>
      mode: full
      token: ${{ secrets.PROJECT_TOKEN }}
```

**Inputs**

<!-- action-docs:inputs source="project/needs/action.yml" -->
| Name          | Description                                                                                                                                                              | Required | Default |
|---------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|---------|
| `project-url` | Project URL, https://github.com/users/<owner>/projects/<n> or https://github.com/orgs/<owner>/projects/<n>                                                               | **Yes**  | —       |
| `token`       | Classic PAT with the scope project, plus repo for a private repository (a user-owned project is not writable with the GITHUB_TOKEN); empty skips the sync with a warning | No       |         |
| `mode`        | event: sync the issue of the event (and its parent, plus dependents on blocker events); full: sync every item of the repository                                          | No       | event   |
| `issues`      | Issue numbers (space, comma or newline separated) to sync with their parents and dependents; overrides the event (mode full still wins)                                  | No       |         |
<!-- /action-docs:inputs -->

Test: `bash tests/project-needs.test.sh` (stub `pwsh`, no network).

---

## Rust Actions

### `rust/setup`

Installs the Rust toolchain (the repository's `rust-toolchain.toml`, or an explicit `toolchain`, or stable), adds components and targets, and caches cargo builds with `Swatinem/rust-cache`. With `tauri-linux-deps: 'true'` it installs the Linux system libraries that Tauri 2 needs (webkit2gtk 4.1).

**Usage:**

```yaml
- uses: GravionLabs/ci/rust/setup@main
  with:
    tauri-linux-deps: 'true'
```

**Inputs**

<!-- action-docs:inputs source="rust/setup/action.yml" -->
| Name               | Description                                                                                                                                                 | Required | Default        |
|--------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|----------------|
| `toolchain`        | Toolchain to install (stable, 1.94.1, ...). Leave empty to use rust-toolchain.toml of the repository, or stable when there is none.                         | No       |                |
| `components`       | Comma-separated components (for example rustfmt,clippy). Added to those of rust-toolchain.toml.                                                             | No       | rustfmt,clippy |
| `targets`          | Comma-separated extra targets (for example aarch64-unknown-linux-gnu)                                                                                       | No       |                |
| `cache`            | Cache cargo builds with Swatinem/rust-cache                                                                                                                 | No       | true           |
| `cache-key`        | Extra cache key, for example the matrix target when several jobs share a runner OS                                                                          | No       |                |
| `workspaces`       | Cargo workspaces for the cache (rust-cache syntax, e.g. ". -> target"). Empty uses the repository root.                                                     | No       |                |
| `tauri-linux-deps` | Install the system libraries Tauri 2 needs on Linux runners (webkit2gtk 4.1 and friends). Ignored on other runners.                                         | No       | false          |
| `linux-packages`   | Space-separated extra apt packages to install on Linux runners (for example libgtk-layer-shell-dev), besides the Tauri libraries. Ignored on other runners. | No       |                |
<!-- /action-docs:inputs -->

---

### `rust/ci`

Runs `cargo fmt --all --check`, `cargo clippy --all-targets -- -D warnings` and `cargo test` after one `rust/setup`. `exclude` leaves crates out of clippy and test (a Tauri crate that needs system libraries), `packages` limits the run to some crates.

**Usage:**

```yaml
- uses: GravionLabs/ci/rust/ci@main
  with:
    exclude: 'myapp-tauri'
```

**Inputs**

<!-- action-docs:inputs source="rust/ci/action.yml" -->
| Name                | Description                                                                                                    | Required | Default |
|---------------------|----------------------------------------------------------------------------------------------------------------|----------|---------|
| `toolchain`         | Toolchain (empty: rust-toolchain.toml, else stable)                                                            | No       |         |
| `working-directory` | Directory of the Cargo workspace                                                                               | No       | .       |
| `exclude`           | Space-separated crates to leave out of clippy and test (for example a Tauri crate that needs system libraries) | No       |         |
| `packages`          | Space-separated crates to check instead of the whole workspace. Takes precedence over exclude.                 | No       |         |
| `run-fmt`           | Run cargo fmt --check                                                                                          | No       | true    |
| `run-clippy`        | Run cargo clippy with -D warnings                                                                              | No       | true    |
| `run-tests`         | Run cargo test                                                                                                 | No       | true    |
| `all-features`      | Pass --all-features to clippy and test                                                                         | No       | false   |
| `locked`            | Pass --locked to clippy and test (fail when Cargo.lock needs an update)                                        | No       | true    |
| `tauri-linux-deps`  | Install the Tauri system libraries on Linux (needed when a Tauri crate is checked)                             | No       | false   |
| `linux-packages`    | Space-separated extra apt packages to install on Linux runners, besides the Tauri libraries                    | No       |         |
<!-- /action-docs:inputs -->

---

### `rust/release-binary`

Builds one binary for one target with a given version: writes the version into the workspace `Cargo.toml` for this build only, runs `cargo build --release`, packs the binary with the extra files (`tar.gz`, or `zip` on Windows) and a SHA-256 file, runs a smoke test and uploads the artifact named after the target. Use it in a matrix of targets after `determine-version`; builds that are not releases should pass `0.0.<run number>`.

**Usage:**

```yaml
- uses: GravionLabs/ci/rust/release-binary@main
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
        uses: GravionLabs/ci/tauri/draft-release@main
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
      - uses: GravionLabs/ci/tauri/installers@main
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
| `version`                      | Version to build (SemVer; MSI needs a numeric one, so non-release builds pass 0.0.<run number>)                                                                                              | **Yes**  | —                                      |
| `target`                       | Rust target triple of this matrix entry                                                                                                                                                      | **Yes**  | —                                      |
| `release-id`                   | Id of the draft release to attach the installers to (output of tauri/draft-release). Empty: build only, upload nothing.                                                                      | No       |                                        |
| `args`                         | Extra arguments for tauri build (for example --config src-tauri/tauri.bundle.conf.json)                                                                                                      | No       |                                        |
| `version-files`                | Space-separated JSON files whose version field is set                                                                                                                                        | No       | package.json src-tauri/tauri.conf.json |
| `cargo-toml`                   | Cargo.toml whose first package/workspace version line is set                                                                                                                                 | No       | Cargo.toml                             |
| `node-version-file`            | File with the Node.js version (for example .nvmrc)                                                                                                                                           | No       | .nvmrc                                 |
| `package-manager`              | pnpm or npm                                                                                                                                                                                  | No       | pnpm                                   |
| `linux-packages`               | Space-separated extra apt packages to install on a Linux runner, besides the Tauri libraries (for example libgtk-layer-shell-dev)                                                            | No       |                                        |
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
- uses: GravionLabs/ci/tauri/installers@main
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
    uses: GravionLabs/ci/.github/workflows/tauri-app.yml@main
    permissions:
      contents: write
    with:
      ci-exclude: myapp-tauri
      cli-package: myapp-cli
      cli-binary: myapp
      tauri: true
      installer-args: --config src-tauri/tauri.bundle.conf.json
    secrets: inherit
```

The caller decides when it runs (the matrix of macOS and Windows runners is expensive: run it on pushes to the default branch and on demand, not on every pull request). Without `cli-package` no CLI binaries are built, without `tauri` no installers.

**Inputs:** `gitversion-config-file` (`GitVersion.yml`), `ci-exclude`, `cli-package` and `cli-binary` (several, separated by spaces, go into one archive per target), `cli-matrix`, `tauri`, `installer-matrix`, `installer-args`, `installer-linux-packages`, `installer-sidecars` (JSON `{"package":"…","binary":"…","dir":"…"}`, see `tauri/installers`), `cliff-config` (`cliff.toml`). **Secrets:** `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` (optional).

**GitVersion pitfall:** do not pin `next-version` in `GitVersion.yml` to an old minor, or the release is numbered as a patch of that minor (a release of 0.5 was published as 0.4.3). Ask for a minor or major bump with `+semver: minor` or `+semver: major` in a commit message of the release.

---

## Node.js Actions

### `node/setup`

Sets up Node.js with `actions/setup-node`, enables the package manager globally (pnpm via `npm install -g`), and configures caching for the package manager.

**Usage:**

```yaml
- uses: GravionLabs/ci/node/setup@main
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
- uses: GravionLabs/ci/node/build@main
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
- uses: GravionLabs/ci/node/ci@main
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
- uses: GravionLabs/ci/node/test@main
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
- uses: GravionLabs/ci/node/publish@main
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
- uses: GravionLabs/ci/docker/lint@main
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
- uses: GravionLabs/ci/docker/build@main
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
- uses: GravionLabs/ci/docker/publish@main
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
    uses: GravionLabs/ci/.github/workflows/nuget-package.yml@main
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
| `publish-api-key`    | API token for private feeds; omit for PyPI Trusted Publishing | No |

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

| Secret              | Required | Description                                          |
|---------------------|----------|------------------------------------------------------|
| `registry-username` | **Yes**  | Username for the container registry                  |
| `registry-token`    | **Yes**  | Token for the container registry (e.g. `GITHUB_TOKEN` for GHCR) |

### `issues.yml`

Reusable workflow for issue and pull request events, three independent jobs:

- **`add-to-project`** adds new issues and pull requests (`issues` opened, reopened, transferred; `pull_request_target` opened, reopened) to a project with the SHA-pinned `actions/add-to-project`. Off when `project-url` is empty.
- **`conventions`** runs [`issues/conventions`](#issuesconventions) on open issues (`issues` opened, edited, labeled, unlabeled, reopened).
- **`needs`** (opt-in, input `needs: true`, requires `project-url`) keeps the project field `Needs` current with [`project/needs`](#projectneeds). Event mode: `issues` labeled, unlabeled, closed, reopened and `pull_request_target` opened, closed, ready_for_review (the issue is taken from the head branch); with `mode: full` or on `schedule` / `workflow_dispatch` it syncs every item. Per-issue concurrency group, newer runs cancel older ones; `permissions: {}`; never checks out the caller or PR code.

**Usage:**

```yaml
on:
  issues:
    types: [opened, edited, labeled, unlabeled, reopened, transferred, closed]
  pull_request_target:
    types: [opened, reopened, closed, ready_for_review]
permissions:
  issues: write
jobs:
  issues:
    uses: GravionLabs/ci/.github/workflows/issues.yml@main
    with:
      project-url: https://github.com/users/<owner>/projects/<n>
      needs: true
      required-sections: '{"pbi":["Acceptance criteria"],"task":["Files","Done when"]}'
    secrets: inherit
```

This repository calls it from `.github/workflows/issue-events.yml` (workflow "Issue events", formerly `add-to-project.yml`). The extra event types `closed` and `ready_for_review` only matter to the `needs` job; the other jobs ignore them.

**Hourly full sync** (repairs missed events, e.g. a cancelled run); this repository's copy is `.github/workflows/project-needs.yml`:

```yaml
name: Project needs
on:
  schedule:
    - cron: '0 * * * *'
  workflow_dispatch:
permissions: {}
jobs:
  needs:
    permissions:
      issues: write   # GitHub validates the permissions of every job of issues.yml at startup
    uses: GravionLabs/ci/.github/workflows/issues.yml@main
    with:
      project-url: https://github.com/users/<owner>/projects/<n>
      needs: true
      mode: full
    secrets:
      GH_PAT: ${{ secrets.GH_PAT }}
      PROJECT_TOKEN: ${{ secrets.PROJECT_TOKEN }}
```

**Inputs**

| Input               | Required | Default                    | Description                                                                                                  |
|---------------------|----------|----------------------------|--------------------------------------------------------------------------------------------------------------|
| `project-url`       | No       | `""`                       | Project URL (`https://github.com/users/<owner>/projects/<n>`); empty disables `add-to-project`               |
| `required-sections` | No       | `{}`                       | JSON map of level label to required headings, e.g. `{"pbi":["Acceptance criteria"],"task":["Files","Done when"]}`; `{}` disables the section check |
| `levels`            | No       | `epic,feature,pbi,task,bug` | Comma-separated level labels in precedence order                                                             |
| `needs`             | No       | `false`                    | Run the `needs` job (requires `project-url`)                                                                 |
| `mode`              | No       | `event`                    | `needs` job: `event` (sync the issue of the event) or `full` (sync every item of the repository)             |

**Secrets**

| Secret          | Required | Description                                                                                                   |
|-----------------|----------|---------------------------------------------------------------------------------------------------------------|
| `GH_PAT`        | No       | Classic PAT with the scopes `project` and `repo`, for `add-to-project` (and `needs` when `PROJECT_TOKEN` is unset) |
| `PROJECT_TOKEN` | No       | Classic PAT with the scope `project`, plus `repo` for a private repository, for the `needs` job; `PROJECT_TOKEN \|\| GH_PAT` is used |

**Token notes**

- `GH_PAT` must be a classic PAT with the scopes `project` and `repo`: the `GITHUB_TOKEN` cannot write to a user-owned project. Without it the job logs one warning and stays green.
- `needs` uses `secrets.PROJECT_TOKEN || secrets.GH_PAT`: a classic PAT with scope `project`, plus `repo` for a private repository (fine-grained tokens cannot access user-owned projects). No token = one warning, job green. `cancel-in-progress` is on, so a `merged` label event can be cancelled by the next event on the same issue; the hourly full sync repairs it.
- `conventions` writes with the `GITHUB_TOKEN`, so its own edits (title, label, comment) trigger no rerun. The calling job must grant `issues: write`; the workflow requests no more.
- `pull_request_target` is safe here: no job checks out PR code and titles and bodies are only read through the API, never through `${{ }}` expressions. Dependabot and fork PRs receive the secret too.
- Tests: `bash tests/issues-workflow.test.sh` (workflow invariants), `bash tests/project-needs.test.sh` (`project/needs`) and `node --test "issues/conventions/*.test.mjs"`; the `actionlint` job of `ci.yml` lints all workflows.

---

### `release-branch.yml`

Reusable workflow for pushes to a release branch. One job, three steps in order; it has no triggers of its own, the caller triggers it on `push` to `release/**`:

1. `versioning/release-pr` keeps the PR `release: <x.y>` from the release branch to the default branch open and current (never merges).
2. `versioning/mark-merged-issues` labels the open issues merged into the branch (input `label`) and, with `project-status`, sets that project Status. Its output `labelled` holds the issues newly labelled in the run.
3. [`project/needs`](#projectneeds) syncs the project field `Needs` of exactly those issues (input `issues`), with parents and dependents. Skipped when `project-url` is empty or nothing was labelled; on a dry run it only prints that it would sync (a dry run labels nothing). Only issues newly labelled in the run are synced: a failed sync is not retried by a rerun, because those issues are then already labelled.

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
    uses: GravionLabs/ci/.github/workflows/release-branch.yml@main
    with:
      project-url: https://github.com/users/<owner>/projects/<n>
    secrets: inherit
```

**Inputs**

| Input            | Required | Default       | Description                                                                                              |
|------------------|----------|---------------|----------------------------------------------------------------------------------------------------------|
| `release-branch` | No       | `""`          | Release branch, e.g. `release/next`; empty = the triggering ref                                          |
| `base`           | No       | `""`          | Base branch of the release PR; empty = the repository default branch                                     |
| `label`          | No       | `merged`      | Label set on the issues merged into the release branch                                                   |
| `project-status` | No       | `In release`  | Project Status set on the project items of the labelled issues; empty disables it                        |
| `project-url`    | No       | `""`          | Project URL for the Needs sync of the labelled issues; empty disables the sync                           |
| `require-pat`    | No       | `false`       | Fail instead of warning when the secret `GH_PAT` is missing                                              |
| `dry-run`        | No       | `false`       | Print what would change without changing anything                                                        |

**Secrets**

| Secret          | Required | Description                                                                                                  |
|-----------------|----------|--------------------------------------------------------------------------------------------------------------|
| `GH_PAT`        | No       | Classic PAT with the scope `repo` (and `workflow` when the release PR changes workflow files) for the release PR |
| `PROJECT_TOKEN` | No       | Classic PAT with the scope `project` (plus `repo` for a private repository) for project Status and Needs; falls back to `GH_PAT` |

**Token requirements**

- A PR created with the `GITHUB_TOKEN` triggers no `pull_request` workflows, so its required checks never run and the PR stays blocked: pass `GH_PAT`. Without it the job warns once and uses the `GITHUB_TOKEN`; with `require-pat: true` it fails.
- The `GITHUB_TOKEN` cannot write to a user-owned project, and fine-grained tokens cannot access user-owned projects: Status and Needs need a classic PAT with the scope `project` (`PROJECT_TOKEN`, or `GH_PAT` carrying `repo`, `workflow` and `project` as one token). Without a project token the project steps warn and the job stays green.
- The secret names match `issues.yml`, so `secrets: inherit` works.
- The actions are referenced at `@main`: the workflow works for callers once those versions are released.
- Tests: `bash tests/release-branch-workflow.test.sh`; the `actionlint` job of `ci.yml` lints the workflow.

---

### `node/ci`

Composite action that lints, builds, and tests a Node.js project with a single setup and dependency installation. Runs lint before build for fast failure.

**Usage:**

```yaml
- uses: GravionLabs/ci/node/ci@main
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

### `pages/deploy`

Builds a [MkDocs Material](https://squidfunk.github.io/mkdocs-material/) site and uploads it as a GitHub Pages artifact.
**Does not perform a checkout** — the caller is responsible for checking out the repository first.

**Usage:**

```yaml
- uses: actions/checkout@v4
- uses: GravionLabs/ci/pages/deploy@main
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
- uses: GravionLabs/ci/pages/docfx@main
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
    - uses: GravionLabs/ci/pages/docfx@main
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

Requires the check of the reusable workflow `pr-checks.yml` in every repository: it adds the context to the `required_status_checks` rule of the existing rulesets `main` (default branch) and `release` (`release/**`), creating the rule, or the ruleset, when missing. `release` also gets the `pull_request` rule so the check applies to PRs into release branches. Other rules and other required checks stay.

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
- `GitVersion.yml` sets `branches: release: { regex: ^release/next$, increment: Minor }`, so `release/next` gets a `1.1.0` pre-release version (GitVersion's default label, observed as `1.1.0-beta.1`, not configured here).
- Merging `release/next` into `main` releases the next version; the `release` job of `ci.yml` tags and publishes it. Callers keep using `@main`.
- **A plain merge is only a patch.** GitVersion on `main` ignores the branch rule after a `--no-ff` merge and yields `1.0.61`, not `1.1.0`. The minor bump needs a `+semver: minor` footer in a commit message that reaches `main`: put it in the merge commit message (or squash message) of the release PR, or in a commit on `release/next`. `versioning/release-pr` does not add it; it must be added by hand when merging. `tests/determine-version.test.sh` asserts both cases.
- Patch releases come only from hotfixes merged directly into `main` (for example `1.1.1`).

---

## Pinning to a Specific Version

> **Recommendation:** Pin to a major version tag (e.g. `@v1`) in production workflows.
> Using `@main` will always track the latest code, which may include breaking changes.

```yaml
# Recommended — follows latest v1.x.y patches and features, no breaking changes
uses: GravionLabs/ci/dotnet/build@v1

# Pinned to exact release — maximum stability
uses: GravionLabs/ci/dotnet/build@v1.2.3

# Pinned to commit SHA — maximum reproducibility
uses: GravionLabs/ci/dotnet/build@<commit-sha>

# Tracks latest (may include breaking changes)
uses: GravionLabs/ci/dotnet/build@main
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
    uses: GravionLabs/ci/.github/workflows/sync-wiki.yml@main
    secrets: inherit
```

**Usage (composite action directly):**

```yaml
- uses: GravionLabs/ci/wiki/sync@main
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



