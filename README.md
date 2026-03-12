# workflow-templates

A collection of reusable GitHub Actions (composite actions) and reusable workflows for use across multiple repositories.

## Repository Structure

```
.github/
├── actions/
│   ├── determine-version/  # Determine SemVer from git history (GitVersion)
│   ├── create-version-tag/ # Create and push a git tag
│   ├── hello-world/        # Simple example action (inputs & outputs)
│   └── setup-node/         # Set up Node.js with dependency caching
└── workflows/
    └── node-ci.yml         # Reusable Node.js CI workflow
```

---

## Composite Actions

### `determine-version`

Determines the semantic version of a repository from its git history using
[GitVersion](https://gitversion.net/). Produces version strings for all major
ecosystems: Docker, npm/Angular, Python (PEP 440), NuGet, and .NET assemblies.

> **Prerequisite:** The calling job must check out with `fetch-depth: 0` so
> that the full git history is available.

**Usage in another repository:**

```yaml
jobs:
  version:
    runs-on: ubuntu-latest
    outputs:
      semver: ${{ steps.version.outputs.semver }}
      python-version: ${{ steps.version.outputs.python-version }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Determine version
        id: version
        uses: jerome-kaufmann/workflow-templates/.github/actions/determine-version@main

      # Use the outputs later in the same job:
      - run: |
          echo "SemVer:      ${{ steps.version.outputs.semver }}"
          echo "Docker:      ${{ steps.version.outputs.semver }}"
          echo "npm:         ${{ steps.version.outputs.npm-version }}"
          echo "Python:      ${{ steps.version.outputs.python-version }}"
          echo "NuGet:       ${{ steps.version.outputs.nuget-version }}"
          echo "Assembly:    ${{ steps.version.outputs.assembly-sem-ver }}"
```

**Inputs**

| Name | Description | Required | Default |
|---|---|---|---|
| `gitversion-version-spec` | GitVersion tool version to install | No | `6.x` |
| `config-file-path` | Path to `GitVersion.yml` config file | No | `GitVersion.yml` |

**Outputs**

| Name | Example | Use case |
|---|---|---|
| `semver` | `1.2.3-alpha.4` | Docker tags, npm, Angular, git tag |
| `major-minor-patch` | `1.2.3` | Stable version string (no pre-release) |
| `major` | `1` | Docker major tag |
| `minor` | `2` | Docker minor/major tag |
| `patch` | `3` | Docker patch tag |
| `pre-release-tag` | `alpha.4` | Conditional logic; empty on stable |
| `full-semver` | `1.2.3-alpha.4+5` | Full SemVer with build metadata |
| `informational-version` | `1.2.3+Branch.main.Sha.abc` | .NET `InformationalVersion` |
| `assembly-sem-ver` | `1.2.3.0` | .NET `AssemblyVersion` / `FileVersion` |
| `nuget-version` | `1.2.3-alpha0004` | NuGet packages |
| `python-version` | `1.2.3a4` | Python / uv (PEP 440 format) |
| `npm-version` | `1.2.3-alpha.4` | npm / Angular packages |

---

### `create-version-tag`

Creates and pushes a git tag for the given version. Idempotent — skips
silently if the tag already exists.

> **Prerequisite:** The calling workflow must grant `permissions: contents: write`.

**Usage in another repository:**

```yaml
permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Determine version
        id: version
        uses: jerome-kaufmann/workflow-templates/.github/actions/determine-version@main

      # … build, test, publish steps …

      - name: Tag release
        uses: jerome-kaufmann/workflow-templates/.github/actions/create-version-tag@main
        with:
          version: ${{ steps.version.outputs.semver }}
```

**Inputs**

| Name | Description | Required | Default |
|---|---|---|---|
| `version` | Version to tag (e.g. `1.2.3` or `1.2.3-alpha.4`) | **Yes** | — |
| `tag-prefix` | Prefix prepended to the version (e.g. `v` → `v1.2.3`) | No | `v` |

---

### `hello-world`

A minimal example that demonstrates how composite actions with inputs and outputs work.

**Usage in another repository:**

```yaml
- name: Greet someone
  uses: jerome-kaufmann/workflow-templates/.github/actions/hello-world@main
  id: greet
  with:
    who-to-greet: 'Alice'

- name: Print the random number
  run: echo "Random number was ${{ steps.greet.outputs.random-number }}"
```

**Inputs**

| Name            | Description       | Required | Default  |
|-----------------|-------------------|----------|----------|
| `who-to-greet`  | Who to greet      | No       | `World`  |

**Outputs**

| Name            | Description                          |
|-----------------|--------------------------------------|
| `random-number` | A random number generated at runtime |

---

### `setup-node`

Sets up a Node.js environment and caches dependencies. Wraps the official
[`actions/setup-node`](https://github.com/actions/setup-node) action with
sensible defaults.

**Usage in another repository:**

```yaml
- name: Set up Node.js
  uses: jerome-kaufmann/workflow-templates/.github/actions/setup-node@main
  with:
    node-version: '20'
    cache: 'npm'
```

**Inputs**

| Name                | Description                                              | Required | Default |
|---------------------|----------------------------------------------------------|----------|---------|
| `node-version`      | Node.js version to install (e.g. `18`, `20`, `22`)      | No       | `20`    |
| `cache`             | Package manager for caching (`npm`, `yarn`, `pnpm`)     | No       | `npm`   |

---

## Reusable Workflows

### `node-ci.yml`

A complete CI pipeline for Node.js projects: checkout → setup Node.js → install → build → test.

**Usage in another repository:**

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  ci:
    uses: jerome-kaufmann/workflow-templates/.github/workflows/node-ci.yml@main
    with:
      node-version: '20'
      working-directory: '.'
      run-tests: true
```

**Inputs**

| Name                | Description                             | Required | Default |
|---------------------|-----------------------------------------|----------|---------|
| `node-version`      | Node.js version to use                  | No       | `20`    |
| `working-directory` | Path to the Node.js project root        | No       | `.`     |
| `run-tests`         | Whether to execute `npm test`           | No       | `true`  |

---

## Referencing a Specific Version

To pin an action or workflow to a specific release or commit SHA instead of
`@main`, use a tag or SHA:

```yaml
uses: jerome-kaufmann/workflow-templates/.github/actions/setup-node@v1.0.0
# or
uses: jerome-kaufmann/workflow-templates/.github/actions/setup-node@<commit-sha>
```

---

## End-to-End Example: Versioning + Docker + Tag

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    branches: [main]

permissions:
  contents: write        # required by create-version-tag
  packages: write        # required if pushing Docker images to GHCR

jobs:
  release:
    runs-on: ubuntu-latest
    outputs:
      semver: ${{ steps.version.outputs.semver }}

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # required by determine-version

      - name: Determine version
        id: version
        uses: jerome-kaufmann/workflow-templates/.github/actions/determine-version@main

      # Docker: tag image with semver, major, major.minor, and latest
      - name: Build & push Docker image
        run: |
          IMAGE="ghcr.io/${{ github.repository }}"
          SEMVER="${{ steps.version.outputs.semver }}"
          MAJOR="${{ steps.version.outputs.major }}"
          MINOR="${{ steps.version.outputs.minor }}"
          docker build \
            -t "$IMAGE:$SEMVER" \
            -t "$IMAGE:$MAJOR.$MINOR" \
            -t "$IMAGE:$MAJOR" \
            -t "$IMAGE:latest" .
          docker push --all-tags "$IMAGE"

      # Python: update pyproject.toml version
      - name: Set Python package version
        run: uv version "${{ steps.version.outputs.python-version }}"

      # npm / Angular: update package.json version
      - name: Set npm package version
        run: npm version "${{ steps.version.outputs.npm-version }}" --no-git-tag-version

      # .NET: pass version to MSBuild
      - name: Build .NET project
        run: |
          dotnet build \
            -p:AssemblyVersion="${{ steps.version.outputs.assembly-sem-ver }}" \
            -p:FileVersion="${{ steps.version.outputs.assembly-sem-ver }}" \
            -p:InformationalVersion="${{ steps.version.outputs.informational-version }}"

      # Create & push the git tag at the end of the workflow
      - name: Tag release
        uses: jerome-kaufmann/workflow-templates/.github/actions/create-version-tag@main
        with:
          version: ${{ steps.version.outputs.semver }}
```

---

## Adding New Actions

1. Create a new directory under `.github/actions/<action-name>/`.
2. Add an `action.yml` file with `using: 'composite'`.
3. Document the new action in this README.
