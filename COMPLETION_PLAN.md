# Autoissue 2.0: Completion Plan

## Overview

**Status:** ~80% complete
- ✅ Phase 1: Error Handling & Retry Foundation
- ✅ Phase 2: Architecture Refactor
- ✅ Phase 3: Replace gh CLI with Octokit (10x faster)
- ✅ Phase 4: Performance Optimizations
- 🔄 Phase 5: Developer Experience (30% complete)
- 🔄 Phase 6: Production Features (20% complete)
- 🔄 Phase 7: Rollout & Validation (10% complete)

**Remaining Work:** ~15-20 hours (2-3 days)

---

## Phase 5: Developer Experience

### 5.1: Explicit CLI Subcommands (3-4 hours)

**Problem:** Current CLI has auto-detection logic that's confusing:
```bash
autoissue ralphy-1              # Auto-detects label mode
autoissue "build feature X"     # Auto-detects planner mode
autoissue --resume              # Resume mode
```

**Solution:** Explicit subcommands with clear UX:
```bash
autoissue exec ralphy-1         # Execute issues by label
autoissue plan "build feature X" # Planner mode
autoissue resume <session-id>   # Resume session
autoissue status                # Show status
autoissue metrics               # Show metrics
```

**Files to modify:**
1. `index.ts` - Update CLI argument parsing
   - Replace auto-detection with subcommand routing
   - Add `exec`, `plan`, `resume`, `status`, `metrics` commands
   - Improve help text with examples

2. `lib/cli.ts` (NEW) - CLI command handlers
   ```typescript
   export async function handleExecCommand(label: string, options: ExecOptions)
   export async function handlePlanCommand(directive: string, options: PlanOptions)
   export async function handleResumeCommand(sessionId: string, options: ResumeOptions)
   export async function handleStatusCommand(options: StatusOptions)
   export async function handleMetricsCommand(options: MetricsOptions)
   ```

3. Update `README.md` with new CLI docs

**Acceptance Criteria:**
- ✅ No more auto-detection ambiguity
- ✅ Clear error messages for invalid commands
- ✅ `--help` shows all subcommands with examples
- ✅ Backward compatibility warning for old usage

---

### 5.2: Structured Logging with Rotation (2-3 hours)

**Problem:** Current logging:
- Unstructured text output
- No log rotation
- Mixes debug/info/warn/error levels inconsistently
- No persistent logs (only console output)

**Solution:** Structured JSON logging with rotation

**Files to modify:**
1. `lib/logger.ts` - Enhance with structured logging
   ```typescript
   import winston from 'winston';
   import DailyRotateFile from 'winston-daily-rotate-file';

   // JSON format for machine parsing
   // File rotation (daily, 14 day retention)
   // Separate error log file
   // Console output with colors for humans
   ```

2. Add log config to `lib/types.ts`:
   ```typescript
   export const LoggingConfigSchema = z.object({
     level: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
     format: z.enum(['json', 'pretty']).default('json'),
     directory: z.string().default('.logs'),
     maxFiles: z.number().default(14), // days
     maxSize: z.string().default('20m'),
   });
   ```

3. Update all log calls to use structured fields:
   ```typescript
   // Before
   logger.info('Task completed', { issueNumber, cost, duration });

   // After (ensure consistent field names)
   logger.info('Task completed', {
     event: 'task.completed',
     taskId: issueNumber,
     costUsd: cost,
     durationMs: duration,
   });
   ```

**Dependencies to add:**
```bash
npm install winston winston-daily-rotate-file
```

**Acceptance Criteria:**
- ✅ JSON logs in `.logs/autoissue-{date}.log`
- ✅ Error-only logs in `.logs/error-{date}.log`
- ✅ Daily rotation with 14-day retention
- ✅ Human-friendly console output (colored, pretty)
- ✅ Log level configurable via env var `LOG_LEVEL`

---

### 5.3: Real-Time Progress Tracking (2 hours)

**Problem:** Limited visibility into what's happening
- TUI shows basic task status
- No circuit breaker state visible
- No budget tracking visible
- No cache hit rates visible

