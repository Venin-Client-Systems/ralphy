/**
 * Sliding Window Scheduler (ported from autoissue/lib/parallel.sh)
 *
 * Schedules tasks with domain-aware parallelization:
 * - Fixed number of slots (e.g., 3 concurrent tasks)
 * - As soon as a slot frees up, schedule the next compatible task
 * - Domain compatibility prevents conflicts (backend + backend = blocked)
 * - Database tasks block everything (schema changes affect all)
 */

import type { Task, Domain } from '../lib/types.js';
import { areDomainsCompatible } from '../lib/domain-classifier.js';
import { logger } from '../lib/logger.js';
import { detectConflicts } from '../lib/conflict-detector.js';

/**
 * A slot in the scheduler (represents a running task).
 */
export interface Slot {
  index: number;
  task: Task | null;
  startedAt: Date | null;
}

/**
 * Scheduler state for the sliding window algorithm.
 */
export interface SchedulerState {
  /** Total number of concurrent slots */
  maxSlots: number;
  /** Current slots (running tasks) */
  slots: Slot[];
  /** Tasks waiting to be scheduled */
  queue: Task[];
  /** Tasks that have been scheduled (completed or running) */
  scheduled: Set<number>;
  /** Total tasks completed */
  completed: number;
  /** Total tasks failed */
  failed: number;
  /** Block reasons for queued tasks */
  blockReasons: Map<number, string>;
}

/**
 * Reason why a task can't be scheduled yet.
 */
export interface BlockReason {
  task: Task;
  reason: string;
  blockedBySlot?: number;
}

/**
 * Create a new scheduler with the given number of parallel slots.
 */
export function createScheduler(maxSlots: number): SchedulerState {
  const slots: Slot[] = [];
  for (let i = 0; i < maxSlots; i++) {
    slots.push({ index: i, task: null, startedAt: null });
  }

  return {
    maxSlots,
    slots,
    queue: [],
    scheduled: new Set(),
    completed: 0,
    failed: 0,
    blockReasons: new Map(),
  };
}

/**
 * Add a task to the scheduler queue.
 */
export function enqueueTask(state: SchedulerState, task: Task): void {
  if (state.scheduled.has(task.issueNumber)) {
    logger.warn('Task already scheduled', { issueNumber: task.issueNumber });
    return;
  }

  state.queue.push(task);
  logger.debug('Task enqueued', { issueNumber: task.issueNumber, queueLength: state.queue.length });
}

/**
 * Add multiple tasks to the queue.
 */
export function enqueueTasks(state: SchedulerState, tasks: Task[]): void {
  for (const task of tasks) {
    enqueueTask(state, task);
  }
}

/**
 * Check if a task is compatible with all currently running tasks.
 */
function isTaskCompatible(state: SchedulerState, task: Task): boolean {
  for (const slot of state.slots) {
    if (!slot.task) continue;

    if (!areDomainsCompatible(task.domain, slot.task.domain)) {
      logger.debug('Task incompatible with running task', {
        task: task.issueNumber,
        taskDomain: task.domain,
        runningTask: slot.task.issueNumber,
        runningDomain: slot.task.domain,
      });
      return false;
    }
  }
  return true;
}

/**
 * Find the next task in the queue that can be scheduled.
 *
 * Returns the task and its index in the queue, or null if no compatible task exists.
 */
function findNextCompatibleTask(state: SchedulerState): { task: Task; queueIndex: number } | null {
  for (let i = 0; i < state.queue.length; i++) {
    const task = state.queue[i];
    if (isTaskCompatible(state, task)) {
      return { task, queueIndex: i };
    }
  }
  return null;
}

/**
 * Find the first free slot, or null if all slots are busy.
 */
function findFreeSlot(state: SchedulerState): Slot | null {
  return state.slots.find((slot) => slot.task === null) ?? null;
}

/**
 * Try to fill empty slots with compatible tasks from the queue.
 *
 * Returns the list of tasks that were scheduled.
 */
