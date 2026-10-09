// History replay cap. A chat's `history` frame used to carry EVERY stored row, tool results
// included — one long session reached 35 MB (9,680 rows) and the phone ran out of memory
// opening it ("VibeMobile keeps stopping"). The frame now carries the newest rows within a row
// and byte budget, with oversized tool results/inputs and message bodies truncated. Older rows
// stay in the DB (search, peers, transcript import read them there); `omitted` says how many
// were left out. Pure → unit-tested.

export const HISTORY_MAX_ROWS = 600;
export const HISTORY_MAX_BYTES = 1_500_000;
const MAX_FIELD = 4_000; // one tool input value / tool result
const MAX_CONTENT = 20_000; // one message body

type Row = { role: string; content?: string | null; tool_json?: string | null; [k: string]: unknown };

const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n)}… (truncated ${s.length - n} chars)` : s);

function shrinkToolJson(json: string): string | null {
  if (json.length <= MAX_FIELD) return json;
  try {
    const o = JSON.parse(json) as Record<string, unknown>;
    if (typeof o.result === "string") o.result = clip(o.result, MAX_FIELD);
    if (o.input && typeof o.input === "object") {
      for (const [k, v] of Object.entries(o.input as Record<string, unknown>)) {
        if (typeof v === "string") (o.input as Record<string, unknown>)[k] = clip(v, MAX_FIELD);
      }
    }
    return JSON.stringify(o);
  } catch {
    return null; // unparseable and big: drop it rather than ship it
  }
}

export function shrinkRow<T extends Row>(r: T): T {
  const out = { ...r };
  if (typeof out.content === "string") out.content = clip(out.content, MAX_CONTENT);
  if (out.role === "tool" && typeof out.tool_json === "string") out.tool_json = shrinkToolJson(out.tool_json);
  return out;
}

/** Newest rows that fit the budgets, oldest first, plus how many older rows were left out. */
export function capHistory<T extends Row>(rows: T[]): { rows: T[]; omitted: number } {
  const kept: T[] = [];
  let bytes = 0;
  for (let i = rows.length - 1; i >= 0 && kept.length < HISTORY_MAX_ROWS; i--) {
    const r = shrinkRow(rows[i]);
    const size = (r.content?.length ?? 0) + (typeof r.tool_json === "string" ? r.tool_json.length : 0) + 64;
    if (bytes + size > HISTORY_MAX_BYTES && kept.length > 0) break;
    bytes += size;
    kept.push(r);
  }
  kept.reverse();
  return { rows: kept, omitted: rows.length - kept.length };
}
