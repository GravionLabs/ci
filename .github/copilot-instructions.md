# Copilot Instructions — GravionLabs/ci

> For a complete architecture overview and action reference, read `AGENTS.md` first.

## What this repository is

A library of **reusable GitHub Actions composite actions and reusable workflows** for .NET and Python CI/CD. There is no application code — every file is either a YAML action, a reusable workflow, or documentation tooling.

## Commands

```bash
# Regenerate README input/output tables after changing any action.yml
python3 scripts/generate_docs.py

# Verify README is in sync (used in CI — fails with exit code 1 if out of date)
python3 scripts/generate_docs.py --check
```

Smoke tests run exclusively in GitHub Actions (`.github/workflows/test.yml`). There is no local test runner.

## Architecture

Actions are organized by technology then function:

```
dotnet/setup → dotnet/build → dotnet/test
                            → dotnet/nuget/pack → dotnet/nuget/verify-package
                                               → dotnet/nuget/publish

docker/lint  (independent job)
docker/build → docker/publish  (same job — build does checkout, publish does not)
```

- `dotnet/build` performs checkout internally — subsequent steps in the same job do not need to checkout again.
- `dotnet/nuget/pack` uploads a `nupkgs` artifact. `dotnet/nuget/publish` downloads it when running in a separate job (`download-artifact: true`).
- `dotnet/nuget/verify-package` must run in the same job as `pack` (no artifact download — it reads `./nupkgs/*.nupkg` directly).
- `.github/workflows/nuget-package.yml` is the flagship reusable workflow that wires all dotnet actions together.

## Conventions

### Parameter naming

- **Tool-specific identifiers** (what to act on) get a tool prefix: `dotnet-version`, `dotnet-project`, `test-project`, `python-version`, `uv-version`, `gitversion-version-spec`.
- **Generic flags** (how to act) do not: `configuration`, `verbosity`, `coverage-format`, `upload-results`.
- **Infrastructure params** shared across technologies do not: `feed-url`, `feed-name`, `feed-token`, `api-key`.
- **Credential secrets** follow the pattern `publish-api-key` (not `api-token`).
- **GitVersion config** is always `gitversion-config-file` (not `config-file-path`).

### Defaults for dotnet-project

| Input | Default | Rationale |
|-------|---------|-----------|
| `dotnet-project` (build, pack) | `**/*.{sln,slnx}` | Solution files give correct build order and prevent packing test projects |
| `test-project` (test) | `test/**/*.Test.csproj` | Test selection should be explicit, not solution-wide |

### Glob handling in bash steps

Whenever a `run:` step uses a glob input (e.g. `${{ inputs.dotnet-project }}`), add `shopt -s globstar nullglob` before the dotnet command so that `**` expands recursively and unmatched patterns disappear instead of being passed as literals.

### README tables are auto-generated

The blocks between `<!-- action-docs:inputs source="..." -->` and `<!-- /action-docs:inputs -->` in README.md are managed by `scripts/generate_docs.py`. Do not edit these blocks manually — run the script instead.

### Threading new inputs through the reusable workflow

When adding a new input to a composite action that should be surfaced to callers, also add it to `.github/workflows/nuget-package.yml` (or `python-package.yml`) and wire the pass-through.

### GitVersion requirement

`versioning/determine-version` requires `fetch-depth: 0` in the caller's checkout step. This is not enforced at the action level — the caller is responsible.

### --no-build convention

All dotnet actions that run after `dotnet/build` pass `--no-build` to avoid redundant compilation.

### Docker multi-arch builds

- Always set up QEMU (`docker/setup-qemu-action@v3`) for ARM emulation before building.
- `docker/build` validates the build (`push: false`); `docker/publish` builds+pushes — the image is built twice in the full workflow. This is intentional and acceptable.
- `docker/publish` has **no checkout step** — it relies on the checkout done by `docker/build` in the same job.
- Tag strategy: `{docker-version}` always; `latest`, `{major}`, `{major}.{minor}`, `{major}.{minor}.{patch}` only on `main`.
- `docker-version` from `determine-version` = `{semver}-{shortSha}` (e.g. `1.2.3-alpha.4-abc1234`).
- No `shopt -s globstar` needed in docker steps (no glob inputs).

### Threading new Docker inputs

When adding a new input to a docker composite action that should be surfaced to callers, also add it to `.github/workflows/docker-package.yml` and wire the pass-through.
