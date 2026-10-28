import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";
import { POLL_INTERVAL_MINUTES } from "./lib/lite";

const crons = cronJobs();

crons.interval("purge expired monitoring data", { hours: 1 }, internal.cleanup.purgeExpired, {});

// Lite polls (lite.ts) and error-rate / scheduler alerts. Every 5 minutes, not every minute: this
// runs on every copy of the backend (dev too), used or not.
crons.interval("monitor", { minutes: POLL_INTERVAL_MINUTES }, internal.lite.tick, {});

export default crons;
