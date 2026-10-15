import { ConvexError } from "convex/values";

/** What the app measures about a deployment's data (read-only profiling on the phone). */
export type FieldProfile = {
  name: string;
  /** "string", "number", "boolean", "array", "object", "null", or "a|b" when mixed. */
  type: string;
  /** Share of sampled documents where the field is set (0–1). */
  fill: number;
  /** "date" (ms timestamp), "email", "url", "tokenIdentifier", "id:<table>". */
  format?: string;
  /** Most common values of a low-variety string field (only when the user allows sharing values). */
  values?: string[];
};

export type TableProfile = { name: string; rows?: number; sampled: number; fields: FieldProfile[] };

export type DataProfile = {
  tables: TableProfile[];
  /** Function names by file, e.g. {"orders": ["place (mutation)", "list (query)"]}. */
  functions?: Record<string, string[]>;
  hints?: string;
};

export type CatalogDescriptions = {
  tables: Record<string, { about?: string; fields?: Record<string, string> }>;
  notes: string[];
};

const percent = (fill: number) => `${Math.round(fill * 100)}%`;

/** Compact text of the profile for the model. */
export function profileText(profile: DataProfile): string {
  const lines: string[] = ["Tables:"];
  for (const table of profile.tables) {
    const rows = table.rows !== undefined ? `${table.rows} rows` : "rows unknown";
    lines.push(`${table.name} (${rows}, sampled ${table.sampled})`);
    for (const field of table.fields) {
      const parts = [field.type, `${percent(field.fill)} set`];
      if (field.format) parts.push(field.format);
      if (field.values?.length) parts.push(`values: ${field.values.join(" | ")}`);
      lines.push(`  ${field.name}: ${parts.join(", ")}`);
    }
  }
  if (profile.functions && Object.keys(profile.functions).length > 0) {
    lines.push("", "Functions by file:");
    for (const [file, names] of Object.entries(profile.functions)) lines.push(`  ${file}: ${names.join(", ")}`);
  }
  if (profile.hints) lines.push("", profile.hints);
  return lines.join("\n");
}

/** Reads the model's JSON (also inside a code fence). */
export function parseCatalogAnswer(text: string): CatalogDescriptions {
  const unfenced = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  const start = unfenced.indexOf("{");
  const end = unfenced.lastIndexOf("}");
  if (start === -1 || end <= start) throw new ConvexError("Couldn't read the catalog from the model's answer.");
  let parsed: { tables?: unknown; notes?: unknown };
  try {
    parsed = JSON.parse(unfenced.slice(start, end + 1));
  } catch {
    throw new ConvexError("Couldn't read the catalog from the model's answer.");
  }
  const tables: CatalogDescriptions["tables"] = {};
  if (typeof parsed.tables === "object" && parsed.tables !== null) {
    for (const [name, raw] of Object.entries(parsed.tables as Record<string, unknown>)) {
      if (typeof raw !== "object" || raw === null) continue;
      const entry = raw as { about?: unknown; fields?: unknown };
      const fields: Record<string, string> = {};
      if (typeof entry.fields === "object" && entry.fields !== null) {
        for (const [field, meaning] of Object.entries(entry.fields as Record<string, unknown>)) {
          if (typeof meaning === "string" && meaning.trim()) fields[field] = meaning.trim();
        }
      }
      tables[name] = { about: typeof entry.about === "string" ? entry.about.trim() : undefined, fields };
    }
  }
  const notes = Array.isArray(parsed.notes)
    ? parsed.notes.filter((note): note is string => typeof note === "string" && note.trim().length > 0).slice(0, 8)
    : [];
  return { tables, notes };
}

/**
 * The prompt-ready catalog: one line per table, then fields that have a meaning or known values.
 * Types and indexes come from the schema the app sends separately.
 */
export function composeCatalog(profile: DataProfile, descriptions: CatalogDescriptions, builtAt: number): string {
  const lines = [`Data catalog (built ${new Date(builtAt).toISOString().slice(0, 10)} from each table's newest documents):`];
  for (const table of [...profile.tables].sort((a, b) => a.name.localeCompare(b.name))) {
    const described = descriptions.tables[table.name];
    const rows = table.rows !== undefined ? `${table.rows} rows` : "rows unknown";
    lines.push(`- ${table.name} (${rows})${described?.about ? `: ${described.about}` : ""}`);
    for (const field of table.fields) {
      const meaning = described?.fields?.[field.name];
      if (!meaning && !field.values?.length) continue;
      const facts = [field.format, field.fill < 1 ? `${percent(field.fill)} set` : undefined].filter(Boolean).join(", ");
      const values = field.values?.length ? `${meaning ? "; " : ""}values: ${field.values.join(" | ")}` : "";
      lines.push(`  · ${field.name}${facts ? ` (${facts})` : ""}: ${meaning ?? ""}${values}`);
    }
  }
  if (descriptions.notes.length > 0) {
    lines.push("Notes:");
    for (const note of descriptions.notes) lines.push(`- ${note}`);
  }
  return lines.join("\n");
}
