import express from 'express';
import { Server } from 'socket.io';
import { createServer } from 'http';
import cors from 'cors';
import basicAuth from 'express-basic-auth';
import type { SessionState, DashboardConfig } from '../lib/types.js';
import { logger } from '../lib/logger.js';
import type { BudgetTracker } from '../core/budget-tracker.js';
import type { CircuitBreaker, ErrorBoundaryObserver } from '../core/error-boundaries.js';

let io: Server | null = null;
let currentSession: SessionState | null = null;
let budgetTracker: BudgetTracker | null = null;
let circuitBreaker: CircuitBreaker | null = null;
let errorObserver: ErrorBoundaryObserver | null = null;

export interface DashboardOptions {
  budgetTracker?: BudgetTracker;
  circuitBreaker?: CircuitBreaker;
  errorObserver?: ErrorBoundaryObserver;
  config?: DashboardConfig;
}

/**
 * Token-based authentication middleware.
 */
function tokenAuthMiddleware(expectedToken: string) {
  return (req: express.Request, res: express.Response, next: express.NextFunction) => {
    const authHeader = req.headers.authorization;

    if (!authHeader) {
      return res.status(401).json({ error: 'Missing Authorization header' });
    }

    const [type, token] = authHeader.split(' ');

    if (type !== 'Bearer') {
      return res.status(401).json({ error: 'Invalid authorization type. Use: Bearer <token>' });
    }

    if (token !== expectedToken) {
      logger.warn('Invalid token attempt', { ip: req.ip });
      return res.status(401).json({ error: 'Invalid token' });
    }

    next();
  };
}

/**
 * Combined auth middleware supporting both Basic and Token auth.
 */
function combinedAuthMiddleware(basicAuthConfig: any, expectedToken: string) {
  return (req: express.Request, res: express.Response, next: express.NextFunction) => {
    const authHeader = req.headers.authorization;

    if (!authHeader) {
      return res.status(401).json({ error: 'Missing Authorization header' });
    }

    // Check if Bearer token
    if (authHeader.startsWith('Bearer ')) {
      const token = authHeader.substring(7);
      if (token === expectedToken) {
        return next();
      }
      logger.warn('Invalid token attempt', { ip: req.ip });
      return res.status(401).json({ error: 'Invalid token' });
    }

    // Check if Basic auth
    if (authHeader.startsWith('Basic ')) {
      // Let express-basic-auth handle it
      return basicAuth(basicAuthConfig)(req, res, next);
    }

    return res.status(401).json({ error: 'Invalid authorization type. Use: Basic or Bearer' });
  };
}

