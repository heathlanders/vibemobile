// Context-window meter (proposal 40): turns the SDK's getContextUsage() response into
// the small `context` frame the app draws. Pure so it can be tested without a session.
//
// Real response keys are camelCase (totalTokens, maxTokens, autoCompactThreshold, …) —
// the SDK's .d.ts for the *message* variant uses snake_case; the control response does not
// (M12 spike). Everything is read defensively: a field that goes missing yields a
// smaller frame, never an exception.

export type ContextCategory = { name: string; tokens: number };
// An instruction file the session loaded (CLAUDE.md, auto-memory, …) — so the app can show
// which instructions are really in force.
export type MemoryFile = { path: string; type: string; tokens: number };
export type ContextFrame = {
  tokens: number; // used right now
  max: number; // the window it is measured against
  percent: number; // 0-100+
  autoCompactAt: number | null; // tokens at which the SDK compacts by itself, if it does
  categories: ContextCategory[]; // only what occupies the window, largest first
  memoryFiles: MemoryFile[]; // instruction files loaded into this session
  model: string | null;
};

const num = (x: unknown): number | null => (typeof x === "number" && Number.isFinite(x) ? x : null);

export function summarizeContext(raw: unknown): ContextFrame | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  const tokens = num(r.totalTokens);
  const max = num(r.maxTokens) ?? num(r.rawMaxTokens);
  if (tokens === null || max === null || max <= 0) return null;
  const categories: ContextCategory[] = [];
  for (const c of Array.isArray(r.categories) ? r.categories : []) {
    const cat = c as Record<string, unknown>;
    // Classify on `kind`, never the English name (SDK doc): only 'used' occupies the window.
    if (cat?.kind === "used" && typeof cat.name === "string" && (num(cat.tokens) ?? 0) > 0) {
      categories.push({ name: cat.name, tokens: num(cat.tokens)! });
    }
  }
  categories.sort((a, b) => b.tokens - a.tokens);
  const memoryFiles: MemoryFile[] = [];
  for (const m of Array.isArray(r.memoryFiles) ? r.memoryFiles.slice(0, 20) : []) {
    const f = m as Record<string, unknown>;
    if (typeof f?.path === "string" && f.path) {
      memoryFiles.push({ path: f.path.slice(0, 400), type: typeof f.type === "string" ? f.type.slice(0, 40) : "", tokens: num(f.tokens) ?? 0 });
    }
  }
  return {
    tokens,
    max,
    percent: num(r.percentage) ?? Math.round((tokens / max) * 100),
    autoCompactAt: r.isAutoCompactEnabled === false ? null : num(r.autoCompactThreshold),
    categories,
    memoryFiles,
    model: typeof r.model === "string" ? r.model : null,
  };
}

/** "Context compacted (manual): 24,261 → 2,806 tokens" — the persisted notice text. */
export function compactNotice(meta: unknown): string {
  const m = (typeof meta === "object" && meta !== null ? meta : {}) as Record<string, unknown>;
  const pre = num(m.pre_tokens);
  const post = num(m.post_tokens);
  const fmt = (n: number) => n.toLocaleString("en-US");
  const how = m.trigger === "auto" ? "auto" : "manual";
  return pre !== null && post !== null
    ? `Context compacted (${how}): ${fmt(pre)} → ${fmt(post)} tokens`
    : `Context compacted (${how})`;
}
