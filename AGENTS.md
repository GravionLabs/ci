# AGENTS.md

## Repository Snapshot

`GravionLabs/ci` provides reusable GitHub Actions composite actions and reusable workflows for .NET, Python, and Docker CI/CD pipelines.

## Repo Map

```
versioning/
  determine-version/    — GitVersion-based semantic versioning (outputs: semver, nuget-version, python-version, docker-version, major, minor, patch, …)
  create-version-tag/   — Creates and pushes a git tag from a version string
  gh-release/           — Creates a GitHub Release with optional changelog extraction
  release-pr/           — Keeps one PR from release/<x.y> to the default branch open and current (title, merged PRs, Closes lines); never merges
  close-release-issues/ — After a release/<x.y> branch merged into main, closes the delivered issues (Closes #n in the merged PRs, their sub-issues, fully delivered pbi/feature parents) and removes their `merged` label
  mark-merged-issues/   — On every push to release/* (incl. release/next), labels the open issues merged into it `merged` (Closes #n in merged PRs, Closes/Refs #n in commits, complete pbi/feature parents; optional project Status via `project-status`)

issues/
  conventions/          — Sets the `[Level] ` title prefix from the level label (legacy `Epic:`/`Feature:`/`Bug:` prefixes replaced) and flags missing required sections with `needs-refinement`

project/
  needs/                — Keeps the project field Needs current: runs Sync-ProjectNeeds.ps1 of the skill `.apm/skills/github-project` of this repository (inputs `project-url`, `token`, `mode`, `issues`)

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

rust/
  setup/                — Installs the Rust toolchain, caches cargo (optionally Tauri Linux libraries)
  ci/                   — cargo fmt --check, clippy -D warnings, test
  release-binary/       — Builds, packs (tar.gz/zip + SHA-256), smoke tests and uploads versioned binaries for one target

tauri/
  draft-release/        — Creates or finds the draft release of a version (shared by parallel installer jobs)
  installers/           — Versioned Tauri 2 installers for one runner; optional sidecars (`sidecar-package`, `sidecar-binary`, `sidecar-dir`) for `bundle.externalBin`

node/
  setup/ build/ test/ ci/ publish/ — Node.js actions; `publish` takes `publish-directory` / `publish-directories`

.apm/skills/github-project/  — APM package `github-project` (apm.yml): the user-invoked skill (`apply|sync|new|sprints|sprint`), `scripts/` (Set-ProjectStandard, Sync-ProjectNeeds, Set-Sprint, NeedsRules.psm1), `templates/` (callers `issue-events.yml`, `project-needs.yml`); the standard is described in `docs/project-standard.md`

.github/workflows/
  nuget-package.yml     — Full NuGet CI/CD: determine-version → build-test-pack (+ verify) → publish (main only)
  python-package.yml    — Full Python CI/CD: determine-version → build-test → publish (main only)
  docker-package.yml    — Full Docker CI/CD: determine-version ‖ lint → build-publish → release (main only)
  node-package.yml      — Full Node.js Package CI/CD: determine-version ‖ ci → publish → release
  angular-package.yml   — Full Angular Package CI/CD: same as node-package.yml with Angular defaults
  tauri-app.yml         — Full Rust CLI / Tauri 2 app CI/CD: determine-version → ci → draft → build ‖ installers → publish → changelog (inputs incl. `installer-sidecars`)
  issues.yml            — Reusable issue workflow: add-to-project ‖ conventions ‖ needs (inputs `project-url`, `required-sections`, `levels`, `needs`, `mode`; secrets `GH_PAT`, `PROJECT_TOKEN`)
  issue-events.yml      — This repository's caller of issues.yml (workflow "Issue events"; replaced add-to-project.yml)
  project-needs.yml     — This repository's hourly full Needs sync (schedule + workflow_dispatch, issues.yml with `needs: true`, `mode: full`)
  release-branch.yml    — Reusable push-to-`release/**` workflow: release-pr → mark-merged-issues (`labelled` output) → project/needs for the labelled issues (inputs incl. `project-status`, `project-url`, `require-pat`, `dry-run`; secrets `GH_PAT`, `PROJECT_TOKEN`)
  sync-wiki.yml         — Wiki sync: docs/**/*.md + README.md → GitHub Wiki
  deploy-pages.yml      — GitHub Pages deploy: MkDocs Material build → GitHub Pages
