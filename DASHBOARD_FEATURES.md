# Dashboard and Dependency Graph Features

## Summary

Added real-time web dashboard and dependency graph visualization to Autoissue.

## Changes

### 1. Web Dashboard (`server/dashboard.ts`)

**New Features:**
- Real-time WebSocket-based updates
- Task status monitoring (running, completed, failed)
- Live cost tracking
- GitHub-themed dark UI
- Auto-shutdown 5 seconds after completion

**API:**
- `startDashboardServer(port)` - Starts Express + Socket.IO server
- `broadcastUpdate(session)` - Broadcasts session state to all connected clients
- Serves HTML dashboard at `http://localhost:{port}`

**Usage:**
```bash
autoissue --issues autoissue-1 --dashboard
# or
autoissue --directive "..." --dashboard
```

**Config:**
```json
{
  "dashboard": {
    "enabled": true,
    "port": 3030
  }
}
```

### 2. Dependency Graph Visualization (`lib/dependency-graph.ts`)

**New Methods:**
- `visualize()` - ASCII art representation
- `toMermaid()` - Mermaid diagram syntax
- `saveMermaidDiagram(path)` - Saves interactive HTML diagram

**Example Output:**
```
📊 Dependency Graph:
────────────────────────────────────────────────────────────
  #42 ← depends on [41] → blocks [43]
  #41 → blocks [42, 43]
  #43 ← depends on [41, 42]
────────────────────────────────────────────────────────────
📊 Dependency graph saved: ~/.autoissue/dep-graph-abc123.html
```

### 3. Executor Integration (`core/executor.ts`)

**Updated Functions:**
- `executeIssues()` - Added dashboard support
- `executePlannerMode()` - Added dashboard + dependency graph visualization
- `resumeExecution()` - Added dashboard support
- `executeSlidingWindow()` - Broadcasts updates on task status changes
- `executeDependencyAware()` - Broadcasts updates on task status changes
- `executeTask()` - Broadcasts on start, complete, and fail

### 4. CLI Integration

**New Options:**
- `--dashboard` - Enable web dashboard
- Already existed in `cli.ts`, now fully integrated

### 5. Tests

**Added Tests:**
- `visualize()` - ASCII art generation
- `toMermaid()` - Mermaid diagram syntax
- All existing tests still pass (158 tests)

## Dependencies Added

```json
{
  "dependencies": {
    "express": "^4.x",
    "socket.io": "^4.x",
    "cors": "^2.x"
  },
  "devDependencies": {
    "@types/express": "^4.x",
    "@types/cors": "^2.x"
  }
}
```

## Files Modified

1. `/server/dashboard.ts` - **NEW** - Dashboard server
2. `/lib/dependency-graph.ts` - Added visualization methods
3. `/core/executor.ts` - Integrated dashboard broadcasts
4. `/index.ts` - Pass dashboard option to executors
5. `/lib/types.ts` - Dashboard config already existed
6. `/__tests__/dependency-graph.test.ts` - Added visualization tests
7. `/README.md` - Updated documentation

## Build Verification

✅ TypeScript compilation passes
✅ All 158 tests pass (including 4 new visualization tests)
✅ No linting errors
✅ Dashboard config schema already existed in types

## Usage Examples

### Direct Mode with Dashboard
```bash
autoissue --issues autoissue-1 --dashboard
```

### Planner Mode with Dashboard
```bash
autoissue --directive "Build authentication system" --dashboard
```

### View Dependency Graph
```bash
autoissue --directive "..." 
# Opens: ~/.autoissue/dep-graph-{sessionId}.html
```

## Implementation Notes

- Dashboard uses Socket.IO for real-time updates (no polling)
- Broadcasts happen on: task start, task complete, task fail, session complete
- Dashboard server auto-shuts down 5s after execution to avoid orphaned processes
- Dependency graph is displayed in console + saved as HTML for planner mode
- All dashboard functionality is opt-in (disabled by default)

## Testing

Run tests:
```bash
npm test
```

Build:
```bash
npm run build
```

All tests pass, build succeeds, no TypeScript errors.
