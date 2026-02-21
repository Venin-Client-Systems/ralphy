# Autoissue Dashboard API

REST API endpoints for programmatic access to Autoissue metrics and state.

## Base URL

```
http://localhost:3030/api
```

(Port can be configured via `dashboard.port` in config)

---

## Endpoints

### GET /api/health

Health check endpoint.

**Response:**
```json
{
  "status": "ok",
  "timestamp": "2026-02-21T12:00:00.000Z",
  "session": "abc123..." // Current session ID or null
}
```

---

### GET /api/metrics

Get all metrics in a single response.

**Response:**
```json
{
  "session": {
    "sessionId": "abc123...",
    "status": "running",
    "totalCost": 2.35,
    "startedAt": "2026-02-21T12:00:00.000Z",
    "completedAt": null,
    "tasks": {
      "total": 10,
      "pending": 2,
      "running": 3,
      "completed": 4,
      "failed": 1
    }
  },
  "budget": {
    "state": {
      "maxBudgetUsd": 50.0,
      "spentUsd": 2.35,
      "remainingUsd": 47.65,
      "taskCount": 5,
      "averageCostPerTask": 0.47
    },
    "statistics": {
      "min": 0.12,
      "max": 1.20,
      "mean": 0.47,
      "median": 0.45,
      "p90": 0.95,
      "total": 2.35
    }
  },
  "circuitBreaker": {
    "state": "closed",
    "failureCount": 0,
    "threshold": 5
  },
  "errors": [
    {
      "operation": "Task #123 (sonnet)",
      "attempts": 2,
      "successes": 1,
      "failures": 1,
      "errorsByType": {
        "timeout": 1
      }
    }
  ]
}
```

---

### GET /api/metrics/budget

Get budget tracker state and statistics.

**Response:**
```json
{
  "state": {
    "maxBudgetUsd": 50.0,
    "spentUsd": 2.35,
    "remainingUsd": 47.65,
    "taskCount": 5,
    "averageCostPerTask": 0.47
  },
  "statistics": {
    "min": 0.12,
    "max": 1.20,
    "mean": 0.47,
    "median": 0.45,
    "p90": 0.95,
    "total": 2.35
  }
}
```

**Error Response (404):**
```json
{
  "error": "Budget tracker not available"
}
```

---

### GET /api/metrics/circuit-breaker

Get circuit breaker state.

**Response:**
```json
{
  "state": "closed",  // "closed" | "open" | "half_open"
  "failureCount": 0,
  "threshold": 5
}
```

**States:**
- `closed` - Normal operation
- `open` - Failing fast after threshold failures
- `half_open` - Testing if service recovered

**Error Response (404):**
```json
{
  "error": "Circuit breaker not available"
}
```

---

### GET /api/metrics/errors

Get error metrics from error boundary observer.

**Response:**
```json
[
  {
    "operation": "Task #123 (sonnet)",
    "attempts": 2,
    "successes": 1,
    "failures": 1,
    "errorsByType": {
      "timeout": 1
    },
    "lastError": {
      "type": "timeout",
      "message": "Agent operation timed out",
      "retryable": true,
      "recoveryHint": "Increase timeoutMs..."
    },
    "lastAttemptAt": 1708516800000
  }
]
```

**Error Types:**
- `validation` - Input validation failure
- `rate_limit` - API rate limit (429)
- `quota_exceeded` - API quota exceeded
- `timeout` - Operation timeout
- `crash` - Agent process crash
- `network` - Network connectivity issue
- `unknown` - Unknown error type

**Error Response (404):**
```json
{
  "error": "Error observer not available"
}
```

---

### GET /api/session

Get current session state.

**Response:**
```json
{
  "sessionId": "abc123...",
  "status": "running",
  "label": "ralphy-1",
  "tasks": [...],
  "totalCost": 2.35,
  "startedAt": "2026-02-21T12:00:00.000Z",
  "config": {...}
}
```

**Error Response (404):**
```json
{
  "error": "No active session"
}
```

---

### GET /api/session/tasks

Get current session tasks only.

**Response:**
```json
{
  "sessionId": "abc123...",
  "tasks": [
    {
      "issueNumber": 123,
      "title": "Fix login bug",
      "domain": "backend",
      "status": "completed",
      "costUsd": 0.45,
      "prNumber": 456,
      "startedAt": "2026-02-21T12:00:00.000Z",
      "completedAt": "2026-02-21T12:05:00.000Z"
    }
  ]
}
```

**Error Response (404):**
```json
{
  "error": "No active session"
}
```

---

### POST /api/circuit-breaker/reset

Manually reset the circuit breaker to closed state.

**Response:**
```json
{
  "success": true,
  "message": "Circuit breaker reset to closed state",
  "state": {
    "state": "closed",
    "failureCount": 0,
    "threshold": 5
  }
}
```

**Error Response (404):**
```json
{
  "error": "Circuit breaker not available"
}
```

---

## Usage Examples

