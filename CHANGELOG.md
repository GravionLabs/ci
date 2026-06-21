# Changelog

All notable changes to GravionLabs/ci are documented here.
Versioning follows [Semantic Versioning](https://semver.org/).
Callers should pin to a major version tag (e.g. `@v1`) rather than `@main`.

---

## [1.0.39] — 2026-06-21

### Bug Fixes
- Use GitVersion to set package version before publish (#14)


### Documentation
- Update CHANGELOG.md for v1.0.38 [skip ci]


## [1.0.38] — 2026-06-19

### Bug Fixes
- Remove duplicate artifact-path input from node and angular workflows (#13)


### Documentation
- Update CHANGELOG.md for v1.0.37 [skip ci]


## [1.0.37] — 2026-06-18

### Documentation
- Update CHANGELOG.md for v1.0.36 [skip ci]


## [1.0.36] — 2026-06-17

### Documentation
- Update CHANGELOG.md for v1.0.35 [skip ci]


### Features
- Add artifact-path input to angular and node workflows for dist subdirectory upload; fix README npm-auth-type


## [1.0.35] — 2026-06-14

### Bug Fixes
- Write npm-auth-type to project .npmrc instead of pnpm config set (#12)


### Documentation
- Update CHANGELOG.md for v1.0.34 [skip ci]


## [1.0.34] — 2026-06-14

### Bug Fixes
- Use pnpm config set for npm-auth-type (not npm config set) (#11)


### Documentation
- Update CHANGELOG.md for v1.0.33 [skip ci]


## [1.0.33] — 2026-06-14

### Documentation
- Update CHANGELOG.md for v1.0.32 [skip ci]


### Features
- Add artifact-path input to workflows, fix pnpm auth to use user-level .npmrc (#10)


## [1.0.32] — 2026-06-14

### Documentation
- Update CHANGELOG.md for v1.0.31 [skip ci]


### Refactoring
- Rename pnpm-version to package-manager-version, update run conditions


## [1.0.31] — 2026-06-14

### Documentation
- Update CHANGELOG.md for v1.0.30 [skip ci]


### Refactoring
- Remove standalone CI workflows, set Angular defaults in angular-package


## [1.0.30] — 2026-06-14

### Documentation
- Update CHANGELOG.md for v1.0.29 [skip ci]


### Features
- Add node/ci composite action with lint, build, test and artifact handoff


## [1.0.29] — 2026-06-14

### Bug Fixes
- Allow pnpm version auto-detection from packageManager field


### Documentation
- Update CHANGELOG.md for v1.0.28 [skip ci]


## [1.0.28] — 2026-06-14

### Documentation
- Update CHANGELOG.md for v1.0.27 [skip ci]


## [1.0.27] — 2026-06-14

### Documentation
- Update CHANGELOG.md for v1.0.26 [skip ci]


## [1.0.26] — 2026-06-14

### Documentation
- Update CHANGELOG.md for v1.0.25 [skip ci]


### Features
- Add package-manager input to workflows and update commands for better flexibility


## [1.0.25] — 2026-06-14

### Documentation
- Update CHANGELOG.md for v1.0.24 [skip ci]


### Features
- Add node-package.yml and angular-package.yml reusable workflows


## [1.0.24] — 2026-06-14

### Bug Fixes
- Write pnpm auth directly to .npmrc instead of pnpm config set


### Documentation
- Update CHANGELOG.md for v1.0.23 [skip ci]


## [1.0.23] — 2026-06-14

### Bug Fixes
- Use --location=project for pnpm config; remove invalid npm-registry-server


### Documentation
- Update CHANGELOG.md for v1.0.22 [skip ci]


### Features
- Auto-dispatch build/test/publish commands based on package-manager (#8)


## [1.0.22] — 2026-06-13

### Documentation
- Update CHANGELOG.md for v1.0.21 [skip ci]


### Features
- Add node/publish composite action for GitHub Packages auth + publish (#8)


## [1.0.21] — 2026-06-10

### Bug Fixes
- **test**: Add continue-on-error to publishing steps


### Documentation
- Update CHANGELOG.md for v1.0.20 [skip ci]


## [1.0.20] — 2026-06-08

### Bug Fixes
- Remove --if-present flag from build commands (not supported by pnpm)


### Documentation
- Update CHANGELOG.md for v1.0.19 [skip ci]


## [1.0.19] — 2026-06-08

### Bug Fixes
- Install pnpm via npm install -g for reliability


### Documentation
- Update CHANGELOG.md for v1.0.18 [skip ci]


## [1.0.18] — 2026-06-08

### Bug Fixes
- Use shell case instead of if for corepack enable in composite action


### Documentation
- Update CHANGELOG.md for v1.0.17 [skip ci]


## [1.0.17] — 2026-06-08

### Features
- Add package-manager input to all composite actions


## [1.0.16] — 2026-06-08

### Documentation
- Update CHANGELOG.md for v1.0.15 [skip ci]


### Features
- Add package-manager input to support pnpm and yarn


## [1.0.15] — 2026-05-10

### Documentation
- Update CHANGELOG.md for v1.0.14 [skip ci]
- Add Pages Actions section to README.md


## [1.0.14] — 2026-05-10

### Documentation
- Update CHANGELOG.md for v1.0.13 [skip ci]


### Features
- **pages**: Add DocFX build action


## [1.0.13] — 2026-04-03

### Documentation
- Update CHANGELOG.md for v1.0.12 [skip ci]


### Features
- **versioning**: Add token input to gh-release action


## [1.0.12] — 2026-03-29

### Documentation
- Update CHANGELOG.md for v1.0.11 [skip ci]


### Features
- **versioning**: Write version summary to job summary in Report versions step


## [1.0.11] — 2026-03-27

### Documentation
- Update CHANGELOG.md for v1.0.10 [skip ci]


## [1.0.10] — 2026-03-26

### Documentation
- Update CHANGELOG.md for v1.0.9 [skip ci]


### Refactoring
- Update Node.js and Angular CI workflows for improved build commands and structure


## [1.0.9] — 2026-03-26

### Bug Fixes
- Add missing permissions for contents in Node.js CI workflow


### Documentation
- Update CHANGELOG.md for v1.0.8 [skip ci]


## [1.0.8] — 2026-03-26

### Refactoring
- Remove unnecessary environment variables from git-cliff steps


## [1.0.7] — 2026-03-26

### Features
- Add GitHub Pages deployment workflow for MkDocs site


## [1.0.6] — 2026-03-24

### Features
- Add Node.js and Angular test actions with coverage publishing


## [1.0.5] — 2026-03-23

### Features
- **node**: Add Angular CI workflow and angular/build composite action


## [1.0.4] — 2026-03-19

### Features
- Add git-cliff CHANGELOG auto-generation to gh-release action


## [1.0.3] — 2026-03-18

### Bug Fixes
- Add contents:read permission to build-test-pack job


## [1.0.2] — 2026-03-18

### Features
- Publish test results and coverage summary to GitHub UI


## [1.0.1] — 2026-03-18

### Bug Fixes
- Remove --no-build and simplify coverage collection in test action


## [1.0.0] — 2026-03-18

### Bug Fixes
- Replace relative uses: paths with absolute refs in composite actions
- Simplify release job — remove create-release input, mirror publish condition


### Documentation
- Update README for verify-package; add marker-based doc generator


### Features
- Add determine-version and create-version-tag composite actions
- Add verify-package action and integrate into nuget-package workflow
- Add wiki/sync composite action and sync-wiki reusable workflow
- Add gh-release action and release job to nuget-package workflow
- Add support for test-projects input in .NET test action and update documentation
- Add Docker CI/CD workflows and actions
- Enhance CI/CD workflows with verbosity and force-publish inputs


### Refactoring
- Move actions to repo root for shorter references
- Update action reference to GravionLabs/ci
- Remove deprecated actions and add new .NET workflows for build, test, pack, and publish
- Update config-file-path description and default value in determine-version action
- Update output descriptions and add Docker version computation in determine-version action
- Add GitHub token to checkout step in build .NET action
- Remove check for full-semver output in test workflow
- Update action references to use GravionLabs namespace in nuget-package workflow
- Add output validation step to determine-version job
- Improve package verification and error handling in verify-package action



