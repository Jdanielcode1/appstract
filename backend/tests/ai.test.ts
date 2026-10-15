import { describe, expect, it } from "vitest";
import { parseAnswer } from "../convex/lib/ai";

describe("parseAnswer", () => {
  it("reads the requested JSON", () => {
    expect(parseAnswer('{"explanation": "Counts users.", "query": "(await ctx.db.query(\\"users\\").take(10000)).length"}')).toEqual({
      explanation: "Counts users.",
      query: '(await ctx.db.query("users").take(10000)).length',
    });
  });

  it("reads JSON inside a code fence", () => {
    expect(parseAnswer('```json\n{"explanation": "x", "query": "await ctx.db.query(\\"a\\").first()"}\n```').query).toBe(
      'await ctx.db.query("a").first()',
    );
  });

  it("falls back to a bare code block", () => {
    expect(parseAnswer("Here you go:\n```js\nawait ctx.db.query(\"a\").take(5)\n```")).toEqual({
      query: 'await ctx.db.query("a").take(5)',
      explanation: "",
    });
  });

  it("doesn't mistake a json fence for a js code block", () => {
    expect(() => parseAnswer('```json\n{"explanation": "x", "query": broken}\n```')).toThrow();
  });

  it("rejects answers without a query", () => {
    expect(() => parseAnswer("I can't help with that.")).toThrow();
  });
});

describe("parseAnswer display", () => {
  it("keeps a valid display hint", () => {
    const answer = parseAnswer(
      '{"explanation": "x", "query": "1", "display": {"type": "ranking", "title": "Top", "label": "name", "value": "count", "unit": "orders", "extra": 1}}',
    );
    expect(answer.display).toEqual({ type: "ranking", title: "Top", label: "name", value: "count", unit: "orders" });
  });

  it("drops an unknown display type", () => {
    expect(parseAnswer('{"explanation": "x", "query": "1", "display": {"type": "pie"}}').display).toBeUndefined();
  });
});