```

Migrating a repository with an inline workflow: see `docs/migration-guide.md`.

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
- The release job needs `contents: write`, `issues: write` and `pull-requests: read`; the calling job must grant them.
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

## Reusable Workflow: `issues.yml`

Call with `uses: GravionLabs/ci/.github/workflows/issues.yml@main` from a workflow on `issues` and `pull_request_target`.

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `project-url` | No | `""` | Project URL; empty disables `add-to-project` |
| `required-sections` | No | `{}` | JSON map of level label to required headings; `{}` disables the section check |
| `levels` | No | `epic,feature,pbi,task,bug` | Level labels in precedence order |
| `needs` | No | `false` | Run the `needs` job (requires `project-url`) |
| `mode` | No | `event` | `needs` job: `event` or `full` (every item of the repository) |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `GH_PAT` | No | Classic PAT with scopes `project` and `repo` (the `GITHUB_TOKEN` cannot write to user-owned projects) |
| `PROJECT_TOKEN` | No | Classic PAT with scope `project`, plus `repo` for a private repository (fine-grained tokens cannot access user-owned projects), for the `needs` job; `PROJECT_TOKEN \|\| GH_PAT` |

### Behavior

- Three independent jobs, no checkout, no job-level `needs:` key. Titles and bodies are untrusted: read through the API only, never through `${{ }}`.
- **add-to-project:** `issues` opened/reopened/transferred and `pull_request_target` opened/reopened; SHA-pinned `actions/add-to-project`. Missing `GH_PAT` = one warning, job green.
- **conventions** (`issues/conventions`): on open issues (opened, edited, labeled, unlabeled, reopened) with the `GITHUB_TOKEN`, so its edits trigger no rerun.
  - Title rule: the first label of `levels` the issue carries gives exactly one `[Level] ` prefix (`pbi` becomes `[PBI]`); other leading `[...]` and legacy `Epic:`, `Feature:`, `Bug:` prefixes are replaced. No level label: nothing happens.
  - Section rule: for levels in `required-sections`, headings (`##` to `####`, case-insensitive) that are missing add the label `needs-refinement` and one comment carrying the marker `<!-- gravionlabs-ci:issue-conventions -->` (updated, not duplicated); complete sections remove the label.
- **needs** (opt-in `needs: true`, runs `project/needs`, `permissions: {}`): `issues` labeled/unlabeled/closed/reopened and `pull_request_target` opened/closed/ready_for_review sync the issue of the event (PR: number from the head branch) plus parent; dependents too on closed/reopened and on the label `merged`. `mode: full`, `schedule` and `workflow_dispatch` sync every item. Runs `Sync-ProjectNeeds.ps1` of this repository's skill `github-project` (never checks out caller or PR code). Token `PROJECT_TOKEN || GH_PAT`, classic PAT with scope `project` (plus `repo` for a private repository); none = one warning, green. Concurrency per issue/PR with cancel-in-progress.
- The calling job must grant `issues: write`. `secrets: inherit` works; passing only `GH_PAT: ${{ secrets.GH_PAT }}` limits what `pull_request_target` runs (fork PRs) receive. The secret keeps the name `GH_PAT` (not kebab-case) so it matches the repository secret under `secrets: inherit`.
- This repository's caller is `.github/workflows/issue-events.yml` (workflow "Issue events"): top-level `permissions: {}`, `issues: write` on the job, `GH_PAT` and `PROJECT_TOKEN` passed, `needs: true`. The hourly full sync is `.github/workflows/project-needs.yml` (`mode: full`; its job also grants `issues: write` because GitHub validates all jobs of `issues.yml` at startup).

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

