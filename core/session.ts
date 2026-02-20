import { join } from 'node:path';
import { readdirSync, existsSync, rmSync, statSync } from 'node:fs';
import { SESSIONS_DIR, readJSON } from '../lib/paths.js';
import { logger } from '../lib/logger.js';
import type { SessionState, SessionStatus } from '../lib/types.js';

export interface SessionSummary {
  id: string;
  repo: string;
  directive?: string;
  label?: string;
  status: SessionStatus;
  totalCost: number;
  taskCount: number;
  startedAt: string;
  completedAt?: string;
}

/** List all sessions, most recent first */
export function listSessions(): SessionSummary[] {
  if (!existsSync(SESSIONS_DIR)) return [];

  const dirs = readdirSync(SESSIONS_DIR).filter(d => {
    const statePath = join(SESSIONS_DIR, d, 'state.json');
    return existsSync(statePath);
  });

  const summaries: SessionSummary[] = [];

  for (const dir of dirs) {
    try {
      const state = readJSON<SessionState>(join(SESSIONS_DIR, dir, 'state.json'));
      if (!state || typeof state.sessionId !== 'string') continue;

      summaries.push({
        id: state.sessionId,
        repo: state.config.project.repo,
        directive: state.directive,
        label: state.label,
        status: state.status,
        totalCost: state.totalCost,
        taskCount: state.tasks.length,
        startedAt: state.startedAt,
        completedAt: state.completedAt,
      });
    } catch {
      logger.debug(`Skipping corrupt session: ${dir}`);
    }
  }

  return summaries.sort((a, b) =>
    (b.completedAt || b.startedAt).localeCompare(a.completedAt || a.startedAt)
  );
}

/** Find a resumable session (most recent paused or running) */
export function findResumableSession(repo?: string): SessionSummary | null {
  const sessions = listSessions();
  const resumable = sessions.filter(s =>
    s.status === 'paused' || s.status === 'running',
  );

  if (repo) {
    return resumable.find(s => s.repo === repo) ?? null;
  }

  // When no repo specified, still return the first one (already sorted by updatedAt)
  // This is intentional - caller should pass repo if they want filtering
  return resumable[0] ?? null;
}

/** Delete a session and its data */
export function deleteSession(sessionId: string): boolean {
  // Sanitize: reject path traversal attempts
  if (sessionId.includes('..') || sessionId.includes('/') || sessionId.includes('\\')) {
    logger.warn('Rejected invalid session ID', { session: sessionId });
    return false;
  }

  const dir = join(SESSIONS_DIR, sessionId);
  if (!existsSync(dir)) return false;

  rmSync(dir, { recursive: true, force: true });
  logger.info('Deleted session', { session: sessionId });
  return true;
}

/** Delete all completed/failed sessions, plus stale running sessions */
export function pruneCompletedSessions(): number {
  const sessions = listSessions();
  const oneHourAgo = Date.now() - 3_600_000;
  let count = 0;

  for (const s of sessions) {
    const updatedTime = new Date(s.completedAt || s.startedAt).getTime();
    const isRecent = updatedTime >= oneHourAgo;

    // Skip recent completed/failed sessions (keep sessions < 1 hour old)
    if (isRecent && (s.status === 'completed' || s.status === 'failed')) {
      continue;
    }

    const prunable =
      s.status === 'completed' ||
      s.status === 'failed' ||
      // Stale running sessions with no tasks (crashed before producing anything)
      (s.status === 'running' && s.taskCount === 0 && updatedTime < oneHourAgo);

    if (prunable && deleteSession(s.id)) count++;
  }

  return count;
}

/** Recursively calculate directory size */
function getDirSize(dirPath: string): number {
  let size = 0;
  try {
    const entries = readdirSync(dirPath, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = join(dirPath, entry.name);
      try {
        if (entry.isDirectory()) {
          size += getDirSize(fullPath);
        } else if (entry.isFile()) {
          size += statSync(fullPath).size;
        }
      } catch { /* skip */ }
    }
  } catch { /* skip */ }
  return size;
}

/** Get disk usage of sessions directory */
export function getSessionsDiskUsage(): { count: number; bytes: number } {
  if (!existsSync(SESSIONS_DIR)) return { count: 0, bytes: 0 };

  const dirs = readdirSync(SESSIONS_DIR);
  let bytes = 0;

  for (const dir of dirs) {
    const fullPath = join(SESSIONS_DIR, dir);
    try {
      const stat = statSync(fullPath);
      if (stat.isDirectory()) {
        bytes += getDirSize(fullPath);
      }
    } catch { /* skip */ }
  }

  return { count: dirs.length, bytes };
}

/** Print session list to stdout */
export function printSessions(): void {
  const sessions = listSessions();

  if (sessions.length === 0) {
    console.log('No sessions found.');
    return;
  }

  console.log(`\n${'ID'.padEnd(50)} ${'Status'.padEnd(10)} ${'Cost'.padEnd(8)} ${'Msgs'.padEnd(5)} Directive`);
  console.log('─'.repeat(100));

  for (const s of sessions) {
    const id = s.id.length > 48 ? s.id.slice(0, 48) + '..' : s.id.padEnd(50);
    const status = s.status.padEnd(10);
    const cost = `$${s.totalCost.toFixed(2)}`.padEnd(8);
    const tasks = String(s.taskCount).padEnd(5);
    const directive = (s.directive || s.label || '').slice(0, 40);
    console.log(`${id} ${status} ${cost} ${tasks} ${directive}`);
  }

  const usage = getSessionsDiskUsage();
  console.log(`\n${sessions.length} session(s), ${(usage.bytes / 1024).toFixed(1)} KB on disk\n`);
}
