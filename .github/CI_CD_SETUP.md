# CI/CD Pipeline Setup

This document explains the GitHub Actions workflows and how to configure them for Autoissue.

---

## Workflows Overview

### 1. **CI Workflow** (`ci.yml`)

**Triggers:**
- Push to `main`, `develop`, or `feat/*` branches
- Pull requests to `main` or `develop`

**Jobs:**
- **Test**: Runs on Node.js 18.x and 20.x
  - Install dependencies
  - Run linter (if configured)
  - Type check (continues even with known pre-existing errors)
  - Run unit tests
  - Upload coverage to Codecov (optional)

- **E2E**: Runs only on `main` branch or PRs to `main`
  - Install dependencies
  - Run end-to-end tests (if configured)

- **Lint Commit**: Validates PR titles follow conventional commit format
  - Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`

---

### 2. **Release Workflow** (`release.yml`)

**Triggers:**
- Push tags matching `v*.*.*` (e.g., `v2.0.0`)

**Jobs:**
- **Publish**:
  - Checkout code
  - Install dependencies
  - Run tests
  - Build (if build script exists)
  - Verify package.json version matches git tag
  - Publish to npm with provenance
  - Create GitHub Release with auto-generated notes
  - Attach README, CHANGELOG, MIGRATION docs

---

### 3. **PR Check Workflow** (`pr-check.yml`)

**Triggers:**
- Pull request opened, synchronized, or reopened

**Jobs:**
- **Validate**:
  - Check for breaking changes in core files
  - Run unit tests
  - Check test coverage (warns if < 80%)
  - Validate package.json
  - Find TODO/FIXME comments in changed files
  - Post comment on PR with results

---

## Required Secrets

### For Release Workflow

1. **`NPM_TOKEN`** (Required for npm publishing)
   - Go to https://www.npmjs.com/settings/your-username/tokens
   - Click "Generate New Token" → "Automation"
   - Copy the token
   - Add to GitHub: Settings → Secrets and variables → Actions → New repository secret
   - Name: `NPM_TOKEN`
   - Value: `npm_xxxxxxxxxxxxxxxxxxxxxxxxxxxx`

2. **`GITHUB_TOKEN`** (Auto-provided by GitHub Actions)
   - No setup required
   - Used for creating GitHub releases

### For E2E Tests (Optional)

If running E2E tests that interact with GitHub API:
- `GITHUB_TOKEN` is automatically available
- For rate limit reasons, consider creating a PAT with higher limits

---

## Setup Instructions

### 1. Enable GitHub Actions

Workflows are automatically enabled when merged to `main` branch.

### 2. Configure npm Publishing

```bash
# Ensure package.json has correct fields
npm init --scope=@venin-client-systems  # If scoped package

# Update package.json
{
  "name": "autoissue",  # or "@venin-client-systems/autoissue"
  "version": "2.0.0",
  "description": "Autonomous GitHub issue executor powered by Claude AI",
  "publishConfig": {
    "access": "public"
  }
}
```

Add NPM_TOKEN secret as described above.

### 3. Configure Branch Protection (Recommended)

Settings → Branches → Add rule for `main`:
- ✅ Require status checks to pass before merging
  - Select: `Test`, `Validate PR`
- ✅ Require pull request reviews before merging
- ✅ Require conversation resolution before merging

---

## Usage

### Running CI on Push

```bash
git add .
git commit -m "feat: add new feature"
git push origin feat/my-feature
```

CI will automatically run and report status on the commit.

### Creating a Release

```bash
# Update version in package.json
npm version patch  # or minor, major

# Push tag to trigger release
git push origin v2.0.1
```

The release workflow will:
1. Run tests
2. Verify version matches tag
3. Publish to npm
4. Create GitHub release

### Testing PR Checks Locally

```bash
# Run tests
npm test

# Type check
npx tsc --noEmit

# Check for breaking changes
git diff main...HEAD --name-only | grep -E "(core/executor.ts|lib/types.ts|cli.ts)"

# Find TODOs
git diff main...HEAD | grep -E "^\+.*\b(TODO|FIXME)\b"
```

---

## Troubleshooting

### Release Fails: Version Mismatch

**Error:** `package.json version (2.0.0) does not match tag version (2.0.1)`

**Fix:**
```bash
# Update package.json version
npm version 2.0.1 --no-git-tag-version

# Commit and re-tag
git add package.json
git commit -m "chore: bump version to 2.0.1"
git tag v2.0.1 -f
git push origin main --tags --force
```

### npm Publish Fails: Invalid Token

**Error:** `npm ERR! code E401`

**Fix:**
1. Verify NPM_TOKEN secret is set correctly
2. Check token hasn't expired: https://www.npmjs.com/settings/tokens
3. Generate new token if needed and update secret

### E2E Tests Fail: Rate Limited

**Error:** `API rate limit exceeded for user`

**Fix:**
1. Create GitHub PAT with higher rate limits
2. Add as secret: `GITHUB_TEST_TOKEN`
3. Update workflow to use it:
   ```yaml
   env:
     GITHUB_TOKEN: ${{ secrets.GITHUB_TEST_TOKEN }}
   ```

### PR Check Fails: Test Coverage Too Low

**Warning:** `Test coverage is below 80%`

**Fix:**
Add tests for uncovered code:
```bash
# Generate coverage report
npm test -- --coverage

# View HTML report
open coverage/index.html
```

---

## Maintenance

### Updating Workflows

1. Edit workflow files in `.github/workflows/`
2. Test locally if possible
3. Create PR with changes
4. Monitor first run after merge

### Monitoring CI/CD

- View runs: https://github.com/Venin-Client-Systems/autoissue/actions
- Check npm publishes: https://www.npmjs.com/package/autoissue
- Review GitHub releases: https://github.com/Venin-Client-Systems/autoissue/releases

---

## Best Practices

1. **Semantic Versioning**: Follow semver for version bumps
   - `patch` (1.0.x): Bug fixes
   - `minor` (1.x.0): New features (backward compatible)
   - `major` (x.0.0): Breaking changes

2. **Changelog**: Update CHANGELOG.md before tagging

3. **Testing**: Ensure tests pass locally before pushing

4. **Commit Messages**: Follow conventional commit format
   - `feat: add dashboard API`
   - `fix: resolve budget tracker overflow`
   - `docs: update README`

5. **Branch Strategy**:
   - `main`: Production releases only
   - `develop`: Integration branch
   - `feat/*`: Feature branches
   - Create PRs to `develop`, then `develop` → `main` for releases

---

**Questions?** Open an issue or see GitHub Actions docs: https://docs.github.com/actions