Tests: `node --test "issues/conventions/*.test.mjs"` (quote the glob, Node 21+; a bare directory fails on Node 24) and `bash tests/issues-workflow.test.sh` (needs `yq` and `jq`); `project/needs`: `bash tests/project-needs.test.sh`; the scripts of the skill: `npm ci && npm test` (Vitest, `tests/project/`, needs pwsh). The `actionlint` job of `ci.yml` lints `.github/workflows/` (actionlint via `go install`, shellcheck pass off); `release` needs it, `test-issue-conventions` and `test-project-needs`; `bash tests/release-branch-workflow.test.sh` (in the `actionlint` job) covers `release-branch.yml`.

## Reusable Workflow: `release-branch.yml`

Call with `uses: GravionLabs/ci/.github/workflows/release-branch.yml@main` from a workflow on `push` to `release/**` (the file has no triggers of its own).

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `release-branch` | No | `""` | Release branch; empty = the triggering ref |
| `base` | No | `""` | Base branch of the release PR; empty = repository default branch |
| `label` | No | `merged` | Label for issues merged into the release branch |
| `project-status` | No | `In release` | Project Status of the labelled issues; empty disables it |
| `project-url` | No | `""` | Project URL for the Needs sync; empty disables the sync |
| `require-pat` | No | `false` | Fail instead of warning when `GH_PAT` is missing |
| `dry-run` | No | `false` | Print what would change |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `GH_PAT` | No | Classic PAT, scope `repo` (plus `workflow`): the release PR created with it triggers its required checks (a `GITHUB_TOKEN` PR does not) |
| `PROJECT_TOKEN` | No | Classic PAT, scope `project` (plus `repo` for a private repository; fine-grained tokens and the `GITHUB_TOKEN` cannot write user-owned projects), for Status and Needs; falls back to `GH_PAT` |

### Behavior

- One job, no checkout, top-level `permissions: {}`; the calling job must grant `contents: read`, `issues: write`, `pull-requests: write`. `secrets: inherit` works.
- Steps: check `GH_PAT` (warning, or failure with `require-pat`), `versioning/release-pr`, `versioning/mark-merged-issues` (output `labelled` = issues newly labelled in this run), then `project/needs` with `issues: <labelled>` (the issues plus parents and dependents). The Needs sync is skipped without `project-url`, without labelled issues and on `dry-run` (which only prints that it would sync, since a dry run labels nothing). Only newly labelled issues are synced; a failed sync is not retried by a rerun. Runs of one release branch are serialized (`concurrency`, no cancel).
- Actions are referenced at `@main`: works for callers once those versions are released.
- Test: `bash tests/release-branch-workflow.test.sh`; the `actionlint` job of `ci.yml` lints it.

## Composite Actions

### `project/needs`

Keeps the project field `Needs` current by running `Sync-ProjectNeeds.ps1` (with `NeedsRules.psm1`) from `.apm/skills/github-project/scripts`, resolved from the action path of the same ref. Inputs: `project-url` (required), `token` (classic PAT, scope `project`, plus `repo` for a private repository; empty = warning, green), `mode` (`event`|`full`), `issues` (space/comma/newline-separated issue numbers; with `mode: event` each is synced with parents and dependents, independent of the event; invalid number = error). Event data reaches `needs.sh` through `env:` only. Test: `bash tests/project-needs.test.sh`; the scripts of the skill: `npm ci && npm test` (Vitest, `tests/project/`, needs pwsh).

### `issues/conventions`

Run on `issues` events (opened, edited, labeled, unlabeled, reopened) of open issues; used by `issues.yml`. Re-reads the issue, then sets exactly one `[Level] ` title prefix from the first `levels` label it carries (case-insensitive; leading `[...]` and legacy `Epic:`/`Feature:`/`Bug:` replaced; no level label: title unchanged). For levels in `required-sections` it adds or removes `needs-refinement` and keeps one marker comment `<!-- gravionlabs-ci:issue-conventions -->` up to date; a label it set is removed when the level no longer requires sections.
Inputs: `levels` (default `epic,feature,pbi,task,bug`), `required-sections` (JSON map level → heading array, default `{}`; invalid JSON or a non-array value fails with `Invalid required-sections JSON`), `token` (default `GITHUB_TOKEN`). Needs `issues: write`. Code: `conventions.mjs` (pure rules), `run.mjs` (API calls), tests in `conventions.test.mjs`.

