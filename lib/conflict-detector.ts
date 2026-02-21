import type { Task } from './types.js';
import { logger } from './logger.js';
import { LRUCache } from 'lru-cache';

/**
 * Cache for file path extraction results.
 * Avoids re-parsing the same text multiple times.
 */
const extractionCache = new LRUCache<string, string[]>({
  max: 1000, // Cache up to 1000 unique texts
  ttl: 10 * 60 * 1000, // 10 minute TTL
});

/**
 * Extract file paths from text using common patterns.
 *
 * Results are cached to avoid re-parsing the same text.
 *
 * Looks for:
 * - Source file paths (src/lib/foo.ts)
 * - Backtick-quoted paths (`src/foo.ts`)
 * - Common extensions (.ts, .js, .tsx, .jsx, .json, .md, .yml, .yaml)
 */
export function extractFilePaths(text: string): string[] {
  // Check cache first
  const cached = extractionCache.get(text);
  if (cached) {
    return cached;
  }
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

  const result = Array.from(files);

  // Cache the result
  extractionCache.set(text, result);

  return result;
}

/**
 * Detect file conflicts between tasks.
 *
 * Optimized O(n*k) algorithm with caching:
 * - n = number of tasks
 * - k = average files per task
 *
 * Uses Sets to avoid duplicate conflicts and caching to avoid re-parsing.
 *
 * Returns a map of task issue numbers to conflicting task issue numbers.
 *
 * Example:
 * - Task 1 touches src/foo.ts
 * - Task 2 also touches src/foo.ts
 * - Result: { 2: [1] } (task 2 conflicts with task 1)
 */
export function detectConflicts(tasks: Task[]): Map<number, number[]> {
  const fileOwnership = new Map<string, Set<number>>(); // file -> Set<issueNumber> (Set for O(1) lookups)
  const conflicts = new Map<number, Set<number>>(); // issueNumber -> Set<conflicting issueNumbers>

  // First pass: build file ownership map - O(n * k)
  for (const task of tasks) {
    const files = extractFilePaths(task.body + ' ' + task.title);

    for (const file of files) {
      if (!fileOwnership.has(file)) {
        fileOwnership.set(file, new Set());
      }
      fileOwnership.get(file)!.add(task.issueNumber);
    }
  }

  // Second pass: detect conflicts - O(f * m²) where f = files, m = avg tasks per file
  // For typical case where m is small (1-2), this is effectively O(f * k)
  for (const [file, owners] of fileOwnership.entries()) {
    if (owners.size > 1) {
      // Multiple tasks touch this file
      for (const issueNumber of owners) {
        if (!conflicts.has(issueNumber)) {
          conflicts.set(issueNumber, new Set());
        }
        // Add all other owners as conflicts (Set automatically deduplicates)
        for (const otherOwner of owners) {
          if (otherOwner !== issueNumber) {
            conflicts.get(issueNumber)!.add(otherOwner);
          }
        }
      }
    }
  }

  // Convert Sets to arrays for return type
  const result = new Map<number, number[]>();
  for (const [issueNumber, conflictSet] of conflicts.entries()) {
    result.set(issueNumber, Array.from(conflictSet));
  }

  if (result.size > 0) {
    logger.warn('File conflicts detected', {
      conflictCount: result.size,
      conflicts: Array.from(result.entries()).map(([issue, conflicting]) => ({
        issue,
        conflictsWith: conflicting,
      })),
    });
  }

  return result;
}

/**
 * Clear the extraction cache.
 * Useful for testing or to free memory.
 */
export function clearExtractionCache(): void {
  extractionCache.clear();
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
