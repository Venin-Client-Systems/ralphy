/**
 * Dependency Graph Management
 *
 * Tracks task dependencies and determines execution order.
 * Prevents circular dependencies and ensures tasks execute in the correct sequence.
 */

import { writeFileSync } from 'fs';
import type { Task } from './types.js';

export interface DependencyNode {
  issueNumber: number;
  dependsOn: number[];
  blocks: number[];
}

export class DependencyGraph {
  private nodes = new Map<number, DependencyNode>();

  /**
   * Add a task to the dependency graph.
   */
  addTask(task: Task, dependsOn: number[] = []) {
    this.nodes.set(task.issueNumber, {
      issueNumber: task.issueNumber,
      dependsOn,
      blocks: [],
    });

    // Update blocked tasks
    for (const depIssue of dependsOn) {
      const depNode = this.nodes.get(depIssue);
      if (depNode) {
        depNode.blocks.push(task.issueNumber);
      }
    }
  }

  /**
   * Get tasks that are ready to execute (all dependencies met).
   */
  getReadyTasks(completedIssues: Set<number>): number[] {
    const ready: number[] = [];

    for (const [issueNumber, node] of this.nodes) {
      // Skip if already completed
      if (completedIssues.has(issueNumber)) continue;

      // Check if all dependencies are met
      const allDepsComplete = node.dependsOn.every((dep) => completedIssues.has(dep));

      if (allDepsComplete) {
        ready.push(issueNumber);
      }
    }

    return ready;
  }

  /**
   * Get all blocked tasks and their dependencies.
   */
  getBlockedTasks(): Map<number, number[]> {
    const blocked = new Map<number, number[]>();

    for (const [issueNumber, node] of this.nodes) {
      if (node.dependsOn.length > 0) {
        blocked.set(issueNumber, node.dependsOn);
      }
    }

    return blocked;
  }

  /**
   * Detect circular dependencies in the graph.
   */
  hasCycles(): boolean {
    const visited = new Set<number>();
    const recursionStack = new Set<number>();

    const dfs = (node: number): boolean => {
      visited.add(node);
      recursionStack.add(node);

      const deps = this.nodes.get(node)?.dependsOn || [];
      for (const dep of deps) {
        if (!visited.has(dep)) {
          if (dfs(dep)) return true;
        } else if (recursionStack.has(dep)) {
          return true; // Cycle detected
        }
      }

      recursionStack.delete(node);
      return false;
    };

    for (const node of this.nodes.keys()) {
      if (!visited.has(node)) {
        if (dfs(node)) return true;
      }
    }

    return false;
  }

  /**
   * Get topological sort of tasks (execution order).
   */
  getExecutionOrder(): number[] {
    if (this.hasCycles()) {
      throw new Error('Cannot create execution order: dependency graph has cycles');
    }

    const visited = new Set<number>();
    const order: number[] = [];

    const visit = (node: number) => {
      if (visited.has(node)) return;
      visited.add(node);

      const deps = this.nodes.get(node)?.dependsOn || [];
      for (const dep of deps) {
        visit(dep);
      }

      order.push(node);
    };

    for (const node of this.nodes.keys()) {
      visit(node);
    }

    return order;
  }

  /**
   * Get all tasks that are blocked by a specific task.
   */
  getBlockedBy(issueNumber: number): number[] {
    const node = this.nodes.get(issueNumber);
    return node?.blocks || [];
  }

  /**
   * Get all tasks that a specific task depends on.
   */
  getDependencies(issueNumber: number): number[] {
    const node = this.nodes.get(issueNumber);
    return node?.dependsOn || [];
  }

  /**
   * Check if a task can start (all dependencies completed).
   */
  canStart(issueNumber: number, completedIssues: Set<number>): boolean {
    const node = this.nodes.get(issueNumber);
    if (!node) return false;

    return node.dependsOn.every((dep) => completedIssues.has(dep));
  }

  /**
   * Generate ASCII art visualization of the dependency graph.
   */
  visualize(): string {
    let output = '\n📊 Dependency Graph:\n';
    output += '─'.repeat(60) + '\n';

    for (const [issueNumber, node] of this.nodes) {
      const deps =
        node.dependsOn.length > 0 ? ` ← depends on [${node.dependsOn.join(', ')}]` : '';
      const blocks = node.blocks.length > 0 ? ` → blocks [${node.blocks.join(', ')}]` : '';

      output += `  #${issueNumber}${deps}${blocks}\n`;
    }

    output += '─'.repeat(60) + '\n';
    return output;
  }

  /**
   * Generate Mermaid diagram syntax for the dependency graph.
   */
  toMermaid(): string {
    let output = 'graph TD\n';

    for (const [issueNumber, node] of this.nodes) {
      output += `  T${issueNumber}[Task #${issueNumber}]\n`;

      for (const dep of node.dependsOn) {
        output += `  T${dep} --> T${issueNumber}\n`;
      }
    }

    return output;
  }

  /**
   * Save Mermaid diagram to file for visualization.
   */
  saveMermaidDiagram(outputPath: string): void {
    const mermaid = this.toMermaid();
    const html = `<!DOCTYPE html>
<html>
<head>
  <script src="https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js"></script>
  <script>mermaid.initialize({ startOnLoad: true });</script>
</head>
<body>
  <div class="mermaid">
${mermaid}
  </div>
</body>
</html>`;

    writeFileSync(outputPath, html);
  }
}
