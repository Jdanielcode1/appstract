import { ConvexError } from "convex/values";

/**
 * Each user self-hosts this backend, so a single owner secret (APP_KEY env var) is enough.
 * Every public function must call this first.
 */
export function assertAppKey(appKey: string) {
  const expected = process.env.APP_KEY;
  if (!expected || appKey !== expected) {
    throw new ConvexError("Unauthorized");
  }
}
