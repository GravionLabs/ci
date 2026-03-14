---
description: Review a .github/workflows/ci.yml against GravionLabs/ci best practices
---

Review the provided GitHub Actions workflow file against the `GravionLabs/ci` best practices for NuGet package CI/CD.

## Checklist

### Interface Usage

- [ ] Uses `GravionLabs/ci/.github/workflows/nuget-package.yml@main` (not an older path or fork)
- [ ] Does **NOT** pass a `version:` input (versioning is internal since the workflow refactor)
- [ ] Does **NOT** have a separate `determine-version` job (it runs inside the reusable workflow)
- [ ] Uses `gitversion-config-file:` input (not `config-file-path:`) if GitVersion is configured

### Required Inputs

- [ ] `dotnet-project` points to a valid `.csproj` or solution file
- [ ] `publish-feed-url` is set and uses the correct URL format for the target feed

### Package Verification

- [ ] `verify-package-files` is set (strongly recommended)
- [ ] All targeted .NET frameworks are covered (e.g. `lib/net8.0/`, `lib/net10.0/`)
- [ ] Both `.dll` and `.xml` (documentation) entries are present per TFM
- [ ] `README.md` and `CHANGELOG.md` are listed if the project includes them in the package

### Secrets

- [ ] `publish-api-key` secret is mapped correctly
- [ ] Secret name matches what is configured in the repository settings
- [ ] If a private restore feed is used, `feed-token` is also mapped

### Triggers

- [ ] Workflow runs on `push` to `main` (for actual publishing)
- [ ] Workflow runs on `pull_request` (for pre-merge validation without publishing)
- [ ] `force-publish: true` is only set if intentional (e.g. beta releases from feature branches)

### Environment

- [ ] The repository has a `nuget-publish` environment configured in GitHub Settings → Environments
  (the `publish` job inside the reusable workflow requires this environment)

## Response Format

For each failed check, provide:

1. **Issue**: What is wrong?
2. **Rule**: Which checklist item is violated?
3. **Fix**: Concrete corrected YAML snippet.
4. **Severity**: Critical / Warning / Info

Workflow to review:

${input:workflow:Paste the ci.yml content here}
