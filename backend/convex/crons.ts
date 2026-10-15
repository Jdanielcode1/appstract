import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

crons.interval("purge expired monitoring data", { hours: 1 }, internal.cleanup.purgeExpired, {});

crons.interval("check alert thresholds", { minutes: 1 }, internal.alerts.checkThresholds, {});

export default crons;
