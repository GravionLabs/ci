# Changelog

All notable changes to GravionLabs/ci are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/).

Callers should pin to a major version tag (e.g. `@v1`) rather than `@main`.
See [README.md](README.md#pinning-to-a-specific-version) for details.

---

## [1.0.0] — First stable release

### Added

#### Docker Actions
- **`docker/lint`** — Lints Dockerfiles using hadolint. Inputs: `dockerfile`, `hadolint-config`.
- **`docker/build`** — Builds a multi-arch image (`linux/amd64`, `linux/arm64`) without pushing to validate the build. Inputs: `image-name`, `dockerfile`, `context`, `platforms`, `build-args`.
- **`docker/publish`** — Builds and pushes a multi-arch image with semantic version tags. On `main`: publishes `latest`, `{major}`, `{major}.{minor}`, `{major}.{minor}.{patch}` and `{docker-version}`. On other branches: `{docker-version}` only.

#### Reusable Workflows
- **`docker-package.yml`** — Full Docker CI/CD pipeline: `determine-version` ‖ `lint` → `build-publish` → `release`. Supports `workflow_dispatch` with `verbosity` and `force-publish` inputs.
- **`nuget-package.yml`** — Full NuGet CI/CD pipeline: `determine-version` → `build-test-pack` (+ verify) → `publish` → `release`. Supports `workflow_dispatch` with `verbosity` and `force-publish` inputs.
- **`python-package.yml`** — Full Python CI/CD pipeline: `determine-version` → `build-test` → `publish` → `release`. Supports `workflow_dispatch` with `verbosity` and `force-publish` inputs.
- **`node-ci.yml`** — CI pipeline for Node.js: checkout → setup → install → build → test.
- **`sync-wiki.yml`** — Syncs `docs/**/*.md` and `README.md` to the GitHub Wiki.

#### .NET Actions
- **`dotnet/setup`** — Installs .NET SDK, configures NuGet cache, optional private feed.
- **`dotnet/build`** — Checkout + setup + restore + build. Optional `publish: true` for apps. Default `dotnet-project`: `**/*.{sln,slnx}`.
- **`dotnet/test`** — Runs `dotnet test` with Coverlet coverage and TRX logger. Uploads `.trx` test results and coverage XML as artifacts. Default `test-project`: `test/**/*.Test.csproj`.
- **`dotnet/nuget/pack`** — `dotnet pack` → `./nupkgs/`. Uploads `nupkgs` artifact.
- **`dotnet/nuget/publish`** — `dotnet nuget push` to any NuGet feed.
- **`dotnet/nuget/verify-package`** — Verifies expected file paths exist inside a `.nupkg`.

#### Python Actions
- **`python/setup`** — Installs uv and Python with dependency cache keyed on `uv.lock`.
- **`python/build`** — Sets version, syncs dependencies, builds wheel.
- **`python/test`** — Runs pytest with coverage. Uploads results as artifacts.
- **`python/pypi/publish`** — Publishes to PyPI (Trusted Publishing) or a private feed. Credential input: `api-key`.

#### Versioning Actions
- **`versioning/determine-version`** — GitVersion-based semantic versioning. Outputs: `semver`, `major`, `minor`, `patch`, `docker-version`, `nuget-version`, `python-version`, `npm-version`, and more.
- **`versioning/create-version-tag`** — Creates and pushes a `v{version}` git tag. Idempotent.
- **`versioning/gh-release`** — Creates a GitHub Release with optional CHANGELOG section extraction and auto-generated release notes fallback.

#### Infrastructure
- **`wiki/sync`** — Syncs docs to GitHub Wiki via HTTPS token (no SSH key required).
- **`node/setup`** — Installs Node.js with npm cache.

### Parameter Naming Conventions
- Tool-specific identifiers get a tool prefix: `dotnet-version`, `dotnet-project`, `test-project`, `python-version`, `uv-version`, `gitversion-version-spec`, `gitversion-config-file`.
- Credential secrets: `publish-api-key` (not `api-token`).
