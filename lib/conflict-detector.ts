import type { Task } from './types.js';
import { logger } from './logger.js';

/**
 * Extract file paths from text using common patterns.
 *
 * Looks for:
 * - Source file paths (src/lib/foo.ts)
 * - Backtick-quoted paths (`src/foo.ts`)
 * - Common extensions (.ts, .js, .tsx, .jsx, .json, .md, .yml, .yaml)
 */
export function extractFilePaths(text: string): string[] {
  const patterns = [
    // Source file paths with extensions (order matters - longer extensions first)
    /(?:src|lib|core|tests?|components?|pages?|app|utils?)\/[a-zA-Z0-9_\-\/\.]+\.(?:tsx|jsx|json|yaml|scss|html|ts|js|md|yml|css)\b/gi,
    // Backtick-quoted paths
    /`([a-zA-Z0-9_\-\/\.]+\.(?:tsx|jsx|json|yaml|scss|html|ts|js|md|yml|css))\b`/gi,
    // Double-quoted paths
    /"([a-zA-Z0-9_\-\/\.]+\.(?:tsx|jsx|json|yaml|scss|html|ts|js|md|yml|css))\b"/gi,
  ];

  const files = new Set<string>();

  for (const pattern of patterns) {
    const matches = text.matchAll(pattern);
    for (const match of matches) {
      // Use capture group if available, otherwise use full match
      const path = match[1] || match[0];
      // Normalize path (remove backticks, quotes)
      const normalized = path.replace(/[`"]/g, '').trim();
      if (normalized) {
        files.add(normalized);
      }
    }
  }

  return Array.from(files);
}

/**
 * Detect file conflicts between tasks.
 *
 * Returns a map of task issue numbers to conflicting task issue numbers.
 *
 * Example:
 * - Task 1 touches src/foo.ts
 * - Task 2 also touches src/foo.ts
 * - Result: { 2: [1] } (task 2 conflicts with task 1)
 */
export function detectConflicts(tasks: Task[]): Map<number, number[]> {
  const fileOwnership = new Map<string, number[]>(); // file -> [issueNumbers]
  const conflicts = new Map<number, number[]>(); // issueNumber -> [conflicting issueNumbers]

  // First pass: build file ownership map
  for (const task of tasks) {
    const files = extractFilePaths(task.body + ' ' + task.title);

    for (const file of files) {
      if (!fileOwnership.has(file)) {
        fileOwnership.set(file, []);
      }
      fileOwnership.get(file)!.push(task.issueNumber);
    }
  }

  // Second pass: detect conflicts
  for (const [file, owners] of fileOwnership.entries()) {
    if (owners.length > 1) {
      // Multiple tasks touch this file
      for (const issueNumber of owners) {
        const otherOwners = owners.filter((n) => n !== issueNumber);
        if (!conflicts.has(issueNumber)) {
          conflicts.set(issueNumber, []);
        }
        conflicts.get(issueNumber)!.push(...otherOwners);
      }
    }
  }

  // Remove duplicates
  for (const [issueNumber, conflictList] of conflicts.entries()) {
    conflicts.set(issueNumber, Array.from(new Set(conflictList)));
  }

  if (conflicts.size > 0) {
    logger.warn('File conflicts detected', {
      conflictCount: conflicts.size,
      conflicts: Array.from(conflicts.entries()).map(([issue, conflicting]) => ({
        issue,
        conflictsWith: conflicting,
      })),
    });
  }

  return conflicts;
}

/**
 * Check if two tasks have file conflicts.
 */
export function hasConflict(task1: Task, task2: Task): boolean {
  const files1 = extractFilePaths(task1.body + ' ' + task1.title);
  const files2 = extractFilePaths(task2.body + ' ' + task2.title);

  const set1 = new Set(files1);
  return files2.some((f) => set1.has(f));
}
