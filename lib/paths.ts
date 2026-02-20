import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import {
  existsSync, mkdirSync, writeFileSync, readFileSync,
  renameSync, appendFileSync,
} from 'node:fs';

export const ECHELON_HOME = join(homedir(), '.echelon');
export const SESSIONS_DIR = join(ECHELON_HOME, 'sessions');

export function sessionDir(sessionId: string): string {
  if (sessionId.includes('..') || sessionId.includes('/') || sessionId.includes('\\')) {
    throw new Error(`Invalid session ID: ${sessionId}`);
  }
  return join(SESSIONS_DIR, sessionId);
}

export function ensureDir(dir: string): void {
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

export function atomicWriteJSON(filePath: string, data: unknown): void {
  ensureDir(dirname(filePath));
  const tmp = filePath + '.tmp';
  writeFileSync(tmp, JSON.stringify(data, null, 2), 'utf-8');
  renameSync(tmp, filePath);
}

export function appendToFile(filePath: string, content: string): void {
  ensureDir(dirname(filePath));
  appendFileSync(filePath, content, 'utf-8');
}

/** Read JSON file. Returns null if file doesn't exist or is corrupt. Never writes. */
export function readJSON<T>(filePath: string): T | null {
  if (!existsSync(filePath)) return null;
  try {
    return JSON.parse(readFileSync(filePath, 'utf-8')) as T;
  } catch {
    return null;
  }
}
