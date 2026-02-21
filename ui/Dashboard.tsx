import React from 'react';
import { Box, Text } from 'ink';
import Spinner from 'ink-spinner';
import type { Task } from '../lib/types.js';

interface DashboardProps {
  tasks: Task[];
  totalCost: number;
  maxBudget: number;
  estimatedCompletion?: string;
}

class ErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { error: Error | null }
> {
  state = { error: null as Error | null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  componentDidCatch(error: Error, errorInfo: React.ErrorInfo) {
    console.error('TUI Error:', error, errorInfo);
  }

  render() {
    if (this.state.error) {
      return (
        <Box padding={1}>
          <Text color="red" bold>TUI Error:</Text>
          <Text color="red">{this.state.error.message}</Text>
        </Box>
      );
    }
    return this.props.children;
  }
}

const DashboardInner: React.FC<DashboardProps> = ({
  tasks,
  totalCost,
  maxBudget,
}) => {
  const running = tasks.filter(t => t.status === 'running');
  const completed = tasks.filter(t => t.status === 'completed');
  const failed = tasks.filter(t => t.status === 'failed');
  const pending = tasks.filter(t => t.status === 'pending');

  const total = tasks.length;
  const done = completed.length + failed.length;
  const progress = total > 0 ? Math.floor((done / total) * 100) : 0;

  // Calculate domain breakdown for queue
  const queueByDomain = pending.reduce((acc, task) => {
    acc[task.domain] = (acc[task.domain] || 0) + 1;
    return acc;
  }, {} as Record<string, number>);

  // Cost stats
  const avgCost = completed.length > 0
    ? completed.reduce((sum, t) => sum + (t.costUsd || 0), 0) / completed.length
    : 0;
  const costPercent = maxBudget > 0 ? (totalCost / maxBudget * 100).toFixed(1) : '0.0';
  const remaining = maxBudget - totalCost;

  // Time stats
  const completedWithTime = completed.filter(t => t.startedAt && t.completedAt);
  const avgDuration = completedWithTime.length > 0
    ? completedWithTime.reduce((sum, t) => {
        const start = new Date(t.startedAt!).getTime();
        const end = new Date(t.completedAt!).getTime();
        return sum + (end - start);
      }, 0) / completedWithTime.length / 1000
    : 0;

  const etaSeconds = avgDuration > 0 ? avgDuration * (pending.length + running.length) : 0;
  const etaMin = Math.floor(etaSeconds / 60);

  // Progress bar
  const barWidth = 40;
  const filled = Math.floor((progress / 100) * barWidth);
  const progressBar = '█'.repeat(filled) + '░'.repeat(barWidth - filled);

  return (
    <Box flexDirection="column" paddingX={2} paddingY={1}>
      {/* Header */}
      <Box borderStyle="round" borderColor="cyan" flexDirection="column" paddingX={2} paddingY={1}>
        <Text bold color="cyan">⚡ Autoissue v2.0 - Parallel Task Execution</Text>
        <Text> </Text>

        {/* Summary Stats */}
        <Box justifyContent="space-between">
          <Box flexDirection="column" width="50%">
            <Text>
              <Text bold color="yellow">Active Sessions: </Text>
              <Text color="yellow">{running.length}</Text>
              <Text dimColor> / {tasks.length} total</Text>
            </Text>
            <Text>
              <Text bold color="green">Completed: </Text>
              <Text color="green">{completed.length}</Text>
              {failed.length > 0 && (
                <>
                  <Text> | </Text>
                  <Text bold color="red">Failed: </Text>
                  <Text color="red">{failed.length}</Text>
                </>
              )}
            </Text>
            <Text>
              <Text bold color="blue">Queued: </Text>
              <Text color="blue">{pending.length}</Text>
              {etaMin > 0 && <Text dimColor> (~{etaMin}m remaining)</Text>}
            </Text>
          </Box>

          <Box flexDirection="column" width="50%">
            <Text>
              <Text bold>Budget: </Text>
              <Text color={parseFloat(costPercent) > 80 ? 'red' : 'green'}>
                ${totalCost.toFixed(2)}
              </Text>
              <Text dimColor> / ${maxBudget.toFixed(2)}</Text>
            </Text>
            <Text>
              <Text bold>Remaining: </Text>
              <Text color={remaining < 5 ? 'red' : 'cyan'}>${remaining.toFixed(2)}</Text>
            </Text>
            {avgCost > 0 && (
              <Text dimColor>Avg: ${avgCost.toFixed(2)}/task</Text>
            )}
          </Box>
        </Box>

        <Text> </Text>

        {/* Progress Bar */}
        <Text>
          <Text bold>Progress: </Text>
          <Text color="cyan">{progressBar}</Text>
          <Text bold color="cyan"> {progress}%</Text>
        </Text>
      </Box>

      <Text> </Text>

      {/* Active Tasks */}
      {running.length > 0 && (
        <Box borderStyle="round" borderColor="yellow" flexDirection="column" paddingX={2} paddingY={1}>
          <Text bold color="yellow">🔄 ACTIVE CLAUDE SESSIONS</Text>
          <Text> </Text>
          {running.map((task) => {
            const elapsed = task.startedAt
              ? Math.floor((Date.now() - new Date(task.startedAt).getTime()) / 1000)
              : 0;
            const min = Math.floor(elapsed / 60);
            const sec = elapsed % 60;

            return (
              <Box key={task.issueNumber} flexDirection="column" marginBottom={1}>
                <Text>
                  <Text color="yellow"><Spinner type="dots" /></Text>
                  {' '}
                  <Text bold color="white">Issue #{task.issueNumber}</Text>
                  {' '}
                  <Text color="magenta" bold>[{task.domain.toUpperCase()}]</Text>
                </Text>
                <Text color="white" dimColor>  {task.title.substring(0, 80)}</Text>
                {task.currentAction && (
                  <Text color="cyan">  ▸ {task.currentAction}</Text>
                )}
                <Text dimColor>
                  {'  '}⏱ {min}m {sec}s
                  {task.costUsd && ` | $${task.costUsd.toFixed(2)}`}
                  {task.agentSessionId && ` | ${task.agentSessionId.substring(0, 8)}`}
                </Text>
              </Box>
            );
          })}
        </Box>
      )}

      {running.length > 0 && <Text> </Text>}

      {/* Queue Info */}
      {pending.length > 0 && (
        <Box borderStyle="round" borderColor="blue" flexDirection="column" paddingX={2} paddingY={1}>
          <Text bold color="blue">⏳ QUEUE ({pending.length} tasks)</Text>
          <Text> </Text>

          {/* Domain breakdown */}
          <Box flexDirection="column">
            <Text dimColor>By domain:</Text>
            {Object.entries(queueByDomain).map(([domain, count]) => (
              <Text key={domain} dimColor>
                {'  '}• {domain}: {count} task{count > 1 ? 's' : ''}
                {domain === 'database' && count > 1 && (
                  <Text color="yellow"> (run sequentially)</Text>
                )}
              </Text>
            ))}
          </Box>

          <Text> </Text>

          {/* Next tasks */}
          <Text dimColor>Next up:</Text>
          {pending.slice(0, 3).map(task => (
            <Text key={task.issueNumber} dimColor>
              {'  '}• #{task.issueNumber} <Text color="magenta">[{task.domain}]</Text> {task.title.substring(0, 50)}
            </Text>
          ))}
          {pending.length > 3 && (
            <Text dimColor>  ...and {pending.length - 3} more</Text>
          )}
        </Box>
      )}

      {pending.length > 0 && <Text> </Text>}

      {/* Recent Activity */}
      {(completed.length > 0 || failed.length > 0) && (
        <Box borderStyle="round" borderColor="green" flexDirection="column" paddingX={2} paddingY={1}>
          <Text bold color="green">✓ RECENT ACTIVITY</Text>
          <Text> </Text>
          {completed.slice(-3).reverse().map(task => (
            <Text key={task.issueNumber} color="green">
              ✓ #{task.issueNumber} <Text dimColor>[{task.domain}]</Text>
              {task.costUsd && <Text dimColor> ${task.costUsd.toFixed(2)}</Text>}
              {task.prNumber && <Text color="cyan"> → PR #{task.prNumber}</Text>}
            </Text>
          ))}
          {failed.slice(-2).reverse().map(task => (
            <Text key={task.issueNumber} color="red">
              ✗ #{task.issueNumber} <Text dimColor>[{task.domain}]</Text>
              {task.error && <Text dimColor> - {task.error.substring(0, 60)}...</Text>}
            </Text>
          ))}
        </Box>
      )}
    </Box>
  );
};

export const Dashboard: React.FC<DashboardProps> = (props) => (
  <ErrorBoundary>
    <DashboardInner {...props} />
  </ErrorBoundary>
);
