// Unified-diff rendering for file-writing tool calls. Shared by two callers:
//
//   1. the session file viewer (file-edits.ts) — diffs of edits ALREADY made;
//   2. the permission gate (permission-gate.ts) — a preview of the edit about
//      to be made, attached to `permission_request` (proposal 02).
//
// Invariant for (2): the preview is built from the SAME `input` object the gate
// resolves as `updatedInput`. Render must equal execution — a card that renders
// a diff reconstructed from anything else could show one thing and run another.
//
// No silent truncation anywhere: every cut appends a visible marker line and
// sets `truncated: true`.

import { relative, resolve } from "node:path";
import { structuredPatch } from "diff";

const MAX_DIFF_LINES = 400;
const MAX_DIFF_BYTES = 32 * 1024;

// One file-writing op, flattened to an old→new string pair.
export type EditOp = {
  ts: string;
  tool: string; // Edit | Write (MultiEdit entries flatten to Edit)
  replaceAll: boolean;
  written: boolean; // Write: prior content unknown → renders as all-additions
  oldStr: string;
  newStr: string;
};

export type DiffPreview = {
  relPath: string;
  diff: string;
  adds: number;
  dels: number;
  truncated: boolean;
};

// Unified-diff text for one op (prefixed lines, hunks joined by @@ headers),
// capped with an explicit in-band marker — never a silent cut.
export function buildEditDiff(op: EditOp): { diff: string; adds: number; dels: number; truncated: boolean } {
  let lines: string[];
  if (op.written) {
    // Write: prior content unknown; render the new content as all-additions.
    // A trailing newline would otherwise show as a spurious empty "+" line.
    const src = op.newStr.endsWith("\n") ? op.newStr.slice(0, -1) : op.newStr;
    lines = src.split("\n").map((l) => "+" + l);
  } else {
    const patch = structuredPatch("a", "b", op.oldStr, op.newStr, "", "", { context: 3 });
    lines = patch.hunks.flatMap((h) => [`@@ -${h.oldStart},${h.oldLines} +${h.newStart},${h.newLines} @@`, ...h.lines]);
  }
  let adds = 0;
  let dels = 0;
  for (const l of lines) {
    if (l.startsWith("+")) adds++;
    else if (l.startsWith("-")) dels++;
  }
  let truncated = false;
  let kept = 0;
  let bytes = 0;
  for (; kept < lines.length && kept < MAX_DIFF_LINES && bytes < MAX_DIFF_BYTES; kept++) bytes += lines[kept].length + 1;
  if (kept < lines.length) {
    truncated = true;
    lines = [...lines.slice(0, kept), `… +${lines.length - kept} lines truncated`];
  }
  return { diff: lines.join("\n"), adds, dels, truncated };
}

// Flatten a pending Edit/Write/MultiEdit tool input into ops. Returns [] for any
// other tool — Bash and friends get no preview, and the field stays absent.
function opsFor(toolName: string, input: Record<string, unknown>): EditOp[] {
  const ts = ""; // preview ops are not persisted; ts is unused here
  if (toolName === "Edit") {
    return [
      {
        ts,
        tool: "Edit",
        replaceAll: input.replace_all === true,
        written: false,
        oldStr: typeof input.old_string === "string" ? input.old_string : "",
        newStr: typeof input.new_string === "string" ? input.new_string : "",
      },
    ];
  }
  if (toolName === "Write") {
    return [
      {
        ts,
        tool: "Write",
        replaceAll: false,
        written: true,
        oldStr: "",
        newStr: typeof input.content === "string" ? input.content : "",
      },
    ];
  }
  if (toolName === "MultiEdit") {
    const edits = Array.isArray(input.edits) ? (input.edits as Record<string, unknown>[]) : [];
    return edits.map((e) => ({
      ts,
      tool: "Edit",
      replaceAll: e.replace_all === true,
      written: false,
      oldStr: typeof e.old_string === "string" ? e.old_string : "",
      newStr: typeof e.new_string === "string" ? e.new_string : "",
    }));
  }
  return [];
}

// Preview of the edit a pending tool call would make, or null when the tool
// doesn't write a file (so the wire field is simply absent).
//
// `input` MUST be the same object the gate will hand back as `updatedInput`.
export function previewForTool(
  toolName: string,
  input: Record<string, unknown>,
  cwd?: string | null,
): DiffPreview | null {
  const raw = input.file_path ?? input.path;
  const path = typeof raw === "string" ? raw : null;
  if (!path) return null;
  const ops = opsFor(toolName, input);
  if (ops.length === 0) return null;

  const parts: string[] = [];
  let adds = 0;
  let dels = 0;
  let truncated = false;
  for (const op of ops) {
    const d = buildEditDiff(op);
    parts.push(d.diff);
    adds += d.adds;
    dels += d.dels;
    truncated ||= d.truncated;
  }

  let relPath = path;
  if (cwd) {
    const rel = relative(resolve(cwd), resolve(path));
    if (rel && !rel.startsWith("..")) relPath = rel;
  }
  return { relPath, diff: parts.join("\n"), adds, dels, truncated };
}
