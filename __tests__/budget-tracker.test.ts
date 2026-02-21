import { describe, it, expect, beforeEach } from 'vitest';
import { BudgetTracker } from '../core/budget-tracker.js';
import { BudgetExceededError } from '../lib/types.js';

describe('BudgetTracker', () => {
  let tracker: BudgetTracker;

  beforeEach(() => {
    tracker = new BudgetTracker(100.0);
  });

  describe('getState', () => {
    it('returns initial state correctly', () => {
      const state = tracker.getState();

      expect(state.maxBudgetUsd).toBe(100.0);
      expect(state.spentUsd).toBe(0);
      expect(state.remainingUsd).toBe(100.0);
      expect(state.taskCount).toBe(0);
      expect(state.averageCostPerTask).toBe(0);
    });

    it('returns updated state after recording costs', () => {
      tracker.recordCost(10.0);
      tracker.recordCost(20.0);

      const state = tracker.getState();

      expect(state.spentUsd).toBe(30.0);
      expect(state.remainingUsd).toBe(70.0);
      expect(state.taskCount).toBe(2);
      expect(state.averageCostPerTask).toBe(15.0);
    });
  });

  describe('canAfford', () => {
    it('allows task within budget', () => {
      expect(tracker.canAfford(50.0)).toBe(true);
    });

    it('throws BudgetExceededError when over budget', () => {
      expect(() => tracker.canAfford(150.0)).toThrow(BudgetExceededError);
    });

    it('accounts for previously spent budget', () => {
      tracker.recordCost(80.0);

      expect(() => tracker.canAfford(30.0)).toThrow(BudgetExceededError);
    });

    it('allows task at exact budget limit', () => {
      expect(tracker.canAfford(100.0)).toBe(true);
    });

    it('includes task number in error', () => {
      try {
        tracker.canAfford(150.0, 5);
        throw new Error('Should have thrown BudgetExceededError');
      } catch (err) {
        expect(err).toBeInstanceOf(BudgetExceededError);
        if (err instanceof BudgetExceededError) {
          expect(err.metadata?.taskNumber).toBe(5);
        }
      }
    });
  });

  describe('recordCost', () => {
    it('updates spent amount', () => {
      tracker.recordCost(10.0);

      const state = tracker.getState();
      expect(state.spentUsd).toBe(10.0);
      expect(state.taskCount).toBe(1);
    });

    it('accumulates multiple costs', () => {
      tracker.recordCost(10.0);
      tracker.recordCost(20.0);
      tracker.recordCost(30.0);

      const state = tracker.getState();
      expect(state.spentUsd).toBe(60.0);
      expect(state.taskCount).toBe(3);
      expect(state.averageCostPerTask).toBe(20.0);
    });
  });

  describe('estimateNextTaskCost', () => {
    it('uses max budget when no history', () => {
      expect(tracker.estimateNextTaskCost()).toBe(100.0);
    });

    it('uses average with limited history', () => {
      tracker.recordCost(10.0);
      tracker.recordCost(20.0);

      expect(tracker.estimateNextTaskCost()).toBe(15.0);
    });

    it('uses P90 with sufficient history', () => {
      // Record 10 tasks with varying costs
      const costs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
      costs.forEach((cost) => tracker.recordCost(cost));

      // P90 of [1,2,3,4,5,6,7,8,9,10] is 9
      expect(tracker.estimateNextTaskCost()).toBe(9);
    });

    it('handles outliers conservatively with P90', () => {
      const costs = [5, 5, 5, 5, 5, 5, 5, 5, 100, 100]; // Two outliers for P90
      costs.forEach((cost) => tracker.recordCost(cost));

      // P90 of [5,5,5,5,5,5,5,5,100,100] at index ceil(10*0.9)-1 = 8 is 100
      expect(tracker.estimateNextTaskCost()).toBe(100);
    });
  });

  describe('canAffordTasks', () => {
    it('checks if budget allows multiple tasks', () => {
      tracker.recordCost(10.0);
      tracker.recordCost(10.0);

      // Estimate per task is 10, so 5 tasks = 50
      // Spent 20, remaining 80, can afford 5 tasks
      expect(tracker.canAffordTasks(5)).toBe(true);
    });

    it('returns false when budget insufficient for multiple tasks', () => {
      tracker.recordCost(10.0);
      tracker.recordCost(10.0);

      // Estimate per task is 10, so 10 tasks = 100
      // Spent 20, remaining 80, cannot afford 10 tasks
      expect(tracker.canAffordTasks(10)).toBe(false);
    });

    it('uses conservative estimate (P90)', () => {
      // Record tasks with mostly low cost, one high cost
      [5, 5, 5, 5, 5, 5, 5, 5, 5, 50].forEach((cost) => tracker.recordCost(cost));

      // P90 is 50, so 2 tasks = 100
      // Already spent 95, cannot afford 2 more tasks
      expect(tracker.canAffordTasks(2)).toBe(false);
    });
  });

  describe('getStatistics', () => {
    it('returns zeros for empty history', () => {
      const stats = tracker.getStatistics();

      expect(stats.min).toBe(0);
      expect(stats.max).toBe(0);
      expect(stats.mean).toBe(0);
      expect(stats.median).toBe(0);
      expect(stats.p90).toBe(0);
      expect(stats.total).toBe(0);
    });

    it('calculates statistics correctly', () => {
      [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].forEach((cost) => tracker.recordCost(cost));

      const stats = tracker.getStatistics();

      expect(stats.min).toBe(1);
      expect(stats.max).toBe(10);
      expect(stats.mean).toBe(5.5);
      expect(stats.median).toBe(5.5); // Average of 5th and 6th elements (5 and 6)
      expect(stats.p90).toBe(9); // ceil(10*0.9)-1 = 8, which is value 9
      expect(stats.total).toBe(55);
    });
  });

  describe('reset', () => {
    it('clears all state', () => {
      tracker.recordCost(10.0);
      tracker.recordCost(20.0);

      tracker.reset();

      const state = tracker.getState();
      expect(state.spentUsd).toBe(0);
      expect(state.taskCount).toBe(0);
      expect(state.remainingUsd).toBe(100.0);
    });
  });

  describe('integration scenarios', () => {
    it('prevents overspending on final task', () => {
      tracker.recordCost(90.0);

      // Try to run task that would exceed budget
      expect(() => tracker.canAfford(20.0)).toThrow(BudgetExceededError);
    });

    it('allows exactly budget-fitting tasks', () => {
      tracker.recordCost(50.0);

      // Exactly 50 remaining
      expect(tracker.canAfford(50.0)).toBe(true);

      tracker.recordCost(50.0);

      // Now at limit
      const state = tracker.getState();
      expect(state.spentUsd).toBe(100.0);
      expect(state.remainingUsd).toBe(0);
    });

    it('provides accurate estimates for batch planning', () => {
      // Simulate 5 completed tasks
      [10, 12, 11, 13, 14].forEach((cost) => tracker.recordCost(cost));

      // Spent 60, remaining 40
      // Average ~12, P90 ~14, so estimate 2-3 more tasks possible
      expect(tracker.canAffordTasks(2)).toBe(true);
      expect(tracker.canAffordTasks(5)).toBe(false);
    });
  });
});
