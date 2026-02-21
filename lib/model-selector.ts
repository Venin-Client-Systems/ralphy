import type { Task, AgentConfig } from './types.js';

/**
 * Select the optimal model for a task based on complexity analysis.
 *
 * Strategy:
 * - Simple tasks (docs, typos, comments) → Haiku (cheaper)
 * - Complex tasks (architecture, refactoring) → Opus (smarter)
 * - Default → Sonnet (balanced)
 *
 * This can reduce costs by 50-70% for simple tasks.
 */
export function selectOptimalModel(task: Task, config: AgentConfig): string {
  // Override if user specified non-sonnet model in config
  if (config.model !== 'sonnet') {
    return config.model;
  }

  const titleLower = task.title.toLowerCase();
  const bodyLower = task.body.toLowerCase();
  const combined = `${titleLower} ${bodyLower}`;

  // Simple tasks → Haiku (cheaper, 5x cost reduction)
  const simpleKeywords = [
    'docs',
    'documentation',
    'readme',
    'comment',
    'typo',
    'simple',
    'update',
    'add comment',
    'fix typo',
    'rename',
    'improve wording',
  ];

  if (simpleKeywords.some((kw) => combined.includes(kw))) {
    return 'haiku';
  }

  // Complex tasks → Opus (smarter, better for architecture)
  const complexKeywords = [
    'architecture',
    'refactor',
    'redesign',
    'complex',
    'migrate',
    'rewrite',
    'performance',
    'optimize',
    'scale',
  ];

  if (complexKeywords.some((kw) => combined.includes(kw))) {
    return 'opus';
  }

  // Check labels for explicit complexity markers
  if (task.labels.includes('complex') || task.labels.includes('architecture')) {
    return 'opus';
  }

  if (task.labels.includes('simple') || task.labels.includes('docs')) {
    return 'haiku';
  }

  // Default: Sonnet (balanced cost/performance)
  return 'sonnet';
}
