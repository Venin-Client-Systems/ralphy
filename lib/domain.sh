# ============================================
# DOMAIN DETECTION & PARALLEL SAFETY
# ============================================

# Extract domain hints from issue title/body/labels
# Returns: backend, frontend, database, tests, docs, infra, security, billing, unknown
# Detection tiers (highest confidence first):
#   1. Explicit [Tag] in issue title
#   2. GitHub issue labels
#   3. File path patterns in title+body
#   4. Keyword matching (most specific domains first to avoid misclassification)
get_issue_domain() {
  local title="$1"
  local body="${2:-}"
  local labels="${3:-}"
  local combined
  combined=$(echo "$title $body" | tr '[:upper:]' '[:lower:]')
  local labels_lower
  labels_lower=$(echo "$labels" | tr '[:upper:]' '[:lower:]')

  # === TIER 1: Explicit tags in title (highest confidence) ===
  if echo "$title" | grep -qiE '^\[(backend|api|server)\]'; then
    echo "backend"; return
  elif echo "$title" | grep -qiE '^\[(frontend|ui|client|component|ux)\]'; then
    echo "frontend"; return
  elif echo "$title" | grep -qiE '^\[(database|db|schema|migration)\]'; then
    echo "database"; return
  elif echo "$title" | grep -qiE '^\[(test|testing|e2e|qa)\]'; then
    echo "tests"; return
  elif echo "$title" | grep -qiE '^\[(docs?|documentation)\]'; then
    echo "docs"; return
  elif echo "$title" | grep -qiE '^\[(infra|ci|deploy|docker|devops)\]'; then
    echo "infra"; return
  elif echo "$title" | grep -qiE '^\[(security|vuln|cve)\]'; then
    echo "security"; return
  elif echo "$title" | grep -qiE '^\[(billing|payments?|stripe)\]'; then
    echo "billing"; return
  fi

  # === TIER 2: GitHub issue labels ===
  if [[ -n "$labels_lower" ]]; then
    if echo "$labels_lower" | grep -qE '(backend|api|server)'; then
      echo "backend"; return
    elif echo "$labels_lower" | grep -qE '(frontend|ui|ux|component)'; then
      echo "frontend"; return
    elif echo "$labels_lower" | grep -qE '(database|db|schema|migration)'; then
      echo "database"; return
    elif echo "$labels_lower" | grep -qE '(test|testing|e2e|qa)'; then
      echo "tests"; return
    elif echo "$labels_lower" | grep -qE '(documentation|docs)'; then
      echo "docs"; return
    elif echo "$labels_lower" | grep -qE '(infra|ci|deploy|docker|devops)'; then
      echo "infra"; return
    elif echo "$labels_lower" | grep -qE '(security|vuln|cve)'; then
      echo "security"; return
    elif echo "$labels_lower" | grep -qE '(billing|payment|stripe)'; then
      echo "billing"; return
    fi
  fi

  # === TIER 3: File path patterns in title+body ===
  if echo "$combined" | grep -qE 'src/(api|server|backend|routers?|services?|middleware|lib/(api|auth|trpc))'; then
    echo "backend"; return
  elif echo "$combined" | grep -qE 'src/(components?|pages?|app/\(|ui/|hooks?/)'; then
    echo "frontend"; return
  elif echo "$combined" | grep -qE '(src/db/|drizzle/|\.schema\.ts|drizzle\.config)'; then
    echo "database"; return
  elif echo "$combined" | grep -qE '(tests?/|\.test\.|\.spec\.|__tests__|playwright)'; then
    echo "tests"; return
  elif echo "$combined" | grep -qE '(\.github/|docker|Dockerfile|Caddyfile)'; then
    echo "infra"; return
  fi

  # === TIER 4: Keyword matching (most specific domains checked first) ===

  # Security - highly specific terms, checked first to catch security fixes
  if echo "$combined" | grep -qE 'vulnerabilit|cve-[0-9]|xss|csrf|sql.injection|sanitiz(e|ation)|prototype.pollution|owasp|content.security.policy|hsts|security.header|security.fix|security.patch|security.audit|secret.leak|credential.leak|privilege.escalat|access.control|brute.force|password.hash'; then
    echo "security"; return
  fi

  # Billing - highly specific terms
  if echo "$combined" | grep -qE 'stripe|subscription|invoice|payment|billing|pricing.page|checkout|coupon|discount|refund|metered|usage.based|plan.limit|free.trial|paywall'; then
    echo "billing"; return
  fi

  # Database - specific to schema/data layer
  if echo "$combined" | grep -qE 'drizzle|neon.postgres|database.migration|schema.change|add.column|drop.column|create.table|alter.table|foreign.key|db.constraint|seed.data|db.connection|db.index'; then
    echo "database"; return
  fi

  # Docs - checked before infra/tests to avoid "deploy" in "deployment docs" matching infra
  if echo "$combined" | grep -qE 'readme|documentation|changelog|contributing|api.doc|swagger|openapi.spec|jsdoc|typedoc|storybook'; then
    echo "docs"; return
  fi

  # Tests - testing-specific terms
  if echo "$combined" | grep -qE 'playwright|jest|vitest|test.coverage|test.fixture|e2e.test|integration.test|unit.test|snapshot.test|regression.test|flaky.test|test.suite|test.helper|test.util'; then
    echo "tests"; return
  fi

  # Infra - CI/CD, deployment, build tooling
  if echo "$combined" | grep -qE 'docker|container|github.action|deploy|caddy|nginx|ssl.cert|dns|cloudflare|aws|lightsail|ci.cd|pipeline|health.check|monitoring|sentry|build.fail|bundle.size|turbopack|dockerfile|env.var|environment.variable|github.workflow|docker.compose'; then
    echo "infra"; return
  fi

  # Backend - broader terms (checked after more specific domains)
  if echo "$combined" | grep -qE 'trpc|router|endpoint|mutation|middleware|webhook|cron.job|auth|session|jwt|oauth|cors|rate.limit|cache|redis|queue|worker|email.send|notification|server.action|server.component|api.route|api.handler|request.handler|upload|download'; then
    echo "backend"; return
  fi

  # Frontend - broadest terms (checked last)
  if echo "$combined" | grep -qE 'component|usestate|useeffect|usecallback|usememo|useref|usecontext|jsx|tsx|react|button|modal|dialog|form.input|form.valid|data.table|chart|layout|sidebar|navbar|tooltip|dropdown|menu|panel|card|skeleton|loading|spinner|toast|alert|badge|icon|theme|dark.mode|responsive|css|tailwind|classname|shadcn|radix|dashboard|onboarding|wizard|stepper|animation|transition|popover|combobox|checkbox|radio|toggle|switch|accordion|breadcrumb|pagination|avatar|progress.bar|slider|tab.component|landing.page'; then
    echo "frontend"; return
  fi

  echo "unknown"
}

