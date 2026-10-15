/** Pure helpers for alert evaluation. No Convex runtime imports so they can be unit tested. */

/** Max alerts one rule may fire for one webhook batch, so a burst can't flood the phone. */
export const MAX_ALERTS_PER_RULE_PER_BATCH = 3;

/**
 * First meaningful line of a Convex error, without the "[Request ID: …] Server Error" wrapper.
 * Mirrors `FunctionError.headline` in the iOS app.
 */
export function errorHeadline(message: string): string {
  const lines = message
    .split("\n")
    .map((line) => line.replace(/^\[Request ID: [^\]]+\] ?/, "").trim())
    .filter((line) => line.length > 0);
  return lines.find((line) => line !== "Server Error") ?? lines[0] ?? message;
}

/**
 * Groups errors that differ only by ids, numbers, or quoted values, so "new error" alerts fire
 * for genuinely new failures rather than every distinct document id.
 */
export function errorSignature(message: string): string {
  return errorHeadline(message)
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, "<uuid>")
    .replace(/\b[a-z0-9]{32}\b/g, "<id>")
    .replace(/"[^"]*"|'[^']*'/g, "<str>")
    .replace(/\b0x[0-9a-f]+\b/gi, "<hex>")
    .replace(/\d+(\.\d+)?/g, "<n>")
    .slice(0, 300);
}

export interface LogMatchConditions {
  level?: string;
  pattern?: string;
  path?: string;
}

export interface LogLike {
  level: string;
  path: string;
  message: string;
}

/** Every provided condition must match. Text conditions are case-insensitive substrings. */
export function logMatches(rule: LogMatchConditions, log: LogLike): boolean {
  if (rule.level && rule.level.toUpperCase() !== log.level.toUpperCase()) return false;
  if (rule.path && !log.path.toLowerCase().includes(rule.path.toLowerCase())) return false;
  if (rule.pattern && !log.message.toLowerCase().includes(rule.pattern.toLowerCase())) return false;
  return true;
}

/** Applies to this deployment? Rules without a deployment apply to all of them. */
export function ruleAppliesTo(rule: { deploymentName?: string }, deploymentName: string): boolean {
  return rule.deploymentName === undefined || rule.deploymentName === deploymentName;
}

export function truncate(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

/** "my-app (prod)", falling back to the deployment name. */
export function deploymentLabel(deployment: { name: string; projectName?: string; deploymentType?: string } | null, name: string) {
  if (!deployment?.projectName) return name;
  return deployment.deploymentType ? `${deployment.projectName} (${deployment.deploymentType})` : deployment.projectName;
}
