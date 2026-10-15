import { describe, expect, it } from "vitest";
import { errorHeadline, errorSignature, logMatches, ruleAppliesTo, deploymentLabel } from "../convex/lib/alerts";

describe("errorHeadline", () => {
  it("skips the Server Error wrapper", () => {
    expect(errorHeadline("[Request ID: abc] Server Error\nUncaught Error: boom\n  at x")).toBe("Uncaught Error: boom");
    expect(errorHeadline("Uncaught Error: plain")).toBe("Uncaught Error: plain");
  });
});

describe("errorSignature", () => {
  it("groups errors that differ only by ids, numbers, and quoted values", () => {
    const a = errorSignature('Uncaught Error: Document jd7f1k2m3n4p5q6r7s8t9u0v1w2x3y4z not found for user "dan"');
    const b = errorSignature('Uncaught Error: Document ab7f1k2m3n4p5q6r7s8t9u0v1w2x3y4z not found for user "eve"');
    expect(a).toBe(b);
    expect(errorSignature("Timeout after 300ms")).toBe(errorSignature("Timeout after 1500ms"));
  });

  it("keeps genuinely different errors apart", () => {
    expect(errorSignature("Uncaught Error: card declined")).not.toBe(errorSignature("Uncaught Error: invalid token"));
  });
});

describe("logMatches", () => {
  const log = { level: "ERROR", path: "feedback:checkStaleReports", message: "[moderation-sla] 2 unresolved report(s)" };

  it("requires every provided condition", () => {
    expect(logMatches({ level: "error" }, log)).toBe(true);
    expect(logMatches({ level: "WARN" }, log)).toBe(false);
    expect(logMatches({ pattern: "MODERATION-SLA" }, log)).toBe(true);
    expect(logMatches({ pattern: "moderation", path: "feedback:" }, log)).toBe(true);
    expect(logMatches({ pattern: "moderation", path: "users:" }, log)).toBe(false);
    expect(logMatches({}, log)).toBe(true);
  });
});

describe("rule scope and labels", () => {
  it("applies rules without a deployment everywhere", () => {
    expect(ruleAppliesTo({}, "x")).toBe(true);
    expect(ruleAppliesTo({ deploymentName: "x" }, "x")).toBe(true);
    expect(ruleAppliesTo({ deploymentName: "y" }, "x")).toBe(false);
  });

  it("labels deployments by project and type", () => {
    expect(deploymentLabel({ name: "tidy-1", projectName: "my-app", deploymentType: "dev" }, "tidy-1")).toBe("my-app (dev)");
    expect(deploymentLabel(null, "tidy-1")).toBe("tidy-1");
  });
});
