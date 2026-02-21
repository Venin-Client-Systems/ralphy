/**
 * Tests for DependencyGraph
 */

import { describe, it, expect } from 'vitest';
import { DependencyGraph } from '../lib/dependency-graph.js';
import type { Task } from '../lib/types.js';

describe('DependencyGraph', () => {
  describe('addTask', () => {
    it('should add task without dependencies', () => {
      const graph = new DependencyGraph();
      const task: Task = {
        issueNumber: 1,
        title: 'Task 1',
        body: 'Body',
        labels: [],
        domain: 'backend',
        status: 'pending',
      };

      graph.addTask(task, []);

      const ready = graph.getReadyTasks(new Set());
      expect(ready).toContain(1);
    });

    it('should add task with dependencies', () => {
      const graph = new DependencyGraph();

      const task1: Task = {
        issueNumber: 1,
        title: 'Task 1',
        body: 'Body',
        labels: [],
        domain: 'backend',
        status: 'pending',
      };

      const task2: Task = {
        issueNumber: 2,
        title: 'Task 2',
        body: 'Body',
        labels: [],
        domain: 'backend',
        status: 'pending',
      };

      graph.addTask(task1, []);
      graph.addTask(task2, [1]);

      const ready = graph.getReadyTasks(new Set());
      expect(ready).toContain(1);
      expect(ready).not.toContain(2);
    });

    it('should update blocks array when adding dependent tasks', () => {
      const graph = new DependencyGraph();

      const task1: Task = {
        issueNumber: 1,
        title: 'Task 1',
        body: 'Body',
        labels: [],
        domain: 'backend',
        status: 'pending',
      };

      const task2: Task = {
        issueNumber: 2,
        title: 'Task 2',
        body: 'Body',
        labels: [],
        domain: 'backend',
        status: 'pending',
      };

      graph.addTask(task1, []);
      graph.addTask(task2, [1]);

      const blockedBy = graph.getBlockedBy(1);
      expect(blockedBy).toContain(2);
    });
  });

  describe('getReadyTasks', () => {
    it('should return tasks with no dependencies', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, []);

      const ready = graph.getReadyTasks(new Set());
      expect(ready).toHaveLength(2);
      expect(ready).toContain(1);
      expect(ready).toContain(2);
    });

    it('should return tasks whose dependencies are met', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, [1]);
      graph.addTask({ issueNumber: 3 } as Task, [1]);

      const ready = graph.getReadyTasks(new Set());
      expect(ready).toHaveLength(1);
      expect(ready).toContain(1);

      const readyAfter1 = graph.getReadyTasks(new Set([1]));
      expect(readyAfter1).toHaveLength(2);
      expect(readyAfter1).toContain(2);
      expect(readyAfter1).toContain(3);
    });

    it('should exclude completed tasks', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, []);

      const ready = graph.getReadyTasks(new Set([1]));
      expect(ready).toHaveLength(1);
      expect(ready).toContain(2);
      expect(ready).not.toContain(1);
    });

    it('should handle chain dependencies', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, [1]);
      graph.addTask({ issueNumber: 3 } as Task, [2]);

      const ready1 = graph.getReadyTasks(new Set());
      expect(ready1).toEqual([1]);

      const ready2 = graph.getReadyTasks(new Set([1]));
      expect(ready2).toEqual([2]);

      const ready3 = graph.getReadyTasks(new Set([1, 2]));
      expect(ready3).toEqual([3]);
    });
  });

  describe('getBlockedTasks', () => {
    it('should return empty map when no tasks are blocked', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, []);

      const blocked = graph.getBlockedTasks();
      expect(blocked.size).toBe(0);
    });

    it('should return blocked tasks and their dependencies', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, [1]);
      graph.addTask({ issueNumber: 3 } as Task, [1, 2]);

      const blocked = graph.getBlockedTasks();
      expect(blocked.size).toBe(2);
      expect(blocked.get(2)).toEqual([1]);
      expect(blocked.get(3)).toEqual([1, 2]);
    });
  });

  describe('hasCycles', () => {
    it('should return false for acyclic graph', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, [1]);
      graph.addTask({ issueNumber: 3 } as Task, [1]);

      expect(graph.hasCycles()).toBe(false);
    });

    it('should detect simple cycle', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, [2]);
      graph.addTask({ issueNumber: 2 } as Task, [1]);

      expect(graph.hasCycles()).toBe(true);
    });

    it('should detect complex cycle', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, [1]);
      graph.addTask({ issueNumber: 3 } as Task, [2]);
      graph.addTask({ issueNumber: 4 } as Task, [3]);
      // Create cycle: 2 depends on 4
      graph.addTask({ issueNumber: 2 } as Task, [1, 4]);

      expect(graph.hasCycles()).toBe(true);
    });

    it('should handle self-referencing task', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, [1]);

      expect(graph.hasCycles()).toBe(true);
    });
  });

  describe('getExecutionOrder', () => {
    it('should return topological sort for acyclic graph', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, [1]);
      graph.addTask({ issueNumber: 3 } as Task, [1]);
      graph.addTask({ issueNumber: 4 } as Task, [2, 3]);

      const order = graph.getExecutionOrder();

      // 1 should come before 2, 3, 4
      expect(order.indexOf(1)).toBeLessThan(order.indexOf(2));
      expect(order.indexOf(1)).toBeLessThan(order.indexOf(3));
      expect(order.indexOf(1)).toBeLessThan(order.indexOf(4));

      // 2 and 3 should come before 4
      expect(order.indexOf(2)).toBeLessThan(order.indexOf(4));
      expect(order.indexOf(3)).toBeLessThan(order.indexOf(4));
    });

    it('should throw for cyclic graph', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, [2]);
      graph.addTask({ issueNumber: 2 } as Task, [1]);

      expect(() => graph.getExecutionOrder()).toThrow(
        'Cannot create execution order: dependency graph has cycles'
      );
    });
  });

  describe('getBlockedBy', () => {
    it('should return tasks blocked by a specific task', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, [1]);
      graph.addTask({ issueNumber: 3 } as Task, [1]);

      const blockedBy1 = graph.getBlockedBy(1);
      expect(blockedBy1).toHaveLength(2);
      expect(blockedBy1).toContain(2);
      expect(blockedBy1).toContain(3);
    });

    it('should return empty array for task with no blockers', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);

      const blockedBy = graph.getBlockedBy(1);
      expect(blockedBy).toHaveLength(0);
    });
  });

  describe('getDependencies', () => {
    it('should return dependencies of a task', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, [1]);
      graph.addTask({ issueNumber: 3 } as Task, [1, 2]);

      const deps = graph.getDependencies(3);
      expect(deps).toHaveLength(2);
      expect(deps).toContain(1);
      expect(deps).toContain(2);
    });

    it('should return empty array for task with no dependencies', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);

      const deps = graph.getDependencies(1);
      expect(deps).toHaveLength(0);
    });
  });

  describe('canStart', () => {
    it('should return true for task with no dependencies', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);

      expect(graph.canStart(1, new Set())).toBe(true);
    });

    it('should return false when dependencies not met', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, [1]);

      expect(graph.canStart(2, new Set())).toBe(false);
    });

    it('should return true when all dependencies met', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, [1]);

      expect(graph.canStart(2, new Set([1]))).toBe(true);
    });

    it('should return false for non-existent task', () => {
      const graph = new DependencyGraph();

      expect(graph.canStart(999, new Set())).toBe(false);
    });
  });

  describe('visualize', () => {
    it('should generate ASCII visualization', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, [1]);
      graph.addTask({ issueNumber: 3 } as Task, [1, 2]);

      const output = graph.visualize();

      expect(output).toContain('Dependency Graph');
      expect(output).toContain('#1');
      expect(output).toContain('#2');
      expect(output).toContain('#3');
      expect(output).toContain('depends on');
      expect(output).toContain('blocks');
    });

    it('should handle empty graph', () => {
      const graph = new DependencyGraph();

      const output = graph.visualize();

      expect(output).toContain('Dependency Graph');
    });
  });

  describe('toMermaid', () => {
    it('should generate Mermaid syntax', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);
      graph.addTask({ issueNumber: 2 } as Task, [1]);
      graph.addTask({ issueNumber: 3 } as Task, [1, 2]);

      const mermaid = graph.toMermaid();

      expect(mermaid).toContain('graph TD');
      expect(mermaid).toContain('T1[Task #1]');
      expect(mermaid).toContain('T2[Task #2]');
      expect(mermaid).toContain('T3[Task #3]');
      expect(mermaid).toContain('T1 --> T2');
      expect(mermaid).toContain('T2 --> T3');
    });

    it('should handle task with no dependencies', () => {
      const graph = new DependencyGraph();

      graph.addTask({ issueNumber: 1 } as Task, []);

      const mermaid = graph.toMermaid();

      expect(mermaid).toContain('T1[Task #1]');
      expect(mermaid).not.toContain('-->');
    });
  });
});