### `versioning/determine-version`

Runs GitVersion on the full git history (`fetch-depth: 0` required in caller).

**Key outputs:** `semver`, `nuget-version`, `npm-version`, `python-version`, `docker-version`, `major`, `minor`, `patch`, `major-minor-patch`.

### `versioning/release-pr`

Run it on every push to `release/**`. It creates the PR `release: <x.y>` from the release branch to the default branch when none is open, and refreshes title and body otherwise: the PRs merged into the release branch since it left the base (a reused branch name does not pull in the PRs of its earlier life) and one `Closes #n` line per issue they reference. Does nothing for branches that are not `release/<x.y>` or are not ahead of the base. Never merges, never closes; idempotent (an unchanged PR is left alone).
Inputs: `release-branch` (default: the triggering ref), `base` (default: repository default branch), `token`, `dry-run`. Needs `contents: read`, `pull-requests: write`.

Pass a PAT as `token`: a PR created with the default `GITHUB_TOKEN` does not trigger `pull_request` workflows, so required checks on the release PR would never run and the PR stays blocked.

```yaml
on:
  push:
    branches: ['release/**']
permissions:
  contents: read
  pull-requests: write
jobs:
  release-pr:
    runs-on: ubuntu-latest
    steps:
      - uses: GravionLabs/ci/versioning/release-pr@main
        with:
          token: ${{ secrets.GH_PAT || github.token }}
```

The reusable workflow `release-branch.yml` wraps it together with `mark-merged-issues`.

Test: `GITHUB_REPOSITORY=<owner/repo> RELEASE_BRANCH=release/<x.y> DRY_RUN=true bash versioning/release-pr/release-pr.sh` (`GH_TOKEN` set).

### `versioning/close-release-issues`

Run it in the release job of the push to `main`, after `gh-release`. When the pushed commit is the merge of a `release/*` PR it closes, as completed with a "Shipped in v…" comment, every open issue referenced by `Closes|Fixes|Resolves #n` in the PRs merged into that release branch and in the release PR, the open sub-issues of those issues, and parents labeled `pbi` or `feature` whose sub-issues are all closed (repeating upwards; `epic` is never closed, parents in other repositories are skipped). Any other commit: no-op. Idempotent.
It also removes the label set by `mark-merged-issues` from every issue it closes and from referenced issues that are already closed (errors ignored).
Inputs: `version` (for the comment), `label` (default `merged`), `token`, `dry-run`. Needs `issues: write`, `pull-requests: read`, `contents: read`.

`versioning/gh-release` calls it by default (input `close-issues`, `continue-on-error`), so every release job gets it. The token needs `issues: write` and `pull-requests: read`; without them the step only warns. The release jobs of the reusable `*-package.yml` workflows and the `publish` job of `tauri-app.yml` request `issues: write` and `pull-requests: read` (besides `contents: write`), so the calling job must grant them: a reusable workflow that requests more than its caller allows fails at startup. `tauri-app.yml` calls this action itself in `publish`.

```yaml
      - uses: GravionLabs/ci/versioning/close-release-issues@main
        with:
          version: ${{ needs.determine-version.outputs.semver }}
```

Test against a finished release: `GITHUB_REPOSITORY=<owner/repo> GITHUB_SHA=<release merge commit> DRY_RUN=true ASSUME_OPEN=true bash versioning/close-release-issues/close.sh` (`GH_TOKEN` set).

### `versioning/mark-merged-issues`

