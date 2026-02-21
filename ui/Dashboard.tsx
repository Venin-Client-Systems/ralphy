import React from 'react';
import { Box, Text } from 'ink';
import Spinner from 'ink-spinner';
import chalk from 'chalk';
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
  estimatedCompletion,
}) => {
  const running = tasks.filter(t => t.status === 'running');
  const completed = tasks.filter(t => t.status === 'completed');
  const failed = tasks.filter(t => t.status === 'failed');
  const pending = tasks.filter(t => t.status === 'pending');

  const costPercent = maxBudget > 0
    ? (totalCost / maxBudget * 100).toFixed(1)
    : '0.0';
  const progressBar = (progress: number = 0) => {
    const filled = Math.floor(progress / 10);
    return '█'.repeat(filled) + '░'.repeat(10 - filled);
  };

  // Calculate progress based on task completion
  const totalTasks = tasks.length;
  const completedTasks = completed.length;
  const overallProgress = totalTasks > 0 ? Math.floor((completedTasks / totalTasks) * 100) : 0;

  return (
    <Box flexDirection="column" padding={1}>
      <Box borderStyle="round" borderColor="cyan" flexDirection="column" paddingX={2}>
        <Text bold color="cyan">Autoissue v2.0 - Real-Time Execution</Text>
        <Text> </Text>

        {running.length > 0 && (
          <>
            <Text bold color="yellow">Active Tasks ({running.length}):</Text>
            {running.map((task, idx) => (
              <Box key={task.issueNumber} flexDirection="column" marginY={0}>
                <Text>
                  <Text color="green"><Spinner type="dots" /></Text>
                  {' '}
                  <Text color="yellow" bold>Slot {idx + 1}:</Text>
                  {' '}
                  <Text color="blue">[{task.domain}]</Text>
                  {' '}
                  {task.title}
                  {' '}
                  <Text color="gray">(#{task.issueNumber})</Text>
                </Text>
              </Box>
            ))}
            <Text> </Text>
          </>
        )}

        {running.length === 0 && pending.length === 0 && (
          <>
            <Text color="gray">No active tasks</Text>
            <Text> </Text>
          </>
        )}

        <Box>
          <Text>
            Queue: <Text color="blue">{pending.length}</Text>
            {' | '}
            Completed: <Text color="green">{completed.length}</Text>
            {' | '}
            Failed: <Text color="red">{failed.length}</Text>
          </Text>
        </Box>

        <Text>
          Overall: {progressBar(overallProgress)} {overallProgress}%
        </Text>

        <Text>
          Cost: <Text color={parseFloat(costPercent) > 80 ? 'red' : 'green'}>${totalCost.toFixed(2)}</Text>
          {' / '}
          ${maxBudget.toFixed(2)}
          {' '}
          ({costPercent}%)
        </Text>

        {estimatedCompletion && (
          <Text color="gray">Est. completion: {estimatedCompletion}</Text>
        )}
      </Box>
    </Box>
  );
};

export const Dashboard: React.FC<DashboardProps> = (props) => (
  <ErrorBoundary>
    <DashboardInner {...props} />
  </ErrorBoundary>
);
