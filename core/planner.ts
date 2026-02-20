// NEW: Smart planner (Echelon didn't have this as a single module)
// Takes a directive, spawns ONE AI call, returns GitHub issue payloads

import { spawnAgent } from './agent.js';

export interface PlannerResult {
  issues: Array<{
    title: string;
    body: string;
    labels: string[];
  }>;
  cost: number;
}

export async function planDirective(
  directive: string,
  repo: string,
  opts: { model: string; maxBudgetUsd: number }
): Promise<PlannerResult> {
  // TODO: Implement
  // 1. Build system prompt
  // 2. Call spawnAgent
  // 3. Parse response for issue data
  // 4. Validate issue payloads
  // 5. Return structured result
  throw new Error('Not implemented');
}
