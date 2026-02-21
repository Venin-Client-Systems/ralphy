import { BudgetExceededError, ErrorCode } from '../lib/types.js';
import { logger } from '../lib/logger.js';

/**
 * Budget state for a session or task.
 */
export interface BudgetState {
  maxBudgetUsd: number;
  spentUsd: number;
  remainingUsd: number;
  taskCount: number;
  averageCostPerTask: number;
}

/**
 * Budget tracker for monitoring and enforcing spending limits.
 *
 * Checks budget BEFORE execution to prevent overspending.
 */
export class BudgetTracker {
  private spentUsd: number = 0;
  private taskCount: number = 0;
  private taskCosts: number[] = [];

  constructor(private readonly maxBudgetUsd: number) {}

  /**
   * Get current budget state.
   */
  getState(): BudgetState {
    return {
      maxBudgetUsd: this.maxBudgetUsd,
      spentUsd: this.spentUsd,
      remainingUsd: Math.max(0, this.maxBudgetUsd - this.spentUsd),
      taskCount: this.taskCount,
      averageCostPerTask: this.taskCount > 0 ? this.spentUsd / this.taskCount : 0,
    };
  }

  /**
   * Check if we can afford to run another task.
   *
   * @param estimatedCost - Estimated cost for the next task
   * @param taskNumber - Task number (for error messages)
   * @returns true if budget allows, false otherwise
   * @throws BudgetExceededError if budget is exceeded
   */
  canAfford(estimatedCost: number, taskNumber?: number): boolean {
    const state = this.getState();

    if (this.spentUsd + estimatedCost > this.maxBudgetUsd) {
      logger.error('Budget check failed', {
        estimatedCost,
        spent: this.spentUsd,
        max: this.maxBudgetUsd,
        overage: (this.spentUsd + estimatedCost) - this.maxBudgetUsd,
        taskNumber,
      });

      throw new BudgetExceededError(
        this.spentUsd + estimatedCost,
        this.maxBudgetUsd,
        taskNumber
      );
    }

    logger.debug('Budget check passed', {
      estimatedCost,
      spent: this.spentUsd,
      remaining: state.remainingUsd,
      taskNumber,
    });

    return true;
  }

  /**
   * Record actual cost after task execution.
   *
   * @param actualCost - Actual cost incurred
   */
  recordCost(actualCost: number): void {
    this.spentUsd += actualCost;
    this.taskCount++;
    this.taskCosts.push(actualCost);

    logger.debug('Cost recorded', {
      actualCost,
      totalSpent: this.spentUsd,
      remaining: this.getState().remainingUsd,
      taskCount: this.taskCount,
    });
  }

  /**
   * Estimate cost for next task based on historical data.
   *
   * Uses P90 (90th percentile) of previous task costs for conservative estimate.
   * Falls back to maxBudgetUsd if no history available.
   */
  estimateNextTaskCost(): number {
    if (this.taskCosts.length === 0) {
      // No history, use max budget as conservative estimate
      return this.maxBudgetUsd;
    }

    if (this.taskCosts.length < 3) {
      // Not enough data, use average
      return this.getState().averageCostPerTask;
    }

    // Use P90 for conservative estimate
    const sorted = [...this.taskCosts].sort((a, b) => a - b);
    // P90: ceil(0.9 * n) - 1 for 0-indexed
    const p90Index = Math.ceil(sorted.length * 0.9) - 1;
    return sorted[p90Index];
  }

  /**
   * Get cost statistics for analysis.
   */
  getStatistics(): {
    min: number;
    max: number;
    mean: number;
    median: number;
    p90: number;
    total: number;
  } {
    if (this.taskCosts.length === 0) {
      return { min: 0, max: 0, mean: 0, median: 0, p90: 0, total: 0 };
    }

    const sorted = [...this.taskCosts].sort((a, b) => a - b);
    const sum = sorted.reduce((a, b) => a + b, 0);

    // Median: for even length, average of two middle values; for odd, middle value
    let median: number;
    if (sorted.length % 2 === 0) {
      const mid = sorted.length / 2;
      median = (sorted[mid - 1] + sorted[mid]) / 2;
    } else {
      median = sorted[Math.floor(sorted.length / 2)];
    }

    return {
      min: sorted[0],
      max: sorted[sorted.length - 1],
      mean: sum / sorted.length,
      median,
      p90: sorted[Math.ceil(sorted.length * 0.9) - 1],
      total: sum,
    };
  }

  /**
   * Check if budget allows running N more tasks.
   *
   * @param taskCount - Number of tasks to check
   * @returns true if budget likely allows, false otherwise
   */
  canAffordTasks(taskCount: number): boolean {
    const estimatedCost = this.estimateNextTaskCost() * taskCount;
    const state = this.getState();

    const canAfford = this.spentUsd + estimatedCost <= this.maxBudgetUsd;

    logger.info('Batch budget check', {
      taskCount,
      estimatedCost,
      estimatedCostPerTask: this.estimateNextTaskCost(),
      spent: this.spentUsd,
      remaining: state.remainingUsd,
      canAfford,
    });

    return canAfford;
  }

  /**
   * Reset tracker (useful for testing).
   */
  reset(): void {
    this.spentUsd = 0;
    this.taskCount = 0;
    this.taskCosts = [];
  }
}
