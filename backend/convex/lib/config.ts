/**
 * Limits you can tune with environment variables (`npx convex env set NAME value`). Changes take
 * effect on the next function call; no redeploy needed. Out-of-range values are clamped, and
 * anything that isn't a number falls back to the default.
 */

export const MINUTE_MS = 60_000;
export const HOUR_MS = 60 * MINUTE_MS;
export const DAY_MS = 24 * HOUR_MS;

function envNumber(name: string, fallback: number, min: number, max: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value)) return fallback;
  return Math.min(Math.max(value, min), max);
}

/**
 * Per monitored deployment, per UTC day. Past the quota, log lines / errors are no longer stored,
 * but they're still counted in function stats and still evaluated by alert rules.
 */
export function dailyQuotas() {
  return {
    logs: envNumber("MAX_LOG_LINES_PER_DAY", 100_000, 0, 5_000_000),
    errors: envNumber("MAX_ERRORS_PER_DAY", 20_000, 0, 1_000_000),
  };
}

/** How long each kind of data is kept (purged hourly by cleanup.ts). */
export function retention() {
  const statsDays = envNumber("STATS_RETENTION_DAYS", 30, 8, 90);
  return {
    logs: envNumber("LOG_RETENTION_HOURS", 24, 1, 7 * 24) * HOUR_MS,
    errors: envNumber("ERROR_RETENTION_DAYS", 7, 1, 30) * DAY_MS,
    // Minute rows only back the 1h view; two days covers it with room for clock skew.
    minuteStats: 2 * DAY_MS,
    // Hour/day stats, audit events, alert history, error signatures, AI history.
    stats: statsDays * DAY_MS,
  };
}

export const startOfUtcDay = (timestamp: number) => Math.floor(timestamp / DAY_MS) * DAY_MS;
