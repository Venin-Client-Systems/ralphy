/**
 * State Persistence
 *
 * Manages session state saving and loading for crash recovery.
 */

import { writeFileSync, readFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import type { SessionState } from '../lib/types.js';
import { logger } from '../lib/logger.js';

const STATE_DIR = join(homedir(), '.autoissue', 'sessions');

/**
 * Get the path to a session's state file.
 */
function getStatePath(sessionId: string): string {
  return join(STATE_DIR, `${sessionId}.json`);
}

/**
 * Ensure the state directory exists.
 */
function ensureStateDir(): void {
  if (!existsSync(STATE_DIR)) {
    mkdirSync(STATE_DIR, { recursive: true });
  }
}

/**
 * Save session state to disk.
 *
 * Called after each task completion to enable crash recovery.
 */
export function saveState(session: SessionState): void {
  try {
    ensureStateDir();
    const path = getStatePath(session.sessionId);
    writeFileSync(path, JSON.stringify(session, null, 2), 'utf-8');
    logger.debug('State saved', { sessionId: session.sessionId, path });
  } catch (err) {
    logger.error('Failed to save state', {
      sessionId: session.sessionId,
      error: err instanceof Error ? err.message : String(err),
    });
    // Don't throw - state saving is best-effort
  }
}

/**
 * Load session state from disk.
 *
 * Returns null if the session doesn't exist.
 */
export function loadState(sessionId: string): SessionState | null {
  try {
    const path = getStatePath(sessionId);
    if (!existsSync(path)) {
      logger.debug('State file not found', { sessionId, path });
      return null;
    }

    const data = readFileSync(path, 'utf-8');
    const session = JSON.parse(data) as SessionState;
    logger.info('State loaded', { sessionId, tasks: session.tasks.length });
    return session;
  } catch (err) {
    logger.error('Failed to load state', {
      sessionId,
      error: err instanceof Error ? err.message : String(err),
    });
    return null;
  }
}

/**
 * List all saved session IDs.
 */
export function listSessions(): string[] {
  try {
    ensureStateDir();
    const { readdirSync } = require('node:fs');
    return readdirSync(STATE_DIR)
      .filter((f: string) => f.endsWith('.json'))
      .map((f: string) => f.replace('.json', ''));
  } catch (err) {
    logger.error('Failed to list sessions', {
      error: err instanceof Error ? err.message : String(err),
    });
    return [];
  }
}