# Check if two domains can safely run in parallel
# Returns 0 if safe, 1 if not
are_domains_compatible() {
  local d1="$1" d2="$2"

  # Unknown domains can't be parallelized safely
  [[ "$d1" == "unknown" || "$d2" == "unknown" ]] && return 1

  # Same domain = likely to conflict
  [[ "$d1" == "$d2" ]] && return 1

  # Database changes should never run in parallel with anything
  [[ "$d1" == "database" || "$d2" == "database" ]] && return 1

  case "$d1:$d2" in
    backend:frontend|frontend:backend) return 0 ;;
    backend:docs|docs:backend) return 0 ;;
    frontend:docs|docs:frontend) return 0 ;;
    backend:tests|tests:backend) return 0 ;;
    frontend:tests|tests:frontend) return 0 ;;
    backend:infra|infra:backend) return 0 ;;
    frontend:infra|infra:frontend) return 0 ;;
    docs:tests|tests:docs) return 0 ;;
    docs:infra|infra:docs) return 0 ;;
    tests:infra|infra:tests) return 0 ;;
    security:docs|docs:security) return 0 ;;
    security:tests|tests:security) return 0 ;;
    security:infra|infra:security) return 0 ;;
    billing:frontend|frontend:billing) return 0 ;;
    billing:docs|docs:billing) return 0 ;;
    billing:tests|tests:billing) return 0 ;;
    billing:infra|infra:billing) return 0 ;;
    *) return 1 ;;
  esac
}