**Solution:** Enhanced TUI with real-time metrics

**Files to modify:**
1. `ui/cli-ui.tsx` - Add metrics panel
   ```typescript
   // Add new components:
   <MetricsPanel>
     <BudgetStatus tracker={budgetTracker} />
     <CircuitBreakerStatus breaker={agentCircuitBreaker} />
     <CacheStats api={githubApi} />
     <ErrorMetrics observer={errorObserver} />
   </MetricsPanel>
   ```

2. `core/executor.ts` - Pass observers to TUI
   ```typescript
   if (!isHeadless) {
     startUI(session, {
       budgetTracker,
       errorObserver,
       githubApi,
       agentCircuitBreaker,
     });
   }
   ```

3. Create `ui/components/metrics-panel.tsx` (NEW)
   - Budget: spent/remaining/estimate
   - Circuit breaker: state/failures/threshold
   - Cache: hit rate/size
   - Errors: retries by type

**Acceptance Criteria:**
- ✅ Real-time budget display
- ✅ Circuit breaker state indicator (🔴 open, 🟡 half-open, 🟢 closed)
- ✅ Cache hit rate percentage
- ✅ Error retry counts by type
- ✅ Updates every 500ms

---

## Phase 6: Production Features

### 6.1: Dashboard Authentication (2-3 hours)

**Problem:** Dashboard is currently open to anyone on the network

**Solution:** Add basic auth and token-based auth

**Files to modify:**
1. `server/dashboard.ts` - Add auth middleware
   ```typescript
   import basicAuth from 'express-basic-auth';

   // Basic auth (for humans)
   if (config.dashboard.basicAuth) {
     app.use(basicAuth({
       users: { [config.dashboard.username]: config.dashboard.password },
       challenge: true,
     }));
   }

   // Token auth (for APIs)
   if (config.dashboard.token) {
     app.use((req, res, next) => {
       const token = req.headers['authorization']?.replace('Bearer ', '');
       if (token === config.dashboard.token) return next();
       res.status(401).json({ error: 'Unauthorized' });
     });
   }
   ```

2. Update `lib/types.ts` - Add auth config:
   ```typescript
   export const DashboardConfigSchema = z.object({
     enabled: z.boolean().default(false),
     port: z.number().int().min(1).max(65535).default(3030),
     host: z.string().default('localhost'),
     auth: z.object({
       basic: z.object({
         enabled: z.boolean().default(false),
         username: z.string(),
         password: z.string(),
       }).optional(),
       token: z.string().optional(),
     }).optional(),
   });
   ```

3. Update config reading to use env vars:
   ```bash
   DASHBOARD_BASIC_AUTH_USER=admin
   DASHBOARD_BASIC_AUTH_PASS=secret123
   DASHBOARD_TOKEN=sk_live_xxx
   ```

**Dependencies to add:**
```bash
npm install express-basic-auth
```

**Acceptance Criteria:**
- ✅ Basic auth prompts for username/password
- ✅ Token auth accepts `Authorization: Bearer <token>` header
- ✅ Auth can be disabled for local dev
- ✅ Clear error messages for unauthorized access

---

### 6.2: HTTPS Support (1-2 hours)

**Problem:** Dashboard only supports HTTP

**Solution:** Add HTTPS with self-signed or Let's Encrypt certs

