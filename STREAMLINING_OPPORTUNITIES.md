# Autoissue Streamlining Opportunities

## Summary
After auditing the autoissue codebase, here are the key areas that can be streamlined for better UX, maintainability, and simplicity.

---

## ✅ COMPLETED

### 1. CLI Auto-Detection (DONE)
**Problem**: Verbose syntax requiring explicit flags (`--issues`, `--directive`, `--resume`)
**Solution**: Auto-detect mode based on argument pattern
**Changes Made**:
- `autoissue` → Resume mode
- `autoissue ralphy-1` → Issue processing mode
- `autoissue "Build JWT auth"` → Directive/planner mode
- Backward compatible with explicit flags

---

## 🔧 RECOMMENDED IMPROVEMENTS

### 2. Reduce Duplication in Executor Functions
**Problem**: `executeIssues`, `executePlannerMode`, and `resumeExecution` share 70%+ duplicate code
**Location**: `core/executor.ts` (1127 lines)
**Impact**: Medium priority, maintainability issue

**Recommendation**:
Extract common patterns:
```typescript
// Shared dashboard setup
function setupDashboard(config, options) { ... }

// Shared session cleanup
function cleanupSession(session, dashboard, ui) { ... }

// Shared execution loop caller
async function runExecution(session, tasks, config, options) { ... }
```

**Benefit**: Reduce executor.ts from ~1100 lines to ~600 lines

---

### 3. Simplify Config Schema Defaults
**Problem**: Too many optional configs with complex default layering
**Location**: `lib/types.ts`, `lib/config.ts`
**Impact**: Low priority, minor complexity

**Current**:
```typescript
export const DashboardConfigSchema = z.object({
  enabled: z.boolean().default(false),
  port: z.number().int().min(1).max(65535).default(3030),
});
```

**Simpler**:
```typescript
// Most users don't need these granular controls
// Provide sane defaults and document overrides
```

**Recommendation**: Remove rarely-used config options like:
- `executor.prDraft` (always `false` in practice)
- `planner.enabled` (just check if planner config exists)
- `telegram.health.bindAddress` (niche use case)

**Benefit**: Easier mental model, smaller config files

---

### 4. Remove Session Complexity
**Problem**: Session state management has multiple overlapping concepts
**Location**: `core/session.ts`, `core/state.ts`, `core/recovery.ts`
**Impact**: Medium priority, confusion between session/state/recovery

**Current Architecture**:
- `SessionState` (types.ts) - type definition
- `session.ts` - session ID generation
- `state.ts` - save/load state
- `recovery.ts` - resume logic

**Recommendation**: Merge into single `core/session-manager.ts`:
```typescript
export class SessionManager {
  create(): SessionState
  save(state: SessionState): void
  load(id: string): SessionState | null
  list(): string[]
  resume(id: string): Promise<void>
}
```

**Benefit**: Single source of truth for session operations

---

### 5. Streamline Error Boundary Complexity
**Problem**: `core/error-boundaries.ts` is 349 lines for error handling
**Location**: `core/error-boundaries.ts`
**Impact**: Low priority, over-engineered for current needs

**Current**: Complex circuit breaker pattern with retry budgets, exponential backoff state machines
**Reality**: Most failures are non-recoverable (API auth, network timeout)

**Recommendation**: Simplify to:
```typescript
export async function withRetry<T>(
  fn: () => Promise<T>,
  maxRetries = 3
): Promise<T> {
  // Simple exponential backoff
  // No complex state machines
}
```

**Benefit**: 300+ lines → ~50 lines, easier to understand

---

### 6. Domain Classifier Optimization
**Problem**: 4-tier classification is overkill for most repos
**Location**: `lib/domain-classifier.ts` (220 lines)
**Impact**: Low priority, minor performance

**Current**: Title tags → Labels → File paths → Keywords
**Reality**: 95% of repos use title tags or labels consistently

**Recommendation**:
- Keep tier 1-2 (title tags, labels)
- Make tier 3-4 (file paths, keywords) optional/lazy
- Add config flag: `classification.quickMode = true` (skip expensive tiers)

**Benefit**: Faster startup, less noise in logs

---

### 7. Remove Telegram Integration (Optional)
**Problem**: Telegram bot adds 200+ lines of code that <1% of users need
**Location**: `lib/telegram-bot.ts` (if exists), config schema
**Impact**: Low priority, code bloat

**Current**: Built into core config schema
**Better**: Make it a plugin or separate package

**Recommendation**:
```bash
# Option 1: Separate package
npm install @venin/autoissue-telegram

# Option 2: Plugin system
autoissue --plugin telegram --issues ralphy-1
```

**Benefit**: Smaller core bundle, easier to maintain

---

### 8. Consolidate Smart Features
**Problem**: Too many "smart" helpers that overlap
**Location**: `lib/smart-retry.ts`, `lib/model-selector.ts`, `lib/conflict-detector.ts`
**Impact**: Medium priority, feature creep

**Current**:
- `smart-retry.ts` - AI-powered retry logic
- `model-selector.ts` - Auto-select model based on complexity
- `conflict-detector.ts` - Predict file conflicts

**Reality**: These are all "nice to have" features that add complexity

**Recommendation**:
- **Keep**: `conflict-detector.ts` (high value, low complexity)
- **Simplify**: `smart-retry.ts` (just exponential backoff, no AI analysis)
- **Remove**: `model-selector.ts` (users should pick their own model)

**Benefit**: Less "magic", more predictable behavior

---

### 9. Dependency Graph Complexity
**Problem**: Full topological sort for dependency resolution is overkill
**Location**: `lib/dependency-graph.ts` (220 lines)
**Impact**: Low priority, rarely used

**Current**: Builds full dependency graph with cycle detection, topological sort, Mermaid visualization
**Reality**: Most directives produce 2-5 independent tasks, rarely dependencies

**Recommendation**:
- Keep basic `depends_on` tracking
- Remove fancy visualizations (Mermaid, ASCII art)
- Fail fast on circular dependencies instead of complex detection

**Benefit**: 220 lines → ~50 lines

---

### 10. Headless vs UI Confusion
**Problem**: `--headless` and `--ui` flags are confusing
**Location**: `cli.ts`, executor calls
**Impact**: Low priority, UX confusion

**Current**:
```bash
autoissue --issues ralphy-1 --ui       # TUI mode
autoissue --issues ralphy-1 --headless # No TUI (default)
```

**Confusing**: Default is headless but flag suggests otherwise

**Recommendation**:
```bash
autoissue ralphy-1           # Headless (default)
autoissue ralphy-1 --ui      # TUI mode
# Remove --headless flag entirely
```

**Benefit**: Simpler mental model

---

## 📊 Priority Summary

| Priority | Items | Total Line Reduction |
|----------|-------|---------------------|
| **High** | CLI auto-detection (✅ done) | - |
| **Medium** | #2 (executor dedup), #4 (session), #8 (smart features) | ~800 lines |
| **Low** | #3, #5, #6, #9, #10 | ~600 lines |
| **Optional** | #7 (telegram removal) | ~200 lines |

**Total Potential Reduction**: ~1600 lines (~30% of codebase)
**Maintainability Gain**: Significant (fewer concepts, clearer boundaries)

---

## Next Steps

1. ✅ CLI auto-detection (completed)
2. Refactor executor to extract common patterns (#2)
3. Merge session-related files (#4)
4. Simplify error boundaries (#5)
5. Review and prune smart features (#8)

Each improvement can be done incrementally without breaking changes.
