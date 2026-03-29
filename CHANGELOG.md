# Changelog

All notable changes to GravionLabs/ci are documented here.
Versioning follows [Semantic Versioning](https://semver.org/).
Callers should pin to a major version tag (e.g. `@v1`) rather than `@main`.

---

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



