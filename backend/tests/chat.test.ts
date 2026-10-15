import { describe, expect, it } from "vitest";
import { composeCatalog, parseCatalogAnswer, profileText } from "../convex/lib/catalog";
import { queriesThisTurn, toModelMessages, toTurns, unresolvedToolUses, type StoredMessage } from "../convex/lib/chat";

const question: StoredMessage = { role: "user", content: [{ type: "text", text: "users with most sessions" }] };
const runStep: StoredMessage = {
  role: "assistant",
  content: [{ type: "tool_use", id: "q1", name: "run_query", input: { code: "1", purpose: "count" } }],
};
const result: StoredMessage = { role: "user", content: [{ type: "tool_result", tool_use_id: "q1", content: "[]" }] };
const answerStep: StoredMessage = {
  role: "assistant",
  content: [{ type: "tool_use", id: "a1", name: "answer", input: { text: "daniel1 leads.", result_of: "q1", followups: ["only premium?"] } }],
};

describe("chat history", () => {
  it("finds tool calls that still need a result", () => {
    expect(unresolvedToolUses([question, runStep]).map((u) => u.id)).toEqual(["q1"]);
    expect(unresolvedToolUses([question, runStep, result])).toEqual([]);
    expect(unresolvedToolUses([question, runStep, result, answerStep]).map((u) => u.id)).toEqual(["a1"]);
  });

  it("counts queries since the last question", () => {
    expect(queriesThisTurn([question, runStep, result, runStep])).toBe(2);
    expect(queriesThisTurn([question, runStep, result, answerStep, question])).toBe(0);
  });

  it("merges consecutive same-role messages", () => {
    const merged = toModelMessages([question, { role: "user", content: [{ type: "text", text: "more" }] }]);
    expect(merged).toHaveLength(1);
    expect(merged[0].content).toHaveLength(2);
  });

  it("builds turns with queries and the answer", () => {
    const [turn] = toTurns([question, runStep, result, answerStep]);
    expect(turn.question).toBe("users with most sessions");
    expect(turn.queries).toEqual([{ id: "q1", code: "1", purpose: "count" }]);
    expect(turn.answer).toMatchObject({ text: "daniel1 leads.", resultOf: "q1", followups: ["only premium?"] });
  });
});

describe("catalog", () => {
  const profile = {
    tables: [
      {
        name: "users",
        rows: 23,
        sampled: 23,
        fields: [
          { name: "email", type: "string", fill: 1, format: "email" },
          { name: "lastOrderAt", type: "number", fill: 0.3, format: "date" },
          { name: "plan", type: "string", fill: 1, values: ["free", "pro"] },
        ],
      },
    ],
    functions: { users: ["getMe (query)"] },
  };

  it("describes the profile compactly", () => {
    const text = profileText(profile);
    expect(text).toContain("users (23 rows, sampled 23)");
    expect(text).toContain("lastOrderAt: number, 30% set, date");
    expect(text).toContain("values: free | pro");
    expect(text).toContain("users: getMe (query)");
  });

  it("keeps only meaningful fields in the catalog", () => {
    const descriptions = parseCatalogAnswer(
      '```json\n{"tables": {"users": {"about": "One row per account.", "fields": {"lastOrderAt": "Last order placed, not app opens."}}}, "notes": ["No app-open field."]}\n```',
    );
    const text = composeCatalog(profile, descriptions, Date.UTC(2026, 9, 6));
    expect(text).toContain("- users (23 rows): One row per account.");
    expect(text).toContain("· lastOrderAt (date, 30% set): Last order placed, not app opens.");
    expect(text).toContain("· plan: values: free | pro");
    expect(text).not.toContain("· email");
    expect(text).toContain("- No app-open field.");
  });
});
