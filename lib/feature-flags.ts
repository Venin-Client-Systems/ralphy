/**
 * Feature flags for Autoissue 2.0.
 *
 * These flags allow gradual rollout of new features and safe A/B testing.
 */

/**
 * Feature flags configuration.
 */
export const FeatureFlags = {
  /**
   * Enable error boundary observability (metrics collection).
   * When true, collects retry metrics for dashboard/TUI display.
   *
   * Default: true
   * Set AUTOISSUE_DISABLE_METRICS=true to disable.
   */
  ENABLE_METRICS: process.env.AUTOISSUE_DISABLE_METRICS !== 'true',
} as const;

/**
 * Get all active feature flags.
 */
export function getActiveFlags(): Record<string, boolean> {
  return { ...FeatureFlags };
}

/**
 * Log current feature flag configuration.
 */
export function logFeatureFlags(): void {
  const flags = getActiveFlags();
  const activeFlags = Object.entries(flags)
    .filter(([_, enabled]) => enabled)
    .map(([name]) => name);

  if (activeFlags.length > 0) {
    console.log('🚩 Active feature flags:', activeFlags.join(', '));
  }
}
