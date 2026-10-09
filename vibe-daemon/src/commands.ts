// Slash commands / skills offered in the app's composer (proposal 41).
//
// The SDK lists everything `/name` can run. Two kinds are offered:
//   - anything that is not Claude Code's own (the user's skills, project/plugin/MCP commands);
//   - Claude Code's own *skills* (/simplify, /code-review, /loop, /init, …) — these are
//     flagged `builtin` too, but they are prompts, not terminal controls. They are identified
//     by appearing in the context response's skills list (M13 spike: a clean split, 13 of the
//     55 flagged rows).
// The remaining built-ins (/config, /clear, /heapdump, /color, …) assume a terminal and some
// change settings, so they are not offered. Sending any of these is just a user message
// starting with "/", so it grants nothing a paired device couldn't already send as a prompt.

export type CommandInfo = { name: string; description: string; hint: string };

const NAME = /^[A-Za-z0-9][A-Za-z0-9:_.-]{0,99}$/;
const MAX_COMMANDS = 200;

const clip = (s: unknown, n: number): string => (typeof s === "string" ? s.replace(/\s+/g, " ").trim().slice(0, n) : "");

/** Names of the skills in a getContextUsage() response (`skills.skillFrontmatter[].name`). */
export function skillNamesFrom(ctx: unknown): Set<string> {
  const fm = (ctx as { skills?: { skillFrontmatter?: unknown } } | null | undefined)?.skills?.skillFrontmatter;
  return new Set(
    (Array.isArray(fm) ? fm : []).map((s) => (s as { name?: unknown } | null)?.name).filter((n): n is string => typeof n === "string"),
  );
}

export function publicCommands(raw: unknown, skillNames: ReadonlySet<string> = new Set()): CommandInfo[] {
  if (!Array.isArray(raw)) return [];
  const rows = raw.filter((c): c is Record<string, unknown> => typeof c === "object" && c !== null);
  // A built-in that is a skill is fine to offer; any other built-in is not.
  const offerable = (c: Record<string, unknown>) => c.builtin !== true || (typeof c.name === "string" && skillNames.has(c.name));
  // "/name" runs the built-in when one shares the name, so a non-built-in row with a
  // withheld built-in's name would be mislabelled by the picker — drop it too.
  const withheld = new Set(rows.filter((c) => c.builtin === true && !offerable(c) && typeof c.name === "string").map((c) => c.name as string));
  const seen = new Set<string>();
  const out: CommandInfo[] = [];
  for (const c of rows) {
    const name = c.name;
    if (!offerable(c) || typeof name !== "string" || !NAME.test(name) || withheld.has(name) || seen.has(name)) continue;
    seen.add(name);
    out.push({ name, description: clip(c.description, 160), hint: clip(c.argumentHint, 80) });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name)).slice(0, MAX_COMMANDS);
}