export function startDashboardServer(
  port: number = 3000,
  options?: DashboardOptions
): () => void {
  const app = express();
  app.use(cors());
  app.use(express.json());

  // Store references for API endpoints
  budgetTracker = options?.budgetTracker || null;
  circuitBreaker = options?.circuitBreaker || null;
  errorObserver = options?.errorObserver || null;

  const config = options?.config;
  const authConfig = config?.auth;

  // Setup authentication if enabled
  let authMiddleware: express.RequestHandler | null = null;

  if (authConfig?.enabled) {
    const authType = authConfig.type || 'basic';

    if (authType === 'basic' || authType === 'both') {
      if (!authConfig.username || !authConfig.password) {
        logger.warn('Basic auth enabled but username/password not configured. Auth disabled.');
      } else {
        const basicAuthConfig = {
          users: { [authConfig.username]: authConfig.password },
          challenge: true,
          realm: 'Autoissue Dashboard',
        };

        if (authType === 'basic') {
          authMiddleware = basicAuth(basicAuthConfig);
          logger.info('Dashboard authentication enabled (Basic Auth)');
        } else if (authType === 'both') {
          if (!authConfig.token) {
            logger.warn('Token auth requested but token not configured. Using basic auth only.');
            authMiddleware = basicAuth(basicAuthConfig);
          } else {
            authMiddleware = combinedAuthMiddleware(basicAuthConfig, authConfig.token);
            logger.info('Dashboard authentication enabled (Basic Auth + Token)');
          }
        }
      }
    } else if (authType === 'token') {
      if (!authConfig.token) {
        logger.warn('Token auth enabled but token not configured. Auth disabled.');
      } else {
        authMiddleware = tokenAuthMiddleware(authConfig.token);
        logger.info('Dashboard authentication enabled (Token Auth)');
      }
    }
  }

  // Apply auth middleware to all routes except health check
  if (authMiddleware) {
    app.use((req, res, next) => {
      // Skip auth for health check
      if (req.path === '/api/health') {
        return next();
      }
      // Apply auth to all other routes
      authMiddleware!(req, res, next);
    });
  }

  const server = createServer(app);
  io = new Server(server, {
    cors: { origin: '*' }
  });

  // Serve HTML dashboard
  app.get('/', (req, res) => {
    res.send(getHTML());
  });

  // === REST API ENDPOINTS ===

  /**
   * GET /api/health - Health check (no auth required)
   */
  app.get('/api/health', (req, res) => {
    res.json({
      status: 'ok',
      timestamp: new Date().toISOString(),
      session: currentSession ? currentSession.sessionId : null,
      auth: authConfig?.enabled ? authConfig.type : 'disabled',
    });
  });

  /**
   * GET /api/metrics - Get all metrics
   */
  app.get('/api/metrics', (req, res) => {
    const metrics = {
      session: currentSession ? {
        sessionId: currentSession.sessionId,
        status: currentSession.status,
        totalCost: currentSession.totalCost,
        startedAt: currentSession.startedAt,
        completedAt: currentSession.completedAt,
        tasks: {
          total: currentSession.tasks.length,
          pending: currentSession.tasks.filter(t => t.status === 'pending').length,
          running: currentSession.tasks.filter(t => t.status === 'running').length,
          completed: currentSession.tasks.filter(t => t.status === 'completed').length,
          failed: currentSession.tasks.filter(t => t.status === 'failed').length,
        },
      } : null,
      budget: budgetTracker ? budgetTracker.getState() : null,
      circuitBreaker: circuitBreaker ? circuitBreaker.getState() : null,
      errors: errorObserver ? errorObserver.getMetrics() : null,
    };

    res.json(metrics);
  });

  /**
   * GET /api/metrics/budget - Get budget tracker state
   */
  app.get('/api/metrics/budget', (req, res) => {
    if (!budgetTracker) {
      return res.status(404).json({ error: 'Budget tracker not available' });
    }

    const state = budgetTracker.getState();
    const statistics = budgetTracker.getStatistics();

    res.json({
      state,
      statistics,
    });
  });

  /**
   * GET /api/metrics/circuit-breaker - Get circuit breaker state
   */
  app.get('/api/metrics/circuit-breaker', (req, res) => {
    if (!circuitBreaker) {
      return res.status(404).json({ error: 'Circuit breaker not available' });
    }

    res.json(circuitBreaker.getState());
  });

  /**
   * GET /api/metrics/errors - Get error metrics
   */
  app.get('/api/metrics/errors', (req, res) => {
    if (!errorObserver) {
      return res.status(404).json({ error: 'Error observer not available' });
    }

    res.json(errorObserver.getMetrics());
  });

  /**
   * GET /api/session - Get current session state
   */
  app.get('/api/session', (req, res) => {
    if (!currentSession) {
      return res.status(404).json({ error: 'No active session' });
    }

    res.json(currentSession);
  });

  /**
   * GET /api/session/tasks - Get current session tasks
   */
  app.get('/api/session/tasks', (req, res) => {
    if (!currentSession) {
      return res.status(404).json({ error: 'No active session' });
    }

    res.json({
      sessionId: currentSession.sessionId,
      tasks: currentSession.tasks,
    });
  });

  /**
   * POST /api/circuit-breaker/reset - Reset circuit breaker
   */
  app.post('/api/circuit-breaker/reset', (req, res) => {
    if (!circuitBreaker) {
      return res.status(404).json({ error: 'Circuit breaker not available' });
    }

    circuitBreaker.reset();
    logger.info('Circuit breaker manually reset via API');

    res.json({
      success: true,
      message: 'Circuit breaker reset to closed state',
      state: circuitBreaker.getState(),
    });
  });

  server.listen(port, () => {
    logger.info('Dashboard server started', {
      port,
      url: `http://localhost:${port}`,
      auth: authConfig?.enabled ? authConfig.type : 'disabled',
    });
    console.log(`\n🌐 Dashboard: http://localhost:${port}\n`);

    if (authConfig?.enabled) {
      console.log(`🔐 Authentication: ${authConfig.type}`);
      if (authConfig.type === 'basic' || authConfig.type === 'both') {
        console.log(`   Username: ${authConfig.username}`);
      }
      if (authConfig.type === 'token' || authConfig.type === 'both') {
        console.log(`   Token: ${authConfig.token?.substring(0, 8)}...`);
      }
      console.log();
    }

    console.log(`📡 API Endpoints:`);
    console.log(`   GET  http://localhost:${port}/api/health (no auth)`);
    console.log(`   GET  http://localhost:${port}/api/metrics`);
    console.log(`   GET  http://localhost:${port}/api/metrics/budget`);
    console.log(`   GET  http://localhost:${port}/api/metrics/circuit-breaker`);
    console.log(`   GET  http://localhost:${port}/api/metrics/errors`);
    console.log(`   GET  http://localhost:${port}/api/session`);
    console.log(`   POST http://localhost:${port}/api/circuit-breaker/reset\n`);

    if (authConfig?.enabled) {
      console.log(`💡 Usage examples:`);
      if (authConfig.type === 'basic' || authConfig.type === 'both') {
        console.log(`   curl -u ${authConfig.username}:${authConfig.password} http://localhost:${port}/api/metrics`);
      }
      if (authConfig.type === 'token' || authConfig.type === 'both') {
        console.log(`   curl -H "Authorization: Bearer ${authConfig.token}" http://localhost:${port}/api/metrics`);
      }
      console.log();
    }
  });

  return () => {
    server.close();
    io?.close();
  };
}

export function broadcastUpdate(session: SessionState): void {
  currentSession = session;
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
    .api-link {
      margin-top: 20px;
      padding: 15px;
      background: #161b22;
      border-radius: 8px;
      border: 1px solid #30363d;
      font-size: 14px;
    }
    .api-link a {
      color: #58a6ff;
      text-decoration: none;
    }
    .api-link a:hover {
      text-decoration: underline;
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

  <div class="api-link">
    <strong>📡 API Endpoints:</strong><br>
    <a href="/api/metrics" target="_blank">GET /api/metrics</a> •
    <a href="/api/metrics/budget" target="_blank">GET /api/metrics/budget</a> •
    <a href="/api/metrics/circuit-breaker" target="_blank">GET /api/metrics/circuit-breaker</a> •
    <a href="/api/session" target="_blank">GET /api/session</a>
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
