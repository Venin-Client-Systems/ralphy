/**
 * Domain Classification (ported from autoissue/lib/domain.sh)
 *
 * Classifies GitHub issues by domain for parallel scheduling:
 * - Tier 1: Title tags ([Backend], [Frontend], etc.)
 * - Tier 2: GitHub labels
 * - Tier 3: File path patterns in body
 * - Tier 4: Keyword matching
 */

import type { Domain, ClassificationResult, GitHubIssue } from './types.js';

/**
 * Map of known domains (for validation).
 */
const VALID_DOMAINS = new Set<Domain>([
  'backend',
  'frontend',
  'database',
  'infrastructure',
  'security',
  'testing',
  'documentation',
  'unknown',
]);

/**
 * Classify a GitHub issue by its domain.
 *
 * Uses a 4-tier detection system with decreasing confidence:
 * 1. Explicit tags in title (100% confidence)
 * 2. GitHub labels (90% confidence)
 * 3. File path patterns (70% confidence)
 * 4. Keyword matching (50% confidence)
 */
export function classifyIssue(issue: GitHubIssue): ClassificationResult {
  const title = issue.title;
  const body = issue.body || '';
  const labels = issue.labels || [];
  const combined = `${title} ${body}`.toLowerCase();
  const labelsLower = labels.map((l) => l.toLowerCase());

  // TIER 1: Explicit tags in title (highest confidence)
  const titleTag = extractTitleTag(title);
  if (titleTag) {
    return {
      domain: titleTag,
      confidence: 1.0,
      reasons: [`Title tag: [${title.match(/^\[([^\]]+)\]/)?.[1]}]`],
    };
  }

  // TIER 2: GitHub labels
  const labelDomain = classifyByLabels(labelsLower);
  if (labelDomain !== 'unknown') {
    return {
      domain: labelDomain,
      confidence: 0.9,
      reasons: [`Label: ${labels.join(', ')}`],
    };
  }

  // TIER 3: File path patterns
  const pathDomain = classifyByFilePaths(combined);
  if (pathDomain !== 'unknown') {
    return {
      domain: pathDomain,
      confidence: 0.7,
      reasons: ['File path patterns in body'],
    };
  }

  // TIER 4: Keyword matching
  const keywordDomain = classifyByKeywords(combined);
  if (keywordDomain !== 'unknown') {
    return {
      domain: keywordDomain,
      confidence: 0.5,
      reasons: ['Keyword matching'],
    };
  }

  // Fallback
  return {
    domain: 'unknown',
    confidence: 0.0,
    reasons: ['No domain indicators found'],
  };
}

/**
 * Extract domain from title tag like [Backend], [Frontend], etc.
 */
function extractTitleTag(title: string): Domain | null {
  const match = title.match(/^\[([^\]]+)\]/i);
  if (!match) return null;

  const tag = match[1].toLowerCase();

  if (/^(backend|api|server)$/i.test(tag)) return 'backend';
  if (/^(frontend|ui|client|component|ux)$/i.test(tag)) return 'frontend';
  if (/^(database|db|schema|migration)$/i.test(tag)) return 'database';
  if (/^(test|testing|e2e|qa)$/i.test(tag)) return 'testing';
  if (/^(docs?|documentation)$/i.test(tag)) return 'documentation';
  if (/^(infra|ci|deploy|docker|devops)$/i.test(tag)) return 'infrastructure';
  if (/^(security|vuln|cve)$/i.test(tag)) return 'security';

  return null;
}

/**
 * Classify by GitHub issue labels.
 */
function classifyByLabels(labels: string[]): Domain {
  for (const label of labels) {
    if (/backend|api|server/.test(label)) return 'backend';
    if (/frontend|ui|ux|component/.test(label)) return 'frontend';
    if (/database|db|schema|migration/.test(label)) return 'database';
    if (/test|testing|e2e|qa/.test(label)) return 'testing';
    if (/documentation|docs/.test(label)) return 'documentation';
    if (/infra|ci|deploy|docker|devops/.test(label)) return 'infrastructure';
    if (/security|vuln|cve/.test(label)) return 'security';
  }
  return 'unknown';
}

/**
 * Classify by file path patterns in title+body.
 */
