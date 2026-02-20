import { render } from 'ink';
import React from 'react';
import { Dashboard } from './Dashboard.js';
import type { SessionState } from '../lib/types.js';

let instance: any = null;

export function startUI(session: SessionState) {
  if (instance) return;
  instance = render(
    <Dashboard
      tasks={session.tasks}
      totalCost={session.totalCost}
      maxBudget={session.config.maxTotalBudgetUsd}
    />
  );
}

export function updateUI(session: SessionState) {
  if (!instance) {
    startUI(session);
    return;
  }
  instance.rerender(
    <Dashboard
      tasks={session.tasks}
      totalCost={session.totalCost}
      maxBudget={session.config.maxTotalBudgetUsd}
    />
  );
}

export function stopUI() {
  if (instance) {
    instance.unmount();
    instance = null;
  }
}