### cURL

```bash
# Get all metrics
curl http://localhost:3030/api/metrics

# Get budget state
curl http://localhost:3030/api/metrics/budget

# Get circuit breaker state
curl http://localhost:3030/api/metrics/circuit-breaker

# Reset circuit breaker
curl -X POST http://localhost:3030/api/circuit-breaker/reset
```

### JavaScript/Node.js

```javascript
// Get all metrics
const response = await fetch('http://localhost:3030/api/metrics');
const metrics = await response.json();

console.log('Total cost:', metrics.session.totalCost);
console.log('Budget remaining:', metrics.budget.state.remainingUsd);
console.log('Circuit breaker:', metrics.circuitBreaker.state);

// Reset circuit breaker if open
if (metrics.circuitBreaker.state === 'open') {
  await fetch('http://localhost:3030/api/circuit-breaker/reset', {
    method: 'POST'
  });
}
```

### Python

```python
import requests

# Get all metrics
response = requests.get('http://localhost:3030/api/metrics')
metrics = response.json()

print(f"Total cost: ${metrics['session']['totalCost']}")
print(f"Budget remaining: ${metrics['budget']['state']['remainingUsd']}")
print(f"Circuit breaker: {metrics['circuitBreaker']['state']}")

# Reset circuit breaker
if metrics['circuitBreaker']['state'] == 'open':
    requests.post('http://localhost:3030/api/circuit-breaker/reset')
```

---

## Error Handling

All endpoints return appropriate HTTP status codes:

- `200 OK` - Success
- `404 Not Found` - Resource not available (e.g., no active session, metric not initialized)
- `500 Internal Server Error` - Server error

Error responses include a JSON body with an `error` field:

```json
{
  "error": "Description of the error"
}
```

---

## Authentication

The dashboard supports three authentication modes:

### Configuration

Add to `autoissue.config.json`:

```json
{
  "dashboard": {
    "enabled": true,
    "port": 3030,
    "auth": {
      "enabled": true,
      "type": "basic",  // or "token" or "both"
      "username": "admin",
      "password": "your-secure-password",
      "token": "your-secure-token"
    }
  }
}
```

### Authentication Types

**1. Basic Authentication (`type: "basic"`)**

Standard HTTP Basic Auth with username and password.

```bash
curl -u admin:password http://localhost:3030/api/metrics
```

**2. Token Authentication (`type: "token"`)**

Bearer token in Authorization header.

```bash
curl -H "Authorization: Bearer your-token" http://localhost:3030/api/metrics
```

**3. Both (`type: "both"`)**

Accepts either Basic or Token auth.

```bash
# Basic auth
curl -u admin:password http://localhost:3030/api/metrics

# OR Token auth
curl -H "Authorization: Bearer your-token" http://localhost:3030/api/metrics
```

### Health Check Exemption

The `/api/health` endpoint is **always accessible without authentication** for health monitoring systems.

```bash
# No auth required
curl http://localhost:3030/api/health
```

### Usage with Authentication

**cURL:**
```bash
# Basic auth
curl -u admin:password http://localhost:3030/api/metrics

# Token auth
curl -H "Authorization: Bearer my-token" http://localhost:3030/api/metrics

# POST with auth
curl -X POST -u admin:password http://localhost:3030/api/circuit-breaker/reset
```

**JavaScript:**
```javascript
// Basic auth
const response = await fetch('http://localhost:3030/api/metrics', {
  headers: {
    'Authorization': 'Basic ' + btoa('admin:password')
  }
});

// Token auth
const response = await fetch('http://localhost:3030/api/metrics', {
  headers: {
    'Authorization': 'Bearer my-token'
  }
});
```

**Python:**
```python
# Basic auth
import requests
response = requests.get('http://localhost:3030/api/metrics',
                       auth=('admin', 'password'))

# Token auth
headers = {'Authorization': 'Bearer my-token'}
response = requests.get('http://localhost:3030/api/metrics',
                       headers=headers)
```

### Security Best Practices

1. **Use HTTPS in production** - Prevents credential interception
2. **Strong passwords** - Use a password manager to generate strong passwords
3. **Rotate tokens regularly** - Change tokens periodically
4. **Restrict network access** - Run dashboard on localhost or private network
5. **Use environment variables** - Don't commit credentials to git

```bash
# Example: Load credentials from environment
{
  "dashboard": {
    "auth": {
      "enabled": true,
      "username": "${DASHBOARD_USER}",
      "password": "${DASHBOARD_PASS}",
      "token": "${DASHBOARD_TOKEN}"
    }
  }
}
```

### Disabling Authentication

For local development, you can disable auth:

```json
{
  "dashboard": {
    "enabled": true,
    "auth": {
      "enabled": false
    }
  }
}
```

Or omit the `auth` section entirely (auth disabled by default).

---

## Rate Limiting

No rate limiting is currently implemented. The API is designed for internal monitoring and should not be exposed to untrusted networks.
