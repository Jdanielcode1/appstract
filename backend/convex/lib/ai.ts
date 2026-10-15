import { ConvexError } from "convex/values";

/** How the app should present a query's result (chosen by the model, validated by the app). */
export type AnswerDisplay = {
  /** number: one value · ranking: label + numeric value per row, sorted · list: records · text: a sentence */
  type: "number" | "ranking" | "list" | "text";
  /** Short title for the answer, e.g. "Users with the most orders". */
  title?: string;
  /** Row field to show as the name (ranking/list), e.g. "username". */
  label?: string;
  /** Row field holding the number (ranking), e.g. "orderCount". */
  value?: string;
  /** Unit after the number, e.g. "sessions". */
  unit?: string;
};

export type Answer = { query: string; explanation: string; display?: AnswerDisplay };

const DISPLAY_TYPES = new Set(["number", "ranking", "list", "text"]);

function parseDisplay(raw: unknown): AnswerDisplay | undefined {
  if (typeof raw !== "object" || raw === null) return undefined;
  const value = raw as Record<string, unknown>;
  if (typeof value.type !== "string" || !DISPLAY_TYPES.has(value.type)) return undefined;
  const text = (key: string) => (typeof value[key] === "string" && value[key] ? (value[key] as string).slice(0, 120) : undefined);
  const display: AnswerDisplay = { type: value.type as AnswerDisplay["type"] };
  for (const key of ["title", "label", "value", "unit"] as const) {
    const field = text(key);
    if (field) display[key] = field;
  }
  return display;
}

/** Accepts the requested JSON, JSON inside a code fence, or a bare code block as a fallback. */
export function parseAnswer(text: string): Answer {
  const unfenced = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  const start = unfenced.indexOf("{");
  const end = unfenced.lastIndexOf("}");
  if (start !== -1 && end > start) {
    try {
      const parsed = JSON.parse(unfenced.slice(start, end + 1)) as { query?: unknown; explanation?: unknown; display?: unknown };
      if (typeof parsed.query === "string" && parsed.query.trim()) {
        const display = parseDisplay(parsed.display);
        return {
          query: parsed.query.trim(),
          explanation: typeof parsed.explanation === "string" ? parsed.explanation.trim() : "",
          ...(display ? { display } : {}),
        };
      }
    } catch {
      // fall through to code-block extraction
    }
  }
  const code = /```(?:javascript|typescript|js|ts)?[ \t]*\n([\s\S]*?)```/i.exec(text)?.[1]?.trim();
  if (code?.startsWith("{")) throw new ConvexError("Couldn't read a query from the model's answer. Try rephrasing.");
  if (code) return { query: code, explanation: "" };
  throw new ConvexError("Couldn't read a query from the model's answer. Try rephrasing.");
}