`Closes #n` only fires on the default branch, so issues merged into a release branch stay open until the release lands. Run this on every push to `release/**` (any `release/*` branch, incl. `release/next`): it labels every open issue delivered to the branch with `merged` (created once with `gh label create --force`) and comments once `Merged into <branch>; closes when the release lands on <base>.`. Issues = `Closes|Fixes|Resolves #n` in the PRs merged into the branch since it left the base, plus `Closes…` and `Refs #n` footer lines in the commit messages of `base...branch`; pull requests and closed issues are skipped. Parents labeled `pbi` or `feature` (same repository) whose open sub-issues all carry the label get it too, repeating upwards; `epic` never. Already labelled issues are left alone (idempotent). Missing permissions or API failures only warn (exit 0). `close-release-issues` removes the label when the release lands.
Optional project status: with `project-status` set (e.g. `In release`), the project items of exactly the issues labelled in this run (the MARKED set, parents included) also get that Status. The status is applied to the whole labelled set of the run, including issues labelled earlier, so a manually set Status may be overwritten. Items already `Done` or already at that Status are skipped; a project without a Status option of that name gets one warning per project; dry-run prints `would set #n to <status> in <project>`. Projects need a token with project access: pass `project-token` as a classic PAT with scope `project` (fine-grained tokens cannot access user-owned projects); when the token lacks access the step warns once with that cause and never fails.
Inputs: `release-branch` (default: the triggering ref), `base` (default: repository default branch), `label` (default `merged`), `token`, `dry-run` (prints `would label #n`), `project-status` (default empty = off), `project-token` (default: `token`). Needs `contents: read`, `issues: write`, `pull-requests: read`; the project calls need the PAT scope above, not a job permission.

```yaml
on:
  push:
    branches: ['release/**']
permissions:
  contents: read
  issues: write
  pull-requests: read
jobs:
  mark-merged-issues:
    runs-on: ubuntu-latest
    steps:
      - uses: GravionLabs/ci/versioning/mark-merged-issues@main
        with:
          project-status: In release
          project-token: ${{ secrets.GH_PAT }}
```

Output `labelled`: space-separated numbers of the issues newly labelled in the run. The reusable workflow `release-branch.yml` wraps this action with `release-pr` and a Needs sync.

Test: `GITHUB_REPOSITORY=<owner/repo> RELEASE_BRANCH=release/next DRY_RUN=true [PROJECT_STATUS='In release' PROJECT_TOKEN=<pat>] bash versioning/mark-merged-issues/mark.sh` (`GH_TOKEN` set). Unit tests for both scripts against a fake `gh`: `bash tests/versioning.test.sh`.

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

### `node/ci`

Lint → build → test with a single setup and dependency installation. Wraps `node/setup`, lint, build, and test. Used internally by `node-package.yml` and `angular-package.yml`.

### `pages/deploy`

Builds a MkDocs site (Material theme) and uploads it as a GitHub Pages artifact.
Inputs: `docs-path` (default: `docs`), `mkdocs-config-file` (default: `mkdocs.yml`), `python-version` (default: `3.12`).
Requires `pages: write`, `id-token: write` permissions on the calling job — use the `deploy-pages.yml` reusable workflow for a complete setup.

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

## Releasing ci

- Work goes through PRs into the rolling `release/next` branch (CI checks run on those PRs). Hotfixes are the exception: `fix/<nr>-<slug>` from `main`, merged directly into `main`, then merge `main` back into `release/next`.
- `GitVersion.yml` sets `branches: release: { regex: ^release/next$, increment: Minor }`, so `release/next` gets a `1.1.0` pre-release version (GitVersion's default label, observed as `1.1.0-beta.1`, not configured here).
- Merging `release/next` into `main` releases the next version; the `release` job of `ci.yml` tags and publishes it. Callers keep using `@main`.
- **A plain merge is only a patch.** GitVersion on `main` ignores the branch rule after a `--no-ff` merge and yields `1.0.61`, not `1.1.0`. The minor bump needs a `+semver: minor` footer in a commit message that reaches `main`: put it in the merge commit message (or squash message) of the release PR, or in a commit on `release/next`. `versioning/release-pr` does not add it; it must be added by hand when merging. `tests/determine-version.test.sh` asserts both cases.
- Patch releases come only from hotfixes merged directly into `main` (for example `1.1.1`).

## Safe Change Checklist

- When adding a new input to an action, add a corresponding entry to the relevant reusable workflow if it should be surfaced there.
- Run `python3 scripts/generate_docs.py` after changing action inputs/outputs to regenerate README tables.
- Add `<!-- action-docs:inputs source="..." -->` markers if adding a new action section to README.md.
- For glob inputs in bash `run:` steps, always add `shopt -s globstar nullglob` before the command.
- Target PRs at `release/next`; see "Releasing ci".