**Files to modify:**
1. `server/dashboard.ts` - Add HTTPS server
   ```typescript
   import https from 'https';
   import fs from 'fs';

   if (config.dashboard.https?.enabled) {
     const httpsOptions = {
       key: fs.readFileSync(config.dashboard.https.keyPath),
       cert: fs.readFileSync(config.dashboard.https.certPath),
     };

     https.createServer(httpsOptions, app).listen(port, () => {
       logger.info(`Dashboard HTTPS server running on https://localhost:${port}`);
     });
   } else {
     app.listen(port, () => {
       logger.info(`Dashboard HTTP server running on http://localhost:${port}`);
     });
   }
   ```

2. Add cert generation script `scripts/generate-cert.sh`:
   ```bash
   #!/bin/bash
   # Generate self-signed certificate for local dev
   openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes
   ```

3. Update config schema:
   ```typescript
   https: z.object({
     enabled: z.boolean().default(false),
     keyPath: z.string(),
     certPath: z.string(),
   }).optional(),
   ```

**Acceptance Criteria:**
- ✅ HTTPS works with self-signed certs (local dev)
- ✅ HTTPS works with custom certs (production)
- ✅ HTTP still works when HTTPS disabled
- ✅ Redirects HTTP → HTTPS when both enabled

---

### 6.3: Metrics API Endpoint (1-2 hours)

**Problem:** No way to query metrics programmatically

**Solution:** REST API for metrics

**Files to modify:**
1. `server/dashboard.ts` - Add API routes
   ```typescript
   app.get('/api/metrics', (req, res) => {
     res.json({
       budget: budgetTracker.getState(),
       budgetStats: budgetTracker.getStatistics(),
       circuitBreaker: agentCircuitBreaker.getState(),
       errorMetrics: errorObserver.getMetrics(),
       githubCache: githubApi.getCacheStats(),
       githubRateLimit: await githubApi.getRateLimitStatus(),
     });
   });

   app.get('/api/metrics/budget', (req, res) => {
     res.json(budgetTracker.getState());
   });

   app.get('/api/metrics/circuit-breaker', (req, res) => {
     res.json(agentCircuitBreaker.getState());
   });

   app.get('/api/metrics/errors', (req, res) => {
     res.json(errorObserver.getMetrics());
   });

   app.post('/api/circuit-breaker/reset', (req, res) => {
     agentCircuitBreaker.reset();
     res.json({ success: true });
   });
   ```

2. Create `server/api-docs.md` with endpoint documentation

**Acceptance Criteria:**
- ✅ `GET /api/metrics` returns all metrics
- ✅ Individual metric endpoints work
- ✅ `POST /api/circuit-breaker/reset` requires auth
- ✅ JSON responses with proper content-type
- ✅ CORS enabled for cross-origin requests

---

### 6.4: Runtime Conflict Detection (2 hours)

**Problem:** Conflicts only detected at startup, not during execution

**Solution:** Real-time conflict monitoring

**Files to modify:**
1. `core/executor.ts` - Add runtime conflict checking
   ```typescript
   async function executeTask(...) {
     // Before starting task, check for runtime conflicts
     const runningTasks = Array.from(runningTasksMap.values());
     const runtimeConflicts = detectRuntimeConflicts(task, runningTasks);

     if (runtimeConflicts.length > 0) {
       logger.warn('Runtime conflicts detected', {
         taskId: task.issueNumber,
         conflicts: runtimeConflicts,
       });

       // Wait for conflicting tasks to complete
       await Promise.all(
         runtimeConflicts.map(conflictId => runningTasksMap.get(conflictId))
       );
     }

     // Now safe to proceed...
   }
   ```

2. Add to `lib/conflict-detector.ts`:
   ```typescript
   export function detectRuntimeConflicts(
     newTask: Task,
     runningTasks: Task[]
   ): number[] {
     const newFiles = new Set(extractFilePaths(newTask.body + ' ' + newTask.title));
     const conflicts: number[] = [];

     for (const runningTask of runningTasks) {
       const runningFiles = extractFilePaths(runningTask.body + ' ' + runningTask.title);
       if (runningFiles.some(f => newFiles.has(f))) {
         conflicts.push(runningTask.issueNumber);
       }
     }

     return conflicts;
   }
   ```

**Acceptance Criteria:**
- ✅ Detects conflicts with currently running tasks
- ✅ Waits for conflicting tasks before starting
- ✅ Logs conflict warnings
- ✅ TUI shows "waiting for conflicts to resolve"

---

## Phase 7: Rollout & Validation

### 7.1: Integration with Budget Tracker (1 hour)

**Problem:** Budget tracker exists but not integrated into executor

**Solution:** Enforce budget checks before task execution

**Files to modify:**
1. `core/executor.ts` - Add budget tracking
   ```typescript
   export async function executeIssues(...) {
     // Create budget tracker
     const budgetTracker = new BudgetTracker(config.maxTotalBudgetUsd);

     // Before starting tasks
     const estimate = budgetTracker.estimateNextTaskCost() * tasks.length;
     if (!budgetTracker.canAffordTasks(tasks.length)) {
       throw new BudgetExceededError(estimate, config.maxTotalBudgetUsd);
     }

     // In executeTask, check before each task
     async function executeTask(task, ...) {
       const estimate = budgetTracker.estimateNextTaskCost();
       budgetTracker.canAfford(estimate, task.issueNumber); // Throws if exceeded

       // ... execute task ...

       // Record actual cost
       budgetTracker.recordCost(task.costUsd);
     }
   }
   ```

**Acceptance Criteria:**
- ✅ Throws `BudgetExceededError` BEFORE execution
- ✅ Estimates based on historical data
- ✅ Records actual costs after execution
- ✅ Visible in TUI metrics panel

---

### 7.2: Feature Flag Cleanup (1 hour)

**Problem:** Legacy retry still supported via feature flag

**Solution:** Remove legacy code after validation

**Files to modify:**
1. `core/executor.ts` - Remove legacy retry path
   ```typescript
   // Delete the entire if (FeatureFlags.USE_LEGACY_RETRY) block
   // Keep only the new error boundary path
   ```

2. `lib/smart-retry.ts` - Delete entire file (fully deprecated)

3. `lib/feature-flags.ts` - Remove `USE_LEGACY_RETRY` flag

**Acceptance Criteria:**
- ✅ Only one retry code path remains
- ✅ All tests still pass
- ✅ No references to `USE_LEGACY_RETRY`

---

### 7.3: End-to-End Testing (3-4 hours)

**Problem:** Only unit and integration tests exist

**Solution:** E2E tests with real GitHub repos

**Files to create:**
1. `__tests__/e2e/setup.ts` - E2E test harness
   ```typescript
   // Create test repo
   // Create test issues with labels
   // Run autoissue in headless mode
   // Verify PRs created
   // Cleanup
   ```

2. `__tests__/e2e/executor.e2e.test.ts`:
   ```typescript
   describe('E2E: Execute Issues', () => {
     it('processes ralphy-1 label end-to-end', async () => {
       // Setup test repo with issues
       // Run: autoissue exec ralphy-1
       // Assert: PRs created, issues closed
     });

     it('handles budget limits', async () => {
       // Set low budget
       // Run executor
       // Assert: stops before exceeding budget
     });

     it('handles circuit breaker', async () => {
       // Simulate API failures
       // Assert: circuit opens, fails fast
     });
   });
   ```

3. `__tests__/e2e/planner.e2e.test.ts`:
   ```typescript
   describe('E2E: Planner Mode', () => {
     it('decomposes directive into issues', async () => {
       // Run: autoissue plan "Add auth system"
       // Assert: Multiple issues created
     });
   });
   ```

**Test Environment:**
- Use test GitHub org/repo (e.g., `autoissue-tests/sandbox`)
- Run in CI with `GITHUB_TOKEN` secret
- Cleanup after each test run

**Acceptance Criteria:**
- ✅ Full executor flow works end-to-end
- ✅ Budget limits enforced
- ✅ Circuit breaker prevents cascading failures
- ✅ Planner mode creates valid issues
- ✅ Tests run in CI/CD

---

### 7.4: Documentation (2-3 hours)

**Files to create/update:**

1. **README.md** - Complete rewrite
   - Installation
   - Quick start
   - CLI reference (all subcommands)
   - Configuration reference
   - Architecture overview
   - Performance benchmarks

2. **MIGRATION.md** - v1.x → v2.0 guide
   ```markdown
   # Migration Guide: v1.x → v2.0

   ## Breaking Changes
   - CLI now uses subcommands (exec, plan, resume)
   - Config format changed (see schema)
   - gh CLI replaced with Octokit (GITHUB_TOKEN required)

   ## New Features
   - Budget tracking (prevents overspending)
   - Circuit breaker (prevents cascading failures)
   - 10x faster GitHub API operations
   - Real-time metrics

   ## Step-by-Step Migration
   1. Update config file
   2. Set GITHUB_TOKEN env var
   3. Update CLI commands
   4. Test with --dry-run
   ```

3. **ARCHITECTURE.md** - System design
   - Component diagram
   - Error handling flow
   - Budget tracking flow
   - Circuit breaker states
   - Caching strategy

4. **API.md** - Dashboard API reference
   - All endpoints with examples
   - Authentication methods
   - Response schemas

5. **CHANGELOG.md** - Version history
   ```markdown
   # Changelog

   ## [2.0.0] - 2026-02-21

   ### Added
   - Budget tracker with P90 cost estimation
   - Circuit breaker for error handling
   - Octokit integration (10x faster GitHub API)
   - Structured logging with rotation
   - Dashboard authentication
   - Metrics API endpoints

   ### Changed
   - CLI now uses subcommands (exec, plan, resume)
   - Replaced gh CLI with @octokit/rest
   - Optimized conflict detection (50-70% faster)

   ### Deprecated
   - smart-retry.ts (use error-boundaries.ts)

   ### Removed
   - Auto-detection CLI mode

   ### Fixed
   - Budget checks now run BEFORE execution
   - Rate limit handling with circuit breaker
   ```

**Acceptance Criteria:**
- ✅ README clear and complete
- ✅ Migration guide tested with real v1.x→v2.0 upgrade
- ✅ Architecture docs explain design decisions
- ✅ API docs have curl examples
- ✅ Changelog follows Keep a Changelog format

---

### 7.5: CI/CD Pipeline (2 hours)

**Problem:** No automated testing/deployment

**Solution:** GitHub Actions workflow

**Files to create:**

1. `.github/workflows/ci.yml`:
   ```yaml
   name: CI

   on: [push, pull_request]

   jobs:
     test:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v3
         - uses: actions/setup-node@v3
           with:
             node-version: '20'
         - run: npm ci
         - run: npm run typecheck
         - run: npm test
         - run: npm run build

     e2e:
       runs-on: ubuntu-latest
       needs: test
       steps:
         - uses: actions/checkout@v3
         - uses: actions/setup-node@v3
         - run: npm ci
         - run: npm run test:e2e
           env:
             GITHUB_TOKEN: ${{ secrets.E2E_GITHUB_TOKEN }}
   ```

2. `.github/workflows/release.yml`:
   ```yaml
   name: Release

   on:
     push:
       tags:
         - 'v*'

   jobs:
     publish:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v3
         - uses: actions/setup-node@v3
           with:
             node-version: '20'
             registry-url: 'https://registry.npmjs.org'
         - run: npm ci
         - run: npm run build
         - run: npm publish
           env:
             NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}
   ```

**Acceptance Criteria:**
- ✅ Tests run on every push
- ✅ E2E tests run on main branch
- ✅ Auto-publish to npm on tags
- ✅ Build artifacts cached

---

### 7.6: Performance Benchmarks (1-2 hours)

**Problem:** No quantitative performance data

**Solution:** Benchmark suite

**Files to create:**

1. `scripts/benchmark.ts`:
   ```typescript
   import { performance } from 'perf_hooks';

   async function benchmarkGitHubAPI() {
     console.log('Benchmarking GitHub API (gh CLI vs Octokit)...');

     // Benchmark gh CLI
     const ghStart = performance.now();
     await githubClient.execForStdout(['issue', 'list', ...]);
     const ghDuration = performance.now() - ghStart;

     // Benchmark Octokit
     const octokitStart = performance.now();
     await githubApi.listIssues('owner/repo', ['bug']);
     const octokitDuration = performance.now() - octokitStart;

     console.log(`gh CLI: ${ghDuration.toFixed(2)}ms`);
     console.log(`Octokit: ${octokitDuration.toFixed(2)}ms`);
     console.log(`Speedup: ${(ghDuration / octokitDuration).toFixed(2)}x`);
   }

   async function benchmarkConflictDetection() {
     // Test with 10, 50, 100 tasks
     // Measure with/without caching
   }

   async function main() {
     await benchmarkGitHubAPI();
     await benchmarkConflictDetection();
     // More benchmarks...
   }
   ```

2. Update `package.json`:
   ```json
   {
     "scripts": {
       "benchmark": "tsx scripts/benchmark.ts"
     }
   }
   ```

**Acceptance Criteria:**
- ✅ Quantitative performance data
- ✅ Comparison with v1.x baseline
- ✅ Results documented in README

---

## Timeline & Effort Estimate

| Phase | Task | Hours | Priority |
|-------|------|-------|----------|
| **5.1** | Explicit CLI Subcommands | 3-4 | HIGH |
| **5.2** | Structured Logging | 2-3 | MEDIUM |
| **5.3** | Real-Time Progress Tracking | 2 | MEDIUM |
| **6.1** | Dashboard Authentication | 2-3 | HIGH |
| **6.2** | HTTPS Support | 1-2 | MEDIUM |
| **6.3** | Metrics API Endpoint | 1-2 | MEDIUM |
| **6.4** | Runtime Conflict Detection | 2 | LOW |
| **7.1** | Budget Tracker Integration | 1 | HIGH |
| **7.2** | Feature Flag Cleanup | 1 | MEDIUM |
| **7.3** | E2E Testing | 3-4 | HIGH |
| **7.4** | Documentation | 2-3 | HIGH |
| **7.5** | CI/CD Pipeline | 2 | MEDIUM |
| **7.6** | Performance Benchmarks | 1-2 | LOW |

**Total Estimated Hours:** 23-33 hours (3-4 days)

---

## Recommended Execution Order

### Sprint 1: Core Functionality (1 day, 8 hours)
1. 7.1: Budget Tracker Integration (1h) ← **Start here**
2. 5.1: Explicit CLI Subcommands (4h)
3. 6.3: Metrics API Endpoint (2h)
4. 7.2: Feature Flag Cleanup (1h)

### Sprint 2: Production Readiness (1 day, 8 hours)
5. 6.1: Dashboard Authentication (3h)
6. 5.2: Structured Logging (3h)
7. 6.2: HTTPS Support (2h)

### Sprint 3: Polish & Validation (1-2 days, 10-15 hours)
8. 7.3: E2E Testing (4h)
9. 7.4: Documentation (3h)
10. 5.3: Real-Time Progress Tracking (2h)
11. 7.5: CI/CD Pipeline (2h)
12. 7.6: Performance Benchmarks (2h)
13. 6.4: Runtime Conflict Detection (2h) ← Optional

---

## Success Criteria

**v2.0 is complete when:**
- ✅ All HIGH priority items done
- ✅ E2E tests pass in CI
- ✅ Documentation complete
- ✅ Performance benchmarks show 10x+ improvement
- ✅ Zero production blockers

**Optional nice-to-haves:**
- 🔄 MEDIUM priority items (improve UX/DX)
- 🔄 LOW priority items (quality of life)

---

## Dependencies to Add

```json
{
  "dependencies": {
    "winston": "^3.x",
    "winston-daily-rotate-file": "^5.x",
    "express-basic-auth": "^1.x"
  }
}
```

---

## Post-Completion Checklist

- [ ] All tests pass (unit, integration, E2E)
- [ ] Documentation reviewed and accurate
- [ ] Performance benchmarks documented
- [ ] Migration guide tested
- [ ] CI/CD pipeline working
- [ ] npm package published
- [ ] GitHub release created
- [ ] Announcement posted (if applicable)
- [ ] v1.x deprecated notice added

---

## Notes

**Breaking Changes in v2.0:**
1. CLI now requires subcommands (exec, plan, resume)
2. `GITHUB_TOKEN` env var required (no more gh CLI)
3. Config schema changed (see migration guide)

**Backward Compatibility:**
- Old gh CLI kept as fallback (optional)
- Legacy config auto-migrated with warnings
- Feature flags allow gradual rollout

**Performance Targets:**
- GitHub API: 10x faster (shell → REST API)
- Conflict detection: 50-70% faster (caching)
- Budget checks: BEFORE execution (prevent overspend)
- Error handling: <1% cascading failures (circuit breaker)
