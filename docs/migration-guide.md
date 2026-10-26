# Migrating an inline workflow to the shared workflows

Most repositories started with a copy of the same steps: GitVersion, build, test, publish, release. The shared workflows in `GravionLabs/ci` replace them with one `uses:` job. This guide shows the steps and, as a worked example, how `agentlens` (a Rust CLI, MCP server and Tauri 2 app) moved to `tauri-app.yml`.

## 1. Pick the reusable workflow

| Project | Workflow |
|---|---|
| NuGet library | `nuget-package.yml` |
| Python package | `python-package.yml` |
| Docker image | `docker-package.yml` |
| npm package / Angular library | `node-package.yml` / `angular-package.yml` |
| Rust CLI and/or Tauri 2 app | `tauri-app.yml` |

The inputs of each workflow are listed in the README. Versioning is done inside the workflow (`determine-version` runs first and every later job reads its outputs): remove your own GitVersion step and do not pass a `version:` input.

## 2. Move versioning into `GitVersion.yml`

Keep a `GitVersion.yml` in the repository. Do not pin `next-version` to an old minor, or a release is numbered as a patch of that minor. Ask for a bump with `+semver: minor` or `+semver: major` in a commit message.

## 3. Replace the jobs

Delete the inline jobs, keep the triggers and add one job that calls the workflow. Grant the permissions the workflow needs on the calling job (a reusable workflow that requests more than its caller allows fails at startup), and pass secrets with `secrets: inherit` or explicitly.

## 4. Keep expensive builds off pull requests

Run platform builds (macOS, Windows, Tauri installers) only on a push to `main` and on `workflow_dispatch`. A run on any other ref gets the throw-away version `0.0.<run number>` and publishes nothing.

## Worked example: agentlens

Before: `release.yml` held about 300 lines (GitVersion, cargo build per target, packing, Tauri installers, draft release, changelog). After:

```yaml
name: release
on:
  push:
    branches: [main]
  workflow_dispatch:
concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false
permissions:
  contents: read
jobs:
  release:
    uses: GravionLabs/ci/.github/workflows/tauri-app.yml@main
    permissions:
      contents: write
    with:
      ci-exclude: agentlens-app            # needs system libraries; app.yml checks it
      cli-package: agentlens-cli agentlens-mcp
      cli-binary: agentlens agentlens-mcp  # one archive per target
      tauri: true
      installer-args: --config src-tauri/tauri.bundle.conf.json
    secrets: inherit                       # TAURI_SIGNING_PRIVATE_KEY(_PASSWORD)
```

To install the CLI and the MCP server together with the application, list them in `bundle.externalBin` and pass them as sidecars:

```yaml
    with:
      installer-sidecars: '{"package":"agentlens-cli agentlens-mcp","binary":"agentlens agentlens-mcp"}'
```

Checks for pull requests stay in the repository (`ci.yml`, `app.yml`) and can use the `rust/ci` action.

## Issue workflows

Copies of `add-to-project.yml`, `issue-conventions.yml` or `issue-title.yml` are replaced by one caller of `issues.yml` (`on: issues` and `pull_request_target`, `permissions: issues: write`, `secrets: inherit`); see the `issues.yml` section in the README. Keep the PAT as secret `GH_PAT` (classic, scopes `project` and `repo`) and pass the project as `project-url`.

## Checklist

- [ ] `GitVersion.yml` present, no `next-version` pinned to an old minor.
- [ ] Calling job grants the permissions of the workflow.
- [ ] Secrets passed (`secrets: inherit`).
- [ ] Platform builds only on `main` and `workflow_dispatch`.
- [ ] A `workflow_dispatch` run on a branch produces the artifacts and no release.