function classifyByFilePaths(text: string): Domain {
  if (/src\/(api|server|backend|routers?|services?|middleware|lib\/(api|auth|trpc))/.test(text)) {
    return 'backend';
  }
  if (/src\/(components?|pages?|app\/\(|ui\/|hooks?\/)/.test(text)) {
    return 'frontend';
  }
  if (/(src\/db\/|drizzle\/|\.schema\.ts|drizzle\.config)/.test(text)) {
    return 'database';
  }
  if (/(tests?\/|\.test\.|\.spec\.|__tests__|playwright)/.test(text)) {
    return 'testing';
  }
  if (/(\.github\/|docker|Dockerfile|Caddyfile)/.test(text)) {
    return 'infrastructure';
  }
  return 'unknown';
}

/**
 * Classify by keyword matching (least reliable, checked in specificity order).
 */
function classifyByKeywords(text: string): Domain {
  // Security - highly specific, checked first
  if (/vulnerabilit|cve-[0-9]|xss|csrf|sql.injection|sanitiz(e|ation)|prototype.pollution|owasp|content.security.policy|hsts|security.header|security.fix|security.patch|security.audit|secret.leak|credential.leak|privilege.escalat|access.control|brute.force|password.hash/.test(text)) {
    return 'security';
  }

  // Database - specific to schema/data layer
  if (/drizzle|neon.postgres|database.migration|schema.change|add.column|drop.column|create.table|alter.table|foreign.key|db.constraint|seed.data|db.connection|db.index/.test(text)) {
    return 'database';
  }

  // Documentation - checked before infra/tests to avoid "deploy" in "deployment docs"
  if (/readme|documentation|changelog|contributing|api.doc|swagger|openapi.spec|jsdoc|typedoc|storybook/.test(text)) {
    return 'documentation';
  }

  // Testing - testing-specific terms
  if (/playwright|jest|vitest|test.coverage|test.fixture|e2e.test|integration.test|unit.test|snapshot.test|regression.test|flaky.test|test.suite|test.helper|test.util/.test(text)) {
    return 'testing';
  }

  // Infrastructure - CI/CD, deployment, build tooling
  if (/docker|container|github.action|deploy|caddy|nginx|ssl.cert|dns|cloudflare|aws|lightsail|ci.cd|pipeline|health.check|monitoring|sentry|build.fail|bundle.size|turbopack|dockerfile|env.var|environment.variable|github.workflow|docker.compose/.test(text)) {
    return 'infrastructure';
  }

  // Backend - broader terms
  if (/trpc|router|endpoint|mutation|middleware|webhook|cron.job|auth|session|jwt|oauth|cors|rate.limit|cache|redis|queue|worker|email.send|notification|server.action|server.component|api.route|api.handler|request.handler|upload|download/.test(text)) {
    return 'backend';
  }

  // Frontend - broadest terms (checked last)
  if (/component|usestate|useeffect|usecallback|usememo|useref|usecontext|jsx|tsx|react|button|modal|dialog|form.input|form.valid|data.table|chart|layout|sidebar|navbar|tooltip|dropdown|menu|panel|card|skeleton|loading|spinner|toast|alert|badge|icon|theme|dark.mode|responsive|css|tailwind|classname|shadcn|radix|dashboard|onboarding|wizard|stepper|animation|transition|popover|combobox|checkbox|radio|toggle|switch|accordion|breadcrumb|pagination|avatar|progress.bar|slider|tab.component|landing.page/.test(text)) {
    return 'frontend';
  }

  return 'unknown';
}

/**
 * Check if two domains can safely run in parallel.
 *
 * Blocked combinations:
 * - Unknown domains (unclassifiable)
 * - Same domain (file conflicts)
 * - Database (schema affects all domains)
 *
 * All other cross-domain pairs are safe.
 */
export function areDomainsCompatible(d1: Domain, d2: Domain): boolean {
  // Unknown domains can't be parallelized safely
  if (d1 === 'unknown' || d2 === 'unknown') return false;

  // Same domain = likely to conflict
  if (d1 === d2) return false;

  // Database changes should never run in parallel with anything
  if (d1 === 'database' || d2 === 'database') return false;

  // All other cross-domain pairs are safe
  return true;
}

/**
 * Validate that a string is a known domain.
 */
export function isValidDomain(domain: string): domain is Domain {
  return VALID_DOMAINS.has(domain as Domain);
}