export function fillSlots(state: SchedulerState): Task[] {
  const scheduled: Task[] = [];

  // Clear previous block reasons
  state.blockReasons.clear();

  // Detect file conflicts across ALL tasks (not just queue)
  const allTasks = [
    ...state.slots.filter(s => s.task !== null).map(s => s.task!),
    ...state.queue
  ];
  const conflicts = detectConflicts(allTasks);

  const runningIssues = new Set(
    state.slots.filter(s => s.task !== null).map(s => s.task!.issueNumber)
  );

  while (true) {
    // Find a free slot
    const slot = findFreeSlot(state);
    if (!slot) {
      logger.debug('All slots full');
      break;
    }

    // Find next compatible task (considering file conflicts)
    let foundTask = false;
    for (let i = 0; i < state.queue.length; i++) {
      const task = state.queue[i];

      // Check domain compatibility
      if (!isTaskCompatible(state, task)) {
        const runningDomains = state.slots
          .filter(s => s.task !== null)
          .map(s => s.task!.domain)
          .join(', ');
        state.blockReasons.set(
          task.issueNumber,
          `Domain conflict: ${task.domain} cannot run with currently executing domains [${runningDomains}]`
        );
        continue;
      }

      // Check file conflicts
      const taskConflicts = conflicts.get(task.issueNumber) || [];
      const hasFileConflict = taskConflicts.some(c => runningIssues.has(c));
      if (hasFileConflict) {
        const conflictingIssues = taskConflicts.filter(c => runningIssues.has(c)).join(', ');
        state.blockReasons.set(
          task.issueNumber,
          `File conflict: shares files with tasks [#${conflictingIssues}]`
        );
        continue;
      }

      // Task is compatible - schedule it
      const compatibleTask = state.queue.splice(i, 1)[0];

      // Assign to slot
      slot.task = compatibleTask;
      slot.startedAt = new Date();
      state.scheduled.add(compatibleTask.issueNumber);
      runningIssues.add(compatibleTask.issueNumber);

      scheduled.push(compatibleTask);

      logger.info('Task scheduled', {
        issueNumber: compatibleTask.issueNumber,
        domain: compatibleTask.domain,
        slot: slot.index,
        queueRemaining: state.queue.length,
      });

      foundTask = true;
      break;
    }

    if (!foundTask) {
      logger.debug('No compatible tasks in queue', { queueLength: state.queue.length });
      break;
    }
  }

  return scheduled;
}

/**
 * Mark a task as completed and free its slot.
 *
 * Returns true if the task was found and freed, false otherwise.
 */
export function completeTask(state: SchedulerState, issueNumber: number, success: boolean): boolean {
  const slot = state.slots.find((s) => s.task?.issueNumber === issueNumber);
  if (!slot || !slot.task) {
    logger.warn('Task not found in slots', { issueNumber });
    return false;
  }

  const task = slot.task;
  const duration = slot.startedAt ? Date.now() - slot.startedAt.getTime() : 0;

  logger.info('Task completed', {
    issueNumber,
    slot: slot.index,
    success,
    durationMs: duration,
  });

  // Update counters
  if (success) {
    state.completed++;
    task.status = 'completed';
    task.completedAt = new Date();
  } else {
    state.failed++;
    task.status = 'failed';
    task.completedAt = new Date();
  }

  // Free the slot
  slot.task = null;
  slot.startedAt = null;

  return true;
}

/**
 * Get the current scheduler status (for display/logging).
 */
export function getSchedulerStatus(state: SchedulerState) {
  const running = state.slots.filter((s) => s.task !== null).length;
  const queued = state.queue.length;
  const total = state.scheduled.size;

  return {
    running,
    queued,
    completed: state.completed,
    failed: state.failed,
    total,
    slots: state.slots.map((slot) => ({
      index: slot.index,
      task: slot.task
        ? {
            issueNumber: slot.task.issueNumber,
            title: slot.task.title,
            domain: slot.task.domain,
            startedAt: slot.startedAt,
          }
        : null,
    })),
  };
}

/**
 * Get reasons why queued tasks can't be scheduled yet.
 *
 * Useful for debugging and displaying to users.
 */
export function getBlockReasons(state: SchedulerState): BlockReason[] {
  const reasons: BlockReason[] = [];

  for (const task of state.queue) {
    // Find which slot is blocking this task
    for (const slot of state.slots) {
      if (!slot.task) continue;

      if (!areDomainsCompatible(task.domain, slot.task.domain)) {
        reasons.push({
          task,
          reason: `Blocked by ${slot.task.domain} task in slot ${slot.index + 1}`,
          blockedBySlot: slot.index,
        });
        break; // Only report first blocker
      }
    }

    // If not blocked by compatibility, it's just waiting for a free slot
    const freeSlot = findFreeSlot(state);
    if (freeSlot && isTaskCompatible(state, task)) {
      reasons.push({
        task,
        reason: 'Compatible, waiting for slot (should be scheduled next)',
      });
    }
  }

  return reasons;
}

/**
 * Check if the scheduler has any active work (running or queued).
 */
export function hasWork(state: SchedulerState): boolean {
  return state.slots.some((s) => s.task !== null) || state.queue.length > 0;
}

/**
 * Check if all work is complete (nothing running, nothing queued).
 */
export function isComplete(state: SchedulerState): boolean {
  return !hasWork(state);
}

/**
 * Get summary statistics.
 */
export function getSummary(state: SchedulerState) {
  return {
    total: state.scheduled.size,
    completed: state.completed,
    failed: state.failed,
    running: state.slots.filter((s) => s.task !== null).length,
    queued: state.queue.length,
    successRate: state.completed + state.failed > 0
      ? (state.completed / (state.completed + state.failed)) * 100
      : 0,
  };
}
