# workflow-templates

A collection of reusable GitHub Actions (composite actions) and reusable workflows for use across multiple repositories.

## Repository Structure

```
.github/
├── actions/
│   ├── hello-world/        # Simple example action (inputs & outputs)
│   └── setup-node/         # Set up Node.js with dependency caching
└── workflows/
    └── node-ci.yml         # Reusable Node.js CI workflow
```

---

## Composite Actions

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

## Adding New Actions

1. Create a new directory under `.github/actions/<action-name>/`.
2. Add an `action.yml` file with `using: 'composite'`.
3. Document the new action in this README.
