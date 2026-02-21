import express from 'express';
import { Server } from 'socket.io';
import { createServer } from 'http';
import cors from 'cors';
import type { SessionState } from '../lib/types.js';
import { logger } from '../lib/logger.js';

let io: Server | null = null;

export function startDashboardServer(port: number = 3000): () => void {
  const app = express();
  app.use(cors());

  const server = createServer(app);
  io = new Server(server, {
    cors: { origin: '*' }
  });

  // Serve HTML dashboard
  app.get('/', (req, res) => {
    res.send(getHTML());
  });

  server.listen(port, () => {
    logger.info('Dashboard server started', { port, url: `http://localhost:${port}` });
    console.log(`\n🌐 Dashboard: http://localhost:${port}\n`);
  });

  return () => {
    server.close();
    io?.close();
  };
}

export function broadcastUpdate(session: SessionState): void {
  if (!io) return;
  io.emit('session_update', session);
}

function getHTML(): string {
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Autoissue Dashboard</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: #0d1117;
      color: #c9d1d9;
      padding: 20px;
    }
    .header {
      background: linear-gradient(135deg, #238636 0%, #1f6feb 100%);
      padding: 30px;
      border-radius: 12px;
      margin-bottom: 20px;
    }
    h1 { font-size: 36px; margin-bottom: 10px; }
    .subtitle { opacity: 0.9; font-size: 18px; }
    .stats {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 15px;
      margin-bottom: 20px;
    }
    .stat-card {
      background: #161b22;
      padding: 20px;
      border-radius: 8px;
      border: 1px solid #30363d;
    }
    .stat-label { opacity: 0.7; font-size: 14px; margin-bottom: 8px; }
    .stat-value { font-size: 32px; font-weight: bold; }
    .stat-value.green { color: #3fb950; }
    .stat-value.red { color: #f85149; }
    .stat-value.blue { color: #58a6ff; }
    .stat-value.yellow { color: #d29922; }
    .tasks {
      background: #161b22;
      border-radius: 8px;
      border: 1px solid #30363d;
      padding: 20px;
      margin-bottom: 20px;
    }
    .task {
      padding: 15px;
      border-bottom: 1px solid #30363d;
      display: flex;
      align-items: center;
      gap: 15px;
    }
    .task:last-child { border-bottom: none; }
    .task-status {
      width: 12px;
      height: 12px;
      border-radius: 50%;
      flex-shrink: 0;
    }
    .task-status.running { background: #d29922; animation: pulse 1.5s infinite; }
    .task-status.completed { background: #3fb950; }
    .task-status.failed { background: #f85149; }
    .task-status.pending { background: #6e7681; }
    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.5; }
    }
    .task-info { flex: 1; }
    .task-title { font-weight: 600; margin-bottom: 4px; }
    .task-meta { font-size: 13px; opacity: 0.7; }
    .progress-bar {
      height: 8px;
      background: #21262d;
      border-radius: 4px;
      overflow: hidden;
      margin-top: 10px;
    }
    .progress-fill {
      height: 100%;
      background: linear-gradient(90deg, #238636, #2ea043);
      transition: width 0.3s;
    }
  </style>
</head>
<body>
  <div class="header">
    <h1>⚡ Autoissue Dashboard</h1>
    <div class="subtitle">Real-time execution monitoring</div>
  </div>

  <div class="stats">
    <div class="stat-card">
      <div class="stat-label">Running Tasks</div>
      <div class="stat-value blue" id="running">0</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Completed</div>
      <div class="stat-value green" id="completed">0</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Failed</div>
      <div class="stat-value red" id="failed">0</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Total Cost</div>
      <div class="stat-value yellow" id="cost">$0.00</div>
    </div>
  </div>

  <div class="tasks">
    <h2 style="margin-bottom: 15px;">Tasks</h2>
    <div id="task-list">
      <div style="opacity: 0.5; text-align: center; padding: 40px;">
        Waiting for data...
      </div>
    </div>
  </div>

  <script src="/socket.io/socket.io.js"></script>
  <script>
    const socket = io();

    socket.on('session_update', (session) => {
      const running = session.tasks.filter(t => t.status === 'running');
      const completed = session.tasks.filter(t => t.status === 'completed');
      const failed = session.tasks.filter(t => t.status === 'failed');

      document.getElementById('running').textContent = running.length;
      document.getElementById('completed').textContent = completed.length;
      document.getElementById('failed').textContent = failed.length;
      document.getElementById('cost').textContent = '$' + session.totalCost.toFixed(2);

      const taskList = document.getElementById('task-list');
      taskList.innerHTML = session.tasks.map(task => \`
        <div class="task">
          <div class="task-status \${task.status}"></div>
          <div class="task-info">
            <div class="task-title">#\${task.issueNumber}: \${task.title}</div>
            <div class="task-meta">
              <span>[\${task.domain}]</span>
              <span>\${task.status}</span>
              \${task.costUsd ? '<span>$' + task.costUsd.toFixed(2) + '</span>' : ''}
              \${task.prNumber ? '<span>PR #' + task.prNumber + '</span>' : ''}
            </div>
          </div>
        </div>
      \`).join('');
    });
  </script>
</body>
</html>`;
}