# Determine if two issues can safely run in parallel
# Returns 0 if safe, 1 if not safe
# Sets LAST_DOMAIN1 and LAST_DOMAIN2 for callers to reuse (avoids duplicate API calls)
can_issues_run_parallel() {
  local task1="$1"
  local task2="$2"

  [[ -z "$task1" || -z "$task2" ]] && return 1

  # Extract issue numbers and titles
  local num1="${task1%%:*}"
  local title1="${task1#*:}"
  local num2="${task2%%:*}"
  local title2="${task2#*:}"

  # Get issue bodies and labels for more context
  local body1="" body2="" labels1="" labels2=""
  if [[ "$PRD_SOURCE" == "github" ]]; then
    body1=$(get_github_issue_body "$task1" 2>/dev/null || echo "")
    body2=$(get_github_issue_body "$task2" 2>/dev/null || echo "")
    labels1=$(get_github_issue_labels "$task1" 2>/dev/null || echo "")
    labels2=$(get_github_issue_labels "$task2" 2>/dev/null || echo "")
  fi

  # Get domains (passing labels for better classification)
  local domain1 domain2
  domain1=$(get_issue_domain "$title1" "$body1" "$labels1")
  domain2=$(get_issue_domain "$title2" "$body2" "$labels2")

  # Cache for callers (e.g., run_auto_parallel_batch display)
  LAST_DOMAIN1="$domain1"
  LAST_DOMAIN2="$domain2"

  log_debug "Issue $num1 domain: $domain1"
  log_debug "Issue $num2 domain: $domain2"

  are_domains_compatible "$domain1" "$domain2"
}

# Get next unclaimed task (skips issues claimed by other instances)
get_next_unclaimed_task() {
  local all_tasks
  all_tasks=$(get_all_tasks)

  while IFS= read -r task; do
    [[ -z "$task" ]] && continue

    local issue_num="${task%%:*}"

    # Skip if claimed by another instance
    if is_issue_claimed "$issue_num"; then
      log_debug "Skipping issue $issue_num (claimed by another instance)"
      continue
    fi

    echo "$task"
    return 0
  done <<< "$all_tasks"

  echo ""
}

# Get a pair of tasks that can safely run in parallel
# Returns two tasks separated by newline, or single task if no safe pair found
get_parallel_safe_pair() {
  local all_tasks=()

  while IFS= read -r task; do
    [[ -z "$task" ]] && continue

    local issue_num="${task%%:*}"

    # Skip if claimed by another instance
    if is_issue_claimed "$issue_num"; then
      log_debug "Skipping issue $issue_num (claimed by another instance)"
      continue
    fi

    all_tasks+=("$task")
  done < <(get_all_tasks)

  local count=${#all_tasks[@]}
  [[ $count -eq 0 ]] && return 1

  # If only one task, return it
  if [[ $count -eq 1 ]]; then
    echo "${all_tasks[0]}"
    return 0
  fi

  # Try to find a safe batch of up to AUTO_PARALLEL_MAX tasks
  # Strategy: start with the first task, greedily add compatible tasks
  local first_task="${all_tasks[0]}"
  local batch=("$first_task")

  for ((i = 1; i < count && i < 10; i++)); do
    local candidate="${all_tasks[$i]}"

    # Check candidate is pairwise-safe with ALL tasks already in the batch
    local all_safe=true
    for existing in "${batch[@]}"; do
      if ! can_issues_run_parallel "$existing" "$candidate"; then
        all_safe=false
        break
      fi
    done

    if [[ "$all_safe" == true ]]; then
      batch+=("$candidate")
      # Stop if we've reached the max
      [[ ${#batch[@]} -ge $AUTO_PARALLEL_MAX ]] && break
    fi
  done

  # Output all tasks in the batch
  for task in "${batch[@]}"; do
    echo "$task"
  done
  return 0
}
